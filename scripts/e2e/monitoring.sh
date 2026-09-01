#!/bin/bash
# =============================================================================
# databases-stack — E2E: İZLEME ZİNCİRİ
# =============================================================================
# Bu betik "Grafana açılıyor mu" diye sormaz. İzleme bir ZİNCİRDİR:
#
#     exporter → Prometheus hedefi → seri → uyarı kuralı → pano sorgusu → panel
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
# DÖRT SONUÇ TÜRÜ (scripts/e2e/lib.sh):
#   t_ok      ölçtük, doğru        t_skip    ön koşul yok (meşru)
#   t_fail    ölçtük, yanlış       t_unknown ÖLÇEMEDİK → başarısız sayılır
#
# Bu betikteki en önemli kural şu: ÖLÇÜM ARACI ÇALIŞMADIĞINDA HİÇBİR SATIR
# YEŞİL YAZMAZ. docker cevap vermezse, Prometheus'a sorulamazsa, sonda çöker
# ya da dosya okunamazsa sonuç t_unknown'dır. "Bilmiyorum" ile "iyi" aynı şey
# değildir; denetimde bu betikte bulunan bütün yalancı-geçtiler tam olarak bu
# ayrımın yapılmamasından çıkmıştı.
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
#
# DOKUNULMAYANLAR: replikasyonu AÇIK bir motor kapat/aç testine SOKULMAZ.
# Sebebi ürün tarafında: do_deactivate() replika servisini de siler ve
# replikasyon profilini state'ten çıkarır (controller/app.py:2205-2210), buna
# karşılık do_activate() normal yolda yalnız engine["services"] + engine
# profilini açar (2135 civarı) — replika GERİ GELMEZ. Böyle bir motoru
# döngüye sokmak, kullanıcının yüksek erişilebilirliğini bir teste kurban
# etmek olurdu; üstelik sessizce.
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/common.sh
source "$SELF_DIR/../lib/common.sh" || { echo "scripts/lib/common.sh okunamadı" >&2; exit 1; }
# Sayaçlar, dört sonuç türü ve ÇIKIŞ KODU ortak kütüphanede — common.sh'ten
# SONRA source ediliyor ki renkler oradan gelsin.
E2E_SUITE="monitoring"
# shellcheck source=lib.sh
source "$SELF_DIR/lib.sh" || { echo "scripts/e2e/lib.sh okunamadı" >&2; exit 1; }
cd "$STACK_ROOT" || exit 1
load_env

DASH_DIR="$STACK_ROOT/config/grafana/dashboards"
RULES_DIR="$STACK_ROOT/config/prometheus/rules"
TARGETS_JSON="$STACK_ROOT/state/prometheus/targets.json"
STATE_JSON="$STACK_ROOT/state/state.json"
PROJ="${STACK_PROJECT:-databases-stack}"
CTRL_C="controller"                     # ağ içi isteklerin atıldığı container
PROM_URL="http://prometheus:9090"
GRAF_URL="http://grafana:3000"

# Sayısal ayarları DOĞRULUYORUZ: "MON_WARMUP_S=cok" gibi bir yazım hatası
# `[ "$x" -gt 0 ]` karşılaştırmasını hata koduna düşürür ve o dal sessizce
# atlanırdı — yani bir yazım hatası bütün bekleme mantığını kapatırdı.
sayi_ya_da() {                          # $1 değer, $2 varsayılan, $3 ad
    case "${1:-}" in
        ''|*[!0-9]*) warn "$3 sayı değil ('${1:-}') — varsayılan $2 kullanılıyor"
                     printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}
MON_WARMUP_S="$(sayi_ya_da "${MON_WARMUP_S:-360}" 360 MON_WARMUP_S)"
MON_NO_CYCLE="${MON_NO_CYCLE:-0}"
MON_CYCLE_ENGINE="${MON_CYCLE_ENGINE:-}"
MON_KEEP_MONITORING="${MON_KEEP_MONITORING:-1}"
MON_HTTP_TIMEOUT="$(sayi_ya_da "${MON_HTTP_TIMEOUT:-60}" 60 MON_HTTP_TIMEOUT)"
MON_ENABLE_TIMEOUT="$(sayi_ya_da "${MON_ENABLE_TIMEOUT:-300}" 300 MON_ENABLE_TIMEOUT)"
MON_BATCH_TIMEOUT="$(sayi_ya_da "${MON_BATCH_TIMEOUT:-300}" 300 MON_BATCH_TIMEOUT)"

# =============================================================================
# SONDA ÇIKTISINI TEST SATIRINA ÇEVİRME
# =============================================================================
# Python sondaları sonucu "DURUM<TAB>ad<TAB>ayrıntı" satırları olarak basar;
# burada tek tek test satırına çevriliyor. SÜREÇ İKAMESİYLE (`< <(...)`) ya da
# dosyadan okunmalı — boru hattı kullanılsaydı döngü alt kabukta çalışır ve
# sayaçlar geri gelmezdi: özet satırı sessizce "0/0 geçti" derdi.
#
# BİLİNMEYEN SATIR ARTIK LOG'A DÜŞMÜYOR. Eskiden biçimi bozuk (ama boş
# olmayan) bir sonda çıktısı hiç test satırı üretmiyordu: emit sessizce log
# basıyor, emit_or_fail de "dosya boş değil" diye memnun kalıyordu. Sonuç:
# sıfır kontrol, sıfır uyarı. Bozuk biçim artık ÖLÇÜLEMEDİ'dir.
EMIT_SATIR=0                            # emit()'in ürettiği test satırı sayısı
EMIT_KAYNAK="sonda"                     # hangi sondanın çıktısını okuduğumuz
emit() {
    local st ad ay
    while IFS=$'\t' read -r st ad ay; do
        case "$st" in
            PASS)    EMIT_SATIR=$((EMIT_SATIR + 1)); t_ok "$ad" ;;
            FAIL)    EMIT_SATIR=$((EMIT_SATIR + 1)); t_fail "$ad" "${ay:-}" ;;
            SKIP)    EMIT_SATIR=$((EMIT_SATIR + 1)); t_skip "$ad" "${ay:-}" ;;
            UNKNOWN) EMIT_SATIR=$((EMIT_SATIR + 1)); t_unknown "$ad" "${ay:-}" ;;
            '')      : ;;
            *)       EMIT_SATIR=$((EMIT_SATIR + 1))
                     t_unknown "$EMIT_KAYNAK — sonda çıktısı çözülemedi" \
                       "beklenen biçim 'DURUM<TAB>ad<TAB>ayrıntı'; gelen: $(printf '%s %s %s' "$st" "${ad:-}" "${ay:-}" | cut -c1-160)" ;;
        esac
    done
    return 0
}

# Bir sonda HİÇ satır üretmezse (çöktü, zaman aşımına uğradı, container gitti)
# emit sessiz kalır ve o bölüm "hiç test yokmuş" gibi geçip gider — yani tam da
# bu betiğin avlamaya çalıştığı türden sessiz bir boşluk. Ölçemedik sayıyoruz.
emit_or_unknown() {                     # $1 çıktı, $2 stderr, $3 test adı
    local once="$EMIT_SATIR"
    # Biçimsiz satırlar özette birbirinden ayırt edilebilsin diye kaynağı da
    # yazıyoruz: dört ayrı "sonda çıktısı çözülemedi" satırı, hangi sondanın
    # bozulduğunu söylemediği sürece bakan kişiye yardım etmiyor.
    EMIT_KAYNAK="$3"
    [ -s "$1" ] && emit < "$1"
    if [ "$EMIT_SATIR" -eq "$once" ]; then
        t_unknown "$3" \
            "sonda hiç sonuç satırı üretmedi (çöktü, zaman aşımına uğradı ya da biçimi bozuk): $(head -c 300 "$2" 2>/dev/null | tr '\n' ' ')"
    fi
    return 0
}

# Sondanın çıkış kodu: 0 dışındaki her şey "liste YARIM olabilir" demektir.
# Yarım listeyi tam sanmak, testin kendisini yalancı yapar.
sonda_rc() {                            # $1 rc, $2 test adı, $3 ipucu
    [ "${1:-0}" -eq 0 ] && return 0
    if [ "$1" -eq 124 ]; then
        t_unknown "$2" "sonda ZAMAN AŞIMINA uğradı (çıkış 124) — üretilen liste YARIM. $3"
    else
        t_unknown "$2" "sonda çıkış kodu $1 (çökme) — üretilen liste YARIM olabilir. $3"
    fi
    return 0
}

# =============================================================================
# ZAMAN SINIRI — hiçbir bekleme sonsuz olmasın
# =============================================================================
# `timeout` (coreutils) yoksa eski sürüm komutu SINIRSIZ çalıştırıyordu:
# ./stack.sh enable bir işi bekler ve stack.sh'in watch_job'unun kendi zaman
# aşımı YOKTUR (bkz. stack.sh:55-75) — betik ne yeşil ne kırmızı verip
# sonsuza kadar asılı kalabiliyordu. Artık timeout yoksa kendi bekçimizi
# kuruyoruz; stdin `<&0` ile açıkça devrediliyor, yoksa bash arka plandaki
# komutun girdisini /dev/null'a bağlar ve heredoc'la beslenen python sondaları
# boş girdiyle çalışırdı.
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
[ "$HAVE_TIMEOUT" = 1 ] || warn "timeout (coreutils) yok — kabuk içi bekçi kullanılıyor (1 sn çözünürlük)"
run_t() {                               # run_t <saniye> <komut...>  (124 = süre doldu)
    local s="$1"; shift
    if [ "$HAVE_TIMEOUT" = 1 ]; then timeout "$s" "$@"; return $?; fi
    local pid rc bekle=0
    "$@" <&0 & pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$bekle" -ge "$s" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 1
            kill -KILL "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            return 124
        fi
        sleep 1
        bekle=$((bekle + 1))
    done
    wait "$pid"; rc=$?
    return $rc
}

# Bir koşul sağlanana kadar bekle; beklerken NEYİ beklediğini ve ne kadar
# kaldığını yaz. Sessiz bekleme, donmuş betikten ayırt edilemez.
# DİKKAT: bu fonksiyonun "başarısız" dönüşü tek başına KALDI anlamına GELMEZ.
# Koşul sağlanmadı da olabilir, ölçüm aracı hiç çalışmadı da. Çağıran taraf
# beklemeden sonra SON BİR ÖLÇÜM daha yapıp ikisini ayırmak zorunda.
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

# ÖLÇÜM HATASININ SEBEBİ NİYE DOSYADA TUTULUYOR:
# sondaların çoğu `deger="$(prom_scalar ...)"` biçiminde, yani ALT KABUKTA
# çağrılıyor. Alt kabukta atanan kabuk değişkeni ana kabuğa DÖNMEZ; sebebi
# değişkende tutan ilk sürümde bütün ÖLÇÜLEMEDİ satırları "sebep belirtilmedi"
# diyordu — yani ölçümün niye düştüğü tam da en çok gereken yerde kayboluyordu
# (sahte docker ile üretilip görüldü). Dosyayı alt kabuk da yazar, ana kabuk da
# okur.
HATA_DOSYA="$TMPD/son_olcum_hatasi.txt"
hata_yaz() { printf '%s' "${1:-}" > "$HATA_DOSYA" 2>/dev/null; }
hata_oku() { cat "$HATA_DOSYA" 2>/dev/null; }
hata_yaz ""

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
# Yalnız EXIT: INT/TERM'i lib.sh yakalıyor (kesinti = GEÇERSİZ koşu, çıkış
# 130). lib.sh'in trap'i exit çağırdığı için bu temizlik yine de çalışır;
# kendi INT trap'imizi kurmak lib.sh'inkini ezerdi ve yarıda kesilen koşu
# "geçti" görünürdü.
trap cleanup EXIT

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
# kontrol var (sonda_rc).
py_in_net_batch() {
    run_t "$MON_BATCH_TIMEOUT" docker exec -i "$@" "$CTRL_C" python -
}

