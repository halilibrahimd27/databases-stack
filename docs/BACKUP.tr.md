# Yedekleme

***Türkçe** · [English](BACKUP.md)*

Yedeği **alan** taraf tek bir betiktir: `scripts/backup.sh`. Panel de, gecelik
zamanlayıcı da, komut satırı da onu çağırır. Aynı işin ikinci bir uygulaması
yok — gece üretilen dosya ile panelin ürettiği dosya farklı yollardan
geçseydi, hangisinin geri yüklenebildiği ancak felaket günü anlaşılırdı.

Bu belge iki yolu da anlatır; ikisi de desteklenir ve aynı sonucu üretir.

---

## Panel: `/yedekler`

Yedeklerin **ayrı bir sayfası** var: `https://<sunucu>/yedekler`. Yönetim
panelinin üstündeki **Araçlar** satırındaki *Yedekler* bağlantısından açılır,
sayfanın başındaki **← Yönetim paneli** ile geri dönülür. Panelle aynı
parolanın, aynı TLS kapısının arkasındadır; parolasız açılmaz.

Sayfada iki bölge var: **Otomatik yedek** ve **Motorlar**. Geri yükleme
ikincisinin içinde, aşağıda ayrı bir başlıkta anlatılıyor.

### Otomatik yedek

Günlük yedek saati ve saklama süresi buradan ayarlanır; açıp kapatmak tek
düğme. Kaydettiğiniz anda sıradaki koşumun zamanı ekrana yazılır.

Zamanlayıcı **controller'ın içinde** çalışır: host'ta root yetkisi, `crontab`
kurulumu ya da systemd birimi gerektirmez. Ayarı okuyanla koşturanın aynı
süreç olması, "kaydettim ama gece yine eski saatte koştu" sınıfından hataları
baştan imkânsız kılıyor.

Aynı bölgede son koşumun sonucu duruyor: başarılıysa ne zaman olduğu,
başarısızsa **sebebiyle birlikte**. Başarısız bir yedek, "yedeğim var" sanan
kullanıcının en pahalı yanılgısıdır; sizi log dosyasına göndermiyoruz.

Zamanlama kapalıyken sayfa bunu bir ayar durumu gibi değil, bir **risk**
olarak yazar — sessizce kapalı kalmasın diye. `./stack.sh doctor` da aynı şeyi
söyler.

### Motorlar

Her motorun satırında kaç yedeği olduğu, toplam boyutu ve en yenisinin ne
zaman alındığı yazar. Hiç yedeği olmayan motor ayrıca işaretlenir: boş
sütunlar yüzünden gözden kaçan şey tam olarak buydu.

**Yedek al** düğmesi o motorun yedeğini hemen alır. Elle alınan yedek gecelik
turu iptal etmez, ek bir kurtarma noktası oluşturur. Motor kapalıyken düğme
tıklanmaz: döküm araçları (`mariadb-dump`, `pg_dumpall`, `mongodump` …)
veritabanına **bağlanır**, kapalı motorda yapacakları bir şey yoktur.

Satırdaki dosya listesini açtığınızda her yedeğin tarihi, boyutu ve
**kaynağı** görünür:

| Etiket | Anlamı |
|---|---|
| `elle` | Panelden **Yedek al** ile alınmış |
| `zamanlı` | Gecelik turun ürettiği |
| `dış` | Host cron'u ya da komut satırı |

Kaynak dosya adından tahmin edilmiyor. `backup.sh` dosya adına kaynağını
yazmaz ve yazdırmak dosya adı sözleşmesini değiştirmek olurdu (geri yükleme,
temizlik ve uçtan uca testler o ada bakıyor). Bunun yerine controller kendi
başlattığı koşumdan sonra oluşan dosyaları ayrı bir deftere işaretler
(`state/backup_index.json`); deftere girmemiş dosya `dış`tır. Bunu "zamanlı"
saymak yalan olurdu.

Liste **son 40 dosya** ile sınırlı — bir yıllık günlük yedek 365 satır demek
ve sayfa kendini düzenli olarak yeniden çiziyor. Sınırın dışında kalanların
varlığı satırdaki toplam sayıda duruyor; sayı ile liste birbirini yalanlamaz.

Yedek sayılan uzantılar `*.gz` (şifresiz) ve `*.gz.enc` (şifreli) —
ikisi de kurtarma noktasıdır, aradaki fark yalnız zarftır. Doğrulamayı
geçemeyip `.bozuk` uzantısıyla kenara alınmış dosyalar kurtarma noktası
**değildir**; onları saymak panelde "3 yedeğiniz var" yazdırıp elde hiç yedek
olmaması demek olurdu.

