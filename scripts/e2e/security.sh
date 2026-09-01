#!/bin/bash
# =============================================================================
# databases-stack — E2E: ERİŞİM DENETİMİ
# =============================================================================
# Çalıştırma (yığın kökünden):   ./scripts/e2e/security.sh [--host <adres>]
#
# NE ÖLÇER: bu ürünün tek savunma hattı gateway'dir. Veritabanı container'ları
# host'a port açmaz; dışarıya çıkan her şey (dashboard, paneller, metrikler,
# istemci portları) nginx'ten geçer. Yani "erişim denetimi çalışıyor mu"
# sorusunun cevabı tek bir yerde: gateway'in verdiği CEVAPLARDA. Bu betik
# yapılandırma dosyalarını okumaz — CANLI kuruluma istek atar ve cevabı ölçer.
# Bir kuralın nginx.conf'ta yazılı olması onun uygulandığı anlamına gelmez:
# location sırası, rewrite/access fazı sıralaması, `add_header ... always` ve
# `internal` hata sayfaları yüzünden yazılı kural ile canlı davranış sık sık
# ayrışır. Ayrışmayı yalnız gerçek bir cevap yakalar.
#
# YAKALADIĞI GERÇEK ARIZALAR (her kontrolün başında da yazıyor):
#   • Panel tek-oturum çerezinin PAROLASIZ cevapta sızması. Çerez `add_header
#     ... always` ile bırakılıyor; always, 401 dâhil TÜM durum kodlarını
#     kapsar. Çerez 401'de de gönderiliyorsa parolayı bilmeyen biri bir GET
#     ile alıp bütün panelleri açar — kapı sonuna kadar açık, üstelik loglarda
#     "401" yazıyor olur.
#   • CSRF kapısının yalnız POST'u durdurması. mongo-express 1.0.2'de indeks
#     silme GET'tir; kötü niyetli bir sayfadaki tek bir <img> etiketi indeksi
#     düşürebiliyordu. Bu yüzden kontrol GET ile yapılıyor.
#   • Yayınlanan portun gateway'e DEĞİL başka bir şeye gitmesi (host'ta k3s/
#     traefik, ikinci bir nginx, elle açılmış bir tünel). Cevap benzer görünür
#     ama TLS sertifikası tutmaz — bu yüzden sertifika parmak izi karşılaştırılır.
#   • Exporter/veritabanı portlarının host'a açılması. Bu portlarda kimlik
#     doğrulaması YOKTUR; iç ağdaki herkes metrikleri (ve bazı motorlarda
#     veriyi) doğrudan okur.
#
# TASARIM KURALLARI:
#   • set -e YOK: tek bir kontrolün patlaması diğerlerini iptal etmemeli.
#   • Sessiz atlama yok: ön koşulu olmayan kontrol ATLA satırı basar. Sessizce
#     atlanan test geçmiş sanılır; en tehlikeli test hatası budur.
#   • Yan etkisiz ve idempotent: yalnız GET/HEAD ve zararsız POST'lar atılır
#     (POST'lar zaten çapraz-site kapısında durur ya da katalogda olmayan bir
#     yola gider → controller 404 der). Yığında hiçbir şey değişmez, tek
#     yaratılan şey geçici dizindir ve çıkışta silinir. Arka arkaya iki kez
#     çalıştırmak aynı sonucu verir.
#   • Sabit port/parola yazılmaz: paneller ve istemci portları catalog.json'dan,
#     parolalar .env'den okunur.
# =============================================================================
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/common.sh
source "$E2E_DIR/../lib/common.sh"

ALAN="erişim denetimi"
PASS=0; FAIL=0; SKIP=0

# --------------------------------------------------------------- raporlama --
# Kontrol adı NE doğrulandığını söyler ("test 4" değil): bir gün kırmızıya
# döndüğünde nöbetçi kişinin ürünü okumadan ne bozulduğunu anlaması gerekiyor.
t_ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$GREEN" "$NC" "$1"; }
t_fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n        %s↳ %s%s\n' \
                                    "$RED" "$NC" "$1" "$RED" "${2:-ayrıntı yok}" "$NC"; }
t_skip() { SKIP=$((SKIP+1)); printf '  %sATLA%s  %s\n        %s↳ %s%s\n' \
                                    "$YELLOW" "$NC" "$1" "$YELLOW" "${2:-sebep belirtilmedi}" "$NC"; }

usage() {
    cat <<'YARDIM'
Kullanım: ./scripts/e2e/security.sh [--host <adres>]

  --host <adres>   Testlerin bağlanacağı adres. Varsayılan: .env'deki
                   STACK_HOST (yoksa 127.0.0.1). Yayınlanan portların
                   dışarıdan gerçekten geldiğini ölçtüğümüz için sunucunun
                   LAN adresi tercih edilir.

Çıkış kodu: başarısız kontrol varsa 1, yoksa 0. Atlanan kontrol kodu bozmaz
ama ekranda ATLA satırı olarak görünür.

Ortam değişkenleri (hepsi isteğe bağlı):
  E2E_HOST            --host ile aynı iş
  E2E_HTTP_TIMEOUT    tek bir HTTP isteğinin üst sınırı, saniye (varsayılan 10).
                      Sağlıklı bir gateway milisaniyelerde cevap verir; bu süre
                      yalnız "bağlantı kuruldu ama cevap gelmiyor" hâlinde
                      devreye girer ve betiğin takılmasını engeller.
  E2E_DOCKER_TIMEOUT  tek bir docker çağrısının üst sınırı (varsayılan 20)
  E2E_METRICS_PORT    metrik portu (varsayılan 9443; katalogda bu alan yok)
YARDIM
}

HOST_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST_ARG="${2:-}"; shift 2 || true ;;
        -h|--help) usage; exit 0 ;;
        *) err "Bilinmeyen seçenek: $1"; usage; exit 2 ;;
    esac
done

# =============================================================================
# 0) ÖN KOŞULLAR VE KEŞİF
# =============================================================================
# Buradaki eksiklikler kontrol değil, ölçüm imkânsızlığıdır: ölçemediğimiz bir
# şeyi "geçti" saymamak için betik burada durur (die → çıkış kodu 1).
heading "0) Ön koşullar"

command -v python3 >/dev/null 2>&1 || die "python3 gerekli — katalog okumak ve HTTPS isteği atmak için kullanılıyor (host'ta curl olmayabilir, python3 zaten yığının şartı)."
command -v docker  >/dev/null 2>&1 || die "docker gerekli — port yüzeyi ve container içi cevap docker üzerinden okunuyor."
[ -f "$CATALOG" ] || die "catalog.json bulunamadı: $CATALOG"

load_env

container_running gateway \
    || die "gateway container'ı çalışmıyor. Erişim denetiminin TAMAMI gateway'de; o kapalıyken ölçülecek bir şey yok. Önce: ./stack.sh up"

