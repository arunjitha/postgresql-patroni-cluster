#!/usr/bin/env bash
# Writes the Patroni config and starts Patroni on this PostgreSQL node.
# The first node started bootstraps the cluster; later ones clone from the leader.
# Wipes the local data directory — deploy always builds a fresh cluster.
source /opt/pglab/scripts/lib.sh

me=$(my_name)
ip=$(my_ip)

systemctl stop patroni 2>/dev/null || true
rm -rf "$PG_DATA"
install -d -o postgres -g postgres -m 700 "$PG_DATA"
install -d -o postgres -g postgres -m 700 /etc/patroni

log "Writing $PATRONI_CONF"
cat > "$PATRONI_CONF" <<EOF
scope: $CLUSTER_NAME
namespace: /service/
name: $me

restapi:
  listen: 0.0.0.0:$PATRONI_API_PORT
  connect_address: $ip:$PATRONI_API_PORT

etcd3:
  hosts: $(etcd_hosts)

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        wal_log_hints: "on"
        max_connections: 200
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 512MB
        shared_buffers: 256MB
        password_encryption: scram-sha-256
  initdb:
    - encoding: UTF8
    - data-checksums

postgresql:
  listen: 0.0.0.0:$PG_PORT
  connect_address: $ip:$PG_PORT
  data_dir: $PG_DATA
  bin_dir: $PG_BIN
  pgpass: /var/lib/pgsql/.pgpass_patroni
  authentication:
    superuser:
      username: postgres
      password: "$POSTGRES_PASSWORD"
    replication:
      username: $REPLICATION_USER
      password: "$REPLICATION_PASSWORD"
    rewind:
      username: $REWIND_USER
      password: "$REWIND_PASSWORD"
  pg_hba:
    - local all all peer
    - host all all 127.0.0.1/32 scram-sha-256
    - host replication $REPLICATION_USER $CLUSTER_SUBNET scram-sha-256
    - host all all $CLUSTER_SUBNET scram-sha-256

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
chown postgres:postgres "$PATRONI_CONF"
chmod 600 "$PATRONI_CONF"

cat > /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni ($CLUSTER_NAME)
After=network-online.target etcd.service
Wants=network-online.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=$(command -v patroni) $PATRONI_CONF
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "export PATRONICTL_CONFIG_FILE=$PATRONI_CONF" > /etc/profile.d/patroni.sh

systemctl daemon-reload
systemctl enable --now patroni
log "Patroni started as $me ($ip)"
