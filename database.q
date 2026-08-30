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
  src     :`symbol$() )      // MANUAL for a hand-entered offer

