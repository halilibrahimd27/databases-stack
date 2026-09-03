# Slow query measurement

*[Türkçe](SLOWLOG.md) · **English***

The answer to the sentence "my database is slow" almost always sits somewhere
measurable: the engine is **already counting** how much time it spends on
which query. The only thing missing is turning that counter on and making it
readable. `scripts/slowlog.sh` does that.

```bash
./scripts/slowlog.sh kur postgresql      # ölçümü aç (kalıcı ayar)
./scripts/slowlog.sh durum               # en pahalı ilk N sorgu
./scripts/slowlog.sh oneri postgresql    # indeks/ayar önerileri
./scripts/slowlog.sh sifirla postgresql  # sayaçları sıfırla
```

(`kur` = set up, `durum` = status, `oneri` = suggest, `sifirla` = reset. The
comments read: turn measurement on (persistent setting) · the most expensive
first N queries · index/setting suggestions · reset the counters)

---

## Why the ranking is by TOTAL time

This is the tool's most important decision. When people look for slowness they
instinctively look at the **average** — and get it wrong:

> A query that takes 0.5 ms but is called 2000 times a second takes **1000 ms**
> of the server every second. A report that takes 3 seconds but runs once a day
> takes **3000 ms** a day. In three seconds the first one passes the second
> one's **daily** cost.

A list sorted by average never shows the first one — and that is the one
actually filling the server. That is why both the screen and the JSON are
sorted by total time; the *average* column exists only for the question "how
long does a single run take".

This decision is not a guess, it is **measured**. `scripts/e2e/slowlog.sh`
deliberately runs two queries that fall on opposite sides and looks at their
positions in the list. From a real run:

| query | calls | total | average | position in list |
|---|---|---|---|---|
| `sik`   | 400 | **56.7 ms** | 0.142 ms | **2** |
| `nadir` |   2 | 14.2 ms | **7.123 ms** | 3 |

Sorted by average, `nadir` would have come out 50 times higher. Yet `sik` took
**4 times more** of the server's CPU. The list shows the right one.

---

## If measurement is off, no empty list is printed

When measurement is not on, this script stops with **exit code 4** and prints
the command that turns measurement on.

The reason is concrete: an empty list reads as "you have no slow queries".
Saying that when no measurement was ever taken is the most expensive wrong
answer this tool can give — the user goes off looking for the real problem
somewhere else entirely.

```
[!] ÖLÇÜM KAPALI — postgresql
[!]   pg_stat_statements ÖN YÜKLÜ DEĞİL — PostgreSQL hiçbir sorgunun
      süresini saymıyor.
[bilgi]   Açmak için:  ./scripts/slowlog.sh kur postgresql
```

(MEASUREMENT OFF — postgresql · pg_stat_statements is NOT PRELOADED —
PostgreSQL is not counting the duration of any query. · info: To turn it on:)

---

## Scope — and why only two engines

| Engine | Measurement | Source |
|---|---|---|
| **postgresql** | ✅ | `pg_stat_statements` |
| **mariadb** | ✅ | the `performance_schema` digest, or the slow query log if absent |
| mongodb | ❌ | **possible** with the profiler, **not done** in this round |
| mssql | ❌ | **possible** with Query Store, **not done** in this round |
| elasticsearch | ❌ | it has its own slow log; a different format, a different interpretation |
| the others | ❌ | no counter in the stack accumulates time per query |

For an out-of-scope engine the exit code is **2**; it does not get mixed up
with the error (1) and could-not-measure (3) codes.

The "possible but not done" rows are written that way deliberately: hiding the
difference between "can be done" and "was done and measured" is the most
expensive thing to learn on the day you need it.

---

## PostgreSQL: setup **requires a restart**

`pg_stat_statements` is a **shared preload** library: it is taken into memory
as the postmaster starts and cannot be loaded afterwards. A `reload` (SIGHUP)
is not enough, and it cannot be changed with a `SELECT`.

```bash
./scripts/slowlog.sh kur postgresql
```

This command:

1. links `config/postgresql/slowlog.conf` into `postgresql.conf` with an
   `include_if_exists` line,
2. creates the extension (`CREATE EXTENSION pg_stat_statements`),
3. says that **measurement has not started yet** and prints the restart
   command.

```bash
docker compose up -d postgresql        # kesintiyi SİZ seçiyorsunuz
./scripts/slowlog.sh durum postgresql
```

(the comment reads: YOU choose the downtime)

The script **does not restart the server by itself**. It does not know what is
running at that moment; the decision to shut down a production database
belongs to the user. The JSON output states this in-between state in a
separate field: `"enabled": false, "pending_restart": true`. If the panel
showed this as "on", the user would look at an empty list the next day and
think the tool was broken.

### `include_if_exists`, not `include`