# Uzun bekleme olmasın: hiçbir docker çağrısı ve hiçbir istek sonsuza kadar
# beklemez. Zaman aşımına uğrayan kontrol FAIL olur, betik takılmaz.
HTTP_TIMEOUT="${E2E_HTTP_TIMEOUT:-10}"     # saniye — tek bir HTTP isteği
DOCKER_TIMEOUT="${E2E_DOCKER_TIMEOUT:-20}" # saniye — tek bir docker çağrısı
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
dk() {  # zaman aşımlı docker
    if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$DOCKER_TIMEOUT" docker "$@"
    else docker "$@"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dbstack-e2e-security.XXXXXX")" || die "geçici dizin açılamadı"
# TEMİZLİK: betiğin yarattığı tek kalıcı iz bu dizindir; hata da olsa silinir.
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------------------------------------------------------- HTTP istemcisi --
# curl her sunucuda yok; python3 zaten şart (compose sarmalayıcısı ve katalog
# okuması onu kullanıyor). Bu yüzden istemci burada.
cat > "$TMP/req.py" <<'PY'
# -*- coding: utf-8 -*-
"""Tek HTTP isteği: durum kodunu stdout'a, başlıkları ve gövdeyi dosyaya yazar.

YÖNLENDİRME İZLENMEZ — bilerek: ClickHouse panelinin kökü 302 ile /play'e
gider; izleseydik ölçtüğümüz cevap ikinci isteğinki olur ve "hangi cevabı
kim verdi" sorusu kaybolurdu.

PROXY ORTAM DEĞİŞKENLERİ DEVRE DIŞI — bilerek: sunucuda http_proxy tanımlıysa
istek yayınlanan portu hiç denemeden vekile giderdi; test yanlış yeri ölçer,
üstelik yeşil kalırdı.

SERTİFİKA DOĞRULANMAZ: iç CA ile imzalı sertifikayı doğrulamak testin konusu
değil (onu ayrı olarak parmak iziyle karşılaştırıyoruz); burada ölçülen şey
kimlik doğrulama ve CSRF kapısı.
"""
import base64
import os
import ssl
import sys
import urllib.error
import urllib.request

headers = {}
for line in os.environ.get("Q_HEADERS", "").split("\n"):
    if ":" in line:
        k, v = line.split(":", 1)
        headers[k.strip()] = v.strip()

auth = os.environ.get("Q_AUTH", "")
if auth:
    headers["Authorization"] = "Basic " + base64.b64encode(
        auth.encode("utf-8")).decode("ascii")

data = os.environ.get("Q_BODY", "")
data = data.encode("utf-8") if data else None

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _NoRedirect,
    urllib.request.HTTPSHandler(context=ctx))

req = urllib.request.Request(os.environ["Q_URL"], data=data, headers=headers,
                             method=os.environ.get("Q_METHOD", "GET"))
code, body, hdrs = 0, b"", ""
try:
    r = opener.open(req, timeout=float(os.environ.get("Q_TIMEOUT", "10")))
    code, body, hdrs = r.code, r.read(), str(r.headers)
except urllib.error.HTTPError as e:          # 4xx/5xx de bir cevaptır
    code, body, hdrs = e.code, e.read(), str(e.headers)
except Exception as e:                        # bağlantı hiç kurulamadı
    sys.stderr.write("%s: %s\n" % (type(e).__name__, e))

with open(os.environ["Q_BODYFILE"], "wb") as f:
    f.write(body)
with open(os.environ["Q_HDRFILE"], "w", encoding="utf-8") as f:
    f.write(hdrs)
print(code)
PY

# TLS parmak izi: yayınlanan portta HANGİ sunucunun cevap verdiğini kanıtlar.
cat > "$TMP/tls.py" <<'PY'
# -*- coding: utf-8 -*-
"""Verilen adres:porttan sunulan sertifikanın SHA-256 parmak izini basar.

SNI GÖNDERİLMİYOR: gateway'de tek varsayılan sunucu var (server_name _), ayrıca
adres çoğu kurulumda IP. Araya giren başka bir sunucu kendi sertifikasını
sunacağı için parmak izi tutmaz — aradığımız sinyal bu.
"""
import hashlib
import os
import socket
import ssl
import sys

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    with socket.create_connection(
            (os.environ["Q_HOST"], int(os.environ["Q_PORT"])),
            timeout=float(os.environ.get("Q_TIMEOUT", "10"))) as s:
        with ctx.wrap_socket(s) as ss:
            print(hashlib.sha256(ss.getpeercert(True)).hexdigest())
except Exception as e:
    sys.stderr.write("%s: %s\n" % (type(e).__name__, e))
    print("HATA")
PY

cat > "$TMP/pem.py" <<'PY'
# -*- coding: utf-8 -*-
"""PEM dosyasındaki sertifikanın SHA-256 parmak izi (DER üzerinden).
Container'ın içinden okunan sertifika ile ağdan görülen sertifika ancak böyle
karşılaştırılabilir: metin biçimi (satır sonu, boşluk) değişebilir, DER değişmez.
"""
import hashlib
import ssl
import sys

try:
    pem = open(sys.argv[1], encoding="utf-8").read()
    print(hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest())
except Exception as e:
    sys.stderr.write("%s: %s\n" % (type(e).__name__, e))
    print("HATA")
PY

cat > "$TMP/tcp.py" <<'PY'
# -*- coding: utf-8 -*-
"""TCP bağlantısı kurulabiliyor mu? (sonsuz beklemesin diye zaman aşımlı)"""
import os
import socket
import sys

try:
    socket.create_connection((os.environ["Q_HOST"], int(os.environ["Q_PORT"])),
                             timeout=float(os.environ.get("Q_TIMEOUT", "5"))).close()
    print("acik")
except Exception as e:
    sys.stderr.write("%s: %s\n" % (type(e).__name__, e))
    print("kapali")
PY

REQ_HEADERS=""; REQ_AUTH=""; REQ_BODY=""
req() {  # req <METOD> <URL>  → durum kodu (bağlantı kurulamadıysa 0)
    local code
    : > "$TMP/err"
    code="$(Q_METHOD="$1" Q_URL="$2" Q_HEADERS="$REQ_HEADERS" Q_AUTH="$REQ_AUTH" \
            Q_BODY="$REQ_BODY" Q_BODYFILE="$TMP/body" Q_HDRFILE="$TMP/hdr" \
            Q_TIMEOUT="$HTTP_TIMEOUT" python3 "$TMP/req.py" 2>"$TMP/err")"
    # Başlıklar TEK KULLANIMLIK: bir kontrolden kalan Sec-Fetch/çerez bir
    # sonrakine sızarsa test yanlış şeyi ölçer ve fark edilmez.
    REQ_HEADERS=""; REQ_AUTH=""; REQ_BODY=""
    printf '%s' "${code:-0}"
}

why() {  # why <beklenen> <gelen> → FAIL satırının ayrıntısı
    local msg="beklenen HTTP $1, gelen $2"
    if [ "$2" = "0" ] && [ -s "$TMP/err" ]; then
        msg="$msg — bağlantı kurulamadı: $(tr '\n' ' ' < "$TMP/err" | cut -c1-140)"
    fi
    printf '%s' "$msg"
}

body_has() { grep -qF -- "$1" "$TMP/body" 2>/dev/null; }
body_peek() { tr -d '\r' < "$TMP/body" | tr '\n' ' ' | cut -c1-100; }

# Parolayı GATEWAY mi istedi, arkadaki panel mi? Ayrımı yapmak zorundayız:
# mongo-express'in KENDİ basic auth'u var ve gateway ona Authorization
# başlığını bilerek iletiyor (ikinci savunma katmanı). Tek-oturum çerezi
# gateway'i geçtiğinde mongo-express yine de kendi parolasını sorabilir; bunu
# "gateway hâlâ parola soruyor" sanıp FAIL basmak yanlış alarm olurdu.
# Gateway'in 401'i realm'inden tanınır: auth_basic "databases-stack …".
gw_asked_password() {
    grep -i '^www-authenticate:' "$TMP/hdr" 2>/dev/null | grep -qi 'databases-stack'
}

tcp_open() {  # tcp_open <host> <port> → "acik" / "kapali"
    Q_HOST="$1" Q_PORT="$2" Q_TIMEOUT=5 python3 "$TMP/tcp.py" 2>/dev/null
}

# ------------------------------------------------------------ katalog oku ---
# Panel portları, istemci portları ve exporter servisleri KATALOGDAN gelir.
# Sabit yazsaydık katalog büyüdüğünde (13. kayıt izleme aracı olarak sonradan
# eklendi) yeni portlar sessizce test edilmemiş kalırdı.
python3 - "$CATALOG" "$TMP" <<'PY'
import json
import sys

cat = json.load(open(sys.argv[1], encoding="utf-8"))
out = sys.argv[2]
panels, routes, exps, engines = [], [], [], []
seen_panel = set()
for e in cat["engines"]:
    engines.append("%s\t%s\t%s" % (e["id"], e.get("primary_service", ""), e.get("name", "")))
    p = e.get("panel") or {}
    if p.get("port") and p["port"] not in seen_panel:
        seen_panel.add(p["port"])
        panels.append((p["port"], p.get("name", "panel"), e["id"]))
    for r in (e.get("route") or []):
        routes.append("%d\t%d\t%s" % (r["listen"], r["upstream_port"], e["id"]))
    x = e.get("exporter") or {}
    if x.get("service"):
        exps.append("%s\t%s\t%s\t%s" % (x["service"], x.get("metrics_path", ""),
                                        e["id"], "1" if x.get("builtin") else "0"))

