// The k4unit test process.
//
// Defaults are tuned for the UNIT suite: fully standalone, no discovery, no
// timers, so `make test` runs green on a laptop with nothing else started.
//
// The integration suite needs the opposite, and re-enables connection
// tracking from the command line (`-.servers.enabled 1`) — see the Makefile.
// TorQ casts such overrides to the type the variable already holds, which is
// why it is `1` and not `1b`.

\d .servers
enabled:0b
STARTUP:0b
DISCOVERYREGISTER:0b
CONNECTIONSFROMDISCOVERY:0b

\d .usage
enabled:0b          // don't log queries during a test run

// NB: leave .timer alone. TorQ's subscriptions module asserts that the timer
// is enabled whenever checksubscriptionperiod is set, and errors out of
// initialisation if it isn't.

\d .proc
loadprocesscode:0b
\d .
