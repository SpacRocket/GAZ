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

// --- fuel inventory ------------------------------------------------------
//
// An append-only LEDGER, not a balance. The level is derived by summing this
// table, for the same reason bids are append-only: "how much fuel did we have
// and what did we commit it to" stays answerable, and it replays from the
// tickerplant log like everything else. A mutable balance row would survive
// neither a replay nor the single-writer rule the HDB layout depends on.
//
// `mwh` is ALWAYS POSITIVE — a magnitude, never a signed delta. The `reason`
// carries the direction. Signing the quantity instead invites a negative
// DELIVERY to be published by accident and read as a burn, and makes the sum
// of the whole column meaningless. Each figure is a clean sum over a subset:
//
//   physical  = sum DELIVERY - sum BURN      what is actually in the tank
//   reserved  = sum RESERVE  - sum RELEASE   earmarked against open offers
//   available = physical - reserved          what you may still offer
//
// The four reasons, and the lifecycle they trace:
//
//   DELIVERY  gas arrives into storage
//   RESERVE   an offer is submitted; the fuel it would burn is earmarked so
//             the same MWh cannot be offered twice
//   RELEASE   the offer did not clear, or was superseded; earmark returned
//   BURN      the offer cleared and the unit ran; fuel physically consumed
//
// A cleared bid produces BOTH a RELEASE (the earmark ends) and a BURN (the
// stock drops). Netting them into one row would leave `physical` unable to
// distinguish fuel that was burnt from fuel that was never committed.
//
// MWh THERMAL throughout, matching gas.price (EUR/MWh thermal, LHV) — NOT MWh
// electrical. .gaz.fuelburn does the efficiency conversion; see .gaz.units.

fuelmove:([]
  time    :`timestamp$();
  plant   :`g#`symbol$();    // unit whose storage this moves
  delivery:`timestamp$();    // period it relates to; 0Np for a physical delivery
  mwh     :`float$();        // MWh THERMAL, always positive - see above
  reason  :`symbol$();       // DELIVERY | RESERVE | RELEASE | BURN
  ref     :`symbol$();       // submission id, ties a RESERVE to its RELEASE/BURN
  src     :`symbol$() )

