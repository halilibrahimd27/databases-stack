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
# (env'e ne yazdığımızı değil). Ama bir uyarı: plan tam olarak manifestteki
# STATİK varsayılana denk gelirse (512MB / 200), ayar hiç uygulanmasa da aynı
# değer okunur. O yüzden betik manifest varsayılanını da okur ve kontrolün o
# koşuda AYIRT EDİCİ olup olmadığını söyler — ayırt edici değilse GEÇTİ yazmaz.
#
# SONUÇ TÜRLERİ scripts/e2e/lib.sh'ten gelir: t_ok / t_fail / t_skip ve
# t_unknown. Sonuncusu "ölçemedik" demektir (kubectl düştü, psql cevap vermedi,
# iptables okunamadı) ve BAŞARISIZ sayılır: ölçüm aracı bozulduğunda yeşil
# yazmak, bir test paketinin yapabileceği en kötü şeydir.
#
# DİKKAT: aynı host'ta k3s + Docker yığını 80/443 için ÇAKIŞIR. k3s'in
# Traefik'i iptables nat/PREROUTING'de DOCKER zincirinden ÖNCE DNAT kuralı
# koyar; paket gateway'e hiç ulaşmaz (docs/KUBERNETES.md). Bu yüzden betik
# önce uyarır ve onay ister, sonunda da temizleyip portların döndüğünü ÖLÇER.
# Temizlik EXIT tuzağına bağlıdır ve Ctrl-C ile kesilemez: yarıda kalan bir
# temizlik kullanıcının panelini 80/443'te kapalı bırakır.
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
# shellcheck source=lib.sh
source "$_bu_dizin/lib.sh"      # t_ok / t_fail / t_skip / t_unknown + çıkış kodu
E2E_SUITE="k8s"
cd "$STACK_ROOT" || { echo "yığın köküne geçilemedi"; exit 1; }
load_env

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
            # Başlık bloğunu satır numarasıyla kesmiyoruz: başlığa bir satır
            # eklendiğinde yardım metni sessizce yarıda kalırdı.
            awk 'NR<3 {next}
                 /^#/  {sub(/^# ?/,""); if ($0 !~ /^=+$/) print; next}
                       {exit}' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "bilinmeyen argüman: $arg  (yardım: --help)" ;;
    esac
done

# =============================================================================
# TEST ÇERÇEVESİ — sayaçlar ve çıkış kodu lib.sh'te
# =============================================================================
# Buradaki dört sarmalayıcı sayaç TUTMAZ; lib.sh'in t_* fonksiyonlarını çağırır.
# İki şey ekliyorlar:
#   1. _RAPOR defteri — lib.sh GEÇEN kontrolleri adıyla listelemediği için
#      "bu kontrol zaten raporlandı mı?" sorusunu başka türlü soramıyoruz.
#      atla_kalan/atla_temizlik buna bakar; aynı ad iki kez raporlanırsa
#      toplam sayı şişer ve "kaç kontrol çalışmadı" gizlenir.
#   2. kanıt satırı — lib.sh'in t_ok'u ikinci argümanı basmıyor. "GEÇTİ" demek
#      yetmez; NE ölçtüğümüz (bulunan değer) görünmezse okuyan kişi kontrolün
#      gerçekten bir şey ölçtüğünü doğrulayamaz.
declare -A _RAPOR=()
raporlandi() { [ -n "${_RAPOR[$1]:-}" ]; }

k_ok()      { raporlandi "$1" && return 0; _RAPOR["$1"]=1; t_ok "$1"
              [ -n "${2:-}" ] && t_info "$2"; return 0; }
k_fail()    { raporlandi "$1" && return 0; _RAPOR["$1"]=1; t_fail    "$1" "${2:-}"; }
k_skip()    { raporlandi "$1" && return 0; _RAPOR["$1"]=1; t_skip    "$1" "${2:-}"; }
k_unknown() { raporlandi "$1" && return 0; _RAPOR["$1"]=1; t_unknown "$1" "${2:-}"; }

# --- kontrol adları --------------------------------------------------------
# Adlar tek yerde duruyor: kontrol hem çalıştırılırken hem de "çalıştırılamadı"
# diye atlanırken aynı metni kullansın, böylece toplam sayı her koşuda sabit
# kalır ve "kaç test çalışmadı" gizlenemez.
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
K_GERI="test için açılan motor koşu sonunda geri kapatıldı (cluster'da kalıntı yok)"
K_KILL="k3s-killall.sh + systemctl disable sonrası k3s kapalı ve açılışta gelmeyecek"
K_IPT="nat/PREROUTING'de KUBE-SERVICES / CNI-HOSTPORT-DNAT kuralı kalmadı"
K_HTTP="Docker yığınının 80 portu geri geldi (cevabı yine gateway veriyor)"
K_HTTPS="Docker yığınının 443 portu geri geldi (panel yeniden açılıyor)"

SIRA_MOTOR=("$K_NODE" "$K_APPLY" "$K_REPLICAS" "$K_SECRET" "$K_RBAC_OK" "$K_RBAC_NO"
            "$K_CTRL" "$K_NODE_MB" "$K_PLAN" "$K_UP" "$K_LIMIT" "$K_SB" "$K_DIGER"
            "$K_YAZ" "$K_SVC" "$K_DOWN" "$K_PVC" "$K_KALICI")
SIRA_TEMIZ=("$K_GERI" "$K_KILL" "$K_IPT" "$K_HTTP" "$K_HTTPS")

# Ön koşul sağlanmadığında geri kalan kontroller SESSİZ KALMAZ: hepsi tek tek
# "atlandı + sebep" olarak raporlanır.
atla_kalan() {
    local sebep="$1" ad
    for ad in "${SIRA_MOTOR[@]}"; do k_skip "$ad" "$sebep"; done
}
atla_temizlik() {
    local sebep="$1" ad
    for ad in "${SIRA_TEMIZ[@]}"; do k_skip "$ad" "$sebep"; done
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
require_cmd python3 curl timeout
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

# DB_SAYISI apply kontrolünün BEKLENEN değeri. Boş kalırsa eski sürüm 0'a
# düşüyordu ve cluster'da hiç StatefulSet olmasa bile "0 = 0" diye GEÇTİ
# yazıyordu: ölçüm aracı (python/katalog) bozulunca kontrol yeşile dönüyordu.
DB_SAYISI="$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print(sum(1 for e in c["engines"] if e.get("kind","database")=="database"))' "$CATALOG" 2>/dev/null)" \
    || die "catalog.json okunamadı — kaç veritabanı beklediğimi bilmeden apply'ı ölçemem."
case "$DB_SAYISI" in
    ''|*[!0-9]*) die "catalog.json'dan veritabanı sayısı okunamadı ('$DB_SAYISI')." ;;
esac
[ "$DB_SAYISI" -gt 0 ] || die "catalog.json'da hiç veritabanı motoru yok — ölçülecek bir şey kalmıyor."

# Geçici dizin ANCAK buradan sonra: yukarıdaki die'lar arkalarında dizin
# bırakmasın (EXIT tuzağı henüz kurulmadı, kimse silmezdi).
TMPD="$(mktemp -d /tmp/e2e-k8s.XXXXXX)" || die "geçici dizin açılamadı"
chmod 700 "$TMPD"

GW_HTTP="${GATEWAY_HTTP_PORT:-80}"
GW_HTTPS="${GATEWAY_HTTPS_PORT:-443}"

# durum bayrakları (temizlik bunlara bakar)
K3S_ONCE_AKTIF=0; K3S_BIZ_KURDUK=0; K3S_BIZ_BASLATTIK=0
# BIZ_ACTIK: motoru BİZ mi açtık? Temizlikteki `scale 0` ve `DROP TABLE` yalnız
# buna bakar. Eski sürümde koşulsuzdu: güvenlik freni "kullanıcının çalışan
# motorlarına dokunma" deyip çıkıyor, ardından EXIT tuzağı tam da o motorları
# 0 replikaya indiriyordu — betik önlemeyi vaat ettiği kesintiyi kendi yapıyordu.
BIZ_ACTIK=0; BIZ_APPLY_ETTIK=0; ISTEMCI_YARATILDI=0; YAZILDI=0
TEMEL_HTTP="000 -"; TEMEL_HTTPS="000 -"
NS_ONCEDEN_VARDI=1; TEMIZLENDI=0
PLAN_DOSYA="$TMPD/plan.json"
LIMIT_MB=""; KAP="$ENGINE"; PGUSER="root"; PGDB="defaultdb"; PVC=""
VARSAYILAN_LIMIT=""; VARSAYILAN_SB=""; VARSAYILAN_EC=""; VARSAYILAN_MC=""
VARSAYILAN_OKUNDU=0
KC_HATA=""; PG_HATA=""; PG_CIKTI=""; SON=""; NODE_OZET=""