# ÖLÇÜM ARACININ KENDİSİ ÇALIŞIYOR MU? Bütün ağ içi ölçümler controller
# içindeki python'a bağlı. O çalışmıyorsa aşağıdaki her "cevap gelmedi"
# satırı ürün hakkında değil, ölçüm aracı hakkında konuşuyor demektir.
tool_alive() {
    local out rc
    out="$(run_t 30 docker exec -i "$CTRL_C" python -c 'print("HAZIR")' 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'HAZIR'; then
        hata_yaz ""; return 0
    fi
    hata_yaz "docker exec $CTRL_C python → çıkış $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    return 1
}

# =============================================================================
# DOCKER — cevap vermemesi "her şey kapalı" DEĞİLDİR
# =============================================================================
# common.sh'in container_running()'i docker hatasını yutar ve "container yok"
# der. Bu betikte o davranış ölümcül: docker cevap vermediğinde bütün motorlar
# "kapalı" sanılır, bütün pano testleri ATLANDI olur ve koşu yeşil biter.
PS_NAMES=""; PS_OK=0
docker_ps_refresh() {                   # 0 = liste tazelendi · 1 = docker cevap vermedi
    local out rc
    out="$(run_t 30 docker ps --format '{{.Names}}' 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        PS_OK=0
        hata_yaz "docker ps → çıkış $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 1
    fi
    PS_NAMES="$out"; PS_OK=1; hata_yaz ""
    return 0
}
container_in_cache() {                  # önbellekteki listede var mı
    [ "$PS_OK" = 1 ] || return 1
    printf '%s\n' "$PS_NAMES" | grep -qx "$1"
}
container_state() {                     # 0 çalışıyor · 1 yok · 2 ÖLÇEMEDİK
    docker_ps_refresh || return 2
    container_in_cache "$1" && return 0
    return 1
}

# =============================================================================
# PROMETHEUS SORGULARI — "ölçemedim" ile "değer 0" ASLA aynı şey değil
# =============================================================================
# Eski sürüm sorgu düştüğünde stdout'a "0" basıyordu. count(up==1) sorusunda
# bu, "motor toplanmıyor" ile "Prometheus'a hiç ulaşamadım"ı aynı satıra
# yazmak demekti; kapat/aç testini yalancı bir sonuca çeviriyordu. Artık ölçüm
# başarısızsa ÇIKIŞ KODU 3 dönüyor ve sebebi `hata_oku` ile okunuyor.
prom_scalar() {                         # $1 PromQL → değer stdout · rc 0 ölçtük · 3 ölçemedik
    local out rc deger sebep
    out="$(py_in_net -e "E2E_Q=$1" 2>&1 <<'PY'
import os, json, urllib.request, urllib.parse
try:
    body = urllib.parse.urlencode({"query": os.environ["E2E_Q"]}).encode()
    req = urllib.request.Request("http://prometheus:9090/api/v1/query", data=body)
    j = json.loads(urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace"))
except Exception as e:
    print("OLCULEMEDI\t%r" % (e,)); raise SystemExit(0)
if j.get("status") != "success":
    print("OLCULEMEDI\tPrometheus hata döndü: %s" % (j.get("error") or "?")); raise SystemExit(0)
res = (j.get("data") or {}).get("result") or []
print("DEGER\t%s" % (res[0]["value"][1] if res else "0"))
PY
)"; rc=$?
    deger="$(printf '%s\n' "$out" | awk -F'\t' '$1=="DEGER" {print $2; exit}')"
    if [ "$rc" -eq 0 ] && [ -n "$deger" ]; then
        hata_yaz ""; printf '%s' "$deger"; return 0
    fi
    sebep="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"
    [ -n "$sebep" ] || sebep="ağ içi sonda çıkış kodu $rc, çıktı yok"
    hata_yaz "$sebep"
    return 3
}

# Bir motorun AKTİF hedef listesindeki hedef sayısı.
# rc 3 = Prometheus'a sorulamadı. Bu "hedef düştü" DEĞİLDİR; ikisini
# karıştırmak kapat/aç testini yalancı bir GEÇTİ'ye çevirirdi.
prom_target_count() {                   # $1 motor kimliği → sayı stdout · rc 0/3
    local out rc deger sebep
    out="$(py_in_net -e "E2E_EID=$1" 2>&1 <<'PY'
import os, json, urllib.request
eid = os.environ["E2E_EID"]
try:
    j = json.loads(urllib.request.urlopen(
        "http://prometheus:9090/api/v1/targets?state=active",
        timeout=25).read().decode("utf-8", "replace"))
    n = sum(1 for t in (j["data"]["activeTargets"] or [])
            if (t.get("labels") or {}).get("engine") == eid)
except Exception as e:
    print("OLCULEMEDI\t%r" % (e,)); raise SystemExit(0)
print("DEGER\t%d" % n)
PY
)"; rc=$?
    deger="$(printf '%s\n' "$out" | awk -F'\t' '$1=="DEGER" {print $2; exit}')"
    if [ "$rc" -eq 0 ] && [ -n "$deger" ]; then
        hata_yaz ""; printf '%s' "$deger"; return 0
    fi
    sebep="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-220)"
    [ -n "$sebep" ] || sebep="ağ içi sonda çıkış kodu $rc, çıktı yok"
    hata_yaz "$sebep"
    return 3
}

# Ağ içinden HTTP: "uç cevap vermiyor" (ölçtük, arıza) ile "sonda hiç
# çalışmadı" (ölçemedik) ayrı ayrı raporlanabilsin diye kod ve gövde ayrı.
http_probe() {                          # $1 URL → HTTP kodu stdout (0 = bağlanamadı) · rc 0/3
    local out rc satir govde
    out="$(py_in_net -e "E2E_URL=$1" 2>&1 <<'PY'
import os, urllib.request, urllib.error
url = os.environ["E2E_URL"]
try:
    r = urllib.request.urlopen(url, timeout=20)
    g = r.read(400).decode("utf-8", "replace")
    print("KOD\t%d\t%s" % (r.getcode(), " ".join(g.split())[:200]))
except urllib.error.HTTPError as e:
    print("KOD\t%d\tHTTP hata gövdesi: %s"
          % (e.code, " ".join(e.read(200).decode("utf-8", "replace").split())))
except Exception as e:
    print("KOD\t0\tbağlanılamadı: %r" % (e,))
PY
)"; rc=$?
    satir="$(printf '%s\n' "$out" | awk -F'\t' '$1=="KOD" {print; exit}')"
    if [ "$rc" -ne 0 ] || [ -z "$satir" ]; then
        hata_yaz "ağ içi sonda çalışmadı (çıkış $rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 3
    fi
    # Cevap gövdesini de hata kanalına yazıyoruz: çağıran taraf alt kabuk
    # yüzünden buradaki değişkenleri göremez, ama "son HTTP cevabı neydi"
    # yazmayan bir KALDI satırı okunmaz olur.
    govde="$(printf '%s' "$satir" | cut -f3)"
    hata_yaz "$govde"
    printf '%s' "$(printf '%s' "$satir" | cut -f2)"
    return 0
}
http_ok() {                             # wait_for koşulu: 200 mü
    local k
    k="$(http_probe "$1")" || return 1
    [ "$k" = "200" ]
}

# wait_for koşulları (kabuk fonksiyonu olduğu için ortam aynı kabukta kalır).
# Ölçüm düşerse "koşul sağlanmadı" derler; ayrımı bekleme BİTTİKTEN sonra
# çağıran taraf yapar (aşağıda her kullanım yerinde son bir ölçüm var).
target_gone() {
    local n; n="$(prom_target_count "$1")" || return 1
    [ "$n" = "0" ]
}
target_up() {
    local n; n="$(prom_scalar "count(up{job=\"databases\",engine=\"$1\"} == 1)")" || return 1
    n="${n%%.*}"
    [ "${n:-0}" -ge 1 ] 2>/dev/null
}

# =============================================================================
# KATALOG — motor listesi, exporter'lar ve portlar BURADAN okunur
# =============================================================================
# Hiçbiri betiğe sabit yazılmaz: kataloğa yeni bir motor eklendiğinde bu betik
# onu kendiliğinden sınamaya başlamalı. Aksi hâlde yeni motorun izlemesi hiç
# test edilmeden ürüne girer ve kimse fark etmez.
if ! command -v python3 >/dev/null 2>&1; then
    t_unknown "katalog ve panolar okundu" \
              "python3 yok — bu betiğin ÖLÇÜM ARACI eksik; hiçbir şey ölçülemez"
    e2e_finish; exit $?
fi
if [ ! -f "$CATALOG" ]; then
    t_fail "catalog.json okunabiliyor" "dosya yok: $CATALOG — motor listesi olmadan izleme sınanamaz"
    e2e_finish; exit $?
fi
if [ ! -d "$DASH_DIR" ]; then
    t_fail "pano klasörü var (config/grafana/dashboards)" \
           "klasör yok: $DASH_DIR — Grafana sağlaması yapılacak dosya bulamaz, bütün panolar eksik demektir"
    e2e_finish; exit $?
fi

# Alanlar: 1 id · 2 ad · 3 ana servis · 4 exporter servisi · 5 port ·
#          6 scrape yolu · 7 tür · 8 replikasyon profili · 9 replika servisi
# 8 ve 9 kapat/aç testinin "bu motora dokunma" kararı için gerekli.
PYTHONIOENCODING=utf-8 python3 - "$CATALOG" > "$TMPD/engines.txt" 2>"$TMPD/engines.err" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
for e in cat["engines"]:
    ex = e.get("exporter") or {}
    rep = e.get("replication") or {}
    print("\t".join([
        e["id"], e["name"], e.get("primary_service") or e["id"],
        ex.get("service") or "", str(ex.get("port") or ""),
        ex.get("scrape_path") or "/metrics", e.get("kind", "database"),
        rep.get("profile") or "", rep.get("replica_service") or "",
    ]))
PY
if [ ! -s "$TMPD/engines.txt" ]; then
    t_unknown "catalog.json ayrıştırıldı" \
              "motor listesi çıkarılamadı: $(head -c 300 "$TMPD/engines.err" 2>/dev/null | tr '\n' ' ')"
    e2e_finish; exit $?
fi

# Motorun ana servisi ŞU AN çalışıyor mu?
# common.sh'in engine_active()'i çoğu motorda doğrudur, çünkü orada motorun
# KİMLİĞİ ile ana servisin ADI aynıdır (mariadb → mariadb). İzleme'de değil:
# kimlik "monitoring", ana servis "grafana"; primary_of("monitoring") de
# topolojide kayıt olmadığı için "monitoring" döner ve öyle bir container
# yoktur. Bu yüzden aktifliği KATALOĞUN primary_service'i üzerinden çözüyoruz,
# devir olmuşsa primary_of'un bildirdiği gerçek ana kopyayı kullanıyoruz.
# Aksi hâlde izleme açıkken bile "kapalı" sanıp bütün pano testlerini atlar,
# yani hiçbir şeyi sınamadan yeşil biterdik.
engine_state() {                        # 0 açık · 1 kapalı · 2 ÖLÇEMEDİK
    local eid="$1" prim svc
    svc="$(awk -F'\t' -v k="$eid" '$1==k {print $3}' "$TMPD/engines.txt")"
    [ -n "$svc" ] || return 2
    prim="$(primary_of "$eid")"
    [ -n "$prim" ] || prim="$svc"
    [ "$prim" = "$eid" ] && prim="$svc"
    [ "$PS_OK" = 1 ] || return 2
    container_in_cache "$prim"
}

# Motorun replikasyonu AÇIK mı?  0 açık · 1 kapalı · 2 ÖLÇEMEDİK
# NİYE ÖNEMLİ: kapat/aç testi replikasyonu açık bir motora uygulanırsa ürün
# replikayı siler ve geri kurmaz (do_deactivate replika servisini de `rm -f`
# eder ve profili state'ten çıkarır; do_activate normal yolda yalnız
# engine["services"] açar — replica_service o listede YOK). Ölçemediğimizde de
# DOKUNMUYORUZ: "bilmiyorum" bu kararda "sakıncası yok" anlamına gelemez.
replication_state() {
    local eid="$1" repprof repsvc pr
    repprof="$(awk -F'\t' -v k="$eid" '$1==k {print $8}' "$TMPD/engines.txt")"
    repsvc="$(awk -F'\t' -v k="$eid" '$1==k {print $9}' "$TMPD/engines.txt")"
    [ -n "$repprof" ] || return 1       # katalogda replikasyon tanımı yok
    if [ "$PS_OK" = 1 ] && [ -n "$repsvc" ] && container_in_cache "$repsvc"; then
        return 0                        # replika container'ı ayakta
    fi
    [ -f "$STATE_JSON" ] || return 2    # profil defteri yok → bilmiyoruz
    pr="$(PYTHONIOENCODING=utf-8 python3 -c '
import json, sys
try:
    st = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("HATA"); raise SystemExit(0)
print("VAR" if sys.argv[2] in (st.get("profiles") or []) else "YOK")
' "$STATE_JSON" "$repprof" 2>/dev/null)"
    case "$pr" in
        VAR) return 0 ;;
        YOK) return 1 ;;
        *)   return 2 ;;
    esac
}

