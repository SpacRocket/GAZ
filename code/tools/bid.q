// Submitting offers by hand.
//
// A bid is not a feed: a person decides it and submits it, which is exactly
// why it goes through the tickerplant. The stamp the tickerplant puts on it is
// the moment you committed to that offer, and because the log is append-only,
// revising an offer before gate closure leaves both versions on the record.
//
// Everything in code/tools/ is loaded as a DIRECTORY by the itest proctype, so
// only loadable libraries belong here — a standalone script that connects on
// load (rconsole.q) breaks every process that loads the directory. That one
// lives in code/console/.
//
// Loaded into the itest proctype, so `tq` gives you these straight away:
//
//   tq
//   q).bid.submit[`Sloe;2026.09.08D06:00;400f;78.50]
//   q).bid.curve[`Sloe;2026.09.08;400f;78.50]    / all 96 periods
//   q).bid.fuel[]                                / fuel position per plant
//   q).bid.effective[2026.09.07D10:00]           / what stands at the gate
//
// Deliberately NOT in code/common/gaz.q: that file is loaded into every
// process and is kept to pure functions so tests/unit can exercise it without
// a stack. These open handles, so they live here.

\d .bid

// EUR/MWh, MW, and a delivery period — the units table in database.q is the
// authority on which is which.

// .[f;(a;b);e] not @[f;x;e]: the @ form applies f to ONE argument, so a
// two-argument function comes back as a projection and every later use fails
// with a type error. gethandlebytype also returns an empty int list rather
// than a null when it finds nothing, so test the count, not `null`.
tp:{
  h:.[.servers.gethandlebytype; (`segmentedtickerplant;`any); {0Ni}];
  // gethandlebytype returns an int ATOM when it finds one handle and an empty
  // int list when it finds none, so `where`/`count` on the result is a type
  // error half the time. `,()` normalises both to a list before taking first.
  h:first h,();
  if[null h; '"no tickerplant reachable - is the stack up, and is this a connected proctype (tq, not make repl-isolated)?"];
  h }

// Submitting by hand now goes THROUGH THE RDB rather than straight to the
// tickerplant. Two reasons, and the second is the important one:
//
//   * `bid` grew a `ref` column, so a six-column publish is now one short and
//     the tickerplant rejects the batch with 'length.
//   * more importantly, an offer has to earmark the fuel it would burn. That
//     logic lives in code/rdb/bidding.q — validation, the release of any
//     earlier reservation for the same periods, and the fuelmove rows. A
//     second copy here would drift from it, and a hand-submitted bid that
//     skipped the reservation would silently let the same MWh be offered twice.
//
// So these are thin remote calls. The RDB is the one place that knows how to
// turn an offer into a bid plus a reservation.

rdb:{
  h:.[.servers.gethandlebytype; (`rdb;`any); {0Ni}];
  h:first h,();
  if[null h; '"no rdb reachable - is the stack up, and is this a connected proctype (tq)?"];
  h }

// One offer, one delivery period. `zone` is no longer an argument: the RDB
// takes it from plants.csv, because a bid into the wrong zone is unrecoverable
// and there is exactly one right answer for a given unit.
submit:{[plant;delivery;mw;price]
  rdb[](`.bid.submit; plant; enlist "p"$delivery; enlist "f"$mw; enlist "f"$price) }

// The same offer across every 15-minute period of a delivery date. This is the
// normal case: you bid a whole day, not a single quarter hour.
curve:{[plant;date;mw;price]
  d:("p"$date)+0D00:15*til 96;
  rdb[](`.bid.submit; plant; d; 96#"f"$mw; 96#"f"$price) }

// Fuel position per plant: physical stock, what is earmarked, what is left to
// offer. MWh THERMAL.
fuel:{ rdb[](`.bid.state; ::) }

// What actually stands at gate closure. Offers are append-only, so the
// effective one is the LAST row before the gate, not simply the last row —
// that is the whole point of keeping the history.
effective:{[gate]
  h:.servers.gethandlebytype[`rdb;`any];
  h ("select last mw, last price by plant, zone, delivery from bid ",
     "where time < ",string "p"$gate) }

\d .
