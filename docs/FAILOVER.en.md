# Automatic failover

*[Türkçe](FAILOVER.md) · **English***

If the primary crashes, the system brings the replica online **by itself** and
routes your applications' connections there. Nothing has to change on the
application side.

```bash
./stack.sh replica on postgresql     # 1. önce yedek kopya
./stack.sh failover on postgresql    # 2. sonra otomatik devir
```

(`# 1. önce yedek kopya` = the replica first; `# 2. sonra otomatik devir` =
then automatic failover.)

In the panel: **Set up replica** ("Replika kur") under the card → **Turn on
automatic failover** ("Otomatik devri aç").

---

## How does it work?

### The router — without it, failover is useless

If your application connected to the database **directly**, you would have to
change the connection address by hand when the primary died; that is, the
failover would not be "automatic". This is why every database port goes
through the gateway:

```
application → gateway:5432 → (whichever is the primary at that moment)
```

In a failover only the gateway's routing table changes. **Your application's
connection address never changes.**

`nginx -s reload` does not cut existing connections; the old worker processes
keep running until they drain.

### Failover sequence

```
The primary fails to answer 3 times in a row
        ↓
1. FENCE   — the old primary is STOPPED
        ↓
2. PROMOTE — the replica is made primary (opened for writes)
        ↓
3. REROUTE — the routing table is rewritten, nginx is reloaded
        ↓
4. RECORD  — the event is recorded, a webhook notification goes out if set
```

**Step 1 cannot be skipped.** If the old primary keeps running, both copies
accept writes, the data diverges and cannot be merged again (split-brain).
`docker stop` also suppresses the restart policy — the old copy does not come
back on its own.

### Why 3 times in a row?

A single failed health check can be temporary: a momentary load spike, a short
GC pause, a slow disk. An unnecessary failover means unnecessary downtime.
With the defaults `FAILOVER_STRIKES=3` and `FAILOVER_INTERVAL=10` the decision
is made in ~30 seconds. It can be changed through `.env`.

### Resilience to restarts

If the promoted node restarts, the replica flags on its command line
(`--read-only`, `--replicaof`) come back and it becomes read-only again. The
controller notices this and reapplies the primary role — this is why the
promotion scripts are written to be **idempotent**.

---

## Per engine

| Engine | Failover | How |
|---|---|---|
| **PostgreSQL** | ✅ controller-driven | `pg_ctl promote` — leaves standby recovery |
| **MariaDB** | ✅ controller-driven | Relay log is drained, `RESET SLAVE ALL`, `read_only=OFF` |
| **Redis** | ✅ controller-driven | `REPLICAOF NO ONE` |
| **MongoDB** | ✅ self-elected | The replica set elects by majority vote (3 members, arbiter included) |
| Others | ✖ | Their clustering models differ — see below |

### Why is MongoDB different?

MongoDB runs its own election; the controller does not intervene. But an
election needs a **majority**: with two members, when one goes down you are
left with 1/2, no majority can be reached, and the surviving member is stuck
in `SECONDARY`. This is why an **arbiter** is added as a third vote when the
replica is set up (it holds no data, ~64 MB).

> ⚠️ In a P-S-A (primary + secondary + arbiter) topology, if the secondary
> goes down, writes made with `w:"majority"` wait. Applications using the
> default `w:1` are not affected.

### Engines where failover is not supported

- **SQL Server** — Always On AG wants separate nodes and a cluster
- **Cassandra** — there is no primary concept, all nodes are equal
- **Elasticsearch / Kafka** — the shard/partition leader is elected automatically inside the cluster
- **RabbitMQ** — quorum queue + cluster required
- **ClickHouse** — ReplicatedMergeTree + Keeper required
- **Neo4j / MinIO** — Enterprise and a multi-disk setup required, respectively

---

## After a failover

When a failover happens a warning appears on the card and a critical entry
lands in the event feed. The old primary is stopped. To bring it back as a
**replica** of the new primary:

```bash
./stack.sh failover rebuild postgresql
```

This operation **deletes the data on the old copy** and copies it again from
the new primary from scratch. That is deliberate: the histories of the two
copies diverged at the moment of failover; keeping the old one produces
inconsistency.

To see the state:

