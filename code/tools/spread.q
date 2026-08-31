// Clean spark spread over a delivery curve.
//
// The T-1 calculation: you know today's gas and carbon marks, tomorrow's power
// prices have cleared, and you want to know which periods your unit is in the
// money for. That is the whole CCGT question.
//
//   tq
//   q).spread.curve[`CCGT_DE_2;2026.08.31]
//   q).spread.summary[`CCGT_DE_2;2026.08.31]
//
// Loaded into the itest proctype alongside bid.q, so tq has it ready.
//
// Two decisions worth knowing about:
//
// * Power is deduplicated with `last price by zone,delivery`. ENTSO-E revises
//   published prices, and a restart of the feed republishes the whole window,
//   so the raw table holds several rows per delivery period — some genuinely
//   disagreeing. Taking the last by ingest time is "the most recent revision
//   we have seen", which is the honest reading.
//
// * Gas and carbon are point marks, not curves. They are simulated here and
//   move continuously, so the spread uses the latest observed value for every
//   delivery period rather than pretending to know a forward gas curve. A real
//   desk would use the forward gas price for the delivery date.

\d .spread

rdb:{
  h:.[.servers.gethandlebytype; (`rdb;`any); {0Ni}];
  h:first h,();
  if[null h; '"no rdb reachable - is the stack up, and is this a connected proctype?"];
  h }

// Latest gas (TTF, EUR/MWh thermal) and carbon (EUR/tCO2) marks.
marks:{
  h:rdb[];
  (h"last exec price from gas where hub=`TTF"; h"last exec price from carbon") }

// Clean spark per delivery period for one plant on one delivery date.
//
// Column arithmetic rather than a qsql update: names inside a select resolve
// against the root namespace at runtime, not the enclosing function's scope,
// so locals like the plant record are not reliably visible there.
curve:{[plant;date]
  pl:.gaz.plants plant;
  // A keyed-table miss returns a null-FILLED dictionary, not an empty one, so
  // `count pl` is 6 either way. Test a field for null instead, or an unknown
  // plant sails through and fails much later with an empty result.
  if[null pl`zone; '"unknown plant: ",string[plant]," - see .gaz.plants"];
  gc:marks[];
  gas:gc 0; co2:gc 1;

  pw:0!rdb[]"select price:last price by zone,delivery from power where src=`ENTSOE";

  // No qsql here on purpose. Names inside a select resolve against the ROOT
  // namespace at runtime, not this function's scope, so `where zone=pl`zone,
  // delivery.date=date` silently matches nothing — `pl` and `date` are locals
  // and invisible to it. Plain vector filtering has no such trap.
  m:(pw[`zone]=pl`zone) and (`date$pw`delivery)=date;
  if[not any m; '"no cleared power prices for that zone and date"];
  dl:pw[`delivery] where m;
  pwr:pw[`price] where m;
  o:iasc dl; dl:dl o; pwr:pwr o;

  mc:.gaz.marginalcost[gas;co2;pl`ef;pl`efficiency];
  ([] delivery :dl;
      power    :pwr;
      marginal :count[pwr]#mc;
      spark    :pwr-mc;
      run      :pwr>mc) }

// One-line view of a day: how many periods pay, and what the day is worth if
// you run only those. Ignores start-up cost, consistent with .gaz.dispatch.
summary:{[plant;date]
  pl:.gaz.plants plant;
  c:curve[plant;date];
  inmoney:select from c where run;
  // 15-minute periods, so a period is a quarter of an hour of output
  mwh:0.25*pl`capacity;
  `plant`date`periods`inmoney`bestspark`worstspark`marginal`grossmargin!
    (plant; date; count c; count inmoney;
     max c`spark; min c`spark; first c`marginal;
     mwh*sum inmoney`spark) }

\d .
