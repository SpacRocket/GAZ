// Sort process: triggered by the wdb at EOD. Sorts the staged partition,
// applies attributes, moves it into the HDB, then tells the rdb/hdb/gateway
// to reload.
//
// This is the ONLY process that writes to GAZ_HDB. In AWS that means it is the
// only process that needs the NFS mount read-write; every HDB reader can
// mount read-only.
//
// TorQ's own sort proctype config already sets mode:`sort — we only relocate
// the directories.

\d .wdb
savedir:hsym`$getenv`GAZ_WDB
hdbdir :hsym`$getenv`GAZ_HDB
\d .
