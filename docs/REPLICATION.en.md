# Replica (replication)

*[Türkçe](REPLICATION.md) · **English***

A replica is a second, continuously updated copy of the primary database. It is good for two things:

- **Redundancy** — if the primary is corrupted, the data is still sitting in the second copy
- **Read scaling** — reports/analytics read from the replica, and the primary gets some relief

> ⚠️ A replica **is no substitute for a backup.** A table deleted by accident is
> reflected on the replica just as instantly, deleted there too. A replica and regular backups are used together.

## Setting up

**Set up replica** ("Replika kur") under the relevant card in the panel, or:

```bash
./stack.sh replica on postgresql
./stack.sh replica off postgresql
```

The system checks the memory budget for the replica too; if there is no room, it does not set one up.

## Per engine

| Engine | Method | Downtime | Replica port |
|---|---|---|---|
| **PostgreSQL** | streaming replication | none | 5433 |
| **MariaDB** | GTID asynchronous replication | none | 3307 |
| **Redis** | `replicaof` | none | 6380 |
| **MongoDB** | replica set (rs0) | **yes** | 27018 |

### PostgreSQL
The replica pulls a full clone of the primary with `pg_basebackup`, then attaches to the
WAL stream. The replica is **readable** (hot standby) — you can point your reports at it.
Write attempts return an error; that is the expected behavior.

Check: `docker exec postgresql psql -U root -c "SELECT * FROM pg_stat_replication;"`

### MariaDB
A consistent dump is taken from the primary with `--gtid` and loaded into the replica, then
the stream starts with `CHANGE MASTER ... MASTER_USE_GTID=slave_pos`. Thanks to GTID the
replica resumes from exactly the right point — no data is skipped or repeated.

The binlog must be enabled; it is enabled in `config/mariadb/my.cnf`.

Check: `docker exec mariadb-replica mariadb -u root -e "SHOW SLAVE STATUS\G"`
→ `Slave_IO_Running: Yes`, `Slave_SQL_Running: Yes`, `Seconds_Behind_Master: 0`

### Redis
The simplest one — the replica is brought up with `replicaof redis 6379` and synchronizes
immediately. There is no downtime, and the replica is read-only.

### MongoDB — mind the downtime
Turning replication on in MongoDB requires restarting **the primary as well** with the
`--replSet` parameter. That means a few seconds of downtime.
The panel says this plainly in the confirmation dialog.

The members also verify each other with a shared key file
(`state/mongo-keyfile`); `install.sh` generates it and sets its permissions.

## Engines that scale by clustering

Cassandra, Elasticsearch and Kafka have no "primary/replica" concept; these scale by
adding nodes:

- **Cassandra** — `replication_factor` per keyspace, then adding nodes
- **Elasticsearch** — `number_of_replicas` per index (cannot be assigned on a single node;
  that is why the `yellow` health status is normal)
- **Kafka** — `replication.factor` per topic (at most 1 on a single broker)

Real clustering for these is beyond the scope of a single machine.

## Failover

This product **does not do automatic failover** — a deliberate choice. To work properly,
automatic failover wants a quorum (at least 3 nodes); on a single machine it does nothing
but increase the risk of "split-brain".

If the primary is lost, promotion is done manually:

```bash
# PostgreSQL
docker exec postgresql-replica pg_ctl promote -D /var/lib/postgresql/data/pgdata

# MariaDB
docker exec mariadb-replica mariadb -u root -e "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=OFF;"

# Redis
docker exec redis-replica redis-cli REPLICAOF NO ONE
```
Then point your application's connection address at the replica port.
