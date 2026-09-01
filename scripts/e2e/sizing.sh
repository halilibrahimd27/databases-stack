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
# Sayaçlar, sonuç bildirimi ve ÇIKIŞ KODU ortak kütüphanede — paketin kendi
# kopyası YOK. Eski hâlde bu betiğin üç sonuç türü vardı (geçti/kaldı/atlandı)
# ve "ölçemedik" için yeri olmadığından ölçüm aracı bozulduğunda kontrol ya
# atlanıyor ya da geçmiş sayılıyordu. lib.sh dördüncü türü getiriyor:
# t_unknown = ölçemedik, BAŞARISIZ sayılır.
source scripts/e2e/lib.sh
E2E_SUITE="sizing"

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
# Temizlik YALNIZ EXIT üzerinde. INT/TERM lib.sh'in: kesilen koşu "geçti"
# sayılmasın diye 130 ile çıkıyor. Buraya INT/TERM yazmak o trap'i ezer ve
# Ctrl-C'yi sessiz bir başarıya çevirirdi; exit 130 zaten EXIT'i tetikleyeceği
# için geçici dizin yine siliniyor.
trap 'rm -rf "$TMP"' EXIT

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

# pj'nin KATI biçimi. pj alan yoksa/python düşerse BOŞ dizge basar ve komut
# ikamesi çıkış kodunu yutar: `x="$(pj ...)"` sonrası x="" ile "alan gerçekten
# boş" ayırt edilemez. Denetimde bulunan sessiz-yeşillerin çoğu buradan çıktı —
# iki tarafı da boş olan bir karşılaştırma "aynı" diye GEÇTİ yazıyordu.
pjq() {   # pjq <dosya> <ifade> [motor] → değer; okunamazsa/boşsa rc=1
    local v
    v="$(pj "$@")" || return 1
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

tamsayi_mi() {   # eksi değerler plan defterinde NORMALDİR (bütçe tükenmiş host)
    case "${1:-}" in
        ''|-) return 1 ;;
        -*) case "${1#-}" in ''|*[!0-9]*) return 1 ;; esac ;;
        *)  case "$1"     in    *[!0-9]*) return 1 ;; esac ;;
    esac
    return 0
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

# Boru hattında çıkış kodu SON komuttan gelir; `python3 ... | tr` kalıbında
# python çökse bile tr 0 döndürür ve motor listesi SESSİZCE boşalır. Boş liste
# bu betikte felakettir: her `for eid in $IDS` döngüsü sıfır kez döner, hiçbir
# şey ölçülmez ve tek bir kırmızı satır bile çıkmaz. Bu yüzden önce yakalayıp
# çıkış kodunu kontrol ediyoruz, sonra \r atıyoruz.
engine_ids() {
    local out
    out="$(python3 -c 'import json,sys;print("\n".join(e["id"] for e in json.load(open(sys.argv[1],encoding="utf-8"))["engines"]))' \
           "$CATALOG" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out" | tr -d '\r'
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

# -------------------------- yardımcı: limit env'i HANGİ container'a uygulanıyor
# Katalogdaki primary_service ile limit env'inin bağlandığı servis AYNI DEĞİL
# olabilir: monitoring'in primary_service'i grafana, limit env'i ise
# PROMETHEUS_MEM_LIMIT ve compose'da o değişken prometheus container'ına bağlı
# (grafana kendi GRAFANA_MEM_LIMIT'inde). İkisini karıştıran eski kontrol,
# sapasağlam bir yığında bile "plan 1303M diyor, container 256 MB ile çalışıyor"
# diye KALDI yazıyordu; daha kötüsü, controller'ın gerçekten boyutlandırdığı
# prometheus HİÇ ölçülmüyordu.
# Doğrusu tahmin değil, compose'un kendisi: deploy.resources.limits.memory
# satırındaki İLK ${DEĞİŞKEN} hangi servisin altındaysa limit o container'a
# uygulanır. (İlk olması şart: replika satırları
# "${X_REPLICA_MEM_LIMIT:-${X_MEM_LIMIT:-8G}}" biçiminde yedekli yazılıyor.)
cat > "$TMP/limitsvc.py" <<'PY'
import re, sys

compose, env = sys.argv[1], sys.argv[2]
bolum, servis = None, None
adlar, bulunan = {}, []
for line in open(compose, encoding="utf-8"):
    line = line.rstrip("\n").rstrip("\r")
    m = re.match(r"^([A-Za-z0-9_-]+):", line)
    if m:                                  # üst düzey bölüm (services/volumes/…)
        bolum, servis = m.group(1), None
        continue
    if bolum != "services":
        continue
    m = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
    if m:
        servis = m.group(1)
        continue
    if servis is None:
        continue
    m = re.match(r"^\s+container_name:\s*(\S+)", line)
    if m:
        adlar[servis] = m.group(1)
        continue
    m = re.match(r"^\s+memory:\s*(\S.*)$", line)
    if m:
        ilk = re.search(r"\$\{([A-Za-z0-9_]+)", m.group(1))
        if ilk and ilk.group(1) == env:
            bulunan.append(servis)
if len(bulunan) != 1:      # hiç yok ya da birden çok servis → tahmin etmiyoruz
    sys.exit(1)
s = bulunan[0]
sys.stdout.write("%s %s" % (s, adlar.get(s, s)))
PY

limit_service_of() {   # <ENV adı> → "servis container_adı"  (çözülemezse rc=1)
    local out
    out="$(python3 "$TMP/limitsvc.py" "$COMPOSE_FILE" "$1" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    printf '%s' "$out" | tr -d '\r'
}

engine_services() {   # <motor> → compose servis adları (boşlukla ayrılmış)
    engine_field "$1" '" ".join(e.get("services", []))'
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
# 000 = curl hiç bağlanamadı, 5xx = sunucu kendi hatası. İkisi de "ürün yanlış
# davrandı" değil, "ölçemedik" demektir; ayırt etmezsek cevapsız bir controller
# uydurma bir ürün arızası gibi raporlanır.
http_cevapsiz() {
    case "${1:-000}" in 000|5*) return 0 ;; esac
    return 1
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

# Çekirdeğin cgroup dosyasını HAM basar. Eski hâli sayıya çeviriyor ve sayısal
# olmayan her şeye (yani "max"a da) 1 dönüyordu; çağıran taraf da bunu
# "ölçemedim" sayıp ATLANDI yazıyordu. Oysa docker limiti 6515 MB iken
# memory.max = "max" olması bu kontrolün VAR OLUŞ SEBEBİDİR: limit defterde
# yazılı, çekirdek uygulamıyor, koruma yok. "Ölçemedim" ile "çekirdek
# uygulamıyor" aynı satırda birleşince arıza gizleniyordu.
#
# rc 0 → ham değer okundu ("max" ya da bayt)
# rc 2 → container'da kabuk yok; bu yöntemle ölçülemez (ön koşul eksik)
# rc 1 → docker exec düştü / dosya okunamadı (ÖLÇEMEDİK)
cgroup_raw() {   # <container> → memory.max ham içeriği
    local out v
    out="$(TO "$DEX_TIMEOUT" docker exec "$1" sh -c \
          'echo __KABUK_VAR__; cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' \
          2>&1)"
    case "$out" in
        *__KABUK_VAR__*) ;;
        *"executable file not found"*|*"no such file or directory"*|*"not found in \$PATH"*)
            return 2 ;;      # imajda sh yok (distroless): yöntem uygulanamıyor
        *) return 1 ;;       # docker cevap vermedi / container kayboldu
    esac
    v="$(printf '%s\n' "$out" | tr -d '\r' | sed -n '/__KABUK_VAR__/{n;p;}' | head -1)"
    [ -n "$v" ] || return 1  # kabuk çalıştı ama dosya okunamadı → ölçemedik
    printf '%s' "$v"
}

# cgroup v1'de "limitsiz" 9223372036854771712 gibi bir sentinel sayıyla
# gösterilir; v2'de "max". İkisi de aynı şey demek: çekirdek limit uygulamıyor.
cgroup_limitsiz_mi() {   # <ham değer>
    case "${1:-}" in
        max|MAX) return 0 ;;
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 4611686018427387904 ]
}

