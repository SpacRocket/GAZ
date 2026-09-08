// Bid submission and fuel reservation.
//
// Lives on the RDB because that is where today's `bid` and `fuelmove` rows
// already are (it subscribes to everything) and because it is the process
// serving HTTP to Grafana. It reaches the tickerplant to publish, exactly as
// code/tools/bid.q does by hand — a bid is a decision, so it travels the same
// logged, append-only path as any other tick.
//
// THE FUEL LIFECYCLE. Submitting an offer does not burn gas; it earmarks it.
// The unit only burns if the auction clears in its favour, which is the day
// after the offer. So:
//
//   submit          RESERVE           available drops, physical unchanged
//   auction misses  RELEASE           available restored
//   auction clears  RELEASE + BURN    on dispatch
//
// Deducting outright at submission would drain storage on offers that never
// cleared and leave the ledger disagreeing with the tank. See database.q for
// the sign convention: `mwh` is always positive, `reason` carries direction.
//
// Re-bidding a period you already offered RELEASES the previous reservation
// first. Without that the second offer earmarks fuel on top of the first and
// the plant looks out of gas after a few revisions — bids are append-only, so
// revising one is normal, not exceptional.
//
// NAME RESOLUTION. Every function here pulls a root table into a local with
// `get` before touching it in a select. Inside a function defined under
// \d .bid, an undotted name in a select binds to .bid.<name> — which does not
// exist — and the call dies with 'fuelmove. Same lesson as the .gaz.bucket
// note in CLAUDE.md, in the other direction. Filters use vector operations
// rather than qsql where-clauses for the related reason spread.q documents:
// a local and a column sharing a name collide silently.

\d .bid

// A person decides a bid, even when a web form carries it.
src:`MANUAL

// --- fuel ledger, RDB + HDB ----------------------------------------------
//
// A fuel level is the sum of every move ever made, so it cannot be read off
// the RDB alone — that holds only since the last EOD. The HDB half is cached
// and refreshed on a slow timer, like .gv.hist, because it only changes at EOD.

histperiod:0D00:05

hist:([] plant:`symbol$(); reason:`symbol$(); mwh:`float$())

refreshhist:{
  h:.[.servers.gethandlebytype;(`hdb;`any);0Ni];
  if[not (type h) in -6 -7h; :0];
  if[null h; :0];
  // Pre-aggregated in the HDB rather than shipped row by row: a year of
  // reservations is a big table and all that is wanted is a sum per plant.
  r:@[h; "0!select mwh:sum mwh by plant,reason from fuelmove"; ()];
  if[not count r; :0];
  `.bid.hist set r;
  count .bid.hist }

// Totals per plant and reason, history plus today.
totals:{
  t:.bid.hist;
  if[`fuelmove in tables[];
    fm:get `fuelmove;
    if[count fm; t:t, 0!select mwh:sum mwh by plant,reason from fm]];
  if[0=count t; :([] plant:`symbol$(); reason:`symbol$(); mwh:`float$())];
  0!select mwh:sum mwh by plant,reason from t }

// --- deliveries in flight -------------------------------------------------
//
// A row published to the tickerplant is NOT immediately visible here: the STP
// batches, so it comes back on its next publish. Between the two, `totals`
// still reports the old level — and two refuels of the same plant inside that
// window both read it, both pass the fuelcap check and both land. Found by
// firing five requests at the live stack in 40ms: total physical came back at
// 575001 MWh against a ceiling of 267000.
//
// So a delivery is held here from the moment it is published until it is seen
// coming back, and `state` counts it as already in the tank. That is the
// honest reading — the gas is committed, the ledger just has not echoed yet.
//
// TTL, because "seen coming back" can never happen: EOD clears `fuelmove` out
// of the RDB, and a row published just before the roll would leave an entry
// here inflating `physical` for ever. Expiry makes the guard self-healing —
// worst case it stops guarding after thirty seconds, which is still three
// orders of magnitude longer than the window it exists to close.
//
// The same window applies to RESERVE from .bid.submit, which is left alone:
// a re-bid releases its predecessor, so the failure there is a rejected offer
// rather than a ledger that disagrees with the tank.
pendingttl:0D00:00:30

