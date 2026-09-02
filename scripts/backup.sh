#!/bin/bash
# =============================================================================
# databases-stack — yedekleme ve geri yükleme
# =============================================================================
# Yalnızca AKTİF motorları yedekler (kapalı motorun container'ı yoktur).
#
# Kullanım:
#   ./scripts/backup.sh all                 aktif motorların hepsi
#   ./scripts/backup.sh mariadb             tek motor
#   ./scripts/backup.sh restore-mariadb <dosya>
#   ./scripts/backup.sh list | stats | clean [gün] | verify <dosya>
#
# NEDEN GÜNDE BİR (15 dakikada bir değil):
# Dump'lar DB container'ının İÇİNDE alınır; bellek tüketimi o container'ın
# kendi cgroup'una yazılır. Sık tam yedek MariaDB'yi tekrar tekrar
# CONSTRAINT_MEMCG OOM'a soktu (container 172 kez yeniden başladı). Daha sık
# kurtarma noktası gerekiyorsa dump yerine binlog/PITR kullanın — MariaDB'de
# binlog artık AÇIK (config/mariadb/my.cnf).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
load_env

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
DATE="$(date +%Y%m%d_%H%M%S)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
BACKUP_EXCLUDE_TABLE_PATTERNS="${BACKUP_EXCLUDE_TABLE_PATTERNS:-telescope% pulse%}"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d).log"
mkdir -p "$LOG_DIR"
# Günlük dosyası GÜN ADIYLA açılır ve ona hem controller (container'da
# root) hem de buradaki kullanıcı yazar. İlk yazan sahibi olur; mod
# açılmazsa ikinci yazan o gün boyunca hiç çalışamaz.
paylasilan_dosya "$LOG_FILE"

# Yedekleme ağır I/O üretir. nice + ionice ile canlı DB trafiği öncelikli kalır
# (özellikle dönen disk / RAID üzerinde fark eder).
if command -v nice >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
    IO_NICE=(nice -n 19 ionice -c3)
else
    IO_NICE=()
fi

blog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
bok()  { ok   "$*"; printf '[%s] [OK] %s\n'   "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
berr() { err  "$*"; printf '[%s] [ERR] %s\n'  "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# =============================================================================
# YEDEK ŞİFRELEME
# =============================================================================
# NEDEN VAR: sync-remote.sh bu dosyaları Google Drive / S3 / SFTP'ye kopyalıyor
# ve dosyalar DÜZ GZIP'ti. Yani veritabanı dökümü şifrelenmeden binadan
# çıkıyordu; uzak depo hesabını ele geçiren biri `gzip -dc` ile bütün veriyi
# okurdu — dump'ların içinde tablo verisinin yanı sıra kullanıcı satırları,
# e-posta adresleri ve parola hash'leri de var (pg_dumpall rolleri ve
# parolaları da alıyor). İç ağda kalan bir yığın için bile kabul edilemez.
#
# NEDEN openssl (age ya da gpg DEĞİL):
#   • BULUNABİLİRLİK — install.sh:42 zaten `require_cmd openssl python3 awk
#     grep sed` diyor: openssl bu ürünün KURULUM ŞARTI. gen-certs.sh TLS
#     sertifikalarını, common.sh rand_secret parolaları onunla üretiyor.
#     age ya da gpg seçmek, "tek komutla kurulur" diyen bir ürüne YENİ bir
#     kurulum bağımlılığı eklemek olurdu; hiçbir dağıtımda ikisi de öntanımlı
#     kurulu gelmiyor.
#   • ANAHTAR YÖNETİMİNİN SADELİĞİ — simetrik parola demek, .env'de TEK satır
#     demek: DB_PASSWORD ile aynı dosyada, aynı izinlerle, aynı yedekleme
#     alışkanlığıyla. age bir kimlik DOSYASI ister (kaybedilecek İKİNCİ bir
#     sır, ayrı bir saklama yeri, ayrı bir yedekleme kuralı). gpg ise
#     ~/.gnupg anahtarlığı + agent ister — ve bu betik ÜÇ ayrı kimlikle
#     koşuyor: host cron'u (kullanıcı), controller container'ı (root),
#     operatörün terminali. Üç farklı $HOME = üç farklı anahtarlık =
#     "panelden çalışıyor, cron'dan çalışmıyor" sınıfı arıza. Bu dosyanın
#     geçmişi tam olarak o sınıf hatalarla dolu (common.sh'taki /tmp kilit
#     dosyası hikâyesi aynı kalıbın bir başka örneği).
#   • KURTARMA — felaket günü elde yığın değil yalnız DOSYA kalırsa, çözme
#     komutu tek satır ve her Linux'ta çalışır (docs/BACKUP.md'de yazılı).
#     age/gpg'de önce aracı kurmak, sonra anahtarı içe aktarmak gerekir; en
#     kötü günde en fazla adım.
#
# NE VAAT ETMİYORUZ: `openssl enc` AEAD (GCM) desteklemez — bu şifreleme
# GİZLİLİK sağlar, kriptografik BÜTÜNLÜK İMZASI (MAC) sağlamaz. Kurcalanmış
# bir dosya neredeyse kesinlikle CBC dolgusunda, gzip CRC'sinde ya da
# verify_backup'ın biçim kontrollerinde düşer; ama bu bir MAC değildir ve
# belgede de böyle yazıyor. Vaat edilmeyen bir güvenceyi vaat etmiş gibi
# göstermek, hiç şifrelememekten daha tehlikelidir.
#
# ÖLÇÜM (openssl 3.5.5, AES-NI'li bir x86-64):
#   • PBKDF2-HMAC-SHA512 600000 iterasyon = DOSYA BAŞINA ~0,56 sn (tek
#     seferlik anahtar türetme; akış uzunluğundan bağımsız).
#   • Akış hızı ~130-220 MB/sn. Şifreleme gzip'ten SONRA geldiği için
#     SIKIŞTIRILMIŞ baytları işliyor: 5 GB'lık bir dump 400 MB'a inip
#     ~3 sn'de şifreleniyor. Darboğaz hâlâ gzip.
# =============================================================================

# DOSYA BİÇİMİ: 64 baytlık DÜZ METİN başlık + `openssl enc` çıktısı.
#
# Parametreler betiğin içinde DEĞİL dosyanın İÇİNDE duruyor. Sebep: yarın
# iterasyon sayısını yükseltirsek ya da şifreyi değiştirirsek, BUGÜN alınmış
# yedekler açılabilir kalmalı. Sabit yazsaydık o değişikliğin yapıldığı gün
# bütün arşiv sessizce okunamaz hâle gelirdi — ve bunu ancak felaket günü
# öğrenirdik.
#
# Başlık SABİT UZUNLUKTA: gövde her zaman 65. bayttan başlar (`tail -c +65`),
# hiçbir ayrıştırma gerekmeden. Değişken uzunlukta bir satır, ikili verinin
# içinde "ilk satır sonuna kadar oku" oyununa dönerdi; ciphertext'in ilk
# baytları arasında 0x0a çıkması olasıdır ve o gün okuma kayardı.
ENC_SIHIR="DBSTACK-ENC1"
ENC_BASLIK=64
ENC_CIPHER="aes-256-cbc"
ENC_KDF="pbkdf2"
ENC_MD="sha512"
ENC_ITER="600000"
ENC_EXT="enc"

# UZANTI SÖZLEŞMESİ — bu iki ad DIŞARIDAN da okunuyor (restore-drill.sh,
# sync-remote.sh, controller):
#   <motor>_<tip>_<TARİH>.<biçim>.gz       şifresiz  (eski akış; hâlâ geçerli)
#   <motor>_<tip>_<TARİH>.<biçim>.gz.enc   şifreli
#   …<herhangi biri>.bozuk                 doğrulamayı geçemedi; KURTARMA
#                                          NOKTASI DEĞİLDİR
# Sıra bilerek "önce gz, sonra enc": dosya önce sıkıştırıldı, SONRA
# şifrelendi; ad soldan sağa bunu anlatıyor. Ters sıra yalan olurdu.
# `.enc` uzantısının `*.gz` desenine UYMAMASI kasıtlı: şifreli bir dosyayı
# `.gz` diye adlandırsaydık, onu tanımayan her araç `gzip -dc` deneyip
# "not in gzip format" ile ölürdü — hata gürültülü ama YANLIŞ yere işaret
# ederdi. Şimdi eski araçlar dosyayı hiç görmüyor; görmemek, yanlış anlamaktan
# iyidir.
YEDEK_BUL=( '(' -name '*.gz' -o -name "*.gz.$ENC_EXT" ')' )

# Şifreleme durumu BİR KEZ, betiğin başında hesaplanıyor. Her çağrıda yeniden
# bakmak yerine tek yerde olması şart: alt kabuklarda (boru hattı, komut
# ikamesi) durumun farklı çıkması, AYNI koşumda bazı motorları şifreleyip
# bazılarını şifresiz bırakabilirdi — sessiz ve fark edilmesi neredeyse
# imkânsız bir sızıntı.
ENC_DURUM="kapali"    # kapali | acik | bozuk
ENC_SEBEP=""
ENC_KAYNAK=""
ENC_KEY=""
enc_durumu_belirle() {
    # Anahtar dosya yolu verildiyse O kazanır: .env'i kopyalayan/gönderen
    # akışlar var (install.sh üretiyor, operatör taşıyor), anahtarı ayrı ve
    # 0600 bir dosyada tutmak isteyen bunu bilerek seçer.
    # DOSYA VERİLİP OKUNAMIYORSA SESSİZCE .env'e DÜŞMÜYORUZ: o düşüş,
    # "şifreleme açık" sanılırken düz metin yedek üretmek demektir.
    if [ -n "${BACKUP_ENCRYPT_KEY_FILE:-}" ]; then
        if [ ! -r "$BACKUP_ENCRYPT_KEY_FILE" ]; then
            ENC_DURUM="bozuk"
            ENC_SEBEP="BACKUP_ENCRYPT_KEY_FILE okunamıyor: $BACKUP_ENCRYPT_KEY_FILE"
            return 0
        fi
        IFS= read -r ENC_KEY < "$BACKUP_ENCRYPT_KEY_FILE" || ENC_KEY="${ENC_KEY:-}"
        ENC_KEY="${ENC_KEY%$'\r'}"
        if [ -z "$ENC_KEY" ]; then
            ENC_DURUM="bozuk"
            ENC_SEBEP="BACKUP_ENCRYPT_KEY_FILE boş: $BACKUP_ENCRYPT_KEY_FILE"
            return 0
        fi
        ENC_KAYNAK="BACKUP_ENCRYPT_KEY_FILE"
    else
        ENC_KEY="${BACKUP_ENCRYPT_KEY:-}"
        [ -n "$ENC_KEY" ] && ENC_KAYNAK="BACKUP_ENCRYPT_KEY"
    fi

    if [ -z "$ENC_KEY" ]; then
        ENC_SEBEP="anahtar tanımlı değil (BACKUP_ENCRYPT_KEY boş)"
        return 0
    fi
    # BACKUP_ENCRYPT=false: anahtar .env'de DURURKEN üretimi kapatmak için.
    # Anahtar yine yüklü kalıyor — yani eski ŞİFRELİ yedekler doğrulanmaya ve
    # geri yüklenmeye devam eder. Anahtarı .env'den silmek bunu yapmaz;
    # geçişten vazgeçen operatör o gün bütün şifreli arşivini kaybederdi.
    case "${BACKUP_ENCRYPT:-}" in
        false|no|0|hayir|kapali)
            ENC_SEBEP="BACKUP_ENCRYPT=false — anahtar duruyor, eski şifreli yedekler açılabilir"
            return 0 ;;
    esac
    if ! command -v openssl >/dev/null 2>&1; then
        ENC_DURUM="bozuk"
        ENC_SEBEP="anahtar tanımlı ama 'openssl' komutu yok"
        return 0
    fi
    ENC_DURUM="acik"
    ENC_SEBEP="$ENC_KAYNAK · $ENC_CIPHER · $ENC_KDF-$ENC_MD · $ENC_ITER iterasyon"
    return 0
}
enc_durumu_belirle

enc_acik()  { [ "$ENC_DURUM" = "acik" ]; }
enc_bozuk() { [ "$ENC_DURUM" = "bozuk" ]; }

# ŞİFRELEME BOZUKSA YEDEK ALMIYORUZ. Sebep tam da yukarıdaki tasarımda
# saklı: "bozuk" durumda enc_acik() false döner, yani betik hiçbir şey
# söylemeden DÜZ METİN yedek üretirdi — kullanıcı şifreleme açık sanırken.
# Yedekte sessiz yanlış, yedeğin hiç olmamasından beterdir.
enc_onkosul() {
    enc_bozuk || return 0
    berr "Yedek şifrelemesi yapılandırılmış ama KULLANILAMIYOR: $ENC_SEBEP"
    case "$ENC_SEBEP" in
        *openssl*)
            err "  Kurulum:  Debian/Ubuntu → sudo apt-get install -y openssl"
            err "            Alpine        → apk add --no-cache openssl" ;;
    esac
    berr "  Şifresiz yedek ÜRETMİYORUZ. Bilerek şifresiz devam edecekseniz .env'de: BACKUP_ENCRYPT=false"
    return 1
}

