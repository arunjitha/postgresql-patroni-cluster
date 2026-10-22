#!/usr/bin/env bash
# HAProxy routing: RW port -> current Patroni leader, RO port -> replicas (round robin).
# Backend health comes from the Patroni REST API (/primary, /replica).
source /opt/pglab/scripts/lib.sh

# Lets HAProxy bind the VIP even on the node that does not currently hold it.
echo "net.ipv4.ip_nonlocal_bind = 1" > /etc/sysctl.d/99-pglab.conf
sysctl -q --system

servers() {
  local n
  for n in $PG_NODES; do
    echo "    server ${n%%:*} ${n#*:}:$PG_PORT maxconn 100 check port $PATRONI_API_PORT"
  done
}

log "Writing /etc/haproxy/haproxy.cfg"
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 1000

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout server 30m
    timeout connect 4s
    timeout check 5s

listen stats
    mode http
    bind *:$HAPROXY_STATS_PORT
    stats enable
    stats uri /
    stats refresh 5s
    stats auth $HAPROXY_STATS_USER:$HAPROXY_STATS_PASSWORD

listen primary
    bind *:$HAPROXY_RW_PORT
    option httpchk OPTIONS /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
$(servers)

listen replicas
    bind *:$HAPROXY_RO_PORT
    balance roundrobin
    option httpchk OPTIONS /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
$(servers)
EOF

haproxy -c -q -f /etc/haproxy/haproxy.cfg
systemctl enable haproxy
systemctl restart haproxy
log "HAProxy up: rw=:$HAPROXY_RW_PORT ro=:$HAPROXY_RO_PORT stats=:$HAPROXY_STATS_PORT"