# newline="\n" ŞART: Python metin kipinde satır sonunu platforma çevirir.
# Windows'ta düzenlenip çalıştırılan bir kurulumda satır sonu \r\n olur ve
# kabuktaki `read` son alanın sonuna görünmez bir \r ekler; "e1" ile "e1\r"
# eşleşmediği için motor eşleştirmesi sessizce boşa düşer — test yeşil kalır
# ama hiçbir şey ölçmez. Bu, betiği yazarken sahte bir kurulumda BİRE BİR
# yaşandı.
for name, rows in (("panels.tsv", ["%d\t%s\t%s" % p for p in sorted(panels)]),
                   ("routes.tsv", routes), ("exporters.tsv", exps),
                   ("engines.tsv", engines)):
    with open(out + "/" + name, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(r + "\n" for r in rows))
PY
[ -s "$TMP/panels.tsv" ] || die "catalog.json'dan panel portu okunamadı — katalog bozuk olabilir."

# ----------------------------------------------------------- adres/portlar --
HTTPS_PORT="${GATEWAY_HTTPS_PORT:-443}"
HTTP_PORT="${GATEWAY_HTTP_PORT:-80}"
# 9443'ün katalogda bir alanı YOK: metrik ucu tek ve gateway'e ait, compose'da
# sabit yazılı. Yine de körlemesine kullanmıyoruz — aşağıda `docker port
# gateway` ile gerçekten yayınlandığını doğruluyoruz, yoksa bölüm atlanıyor.
METRICS_PORT="${E2E_METRICS_PORT:-9443}"

HOST="$HOST_ARG"
[ -z "$HOST" ] && HOST="${E2E_HOST:-${STACK_HOST:-}}"
if [ -z "$HOST" ]; then
    HOST="127.0.0.1"
    warn "STACK_HOST boş — 127.0.0.1 kullanılıyor. Yayınlanan portların LAN'dan geldiğini ölçmek için: --host <sunucu-ip>"
fi
# .env ile ÇALIŞAN container ayrışabilir: GATEWAY_HTTPS_PORT değiştirilip
# gateway yeniden yaratılmadıysa .env'deki port ile gerçek yayın portu farklıdır.
# Bu durumda ölçümü gerçek porta taşıyoruz — ama sessizce değil, uyararak.
if [ "$(tcp_open "$HOST" "$HTTPS_PORT")" != "acik" ]; then
    gwp="$(dk port gateway 443/tcp 2>/dev/null | head -1 | sed 's/.*://')"
    if [ -n "$gwp" ] && [ "$gwp" != "$HTTPS_PORT" ]; then
        warn ".env'de GATEWAY_HTTPS_PORT=$HTTPS_PORT yazıyor ama container 443'ü $gwp portundan yayınlıyor — $gwp kullanılıyor (gateway .env değişikliğinden sonra yeniden yaratılmamış olabilir)"
        HTTPS_PORT="$gwp"
    fi
fi
if [ "$(tcp_open "$HOST" "$HTTPS_PORT")" != "acik" ]; then
    warn "$HOST:$HTTPS_PORT'a bağlanılamadı — 127.0.0.1 deneniyor."
    HOST="127.0.0.1"
    [ "$(tcp_open "$HOST" "$HTTPS_PORT")" = "acik" ] \
        || die "gateway'in HTTPS portuna ($HTTPS_PORT) hiçbir adresten bağlanılamadı. Container ayakta ama port yayınlanmıyor olabilir: docker port gateway"
fi
# URL'de IPv6 adresi köşeli parantez ister.
case "$HOST" in *:*) HOSTU="[$HOST]" ;; *) HOSTU="$HOST" ;; esac
DASH="https://$HOSTU:$HTTPS_PORT"

# ------------------------------------------------------------------ parola --
# Panel parolası .env'den. Boşsa .env.example'ın söylediği gibi DB_PASSWORD'a
# düşer. İkisi de yoksa "doğru parola ile geçiyor" kontrolleri ATLANIR —
# parolasız 401 kontrolleri yine çalışır (asıl güvenlik iddiası odur).
PANEL_USER_V="${PANEL_USER:-admin}"
PANEL_PASS_V="${PANEL_PASSWORD:-}"
[ -z "$PANEL_PASS_V" ] && PANEL_PASS_V="${DB_PASSWORD:-}"
AUTH="$PANEL_USER_V:$PANEL_PASS_V"
HAVE_AUTH=1; [ -z "$PANEL_PASS_V" ] && HAVE_AUTH=0
NO_AUTH_REASON="gateway/.htpasswd parolası .env'de yok (PANEL_PASSWORD ve DB_PASSWORD boş) — kimlik doğrulanmış istek atılamıyor"

if [ "$HAVE_AUTH" = 1 ]; then
    AUTH_NOTE="(parola .env dosyasından okundu)"
else
    AUTH_NOTE="(PAROLA YOK — kimlik doğrulaması gerektiren kontroller ATLANACAK)"
fi
[ -f "$ENV_FILE" ] || warn ".env bulunamadı ($ENV_FILE) — parola gerektiren kontroller atlanacak"

log "adres      : $HOST  (dashboard $HTTPS_PORT, http $HTTP_PORT, metrik $METRICS_PORT)"
log "panel portu: $(cut -f1 "$TMP/panels.tsv" | tr '\n' ' ')"
log "panel kul. : $PANEL_USER_V $AUTH_NOTE"
log "istek zaman aşımı: ${HTTP_TIMEOUT}s — hiçbir bekleme sonsuz değil"

# =============================================================================
# 1) DASHBOARD (:443) — parola kapısı ve çerez sızıntısı
# =============================================================================
heading "1) Dashboard ($DASH)"

# Ürünün en temel iddiası: yönetim panosuna parolasız girilemez.
code="$(req GET "$DASH/")"
[ "$code" = "401" ] \
    && t_ok "dashboard / parolasız 401 veriyor" \
    || t_fail "dashboard / parolasız 401 veriyor" "$(why 401 "$code")"

# ÇEREZ SIZINTISI — bu betikteki en önemli kontrol.
# Panel tek-oturum çerezi `add_header ... always` ile bırakılıyor; `always`
# 401 dâhil TÜM durum kodlarını kapsar. Çerez 401 cevabında da gönderiliyorsa
# parolayı bilmeyen biri tek bir GET ile onu alır ve BÜTÜN panelleri parolasız
# açar. Erişim kayıtlarında yalnızca "401" görünür — sızıntı sessizdir.
LEAK_COOKIE="$(grep -i '^set-cookie:' "$TMP/hdr" 2>/dev/null \
               | sed -n 's/.*dbstack_sso=\([^;]*\).*/\1/p' | head -1)"
if [ -z "$LEAK_COOKIE" ]; then
    t_ok "dashboard 401 cevabı panel tek-oturum çerezini SIZDIRMIYOR"
else
    t_fail "dashboard 401 cevabı panel tek-oturum çerezini SIZDIRMIYOR" \
           "parolasız istek Set-Cookie: dbstack_sso=... aldı — bu çerez panel portlarında parolayı devre dışı bırakıyor"
fi

code="$(REQ_AUTH="$PANEL_USER_V:kesinlikle-yanlis-parola-$$" req GET "$DASH/")"
[ "$code" = "401" ] \
    && t_ok "dashboard / yanlış parolayla 401 veriyor" \
    || t_fail "dashboard / yanlış parolayla 401 veriyor" "$(why 401 "$code")"

# Kontrol API'si ve katalog: kimliği doğrulanmamış istek buraya da giremez.
# /api/engines/<id>/connection cevabında veritabanı PAROLALARI var.
code="$(req GET "$DASH/api/status")"
[ "$code" = "401" ] \
    && t_ok "kontrol API'si /api/status parolasız 401 veriyor" \
    || t_fail "kontrol API'si /api/status parolasız 401 veriyor" "$(why 401 "$code")"