The config file comes from the host via a bind mount. The repo gets moved, the
mount disappears or the file is deleted; in that case `include` **brings
PostgreSQL down at startup**. A measurement tool's config file must not be
able to stop the database from coming up — when it disappears, the only thing
that should happen is that measurement turns off and `durum` says so.

### The decisions inside `config/postgresql/slowlog.conf`

| Setting | Value | Why |
|---|---|---|
| `shared_preload_libraries` | `pg_stat_statements` | the measurement itself |
| `pg_stat_statements.track` | `top` | with `all`, statements inside functions would be counted separately, **the same time would appear twice** and the total-time ranking would break |
| `pg_stat_statements.track_utility` | `off` | **privacy**: utility statements are not normalized, they are stored with their `CREATE ROLE … PASSWORD '…'` text and `durum` would print that on screen |
| `pg_stat_statements.save` | `on` | with it off, every restart would reset the measurement and there would be no such thing as "the most expensive query of the week" |
| `compute_query_id` | `on` | `pg_stat_activity.query_id` gets filled in too: "the query hanging right now, which row in the list is it" can only be answered that way |

---

## MariaDB: a restart is **not needed**

```bash
./scripts/slowlog.sh kur mariadb --esik 0.5
```

(`--esik` = the threshold flag, in seconds)

There are two sources, and the tool prints on screen which one it used:

**1. The `performance_schema` digest** — the preferred one. It normalizes the
query (`?`), **knows no threshold**, and is reset with `TRUNCATE`.

**2. The slow query log** — writes queries that take longer than
`long_query_time` to a file **in raw text**. It has two limits:

* **THRESHOLD.** The very class this tool is looking for — a short but heavily
  called query — stays under the threshold and lands in the file **not at
  all**. So "the slow query log is empty" does not mean "there are no slow
  queries".
* **PRIVACY.** `WHERE tcno = '12345678901'` is written in the file exactly as
  is.

`performance_schema` is **off** by default in this stack; turning it on
requires a restart:

```ini
# config/mariadb/my.cnf → [mysqld]
performance_schema = ON
```

```bash
docker compose up -d mariadb
```

`kur mariadb` uses `SET GLOBAL`, so the settings are **lost on restart**. To
make them permanent you add the lines in `my.cnf` yourself — the script does
not write into the engine's config file. The reason: `my.cnf` also carries the
engine's memory settings; a measurement tool writing there means nobody can
ever know again who edited that file.

---

## Privacy: query text can carry data

| Source | Text | What the tool does |
|---|---|---|
| `pg_stat_statements` | normalized (`$1`) | shows it as is |
| the `performance_schema` digest | normalized (`?`) | shows it as is |
| MariaDB slow query log | **RAW** | turns string literals and numbers into `?` **and says so on screen** |

If the masking were done silently, the user could not know that the text they
see is not raw, and would therefore **think the log file on disk was safe
too** — while the raw version is sitting right there. In the JSON output the
`"masked": true` field says the same thing to the panel.

---

## `oneri` — three measurable things, nothing invented

```bash
./scripts/slowlog.sh oneri postgresql
```

| Type | How it is measured |
|---|---|
| `indeks` | sequential scan + equality filter in the `EXPLAIN` plan (below) |
| `ardisik-tarama` | `pg_stat_user_tables.seq_tup_read` |
| `kullanilmayan-indeks` | PostgreSQL `idx_scan = 0`, MariaDB `COUNT_FETCH = 0` |
| `tarama-orani` | ratio of examined / returned rows |

**`indeks`** — the plans of the most expensive queries are actually looked at.
PostgreSQL 16's `EXPLAIN (GENERIC_PLAN)` option plans `$1` parameters without
real values; it exists for exactly this job. If the plan shows `Seq Scan …
Filter: (sütun = $1)`, that column is being read. The column name is also
verified in `pg_attribute`, and if the table is not big enough the suggestion
is **not given** — on a small table a sequential scan is already the right
plan. Only **equality** filters are suggested: for a filter containing `<`,
`LIKE '%…%'` or a function call an ordinary B-tree index usually does not help
and would produce the "I added an index and nothing changed" outcome. On
versions older than PostgreSQL 16 this step is **skipped, and the skip is
stated**.

**`ardisik-tarama`** — the ranking is not by the *number* of scans but by the
number of **rows read** in those scans. Scanning a 40-row table a million
times is cheap; scanning a 10-million-row table ten times is not.

**`kullanilmayan-indeks`** — on MariaDB the criterion is `COUNT_FETCH`, not
`COUNT_STAR`. `COUNT_STAR` counts reads **and writes together**; an index that
is never read on a constantly written table shows up there as greater than
zero and would never enter the list — yet that is exactly the index we are
looking for.

**`tarama-orani`** — a query that examines 2 million rows and returns 10 is
reading the whole table to do its job.

### A suggestion is **not applied**, it is only written out