pending:([] time:`timestamp$(); ref:`symbol$(); plant:`symbol$(); mwh:`float$())

// Drop what has landed or expired. Vector filtering, not a qsql where-clause:
// inside a select, `seen` would resolve against the ROOT namespace rather than
// this local and the filter would silently match nothing.
reap:{
  p:.bid.pending;
  if[0=count p; :0];
  fm:$[`fuelmove in tables[]; get `fuelmove; 0#p];
  seen:$[count fm; distinct fm`ref; 0#`];
  `.bid.pending set p where (not p[`ref] in seen) and p[`time] > .z.p - .bid.pendingttl;
  count .bid.pending }

// In-flight deliveries per plant, as a dictionary over EVERY plant, matching
// the shape by_ returns so state can simply add the two.
pendingby:{
  .bid.reap[];
  pl:exec plant from .gaz.plants;
  base:pl!count[pl]#0f;
  pd:.bid.pending;
  if[0=count pd; :base];
  s:0!select mwh:sum mwh by plant from pd;
  base, (s`plant)!s`mwh }

// Sum of one reason per plant, as a dictionary over EVERY plant. A plant with
// no rows for a reason must read 0f rather than dropping out, because every
// figure below is a difference of two of these.
by_:{[t;r]
  p:exec plant from .gaz.plants;
  base:p!count[p]#0f;
  if[0=count t; :base];
  m:t[`reason]=r;
  if[not any m; :base];
  base, (t[`plant] where m)!(t[`mwh] where m) }

// Physical stock, earmarked, and what may still be offered. MWh THERMAL.
state:{
  t:.bid.totals[];
  phys:(.bid.by_[t;`DELIVERY] - .bid.by_[t;`BURN]) + .bid.pendingby[];
  resv:.bid.by_[t;`RESERVE]  - .bid.by_[t;`RELEASE];
  p:0!.gaz.plants;
  ([] plant:p`plant; zone:p`zone; capacity:p`capacity;
      efficiency:p`efficiency; fuelcap:p`fuelcap;
      physical:phys p`plant; reserved:resv p`plant;
      available:(phys-resv) p`plant) }

