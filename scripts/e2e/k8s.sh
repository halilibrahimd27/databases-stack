#!/bin/bash
# =============================================================================
# databases-stack — uçtan uca test: KUBERNETES DAĞITIMI (k3s)
# =============================================================================
# Ne doğrular: k8s/base altındaki manifestler GERÇEK bir cluster'da işe yarıyor
# mu? "kubectl apply hata vermedi" bunu göstermez. Bu betik zinciri sonuna
# kadar yürütür:
#
#   k3s başlat → apply → bir motoru 0→1 ölçekle → controller'ın HESAPLADIĞI
#   bellek ayarlarının POD İÇİNDE gerçekten uygulandığını motorun kendisine
#   sorarak ölç (SHOW shared_buffers) → veri yaz/oku → 1→0 → PVC'nin ve
#   verinin kaldığını yeniden açıp ölç → k3s'i TEMİZLE → Docker yığınının
#   80/443 portlarının geri geldiğini ölç.
#
# Boyutlandırma kısmı neden bu kadar önemli: motorların çoğu bellek ayarını
# yalnız KOMUT SATIRINDAN alır (env değişkeni okumaz). K8s manifestinde args
# yoksa ya da $(VAR) yerine konmazsa `kubectl set env` sessizce başarılı olur,
# pod da ayakta görünür — ama motor VARSAYILANLARLA çalışır. Ürünün
# "sunucuya göre ayarlıyorum" vaadi hiçbir hata vermeden boşa çıkar. Tek
# yakalama yolu motora kendi ayarını sormaktır; bu betik onu yapar.
#
# Kanıt motoru PostgreSQL: SHOW shared_buffers motorun ÇALIŞAN değerini verir
# (env'e ne yazdığımızı değil) ve hesaplanan değerler varsayılanlardan belirgin
# şekilde farklıdır — yani kontrol gerçekten ayrım yapar.
#
# DİKKAT: aynı host'ta k3s + Docker yığını 80/443 için ÇAKIŞIR. k3s'in
# Traefik'i iptables nat/PREROUTING'de DOCKER zincirinden ÖNCE DNAT kuralı
# koyar; paket gateway'e hiç ulaşmaz (docs/KUBERNETES.md). Bu yüzden betik
# önce uyarır ve onay ister, sonunda da temizleyip portların döndüğünü ÖLÇER.
#
# Kullanım (yığın kökünden):
#   ./scripts/e2e/k8s.sh                        onay sorar
#   ./scripts/e2e/k8s.sh --yes                  onay sormaz (CI / uzak oturum)
#   ./scripts/e2e/k8s.sh --yes --install-k3s    k3s yoksa kurar, sonunda kaldırır
#   ./scripts/e2e/k8s.sh --yes --no-controller  kontrol servisi pod'unu atlar
#
# Ortam değişkenleri:
#   E2E_POD_TIMEOUT=420   pod'un hazır olması için üst sınır (sn; imaj çekme)
#   E2E_K3S_TIMEOUT=180   k3s API'sinin ayağa kalkması için üst sınır (sn)
# =============================================================================
set -uo pipefail

_bu_dizin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/common.sh
source "$_bu_dizin/../lib/common.sh"
cd "$STACK_ROOT" || { echo "yığın köküne geçilemedi"; exit 1; }
load_env

ALAN="k8s"
ENGINE="postgresql"          # pod içi ayar kanıtı bu motor üzerinden yapılır
POD_TIMEOUT="${E2E_POD_TIMEOUT:-420}"
K3S_TIMEOUT="${E2E_K3S_TIMEOUT:-180}"
KUBECTL_TIMEOUT="${E2E_KUBECTL_TIMEOUT:-60}"
JETON="e2e-k8s-$(date +%s)-$$"
TABLO="e2e_k8s_kanit"
ISTEMCI_POD="e2e-k8s-istemci"

ONAY=0; KUR_K3S=0; CONTROLLER_TESTI=1

for arg in "$@"; do
    case "$arg" in
        -y|--yes|--evet)   ONAY=1 ;;
        --install-k3s)     KUR_K3S=1 ;;
        --no-controller)   CONTROLLER_TESTI=0 ;;
        -h|--help|yardim)
            sed -n '3,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "bilinmeyen argüman: $arg  (yardım: --help)" ;;
    esac
done

# =============================================================================
# TEST ÇERÇEVESİ
# =============================================================================
TOPLAM=0; GECEN=0; BASARISIZ=0; ATLANAN=0
declare -A _RAPOR=()

t_ok() {
    _RAPOR["$1"]=1; TOPLAM=$((TOPLAM+1)); GECEN=$((GECEN+1))
    printf '%s[GEÇTİ]%s   %s\n' "$GREEN" "$NC" "$1"
    [ -n "${2:-}" ] && printf '            %s\n' "$2"
    return 0
}
t_fail() {
    _RAPOR["$1"]=1; TOPLAM=$((TOPLAM+1)); BASARISIZ=$((BASARISIZ+1))
    printf '%s[KALDI]%s   %s\n' "$RED" "$NC" "$1" >&2
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/            ↳ /' >&2
    return 0
}
# Sessizce atlanan test "geçti" sanılır — en tehlikeli test hatası budur.
# Bu yüzden atlama da bir satır basar ve SEBEBİNİ söyler.
t_skip() {
    _RAPOR["$1"]=1; TOPLAM=$((TOPLAM+1)); ATLANAN=$((ATLANAN+1))
    printf '%s[ATLANDI]%s %s\n' "$YELLOW" "$NC" "$1"
    printf '            ↳ sebep: %s\n' "${2:-belirtilmedi}"
    return 0
}

# --- kontrol adları --------------------------------------------------------
# Adlar tek yerde duruyor: kontrol hem çalıştırılırken hem de "çalıştırılamadı"
# diye atlanırken aynı metni kullansın, böylece toplam sayı (Y) her koşuda
# sabit kalır ve "kaç test çalışmadı" gizlenemez.
K_NODE="k3s API sunucusu ayakta ve node Ready durumda"
K_APPLY="kubectl apply -k k8s/base: isim alanı + katalogdaki her veritabanı için StatefulSet oluştu"
K_REPLICAS="tüm veritabanı StatefulSet'leri replicas=0 geldi (kapalı motor = sıfır pod)"
K_SECRET="db-secrets Secret'ındaki POSTGRES_PASSWORD .env'deki parolayla aynı"
K_RBAC_OK="controller ServiceAccount'u statefulsets/scale'i patch edebiliyor"
K_RBAC_NO="controller ServiceAccount'u pod silemiyor / secret okuyamıyor (yetki dar)"
K_CTRL="controller Deployment'ı k3s'te Ready oldu (/healthz probe'u cevap verdi)"
K_NODE_MB="kapasite en büyük node'un allocatable belleğinden okundu (host /proc/meminfo'dan değil)"
K_PLAN="postgresql için bellek planı hesaplandı (limit + motor ayarları)"
K_UP="aktivasyon 0→1: postgresql-0 pod'u Ready ve bağlantı kabul ediyor"
K_LIMIT="pod'un bellek limiti plandaki limitle aynı"
K_SB="pod İÇİNDE shared_buffers plandaki değere eşit (SHOW shared_buffers)"
K_DIGER="pod İÇİNDE effective_cache_size ve max_connections plandaki değerlere eşit"
K_YAZ="pod'a yazılan satır aynı pod'dan geri okunuyor"
K_SVC="satır, cluster içinden Service adıyla (postgresql:5432) da okunuyor"
K_DOWN="durdurma 1→0: pod kayboldu"
K_PVC="pod yokken PVC hâlâ Bound (veri diski silinmedi)"
K_KALICI="yeniden aktivasyonda satır hâlâ orada (veri gerçekten PVC'de yaşıyor)"
K_KILL="k3s-killall.sh + systemctl disable sonrası k3s kapalı ve açılışta gelmeyecek"
K_IPT="nat/PREROUTING'de KUBE-SERVICES / CNI-HOSTPORT-DNAT kuralı kalmadı"
K_HTTP="Docker yığınının 80 portu geri geldi (dışarıdan gelen cevap gateway'inkiyle aynı)"
K_HTTPS="Docker yığınının 443 portu geri geldi (panel yeniden açılıyor)"

