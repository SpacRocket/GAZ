// Single source of truth for the tick schema.
//
// Loaded by the segmented tickerplant via -schemafile, and by the unit tests.
// Every downstream process (rdb, wdb, hdb, feed) inherits its shape from here,
// so a column added below propagates without touching another file.

// --- the three legs of the clean spark spread ---------------------------
//
// Power, gas and carbon arrive asynchronously and at different cadences —
// that asymmetry is the point. The spread is computed by as-of joining the
// latest gas and carbon onto each power tick, so every table needs `time`
// (stamped by the tickerplant) and the `g#` attribute on its key column —
// that attribute is what keeps `where zone=`X` fast in the RDB.
//
// Prices are all EUR but the units differ and do not cancel: power and gas
// are per MWh, carbon is per tonne CO2. The spread calculation converts via
// plant efficiency and carbon intensity.
//
// `src` distinguishes a real feed from a simulated one — ENTSOE for power,
// SIM for gas and carbon, which have no free real-time source.

power:([]
  time    :`timestamp$();
  zone    :`g#`symbol$();    // ENTSO-E bidding zone: DE_LU, FR, NL, BE
  delivery:`timestamp$();    // start of the delivery period the price is for
  price   :`float$();        // EUR/MWh
  src     :`symbol$() )

gas:([]
  time :`timestamp$();
  hub  :`g#`symbol$();       // TTF, NBP
  price:`float$();           // EUR/MWh
  src  :`symbol$() )

carbon:([]
  time    :`timestamp$();
  contract:`g#`symbol$();    // EUA front-December
  price   :`float$();        // EUR/tCO2
  src     :`symbol$() )

// --- our own offers ------------------------------------------------------
//
// Bids go through the tickerplant like any other feed, which is what makes
// `time` meaningful here in a way it is not for power: an ENTSO-E row is
// stamped when we happened to poll, but a bid is stamped when it was actually
// submitted. That gives an audit trail for free — offers are append-only, so
// revising one before gate closure leaves both versions on the record and
// "what did we offer, and when did we change our mind" stays answerable.
//
// The effective offer for a delivery period is therefore the last row before
// gate closure (12:00 CET on T-1), not simply the last row:
//   select last price, last mw by plant, delivery from bid where time < gc
//
// Dispatch is an ordinary join against cleared prices on (zone;delivery) —
// not an as-of join. Both sides are keyed to delivery periods, not to
// arrival, so there is nothing to align in time.

bid:([]
  time    :`timestamp$();
  plant   :`g#`symbol$();    // unit offering
  zone    :`symbol$();       // bidding zone, matches power.zone
  delivery:`timestamp$();    // the period being offered, matches power.delivery
  mw      :`float$();        // volume offered
  price   :`float$();        // offer price EUR/MWh - your marginal cost
  ref     :`symbol$();       // submission id, ties these rows to their fuelmove
  src     :`symbol$() )      // MANUAL for a hand-entered offer

// --- fuel procurement ----------------------------------------------------
//
// THERE IS NO GAS STORED AT A POWER STATION. A CCGT does not have a tank; it
// takes gas off the transmission grid against a shipper portfolio. So the fuel
// position is a PORTFOLIO position, not a per-plant stock level, and every
// plant draws on the same one: .gaz.portfolio, TEST_UNIVERSAL_TTF.
//
// This table is the BOOK — what was bought, when, for which delivery window,
// and at what price. It is what makes a realised clean spark answerable: the
// spread against the market mark says whether the dispatch call was right, the
// spread against what you actually PAID says whether the procurement call was.
//
// `dfrom`/`dto` is the delivery window, `dto` EXCLUSIVE, matching the
// convention .gz.parseblocks uses for offer blocks. A trade struck today for
// November delivery sits on the book from the moment it is struck and lands in
// the pool at `dfrom` — which is the whole point of separating this from
// fuelmove. One row cannot be both "bought" and "in the pool" without the
// position being wrong for everything in between.
//
// NOT `from` and `to`. Both are qsql KEYWORDS: a column named `from` parses as
// the start of a from-clause, so `where from<=x` is a syntax error rather than
// a filter, and there is no way to quote your way out of it inside a select.
// The same trap is already worked around in .gz.bids, which aliases to
// `fromp`/`top` for exactly this reason.
//
// SIMPLIFICATION, and the one to revisit first: the volume lands in the pool
// ALL AT ONCE at `dfrom`, rather than pro-rating evenly across the window. That
// keeps every figure below a plain sum over a subset. A strip covering a month
// therefore reads as fully delivered on day one.
//
// `price` is EUR/MWh THERMAL, the same basis as gas.price, so the two are
// directly comparable — that difference IS the fuel P&L.
//
// Bid on the MARKET price, book against this one. Offering at your average
// book cost is the classic error: gas already bought can be resold, so the
// cost of burning it is the replacement cost, not what you happened to pay.

