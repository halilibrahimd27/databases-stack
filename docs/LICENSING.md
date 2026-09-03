# Lisanslar

***Türkçe** · [English](LICENSING.en.md)*

> Bu sayfa bilgi amaçlıdır, hukuki tavsiye değildir. Şüphede kalırsanız hukuk
> biriminize danışın.

Bu yığın **varsayılan ayarlarıyla** üretimde ücretsiz kullanılabilir; SQL Server
dahil (Express sürümüyle gelir). **Dikkat gerektiren iki durum** vardır:

1. **`MSSQL_PID`'i `Developer` yaparsanız o kurulum üretimde kullanılamaz** —
   bu bir hukuki yükümlülüktür, teknik bir sınır değil. Varsayılan `Express`
   olduğu için bu ancak bilerek değiştirilirse geçerlidir.
2. **SSPL / AGPL lisanslı motorları üçüncü taraflara *servis olarak* sunmak**
   kaynak açma yükümlülüğü doğurabilir. Kendi uygulamanız için kullanmak
   serbesttir.

---

## Motor bazında

| Motor | Lisans | Üretimde ücretsiz? |
|---|---|---|
| **PostgreSQL** | PostgreSQL License | ✅ Kısıtlama yok |
| **MariaDB** | GPL-2.0 | ✅ Kısıtlama yok |
| **Cassandra** | Apache-2.0 | ✅ Kısıtlama yok |
| **Kafka** | Apache-2.0 | ✅ Kısıtlama yok |
| **ClickHouse** | Apache-2.0 | ✅ Kısıtlama yok |
| **RabbitMQ** | MPL-2.0 | ✅ Pratikte kısıtlama yok |
| **MongoDB** | SSPL-1.0 | ⚠️ Copyleft — aşağıya bakın |
| **Redis** | AGPL-3.0 / RSALv2 / SSPL | ⚠️ Copyleft — Valkey alternatifi var |
| **Elasticsearch** | Elastic License 2.0 / SSPL | ⚠️ Copyleft |
| **Neo4j Community** | GPL-3.0 | ⚠️ Copyleft; kümeleme Enterprise'da |
| **MinIO** | AGPL-3.0 | ⚠️ Copyleft |
| **SQL Server** | Express Edition (varsayılan) | ✅ Ücretsiz — DB başına 10 GB sınırı |

Panelde her kartın altında lisansı görürsünüz; kısıtlı olanlar işaretlenir ve
aktivasyon onayında uyarı çıkar.

```bash
./stack.sh licenses     # terminalden aynı özet
```

---

## SQL Server — hangi sürüm gelir?

Varsayılan **`MSSQL_PID=Express`**: ücretsizdir ve **üretimde kullanılabilir**.
Bu yığının hedefi minimum lisans yüküyle çalışan bir kurulum olduğu için
varsayılan bilerek Express seçildi.

Express'in sınırları:

| Sınır | Değer |
|---|---|
| Veritabanı başına veri | 10 GB |
| Tampon havuzu (buffer pool) | ~1.4 GB |
| Kullanılan çekirdek | en fazla 4 |

Bu yüzden panel SQL Server'a en fazla ~3 GB ayırır: Express bundan fazlasını
zaten kullanamaz, ayırmak diğer motorlardan çalmak olurdu.

Diğer seçenekler:

```bash
# Tüm özellikler açık, ücretsiz — ama YALNIZ geliştirme/test
MSSQL_PID=Developer

# Satın alınmış lisans
MSSQL_PID=Standard      # ya da Enterprise
```

`.env` içinde değiştirip `./stack.sh disable mssql && ./stack.sh enable mssql`.

---

## ⚠️ Copyleft motorlar — ne anlama geliyor?

**Kendi uygulamanız için kullanıyorsanız hiçbir yükümlülük doğmaz.** Şirketinizin
CRM'i PostgreSQL yerine MongoDB kullanıyor olabilir, sorun yok.

Yükümlülük, bu motoru **başkalarına yönetilen servis olarak sunduğunuzda**
doğar — "MongoDB hosting satıyorum", "arama API'si olarak Elasticsearch'ü
müşteriye açıyorum" gibi. SSPL bu durumda hizmeti çalıştıran tüm yazılım
yığınının açılmasını ister; AGPL ise değiştirdiğiniz kaynağı.

