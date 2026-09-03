# Memory: ceiling, reserve, and kernel pressure

*[Türkçe](BELLEK.tr.md) · **English***

This document explains what the controller looks at when it starts an engine,
and why it looks that way. The short answer: **`docker --memory` is a ceiling,
not a reservation.** A calculation that loses this distinction says "no room"
on an empty machine.

---

## 1. Two quantities

| | **Reserve** (floor) | **Ceiling** (limit) |
|---|---|---|
| Definition | The memory the engine **actually allocates** at startup and never gives back to the operating system | `docker --memory` / cgroup `memory.max`. If it is exceeded, the kernel kills the container |
| Set by | The engine's own setting (buffer pool, heap) | The upper bound handed out by the controller |
| Their sum | Can **never** exceed allocatable | **Can** exceed allocatable |
| Changes | Does not shrink while the engine runs | Changes live with `docker update` |

Where the reserve comes from is told by the **catalog**; the code knows no
engine names. `catalog.json` → `resources.reserve.from` records which setting
key(s) the reserve derives from. An empty list means "it has no floor":

| Engine | Reserve comes from | Note |
|---|---|---|
| MariaDB | `MARIADB_BUFFER_POOL` | the InnoDB buffer pool is allocated at startup and never given back |
| PostgreSQL | `POSTGRES_SHARED_BUFFERS` | postmaster allocates shared memory in one piece at startup |
| Elasticsearch | `ELASTIC_JAVA_OPTS` | `-Xms` = the heap the JVM takes at startup |
| Cassandra | `CASSANDRA_HEAP` | same reason (JVM `-Xms`) |
| Kafka | `KAFKA_HEAP_OPTS` | same reason |
| Neo4j | `NEO4J_HEAP` | same reason |
| Redis | — | `maxmemory` is a CEILING; Redis starts empty and grows as data is written |
| MSSQL | — | "max server memory" is a CEILING |
| MongoDB | — | the WiredTiger cache is a CEILING; it grows as data is read |
| ClickHouse | — | `max_server_memory_usage` is a CEILING |
| MinIO · RabbitMQ · Monitoring | — | no distinct startup floor |

`POSTGRES_WORK_MEM` is deliberately **not** a reserve: it is per connection and
temporary. (It is still an OOM source; that the sum
`shared_buffers + work_mem × max_connections` does not exceed the ceiling is
checked separately in `scripts/selftest.py`.)

The **number** of connections is a memory line item too: in PostgreSQL every
connection is a separate process, so an application that uses no pool chokes
the engine with process count, not with RAM. That is why there is an optional
connection pool on 6432; how the pool settings derive from
`POSTGRES_MAX_CONNECTIONS` and the limits of transaction pooling are in
`docs/POOLING.md`.

---

## 2. Allocatable memory

```
allocatable = total RAM − operating-system share − core-services share
```

- **Operating-system share** = `max(1024 MB, RAM × 0.20)`, at most 60% of RAM.
  The upper bound is required: on a 512 MB machine, saying "1024 MB went to the
  operating system" drops the budget below zero and no engine can start.
- **Core-services share** = 448 MB — the gateway (nginx), the controller and
  Adminer. These are always up.

On the measured 16 GB test server: `15984 − 3196 − 448 = 12340 MB`.

---

## 3. The three gates before an engine starts

They are applied in order, and the refusal message says **which gate** it
caught on (the `plan.rule` field: `tavan` · `rezerve` · `cekirdek` — the values
the product prints, in Turkish: ceiling · reserve · kernel).

### 3.1 Ceiling gate — soft

```
Σ ceiling + new ceiling  ≤  allocatable × OVERCOMMIT_LIMIT
```

Not every ceiling fills at the same time; overcommit is a deliberate policy.
The default coefficient is **1.5** and it is cautious even against the
measurement — the four containers below were using an average of **5%** of
their ceilings.

Writing `OVERCOMMIT_LIMIT=1.0` turns overcommit off, that is, it returns to the
behavior with the bug this document describes.

### 3.2 Reserve gate — hard

```
Σ reserve + the new engine's reserve  ≤  allocatable
```

