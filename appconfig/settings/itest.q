// Integration test process.
//
// The mirror image of test.q: this one MUST reach the running stack, so
// discovery and connection tracking stay on. Keeping it a separate proctype
// rather than overriding test.q from the command line matters — .servers has
// four interlocking flags, and enabling only `enabled` leaves CONNECTIONS
// empty and CONNECTIONSFROMDISCOVERY off, so startupdepcycles blocks forever
// on a connection nothing will ever open.

\d .servers
enabled:1b
STARTUP:1b
DISCOVERYREGISTER:1b
CONNECTIONSFROMDISCOVERY:1b
CONNECTIONS:`rdb`hdb`gateway`segmentedtickerplant
HOPENTIMEOUT:5000

\d .usage
enabled:0b

\d .proc
loadprocesscode:0b
\d .
