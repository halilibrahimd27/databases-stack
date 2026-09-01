#!/bin/bash
# =============================================================================
# E2E — KAYNAĞA GÖRE OTOMATİK BOYUTLANDIRMA
# =============================================================================
# Kurulu ve ÇALIŞAN bir yığına karşı çalışır. Sorduğu soru tek:
#
#     "Controller'ın hesapladığını söylediği bellek container'a GERÇEKTEN
#      uygulanmış mı — ve motorun kendi iç ayarı o limitin altında mı?"
#
# Bu ürünün en sessiz arıza sınıfı burada. Dashboard "MariaDB'ye 2 GB ayrıldı"
# yazar, tuning.env'de değer durur, ama container'ın cgroup'unda limit yoktur
# ya da motor hâlâ imajın 1G varsayılan buffer pool'uyla açılmıştır. Hiçbir şey
# hata vermez; arıza aylar sonra, gece yarısı OOM-killer veritabanını
# öldürdüğünde ortaya çıkar. Bu yüzden burada API'nin SÖYLEDİĞİNE değil,
# docker'ın ve motorun KENDİ ağzından çıkana bakıyoruz.
#
# Kullanım:
#     ./scripts/e2e/sizing.sh
#
# Ortam değişkeni (opsiyonel):
#     SIZING_SKIP_REFUSAL=1   bütçe aşımı reddi testini atla. O test kapalı bir
#                             motora "host RAM'inin 8 katı" isteğiyle aktivasyon
#                             gönderir; reddedilmesi beklenir (ve ret çalışmazsa
#                             betik açılanı kendisi kapatır), ama canlı sistemde
#                             karar sizin olsun diye kapatılabilir.
#
# NE YARATIR / NE SİLER:
#     Veritabanı, tablo, kullanıcı ya da kalıcı dosya YARATMAZ. Yalnız /tmp
#     altında geçici bir çalışma dizini açar ve çıkarken siler. Bütçe reddi
#     testi controller'ın olay günlüğüne bir "activate_refused" kaydı bırakır;
#     bu bir denetim kaydıdır, silinmez. Betik arka arkaya iki kez
#     çalıştırılabilir — ikinci çalıştırma birincisinden farklı davranmaz.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

ALAN="boyutlandırma"

# ------------------------------------------------------------- test sayaçları
PASS=0; FAIL=0; SKIP=0

t_ok() {
    PASS=$((PASS + 1))
    printf '%s[GEÇTİ]%s   %s\n' "$GREEN" "$NC" "$1"
    return 0
}
t_fail() {
    FAIL=$((FAIL + 1))
    printf '%s[KALDI]%s   %s\n' "$RED" "$NC" "$1" >&2
    [ -n "${2:-}" ] && printf '            ↳ %s\n' "$2" >&2
    return 0
}
# Sessizce atlanan test GEÇMİŞ sanılır ve bu, bir testin verebileceği en pahalı
# yanlış cevaptır: "boyutlandırma doğrulandı" denir, oysa hiç ölçülmemiştir.
# Atlama da satır üretir ve SEBEBİNİ yazar.
t_skip() {
    SKIP=$((SKIP + 1))
    printf '%s[ATLANDI]%s %s\n' "$YELLOW" "$NC" "$1"
    printf '            ↳ sebep: %s\n' "${2:-belirtilmedi}"
    return 0
}

ozet_ve_cik() {
    local toplam=$((PASS + FAIL + SKIP))
    heading "──────────────────────────────────────────────────────────────"
    printf '%s: %d/%d geçti  (%d başarısız, %d atlandı)\n' \
           "$ALAN" "$PASS" "$toplam" "$FAIL" "$SKIP"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

# ------------------------------------------------------------------ önkoşullar
require_cmd docker python3 curl

# Hiçbir bekleme sonsuz olmasın: asılı kalan bir `docker exec` (ör. cevap
# vermeyen motor) betiği de sonsuza dek askıda bırakırdı.
if command -v timeout >/dev/null 2>&1; then
    TO() { timeout "$@"; }
else
    warn "'timeout' komutu yok — container içi çağrılar zaman aşımısız çalışacak."
    TO() { shift; "$@"; }
fi

PANEL_USER="${PANEL_USER:-admin}"
[ -n "${PANEL_PASSWORD:-}" ] || die "PANEL_PASSWORD .env'de boş — gateway'in API'sine kimlik doğrulanamaz."
GW="https://127.0.0.1:${GATEWAY_HTTPS_PORT:-443}"
PROJ="${STACK_PROJECT:-databases-stack}"
API_TIMEOUT=25          # sn — controller cevabı bu sürede gelmezse ölçüm yok
DEX_TIMEOUT=30          # sn — container içi sorgular
JOB_TIMEOUT=90          # sn — reddedilmesi beklenen iş bu sürede sonuçlanmalı

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-sizing.XXXXXX")" || die "geçici dizin açılamadı"
trap 'rm -rf "$TMP"' EXIT INT TERM

heading "E2E — kaynağa göre otomatik boyutlandırma   ($GW)"

# ------------------------------------------------------------ yardımcı: JSON
# Depodaki üslupla aynı (bkz. backup.sh: engine_field): küçük bir python
# ifadesi, dosyadan okunan JSON üzerinde. `E` motor kimliğini taşır.
pj() {   # pj <dosya> <ifade> [motor-kimliği]
    EID="${3:-}" python3 -c '
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
E = os.environ.get("EID", "")
try:
    v = eval(sys.argv[2], {"d": d, "E": E})
except Exception:
    sys.exit(1)
if v is None:
    v = ""
sys.stdout.write(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))
' "$1" "$2" 2>/dev/null
}

# Tek değer döndüren yardımcılar print YERİNE sys.stdout.write kullanır ve
# liste döndüren yardımcı satır sonlarını temizler: Windows'ta düzenlenmiş bir
# depoda ya da CRLF çeviren bir Python'da print'in eklediği \r container adının
# sonuna yapışır, "mariadb\r" diye bir container aranır ve HER MOTOR "kapalı"
# sanılıp sessizce atlanır. common.sh'ın .env okurken \r attığı gerekçenin
# aynısı (bkz. .gitattributes).
engine_field() {   # engine_field <motor> <python-ifadesi>   (backup.sh ile aynı)
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e:
    sys.exit(1)
sys.stdout.write(str(eval(sys.argv[3], {"e": e[0]})))' "$CATALOG" "$1" "$2" 2>/dev/null
}

engine_ids() {
    python3 -c 'import json,sys;print("\n".join(e["id"] for e in json.load(open(sys.argv[1],encoding="utf-8"))["engines"]))' \
        "$CATALOG" | tr -d '\r'
}

limit_env_of() {   # <motor> → katalogdaki "kind: limit" ayarının env adı
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e:
    sys.exit(1)
for t in e[0].get("resources", {}).get("tuning", []):
    if t.get("kind") == "limit":
        sys.stdout.write(t["env"]); break' "$CATALOG" "$1" 2>/dev/null
}

