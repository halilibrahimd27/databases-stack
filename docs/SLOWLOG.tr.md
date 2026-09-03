# Yavaş sorgu ölçümü

***Türkçe** · [English](SLOWLOG.md)*

"Veritabanım yavaş" cümlesinin cevabı neredeyse her zaman ölçülebilir bir
yerde durur: motor, hangi sorguya ne kadar zaman harcadığını **zaten
sayıyor**. Eksik olan tek şey o sayacın açılması ve okunabilir hâle
getirilmesidir. `scripts/slowlog.sh` bunu yapar.

```bash
./scripts/slowlog.sh kur postgresql      # ölçümü aç (kalıcı ayar)
./scripts/slowlog.sh durum               # en pahalı ilk N sorgu
./scripts/slowlog.sh oneri postgresql    # indeks/ayar önerileri
./scripts/slowlog.sh sifirla postgresql  # sayaçları sıfırla
```

---

## Sıralama neden TOPLAM süreye göre

Bu, aracın en önemli kararı. İnsanlar yavaşlık ararken içgüdüsel olarak
**ortalamaya** bakar ve yanılır:

> 0.5 ms süren ama saniyede 2000 kez çağrılan bir sorgu, sunucudan saniyede
> **1000 ms** alır. 3 saniye süren ama günde bir koşan bir rapor günde
> **3000 ms** alır. Birincisi üç saniyede ikincisinin **günlük** maliyetini
> geçer.

Ortalamaya göre sıralayan bir liste birinciyi hiç göstermez — ve sunucuyu
gerçekten dolduran odur. Bu yüzden hem ekran hem JSON toplam süreye göre
sıralıdır; *ortalama* sütunu yalnızca "tek koşum ne kadar sürüyor" sorusu
için vardır.

Bu karar tahmin değil, **ölçülmüş**. `scripts/e2e/slowlog.sh` bilerek ters
düşen iki sorgu koşturur ve listedeki sıralarına bakar. Gerçek bir koşumdan:

| sorgu | çağrı | toplam | ortalama | listedeki sıra |
|---|---|---|---|---|
| `sik`   | 400 | **56.7 ms** | 0.142 ms | **2** |
| `nadir` |   2 | 14.2 ms | **7.123 ms** | 3 |

Ortalamaya göre sıralansaydı `nadir` 50 kat üstte çıkardı. Oysa sunucunun
CPU'sundan `sik` **4 kat fazlasını** almış. Liste doğru olanı gösteriyor.

---

## Ölçüm kapalıysa boş liste basılmaz

Ölçüm açık değilken bu betik **çıkış kodu 4** ile durur ve ölçümü açan
komutu ekrana yazar.

Sebep somut: boş bir liste "yavaş sorgun yok" diye okunur. Ölçüm hiç
yapılmamışken bunu söylemek, bu aracın verebileceği en pahalı yanlış
cevaptır — kullanıcı asıl sorunu bambaşka bir yerde aramaya gider.

```
[!] ÖLÇÜM KAPALI — postgresql
[!]   pg_stat_statements ÖN YÜKLÜ DEĞİL — PostgreSQL hiçbir sorgunun
      süresini saymıyor.
[bilgi]   Açmak için:  ./scripts/slowlog.sh kur postgresql
```

---

## Kapsam — ve neden yalnız iki motor

| Motor | Ölçüm | Kaynak |
|---|---|---|
| **postgresql** | ✅ | `pg_stat_statements` |
| **mariadb** | ✅ | `performance_schema` digest'i, yoksa yavaş sorgu günlüğü |
| mongodb | ❌ | profiler ile **mümkün**, bu turda **yapılmadı** |
| mssql | ❌ | Query Store ile **mümkün**, bu turda **yapılmadı** |
| elasticsearch | ❌ | kendi slow log'u var; ayrı bir biçim, ayrı bir yorum |
| diğerleri | ❌ | sorgu başına süre biriktiren bir sayaç yığında yok |

Kapsam dışı motorda çıkış kodu **2**'dir; hata (1) ve ölçülemedi (3)
kodlarıyla karışmaz.

"Mümkün ama yapılmadı" satırları bilerek böyle yazıldı: "yapılabilir" ile
"yapıldı ve ölçüldü" arasındaki farkı gizlemek, ihtiyaç duyulduğu gün
öğrenilecek en pahalı şeydir.

---

## PostgreSQL: kurulum **yeniden başlatma ister**