# Hiçbir kubectl çağrısı sonsuza kadar asılı kalmasın (API sunucusu ölürse
# betik dakikalarca sessiz bekler ve temizlik gecikir).
kc() { timeout "$KUBECTL_TIMEOUT" kubectl "$@"; }

# kubectl'den DEĞER okumanın tek doğru yolu. `x="$(kc ... 2>/dev/null)"` kalıbı
# çıkış kodunu yutar ve "sorgu düştü"yü "cevap boş" ile aynı şeye çevirir;
# denetimde güvenlik freninin ve K_REPLICAS'ın fail-open olmasının sebebi
# tam olarak buydu. Burada çıktı ile rc ayrı ayrı geri veriliyor.
kc_al() {   # kc_al <değişken adı> <kubectl argümanları...> → rc: kubectl'in rc'si
    local __v="$1"; shift
    local __o __r
    __o="$(kc "$@" 2>"$TMPD/kc.err")"; __r=$?
    KC_HATA="$(head -c 400 "$TMPD/kc.err" 2>/dev/null | tr '\n' ' ')"
    printf -v "$__v" '%s' "$__o"
    return $__r
}

# =============================================================================
# YARDIMCILAR — motorla ve ürünün kontrol düzlemiyle konuşma
# =============================================================================
# pg_deger: rc 0 → ÖLÇTÜK (değer stdout'ta, boş olabilir: satır yok demektir)
#           rc 1 → ÖLÇEMEDİK (exec/psql düştü). Çağıranlar bu ikisini
#           karıştırmamalı: "psql çalışmadı" ile "değer boş" aynı şey değil.
pg_deger() {
    local ham rc
    ham="$(kc -n "$NS" exec "$POD" -c "$KAP" -- \
        psql -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 -tAc "$1" 2>"$TMPD/psql.err")"; rc=$?
    PG_HATA="$(head -3 "$TMPD/psql.err" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    [ "$rc" -eq 0 ] || return 1
    ham="$(printf '%s' "$ham" | tr -d '\r' | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    printf '%s' "$ham"
    return 0
}
pg_calistir() {   # rc = psql'in rc'si; birleşik çıktı PG_CIKTI'da (tanı için)
    local rc
    PG_CIKTI="$(kc -n "$NS" exec "$POD" -c "$KAP" -- \
        psql -U "$PGUSER" -d "$PGDB" -v ON_ERROR_STOP=1 -tAc "$1" 2>&1)"; rc=$?
    PG_CIKTI="$(printf '%s' "$PG_CIKTI" | tr -d '\r')"
    return $rc
}
# PostgreSQL init sırasında geçici sunucu listen_addresses='' ile açılır; asıl
# sunucu '*' ile. Bu ayrım olmadan pg_isready init aşamasında da "hazır" der ve
# test yarı kurulmuş bir veritabanına soru sormaya başlar (kararsız KALDI'lar).
pg_hazir() { local v; v="$(pg_deger 'SHOW listen_addresses')" || return 1; [ "$v" = "*" ]; }

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

# Kontrol o koşuda BİR ŞEY KANITLIYOR MU? Plan değeri manifestteki statik
# varsayılana birebir eşitse, `kubectl set env` hiç işlemese de motor aynı
# değeri raporlar — böyle bir GEÇTİ ölçüm değil, tesadüftür.
ayirt_edici_mi() {   # ayirt_edici_mi <plan değeri> <manifest varsayılanı>
    [ -n "${2:-}" ] || return 0        # manifestte statik varsayılan yok → eşleşme kanıttır
    esit_mi "$1" "$2" && return 1      # eşit → ayırt edici DEĞİL
    return 0
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

# Pod GERÇEKTEN yok mu? `! kubectl get pod` kalıbı kubectl'in HER hatasını
# "pod silinmiş" diye okur (API düşerse de doğru çıkar) — bu, K_DOWN'ı ölçüm
# aracı bozulduğunda yeşile çeviren klasik kalıptır. NotFound'u ayırıyoruz.
pod_yok_mu() {
    local o r
    o="$(kc -n "$NS" get pod "$POD" -o name 2>"$TMPD/podyok.err")"; r=$?
    if [ "$r" -eq 0 ]; then [ -z "$o" ]; return $?; fi
    grep -qiE 'not ?found' "$TMPD/podyok.err" 2>/dev/null && return 0
    return 1        # kubectl düştü: "yok" demek DEĞİL
}

# =============================================================================
# TEMİZLİK — bu adım atlanırsa kullanıcının paneli çalışmaz hâlde kalır.
# Bu yüzden EXIT tuzağına bağlı: betik nerede biterse bitsin çalışır.
# =============================================================================
# Dışarıdan tek ölçüm: HTTP kodu + cevabı KİMİN verdiği. Yalnız koda bakmak
# yetmez, çünkü k3s'in Traefik'i de 404 döner; gateway'in 404'üyle aynı kodda
# buluşurlarsa "port geri geldi" sessizce yeşil olur. İmza için Server başlığını
# kullanıyoruz: nginx `server_tokens off` ile bile "nginx" gönderir, Traefik hiç
# Server başlığı göndermez ve gövdesi "404 page not found"tur.
#
# NOT: eski sürüm ikincil ölçütü gateway'in İÇİNDEN curl ile alıyordu; ama
# nginx:1.27-alpine imajında curl YOK, dolayısıyla o ölçüt her koşuda ölüydü ve
# rapor satırı "gateway içinden 000" yazarak ölçülmüş izlenimi veriyordu.
_dis_olc() {   # _dis_olc <şema> <port> → stdout "<kod> <imza>"
    local sema="$1" port="$2" kf="" kod imza
    [ "$sema" = "https" ] && kf="-k"
    : >"$TMPD/dis.hdr"; : >"$TMPD/dis.body"
    # curl bağlanamayınca da '%{http_code}' ile "000" basar; `|| echo 000`
    # yazmak "000000" gibi bozuk bir değer üretirdi (kod yalnız yan yana eklenirdi).
    kod="$(curl -s $kf -o "$TMPD/dis.body" -D "$TMPD/dis.hdr" -w '%{http_code}' \
           --max-time 5 "$sema://127.0.0.1:$port/" 2>/dev/null)"
    [ -n "$kod" ] || kod="000"
    imza="$(grep -i '^server:' "$TMPD/dis.hdr" 2>/dev/null | tail -1 \
            | sed 's/^[^:]*:[[:space:]]*//; s#/.*##' | tr -d '\r' \
            | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [ -z "$imza" ]; then
        if grep -qF '404 page not found' "$TMPD/dis.body" 2>/dev/null; then
            imza="traefik"
        elif [ "$kod" = "000" ]; then
            imza="-"
        else
            imza="imzasiz"
        fi
    fi
    printf '%s %s' "$kod" "$imza"
}

_port_geri_geldi_mi() {   # <kontrol adı> <şema> <port> "<kod imza>"
    local ad="$1" sema="$2" port="$3" temel="$4"
    local temel_kod="${temel%% *}" temel_imza="${temel##* }"

    if ! command -v docker >/dev/null 2>&1; then
        k_skip "$ad" "docker komutu yok"; return 0
    fi
    if ! docker ps >/dev/null 2>&1; then
        # Ölçüm aracı bozuk: gateway çalışıyor da olabilir, çalışmıyor da.
        k_unknown "$ad" "docker daemon cevap vermiyor; $port portunun gateway'e döndüğünü ölçemiyorum"
        return 0
    fi
    container_running gateway || {
        k_skip "$ad" "gateway container'ı çalışmıyor — Docker yığını kurulu değil ya da kapalı"; return 0; }
    if [ "$temel_kod" = "000" ]; then
        k_skip "$ad" "$port portu test BAŞLAMADAN da dışarıdan cevap vermiyordu (kod 000) — geri geldiğini ölçecek bir başlangıç değeri yok"
        return 0
    fi
    if [ "$temel_imza" = "traefik" ]; then
        k_skip "$ad" "test BAŞLAMADAN önce de $port portuna Traefik cevap veriyordu (kod $temel_kod) — 'gateway'e geri döndü' diye karşılaştıracak sağlam bir başlangıç yok. Önce: sudo /usr/local/bin/k3s-killall.sh && docker restart gateway"
        return 0
    fi

    SON=""
    _olc() { SON="$(_dis_olc "$sema" "$port")"; [ "$SON" = "$temel" ]; }

    # iptables kuralları hemen düşmeyebilir; kısa bir pencere tanıyoruz.
    if bekle 30 "$port portunun gateway'e dönmesi bekleniyor" _olc; then
        k_ok "$ad" "dışarıdan '$SON' — test öncesiyle aynı (kod + Server imzası)"
        return 0
    fi
    # docs/KUBERNETES.md'nin temizlik adımının son maddesi: gateway'i yenile.
    log "port dönmedi; belgedeki adım deneniyor: docker restart gateway"
    docker restart gateway >/dev/null 2>&1 || warn "docker restart gateway başarısız oldu"
    if bekle 60 "gateway yeniden başlatıldı, $port portu bekleniyor" _olc; then
        k_ok "$ad" "gateway yeniden başlatıldıktan sonra döndü ('$SON')"
    else
        k_fail "$ad" "test öncesi '$temel' gelirken şimdi '$SON' geliyor — $port hâlâ başka bir yere gidiyor (imza 'traefik' ise DNAT kuralı duruyor demektir).
Kimin dinlediği:  sudo ss -lntp | grep ':$port '
Yönlendirme:      sudo iptables -t nat -L PREROUTING -n"
    fi
    return 0
}

_k3s_kapali_mi_dogrula() {
    local durum aktif surec otomatik surec_olculdu=1
    durum="$(systemctl is-active k3s 2>/dev/null)"
    case "${durum:-}" in
        active)                                    aktif="evet" ;;
        inactive|failed|deactivating|activating|unknown) aktif="hayir" ;;
        # Boş cevap = systemctl'in kendisi çalışmadı (dbus yok, izin yok).
        # Silinmiş bir birim için bile "inactive" basılır; boşluğu "kapalı"
        # saymak, k3s ayaktayken K_KILL'i yeşile çeviren fail-open olurdu.
        *)                                         aktif="bilinmiyor" ;;
    esac
    # `systemctl is-active` boş/anlaşılmaz cevap verirse k3s'in durumunu
    # BİLMİYORUZ demektir; "kapalı" varsaymak tam da sessiz-yeşil kalıbıdır.
    if command -v pgrep >/dev/null 2>&1; then
        # pgrep: 0 = eşleşme var, 1 = eşleşme yok, ≥2 = HATA. Hatayı "süreç yok"
        # saymak, k3s ayakta dururken K_KILL'i yeşile çevirirdi.
        local surec_ham pg_rc
        surec_ham="$(pgrep -f '/usr/local/bin/k3s server' 2>/dev/null)"; pg_rc=$?
        [ "$pg_rc" -le 1 ] || surec_olculdu=0
        surec="$(printf '%s' "$surec_ham" | head -3 | tr '\n' ' ')"
    else
        surec=""; surec_olculdu=0
    fi
    otomatik="$(systemctl is-enabled k3s 2>/dev/null || true)"

    if [ "$aktif" = "bilinmiyor" ]; then
        k_unknown "$K_KILL" "systemctl is-active k3s anlaşılmaz cevap verdi ('$durum') — k3s'in kapandığını doğrulayamıyorum.