SIRA_MOTOR=("$K_NODE" "$K_APPLY" "$K_REPLICAS" "$K_SECRET" "$K_RBAC_OK" "$K_RBAC_NO"
            "$K_CTRL" "$K_NODE_MB" "$K_PLAN" "$K_UP" "$K_LIMIT" "$K_SB" "$K_DIGER"
            "$K_YAZ" "$K_SVC" "$K_DOWN" "$K_PVC" "$K_KALICI")
SIRA_TEMIZ=("$K_KILL" "$K_IPT" "$K_HTTP" "$K_HTTPS")

# Ön koşul sağlanmadığında geri kalan kontroller SESSİZ KALMAZ: hepsi tek tek
# "atlandı + sebep" olarak raporlanır.
atla_kalan() {
    local sebep="$1" ad
    for ad in "${SIRA_MOTOR[@]}"; do
        [ -n "${_RAPOR[$ad]:-}" ] || t_skip "$ad" "$sebep"
    done
}
atla_temizlik() {
    local sebep="$1" ad
    for ad in "${SIRA_TEMIZ[@]}"; do
        [ -n "${_RAPOR[$ad]:-}" ] || t_skip "$ad" "$sebep"
    done
}

# Hiçbir bekleme sonsuz değildir; beklerken NE beklendiği ekrana yazılır.
# Terminal yoksa (cron, CI, `| tee log`) geri sayım satırı \r ile log'u
# çöplemesin diye tek satır yazılır.
bekle() {   # bekle <saniye> <ne bekleniyor> <komut...>
    local sure="$1" ne="$2"; shift 2
    local t0=$SECONDS
    [ -t 1 ] || log "bekleniyor: $ne (en fazla $sure sn)"
    while :; do
        if "$@" >/dev/null 2>&1; then
            [ -t 1 ] && printf '\r%*s\r' 78 ''
            return 0
        fi
        if [ $((SECONDS-t0)) -ge "$sure" ]; then
            [ -t 1 ] && printf '\r%*s\r' 78 ''
            return 1
        fi
        [ -t 1 ] && printf '\r  … %s (%s/%s sn)' "$ne" "$((SECONDS-t0))" "$sure"
        sleep 3
    done
}

# =============================================================================
# ORTAM
# =============================================================================
[ "$(uname -s)" = "Linux" ] || die "bu betik Ubuntu sunucuda çalışır (k3s + systemd gerekir)."
require_cmd python3 curl
command -v systemctl >/dev/null 2>&1 || die "systemctl yok — k3s systemd ister."

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "root değilsiniz ve sudo yok — k3s'i yönetemem."
    SUDO="sudo"
    # Parola sorulacaksa BAŞTA sorulsun: testin ortasında, uzun bir beklemenin
    # arkasında sessizce sudo prompt'una takılmak en kötü senaryo.
    $SUDO -v || die "sudo yetkisi alınamadı. Testi 'sudo ./scripts/e2e/k8s.sh --yes' \
ile ya da parolasız sudo'su olan bir kullanıcıyla çalıştırın (k3s'i başlatmak, \
kubeconfig'i okumak ve sonunda killall yapmak için gerekir)."
fi

NS="$(awk '/^namespace:/{print $2; exit}' k8s/base/kustomization.yaml 2>/dev/null)"
[ -n "$NS" ] || NS="databases-stack"

# Katalog TEK YETKİ KAYNAĞI: servis adı, port ve motor sayısı buradan okunur —
# betiğe sabit yazılmaz, yoksa katalog değişince test sessizce yanlış şeyi ölçer.
motor_alan() {   # motor_alan <python ifadesi; e = motor kaydı>
    python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
m=[x for x in c["engines"] if x["id"]==sys.argv[2]]
if not m: sys.exit(1)
e=m[0]
print(eval(sys.argv[3]))' "$CATALOG" "$ENGINE" "$1" 2>/dev/null
}
STS="$(motor_alan 'e["primary_service"]')"
K8S_PORT="$(motor_alan 'e["k8s"]["port"]')"
[ -n "$STS" ] && [ -n "$K8S_PORT" ] || die "catalog.json'da $ENGINE kaydı okunamadı."
POD="${STS}-0"
DB_SAYISI="$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print(sum(1 for e in c["engines"] if e.get("kind","database")=="database"))' "$CATALOG")"
[ -n "$DB_SAYISI" ] || DB_SAYISI=0

# Geçici dizin ANCAK buradan sonra: yukarıdaki die'lar arkalarında dizin
# bırakmasın (EXIT tuzağı henüz kurulmadı, kimse silmezdi).
TMPD="$(mktemp -d /tmp/e2e-k8s.XXXXXX)" || die "geçici dizin açılamadı"
chmod 700 "$TMPD"

GW_HTTP="${GATEWAY_HTTP_PORT:-80}"
GW_HTTPS="${GATEWAY_HTTPS_PORT:-443}"

# durum bayrakları (temizlik bunlara bakar)
K3S_ONCE_AKTIF=0; K3S_BIZ_KURDUK=0; K3S_BIZ_BASLATTIK=0
TEMEL_HTTP="000"; TEMEL_HTTPS="000"
NS_ONCEDEN_VARDI=1; TEMIZLENDI=0; KESILDI=0
PLAN_DOSYA="$TMPD/plan.json"
LIMIT_MB=""; KAP="$ENGINE"; PGUSER="root"; PGDB="defaultdb"; PVC=""

# Hiçbir kubectl çağrısı sonsuza kadar asılı kalmasın (API sunucusu ölürse
# betik dakikalarca sessiz bekler ve temizlik gecikir).
kc() { timeout "$KUBECTL_TIMEOUT" kubectl "$@"; }

# =============================================================================
# YARDIMCILAR — motorla ve ürünün kontrol düzlemiyle konuşma
# =============================================================================
pg_deger() {   # pod içinde tek değer okur
    kc -n "$NS" exec "$POD" -c "$KAP" -- \
        psql -U "$PGUSER" -d "$PGDB" -tAc "$1" 2>/dev/null | tr -d '\r' | head -1 \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}
