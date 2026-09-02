# Zamanda bir ana dönme (PITR)

Gecelik yedekle yapılabilecek en iyi şey **"dünkü yedeğe dön"**dür. Oysa
istenen neredeyse hiçbir zaman bu değildir: veriyi bozan `UPDATE` dün 14:33'te
koştuysa **14:32'ye** dönmek gerekir. Aradaki fark bir günlük iştir.

Tam yedek + o andan sonraki **değişiklik günlüğü** bu farkı kapatır.
PostgreSQL'de bu günlük WAL, MariaDB'de binlog'dur.

```
./scripts/pitr.sh durum
./scripts/pitr.sh don postgresql "2026-09-01 14:32:00" --prova
```

---

## Kapsam — ve neden yalnız iki motor

| Motor | PITR | Neden |
|---|---|---|
| **postgresql** | ✅ | WAL arşivleniyor (`archive_mode`, docker-compose.yml) |
| **mariadb** | ✅ | binlog zaten açık (config/mariadb/my.cnf) |
| mongodb | ❌ | oplog ile teknik olarak **mümkün** (replica set şart, oplog penceresi kadar geriye) ama **bu turda yapılmadı** |
| redis | ❌ | AOF yalnız komut akışıdır; olaylarda zaman damgası yoktur, "14:32'ye dön" ifade edilemez |
| mssql | ❌ | işlem günlüğü yedeği (LOG backup) gerekir; bu yığın yalnız FULL yedek alıyor |
| diğerleri | ❌ | zaman damgalı bir değişiklik günlüğü yığında tutulmuyor |

MongoDB satırı bilerek "mümkün ama yapılmadı" diye yazıldı. "Yapılabilir" ile
"yapıldı ve ölçüldü" arasındaki farkı gizlemek, felaket günü öğrenilecek en
pahalı şeydir.

---

## PITR'ın iki parçası: TABAN ve ARŞİV

Bu belgede tekrar tekrar geçecek olan tek kural şudur:

> **Değişiklik günlüğü tek başına veri değildir.** WAL de binlog da bir
> **tabanın üzerine** oynatılır. Taban yoksa dönülebilir aralık da yoktur.

### PostgreSQL tabanı neden `backup.sh`'ın yedeği DEĞİL

`backup.sh` PostgreSQL'i `pg_dumpall` ile yedekler — bu **mantıksal** bir
yedektir, yani SQL cümleleridir. WAL ise **blok düzeyi** değişikliklerdir.
Birinin üzerine diğeri oynatılamaz: LSN'ler, blok düzenleri ve dosya
düğümleri tutmaz. Bu yüzden PITR'ın kendi tabanı var:

```
./scripts/pitr.sh taban postgresql     # pg_basebackup — FİZİKSEL kopya
```

→ `backups/postgresql/taban/postgresql_taban_<tarih>.tar.gz` (+ `.meta`)

### MariaDB tabanı gecelik yedek OLABİLİR

MariaDB'de binlog da mantıksal düzeydedir (satır/ifade olayları), yani dump
ile aynı dili konuşur. Şart olan tek şey, dump'ın **hangi binlog
konumundan** sonrasını temsil ettiğinin dosyada yazılı olmasıdır; bunu
`mariadb-dump --master-data=2` yapar ve `backup.sh` zaten o bayrakla dump
alıyor. Bu yüzden `pitr.sh` aday tabanları **iki yerden** toplar:

* `backups/mariadb/taban/` — `pitr.sh taban mariadb`'nin ürettikleri
* `backups/mariadb/full/` — `backup.sh`'ın gecelik yedekleri

