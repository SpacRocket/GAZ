// Single source of truth for the tick schema.
//
// Loaded by the segmented tickerplant via -schemafile, and by the unit tests.
// Every downstream process (rdb, wdb, hdb, feed) inherits its shape from here,
// so a column added below propagates without touching another file.
//
// `g# on sym is what makes `select from trade where sym=`X` fast in the RDB.

trade:([]
  time  :`timestamp$();
  sym   :`g#`symbol$();
  price :`float$();
  size  :`int$();
  side  :`symbol$();
  ex    :`char$();
  cond  :`char$();
  src   :`symbol$() )

quote:([]
  time  :`timestamp$();
  sym   :`g#`symbol$();
  bid   :`float$();
  ask   :`float$();
  bsize :`long$();
  asize :`long$();
  ex    :`char$();
  src   :`symbol$() )
