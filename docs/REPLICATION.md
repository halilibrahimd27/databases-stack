# Yedek kopya (replikasyon)

Replika, ana veritabanının sürekli güncellenen ikinci bir kopyasıdır. İki işe yarar:

- **Yedeklilik** — ana kopya bozulursa veri ikinci kopyada durur
- **Okuma ölçekleme** — raporlar/analizler replikadan okunur, ana kopya rahatlar

> ⚠️ Replika **yedeğin yerini tutmaz.** Yanlışlıkla silinen bir tablo replikaya da
> anında silinerek yansır. Replika + düzenli yedek birlikte kullanılır.

## Kurma

Panelde ilgili kartın altındaki **Replika kur**, ya da:

```bash
./stack.sh replica on postgresql
./stack.sh replica off postgresql
```

Sistem replika için de bellek bütçesini kontrol eder; yer yoksa kurmaz.

## Motor bazında

| Motor | Yöntem | Kesinti | Replika portu |
|---|---|---|---|
| **PostgreSQL** | streaming replication | yok | 5433 |
| **MariaDB** | GTID asenkron replikasyon | yok | 3307 |
| **Redis** | `replicaof` | yok | 6380 |
| **MongoDB** | replica set (rs0) | **var** | 27018 |

### PostgreSQL
Replika `pg_basebackup` ile ana kopyanın tam klonunu çeker, sonra WAL akışına
bağlanır. Replika **okunabilir** (hot standby) — raporları oraya yönlendirebilirsiniz.
Yazma denemeleri hata verir, bu beklenen davranıştır.

Kontrol: `docker exec postgresql psql -U root -c "SELECT * FROM pg_stat_replication;"`

### MariaDB
Ana kopyadan `--gtid` ile tutarlı bir dump alınıp replikaya basılır, ardından
`CHANGE MASTER ... MASTER_USE_GTID=slave_pos` ile akış başlar. GTID sayesinde
replika tam olarak doğru noktadan devam eder — veri atlanmaz veya tekrarlanmaz.

Binlog'un açık olması şarttır; `config/mariadb/my.cnf` içinde açıktır.

Kontrol: `docker exec mariadb-replica mariadb -u root -e "SHOW SLAVE STATUS\G"`
→ `Slave_IO_Running: Yes`, `Slave_SQL_Running: Yes`, `Seconds_Behind_Master: 0`

### Redis
En basiti — replika `replicaof redis 6379` ile açılır ve anında senkronize olur.
Kesinti yoktur, replika salt okunurdur.

### MongoDB — kesintiye dikkat
MongoDB'de replikasyon açmak, **ana kopyanın da** `--replSet` parametresiyle
yeniden başlatılmasını gerektirir. Bu birkaç saniyelik bir kesinti demektir.
Panel bunu onay penceresinde açıkça söyler.

Ayrıca üyeler birbirini paylaşılan bir anahtar dosyasıyla doğrular
(`state/mongo-keyfile`); `install.sh` bunu üretir ve izinlerini ayarlar.

## Kümelenerek ölçeklenen motorlar

Cassandra, Elasticsearch ve Kafka'da "primary/replica" kavramı yoktur; bunlar
node ekleyerek ölçeklenir:

- **Cassandra** — keyspace başına `replication_factor`, sonra node ekleme
- **Elasticsearch** — index başına `number_of_replicas` (tek node'da atanamaz;
  `yellow` sağlık durumu bu yüzden normaldir)
- **Kafka** — topic başına `replication.factor` (tek broker'da en fazla 1)

Bunlar için gerçek kümeleme, tek makine kapsamını aşar.

## Failover

Bu ürün **otomatik failover yapmaz** — bilinçli bir karardır. Otomatik failover
düzgün çalışmak için quorum (en az 3 node) ister; tek makinede "split-brain"
riskini artırmaktan başka işe yaramaz.

Ana kopya kaybedilirse yükseltme elle yapılır:

```bash
# PostgreSQL
docker exec postgresql-replica pg_ctl promote -D /var/lib/postgresql/data/pgdata

# MariaDB
docker exec mariadb-replica mariadb -u root -e "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=OFF;"

# Redis
docker exec redis-replica redis-cli REPLICAOF NO ONE
```
Ardından uygulamanızın bağlantı adresini replika portuna çevirin.
