#!/bin/bash
# =============================================================================
# databases-stack — E2E: DEVİR PROVASI (scripts/failover-drill.sh)
# =============================================================================
# Bu paket provanın kendisini sınar. Sorduğu soru "HA çalışıyor mu" değil:
#
#     PROVA ARACI DOĞRU SÖYLÜYOR MU, VE İZİNSİZ BİR ŞEY YAPIYOR MU?
#
# Sebep: bu araç, restore-drill.sh'ın tersine, ÜRETİM VERİTABANINI GERÇEKTEN
# DEVREDİYOR. Böyle bir aracın üç şekilde zarar vermesi mümkündür ve üçü de
# sessizdir:
#   1) İZİNSİZ DEVREDER — --onayla verilmeden ana kopyayı durdurur. Kullanıcı
#      "bir bakayım" diye çalıştırdığı komutla üretimini devretmiş olur.
#   2) YANLIŞ SÖYLER — replikasyon akmıyorken devreder (senkron olmamış bir
#      düğümü yükseltmek = sessiz veri kaybı), ya da ölçemediği kesintiyi
#      "0 saniye" diye raporlar. İkincisi bu ürünün satış cümlesini
#      ("6 saniyede devrettik") ölçüme değil temenniye dayandırır.
#   3) ARKASINDA ÇÖP BIRAKIR — sonda container'ı ve prova tablosu üretim
#      veritabanında kalır.
#
# ÖLÇÜLENLER
#   · kapsam dışı motorda 0 DEĞİL anlamlı bir kod dönüyor mu (cassandra,
#     mongodb: devri kendi yapar)
#   · motor verilmeden çağrıldığında ne yapıyor
#   · son satır TEK SATIR ve GEÇERLİ JSON mu (controller bunu okuyacak)
#   · --onayla YOKKEN üretimde devir YAPMIYOR mu (topoloji ve ana kopyanın
#     StartedAt damgası değişmemeli)
#   · plan, eski düğümü geri getirecek komutu YAZIYOR mu
#   · replikasyon akmıyorken (yedek kopya kapalı) --onayla ile bile
#     REDDEDİYOR mu ve ana kopyaya dokunmuyor mu
#   · GERÇEK prova: devir oldu mu, ölçülen kesinti üst sınırın altında mı
#   · devirden sonra BU PAKETİN KENDİ kanıt satırı duruyor mu
#   · sonda container'ı ve prova tablosu SONUNDA gerçekten silinmiş mi
#
# KANIT SATIRINI NEDEN KENDİMİZ YAZIYORUZ: provanın "data_loss": false demesi
# kendi kendini not vermesidir. Bu paket devirden ÖNCE kendi satırını
# gateway'den yazar, yedeğe aktığını doğrular ve devirden SONRA yeni ana
# kopyada arar. Prova "kayıp yok" derken bizim satırımız kaybolmuşsa bulgu
# provanın kendisi hakkındadır.
#
# ÜST SINIRI KİM SEÇİYOR: bu paket, kendi sınırını KENDİ hesaplar
# (E2E_HA_TAVAN, varsayılan 90 sn) ve provanın raporladığı sınırı ölçüt olarak
# KULLANMAZ. Ürünün kendi eşiğini ödünç alan bir test, eşiğin yanlış olduğu
# durumu asla yakalayamaz. 90 sn'nin gerekçesi ürünün kendi zaman aşımları:
# fence 15 sn (controller'ın docker stop -t 15'i) + yükseltme 60 sn (MariaDB
# relay log'u 30 sn bekler, PostgreSQL'in promote yoklamasının tavanı 120
# sn'dir ama beklenen değeri saniyelerdir, Redis ~1 sn) + yönlendirme 15 sn
# (nginx reload + stream resolver'ın 10 sn'lik DNS önbelleği). Bu bir HEDEF
# değil ALARM eşiğidir: üstü "yavaş devir" değil "bir yerde takıldı"dır.
# PLANLI devir ölçülüyor; ana kopya kendiliğinden ölseydi buna denetleyicinin
# tespit süresi (FAILOVER_STRIKES × FAILOVER_INTERVAL) eklenirdi ve o sayı
# ÖLÇÜLMEZ, yapılandırmadan okunur.
#
# ⚠ YAN ETKİ — BU PAKET ÜRETİM VERİTABANINI DEVREDİR:
#   • Seçilen motorda GERÇEK bir devir yapılır: ana kopya durdurulur, yedek
#     yükselir, roller KALICI olarak yer değiştirir. E2E_HA_DEVIR=0 ile
#     kapatılabilir (o zaman ilgili kontroller ATLANDI olur — ve paketin asıl
#     ölçümü yapılmamış olur).
#   • "Reddediyor mu" kontrolü için YEDEK kopya geçici olarak durdurulur ve
#     sonunda geri açılır (durdurulan düğüm defteri + EXIT tuzağı). Ana kopyaya
#     dokunulmaz.
#   • Prova bittiğinde yedek kopya YOKTUR. Geri getirmek için:
#         ./stack.sh failover rebuild <motor>
#
# YEDEKLEME KİLİDİNİ ALMIYORUZ — BİLEREK. Diğer e2e paketleri (failover.sh)
# state/backup.lock'u alır. Bu paket ALIRSA, çağırdığı provanın kendisi aynı
# kilidi isteyip "kilit başkasında" diyerek çıkar; yani paket, ölçmek istediği
# aracı kendi eliyle engellemiş olur. Kilidi başkası tutuyorsa provanın çıkış
# 3'ünü ATLANDI olarak raporluyoruz (aşağıdaki kilit_carpismasi).
#
# set -e YOK: her kontrol tek tek raporlanmalı. Sonuç türleri ve çıkış kodu
# ortak kütüphanede (scripts/e2e/lib.sh); "ölçemedik" (t_unknown) BAŞARISIZ
# sayılır, çünkü "bilmiyorum" ile "iyi" aynı şey değildir.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

[ -r scripts/e2e/lib.sh ] \
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi olmadan bu paket ölçüm yapamaz."
E2E_SUITE="ha-drill"
source scripts/e2e/lib.sh

# python3 çıktısı SABİT UTF-8 olsun: yerel ayarı UTF-8 olmayan bir kabukta
# ürünün Türkçe mesajlarındaki harfler bozulur ve metin eşleşmeleri tutmaz.
export PYTHONIOENCODING=utf-8

LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
PROVA="scripts/failover-drill.sh"
# Çalıştırma izni kaybolmuş bir checkout'ta (Windows'tan kopyalanmış depo,
# unzip edilmiş arşiv) `./betik` "Permission denied" verir. Paket bunu ÜRÜN
# HATASI gibi raporlamasın diye çağrı biçimini burada bir kez seçiyoruz.
PROVA_CAGRI=("./$PROVA")
[ -x "$PROVA" ] || PROVA_CAGRI=(bash "$PROVA")

ETIKET="dbstack-ha-prova"     # provanın sonda container'ı bu etiketi taşır
PROVA_TABLO="ha_prova"        # provanın kendi prova tablosu (silmiş olmalı)
PROVA_ANAHTAR="dbstack:ha-prova"

# Bu paketin KENDİ kanıt satırı — provanınkiyle karışmasın diye ayrı ad.
KANIT_TABLO="e2e_ha_kanit"
KANIT_ANAHTAR="e2e:ha-kanit"
KOSU="$(date +%s)-$$"

TAVAN="${E2E_HA_TAVAN:-90}"
DEVIR_YAP="${E2E_HA_DEVIR:-1}"
SURE_PROVA="${E2E_HA_PROVA_SURESI:-1800}"
ISTEMCI_TO="${E2E_HA_ISTEMCI_TIMEOUT:-60}"
AKIS_TO="${E2E_HA_AKIS_TIMEOUT:-60}"
# Motor sırası ucuzdan pahalıya: her prova gerçek bir devir yapıyor. Paketin
# işi motorları taramak değil, PROVA ARACINI sınamak — bir motor yeter.
SIRA="${E2E_HA_MOTOR:-redis mariadb postgresql}"

# ------------------------------------------------------------ zaman aşımı ---
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman_asimi() {
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
# Ölçüm ARACI asıldıysa sonuç "ürün yanlış cevap verdi" değil "ÖLÇEMEDİK"tir:
# timeout(1) zaman aşımında 124, -k ile öldürmek zorunda kalınca 137 döner.
asildi_mi() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }
docker_yasiyor() { docker ps -q >/dev/null 2>&1; }

mkdir -p "$LOG_DIR"
E2E_LOG="$LOG_DIR/e2e-ha-drill_$(date +%Y%m%d_%H%M%S).log"
: > "$E2E_LOG"
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-ha-XXXXXX")" \
    || die "Geçici dizin açılamadı."

# ------------------------------------------- durdurulan düğüm defteri -------
# Paket bir düğümü durdurursa YAZAR ve çıkarken geri açar. Kullanıcının yedek
# kopyasını kapalı bırakan bir test aracı, hatanın kendisidir.
DURDURULAN=()
cikis_temizligi() {
    local c
    for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
        warn "paketin durdurduğu $c geri açılıyor"
        docker start "$c" >/dev/null 2>&1 \
            || warn "  $c AÇILAMADI — elle: docker start $c"
    done
    [ -n "${E2E_TMP:-}" ] && rm -rf "$E2E_TMP" 2>/dev/null
    return 0
}
# Temizlik YALNIZ EXIT üzerinde: INT/TERM lib.sh'in (kesilen koşu 130 ile
# çıkar ve bu tuzağı zaten tetikler). Buraya INT yazmak, Ctrl-C'yi sessiz bir
# başarıya çevirirdi.
trap cikis_temizligi EXIT

# =============================================================================
# PROVAYI ÇALIŞTIRAN SARMALAYICI
# =============================================================================
# Provanın üç çıktısı ayrı ayrı lazım: çıkış kodu, TAM metin ve SON SATIR
# (JSON). Boru hattında çıkış kodunun kaybolması bu paketlerdeki sahte-yeşilin
# bir numaralı sebebi olduğu için çıktı dosyaya alınıp rc ayrıca saklanıyor.
PROVA_RC=0
PROVA_CIKTI=""
PROVA_JSON=""
prova_calistir() {   # prova_calistir <etiket> <argümanlar…>
    local ne="$1"; shift
    PROVA_CIKTI="$E2E_TMP/prova.out"
    PROVA_JSON="$E2E_TMP/prova.json"
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$ne"
      printf 'komut: %s %s\n' "${PROVA_CAGRI[*]}" "$*"; } >> "$E2E_LOG"
    PROVA_RC=0
    # stdin /dev/null: prova onay için terminal beklemez (--onayla bayrağı
    # kullanır) ama beklese bile bu paket asılı kalmasın.
    zaman_asimi "$SURE_PROVA" "${PROVA_CAGRI[@]}" "$@" > "$PROVA_CIKTI" 2>&1 \
        < /dev/null || PROVA_RC=$?
    cat "$PROVA_CIKTI" >> "$E2E_LOG"
    tail -n 1 "$PROVA_CIKTI" > "$PROVA_JSON" 2>/dev/null
    return 0
}

son_ozet() {
    tr -d '\r' < "$PROVA_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' \
        | tail -n 2 | tr '\n' ' '
}
kilit_carpismasi() { grep -qaF "kilidi başkasında" "$PROVA_CIKTI" 2>/dev/null; }

# JSON'dan tek alan. rc=2 → dosya JSON DEĞİL (bu da bir bulgudur); rc=3 → alan
# yok. Yokluk ile "null" birbirine karışmasın diye null açıkça basılıyor.
json_alan() {   # json_alan <alan>
    python3 - "$PROVA_JSON" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
if not isinstance(d, dict) or sys.argv[2] not in d:
    sys.exit(3)
v = d[sys.argv[2]]
if v is None:   print("null")
elif v is True: print("true")
elif v is False:print("false")
else:           print(v)
PY
}

# Çıktının TAMAMINDA '{' ile başlayan KAÇ satır var? Yalnız "son satır
# ayrıştı" demek yetmez: kendi kestiğimiz satırı sınamış oluruz. Fazladan bir
# JSON satırı basılırsa controller hangisini okuyacağını bilemez.
json_satir_sayisi() {
    grep -ac '^{' "$PROVA_CIKTI" 2>/dev/null | tr -d '[:space:]'
}

