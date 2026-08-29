# Linux image for gaz. Two reasons to use it even while developing on a Mac:
#   1. macOS is case-insensitive by default, ZFS and ext4 are not — a sym or
#      column name differing only in case breaks in production and nowhere else.
#   2. It is the same image you deploy, so "works locally" means something.
#
# KDB-X installs itself from KX's portal at build time. The zips are public —
# no credentials — and the installer reads uname, so this builds natively on an
# M-series Mac and on an x86 runner without edits:
#
#   export KX_B64_LIC=$(base64 < ~/Applications/q/kc.lic | tr -d '\n')
#   docker compose -f docker/docker-compose.yml build
#
# Build time, not container start: nine processes must not each download kdb+ on
# every boot, and the stack has to come up when the portal is down.
#
# kdb+ is licensed software. The binary is baked in; the LICENCE IS NOT —
# the installer's -y demands one, so it arrives as a BuildKit secret (never a
# layer, never the repo) and the kc.lic it writes is deleted in the same step.
# The real licence is mounted at runtime, see docker-compose.yml.

FROM debian:12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates rlwrap procps gawk curl unzip ncurses-bin \
      python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*

# PyKX for the Python line handler. IPC only — it talks to the tickerplant over
# a socket like any other client, so it needs no embedded q of its own.
RUN pip3 install --no-cache-dir --break-system-packages pykx

# Match the UID across every container and host that touches the shared
# filesystem. NFS enforces POSIX ownership, so a mismatch here becomes
# permission errors on files the sort process wrote.
ARG GAZ_UID=6000
RUN groupadd -g ${GAZ_UID} gaz && useradd -u ${GAZ_UID} -g gaz -m -s /bin/bash gaz

ENV QHOME=/opt/q

# The installer hardcodes $HOME/.kx as its target and rewrites shell rc files,
# so it runs with HOME pointed at a scratch dir and the result is moved into
# QHOME. TERM matters: the script is `bash -e` and opens with bare tput calls.
RUN --mount=type=secret,id=kxlic set -eu; \
    test -s /run/secrets/kxlic \
      || { echo "KX_B64_LIC is empty — see the header of this file" >&2; exit 1; }; \
    curl --fail -sL -o /tmp/install_kdb.sh \
      https://portal.dl.kx.com/assets/raw/kdb-x/install_kdb/~latest~/install_kdb.sh; \
    HOME=/tmp TERM=dumb bash /tmp/install_kdb.sh -y --b64lic "$(cat /run/secrets/kxlic)"; \
    mv /tmp/.kx "${QHOME}"; \
    rm -f "${QHOME}/kc.lic" "${QHOME}/k4.lic" /tmp/install_kdb.sh; \
    test -x "${QHOME}/bin/q" || { echo "installer left no q binary" >&2; exit 1; }; \
    ln -s "${QHOME}/bin/q" /usr/local/bin/q

WORKDIR /app
COPY --chown=gaz:gaz . /app

# Cloud paths. Overridden per-service in compose; in AWS these are the real
# mount points. Note tplog and wdb are deliberately separate volumes from hdb.
ENV GAZ_HDB=/fsx/hdb \
    GAZ_WDB=/mnt/wdb \
    GAZ_TPLOG=/mnt/tplog \
    GAZ_LOG=/var/log/gaz \
    QLIC=/etc/kdb

# env.sh creates all four data dirs in every process, whether or not this
# particular service mounts a volume there — and bin/gaz runs under `set -e`,
# so a mkdir into root-owned /mnt or /var/log kills the launcher. Create them
# as gaz here: an empty named volume inherits the mountpoint's ownership from
# the image, so this covers both the mounted and unmounted cases.
RUN mkdir -p "${GAZ_HDB}" "${GAZ_WDB}" "${GAZ_TPLOG}" "${GAZ_LOG}" \
 && chown -R gaz:gaz "${GAZ_HDB}" "${GAZ_WDB}" "${GAZ_TPLOG}" "${GAZ_LOG}"

# `tq` in an interactive container shell: a q session that is a TorQ process on
# this stack, rather than the bare kdb+ that `q` gives you. Takes an optional
# process name (tq rdb1), defaulting to itest1. Lands in .bashrc because
# `docker compose exec <svc> bash` is an interactive non-login shell, which
# reads that and not /etc/profile.d.
RUN printf '\n# gaz: interactive TorQ process on this stack\nalias tq=%s\n' \
      "'/app/bin/gaz repl'" >> /home/gaz/.bashrc \
 && chown gaz:gaz /home/gaz/.bashrc

USER gaz
ENTRYPOINT ["/app/bin/gaz"]
CMD ["status"]
