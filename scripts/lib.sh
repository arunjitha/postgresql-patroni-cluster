#!/usr/bin/env bash
# Shared helpers for the guest-side provisioning scripts.
set -euo pipefail

LAB_DIR=/opt/pglab
# shellcheck source=../cluster.conf
source "$LAB_DIR/cluster.conf"

PG_BIN="/usr/pgsql-$PG_MAJOR/bin"
PG_DATA="/var/lib/pgsql/$PG_MAJOR/data"
PATRONI_CONF=/etc/patroni/patroni.yml

log() { echo "==> $*"; }

node_ip() {
  local n
  for n in $PG_NODES $HAPROXY_NODES; do
    if [[ ${n%%:*} == "$1" ]]; then echo "${n#*:}"; return 0; fi
  done
  echo "unknown node: $1" >&2
  return 1
}

my_name() { hostname -s; }
my_ip() { node_ip "$(my_name)"; }

iface_for_ip() {
  ip -o -4 addr show | awk -v ip="$1" '{ split($4, a, "/"); if (a[1] == ip) print $2 }'
}

etcd_hosts() {
  local n out=""
  for n in $ETCD_NODES; do out+="${out:+,}$(node_ip "$n"):$ETCD_CLIENT_PORT"; done
  echo "$out"
}