`pg_stat_statements` bir **shared preload** kütüphanesidir: postmaster
başlarken belleğe alınır, sonradan yüklenemez. `reload` (SIGHUP) yetmez,
`SELECT` ile değiştirilemez.

```bash
./scripts/slowlog.sh kur postgresql
```

Bu komut:

1. `config/postgresql/slowlog.conf` dosyasını `postgresql.conf`'a bir
   `include_if_exists` satırıyla bağlar,
2. eklentiyi yaratır (`CREATE EXTENSION pg_stat_statements`),
3. **ölçümün henüz başlamadığını** söyler ve yeniden başlatma komutunu
   yazar.

```bash
docker compose up -d postgresql        # kesintiyi SİZ seçiyorsunuz
./scripts/slowlog.sh durum postgresql
```

Betik sunucuyu **kendiliğinden yeniden başlatmaz**. O an ne koştuğunu
bilmiyor; üretim veritabanını kapatma kararı kullanıcınındır. JSON çıktısı
bu ara hâli ayrı bir alanla söyler: `"enabled": false,
"pending_restart": true`. Panel bunu "açık" gösterseydi, kullanıcı ertesi
gün boş listeye bakıp aracın bozulduğunu düşünürdü.

### `include_if_exists`, `include` değil

Ayar dosyası host'tan bind-mount ile geliyor. Depo taşınır, mount kaybolur
ya da dosya silinir; `include` o hâlde PostgreSQL'i **açılışta düşürür**.
Bir ölçüm aracının ayar dosyası, veritabanının açılmasını engelleyemez —
kaybolduğunda olması gereken tek şey ölçümün kapanması ve `durum`un bunu
söylemesidir.

### `config/postgresql/slowlog.conf` içindeki kararlar

| Ayar | Değer | Neden |
|---|---|---|
| `shared_preload_libraries` | `pg_stat_statements` | ölçümün kendisi |
| `pg_stat_statements.track` | `top` | `all` olsaydı fonksiyon içindeki cümleler ayrıca sayılır, **aynı süre iki kez** görünür ve toplam-süre sıralaması bozulurdu |
| `pg_stat_statements.track_utility` | `off` | **gizlilik**: utility cümleleri normalleştirilmez, `CREATE ROLE … PASSWORD '…'` metniyle saklanır ve `durum` onu ekrana basardı |
| `pg_stat_statements.save` | `on` | kapalı olsaydı her yeniden başlatma ölçümü sıfırlar, "haftanın en pahalı sorgusu" diye bir şey ölçülemezdi |
| `compute_query_id` | `on` | `pg_stat_activity.query_id` de dolar: "şu an asılı duran sorgu, listedeki hangi satır" ancak öyle cevaplanır |

---

## MariaDB: yeniden başlatma **gerekmez**

```bash
./scripts/slowlog.sh kur mariadb --esik 0.5
```

İki kaynak var ve araç hangisini kullandığını ekranda yazar:

**1. `performance_schema` digest'i** — tercih edilen. Sorguyu
normalleştirir (`?`), **eşik tanımaz**, `TRUNCATE` ile sıfırlanır.

**2. Yavaş sorgu günlüğü** — `long_query_time`'dan uzun süren sorguları
**ham metinle** dosyaya yazar. İki sınırı var:

* **EŞİK.** Bu aracın aradığı asıl sınıf — kısa ama çok çağrılan sorgu —
  eşiğin altında kalır ve dosyaya **hiç düşmez**. Yani "yavaş sorgu günlüğü
  boş" demek "yavaş sorgu yok" demek değildir.
* **GİZLİLİK.** `WHERE tcno = '12345678901'` dosyada aynen yazılıdır.

`performance_schema` bu yığında varsayılan olarak **kapalıdır**; açmak
yeniden başlatma ister:

```ini
# config/mariadb/my.cnf → [mysqld]
performance_schema = ON
```

```bash
docker compose up -d mariadb
```

`kur mariadb` `SET GLOBAL` kullanır, yani ayarlar **yeniden başlatmada
kaybolur**. Kalıcı olması için `my.cnf`'teki satırları siz eklersiniz —
betik motorun ayar dosyasına yazmaz. Sebep: `my.cnf` motorun bellek
ayarlarını da taşıyor; bir ölçüm aracının oraya yazması, o dosyayı kimin
düzenlediğini bir daha kimsenin bilememesi demek.

---

## Gizlilik: sorgu metni veri taşıyabilir

