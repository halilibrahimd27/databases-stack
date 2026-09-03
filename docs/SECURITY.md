# Güvenlik

***Türkçe** · [English](SECURITY.en.md)*

Bu ürün **iç ağ / VPN arkası** kullanım için tasarlandı.

## Varsayılan güvenlik duruşu

| Konu | Durum |
|---|---|
| Panellerin portları | Host'a **açılmaz** — yalnız gateway üzerinden erişilir |
| Panel trafiği | TLS (iç CA, IP SAN'lı) + HTTP basic auth |
| Veritabanı portları | Host'a açılır (uygulamanız bağlanabilsin diye) |
| Parolalar | Motor başına ayrı, `install.sh` tarafından rastgele üretilir |
| Kontrol servisi | Portu yok; yalnız gateway'den, paylaşılan token ile |
| Metrik uçları | Tek TLS+auth'lu portta (9443), exporter portları kapalı |
| Betiklerde parola | Ortam değişkeniyle geçer, komut satırında **görünmez** |

### Parolaların komut satırında olmaması neden önemli

`docker exec mariadb mariadb -u root -pPAROLA` yazarsanız parola host'ta
`ps aux` çıktısında ve `/proc/<pid>/cmdline` içinde görünür — sunucudaki her
kullanıcı okuyabilir. Bu yüzden tüm betikler `MYSQL_PWD`, `PGPASSWORD`,
`REDISCLI_AUTH`, `SQLCMDPASSWORD` gibi ortam değişkenlerini kullanır.

## Kontrol servisinin yetkisi

Kontrol servisi Docker soketine bağlıdır. **Bu, host üzerinde root'a eşdeğer bir
yetkidir** — container başlatabilen, host dosya sistemini bağlayabilir. Bu yüzden:

- Host'a hiç port açmaz; ağdan doğrudan erişilemez
- Gateway'in eklediği `X-Api-Token` olmadan her isteği 401 ile reddeder
  (aynı docker ağındaki ele geçirilmiş bir panel bile ulaşamaz)
- Yalnızca `catalog.json` içinde tanımlı motor kimliklerini kabul eder; keyfi
  servis adı ya da dosya yolu geçirilemez
- Alt süreçleri kabuk olmadan (`shell=False`) çalıştırır — komut enjeksiyonu yok

> Kubernetes dağıtımında bu yetki çok daha dardır: yalnızca StatefulSet okuma ve
> ölçekleme. Sıkı güvenlik gereksiniminiz varsa K8s yolunu tercih edin.

## TLS — domain olmadan

İç ağda alan adı yoktur, Let's Encrypt kullanılamaz (doğrulama için dışarıdan
erişilebilir bir isim ister). Çözüm kendi mini sertifika otoritemiz
(`scripts/gen-certs.sh`):

- `certs/ca.crt` — istemcilere kurulur, 10 yıl geçerli
- `certs/server.crt` — sunucunun tüm IP'leri ve adları SAN olarak yazılı, 825 gün

Neden self-signed değil de CA: tarayıcılar IP adresli self-signed sertifikaya
**asla** güvenmez, ama güvenilen bir CA'nın imzaladığı IP SAN'lı sertifikayı
kabul eder. CA'yı bir kez kurunca uyarı tamamen kalkar.

CA'nın özel anahtarı (`certs/ca.key`) sızarsa saldırgan bu ağ için geçerli
sertifika üretebilir — dosya `600` iznindedir ve `.gitignore` içindedir.

Sunucunun IP'si değişirse:

```bash
./scripts/gen-certs.sh 192.168.1.55
docker restart gateway
```

## Yapılması önerilenler

**1. Uygulamanız root ile bağlanmasın**

```bash
./stack.sh app-user
```

`DROP DATABASE`, `DROP TABLE`, `TRUNCATE`, `FLUSHALL` yetkisi olmayan bir
kullanıcı oluşturur. MariaDB'de yetkiler `*.*` üzerinde değil kullanıcı
veritabanları üzerinde verilir — böylece `mysql` şemasındaki parola hash'lerini
okuyamaz.

**2. Veritabanı portlarını dışarı kapatın**

Uygulamalarınız da aynı sunucudaysa portları hiç açmayın:

```yaml
# docker-compose.override.yml
services:
  mariadb:    { ports: [] }
  postgresql: { ports: [] }
  mongodb:    { ports: [] }
  redis:      { ports: [] }
```

**3. Güvenlik duvarı**

```bash
ufw allow from 10.8.0.0/24 to any port 443            # yalnız VPN ağı
ufw allow from 10.8.0.0/24 to any port 8081:8091 proto tcp
ufw deny 3306,5432,27017,6379,1433/tcp                # gerekmiyorsa
```

**4. Yedeklerinizi test edin**

Test edilmemiş yedek, yedek değildir:

```bash
./scripts/backup.sh verify backups/mariadb/full/<dosya>
```

Yılda en az bir kez gerçek bir geri yükleme provası yapın.

## Bilinen kabuller

- **Elasticsearch'ün HTTP TLS'i kapalıdır.** Basic auth açıktır ve trafik iç ağda,
  gateway'in TLS'i arkasındadır. 9200 portunu dışarı açmayın.
- **Kafka'da kimlik doğrulama yoktur.** SASL kurulumu tek makinelik bir stack'in
  kapsamını aşar; 9092'yi yalnız güvendiğiniz ağa açın.
- **Redis'in `default` kullanıcısı tam yetkilidir.** Uygulamalarınızı
  `./stack.sh app-user` ile oluşturulan kısıtlı kullanıcıya geçirin.
- **`credentials.txt` ve `.env` düz metindir** (mod 600). Sunucuya kimlerin
  eriştiğini sınırlayın.
- **Dashboard'daki "Bağlantı bilgisi" parolayı gösterir.** Bu bilinçli: oraya
  erişebilen kişi zaten phpMyAdmin/pgAdmin üzerinden tam yetkilidir.
