// Gateway: the only endpoint clients should talk to.
//
// It fans a query out to whichever backends hold the requested dates, joins
// the results, and load-balances across duplicate hdb/rdb processes. Keeping
// clients off the HDBs directly is what lets you add, remove or restart
// readers without anyone noticing.

\d .gw
synccallsallowed:1b     // permit sync queries (simpler clients; async scales better)
querykeeptime:0D00:30   // how long to retain completed query results

\d .servers
CONNECTIONS:`rdb`hdb    // what the gateway routes to
STARTUP:1b
\d .
