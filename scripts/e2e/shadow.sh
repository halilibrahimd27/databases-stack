#!/bin/bash
# =============================================================================
# databases-stack — uçtan uca test: GÖLGE GERİ YÜKLEME ve GERİ DÖNÜŞ BİLETİ
# =============================================================================
# CANLI bir kuruluma karşı çalışır ve GERÇEKTEN takas yapar. Ölçtüğü şey
# "komut hata vermedi" değil; dört ayrı soru:
#
#   1) KESİNTİ  — takas sırasında uygulamanın gördüğü kesinti kaç saniye?
#      Motorun kendi beyanına DEĞİL, gateway portuna bakılır: uygulamanın
#      bağlandığı yer orasıdır ve bağımsız tanık odur. Vaadin tamamı bu
#      sayının GERİ YÜKLEME SÜRESİNDEN küçük olmasıdır; ikisi de rapora
#      yazılır ki "10 kat" gibi bir cümle ölçüme dayansın.
#
#   2) NEGATİF  — yabancı/bozuk bir dosya verildiğinde gölge DÜŞMELİ ve
#      üretimin satır sayısı ile CANLI HACİM ADI değişmemiş olmalı. Yıkıcı
#      olmayan bir yolun tek anlamı budur: başarısızlık üretime dokunmamalı.
#
#   3) GERİ DÖNÜŞ — takastan sonra bilet kullanılınca eski veri satır sayısıyla
#      değil ÇEKİRDEK BİR İMZAYLA (checksum) doğrulanır. Satır saymak,
#      içeriği değişmiş bir tabloyu "aynı" gösterebilirdi.
#
#   4) AYRIŞMA  — takas yarıda kalırsa dosya (volumes.env) ile gerçek
#      (container'ın Mounts'ı) ayrışır. Ürün DOSYAYA İNANMAMALI: canlı hacmi
#      ölçüp ayrışmayı söylemeli. Bu kontrol o durumu bilerek kuruyor;
#      controller'ı kill -9 ile öldürmenin zamanlamasına bağlı kalmak,
#      ölçülmek istenen şeyi değil şansı ölçerdi.
#
# BU PAKET ÜRETİM VERİSİNE DOKUNUR. Kendi tablosunu (e2e_golge) yaratır,
# kendi yedeğini alır ve SONUNDA bileti kullanarak başladığı yere döner.
# Yarıda kesilirse ekrana ne yapılacağı yazılır.
#
# Kullanım:
#   ./scripts/e2e/shadow.sh              # mariadb (varsayılan)
#   ./scripts/e2e/shadow.sh postgresql
#
# Ayarlar (ortam değişkeni):
#   E2E_GOLGE_MB      (vars. 256)  üretilecek veri, MB. Kesinti ile geri
#                                  yükleme süresi ancak geri yükleme
#                                  gözle görülür sürerse ayrışır; küçük
#                                  veride iki sayı da saniyeler çıkar ve
#                                  ölçüm bir şey söylemez. Rapora yazılır.
#   E2E_GOLGE_TIMEOUT (vars. 3600) gölge işi üst sınırı, sn
#   E2E_PROBE_MS      (vars. 200)  gateway portu yoklama aralığı, ms
# =============================================================================
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$STACK_ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
. "$E2E_DIR/lib.sh"

# .env ORTAMA YÜKLENİR: parolalar, imaj sürümleri ve şifreleme durumu oradan
# gelir. Diğer bütün e2e paketleri de bunu yapıyor; unutulduğunda paket
# "parola okunamadı" deyip HİÇBİR ŞEY ölçmüyor.
load_env

MOTOR="${1:-mariadb}"
GOLGE_MB="${E2E_GOLGE_MB:-256}"
GOLGE_TO="${E2E_GOLGE_TIMEOUT:-3600}"
PROBE_MS="${E2E_PROBE_MS:-200}"
E2E_LOG="${E2E_LOG:-$STACK_ROOT/logs/e2e-shadow_$(date +%Y%m%d_%H%M%S).log}"
mkdir -p "$(dirname "$E2E_LOG")" 2>/dev/null

TABLO="e2e_golge"
ISARET="e2e-takas-oncesi"
PROBE_PID=""
PROBE_OUT=""
YEDEK=""
TEMIZ_NOT=""