enc_baslik() {
    # '%-63s' + '\n' = tam 64 bayt. Buradaki alanların hiçbiri kullanıcıdan
    # gelmiyor (hepsi bu dosyada sabit) ve toplamı 45 karakter; 63'ü aşarsa
    # printf KIRPMAZ, başlık büyür ve `tail -c +65` gövdeyi kaçırır.
    printf '%-63s\n' "$ENC_SIHIR $ENC_CIPHER $ENC_KDF $ENC_MD $ENC_ITER"
}

# Anahtar ARGÜMANA değil ORTAMA konuyor. Fark somut: `ps aux` çıktısı
# sistemdeki HERKESE açıktır (hidepid ayarlı değilse), /proc/<pid>/environ ise
# yalnız sürecin sahibine ve root'a. Ortamı okuyabilen zaten .env'i de
# okuyabilir — yani ortam yeni bir açık yaratmıyor; argüman ise anahtarı
# makinedeki her kullanıcıya açardı. (Aynı gerekçe MYSQL_PWD/PGPASSWORD/
# SQLCMDPASSWORD için de geçerli, dosyanın geri kalanı bu deseni kullanıyor.)
sifrele() {   # stdin → stdout
    DBSTACK_ENC_PASS="$ENC_KEY" openssl enc "-$ENC_CIPHER" "-$ENC_KDF" \
        -md "$ENC_MD" -iter "$ENC_ITER" -salt -pass env:DBSTACK_ENC_PASS
}

# Dosya ADINA değil İÇİNE bakıyoruz. Sebep somut: aynı dosya `.bozuk` ekiyle
# kenara alınmış olabilir, operatör elle `.gz` diye yeniden adlandırmış
# olabilir, uzak depodan farklı bir adla inmiş olabilir. Ada bakan bir kontrol
# o dosyaya "bozuk gzip" derdi; oysa doğru cevap "bu dosya ŞİFRELİ".
sifreli_mi() {   # sifreli_mi <dosya>
    [ -f "$1" ] || return 1
    # KOMUT İKAMESİ ($( )) BİLEREK KULLANILMIYOR. Kabuk değişkeni NUL baytı
    # taşıyamaz ve bash ikamede NUL görünce HER ÇAĞRIDA stderr'e
    # "warning: command substitution: ignored null byte in input" basar.
    # Bu fonksiyon her verify ve her geri yükleme yolunda çağrılıyor, gzip
    # başlığında da NUL var — yani o uyarı her gece cron mail'ine düşerdi.
    # (Aynı sınıf gürültü için yukarıdaki awk `[.]` yorumuna bakın.)
    # grep boruda çalıştığı için ikame yok: -a ikili girdiyi metin sayar,
    # -x satırın TAMAMININ eşleşmesini ister, -F deseni düz metin olarak alır.
    head -c "${#ENC_SIHIR}" "$1" 2>/dev/null | grep -qaxF "$ENC_SIHIR"
}

# Şifresi ÇÖZÜLMÜŞ ama hâlâ SIKIŞTIRILMIŞ baytlar. Şifresiz dosyada dosyanın
# kendisi. Çıkış kodu "akış sonuna kadar okunabildi mi" sorusunu cevaplar.
#   3 = anahtar yok · 4 = openssl yok · 5 = başlık tanınmıyor
oku_ham() {   # oku_ham <dosya>
    local f="$1"
    if ! sifreli_mi "$f"; then cat "$f"; return $?; fi
    [ -n "$ENC_KEY" ] || return 3
    command -v openssl >/dev/null 2>&1 || return 4
    local sihir c kdf md it
    read -r sihir c kdf md it _ <<< "$(head -c "$ENC_BASLIK" "$f" 2>/dev/null)"
    [ "$sihir" = "$ENC_SIHIR" ] || return 5
    # Başlık DOSYADAN geliyor ve dosya uzak depodan da inmiş olabilir; yani
    # bu alanlar güvenilmez girdidir. Beyaz liste olmadan `-$c` doğrudan
    # openssl'e bayrak olarak geçerdi ("-help", "-out /etc/…" gibi) — dosya
    # adı sözleşmesinden çok daha pahalı bir açık.
    case "$c"   in aes-256-cbc|aes-256-ctr|aes-128-cbc) ;; *) return 5 ;; esac
    case "$kdf" in pbkdf2) ;;                               *) return 5 ;; esac
    case "$md"  in sha256|sha512) ;;                        *) return 5 ;; esac
    case "$it"  in ''|*[!0-9]*) return 5 ;; esac
    tail -c "+$((ENC_BASLIK + 1))" "$f" \
        | DBSTACK_ENC_PASS="$ENC_KEY" openssl enc -d "-$c" "-$kdf" \
              -md "$md" -iter "$it" -pass env:DBSTACK_ENC_PASS
    local ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ]
}

# Yedeğin İÇERİĞİ: şifresi çözülmüş VE gzip'i açılmış akış. Eski koddaki
# `gzip -dc "$f"`nin yerini BİREBİR tutuyor — çıkış kodu yine "dosya sonuna
# kadar okunabildi mi" demek. Bu şart: verify/restore yollarındaki
# PIPESTATUS[0] kontrolleri anlamını korusun diye (o kontroller kesik gzip'i
# yakalamak için tek tek yazıldı; buradaki bir kayma hepsini sessizce iptal
# ederdi).
oku_akis() {   # oku_akis <dosya>
    oku_ham "$1" | gzip -dc
    local ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ]
}

oku_tar() {   # oku_tar <dosya> — arşiv üye listesi (uzun biçim)
    oku_akis "$1" | tar -tvf -
    local ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ]
}

# Şifreli dosyada verify_backup'ın İLK işi: bu dosyayı AÇABİLİYOR MUYUZ?
# Önce sormanın sebebi mesaj kalitesidir. Sormasaydık gzip "not in gzip
# format" derdi ve operatör yedeğin BOZUK olduğunu sanıp onu silerdi — oysa
# dosya sapasağlam, eksik olan anahtar.
enc_dogrula() {   # enc_dogrula <dosya>
    local f="$1" base sihir c kdf md it
    base="$(basename "$f")"
    read -r sihir c kdf md it _ <<< "$(head -c "$ENC_BASLIK" "$f" 2>/dev/null)"
    if [ "$sihir" != "$ENC_SIHIR" ]; then
        berr "Şifreli yedeğin başlığı tanınmıyor: $base"
        berr "  Bu betiğin ürettiği bir yedek değil ya da dosyanın BAŞI kesilmiş."
        return 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        berr "Bu yedek ŞİFRELİ ama 'openssl' komutu yok: $base"
        err  "  Kurun:  Debian/Ubuntu → sudo apt-get install -y openssl"
        err  "          Alpine        → apk add --no-cache openssl"
        return 1
    fi
    if [ -z "$ENC_KEY" ]; then
        berr "Bu yedek ŞİFRELİ, BACKUP_ENCRYPT_KEY tanımlı değil: $base"
        berr "  .env'de BACKUP_ENCRYPT_KEY (ya da BACKUP_ENCRYPT_KEY_FILE) verin, sonra tekrar deneyin."
        berr "  ANAHTAR KAYIPSA BU DOSYA AÇILAMAZ; kurtarmanın başka yolu yoktur (docs/BACKUP.md)."
        return 1
    fi
    # Anahtar DOĞRU mu? Bu yığında şifrelenen her akış gzip'tir (sql.gz,
    # tar.gz, rdb.gz, json.gz, archive.gz, dump.gz) — yani çözülen ilk iki
    # bayt 1f 8b OLMALI.
    # openssl'in kendi çıkış koduna güvenmiyoruz: CBC dolgu hatası akışın
    # SONUNDA anlaşılır, yani 30 GB'lık bir dosyayı yanlış anahtarla baştan
    # sona okuduktan sonra "bad decrypt" der. Cevabı 40 dakika geç vermek,
    # geri yükleme sırasında verilebilecek en pahalı cevaptır. İlk iki bayt
    # aynı cevabı ANINDA veriyor.
    if ! command -v od >/dev/null 2>&1; then
        warn "od bulunamadı: $base'in anahtarı ÖN KONTROLDEN geçirilemedi."
        log  "  Yanlış anahtar ancak dosya sonuna gelindiğinde anlaşılacak."
        return 0
    fi
    local m
    m="$(oku_ham "$f" 2>/dev/null | head -c 2 | od -An -tx1 | tr -d ' \n')"
    if [ "$m" != "1f8b" ]; then
        berr "Bu yedeğin ŞİFRESİ ÇÖZÜLEMEDİ: $base"
        berr "  Elinizdeki anahtar bu dosyaya ait değil (ya da dosya kurcalanmış)."
        berr "  Çözülen ilk baytlar: ${m:-yok} — beklenen: 1f8b (gzip)."
        berr "  Anahtar kaynağı: ${ENC_KAYNAK:-?}. Yedeğin alındığı gün geçerli olan anahtarı kullanın."
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------ yardımcı
engine_field() {   # engine_field <id> <python-ifade>
    python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
e=[x for x in c["engines"] if x["id"]==sys.argv[2]]
if not e: sys.exit(1)
e=e[0]
print(eval(sys.argv[3], {"e": e}))' "$CATALOG" "$1" "$2" 2>/dev/null
}
backupable_engines() {
    python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if e.get("backup",{}).get("supported")))' "$CATALOG"
}

# Şifreli dosya adı BURADA doğuyor, motor fonksiyonlarında değil: on bir
# motorun her birine `.enc` eklemeyi hatırlatmak yerine tek yerde ekliyoruz.
# Unutulan tek motor, "şifreleme açık" denen bir kurulumda düz metin dosya
# üretirdi ve bunu kimse fark etmezdi.
out_path() {  # out_path <motor> <tip> <uzantı>
    local d="$BACKUP_DIR/$1/$2"
    mkdir -p "$d"
    local ad; ad="$(printf '%s/%s_%s_%s.%s' "$d" "$1" "$2" "$DATE" "$3")"
    enc_acik && ad="$ad.$ENC_EXT"
    printf '%s' "$ad"
}

# Yedek akışının SON HALKASI. Bütün motorlar dökümlerini buraya boru ile
# veriyor; sıkıştırma ve (açıksa) şifreleme tek yerde.
#
# NEDEN BORUDA, "önce .gz yaz sonra şifrele" DEĞİL: ikinci yol daha kolay
# yazılırdı ama düz metin dump bir süre DİSKTE dururdu. BACKUP_DIR çoğu
# kurulumda ayrı bir birimdir — .env.example'ın kendisi
# `BACKUP_DIR=/mnt/backups` örneğini veriyor ve bu tipik olarak ağdan
# bağlanmış bir NAS'tır. Orada düz
# metin dump'ın saniyeler durması bile, şifrelemenin engellemeye çalıştığı
# şeyin ta kendisidir. Boruda şifrelerken düz metin diske HİÇ yazılmaz.
paketle() {   # stdin → <dosya>   (gzip + varsa şifreleme)
    local hedef="$1"
    if enc_acik; then
        # İki adım: önce başlık, sonra ekleme. Tek bir `{ …; } > dosya`
        # grubunda PIPESTATUS'un hangi boru hattına ait olduğu okuyana göre
        # değişir; burada belirsizliğe yer yok, çünkü bu iki kodun kaybolması
        # "sessizce yarım yedek" demek.
        enc_baslik > "$hedef" || return 1
        "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" | sifrele >> "$hedef"
        local ps=("${PIPESTATUS[@]}")
        [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ]
        return $?
    fi
    "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$hedef"
}

