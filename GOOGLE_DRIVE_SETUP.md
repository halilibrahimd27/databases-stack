# 🔗 GOOGLE DRIVE BAĞLANTI KILAVUZU

## 📋 GEREKSINIMLER

### 1. Teknik Gereksinimler:
- ✅ Linux sunucu (Ubuntu, Debian, CentOS, vb.)
- ✅ Root veya sudo yetkisi
- ✅ İnternet bağlantısı
- ✅ Minimum 100MB boş alan (rclone için)
- ✅ Tarayıcı erişimi (yapılandırma için)

### 2. Google Hesabı:
- ✅ Gmail hesabı (ücretsiz)
- ✅ Google Drive aktif olmalı
- ✅ 2FA (2 Faktörlü Doğrulama) YOKSA daha kolay
- ✅ "Daha az güvenli uygulama" ayarı opsiyonel

---

## 🚀 ADIM ADIM KURULUM

### ADIM 1: rclone Kurulumu (2 dakika)

Linux sunucunuzda:

```bash
# rclone'u otomatik kur
curl https://rclone.org/install.sh | sudo bash

# Kurulumu doğrula
rclone version

# Çıktı benzeri:
# rclone v1.64.2
# - os/version: ubuntu 22.04
# - arch: amd64
# - go: go1.21
```

**Alternatif kurulum yöntemleri:**

```bash
# Debian/Ubuntu için APT ile
sudo apt update
sudo apt install rclone -y

# CentOS/RHEL için YUM ile
sudo yum install rclone -y

# Manuel indirme (internet problemi varsa)
cd /tmp
wget https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip rclone-current-linux-amd64.zip
cd rclone-*-linux-amd64
sudo cp rclone /usr/bin/
sudo chown root:root /usr/bin/rclone
sudo chmod 755 /usr/bin/rclone
```

---

### ADIM 2: Google Drive Yapılandırması (5-7 dakika)

#### 2.1. rclone Config Başlat

```bash
rclone config
```

#### 2.2. Yeni Remote Oluştur

```
Current remotes:

Name                 Type
====                 ====

e) Edit existing remote
n) New remote
d) Delete remote
r) Rename remote
c) Copy remote
s) Set configuration password
q) Quit config
```

**Seçim:** `n` (New remote) yazıp Enter

---

#### 2.3. Remote İsmi

```
Enter name for new remote.
name>
```

**Yazın:** `gdrive` (veya istediğiniz isim, örn: `backup-drive`, `my-drive`)

**ÖNEMLİ:** Bu ismi sync_remote.sh'da kullanacaksınız!

---

#### 2.4. Storage Type Seçimi

```
Option Storage.
Type of storage to configure.
Choose a number from below, or type in your own value.
 1 / 1Fichier
   \ (fichier)
 2 / Akamai NetStorage
   \ (netstorage)
...
15 / Google Drive
   \ (drive)
...
45 / premiumize.me
   \ (premiumizeme)
Storage>
```

**Yazın:** `15` (veya kaç numarada "drive" yazıyorsa)

**Alternatif:** Direkt `drive` yazabilirsiniz

---

#### 2.5. Google Application Client ID

```
Option client_id.
Google Application Client Id
Setting your own is recommended.
See https://rclone.org/drive/#making-your-own-client-id for how to create your own.
If you leave this blank, it will use an internal key which is low performance.
Enter a value. Press Enter to leave empty.
client_id>
```

**ÖNERİ:** Boş bırakın (sadece Enter)

**Not:** İleride performans sorunu olursa kendi Client ID'nizi oluşturabilirsiniz.

---

#### 2.6. Google Application Client Secret

```
Option client_secret.
OAuth Client Secret.
Leave blank normally.
Enter a value. Press Enter to leave empty.
client_secret>
```

**Yazın:** Boş bırakın (sadece Enter)

---

#### 2.7. Scope (Yetki Seviyesi)

```
Option scope.
Comma separated list of scopes that rclone should use when requesting access from drive.
Choose a number from below, or type in your own string value.
Press Enter for the default (full access).
 1 / Full access all files, excluding Application Data Folder.
   \ (drive)
 2 / Read-only access to file metadata and file contents.
   \ (drive.readonly)
 3 / Access to files created by rclone only.
   \ (drive.file)
...
scope>
```

**Yazın:** `1` (Full access - backup için gerekli)

---

#### 2.8. Root Folder ID

```
Option root_folder_id.
ID of the root folder.
Leave blank normally.
Enter a value. Press Enter to leave empty.
root_folder_id>
```

**Yazın:** Boş bırakın (sadece Enter)

---

#### 2.9. Service Account File

```
Option service_account_file.
Service Account Credentials JSON file path.
Leave blank normally.
Enter a value. Press Enter to leave empty.
service_account_file>
```

**Yazın:** Boş bırakın (sadece Enter)

---

#### 2.10. Advanced Config

```
Edit advanced config?
y) Yes
n) No (default)
y/n>
```

**Yazın:** `n` (No)

---

#### 2.11. Auto Config - ÇOOOK ÖNEMLİ! ⚠️