# =============================================================================
# 0) ÖN KOŞULLAR
# =============================================================================
heading "0) Ön koşullar"

# İLK KONTROL DOCKER'IN KENDİSİ. container_running, docker cevap vermediğinde
# de "hayır" der: daemon kapalıyken bu paket 13 motorun 13'üne "kapalı, atlandı"
# yazıp hiçbir şey ölçmeden biterdi. Ölçüm aracı çalışmıyorsa ölçüm yok.
if docker ps --format '{{.Names}}' >/dev/null 2>&1; then
    t_ok "docker arayüzü cevap veriyor (bütün container ölçümlerinin ön koşulu)"
else
    t_unknown "docker arayüzü cevap veriyor (bütün container ölçümlerinin ön koşulu)" \
              "docker ps başarısız — bu hâlde her container 'kapalı' sanılır ve paketin tamamı sessizce atlanırdı; ölçüm yapılmadı"
    e2e_finish; exit $?
fi

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
if [ "$code" = "200" ] && pjq "$PLANS" 'd["plans"]' >/dev/null; then
    t_ok "gateway üzerinden /api/plans 200 döndürüyor ve JSON çözümleniyor"
else
    t_fail "gateway üzerinden /api/plans 200 döndürüyor ve JSON çözümleniyor" \
           "HTTP $code — gövde: $(head -c 200 "$PLANS" 2>/dev/null | tr -d '\n')"
    # Buradan sonrası ölçülemedi: karşılaştırılacak hesap yok. ATLANDI demek
    # "ölçmemize gerek yoktu" demek olurdu; oysa ölçmemiz gerekiyordu ve
    # ölçemedik.
    t_unknown "boyutlandırmanın geri kalanı" \
              "plan API'si okunamadı; container limitleri hangi hesapla karşılaştırılacaktı bilinmiyor"
    e2e_finish; exit $?
fi

# Motor listesi boşsa aşağıdaki her `for eid in $IDS` döngüsü SIFIR kez döner:
# tek bir kırmızı satır çıkmadan paketin tamamı ölçüm yapmamış olur. Bu yüzden
# burada duruyoruz.
if ! IDS="$(engine_ids)"; then
    t_unknown "catalog.json'daki motor listesi okunuyor" \
              "$CATALOG okunamadı ya da python3 çözümleyemedi — motor başına hiçbir kontrol çalıştırılamaz"
    e2e_finish; exit $?
fi
N_CAT="$(printf '%s\n' "$IDS" | grep -c .)"
if N_PLAN="$(pjq "$PLANS" 'len(d["plans"])')"; then
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
else
    t_unknown "/api/plans katalogdaki $N_CAT kaydın hepsi için plan üretiyor" \
              "cevaptaki plans sözlüğü sayılamadı — JSON beklenen biçimde değil"
fi

# =============================================================================
# 1) PLANIN DAYANDIĞI ÖLÇÜLER
# =============================================================================
heading "1) Planın dayandığı ölçüler"

# Controller /proc/meminfo'yu container içinden okur; docker'da orası HOST
# değerlerini gösterir. Tutmuyorsa boyutlandırma yanlış bir kapasiteye göre
# yapılıyor demektir (yanlış backend, kısıtlı /proc, K8s modu) — ya hiçbir
# motor açılamaz ya da host'a sığmayan limitler dağıtılır.
HOST_TOTAL_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null | tr -dc '0-9')"
PLAN_TOTAL_MB="$(pj "$PLANS" 'list(d["plans"].values())[0].get("host_total_mb", 0)')"
if ! tamsayi_mi "${HOST_TOTAL_MB:-}"; then
    # /proc/meminfo bu kontrolün ÖLÇÜ ARACI. Yoksa karşılaştıracak referans
    # yok demektir; "ön koşul eksik" değil, ölçemedik. Aşağıdaki bütçe sınırı
    # ve ret testi de aynı sayıya dayandığı için 0'a düşürüyoruz.
    HOST_TOTAL_MB=0
    t_unknown "plandaki host RAM'i /proc/meminfo ile aynı" \
              "/proc/meminfo okunamadı — controller'ın bildirdiği kapasite hiçbir şeyle karşılaştırılamadı"
elif ! tamsayi_mi "${PLAN_TOTAL_MB:-}" || [ "$PLAN_TOTAL_MB" -le 0 ]; then
    t_fail "plandaki host RAM'i /proc/meminfo ile aynı" \
           "plan host_total_mb alanını üretmiyor (gelen: '${PLAN_TOTAL_MB:-yok}'), /proc/meminfo: $HOST_TOTAL_MB MB — controller host belleğini hiç okuyamamış olabilir"
elif [ "$(( PLAN_TOTAL_MB > HOST_TOTAL_MB ? PLAN_TOTAL_MB - HOST_TOTAL_MB : HOST_TOTAL_MB - PLAN_TOTAL_MB ))" -le 2 ]; then
    t_ok "plandaki host RAM'i ($PLAN_TOTAL_MB MB) /proc/meminfo ile aynı"
else
    t_fail "plandaki host RAM'i /proc/meminfo ile aynı" \
           "plan: $PLAN_TOTAL_MB MB, /proc/meminfo: $HOST_TOTAL_MB MB — controller yanlış kapasiteye göre bellek dağıtıyor"
fi

# Bütçe defteri: RAM − OS payı − çekirdek payı − zaten ayrılmış = bütçe.
# Tutmazsa controller kendi defterini yanlış tutuyordur; sonucu ya sebepsiz
# ret ya da host'u OOM'a sokan aşırı dağıtımdır.
bozuk=""; defter_bakilan=0; defter_eksik=""
for eid in $IDS; do
    satir="$(pj "$PLANS" '" ".join(str(d["plans"][E].get(k,"yok")) for k in ("host_total_mb","os_reserve_mb","core_reserve_mb","committed_mb","budget_mb","overhead_mb","engine_budget_mb"))' "$eid")"
    # "yok" = plan bu alanları hiç üretmeden erken dönmüş (host belleği
    # okunamadı gibi). Eksi değer NORMALDİR (bütçe tükenmiş host) ve elenmemeli.
    # Eskiden burada sessizce `continue` ediliyordu: alanlar HİÇBİR planda
    # yoksa döngü tek karşılaştırma yapmadan bitiyor ve aşağıdaki `-z "$bozuk"`
    # dalı GEÇTİ yazıyordu. Sıfır karşılaştırma "tutarlı" demek değildir.
    case "$satir" in *yok*|'') defter_eksik="$defter_eksik $eid"; continue ;; esac
    read -r tot osr cor com bud ovh ebud <<EOF
$satir
EOF
    _sayisal=1
    for _v in "$tot" "$osr" "$cor" "$com" "$bud" "$ovh" "$ebud"; do
        tamsayi_mi "$_v" || _sayisal=0
    done
    if [ "$_sayisal" -eq 0 ]; then
        # Alan var ama sayı değil: `[ x -eq y ]` burada hata verip 2 döndürür ve
        # "|| bozuk=..." dalı bunu ARIZA sanardı. Ölçemedik demek daha doğru.
        defter_eksik="$defter_eksik $eid(sayısal-değil)"; continue
    fi
    defter_bakilan=$((defter_bakilan + 1))
    [ "$bud"  -eq "$(( tot - osr - cor - com ))" ] || bozuk="$bozuk $eid(bütçe)"
    [ "$ebud" -eq "$(( bud - ovh ))" ]             || bozuk="$bozuk $eid(motor-bütçesi)"
    # 512 MB'lık bir makinede "1024 MB işletim sistemine ayrıldı" demek bütçeyi
    # eksiye düşürür ve hiçbir motor açılamaz.
    [ "$osr" -le "$(( tot * 6 / 10 + 1 ))" ]       || bozuk="$bozuk $eid(os-payı>%60)"
done
if [ -n "$bozuk" ]; then
    t_fail "plan bütçe aritmetiği tutarlı (RAM − OS payı − çekirdek payı − ayrılmış = bütçe)" \
           "tutmayan:$bozuk"