# Akışın ZATEN sıkıştırılmış geldiği tek motor için (mongodump --archive
# --gzip kendi gzip'ini yazar). Burada ikinci kez gzip'lemek boşuna CPU ve
# `.archive.gz` sözleşmesini bozardı; yapılacak tek iş varsa şifrelemek.
paketle_hazir() {   # stdin → <dosya>
    local hedef="$1"
    if enc_acik; then
        enc_baslik > "$hedef" || return 1
        sifrele >> "$hedef"
        return $?
    fi
    cat > "$hedef"
}

check_disk() {
    local avail_kb; avail_kb="$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
    # -P (POSIX) şart: uzun aygıt adlarında df çıktısı iki satıra bölünür ve
    # sütun numaraları kayar; -P bunu engeller.
    if [ "${avail_kb:-0}" -lt 5242880 ]; then
        berr "Disk kritik: 5 GB'dan az boş alan var, yedekleme iptal."
        return 1
    fi
    [ "$avail_kb" -lt 10485760 ] && warn "Disk azalıyor: $((avail_kb/1024)) MB boş"
    return 0
}

# Bir yedekleme ürününde en pahalı hata, felaket günü dosyayı açıp İÇİNİ BOŞ
# bulmaktır. Eski sürüm yalnız "dosya duruyor mu, arşiv bozuk mu" diye bakıyordu:
# boş bir dizinin tar.gz'si 115 bayt, boş girdinin gzip'i 20 bayttır ve İKİSİ DE
# bu testlerden geçip "Bütünlük doğrulandı" damgası yiyordu — ClickHouse'da ve
# MSSQL'de aylarca sessizce böyle oldu. Artık dosyanın gerçekten geri
# yüklenebilir içerik taşıdığına da bakıyoruz; her motorun biçimi farklı olduğu
# için kontrol de biçime göre değişiyor.
verify_backup() {
    local f="${1:-}"
    [ -n "$f" ] || { berr "Doğrulanacak dosya belirtilmedi. Örnek: ./scripts/backup.sh verify backups/mariadb/full/<dosya>"; return 1; }
    [ -f "$f" ] || { berr "Yedek dosyası yok: $f"; return 1; }
    [ -s "$f" ] || { berr "Yedek dosyası boş: $f — bu yedek KULLANILAMAZ."; return 1; }
    local base detay="" enc_not=""; base="$(basename "$f")"

    # ŞİFRELİ DOSYA. Önce AÇILABİLİRLİK, sonra biçim: şifreleme bir ZARFTIR,
    # dosyanın biçimini değiştirmez. Bu yüzden addan yalnız `.enc` düşürülüyor
    # ve aşağıdaki biçim dalları (tar.gz / archive.gz / gz) HİÇ DEĞİŞMEDEN
    # çalışıyor. `.bozuk` dosyalarda şifre çözmeye hiç girişmiyoruz: o dal
    # zaten reddedecek, önce "anahtar yok" diye bağırmak yanlış yere işaret
    # etmek olurdu.
    local bicim="$base"
    case "$base" in
        *.bozuk) ;;
        *)  if sifreli_mi "$f"; then
                enc_dogrula "$f" || return 1
                bicim="${bicim%.$ENC_EXT}"
                enc_not=", şifreli"
            elif [ "${base%.$ENC_EXT}" != "$base" ]; then
                # Adı ".gz.enc" diyor ama başında imza yok. Bu dosya aşağıdaki
                # hiçbir biçim dalına uymadığı için case'in sonundaki
                # "Tanınmayan biçim → UYARI, çıkış 0" satırına düşerdi: yani
                # doğrulanmamış bir dosya YEŞİL geçerdi. Adın söylediği ile
                # içeriğin söylediği çelişiyorsa cevap "bilmiyorum" değil,
                # "bu dosyayla geri yükleme yapılmaz"dır.
                berr "Adı şifreli yedek diyor ama içeriği öyle değil: $base"
                berr "  Dosyanın başında '$ENC_SIHIR' imzası yok — başı kesilmiş ya da bu betiğin ürettiği bir yedek değil."
                return 1
            fi ;;
    esac

    case "$bicim" in
        *.bozuk)
            # Bu dosyayı BU BETİK kenara aldı (finalize_backup). Uzantısı
            # aşağıdaki dalların hiçbirine uymadığı için case'in sonundaki
            # koşulsuz "Bütünlük doğrulandı" satırına düşüyordu: gece
            # "Doğrulamayı geçemedi, kenara alındı" uyarısını gören operatör
            # dosyayı elle doğrulayınca YEŞİL TİK görüyor, uzantıyı geri alıp
            # o dosyayla geri yüklemeye kalkıyordu.
            berr "Bu dosya doğrulamayı geçemediği için kenara alınmıştı: $base"
            berr "  Kurtarma noktası DEĞİLDİR, geri yüklemede kullanmayın. Neden düştüğü: $LOG_FILE"
            return 1
            ;;
        *.tar.gz)
            # "Dizin olmayan EN AZ BİR üye" ölçütü yetmiyordu: bu arşivlerin
            # hiçbiri tek dosyadan ibaret değil, hepsi çok parçalı. Cassandra
            # arşivi schema.cql + SSTable'lardan oluşur; snapshot dizinleri
            # bulunamazsa (özel data_file_directories) tar YALNIZ schema.cql'i
            # paketleyip 0 ile çıkar. Üstelik o schema.cql 0 bayt bile
            # olabiliyor — ve bu dosya ekranda "1 dosya, Bütünlük doğrulandı"
            # damgası alıyordu; elde sıfır veri vardı. Aynısı ES'te de var:
            # arşivde yalnız depo üstverisi (index-0, index.latest) kalırsa
            # "2 dosya" görünür ama içinde tek indeks yoktur.
            # Bu yüzden artık üç şey birden aranıyor:
            #   1) dizin olmayan bir üye,
            #   2) en az bir üyenin 0 bayttan büyük olması (yalnız dosya
            #      ADLARI taşıyan arşiv veri taşımıyor demektir),
            #   3) motorun geri yüklemede GERÇEKTEN okuduğu dosya türünün
            #      arşivde bulunması (restore_mssql zaten arşivde .bak yoksa
            #      duruyor; aynı ölçütü yedek alınırken uygulamamak için bir
            #      sebep yok).
            local gerek="" gerek_ad=""
            # $bicim, $base DEĞİL: şifreli dosyada ad ".enc" ile biter ve
            # ".gz" ile biten dalların hiçbiri tutmaz. Ölçüldü — bu satır
            # $base iken kesik bir RDB yedeği şifresizken REDDEDİLİYOR,
            # AYNI dosya şifreliyken "Bütünlük doğrulandı" alıyordu.
            case "$bicim" in
                # Desenlerde ters bölü YOK: awk -v ile geçen değerde `\.`
                # kaçış olarak ÇÖZÜLÜR ("escape sequence treated as plain .")
                # ve her koşumda stderr'e uyarı basar — cron mail'inde her gece
                # görünecek bir gürültü. `[.]` aynı işi sessizce yapıyor.
                mssql_*)         gerek='[.]bak$';       gerek_ad='veritabanı yedeği (*.bak)' ;;
                clickhouse_*)    gerek='[.]zip$';       gerek_ad='veritabanı yedeği (*.zip)' ;;
                cassandra_*)     gerek='/snapshots/';   gerek_ad='SSTable snapshot dosyası (*/snapshots/*)' ;;
                elasticsearch_*) gerek='(^|/)indices/'; gerek_ad='indeks verisi (indices/…)' ;;
            esac
            # Tek geçiş: arşivin sağlamlığı, üye sayısı, boyutları ve adları
            # aynı okumadan çıkıyor (büyük yedeklerde arşivi ikinci kez açmak
            # boşuna dakikalar demek). Alt kabuğun sonundaki `exit`, tar'ın
            # çıkış kodunu dışarı taşır — awk'ınkini değil.
            # awk desenleri SATIRIN TAMAMINA uygulanıyor, alan numarasına
            # değil: `tar -tv` çıktısının alan düzeni GNU/BSD tar arasında
            # değişir, ama ad her zaman satırın sonundadır ve izin/sahip/tarih
            # alanlarında "/snapshots/" gibi bir dizi geçmez. Boyut alanı ($3)
            # GNU tar'da sayıdır; sayı değilse boyut ölçütü sessizce devre dışı
            # kalır (yanlış yere "bozuk" demek, kaçırmaktan daha pahalıdır).
            local sayim trc uye sayilir dolu esles
            sayim="$(oku_tar "$f" 2>/dev/null | awk -v d="$gerek" '
                $0 ~ /\/$/ { next }                       # dizin üyesi
                { uye++
                  if ($3 ~ /^[0-9]+$/) { sayilir++; if ($3 + 0 > 0) dolu++ }
                  if (d != "" && $0 ~ d) esles++ }
                END { printf "%d %d %d %d", uye, sayilir, dolu, esles }'
                exit "${PIPESTATUS[0]}")"; trc=$?
            [ "$trc" -eq 0 ] || { berr "Bozuk arşiv: $base — bu yedek KULLANILAMAZ."; return 1; }
            read -r uye sayilir dolu esles <<< "${sayim:-0 0 0 0}"
            if [ "${uye:-0}" -lt 1 ]; then
                berr "Yedeğin İÇİ BOŞ: $base — arşivde tek dosya bile yok, geri yüklenemez."
                berr "  Motorun o anki hatası burada: $LOG_FILE"
                return 1
            fi
            if [ "${sayilir:-0}" -gt 0 ] && [ "${dolu:-0}" -eq 0 ]; then
                berr "Yedeğin İÇİ BOŞ: $base — arşivdeki $uye dosyanın hepsi 0 bayt, geri yüklenemez."
                berr "  Motorun o anki hatası burada: $LOG_FILE"
                return 1
            fi
            if [ -n "$gerek" ] && [ "${esles:-0}" -eq 0 ]; then
                berr "Yedek EKSİK: $base — arşivde $gerek_ad yok, yalnızca üstveri var."
                berr "  Bu dosyadan geri yükleme YAPILAMAZ; motorun o anki hatası burada: $LOG_FILE"
                return 1
            fi
            detay=", $uye dosya"
            ;;
        *.archive.gz)
            # ─────────────────────────────────────────────────────────────────
            # BU DAL İKİ KEZ YANLIŞ ÖLÇÜLDÜ. İkisi de doğru dosyaya bakıyordu
            # ama sorduğu soru "bu arşiv geri yüklenebilir mi?" DEĞİLDİ:
            #
            #  1) İmza kontrolü  → "dosya mongodump çıktısı gibi BAŞLIYOR mu?"
            #     Kesilmiş bir dosyanın da başı doğrudur; bu soru kesikliği
            #     göremez. Üstelik beklenen imza da yanlıştı (aşağıda).
            #  2) 256 bayt eşiği → "dump BAŞLADI mı?"
            #     Dayandığı "gerçek arşiv kilobayt mertebesindedir" varsayımı
            #     sahada doğru değil: hiç kullanıcı verisi olmayan bir mongo:7.0
            #     sunucusunun tam ve geçerli arşivi 855 BAYT. Yani eşik hem
            #     sınırda hem de yalnız "dump hiç başlamadı" hâlini yakalıyor.
            #
            # İkisi de AKIŞIN BAŞINA bakıyor; oysa yedeği öldüren şey akışın
            # SONUDUR. 2000 belgelik gerçek bir arşivi (16942 bayt) 400 bayta
            # kestik: her iki kontrolden de geçip "Bütünlük doğrulandı" aldı,
            # mongorestore ise "corruption found in archive … unexpected EOF"
            # dedi. Felaket günü ekranda yeşil tik, elde yarım veri.
            #
            # DOĞRU ÖLÇÜT: akış SONUNA KADAR sağlam mı? Üç şeye birden bakıyoruz.
            #
            # (a) Zarf. Bu yığında mongodump --archive --gzip DÜZ GZIP yazar:
            #     dosyanın ilk baytları 1f 8b 08 00, arşiv gzip'in İÇİNDEDİR.
            #     (Eski yorumdaki "GZIP DOSYASI DEĞİLDİR" cümlesi mongo:7.0'da
            #     ölçüldü, doğru değil. `--gzip`siz `--archive` ise gerçekten
            #     6d e2 99 81 ile başlar; o hâl de destekleniyor.) Gzip'in
            #     sonundaki CRC32+uzunluk, akışı yazanın işini BİTİRDİĞİNİ
            #     kanıtlar — dump yarıda ölürse bu kuyruk hiç yazılmaz. Bu
            #     yüzden gzip'i sonuna kadar açıyoruz.
            # (b) İçerik. Zarfın içinden mongodump arşivi mi çıkıyor? Açılmış
            #     akış 6d e2 99 81 ile başlamalı; başlamıyorsa dosya .archive.gz
            #     adını taşısa bile mongo yedeği değildir.
            # (c) Son. Arşiv biçiminin sonlandırıcısı ff ff ff ff'tir; tamamlanan
            #     her arşiv onunla biter. Zarfı olmayan (sıkıştırmasız) hâlde
            #     elimizdeki TEK son-kontrolü budur.
            #
            # "gzip -t yeter" demedik, çünkü ZARF ile İÇERİK ayrı şeylerdir:
            # `üretici | gzip > dosya` zincirinde sol taraf yarıda ölse bile
            # gzip EOF görüp akışı kusursuz kapatabilir. Bunu da ürettik —
            # gzip -t rc=0 verdi, mongorestore 2000 belgenin 1150'sini yükleyip
            # "archive io error" ile düştü. Sonlandırıcı o hâli yakalıyor.
            #
            # Daha da ileri gidip sondaki namespace kapanış kaydını (EOF/CRC
            # alanları) aramadık: onlar mongo-tools'un iç alan adlarıdır, sürüm
            # değiştirince SAPASAĞLAM her yedeğe "bozuk" dedirtme riski
            # taşırlar. ff ff ff ff ise arşiv biçiminin sabiti.
            # ─────────────────────────────────────────────────────────────────
            if ! command -v od >/dev/null 2>&1; then
                warn "od bulunamadı: $base'in SONUNA bakılamadı."
                log  "  Yalnızca 'dosya var ve boş değil' kontrol edildi; İÇERİĞİ DOĞRULANMADI."
                return 0
            fi
            local magic ic_magic son arc
            # Baytlar `oku_ham`dan geliyor: dosya şifreliyse ÖNCE çözülür.
            # Aşağıdaki bütün imza/son kontrolleri artık "zarfın içindeki"
            # akışa bakıyor; şifreleme onların hiçbirini değiştirmiyor.
            magic="$(oku_ham "$f" 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n')"
            case "$magic" in
                1f8b*)
                    # `head -c 4` erken çıkar (SIGPIPE): koca arşiv için bile
                    # tek blokluk okuma.
                    ic_magic="$(oku_akis "$f" 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n')"
                    # Tek TAM geçiş: gzip'in çıkış kodu (zarf sonuna kadar sağlam
                    # mı) ve arşivin son dört baytı aynı okumadan çıkıyor —
                    # büyük yedeklerde dosyayı ikinci kez açmak boşuna dakikalar
                    # demek. Alt kabuğun sonundaki `exit`, gzip'in çıkış kodunu
                    # dışarı taşır; od/tr'ninkini değil.
                    son="$(oku_akis "$f" 2>>"$LOG_FILE" | tail -c 4 | od -An -tx1 | tr -d ' \n'
                           exit "${PIPESTATUS[0]}")"; arc=$?
                    if [ "$arc" -ne 0 ]; then
                        berr "MongoDB arşivi YARIM: $base — gzip akışı sonuna gelmeden kesilmiş."
                        berr "  Bu dosya kurtarma noktası DEĞİLDİR: mongorestore veriyi yarıda bırakır."
                        berr "  Motorun o anki hatası burada: $LOG_FILE"
                        return 1
                    fi
                    ;;
                6de29981)
                    # Sıkıştırmasız --archive: zarf yok, dosyanın kendisi arşiv.
                    ic_magic="$magic"
                    son="$(oku_ham "$f" 2>/dev/null | tail -c 4 | od -An -tx1 | tr -d ' \n')"
                    ;;
                *)
                    berr "MongoDB arşivi tanınmıyor: $base — mongodump çıktısı değil."
                    berr "  İlk baytlar: ${magic:-yok} (beklenen: 1f8b… ya da 6de29981)"
                    return 1
                    ;;
            esac
            if [ "$ic_magic" != "6de29981" ]; then
                berr "MongoDB arşivi tanınmıyor: $base — gzip'in içinden mongodump arşivi çıkmadı."
                berr "  Açılmış ilk baytlar: ${ic_magic:-yok} (beklenen: 6de29981)"
                return 1
            fi
            if [ "$son" != "ffffffff" ]; then
                berr "MongoDB arşivi YARIM: $base — arşiv sonlandırıcısı yok, akış bitmeden kesilmiş."
                berr "  Bu dosya kurtarma noktası DEĞİLDİR: mongorestore veriyi yarıda bırakır."
                berr "  Motorun o anki hatası burada: $LOG_FILE"
                return 1
            fi
            ;;
        *.gz)
            # Bu dalda gzip ZARFI baştan sona sınanıyordu (`gzip -t`), ama
            # İÇERİK yalnız BAŞINDAN. Aynı sınıf hata: `üretici | gzip > dosya`
            # zincirinde sol taraf yarıda ölürse gzip boruda EOF görüp akışı
            # kusursuz kapatır — zarf sağlam, içerik yarım. Bu yüzden artık
            # içeriğin SONUNA da bakıyoruz.
            #
            # Kuyruk, `gzip -t` yerine geçen TEK TAM GEÇİŞTEN çıkıyor: gzip'in
            # çıkış kodu zarfı, son 16 bayt da içeriği cevaplıyor. `gzip -t` de
            # dosyayı baştan sona okuduğu için maliyet ARTMADI (büyük yedeklerde
            # ikinci bir tam geçiş boşuna dakikalar demek). od yoksa eski
            # davranışa düşüyoruz: zarf sınanır, sona bakılmaz.
            local kuyruk="" grc
            if command -v od >/dev/null 2>&1; then
                kuyruk="$(oku_akis "$f" 2>>"$LOG_FILE" | tail -c 16 | od -An -tx1 | tr -d ' \n'
                          exit "${PIPESTATUS[0]}")"; grc=$?
            else
                # `gzip -t` yerine oku_akis: dosya şifreliyse `gzip -t` zaten
                # onu okuyamaz ve SAPASAĞLAM bir yedeğe "bozuk gzip" derdi.
                oku_akis "$f" >/dev/null 2>&1; grc=$?
            fi
            [ "$grc" -eq 0 ] || { berr "Bozuk gzip: $base — bu yedek KULLANILAMAZ."; return 1; }
            # Açılmış ilk 64 KB hem "içi tamamen boş mu" hem de "beklenen biçimde
            # mi" sorusunu tek okumada cevaplar. NUL baytları atılıyor: kabuk
            # değişkeni ikili veriyi olduğu gibi taşıyamaz (RDB dosyaları ikili).
            local head64; head64="$(oku_akis "$f" 2>/dev/null | head -c 65536 | tr -d '\000')"
            if [ "${#head64}" -eq 0 ]; then
                berr "Yedeğin İÇİ BOŞ: $base — açıldığında tek bayt bile çıkmıyor."
                berr "  Motorun o anki hatası burada: $LOG_FILE"
                return 1
            fi
            # $bicim şart — yukarıdaki tar.gz dalındaki gerekçenin aynısı.
            case "$bicim" in
                *.sql.gz)
                    # Geri yüklenebilir bir dump en az bir DDL/DML satırı taşır.
                    # Yalnızca SET/başlık satırları varsa döküm yarıda kesilmiştir.
                    case "$head64" in
                        *CREATE*|*INSERT*|*COPY*|*GRANT*|*"DROP "*) ;;
                        *) berr "Yedeğin İÇİ BOŞ görünüyor: $base — dump'ta hiç CREATE/INSERT satırı yok."; return 1 ;;
                    esac
                    # SQL dump'larının SONUNA BİLEREK bakmıyoruz. Ölçtük:
                    # mariadb-dump --skip-comments çıktısı sunucu SÜRÜMÜNE göre
                    # değişen bir satırla bitiyor (MariaDB 11'de
                    # `/*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY */;`,
                    # eskilerde COLLATION_CONNECTION satırı), pg_dumpall ise
                    # bambaşka bir yorum satırıyla. Böyle bir imzaya bağlanmak,
                    # motor sürümü yükseldiği gün SAPASAĞLAM her yedeğe "bozuk"
                    # dedirtir — ve bir yedeğe haksız yere bozuk demek, onu YOK
                    # saymakla aynı şeydir. Kesilme riski burada zaten üretim
                    # tarafında kapalı: dump borusunun sol tarafı PIPESTATUS ile
                    # kontrol ediliyor (backup_mariadb / backup_postgresql).
                    ;;
                *.rdb.gz)
                    # RDB dosyaları her zaman "REDIS<sürüm>" imzasıyla başlar.
                    case "$head64" in
                        REDIS*) ;;
                        *) berr "Redis yedeği geçerli bir RDB değil: $base"; return 1 ;;
                    esac
                    # …ve her zaman EOF işlemcisiyle (ff) + 8 baytlık sağlama
                    # ile BİTER. Bu bir sürüm dizgesi değil, RDB biçiminin
                    # sabiti: boş bir veritabanında da, `rdbchecksum no` ile de
                    # (sağlama alanı sıfırlarla dolar) aynı. Başı doğru olan
                    # kesik bir RDB eski ölçütten geçiyordu; oysa restore_redis
                    # o dosyayı volume'a koymadan ÖNCE eski dump.rdb'yi ve AOF'u
                    # SİLİYOR. Redis kesik RDB'yi yüklemez, hiç açılmaz
                    # ("Unexpected EOF reading RDB file") — geriye ne eski veri
                    # ne yenisi kalır. Sondan 9. bayt ff olmalı; sağlaması
                    # olmayan çok eski RDB'lerde dosya doğrudan ff ile biter.
                    if [ -n "$kuyruk" ] \
                       && [ "${kuyruk: -18:2}" != "ff" ] && [ "${kuyruk: -2}" != "ff" ]; then
                        berr "Redis yedeği YARIM: $base — RDB sonlandırıcısı yok, akış bitmeden kesilmiş."
                        berr "  Bu dosyayla geri yüklerseniz Redis HİÇ AÇILMAZ ve eski veri de silinmiş olur."
                        berr "  Motorun o anki hatası burada: $LOG_FILE"
                        return 1
                    fi ;;
                *.json.gz)
                    case "$head64" in
                        \{*) ;;
                        *) berr "RabbitMQ tanımları JSON değil: $base — dışa aktarma yarım kalmış."; return 1 ;;
                    esac
                    # Başı `{` olan JSON'ın sonu da `}` olmalı — bu bir sürüm
                    # imzası değil, biçimin tanımı. Kesik bir export'un başı
                    # kusursuzdur, sonu yoktur. Sondaki boşluk/satır sonu
                    # baytlarını (0a 0d 09 20) atıp son bayta bakıyoruz.
                    if [ -n "$kuyruk" ]; then
                        local jk="$kuyruk"
                        while :; do
                            case "$jk" in *0a|*0d|*09|*20) jk="${jk%??}" ;; *) break ;; esac
                        done
                        if [ "${jk: -2}" != "7d" ]; then
                            berr "RabbitMQ tanımları YARIM: $base — JSON kapanmıyor, dışa aktarma kesilmiş."
                            berr "  Bu dosyadan exchange/queue/binding tanımları geri getirilemez."
                            berr "  Motorun o anki hatası burada: $LOG_FILE"
                            return 1
                        fi
                    fi ;;
            esac
            ;;
        *)
            # Tanınmayan uzantı da case'in sonundaki koşulsuz "Bütünlük
            # doğrulandı" satırına düşüyordu: düz bir metin dosyası bile yeşil
            # tik alıyordu. Doğrulanmamış bir dosyaya doğrulandı demektense
            # kullanıcıya ne KONTROL EDİLMEDİĞİNİ söylüyoruz.
            warn "Tanınmayan biçim: $base — bu betiğin ürettiği bir yedek değil."
            log  "  Yalnızca 'dosya var ve boş değil' kontrol edildi; İÇERİĞİ DOĞRULANMADI."
            return 0
            ;;
    esac
    bok "Bütünlük doğrulandı: $base ($(du -h "$f" | cut -f1)$detay$enc_not)"
}

