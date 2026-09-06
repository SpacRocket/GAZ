"""Shared plumbing for Python line handlers.

Every handler does the same three things — reach the tickerplant, publish
column-major batches, survive the tickerplant going away — and differs only in
where the data comes from. That difference is the whole point: sim_power.py is
meant to be replaced by an ENTSO-E adapter without anything below changing.

Import this before pykx; it sets the environment pykx needs (see set_up_pykx).
"""

import os
import signal
import sys
import time


def _prepare_env():
    """Must run before pykx is imported.

    PyKX otherwise starts in licensed mode and initialises its own bundled
    libq, which is a 4.x-generation build and SIGSEGVs against a KDB-X 5.0
    licence — the same generation mismatch the Dockerfile's installer solves
    for q itself. A feed only ever sends over IPC, so unlicensed mode costs
    nothing: the typed vector constructors below all work, only converting q
    results back into Python does not.

    Set here rather than in compose so it holds on every launch path,
    including running a handler by hand.
    """
    os.environ.setdefault("PYKX_UNLICENSED", "1")
    # Suppresses a warning about symlinking QHOME into PyKX's lib dir, which an
    # unprivileged container user cannot do and does not need.
    os.environ.setdefault("PYKX_IGNORE_QHOME", "True")


_prepare_env()

import pykx as kx  # noqa: E402 - must follow _prepare_env()

# Re-exported so handlers do not each import pykx and risk doing it too early.
SymbolVector = kx.SymbolVector
FloatVector = kx.FloatVector
IntVector = kx.IntVector
LongVector = kx.LongVector
CharVector = kx.CharVector
TimestampVector = kx.TimestampVector

# The feed shares a container with the tickerplant, so this is loopback and
# needs no discovery service. GAZ_TP_HOST covers moving it back out.
TP_HOST = os.environ.get("GAZ_TP_HOST", "localhost")
TP_PORT = int(os.environ.get("GAZ_TP_PORT", os.environ.get("KDBBASEPORT", 6000)))


def connect(name, attempts=None):
    """Block until the tickerplant answers.

    The q feed gets this from .servers.startupdepcycles; a Python process gets
    nothing for free. The container starts the tickerplant and its handlers at
    once, so a few seconds of connection refused while the tp loads its schema
    is normal, not an error.

    attempts=None retries forever, which is what a supervised long-lived
    handler wants — there is nobody to report to and the tickerplant will come
    back. A one-shot script (backfill_power.py) passes a bound instead, so an
    operator running it against a stopped stack gets a non-zero exit rather
    than a process that looks busy for ever.
    """
    n = 0
    while True:
        try:
            conn = kx.SyncQConnection(TP_HOST, TP_PORT, no_ctx=True)
            print(f"{name}: connected to tickerplant {TP_HOST}:{TP_PORT}", flush=True)
            return conn
        except BaseException as e:  # noqa: BLE001 - any failure means retry
            n += 1
            if attempts is not None and n >= attempts:
                raise
            print(f"{name}: tickerplant not up ({e}), retrying in 2s", flush=True)
            time.sleep(2)


def publish(conn, table, columns, wait=False):
    """Send one batch to the tickerplant.

    Two rules the tickerplant enforces, both of which cost a `length error or a
    silent drop to learn:

    1. No `time` column. The STP prepends its own (stplog.q:53), and that single
       clock is what keeps ordering consistent across feeds. Sending one makes
       the payload a column too wide.
    2. Column-major — a tuple of one vector per column, not a table or a dict.

    Types must match database.q exactly. Plain Python lists get inferred types
    (a list of ints becomes a long vector) and the tickerplant rejects the batch
    with a type error, so build the vectors explicitly.

    wait=False, the default, makes this a genuine async publish. A synchronous
    call would block the handler on the tickerplant's reply and, worse, make the
    tickerplant wait on the handler. That is the right trade for a live handler
    sending a handful of rows on a timer.

    A bulk loader wants the opposite and passes wait=True: back-pressure is the
    point when you are pushing months of history through in a tight loop, and
    the round trip is the only confirmation the tickerplant took the batch
    before the caller records it as published.

    Note errmode:1b means a rejected batch does NOT raise here — it is written
    to stp1_segmentederrorlogfile* in the tplog dir. If a handler looks healthy
    but nothing arrives downstream, check that file first.
    """
    conn(".u.upd", table, columns, wait=wait)


def run(name, table, interval, make_batch):
    """Poll/generate loop shared by every handler.

    `make_batch` returns the column tuple for one publish, or None to skip.
    Reconnects on any IPC failure, because the tickerplant may be restarted
    underneath a long-lived handler.
    """
    # The sidecar supervisor in bin/gaz restarts us, so exiting on SIGTERM is
    # the correct response rather than trying to clean up.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    conn = connect(name)
    while True:
        try:
            batch = make_batch()
            if batch is not None:
                publish(conn, table, batch)
        except BaseException as e:  # noqa: BLE001 - reconnect on any failure
            print(f"{name}: publish failed ({e}), reconnecting", flush=True)
            try:
                conn.close()
            except BaseException:  # noqa: BLE001
                pass
            conn = connect(name)
        time.sleep(interval)