| Kaynak | Metin | Araç ne yapar |
|---|---|---|
| `pg_stat_statements` | normalleştirilmiş (`$1`) | olduğu gibi gösterir |
| `performance_schema` digest'i | normalleştirilmiş (`?`) | olduğu gibi gösterir |
| MariaDB yavaş sorgu günlüğü | **HAM** | dizgi sabitlerini ve sayıları `?` yapar **ve ekranda söyler** |

Maskeleme sessiz yapılsaydı kullanıcı gördüğü metnin ham olmadığını bilemez,
dolayısıyla **diskteki günlük dosyasını da güvenli sanırdı** — oysa orada
ham hâli duruyor. JSON çıktısında `"masked": true` alanı aynı şeyi panele
söyler.

---

## `oneri` — ölçülebilen üç şey, uydurma yok

```bash
./scripts/slowlog.sh oneri postgresql
```

| Tür | Nasıl ölçülüyor |
|---|---|
| `indeks` | `EXPLAIN` planında ardışık tarama + eşitlik süzgeci (aşağıda) |
| `ardisik-tarama` | `pg_stat_user_tables.seq_tup_read` |
| `kullanilmayan-indeks` | PostgreSQL `idx_scan = 0`, MariaDB `COUNT_FETCH = 0` |
| `tarama-orani` | taranan / dönen satır oranı |

**`indeks`** — en pahalı sorguların planına gerçekten bakılır. PostgreSQL
16'nın `EXPLAIN (GENERIC_PLAN)` seçeneği `$1` parametrelerini gerçek değer
olmadan planlatır; tam bu iş için var. Planda `Seq Scan … Filter:
(sütun = $1)` görülüyorsa o sütun okunuyor demektir. Sütun adı ayrıca
`pg_attribute`'ta doğrulanır ve tablo yeterince büyük değilse öneri
**verilmez** — küçük bir tabloda ardışık tarama zaten doğru plandır.
Yalnız **eşitlik** süzgeçleri önerilir: `<`, `LIKE '%…%'` ya da işlev
çağrısı içeren bir süzgeç için sıradan bir B-tree indeksi çoğu zaman işe
yaramaz ve "indeks ekledim, hiçbir şey değişmedi" sonucunu üretirdi.
PostgreSQL 16'dan eski sürümlerde bu adım **atlanır ve atlandığı söylenir**.

**`ardisik-tarama`** — sıralama tarama *sayısına* göre değil, o taramalarda
**okunan satır** sayısına göre. 40 satırlık bir tabloyu bir milyon kez
taramak ucuzdur; 10 milyon satırlık bir tabloyu on kez taramak değildir.

**`kullanilmayan-indeks`** — MariaDB'de ölçüt `COUNT_FETCH`, `COUNT_STAR`
değil. `COUNT_STAR` okumaları ve **yazmaları birlikte** sayar; sürekli
yazılan bir tablodaki hiç okunmayan indeks orada sıfırdan büyük görünür ve
listeye hiç girmezdi — oysa tam olarak aradığımız indeks odur.

**`tarama-orani`** — 2 milyon satır tarayıp 10 satır döndüren bir sorgu,
işini yapmak için tablonun tamamını okuyordur.

### Öneri **uygulanmaz**, yalnız yazılır

İndeks eklemek okuma yolunu hızlandırır ama **her `INSERT`/`UPDATE`'i
yavaşlatır** ve diskte yer tutar; indeks silmek geri alması dakikalar süren
bir iştir. Bu takası ancak uygulamayı bilen kişi yapabilir. Bu yüzden
`oneri` yalnız `SELECT`/`EXPLAIN` çalıştırır ve komutları ekrana basar;
`EXPLAIN`'e `ANALYZE` verilmez, yani sorgu **çalıştırılmaz**.

E2E paketi bu sözü indeks sayısını önce ve sonra sayarak doğrular.

### Dışarıda bırakılanlar ve sebepleri

"Kullanılmıyor" görünen her indeks silinemez:

* **PRIMARY / UNIQUE / dışlama kısıtı** — indeksi değil **kuralı** kaldırır.
* **`indisreplident`** — mantıksal çoğaltma satırı bu indeksle tanır.
* **Yabancı anahtar indeksi (MariaDB)** — motor silmeyi zaten reddeder;
  önerseydik çalışmayacak bir komut vermiş olurduk.

### `idx_scan = 0` her zaman "hiç kullanılmadı" demek değil

"Sayaç **sıfırlandığından beri** kullanılmadı" demektir. Bu yüzden her
`oneri` çıktısında **gözlem penceresi** yazar. Ayrıca sayaçlar düğüm
başınadır: ana kopyada kullanılmayan bir indeks replikada kullanılıyor
olabilir.

