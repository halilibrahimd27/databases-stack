#!/bin/bash
# =============================================================================
# databases-stack — YEDEĞİN İÇİNE BAKMA (geri yüklemeden)
# =============================================================================
#   ./scripts/backup-inspect.sh <motor> <dosya>
#
# NEDEN VAR:
# "Yedek var" cümlesi iki soruyu cevaplar sanılır ama yalnız birini cevaplar:
# dosya duruyor mu. İkinci soru — İÇİNDE NE VAR — bugüne kadar ancak geri
# yükleyerek cevaplanabiliyordu. Oysa insanın sabah 09:00'da sorduğu şey
# genelde şu: "dün gece silinen 'siparisler' tablosu bu yedekte VAR MI?"
# Bunun için üretimi riske atıp geri yükleme yapmak zorunda kalmak, sorunun
# kendisini sormayı caydırıyor.
#
# Bu betik dosyayı AÇMADAN, yalnız AKITARAK okur: gerekiyorsa şifreyi çözer,
# gzip'i açar ve içindeki YAPIYI çıkarır. Diske hiçbir şey yazmaz, üretime
# dokunmaz, veritabanı açmaz.
#
# ⚠ EN ÖNEMLİ KURAL — SATIR VERİSİ ASLA DÖNMEZ:
# Bu araç tablo/nesne ADLARINI ve SAYILARINI döndürür; satır İÇERİĞİNİ
# döndürmez. Sebebi teknik değil, sonuç odaklı: paneli açabilen herkesin
# müşteri satırlarını tarayıcıda okuyabildiği bir "yedek görüntüleyici",
# yedeklemenin korumaya çalıştığı şeyi sızdıran bir kapıya dönüşür. Şifreli
# yedek özelliğini yazıp sonra içeriğini panelde göstermek kendi kendini
# iptal etmek olurdu. Sorulan soru "hangi tablolar var, kaç satır" — o
# soruya satır göstermeden cevap veriyoruz.
#
# ÇIKIŞ KODLARI (kapsam dışı ile hata KARIŞMASIN diye ayrı):
#   0  incelendi (son satır TEK SATIR JSON)
#   1  hata (dosya bozuk, şifre çözülemedi, gzip açılamadı)
#   2  KAPSAM DIŞI — bu motorun yedek biçimi okunabilir değil, ya da
#      kullanım hatası
#   3  ÖLÇÜLEMEDİ — dosya yok/okunamıyor, gerekli araç yok
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
load_env

KOD_HATA=1
KOD_KAPSAM=2
KOD_OLCUM_YOK=3

# Okunacak en çok bayt (açılmış hâliyle). Sınırsız okumak, 40 GB'lık bir
# dump'ta paneli dakikalarca bekletir ve sunucunun I/O'sunu yer. Sınıra
# gelindiğinde JSON'da "kesildi": true yazar — sessizce eksik cevap YOK.
UST_SINIR="${INSPECT_MAX_BYTES:-268435456}"        # 256 MB
# En çok kaç nesne listelenir. Aşılırsa yine "kesildi" yazılır.
UST_NESNE="${INSPECT_MAX_OBJECTS:-500}"

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"

js() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "${1-}"; }

# ---------------------------------------------------------------- kapsam ---
# Okunabilir biçim = metin tabanlı ve yapısı akıtılarak çıkarılabilir olan.
# Diğerleri için SEBEP yazıyoruz: "desteklenmiyor" tek başına, kullanıcıya
# bunun bir eksiklik mi biçimin doğası mı olduğunu bırakmaz.
kapsam_notu() {
    case "$1" in
        mongodb)   printf '%s' "arşiv biçimi ikili (mongodump --archive); yapısı ancak mongorestore --dryRun ile okunur — bu turda yapılmadı" ;;
        redis)     printf '%s' "RDB ikili bir anlık görüntüdür; anahtar listesi ancak yükleyerek çıkar" ;;
        mssql)     printf '%s' "native .bak ikili biçimdir; içeriği yalnız SQL Server okuyabilir" ;;
        neo4j)     printf '%s' "neo4j-admin dump ikili biçimdir" ;;
        cassandra|elasticsearch|minio)
                   printf '%s' "dosya bir arşiv (tar); veri dosyaları motorun kendi ikili biçiminde" ;;
        *)         printf '%s' "bu motorun yedek biçimi metin tabanlı değil" ;;
    esac
}

okunabilir_mi() {
    case "$1" in postgresql|mariadb|clickhouse|rabbitmq) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ akış ---