pg_calistir() {   # rc + birleşik çıktı (tanı için)
    kc -n "$NS" exec "$POD" -c "$KAP" -- \
        psql -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 -tAc "$1" 2>&1 | tr -d '\r'
}
# PostgreSQL init sırasında geçici sunucu listen_addresses='' ile açılır; asıl
# sunucu '*' ile. Bu ayrım olmadan pg_isready init aşamasında da "hazır" der ve
# test yarı kurulmuş bir veritabanına soru sormaya başlar (kararsız KALDI'lar).
pg_hazir() { [ "$(pg_deger 'SHOW listen_addresses')" = "*" ]; }

# PostgreSQL birimleri normalize eder: 1024MB'yi "1GB" diye gösterir. Düz metin
# karşılaştırması bu yüzden yanlış KALDI üretir — iki tarafı da kB'ye çeviriyoruz.
kb_cevir() {
    python3 - "$1" <<'PY'
import re, sys
s = sys.argv[1].strip().replace(" ", "")
m = re.match(r"^(-?\d+(?:\.\d+)?)([A-Za-z]*)$", s)
if not m:
    print(""); raise SystemExit(0)
v = float(m.group(1)); u = m.group(2).lower()
carpan = {"": 1.0, "b": 1 / 1024.0, "kb": 1.0, "k": 1.0, "mb": 1024.0, "m": 1024.0,
          "gb": 1048576.0, "g": 1048576.0, "tb": 1073741824.0}
print(int(v * carpan.get(u, 1.0)))
PY
}
esit_mi() {   # esit_mi <beklenen> <bulunan>
    local a b
    a="$(kb_cevir "${1:-}")"; b="$(kb_cevir "${2:-}")"
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" = "$b" ]
}

plan_alan() {   # plan_alan <anahtar.yolu>
    python3 - "$PLAN_DOSYA" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(""); raise SystemExit(0)
cur = d
for k in sys.argv[2].split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
    if cur is None:
        print(""); raise SystemExit(0)
print(cur)
PY
}

# Ölçekleme ve boyutlandırma ÜRÜNÜN KENDİ KODUYLA yapılır (controller/app.py →
# _k8s_scale). Betik kendi kubectl komutlarını yazsaydı controller'daki bir hata
# (yanlış container adı, atlanan `set env`) teste hiç yansımaz, test yeşil
# yanarken paneldeki "Aktif Et" düğmesi bozuk kalırdı.
k8s_scale() {   # k8s_scale 0|1
    E2E_HEDEF="$1" E2E_ENGINE="$ENGINE" E2E_PLAN="$PLAN_DOSYA" \
    CONTROLLER_DIR="$STACK_ROOT/controller" \
    BACKEND=kubernetes K8S_NAMESPACE="$NS" CATALOG_PATH="$CATALOG" \
    STATE_DIR="$TMPD/state" PYTHONIOENCODING=utf-8 \
    python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["CONTROLLER_DIR"])
import app                                    # ← ürünün gerçek kontrol düzlemi
e = app.CATALOG.engine(os.environ["E2E_ENGINE"])
hedef = int(os.environ["E2E_HEDEF"])
limit, tuning = None, None
if hedef > 0:
    try:
        p = json.load(open(os.environ["E2E_PLAN"], encoding="utf-8"))
        limit, tuning = p.get("limit_mb"), p.get("tuning")
    except Exception:
        pass
rc, out, err = app._k8s_scale(e, hedef, limit, tuning)
sys.stderr.write((out or "") + (err or ""))
sys.exit(0 if rc == 0 else 1)
PY
}

# =============================================================================
# TEMİZLİK — bu adım atlanırsa kullanıcının paneli çalışmaz hâlde kalır.
# Bu yüzden EXIT tuzağına bağlı: betik nerede biterse bitsin çalışır.
# =============================================================================
# curl bağlanamayınca da '%{http_code}' ile "000" basar; ayrıca `|| echo 000`
# yazmak "000000" gibi bozuk bir değer üretirdi (kod yalnız yan yana eklenirdi).
_kod_dis() {   # _kod_dis <şema> <port> — host'tan gelen HTTP kodu
    local kf="" c
    [ "$1" = "https" ] && kf="-k"
    c="$(curl -s $kf -o /dev/null -w '%{http_code}' --max-time 5 "$1://127.0.0.1:$2/" 2>/dev/null)"
    printf '%s' "${c:-000}"
}

# Portun "açık" olması yetmez — asıl soru cevabın GATEWAY'DEN gelip gelmediği.
# Container İÇİNDEN ve dışarıdan alınan HTTP kodları karşılaştırılır;
# `stack.sh doctor` da tam olarak bunu yapar. Traefik kaçırıyorsa dışarıdaki
# kod (404) içerideki koddan (401/200) farklı çıkar — port yine "açık" görünür.
_port_geri_geldi_mi() {   # _port_geri_geldi_mi <kontrol adı> <şema> <port> <test öncesi kod>
    local ad="$1" sema="$2" port="$3" temel="$4" kflag=""
    [ "$sema" = "https" ] && kflag="-k"
    command -v docker >/dev/null 2>&1 || { t_skip "$ad" "docker komutu yok"; return 0; }
    container_running gateway || { t_skip "$ad" "gateway container'ı çalışmıyor — Docker yığını kurulu değil ya da kapalı"; return 0; }
    if [ "$temel" = "000" ]; then
        t_skip "$ad" "$port portu test BAŞLAMADAN da dışarıdan cevap vermiyordu (kod 000) — geri geldiğini ölçecek bir başlangıç değeri yok"
        return 0
    fi

    _ic=""; _dis=""
    _olc() {
        _ic="$(docker exec gateway curl -s $kflag -o /dev/null -w '%{http_code}' \
               --max-time 5 "$sema://127.0.0.1:$port/" 2>/dev/null)"
        _dis="$(_kod_dis "$sema" "$port")"
        [ -n "$_ic" ] || _ic="000"
        # Birincil ölçüt: dışarıdan gelen cevap test ÖNCESİYLE aynı mı?
        [ "$_dis" = "$temel" ] || return 1
        # İkincil ölçüt: cevap gerçekten gateway'den mi geliyor? (Traefik
        # araya girdiğinde container içi ve dışı kodlar ayrışır.) Gateway'de
        # curl yoksa _ic=000 gelir; o durumda birincil ölçütle yetiniyoruz.
        [ "$_ic" = "000" ] || [ "$_ic" = "$_dis" ]
    }

    # iptables kuralları hemen düşmeyebilir; kısa bir pencere tanıyoruz.
    if bekle 30 "$port portunun gateway'e dönmesi bekleniyor" _olc; then
        t_ok "$ad" "dışarıdan $_dis (test öncesiyle aynı), gateway içinden $_ic"
        return 0
    fi
    # docs/KUBERNETES.md'nin temizlik adımının son maddesi: gateway'i yenile.
    log "port dönmedi; belgedeki adım deneniyor: docker restart gateway"
    docker restart gateway >/dev/null 2>&1
    if bekle 60 "gateway yeniden başlatıldı, $port portu bekleniyor" _olc; then
        t_ok "$ad" "gateway yeniden başlatıldıktan sonra döndü (dışarıdan $_dis, içeriden $_ic)"
    else
        t_fail "$ad" "test öncesi dışarıdan '$temel' gelirken şimdi '$_dis' geliyor (gateway içinden '$_ic') — $port hâlâ başka bir yere gidiyor.
Kimin dinlediği:  sudo ss -lntp | grep ':$port '
Yönlendirme:      sudo iptables -t nat -L PREROUTING -n"
    fi
    return 0
}

