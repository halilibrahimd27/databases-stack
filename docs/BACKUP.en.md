# Backups

*[Türkçe](BACKUP.md) · **English***

The side that **takes** the backup is a single script: `scripts/backup.sh`. The
panel calls it, the nightly scheduler calls it, the command line calls it.
There is no second implementation of the same job — if the file produced at
night and the file the panel produces went through different paths, which one
could be restored would only become clear on disaster day.

This document describes both routes; both are supported and both produce the
same result.

---

## Panel: `/yedekler`

Backups have **their own page**: `https://<sunucu>/yedekler` (`<sunucu>` = your
server host). It opens from the *Backups* ("Yedekler") link in the **Tools**
("Araçlar") row at the top of the admin panel, and you come back with
**← Admin panel** ("← Yönetim paneli") at the top of the page. It sits behind
the same password and the same TLS door as the panel; it does not open without
the password.

The page has two areas: **Automatic backup** ("Otomatik yedek") and **Engines**
("Motorlar"). Restore lives inside the second one, described under a separate
heading below.

### Automatic backup

The daily backup time and the retention period are set here; turning it on and
off is a single button. The moment you save, the time of the next run is
written on the screen.

The scheduler runs **inside the controller**: it needs no root on the host, no
`crontab` installation, no systemd unit. Having the same process read the
setting and run the job makes the "I saved it but it ran at the old time again
last night" class of bug impossible from the start.

The same area holds the result of the last run: if it succeeded, when that was;
if it failed, **together with the reason**. A failed backup is the most
expensive delusion of a user who thinks "I have a backup"; we are not sending
you to a log file.

While scheduling is off, the page writes this not as a setting state but as a
**risk** — so that it does not stay silently off. `./stack.sh doctor` says the
same thing.

### Engines

Each engine's row shows how many backups it has, their total size, and when the
newest one was taken. An engine with no backups at all is marked separately:
what used to get missed because of empty columns was exactly this.

The **Back up now** ("Yedek al") button takes that engine's backup immediately.
A manually taken backup does not cancel the nightly round, it creates an extra
recovery point. The button is not clickable while the engine is down: the dump
tools (`mariadb-dump`, `pg_dumpall`, `mongodump` …) **connect** to the
database, and there is nothing for them to do on a stopped engine.

When you open the file list in the row, each backup's date, size and **source**
are visible:

| Label | Meaning |
|---|---|
| `elle` | Taken from the panel with **Back up now** (`elle` = manual) |
| `zamanlı` | Produced by the nightly round (`zamanlı` = scheduled) |
| `dış` | Host cron or the command line (`dış` = external) |

The source is not guessed from the file name. `backup.sh` does not write its
source into the file name, and making it do so would mean changing the
file-name convention (restore, cleanup and the end-to-end tests look at that
name). Instead the controller marks the files that appear after a run it
started itself in a separate ledger (`state/backup_index.json`); a file that
never entered the ledger is `dış`. Counting that as "zamanlı" would be a lie.

The list is limited to **the last 40 files** — a year of daily backups means
365 rows, and the page redraws itself regularly. The existence of the ones
outside the limit is held in the row's total count; the count and the list
never contradict each other.

The extensions counted as backups are `*.gz` (unencrypted) and `*.gz.enc`
(encrypted) — both are recovery points, the only difference is the envelope.
Files that could not pass verification and were set aside with the `.bozuk`
extension are **not** recovery points; counting them would mean printing "you
have 3 backups" on the panel while there is no backup at hand.

---

## Command line

```bash
./stack.sh backup                # aktif motorların hepsi (kapalılar atlanır)
./stack.sh backup mariadb        # tek motor
./scripts/backup.sh list         # yedekleri listele
./scripts/backup.sh stats        # boyut, adet, en son ne zaman
./scripts/backup.sh clean 7      # 7 günden eskileri sil
./scripts/backup.sh verify <dosya>
./scripts/backup.sh sifreleme   # yedek şifrelemesi açık mı, hangi anahtarla
```

(`sifreleme` = encryption, `<dosya>` = the backup file. The comments read: every
active engine, stopped ones are skipped · a single engine · list the backups ·
size, count, when the latest one was · delete anything older than 7 days · is
backup encryption on, and with which key)