Adding an index speeds up the read path but **slows down every
`INSERT`/`UPDATE`** and takes space on disk; dropping an index is a job that
takes minutes to undo. Only someone who knows the application can make that
trade-off. That is why `oneri` runs only `SELECT`/`EXPLAIN` and prints the
commands on screen; `ANALYZE` is not given to `EXPLAIN`, so the query is
**not run**.

The e2e suite verifies this promise by counting the number of indexes before
and after.

### What is left out, and why

Not every index that looks "unused" can be dropped:

* **PRIMARY / UNIQUE / exclusion constraint** — dropping it removes not the
  index but **the rule**.
* **`indisreplident`** — logical replication identifies the row with this
  index.
* **Foreign key index (MariaDB)** — the engine already refuses the drop; had
  we suggested it, we would have handed out a command that will not work.

### `idx_scan = 0` does not always mean "never used"

It means "not used **since the counter was reset**". That is why every `oneri`
output prints the **observation window**. The counters are also per node: an
index unused on the primary may be in use on the replica.

---

## `sifirla` — and what `--vt` means specifically on PostgreSQL

```bash
./scripts/slowlog.sh sifirla postgresql --vt uygulama   # yalnız o veritabanı
./scripts/slowlog.sh sifirla postgresql                 # KÜME GENELİ
```

(`--vt` = the database flag; `uygulama` is a database name here. The comments
read: only that database · CLUSTER-WIDE)

On PostgreSQL, `pg_stat_statements_reset(userid, dbid, queryid)` exists for
exactly this. On MariaDB the counters cannot be reset per database
(`performance_schema` tables accept only `TRUNCATE`); there `--vt` is
**ignored, and that is stated**. Had we silently reset the whole server, the
user would have thought they cleared only their own database.

Accumulated measurement does not come back.

---

## JSON output

The last line is always a single line of JSON; the panel and the controller
read it.

```json
{"engine":"postgresql","command":"durum","source":"pg_stat_statements",
 "enabled":true,"pending_restart":false,"masked":false,
 "rows_kind":"returned","threshold_ms":null,
 "queries":[{"query":"SELECT count(*) FROM t_sik WHERE dolgu = $1",
             "calls":400,"total_ms":53.0,"avg_ms":0.132,"rows":400,
             "blocks":10000,"db":"slowtest"}],
 "total_ms":199.5,"suggestions":[],"seconds":13,"ok":true,
 "detail":"ölçüldü: 1 motor, 4 sorgu listelendi, toplam 199.5 ms"}
```

(`detail` reads: measured: 1 engine, 4 queries listed, 199.5 ms in total)

**The field names are the same on every engine; their being filled in is
not.** On MariaDB `"blocks"` is JSON `null`, not `0` — InnoDB does not keep a
counter for blocks read per query. Had we written `0`, the panel would say "it
read no disk at all, the problem is not here"; whereas the right answer is
"there is no such measure on this engine".

`"rows"` counts a different thing depending on the engine, which is why
`rows_kind` sits next to it:

| Engine | `rows_kind` | Meaning |
|---|---|---|
| postgresql | `returned` | **returned** rows |
| mariadb | `examined` | **examined** rows |

Had we not written the difference down, the answer to "why is a query that
returns 10 rows slow" would be lost — that number on MariaDB may be saying 2
million rows were examined, and that is exactly the real finding.

---

## Exit codes

| Code | Meaning |
|---|---|
| 0 | the job is done |
| 1 | **the job failed** — the setting could not be written, the reset failed |
| 2 | **out of scope** or a usage error |
| 3 | **could not measure** — engine down, no docker, the query failed |
| 4 | **MEASUREMENT OFF** — not "no slow queries found", but "nothing was ever looked at" |

`0`, `3` and `4` are separate deliberately: "I looked, it is clean", "I could
not look" and "nothing was ever looked at" are three different answers, and
each of the three requires different work.

---

## Measurement: `scripts/e2e/slowlog.sh`

```bash
./scripts/e2e/slowlog.sh              # çalışan motorların hepsi
./scripts/e2e/slowlog.sh postgresql   # yalnız biri
```

(the comments read: all running engines · only one of them)

The suite runs four queries of known cost and compares, with numbers, how the
tool reports them: is the expensive query in the first N, is the call count
right, is the ranking really by total time, does the cheap query fill the
list, does `sifirla` really reset, does `oneri` apply anything, does `kur`
silently restart the server.

**Its side effects** are written at the top of the suite: it creates and
deletes a temporary database, resets the counters (server-wide on MariaDB),
and changes MariaDB's global slow query settings and **writes them back**.

On PostgreSQL, if measurement is off the actual checks are **skipped** and the
reason is printed; the suite does not restart a production database by itself.
If a restart is acceptable:

```bash
E2E_SLOWLOG_YENIDEN_BASLAT=1 ./scripts/e2e/slowlog.sh postgresql
```
