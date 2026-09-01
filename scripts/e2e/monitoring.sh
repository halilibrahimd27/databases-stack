#!/bin/bash
# =============================================================================
# databases-stack — E2E: İZLEME ZİNCİRİ
# =============================================================================
# Bu betik "Grafana açılıyor mu" diye sormaz. İzleme bir ZİNCİRDİR:
#
#     exporter → Prometheus hedefi → seri → pano sorgusu → Grafana paneli
#
# Zincirin ortasındaki bir halka koptuğunda ürün HÂLÂ SAĞLIKLI GÖRÜNÜR:
# container'lar ayakta, Grafana açılıyor, panolar listeleniyor, grafiklerin
# ekseni çiziliyor — içleri boştur. Depoda bunun iki gerçek örneği yazılı:
#   • cAdvisor bu sunucuda hedef olarak "up" görünüyordu ama container başına
#     HİÇ seri üretmiyordu; Genel Bakış panosunun on sorgusu sessizce boştu.
#   • Devirden sonra exporter eski ana kopyaya bakmaya devam ediyor, mysql_up
#     0'a düşüyor ve o motorun bütün grafikleri boşalıyordu — yani izleme, tam
#     da en çok ihtiyaç duyulduğu anda körleşiyordu.
# İkisi de "container ayakta mı" sorusuyla YAKALANAMAZ. Ancak sorgunun kendisi
# gerçek Prometheus'a sorulup cevabın boş geldiği görülünce yakalanır. Bu
# betiğin tamamı bunun üzerine kurulu.
#
# ÇALIŞTIRMA (yığın kökünden):
#     ./scripts/e2e/monitoring.sh
#
# AYARLAR (ortam değişkeni olarak verilir):
#   MON_WARMUP_S=360        rate() penceresinin dolması için beklenecek süre.
#                           0 verilirse hiç beklenmez; yeterli örnek yoksa
#                           rate() sorguları ATLANDI olarak raporlanır.
#   MON_NO_CYCLE=1          "motoru kapat/aç" testini atlar (ATLANDI yazar).
#   MON_CYCLE_ENGINE=redis  o testte hangi motorun kullanılacağını sabitler.
#   MON_BATCH_TIMEOUT=300   toplu sondaların (164 pano sorgusu) üst süre sınırı.
#   MON_KEEP_MONITORING=0   izlemeyi BU BETİK açtıysa sonunda geri kapatır.
#                           Varsayılan 1 (açık bırakır): kapatmak Prometheus'un
#                           ölçüm penceresini boşaltır ve bir sonraki koşuyu
#                           yeniden 6 dakika beklemeye mahkûm eder.
#
# TEMİZLİK: betik yalnız /tmp altında geçici dosya yaratır ve çıkarken siler.
# Kapattığı motoru (yarıda kesilse bile) geri açar. Veritabanlarına hiçbir şey
# yazmaz — burada ölçülen şey yığının kendi telemetrisidir, sınamak için veri
# üretmeye gerek yoktur. Arka arkaya iki kez çalıştırılabilir; ikinci koşu
# birincisinden farklı davranmaz.
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/common.sh
source "$SELF_DIR/../lib/common.sh" || { echo "scripts/lib/common.sh okunamadı" >&2; exit 1; }
cd "$STACK_ROOT" || exit 1
load_env

ALAN="izleme"
DASH_DIR="$STACK_ROOT/config/grafana/dashboards"
TARGETS_JSON="$STACK_ROOT/state/prometheus/targets.json"
PROJ="${STACK_PROJECT:-databases-stack}"
CTRL_C="controller"                     # ağ içi isteklerin atıldığı container
PROM_URL="http://prometheus:9090"
GRAF_URL="http://grafana:3000"

MON_WARMUP_S="${MON_WARMUP_S:-360}"
MON_NO_CYCLE="${MON_NO_CYCLE:-0}"
MON_CYCLE_ENGINE="${MON_CYCLE_ENGINE:-}"
MON_KEEP_MONITORING="${MON_KEEP_MONITORING:-1}"
MON_HTTP_TIMEOUT="${MON_HTTP_TIMEOUT:-60}"
MON_ENABLE_TIMEOUT="${MON_ENABLE_TIMEOUT:-300}"

# =============================================================================
# TEST YARDIMCILARI
# =============================================================================
# t_skip AYRI BİR SATIR basar ve sayılır. Sessizce atlanan test "geçti" sanılır;
# izlemede bu özellikle tehlikeli, çünkü boş bir grafikle geçen testi kimse
# fark etmez — grafik zaten çizilmiştir, yalnız içi yoktur.
PASS_N=0; FAIL_N=0; SKIP_N=0

t_ok() {
    PASS_N=$((PASS_N + 1))
    printf '%s  [GEÇTİ]%s   %s\n' "$GREEN" "$NC" "$1"
    return 0
}

t_fail() {
    FAIL_N=$((FAIL_N + 1))
    printf '%s  [KALDI]%s   %s\n' "$RED" "$NC" "$1"
    if [ -n "${2:-}" ]; then printf '              ↳ %s\n' "$2"; fi
    return 0
}

t_skip() {
    SKIP_N=$((SKIP_N + 1))
    printf '%s  [ATLANDI]%s %s\n' "$YELLOW" "$NC" "$1"
    printf '              ↳ sebep: %s\n' "${2:-sebep belirtilmedi}"
    return 0
}

# Python sondaları sonucu "DURUM<TAB>ad<TAB>ayrıntı" satırları olarak basar;
# burada tek tek test satırına çevriliyor. SÜREÇ İKAMESİYLE (`< <(...)`) ya da
# dosyadan okunmalı — boru hattı kullanılsaydı döngü alt kabukta çalışır ve
# sayaçlar geri gelmezdi: özet satırı sessizce "0/0 geçti" derdi.
emit() {
    local st ad ay
    while IFS=$'\t' read -r st ad ay; do
        case "$st" in
            PASS) t_ok "$ad" ;;
            FAIL) t_fail "$ad" "${ay:-}" ;;
            SKIP) t_skip "$ad" "${ay:-}" ;;
            '')   : ;;
            *)    log "$st ${ad:-} ${ay:-}" ;;
        esac
    done
    return 0
}

# Bir sonda HİÇ satır üretmezse (çöktü, zaman aşımına uğradı, container gitti)
# emit sessiz kalır ve o bölüm "hiç test yokmuş" gibi geçip gider — yani tam da
# bu betiğin avlamaya çalıştığı türden sessiz bir boşluk. Boş çıktıyı açıkça
# KALDI sayıyoruz.
emit_or_fail() {                        # $1 çıktı, $2 stderr, $3 test adı
    if [ -s "$1" ]; then
        emit < "$1"
    else
        t_fail "$3" "sonda hiç sonuç üretmedi (çöktü ya da zaman aşımı): $(head -c 300 "$2" 2>/dev/null | tr '\n' ' ')"
    fi
    return 0
}

# Hiçbir bekleme sonsuz olmasın: dışarıya giden her çağrı `timeout` ile sarılır.
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
run_t() {
    local s="$1"; shift
    if [ "$HAVE_TIMEOUT" = 1 ]; then timeout "$s" "$@"; else "$@"; fi
}