elif [ "$defter_bakilan" -eq 0 ]; then
    t_unknown "plan bütçe aritmetiği tutarlı (RAM − OS payı − çekirdek payı − ayrılmış = bütçe)" \
              "hiçbir planda defter alanları (budget_mb/os_reserve_mb/…) yok — tek bir karşılaştırma bile yapılamadı:$defter_eksik"
elif [ -n "$defter_eksik" ]; then
    t_ok "plan bütçe aritmetiği $defter_bakilan planda tutarlı (alanları üretmeyenler hariç:$defter_eksik)"
else
    t_ok "plan bütçe aritmetiği $defter_bakilan planın hepsinde tutarlı (RAM − OS payı − çekirdek payı − ayrılmış = bütçe)"
fi

# Reddedilen her planın sebebi kullanıcıya gösterilir. Boş ya da kriptik sebep,
# veritabanı bilmeyen kullanıcı için "açılmadı, neden bilmiyorum" demektir.
sebepsiz=""; red_sayisi=0; karar_okunamayan=""
for eid in $IDS; do
    # Kararın kendisi okunamıyorsa (motorun planı hiç yok) bunu "reddedilmiş"
    # saymak yanlış olurdu: ölçemediğimizi ret sanıp sebep ararken uydurma bir
    # başarısızlık üretirdik.
    if ! karar="$(pjq "$PLANS" 'bool(d["plans"][E].get("ok"))' "$eid")"; then
        karar_okunamayan="$karar_okunamayan $eid"; continue
    fi
    [ "$karar" = "true" ] && continue
    red_sayisi=$((red_sayisi + 1))
    r="$(pj "$PLANS" 'd["plans"][E].get("reason","")' "$eid")"
    [ "${#r}" -ge 25 ] || sebepsiz="$sebepsiz $eid"
done
if [ -n "$karar_okunamayan" ] && [ "$red_sayisi" -eq 0 ]; then
    t_unknown "bütçeye sığmayan planlar sebebini yazıyor" \
              "planı okunamayan motorlar var ($karar_okunamayan); ret metni ölçülemedi"
elif [ "$red_sayisi" -eq 0 ]; then
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
# Dört alanı da KATI okuyoruz. Eski hâlde tazeleme çağrısının HTTP kodu hiç
# bakılmıyordu: tazeleme düşerse plans.json bozulur, dört pj çağrısının dördü
# de boş döner, ""="" karşılaştırması "aynı" çıkar ve 999 MB'lık GERÇEK bir
# ayrışma GEÇTİ olarak raporlanırdı — özet sağlıklı koşudan ayırt edilemezdi.
capraz_oku() {   # <motor> → "a_ok a_lim b_ok b_lim"; biri bile okunamazsa rc=1
    local eid="$1" dosya="$2" ao al bo bl
    ao="$(pjq "$PLANS" 'bool(d["plans"][E].get("ok"))' "$eid")" || return 1
    al="$(pjq "$PLANS" 'd["plans"][E].get("limit_mb",0)' "$eid")" || return 1
    bo="$(pjq "$dosya" 'bool(d.get("ok"))')" || return 1
    bl="$(pjq "$dosya" 'd.get("limit_mb",0)')" || return 1
    printf '%s %s %s %s' "$ao" "$al" "$bo" "$bl"
}

capraz=""; capraz_olcum=""; capraz_bakilan=0
for eid in $IDS; do
    D="$TMP/plan-$eid.json"
    c="$(api_get "/api/engines/$eid/plan" "$D")"
    if [ "$c" != "200" ]; then
        # Uç nokta cevap vermediyse KARŞILAŞTIRMA YAPILMADI. Bunu "ayrışıyor"
        # diye yazmak da yanlış olurdu; ölçemedik.
        capraz_olcum="$capraz_olcum $eid(HTTP $c)"; continue
    fi
    if ! okuma="$(capraz_oku "$eid" "$D")"; then
        capraz_olcum="$capraz_olcum $eid(alan-yok)"; continue
    fi
    read -r a_ok a_lim b_ok b_lim <<EOF
$okuma
EOF
    if [ "$a_ok" != "$b_ok" ] || [ "$a_lim" != "$b_lim" ]; then
        # İki çağrı arasında başka bir motor açılmış olabilir (committed
        # değişir). Bir kez tazeleyip tekrar bakıyoruz; hâlâ farklıysa gerçek.
        # Tazelemenin KENDİSİ başarısızsa ayrışmayı doğrulayamayız → ölçemedik.
        # Tazelemeyi ÖNCE geçici dosyaya alıyoruz: 500 dönen bir cevap
        # plans.json'un üstüne yazılırsa kalan 12 motorun karşılaştırması da
        # çöker ve tek bir arıza koca bir kör nokta yaratır.
        c1="$(api_get /api/plans "$TMP/plans-yeni.json")"
        c2="$(api_get "/api/engines/$eid/plan" "$TMP/plan-yeni.json")"
        if [ "$c1" = "200" ] && pjq "$TMP/plans-yeni.json" 'd["plans"]' >/dev/null; then
            cp "$TMP/plans-yeni.json" "$PLANS"
        fi
        [ "$c2" = "200" ] && cp "$TMP/plan-yeni.json" "$D"
        if [ "$c1" != "200" ] || [ "$c2" != "200" ]; then
            capraz_olcum="$capraz_olcum $eid(tazeleme HTTP $c1/$c2, ilk okumada ayrışıktı: $a_lim/$a_ok≠$b_lim/$b_ok)"
            continue
        fi
        if ! okuma="$(capraz_oku "$eid" "$D")"; then
            capraz_olcum="$capraz_olcum $eid(tazeleme sonrası alan-yok, ilk okumada ayrışıktı: $a_lim/$a_ok≠$b_lim/$b_ok)"
            continue
        fi
        read -r a_ok a_lim b_ok b_lim <<EOF
$okuma
EOF
        if [ "$a_ok" != "$b_ok" ] || [ "$a_lim" != "$b_lim" ]; then
            capraz="$capraz $eid(toplu:$a_lim/$a_ok, detay:$b_lim/$b_ok)"
            continue
        fi
    fi
    capraz_bakilan=$((capraz_bakilan + 1))
done
if [ -n "$capraz" ]; then
    t_fail "/api/engines/<id>/plan ile /api/plans aynı limiti ve aynı kararı veriyor" \
           "ayrışan:$capraz${capraz_olcum:+ · ayrıca ölçülemeyen:$capraz_olcum}"
elif [ -n "$capraz_olcum" ]; then
    t_unknown "/api/engines/<id>/plan ile /api/plans aynı limiti ve aynı kararı veriyor" \
              "karşılaştırılamayan:$capraz_olcum (karşılaştırılabilen $capraz_bakilan motorda fark yok)"
elif [ "$capraz_bakilan" -eq 0 ]; then
    t_unknown "/api/engines/<id>/plan ile /api/plans aynı limiti ve aynı kararı veriyor" \
              "tek bir motor bile karşılaştırılamadı"
else
    t_ok "/api/engines/<id>/plan ile /api/plans $capraz_bakilan motorda aynı limiti ve aynı kararı veriyor"
fi

# Planın iç ayarları diskteki catalog.json'un formülünden mi çıkıyor?
formul_bozuk=""; formul_atlanan=""; formul_olcumsuz=""; formul_bakilan=0
for eid in $IDS; do
    if [ "$(pj "$PLANS" 'bool(d["plans"][E].get("ok"))' "$eid")" != "true" ]; then
        # Reddedilen planın tuning'i yoktur: karşılaştıracak bir şey yok.
        formul_atlanan="$formul_atlanan $eid"; continue
    fi
    if ! lim="$(pjq "$PLANS" 'd["plans"][E]["limit_mb"]' "$eid")" || ! tamsayi_mi "$lim"; then
        formul_olcumsuz="$formul_olcumsuz $eid(limit_mb yok)"; continue
    fi
    # Boru hattı yerine önce yakala, sonra \r at: `python3 | tr` kalıbında
    # python çökse bile tr 0 döndürür, "beklenen" boşalır ve iki taraf da
    # boşsa karşılaştırma "aynı" çıkardı.
    if ! beklenen="$(python3 "$TMP/tuning_calc.py" "$CATALOG" "$eid" "$lim" 2>/dev/null)" || [ -z "$beklenen" ]; then
        formul_olcumsuz="$formul_olcumsuz $eid(katalog formülü çalıştırılamadı)"; continue
    fi
    if ! gelen="$(pjq "$PLANS" 'chr(10).join("%s=%s" % (k, d["plans"][E]["tuning"][k]) for k in sorted(d["plans"][E]["tuning"]))' "$eid")"; then
        formul_olcumsuz="$formul_olcumsuz $eid(planda tuning yok)"; continue
    fi
    beklenen="$(printf '%s' "$beklenen" | tr -d '\r')"
    gelen="$(printf '%s' "$gelen" | tr -d '\r')"
    formul_bakilan=$((formul_bakilan + 1))
    [ "$beklenen" = "$gelen" ] || formul_bozuk="$formul_bozuk $eid"