code="$(req GET "$DASH/catalog.json")"
[ "$code" = "401" ] \
    && t_ok "/catalog.json parolasız 401 veriyor (kurulu motor listesi sızmıyor)" \
    || t_fail "/catalog.json parolasız 401 veriyor (kurulu motor listesi sızmıyor)" "$(why 401 "$code")"

# Yukarıdaki 401'lerin "gateway tamamen bozuk, her şeye 401 diyor"dan
# ayrılması için doğru parolanın GERÇEKTEN geçtiğini de görmek gerekiyor.
DASH_OK=0
if [ "$HAVE_AUTH" = 0 ]; then
    t_skip "dashboard / doğru parolayla 200 veriyor" "$NO_AUTH_REASON"
else
    code="$(REQ_AUTH="$AUTH" req GET "$DASH/")"
    if [ "$code" = "200" ]; then
        DASH_OK=1; t_ok "dashboard / doğru parolayla 200 veriyor"
    else
        t_fail "dashboard / doğru parolayla 200 veriyor" \
               "$(why 200 "$code") — .env'deki parola ile gateway/.htpasswd ayrışmış olabilir (./install.sh yeniden üretir)"
    fi
fi

# =============================================================================
# 2) PANEL PORTLARI — parolasız girilemiyor
# =============================================================================
heading "2) Panel portları — parola kapısı (katalogdan okundu)"

# Sonda `location = /` gibi özel eşleşmelere denk gelmeyen bir yol kullanıyoruz:
# ClickHouse panelinin kökü rewrite fazında 302 döndürüyor ve access fazına
# (yani parola kontrolüne) hiç gelmiyor. "/" ile ölçseydik o portta 302 görüp
# yanlış yere FAIL basardık. Bu yol her panelde `location /`e düşer.
PROBE="/dbstack-e2e-erisim-denetimi-sondasi"
bad=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(req GET "https://$HOSTU:$pport$PROBE")"
    if [ "$code" != "401" ]; then
        bad="$bad ${pport}(${pname}):$code"
    elif ! gw_asked_password; then
        # 401 var ama parolayı GATEWAY istemedi → istek arkadaki panele
        # ULAŞMIŞ ve kapıyı panelin kendi auth'u tutmuş demektir. Yalnız
        # mongo-express'te kendi auth'u var; diğerlerinde bu, gateway'in
        # parola kapısının düştüğü ve panele göre değişen bir savunmaya
        # kaldığımız anlamına gelir.
        bad="$bad ${pport}(${pname}):401-ama-gateway-sormadi"
    fi
done < "$TMP/panels.tsv"
[ -z "$bad" ] \
    && t_ok "$n panel portunun hepsi parolasız ve çerezsiz istekte gateway'in 401'ini veriyor" \
    || t_fail "$n panel portunun hepsi parolasız ve çerezsiz istekte gateway'in 401'ini veriyor" \
              "sorunlu portlar:$bad (0 = bağlantı kurulamadı; port yayınlanmıyor ya da nginx'te bu porta server bloğu yok)"

# Sahte çerez: parolayı devre dışı bırakan tek şey DOĞRU sırdır. Eski bir
# hatada çerez yokluğu ile boş çerez aynı anahtara düşüyor ve tanımsız sır
# durumunda bütün paneller parolasız açılıyordu.
bad=""
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    code="$(REQ_HEADERS="Cookie: dbstack_sso=sahte-cerez-$$-deneme" req GET "https://$HOSTU:$pport$PROBE")"
    [ "$code" = "401" ] || bad="$bad ${pport}(${pname}):$code"
done < "$TMP/panels.tsv"
[ -z "$bad" ] \
    && t_ok "sahte tek-oturum çerezi hiçbir panelde parolayı atlatmıyor (401)" \
    || t_fail "sahte tek-oturum çerezi hiçbir panelde parolayı atlatmıyor (401)" \
              "sahte çerezi kabul eden portlar:$bad"

# Boş çerez ayrı bir durum: nginx'te "çerez yok" ile "çerez boş" aynı değere
# düşer; eşleştirme doğrudan yapılsaydı ve sır tanımsız olsaydı boş çerez
# bütün panelleri açardı. Bu yüzden ayrıca ölçülüyor.
bad=""
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    code="$(REQ_HEADERS="Cookie: dbstack_sso=" req GET "https://$HOSTU:$pport$PROBE")"
    [ "$code" = "401" ] || bad="$bad ${pport}(${pname}):$code"
done < "$TMP/panels.tsv"
[ -z "$bad" ] \
    && t_ok "BOŞ tek-oturum çerezi hiçbir panelde parolayı atlatmıyor (401)" \
    || t_fail "BOŞ tek-oturum çerezi hiçbir panelde parolayı atlatmıyor (401)" \
              "boş çerezi kabul eden portlar:$bad"

# =============================================================================
# 3) PANEL TEK OTURUMU — dashboard'a girince bırakılan çerez
# =============================================================================
heading "3) Panel tek oturumu (dashboard çerezi)"

SSO_COOKIE=""; SSO_LINE=""
if [ "$DASH_OK" != 1 ]; then
    # İKİ kontrol birden atlanıyor; ikisi de ayrı ayrı raporlanmalı, yoksa
    # ekranda hiç görünmez ve "geçti" sanılır.
    t_skip "dashboard girişi tek-oturum çerezini bırakıyor" \
           "dashboard doğru parolayla açılamadı (bkz. yukarıdaki satır) — bırakılacak çerez yok"
    t_skip "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor" \
           "çerez hiç alınamadı (dashboard doğru parolayla açılamadı)"
else
    code="$(REQ_AUTH="$AUTH" req GET "$DASH/")"
    SSO_LINE="$(grep -i '^set-cookie:.*dbstack_sso=' "$TMP/hdr" 2>/dev/null | head -1)"
    SSO_COOKIE="$(printf '%s' "$SSO_LINE" | sed -n 's/.*dbstack_sso=\([^;]*\).*/\1/p')"
    if [ -n "$SSO_COOKIE" ]; then
        t_ok "dashboard girişi tek-oturum çerezini bırakıyor (Set-Cookie: dbstack_sso)"
    else
        t_fail "dashboard girişi tek-oturum çerezini bırakıyor (Set-Cookie: dbstack_sso)" \
               "200 geldi ama Set-Cookie yok — PANEL_SSO_TOKEN .env'de boş olabilir; bu durumda her panelde ikinci kez parola sorulur"
    fi

    # Çerezin ÖZELLİKLERİ de erişim denetiminin parçası: HttpOnly olmayan çerez
    # bir XSS ile çalınır, Secure olmayan çerez düz HTTP'ye sızar, SameSite
    # olmayan çerez çapraz-site isteklerle birlikte gider.
    if [ -z "$SSO_LINE" ]; then
        t_skip "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor" \
               "Set-Cookie başlığı hiç gelmedi"
    else
        miss=""
        printf '%s' "$SSO_LINE" | grep -qi 'HttpOnly'     || miss="$miss HttpOnly"
        printf '%s' "$SSO_LINE" | grep -qi 'Secure'       || miss="$miss Secure"
        printf '%s' "$SSO_LINE" | grep -qi 'SameSite=Lax' || miss="$miss SameSite=Lax"
        printf '%s' "$SSO_LINE" | grep -qi 'Path=/'       || miss="$miss Path=/"
        [ -z "$miss" ] \
            && t_ok "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor" \
            || t_fail "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor" \
                      "eksik özellik:$miss — satır: $(printf '%s' "$SSO_LINE" | cut -c1-120)"
    fi
fi

if [ -z "$SSO_COOKIE" ]; then
    t_skip "dashboard çerezi tüm panel portlarında parolayı devre dışı bırakıyor" \
           "çerez elde edilemedi (dashboard girişi ya da PANEL_SSO_TOKEN eksik)"