# targets.json'un imzası: değişiklik zamanı (ns) + içerik özeti.
# Dosya YERİNDE yazılıyor (write_prometheus_targets, inode korunuyor); içerik
# aynı kalsa bile "yeniden yazıldı mı" sorusunun cevabı mtime'dadır. Kapat/aç
# testinde ölçmek istediğimiz tam olarak bu.
tfile_sig() {                           # → "mtime_ns<TAB>sha256" · rc 0/3
    local out rc
    out="$(PYTHONIOENCODING=utf-8 python3 -c '
import hashlib, os, sys
try:
    p = sys.argv[1]
    d = open(p, "rb").read()
    print("%d\t%s" % (os.stat(p).st_mtime_ns, hashlib.sha256(d).hexdigest()))
except Exception as e:
    print("OLCULEMEDI\t%r" % (e,))
' "$TARGETS_JSON" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        hata_yaz "python3 çalışmadı (çıkış $rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
        return 3
    fi
    case "$out" in
        OLCULEMEDI*) hata_yaz "$(printf '%s' "$out" | cut -f2)"; return 3 ;;
    esac
    printf '%s' "$out"; return 0
}
tfile_has_engine() {                    # $1 motor → 0 var · 1 yok · 3 ölçemedik
    local out
    out="$(PYTHONIOENCODING=utf-8 python3 -c '
import json, sys
try:
    items = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("HATA\t%r" % (e,)); raise SystemExit(0)
if not isinstance(items, list):
    print("HATA\tdosya bir liste değil"); raise SystemExit(0)
print("VAR" if any((i.get("labels") or {}).get("engine") == sys.argv[2] for i in items) else "YOK")
' "$TARGETS_JSON" "$1" 2>&1)" || { hata_yaz "python3 çalışmadı: $out"; return 3; }
    case "$out" in
        VAR*) return 0 ;;
        YOK*) return 1 ;;
        *)    hata_yaz "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"; return 3 ;;
    esac
}

# =============================================================================
# 1) İZLEME AÇIK MI + ÖLÇÜM ARACI ÇALIŞIYOR MU
# =============================================================================
heading "1) İzleme açık mı? (prometheus + grafana + node-exporter)"

# Önce ÖLÇÜM ARACI. Sırası tesadüf değil: docker cevap vermiyorsa aşağıdaki
# her "container yok" satırı ürün hakkında değil, ölçüm hakkında konuşur.
if docker_ps_refresh; then
    t_ok "docker cevap veriyor (docker ps çalışan container listesini verdi)"
else
    t_unknown "docker cevap veriyor (docker ps çalışan container listesini verdi)" \
              "$(hata_oku) — bu betiğin BÜTÜN ölçümleri docker'a bağlı; hiçbir şey ölçülemez"
    e2e_finish; exit $?
fi

if container_in_cache "$CTRL_C"; then
    t_ok "controller container'ı ayakta (ağ içi sondaların çalıştığı yer)"
else
    t_fail "controller container'ı ayakta (ağ içi sondaların çalıştığı yer)" \
           "docker ps listesinde yok — Prometheus/Grafana ağ içi olduğundan hiçbir sorgu atılamaz. Önce: ./install.sh"
    e2e_finish; exit $?
fi

if tool_alive; then
    t_ok "ağ içi ölçüm aracı çalışıyor (controller içinde python)"
else
    t_unknown "ağ içi ölçüm aracı çalışıyor (controller içinde python)" \
              "$(hata_oku) — bundan sonraki her ölçüm bu araca bağlı; 'cevap gelmedi' satırları ürün hakkında konuşamazdı"
    e2e_finish; exit $?
fi

engine_state monitoring; MON_STATE=$?
if [ "$MON_STATE" = 0 ]; then
    log "izleme zaten açık"
elif [ "$MON_STATE" = 2 ]; then
    t_unknown "izleme profilinin durumu okundu" \
              "motorun ana servisi katalogdan/docker'dan çözülemedi — açık mı kapalı mı bilinmiyor"
else
    log "izleme kapalı — ürünün kendi arayüzüyle açılıyor: ./stack.sh enable monitoring"
    run_t 600 "$STACK_ROOT/stack.sh" enable monitoring > "$TMPD/enable.log" 2>&1; erc=$?
    if [ "$erc" -eq 0 ]; then
        WE_ENABLED_MONITORING=1
        t_ok "izleme profili './stack.sh enable monitoring' ile açıldı"
    elif [ "$erc" -eq 124 ]; then
        t_unknown "izleme profili './stack.sh enable monitoring' ile açıldı" \
                  "600 sn içinde bitmedi (stack.sh watch_job'un kendi zaman aşımı yok) — açıldı mı bilinmiyor: $(tail -3 "$TMPD/enable.log" 2>/dev/null | tr '\n' ' ')"
    else
        t_fail "izleme profili './stack.sh enable monitoring' ile açıldı" \
               "çıkış $erc: $(tail -3 "$TMPD/enable.log" 2>/dev/null | tr '\n' ' ')"
    fi
    docker_ps_refresh || warn "docker listesi tazelenemedi: $(hata_oku)"
fi

PROM_RUNNING=0
for svc in prometheus grafana node-exporter; do
    container_state "$svc"; crc=$?
    case "$crc" in
        0) t_ok "$svc container'ı ayakta"
           [ "$svc" = prometheus ] && PROM_RUNNING=1 ;;
        1) t_fail "$svc container'ı ayakta" "docker ps listesinde yok" ;;
        *) t_unknown "$svc container'ı ayakta" "docker'a sorulamadı: $(hata_oku)" ;;
    esac
done

# Container'ın ayakta olması yetmez: Prometheus bozuk bir kural dosyasıyla da
# ayakta kalabilir, Grafana da kendi veritabanına bağlanamadan açılabilir.
if [ "$PROM_RUNNING" = 1 ]; then
    if wait_for "prometheus /-/healthy cevap versin" 120 http_ok "$PROM_URL/-/healthy"; then
        t_ok "prometheus /-/healthy sağlıklı cevap veriyor"
    elif kod="$(http_probe "$PROM_URL/-/healthy")"; then
        t_fail "prometheus /-/healthy sağlıklı cevap veriyor" \
               "120 sn boyunca 200 gelmedi (son HTTP kodu: $kod · $(hata_oku))"
    else
        t_unknown "prometheus /-/healthy sağlıklı cevap veriyor" "$(hata_oku)"
    fi
else
    t_skip "prometheus /-/healthy sağlıklı cevap veriyor" "prometheus container'ı kapalı"
fi

container_state grafana; GRAF_STATE=$?
if [ "$GRAF_STATE" = 0 ]; then
    if wait_for "grafana /api/health cevap versin" 180 http_ok "$GRAF_URL/api/health"; then
        t_ok "grafana /api/health cevap veriyor"
    elif kod="$(http_probe "$GRAF_URL/api/health")"; then
        t_fail "grafana /api/health cevap veriyor" \
               "180 sn boyunca 200 gelmedi (son HTTP kodu: $kod · $(hata_oku))"
    else
        t_unknown "grafana /api/health cevap veriyor" "$(hata_oku)"
    fi
elif [ "$GRAF_STATE" = 2 ]; then
    t_unknown "grafana /api/health cevap veriyor" "docker'a sorulamadı: $(hata_oku)"
else
    t_skip "grafana /api/health cevap veriyor" "grafana container'ı kapalı"
fi

if [ "$PROM_RUNNING" != 1 ]; then
    err "prometheus olmadan izleme zincirinin geri kalanı sınanamaz."
    e2e_finish; exit $?
fi

# --------------------------------------------------------------------------
# 1b) YAPILANDIRMA VE UYARI KURALLARI
# --------------------------------------------------------------------------
# /-/healthy SÜREÇ YAŞADIĞI SÜRECE 200 döner: yapılandırma ya da kural sağlığı
# hakkında hiçbir şey söylemez. Zincirin son halkası (seri → uyarı kuralı →
# alarm) burada sınanıyor. Kural klasörü bağlanmamışsa ya da grup
# yüklenmemişse ürün sıfır alarm üretir; eski sürümde betik yine baştan sona
# yeşil bitiyordu — yani tam da avlamayı iddia ettiği sessiz arıza türü.
heading "1b) Prometheus yapılandırmayı ve uyarı kurallarını GERÇEKTEN yükledi mi?"

RULE_NAMES=""
RULES_ERR=""
if [ -d "$RULES_DIR" ]; then
    RULE_OUT="$(PYTHONIOENCODING=utf-8 python3 -c '