```
Use auto config?
 * Say Y if not sure
 * Say N if you are working on a remote or headless machine

y) Yes (default)
n) No
y/n>
```

**ÖNEMLİ:** Sunucunuzun durumuna göre:

**DURUM A:** Masaüstü Linux / Grafiksel arayüz var → `y` yazın
**DURUM B:** Uzak sunucu / SSH ile bağlı / Headless → `n` yazın

**Çoğu zaman:** `n` yazacaksınız (SSH ile bağlandığınız için)

---

#### 2.12. UZAK SUNUCU DURUMU (n seçtiyseniz)

Bu adımda ekrana bir LINK çıkacak:

```
Option config_token.
For this to work, you will need rclone available on a machine that has
a web browser available.

For more help and alternate methods see: https://rclone.org/remote_setup/

Execute the following on the machine with the web browser (same rclone
version recommended):

	rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"

Then paste the result below:
result>
```

**ŞİMDİ NE YAPACAKSINIZ:**

1. **Bu linki KOPYALAYIN:**
   ```bash
   rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"
   ```

2. **Windows BİLGİSAYARINIZDA (şu anda kullandığınız):**

   **PowerShell açın ve çalıştırın:**
   
   Önce rclone'u Windows'a kurun:
   ```powershell
   # PowerShell'de (Yönetici olarak)
   choco install rclone
   # VEYA
   # https://rclone.org/downloads/ adresinden Windows .exe indirin
   ```

   Sonra komutu çalıştırın:
   ```powershell
   rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlIn0"
   ```

3. **TARAYICI AÇILACAK:**
   - Google hesabınızı seçin
   - "rclone wants to access your Google Account" görünecek
   - **Allow** (İzin Ver) tıklayın

4. **BAŞARILI MESAJI:**
   ```
   Success!
   All done. Please go back to rclone.
   ```

5. **PowerShell'de UZUN BİR KOD göreceksiniz:**
   ```json
   {"access_token":"ya29.a0AfH6SMBx...","token_type":"Bearer",...}
   ```

6. **BU KODU TAMAMEN KOPYALAYIN** (Ctrl+C)

7. **LINUX SUNUCUSUNA DÖNERESİNİZ** (SSH terminalinize)

8. **KODU YAPIŞTIRIN** ve Enter

```
result> {"access_token":"ya29.a0AfH6SMBx...","token_type":"Bearer",...}
```

---

#### 2.13. Team Drive

```
Configure this as a Shared Drive (Team Drive)?

y) Yes
n) No (default)
y/n>
```

**Yazın:** `n` (kişisel kullanım için)

---

#### 2.14. Configuration Onayı

```
Configuration complete.
Options:
- type: drive
- scope: drive
- token: {"access_token":"XXX","token_type":"Bearer",...}
- team_drive: 
Keep this "gdrive" remote?
y) Yes this is OK (default)
e) Edit this remote
d) Delete this remote
y/e/d>
```

**Yazın:** `y` (Yes)

---

#### 2.15. Çıkış

```
Current remotes:

Name                 Type
====                 ====
gdrive              drive

e) Edit existing remote
n) New remote
d) Delete remote
r) Rename remote
c) Copy remote
s) Set configuration password
q) Quit config
e/n/d/r/c/s/q>
```

**Yazın:** `q` (Quit)

---

### ADIM 3: Test Etme (1 dakika)

#### 3.1. Bağlantıyı Test Et

```bash
# Google Drive'ınızı listele
rclone lsd gdrive:

# Çıktı benzeri:
#           -1 2023-01-15 10:23:45        -1 My Drive
#           -1 2023-01-15 10:23:45        -1 Shared with me
```

✅ Liste göründüyse BAŞARILI!

#### 3.2. Test Klasörü Oluştur

```bash
# DatabaseBackups klasörü oluştur
rclone mkdir gdrive:/DatabaseBackups

# Kontrol et
rclone lsd gdrive:
```

#### 3.3. Test Dosyası Gönder

```bash
# Test dosyası oluştur
echo "Test backup file" > /tmp/test-backup.txt

# Google Drive'a gönder
rclone copy /tmp/test-backup.txt gdrive:/DatabaseBackups/

# Kontrol et
rclone ls gdrive:/DatabaseBackups/
```

Çıktı:
```
       18 test-backup.txt
```

✅ Dosya göründüyse TAM BAŞARILI!

---

### ADIM 4: sync_remote.sh'ı Yapılandır (30 saniye)

```bash
cd /opt/databases

# Script'i düzenle
nano sync_remote.sh

# Veya otomatik:
sed -i 's/REMOTE_SYNC_ENABLED="false"/REMOTE_SYNC_ENABLED="true"/' sync_remote.sh
sed -i 's/REMOTE_TYPE="rclone"/REMOTE_TYPE="gdrive"/' sync_remote.sh

# Test et
./sync_remote.sh
```

---

## 🔒 GÜVENLİK ÖNERİLERİ

### 1. rclone Config Şifreleme (Opsiyonel ama Önerilen)

```bash
rclone config

# Menüden seç:
s) Set configuration password

# Şifre belirle
# Her rclone kullanımında bu şifreyi gireceksiniz
```