Elle: sudo /usr/local/bin/k3s-killall.sh && sudo systemctl disable --now k3s"
    elif [ "$aktif" = "evet" ] || [ -n "$surec" ]; then
        k_fail "$K_KILL" "k3s hâlâ ayakta (is-active=$durum, süreçler: ${surec:-yok}).
Elle: sudo /usr/local/bin/k3s-killall.sh && sudo systemctl disable --now k3s"
    elif [ "$surec_olculdu" != 1 ]; then
        k_unknown "$K_KILL" "servis '$durum' görünüyor ama pgrep yok: 'k3s server' sürecinin gerçekten öldüğünü ölçemedim (systemctl stop pod'ları ve iptables kurallarını bırakabiliyor)"
    elif [ "$otomatik" = "enabled" ]; then
        k_fail "$K_KILL" "k3s durdu ama hâlâ 'enabled': makine yeniden başlayınca 80/443'ü tekrar kapar.
Elle: sudo systemctl disable k3s"
    else
        k_ok "$K_KILL" "servis durumu: $durum / ${otomatik:-birim yok}, çalışan 'k3s server' süreci yok"
    fi

    # Asıl arıza buradaydı: k3s dursa bile nat/PREROUTING'deki KUBE-SERVICES /
    # CNI-HOSTPORT-DNAT kuralları DOCKER zincirinden önce gelir ve 80/443'ü
    # kaçırmaya devam eder. `systemctl stop k3s` bu kuralları KALDIRMAZ.
    if ! command -v iptables >/dev/null 2>&1; then
        k_skip "$K_IPT" "iptables komutu yok — kuralları göremiyorum"
    else
        local ipt_out ipt_rc kalan
        # `$SUDO iptables ... 2>/dev/null | grep -c` boru hattı rc'yi yutuyordu:
        # iptables hiç çalışmasa da (sudo parolası, izin, nft/legacy uyuşmazlığı)
        # sayım 0 çıkıyor ve "PREROUTING temiz" GEÇTİ'si basılıyordu. docs/
        # KUBERNETES.md'deki gerçek 80/443 kaçırma olayının tek koruması bu.
        ipt_out="$($SUDO iptables -t nat -S PREROUTING 2>&1)"; ipt_rc=$?
        if [ "$ipt_rc" -ne 0 ]; then
            k_unknown "$K_IPT" "iptables okunamadı (rc=$ipt_rc): $(printf '%s' "$ipt_out" | head -2 | tr '\n' ' ')
80/443'ü kaçıran DNAT kuralı KALMIŞ OLABİLİR; elle bakın: sudo iptables -t nat -L PREROUTING -n"
        elif [ -z "$ipt_out" ]; then
            k_unknown "$K_IPT" "iptables boş çıktı verdi (en az '-P PREROUTING ACCEPT' beklenirdi) — sayım güvenilir değil"
        else
            kalan="$(printf '%s\n' "$ipt_out" | grep -cE 'KUBE-SERVICES|CNI-HOSTPORT-DNAT')"
            case "$kalan" in ''|*[!0-9]*) kalan=0 ;; esac
            if [ "$kalan" -eq 0 ]; then
                k_ok "$K_IPT" "PREROUTING temiz ($(printf '%s\n' "$ipt_out" | grep -c .) kural okundu)"
            else
                k_fail "$K_IPT" "$kalan kural kaldı; 80/443 hâlâ Traefik'e gidiyor olabilir.
Görmek için: sudo iptables -t nat -L PREROUTING -n"
            fi
        fi
    fi

    _port_geri_geldi_mi "$K_HTTP"  "http"  "$GW_HTTP"  "$TEMEL_HTTP"
    _port_geri_geldi_mi "$K_HTTPS" "https" "$GW_HTTPS" "$TEMEL_HTTPS"
}

