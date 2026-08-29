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
