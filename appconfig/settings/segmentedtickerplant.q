// Segmented tickerplant — the single point every tick passes through.
//
// The tp log directory is set twice on purpose: -tplogdir in process.csv (the
// STP reads it at startup) and .stplg.kdbtplog below (used on recovery). Both
// resolve from GAZ_TPLOG, which stays on local block storage in every
// environment — see the note in env.sh.

\d .sub
// TorQ's stp proctype config disables the timer, but subscriptions.q treats a
// non-zero checksubscriptionperiod with no timer as a fatal init error
// (subscriptions.q:174). The tickerplant subscribes to nothing, so the
// subscription check is what should go, not the timer.
checksubscriptionperiod:0D

\d .stplg
kdbtplog:`$getenv`GAZ_TPLOG
multilog:`tabperiod        // one log per table per period — parallel replay at EOD
batchmode:`defaultbatch    // batch publishes on the timer rather than per-message
errmode:1b
\d .