## Running it automatically

There are two routes and both are supported.

**1) From the panel** (recommended) — the *Automatic backup* area on the
`/yedekler` page. The setting is kept in the `state/backup.json` file, and the
controller is what runs it.

**2) Host cron** — `install.sh` generates the `state/crontab` file with the
real paths:

```bash
crontab state/crontab
```

| Time | Job |
|---|---|
| 02:00 | Full backup of the active engines |
| 02:30 | Upload to remote storage (if on) |
| 03:00 | Deletion of local backups older than `RETENTION_DAYS` |
| 08:00 | Statistics report |
| Sunday 04:00 | Renewal of the TLS certificate if less than 30 days are left |

If the two run together it is not a problem: `backup.sh` holds its own lock on
`state/backup.lock`, and the second run is refused. The panel checks that lock
**beforehand** — otherwise the manually started job died with the script's
"another process holds the lock" death and the screen showed "backup failed";
yet a backup was being taken, just by another run.

> The panel scheduling is the result of a measured failure. Previously
> `install.sh` only *generated* `state/crontab` and said "to install it,
> `crontab state/crontab`". Nobody was doing it: on the test server
> `crontab -l | grep backup` returned zero lines and the folders under
> `backups/` were empty. Backups were thought to be taken while none were.

### Retention period

The default is 7 days (`RETENTION_DAYS`), changeable from the panel between 1
and 365. The cleanup **keeps the newest few copies of every engine no matter
how old they are** (`BACKUP_KEEP_MIN`, default 3): the files of an engine that
is down, or whose backups have failed over and over, are not refreshed, so they
cross the date threshold and the old version was deleting its **last** recovery
point too — when the engine was started again, no backup was left.

The cleanup runs even if the backup falls: the reason a backup falls is most
often a full disk, and skipping the cleanup in exactly that situation makes
things worse.

### Why once a day, not every 15 minutes?

Backups are taken **inside** the database container, and the dump's memory
consumption is charged to that container's own cgroup. A full backup every 15
minutes killed MariaDB again and again with `CONSTRAINT_MEMCG` OOM — the
container restarted 172 times. One full backup a day removes that pressure.

If you need recovery points more often, use **binlog / PITR** instead of dumps:
binlog is on in MariaDB now (`config/mariadb/my.cnf`) and, because the dumps
are taken with `--master-data=2`, you can go back to whichever point you want
with the binlogs that pile up after a backup.

Backups run with `nice -n 19 ionice -c3` — live database traffic always stays
first in line.

## Method per engine

| Engine | Method | File |
|---|---|---|
| MariaDB | `mariadb-dump --all-databases --single-transaction --master-data=2` | `.sql.gz` |
| PostgreSQL | `pg_dumpall` (roles and passwords included) | `.sql.gz` |
| MongoDB | `mongodump --archive --gzip` | `.archive.gz` |
| Redis | `BGSAVE` + `dump.rdb` | `.rdb.gz` |
| SQL Server | `BACKUP DATABASE` (master and msdb included) | `.tar.gz` |
| Cassandra | `nodetool flush` + `snapshot` + schema | `.tar.gz` |
| Elasticsearch | Snapshot API | `.tar.gz` |
| ClickHouse | native `BACKUP DATABASE` command | `.tar.gz` |
| RabbitMQ | `export_definitions` (the definitions, not the messages) | `.json.gz` |
| MinIO | data-directory archive (objects are immutable) | `.tar.gz` |
| Neo4j | offline dump — **requires downtime** | `.dump.gz` |
| Kafka | not backed up | — |

