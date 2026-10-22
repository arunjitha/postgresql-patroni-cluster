# postgresql-patroni-cluster — 6-node Patroni HA cluster for PostgreSQL 16

A clone-and-run lab on macOS (Apple Silicon) using Vagrant + VirtualBox and
**Percona Distribution for PostgreSQL 16** on AlmaLinux 9. The cluster is
named `pgvms` (`CLUSTER_NAME` in `cluster.conf`).

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

## Setup

### 1. Check the host

Tested on macOS with Apple Silicon (arm64), 24 GB RAM, VirtualBox 7.2 and Vagrant 2.4.

| Need | Default lab usage |
|---|---|
| Free RAM | ~13 GB (6 × 2 GB + 2 × 512 MB) |
| CPU | 14 vCPUs allocated (overcommit is fine) |
| Disk | ~15 GB (linked clones of one base box) |
| Network | Internet access from the VMs (dnf + repo.percona.com) |

Short on RAM? Lower `PG_MEMORY` in `cluster.conf` (1024 works for light testing).

### 2. Install the tools

```bash
brew install --cask virtualbox    # VirtualBox 7.1+ (needed for Apple Silicon hosts)
brew install --cask vagrant       # Vagrant 2.4+
brew install libpq                # psql client only, no server
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.bash_profile   # ~/.zshrc for zsh
source ~/.bash_profile
```

After installing VirtualBox, allow its system extension in
**System Settings → Privacy & Security** if macOS asks, then reboot.

Check:

```bash
VBoxManage --version   # 7.1 or later
vagrant --version      # 2.4 or later
psql --version
```

### 3. Clone the project

```bash
git clone https://github.com/arunjitha/postgresql-patroni-cluster.git
cd postgresql-patroni-cluster
```

### 4. Review `cluster.conf` (optional)

Everything — node names, IPs, VIP, ports, VM sizing and passwords — lives in
`cluster.conf`. The defaults work as-is. If you change anything later, run
`./pglab reset` to rebuild.

Keep IPs inside `192.168.56.0/21`: VirtualBox on macOS refuses other host-only
ranges unless you list them in `/etc/vbox/networks.conf`.

### 5. Build the cluster

```bash
./pglab reset
```

This creates the 8 VMs (the first run also downloads the `bento/almalinux-9`
box) and then deploys in dependency order:

1. Base OS setup and packages on all nodes (in parallel)
2. etcd quorum on pgnode1–3
3. Patroni bootstrap of the leader on pgnode1
4. Replicas pgnode2–6 clone from the leader (in parallel)
5. `admin` superuser role
6. HAProxy + Keepalived, then a write test through the VIP

The deploy steps took about 6 minutes in testing, plus VM creation time.
It ends by printing `./pglab status`.

### 6. Verify

```bash
./pglab status
```

Expect one `Leader` in state `running`, five `Replica`s `streaming` with lag 0,
three healthy etcd endpoints, and the VIP held by `pghaproxy1`. In the HAProxy
list each node is `UP` in one pool and `DOWN` in the other — that is correct.

### 7. Connect

```bash
export PGPASSWORD=postgres_pass
psql -h 192.168.56.20 -p 5000 -U postgres   # read-write → leader
psql -h 192.168.56.20 -p 5001 -U postgres   # read-only → replicas (round robin)
```

No local psql? `./pglab psql` (or `./pglab psql ro`) runs it inside a node.

HAProxy stats: http://192.168.56.20:8080/ (admin/admin).

### 8. Run the failover test

```bash
./pglab test
```

It writes a row through the VIP, hard powers off the leader VM, waits for a new
leader, writes again through the VIP, reads both rows from the RO port, then
boots the old leader and waits for it to rejoin as a replica. In testing,
failover took about 30 seconds.

### 9. Stop and start

```bash
./pglab down       # halt all VMs, frees the RAM
./pglab up         # boot them again — services and the cluster recover on their own
./pglab teardown   # destroy all VMs
```

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
| `ssh <node>`, `logs <node> [svc]` | Shell / follow journal (default svc: patroni or haproxy) |

## Things to try

```bash
./pglab switchover pgnode3                 # planned leader change
./pglab stop-node pghaproxy1               # VIP moves to pghaproxy2
./pglab start-node pghaproxy1              # VIP moves back
./pglab ssh pgnode1                        # then: sudo patronictl list
./pglab logs pgnode2                       # follow Patroni's log
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `psql: command not found` | `brew install libpq` and add `/opt/homebrew/opt/libpq/bin` to `PATH` (step 2) |
| `The IP address configured for the host-only network is not within the allowed ranges` | Use IPs in `192.168.56.0/21`, or add your range to `/etc/vbox/networks.conf` |
| VM fails to boot / VirtualBox kernel error | Allow the VirtualBox extension in Privacy & Security and reboot |
| `timed out waiting for …` during deploy | Re-run `./pglab deploy`; check `./pglab logs <node> etcd` or `patroni` |
| `ssh` errors after VMs restart | Run any `./pglab up` / `start-node` — it refreshes `.vagrant/ssh-config` |
| Out of memory, slow VMs | Lower `PG_MEMORY` / `LB_MEMORY` in `cluster.conf`, then `./pglab reset` |

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

## Lab-only shortcuts

SELinux is permissive, firewalld is off, etcd and the Patroni REST API run
without TLS or authentication, the Patroni watchdog is off, and passwords are
plain text in `cluster.conf`. Don't use this setup in production.