---

## Komut satırı

```bash
./stack.sh backup                # aktif motorların hepsi (kapalılar atlanır)
./stack.sh backup mariadb        # tek motor
./scripts/backup.sh list         # yedekleri listele
./scripts/backup.sh stats        # boyut, adet, en son ne zaman
./scripts/backup.sh clean 7      # 7 günden eskileri sil
./scripts/backup.sh verify <dosya>
./scripts/backup.sh sifreleme   # yedek şifrelemesi açık mı, hangi anahtarla
```

## Otomatik çalıştırma

İki yol var ve ikisi de destekleniyor.

**1) Panelden** (önerilen) — `/yedekler` sayfasındaki *Otomatik yedek*
bölgesi. Ayar `state/backup.json` dosyasında tutulur, koşturan controller'dır.

**2) Host cron'u** — `install.sh`, `state/crontab` dosyasını gerçek yollarla
üretir:

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

İkisi birlikte koşarsa sorun olmaz: `backup.sh` `state/backup.lock` üzerinde
kendi kilidini tutar, ikinci koşum reddedilir. Panel bu kilide **önceden**
bakar — aksi halde elle başlatılan iş, betiğin "başka bir işlem kilidi
tutuyor" ölümüyle düşüyor ve ekranda "yedekleme başarısız" görünüyordu; oysa
yedek alınıyordu, sadece başka bir koşum tarafından.

> Panel zamanlaması, ölçülmüş bir arızanın sonucudur. Önceden `install.sh`
> yalnız `state/crontab`ı *üretiyor* ve "yüklemek için `crontab state/crontab`"
> diyordu. Kimse yapmıyordu: test sunucusunda `crontab -l | grep backup` sıfır
> satır, `backups/` altındaki klasörler boştu. Yedek alındığı sanılırken hiç
> alınmıyordu.

### Saklama süresi

Varsayılan 7 gün (`RETENTION_DAYS`), panelden 1–365 arası değiştirilebilir.
Temizlik her motorda **en yeni birkaç kopyayı yaşı ne olursa olsun korur**
(`BACKUP_KEEP_MIN`, varsayılan 3): kapalı ya da yedeği üst üste başarısız olan
bir motorun dosyaları yenilenmediği için tarih eşiğini geçiyor ve eski sürüm
onun **son** kurtarma noktasını da siliyordu — motor tekrar açıldığında geriye
hiçbir yedek kalmıyordu.

Temizlik, yedekleme düşse bile çalışır: yedeğin düşme sebebi çoğu zaman diskin
dolmasıdır ve tam o durumda temizliği atlamak işi kötüleştirir.

### Neden günde bir, 15 dakikada bir değil?

Yedekler veritabanı container'ının **içinde** alınır ve dump'ın bellek
tüketimi o container'ın kendi cgroup'una yazılır. 15 dakikada bir tam yedek
MariaDB'yi tekrar tekrar `CONSTRAINT_MEMCG` OOM ile öldürdü — container 172
kez yeniden başladı. Günde bir tam yedek bu baskıyı ortadan kaldırır.

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

