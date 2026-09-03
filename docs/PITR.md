# Going back to a point in time (PITR)

*[Türkçe](PITR.tr.md) · **English***

The best thing you can do with a nightly backup is **"go back to yesterday's
backup"**. But that is almost never what you want: if the `UPDATE` that
corrupted the data ran yesterday at 14:33, you need to go back to **14:32**.
The difference between the two is a day's worth of work.

A full backup plus the **change log** from that moment on closes that gap. In
PostgreSQL that log is the WAL, in MariaDB it is the binlog.

```
./scripts/pitr.sh durum
./scripts/pitr.sh don postgresql "2026-09-01 14:32:00" --prova
```

(`durum` = status, `don` = go back, `--prova` = drill mode; it never touches
production.)

---

## Scope — and why only two engines

| Engine | PITR | Why |
|---|---|---|
| **postgresql** | ✅ | WAL is being archived (`archive_mode`, docker-compose.yml) |
| **mariadb** | ✅ | binlog is already on (config/mariadb/my.cnf) |
| mongodb | ❌ | technically **possible** with the oplog (a replica set is required, going back as far as the oplog window) but **not done in this round** |
| redis | ❌ | AOF is only a command stream; the events carry no timestamp, "go back to 14:32" cannot be expressed |
| mssql | ❌ | transaction log backups (LOG backup) are required; this stack only takes FULL backups |
| others | ❌ | no timestamped change log is kept in the stack |

The MongoDB row deliberately says "possible but not done". Hiding the
difference between "can be done" and "was done and measured" is the most
expensive thing to learn on the day of a disaster.

---

## The two parts of PITR: the BASE BACKUP and the ARCHIVE

There is one rule that will come up again and again in this document:

> **A change log is not data on its own.** Both the WAL and the binlog are
> replayed **on top of a base backup**. With no base backup there is no
> recoverable range either.

### Why the PostgreSQL base backup is NOT `backup.sh`'s backup

`backup.sh` backs PostgreSQL up with `pg_dumpall` — that is a **logical**
backup, i.e. SQL statements. The WAL, on the other hand, is **block-level**
changes. Neither can be replayed on top of the other: the LSNs, the block
layouts and the file nodes do not match. That is why PITR has its own base
backup (the `taban` command; "taban" = base):

```
./scripts/pitr.sh taban postgresql     # pg_basebackup — FİZİKSEL kopya
```

(The comment reads: a PHYSICAL copy. `<tarih>` = date.)

→ `backups/postgresql/taban/postgresql_taban_<tarih>.tar.gz` (+ `.meta`)

### The MariaDB base backup CAN be the nightly backup

In MariaDB the binlog is logical as well (row/statement events), so it speaks
the same language as a dump. The only requirement is that the file record
**which binlog position** it represents everything after; `mariadb-dump
--master-data=2` does that, and `backup.sh` already dumps with that flag. That
is why `pitr.sh` collects candidate base backups from **two places**:

* `backups/mariadb/taban/` — what `pitr.sh taban mariadb` produces
* `backups/mariadb/full/` — `backup.sh`'s nightly backups

The second one is deliberate: taking one more dump every day would bring back
the OOM incident described at the top of `backup.sh` (a second heavy job in
the same container). But there is **no dependency**: a file that does not
carry the position line never enters the candidate list, and is never silently
counted as "there is a base backup".

---

## Setup

The PITR settings were added to compose. `archive_mode` **requires a
restart**, a reload is not enough:

```bash
docker compose up -d postgresql mariadb   # container'lar yeniden yaratılır
./scripts/pitr.sh kur postgresql
./scripts/pitr.sh kur mariadb
./scripts/pitr.sh taban postgresql
./scripts/pitr.sh taban mariadb
./scripts/pitr.sh durum
```

(The comment reads: the containers are re-created.)