# Bir koşul sağlanana kadar bekle; beklerken NEYİ beklediğini ve ne kadar
# kaldığını yaz. Sessiz bekleme, donmuş betikten ayırt edilemez.
wait_for() {
    local desc="$1" tmo="$2"; shift 2
    local start now i=0
    start="$(date +%s)"
    while :; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        now="$(date +%s)"
        if [ $((now - start)) -ge "$tmo" ]; then
            warn "zaman aşımı (${tmo} sn): $desc"
            return 1
        fi
        i=$((i + 1))
        if [ $((i % 3)) -eq 1 ]; then
            log "bekleniyor: $desc — $((now - start))/${tmo} sn"
        fi
        sleep 5
    done
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dbstack-e2e-monitoring.XXXXXX")" || exit 1
RESTORE_ENGINE=""                       # kapat/aç testinde geri açılacak motor
WE_ENABLED_MONITORING=0

cleanup() {
    local rc=$?
    # Betik yarıda kesilse bile kapattığımız motoru geri açmayı DENERİZ: yarım
    # kalmış bir test yüzünden veritabanının kapalı kalması, testin yakalamaya
    # çalıştığı her arızadan pahalıdır.
    if [ -n "$RESTORE_ENGINE" ]; then
        warn "temizlik: $RESTORE_ENGINE geri açılıyor…"
        run_t "$MON_ENABLE_TIMEOUT" "$STACK_ROOT/stack.sh" enable "$RESTORE_ENGINE" >/dev/null 2>&1 \
            || err "$RESTORE_ENGINE geri AÇILAMADI — elle açın: ./stack.sh enable $RESTORE_ENGINE"
        RESTORE_ENGINE=""
    fi
    if [ "$WE_ENABLED_MONITORING" = 1 ] && [ "$MON_KEEP_MONITORING" = 0 ]; then
        log "temizlik: izleme, betik başlamadan önceki hâline (kapalı) döndürülüyor…"
        run_t 300 "$STACK_ROOT/stack.sh" disable monitoring >/dev/null 2>&1 \
            || warn "izleme kapatılamadı — elle: ./stack.sh disable monitoring"
    fi
    rm -rf "$TMPD"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# =============================================================================
# AĞ İÇİ HTTP — Prometheus ve Grafana HOST'A PORT AÇMAZ
# =============================================================================
# İkisi de yalnız Docker ağından (dbnet) erişilebilir; host'ta curl olsa bile
# ulaşamaz. stack.sh controller'a tam olarak bu yolla konuşuyor (bkz. _api):
# istek, aynı ağdaki bir container'ın içinden atılır. controller'ı seçmemizin
# sebebi orada Python'un olması — busybox wget'te ne URL kaçışı ne JSON
# ayrıştırması var, uzun PromQL ifadeleri de GET satırına sığmaz (bu yüzden
# sorgular POST ile gidiyor).
py_in_net() {
    run_t "$MON_HTTP_TIMEOUT" docker exec -i "$@" "$CTRL_C" python -
}

# Toplu sondalar (bir koşuda yüzlerce PromQL) tek bir HTTP çağrısından çok daha
# uzun sürer; onlara ayrı ve geniş bir zaman aşımı veriyoruz — yine de sonsuz
# değil. Zaman aşımına uğrarsa çıktı YARIM kalır; bunu bildiren ayrı bir
# kontrol var (yarım listeyi tam sanmak, testin kendisini yalancı yapardı).
MON_BATCH_TIMEOUT="${MON_BATCH_TIMEOUT:-300}"
py_in_net_batch() {
    run_t "$MON_BATCH_TIMEOUT" docker exec -i "$@" "$CTRL_C" python -
}

# Tek bir PromQL'i anlık sorar, ilk örneğin değerini basar (sonuç yoksa 0).
prom_scalar() {
    py_in_net -e "E2E_Q=$1" <<'PY'
import os, json, urllib.request, urllib.parse
try:
    body = urllib.parse.urlencode({"query": os.environ["E2E_Q"]}).encode()
    req = urllib.request.Request("http://prometheus:9090/api/v1/query", data=body)
    j = json.loads(urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace"))
    res = (j.get("data") or {}).get("result") or []
    print(res[0]["value"][1] if res else "0")
except Exception:
    print("0")
PY
}

# Bir motorun AKTİF hedef listesindeki hedef sayısı.
# -1 = Prometheus'a sorulamadı. Bu "hedef düştü" DEĞİLDİR; ikisini karıştırmak
# kapat/aç testini yalancı bir GEÇTİ'ye çevirirdi.
prom_target_count() {
    py_in_net -e "E2E_EID=$1" <<'PY'
import os, json, urllib.request
eid = os.environ["E2E_EID"]
try:
    j = json.loads(urllib.request.urlopen(
        "http://prometheus:9090/api/v1/targets?state=active",
        timeout=25).read().decode("utf-8", "replace"))
    print(sum(1 for t in (j["data"]["activeTargets"] or [])
              if (t.get("labels") or {}).get("engine") == eid))
except Exception:
    print(-1)
PY
}

http_ok() {                             # $1 URL → 200 dönüyorsa 0
    py_in_net -e "E2E_URL=$1" <<'PY' >/dev/null 2>&1
import os, sys, urllib.request
try:
    urllib.request.urlopen(os.environ["E2E_URL"], timeout=20).read()
except Exception:
    sys.exit(1)
PY
}

# wait_for'a verilebilen koşullar (kabuk fonksiyonu olduğu için sayaçlar ve
# ortam aynı kabukta kalır).
target_gone() {
    local n; n="$(prom_target_count "$1")"
    [ "${n:-1}" = "0" ]
}
target_up() {
    local n; n="$(prom_scalar "count(up{job=\"databases\",engine=\"$1\"} == 1)")"
    n="${n%%.*}"
    [ "${n:-0}" -ge 1 ] 2>/dev/null
}

# =============================================================================
# KATALOG — motor listesi, exporter'lar ve portlar BURADAN okunur
# =============================================================================
# Hiçbiri betiğe sabit yazılmaz: kataloğa yeni bir motor eklendiğinde bu betik
# onu kendiliğinden sınamaya başlamalı. Aksi hâlde yeni motorun izlemesi hiç
# test edilmeden ürüne girer ve kimse fark etmez.
command -v python3 >/dev/null 2>&1 || die "python3 gerekli (katalog ve panolar okunuyor)."
[ -f "$CATALOG" ] || die "catalog.json bulunamadı: $CATALOG"
[ -d "$DASH_DIR" ] || die "Pano klasörü yok: $DASH_DIR"

PYTHONIOENCODING=utf-8 python3 - "$CATALOG" > "$TMPD/engines.txt" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
for e in cat["engines"]:
    ex = e.get("exporter") or {}
    print("\t".join([
        e["id"], e["name"], e.get("primary_service") or e["id"],
        ex.get("service") or "", str(ex.get("port") or ""),
        ex.get("scrape_path") or "/metrics", e.get("kind", "database"),
    ]))
PY
[ -s "$TMPD/engines.txt" ] || die "catalog.json ayrıştırılamadı."

# Motorun ana servisi ŞU AN çalışıyor mu?
# common.sh'in engine_active()'i çoğu motorda doğrudur, çünkü orada motorun
# KİMLİĞİ ile ana servisin ADI aynıdır (mariadb → mariadb). İzleme'de değil:
# kimlik "monitoring", ana servis "grafana"; primary_of("monitoring") de
# topolojide kayıt olmadığı için "monitoring" döner ve öyle bir container
# yoktur. Bu yüzden aktifliği KATALOĞUN primary_service'i üzerinden çözüyoruz,
# devir olmuşsa primary_of'un bildirdiği gerçek ana kopyayı kullanıyoruz.
# Aksi hâlde izleme açıkken bile "kapalı" sanıp bütün pano testlerini atlar,
# yani hiçbir şeyi sınamadan yeşil biterdik.
engine_up() {
    local eid="$1" prim svc
    svc="$(awk -F'\t' -v k="$eid" '$1==k {print $3}' "$TMPD/engines.txt")"
    [ -n "$svc" ] || return 1
    prim="$(primary_of "$eid")"
    [ "$prim" = "$eid" ] && prim="$svc"
    container_running "$prim"
}

# =============================================================================
# 1) İZLEMEYİ AÇ
# =============================================================================
heading "1) İzleme açık mı? (prometheus + grafana + node-exporter)"

container_running "$CTRL_C" \
    || die "controller çalışmıyor — ağ içi hiçbir sorgu atılamaz. Önce: ./install.sh"

if engine_up monitoring; then
    log "izleme zaten açık"
else
    log "izleme kapalı — ürünün kendi arayüzüyle açılıyor: ./stack.sh enable monitoring"
    if run_t 600 "$STACK_ROOT/stack.sh" enable monitoring > "$TMPD/enable.log" 2>&1; then
        WE_ENABLED_MONITORING=1
        t_ok "izleme profili './stack.sh enable monitoring' ile açıldı"
    else
        t_fail "izleme profili './stack.sh enable monitoring' ile açıldı" \
               "$(tail -3 "$TMPD/enable.log" 2>/dev/null | tr '\n' ' ')"
    fi
fi

for svc in prometheus grafana node-exporter; do
    if container_running "$svc"; then
        t_ok "$svc container'ı ayakta"
    else
        t_fail "$svc container'ı ayakta" "docker ps listesinde yok"
    fi
done

# Container'ın ayakta olması yetmez: Prometheus bozuk bir kural dosyasıyla da
# ayakta kalabilir, Grafana da kendi veritabanına bağlanamadan açılabilir.
if container_running prometheus; then
    if wait_for "prometheus /-/healthy cevap versin" 120 http_ok "$PROM_URL/-/healthy"; then
        t_ok "prometheus /-/healthy sağlıklı cevap veriyor"
    else
        t_fail "prometheus /-/healthy sağlıklı cevap veriyor" "120 sn içinde cevap gelmedi"
    fi
else
    t_skip "prometheus /-/healthy sağlıklı cevap veriyor" "prometheus container'ı kapalı"
fi

if container_running grafana; then
    if wait_for "grafana /api/health cevap versin" 180 http_ok "$GRAF_URL/api/health"; then
        t_ok "grafana /api/health cevap veriyor"
    else
        t_fail "grafana /api/health cevap veriyor" "180 sn içinde cevap gelmedi"
    fi
else
    t_skip "grafana /api/health cevap veriyor" "grafana container'ı kapalı"
fi

if ! container_running prometheus; then
    err "prometheus olmadan izleme zincirinin geri kalanı sınanamaz."
    printf '\n%s: %d/%d geçti (%d atlandı)\n' "$ALAN" "$PASS_N" "$((PASS_N + FAIL_N))" "$SKIP_N"
    exit 1
fi

# --------------------------------------------------------------------------
# Açık motorları tespit et — bundan sonraki her adım bu listeye göre karar verir
# --------------------------------------------------------------------------
ACTIVE_ENGINES=""
while IFS=$'\t' read -r eid ename eprim eexsvc eexport escrape ekind; do
    [ -n "${eid:-}" ] || continue
    if engine_up "$eid"; then ACTIVE_ENGINES="$ACTIVE_ENGINES $eid"; fi
done < "$TMPD/engines.txt"
ACTIVE_ENGINES="${ACTIVE_ENGINES# }"
log "açık motorlar: ${ACTIVE_ENGINES:-(yok)}"

# =============================================================================
# 2) PROMETHEUS HEDEFLERİ
# =============================================================================
heading "2) Prometheus hedeflerinin HEPSİ up mı?"

# Önce hedef DOSYASI. Onu controller yazar ve yalnız motor açılıp kapandığında
# yazar (periyodik tazeleme yoktur — bkz. write_routes çağrı yerleri). Dosya
# eskirse iki arıza da sessizdir: kapalı exporter listede kalırsa sonsuz
# "erişilemiyor" alarmı üretir; yeni açılan motor listeye girmezse hiç
# toplanmaz ve bütün panoları boş çizer.
if [ -f "$TARGETS_JSON" ]; then
    docker ps --filter "label=com.docker.compose.project=$PROJ" \
              --format '{{.Label "com.docker.compose.service"}}' \
              > "$TMPD/running.txt" 2>/dev/null
    PYTHONIOENCODING=utf-8 python3 - "$TARGETS_JSON" "$TMPD/engines.txt" "$TMPD/running.txt" \
        > "$TMPD/tfile.out" 2>"$TMPD/tfile.err" <<'PY'
import json, sys
try:
    items = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("FAIL\tprometheus hedef dosyası (state/prometheus/targets.json) geçerli JSON\t%s" % e)
    raise SystemExit(0)
engines = [l.rstrip("\n").split("\t") for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
running = {l.strip() for l in open(sys.argv[3], encoding="utf-8") if l.strip()}
listed = {}
for it in items:
    eid = (it.get("labels") or {}).get("engine") or "?"
    for t in it.get("targets") or []:
        listed[eid] = t
beklenen = {e[0]: "%s:%s" % (e[3], e[4]) for e in engines if e[3] and e[4] and e[3] in running}
eksik = sorted(set(beklenen) - set(listed))
fazla = sorted(set(listed) - set(beklenen))
yanlis = sorted(k for k in (set(listed) & set(beklenen)) if listed[k] != beklenen[k])
ad = ("prometheus hedef dosyası, ayakta olan exporter'ların listesiyle birebir aynı")
if eksik or fazla or yanlis:
    d = []
    if eksik:
        d.append("exporter'ı ayakta olduğu hâlde listede OLMAYAN: " + ", ".join(eksik))
    if fazla:
        d.append("exporter'ı kapalı olduğu hâlde listede DURAN: " + ", ".join(fazla))
    if yanlis:
        d.append("adres uyuşmuyor: " + ", ".join(yanlis))
    print("FAIL\t%s\t%s" % (ad, "; ".join(d)))
else:
    print("PASS\t%s (%d hedef)\t" % (ad, len(listed)))
PY
    emit_or_fail "$TMPD/tfile.out" "$TMPD/tfile.err" "prometheus hedef dosyası okunup karşılaştırıldı"
else
    t_fail "prometheus hedef dosyası (state/prometheus/targets.json) var" \
           "dosya yok — controller hedef listesini hiç yazmamış; hiçbir veritabanı toplanmıyor demektir"
fi

# Sonra Prometheus'un KENDİ gördüğü hedefler. Dosya doğru olup Prometheus onu
# okumamış da olabilir: file_sd yolu yanlış bağlanmışsa dosya kusursuzdur ve
# hedef listesi yine boştur.
EXPORTERS_JSON="$(PYTHONIOENCODING=utf-8 python3 - "$TMPD/engines.txt" "$ACTIVE_ENGINES" <<'PY'
import json, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
active = set(sys.argv[2].split())
print(json.dumps({r[0]: {"ad": r[1], "svc": r[3], "port": r[4], "kind": r[6]}
                  for r in rows if r[0] in active}, ensure_ascii=False))
PY
)"

py_in_net_batch -e "E2E_EXPORTERS=$EXPORTERS_JSON" <<'PY' > "$TMPD/targets.out" 2>"$TMPD/targets.err"
import os, json, urllib.request


def line(st, ad, ay=""):
    print("%s\t%s\t%s" % (st, " ".join(str(ad).split()), " ".join(str(ay).split())))


try:
    j = json.loads(urllib.request.urlopen(
        "http://prometheus:9090/api/v1/targets?state=active",
        timeout=30).read().decode("utf-8", "replace"))
    tg = j["data"]["activeTargets"] or []
except Exception as e:
    line("FAIL", "prometheus /api/v1/targets aktif hedef listesini veriyor", repr(e))
    raise SystemExit(0)

line("PASS", "prometheus /api/v1/targets aktif hedef listesini veriyor (%d hedef)" % len(tg))

for t in tg:
    lb = t.get("labels") or {}
    eng = lb.get("engine_name") or lb.get("engine") or ""
    ad = "hedef up: job=%s instance=%s%s" % (lb.get("job", "?"), lb.get("instance", "?"),
                                             (" (%s)" % eng) if eng else "")
    if t.get("health") == "up":
        line("PASS", ad)
    else:
        line("FAIL", ad, "health=%s · son hata: %s · scrape=%s"
             % (t.get("health"), t.get("lastError") or "(hata metni yok)",
                t.get("scrapeUrl", "?")))

# İzlemenin OMURGASI. Bu üç iş hedef listesinde HİÇ yoksa "hepsi up" cevabı
# yanıltıcıdır: olmayan hedef "down" da görünmez. controller hedefi
# unutulduğunda Genel Bakış panosunun tamamı sessizce boş kalıyordu
# (bkz. config/prometheus/prometheus.yml içindeki not).
jobs = {(t.get("labels") or {}).get("job") for t in tg}
for job, nicin in (("controller", "container bellek/CPU ve bellek bütçesi metrikleri"),
                   ("host", "sunucunun RAM/disk/CPU metrikleri"),
                   ("prometheus", "izlemenin kendi sağlığı")):
    ad = "sabit hedef listede var: job=%s (%s)" % (job, nicin)
    if job in jobs:
        line("PASS", ad)
    else:
        line("FAIL", ad, "bu iş hiç toplanmıyor; ona dayanan HİÇBİR seri üretilmez")

# Açık her motorun exporter'ı gerçekten toplanıyor mu? "exporter'ı yok"
# (mssql, neo4j — ürünün bilinen eksiği) ile "exporter'ı var ama toplanmıyor"
# ayrı şeylerdir: birincisi ATLANDI, ikincisi gerçek arızadır.
exporters = json.loads(os.environ.get("E2E_EXPORTERS") or "{}")
gorulen = {}
for t in tg:
    lb = t.get("labels") or {}
    if lb.get("job") == "databases" and lb.get("engine"):
        gorulen.setdefault(lb["engine"], []).append(t)
for eid in sorted(exporters):
    ex = exporters[eid]
    if not ex["svc"] or not ex["port"]:
        if ex.get("kind") == "tool":
            neden = ("bu bir veritabanı değil, izleme aracının kendisi; sağlığı yukarıdaki "
                     "job=prometheus hedefiyle ölçülüyor, ayrı bir exporter'ı yok")
        else:
            neden = ("katalogda bu motorun exporter'ı tanımlı değil (exporter: null) — "
                     "toplanacak bir uç ve dolayısıyla panosu yok")
        line("SKIP", "açık motorun exporter hedefi toplanıyor: %s" % eid, neden)
        continue
    ad = "açık motorun exporter hedefi toplanıyor: %s (%s:%s)" % (eid, ex["svc"], ex["port"])
    if eid in gorulen:
        line("PASS", ad)
    else:
        line("FAIL", ad,
             "motor açık ama job=databases içinde engine=\"%s\" etiketli hedef yok — "
             "o motorun bütün panoları boş çizer" % eid)
PY
probe_rc=$?
emit_or_fail "$TMPD/targets.out" "$TMPD/targets.err" "prometheus /api/v1/targets aktif hedef listesini veriyor"
if [ "$probe_rc" -ne 0 ]; then
    t_fail "hedef sondası eksiksiz tamamlandı" \
           "çıkış kodu $probe_rc (zaman aşımı ya da çökme) — yukarıdaki hedef listesi EKSİK olabilir"
fi
if [ -s "$TMPD/targets.err" ]; then
    warn "hedef sondası uyarı verdi: $(head -c 300 "$TMPD/targets.err" | tr '\n' ' ')"
fi

# =============================================================================
# 3) GRAFANA PANOLARI
# =============================================================================
heading "3) Panolar Grafana'ya yüklenmiş mi? (KATALOGLA değil, DOSYA SAYISIYLA)"

# Panolar dosyadan sağlanıyor (provisioning). Karşılaştırma katalogla değil,
# klasördeki dosya sayısıyla yapılır: bir pano dosyası eklendiği hâlde Grafana
# onu yüklememişse (JSON bozuk, uid çakışmış, klasör bağlanmamış) fark tam
# burada görünür. Katalogla karşılaştırmak yanlış olurdu — mssql ve neo4j'nin
# panosu yok ve olması da beklenmiyor; katalog sayısı hiç tutmazdı.
PYTHONIOENCODING=utf-8 python3 - "$DASH_DIR" "$TMPD/engines.txt" \
    > "$TMPD/dash.json" 2>"$TMPD/dash.err" <<'PY'
import json, glob, os, sys
ids = {l.split("\t")[0] for l in open(sys.argv[2], encoding="utf-8") if l.strip()}
out = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    base = os.path.basename(f)[:-5]
    try:
        d = json.load(open(f, encoding="utf-8"))
    except Exception as e:
        out.append({"file": base, "uid": "", "title": base, "engine": "?",
                    "hata": "JSON okunamadı: %s" % e, "panels": []})
        continue
    # Dosya adı → motor eşlemesi. genel.json yığının tamamına aittir, motoru yok.
    eng = "" if base == "genel" else (base if base in ids else "?")
    panels = []
    for p in d.get("panels") or []:
        tg = [{"ref": t.get("refId") or "?", "expr": t.get("expr") or ""}
              for t in (p.get("targets") or []) if t.get("expr")]
        if tg:
            panels.append({"title": (p.get("title") or "?")[:70], "targets": tg})
    out.append({"file": base, "uid": d.get("uid") or "", "hata": "",
                "title": (d.get("title") or base)[:70], "engine": eng, "panels": panels})
print(json.dumps(out, ensure_ascii=False))
PY
DASH_JSON="$(cat "$TMPD/dash.json" 2>/dev/null)"
[ -n "$DASH_JSON" ] || die "Pano dosyaları okunamadı: $(head -c 300 "$TMPD/dash.err" 2>/dev/null)"
DASH_FILE_N="$(ls -1 "$DASH_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
log "$DASH_DIR içinde $DASH_FILE_N pano dosyası var"

if container_running grafana; then
    # Grafana'da anonim erişim Viewer rolüyle açık (bkz. docker-compose.yml).
    # Yine de yönetici bilgisini hazırda tutuyoruz: kurulum anonim erişimi
    # kapatmışsa test "yetkisiz" yüzünden YANLIŞLIKLA kalmamalı.
    GF_USER="${GRAFANA_USER:-admin}"
    GF_PASS="${GRAFANA_PASSWORD:-${DB_PASSWORD:-}}"
    py_in_net_batch -e "E2E_DASH=$DASH_JSON" -e "E2E_N=$DASH_FILE_N" \
              -e "E2E_GF_USER=$GF_USER" -e "E2E_GF_PASS=$GF_PASS" \
              <<'PY' > "$TMPD/grafana.out" 2>"$TMPD/grafana.err"
import os, json, base64, urllib.request, urllib.error

BASE = "http://grafana:3000"
AUTH = "Basic " + base64.b64encode(
    ("%s:%s" % (os.environ.get("E2E_GF_USER", ""),
                os.environ.get("E2E_GF_PASS", ""))).encode()).decode()


def line(st, ad, ay=""):
    print("%s\t%s\t%s" % (st, " ".join(str(ad).split()), " ".join(str(ay).split())))


def get(path):
    """Önce anonim, olmazsa yönetici kimliğiyle dener. (gövde, hata) döner."""
    son = ""
    for hdr in ({}, {"Authorization": AUTH}):
        try:
            req = urllib.request.Request(BASE + path, headers=hdr)
            return urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace"), ""
        except urllib.error.HTTPError as e:
            son = "HTTP %d" % e.code
        except Exception as e:
            son = repr(e)
    return None, son


body, hata = get("/api/health")
if body is None:
    line("FAIL", "grafana API'si (/api/health) cevap veriyor", hata)
    raise SystemExit(0)
try:
    h = json.loads(body)
except Exception:
    h = {}
if h.get("database") == "ok":
    line("PASS", "grafana API'si sağlıklı (sürüm %s, database=ok)" % h.get("version", "?"))
else:
    line("FAIL", "grafana API'si sağlıklı (database=ok)", body[:200])

dash = json.loads(os.environ["E2E_DASH"])
beklenen = int(os.environ["E2E_N"])

body, hata = get("/api/search?type=dash-db&tag=databases-stack&limit=500")
yuklu = None
if body is None:
    line("FAIL", "grafana pano listesi (/api/search) okunabiliyor", hata)
else:
    try:
        yuklu = json.loads(body)
    except Exception as e:
        line("FAIL", "grafana pano listesi (/api/search) okunabiliyor", repr(e))

if yuklu is not None:
    ad = ("grafana'ya yüklü pano sayısı, config/grafana/dashboards altındaki dosya "
          "sayısıyla aynı (%d)" % beklenen)
    if len(yuklu) == beklenen:
        line("PASS", ad)
    else:
        line("FAIL", ad,
             "Grafana %d pano gösteriyor, klasörde %d dosya var. Grafana'dakiler: %s"
             % (len(yuklu), beklenen,
                ", ".join(sorted(d.get("title", "?") for d in yuklu)) or "(hiç)"))

# Sayının tutması doğru panoların yüklendiğini KANITLAMAZ: bir dosya düşüp
# yerine başkası gelmiş olabilir. Her dosyanın uid'sini tek tek arıyoruz.
for d in dash:
    if d.get("hata"):
        line("FAIL", "%s.json panosu geçerli bir JSON" % d["file"], d["hata"])
        continue
    if not d["uid"]:
        line("FAIL", "%s.json panosunun uid'i var" % d["file"],
             "uid alanı boş — Grafana her sağlamada yeni uid üretir ve panoya verilmiş "
             "bütün linkler kırılır")
        continue
    b, hata = get("/api/dashboards/uid/" + d["uid"])
    ad = "%s.json panosu Grafana'da yüklü (uid=%s)" % (d["file"], d["uid"])
    if b is None:
        line("FAIL", ad, "%s — dosya klasörde duruyor ama Grafana onu almamış" % hata)
    else:
        line("PASS", ad)

# Panolar veri kaynağını uid ile arar. Veri kaynağı yoksa ya da uid değişmişse
# panolar yine açılır, panellerde "Datasource not found" yazar — grafik yoktur.
b, hata = get("/api/datasources/proxy/uid/dbstack-prometheus/api/v1/query?query=up")
ad = "grafana, dbstack-prometheus veri kaynağı üzerinden Prometheus'a sorgu geçirebiliyor"
if b is None:
    line("FAIL", ad, "%s — bütün panolar bu uid'ye referans veriyor" % hata)
else:
    try:
        j = json.loads(b)
        n = len((j.get("data") or {}).get("result") or [])
    except Exception:
        j, n = {}, 0
    if j.get("status") == "success" and n > 0:
        line("PASS", ad + " (%d seri döndü)" % n)
    else:
        line("FAIL", ad, "cevap: %s" % b[:200])
PY
    probe_rc=$?
    emit_or_fail "$TMPD/grafana.out" "$TMPD/grafana.err" "grafana API'si üzerinden pano kontrolleri çalıştı"
    if [ "$probe_rc" -ne 0 ]; then
        t_fail "grafana sondası eksiksiz tamamlandı" \
               "çıkış kodu $probe_rc (zaman aşımı ya da çökme) — pano listesi EKSİK olabilir"
    fi
    if [ -s "$TMPD/grafana.err" ]; then
        warn "grafana sondası uyarı verdi: $(head -c 300 "$TMPD/grafana.err" | tr '\n' ' ')"
    fi
else
    t_skip "panolar Grafana'ya yüklenmiş" "grafana container'ı kapalı"
fi

# =============================================================================
# 4) PANO SORGULARI — GERÇEKTEN VERİ DÖNÜYOR MU?
# =============================================================================
heading "4) Her panonun HER sorgusu Prometheus'ta veri döndürüyor mu?"

# rate() en az İKİ örnek ister. İzleme az önce açıldıysa Prometheus'un elinde
# tek örnek vardır ve bütün rate() grafikleri boş çıkar — bu arıza değil,
# ölçüm penceresinin dolmamış olmasıdır. İkisi ayrılmazsa betik ya yalancı
# KALDI basar ya da gerçek boşlukları görmezden gelir. Bu yüzden önce
# pencerenin dolmasını BEKLİYORUZ; beklemeye rağmen dolmazsa o sorgular kaç
# örnek bulunduğu yazılarak ATLANDI olarak raporlanır.
NEED_SAMPLES=10        # 6 dk / 30 sn = 12 örnek; 10 hedefi jitter payı bırakır
if [ "${MON_WARMUP_S:-0}" -gt 0 ] 2>/dev/null; then
    WARM_DEADLINE=$(( $(date +%s) + MON_WARMUP_S + 120 ))
    while :; do
        MIN_S=9999; WORST=""
        for weid in $ACTIVE_ENGINES genel; do
            if [ "$weid" = "genel" ]; then
                WSEL="up{job=\"host\"}"
            else
                [ -f "$DASH_DIR/$weid.json" ] || continue
                WSEL="up{job=\"databases\",engine=\"$weid\"}"
            fi
            wn="$(prom_scalar "max(count_over_time(${WSEL}[${MON_WARMUP_S}s]))")"
            wn="${wn%%.*}"; [ -n "$wn" ] || wn=0
            if [ "$wn" -lt "$MIN_S" ] 2>/dev/null; then MIN_S="$wn"; WORST="$weid"; fi
        done
        [ "$MIN_S" = 9999 ] && break                     # sınanacak pano yok
        [ "$MIN_S" -ge "$NEED_SAMPLES" ] 2>/dev/null && break
        if [ "$(date +%s)" -ge "$WARM_DEADLINE" ]; then
            warn "ölçüm penceresi dolmadı (en az örnekli: $WORST = $MIN_S örnek). rate() sorguları eldeki veriyle sınanacak."
            break
        fi
        log "bekleniyor: rate() penceresi doluyor — $WORST için ${MIN_S}/${NEED_SAMPLES} örnek (son ${MON_WARMUP_S} sn)"
        sleep 30
    done
else
    warn "MON_WARMUP_S=0 — beklenmiyor; yeterli örnek yoksa rate() sorguları ATLANDI olarak raporlanacak"
fi

py_in_net_batch -e "E2E_DASH=$DASH_JSON" -e "E2E_ACTIVE=$ACTIVE_ENGINES" \
          -e "E2E_WARMUP=$MON_WARMUP_S" <<'PY' > "$TMPD/queries.out" 2>"$TMPD/queries.err"
import os, re, json, urllib.request, urllib.parse

PROM = "http://prometheus:9090"
dash = json.loads(os.environ["E2E_DASH"])
active = set((os.environ.get("E2E_ACTIVE") or "").split())
warm = max(int(os.environ.get("E2E_WARMUP") or 0), 300)


def line(st, ad, ay=""):
    print("%s\t%s\t%s" % (st, " ".join(str(ad).split()), " ".join(str(ay).split())))


def query(expr):
    """(sonuç listesi, hata metni). Uzun ifadeler için POST kullanılıyor."""
    try:
        body = urllib.parse.urlencode({"query": expr}).encode()
        req = urllib.request.Request(PROM + "/api/v1/query", data=body)
        j = json.loads(urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace"))
    except Exception as e:
        return None, repr(e)
    if j.get("status") != "success":
        return None, j.get("error") or "bilinmeyen sorgu hatası"
    return (j.get("data") or {}).get("result") or [], ""


# Prometheus'un TANIDIĞI bütün metrik adları. Boş dönen bir sorguda asıl soru
# şu: seri hiç üretilmemiş mi (exporter ile Prometheus arası kopuk — gerçek
# arıza), yoksa seri var da filtre mi hiçbir şey seçmemiş (ör. hiç consumer
# group yok)? Bu ayrım yapılmadan verilen rapor kullanılmaz hâle gelir:
# kullanıcı listeyi bir kez "zaten hep kırmızı" diye kapatır.
try:
    bilinen = set(json.loads(urllib.request.urlopen(
        PROM + "/api/v1/label/__name__/values", timeout=30).read().decode())["data"])
except Exception:
    bilinen = set()

ANAHTAR = set("""
by without on ignoring group_left group_right offset bool and or unless start end atan2
sum min max avg group stddev stdvar count count_values bottomk topk quantile limitk limit_ratio
rate irate increase delta idelta deriv predict_linear holt_winters double_exponential_smoothing
resets changes abs ceil floor round exp ln log2 log10 sqrt sgn clamp clamp_max clamp_min
histogram_quantile histogram_count histogram_sum histogram_avg label_replace label_join
time timestamp vector scalar absent absent_over_time sort sort_desc sort_by_label
day_of_week day_of_month day_of_year days_in_month hour minute month year pi inf nan
avg_over_time min_over_time max_over_time sum_over_time count_over_time quantile_over_time
stddev_over_time stdvar_over_time last_over_time present_over_time mad_over_time
""".split())

RATE_FN = re.compile(r"\b(rate|irate|increase|delta|idelta|deriv|predict_linear|"
                     r"holt_winters|resets|changes|[a-z_]+_over_time)\s*\(")


def metrik_adlari(expr):
    """İfadedeki çıplak metrik adları (teşhis için; kusursuz bir ayrıştırıcı
    değil, sebep göstermeye yeter)."""
    e = re.sub(r'"[^"]*"', '""', expr)                                  # etiket DEĞERLERİ
    e = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", " ", e)
    e = re.sub(r"\{[^}]*\}", " ", e)                                    # etiket blokları
    e = re.sub(r"\[[^\]]*\]", " ", e)                                   # aralık seçicileri
    ad = []
    for m in re.finditer(r"[A-Za-z_:][A-Za-z0-9_:]*", e):
        tok = m.group(0)
        if e[m.end():].lstrip().startswith("("):                        # fonksiyon çağrısı
            continue
        if tok in ANAHTAR or tok in ad:
            continue
        ad.append(tok)
    return ad


for d in dash:
    etiket = "%s.json" % d["file"]
    if d.get("hata"):
        line("FAIL", "%s panosunun sorguları çalıştırılabiliyor" % etiket, d["hata"])
        continue
    eng = d["engine"]
    if eng == "?":
        line("SKIP", "%s panosunun sorguları sınandı" % etiket,
             "dosya adı katalogdaki hiçbir motorla eşleşmiyor; motorun açık mı kapalı mı "
             "olduğu bilinemediği için boş sonuç yorumlanamaz")
        continue
    if eng and eng not in active:
        line("SKIP", "%s panosunun sorguları sınandı" % etiket,
             "%s motoru kapalı — kapalı motorun panosunun boş olması normaldir" % eng)
        continue

    # Bu pano için ölçüm penceresi ne kadar dolu?
    sec = 'up{job="host"}' if not eng else 'up{job="databases",engine="%s"}' % eng
    res, _ = query("max(count_over_time(%s[%ds]))" % (sec, warm))
    try:
        ornek = int(float(res[0]["value"][1])) if res else 0
    except Exception:
        ornek = 0

    for p in d["panels"]:
        for t in p["targets"]:
            expr = t["expr"]
            ad = 'pano %s · "%s" [%s] sorgusu Prometheus\'ta veri döndürüyor' % (
                etiket, p["title"], t["ref"])
            kisa = " ".join(expr.split())[:180]
            if RATE_FN.search(expr) and ornek < 2:
                line("SKIP", ad,
                     "izleme son %d sn içinde yalnız %d örnek biriktirdi; rate() en az 2 "
                     "örnek ister. Daha uzun beklemek için: MON_WARMUP_S=600 (sorgu: %s)"
                     % (warm, ornek, kisa))
                continue
            res, hata = query(expr)
            if res is None:
                line("FAIL", ad, "sorgu HATASI: %s (sorgu: %s)" % (hata, kisa))
                continue
            if res:
                line("PASS", ad + " (%d seri)" % len(res))
                continue
            # BOŞ — sebebini ayırt et.
            adlar = metrik_adlari(expr)
            yok = [a for a in adlar if a not in bilinen] if bilinen else []
            if yok:
                line("FAIL", ad,
                     "BOŞ — şu metrikler Prometheus'ta HİÇ YOK: %s. Zincir exporter ile "
                     "Prometheus arasında kopuk (exporter o metriği üretmiyor ya da adı "
                     "değişmiş); panel her zaman boş çizer. (sorgu: %s)"
                     % (", ".join(yok), kisa))
            elif adlar:
                line("FAIL", ad,
                     "BOŞ — metrikler (%s) Prometheus'ta var ama sorgunun filtresi/eşlemesi "
                     "hiçbir seri seçmedi: etiket uyuşmazlığı ya da o an gerçekten sıfır olan "
                     "bir durum (ör. hiç consumer group yok) olabilir. (sorgu: %s)"
                     % (", ".join(adlar[:4]), kisa))
            else:
                line("FAIL", ad, "BOŞ — sonuç yok (sorgu: %s)" % kisa)
PY
probe_rc=$?
emit_or_fail "$TMPD/queries.out" "$TMPD/queries.err" "pano sorguları Prometheus'a soruldu"
if [ "$probe_rc" -ne 0 ]; then
    t_fail "pano sorgu sondası eksiksiz tamamlandı" \
           "çıkış kodu $probe_rc (zaman aşımı ya da çökme) — sınanmamış sorgular kalmış olabilir; MON_BATCH_TIMEOUT ile süreyi artırın"
fi
if [ -s "$TMPD/queries.err" ]; then
    warn "pano sorgu sondası uyarı verdi: $(head -c 300 "$TMPD/queries.err" | tr '\n' ' ')"
fi

# =============================================================================
# 5) MOTOR KAPAT/AÇ → HEDEF LİSTESİ KENDİNİ GÜNCELLİYOR MU?
# =============================================================================
heading "5) Motor kapatılınca hedeften düşüyor, açılınca geri geliyor mu?"

# Bu, izlemenin "kendi kendini ayarlar" iddiasının tek gerçek kanıtı. Hedef
# listesini controller yazar ve YALNIZ aktivasyon/deaktivasyon anında yazar.
# Bu yol kırıldığında hiçbir şey bağırmaz; kanıt için gerçekten kapatıp açmak
# gerekir. Container'a bakmak bunu göstermez, çünkü container zaten doğru
# durumdadır — yanlış olan, onu takip etmeyen listedir.
cycle_engine=""
if [ "$MON_NO_CYCLE" = "1" ]; then
    t_skip "motor kapatılınca hedef listesinden düşüyor / açılınca geri geliyor" \
           "MON_NO_CYCLE=1 verildi — bu test bir veritabanını kısa süre kapatır"
elif [ -n "$MON_CYCLE_ENGINE" ]; then
    # Elle verilen motoru DOĞRULA. Yanlış yazılmış bir ad sessizce "test yok"a
    # dönüşmemeli; kullanıcı testi çalıştırdığını sanıp geçmiş sayardı.
    if ! awk -F'\t' -v k="$MON_CYCLE_ENGINE" '$1==k {f=1} END {exit !f}' "$TMPD/engines.txt"; then
        t_fail "MON_CYCLE_ENGINE ile verilen motor katalogda var" \
               "'$MON_CYCLE_ENGINE' catalog.json'da yok — geçerli kimlikler: $(cut -f1 "$TMPD/engines.txt" | tr '\n' ' ')"
    elif ! engine_up "$MON_CYCLE_ENGINE"; then
        t_skip "$MON_CYCLE_ENGINE kapatılınca hedeften düşüyor / açılınca geri geliyor" \
               "MON_CYCLE_ENGINE=$MON_CYCLE_ENGINE seçildi ama o motor şu an kapalı"
    else
        cycle_engine="$MON_CYCLE_ENGINE"
    fi
else
    # Tercih sırası: yeniden başlaması ucuz olanlar önce; açılışı dakikalar
    # süren JVM tabanlılar (elasticsearch, cassandra) en sonda.
    for cand in redis mongodb mariadb postgresql rabbitmq minio clickhouse kafka elasticsearch cassandra; do
        case " $ACTIVE_ENGINES " in *" $cand "*) ;; *) continue ;; esac
        cexsvc="$(awk -F'\t' -v k="$cand" '$1==k {print $4}' "$TMPD/engines.txt")"
        [ -n "$cexsvc" ] || continue
        # Devir geçirmiş motora DOKUNMA: orada roller yer değiştirmiştir ve
        # kapat/aç, testin amacını aşan bir kurtarma işine dönüşür.
        [ "$(primary_of "$cand")" = "$cand" ] || continue
        cycle_engine="$cand"; break
    done
    [ -n "$cycle_engine" ] || t_skip \
        "motor kapatılınca hedef listesinden düşüyor / açılınca geri geliyor" \
        "exporter'ı olan, açık ve devir geçirmemiş bir motor yok (MON_CYCLE_ENGINE=<motor> ile seçebilirsiniz)"
fi

if [ -n "$cycle_engine" ]; then
    before="$(prom_target_count "$cycle_engine")"
    if [ "${before:-0}" -lt 1 ] 2>/dev/null; then
        t_skip "$cycle_engine kapatılınca hedef listesinden düşüyor" \
               "test başlamadan da hedef listesinde yoktu (sayı=$before) — kapanışın etkisi ölçülemez"
    else
        warn "$cycle_engine KISA SÜRE KAPATILIYOR (veri silinmez, yalnız container durur). Atlamak için: MON_NO_CYCLE=1"
        RESTORE_ENGINE="$cycle_engine"
        if run_t 600 "$STACK_ROOT/stack.sh" disable "$cycle_engine" > "$TMPD/cycle.log" 2>&1; then
            log "$cycle_engine kapatıldı; hedeften düşmesi bekleniyor (file_sd 15 sn'de bir tazelenir)"
            if wait_for "$cycle_engine hedefinin aktif listeden düşmesi" 150 target_gone "$cycle_engine"; then
                t_ok "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü"
            else
                t_fail "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü" \
                       "150 sn sonra hâlâ listede (sayı=$(prom_target_count "$cycle_engine")) — kapalı motor için sonsuza dek 'erişilemiyor' alarmı üretilir"
            fi
            # Dosya da güncellenmiş mi? Prometheus'un listesi doğru olup dosya
            # eskimiş olabilir; o zaman controller yeniden başladığında eski
            # liste geri gelir ve arıza günler sonra ortaya çıkar.
            if [ -f "$TARGETS_JSON" ]; then
                # grep yerine JSON ayrıştırılıyor: girinti/biçim değişirse grep
                # sessizce "bulamadım" der ve test yalancı biçimde GEÇER.
                tstate="$(PYTHONIOENCODING=utf-8 python3 -c '
import json, sys
try:
    items = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("HATA"); raise SystemExit(0)
print("VAR" if any((i.get("labels") or {}).get("engine") == sys.argv[2] for i in items) else "YOK")
' "$TARGETS_JSON" "$cycle_engine" 2>/dev/null)"
                case "$tstate" in
                    YOK) t_ok "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" ;;
                    VAR) t_fail "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" \
                                "dosyada hâlâ engine=\"$cycle_engine\" kaydı var — controller kapatmada hedef listesini tazelememiş" ;;
                    *)   t_fail "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" \
                                "hedef dosyası okunamadı/ayrıştırılamadı" ;;
                esac
            else
                t_skip "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" \
                       "hedef dosyası yok"
            fi
        else
            t_fail "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü" \
                   "./stack.sh disable $cycle_engine başarısız: $(tail -3 "$TMPD/cycle.log" | tr '\n' ' ')"
        fi

        # Geri aç ve hedefin GERÇEKTEN up olmasını bekle. Listeye geri gelip
        # "down" kalmak, kullanıcı açısından hiç açılmamış olmakla aynı şeydir.
        log "$cycle_engine geri açılıyor…"
        if run_t "$MON_ENABLE_TIMEOUT" "$STACK_ROOT/stack.sh" enable "$cycle_engine" >> "$TMPD/cycle.log" 2>&1; then
            RESTORE_ENGINE=""
            if wait_for "$cycle_engine hedefinin listeye dönüp up olması" "$MON_ENABLE_TIMEOUT" \
                        target_up "$cycle_engine"; then
                t_ok "$cycle_engine açılınca hedef listesine geri geldi ve up=1 oldu"
            else
                t_fail "$cycle_engine açılınca hedef listesine geri geldi ve up=1 oldu" \
                       "${MON_ENABLE_TIMEOUT} sn içinde up=1 olmadı — motor açık ama grafikleri boş kalır"
            fi
        else
            t_fail "$cycle_engine açılınca hedef listesine geri geldi ve up=1 oldu" \
                   "./stack.sh enable $cycle_engine BAŞARISIZ: $(tail -3 "$TMPD/cycle.log" | tr '\n' ' ')"
        fi
    fi