import glob, os, re, sys
try:
    ad = []
    for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.y*ml"))):
        metin = open(f, encoding="utf-8").read()
        ad += re.findall(r"^\s*-\s*alert:\s*[\"\x27]?([A-Za-z0-9_]+)", metin, re.M)
    print("AD\t" + " ".join(ad))
except Exception as e:
    print("HATA\t%r" % (e,))
' "$RULES_DIR" 2>&1)"
    case "$RULE_OUT" in
        AD*)  RULE_NAMES="$(printf '%s' "$RULE_OUT" | cut -f2)" ;;
        *)    RULES_ERR="$(printf '%s' "$RULE_OUT" | tr '\n' ' ' | cut -c1-200)" ;;
    esac
else
    RULES_ERR="klasör yok: $RULES_DIR"
fi

if [ -n "$RULES_ERR" ]; then
    t_unknown "config/prometheus/rules içindeki uyarı kuralları okundu" "$RULES_ERR"
fi

py_in_net -e "E2E_RULES=$RULE_NAMES" <<'PY' > "$TMPD/rules.out" 2>"$TMPD/rules.err"
import os, json, urllib.request, urllib.parse

PROM = "http://prometheus:9090"


def line(st, ad, ay=""):
    print("%s\t%s\t%s" % (st, " ".join(str(ad).split()), " ".join(str(ay).split())))


def get(path):
    try:
        r = urllib.request.urlopen(PROM + path, timeout=25)
        return r.read().decode("utf-8", "replace"), r.getcode(), ""
    except Exception as e:
        return None, 0, repr(e)


def q(expr):
    try:
        body = urllib.parse.urlencode({"query": expr}).encode()
        req = urllib.request.Request(PROM + "/api/v1/query", data=body)
        j = json.loads(urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace"))
    except Exception as e:
        return None, repr(e)
    if j.get("status") != "success":
        return None, j.get("error") or "bilinmeyen sorgu hatası"
    return (j.get("data") or {}).get("result") or [], ""


# --- /-/ready: "süreç yaşıyor" değil, "istek kabul ediyor" -------------------
ad = "prometheus /-/ready sorgu kabul ettiğini bildiriyor"
g, kod, hata = get("/-/ready")
if g is None:
    line("UNKNOWN", ad, "uca ulaşılamadı: %s" % hata)
elif kod == 200:
    line("PASS", ad)
else:
    line("FAIL", ad, "HTTP %d — süreç ayakta ama sorgu kabul etmiyor" % kod)

# --- yapılandırma hatasız yüklendi mi ---------------------------------------
ad = "prometheus yapılandırmayı HATASIZ yükledi (config_last_reload_successful=1)"
res, hata = q("prometheus_config_last_reload_successful")
if res is None:
    line("UNKNOWN", ad, "sorgu yapılamadı: %s" % hata)
elif not res:
    line("FAIL", ad, "bu metrik hiç yok — prometheus kendi hedefini (job=prometheus) "
                     "toplamıyor demektir; yapılandırma sağlığı ÖLÇÜLEMEZ hâlde")
else:
    try:
        v = float(res[0]["value"][1])
    except Exception as e:
        v = -1.0
    if v == 1.0:
        line("PASS", ad)
    else:
        line("FAIL", ad, "değer %s — son yeniden yükleme BAŞARISIZ; prometheus eski "
                         "yapılandırmayla çalışıyor, dosyada yaptığınız değişiklik geçerli değil" % v)

# --- uyarı kuralları -------------------------------------------------------
beklenen = [a for a in (os.environ.get("E2E_RULES") or "").split() if a]
g, kod, hata = get("/api/v1/rules")
if g is None:
    line("UNKNOWN", "prometheus uyarı kurallarını yükledi (/api/v1/rules)",
         "uca ulaşılamadı: %s" % hata)
    raise SystemExit(0)
try:
    gruplar = (json.loads(g).get("data") or {}).get("groups") or []
except Exception as e:
    line("UNKNOWN", "prometheus uyarı kurallarını yükledi (/api/v1/rules)",
         "cevap ayrıştırılamadı: %r" % (e,))
    raise SystemExit(0)

kurallar = [r for gr in gruplar for r in (gr.get("rules") or [])]
ad = "prometheus en az bir uyarı kuralı grubu yükledi"
if not beklenen:
    line("SKIP", ad, "config/prometheus/rules altında tanımlı uyarı yok (ya da okunamadı); "
                     "yüklenmesi gereken bir grup bilinmiyor")
elif gruplar:
    line("PASS", ad + " (%d grup, %d kural)" % (len(gruplar), len(kurallar)))
else:
    line("FAIL", ad, "kural dosyasında %d uyarı tanımlı ama Prometheus HİÇ grup yüklememiş "
                     "(rule_files yolu yanlış ya da klasör bağlanmamış: docker-compose.yml "
                     "/etc/prometheus/rules) — bu kurulumda hiçbir alarm üretilmez" % len(beklenen))

ad = "yüklenen her uyarı kuralı hatasız derlendi (lastError boş, health=ok)"
if not gruplar:
    line("SKIP", ad, "yüklenmiş kural yok — sınanacak bir şey de yok")
else:
    bozuk = ["%s: %s" % (r.get("name", "?"), (r.get("lastError") or "health=%s" % r.get("health")))
             for r in kurallar
             if r.get("lastError") or (r.get("health") not in ("ok", None, ""))]
    if bozuk:
        line("FAIL", ad, "bozuk kural(lar): " + "; ".join(bozuk[:6]))
    else:
        line("PASS", ad + " (%d kural)" % len(kurallar))

ad = "kural dosyasındaki her uyarı Prometheus'a yüklenmiş"
if not beklenen:
    line("SKIP", ad, "kural dosyasından uyarı adı çıkarılamadı")
else:
    yuklu = {r.get("name") for r in kurallar}
    eksik = [a for a in beklenen if a not in yuklu]
    if eksik:
        line("FAIL", ad, "dosyada tanımlı olduğu hâlde Prometheus'ta OLMAYAN uyarılar: %s "
                         "(bu uyarılar hiçbir zaman ateşlenmez)" % ", ".join(eksik))
    else:
        line("PASS", ad + " (%d uyarı)" % len(beklenen))
PY
rules_rc=$?
emit_or_unknown "$TMPD/rules.out" "$TMPD/rules.err" "prometheus yapılandırma/kural sondası çalıştı"
sonda_rc "$rules_rc" "kural sondası eksiksiz tamamlandı" "MON_HTTP_TIMEOUT ile süreyi artırın"

# --------------------------------------------------------------------------
# Açık motorları tespit et — bundan sonraki her adım bu listeye göre karar verir
# --------------------------------------------------------------------------
# Bu liste yanlışsa bütün paket sessizce yalancı olur: motorlar "kapalı"
# sanılırsa pano sorguları ATLANDI'ya düşer ve koşu yeşil biter. Bu yüzden
# tek bir motorun durumu bile ölçülemediyse burada duruyoruz.
docker_ps_refresh || { t_unknown "açık motor listesi çıkarıldı" "$(hata_oku)"; e2e_finish; exit $?; }
ACTIVE_ENGINES=""
ENGINE_STATE_ERR=""
while IFS=$'\t' read -r eid ename eprim eexsvc eexport escrape ekind erepprof erepsvc; do
    [ -n "${eid:-}" ] || continue
    engine_state "$eid"; esrc=$?
    case "$esrc" in
        0) ACTIVE_ENGINES="$ACTIVE_ENGINES $eid" ;;
        1) : ;;
        *) ENGINE_STATE_ERR="$ENGINE_STATE_ERR $eid" ;;
    esac
done < "$TMPD/engines.txt"
ACTIVE_ENGINES="${ACTIVE_ENGINES# }"
if [ -n "$ENGINE_STATE_ERR" ]; then
    t_unknown "her motorun açık/kapalı durumu ölçüldü" \
              "durumu ÇÖZÜLEMEYEN motorlar:$ENGINE_STATE_ERR — bunların panoları 'kapalı motor' sayılıp sessizce atlanırdı"
fi
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
    run_t 30 docker ps --filter "label=com.docker.compose.project=$PROJ" \
              --format '{{.Label "com.docker.compose.service"}}' \
              > "$TMPD/running.txt" 2>"$TMPD/running.err"
    ps_rc=$?
    if [ "$ps_rc" -ne 0 ]; then
        # docker cevap vermediğinde "ayakta olan exporter yok" sanılır ve
        # karşılaştırma SIFIR öğeyle "geçti" derdi.
        t_unknown "prometheus hedef dosyası, ayakta olan exporter'ların listesiyle birebir aynı" \
                  "proje container listesi alınamadı (docker ps çıkış $ps_rc): $(head -c 200 "$TMPD/running.err" | tr '\n' ' ')"
    elif [ ! -s "$TMPD/running.txt" ]; then
        t_unknown "prometheus hedef dosyası, ayakta olan exporter'ların listesiyle birebir aynı" \
                  "docker, '$PROJ' projesinde HİÇ container görmüyor — oysa controller ayakta. STACK_PROJECT yanlış olabilir; bu hâlde karşılaştırma sıfır öğe üzerinden yapılır ve hiçbir şey ölçülmezdi"
    else
        PYTHONIOENCODING=utf-8 python3 - "$TARGETS_JSON" "$TMPD/engines.txt" "$TMPD/running.txt" \
            > "$TMPD/tfile.out" 2>"$TMPD/tfile.err" <<'PY'
import json, sys
try:
    items = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("FAIL\tprometheus hedef dosyası (state/prometheus/targets.json) geçerli JSON\t%s" % e)
    raise SystemExit(0)
if not isinstance(items, list):
    print("FAIL\tprometheus hedef dosyası (state/prometheus/targets.json) geçerli JSON\t"
          "beklenen liste, gelen %s" % type(items).__name__)
    raise SystemExit(0)
engines = [l.rstrip("\n").split("\t") for l in open(sys.argv[2], encoding="utf-8") if l.strip()]
running = {l.strip() for l in open(sys.argv[3], encoding="utf-8") if l.strip()}
listed = {}
for it in items:
    eid = (it.get("labels") or {}).get("engine") or "?"
    for t in it.get("targets") or []:
        listed[eid] = t
beklenen = {e[0]: "%s:%s" % (e[3], e[4]) for e in engines if e[3] and e[4] and e[3] in running}
ad = ("prometheus hedef dosyası, ayakta olan exporter'ların listesiyle birebir aynı")
# SIFIR KARŞILAŞTIRMA = ÖLÇÜM DEĞİLDİR. İki taraf da boşken eski sürüm
# "PASS (0 hedef)" basıyordu; hiçbir şey karşılaştırılmadan yeşil bir satır.
if not listed and not beklenen:
    print("UNKNOWN\t%s\tkarşılaştırılacak hiç hedef yok: dosya boş VE ayakta exporter yok. "
          "Bu bir doğrulama değil, ölçüm yokluğudur (exporter'ı olan bir motor açın)." % ad)
    raise SystemExit(0)
eksik = sorted(set(beklenen) - set(listed))
fazla = sorted(set(listed) - set(beklenen))
yanlis = sorted(k for k in (set(listed) & set(beklenen)) if listed[k] != beklenen[k])
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
    print("PASS\t%s (%d hedef, %d ayakta exporter)\t" % (ad, len(listed), len(beklenen)))
