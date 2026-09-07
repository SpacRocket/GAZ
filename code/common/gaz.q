// Shared application library.
//
// $KDBAPPCODE/common is loaded into EVERY gaz process by .proc.reloadcode,
// so anything defined here is available in the feed, rdb, hdb and gateway
// alike. Keep it to pure functions — that is what makes it testable in
// isolation by tests/unit without standing up the stack.

\d .gaz

// --- units ---------------------------------------------------------------
//
// Deliberately here and not in database.q: that file is the tickerplant's
// -schemafile, and the STP treats every root table in it as a tick table to
// log. A keyed table with no `time` column makes init fail with a length
// error and the tickerplant crashloops. Metadata is not a tick table.
//
// European conventions throughout, and the two that actually change numbers:
//
//   * Gas is EUR/MWh thermal, NOT USD/MMBtu. Henry Hub quotes are per MMBtu;
//     TTF is per MWh. Mixing them is a factor of ~3.4 error.
//   * Efficiency is on a LOWER heating value basis, the European convention.
//     US sources quote HHV, which runs ~10% higher for natural gas — an
//     efficiency copied from an HHV source makes a plant look better than it
//     is, and the error lands straight in the marginal cost.
//
// Carbon is EUR per tonne CO2 (metric), never short tons.

units:2!flip `tab`col`unit`basis!flip (
  (`power ; `price      ; `$"EUR/MWh"      ; `electrical);
  (`gas   ; `price      ; `$"EUR/MWh"      ; `thermal_LHV);
  (`carbon; `price      ; `$"EUR/tCO2"     ; `allowance);
  (`bid   ; `price      ; `$"EUR/MWh"      ; `electrical);
  (`bid   ; `mw         ; `MW              ; `electrical);
  (`plants; `capacity   ; `MW              ; `electrical);
  (`plants; `efficiency ; `ratio           ; `LHV);
  (`plants; `ef         ; `$"tCO2/MWh"     ; `thermal);
  (`plants; `startup    ; `EUR             ; `per_start);
  (`plants; `fuelcap    ; `$"MWh"          ; `thermal_LHV);
  (`fuelmove; `mwh      ; `$"MWh"          ; `thermal_LHV))

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

// --- CCGT economics ------------------------------------------------------
//
// Everything here is EUR per MWh ELECTRICAL out. The conversions are where the
// mistakes live, so they are spelled out rather than folded together.
//
// Burning gas to make 1 MWh electrical consumes 1/eff MWh thermal, and that
// thermal burn emits ef tonnes of CO2 per MWh thermal. So BOTH the fuel and
// the carbon term divide by efficiency — a common slip is to divide only the
// fuel, which understates marginal cost by the whole carbon leg.
//
//   gas    EUR/MWh thermal   (TTF; per MWh, never per MMBtu)
//   carbon EUR/tCO2
//   ef     tCO2/MWh thermal  (natural gas ~0.202)
//   eff    ratio, LHV basis  (European convention; a US HHV figure is ~10% high)
//
// Vector-friendly in every argument, so it works on a whole delivery curve.

// What it costs you to generate one MWh.
marginalcost:{[gas;carbon;ef;eff] (gas + carbon*ef) % eff}

// Clean spark spread: what you make per MWh at a given power price.
// Positive means the unit is in the money for that period.
cleanspark:{[power;gas;carbon;ef;eff] power - .gaz.marginalcost[gas;carbon;ef;eff]}

// Dispatch signal. Deliberately ignores start-up cost: the simplification is
// that the unit runs at full load whenever the spread is positive. Revisit
// this if cycling is ever modelled, because a start is a real cost that a
// single positive period may not cover.
dispatch:{[power;gas;carbon;ef;eff] 0f < .gaz.cleanspark[power;gas;carbon;ef;eff]}

// --- fuel ----------------------------------------------------------------
//
// ENTSO-E day-ahead periods are quarter hours, so a plant offering `mw` MW for
// one period delivers mw*0.25 MWh electrical. Named rather than written as a
// bare 0.25 wherever it is needed: the same constant sets the offer curve
// length (96 periods) and the burn per period, and the two must not drift.
periodhours:0.25

// MWh THERMAL burnt to deliver `mw` MW electrical for `hours` hours at `eff`.
//
// The same efficiency conversion as marginalcost, in the other direction:
// making 1 MWh electrical consumes 1/eff MWh thermal. Vector-friendly in every
// argument so a whole 96-period offer curve costs one call.
//
// Note it takes HOURS, not periods. Passing a period count would silently
// under-burn by a factor of four, and the units table cannot catch that.
fuelburn:{[mw;hours;eff] (mw*hours) % eff}

// --- bucketing -----------------------------------------------------------

// Round timestamps down into buckets of width `w` (a timespan).
// e.g. bucket[0D00:05;t] -> five minute bars
bucket:{[w;t] `timestamp$w xbar `long$t}

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