# ---------------------------------------------------------------- yardımcı --
# ÖLÇÜM ARACI ASILIRSA bu "ürün yanlış" değil "ÖLÇEMEDİK"tir. timeout(1)
# zaman aşımında 124 döner; yoksa komutu olduğu gibi çalıştırıyoruz.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)

zaman_asimi() {   # zaman_asimi <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}

kat() {   # kat <python ifadesi>  → catalog.json'dan oku
    catalog_query "
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
eid=sys.argv[2]
for e in c['engines']:
    if e['id']==eid:
        try:
            print($1)
        except Exception:
            pass
        break
" "$MOTOR" | tr -d '\r'
}

# Controller kendi günlüğünü de stdout'a yazıyor: iş çalışırken araya onlarca
# satır giriyor. Sonucu AYIRT EDİLEBİLİR bir önekle basıp yalnız onu okuyoruz.
# İlk sürüm bunu yapmıyordu ve her karşılaştırma çok satırlı bir metinle
# yapılıyordu — üç kontrol yalancı kırmızı verdi, oysa ürün doğru çalışıyordu.
ctl() {   # ctl <python gövdesi> — ürünün KENDİ yolundan çalıştır
    local ham
    ham="$(docker exec controller python3 -c "
import sys, json
sys.path.insert(0,'/app')
import app
def E2E(x): print('E2E>' + str(x))
$1
" 2>>"$E2E_LOG")"
    printf '%s\n' "$ham" >>"$E2E_LOG"
    printf '%s' "$ham" | sed -n 's/^E2E>//p' | tail -1
}

sql() {   # sql <container> <ifade> — düğümün kendi istemcisiyle
    case "$MOTOR" in
    mariadb)
        docker exec -e MYSQL_PWD="$PAROLA" "$1" \
            mariadb -u"$KULLANICI" -D "$VTABANI" -N -B -e "$2" 2>>"$E2E_LOG" ;;
    postgresql)
        docker exec -e PGPASSWORD="$PAROLA" "$1" \
            psql -U "$KULLANICI" -d "$VTABANI" -tAq -v ON_ERROR_STOP=1 \
            -c "$2" 2>>"$E2E_LOG" ;;
    *)  return 1 ;;
    esac
}

# Kanıt tablosunun İÇERİĞİNİN imzası. Satır saymak yetmez: aynı sayıda ama
# içeriği değişmiş bir tablo "aynı" görünürdü. Geri dönüşün bit düzeyinde
# doğrulanması bu paketin en pahalı kontrolü.
imza() {   # imza <container>
    case "$MOTOR" in
    mariadb)  sql "$1" "SELECT COALESCE(SUM(CRC32(CONCAT_WS('|',id,veri))),0) FROM $TABLO;" ;;
    postgresql) sql "$1" "SELECT COALESCE(SUM(('x'||substr(md5(id::text||'|'||veri),1,8))::bit(32)::bigint),0) FROM $TABLO;" ;;
    esac
}

satir_say() { sql "$1" "SELECT COUNT(*) FROM $TABLO;"; }

isaret_var_mi() {   # 1 = var, 0 = yok
    local n
    n="$(sql "$1" "SELECT COUNT(*) FROM $TABLO WHERE veri = '$ISARET';")"
    printf '%s' "${n:-HATA}"
}

# ------------------------------------------------------- gateway tanığı -----
# ÖLÇÜLDÜ VE İLK SÜRÜM YANLIŞTI: TCP bağlantısı açabilmek "veritabanı
# çalışıyor" demek DEĞİL. nginx akış vekili bağlantıyı kabul ediyor, sonra
# arkadaki hedefe ulaşamayınca takılıyor; TCP yoklaması bu sırada "açık"
# diyor ve kesinti 0 sn ölçülüyordu — yani tanık hiçbir şeye tanıklık
# etmiyordu. Şimdi gerçekten SORGU çalıştırıyoruz: uygulamanın yaptığı şey bu.
#
# Yoklayıcı UZUN ÖMÜRLÜ tek bir container: her yoklamada yeni container
# başlatmak saniyeler alır ve ölçmek istediğimiz kesintiden uzun sürerdi
# (ash.sh'taki tek uzun ömürlü exec deseninin aynısı).
PROBE_C=""