İkincisi bilerek: her gün ayrıca bir dump daha almak, `backup.sh`'ın başında
anlatılan OOM olayını (aynı container'da ikinci bir ağır iş) geri getirirdi.
Ama **bağımlılık yok**: konum satırını taşımayan bir dosya aday listesine
hiç girmez, sessizce "taban var" sayılmaz.

---

## Kurulum

Compose'a PITR ayarları eklendi. `archive_mode` **yeniden başlatma ister**,
reload yetmez:

```bash
docker compose up -d postgresql mariadb   # container'lar yeniden yaratılır
./scripts/pitr.sh kur postgresql
./scripts/pitr.sh kur mariadb
./scripts/pitr.sh taban postgresql
./scripts/pitr.sh taban mariadb
./scripts/pitr.sh durum
```

`kur` komutunun asıl işi **izinleri ölçmektir**. Arşiv dizini host'ta durur
ama container'ın kullanıcısı (postgres = uid 999, mysql = uid 999) oraya
yazar. Dizin yoksa docker onu **root:root** olarak yaratır ve
`archive_command` her segmentte "Permission denied" der. Bunun kötü tarafı
gürültülü olması değil, **sessiz** olmasıdır: PostgreSQL yeniden dener,
`pg_wal` büyür, arıza ancak veri diski dolduğunda görünür. `kur`, motorun
kendi kullanıcısıyla bir dosya oluşturup silerek bunu **söz olarak değil
ölçüm olarak** doğrular.

### Neler değişti

**docker-compose.yml → postgresql**

```yaml
volumes:
  - ${STACK_DIR:-.}/backups/postgresql/wal:/wal-archive
  - ${STACK_DIR:-.}/config/postgresql:/etc/pitr:ro
environment:
  PG_WAL_ARSIV: /wal-archive
command:
  - -c
  - archive_mode=${POSTGRES_ARCHIVE_MODE:-on}
  - -c
  - archive_command=sh /etc/pitr/wal-archive.sh %p %f
  - -c
  - archive_timeout=${POSTGRES_ARCHIVE_TIMEOUT:-300}
```

`wal_level` **değiştirilmedi**: `replica` PITR için yeterlidir (`logical`
daha fazlasını yazar ve diski boşuna şişirir). Eksik olan tek şey
arşivlemeydi — `replica` seviyesi WAL'ı üretir ama `pg_wal` dolunca geri
dönüştürür; yani "dün 14:32" o segment geri dönüştürüldüğü anda ulaşılamaz
olur.

**docker-compose.yml → mariadb**

```yaml
volumes:
  - ${STACK_DIR:-.}/backups/mariadb/binlog:/binlog-archive
```

Binlog'un **yeri değişmedi**; buraya bir **kopya** çıkarılıyor. Sebebi
aşağıda.

---

## Arşiv nerede durur, ne kadar durur

| | Yer | Kim yazar |
|---|---|---|
| PostgreSQL WAL | `backups/postgresql/wal/` | motor, `archive_command` ile sürekli |
| PostgreSQL taban | `backups/postgresql/taban/` | `pitr.sh taban postgresql` |
| MariaDB binlog (asıl) | `mariadb_data` hacmi, `/var/lib/mysql/mysql-bin.*` | motor |
| MariaDB binlog (kopya) | `backups/mariadb/binlog/` | `pitr.sh arsivle mariadb` |
| MariaDB taban | `backups/mariadb/taban/` + `backups/mariadb/full/` | `pitr.sh taban` / `backup.sh` |

Arşiv **yedeklerin altında**, ayrı bir kökte değil. Ayrı bir yer seçseydik
iki şey bozulurdu: `backup.sh stats` disk uyarısı arşivi saymazdı ve
`sync-remote.sh` uzağa yalnız yedekleri gönderirdi — felaket günü tam yedek
uzakta, PITR arşivi ölen sunucuda kalırdı.

### MariaDB binlog'unun yeri neden DEĞİŞTİRİLMEDİ

`log_bin` yolunu `/binlog-archive`e taşımak cazip görünüyor ama yıkıcı:
MariaDB hangi binlog'ların var olduğunu `mysql-bin.index` dosyasından bilir
ve `PURGE`'ü ona göre yapar. Yol değişince **yeni bir index açılır**, eski
dizinde kalan dosyalar bir daha hiç silinmez ve
`binlog_expire_logs_seconds` onları artık görmez. Sessizce dolan bir veri
hacmi, çözmeye çalıştığımız sorunun daha kötüsü olurdu.

Kopya ise host'ta durur: motorun hacmi ölse bile binlog elde kalır.

### Saklama — "aynı gün sayısı" tek başına yetmez

```bash
./scripts/pitr.sh temizle          # varsayılan: PITR_RETENTION_DAYS (= RETENTION_DAYS)
./scripts/pitr.sh temizle 14
```

`PITR_RETENTION_DAYS` varsayılan olarak `RETENTION_DAYS`'e eşittir; ayrışırsa
`pitr.sh durum` bunu **uyarı** olarak gösterir. Arşiv daha uzunsa disk
sessizce dolar; kısaysa elinizdeki yedeklerin bir kısmından ileri gidilemez.

Ama asıl mesele gün sayısı değil: **yaşa bakan düz bir silme, saklanan bir
tabanın ihtiyaç duyduğu WAL'ı da siler.** `backup.sh clean` her motorda en
yeni 3 kopyayı **yaşı ne olursa olsun** korur (kapalı bir motorun son
kurtarma noktası yok olmasın diye). O kural yüzünden 30 günlük bir taban elde
kalabilir; WAL'ını 7 günde silersek elimizde **açılamayan** bir taban kalır
ve kimse fark etmez.

Bu yüzden `temizle` iki ölçütü **birlikte** uygular:

1. yaş > `PITR_RETENTION_DAYS`, **ve**
2. dosya, saklanan **en eski tabanın** gerektirdiği zamandan da eski
   (taban dosyasının mtime'ı yedeğin *bitişidir*, gereken WAL ise
   *başlangıcından* itibarendir — aradaki fark `PITR_KORUMA_TAMPON`,
   varsayılan 4 saat)

`*.history` dosyaları **yaş ne olursa olsun** kalır. Birkaç yüz bayttır ama
kurtarma, hangi zaman çizgisinin nereden ayrıldığını yalnız oradan okur;
silinirse `latest` çizgiyi izleyen her kurtarma eski çizgide takılır ve bunu
hiçbir hata mesajı söylemez.

**Taban dosyalarını `temizle` SİLMEZ.** Onlar `backups/<motor>/taban/`
altında ve `backup.sh clean` oraya da bakıyor (`find` özyinelemeli, `*.gz`
deseni hem `tar.gz`'yi hem `sql.gz`'yi kapsıyor). İki sahibi olan bir
politika, hiç sahibi olmayandan beterdir.

---

## Dönülebilir aralık nasıl hesaplanıyor

```
./scripts/pitr.sh durum
./scripts/pitr.sh durum postgresql --json     # controller / panel için
```

### PostgreSQL

* **En eski** = en eski taban yedeğinin **bittiği an** (`.meta` →
  `bitis_epoch`). Ondan öncesine dönmek imkânsızdır.
* **En yeni** = arşive **düşmüş** son segmentin arşivlenme anı (dosyanın
  mtime'ı). Sunucuda o andan sonra üretilmiş WAL da vardır ama o henüz
  `pg_wal`dadır; ölen bir sunucuda ona ulaşılamaz, dolayısıyla
  "dönülebilir" saymak yalan olurdu.
* Dosya mtime'ı kullanılıyor çünkü **sunucu kapalıyken de okunur** — ve
  PITR'a en çok sunucu kapalıyken bakılır.
* Arşivde **boşluk** varsa en yeni, boşluktan önceki son segmentin zamanına
  çekilir ve sebebi yazılır. Boşluk, segment adlarının ardışıklığından
  bulunur (24 hex = 8 zaman çizgisi + 8 log kimliği + 8 sıra; log kimliği
  başına segment sayısı = 2³² / `wal_segment_size`). Zaman çizgileri ayrı
  ayrı değerlendirilir, yoksa her PITR'dan sonra yanlış alarm üretirdi.

### MariaDB

* **En eski** = binlog'u **hâlâ duran** en eski tabanın alındığı an. Tabanın
  işaret ettiği binlog `PURGE` edilmişse o tabandan ileri gidilemez; o taban
  aralığa dahil edilmez ve `durum` kaç tabanın bu yüzden kullanılamaz
  olduğunu ayrıca yazar.
* **En yeni** = **şu an**. MariaDB'de binlog yerel bir dosyadır ve her commit
  anında yazılır; PostgreSQL'deki gibi bir "arşive düşme gecikmesi" yoktur.
  Sunucu kapalıysa bu doğru olmaz — o hâlde host arşivindeki en yeni
  binlog'un zamanı kullanılır ve **sebep yazılır**.

### Aralığın üst sınırını ileri itmek

```bash
./scripts/pitr.sh arsivle postgresql   # pg_switch_wal + arşive düştüğünü DOĞRULA
./scripts/pitr.sh arsivle mariadb      # FLUSH BINARY LOGS + host'a kopyala
```

PostgreSQL'de segment **dolmadan** arşive düşmez. `archive_timeout=300`
yazı olmuşsa segmenti 5 dakikada bir zorla kapatır — yani **RPO'nun üst
sınırı budur**. Bedeli: yazı olan her 5 dakikada bir, yarısı boş olsa da tam
boyutlu (16 MB) bir segment arşive düşer. Boştaki bir sunucuda bu hiç olmaz
(PostgreSQL yazı yoksa segment değiştirmez), yani sabit bir disk maliyeti
değil.

---

## Geri dönüş

```bash
# 1) ÖNCE PROVA — üretime dokunmaz
./scripts/pitr.sh don postgresql "2026-09-01 14:32:00" --prova \
    --dogrula "SELECT count(*) FROM siparisler WHERE tutar < 0"

# 2) sonuç doğruysa üretime
./scripts/pitr.sh don postgresql "2026-09-01 14:32:00"
```

### Üç güvenlik kapısı

**1. `--prova`.** Kurtarma tek kullanımlık bir container ve hacimde,
`--network none` ile yapılır; üretim container'ına, gateway'e ya da yığın
ağına giden bir yol **yoktur**. Arşiv **salt okunur** bağlanır: provanın
arşivi kirletmesi teknik olarak imkânsızdır. Bu, "dokunmuyoruz" sözünü
niyete değil çekirdeğe bağlar (`restore-drill.sh` ile aynı sözleşme).

`--dogrula` kurtarılan kopyaya **kendi sorgunuzu** sorar ve cevabını JSON'a
koyar. Neden var: "kurtarma başarıyla bitti" cümlesi istenen verinin
geldiğini kanıtlamaz. Üretimde uygulamadan önce sorulacak tek doğru soru,
"o satır orada mı, sonraki satır orada **değil** mi" sorusudur.

**2. Güvenlik yedeği.** Üretimde `don`, yıkıcı adıma geçmeden önce mevcut
hâlin tam bir kopyasını alır (PostgreSQL'de `pg_basebackup`, MariaDB'de
`mariadb-dump`). Yanlış ana dönmek de bir arızadır ve geri alınabilmelidir.
Güvenlik yedeği alınamazsa **hiçbir şey yapılmaz**.

**3. Aralık kapısı.** Hedef aralığın dışındaysa iş **reddedilir** (çıkış 2)
ve gerekçe sayılarla yazılır:

```
[✗] Hedef aralığın ÖNCESİNDE: istenen 2026-09-02 10:00:00 +0300 ·
    en eski dönülebilir an 2026-09-02 17:52:49 +0300
    (bunu en eski taban yedeği belirliyor). Daha geriye gitmek için
    o tarihi kapsayan bir taban gerekir; elde yok.
```

"Aralık dışında" tek başına kullanıcıyı ekranın karşısında bırakır: ne kadar
geriye gidilebildiğini ve o sınırı **neyin** koyduğunu bilmeden ne yapacağına
karar veremez. Sessizce "en yakın ana" dönmek ise ona olmayan bir veriyi var
sanmasını öğretirdi.

### Saat dilimi — sessiz üç saat

Hedef zaman **yerel saatle** verilir. `pitr.sh` onu motora **açık saat
dilimiyle** geçirir:

* PostgreSQL: `recovery_target_time = '2026-09-01 14:32:00+0300'`
* MariaDB: `mariadb-binlog` `TZ=UTC` ile çağrılır, hedef UTC yazılır

Dilim yazılmasaydı sunucunun kendi ayarına göre yorumlanırdı; container UTC,
host Europe/Istanbul iken bu **sessizce üç saatlik** bir kaymadır ve geri
gelen veri "yaklaşık doğru" göründüğü için kimse fark etmez.

### İki motor arasındaki bir fark

* PostgreSQL: `recovery_target_inclusive = on` → hedef an **dahildir**.
* MariaDB: `--stop-datetime`, damgası hedefe **eşit ya da büyük** ilk olayda
  durur → hedef an **dahil değildir**.

Saniye altı hassasiyet gerekiyorsa MariaDB'de hedefi bir saniye ileri alın;
binlog olaylarının damgası zaten saniye çözünürlüğündedir.

### Üretime döndükten sonra

```
[!] Varsa REPLİKALAR artık uyumsuz — ./stack.sh replica off/on ile yeniden kurun.
[!] Yeni bir PITR tabanı alın: ./scripts/pitr.sh taban <motor>
```

PostgreSQL'de kurtarma **yeni bir zaman çizgisi** başlatır; replikalar eski
çizgideki verinin peşindedir. MariaDB'de binlog oynatma sırasında
`gtid_strict_mode` geçici olarak kapatılır (eski GTID'leri yeniden yazmak
katı kipte "out-of-order sequence number" hatasıdır) ve **her çıkış
yolunda** — hata, zaman aşımı, Ctrl+C dahil — geri konur. Geri konamazsa
betik bunu ekrana yazar.

---

## Çıkış kodları

| Kod | Anlamı |
|---|---|
| 0 | iş tamam |
| 1 | **başarısız** — iş denendi, olmadı |
| 2 | **reddedildi** — hedef aralık dışında ya da onay verilmedi. **Yıkıcı hiçbir iş yapılmadı**; bu kod "veriniz yerinde" demektir |
| 3 | **kapsam dışı / ölçülemedi** — motor PITR desteklemiyor, docker yok, kilit başkasında. İş hiç *denenemedi* |
| 4 | iş bitti ama geçici container/hacim **sızdı** |

2 ile 1'in ayrı olması bilerek: "reddedildi" bir arıza değil, güvenlik
kapısının çalıştığının kanıtıdır. Panel ikisini aynı renkte gösterirse
kullanıcı gerçek arızayı görmeyi bırakır.

`don` ve `durum --json` **son satırda tek satır JSON** basar:

```json
{"komut":"don","engine":"postgresql","target":"2026-09-01T14:32:00+0300",
 "mode":"prova","ok":true,"seconds":37,"base":"…/postgresql_taban_….tar.gz",
 "stopped_at":"LOG: recovery stopping before commit of transaction 734, …",
 "verify":"A","cleanup":true,"detail":"PROVA GEÇTİ: …"}
```

`stopped_at` **motorun kendi cümlesidir**, bizim yorumumuz değil.
Kurtarmanın nerede durduğunu ondan başka kimse bilmiyor.

---

## Nasıl ölçüldü

`scripts/e2e/pitr.sh`. Ölçtüğü asıl şey tek cümledir:

> T1'de A satırı yazılır · T2'de B satırı yazılır ·
> T1 ile T2 **arasına** dönülür → kopyada **A var, B yok**.

```bash
./scripts/e2e/pitr.sh                 # postgresql + mariadb
./scripts/e2e/pitr.sh mariadb
```

Neden bu cümle: tek bir satır saymak yetmez. Taban yedeğini olduğu gibi açıp
değişiklik günlüğünü hiç oynatmayan bir kurtarma da "başarılı" görünür;
hedefi aşan bir kurtarma da. İki satırın biri **varken** diğeri **yoksa**,
hem tabanın üzerine günlüğün oynatıldığı hem de **doğru yerde durulduğu**
aynı anda kanıtlanır.

Paket ayrıca şunları ölçer: aralık dışına (hem geleceğe hem çok geriye)
dönme denemesinin çıkış 2 ile reddedilmesi; prova ve reddedilen denemeler
sonrasında üretimde hâlâ `A,B` bulunması (yani "dokunmadık" iddiasının
ölçülmesi); arşiv temizliğinin saklama süresine uyması **ve** saklanan bir
tabanın gerektirdiği segmente dokunmaması.

Ölçülemeyen her şey `t_unknown`'dır ve `scripts/e2e/lib.sh` onu
**başarısız sayar** — "bilmiyorum" ile "iyi" aynı şey değildir.

Bu paket **yıkıcı değildir**: kurtarma yalnız `--prova` ile yapılır, üretimde
yalnız kendi test tablosu (`e2e_pitr`) oluşturulup sonunda düşürülür.

---

## Zamanlanmış görevler

`scripts/crontab.template` tam yedeği ve temizliği zamanlıyor. PITR için
şunlar eklenebilir (yollar `install.sh`'ın ürettiği `state/crontab`
biçiminde):

```cron
# Haftada bir PITR tabanı — pencerenin alt sınırını taze tutar.
# Gecelik tam yedekten SONRA: ikisi aynı kilidi paylaşır ve çakışırlarsa
# ikincisi "kilit başkasında" deyip çıkar.
30 3 * * 0 /yol/scripts/pitr.sh taban postgresql >> /yol/logs/cron_pitr.log 2>&1
40 3 * * 0 /yol/scripts/pitr.sh taban mariadb    >> /yol/logs/cron_pitr.log 2>&1

# Saatte bir binlog kopyası — motorun hacmi ölse bile binlog host'ta kalsın.
15 * * * * /yol/scripts/pitr.sh arsivle mariadb  >> /yol/logs/cron_pitr.log 2>&1

# Arşiv temizliği, yedek temizliğinin hemen ardından.
10 3 * * * /yol/scripts/pitr.sh temizle          >> /yol/logs/cron_pitr.log 2>&1
```

PostgreSQL WAL arşivi için zamanlanmış bir işe gerek yok: `archive_command`
sürekli çalışır.

---

## Ayarlar

| Değişken | Varsayılan | Ne yapar |
|---|---|---|
| `POSTGRES_ARCHIVE_MODE` | `on` | WAL arşivleme. `off` PITR'ı bitirir — ama arşive yazamayan bir kurulumda `pg_wal`ın veri diskini doldurmasından iyidir; bu kaçış yolu bilerek var |
| `POSTGRES_ARCHIVE_TIMEOUT` | `300` | Yazı olmuşsa segmenti kaç saniyede bir zorla kapat (= RPO üst sınırı) |
| `PITR_RETENTION_DAYS` | `RETENTION_DAYS` | Arşiv saklama süresi |
| `PITR_KORUMA_TAMPON` | `14400` | En eski tabanın gerektirdiği WAL için güvenlik payı (sn) |
| `PITR_ZAMAN_CIZGISI` | `latest` | `recovery_target_timeline`. `latest` üst üste PITR yapılabilmesi için gerekli |
| `PITR_KURTARMA_SURESI` | `1800` | Kurtarmanın tamamlanması için üst sınır (sn) |
| `PROVA_MEM_MB` | `1024` | Geçici kopyanın bellek tavanı |
| `PITR_DOGRULA_DB` | `DEFAULT_DATABASE` | `--dogrula` sorgusunun koşacağı veritabanı (PostgreSQL) |
| `ASSUME_YES=yes` | — | Üretim `don` için onay sorma (otomasyon) |

---

## Sık karşılaşılanlar

**`durum` "archive_mode KAPALI" diyor ama compose'da `on` yazıyor.**
`archive_mode` yeniden başlatma ister, reload yetmez. `docker compose up -d
postgresql` ile container'ı yeniden yaratın. `durum` compose'daki değere
değil **çalışan sunucuya** sorar; aradaki fark tam olarak budur.

**`durum` "arşivleme N kez başarısız oldu" diyor.**
Neredeyse her zaman izin: arşiv dizini docker tarafından root olarak
yaratılmıştır. `./scripts/pitr.sh kur postgresql`. Bu uyarıyı ciddiye alın —
PostgreSQL arşivlenemeyen segmenti serbest bırakmaz, `pg_wal` büyür ve
sonunda sunucu PANIC ile durur.

**`don` "İSTENEN ANA ULAŞAMADI, arşivin ulaştığı son işlem X" diyor,
oysa hedef aralığın içindeydi.**
En sık sebep eksik segment değil, **sessiz bir veritabanıdır**. Hedefle son
işlem arasında hiç yazı olmadıysa o aralıkta WAL kaydı da yoktur ve
PostgreSQL hedefi reddeder. Mesajdaki `X` anını (ya da öncesini) hedef alın.
Ölçümde bu birebir görüldü: son işlem 17:53:14, hedef 17:55:00, arada tek
yazı yok → `FATAL: recovery ended before configured recovery target was
reached`.

**`don` "KURTARMA KOMUTU ÇALIŞTIRILAMADI" diyor.**
`/etc/pitr` bağlaması yok — container PITR ayarları eklendikten sonra
yeniden yaratılmamış. `docker compose up -d postgresql`. Bu mesaj ayrı
tutuluyor çünkü PostgreSQL'in günlüğe yazdığı cümle yukarıdakiyle **birebir
aynıdır**; suçu arşive atan bir mesaj, operatörü var olmayan bir eksik
segmenti aramaya gönderirdi.

**`don` "Yedekleme kilidi başkasında" deyip çıkış 3 veriyor.**
`backup.sh`, `restore-drill.sh` ve `pitr.sh` **aynı kilidi** paylaşır: tek
sunucuda iki ağır iş aynı cgroup'u zorlar ve temizlik turu, okuduğumuz
dosyayı ayağımızın altından çekebilir. Çıkış 3 "kurtarma başarısız" değil,
"kurtarma **denenmedi**" demektir.
