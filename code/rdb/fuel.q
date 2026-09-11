// Gas procurement: the book, and the pool position derived from it.
//
// THE MODEL. There is no gas stored at a power station. Every plant draws on
// ONE portfolio, .gaz.portfolio (TEST_UNIVERSAL_TTF), which buys at .gaz.hub.
// So there is a single fuel position for the whole fleet, and `fuelmove`'s
// `plant` column says which unit committed or burnt against it — not whose
// tank it came out of. See the fuel procurement note in database.q.
//
// Lives on the RDB for the same reasons bidding.q does: today's `fueltrade`
// and `fuelmove` rows are already here, and this is the process serving HTTP.
//
// WHAT A TRADE IS. A purchase with a delivery window. It sits on the book from
// the moment it is struck and lands in the pool at `delivstart` — which is what
// makes "buy something now, find out later whether it was a good trade" work:
// the trade is recorded at today's mark, and the power prices that judge it
// clear weeks later. A trade is NOT an inventory movement, which is why it is
// a separate table from the ledger.
//
// NAME RESOLUTION. Every function here pulls a root table into a local with
// `get` before touching it, and filters with vector operations rather than
// qsql where-clauses. Inside a function under \d .fuel an undotted name in a
// select binds to .fuel.<name>, and a local sharing a column's name collides
// silently. Same lesson as the header of bidding.q.

\d .fuel

// A person decides a trade, even when a web form carries it.
src:`MANUAL

// --- history from the HDB ------------------------------------------------
//
// A fuel position is the sum of everything ever bought and burnt, so it cannot
// be read off the RDB alone — that holds only since the last EOD. Cached and
// refreshed on a slow timer, like .bid.hist and .gv.hist, because the HDB only
// changes at EOD.
//
// Aggregated HDB-side rather than shipped row by row: all that is wanted is
// five scalars, and a year of reservations is a large table to move to compute
// them. Unbounded by date on purpose — trades are hand-entered and few, unlike
// the marks .gv.refreshmarks has to bound. Revisit if that stops being true.

histperiod:0D00:05

// dmwh/dvalue  volume and cost of gas DELIVERED into the pool (trades landed)
// bmwh/bvalue  volume and cost of gas BURNT out of it
// resv         earmarked against open offers, RESERVE less RELEASE
zero:`dmwh`dvalue`bmwh`bvalue`resv!5#0f

hist:zero

hdbhandle:{
  // .[f;args;err], NOT @[f;args;err] — the @ form applies the pair as ONE
  // argument and binds a PROJECTION rather than a handle, with no error. An
  // open handle is an int atom (-6h); 0Ni, meaning no hdb, is one too.
  h:.[.servers.gethandlebytype;(`hdb;`any);0Ni];
  $[(type h) in -6 -7h; h; 0Ni] }

