# Linux image for gaz. Two reasons to use it even while developing on a Mac:
#   1. macOS is case-insensitive by default, ZFS and ext4 are not — a sym or
#      column name differing only in case breaks in production and nowhere else.
#   2. It is the same image you deploy, so "works locally" means something.
#
# kdb+ is licensed software and is NOT baked in. Before building:
#   mkdir -p docker/q && cp -r $QHOME/l64 $QHOME/q.k docker/q/
# and mount the license at runtime (see docker-compose.yml) rather than
# copying it into a layer.

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
COPY docker/q/ ${QHOME}/
RUN ln -s ${QHOME}/l64/q /usr/local/bin/q && chmod +x ${QHOME}/l64/q

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