kontrol_json_bicimi() {   # kontrol_json_bicimi <ad>
    local ad="$1" adet ok_alan
    adet="$(json_satir_sayisi)"
    if ! ok_alan="$(json_alan ok)"; then
        t_fail "$ad" "son satır JSON olarak ayrıştırılamadı: $(tail -c 200 "$PROVA_JSON" | tr -d '\r\n')"
    elif [ "${adet:-0}" -ne 1 ]; then
        t_fail "$ad" "çıktıda $adet adet JSON satırı var — tam olarak 1 olmalı"
    else
        t_ok "$ad"
    fi
}

# =============================================================================
# ÜRÜN DURUMU — katalog, topoloji, state
# =============================================================================
kat() {   # kat <motor> <python ifadesi>
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e: sys.exit(1)
v = eval(sys.argv[3], {"e": e[0]})
sys.stdout.write("" if v is None else str(v))' "$CATALOG" "$1" "$2" 2>/dev/null \
    | tr -d '\r'
}

denetlenen_motorlar() {
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
for e in c["engines"]:
    f = e.get("failover", {})
    if f.get("supported") and f.get("mode") == "supervised":
        print(e["id"])' "$CATALOG" 2>/dev/null | tr -d '\r'
}

# state.json bir LİSTE dosyasıdır; "listede yok" ile "dosyayı okuyamadım" aynı
# şey değildir. 0 = var · 1 = yok · 2 = ÖLÇEMEDİK
durum_listesinde() {
    python3 -c '
import json, os, sys
yol = sys.argv[1]
if not os.path.exists(yol):
    sys.exit(1)
try:
    s = json.load(open(yol, encoding="utf-8"))
except Exception:
    sys.exit(2)
sys.exit(0 if sys.argv[3] in (s.get(sys.argv[2]) or []) else 1)' \
        "$STACK_ROOT/state/state.json" "$1" "$2" 2>/dev/null
    local rc=$?
    [ "$rc" -le 2 ] || rc=2
    return $rc
}

# Ana kopyayı common.sh'in primary_of'u ile okuyoruz — ürünün kendi yardımcısı.
# Devirden sonra bu, kataloğun varsayılan servisi DEĞİLDİR.
prim_oku() { primary_of "$1"; }

yedek_dugum() {   # yedek_dugum <motor> <şu anki ana kopya>
    local p; p="$(kat "$1" 'e["primary_service"]')"
    if [ "$2" = "$p" ]; then kat "$1" 'e["replication"].get("replica_service") or ""'
    else printf '%s' "$p"; fi
}

# Üretime dokunmama ölçütü State.StartedAt: prova ana kopyayı durdurup
# açsaydı bu damga değişirdi. Ayrıca hâlâ ÇALIŞIYOR olmalı — durdurulmuş bir
# container'ın StartedAt'i de değişmez, o yüzden ikisine birden bakıyoruz.
damga_al() { docker inspect -f '{{.State.StartedAt}}|{{.State.Running}}' "$1" 2>/dev/null; }

dugum_durdur() {
    docker stop -t 10 "$1" >>"$E2E_LOG" 2>&1 || return 1
    DURDURULAN+=("$1")
    return 0
}
dugum_baslat() {
    local yeni=() c
    docker start "$1" >>"$E2E_LOG" 2>&1 || return 1
    for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
        [ "$c" = "$1" ] || yeni+=("$c")
    done
    DURDURULAN=(${yeni[@]+"${yeni[@]}"})
    return 0
}

# =============================================================================
# İSTEMCİLER — paketin KENDİ kanıt satırı için
# =============================================================================
# İstemci imajı motorun kendi container'ının imajıdır: host'a hiçbir
# veritabanı istemcisi kurmadan, sürüm uyumu garanti biçimde sorgu çalışır.
# gw_* gateway üzerinden (uygulamanın gördüğü yol), dugum_* doğrudan düğümden.
# Burada TEK ATIŞLIK container kullanıyoruz: bu paket süre ÖLÇMÜYOR, yalnız
# satır yazıp okuyor — provanın sonda container'ına gerek yok.
M_IMAJ=""; M_LISTEN=""; M_KULLANICI=""; M_VTABANI=""; M_PAROLA=""; AG=""

gw_calistir() {   # gw_calistir <sql | redis argümanları…>
    case "$MOTOR" in
    mariadb)
        ( export MYSQL_PWD="$M_PAROLA"
          zaman_asimi "$ISTEMCI_TO" docker run --rm --network "$AG" -e MYSQL_PWD \
            --entrypoint mariadb "$M_IMAJ" -h gateway -P "$M_LISTEN" \
            -u "$M_KULLANICI" -D "$M_VTABANI" --connect-timeout=10 -N -B \
            -e "$1" ) 2>>"$E2E_LOG" ;;
    postgresql)
        ( export PGPASSWORD="$M_PAROLA" PGCONNECT_TIMEOUT=10
          zaman_asimi "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e PGPASSWORD -e PGCONNECT_TIMEOUT \
            --entrypoint psql "$M_IMAJ" -h gateway -p "$M_LISTEN" \
            -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAq -v ON_ERROR_STOP=1 \
            -c "$1" ) 2>>"$E2E_LOG" ;;
    redis)
        ( export REDISCLI_AUTH="$M_PAROLA"
          zaman_asimi "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e REDISCLI_AUTH --entrypoint redis-cli "$M_IMAJ" \
            --no-auth-warning -h gateway -p "$M_LISTEN" "$@" ) 2>>"$E2E_LOG" ;;
    *)  return 1 ;;
    esac
}

dugum_calistir() {   # dugum_calistir <container> <sql | redis argümanları…>
    local c="$1"; shift
    case "$MOTOR" in
    mariadb)
        ( export MYSQL_PWD="$M_PAROLA"
          zaman_asimi "$ISTEMCI_TO" docker exec -e MYSQL_PWD "$c" \
            mariadb -u "$M_KULLANICI" -D "$M_VTABANI" -N -B -e "$1" ) \
          2>>"$E2E_LOG" ;;
    postgresql)
        ( export PGPASSWORD="$M_PAROLA"
          zaman_asimi "$ISTEMCI_TO" docker exec -e PGPASSWORD "$c" \
            psql -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAq \
                 -v ON_ERROR_STOP=1 -c "$1" ) 2>>"$E2E_LOG" ;;
    redis)
        ( export REDISCLI_AUTH="$M_PAROLA"
          zaman_asimi "$ISTEMCI_TO" docker exec -e REDISCLI_AUTH "$c" \
            redis-cli --no-auth-warning "$@" ) 2>>"$E2E_LOG" ;;
    *)  return 1 ;;
    esac
}

