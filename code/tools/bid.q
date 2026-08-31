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
//   q).bid.submit[`CCGT1;`DE_LU;2026.08.31D06:00;400f;78.50]
//   q).bid.curve[`CCGT1;`DE_LU;2026.08.31;400f;78.50]   / all 96 periods
//   q).bid.effective[2026.08.30D10:00]                  / what stands at the gate
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

// One offer, one delivery period.
//
// `time` is omitted on purpose — the tickerplant prepends its own, and sending
// one makes the payload a column too wide (stplog.q:53). Every column is a
// list of length 1 because .u.upd takes column-major data, never a table.
// Casts rather than type assertions: `type` on an atom is negative (a
// timestamp atom is -12h, a list 12h), so asserting on the list code rejects
// every valid single value. Casting accepts a date or a timestamp and fails
// with q's own message if given something that is neither.
submit:{[plant;zone;delivery;mw;price]
  delivery:"p"$delivery;
  mw:"f"$mw;
  price:"f"$price;
  if[null delivery; '"delivery is null - pass a date or timestamp"];
  neg[tp[]](".u.upd";`bid;
    (enlist plant; enlist zone; enlist delivery; enlist mw; enlist price; enlist `MANUAL));
  neg[tp[]][];
  (`plant`zone`delivery`mw`price)!(plant;zone;delivery;mw;price) }

// The same offer across every 15-minute period of a delivery date. This is the
// normal case: you bid a whole day, not a single quarter hour.
curve:{[plant;zone;date;mw;price]
  d:("p"$date)+0D00:15*til 96;
  n:count d;
  neg[tp[]](".u.upd";`bid;
    (n#plant; n#zone; d; n#"f"$mw; n#"f"$price; n#`MANUAL));
  neg[tp[]][];
  n }

// What actually stands at gate closure. Offers are append-only, so the
// effective one is the LAST row before the gate, not simply the last row —
// that is the whole point of keeping the history.
effective:{[gate]
  h:.servers.gethandlebytype[`rdb;`any];
  h ("select last mw, last price by plant, zone, delivery from bid ",
     "where time < ",string "p"$gate) }

\d .
