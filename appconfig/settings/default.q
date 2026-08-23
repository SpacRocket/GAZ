// Application-wide config. Loaded by every gaz process, after TorQ's own
// config/settings/default.q, so anything set here overrides the framework.
//
// Load order per process:
//   $KDBCONFIG/settings/{default,<proctype>,<procname>}.q      (TorQ)
//   $KDBAPPCONFIG/settings/{default,<proctype>,<procname>}.q   (us)

\d .proc
// $KDBAPPCODE/common is picked up by .proc.reloadcode[`common], which is how
// code/common/gaz.q lands in every process without being listed anywhere.
loadcommoncode:1b

\d .gaz
// Resolved once, here, so no other q file has to know about the environment.
hdbdir  :hsym`$getenv`GAZ_HDB
wdbdir  :hsym`$getenv`GAZ_WDB
tplogdir:hsym`$getenv`GAZ_TPLOG
schema  :getenv`GAZ_SCHEMA

\d .
