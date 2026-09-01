# Sürüm yükseltme

Bu stack'teki tüm imaj sürümleri `.env` içinde **sabitlenmiştir** (`latest` yok).
Sürpriz güncelleme gelmez; yükseltme bilinçli bir karardır.

## Neden dikkat gerekiyor?

Bir veritabanının MAJOR sürümü değiştiğinde diskteki veri biçimi de değişir.
Yeni sürüm eski veriyi tanımazsa container açılmaz — **veri kaybolmaz** ama
servis çalışmaz. `install.sh` bu yüzden mevcut volume'ları algılayıp uyumlu
sürümü otomatik sabitler:

| Motor | Mevcut veri varsa sabitlenen | Neden |
|---|---|---|
| MongoDB | `4.4` | 4.4 → 7.0 doğrudan atlanamaz (5.0 → 6.0 → 7.0 sırası gerekir) |
| PostgreSQL | `15` | major geçiş `pg_upgrade` ya da dump/restore ister |

Diğer motorlarda (MariaDB, Redis, ClickHouse, Cassandra…) aynı major içinde
yükseltme sorunsuzdur.

---

## PostgreSQL 15 → 16

En güvenli yol dump/restore. Küçük-orta veri setlerinde dakikalar sürer.

```bash
# 1. Yedek al ve DOĞRULA (yedeksiz yükseltme yapmayın)
./stack.sh backup postgresql
./scripts/backup.sh verify backups/postgresql/full/postgresql_full_*.sql.gz

# 2. Motoru durdur
./stack.sh disable postgresql

# 3. Eski veriyi kenara al (silmeyin — geri dönüş yolunuz bu)
docker volume create databases-stack_postgresql_data_v15_yedek
docker run --rm -v databases-stack_postgresql_data:/eski \
                -v databases-stack_postgresql_data_v15_yedek:/yeni \
                alpine sh -c 'cp -a /eski/. /yeni/'
docker volume rm databases-stack_postgresql_data

# 4. Sürümü yükselt ve boş bir cluster ile başlat
sed -i 's/^POSTGRES_VERSION=.*/POSTGRES_VERSION=16/' .env
./stack.sh enable postgresql

# 5. Yedeği geri yükle
./stack.sh restore postgresql backups/postgresql/full/postgresql_full_*.sql.gz
```

Sorun çıkarsa: `POSTGRES_VERSION=15` yapıp `databases-stack_postgresql_data_v15_yedek`
volume'unu `databases-stack_postgresql_data` adıyla geri kopyalayın.

---

## MongoDB 4.4 → 7.0

MongoDB ara sürümleri **atlamaya izin vermez**. Her adımda
`featureCompatibilityVersion` (FCV) yükseltilmelidir.

```bash
./stack.sh backup mongodb          # önce yedek

for v in 5.0 6.0 7.0; do
  prev=$(grep ^MONGO_VERSION= .env | cut -d= -f2)
  # Bir önceki sürümde FCV'yi yükselt
  docker exec mongodb mongosh --quiet -u root -p "$(grep ^MONGO_PASSWORD= .env | cut -d= -f2)" \
    --authenticationDatabase admin \
    --eval "db.adminCommand({setFeatureCompatibilityVersion:'${prev}', confirm:true})"
  # Sonra imajı değiştir
  sed -i "s/^MONGO_VERSION=.*/MONGO_VERSION=$v/" .env
  [ "$v" != "4.4" ] && sed -i "s/^MONGO_SHELL=.*/MONGO_SHELL=mongosh/" .env
  ./stack.sh disable mongodb && ./stack.sh enable mongodb
  sleep 30
done
```

> 4.4'te `mongosh` yoktur; ilk adımda `MONGO_SHELL=mongo` olmalıdır — `install.sh`
> mevcut veri bulursa bunu zaten ayarlar.

---

## Stack'in kendisini güncellemek

```bash
cd /opt/databases
git pull
./install.sh          # var olan .env ve parolalara DOKUNMAZ, eksikleri tamamlar
./stack.sh doctor
```

`install.sh` idempotenttir: mevcut parolaları, CA sertifikasını ve veri
volume'larını korur. Yalnız eksik olanları üretir.