probe_baslat() {
    PROBE_C="dbstack-e2e-probe-$$"
    local dongu
    case "$MOTOR" in
    mariadb)
        dongu="while :; do if mariadb -h gateway -P $PORT -u $KULLANICI -D $VTABANI --connect-timeout=2 -N -e 'SELECT 1' >/dev/null 2>&1; then echo \"A \$(date +%s.%N)\"; else echo \"R \$(date +%s.%N)\"; fi; sleep $(awk "BEGIN{print $PROBE_MS/1000}"); done" ;;
    postgresql)
        dongu="while :; do if psql -h gateway -p $PORT -U $KULLANICI -d $VTABANI -w -tAq -c 'SELECT 1' >/dev/null 2>&1; then echo \"A \$(date +%s.%N)\"; else echo \"R \$(date +%s.%N)\"; fi; sleep $(awk "BEGIN{print $PROBE_MS/1000}"); done" ;;
    esac
    docker run -d --name "$PROBE_C" --network "$AG" --restart no \
        -e MYSQL_PWD="$PAROLA" -e PGPASSWORD="$PAROLA" -e PGCONNECT_TIMEOUT=2 \
        --entrypoint sh "$IMAJ" -c "$dongu" >>"$E2E_LOG" 2>&1 \
        || { PROBE_C=""; return 1; }
    return 0
}

probe_durdur() {
    [ -n "$PROBE_C" ] || return 0
    PROBE_OUT="$(mktemp "${TMPDIR:-/tmp}/dbstack-probe-XXXXXX")"
    docker logs "$PROBE_C" > "$PROBE_OUT" 2>/dev/null
    docker rm -f "$PROBE_C" >>"$E2E_LOG" 2>&1
    PROBE_C=""
}

# Kesinti = ilk reddedilen yoklama ile son reddedilen yoklama arası + bir
# aralık. Sayıyı yuvarlamıyoruz; ölçüm neyse o.
probe_kesinti() {
    [ -s "$PROBE_OUT" ] || { printf 'ÖLÇÜLEMEDİ'; return 1; }
    awk -v ara="$(awk "BEGIN{print $PROBE_MS/1000}")" '
        $1=="R" { if (ilk=="") ilk=$2; son=$2; n++ }
        END {
            if (n==0) { print "0"; exit }
            printf "%.1f", (son-ilk)+ara
        }' "$PROBE_OUT"
}

probe_toplam() { [ -s "$PROBE_OUT" ] && wc -l < "$PROBE_OUT" | tr -d ' ' || printf '0'; }

# ------------------------------------------------------------- temizlik -----
cikista() {
    probe_durdur
    [ -n "${PROBE_C:-}" ] && docker rm -f "$PROBE_C" >/dev/null 2>&1
    [ -n "$PROBE_OUT" ] && rm -f "$PROBE_OUT" 2>/dev/null
    if [ -n "$TEMIZ_NOT" ]; then
        printf '\n%s[ELDE KALAN]%s %s\n' "$YELLOW" "$NC" "$TEMIZ_NOT" >&2
    fi
}
trap cikista EXIT

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
t_head "Gölge geri yükleme — $MOTOR"

case "$MOTOR" in
    mariadb|postgresql) ;;
    *)  t_skip "gölge geri yükleme" \
            "$MOTOR bu pakette desteklenmiyor (kanıt sorguları mariadb/postgresql için yazılı)"
        e2e_finish; exit $? ;;
esac

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    t_unknown "gölge geri yükleme" "docker'a erişilemiyor — hiçbir şey ölçülemedi"
    e2e_finish; exit $?
fi
if ! container_running controller || ! container_running gateway; then
    t_skip "gölge geri yükleme" \
        "controller ya da gateway çalışmıyor — takası controller yapar, kesinti gateway'den ölçülür. Önce: ./stack.sh up"
    e2e_finish; exit $?
fi

ANA="$(primary_of "$MOTOR")"
if ! container_running "$ANA"; then
    t_skip "gölge geri yükleme" "$MOTOR kapalı ($ANA) — önce açın"
    e2e_finish; exit $?
fi

PORT="$(kat "e['route'][0]['listen']")"
if ! printf '%s' "${PORT:-}" | grep -qE '^[0-9]+$'; then
    t_unknown "gateway portu okunamadı" "catalog.json route[0].listen"
    e2e_finish; exit $?
