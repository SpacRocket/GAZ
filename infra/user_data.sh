#!/bin/bash
# Boot-time provisioning for the kdb box.
set -eux

# --- ssm ------------------------------------------------------------------
dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
systemctl enable --now amazon-ssm-agent

# bash-completion is the framework that sources the completion files other
# packages drop in. docker-ce-cli ships one, but without this nothing reads it.
dnf install -y nfs-utils unzip dnf-plugins-core bash-completion

# --- aws cli --------------------------------------------------------------
curl -sSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
ln -sf /usr/local/bin/aws /usr/bin/aws

# --- fsx ------------------------------------------------------------------
#   _netdev             do not attempt before the network is up
#   x-systemd.automount mount on FIRST ACCESS to /mnt/fsx, not at boot
mkdir -p /mnt/fsx
grep -q ' /mnt/fsx ' /etc/fstab || echo "${fsx_dns}:/fsx /mnt/fsx nfs _netdev,x-systemd.automount,hard,noatime,nfsvers=4.2,nconnect=16,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab
systemctl daemon-reload
systemctl start mnt-fsx.automount

# --- docker ---------------------------------------------------------------
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
usermod -aG docker rocky

# --- values the bootstrap needs, resolved at apply time -------------------
install -d -m 0755 /etc/gaz
cat >/etc/gaz/bootstrap.env <<ENV
GAZ_REGION=${region}
GAZ_BUCKET=${bucket}
GAZ_LIC_PARAM=${lic_param}
GAZ_ENTSOE_PARAM=${entsoe_param}
ENV

# --- the bootstrap --------------------------------------------------------
cat >/usr/local/bin/gaz-bootstrap <<'BOOTSTRAP'
#!/bin/bash
# Fetch the licence and the code, then bring the stack up.
#
# Must be safe to re-run: systemd retries this on failure and on every reboot.
# Both inputs are allowed to be missing at boot -- `terraform destroy` takes
# the bucket with it (force_destroy), so a fresh apply recreates it EMPTY and
# the tarball only lands when scripts/uploadCode.sh next runs. Failing and
# letting systemd retry is the whole mechanism, not an error path.
set -euo pipefail
. /etc/gaz/bootstrap.env
export AWS_DEFAULT_REGION="$GAZ_REGION"

# --- licence --------------------------------------------------------------
# QLIC is a DIRECTORY; docker-compose.yml bind-mounts it to /etc/kdb:ro.
LIC_B64="$(aws ssm get-parameter --name "$GAZ_LIC_PARAM" \
             --with-decryption --query Parameter.Value --output text)"

# Terraform creates the parameter holding a placeholder. Refuse loudly rather
# than build an image around junk; systemd retries once the real value lands.
if [ "$LIC_B64" = "PLACEHOLDER" ]; then
  echo "licence parameter $GAZ_LIC_PARAM still holds PLACEHOLDER;" >&2
  echo "run the put-parameter in infra/main.tf, then this retries itself" >&2
  exit 1
fi

install -d -m 0755 /etc/kdb
printf '%s' "$LIC_B64" | base64 -d > /etc/kdb/kc.lic.new
mv /etc/kdb/kc.lic.new /etc/kdb/kc.lic
chmod 0644 /etc/kdb/kc.lic

# --- code -----------------------------------------------------------------
install -d -o rocky -g rocky /home/rocky/gaz
aws s3 cp "s3://$GAZ_BUCKET/gaz.tar.gz" - | tar -xz -C /home/rocky/gaz
chown -R rocky:rocky /home/rocky/gaz

# --- hdb on fsx -----------------------------------------------------------
# docker-compose.yml bind-mounts this. Docker would otherwise create it as root,
# and the containers run as uid 6000 (docker/Dockerfile), so `sort` could not
# write. Touching the path also trips the automount. Requires the FSx export to
# permit this -- see the root_volume_configuration note in infra/main.tf.
install -d -o 6000 -g 6000 /mnt/fsx/hdb

# --- stack ----------------------------------------------------------------
cd /home/rocky/gaz
export QLIC=/etc/kdb
export KX_B64_LIC="$LIC_B64"

# Optional: the feed needs it, the stack starts without it.
if AK="$(aws ssm get-parameter --name "$GAZ_ENTSOE_PARAM" \
           --with-decryption --query Parameter.Value --output text 2>/dev/null)"; then
  export ENTSOE_API_KEY="$AK"
fi

docker compose -f docker/docker-compose.yml build
docker compose -f docker/docker-compose.yml up -d
BOOTSTRAP
chmod 0755 /usr/local/bin/gaz-bootstrap

cat >/etc/systemd/system/gaz-stack.service <<'UNIT'
[Unit]
Description=gaz: fetch licence and code from AWS, bring the stack up
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/gaz-bootstrap
# The code tarball may not be in the bucket yet. Retry rather than give up:
# `tf apply` then `scripts/uploadCode.sh` brings the stack up within 30s,
# in either order.
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now gaz-stack.service
