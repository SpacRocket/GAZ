// Shared application library.
//
// $KDBAPPCODE/common is loaded into EVERY gaz process by .proc.reloadcode,
// so anything defined here is available in the feed, rdb, hdb and gateway
// alike. Keep it to pure functions — that is what makes it testable in
// isolation by tests/unit without standing up the stack.

\d .gaz

// --- reference data ------------------------------------------------------
syms:`AAPL`MSFT`GOOG`AMZN`NVDA`META`TSLA`AMD`INTC`IBM

// Seed prices, used by the feed and by tests that need a deterministic base.
refprice:syms!33 27 84 12 20 72 36 51 42 29f

exchanges:"NLOB"          // NYSE, Nasdaq, other, BATS
sources  :`BARX`GETGO`SUN`DB
sides    :`buy`sell

// --- pricing -------------------------------------------------------------

// Mid price from a bid/ask pair. Vector-friendly.
mid:{[b;a] 0.5*b+a}

// Absolute spread.
spread:{[b;a] a-b}

// Spread in basis points of the mid. Null where the mid is zero, rather than
// returning an infinity that would poison a downstream avg.
spreadbps:{[b;a] m:mid[b;a]; ?[m=0f; 0nf; 10000f*(a-b)%m]}

// Volume weighted average price. 0n for an empty input rather than 0n%0n.
vwap:{[p;s] $[0=count p; 0nf; 0=t:sum s; 0nf; (sum p*s)%t]}

// Round to n decimal places.
rnd:{[n;x] m:"f"$prd n#10; (floor 0.5+x*m)%m}

// --- bucketing -----------------------------------------------------------

// Round timestamps down into buckets of width `w` (a timespan).
// e.g. bucket[0D00:05;t] -> five minute bars
bucket:{[w;t] `timestamp$w xbar `long$t}

// OHLC bars over a trade table, bucketed by `w`.
// Returns a keyed table on (sym;time).
//
// The names inside a qsql expression are resolved against the root namespace
// at runtime, NOT against the \d context this file was loaded under — so
// `bucket` and `vwap` must be fully qualified here even though they are
// defined two lines up.
ohlc:{[w;t]
  select open:first price, high:max price, low:min price, close:last price,
         volume:sum size, vwap:.gaz.vwap[price;size]
    by sym, time:.gaz.bucket[w;time] from t }

// --- validation ----------------------------------------------------------
// Used by the feed before publishing and available to a data-quality process.
// Returns a boolean vector, one per row.

validtrade:{[t]
  (not null t`time) and (not null t`sym) and (t[`price]>0f) and t[`size]>0i }

validquote:{[q]
  (not null q`time) and (not null q`sym) and (q[`bid]<=q`ask)
    and (q[`bid]>0f) and q[`asize]>=0j }

// --- partitions ----------------------------------------------------------

// Dates actually present in an on-disk database. Empty list if it has never
// been written to, which is the normal state on a fresh checkout.
// (`key` on a never-written directory returns an untyped empty list, so test
// the count rather than matching against ().)
//
// Anything that does not parse as a date is dropped, not returned as 0Nd — a
// database root also holds `sym`, `par.txt` and (on a Mac) .DS_Store, and a
// tplog directory holds none but stp-prefixed names. Returning a null date
// for those silently poisons any `min`/`max` taken over the result.
hdbdates:{[d]
  if[0=count k:key hsym d; :`date$()];
  asc dt where not null dt:"D"$string k except `sym }

\d .
