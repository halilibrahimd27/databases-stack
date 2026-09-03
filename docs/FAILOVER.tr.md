# Otomatik devir (failover)

***Türkçe** · [English](FAILOVER.md)*

Ana kopya çökerse sistem yedek kopyayı **kendisi** devreye alır ve
uygulamalarınızın bağlantısını oraya yönlendirir. Uygulama tarafında hiçbir
değişiklik gerekmez.

```bash
./stack.sh replica on postgresql     # 1. önce yedek kopya
./stack.sh failover on postgresql    # 2. sonra otomatik devir
```

Panelde: kartın altındaki **Replika kur** → **Otomatik devri aç**.

---

## Nasıl çalışıyor?

### Yönlendirici — bu olmadan failover işe yaramaz

Uygulamanız veritabanına **doğrudan** bağlansaydı, ana kopya öldüğünde
bağlantı adresini elle değiştirmeniz gerekirdi; yani devir "otomatik" olmazdı.
Bu yüzden tüm veritabanı portları gateway'den geçer:

```
uygulama → gateway:5432 → (o an ana kopya olan neyse)
```

Devirde yalnız gateway'in yönlendirme tablosu değişir. **Uygulamanızın
bağlantı adresi hiç değişmez.**

`nginx -s reload` mevcut bağlantıları koparmaz; eski işçi süreçler boşalana
kadar çalışmaya devam eder.

### Devir sırası

```
Ana kopya 3 kez üst üste yanıt vermiyor
        ↓
1. FENCE   — eski ana kopya DURDURULUR
        ↓
2. PROMOTE — yedek kopya ana kopya yapılır (yazmaya açılır)
        ↓
3. REROUTE — yönlendirme tablosu yeniden yazılır, nginx tazelenir
        ↓
4. KAYIT   — olay kaydedilir, webhook varsa bildirim gider
```

**1. adım atlanamaz.** Eski ana kopya çalışmaya devam ederse iki kopya da yazı
kabul eder, veriler ayrışır ve birleştirilemez (split-brain). `docker stop`
aynı zamanda yeniden başlatma politikasını da bastırır — eski kopya
kendiliğinden geri gelmez.

### Neden 3 kez üst üste?

Tek bir başarısız sağlık kontrolü geçici olabilir: anlık yük artışı, kısa bir
GC duraklaması, yavaş bir disk. Gereksiz devir gereksiz kesinti demektir.
Varsayılan `FAILOVER_STRIKES=3` ve `FAILOVER_INTERVAL=10` ile karar ~30
saniyede verilir. `.env` üzerinden değiştirilebilir.

### Yeniden başlatmaya dayanıklılık

Yükseltilmiş düğüm yeniden başlarsa, komut satırındaki yedek-kopya bayrakları
(`--read-only`, `--replicaof`) geri gelir ve tekrar salt-okunur olur.
Denetleyici bunu fark edip ana kopya rolünü yeniden uygular — yükseltme
betikleri bu yüzden **idempotent** yazılmıştır.

---

## Motor bazında

| Motor | Devir | Nasıl |
|---|---|---|
| **PostgreSQL** | ✅ denetlenen | `pg_ctl promote` — standby recovery'den çıkar |
| **MariaDB** | ✅ denetlenen | Relay log boşaltılır, `RESET SLAVE ALL`, `read_only=OFF` |
| **Redis** | ✅ denetlenen | `REPLICAOF NO ONE` |
| **MongoDB** | ✅ kendi seçimi | Replica set oy çokluğuyla seçer (arbiter dahil 3 üye) |
| Diğerleri | ✖ | Kümeleme mantıkları farklı — aşağıya bakın |

### MongoDB neden farklı?

MongoDB kendi seçimini yapar; controller müdahale etmez. Ama seçim için
**çoğunluk** gerekir: iki üyeyle biri düşünce 1/2 kalır, çoğunluk sağlanamaz
ve kalan üye `SECONDARY`de kilitlenir. Bu yüzden replika kurulduğunda üçüncü
oy olarak bir **arbiter** de eklenir (veri tutmaz, ~64 MB).

> ⚠️ P-S-A (primary + secondary + arbiter) topolojisinde secondary düşerse
> `w:"majority"` ile yapılan yazmalar bekler. Varsayılan `w:1` kullanan
> uygulamalar etkilenmez.

### Devir desteklenmeyen motorlar

- **SQL Server** — Always On AG ayrı node'lar ve cluster ister
- **Cassandra** — ana kopya kavramı yoktur, tüm node'lar eşittir
- **Elasticsearch / Kafka** — shard/partition lideri küme içinde otomatik seçilir
- **RabbitMQ** — quorum queue + cluster gerekir
- **ClickHouse** — ReplicatedMergeTree + Keeper gerekir
- **Neo4j / MinIO** — sırasıyla Enterprise ve çok diskli kurulum gerekir

---

## Devir sonrası

