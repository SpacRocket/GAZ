// WDB: periodically flushes in-memory data to disk intraday, then hands the
// partition to the sort process at EOD.
//
// savedir is deliberately local disk (fast, many small writes); hdbdir is the
// shared filesystem (FSx for OpenZFS in AWS). The sort process is the single
// writer that promotes staged data into hdbdir — keeping exactly one writer
// against the shared mount is what makes the many-reader HDB pattern safe.

\d .wdb
savedir:hsym`$getenv`GAZ_WDB
hdbdir :hsym`$getenv`GAZ_HDB

ignorelist:`heartbeat`logmsg
tickerplanttypes:`segmentedtickerplant
hdbtypes:`hdb
rdbtypes:`rdb
gatewaytypes:`gateway

mode:`save                      // write intraday, then hand off to the sort proc at EOD
writedownmode:`default
settimer:0D00:00:10             // how often to check whether a flush is due
numtab:`quote`trade!10000 50000 // per-table row thresholds before flushing
replay:1b                       // replay the tp log on restart
schema:1b                       // take the schema from the tickerplant
\d .
