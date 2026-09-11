// Loaded before every test run (via -load), for both unit and integration
// suites. Anything a .csv test row needs but shouldn't have to inline goes
// here — k4unit's `code` column is a single CSV field, so keep it short.
//
// .gaz.* is already present: $KDBAPPCODE/common is loaded into every TorQ
// process, this one included.

// The real schema, so schema tests assert against what actually ships.
system"l ",getenv`GAZ_SCHEMA;

\d .t

// A path that is guaranteed not to exist, for the "never written to" branch of
// .gaz.hdbdates. Deliberately not GAZ_HDB or GAZ_TPLOG: both hold files as
// soon as the stack has run once, which made that assertion pass only on a
// fresh checkout.
emptydir:`$getenv[`GAZ_TESTS],"/.does-not-exist";

// Compare floats without tripping over representation. k4unit `true` rows
// need an exact 1b, so never write `x=y` on floats in a test CSV.
eqf:{[x;y] all (abs x-y) < 1e-9};

// Weighted average cost of gas REMAINING in the pool, given delivered volumes
// and prices and burnt volumes and prices. The arithmetic .fuel.position does
// inline, extracted so a CSV row can assert it without a running stack.
//
// Value and volume both net the burns off: WACOG is the average cost of what
// is LEFT, not of everything ever bought. A pool that is empty has no average
// cost, so it is null rather than zero — zero would read as free gas.
wacog:{[dmwh;dpx;bmwh;bpx]
  v:(sum dmwh*dpx)-sum bmwh*bpx;
  q:(sum dmwh)-sum bmwh;
  $[q>1e-9; v%q; 0nf]};

// --- integration helpers -------------------------------------------------
// Only meaningful when the stack is up (make test-integration). Assertions
// live here rather than inline in the CSVs because k4unit's `code` column is
// one CSV field — keeping quotes and commas out of it avoids parser surprises.

conn:{[t] .servers.gethandlebytype[t;`any]};
ask :{[t;x] conn[t] x};                       // eval a q string on a process of type t

up      :{[t] not null conn t};

// The pool position's shape, asserted through the RDB. A dictionary of
// scalars, not a table: there is exactly ONE gas portfolio, so a row per plant
// would be the tank model coming back in.
poolshape:{[] `portfolio`hub`delivered`burnt`physical`reserved`available`wacog`forward~
  key ask[`rdb;".fuel.position[]"]};

// `available` belongs to the POOL and must never appear per plant — splitting
// it between units needs an allocation rule nobody has chosen.
noplantavail:{[] not any `available`physical`fuelcap in ask[`rdb;"cols .bid.byplant[]"]};

// Every figure in the position is a plain sum over a subset, so they must
// agree with each other at all times.
poolconsistent:{[]
  p:ask[`rdb;".fuel.position[]"];
  (eqf[p`physical; p[`delivered]-p`burnt]) and eqf[p`available; p[`physical]-p`reserved]};
hastables:{[t] all `power`gas`carbon in ask[t;"tables[]"]};
rows    :{[t;tab] ask[t;"count ",string tab]};

// Wait up to `s` seconds for a predicate to go true. Integration tests race
// the feed and the wdb timer; polling beats a fixed sleep.
until:{[s;f] w:.z.p+`second$s; while[(not f[]) and .z.p<w; system"sleep 0.2"]; f[]};

\d .