temizle() {
    [ "$TEMIZLENDI" = 1 ] && return 0
    TEMIZLENDI=1
    heading "6/6 — temizlik ve Docker yığınının geri gelmesi"

    # --- (a) cluster'da BİZİM bıraktıklarımız ------------------------------
    # `kubectl version` API'ye ulaşamasa da 0 dönebilir; /readyz dönmüyorsa
    # cluster gerçekten yok demektir — boşuna 60 sn kubectl beklemeyelim.
    local ulasilir=0
    if [ -n "${KUBECONFIG:-}" ] && kc get --raw /readyz >/dev/null 2>&1; then
        ulasilir=1
    fi

    if [ "$BIZ_ACTIK" != 1 ]; then
        # Kullanıcının motoruna DOKUNMUYORUZ. Güvenlik freni "çalışan motor var,
        # apply etmiyorum" dediğinde eski sürüm yine de scale 0 + DROP TABLE
        # çalıştırıyordu; yani önlemeyi vaat ettiği kesintiyi kendisi yapıyordu.
        k_skip "$K_GERI" "bu koşu hiçbir motor açmadı — cluster'da geri alınacak bir şey yok"
    elif [ "$ulasilir" != 1 ]; then
        k_unknown "$K_GERI" "cluster'a ulaşılamadı; açtığımız $STS'in kapandığını DOĞRULAYAMIYORUM — pod çalışıyor olabilir.
Elle: kubectl -n $NS scale statefulset $STS --replicas 0"
    else
        # Kendi yarattığımız tabloyu bırakmayız: betik iki kez üst üste
        # çalıştırılabilir olmalı ve kullanıcının verisinde iz kalmamalı.
        if [ "$YAZILDI" = 1 ] && kc -n "$NS" get pod "$POD" >/dev/null 2>&1; then
            if pg_calistir "DROP TABLE IF EXISTS $TABLO" >/dev/null 2>&1; then
                log "test tablosu ($TABLO) silindi"
            else
                warn "test tablosu ($TABLO) SİLİNEMEDİ; elle: kubectl -n $NS exec $POD -- psql -U $PGUSER -d $PGDB -c 'DROP TABLE $TABLO'"
            fi
        fi
        [ "$ISTEMCI_YARATILDI" = 1 ] && \
            kc -n "$NS" delete pod "$ISTEMCI_POD" --ignore-not-found --now >/dev/null 2>&1

        # Ölçekleme BAŞARISIZ olursa sessiz kalmak, kullanıcının cluster'ında
        # bizim açtığımız pod'u çalışır bırakmak demektir. Bu yüzden sonucu
        # komutun rc'sine değil, StatefulSet'in gerçek replicas değerine soruyoruz.
        k8s_scale 0 >"$TMPD/temizlik-scale.log" 2>&1 || \
            warn "kapatma komutu hata verdi: $(tail -2 "$TMPD/temizlik-scale.log" 2>/dev/null | tr '\n' ' ')"
        local rep
        if kc_al rep -n "$NS" get sts "$STS" -o jsonpath='{.spec.replicas}'; then
            if [ "${rep:-}" = "0" ]; then
                k_ok "$K_GERI" "$STS replicas=0 (açtığımız pod kapatıldı)"
            else
                k_fail "$K_GERI" "$STS hâlâ replicas=${rep:-?} — test kendi açtığı motoru cluster'da AÇIK bıraktı.
Elle: kubectl -n $NS scale statefulset $STS --replicas 0"
            fi
        else
            k_unknown "$K_GERI" "replicas okunamadı ($KC_HATA); motorun kapandığını doğrulayamadım.
Elle: kubectl -n $NS scale statefulset $STS --replicas 0"
        fi

        if [ "$NS_ONCEDEN_VARDI" = 0 ] && [ "$BIZ_APPLY_ETTIK" = 1 ]; then
            # İsim alanını BİZ yarattıysak geri alıyoruz: makineyi bulduğumuz
            # gibi bırakmak testin sözleşmesi. --wait=false, silme finalizer'a
            # takılırsa betiğin temizliğini bloklamasın diye.
            kc delete ns "$NS" --wait=false >/dev/null 2>&1 \
                && log "$NS isim alanı silindi (bu koşuda yaratılmıştı)"
        elif [ "$NS_ONCEDEN_VARDI" = 1 ]; then
            log "not: $NS isim alanı ve PVC'ler bırakıldı (bu koşudan önce de vardı)."
        fi
    fi

    # --- (b) k3s ------------------------------------------------------------
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

# TEK ÇIKIŞ KAPISI. Özet ve çıkış kodu lib.sh'in e2e_finish'inden gelir; ama
# temizlik BEŞ ölçüm üretiyor (K_GERI…K_HTTPS), o yüzden e2e_finish'ten ÖNCE
# çalışması şart — yoksa temizliğin sonuçları ne özete ne çıkış koduna girer.
cikista() {
    local gelen=$?
    # Temizlik kesilemez: yarıda kalan bir temizlik k3s'in DNAT kurallarını
    # yerinde bırakır ve kullanıcının paneli 80/443'te kapalı kalır. Bu betiğin
    # bırakabileceği en pahalı kalıntı budur.
    trap '' INT TERM
    # Sıra gelmemiş kontroller sessizce kaybolmasın: kesintide tablo eksik kalır
    # ve "5 geçti" satırı, 17 kontrolün hiç çalışmadığını gizler. Zaten
    # raporlanmış adlar bu çağrıdan etkilenmez (k_* ilk sonucu korur).
    atla_kalan "koşu bu kontrole sıra gelmeden bitti (kesinti ya da erken çıkış)"
    temizle
    e2e_finish; local rc=$?
    if [ "$gelen" -eq 130 ]; then
        # e2e_finish kesintiden haberdar değil; koşu yarıda kaldıysa yazdığı
        # "çalışan N kontrolün hepsi geçti" satırı yanıltıcıdır. Son sözü
        # burada söylüyoruz ki ekranda kalan cümle doğru olsun.
        printf '  %sKOŞU KESİLDİ:%s yukarıdaki özet bu koşu için GEÇERSİZ — %d kontrole hiç sıra gelmedi.\n\n' \
            "$RED" "$NC" "$E2E_SKIP"
        exit 130
    fi
    if [ "$gelen" -ne 0 ] && [ "$rc" -eq 0 ]; then
        printf '  %sBetik %d ile bitti ama tabloda başarısız kontrol yok — yine de yeşil yazmıyoruz.%s\n' \
            "$RED" "$gelen" "$NC"
        exit "$gelen"
    fi
    exit "$rc"
}
# INT/TERM'i lib.sh yakalıyor (e2e_interrupt → exit 130); o çıkış da buraya
# uğrar, yani kesintide de temizlik çalışır.
trap cikista EXIT

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
    # Hiçbir kontrol çalışmadan çıkıyoruz. lib.sh bunu çıkış 2 ile bildirir
    # ("ölçmedik", "sağlam" değil); run.sh de paketi ÖLÇÜLMEDİ diye sayar.
    # Eski sürüm burada 0 ile çıkıyordu ve toplu koşucu "✓ k8s GEÇTİ" yazıyordu —
    # etkileşimsiz koşuda (cron/CI, --yes yok) VARSAYILAN davranış tam buydu.
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
    TEMEL_HTTP="$(_dis_olc http "$GW_HTTP")"
    TEMEL_HTTPS="$(_dis_olc https "$GW_HTTPS")"
    log "test öncesi gateway cevapları: $GW_HTTP → '$TEMEL_HTTP', $GW_HTTPS → '$TEMEL_HTTPS'"
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
    exit 0
fi
if ! $SUDO cat /etc/rancher/k3s/k3s.yaml > "$TMPD/kubeconfig" 2>"$TMPD/kubeconfig.err"; then
    atla_kalan "kubeconfig okunamadı: $(tail -2 "$TMPD/kubeconfig.err" | tr '\n' ' ')"
    exit 0
fi
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

# K_NODE'un SONUCU burada BASILMIYOR — aşağıdaki güvenlik freninden sonra
# basılıyor. Sebebi: fren devreye girdiğinde (cluster kullanıcının, üstünde
# çalışan motorlar var) bu koşu ürün hakkında hiçbir şey ölçmemiş olur. K_NODE'u
# şimdiden "geçti" saymak lib.sh'e "1 geçti, 0 başarısız" der ve toplu koşucu
# 22 kontrolün atlandığı koşuyu "✓ k8s GEÇTİ" diye özetlerdi. Hiçbir kontrol
# raporlanmayınca çıkış kodu 2 olur: "ölçmedik" — doğru cevap budur.
if bekle "$K3S_TIMEOUT" "node'un Ready olması bekleniyor" \
        bash -c 'kubectl get nodes --no-headers 2>/dev/null | grep -qw Ready'; then
    kc_al _node_satir get nodes --no-headers || _node_satir=""
    NODE_OZET="$(printf '%s' "$_node_satir" | head -1 | awk '{print $1, $2, $5}')"
    log "node hazır: ${NODE_OZET:-(satır okunamadı)}"
else
    k_fail "$K_NODE" "node $K3S_TIMEOUT sn içinde Ready olmadı: $(kubectl get nodes 2>&1 | head -2 | tr '\n' ' ')"
    atla_kalan "k3s cluster'ı kullanılabilir değil"
    exit 1
fi

# =============================================================================
# GÜVENLİK FRENİ — var olan bir cluster'a apply etmek, orada ÇALIŞAN motorları
# 0 replikaya indirirdi (manifestler replicas: 0 ile geliyor). Kullanıcının
# canlı veritabanını durdurmaktansa testi burada kesiyoruz.
#
# Bu sorgu FAIL-OPEN OLAMAZ. Eski sürüm `calisan="$(kc ... 2>/dev/null | …)"`
# yazıyordu: sorgu hata verdiğinde (RBAC, zaman aşımı, alan adı değişikliği)
# çıktı boş kalıyor ve "çalışan motor yok" gibi okunuyordu — yani frenin
# kendisi, kullanıcının motorlarını durduran yola çıkıyordu. Artık rc ölçülüyor
# ve okuyamadığımızda APPLY ETMİYORUZ.
# =============================================================================
if kc_al _ns_ad get ns "$NS" -o name; then
    ns_var=1
elif printf '%s' "$KC_HATA" | grep -qiE 'not ?found'; then
    ns_var=0
else
    k_unknown "$K_APPLY" "isim alanı sorgusu cevap vermedi ($KC_HATA) — cluster'ın durumunu okumadan apply etmiyorum: manifestler replicas:0 ile geliyor, açık bir motoru durdurabilirdim"
    atla_kalan "cluster durumu okunamadı; hiçbir şey uygulanmadı"
    exit 1
fi

if [ "$ns_var" = 1 ]; then
    if ! kc_al _sts_ham -n "$NS" get statefulsets \
            -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas} {end}'; then
        k_unknown "$K_APPLY" "$NS isim alanındaki StatefulSet'ler okunamadı ($KC_HATA) — açık motor var mı bilmeden apply etmiyorum"
        atla_kalan "cluster durumu okunamadı; hiçbir şey uygulanmadı"
        exit 1
    fi
    calisan="$(printf '%s' "$_sts_ham" | tr ' ' '\n' | grep -v '=0$' | grep -v '^$' | tr '\n' ' ')"
    if [ -n "$calisan" ]; then
        atla_kalan "$NS isim alanında ZATEN çalışan motorlar var ($calisan); apply onları 0 replikaya indirirdi"
        # Temizlik bu cluster'a HİÇ dokunmasın: KUBECONFIG'i düşürüyoruz.
        # (BIZ_ACTIK=0 zaten koruyor; bu ikinci emniyet.)
        unset KUBECONFIG
        exit 0
    fi
