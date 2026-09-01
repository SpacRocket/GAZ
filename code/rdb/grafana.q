// Grafana wiring for the RDB.
//
// $KDBAPPCODE/<proctype>/ is auto-loaded into processes of that type, which is
// why this lives in code/rdb/ rather than code/common/ — only the RDB needs to
// speak HTTP to Grafana.
//
// TorQ ships the datasource implementation but does not load it, so we load it
// explicitly. It implements the Grafana SimpleJSON API over kdb+'s own HTTP
// handlers (.z.pp / .z.ph), keyed off the X-Grafana-Org-Id header, so the same
// port serves IPC and Grafana at once — no extra listener.
//
// NOT pointed at the gateway on purpose. The gateway routes queries and holds
// no tables of its own, and .grafana.search enumerates tables[] locally, so a
// Grafana datasource aimed at it would find nothing to plot.

system"l ",getenv[`TORQHOME],"/code/common/grafana.q";

\d .grafana

// Left on grafana.q's defaults — `time` and `sym`.
//
// An earlier version pointed timecol at `delivery` so the power curve charted
// against the period a price is FOR rather than when it arrived. That works
// for one table and breaks the moment a second chart wants a different axis:
// there is only one timecol for every table grafana.q exposes, and marginal
// cost is a series over `time` split by `plant`, not over `delivery`.
//
// The fix is in code/rdb/grafanaviews.q — derived views reshaped to a common
// (time; sym) convention, so power keeps its delivery axis while marginal cost
// gets a wall-clock one.
// See code/rdb/grafanaviews.q: `gvtime` exists only on the Grafana view
// tables, which keeps grafana.q away from the raw tick tables it cannot
// handle (they have no `sym` column and /search throws 'sym).
timecol:`gvtime
sym:`sym

// Cover the whole published curve — day-ahead runs ~2 days forward.
timebackdate:4D

// Enough points for 96 quarter-hours x 5 zones x a few days.
ticks:2000

\d .