Şifreleme açıkken her dosyanın adına `.enc` eklenir
(`.sql.gz` → `.sql.gz.enc`); biçim değişmez, üzerine bir zarf geçer.
Ayrıntı: [Yedek şifreleme](#yedek-şifreleme).

### Neo4j

Community sürümde çevrimiçi yedek yoktur (Enterprise özelliğidir). Yedek almak
veritabanını durdurmayı gerektirir, bu yüzden `backup all` içinde otomatik
çalışmaz:

```bash
BACKUP_NEO4J_OFFLINE=true ./scripts/backup.sh neo4j
```

### Kafka

Kafka bir log'dur, veritabanı değil. Dayanıklılık yedekle değil, topic başına
`replication.factor` ve `retention.ms` ile sağlanır. Katalogda yedeği
"desteklenmiyor" işaretli olduğu için `/yedekler` listesinde de görünmez: her
satırında ömür boyu "hiç yedek yok" yazan bir kayıt, gerçekten yedeksiz kalmış
bir veritabanını o gürültünün içinde kaybederdi.

### Elasticsearch

Veri dizinini kopyalamak **tutarsız** bir yedek üretir; doğru yol snapshot
API'sidir. Bunun için `path.repo` ayarı ve ayrı bir volume gerekir — compose
dosyasında hazır tanımlıdır.

---

## Yedek şifreleme

Yedekler öntanımlı olarak **düz gzip**tir. `.env` içinde bir anahtar
verdiğinizde her yedek **AES-256** ile şifrelenir:

```bash
# anahtar üret
openssl rand -base64 32 | tr -d '+/='

# .env
BACKUP_ENCRYPT_KEY=<ürettiğiniz değer>
```

Durumu her zaman şuradan görürsünüz:

```bash
./scripts/backup.sh sifreleme
```

### Neden

`scripts/sync-remote.sh` yedekleri Google Drive / S3 / Backblaze / SFTP'ye
kopyalıyor. Şifreleme olmadan bu dosyalar **düz gzip** olarak binadan çıkar:
uzak depo hesabını ele geçiren biri `gzip -dc` ile bütün veritabanını okur.
Elde ettiği şey yalnız tablo verisi de değil — `pg_dumpall` rolleri ve parola
hash'lerini, MariaDB dump'ı bütün kullanıcı tablolarını taşır. Yedek diskini
ayrı bir birime (`BACKUP_DIR=/mnt/backups`, tipik olarak bir NAS) koyan
kurulumlarda dosya zaten sunucunun dışında duruyor.

### Dosya adı sözleşmesi

| Ad | Anlamı |
|---|---|
| `mariadb_full_20260901_020000.sql.gz` | **Şifresiz** yedek (eski akış; hâlâ geçerli) |
| `mariadb_full_20260901_020000.sql.gz.enc` | **Şifreli** yedek |
| `…​.gz.bozuk` / `…​.gz.enc.bozuk` | Doğrulamayı geçemedi — **kurtarma noktası değildir** |

Sıra bilerek "önce `.gz`, sonra `.enc`": dosya önce sıkıştırıldı, **sonra**
şifrelendi; ad soldan sağa bunu anlatır.

`.enc` uzantısının `*.gz` desenine **uymaması** da kasıtlı. Şifreli dosyayı
`.gz` diye adlandırsaydık, onu tanımayan her araç `gzip -dc` deneyip
"not in gzip format" ile ölürdü — gürültülü ama **yanlış yere** işaret eden bir
hata. Şimdi eski araçlar dosyayı hiç görmüyor; görmemek, yanlış anlamaktan
iyidir.

Şifreli dosyanın ilk 64 baytı **düz metin bir başlıktır**:

```
DBSTACK-ENC1 aes-256-cbc pbkdf2 sha512 600000
```

Şifreleme parametreleri betikte değil **dosyanın içinde** duruyor. Sebebi:
yarın iterasyon sayısı yükseltilirse bugünkü yedekler açılabilir kalsın.
Betiğe sabit yazsaydık, o değişikliğin yapıldığı gün bütün arşiv sessizce
okunamaz hâle gelir ve bunu ancak felaket günü öğrenirdik. Aynı başlık,
dosyanın şifreli olduğunu **adından bağımsız** anlamayı da sağlıyor: dosya
yeniden adlandırılmış olsa bile betik "bu yedek şifreli" der, "bozuk gzip"
demez.

### Neden `openssl` (age ya da gpg değil)

- **Bulunabilirlik.** `install.sh` zaten `require_cmd openssl` diyor — openssl
  bu ürünün *kurulum şartı*; TLS sertifikaları (`scripts/gen-certs.sh`) ve
  rastgele parolalar (`scripts/lib/common.sh`) onunla üretiliyor. `age` ya da
  `gpg` seçmek, "tek komutla kurulur" diyen bir ürüne **yeni bir kurulum
  bağımlılığı** eklemek olurdu; ikisi de hiçbir dağıtımda öntanımlı gelmiyor.
- **Anahtar yönetiminin sadeliği.** Simetrik parola = `.env`'de tek satır,
  `DB_PASSWORD` ile aynı dosyada, aynı izinlerle. `age` bir *kimlik dosyası*
  ister: kaybedilecek ikinci bir sır, ayrı bir saklama yeri, ayrı bir
  yedekleme kuralı. `gpg` ise `~/.gnupg` anahtarlığı ister — ve `backup.sh`
  **üç ayrı kimlikle** koşuyor: host cron'u (kullanıcı), controller
  container'ı (root), operatörün terminali. Üç farklı `$HOME` = üç farklı
  anahtarlık = "panelden çalışıyor, cron'dan çalışmıyor" sınıfı arıza.
- **Kurtarma.** Felaket günü elde yığın değil yalnız *dosya* kalırsa, çözme
  komutu tek satır ve her Linux'ta çalışır (aşağıda). `age`/`gpg` ile önce
  aracı kurmak, sonra anahtarı içe aktarmak gerekir; en kötü günde en fazla
  adım.

**Ne vaat edilmiyor:** `openssl enc` AEAD (GCM) desteklemez. Bu şifreleme
**gizlilik** sağlar, kriptografik **bütünlük imzası (MAC)** sağlamaz.
Kurcalanmış bir dosya neredeyse kesinlikle CBC dolgusunda, gzip CRC'sinde ya da
`verify` biçim kontrollerinde düşer — ama bu bir MAC değildir. Vaat edilmeyen
bir güvenceyi vaat edilmiş gibi göstermek, hiç şifrelememekten tehlikelidir.

### ⚠️ ANAHTARI KAYBEDERSENİZ YEDEKLER AÇILAMAZ

Bunu büyük harfle yazıyoruz çünkü geri dönüşü yok: **anahtarsız bir yedek
dosyası rastgele bayt yığınıdır.** Ne bu üründe, ne başka bir yerde bir
kopyası vardır; kurtarma servisi, yedek anahtar, arka kapı yoktur.

Bu yüzden:

- Anahtarı **sunucunun dışında da** saklayın — parola yöneticisi, kasa, kâğıda
  yazıp zarf. Sunucu yandığında yedeği açacak şey odur. Anahtarı yalnız
  sunucuda tutmak, yedeği veriyle aynı yere koymakla aynı şeydir.
- `.env` dosyasını yedekleyin (ya da en azından bu satırı). `.env` sürüm
  kontrolüne **girmez** (`.gitignore`), yani onu yedekleyen tek şey sizsiniz.
- Anahtarı **değiştirirseniz eskisini silmeyin**: eski dosyalar eski anahtarla
  açılır. `RETENTION_DAYS` dolup o dosyalar temizlenene kadar ikisine de
  ihtiyacınız var. Uzak depodaki kopyalar için süre `RETENTION_REMOTE_DAYS`
  (öntanımlı 30 gün) — eski anahtarı en az o kadar saklayın.

Anahtarı `.env`'den ayrı bir dosyada tutmak isterseniz:

```bash
install -m 0600 /dev/null /etc/databases-stack/backup.key
openssl rand -base64 32 | tr -d '+/=' > /etc/databases-stack/backup.key
# .env
BACKUP_ENCRYPT_KEY_FILE=/etc/databases-stack/backup.key
```

Dosya okunamıyorsa yedekleme **durur**; sessizce şifresiz yedek üretmez.

### Geri yükleme ve doğrulama

Hiçbir komut değişmiyor. `verify`, `restore-*`, `list`, `stats`, `clean` ve
prova (`restore-drill.sh`) şifreli dosyayı da şifresizi de kabul eder;
şifre çözme boru hattının içinde yapılır.

Anahtar yoksa hata **anlaşılırdır** — gzip hatası değil:

```
[✗] Bu yedek ŞİFRELİ, BACKUP_ENCRYPT_KEY tanımlı değil: mariadb_full_….sql.gz.enc
[✗]   .env'de BACKUP_ENCRYPT_KEY (ya da BACKUP_ENCRYPT_KEY_FILE) verin, sonra tekrar deneyin.
[✗]   ANAHTAR KAYIPSA BU DOSYA AÇILAMAZ; kurtarmanın başka yolu yoktur (docs/BACKUP.md).
```

Anahtar **yanlışsa**:

```
[✗] Bu yedeğin ŞİFRESİ ÇÖZÜLEMEDİ: mariadb_full_….sql.gz.enc
[✗]   Elinizdeki anahtar bu dosyaya ait değil (ya da dosya kurcalanmış).
[✗]   Çözülen ilk baytlar: 7712 — beklenen: 1f8b (gzip).
```

Bu ikinci kontrol dosyanın **ilk iki baytına** bakar. Sebep hız: CBC dolgu
hatası akışın *sonunda* anlaşılır, yani 30 GB'lık bir dosyayı yanlış anahtarla
baştan sona okuduktan sonra "bad decrypt" denirdi — cevabı 40 dakika geç
vermek, geri yükleme sırasında verilebilecek en pahalı cevaptır.

### Elle çözme (ürün olmadan)

Sunucu, betikler, hepsi gitti; elinizde yalnız dosya ve anahtar var:

```bash
export K='<anahtarınız>'
tail -c +65 mariadb_full_20260901_020000.sql.gz.enc \
  | openssl enc -d -aes-256-cbc -pbkdf2 -md sha512 -iter 600000 -pass env:K \
  | gzip -dc > dump.sql
```

`tail -c +65` 64 baytlık başlığı atlar. Parametreleri başlıktan okuyun:

```bash
head -c 64 mariadb_full_20260901_020000.sql.gz.enc; echo
```

Anahtarı komut satırına (`-pass pass:...`) **yazmayın**: `ps` çıktısı
sistemdeki herkese açıktır. Betik de bu yüzden ortam değişkeni kullanıyor.

### Maliyet (ölçüldü)

openssl 3.5.5, AES-NI'li bir x86-64 üzerinde:

| Ne | Süre |
|---|---|
| PBKDF2-HMAC-SHA512, 600 000 iterasyon | **dosya başına ~0,56 sn** (tek seferlik) |
| Şifreleme akış hızı | ~130–220 MB/sn |

Şifreleme gzip'ten **sonra** geldiği için sıkıştırılmış baytları işler:
5 GB'lık bir dump 400 MB'a inip ~3 sn'de şifrelenir. Darboğaz hâlâ gzip.

600 000 iterasyon OWASP'ın PBKDF2 önerisidir. Rastgele üretilmiş 32 karakterlik
bir anahtar için gereğinden fazladır; zayıf bir parola giren kullanıcı için
ise tek koruma odur ve bedeli günde yarım saniyedir.

---

## Geri yükleme

Geri yükleme, veriyi **silip yerine koyan** bir işlemdir. Hem panelden hem
komut satırından yapılabilir; ikisi de aynı
`scripts/backup.sh restore-<motor>` çağrısına iner ve ikisi de dosyayı veriye
dokunmadan **önce** doğrular.

Otomatik geri yükleme beş motorda vardır:

| Motor | Panelden | Komut satırından |
|---|---|---|
| MariaDB | var | `./stack.sh restore mariadb <dosya>` |
| PostgreSQL | var | `./stack.sh restore postgresql <dosya>` |
| MongoDB | var | `./stack.sh restore mongodb <dosya>` |
| Redis | var | `./stack.sh restore redis <dosya>` |
| SQL Server | var | `./stack.sh restore mssql <dosya>` |

Diğer motorların yedeği alınır ama otomatik geri yüklemesi yoktur; betik bunu
açıkça söyler ("Bu motor için otomatik geri yükleme yok"). Dosyaların içeriği
standarttır (Cassandra snapshot'ı, ClickHouse `BACKUP` çıktısı, RabbitMQ
tanımları, MinIO veri dizini arşivi) ve motorun kendi belgesindeki yolla geri
yüklenir.

### Panelden — adım adım

1. **Yedekler sayfasını açın:** panelin üstündeki *Araçlar* satırındaki
   **Yedekler** bağlantısı, ya da doğrudan `https://<sunucu>/yedekler`.
2. **Motorun satırını bulun.** En yeni kopyaya dönmek için **Son yedeğe dön**
   yeter. Belirli bir güne dönecekseniz **Yedekleri göster** ile dosya
   listesini açın ve o tarihteki satırın **Bu yedeğe dön** düğmesini
   kullanın — "son yedek" her zaman istenen yedek değildir: veriyi bozan
   işlem dün öğlen olmuşsa dönülecek yer ondan **önceki** kopyadır.
3. **Onay penceresini okuyun.** Pencere ne olacağını açıkça yazar: o motordaki
   **mevcut veriler silinir**, veritabanı dosyadaki hâline döner ve o
   tarihten sonra yazılan her şey kaybolur. Dönülecek dosyanın adı, tarihi,
   yaşı ve boyutu da orada — hangi yedeğe döndüğünüzü iş bittikten sonra
   öğrenmeyesiniz diye.
4. **Motorun adını elinizle yazın.** **Geri Yükle** düğmesi doğru yazılana
   kadar kapalıdır (büyük/küçük harf aranmaz). Bu, terminalde `evet` yazarak
   verdiğiniz onayın karşılığıdır: yan yana duran düğmeler arasından
   yanlışına basarak tetiklenebilecek bir işlem olmasın diye.
5. **İş penceresini izleyin.** Betiğin çıktısı canlı akar. Pencereyi
   kapatsanız da iş sunucuda devam eder; sonucu panelin olay akışında da
   görürsünüz.

Panelden geri yüklenemeyen bir motorda düğme tıklanmaz ve sebebini söyler
("Bu motorda panelden geri yükleme yok"). Motor kapalıyken ya da o sırada bir
yedekleme sürerken de kapalıdır; ikisinde de sebep düğmenin üstünde yazar.

Motor **açık** olmalıdır: geri yükleme araçları da tıpkı dump araçları gibi
çalışan veritabanına bağlanır (Redis'te veri dosyası değiştirilip motor
yeniden başlatılır). Kapalı bir motoru önce yönetim panelinden **Aktif Et**
ile açın.

Otomasyon yazacaklar için panelin kullandığı uç:

```
POST /api/engines/<motor>/restore
{"file": "<dosya adı>"}          →  {"job": "<iş kimliği>"}
```

Gövde dosyanın **yolunu değil adını** taşır ve ad `backups/<motor>/` altında
çözülür: dizin ayracı, `..` ve dizinin dışına çıkan sembolik linkler
reddedilir, yalnız `.gz` kabul edilir. Bu bir biçim titizliği değil — bu uca
verilen dizge, veritabanının **üstüne yazılacak** dosyayı seçiyor.

O sırada başka bir yedekleme ya da geri yükleme sürüyorsa iş **ertelenir** ve
bunu açıkça söyler: veriye hiç dokunulmamıştır, bekleyip tekrar denersiniz.

### Komut satırından

```bash
./stack.sh restore mariadb    backups/mariadb/full/mariadb_full_20260901_020000.sql.gz
./stack.sh restore postgresql backups/postgresql/full/...
./stack.sh restore mongodb    backups/mongodb/full/...
./stack.sh restore redis      backups/redis/full/...
./stack.sh restore mssql      backups/mssql/full/...
```

Her geri yükleme `evet` yazarak onay ister. Otomasyonda atlamak için:
`ASSUME_YES=yes`.

### Önce doğrulama, sonra silme

Geri yükleme mevcut veriyi **silerek** başlar. Bu yüzden dosya, silme
başlamadan önce açılıp içeriği sınanır; geçemezse işlem hiç başlamaz ("Bu
dosyayla geri yükleme yapılmaz"). Boş ya da kesik bir yedekle başlanan geri
yükleme veriyi geri getirmez, yalnızca yok eder.

Şifreli dosyada aynı kontrol **şifre çözmeyi de** kapsar: anahtar eksik ya da
yanlışsa geri yükleme hiç başlamaz ve veriye dokunulmaz. Anahtarı yedeği
silmeden *sonra* aramak zorunda kalmamanız için bu sıra bilerek böyle.

Aynı sebeple geri yükleme, yedeklemeyle **aynı kilidi** tutar. Kilitsizken
02:00 cron'u, yarım geri yüklenmiş bir veritabanını (bazı tablolar yeni,
bazıları DROP edilmiş) döküp "geçerli yedek" diye saklıyor ve uzağa
senkronluyordu.

### Redis geri yüklemesindeki tuzak

AOF (append-only file) açıkken Redis açılışta `dump.rdb` dosyasını **değil**
AOF'u okur. Sadece `dump.rdb`'yi değiştirip yeniden başlatmak "başarılı" der
ama hiçbir şey geri yüklemez. Betik doğru sırayı uygular:

1. AOF'u kapat
2. RDB'yi yerine koy, eski AOF dosyalarını sil
3. Yeniden başlat — Redis artık RDB'den yükler
4. AOF'u tekrar aç ve `BGREWRITEAOF` ile yeni veriden üret

### PostgreSQL: neden `ON_ERROR_STOP` yok

`pg_dumpall --clean` çıktısı, bağlı olunan rolü ve veritabanını da düşürmeye
çalışır; bu iki hata normaldir ve zararsızdır. `ON_ERROR_STOP=1` ile psql tam
o noktada durur — yani diğer veritabanları çoktan düşürülmüşken. Elde ne eski
veri ne yenisi kalır. Betik bunun yerine hataları toplar, beklenenleri eler ve
geriye gerçek bir hata kalıp kalmadığına bakar.

### SQL Server

`master` ve `msdb` yedeklenir ama otomatik geri yüklenmez — sistem
veritabanlarının geri yüklenmesi tek kullanıcı modu gerektirir. SQL login'leri
kaybolduysa bunları elle geri yükleyin.

---

## Kesintisiz geri yükleme (gölge)

Klasik geri yükleme **tek yönlü bir kapıdır**: mevcut veri silinir, dosya
basılır ve iş yarıda kalırsa elde ne eskisi ne yenisi kalır. Kesinti de
geri yüklemenin tamamı kadar sürer.

Gölge yolu aynı işi iki yönlü yapar:

1. yedek **yeni bir hacme** geri yüklenir — üretim bu sırada çalışmaya
   devam eder,
2. kopyanın gerçekten açıldığı ve satır sayısı doğrulanır,
3. işaretçi çevrilir — kesinti yalnız **container yeniden yaratılırken**,
4. eski hacim **geri dönüş bileti** olarak 24 saat durur.

Ölçülen değerler (256 MB veri, tek sunucu): geri yükleme 35 sn, kesinti
**3,6 sn**. İkisi ayrı raporlanır; "10 kat hızlı" gibi bir cümle geri
yükleme süresini değil kesintiyi anlatır.

Panelden: yedek satırındaki **Kesintisiz dön**. Komut satırından yalnız
hazırlık kısmı çalıştırılabilir (takası controller yapar):

```bash
./scripts/restore-drill.sh mariadb --golge
```

**Bedeli açıkça söylenir:** takasa kadar üretim bugünkü (belki bozuk) veriyi
servis etmeye devam eder ve diskte bir kopyalık fazladan yer gerekir. Yer
yetmiyorsa işlem başlamadan sayıyla reddedilir: "1777 MB gerekiyor, 204899 MB
boş".

**Kapsam:** yalnız otomatik geri yüklemesi olan beş motorda. Replikası açık
bir motorda takas **reddedilir** — takas ana kopyanın geçmişini değiştirir ve
replika o anda ayrışır; sessizce bozmaktansa reddetmek doğrudur.

### Geri dönüş bileti

Takastan sonra eski hacim silinmez, 24 saat saklanır. Karar yanlışsa panelden
**Takas öncesine dön** tek düğmedir ve kesinti yine saniyeler sürer. Süre
dolunca eski hacim **olayla** silinir — sessizce değil, çünkü kullanıcının
"geri dönebilirim" sandığı bir kapı kapanıyor.

Bilet açıkken ikinci bir takas kabul edilmez: iki takas üst üste yapılırsa
"geri dön" dendiğinde hangi geçmişe dönüleceği belirsizleşir.

### İşaretçi ayrışması

Takas yarıda kalırsa `state/volumes.env` bir kopyayı gösterirken container
başkasını bağlamış olabilir. Motor sağlıklı görünür ve kimse hata görmez.
Bu yüzden canlı hacim **dosyadan değil container'dan ölçülür**; ikisi
ayrışırsa panel bunu söyler. "Ölçemedim" ile "ayrışma yok" ayrı iki cevaptır:
motor kapalıysa ürün ikincisini iddia etmez.

## Şema parmak izi

Kurtarma provası uzun süre yalnız **tablo ve satır** saydı. İndeks, kısıt,
view, trigger ve rutin kaybı bu ölçütten sessizce geçiyordu — yani "prova
geçti" rozeti, göremediği bir şeyi iddia ediyordu.

Artık iki ölçüt var:

- **Nesne sayımı:** prova, geri yüklenen kopya ile üretimi beş türde
  karşılaştırır (indeks, kısıt, view, trigger, rutin) ve farkı yazar. Fark
  tek başına başarısızlık değildir — yedek alındıktan sonra şema değişmiş
  olabilir; sessiz kalmak hataydı.
- **Parmak izi:** veritabanının şekli tek bir hash'e indirilir ve **yedek
  alınırken** kaydedilir. Prova, geri yüklenen kopyanın parmak izini o kayıtla
  karşılaştırır. Sorulan soru şu: *elimdeki bu dosya hangi şemayı geri
  getirir?*

```bash
./scripts/schema.sh postgresql
```

Parmak izine **veri girmez**: bir milyon satır eklemek onu değiştirmemelidir.
MariaDB'de `SHOW CREATE TABLE` bilerek kullanılmaz (`AUTO_INCREMENT` sayacını
taşır), sequence'ın tanımı girer ama anlık değeri girmez, listeler sıralanır.
Biçim sürümlüdür; farklı sürümlerin parmak izleri karşılaştırılmaz, çünkü
karşılaştırmak dev bir sahte fark üretirdi.

