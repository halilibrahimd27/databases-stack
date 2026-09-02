#!/bin/bash
# =============================================================================
# databases-stack — E2E: YEDEK ŞİFRELEME
# =============================================================================
# Bu betik CANLI bir kuruluma karşı çalışır ve tek bir soruyu cevaplar:
#
#     YEDEK DOSYASI GERÇEKTEN ŞİFRELENİYOR MU — VE ŞİFRELİYKEN GERİ
#     YÜKLENEBİLİYOR MU?
#
# "Dosyanın adı .enc" bu sorunun cevabı DEĞİLDİR; "betikte openssl
# çağrısı var" da değildir. Şifrelemenin gerçekten olduğunun tek dürüst
# kanıtı, yazdığımız değerin dosyanın HAM BAYTLARINDA BULUNAMAMASIDIR.
#
# ⚠ AMA TEK BAŞINA "grep bulamadı" HİÇBİR ŞEY KANITLAMAZ.
# Bu paketin en önemli tasarım kararı bu. Yedekler zaten gzip'lidir: ŞİFRESİZ
# bir .gz dosyasında da `grep` düz metni BULAMAZ, çünkü sıkıştırma metni yok
# eder. Yani "şifreli dosyada grep bulamadı" testi, şifreleme hiç yapılmasa da
# GEÇERDİ — klasik sessiz-yeşil. Bu yüzden ölçüm üç ayaklı:
#
#   (a) KONTROL GRUBU — aynı akış ŞİFRESİZ alınır; `gzip -dc | grep` değeri
#       BULUR. Bu, değerin gerçekten dump'ın içinde olduğunu kanıtlar; yoksa
#       (b) ve (c) boş kümede arama yapıyor olurdu.
#   (b) ŞİFRELİ dosyanın HAM baytlarında değer YOK.
#   (c) ŞİFRELİ dosya `gzip -dc` ile AÇILAMIYOR — yani yalnızca adı değişmiş
#       bir gzip değil. (b)'yi tek başına bırakırsak, dosyayı yeniden
#       adlandırmak bile testi geçirirdi.
#
# Ayrıca ölçülenler:
#   · DOĞRU anahtarla geri yükleme veriyi GETİRİYOR
#   · YANLIŞ anahtarla geri yükleme BAŞARISIZ oluyor — ve veriye DOKUNMUYOR
#   · Anahtar yokken hata ANLAŞILIR ("BACKUP_ENCRYPT_KEY tanımlı değil"),
#     gzip hatası değil
#   · Şifreleme KAPALIYKEN eski akış aynen çalışıyor (regresyon kemeri)
#   · Uzak gönderim kapısı: şifreleme açıkken şifresiz dosya GÖNDERİLMİYOR
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/encrypt.sh                 uygun ilk motoru seçer
#     ./scripts/e2e/encrypt.sh postgresql      motoru elle seç
#
# Ayarlar (ortam değişkeni):
#     E2E_GERI_YUKLEME=0    yıkıcı adımları atla (yalnız üretim + doğrulama)
#     E2E_SURE=…            komut zaman aşımı (sn)
#
# ⚠ YIKICI ADIM: geri yükleme, seçilen motorun verisini TESTİN BAŞINDA aldığı
#   yedeğe döndürür. Test sürerken başkası veri yazarsa o yazma kaybolur.
#   Bakım penceresinde çalıştırın ya da E2E_GERI_YUKLEME=0 verin.
#
# set -e YOK: her kontrol tek tek raporlanmalı. İlk hatada ölen bir test, asıl
# bilgiyi (hangi güvencenin tutmadığını) hiç göstermez.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

[ -r scripts/e2e/lib.sh ] \
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi olmadan bu paket ölçüm yapamaz."
E2E_SUITE="encrypt"
source scripts/e2e/lib.sh

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"

# --------------------------------------------------------------- zaman aşımı
# Hiçbir bekleme sonsuz değil: askıda kalmış bir koşum hem "sürüyor" görünür
# hem de yedekleme kilidini tutup gece yedeğini öldürür.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
SURE="${E2E_SURE:-900}"
zaman_asimi() {   # zaman_asimi <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
# Ölçüm ARACI asıldıysa sonuç "ürün reddetti" değil "ÖLÇEMEDİK"tir: timeout(1)
# zaman aşımında 124, öldürmek zorunda kalınca 137 döner. Bu ayrım olmadan
# asılı kalan her negatif kontrol "doğru şekilde reddetti" diye yeşil yazılır.
asildi_mi() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }
docker_yasiyor() { docker ps -q >/dev/null 2>&1; }

# ------------------------------------------------------------ geçici alan ---
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-sifre-XXXXXX")" || die "Geçici dizin açılamadı."
SON_CIKTI="$E2E_TMP/son.out"; : > "$SON_CIKTI"
E2E_LOG="$LOG_DIR/e2e-encrypt_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$LOG_DIR"; : > "$E2E_LOG"

# YEDEK DİZİNİ ÜRETİMİNKİNDEN AYRI ama AYNI DOSYA SİSTEMİNDE: backup.sh 5 GB'ın
# altında yedek almayı reddediyor ve o kontrol BACKUP_DIR'in bulunduğu birime
# bakıyor. /tmp'ye kaçsaydık kontrol bambaşka bir birimi ölçer, test ya sahte
# bir sebeple atlanır ya da üretimde geçmeyecek bir yoldan geçerdi. Nokta ile
# başlıyor: `for d in "$BACKUP_DIR"/*/` döngüleri (clean_old) gizli dizini
# görmez, yani üretim turu bu dizini motor sanmaz.
TEST_DIR="$BACKUP_DIR/.e2e-sifreleme"

# Anahtarlar HER KOŞUMDA YENİ ve ürünün kendi üretecinden (common.sh). Sabit
# bir anahtar yazsaydık, testin "doğru anahtar" dediği şey kaynak kodda duran
# bir dizge olurdu; sızıntı bir yana, iki koşum birbirinin dosyasını açardı ve
# "yanlış anahtar" testi yanlış anahtarla değil ESKİ anahtarla ölçerdi.
K_DOGRU="$(rand_secret 32)"
K_YANLIS="$(rand_secret 32)"