else
    bad=""; own=""
    while IFS=$'\t' read -r pport pname peid; do
        [ -n "$pport" ] || continue
        code="$(REQ_HEADERS="Cookie: dbstack_sso=$SSO_COOKIE" req GET "https://$HOSTU:$pport$PROBE")"
        # Motor kapalıysa 503 ("pasif" sayfası), açıksa panelin kendi cevabı
        # (404/200/302) gelir; hepsi "gateway parola sormadı" demektir.
        if [ "$code" = "0" ]; then
            bad="$bad ${pport}(${pname}):bağlanılamadı"
        elif [ "$code" = "401" ] && gw_asked_password; then
            bad="$bad ${pport}(${pname}):gateway-401"
        elif [ "$code" = "401" ]; then
            # Gateway geçildi, parolayı arkadaki panel istedi (mongo-express'in
            # kendi basic auth'u böyledir). Tek oturum kapısı açısından geçer;
            # yine de kullanıcı orada ikinci kez parola görecek, bilinsin.
            own="$own ${pport}(${pname})"
        fi
    done < "$TMP/panels.tsv"
    [ -n "$own" ] && log "not: şu panellerde parolayı gateway değil panelin kendisi soruyor:$own"
    [ -z "$bad" ] \
        && t_ok "dashboard çerezi tüm panel portlarında parolayı devre dışı bırakıyor" \
        || t_fail "dashboard çerezi tüm panel portlarında parolayı devre dışı bırakıyor" \
                  "hâlâ parola soran portlar:$bad — kullanıcı her panelde .env'den parola aramak zorunda kalır"
fi

# Sızan çerezin gerçekten işe yarayıp yaramadığı: 1. bölümdeki sızıntı
# kontrolü kırmızıysa, bunun ne kadar ciddi olduğunu burada kanıtlıyoruz.
if [ -z "$LEAK_COOKIE" ]; then
    t_skip "parolasız 401'de sızan çerez panelleri AÇAMIYOR" \
           "401 cevabında çerez sızmadı — denenecek bir sızıntı yok"
else
    first_panel="$(head -1 "$TMP/panels.tsv" | cut -f1)"
    code="$(REQ_HEADERS="Cookie: dbstack_sso=$LEAK_COOKIE" req GET "https://$HOSTU:$first_panel$PROBE")"
    [ "$code" = "401" ] \
        && t_ok "parolasız 401'de sızan çerez panelleri AÇAMIYOR" \
        || t_fail "parolasız 401'de sızan çerez panelleri AÇAMIYOR" \
                  "panel :$first_panel sızan çerezle $code döndü — parolayı hiç bilmeyen biri bütün panellere giriyor"
fi

# =============================================================================
# 4) /api/ — ÇAPRAZ-SİTE KORUMASI
# =============================================================================
heading "4) Kontrol API'si (/api/) çapraz-site koruması"

# Kimlik doğrulama Basic auth ile yapılıyor ve tarayıcı, bu adrese giden HER
# isteğe kimlik bilgisini KENDİ ekliyor. Yani panele bir kez girmiş bir
# yöneticinin tarayıcısında açılan kötü niyetli bir sayfa, gizli bir POST ile
# veritabanı durdurabilir ya da replika diskini sildirebilirdi. Kapı:
# Sec-Fetch-Site (tarayıcının doldurduğu, sayfanın değiştiremediği başlık).
API_PROBE="/api/dbstack-e2e-yok-boyle-bir-uc"

code="$(REQ_AUTH="$AUTH" \
        REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: cors\nOrigin: https://kotu-site.example\nContent-Type: application/json' \
        REQ_BODY='{}' req POST "$DASH$API_PROBE")"
if [ "$code" = "403" ] && body_has "durduruldu"; then
    t_ok "/api/ çapraz-siteden gelen POST 403 ile durduruluyor (kimlik doğrulanmış olsa bile)"
elif [ "$code" = "403" ]; then
    t_fail "/api/ çapraz-siteden gelen POST 403 ile durduruluyor (kimlik doğrulanmış olsa bile)" \
           "403 geldi ama gövde gateway'in açıklama metni değil — cevabı controller vermiş olabilir: $(body_peek)"
else
    t_fail "/api/ çapraz-siteden gelen POST 403 ile durduruluyor (kimlik doğrulanmış olsa bile)" \
           "$(why 403 "$code") — çapraz-site kapısı kapalı; kötü niyetli bir sayfa yöneticinin tarayıcısından motor durdurabilir"
fi

# Aynı kapı GET'i de kapatmalı: /api/engines/<id>/connection cevabında
# veritabanı PAROLALARI var. Sadece POST kapatılsaydı, kötü niyetli bir sayfa
# fetch ile parolaları okumayı deneyebilirdi.
first_eid="$(head -1 "$TMP/engines.tsv" | cut -f1)"
code="$(REQ_AUTH="$AUTH" \
        REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: cors\nOrigin: https://kotu-site.example' \
        req GET "$DASH/api/engines/$first_eid/connection")"
if [ "$code" = "403" ] && ! body_has "password"; then
    t_ok "/api/ çapraz-siteden GET .../connection 403 — bağlantı parolaları sızmıyor"
else
    t_fail "/api/ çapraz-siteden GET .../connection 403 — bağlantı parolaları sızmıyor" \
           "$(why 403 "$code")$(body_has "password" && printf ' — GÖVDEDE "password" alanı var, parola çapraz-siteye gitti')"
fi

# Sec-Fetch-* göndermeyen eski tarayıcılar için ikinci kapı: Origin.
code="$(REQ_AUTH="$AUTH" \
        REQ_HEADERS=$'Origin: https://kotu-site.example\nContent-Type: application/json' \
        REQ_BODY='{}' req POST "$DASH$API_PROBE")"
[ "$code" = "403" ] \
    && t_ok "/api/ Sec-Fetch göndermeyen tarayıcıda yabancı Origin ile POST 403" \
    || t_fail "/api/ Sec-Fetch göndermeyen tarayıcıda yabancı Origin ile POST 403" \
              "$(why 403 "$code") — eski tarayıcılarda kalan tek kapı Origin'di"

# Kapı meşru kullanımı kesmemeli: dashboard'un kendi POST'u geçmeli. Aksi
# hâlde "Aktif Et" düğmesi çalışmaz ve kullanıcı ürünü hiç kullanamaz.
if [ "$HAVE_AUTH" = 0 ]; then
    t_skip "/api/ same-origin POST kapıdan geçiyor (dashboard düğmeleri çalışıyor)" "$NO_AUTH_REASON"
else
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS="$(printf 'Sec-Fetch-Site: same-origin\nSec-Fetch-Mode: cors\nOrigin: %s\nContent-Type: application/json' "$DASH")" \
            REQ_BODY='{}' req POST "$DASH$API_PROBE")"
    case "$code" in
        404) t_ok "/api/ same-origin POST kapıdan geçiyor (controller cevaplıyor: 404 = bilinmeyen uç)" ;;
        503) t_skip "/api/ same-origin POST kapıdan geçiyor (dashboard düğmeleri çalışıyor)" \
                    "kapı geçildi ama controller cevap vermiyor (gateway 503) — uçtan uca doğrulanamadı; controller'ı kontrol edin: docker ps | grep controller" ;;
        403) t_fail "/api/ same-origin POST kapıdan geçiyor (dashboard düğmeleri çalışıyor)" \
                    "kendi sayfamızın isteği de 403 yedi — çapraz-site kapısı fazla dar, dashboard'un hiçbir düğmesi çalışmaz" ;;
        *)   t_fail "/api/ same-origin POST kapıdan geçiyor (dashboard düğmeleri çalışıyor)" "$(why 404 "$code")" ;;
    esac
fi

# =============================================================================
# 5) PANEL CSRF — isteği KİM başlattı
# =============================================================================
heading "5) Panel CSRF kapısı (yöntem değil, isteği kimin başlattığı)"

# Bu kontrolün GET ile yapılmasının sebebi somut: kapı eskiden yalnız HTTP
# yöntemine bakıyordu ve "GET okumadır" varsayıyordu. mongo-express 1.0.2'de
# indeks silme GET'tir:
#     GET /db/<vt>/dropIndex/<koleksiyon>?name=...
# Kötü niyetli bir sayfadaki tek bir <img src="..."> etiketi kapıdan geçiyor,
# tarayıcı da panele girmiş yöneticinin kimlik bilgisini isteğe kendisi
# ekliyordu. Canlı container'da üretildi: indeks gerçekten düştü.
# Aşağıdaki yol var olmayan bir veritabanı/koleksiyon adı taşıyor: kapı
# çalışmıyorsa bile hiçbir veri kaybolmaz, yalnız FAIL satırı basılır.
CSRF_GET="/db/dbstack_e2e_yok/dropIndex/dbstack_e2e_yok?name=dbstack_e2e_yok"

