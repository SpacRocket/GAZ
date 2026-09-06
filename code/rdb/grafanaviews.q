// Grafana-facing views, refreshed on the RDB's timer.
//
// TorQ's grafana.q has ONE .grafana.timecol and ONE .grafana.sym for every
// table it exposes. That is fine until two charts want different axes: the
// power curve is price against `delivery` split by `zone`, while marginal cost
// is a cost against wall-clock `time` split by `plant`. Rather than fight it,
// both are reshaped to the same convention — a `time` column and a `sym`
// column — and grafana.q is left on its defaults.
//
// These are derived views, not tick tables: rebuilt here rather than published
// through the tickerplant, because nothing downstream consumes them and a
// chart does not need a recovery log.
//
// No `\d .gv` block. grafana.q discovers series with tables[], which lists
// ROOT tables only, so the views must live at root — under a namespace they
// become .gv.gv_power and Grafana never sees them. Functions are qualified
// explicitly instead.
//
// The time column is `gvtime`. Two reasons, both learned the hard way.
//
// It is not `time`, because grafana.q builds its series list by calling
// finddistinctsyms over every table carrying .grafana.timecol, and that reads
// a `sym` column the raw tick tables do not have — point timecol at `time` and
// /search dies with 'sym on power/gas/carbon/bid. A name only the views use
// keeps grafana.q looking exclusively at tables shaped for it.
//
// And it is not `gtime`, which was the first choice: `gtime` is a q BUILT-IN
// (the GMT/local time conversion pair with `ltime`), so a column of that name
// fails to even parse with 'assign.

// --- the views (root, so grafana.q can find them) ------------------------