fueltrade:([]
  time     :`timestamp$();   // when the trade was struck
  portfolio:`g#`symbol$();   // TEST_UNIVERSAL_TTF - one pool, every plant
  hub      :`symbol$();      // TTF, matching gas.hub
  dfrom    :`timestamp$();   // delivery window start - when it lands in the pool
  dto      :`timestamp$();   // delivery window end, EXCLUSIVE
  mwh      :`float$();       // MWh THERMAL bought over the window
  price    :`float$();       // EUR/MWh THERMAL paid
  ref      :`symbol$();      // trade id
  src      :`symbol$() )     // MANUAL for a hand-entered trade

// --- fuel commitment -----------------------------------------------------
//
// An append-only LEDGER, not a balance. What each PLANT has committed against
// the shared pool and what it actually burnt. Deliveries are NOT here — they
// are trades, in fueltrade above.
//
// `mwh` is ALWAYS POSITIVE — a magnitude, never a signed delta. The `reason`
// carries the direction. Signing the quantity instead invites a negative row
// to be published by accident and read backwards, and makes the sum of the
// whole column meaningless.
//
// The pool position, every figure a clean sum over a subset:
//
//   delivered = sum fueltrade mwh where dfrom <= now
//   burnt     = sum BURN
//   physical  = delivered - burnt            gas the portfolio actually holds
//   reserved  = sum RESERVE - sum RELEASE    earmarked against open offers
//   available = physical - reserved          what may still be offered
//
// The three reasons, and the lifecycle they trace:
//
//   RESERVE   an offer is submitted; the fuel it would burn is earmarked so
//             the same MWh cannot be offered twice across the whole fleet
//   RELEASE   the offer did not clear, or was superseded; earmark returned
//   BURN      the offer cleared and the unit ran; fuel physically consumed
//
// A cleared bid produces BOTH a RELEASE (the earmark ends) and a BURN (the
// pool drops). Netting them into one row would leave `physical` unable to
// distinguish fuel that was burnt from fuel that was never committed.
//
// `price` is the COST STAMPED ON A BURN — the pool's weighted average cost of
// gas (WACOG) at the instant it was consumed, EUR/MWh thermal. Null on RESERVE
// and RELEASE, which move no gas and have no cost.
//
// Stamping it rather than deriving it later is what keeps the cost basis a
// SUM and not a scan. WACOG at any instant is (value delivered - value burnt)
// over (volume delivered - volume burnt); if a burn carried no price, working
// out what it cost would need the WACOG at that moment, which needs the burns
// before it, and so on back to the first trade. Writing the number down at the
// one moment it is known collapses the recursion.
//
// MWh THERMAL throughout, matching gas.price and fueltrade.price (EUR/MWh
// thermal, LHV) — NOT MWh electrical. .gaz.fuelburn does the efficiency
// conversion; see .gaz.units.

fuelmove:([]
  time    :`timestamp$();
  plant   :`g#`symbol$();    // the unit committing or burning
  delivery:`timestamp$();    // the offer period it relates to
  mwh     :`float$();        // MWh THERMAL, always positive - see above
  price   :`float$();        // EUR/MWh THERMAL, WACOG on a BURN; null otherwise
  reason  :`symbol$();       // RESERVE | RELEASE | BURN
  ref     :`symbol$();       // submission id, ties a RESERVE to its RELEASE/BURN
  src     :`symbol$() )