bad=""
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: no-cors\nSec-Fetch-Dest: image' \
            req GET "https://$HOSTU:$pport$CSRF_GET")"
    if [ "$code" != "403" ]; then
        bad="$bad ${pport}(${pname}):$code"
    elif ! body_has "Bu istek durduruldu"; then
        # 403 var ama gateway'in sayfası değil → cevap ARKADAKİ panelden
        # geliyor olabilir, yani istek panele ULAŞMIŞ demektir.
        bad="$bad ${pport}(${pname}):403-ama-gateway-sayfasi-degil"
    fi
done < "$TMP/panels.tsv"
[ -z "$bad" ] \
    && t_ok "çapraz-siteden GET ile gelen indeks-silme isteği hiçbir panele ulaşmıyor (403)" \
    || t_fail "çapraz-siteden GET ile gelen indeks-silme isteği hiçbir panele ulaşmıyor (403)" \
              "durdurmayan portlar:$bad — <img src> ile tetiklenen silme uçları açık"

bad=""
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: no-cors\nContent-Type: application/x-www-form-urlencoded' \
            REQ_BODY='dbstack=e2e' req POST "https://$HOSTU:$pport$PROBE")"
    [ "$code" = "403" ] || bad="$bad ${pport}(${pname}):$code"
done < "$TMP/panels.tsv"
[ -z "$bad" ] \
    && t_ok "çapraz-siteden gelen gizli form POST'u hiçbir panele ulaşmıyor (403)" \
    || t_fail "çapraz-siteden gelen gizli form POST'u hiçbir panele ulaşmıyor (403)" \
              "durdurmayan portlar:$bad"

# Aynı host'un BAŞKA bir portundaki sayfa (tarayıcı buna "same-site" der) da
# panele veri yazamamalı: dashboard :443'ten panel :8083'e giden gizli bir
# form POST'u bu kademede durur. Yalnız üst-seviye gezinme (giriş) geçer.
bad=""
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: same-site\nSec-Fetch-Mode: no-cors\nContent-Type: application/x-www-form-urlencoded' \
            REQ_BODY='dbstack=e2e' req POST "https://$HOSTU:$pport$PROBE")"
    [ "$code" = "403" ] || bad="$bad ${pport}(${pname}):$code"
done < "$TMP/panels.tsv"
[ -z "$bad" ] \
    && t_ok "same-site alt-kaynak POST'u hiçbir panele ulaşmıyor (403)" \
    || t_fail "same-site alt-kaynak POST'u hiçbir panele ulaşmıyor (403)" \
              "durdurmayan portlar:$bad"

# Kapı meşru girişi kesmemeli: dashboard'daki "Panel aç" düğmesi ayrı porta
# gider ve tarayıcı buna "same-site + navigate" der. Bu kontrol kırmızıysa
# koruma değil, ürünün kendisi bozulmuş demektir.
bad=""
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: same-site\nSec-Fetch-Mode: navigate\nSec-Fetch-Dest: document' \
            req GET "https://$HOSTU:$pport$PROBE")"
    case "$code" in 403|0) bad="$bad ${pport}(${pname}):$code" ;; esac
done < "$TMP/panels.tsv"
[ -z "$bad" ] \
    && t_ok "dashboard'dan panele giriş gezinmesi (same-site + navigate) tüm panellerde geçiyor" \
    || t_fail "dashboard'dan panele giriş gezinmesi (same-site + navigate) tüm panellerde geçiyor" \
              "geçmeyen portlar:$bad — kullanıcı panellerine giremez"

# =============================================================================
# 6) METRİK PORTU (:9443)
# =============================================================================
heading "6) Metrik portu (:$METRICS_PORT)"

METRICS_PUBLISHED="$(dk port gateway "$METRICS_PORT/tcp" 2>/dev/null)"
FIRST_METRIC_PATH="$(head -1 "$TMP/exporters.tsv" | cut -f2)"
[ -n "$FIRST_METRIC_PATH" ] || FIRST_METRIC_PATH="/metrics/mariadb"

NO_METRICS_REASON="gateway bu portu yayınlamıyor (docker port gateway $METRICS_PORT/tcp boş) — kurulum onu kapatmış olabilir"
if [ -z "$METRICS_PUBLISHED" ]; then
    # Üç kontrol birden atlanıyor; üçü de ayrı satır olarak raporlanıyor.
    t_skip "metrik portu :$METRICS_PORT parolasız 401 veriyor" "$NO_METRICS_REASON"
    t_skip "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" "$NO_METRICS_REASON"
    t_skip "metrik portu doğru parola ile gerçek metrik döndürüyor" "$NO_METRICS_REASON"
else
    code="$(req GET "https://$HOSTU:$METRICS_PORT$FIRST_METRIC_PATH")"
    [ "$code" = "401" ] \
        && t_ok "metrik portu :$METRICS_PORT $FIRST_METRIC_PATH parolasız 401 veriyor" \
        || t_fail "metrik portu :$METRICS_PORT $FIRST_METRIC_PATH parolasız 401 veriyor" \
                  "$(why 401 "$code") — exporter'lar kimlik doğrulaması YAPMAZ; bu port açıksa iç ağdaki herkes metrikleri okur"

    # Bilinmeyen yol: 9443'te `location /` yok. Parolayla 404 gelmeli — 200
    # gelirse keyfi bir upstream'e proxy açılmış demektir.
    if [ "$HAVE_AUTH" = 0 ]; then
        t_skip "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" "$NO_AUTH_REASON"
        t_skip "metrik portu doğru parola ile gerçek metrik döndürüyor" "$NO_AUTH_REASON"
    else
        code="$(REQ_AUTH="$AUTH" req GET "https://$HOSTU:$METRICS_PORT/metrics/dbstack-e2e-yok")"
        [ "$code" = "404" ] \
            && t_ok "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" \
            || t_fail "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" "$(why 404 "$code")"

        # Doğru parola ile gerçekten metrik gelmeli; yoksa Prometheus sessizce
        # boş toplar ve panolar boş kalır. Çalışan bir exporter arıyoruz.
        mrun=""; mpath=""
        while IFS=$'\t' read -r msvc mpth meid mbuiltin; do
            [ -n "$msvc" ] || continue
            if container_running "$msvc"; then mrun="$msvc"; mpath="$mpth"; break; fi
        done < "$TMP/exporters.tsv"
        if [ -z "$mrun" ]; then
            t_skip "metrik portu doğru parola ile gerçek metrik döndürüyor" \
                   "hiçbir exporter container'ı çalışmıyor (motorlar kapalı) — ölçülecek canlı uç yok"
        else
            code="$(REQ_AUTH="$AUTH" req GET "https://$HOSTU:$METRICS_PORT$mpath")"
            if [ "$code" = "200" ] && body_has "# HELP"; then
                t_ok "metrik portu doğru parola ile gerçek metrik döndürüyor ($mpath ← $mrun)"
            else
                t_fail "metrik portu doğru parola ile gerçek metrik döndürüyor ($mpath ← $mrun)" \
                       "$(why 200 "$code") / gövde: $(body_peek)"
            fi
        fi
    fi
fi

# =============================================================================
# 7) PORT YÜZEYİ — host'a ne açılmış?
# =============================================================================
heading "7) Host'a açılan portlar (docker ps ile doğrulanıyor)"

PROJ="${STACK_PROJECT:-databases-stack}"
dk ps --filter "label=com.docker.compose.project=$PROJ" --format '{{.Names}}' 2>/dev/null \
    | sed '/^$/d' > "$TMP/containers.txt"
if [ ! -s "$TMP/containers.txt" ]; then
    # Etiket filtresi tutmadıysa (elle başlatılmış container'lar) katalogdaki
    # servis adlarına düşüyoruz — sessizce boş liste ile "hepsi temiz" DEMEYİZ.
    warn "compose etiketiyle container bulunamadı (proje: $PROJ) — çalışan tüm container'lara bakılıyor"
    dk ps --format '{{.Names}}' 2>/dev/null | sed '/^$/d' > "$TMP/containers.txt"
