# Bağlantı havuzu (PgBouncer) — 6432

***Türkçe** · [English](POOLING.en.md)*

PostgreSQL'de her bağlantı ayrı bir **süreçtir**. Bu belgenin tek cümlelik
özeti: havuz kullanmayan bir uygulama, veritabanını *bellekle* değil *süreç
sayısıyla* öldürür. `shared_buffers` ve `work_mem × max_connections` hesabı
doğru yapılmış 2 GB'lık bir PostgreSQL, 200 kısa ömürlü bağlantı açan küçük
bir uygulamanın altında "RAM yetiyor" derken cevap veremez hale gelir.

Bu yığın **6432** portunda bir PgBouncer sunar. **5432 değişmez**: doğrudan
bağlantı varsayılan yoldur, havuz isteyene açıktır.

---

## 1. Ne zaman gerekir

Havuz **gerekir** ise:

- Uygulama sunucusu her istekte yeni bağlantı açıyorsa — PHP-FPM, CGI,
  cron işleri, kısa ömürlü işçiler, "serverless" çalışan kod.
- `FATAL: sorry, too many clients already` görüyorsanız.
- Aşağıdaki sorgu yüzlerce `idle` satır döndürüyorsa:

```sql
SELECT state, count(*) FROM pg_stat_activity GROUP BY state ORDER BY 2 DESC;
```

Havuz **gerekmez** ise:

- Uygulama çerçevesi zaten havuz tutuyorsa (HikariCP, SQLAlchemy `pool_size`,
  `pgx`/`node-postgres` havuzu). Bağlantı sayısı zaten sınırlıdır; ikinci bir
  havuz katmanı fayda getirmez, yalnız bir atlama daha ekler.
- Uzun süren analitik sorgular çalıştırıyorsanız: havuz bağlantıyı *işlem*
  bitince geri alır, uzun tek işlemde kazanç yoktur.

---

## 2. 5432 ile 6432 farkı