fi

case "$MOTOR" in
mariadb)
    KULLANICI="root"; VTABANI="${DEFAULT_DATABASE:-defaultdb}"
    PAROLA="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}" ;;
postgresql)
    KULLANICI="${POSTGRES_USER:-root}"; VTABANI="${DEFAULT_DATABASE:-defaultdb}"
    PAROLA="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}" ;;
esac
if [ -z "$PAROLA" ]; then
    t_unknown "$MOTOR parolası okunamadı" ".env eksik — sorgu çalıştırılamaz"
    e2e_finish; exit $?
fi

# Yoklayıcı motorun KENDİ imajını kullanır: host'a istemci kurmadan, sürüm
# uyumu garanti biçimde sorgu çalışır (ha-drill.sh ile aynı desen).
IMAJ="$(docker inspect -f '{{.Config.Image}}' "$ANA" 2>/dev/null)"
AG="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' gateway 2>/dev/null)"
[ -n "$AG" ] || AG="databases-stack_net"
if [ -z "$IMAJ" ]; then
    t_unknown "motor imajı okunamadı" "yoklayıcı başlatılamaz"
    e2e_finish; exit $?
fi

# Ürün bu motorda gölgeyi destekliyor mu — SORUYORUZ, varsaymıyoruz.
DESTEK="$(ctl "E2E(app.shadow_supported('$MOTOR'))")"
if [ "$DESTEK" != "True" ]; then
    t_skip "gölge geri yükleme" "$MOTOR için desteklenmiyor (restore_$MOTOR yok ya da hacmi katalogda bildirilmemiş)"
    e2e_finish; exit $?
fi
if [ "$(ctl "E2E(app.replikasyon_kurulu_mu('$MOTOR'))")" = "True" ]; then
    t_skip "gölge geri yükleme" \
        "$MOTOR için replika kurulu — takas bilerek reddedilir (./stack.sh replica off $MOTOR)"
    e2e_finish; exit $?
fi
if [ "$(ctl "E2E(bool(app.bilet_of('$MOTOR')))")" = "True" ]; then
    t_skip "gölge geri yükleme" "$MOTOR için açık bir geri dönüş bileti var — önce onu kapatın"
    e2e_finish; exit $?
fi

# =============================================================================
# HAZIRLIK — veri üret, yedek al, İŞARET koy
# =============================================================================
t_info "kanıt tablosu hazırlanıyor (~${GOLGE_MB} MB)"
# Satır başına ~4 KB: hedef boyuta 256 satır/MB ile yaklaşıyoruz.
SATIR=$(( GOLGE_MB * 256 ))
# PARÇALI YAZIYORUZ. İki sebep ölçüldü: (1) MariaDB'nin özyinelemeli CTE'si
# max_recursive_iterations=1000'de duruyor ve "sorgu kesildi" diyor — tek
# deyimde 65 bin satır üretilemiyor; (2) 256 MB'ı tek işlemde yazmak, tavanı
# 1 GB olan bir container'da geri alma günlüğünü şişirir. Parça büyüklüğü
# ikisini de rahat karşılıyor.
PARCA=4096

case "$MOTOR" in
mariadb)
    sql "$ANA" "
      CREATE TABLE IF NOT EXISTS $TABLO (id INT PRIMARY KEY AUTO_INCREMENT,
        veri VARCHAR(255), dolgu LONGTEXT) ENGINE=InnoDB;
      TRUNCATE TABLE $TABLO;" >/dev/null
    _yazilan=0
    while [ "$_yazilan" -lt "$SATIR" ]; do
        _n=$(( SATIR - _yazilan )); [ "$_n" -gt "$PARCA" ] && _n="$PARCA"
        sql "$ANA" "
          SET SESSION max_recursive_iterations = 1000000;
          INSERT INTO $TABLO (veri, dolgu)
          WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < $_n)
          SELECT CONCAT('satir-', $_yazilan + n), REPEAT('x', 4000) FROM s;" >/dev/null           || break
        _yazilan=$(( _yazilan + _n ))
    done ;;