_k3s_kapali_mi_dogrula() {
    local aktif="hayir" surec="" otomatik=""
    systemctl is-active --quiet k3s 2>/dev/null && aktif="evet"
    surec="$(pgrep -f '/usr/local/bin/k3s server' 2>/dev/null | head -3 | tr '\n' ' ')"
    otomatik="$(systemctl is-enabled k3s 2>/dev/null || true)"
    if [ "$aktif" = "hayir" ] && [ -z "$surec" ] && [ "$otomatik" != "enabled" ]; then
        t_ok "$K_KILL" "servis durumu: ${otomatik:-yok}, çalışan 'k3s server' süreci yok"
    elif [ "$aktif" = "hayir" ] && [ -z "$surec" ]; then
        t_fail "$K_KILL" "k3s durdu ama hâlâ 'enabled': makine yeniden başlayınca 80/443'ü tekrar kapar.
Elle: sudo systemctl disable k3s"
    else
        t_fail "$K_KILL" "k3s hâlâ ayakta (is-active=$aktif, süreçler: ${surec:-yok}).
Elle: sudo /usr/local/bin/k3s-killall.sh && sudo systemctl disable --now k3s"
    fi

    # Asıl arıza buradaydı: k3s dursa bile nat/PREROUTING'deki KUBE-SERVICES /
    # CNI-HOSTPORT-DNAT kuralları DOCKER zincirinden önce gelir ve 80/443'ü
    # kaçırmaya devam eder. `systemctl stop k3s` bu kuralları KALDIRMAZ.
    if ! command -v iptables >/dev/null 2>&1; then
        t_skip "$K_IPT" "iptables komutu yok — kuralları göremiyorum"
    else
        local kalan
        kalan="$($SUDO iptables -t nat -S PREROUTING 2>/dev/null | grep -cE 'KUBE-SERVICES|CNI-HOSTPORT-DNAT')"
        [ -n "$kalan" ] || kalan=0
        if [ "$kalan" -eq 0 ]; then
            t_ok "$K_IPT" "PREROUTING temiz"
        else
            t_fail "$K_IPT" "$kalan kural kaldı; 80/443 hâlâ Traefik'e gidiyor olabilir.
Görmek için: sudo iptables -t nat -L PREROUTING -n"
        fi
    fi

    _port_geri_geldi_mi "$K_HTTP"  "http"  "$GW_HTTP"  "$TEMEL_HTTP"
    _port_geri_geldi_mi "$K_HTTPS" "https" "$GW_HTTPS" "$TEMEL_HTTPS"
}

temizle() {
    [ "$TEMIZLENDI" = 1 ] && return 0
    TEMIZLENDI=1
    heading "6/6 — temizlik ve Docker yığınının geri gelmesi"

    # `kubectl version` API'ye ulaşamasa da 0 dönebilir; /readyz dönmüyorsa
    # cluster gerçekten yok demektir — boşuna 60 sn kubectl beklemeyelim.
    if [ -n "${KUBECONFIG:-}" ] && kc get --raw /readyz >/dev/null 2>&1; then
        # Kendi yarattığımız tabloyu bırakmayız: betik iki kez üst üste
        # çalıştırılabilir olmalı ve kullanıcının verisinde iz kalmamalı.
        if kc -n "$NS" get pod "$POD" >/dev/null 2>&1; then
            pg_calistir "DROP TABLE IF EXISTS $TABLO" >/dev/null 2>&1 \
                && log "test tablosu ($TABLO) silindi"
        fi
        kc -n "$NS" delete pod "$ISTEMCI_POD" --ignore-not-found --now >/dev/null 2>&1
        k8s_scale 0 >/dev/null 2>&1 && log "$STS 0 replikaya indirildi"
        if [ "$NS_ONCEDEN_VARDI" = 0 ]; then
            # İsim alanını BİZ yarattıysak geri alıyoruz: makineyi bulduğumuz
            # gibi bırakmak testin sözleşmesi. --wait=false, silme finalizer'a
            # takılırsa betiğin temizliğini bloklamasın diye.
            kc delete ns "$NS" --wait=false >/dev/null 2>&1 \
                && log "$NS isim alanı silindi (bu koşuda yaratılmıştı)"
        else
            log "not: $NS isim alanı ve PVC'ler bırakıldı (bu koşudan önce de vardı)."
        fi
    fi

    # `systemctl stop k3s` YETMEZ: pod'lar containerd altında yaşamaya devam
    # eder ve iptables kuralları yerinde kalır (docs/KUBERNETES.md).
    if [ "$K3S_BIZ_KURDUK" = 1 ]; then
        log "k3s kaldırılıyor (bu koşuda kurulmuştu)…"
        [ -x /usr/local/bin/k3s-uninstall.sh ] \
            && $SUDO /usr/local/bin/k3s-uninstall.sh >"$TMPD/uninstall.log" 2>&1
        _k3s_kapali_mi_dogrula
    elif [ "$K3S_BIZ_BASLATTIK" = 1 ]; then
        log "k3s durduruluyor (killall + disable)…"
        [ -x /usr/local/bin/k3s-killall.sh ] \
            && $SUDO /usr/local/bin/k3s-killall.sh >"$TMPD/killall.log" 2>&1
        $SUDO systemctl disable --now k3s >/dev/null 2>&1
        _k3s_kapali_mi_dogrula
    elif [ "$K3S_ONCE_AKTIF" = 1 ]; then
        atla_temizlik "k3s bu betikten ÖNCE de çalışıyordu; kullanıcının kurulumunu kapatmıyoruz. 80/443'ü Docker'a geri vermek için: sudo /usr/local/bin/k3s-killall.sh && sudo systemctl disable --now k3s && docker restart gateway"
    else
        atla_temizlik "k3s bu koşuda hiç başlatılmadı — temizlenecek bir şey yok"
    fi

    rm -rf "$TMPD"
}

ozet() {
    printf '\n'
    printf '%s%s: %d/%d geçti%s' "$BOLD" "$ALAN" "$GECEN" "$TOPLAM" "$NC"
    [ "$BASARISIZ" -gt 0 ] && printf ' — %d başarısız' "$BASARISIZ"
    [ "$ATLANAN" -gt 0 ] && printf ' — %d atlandı' "$ATLANAN"
    printf '\n\n'
    return 0
}