# ------------------------------------------------------------- yardımcı: API
# Controller host'a port açmaz; ona ulaşmanın yolu gateway'dir. Sertifika
# kurulum sonrası kendi CA'sıyla imzalı olduğu için -k, kimlik için panel
# kullanıcısı (-u). curl Origin/Sec-Fetch-Site göndermediği için gateway'in
# çapraz-site kapısı bakım betiklerini bilerek geçirir.
api_get() {   # api_get <yol> <çıktı-dosyası> → HTTP kodunu basar
    local code
    code="$(curl -sk -u "$PANEL_USER:$PANEL_PASSWORD" --max-time "$API_TIMEOUT" \
                 -o "$2" -w '%{http_code}' "$GW$1" 2>/dev/null)"
    printf '%s' "${code:-000}"
}
api_post() {  # api_post <yol> <gövde> <çıktı-dosyası> → HTTP kodunu basar
    local code
    code="$(curl -sk -u "$PANEL_USER:$PANEL_PASSWORD" --max-time "$API_TIMEOUT" \
                 -X POST -H 'Content-Type: application/json' -d "$2" \
                 -o "$3" -w '%{http_code}' "$GW$1" 2>/dev/null)"
    printf '%s' "${code:-000}"
}

# --------------------------------------------------- yardımcı: boyut çözümü
cat > "$TMP/size2b.py" <<'PY'
# "512M" / "512MB" / "384mb" / "0.75G" / "1610612736" → bayt
import re, sys
s = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
m = re.match(r"^([0-9]+(?:\.[0-9]+)?)\s*([kKmMgGtT]?)[bB]?$", s)
if not m:
    sys.exit(1)
mult = {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3, "t": 1024 ** 4}
print(int(float(m.group(1)) * mult[m.group(2).lower()]))
PY
size2b() { python3 "$TMP/size2b.py" "${1:-}" 2>/dev/null; }

# ----------------------- yardımcı: katalog formülünün BAĞIMSIZ ikinci kopyası
# controller/app.py:compute_tuning'in portu. Amacı kodu tekrarlamak değil,
# HESABI BAĞIMSIZ YAPMAK: controller kataloğu imajına gömülü ya da kopmuş bir
# bind-mount'tan okuyorsa API'nin verdiği sayılar diskteki catalog.json'un
# formülüyle tutmaz. O durumda yönetici catalog.json'u düzenler, hiçbir şey
# değişmez ve sebebini hiçbir yerde göremez.
cat > "$TMP/tuning_calc.py" <<'PY'
import json, sys

cat_path, eid, limit_mb = sys.argv[1], sys.argv[2], int(sys.argv[3])
cat = json.load(open(cat_path, encoding="utf-8"))
eng = [e for e in cat["engines"] if e["id"] == eid]
if not eng:
    sys.exit(1)
spec = eng[0].get("resources", {}).get("tuning", [])


def clamp(v, lo, hi):
    if lo is not None:
        v = max(v, lo)
    if hi is not None:
        v = min(v, hi)
    return v


def fmt(value_mb, f):
    v = int(value_mb)
    if f == "M":
        return "%dM" % v
    if f == "MB":
        return "%dMB" % v
    if f == "m":
        return "%dm" % v
    if f == "mb":
        return "%dmb" % v
    if f == "bytes":
        return str(v * 1024 * 1024)
    if f in ("int", "int_mb"):
        return str(v)
    if f == "java":
        return "-Xms%dm -Xmx%dm" % (v, v)
    if f == "G_half":
        g = max(0.25, round((v / 1024.0) * 4) / 4.0)
        return "%g" % g
    return str(v)


out, scratch = {}, {}
for t in spec:
    kind = t.get("kind")
    if kind == "limit":
        val = limit_mb
    elif kind == "fraction":
        val = clamp(limit_mb * t.get("factor", 0.5), t.get("min_mb"), t.get("max_mb"))
    elif kind == "per_gb":
        val = clamp(round(t.get("factor", 100) * limit_mb / 1024.0), t.get("min"), t.get("max"))
    else:
        continue
    scratch[t["env"]] = val
    out[t["env"]] = fmt(val, t.get("fmt", "int"))
for t in spec:
    if t.get("kind") != "workmem":
        continue
    conns = max(1, int(scratch.get("POSTGRES_MAX_CONNECTIONS", 100)))
    out[t["env"]] = fmt(clamp(int((limit_mb * 0.25) / conns), 2, 64), t.get("fmt", "MB"))
for k in sorted(out):
    print("%s=%s" % (k, out[k]))
PY

# ------------------------------- yardımcı: değer container'a gerçekten geçmiş mi
# Hesaplanan değeri container'ın GERÇEK komut satırında/ortamında arar.
# Yakaladığı arıza: motor `--env-file state/tuning.env` olmadan açılmış (elle
# `docker compose up`), imajın varsayılanıyla çalışıyor; controller ise hesabını
# tuning.env'e yazmış ve "uygulandı" saymış. Dashboard'daki sayı ile gerçek
# birbirini tutmaz, hiçbir hata da çıkmaz.
cat > "$TMP/cfgmatch.py" <<'PY'
import json, sys

cfg = json.load(open(sys.argv[1], encoding="utf-8"))[0]["Config"]
val = sys.argv[2]
items = []
for key in ("Cmd", "Entrypoint", "Env"):
    items += [str(x) for x in (cfg.get(key) or [])]


def hit(s):
    # "0.75" (tek başına arg), "--maxmemory=399mb" / "shared_buffers=1024MB"
    # (anahtar=değer) ve "ES_JAVA_OPTS=-Xms819m -Xmx819m" (boşluklu değer)
    # biçimlerinin üçünü de yakalar.
    if s == val or s.endswith("=" + val):
        return True
    return any(tok == val for tok in s.replace("=", " ").split())


sys.exit(0 if any(hit(s) for s in items) else 1)
PY

# --------------------------------------------- yardımcı: container ve limitler
# primary_of() topolojide kayıt yoksa MOTOR KİMLİĞİNİ döndürür; kimlik her
# zaman servis adı değildir (monitoring → grafana). Kimliği container adı
# sanan bir kontrol "container yok" deyip motoru sessizce atlar. Bu yüzden asıl
# kaynak katalogdaki primary_service; topoloji yalnız devir olmuşsa devreye
# girer (devirden sonra ana kopya replika container'ıdır).
primary_container() {   # <motor> → şu anki ana kopya container adı
    local eid="$1" svc topo
    svc="$(engine_field "$eid" 'e["primary_service"]')" || return 1
    topo="$(primary_of "$eid")"
    if [ -n "$topo" ] && [ "$topo" != "$eid" ]; then svc="$topo"; fi
    printf '%s' "$svc"
}

docker_limit_mb() {   # <container> → MB (0 = limitsiz)
    local b
    b="$(TO 20 docker inspect -f '{{.HostConfig.Memory}}' "$1" 2>/dev/null)" || return 1
    case "$b" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$((b / 1048576))"
}

