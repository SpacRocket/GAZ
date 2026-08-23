// RDB: holds today's data in memory, serves intraday queries.

\d .rdb
hdbdir:hsym`$getenv`GAZ_HDB     // where EOD data lands / which hdb to notify
replaylog:1b                    // recover today's ticks from the tp log on restart
savetables:0b                   // the wdb owns write-down, not the rdb
garbagecollect:1b
subscribeto:`                   // all tables
subscribesyms:`                 // all syms
\d .