else
    NS_ONCEDEN_VARDI=0
fi

# Fren geçildi; ürünü ölçmeye başlıyoruz. İlk sonuç node'un durumu.
k_ok "$K_NODE" "$NODE_OZET"

# =============================================================================
# 2/6 — manifestler
# =============================================================================
heading "2/6 — manifestler uygulanıyor (kubectl apply -k k8s/base)"

if kc apply -k k8s/base >"$TMPD/apply.log" 2>&1; then
    BIZ_APPLY_ETTIK=1
    if kc_al _sts_adlar -n "$NS" get statefulsets -o name; then
        sts_sayisi="$(printf '%s\n' "$_sts_adlar" | grep -c 'statefulset')"
        case "$sts_sayisi" in ''|*[!0-9]*) sts_sayisi=0 ;; esac
        if [ "$sts_sayisi" -eq "$DB_SAYISI" ]; then
            k_ok "$K_APPLY" "$sts_sayisi StatefulSet (katalogdaki veritabanı sayısı: $DB_SAYISI)"
        else
            k_fail "$K_APPLY" "katalogda $DB_SAYISI veritabanı var, cluster'da $sts_sayisi StatefulSet oluştu — manifestler katalogla ayrışmış (python3 scripts/gen-k8s.py ile yeniden üretin)"
        fi
    else
        k_unknown "$K_APPLY" "apply hata vermedi ama StatefulSet listesi okunamadı ($KC_HATA) — kaç nesne oluştuğunu ölçemedim"
    fi
else
    k_fail "$K_APPLY" "$(tail -5 "$TMPD/apply.log" | tr '\n' ' ')"
    atla_kalan "manifestler uygulanamadı"
    exit 1
fi

# Kapalı motor = HİÇ pod yok. Bir manifest yanlışlıkla replicas: 1 ile
# üretilirse apply anında 12 veritabanı birden açılır ve node belleği biter;
# kullanıcı hiçbir düğmeye basmadan sunucusunu kaybeder. Sorgu düşerse
# "hepsi 0" demek en tehlikeli varsayım olurdu.
if kc_al _rep_ham -n "$NS" get statefulsets \
        -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas} {end}'; then
    if [ -z "$_rep_ham" ]; then
        k_unknown "$K_REPLICAS" "StatefulSet listesi BOŞ döndü — apply sonrası en az $DB_SAYISI kayıt beklenirdi; replikaları ölçemedim"
    else
        acik="$(printf '%s' "$_rep_ham" | tr ' ' '\n' | grep -v '=0$' | grep -v '^$' | tr '\n' ' ')"
        if [ -z "$acik" ]; then
            k_ok "$K_REPLICAS" "$(printf '%s' "$_rep_ham" | tr ' ' '\n' | grep -c '=0$') StatefulSet, hepsi replicas=0"
        else
            k_fail "$K_REPLICAS" "sıfır olmayan replika: $acik"
        fi
    fi
else
    k_unknown "$K_REPLICAS" "replika sorgusu düştü ($KC_HATA) — 'toplam 0 pod' varsaymak, apply'ın 12 motoru birden açtığı durumu gizlerdi"
fi

# Manifestteki STATİK varsayılanlar: controller henüz hiçbir şeye dokunmadan
# okunuyor. Boyutlandırma kontrolleri (K_LIMIT/K_SB/K_DIGER) bunlara bakıp
# kendilerinin AYIRT EDİCİ olup olmadığını söyleyecek: plan tam olarak bu
# değerlere denk gelirse `set env` hiç işlemese de aynı sonuç okunur.
_manifest_env() {   # <env adı> → değer (rc 1: okunamadı)
    local _mv
    kc_al _mv -n "$NS" get sts "$STS" \
        -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}" || return 1
    printf '%s' "$_mv"
}
VARSAYILAN_OKUNDU=1
kc_al VARSAYILAN_LIMIT -n "$NS" get sts "$STS" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' || VARSAYILAN_OKUNDU=0
VARSAYILAN_SB="$(_manifest_env POSTGRES_SHARED_BUFFERS)"   || VARSAYILAN_OKUNDU=0
VARSAYILAN_EC="$(_manifest_env POSTGRES_EFFECTIVE_CACHE)"  || VARSAYILAN_OKUNDU=0
VARSAYILAN_MC="$(_manifest_env POSTGRES_MAX_CONNECTIONS)"  || VARSAYILAN_OKUNDU=0
[ "$VARSAYILAN_OKUNDU" = 1 ] \
    && log "manifest varsayılanları: limit=${VARSAYILAN_LIMIT:-yok} shared_buffers=${VARSAYILAN_SB:-yok} max_connections=${VARSAYILAN_MC:-yok}" \
    || warn "manifestteki statik varsayılanlar okunamadı — boyutlandırma kontrollerinin ayırt edici olduğunu doğrulayamayacağım"

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
beklenen="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
if python3 "$TMPD/gen/scripts/gen-k8s.py" --with-secrets >"$TMPD/gen.log" 2>&1 \
   && [ -f "$gizli_dosya" ] \
   && kc apply -f "$gizli_dosya" >>"$TMPD/gen.log" 2>&1; then
    if [ -z "$beklenen" ]; then
        k_skip "$K_SECRET" ".env'de POSTGRES_PASSWORD/DB_PASSWORD yok — karşılaştıracak değer yok"
    elif ! kc_al _b64 -n "$NS" get secret db-secrets -o jsonpath='{.data.POSTGRES_PASSWORD}'; then
        k_unknown "$K_SECRET" "Secret okunamadı ($KC_HATA) — cluster'daki parolayı .env'dekiyle karşılaştıramadım"
    elif [ -z "$_b64" ]; then
        k_fail "$K_SECRET" "db-secrets içinde POSTGRES_PASSWORD alanı YOK — pod 'CreateContainerConfigError' ile açılmaz"
    elif ! kayitli="$(printf '%s' "$_b64" | base64 -d 2>/dev/null)"; then
        k_unknown "$K_SECRET" "Secret'taki değer base64 olarak çözülemedi — karşılaştırma yapılamadı"
    elif [ "$kayitli" = "$beklenen" ]; then
        k_ok "$K_SECRET" "${#beklenen} karakterlik parola cluster'a taşındı"
    else
        k_fail "$K_SECRET" "Secret'taki parola .env'dekiyle aynı değil (uzunluk ${#kayitli} ↔ ${#beklenen}); pod 'password authentication failed' verir"
    fi
elif [ -z "$beklenen" ]; then
    # Parola hiç yoksa üreticinin başarısız olması ÜRÜN HATASI DEĞİL, ön koşul
    # eksikliğidir; bunu "başarısız" saymak yanlış alarm olurdu.
    k_skip "$K_SECRET" ".env'de POSTGRES_PASSWORD/DB_PASSWORD yok; Secret da üretilemedi: $(tail -2 "$TMPD/gen.log" | tr '\n' ' ')"
else
    k_fail "$K_SECRET" "Secret üretilemedi/uygulanamadı: $(tail -3 "$TMPD/gen.log" | tr '\n' ' ')"
fi

# --- RBAC ------------------------------------------------------------------
# docs/KUBERNETES.md "controller'ın K8s'teki tek yetkisi StatefulSet okumak ve
# ölçeklemek" diyor ve bunu Docker'daki docker.sock erişimine (host'ta root'a
# eşdeğer) karşı bir güvenlik üstünlüğü olarak sunuyor. İddiayı API'ye sorarak
# ölçüyoruz: Role'e kısayoldan "*" eklenirse bu iki kontrol ayrışır.
#
# `can-i -q`nin çıkış kodu "hayır" ile "soramadım"ı ayırmıyordu: impersonation
# yetkisi yoksa, API hata verirse ya da timeout olursa rc yine sıfırdan farklı
# çıkıyor ve `! can-i` kalıbı bunu "yetki dar" GEÇTİ'sine çeviriyordu. Artık
# cevabın METNİNİ okuyoruz; yes/no gelmiyorsa ÖLÇEMEDİK.
SA="system:serviceaccount:$NS:controller"
rbac_sor() {   # rbac_sor <fiil> <kaynak> → stdout yes|no ; rc 1 = ölçülemedi
    local out
    kc_al out auth can-i "$1" "$2" --as="$SA" -n "$NS" >/dev/null 2>&1
    out="$(printf '%s' "$out" | tr -d '\r' | head -1 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$out" in
        yes|no) printf '%s' "$out"; return 0 ;;
    esac
    return 1
}
if ! r_sts="$(rbac_sor patch statefulsets)" || ! r_scale="$(rbac_sor patch statefulsets/scale)"; then
    k_unknown "$K_RBAC_OK" "kubectl auth can-i yes/no dönmedi ($KC_HATA) — controller'ın ölçekleme yetkisini ölçemedim"
