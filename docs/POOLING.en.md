# Connection pool (PgBouncer) — 6432

*[Türkçe](POOLING.md) · **English***

In PostgreSQL every connection is a separate **process**. The one-sentence
summary of this document: an application that uses no pool kills the database
not with *memory* but with *process count*. A 2 GB PostgreSQL whose
`shared_buffers` and `work_mem × max_connections` math was done correctly
becomes unable to answer — while still saying "there is enough RAM" — under a
small application that opens 200 short-lived connections.

This stack serves a PgBouncer on port **6432**. **5432 does not change**: the
direct connection is the default path, the pool is open to whoever wants it.

---

## 1. When it is needed

A pool **is needed** if:

- Your application server opens a new connection on every request — PHP-FPM,
  CGI, cron jobs, short-lived workers, code running "serverless".
- You are seeing `FATAL: sorry, too many clients already`.
- The query below returns hundreds of `idle` rows:

```sql
SELECT state, count(*) FROM pg_stat_activity GROUP BY state ORDER BY 2 DESC;
```

A pool **is not needed** if:

- Your application framework already keeps a pool (HikariCP, SQLAlchemy
  `pool_size`, the `pgx`/`node-postgres` pool). The connection count is already
  bounded; a second pool layer brings no benefit, it only adds one more hop.
- You run long analytical queries: the pool takes the connection back when the
  *transaction* ends, and there is no gain in a single long transaction.

---

## 2. The difference between 5432 and 6432

| | **5432 — direct** | **6432 — pooled** |
|---|---|---|
| Behind it | PostgreSQL itself | PgBouncer, `pool_mode = transaction` |
| Session state | preserved | **not preserved** (see section 3) |
| Cost of a connection | a process (megabytes) | a buffer (~8 KB) |
| On failover | the gateway table is updated automatically | the pool **must be recreated** |
| Who should use it | psql, pgAdmin, backup, replication, migration tools | applications that open many short-lived connections |

Turning 5432 into a pool was deliberately not done: (1) the replication and
failover tests measure the path that goes through 5432, and changing that port
would separate the path the test verifies from the product's real path;
(2) transaction pooling can silently break working clients — the default cannot
be a thing like that.

---

## 3. The limits of transaction pooling

`pool_mode = transaction`: the server connection returns to the pool **when the
transaction ends** and on the next transaction it can go **to another client**.
That is why everything that hangs on the session is unreliable:

- `PREPARE` / `DEALLOCATE` at the SQL level
- session variables via `SET` / `RESET`
- `LISTEN` / `NOTIFY`
- `WITH HOLD` cursors, session-level advisory locks, temporary tables

**What does work:** prepared statements at the protocol level (JDBC, asyncpg,
Npgsql, `pgx`). In PgBouncer 1.25.2 the `max_prepared_statements` default is
**200** — verified with `SHOW CONFIG` on the running pool — so these drivers
work fine under transaction pooling.

**The insidious part:** when you try it with a single client, `PREPARE` +
`EXECUTE` and `SET` look like they "work". Measured: with no other client in
the pool the same server connection is handed back, so it does the job. Under
load that guarantee **does not exist**; the breakage only surfaces once
concurrency rises. Work that needs session behavior must connect to 5432.

---

## 4. Where the pool settings come from

The settings are **derived from `POSTGRES_MAX_CONNECTIONS`** — they are not
fixed. The rule is this: *the connections the pool will open on the server
cannot exceed what the server accepts.* If they do, the pool does not solve the
problem, it **produces** one: it takes the `too many clients` error away from
the application and carries it onto itself, and from then on the single point
of failure is the pool.

The math is done by the `pgbouncer` entrypoint in `docker-compose.yml`. The 200
example:

