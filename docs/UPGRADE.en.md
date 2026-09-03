# Version upgrade

*[Türkçe](UPGRADE.md) · **English***

Every image version in this stack is **pinned** in `.env` (there is no `latest`).
No surprise update arrives; an upgrade is a deliberate decision.

## Why does this need care?

When a database's MAJOR version changes, the data format on disk changes too.
If the new version does not recognize the old data, the container does not start —
**no data is lost** but the service does not run. That is why `install.sh` detects
the existing volumes and automatically pins a compatible version:

| Engine | Pinned if data already exists | Why |
|---|---|---|
| MongoDB | `4.4` | 4.4 → 7.0 cannot be jumped directly (the 5.0 → 6.0 → 7.0 order is required) |
| PostgreSQL | `15` | a major transition requires `pg_upgrade` or dump/restore |

On the other engines (MariaDB, Redis, ClickHouse, Cassandra…) an upgrade within the
same major is trouble-free.

---

## PostgreSQL 15 → 16

The safest path is dump/restore. On small-to-medium data sets it takes minutes.

```bash
# 1. Take a backup and VERIFY it (never upgrade without one)
./stack.sh backup postgresql
./scripts/backup.sh verify backups/postgresql/full/postgresql_full_*.sql.gz

# 2. Motoru durdur
./stack.sh disable postgresql

# 3. Move the old data aside (do not delete it — this is your way back)
docker volume create databases-stack_postgresql_data_v15_yedek
docker run --rm -v databases-stack_postgresql_data:/eski \
                -v databases-stack_postgresql_data_v15_yedek:/yeni \
                alpine sh -c 'cp -a /eski/. /yeni/'
docker volume rm databases-stack_postgresql_data

# 4. Raise the version and start with an empty cluster
sed -i 's/^POSTGRES_VERSION=.*/POSTGRES_VERSION=16/' .env
./stack.sh enable postgresql

# 5. Restore the backup
./stack.sh restore postgresql backups/postgresql/full/postgresql_full_*.sql.gz
```

(The comments in the block, step by step: 1 — take a backup and VERIFY it (do not upgrade
without a backup); 2 — stop the engine; 3 — set the old data aside (do not delete it — this
is your way back); 4 — raise the version and start with an empty cluster; 5 — restore the backup.)

If something goes wrong: set `POSTGRES_VERSION=15` and copy the `databases-stack_postgresql_data_v15_yedek`
volume back under the name `databases-stack_postgresql_data`.

---

## MongoDB 4.4 → 7.0

MongoDB **does not allow skipping** intermediate versions. At every step
`featureCompatibilityVersion` (FCV) must be raised.

```bash
./stack.sh backup mongodb          # önce yedek

for v in 5.0 6.0 7.0; do
  prev=$(grep ^MONGO_VERSION= .env | cut -d= -f2)
  # Raise the FCV while still on the previous version
  docker exec mongodb mongosh --quiet -u root -p "$(grep ^MONGO_PASSWORD= .env | cut -d= -f2)" \
    --authenticationDatabase admin \
    --eval "db.adminCommand({setFeatureCompatibilityVersion:'${prev}', confirm:true})"
  # Then switch the image
  sed -i "s/^MONGO_VERSION=.*/MONGO_VERSION=$v/" .env
  [ "$v" != "4.4" ] && sed -i "s/^MONGO_SHELL=.*/MONGO_SHELL=mongosh/" .env
  ./stack.sh disable mongodb && ./stack.sh enable mongodb
  sleep 30
done
```

(The comments in the block: `# önce yedek` = back up first; `# Bir önceki sürümde FCV'yi yükselt`
= raise FCV on the previous version; `# Sonra imajı değiştir` = then change the image.)

> 4.4 has no `mongosh`; in the first step `MONGO_SHELL=mongo` is required — if `install.sh`
> finds existing data it already sets this.

---

## Updating the stack itself

> **If you are coming from before v1.0, recreate the gateway ONCE:**
> ```bash
> docker compose --env-file .env -p databases-stack up -d --force-recreate gateway
> ```
> The routing table is mounted into the gateway as a single file, and Docker binds a file
> mount to the inode. The old version replaced that file with a rename and broke the
> mount; the container could not see the current table. The new version writes in place,
> but an existing container is still bound to the old inode.


```bash
cd /opt/databases
git pull
./install.sh          # var olan .env ve parolalara DOKUNMAZ, eksikleri tamamlar
./stack.sh doctor
```

(The comment on `./install.sh`: it does NOT touch the existing `.env` or the passwords; it fills in what is missing.)

`install.sh` is idempotent: it preserves the existing passwords, the CA certificate and the
data volumes. It generates only what is missing.