tek_satir() { printf '%s' "${1:-}" | tr -d '\r' | head -n 1 | tr -d '[:blank:]'; }

kanit_yaz() {   # 0 = yazıldı
    case "$MOTOR" in
    mariadb)
        gw_calistir "CREATE TABLE IF NOT EXISTS $KANIT_TABLO (
                       k VARCHAR(64) PRIMARY KEY,
                       v VARCHAR(96) NOT NULL) ENGINE=InnoDB;
                     REPLACE INTO $KANIT_TABLO (k,v)
                       VALUES ('kanit','$KOSU');" >/dev/null ;;
    postgresql)
        gw_calistir "CREATE TABLE IF NOT EXISTS $KANIT_TABLO (
                       k text PRIMARY KEY, v text NOT NULL);
                     INSERT INTO $KANIT_TABLO (k,v) VALUES ('kanit','$KOSU')
                       ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" \
            >/dev/null ;;
    redis)
        local o; o="$(gw_calistir HSET "$KANIT_ANAHTAR" kanit "$KOSU")" || return 1
        # redis-cli read-only bir düğüme yazınca "-READONLY …" basıp ÇIKIŞ 0
        # döner; karar çıkış koduna değil ÇIKTIYA dayanmalı.
        case "$(tek_satir "$o")" in ''|*[!0-9]*) return 1 ;; esac ;;
    *)  return 1 ;;
    esac
}

# DEĞERİ KANIT_DEGER'e koyar, çıkış koduyla SORGUNUN çalışıp çalışmadığını
# söyler: "satır yok" bir ölçümdür (veri kaybı), "sorgu çalışmadı" ölçüm
# yokluğudur ve ikisi de boş cevap üretir.
KANIT_DEGER=""
kanit_oku() {   # kanit_oku <gw | container> → 0 sorgu çalıştı · 1 çalışmadı
    local bakis="$1" o
    KANIT_DEGER=""
    case "$MOTOR" in
    mariadb|postgresql)
        if [ "$bakis" = "gw" ]; then
            o="$(gw_calistir "SELECT v FROM $KANIT_TABLO WHERE k='kanit';")" || return 1
        else
            o="$(dugum_calistir "$bakis" "SELECT v FROM $KANIT_TABLO WHERE k='kanit';")" || return 1
        fi ;;
    redis)
        if [ "$bakis" = "gw" ]; then
            o="$(gw_calistir HGET "$KANIT_ANAHTAR" kanit)" || return 1
        else
            o="$(dugum_calistir "$bakis" HGET "$KANIT_ANAHTAR" kanit)" || return 1
        fi ;;
    *)  return 1 ;;
    esac
    KANIT_DEGER="$(tek_satir "$o")"
    return 0
}

kanit_sil() {
    case "$MOTOR" in
    mariadb|postgresql) dugum_calistir "$(prim_oku "$MOTOR")" \
                            "DROP TABLE IF EXISTS $KANIT_TABLO;" >/dev/null ;;
    redis)              dugum_calistir "$(prim_oku "$MOTOR")" \
                            DEL "$KANIT_ANAHTAR" >/dev/null ;;
    esac
}

# "yok" | "var" | "sorulamadi" — üçüncü hâl ŞART: sorgu hiç çalışmadıysa boş
# cevap gelir ve "boş = silinmiş" saymak, temizlik kontrolünü tam da temizlik
# ölçülemediği durumda yeşil yakardı.
prova_tablosu_durumu() {
    local c o rc
    c="$(prim_oku "$MOTOR")"
    case "$MOTOR" in
    mariadb)
        o="$(dugum_calistir "$c" "SELECT COUNT(*) FROM information_schema.TABLES
              WHERE table_schema = DATABASE() AND table_name = '$PROVA_TABLO';")" ;;
    postgresql)
        o="$(dugum_calistir "$c" "SELECT COUNT(*) FROM pg_class
              WHERE relname = '$PROVA_TABLO';")" ;;
    redis)
        o="$(dugum_calistir "$c" EXISTS "$PROVA_ANAHTAR")" ;;
    *)  printf 'sorulamadi'; return ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ]; then printf 'sorulamadi'; return; fi
    case "$(tek_satir "$o")" in
        ""|*[!0-9]*) printf 'sorulamadi' ;;
        0)           printf 'yok' ;;
        *)           printf 'var' ;;
    esac
}

# =============================================================================
# MOTOR SEÇİMİ
# =============================================================================
MOTOR=""; YEDEK=""; ANA=""; SECIM_NOTU=""
motor_baglami() {   # 0 = bağlam kuruldu
    local pv
    M_LISTEN="$(kat "$MOTOR" 'e["route"][0]["listen"]')"
    M_KULLANICI="$(kat "$MOTOR" 'e["connection"]["username"]')"
    M_VTABANI="$(kat "$MOTOR" 'e["connection"]["database"]')"
    pv="$(kat "$MOTOR" 'e["connection"]["password_env"]')"
    M_VTABANI="${DEFAULT_DATABASE:-$M_VTABANI}"
    [ "$MOTOR" = "postgresql" ] && M_KULLANICI="${POSTGRES_USER:-$M_KULLANICI}"
    M_PAROLA="${!pv:-}"
    [ -n "$M_PAROLA" ] || M_PAROLA="${DB_PASSWORD:-}"
    M_IMAJ="$(docker inspect -f '{{.Config.Image}}' "$ANA" 2>/dev/null)"
    [ -n "$M_LISTEN" ] && [ -n "$M_PAROLA" ] && [ -n "$M_IMAJ" ]
}

