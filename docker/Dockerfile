# Linux image for gaz. Two reasons to use it even while developing on a Mac:
#   1. macOS is case-insensitive by default, ZFS and ext4 are not — a sym or
#      column name differing only in case breaks in production and nowhere else.
#   2. It is the same image you deploy, so "works locally" means something.
#
# The Linux kdb+ builds live in kdb/ at the repo root, one directory per
# architecture. The right one is picked from BuildKit's TARGETARCH, so this
# builds natively on an M-series Mac and on an x86 runner without edits:
#
#   docker compose -f docker/docker-compose.yml build                  # native
#   docker compose -f docker/docker-compose.yml build \
#     --build-arg TARGETARCH=amd64                                     # forced
#
# kdb+ is licensed software. The binary is baked in; the LICENCE IS NOT —
# kc.lic/k4.lic is mounted at runtime, see docker-compose.yml.

FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates rlwrap procps gawk \
 && rm -rf /var/lib/apt/lists/*

# Match the UID across every container and host that touches the shared
# filesystem. NFS enforces POSIX ownership, so a mismatch here becomes
# permission errors on files the sort process wrote.
ARG GAZ_UID=6000
RUN groupadd -g ${GAZ_UID} gaz && useradd -u ${GAZ_UID} -g gaz -m -s /bin/bash gaz

ENV QHOME=/opt/q

# TARGETARCH is supplied by BuildKit (amd64 | arm64). Both builds are copied in
# and the unused one dropped in the same layer — they are under a megabyte each,
# and this keeps the selection logic in one place.
ARG TARGETARCH
COPY kdb/ /tmp/kdb/
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) qarch=l64    ;; \
      arm64) qarch=l64arm ;; \
      *) echo "no kdb+ build bundled for TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    test -x "/tmp/kdb/${qarch}/${qarch}/q" \
      || { echo "expected kdb/${qarch}/${qarch}/q in the build context" >&2; exit 1; }; \
    mkdir -p "${QHOME}"; \
    cp -r "/tmp/kdb/${qarch}/." "${QHOME}/"; \
    chmod +x "${QHOME}/${qarch}/q"; \
    ln -s "${QHOME}/${qarch}/q" /usr/local/bin/q; \
    rm -rf /tmp/kdb

WORKDIR /app
COPY --chown=gaz:gaz . /app

# Cloud paths. Overridden per-service in compose; in AWS these are the real
# mount points. Note tplog and wdb are deliberately separate volumes from hdb.
ENV GAZ_HDB=/fsx/hdb \
    GAZ_WDB=/mnt/wdb \
    GAZ_TPLOG=/mnt/tplog \
    GAZ_LOG=/var/log/gaz \
    QLIC=/etc/kdb

USER gaz
ENTRYPOINT ["/app/bin/gaz"]
CMD ["status"]
