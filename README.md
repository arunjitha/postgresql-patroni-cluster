# pgvms — 6-node Patroni HA cluster for PostgreSQL 16

A clone-and-run lab on macOS (Apple Silicon) using Vagrant + VirtualBox and
**Percona Distribution for PostgreSQL 16** on AlmaLinux 9.

```
                     clients
                        │
               VIP 192.168.56.20  (Keepalived, unicast VRRP)
             ┌──────────┴──────────┐
        pghaproxy1             pghaproxy2        :5000 RW → leader
        (MASTER)               (BACKUP)          :5001 RO → replicas
             └──────────┬──────────┘             :8080 stats
     ┌────────┬────────┬┴───────┬────────┬────────┐
  pgnode1  pgnode2  pgnode3  pgnode4  pgnode5  pgnode6     PostgreSQL 16 + Patroni
  └──── etcd (3-member DCS) ───┘                           REST API :8008
```

| Node | IP | Role |
|---|---|---|
| pgnode1 | 192.168.56.11 | PostgreSQL + Patroni (bootstrap leader), etcd |
| pgnode2 | 192.168.56.12 | PostgreSQL + Patroni, etcd |
| pgnode3 | 192.168.56.13 | PostgreSQL + Patroni, etcd |
| pgnode4–6 | 192.168.56.14–16 | PostgreSQL + Patroni |
| pghaproxy1 | 192.168.56.21 | HAProxy + Keepalived (MASTER) |
| pghaproxy2 | 192.168.56.22 | HAProxy + Keepalived (BACKUP) |
| VIP | 192.168.56.20 | Floating client endpoint |

## Requirements

- Vagrant ≥ 2.4, VirtualBox ≥ 7.1 (ARM host support)
- ~14 GB free RAM with defaults (6 × 2 GB + 2 × 512 MB); adjust in `cluster.conf`
- Internet access from the VMs (dnf + repo.percona.com)

## Quick start

```bash
./pglab reset     # destroy, create 8 VMs, deploy everything
./pglab status    # Patroni members, etcd, VIP holder, HAProxy backends
./pglab test      # power off the leader, verify failover via VIP, rejoin it
```

Connect from the Mac (needs a local `psql`; otherwise `./pglab psql` runs it inside a node):

```bash
psql -h 192.168.56.20 -p 5000 -U postgres   # read-write (leader)
psql -h 192.168.56.20 -p 5001 -U postgres   # read-only (replicas, round robin)
```

HAProxy stats: http://192.168.56.20:8080/ (admin/admin).

## Commands

| Command | What it does |
|---|---|
| `reset` | Destroy all VMs, recreate, deploy |
| `up [node…]` / `down [node…]` | Start / halt VMs |
| `deploy` | (Re)provision on running VMs. **Wipes etcd and PG data** |
| `teardown` | Destroy all VMs |
| `status` | Cluster overview |
| `test` | Automated crash-failover test with data check |
| `switchover [node]` | Planned leader change |
| `stop-node` / `start-node <node>` | Hard power-off / boot one VM |
| `psql [rw\|ro]` | Connect through the VIP |
| `ssh <node>`, `logs <node> [svc]` | Shell / follow journal |

## Layout

```
cluster.conf             single source of truth: nodes, IPs, ports, sizing, passwords
Vagrantfile              builds the VMs from cluster.conf
pglab                    host CLI; drives provisioning over ssh in dependency order
scripts/
  lib.sh                 shared guest helpers
  common-setup.sh        hosts, chrony, SELinux/firewalld, Percona repo + packages
  etcd-setup.sh          3-member etcd (v3 API) DCS
  patroni-setup.sh       patroni.yml + systemd unit; bootstraps or clones
  haproxy-setup.sh       RW/RO listeners using Patroni /primary and /replica checks
  keepalived-setup.sh    VIP failover between HAProxy nodes
  cluster-state.sh       leader / health queries used by pglab
```

Deploy order: base setup (parallel) → etcd quorum → leader bootstrap on `pgnode1`
→ replicas clone in parallel → admin role → HAProxy + Keepalived → VIP check.

## Customising

Edit `cluster.conf` (IPs, node count, sizing, credentials) and run `./pglab reset`.
On macOS, VirtualBox host-only networks must sit inside `192.168.56.0/21`
unless you add ranges to `/etc/vbox/networks.conf`.

## Lab-only shortcuts

SELinux is permissive, firewalld is off, etcd and the Patroni REST API run
without TLS or authentication, the Patroni watchdog is off, and passwords are
plain text in `cluster.conf`. Don't use this setup in production.