done
if [ -n "$formul_bozuk" ]; then
    t_fail "plandaki iç ayarlar catalog.json formülüyle birebir üretiliyor" \
           "uyuşmayan:$formul_bozuk — controller büyük olasılıkla ESKİ bir catalog.json okuyor (imaja gömülü kopya / kopmuş bind-mount); catalog.json'da yapılan ayar değişikliği hiç uygulanmıyor"
elif [ -n "$formul_olcumsuz" ]; then
    t_unknown "plandaki iç ayarlar catalog.json formülüyle birebir üretiliyor" \
              "karşılaştırılamayan:$formul_olcumsuz (karşılaştırılan $formul_bakilan motorda fark yok)"
elif [ "$formul_bakilan" -eq 0 ]; then
    # 13/13 motorun planı reddedilmişken "birebir üretiliyor" demek, sıfır
    # karşılaştırmayı doğrulama diye satmaktı. Formül bu koşuda hiç çalışmadı.
    t_skip "plandaki iç ayarlar catalog.json formülüyle birebir üretiliyor" \
           "planı kabul edilen motor yok (hepsi bütçeye sığmıyor:$formul_atlanan) — karşılaştırılacak tek bir tuning bloğu bile üretilmedi"
elif [ -n "$formul_atlanan" ]; then
    t_ok "plandaki iç ayarlar $formul_bakilan motorda catalog.json formülüyle birebir üretiliyor (bütçeye sığmayanlar hariç:$formul_atlanan)"
else
    t_ok "plandaki iç ayarlar $formul_bakilan motorun hepsinde catalog.json formülüyle birebir üretiliyor"
fi

# =============================================================================
# 2) HOST BÜTÇESİ AŞILMIŞ MI?
# =============================================================================
heading "2) Host bütçesi"

# Ürünün çekirdek vaadi: açık container limitlerinin toplamı host RAM'ini
# aşmaz. Aştığında hiçbir uyarı çıkmaz; çekirdek ilk bellek baskısında en
# büyük container'ı öldürür ve bunu kullanıcıya kimse söylemez.
RUNNING=""
ps_out=""
if ps_out="$(docker ps --filter "label=com.docker.compose.project=$PROJ" --format '{{.Names}}' 2>/dev/null)"; then
    ps_ok=1
else
    ps_ok=0     # docker cevap vermedi: "container yok" ile aynı şey DEĞİL
fi
while IFS= read -r _c; do
    _c="${_c%$'\r'}"
    [ -n "$_c" ] && RUNNING="$RUNNING $_c"
done <<EOF
$ps_out
EOF

if [ "$ps_ok" -eq 0 ]; then
    t_unknown "açık container limitlerinin toplamı host RAM'ine sığıyor" \
              "docker ps başarısız — hangi container'ların açık olduğu bilinmiyor"
    t_unknown "açık container'ların hepsinde bellek limiti tanımlı" \
              "docker ps başarısız — hangi container'ların açık olduğu bilinmiyor"
elif [ -z "$RUNNING" ]; then
    t_skip "açık container limitlerinin toplamı host RAM'ine sığıyor" \
           "'$PROJ' projesine ait çalışan container yok"
    t_skip "açık container'ların hepsinde bellek limiti tanımlı" \
           "'$PROJ' projesine ait çalışan container yok"
else
    # Okunamayan container AYRI tutuluyor. Eskiden `continue` ile toplamın
    # dışında bırakılıyordu: 13 container'ın 13'ü de okunamadığında "toplam
    # 0 MB, host RAM'ine sığıyor" diye GEÇTİ yazılıyordu. Toplamın bir
    # parçasını ölçemediysek toplamı bilmiyoruz demektir.
    toplam_mb=0; limitsiz=""; okunamayan=""; adet=0; olculen=0
    for c in $RUNNING; do
        adet=$((adet + 1))
        m="$(docker_limit_mb "$c")" || { okunamayan="$okunamayan $c"; continue; }
        olculen=$((olculen + 1))
        [ "$m" -eq 0 ] && limitsiz="$limitsiz $c"
        toplam_mb=$((toplam_mb + m))
    done

    # Sınır = RAM − OS payı. os_reserve_mb okunamazsa eskiden 0 varsayılıyordu
    # ve sınır SESSİZCE tüm RAM'e gevşiyordu: 30 GB'lık gerçek bir aşım bu
    # yüzden GEÇTİ oluyordu. Payı bilmiyorsak sınırı da bilmiyoruz.
    # DİKKAT: `.get("os_reserve_mb", 0)` yazmak alanın YOKLUĞUNU 0 diye okur ve
    # sınırı sessizce tüm RAM'e gevşetir — sahte yığında birebir üretildi:
    # alan silindiğinde kontrol "sınır 32577 MB = RAM − OS payı" deyip GEÇTİ
    # yazıyordu. Varsayılan yok; alan yoksa pjq hata veriyor.
    osr="$(pjq "$PLANS" 'list(d["plans"].values())[0]["os_reserve_mb"]')" || osr=""
    if [ "$HOST_TOTAL_MB" -le 0 ]; then
        t_unknown "açık container limitlerinin toplamı host RAM'ine sığıyor" \
                  "host RAM'i okunamadı (/proc/meminfo) — sığıp sığmadığı hesaplanamaz"
    elif ! tamsayi_mi "${osr:-}"; then
        t_unknown "açık container limitlerinin toplamı host RAM'ine sığıyor" \
                  "planda os_reserve_mb yok; OS payı bilinmeden sınır tüm RAM'e gevşer ve gerçek aşımlar geçmiş görünür"
    else
        sinir=$(( HOST_TOTAL_MB - osr ))
        if [ "$toplam_mb" -gt "$sinir" ]; then
            # Eksik ölçüm olsa bile: elimizdeki PARÇA toplam zaten sınırı
            # aşıyorsa aşım kanıtlanmıştır, eksik veri bunu iyileştiremez.
            t_fail "açık container limitlerinin toplamı host RAM'ine sığıyor" \
                   "toplam $toplam_mb MB > sınır $sinir MB (RAM $HOST_TOTAL_MB − OS payı $osr) — aşırı dağıtım; ilk yoğunlukta OOM-killer devreye girer${okunamayan:+ (üstelik şunlar hiç okunamadı:$okunamayan)}"
        elif [ -n "$okunamayan" ]; then
            t_unknown "açık container limitlerinin toplamı host RAM'ine sığıyor" \
                      "$adet container'ın $olculen tanesi okunabildi; limiti okunamayan:$okunamayan — eksik toplam ($toplam_mb MB) sınırın ($sinir MB) altında görünüyor ama gerçek toplam bilinmiyor"
        else
            t_ok "açık $adet container'ın limit toplamı ($toplam_mb MB) host RAM'ine sığıyor (sınır $sinir MB = RAM − OS payı)"
        fi
    fi

    if [ -n "$limitsiz" ]; then
        t_fail "açık container'ların hepsinde bellek limiti tanımlı (sınırsız çalışan yok)" \
               "limitsiz:$limitsiz — deploy.resources.limits uygulanmamış; bu container host'un tüm belleğini yiyebilir"
    elif [ -n "$okunamayan" ]; then
        t_unknown "açık container'ların hepsinde bellek limiti tanımlı (sınırsız çalışan yok)" \
                  "docker inspect şunlarda düştü:$okunamayan — limitleri var mı yok mu bilinmiyor"
    else
        t_ok "açık $adet container'ın hepsinde bellek limiti tanımlı (sınırsız çalışan yok)"
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
    if [ -z "$C" ] || [ -z "$ANA_SVC" ] || [ -z "$MEMENV" ]; then
        t_unknown "$eid: hesaplanan limit container'a uygulanmış" \
                  "katalogdan okunamadı (primary_service='$ANA_SVC', ana kopya='$C', limit env='$MEMENV') — catalog.json bozuk ya da python3 çalışmıyor; bu motorun hiçbir ölçümü yapılamadı"
        continue
    fi
    if ! container_running "$C"; then
        t_skip "$eid: hesaplanan limit container'a uygulanmış" \
               "motor kapalı ($C container'ı yok) — kapalı motorda ölçülecek limit yoktur; açmak için: ./stack.sh enable $eid"
        continue
    fi
    AKTIF_MOTORLAR="$AKTIF_MOTORLAR $eid"

    # --- limit env'i HANGİ container'a uygulanıyor? -------------------------
    # primary_service'i limit container'ı sanmak monitoring'de yanlış cevap
    # veriyordu (ana servis grafana, limit env'i prometheus'a bağlı). Doğruyu
    # compose'dan okuyoruz; okuyamazsak TAHMİN ETMİYORUZ.
    LIM_SVC=""; LIM_C=""; lim_hata=""
    if lsvc="$(limit_service_of "$MEMENV")"; then
        read -r LIM_SVC LIM_C <<EOF