Yedek **alınırken** şema değişirse (DDL) kayıt "kararsız" işaretlenir:
dosyanın hangi şemayı taşıdığı kesin değildir ve ürün bunu saklamaz.

Panelde her yedek dosyasının yanında kısa parmak izi görünür; balonunda o
dosyanın kaç tablo, kaç indeks, kaç kısıt içerdiği yazar.

## Kurtarma noktası setleri

Bir uygulama çoğu zaman tek veritabanı kullanmaz. Yedekler motor motor ve
dakikalar arayla alındığı için "dün geceye dön" demek, elde birbirinden uzak
birkaç **an** bırakır.

Set, seçilen motorların yedeğini **tek tur** olarak alır ve şunu ölçer:

- **pencere**: setteki en eski ve en yeni dosya arasındaki fark. Sıfır
  değilse bu bir an değil bir aralıktır,
- **hedef an**: turun bittiği an,
- motor başına **hedeften kaç saniye geride** kalındığı.

Geri yüklerken zamanda geri dönmesi (PITR) açık olan motorlar hedef ana
**ileri sarılarak** tam oturur; diğerleri kendi dosyalarının anına döner.
Rapor bunu olduğu gibi söyler: *"üç motor hedef anda, iki motor 252 sn
geride"*.

**Vaat edilmeyen şey:** heterojen motorlarda, yazmayı durdurmadan gerçek bir
anlık görüntü alınamaz. Ürün "hepsi aynı ana geldi" demez; ne kadar
yaklaşıldığını sayıyla söyler.

