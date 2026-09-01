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

// --- refresh -------------------------------------------------------------

.gv.period:0D00:00:10;

// How much marginal-cost history to keep. It is sampled, not ticked, so this
// is a display buffer rather than a record — the tickerplant holds the inputs
// (gas, carbon) if the series ever needs rebuilding.
.gv.maxrows:5000;

// Power curve against delivery. Prefers real cleared prices, falls back to the
// simulator — the same rule .spread.curve uses.
.gv.refreshpower:{
  // App code loads BEFORE the process subscribes to the tickerplant, so the
  // tick tables do not exist yet at load time. Everything here is guarded and
  // driven off the timer rather than run on load.
  if[not `power in tables[]; :0];
  t:0!select price:last price by src,zone,delivery from power;
  e:select from t where src=`ENTSOE;
  if[0=count e; e:select from t where src=`SIM];
  `gv_power set `gvtime xasc select gvtime:delivery, sym:zone, price from e;
  count gv_power }

// Marginal cost per MWh electrical, one row per plant per sample.
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
  p:0!.gaz.plants;
  n:count p;
  f:g % p`efficiency;                    // fuel leg,   EUR/MWh electrical
  cc:(c * p`ef) % p`efficiency;          // carbon leg, EUR/MWh electrical
  `gv_marginal upsert ([] gvtime:n#.z.p; sym:p`plant;
                          marginal:f+cc; fuel:f; carboncost:cc;
                          gas:n#g; carbon:n#c);
  if[.gv.maxrows<count gv_marginal;
    `gv_marginal set .gv.maxrows sublist gv_marginal];
  n }

.gv.refresh:{ .gv.refreshpower[]; .gv.samplemarginal[]; }

// Timer only — see refreshpower for why this cannot run at load time. The
// first tick lands within .gv.period of startup.
.timer.repeat[.proc.cp[]; 0Wp; .gv.period; (`.gv.refresh;`); "refresh grafana views"];
