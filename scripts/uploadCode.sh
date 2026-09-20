#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Ship the repo to the code bucket as a single tarball.
#
# A tarball rather than `aws s3 sync` because docker/Dockerfile does
# `COPY . /app`: a sync leaves deleted files behind on the box unless you
# remember --delete, so what ends up in /app depends on history rather than on
# one object. One object also means the box's pull is atomic.
#
# Lands at the bucket ROOT. The artifacts/ prefix is the only one the instance
# role may write to (infra/main.tf), so that direction is for output coming
# back, not code going out.
# ---------------------------------------------------------------------------
set -euo pipefail          # pipefail is load-bearing: without it a failing tar
                           # still exits 0 through `aws s3 cp` and silently
                           # uploads a TRUNCATED archive.

GAZ_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$GAZ_HOME"

DEST="$(terraform -chdir=infra output -raw code_bucket_uri)/gaz.tar.gz"

# Excludes, each one a real hazard:
#   --exclude-vcs        drops .git AND vendor/TorQ/.git, but keeps TorQ's
#                        working tree — the box gets the framework without
#                        needing `git submodule init`.
#   infra/*.tfstate*     state holds resource detail that has no business
#                        on the instance.
#   infra/.terraform     ~650MB of downloaded provider binaries.
#   data/, env.local.sh  local HDB/logs and this machine's paths, which would
#                        override the container's.
#
# kdb/ IS shipped, though it is gitignored: it holds the Linux q builds
# (l64 = x86_64, l64arm = aarch64), which by definition cannot be committed and
# cannot be fetched on a box with no q on it yet. Both arches go up — together
# they are under 2MB, and hardcoding one makes the tarball silently wrong the
# day the instance changes shape. The bucket is private with public access
# fully blocked and SSE-S3 on, which is the only reason licensed KX binaries
# may sit in it at all.

# Fail before the upload rather than after. kdb/ is gitignored, so a fresh
# clone simply does not have it, and a tarball missing q is only discovered
# on the box at `docker compose build` time.
[ -x kdb/l64/l64/q ] || { echo "no kdb/l64/l64/q — stage the Linux q build first" >&2; exit 1; }

echo "packing $GAZ_HOME -> $DEST"
tar --exclude-vcs \
    --exclude='./data' \
    --exclude='./infra/.terraform' \
    --exclude='./infra/*.tfstate*' \
    --exclude='env.local.sh' \
    --exclude='__pycache__' \
    -czf - . \
  | aws s3 cp - "$DEST"

echo "uploaded. On the box:"
echo "  aws s3 cp $DEST - | tar -xz -C ~/gaz"