$lsvc
EOF
        case " $(engine_services "$eid") " in
            *" $LIM_SVC "*) ;;
            *) lim_hata="compose'da $MEMENV '$LIM_SVC' servisine uygulanıyor, ama bu servis katalogda $eid motorunun servisleri arasında yok — katalog ile compose ayrışmış, hangi container'ı ölçeceğimiz belirsiz" ;;
        esac
    else
        lim_hata="$COMPOSE_FILE içinde memory limitini $MEMENV değişkenine bağlayan tek bir servis bulunamadı — yanlış container'ı ölçüp uydurma arıza raporlamaktansa ölçemedik diyoruz"
    fi

    # Ölçüm hedefi. Devir olduysa (ana kopya artık replika container'ı) canlı
    # ana kopyayı ölçüyoruz: onun limiti compose'da kendi *_REPLICA_MEM_LIMIT
    # değişkeninden gelir.
    KC=""; kc_hata="$lim_hata"
    if [ -z "$lim_hata" ]; then
        if [ "$C" != "$ANA_SVC" ]; then KC="$C"; else KC="$LIM_C"; fi
        if ! container_running "$KC"; then
            kc_hata="$MEMENV limitinin uygulandığı '$KC' container'ı çalışmıyor (motorun ana servisi $C açık) — limit ölçülemedi"
            KC=""
        fi
    fi
    gercek_mb=""
    if [ -n "$KC" ]; then
        if ! gercek_mb="$(docker_limit_mb "$KC")"; then
            gercek_mb=""; kc_hata="docker inspect $KC okunamadı (HostConfig.Memory) — container'ın limiti öğrenilemedi"
        fi
    fi
    # Limit başka bir container'a uygulanıyorsa satırda HANGİSİNİ ölçtüğümüz
    # yazsın; "monitoring geçti" deyip grafana'yı ölçmek okuyanı yanıltıyordu.
    EK_C=""
    ETIKET="$eid"
    if [ -n "$LIM_C" ] && [ "$LIM_C" != "$C" ]; then
        ETIKET="$eid ($LIM_C)"
        container_running "$LIM_C" && EK_C="$LIM_C"
    fi

    # --- (a) tuning.json'daki MEM_LIMIT ↔ container'ın gerçek limiti ---------
    if [ -z "$gercek_mb" ]; then
        t_unknown "$ETIKET: container limiti controller'ın yazdığı $MEMENV ile aynı" "$kc_hata"
    elif [ "$C" != "$ANA_SVC" ]; then
        t_skip "$ETIKET: container limiti controller'ın yazdığı $MEMENV ile aynı" \
               "devir yapılmış, ana kopya $C — replika compose'da kendi *_REPLICA_MEM_LIMIT değişkenine düşer, $MEMENV ile karşılaştırma yanıltıcı olur"
    elif [ ! -f "$TUNING_JSON" ]; then
        # Motor AÇIK ama controller'ın hesap defteri hiç yok. Eskiden bu
        # ATLANDI idi ve motorlar kapalıyken koşu "0 başarısız, çıkış 0"
        # veriyordu: özete bakan bir CI "boyutlandırma doğrulandı" sanıyordu.
        # Açık bir motorun limiti KARŞILAŞTIRILAMADIYSA ölçüm yapılmamıştır.
        t_unknown "$ETIKET: container limiti controller'ın yazdığı $MEMENV ile aynı" \
                  "$TUNING_JSON yok — motor açık ama controller'ın hesabı diskte değil; container $gercek_mb MB ile çalışıyor, doğru olup olmadığı bilinmiyor (yığın elle 'docker compose up' ile açılmış olabilir; o yolda otomatik boyutlandırma hiç çalışmaz)"
    elif ! kayit="$(tuning_val "$eid" "$MEMENV")" || [ -z "$kayit" ]; then
        t_unknown "$ETIKET: container limiti controller'ın yazdığı $MEMENV ile aynı" \
                  "state/tuning.json'da $eid için $MEMENV kaydı yok — motor açık, container $gercek_mb MB ile çalışıyor ama karşılaştırılacak hesap yok"
    elif ! bek_b="$(size2b "$kayit")" || ! tamsayi_mi "${bek_b:-}"; then
        t_unknown "$ETIKET: container limiti controller'ın yazdığı $MEMENV ile aynı" \
                  "controller'ın yazdığı değer bayta çevrilemedi ($MEMENV='$kayit') — karşılaştırma yapılamadı"
    else
        bek_mb=$(( bek_b / 1048576 ))
        if [ "$gercek_mb" -eq 0 ]; then
            t_fail "$ETIKET: container limiti controller'ın yazdığı $MEMENV ile aynı" \
                   "container SINIRSIZ çalışıyor (HostConfig.Memory=0); plan $kayit diyor ama limit hiç uygulanmamış"
        elif [ "$bek_mb" -eq "$gercek_mb" ]; then
            t_ok "$ETIKET: container limiti ($gercek_mb MB) controller'ın hesabıyla ($MEMENV=$kayit) birebir aynı"
        else
            t_fail "$ETIKET: container limiti controller'ın yazdığı $MEMENV ile aynı" \
                   "plan $kayit ($bek_mb MB) diyor, container $gercek_mb MB ile çalışıyor — dashboard'daki sayı ile gerçekte ayrılan bellek farklı"
        fi
    fi

    # --- (b) çekirdek limiti gerçekten uyguluyor mu? ------------------------
    # docker'ın defterinde limit yazması yetmez: cgroup bellek denetleyicisi
    # kapalıysa (bazı çekirdekler, LXC içi docker, eski WSL) docker uyarıyı bir
    # kez basar ve limit hiç uygulanmaz — plan doğru, koruma yoktur.
    if [ -z "$gercek_mb" ]; then
        t_unknown "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" "$kc_hata"
    else
        cg_raw="$(cgroup_raw "$KC")"; cg_rc=$?
        if [ "$cg_rc" -eq 2 ]; then
            t_skip "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
                   "$KC imajında kabuk yok; çekirdek limiti container içinden okunamıyor (ölçüm yöntemi bu imajda uygulanamaz)"
        elif [ "$cg_rc" -ne 0 ]; then
            t_unknown "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
                      "$KC içinde /sys/fs/cgroup/memory.max okunamadı (docker exec düştü ya da dosya yok) — çekirdeğin limiti uygulayıp uygulamadığı BİLİNMİYOR"
        elif cgroup_limitsiz_mi "$cg_raw"; then
            # BU KONTROLÜN VAR OLUŞ SEBEBİ. Eskiden 'max' sayısal değil diye
            # "okunamadı" sayılıp ATLANDI yazılıyordu ve koşu 0 başarısızla
            # bitiyordu: "limit var" izlenimi bırakan sessiz bir yeşil.
            if [ "$gercek_mb" -eq 0 ]; then
                t_fail "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
                       "ne docker'da limit var (HostConfig.Memory=0) ne çekirdekte (memory.max=$cg_raw) — motor host'un tüm belleğini kullanabilir"
            else
                t_fail "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
                       "docker $gercek_mb MB limit bildiriyor ama çekirdekte memory.max=$cg_raw (limitsiz) — cgroup bellek denetleyicisi limiti UYGULAMIYOR; limit yalnız defterde, gerçek koruma yok"
            fi
        elif ! tamsayi_mi "$cg_raw"; then
            t_unknown "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
                      "cgroup dosyasından beklenmedik içerik geldi: '$cg_raw'"
        else
            cg_mb=$(( cg_raw / 1048576 ))
            if [ "$gercek_mb" -eq 0 ]; then
                # Ölçülemez değil, YANLIŞ: docker limiti hiç yok. Bunu "cgroup
                # tutmuyor" diye raporlamak sebebi gizler; asıl arıza limitin
                # hiç konmamış olması.
                t_fail "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
                       "container'da docker limiti YOK (HostConfig.Memory=0); cgroup $cg_mb MB gösteriyor — motorun belleği sınırlanmamış, host'un tamamını kullanabilir"
            elif [ "$cg_mb" -eq "$gercek_mb" ]; then
                t_ok "$ETIKET: çekirdek cgroup limiti ($cg_mb MB) docker'ın bildirdiğiyle aynı — limit gerçekten uygulanıyor"
            else
                t_fail "$ETIKET: çekirdek cgroup limiti docker'ın bildirdiği limitle aynı" \
                       "docker: $gercek_mb MB, cgroup: $cg_mb MB — limit yazılı ama çekirdek başka bir değeri uyguluyor"
            fi
        fi
    fi

    # --- (c) hesaplanan iç ayarlar container'a gerçekten geçmiş mi? ---------
    # Ayarlar motorun kendi container'ında aranır; limit env'i başka bir
    # servise gidiyorsa (monitoring) o container'a da bakılır.
    INSP_LISTE=""; insp_hata=""
    for _ic in $C $EK_C; do
        if TO 20 docker inspect "$_ic" > "$TMP/inspect-$_ic.json" 2>/dev/null; then
            INSP_LISTE="$INSP_LISTE $TMP/inspect-$_ic.json"
        else
            insp_hata="$insp_hata $_ic"
        fi
    done
    if [ -n "$insp_hata" ]; then
        t_unknown "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" \
                  "docker inspect başarısız:$insp_hata — ayarların geçip geçmediği okunamadı"
    elif [ ! -f "$TUNING_JSON" ]; then
        t_unknown "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" \
                  "$TUNING_JSON yok — motor açık ama controller'ın hesapladığı iç ayarlar diskte değil; container'da ne arayacağımızı bilmiyoruz"
    else
        AYARLAR="$(pj "$TUNING_JSON" \
                   'chr(10).join("%s=%s" % (k, d.get(E, {})[k]) for k in sorted(d.get(E, {})))' "$eid")"
        AYARLAR="$(printf '%s' "$AYARLAR" | tr -d '\r')"
        gecmeyen=""; bakilan=0; kayit_var=0
        [ -n "$AYARLAR" ] && kayit_var=1
        while IFS='=' read -r k v; do
            [ -n "$k" ] || continue
            case "$k" in *_MEM_LIMIT) continue ;; esac    # (a)'da ölçüldü
            bakilan=$((bakilan + 1))
            bulundu=0
            for _f in $INSP_LISTE; do
                python3 "$TMP/cfgmatch.py" "$_f" "$v" && { bulundu=1; break; }
            done
            [ "$bulundu" -eq 1 ] || gecmeyen="$gecmeyen $k=$v"
        done <<EOF