cgroup_limit_mb() {   # <container> → çekirdeğin GERÇEKTEN uyguladığı limit (MB)
    local v
    v="$(TO "$DEX_TIMEOUT" docker exec "$1" sh -c \
         'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' \
         2>/dev/null | tr -d '\r' | head -1)"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$((v / 1048576))"
}

# =============================================================================
# 0) ÖN KOŞULLAR
# =============================================================================
heading "0) Ön koşullar"

if container_running gateway; then
    t_ok "gateway container'ı çalışıyor (API'nin tek giriş kapısı)"
else
    t_fail "gateway container'ı çalışıyor (API'nin tek giriş kapısı)" \
           "gateway ayakta değil; /api/... hiçbir yerden çağrılamaz. Önce: ./install.sh"
fi
if container_running controller; then
    t_ok "controller container'ı çalışıyor (boyutlandırmayı yapan servis)"
else
    t_fail "controller container'ı çalışıyor (boyutlandırmayı yapan servis)" \
           "controller ayakta değil; plan hesaplanamaz, aktivasyon yapılamaz."
fi

PLANS="$TMP/plans.json"
code="$(api_get /api/plans "$PLANS")"
if [ "$code" = "200" ] && [ -n "$(pj "$PLANS" 'd["plans"]')" ]; then
    t_ok "gateway üzerinden /api/plans 200 döndürüyor ve JSON çözümleniyor"
else
    t_fail "gateway üzerinden /api/plans 200 döndürüyor ve JSON çözümleniyor" \
           "HTTP $code — gövde: $(head -c 200 "$PLANS" 2>/dev/null | tr -d '\n')"
    t_skip "boyutlandırmanın geri kalanı" \
           "plan API'si okunamadı; karşılaştırılacak hesap yok — ölçüm yapılamadı"
    ozet_ve_cik
fi

IDS="$(engine_ids)"
N_CAT="$(printf '%s\n' "$IDS" | grep -c .)"
N_PLAN="$(pj "$PLANS" 'len(d["plans"])')"
eksik=""
for eid in $IDS; do
    [ "$(pj "$PLANS" 'E in d["plans"]' "$eid")" = "true" ] || eksik="$eksik $eid"
done
if [ -z "$eksik" ] && [ "$N_PLAN" = "$N_CAT" ]; then
    t_ok "/api/plans katalogdaki $N_CAT kaydın hepsi için plan üretiyor"
else
    t_fail "/api/plans katalogdaki $N_CAT kaydın hepsi için plan üretiyor" \
           "planı olmayan:${eksik:- yok}; plan sayısı=$N_PLAN, katalog=$N_CAT — dashboard'da kartı olup planı olmayan motor 'Aktif Et'e basılınca anlaşılmaz hata verir"
fi

# =============================================================================
# 1) PLANIN DAYANDIĞI ÖLÇÜLER
# =============================================================================
heading "1) Planın dayandığı ölçüler"

# Controller /proc/meminfo'yu container içinden okur; docker'da orası HOST
# değerlerini gösterir. Tutmuyorsa boyutlandırma yanlış bir kapasiteye göre
# yapılıyor demektir (yanlış backend, kısıtlı /proc, K8s modu) — ya hiçbir
# motor açılamaz ya da host'a sığmayan limitler dağıtılır.
HOST_TOTAL_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"
PLAN_TOTAL_MB="$(pj "$PLANS" 'list(d["plans"].values())[0].get("host_total_mb", 0)')"
if [ -z "${HOST_TOTAL_MB:-}" ]; then
    HOST_TOTAL_MB=0
    t_skip "plandaki host RAM'i /proc/meminfo ile aynı" "/proc/meminfo okunamadı"
elif [ -n "$PLAN_TOTAL_MB" ] && [ "$PLAN_TOTAL_MB" -gt 0 ] 2>/dev/null \
     && [ "$(( PLAN_TOTAL_MB > HOST_TOTAL_MB ? PLAN_TOTAL_MB - HOST_TOTAL_MB : HOST_TOTAL_MB - PLAN_TOTAL_MB ))" -le 2 ]; then
    t_ok "plandaki host RAM'i ($PLAN_TOTAL_MB MB) /proc/meminfo ile aynı"
else
    t_fail "plandaki host RAM'i /proc/meminfo ile aynı" \
           "plan: ${PLAN_TOTAL_MB:-yok} MB, /proc/meminfo: $HOST_TOTAL_MB MB — controller yanlış kapasiteye göre bellek dağıtıyor"
fi

# Bütçe defteri: RAM − OS payı − çekirdek payı − zaten ayrılmış = bütçe.
# Tutmazsa controller kendi defterini yanlış tutuyordur; sonucu ya sebepsiz
# ret ya da host'u OOM'a sokan aşırı dağıtımdır.
bozuk=""
for eid in $IDS; do
    satir="$(pj "$PLANS" '" ".join(str(d["plans"][E].get(k,"yok")) for k in ("host_total_mb","os_reserve_mb","core_reserve_mb","committed_mb","budget_mb","overhead_mb","engine_budget_mb"))' "$eid")"
    # "yok" = plan bu alanları hiç üretmeden erken dönmüş (host belleği
    # okunamadı gibi). Eksi değer NORMALDİR (bütçe tükenmiş host) ve elenmemeli.
    case "$satir" in *yok*|'') continue ;; esac
    read -r tot osr cor com bud ovh ebud <<EOF
$satir
EOF
    [ "$bud"  -eq "$(( tot - osr - cor - com ))" ] || bozuk="$bozuk $eid(bütçe)"
    [ "$ebud" -eq "$(( bud - ovh ))" ]             || bozuk="$bozuk $eid(motor-bütçesi)"
    # 512 MB'lık bir makinede "1024 MB işletim sistemine ayrıldı" demek bütçeyi
    # eksiye düşürür ve hiçbir motor açılamaz.
    [ "$osr" -le "$(( tot * 6 / 10 + 1 ))" ]       || bozuk="$bozuk $eid(os-payı>%60)"
done
if [ -z "$bozuk" ]; then
    t_ok "plan bütçe aritmetiği tutarlı (RAM − OS payı − çekirdek payı − ayrılmış = bütçe)"
else
    t_fail "plan bütçe aritmetiği tutarlı (RAM − OS payı − çekirdek payı − ayrılmış = bütçe)" \
           "tutmayan:$bozuk"
fi

# Reddedilen her planın sebebi kullanıcıya gösterilir. Boş ya da kriptik sebep,
# veritabanı bilmeyen kullanıcı için "açılmadı, neden bilmiyorum" demektir.
sebepsiz=""; red_sayisi=0
for eid in $IDS; do
    [ "$(pj "$PLANS" 'bool(d["plans"][E].get("ok"))' "$eid")" = "true" ] && continue
    red_sayisi=$((red_sayisi + 1))
    r="$(pj "$PLANS" 'd["plans"][E].get("reason","")' "$eid")"
    [ "${#r}" -ge 25 ] || sebepsiz="$sebepsiz $eid"
done
if [ "$red_sayisi" -eq 0 ]; then
    t_skip "bütçeye sığmayan planlar sebebini yazıyor" \
           "şu an reddedilen motor yok (planların hepsi ok) — ret metni bu koşuda ölçülemedi"
