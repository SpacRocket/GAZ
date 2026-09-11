// Plant reference data, loaded from a CSV at process startup.
//
// $KDBAPPCODE/common is loaded into EVERY process, so .gaz.plants is available
// to the analytics wherever they end up running — the RDB, a dedicated
// calculation process, or an interactive tq session composing an offer.
//
// Deliberately NOT loaded from database.q. That file is the tickerplant's
// -schemafile and the STP treats every root table in it as a tick table to
// log; anything that is not one fails init with a length error and the
// tickerplant crashloops. Reference data is not tick data.
//
// A CSV rather than a splayed table because this is small, static and edited
// by hand — five rows that change when a unit is refurbished. Keeping it in
// git means a change to an efficiency shows up in history next to the commit
// that explains it, which a binary column file would not.
//
// Caveat worth knowing: this is a snapshot, not a slowly-changing dimension.
// Efficiency degrades and units get upgraded; editing the CSV rewrites
// history rather than versioning it. Fine at this size — if it ever matters,
// the fix is a `from` date column and an as-of lookup.

\d .gaz

// Column types, in file order:
//   plant      symbol   unit identifier
//   zone       symbol   bidding zone, matches power.zone
//   capacity   float    MW electrical, net
//   efficiency float    LHV basis, electrical out / thermal in. See .gaz.units:
//                       European convention. A US HHV figure runs ~10% higher
//                       and would flatter the plant straight into marginal cost.
//   ef         float    tCO2 per MWh thermal burnt (natural gas ~0.202)
//   startup    float    EUR per cold start
//
// There is NO fuelcap column, and there should not be one. A CCGT has no
// on-site gas storage — it takes gas off the grid against a shipper portfolio,
// so the fuel position belongs to .gaz.portfolio and not to any single unit.
// See the fuel procurement note in database.q.
plants:1!("SSFFFF"; enlist ",") 0: hsym `$getenv `GAZ_PLANTS

\d .