elif [ "$r_sts" = "yes" ] && [ "$r_scale" = "yes" ]; then
    k_ok "$K_RBAC_OK" "patch statefulsets=$r_sts · patch statefulsets/scale=$r_scale"
else
    k_fail "$K_RBAC_OK" "controller ölçekleyemiyor (statefulsets=$r_sts, scale=$r_scale): paneldeki 'Aktif Et' K8s'te forbidden verir (kubectl auth can-i patch statefulsets/scale --as=$SA -n $NS)"
fi
if ! r_pod="$(rbac_sor delete pods)" || ! r_sec="$(rbac_sor get secrets)"; then
    k_unknown "$K_RBAC_NO" "kubectl auth can-i yes/no dönmedi ($KC_HATA) — 'yetki dar' iddiasını ölçemedim; ölçemediğimizi 'dar' saymak belgelenen güvenlik üstünlüğünü kanıtsız bırakırdı"
elif [ "$r_pod" = "no" ] && [ "$r_sec" = "no" ]; then
    k_ok "$K_RBAC_NO" "delete pods=$r_pod · get secrets=$r_sec (ikisi de reddedildi)"
else
    k_fail "$K_RBAC_NO" "controller'ın yetkisi belgelenenden GENİŞ (delete pods=$r_pod, get secrets=$r_sec) — k8s/base/controller.yaml içindeki Role'ü daraltın"
fi

# --- controller pod'u ------------------------------------------------------
if [ "$CONTROLLER_TESTI" != 1 ]; then
    k_skip "$K_CTRL" "--no-controller verildi"
elif ! kc_al ctrl_imaj -n "$NS" get deploy controller -o jsonpath='{.spec.template.spec.containers[0].image}'; then
    k_unknown "$K_CTRL" "controller Deployment'ı sorgulanamadı ($KC_HATA)"
elif [ -z "$ctrl_imaj" ]; then
    k_skip "$K_CTRL" "controller Deployment'ı bulunamadı"
elif ! command -v docker >/dev/null 2>&1 || ! docker image inspect "$ctrl_imaj" >/dev/null 2>&1; then
    k_skip "$K_CTRL" "$ctrl_imaj imajı bu makinede yok ve k3s onu bir kayıt defterinden çekemez; önce ./install.sh (imajı derler), sonra bu test"
else
    log "$ctrl_imaj k3s containerd'sine aktarılıyor…"
    # Boru hattının rc'si SON komuttan gelir: `docker save` düşse bile `ctr
    # import` 0 dönebilirdi. PIPESTATUS ile iki tarafı da ölçüyoruz.
    docker save "$ctrl_imaj" 2>"$TMPD/save.err" | $SUDO k3s ctr images import - >"$TMPD/import.log" 2>&1
    _ps=("${PIPESTATUS[@]}")
    if [ "${_ps[0]}" -ne 0 ] || [ "${_ps[1]}" -ne 0 ]; then
        k_unknown "$K_CTRL" "imaj containerd'ye aktarılamadı (docker save rc=${_ps[0]}, ctr import rc=${_ps[1]}): $(tail -2 "$TMPD/import.log" 2>/dev/null | tr '\n' ' ') $(tail -1 "$TMPD/save.err" 2>/dev/null)"
    else
        kc -n "$NS" rollout restart deploy/controller >/dev/null 2>&1
        if timeout 260 kubectl -n "$NS" rollout status deploy/controller --timeout=220s >"$TMPD/ctrl.log" 2>&1; then
            k_ok "$K_CTRL" "readinessProbe httpGet /healthz cevap verdi"
        else
            k_fail "$K_CTRL" "controller Ready olmadı: $(kc -n "$NS" get pods -l app.kubernetes.io/name=controller --no-headers 2>/dev/null | head -2 | tr '\n' ' ')"
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
node_okundu=1; node_kb=""; node_mb=0
if kc_al _node_ham get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}'; then
    node_kb="$(printf '%s\n' "$_node_ham" | sed 's/Ki$//' | grep -E '^[0-9]+$' | sort -n | tail -1)"
    [ -n "$node_kb" ] && node_mb=$((node_kb / 1024))
else
    node_okundu=0
fi

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
plan_rc=$?

# Plan üreten kod hiç çalışmadıysa hem K_NODE_MB hem K_PLAN ÖLÇÜLEMEDİ'dir:
# boş plan dosyasını "plan reddedildi" diye okumak, ürünün bir kararını değil
# ölçüm aracının çöküşünü raporlamak olurdu.
if [ "$plan_rc" -ne 0 ] || [ ! -s "$PLAN_DOSYA" ]; then
    k_unknown "$K_NODE_MB" "planlayıcı çalışmadı (rc=$plan_rc): $(tail -3 "$TMPD/plan.log" 2>/dev/null | tr '\n' ' ')"
    k_unknown "$K_PLAN"    "planlayıcı çalışmadı (rc=$plan_rc) — controller/app.py içe aktarılamadı ya da çöktü"
    atla_kalan "boyutlandırma planı üretilemedi (ölçüm aracı düştü)"
    exit 1
fi

plan_node="$(plan_alan node_mb)"
plan_cap="$(plan_alan capacity_mb)"
if [ "$node_okundu" != 1 ]; then
    k_unknown "$K_NODE_MB" "kubectl node listesi okunamadı ($KC_HATA) — controller'ın okuduğu değeri kıyaslayacak referansım yok"
elif [ "$node_mb" -eq 0 ] || [ -z "$plan_node" ]; then
    k_fail "$K_NODE_MB" "node allocatable belleği okunamadı (kubectl: '${node_kb:-boş}', controller: '${plan_node:-boş}') — controller sessizce /proc/meminfo'ya düşer. Plan günlüğü: $(tail -2 "$TMPD/plan.log" | tr '\n' ' ')"
elif [ "$plan_node" = "$node_mb" ] && [ "$plan_cap" = "$node_mb" ]; then
    k_ok "$K_NODE_MB" "en büyük node: $node_mb MB allocatable"
else
    k_fail "$K_NODE_MB" "kubectl $node_mb MB diyor, controller ${plan_node:-?} MB okudu, plan ${plan_cap:-?} MB kullandı — kapasite kaynağı ayrışmış"
fi

plan_ok="$(plan_alan ok)"
if [ "$plan_ok" = "True" ]; then
    LIMIT_MB="$(plan_alan limit_mb)"
    case "$LIMIT_MB" in
        ''|*[!0-9]*)
            k_unknown "$K_PLAN" "plan 'ok' dedi ama limit_mb sayı değil ('$LIMIT_MB') — ölçülecek hedef yok"
            atla_kalan "plan çıktısı okunamadı"
            exit 1 ;;
    esac
    k_ok "$K_PLAN" "limit=$LIMIT_MB MB · shared_buffers=$(plan_alan tuning.POSTGRES_SHARED_BUFFERS) · max_connections=$(plan_alan tuning.POSTGRES_MAX_CONNECTIONS)"
elif [ "$plan_ok" = "False" ]; then
    k_fail "$K_PLAN" "plan reddedildi: $(plan_alan reason)"
    atla_kalan "bellek planı üretilemediği için motor açılamadı"
    exit 1
else
    k_unknown "$K_PLAN" "plan çıktısındaki 'ok' alanı okunamadı ('$plan_ok'): $(tail -3 "$TMPD/plan.log" | tr '\n' ' ')"
    atla_kalan "plan çıktısı okunamadı"
    exit 1
fi

# Bu noktadan SONRA temizlik sorumlu: motoru biz açıyoruz, biz kapatacağız.
# Bayrak komuttan ÖNCE kalkıyor — ölçekleme yarıda kalırsa (replicas yazıldı,
# `set env` düştü) pod yine de ayağa kalkmış olabilir ve kapatılması gerekir.
BIZ_ACTIK=1
if ! k8s_scale 1 2>"$TMPD/scale.log"; then
    k_fail "$K_UP" "kubectl scale/set başarısız: $(tail -3 "$TMPD/scale.log" | tr '\n' ' ')"
    atla_kalan "motor açılamadı"
    exit 1
fi

# Container adı, kullanıcı/veritabanı adı ve PVC adı UYGULANMIŞ manifestten
# okunur — betiğe sabit yazılsaydı manifest değişince test yanlış yere bakardı.
kc_al _k -n "$NS" get sts "$STS" -o jsonpath='{.spec.template.spec.containers[0].name}' \
    || warn "container adı okunamadı ($KC_HATA); '$KAP' varsayılıyor"