### Redis → Valkey (birebir geçiş)

Redis 7.4 ile RSALv2/SSPL'e geçti; 8.0 ile AGPL-3.0 seçeneği eklendi. Copyleft
istemiyorsanız **Valkey** Linux Foundation altında BSD-3 lisanslı bir çataldır
ve protokol/komut düzeyinde birebir uyumludur:

```bash
# .env
REDIS_IMAGE=valkey/valkey:8-alpine
```

Yığındaki her şey (RedisInsight, exporter, yedekleme, replikasyon, devir)
değişiklik gerektirmeden çalışır.

### Elasticsearch → OpenSearch (birebir değil)

OpenSearch Apache-2.0'dır ama **doğrudan yerine geçmez**: Kibana yerine
OpenSearch Dashboards gerekir ve istemci kütüphaneleri farklıdır. Geçmek
isterseniz `ELASTIC_IMAGE` ile motoru değiştirip Kibana servisini kendi
Dashboards'unuzla değiştirmeniz gerekir.

### MongoDB → FerretDB

FerretDB (Apache-2.0) MongoDB tel protokolünü PostgreSQL üzerinde konuşur.
Basit CRUD iş yüklerinde çalışır; aggregation pipeline ve transaction
desteğinde farklar vardır. Geçmeden önce kendi sorgularınızla deneyin.

### MinIO — durum tam olarak ne?

MinIO **ücretli değildir**, AGPL-3.0'dır ve öyle kalmıştır. Değişen şey:
2025'te community sürümünün web konsolundaki **yönetim özellikleri** ticari
AIStor ürününe taşındı; community konsolunda temel nesne tarayıcı kaldı.

Bu yüzden sürüm bilerek o değişiklikten **önceye sabitlendi**:

```bash
MINIO_VERSION=RELEASE.2024-10-13T13-34-11Z
```

Böylece paneldeki MinIO Console tam çalışır. Daha yeni sürüme geçmek isterseniz
sunucu tarafı sorunsuz güncellenir; yalnız konsolun yönetim ekranları kaybolur
(kova/kullanıcı yönetimini `mc` komut satırıyla yaparsınız).

> **`bitnami/minio` kullanmayın.** Bitnami de 2025'te kataloğunu ücretli
> "Bitnami Secure Images"a taşıdı; ücretsiz kalan `bitnamilegacy/*` imajları
> donduruldu ve **güvenlik yaması almıyor**. Eski bir imajı lisans kaygısıyla
> seçmek, yamasız bir imajı üretime koymak demektir — kötü bir takas.

Tamamen copyleft'siz bir S3 alternatifi isterseniz: **SeaweedFS** (Apache-2.0).

---

## Kendi imajınızı kullanmak

Her motorun imajı `<MOTOR>_IMAGE` ile tamamen değiştirilebilir. Bu üç işe yarar:

```bash
# 1. Lisans alternatifi
REDIS_IMAGE=valkey/valkey:8-alpine

# 2. Kapalı ağda kendi registry aynanız
MARIADB_IMAGE=registry.sirket.local/mariadb:11.4
POSTGRES_IMAGE=registry.sirket.local/postgres:16

# 3. Kurum içi sertleştirilmiş imaj
POSTGRES_IMAGE=registry.sirket.local/hardened/postgres:16-fips
```

Değişkenler: `MARIADB_IMAGE`, `POSTGRES_IMAGE`, `MONGO_IMAGE`, `REDIS_IMAGE`,
`MSSQL_IMAGE`, `CASSANDRA_IMAGE`, `ELASTIC_IMAGE`, `KAFKA_IMAGE`,
`RABBITMQ_IMAGE`, `CLICKHOUSE_IMAGE`, `NEO4J_IMAGE`, `MINIO_IMAGE`.

---

## Bu projenin kendi lisansı

`databases-stack` MIT lisanslıdır ([LICENSE](../LICENSE)). Proje motorları
**yeniden dağıtmaz**; Docker Hub / resmi kayıt defterlerinden çeker. Yani her
motorun lisansı doğrudan sizinle o motorun sahibi arasındadır.