elif [ -z "$sebepsiz" ]; then
    t_ok "bütçeye sığmayan $red_sayisi planın hepsi anlaşılır bir sebep bildiriyor"
else
    t_fail "bütçeye sığmayan $red_sayisi planın hepsi anlaşılır bir sebep bildiriyor" \
           "sebebi boş/çok kısa olan:$sebepsiz"
fi

# Dashboard kartları /api/plans'ı, ayrıntı görünümü /api/engines/<id>/plan'ı
# okuyor. Ayrışırlarsa kullanıcı aynı motor için iki farklı sayı görür ve
# hangisine göre karar vereceğini bilemez.
capraz=""
for eid in $IDS; do
    D="$TMP/plan-$eid.json"
    c="$(api_get "/api/engines/$eid/plan" "$D")"
    if [ "$c" != "200" ]; then capraz="$capraz $eid(HTTP $c)"; continue; fi
    a_ok="$(pj "$PLANS" 'bool(d["plans"][E].get("ok"))' "$eid")"
    b_ok="$(pj "$D"     'bool(d.get("ok"))')"
    a_lim="$(pj "$PLANS" 'd["plans"][E].get("limit_mb",0)' "$eid")"
    b_lim="$(pj "$D"     'd.get("limit_mb",0)')"
    if [ "$a_ok" != "$b_ok" ] || [ "$a_lim" != "$b_lim" ]; then
        # İki çağrı arasında başka bir motor açılmış olabilir (committed
        # değişir). Bir kez tazeleyip tekrar bakıyoruz; hâlâ farklıysa gerçek.
        api_get /api/plans "$PLANS" >/dev/null
        api_get "/api/engines/$eid/plan" "$D" >/dev/null
        a_ok="$(pj "$PLANS" 'bool(d["plans"][E].get("ok"))' "$eid")"
        b_ok="$(pj "$D"     'bool(d.get("ok"))')"
        a_lim="$(pj "$PLANS" 'd["plans"][E].get("limit_mb",0)' "$eid")"
        b_lim="$(pj "$D"     'd.get("limit_mb",0)')"
        if [ "$a_ok" != "$b_ok" ] || [ "$a_lim" != "$b_lim" ]; then
            capraz="$capraz $eid(toplu:$a_lim/$a_ok, detay:$b_lim/$b_ok)"
        fi
    fi
done
if [ -z "$capraz" ]; then
    t_ok "/api/engines/<id>/plan ile /api/plans aynı limiti ve aynı kararı veriyor"
else
    t_fail "/api/engines/<id>/plan ile /api/plans aynı limiti ve aynı kararı veriyor" \
           "ayrışan:$capraz"
fi

# Planın iç ayarları diskteki catalog.json'un formülünden mi çıkıyor?
formul_bozuk=""; formul_atlanan=""
for eid in $IDS; do
    if [ "$(pj "$PLANS" 'bool(d["plans"][E].get("ok"))' "$eid")" != "true" ]; then
        formul_atlanan="$formul_atlanan $eid"; continue
    fi
    lim="$(pj "$PLANS" 'd["plans"][E]["limit_mb"]' "$eid")"
    beklenen="$(python3 "$TMP/tuning_calc.py" "$CATALOG" "$eid" "$lim" 2>/dev/null | tr -d '\r')"
    gelen="$(pj "$PLANS" 'chr(10).join("%s=%s" % (k, d["plans"][E]["tuning"][k]) for k in sorted(d["plans"][E]["tuning"]))' "$eid" | tr -d '\r')"
    [ "$beklenen" = "$gelen" ] || formul_bozuk="$formul_bozuk $eid"
done
if [ -n "$formul_bozuk" ]; then
    t_fail "plandaki iç ayarlar catalog.json formülüyle birebir üretiliyor" \
           "uyuşmayan:$formul_bozuk — controller büyük olasılıkla ESKİ bir catalog.json okuyor (imaja gömülü kopya / kopmuş bind-mount); catalog.json'da yapılan ayar değişikliği hiç uygulanmıyor"
elif [ -n "$formul_atlanan" ]; then
    t_ok "plandaki iç ayarlar catalog.json formülüyle birebir üretiliyor (bütçeye sığmayanlar hariç:$formul_atlanan)"
else
    t_ok "plandaki iç ayarlar catalog.json formülüyle birebir üretiliyor"
fi

# =============================================================================
# 2) HOST BÜTÇESİ AŞILMIŞ MI?
# =============================================================================
heading "2) Host bütçesi"

# Ürünün çekirdek vaadi: açık container limitlerinin toplamı host RAM'ini
# aşmaz. Aştığında hiçbir uyarı çıkmaz; çekirdek ilk bellek baskısında en
# büyük container'ı öldürür ve bunu kullanıcıya kimse söylemez.
RUNNING=""
while IFS= read -r _c; do
    [ -n "$_c" ] && RUNNING="$RUNNING $_c"
done < <(docker ps --filter "label=com.docker.compose.project=$PROJ" --format '{{.Names}}' 2>/dev/null)

if [ -z "$RUNNING" ]; then
    t_skip "açık container limitlerinin toplamı host RAM'ine sığıyor" \
           "'$PROJ' projesine ait çalışan container yok"
    t_skip "açık container'ların hepsinde bellek limiti tanımlı" \
           "'$PROJ' projesine ait çalışan container yok"
else
    toplam_mb=0; limitsiz=""; adet=0
    for c in $RUNNING; do
        adet=$((adet + 1))
        m="$(docker_limit_mb "$c")" || { limitsiz="$limitsiz $c(okunamadı)"; continue; }
        [ "$m" -eq 0 ] && limitsiz="$limitsiz $c"
        toplam_mb=$((toplam_mb + m))
    done
    osr="$(pj "$PLANS" 'list(d["plans"].values())[0].get("os_reserve_mb", 0)')"
    sinir=$(( HOST_TOTAL_MB - ${osr:-0} ))
    if [ "$HOST_TOTAL_MB" -le 0 ]; then
        t_skip "açık container limitlerinin toplamı host RAM'ine sığıyor" "host RAM'i okunamadı"
    elif [ "$toplam_mb" -le "$sinir" ]; then
        t_ok "açık $adet container'ın limit toplamı ($toplam_mb MB) host RAM'ine sığıyor (sınır $sinir MB = RAM − OS payı)"
    else
        t_fail "açık container limitlerinin toplamı host RAM'ine sığıyor" \
               "toplam $toplam_mb MB > sınır $sinir MB (RAM $HOST_TOTAL_MB − OS payı ${osr:-0}) — aşırı dağıtım; ilk yoğunlukta OOM-killer devreye girer"
    fi
    if [ -z "$limitsiz" ]; then
        t_ok "açık $adet container'ın hepsinde bellek limiti tanımlı (sınırsız çalışan yok)"
    else
        t_fail "açık container'ların hepsinde bellek limiti tanımlı (sınırsız çalışan yok)" \
               "limitsiz:$limitsiz — deploy.resources.limits uygulanmamış; bu container host'un tüm belleğini yiyebilir"
    fi