fi

if [ ! -s "$TMP/containers.txt" ]; then
    t_skip "host'a port açan tek container gateway" "çalışan container listelenemedi (docker ps boş döndü)"
else
    bad=""
    while read -r cname; do
        [ -n "$cname" ] || continue
        [ "$cname" = "gateway" ] && continue
        pmap="$(dk port "$cname" 2>/dev/null | sed '/^$/d')"
        if [ -n "$pmap" ]; then
            bad="$bad $cname[$(printf '%s' "$pmap" | tr '\n' ',' | cut -c1-60)]"
        fi
    done < "$TMP/containers.txt"
    [ -z "$bad" ] \
        && t_ok "host'a port açan tek container gateway ($(wc -l < "$TMP/containers.txt" | tr -d ' ') container denetlendi)" \
        || t_fail "host'a port açan tek container gateway" \
                  "port açan başka container'lar:$bad — bu portlarda gateway'in parolası ve TLS'i YOKTUR"
fi

# Exporter'lar ayrıca ve adıyla kontrol ediliyor: metrikler kimlik doğrulaması
# olmadan sunulur ve içlerinde sorgu/kullanıcı adları geçer. Tek doğru yol
# 9443'ten, parolalı ve TLS'li geçmektir.
checked=0; missing=""; bad=""
while IFS=$'\t' read -r msvc mpth meid mbuiltin; do
    [ -n "$msvc" ] || continue
    if ! container_running "$msvc"; then missing="$missing $msvc"; continue; fi
    checked=$((checked+1))
    pmap="$(dk port "$msvc" 2>/dev/null | sed '/^$/d')"
    [ -n "$pmap" ] && bad="$bad ${msvc}[$(printf '%s' "$pmap" | tr '\n' ',' | cut -c1-40)]"
done < "$TMP/exporters.tsv"
if [ "$checked" = 0 ]; then
    t_skip "çalışan exporter container'larının hiçbiri host'a port açmamış" \
           "hiçbir exporter çalışmıyor (kapalı:$missing) — kapalı motorda ölçülecek port yok"
else
    [ -z "$bad" ] \
        && t_ok "çalışan $checked exporter container'ının hiçbiri host'a port açmamış" \
        || t_fail "çalışan $checked exporter container'ının hiçbiri host'a port açmamış" \
                  "host'a açılmış exporter portları:$bad — metrik uçlarında parola yoktur, iç ağdaki herkes okur"
fi

# Controller: kontrol düzlemi. Host'a port açmaz; token'ı gateway ekler.
if container_running controller; then
    pmap="$(dk port controller 2>/dev/null | sed '/^$/d')"
    [ -z "$pmap" ] \
        && t_ok "controller host'a port açmamış (kontrol düzlemine yalnız gateway üzerinden gidiliyor)" \
        || t_fail "controller host'a port açmamış (kontrol düzlemine yalnız gateway üzerinden gidiliyor)" \
                  "açık portlar: $(printf '%s' "$pmap" | tr '\n' ' ')"
else
    t_skip "controller host'a port açmamış" "controller container'ı çalışmıyor"
fi

# Veritabanı istemci portları GATEWAY üzerinden gelmeli: failover'da arkadaki
# ana kopya değişse bile uygulamanın adresi değişmesin diye. Port host'ta
# yayınlanmış ama nginx onu dinlemiyorsa, istemci "bağlantı kuruldu sonra
# koptu" hatası alır ve sebebini hiç bulamaz.
ROUTES_CONF="$(dk exec gateway cat /etc/nginx/stream.d/routes.conf 2>/dev/null)"
mapped=""; unlistened=""; nroute=0
while IFS=$'\t' read -r rlisten rup reid; do
    [ -n "$rlisten" ] || continue
    nroute=$((nroute+1))
    # `docker port` çıktısı boşsa eşleme yok demektir; çıkış kodu docker
    # sürümüne göre değişiyor, bu yüzden ÇIKTIYA bakıyoruz.
    [ -z "$(dk port gateway "$rlisten/tcp" 2>/dev/null)" ] && mapped="$mapped ${reid}:${rlisten}"
    printf '%s' "$ROUTES_CONF" | grep -qE "listen[[:space:]]+$rlisten;" || unlistened="$unlistened ${reid}:${rlisten}"
done < "$TMP/routes.tsv"

[ -z "$mapped" ] \
    && t_ok "katalogdaki $nroute istemci portunun hepsi host'ta gateway'e eşlenmiş" \
    || t_fail "katalogdaki $nroute istemci portunun hepsi host'ta gateway'e eşlenmiş" \
              "gateway'de eşlemesi olmayan portlar:$mapped — bu motorlara dışarıdan hiç bağlanılamaz"

if [ -z "$ROUTES_CONF" ]; then
    t_skip "gateway nginx katalogdaki tüm istemci portlarını gerçekten dinliyor" \
           "stream yönlendirme tablosu okunamadı (docker exec gateway cat /etc/nginx/stream.d/routes.conf boş) — controller onu henüz yazmamış olabilir"
else
    [ -z "$unlistened" ] \
        && t_ok "gateway nginx katalogdaki tüm istemci portlarını gerçekten dinliyor (stream routes)" \
        || t_fail "gateway nginx katalogdaki tüm istemci portlarını gerçekten dinliyor (stream routes)" \
                  "yönlendirme tablosunda olmayan portlar:$unlistened — port host'ta açık ama arkasında kimse yok; istemci sebepsiz kopma yaşar"
fi

badp=""
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    [ -z "$(dk port gateway "$pport/tcp" 2>/dev/null)" ] && badp="$badp ${pport}(${pname})"
done < "$TMP/panels.tsv"
[ -z "$badp" ] \
    && t_ok "katalogdaki tüm panel portları host'ta gateway'e eşlenmiş" \
    || t_fail "katalogdaki tüm panel portları host'ta gateway'e eşlenmiş" \
              "eşlemesi olmayan panel portları:$badp — katalog ile compose ayrışmış"

# =============================================================================
# 8) YAYINLANAN PORT GERÇEKTEN GATEWAY'E Mİ GİDİYOR?
# =============================================================================
heading "8) Dışarıdan gelen cevap ile container içinden alınan cevap aynı mı?"

# NEDEN: `docker port` yalnız docker'ın NİYETİNİ gösterir. Host'ta başka bir
# şey (k3s/traefik, ikinci bir nginx, elle kurulmuş bir tünel) aynı portu
# kapmışsa cevap benzer görünür ama gateway'den gelmez — parolasız, TLS'i
# başka bir sertifikayla. Bunu ayırt eden şey sertifikanın PARMAK İZİDİR.
GW_CERT_FP=""
if dk exec gateway cat /etc/nginx/certs/server.crt > "$TMP/gw.crt" 2>"$TMP/err"; then
    GW_CERT_FP="$(python3 "$TMP/pem.py" "$TMP/gw.crt" 2>/dev/null)"
fi
[ "$GW_CERT_FP" = "HATA" ] && GW_CERT_FP=""

if [ -z "$GW_CERT_FP" ]; then
    CERT_REASON="gateway container'ından /etc/nginx/certs/server.crt okunamadı: $(tr '\n' ' ' < "$TMP/err" | cut -c1-120)"
    t_skip "dashboard :$HTTPS_PORT dışarıdan bakıldığında gateway'in kendi sertifikasını sunuyor (araya giren yok)" "$CERT_REASON"
    t_skip "panel ve metrik portlarının hepsi aynı gateway sertifikasını sunuyor" "$CERT_REASON"
