#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gaz environment
#
# This is THE portability layer. Nothing in code/ or appconfig/ hardcodes a
# path; everything resolves from the variables set here.
#
#   Local  : data lives under ./data
#   Cloud  : export GAZ_HDB=/fsx/hdb etc. before sourcing, and nothing else
#            in the repo changes.
#
# Every GAZ_* var below uses ${VAR:-default}, so an exported value always
# wins. Put machine-specific overrides in env.local.sh (gitignored).
# ---------------------------------------------------------------------------

if [ -n "$BASH_SOURCE" ]; then
  _gaz_self="${BASH_SOURCE[0]}"
else
  _gaz_self="$0"
fi
GAZ_ROOT="$(cd "$(dirname "$_gaz_self")" && pwd)"
export GAZ_ROOT

# --- q -------------------------------------------------------------------
# QHOME must point at your kdb+ install (the dir holding the l64/m64 binary
# and q.k). Override in env.local.sh if yours lives elsewhere.
export QHOME="${QHOME:-$HOME/Applications/q}"
export PATH="$QHOME/bin:$PATH"
export QCMD="${QCMD:-q}"

# --- code + config: these follow the repo, never the environment ---------
export TORQHOME="${TORQHOME:-$GAZ_ROOT/vendor/TorQ}"   # the framework
export TORQAPPHOME="$GAZ_ROOT"                          # our application
export KDBCODE="$TORQHOME/code"
export KDBCONFIG="$TORQHOME/config"
export KDBHTML="$TORQHOME/html"
export KDBLIB="$TORQHOME/lib"
export KDBAPPCODE="$TORQAPPHOME/code"
export KDBAPPCONFIG="$TORQAPPHOME/appconfig"
export TORQPROCESSES="$KDBAPPCONFIG/process.csv"
export GAZ_SCHEMA="$TORQAPPHOME/database.q"

# KDBTESTS must point at TorQ's tests dir: passing -test makes torq.q load
# $KDBTESTS/k4unit.q and $KDBTESTS/runtests.q from there (torq.q:708). Our own
# test CSVs live in GAZ_TESTS and are named with -test on the command line.
export KDBTESTS="$TORQHOME/tests"
export GAZ_TESTS="$TORQAPPHOME/tests"

# --- data: THIS is what moves to cloud -----------------------------------
# Local defaults mirror the cloud layout one-for-one. See infra/README.md.
GAZ_DATA="${GAZ_DATA:-$GAZ_ROOT/data}"

#   HDB  -> FSx for OpenZFS (NFS) in AWS. Shared, one writer / many readers.
export GAZ_HDB="${GAZ_HDB:-$GAZ_DATA/hdb}"

#   WDB  -> intraday write-down staging. Local disk in both environments;
#           the sort process promotes it into GAZ_HDB at EOD.
export GAZ_WDB="${GAZ_WDB:-$GAZ_DATA/wdb}"

#   TPLOG -> deliberately NOT on the shared FS. Local block storage (EBS gp3).
#           Every tick is fsync'd here; a network filesystem would put the
#           recovery log behind the same failure domain as the HDB.
export GAZ_TPLOG="${GAZ_TPLOG:-$GAZ_DATA/tplogs}"

export KDBLOG="${GAZ_LOG:-$GAZ_DATA/logs}"

# TorQ reads these names directly in a few places
export KDBHDB="$GAZ_HDB"
export KDBWDB="$GAZ_WDB"
export KDBTPLOG="$GAZ_TPLOG"

# --- ports ---------------------------------------------------------------
# process.csv addresses everything as {KDBBASEPORT}+n, so the whole stack
# relocates by changing this one number.
export KDBBASEPORT="${KDBBASEPORT:-6000}"
export KDBSTACKID="-stackid ${KDBBASEPORT}"

# --- platform ------------------------------------------------------------
# The :- defaults matter: bin/gaz runs under `set -u`, so a bare reference to
# an unset DYLD_LIBRARY_PATH would abort the launcher.
case "$(uname -s)" in
  Darwin) export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-}:$KDBLIB/m64" ;;
  Linux)  export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$KDBLIB/l64" ;;
esac

# --- local overrides -----------------------------------------------------
if [ -f "$GAZ_ROOT/env.local.sh" ]; then
  . "$GAZ_ROOT/env.local.sh"
fi

mkdir -p "$GAZ_HDB" "$GAZ_WDB" "$GAZ_TPLOG" "$KDBLOG"