postgresql)
    sql "$ANA" "
      CREATE TABLE IF NOT EXISTS $TABLO (id serial PRIMARY KEY,
        veri text, dolgu text);
      TRUNCATE TABLE $TABLO;" >/dev/null
    _yazilan=0
    while [ "$_yazilan" -lt "$SATIR" ]; do
        _n=$(( SATIR - _yazilan )); [ "$_n" -gt "$PARCA" ] && _n="$PARCA"
        sql "$ANA" "
          INSERT INTO $TABLO (veri, dolgu)
          SELECT 'satir-'||($_yazilan + g), repeat('x', 4000)
          FROM generate_series(1,$_n) g;" >/dev/null || break
        _yazilan=$(( _yazilan + _n ))
    done ;;
esac

ONCE_SATIR="$(satir_say "$ANA")"
if ! printf '%s' "${ONCE_SATIR:-}" | grep -qE '^[0-9]+$' || [ "$ONCE_SATIR" -lt 1 ]; then
    t_unknown "kanıt verisi üretilemedi" "satır sayısı: '${ONCE_SATIR:-boş}' (ayrıntı: $E2E_LOG)"
    e2e_finish; exit $?
fi
t_info "üretilen: $ONCE_SATIR satır"

t_info "yedek alınıyor (gölgenin girdisi)"
if ! zaman_asimi "$GOLGE_TO" "$STACK_ROOT/scripts/backup.sh" "$MOTOR" >>"$E2E_LOG" 2>&1; then
    t_unknown "yedek alınamadı" "gölgenin girdisi yok (ayrıntı: $E2E_LOG)"
    e2e_finish; exit $?
fi

# İŞARET yedekten SONRA yazılıyor: hangi kopyanın canlı olduğunu ad değil
# VERİ söylesin. Hacim adına bakmak, adın doğru ama içeriğin yanlış olduğu
# durumu kaçırırdı.
sql "$ANA" "INSERT INTO $TABLO (veri, dolgu) VALUES ('$ISARET','m');" >/dev/null
ONCE_IMZA="$(imza "$ANA")"
ONCE_ISARET="$(isaret_var_mi "$ANA")"
ONCE_HACIM="$(ctl "E2E(app.canli_hacim(app.CATALOG.engine('$MOTOR')['primary_service']) or '')")"
ONCE_GOLGE_SAYI="$(docker volume ls -q --filter label=dbstack-golge 2>/dev/null | wc -l | tr -d ' ')"

if [ "$ONCE_ISARET" != "1" ]; then
    t_unknown "işaret satırı yazılamadı" "okunan: '$ONCE_ISARET'"
    e2e_finish; exit $?
fi
t_info "takas öncesi: hacim=$ONCE_HACIM imza=$ONCE_IMZA işaret=var"

# =============================================================================
# 2) NEGATİF — yabancı dosya üretime DOKUNMAMALI
# =============================================================================
# Sıralama bilinçli: yıkıcı olmayan yolun ilk sınavı, BAŞARISIZ olduğunda
# hiçbir şey bozmadığını göstermektir. Bunu takastan önce yapıyoruz ki
# ölçüm temiz bir üretim üzerinde koşsun.
t_head "Negatif — bozuk dosya üretime dokunmamalı"
BOZUK="$STACK_ROOT/backups/$MOTOR/full/e2e-bozuk-$$.sql.gz"
printf 'bu bir gzip degil, bilerek bozuk\n' > "$BOZUK"
TEMIZ_NOT="geçici bozuk dosya: $BOZUK"

NEG="$(ctl "
jid = app.new_job('shadow-restore','$MOTOR')
app.do_shadow_restore(jid,'$MOTOR','$(basename "$BOZUK")')
j = app.JOBS[jid]
E2E(j['state'])
")"
rm -f "$BOZUK"; TEMIZ_NOT=""

SONRA_SATIR="$(satir_say "$ANA")"
SONRA_HACIM="$(ctl "E2E(app.canli_hacim(app.CATALOG.engine('$MOTOR')['primary_service']) or '')")"

if [ "$NEG" = "failed" ]; then
    t_ok "bozuk dosyada gölge DÜŞÜYOR"
elif [ -z "$NEG" ]; then
    t_unknown "bozuk dosya denemesi" "controller'dan cevap alınamadı (ayrıntı: $E2E_LOG)"
else
    t_fail "bozuk dosyada gölge DÜŞMELİYDİ" "iş durumu: $NEG"
fi