cikista() {
    temizle
    ozet
    [ "$KESILDI" = 1 ] && exit 130
    [ "$BASARISIZ" -gt 0 ] && exit 1
    exit 0
}
trap cikista EXIT
trap 'KESILDI=1; warn "kesildi — temizlik yine de çalışacak"; exit 130' INT TERM

# =============================================================================
# 0/6 — UYARI VE ONAY
# =============================================================================
heading "databases-stack — uçtan uca test: Kubernetes dağıtımı"
cat <<'UYARI'

  ┌──────────────────────────────────────────────────────────────────────┐
  │ DİKKAT: bu test, bu makinedeki Docker yığınının 80/443 portlarını     │
  │ GEÇİCİ olarak kesecek.                                               │
  └──────────────────────────────────────────────────────────────────────┘

  k3s kendi Traefik'i ile 80 ve 443'ü iptables DNAT ile kapar; kural
  nat/PREROUTING'de DOCKER zincirinden ÖNCE gelir, paket gateway'e hiç
  ulaşmaz. Test sürerken (birkaç dakika):

    • panel (https://sunucu/) "404 page not found" verir — Traefik'in cevabı
    • veritabanı portları (3306, 5432, 27017 …) ETKİLENMEZ

  Sonunda k3s killall + disable ile temizlenir ve portların GERİ GELDİĞİ
  ölçülerek doğrulanır. Yine de canlı kullanıcı varken çalıştırmayın.

UYARI

if [ "$ONAY" != 1 ] && [ -t 0 ]; then
    printf '  Devam etmek için "evet" yazın (60 sn): '
    cevap=""
    read -r -t 60 cevap || true
    printf '\n'
    case "$cevap" in
        evet|EVET|e|E|yes|y) ONAY=1 ;;
    esac
fi
if [ "$ONAY" != 1 ]; then
    atla_kalan "onay verilmedi (etkileşimsiz çalıştırmak için --yes bayrağı)"
    atla_temizlik "test hiç başlamadı"
    exit 0
fi

# =============================================================================
# 1/6 — k3s
# =============================================================================
heading "1/6 — k3s başlatılıyor"

# Portların "geri geldiğini" ölçebilmek için ÖNCE nasıl olduklarını yazıyoruz.
# k3s kalktıktan sonra ölçmek geç olurdu: Traefik çoktan araya girmiş olur ve
# testin sonunda neyle karşılaştıracağımızı bilemeyiz.
if command -v docker >/dev/null 2>&1 && container_running gateway; then
    TEMEL_HTTP="$(_kod_dis http "$GW_HTTP")"
    TEMEL_HTTPS="$(_kod_dis https "$GW_HTTPS")"
    log "test öncesi gateway cevapları: $GW_HTTP → $TEMEL_HTTP, $GW_HTTPS → $TEMEL_HTTPS"
fi

systemctl is-active --quiet k3s 2>/dev/null && K3S_ONCE_AKTIF=1

if ! command -v k3s >/dev/null 2>&1 && [ ! -x /usr/local/bin/k3s ]; then
    if [ "$KUR_K3S" != 1 ]; then
        atla_kalan "k3s kurulu değil. Kurulumu bu betiğe yaptırmak için: ./scripts/e2e/k8s.sh --yes --install-k3s   (elle: curl -sfL https://get.k3s.io | sh -)"
        atla_temizlik "k3s kurulu değil"
        exit 0
    fi
    log "k3s indiriliyor ve kuruluyor (get.k3s.io)…"
    if ! curl -sfL https://get.k3s.io -o "$TMPD/k3s-install.sh"; then
        atla_kalan "k3s kurulum betiği indirilemedi (ağ/proxy?)"
        atla_temizlik "k3s kurulamadı"
        exit 0
    fi
    if ! $SUDO sh "$TMPD/k3s-install.sh" >"$TMPD/k3s-install.log" 2>&1; then
        tail -5 "$TMPD/k3s-install.log" | sed 's/^/    /' >&2
        atla_kalan "k3s kurulumu başarısız (son satırlar yukarıda)"
        atla_temizlik "k3s kurulamadı"
        exit 0
    fi
    K3S_BIZ_KURDUK=1; K3S_BIZ_BASLATTIK=1
    ok "k3s kuruldu — test sonunda k3s-uninstall.sh ile kaldırılacak"
fi

if [ "$K3S_ONCE_AKTIF" = 1 ]; then
    warn "k3s bu betikten ÖNCE de çalışıyordu — sonunda KAPATILMAYACAK (sizin kurulumunuz)."
elif [ "$K3S_BIZ_KURDUK" != 1 ]; then
    log "k3s başlatılıyor (systemctl start k3s)…"
    if ! $SUDO systemctl start k3s >"$TMPD/start.log" 2>&1; then
        atla_kalan "systemctl start k3s başarısız: $(tail -2 "$TMPD/start.log" | tr '\n' ' ')"
        atla_temizlik "k3s başlatılamadı"
        exit 0
    fi
    K3S_BIZ_BASLATTIK=1
fi

# kubeconfig'i kopyalayıp kendimize ait yapıyoruz; yoksa her kubectl için sudo
# gerekir ve python tarafındaki controller kodu da cluster'a ulaşamaz.
if ! bekle "$K3S_TIMEOUT" "kubeconfig (/etc/rancher/k3s/k3s.yaml) bekleniyor" \
        $SUDO test -r /etc/rancher/k3s/k3s.yaml; then
    atla_kalan "k3s $K3S_TIMEOUT sn içinde kubeconfig üretmedi (bakın: journalctl -u k3s -n 50)"
    atla_temizlik "k3s ayağa kalkmadı"
    exit 0
fi
$SUDO cat /etc/rancher/k3s/k3s.yaml > "$TMPD/kubeconfig" 2>/dev/null
chmod 600 "$TMPD/kubeconfig"
export KUBECONFIG="$TMPD/kubeconfig"

# controller/app.py düz "kubectl" çağırır. k3s yalnızca `k3s kubectl` sunuyorsa
# ürünün kodu çalışmaz; PATH'e ince bir sarmalayıcı koyup gerçek arayüzü
# bozmadan yürütüyoruz.
if ! command -v kubectl >/dev/null 2>&1; then
    mkdir -p "$TMPD/bin"
    printf '#!/bin/sh\nexec k3s kubectl "$@"\n' > "$TMPD/bin/kubectl"
    chmod 755 "$TMPD/bin/kubectl"
    export PATH="$TMPD/bin:$PATH"
    log "kubectl yok — 'k3s kubectl' sarmalayıcısı kullanılıyor"
fi

if bekle "$K3S_TIMEOUT" "node'un Ready olması bekleniyor" \
        bash -c 'kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready'; then
    t_ok "$K_NODE" "$(kubectl get nodes --no-headers 2>/dev/null | head -1 | awk '{print $1, $2, $5}')"
else
    t_fail "$K_NODE" "node $K3S_TIMEOUT sn içinde Ready olmadı: $(kubectl get nodes 2>&1 | head -2 | tr '\n' ' ')"
    atla_kalan "k3s cluster'ı kullanılabilir değil"
    exit 0
fi