[ -n "${_k:-}" ] && KAP="$_k"
_u="$(_manifest_env POSTGRES_USER)" && [ -n "$_u" ] && PGUSER="$_u"
_d="$(_manifest_env POSTGRES_DB)"   && [ -n "$_d" ] && PGDB="$_d"
kc_al _v -n "$NS" get sts "$STS" -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' || _v=""
[ -n "${_v:-}" ] || _v="data"
PVC="${_v}-${POD}"

if timeout $((POD_TIMEOUT + 30)) kubectl -n "$NS" rollout status statefulset/"$STS" \
        --timeout="${POD_TIMEOUT}s" >"$TMPD/rollout.log" 2>&1 \
   && bekle 120 "$POD içinde PostgreSQL'in bağlantı kabul etmesi bekleniyor" pg_hazir; then
    kc_al _pod_satir -n "$NS" get pod "$POD" --no-headers || _pod_satir=""
    k_ok "$K_UP" "$(printf '%s' "$_pod_satir" | awk '{print $2, $3, $5}')"
else
    k_fail "$K_UP" "pod $POD_TIMEOUT sn içinde hazır olmadı.
durum:   $(kc -n "$NS" get pod "$POD" --no-headers 2>/dev/null | tr -s ' ')
olaylar: $(kc -n "$NS" get events --field-selector involvedObject.name="$POD" --sort-by=.lastTimestamp -o jsonpath='{range .items[-3:]}{.reason}: {.message}{"; "}{end}' 2>/dev/null)"
    atla_kalan "pod hazır olmadığı için içine bakılamadı"
    exit 1
fi

# =============================================================================
# 4/6 — hesaplanan ayarlar POD İÇİNDE gerçekten uygulandı mı?
# =============================================================================
heading "4/6 — ayarlar pod içinde ölçülüyor, veri yazılıp okunuyor"

if ! kc_al pod_limit -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].resources.limits.memory}'; then
    k_unknown "$K_LIMIT" "pod'un bellek limiti okunamadı ($KC_HATA)"
elif [ "$pod_limit" != "${LIMIT_MB}Mi" ]; then
    k_fail "$K_LIMIT" "plan $LIMIT_MB MB dedi, pod'un limiti '${pod_limit:-yok}' — 'kubectl set resources' yanlış container'a gitmiş olabilir (--containers $KAP)"
elif [ "$VARSAYILAN_OKUNDU" = 1 ] && [ "${LIMIT_MB}Mi" = "$VARSAYILAN_LIMIT" ]; then
    k_skip "$K_LIMIT" "pod limiti $pod_limit ve plan da aynı — ama manifestin STATİK varsayılanı da $VARSAYILAN_LIMIT; 'kubectl set resources' hiç işlemese de bu değer okunurdu. Bu makinede kontrol AYIRT EDİCİ DEĞİL (belleği farklı bir makinede tekrarlayın)."
else
    _not=""
    [ -n "$VARSAYILAN_LIMIT" ] && _not=" — manifest varsayılanı $VARSAYILAN_LIMIT idi, yani set resources gerçekten uygulanmış"
    k_ok "$K_LIMIT" "$pod_limit$_not"
fi

# ASIL KONTROL. `kubectl set env` her zaman başarılı olur; manifestte args yoksa
# ya da $(VAR) çözülmezse motor VARSAYILANLA çalışır ve hiçbir yerde hata
# görünmez — pod bile "Running" der. Bu yüzden değeri motorun KENDİSİNE soruyoruz.
bek_sb="$(plan_alan tuning.POSTGRES_SHARED_BUFFERS)"
bul_sb=""
if [ -z "$bek_sb" ]; then
    k_unknown "$K_SB" "planda POSTGRES_SHARED_BUFFERS yok — karşılaştıracak beklenen değer üretilemedi"
elif ! bul_sb="$(pg_deger 'SHOW shared_buffers')"; then
    k_unknown "$K_SB" "SHOW shared_buffers çalıştırılamadı (exec/psql düştü): ${PG_HATA:-sebep yok}"
elif [ -z "$bul_sb" ]; then
    k_unknown "$K_SB" "SHOW shared_buffers boş cevap verdi — motorun çalışan değerini okuyamadım"
elif ! esit_mi "$bek_sb" "$bul_sb"; then
    k_fail "$K_SB" "controller $bek_sb hesapladı ama motor $bul_sb ile çalışıyor: manifestte args/\$(POSTGRES_SHARED_BUFFERS) eksik ya da 'set env' pod'a yansımamış. Ürünün 'sunucuya göre ayarlıyorum' vaadi sessizce boşa çıkar."
elif [ "$VARSAYILAN_OKUNDU" = 1 ] && ! ayirt_edici_mi "$bek_sb" "$VARSAYILAN_SB"; then
    k_skip "$K_SB" "motor $bul_sb ile çalışıyor ve plan da $bek_sb — ama manifestin statik varsayılanı da $VARSAYILAN_SB; 'set env' hiç işlemese de aynı değer okunurdu. Bu koşuda kontrol AYIRT EDİCİ DEĞİL, GEÇTİ yazmak yanıltıcı olur."
else
    _not=""
    [ -n "$VARSAYILAN_SB" ] && _not=" — manifest varsayılanı $VARSAYILAN_SB idi, yani okunan değer set env sayesinde"
    k_ok "$K_SB" "plan $bek_sb · motor $bul_sb$_not"
fi

bek_ec="$(plan_alan tuning.POSTGRES_EFFECTIVE_CACHE)"
bek_mc="$(plan_alan tuning.POSTGRES_MAX_CONNECTIONS)"
bul_ec=""; bul_mc=""
if ! bul_ec="$(pg_deger 'SHOW effective_cache_size')" || ! bul_mc="$(pg_deger 'SHOW max_connections')"; then
    k_unknown "$K_DIGER" "SHOW effective_cache_size / max_connections çalıştırılamadı: ${PG_HATA:-sebep yok}"
elif [ -z "$bek_ec" ] || [ -z "$bek_mc" ]; then
    k_unknown "$K_DIGER" "planda beklenen değerler yok (effective_cache='$bek_ec', max_connections='$bek_mc')"
elif esit_mi "$bek_ec" "$bul_ec" && [ "$bek_mc" = "$bul_mc" ]; then
    if [ "$VARSAYILAN_OKUNDU" = 1 ] \
       && ! ayirt_edici_mi "$bek_ec" "$VARSAYILAN_EC" && ! ayirt_edici_mi "$bek_mc" "$VARSAYILAN_MC"; then
        k_skip "$K_DIGER" "iki değer de plana uyuyor (effective_cache_size=$bul_ec, max_connections=$bul_mc) ama ikisi de manifestin statik varsayılanına eşit ($VARSAYILAN_EC / $VARSAYILAN_MC); 'set env' hiç işlemese de aynı sonuç çıkardı — kontrol AYIRT EDİCİ DEĞİL."
    else
        k_ok "$K_DIGER" "effective_cache_size=$bul_ec · max_connections=$bul_mc"
    fi
else
    k_fail "$K_DIGER" "effective_cache_size: plan $bek_ec / motor ${bul_ec:-yok}; max_connections: plan $bek_mc / motor ${bul_mc:-yok}"
fi

# --- veri yaz / oku --------------------------------------------------------
okunan=""
if ! pg_calistir "CREATE TABLE IF NOT EXISTS $TABLO (jeton text PRIMARY KEY, yazildi timestamptz DEFAULT now()); INSERT INTO $TABLO (jeton) VALUES ('$JETON') ON CONFLICT DO NOTHING;"; then
    k_unknown "$K_YAZ" "yazma komutu çalıştırılamadı: $(printf '%s' "$PG_CIKTI" | tail -2 | tr '\n' ' ')"
elif ! okunan="$(pg_deger "SELECT jeton FROM $TABLO WHERE jeton = '$JETON'")"; then
    k_unknown "$K_YAZ" "geri okuma sorgusu çalıştırılamadı: ${PG_HATA:-sebep yok}"
elif [ "$okunan" = "$JETON" ]; then
    YAZILDI=1
    k_ok "$K_YAZ" "jeton: $JETON"
else
    k_fail "$K_YAZ" "yazılan satır geri okunamadı (okunan: '${okunan:-boş}')"
fi

# Service + cluster DNS gerçekten çalışıyor mu? `kubectl exec` bunu ölçmez:
# uygulamalar motora exec ile değil, Service adıyla bağlanır. Service'in
# selector'ı ya da portu yanlışsa exec'li testler yeşil yanarken gerçek
# istemciler hiç bağlanamaz.
kc_al imaj -n "$NS" get sts "$STS" -o jsonpath='{.spec.template.spec.containers[0].image}' || imaj=""
pgpass="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
if [ "$YAZILDI" != 1 ]; then
    k_skip "$K_SVC" "kanıt satırı pod'a yazılamadı — Service üzerinden okunacak bir şey yok"