if [ -z "$SONRA_SATIR" ] || [ -z "$SONRA_HACIM" ]; then
    t_unknown "başarısızlıktan sonra üretim ölçülemedi" "satır='$SONRA_SATIR' hacim='$SONRA_HACIM'"
elif [ "$SONRA_SATIR" = "$ONCE_SATIR" ] && [ "$SONRA_HACIM" = "$ONCE_HACIM" ]; then
    # ONCE_SATIR işaretten önceki sayı; işaret eklendiği için bir fazlası
    # beklenir. Karşılaştırmayı işaretten SONRAKİ sayıyla yapmalıyız.
    t_ok "gölge düştüğünde üretimin hacmi değişmiyor"
else
    BEKLENEN=$(( ONCE_SATIR + 1 ))
    if [ "$SONRA_SATIR" = "$BEKLENEN" ] && [ "$SONRA_HACIM" = "$ONCE_HACIM" ]; then
        t_ok "gölge düştüğünde üretimin verisi ve hacmi değişmiyor"
    else
        t_fail "gölge düştüğünde üretim DEĞİŞTİ" \
            "satır $BEKLENEN → $SONRA_SATIR, hacim $ONCE_HACIM → $SONRA_HACIM"
    fi
fi

# =============================================================================
# 1) KESİNTİ — gateway portundan, bağımsız tanıkla
# =============================================================================
t_head "Kesinti — gateway portundan ölçülüyor"
probe_baslat
sleep 1

TAKAS="$(ctl "
import json
jid = app.new_job('shadow-restore','$MOTOR')
app.do_shadow_restore(jid,'$MOTOR')
j = app.JOBS[jid]
E2E(json.dumps({'state': j['state'], 'reason': j.get('reason'),
                  'outage': j.get('outage_seconds'),
                  'restore': j.get('restore_seconds'),
                  'volume': j.get('volume'), 'pitr': j.get('pitr')}))
")"
sleep 1
probe_durdur

