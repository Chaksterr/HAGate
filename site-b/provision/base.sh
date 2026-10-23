#!/usr/bin/env bash
# Provisioner for vagrant/Vagrantfile — mirrors SiteB_Manual_Runbook.md §1.2.
# Runs as root, idempotent (vagrant provision can be re-run safely).
set -euo pipefail

MARKER=/var/lib/siteb-provisioned

# 1. cloud-init must never rewrite netplan (would restore the host NAT default route)
install -d /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF

# 2. a real netplan config, otherwise systemd-networkd-wait-online blocks boot forever
if [ ! -f /etc/netplan/01-lab.yaml ]; then
  rm -f /etc/netplan/50-cloud-init.yaml
  cat > /etc/netplan/01-lab.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      dhcp4: true
EOF
  chmod 600 /etc/netplan/*.yaml
  netplan apply
fi

# 3. boot must not wait for "online" (the unit has no timeout)
systemctl mask --now systemd-networkd-wait-online.service

# 4. per-VM identity and host keys — only once, so re-provisioning does not
#    invalidate known_hosts on every run
if [ ! -f "$MARKER" ]; then
  truncate -s 0 /etc/machine-id
  systemd-machine-id-setup
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  # SIGHUP: sshd re-execs with the new keys without killing this session
  systemctl reload ssh 2>/dev/null || systemctl restart ssh
  mkdir -p /var/lib
  touch "$MARKER"
fi

echo "siteb base provisioning complete: $(hostname) -> enp0s3 $(ip -4 -br addr show enp0s3 | awk '{print $3}')"