PY
        tfile_rc=$?
        emit_or_unknown "$TMPD/tfile.out" "$TMPD/tfile.err" "prometheus hedef dosyası okunup karşılaştırıldı"
        sonda_rc "$tfile_rc" "hedef dosyası karşılaştırması tamamlandı" "python3 çalışmasına bakın"
    fi
else
    t_fail "prometheus hedef dosyası (state/prometheus/targets.json) var" \
           "dosya yok — controller hedef listesini hiç yazmamış; hiçbir veritabanı toplanmıyor demektir"
fi

# Sonra Prometheus'un KENDİ gördüğü hedefler. Dosya doğru olup Prometheus onu
# okumamış da olabilir: file_sd yolu yanlış bağlanmışsa dosya kusursuzdur ve
# hedef listesi yine boştur.
EXPORTERS_JSON="$(PYTHONIOENCODING=utf-8 python3 - "$TMPD/engines.txt" "$ACTIVE_ENGINES" 2>"$TMPD/exp.err" <<'PY'
import json, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
active = set(sys.argv[2].split())
print(json.dumps({r[0]: {"ad": r[1], "svc": r[3], "port": r[4], "kind": r[6]}
                  for r in rows if r[0] in active}, ensure_ascii=False))
PY
)"
if [ -z "$EXPORTERS_JSON" ]; then
    # Liste boş kalırsa aşağıdaki sonda "açık motorun exporter'ı toplanıyor mu"
    # kontrolünü HİÇ yapmaz ve bunu kimse fark etmez.
    t_unknown "açık motorların exporter listesi çıkarıldı" \
              "katalogdan liste üretilemedi: $(head -c 200 "$TMPD/exp.err" 2>/dev/null | tr '\n' ' ') — motor başına exporter kapsaması SINANMADI"
    EXPORTERS_JSON='{}'
fi

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
    # ÖLÇEMEDİK: Prometheus'a ulaşılamadı. "Hedef yok" DEĞİL.
    line("UNKNOWN", "prometheus /api/v1/targets aktif hedef listesini veriyor", repr(e))
    raise SystemExit(0)

line("PASS", "prometheus /api/v1/targets aktif hedef listesini veriyor (%d hedef)" % len(tg))

for t in tg:
    lb = t.get("labels") or {}
    eng = lb.get("engine_name") or lb.get("engine") or ""
    ad = "hedef up: job=%s instance=%s%s" % (lb.get("job", "?"), lb.get("instance", "?"),
                                             (" (%s)" % eng) if eng else "")
    if t.get("health") == "up":
        line("PASS", ad)
    elif t.get("health") == "unknown":
        # Prometheus henüz ilk toplamayı yapmamış: ölçemedik, "up" da diyemeyiz.
        line("UNKNOWN", ad, "health=unknown — hedef listeye yeni girmiş, ilk toplama henüz yapılmamış")
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
try:
    exporters = json.loads(os.environ.get("E2E_EXPORTERS") or "{}")
except Exception as e:
    exporters = {}
    line("UNKNOWN", "açık motorların exporter hedefleri sınandı",
         "exporter listesi çözülemedi: %r" % (e,))
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
emit_or_unknown "$TMPD/targets.out" "$TMPD/targets.err" "prometheus /api/v1/targets aktif hedef listesini veriyor"
sonda_rc "$probe_rc" "hedef sondası eksiksiz tamamlandı" "yukarıdaki hedef listesi EKSİK olabilir"
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
#
# Panellerin İÇİNE de iniyoruz: Grafana'da "row" tipi paneller alt panelleri
# kendi içinde taşır. Eski ayrıştırıcı yalnız üst seviyeye baktığı için bir
# satırın altına konan paneller sessizce hiç sınanmıyordu ve toplam yine
# "geçti" diyordu.
PYTHONIOENCODING=utf-8 python3 - "$DASH_DIR" "$TMPD/engines.txt" \
    > "$TMPD/dash.json" 2>"$TMPD/dash.err" <<'PY'
import json, glob, os, sys
ids = {l.split("\t")[0] for l in open(sys.argv[2], encoding="utf-8") if l.strip()}
out = []


def topla(paneller, biriktir, yol=""):
    """row panellerinin İÇİNDEKİ panelleri de toplar (iç içe olabilir)."""
    for p in paneller or []:
        baslik = (p.get("title") or "?")[:70]
        tam = ("%s / %s" % (yol, baslik)) if yol else baslik
        tg = [{"ref": t.get("refId") or "?", "expr": t.get("expr") or ""}
              for t in (p.get("targets") or []) if t.get("expr")]
        if tg:
            biriktir.append({"title": tam, "targets": tg})
        if p.get("panels"):
            topla(p["panels"], biriktir, tam)


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
    topla(d.get("panels"), panels)
    out.append({"file": base, "uid": d.get("uid") or "", "hata": "",
                "title": (d.get("title") or base)[:70], "engine": eng, "panels": panels})
print(json.dumps(out, ensure_ascii=False))
PY
dash_rc=$?
DASH_JSON="$(cat "$TMPD/dash.json" 2>/dev/null)"
DASH_OK=1
if [ "$dash_rc" -ne 0 ] || [ -z "$DASH_JSON" ]; then
    # Pano dosyaları okunamazsa 3. ve 4. bölümün TAMAMI ölçülemez. Eskiden
    # burada die vardı: özet hiç basılmıyor, koşu "başarısız" olduğu için de
    # hangi kontrollerin çalıştığı görünmüyordu.
    DASH_OK=0
    DASH_JSON='[]'
    t_unknown "pano dosyaları (config/grafana/dashboards) ayrıştırıldı" \
              "çıkış $dash_rc: $(head -c 300 "$TMPD/dash.err" 2>/dev/null | tr '\n' ' ') — pano ve sorgu kontrollerinin tamamı ölçülemedi"
fi
DASH_FILE_N="$(PYTHONIOENCODING=utf-8 python3 -c '
import glob, os, sys
print(len(glob.glob(os.path.join(sys.argv[1], "*.json"))))' "$DASH_DIR" 2>/dev/null)"
case "${DASH_FILE_N:-}" in
    ''|*[!0-9]*) DASH_FILE_N=-1 ;;
esac
[ "$DASH_FILE_N" -ge 0 ] && log "$DASH_DIR içinde $DASH_FILE_N pano dosyası var"

container_state grafana; GRAF_STATE=$?
if [ "$GRAF_STATE" = 0 ]; then
    # Grafana'da anonim erişim Viewer rolüyle açık (bkz. docker-compose.yml).
    # Yine de yönetici bilgisini hazırda tutuyoruz: kurulum anonim erişimi
    # kapatmışsa test "yetkisiz" yüzünden YANLIŞLIKLA kalmamalı.
    GF_USER="${GRAFANA_USER:-admin}"
    GF_PASS="${GRAFANA_PASSWORD:-${DB_PASSWORD:-}}"
    py_in_net_batch -e "E2E_DASH=$DASH_JSON" -e "E2E_N=$DASH_FILE_N" \
              -e "E2E_DASH_OK=$DASH_OK" \
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
    """Önce anonim, olmazsa yönetici kimliğiyle dener.

    (gövde, hata, tur) döner. `tur`: "" başarı · "http" sunucu cevap verdi ama
    reddetti (ÖLÇTÜK) · "ag" hiç bağlanamadık (ÖLÇEMEDİK). İkisini aynı sayan
    eski sürüm, Grafana'ya hiç ulaşılamadığında da KALDI basıyordu: bakan kişi
    ürünü suçlayıp ölçüm arızasını gözden kaçırırdı.
    """
    son, tur = "", "ag"
    for hdr in ({}, {"Authorization": AUTH}):
        try:
            req = urllib.request.Request(BASE + path, headers=hdr)
            return urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace"), "", ""
        except urllib.error.HTTPError as e:
            son, tur = "HTTP %d" % e.code, "http"
        except Exception as e:
            son = repr(e)
            if tur != "http":
                tur = "ag"
    return None, son, tur


body, hata, tur = get("/api/health")
if body is None:
    line("UNKNOWN" if tur == "ag" else "FAIL", "grafana API'si (/api/health) cevap veriyor", hata)
    raise SystemExit(0)
try:
    h = json.loads(body)
except Exception as e:
    line("FAIL", "grafana API'si sağlıklı (database=ok)",
         "cevap JSON değil: %r · %s" % (e, body[:120]))
    h = None
if h is not None:
    if h.get("database") == "ok":
        line("PASS", "grafana API'si sağlıklı (sürüm %s, database=ok)" % h.get("version", "?"))
    else:
        line("FAIL", "grafana API'si sağlıklı (database=ok)", body[:200])

dash = json.loads(os.environ["E2E_DASH"])
dash_ok = os.environ.get("E2E_DASH_OK") == "1"
try:
    beklenen = int(os.environ["E2E_N"])
except Exception:
    beklenen = -1

body, hata, tur = get("/api/search?type=dash-db&tag=databases-stack&limit=500")
yuklu = None
if body is None:
    line("UNKNOWN" if tur == "ag" else "FAIL",
         "grafana pano listesi (/api/search) okunabiliyor", hata)
else:
    try:
        yuklu = json.loads(body)
    except Exception as e:
        line("FAIL", "grafana pano listesi (/api/search) okunabiliyor",
             "cevap JSON değil: %r · %s" % (e, body[:120]))

ad = "grafana'ya yüklü pano sayısı, config/grafana/dashboards altındaki dosya sayısıyla aynı"
if yuklu is None:
    pass                                    # yukarıda zaten satır basıldı
elif beklenen < 0:
    line("UNKNOWN", ad, "klasördeki dosya sayısı okunamadı — karşılaştırma yapılamaz")
else:
    if len(yuklu) == beklenen:
        line("PASS", ad + " (%d)" % beklenen)
    else:
        line("FAIL", ad,
             "Grafana %d pano gösteriyor, klasörde %d dosya var. Grafana'dakiler: %s"
             % (len(yuklu), beklenen,
                ", ".join(sorted(d.get("title", "?") for d in yuklu)) or "(hiç)"))

# Sayının tutması doğru panoların yüklendiğini KANITLAMAZ: bir dosya düşüp
# yerine başkası gelmiş olabilir. Her dosyanın uid'sini tek tek arıyoruz.
if not dash_ok:
    line("UNKNOWN", "her pano dosyası Grafana'da uid'siyle bulundu",
         "pano dosyaları okunamadığı için aranacak uid listesi YOK")
elif not dash:
    line("UNKNOWN", "her pano dosyası Grafana'da uid'siyle bulundu",
         "klasörde hiç pano dosyası yok — sınanacak bir şey bulunamadı")
for d in dash:
    if d.get("hata"):
        line("FAIL", "%s.json panosu geçerli bir JSON" % d["file"], d["hata"])
        continue
    if not d["uid"]:
        line("FAIL", "%s.json panosunun uid'i var" % d["file"],
             "uid alanı boş — Grafana her sağlamada yeni uid üretir ve panoya verilmiş "
             "bütün linkler kırılır")
        continue
    b, hata, tur = get("/api/dashboards/uid/" + d["uid"])
    ad = "%s.json panosu Grafana'da yüklü (uid=%s)" % (d["file"], d["uid"])
    if b is None and tur == "ag":
        line("UNKNOWN", ad, "grafana'ya ulaşılamadı: %s" % hata)
    elif b is None:
        line("FAIL", ad, "%s — dosya klasörde duruyor ama Grafana onu almamış" % hata)
    else:
        line("PASS", ad)