motor_sec() {
    local eid kapsam prof
    kapsam="$(denetlenen_motorlar)"
    if [ -z "$kapsam" ]; then
        SECIM_NOTU="catalog.json'dan denetlenen (supervised) motor listesi okunamadı"
        return 1
    fi
    for eid in $SIRA; do
        printf '%s\n' "$kapsam" | grep -qx "$eid" || continue
        MOTOR="$eid"
        ANA="$(prim_oku "$eid")"
        container_running "$ANA" || { SECIM_NOTU="$eid ana kopyası ($ANA) çalışmıyor"; continue; }
        prof="$(kat "$eid" 'e["replication"].get("profile") or ""')"
        durum_listesinde profiles "$prof"; local rc=$?
        if [ "$rc" -eq 2 ]; then
            SECIM_NOTU="state/state.json okunamadı — replikasyonun kurulu olup olmadığı ölçülemedi"
            MOTOR=""; return 1
        fi
        [ "$rc" -eq 0 ] || { SECIM_NOTU="$eid için replikasyon kurulu değil (./stack.sh replica on $eid)"; continue; }
        YEDEK="$(yedek_dugum "$eid" "$ANA")"
        container_running "$YEDEK" || { SECIM_NOTU="$eid yedek kopyası ($YEDEK) çalışmıyor"; continue; }
        motor_baglami || { SECIM_NOTU="$eid bağlamı kurulamadı (.env parolası / imaj / port okunamadı)"; continue; }
        return 0
    done
    MOTOR=""
    [ -n "$SECIM_NOTU" ] || SECIM_NOTU="denetlenen motorların hiçbiri prova için hazır değil"
    return 1
}

# =============================================================================
# KONTROLLER — docker gerektirmeyenler (en başta: yığın kapalıyken bile
# paket EN AZ BİR ŞEY ölçmüş olsun, yoksa "hiçbir kontrol çalışmadı" ile
# "her şey yeşil" ayrımı kaybolurdu)
# =============================================================================
kontrol_kapsam_disi() {
    local ad="kapsam dışı motorda 0 DEĞİL anlamlı kod dönüyor (cassandra)"
    prova_calistir "kapsam dışı motor" cassandra
    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad" "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
    elif [ "$PROVA_RC" -eq 2 ]; then
        t_ok "$ad — çıkış 2 (kapsam dışı), hata koduyla karışmıyor"
    elif [ "$PROVA_RC" -eq 0 ]; then
        t_fail "$ad" "çıkış 0: devri OLMAYAN bir motorda prova BAŞARILI görünüyor"
    else
        t_fail "$ad" "beklenen çıkış 2, gelen $PROVA_RC: $(son_ozet)"
    fi
    kontrol_json_bicimi "kapsam dışı çağrıda da son satır TEK SATIR ve geçerli JSON"
}

kontrol_native_devir() {
    # MongoDB devri KENDİ yapar (failover.mode=native): controller araya
    # girmez, dolayısıyla ölçülecek bir "controller devri" de yoktur. Bunu
    # sessizce desteklenmiyor saymak, kullanıcının kurduğu replica set'i
    # yokmuş gibi göstermek olurdu — prova SEBEBİNİ söylemeli.
    local ad="devri kendi yapan motorda prova reddediyor ve SEBEBİNİ söylüyor (mongodb)"
    prova_calistir "native devir" mongodb
    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad" "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        return 0
    fi
    if [ "$PROVA_RC" -ne 2 ]; then
        t_fail "$ad" "beklenen çıkış 2, gelen $PROVA_RC: $(son_ozet)"
        return 0
    fi
    if grep -qaF "native" "$PROVA_CIKTI" && grep -qa "kendi seçimini" "$PROVA_CIKTI"; then
        t_ok "$ad"
    else
        t_fail "$ad" "çıkış 2 doğru ama gerekçe (katalogdaki failover.note) basılmamış: $(son_ozet)"
    fi
}

kontrol_argumansiz() {
    local ad="motor verilmeden çağrıldığında kullanımı basıp 0 DEĞİL kod dönüyor"
    prova_calistir "argümansız"
    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad" "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
    elif [ "$PROVA_RC" -eq 0 ]; then
        t_fail "$ad" "çıkış 0 — hiçbir şey yapılmadığı hâlde başarı bildiriliyor"
    elif grep -qa 'failover-drill.sh <motor>' "$PROVA_CIKTI"; then
        t_ok "$ad (çıkış $PROVA_RC, kullanım basıldı)"
    else
        t_fail "$ad" "çıkış $PROVA_RC ama kullanım metni yok: $(son_ozet)"
    fi
}