### 2. Token Yenileme

Google token'ları periyodik olarak yenilenir, otomatik.  
Sorun çıkarsa:

```bash
rclone config reconnect gdrive:
```

### 3. İki Faktörlü Doğrulama (2FA)

Google hesabınızda 2FA varsa:
- rclone authorize sırasında doğrulama kodu isteyecek
- Telefonunuzdaki kodu girin

---

## 🌐 WEB'DEN KONTROL

1. https://drive.google.com adresine gidin
2. Sol menüde "My Drive" tıklayın
3. "DatabaseBackups" klasörünü görmelisiniz
4. İçinde backup dosyaları olacak

---

## ⚠️ MUHTEMEL SORUNLAR VE ÇÖZÜMLER

### Sorun 1: "rclone: command not found"

```bash
# rclone'u tekrar kur
curl https://rclone.org/install.sh | sudo bash

# PATH kontrolü
which rclone
# Çıktı: /usr/bin/rclone
```

---

### Sorun 2: "Failed to authorize"

**Sebep:** Tarayıcı erişimi yok veya token kopyalama hatası

**Çözüm 1:** Windows'ta rclone kur ve authorize et
```powershell
# Windows PowerShell
choco install rclone
rclone authorize "drive" "SUNUCUDAN_GELEN_KOD"
```

**Çözüm 2:** Başka bir bilgisayarda rclone kur ve authorize et

---

### Sorun 3: "Token expired"

```bash
# Token'ı yenile
rclone config reconnect gdrive:

# Veya remote'u sil ve yeniden yapılandır
rclone config delete gdrive
rclone config  # Yeniden başlat
```

---

### Sorun 4: "403 Forbidden" veya "Rate limit exceeded"

**Sebep:** Google API limitleri

**Çözüm:** Kendi Client ID'nizi oluşturun

1. https://console.cloud.google.com/ gidin
2. Yeni proje oluşturun
3. Google Drive API'yi aktive edin
4. OAuth 2.0 Credentials oluşturun
5. Client ID ve Secret'i rclone config'e girin

---

### Sorun 5: "Permission denied" upload sırasında

```bash
# rclone test et
rclone lsd gdrive:

# Scope'u kontrol et (Full access olmalı)
rclone config show gdrive

# Yeniden authorize et
rclone config reconnect gdrive:
```

---

## 📊 GOOGLE DRIVE LİMİTLERİ

| Limit | Değer |
|-------|-------|
| **Upload (günlük)** | 750 GB/gün |
| **Download (günlük)** | 10 TB/gün |
| **API request** | 20,000/100 saniye |
| **Dosya boyutu** | 5 TB/dosya |
| **Ücretsiz alan** | 15 GB |

**Sizin durumunuzda:**
- Günlük upload: ~620MB × 1 = 620MB
- Aylık: ~18GB

**Sonuç:** Limitler içindesiniz ✅

---

## 💰 GOOGLE DRIVE PLANLARI

| Plan | Alan | Ücret (Aylık) |
|------|------|---------------|
| **Ücretsiz** | 15 GB | ÜCRETSİZ |
| **Google One Basic** | 100 GB | $1.99 (~₺60) |
| **Google One Standard** | 200 GB | $2.99 (~₺90) |
| **Google One Premium** | 2 TB | $9.99 (~₺300) |

**Öneriniz için:** 100 GB plan ($1.99/ay) ✅

---

## 🎯 ÖZET KONTROL LİSTESİ

Başarılı kurulum için kontrol edin:

- [ ] rclone kurulu (`rclone version` çalışıyor)
- [ ] `rclone config` tamamlandı
- [ ] Remote adı: `gdrive` (veya tercih ettiğiniz)
- [ ] Scope: `drive` (Full access)
- [ ] Token alındı ve yapıştırıldı
- [ ] `rclone lsd gdrive:` çalışıyor
- [ ] Test dosyası gönderildi ve görünüyor
- [ ] Web'de drive.google.com'da dosya var
- [ ] sync_remote.sh çalıştırılabilir
- [ ] REMOTE_SYNC_ENABLED="true"

**Hepsi ✅ ise HAZIR!**

---

## 🚀 SONRAKI ADIM

Şimdi ilk gerçek sync'i yapın:

```bash
cd /opt/databases
./sync_remote.sh

# Log'u izle
tail -f logs/remote_sync.log

# Google Drive'da kontrol et
rclone ls gdrive:/DatabaseBackups/
```

---

## 📞 YARDIM KAYNAKLARI

- **rclone dokümantasyonu:** https://rclone.org/drive/
- **Video tutorial:** YouTube'da "rclone google drive"
- **Sorun giderme:** https://rclone.org/drive/#troubleshooting
- **Forum:** https://forum.rclone.org/

---

**Kurulum Süresi:** 10-15 dakika  
**Zorluk:** ⭐⭐☆☆☆ (Kolay)  
**Maliyet:** ÜCRETSİZ (15GB) / $2/ay (100GB)  

**HAYDİ BAŞLAYALIM!** 🚀
