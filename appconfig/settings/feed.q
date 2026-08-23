// Feed handler.
//
// .servers.CONNECTIONS is what makes .servers.startup[] actually dial the
// tickerplant. Without it the feed blocks forever inside
// .servers.startupdepcycles waiting for a connection nothing ever opens —
// the process looks alive but publishes nothing.

\d .servers
enabled:1b
CONNECTIONS:enlist`segmentedtickerplant
STARTUP:1b
HOPENTIMEOUT:30000
\d .