# Şifreli (.gz.enc) ve düz (.gz) dosyaları AYNI şekilde okuyan tek yol.
# common.sh'taki oku_akis ile aynı sözleşme; burada tekrar yazmıyoruz ki
# şifreleme kuralları tek yerde kalsın.
akit() {   # akit <dosya>
    case "$1" in
        *.enc)
            [ -n "${BACKUP_ENCRYPT_KEY:-}" ] || return 3
            command -v openssl >/dev/null 2>&1 || return 3
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
                -pass "pass:$BACKUP_ENCRYPT_KEY" -in "$1" 2>/dev/null | gzip -dc 2>/dev/null
            ;;
        *.gz)  gzip -dc -- "$1" 2>/dev/null ;;
        *)     cat -- "$1" ;;
    esac
}

MOTOR="${1:-}"
DOSYA="${2:-}"

if [ -z "$MOTOR" ] || [ -z "$DOSYA" ]; then
    cat <<EOF

Yedeğin içine bakma — databases-stack

  ./scripts/backup-inspect.sh <motor> <dosya>

  Yedeği GERİ YÜKLEMEDEN içindeki YAPIYI çıkarır: hangi tablolar var, kaç
  satır, hangi görünüm/rutin/indeks tanımlı. Dosyayı yalnız akıtarak okur;
  diske bir şey yazmaz, veritabanı açmaz, üretime dokunmaz.

  SATIR VERİSİ DÖNDÜRMEZ — yalnız adlar ve sayılar. Paneli açabilen herkesin
  müşteri satırlarını okuyabildiği bir görüntüleyici, yedeklemenin korumaya
  çalıştığı şeyi sızdırırdı.

  Okunabilen motorlar: postgresql · mariadb · clickhouse · rabbitmq
  Diğerlerinde sebep yazılıdır: ./scripts/backup-inspect.sh <motor> x

  Çıkış: 0 incelendi · 1 hata · 2 kapsam dışı · 3 ölçülemedi

EOF
    exit "$KOD_KAPSAM"
fi

if ! okunabilir_mi "$MOTOR"; then
    printf '{"engine":%s,"ok":false,"kapsam":false,"detail":%s}\n' \
        "$(js "$MOTOR")" "$(js "$(kapsam_notu "$MOTOR")")"
    exit "$KOD_KAPSAM"
fi

# Dosya yolu: yalnız yedek dizininin ALTINDA olabilir. Bu kontrol burada da
# duruyor (controller'da da var) çünkü betik komut satırından da çağrılıyor
# ve "../../etc/passwd" gibi bir yol buraya kadar gelmemeli.
TAM="$DOSYA"
[ -f "$TAM" ] || TAM="$BACKUP_DIR/$MOTOR/full/$DOSYA"
[ -f "$TAM" ] || TAM="$(find "$BACKUP_DIR/$MOTOR" -maxdepth 2 -name "$(basename -- "$DOSYA")" -type f 2>/dev/null | head -1)"
if [ -z "$TAM" ] || [ ! -f "$TAM" ]; then
    printf '{"engine":%s,"ok":false,"detail":%s}\n' "$(js "$MOTOR")" \
        "$(js "yedek dosyası bulunamadı: $DOSYA")"
    exit "$KOD_OLCUM_YOK"