fi

# =============================================================================
# 3) HESAPLANAN LİMİT CONTAINER'A UYGULANMIŞ MI?
# =============================================================================
heading "3) Hesaplanan limit container'a uygulanmış mı?"

TUNING_JSON="$STACK_ROOT/state/tuning.json"

tuning_val() {   # tuning_val <motor> <ENV> → controller'ın kaydettiği değer
    [ -f "$TUNING_JSON" ] || return 1
    pj "$TUNING_JSON" 'd.get(E, {}).get("'"$2"'", "")' "$1"
}

# Hangi motorun hangi iç ayarı ölçülüyor. AYRI bir fonksiyon, çünkü probe_bytes
# komut ikamesi içinde (alt kabukta) çalışır ve orada yapılan değişken atamaları
# çağırana DÖNMEZ — etiketi orada ayarlasaydık her motor "ayar tanımlı değil"
# diye atlanır, yani en can alıcı kontrol sessizce hiç çalışmazdı.
probe_meta() {   # <motor> → "ENV|etiket"  (bu motorda iç ayar yoksa boş)
    case "$1" in
    mariadb)       printf 'MARIADB_BUFFER_POOL|innodb_buffer_pool_size' ;;
    postgresql)    printf 'POSTGRES_SHARED_BUFFERS|shared_buffers' ;;
    mongodb)       printf 'MONGO_WIREDTIGER_CACHE_GB|WiredTiger önbelleği' ;;
    redis)         printf 'REDIS_MAXMEMORY|maxmemory' ;;
    mssql)         printf 'MSSQL_MEMORY_LIMIT_MB|max server memory (MB)' ;;
    cassandra)     printf 'CASSANDRA_HEAP|JVM heap' ;;
    elasticsearch) printf 'ELASTIC_JAVA_OPTS|JVM heap' ;;
    kafka)         printf 'KAFKA_HEAP_OPTS|JVM heap (-Xmx)' ;;
    neo4j)         printf 'NEO4J_HEAP|JVM heap (-Xmx)' ;;
    clickhouse)    printf 'CLICKHOUSE_MAX_MEMORY|max_server_memory_usage' ;;
    esac
}

# Motorun ana bellek ayarını CANLI ölçen sondalar. Host'ta veritabanı istemcisi
# yok; hepsi container'ın kendi istemcisiyle konuşur ve BAYT basar. Boş çıktı
# "ölçemedim" demektir — sessizce 0 sayılmaz.
probe_bytes() {   # probe_bytes <motor> <container> → bayt
    local eid="$1" C="$2" pw out
    case "$eid" in
    mariadb)
        pw="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
        MYSQL_PWD="$pw" TO "$DEX_TIMEOUT" docker exec -e MYSQL_PWD "$C" \
            mariadb -u root -N -B -e "SELECT @@innodb_buffer_pool_size" 2>/dev/null | tr -dc '0-9'
        ;;
    postgresql)
        pw="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
        TO "$DEX_TIMEOUT" docker exec -e PGPASSWORD="$pw" "$C" \
            psql -U "${POSTGRES_USER:-root}" -d postgres -tAc \
            "SELECT setting::bigint * current_setting('block_size')::bigint FROM pg_settings WHERE name='shared_buffers'" \
            2>/dev/null | tr -dc '0-9'
        ;;
    mongodb)
        pw="${MONGO_PASSWORD:-${DB_PASSWORD:-}}"
        TO "$DEX_TIMEOUT" docker exec "$C" "${MONGO_SHELL:-mongosh}" --quiet \
            --username "${MONGO_USER:-root}" --password "$pw" --authenticationDatabase admin \
            --eval 'print(db.serverStatus().wiredTiger.cache["maximum bytes configured"])' \
            2>/dev/null | tr -dc '0-9'
        ;;
    redis)
        pw="${REDIS_PASSWORD:-${DB_PASSWORD:-}}"
        TO "$DEX_TIMEOUT" docker exec -e REDISCLI_AUTH="$pw" "$C" \
            redis-cli --no-auth-warning CONFIG GET maxmemory 2>/dev/null | tail -n 1 | tr -dc '0-9'
        ;;
    mssql)
        pw="${MSSQL_PASSWORD:-${DB_PASSWORD:-}}"
        out="$(SQLCMDPASSWORD="$pw" TO "$DEX_TIMEOUT" docker exec -e SQLCMDPASSWORD "$C" \
               /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -h -1 -W -Q \
               "SET NOCOUNT ON; SELECT CAST(value_in_use AS BIGINT) FROM sys.configurations WHERE name = 'max server memory (MB)'" \
               2>/dev/null | tr -d ' \r' | grep -m1 -E '^[0-9]+$')"
        [ -n "$out" ] && printf '%s' "$((out * 1048576))"    # MB → bayt
        ;;
    cassandra)
        # nodetool info: "Heap Memory (MB) : 245.66 / 1004.00" → tavan ikinci alan
        out="$(TO "$DEX_TIMEOUT" docker exec "$C" nodetool info 2>/dev/null \
               | grep -i 'Heap Memory' | head -1 | awk -F'/' '{gsub(/[^0-9.]/,"",$2); print $2}')"
        [ -n "$out" ] && python3 -c 'import sys;print(int(float(sys.argv[1])*1048576))' "$out" 2>/dev/null
        ;;
    elasticsearch)
        pw="${ELASTIC_PASSWORD:-${DB_PASSWORD:-}}"
        TO "$DEX_TIMEOUT" docker exec "$C" curl -sf -u "elastic:$pw" \
            "http://127.0.0.1:9200/_nodes/_local/jvm?filter_path=nodes.*.jvm.mem.heap_max_in_bytes" \
            2>/dev/null | grep -o '"heap_max_in_bytes":[0-9]*' | head -1 | tr -dc '0-9'
        ;;
    kafka|neo4j)
        # `ps` her imajda yok; /proc her yerde var.
        out="$(TO "$DEX_TIMEOUT" docker exec "$C" sh -c \
               'for p in /proc/[0-9]*/cmdline; do tr "\0" "\n" < "$p" 2>/dev/null; done' \
               2>/dev/null | grep -m1 '^-Xmx')"
        [ -n "$out" ] && size2b "${out#-Xmx}"
        ;;
    clickhouse)
        pw="${CLICKHOUSE_PASSWORD:-${DB_PASSWORD:-}}"
        TO "$DEX_TIMEOUT" docker exec -e CH_PW="$pw" -e CH_USER="${CLICKHOUSE_USER:-default}" "$C" \
            sh -c 'exec clickhouse-client --user "$CH_USER" --password "$CH_PW" --query "$1"' sh \
            "SELECT value FROM system.server_settings WHERE name = 'max_server_memory_usage'" \
            2>/dev/null | tr -dc '0-9'
        ;;
    esac
}