# Kanıt değeri her koşumda farklı: geri yüklemeden sonra okunan şeyin gerçekten
# BU koşumun yazdığı kayıt olduğunu ancak böyle söyleyebiliriz. Sabit bir değer
# kullansaydık, hiç geri yüklenmemiş eski veri de testi geçirirdi.
KANIT="e2esifre-$(date +%Y%m%d%H%M%S)-$$"
E2E_DB="e2e_sifreleme"
E2E_TABLO="kanit"
E2E_ANAHTAR="kanit"

DOKUNULAN=""      # veri yazdığımız motor (sonunda temizlenecek)

# ------------------------------------------------------------------ koşum ---
# Çalıştırılan her ürün komutunun tam çıktısı log'a gider; ekranda yalnız
# kontrol satırları kalır. Son komutun çıktısı SON_CIKTI'da da durur — hata
# ayrıntısını oradan alıp DÜŞTÜ satırına yazıyoruz, kullanıcı log açmasın.
# stdin /dev/null: geri yükleme onayı (`read`) terminalsiz ortamda bizi
# sonsuza kadar bekletmesin.
calistir() {   # calistir <saniye> <açıklama> <komut…>
    local sn="$1" ne="$2"; shift 2
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$ne"
      printf 'komut: %s\n' "$*"; } >> "$E2E_LOG"
    local rc=0
    zaman_asimi "$sn" "$@" > "$SON_CIKTI" 2>&1 < /dev/null || rc=$?
    cat "$SON_CIKTI" >> "$E2E_LOG"
    [ "$rc" -eq 124 ] && printf '(ZAMAN AŞIMI: %s sn)\n' "$sn" >> "$E2E_LOG"
    printf '(çıkış kodu: %s)\n' "$rc" >> "$E2E_LOG"
    return "$rc"
}
son_ozet() {
    local s
    s="$(tr -d '\r' < "$SON_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 2 | tr '\n' ' ')"
    printf '%s' "${s:-çıktı yok}"
}
son_icerir() { grep -qaF "$1" "$SON_CIKTI" 2>/dev/null; }

# Kilit çakışması ÜRÜN HATASI DEĞİLDİR: gece yedeği ya da elle başlatılmış bir
# iş sürüyor olabilir. Bunu başarısızlık saymak, testi saate bağımlı kılar.
kilit_carpismasi() { son_icerir "kilidi tutuyor"; }

# backup.sh'ı DENETİMLİ bir ortamla çağırır. Üç değişken burada TEK YERDEN
# veriliyor; .env'de ne yazarsa yazsın testin ölçtüğü durum belli olsun diye
# (load_env ortamı .env'in ÜSTÜNDE tutar — boş değer de bir değerdir).
# LOG_DIR geçici alana yönlendiriliyor: bu paket bilerek başarısız çağrılar
# yapıyor ve o hata satırları logs/backup_<tarih>.log'a düşseydi, ertesi sabah
# gece yedeğini inceleyen operatör testin sahte alarmlarını gerçek sanardı.
BK_KEY=""; BK_KEYFILE=""; BK_ENCRYPT=""
bk() {   # bk <saniye> <açıklama> <backup.sh argümanları…>
    local sn="$1" ne="$2"; shift 2
    calistir "$sn" "$ne" env \
        BACKUP_DIR="$TEST_DIR" LOG_DIR="$E2E_TMP" ASSUME_YES=yes \
        BACKUP_ENCRYPT_KEY="$BK_KEY" BACKUP_ENCRYPT_KEY_FILE="$BK_KEYFILE" \
        BACKUP_ENCRYPT="$BK_ENCRYPT" \
        ./scripts/backup.sh "$@"
}
sr() {   # sr <saniye> <açıklama> <sync-remote.sh argümanları…>
    local sn="$1" ne="$2"; shift 2
    calistir "$sn" "$ne" env \
        BACKUP_DIR="$TEST_DIR" LOG_DIR="$E2E_TMP" \
        BACKUP_ENCRYPT_KEY="$BK_KEY" BACKUP_ENCRYPT_KEY_FILE="$BK_KEYFILE" \
        BACKUP_ENCRYPT="$BK_ENCRYPT" \
        ./scripts/sync-remote.sh "$@"
}

# Bir dizindeki en yeni yedek dosyası (şifreli ya da değil).
#   0 bulundu · 1 yok · 2 ÖLÇEMEDİK (tarama düştü)
# "dosya üretilmedi" ile "tarayamadım" ayrı şeyler; ikisini aynı sonuca
# düşürmek, ölçüm aracının bozulmasını ürün hatası gibi gösterir.
en_yeni_yedek() {   # en_yeni_yedek <dizin>
    local d="$1" ham="$E2E_TMP/bul.$$" yol
    [ -d "$d" ] || return 1
    if ! find "$d" -type f '(' -name '*.gz' -o -name '*.gz.enc' ')' ! -name '*.bozuk' \
         -print > "$ham" 2>>"$E2E_LOG"; then rm -f "$ham"; return 2; fi
    [ -s "$ham" ] || { rm -f "$ham"; return 1; }
    yol="$(tr '\n' '\0' < "$ham" | xargs -0 ls -1t -- 2>>"$E2E_LOG" | head -1)"
    rm -f "$ham"
    [ -n "$yol" ] || return 2
    printf '%s' "$yol"
}

# =============================================================================
# MOTOR İSTEMCİLERİ  (yalnız mariadb + postgresql)
# =============================================================================
# NEDEN SADECE BU İKİSİ: bu paketin ana ölçütü "yazdığımız değer dump'ın
# İÇİNDE var mı" kontrol grubudur (yukarıdaki (a) maddesi). Bu ancak dökümü
# DÜZ METİN olan motorlarda kurulabilir. Cassandra SSTable'ı, ClickHouse zip'i
# ya da MSSQL .bak'ı kendi içinde de sıkıştırılmış/ikili olduğu için orada
# "grep buldu" demek mümkün değil; kontrol grubu kurulamayan bir yerde
# "grep bulamadı" ölçmek tiyatro olurdu. Şifreleme zaten motora göre
# değişmiyor: paketleme tek fonksiyonda (backup.sh:paketle) ve dosya adı tek
# fonksiyonda (out_path) üretiliyor. Bu ikisini kanıtlamak hepsini kanıtlar.
# Parolalar komut satırına DEĞİL ortama konuyor (host'ta `ps` çıktısında
# görünmesinler) — backup.sh'taki desenin aynısı.
my_sql() {   # my_sql <container> <parola> <sql>
    ( export MYSQL_PWD="$2"
      zaman_asimi 60 docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$3" ) 2>>"$E2E_LOG"
}
pg_sql() {   # pg_sql <container> <parola> <veritabanı> <sql>
    ( export PGPASSWORD="$2"
      zaman_asimi 60 docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$3" -tAq -c "$4" ) \
      2>>"$E2E_LOG"
}
motor_pw() {
    case "$1" in
        mariadb)    printf '%s' "${MARIADB_PASSWORD:-${DB_PASSWORD:-}}" ;;
        postgresql) printf '%s' "${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}" ;;
    esac
}