Tur **sırayla** koşar. Paralel almak pencereyi daraltırdı ama aynı sunucuda
iki ağır dump, aynı cgroup'ta çift bellek baskısı demektir; pencereyi
daraltmanın doğru yolu paralellik değil, PITR ile ileri sarmaktır.

Dosyaları saklama temizliğine takılmış bir nokta **dönülebilir görünmez**:
panel eksik dosya sayısını yazar ve düğmeyi kapatır.

## Uzak depo

`.env` içinde `REMOTE_SYNC_ENABLED=true` yapıp rclone'u yapılandırın.
Google Drive, S3, Backblaze, SFTP — rclone'un desteklediği her hedef çalışır.
Kurulum: [GOOGLE-DRIVE.tr.md](GOOGLE-DRIVE.tr.md)

```bash
./scripts/sync-remote.sh test     # bağlantı testi
./scripts/sync-remote.sh plan     # NE gidecek, ne gitmeyecek (uzağa dokunmaz)
./scripts/sync-remote.sh          # gönder
./scripts/sync-remote.sh status   # yerel/uzak karşılaştırma
```

Uzak saklama süresi `RETENTION_REMOTE_DAYS` (varsayılan 30 gün) ile ayarlanır;
yerel saklama `RETENTION_DAYS` (varsayılan 7 gün).

