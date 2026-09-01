# Yedekleme

```bash
./stack.sh backup                # aktif motorların hepsi (kapalılar atlanır)
./stack.sh backup mariadb        # tek motor
./scripts/backup.sh list         # yedekleri listele
./scripts/backup.sh stats        # boyut, adet, en son ne zaman
./scripts/backup.sh clean 7      # 7 günden eskileri sil
./scripts/backup.sh verify <dosya>
```

## Otomatik çalıştırma

`install.sh`, `state/crontab` dosyasını gerçek yollarla üretir:

```bash
crontab state/crontab
```

| Saat | İş |
|---|---|
| 02:00 | Aktif motorların tam yedeği |
| 02:30 | Uzak depoya gönderim (açıksa) |
| 03:00 | `RETENTION_DAYS`ten eski yerel yedeklerin silinmesi |
| 08:00 | İstatistik raporu |
| Pazar 04:00 | TLS sertifikası 30 günden az kaldıysa yenileme |

### Neden günde bir, 15 dakikada bir değil?

Yedekler veritabanı container'ının **içinde** alınır ve dump'ın bellek tüketimi
o container'ın kendi cgroup'una yazılır. 15 dakikada bir tam yedek MariaDB'yi
tekrar tekrar `CONSTRAINT_MEMCG` OOM ile öldürdü — container 172 kez yeniden
başladı. Günde bir tam yedek bu baskıyı ortadan kaldırır.

Daha sık kurtarma noktası gerekiyorsa dump yerine **binlog / PITR** kullanın:
MariaDB'de binlog artık açıktır (`config/mariadb/my.cnf`) ve dump'lar
`--master-data=2` ile alındığı için, yedek sonrası biriken binlog'larla
istediğiniz ana geri dönebilirsiniz.

Yedekler `nice -n 19 ionice -c3` ile çalışır — canlı veritabanı trafiği her
zaman öncelikli kalır.

## Motor başına yöntem

| Motor | Yöntem | Dosya |
|---|---|---|
| MariaDB | `mariadb-dump --all-databases --single-transaction --master-data=2` | `.sql.gz` |
| PostgreSQL | `pg_dumpall` (roller ve parolalar dahil) | `.sql.gz` |
| MongoDB | `mongodump --archive --gzip` | `.archive.gz` |
| Redis | `BGSAVE` + `dump.rdb` | `.rdb.gz` |
| SQL Server | `BACKUP DATABASE` (master ve msdb dahil) | `.tar.gz` |
| Cassandra | `nodetool flush` + `snapshot` + şema | `.tar.gz` |
| Elasticsearch | Snapshot API | `.tar.gz` |
| ClickHouse | yerel `BACKUP DATABASE` komutu | `.tar.gz` |
| RabbitMQ | `export_definitions` (mesajlar değil, tanımlar) | `.json.gz` |
| MinIO | veri dizini arşivi (nesneler değişmezdir) | `.tar.gz` |
| Neo4j | çevrimdışı dump — **kesinti gerektirir** | `.dump.gz` |
| Kafka | yedeklenmez | — |

### Neo4j

Community sürümde çevrimiçi yedek yoktur (Enterprise özelliğidir). Yedek almak
veritabanını durdurmayı gerektirir, bu yüzden `backup all` içinde otomatik
çalışmaz:

```bash
BACKUP_NEO4J_OFFLINE=true ./scripts/backup.sh neo4j
```

### Kafka

Kafka bir log'dur, veritabanı değil. Dayanıklılık yedekle değil, topic başına
`replication.factor` ve `retention.ms` ile sağlanır.

### Elasticsearch

Veri dizinini kopyalamak **tutarsız** bir yedek üretir; doğru yol snapshot
API'sidir. Bunun için `path.repo` ayarı ve ayrı bir volume gerekir — compose
dosyasında hazır tanımlıdır.

## Geri yükleme

```bash
./stack.sh restore mariadb    backups/mariadb/full/mariadb_full_20260901_020000.sql.gz
./stack.sh restore postgresql backups/postgresql/full/...
./stack.sh restore mongodb    backups/mongodb/full/...
./stack.sh restore redis      backups/redis/full/...
./stack.sh restore mssql      backups/mssql/full/...
```

Her geri yükleme `evet` yazarak onay ister. Otomasyonda atlamak için:
`ASSUME_YES=yes`.

### Redis geri yüklemesindeki tuzak

AOF (append-only file) açıkken Redis açılışta `dump.rdb` dosyasını **değil**
AOF'u okur. Sadece `dump.rdb`'yi değiştirip yeniden başlatmak "başarılı" der ama
hiçbir şey geri yüklemez. Betik doğru sırayı uygular:

1. AOF'u kapat
2. RDB'yi yerine koy, eski AOF dosyalarını sil
3. Yeniden başlat — Redis artık RDB'den yükler
4. AOF'u tekrar aç ve `BGREWRITEAOF` ile yeni veriden üret

### SQL Server

`master` ve `msdb` yedeklenir ama otomatik geri yüklenmez — sistem
veritabanlarının geri yüklenmesi tek kullanıcı modu gerektirir. SQL login'leri
kaybolduysa bunları elle geri yükleyin.

## Uzak depo

`.env` içinde `REMOTE_SYNC_ENABLED=true` yapıp rclone'u yapılandırın.
Google Drive, S3, Backblaze, SFTP — rclone'un desteklediği her hedef çalışır.
Kurulum: [GOOGLE-DRIVE.md](GOOGLE-DRIVE.md)

```bash
./scripts/sync-remote.sh test     # bağlantı testi
./scripts/sync-remote.sh          # gönder
./scripts/sync-remote.sh status   # yerel/uzak karşılaştırma
```

Uzak saklama süresi `RETENTION_REMOTE_DAYS` (varsayılan 30 gün) ile ayarlanır;
yerel saklama `RETENTION_DAYS` (varsayılan 7 gün).
