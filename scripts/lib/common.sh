#!/bin/bash
# =============================================================================
# databases-stack — betiklerin ortak kütüphanesi
# =============================================================================
# Tüm betikler bunu source eder. Amaç: .env okuma, loglama, kilitleme ve
# compose çağrısı gibi işlerin TEK bir doğru uygulaması olsun.
# =============================================================================

# ---------------------------------------------------------------- renkler --
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

log()     { printf '%s[bilgi]%s %s\n'  "$BLUE"   "$NC" "$*"; }
ok()      { printf '%s[✓]%s %s\n'      "$GREEN"  "$NC" "$*"; }
warn()    { printf '%s[!]%s %s\n'      "$YELLOW" "$NC" "$*" >&2; }
err()     { printf '%s[✗]%s %s\n'      "$RED"    "$NC" "$*" >&2; }
die()     { err "$@"; exit 1; }
heading() { printf '\n%s%s%s\n' "$BOLD" "$*" "$NC"; }

# ------------------------------------------------------------ stack kökü ---
# Betikler scripts/ altında; kök bir üst dizin. Sembolik link üzerinden
# çağrılsa bile doğru çözülsün diye pwd -P kullanılıyor.
_lib="${BASH_SOURCE[0]}"
while [ -L "$_lib" ]; do _lib="$(readlink "$_lib")"; done
STACK_ROOT="$(cd "$(dirname "$_lib")/../.." && pwd -P)"
export STACK_ROOT

# ------------------------------------------------- PAYLAŞILAN DOSYA İZNİ ---
# state/ ve logs/ altındaki dosyaları İKİ AYRI KİMLİK yazar:
#   • controller — container'ın İÇİNDE root (docker soketine erişmek için)
#   • siz / cron  — sunucudaki yönetici kullanıcı
# Kim önce yazarsa dosya onun olur. Varsayılan umask 022 ile root'un açtığı
# dosya 0644/root:root olur ve yöneticinin o dosyaya bir daha ASLA yazamaz.
# Ölçülmüş sonuçları:
#   • state/backup.lock root'a geçince `backup.sh`, `pitr.sh taban`,
#     `restore-drill.sh`, `failover-drill.sh` — hepsi "Kilit dosyası
#     açılamadı" ile ÖLÇÜLEMEDİ döner. Yani gece cron'u sessizce hiç
#     yedek almaz; panel yedek aldığı için de kimse fark etmez.
#   • logs/ altındaki günlük dosyaları GÜN ADIYLA açılır
#     (restore-drill_20260902.log). Controller o gün provayı bir kez
#     çalıştırdıysa, aynı gün elle çalıştırılan prova log dosyasını
#     açamaz ve düşer.
# Çözüm iki parçalı: yeni dosyalar grup-yazılabilir doğsun (umask 0002) ve
# dizinler setgid olsun (install.sh / stack.sh doctor) ki grup ortak kalsın.
umask 0002

# Paylaşılan bir dosyayı yaratır ve modunu açar. Sahibi değilsek chmod
# sessizce düşer — bu bir hata değildir, o durumda zaten yazabiliyoruzdur.
paylasilan_dosya() {   # <yol> [mod]
    local f="$1" mod="${2:-0664}"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    [ -e "$f" ] || : >> "$f" 2>/dev/null || true
    chmod "$mod" "$f" 2>/dev/null || true
}

ENV_FILE="${ENV_FILE:-$STACK_ROOT/.env}"
TUNING_ENV="$STACK_ROOT/state/tuning.env"
ROLES_ENV="$STACK_ROOT/state/roles.env"
VOLUMES_ENV="$STACK_ROOT/state/volumes.env"
COMPOSE_FILE="$STACK_ROOT/docker-compose.yml"
CATALOG="$STACK_ROOT/catalog.json"

