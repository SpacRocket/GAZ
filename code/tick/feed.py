#!/usr/bin/env python3
"""Synthetic feed handler, Python edition.

The counterpart to feed.q, and the place to put a real adapter: the venue
protocol, parsing and reconnect logic belong here, in a language with the
libraries for it. Everything below the `publish` boundary is the part worth
keeping when you replace the generator.

Deliberately NOT a process.csv row. bin/gaz builds `q torq.q ...` for every
row in that file, so a non-q process cannot be expressed as one; it also has
no proctype, no config layering and no -procfile. It is launched instead as
`bin/gaz run stp1 --sidecar 'python3 .../feed.py'`, which gives it the same
restart contract as a q co-tenant: it restarts in place, and never takes the
tickerplant down with it.

Because the feed shares a container with the tickerplant, the connection is
plain loopback — no discovery service, no .servers, no reconnect cycles.
"""

import os
import random
import signal
import sys
import time

# Must be set before pykx is imported. PyKX otherwise starts in licensed mode
# and initialises its own bundled libq, which is a 4.x-generation build and
# SIGSEGVs against a KDB-X 5.0 licence — the same generation mismatch that the
# Dockerfile's installer solves for q itself. A feed only ever sends over IPC,
# so unlicensed mode costs nothing: the typed vector constructors used below
# all work, only converting q results back to Python does not.
#
# It lives here rather than in compose so it holds on every launch path,
# including running this script by hand.
os.environ.setdefault("PYKX_UNLICENSED", "1")
# Suppresses a startup warning about symlinking QHOME into PyKX's lib dir,
# which the container cannot do as an unprivileged user and does not need.
os.environ.setdefault("PYKX_IGNORE_QHOME", "True")

import pykx as kx  # noqa: E402 - must follow the environment setup above

# --- configuration -------------------------------------------------------
# GAZ_TP_HOST exists for the case where the feed is moved back out into its
# own container; in the co-located layout it is always loopback.
TP_HOST = os.environ.get("GAZ_TP_HOST", "localhost")
TP_PORT = int(os.environ.get("GAZ_TP_PORT", os.environ.get("KDBBASEPORT", 6000)))
INTERVAL = float(os.environ.get("GAZ_FEED_INTERVAL", "0.2"))
MAX_TRADES = 10
MAX_QUOTES = 20

# --- reference data ------------------------------------------------------
# Mirrors code/common/gaz.q. That file is loaded into every q process; a
# Python process gets nothing for free, so the values are restated here.
SYMS = ["AAPL", "MSFT", "GOOG", "AMZN", "NVDA", "META", "TSLA", "AMD", "INTC", "IBM"]
REFPRICE = dict(zip(SYMS, [33, 27, 84, 12, 20, 72, 36, 51, 42, 29]))
EXCHANGES = "NLOB"
SOURCES = ["BARX", "GETGO", "SUN", "DB"]
SIDES = ["buy", "sell"]

price = dict(REFPRICE)


def step():
    """Advance the random walk, as feed.q does."""
    for s in price:
        price[s] *= 1.0 + 0.0005 * random.uniform(-1, 1)


def mktrades(n):
    syms = [random.choice(SYMS) for _ in range(n)]
    return (
        kx.SymbolVector(syms),
        kx.FloatVector([round(price[s], 2) for s in syms]),
        kx.IntVector([random.randint(10, 999) for _ in range(n)]),
        kx.SymbolVector([random.choice(SIDES) for _ in range(n)]),
        kx.CharVector("".join(random.choice(EXCHANGES) for _ in range(n))),
        kx.CharVector(" " * n),
        kx.SymbolVector([random.choice(SOURCES) for _ in range(n)]),
    )


def mkquotes(n):
    syms = [random.choice(SYMS) for _ in range(n)]
    mids = [price[s] for s in syms]
    halves = [0.01 + 0.05 * random.random() for _ in range(n)]
    return (
        kx.SymbolVector(syms),
        kx.FloatVector([round(m - h, 2) for m, h in zip(mids, halves)]),
        kx.FloatVector([round(m + h, 2) for m, h in zip(mids, halves)]),
        kx.LongVector([100 * random.randint(1, 50) for _ in range(n)]),
        kx.LongVector([100 * random.randint(1, 50) for _ in range(n)]),
        kx.CharVector("".join(random.choice(EXCHANGES) for _ in range(n))),
        kx.SymbolVector([random.choice(SOURCES) for _ in range(n)]),
    )


def connect():
    """Block until the tickerplant answers, the way .servers.startupdepcycles
    does for a q feed. The container starts both at once, so a few seconds of
    "connection refused" while the tp loads its schema is expected."""
    while True:
        try:
            conn = kx.SyncQConnection(TP_HOST, TP_PORT, no_ctx=True)
            print(f"feed: connected to tickerplant {TP_HOST}:{TP_PORT}", flush=True)
            return conn
        except BaseException as e:  # noqa: BLE001 - any failure means retry
            print(f"feed: tickerplant not up ({e}), retrying in 2s", flush=True)
            time.sleep(2)


def publish(conn):
    step()
    # Two rules the tickerplant enforces, both of which cost a `length error
    # to learn (see CLAUDE.md):
    #   1. no `time` column — the STP prepends its own (stplog.q:53), and that
    #      single clock is what keeps ordering consistent across feeds;
    #   2. column-major, one list per column, not a table or dict.
    # wait=False makes it a genuine async publish. A synchronous call would
    # block this process on the tickerplant's response and, worse, make the
    # tickerplant wait on us.
    conn(".u.upd", "trade", mktrades(random.randint(1, MAX_TRADES)), wait=False)
    conn(".u.upd", "quote", mkquotes(random.randint(1, MAX_QUOTES)), wait=False)


def main():
    # The sidecar supervisor restarts us, so exiting on SIGTERM is correct.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    conn = connect()
    while True:
        try:
            publish(conn)
        except BaseException as e:  # noqa: BLE001 - reconnect on any IPC failure
            print(f"feed: publish failed ({e}), reconnecting", flush=True)
            try:
                conn.close()
            except BaseException:  # noqa: BLE001
                pass
            conn = connect()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