AKTIF_MOTORLAR=""
for eid in $IDS; do
    C="$(primary_container "$eid")"
    ANA_SVC="$(engine_field "$eid" 'e["primary_service"]')"
    ADI="$(engine_field "$eid" 'e["name"]')"
    MEMENV="$(limit_env_of "$eid")"

    # Boş container adıyla devam etmek en tehlikeli sonucu verirdi: container_running ""
    # hiçbir şey bulamaz, motor "kapalı" diye atlanır ve açık bir veritabanı
    # hiç ölçülmeden geçmiş sayılır.
    if [ -z "$C" ] || [ -z "$MEMENV" ]; then
        t_fail "$eid: hesaplanan limit container'a uygulanmış" \
               "katalogdan okunamadı (primary_service='$C', limit env='$MEMENV') — catalog.json bozuk ya da python3 çalışmıyor"
        continue
    fi
    if ! container_running "$C"; then
        t_skip "$eid: hesaplanan limit container'a uygulanmış" \
               "motor kapalı ($C container'ı yok) — kapalı motorda ölçülecek limit yoktur; açmak için: ./stack.sh up $eid"
        continue
    fi
    AKTIF_MOTORLAR="$AKTIF_MOTORLAR $eid"

    gercek_mb="$(docker_limit_mb "$C")"
    if [ -z "${gercek_mb:-}" ]; then
        t_fail "$eid: container limiti controller'ın hesabıyla aynı" "docker inspect $C okunamadı"
        continue
    fi

    # --- (a) tuning.json'daki MEM_LIMIT ↔ container'ın gerçek limiti ---------
    kayit="$(tuning_val "$eid" "$MEMENV")"
    if [ -z "$kayit" ]; then
        t_skip "$eid: container limiti controller'ın yazdığı $MEMENV ile aynı" \
               "state/tuning.json'da bu motorun kaydı yok — motor controller'dan değil, elle 'docker compose up' ile açılmış olabilir (o yolda otomatik boyutlandırma hiç çalışmaz)"
    elif [ "$C" != "$ANA_SVC" ]; then
        t_skip "$eid: container limiti controller'ın yazdığı $MEMENV ile aynı" \
               "devir yapılmış, ana kopya $C — replika compose'da kendi *_REPLICA_MEM_LIMIT değişkenine düşebilir, karşılaştırma yanıltıcı olur"
    else
        bek_b="$(size2b "$kayit")"
        bek_mb=$(( ${bek_b:-0} / 1048576 ))
        if [ "$gercek_mb" -eq 0 ]; then
            t_fail "$eid: container limiti controller'ın yazdığı $MEMENV ile aynı" \
                   "container SINIRSIZ çalışıyor (HostConfig.Memory=0); plan $kayit diyor ama limit hiç uygulanmamış"
        elif [ "$bek_mb" -eq "$gercek_mb" ]; then
            t_ok "$eid: container limiti ($gercek_mb MB) controller'ın hesabıyla ($MEMENV=$kayit) birebir aynı"
        else
            t_fail "$eid: container limiti controller'ın yazdığı $MEMENV ile aynı" \
                   "plan $kayit ($bek_mb MB) diyor, container $gercek_mb MB ile çalışıyor — dashboard'daki sayı ile gerçekte ayrılan bellek farklı"
        fi
    fi

    # --- (b) çekirdek limiti gerçekten uyguluyor mu? ------------------------
    # docker'ın defterinde limit yazması yetmez: cgroup bellek denetleyicisi
    # kapalıysa (bazı çekirdekler, LXC içi docker, eski WSL) docker uyarıyı bir
    # kez basar ve limit hiç uygulanmaz — plan doğru, koruma yoktur.
    cg_mb="$(cgroup_limit_mb "$C")"
    if [ -z "${cg_mb:-}" ]; then
        t_skip "$eid: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
               "$C içinden /sys/fs/cgroup okunamadı (limit 'max' ya da container'da kabuk yok)"
    elif [ "$gercek_mb" -eq 0 ]; then
        # Ölçülemez değil, YANLIŞ: docker limiti hiç yok. Bunu "cgroup tutmuyor"
        # diye raporlamak sebebi gizler; asıl arıza limitin hiç konmamış olması.
        t_fail "$eid: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
               "container'da docker limiti YOK (HostConfig.Memory=0); cgroup $cg_mb MB gösteriyor — motorun belleği sınırlanmamış, host'un tamamını kullanabilir"
    elif [ "$cg_mb" -eq "$gercek_mb" ]; then
        t_ok "$eid: çekirdek cgroup limiti ($cg_mb MB) docker'ın bildirdiğiyle aynı — limit gerçekten uygulanıyor"
    else
        t_fail "$eid: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
               "docker: $gercek_mb MB, cgroup: $cg_mb MB — limit yazılı ama çekirdek uygulamıyor"
    fi

    # --- (c) hesaplanan iç ayarlar container'a gerçekten geçmiş mi? ---------
    INSP="$TMP/inspect-$C.json"
    if TO 20 docker inspect "$C" > "$INSP" 2>/dev/null; then
        AYARLAR="$( [ -f "$TUNING_JSON" ] && pj "$TUNING_JSON" \
                    'chr(10).join("%s=%s" % (k, d.get(E, {})[k]) for k in sorted(d.get(E, {})))' "$eid" | tr -d '\r')"
        gecmeyen=""; bakilan=0
        while IFS='=' read -r k v; do
            [ -n "$k" ] || continue
            case "$k" in *_MEM_LIMIT) continue ;; esac    # (a)'da ölçüldü
            bakilan=$((bakilan + 1))
            python3 "$TMP/cfgmatch.py" "$INSP" "$v" || gecmeyen="$gecmeyen $k=$v"
        done <<EOF
$AYARLAR
EOF
        if [ "$bakilan" -eq 0 ]; then
            t_skip "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" \
                   "state/tuning.json'da bu motor için MEM_LIMIT dışında ayar yok"
        elif [ -z "$gecmeyen" ]; then
            t_ok "$eid: hesaplanan $bakilan iç ayarın hepsi container'ın komutunda/ortamında bulundu"
        else
            t_fail "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" \
                   "container'da bulunmayan:$gecmeyen — compose 'state/tuning.env' okunmadan çalıştırılmış olabilir; motor imaj varsayılanıyla açık"
        fi
    else
        t_fail "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" "docker inspect $C başarısız"
    fi

    # --- (d) motorun CANLI iç ayarı container limitinin altında mı? --------
    IFS='|' read -r probe_env probe_label <<EOF