$AYARLAR
EOF
        if [ "$kayit_var" -eq 0 ]; then
            t_unknown "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" \
                      "state/tuning.json'da $eid kaydı yok — motor açık ama controller bu motor için hiçbir ayar yazmamış"
        elif [ "$bakilan" -eq 0 ]; then
            t_skip "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" \
                   "state/tuning.json'da bu motor için MEM_LIMIT dışında ayar yok — $ADI için hesaplanan iç ayar yok"
        elif [ -z "$gecmeyen" ]; then
            t_ok "$eid: hesaplanan $bakilan iç ayarın hepsi container'ın komutunda/ortamında bulundu"
        else
            t_fail "$eid: hesaplanan iç ayarlar container'ın komutuna/ortamına geçmiş" \
                   "container'da bulunmayan:$gecmeyen — compose 'state/tuning.env' okunmadan çalıştırılmış olabilir; motor imaj varsayılanıyla açık"
        fi
    fi

    # --- (d) motorun CANLI iç ayarı container limitinin altında mı? --------
    IFS='|' read -r probe_env probe_label <<EOF
$(probe_meta "$eid")
EOF
    if [ -z "$probe_env" ]; then
        t_skip "$eid: motorun iç bellek ayarı container limitinin altında" \
               "katalogda bu motor için iç bellek ayarı tanımlı değil (yalnız $MEMENV); $ADI belleğini kendi yönetiyor"
    else
        # Sonda MOTORUN container'ını ölçüyor; tavan da O container'ın kendi
        # limiti olmalı. Limit env'i başka bir servise gidiyorsa (çok servisli
        # motor) başka container'ın limitini tavan saymak elmayla armudu
        # karşılaştırmak olurdu.
        tavan_mb="$gercek_mb"; tavan_hata="$kc_hata"
        if [ "$KC" != "$C" ]; then
            if tavan_mb="$(docker_limit_mb "$C")"; then
                tavan_hata=""
            else
                tavan_mb=""; tavan_hata="docker inspect $C okunamadı — motorun kendi container limiti bilinmiyor"
            fi
        fi
        ic_b="$(probe_bytes "$eid" "$C")"
        if [ -z "${ic_b:-}" ] || ! tamsayi_mi "$ic_b"; then
            # Sonda düştü: istemci yok, parola tutmadı, motor cevap vermedi.
            # Bu "ayar iyi" demek değil, "ayarı görmedik" demek.
            t_unknown "$eid: motorun iç bellek ayarı ($probe_label) container limitinin altında" \
                      "$C içinden ölçüm alınamadı (istemci/parola/erişim; gelen: '${ic_b:-boş}') — ayar DOĞRULANAMADI"
        elif [ -z "$tavan_mb" ]; then
            t_unknown "$eid: motorun iç bellek ayarı ($probe_label) container limitinin altında" \
                      "$probe_label okundu ($((ic_b / 1048576)) MB) ama container limiti öğrenilemedi: $tavan_hata"
        elif [ "$tavan_mb" -le 0 ]; then
            t_skip "$eid: motorun iç bellek ayarı ($probe_label) container limitinin altında" \
                   "container limitsiz; karşılaştırılacak tavan yok (limitsizliğin kendisi yukarıda başarısız yazıldı)"
        else
            lim_b=$((tavan_mb * 1048576))
            ic_mb=$((ic_b / 1048576))
            # %10 pay şart: motorun ayarı limite eşit ya da çok yakınsa bağlantı
            # tamponları ve sorgu belleği ilk yükte limiti aşırır; cgroup OOM-killer
            # sorguyu değil SÜRECİ öldürür.
            if [ "$ic_b" -gt 0 ] && [ $((ic_b * 10)) -le $((lim_b * 9)) ]; then
                t_ok "$eid: $probe_label = $ic_mb MB, container limitinin ($tavan_mb MB) %$((ic_mb * 100 / tavan_mb))'i — limitin altında"
            else
                t_fail "$eid: motorun iç bellek ayarı ($probe_label) container limitinin altında" \
                       "$probe_label = $ic_mb MB, container limiti $tavan_mb MB — motor limiti aşabilir; cgroup OOM-killer süreci öldürür"
            fi
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
if [ -z "$PG_C" ]; then
    t_unknown "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
              "postgresql'in ana kopya container adı katalogdan okunamadı — hangi container'a bakacağımız belli değil"
