// Synthetic feed handler.
//
// Stands in for a real market data adapter: finds the tickerplant through the
// discovery service and publishes batches of trades and quotes on a timer.
// Replace the generation below with your actual adapter; the discovery and
// publish mechanics are the parts worth keeping.

\d .feed

tpconn:0Ni                        // handle to the tickerplant
interval:0D00:00:00.200           // publish every 200ms
maxtrades:10                      // per batch
maxquotes:20

// Random walk state, seeded from the shared reference prices.
price:.gaz.refprice

step:{[p] p*1f+0.0005*(count p)?-1 1f}

mktrades:{[n]
  s:n?.gaz.syms;
  ([] time :n#.proc.cp[];
      sym  :s;
      price:.gaz.rnd[2; price s];
      size :`int$10+n?990;
      side :n?.gaz.sides;
      ex   :n?.gaz.exchanges;
      cond :n#" ";
      src  :n?.gaz.sources ) }

mkquotes:{[n]
  s:n?.gaz.syms;
  m:price s;
  h:0.01+0.05*n?1f;               // half-spread
  ([] time :n#.proc.cp[];
      sym  :s;
      bid  :.gaz.rnd[2; m-h];
      ask  :.gaz.rnd[2; m+h];
      bsize:100*1+n?50;
      asize:100*1+n?50;
      ex   :n?.gaz.exchanges;
      src  :n?.gaz.sources ) }

// Rows that would fail data quality never reach the tickerplant. A real
// adapter should log the drops rather than discarding them silently.
publish:{
  if[null tpconn; :()];
  price::step price;              // advance the walk

  t:mktrades 1+rand maxtrades;
  t:t where .gaz.validtrade t;
  q:mkquotes 1+rand maxquotes;
  q:q where .gaz.validquote q;

  // The tickerplant prepends its own time column (stplog.q:53) — that single
  // clock is what keeps ordering consistent across feeds. Publishing `time`
  // ourselves makes the payload one column too wide and the STP rejects the
  // batch with a `length error. Generate it locally for validation, strip it
  // on the way out.
  if[count t; neg[tpconn](".u.upd";`trade;value flip delete time from t)];
  if[count q; neg[tpconn](".u.upd";`quote;value flip delete time from q)];
  neg[tpconn][]; }

\d .

// Block until the tickerplant is up, then start publishing. .servers is
// TorQ's connection manager: it resolves the tp through discovery and
// reconnects on its own if the tp bounces.
.servers.startupdepcycles[`segmentedtickerplant;10;0W];
.feed.tpconn:.servers.gethandlebytype[`segmentedtickerplant;`any];

.timer.repeat[.proc.cp[];0Wp;.feed.interval;(`.feed.publish;`);"gaz feed publish"];

.lg.o[`feed;"publishing to tickerplant on handle ",string .feed.tpconn];