# Panolar veri kaynağını uid ile arar. Veri kaynağı yoksa ya da uid değişmişse
# panolar yine açılır, panellerde "Datasource not found" yazar — grafik yoktur.
b, hata, tur = get("/api/datasources/proxy/uid/dbstack-prometheus/api/v1/query?query=up")
ad = "grafana, dbstack-prometheus veri kaynağı üzerinden Prometheus'a sorgu geçirebiliyor"
if b is None and tur == "ag":
    line("UNKNOWN", ad, "grafana'ya ulaşılamadı: %s" % hata)
elif b is None:
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
    emit_or_unknown "$TMPD/grafana.out" "$TMPD/grafana.err" "grafana API'si üzerinden pano kontrolleri çalıştı"
    sonda_rc "$probe_rc" "grafana sondası eksiksiz tamamlandı" "pano listesi EKSİK olabilir"
    if [ -s "$TMPD/grafana.err" ]; then
        warn "grafana sondası uyarı verdi: $(head -c 300 "$TMPD/grafana.err" | tr '\n' ' ')"
    fi
elif [ "$GRAF_STATE" = 2 ]; then
    t_unknown "panolar Grafana'ya yüklenmiş" "grafana container'ının durumu docker'dan okunamadı: $(hata_oku)"
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
if [ "$DASH_OK" != 1 ]; then
    t_unknown "pano sorguları Prometheus'a soruldu" \
              "pano dosyaları ayrıştırılamadığı için sorulacak sorgu listesi YOK (yukarıdaki ayrıştırma hatasına bakın)"
elif [ "$MON_WARMUP_S" -gt 0 ]; then
    WARM_DEADLINE=$(( $(date +%s) + MON_WARMUP_S + 120 ))
    while :; do
        MIN_S=9999; WORST=""; OLCUM_DUSTU=0
        for weid in $ACTIVE_ENGINES genel; do
            if [ "$weid" = "genel" ]; then
                WSEL="up{job=\"host\"}"
            else
                [ -f "$DASH_DIR/$weid.json" ] || continue
                WSEL="up{job=\"databases\",engine=\"$weid\"}"
            fi
            # Ölçüm düşerse BEKLEMEK anlamsız: eskiden prom_scalar "0" basıyor,
            # döngü pencereyi hiç dolmamış sanıp tam süre bekliyordu.
            if ! wn="$(prom_scalar "max(count_over_time(${WSEL}[${MON_WARMUP_S}s]))")"; then
                OLCUM_DUSTU=1; break
            fi
            wn="${wn%%.*}"; [ -n "$wn" ] || wn=0
            if [ "$wn" -lt "$MIN_S" ] 2>/dev/null; then MIN_S="$wn"; WORST="$weid"; fi
        done
        if [ "$OLCUM_DUSTU" = 1 ]; then
            warn "ölçüm penceresi sayılamadı (Prometheus'a sorulamıyor: $(hata_oku)) — beklemek anlamsız, sondaya geçiliyor"
            break
        fi
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

