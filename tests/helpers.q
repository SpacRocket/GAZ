// Loaded before every test run (via -load), for both unit and integration
// suites. Anything a .csv test row needs but shouldn't have to inline goes
// here — k4unit's `code` column is a single CSV field, so keep it short.
//
// .gaz.* is already present: $KDBAPPCODE/common is loaded into every TorQ
// process, this one included.

// The real schema, so schema tests assert against what actually ships.
system"l ",getenv`GAZ_SCHEMA;

\d .t

// Deterministic sample data — no rand, so expected values in the CSVs stay
// stable across runs. This is the difference between a test suite and a
// flaky one.
d:2026.08.10D09:30:00.000000000;

trades:([]
  time :d+0D00:00:01*til 6;
  sym  :`AAPL`AAPL`MSFT`AAPL`MSFT`MSFT;
  price:100 102 50 104 52 54f;
  size :100 200 300 100 200 300i;
  side :`buy`sell`buy`buy`sell`sell;
  ex   :"NNLNLL";
  cond :"      ";
  src  :6#`BARX );

quotes:([]
  time :d+0D00:00:01*til 4;
  sym  :`AAPL`AAPL`MSFT`MSFT;
  bid  :99.5 101.5 49.5 51.5;
  ask  :100.5 102.5 50.5 52.5;
  bsize:100 200 300 400j;
  asize:100 200 300 400j;
  ex   :"NNLL";
  src  :4#`BARX );

// A path that is guaranteed not to exist, for the "never written to" branch of
// .gaz.hdbdates. Deliberately not GAZ_HDB or GAZ_TPLOG: both hold files as
// soon as the stack has run once, which made that assertion pass only on a
// fresh checkout.
emptydir:`$getenv[`GAZ_TESTS],"/.does-not-exist";

// Compare floats without tripping over representation. k4unit `true` rows
// need an exact 1b, so never write `x=y` on floats in a test CSV.
eqf:{[x;y] all (abs x-y) < 1e-9};

// Do two tables have the same columns and types? Used by the schema tests to
// catch a column added to database.q but not to a downstream consumer.
sametype:{[x;y] (cols[x]~cols y) and (0!meta x)[`t] ~ (0!meta y)[`t]};

// --- integration helpers -------------------------------------------------
// Only meaningful when the stack is up (make test-integration). Assertions
// live here rather than inline in the CSVs because k4unit's `code` column is
// one CSV field — keeping quotes and commas out of it avoids parser surprises.

conn:{[t] .servers.gethandlebytype[t;`any]};
ask :{[t;x] conn[t] x};                       // eval a q string on a process of type t

up      :{[t] not null conn t};
hastables:{[t] all `trade`quote in ask[t;"tables[]"]};
rows    :{[t;tab] ask[t;"count ",string tab]};

// Wait up to `s` seconds for a predicate to go true. Integration tests race
// the feed and the wdb timer; polling beats a fixed sleep.
until:{[s;f] w:.z.p+`second$s; while[(not f[]) and .z.p<w; system"sleep 0.2"]; f[]};

\d .