veri_yaz() {   # veri_yaz <eid> <container>
    local pw; pw="$(motor_pw "$1")"
    case "$1" in
        mariadb)
            my_sql "$2" "$pw" "CREATE DATABASE IF NOT EXISTS \`$E2E_DB\`;
                CREATE TABLE IF NOT EXISTS \`$E2E_DB\`.\`$E2E_TABLO\`
                    (k VARCHAR(64) PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
                REPLACE INTO \`$E2E_DB\`.\`$E2E_TABLO\` VALUES ('$E2E_ANAHTAR','$KANIT');" >/dev/null ;;
        postgresql)
            local var
            var="$(pg_sql "$2" "$pw" postgres "SELECT 1 FROM pg_database WHERE datname='$E2E_DB'")"
            [ -n "$var" ] || pg_sql "$2" "$pw" postgres "CREATE DATABASE \"$E2E_DB\"" >/dev/null || return 1
            pg_sql "$2" "$pw" "$E2E_DB" \
                "CREATE TABLE IF NOT EXISTS \"$E2E_TABLO\" (k text PRIMARY KEY, v text);
                 INSERT INTO \"$E2E_TABLO\" VALUES ('$E2E_ANAHTAR','$KANIT')
                 ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" >/dev/null ;;
        *) return 3 ;;
    esac
}
veri_oku() {   # veri_oku <eid> <container> → kanıt (yoksa boş)
    local pw; pw="$(motor_pw "$1")"
    case "$1" in
        mariadb)    my_sql "$2" "$pw" "SELECT v FROM \`$E2E_DB\`.\`$E2E_TABLO\` WHERE k='$E2E_ANAHTAR';" ;;
        postgresql) pg_sql "$2" "$pw" "$E2E_DB" "SELECT v FROM \"$E2E_TABLO\" WHERE k='$E2E_ANAHTAR'" ;;
        *) return 3 ;;
    esac
}
veri_yikim() { # veri_yikim <eid> <container> — geri yüklemeye iş çıkar
    local pw; pw="$(motor_pw "$1")"
    case "$1" in
        mariadb)    my_sql "$2" "$pw" "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null ;;
        postgresql) pg_sql "$2" "$pw" postgres "DROP DATABASE IF EXISTS \"$E2E_DB\"" >/dev/null ;;
        *) return 3 ;;
    esac
}

# Okuma DENEMESİ ile okuma SONUCU iki ayrı bilgidir: istemci hiç çalışmadıysa
# (docker exec düştü, container yeniden başlıyor) elimizde "veri yok" değil
# ÖLÇÜM YOK vardır. Boş çıktıyı "kayıt silinmiş" saymak, geri yükleme
# kontrolünü kendi kendini kandıran bir kontrole çevirir.
OKUNAN=""; OKUMA_RC=0
oku() { OKUNAN="$(veri_oku "$1" "$2")"; OKUMA_RC=$?; return 0; }
kanit_var() { case "$OKUNAN" in *"$KANIT"*) return 0 ;; esac; return 1; }
veri_bekle() {   # veri_bekle <eid> <container> [saniye]
    local bitis=$(( $(date +%s) + ${3:-180} ))
    while :; do
        oku "$1" "$2"
        [ "$OKUMA_RC" -eq 0 ] && kanit_var && return 0
        [ "$(date +%s)" -ge "$bitis" ] && return 1
        sleep 3
    done
}

# =============================================================================
# TEMİZLİK
# =============================================================================
TEMIZLENDI=0
temizle() {
    [ "$TEMIZLENDI" = "1" ] && return 0
    TEMIZLENDI=1
    if [ -n "$DOKUNULAN" ]; then
        heading "Temizlik"
        local C; C="$(primary_of "$DOKUNULAN")"
        if container_running "$C"; then
            veri_yikim "$DOKUNULAN" "$C"
            log "  $DOKUNULAN: test verisi kaldırıldı ($E2E_DB)"
        else
            warn "  $DOKUNULAN: container kapalı, test verisi KALDIRILAMADI ($E2E_DB)"
        fi
    fi
    # Testin ürettiği yedekler ŞİFRELİ ve anahtarları yalnız bu koşumun
    # belleğindeydi; bırakılsalar hiç kimsenin açamayacağı dosyalar olarak
    # diskte yer kaplarlardı.
    [ -d "$TEST_DIR" ] && { rm -rf "$TEST_DIR" || warn "  test yedek dizini silinemedi: $TEST_DIR"; }
    rm -rf "$E2E_TMP"
    [ -s "$E2E_LOG" ] || rm -f "$E2E_LOG"
}
# INT/TERM'i lib.sh yakalıyor (kesinti BAŞARI DEĞİLDİR: 130 ile çıkar). Bizim
# temizliğimiz EXIT üzerinde — 130'la çıkarken de, die'da da çalışır.
trap temizle EXIT

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
heading "Ön koşullar"
require_docker
require_cmd python3 flock gzip find awk grep
[ -r scripts/backup.sh ]      || die "scripts/backup.sh okunamıyor — yığın kökünde miyiz?"
[ -r scripts/sync-remote.sh ] || die "scripts/sync-remote.sh okunamıyor."
[ -f "$ENV_FILE" ] || warn ".env yok ($ENV_FILE) — parolalar yalnız ortamdan okunacak."
if [ "${#ZAMAN[@]}" -eq 0 ]; then
    warn "'timeout' komutu yok: komutlar zaman aşımı OLMADAN çalışacak (coreutils kurun)."
fi
mkdir -p "$TEST_DIR" || die "Test yedek dizini oluşturulamadı: $TEST_DIR"
ok "Bu koşumun kanıt değeri: $KANIT"
log "Test yedek dizini: $TEST_DIR"
log "Ayrıntılı komut çıktısı: $E2E_LOG"

# ---------------------------------------------------------- motor seçimi ----
ADAYLAR="mariadb postgresql"
MOTOR=""
if [ "$#" -gt 0 ]; then
    printf '%s\n' $ADAYLAR | grep -qx "$1" \
        || die "'$1' bu pakette desteklenmiyor. Seçenekler: $ADAYLAR"
    MOTOR="$1"
else
    for m in $ADAYLAR; do
        container_running "$(primary_of "$m")" && { MOTOR="$m"; break; }
    done
fi

# =============================================================================
# A) ARAÇ VE ORTAM
# =============================================================================
t_head "A · Şifreleme aracı"

if command -v openssl >/dev/null 2>&1; then
    t_ok "openssl host'ta var ($(openssl version 2>/dev/null | awk '{print $1, $2}'))"
else
    t_fail "openssl host'ta YOK" \
           "Şifreleme bu araca dayanıyor; install.sh zaten require_cmd openssl diyor."
fi

# Zamanlanmış yedeği CONTROLLER container'ı çalıştırıyor
# (controller/Dockerfile). Yani şifreleme açıkken openssl'in ORADA da
# bulunması gerekir; yoksa panelden
# ve gecelik zamanlayıcıdan alınan yedekler "şifreleme kullanılamıyor" diyip
# HİÇ ALINMAZ (backup.sh bilerek şifresiz yedek üretmiyor). Host'ta openssl
# olması bunu garanti etmez — controller alpine tabanlı ayrı bir imaj.
if ! docker_yasiyor; then
    t_unknown "controller container'ında openssl" "docker cevap vermiyor"
elif container_running controller; then
    if zaman_asimi 60 docker exec controller sh -c 'command -v openssl' >/dev/null 2>&1; then
        t_ok "controller container'ında openssl var (panelden/zamanlayıcıdan şifreli yedek alınabilir)"
    else
        t_fail "controller container'ında openssl YOK" \
               "Panelden ve gecelik zamanlayıcıdan şifreli yedek ALINAMAZ. controller/Dockerfile'a 'openssl' paketi eklenmeli."
    fi
else
    t_skip "controller container'ında openssl" "controller çalışmıyor"
fi

# =============================================================================
# B) SÖZLEŞME — backup.sh sifreleme-durumu
# =============================================================================
# sync-remote.sh gönderim kararını BU ÇIKIŞ KODUNA bağlıyor. Kod sessizce
# değişirse, "şifresiz dosya göndermiyoruz" güvencesi hiçbir hata vermeden
# ortadan kalkar — o yüzden üç durumun üçü de ayrı ayrı ölçülüyor.
t_head "B · Durum sözleşmesi (çıkış kodları)"

durum_kontrol() {   # durum_kontrol <ad> <beklenen_rc> <beklenen_metin>
    local ad="$1" bek="$2" metin="$3" rc=0
    bk 60 "$ad" sifreleme-durumu || rc=$?
    if asildi_mi "$rc"; then t_unknown "$ad" "komut askıda kaldı"; return; fi
    if [ "$rc" -ne "$bek" ]; then
        t_fail "$ad" "çıkış kodu $rc, beklenen $bek — $(son_ozet)"; return
    fi
    if [ -n "$metin" ] && ! son_icerir "$metin"; then
        t_fail "$ad" "çıktıda '$metin' yok — $(son_ozet)"; return
    fi
    t_ok "$ad"
}

BK_KEY="$K_DOGRU"; BK_KEYFILE=""; BK_ENCRYPT=""
durum_kontrol "anahtar verilince AÇIK (rc=0) ve uzantı .gz.enc" 0 ".gz.enc"

BK_KEY=""
durum_kontrol "anahtar yokken KAPALI (rc=2)" 2 "ŞİFRESİZ"

BK_KEY="$K_DOGRU"; BK_ENCRYPT="false"
durum_kontrol "BACKUP_ENCRYPT=false ile KAPALI ama anahtar okunabilir (rc=2)" 2 "eski şifreli yedekler açılabilir"

BK_KEY=""; BK_ENCRYPT=""; BK_KEYFILE="$E2E_TMP/olmayan-anahtar-dosyasi"
durum_kontrol "okunamayan anahtar dosyası BOZUK (rc=1) — 'kapalı' DEĞİL" 1 "okunamıyor"
BK_KEYFILE=""

# =============================================================================
# C) REGRESYON KEMERİ — ŞİFRELEME KAPALIYKEN ESKİ AKIŞ
# =============================================================================
# Bu bölüm yeni özelliği değil, ESKİ davranışın bozulmadığını ölçüyor. Aynı
# zamanda (a) KONTROL GRUBUNU kuruyor: kanıt değerinin gerçekten dump'ın
# içinde olduğunu burada görüyoruz.
t_head "C · Şifreleme KAPALIYKEN eski akış (regresyon kemeri)"

DUZ_DOSYA=""
if [ -z "$MOTOR" ]; then
    t_skip "şifresiz yedek üretimi" "mariadb/postgresql çalışmıyor"
elif ! docker_yasiyor; then
    t_unknown "şifresiz yedek üretimi" "docker cevap vermiyor"
else
    C_ANA="$(primary_of "$MOTOR")"
    t_info "seçilen motor: $MOTOR (container: $C_ANA)"
    if ! veri_yaz "$MOTOR" "$C_ANA"; then
        t_unknown "kanıt kaydı yazılamadı" "$MOTOR istemcisi cevap vermedi — $E2E_LOG"
    else
        DOKUNULAN="$MOTOR"
        oku "$MOTOR" "$C_ANA"
        if [ "$OKUMA_RC" -ne 0 ] || ! kanit_var; then
            t_unknown "kanıt kaydı doğrulanamadı" "yazıldı ama geri okunamadı"
        else
            t_ok "kanıt kaydı yazıldı ve geri okundu ($MOTOR)"

            BK_KEY=""; BK_ENCRYPT=""
            rc=0; bk "$SURE" "şifresiz yedek" "$MOTOR" || rc=$?
            if kilit_carpismasi; then
                t_skip "şifresiz yedek alındı" "başka bir yedekleme/geri yükleme sürüyor"
            elif asildi_mi "$rc"; then
                t_unknown "şifresiz yedek alındı" "komut askıda kaldı ($SURE sn)"
            elif [ "$rc" -ne 0 ]; then
                t_fail "şifresiz yedek alındı" "backup.sh rc=$rc — $(son_ozet)"
            else
                DUZ_DOSYA="$(en_yeni_yedek "$TEST_DIR/$MOTOR")"; brc=$?
                if [ "$brc" -eq 2 ]; then
                    t_unknown "şifresiz yedek alındı" "dizin taranamadı"
                elif [ "$brc" -ne 0 ] || [ -z "$DUZ_DOSYA" ]; then
                    t_fail "şifresiz yedek alındı" "dosya üretilmedi"
                else
                    t_ok "şifresiz yedek alındı: $(basename "$DUZ_DOSYA")"
                    case "$DUZ_DOSYA" in
                        *.enc) t_fail "şifreleme kapalıyken ad .enc ile BİTMEMELİ" "$(basename "$DUZ_DOSYA")" ;;
                        *.gz)  t_ok   "şifreleme kapalıyken uzantı .gz (sözleşme)" ;;
                        *)     t_fail "şifreleme kapalıyken uzantı .gz olmalı" "$(basename "$DUZ_DOSYA")" ;;
                    esac
                fi
            fi
        fi
    fi
fi

# (a) KONTROL GRUBU. Bu kontrol GEÇMEZSE aşağıdaki bütün "grep bulamadı"
# ölçümleri anlamsızdır: boş kümede arama yapıyor oluruz.
KONTROL_GRUBU=0
if [ -z "$DUZ_DOSYA" ]; then
    t_skip "KONTROL GRUBU: kanıt şifresiz dump'ın İÇİNDE" "şifresiz yedek üretilemedi"
else
    gzip -dc "$DUZ_DOSYA" 2>>"$E2E_LOG" | grep -qaF "$KANIT"
    ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ]; then
        t_unknown "KONTROL GRUBU: kanıt şifresiz dump'ın İÇİNDE" "dosya sonuna kadar açılamadı (gzip rc=${ps[0]})"
    elif [ "${ps[1]}" -eq 0 ]; then
        KONTROL_GRUBU=1
        t_ok "KONTROL GRUBU: kanıt şifresiz dump'ın İÇİNDE (yani aşağıdaki 'bulunamadı' ölçümleri anlamlı)"
    else
        t_fail "KONTROL GRUBU: kanıt şifresiz dump'ın İÇİNDE" \
               "değer dump'ta yok — şifreli dosyada aranması da hiçbir şey kanıtlamaz"
    fi
fi

if [ -n "$DUZ_DOSYA" ]; then
    BK_KEY=""; rc=0
    bk 300 "şifresiz verify" verify "$DUZ_DOSYA" || rc=$?
    if asildi_mi "$rc"; then t_unknown "şifresiz yedek doğrulanıyor" "komut askıda kaldı"
    elif [ "$rc" -eq 0 ]; then t_ok "şifresiz yedek doğrulanıyor"
    else t_fail "şifresiz yedek doğrulanıyor" "verify rc=$rc — $(son_ozet)"; fi
fi

# =============================================================================
# D) ŞİFRELİ ÜRETİM — ASIL KANIT
# =============================================================================
t_head "D · Şifreli yedek üretimi"

ENC_DOSYA=""
if [ -z "$MOTOR" ] || [ -z "$DOKUNULAN" ]; then
    t_skip "şifreli yedek üretimi" "motor yok ya da kanıt kaydı yazılamadı"
else
    BK_KEY="$K_DOGRU"; BK_ENCRYPT=""
    rc=0; bk "$SURE" "şifreli yedek" "$MOTOR" || rc=$?
    if kilit_carpismasi; then
        t_skip "şifreli yedek alındı" "başka bir yedekleme/geri yükleme sürüyor"
    elif asildi_mi "$rc"; then
        t_unknown "şifreli yedek alındı" "komut askıda kaldı ($SURE sn)"
    elif [ "$rc" -ne 0 ]; then
        t_fail "şifreli yedek alındı" "backup.sh rc=$rc — $(son_ozet)"
    else
        # En yeni dosya bu olmalı; adı .enc ile bitmiyorsa zaten aşağıdaki
        # kontrol düşecek, yanlış dosyayla ölçmeyelim diye adı da doğruluyoruz.
        ENC_DOSYA="$(en_yeni_yedek "$TEST_DIR/$MOTOR")"; brc=$?
        if [ "$brc" -eq 2 ]; then
            t_unknown "şifreli yedek alındı" "dizin taranamadı"
        elif [ "$brc" -ne 0 ] || [ -z "$ENC_DOSYA" ]; then
            t_fail "şifreli yedek alındı" "dosya üretilmedi"
        else
            t_ok "şifreli yedek alındı: $(basename "$ENC_DOSYA")"
            case "$ENC_DOSYA" in
                *.gz.enc) t_ok "UZANTI SÖZLEŞMESİ: şifreli yedek '.gz.enc' ile bitiyor" ;;
                *)        t_fail "UZANTI SÖZLEŞMESİ: şifreli yedek '.gz.enc' ile bitmeli" \
                                 "üretilen: $(basename "$ENC_DOSYA")"
                          ENC_DOSYA="" ;;
            esac
        fi
    fi
fi

if [ -z "$ENC_DOSYA" ]; then
    t_skip "şifreli dosyanın başlığı" "şifreli yedek üretilemedi"
else
    # Başlık, dosyanın ŞİFRELİ olduğunu ADINDAN BAĞIMSIZ anlatan tek şey;
    # yeniden adlandırılmış bir dosyada bile ürün doğru mesajı bunun sayesinde
    # veriyor. Sözleşmenin makine tarafı budur.
    if head -c 12 "$ENC_DOSYA" 2>/dev/null | grep -qaxF "DBSTACK-ENC1"; then
        t_ok "şifreli dosya 'DBSTACK-ENC1' imzasıyla başlıyor (ada bakılmadan tanınır)"
    else
        t_fail "şifreli dosya 'DBSTACK-ENC1' imzasıyla başlamalı" \
               "ilk baytlar: $(head -c 12 "$ENC_DOSYA" 2>/dev/null | od -An -c | tr -s ' ')"
    fi
fi

# ─── (b) HAM BAYT ARAMASI — ŞİFRELEMENİN TEK DÜRÜST KANITI ───────────────────
ham_bayt_yok() {   # ham_bayt_yok <ad> <aranan>
    local ad="$1" ne="$2" rc
    if [ -z "$ENC_DOSYA" ]; then t_skip "$ad" "şifreli yedek üretilemedi"; return; fi
    if [ "$KONTROL_GRUBU" -ne 1 ] && [ "$ne" = "$KANIT" ]; then
        # Kontrol grubu kurulamadıysa bu ölçüm "bulamadım" der ama bu, aranan
        # şeyin hiç var olmamasından da kaynaklanabilir. ÖLÇEMEDİK demek doğru
        # olan; "geçti" demek bu paketin engellemeye çalıştığı şeyin ta
        # kendisidir.
        t_unknown "$ad" "kontrol grubu kurulamadı — 'bulunamadı' bir şey kanıtlamaz"
        return
    fi
    grep -qaF "$ne" "$ENC_DOSYA"; rc=$?
    case "$rc" in
        1) t_ok "$ad" ;;
        0) t_fail "$ad" "değer ŞİFRELİ dosyanın ham baytlarında GÖRÜNÜYOR — şifreleme çalışmıyor" ;;
        *) t_unknown "$ad" "grep düştü (rc=$rc)" ;;
    esac
}
t_head "D · Ham baytlarda sır aranıyor"
ham_bayt_yok "yazdığımız DEĞER şifreli dosyanın ham baytlarında YOK"  "$KANIT"
ham_bayt_yok "TABLO adı ('$E2E_TABLO') şifreli dosyanın ham baytlarında YOK" "$E2E_TABLO"
ham_bayt_yok "VERİTABANI adı ('$E2E_DB') şifreli dosyanın ham baytlarında YOK" "$E2E_DB"

# ─── (c) "yalnızca adı değişmiş gzip" olmadığının kanıtı ─────────────────────
if [ -z "$ENC_DOSYA" ]; then
    t_skip "şifreli dosya gzip olarak AÇILAMIYOR" "şifreli yedek üretilemedi"
else
    if gzip -t "$ENC_DOSYA" >/dev/null 2>&1; then
        t_fail "şifreli dosya gzip olarak AÇILAMAMALI" \
               "dosya geçerli bir gzip — yalnızca adı .enc olmuş olabilir"
    else
        t_ok "şifreli dosya gzip olarak AÇILAMIYOR (yalnızca adı değişmiş bir .gz değil)"
    fi
fi

# =============================================================================
# E) ANAHTAR — DOĞRU, YANLIŞ, YOK
# =============================================================================
t_head "E · Anahtar kontrolleri"

if [ -z "$ENC_DOSYA" ]; then
    t_skip "doğru anahtarla doğrulama" "şifreli yedek üretilemedi"
    t_skip "anahtarsız doğrulama anlaşılır hata veriyor" "şifreli yedek üretilemedi"
    t_skip "yanlış anahtarla doğrulama reddediyor" "şifreli yedek üretilemedi"
else
    BK_KEY="$K_DOGRU"; rc=0
    bk 300 "doğru anahtarla verify" verify "$ENC_DOSYA" || rc=$?
    if asildi_mi "$rc"; then t_unknown "doğru anahtarla doğrulama" "komut askıda kaldı"
    elif [ "$rc" -eq 0 ]; then t_ok "doğru anahtarla doğrulama geçiyor"
    else t_fail "doğru anahtarla doğrulama geçiyor" "verify rc=$rc — $(son_ozet)"; fi

    # ANAHTAR YOK. Buradaki asıl ölçüt çıkış kodu değil MESAJ: kullanıcı
    # "bozuk gzip" görürse sağlam yedeğini siler. Bu paketin var olma
    # sebeplerinden biri tam olarak bu satır.
    BK_KEY=""; rc=0
    bk 300 "anahtarsız verify" verify "$ENC_DOSYA" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "anahtarsız doğrulama anlaşılır hata veriyor" "komut askıda kaldı"
    elif [ "$rc" -eq 0 ]; then
        t_fail "anahtarsız doğrulama REDDETMELİ" "verify anahtarsız 0 döndü — şifreli dosya doğrulanmış sayıldı"
    elif son_icerir "BACKUP_ENCRYPT_KEY"; then
        t_ok "anahtarsız doğrulama anlaşılır hata veriyor ('BACKUP_ENCRYPT_KEY tanımlı değil')"
    else
        t_fail "anahtarsız doğrulama anlaşılır hata veriyor" \
               "reddetti ama sebebi söylemedi — $(son_ozet)"
    fi

    # YANLIŞ ANAHTAR.
    BK_KEY="$K_YANLIS"; rc=0
    bk 300 "yanlış anahtarla verify" verify "$ENC_DOSYA" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "yanlış anahtarla doğrulama reddediyor" "komut askıda kaldı"
    elif [ "$rc" -eq 0 ]; then
        t_fail "yanlış anahtarla doğrulama REDDETMELİ" "verify yanlış anahtarla 0 döndü"
    elif son_icerir "ŞİFRESİ ÇÖZÜLEMEDİ"; then
        t_ok "yanlış anahtarla doğrulama reddediyor ve sebebi söylüyor"
    else
        t_fail "yanlış anahtarla doğrulama reddediyor" \
               "reddetti ama mesaj anahtarı işaret etmiyor — $(son_ozet)"
    fi
fi
BK_KEY="$K_DOGRU"

# =============================================================================
# F) GERİ YÜKLEME  (YIKICI)
# =============================================================================
t_head "F · Geri yükleme"

if [ "${E2E_GERI_YUKLEME:-1}" = "0" ]; then
    t_skip "yanlış anahtarla geri yükleme veriye DOKUNMUYOR" "E2E_GERI_YUKLEME=0"
    t_skip "doğru anahtarla geri yükleme veriyi GETİRİYOR"   "E2E_GERI_YUKLEME=0"
elif [ -z "$ENC_DOSYA" ] || [ -z "$DOKUNULAN" ]; then
    t_skip "yanlış anahtarla geri yükleme veriye DOKUNMUYOR" "şifreli yedek üretilemedi"
    t_skip "doğru anahtarla geri yükleme veriyi GETİRİYOR"   "şifreli yedek üretilemedi"
else
    C_ANA="$(primary_of "$MOTOR")"

    # 1) YANLIŞ ANAHTAR. Beklenen: geri yükleme HİÇ BAŞLAMASIN. backup.sh
    # dosyayı silmeden ÖNCE doğruluyor; bu sıra doğru değilse yanlış anahtarlı
    # bir deneme veriyi siler ve yerine hiçbir şey koyamaz — şifrelemenin
    # eklediği EN BÜYÜK yeni risk budur, o yüzden ayrıca ölçülüyor.
    BK_KEY="$K_YANLIS"; rc=0
    bk "$SURE" "yanlış anahtarla restore" "restore-$MOTOR" "$ENC_DOSYA" || rc=$?
    if kilit_carpismasi; then
        t_skip "yanlış anahtarla geri yükleme veriye DOKUNMUYOR" "başka bir iş kilidi tutuyor"
    elif asildi_mi "$rc"; then
        t_unknown "yanlış anahtarla geri yükleme veriye DOKUNMUYOR" "komut askıda kaldı"
    elif [ "$rc" -eq 0 ]; then
        t_fail "yanlış anahtarla geri yükleme REDDETMELİ" "restore yanlış anahtarla 0 döndü"
    else
        oku "$MOTOR" "$C_ANA"
        if [ "$OKUMA_RC" -ne 0 ]; then
            t_unknown "yanlış anahtarla geri yükleme veriye DOKUNMUYOR" "geri yüklemeden sonra okuma yapılamadı"
        elif kanit_var; then
            t_ok "yanlış anahtarla geri yükleme reddedildi ve VERİYE DOKUNULMADI"
        else
            t_fail "yanlış anahtarla geri yükleme VERİYİ SİLDİ" \
                   "reddetmesi gereken çağrı veriyi yok etti — doğrulama silmeden ÖNCE yapılmıyor"
        fi
    fi

    # 2) DOĞRU ANAHTAR. Önce veriyi yok ediyoruz ki geri yüklemenin gerçekten
    # iş yaptığı görülsün: yıkım olmadan "veri duruyor" cümlesi geri yüklemeyi
    # değil, hiçbir şey yapmamış olmayı da kanıtlardı.
    if ! veri_yikim "$MOTOR" "$C_ANA"; then
        t_unknown "doğru anahtarla geri yükleme veriyi GETİRİYOR" "yıkım adımı çalışmadı"
    else
        oku "$MOTOR" "$C_ANA"
        if [ "$OKUMA_RC" -eq 0 ] && kanit_var; then
            t_unknown "doğru anahtarla geri yükleme veriyi GETİRİYOR" \
                      "yıkımdan sonra kayıt hâlâ duruyor — testin yıkımı işe yaramadı"
        else
            BK_KEY="$K_DOGRU"; rc=0
            bk "$SURE" "doğru anahtarla restore" "restore-$MOTOR" "$ENC_DOSYA" || rc=$?
            if kilit_carpismasi; then
                t_skip "doğru anahtarla geri yükleme veriyi GETİRİYOR" "başka bir iş kilidi tutuyor"
            elif asildi_mi "$rc"; then
                t_unknown "doğru anahtarla geri yükleme veriyi GETİRİYOR" "komut askıda kaldı"
            elif [ "$rc" -ne 0 ]; then
                t_fail "doğru anahtarla geri yükleme veriyi GETİRİYOR" "restore rc=$rc — $(son_ozet)"
            elif veri_bekle "$MOTOR" "$C_ANA"; then
                t_ok "doğru anahtarla geri yükleme veriyi GETİRDİ (kanıt: $KANIT)"
            else
                t_fail "doğru anahtarla geri yükleme veriyi GETİRİYOR" \
                       "restore 0 döndü ama kanıt kaydı geri gelmedi (okuma rc=$OKUMA_RC)"
            fi
        fi
    fi
fi
BK_KEY="$K_DOGRU"

# =============================================================================
# G) GERİYE UYUMLULUK
# =============================================================================
# Şifreleme AÇIKKEN, ondan önce alınmış ŞİFRESİZ yedekler kullanılabilir
# kalmalı. Aksi hâlde şifrelemeyi açmak, o güne kadarki bütün kurtarma
# noktalarını çöpe atmak demek olurdu — ve bunu ancak felaket günü fark
# ederdik.
t_head "G · Geriye uyumluluk (şifreleme açıkken eski şifresiz yedekler)"

if [ -z "$DUZ_DOSYA" ]; then
    t_skip "şifreleme açıkken şifresiz yedek doğrulanıyor" "şifresiz yedek üretilemedi"
else
    BK_KEY="$K_DOGRU"; rc=0
    bk 300 "şifreleme açıkken şifresiz verify" verify "$DUZ_DOSYA" || rc=$?
    if asildi_mi "$rc"; then t_unknown "şifreleme açıkken şifresiz yedek doğrulanıyor" "komut askıda kaldı"
    elif [ "$rc" -eq 0 ]; then t_ok "şifreleme açıkken şifresiz yedek doğrulanıyor"
    else t_fail "şifreleme açıkken şifresiz yedek doğrulanıyor" "verify rc=$rc — $(son_ozet)"; fi
fi

# list/stats HER İKİ uzantıyı da saymalı. Saymazsa saklama temizliği de
# saymaz (aynı desen), yani RETENTION_DAYS sessizce hiç işlemez ve panel
# "hiç yedek yok" der.
if [ -z "$ENC_DOSYA" ] && [ -z "$DUZ_DOSYA" ]; then
    t_skip "list şifreli ve şifresiz dosyaların İKİSİNİ de sayıyor" "yedek üretilemedi"
else
    bek=0; [ -n "$ENC_DOSYA" ] && bek=$((bek+1)); [ -n "$DUZ_DOSYA" ] && bek=$((bek+1))
    BK_KEY="$K_DOGRU"; rc=0
    bk 120 "list" list || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "list şifreli ve şifresiz dosyaların İKİSİNİ de sayıyor" "komut askıda kaldı"
    elif son_icerir "($bek yedek)"; then
        t_ok "list şifreli ve şifresiz dosyaların İKİSİNİ de sayıyor ($bek yedek)"
    else
        t_fail "list şifreli ve şifresiz dosyaların İKİSİNİ de sayıyor" \
               "'($bek yedek)' satırı yok — desen bir uzantıyı atlıyor olabilir: $(son_ozet)"
    fi
fi

# =============================================================================
# H) UZAK GÖNDERİM KAPISI
# =============================================================================
# "Şifreleme açıkken şifresiz dosya göndermiyoruz" bir GÜVENCE. Gözlenemeyen
# güvence sınanamaz, sınanamayan güvence zamanla sessizce bozulur. `plan` alt
# komutu kararı rclone'a hiç dokunmadan gösteriyor; burada onu ölçüyoruz.
t_head "H · Uzak gönderim kapısı (sync-remote.sh plan)"

if [ -z "$ENC_DOSYA" ] || [ -z "$DUZ_DOSYA" ]; then
    t_skip "şifreleme açıkken şifresiz dosya GÖNDERİLMİYOR" "iki uzantıdan biri üretilemedi"
    t_skip "şifreleme kapalıyken UYARI basılıyor" "iki uzantıdan biri üretilemedi"
else
    BK_KEY="$K_DOGRU"; BK_ENCRYPT=""; rc=0
    sr 120 "plan (şifreleme açık)" plan || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "şifreleme açıkken şifresiz dosya GÖNDERİLMİYOR" "komut askıda kaldı"
    elif [ "$rc" -ne 0 ]; then
        t_fail "şifreleme açıkken şifresiz dosya GÖNDERİLMİYOR" "plan rc=$rc — $(son_ozet)"
    elif son_icerir "$(basename "$DUZ_DOSYA")" && son_icerir "ŞİFRESİZ — gönderilmez"; then
        t_ok "şifreleme açıkken şifresiz dosya GÖNDERİLMİYOR (planda 'atlanır' diye adıyla yazıyor)"
    else
        t_fail "şifreleme açıkken şifresiz dosya GÖNDERİLMİYOR" \
               "plan şifresiz dosyayı atlanan olarak listelemedi — $(son_ozet)"
    fi

    BK_KEY=""; rc=0
    sr 120 "plan (şifreleme kapalı)" plan || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "şifreleme kapalıyken UYARI basılıyor" "komut askıda kaldı"
    elif son_icerir "ŞİFRELENMEDEN"; then
        t_ok "şifreleme kapalıyken gönderim UYARIYLA yapılıyor (sessiz değil)"
    else
        t_fail "şifreleme kapalıyken UYARI basılmalı" \
               "uyarı satırı yok — şifresiz gönderim sessizce yapılıyor: $(son_ozet)"
    fi

    # BOZUK durumda hiçbir şey gönderilmemeli: o hâlde üretilen dosyaların
    # şifreli olduğunu SÖYLEYEMEYİZ, söyleyemediğimiz bir şeyi de dışarı
    # çıkaramayız.
    BK_KEY=""; BK_KEYFILE="$E2E_TMP/olmayan-anahtar-dosyasi"; rc=0
    sr 120 "plan (şifreleme bozuk)" plan || rc=$?
    BK_KEYFILE=""
    if asildi_mi "$rc"; then
        t_unknown "şifreleme BOZUKKEN gönderim reddediliyor" "komut askıda kaldı"
    elif [ "$rc" -eq 0 ]; then
        t_fail "şifreleme BOZUKKEN gönderim REDDEDİLMELİ" "plan 0 döndü — gönderim yapılabilir görünüyor"
    else
        t_ok "şifreleme BOZUKKEN gönderim reddediliyor (rc=$rc)"
    fi
fi

# =============================================================================
# I) UZANTI SÖZLEŞMESİNİN DİĞER TÜKETİCİLERİ
# =============================================================================
# `.gz.enc` adını yalnız backup.sh üretmiyor; başka bileşenler de OKUYOR.
# Biri kapsamı güncellemezse hata vermez, SESSİZCE dosyayı görmez — prova
# "yedek yok" der, panel listesi boş görünür. Bu yüzden burada STATİK olarak
# okunuyor; ölçüm yöntemini de adında yazıyoruz ki kimse bunu bir çalışma
# zamanı kanıtı sanmasın.
t_head "I · Uzantı sözleşmesini okuyan diğer bileşenler (statik okuma)"

sozlesme_tuketici() {   # sozlesme_tuketici <dosya> <açıklama>
    local dosya="$1" ad="$2"
    if [ ! -r "$dosya" ]; then
        t_unknown "$ad" "$dosya okunamadı"; return
    fi
    if grep -qa 'gz\.enc\|gz\.\$ENC_EXT\|gz\.\${ENC_EXT}' "$dosya"; then
        t_ok "$ad"
    else
        t_fail "$ad" "dosyada '.gz.enc' geçmiyor: şifreli yedekleri GÖREMEZ (sessizce atlar)"
    fi
}
sozlesme_tuketici scripts/restore-drill.sh \
    "restore-drill.sh aday araması '.gz.enc' kapsıyor (statik okuma)"
sozlesme_tuketici controller/app.py \
    "controller/app.py yedek listesi/geri yükleme '.gz.enc' kapsıyor (statik okuma)"

# =============================================================================
# ÖZET
# =============================================================================
temizle

t_info "kanıt değeri: $KANIT · seçilen motor: ${MOTOR:-yok}"
if [ "$E2E_FAIL" -eq 0 ] && [ "$E2E_UNKNOWN" -eq 0 ]; then
    rm -f "$E2E_LOG"
else
    t_info "komut çıktılarının tamamı: $E2E_LOG"
fi

# Sayaçlar, özet ve ÇIKIŞ KODU ortak kütüphanede (scripts/e2e/lib.sh):
#   0 çalışan kontrollerin hepsi geçti · 1 başarısız/ölçülemedi var
#   2 HİÇBİR KONTROL ÇALIŞMADI — "hepsi yeşil" değil, "hiçbir şey ölçülmedi"
#   3 EKSİK KAPSAM · 130 kesildi
e2e_finish
exit $?