# Var olan bir cluster'a apply etmek, orada ÇALIŞAN motorları 0 replikaya
# indirirdi (manifestler replicas: 0 ile geliyor). Kullanıcının canlı
# veritabanını durdurmaktansa testi burada kesiyoruz.
if kc get ns "$NS" >/dev/null 2>&1; then
    calisan="$(kc -n "$NS" get statefulsets \
        -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas} {end}' 2>/dev/null \
        | tr ' ' '\n' | grep -v '=0$' | grep -v '^$' | tr '\n' ' ')"
    if [ -n "$calisan" ]; then
        atla_kalan "$NS isim alanında ZATEN çalışan motorlar var ($calisan); apply onları 0 replikaya indirirdi"
        exit 0
    fi
else
    NS_ONCEDEN_VARDI=0
fi

# =============================================================================
# 2/6 — manifestler
# =============================================================================
heading "2/6 — manifestler uygulanıyor (kubectl apply -k k8s/base)"

if kc apply -k k8s/base >"$TMPD/apply.log" 2>&1; then
    sts_sayisi="$(kc -n "$NS" get statefulsets -o name 2>/dev/null | grep -c .)"
    [ -n "$sts_sayisi" ] || sts_sayisi=0
    if kc get ns "$NS" >/dev/null 2>&1 && [ "$sts_sayisi" -eq "$DB_SAYISI" ]; then
        t_ok "$K_APPLY" "$sts_sayisi StatefulSet (katalogdaki veritabanı sayısı: $DB_SAYISI)"
    else
        t_fail "$K_APPLY" "katalogda $DB_SAYISI veritabanı var, cluster'da $sts_sayisi StatefulSet oluştu — manifestler katalogla ayrışmış (python3 scripts/gen-k8s.py ile yeniden üretin)"
    fi
else
    t_fail "$K_APPLY" "$(tail -5 "$TMPD/apply.log" | tr '\n' ' ')"
    atla_kalan "manifestler uygulanamadı"
    exit 0
fi

# Kapalı motor = HİÇ pod yok. Bir manifest yanlışlıkla replicas: 1 ile
# üretilirse apply anında 12 veritabanı birden açılır ve node belleği biter;
# kullanıcı hiçbir düğmeye basmadan sunucusunu kaybeder.
acik="$(kc -n "$NS" get statefulsets \
        -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas} {end}' 2>/dev/null \
        | tr ' ' '\n' | grep -v '=0$' | grep -v '^$' | tr '\n' ' ')"
if [ -z "$acik" ]; then
    t_ok "$K_REPLICAS" "$DB_SAYISI StatefulSet, toplam 0 pod"
else
    t_fail "$K_REPLICAS" "sıfır olmayan replika: $acik"
fi

# --- Secret ---------------------------------------------------------------
# kustomization.yaml Secret'ı İÇERMEZ (parola git'e girmesin diye). Secret
# olmadan pod CreateContainerConfigError ile açılmaz. Ürünün kendi üreticisini
# kullanıyoruz ama DEPOYU KİRLETMEDEN: catalog + gen-k8s.py + .env geçici bir
# ağaca kopyalanıp orada çalıştırılıyor, k8s/base'e dokunulmuyor.
mkdir -p "$TMPD/gen/scripts"
cp "$CATALOG" "$TMPD/gen/catalog.json" 2>/dev/null
cp "$STACK_ROOT/scripts/gen-k8s.py" "$TMPD/gen/scripts/gen-k8s.py" 2>/dev/null
cp "$ENV_FILE" "$TMPD/gen/.env" 2>/dev/null
chmod 600 "$TMPD/gen/.env" 2>/dev/null
gizli_dosya="$TMPD/gen/k8s/secrets/secret.yaml"
if python3 "$TMPD/gen/scripts/gen-k8s.py" --with-secrets >"$TMPD/gen.log" 2>&1 \
   && [ -f "$gizli_dosya" ] \
   && kc apply -f "$gizli_dosya" >>"$TMPD/gen.log" 2>&1; then
    kayitli="$(kc -n "$NS" get secret db-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null)"
    beklenen="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
    if [ -z "$beklenen" ]; then
        t_skip "$K_SECRET" ".env'de POSTGRES_PASSWORD/DB_PASSWORD yok — karşılaştıracak değer yok"
    elif [ "$kayitli" = "$beklenen" ]; then
        t_ok "$K_SECRET" "${#beklenen} karakterlik parola cluster'a taşındı"
    else
        t_fail "$K_SECRET" "Secret'taki parola .env'dekiyle aynı değil (uzunluk ${#kayitli} ↔ ${#beklenen}); pod 'password authentication failed' verir"
    fi
else
    t_fail "$K_SECRET" "Secret üretilemedi/uygulanamadı: $(tail -3 "$TMPD/gen.log" | tr '\n' ' ')"
fi

# --- RBAC ------------------------------------------------------------------
# docs/KUBERNETES.md "controller'ın K8s'teki tek yetkisi StatefulSet okumak ve
# ölçeklemek" diyor ve bunu Docker'daki docker.sock erişimine (host'ta root'a
# eşdeğer) karşı bir güvenlik üstünlüğü olarak sunuyor. İddiayı API'ye sorarak
# ölçüyoruz: Role'e kısayoldan "*" eklenirse bu iki kontrol ayrışır.
SA="system:serviceaccount:$NS:controller"
if kc auth can-i patch statefulsets --as="$SA" -n "$NS" -q 2>/dev/null \
   && kc auth can-i patch statefulsets/scale --as="$SA" -n "$NS" -q 2>/dev/null; then
    t_ok "$K_RBAC_OK"
else
    t_fail "$K_RBAC_OK" "controller ölçekleyemiyor: paneldeki 'Aktif Et' K8s'te forbidden verir (kubectl auth can-i patch statefulsets/scale --as=$SA -n $NS)"
fi
if ! kc auth can-i delete pods --as="$SA" -n "$NS" -q 2>/dev/null \
   && ! kc auth can-i get secrets --as="$SA" -n "$NS" -q 2>/dev/null; then
    t_ok "$K_RBAC_NO" "pod silme ve secret okuma reddediliyor"
else
    t_fail "$K_RBAC_NO" "controller'ın yetkisi belgelenenden GENİŞ (pod silme ya da secret okuma açık) — k8s/base/controller.yaml içindeki Role'ü daraltın"
fi

# --- controller pod'u ------------------------------------------------------
if [ "$CONTROLLER_TESTI" != 1 ]; then
    t_skip "$K_CTRL" "--no-controller verildi"
