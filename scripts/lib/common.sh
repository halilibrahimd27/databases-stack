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
