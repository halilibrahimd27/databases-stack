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
#   • Kademeli panel kapısının ORTA katmanının düşmesi: dashboard (:443)
#     sayfasından panele (:8083) giden gizli form POST'u. Tarayıcı buna
#     "same-site + navigate" der; birinci kapıdan geçer, yalnız $panel_deny
#     kademesinde durur. Bu yüzden AYRI bir kontrolü var.
#   • Yayınlanan portun gateway'e DEĞİL başka bir şeye gitmesi (host'ta k3s/
#     traefik, ikinci bir nginx, elle açılmış bir tünel). Cevap benzer görünür
#     ama TLS sertifikası tutmaz — bu yüzden sertifika parmak izi karşılaştırılır.
#   • Exporter/veritabanı portlarının host'a açılması. Bu portlarda kimlik
#     doğrulaması YOKTUR; iç ağdaki herkes metrikleri (ve bazı motorlarda
#     veriyi) doğrudan okur.
#
# TASARIM KURALLARI:
#   • set -e YOK: tek bir kontrolün patlaması diğerlerini iptal etmemeli.
#   • Sonuç bildirimi scripts/e2e/lib.sh'te; DÖRT tür var, üç değil:
#       t_ok      ölçtük, doğru
#       t_fail    ölçtük, yanlış
#       t_skip    ÖN KOŞUL YOK (motor kapalı, parola tanımsız) — meşru
#       t_unknown ÖLÇEMEDİK (istek atılamadı, docker cevap vermedi, dosya
#                 okunamadı) — BAŞARISIZ sayılır
#     Bu betikte her kontrol "ölçüm ARACI çalışmazsa ne olur" sorusuna göre
#     yazıldı: aracın bozulması hiçbir yerde t_ok'a düşmez. Denetimde
#     bulunanlar tam olarak bu sınıftandı — sorgu düşünce kontrol yeşil
#     yazıyordu.
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
# Sayaçlar, sonuç türleri ve ÇIKIŞ KODU ortak kütüphanede — sekiz paketin
# sekizinde de ayrı ayrı yazılıp sekizinde de aynı hata yapıldığı için.
E2E_SUITE="security"
# shellcheck source=lib.sh
source "$E2E_DIR/lib.sh"