| | **5432 — doğrudan** | **6432 — havuz** |
|---|---|---|
| Arkasında | PostgreSQL'in kendisi | PgBouncer, `pool_mode = transaction` |
| Oturum durumu | korunur | **korunmaz** (bkz. 3. bölüm) |
| Bağlantı maliyeti | bir süreç (MB'lar) | bir tampon (~8 KB) |
| Devirde | gateway tablosu otomatik güncellenir | havuz **yeniden yaratılmalı** |
| Kimler kullanmalı | psql, pgAdmin, yedekleme, replikasyon, göç araçları | çok sayıda kısa ömürlü bağlantı açan uygulamalar |

5432'yi havuza çevirmek bilerek yapılmadı: (1) replikasyon ve devir testleri
5432'den geçen yolu ölçüyor, o portu değiştirmek testin doğruladığı yolu
ürünün gerçek yolundan ayırırdı; (2) transaction pooling çalışan istemcileri
sessizce bozabilir — varsayılanı böyle bir şey olamaz.

---

## 3. Transaction pooling'in sınırları

`pool_mode = transaction`: sunucu bağlantısı **işlem bitince** havuza döner ve
bir sonraki işlemde **başka bir istemciye** gidebilir. Bu yüzden oturuma
bağlanan her şey güvenilmezdir:

- SQL düzeyinde `PREPARE` / `DEALLOCATE`
- `SET` / `RESET` ile oturum değişkenleri
- `LISTEN` / `NOTIFY`
- `WITH HOLD` cursor, oturum düzeyinde advisory lock, geçici tablolar

**Çalışan durum:** protokol düzeyinde hazırlanmış deyimler (JDBC, asyncpg,
Npgsql, `pgx`). PgBouncer 1.25.2'de `max_prepared_statements` varsayılanı
**200**'dür — çalışan havuzda `SHOW CONFIG` ile doğrulandı — yani bu sürücüler
transaction pooling'de sorunsuz çalışır.

**Sinsi olan:** tek istemciyle denediğinizde `PREPARE` + `EXECUTE` ve `SET`
"çalışıyor" görünür. Ölçüldü: havuzda başka istemci yokken aynı sunucu
bağlantısı geri verildiği için iş görür. Yük altında bu garanti **yoktur**;
bozulma ancak eşzamanlılık artınca ortaya çıkar. Oturum davranışına ihtiyaç
duyan iş 5432'ye bağlanmalıdır.

---

## 4. Havuz ayarları nereden geliyor

Ayarlar **`POSTGRES_MAX_CONNECTIONS`'tan türetilir** — sabit değildir. Kural
şudur: *havuzun sunucuda açacağı bağlantı, sunucunun kabul ettiğini aşamaz.*
Aşarsa havuz sorunu çözmez, **üretir**: `too many clients` hatasını
uygulamadan alıp kendi üstüne taşır ve artık tek arıza noktası havuzdur.

Hesabı `docker-compose.yml`deki `pgbouncer` entrypoint'i yapar. 200 örneği:

| Ayar | Formül | 200'de | Neden |
|---|---|---|---|
| `default_pool_size` | `max_connections / 4` | 50 | tek bir (rol, veritabanı) çifti payın dörtte birinden fazlasını almasın |
| `max_user_connections` | `max_connections / 2` | 100 | rol başına tavan |
| `max_db_connections` | `max_connections / 2` | 100 | veritabanı başına tavan |
| `max_client_conn` | `max_connections × 5` | 1000 | istemci ucuzdur (~8 KB), sunucu bağlantısı pahalıdır (bir süreç) |

Kalan **%50 bilerek boş bırakılır**: pgAdmin, `postgres-exporter`, yedek alan
`pg_dump` ve doğrudan 5432'ye bağlanan yönetici de bağlantı bulabilmeli.
Havuz o payı da yerse veritabanı "ayakta" görünürken panelden bakamaz, yedek
alamaz hale gelirsiniz.

PgBouncer'da **genel** bir üst sınır yoktur; yukarıdaki iki tavan birliktedir.
Bu yüzden sınır tam olarak şudur: havuzun açabileceği toplam bağlantı
`100 × min(rol sayısı, veritabanı sayısı)`. İkisinden **küçük olanı 2'yi
geçmediği sürece** toplam `max_connections`ı aşamaz. Üçten fazla rol *ve*
üçten fazla veritabanını aynı anda havuz üzerinden kullanacaksanız
`max_connections`ı büyütün (daha çok RAM = katalogdaki `per_gb` kuralı) ya da
uygulamaları tek rolde toplayın.

Tepe anında serbest sunucu bağlantısı kalmazsa istemci **reddedilmez, sıraya
alınır** (`query_wait_timeout` varsayılanı 120 sn). Havuzun bütün değeri
burada: 1000 istemci sıraya girer, veritabanı 50 süreçle çalışmaya devam eder.

---

## 5. Devirden sonra havuz YENİDEN YARATILMALIDIR

PgBouncer'ın hedefi **ana kopyadır** ve devirde ana kopya değişir
(`postgresql` → `postgresql-replica`). Hedef adres `POSTGRES_PRIMARY_HOST`
ortam değişkeninden gelir, ama **container yaratılırken** `pgbouncer.ini`'ye
yazılır: çalışan container ortam değişkenini yeniden okumaz. Devirden sonra
yeniden yaratılmazsa havuz, fence edilmiş (durdurulmuş) eski ana kopyaya
bakmaya devam eder — 6432'ye bağlanan uygulamalar için devir hiç olmamış gibi
görünür.

```bash
docker compose --profile postgresql up -d --force-recreate --no-deps pgbouncer
```

Bu, izleme ucunun (`postgres-exporter`) devirde yeniden yaratılmasıyla aynı
sınıftan bir iştir; farkı, burada etkilenenin grafikler değil **trafik**
olmasıdır.

**Karıştırmayın:** ana kopya *aynı adla* yeniden başlarsa (yeniden başlatma,
kısa kesinti) havuz kendi kendine toparlanır. Ölçüldü: arka uç durduğunda
istemciler sıraya alınır, arka uç döndükten ~15 sn sonra (`server_login_retry`)
sorgular yeniden akar. Yeniden yaratma yalnızca **adres değiştiğinde** gerekir.

---

## 6. Sağlık kontrolü ne söyler, ne söylemez

`pgbouncer` servisinin healthcheck'i `pg_isready -p 6432` çalıştırır ve
**yalnız havuz sürecini** ölçer. Ölçüldü: PostgreSQL tamamen durdurulmuşken de
`accepting connections` der, çünkü PgBouncer istemciyi kabul edip sıraya alır.
Bu bilerek böyle: motorun sağlığı zaten `postgresql` servisinin
healthcheck'inde ölçülüyor; ikinci kez ölçmek, havuz sapasağlam ayaktayken onu
"hasta" gösterip gereksiz yeniden başlatma üretirdi.

---

## 7. Doğrulama

```bash
# Havuz üzerinden gerçek sorgu
psql "postgresql://root@SUNUCU:6432/defaultdb" -c "select 1"

# Yönetim konsolu: hangi havuz kaç bağlantı tutuyor
psql "postgresql://root@SUNUCU:6432/pgbouncer" -c "SHOW POOLS;"
psql "postgresql://root@SUNUCU:6432/pgbouncer" -c "SHOW CONFIG;"

# Açılışta hesaplanan sayılar loga basılır
docker logs pgbouncer | head -20
```

---

## 8. Kubernetes'te yok

`scripts/gen-k8s.py` her motor için yalnız motorun kendi StatefulSet'ini
üretir; **PgBouncer manifestlerde yoktur**. Üretilen `postgresql` Service'inde
6432 portu görünür ama arkasında havuz olmadığı için yanıt vermez. K8s'te
havuz istiyorsanız ayrı bir Deployment + Service eklemeniz gerekir; bu yığının
havuzu Docker kurulumuna aittir.