While encryption is on, `.enc` is appended to every file's name
(`.sql.gz` → `.sql.gz.enc`); the format does not change, an envelope goes over
it. Detail: [Backup encryption](#backup-encryption).

### Neo4j

There is no online backup in the Community edition (it is an Enterprise
feature). Taking a backup requires stopping the database, which is why it does
not run automatically inside `backup all`:

```bash
BACKUP_NEO4J_OFFLINE=true ./scripts/backup.sh neo4j
```

### Kafka

Kafka is a log, not a database. Durability comes not from backups but from
per-topic `replication.factor` and `retention.ms`. Because its backup is marked
"not supported" in the catalog, it does not appear in the `/yedekler` list
either: a record that says "no backups at all" on every row for its whole life
would lose a database that really has been left without a backup inside that
noise.

### Elasticsearch

Copying the data directory produces an **inconsistent** backup; the correct
route is the snapshot API. That needs the `path.repo` setting and a separate
volume — it is already defined in the compose file.

---

## Backup encryption

Backups are **plain gzip** by default. When you give a key in `.env`, every
backup is encrypted with **AES-256**:

```bash
# anahtar üret
openssl rand -base64 32 | tr -d '+/='

# .env
BACKUP_ENCRYPT_KEY=<ürettiğiniz değer>
```

(`# anahtar üret` = generate the key; `<ürettiğiniz değer>` = the value you
generated.)

You can always see the state from here:

```bash
./scripts/backup.sh sifreleme
```

### Why

`scripts/sync-remote.sh` copies the backups to Google Drive / S3 / Backblaze /
SFTP. Without encryption those files leave the building as **plain gzip**:
whoever takes over the remote storage account reads the whole database with
`gzip -dc`. And what they get is not only table data — `pg_dumpall` carries the
roles and the password hashes, the MariaDB dump carries all the user tables. In
installations that put the backup disk on a separate volume
(`BACKUP_DIR=/mnt/backups`, typically a NAS) the file is already sitting
outside the server.

### File-name convention

| Name | Meaning |
|---|---|
| `mariadb_full_20260901_020000.sql.gz` | **Unencrypted** backup (the old flow; still valid) |
| `mariadb_full_20260901_020000.sql.gz.enc` | **Encrypted** backup |
| `…​.gz.bozuk` / `…​.gz.enc.bozuk` | Could not pass verification — **not a recovery point** |

The order is "first `.gz`, then `.enc`" on purpose: the file was compressed
first and encrypted **after**; the name tells that from left to right.

That the `.enc` extension **does not match** the `*.gz` pattern is deliberate
too. Had we named the encrypted file `.gz`, every tool that does not know it
would try `gzip -dc` and die with "not in gzip format" — a noisy error that
points at **the wrong place**. As it is now, the old tools do not see the file
at all; not seeing is better than misunderstanding.

The first 64 bytes of an encrypted file are **a plain-text header**:

```
DBSTACK-ENC1 aes-256-cbc pbkdf2 sha512 600000
```

The encryption parameters sit **inside the file**, not in the script. The
reason: if the iteration count is raised tomorrow, today's backups should stay
openable. Had we hard-coded them into the script, the whole archive would
silently become unreadable the day that change was made, and we would learn it
only on disaster day. The same header also makes it possible to tell that a
file is encrypted **independently of its name**: even if the file has been
renamed, the script says "this backup is encrypted", not "corrupt gzip".

### Why `openssl` (not age or gpg)

- **Availability.** `install.sh` already says `require_cmd openssl` — openssl
  is an *installation requirement* of this product; the TLS certificates
  (`scripts/gen-certs.sh`) and the random passwords (`scripts/lib/common.sh`)
  are generated with it. Choosing `age` or `gpg` would mean adding **a new
  installation dependency** to a product that says "installs with one command";
  neither one ships by default on any distribution.
- **The simplicity of key management.** A symmetric password = one line in
  `.env`, in the same file as `DB_PASSWORD`, with the same permissions. `age`
  wants an *identity file*: a second secret to lose, a separate place to keep
  it, a separate backup rule. `gpg` wants the `~/.gnupg` keyring — and
  `backup.sh` runs **under three separate identities**: host cron (the user),
  the controller container (root), the operator's terminal. Three different
  `$HOME` = three different keyrings = the "works from the panel, does not work
  from cron" class of failure.
- **Recovery.** If on disaster day what is left in your hand is not the stack
  but only the *file*, the decryption command is one line and works on every
  Linux (below). With `age`/`gpg` you first have to install the tool, then
  import the key; the most steps on the worst day.

**What is not promised:** `openssl enc` does not support AEAD (GCM). This
encryption provides **confidentiality**, it does not provide a cryptographic
**integrity signature (MAC)**. A tampered file will almost certainly fall in
the CBC padding, in the gzip CRC or in the `verify` format checks — but that is
not a MAC. Making an assurance that is not promised look promised is more
dangerous than not encrypting at all.

### ⚠️ IF YOU LOSE THE KEY, THE BACKUPS CANNOT BE OPENED

We write this in capitals because there is no way back: **a backup file without
its key is a pile of random bytes.** There is no copy of it, not in this
product and not anywhere else; there is no recovery service, no spare key, no
back door.

Therefore:

- Keep the key **outside the server too** — a password manager, a safe, written
  on paper in an envelope. When the server burns down, that is the thing that
  will open the backup. Keeping the key only on the server is the same thing as
  putting the backup in the same place as the data.
- Back up the `.env` file (or at least this line). `.env` **does not** go into
  version control (`.gitignore`), which means the only thing backing it up is
  you.
- **If you change the key, do not delete the old one**: the old files open with
  the old key. Until `RETENTION_DAYS` runs out and those files are cleaned up,
  you need both. For the copies in remote storage the period is
  `RETENTION_REMOTE_DAYS` (30 days by default) — keep the old key at least that
  long.

If you want to keep the key in a file separate from `.env`:

```bash
install -m 0600 /dev/null /etc/databases-stack/backup.key
openssl rand -base64 32 | tr -d '+/=' > /etc/databases-stack/backup.key
# .env
BACKUP_ENCRYPT_KEY_FILE=/etc/databases-stack/backup.key
```

If the file cannot be read, the backup **stops**; it does not silently produce
an unencrypted backup.

### Restore and verification

No command changes. `verify`, `restore-*`, `list`, `stats`, `clean` and the
drill (`restore-drill.sh`) accept the encrypted file and the unencrypted one
alike; the decryption is done inside the pipeline.

If there is no key, the error is **understandable** — not a gzip error:

```
[✗] Bu yedek ŞİFRELİ, BACKUP_ENCRYPT_KEY tanımlı değil: mariadb_full_….sql.gz.enc
[✗]   .env'de BACKUP_ENCRYPT_KEY (ya da BACKUP_ENCRYPT_KEY_FILE) verin, sonra tekrar deneyin.
[✗]   ANAHTAR KAYIPSA BU DOSYA AÇILAMAZ; kurtarmanın başka yolu yoktur (docs/BACKUP.md).
```

(This backup is ENCRYPTED, `BACKUP_ENCRYPT_KEY` is not defined; give it in
`.env` and try again. IF THE KEY IS LOST THIS FILE CANNOT BE OPENED; there is
no other way to recover it.)

If the key is **wrong**:

```
[✗] Bu yedeğin ŞİFRESİ ÇÖZÜLEMEDİ: mariadb_full_….sql.gz.enc
[✗]   Elinizdeki anahtar bu dosyaya ait değil (ya da dosya kurcalanmış).
[✗]   Çözülen ilk baytlar: 7712 — beklenen: 1f8b (gzip).
```

(This backup COULD NOT BE DECRYPTED: the key you have does not belong to this
file, or the file has been tampered with. First decrypted bytes: 7712 —
expected: 1f8b.)

This second check looks at the **first two bytes** of the file. The reason is
speed: a CBC padding error is understood at the *end* of the stream, meaning a
30 GB file would be read from beginning to end with the wrong key before "bad
decrypt" was said — giving the answer 40 minutes late is the most expensive
answer that can be given during a restore.

### Manual decryption (without the product)

The server, the scripts, all gone; you have only the file and the key:

```bash
export K='<anahtarınız>'
tail -c +65 mariadb_full_20260901_020000.sql.gz.enc \
  | openssl enc -d -aes-256-cbc -pbkdf2 -md sha512 -iter 600000 -pass env:K \
  | gzip -dc > dump.sql
```

(`<anahtarınız>` = your key.)

`tail -c +65` skips the 64-byte header. Read the parameters from the header:

```bash
head -c 64 mariadb_full_20260901_020000.sql.gz.enc; echo
```

Do **not** write the key on the command line (`-pass pass:...`): `ps` output is
open to everyone on the system. That is why the script uses an environment
variable too.

### Cost (measured)

openssl 3.5.5, on an x86-64 with AES-NI:

| What | Time |
|---|---|
| PBKDF2-HMAC-SHA512, 600,000 iterations | **~0.56 s per file** (one time only) |
| Encryption throughput | ~130–220 MB/s |

Because the encryption comes **after** gzip, it processes compressed bytes: a
5 GB dump goes down to 400 MB and is encrypted in ~3 s. The bottleneck is still
gzip.

600,000 iterations is OWASP's PBKDF2 recommendation. For a randomly generated
32-character key it is more than needed; for a user who enters a weak password
it is the only protection, and its price is half a second a day.

---

## Restore

A restore is an operation that **deletes the data and puts something else in
its place**. It can be done from the panel and from the command line; both come
down to the same `scripts/backup.sh restore-<motor>` call, and both verify the
file **before** touching the data.

Automatic restore exists on five engines:

| Engine | From the panel | From the command line |
|---|---|---|
| MariaDB | yes | `./stack.sh restore mariadb <dosya>` |
| PostgreSQL | yes | `./stack.sh restore postgresql <dosya>` |
| MongoDB | yes | `./stack.sh restore mongodb <dosya>` |
| Redis | yes | `./stack.sh restore redis <dosya>` |
| SQL Server | yes | `./stack.sh restore mssql <dosya>` |

The other engines are backed up but have no automatic restore; the script says
so plainly ("Bu motor için otomatik geri yükleme yok" = there is no automatic
restore for this engine). The contents of the files are standard (a Cassandra
snapshot, ClickHouse `BACKUP` output, RabbitMQ definitions, a MinIO
data-directory archive) and are restored by the route in the engine's own
documentation.

### From the panel — step by step

1. **Open the backups page:** the **Backups** ("Yedekler") link in the *Tools*
   ("Araçlar") row at the top of the panel, or `https://<sunucu>/yedekler`
   directly.
2. **Find the engine's row.** To go back to the newest copy, **Restore last
   backup** ("Son yedeğe dön") is enough. If you are going back to a particular
   day, open the file list with **Show backups** ("Yedekleri göster") and use
   the **Restore this backup** ("Bu yedeğe dön") button on that date's row —
   "the last backup" is not always the wanted backup: if the operation that
   corrupted the data happened yesterday at noon, the place to go back to is
   the copy **before** it.
3. **Read the confirmation dialog.** The dialog writes plainly what will
   happen: the **existing data is deleted** on that engine, the database goes
   back to its state in the file, and everything written after that date is
   lost. The name, date, age and size of the file you are going back to are
   there too — so that you do not learn which backup you went back to after the
   job is over.
4. **Type the engine's name by hand.** The **Restore** ("Geri Yükle") button
   stays closed until it is typed correctly (case is not checked). This is the
   counterpart of the confirmation you give by typing `evet` ("evet" = yes) in
   the terminal: so that it is not an operation that can be triggered by
   pressing the wrong one of two buttons standing side by side.
5. **Watch the job pane.** The script's output streams live. Even if you close
   the pane, the job continues on the server; you also see the result in the
   panel's event feed.

On an engine that cannot be restored from the panel the button is not clickable
and says why ("Bu motorda panelden geri yükleme yok" = there is no panel
restore on this engine). It is also closed while the engine is down, or while a
backup is running at that moment; in both cases the reason is written above the
button.

The engine must be **up**: the restore tools, just like the dump tools, connect
to a running database (in Redis the data file is replaced and the engine is
restarted). Open a stopped engine from the admin panel first with **Activate**
("Aktif Et").

For those who will write automation, the endpoint the panel uses:

```
POST /api/engines/<motor>/restore
{"file": "<dosya adı>"}          →  {"job": "<iş kimliği>"}
```

(`<dosya adı>` = the file name; `<iş kimliği>` = the job id.)

The body carries the file's **name, not its path**, and the name is resolved
under `backups/<motor>/`: directory separators, `..` and symlinks that lead
outside the directory are refused, and only `.gz` is accepted. This is not
formatting fussiness — the string given to this endpoint selects the file that
will be **written over** the database.

If another backup or restore is running at that moment, the job is **deferred**
and says so plainly: the data has not been touched at all, you wait and try
again.

### From the command line

```bash
./stack.sh restore mariadb    backups/mariadb/full/mariadb_full_20260901_020000.sql.gz
./stack.sh restore postgresql backups/postgresql/full/...
./stack.sh restore mongodb    backups/mongodb/full/...
./stack.sh restore redis      backups/redis/full/...
./stack.sh restore mssql      backups/mssql/full/...
```

Every restore asks for confirmation by typing `evet`. To skip it in automation:
`ASSUME_YES=yes`.

### Verification first, deletion second

A restore starts by **deleting** the existing data. That is why the file is
opened and its contents are tested before the deletion begins; if it does not
pass, the operation never starts ("Bu dosyayla geri yükleme yapılmaz" = no
restore is done with this file). A restore started with an empty or truncated
backup does not bring the data back, it only destroys it.

On an encrypted file the same check **covers the decryption too**: if the key
is missing or wrong, the restore never starts and the data is not touched. This
order is deliberately this way, so that you do not have to look for the key
*after* the data has been deleted.

For the same reason a restore holds **the same lock** as a backup. While there
was no lock, the 02:00 cron was dumping a half-restored database (some tables
new, some DROPped), keeping it as a "valid backup" and syncing it to the
remote.

### The trap in the Redis restore

While AOF (append-only file) is on, Redis reads the AOF at startup, **not** the
`dump.rdb` file. Replacing only `dump.rdb` and restarting says "successful" but
restores nothing. The script applies the correct order:

1. Turn AOF off
2. Put the RDB in place, delete the old AOF files
3. Restart — Redis now loads from the RDB
4. Turn AOF back on and produce it from the new data with `BGREWRITEAOF`

### PostgreSQL: why there is no `ON_ERROR_STOP`

The output of `pg_dumpall --clean` also tries to drop the role and the database
you are connected to; those two errors are normal and harmless. With
`ON_ERROR_STOP=1` psql stops at exactly that point — that is, when the other
databases have already been dropped. Neither the old data nor the new one is
left in your hand. Instead the script collects the errors, filters out the
expected ones and looks at whether a real error is left over.

### SQL Server

`master` and `msdb` are backed up but not restored automatically — restoring
the system databases requires single-user mode. If the SQL logins are lost,
restore them by hand.

---

## Remote storage

Set `REMOTE_SYNC_ENABLED=true` in `.env` and configure rclone. Google Drive,
S3, Backblaze, SFTP — every target rclone supports works.
Setup: [GOOGLE-DRIVE.en.md](GOOGLE-DRIVE.en.md)

```bash
./scripts/sync-remote.sh test     # bağlantı testi
./scripts/sync-remote.sh plan     # NE gidecek, ne gitmeyecek (uzağa dokunmaz)
./scripts/sync-remote.sh          # gönder
./scripts/sync-remote.sh status   # yerel/uzak karşılaştırma
```

(The comments read: connection test · WHAT will go and what will not, it does
not touch the remote · send · local/remote comparison)

The remote retention period is set with `RETENTION_REMOTE_DAYS` (default 30
days); local retention with `RETENTION_DAYS` (default 7 days).

### The encryption gate

Remote storage is the real reason for
[backup encryption](#backup-encryption); that is why the decision to upload
depends on the encryption state:

| Encryption | What happens |
|---|---|
| **On** | Only `*.gz.enc` is sent. Unencrypted `*.gz` files are **not sent**; how many were skipped is written on the screen. |
| **Off** | The upload happens, but **a warning is printed on every run** — taking the dump out of the building unencrypted is not a job to be done silently. |
| **Broken** (a key exists, `openssl` is missing / the key file cannot be read) | **Nothing is sent.** In that state we cannot say the backups being produced are encrypted. |

Unencrypted copies taken **before** encryption was turned on never go to the
remote again. This is the correct behaviour: even the oldest unencrypted copy
sitting in the remote carries the same tables, meaning sending it would make
turning encryption on pointless. For an encrypted copy, take that engine's
backup again.

To see what will go **before** the upload, without touching the remote storage
at all:

```bash
./scripts/sync-remote.sh plan
```

`.bozuk` files are not sent in either state — they are not recovery points,
they are files that were set aside because they could not pass verification.