else
    ctrl_imaj="$(kc -n "$NS" get deploy controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    if [ -z "$ctrl_imaj" ]; then
        t_skip "$K_CTRL" "controller Deployment'ı bulunamadı"
    elif ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$ctrl_imaj" >/dev/null 2>&1; then
        t_skip "$K_CTRL" "$ctrl_imaj imajı bu makinede yok ve k3s onu bir kayıt defterinden çekemez; önce ./install.sh (imajı derler), sonra bu test"
    else
        log "$ctrl_imaj k3s containerd'sine aktarılıyor…"
        if docker save "$ctrl_imaj" 2>/dev/null | $SUDO k3s ctr images import - >"$TMPD/import.log" 2>&1; then
            kc -n "$NS" rollout restart deploy/controller >/dev/null 2>&1
            if timeout 260 kubectl -n "$NS" rollout status deploy/controller --timeout=220s >"$TMPD/ctrl.log" 2>&1; then
                t_ok "$K_CTRL" "readinessProbe httpGet /healthz cevap verdi"
            else
                t_fail "$K_CTRL" "controller Ready olmadı: $(kc -n "$NS" get pods -l app.kubernetes.io/name=controller --no-headers 2>/dev/null | head -2 | tr '\n' ' ')"
            fi
        else
            t_skip "$K_CTRL" "imaj containerd'ye aktarılamadı: $(tail -2 "$TMPD/import.log" | tr '\n' ' ')"
        fi
    fi
fi

# =============================================================================
# 3/6 — plan ve aktivasyon
# =============================================================================
heading "3/6 — $ENGINE aktif ediliyor (0 → 1 replika)"

# Kapasite: K8s'te EN BÜYÜK NODE'un allocatable belleği esas alınır (pod tek bir
# node'a sığmak zorunda). Bu okuma bozulursa controller sessizce host
# /proc/meminfo'suna düşer; çok node'lu bir cluster'da hiçbir node'a sığmayan
# bir limit üretip pod'u sonsuza dek Pending'de bırakır.
node_kb="$(kc get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
           | sed 's/Ki$//' | grep -E '^[0-9]+$' | sort -n | tail -1)"
node_mb=0
[ -n "$node_kb" ] && node_mb=$((node_kb / 1024))

BACKEND=kubernetes K8S_NAMESPACE="$NS" CATALOG_PATH="$CATALOG" STATE_DIR="$TMPD/state" \
CONTROLLER_DIR="$STACK_ROOT/controller" E2E_ENGINE="$ENGINE" E2E_OUT="$PLAN_DOSYA" \
PYTHONIOENCODING=utf-8 python3 - >"$TMPD/plan.log" 2>&1 <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["CONTROLLER_DIR"])
import app                                    # ← boyutlandırma ürünün kodundan
node = app._k8s_largest_node_mb()
total, avail = app.host_memory_mb()
p = app.plan_engine(os.environ["E2E_ENGINE"])
json.dump({"ok": bool(p.get("ok")), "reason": p.get("reason"),
           "limit_mb": p.get("limit_mb"), "tuning": p.get("tuning") or {},
           "node_mb": (node[0] if node else None), "capacity_mb": total},
          open(os.environ["E2E_OUT"], "w", encoding="utf-8"), ensure_ascii=False)
PY

plan_node="$(plan_alan node_mb)"
plan_cap="$(plan_alan capacity_mb)"
if [ -z "$plan_node" ] || [ "$node_mb" -eq 0 ]; then
    t_fail "$K_NODE_MB" "node allocatable belleği okunamadı (kubectl: '${node_kb:-boş}', controller: '${plan_node:-boş}') — controller sessizce /proc/meminfo'ya düşer. Plan günlüğü: $(tail -2 "$TMPD/plan.log" | tr '\n' ' ')"
elif [ "$plan_node" = "$node_mb" ] && [ "$plan_cap" = "$node_mb" ]; then
    t_ok "$K_NODE_MB" "en büyük node: $node_mb MB allocatable"
else
    t_fail "$K_NODE_MB" "kubectl $node_mb MB diyor, controller ${plan_node:-?} MB okudu, plan ${plan_cap:-?} MB kullandı — kapasite kaynağı ayrışmış"
fi

if [ "$(plan_alan ok)" = "True" ]; then
    LIMIT_MB="$(plan_alan limit_mb)"
    t_ok "$K_PLAN" "limit=$LIMIT_MB MB · shared_buffers=$(plan_alan tuning.POSTGRES_SHARED_BUFFERS) · max_connections=$(plan_alan tuning.POSTGRES_MAX_CONNECTIONS)"
else
    t_fail "$K_PLAN" "plan reddedildi: $(plan_alan reason) $(tail -3 "$TMPD/plan.log" | tr '\n' ' ')"
    atla_kalan "bellek planı üretilemediği için motor açılamadı"
    exit 0
fi

if ! k8s_scale 1 2>"$TMPD/scale.log"; then
    t_fail "$K_UP" "kubectl scale/set başarısız: $(tail -3 "$TMPD/scale.log" | tr '\n' ' ')"
    atla_kalan "motor açılamadı"
    exit 0
fi

# Container adı, kullanıcı/veritabanı adı ve PVC adı UYGULANMIŞ manifestten
# okunur — betiğe sabit yazılsaydı manifest değişince test yanlış yere bakardı.
KAP="$(kc -n "$NS" get sts "$STS" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null)"
[ -n "$KAP" ] || KAP="$ENGINE"
_u="$(kc -n "$NS" get sts "$STS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_USER")].value}' 2>/dev/null)"
[ -n "$_u" ] && PGUSER="$_u"
_d="$(kc -n "$NS" get sts "$STS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="POSTGRES_DB")].value}' 2>/dev/null)"
[ -n "$_d" ] && PGDB="$_d"
_v="$(kc -n "$NS" get sts "$STS" -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null)"
[ -n "$_v" ] || _v="data"
PVC="${_v}-${POD}"

if timeout $((POD_TIMEOUT + 30)) kubectl -n "$NS" rollout status statefulset/"$STS" \
        --timeout="${POD_TIMEOUT}s" >"$TMPD/rollout.log" 2>&1 \
   && bekle 120 "$POD içinde PostgreSQL'in bağlantı kabul etmesi bekleniyor" pg_hazir; then
    t_ok "$K_UP" "$(kc -n "$NS" get pod "$POD" --no-headers 2>/dev/null | awk '{print $2, $3, $5}')"
else
    t_fail "$K_UP" "pod $POD_TIMEOUT sn içinde hazır olmadı.
durum:   $(kc -n "$NS" get pod "$POD" --no-headers 2>/dev/null | tr -s ' ')
olaylar: $(kc -n "$NS" get events --field-selector involvedObject.name="$POD" --sort-by=.lastTimestamp -o jsonpath='{range .items[-3:]}{.reason}: {.message}{"; "}{end}' 2>/dev/null)"
    atla_kalan "pod hazır olmadığı için içine bakılamadı"
    exit 0
fi

# =============================================================================
# 4/6 — hesaplanan ayarlar POD İÇİNDE gerçekten uygulandı mı?
# =============================================================================
heading "4/6 — ayarlar pod içinde ölçülüyor, veri yazılıp okunuyor"

pod_limit="$(kc -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)"
if [ "$pod_limit" = "${LIMIT_MB}Mi" ]; then
    t_ok "$K_LIMIT" "$pod_limit"
else
    t_fail "$K_LIMIT" "plan $LIMIT_MB MB dedi, pod'un limiti '${pod_limit:-yok}' — 'kubectl set resources' yanlış container'a gitmiş olabilir (--containers $KAP)"
fi