else
    fp="$(Q_HOST="$HOST" Q_PORT="$HTTPS_PORT" Q_TIMEOUT="$HTTP_TIMEOUT" python3 "$TMP/tls.py" 2>/dev/null)"
    if [ "$fp" = "$GW_CERT_FP" ]; then
        t_ok "dashboard :$HTTPS_PORT dışarıdan bakıldığında gateway'in kendi sertifikasını sunuyor (araya giren yok)"
    else
        t_fail "dashboard :$HTTPS_PORT dışarıdan bakıldığında gateway'in kendi sertifikasını sunuyor (araya giren yok)" \
               "dışarıdan görülen parmak izi ${fp:-cevap-yok}, gateway'inki $GW_CERT_FP — bu portu başka bir servis (k3s/traefik, ikinci nginx) kapmış olabilir"
    fi

    # Panel portları ve metrik portu da aynı gateway'de olmalı. Tek tek FAIL
    # basmak yerine tutmayanları listeliyoruz; ad hangi portların denendiğini
    # söylüyor, ayrıntı hangisinin tutmadığını.
    bad=""; n=0
    # Parmak izleri listede KISALTILIYOR (ilk 16 hane): 12 panel × 64 hane tek
    # satıra sığmaz, sığdırmaya çalışınca da hangi portun tutmadığı kaybolur.
    # Ayrım için 16 hane fazlasıyla yeterli.
    while IFS=$'\t' read -r pport pname peid; do
        [ -n "$pport" ] || continue
        n=$((n+1))
        fp="$(Q_HOST="$HOST" Q_PORT="$pport" Q_TIMEOUT="$HTTP_TIMEOUT" python3 "$TMP/tls.py" 2>/dev/null)"
        if [ "$fp" != "$GW_CERT_FP" ]; then
            fps="cevap-yok"; [ -n "$fp" ] && fps="${fp:0:16}…"
            bad="$bad ${pport}(${pname}):$fps"
        fi
    done < "$TMP/panels.tsv"
    if [ -n "$METRICS_PUBLISHED" ]; then
        n=$((n+1))
        fp="$(Q_HOST="$HOST" Q_PORT="$METRICS_PORT" Q_TIMEOUT="$HTTP_TIMEOUT" python3 "$TMP/tls.py" 2>/dev/null)"
        if [ "$fp" != "$GW_CERT_FP" ]; then
            fps="cevap-yok"; [ -n "$fp" ] && fps="${fp:0:16}…"
            bad="$bad ${METRICS_PORT}(metrik):$fps"
        fi
    fi
    [ -z "$bad" ] \
        && t_ok "$n panel/metrik portunun hepsi aynı gateway sertifikasını sunuyor" \
        || t_fail "$n panel/metrik portunun hepsi aynı gateway sertifikasını sunuyor" \
                  "gateway'in parmak izi ${GW_CERT_FP:0:16}…, tutmayan portlar:$bad"
fi

# İkinci kanıt: aynı sağlık ucunun cevabı container'ın İÇİNDEN ve dışarıdan
# alınıp karşılaştırılıyor. HTTP portu bilerek seçildi — /health orada
# auth'suz (healthcheck ve izleme buradan bakıyor), yani karşılaştırma
# kimlik doğrulamasından bağımsız.
INSIDE=""
if [ -n "$TIMEOUT_BIN" ]; then
    INSIDE="$("$TIMEOUT_BIN" "$DOCKER_TIMEOUT" docker exec gateway wget -q -O - -T 5 http://127.0.0.1/health 2>/dev/null)"
else
    INSIDE="$(docker exec gateway wget -q -O - -T 5 http://127.0.0.1/health 2>/dev/null)"
fi
INSIDE="$(printf '%s' "$INSIDE" | tr -d '\r\n')"

# Host portunu .env'den DEĞİL docker'dan alıyoruz: karşılaştırmanın anlamı
# "dışarıdaki bu port ile içerideki nginx aynı mı" olduğu için, dışarıdaki
# portun gerçekten o container'a eşlenen port olması gerekiyor.
HTTP_HOSTPORT="$(dk port gateway 80/tcp 2>/dev/null | head -1 | sed 's/.*://')"
if [ -z "$INSIDE" ]; then
    t_skip "yayınlanan HTTP portundan gelen /health cevabı container içindekiyle aynı" \
           "container içinden cevap alınamadı (docker exec gateway wget) — nginx içeride cevap vermiyor olabilir"
elif [ -z "$HTTP_HOSTPORT" ]; then
    t_skip "yayınlanan HTTP portundan gelen /health cevabı container içindekiyle aynı" \
           "gateway 80/tcp'yi yayınlamıyor — karşılaştırılacak dış uç yok"
else
    [ "$HTTP_HOSTPORT" = "$HTTP_PORT" ] \
        || warn ".env'deki GATEWAY_HTTP_PORT=$HTTP_PORT ile gerçek yayın portu $HTTP_HOSTPORT ayrışmış — ölçüm $HTTP_HOSTPORT üzerinden yapılıyor"
    code="$(req GET "http://$HOSTU:$HTTP_HOSTPORT/health")"
    OUTSIDE="$(tr -d '\r\n' < "$TMP/body")"
    if [ "$code" = "200" ] && [ "$OUTSIDE" = "$INSIDE" ]; then
        t_ok "yayınlanan HTTP portundan (:$HTTP_HOSTPORT) gelen /health cevabı container içindekiyle birebir aynı"
    else
        t_fail "yayınlanan HTTP portundan (:$HTTP_HOSTPORT) gelen /health cevabı container içindekiyle birebir aynı" \
               "$(why 200 "$code"); içeriden '$INSIDE', dışarıdan '$(printf '%s' "$OUTSIDE" | cut -c1-60)' — araya başka bir servis girmiş olabilir"
    fi
fi

# İstemci portları TCP: yayınlanmış port gerçekten bağlantı kabul ediyor mu?
# Yalnız AKTİF motorlar için anlamlı — kapalı motorun portu da açılır (nginx
# dinler) ama arkasında kimse yoktur; onu yukarıdaki routes.conf kontrolü
# ölçüyor, burada bağlantıyı ölçüyoruz.
active_checked=0; closed=""
while IFS=$'\t' read -r eid prim ename; do
    [ -n "$eid" ] || continue
    engine_active "$eid" || continue
    while IFS=$'\t' read -r rlisten rup reid; do
        [ "$reid" = "$eid" ] || continue
        hostport="$(dk port gateway "$rlisten/tcp" 2>/dev/null | head -1 | sed 's/.*://')"
        [ -n "$hostport" ] || { closed="$closed ${eid}:${rlisten}(eşleme-yok)"; continue; }
        active_checked=$((active_checked+1))
        [ "$(tcp_open "$HOST" "$hostport")" = "acik" ] || closed="$closed ${eid}:${hostport}"
    done < "$TMP/routes.tsv"
done < "$TMP/engines.tsv"

# Sıra önemli: "hiç aktif motor yok" ile "aktif motor var ama portu kapalı"
# ayrı şeyler. Yalnız sayaca baksaydık, eşlemesi hiç olmayan bir motor
# ATLA satırı üretirdi — yani gerçek bir arıza "ön koşul yok" gibi görünürdü.
if [ -n "$closed" ]; then
    t_fail "aktif motorların istemci portları dışarıdan TCP bağlantısı kabul ediyor" \
           "sorunlu portlar:$closed — motor çalışıyor ama uygulamalar bağlanamaz"
elif [ "$active_checked" = 0 ]; then
    t_skip "aktif motorların istemci portları dışarıdan TCP bağlantısı kabul ediyor" \
           "hiçbir motor aktif değil — dışarıdan denenecek istemci portu yok (./stack.sh list ile durumu görebilirsiniz)"
else
    t_ok "aktif motorların $active_checked istemci portu dışarıdan TCP bağlantısı kabul ediyor"
fi

# =============================================================================
# ÖZET
# =============================================================================
TOTAL=$((PASS+FAIL))
printf '\n'
if [ "$FAIL" -gt 0 ]; then
    printf '%s%s: %d/%d geçti%s' "$RED" "$ALAN" "$PASS" "$TOTAL" "$NC"
else
    printf '%s%s: %d/%d geçti%s' "$GREEN" "$ALAN" "$PASS" "$TOTAL" "$NC"
fi
[ "$SKIP" -gt 0 ] && printf ' %s(%d kontrol atlandı — yukarıdaki ATLA satırlarına bakın)%s' "$YELLOW" "$SKIP" "$NC"
printf '\n\n'

[ "$FAIL" -gt 0 ] && exit 1
exit 0
