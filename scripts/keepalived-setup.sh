#!/usr/bin/env bash
# Keepalived floats the VIP between the HAProxy nodes over unicast VRRP.
# The first HAPROXY_NODES entry is MASTER; a node with HAProxy down goes FAULT
# and gives up the VIP.
source /opt/pglab/scripts/lib.sh

me=$(my_name)
ip=$(my_ip)
iface=$(iface_for_ip "$ip")
[[ -n $iface ]] || { echo "no interface carries $ip" >&2; exit 1; }

first=${HAPROXY_NODES%% *}
if [[ ${first%%:*} == "$me" ]]; then
  state=MASTER priority=101
else
  state=BACKUP priority=100
fi

peers=""
for n in $HAPROXY_NODES; do
  [[ ${n%%:*} == "$me" ]] || peers+="        ${n#*:}"$'\n'
done

log "Writing /etc/keepalived/keepalived.conf ($state on $iface)"
cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id $me
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    fall 2
    rise 2
}

vrrp_instance ${CLUSTER_NAME}_vip {
    state $state
    interface $iface
    virtual_router_id $KEEPALIVED_ROUTER_ID
    priority $priority
    advert_int 1
    unicast_src_ip $ip
    unicast_peer {
$peers    }
    authentication {
        auth_type PASS
        auth_pass $KEEPALIVED_PASSWORD
    }
    virtual_ipaddress {
        $VIP/${CLUSTER_SUBNET#*/} dev $iface
    }
    track_script {
        chk_haproxy
    }
}
EOF

systemctl enable keepalived
systemctl restart keepalived
log "Keepalived up ($state, priority $priority)"