The real job of the `kur` command ("kur" = set up) is **to measure
permissions**. The archive directory lives on the host, but the container's
own user (postgres = uid 999, mysql = uid 999) is what writes into it. If the
directory does not exist, docker creates it as **root:root** and
`archive_command` says "Permission denied" on every segment. The bad part is
not that this is noisy, but that it is **silent**: PostgreSQL retries,
`pg_wal` grows, and the failure only becomes visible once the data disk fills
up. `kur` verifies this **as a measurement, not as a promise**, by creating
and deleting a file as the engine's own user.

### What changed

**docker-compose.yml → postgresql**

```yaml
volumes:
  - ${STACK_DIR:-.}/backups/postgresql/wal:/wal-archive
  - ${STACK_DIR:-.}/config/postgresql:/etc/pitr:ro
environment:
  PG_WAL_ARSIV: /wal-archive
command:
  - -c
  - archive_mode=${POSTGRES_ARCHIVE_MODE:-on}
  - -c
  - archive_command=sh /etc/pitr/wal-archive.sh %p %f
  - -c
  - archive_timeout=${POSTGRES_ARCHIVE_TIMEOUT:-300}
```

`wal_level` was **not changed**: `replica` is enough for PITR (`logical`
writes more and inflates the disk for nothing). The only thing missing was
archiving — the `replica` level does produce the WAL, but recycles it once
`pg_wal` fills up; so "yesterday 14:32" becomes unreachable the moment that
segment is recycled.

**docker-compose.yml → mariadb**

```yaml
volumes:
  - ${STACK_DIR:-.}/backups/mariadb/binlog:/binlog-archive
```

The binlog's **location did not change**; a **copy** is written out here. The
reason is below.

---

## Where the archive lives, and how long it lives

| | Where | Who writes it |
|---|---|---|
| PostgreSQL WAL | `backups/postgresql/wal/` | the engine, continuously via `archive_command` |
| PostgreSQL base backup | `backups/postgresql/taban/` | `pitr.sh taban postgresql` |
| MariaDB binlog (the original) | `mariadb_data` volume, `/var/lib/mysql/mysql-bin.*` | the engine |
| MariaDB binlog (the copy) | `backups/mariadb/binlog/` | `pitr.sh arsivle mariadb` |
| MariaDB base backup | `backups/mariadb/taban/` + `backups/mariadb/full/` | `pitr.sh taban` / `backup.sh` |

The archive lives **under the backups**, not in a separate root. Had we picked
a separate place, two things would break: `backup.sh stats`'s disk warning
would not count the archive, and `sync-remote.sh` would send only the backups
off-site — on the day of a disaster the full backup would be far away and the
PITR archive would stay on the dead server.

### Why the MariaDB binlog's location was NOT changed

Moving the `log_bin` path to `/binlog-archive` looks tempting but is
destructive: MariaDB knows which binlogs exist from the `mysql-bin.index` file
and runs `PURGE` accordingly. When the path changes **a new index is opened**,
the files left in the old directory are never deleted again and
`binlog_expire_logs_seconds` no longer sees them. A data volume that fills up
silently would be a worse version of the problem we are trying to solve.

The copy, on the other hand, lives on the host: even if the engine's volume
dies, you still have the binlog.

### Retention — "the same number of days" is not enough on its own

```bash
./scripts/pitr.sh temizle          # varsayılan: PITR_RETENTION_DAYS (= RETENTION_DAYS)
./scripts/pitr.sh temizle 14
```

(The comment reads: default: PITR_RETENTION_DAYS (= RETENTION_DAYS).)

`PITR_RETENTION_DAYS` is by default equal to `RETENTION_DAYS`; if the two
diverge, `pitr.sh durum` shows it as a **warning**. If the archive is kept
longer, the disk fills up silently; if it is kept shorter, there are backups
in your hand you cannot move forward from.