```bash
./stack.sh failover status
./stack.sh events
```

---

## Things to watch for after a failover

**In PostgreSQL, sequence numbers jump.** After a failover, auto-incrementing
fields like `id` may show a jump (e.g. from 3 to 36). This is not a bug: for
performance PostgreSQL preallocates sequence numbers in blocks of 32, and that
allocation is not written to the WAL. On failover the unused block is lost.
The numbers stay unique, only a gap appears. Your application MUST NOT ASSUME
that `id`s are consecutive.

**Backups automatically target the new primary.** The scripts do not use a
fixed container name; they resolve the current primary from
`state/topology.json`.

## How much data can I lose?

Replication is **asynchronous**. Transactions the primary did not manage to
send to the replica just before it died are lost — typically milliseconds,
seconds under heavy writes.

Synchronous replication (zero loss) makes every write wait for the replica to
acknowledge it as well; if the replica slows down, so does the primary. For a
single-machine setup this trade-off is usually not the right one, which is why
asynchronous was chosen.

**If you need zero data loss**, run the replica on a second machine and turn
on `synchronous_commit=remote_apply` in PostgreSQL / semi-sync replication in
MariaDB.

---

## What it protects against, what it does not

**Protects against:**
- The database process crashing, hanging, being killed by the OOM killer
- Corruption of the data files (the replica stays intact)
- Taking an engine down for maintenance (`./stack.sh failover now`)

**Does not protect — honestly:**
- **The whole host going down.** Both copies are on the same machine; if the
  machine dies, both die. For that, run the replica **on a second machine**:
  point the replica service in `.env` at a remote docker host, or use the
  Kubernetes deployment with node anti-affinity.
- **Data deleted by accident.** It is reflected on the replica instantly too.
  The remedy for that is a backup → [BACKUP.en.md](BACKUP.en.md)
- **The controller itself.** If the controller crashes, no failover is done.
  It is a small service and comes back with `restart: unless-stopped`; watch
  the events.

---

## Testing

Before you go to production, **you must** try a failover:

```bash
./stack.sh replica on postgresql
./stack.sh failover on postgresql

# Ana kopyayı öldür ve izle
docker stop postgresql
watch -n2 './stack.sh failover status'

# ~30 saniye içinde devir olmalı. Uygulamanız kesintiden sonra
# HİÇBİR ayar değişikliği olmadan yazmaya devam edebilmeli.
psql -h <sunucu> -p 5432 -U root -d defaultdb -c "SELECT pg_is_in_recovery();"
#  → f  (yani yazılabilir ana kopya)

# Eski kopyayı yedek olarak geri al (verisi silinip baştan kopyalanır)
./stack.sh failover rebuild postgresql

# Doğrula: replikasyon artık ters yönde akmalı
docker exec postgresql-replica psql -U root -d postgres   -c "SELECT application_name, state FROM pg_stat_replication;"
#  → walreceiver | streaming
```

(The comments, in order: `# Ana kopyayı öldür ve izle` = kill the primary and
watch; `# ~30 saniye içinde devir olmalı…` = the failover should happen within
~30 seconds, and after the outage your application should be able to keep
writing with NO configuration change; `#  → f  (yani yazılabilir ana kopya)` =
f, that is, a writable primary; `# Eski kopyayı yedek olarak geri al…` = bring
the old copy back as a replica, its data is deleted and recopied from scratch;
`# Doğrula: replikasyon artık ters yönde akmalı` = verify, replication should
now flow in the opposite direction. `<sunucu>` = your server.)

Times measured on a real server (16 GB, 8 cores):

| Step | Time |
|---|---|
| Detecting the failure (3 checks × 10 s) | ~30 s |
| Fence + promotion + rerouting | 1-2 s |
| **Total downtime** | **~30 s** |
| Bringing the old copy back as a replica | 1-2 min (depends on data size) |

---

## Notifications

Critical events (failover, promotion error) are POSTed to the
`NOTIFY_WEBHOOK` address in `.env`. Slack, Teams, Discord and most tools are
compatible:

```bash
NOTIFY_WEBHOOK=https://hooks.slack.com/services/...
```

The body that is sent contains both a plain `text` field and a structured
`event` field.