fi

# =============================================================================
# 6) CONTROLLER /metrics
# =============================================================================
heading "6) controller /metrics dbstack_* üretiyor ve limitler GERÇEK mi?"

# Bu uç, kaldırılan cAdvisor'ın yerine geçti: container başına bellek/CPU ve
# bellek bütçesi buradan geliyor. Uç sessizce boşalırsa Genel Bakış panosunun
# yarısı boş kalır — cAdvisor'da yaşanan arızanın ta kendisi.
if py_in_net <<'PY' > "$TMPD/metrics.txt" 2>"$TMPD/metrics.err"
import urllib.request, sys
try:
    sys.stdout.write(urllib.request.urlopen(
        "http://controller:8000/metrics", timeout=25).read().decode("utf-8", "replace"))
except Exception as e:
    sys.stderr.write(repr(e) + "\n")
    sys.exit(1)
PY
then
    t_ok "controller /metrics ucu cevap veriyor ($(wc -l < "$TMPD/metrics.txt" | tr -d ' ') satır)"
else
    t_fail "controller /metrics ucu cevap veriyor" \
           "$(head -c 200 "$TMPD/metrics.err" 2>/dev/null | tr '\n' ' ')"
fi

for m in dbstack_container_up dbstack_container_memory_bytes \
         dbstack_container_memory_limit_bytes dbstack_container_cpu_percent \
         dbstack_engine_active dbstack_host_memory_total_bytes \
         dbstack_memory_committed_bytes dbstack_memory_budget_bytes \
         dbstack_disk_free_bytes; do
    mn="$(grep -c "^${m}[ {]" "$TMPD/metrics.txt" 2>/dev/null || true)"
    if [ "${mn:-0}" -gt 0 ] 2>/dev/null; then
        t_ok "$m metriği yayınlanıyor ($mn seri)"
    else
        t_fail "$m metriği yayınlanıyor" "uçta bu ada ait hiç seri yok"
    fi
done

# Uç ayakta olsa bile Prometheus onu toplamıyor olabilir (job=controller hedefi
# yoksa aynen böyle olur). Zincirin bu halkasını ayrıca sınıyoruz.
pn="$(prom_scalar 'count(dbstack_container_memory_limit_bytes)')"; pn="${pn%%.*}"
if [ "${pn:-0}" -gt 0 ] 2>/dev/null; then
    t_ok "controller metrikleri Prometheus'a düşüyor (dbstack_container_memory_limit_bytes: $pn seri)"
else
    t_fail "controller metrikleri Prometheus'a düşüyor" \
           "Prometheus'ta hiç dbstack_container_memory_limit_bytes serisi yok — uç çalışsa bile Genel Bakış panosu boş kalır"
fi

# --------------------------------------------------------------------------
# Limit metriği GERÇEK container limitiyle aynı mı?
# --------------------------------------------------------------------------
# Ürünün can alıcı iddiası "belleği ben hesaplıyorum". Metrik yanlış sayıyı
# gösterirse kullanıcı yanlış bir hesabı doğru sanır ve OOM'a kadar fark etmez.
# Karşılaştırma `docker inspect .HostConfig.Memory` ile yapılır; controller
# değeri MiB'e yuvarlayarak yayınladığı için beklenen değeri aynı şekilde
# yuvarlıyoruz (bkz. controller/app.py: mem_mb = int(mem) // (1024*1024)).
docker ps -q --filter "label=com.docker.compose.project=$PROJ" > "$TMPD/ids.txt" 2>/dev/null
if [ -s "$TMPD/ids.txt" ]; then
    # shellcheck disable=SC2046
    docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}|{{.HostConfig.Memory}}' \
        $(cat "$TMPD/ids.txt") > "$TMPD/limits.txt" 2>/dev/null