fi
GERCEK="$(realpath -- "$TAM" 2>/dev/null || printf '%s' "$TAM")"
KOK="$(realpath -- "$BACKUP_DIR" 2>/dev/null || printf '%s' "$BACKUP_DIR")"
case "$GERCEK" in
    "$KOK"/*) ;;
    *) printf '{"engine":%s,"ok":false,"detail":%s}\n' "$(js "$MOTOR")" \
           "$(js "dosya yedek dizininin dışında: $GERCEK")"
       exit "$KOD_KAPSAM" ;;
esac

BOYUT="$(stat -c %s "$GERCEK" 2>/dev/null || echo 0)"
SIFRELI=false
case "$GERCEK" in *.enc) SIFRELI=true ;; esac

if [ "$SIFRELI" = true ] && [ -z "${BACKUP_ENCRYPT_KEY:-}" ]; then
    printf '{"engine":%s,"file":%s,"ok":false,"encrypted":true,"detail":%s}\n' \
        "$(js "$MOTOR")" "$(js "$(basename -- "$GERCEK")")" \
        "$(js ".env'de BACKUP_ENCRYPT_KEY yok — şifreli yedeğin içi okunamaz")"
    exit "$KOD_OLCUM_YOK"
fi

# =============================================================================
# ÇÖZÜMLEYİCİ
# =============================================================================
# Ayrıştırma python3'te: SQL dökümünde tablo adı tırnaklı/şemalı/ters tırnaklı
# gelebiliyor ve bunu awk ile doğru yapmanın güvenli yolu yok. Yanlış
# ayrıştırma burada sessiz bir yanlış cevap üretir ("tablo yok" der), ki bu
# aracın varlık sebebinin tam tersi.
# PROGRAM GEÇİCİ DOSYAYA YAZILIYOR, heredoc ile stdin'e DEĞİL.
# `python3 - <<EOF` yazıldığında program stdin'den okunur ve VERİ BORUSU
# KAYBOLUR: süzgeç sıfır bayt görür, üstelik hata da vermez — "yedeğin
# içinde hiçbir şey yok" diye sessiz ve YANLIŞ bir cevap üretir. Bu hata
# ash.sh yazılırken de yapıldı; selftest artık ikisini birden bekliyor.
PROG="$(mktemp "${TMPDIR:-/tmp}/bi-cozumle.XXXXXX")" || exit "$KOD_OLCUM_YOK"
trap 'rm -f "$PROG"' EXIT
cat > "$PROG" <<'PY'
import json, os, re, sys

motor = os.environ["INS_MOTOR"]
sinir = int(os.environ["INS_SINIR"])
azami = int(os.environ["INS_NESNE"])

# --- desenler ---------------------------------------------------------------
# Tablo ADI çeşitli biçimlerde gelir: "sema"."tablo" · `tablo` · [tablo] · tablo
AD = r'[`"\[]?([A-Za-z0-9_$À-￿]+)[`"\]]?'
CREATE_T = re.compile(r'^\s*CREATE\s+(?:UNLOGGED\s+|TEMP(?:ORARY)?\s+)?TABLE\s+'
                      r'(?:IF\s+NOT\s+EXISTS\s+)?(?:' + AD + r'\s*\.\s*)?' + AD,
                      re.I)
CREATE_V = re.compile(r'^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?VIEW\s+'
                      r'(?:IF\s+NOT\s+EXISTS\s+)?(?:' + AD + r'\s*\.\s*)?' + AD, re.I)
CREATE_I = re.compile(r'^\s*CREATE\s+(?:UNIQUE\s+)?INDEX\s+', re.I)
CREATE_R = re.compile(r'^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:DEFINER=\S+\s+)?'
                      r'(FUNCTION|PROCEDURE|TRIGGER)\s+', re.I)
INSERT = re.compile(r'^\s*INSERT\s+INTO\s+(?:' + AD + r'\s*\.\s*)?' + AD, re.I)
# Bir KAYIT, satır başında ya da "),"den sonra gelen "(" ile başlar. Tek
# satırlık ve çok satırlık INSERT'in ikisinde de aynı desen işler.
# "VALUES" da bir başlangıçtır: tek satırlık INSERT'te ilk kayıt ondan sonra
# gelir ve yalnız "^" ile "),", o ilk kaydı KAÇIRIR (5 kayıt 4 sayılıyordu).
TUPLE = re.compile(r'(?:^|\),|VALUES)\s*\(', re.I)
COPY = re.compile(r'^\s*COPY\s+(?:' + AD + r'\s*\.\s*)?' + AD, re.I)

tablolar = {}       # ad -> {"satir": n, "satir_kesin": bool}
gorunum = []
rutin = 0
indeks = 0
kesildi = False
okunan = 0
kopya_hedef = None   # PostgreSQL COPY bloğu içindeyken tablo adı
insert_hedef = None  # çok satırlı INSERT bloğu içindeyken tablo adı


def ad_al(m):
    sema, tab = m.group(1), m.group(2)
    if tab is None:
        sema, tab = None, sema
    return ("%s.%s" % (sema, tab)) if sema else tab


def tablo(ad):
    return tablolar.setdefault(ad, {"satir": 0, "satir_kesin": True})


ham = sys.stdin.buffer
for satir_b in ham:
    okunan += len(satir_b)
    if okunan > sinir:
        kesildi = True
        break
    try:
        satir = satir_b.decode("utf-8", "replace")
    except Exception:
        continue

    # PostgreSQL COPY bloğu: veri satırları burada akar. İÇERİĞİNE BAKMIYORUZ,
    # yalnız SAYIYORUZ — bu aracın kuralı "adlar ve sayılar, satır yok".
    if kopya_hedef is not None:
        if satir.startswith("\\."):
            kopya_hedef = None
        else:
            tablo(kopya_hedef)["satir"] += 1
        continue

    m = COPY.match(satir)
    if m and " FROM " in satir.upper():
        kopya_hedef = ad_al(m)
        tablo(kopya_hedef)
        continue

    m = CREATE_T.match(satir)
    if m:
        tablo(ad_al(m))
        continue
    m = CREATE_V.match(satir)
    if m:
        if len(gorunum) < azami:
            gorunum.append(ad_al(m))
        continue
    if CREATE_I.match(satir):
        indeks += 1
        continue
    if CREATE_R.match(satir):
        rutin += 1
        continue
    # ÇOK SATIRLI INSERT. mariadb-dump şöyle yazar:
    #     INSERT INTO `t` VALUES
    #     (1,'a'),
    #     (2,'b');
    # Yani kayıtlar SONRAKİ satırlardadır. Satır satır sayan ilk sürüm
    # bunları hiç görmüyor ve her tabloya "1-2 satır" diyordu — 500 satırlık
    # bir tabloya "2 satır" demek, yanlış bir sayıyı sayı gibi sunmaktır ve
    # hiç sayı vermemekten kötüdür. Bu yüzden INSERT bloğu içindeyken de
    # sayıyoruz; blok, satırı ';' ile biten ifadede kapanır.
    if insert_hedef is not None:
        t = tablo(insert_hedef)
        t["satir"] += len(TUPLE.findall(satir))
        t["satir_kesin"] = False
        if satir.rstrip().endswith(";"):
            insert_hedef = None
        continue

    m = INSERT.match(satir)
    if m:
        ad = ad_al(m)
        t = tablo(ad)
        # Çok satırlı INSERT: "),(" sayısı satır sayısını verir. Tek satırlık
        # INSERT'te de bir tane sayılır. Bu bir TAHMİNDİR ve öyle de yazılıyor:
        # kesin sayı ancak yükleyerek bulunur, ve öyle olduğunu söylemeyen bir
        # sayı, kullanıcıyı yanlış bir kesinliğe ikna eder.
        t["satir"] += len(TUPLE.findall(satir))
        t["satir_kesin"] = False
        if not satir.rstrip().endswith(";"):
            insert_hedef = ad          # kayıtlar sonraki satırlarda sürüyor

if len(tablolar) > azami:
    kesildi = True

siralı = sorted(tablolar.items(), key=lambda kv: (-kv[1]["satir"], kv[0]))[:azami]
cikti = {
    "engine": motor,
    "file": os.environ["INS_DOSYA"],
    "bytes": int(os.environ["INS_BOYUT"]),
    "encrypted": os.environ["INS_SIFRELI"] == "true",
    "ok": True,
    "kapsam": True,
    "tablo_sayisi": len(tablolar),
    "gorunum_sayisi": len(gorunum),
    "rutin_sayisi": rutin,
    "indeks_sayisi": indeks,
    "tablolar": [{"ad": a, "satir": v["satir"], "satir_kesin": v["satir_kesin"]}
                 for a, v in siralı],
    "gorunumler": gorunum[:azami],
    "kesildi": kesildi,
    "okunan_bayt": okunan,
}
# Boş bir dump ile OKUNAMAYAN bir dump aynı şey değil: ilki gerçekten boştur,
# ikincisi ölçüm yokluğudur. Hiç nesne yoksa ve hiç bayt okunmadıysa bunu
# "boş yedek" diye sunmak sahte bir güvence olurdu.
if okunan == 0:
    cikti["ok"] = False
    cikti["detail"] = ("dosyadan tek bayt okunamadı — bozuk, boş ya da "
                       "şifresi çözülemiyor olabilir")
elif not tablolar and not gorunum and not rutin:
    cikti["detail"] = ("okundu ama tanınan hiçbir yapı bulunamadı "
                       "(%d bayt) — biçim beklenenden farklı olabilir" % okunan)
else:
    cikti["detail"] = "%d tablo, %d görünüm, %d rutin, %d indeks" % (
        len(tablolar), len(gorunum), rutin, indeks)
sys.stdout.write(json.dumps(cikti, ensure_ascii=False) + "\n")
PY
akit "$GERCEK" | INS_MOTOR="$MOTOR" INS_DOSYA="$(basename -- "$GERCEK")" \
    INS_BOYUT="$BOYUT" INS_SIFRELI="$SIFRELI" INS_SINIR="$UST_SINIR" \
    INS_NESNE="$UST_NESNE" python3 "$PROG"
RC=${PIPESTATUS[1]}
exit "${RC:-0}"