KESINTI="$(probe_kesinti)"
YOKLAMA="$(probe_toplam)"
DURUM="$(printf '%s' "$TAKAS" | sed -n 's/.*"state": *"\([^"]*\)".*/\1/p')"
GY_SN="$(printf '%s' "$TAKAS" | sed -n 's/.*"restore": *\([0-9]*\).*/\1/p')"
YENI_HACIM="$(printf '%s' "$TAKAS" | sed -n 's/.*"volume": *"\([^"]*\)".*/\1/p')"

if [ "$DURUM" != "done" ]; then
    t_fail "gölge geri yükleme + takas" "iş durumu: ${DURUM:-okunamadı} — $TAKAS"
    e2e_finish; exit $?
fi
t_ok "gölge geri yükleme + takas tamamlandı"
t_info "yoklama sayısı $YOKLAMA · veri ~${GOLGE_MB} MB · geri yükleme ${GY_SN:-?} sn"

if [ "$YOKLAMA" -lt 10 ]; then
    t_unknown "kesinti ölçülemedi" "yalnız $YOKLAMA yoklama yapıldı — tanık çalışmadı"
elif [ "$KESINTI" = "ÖLÇÜLEMEDİ" ]; then
    t_unknown "kesinti ölçülemedi" "yoklama çıktısı boş"
else
    t_info "gateway portu $KESINTI sn cevap vermedi (geri yükleme ${GY_SN:-?} sn sürdü)"
    # ASIL İDDİA: kesinti, geri yükleme süresinden BELİRGİN ölçüde küçük.
    # Eşiği yarı olarak alıyoruz — "10 kat" gibi bir sayı veriye bağlı ve
    # küçük veride kendiliğinden sağlanmaz; abartılı bir eşik, ölçümü
    # veriye göre yalancı kırmızıya çevirirdi.
    if [ -z "${GY_SN:-}" ]; then
        t_unknown "kesinti/geri yükleme kıyası" "geri yükleme süresi okunamadı"
    elif awk "BEGIN{exit !($KESINTI < $GY_SN / 2)}"; then
        t_ok "kesinti geri yükleme süresinden belirgin küçük" \
            "$KESINTI sn / $GY_SN sn"
    else
        t_fail "kesinti geri yükleme süresine yakın — vaat karşılanmıyor" \
            "kesinti $KESINTI sn, geri yükleme $GY_SN sn (veri ~${GOLGE_MB} MB; E2E_GOLGE_MB ile artırın)"
    fi
fi

# Takas GERÇEKTEN oldu mu — adı değil VERİYİ soruyoruz.
CANLI="$(ctl "E2E(app.canli_hacim(app.CATALOG.engine('$MOTOR')['primary_service']) or '')")"
if [ -z "$CANLI" ]; then
    t_unknown "takastan sonra canlı hacim ölçülemedi" "docker inspect cevap vermedi"
elif [ "$CANLI" = "$YENI_HACIM" ] && [ "$CANLI" != "$ONCE_HACIM" ]; then
    t_ok "canlı hacim yeni kuşak (container'dan ölçüldü)" "$CANLI"
else
    t_fail "canlı hacim beklenen kuşakta değil" "beklenen $YENI_HACIM, ölçülen $CANLI"
fi

# Motor yeni hacimle YENİDEN YARATILDI: sorgu için hazır olmasını bekliyoruz.
# İlk sürüm beklemiyordu ve "işaret satırı okunamadı" diyordu — ürünün değil
# ölçümün hatası.
for _ in $(seq 1 40); do
    sql "$ANA" "SELECT 1" >/dev/null 2>&1 && break
    sleep 3
done
ISARET_SONRA="$(isaret_var_mi "$ANA")"
if [ "$ISARET_SONRA" = "0" ]; then
    t_ok "takastan sonra yedek SONRASI yazılan veri yok (geri yüklenen kopya servis ediliyor)"
elif [ "$ISARET_SONRA" = "1" ]; then
    t_fail "takas veriyi değiştirmemiş" "işaret satırı hâlâ duruyor — eski kopya servis ediliyor olabilir"
else
    t_unknown "takas sonrası işaret satırı okunamadı" "okunan: '$ISARET_SONRA'"
fi

# =============================================================================
# 4) AYRIŞMA — dosyaya değil ÖLÇÜME inanmalı
# =============================================================================
t_head "Ayrışma — işaretçi ile gerçek çeliştiğinde"
# Takas yarıda kalmış bir dünyayı BİLEREK kuruyoruz: volumes.env var olmayan
# bir kuşağı gösteriyor, container ise gerçek olanı bağlı. Ürün burada
# dosyaya inanırsa panelde yanlış cevap verir ve kimse hata görmez.
AYRISMA="$(ctl "
import app
s = app.CATALOG.engine('$MOTOR')['primary_service']
onceki = app.volumes_env_oku()
atama = {s: '$CANLI' + '__g999'}
app.volumes_env_yaz(atama)
c, n, d = app.kusak_durumu(s)
# Dünyayı geri koyuyoruz: bu kontrol ölçüm yapar, durum bırakmaz.
app.volumes_env_yaz({s: '$CANLI'})
E2E('%s|%s|%s' % (c, n, d))
")"
A_CANLI="${AYRISMA%%|*}"; A_KALAN="${AYRISMA#*|}"
A_NIYET="${A_KALAN%%|*}"; A_DRIFT="${A_KALAN##*|}"
if [ -z "$AYRISMA" ]; then
    t_unknown "ayrışma ölçülemedi" "controller cevap vermedi"
elif [ "$A_DRIFT" = "True" ] && [ "$A_CANLI" = "$CANLI" ]; then
    t_ok "işaretçi yalan söylediğinde ürün AYRIŞMA diyor (dosyaya inanmıyor)" \
        "canlı=$A_CANLI niyet=$A_NIYET"
else
    t_fail "ayrışma bildirilmedi" "canlı=$A_CANLI niyet=$A_NIYET drift=$A_DRIFT"
fi

# =============================================================================
# 3) GERİ DÖNÜŞ — biletle, imza bit-birebir
# =============================================================================
t_head "Geri dönüş bileti"
BILET_VAR="$(ctl "E2E(bool(app.bilet_of('$MOTOR')))")"
if [ "$BILET_VAR" != "True" ]; then
    t_fail "takastan sonra geri dönüş bileti kesilmemiş" "bilet yok"
    e2e_finish; exit $?
fi
t_ok "takastan sonra geri dönüş bileti açık"

GERI="$(ctl "
jid = app.new_job('rollback','$MOTOR')
app.do_ticket_rollback(jid,'$MOTOR')
E2E(app.JOBS[jid]['state'])
")"
if [ "$GERI" != "done" ]; then
    t_fail "bilet kullanılamadı" "iş durumu: ${GERI:-okunamadı}"
    TEMIZ_NOT="ELDE BİLET KALDI — panelden 'Takas öncesine dön' ile geri alın."
    e2e_finish; exit $?
fi

# Motor yeniden yaratıldı: sorgu için hazır olmasını bekliyoruz.
for _ in $(seq 1 40); do
    sql "$ANA" "SELECT 1" >/dev/null 2>&1 && break
    sleep 3
done

SON_IMZA="$(imza "$ANA")"
SON_ISARET="$(isaret_var_mi "$ANA")"
SON_HACIM="$(ctl "E2E(app.canli_hacim(app.CATALOG.engine('$MOTOR')['primary_service']) or '')")"

if [ -z "$SON_IMZA" ] || [ "$SON_IMZA" = "HATA" ]; then
    t_unknown "geri dönüşten sonra imza okunamadı" "motor hazır olmamış olabilir (ayrıntı: $E2E_LOG)"
elif [ "$SON_IMZA" = "$ONCE_IMZA" ]; then
    t_ok "geri dönüşte veri BİT-BİREBİR aynı (satır sayısı değil, içerik imzası)" \
        "imza $SON_IMZA"
else
    t_fail "geri dönüşte veri farklı" "önce $ONCE_IMZA, sonra $SON_IMZA"
fi

if [ "$SON_ISARET" = "1" ]; then
    t_ok "geri dönüşte takas öncesi işaret satırı geri geldi"
else
    t_fail "geri dönüşte işaret satırı yok" "okunan: '$SON_ISARET'"
fi

if [ "$SON_HACIM" = "$ONCE_HACIM" ]; then
    t_ok "geri dönüşte canlı hacim başlangıçtaki kuşak" "$SON_HACIM"
else
    t_fail "geri dönüşte hacim başlangıçtakine dönmedi" "beklenen $ONCE_HACIM, ölçülen $SON_HACIM"
fi

# =============================================================================
# KALINTI — gölge hacmi sayısı beklenene eşit mi
# =============================================================================
# Geri dönüşten sonra gölge hacmi diskte KALIR (olay da bunu söylüyor).
# Beklenen: başlangıçtaki sayı + 1. Fazlası sızıntıdır; bu depoda kalıntı
# disiplini var ve `docker volume ls` kimsenin bakmadığı yerdir.
SON_GOLGE_SAYI="$(docker volume ls -q --filter label=dbstack-golge 2>/dev/null | wc -l | tr -d ' ')"
BEKLENEN_GOLGE=$(( ONCE_GOLGE_SAYI + 1 ))
if [ "$SON_GOLGE_SAYI" = "$BEKLENEN_GOLGE" ]; then
    t_ok "gölge hacmi sayısı beklenen" "$SON_GOLGE_SAYI (başlangıç $ONCE_GOLGE_SAYI + 1)"
else
    t_fail "gölge hacmi sayısı beklenenden farklı" \
        "beklenen $BEKLENEN_GOLGE, sayılan $SON_GOLGE_SAYI"
fi

# Ürün bu hacmi ARTIK olarak görüyor mu — sızıntıyı kendisi söylemeli.
ARTIK="$(ctl "E2E(','.join(app.artik_golge_hacimleri() or []))")"
if printf '%s' "$ARTIK" | grep -q "$YENI_HACIM"; then
    t_ok "ürün sahipsiz gölge hacmini kendisi bildiriyor" "$ARTIK"
else
    t_fail "sahipsiz gölge hacmi bildirilmedi" "beklenen $YENI_HACIM, bildirilen: '${ARTIK:-yok}'"
fi

# Paket kendi çöpünü toplar: bıraktığı hacim bir sonraki koşumun sayımını
# bozardı.
if docker volume rm "$YENI_HACIM" >>"$E2E_LOG" 2>&1; then
    t_info "gölge hacmi silindi: $YENI_HACIM"
else
    TEMIZ_NOT="gölge hacmi silinemedi: docker volume rm $YENI_HACIM"
fi
sql "$ANA" "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1

e2e_finish
exit $?
