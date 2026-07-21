<div align="center">

# 🗄️ databases-stack

### *Tek `docker compose up` ile MariaDB · PostgreSQL · MongoDB · Redis*

**Admin panelleri** + **Prometheus exporters** + **günlük otomatik backup** + **Google Drive sync** + **least-privilege user setup**

[![Docker](https://img.shields.io/badge/Docker-Compose-2496ed?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![MariaDB](https://img.shields.io/badge/MariaDB-11.4-003545?style=flat-square&logo=mariadb&logoColor=white)](#)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-336791?style=flat-square&logo=postgresql&logoColor=white)](#)
[![MongoDB](https://img.shields.io/badge/MongoDB-4.4-47A248?style=flat-square&logo=mongodb&logoColor=white)](#)
[![Redis](https://img.shields.io/badge/Redis-8-DC382D?style=flat-square&logo=redis&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

> **⭐ Beğendiyseniz yıldız bırakın** — bu tip self-hosted stack'ler nadir.

</div>

---

## 🎯 Niye var?

Geliştiriciler için "bir tek-makine veritabanı sunucusu" kurmanın zor tarafı 4 farklı container, 4 farklı admin panel, 4 farklı backup yöntemi, 4 farklı user-permission mantığını uyumlu kurmak. Bu repo:

- 4 popüler DB'yi tek `docker compose up` ile çalıştırır
- Her birine **web UI** (phpMyAdmin / pgAdmin / Mongo Express / RedisInsight + Adminer)
- Her birinin **Prometheus exporter**'ı kurulu, scrape edilmeye hazır
- **Günde bir tam backup** + 7 gün retention
- **Google Drive'a** rclone ile sync (offsite backup)
- **Least-privilege app user** (DROP DATABASE yasak, DELETE serbest)
- Tek **nginx dashboard** ile her şey tek pencerede

> ⚠️ **Bu bir "production database cluster" değil.** Single-machine, single-replica, dev/staging veya küçük production için. HA/multi-region için Patroni, CloudNativePG, Aurora vb. kullanın.

---

## 📦 Servisler

| Servis | Port | Image | Açıklama |
|---|---|---|---|
| **mariadb** | 3306 | `mariadb:11.4` | slow query log açık, 3G buffer pool, 1000 max_connections (ayarlar `mariadb/config/my.cnf`) |
| **postgresql** | 5432 | `postgres:15` | tuned (`shared_buffers=256M`, `max_connections=200`) |
| **mongodb** | 27017 | `mongo:4.4` | auth açık, 1GB WiredTiger cache |
| **redis** | 6379 | `redis:8-alpine` | requirepass, AOF, allkeys-lru, `maxmemory=384mb` |
| **mssql** | 1433 | `mcr.microsoft.com/mssql/server:2022` | SQL Server 2022 Developer; admin kullanıcı `sa` (root değil), yönetim Adminer'dan |
| **phpmyadmin** | 8081 | `phpmyadmin:latest` | MariaDB UI |
| **pgadmin** | 8082 | `dpage/pgadmin4:latest` | PostgreSQL UI |
| **mongo-express** | 8083 | `mongo-express:latest` | MongoDB UI |
| **redis-insight** | 8084 | `redis/redisinsight:latest` | Redis UI |
| **adminer** | 8085 | `adminer:latest` | Universal DB UI |
| **nginx-dashboard** | 80 | `nginx:alpine` | Tüm panellere link landing page |
| **mysql-exporter** | 9104 | `prom/mysqld-exporter:latest` | Prometheus metric'i |
| **postgres-exporter** | 9187 | `prometheuscommunity/postgres-exporter` | Prometheus metric'i |
| **mongodb-exporter** | 9216 | `percona/mongodb_exporter:0.40` | Prometheus metric'i |
| **redis-exporter** | 9121 | `oliver006/redis_exporter:latest` | Prometheus metric'i |

> 🪄 Cassandra opsiyonel olarak [`cassandra/`](cassandra/) altında ayrı compose'da. Ana 4 DB'ye dahil değil.

---

## 🚀 Hızlı Başlangıç

### 1. Klonla
```bash
git clone https://github.com/halilibrahimd27/databases-stack.git
cd databases-stack
```

### 2. Env dosyasını hazırla
```bash
cp .env.example .env

# Güçlü bir parola üret
echo "DB_PASSWORD=$(openssl rand -base64 32 | tr -d '+/=')" >> .env

# .env'i editörde aç ve kalan zorunlu alanları doldur
```

### 3. Stack'i ayağa kaldır
```bash
docker compose up -d
docker compose ps
```

### 4. Doğrulama
```bash
curl http://localhost/health             # nginx dashboard
docker compose logs --tail=30 mariadb
```

### 5. (Opsiyonel) App user oluştur
```bash
DB_ROOT_PASSWORD="$(grep DB_PASSWORD .env | cut -d= -f2)" \
APP_PASSWORD="$(openssl rand -base64 24)" \
  ./setup_db_users.sh all
```

### 6. (Opsiyonel) Günlük backup cron
```bash
chmod +x backup.sh
crontab crontab     # crontab dosyasını cron'a yükle (günlük 02:00 tam yedek)
```

### 7. (Opsiyonel) Google Drive sync
```bash
# rclone'u kur ve gdrive remote'unu yapılandır
curl https://rclone.org/install.sh | sudo bash
rclone config
# → New remote → name: gdrive → Storage: drive → ...

# Test
./sync_remote.sh test
./sync_remote.sh         # ilk sync
```

---

## 🔌 Erişim

| URL | Servis | Auth |
|---|---|---|
| `http://<HOST>` | Nginx Dashboard (landing) | nginx basic auth (`root` / `${DB_PASSWORD}`) |
| `http://<HOST>:8081` | phpMyAdmin | MariaDB user (`root` / `${DB_PASSWORD}`) |
| `http://<HOST>:8082` | pgAdmin | `admin@admin.com` / `${DB_PASSWORD}` |
| `http://<HOST>:8083` | Mongo Express | `root` / `${DB_PASSWORD}` |
| `http://<HOST>:8084` | RedisInsight | UI'da connection ekle |
| `http://<HOST>:8085` | Adminer | DB tipi seç + creds |

> ⚠️ **Production'da hiçbiri public açmayın.** Reverse proxy + VPN/IP whitelist arkasına alın.

---

## 💾 Backup Sistemi

`backup.sh` 1000+ satırlık production-grade script. Özellikler:

- ✅ **Lock mekanizması** — concurrent run engeller
- ✅ **Tüm DB'ler** (sadece `defaultdb` değil)
- ✅ **Per-DB single backup** opsiyonu
- ✅ **Backup integrity verification** (gzip/tar test)
- ✅ **Disk space check** (5GB altında abort)
- ✅ **Container health check**
- ✅ **Retention** (default 7 gün)
- ✅ **Restore komutları** her DB için
- ✅ **Detaylı log + colored output**

### Kullanım

```bash
./backup.sh all                  # tüm DB'leri yedekle
./backup.sh mariadb              # sadece MariaDB
./backup.sh mariadb-single mydb  # tek bir MariaDB DB'si
./backup.sh stats                # istatistik raporu
./backup.sh list                 # son yedekleri listele
./backup.sh clean 7              # 7 günden eski yedekleri sil
./backup.sh restore-postgresql /path/to/backup.sql.gz
```

### Cron (günlük tam yedek, önerilen)

> ⚠️ **Neden 15 dakikada bir değil?** Yedekler DB container'ının **içinde**
> `docker exec` (mariadb-dump / mongodump) ile alınır; dump'ın bellek tüketimi
> **DB container'ının kendi cgroup'una** yazılır. 15 dakikada bir tam yedek
> almak MariaDB'yi tekrar tekrar `CONSTRAINT_MEMCG` OOM ile öldürdü (container
> 172 kez restart etti). Günde bir tam yedek + offsite sync bu baskıyı ortadan
> kaldırır. Sık, tutarlı anlık kopya gerekiyorsa dump yerine binlog/PITR ya da
> volume snapshot gibi container dışı bir yöntem tercih edin.

`crontab` dosyasını yükle:

```bash
crontab crontab
```

Bu ekler:
- Her gün **02:00** → full backup (tüm DB'ler)
- Her gün **02:30** → Google Drive sync (yedek bittikten sonra)
- Her gün **03:00** → `backup.sh clean` ile 7 günden eski local yedekleri sil
- Her gün **08:00** → istatistik raporu

---

## ☁️ Google Drive Sync

`sync_remote.sh` — rclone ile Google Drive'a otomatik yedek.

```bash
./sync_remote.sh test     # bağlantı testi
./sync_remote.sh          # şimdi sync
./sync_remote.sh status   # local + remote stats
./sync_remote.sh cleanup  # eski uzak yedekleri sil
```

**Önkoşul:** [`GOOGLE_DRIVE_SETUP.md`](GOOGLE_DRIVE_SETUP.md) okuyun (rclone kurulum, Google Drive auth).

---

## 🔒 Least-Privilege App User

`setup_db_users.sh` — uygulamanın bağlanacağı kısıtlı kullanıcı oluşturur.

| ✅ İzin verilen | ❌ Yasak |
|---|---|
| SELECT, INSERT, UPDATE, DELETE | DROP DATABASE |
| CREATE TABLE, CREATE INDEX | DROP TABLE |
| ALTER TABLE | TRUNCATE |
| Stored procedures, functions | SUPERUSER, GRANT |
| `DEL` (Redis) | `FLUSHALL`, `FLUSHDB` |

```bash
APP_PASSWORD='$(openssl rand -base64 24)' ./setup_db_users.sh all

# Sadece tek DB
./setup_db_users.sh mariadb
./setup_db_users.sh remove   # kullanıcıyı kaldır
```

---

## 📊 Monitoring (Prometheus + Grafana)

Exporter'lar zaten kurulu — Prometheus'u stack'in dışında bir yere kurup şu target'ları scrape edin:

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'mariadb'
    static_configs:
      - targets: ['<HOST>:9104']
  - job_name: 'postgresql'
    static_configs:
      - targets: ['<HOST>:9187']
  - job_name: 'mongodb'
    static_configs:
      - targets: ['<HOST>:9216']
  - job_name: 'redis'
    static_configs:
      - targets: ['<HOST>:9121']
```

Grafana dashboard ID önerileri:
- **MariaDB:** [7362](https://grafana.com/grafana/dashboards/7362)
- **PostgreSQL:** [9628](https://grafana.com/grafana/dashboards/9628)
- **MongoDB:** [2583](https://grafana.com/grafana/dashboards/2583)
- **Redis:** [763](https://grafana.com/grafana/dashboards/763)

---

## 🛡️ Güvenlik Notları

- ✅ Tüm secret'lar `.env` üzerinden, `${VAR}` interpolasyonu (hardcoded yok)
- ✅ Container'lar resource limit'li (memory hard cap)
- ✅ Health check'li (auto-restart kötü state'te)
- ✅ App user least-privilege
- ⚠️ DB portları (3306/5432/27017/6379) **default'ta host'a expose**. Production'da:
  ```yaml
  # docker-compose.yml override
  mariadb:
    ports: []        # sadece compose network içinden
  ```
- ⚠️ Admin panel'leri auth'lu ama **VPN/whitelist** olmadan public açmayın
- ⚠️ Nginx dashboard basic-auth kullanır — production'da OAuth proxy/SSO

### Önerilen production hardening
```bash
# 1. Strong password
openssl rand -base64 32 > /tmp/dbpass
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$(cat /tmp/dbpass)/" .env
shred -u /tmp/dbpass

# 2. DB portlarını host'a açma (override.yml ile)
cat > docker-compose.override.yml <<'EOF'
services:
  mariadb: { ports: [] }
  postgresql: { ports: [] }
  mongodb: { ports: [] }
  redis: { ports: [] }
EOF

# 3. Reverse proxy + TLS
# Caddy / nginx + Let's Encrypt arkasından dashboard'a açın
```

---

## 🧮 Kaynak Gereksinimleri

Container'ların **hard memory limit** toplamı (varsayılan `.env` değerleriyle):

| Servis | Limit |
|---|---|
| MariaDB | 8G |
| PostgreSQL | 1G |
| MongoDB | 2G |
| Redis | 600M |
| Admin panelleri (5) + nginx | ~1.5G |
| Prometheus exporter'ları (4) | ~256M |
| **Toplam (tavan)** | **~13.5 GB** |

Bunlar container başına *tavan* değerlerdir; sürekli (steady-state) RSS tüketimi
genelde daha düşüktür. Asıl büyük tüketiciler MariaDB'nin 3G `innodb_buffer_pool`'u
ile MongoDB'nin 1G WiredTiger cache'idir. Tüm limitler `.env` üzerinden ayarlanabilir.

> 💽 **Dönen disk (RAID/HDD) notu:** Linux boştaki RAM'i **page cache** olarak
> kullanır ve DB dosyaları buradan okunur. Dönen disk üzerinde çalıştırıyorsanız
> limit toplamının **üstüne** page cache için bol boşluk bırakın — pratikte kutunun
> limitler + page cache + OS ile birlikte **~18-20 GB** civarında oturmasını
> planlayın (rahat bir taban için **24-32 GB RAM**'li host önerilir). Yedekler
> zaten `nice -n 19 ionice -c3` ile düşük I/O önceliğinde çalışır (bkz.
> [`backup.sh`](backup.sh)); böylece yedek dizisi doyduğunda canlı DB trafiği
> öncelikli kalır.

---

## 📁 Repo Yapısı

```
databases-stack/
├── docker-compose.yml         # Ana stack (MariaDB+PG+Mongo+Redis+UIs+exporters)
├── backup.sh                  # 1000+ satırlık backup script
├── sync_remote.sh             # Google Drive sync (rclone)
├── setup_db_users.sh          # Least-privilege app user setup
├── sc.sh                      # İlk kurulum yardımcısı (opsiyonel)
├── crontab                    # Cron jobs (günlük backup + sync)
├── .env.example               # Ortam değişkenleri şablonu
├── .gitignore
├── GOOGLE_DRIVE_SETUP.md      # Rclone setup detayı
├── mariadb/config/my.cnf      # Custom MariaDB config
├── nginx/
│   ├── nginx.conf             # Reverse proxy + auth
│   └── html/index.html        # Dashboard landing
└── cassandra/                 # Opsiyonel: Cassandra alt-stack
    ├── docker-compose.yml
    ├── backup.sh
    ├── setup_users.sh
    └── ...
```

---

## 🆘 Sorun Giderme

### Container ayağa kalkıyor ama bağlanamıyorum
```bash
docker compose ps
docker compose logs <SERVICE> --tail=50
docker exec <CONTAINER> printenv | grep -i pass
```

### "DB_PASSWORD not set" hatası
`.env` dosyasında `DB_PASSWORD=` doldurulmamış. Düzelt + `docker compose down && up -d`.

### Backup script hemen çıkıyor ("Another backup is already running")
Kilit artık **flock** ile yönetiliyor: kilit yalnızca çalışan sürece bağlıdır ve
süreç ölünce çekirdek tarafından otomatik bırakılır — bayat kilit diye bir şey
kalmadı. Bu mesajı görüyorsanız gerçekten başka bir çalışma vardır:
```bash
pgrep -af 'backup.sh|sync_remote.sh'   # gerçekten çalışan var mı?
```
Lock dosyasını (`/tmp/db_backup.lock`) **elle silmeyin** — flock ile ne gerekli
ne de güvenlidir (boş dosya bile canlı bir kilidi temsil edebilir).

### Google Drive sync auth fail
```bash
rclone config reconnect gdrive:
./sync_remote.sh test
```

### MongoDB Express login loop
Mongo Express bazen ilk start'ta sorun çıkarır:
```bash
docker compose restart mongodb
sleep 30
docker compose restart mongo-express
```

### pgAdmin "could not connect to server"
pgAdmin container'ını ilk açtığında PostgreSQL henüz hazır olmayabilir. Server config'i UI'da elle ekleyin:
- Host: `postgresql`
- Port: `5432`
- Username: `root`
- Password: `${DB_PASSWORD}`

---

## 📜 Lisans

MIT — `LICENSE` dosyasına bakın.

---

<div align="center">

## 🌟 Destek olmak istersen

| Süre | Yardım |
|---|---|
| 5 sn | **⭐ Star** |
| 30 sn | Twitter/LinkedIn'de paylaş |
| 5 dk | Issue aç (eksik bulduğun şey) |
| 2 saat | Yeni DB ekle (Cassandra benzeri alt-stack) |

[![Star History Chart](https://api.star-history.com/svg?repos=halilibrahimd27/databases-stack&type=Date)](https://star-history.com/#halilibrahimd27/databases-stack&Date)

</div>