elif [ -z "${imaj:-}" ] || [ -z "$pgpass" ]; then
    k_skip "$K_SVC" "istemci pod'u için imaj ('${imaj:-yok}') ya da parola bilinmiyor"
else
    kc -n "$NS" delete pod "$ISTEMCI_POD" --ignore-not-found --now >/dev/null 2>&1
    ISTEMCI_YARATILDI=1
    svc_cikti="$(timeout 240 kubectl -n "$NS" run "$ISTEMCI_POD" --rm --restart=Never \
        --image="$imaj" --image-pull-policy=IfNotPresent --pod-running-timeout=180s \
        --env="PGPASSWORD=$pgpass" --quiet --attach --command -- \
        psql -h "$STS.$NS.svc.cluster.local" -p "$K8S_PORT" -U "$PGUSER" -d "$PGDB" \
        -tAc "SELECT jeton FROM $TABLO WHERE jeton = '$JETON'" 2>&1)"; svc_rc=$?
    svc_cikti="$(printf '%s' "$svc_cikti" | tr -d '\r')"
    # TAM SATIR eşleşmesi ve rc şart. Eski sürüm `grep -q "$JETON"` yazıyordu;
    # psql hata verdiğinde `LINE 1: SELECT jeton FROM … '<jeton>'` satırını geri
    # yazar ve o satır jetonu İÇERİR — Service yanlış pod'a gittiğinde bile
    # kontrol GEÇTİ diyordu (arızalı ve sağlıklı senaryo birebir aynı çıktı).
    if [ "$svc_rc" -eq 0 ]; then
        if printf '%s\n' "$svc_cikti" | grep -Fxq "$JETON"; then
            k_ok "$K_SVC" "$STS.$NS.svc.cluster.local:$K8S_PORT üzerinden okundu"
        else
            k_fail "$K_SVC" "istemci bağlandı ama satır GELMEDİ — Service başka bir pod'a/porta gidiyor olabilir. Çıktı: $(printf '%s' "$svc_cikti" | tail -3 | tr '\n' ' ')"
        fi
    # rc sıfır değil: iki bambaşka sebep olabilir ve ayrımı YAPMAK ZORUNDAYIZ.
    #   (1) kubectl istemci pod'unu hiç çalıştıramadı → ÖLÇEMEDİK
    #   (2) psql çalıştı ama Service'e bağlanamadı/sorgu hata verdi → ÜRÜN HATASI
    # kubectl kendi hatalarını küçük harfle 'error:' diye yazar, PostgreSQL ise
    # büyük harfle 'ERROR:'/'FATAL:'; bu yüzden burada -i KULLANILMAZ, yoksa
    # "error: timed out waiting" ölçüm çöküşü olduğu hâlde ürün hatası sayılır.
    elif printf '%s' "$svc_cikti" \
         | grep -qE '^error: |timed out waiting|ImagePullBackOff|ErrImagePull|Unable to connect to the server|unable to (find|recognize)|already exists'; then
        k_unknown "$K_SVC" "istemci pod'u çalıştırılamadı (rc=$svc_rc) — Service ölçülemedi: $(printf '%s' "$svc_cikti" | tail -3 | tr '\n' ' ')"
    elif printf '%s' "$svc_cikti" \
         | grep -qE 'psql:|could not connect|[Cc]onnection refused|no route to host|could not translate|timeout expired|password authentication|ERROR:|FATAL:'; then
        k_fail "$K_SVC" "Service üzerinden okunamadı (rc=$svc_rc): $(printf '%s' "$svc_cikti" | tail -3 | tr '\n' ' ')"
    else
        k_unknown "$K_SVC" "istemci pod'u ölçüm yapamadı ve sebebi anlaşılmadı (rc=$svc_rc): $(printf '%s' "$svc_cikti" | tail -3 | tr '\n' ' ')"
    fi
fi

# =============================================================================
# 5/6 — kapatma, PVC ve kalıcılık
# =============================================================================
heading "5/6 — $ENGINE durduruluyor (1 → 0) ve veri kalıcılığı ölçülüyor"

if ! k8s_scale 0 2>"$TMPD/scale0.log"; then
    k_fail "$K_DOWN" "controller'ın kapatma komutu hata verdi: $(tail -3 "$TMPD/scale0.log" | tr '\n' ' ')"
elif bekle 180 "$POD pod'unun silinmesi bekleniyor" pod_yok_mu; then
    k_ok "$K_DOWN" "pod yok (NotFound), StatefulSet replicas=0"
elif kc_al _pod_kalan -n "$NS" get pod "$POD" -o name; then
    # Pod HÂLÂ orada: ölçtük, yanlış.
    k_fail "$K_DOWN" "pod 180 sn sonra hâlâ duruyor (${_pod_kalan:-?}): $(kc -n "$NS" get pod "$POD" --no-headers 2>&1 | head -1 | tr -s ' ') $(tail -2 "$TMPD/scale0.log" | tr '\n' ' ')"
elif printf '%s' "$KC_HATA" | grep -qiE 'not ?found'; then
    # Bekleme penceresinin son anında silinmiş olabilir; sonuç yine de ölçüldü.
    k_ok "$K_DOWN" "pod NotFound (bekleme bitiminde silinmişti)"
else
    # kubectl cevap vermiyor: pod'un silinip silinmediğini BİLMİYORUZ.
    k_unknown "$K_DOWN" "pod'un silindiği doğrulanamadı ($KC_HATA) — 180 sn boyunca durum okunamadı"
fi

# PVC sorgusu düşerse "durum yok" çıkar; eski sürüm bunu 'Bound değil' diye
# KALDI yazıyordu. NotFound (gerçekten silinmiş = veri kaybı) ile "sorgu
# cevap vermedi" ayrı şeyler.
if kc_al pvc_durum -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}'; then
    if [ "$pvc_durum" = "Bound" ]; then
        kc_al _pvc_boy -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.resources.requests.storage}' || _pvc_boy="?"
        k_ok "$K_PVC" "$PVC: Bound (${_pvc_boy:-?})"
    else
        k_fail "$K_PVC" "$PVC durumu '${pvc_durum:-boş}' — motoru kapatmak veri diskini de silmiş olur, 'Durdur' düğmesi veri kaybına dönüşür"
    fi
elif printf '%s' "$KC_HATA" | grep -qiE 'not ?found'; then
    k_fail "$K_PVC" "$PVC YOK — motoru kapatmak veri diskini de sildi, 'Durdur' düğmesi veri kaybına dönüşür"
else
    k_unknown "$K_PVC" "PVC durumu okunamadı ($KC_HATA) — diskin durduğunu doğrulayamadım"
fi

# PVC'nin var olması veriyi TUTTUĞU anlamına gelmez: yanlış mountPath, hacmin
# dışında kalan bir PGDATA ya da emptyDir'e düşmüş bir hacim tam olarak aynı
# görüntüyü verir. Tek kanıt, yeniden açıp satırı geri okumaktır.
if [ "$YAZILDI" != 1 ]; then
    k_skip "$K_KALICI" "kanıt satırı hiç yazılamadığı için kalıcılık ölçülemez (K_YAZ'a bakın)"
elif ! k8s_scale 1 2>>"$TMPD/scale.log"; then
    k_fail "$K_KALICI" "motor yeniden açılamadı (controller hata verdi): $(tail -3 "$TMPD/scale.log" | tr '\n' ' ')"
elif ! timeout $((POD_TIMEOUT + 30)) kubectl -n "$NS" rollout status statefulset/"$STS" \
        --timeout="${POD_TIMEOUT}s" >>"$TMPD/rollout.log" 2>&1 \
     || ! bekle 120 "$POD yeniden açıldı, bağlantı bekleniyor" pg_hazir; then
    k_fail "$K_KALICI" "motor yeniden açıldı ama pod hazır olmadı: $(tail -3 "$TMPD/rollout.log" | tr '\n' ' ')"
elif ! tekrar="$(pg_deger "SELECT jeton FROM $TABLO WHERE jeton = '$JETON'")"; then
    k_unknown "$K_KALICI" "yeniden açılan pod'da sorgu çalıştırılamadı: ${PG_HATA:-sebep yok}"
elif [ "$tekrar" = "$JETON" ]; then
    k_ok "$K_KALICI" "pod yeniden yaratıldı, satır yerinde"
else
    k_fail "$K_KALICI" "yeniden açılan pod'da satır YOK (okunan: '${tekrar:-boş}') — veri PVC'de değil, pod'un geçici katmanındaymış"
fi

# 6/6 (temizlik + K_GERI/K_KILL/K_IPT/K_HTTP/K_HTTPS) EXIT tuzağındaki
# cikista() içinde çalışır: temizle → e2e_finish → çıkış kodu. Betik buradan
# önce hangi satırda biterse bitsin o adım atlanmaz.
exit 0