if [ "$DASH_OK" = 1 ]; then
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
    """(sonuç, hata, tur). tur: "" başarı · "ag" ULAŞAMADIK (ölçemedik) ·
    "sorgu" Prometheus cevap verdi ama ifadeyi reddetti (gerçek arıza:
    panodaki PromQL bozuk). İkisini aynı sayan eski sürüm, Prometheus'a
    ulaşılamadığında 164 satır KALDI basıyordu — hepsi ürünü suçluyordu."""
    try:
        body = urllib.parse.urlencode({"query": expr}).encode()
        req = urllib.request.Request(PROM + "/api/v1/query", data=body)
        j = json.loads(urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace"))
    except Exception as e:
        return None, repr(e), "ag"
    if j.get("status") != "success":
        return None, j.get("error") or "bilinmeyen sorgu hatası", "sorgu"
    return (j.get("data") or {}).get("result") or [], "", ""


# Prometheus'un TANIDIĞI bütün metrik adları. Boş dönen bir sorguda asıl soru
# şu: seri hiç üretilmemiş mi (exporter ile Prometheus arası kopuk — gerçek
# arıza), yoksa seri var da filtre mi hiçbir şey seçmemiş (ör. hiç consumer
# group yok)? Bu ayrım yapılmadan verilen rapor kullanılmaz hâle gelir:
# kullanıcı listeyi bir kez "zaten hep kırmızı" diye kapatır.
bilinen = set()
bilinen_hata = ""
try:
    bilinen = set(json.loads(urllib.request.urlopen(
        PROM + "/api/v1/label/__name__/values", timeout=30).read().decode())["data"])
except Exception as e:
    bilinen_hata = repr(e)
if bilinen_hata:
    line("UNKNOWN", "boş sorguların sebebi ayırt edilebiliyor (metrik adı listesi)",
         "Prometheus'tan metrik adı listesi alınamadı (%s) — aşağıdaki boş sonuçlarda "
         "'metrik hiç yok' ile 'filtre seçmedi' AYIRT EDİLEMEDİ" % bilinen_hata)

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
    if not d["panels"]:
        line("UNKNOWN", "%s panosunun sorguları sınandı" % etiket,
             "dosyada sorgusu (targets.expr) olan hiç panel bulunamadı — pano boş ya da "
             "ayrıştırıcı panelleri göremedi; hiçbir şey ölçülmedi")
        continue

    # Bu pano için ölçüm penceresi ne kadar dolu?
    sec = 'up{job="host"}' if not eng else 'up{job="databases",engine="%s"}' % eng
    res, s_hata, s_tur = query("max(count_over_time(%s[%ds]))" % (sec, warm))
    if res is None:
        # Örnek sayısı ÖLÇÜLEMEDİ. Eskiden 0 sayılıyordu ve panonun bütün
        # rate() sorguları "pencere dolmadı" diye ATLANIYORDU: ölçüm arızası
        # sessizce meşru bir atlamaya dönüşüyordu.
        ornek = None
    else:
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
            if RATE_FN.search(expr):
                if ornek is None:
                    line("UNKNOWN", ad,
                         "rate() penceresinde kaç örnek olduğu ÖLÇÜLEMEDİ (%s); sorgunun "
                         "boş dönmesi arıza mı yoksa pencere mi dolmamış ayırt edilemez "
                         "(sorgu: %s)" % (s_hata, kisa))
                    continue
                if ornek < 2:
                    line("SKIP", ad,
                         "izleme son %d sn içinde yalnız %d örnek biriktirdi; rate() en az 2 "
                         "örnek ister. Daha uzun beklemek için: MON_WARMUP_S=600 (sorgu: %s)"
                         % (warm, ornek, kisa))
                    continue
            res, hata, tur = query(expr)
            if res is None and tur == "ag":
                line("UNKNOWN", ad, "Prometheus'a ULAŞILAMADI: %s (sorgu: %s)" % (hata, kisa))
                continue
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
emit_or_unknown "$TMPD/queries.out" "$TMPD/queries.err" "pano sorguları Prometheus'a soruldu"
sonda_rc "$probe_rc" "pano sorgu sondası eksiksiz tamamlandı" \
         "sınanmamış sorgular kalmış olabilir; MON_BATCH_TIMEOUT ile süreyi artırın"
if [ -s "$TMPD/queries.err" ]; then
    warn "pano sorgu sondası uyarı verdi: $(head -c 300 "$TMPD/queries.err" | tr '\n' ' ')"
fi
fi

# =============================================================================
# 5) MOTOR KAPAT/AÇ → HEDEF LİSTESİ KENDİNİ GÜNCELLİYOR MU?
# =============================================================================
heading "5) Motor kapatılınca hedeften düşüyor, açılınca hedef listesi tazeleniyor mu?"

# Bu, izlemenin "kendi kendini ayarlar" iddiasının tek gerçek kanıtı. Hedef
# listesini controller yazar ve YALNIZ aktivasyon/deaktivasyon anında yazar.
# Bu yol kırıldığında hiçbir şey bağırmaz; kanıt için gerçekten kapatıp açmak
# gerekir. Container'a bakmak bunu göstermez, çünkü container zaten doğru
# durumdadır — yanlış olan, onu takip etmeyen listedir.
#
# ÖNEMLİ AYRIM: "motor açılınca hedef up=1 oldu" tek başına AKTİVASYONUN
# LİSTEYİ TAZELEDİĞİNİ KANITLAMAZ. do_deactivate() hedef listesini hiç
# yazmadığı için kapalıyken bile kayıt dosyada durur; motor geri açıldığında
# ESKİ kayıt sayesinde toplanır ve up=1 olur. Yani eski test, ürünün
# tazelemediği bir yolu "geçti" sayıyordu. Artık dosyanın YENİDEN YAZILDIĞINI
# (mtime) ayrıca ölçüyoruz.
cycle_engine=""
cycle_elenen=""
if [ "$MON_NO_CYCLE" = "1" ]; then
    t_skip "motor kapatılınca hedef listesinden düşüyor / açılınca liste tazeleniyor" \
           "MON_NO_CYCLE=1 verildi — bu test bir veritabanını kısa süre kapatır"
elif [ -n "$MON_CYCLE_ENGINE" ]; then
    # Elle verilen motoru DOĞRULA. Yanlış yazılmış bir ad sessizce "test yok"a
    # dönüşmemeli; kullanıcı testi çalıştırdığını sanıp geçmiş sayardı.
    if ! awk -F'\t' -v k="$MON_CYCLE_ENGINE" '$1==k {f=1} END {exit !f}' "$TMPD/engines.txt"; then
        t_fail "MON_CYCLE_ENGINE ile verilen motor katalogda var" \
               "'$MON_CYCLE_ENGINE' catalog.json'da yok — geçerli kimlikler: $(cut -f1 "$TMPD/engines.txt" | tr '\n' ' ')"
    else
        engine_state "$MON_CYCLE_ENGINE"; msrc=$?
        replication_state "$MON_CYCLE_ENGINE"; mrrc=$?
        if [ "$msrc" = 2 ]; then
            t_unknown "$MON_CYCLE_ENGINE kapatılınca hedeften düşüyor / açılınca liste tazeleniyor" \
                      "motorun açık mı kapalı mı olduğu ölçülemedi — kapatma denenmedi"
        elif [ "$msrc" != 0 ]; then
            t_skip "$MON_CYCLE_ENGINE kapatılınca hedeften düşüyor / açılınca liste tazeleniyor" \
                   "MON_CYCLE_ENGINE=$MON_CYCLE_ENGINE seçildi ama o motor şu an kapalı"
        elif [ "$mrrc" = 0 ]; then
            t_skip "$MON_CYCLE_ENGINE kapatılınca hedeften düşüyor / açılınca liste tazeleniyor" \
                   "bu motorun REPLİKASYONU AÇIK. Kapat/aç döngüsü replikayı siler ve geri kurmaz (do_deactivate replika servisini de 'rm -f' eder ve profili state'ten çıkarır; do_activate normal yolda yalnız engine[services] açar) — yüksek erişilebilirliği bir teste kurban etmemek için dokunulmuyor. Replikasyonu olmayan bir motor seçin"
        elif [ "$mrrc" = 2 ]; then
            t_unknown "$MON_CYCLE_ENGINE kapatılınca hedeften düşüyor / açılınca liste tazeleniyor" \
                      "replikasyonun açık olup olmadığı okunamadı (state/state.json) — kapatmak replikayı GERİ DÖNÜLMEZ biçimde silebilirdi, denenmedi"
        else
            cycle_engine="$MON_CYCLE_ENGINE"
        fi
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
        if [ "$(primary_of "$cand")" != "$cand" ]; then
            cycle_elenen="$cycle_elenen $cand(devir geçirmiş)"; continue
        fi
        # Replikasyonu açık motora da DOKUNMA (yukarıdaki uzun gerekçe).
        replication_state "$cand"; rrc=$?
        if [ "$rrc" = 0 ]; then
            cycle_elenen="$cycle_elenen $cand(replikasyon açık)"; continue
        elif [ "$rrc" = 2 ]; then
            cycle_elenen="$cycle_elenen $cand(replikasyon durumu okunamadı)"; continue
        fi
        cycle_engine="$cand"; break
    done
    [ -n "$cycle_engine" ] || t_skip \
        "motor kapatılınca hedef listesinden düşüyor / açılınca liste tazeleniyor" \
        "uygun aday yok — exporter'ı olan, açık, devir geçirmemiş ve replikasyonu kapalı bir motor bulunamadı. Elenenler:${cycle_elenen:- (hiç aday yoktu)}. MON_CYCLE_ENGINE=<motor> ile seçebilirsiniz"
fi

if [ -n "$cycle_engine" ]; then
    if ! before="$(prom_target_count "$cycle_engine")"; then
        # Ölçemediğimiz bir başlangıç durumunun üstüne motor KAPATILMAZ:
        # kapanışın etkisini karşılaştıracak referansımız olmaz.
        t_unknown "$cycle_engine kapatılınca hedef listesinden düşüyor" \
                  "başlangıçtaki hedef sayısı Prometheus'tan okunamadı ($(hata_oku)) — motora dokunulmadı"
    elif [ "$before" -lt 1 ] 2>/dev/null; then
        t_skip "$cycle_engine kapatılınca hedef listesinden düşüyor" \
               "test başlamadan da hedef listesinde yoktu (sayı=$before) — kapanışın etkisi ölçülemez"
    else
        warn "$cycle_engine KISA SÜRE KAPATILIYOR (veri silinmez, yalnız container durur). Atlamak için: MON_NO_CYCLE=1"
        RESTORE_ENGINE="$cycle_engine"
        run_t 600 "$STACK_ROOT/stack.sh" disable "$cycle_engine" > "$TMPD/cycle.log" 2>&1
        drc=$?
        if [ "$drc" -eq 0 ]; then
            log "$cycle_engine kapatıldı; hedeften düşmesi bekleniyor (file_sd 15 sn'de bir tazelenir)"
            if wait_for "$cycle_engine hedefinin aktif listeden düşmesi" 150 target_gone "$cycle_engine"; then
                t_ok "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü"
            elif sonra="$(prom_target_count "$cycle_engine")"; then
                t_fail "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü" \
                       "150 sn sonra hâlâ listede (sayı=$sonra) — kapalı motor için sonsuza dek 'erişilemiyor' alarmı üretilir"
            else
                t_unknown "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü" \
                          "hedef sayısı Prometheus'tan okunamadı: $(hata_oku)"
            fi

            # Dosya da güncellenmiş mi? Prometheus'un listesi doğru olup dosya
            # eskimiş olabilir; o zaman controller yeniden başladığında eski
            # liste geri gelir ve arıza günler sonra ortaya çıkar.
            # grep yerine JSON ayrıştırılıyor: girinti/biçim değişirse grep
            # sessizce "bulamadım" der ve test yalancı biçimde GEÇER.
            if [ -f "$TARGETS_JSON" ]; then
                tfile_has_engine "$cycle_engine"; hrc=$?
                case "$hrc" in
                    1) t_ok "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" ;;
                    0) t_fail "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" \
                              "dosyada hâlâ engine=\"$cycle_engine\" kaydı var — do_deactivate() hedef listesini HİÇ yazmıyor (controller/app.py:2179 civarı write_routes/write_prometheus_targets çağrısı yok); do_activate() da yalnız 'failed_over' dalında yazıyor (app.py:2135-2155). Yani liste ancak devir olduğunda tazeleniyor" ;;
                    *) t_unknown "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" \
                                 "hedef dosyası okunamadı/ayrıştırılamadı: $(hata_oku)" ;;
                esac
            else
                t_skip "state/prometheus/targets.json kapanışı yansıttı ($cycle_engine çıkarıldı)" \
                       "hedef dosyası yok (2. bölümde ayrıca raporlandı)"
            fi
        elif [ "$drc" -eq 124 ]; then
            t_unknown "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü" \
                      "./stack.sh disable $cycle_engine 600 sn içinde bitmedi — motorun kapanıp kapanmadığı bilinmiyor: $(tail -3 "$TMPD/cycle.log" 2>/dev/null | tr '\n' ' ')"
        else
            t_fail "$cycle_engine kapatılınca Prometheus'un aktif hedef listesinden düştü" \
                   "./stack.sh disable $cycle_engine başarısız (çıkış $drc): $(tail -3 "$TMPD/cycle.log" 2>/dev/null | tr '\n' ' ')"
        fi

        # AÇILIŞ ÖNCESİ İMZA. Dosya yerinde yazıldığı için içerik aynı kalsa
        # bile mtime ilerler; "aktivasyon listeyi yeniden yazdı mı" sorusunun
        # tek dürüst ölçüsü budur. İçerik özetini de alıyoruz: mtime aynı ama
        # içerik farklıysa (dosya sistemi çözünürlüğü) yine "yazıldı" deriz.
        sig_once=""; sig_once_rc=1; sig_once_err=""
        if [ -f "$TARGETS_JSON" ]; then
            # Sebebi HEMEN yakalıyoruz: aradan geçen her ölçüm hata kanalını ezer.
            if sig_once="$(tfile_sig)"; then sig_once_rc=0
            else sig_once_rc=3; sig_once_err="$(hata_oku)"; fi
        fi

        # Geri aç ve hedefin GERÇEKTEN up olmasını bekle. Listeye geri gelip
        # "down" kalmak, kullanıcı açısından hiç açılmamış olmakla aynı şeydir.
        log "$cycle_engine geri açılıyor…"
        run_t "$MON_ENABLE_TIMEOUT" "$STACK_ROOT/stack.sh" enable "$cycle_engine" >> "$TMPD/cycle.log" 2>&1
        erc=$?
        if [ "$erc" -eq 0 ]; then
            # Motor gerçekten ayaktaysa temizlik borcumuz kapanır; değilse
            # RESTORE_ENGINE duruyor ve çıkışta bir kez daha denenir.
            docker_ps_refresh >/dev/null 2>&1
            engine_state "$cycle_engine" && RESTORE_ENGINE=""

            if wait_for "$cycle_engine hedefinin listeye dönüp up olması" "$MON_ENABLE_TIMEOUT" \
                        target_up "$cycle_engine"; then
                t_ok "$cycle_engine açılınca exporter'ı yeniden toplanıyor (up=1)"
            elif n_up="$(prom_scalar "count(up{job=\"databases\",engine=\"$cycle_engine\"} == 1)")"; then
                t_fail "$cycle_engine açılınca exporter'ı yeniden toplanıyor (up=1)" \
                       "${MON_ENABLE_TIMEOUT} sn içinde up=1 olmadı (ölçülen: $n_up) — motor açık ama grafikleri boş kalır"
            else
                t_unknown "$cycle_engine açılınca exporter'ı yeniden toplanıyor (up=1)" \
                          "up serisi Prometheus'tan okunamadı: $(hata_oku)"
            fi

            # ASIL İDDİA: aktivasyon hedef listesini TAZELİYOR mu?
            ad_tz="aktivasyon state/prometheus/targets.json'u yeniden yazdı ($cycle_engine)"
            if [ ! -f "$TARGETS_JSON" ]; then
                t_fail "$ad_tz" "dosya açılıştan sonra da yok — controller hedef listesini hiç yazmıyor"
            elif [ "$sig_once_rc" != 0 ]; then
                t_unknown "$ad_tz" "açılış ÖNCESİ imza alınamadı ($sig_once_err) — karşılaştırma yapılamaz"
            elif sig_sonra="$(tfile_sig)"; then
                if [ "$sig_sonra" != "$sig_once" ]; then
                    t_ok "$ad_tz"
                    # Tazelendiyse içeriğin doğruluğu da anlamlı bir soru olur.
                    tfile_has_engine "$cycle_engine"; hrc2=$?
                    case "$hrc2" in
                        0) t_ok "tazelenen hedef listesinde $cycle_engine kaydı var" ;;
                        1) t_fail "tazelenen hedef listesinde $cycle_engine kaydı var" \
                                  "dosya yeniden yazıldı ama motor listeye GİRMEDİ — exporter hiç toplanmaz, bütün panoları boş çizer" ;;
                        *) t_unknown "tazelenen hedef listesinde $cycle_engine kaydı var" \
                                     "dosya okunamadı: $(hata_oku)" ;;
                    esac
                else
                    t_fail "$ad_tz" \
                           "dosya kapanış/açılış boyunca HİÇ yeniden yazılmadı (mtime+özet aynı). do_deactivate() write_routes çağırmıyor, do_activate() ise yalnız 'failed_over' dalında çağırıyor (controller/app.py:2135-2155) — normal bir 'enable' hedef listesini tazelemiyor. Motorun yine de toplanıyor olması, kapanışta silinmemiş ESKİ kaydın tesadüfen işe yaramasındandır"
                    tfile_has_engine "$cycle_engine"; hrc2=$?
                    case "$hrc2" in
                        0) t_unknown "tazelenen hedef listesinde $cycle_engine kaydı var" \
                                     "kayıt dosyada duruyor ama dosya aktivasyonda yeniden yazılmadı; bu kaydın GÜNCEL mi yoksa kapanıştan kalma ESKİ kayıt mı olduğu ölçülemez" ;;
                        1) t_fail "tazelenen hedef listesinde $cycle_engine kaydı var" \
                                  "motor açık olduğu hâlde listede yok ve dosya tazelenmiyor — exporter hiç toplanmaz" ;;
                        *) t_unknown "tazelenen hedef listesinde $cycle_engine kaydı var" \
                                     "dosya okunamadı: $(hata_oku)" ;;
                    esac
                fi
            else
                t_unknown "$ad_tz" "açılış SONRASI imza alınamadı: $(hata_oku)"
            fi
        elif [ "$erc" -eq 124 ]; then
            t_unknown "$cycle_engine açılınca exporter'ı yeniden toplanıyor (up=1)" \
                      "./stack.sh enable $cycle_engine ${MON_ENABLE_TIMEOUT} sn içinde bitmedi — motor açıldı mı bilinmiyor. Temizlik açılışı bir kez daha deneyecek"
        else
            t_fail "$cycle_engine açılınca exporter'ı yeniden toplanıyor (up=1)" \
                   "./stack.sh enable $cycle_engine BAŞARISIZ (çıkış $erc): $(tail -3 "$TMPD/cycle.log" 2>/dev/null | tr '\n' ' ')"
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
#
# Çıkış kodu ayrımı: 3 = uç cevap vermedi (ÖLÇTÜK, arıza) · başka bir kod =
# sondanın kendisi çalışmadı (ÖLÇEMEDİK).
run_t "$MON_HTTP_TIMEOUT" docker exec -i "$CTRL_C" python - \
      > "$TMPD/metrics.txt" 2>"$TMPD/metrics.err" <<'PY'
