# Yedekleme

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

Yalnız `*.gz` dosyaları sayılır. Doğrulamayı geçemeyip `.bozuk` uzantısıyla
kenara alınmış dosyalar kurtarma noktası **değildir**; onları saymak panelde
"3 yedeğiniz var" yazdırıp elde hiç yedek olmaması demek olurdu.

---

## Komut satırı

```bash
./stack.sh backup                # aktif motorların hepsi (kapalılar atlanır)
./stack.sh backup mariadb        # tek motor
./scripts/backup.sh list         # yedekleri listele
./scripts/backup.sh stats        # boyut, adet, en son ne zaman
./scripts/backup.sh clean 7      # 7 günden eskileri sil
./scripts/backup.sh verify <dosya>
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
