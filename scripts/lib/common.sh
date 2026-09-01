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

ENV_FILE="${ENV_FILE:-$STACK_ROOT/.env}"
TUNING_ENV="$STACK_ROOT/state/tuning.env"
COMPOSE_FILE="$STACK_ROOT/docker-compose.yml"
CATALOG="$STACK_ROOT/catalog.json"

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

require_docker() {
    require_cmd docker
    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose v2 gerekli ('docker compose'). Docker'ı güncelleyin."
    docker info >/dev/null 2>&1 \
        || die "Docker çalışmıyor ya da bu kullanıcının yetkisi yok (sudo gerekebilir)."
}

# ------------------------------------------------------------- kilitleme ---
# flock tabanlı: kilit AÇIK BİR DOSYA TANIMLAYICISINA bağlanır ve süreç ölünce
# çekirdek tarafından bırakılır. Yaş bakan eski mantık, sahibi hâlâ çalışırken
# kilidi kırıp ikinci bir yedek başlatabiliyordu (iki paralel dump = DB
# container'ında çift bellek baskısı = OOM).
acquire_lock() {
    local lockfile="${1:-/tmp/databases-stack.lock}"
    command -v flock >/dev/null 2>&1 || die "flock (util-linux) gerekli."
    exec 9>>"$lockfile" || die "Kilit dosyası açılamadı: $lockfile"
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
    container_running "$1"
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
