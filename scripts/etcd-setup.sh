#!/usr/bin/env bash
# Configures this node as a member of the etcd DCS cluster.
# Run on every ETCD_NODES member at the same time; the members wait for quorum.
# Wipes any existing etcd data — deploy always builds a fresh cluster.
source /opt/pglab/scripts/lib.sh

me=$(my_name)
ip=$(my_ip)

initial=""
for n in $ETCD_NODES; do
  initial+="${initial:+,}$n=http://$(node_ip "$n"):$ETCD_PEER_PORT"
done

systemctl stop etcd 2>/dev/null || true
id etcd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/etcd --shell /sbin/nologin etcd
rm -rf /var/lib/etcd
install -d -o etcd -g etcd -m 700 /var/lib/etcd
install -d -m 755 /etc/etcd

log "Writing /etc/etcd/etcd.conf.yaml"
cat > /etc/etcd/etcd.conf.yaml <<EOF
name: $me
data-dir: /var/lib/etcd/$CLUSTER_NAME
initial-cluster-token: ${CLUSTER_NAME}-etcd
initial-cluster-state: new
initial-cluster: $initial
initial-advertise-peer-urls: http://$ip:$ETCD_PEER_PORT
listen-peer-urls: http://$ip:$ETCD_PEER_PORT
listen-client-urls: http://$ip:$ETCD_CLIENT_PORT,http://127.0.0.1:$ETCD_CLIENT_PORT
advertise-client-urls: http://$ip:$ETCD_CLIENT_PORT
EOF

cat > /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd ($CLUSTER_NAME DCS)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=etcd
ExecStart=$(command -v etcd) --config-file /etc/etcd/etcd.conf.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable etcd
# --no-block: start returns before quorum exists; pglab waits for health.
systemctl start --no-block etcd
log "etcd starting as $me ($ip)"