refreshhist:{
  h:.fuel.hdbhandle[];
  if[null h; :0];
  // Only trades that have actually LANDED count toward the pool. A forward
  // bought for November is on the book but not in the tank, and counting it
  // as delivered would let it be offered months before it arrives.
  t:@[h; "select dmwh:sum mwh, dvalue:sum mwh*price from fueltrade ",
         "where delivstart<=.z.p"; ()];
  m:@[h; "select mwh:sum mwh, value:sum mwh*price by reason from fuelmove"; ()];
  r:.fuel.zero;
  if[count t;
    r[`dmwh]:first t`dmwh; r[`dvalue]:first t`dvalue];
  if[count m;
    m:0!m;
    q:(m`reason)!m`mwh;
    v:(m`reason)!m`value;
    r[`bmwh]:0f^q`BURN; r[`bvalue]:0f^v`BURN;
    r[`resv]:(0f^q`RESERVE)-0f^q`RELEASE];
  // Backtick, not a bare name — `set` takes a SYMBOL on the left. Given the
  // value it neither assigns nor errors and the cache stays empty for ever.
  `.fuel.hist set r;
  1 }

// --- trades in flight ----------------------------------------------------
//
// A row published to the tickerplant is NOT immediately visible here: the STP
// batches, so it comes back on its next publish. Between the two, `position`
// reports the pre-trade pool — so buying gas and immediately offering against
// it would have the offer rejected for fuel that is already paid for.
//
// (The mirror of the bug this guard was originally written for. When plants
// had tanks the exposure was double-counting a refuel against a ceiling; with
// no ceiling the exposure runs the other way, and the failure is a rejected
// offer rather than an impossible stock level. The window is the same.)
//
// TTL, because "seen coming back" can never happen: EOD clears `fueltrade` out
// of the RDB, and a trade published just before the roll would sit here
// inflating the pool for ever. Expiry makes the guard self-healing.
pendingttl:0D00:00:30

// `cost`, NOT `value`. `value` is a q BUILT-IN, so a column of that name fails
// to even parse inside a table literal with 'assign — the same trap as `gtime`
// in grafanaviews.q and `from`/`to` in database.q.
pending:([] time:`timestamp$(); ref:`symbol$(); mwh:`float$(); cost:`float$())

// Drop what has landed or expired. Vector filtering, not a qsql where-clause:
// inside a select, `seen` would resolve against the ROOT namespace rather than
// this local and the filter would silently match nothing.
reap:{
  p:.fuel.pending;
  if[0=count p; :0];
  ft:$[`fueltrade in tables[]; get `fueltrade; 0#p];
  seen:$[count ft; distinct ft`ref; 0#`];
  `.fuel.pending set p where (not p[`ref] in seen) and p[`time] > .z.p - .fuel.pendingttl;
  count .fuel.pending }

// --- the pool ------------------------------------------------------------

// Today's half, off the RDB's in-memory tables.
today:{
  r:.fuel.zero;
  if[`fueltrade in tables[];
    ft:get `fueltrade;
    if[count ft;
      // Landed only, same rule as the HDB half.
      m:ft[`delivstart]<=.z.p;
      if[any m;
        r[`dmwh]:sum ft[`mwh] where m;
        r[`dvalue]:sum (ft[`mwh]*ft[`price]) where m]]];
  if[`fuelmove in tables[];
    fm:get `fuelmove;
    if[count fm;
      rsn:fm`reason; q:fm`mwh;
      b:rsn=`BURN;
      if[any b;
        r[`bmwh]:sum q where b;
        r[`bvalue]:sum (q*fm`price) where b];
      r[`resv]:(sum q where rsn=`RESERVE)-sum q where rsn=`RELEASE]];
  r }

// The whole position: history, today, and what is still in flight.
//
// Returned as a dictionary of scalars rather than a table because there is
// exactly one pool. Every figure is a plain sum over a subset of the two
// tables — nothing here is a running balance.
//
//   delivered  gas bought whose window has started
//   burnt      gas consumed
//   physical   delivered - burnt        what the portfolio actually holds
//   reserved   RESERVE - RELEASE        earmarked against open offers
//   available  physical - reserved      what may still be offered
//   wacog      weighted average cost of what remains, EUR/MWh thermal
//   forward    bought but not yet delivered - on the book, not in the pool
position:{
  .fuel.reap[];
  h:.fuel.hist; t:.fuel.today[];
  pd:.fuel.pending;
  pm:$[count pd; sum pd`mwh; 0f];
  pv:$[count pd; sum pd`cost; 0f];

  dm:h[`dmwh]+t[`dmwh]+pm;  dv:h[`dvalue]+t[`dvalue]+pv;
  bm:h[`bmwh]+t[`bmwh];     bv:h[`bvalue]+t[`bvalue];
  phys:dm-bm;
  resv:h[`resv]+t[`resv];

  // WACOG of what REMAINS, not of everything ever bought: value delivered less
  // value burnt, over volume delivered less volume burnt. Guarded rather than
  // returning an infinity that would poison anything downstream — an empty
  // pool has no average cost, and 0n says so honestly where 0f would read as
  // free gas.
  `portfolio`hub`delivered`burnt`physical`reserved`available`wacog`forward!
    (.gaz.portfolio; .gaz.hub; dm; bm; phys; resv; phys-resv;
     $[phys>1e-9; (dv-bv)%phys; 0nf]; .fuel.forward[]) }

// Bought but not yet landed. On the book from the moment it is struck, which
// is the half of the position a tank model cannot express at all.
forward:{
  n:0f;
  if[`fueltrade in tables[];
    ft:get `fueltrade;
    if[count ft; m:ft[`delivstart]>.z.p; if[any m; n:sum ft[`mwh] where m]]];
  h:.fuel.hdbhandle[];
  if[null h; :n];
  r:@[h; "select mwh:sum mwh from fueltrade where delivstart>.z.p"; ()];
  n + $[count r; first r`mwh; 0f] }

// --- writing -------------------------------------------------------------

// .[f;(a;b);e], not @[f;x;e]: the @ form applies its second argument as ONE
// argument, so a two-argument function comes back as a projection and every
// later use fails somewhere else entirely. gethandlebytype also returns an
// empty int list rather than a null when it finds nothing, so normalise with
// `,()` before taking first. Both traps are documented in CLAUDE.md.
tp:{
  h:.[.servers.gethandlebytype; (`segmentedtickerplant;`any); {0Ni}];
  h:first h,();
  if[null h; '"no tickerplant reachable - cannot trade"];
  h }

// A trade id. Digits only: a timestamp string carries dots and a D that would
// need quoting as a symbol. G for gas, so a ref is traceable to its table
// without a join — B is a bid, from .bid.newref.
newref:{`$"G",(string[.z.p] where string[.z.p] in .Q.n)}

// Buy gas for a delivery window.
//
//   .fuel.buy[50000f; 34.20; 2026.10.01D00:00; 2026.11.01D00:00]
//
// `mwh` is MWh THERMAL over the whole window, `price` EUR/MWh thermal paid.
// `delivend` is EXCLUSIVE, matching the offer blocks in .gz.parseblocks.
//
// There is no ceiling to check against — that was the tank, and it is gone. A
// trade is rejected only for being malformed. What it CAN do is fail later, at
// submit: gas bought for November does not make an October offer possible.
buy:{[mwh;price;delivstart;delivend]
  q:"f"$mwh; px:"f"$price;
  if[not 1=count q,();  '"one quantity per trade - buy does not vectorise"];
  if[not 1=count px,(); '"one price per trade - buy does not vectorise"];
  q:first q,(); px:first px,();
  f:"p"$delivstart; t:"p"$delivend;
  f:first f,(); t:first t,();

  if[null q;  '"null mwh"];
  if[null px; '"null price"];
  if[any null (f;t); '"null delivery window - need delivstart and delivend"];
  if[q<=1e-9; '"trade must be positive - mwh is a magnitude, not a signed delta (see database.q)"];
  if[px<0f;  '"negative price - gas has traded below zero, but not here"];
  if[t<=f;   '"delivend must be after delivstart, and it is EXCLUSIVE"];

  ref:.fuel.newref[];
  h:.fuel.tp[];

  // The STP prepends `time`, so this publishes eight columns, not nine.
  neg[h](".u.upd";`fueltrade;
    (enlist .gaz.portfolio; enlist .gaz.hub; enlist f; enlist t;
     enlist q; enlist px; enlist ref; enlist .fuel.src));
  neg[h][];                              // flush, so the caller knows it landed

  // Committed, but not yet echoed by the tickerplant. Recorded BEFORE this
  // returns so an offer submitted straight afterwards sees the gas.
  `.fuel.pending upsert (.z.p; ref; $[f<=.z.p; q; 0f]; $[f<=.z.p; q*px; 0f]);

  .lg.o[`fuel;"bought ",string[.gaz.rnd[1;q]]," MWh th at ",string[.gaz.rnd[2;px]],
        " EUR/MWh for ",string[f]," to ",string[t]," ref ",string ref];
  `ref`portfolio`hub`mwh`price`cost`delivstart`delivend!
    (ref; .gaz.portfolio; .gaz.hub; q; px; q*px; f; t) }

// Buy at the current market mark, delivering now. The normal way to start a
// demo stack, and the replacement for the old .bid.fillall.
//
// Takes the mark off the `gas` table rather than accepting a price, because
// the point of this is "put gas in the pool at a fair price without thinking
// about it". A real trade goes through .fuel.buy with the price you were hit
// at, which is the number the fuel P&L is measured against.
buyspot:{[mwh]
  if[not `gas in tables[]; '"no gas marks yet - the feed has not published"];
  // `get` and vector filtering, NOT `exec price from gas where hub=...`. Under
  // \d .fuel an undotted name inside a select binds to .fuel.gas, which does
  // not exist, and the call dies with a bare 'gas. The rule is in this file's
  // header; this is the function that proved it.
  t:get `gas;
  m:t[`hub]=.gaz.hub;
  if[not any m; '"no ",string[.gaz.hub]," mark yet - nothing to price against"];
  g:last t[`price] where m;
  if[null g; '"no ",string[.gaz.hub]," mark yet - nothing to price against"];
  // A day-long window starting now, so it lands immediately and `forward`
  // stays zero. delivend is exclusive.
  .fuel.buy[mwh; g; .z.p; .z.p+0D24:00] }

// The book, newest first. Includes forwards, which is the point of keeping it.
trades:{
  empty:([] time:`timestamp$(); ref:`symbol$(); mwh:`float$(); price:`float$();
            delivstart:`timestamp$(); delivend:`timestamp$(); landed:`boolean$());
  if[not `fueltrade in tables[]; :empty];
  ft:get `fueltrade;
  if[0=count ft; :empty];
  t:`time xdesc select time, ref, mwh, price, delivstart, delivend from ft;
  update landed:delivstart<=.z.p, cost:mwh*price from t }

\d .

// The HDB pull is on a slow timer — it is a disk read over IPC against data
// that only changes at EOD. Trapped so a signal out of it logs and is dropped
// rather than taking .timer down with it.
//
// @[f;::;h], not .[f;();h]. A niladic q function still takes one argument, the
// null `::`, so an empty argument LIST is a rank error — and trapped, that
// rank error is all you ever see.
.fuel.refreshtrap:{
  @[.fuel.refreshhist; ::; {.lg.e[`fuel;"hdb fuel history refresh failed: ",x]; 0}] }

.timer.repeat[.proc.cp[]; 0Wp; .fuel.histperiod; (`.fuel.refreshtrap;`);
              "refresh fuel history from hdb"];