It is never bent. The reserve is the memory the engine will actually allocate;
if it is overcommitted, the OOM killer steps in on the first write load. The
plan reports this gate in the `reserve_ok` field.

A request that does not fit is **shrunk first**: because the reserve grows
together with the ceiling (MariaDB buffer pool = 60% of the ceiling), a smaller
ceiling usually fits and the user gets the engine they asked for. The ceiling
comes down in 5% steps as far as `min_mb`; if it does not fit even at the
minimum ceiling, **then** it is refused.

### 3.3 Kernel seatbelt

```
MemAvailable  ≥  new reserve + KERNEL_SAFETY_MB   (default 512 MB)
```

Whatever the ledger says, the kernel's reality is binding. If `MemAvailable`
cannot be read (0), this gate is **skipped**: refusing to let an engine start
on the grounds of something we could not measure would be lying to the user.

---

## 4. Kernel pressure signal (PSI)

`/proc/pressure/memory` is the kernel's own measurement:

```
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

- **some avg10** — in what percentage of the last 10 seconds **at least one**
  task waited on memory. This is the number actually watched.
- **full avg10** — in what percentage **all** tasks waited (serious scarcity).

| Level | Threshold (`some avg10`) | Meaning |
|---|---|---|
| `yok` | < 10 | The kernel is making nobody wait |
| `orta` | ≥ `PRESSURE_WARN` (10) | Memory reclaim has started |
| `yuksek` | ≥ `PRESSURE_HIGH` (30) | Real scarcity; do not add new load |
| `bilinmiyor` | — | No PSI in the kernel (`CONFIG_PSI` off) |

(The level values are what the product prints, in Turkish: `yok` = none ·
`orta` = moderate · `yuksek` = high · `bilinmiyor` = unknown.)

`bilinmiyor` is not a failure and is **not used as a gate**.

---

## 5. The measured incident

On the 16 GB test server, in the product's earlier state:

| Container | Ceiling | Actual use |
|---|---|---|
| mariadb | 3196 MB | 243 MB (7%) |
| mariadb-replica | 3196 MB | 213 MB (6%) |
| postgresql | 2397 MB | 98 MB (4%) |
| redis | 1278 MB | 5 MB (0%) |

The host state at the same moment:

```
free -m               → total 15984 · used 1508 · available 13987
/proc/pressure/memory → some avg10=0.00 avg60=0.00 · full avg10=0.00
sum of ceilings       → 15087 MB
allocatable           → 12340 MB
```

The panel was printing this: **"AYRILAN BELLEK 15 GB / 12 GB · %122 aşım"**
(Turkish output: "MEMORY ALLOCATED 15 GB / 12 GB · 122% over"), and every
stopped engine said "bellek yetmiyor" ("not enough memory"). The machine was
**91% free** and the kernel was not making a single task wait.

The bug was in the model: ceilings were summed and compared against RAM. That
is like adding up the top speeds of the cars on a road and saying "road
capacity exceeded".

The same situation under the new model:

```
Σ ceiling    15087 MB ≤ 12340 × 1.5 = 18510 MB   → ceiling gate OPEN
Σ reserve     2516 MB ≤ 12340 MB                 → reserve gate OPEN
MemAvailable 13987 MB ≥ reserve + 512 MB         → kernel seatbelt OPEN
```

2516 MB = MariaDB 1917 (buffer pool) + PostgreSQL 599 (shared_buffers) +
Redis 0. On the same server a new engine **can be started**.

---

## 6. Rebalancing

`POST /api/rebalance` (**Rebalance** ("Yeniden dengele") in the panel). The
ceilings had been computed as the engines were started one by one; by the time
the third engine started, the first two already had their ceilings set, and
nobody went back to say "there is less room now, you shrink too". Rebalancing
does exactly that:

1. Computes the desired ceiling for every running engine with the **same
   formula** used at activation (keeping two formulas would mean a different
   number coming out when you stop and start the engine after a rebalance).
2. **Soft rule**: if the engines' total ceiling exceeds the budget, all of them
   are cut by the **same ratio** — the last one started is not punished for
   being last.
3. **Hard rule**: if the total reserve that would derive from the new ceilings
   exceeds allocatable, it comes down in 10% steps; it never goes below
   `min_mb`.
4. **Applies it**: `docker update --memory` — the cgroup limit changes
   **live**.

### What rebalancing does not do

- **It does not restart the container.** Open connections are not dropped,
  InnoDB recovery does not run, there is no downtime. The easy path would have
  been to recreate the engine with `compose up -d`; that path shuts down a
  running database.
- **It does not push the ceiling below current use.** The floor =
  `actual use × REBALANCE_HEADROOM` (default 1.3). If the cgroup limit drops
  below current use, the container OOMs **immediately**.
- **It does not shrink when actual use cannot be measured.** Shrinking blind
  ends up in the same place; this case is written to the job log.
- **It does not change the engine's internal setting while it runs.** Buffer
  pool and heap cannot be shrunk; the new values are written to
  `state/tuning.env` and take effect at the engine's **next** startup. That
  write is required: without it, the engine would allocate memory above its own
  ceiling at the next startup and OOM on the first query.
- **It does not work on Kubernetes.** There, changing the limit recreates the
  pod, which means downtime; the job is refused with an explicit reason.

---

## 7. Tuning constants

All of them are environment variables of the controller; if one is not given,
the default applies.

| Variable | Default | What it does |
|---|---|---|
| `OVERCOMMIT_LIMIT` | `1.5` | Ratio of the total ceiling to allocatable. `1.0` = no overcommit |
| `KERNEL_SAFETY_MB` | `512` | Safety margin of the kernel seatbelt |
| `PRESSURE_WARN` | `10.0` | If `some avg10` is above this value, pressure is "orta" |
| `PRESSURE_HIGH` | `30.0` | Above this value, "yuksek" |
| `REBALANCE_HEADROOM` | `1.3` | Minimum multiple of actual use for the new ceiling |

Hard-coded in the code: the operating-system share `20%` (at least 1024 MB, at
most 60% of RAM), the core-services share `448 MB`, the smallest meaningful
ceiling change `32 MB`.

---

## 8. Troubleshooting

**"The panel says there is not enough memory, but `free -m` says the machine is
empty."**
Read the refusal message: it says which gate it caught on.
- *CEILING crunch* (`tavan`) → rebalance, stop an engine, or raise
  `OVERCOMMIT_LIMIT`. Memory is not actually full.
- *RESERVE* (`rezerve`) → the running engines have actually allocated the
  memory. There is no way out other than stopping an engine or adding RAM.
- *KERNEL SEATBELT* (`cekirdek`) → `MemAvailable` is low. Something outside the
  stack may be eating memory; look at `free -m` and `/proc/pressure/memory`.

**"I rebalanced but the ceiling did not change."**
Look at the job log (`/api/jobs/<id>` → `log`): one of the lines "gerçek
kullanım ölçülemedi" (could not measure actual use), "değişiklik yok (32 MB'ın
altında)" (no change, below 32 MB) or "tabana çekildi" (pulled down to the
floor) says why.

**"I stopped and started the engine and its internal setting changed."**
Expected behavior: rebalancing applies the ceiling immediately and the internal
setting at the next startup.

---

## 9. How this is verified

```bash
./stack.sh selftest          # needs no docker
```
Section 7 tests the three rules of this model **with paired scenarios**: the
only difference between them is the quantity the rule looks at. Accept while
the total ceiling is over, refuse while the reserve is over; with the same
ledger, accept at MemAvailable 13987 MB, refuse at 128 MB. It also verifies
that every engine has a reserve definition in the catalog and that no accepted
plan breaks the hard rule (5 server sizes × 4 running-engine states).

```bash
./scripts/e2e/sizing.sh      # against a RUNNING installation
```
Section 6 **creates the overcommit condition itself** (it temporarily inflates
one engine's ceiling with `docker update`), calls rebalancing, reads from the
cgroup that the ceiling actually came down, and verifies with
`.State.StartedAt` that no container was restarted. On the way out it writes
back the ceiling it inflated. To skip it: `SIZING_SKIP_REBALANCE=1`.

Cases that could not be measured are reported as `[ÖLÇÜLEMEDİ]` (NOT MEASURED)
and **counted as failed** — "I don't know" and "good" are not the same thing.
