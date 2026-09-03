# Licenses

*[Türkçe](LICENSING.tr.md) · **English***

> This page is for information only, not legal advice. If you are in doubt, ask
> your legal department.

This stack can be used in production free of charge **with its default settings**,
SQL Server included (it ships with the Express edition). There are **two cases
that need attention**:

1. **If you set `MSSQL_PID` to `Developer`, that installation cannot be used in
   production** — this is a legal obligation, not a technical limit. The default
   is `Express`, so it only applies if you deliberately change it.
2. **Offering SSPL / AGPL licensed engines to third parties *as a service*** can
   create an obligation to open your source. Using them for your own application
   is free.

---

## Per engine

| Engine | License | Free in production? |
|---|---|---|
| **PostgreSQL** | PostgreSQL License | ✅ No restrictions |
| **MariaDB** | GPL-2.0 | ✅ No restrictions |
| **Cassandra** | Apache-2.0 | ✅ No restrictions |
| **Kafka** | Apache-2.0 | ✅ No restrictions |
| **ClickHouse** | Apache-2.0 | ✅ No restrictions |
| **RabbitMQ** | MPL-2.0 | ✅ No restrictions in practice |
| **MongoDB** | SSPL-1.0 | ⚠️ Copyleft — see below |
| **Redis** | AGPL-3.0 / RSALv2 / SSPL | ⚠️ Copyleft — Valkey is an alternative |
| **Elasticsearch** | Elastic License 2.0 / SSPL | ⚠️ Copyleft |
| **Neo4j Community** | GPL-3.0 | ⚠️ Copyleft; clustering is in Enterprise |
| **MinIO** | AGPL-3.0 | ⚠️ Copyleft |
| **SQL Server** | Express Edition (default) | ✅ Free — 10 GB limit per DB |

In the panel you see the license under every card; the restricted ones are
marked, and a warning appears in the activation confirmation.

```bash
./stack.sh licenses     # terminalden aynı özet
```

(`# terminalden aynı özet` = the same summary from the terminal.)

---

## SQL Server — which edition ships?

The default is **`MSSQL_PID=Express`**: it is free and **can be used in
production**. This stack aims at an installation that runs with the minimum
licensing burden, so Express was deliberately chosen as the default.

Express's limits:

| Limit | Value |
|---|---|
| Data per database | 10 GB |
| Buffer pool | ~1.4 GB |
| Cores used | 4 at most |

That is why the panel gives SQL Server ~3 GB at most: Express cannot use more
than that anyway, and allocating it would be stealing from the other engines.

Other options:

```bash
# All features on, free of charge — but for development/testing ONLY
MSSQL_PID=Developer

# Purchased license
MSSQL_PID=Standard      # ya da Enterprise
```

(`# Tüm özellikler açık, ücretsiz — ama YALNIZ geliştirme/test` = all features
on, free — but for development/testing ONLY; `# Satın alınmış lisans` = a
purchased license; `# ya da Enterprise` = or Enterprise.)

Change it in `.env`, then `./stack.sh disable mssql && ./stack.sh enable mssql`.

---

## ⚠️ Copyleft engines — what does that mean?

**If you are using one for your own application, no obligation arises at all.**
Your company's CRM may be using MongoDB instead of PostgreSQL; that is fine.

The obligation arises when you **offer the engine to other people as a managed
service** — "I sell MongoDB hosting", "I expose Elasticsearch to the customer as
a search API", that kind of thing. In that case SSPL asks for the whole software
stack running the service to be opened; AGPL asks for the source you modified.

### Redis → Valkey (drop-in replacement)

Redis moved to RSALv2/SSPL with 7.4; with 8.0 an AGPL-3.0 option was added. If
you do not want copyleft, **Valkey** is a BSD-3 licensed fork under the Linux
Foundation and matches it one for one at the protocol/command level:

```bash
# .env
REDIS_IMAGE=valkey/valkey:8-alpine
```

Everything in the stack (RedisInsight, the exporter, backups, replication,
failover) works without requiring any change.

### Elasticsearch → OpenSearch (not a drop-in)

OpenSearch is Apache-2.0, but **it is not a direct replacement**: you need
OpenSearch Dashboards instead of Kibana, and the client libraries are different.
If you want to switch, you have to change the engine with `ELASTIC_IMAGE` and
replace the Kibana service with your own Dashboards.

### MongoDB → FerretDB

FerretDB (Apache-2.0) speaks the MongoDB wire protocol on top of PostgreSQL. It
works for simple CRUD workloads; there are differences in aggregation pipeline
and transaction support. Try it with your own queries before you switch.

### MinIO — what exactly is the situation?

MinIO **is not paid software**, it is AGPL-3.0 and it has stayed that way. What
changed: in 2025 the **management features** in the community edition's web
console were moved into the commercial AIStor product; what is left in the
community console is the basic object browser.

That is why the version is deliberately pinned to **before** that change:

```bash
MINIO_VERSION=RELEASE.2024-10-13T13-34-11Z
```

This way the MinIO Console in the panel works fully. If you want to move to a
newer version, the server side updates without trouble; only the console's
management screens disappear (you do bucket/user management with the `mc`
command line).

> **Do not use `bitnami/minio`.** Bitnami moved its catalog into the paid
> "Bitnami Secure Images" in 2025 as well; the `bitnamilegacy/*` images that
> stayed free were frozen and **get no security patches**. Choosing an old image
> out of licensing concern means putting an unpatched image into production — a
> bad trade-off.

If you want an S3 alternative with no copyleft at all: **SeaweedFS**
(Apache-2.0).

---

## Using your own image

Every engine's image can be replaced entirely with `<MOTOR>_IMAGE`. This is good
for three things:

```bash
# 1. Lisans alternatifi
REDIS_IMAGE=valkey/valkey:8-alpine

# 2. Your own registry mirror on an air-gapped network
MARIADB_IMAGE=registry.sirket.local/mariadb:11.4
POSTGRES_IMAGE=registry.sirket.local/postgres:16

# 3. In-house hardened image
POSTGRES_IMAGE=registry.sirket.local/hardened/postgres:16-fips
```

(`# 1. Lisans alternatifi` = a licensing alternative; `# 2. Kapalı ağda kendi
registry aynanız` = your own registry mirror on a closed network; `# 3. Kurum içi
sertleştirilmiş imaj` = an in-house hardened image.)

The variables: `MARIADB_IMAGE`, `POSTGRES_IMAGE`, `MONGO_IMAGE`, `REDIS_IMAGE`,
`MSSQL_IMAGE`, `CASSANDRA_IMAGE`, `ELASTIC_IMAGE`, `KAFKA_IMAGE`,
`RABBITMQ_IMAGE`, `CLICKHOUSE_IMAGE`, `NEO4J_IMAGE`, `MINIO_IMAGE`.

---

## This project's own license

`databases-stack` is MIT licensed ([LICENSE](../LICENSE)). The project **does not
redistribute** the engines; it pulls them from Docker Hub / the official
registries. So each engine's license is directly between you and that engine's
owner.
