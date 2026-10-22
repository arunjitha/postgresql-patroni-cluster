#!/usr/bin/env bash
# Reads Patroni cluster state from the DCS for pglab.
# Usage:
#   cluster-state.sh leader         print the running leader's name (exit 1 if none)
#   cluster-state.sh healthy <n>    exit 0 when a leader runs and n-1 replicas stream
source /opt/pglab/scripts/lib.sh

patronictl -c "$PATRONI_CONF" list -f json | python3 -c '
import json, sys
mode = sys.argv[1]
members = json.load(sys.stdin)
leaders = [m["Member"] for m in members if m["Role"] == "Leader" and m["State"] == "running"]
if mode == "leader":
    if not leaders:
        sys.exit(1)
    print(leaders[0])
elif mode == "healthy":
    streaming = [m for m in members if m["Role"] != "Leader" and m["State"] == "streaming"]
    sys.exit(0 if leaders and len(streaming) == int(sys.argv[2]) - 1 else 1)
' "$@"