$(probe_meta "$eid")
EOF
    ic_b="$(probe_bytes "$eid" "$C")"
    if [ -z "$probe_env" ]; then
        t_skip "$eid: motorun iç bellek ayarı container limitinin altında" \
               "katalogda bu motor için iç bellek ayarı tanımlı değil (yalnız $MEMENV); $ADI belleğini kendi yönetiyor"
    elif [ -z "${ic_b:-}" ]; then
        t_fail "$eid: motorun iç bellek ayarı ($probe_label) container limitinin altında" \
               "$C içinden ölçüm alınamadı (istemci/parola/erişim) — ayar DOĞRULANAMADI, geçmiş sayılmıyor"
    elif [ "$gercek_mb" -le 0 ]; then
        t_skip "$eid: motorun iç bellek ayarı ($probe_label) container limitinin altında" \
               "container limitsiz; karşılaştırılacak tavan yok"
    else
        lim_b=$((gercek_mb * 1048576))
        ic_mb=$((ic_b / 1048576))
        # %10 pay şart: motorun ayarı limite eşit ya da çok yakınsa bağlantı
        # tamponları ve sorgu belleği ilk yükte limiti aşırır; cgroup OOM-killer
        # sorguyu değil SÜRECİ öldürür.
        if [ "$ic_b" -gt 0 ] && [ $((ic_b * 10)) -le $((lim_b * 9)) ]; then
            t_ok "$eid: $probe_label = $ic_mb MB, container limitinin ($gercek_mb MB) %$((ic_mb * 100 / gercek_mb))'i — limitin altında"
        else
            t_fail "$eid: motorun iç bellek ayarı ($probe_label) container limitinin altında" \
                   "$probe_label = $ic_mb MB, container limiti $gercek_mb MB — motor limiti aşabilir; cgroup OOM-killer süreci öldürür"
        fi
    fi
done

# =============================================================================
# 4) KLASİK OOM TUZAKLARI (bağlantı başına ayrılan bellek)
# =============================================================================
heading "4) PostgreSQL bellek tuzağı: shared_buffers + work_mem × max_connections"

# work_mem BAĞLANTI BAŞINA ayrılır (üstelik sorgudaki her sıralama/hash için
# ayrı ayrı). shared_buffers + work_mem × max_connections limiti aşıyorsa
# veritabanı boştayken kusursuz görünür, yoğun anda cgroup OOM'una girer.
PG_C="$(primary_container postgresql)"
if container_running "$PG_C"; then
    pgpw="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
    pgq() {
        TO "$DEX_TIMEOUT" docker exec -e PGPASSWORD="$pgpw" "$PG_C" \
            psql -U "${POSTGRES_USER:-root}" -d postgres -tAc "$1" 2>/dev/null | tr -d ' \r'
    }
    sb_b="$(pgq "SELECT setting::bigint*current_setting('block_size')::bigint FROM pg_settings WHERE name='shared_buffers'")"
    wm_b="$(pgq "SELECT setting::bigint*1024 FROM pg_settings WHERE name='work_mem'")"
    conns="$(pgq "SELECT setting FROM pg_settings WHERE name='max_connections'")"
    lim_mb="$(docker_limit_mb "$PG_C")"
    okunabilir=1
    for _v in "${sb_b:-}" "${wm_b:-}" "${conns:-}"; do
        case "$_v" in ''|*[!0-9]*) okunabilir=0 ;; esac
    done
    if [ "$okunabilir" -eq 0 ]; then
        t_fail "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
               "canlı değerler okunamadı (shared_buffers=${sb_b:-yok}, work_mem=${wm_b:-yok}, max_connections=${conns:-yok})"
    else
        if [ "${lim_mb:-0}" -le 0 ]; then
            t_skip "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
                   "container limitsiz; karşılaştırılacak tavan yok"
        else
            top_mb=$(( (sb_b + wm_b * conns) / 1048576 ))
            if [ "$top_mb" -lt "$lim_mb" ]; then
                t_ok "postgresql: shared_buffers($((sb_b / 1048576)) MB) + work_mem($((wm_b / 1048576)) MB) × $conns bağlantı = $top_mb MB, container limitinin ($lim_mb MB) altında"
            else
                t_fail "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
                       "en kötü durumda $top_mb MB gerekiyor, container limiti $lim_mb MB — bağlantılar aynı anda sorgu çalıştırdığında OOM"
            fi
        fi
    fi
else
    t_skip "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
           "PostgreSQL kapalı ($PG_C container'ı yok) — canlı ayar okunamaz"
fi

# Motor kapalıyken bile PLAN doğrulanabilir: tuzak aktivasyondan ÖNCE, hesabın
# içinde vardır. Böylece "açılsaydı OOM olurdu" durumu da yakalanır.
if [ "$(pj "$PLANS" 'bool(d["plans"]["postgresql"].get("ok"))')" = "true" ]; then
    p_lim="$(pj "$PLANS" 'd["plans"]["postgresql"]["limit_mb"]')"
    p_sb="$(size2b "$(pj "$PLANS" 'd["plans"]["postgresql"]["tuning"].get("POSTGRES_SHARED_BUFFERS","")')")"
    p_wm="$(size2b "$(pj "$PLANS" 'd["plans"]["postgresql"]["tuning"].get("POSTGRES_WORK_MEM","")')")"
    p_mc="$(pj "$PLANS" 'd["plans"]["postgresql"]["tuning"].get("POSTGRES_MAX_CONNECTIONS","0")')"
    if [ -n "${p_sb:-}" ] && [ -n "${p_wm:-}" ] && [ "${p_mc:-0}" -gt 0 ] 2>/dev/null; then
        p_top=$(( (p_sb + p_wm * p_mc) / 1048576 ))
        if [ "$p_top" -lt "$p_lim" ]; then
            t_ok "postgresql planı: shared_buffers + work_mem × $p_mc bağlantı = $p_top MB, planlanan limitin ($p_lim MB) altında"
        else
            t_fail "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
                   "plan en kötü durumda $p_top MB istiyor ama limit $p_lim MB — bu planla açılan PostgreSQL yük altında OOM olur"
        fi
    else
        t_fail "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
               "planda POSTGRES_SHARED_BUFFERS / WORK_MEM / MAX_CONNECTIONS eksik"
    fi
else
    t_skip "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
           "PostgreSQL planı reddedilmiş: $(pj "$PLANS" 'd["plans"]["postgresql"].get("reason","")')"
fi

# Neo4j aynı tuzağın ikinci örneği: heap JVM'in İÇİNDE, pagecache DIŞINDA
# ayrılır. İkisi tek tek limite sığsa bile toplamları sığmayabilir.
NEO_C="$(primary_container neo4j)"
if container_running "$NEO_C"; then
    neo_xmx="$(TO "$DEX_TIMEOUT" docker exec "$NEO_C" sh -c \
               'for p in /proc/[0-9]*/cmdline; do tr "\0" "\n" < "$p" 2>/dev/null; done' 2>/dev/null \
               | grep -m1 '^-Xmx')"
    heap_b="$(size2b "${neo_xmx#-Xmx}")"
    pc_raw="$(TO 20 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NEO_C" 2>/dev/null \
              | sed -n 's/^NEO4J_server_memory_pagecache_size=//p' | head -1 | tr -d '\r')"
    pc_b="$(size2b "$pc_raw")"
    neo_lim="$(docker_limit_mb "$NEO_C")"
    if [ -z "${heap_b:-}" ] || [ -z "${pc_b:-}" ] || [ "${neo_lim:-0}" -le 0 ]; then
        t_skip "neo4j: JVM heap + pagecache container limitinin altında" \
               "heap ya da pagecache okunamadı (heap=${neo_xmx:-yok}, pagecache=${pc_raw:-yok}, limit=${neo_lim:-0} MB)"
    else
        neo_top=$(( (heap_b + pc_b) / 1048576 ))
        if [ $((neo_top * 100)) -le $((neo_lim * 90)) ]; then
            t_ok "neo4j: heap + pagecache = $neo_top MB, container limitinin ($neo_lim MB) altında"
        else
            t_fail "neo4j: JVM heap + pagecache container limitinin altında" \
                   "heap+pagecache $neo_top MB, limit $neo_lim MB — pagecache JVM heap'in DIŞINDA ayrılır; toplam limiti aşınca OOM"
        fi
    fi