import urllib.request, sys
try:
    sys.stdout.write(urllib.request.urlopen(
        "http://controller:8000/metrics", timeout=25).read().decode("utf-8", "replace"))
except Exception as e:
    sys.stderr.write(repr(e) + "\n")
    sys.exit(3)
PY
mrc=$?
METRICS_OK=0
if [ "$mrc" -eq 0 ] && [ -s "$TMPD/metrics.txt" ]; then
    METRICS_OK=1
    t_ok "controller /metrics ucu cevap veriyor ($(wc -l < "$TMPD/metrics.txt" | tr -d ' ') satır)"
elif [ "$mrc" -eq 0 ]; then
    t_fail "controller /metrics ucu cevap veriyor" \
           "uç 200 döndü ama gövde BOŞ — Prometheus hiçbir dbstack_* serisi toplayamaz"
elif [ "$mrc" -eq 3 ]; then
    t_fail "controller /metrics ucu cevap veriyor" \
           "$(head -c 200 "$TMPD/metrics.err" 2>/dev/null | tr '\n' ' ')"
else
    t_unknown "controller /metrics ucu cevap veriyor" \
              "ağ içi sonda çalışmadı (çıkış $mrc): $(head -c 200 "$TMPD/metrics.err" 2>/dev/null | tr '\n' ' ')"
fi

METRIK_LISTESI="dbstack_container_up dbstack_container_memory_bytes
dbstack_container_memory_limit_bytes dbstack_container_cpu_percent
dbstack_engine_active dbstack_host_memory_total_bytes
dbstack_memory_committed_bytes dbstack_memory_budget_bytes
dbstack_disk_free_bytes"

if [ "$METRICS_OK" = 1 ]; then
    for m in $METRIK_LISTESI; do
        mn="$(grep -c "^${m}[ {]" "$TMPD/metrics.txt")"
        grc=$?
        # grep -c eşleşme yoksa 1, DOSYA HATASINDA 2 döner. İkisini `|| true`
        # ile aynı sepete atmak, okunamayan bir dosyayı "metrik yok" saymaktı.
        if [ "$grc" -gt 1 ]; then
            t_unknown "$m metriği yayınlanıyor" "metrik dosyası taranamadı (grep çıkış $grc)"
        elif [ "${mn:-0}" -gt 0 ] 2>/dev/null; then
            t_ok "$m metriği yayınlanıyor ($mn seri)"
        else
            t_fail "$m metriği yayınlanıyor" "uçta bu ada ait hiç seri yok"
        fi
    done
else
    # Uç okunamadıysa 9 ayrı KALDI basmak yanıltıcı olur: ürün hakkında değil,
    # ölçüm hakkında konuşuyoruz.
    t_unknown "dbstack_* metriklerinin hepsi yayınlanıyor" \
              "/metrics içeriği alınamadığı için şu metriklerin hiçbiri sınanamadı: $(printf '%s' "$METRIK_LISTESI" | tr '\n' ' ')"
fi

# Uç ayakta olsa bile Prometheus onu toplamıyor olabilir (job=controller hedefi
# yoksa aynen böyle olur). Zincirin bu halkasını ayrıca sınıyoruz.
if pn="$(prom_scalar 'count(dbstack_container_memory_limit_bytes)')"; then
    pn="${pn%%.*}"
    if [ "${pn:-0}" -gt 0 ] 2>/dev/null; then
        t_ok "controller metrikleri Prometheus'a düşüyor (dbstack_container_memory_limit_bytes: $pn seri)"
    else
        t_fail "controller metrikleri Prometheus'a düşüyor" \
               "Prometheus'ta hiç dbstack_container_memory_limit_bytes serisi yok — uç çalışsa bile Genel Bakış panosu boş kalır"
    fi
else
    t_unknown "controller metrikleri Prometheus'a düşüyor" "Prometheus'a sorulamadı: $(hata_oku)"
fi

# --------------------------------------------------------------------------
# Limit metriği GERÇEK container limitiyle aynı mı?
# --------------------------------------------------------------------------
# Ürünün can alıcı iddiası "belleği ben hesaplıyorum". Metrik yanlış sayıyı
# gösterirse kullanıcı yanlış bir hesabı doğru sanır ve OOM'a kadar fark etmez.
# Karşılaştırma `docker inspect .HostConfig.Memory` ile yapılır; controller
# değeri MiB'e yuvarlayarak yayınladığı için beklenen değeri aynı şekilde
# yuvarlıyoruz (bkz. controller/app.py: mem_mb = int(mem) // (1024*1024)).
LIMIT_OLCULEBILIR=0
LIMIT_NEDEN=""
run_t 30 docker ps -q --filter "label=com.docker.compose.project=$PROJ" \
      > "$TMPD/ids.txt" 2>"$TMPD/ids.err"
ids_rc=$?
if [ "$ids_rc" -ne 0 ]; then
    LIMIT_NEDEN="proje container listesi alınamadı (docker ps çıkış $ids_rc): $(head -c 200 "$TMPD/ids.err" | tr '\n' ' ')"
elif [ ! -s "$TMPD/ids.txt" ]; then
    # Eski sürüm burada hiçbir container'ı incelemeden GEÇTİ basıyordu.
    LIMIT_NEDEN="docker '$PROJ' projesinde HİÇ container görmüyor (STACK_PROJECT yanlış olabilir) — oysa controller ayakta; karşılaştırılacak gerçek limit yok"
else
    # shellcheck disable=SC2046
    run_t 60 docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}|{{.HostConfig.Memory}}' \
        $(cat "$TMPD/ids.txt") > "$TMPD/limits.txt" 2>"$TMPD/limits.err"
    ins_rc=$?
    if [ "$ins_rc" -ne 0 ] || [ ! -s "$TMPD/limits.txt" ]; then
        LIMIT_NEDEN="docker inspect gerçek limitleri vermedi (çıkış $ins_rc): $(head -c 200 "$TMPD/limits.err" | tr '\n' ' ')"
    else
        LIMIT_OLCULEBILIR=1
    fi
fi

if [ "$METRICS_OK" != 1 ]; then
    t_unknown "dbstack_container_memory_limit_bytes serileri gerçek limitlerle karşılaştırıldı" \
              "/metrics içeriği alınamadı — karşılaştırılacak metrik yok"
elif [ "$LIMIT_OLCULEBILIR" != 1 ]; then
    t_unknown "dbstack_container_memory_limit_bytes serileri gerçek limitlerle karşılaştırıldı" \
              "$LIMIT_NEDEN"
else
    seen=""
    cozulemeyen=0
    karsilastirilan=0
    while IFS= read -r satir; do
        lsvc="$(printf '%s' "$satir" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
        lval="$(printf '%s' "$satir" | awk '{print $NF}')"; lval="${lval%%.*}"
        if [ -z "$lsvc" ]; then
            # service etiketi olmayan seriyi sessizce atlamak, metrikteki
            # etiket bozulmasını görünmez kılardı.
            cozulemeyen=$((cozulemeyen + 1)); continue
        fi
        seen="$seen $lsvc"
        lreal="$(awk -F'|' -v s="$lsvc" '$1==s {print $2; exit}' "$TMPD/limits.txt")"
        if [ -z "$lreal" ]; then
            t_fail "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı" \
                   "docker'da böyle bir container yok — metrik hayalet bir servisi bildiriyor"
            continue
        fi
        case "$lreal" in
            ''|*[!0-9]*) t_unknown "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı" \
                                   "docker inspect sayı vermedi ('$lreal') — karşılaştırma yapılamadı"
                         continue ;;
        esac
        case "${lval:-}" in
            ''|*[!0-9]*) t_unknown "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı" \
                                   "metrik satırından sayı okunamadı: $(printf '%s' "$satir" | cut -c1-120)"
                         continue ;;
        esac
        karsilastirilan=$((karsilastirilan + 1))
        lbek=$(( (lreal / 1048576) * 1048576 ))
        if [ "$lval" = "$lbek" ]; then
            t_ok "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı ($((lbek / 1048576)) MiB)"
        else
            t_fail "dbstack_container_memory_limit_bytes{service=\"$lsvc\"} gerçek limitle aynı" \
                   "metrik $lval bayt diyor, docker inspect $lreal bayt ($((lreal / 1048576)) MiB) diyor"
        fi
    done < <(grep '^dbstack_container_memory_limit_bytes{' "$TMPD/metrics.txt")

    if [ "$cozulemeyen" -gt 0 ]; then
        t_unknown "her limit serisinin service etiketi okunabiliyor" \
                  "$cozulemeyen seride service=\"…\" etiketi çözülemedi — o container'ların limiti karşılaştırılamadı"
    fi

    # Ters yön: limiti OLAN ama metriği yayınlanmayan container. Eksik metrik
    # grafikte "veri yok" olarak değil, çoğu panelde HİÇ GÖRÜNMEMEK olarak
    # çıkar — yani fark edilmez.
    eksik=""
    limitli=0
    while IFS='|' read -r rsvc rmem; do
        [ -n "${rsvc:-}" ] || continue
        [ "${rmem:-0}" -gt 0 ] 2>/dev/null || continue
        limitli=$((limitli + 1))
        case " $seen " in *" $rsvc "*) ;; *) eksik="$eksik $rsvc" ;; esac
    done < "$TMPD/limits.txt"
    ad_ters="bellek limiti olan her çalışan container için limit metriği yayınlanıyor"
    if [ "$limitli" -eq 0 ]; then
        # Hiç limitli container yoksa karşılaştırma boştur: eski sürüm burada
        # koşulsuz GEÇTİ basıyordu.
        t_unknown "$ad_ters" \
                  "docker'da bellek limiti TANIMLI hiç container yok (incelenen: $(wc -l < "$TMPD/limits.txt" | tr -d ' ')) — bu bir doğrulama değil, karşılaştıracak veri yokluğu. Bellek planlaması hiç uygulanmamış olabilir"
    elif [ -n "$eksik" ]; then
        t_fail "$ad_ters" "metrikte olmayanlar:$eksik ($limitli limitli container incelendi)"
    else
        t_ok "$ad_ters ($limitli limitli container, $karsilastirilan seri karşılaştırıldı)"
    fi
fi

# =============================================================================
# ÖZET — sayaçlar, çıkış kodu ve "hiçbir kontrol çalışmadı" uyarısı lib.sh'te
# =============================================================================
if [ "$WE_ENABLED_MONITORING" = 1 ] && [ "$MON_KEEP_MONITORING" != 0 ]; then
    log "izleme bu betik tarafından açıldı ve AÇIK BIRAKILDI (kapatmak için: ./stack.sh disable monitoring)"
fi
e2e_finish; exit $?