### Şifreleme kapısı

Uzak depo, [yedek şifrelemesinin](#yedek-şifreleme) asıl sebebidir; bu yüzden
gönderim kararı şifreleme durumuna bağlı:

| Şifreleme | Ne olur |
|---|---|
| **Açık** | Yalnız `*.gz.enc` gönderilir. Şifresiz `*.gz` dosyalar **gönderilmez**; kaç tanesinin atlandığı ekrana yazılır. |
| **Kapalı** | Gönderim yapılır ama her koşumda **uyarı basılır** — dökümü şifrelemeden binadan çıkarmak sessizce yapılacak bir iş değil. |
| **Bozuk** (anahtar var, `openssl` yok / anahtar dosyası okunamıyor) | **Hiçbir şey gönderilmez.** O durumda üretilen yedeklerin şifreli olduğunu söyleyemeyiz. |

Şifreleme açıldıktan **önce** alınmış şifresiz kopyalar bir daha uzağa gitmez.
Bu doğru davranıştır: uzakta duran en eski şifresiz kopya bile aynı tabloları
taşır, yani onu göndermek şifrelemeyi açmayı anlamsız kılardı. Şifreli bir
kopya için o motorun yedeğini yeniden alın.

Ne gideceğini gönderimden **önce**, uzak depoya hiç dokunmadan görmek için:

```bash
./scripts/sync-remote.sh plan
```

`.bozuk` dosyalar her iki durumda da gönderilmez — onlar kurtarma noktası
değil, doğrulamayı geçemediği için kenara alınmış dosyalardır.