---

## `sifirla` — ve `--vt`'nin PostgreSQL'e özel anlamı

```bash
./scripts/slowlog.sh sifirla postgresql --vt uygulama   # yalnız o veritabanı
./scripts/slowlog.sh sifirla postgresql                 # KÜME GENELİ
```

PostgreSQL'de `pg_stat_statements_reset(userid, dbid, queryid)` tam bunun
için var. MariaDB'de sayaçlar veritabanı bazında sıfırlanamaz
(`performance_schema` tabloları yalnız `TRUNCATE` kabul eder); orada
`--vt` **yok sayılır ve bu söylenir**. Sessizce sunucu genelini
sıfırlasaydık, kullanıcı yalnız kendi veritabanını temizlediğini sanırdı.

Biriken ölçüm geri gelmez.

---

## JSON çıktısı

Son satır her zaman tek satır JSON'dur; panel ve controller bunu okur.

```json
{"engine":"postgresql","command":"durum","source":"pg_stat_statements",
 "enabled":true,"pending_restart":false,"masked":false,
 "rows_kind":"returned","threshold_ms":null,
 "queries":[{"query":"SELECT count(*) FROM t_sik WHERE dolgu = $1",
             "calls":400,"total_ms":53.0,"avg_ms":0.132,"rows":400,
             "blocks":10000,"db":"slowtest"}],
 "total_ms":199.5,"suggestions":[],"seconds":13,"ok":true,
 "detail":"ölçüldü: 1 motor, 4 sorgu listelendi, toplam 199.5 ms"}
```

**Alan adları her motorda aynı, dolu olmaları değil.** MariaDB'de
`"blocks"` JSON `null`'dur, `0` değil — InnoDB sorgu başına okunan blok diye
bir sayaç tutmuyor. `0` yazsaydık panel "hiç disk okumamış, sorun burada
değil" derdi; oysa doğru cevap "bu motorda böyle bir ölçü yok".

`"rows"` motora göre farklı şey sayar, bu yüzden yanında `rows_kind` var:

| Motor | `rows_kind` | Anlamı |
|---|---|---|
| postgresql | `returned` | **dönen** satır |
| mariadb | `examined` | **taranan** satır |

Farkı yazmasaydık "10 satır döndüren sorgu neden yavaş" sorusunun cevabı
kaybolurdu — MariaDB'deki o sayı 2 milyon satır tarandığını söylüyor olabilir
ve asıl bulgu tam olarak budur.

---

## Çıkış kodları

| Kod | Anlamı |
|---|---|
| 0 | iş bitti |
| 1 | **iş düştü** — ayar yazılamadı, sıfırlama başarısız |
| 2 | **kapsam dışı** ya da kullanım hatası |
| 3 | **ölçülemedi** — motor kapalı, docker yok, sorgu düştü |
| 4 | **ÖLÇÜM KAPALI** — "yavaş sorgu bulunmadı" değil, "hiç bakılmadı" |

`0`, `3` ve `4` bilerek ayrı: "baktım, temiz", "bakamadım" ve "hiç
bakılmadı" üç ayrı cevaptır ve üçü ayrı iş gerektirir.

---

## Ölçüm: `scripts/e2e/slowlog.sh`

```bash
./scripts/e2e/slowlog.sh              # çalışan motorların hepsi
./scripts/e2e/slowlog.sh postgresql   # yalnız biri
```

Paket bilinen maliyette dört sorgu koşturur ve aracın onları nasıl
raporladığını sayıyla karşılaştırır: pahalı sorgu ilk N'de mi, çağrı sayısı
doğru mu, sıralama gerçekten toplam süreye göre mi, ucuz sorgu listeyi
dolduruyor mu, `sifirla` gerçekten sıfırlıyor mu, `oneri` hiçbir şey
uyguluyor mu, `kur` sunucuyu sessizce yeniden başlatıyor mu.

**Yan etkileri** paketin başında yazılı: geçici bir veritabanı yaratıp
siler, sayaçları sıfırlar (MariaDB'de sunucu geneli), MariaDB'nin global
yavaş sorgu ayarlarını değiştirip **geri yazar**.

PostgreSQL'de ölçüm kapalıysa asıl kontroller **atlanır** ve sebebi yazılır;
paket üretim veritabanını kendiliğinden yeniden başlatmaz. Yeniden başlatma
kabul edilebiliyorsa:

```bash
E2E_SLOWLOG_YENIDEN_BASLAT=1 ./scripts/e2e/slowlog.sh postgresql
```
