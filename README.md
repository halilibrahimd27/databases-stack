<div align="center">

# 🗄️ databases-stack

### *Tek sunucuda 12 veritabanı — istediğini aç, istemediğini kapat*

**Panelden düğmeye bas, veritabanın açılsın.** Sistem sunucunun belleğini ölçer,
o veritabanına ne kadar ayıracağını ve iç ayarlarını kendisi hesaplar.
Sen hiçbir teknik değer girmezsin.

**Ana kopya çökerse yedeğe kendisi geçer** — uygulamanın bağlantı adresi değişmeden.

[![Docker](https://img.shields.io/badge/Docker-Compose-2496ed?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-hazır-326ce5?style=flat-square&logo=kubernetes&logoColor=white)](docs/KUBERNETES.md)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)

</div>

---

## Nasıl görünüyor?

<div align="center">
<img src="ss/01-panel.png" alt="Yönetim paneli" width="900">
</div>

Sayfa iki bölgeden oluşur. Üstte **şu an açık** olanlar kart hâlinde: ne kadar
bellek aldıkları, hangi porttan bağlanılacağı, yedek kopyası ve otomatik devri
var mı. Altta **kapalı** olanlar tek satır — hiç kaynak harcamıyorlar, bir
kartı hak etmiyorlar. Satıra tıklayınca ne işe yaradığı, tahmini belleği ve
lisansı açılır.

Üst bardaki sayı *ayrılan* belleği gösterir (motorlara söz verilen tavan),
altında da sunucunun toplam RAM'i ve **gerçek** kullanımı. İkisi farklıdır ve
fark önemlidir: tavanlar rezervasyon değil üst sınırdır.

<div align="center">
<img src="ss/03-islemler.png" alt="Geri dönüşü zor işlemler kapalı bir bölümde" width="900">
</div>

Gündelik işler kartın yüzünde (paneli aç, bağlantı bilgisi). **Geri dönüşü zor
olanlar** — kapatmak, yedek kopyayı kaldırmak, otomatik devri kapatmak —
kapalı bir bölümde ve her biri **ne olacağını tek cümleyle** söylüyor. Yan yana
duran altı düğme arasından yanlışına basmak bu üründe mümkün değil.

<div align="center">
<img src="ss/05-izleme.png" alt="Grafana panoları" width="900">
</div>

İzleme ayrı bir kurulum değil, panelden açılan bir modül: **İzleme aç** deyince
Prometheus + Grafana kalkar, açık olan her motorun exporter'ı hedef listesine
kendiliğinden eklenir ve **11 hazır pano** gelir — hepsi Türkçe ve "her şey
yolunda mı?" sorusuna cevap verecek şekilde yazılmış. Tek bir PromQL sorgusu
yazmanız gerekmez; kapattığınızda da hedef listesinden kendiliğinden çıkar.

<div align="center">
<img src="ss/04-olaylar.png" alt="Son olaylar" width="900">
</div>

Panelin altında **ne olduğu yazıyor**: hangi motor ne zaman açıldı, ne kadar
bellek ayrıldı, hangi ayar hesaplandı, bir aktivasyon neden reddedildi, otomatik
devir ne zaman ve **hangi sebeple** çalıştı. Sunucuya girip `docker logs`
okumadan olan biteni buradan takip edersiniz.

<div align="center">
<img src="ss/02-kurulum.png" alt="Sertifika kurulum rehberi" width="620">
</div>

İç ağda alan adı olmadığı için TLS sertifikasını sunucu kendisi üretir.
Tarayıcının "güvenli değil" uyarısını kaldırmak için **tek seferlik** bu rehber
adım adım anlatır — sertifikayı kurduktan sonra sayfa sizi otomatik panele
geçirir. Panele bir kez girdiğinizde bütün yönetim ekranları (phpMyAdmin,
pgAdmin, Grafana…) parola sormadan açılır; dışarıdan doğrudan gelen biri ise
hâlâ parola ekranıyla karşılaşır.

---

## Kurulum

**Önkoşul:** Docker (yoksa `install.sh` size kurulum komutunu verir):

```bash
curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER && newgrp docker
```

Sonra:

```bash
sudo mkdir -p /opt/databases && sudo chown $USER:$USER /opt/databases
git clone https://github.com/halilibrahimd27/databases-stack.git /opt/databases
cd /opt/databases && ./install.sh
```

Bu kadar. Soru sormaz. Parolaları, TLS sertifikalarını ve sunucu adresini kendisi
üretir/algılar, sonuçları ekrana ve `credentials.txt`e yazar.

Sonra tarayıcıdan `https://<sunucu-ip>/` adresine gidin ve ihtiyacınız olan
veritabanının satırındaki **Aktif Et** düğmesine basın.

> **Tarayıcı "güvenli değil" diyorsa:** `http://<sunucu-ip>/ca.crt` adresinden
> sertifikayı indirip bilgisayarınıza kurun, uyarı kalkar. Bu iç ağa özel bir
> sertifika otoritesidir — alan adı (domain) gerektirmez, internete çıkmaz.

---

## Nasıl çalışıyor?

Kurulumdan sonra **hiçbir veritabanı çalışmıyor.** Sadece üç küçük servis ayakta:
giriş kapısı (nginx), kontrol servisi ve Adminer. Toplam ~450 MB.

Panelde bir veritabanını açtığınızda arka planda şunlar olur:

```
"Aktif Et"  →  Kontrol servisi sunucuyu ölçer
                 ├─ Toplam RAM, boş RAM, boş disk, CPU
                 ├─ Zaten açık veritabanlarının taahhüdü
                 └─ İşletim sistemi ve çekirdek servisler için ayrılan pay
                             ↓
               Bütçe yetiyor mu?
                 ├─ HAYIR → açmaz, sebebini sade dille söyler
                 └─ EVET  → limiti ve motorun iç ayarlarını hesaplar
                             (buffer pool, JVM heap, WiredTiger cache,
                              max_connections, work_mem …)
                             ↓
               docker compose --profile <motor> up -d
```

**Kapalı bir veritabanı hiç container yaratmaz** — sıfır RAM, sıfır CPU tüketir.
Kapatmak verileri silmez; diskte kalır, tekrar açtığınızda her şey yerindedir.

### Bunun neden önemli olduğu

Aynı hesabın somut karşılığı:

| Sunucu | MariaDB açılırsa | Elasticsearch açılırsa |
|---|---|---|
| 512 MB | **açılmaz** — "en az 512 MB gerekiyor, bütçe 0 MB" | açılmaz |
| 2 GB | 512 MB limit, panelsiz (Adminer'ı kullanın) | açılmaz |
| 4 GB | 1.2 GB limit, buffer pool 736 MB | 1 GB limit, JVM heap 512 MB |
| 16 GB | 4.8 GB limit, buffer pool 2.9 GB | 4 GB limit, JVM heap 2 GB |
| 128 GB | 16 GB limit (tek motor sunucuyu yutmasın) | 16 GB limit, heap 8 GB |

4 GB'lık makinede 16 GB'lık veritabanı açılmaya çalışılmaz; 128 GB'lık makinede
de varsayılan değerlerde kalınmaz. Bütçe dolduğunda kart pasifleşir ve
"MongoDB en az 512 MB ister, kullanılabilir bütçe 380 MB — başka bir motoru
durdurun" der.

Hesabı görmek için: `./stack.sh plan mongodb`

---

## İçindeki veritabanları

Hepsi kapalı gelir; yalnız kullandıklarınız açılır.

| | Veritabanı | Ne için | Panel |
|---|---|---|---|
| 🐬 | **MariaDB** | Klasik tablolu veri — kullanıcılar, siparişler, ürünler | phpMyAdmin |
| 🐘 | **PostgreSQL** | Aynı iş + JSON, konum verisi, karmaşık sorgular | pgAdmin |
| 🍃 | **MongoDB** | Sabit şeması olmayan kayıtlar | Mongo Express |
| 🔴 | **Redis** | Önbellek, oturum, kuyruk (kalıcı depo değil) | RedisInsight |
| 🟥 | **SQL Server** | .NET / Windows tabanlı kurumsal uygulamalar | Adminer |
| 🌀 | **Cassandra** | Çok yüksek yazma hacmi, lineer ölçek | cqlsh |
| 🔎 | **Elasticsearch** | Site içi arama, log analizi | Kibana |
| 📨 | **Kafka** | Servisler arası olay akışı | Kafka UI |
| 🐰 | **RabbitMQ** | Basit iş kuyruğu (Kafka'dan çok daha kolay) | Management UI |
| 📊 | **ClickHouse** | Rapor ve analiz sorguları (OLAP) | Play UI |
| 🕸️ | **Neo4j** | İlişki ağırlıklı veri, öneri motorları | Neo4j Browser |
| 🪣 | **MinIO** | Dosya/görsel depolama (S3 uyumlu) | MinIO Console |

> Ne seçeceğinizi bilmiyorsanız: **PostgreSQL** (verileriniz için) +
> **Redis** (hız için) çoğu proje için doğru başlangıçtır.

---

## Erişim

Tek giriş kapısı var; **hiçbir panelin portu doğrudan dışarı açılmaz.**
Hepsi TLS + parola arkasından geçer.

| Adres | Ne |
|---|---|
| `https://<sunucu>/` | Yönetim paneli |
| `https://<sunucu>:8081…8091` | Veritabanı panelleri (kapalıysa "pasif" sayfası) |
| `https://<sunucu>:9443/metrics/<motor>` | Prometheus metrikleri |
| `<sunucu>:3306, 5432, 27017 …` | Uygulamanızın bağlanacağı veritabanı portları |

Veritabanı portları da gateway üzerinden geçer. Bu iki şey sağlar: devirde
bağlantı adresiniz değişmez, ve container'lar host'a doğrudan port açmaz.

Bağlantı bilgisini panelden **Bağlantı bilgisi** düğmesiyle ya da
`./stack.sh conn postgresql` ile kopyalayabilirsiniz.

---

## Terminalden

Panelin yaptığı her şeyi yapar; aynı otomatik boyutlandırma çalışır.

```bash
./stack.sh list                  # motorlar, durumları, tahmini bellek
./stack.sh enable postgresql     # aç
./stack.sh plan elasticsearch    # açılsa ne kadar ayrılırdı?
./stack.sh disable redis         # kapat (veri silinmez)
./stack.sh conn mariadb          # bağlantı bilgisi
./stack.sh replica on postgresql # yedek kopya kur
./stack.sh backup                # aktif motorların hepsini yedekle
./stack.sh app-user              # uygulama için kısıtlı kullanıcı
./stack.sh doctor                # kurulum sağlık kontrolü
```

---

## Yedekleme

```bash
./stack.sh backup                # aktif motorlar (kapalı olanlar atlanır)
./stack.sh backup mariadb        # tek motor
./scripts/backup.sh list         # yedekleri listele
./stack.sh restore mariadb backups/mariadb/full/mariadb_full_20260901.sql.gz
```

**Zamanlama panelden yönetilir.** Panelin altındaki *Yedekler* bölümünden
açarsınız: saat, saklama süresi ve son koşunun sonucu orada. Zamanlayıcı
controller'ın içinde çalışır — host'ta root yetkisi, cron kurulumu ya da
systemd birimi gerektirmez.

> Bu, ölçülmüş bir arızanın sonucudur. Önceden `install.sh` yalnız
> `state/crontab` dosyasını *üretiyor* ve "yüklemek için `crontab state/crontab`"
> diyordu. Kimse yapmıyordu: test sunucusunda `crontab -l | grep backup` sıfır
> satır, `backups/` altındaki klasörler boştu. Yani yedek alındığı sanılırken
> hiç alınmıyordu — bir yedekleme sisteminin verebileceği en kötü sonuç.
> `./stack.sh doctor` artık zamanlama kapalıysa bunu açıkça söylüyor.

Her motorun kartında ve *Yedekler* bölümünde **"Yedek al"** düğmesi var; elle
alınan yedek gecelik turu iptal etmez, ek bir kurtarma noktası oluşturur.
Listede her dosyanın tarihi, boyutu ve **kaynağı** yazar: `elle`, `zamanlı`
ya da `dış` (host cron'u veya komut satırı).

Host cron'unu tercih ederseniz `state/crontab` hâlâ üretiliyor; ikisi birlikte
koşarsa `backup.sh` kendi kilidiyle çakışmayı önler.

Geri yükleme **panelde yoktur** ve bu bilerek: veriyi silip yerine koyan bir
işlemdir, sunucuda bilerek çalıştırılır (yukarıdaki `restore` komutu).

Ayrıntı ve motor başına yöntemler: [docs/BACKUP.md](docs/BACKUP.md).
Uzak depo (Google Drive / S3 / SFTP): [docs/GOOGLE-DRIVE.md](docs/GOOGLE-DRIVE.md).

---

## İzleme

Açtığınız veritabanlarının nasıl çalıştığını grafiklerle gösterir. Kurulum ya
da yapılandırma gerektirmez:

```bash
./stack.sh enable monitoring     # ya da panelden "İzleme" kartındaki Aktif Et
./stack.sh panel monitoring      # adresi yazar
```

Motor başına hazır panolar gelir: kaç bağlantı var, saniyede kaç işlem
düşüyor, önbellek işe yarıyor mu, yedek kopya geride mi. Her panelin altında
**ne anlama geldiği ve ne zaman endişelenmeniz gerektiği** yazar — veritabanı
yönetmeyi bilmeden de okunabilsin diye.

Genel Bakış panosu bu ürün için ayrıca önemli: yığın belleği otomatik
hesaplayıp dağıtıyor, bu panoda her container'ın *gerçekte* ne kadar
kullandığını ayrılan limitle yan yana görürsünüz — yani hesabın doğru olup
olmadığını gözünüzle doğrularsınız.

Hedef listesi elle yazılmaz: bir motoru açıp kapattığınızda liste kendiliğinden
güncellenir. Kapalı motor listede olmadığı için "erişilemiyor" uyarısı da
yağmaz — kapalı olmak arıza değildir.

Kapalıyken hiçbir container çalışmaz. Açıkken ~830 MB RAM ister; sunucuda yer
yoksa diğer motorlar gibi **açılmaz ve sebebini söyler**.

Ayrıntı: [docs/MONITORING.md](docs/MONITORING.md).

---

## Yedek kopya (master-slave)

Panelde ilgili kartın altındaki **Replika kur** düğmesi, ya da:

```bash
./stack.sh replica on postgresql
```

| Motor | Yöntem | Kesinti |
|---|---|---|
| PostgreSQL | streaming replication (`pg_basebackup`) | yok |
| MariaDB | GTID tabanlı asenkron replikasyon | yok |
| Redis | `replicaof` | yok |
| MongoDB | replica set (rs0) | **var** — primary yeniden başlar |
| Cassandra / Kafka / Elasticsearch | motorun kendi kümeleme mantığı | — |

Ayrıntı: [docs/REPLICATION.md](docs/REPLICATION.md)

---

## Otomatik devir (failover)

Yedek kopyayı kurduktan sonra tek bir düğme daha:

```bash
./stack.sh failover on postgresql
```

Sistem ana kopyayı 10 saniyede bir yoklar. Üst üste 3 kez yanıt alamazsa:

1. **Eski ana kopyayı durdurur** — iki kopyanın aynı anda yazı kabul edip
   verilerin ayrışmasını (split-brain) önlemek için zorunlu adım
2. **Yedeği ana kopya yapar** (yazmaya açar)
3. **Yönlendirmeyi günceller** — uygulamanız aynı adrese bağlanmaya devam eder
4. **Olayı kaydeder** ve tanımlıysa webhook bildirimi gönderir

Bunun çalışabilmesi için tüm veritabanı portları gateway üzerinden geçer:

```
uygulama → gateway:5432 → (o an ana kopya olan neyse)
```

Uygulamanız doğrudan container'a bağlansaydı, devirden sonra ölü sunucuya
bağlanmaya devam ederdi — yani devir otomatik olmazdı.

```bash
./stack.sh failover status        # durum ve devir geçmişi
./stack.sh failover now <motor>   # elle devir (bakım/test)
./stack.sh failover rebuild <m>   # eski kopyayı yedek olarak geri al
./stack.sh events                 # olay akışı
```

| Motor | Devir yöntemi |
|---|---|
| PostgreSQL | `pg_ctl promote` |
| MariaDB | relay log boşaltılır → `RESET SLAVE ALL` → yazmaya açılır |
| Redis | `REPLICAOF NO ONE` |
| MongoDB | replica set kendi seçimini yapar (arbiter ile 3 oy) |

Ayrıntı, test yöntemi ve sınırlar: [docs/FAILOVER.md](docs/FAILOVER.md)

---

## Kubernetes

Aynı ürün, aynı mantık: **"aktif et" = StatefulSet'i 0'dan 1 replikaya
ölçeklemek.** Manifestler katalogdan üretilir, elle yazılmaz.

```bash
python3 scripts/gen-k8s.py --with-secrets
kubectl apply -k k8s/base
```

Kontrol servisinin K8s'teki tek yetkisi StatefulSet'leri okumak ve
ölçeklemek/boyutlandırmaktır — Docker kurulumundaki docker soketi erişiminden
(host'ta tam yetki) belirgin şekilde dardır.

Ayrıntı: [docs/KUBERNETES.md](docs/KUBERNETES.md)

---

## Yapı

```
databases-stack/
├── install.sh              Tek komutluk kurulum
├── stack.sh                Günlük kullanım CLI'ı
├── catalog.json            ⭐ Motor kataloğu — TEK YETKİ KAYNAĞI
├── docker-compose.yml      Tüm motorlar, profil tabanlı
├── controller/             Kontrol düzlemi (aktivasyon + boyutlandırma)
├── gateway/                nginx: TLS, auth, reverse proxy, dashboard
├── config/                 Motor konfigürasyonları (my.cnf vb.)
├── scripts/                backup, sync, kullanıcı, sertifika, replikasyon, devir
├── overrides/              Duruma göre yüklenen compose parçaları
├── k8s/                    Üretilmiş Kubernetes manifestleri
└── docs/                   Ayrıntılı belgeler
```

**Yeni bir veritabanı eklemek** = `catalog.json`a bir kayıt + `docker-compose.yml`e
aynı profile sahip servisler. `./scripts/check-catalog.sh` ikisinin ayrışmadığını
doğrular; `./stack.sh doctor` bunu otomatik çağırır.

---

## Güvenlik

- Panel portları host'a açılmaz; tek giriş kapısı TLS + basic auth arkasındadır
- Her motorun **ayrı** parolası vardır (tek sızıntı 12 motoru açmaz)
- Kontrol servisinin portu yoktur; yalnız gateway'den, paylaşılan token ile erişilir
- Parolalar hiçbir betikte komut satırına yazılmaz (`ps` çıktısında görünmez)
- `./stack.sh app-user` ile uygulamanız için `DROP` yetkisi olmayan kullanıcı

> ⚠️ Bu ürün **iç ağ / VPN arkası** kullanım için tasarlandı. Veritabanı
> portlarını internete açmayın.

Ayrıntı ve sertleştirme adımları: [docs/SECURITY.md](docs/SECURITY.md)

---

## Nasıl doğrulanıyor

Bu ürünün iddiaları ölçülüyor. Depoda iki katman var:

```bash
./stack.sh selftest    # docker gerektirmez — boyutlandırma, API, nginx, betikler
./stack.sh e2e         # ÇALIŞAN kuruluma karşı — sekiz paket, ~300 kontrol
./stack.sh e2e --hepsi # Kubernetes dahil
```

`selftest` docker'ı taklit eder; hızlıdır ve mantık hatalarını yakalar. Ama
taklit edilen bir docker, gerçek bir container'ın yapmadığını yapmaz. Bu
yüzden ikinci katman var ve **çalışan sisteme** soruyor: veri yazılıp geri
okunuyor mu, ana kopya öldürülünce uygulama **aynı adrese** yazmaya devam
ediyor mu, alınan yedek gerçekten geri yükleniyor mu, her panonun her sorgusu
veri döndürüyor mu.

| Paket | Ne kanıtlar |
|---|---|
| `security` | Panel/API/metrik parolası, tek oturum, çapraz-site koruması |
| `sizing` | Hesaplanan limit gerçekten uygulanmış mı, bütçe dolunca reddediyor mu |
| `replication` | Replika akıyor, salt-okunur, kapatınca kalıntı bırakmıyor |
| `failover` | Ölüm → devir → **aynı adresten yazma** → veri kaybı yok |
| `backup` | Yedek al → **veriyi sil** → geri yükle → veri geri geldi |
| `monitoring` | Hedefler, metrikler, **her panonun her sorgusu** |
| `lifecycle` | Aç/kapat/aç — kapatınca veri silinmiyor |
| `k8s` | Ayarlar pod içinde uygulanıyor mu (k3s açar ve sonunda kapatır) |

**Sonuç türü üç değil dört:**

| | Anlamı | Çıkış koduna etkisi |
|---|---|---|
| `GEÇTİ` / `BAŞARISIZ` | Ölçtük | — / 1 |
| `ATLANDI` | Ön koşul yok (motor kapalı) — meşru | yok |
| `ÖLÇÜLEMEDİ` | Sorgu düştü, docker cevap vermedi | **1** |

Son satır kasıtlı: *"bilmeyi başaramadık" ile "iyi durumda" aynı şey değildir.*
Aynı sebeple **hiçbir kontrol çalışmadıysa çıkış 2**, ölçülenden çok atlama
varsa **çıkış 3** — "0/0 geçti" diyerek yeşil görünen bir test, hiç olmayan
testten kötüdür.

Bu paket yazıldığı gün ürünün kendisinde altı gerçek hata buldu; dördü ancak
sıfırdan kurulmuş, gerçekten çalışan bir sistemde görülebilirdi. Her biri için
teste kalıcı bir koruma eklendi ve **korumanın bozuk hâli gerçekten yakaladığı**
ayrıca sınandı.

---

## Kapsam — dürüstçe

Otomatik devir **süreç düzeyindeki** arızaları karşılar: veritabanının çökmesi,
kilitlenmesi, OOM ile öldürülmesi, veri dosyasının bozulması. Bunlar pratikte
en sık yaşanan arızalardır ve sistem bunları ~30 saniyede kendisi kapatır.

Aynı ürün, ikinci bir makine eklendiğinde **host arızasını** da karşılar:
yedek kopyayı uzak bir Docker host'unda ya da Kubernetes'te node
anti-affinity ile çalıştırın (bkz. [docs/FAILOVER.md](docs/FAILOVER.md)).
Tek makinede çalıştırdığınız sürece, makinenin tamamı düşerse iki kopya da
düşer — bu bir eksiklik değil, tek makine olmanın tanımıdır.

Bilmeniz gerekenler:

- **Replikasyon asenkrondur.** Devirde, ana kopyanın göndermeye yetişemediği
  son işlemler kaybolabilir (tipik olarak milisaniyeler). Sıfır kayıp için
  senkron replikasyon nasıl açılır: [docs/FAILOVER.md](docs/FAILOVER.md)
- **Devir yedeğin yerini tutmaz.** Yanlışlıkla silinen veri replikaya da
  anında yansır. Düzenli yedek şart → [docs/BACKUP.md](docs/BACKUP.md)
- Veritabanı portları gateway üzerinden geçtiği için motorlar istemcinin
  gerçek IP'sini değil gateway'in IP'sini görür — host tabanlı yetkilendirme
  (`user@'192.168.1.5'`) kullanıyorsanız buna göre ayarlayın.
- Neo4j Community'de çevrimiçi yedek yoktur — yedek almak veritabanını durdurur.
- Kafka yedeklenmez (log'dur, veritabanı değil); `replication.factor` kullanın.
- MongoDB replica set açmak ana kopyayı yeniden başlatır (kısa kesinti).

---

## Lisanslar

Bu proje MIT'tir ve motorları **yeniden dağıtmaz** — resmi kayıt defterlerinden
çeker. Yani her motorun lisansı doğrudan sizinle motorun sahibi arasındadır.
Panelde her kartın altında lisans görünür, kısıtlı olanlarda aktivasyon
onayında uyarı çıkar.

```bash
./stack.sh licenses
```

Çoğu motor iç kullanımda sorunsuzdur. İki başlık dikkat ister:

- **SQL Server** varsayılan olarak **ücretsiz Express** sürümüyle gelir ve
  üretimde de kullanılabilir; sınırı veritabanı başına 10 GB ve ~1.4 GB tampon
  havuzudur. Tüm özellikler gerekiyorsa `MSSQL_PID=Developer` ücretsizdir ama
  **yalnız geliştirme/test** içindir; üretimde Standard/Enterprise lisansı ister.
- **MongoDB (SSPL), Elasticsearch (ELv2/SSPL), Redis, Neo4j, MinIO (AGPL)**
  copyleft lisanslıdır. Kendi uygulamanız için kullanmak serbesttir; bu
  motorları üçüncü taraflara **yönetilen servis olarak satarsanız** kaynak açma
  yükümlülüğü doğabilir.

İzleme modülü için: **Prometheus ve node-exporter Apache-2.0**
(kısıtsız), **Grafana OSS ise AGPL-3.0**'dır. Grafana'yı olduğu gibi
çalıştırmak serbesttir; AGPL yükümlülüğü ancak Grafana'yı DEĞİŞTİRİP ağ
üzerinden üçüncü taraflara sunarsanız doğar. İç ağda kendi panolarınızı
kullanmak bu kapsama girmez.

Copyleft istemiyorsanız imajlar değiştirilebilir — Redis yerine BSD-3 lisanslı
**Valkey** birebir geçer:

```bash
REDIS_IMAGE=valkey/valkey:8-alpine    # .env
```

Aynı mekanizma kapalı ağda kendi registry aynanız için de kullanılır.
Ayrıntı: [docs/LICENSING.md](docs/LICENSING.md)

---

## Lisans

MIT — [LICENSE](LICENSE)
