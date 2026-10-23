# postgresql-patroni-cluster

**A hands-on tutorial: build a 6-node highly available PostgreSQL 16 cluster with Patroni on your Mac.**

This project builds a small production-style database cluster on your laptop
using virtual machines. You can then break it on purpose and watch it heal.
The guide assumes you know basic SQL and the terminal, but have never set up
high availability (HA) before.

By the end you will understand:

- why one database server is not enough, and what "high availability" means
- how PostgreSQL copies data from one server to others (streaming replication)
- how **Patroni** and **etcd** decide which server is in charge, and replace it automatically when it dies
- how **HAProxy** and **Keepalived** give applications one stable address that always points at the right server
- how to run failover, switchover and recovery drills yourself

> The cluster is named `pgvms` inside the configuration (`CLUSTER_NAME` in
> `cluster.conf`). You will see that name in commands and output.

### Background: where this lab comes from

This lab follows on from my Percona blog post
[**A Practical Guide to PostgreSQL Replication with Both Asynchronous and Synchronous Standbys**](https://www.percona.com/blog/a-practical-guide-to-postgresql-replication-with-both-asynchronous-and-synchronous-standbys/).
That post builds replication **by hand**: one primary, one asynchronous and one
synchronous standby, cloned with `pg_basebackup -R`, with
`synchronous_standby_names` set manually and the setup checked through
`pg_stat_replication`.

It stops at the question every replication setup eventually faces: **what
happens when the primary dies?** With manual replication, someone has to
notice, promote a standby, repoint the applications and rebuild the old
primary. This lab automates all of that:

| In the blog (manual) | In this lab (automated) |
|---|---|
| You run `initdb`, `pg_basebackup -R` on each standby | Patroni bootstraps the primary and clones every replica |
| You edit `postgresql.conf` / `pg_hba.conf` on each server | One config in Patroni/etcd, applied to every node |
| You set `synchronous_standby_names` | Patroni sets it for you in synchronous mode ([Lab 11](#lab-11--async-and-sync-standbys-the-blog-setup-automated)) |
| You promote a standby by hand after a failure | Patroni elects and promotes the best replica in ~30 s |
| Applications need the new primary's address | HAProxy + a floating VIP: the address never changes |
| You rebuild the old primary | Patroni rejoins it with `pg_rewind` |

The core replication settings are the same as in the blog (`wal_level =
replica`, `max_wal_senders = 10`, `wal_keep_size = 512MB`, `hot_standby = on`),
so you can read the two side by side.

---

## Contents

1. [The problem this solves](#1-the-problem-this-solves)
2. [Core concepts in plain words](#2-core-concepts-in-plain-words)
3. [What you will build](#3-what-you-will-build)
4. [The tools, one by one](#4-the-tools-one-by-one)
5. [How it all fits together](#5-how-it-all-fits-together)
6. [Setup, step by step](#6-setup-step-by-step)
7. [What `./pglab reset` does under the hood](#7-what-pglab-reset-does-under-the-hood)
8. [Hands-on labs](#8-hands-on-labs)
9. [Command reference](#9-command-reference)
10. [Troubleshooting](#10-troubleshooting)
11. [Project layout](#11-project-layout)
12. [From lab to production](#12-from-lab-to-production)
13. [Glossary](#13-glossary)

---

## 1. The problem this solves

A single PostgreSQL server is a **single point of failure**. If the machine
crashes, loses power or needs a reboot for patching, every application that
uses it stops working until someone fixes it, often at 3 a.m.

High availability means: **keep several copies of the database on different
machines, and when the main one fails, promote a copy and move traffic to it
automatically — in seconds, without a human.**

That needs four things to work together:

| Need | Solved by |
|---|---|
| Keep up-to-date copies of the data | PostgreSQL **streaming replication** |
| Decide which server is the main one, safely | **Patroni** + **etcd** |
| Send application traffic to the main server | **HAProxy** |
| Give applications one address that never changes | **Keepalived** (virtual IP) |

---

## 2. Core concepts in plain words

**Primary (leader)** — the one server that accepts writes (`INSERT`, `UPDATE`,
`DELETE`, `CREATE TABLE`). There is exactly one at any moment.

**Replica (standby)** — a server that keeps a live copy of the primary's data.
It can answer read-only queries but rejects writes.

**WAL (Write-Ahead Log)** — before PostgreSQL changes any data file, it writes
a description of the change to the WAL. The WAL is the database's diary.
Replicas stay up to date by receiving the primary's WAL and replaying it.

**Streaming replication** — the primary sends WAL records to replicas over the
network as they are produced. Replicas are usually milliseconds behind.

**Asynchronous replication** (used here) — the primary does not wait for
replicas to confirm before telling the client "committed". Fast, but a crash
can lose the last few transactions that had not reached a replica yet.

**Synchronous replication** — the primary waits until at least one chosen
replica has the WAL before confirming a commit. No committed data is lost on
failover, at the cost of slightly slower commits. Lab 11 shows both kinds
side by side, like the blog post.

**Failover** — unplanned: the primary dies, and a replica is promoted to
replace it.

**Switchover** — planned: you move the primary role to another server on
purpose, for example before patching. No data is lost.

**Split-brain** — the disaster HA must prevent: two servers both believe they
are the primary and both accept writes. The data diverges and cannot be merged
cleanly. Everything in this design exists to make split-brain impossible.

**Consensus and quorum** — to avoid split-brain, servers must *agree* who the
leader is. A group agrees by majority vote: with 3 voters, 2 is a majority
(quorum). Any decision needs a majority, so two halves of a broken network can
never both decide.

**Timeline** — a counter that PostgreSQL increases every time a replica is
promoted. It marks "history branched here", so servers can tell old WAL from
new WAL after a failover.

**Virtual IP (VIP)** — an IP address not tied to one machine. It can move
between machines in about a second, so clients always connect to the same
address.

---

## 3. What you will build

Eight virtual machines on a private network inside your Mac:

```
                         your Mac / applications
                                  │
                        VIP 192.168.56.20  ← one stable address
                   (Keepalived moves it if a node dies)
                ┌─────────────────┴─────────────────┐
           pghaproxy1                          pghaproxy2
         192.168.56.21                       192.168.56.22
        HAProxy (MASTER)                    HAProxy (BACKUP)
                │   :5000 read-write → current primary
                │   :5001 read-only  → replicas (round robin)
                │   :8080 statistics page
     ┌────────┬─┴──────┬────────┬────────┬────────┐
  pgnode1  pgnode2  pgnode3  pgnode4  pgnode5  pgnode6
   .11      .12      .13      .14      .15      .16
  ───────────────── PostgreSQL 16 + Patroni on every node ─────────────────
  └──── etcd (3 voters) ────┘
```

| Node | IP | Runs | CPU / RAM |
|---|---|---|---|
| pgnode1 | 192.168.56.11 | PostgreSQL, Patroni, etcd — first primary | 2 / 2 GB |
| pgnode2 | 192.168.56.12 | PostgreSQL, Patroni, etcd | 2 / 2 GB |
| pgnode3 | 192.168.56.13 | PostgreSQL, Patroni, etcd | 2 / 2 GB |
| pgnode4 | 192.168.56.14 | PostgreSQL, Patroni | 2 / 2 GB |
| pgnode5 | 192.168.56.15 | PostgreSQL, Patroni | 2 / 2 GB |
| pgnode6 | 192.168.56.16 | PostgreSQL, Patroni | 2 / 2 GB |
| pghaproxy1 | 192.168.56.21 | HAProxy, Keepalived (preferred VIP holder) | 1 / 512 MB |
| pghaproxy2 | 192.168.56.22 | HAProxy, Keepalived (standby) | 1 / 512 MB |
| — | 192.168.56.20 | the VIP | — |

**Why these numbers?**

- **3 etcd voters**: the smallest group that survives losing one member (2 of 3
  is still a majority). With 2 voters, losing one leaves no majority.
- **6 PostgreSQL nodes**: more than you need for HA (2–3 is common), so you can
  experiment with several failures and see replicas spread read traffic.
- **2 HAProxy nodes**: HAProxy itself must not become the new single point of
  failure.

---

## 4. The tools, one by one

### 4.1 VirtualBox — the virtual machines

**What it is:** free virtualisation software from Oracle. It runs complete
computers (virtual machines, VMs) inside your Mac, each with its own operating
system, CPU, memory, disk and network card.

**What it does here:** runs the 8 Linux servers. Each VM gets two network cards:

- **Adapter 1, NAT** (`enp0s8` inside the VM) — lets the VM reach the internet
  to download packages.
- **Adapter 2, host-only** (`enp0s9`) — a private network `192.168.56.0/24`
  shared by the VMs and your Mac. All cluster traffic and your `psql`
  connections use this one.

### 4.2 Vagrant — VMs as code

**What it is:** a tool from HashiCorp that creates and manages VMs from a text
file called the `Vagrantfile`, so anyone can rebuild the same machines with one
command.

**What it does here:** the `Vagrantfile` reads `cluster.conf` and, for each
node, sets the name, IP, CPU and memory, and starts it from the base image
**`bento/almalinux-9`** (an AlmaLinux 9 image built by the Bento project, with
an arm64 version for Apple Silicon). `linked_clone = true` makes all VMs share
one copy of the base disk, which saves space and time.

Useful Vagrant commands (`pglab` wraps them for you):

```bash
vagrant status           # which VMs exist and whether they are running
vagrant ssh pgnode1      # log in to a VM
vagrant halt pgnode1     # shut one down
vagrant destroy -f       # delete all VMs
```

### 4.3 AlmaLinux 9 — the operating system

A free, community-built Linux that is binary-compatible with Red Hat Enterprise
Linux (RHEL) 9 — the most common OS for PostgreSQL in companies. Packages are
installed with `dnf`, services are managed with `systemd`.

`scripts/common-setup.sh` prepares every VM:

- writes `/etc/hosts`, so nodes can reach each other by name (`pgnode1`, …)
- starts **chrony**, which keeps the clock in sync — clustered software relies
  on timestamps and leases, so clocks must agree
- sets SELinux to permissive and turns off firewalld (lab shortcut, see §12)

### 4.4 PostgreSQL 16 (Percona Distribution)

**What it is:** the database. This lab uses **Percona Distribution for
PostgreSQL 16** — standard open-source PostgreSQL, packaged and tested by
Percona together with the HA tools you need (Patroni, etcd, HAProxy,
pgBackRest, …), all from one repository (`percona-release setup ppg-16`).

**Where things live on each PG node:**

| What | Path |
|---|---|
| Programs (`postgres`, `pg_ctl`, `pg_rewind`, …) | `/usr/pgsql-16/bin` |
| Data directory | `/var/lib/pgsql/16/data` |
| Port | 5432 |

**Important:** PostgreSQL is *not* started by its own `postgresql-16` service.
Patroni starts, stops, configures and promotes it. If you start PostgreSQL by
hand behind Patroni's back, you can break the cluster.

**PostgreSQL features this lab relies on:**

| Feature | Setting | Why |
|---|---|---|
| WAL with enough detail for replicas | `wal_level: replica` | replicas need full WAL |
| Read queries on replicas | `hot_standby: on` | lets port 5001 serve reads |
| Several replica connections | `max_wal_senders: 10` | one sender per replica |
| Replication slots | `use_slots: true`, `max_replication_slots: 10` | the primary keeps WAL until each replica has received it |
| Rewind after failover | `use_pg_rewind: true`, `wal_log_hints: on` | lets an old primary rejoin without a full copy |
| Data checksums | `initdb: data-checksums` | detects disk corruption |
| Password hashing | `password_encryption: scram-sha-256` | modern, secure password auth |

**pg_rewind** deserves a word. When the old primary crashes, it may have a few
WAL records the new primary never received. Its history has *diverged*. Before
it can follow the new primary, `pg_rewind` rolls back just the changed blocks to
the point where the histories split, instead of copying the whole database
again.

### 4.5 etcd — the source of truth

**What it is:** a small, very reliable key-value store, also used by
Kubernetes. Its members use the **Raft** consensus algorithm: every write must
be accepted by a majority before it counts, so all members always agree on the
data.

**What it does here:** stores the cluster's shared state, the **DCS**
(Distributed Configuration Store, in Patroni's terms). Most importantly, the
**leader key** says who the primary is. etcd runs on pgnode1–3, with port 2379
for clients (Patroni) and port 2380 for etcd members talking to each other.

The keys Patroni keeps in etcd (you will look at them in Lab 2):

| Key | Meaning |
|---|---|
| `/service/pgvms/leader` | name of the current primary — **with an expiry time** |
| `/service/pgvms/members/<node>` | each node's address, role, state and WAL position |
| `/service/pgvms/config` | cluster-wide settings (`ttl`, PostgreSQL parameters, …) |
| `/service/pgvms/initialize` | the cluster's system ID, written once at bootstrap |
| `/service/pgvms/history` | list of past failovers and timelines |
| `/service/pgvms/status` | last known WAL position of the leader, slot positions |

Config file: `/etc/etcd/etcd.conf.yaml`. Service: `etcd`.

### 4.6 Patroni — the HA brain

**What it is:** an open-source HA manager for PostgreSQL, written in Python. One
Patroni process runs on every PostgreSQL node and fully controls the PostgreSQL
there.

**What it does here — the main loop.** Every `loop_wait` (10 seconds), each
Patroni asks etcd: *"Is there a leader key, and is it mine?"*

- **If I am the leader:** renew the leader key, which keeps it alive for
  another `ttl` (30) seconds, and keep PostgreSQL running as primary.
- **If someone else is the leader:** make sure my PostgreSQL is a replica
  streaming from that node.
- **If there is no leader key** (it expired because the leader died): take part
  in an election. A node may take the key only if it is healthy, its data is
  not too far behind (`maximum_lag_on_failover`: 1 MB), and no other replica is
  further ahead. The winner creates the key in etcd — etcd lets only one node
  succeed — and promotes its PostgreSQL to primary.

The leader key is a **lease**: if the leader stops renewing it (crash, power
loss, network cut), it disappears by itself after 30 seconds. And a primary
that can no longer reach etcd **demotes itself** to read-only, because it can
no longer prove it still holds the key. Those two rules together prevent
split-brain.

**Bootstrap and cloning.** On the first node, Patroni finds an empty cluster in
etcd, runs `initdb` to create a new database, and takes the leader key. On
every other node it finds an existing leader, copies the data with
`pg_basebackup`, and starts as a replica.

**REST API (port 8008).** Each Patroni answers HTTP requests about its node:

| Endpoint | Returns 200 when | Used by |
|---|---|---|
| `/primary` | this node is the primary | HAProxy port 5000 |
| `/replica` | this node is a healthy, running replica | HAProxy port 5001 |
| `/patroni` | always — full status as JSON | you, monitoring |
| `/health` | PostgreSQL is running | monitoring |

Otherwise these endpoints return `503`. That is how HAProxy knows where to send
traffic without ever talking to etcd.

**patronictl** is the command-line tool for operators: list members, switch
over, change settings, pause automation, restart nodes.

Config file: `/etc/patroni/patroni.yml`. Service: `patroni`.

### 4.7 HAProxy — the traffic router

**What it is:** a fast, widely used load balancer and proxy for TCP and HTTP.

**What it does here:** applications connect to HAProxy instead of to a database
node. HAProxy forwards each connection to the right PostgreSQL node:

| Port | Name | Sends connections to | Health check |
|---|---|---|---|
| 5000 | `primary` | the one node that answers 200 on `/primary` | `OPTIONS /primary` on 8008 |
| 5001 | `replicas` | every node answering 200 on `/replica`, in turn (round robin) | `OPTIONS /replica` on 8008 |
| 8080 | `stats` | a web page showing every backend's state | — |

Every 3 seconds (`inter 3s`) HAProxy calls each node's Patroni API. A node is
marked down after 3 failed checks (`fall 3`) and up again after 2 good ones
(`rise 2`). `on-marked-down shutdown-sessions` cuts existing connections to a
node the moment it is marked down, so no client stays connected to an old
primary.

Config file: `/etc/haproxy/haproxy.cfg`. Service: `haproxy`.

### 4.8 Keepalived — the floating IP

**What it is:** a Linux daemon that implements **VRRP** (Virtual Router
Redundancy Protocol): a group of machines shares one virtual IP, and exactly
one of them holds it at a time.

**What it does here:** both HAProxy nodes run Keepalived. They send each other
a heartbeat every second (`advert_int 1`), directly to each other's IP
(`unicast_peer`).

- **pghaproxy1** has priority 101 → MASTER, holds `192.168.56.20`
- **pghaproxy2** has priority 100 → BACKUP, waits
- every 2 seconds each node checks that HAProxy is still running
  (`killall -0 haproxy`). If HAProxy dies, that node enters FAULT state and
  gives up the VIP.
- if the BACKUP stops hearing heartbeats, or the MASTER enters FAULT, the
  BACKUP adds the VIP to its own network card and announces it to the network.
  This takes a few seconds.
- when pghaproxy1 is healthy again, its higher priority takes the VIP back.

Config file: `/etc/keepalived/keepalived.conf`. Service: `keepalived`.

### 4.9 pglab — the lab's control script

**What it is:** a bash script in this repo that runs on your Mac.

**What it does:** wraps Vagrant and ssh so you can run the whole lab with
single commands: build (`reset`), inspect (`status`), test (`test`), and
operate (`switchover`, `stop-node`, `psql`, `logs` …). It pushes
`cluster.conf` and `scripts/` to every VM over ssh and runs the setup scripts
in the right order (see §7).

### 4.10 cluster.conf — one file for every setting

All names, IPs, ports, VM sizes and passwords are in `cluster.conf`. The
`Vagrantfile`, `pglab` and every setup script read it, so you change a value in
one place and run `./pglab reset`.

---

## 5. How it all fits together

### 5.1 The path of a query

```
psql -h 192.168.56.20 -p 5000
   │
   ▼
VIP 192.168.56.20 ── currently held by pghaproxy1 (Keepalived)
   │
   ▼
HAProxy "primary" listener on :5000
   │  asks each node's Patroni every 3 s: GET /primary → only the leader says 200
   ▼
PostgreSQL on the current primary (e.g. pgnode1:5432)
   │  WAL streams to every replica
   ▼
pgnode2 … pgnode6 replay the WAL and serve reads on :5001
```

### 5.2 What happens when the primary crashes

Timeline with the lab's settings (`ttl: 30`, `loop_wait: 10`):

| Time | What happens |
|---|---|
| 0 s | pgnode1 (primary) loses power. It stops renewing the leader key. |
| 0–9 s | HAProxy's `/primary` checks to pgnode1 fail; after 3 failures pgnode1 is marked DOWN on port 5000. Writes now fail — there is no primary. |
| ≤ 30 s | The leader key's lease runs out; etcd deletes it. |
| next loop (≤ 10 s) | Each replica's Patroni sees no leader. They compare WAL positions; the most up-to-date healthy replica takes the leader key. |
| + 1–2 s | The winner runs `pg_promote`: it becomes primary on a new **timeline** (1 → 2). The other replicas switch to streaming from it. |
| + 3–6 s | HAProxy's `/primary` check now gets 200 from the new primary → port 5000 is back. |
| later | When pgnode1 boots, Patroni sees someone else holds the key, uses `pg_rewind` to undo its few divergent changes, and rejoins as a replica. |

Measured in this lab: **about 30 seconds** from power-off to writes working
again. Lowering `ttl` and `loop_wait` makes it faster but makes false
failovers more likely on a slow network.

### 5.3 Why split-brain can't happen

- Only the node holding the etcd leader key may be primary, and etcd
  guarantees only one node can hold it.
- The key expires if the leader goes silent, and a primary that can't reach
  etcd demotes itself before its lease could be given to someone else.
- etcd needs 2 of 3 members to agree on any change, so a network split can't
  produce two leaders.
- HAProxy only sends writes to a node that *currently* says it is primary.

---

## 6. Setup, step by step

### Step 1 — Check your Mac

Tested on macOS with Apple Silicon (arm64), 24 GB RAM, VirtualBox 7.2 and
Vagrant 2.4.

| Need | With the default settings |
|---|---|
| Free RAM | ~13 GB (6 × 2 GB + 2 × 512 MB) |
| Disk | ~15 GB |
| Internet | the VMs download packages from the AlmaLinux and Percona repos |

Short on RAM? Set `PG_MEMORY="1024"` in `cluster.conf`.

### Step 2 — Install the tools

```bash
brew install --cask virtualbox    # VirtualBox 7.1+ (needed for Apple Silicon)
brew install --cask vagrant       # Vagrant 2.4+
brew install libpq                # psql client only, no server
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.bash_profile   # use ~/.zshrc for zsh
source ~/.bash_profile
```

If macOS asks, allow the VirtualBox system extension in
**System Settings → Privacy & Security**, then reboot.

Check the versions:

```bash
VBoxManage --version   # 7.1 or later
vagrant --version      # 2.4 or later
psql --version
```

### Step 3 — Get the project

```bash
git clone https://github.com/arunjitha/postgresql-patroni-cluster.git
cd postgresql-patroni-cluster
```

### Step 4 — Look at `cluster.conf` (optional)

The defaults work. If you change IPs, keep them in `192.168.56.0/21`:
VirtualBox on macOS refuses other host-only ranges unless you add them to
`/etc/vbox/networks.conf`.

### Step 5 — Build the cluster

```bash
./pglab reset
```

The first run also downloads the `bento/almalinux-9` image. Once the VMs are
up, the deploy took about 6 minutes in testing. The command ends by printing
the cluster status. §7 explains each stage.

### Step 6 — Check that it is healthy

```bash
./pglab status
```

A healthy cluster looks like this:

```
+ Cluster: pgvms ---------+---------+-----------+----+-------------+-----+
|  Member |      Host     |   Role  |   State   | TL | Receive LSN | Lag |
+---------+---------------+---------+-----------+----+-------------+-----+
| pgnode1 | 192.168.56.11 | Leader  | running   |  1 |             |     |
| pgnode2 | 192.168.56.12 | Replica | streaming |  1 |   0/6001138 |   0 |
| ...                                                                     |
```

- exactly one **Leader** in state `running`
- five **Replica**s in state `streaming`, `Lag` 0
- three etcd endpoints with no errors, one of them `IS LEADER: true` (etcd's
  own Raft leader, unrelated to the PostgreSQL leader)
- the VIP held by `pghaproxy1`
- in the HAProxy list, each node is `UP` in one pool and `DOWN` in the other —
  that is correct: the primary is only in `primary`, replicas only in
  `replicas`.

### Step 7 — Connect

```bash
export PGPASSWORD=postgres_pass
psql -h 192.168.56.20 -p 5000 -U postgres   # read-write → primary
psql -h 192.168.56.20 -p 5001 -U postgres   # read-only → replicas
```

No `psql` on your Mac? `./pglab psql` (or `./pglab psql ro`) runs it inside a VM.

HAProxy statistics page: http://192.168.56.20:8080/ (user `admin`, password `admin`).

### Step 8 — Stop and start

```bash
./pglab down       # shut down all VMs and free the RAM
./pglab up         # start them again; the cluster recovers by itself
./pglab teardown   # delete all VMs
```

---

## 7. What `./pglab reset` does under the hood

`reset` = `vagrant destroy` + `vagrant up` + `pglab deploy`. The deploy runs
these steps from your Mac, over ssh:

| # | Step | Script | Runs on | Details |
|---|---|---|---|---|
| 1 | Push files | — | all 8 | copies `cluster.conf` and `scripts/` to `/opt/pglab` |
| 2 | Base setup | `common-setup.sh` | all 8, in parallel | `/etc/hosts`, chrony, SELinux, firewalld. PG nodes: EPEL, CRB, Percona repo, install `percona-postgresql16-server`, `percona-patroni`, `etcd`. LB nodes: install `haproxy`, `keepalived` |
| 3 | Stop Patroni | — | pgnode1–6 | makes re-deploys safe |
| 4 | etcd | `etcd-setup.sh` | pgnode1–3, together | writes `/etc/etcd/etcd.conf.yaml`, starts etcd; pglab waits until `etcdctl endpoint health` passes on all 3 |
| 5 | First primary | `patroni-setup.sh` | pgnode1 | writes `/etc/patroni/patroni.yml` and a systemd unit, starts Patroni → `initdb` → takes leader key |
| 6 | Replicas | `patroni-setup.sh` | pgnode2–6, in parallel | same config; Patroni sees a leader, runs `pg_basebackup`, starts streaming. pglab waits for 5 `streaming` replicas |
| 7 | Admin user | — | primary | `CREATE ROLE admin … SUPERUSER` |
| 8 | Load balancers | `haproxy-setup.sh`, `keepalived-setup.sh` | pghaproxy1–2 | writes configs, starts both; pglab waits until `SELECT 1` works through VIP:5000 |
| 9 | Status | `cluster-state.sh` | — | prints `./pglab status` |

Order matters: Patroni needs etcd, replicas need a primary, and HAProxy is only
useful once the database answers.

> `./pglab deploy` on its own re-runs steps 1–9 on existing VMs. It **erases**
> all database and etcd data and builds a fresh cluster.

---

## 8. Hands-on labs

Run each lab from the project folder. Set the password once per terminal:

```bash
export PGPASSWORD=postgres_pass
```

The output shown is from a real run; your leader and numbers may differ.

### Lab 1 — Meet Patroni

```bash
./pglab ssh pgnode1
sudo patronictl -c /etc/patroni/patroni.yml list           # members, roles, lag
sudo patronictl -c /etc/patroni/patroni.yml show-config    # cluster-wide settings
sudo patronictl -c /etc/patroni/patroni.yml history        # past failovers
sudo cat /etc/patroni/patroni.yml                          # this node's config
exit
```

`show-config` prints settings stored in etcd, such as `ttl: 30`,
`loop_wait: 10`, `use_pg_rewind: true`. They apply to every node.

### Lab 2 — Look inside etcd

```bash
./pglab ssh pgnode1
etcdctl endpoint status --cluster -w table                 # the 3 etcd members
etcdctl get --prefix /service/pgvms/ --keys-only           # every key Patroni uses
etcdctl get /service/pgvms/leader --print-value-only       # who is primary right now
etcdctl get /service/pgvms/members/pgnode2 --print-value-only
exit
```

Expected keys:

```
/service/pgvms/config
/service/pgvms/history
/service/pgvms/initialize
/service/pgvms/leader
/service/pgvms/members/pgnode1 … pgnode6
/service/pgvms/status
```

**Takeaway:** the whole cluster's view of "who is primary" is that one
`leader` key.

### Lab 3 — Ask Patroni over HTTP, like HAProxy does

From your Mac:

```bash
for ip in 11 12 13 14 15 16; do
  printf "192.168.56.$ip  /primary=%s  /replica=%s\n" \
    "$(curl -s -o /dev/null -w '%{http_code}' http://192.168.56.$ip:8008/primary)" \
    "$(curl -s -o /dev/null -w '%{http_code}' http://192.168.56.$ip:8008/replica)"
done

curl -s http://192.168.56.11:8008/patroni | python3 -m json.tool
```

The primary answers `200` on `/primary` and `503` on `/replica`; every replica
answers the opposite. HAProxy's health checks do exactly this.

### Lab 4 — Watch replication

```bash
psql -h 192.168.56.20 -p 5000 -U postgres
```

```sql
-- On the primary: who is connected to me as a replica?
SELECT application_name, client_addr, state, sync_state
FROM pg_stat_replication ORDER BY 1;

-- One replication slot per replica keeps WAL until they have it
SELECT slot_name, active FROM pg_replication_slots ORDER BY 1;

-- Write something
CREATE TABLE demo (id serial PRIMARY KEY, note text, at timestamptz DEFAULT now());
INSERT INTO demo (note) VALUES ('hello from the primary');
```

Expected: 5 rows `streaming | async`, and 5 active slots. Now read it on a replica:

```bash
psql -h 192.168.56.20 -p 5001 -U postgres -c "SELECT inet_server_addr(), * FROM demo;"
```

The row is already there, on a different server.

### Lab 5 — Read-only routing and round robin

```bash
for i in 1 2 3 4 5; do
  psql -h 192.168.56.20 -p 5001 -U postgres -XAtc "SELECT inet_server_addr()"
done
```

Each connection goes to the next replica:

```
192.168.56.11
192.168.56.12
192.168.56.13
...
```

Now try writing through the read-only port:

```bash
psql -h 192.168.56.20 -p 5001 -U postgres -c "CREATE TABLE nope (id int);"
# ERROR:  cannot execute CREATE TABLE in a read-only transaction
```

Replicas can't accept writes. That's why applications use port 5000 for writes.

### Lab 6 — Planned switchover

```bash
./pglab status                # note the current leader
./pglab switchover pgnode3    # move the primary role to pgnode3
```

Patroni cleanly stops writes on the old primary, makes sure pgnode3 has every
WAL record, promotes pgnode3, and makes the old primary a replica. No data is
lost. Run `patronictl history` (Lab 1) and you'll see a new timeline.

### Lab 7 — Crash the primary (automatic failover)

Automated:

```bash
./pglab test
```

Or by hand, in two terminals. **Terminal A** — keep writing through the VIP:

```bash
while true; do
  psql -h 192.168.56.20 -p 5000 -U postgres -XAtc \
    "INSERT INTO demo (note) VALUES ('tick') RETURNING inet_server_addr(), now()::time" \
    2>&1 | tail -1
  sleep 1
done
```

**Terminal B** — pull the plug on the primary (use the leader's name):

```bash
./pglab stop-node pgnode1     # hard power-off, like a power cut
```

Watch terminal A: errors for about 30 seconds (§5.2 explains why), then inserts
succeed again **on a different server address**. Then:

```bash
./pglab status                # new leader, timeline went up by 1
./pglab start-node pgnode1    # bring the old primary back
./pglab status                # pgnode1 rejoins as a Replica (pg_rewind)
```

### Lab 8 — Kill a load balancer (VIP failover)

```bash
./pglab ssh pghaproxy1
ip -4 addr show enp0s9        # note: both .21 and the VIP .20 are listed
sudo systemctl stop haproxy   # Keepalived notices within ~4 s
exit

./pglab status                # VIP now held by pghaproxy2
psql -h 192.168.56.20 -p 5000 -U postgres -c "SELECT 1"   # still works

./pglab ssh pghaproxy1 -- sudo systemctl start haproxy
./pglab status                # VIP back on pghaproxy1 (higher priority)
```

To follow Keepalived's state changes: `./pglab logs pghaproxy2 keepalived`.

### Lab 8b — Watch the HAProxy stats page during a failover

Open http://192.168.56.20:8080/ (admin/admin) and run `./pglab test` in a
terminal. The page refreshes every 5 seconds: the `primary` backend's green
row moves from the old leader to the new one.

### Lab 9 — Change a PostgreSQL setting cluster-wide

```bash
./pglab ssh pgnode1
sudo patronictl -c /etc/patroni/patroni.yml edit-config \
  -p work_mem=16MB --force
sudo patronictl -c /etc/patroni/patroni.yml list
exit
psql -h 192.168.56.20 -p 5001 -U postgres -XAtc "SHOW work_mem"   # 16MB on replicas too
```

Patroni stores the change in etcd and every node applies it. For settings that
need a restart (like `shared_buffers`), `list` shows a `Pending restart` column;
apply it with `patronictl restart pgvms --force`.

### Lab 10 — Maintenance mode

```bash
./pglab ssh pgnode1
sudo patronictl -c /etc/patroni/patroni.yml pause    # Patroni stops acting
sudo patronictl -c /etc/patroni/patroni.yml list     # shows "Maintenance mode: on"
sudo patronictl -c /etc/patroni/patroni.yml resume   # back to automatic
exit
```

While paused, Patroni won't fail over or restart anything. You'd use this
when you need to work on PostgreSQL by hand.

### Lab 11 — Async and sync standbys (the blog setup, automated)

The [blog post](https://www.percona.com/blog/a-practical-guide-to-postgresql-replication-with-both-asynchronous-and-synchronous-standbys/)
mixes one synchronous and one asynchronous standby by setting
`synchronous_standby_names` by hand. Patroni can do the same, and keep it
correct through failovers, with **synchronous mode**.

Turn it on:

```bash
./pglab ssh pgnode1 -- sudo patronictl -c /etc/patroni/patroni.yml edit-config -s synchronous_mode=true --force
sleep 15
./pglab ssh pgnode1 -- sudo patronictl -c /etc/patroni/patroni.yml list
```

One replica's role changes to **Sync Standby**; the rest stay async:

```
| pgnode1 | 192.168.56.11 | Sync Standby | streaming |  3 | ...
| pgnode2 | 192.168.56.12 | Replica      | streaming |  3 | ...
| pgnode6 | 192.168.56.16 | Leader       | running   |  3 | ...
```

Look at what Patroni did on the primary — the same things the blog configures manually:

```bash
psql -h 192.168.56.20 -p 5000 -U postgres -XAt \
  -c "SHOW synchronous_standby_names" \
  -c "SELECT application_name, sync_state FROM pg_stat_replication ORDER BY 1"
```

```
pgnode1
pgnode1|sync
pgnode2|async
pgnode3|async
...
```

Want two synchronous standbys?

```bash
./pglab ssh pgnode1 -- sudo patronictl -c /etc/patroni/patroni.yml edit-config -s synchronous_node_count=2 --force
# synchronous_standby_names becomes: 2 (pgnode1,pgnode3)
```

**What changes:** a commit on the primary now waits until the sync standby has
the WAL, so a failover never loses a committed transaction. Patroni also only
promotes the sync standby on failover, and picks a new sync standby if the
current one goes away. The cost is a little extra latency on every commit.

Try Lab 7 again with synchronous mode on and watch which node becomes leader.

Switch back to fully async:

```bash
./pglab ssh pgnode1 -- sudo patronictl -c /etc/patroni/patroni.yml edit-config -s synchronous_mode=false -s synchronous_node_count=1 --force
```

### Lab 12 — Lose etcd quorum (what protects you)

> Run this last; it makes the cluster read-only until you restore etcd.

```bash
./pglab ssh pgnode2 -- sudo systemctl stop etcd   # 2 of 3 still OK
./pglab status                                     # still fine
./pglab ssh pgnode3 -- sudo systemctl stop etcd   # only 1 of 3 left: no quorum
```

Wait about 30 seconds, then check:

```bash
psql -h 192.168.56.20 -p 5000 -U postgres -c "SELECT 1"
# fails: HAProxy has no primary to send you to
./pglab ssh pgnode6 -- "sudo -u postgres psql -XAtc 'SELECT pg_is_in_recovery()'"
# t  — the old primary (use your leader's name) is now read-only
./pglab ssh pgnode1 -- sudo patronictl -c /etc/patroni/patroni.yml list
# ... Etcd is not responding properly
```

The primary can no longer renew its leader key, so Patroni **demotes it** and
writes stop. Patroni won't risk split-brain. Reads on replicas still work.

Restore etcd:

```bash
./pglab ssh pgnode2 -- sudo systemctl start etcd
./pglab ssh pgnode3 -- sudo systemctl start etcd
./pglab status       # within a minute a leader is elected again, on a new timeline
```

**Takeaway:** protect etcd as carefully as the database. In production, put it
on separate machines in separate failure zones.

---

## 9. Command reference

| Command | What it does |
|---|---|
| `./pglab reset` | Delete all VMs, recreate them, deploy everything |
| `./pglab up [node…]` | Create or start VMs |
| `./pglab deploy` | Set up the cluster on running VMs — **erases data** |
| `./pglab down [node…]` | Shut down VMs |
| `./pglab teardown` | Delete all VMs |
| `./pglab status` | Patroni members, etcd health, VIP holder, HAProxy backends |
| `./pglab test` | Crash the primary, check failover and rejoin |
| `./pglab switchover [node]` | Planned primary change |
| `./pglab stop-node <node>` | Hard power-off one VM |
| `./pglab start-node <node>` | Boot one VM; its services start automatically |
| `./pglab psql [rw\|ro]` | Connect through the VIP (5000 or 5001) |
| `./pglab ssh <node> [-- command]` | Log in to a VM, or run one command on it |
| `./pglab logs <node> [service]` | Follow a service's log (default: `patroni` on PG nodes, `haproxy` on LB nodes) |

Inside a PG node:

```bash
sudo patronictl -c /etc/patroni/patroni.yml list | history | show-config | edit-config | switchover | restart | reinit <node> | pause | resume
etcdctl endpoint status --cluster -w table
sudo journalctl -u patroni -f          # or -u etcd
```

---

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `psql: command not found` | `brew install libpq` and add `/opt/homebrew/opt/libpq/bin` to `PATH` (Step 2) |
| `The IP address configured for the host-only network is not within the allowed ranges` | Use IPs in `192.168.56.0/21`, or add your range to `/etc/vbox/networks.conf` |
| VMs fail to start, VirtualBox kernel driver error | Allow the VirtualBox extension in Privacy & Security, then reboot |
| `timed out waiting for …` during deploy | Re-run `./pglab deploy`; look at `./pglab logs <node> etcd` or `./pglab logs <node>` |
| ssh errors after VMs restart | `./pglab up` or `start-node` refreshes `.vagrant/ssh-config` |
| A replica stuck in `starting` or `stopped` | `sudo patronictl -c /etc/patroni/patroni.yml reinit pgvms <node>` re-copies it from the primary |
| No leader, writes fail | Check etcd first (`etcdctl endpoint health --cluster`); Lab 12 explains why |
| Mac slow or out of memory | Lower `PG_MEMORY` / `LB_MEMORY` in `cluster.conf`, then `./pglab reset` |

---

## 11. Project layout

```
cluster.conf             every setting: nodes, IPs, ports, VM sizes, passwords
Vagrantfile              builds the VMs from cluster.conf
pglab                    host control script (runs on your Mac)
scripts/
  lib.sh                 shared helpers for the scripts below
  common-setup.sh        OS prep and package install (all nodes)
  etcd-setup.sh          etcd member config + service (pgnode1–3)
  patroni-setup.sh       patroni.yml + service (pgnode1–6)
  haproxy-setup.sh       HAProxy listeners and health checks
  keepalived-setup.sh    VIP failover between the HAProxy nodes
  cluster-state.sh       leader / health queries that pglab uses
```

---

## 12. From lab to production

This lab takes shortcuts to stay simple. A production cluster should also have:

| Lab shortcut | In production |
|---|---|
| SELinux permissive, firewalld off | SELinux enforcing; firewall only the needed ports |
| etcd and Patroni API over plain HTTP, no auth | TLS everywhere, client certificates, REST API auth |
| etcd on the database nodes | etcd on its own 3 or 5 small machines, in different zones |
| Passwords in a text file | a secrets manager; strong, rotated passwords |
| No watchdog | Linux `softdog`/hardware watchdog so a hung primary is reset |
| Asynchronous replication | `synchronous_mode` (Lab 11) if losing any committed transaction is unacceptable |
| No backups | **pgBackRest** (also in the Percona distribution) with WAL archiving and restore tests |
| No monitoring | Percona Monitoring and Management (PMM) or Prometheus + alerting |
| All VMs on one laptop | separate hosts, racks or availability zones |

Remember: **replication is not a backup.** A `DROP TABLE` reaches every
replica within milliseconds.

---

## 13. Glossary

| Term | Meaning |
|---|---|
| **Async replication** | primary confirms commits without waiting for replicas |
| **Consensus** | members of a group agreeing on one value even if some fail (etcd uses Raft) |
| **DCS** | Distributed Configuration Store — Patroni's name for etcd/Consul/ZooKeeper |
| **Failover** | automatic promotion of a replica after the primary fails |
| **HA** | High Availability — keeping a service up despite failures |
| **Hot standby** | a replica that also answers read-only queries |
| **Leader key** | the etcd key naming the current primary; expires unless renewed |
| **LSN** | Log Sequence Number — a position in the WAL, like `0/6001138` |
| **pg_basebackup** | copies a running primary to create a new replica |
| **pg_rewind** | resyncs a former primary with the new one by undoing divergent changes |
| **Quorum** | a majority of members (2 of 3); needed for any decision |
| **Replication slot** | makes the primary keep WAL until a replica has received it |
| **Split-brain** | two primaries at once — what HA must prevent |
| **Switchover** | planned, lossless move of the primary role |
| **Timeline (TL)** | counter that increases on each promotion |
| **TTL** | time-to-live of the leader key (30 s here) |
| **VIP** | Virtual IP — an address that moves between machines |
| **VRRP** | protocol Keepalived uses to decide who holds the VIP |
| **WAL** | Write-Ahead Log — PostgreSQL's record of every change |
