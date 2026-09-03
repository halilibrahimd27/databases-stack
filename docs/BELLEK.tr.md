# Bellek: tavan, rezerve ve çekirdek baskısı

***Türkçe** · [English](BELLEK.md)*

Bu belge, kontrol servisinin bir motoru açarken neye baktığını ve neden öyle
baktığını anlatır. Kısa cevap: **`docker --memory` bir tavandır, rezervasyon
değildir.** Bu ayrımı kaybeden bir hesap, boş bir makinede "yer yok" der.

---

## 1. İki büyüklük

| | **Rezerve** (taban) | **Tavan** (limit) |
|---|---|---|
| Tanım | Motorun açılışta **gerçekten ayırdığı** ve işletim sistemine geri vermediği bellek | `docker --memory` / cgroup `memory.max`. Aşılırsa çekirdek container'ı öldürür |
| Ölçüsü | Motorun kendi ayarı (buffer pool, heap) | Kontrol servisinin verdiği üst sınır |
| Toplamı | Dağıtılabiliri **asla** aşamaz | Dağıtılabiliri **aşabilir** |
| Değişimi | Motor çalışırken küçülmez | `docker update` ile canlı değişir |

Rezervenin kaynağını **katalog** söyler; kod motor adı bilmez.
`catalog.json` → `resources.reserve.from`, rezervenin hangi ayar
anahtar(lar)ından türediğini yazar. Boş liste "tabanı yok" demektir:

| Motor | Rezerve nereden | Açıklama |
|---|---|---|
| MariaDB | `MARIADB_BUFFER_POOL` | InnoDB buffer pool'u açılışta ayrılır, geri verilmez |
| PostgreSQL | `POSTGRES_SHARED_BUFFERS` | postmaster açılışta tek parça paylaşımlı bellek ayırır |
| Elasticsearch | `ELASTIC_JAVA_OPTS` | `-Xms` = JVM'in açılışta aldığı heap |
| Cassandra | `CASSANDRA_HEAP` | aynı gerekçe (JVM `-Xms`) |
| Kafka | `KAFKA_HEAP_OPTS` | aynı gerekçe |
| Neo4j | `NEO4J_HEAP` | aynı gerekçe |
| Redis | — | `maxmemory` bir TAVANDIR; Redis boş başlar, veri yazıldıkça büyür |
| MSSQL | — | "max server memory" bir TAVANDIR |
| MongoDB | — | WiredTiger önbelleği bir TAVANDIR; okundukça büyür |
| ClickHouse | — | `max_server_memory_usage` bir TAVANDIR |
| MinIO · RabbitMQ · İzleme | — | belirgin bir açılış tabanı yok |

`POSTGRES_WORK_MEM` bilerek rezerve **değildir**: bağlantı başına ve geçicidir.
(Yine de bir OOM kaynağıdır; `shared_buffers + work_mem × max_connections`
toplamının tavanı aşmadığı `scripts/selftest.py`de ayrıca sınanır.)

Bağlantı **sayısı** da bir bellek kalemidir: PostgreSQL'de her bağlantı
ayrı bir süreçtir, yani havuz kullanmayan bir uygulama motoru RAM'le
değil süreç sayısıyla boğar. Bunun için 6432'de isteğe bağlı bir bağlantı
havuzu vardır; havuz ayarlarının `POSTGRES_MAX_CONNECTIONS`'tan nasıl
türediği ve transaction pooling'in sınırları `docs/POOLING.md`de.

---

## 2. Dağıtılabilir bellek

```
dağıtılabilir = toplam RAM − işletim sistemi payı − çekirdek servis payı
```

- **İşletim sistemi payı** = `max(1024 MB, RAM × 0.20)`, en çok RAM'in %60'ı.
  Üst sınır şart: 512 MB'lık bir makinede "1024 MB işletim sistemine ayrıldı"
  demek bütçeyi eksiye düşürür ve hiçbir motor açılamaz.
- **Çekirdek servis payı** = 448 MB — gateway (nginx), kontrol servisi ve
  Adminer. Bunlar her zaman ayakta.

Ölçülen 16 GB'lık test sunucusunda: `15984 − 3196 − 448 = 12340 MB`.

---

## 3. Bir motoru açmadan önceki üç kapı

Sırayla uygulanır ve ret mesajı **hangi kapıya** takıldığını söyler
(`plan.rule` alanı: `tavan` · `rezerve` · `cekirdek`).

### 3.1 Tavan kapısı — yumuşak

```
Σ tavan + yeni tavan  ≤  dağıtılabilir × OVERCOMMIT_LIMIT
```

Tavanların hepsi aynı anda dolmaz; aşırı taahhüt bilinçli bir politikadır.
Varsayılan katsayı **1.5** ve ölçüme göre bile temkinlidir — aşağıdaki dört
container tavanlarının ortalama **%5'ini** kullanıyordu.

`OVERCOMMIT_LIMIT=1.0` yazmak aşırı taahhüdü kapatır, yani bu belgenin
anlattığı hatanın olduğu davranışa döner.

### 3.2 Rezerve kapısı — sert