Devir olduğunda kartta uyarı çıkar ve olay akışına kritik bir kayıt düşer.
Eski ana kopya durmuş durumdadır. Onu yeni ana kopyanın **yedeği** olarak geri
almak için:

```bash
./stack.sh failover rebuild postgresql
```

Bu işlem **eski kopyadaki verileri siler** ve yeni ana kopyadan baştan
kopyalar. Bilinçlidir: iki kopyanın geçmişi devir anında ayrışmıştır; eskiyi
korumak tutarsızlık üretir.

Durumu görmek için:

```bash
./stack.sh failover status
./stack.sh events
```

---

## Devirden sonra dikkat edilecekler

**PostgreSQL'de sıra (sequence) numaralarında atlama olur.** Devirden sonra
`id` gibi otomatik artan alanlar bir sıçrama gösterebilir (ör. 3'ten 36'ya).
Bu bir hata değildir: PostgreSQL performans için sıra numaralarını 32'lik
bloklar hâlinde önceden ayırır ve bu ayırma WAL'a yazılmaz. Devirde
kullanılmamış blok kaybolur. Numaralar benzersiz kalır, sadece boşluk oluşur.
Uygulamanız `id`'lerin ardışık olduğunu VARSAYMAMALI.

**Yedekleme otomatik olarak yeni ana kopyayı hedefler.** Betikler container
adını sabit kullanmaz, `state/topology.json`'dan o anki ana kopyayı çözer.

## Ne kadar veri kaybedebilirim?

Replikasyon **asenkrondur**. Ana kopyanın ölmeden hemen önce yedeğe
göndermeye yetişemediği işlemler kaybolur — tipik olarak milisaniyeler,
yoğun yazma altında saniyeler.

Senkron replikasyon (sıfır kayıp) her yazmayı yedeğin de onaylamasını
bekletir; yedek yavaşlarsa ana kopya da yavaşlar. Tek makinelik bir kurulum
için bu takas genellikle doğru değildir, bu yüzden asenkron seçildi.

**Sıfır veri kaybı gerekiyorsa** yedeği ikinci bir makinede çalıştırın ve
PostgreSQL'de `synchronous_commit=remote_apply` / MariaDB'de semi-sync
replikasyonu açın.

---

## Neyi korur, neyi korumaz

**Korur:**
- Veritabanı sürecinin çökmesi, kilitlenmesi, OOM ile öldürülmesi
- Veri dosyalarının bozulması (yedek kopya sağlam kalır)
- Bir motorun bakıma alınması (`./stack.sh failover now`)

**Korumaz — dürüstçe:**
- **Host'un tamamının düşmesi.** İki kopya aynı makinededir; makine ölürse
  ikisi de ölür. Bunun için yedeği **ikinci bir makinede** çalıştırın:
  `.env` içindeki replika servisini uzak bir docker host'una yönlendirin ya da
  Kubernetes dağıtımını node anti-affinity ile kullanın.
- **Yanlışlıkla silinen veri.** Replikaya da anında yansır. Bunun çaresi
  yedektir → [BACKUP.tr.md](BACKUP.tr.md)
- **Denetleyicinin kendisi.** Controller çökerse devir yapılmaz. Küçük bir
  servistir ve `restart: unless-stopped` ile geri gelir; olayları izleyin.

---

## Test etmek

Üretime almadan önce devri **mutlaka** deneyin:

```bash
./stack.sh replica on postgresql
./stack.sh failover on postgresql

# Ana kopyayı öldür ve izle
docker stop postgresql
watch -n2 './stack.sh failover status'

# ~30 saniye içinde devir olmalı. Uygulamanız kesintiden sonra
# HİÇBİR ayar değişikliği olmadan yazmaya devam edebilmeli.
psql -h <sunucu> -p 5432 -U root -d defaultdb -c "SELECT pg_is_in_recovery();"
#  → f  (yani yazılabilir ana kopya)

# Eski kopyayı yedek olarak geri al (verisi silinip baştan kopyalanır)
./stack.sh failover rebuild postgresql

# Doğrula: replikasyon artık ters yönde akmalı
docker exec postgresql-replica psql -U root -d postgres   -c "SELECT application_name, state FROM pg_stat_replication;"
#  → walreceiver | streaming
```

Gerçek bir sunucuda ölçülen süreler (16 GB, 8 çekirdek):

| Adım | Süre |
|---|---|
| Arızanın tespiti (3 kontrol × 10 sn) | ~30 sn |
| Fence + yükseltme + yönlendirme | 1-2 sn |
| **Toplam kesinti** | **~30 sn** |
| Eski kopyayı yedek olarak geri alma | 1-2 dk (veri boyutuna bağlı) |

---

## Bildirimler

Kritik olaylar (devir, yükseltme hatası) `.env` içindeki `NOTIFY_WEBHOOK`
adresine POST edilir. Slack, Teams, Discord ve çoğu araç uyumludur:

```bash
NOTIFY_WEBHOOK=https://hooks.slack.com/services/...
```

Gönderilen gövde hem düz `text` hem yapılandırılmış `event` alanı içerir.
