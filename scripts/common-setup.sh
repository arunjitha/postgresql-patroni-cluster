#!/usr/bin/env bash
# Base OS prep for every node: /etc/hosts, time sync, SELinux/firewalld, packages.
# Usage: common-setup.sh pg|lb
source /opt/pglab/scripts/lib.sh
role=${1:?usage: common-setup.sh pg|lb}

log "SELinux permissive, firewalld off (lab setting)"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
systemctl disable --now firewalld 2>/dev/null || true

log "Writing /etc/hosts"
{
  echo "127.0.0.1 localhost localhost.localdomain"
  echo "::1       localhost localhost.localdomain"
  for n in $PG_NODES $HAPROXY_NODES; do echo "${n#*:} ${n%%:*}"; done
  echo "$VIP ${CLUSTER_NAME}-vip"
} > /etc/hosts

log "Time sync"
dnf -y -q install chrony
systemctl enable --now chronyd

case $role in
  pg)
    log "Enabling EPEL, CRB and Percona Distribution for PostgreSQL $PG_MAJOR"
    dnf -y -q install epel-release dnf-plugins-core
    dnf config-manager --set-enabled crb
    dnf -y -q install https://repo.percona.com/yum/percona-release-latest.noarch.rpm
    percona-release setup -y "ppg-$PG_MAJOR"
    dnf -y -q module disable postgresql 2>/dev/null || true

    log "Installing PostgreSQL $PG_MAJOR, Patroni and etcd"
    dnf -y -q install \
      "percona-postgresql$PG_MAJOR-server" "percona-postgresql$PG_MAJOR-contrib" \
      percona-patroni percona-patroni-etcd etcd
    # Patroni owns the postmaster; the stock unit must never start it.
    systemctl disable --now "postgresql-$PG_MAJOR" 2>/dev/null || true
    ;;
  lb)
    log "Installing HAProxy and Keepalived"
    dnf -y -q install haproxy keepalived psmisc
    ;;
  *) echo "unknown role: $role" >&2; exit 1 ;;
esac

log "common setup done"
