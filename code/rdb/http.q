// Plain JSON over HTTP, for Grafana.
//
// Replaces TorQ's grafana.q, which implements the Grafana SimpleJSON API — an
// API whose only client plugin is Angular-based. Grafana disables Angular by
// default from 11 and removed the escape hatch entirely in 11.6, so that path
// was already pinned to a dying Grafana and warning users on every dashboard.
//
// This serves ordinary JSON instead, which any modern React datasource reads
// (Infinity, JSON API). It also drops grafana.q's constraints: it had ONE
// timecol and ONE sym for every table, which is why the views needed a
// `gvtime` column and why raw tick tables broke /search with 'sym.
//
//   GET /gaz/power     day-ahead power price by bidding zone
//   GET /gaz/marginal  marginal cost per MWh electrical, by plant
//   GET /gaz/marks     the gas and carbon marks driving marginal cost
//
// LONG format on purpose — [{time; sym; value}] — not one column per series.
// The schema then stays fixed however many plants or zones exist, so a new
// unit in plants.csv appears on the dashboard without touching the panel. The
// panel does long -> wide with a prepareTimeSeries transformation.

// No `\d .gz` block, deliberately. Inside a namespace context an undotted
// name resolves to that namespace, so `gv_marginal` becomes `.gz.gv_marginal`
// and the root view is invisible. Functions are qualified explicitly instead.

// kdb+ timestamps are nanoseconds since 2000; Grafana wants milliseconds
// since 1970. Numbers rather than ISO strings: formatting an ISO timestamp in
// q means splicing the date and time parts by hand (`string` on a datetime
// gives dots in the date, and ssr would eat the fractional-second dot too),
// and epoch millis need no parsing rules agreed with the client.
.gz.ms:{`long$(x - 1970.01.01D00:00:00.000000000) % 1000000};

// Long-format rows from a (time; sym; value) triple.
.gz.long:{[tc;sc;vc] .j.j flip `time`sym`value!(.gz.ms tc; string sc; vc)};

.gz.power:{
  if[not `gv_power in tables[]; :"[]"];
  .gz.long[gv_power`gvtime; gv_power`sym; gv_power`price] };

.gz.marginal:{
  if[not `gv_marginal in tables[]; :"[]"];
  .gz.long[gv_marginal`gvtime; gv_marginal`sym; gv_marginal`marginal] };

// Gas and carbon are the same for every plant, so one plant's rows are enough
// to recover the mark history without sending it eleven times over.
.gz.marks:{
  if[not `gv_marginal in tables[]; :"[]"];
  t:select from gv_marginal where sym=first sym;
  .j.j flip `time`gas`carbon!(.gz.ms t`gvtime; t`gas; t`carbon) };

.gz.index:{.j.j enlist[`paths]!enlist ("/gaz/power";"/gaz/marginal";"/gaz/marks")};

// Route a GET. q hands .z.ph the path without a leading slash, but accept both
// so a hand-typed URL behaves the same.
.gz.route:{[p]
  // Strip only a LEADING slash — `except` removes every one and would turn
  // "gaz/power" into "gazpower", so nothing matches.
  p:$["/"~first p; 1_p; p];
  $[p like "gaz/power*";    .gz.power[];
    p like "gaz/marginal*"; .gz.marginal[];
    p like "gaz/marks*";    .gz.marks[];
    p like "gaz*";          .gz.index[];
    ()] };


// Chain rather than replace: TorQ installs its own .z.ph for status pages, and
// .dotz.set keeps whatever was there for anything that is not ours.
.dotz.set[`.z.ph; {[f;x]
  r:@[.gz.route; first x; {[e] ()}];
  $[count r; .h.hy[`json] r; f x]
 }[@[value; .dotz.getcommand[`.z.ph]; {{[x] x}}]]];
