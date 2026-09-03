# İzleme

***Türkçe** · [English](MONITORING.en.md)*

Açtığınız veritabanlarının nasıl çalıştığını grafiklerle gösterir. Kurulum
gerektirmez, yapılandırma istemez: panelden **İzleme**'yi açın, grafikler
hazır gelir.

```bash
./stack.sh enable monitoring
./stack.sh panel monitoring        # adresi ve parolayı yazar
```

Kapattığınızda hiçbir container çalışmaz, RAM tüketimi sıfırdır — diğer
motorlarla aynı mantık.

## Ne göreceksiniz

| Pano | Cevapladığı soru |
|---|---|
| **Genel Bakış** | Her şey ayakta mı? Hangi motor ne kadar RAM kullanıyor? Disk ne zaman dolar? |
| **Motor panoları** | Kaç bağlantı var? Saniyede kaç işlem? Önbellek işe yarıyor mu? Yedek kopya geride mi? |

Her panelin altında ne anlama geldiği ve **ne zaman endişelenmeniz gerektiği**
yazar. Amaç, veritabanı yönetmeyi bilmeden de "bir şey ters gidiyor mu?"
sorusuna bakışta cevap verebilmenizdir.

**Genel Bakış panosu bu ürün için özel olarak önemlidir:** yığın belleği
otomatik hesaplayıp dağıtır (bkz. [SIZING](../README.md#bellek-otomatik-hesaplanır)).
Bu panoda her container'ın *gerçekte* ne kadar kullandığını ayrılan limitle
yan yana görürsünüz — yani hesabın doğru olup olmadığını gözünüzle
doğrulayabilirsiniz.

## Nasıl çalışıyor

```
  motorlar          Prometheus            Grafana
 ┌─────────┐       ┌────────────┐       ┌──────────┐
 │exporter │──────▶│  toplar    │──────▶│ çizer    │
 └─────────┘       │  saklar    │       │ uyarır   │
                   └────────────┘       └──────────┘
                          ▲
                   hedef listesi
                   (controller üretir)
```

Her motorun zaten bir **exporter**'ı vardı; eksik olan onu okuyan yüzdü.

**Hedef listesi elle yazılmaz.** Bir motoru açıp kapattığınızda controller
`state/prometheus/targets.json` dosyasını yeniden üretir; Prometheus dosyayı
izler ve listeyi kendiliğinden günceller. Yeniden başlatma gerekmez. Kapalı
motor listede bulunmadığı için "erişilemiyor" uyarısı da yağmaz — kapalı olmak
arıza değildir.

Prometheus, exporter'lara Docker ağı üzerinden **doğrudan** bağlanır; aradan
TLS ve parola çıkar. Dışarıdaki kurumsal bir Prometheus'unuz varsa o, gateway
üzerinden toplamaya devam edebilir:

```yaml
scrape_configs:
  - job_name: databases-stack
    scheme: https
    metrics_path: /metrics/postgresql        # motor başına bir uç
    basic_auth: { username: admin, password: <panel parolası> }
    tls_config:  { ca_file: databases-stack-ca.crt }
    static_configs: [{ targets: ['<sunucu>:9443'] }]
```

## Kaynak kullanımı

| Servis | Bellek | Ne yapar |
|---|---|---|
| Prometheus | ~512 MB | Metrikleri toplar ve saklar |
| Grafana | ~256 MB | Grafikleri çizer |
| node-exporter | ~64 MB | Sunucunun RAM/disk/CPU durumu |

Toplam ~830 MB. Container başına bellek/CPU için ayrı bir araç (cAdvisor)
çalıştırılmaz: o bilgiyi zaten belleği dağıtan controller'ın kendisi
yayınlar. Böylece grafiklerdeki sayılar, ayırma kararını veren kodun kendi
defterinden gelir — ayrı bir aracın farklı sayması kafa karıştırırdı.

Diğer motorlar gibi, sunucuda yer yoksa **açılmaz** ve size sebebini söyler —
sessizce sunucuyu boğmaz.

Saklama süresi varsayılan **15 gün**, disk sınırı **2 GB**. İkisi birlikte
sınırlanır: yalnız süre sınırlansaydı yoğun bir kurulumda disk sessizce dolar
ve veritabanları yazmayı bırakırdı. Değiştirmek için `.env`:

```
PROMETHEUS_RETENTION=30d
PROMETHEUS_RETENTION_SIZE=5GB
```

## Uyarılar

`config/prometheus/rules/databases.yml` içinde **dört** kural vardır ve bu
sayı kasıtlı olarak azdır:

- **MotorErisilemiyor** — açık bir motor 2 dakikadır cevap vermiyor
- **BellekSinirinaYaklasiyor** — bir container ayrılan belleğin %90'ını aştı
  (öncesinde uyarmak, gece yarısı OOM ile düşmesinden iyidir)
- **ReplikasyonGeride** — yedek kopya 5 dakikadan fazla geride; bu durumda
  otomatik devir yapılırsa aradaki veri kaybolur
- **DiskDoluyor** — %10'dan az yer kaldı

Yüzlerce hassas kural, uzman olmayan kullanıcı için gürültüden başka bir şey
değildir. Her uyarının açıklamasında **ne yapılacağı** yazar.

Bildirim (e-posta, Slack, webhook) kurmak isterseniz Grafana içinden:
**Alerting → Contact points**.

## Panoları değiştirmek

Panolar `config/grafana/dashboards/*.json` altında **kodun bir parçası**
olarak durur ve salt-okunur bağlanır: sürüm kontrolünde kalırlar, kurulumda
kendiliğinden gelirler, kazara silinemezler.

Kendi panonuzu yapmak isterseniz Grafana'da yeni pano oluşturun — buradakiler
etkilenmez. Hazır panolardan birini değiştirmek isterseniz JSON dosyasını
düzenleyin; Grafana 30 saniyede bir yeniden okur.

## Sorun giderme

**Grafikler boş.** Prometheus hedefleri topluyor mu, bakın: Grafana içinden
**Connections → Data sources → Prometheus → Explore** ve `up{job="databases"}`
sorgusunu çalıştırın. Hiç satır yoksa hedef listesi boştur — açık bir motor
olduğundan emin olun, sonra:

```bash
cat state/prometheus/targets.json      # controller ne üretmiş?
./stack.sh logs prometheus
```

**Bir motorun panosu boş, diğerleri dolu.** O motorun exporter'ı çalışmıyor
olabilir:

```bash
docker ps --filter name=-exporter
./stack.sh logs <motor>-exporter
```

MSSQL ve Neo4j'nin exporter'ı yoktur; onlar yalnız Genel Bakış panosunda
(controller'ın yayınladığı bellek/CPU kullanımı olarak) görünür.

**Grafana'ya giriş.** Panel zaten parola arkasında olduğu için Grafana'ya
ziyaretçi olarak girersiniz; pano düzenlemek için `admin` kullanıcısıyla giriş
yapın. Parola `credentials.txt` içindedir.