# =============================================================================
# KONTROL — ONAY KAPISI (bu paketin en önemli kontrolü)
# =============================================================================
# Prova, --onayla verilmeden ÜRETİMDE devir yapmamalı. "Yapmadı"yı üç ayrı
# ölçüyle doğruluyoruz; tek başına çıkış kodu yetmez, çünkü devri yapıp sonra
# 5 dönen bir betik de aynı kodu basardı.
kontrol_onay_kapisi() {
    local ad="--onayla YOKKEN üretimde devir YAPMIYOR"
    local ad_plan="plan, eski düğümü geri getirecek komutu yazıyor"
    local once_prim once_damga sonra_prim sonra_damga

    once_prim="$(prim_oku "$MOTOR")"
    once_damga="$(damga_al "$ANA")"
    if [ -z "$once_damga" ]; then
        t_unknown "$ad"      "$ANA docker inspect ile okunamadı — karşılaştırılacak damga yok"
        t_unknown "$ad_plan" "prova çalıştırılamadı"
        return 1
    fi

    prova_calistir "onaysız prova ($MOTOR)" "$MOTOR"

    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad"      "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        t_unknown "$ad_plan" "prova bitmedi"
        return 1
    fi
    if kilit_carpismasi; then
        t_skip "$ad"      "yedekleme kilidi başkasında — prova koşulamadı"
        t_skip "$ad_plan" "prova koşulamadı (kilit başkasında)"
        return 1
    fi

    sonra_prim="$(prim_oku "$MOTOR")"
    sonra_damga="$(damga_al "$ANA")"

    if [ "$PROVA_RC" -eq 3 ]; then
        # Ön koşul yok (replikasyon akmıyor vb.): devir zaten yapılmadı ama
        # ONAY KAPISINI ölçmüş olmuyoruz — bu bir ATLAMA, geçme değil.
        t_skip "$ad" "prova ön koşul bulamadı (çıkış 3): $(son_ozet)"
        t_skip "$ad_plan" "plan basılmadı (çıkış 3)"
        return 1
    fi
    if [ "$PROVA_RC" -ne 5 ]; then
        t_fail "$ad" "beklenen çıkış 5 (onay yok), gelen $PROVA_RC: $(son_ozet)"
    elif [ "$sonra_prim" != "$once_prim" ]; then
        t_fail "$ad" "ONAYSIZ DEVİR YAPILDI: topolojide ana kopya $once_prim → $sonra_prim"
    elif [ "$sonra_damga" != "$once_damga" ]; then
        t_fail "$ad" "ana kopyaya DOKUNULDU: $ANA durumu önce [$once_damga] sonra [$sonra_damga]"
    else
        t_ok "$ad (çıkış 5, ana kopya $once_prim ve StartedAt değişmedi)"
    fi

    kontrol_json_bicimi "onaysız çağrıda da son satır TEK SATIR ve geçerli JSON"

    local ok_alan; ok_alan="$(json_alan ok || true)"
    local kes; kes="$(json_alan downtime_seconds || true)"
    local ad_null="devir yapılmayınca downtime_seconds null (0 DEĞİL)"
    if [ "$ok_alan" != "false" ]; then
        t_fail "$ad_null" "ok=$ok_alan — hiçbir şey yapılmadığı hâlde olumlu görünüyor"
    elif [ "$kes" = "null" ]; then
        # "0 saniye kesinti" ölçülebilecek EN İYİ sonuçtur; ölçülmemiş bir
        # provada 0 basmak, hiç devretmemiş bir yığını "kesintisiz devretti"
        # diye belgelemek olurdu.
        t_ok "$ad_null"
    else
        t_fail "$ad_null" "downtime_seconds=$kes — ölçüm yapılmadan sayı basılmış"
    fi

    # Devrin KALICI olduğunu ve eski düğümün nasıl geri geleceğini söylemek
    # provanın işi: kullanıcı "yedek kopyam nerede" sorusuyla baş başa
    # kalmamalı. Panelde de aynı komut yazıyor.
    if grep -qaF "./stack.sh failover rebuild $MOTOR" "$PROVA_CIKTI" \
       && grep -qa "KALICI" "$PROVA_CIKTI"; then
        t_ok "$ad_plan"
    else
        t_fail "$ad_plan" \
               "planda 'KALICI' uyarısı ya da './stack.sh failover rebuild $MOTOR' komutu yok"
    fi
    return 0
}

# =============================================================================
# KONTROL — REPLİKASYON AKMIYORKEN REDDETME
# =============================================================================
# Senaryoyu YEDEK kopyayı durdurarak üretiyoruz (ana kopyaya dokunulmuyor) ve
# provayı --onayla İLE çağırıyoruz. Onaysız çağırmak bu kapıyı sınamazdı:
# betik zaten onay kapısında dururdu. --onayla ile çağırmak, kapının GERÇEKTEN
# tuttuğunu ölçen tek yoldur.
# RİSK BİLEREK ALINIYOR ve iki katmanla sınırlı: (1) provanın kendi ön koşul
# kapısı, (2) controller'ın devirden önce çalıştırdığı `ready` kontrolü —
# yedek kopya ayakta değilken controller da ana kopyaya dokunmadan reddeder.
kontrol_replikasyon_kapali() {
    local ad="replikasyon akmıyorken prova --onayla ile bile REDDEDİYOR"
    local ad_dokunma="reddederken ana kopyaya DOKUNMUYOR"
    local once_damga sonra_damga once_prim sonra_prim

    once_damga="$(damga_al "$ANA")"
    once_prim="$(prim_oku "$MOTOR")"
    if [ -z "$once_damga" ]; then
        t_unknown "$ad"          "$ANA okunamadı"
        t_unknown "$ad_dokunma"  "$ANA okunamadı"
        return 0
    fi
    if ! dugum_durdur "$YEDEK"; then
        t_unknown "$ad"         "yedek kopya ($YEDEK) durdurulamadı — senaryo ÜRETİLEMEDİ"
        t_unknown "$ad_dokunma" "senaryo üretilemedi"
        return 0
    fi
    t_info "yedek kopya ($YEDEK) geçici olarak durduruldu — replikasyon akmıyor"

    prova_calistir "replikasyon kapalı ($MOTOR --onayla)" "$MOTOR" --onayla

    sonra_damga="$(damga_al "$ANA")"
    sonra_prim="$(prim_oku "$MOTOR")"

    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad"         "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        t_unknown "$ad_dokunma" "prova bitmedi"
    elif kilit_carpismasi; then
        t_skip "$ad"         "yedekleme kilidi başkasında — prova koşulamadı"
        t_skip "$ad_dokunma" "prova koşulamadı"
    elif [ "$PROVA_RC" -eq 3 ]; then
        local d; d="$(json_alan detail || true)"
        if [ -n "$d" ] && [ "$d" != "null" ]; then
            t_ok "$ad (çıkış 3 = ölçülemedi, sebep yazılı)"
        else
            t_fail "$ad" "çıkış 3 doğru ama detail boş — operatör NEDENİNİ göremiyor"
        fi
    elif [ "$PROVA_RC" -eq 0 ]; then
        t_fail "$ad" "ÇIKIŞ 0: replikasyon akmıyorken devir yapılmış ve PROVA GEÇMİŞ sayılmış — senkron olmamış bir düğümü yükseltmek sessiz veri kaybıdır"
    else
        t_fail "$ad" "beklenen çıkış 3, gelen $PROVA_RC: $(son_ozet)"
    fi

    if [ -z "$sonra_damga" ]; then
        t_unknown "$ad_dokunma" "$ANA artık okunamıyor — durumu ÖLÇÜLEMEDİ"
    elif [ "$sonra_prim" != "$once_prim" ]; then
        t_fail "$ad_dokunma" "topolojide ana kopya değişti: $once_prim → $sonra_prim"
    elif [ "$sonra_damga" != "$once_damga" ]; then
        t_fail "$ad_dokunma" "$ANA durumu değişti: önce [$once_damga] sonra [$sonra_damga]"
    else
        t_ok "$ad_dokunma ($ANA, StartedAt değişmedi)"
    fi

    # Senaryoyu geri al: yedeği açıp replikasyonun tekrar akmasını bekliyoruz.
    if ! dugum_baslat "$YEDEK"; then
        t_unknown "gerçek prova" "$YEDEK geri açılamadı — devir provası koşulamaz"
        return 1
    fi
    t_info "yedek kopya ($YEDEK) geri açıldı"
    return 0
}