```
Σ rezerve + yeni motorun rezervesi  ≤  dağıtılabilir
```

Asla esnetilmez. Rezerve motorun gerçekten ayıracağı bellektir; aşırı taahhüt
edilirse ilk yazma yükünde OOM killer devreye girer. Plan bu kapıyı
`reserve_ok` alanında bildirir.

Sığmayan bir istek **önce küçültülür**: rezerve tavanla birlikte büyüdüğü için
(MariaDB buffer pool = tavanın %60'ı) daha küçük bir tavan çoğu zaman sığar ve
kullanıcı istediği motoru açar. Tavan %5'lik adımlarla `min_mb`'ye kadar iner;
asgari tavanda bile sığmıyorsa **o zaman** reddedilir.

### 3.3 Çekirdek kemeri

```
MemAvailable  ≥  yeni rezerve + KERNEL_SAFETY_MB   (varsayılan 512 MB)
```

Defter ne derse desin çekirdeğin gerçeği bağlayıcıdır. `MemAvailable`
okunamıyorsa (0) bu kapı **atlanır**: ölçemediğimiz bir şeyi gerekçe gösterip
motor açtırmamak kullanıcıya yalan söylemek olurdu.

---

## 4. Çekirdek baskı sinyali (PSI)

`/proc/pressure/memory` çekirdeğin kendi ölçümüdür:

```
some avg10=0.00 avg60=0.00 avg300=0.00 total=0
full avg10=0.00 avg60=0.00 avg300=0.00 total=0
```

- **some avg10** — son 10 saniyenin yüzde kaçında **en az bir** görev bellek
  bekledi. Asıl bakılan sayı budur.
- **full avg10** — yüzde kaçında **bütün** görevler bekledi (ciddi darlık).

| Seviye | Eşik (`some avg10`) | Anlamı |
|---|---|---|
| `yok` | < 10 | Çekirdek kimseyi bekletmiyor |
| `orta` | ≥ `PRESSURE_WARN` (10) | Bellek geri kazanımı başladı |
| `yuksek` | ≥ `PRESSURE_HIGH` (30) | Gerçek darlık; yeni yük koymayın |
| `bilinmiyor` | — | Çekirdekte PSI yok (`CONFIG_PSI` kapalı) |

`bilinmiyor` bir arıza değildir ve **kapı olarak kullanılmaz**.

---

## 5. Ölçülen olay

16 GB'lık test sunucusunda, ürünün eski hâlinde:

| Container | Tavan | Gerçek kullanım |
|---|---|---|
| mariadb | 3196 MB | 243 MB (%7) |
| mariadb-replica | 3196 MB | 213 MB (%6) |
| postgresql | 2397 MB | 98 MB (%4) |
| redis | 1278 MB | 5 MB (%0) |

Aynı andaki host durumu:

```
free -m               → toplam 15984 · kullanılan 1508 · available 13987
/proc/pressure/memory → some avg10=0.00 avg60=0.00 · full avg10=0.00
tavanların toplamı    → 15087 MB
dağıtılabilir         → 12340 MB
```

Panel şunu yazıyordu: **"AYRILAN BELLEK 15 GB / 12 GB · %122 aşım"**, kapalı
motorların hepsinde de "bellek yetmiyor". Makine ise **%91 boştu** ve çekirdek
tek bir görevi bile bekletmiyordu.

Hata modeldeydi: tavanlar toplanıp RAM'le kıyaslanıyordu. Bu, yoldaki
arabaların azami hızlarını toplayıp "yol kapasitesi aşıldı" demeye benzer.

Yeni modelde aynı durum:

```
Σ tavan     15087 MB ≤ 12340 × 1.5 = 18510 MB   → tavan kapısı AÇIK
Σ rezerve    2516 MB ≤ 12340 MB                 → rezerve kapısı AÇIK
MemAvailable 13987 MB ≥ rezerve + 512 MB        → çekirdek kemeri AÇIK
```

2516 MB = MariaDB 1917 (buffer pool) + PostgreSQL 599 (shared_buffers) +
Redis 0. Aynı sunucuda yeni bir motor **açılabilir**.

---

## 6. Yeniden dengeleme

`POST /api/rebalance` (panelde **Yeniden dengele**). Tavanlar motorlar tek tek
açılırken hesaplanmıştı; üçüncü motor açılırken ilk ikisinin tavanı çoktan
konmuştu ve kimse geri dönüp "artık daha az yer var, sen de kıs" demedi.
Yeniden dengeleme tam olarak bunu yapar:

1. Her açık motor için istenen tavanı aktivasyondakiyle **aynı formülle**
   hesaplar (iki formül tutmak, dengelemeden sonra motoru kapatıp açınca
   başka bir sayı çıkması demek olurdu).
2. **Yumuşak kural**: motorların tavan toplamı bütçeyi aşıyorsa hepsi **aynı
   oranda** kısılır — sıraya göre son açılan cezalandırılmaz.
3. **Sert kural**: yeni tavanlardan türeyecek rezerve toplamı dağıtılabiliri
   aşıyorsa %10'luk adımlarla inilir; `min_mb`'nin altına inilmez.
4. **Uygular**: `docker update --memory` — cgroup limiti **canlı** değişir.

### Yeniden dengeleme neyi yapmaz

- **Container'ı yeniden başlatmaz.** Açık bağlantılar kopmaz, InnoDB kurtarma
  çalışmaz, kesinti olmaz. Kolay yol `compose up -d` ile motoru yeniden
  yaratmak olurdu; o yol çalışan veritabanını kapatır.
- **Tavanı anlık kullanımın altına indirmez.** Taban =
  `gerçek kullanım × REBALANCE_HEADROOM` (varsayılan 1.3). cgroup limiti anlık
  kullanımın altına inerse container **anında** OOM olur.
- **Gerçek kullanım ölçülemiyorsa küçültmez.** Körlemesine küçültmek aynı
  kapıya çıkar; bu durum iş günlüğüne yazılır.
- **Motorun iç ayarını çalışırken değiştirmez.** Buffer pool ve heap
  küçültülemez; yeni değerler `state/tuning.env`e yazılır ve motorun **bir
  sonraki** açılışında geçerli olur. Bu yazma şarttır: yoksa motor bir dahaki
  açılışta kendi tavanının üstünde bellek ayırıp ilk sorguda OOM olur.
- **Kubernetes'te çalışmaz.** Orada limit değişimi pod'u yeniden yaratır,
  yani kesinti demektir; iş açık gerekçeyle reddedilir.

---

## 7. Ayar sabitleri

Hepsi kontrol servisinin ortam değişkenidir; verilmezse varsayılan geçerlidir.

| Değişken | Varsayılan | Ne yapar |
|---|---|---|
| `OVERCOMMIT_LIMIT` | `1.5` | Tavan toplamının dağıtılabilire oranı. `1.0` = aşırı taahhüt yok |
| `KERNEL_SAFETY_MB` | `512` | Çekirdek kemerinin emniyet payı |
| `PRESSURE_WARN` | `10.0` | `some avg10` bu değerden büyükse baskı "orta" |
| `PRESSURE_HIGH` | `30.0` | Bu değerden büyükse "yuksek" |
| `REBALANCE_HEADROOM` | `1.3` | Yeni tavanın gerçek kullanıma göre asgari katı |

Kodda sabit olanlar: işletim sistemi payı `%20` (en az 1024 MB, en çok RAM'in
%60'ı), çekirdek servis payı `448 MB`, en küçük anlamlı tavan değişimi
`32 MB`.

---

## 8. Sorun giderme

**"Panel bellek yetmiyor diyor ama `free -m` makinenin boş olduğunu
söylüyor."**
Ret mesajını okuyun: hangi kapıya takıldığını yazar.
- *TAVAN sıkışması* → yeniden dengeleyin, bir motoru durdurun ya da
  `OVERCOMMIT_LIMIT`'i yükseltin. Bellek gerçekten dolu değildir.
- *REZERVE* → açık motorlar belleği gerçekten ayırmış. Bir motoru durdurmak ya
  da RAM eklemek dışında yolu yoktur.
- *ÇEKİRDEK KEMERİ* → `MemAvailable` düşük. Yığın dışında bir şey belleği
  yiyor olabilir; `free -m` ve `/proc/pressure/memory`ye bakın.

**"Yeniden dengeledim ama tavan değişmedi."**
İş günlüğüne bakın (`/api/jobs/<id>` → `log`): "gerçek kullanım ölçülemedi",
"değişiklik yok (32 MB'ın altında)" ya da "tabana çekildi" satırlarından biri
sebebi söyler.

**"Motoru kapatıp açtım, iç ayarı değişti."**
Beklenen davranış: yeniden dengeleme tavanı hemen, iç ayarı bir sonraki
açılışta uygular.

---

## 9. Nasıl doğrulanıyor

```bash
./stack.sh selftest          # docker gerektirmez
```
7. bölüm bu modelin üç kuralını **çift senaryoyla** sınar: aralarındaki tek
fark kuralın baktığı büyüklüktür. Tavan toplamı aşarken kabul, rezerve
aşarken ret; aynı defterle MemAvailable 13987 MB'da kabul, 128 MB'da ret.
Ayrıca her motorun katalogda rezerve tanımı olduğu ve kabul edilen hiçbir
planın sert kuralı çiğnemediği (5 sunucu boyutu × 4 açık motor durumu)
doğrulanır.

```bash
./scripts/e2e/sizing.sh      # ÇALIŞAN kuruluma karşı
```
6. bölüm aşırı taahhüt durumunu **kendisi yaratır** (bir motorun tavanını
`docker update` ile geçici olarak şişirir), yeniden dengelemeyi çağırır,
tavanın gerçekten düştüğünü cgroup'tan okur ve `.State.StartedAt` ile hiçbir
container'ın yeniden başlatılmadığını doğrular. Çıkarken şişirdiği tavanı geri
yazar. Atlamak için: `SIZING_SKIP_REBALANCE=1`.

Ölçülemeyen durumlar `[ÖLÇÜLEMEDİ]` diye raporlanır ve **başarısız sayılır** —
"bilmiyorum" ile "iyi" aynı şey değildir.