# Yedek ALMA yolunda verify_backup yerine bu kullanılır. Doğrulamayı geçemeyen
# dosya olduğu yerde kalırsa `list` ve `stats` onu geçerli bir kurtarma noktası
# gibi sayar, clean_old'un "son N kopyayı koru" tabanı da onu korur; yani
# kullanıcı elinde olmayan bir yedeğe güvenmeye devam eder. Silmiyoruz da —
# ürettiğimiz dosyayı yok etmek yerine .bozuk uzantısıyla kenara koyuyoruz;
# incelenebilir kalsın ama yedek sanılmasın. (clean_old bunları da süpürür.)
finalize_backup() {
    local f="$1"
    verify_backup "$f" && return 0
    mv -f "$f" "$f.bozuk" 2>/dev/null \
        && berr "Doğrulamayı geçemedi, kenara alındı: $(basename "$f").bozuk" \
        || rm -f "$f"
    return 1
}

# =============================================================================
# MOTOR YEDEKLERİ
# =============================================================================

backup_mariadb() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of mariadb)"
    local f; f="$(out_path mariadb full sql.gz)"
    blog "MariaDB yedekleniyor…"

    # Hariç tutulacak tablolar (Telescope/Pulse gibi büyük, atılabilir tablolar)
    local ignore=""
    if [ -n "$BACKUP_EXCLUDE_TABLE_PATTERNS" ]; then
        local where="" p
        for p in $BACKUP_EXCLUDE_TABLE_PATTERNS; do
            [ -n "$where" ] && where+=" OR "
            where+="TABLE_NAME LIKE '$p'"
        done
        ignore="$(MYSQL_PWD="${MARIADB_PASSWORD:-$DB_PASSWORD}" docker exec -e MYSQL_PWD "$C" \
            mariadb -u root -N -e "SELECT CONCAT('--ignore-table=',TABLE_SCHEMA,'.',TABLE_NAME)
            FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN
            ('information_schema','performance_schema','mysql','sys') AND ($where);" \
            2>>"$LOG_FILE" | tr '\n' ' ')"
        [ -n "$ignore" ] && blog "  hariç: $ignore"
    fi

    # --master-data=2: dump'a binlog konumunu YORUM olarak yazar → bu yedekten
    # sonra biriken binlog'larla point-in-time recovery yapılabilir.
    MYSQL_PWD="${MARIADB_PASSWORD:-$DB_PASSWORD}" "${IO_NICE[@]}" \
        docker exec -e MYSQL_PWD "$C" mariadb-dump -u root \
            --all-databases --single-transaction --quick --routines --triggers \
            --events --hex-blob --add-drop-database --add-drop-table \
            --master-data=2 --skip-comments $ignore \
        2>>"$LOG_FILE" | paketle "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "MariaDB dump başarısız"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_postgresql() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of postgresql)"
    local f; f="$(out_path postgresql full sql.gz)"
    blog "PostgreSQL yedekleniyor…"
    # pg_dumpall roller/parolalar dahil TÜM cluster'ı alır — tek DB'lik
    # pg_dump'ın aksine geri yüklemede kullanıcılar da geri gelir.
    "${IO_NICE[@]}" docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" "$C" \
        pg_dumpall -U "${POSTGRES_USER:-root}" --clean --if-exists --quote-all-identifiers \
        2>>"$LOG_FILE" | paketle "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "PostgreSQL dump başarısız"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_mongodb() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of mongodb)"
    local f; f="$(out_path mongodb full archive.gz)"
    blog "MongoDB yedekleniyor…"
    # --archive ile doğrudan stdout'a yazıyoruz: eski sürüm önce container
    # içinde /tmp/backup dizinine döküp sonra tar'lıyordu; bu, container'ın
    # diskini ve belleğini iki kez zorluyordu.
    "${IO_NICE[@]}" docker exec "$C" mongodump \
        --username "${MONGO_USER:-root}" --password "${MONGO_PASSWORD:-$DB_PASSWORD}" \
        --authenticationDatabase admin --archive --gzip --quiet \
        2>>"$LOG_FILE" | paketle_hazir "$f"
    # Diğer dokuz motor finalize_backup'a çevrilirken mongodb ATLANMIŞTI: kendi
    # `[ -s "$f" ]` kontrolüyle yetiniyor, "MongoDB yedeklendi" deyip
    # geçiyordu. Sonuç, *.archive.gz için yazılan imza/boyut kontrolünün yedek
    # ALMA yolunda ÖLÜ KOD kalmasıydı — hata ancak aylar sonra, geri yükleme
    # denenirken görülecekti. Üstelik doğrulamayı geçemeyen dosya kenara
    # alınmadığı için `list`, `stats` ve sync-remote.sh onu geçerli bir
    # kurtarma noktası sayıp uzak sunucuya da kopyalıyordu.
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "MongoDB dump başarısız. Ayrıntı: $LOG_FILE"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_redis() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of redis)"
    local f; f="$(out_path redis full rdb.gz)"
    blog "Redis yedekleniyor…"
    local pw="${REDIS_PASSWORD:-$DB_PASSWORD}"
    rcli() { docker exec -e REDISCLI_AUTH="$pw" "$C" redis-cli --no-auth-warning "$@"; }

    local before; before="$(rcli LASTSAVE 2>/dev/null | tr -d '[:space:]')"
    rcli BGSAVE >>"$LOG_FILE" 2>&1 || { berr "BGSAVE reddedildi"; return 1; }

    # LASTSAVE değişene kadar bekle — sabit `sleep` ile büyük veri setlerinde
    # yarım yazılmış dump.rdb kopyalanabiliyordu.
    local i=0 now
    while [ $i -lt 120 ]; do
        now="$(rcli LASTSAVE 2>/dev/null | tr -d '[:space:]')"
        [ -n "$now" ] && [ "$now" != "$before" ] && break
        i=$((i+1)); sleep 1
    done
    [ $i -lt 120 ] || warn "BGSAVE 120 sn'de bitmedi; mevcut dump.rdb kopyalanıyor"

    "${IO_NICE[@]}" docker exec "$C" cat /data/dump.rdb 2>>"$LOG_FILE" \
        | paketle "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "Redis dump kopyalanamadı"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_mssql() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    # Bu satır sabit container adları kaldırılırken UNUTULMUŞTU: fonksiyonun
    # gövdesi $C kullanıyor ama hiçbir yerde tanımlı değildi. `set -u` yüzünden
    # bash "C: unbound variable" deyip BÜTÜN betikten çıkıyordu; mssql'den
    # sonraki motorların (cassandra, elasticsearch, rabbitmq, clickhouse,
    # neo4j, minio) hiçbiri yedeklenmiyor, özet tablosu bile basılmıyordu.
    local C; C="$(primary_of mssql)"
    local f; f="$(out_path mssql full tar.gz)"
    local SQLCMD=/opt/mssql-tools18/bin/sqlcmd
    blog "MSSQL yedekleniyor…"
    sq() { SQLCMDPASSWORD="${MSSQL_PASSWORD:-$DB_PASSWORD}" \
           docker exec -e SQLCMDPASSWORD "$C" "$SQLCMD" -S localhost -U sa -C "$@"; }

    docker exec "$C" sh -c 'mkdir -p /var/opt/mssql/backup && rm -f /var/opt/mssql/backup/*.bak' 2>/dev/null

    # database_id>4 → master/tempdb/model/msdb hariç. msdb ve master ayrıca
    # alınıyor: SQL login'leri ve agent job'ları oradadır, yoksa geri yüklemede
    # kullanıcılar "orphaned" kalır.
    local dbs failed=0 db
    dbs="$(sq -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id>4 OR name IN ('master','msdb');" \
           2>>"$LOG_FILE" | tr -d '\r' | grep -v '^$')"
    # master ve msdb HER ZAMAN vardır; liste boş dönüyorsa sorgu düşmüştür
    # (yanlış parola, sunucu henüz ayağa kalkmamış…). Eskiden döngü hiç
    # dönmüyor, failed=0 kalıyor ve BOŞ klasör tar'lanıp "doğrulandı" damgası
    # alıyordu — elde yedek var sanılıyordu.
    [ -n "$dbs" ] || { berr "MSSQL veritabanı listesi alınamadı — sunucu hazır mı, MSSQL_PASSWORD doğru mu? Ayrıntı: $LOG_FILE"; return 1; }
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        blog "  - $db"
        # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir. Bu
        # olmadan başarısız BACKUP sessizce "başarılı" sanılıyordu.
        sq -b -Q "BACKUP DATABASE [$db] TO DISK=N'/var/opt/mssql/backup/${db}.bak' WITH FORMAT, INIT;" \
            >>"$LOG_FILE" 2>&1 || { failed=1; berr "  BACKUP başarısız: $db"; }
    done <<< "$dbs"
    [ "$failed" -eq 0 ] || { docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*.bak'; return 1; }

    "${IO_NICE[@]}" docker exec "$C" tar -cf - -C /var/opt/mssql/backup . 2>>"$LOG_FILE" \
        | paketle "$f"
    local rc="${PIPESTATUS[0]}"
    docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*.bak' 2>/dev/null
    [ "$rc" -eq 0 ] || { berr "MSSQL arşivi alınamadı"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_cassandra() {
    local f; f="$(out_path cassandra full tar.gz)"
    local snap="bk_$DATE"
    blog "Cassandra yedekleniyor…"
    # Önce flush: memtable'daki veri diske inmeden snapshot eksik olur.
    docker exec cassandra nodetool flush >>"$LOG_FILE" 2>&1
    docker exec cassandra nodetool snapshot -t "$snap" >>"$LOG_FILE" 2>&1 \
        || { berr "snapshot alınamadı"; return 1; }
    # Şema de gerekli: snapshot yalnız SSTable'ları içerir, tablo tanımlarını değil.
    # Kullanıcı adını da -e ile geçiyoruz: tek tırnaklı sh -c içindeki
    # ${CASSANDRA_USER} HOST'ta değil CONTAINER'da çözülür, orada da tanımlı
    # değildir — kullanıcı adı değiştirilmişse sessizce yanlış hesapla
    # bağlanmaya çalışılıyordu.
    docker exec -e CQLSH_PW="${CASSANDRA_PASSWORD:-$DB_PASSWORD}" \
                -e CQLSH_USER="${CASSANDRA_USER:-cassandra}" cassandra sh -c \
        'cqlsh -u "$CQLSH_USER" -p "$CQLSH_PW" -e "DESCRIBE SCHEMA;" > /tmp/schema.cql' \
        2>>"$LOG_FILE" \
        || { berr "Cassandra şeması alınamadı (parola ya da yetki?). Şemasız snapshot GERİ YÜKLENEMEZ, yedek alınmadı."
             docker exec cassandra nodetool clearsnapshot -t "$snap" >>"$LOG_FILE" 2>&1
             return 1; }
    # Yönlendirme, komut düşse bile dosyayı (boş olarak) yaratıyor; çıkış kodu
    # hiç bakılmadığı için boş şemalı, geri yüklenemez arşivler "doğrulandı"
    # damgası alıyordu. Boşluk hatası değilse de kullanıcıyı uyar.
    docker exec cassandra sh -c '[ -s /tmp/schema.cql ]' 2>/dev/null \
        || warn "Cassandra şema dökümü boş — bu düğümde kullanıcı keyspace'i yok gibi görünüyor."
    # Aşağıdaki tar'ın içindeki `find` hiçbir snapshot dizini bulamazsa (veri
    # dizini standart yerde değilse: data_file_directories özelleştirilmiş)
    # komut ikamesi BOŞ döner ve tar yalnız schema.cql'i paketleyip 0 ile
    # çıkar: `||` yedek dalı hiç çalışmaz, hata da verilmez. İçinde SSTable
    # olmayan bir Cassandra arşivi GERİ YÜKLENEMEZ. Bunu arşivi üretmeden önce
    # söylüyoruz — verify_backup aynı durumu arşiv tarafında da yakalıyor ama
    # NEDENİNİ yalnız burası bilir.
    local snapdir
    snapdir="$(docker exec cassandra find /var/lib/cassandra/data -type d -name "$snap" -print -quit 2>>"$LOG_FILE")"
    if [ -z "$snapdir" ]; then
        berr "Cassandra snapshot dosyaları bulunamadı: /var/lib/cassandra/data altında '$snap' yok."
        berr "  Bu arşivde VERİ olmazdı, yedek alınmadı. Veri dizini özelleştirildiyse docs/BACKUP.md'ye bakın."
        docker exec cassandra nodetool clearsnapshot -t "$snap" >>"$LOG_FILE" 2>&1
        return 1
    fi
    "${IO_NICE[@]}" docker exec cassandra sh -c \
        "tar -cf - -C /tmp schema.cql \$(find /var/lib/cassandra/data -type d -name '$snap' -printf '%P\n' 2>/dev/null | sed 's|^|-C /var/lib/cassandra/data |') 2>/dev/null || tar -cf - -C /var/lib/cassandra/data . --wildcards '*/snapshots/$snap/*'" \
        2>>"$LOG_FILE" | paketle "$f"
    local rc="${PIPESTATUS[0]}"
    docker exec cassandra nodetool clearsnapshot -t "$snap" >>"$LOG_FILE" 2>&1
    [ "$rc" -eq 0 ] || { berr "Cassandra arşivi alınamadı"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_elasticsearch() {
    local f; f="$(out_path elasticsearch full tar.gz)"
    local snap="bk_$DATE"
    blog "Elasticsearch yedekleniyor…"
    es() { docker exec elasticsearch curl -sf -u "elastic:${ELASTIC_PASSWORD:-$DB_PASSWORD}" "$@"; }

    # Snapshot deposu (path.repo=/snapshots compose'da tanımlı). Veri dizinini
    # kopyalamak TUTARSIZ olur — ES'te doğru yol snapshot API'sidir.
    es -X PUT "http://localhost:9200/_snapshot/backup_repo" -H 'Content-Type: application/json' \
       -d '{"type":"fs","settings":{"location":"/snapshots"}}' >>"$LOG_FILE" 2>&1
    es -X PUT "http://localhost:9200/_snapshot/backup_repo/$snap?wait_for_completion=true" \
       -H 'Content-Type: application/json' -d '{"indices":"*","include_global_state":true}' \
       >>"$LOG_FILE" 2>&1 || { berr "snapshot başarısız"; return 1; }

    # Depoyu buda. Eski sürüm hiçbir snapshot'ı SİLMİYORDU: her gece bir yenisi
    # ekleniyor, /snapshots volume'u şişiyor (ES disk watermark'a takılınca
    # indeksleri read-only'ye çevirir → yazma kesintisi) ve o günün arşivi TÜM
    # geçmişi taşıyordu; 30. günde arşiv 30 snapshot'lık oluyordu. Arşivin
    # kendisi host'ta durduğu için depoda yalnızca en yeni snapshot yeterli.
    # Budama tar'dan ÖNCE: arşive yalnız bugünün snapshot'ı girsin.
    local old s
    old="$(es "http://localhost:9200/_cat/snapshots/backup_repo?h=id" 2>/dev/null | tr -d '\r' | grep -vFx "$snap")"
    for s in $old; do
        [ -n "$s" ] || continue
        if es -X DELETE "http://localhost:9200/_snapshot/backup_repo/$s" >>"$LOG_FILE" 2>&1; then
            blog "  depodan silindi: $s"
        else
            warn "  eski snapshot depodan silinemedi: $s"
        fi
    done

    "${IO_NICE[@]}" docker exec elasticsearch tar -cf - -C /snapshots . 2>>"$LOG_FILE" \
        | paketle "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "ES arşivi alınamadı"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_clickhouse() {
    local f; f="$(out_path clickhouse full tar.gz)"
    blog "ClickHouse yedekleniyor…"
    # Parola CONTAINER'da çözülmeli. Eski sürümde `--password "$CH_PW"` ÇİFT
    # tırnak içindeydi: host'ta genişliyordu, host'ta böyle bir değişken de
    # olmadığı için `set -u` komut ikamesinin alt kabuğunu öldürüyordu. Sonuç
    # sessizdi ve pahalıydı: veritabanı listesi BOŞ kalıyor, hiç BACKUP
    # çalışmıyor, boş klasör tar'lanıyor ve "Bütünlük doğrulandı" deniyordu.
    # Tek tırnaklı sh -c sarmalayıcısı (cassandra'daki doğru desen) bunu
    # container'a taşır.
    ch() { docker exec -e CH_PW="${CLICKHOUSE_PASSWORD:-$DB_PASSWORD}" \
                       -e CH_USER="${CLICKHOUSE_USER:-default}" clickhouse \
           sh -c 'exec clickhouse-client --user "$CH_USER" --password "$CH_PW" "$@"' sh "$@"; }
    local dbs db rc
    dbs="$(ch --query "SELECT name FROM system.databases WHERE name NOT IN ('system','INFORMATION_SCHEMA','information_schema')" 2>>"$LOG_FILE")"; rc=$?
    [ "$rc" -eq 0 ] || { berr "ClickHouse'a bağlanılamadı — CLICKHOUSE_PASSWORD doğru mu? Ayrıntı: $LOG_FILE"; return 1; }
    [ -n "$dbs" ] || { berr "ClickHouse'ta yedeklenecek veritabanı yok — boş yedek üretmemek için durduruldu."; return 1; }
    docker exec clickhouse sh -c 'rm -rf /var/lib/clickhouse/backups/* ' 2>/dev/null
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        blog "  - $db"
        ch --query "BACKUP DATABASE \`$db\` TO Disk('backups', '${db}.zip')" >>"$LOG_FILE" 2>&1 \
            || { berr "  BACKUP başarısız: $db"; return 1; }
    done <<< "$dbs"
    "${IO_NICE[@]}" docker exec clickhouse tar -cf - -C /var/lib/clickhouse/backups . 2>>"$LOG_FILE" \
        | paketle "$f"
    rc="${PIPESTATUS[0]}"
    docker exec clickhouse sh -c 'rm -rf /var/lib/clickhouse/backups/*' 2>/dev/null
    [ "$rc" -eq 0 ] || { berr "ClickHouse arşivi alınamadı"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_rabbitmq() {
    local f; f="$(out_path rabbitmq full json.gz)"
    blog "RabbitMQ tanımları yedekleniyor…"
    # NOT: Kuyruklardaki MESAJLAR yedeklenmez — mesajlar geçicidir, yedeklenecek
    # şey exchange/queue/binding/policy tanımlarıdır.
    docker exec rabbitmq rabbitmqctl export_definitions /tmp/defs.json >>"$LOG_FILE" 2>&1 \
        || { berr "export_definitions başarısız"; return 1; }
    docker exec rabbitmq cat /tmp/defs.json 2>>"$LOG_FILE" | paketle "$f"
    # Boru hattının SOL tarafı hiç kontrol edilmiyordu (dosyadaki tek yerdi):
    # `cat` düşse bile gzip boş girdiden 20 baytlık GEÇERLİ bir dosya üretiyor,
    # verify de ona "doğrulandı" diyordu. İçinde tek exchange/queue tanımı
    # olmayan bu dosyayla RabbitMQ topolojisi geri getirilemez.
    local ps=("${PIPESTATUS[@]}")
    docker exec rabbitmq rm -f /tmp/defs.json 2>/dev/null
    [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ] \
        || { berr "RabbitMQ tanım dosyası okunamadı — yedek alınmadı."; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_minio() {
    local f; f="$(out_path minio full tar.gz)"
    blog "MinIO nesneleri yedekleniyor…"
    # MinIO imajında `tar` YOKTUR (busybox bile değil, tek statik ikili).
    # Bu yüzden arşivi container'ın içinde değil `docker cp` ile DOCKER'a
    # yaptırıyoruz: `docker cp <container>:<yol> -` tar akışını stdout'a verir
    # ve imajın içinde hiçbir araç gerektirmez.
    # Nesneler değişmezdir (immutable), veri dizinini kopyalamak tutarlıdır.
    "${IO_NICE[@]}" docker cp "minio:/data/." - 2>>"$LOG_FILE" \
        | paketle "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "MinIO arşivi alınamadı"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

backup_neo4j() {
    # Neo4j Community'de ÇEVRİMİÇİ yedek yoktur (Enterprise özelliğidir).
    # Dump için veritabanının durması gerekir → kesinti. Bu yüzden `all`
    # içinde otomatik çalışmaz; bilinçli olarak istenmelidir.
    if [ "${BACKUP_NEO4J_OFFLINE:-false}" != "true" ]; then
        warn "Neo4j atlandı: Community sürümde yedek almak veritabanını DURDURMAYI gerektirir."
        warn "  Kesintiyi göze alıyorsanız: BACKUP_NEO4J_OFFLINE=true ./scripts/backup.sh neo4j"
        return 0
    fi
    local f; f="$(out_path neo4j full dump.gz)"
    blog "Neo4j durduruluyor (çevrimdışı yedek)…"
    compose stop neo4j >>"$LOG_FILE" 2>&1
    docker run --rm -v "${STACK_PROJECT:-databases-stack}_neo4j_data:/data" \
        "neo4j:${NEO4J_VERSION:-5-community}" \
        neo4j-admin database dump neo4j --to-stdout 2>>"$LOG_FILE" \
        | paketle "$f"
    local rc="${PIPESTATUS[0]}"
    blog "Neo4j yeniden başlatılıyor…"
    compose --profile neo4j up -d neo4j >>"$LOG_FILE" 2>&1
    [ "$rc" -eq 0 ] || { berr "Neo4j dump başarısız"; rm -f "$f"; return 1; }
    finalize_backup "$f"
}

# =============================================================================
# TÜMÜ
# =============================================================================
backup_all() {
    acquire_lock "$STACK_ROOT/state/backup.lock"
    enc_onkosul || exit 1
    check_disk || exit 1

    heading "Yedekleme — $(date '+%Y-%m-%d %H:%M')"
    # Şifreleme durumunu HER turda yazıyoruz. Sessiz bir "kapalı", uzak depoya
    # düz metin gönderen bir kurulumun tek uyarısı olurdu.
    if enc_acik; then
        log "Şifreleme AÇIK: $ENC_SEBEP — dosyalar .gz.$ENC_EXT olarak yazılacak"
    else
        warn "Şifreleme KAPALI ($ENC_SEBEP) — yedekler DÜZ GZIP yazılıyor."
        warn "  Uzak depo kullanıyorsanız açın: .env → BACKUP_ENCRYPT_KEY (docs/BACKUP.md)"
    fi
    local start; start="$(date +%s)"
    local okc=0 failc=0 skipc=0 eid primary

    for eid in $(backupable_engines); do
        primary="$(primary_of "$eid")"
        if ! container_running "$primary"; then
            printf '  %-14s %s\n' "$eid" "atlandı (kapalı)"
            skipc=$((skipc+1)); continue
        fi
        # Alt kabuk KASITLI: bir motorun beklenmedik kabuk hatası (tanımsız
        # değişken gibi) `set -u` yüzünden BÜTÜN turu ortasından kesiyordu —
        # mssql'de gerçekten oldu ve o geceden sonraki motorların hiçbiri
        # yedeklenmedi, özet tablosu bile basılmadı. Alt kabukta hata yalnız o
        # motoru düşürür, diğerleri yedeklenmeye devam eder.
        if ( "backup_$eid" ); then okc=$((okc+1)); else failc=$((failc+1)); fi
    done

    local dur=$(( $(date +%s) - start ))
    heading "Özet"
    printf '  Başarılı : %d\n  Başarısız: %d\n  Atlanan  : %d (kapalı motorlar)\n' \
        "$okc" "$failc" "$skipc"
    printf '  Süre     : %dm %ds\n' $((dur/60)) $((dur%60))
    printf '  Toplam   : %s\n' "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    printf '  Boş disk : %s\n' "$(df -Ph "$BACKUP_DIR" | awk 'NR==2{print $4}')"
    [ "$failc" -eq 0 ] || return 1
}

# =============================================================================
# GERİ YÜKLEME
# =============================================================================
confirm_restore() {
    local what="$1"
    warn "GERİ YÜKLEME: $what — mevcut veriler ÜZERİNE YAZILACAK."
    if [ "${ASSUME_YES:-}" = "yes" ]; then return 0; fi
    printf "Devam etmek için 'evet' yazın: "
    read -r a; [ "$a" = "evet" ] || { log "İptal edildi"; return 1; }
}

restore_mariadb() {
    local C; C="$(primary_of mariadb)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    # Geri yükleme mevcut veriyi SİLEREK başlar. Elimizdeki dosyanın gerçekten
    # dolu olduğunu silmeden ÖNCE doğruluyoruz — boş bir yedekle başlanan geri
    # yükleme, veriyi geri getirmez, sadece yok eder.
    verify_backup "$f" || die "Bu dosyayla geri yükleme yapılmaz."
    confirm_restore "MariaDB" || return 1
    oku_akis "$f" | MYSQL_PWD="${MARIADB_PASSWORD:-$DB_PASSWORD}" \
        docker exec -e MYSQL_PWD -i "$C" mariadb -u root
    # gzip tarafı da kontrol ediliyor: kesik bir .gz kısmi SQL üretip 1 ile
    # çıkar, istemci o kısmı sorunsuz yutar ve YARIM geri yükleme "başarılı"
    # görünürdü.
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ]; then
        bok "MariaDB geri yüklendi"
    else
        berr "MariaDB geri yüklenemedi — veritabanı YARIM kalmış olabilir. Ayrıntı: $LOG_FILE"
        return 1
    fi
}

restore_postgresql() {
    local C; C="$(primary_of postgresql)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    verify_backup "$f" || die "Bu dosyayla geri yükleme yapılmaz."
    confirm_restore "PostgreSQL" || return 1
    # ------------------------------------------------------------------------
    # ON_ERROR_STOP KULLANILMAZ — kullanılırsa geri yükleme HER SEFERİNDE yarıda
    # kalır ve veri kaybettirir. Sebep: `pg_dumpall --clean` çıktısı, bağlı
    # olduğumuz rolü ve veritabanını da düşürmeye çalışır:
    #     DROP DATABASE IF EXISTS "postgres";  → cannot drop the currently open database
    #     DROP ROLE     IF EXISTS "root";      → current user cannot be dropped
    # Bu iki hata NORMALDİR ve zararsızdır; ama ON_ERROR_STOP=1 ile psql tam o
    # noktada durur — yani DİĞER veritabanları çoktan düşürülmüşken. Elde ne
    # eski veri ne de yenisi kalır. (Bu, bir düzeltme denemesinin ürettiği
    # gerçek bir regresyondu; postgres:16 üzerinde birebir üretilip doğrulandı.)
    #
    # Bunun yerine: psql serbest çalışır, hataları TOPLARIZ ve sonunda
    # BEKLENENLERİ eleyip geriye gerçek hata kalıp kalmadığına bakarız. Böylece
    # hem geri yükleme tamamlanır hem de "her şey patladı ama başarılı dedik"
    # durumu imkânsız olur.
    # (--single-transaction da kullanılamaz: CREATE/DROP DATABASE tek işlem
    # içinde çalıştırılamaz.)
    # ------------------------------------------------------------------------
    local errf; errf="$(mktemp)"
    oku_akis "$f" | docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" -i "$C" \
        psql -U "${POSTGRES_USER:-root}" -d postgres 2>"$errf" >>"$LOG_FILE"
    local ps=("${PIPESTATUS[@]}")
    cat "$errf" >>"$LOG_FILE"

    if [ "${ps[0]}" -ne 0 ]; then
        rm -f "$errf"
        berr "Yedek dosyası açılamadı (bozuk gzip). Geri yükleme yapılmadı."
        return 1
    fi

    # Beklenen (zararsız) hatalar. Hepsi "bağlı olduğumuz oturumu düşüremeyiz"
    # ailesinden; DROP başarısız olunca ardından gelen CREATE de "zaten var"
    # der — o da beklenendir.
    local gercek
    gercek="$(grep -E '^(psql:|ERROR|FATAL|HATA)' "$errf" 2>/dev/null \
        | grep -viE 'current user cannot be dropped|cannot drop the currently open database|role .* already exists|database .* already exists|is being accessed by other users' \
        || true)"
    rm -f "$errf"

    if [ -n "$gercek" ]; then
        berr "PostgreSQL geri yüklenirken hata oluştu — cluster YARIM kalmış olabilir:"
        printf '%s\n' "$gercek" | head -5 | sed 's/^/    /' >&2
        berr "Tam çıktı: $LOG_FILE"
        return 1
    fi
    bok "PostgreSQL geri yüklendi"
}

restore_mongodb() {
    local C; C="$(primary_of mongodb)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    verify_backup "$f" || die "Bu dosyayla geri yükleme yapılmaz."
    confirm_restore "MongoDB" || return 1
    # mongorestore SIKIŞTIRILMIŞ arşiv bekliyor (--gzip), o yüzden oku_akis
    # değil oku_ham: şifre çözülür, gzip'e dokunulmaz.
    # Boru hattının İKİ ucu da kontrol ediliyor. Eskiden dosya `< "$f"` ile
    # doğrudan veriliyordu ve yalnız mongorestore'un kodu görülüyordu; dosya
    # açılamadığında (yanlış anahtar, kesik gzip) mongorestore BOŞ girdiyle
    # 0 dönebilir ve "MongoDB geri yüklendi" yazılırdı.
    oku_ham "$f" | docker exec -i "$C" mongorestore \
        --username "${MONGO_USER:-root}" --password "${MONGO_PASSWORD:-$DB_PASSWORD}" \
        --authenticationDatabase admin --archive --gzip --drop
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ]; then
        bok "MongoDB geri yüklendi"
    else
        berr "MongoDB geri yüklenemedi (dosya rc=${ps[0]}, mongorestore rc=${ps[1]}). Ayrıntı: $LOG_FILE"
        return 1
    fi
}

restore_redis() {
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    # 2. adım volume'daki dump.rdb'yi ve AOF'u SİLİYOR; dosyanın gerçek bir RDB
    # olduğunu önce doğrula, yoksa elde hiçbir şey kalmaz.
    verify_backup "$f" || die "Bu dosyayla geri yükleme yapılmaz."
    confirm_restore "Redis" || return 1
    local pw="${REDIS_PASSWORD:-$DB_PASSWORD}"
    local C; C="$(primary_of redis)"
    local proj="${STACK_PROJECT:-databases-stack}"
    local vol="${proj}_redis_data"
    [ "$C" = "redis-replica" ] && vol="${proj}_redis_replica_data"
    local img; img="$(docker inspect "$C" --format '{{.Config.Image}}' 2>/dev/null)"
    [ -n "$img" ] || img="redis:${REDIS_VERSION:-8-alpine}"
    rcli() { docker exec -e REDISCLI_AUTH="$pw" "$C" redis-cli --no-auth-warning "$@"; }

    # ═════════════════════════════════════════════════════════════════════
    # ⚠ REDIS GERİ YÜKLEMESİNİN TUZAĞI
    # appendonly=yes ile açılan Redis AOF dosyasını okur. AOF YOKSA BOŞ
    # BAŞLAR ve dump.rdb'ye HİÇ BAKMAZ — RDB'ye geri düşmez. Yani dosyayı
    # yerine koyup yeniden başlatmak "başarılı" der ve HİÇBİR ŞEY yüklemez.
    # Logda şöyle görünür:  "Creating AOF incr file ... on server start"
    # Doğru sıra: AOF KAPALI başlat (RDB okunur) → AOF'u aç ve yeniden üret
    # → normal yapılandırmaya dön (artık AOF'ta geri yüklenmiş veri var).
    # ═════════════════════════════════════════════════════════════════════

    blog "1/5 Redis durduruluyor"
    compose --profile redis stop "$C" >>"$LOG_FILE" 2>&1

    blog "2/5 RDB yerine konuyor, AOF kalıntıları siliniyor"
    # Container durmuş durumda; işi volume'u bağlayan yardımcı container yapar.
    oku_akis "$f" | docker run -i --rm -v "$vol:/d" --entrypoint sh "$img" -c         'rm -rf /d/appendonlydir /d/appendonly.aof* /d/dump.rdb && cat > /d/dump.rdb && chown 999:999 /d/dump.rdb'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "RDB yazılamadı"; return 1; }

    blog "3/5 Redis AOF KAPALI başlatılıyor (RDB okunabilsin diye)"
    REDIS_APPENDONLY=no compose --profile redis up -d --force-recreate "$C" >>"$LOG_FILE" 2>&1
    local i=0
    while [ $i -lt 60 ]; do rcli PING 2>/dev/null | grep -q PONG && break; sleep 2; i=$((i+1)); done
    [ $i -lt 60 ] || { berr "Redis açılmadı"; return 1; }

    local n; n="$(rcli DBSIZE 2>/dev/null | tr -d '[:space:]')"
    if [ "${n:-0}" -eq 0 ]; then
        berr "Geri yükleme sonrası 0 anahtar — yedek boş ya da RDB yüklenemedi."
        berr "Redis normal yapılandırmaya döndürülüyor."
        compose --profile redis up -d --force-recreate "$C" >>"$LOG_FILE" 2>&1
        return 1
    fi
    blog "    RDB yüklendi: $n anahtar"

    blog "4/5 AOF açılıyor ve geri yüklenen veriden yeniden üretiliyor"
    rcli CONFIG SET appendonly yes >/dev/null
    rcli BGREWRITEAOF >/dev/null
    i=0
    while [ $i -lt 60 ]; do
        rcli INFO persistence 2>/dev/null | grep -q 'aof_rewrite_in_progress:0' && break
        sleep 2; i=$((i+1))
    done

    # Normal yapılandırmaya dön. Bu ŞART: container şu an --appendonly no ile
    # yaratılmış durumda; öyle bırakılırsa bir sonraki yeniden başlatmada
    # AOF'u değil eskimiş RDB'yi okur ve aradaki yazmalar kaybolur.
    blog "5/5 Normal yapılandırmaya dönülüyor (AOF açık)"
    compose --profile redis up -d --force-recreate "$C" >>"$LOG_FILE" 2>&1
    i=0
    while [ $i -lt 60 ]; do rcli PING 2>/dev/null | grep -q PONG && break; sleep 2; i=$((i+1)); done

    local n2; n2="$(rcli DBSIZE 2>/dev/null | tr -d '[:space:]')"
    if [ "${n2:-0}" -eq 0 ]; then
        berr "Normal yapılandırmaya dönünce veri kayboldu (AOF üretilememiş olabilir)"
        return 1
    fi
    bok "Redis geri yüklendi ($n2 anahtar)"
}

restore_mssql() {
    local C; C="$(primary_of mssql)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    verify_backup "$f" || die "Bu dosyayla geri yükleme yapılmaz."
    confirm_restore "MSSQL" || return 1
    local SQLCMD=/opt/mssql-tools18/bin/sqlcmd rc=0 bulunan=0 yuklenen=0
    docker exec "$C" sh -c 'mkdir -p /var/opt/mssql/backup && rm -f /var/opt/mssql/backup/*.bak'
    oku_akis "$f" | docker exec -i "$C" tar -xf - -C /var/opt/mssql/backup
    # Arşiv açma hiç kontrol edilmiyordu: açılmazsa klasör boş kalıyor, aşağıdaki
    # döngü hiç dönmüyor, rc başlangıç değeri 0'da kalıyor ve betik HİÇBİR ŞEY
    # yapmadan "MSSQL geri yüklendi" deyip 0 ile çıkıyordu.
    local ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ] \
        || { berr "Yedek arşivi açılamadı: $f"; return 1; }
    for bak in $(docker exec "$C" sh -c 'ls /var/opt/mssql/backup/*.bak 2>/dev/null'); do
        bulunan=$((bulunan+1))
        local db; db="$(basename "$bak" .bak)"
        case "$db" in master|msdb) blog "  $db atlandı (sistem DB'si elle geri yüklenir)"; continue ;; esac
        blog "  geri yükleniyor: $db"
        if SQLCMDPASSWORD="${MSSQL_PASSWORD:-$DB_PASSWORD}" docker exec -e SQLCMDPASSWORD "$C" \
            "$SQLCMD" -S localhost -U sa -C -b \
            -Q "RESTORE DATABASE [$db] FROM DISK=N'$bak' WITH REPLACE;" >>"$LOG_FILE" 2>&1
        then yuklenen=$((yuklenen+1)); else rc=1; fi
    done
    docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*.bak'
    # "Hiç dönmeyen döngü = başarı" tuzağını kapatıyoruz: en az bir veritabanı
    # gerçekten geri yüklenmediyse bu iş BAŞARISIZDIR.
    [ "$bulunan" -gt 0 ] || { berr "Arşivin içinde .bak dosyası yok — bu dosya bir MSSQL yedeği değil."; return 1; }
    [ "$yuklenen" -gt 0 ] || { berr "Hiçbir veritabanı geri yüklenmedi (arşivde yalnızca sistem veritabanları olabilir). Ayrıntı: $LOG_FILE"; return 1; }
    if [ "$rc" -eq 0 ]; then
        bok "MSSQL geri yüklendi ($yuklenen veritabanı)"
    else
        berr "Bazı veritabanları geri yüklenemedi ($yuklenen/$bulunan). Ayrıntı: $LOG_FILE"
        return 1
    fi
}

# =============================================================================
# BAKIM
# =============================================================================
clean_old() {
    local days="${1:-$RETENTION_DAYS}"
    # `clean abc` gibi sayısal olmayan bir argümanda find hata veriyor, 2>/dev/null
    # bunu yutuyor ve kullanıcı "Silinecek yedek yok" görüp temizliğin
    # çalıştığını sanıyordu. Artık ne olduğunu açıkça söylüyoruz.
    case "$days" in
        ''|*[!0-9]*) die "Gün sayısı bir tam sayı olmalı, '$days' değil. Örnek: ./scripts/backup.sh clean 7" ;;
    esac
    # Her motorda EN YENİ birkaç kopya, yaşı ne olursa olsun korunur. Kapalı
    # (ya da yedeği üst üste başarısız olan) bir motorun yedeği yenilenmediği
    # için tarih eşiğini geçiyor ve eski sürüm SON kurtarma noktasını da
    # siliyordu: motor tekrar açıldığında geriye hiçbir yedek kalmıyordu.
    local keep="${BACKUP_KEEP_MIN:-3}"
    heading "$days günden eski yedekler temizleniyor (her motorda en yeni $keep kopya korunur)"

    local d korunan aday liste="" n=0 kalan=0 f
    for d in "$BACKUP_DIR"/*/; do
        [ -d "$d" ] || continue
        korunan="$(find "$d" -type f "${YEDEK_BUL[@]}" -printf '%T@\t%p\n' 2>/dev/null \
                   | sort -rn | head -n "$keep" | cut -f2-)"
        aday="$(find "$d" -type f "${YEDEK_BUL[@]}" -mtime +"$days" 2>/dev/null)"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if printf '%s\n' "$korunan" | grep -Fxq "$f"; then
                kalan=$((kalan+1)); continue
            fi
            liste="$liste$f"$'\n'
            n=$((n+1))
        done <<< "$aday"
    done

    if [ "$n" -eq 0 ]; then
        log "Silinecek yedek yok (son $keep kopya her motorda korunuyor)"
        return 0
    fi
    printf '%s' "$liste" | head -10 | while IFS= read -r f; do
        [ -n "$f" ] && printf '  siliniyor: %s\n' "$(basename "$f")"
    done
    [ "$n" -gt 10 ] && log "  … ve $((n-10)) dosya daha"
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f"
    done <<< "$liste"
    # Doğrulamayı geçemeyip kenara alınmış dosyalar kurtarma noktası değildir;
    # onlarda "son N kopyayı koru" tabanı da aranmaz, yaşı gelen gider.
    find "$BACKUP_DIR" -type f -name '*.bozuk' -mtime +"$days" -delete 2>/dev/null
    bok "$n dosya silindi, $kalan dosya kural gereği korundu (kalan: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1))"
}

list_backups() {
    heading "Mevcut yedekler"
    local eid n
    for eid in $(backupable_engines); do
        n="$(find "$BACKUP_DIR/$eid" -type f "${YEDEK_BUL[@]}" 2>/dev/null | wc -l)"
        printf '\n  %s%s%s  (%d yedek)\n' "$BOLD" "$eid" "$NC" "$n"
        [ "$n" -eq 0 ] && { printf '    yedek yok\n'; continue; }
        find "$BACKUP_DIR/$eid" -type f "${YEDEK_BUL[@]}" -printf '%T@\t%TY-%Tm-%Td %TH:%TM\t%s\t%f\n' 2>/dev/null \
            | sort -rn | head -5 \
            | awk -F'\t' '{printf "    %s  %8.1f MB  %s\n", $2, $3/1048576, $4}'
    done
    printf '\n  Toplam: %s\n\n' "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
}

stats() {
    heading "Yedekleme istatistikleri"
    printf '  Dizin      : %s\n' "$BACKUP_DIR"
    printf '  Toplam     : %s\n' "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    printf '  Boş disk   : %s (%s dolu)\n' \
        "$(df -Ph "$BACKUP_DIR" | awk 'NR==2{print $4}')" \
        "$(df -Ph "$BACKUP_DIR" | awk 'NR==2{print $5}')"
    printf '  Saklama    : %s gün\n' "$RETENTION_DAYS"
    printf '  Şifreleme  : %s (%s)\n\n' "$ENC_DURUM" "${ENC_SEBEP:-yok}"
    printf '  %-14s %6s  %10s  %s\n' "MOTOR" "ADET" "BOYUT" "EN SON"
    printf '  %s\n' "------------------------------------------------------------"
    local eid n sz last
    for eid in $(backupable_engines); do
        n="$(find "$BACKUP_DIR/$eid" -type f "${YEDEK_BUL[@]}" 2>/dev/null | wc -l)"
        sz="$(du -sh "$BACKUP_DIR/$eid" 2>/dev/null | cut -f1)"
        last="$(find "$BACKUP_DIR/$eid" -type f "${YEDEK_BUL[@]}" -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort -r | head -1)"
        printf '  %-14s %6s  %10s  %s\n' "$eid" "$n" "${sz:-0}" "${last:-hiç}"
    done
    echo
}

# =============================================================================
case "${1:-help}" in
    all)        backup_all ;;
    mariadb|postgresql|mongodb|redis|mssql|cassandra|elasticsearch|clickhouse|rabbitmq|minio|neo4j)
                acquire_lock "$STACK_ROOT/state/backup.lock"
                primary="$(primary_of "$1")"
                container_running "$primary" || die "$1 çalışmıyor. Önce: ./stack.sh enable $1"
                enc_onkosul || exit 1
                check_disk || exit 1
                "backup_$1" ;;
    restore-mariadb|restore-postgresql|restore-mongodb|restore-redis|restore-mssql)
                # Yedeklemeyle AYNI kilit. Kilitsizken 02:00 cron'u, yarım geri
                # yüklenmiş bir veritabanını (bazı tablolar yeni, bazıları
                # DROP edilmiş) döküp "geçerli yedek" diye saklıyor ve uzağa
                # senkronluyordu; üstelik iki ağır iş aynı container'ın
                # cgroup'unda çakışınca dosyanın başında anlatılan OOM riski de
                # geri geliyordu.
                acquire_lock "$STACK_ROOT/state/backup.lock"
                "restore_${1#restore-}" "${2:-}" ;;
    restore-*)           die "Bu motor için otomatik geri yükleme yok: ${1#restore-}. docs/BACKUP.md bakın." ;;
    clean)      clean_old "${2:-}" ;;
    list)       list_backups ;;
    stats)      stats ;;
    verify)     verify_backup "${2:-}" ;;
    sifreleme|sifreleme-durumu|encrypt-status)
                # ÇIKIŞ KODU MAKİNE İÇİNDİR — sync-remote.sh bunu okuyor:
                #   0 şifreleme AÇIK ve kullanılabilir
                #   1 yapılandırılmış ama KULLANILAMIYOR (openssl yok, anahtar
                #     dosyası okunamıyor) → çağıran DURMALI, "kapalı" sanmamalı
                #   2 şifreleme KAPALI
                # Kararı ikinci bir betiğe yeniden hesaplatmak yerine buraya
                # sordurmanın sebebi: sözleşmenin tek sahibi bu dosya. İki
                # kopya, .env'e BACKUP_ENCRYPT=false eklendiği gün ayrışır ve
                # sync-remote "nasılsa şifreli" deyip düz metin gönderirdi.
                printf 'durum   : %s\n' "$ENC_DURUM"
                printf 'sebep   : %s\n' "${ENC_SEBEP:-yok}"
                printf 'yöntem  : %s · %s-%s · %s iterasyon\n' \
                    "$ENC_CIPHER" "$ENC_KDF" "$ENC_MD" "$ENC_ITER"
                if enc_acik; then
                    printf 'uzantı  : .gz.%s (yeni yedekler ŞİFRELİ)\n' "$ENC_EXT"
                else
                    printf 'uzantı  : .gz (yeni yedekler ŞİFRESİZ)\n'
                fi
                if [ -n "$ENC_KEY" ]; then
                    printf 'anahtar : tanımlı (%s) — eski şifreli yedekler açılabilir\n' "$ENC_KAYNAK"
                else
                    printf 'anahtar : YOK — şifreli bir yedek varsa AÇILAMAZ\n'
                fi
                case "$ENC_DURUM" in acik) exit 0 ;; bozuk) exit 1 ;; *) exit 2 ;; esac ;;
    *)
cat <<EOF

Yedekleme — databases-stack

  ./scripts/backup.sh all                 Aktif motorların hepsini yedekle
  ./scripts/backup.sh <motor>             Tek motor
  ./scripts/backup.sh list                Yedekleri listele
  ./scripts/backup.sh stats               İstatistikler
  ./scripts/backup.sh clean [gün]         Eski yedekleri sil (varsayılan $RETENTION_DAYS)
  ./scripts/backup.sh verify <dosya>      Bütünlük kontrolü
  ./scripts/backup.sh sifreleme           Yedek şifrelemesinin durumu

  Geri yükleme:
  ./scripts/backup.sh restore-mariadb <dosya>
  ./scripts/backup.sh restore-postgresql <dosya>
  ./scripts/backup.sh restore-mongodb <dosya>
  ./scripts/backup.sh restore-redis <dosya>
  ./scripts/backup.sh restore-mssql <dosya>

Dosya adı sözleşmesi:
  *.gz       şifresiz yedek
  *.gz.enc   şifreli yedek (BACKUP_ENCRYPT_KEY ile — docs/BACKUP.md)
  *.bozuk    doğrulamayı geçemedi; KURTARMA NOKTASI DEĞİLDİR

Yedeklenebilen motorlar: $(backupable_engines | tr '\n' ' ')
Kafka yedeklenmez (log'dur, veritabanı değil — replication.factor kullanın).

EOF
        exit 1 ;;
esac