# ASIL KONTROL. `kubectl set env` her zaman başarılı olur; manifestte args yoksa
# ya da $(VAR) çözülmezse motor VARSAYILANLA çalışır ve hiçbir yerde hata
# görünmez — pod bile "Running" der. Bu yüzden değeri motorun KENDİSİNE soruyoruz.
bek_sb="$(plan_alan tuning.POSTGRES_SHARED_BUFFERS)"
bul_sb="$(pg_deger 'SHOW shared_buffers')"
if [ -z "$bul_sb" ]; then
    t_fail "$K_SB" "SHOW shared_buffers cevap vermedi (psql pod içinde çalışmadı)"
elif esit_mi "$bek_sb" "$bul_sb"; then
    t_ok "$K_SB" "plan $bek_sb · motor $bul_sb"
else
    t_fail "$K_SB" "controller $bek_sb hesapladı ama motor $bul_sb ile çalışıyor: manifestte args/\$(POSTGRES_SHARED_BUFFERS) eksik ya da 'set env' pod'a yansımamış. Ürünün 'sunucuya göre ayarlıyorum' vaadi sessizce boşa çıkar."
fi

bek_ec="$(plan_alan tuning.POSTGRES_EFFECTIVE_CACHE)"
bek_mc="$(plan_alan tuning.POSTGRES_MAX_CONNECTIONS)"
bul_ec="$(pg_deger 'SHOW effective_cache_size')"
bul_mc="$(pg_deger 'SHOW max_connections')"
if esit_mi "$bek_ec" "$bul_ec" && [ -n "$bek_mc" ] && [ "$bek_mc" = "$bul_mc" ]; then
    t_ok "$K_DIGER" "effective_cache_size=$bul_ec · max_connections=$bul_mc"
else
    t_fail "$K_DIGER" "effective_cache_size: plan $bek_ec / motor ${bul_ec:-yok}; max_connections: plan $bek_mc / motor ${bul_mc:-yok}"
fi

# --- veri yaz / oku --------------------------------------------------------
yaz_cikti="$(pg_calistir "CREATE TABLE IF NOT EXISTS $TABLO (jeton text PRIMARY KEY, yazildi timestamptz DEFAULT now()); INSERT INTO $TABLO (jeton) VALUES ('$JETON') ON CONFLICT DO NOTHING;")"
okunan="$(pg_deger "SELECT jeton FROM $TABLO WHERE jeton = '$JETON'")"
if [ "$okunan" = "$JETON" ]; then
    t_ok "$K_YAZ" "jeton: $JETON"
else
    t_fail "$K_YAZ" "yazılan satır geri okunamadı (okunan: '${okunan:-boş}'); psql: $(printf '%s' "$yaz_cikti" | tail -2 | tr '\n' ' ')"
fi

# Service + cluster DNS gerçekten çalışıyor mu? `kubectl exec` bunu ölçmez:
# uygulamalar motora exec ile değil, Service adıyla bağlanır. Service'in
# selector'ı ya da portu yanlışsa exec'li testler yeşil yanarken gerçek
# istemciler hiç bağlanamaz.
imaj="$(kc -n "$NS" get sts "$STS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
pgpass="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
if [ -z "$imaj" ] || [ -z "$pgpass" ]; then
    t_skip "$K_SVC" "istemci pod'u için imaj ('${imaj:-yok}') ya da parola bilinmiyor"
else
    kc -n "$NS" delete pod "$ISTEMCI_POD" --ignore-not-found --now >/dev/null 2>&1
    svc_cikti="$(timeout 240 kubectl -n "$NS" run "$ISTEMCI_POD" --rm --restart=Never \
        --image="$imaj" --image-pull-policy=IfNotPresent --pod-running-timeout=180s \
        --env="PGPASSWORD=$pgpass" --quiet --attach --command -- \
        psql -h "$STS.$NS.svc.cluster.local" -p "$K8S_PORT" -U "$PGUSER" -d "$PGDB" \
        -tAc "SELECT jeton FROM $TABLO WHERE jeton = '$JETON'" 2>&1)"
    if printf '%s' "$svc_cikti" | grep -q "$JETON"; then
        t_ok "$K_SVC" "$STS.$NS.svc.cluster.local:$K8S_PORT üzerinden okundu"
    else
        t_fail "$K_SVC" "Service üzerinden okunamadı: $(printf '%s' "$svc_cikti" | tail -3 | tr '\n' ' ')"
    fi
fi

# =============================================================================
# 5/6 — kapatma, PVC ve kalıcılık
# =============================================================================
heading "5/6 — $ENGINE durduruluyor (1 → 0) ve veri kalıcılığı ölçülüyor"

if k8s_scale 0 2>"$TMPD/scale0.log" \
   && bekle 180 "$POD pod'unun silinmesi bekleniyor" \
        bash -c "! kubectl -n '$NS' get pod '$POD' >/dev/null 2>&1"; then
    t_ok "$K_DOWN" "pod yok, StatefulSet replicas=0"
else
    t_fail "$K_DOWN" "pod 180 sn içinde kaybolmadı: $(kc -n "$NS" get pod "$POD" --no-headers 2>/dev/null | tr -s ' ') $(tail -2 "$TMPD/scale0.log" | tr '\n' ' ')"
fi

pvc_durum="$(kc -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null)"
if [ "$pvc_durum" = "Bound" ]; then
    t_ok "$K_PVC" "$PVC: Bound ($(kc -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null))"
else
    t_fail "$K_PVC" "$PVC durumu '${pvc_durum:-yok}' — motoru kapatmak veri diskini de silmiş olur, 'Durdur' düğmesi veri kaybına dönüşür"
fi

# PVC'nin var olması veriyi TUTTUĞU anlamına gelmez: yanlış mountPath, hacmin
# dışında kalan bir PGDATA ya da emptyDir'e düşmüş bir hacim tam olarak aynı
# görüntüyü verir. Tek kanıt, yeniden açıp satırı geri okumaktır.
if k8s_scale 1 2>>"$TMPD/scale.log" \
   && timeout $((POD_TIMEOUT + 30)) kubectl -n "$NS" rollout status statefulset/"$STS" \
        --timeout="${POD_TIMEOUT}s" >>"$TMPD/rollout.log" 2>&1 \
   && bekle 120 "$POD yeniden açıldı, bağlantı bekleniyor" pg_hazir; then
    tekrar="$(pg_deger "SELECT jeton FROM $TABLO WHERE jeton = '$JETON'")"
    if [ "$tekrar" = "$JETON" ]; then
        t_ok "$K_KALICI" "pod yeniden yaratıldı, satır yerinde"
    else
        t_fail "$K_KALICI" "yeniden açılan pod'da satır YOK (okunan: '${tekrar:-boş}') — veri PVC'de değil, pod'un geçici katmanındaymış"
    fi
else
    t_fail "$K_KALICI" "motor yeniden açılamadı: $(tail -3 "$TMPD/rollout.log" | tr '\n' ' ')"
fi

# 6/6 (temizlik + port kontrolleri) EXIT tuzağındaki temizle() içinde çalışır;
# betik buradan önce hangi satırda biterse bitsin o adım atlanmaz.
exit 0