# ------------------------------------------------- ÖLÇÜM SONUCU DEFTERİ ---
# Bir ölçümü KİMİN çalıştırdığı, sonucun nereye yazılacağını değiştirmemeli.
# Ölçüldü: `./stack.sh devir-provasi mariadb --onayla` GEÇTİ dedi ve 3.06 sn
# kesinti ölçtü, ama panel bunu hiç görmedi — state/ha-drill.json yalnız
# controller yazdığı için komut satırından koşan prova sessizce kayboluyordu.
# Aynısı kurtarma provası için de geçerliydi. Yedeklerde bu sorun zaten
# çözülmüştü (kaynak etiketi: elle / zamanlı / dış); provalar da aynı
# kurala giriyor: TEK DEFTER, kaynağı yazılı.
#
# Yazma atomik (geçici dosya + mv) ve dosya PAYLAŞILAN: aynı deftere
# controller da (container içinde root) yazıyor.
sonuc_defterine_yaz() {   # <defter-dosyası> <motor> <json-satırı> [kaynak]
    local dosya="$1" motor="$2" satir="$3" kaynak="${4:-elle}"
    [ -n "$dosya" ] && [ -n "$motor" ] && [ -n "$satir" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    paylasilan_dosya "$dosya" 0664
    DEFTER="$dosya" MOTOR="$motor" SATIR="$satir" KAYNAK="$kaynak" python3 - <<'PY' || return 1
import json, os, time
defter = os.environ["DEFTER"]
motor  = os.environ["MOTOR"]
kaynak = os.environ["KAYNAK"]
try:
    yeni = json.loads(os.environ["SATIR"])
except ValueError:
    raise SystemExit(1)
try:
    with open(defter, encoding="utf-8") as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        d = {}
except Exception:
    d = {}
yeni["at"] = int(time.time())
yeni["engine"] = motor
yeni["kaynak"] = kaynak
d[motor] = yeni
gecici = defter + ".tmp"
with open(gecici, "w", encoding="utf-8") as fh:
    json.dump(d, fh, ensure_ascii=False)
os.replace(gecici, defter)
PY
}

# ------------------------------------------------------------ .env okuma ---
# .env'i SOURCE ETMEZ — içindeki keyfi kabuk kodu çalışmasın diye satır satır
# ayrıştırır. Ayrıca:
#   • tırnakları soyar  → `PASS="abc"` compose'da abc olur; soymasaydık betik
#     "abc" (tırnaklarla) kullanır ve parola tutmazdı. Bu, eski sürümde
#     sessizce "Access denied" veren gerçek bir hataydı.
#   • satır sonundaki \r'yi atar (Windows'ta düzenlenmiş .env)
#   • ZATEN ORTAMDA TANIMLI değişkenlere dokunmaz → gerçek env her zaman önce gelir
load_env() {
    local file="${1:-$ENV_FILE}" line key val
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"; val="${line#*=}"
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
        # baştaki/sondaki boşluk
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        # tırnak soy
        if [ ${#val} -ge 2 ]; then
            case "$val" in
                \"*\") val="${val#\"}"; val="${val%\"}" ;;
                \'*\') val="${val#\'}"; val="${val%\'}" ;;
            esac
        fi
        [ -n "${!key+x}" ] && continue     # ortam değişkeni önceliklidir
        printf -v "$key" '%s' "$val"
        export "$key"
    done < "$file"
    # ŞİFRELEME DURUMU BURADA HESAPLANIR, DOSYANIN SONUNDA DEĞİL.
    # Sebebi ölçülmüş bir regresyon: enc_durumu_belirle common.sh source
    # edilirken çağrılıyordu, yani .env HENÜZ OKUNMAMIŞKEN. Sonuç, bu ürünün
    # en sevmediği türden bir sessiz yanlıştı: .env'de BACKUP_ENCRYPT_KEY
    # yazılı olduğu hâlde anahtar görünmüyor, ENC_DURUM "kapali" kalıyor ve
    # yedekler ŞİFRESİZ üretiliyordu — kullanıcı şifreleme açık sanarken.
    # Ölçüldü: anahtar .env'e yazıldı, backup.sh düz .sql.gz üretti.
    if declare -F enc_durumu_belirle >/dev/null 2>&1; then
        enc_durumu_belirle
    fi
}

# .env'den tek bir anahtar oku (yan etkisiz)
env_get() {
    local key="$1" file="${2:-$ENV_FILE}" line val
    [ -f "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in "$key"=*) ;; *) continue ;; esac
        val="${line#*=}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;;
                       \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
        printf '%s' "$val"; return 0
    done < "$file"
    return 1
}

# .env'de bir anahtarı ayarla (varsa değiştir, yoksa ekle)
env_set() {
    local key="$1" val="$2" file="${3:-$ENV_FILE}"
    touch "$file"
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"
        awk -v k="$key" -v v="$val" \
            'BEGIN{FS=OFS="="} $1==k {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' \
            "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

# ------------------------------------------------------------ gereklilik ---
require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "'$c' komutu bulunamadı. Kurun ve tekrar deneyin."
    done
}

# Docker eksikse KOPYALANABİLİR bir kurulum komutu ver. "docker bulunamadı,
# kurun" demek kullanıcıyı arama motoruna yollar; ürünün "tek komutla kurulur"
# iddiasıyla çelişir.
_docker_install_hint() {
    cat >&2 <<'HINT'

  Docker kurulu değil. Ubuntu/Debian için (kopyalayıp yapıştırın):

    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER
    newgrp docker

  Sonra bu betiği tekrar çalıştırın:  ./install.sh
  Diğer dağıtımlar: https://docs.docker.com/engine/install/

HINT
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        _docker_install_hint
        die "Docker bulunamadı."
    fi
    if ! docker compose version >/dev/null 2>&1; then
        err "Docker Compose v2 gerekli — 'docker compose' alt komutu yok."
        _docker_install_hint
        die "Docker sürümünüz eski."
    fi
    if ! docker info >/dev/null 2>&1; then
        err "Docker çalışmıyor ya da bu kullanıcının yetkisi yok."
        cat >&2 <<'HINT'

  Şunları deneyin:
    sudo systemctl start docker      # servis kapalıysa
    sudo usermod -aG docker $USER    # yetki yoksa
    newgrp docker                    # grubu bu oturuma uygula

HINT
        die "Docker'a erişilemiyor."
    fi
}
# =============================================================================
# YEDEK ŞİFRELEME — OKUMA TARAFI
# =============================================================================
# BURADA, backup.sh'ta DEĞİL. Sebebi ölçülmüş bir hata: restore-drill.sh yalnız
# common.sh'ı source ediyor ve şifreli yedekleri aday olarak SEÇİP (kendi
# find deseninde .gz.enc var) düz `gzip -dc` ile açmaya çalışıyordu. Şifreleme
# açık bir kurulumda haftalık prova, SAPASAĞLAM bir yedeğe "geri yüklenemedi"
# damgası vuruyordu — yani ürünün en çok güvendiği ölçüm, en çok güvendiği
# özelliği suçluyordu. Okuma yolu tek yerde durmalı.
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
# İKİ KEZ ÇAĞRILIYOR, bilerek:
#   1) BURADA — anahtarı ORTAM DEĞİŞKENİ olarak veren çağrılar (testler,
#      cron satırları, `BACKUP_ENCRYPT_KEY=… ./betik`) load_env çağırmadan
#      da doğru durumu görsün.
#   2) load_env'in SONUNDA — anahtar .env'de yazılıysa ancak orada görünür.
# Fonksiyon durumu her seferinde SIFIRDAN hesaplıyor; ikinci çağrı tam
# bilgiyle birincinin üzerine yazıyor. Yalnız birini bırakmak, iki ayrı
# sessiz yanlıştan birini üretiyordu: yalnız (1) ise .env'deki anahtar
# görünmüyor ve yedekler ŞİFRESİZ yazılıyordu (ölçüldü); yalnız (2) ise
# ortamdan anahtar veren her çağrı şifrelemeyi kapalı görüyordu.
enc_durumu_belirle

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


# ------------------------------------------------------------- kilitleme ---
# flock tabanlı: kilit AÇIK BİR DOSYA TANIMLAYICISINA bağlanır ve süreç ölünce
# çekirdek tarafından bırakılır. Yaş bakan eski mantık, sahibi hâlâ çalışırken
# kilidi kırıp ikinci bir yedek başlatabiliyordu (iki paralel dump = DB
# container'ında çift bellek baskısı = OOM).
# KİLİT DOSYASI /tmp'DE DEĞİL, YIĞININ KENDİ DİZİNİNDE durur. /tmp herkese
# yazılabilir ama dosya SAHİBİ onu ilk yaratan kullanıcıdır: root olarak bir kez
# koşan yedek, /tmp/databases-stack-backup.lock'u root'a ait 0644 bırakıyor ve
# ondan sonra normal kullanıcının HER yedeği "Permission denied" ile ölüyordu.
# (Gerçek olay: e2e yedek paketi bu yüzden komple başarısız oldu.) state/
# dizini yığının kendisine ait olduğu için sahiplik sorunu doğurmaz; hem de
# panelden (controller container'ı) ve host'tan gelen koşular AYNI kilidi
# görür — /tmp container'da ayrı bir dosya sistemidir, orada görmezlerdi.
acquire_lock() {
    local lockfile="${1:-${STACK_ROOT:-/tmp}/state/databases-stack.lock}"
    command -v flock >/dev/null 2>&1 || die "flock (util-linux) gerekli."
    # Kilit dosyasının İÇİNDE veri yoktur; herkese yazılabilir olması bir
    # sır sızdırmaz. Buradaki tek amaç, controller (root) ile yöneticinin
    # AYNI kilidi paylaşabilmesi — paylaşamazlarsa ikisi aynı anda yedek
    # alır ve kilidin var olma sebebi ortadan kalkar.
    paylasilan_dosya "$lockfile" 0666
    if ! exec 9>>"$lockfile"; then
        die "Kilit dosyası açılamadı: $lockfile
  Sahibi: $(stat -c '%U:%G %a' "$lockfile" 2>/dev/null || echo bilinmiyor) · siz: $(id -un)
  Bu dosyaya controller (container'da root) da yazar; kim önce yazarsa
  dosya onun olur ve diğeri bir daha açamaz. Onarım:
    ./stack.sh doctor --duzelt"
    fi
    if ! flock -n 9; then
        die "Başka bir işlem kilidi tutuyor ($lockfile). Çıkılıyor."
    fi
}

# --------------------------------------------------------------- compose ---
# Her zaman iki env dosyası: .env (sırlar) + state/tuning.env (controller'ın
# hesapladığı bellek ayarları). Sıra önemli — sonraki öncekini ezer.
compose() {
    local args=(--project-directory "$STACK_ROOT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE")
    [ -f "$TUNING_ENV" ] && args+=(--env-file "$TUNING_ENV")
    # roles.env replikasyon rollerini tutar (hangi düğüm primary).
    [ -f "$ROLES_ENV" ] && args+=(--env-file "$ROLES_ENV")
    # volumes.env hangi hacim kuşağının canlı olduğunu tutar.
    # Betikler bunu okumazsa compose ESKİ kuşağı bağlar ve motor
    # geri yüklenmemiş veriyle açılır — sessiz ve yıkıcı.
    [ -f "$VOLUMES_ENV" ] && args+=(--env-file "$VOLUMES_ENV")
    # Etkin override'lar (replikasyon vb.) state.json'da tutulur
    if [ -f "$STACK_ROOT/state/state.json" ] && command -v python3 >/dev/null 2>&1; then
        local ov
        ov=$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1])).get('overrides',[])))" \
             "$STACK_ROOT/state/state.json" 2>/dev/null) || ov=""
        for o in $ov; do
            [ -f "$STACK_ROOT/overrides/$o.yml" ] && args+=(-f "$STACK_ROOT/overrides/$o.yml")
        done
    fi
    docker compose "${args[@]}" -p "${STACK_PROJECT:-databases-stack}" "$@"
}

# Katalogdan JSON alanı oku (python3 her modern dağıtımda var)
catalog_query() {
    python3 -c "$1" "$CATALOG" 2>/dev/null
}

# Bir container çalışıyor mu?
container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# Motorun aktif olup olmadığı (kataloğa göre birincil servis)
engine_active() {
    container_running "$(primary_of "$1")"
}

# Bir motorun ŞU ANKİ ana kopya container'ı.
# Devirden sonra bu, kataloğun varsayılan servisi DEĞİLDİR: eski ana kopya
# fence edilip durdurulmuş, yedek kopya ana kopya olmuştur. Sabit adı kullanan
# betikler devirden sonra durdurulmuş container'a bakıp "kapalı" sanar ve
# sessizce hiçbir şey yapmaz — yedekleme için bu veri kaybı riskidir.
primary_of() {
    local eid="$1"
    local topo="$STACK_ROOT/state/topology.json"
    if [ -f "$topo" ] && command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    t = json.load(open(sys.argv[1], encoding="utf-8"))
    print(t.get(sys.argv[2], {}).get("primary") or sys.argv[2])
except Exception:
    print(sys.argv[2])' "$topo" "$eid" 2>/dev/null || printf '%s' "$eid"
    else
        printf '%s' "$eid"
    fi
}

rand_secret() {
    local n="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$n"
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$n"
    fi
    echo
}
