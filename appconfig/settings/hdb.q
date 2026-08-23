// HDB reader. Mmaps the on-disk database; holds no state of its own.
//
// The database directory is NOT set here — it comes from the `load` column of
// process.csv (`-load ${GAZ_HDB}`), which is what makes the same config work
// against ./data/hdb locally and /fsx/hdb in AWS.
//
// Scale-out unit: add hdb2, hdb3... rows to process.csv, all pointed at the
// same GAZ_HDB. In AWS those become separate instances against one NFS mount
// (FSx for OpenZFS), and the gateway load-balances across them.
//
// TorQ's hdb proctype config already sets loadprocesscode:1b (which brings in
// the reload handler the sort process calls at EOD) — do not turn that off.

\d .servers
CONNECTIONS:()
STARTUP:1b
\d .