else
    : > "$TMPD/limits.txt"
fi

seen=""
while IFS= read -r satir; do
    lsvc="$(printf '%s' "$satir" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
    lval="$(printf '%s' "$satir" | awk '{print $NF}')"; lval="${lval%%.*}"
    [ -n "$lsvc" ] || continue
    seen="$seen $lsvc"
    lreal="$(awk -F'|' -v s="$lsvc" '$1==s {print $2; exit}' "$TMPD/limits.txt")"
    if [ -z "$lreal" ]; then
        t_fail "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı" \
               "docker'da böyle bir container yok — metrik hayalet bir servisi bildiriyor"
        continue
    fi
    lbek=$(( (lreal / 1048576) * 1048576 ))
    if [ "${lval:-0}" = "$lbek" ]; then
        t_ok "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı ($((lbek / 1048576)) MiB)"
    else
        t_fail "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı" \
               "metrik $lval bayt diyor, docker inspect $lreal bayt ($((lreal / 1048576)) MiB) diyor"
    fi
done < <(grep '^dbstack_container_memory_limit_bytes{' "$TMPD/metrics.txt" 2>/dev/null)

# Ters yön: limiti OLAN ama metriği yayınlanmayan container. Eksik metrik
# grafikte "veri yok" olarak değil, çoğu panelde HİÇ GÖRÜNMEMEK olarak çıkar —
# yani fark edilmez.
eksik=""
while IFS='|' read -r rsvc rmem; do
    [ -n "${rsvc:-}" ] || continue
    [ "${rmem:-0}" -gt 0 ] 2>/dev/null || continue
    case " $seen " in *" $rsvc "*) ;; *) eksik="$eksik $rsvc" ;; esac
done < "$TMPD/limits.txt"
if [ -n "$eksik" ]; then
    t_fail "bellek limiti olan her çalışan container için limit metriği yayınlanıyor" \
           "metrikte olmayanlar:$eksik"
else
    t_ok "bellek limiti olan her çalışan container için limit metriği yayınlanıyor"
fi

# =============================================================================
# ÖZET
# =============================================================================
heading "ÖZET"
TOPLAM=$((PASS_N + FAIL_N))
if [ "$SKIP_N" -gt 0 ]; then
    printf '%s: %d/%d geçti (%d atlandı)\n' "$ALAN" "$PASS_N" "$TOPLAM" "$SKIP_N"
else
    printf '%s: %d/%d geçti\n' "$ALAN" "$PASS_N" "$TOPLAM"
fi
if [ "$WE_ENABLED_MONITORING" = 1 ] && [ "$MON_KEEP_MONITORING" != 0 ]; then
    log "izleme bu betik tarafından açıldı ve AÇIK BIRAKILDI (kapatmak için: ./stack.sh disable monitoring)"
fi
[ "$FAIL_N" -gt 0 ] && exit 1
exit 0