// Open reservations per delivery period for one plant — RESERVE not yet given
// back. This is what a re-bid has to release before earmarking again.
open:{[pl]
  empty:([] delivery:`timestamp$(); mwh:`float$());
  if[not `fuelmove in tables[]; :empty];
  fm:get `fuelmove;
  if[0=count fm; :empty];
  m:(fm[`plant]=pl) and fm[`reason] in `RESERVE`RELEASE;
  if[not any m; :empty];
  // RESERVE adds to the earmark, RELEASE gives it back. Signing here rather
  // than in the ledger keeps `mwh` on disk a plain positive magnitude.
  rsn:fm[`reason] where m;
  amt:fm[`mwh] where m;
  t:([] delivery:fm[`delivery] where m; mwh:?[rsn=`RESERVE; amt; neg amt]);
  r:0!select mwh:sum mwh by delivery from t;
  select from r where mwh>1e-9 }

// --- submission ----------------------------------------------------------

// .[f;(a;b);e], not @[f;x;e]: the @ form applies its second argument as ONE
// argument, so a two-argument function comes back as a projection and every
// later use fails somewhere else entirely. gethandlebytype also returns an
// empty int list rather than a null when it finds nothing, so normalise with
// `,()` before taking first. Both traps are documented in CLAUDE.md.
tp:{
  h:.[.servers.gethandlebytype; (`segmentedtickerplant;`any); {0Ni}];
  h:first h,();
  if[null h; '"no tickerplant reachable - cannot submit"];
  h }

// A ledger id, unique per call and readable in a log line. Digits only:
// a timestamp string carries dots and a D that would need quoting as a symbol.
// The prefix says what kind of event it was — B for a bid, D for a delivery —
// so a ref found in the fuelmove table is traceable without a join.
newref:{[pfx] `$pfx,(string[.z.p] where string[.z.p] in .Q.n)}

// Submit an offer curve for one plant.
//
// `deliveries`, `mws` and `prices` are equal-length lists — one entry per
// 15-minute period. The zone is taken from plants.csv rather than accepted as
// an argument: a bid into the wrong zone is unrecoverable, and there is
// exactly one right answer for a given unit.
//
// Everything is validated BEFORE anything is published. A partial submission —
// bids sent, reservation rejected — would leave an offer standing against fuel
// that was never earmarked, which is precisely the state this is meant to
// prevent.
submit:{[pl;deliveries;mws;prices]
  if[not pl in exec plant from .gaz.plants; '"unknown plant: ",string pl];
  rec:.gaz.plants pl;

  d:"p"$deliveries; mw:"f"$mws; px:"f"$prices;
  d:d,(); mw:mw,(); px:px,();          // accept a single period as atoms
  n:count d;
  if[0=n; '"nothing to submit"];
  if[n<>count mw; '"mw count (",string[count mw],") does not match periods (",string[n],")"];
  if[n<>count px; '"price count (",string[count px],") does not match periods (",string[n],")"];
  if[any null d;  '"null delivery period"];
  if[any null mw; '"null mw"];
  if[any null px; '"null price"];
  if[any mw<0f;   '"negative mw"];
  if[any px<0f;   '"negative price - offers may be zero but not negative here"];
  if[any mw>rec`capacity;
    '"offer of ",string[max mw]," MW exceeds ",string[pl]," capacity of ",
      string[rec`capacity]," MW"];
  if[n<>count distinct d; '"duplicate delivery periods in one submission"];

  // What this curve would burn, per period, MWh thermal.
  need:.gaz.fuelburn[mw; .gaz.periodhours; rec`efficiency];

  // Releasing first is what makes a revision safe. Vector filtering, not
  // `where delivery in d` — `d` is a local and `delivery` a column.
  op:.bid.open[pl];
  relm:$[count op; op[`delivery] in d; 0#0b];
  reld:op[`delivery] where relm;
  relq:op[`mwh] where relm;

  st:.bid.state[];
  avail:first st[`available] where st[`plant]=pl;
  // The release is added back before the check: re-bidding the same periods
  // must not fail merely because the earlier version of the same offer is
  // still holding the fuel.
  if[(sum need) > avail + sum relq;
    '"insufficient fuel for ",string[pl],": need ",string[.gaz.rnd[1;sum need]],
      " MWh thermal, ",string[.gaz.rnd[1;avail + sum relq]]," available"];

  ref:.bid.newref"B";
  h:.bid.tp[];

  // Order matters. RELEASE before RESERVE so the ledger never shows the same
  // fuel earmarked twice, even to a reader that lands mid-submission.
  if[count reld;
    neg[h](".u.upd";`fuelmove;
      (count[reld]#pl; reld; relq; count[reld]#`RELEASE; count[reld]#ref;
       count[reld]#.bid.src))];

  neg[h](".u.upd";`bid;
    (n#pl; n#rec`zone; d; mw; px; n#ref; n#.bid.src));

  // No reservation for a period offered at zero MW - it burns nothing, and a
  // zero row is noise in a ledger meant to be read by a person.
  k:where need>1e-9;
  if[count k;
    neg[h](".u.upd";`fuelmove;
      (count[k]#pl; d k; need k; count[k]#`RESERVE; count[k]#ref;
       count[k]#.bid.src))];

  neg[h][];                              // flush, so the caller knows it landed
  .lg.o[`bid;"submitted ",string[n]," period(s) for ",string[pl],
        " ref ",string[ref],", reserved ",string[.gaz.rnd[1;sum need]]," MWh th"];
  `ref`plant`zone`periods`mw`fuelreserved`fuelreleased!
    (ref; pl; rec`zone; n; sum mw*.gaz.periodhours; sum need; sum relq) }

// --- deliveries ----------------------------------------------------------
//
// WHY EVERY PLANT READS ZERO ON A FRESH STACK. `physical` is
// `sum DELIVERY - sum BURN`, and until this function existed nothing in the
// repo ever published a DELIVERY row — submit only writes RESERVE and
// RELEASE. So the tanks started empty and stayed empty, and the first offer
// of any size failed the "insufficient fuel" check. Gas has to arrive before
// it can be burnt; this is how it arrives.
//
// A delivery is not a feed either — someone nominated it — so it takes the
// same logged, append-only path as a bid, with src=MANUAL.

// Book `mwh` MWh THERMAL of gas into a plant's storage.
//
// `fuelcap` is a physical ceiling, so an overfill is rejected rather than
// clipped: silently accepting less than was nominated would leave the ledger
// disagreeing with the delivery note, which is exactly the state the ledger
// exists to prevent. The error says how much room there is.
refuel:{[pl;mwh]
  if[not pl in exec plant from .gaz.plants; '"unknown plant: ",string pl];
  rec:.gaz.plants pl;

  q:"f"$mwh;
  if[not 1=count q,(); '"one plant, one quantity - refuel does not vectorise"];
  q:first q,();
  if[null q;     '"null mwh"];
  if[q<=1e-9;    '"delivery must be positive - mwh is a magnitude, not a signed delta (see database.q)"];

  // Read the level back off the ledger rather than trusting a caller's idea
  // of it: state[] is the only definition of "physical" that the rest of the
  // system agrees with.
  st:.bid.state[];
  m:st[`plant]=pl;
  phys:first st[`physical] where m;
  resv:first st[`reserved] where m;
  room:rec[`fuelcap] - phys;
  if[q > room + 1e-9;
    '"delivery overfills ",string[pl],": ",string[.gaz.rnd[1;q]],
      " MWh thermal offered, ",string[.gaz.rnd[1;room]]," MWh of headroom"];

  ref:.bid.newref"D";
  h:.bid.tp[];

  // delivery is 0Np: gas arriving into the tank relates to no offer period.
  // The STP prepends `time`, so this publishes six columns, not seven.
  neg[h](".u.upd";`fuelmove;
    (enlist pl; enlist 0Np; enlist q; enlist `DELIVERY; enlist ref;
     enlist .bid.src));
  neg[h][];                              // flush, so the caller knows it landed

  // Committed, but not yet echoed by the tickerplant. Recorded BEFORE this
  // returns so the next call — a double-clicked button is the realistic one —
  // sees it and refuses to overfill.
  `.bid.pending upsert (.z.p; ref; pl; q);

  .lg.o[`bid;"delivered ",string[.gaz.rnd[1;q]]," MWh th to ",string[pl],
        " ref ",string[ref],", physical now ",string[.gaz.rnd[1;phys+q]]];
  `ref`plant`delivered`physical`reserved`available!
    (ref; pl; q; phys+q; resv; phys+q-resv) }

// Top a plant up to its `fuelcap`. The normal way to start a demo stack, and
// the reason refuel takes a quantity rather than a target: the ledger records
// what arrived, so "fill it" has to be turned into a number by someone.
// A tank already full is a no-op, not an error — filling twice is a
// reasonable thing to ask for and must not publish a zero row.
fill:{[pl]
  if[not pl in exec plant from .gaz.plants; '"unknown plant: ",string pl];
  st:.bid.state[];
  m:st[`plant]=pl;
  room:(first st[`fuelcap] where m) - first st[`physical] where m;
  $[room>1e-9;
    .bid.refuel[pl; room];
    `ref`plant`delivered`physical`reserved`available!
      (`; pl; 0f; first st[`physical] where m; first st[`reserved] where m;
       first st[`available] where m)] }

// Every plant to its ceiling, in one call. Returns the fuel position after.
fillall:{
  {[pl] .bid.fill pl} each exec plant from .gaz.plants;
  .bid.state[] }

\d .