But the real issue is not the number of days: **a flat, age-based deletion
also deletes the WAL that a retained base backup needs.** `backup.sh clean`
keeps the newest 3 copies of every engine **whatever their age** (so that a
stopped engine's last recovery point does not disappear). Because of that rule
a 30-day-old base backup can still be in hand; if we delete its WAL after 7
days, what is left is a base backup that **cannot be opened**, and nobody
notices.

That is why `temizle` ("temizle" = clean up) applies two criteria
**together**:

1. age > `PITR_RETENTION_DAYS`, **and**
2. the file is also older than what the oldest **retained base backup**
   requires (a base backup file's mtime is the *end* of the backup, while the
   WAL it needs runs from its *beginning* — the difference between the two is
   `PITR_KORUMA_TAMPON`, 4 hours by default)

`*.history` files stay **whatever their age**. They are a few hundred bytes,
but recovery reads where which timeline branched off from nowhere else; if
they are deleted, every recovery that follows the `latest` timeline gets stuck
on the old timeline, and no error message tells you so.

**`temizle` does NOT delete base backup files.** They live under
`backups/<motor>/taban/` and `backup.sh clean` looks there too (`find` is
recursive, and the `*.gz` pattern covers both `tar.gz` and `sql.gz`). A policy
with two owners is worse than one with no owner at all.

---

## How the recoverable range is computed

```
./scripts/pitr.sh durum
./scripts/pitr.sh durum postgresql --json     # controller / panel için
```

(The comment reads: for the controller / the panel.)

### PostgreSQL

* **Earliest** = the moment the oldest base backup **finished** (`.meta` →
  `bitis_epoch`). Going back before that is impossible.
* **Latest** = the moment the last segment that actually **landed** in the
  archive was archived (the file's mtime). There is WAL produced on the server
  after that moment too, but it is still in `pg_wal`; on a dead server you
  cannot reach it, so counting it as "recoverable" would be a lie.
* The file mtime is used because **it can be read even while the server is
  down** — and PITR is looked at while the server is down more than at any
  other time.
* If there is a **gap** in the archive, the latest point is pulled back to the
  time of the last segment before the gap, and the reason is written out. The
  gap is found from the consecutiveness of the segment names (24 hex = 8
  timeline + 8 log id + 8 sequence; segments per log id = 2³² /
  `wal_segment_size`). Timelines are evaluated separately, otherwise this
  would raise a false alarm after every PITR.

### MariaDB

* **Earliest** = the moment the oldest base backup whose binlog is **still
  there** was taken. If the binlog a base backup points at has been `PURGE`d,
  you cannot move forward from that base backup; it is not included in the
  range, and `durum` additionally writes how many base backups are unusable
  for this reason.
* **Latest** = **right now**. In MariaDB the binlog is a local file and is
  written at every commit; there is no "delay before landing in the archive"
  the way there is in PostgreSQL. If the server is down this is not true — in
  that case the time of the newest binlog in the host archive is used, and
  **the reason is written out**.

### Pushing the upper end of the range forward

```bash
./scripts/pitr.sh arsivle postgresql   # pg_switch_wal + arşive düştüğünü DOĞRULA
./scripts/pitr.sh arsivle mariadb      # FLUSH BINARY LOGS + host'a kopyala
```

(`arsivle` = archive. The comments read: pg_switch_wal + VERIFY that it landed
in the archive · FLUSH BINARY LOGS + copy to the host.)

In PostgreSQL a segment does not land in the archive
**until it is full**. `archive_timeout=300` force-closes the segment every 5
minutes if there have been writes — so **this is the upper bound on RPO**. The
price: for every 5 minutes with writes, a full-size (16 MB) segment lands in
the archive even if it is half empty. On an idle server this never happens
(PostgreSQL does not switch segments when there are no writes), so it is not a
fixed disk cost.

---

## Going back

```bash
# 1) REHEARSE FIRST — does not touch production
./scripts/pitr.sh don postgresql "2026-09-01 14:32:00" --prova \
    --dogrula "SELECT count(*) FROM siparisler WHERE tutar < 0"

# 2) if the result is correct, apply to production
./scripts/pitr.sh don postgresql "2026-09-01 14:32:00"
```

(The comments read: the drill first — it does not touch production · if the
result is right, then production. The example query counts orders with a
negative amount.)

### Three safety gates

**1. `--prova`.** Recovery is done in a single-use container and volume, with
`--network none`; there is **no** path to the production container, to the
gateway or to the stack network. The archive is mounted **read-only**: it is
technically impossible for the drill to dirty the archive. This ties the
promise "we are not touching anything" to the kernel rather than to intent
(the same contract as `restore-drill.sh`).

`--dogrula` ("--dogrula" = verify) asks the recovered copy **your own query**
and puts its answer into the JSON. Why it exists: the sentence "recovery
finished successfully" does not prove the data you wanted came back. Before
applying anything in production the only right question to ask is "is that row
there, and is the next row **not** there".

**2. The safety backup.** In production, `don` takes a full copy of the
current state before moving on to the destructive step (`pg_basebackup` in
PostgreSQL, `mariadb-dump` in MariaDB). Going back to the wrong point is a
failure too, and it must be undoable. If the safety backup cannot be taken,
**nothing is done**.

**3. The range gate.** If the target is outside the range the job is
**refused** (exit 2) and the reason is written out with numbers:

```
[✗] Hedef aralığın ÖNCESİNDE: istenen 2026-09-02 10:00:00 +0300 ·
    en eski dönülebilir an 2026-09-02 17:52:49 +0300
    (bunu en eski taban yedeği belirliyor). Daha geriye gitmek için
    o tarihi kapsayan bir taban gerekir; elde yok.
```

(BEFORE the range: requested … · earliest recoverable point … — this is set by
the oldest base backup. Going further back needs a base backup covering that
date; there is none.)

"Outside the range" on its own leaves the user sitting in front of the screen:
without knowing how far back they can go and **what** sets that limit, they
cannot decide what to do. And silently going back to "the nearest point" would
teach them to believe in data that is not there.

### Time zone — the silent three hours

The target time is given in **local time**. `pitr.sh` passes it to the engine
**with an explicit time zone**:

* PostgreSQL: `recovery_target_time = '2026-09-01 14:32:00+0300'`
* MariaDB: `mariadb-binlog` is called with `TZ=UTC`, the target is written in
  UTC

If the zone were not written out, it would be interpreted according to the
server's own setting; with the container on UTC and the host on
Europe/Istanbul that is a **silent three-hour** shift, and because the data
that comes back looks "roughly right", nobody notices.

### One difference between the two engines

* PostgreSQL: `recovery_target_inclusive = on` → the target moment **is
  included**.
* MariaDB: `--stop-datetime` stops at the first event whose timestamp is
  **equal to or greater than** the target → the target moment **is not
  included**.

If you need sub-second precision, move the target one second forward in
MariaDB; binlog event timestamps are at one-second resolution anyway.

### After going back in production

```
[!] Varsa REPLİKALAR artık uyumsuz — ./stack.sh replica off/on ile yeniden kurun.
[!] Yeni bir PITR tabanı alın: ./scripts/pitr.sh taban <motor>
```

(Any REPLICAS are now inconsistent — rebuild them with `./stack.sh replica
off/on`. Take a new PITR base backup: `./scripts/pitr.sh taban <motor>`.)

In PostgreSQL, recovery starts **a new timeline**; the replicas are chasing
the data on the old one. In MariaDB, `gtid_strict_mode` is turned off
temporarily while the binlog is replayed (rewriting old GTIDs is an
"out-of-order sequence number" error in strict mode) and is put back on
**every exit path** — errors, timeouts and Ctrl+C included. If it cannot be
put back, the script writes that on the screen.

---

## Exit codes

| Code | Meaning |
|---|---|
| 0 | job done |
| 1 | **failed** — the job was tried, it did not work |
| 2 | **refused** — the target is outside the range, or approval was not given. **Nothing destructive was done**; this code means "your data is where it was" |
| 3 | **out of scope / could not measure** — the engine does not support PITR, docker is missing, someone else holds the lock. The job could not even be *tried* |
| 4 | the job finished but the temporary container/volume **leaked** |

Keeping 2 and 1 apart is deliberate: "refused" is not a failure, it is proof
that the safety gate works. If the panel shows the two in the same color, the
user stops seeing the real failures.

`don` and `durum --json` print **a single line of JSON on the last line**:

```json
{"komut":"don","engine":"postgresql","target":"2026-09-01T14:32:00+0300",
 "mode":"prova","ok":true,"seconds":37,"base":"…/postgresql_taban_….tar.gz",
 "stopped_at":"LOG: recovery stopping before commit of transaction 734, …",
 "verify":"A","cleanup":true,"detail":"PROVA GEÇTİ: …"}
```

(`PROVA GEÇTİ` = the drill passed.)

`stopped_at` is **the engine's own sentence**, not our interpretation of it.
Nobody but the engine knows where recovery stopped.

---

## How it was measured

`scripts/e2e/pitr.sh`. What it really measures is one sentence:

> Row A is written at T1 · row B is written at T2 ·
> we go back to a point **between** T1 and T2 → in the copy **A is there, B is
> not**.

```bash
./scripts/e2e/pitr.sh                 # postgresql + mariadb
./scripts/e2e/pitr.sh mariadb
```

Why this sentence: counting a single row is not enough. A recovery that
unpacks the base backup as it is and never replays the change log also looks
"successful"; so does a recovery that overshoots the target. When one of the
two rows is **there** and the other is **not**, both things are proven at
once: that the log was replayed on top of the base backup, and that it
**stopped in the right place**.

The suite also measures: that an attempt to go outside the range (both into
the future and far into the past) is refused with exit 2; that after drills
and refused attempts production still contains `A,B` (that is, measuring the
claim "we did not touch anything"); that archive cleanup obeys the retention
period **and** does not touch a segment a retained base backup needs.

Everything that could not be measured is `t_unknown`, and `scripts/e2e/lib.sh`
**counts it as failed** — "I don't know" and "fine" are not the same thing.

This suite is **not destructive**: recovery is only done with `--prova`, and
in production only its own test table (`e2e_pitr`) is created and dropped at
the end.

---

## Scheduled jobs

**These are now ready inside `scripts/crontab.template`** — `install.sh`
produces `state/crontab`, and you load it with `crontab state/crontab`. In the
previous version they sat there as an example, "you could add these", and
nobody added them; the result was a PITR window in MariaDB that never moved
forward.

```cron
*/15 * * * *  scripts/pitr.sh arsivle    # RPO üst sınırı: 15 dakika
0    1 * * *  scripts/pitr.sh taban      # WAL/binlog tek başına veri değildir
15   3 * * *  scripts/pitr.sh temizle    # arşiv sonsuza kadar büyümesin
```

(The comments read: RPO upper bound: 15 minutes · WAL/binlog is not data on its
own · keep the archive from growing forever.)

If no engine name is given, it runs on **all** engines that have PITR. A
stopped engine is **skipped** (exit 3) and raises no alarm; a cron that alarms
every morning is a cron nobody looks at. We do not write the engines into the
crontab one by one: the day a third PITR engine is added to the stack, it
would silently be left without an archive.

`taban` and the nightly full backup are **deliberately at different times**:
the two share the same lock, and if they collide one of them never runs.

### PostgreSQL needs an archiving job too

The previous version said here: "no scheduled job is needed for the PostgreSQL
WAL archive, `archive_command` runs continuously". True but incomplete: if
`archive_command` **cannot run**, nobody notices. Two states measured on the
server:

- **The directory does not exist.** docker creates the bind-mount source as
  **root:root**; the `postgres` user cannot write and archiving returns exit 1
  once a second. The only thing that fixed this was a hand-typed `pitr.sh kur`
  — meaning PITR stayed off until somebody typed that command. Now
  `install.sh` creates the directories and `arsivle` **measures and fixes**
  the permission itself.
- **A failover has happened.** If the promoted node has no `archive_mode` and
  no `/wal-archive`, archiving stops; the upper end of the window freezes at
  the moment of the failover. So PITR dies right after an incident, exactly
  when it is needed most. `postgresql-replica` now carries the same archive
  settings as the primary.

`arsivle` also calls `pg_switch_wal()` and **verifies that the segment
landed** in the archive: if there have been writes but the segment is not
full, the "latest recoverable point" stays hours behind and the user cannot go
back to data they actually have.

### Permissions have two sides

**Two different identities** write into the archive directory: the engine's
own user (`postgres`/`mysql`, from inside the container) and the administrator
on the server (`pitr.sh taban`, `temizle`). Opening it up to only one breaks
the other — when the directory was `postgres:root 750` the administrator could
not list the archive and `temizle` could not delete anything. The correct
state: the owner is the engine's user, the group is the group on the server,
mode **2775**. If it is broken:

```bash
./stack.sh doctor            # yazamadığınız dizinleri sahibiyle listeler
sudo ./stack.sh doctor --duzelt
```

(The comment reads: lists the directories you cannot write to, with their
owner. `--duzelt` = fix.)

---

## Settings

| Variable | Default | What it does |
|---|---|---|
| `POSTGRES_ARCHIVE_MODE` | `on` | WAL archiving. `off` ends PITR — but it is better than `pg_wal` filling the data disk on an installation that cannot write to the archive; this escape hatch exists deliberately |
| `POSTGRES_ARCHIVE_TIMEOUT` | `300` | How often, in seconds, to force-close the segment when there have been writes (= the upper bound on RPO) |
| `PITR_RETENTION_DAYS` | `RETENTION_DAYS` | Archive retention period |
| `PITR_KORUMA_TAMPON` | `14400` | Safety margin (s) for the WAL the oldest base backup needs |
| `PITR_ZAMAN_CIZGISI` | `latest` | `recovery_target_timeline`. `latest` is required for PITR on top of PITR to be possible |
| `PITR_KURTARMA_SURESI` | `1800` | Upper bound (s) for recovery to complete |
| `PROVA_MEM_MB` | `1024` | Memory ceiling for the temporary copy |
| `PITR_DOGRULA_DB` | `DEFAULT_DATABASE` | The database the `--dogrula` query will run against (PostgreSQL) |
| `ASSUME_YES=yes` | — | Do not ask for confirmation on a production `don` (automation) |

---

## Common situations

**`durum` says "archive_mode KAPALI" ("archive_mode OFF") but compose says
`on`.**
`archive_mode` requires a restart, a reload is not enough. Re-create the
container with `docker compose up -d postgresql`. `durum` asks **the running
server**, not the value in compose; that difference is exactly the point.

**`durum` says "arşivleme N kez başarısız oldu" ("archiving failed N
times").**
Almost always permissions: the archive directory was created by docker as
root. `./scripts/pitr.sh kur postgresql`. Take this warning seriously —
PostgreSQL does not release a segment it cannot archive, `pg_wal` grows, and
in the end the server stops with a PANIC.

**`don` says "İSTENEN ANA ULAŞAMADI, arşivin ulaştığı son işlem X" ("could not
reach the requested point; the last transaction the archive reached is X")
even though the target was inside the range.**
The most common cause is not a missing segment but **a quiet database**. If
there were no writes at all between the target and the last transaction, there
is no WAL record in that interval either, and PostgreSQL rejects the target.
Aim at the `X` moment in the message (or before it). This was seen exactly
that way in measurement: last transaction 17:53:14, target 17:55:00, not a
single write in between → `FATAL: recovery ended before configured recovery
target was reached`.

**`don` says "KURTARMA KOMUTU ÇALIŞTIRILAMADI" ("the recovery command could
not be run").**
The `/etc/pitr` mount is missing — the container was not re-created after the
PITR settings were added. `docker compose up -d postgresql`. This message is
kept separate because the sentence PostgreSQL writes to its log is **word for
word identical** to the one above; a message that blames the archive would
send the operator hunting for a missing segment that does not exist.

**`don` says "Yedekleme kilidi başkasında" ("someone else holds the backup
lock") and exits 3.**
`backup.sh`, `restore-drill.sh` and `pitr.sh` share **the same lock**: on a
single server two heavy jobs strain the same cgroup, and the cleanup pass can
pull the file we are reading out from under our feet. Exit 3 does not mean
"recovery failed", it means "recovery was **not tried**".