elif container_running "$PG_C"; then
    pgpw="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
    pgq() {
        local out
        out="$(TO "$DEX_TIMEOUT" docker exec -e PGPASSWORD="$pgpw" "$PG_C" \
               psql -U "${POSTGRES_USER:-root}" -d postgres -tAc "$1" 2>/dev/null)" || return 1
        printf '%s' "$out" | tr -d ' \r' | head -1
    }
    sb_b="$(pgq "SELECT setting::bigint*current_setting('block_size')::bigint FROM pg_settings WHERE name='shared_buffers'")"
    wm_b="$(pgq "SELECT setting::bigint*1024 FROM pg_settings WHERE name='work_mem'")"
    conns="$(pgq "SELECT setting FROM pg_settings WHERE name='max_connections'")"
    lim_mb="$(docker_limit_mb "$PG_C")" || lim_mb=""
    okunabilir=1
    for _v in "${sb_b:-}" "${wm_b:-}" "${conns:-}"; do
        case "$_v" in ''|*[!0-9]*) okunabilir=0 ;; esac
    done
    if [ "$okunabilir" -eq 0 ]; then
        # psql'e ulaşamamak "tuzak yok" demek değil, "tuzağa bakamadık" demek.
        t_unknown "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
                  "canlı değerler okunamadı (shared_buffers=${sb_b:-yok}, work_mem=${wm_b:-yok}, max_connections=${conns:-yok}) — istemci/parola/erişim"
    elif [ -z "$lim_mb" ]; then
        # Eskiden bu dal "container limitsiz" diye ATLANIYORDU: docker inspect
        # düştüğünde limit 0 sanılıyor ve kontrol sessizce kayboluyordu.
        t_unknown "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
                  "docker inspect $PG_C okunamadı — karşılaştırılacak container limiti bilinmiyor"
    elif [ "$lim_mb" -le 0 ]; then
        t_skip "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
               "container limitsiz (HostConfig.Memory=0); karşılaştırılacak tavan yok — limitsizliğin kendisi yukarıda başarısız yazıldı"
    else
        top_mb=$(( (sb_b + wm_b * conns) / 1048576 ))
        if [ "$top_mb" -lt "$lim_mb" ]; then
            t_ok "postgresql: shared_buffers($((sb_b / 1048576)) MB) + work_mem($((wm_b / 1048576)) MB) × $conns bağlantı = $top_mb MB, container limitinin ($lim_mb MB) altında"
        else
            t_fail "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
                   "en kötü durumda $top_mb MB gerekiyor, container limiti $lim_mb MB — bağlantılar aynı anda sorgu çalıştırdığında OOM"
        fi
    fi
else
    t_skip "postgresql: canlı shared_buffers + work_mem × max_connections container limitini aşmıyor" \
           "PostgreSQL kapalı ($PG_C container'ı yok) — canlı ayar okunamaz"
fi

# Motor kapalıyken bile PLAN doğrulanabilir: tuzak aktivasyondan ÖNCE, hesabın
# içinde vardır. Böylece "açılsaydı OOM olurdu" durumu da yakalanır.
if ! p_karar="$(pjq "$PLANS" 'bool(d["plans"]["postgresql"].get("ok"))')"; then
    t_unknown "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
              "/api/plans cevabında postgresql kaydı yok — plan üzerinden tuzak denetlenemedi"
elif [ "$p_karar" = "true" ]; then
    p_lim="$(pj "$PLANS" 'd["plans"]["postgresql"]["limit_mb"]')"
    p_sb="$(size2b "$(pj "$PLANS" 'd["plans"]["postgresql"]["tuning"].get("POSTGRES_SHARED_BUFFERS","")')")"
    p_wm="$(size2b "$(pj "$PLANS" 'd["plans"]["postgresql"]["tuning"].get("POSTGRES_WORK_MEM","")')")"
    p_mc="$(pj "$PLANS" 'd["plans"]["postgresql"]["tuning"].get("POSTGRES_MAX_CONNECTIONS","0")')"
    if ! tamsayi_mi "${p_lim:-}" || [ "$p_lim" -le 0 ]; then
        t_unknown "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
                  "planda limit_mb yok/sayı değil ('${p_lim:-yok}') — karşılaştırılacak tavan yok"
    elif tamsayi_mi "${p_sb:-}" && tamsayi_mi "${p_wm:-}" && tamsayi_mi "${p_mc:-}" && [ "$p_mc" -gt 0 ]; then
        p_top=$(( (p_sb + p_wm * p_mc) / 1048576 ))
        if [ "$p_top" -lt "$p_lim" ]; then
            t_ok "postgresql planı: shared_buffers + work_mem × $p_mc bağlantı = $p_top MB, planlanan limitin ($p_lim MB) altında"
        else
            t_fail "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
                   "plan en kötü durumda $p_top MB istiyor ama limit $p_lim MB — bu planla açılan PostgreSQL yük altında OOM olur"
        fi
    else
        # Alanların yokluğu ürünün hatası: katalog bu üç ayarı üretmek zorunda.
        t_fail "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
               "planda POSTGRES_SHARED_BUFFERS / WORK_MEM / MAX_CONNECTIONS eksik ya da sayıya çevrilemedi (sb='${p_sb:-yok}', wm='${p_wm:-yok}', mc='${p_mc:-yok}')"
    fi
else
    t_skip "postgresql planı: shared_buffers + work_mem × max_connections planlanan limiti aşmıyor" \
           "PostgreSQL planı reddedilmiş (tuning üretilmiyor): $(pj "$PLANS" 'd["plans"]["postgresql"].get("reason","sebep bildirilmemiş")')"
fi

# Neo4j aynı tuzağın ikinci örneği: heap JVM'in İÇİNDE, pagecache DIŞINDA
# ayrılır. İkisi tek tek limite sığsa bile toplamları sığmayabilir.
NEO_C="$(primary_container neo4j)"
if [ -z "$NEO_C" ]; then
    t_unknown "neo4j: JVM heap + pagecache container limitinin altında" \
              "neo4j'nin ana kopya container adı katalogdan okunamadı"
elif container_running "$NEO_C"; then
    neo_ps="$(TO "$DEX_TIMEOUT" docker exec "$NEO_C" sh -c \
              'for p in /proc/[0-9]*/cmdline; do tr "\0" "\n" < "$p" 2>/dev/null; done' 2>/dev/null)"
    neo_xmx="$(printf '%s\n' "$neo_ps" | grep -m1 '^-Xmx')"
    heap_b="$(size2b "${neo_xmx#-Xmx}")"
    pc_env="$(TO 20 docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NEO_C" 2>/dev/null)" \
        && pc_okundu=1 || pc_okundu=0
    pc_raw="$(printf '%s\n' "$pc_env" | sed -n 's/^NEO4J_server_memory_pagecache_size=//p' | head -1 | tr -d '\r')"
    pc_b="$(size2b "$pc_raw")"
    neo_lim="$(docker_limit_mb "$NEO_C")" || neo_lim=""
    if ! tamsayi_mi "${heap_b:-}" || [ "$pc_okundu" -eq 0 ] || ! tamsayi_mi "${pc_b:-}"; then
        # Heap ya da pagecache okunamadıysa toplamı bilmiyoruz. Bunu ATLANDI
        # yazmak "tuzak yok" izlenimi bırakıyordu; ölçemedik.
        t_unknown "neo4j: JVM heap + pagecache container limitinin altında" \
                  "heap ya da pagecache okunamadı (heap='${neo_xmx:-yok}', pagecache='${pc_raw:-yok}', docker inspect $( [ "$pc_okundu" -eq 1 ] && echo çalıştı || echo düştü )) — toplam hesaplanamadı"
    elif [ -z "$neo_lim" ]; then
        t_unknown "neo4j: JVM heap + pagecache container limitinin altında" \
                  "docker inspect $NEO_C okunamadı — karşılaştırılacak container limiti bilinmiyor"
    elif [ "$neo_lim" -le 0 ]; then
        t_skip "neo4j: JVM heap + pagecache container limitinin altında" \
               "container limitsiz (HostConfig.Memory=0); karşılaştırılacak tavan yok"
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
katalogda_mi() { local x; for x in $IDS; do [ "$x" = "$1" ] && return 0; done; return 1; }
plan_ok_mu()   { [ "$(pj "$PLANS" 'bool(d["plans"][E].get("ok"))' "$1")" = "true" ]; }
kapali_mi() {   # <motor> → container'ı çalışmıyorsa 0
    local c
    c="$(primary_container "$1")" || return 1
    [ -n "$c" ] || return 1
    container_running "$c" && return 1
    return 0
}