else
    t_skip "neo4j: JVM heap + pagecache container limitinin altında" \
           "Neo4j kapalı ($NEO_C container'ı yok)"
fi

# =============================================================================
# 5) BÜTÇE DOLUNCA AKTİVASYON REDDEDİLİYOR MU?
# =============================================================================
heading "5) Bütçe aşımında aktivasyon reddi"

# KAPALI bir motor seçiyoruz: ret ÇALIŞMAZSA en kötü ihtimalle küçük bir motor
# açılır (ve aşağıda betik onu kendisi kapatır). Açık bir motorda denemek onu
# yeniden boyutlandırma riski taşırdı — canlı veritabanını yeniden yaratmak
# testin işi değil.
hedef=""
for tercih in minio monitoring rabbitmq; do
    for eid in $IDS; do
        [ "$eid" = "$tercih" ] || continue
        container_running "$(primary_container "$eid")" || hedef="$eid"
    done
    [ -n "$hedef" ] && break
done
if [ -z "$hedef" ]; then
    for eid in $IDS; do
        container_running "$(primary_container "$eid")" || { hedef="$eid"; break; }
    done
fi

# İstenecek miktar SIFIR OLAMAZ. Controller `if requested_mb:` diye bakar; 0
# gönderirsek "istek yok" sayılır, plan otomatik moda düşer ve motor GERÇEKTEN
# AÇILIR. Ret testi yaparken canlı sunucuda motor açmak, bu testin yapabileceği
# en kötü şeydir — kaynak RAM okunamadıysa istek hiç gönderilmez.
ram_ref="${HOST_TOTAL_MB:-0}"
[ "$ram_ref" -gt 0 ] 2>/dev/null || ram_ref="${PLAN_TOTAL_MB:-0}"
istenen=$(( ram_ref * 8 ))      # host RAM'inin 8 katı: hiçbir bütçeye sığmaz

atla=""
if [ -n "${SIZING_SKIP_REFUSAL:-}" ]; then
    atla="SIZING_SKIP_REFUSAL ayarlı — test istenerek atlandı"
elif [ -z "$hedef" ]; then
    atla="katalogdaki motorların hepsi açık; denemeye uygun kapalı motor yok (açık bir motorda denemek onu yeniden boyutlandırırdı)"
elif [ "$istenen" -le 0 ] 2>/dev/null; then
    atla="host RAM'i okunamadı; bütçeyi kesin aşan bir miktar hesaplanamıyor ve 0 göndermek motoru gerçekten açardı"
fi

if [ -n "$atla" ]; then
    t_skip "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır" "$atla"
    t_skip "reddedilen aktivasyon hiçbir container yaratmıyor" "$atla"
else
    HC="$(primary_container "$hedef")"
    log "hedef: $hedef ($HC) — $istenen MB isteniyor (host RAM'inin 8 katı); RET bekleniyor"
    RESP="$TMP/activate.json"
    code="$(api_post "/api/engines/$hedef/activate" "{\"memory_mb\": $istenen}" "$RESP")"
    job="$(pj "$RESP" 'd.get("job","")')"
    if [ "$code" != "202" ] || [ -z "$job" ]; then
        t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                "istek işe bile dönüşmedi: HTTP $code — $(head -c 200 "$RESP" 2>/dev/null | tr -d '
')"
        t_skip "reddedilen aktivasyon hiçbir container yaratmıyor" "iş hiç başlamadı"
    else
        # Sonsuz bekleme yok. İş JOB_TIMEOUT içinde sonuçlanmazsa bu da arızadır:
        # dashboard'da sonsuza dek "devam ediyor" gösteren iş gerçek bir hataydı.
        durum="running"; sebep=""; gecen=0
        while [ "$durum" = "running" ] && [ "$gecen" -lt "$JOB_TIMEOUT" ]; do
            sleep 2; gecen=$((gecen + 2))
            api_get "/api/jobs/$job" "$TMP/job.json" >/dev/null
            durum="$(pj "$TMP/job.json" 'd.get("state","running")')"
            sebep="$(pj "$TMP/job.json" 'd.get("reason","")')"
            [ $((gecen % 20)) -eq 0 ] && log "  '$hedef' aktivasyon işi bekleniyor (${gecen}s/${JOB_TIMEOUT}s), durum: $durum"
        done
        if [ -z "$durum" ]; then
            t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                    "iş durumu okunamadı (/api/jobs/$job cevap vermedi) — ret doğrulanamadı"
        elif [ "$durum" = "running" ]; then
            t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                    "iş $JOB_TIMEOUT saniyede sonuçlanmadı, hâlâ 'running' — kullanıcı sonuç göremeden bekler"
        elif [ "$durum" = "done" ]; then
            t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                    "$istenen MB istendi ve iş BAŞARILI döndü — bütçe denetimi devrede değil, host aşırı dağıtılıyor"
        elif [ "${#sebep}" -ge 25 ] && printf '%s' "$sebep" | grep -q 'MB'; then
            t_ok "bütçeyi aşan istek ($hedef, $istenen MB) reddedildi ve sebep MB cinsinden açıklandı: $sebep"
        else
            t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                    "reddedildi ama sebep kullanıcıya bir şey anlatmıyor: '${sebep:-boş}'"
        fi

        # Ret gerçekten "hiçbir şey yapılmadı" mı? Yarım kalmış bir container
        # hem bütçe defterini bozar hem de kapalı sanılan bir port açar.
        sleep 1
        if container_running "$HC"; then
            t_fail "reddedilen aktivasyon hiçbir container yaratmıyor"                    "$HC ayağa kalkmış — ret yolunda yan etki var; betik açtığını kapatıyor"
            # TEMİZLİK: betiğin dokunduğu hiçbir şey geride kalmaz.
            api_post "/api/engines/$hedef/deactivate" '{}' "$TMP/deact.json" >/dev/null
            warn "$hedef için durdurma isteği gönderildi (betik kendi yan etkisini temizliyor)"
        else
            t_ok "reddedilen aktivasyon hiçbir container yaratmadı ($HC hâlâ kapalı)"
        fi
    fi
fi

# =============================================================================
# ÖZET
# =============================================================================
[ -n "$AKTIF_MOTORLAR" ] || \
    warn "Hiçbir veritabanı motoru açık değil — container üzerinden yapılan ölçümlerin hepsi atlandı. Gerçek doğrulama için en az bir motoru açın: ./stack.sh up mariadb"
ozet_ve_cik