# =============================================================================
# KONTROL — GERÇEK PROVA
# =============================================================================
gercek_prova_atla() {   # bağlı kontroller RAPOR EDİLİR, sessizce düşürülmez
    local sebep="$1"
    t_skip "gerçek prova: devir yapıldı ve ok=true (çıkış 0)"        "$sebep"
    t_skip "ölçülen kesinti üst sınırın altında (<= $TAVAN sn)"      "$sebep"
    t_skip "devirden sonra E2E kanıt satırı duruyor (veri kaybı yok)" "$sebep"
    t_skip "prova arkasında kalıntı bırakmıyor"                      "$sebep"
}

kontrol_gercek_prova() {
    local ad="gerçek prova: devir yapıldı ve ok=true (çıkış 0)"
    local ad_sure="ölçülen kesinti üst sınırın altında (<= $TAVAN sn)"
    local ad_kanit="devirden sonra E2E kanıt satırı duruyor (veri kaybı yok)"
    local ad_temiz="prova arkasında kalıntı bırakmıyor"
    local once_prim

    # --- kendi kanıt satırımız --------------------------------------------
    if ! kanit_yaz; then
        gercek_prova_atla "E2E kanıt satırı gateway üzerinden yazılamadı (ayrıntı: $E2E_LOG)"
        return 0
    fi
    if ! kanit_oku gw || [ "$KANIT_DEGER" != "$KOSU" ]; then
        gercek_prova_atla "E2E kanıt satırı gateway'den geri okunamadı (okunan: '${KANIT_DEGER:-boş}')"
        return 0
    fi
    # Yedeğe AKTIĞINI görmeden devretmiyoruz: aksi hâlde satırın kaybolması
    # devrin değil, hiç replike olmamış olmanın sonucu olurdu ve provayı
    # haksız yere suçlardık.
    local akti=0 bitis; bitis=$(( $(date +%s) + AKIS_TO ))
    while :; do
        if kanit_oku "$YEDEK" && [ "$KANIT_DEGER" = "$KOSU" ]; then akti=1; break; fi
        [ "$(date +%s)" -ge "$bitis" ] && break
        sleep 2
    done
    if [ "$akti" -ne 1 ]; then
        gercek_prova_atla "E2E kanıt satırı $AKIS_TO sn'de yedeğe ($YEDEK) ulaşmadı — replikasyon akmıyor"
        return 0
    fi
    t_info "E2E kanıt satırı yazıldı ve yedek kopyada ($YEDEK) görüldü"

    once_prim="$(prim_oku "$MOTOR")"
    t_info "GERÇEK DEVİR başlıyor: $MOTOR ($once_prim → $YEDEK). Kısa bir kesinti olacak."

    prova_calistir "gerçek prova ($MOTOR --onayla)" "$MOTOR" --onayla

    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad"       "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        t_unknown "$ad_sure"  "prova bitmedi"
        t_unknown "$ad_kanit" "prova bitmedi"
        t_unknown "$ad_temiz" "prova bitmedi"
        return 0
    fi
    if kilit_carpismasi; then
        gercek_prova_atla "yedekleme kilidi başkasında — prova koşulamadı"
        return 0
    fi
    if [ "$PROVA_RC" -eq 3 ]; then
        gercek_prova_atla "prova ÖLÇEMEDİ (çıkış 3): $(son_ozet)"
        return 0
    fi

    kontrol_json_bicimi "gerçek provada son satır TEK SATIR ve geçerli JSON"

    local ok_alan yeni kes kayip
    ok_alan="$(json_alan ok || true)"
    yeni="$(json_alan new_primary || true)"
    kes="$(json_alan downtime_seconds || true)"
    kayip="$(json_alan data_loss || true)"

    # --- devir gerçekten oldu mu ------------------------------------------
    local topo_yeni; topo_yeni="$(prim_oku "$MOTOR")"
    if [ "$PROVA_RC" -eq 0 ] && [ "$ok_alan" = "true" ]; then
        if [ "$topo_yeni" = "$once_prim" ]; then
            t_fail "$ad" "ok=true ama topolojide ana kopya değişmedi (hâlâ $once_prim) — prova olmayan bir devri raporluyor"
        elif [ "$yeni" != "$topo_yeni" ]; then
            t_fail "$ad" "JSON'daki new_primary=$yeni ile topolojideki $topo_yeni tutmuyor"
        else
            t_ok "$ad ($once_prim → $topo_yeni)"
        fi
    elif [ "$PROVA_RC" -eq 4 ]; then
        # 4 = prova bitti ama temizlik yapılamadı. Cevap doğru olabilir; suçu
        # temizlik kontrolü üstlensin diye ayrı raporluyoruz.
        t_fail "$ad" "çıkış 4: devir oldu ama TEMİZLİK yapılamadı — $(son_ozet)"
    else
        t_fail "$ad" "çıkış $PROVA_RC, ok=${ok_alan:-okunamadı}: $(son_ozet)"
    fi

    # --- kesinti süresi ----------------------------------------------------
    case "${kes:-yok}" in
        yok|null)
            t_unknown "$ad_sure" "downtime_seconds=${kes:-alan yok} — kesinti ÖLÇÜLEMEMİŞ" ;;
        *[!0-9.]*|.|"")
            t_fail "$ad_sure" "downtime_seconds sayı değil: '$kes'" ;;
        *)
            if python3 -c 'import sys
sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' \
                    "$kes" "$TAVAN" 2>/dev/null; then
                t_ok "$ad_sure (ölçülen: ${kes} sn)"
                t_info "kesinti ${kes} sn — bu PLANLI devrin sayısıdır; ana kopya kendiliğinden ölseydi denetleyicinin tespit süresi ($(( ${FAILOVER_STRIKES:-3} * ${FAILOVER_INTERVAL:-10} )) sn) eklenirdi"
            else
                t_fail "$ad_sure" "ölçülen kesinti ${kes} sn > $TAVAN sn — devir tamamlandı ama uygulama bu kadar süre yazamadı (E2E_HA_TAVAN ile değiştirilebilir)"
            fi ;;
    esac

    # --- veri kaybı: BİZİM satırımız --------------------------------------
    if [ "$topo_yeni" = "$once_prim" ]; then
        t_skip "$ad_kanit" "devir olmadı — kanıt satırının yeni ana kopyada aranması anlamsız"
    elif ! kanit_oku "$topo_yeni"; then
        t_unknown "$ad_kanit" "yeni ana kopyada ($topo_yeni) kanıt sorgusu çalışmadı — veri kaybı ÖLÇÜLEMEDİ"
    elif [ "$KANIT_DEGER" = "$KOSU" ]; then
        # Provanın kendi beyanı ile bizim ölçümümüz çelişirse asıl bulgu
        # budur: araç, kaybettiğini kaybetmedim diyor olabilir.
        if [ "$kayip" = "false" ]; then
            t_ok "$ad_kanit (kanıt satırı $topo_yeni içinde duruyor; provanın data_loss=false beyanı da tutuyor)"
        else
            t_ok "$ad_kanit (satır duruyor)"
            t_info "provanın data_loss alanı '$kayip' — bizim satırımız sağlam; prova başka bir yazmanın kaybolduğunu görmüş olabilir (detail: $(json_alan detail || true))"
        fi
    else
        t_fail "$ad_kanit" "VERİ KAYBI: devirden önce COMMIT edilip yedeğe aktığı doğrulanmış satır yeni ana kopyada ($topo_yeni) yok (okunan: '${KANIT_DEGER:-boş}'); provanın beyanı data_loss=$kayip"
    fi

    # --- kalıntı -----------------------------------------------------------
    local etiketli tablo
    etiketli="$(docker ps -aq --filter "label=$ETIKET" 2>/dev/null | wc -l | tr -d '[:space:]')"
    tablo="$(prova_tablosu_durumu)"
    case "${etiketli:-x}" in
        *[!0-9]*) t_unknown "$ad_temiz" "etiket taraması yapılamadı (label=$ETIKET)" ;;
        *) if [ "$etiketli" -ne 0 ]; then
               t_fail "$ad_temiz" "$etiketli adet sonda container'ı duruyor (label=$ETIKET)"
           elif [ "$tablo" = "var" ]; then
               t_fail "$ad_temiz" "provanın $PROVA_TABLO/$PROVA_ANAHTAR kabı üretim veritabanında KALDI"
           elif [ "$tablo" = "sorulamadi" ]; then
               t_unknown "$ad_temiz" "sonda container'ı temiz ama prova tablosunun silinip silinmediği sorulamadı"
           else
               t_ok "$ad_temiz (sonda container'ı yok, $PROVA_TABLO silinmiş)"
           fi ;;
    esac
    return 0
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
BASLANGIC="$(date +%s)"
heading "E2E devir provası — $(date '+%Y-%m-%d %H:%M')"
[ -f "$PROVA" ] || die "$PROVA yok — bu paket onu sınamak için var."
[ -x "$PROVA" ] || t_info "$PROVA çalıştırma izni yok; 'bash' ile çağrılıyor."

t_head "Kapsam, çıkış kodları ve JSON sözleşmesi"
kontrol_kapsam_disi
kontrol_argumansiz
kontrol_native_devir

t_head "Onay kapısı · reddetme · gerçek prova"
if ! docker_yasiyor; then
    t_unknown "--onayla YOKKEN üretimde devir YAPMIYOR" "docker cevap vermiyor"
    t_unknown "replikasyon akmıyorken prova reddediyor"  "docker cevap vermiyor"
    gercek_prova_atla "docker cevap vermiyor"
elif ! container_running controller || ! container_running gateway; then
    t_skip "--onayla YOKKEN üretimde devir YAPMIYOR" \
           "controller ya da gateway çalışmıyor — devri controller yapar, ölçüm gateway'den geçer. Önce: ./stack.sh up"
    t_skip "replikasyon akmıyorken prova reddediyor" "controller/gateway çalışmıyor"
    gercek_prova_atla "controller/gateway çalışmıyor"
elif ! motor_sec; then
    t_skip "--onayla YOKKEN üretimde devir YAPMIYOR" "$SECIM_NOTU"
    t_skip "replikasyon akmıyorken prova reddediyor" "$SECIM_NOTU"
    gercek_prova_atla "$SECIM_NOTU"
else
    AG="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' gateway 2>/dev/null)"
    [ -n "$AG" ] || AG="databases-stack_net"
    t_info "motor: $MOTOR · ana kopya: $ANA · yedek: $YEDEK · adres: gateway:$M_LISTEN · ağ: $AG"

    kontrol_onay_kapisi
    devam=$?

    if [ "$devam" -ne 0 ]; then
        t_skip "replikasyon akmıyorken prova reddediyor" "onay kapısı kontrolü tamamlanamadı"
        gercek_prova_atla "onay kapısı kontrolü tamamlanamadı"
    else
        kontrol_replikasyon_kapali; hazir=$?
        if [ "$hazir" -ne 0 ]; then
            gercek_prova_atla "yedek kopya geri açılamadı"
        elif [ "$DEVIR_YAP" != "1" ]; then
            gercek_prova_atla "E2E_HA_DEVIR=0 — gerçek devir kapalı. Paketin ASIL ölçümü (kesinti süresi) yapılmadı."
        else
            warn "Bu paket ŞİMDİ GERÇEK BİR DEVİR yapacak: $MOTOR ana kopyası durdurulacak."
            warn "Devir KALICIDIR. Sonrasında: ./stack.sh failover rebuild $MOTOR"
            kontrol_gercek_prova
            kanit_sil >/dev/null 2>&1
        fi
    fi
fi

# ------------------------------------------------------------------- özet ---
SURE=$(( $(date +%s) - BASLANGIC ))
t_info "süre: $((SURE / 60))m $((SURE % 60))s"
if [ "$E2E_FAIL" -eq 0 ] && [ "$E2E_UNKNOWN" -eq 0 ]; then
    rm -f "$E2E_LOG"
else
    t_info "komut çıktılarının tamamı: $E2E_LOG"
fi

# Sayaçlar, özet ve ÇIKIŞ KODU ortak kütüphanede (scripts/e2e/lib.sh):
#   0 çalışan kontrollerin hepsi geçti · 1 başarısız/ölçülemedi var
#   2 HİÇBİR KONTROL ÇALIŞMADI · 3 eksik kapsam
e2e_finish
exit $?