gv_power  :([] gvtime:`timestamp$(); sym:`g#`symbol$(); price:`float$());

// `fuel` and `carboncost` are the two halves of `marginal`, both in EUR per
// MWh ELECTRICAL so they are comparable and additive — unlike the raw gas and
// carbon marks, which are per MWh thermal and per tonne CO2 respectively.
//   fuel       = gas / efficiency
//   carboncost = (carbon * ef) / efficiency
//   marginal   = fuel + carboncost
gv_marginal:([] gvtime:`timestamp$(); sym:`g#`symbol$();
                marginal:`float$(); fuel:`float$(); carboncost:`float$();
                gas:`float$(); carbon:`float$());

// The empty declaration above doubles as a schema template. gv_marginal is
// REBUILT on every sample from two parts (HDB history and the live buffer)
// rather than appended to, and `set` on a raze of freshly built tables would
// otherwise decide the column types from whatever the first part happened to
// hold — an empty history would leave a table of general lists.
.gv.mschema:gv_marginal;

// --- refresh -------------------------------------------------------------

.gv.period:0D00:00:10;

// How many LIVE samples to keep (.gv.live, the part of gv_marginal that this
// process computes itself). Marginal cost is sampled, not ticked, so this is
// a display buffer rather than a record — the tickerplant holds the inputs
// (gas, carbon), and everything before today's partition comes back off the
// HDB in .gv.refreshmarks. It bounds the live tail only.
.gv.maxrows:5000;

// --- history from the HDB ------------------------------------------------
//
// The power chart is served from the RDB, which by definition holds only what
// has arrived since the last EOD. That made the panel a one-day window onto a
// series whose whole point is the shape of the forward curve over time. So the
// RDB reaches back into the HDB and serves the union.
//
// The RDB does the reaching, not Grafana. Grafana stays pointed at one host
// (see docker/grafana/provisioning/datasources/kdb.yml) and the gateway holds
// no tables of its own to chart, so pulling history in here keeps the serving
// path unchanged — .gz.power still just reads gv_power.

// How many PARTITIONS back to pull. Partitions are keyed on ingestion date,
// not delivery, so this bounds the scan and not the span of the curve: one
// backfilled partition can carry years of delivery periods.
.gv.histdays:30;

// The HDB only changes at EOD, so this is cached rather than re-queried on
// every view refresh. Five minutes is far inside that, and day-ahead history
// appearing five minutes late means nothing.
.gv.histperiod:0D00:05;

// Cached HDB slice, pre-aggregated so the 10-second view refresh only has to
// merge it. Deliberately in .gv and NOT at root: tables[] lists root tables
// only and everything it lists is discovered as a Grafana series — this is an
// input to gv_power, not a view in its own right.
.gv.hist:([] src:`symbol$(); zone:`symbol$();
             delivery:`timestamp$(); price:`float$());

// An open handle to the HDB, or 0Ni if there is not one. Every HDB pull below
// goes through here, and every one of them is guarded: a missing HDB, an HDB
// with no partitions yet, or a failed query must leave the live charts serving
// intraday data rather than taking the timer down with it.
.gv.hdbhandle:{
  // .[f;args;err], NOT @[f;args;err]. `@` applies its second argument as ONE
  // argument, so @[gethandlebytype;(`hdb;`any);0Ni] silently binds h to a
  // PROJECTION rather than a handle — it does not error, `null` on it is
  // false, and the query then fails into the error branch. The cache just
  // stays empty and the chart quietly shows intraday only.
  h:.[.servers.gethandlebytype;(`hdb;`any);0Ni];
  // An open handle is an int ATOM (type -6h); 0Ni, meaning no hdb is up, is
  // one too. Anything else means the lookup did not return a handle at all,
  // and calling it would be the projection bug above all over again.
  $[(type h) in -6 -7h; h; 0Ni] }

.gv.refreshhist:{
  h:.gv.hdbhandle[];
  if[null h; :0];
  q:"select price:last price by src,zone,delivery from power where date>=",
    string .z.D - .gv.histdays;
  r:@[h; q; ()];
  if[not count r; :0];
  // Backtick, not a bare name. `set` takes a SYMBOL on the left; given the
  // table's value instead it neither assigns nor errors — the cache stays
  // empty for ever and the only symptom is a chart with no history on it.
  `.gv.hist set 0!r;
  count .gv.hist }

// Power curve against delivery. Prefers real cleared prices, falls back to the
// simulator — the same rule .spread.curve uses.
.gv.refreshpower:{
  // App code loads BEFORE the process subscribes to the tickerplant, so the
  // tick tables do not exist yet at load time. Everything here is guarded and
  // driven off the timer rather than run on load.
  if[not `power in tables[]; :0];
  t:0!select price:last price by src,zone,delivery from power;
  // History first, intraday second: `last` takes the later row, so anything
  // the RDB holds wins over the same (src;zone;delivery) read from disk. They
  // should not normally overlap — the HDB holds past partitions and the RDB
  // today's — but a backfill publishes old delivery periods under today's
  // ingestion date, which is exactly the case where they can.
  t:0!select price:last price by src,zone,delivery from .gv.hist upsert t;
  // The ENTSOE/SIM choice is applied ONCE, to the merged series. Deciding it
  // per source would let a day of simulated history sit next to a day of real
  // prices on the same line.
  e:select from t where src=`ENTSOE;
  if[0=count e; e:select from t where src=`SIM];
  `gv_power set `gvtime xasc select gvtime:delivery, sym:zone, price from e;
  count gv_power }

// --- marginal cost -------------------------------------------------------
//
// gv_marginal is assembled from two parts, because the two halves of the
// series come from different places:
//
//   .gv.histmarginal  everything up to the last EOD, recomputed from the gas
//                     and carbon marks read back out of the HDB
//   .gv.live          today, sampled off the RDB's in-memory marks every
//                     .gv.period
//
// Marginal cost is not a tick table — nothing publishes it, this process
// derives it — so unlike gv_power there is no stored history to read back.
// What the HDB does hold is the two INPUTS, and marginal cost is a pure
// function of them, so the history is rebuilt rather than recovered. That is
// also why editing an efficiency in plants.csv retroactively changes the
// chart: .gaz.plants is a snapshot, not a slowly-changing dimension (see
// code/common/plants.q).

// Bucket width for the historical marks. The marks tick every few seconds —
// gas at 4.3s, carbon at 9.1s — so a raw pull of .gv.histdays partitions is
// on the order of a million rows, and every one of them would be crossed with
// eleven plants and then serialised to JSON on every dashboard refresh.
// Hourly over 30 days is 720 buckets x 11 plants, which is a chart rather
// than a download, and marginal cost has no intraday shape worth more.
.gv.markbucket:0D01:00;

// The aligned mark history: one row per bucket, both marks on the same axis.
// In .gv and NOT at root, for the same reason as .gv.hist — tables[] lists
// root tables only and everything it lists becomes a Grafana series.
.gv.marks:([] gvtime:`timestamp$(); gas:`float$(); carbon:`float$());

// gv_marginal's two parts, likewise kept out of root.
.gv.histmarginal:.gv.mschema;
.gv.live:.gv.mschema;

// Cross a mark history with every plant. Shared by the history rebuild and
// (with a single-row t) the live sample, so the arithmetic exists once.
.gv.expand:{[t]
  p:0!.gaz.plants;
  .gv.mschema, raze {[t;pl]
    f:t[`gas] % pl`efficiency;           // fuel leg,   EUR/MWh electrical
    cc:(t[`carbon] * pl`ef) % pl`efficiency;  // carbon leg, EUR/MWh electrical
    ([] gvtime:t`gvtime; sym:count[t]#pl`plant;
        marginal:f+cc; fuel:f; carboncost:cc;
        gas:t`gas; carbon:t`carbon) }[t] each p }

// Pull the gas and carbon marks back out of the HDB and rebuild the history.
.gv.refreshmarks:{
  h:.gv.hdbhandle[];
  if[null h; :0];
  b:string .gv.markbucket;
  d:string .z.D - .gv.histdays;
  // `date` first so the partition constraint prunes before anything else, and
  // .gaz.bucket fully qualified — inside a select, names resolve against the
  // root namespace at runtime, not the \d context the file was loaded under.
  // The HDB has code/common loaded like every other process, so it has it.
  g:@[h; "select gas:last price by gvtime:.gaz.bucket[",b,";time] ",
         "from gas where date>=",d,", hub=`TTF"; ()];
  c:@[h; "select carbon:last price by gvtime:.gaz.bucket[",b,";time] ",
         "from carbon where date>=",d; ()];
  if[(0=count g) or 0=count c; :0];
  // aj, not a join on gvtime: the two feeds are independent and neither is
  // guaranteed to have marked in a given bucket. Gas is the spine (it is the
  // faster of the two) and carbon is carried forward as-of, which is what a
  // desk means by "the mark" anyway. Buckets before the first carbon tick get
  // a null and are dropped rather than charted as a fuel-only cost.
  m:aj[`gvtime; `gvtime xasc 0!g; `gvtime xasc 0!c];
  m:select from m where not null gas, not null carbon;
  if[0=count m; :0];
  // Backtick on the left of `set` — it takes a SYMBOL. Given the table's
  // value it neither assigns nor errors, and the history stays empty for ever.
  `.gv.marks set m;
  `.gv.histmarginal set .gv.expand m;
  // Rebuild here too, not just from the sampler. If the RDB has not subscribed
  // yet — or the marks stop ticking — samplemarginal returns early and never
  // calls it, and gv_marginal would sit empty with a perfectly good history
  // already loaded next to it.
  .gv.rebuildmarginal[];
  count .gv.histmarginal }

// Rebuild gv_marginal from its two parts. History first, live second, so
// `last fuel by sym` in .gz.split picks up today rather than the last EOD.
//
// The live buffer WINS over history wherever the two cover the same instant.
// Normally they cannot: the HDB holds partitions up to the last EOD and the
// buffer holds since. But an EOD forced mid-session promotes today's marks to
// disk while the buffer still holds them, and then the same hours arrive twice
// at two different resolutions — hourly from .gv.marks, ten-second from
// .gv.live — and the plant's line doubles back on itself. Cutting history at
// the buffer's first sample makes the overlap impossible to draw rather than
// relying on the roll never being forced.
//
// The `g#` is reapplied because neither `,` nor `xasc` carries an attribute
// across — without it gv_marginal would quietly not have the attribute its own
// declaration promises, and .gz.split's group-by would scan. `g#` needs no
// sort order, so it survives the xasc on gvtime.
.gv.rebuildmarginal:{
  h:.gv.histmarginal;
  if[count .gv.live; h:select from h where gvtime < min .gv.live`gvtime];
  `gv_marginal set @[`gvtime xasc h, .gv.live; `sym; `g#];
  count gv_marginal }

// One live sample: marginal cost per MWh electrical, one row per plant.
//
// A COST PER UNIT, not the cost of running the unit — capacity is deliberately
// not a factor. (gas + carbon*ef) / efficiency, all per MWh; see .gaz.units
// and .gaz.marginalcost for why both the fuel and the carbon term divide by
// efficiency rather than just the fuel.
.gv.samplemarginal:{
  if[not all `gas`carbon in tables[]; :0];
  g:last exec price from gas where hub=`TTF;
  c:last exec price from carbon;
  if[(null g) or null c; :0];          // nothing marked yet, nothing to sample
  `.gv.live upsert .gv.expand ([] gvtime:1#.z.p; gas:1#g; carbon:1#c);
  // NEGATIVE sublist. `n sublist t` keeps the FIRST n rows, so trimming with a
  // positive count pins the buffer to its oldest rows: once it fills, every
  // later sample is appended and then immediately cut away again and the
  // chart stops advancing. Eleven plants at .gv.period filled 5000 rows in
  // about seventy-five minutes, which is why it looked like a stall and not a
  // bug. `neg n sublist t` keeps the LAST n, which is the tail we want.
  if[.gv.maxrows<count .gv.live;
    `.gv.live set neg[.gv.maxrows] sublist .gv.live];
  .gv.rebuildmarginal[] }

.gv.refresh:{ .gv.refreshpower[]; .gv.samplemarginal[]; }

// Timer only — see refreshpower for why this cannot run at load time. The
// first tick lands within .gv.period of startup.
.timer.repeat[.proc.cp[]; 0Wp; .gv.period; (`.gv.refresh;`); "refresh grafana views"];

// The HDB pulls are on their own, much slower timer — they are disk reads over
// IPC against data that only changes at EOD, so running them at .gv.period
// would be pure waste. Separate from .gv.refresh for that reason alone.
//
// Each is trapped SEPARATELY. They are independent charts sharing a timer, so
// a signal out of one — a schema change the query no longer matches, say —
// must not cost the other its refresh for the rest of the process's life.
// Everything inside them is already guarded against the ordinary cases (no
// HDB, no partitions, an empty result); this catches the unforeseen one and
// logs it rather than letting it escape into .timer.
//
// @[f;::;h], not .[f;();h]. A niladic q function still takes one argument, the
// null `::`, so an empty argument LIST is a rank error — and trapped, that
// rank error is all you ever see: every refresh reports 'type and neither
// query is ever actually run.
.gv.trap:{[f;nm] @[f; ::; {[nm;e] .lg.e[`grafanaviews; nm," failed: ",e]; 0}[nm]] }

.gv.refreshhistory:{
  .gv.trap[.gv.refreshhist;  "hdb power history refresh"];
  .gv.trap[.gv.refreshmarks; "hdb mark history refresh"]; }

.timer.repeat[.proc.cp[]; 0Wp; .gv.histperiod; (`.gv.refreshhistory;`); "refresh grafana hdb history"];