| Setting | Formula | At 200 | Why |
|---|---|---|---|
| `default_pool_size` | `max_connections / 4` | 50 | a single (role, database) pair should not take more than a quarter of the share |
| `max_user_connections` | `max_connections / 2` | 100 | ceiling per role |
| `max_db_connections` | `max_connections / 2` | 100 | ceiling per database |
| `max_client_conn` | `max_connections × 5` | 1000 | a client is cheap (~8 KB), a server connection is expensive (a process) |

The remaining **50% is left free deliberately**: pgAdmin, `postgres-exporter`,
the `pg_dump` that takes the backup and the administrator connecting directly
to 5432 must be able to find a connection too. If the pool eats that share as
well, the database looks "up" while you become unable to look at it from the
panel or to take a backup.

There is no **global** upper limit in PgBouncer; the two ceilings above work
together. So the limit is exactly this: the total number of connections the
pool can open is `100 × min(number of roles, number of databases)`. **As long
as the smaller of the two does not exceed 2**, the total cannot exceed
`max_connections`. If you are going to use more than three roles *and* more
than three databases over the pool at the same time, increase `max_connections`
(more RAM = the `per_gb` rule in the catalog) or gather the applications onto a
single role.

If no free server connection is left at peak, the client **is not refused, it
is queued** (`query_wait_timeout` default 120 s). The whole value of the pool
is here: 1000 clients queue up, the database keeps working with 50 processes.

---

## 5. After a failover the pool MUST BE RECREATED

PgBouncer's target is the **primary**, and on failover the primary changes
(`postgresql` → `postgresql-replica`). The target address comes from the
`POSTGRES_PRIMARY_HOST` environment variable, but it is written into
`pgbouncer.ini` **when the container is created**: a running container does not
re-read the environment variable. If it is not recreated after a failover, the
pool keeps looking at the fenced (stopped) old primary — for applications
connecting to 6432 it looks as if the failover never happened.

```bash
docker compose --profile postgresql up -d --force-recreate --no-deps pgbouncer
```

This is a job of the same class as recreating the monitoring endpoint
(`postgres-exporter`) on failover; the difference is that what is affected here
is not the graphs but the **traffic**.

**Do not confuse this:** if the primary comes back up *under the same name*
(a restart, a short downtime) the pool recovers on its own. Measured: when the
backend goes down clients are queued, and ~15 s after the backend returns
(`server_login_retry`) queries flow again. Recreating is needed only **when the
address changes**.

---

## 6. What the health check says and what it does not

The healthcheck of the `pgbouncer` service runs `pg_isready -p 6432` and
measures **only the pool process**. Measured: it says `accepting connections`
even when PostgreSQL is completely stopped, because PgBouncer accepts the
client and queues it. This is deliberate: the engine's health is already
measured in the `postgresql` service's healthcheck; measuring it a second time
would show the pool as "sick" while it is perfectly fine and would produce
unnecessary restarts.

---

## 7. Verification

```bash
# Havuz üzerinden gerçek sorgu
psql "postgresql://root@SUNUCU:6432/defaultdb" -c "select 1"

# Yönetim konsolu: hangi havuz kaç bağlantı tutuyor
psql "postgresql://root@SUNUCU:6432/pgbouncer" -c "SHOW POOLS;"
psql "postgresql://root@SUNUCU:6432/pgbouncer" -c "SHOW CONFIG;"

# Açılışta hesaplanan sayılar loga basılır
docker logs pgbouncer | head -20
```

(`SUNUCU` = your server address. The comments, top to bottom: a real query
through the pool; the admin console — which pool is holding how many
connections; the numbers computed at startup are printed to the log.)

---

## 8. Not there on Kubernetes

For each engine `scripts/gen-k8s.py` produces only the engine's own
StatefulSet; **PgBouncer is not in the manifests**. Port 6432 shows up on the
generated `postgresql` Service, but nothing answers on it because there is no
pool behind it. If you want a pool on K8s you need to add a separate Deployment
+ Service; this stack's pool belongs to the Docker setup.