usage() {
    cat <<'YARDIM'
Kullanım: ./scripts/e2e/security.sh [--host <adres>]

  --host <adres>   Testlerin bağlanacağı adres. Varsayılan: .env'deki
                   STACK_HOST (yoksa 127.0.0.1). Yayınlanan portların
                   dışarıdan gerçekten geldiğini ölçtüğümüz için sunucunun
                   LAN adresi tercih edilir.

Çıkış kodu (lib.sh'te tanımlı):
  0    en az bir kontrol çalıştı, hiçbiri başarısız/ölçülemedi
  1    başarısız ya da ÖLÇÜLEMEYEN kontrol var ("bilmiyorum" ile "iyi" aynı
       şey değildir; ölçülemeyen kontrol başarısız sayılır)
  2    HİÇBİR kontrol çalışmadı — ölçüm yapılamadı, bu bir başarı değildir
  130  kesildi (Ctrl-C / SIGTERM). Yarıda kalan koşum GEÇERSİZDİR.
Atlanan kontrol çıkış kodunu bozmaz ama ekranda ATLANDI satırı olarak görünür.

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

# Ön koşul eksikse `die` ile çıkmıyoruz: die özet satırını hiç üretmez ve
# run.sh "hiçbir kontrol çalışmadı" (2) ile "bir kontrol düştü" (1) arasındaki
# farkı göremez. Sebebi bir SONUÇ SATIRI olarak basıp lib.sh'e bırakıyoruz.
bitir() { e2e_finish; exit $?; }

# =============================================================================
# 0) ÖN KOŞULLAR VE KEŞİF
# =============================================================================
# Buradaki eksiklikler kontrol değil, ölçüm imkânsızlığıdır. Ayrımı koruyoruz:
# ARAÇ yoksa (python3, docker, katalog) ÖLÇEMEDİK; ÜRÜN kapalıysa (gateway
# ayakta değil) ön koşul yok, ATLANDI.
heading "0) Ön koşullar"

ARAC_ADI="ölçüm araçları hazır (python3 + docker + catalog.json)"
if ! command -v python3 >/dev/null 2>&1; then
    t_unknown "$ARAC_ADI" \
        "python3 yok — katalog okumak ve HTTPS isteği atmak için gerekli (host'ta curl olmayabilir, python3 zaten yığının şartı). Hiçbir kontrol ölçülemez."
    bitir
fi
if ! command -v docker >/dev/null 2>&1; then
    t_unknown "$ARAC_ADI" \
        "docker yok — port yüzeyi ve container içi cevap docker üzerinden okunuyor. Hiçbir kontrol ölçülemez."
    bitir
fi
if [ ! -f "$CATALOG" ]; then
    t_unknown "$ARAC_ADI" \
        "catalog.json bulunamadı: $CATALOG — panel/istemci portları oradan okunuyor, hangi portu sınayacağımızı bilmiyoruz."
    bitir
fi

# Uzun bekleme olmasın: hiçbir docker çağrısı ve hiçbir istek sonsuza kadar
# beklemez. Zaman aşımına uğrayan kontrol ÖLÇÜLEMEDİ olur, betik takılmaz.
HTTP_TIMEOUT="${E2E_HTTP_TIMEOUT:-10}"     # saniye — tek bir HTTP isteği
DOCKER_TIMEOUT="${E2E_DOCKER_TIMEOUT:-20}" # saniye — tek bir docker çağrısı
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
dk() {  # zaman aşımlı docker
    if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$DOCKER_TIMEOUT" docker "$@" </dev/null
    else docker "$@" </dev/null; fi
}

# Zaman aşımlı python3. İçerideki Q_TIMEOUT yalnız BETİK ÇALIŞMAYA BAŞLADIKTAN
# sonra korur; yorumlayıcının kendisi takılırsa (yüklü makinede görüldü: tek
# bir python3 dört dakika boyunca hiçbir şey yapmadan asılı kaldı) betik
# sonsuza kadar bekler ve hiçbir sonuç basmaz. Dışarıdan da sınırlıyoruz:
# takılan ölçüm aracı artık ÖLÇÜLEMEDİ satırına dönüşüyor.
# </dev/null ŞART: bu çağrıların çoğu `while read ... done < liste` döngüsünün
# içinde; stdin'i devralan bir çocuk süreç listeyi yiyip döngüyü erken
# bitirirse geriye "hiçbir port sınanmadı ama hata da yok" kalırdı.
PY_TIMEOUT=$((HTTP_TIMEOUT + 5))
py() {
    if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$PY_TIMEOUT" python3 "$@" </dev/null
    else python3 "$@" </dev/null; fi
}

TMP=""
temizle() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; return 0; }
# TEMİZLİK YALNIZ EXIT'TE. Eskiden trap INT ve TERM'i de yakalıyordu ama
# handler yalnız siliyordu: bash sinyalde handler'ı çalıştırıp betiği KALDIĞI
# YERDEN sürdürdüğü için $TMP silinmiş hâlde devam ediyor, panels.tsv okuyan
# bütün döngüler sıfır kez dönüyor ve "bad" boş kaldığı için ~10 kontrol HİÇ
# İSTEK ATMADAN "geçti" yazıyordu (Ctrl-C, CI zaman aşımı, `timeout` sarmalı).
# Sinyali artık lib.sh yakalıyor ve 130 ile ÇIKIYOR; çıkış da bu trap'i
# tetikliyor, yani dizin yine siliniyor. Kemer-askı olarak her döngü kaç satır
# okuduğunu sayıyor: sıfır satır okunduysa sonuç t_ok değil t_unknown.
trap temizle EXIT

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dbstack-e2e-security.XXXXXX")" || TMP=""
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
    t_unknown "$ARAC_ADI" "geçici dizin açılamadı (mktemp) — istek/cevap dosyaları yazılamaz, hiçbir kontrol ölçülemez."
    bitir
fi

load_env

# ------------------------------------------------------------ docker durumu -
# `docker ps` ÇALIŞMADIĞINDA "hiçbir container çalışmıyor" ile "docker cevap
# vermiyor" aynı şeye benziyordu: ikisinde de liste boş dönüyor ve kontrol
# "motor kapalı" diye ATLANDI basıyordu. Ayrımı çıkış koduyla yapıyoruz.
PS_RC=1
ps_yenile() {
    dk ps --format '{{.Names}}' > "$TMP/ps.raw" 2>"$TMP/dkerr"; PS_RC=$?
    return $PS_RC
}
calisiyor_mu() {   # 0 = çalışıyor, 1 = çalışmıyor, 2 = ÖLÇEMEDİK
    [ "$PS_RC" -eq 0 ] || return 2
    grep -qx -- "$1" "$TMP/ps.raw"
}
docker_hatasi() { tr '\n' ' ' < "$TMP/dkerr" 2>/dev/null | cut -c1-160; }

ps_yenile
if [ "$PS_RC" -ne 0 ]; then
    t_unknown "gateway ayakta (erişim denetiminin tamamı orada)" \
        "docker ps çalışmadı (çıkış $PS_RC): $(docker_hatasi) — container'ların durumu okunamadığı için hiçbir şey ölçülemez."
    bitir
fi
if ! calisiyor_mu gateway; then
    t_skip "gateway ayakta (erişim denetiminin tamamı orada)" \
        "gateway container'ı çalışmıyor. Erişim denetiminin TAMAMI gateway'de; o kapalıyken ölçülecek bir şey yok. Önce: ./stack.sh up"
    bitir
fi

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

ÇIKIŞ KODU: bağlantı hiç kurulamadıysa 0 basılır ama çıkış kodu 0'dır — bu
"ölçtük, cevap gelmedi" demektir. Betik "istemci hiç çalışmadı" (çıkış kodu
sıfır değil / çıktı boş) hâlini bundan AYIRIYOR: birincisi ürün hakkında bir
gözlem, ikincisi ölçüm yokluğudur.
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

Bağlantı/TLS hatasında "HATA" basar ve ÇIKIŞ KODU 3 olur: çağıran taraf
"parmak izi tutmadı" (ürün arızası) ile "parmak izi hiç alınamadı" (ölçüm
yok) arasını ayırabilsin diye.
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
    sys.exit(3)
PY

cat > "$TMP/pem.py" <<'PY'
# -*- coding: utf-8 -*-
"""PEM dosyasındaki sertifikanın SHA-256 parmak izi (DER üzerinden).
Container'ın içinden okunan sertifika ile ağdan görülen sertifika ancak böyle
karşılaştırılabilir: metin biçimi (satır sonu, boşluk) değişebilir, DER değişmez.
Okunamazsa "HATA" basar ve çıkış kodu 3 olur.
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
    sys.exit(3)
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

# ---------------------------------------------------------------- istek/cevap
# ÖLÇEMEDİK İŞARETİ. req() üç şeyi ayırıyor:
#   "<sayı>"  cevap geldi (403, 401, 200 …)
#   "0"       bağlantı kurulamadı — ürün hakkında bir gözlem ama BU KONTROLÜN
#             iddiası ölçülmedi, o yüzden t_ok'a düşmez
#   "ARAC"    istemcinin KENDİSİ çalışmadı (python3 patladı, dosya silindi,
#             çıktı boş) — hiçbir istek atılmadı
ARAC="ARAC"
REQ_HEADERS=""; REQ_AUTH=""; REQ_BODY=""
req() {  # req <METOD> <URL>  → durum kodu / "0" / "ARAC"
    local code rc
    # GÖVDE VE BAŞLIK HER İSTEKTE SIFIRLANIR: eskiden sıfırlanmıyordu ve
    # req.py hiç çalışamadığında body_has/gw_asked_password BİR ÖNCEKİ
    # isteğin verisiyle karar veriyordu — yani ölçüm düşünce kontrol
    # başkasının cevabına bakıp "geçti" diyebiliyordu.
    : > "$TMP/err"; : > "$TMP/body"; : > "$TMP/hdr"
    code="$(Q_METHOD="$1" Q_URL="$2" Q_HEADERS="$REQ_HEADERS" Q_AUTH="$REQ_AUTH" \
            Q_BODY="$REQ_BODY" Q_BODYFILE="$TMP/body" Q_HDRFILE="$TMP/hdr" \
            Q_TIMEOUT="$HTTP_TIMEOUT" py "$TMP/req.py" 2>"$TMP/err")"
    rc=$?
    # Başlıklar TEK KULLANIMLIK: bir kontrolden kalan Sec-Fetch/çerez bir
    # sonrakine sızarsa test yanlış şeyi ölçer ve fark edilmez.
    REQ_HEADERS=""; REQ_AUTH=""; REQ_BODY=""
    if [ "$rc" -ne 0 ] || [ -z "$code" ]; then printf '%s' "$ARAC"; return 1; fi
    case "$code" in *[!0-9]*) printf '%s' "$ARAC"; return 1 ;; esac
    printf '%s' "$code"
}

olculemedi() {   # 0 = bu koddan sonuç çıkarılamaz
    [ "$1" = "$ARAC" ] || [ "$1" = "0" ]
}

olcum_hatasi() {  # olcum_hatasi <kod> → ÖLÇÜLEMEDİ satırının sebebi
    local ek; ek="$(tr '\n' ' ' < "$TMP/err" 2>/dev/null | cut -c1-160)"
    if [ "$1" = "$ARAC" ]; then
        printf 'HTTP istemcisi (python3 req.py) hiç çalışmadı: %s — istek ATILMADI, bu iddia hakkında hiçbir şey bilmiyoruz' "${ek:-sebep yok}"
    else
        printf 'bağlantı kurulamadı: %s — istek karşı tarafa hiç ulaşmadı, iddia SINANMADI' "${ek:-sebep yok}"
    fi
}

why() {  # why <beklenen> <gelen> → BAŞARISIZ satırının ayrıntısı
    printf 'beklenen HTTP %s, gelen %s' "$1" "$2"
}

# Tek istekli kontrollerin ortak gövdesi. Ölçüm aracı bozulduğunda t_ok'a
# düşmemesinin tek yolu bu ayrımı TEK yerde yapmak.
kod_bekle() {   # kod_bekle <ad> <beklenen> <gelen> [fail_eki]
    local ad="$1" bek="$2" gel="$3" ek="${4:-}"
    if olculemedi "$gel"; then
        t_unknown "$ad" "$(olcum_hatasi "$gel")"
        return 1
    fi
    if [ "$gel" = "$bek" ]; then t_ok "$ad"; return 0; fi
    t_fail "$ad" "$(why "$bek" "$gel")${ek:+ — $ek}"
    return 1
}

body_has() { grep -qF -- "$1" "$TMP/body" 2>/dev/null; }
body_peek() { tr -d '\r' < "$TMP/body" 2>/dev/null | tr '\n' ' ' | cut -c1-100; }

# Parolayı GATEWAY mi istedi, arkadaki panel mi? Ayrımı yapmak zorundayız:
# mongo-express'in KENDİ basic auth'u var ve gateway ona Authorization
# başlığını bilerek iletiyor (ikinci savunma katmanı). Tek-oturum çerezi
# gateway'i geçtiğinde mongo-express yine de kendi parolasını sorabilir; bunu
# "gateway hâlâ parola soruyor" sanıp BAŞARISIZ basmak yanlış alarm olurdu.
# Gateway'in 401'i realm'inden tanınır: auth_basic "databases-stack …".
gw_asked_password() {
    [ -s "$TMP/hdr" ] || return 1
    grep -i '^www-authenticate:' "$TMP/hdr" 2>/dev/null | grep -qi 'databases-stack'
}

tcp_open() {  # tcp_open <host> <port> → "acik" / "kapali" / "hata"
    local out rc
    out="$(Q_HOST="$1" Q_PORT="$2" Q_TIMEOUT=5 py "$TMP/tcp.py" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then printf 'hata'; return 2; fi
    printf '%s' "$out"
    [ "$out" = "acik" ]
}

# ---------------------------------------------------------------- docker port
# `docker port` çıktısı boşsa "eşleme yok" DEMEK ZORUNDA DEĞİL: container adı
# yanlışsa, daemon düşmüşse ya da çağrı zaman aşımına uğradıysa da boş döner.
# Boşluğu körce "eşleme yok" saymak, docker'ın ölmesini "port kapalı, her şey
# yolunda" diye raporlamak olurdu. stderr + çıkış kodu ile ayırıyoruz.
DK_PORT_OUT=""
dk_port() {   # dk_port <container> [port/tcp] → 0 eşleme var, 1 eşleme yok, 2 ÖLÇEMEDİK
    local rc
    DK_PORT_OUT="$(dk port "$@" 2>"$TMP/dkerr")"; rc=$?
    DK_PORT_OUT="$(printf '%s' "$DK_PORT_OUT" | sed '/^$/d')"
    [ -n "$DK_PORT_OUT" ] && return 0
    [ "$rc" -ge 124 ] && return 2          # timeout(1): 124/125/126/127/137
    [ -s "$TMP/dkerr" ] && return 2        # "No such container", daemon hatası…
    return 1
}

# `docker exec` sağlam mı? Bunu bir kez ölçüyoruz ki "dosya yok" ile "docker
# konuşmuyor" ayrılabilsin: birincisi ATLANDI, ikincisi ÖLÇÜLEMEDİ.
EXEC_OK=0
dk exec gateway true >/dev/null 2>"$TMP/dkerr" && EXEC_OK=1
EXEC_ERR="$(docker_hatasi)"

# ------------------------------------------------------------ katalog oku ---
# Panel portları, istemci portları ve exporter servisleri KATALOGDAN gelir.
# Sabit yazsaydık katalog büyüdüğünde (13. kayıt izleme aracı olarak sonradan
# eklendi) yeni portlar sessizce test edilmemiş kalırdı.
KAT_RC=0
# py() kullanılmıyor: ayrıştırıcı gövdesi stdin'den (heredoc) geliyor, py ise
# stdin'i /dev/null'a bağlıyor. Zaman aşımını burada elle sarıyoruz.
if [ -n "$TIMEOUT_BIN" ]; then KAT_CMD=("$TIMEOUT_BIN" "$PY_TIMEOUT" python3)
else KAT_CMD=(python3); fi
"${KAT_CMD[@]}" - "$CATALOG" "$TMP" <<'PY' 2>"$TMP/err" || KAT_RC=$?
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

# Katalog ayrıştırıcısının ÇIKIŞ KODU okunuyor: eskiden okunmuyordu ve python
# patladığında dosyalar hiç yaratılmıyor, sonraki döngüler sıfır kez dönüyor,
# "katalogdaki 0 istemci portunun hepsi eşlenmiş" gibi HİÇBİR ŞEY ÖLÇMEYEN
# GEÇTİ satırları basılıyordu.
if [ "$KAT_RC" -ne 0 ]; then
    t_unknown "catalog.json ayrıştırılabiliyor (panel/istemci/exporter listesi)" \
        "python3 katalog okuyucusu çıkış $KAT_RC verdi: $(tr '\n' ' ' < "$TMP/err" | cut -c1-200) — hangi portları sınayacağımızı bilmiyoruz."
    bitir
fi
for f in panels routes exporters engines; do
    [ -f "$TMP/$f.tsv" ] || KAT_RC=1
done
if [ "$KAT_RC" -ne 0 ]; then
    t_unknown "catalog.json ayrıştırılabiliyor (panel/istemci/exporter listesi)" \
        "ayrıştırıcı çalıştı ama liste dosyaları yazılmadı ($TMP) — hangi portları sınayacağımızı bilmiyoruz."
    bitir
fi

# grep -c boş dosyada "0" BASAR ama çıkış kodu 1'dir; `||` ile zincirlemek
# çıktıyı "00" yapardı. Sayıyı değişkene alıp öyle basıyoruz.
satir_sayisi() {
    local n=""
    [ -f "$1" ] && n="$(grep -c '' "$1" 2>/dev/null)"
    case "${n:-0}" in *[!0-9]*|'') n=0 ;; esac
    printf '%s' "$n"
    return 0
}
N_PANEL="$(satir_sayisi "$TMP/panels.tsv")"
N_ROUTE="$(satir_sayisi "$TMP/routes.tsv")"
N_EXP="$(satir_sayisi "$TMP/exporters.tsv")"
N_ENGINE="$(satir_sayisi "$TMP/engines.tsv")"
if [ "$N_PANEL" -eq 0 ]; then
    t_unknown "catalog.json ayrıştırılabiliyor (panel/istemci/exporter listesi)" \
        "katalogda tek bir panel portu yok — panel kontrollerinin hiçbiri sınanamaz, katalog bozuk olabilir."
    bitir
fi
t_info "katalog: $N_PANEL panel portu, $N_ROUTE istemci yolu, $N_EXP exporter, $N_ENGINE motor"

# Döngülü kontrollerin ortak sonucu. ÜÇ bucket var ve sırası önemli:
#   n = 0        → hiç satır okunmadı: hiçbir istek atılmadı, ÖLÇÜLEMEDİ
#   kotu dolu    → ölçtük, yanlış: BAŞARISIZ
#   olcm dolu    → bazı portlarda ölçüm yapılamadı: ÖLÇÜLEMEDİ
# Eskiden yalnız "kotu" bakılıyordu; boş liste ve düşen istekler t_ok'a
# düşüyordu.
rapor_dongu() {  # rapor_dongu <ad> <okunan> <yanlis> <olcemedik> <fail_ipucu>
    local ad="$1" n="$2" kotu="$3" olcm="$4" ipucu="$5"
    if [ "$n" -eq 0 ]; then
        t_unknown "$ad" "listeden tek bir satır okunamadı — döngü hiç dönmedi, HİÇBİR istek atılmadı"
        return 1
    fi
    if [ -n "$kotu" ]; then
        t_fail "$ad" "$ipucu:$kotu${olcm:+ | ayrıca ölçülemeyen portlar:$olcm}"
        return 1
    fi
    if [ -n "$olcm" ]; then
        t_unknown "$ad" "ölçüm yapılamayan portlar:$olcm — kalanlar doğruydu ama bu portlarda iddia SINANMADI"
        return 1
    fi
    t_ok "$ad"
    return 0
}

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
    if dk_port gateway 443/tcp; then
        gwp="$(printf '%s' "$DK_PORT_OUT" | head -1 | sed 's/.*://')"
        if [ -n "$gwp" ] && [ "$gwp" != "$HTTPS_PORT" ]; then
            warn ".env'de GATEWAY_HTTPS_PORT=$HTTPS_PORT yazıyor ama container 443'ü $gwp portundan yayınlıyor — $gwp kullanılıyor (gateway .env değişikliğinden sonra yeniden yaratılmamış olabilir)"
            HTTPS_PORT="$gwp"
        fi
    fi
fi
BAGLANTI="$(tcp_open "$HOST" "$HTTPS_PORT")"
if [ "$BAGLANTI" != "acik" ]; then
    warn "$HOST:$HTTPS_PORT'a bağlanılamadı ($BAGLANTI) — 127.0.0.1 deneniyor."
    HOST="127.0.0.1"
    BAGLANTI="$(tcp_open "$HOST" "$HTTPS_PORT")"
    if [ "$BAGLANTI" = "hata" ]; then
        t_unknown "gateway'in HTTPS portuna bağlanılabiliyor" \
            "TCP sondası (python3 tcp.py) çalışmadı — portun açık olup olmadığını bile ölçemedik."
        bitir
    fi
    if [ "$BAGLANTI" != "acik" ]; then
        t_fail "gateway'in HTTPS portuna bağlanılabiliyor" \
            "gateway ayakta ama HTTPS portuna ($HTTPS_PORT) hiçbir adresten bağlanılamadı — port yayınlanmıyor olabilir: docker port gateway. Erişim denetiminin tamamı bu portun arkasında."
        bitir
    fi
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
kod_bekle "dashboard / parolasız 401 veriyor" 401 "$code"
ILK_CEVAP="$code"

# ÇEREZ SIZINTISI — bu betikteki en önemli kontrol.
# Panel tek-oturum çerezi `add_header ... always` ile bırakılıyor; `always`
# 401 dâhil TÜM durum kodlarını kapsar. Çerez 401 cevabında da gönderiliyorsa
# parolayı bilmeyen biri tek bir GET ile onu alır ve BÜTÜN panelleri parolasız
# açar. Erişim kayıtlarında yalnızca "401" görünür — sızıntı sessizdir.
#
# ÖNCE CEVABIN VARLIĞI SORULUYOR: başlık dosyası boşken grep hiçbir şey
# bulamaz ve "çerez sızmıyor" gibi görünür. Sızıntının YOKLUĞUNU ancak elimizde
# GERÇEK bir cevap varken iddia edebiliriz.
LEAK_COOKIE=""
if olculemedi "$ILK_CEVAP" || [ ! -s "$TMP/hdr" ]; then
    t_unknown "dashboard 401 cevabı panel tek-oturum çerezini SIZDIRMIYOR" \
        "parolasız istekten başlık alınamadı ($(olcum_hatasi "$ILK_CEVAP")) — Set-Cookie var mı yok mu bilmiyoruz"
else
    LEAK_COOKIE="$(grep -i '^set-cookie:' "$TMP/hdr" 2>/dev/null \
                   | sed -n 's/.*dbstack_sso=\([^;]*\).*/\1/p' | head -1)"
    if [ -z "$LEAK_COOKIE" ]; then
        t_ok "dashboard 401 cevabı panel tek-oturum çerezini SIZDIRMIYOR"
    else
        t_fail "dashboard 401 cevabı panel tek-oturum çerezini SIZDIRMIYOR" \
               "parolasız istek Set-Cookie: dbstack_sso=... aldı — bu çerez panel portlarında parolayı devre dışı bırakıyor"
    fi
fi

code="$(REQ_AUTH="$PANEL_USER_V:kesinlikle-yanlis-parola-$$" req GET "$DASH/")"
kod_bekle "dashboard / yanlış parolayla 401 veriyor" 401 "$code"

# Kontrol API'si ve katalog: kimliği doğrulanmamış istek buraya da giremez.
# /api/engines/<id>/connection cevabında veritabanı PAROLALARI var.
code="$(req GET "$DASH/api/status")"
kod_bekle "kontrol API'si /api/status parolasız 401 veriyor" 401 "$code"

code="$(req GET "$DASH/catalog.json")"
kod_bekle "/catalog.json parolasız 401 veriyor (kurulu motor listesi sızmıyor)" 401 "$code"

# Yukarıdaki 401'lerin "gateway tamamen bozuk, her şeye 401 diyor"dan
# ayrılması için doğru parolanın GERÇEKTEN geçtiğini de görmek gerekiyor.
DASH_OK=0
if [ "$HAVE_AUTH" = 0 ]; then
    t_skip "dashboard / doğru parolayla 200 veriyor" "$NO_AUTH_REASON"
else
    code="$(REQ_AUTH="$AUTH" req GET "$DASH/")"
    if kod_bekle "dashboard / doğru parolayla 200 veriyor" 200 "$code" \
        ".env'deki parola ile gateway/.htpasswd ayrışmış olabilir (./install.sh yeniden üretir)"; then
        DASH_OK=1
    fi
fi

# =============================================================================
# 2) PANEL PORTLARI — parolasız girilemiyor
# =============================================================================
heading "2) Panel portları — parola kapısı (katalogdan okundu)"

# Sonda `location = /` gibi özel eşleşmelere denk gelmeyen bir yol kullanıyoruz:
# ClickHouse panelinin kökü rewrite fazında 302 döndürüyor ve access fazına
# (yani parola kontrolüne) hiç gelmiyor. "/" ile ölçseydik o portta 302 görüp
# yanlış yere BAŞARISIZ basardık. Bu yol her panelde `location /`e düşer.
PROBE="/dbstack-e2e-erisim-denetimi-sondasi"
bad=""; olcm=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(req GET "https://$HOSTU:$pport$PROBE")"
    if olculemedi "$code"; then
        # 0 = bağlantı yok, ARAC = istemci çalışmadı. İkisi de "bu portta
        # parola kapısı var mı" sorusunu cevapsız bırakır.
        olcm="$olcm ${pport}(${pname}):${code}"
    elif [ "$code" != "401" ]; then
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
rapor_dongu "panel portlarının hepsi parolasız ve çerezsiz istekte gateway'in 401'ini veriyor ($n port)" \
    "$n" "$bad" "$olcm" \
    "sorunlu portlar"

# Sahte çerez: parolayı devre dışı bırakan tek şey DOĞRU sırdır. Eski bir
# hatada çerez yokluğu ile boş çerez aynı anahtara düşüyor ve tanımsız sır
# durumunda bütün paneller parolasız açılıyordu.
bad=""; olcm=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(REQ_HEADERS="Cookie: dbstack_sso=sahte-cerez-$$-deneme" req GET "https://$HOSTU:$pport$PROBE")"
    if olculemedi "$code"; then olcm="$olcm ${pport}(${pname}):${code}"
    elif [ "$code" != "401" ]; then bad="$bad ${pport}(${pname}):$code"; fi
done < "$TMP/panels.tsv"
rapor_dongu "sahte tek-oturum çerezi hiçbir panelde parolayı atlatmıyor (401)" \
    "$n" "$bad" "$olcm" "sahte çerezi kabul eden portlar"

# Boş çerez ayrı bir durum: nginx'te "çerez yok" ile "çerez boş" aynı değere
# düşer; eşleştirme doğrudan yapılsaydı ve sır tanımsız olsaydı boş çerez
# bütün panelleri açardı. Bu yüzden ayrıca ölçülüyor.
bad=""; olcm=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(REQ_HEADERS="Cookie: dbstack_sso=" req GET "https://$HOSTU:$pport$PROBE")"
    if olculemedi "$code"; then olcm="$olcm ${pport}(${pname}):${code}"
    elif [ "$code" != "401" ]; then bad="$bad ${pport}(${pname}):$code"; fi
done < "$TMP/panels.tsv"
rapor_dongu "BOŞ tek-oturum çerezi hiçbir panelde parolayı atlatmıyor (401)" \
    "$n" "$bad" "$olcm" "boş çerezi kabul eden portlar"

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
    if olculemedi "$code" || [ ! -s "$TMP/hdr" ]; then
        # Cevap alınamadıysa "Set-Cookie yok" DENEMEZ: başlık dosyası boşken
        # grep hiçbir şey bulamaz ve kontrol ürün hakkında değil kendi
        # arızası hakkında konuşmuş olur.
        t_unknown "dashboard girişi tek-oturum çerezini bırakıyor (Set-Cookie: dbstack_sso)" \
            "$(olcum_hatasi "$code")"
        t_unknown "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor" \
            "cevap başlıkları alınamadı — çerezin özellikleri okunamadı"
    else
        SSO_LINE="$(grep -i '^set-cookie:.*dbstack_sso=' "$TMP/hdr" 2>/dev/null | head -1)"
        SSO_COOKIE="$(printf '%s' "$SSO_LINE" | sed -n 's/.*dbstack_sso=\([^;]*\).*/\1/p')"
        if [ -n "$SSO_COOKIE" ]; then
            t_ok "dashboard girişi tek-oturum çerezini bırakıyor (Set-Cookie: dbstack_sso)"
        else
            t_fail "dashboard girişi tek-oturum çerezini bırakıyor (Set-Cookie: dbstack_sso)" \
                   "cevap geldi (HTTP $code) ama Set-Cookie yok — PANEL_SSO_TOKEN .env'de boş olabilir; bu durumda her panelde ikinci kez parola sorulur"
        fi

        # Çerezin ÖZELLİKLERİ de erişim denetiminin parçası: HttpOnly olmayan
        # çerez bir XSS ile çalınır, Secure olmayan çerez düz HTTP'ye sızar,
        # SameSite olmayan çerez çapraz-site isteklerle birlikte gider.
        if [ -z "$SSO_LINE" ]; then
            t_skip "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor" \
                   "Set-Cookie başlığı gelmedi (yukarıdaki satır) — incelenecek çerez yok"
        else
            miss=""
            printf '%s' "$SSO_LINE" | grep -qi 'HttpOnly'     || miss="$miss HttpOnly"
            printf '%s' "$SSO_LINE" | grep -qi 'Secure'       || miss="$miss Secure"
            printf '%s' "$SSO_LINE" | grep -qi 'SameSite=Lax' || miss="$miss SameSite=Lax"
            printf '%s' "$SSO_LINE" | grep -qi 'Path=/'       || miss="$miss Path=/"
            if [ -z "$miss" ]; then
                t_ok "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor"
            else
                t_fail "tek-oturum çerezi HttpOnly + Secure + SameSite=Lax + Path=/ ile bırakılıyor" \
                       "eksik özellik:$miss — satır: $(printf '%s' "$SSO_LINE" | cut -c1-120)"
            fi
        fi
    fi
fi

if [ -z "$SSO_COOKIE" ]; then
    t_skip "dashboard çerezi tüm panel portlarında parolayı devre dışı bırakıyor" \
           "çerez elde edilemedi (dashboard girişi ya da PANEL_SSO_TOKEN eksik)"
else
    bad=""; olcm=""; own=""; n=0
    while IFS=$'\t' read -r pport pname peid; do
        [ -n "$pport" ] || continue
        n=$((n+1))
        code="$(REQ_HEADERS="Cookie: dbstack_sso=$SSO_COOKIE" req GET "https://$HOSTU:$pport$PROBE")"
        # Motor kapalıysa 503 ("pasif" sayfası), açıksa panelin kendi cevabı
        # (404/200/302) gelir; hepsi "gateway parola sormadı" demektir.
        if olculemedi "$code"; then
            olcm="$olcm ${pport}(${pname}):${code}"
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
    rapor_dongu "dashboard çerezi tüm panel portlarında parolayı devre dışı bırakıyor" \
        "$n" "$bad" "$olcm" \
        "hâlâ gateway parolası soran portlar (kullanıcı her panelde .env'den parola aramak zorunda kalır)"
fi

# Sızan çerezin gerçekten işe yarayıp yaramadığı: 1. bölümdeki sızıntı
# kontrolü kırmızıysa, bunun ne kadar ciddi olduğunu burada kanıtlıyoruz.
if [ -z "$LEAK_COOKIE" ]; then
    t_skip "parolasız 401'de sızan çerez panelleri AÇAMIYOR" \
           "401 cevabında çerez sızmadı (ya da sızıp sızmadığı ölçülemedi) — denenecek sızıntı yok"
else
    first_panel="$(head -1 "$TMP/panels.tsv" | cut -f1)"
    if [ -z "$first_panel" ]; then
        t_unknown "parolasız 401'de sızan çerez panelleri AÇAMIYOR" \
            "katalogdan panel portu okunamadı — sızan çerez hiçbir yerde denenmedi"
    else
        code="$(REQ_HEADERS="Cookie: dbstack_sso=$LEAK_COOKIE" req GET "https://$HOSTU:$first_panel$PROBE")"
        kod_bekle "parolasız 401'de sızan çerez panelleri AÇAMIYOR" 401 "$code" \
            "panel :$first_panel sızan çerezi kabul etti — parolayı hiç bilmeyen biri bütün panellere giriyor"
    fi
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
#
# PAROLA YOKSA NE OLUYOR: nginx çapraz-site kapısını rewrite fazında, yani
# auth_basic'ten ÖNCE kapatıyor. Bu yüzden parolasız gönderilen bir istek de
# 403 alır ve kontrol yeşil yazar — ama o zaman ölçülen şey "kapı kapalı"dır,
# "GİRİŞ YAPMIŞ yöneticinin tarayıcısı korunuyor" değildir. Denetimde tam bu
# fark kaydedilmişti; iddianın sınanmadığı hâli artık ekranda görünüyor.
if [ "$HAVE_AUTH" = 0 ]; then
    t_skip "çapraz-site kapısı KİMLİK DOĞRULANMIŞ istekte de kapalı (/api/ ve paneller)" \
           "$NO_AUTH_REASON — aşağıdaki kapı kontrolleri parolasız atılıyor; kapı auth'tan önce çalıştığı için yine 403 görürüz, bu 'yönetici oturumu korunuyor' demek DEĞİLDİR"
else
    t_info "aşağıdaki çapraz-site kontrolleri GEÇERLİ kimlik bilgisiyle atılıyor (iddia: giriş yapmış yöneticinin tarayıcısı da korunuyor)"
fi

API_PROBE="/api/dbstack-e2e-yok-boyle-bir-uc"

code="$(REQ_AUTH="$AUTH" \
        REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: cors\nOrigin: https://kotu-site.example\nContent-Type: application/json' \
        REQ_BODY='{}' req POST "$DASH$API_PROBE")"
API_ADI="/api/ çapraz-siteden gelen POST 403 ile durduruluyor"
if olculemedi "$code"; then
    t_unknown "$API_ADI" "$(olcum_hatasi "$code")"
elif [ "$code" = "403" ] && body_has "durduruldu"; then
    t_ok "$API_ADI"
elif [ "$code" = "403" ]; then
    t_fail "$API_ADI" \
           "403 geldi ama gövde gateway'in açıklama metni değil — cevabı controller vermiş olabilir: $(body_peek)"
else
    t_fail "$API_ADI" \
           "$(why 403 "$code") — çapraz-site kapısı kapalı; kötü niyetli bir sayfa yöneticinin tarayıcısından motor durdurabilir"
fi

# Aynı kapı GET'i de kapatmalı: /api/engines/<id>/connection cevabında
# veritabanı PAROLALARI var. Sadece POST kapatılsaydı, kötü niyetli bir sayfa
# fetch ile parolaları okumayı deneyebilirdi.
CONN_ADI="/api/ çapraz-siteden GET .../connection 403 — bağlantı parolaları sızmıyor"
first_eid="$(head -1 "$TMP/engines.tsv" | cut -f1)"
if [ -z "$first_eid" ]; then
    # Boş motor kimliği ile URL .../engines//connection olur; oraya gelen 403
    # başka bir kuralın eseri olabilir. Ölçmüş sayılmayız.
    t_unknown "$CONN_ADI" "katalogdan motor kimliği okunamadı — istek gerçek bir /connection ucuna atılamadı"
else
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: cors\nOrigin: https://kotu-site.example' \
            req GET "$DASH/api/engines/$first_eid/connection")"
    if olculemedi "$code"; then
        t_unknown "$CONN_ADI" "$(olcum_hatasi "$code")"
    elif [ "$code" = "403" ] && ! body_has "password"; then
        t_ok "$CONN_ADI"
    else
        t_fail "$CONN_ADI" \
               "$(why 403 "$code")$(body_has "password" && printf ' — GÖVDEDE "password" alanı var, parola çapraz-siteye gitti')"
    fi
fi

# Sec-Fetch-* göndermeyen eski tarayıcılar için ikinci kapı: Origin.
code="$(REQ_AUTH="$AUTH" \
        REQ_HEADERS=$'Origin: https://kotu-site.example\nContent-Type: application/json' \
        REQ_BODY='{}' req POST "$DASH$API_PROBE")"
kod_bekle "/api/ Sec-Fetch göndermeyen tarayıcıda yabancı Origin ile POST 403" 403 "$code" \
    "eski tarayıcılarda kalan tek kapı Origin'di"

# Kapı meşru kullanımı kesmemeli: dashboard'un kendi POST'u geçmeli. Aksi
# hâlde "Aktif Et" düğmesi çalışmaz ve kullanıcı ürünü hiç kullanamaz.
SAME_ADI="/api/ same-origin POST kapıdan geçiyor (dashboard düğmeleri çalışıyor)"
if [ "$HAVE_AUTH" = 0 ]; then
    t_skip "$SAME_ADI" "$NO_AUTH_REASON"
else
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS="$(printf 'Sec-Fetch-Site: same-origin\nSec-Fetch-Mode: cors\nOrigin: %s\nContent-Type: application/json' "$DASH")" \
            REQ_BODY='{}' req POST "$DASH$API_PROBE")"
    case "$code" in
        404) t_ok "$SAME_ADI  (controller cevaplıyor: 404 = bilinmeyen uç)" ;;
        503) t_skip "$SAME_ADI" \
                    "kapı geçildi ama controller cevap vermiyor (gateway 503) — uçtan uca doğrulanamadı; controller'ı kontrol edin: docker ps | grep controller" ;;
        403) t_fail "$SAME_ADI" \
                    "kendi sayfamızın isteği de 403 yedi — çapraz-site kapısı fazla dar, dashboard'un hiçbir düğmesi çalışmaz" ;;
        "$ARAC"|0) t_unknown "$SAME_ADI" "$(olcum_hatasi "$code")" ;;
        *)   t_fail "$SAME_ADI" "$(why 404 "$code")" ;;
    esac
fi

# =============================================================================
# 5) PANEL CSRF — isteği KİM başlattı
# =============================================================================
heading "5) Panel CSRF kapısı (yöntem değil, isteğin kimin başlattığı)"

# Bu kontrolün GET ile yapılmasının sebebi somut: kapı eskiden yalnız HTTP
# yöntemine bakıyordu ve "GET okumadır" varsayıyordu. mongo-express 1.0.2'de
# indeks silme GET'tir:
#     GET /db/<vt>/dropIndex/<koleksiyon>?name=...
# Kötü niyetli bir sayfadaki tek bir <img src="..."> etiketi kapıdan geçiyor,
# tarayıcı da panele girmiş yöneticinin kimlik bilgisini isteğe kendisi
# ekliyordu. Canlı container'da üretildi: indeks gerçekten düştü.
# Aşağıdaki yol var olmayan bir veritabanı/koleksiyon adı taşıyor: kapı
# çalışmıyorsa bile hiçbir veri kaybolmaz, yalnız BAŞARISIZ satırı basılır.
CSRF_GET="/db/dbstack_e2e_yok/dropIndex/dbstack_e2e_yok?name=dbstack_e2e_yok"

bad=""; olcm=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: no-cors\nSec-Fetch-Dest: image' \
            req GET "https://$HOSTU:$pport$CSRF_GET")"
    if olculemedi "$code"; then
        olcm="$olcm ${pport}(${pname}):${code}"
    elif [ "$code" != "403" ]; then
        bad="$bad ${pport}(${pname}):$code"
    elif ! body_has "Bu istek durduruldu"; then
        # 403 var ama gateway'in sayfası değil → cevap ARKADAKİ panelden
        # geliyor olabilir, yani istek panele ULAŞMIŞ demektir.
        bad="$bad ${pport}(${pname}):403-ama-gateway-sayfasi-degil"
    fi
done < "$TMP/panels.tsv"
rapor_dongu "çapraz-siteden GET ile gelen indeks-silme isteği hiçbir panele ulaşmıyor (403)" \
    "$n" "$bad" "$olcm" \
    "durdurmayan portlar (<img src> ile tetiklenen silme uçları açık)"

bad=""; olcm=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: cross-site\nSec-Fetch-Mode: no-cors\nContent-Type: application/x-www-form-urlencoded' \
            REQ_BODY='dbstack=e2e' req POST "https://$HOSTU:$pport$PROBE")"
    if olculemedi "$code"; then olcm="$olcm ${pport}(${pname}):${code}"
    elif [ "$code" != "403" ]; then bad="$bad ${pport}(${pname}):$code"; fi
done < "$TMP/panels.tsv"
rapor_dongu "çapraz-siteden gelen gizli form POST'u hiçbir panele ulaşmıyor (403)" \
    "$n" "$bad" "$olcm" "durdurmayan portlar"

# Aynı host'un başka bir portundaki sayfanın ALT-KAYNAK isteği (resim, XHR,
# gizli form): tarayıcı Sec-Fetch-Site: same-site + Mode: no-cors gönderir.
# Bu ikili $panel_from map'inde hiçbir anahtara uymaz → 0 → kapının BİRİNCİ
# katmanı (`if ($panel_from = 0) { return 403; }`) durdurur.
# ADI BİLEREK "birinci katman" diyor: bu kontrol eskiden kademeli kapının orta
# katmanını ölçtüğünü iddia ediyordu, oysa oraya hiç gelmiyordu. Orta katmanın
# kendi kontrolü hemen aşağıda.
bad=""; olcm=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: same-site\nSec-Fetch-Mode: no-cors\nContent-Type: application/x-www-form-urlencoded' \
            REQ_BODY='dbstack=e2e' req POST "https://$HOSTU:$pport$PROBE")"
    if olculemedi "$code"; then olcm="$olcm ${pport}(${pname}):${code}"
    elif [ "$code" != "403" ]; then bad="$bad ${pport}(${pname}):$code"; fi
done < "$TMP/panels.tsv"
rapor_dongu "same-site ALT-KAYNAK POST'u hiçbir panele ulaşmıyor (403 — kapının birinci katmanı)" \
    "$n" "$bad" "$olcm" "durdurmayan portlar"

# ---- KADEMELİ KAPININ ORTA KATMANI -----------------------------------------
# Dashboard (:443) sayfasındaki gizli bir form panele (:8083) POST ederse
# tarayıcı buna "same-site + navigate" der. Bu ikili $panel_from'da 1'e düşer,
# yani BİRİNCİ kapıdan GEÇER; isteği yalnız ikinci kapı durdurur:
#     set $panel_deny "$panel_write$panel_from";  if ($panel_deny = "11") 403
# Origin BİLEREK gönderilmiyor: gönderirsek üçüncü kapı ($csrf_origin_host !=
# $host) devreye girer ve yine 403 alırız — ama o zaman orta katman düşmüş
# olsa bile testi geçerdik. Origin yokken $csrf_origin_host $host'a eşit
# olduğu için üçüncü kapı da açık kalır: 403'ü üretebilecek TEK kural orta
# katmandır. Denetimde bu kademe sahte gateway'de silindi ve betik yine 33/33
# geçti; o boşluğu kapatan kontrol budur.
ORTA_ADI="same-site + NAVIGATE POST'u hiçbir panele ulaşmıyor (403 — kademeli kapının ORTA katmanı)"
if [ "$HAVE_AUTH" = 0 ]; then
    # Parolasızken bu kademe silinse istek auth_basic'e düşer ve 401 gelirdi;
    # 403 beklediğimiz için BAŞARISIZ yazardık — ama sebebi yanlış olurdu ve asıl
    # iddia (giriş yapmış yöneticinin gizli form POST'u durur) sınanmamış
    # kalırdı. Uydurmaktansa atlıyoruz.
    t_skip "$ORTA_ADI" "$NO_AUTH_REASON — bu kademe ancak kimliği doğrulanmış istekle ayırt edilebilir"
else
    bad=""; olcm=""; n=0
    while IFS=$'\t' read -r pport pname peid; do
        [ -n "$pport" ] || continue
        n=$((n+1))
        code="$(REQ_AUTH="$AUTH" \
                REQ_HEADERS=$'Sec-Fetch-Site: same-site\nSec-Fetch-Mode: navigate\nSec-Fetch-Dest: document\nContent-Type: application/x-www-form-urlencoded' \
                REQ_BODY='dbstack=e2e' req POST "https://$HOSTU:$pport$PROBE")"
        if olculemedi "$code"; then
            olcm="$olcm ${pport}(${pname}):${code}"
        elif [ "$code" != "403" ]; then
            bad="$bad ${pport}(${pname}):$code"
        elif ! body_has "Bu istek durduruldu"; then
            # 403 gateway'in kapısından gelmiyorsa istek panele ulaşmış ve
            # cevabı panel vermiş olabilir — kapı ölçülmüş sayılmaz.
            bad="$bad ${pport}(${pname}):403-ama-gateway-sayfasi-degil"
        fi
    done < "$TMP/panels.tsv"
    rapor_dongu "$ORTA_ADI" "$n" "$bad" "$olcm" \
        "geçiren portlar (dashboard sayfasından panele gizli form POST'u ulaşıyor; \$panel_deny=11 kademesi düşmüş)"
fi

# Kapı meşru girişi kesmemeli: dashboard'daki "Panel aç" düğmesi ayrı porta
# gider ve tarayıcı buna "same-site + navigate" der. Bu kontrol kırmızıysa
# koruma değil, ürünün kendisi bozulmuş demektir.
bad=""; olcm=""; n=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    n=$((n+1))
    code="$(REQ_AUTH="$AUTH" \
            REQ_HEADERS=$'Sec-Fetch-Site: same-site\nSec-Fetch-Mode: navigate\nSec-Fetch-Dest: document' \
            req GET "https://$HOSTU:$pport$PROBE")"
    if olculemedi "$code"; then olcm="$olcm ${pport}(${pname}):${code}"
    elif [ "$code" = "403" ]; then bad="$bad ${pport}(${pname}):$code"; fi
done < "$TMP/panels.tsv"
rapor_dongu "dashboard'dan panele giriş gezinmesi (same-site + navigate GET) tüm panellerde geçiyor" \
    "$n" "$bad" "$olcm" "geçmeyen portlar (kullanıcı panellerine giremez)"

# =============================================================================
# 6) METRİK PORTU (:9443)
# =============================================================================
heading "6) Metrik portu (:$METRICS_PORT)"

ps_yenile
METRICS_VAR=0
dk_port gateway "$METRICS_PORT/tcp"; METRICS_RC=$?
[ "$METRICS_RC" -eq 0 ] && METRICS_VAR=1
NO_METRICS_REASON="gateway bu portu yayınlamıyor (docker port gateway $METRICS_PORT/tcp boş) — kurulum onu kapatmış olabilir"
METRICS_ARAC_REASON="docker port gateway $METRICS_PORT/tcp çalışmadı: $(docker_hatasi) — portun yayınlanıp yayınlanmadığını bile ölçemedik"

FIRST_METRIC_PATH="$(head -1 "$TMP/exporters.tsv" | cut -f2)"

if [ "$METRICS_RC" -eq 2 ]; then
    # docker cevap vermedi: "yayınlanmıyor" DEMEK YANLIŞ olurdu.
    t_unknown "metrik portu :$METRICS_PORT parolasız 401 veriyor" "$METRICS_ARAC_REASON"
    t_unknown "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" "$METRICS_ARAC_REASON"
    t_unknown "metrik portu doğru parola ile gerçek metrik döndürüyor" "$METRICS_ARAC_REASON"
elif [ "$METRICS_VAR" -eq 0 ]; then
    # Üç kontrol birden atlanıyor; üçü de ayrı satır olarak raporlanıyor.
    t_skip "metrik portu :$METRICS_PORT parolasız 401 veriyor" "$NO_METRICS_REASON"
    t_skip "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" "$NO_METRICS_REASON"
    t_skip "metrik portu doğru parola ile gerçek metrik döndürüyor" "$NO_METRICS_REASON"
else
    if [ -z "$FIRST_METRIC_PATH" ]; then
        # Sabit bir yola düşmüyoruz: katalogda olmayan bir yol 404 döner ve
        # "parola sorulmadı" gibi görünür — ölçtüğümüz şey başka bir şey olur.
        t_unknown "metrik portu :$METRICS_PORT parolasız 401 veriyor" \
            "katalogda tek bir exporter metrik yolu yok — hangi yolu sınayacağımızı bilmiyoruz"
    else
        code="$(req GET "https://$HOSTU:$METRICS_PORT$FIRST_METRIC_PATH")"
        kod_bekle "metrik portu :$METRICS_PORT $FIRST_METRIC_PATH parolasız 401 veriyor" 401 "$code" \
            "exporter'lar kimlik doğrulaması YAPMAZ; bu port açıksa iç ağdaki herkes metrikleri okur"
    fi

    # Bilinmeyen yol: 9443'te `location /` yok. Parolayla 404 gelmeli — 200
    # gelirse keyfi bir upstream'e proxy açılmış demektir.
    if [ "$HAVE_AUTH" = 0 ]; then
        t_skip "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" "$NO_AUTH_REASON"
        t_skip "metrik portu doğru parola ile gerçek metrik döndürüyor" "$NO_AUTH_REASON"
    else
        code="$(REQ_AUTH="$AUTH" req GET "https://$HOSTU:$METRICS_PORT/metrics/dbstack-e2e-yok")"
        kod_bekle "metrik portu bilinmeyen yolu 404 veriyor (keyfi upstream'e proxy yok)" 404 "$code"

        # Doğru parola ile gerçekten metrik gelmeli; yoksa Prometheus sessizce
        # boş toplar ve panolar boş kalır. Çalışan bir exporter arıyoruz.
        METRIK_ADI="metrik portu doğru parola ile gerçek metrik döndürüyor"
        mrun=""; mpath=""; msorun=0; missing=""
        while IFS=$'\t' read -r msvc mpth meid mbuiltin; do
            [ -n "$msvc" ] || continue
            calisiyor_mu "$msvc"; crc=$?
            case "$crc" in
                0) mrun="$msvc"; mpath="$mpth"; break ;;
                2) msorun=1 ;;
                *) missing="$missing $msvc" ;;
            esac
        done < "$TMP/exporters.tsv"
        if [ -n "$mrun" ] && [ -n "$mpath" ]; then
            code="$(REQ_AUTH="$AUTH" req GET "https://$HOSTU:$METRICS_PORT$mpath")"
            if olculemedi "$code"; then
                t_unknown "$METRIK_ADI ($mpath ← $mrun)" "$(olcum_hatasi "$code")"
            elif [ "$code" = "200" ] && body_has "# HELP"; then
                t_ok "$METRIK_ADI ($mpath ← $mrun)"
            else
                t_fail "$METRIK_ADI ($mpath ← $mrun)" \
                       "$(why 200 "$code") / gövde: $(body_peek)"
            fi
        elif [ -n "$mrun" ]; then
            t_unknown "$METRIK_ADI" "$mrun çalışıyor ama katalogda metrics_path'i boş — hangi yolu isteyeceğimizi bilmiyoruz"
        elif [ "$msorun" = 1 ]; then
            t_unknown "$METRIK_ADI" "docker ps exporter durumunu vermedi ($(docker_hatasi)) — 'exporter kapalı' ile 'docker konuşmuyor' ayırt edilemedi"
        elif [ "$N_EXP" -eq 0 ]; then
            t_unknown "$METRIK_ADI" "katalogda tek bir exporter yok — ölçülecek uç listelenemedi"
        else
            t_skip "$METRIK_ADI" \
                   "hiçbir exporter container'ı çalışmıyor (kapalı:$missing) — kapalı motorda ölçülecek canlı uç yok"
        fi
    fi
fi

# =============================================================================
# 7) PORT YÜZEYİ — host'a ne açılmış?
# =============================================================================
heading "7) Host'a açılan portlar (docker ps ile doğrulanıyor)"

ps_yenile
PROJ="${STACK_PROJECT:-databases-stack}"
LISTE_RC=0
# Boru hattı YOK: `docker ... | sed > dosya` yazılsaydı çıkış kodu sed'den
# gelirdi (sed her zaman 0) ve docker'ın düşmesi "boş liste = temiz yüzey"
# diye okunurdu. Önce docker'ın kendi kodunu alıyoruz, sonra süzüyoruz.
dk ps --filter "label=com.docker.compose.project=$PROJ" --format '{{.Names}}' \
    > "$TMP/cont.raw" 2>"$TMP/dkerr" || LISTE_RC=1
sed '/^$/d' "$TMP/cont.raw" > "$TMP/containers.txt" 2>/dev/null || LISTE_RC=1
if [ "$LISTE_RC" -eq 0 ] && [ ! -s "$TMP/containers.txt" ]; then
    # Etiket filtresi tutmadıysa (elle başlatılmış container'lar) katalogdaki
    # servis adlarına düşüyoruz — sessizce boş liste ile "hepsi temiz" DEMEYİZ.
    warn "compose etiketiyle container bulunamadı (proje: $PROJ) — çalışan tüm container'lara bakılıyor"
    if [ "$PS_RC" -eq 0 ]; then sed '/^$/d' "$TMP/ps.raw" > "$TMP/containers.txt"
    else LISTE_RC=1; fi
fi

YUZEY_ADI="host'a port açan tek container gateway"
if [ "$LISTE_RC" -ne 0 ]; then
    t_unknown "$YUZEY_ADI" \
        "çalışan container'lar listelenemedi (docker ps): $(docker_hatasi) — 'port açan başka container yok' diyemeyiz, hiç bakamadık"
elif [ ! -s "$TMP/containers.txt" ]; then
    t_unknown "$YUZEY_ADI" \
        "docker ps boş liste döndürdü, oysa gateway ayakta olmalıydı — liste güvenilmez, port yüzeyi ölçülmedi"
elif ! grep -qx -- 'gateway' "$TMP/containers.txt"; then
    t_unknown "$YUZEY_ADI" \
        "listede gateway yok — ya gateway koşum sırasında durdu ya da docker eksik liste verdi; her iki hâlde de bu ölçüm geçersiz"
else
    bad=""; olcm=""; ncont=0
    while read -r cname; do
        [ -n "$cname" ] || continue
        [ "$cname" = "gateway" ] && continue
        ncont=$((ncont+1))
        dk_port "$cname"; prc=$?
        case "$prc" in
            0) bad="$bad $cname[$(printf '%s' "$DK_PORT_OUT" | tr '\n' ',' | cut -c1-60)]" ;;
            2) olcm="$olcm $cname" ;;
        esac
    done < "$TMP/containers.txt"
    # ncont = 0 burada meşru: listede gateway'den başka container yok. Listenin
    # kendisini yukarıda doğruladık (docker konuştu, gateway içinde), yani bu
    # "hiç bakamadık" değil "bakacak başka container yok" demek.
    if [ -n "$bad" ]; then
        t_fail "$YUZEY_ADI" \
            "port açan başka container'lar:$bad — bu portlarda gateway'in parolası ve TLS'i YOKTUR${olcm:+ | ayrıca ölçülemeyenler:$olcm}"
    elif [ -n "$olcm" ]; then
        t_unknown "$YUZEY_ADI" \
            "port eşlemesi okunamayan container'lar:$olcm (docker port çalışmadı) — bunların port açıp açmadığını bilmiyoruz"
    else
        t_ok "$YUZEY_ADI (gateway dışında $ncont container denetlendi)"
    fi
fi

# Exporter'lar ayrıca ve adıyla kontrol ediliyor: metrikler kimlik doğrulaması
# olmadan sunulur ve içlerinde sorgu/kullanıcı adları geçer. Tek doğru yol
# 9443'ten, parolalı ve TLS'li geçmektir.
EXP_ADI="çalışan exporter container'larının hiçbiri host'a port açmamış"
checked=0; missing=""; bad=""; olcm=""; nexp=0
while IFS=$'\t' read -r msvc mpth meid mbuiltin; do
    [ -n "$msvc" ] || continue
    nexp=$((nexp+1))
    calisiyor_mu "$msvc"; crc=$?
    case "$crc" in
        1) missing="$missing $msvc"; continue ;;
        2) olcm="$olcm ${msvc}(docker-cevap-yok)"; continue ;;
    esac
    checked=$((checked+1))
    dk_port "$msvc"; prc=$?
    case "$prc" in
        0) bad="$bad ${msvc}[$(printf '%s' "$DK_PORT_OUT" | tr '\n' ',' | cut -c1-40)]" ;;
        2) olcm="$olcm ${msvc}(docker-port-cevap-yok)" ;;
    esac
done < "$TMP/exporters.tsv"
if [ "$nexp" -eq 0 ]; then
    t_unknown "$EXP_ADI" "katalogdan exporter listesi okunamadı — döngü hiç dönmedi"
elif [ -n "$bad" ]; then
    t_fail "$EXP_ADI" "host'a açılmış exporter portları:$bad — metrik uçlarında parola yoktur, iç ağdaki herkes okur"
elif [ -n "$olcm" ]; then
    t_unknown "$EXP_ADI" "durumu ölçülemeyen exporter'lar:$olcm — port açıp açmadıklarını bilmiyoruz"
elif [ "$checked" -eq 0 ]; then
    t_skip "$EXP_ADI" "hiçbir exporter çalışmıyor (kapalı:$missing) — kapalı motorda ölçülecek port yok"
else
    t_ok "çalışan $checked exporter container'ının hiçbiri host'a port açmamış"
fi

# Controller: kontrol düzlemi. Host'a port açmaz; token'ı gateway ekler.
CTL_ADI="controller host'a port açmamış (kontrol düzlemine yalnız gateway üzerinden gidiliyor)"
calisiyor_mu controller; crc=$?
case "$crc" in
    2) t_unknown "$CTL_ADI" "docker ps controller'ın durumunu vermedi: $(docker_hatasi)" ;;
    1) t_skip "$CTL_ADI" "controller container'ı çalışmıyor" ;;
    0)
        dk_port controller; prc=$?
        case "$prc" in
            1) t_ok "$CTL_ADI" ;;
            0) t_fail "$CTL_ADI" "açık portlar: $(printf '%s' "$DK_PORT_OUT" | tr '\n' ' ')" ;;
            *) t_unknown "$CTL_ADI" "docker port controller çalışmadı: $(docker_hatasi)" ;;
        esac
        ;;
esac

# Veritabanı istemci portları GATEWAY üzerinden gelmeli: failover'da arkadaki
# ana kopya değişse bile uygulamanın adresi değişmesin diye. Port host'ta
# yayınlanmış ama nginx onu dinlemiyorsa, istemci "bağlantı kuruldu sonra
# koptu" hatası alır ve sebebini hiç bulamaz.
ROUTES_CONF=""; ROUTES_DURUM="yok"
if [ "$EXEC_OK" != 1 ]; then
    ROUTES_DURUM="arac"
else
    rc_conf=0
    ROUTES_CONF="$(dk exec gateway cat /etc/nginx/stream.d/routes.conf 2>"$TMP/dkerr")" || rc_conf=$?
    if [ "$rc_conf" -ne 0 ] || [ -z "$ROUTES_CONF" ]; then ROUTES_DURUM="yok"; else ROUTES_DURUM="var"; fi
fi

mapped=""; unlistened=""; olcm=""; nroute=0
while IFS=$'\t' read -r rlisten rup reid; do
    [ -n "$rlisten" ] || continue
    nroute=$((nroute+1))
    dk_port gateway "$rlisten/tcp"; prc=$?
    case "$prc" in
        1) mapped="$mapped ${reid}:${rlisten}" ;;
        2) olcm="$olcm ${reid}:${rlisten}" ;;
    esac
    if [ "$ROUTES_DURUM" = "var" ]; then
        printf '%s' "$ROUTES_CONF" | grep -qE "listen[[:space:]]+$rlisten;" \
            || unlistened="$unlistened ${reid}:${rlisten}"
    fi
done < "$TMP/routes.tsv"

rapor_dongu "katalogdaki $nroute istemci portunun hepsi host'ta gateway'e eşlenmiş" \
    "$nroute" "$mapped" "$olcm" \
    "gateway'de eşlemesi olmayan portlar (bu motorlara dışarıdan hiç bağlanılamaz)"

DINLE_ADI="gateway nginx katalogdaki tüm istemci portlarını gerçekten dinliyor (stream routes)"
case "$ROUTES_DURUM" in
    arac)
        t_unknown "$DINLE_ADI" \
            "docker exec gateway çalışmıyor ($EXEC_ERR) — yönlendirme tablosuna hiç bakamadık" ;;
    yok)
        t_skip "$DINLE_ADI" \
            "stream yönlendirme tablosu okunamadı (docker exec gateway cat /etc/nginx/stream.d/routes.conf boş: $(docker_hatasi)) — controller onu henüz yazmamış olabilir" ;;
    var)
        rapor_dongu "$DINLE_ADI" "$nroute" "$unlistened" "" \
            "yönlendirme tablosunda olmayan portlar (port host'ta açık ama arkasında kimse yok; istemci sebepsiz kopma yaşar)" ;;
esac

badp=""; olcm=""; np=0
while IFS=$'\t' read -r pport pname peid; do
    [ -n "$pport" ] || continue
    np=$((np+1))
    dk_port gateway "$pport/tcp"; prc=$?
    case "$prc" in
        1) badp="$badp ${pport}(${pname})" ;;
        2) olcm="$olcm ${pport}(${pname})" ;;
    esac
done < "$TMP/panels.tsv"
rapor_dongu "katalogdaki tüm panel portları host'ta gateway'e eşlenmiş" \
    "$np" "$badp" "$olcm" "eşlemesi olmayan panel portları (katalog ile compose ayrışmış)"

# =============================================================================
# 8) YAYINLANAN PORT GERÇEKTEN GATEWAY'E Mİ GİDİYOR?
# =============================================================================
heading "8) Dışarıdan gelen cevap ile container içinden alınan cevap aynı mı?"

# NEDEN: `docker port` yalnız docker'ın NİYETİNİ gösterir. Host'ta başka bir
# şey (k3s/traefik, ikinci bir nginx, elle kurulmuş bir tünel) aynı portu
# kapmışsa cevap benzer görünür ama gateway'den gelmez — parolasız, TLS'i
# başka bir sertifikayla. Bunu ayırt eden şey sertifikanın PARMAK İZİDİR.
CERT1_ADI="dashboard :$HTTPS_PORT dışarıdan bakıldığında gateway'in kendi sertifikasını sunuyor (araya giren yok)"
CERT2_ADI="panel ve metrik portlarının hepsi aynı gateway sertifikasını sunuyor"
GW_CERT_FP=""; CERT_REASON=""
if [ "$EXEC_OK" != 1 ]; then
    CERT_REASON="docker exec gateway çalışmıyor ($EXEC_ERR) — karşılaştırma için gereken sertifika okunamadı"
elif ! dk exec gateway cat /etc/nginx/certs/server.crt > "$TMP/gw.crt" 2>"$TMP/dkerr"; then
    CERT_REASON="gateway container'ından /etc/nginx/certs/server.crt okunamadı: $(docker_hatasi)"
else
    GW_CERT_FP="$(py "$TMP/pem.py" "$TMP/gw.crt" 2>"$TMP/err")" || GW_CERT_FP=""
    [ "$GW_CERT_FP" = "HATA" ] && GW_CERT_FP=""
    [ -z "$GW_CERT_FP" ] && CERT_REASON="sertifikanın parmak izi hesaplanamadı (python3 pem.py): $(tr '\n' ' ' < "$TMP/err" | cut -c1-140)"
fi

if [ -z "$GW_CERT_FP" ]; then
    # Gateway TLS konuşuyor, yani sertifika VAR; okuyamadıysak karşılaştırma
    # yapılmadı demektir. Bu "ön koşul yok" değil, ÖLÇEMEDİK'tir.
    t_unknown "$CERT1_ADI" "$CERT_REASON"
    t_unknown "$CERT2_ADI" "$CERT_REASON"
else
    fp="$(Q_HOST="$HOST" Q_PORT="$HTTPS_PORT" Q_TIMEOUT="$HTTP_TIMEOUT" py "$TMP/tls.py" 2>"$TMP/err")"; frc=$?
    if [ "$frc" -ne 0 ] || [ -z "$fp" ] || [ "$fp" = "HATA" ]; then
        t_unknown "$CERT1_ADI" \
            "dışarıdan TLS parmak izi alınamadı (tls.py çıkış $frc): $(tr '\n' ' ' < "$TMP/err" | cut -c1-140) — portu gateway mi başkası mı tutuyor, ölçemedik"
    elif [ "$fp" = "$GW_CERT_FP" ]; then
        t_ok "$CERT1_ADI"
    else
        t_fail "$CERT1_ADI" \
               "dışarıdan görülen parmak izi ${fp:0:16}…, gateway'inki ${GW_CERT_FP:0:16}… — bu portu başka bir servis (k3s/traefik, ikinci nginx) kapmış olabilir"
    fi

    # Panel portları ve metrik portu da aynı gateway'de olmalı. Tek tek BAŞARISIZ
    # basmak yerine tutmayanları listeliyoruz; ad hangi portların denendiğini
    # söylüyor, ayrıntı hangisinin tutmadığını.
    # Parmak izleri listede KISALTILIYOR (ilk 16 hane): 12 panel × 64 hane tek
    # satıra sığmaz, sığdırmaya çalışınca da hangi portun tutmadığı kaybolur.
    bad=""; olcm=""; n=0
    while IFS=$'\t' read -r pport pname peid; do
        [ -n "$pport" ] || continue
        n=$((n+1))
        fp="$(Q_HOST="$HOST" Q_PORT="$pport" Q_TIMEOUT="$HTTP_TIMEOUT" py "$TMP/tls.py" 2>/dev/null)"; frc=$?
        if [ "$frc" -ne 0 ] || [ -z "$fp" ] || [ "$fp" = "HATA" ]; then
            olcm="$olcm ${pport}(${pname}):parmak-izi-alinamadi"
        elif [ "$fp" != "$GW_CERT_FP" ]; then
            bad="$bad ${pport}(${pname}):${fp:0:16}…"
        fi
    done < "$TMP/panels.tsv"
    if [ "$METRICS_VAR" -eq 1 ]; then
        n=$((n+1))
        fp="$(Q_HOST="$HOST" Q_PORT="$METRICS_PORT" Q_TIMEOUT="$HTTP_TIMEOUT" py "$TMP/tls.py" 2>/dev/null)"; frc=$?
        if [ "$frc" -ne 0 ] || [ -z "$fp" ] || [ "$fp" = "HATA" ]; then
            olcm="$olcm ${METRICS_PORT}(metrik):parmak-izi-alinamadi"
        elif [ "$fp" != "$GW_CERT_FP" ]; then
            bad="$bad ${METRICS_PORT}(metrik):${fp:0:16}…"
        fi
    fi
    rapor_dongu "$CERT2_ADI ($n port)" "$n" "$bad" "$olcm" \
        "gateway'in parmak izi ${GW_CERT_FP:0:16}…, tutmayan portlar"
fi

# İkinci kanıt: aynı sağlık ucunun cevabı container'ın İÇİNDEN ve dışarıdan
# alınıp karşılaştırılıyor. HTTP portu bilerek seçildi — /health orada
# auth'suz (healthcheck ve izleme buradan bakıyor), yani karşılaştırma
# kimlik doğrulamasından bağımsız.
SAGLIK_ADI="yayınlanan HTTP portundan gelen /health cevabı container içindekiyle birebir aynı"
INSIDE=""; INSIDE_RC=1
if [ "$EXEC_OK" = 1 ]; then
    INSIDE="$(dk exec gateway wget -q -O - -T 5 http://127.0.0.1/health 2>"$TMP/dkerr")"; INSIDE_RC=$?
    INSIDE="$(printf '%s' "$INSIDE" | tr -d '\r\n')"
fi

# Host portunu .env'den DEĞİL docker'dan alıyoruz: karşılaştırmanın anlamı
# "dışarıdaki bu port ile içerideki nginx aynı mı" olduğu için, dışarıdaki
# portun gerçekten o container'a eşlenen port olması gerekiyor.
dk_port gateway 80/tcp; HTTPP_RC=$?
HTTP_HOSTPORT="$(printf '%s' "$DK_PORT_OUT" | head -1 | sed 's/.*://')"

if [ "$EXEC_OK" != 1 ]; then
    t_unknown "$SAGLIK_ADI" "docker exec gateway çalışmıyor ($EXEC_ERR) — içeriden alınacak referans cevap yok"
elif [ "$INSIDE_RC" -ne 0 ] || [ -z "$INSIDE" ]; then
    # Referans cevap alınamadıysa karşılaştırma YAPILMADI. Eskiden bu ATLANDI
    # sayılıyordu; oysa bir şeyi ölçemedik, ön koşulumuz eksik değil.
    t_unknown "$SAGLIK_ADI" \
        "container içinden cevap alınamadı (docker exec gateway wget, çıkış $INSIDE_RC): $(docker_hatasi) — nginx içeride cevap vermiyor olabilir"
elif [ "$HTTPP_RC" -eq 2 ]; then
    t_unknown "$SAGLIK_ADI" "docker port gateway 80/tcp çalışmadı: $(docker_hatasi)"
elif [ "$HTTPP_RC" -ne 0 ] || [ -z "$HTTP_HOSTPORT" ]; then
    t_skip "$SAGLIK_ADI" "gateway 80/tcp'yi yayınlamıyor — karşılaştırılacak dış uç yok"
else
    [ "$HTTP_HOSTPORT" = "$HTTP_PORT" ] \
        || warn ".env'deki GATEWAY_HTTP_PORT=$HTTP_PORT ile gerçek yayın portu $HTTP_HOSTPORT ayrışmış — ölçüm $HTTP_HOSTPORT üzerinden yapılıyor"
    code="$(req GET "http://$HOSTU:$HTTP_HOSTPORT/health")"
    OUTSIDE="$(tr -d '\r\n' < "$TMP/body" 2>/dev/null)"
    if olculemedi "$code"; then
        t_unknown "$SAGLIK_ADI (:$HTTP_HOSTPORT)" "$(olcum_hatasi "$code")"
    elif [ "$code" = "200" ] && [ "$OUTSIDE" = "$INSIDE" ]; then
        t_ok "$SAGLIK_ADI (:$HTTP_HOSTPORT)"
    else
        t_fail "$SAGLIK_ADI (:$HTTP_HOSTPORT)" \
               "$(why 200 "$code"); içeriden '$INSIDE', dışarıdan '$(printf '%s' "$OUTSIDE" | cut -c1-60)' — araya başka bir servis girmiş olabilir"
    fi
fi

# İstemci portları TCP: yayınlanmış port gerçekten bağlantı kabul ediyor mu?
# Yalnız AKTİF motorlar için anlamlı — kapalı motorun portu da açılır (nginx
# dinler) ama arkasında kimse yoktur; onu yukarıdaki routes.conf kontrolü
# ölçüyor, burada bağlantıyı ölçüyoruz.
TCP_ADI="aktif motorların istemci portları dışarıdan TCP bağlantısı kabul ediyor"
active_checked=0; closed=""; olcm=""; nengine=0
while IFS=$'\t' read -r eid prim ename; do
    [ -n "$eid" ] || continue
    nengine=$((nengine+1))
    # primary_of: devirden sonra ana kopya kataloğun varsayılan servisi
    # DEĞİLDİR; sabit ada bakarsak "kapalı" sanıp sessizce atlardık.
    pc="$(primary_of "$eid")"
    if [ -z "$pc" ]; then olcm="$olcm ${eid}(birincil-container-bulunamadi)"; continue; fi
    calisiyor_mu "$pc"; crc=$?
    case "$crc" in
        2) olcm="$olcm ${eid}(docker-cevap-yok)"; continue ;;
        1) continue ;;
    esac
    while IFS=$'\t' read -r rlisten rup reid; do
        [ "$reid" = "$eid" ] || continue
        dk_port gateway "$rlisten/tcp"; prc=$?
        case "$prc" in
            1) closed="$closed ${eid}:${rlisten}(eşleme-yok)"; continue ;;
            2) olcm="$olcm ${eid}:${rlisten}(docker-port-cevap-yok)"; continue ;;
        esac
        hostport="$(printf '%s' "$DK_PORT_OUT" | head -1 | sed 's/.*://')"
        if [ -z "$hostport" ]; then olcm="$olcm ${eid}:${rlisten}(port-ayrıştırılamadı)"; continue; fi
        active_checked=$((active_checked+1))
        case "$(tcp_open "$HOST" "$hostport")" in
            acik)  ;;
            hata)  olcm="$olcm ${eid}:${hostport}(TCP-sondası-çalışmadı)" ;;
            *)     closed="$closed ${eid}:${hostport}" ;;
        esac
    done < "$TMP/routes.tsv"
done < "$TMP/engines.tsv"

# Sıra önemli: "hiç aktif motor yok" ile "aktif motor var ama portu kapalı"
# ayrı şeyler. Yalnız sayaca baksaydık, eşlemesi hiç olmayan bir motor
# ATLANDI satırı üretirdi — yani gerçek bir arıza "ön koşul yok" gibi görünürdü.
if [ "$nengine" -eq 0 ]; then
    t_unknown "$TCP_ADI" "katalogdan motor listesi okunamadı — döngü hiç dönmedi"
elif [ -n "$closed" ]; then
    t_fail "$TCP_ADI" "sorunlu portlar:$closed — motor çalışıyor ama uygulamalar bağlanamaz${olcm:+ | ayrıca ölçülemeyenler:$olcm}"
elif [ -n "$olcm" ]; then
    t_unknown "$TCP_ADI" "ölçüm yapılamayanlar:$olcm"
elif [ "$active_checked" = 0 ]; then
    t_skip "$TCP_ADI" \
           "hiçbir motor aktif değil — dışarıdan denenecek istemci portu yok (./stack.sh list ile durumu görebilirsiniz)"
else
    t_ok "aktif motorların $active_checked istemci portu dışarıdan TCP bağlantısı kabul ediyor"
fi

# =============================================================================
# SONUÇ — sayaçlar, çıkış kodu ve "hiçbir kontrol çalışmadı" uyarısı lib.sh'te
# =============================================================================
e2e_finish; exit $?