# Hedef seçimi iki koşullu: motor KAPALI olacak (ret çalışmazsa en fazla küçük
# bir motor açılır, betik de onu kapatır) ve planı KABUL EDİLMİŞ olacak.
# İkincisi denetimden çıktı: controller retleri SIRAYLA uyguluyor. Motor zaten
# bütçeye sığmıyorsa istek hiç değerlendirilmeden "en az X MB ister" diye
# reddedilir; biz de asıl sınamak istediğimiz requested_mb denetimini HİÇ
# ÇALIŞTIRMADAN "geçti" yazarız. Planı kabul edilen bir motorda ise gelen tek
# ret sebebi istenen miktarın kendisidir.
hedef=""; hedef_yedek=""
for tercih in minio monitoring rabbitmq $IDS; do
    katalogda_mi "$tercih" || continue
    kapali_mi "$tercih" || continue
    [ -z "$hedef_yedek" ] && hedef_yedek="$tercih"
    if plan_ok_mu "$tercih"; then hedef="$tercih"; break; fi
done
hedef_plan_ok=1
if [ -z "$hedef" ]; then hedef="$hedef_yedek"; hedef_plan_ok=0; fi

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
    if http_cevapsiz "$code"; then
        # Gateway/controller cevap vermedi: ret mekanizmasını SINAYAMADIK.
        # Bunu "ret çalışmıyor" diye yazmak da uydurma olurdu.
        t_unknown "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır" \
                  "aktivasyon isteği cevapsız kaldı: HTTP $code — $(head -c 200 "$RESP" 2>/dev/null | tr -d '
')"
        t_unknown "reddedilen aktivasyon hiçbir container yaratmıyor" \
                  "istek gönderilemedi; yan etki olup olmadığı da bilinmiyor"
    elif [ "$code" != "202" ] || [ -z "$job" ]; then
        t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                "istek işe bile dönüşmedi: HTTP $code — $(head -c 200 "$RESP" 2>/dev/null | tr -d '
')"
        t_skip "reddedilen aktivasyon hiçbir container yaratmıyor" "iş hiç başlamadı"
    else
        # Sonsuz bekleme yok. İş JOB_TIMEOUT içinde sonuçlanmazsa bu da arızadır:
        # dashboard'da sonsuza dek "devam ediyor" gösteren iş gerçek bir hataydı.
        durum="running"; sebep=""; gecen=0; job_hata=""
        while [ "$durum" = "running" ] && [ "$gecen" -lt "$JOB_TIMEOUT" ]; do
            sleep 2; gecen=$((gecen + 2))
            # İş durumunu okuyan çağrının KENDİSİ düşerse durum boşalır ve
            # döngü "running değil" diye çıkardı; ölçemediğimizi ret sanmamak
            # için HTTP kodunu okuyoruz.
            jc="$(api_get "/api/jobs/$job" "$TMP/job.json")"
            if [ "$jc" != "200" ]; then job_hata="/api/jobs/$job HTTP $jc"; break; fi
            if ! durum="$(pjq "$TMP/job.json" 'd.get("state","")')"; then
                job_hata="iş cevabında state alanı yok — $(head -c 120 "$TMP/job.json" 2>/dev/null | tr -d '\n')"; break
            fi
            sebep="$(pj "$TMP/job.json" 'd.get("reason","")')"
            [ $((gecen % 20)) -eq 0 ] && log "  '$hedef' aktivasyon işi bekleniyor (${gecen}s/${JOB_TIMEOUT}s), durum: $durum"
        done
        if [ -n "$job_hata" ]; then
            t_unknown "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır" \
                      "iş durumu okunamadı ($job_hata) — ret gerçekleşti mi bilinmiyor"
        elif [ "$durum" = "running" ]; then
            t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                    "iş $JOB_TIMEOUT saniyede sonuçlanmadı, hâlâ 'running' — kullanıcı sonuç göremeden bekler"
        elif [ "$durum" = "done" ]; then
            t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                    "$istenen MB istendi ve iş BAŞARILI döndü — bütçe denetimi devrede değil, host aşırı dağıtılıyor"
        elif [ "${#sebep}" -ge 25 ] && printf '%s' "$sebep" | grep -qF -- "$istenen"; then
            # Ret metni İSTENEN MİKTARI anıyorsa denetim gerçekten istek
            # üzerinde çalışmıştır. Eskiden yalnız "MB geçiyor mu" diye
            # bakılıyordu; "bütçe zaten dolu" gibi ilgisiz bir ret de GEÇTİ
            # yazıyor, hedeflenen requested_mb denetimi hiç çalışmamış olabiliyordu.
            t_ok "bütçeyi aşan istek ($hedef, $istenen MB) reddedildi ve sebep istenen miktarı adıyla anıyor: $sebep"
        elif [ "$hedef_plan_ok" -eq 0 ]; then
            t_skip "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır" \
                   "denemeye uygun (kapalı VE planı kabul edilmiş) motor yoktu; '$hedef' zaten bütçeye sığmıyordu ve istek değerlendirilmeden reddedildi ('${sebep:-boş}') — istenen miktar denetimi bu koşuda ÇALIŞMADI"
        else
            t_fail "bütçeyi aşan aktivasyon isteği reddediliyor ve sebebi anlaşılır"                    "reddedildi ama sebep istenen $istenen MB'dan hiç söz etmiyor: '${sebep:-boş}' — planı kabul edilen bir motorda tek beklenen ret sebebi istenen miktardır; requested_mb denetimi çalışmamış olabilir"
        fi

        # Ret gerçekten "hiçbir şey yapılmadı" mı? Yarım kalmış bir container
        # hem bütçe defterini bozar hem de kapalı sanılan bir port açar.
        sleep 1
        if [ -z "$HC" ]; then
            # container_running "" hiçbir zaman eşleşmez: boş adla bu kontrol
            # "container yaratılmamış" diye HER ZAMAN geçerdi.
            t_unknown "reddedilen aktivasyon hiçbir container yaratmıyor" \
                      "'$hedef' motorunun container adı katalogdan okunamadı — yan etki olup olmadığına bakılamadı"
        elif ! docker ps --format '{{.Names}}' >/dev/null 2>&1; then
            # docker sustuğunda container_running her zaman "hayır" der; bu
            # kontrol o hâlde "yan etki yok" diye GEÇERDİ.
            t_unknown "reddedilen aktivasyon hiçbir container yaratmıyor" \
                      "docker ps cevap vermiyor — '$HC' ayağa kalkmış mı görülemedi"
        elif container_running "$HC"; then
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
# Doğru komut './stack.sh enable <motor>'. './stack.sh up' argüman ALMAZ
# (stack.sh: 'up) compose up -d gateway controller adminer'): 'mariadb'
# yutulur, yalnız kontrol düzlemi açılır, motor açılmaz ve kullanıcı ürünü
# bozuk sanar.
[ -n "$AKTIF_MOTORLAR" ] || \
    warn "Hiçbir veritabanı motoru açık değil — container üzerinden yapılan ölçümlerin hepsi atlandı. Gerçek doğrulama için en az bir motoru açın: ./stack.sh enable mariadb"

# Sayaçlar, özet ve çıkış kodu lib.sh'te. Buradaki eski özet bloğu "FAIL>0 ise
# 1, değilse 0" diyordu; "hiçbir kontrol çalışmadı" hâli de 0 veriyordu.
e2e_finish; exit $?
