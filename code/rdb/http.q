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
//   GET /gaz/fuel      the fuel leg of marginal cost, by plant
//   GET /gaz/carbon    the carbon leg of marginal cost, by plant
//   GET /gaz/split     latest fuel/carbon split per plant (for a bar chart)
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

.gz.fuel:{
  if[not `gv_marginal in tables[]; :"[]"];
  .gz.long[gv_marginal`gvtime; gv_marginal`sym; gv_marginal`fuel] };

.gz.carbonleg:{
  if[not `gv_marginal in tables[]; :"[]"];
  .gz.long[gv_marginal`gvtime; gv_marginal`sym; gv_marginal`carboncost] };

// Latest sample per plant, as a non-time frame: one row per plant with the two
// legs side by side. Shaped for a stacked bar chart, where the question is
// "how much of THIS plant's cost is carbon" rather than how it moved.
.gz.split:{
  if[not `gv_marginal in tables[]; :"[]"];
  t:0!select last fuel, last carboncost by sym from gv_marginal;
  .j.j flip `sym`fuel`carbon!(string t`sym; t`fuel; t`carboncost) };

.gz.index:{.j.j enlist[`paths]!enlist ("/gaz/power";"/gaz/marginal";"/gaz/marks";"/gaz/fuel";"/gaz/carbon";"/gaz/split")};

// Route a GET. q hands .z.ph the path without a leading slash, but accept both
// so a hand-typed URL behaves the same.
.gz.route:{[p]
  // Strip only a LEADING slash — `except` removes every one and would turn
  // "gaz/power" into "gazpower", so nothing matches.
  p:$["/"~first p; 1_p; p];
  $[p like "gaz/power*";    .gz.power[];
    p like "gaz/marginal*"; .gz.marginal[];
    p like "gaz/marks*";    .gz.marks[];
    p like "gaz/fuel*";     .gz.fuel[];
    p like "gaz/carbon*";   .gz.carbonleg[];
    p like "gaz/split*";    .gz.split[];
    p like "gaz*";          .gz.index[];
    ()] };


// Chain rather than replace: TorQ installs its own .z.ph for status pages, and
// .dotz.set keeps whatever was there for anything that is not ours.
.dotz.set[`.z.ph; {[f;x]
  r:@[.gz.route; first x; {[e] ()}];
  $[count r; .h.hy[`json] r; f x]
 }[@[value; .dotz.getcommand[`.z.ph]; {{[x] x}}]]];

// =========================================================================
// Bidding — read endpoints for context, and a POST to submit.
//
//   GET  /gaz/store        fuel inventory per plant (physical/reserved/available)
//   GET  /gaz/grid         96-period offer grid for ?plant=&date=
//   GET  /gaz/bids         offers submitted, most recent first
//   POST /gaz/submit       submit an offer curve
//
// `/gaz/store`, NOT `/gaz/fuelstore`. The route chain above matches
// `gaz/fuel*` for the fuel LEG of marginal cost, and `like` would swallow
// `gaz/fuelstore` into it. Ordering the specific route first would also work
// and would break silently the first time someone reordered the chain; a
// prefix that cannot collide is the safer of the two.

// CORS. Grafana runs on :3000 and this serves :6002, so a panel that talks to
// us directly is cross-origin. .h.hy does not emit the header, so responses
// below are built by hand.
//
// Preflight. By DEFAULT q answers OPTIONS with 501 Not Implemented — .z.ph and
// .z.pp cover GET and POST only — so a preflighted browser request never
// arrives, and the failure is invisible from the server: nothing is logged
// because nothing was ever handled.
//
// .z.pm is the hook. It takes (method; path; headers) and catches the methods
// the other two do not, OPTIONS among them. It is not defined until you set it,
// which is why `\`pm in key \`.z` reads false on a process that has never
// installed one — absence there is not evidence the build lacks support.
//
// With the handler below a preflighted request works, so the Content-Type no
// longer has to stay inside the CORS "simple request" set. It is still sent as
// text/plain by the panel, which avoids the preflight round trip entirely.
.gz.cors:"Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\n";

.gz.ok:{"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",.gz.cors,"\r\n",x};
.gz.bad:{"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n",.gz.cors,"\r\n",
         .j.j enlist[`error]!enlist x};

// Fuel inventory. `pct` saves every panel doing the division itself.
.gz.store:{
  t:.bid.state[];
  .j.j update pct:100f*available%fuelcap from
    select plant:string plant, zone:string zone, capacity, efficiency,
           fuelcap, physical, reserved, available from t };

// --- query strings -------------------------------------------------------
// "gaz/grid?plant=Sloe&date=2026-09-08" -> `plant`date!("Sloe";"2026-09-08")
.gz.args:{[p]
  i:p?"?";
  if[i=count p; :()!()];
  kv:"&" vs (i+1)_p;
  kv:kv where 0<count each kv;
  // Split each pair at its FIRST "=" only: a value may legitimately contain
  // one, and "=" vs would shred it into three pieces.
  (`$ {(x?"=")#x} each kv) ! {1_(x?"=")_x} each kv };

// The 96 quarter-hours of a delivery date, with the marginal cost of the plant
// as a suggested floor and whatever is currently offered alongside it.
//
// The suggestion is `marginal`, not a price with a margin on it: what to add is
// a trading decision, and a UI that pre-loads a profit assumption invites it to
// be sent unread.
.gz.grid:{[a]
  // An unresolved dashboard variable arrives literally as "$plant". Answer
  // that with an empty 200, not a 400: Infinity turns any non-2xx into a panel
  // ERROR, so a variable that has not been substituted yet during dashboard
  // load would flash a failure that looks like a broken endpoint. "No data" is
  // the honest answer to "no plant selected". A genuine typo still 400s, so a
  // real mistake is not swallowed.
  raw:a[`plant];
  if[(0=count raw) or "$"~first raw; :"[]"];
  pl:`$raw;
  if[not pl in exec plant from .gaz.plants; '"unknown plant: ",raw];
  d:"D"$a[`date];
  if[null d; '"bad or missing date - expected YYYY-MM-DD"];
  rec:.gaz.plants pl;
  periods:("p"$d)+0D00:15*til 96;

  // Latest marks, same source .gv.samplemarginal uses.
  g:$[`gas in tables[]; last exec price from gas where hub=`TTF; 0nf];
  c:$[`carbon in tables[]; last exec price from carbon; 0nf];
  mc:.gaz.marginalcost[g;c;rec`ef;rec`efficiency];

  // What stands for these periods already. Offers are append-only, so the
  // effective one is the LAST row per period, not simply any row.
  b:$[`bid in tables[]; 0!select mw:last mw, price:last price by delivery from bid
        where plant=pl; ([] delivery:`timestamp$(); mw:`float$(); price:`float$())];
  cur:periods!count[periods]#0nf;
  curmw:periods!count[periods]#0nf;
  if[count b; cur:cur,(b`delivery)!b`price; curmw:curmw,(b`delivery)!b`mw];

  // Open reservation per period, so the grid can show what each row is holding.
  op:.bid.open[pl];
  res:periods!count[periods]#0f;
  if[count op; res:res,(op`delivery)!op`mwh];

  .j.j flip `time`period`delivery`marginal`price`mw`reserved!(
    .gz.ms periods;
    til 96;
    string periods;
    count[periods]#.gaz.rnd[2;mc];
    cur periods;
    curmw periods;
    res periods) };

// Offers submitted, newest first. One row per period is far too much to chart,
// so this is grouped to the submission that produced it — which is also the
// unit a person actually thinks in ("the curve I sent at 11:40").
.gz.bids:{
  if[not `bid in tables[]; :"[]"];
  if[0=count bid; :"[]"];
  t:0!select time:last time, periods:count i, mw:avg mw, price:avg price,
             fromp:min delivery, top:max delivery
      by ref, plant, zone from bid;
  t:`time xdesc t;
  .j.j flip `time`ref`plant`zone`periods`mw`price`from`to!(
    .gz.ms t`time; string t`ref; string t`plant; string t`zone;
    t`periods; .gaz.rnd[1;t`mw]; .gaz.rnd[2;t`price];
    string t`fromp; string t`top) };

// --- submit --------------------------------------------------------------
//
// Body is JSON. Two shapes, because a form and a grid want different things:
//
//   {"plant":"Sloe","date":"2026-09-08","mw":400,"price":82.5}
//     the whole day at one price
//
//   {"plant":"Sloe","date":"2026-09-08",
//    "blocks":[{"from":"06:00","to":"20:00","mw":400,"price":82.5}, ...]}
//     time ranges, which is how a desk actually offers
//
// `to` is EXCLUSIVE. A block 06:00-07:00 is four periods, not five; treating it
// as inclusive silently offers an extra quarter-hour at the end of every block.
.gz.parseblocks:{[d;bl]
  raze {[d;b]
    // "N"$, NOT "V"$. Both parse "06:00", but "V" yields a SECOND whose
    // underlying value is 21600 — and `timespan$ on that reads 21600 as
    // NANOseconds, putting the block 21 microseconds after midnight instead of
    // at six in the morning. "N" parses straight to a timespan.
    f:"N"$b`from; t:"N"$b`to;
    if[any null(f;t); '"block needs from and to as HH:MM"];
    if[t<=f; '"block `to` must be after `from`"];
    p:("p"$d)+f+0D00:15*til `long$(t-f)%0D00:15;
    ([] delivery:p; mw:count[p]#"f"$b`mw; price:count[p]#"f"$b`price) }[d] each bl };

// A THIRD shape, and the one the Grafana panel actually sends:
//
//   {"plant":"Sloe","biddate":"2026-09-08","from":"06:00","to":"10:00",
//    "mw":400,"price":85}
//
// Business Forms posts a flat {elementId: value} object when payloadMode is
// "all". Accepting that directly is deliberate: the alternative is custom
// JavaScript in the panel to reshape it, and that JS runs only in a browser —
// it cannot be tested from here, and a typo in it fails silently with nothing
// sent and nothing logged. Server-side shaping is testable with curl.
//
// `biddate` as well as `date` because the form element is named biddate to
// match the dashboard variable.
.gz.submit:{[body]
  r:@[.j.k; body; {'"body is not valid JSON: ",x}];
  if[not `plant in key r; '"need plant"];
  pl:`$r[`plant];
  dk:$[`date in key r; `date; `biddate];
  if[not dk in key r; '"need date (or biddate)"];
  d:"D"$r dk;
  if[null d; '"bad date - expected YYYY-MM-DD"];

  t:$[`blocks in key r;
      // explicit blocks: [{from,to,mw,price}, ...]
      .gz.parseblocks[d;r`blocks];
    all `from`to in key r;
      // flat single block, as the form panel sends it
      .gz.parseblocks[d; enlist `from`to`mw`price!(r`from;r`to;r`mw;r`price)];
      // neither: the whole delivery day at one price
      [p:("p"$d)+0D00:15*til 96;
       ([] delivery:p; mw:count[p]#"f"$r`mw; price:count[p]#"f"$r`price)]];
  if[0=count t; '"no periods to submit"];
  .bid.submit[pl; t`delivery; t`mw; t`price] };

.gz.route2:{[p;body]
  p:$["/"~first p; 1_p; p];
  a:.gz.args p;
  base:(p?"?")#p;
  // Handlers return a JSON BODY, or signal. Wrapping happens here and only
  // here — an earlier version had .gz.grid return a full response which this
  // then wrapped a second time, putting the status line and headers inside the
  // body. One place decides what an HTTP response looks like.
  $[base like "gaz/store*";  @[{.gz.ok .gz.store[]};   ::;   {.gz.bad x}];
    base like "gaz/grid*";   @[{.gz.ok .gz.grid x};    a;    {.gz.bad x}];
    base like "gaz/bids*";   @[{.gz.ok .gz.bids[]};    ::;   {.gz.bad x}];
    base like "gaz/submit*"; @[{.gz.ok .j.j .gz.submit x}; body; {.gz.bad x}];
    ()] };

// GET for the read endpoints, chained ahead of the existing .z.ph so the
// original /gaz/* routes are untouched.
.dotz.set[`.z.ph; {[f;x]
  r:@[{.gz.route2[x;""]}; first x; {[e] ()}];
  $[count r; r; f x]
 }[@[value; .dotz.getcommand[`.z.ph]; {{[x] x}}]]];

// OPTIONS, and anything else that is neither GET nor POST. A browser sends this
// before a cross-origin POST it considers non-simple, and refuses to send the
// POST at all unless the answer allows the origin, method and headers.
//
// 204 with no body is the conventional answer; Content-Length: 0 is explicit so
// no client waits on a body that never comes.
.dotz.set[`.z.pm; {[f;x]
  $[`OPTIONS~first x;
    "HTTP/1.1 204 No Content\r\n",.gz.cors,
      "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nContent-Length: 0\r\n\r\n";
    f x] }[@[value; .dotz.getcommand[`.z.pm]; {{[x] "HTTP/1.1 501 Not Implemented\r\nContent-Length: 0\r\n\r\n"}}]]];

// POST. q hands .z.pp the PATH AND BODY CONCATENATED WITH A SPACE in x[0] —
// not as separate arguments, and not with the body in the header dict. So the
// first space is the separator and everything after it is the payload.
.dotz.set[`.z.pp; {[f;x]
  s:first x;
  i:s?" ";
  p:i#s;
  b:$[i=count s; ""; (i+1)_s];
  // .[f;(a;b);e], NOT @[f;(a;b);e]. `@` applies the pair as ONE argument, so
  // route2 receives the list as its path and never gets a body — the failure
  // surfaces as a bare 'type with no clue where it came from. The same trap
  // CLAUDE.md records against .servers.gethandlebytype.
  r:.[.gz.route2; (p;b); {[e] .gz.bad "unhandled: ",e}];
  $[count r; r; f x]
 }[@[value; .dotz.getcommand[`.z.pp]; {{[x] .gz.bad "no route"}}]]];
