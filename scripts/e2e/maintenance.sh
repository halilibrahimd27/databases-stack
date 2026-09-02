#!/bin/bash
# =============================================================================
# databases-stack — E2E: ŞİŞKİNLİK ÖLÇÜMÜ VE BAKIM (scripts/maintenance.sh)
# =============================================================================
# Bu paketin sorduğu soru "veritabanı şişmiş mi" değil:
#
#     ARAÇ ŞİŞKİNLİĞİ GERÇEKTEN GÖRÜYOR MU, VE BAKIM GERÇEKTEN İŞE
#     YARIYOR MU?
#
# Sebep: bu araç bir SAYI basıyor ve kullanıcı o sayıya bakıp üretim
# tablosunu dakikalarca kilitlemeye razı oluyor. Böyle bir aracın iki
# şekilde zarar vermesi mümkün ve ikisi de sessizdir:
#   1) GÖRMEZ — şişkinliği ölçemez, "0" basar. Kullanıcı diskin neden
#      dolduğunu hiç öğrenemez; araç tam da var oluş sebebini yerine
#      getirmez.
#   2) YALAN SÖYLER — bakımdan sonra "temizlendi" der ama hiçbir şey
#      değişmemiştir. O zaman kullanıcı bir kesintiyi bedavaya vermiş,
#      üstüne sorunu çözdüğünü sanmış olur.
# Bu yüzden buradaki kontroller ARACIN KENDİSİNİ ölçüyor: BİLEREK şişkinlik
# üretiyoruz, aracın onu gördüğünü ve bakımdan sonra düştüğünü sayıyla
# kanıtlıyoruz.
#
# ÖLÇÜLENLER
#   · kapsam dışı motorda 0 DEĞİL anlamlı bir kod dönüyor mu (çıkış 2)
#   · katalogda olmayan motorda ne yapıyor
#   · son satır TEK SATIR ve GEÇERLİ JSON mu (panel bunu okuyacak)
#   · BİLEREK üretilen şişkinliği 'durum' GÖRÜYOR mu
#   · en şişkin tablo listesinde o tablo gerçekten çıkıyor mu (sıralama)
#   · 'durum' hiçbir şeyi DEĞİŞTİRMİYOR mu (öncesi = sonrası)
#   · 'bakim' sonrası ölçülen şişkinlik DÜŞTÜ mü
#   · önce/sonra ölçümü hem ekranda hem JSON'da var mı (bakımın tek kanıtı)
#   · --agresif, --onayla YOKKEN gerçekten HİÇBİR ŞEY YAPMIYOR mu (çıkış 5)
#   · test kendi ürettiği veritabanını SONUNDA siliyor mu
#
# ÜRETİM VERİSİNE DOKUNULMAZ — VE BU TESADÜF DEĞİL:
#   · Test kendi VERİTABANINI yaratır (adı 'e2e_' ile başlar) ve sonunda
#     onu düşürür; üretim şemalarına hiç girmez.
#   · Bakım çağrılarının HEPSİ '--tablo <kendi tablomuz>' ile daraltılmış.
#     Daraltmasaydık 'bakim mariadb --agresif' ÜRETİM tablolarını yeniden
#     kurar ve onları dakikalarca kilitlerdi — testin ölçmeye çalıştığı
#     zararın ta kendisini test yapmış olurdu.
#   · Süzgeçsiz çalıştırılan tek komut 'durum'dur ve o yalnız SELECT
#     çalıştırır.
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/maintenance.sh              çalışan motorların hepsi
#     ./scripts/e2e/maintenance.sh postgresql   yalnız biri
#
# Ayarlar (ortam değişkeni):
#     E2E_BAKIM_SATIR=…    PostgreSQL'de üretilecek satır (varsayılan
#                          200000; ~50 MB şişkinlik demek)
#     E2E_BAKIM_KAT=…      MariaDB'de tablo kaç kez ikiye katlanacak
#                          (varsayılan 17 → 131072 satır, ~35 MB)
#     E2E_BAKIM_BEKLE=…    şişkinliğin ölçülür hâle gelmesi için en çok
#                          kaç saniye beklenecek (varsayılan 120)
#
# ⚠ YAN ETKİ: bu paket motorlarda geçici bir veritabanı yaratıp onlarca MB
#   veri yazar ve siler. Diskte kısa süreliğine yer kullanır; sonunda
#   veritabanını düşürür.
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
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi" \
           "olmadan bu paket ölçüm yapamaz."
E2E_SUITE="maintenance"
source scripts/e2e/lib.sh

ARAC="scripts/maintenance.sh"
# Çalıştırma izni kaybolmuş bir checkout'ta (Windows'tan kopyalanmış depo,
# unzip edilmiş arşiv) "./betik" Permission denied verir. Paket bunu ÜRÜN
# HATASI gibi raporlamasın diye çağrı biçimini burada bir kez seçiyoruz.
ARAC_CAGRI=("./$ARAC")
[ -x "$ARAC" ] || ARAC_CAGRI=(bash "$ARAC")

LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
mkdir -p "$LOG_DIR"
E2E_LOG="$LOG_DIR/e2e-maintenance_$(date +%Y%m%d_%H%M%S).log"
: > "$E2E_LOG"
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-bakim-XXXXXX")" \
    || die "Geçici dizin açılamadı."

SATIR="${E2E_BAKIM_SATIR:-200000}"
KAT="${E2E_BAKIM_KAT:-17}"
BEKLE="${E2E_BAKIM_BEKLE:-120}"
# "Belirgin şişkinlik" eşiği. 4 MB bilerek seçildi: InnoDB alanı EXTENT
# (1 MB) biriminde geri verir, yani birkaç MB'ın altındaki bir fark
# "ölçüm gürültüsü mü, gerçek mi" ayrımını taşımaz.
ESIK=$((4 * 1024 * 1024))

# Kendi adımız. PID'li: aynı makinede iki koşum çakışmasın. 'e2e' ile
# başlıyor ki elde kalan bir kalıntı, üretim veritabanlarından BAKIŞTA
# ayrılabilsin.
E2E_DB="e2e_bakim_$$"
E2E_TABLO="e2e_sisme"

# ------------------------------------------------------------ zaman aşımı ---
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman_asimi() {
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
SURE_SQL="${E2E_BAKIM_SQL_SURESI:-900}"
SURE_ARAC="${E2E_BAKIM_ARAC_SURESI:-1800}"

# Ölçüm ARACI asıldıysa sonuç "ürün yanlış cevap verdi" değil "ÖLÇEMEDİK":
# timeout(1) zaman aşımında 124, -k ile öldürmek zorunda kalınca 137 döner.
asildi_mi() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }
docker_yasiyor() { docker ps -q >/dev/null 2>&1; }

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Parola ORTAMA konuyor, komut satırına değil (backup.sh'taki gerekçe:
# `ps` çıktısı sistemdeki herkese açıktır).
PG_C=""; MY_C=""
pg_calistir() {   # pg_calistir <veritabanı> <sql>
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      zaman_asimi "$SURE_SQL" docker exec -e PGPASSWORD "$PG_C" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$1" \
               -v ON_ERROR_STOP=1 -tAq -c "$2" ) 2>>"$E2E_LOG"
}
my_calistir() {   # my_calistir <sql>
    ( export MYSQL_PWD="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
      zaman_asimi "$SURE_SQL" docker exec -e MYSQL_PWD "$MY_C" \
          mariadb -u root -N -B -e "$1" ) 2>>"$E2E_LOG"
}

# =============================================================================
# ARACI ÇALIŞTIRAN SARMALAYICI
# =============================================================================
# Aracın üç çıktısı ayrı ayrı lazım: çıkış kodu, TAM metin ("önce … sonra …"
# satırı oradan okunuyor) ve SON SATIR (JSON). Boru hattında çıkış kodunun
# kaybolması bu paketlerdeki sahte-yeşilin bir numaralı sebebi olduğu için
# çıktı dosyaya alınıp rc ayrıca saklanıyor.
ARAC_RC=0
ARAC_CIKTI="$E2E_TMP/arac.out"
ARAC_JSON="$E2E_TMP/arac.json"
arac_calistir() {   # arac_calistir <etiket> <argümanlar…>
    local ne="$1"; shift
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$ne"
      printf 'komut: %s %s\n' "${ARAC_CAGRI[*]}" "$*"; } >> "$E2E_LOG"
    ARAC_RC=0
    # stdin /dev/null: araç onay sorabiliyor. Terminal olmayan bir ortamda
    # sonsuza kadar asılı kalmasını engellemenin yanı sıra, "--onayla
    # yoksa hiçbir şey yapma" kuralını da tam olarak bu koşulda sınıyoruz.
    zaman_asimi "$SURE_ARAC" "${ARAC_CAGRI[@]}" "$@" \
        > "$ARAC_CIKTI" 2>&1 < /dev/null || ARAC_RC=$?
    cat "$ARAC_CIKTI" >> "$E2E_LOG"
    tail -n 1 "$ARAC_CIKTI" > "$ARAC_JSON" 2>/dev/null
    return 0
}

son_ozet() {
    tr -d '\r' < "$ARAC_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' \
        | tail -n 2 | tr '\n' ' '
}
kilit_carpismasi() {
    grep -qaF "kilidi başkasında" "$ARAC_CIKTI" 2>/dev/null
}

# JSON'dan tek alan. rc=2 → dosya JSON DEĞİL (bu da bir bulgudur, ayrı
# raporlanır); rc=3 → alan yok.
json_alan() {   # json_alan <alan>
    python3 - "$ARAC_JSON" "$1" <<'PY'
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

# tables[] içinde ADI verilen tablonun bloat_bytes değeri. Sıra numarasına
# değil ADA bakıyoruz: sıralama değişse bile doğru satırı buluruz, yanlış
# satırı okuyup "şişkinlik düşmedi" demeyiz.
json_tablo_bos() {   # json_tablo_bos <ad>
    python3 - "$ARAC_JSON" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
for t in (d.get("tables") or []):
    if t.get("name") == sys.argv[2]:
        v = t.get("bloat_bytes")
        if v is None:
            sys.exit(3)
        print(int(v)); sys.exit(0)
sys.exit(4)
PY
}

json_tablo_var() {   # json_tablo_var <ad> → 0 varsa
    python3 - "$ARAC_JSON" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
names = [t.get("name") for t in (d.get("tables") or [])]
sys.exit(0 if sys.argv[2] in names else 1)
PY
}

json_en_kucuk_bos() {   # listedeki en küçük bloat_bytes
    python3 - "$ARAC_JSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
vals = [t.get("bloat_bytes") for t in (d.get("tables") or [])]
vals = [int(v) for v in vals if v is not None]
if not vals:
    sys.exit(3)
print(min(vals))
PY
}

sayi_mi() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Aracın kendi ölçümüyle tek tablonun şişkinliğini okur. ARACIN KENDİSİNİ
# kullanıyoruz, ayrı bir sorgu yazmıyoruz: ölçtüğümüz şey zaten aracın
# verdiği sayıdır. Kendi sorgumuzu yazsaydık "benim sorgum ne diyor"u
# ölçerdik, aracın doğruluğunu değil.
olcum_al() {   # olcum_al <motor> <tam ad> → bloat_bytes (stdout)
    arac_calistir "durum $1 --tablo $2" durum "$1" --tablo "$2"
    [ "$ARAC_RC" -eq 0 ] || return 1
    json_tablo_bos "$2"
}

# Şişkinlik ANINDA ölçülür hâle gelmez: PostgreSQL istatistikleri işlem
# bittikten sonra bildirir, InnoDB ise silinen sayfaları purge iş parçacığı
# çalıştıkça boş extent'e çevirir. Sabit bir sleep ile beklemek ya çok kısa
# (test tutarsız düşer) ya çok uzun (paket boşuna dakikalar harcar) olurdu.
sisme_bekle() {   # sisme_bekle <motor> <tam ad> <hedef bayt> → son ölçüm
    local motor="$1" ad="$2" hedef="$3" basla son="" v
    basla=$(date +%s)
    while :; do
        v="$(olcum_al "$motor" "$ad")" && son="$v"
        if sayi_mi "${son:-}" && [ "$son" -ge "$hedef" ]; then
            printf '%s' "$son"; return 0
        fi
        [ $(( $(date +%s) - basla )) -ge "$BEKLE" ] && break
        sleep 5
    done
    printf '%s' "${son:-}"
    return 1
}

# =============================================================================
# TEST VERİSİ — BİLEREK ŞİŞKİNLİK ÜRETMEK
# =============================================================================
PG_KURULDU=0
MY_KURULDU=0

# PostgreSQL: satırları yaz, sonra HEPSİNİ SİL. Silinen satırlar dosyadan
# gitmez, "ölü satır" olarak kalır — ölçmek istediğimiz şişkinlik tam budur.
#
# autovacuum_enabled = false ŞART. Bu kadar satır silindiğinde autovacuum'un
# eşiği (50 + %20) kesinlikle aşılır ve arka planda koşup ölü satırları
# temizler. O zaman test ya "durum şişkinliği görmedi" (oysa şişkinlik
# gerçekten kalmamıştır) ya da "bakım işe yaradı" (oysa işi autovacuum
# yapmıştır) der. İki hâlde de ARACI değil, PostgreSQL'in zamanlamasını
# ölçmüş oluruz. Ayar YALNIZ BU TABLOYA konuyor; sunucu ayarına dokunmuyoruz.
pg_veri_kur() {
    pg_calistir postgres "DROP DATABASE IF EXISTS $E2E_DB;" >/dev/null 2>&1
    pg_calistir postgres "CREATE DATABASE $E2E_DB;" >/dev/null || return 1
    PG_KURULDU=1
    pg_calistir "$E2E_DB" "
        CREATE TABLE public.$E2E_TABLO (
            id bigserial PRIMARY KEY,
            dolgu text NOT NULL
        ) WITH (autovacuum_enabled = false);" >/dev/null || return 1
    pg_calistir "$E2E_DB" "
        INSERT INTO public.$E2E_TABLO (dolgu)
        SELECT repeat('x', 200) FROM generate_series(1, $SATIR);" \
        >/dev/null || return 1
    return 0
}
pg_veri_sil() {
    pg_calistir "$E2E_DB" "DELETE FROM public.$E2E_TABLO;" >/dev/null
}

# MariaDB: aynı fikir, ikiye katlayarak. generate_series yerine
# INSERT … SELECT kullanıyoruz — MariaDB'nin sequence eklentisi her kurulumda
# etkin değil, ama INSERT … SELECT her sürümde çalışır.
my_veri_kur() {
    local i sql=""
    my_calistir "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null 2>&1
    my_calistir "CREATE DATABASE \`$E2E_DB\`;" >/dev/null || return 1
    MY_KURULDU=1
    my_calistir "
        CREATE TABLE \`$E2E_DB\`.\`$E2E_TABLO\` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            dolgu CHAR(255) NOT NULL
        ) ENGINE=InnoDB;" >/dev/null || return 1
    my_calistir "INSERT INTO \`$E2E_DB\`.\`$E2E_TABLO\` (dolgu)
                 VALUES (REPEAT('x', 255));" >/dev/null || return 1
    for i in $(seq 1 "$KAT"); do
        sql="$sql INSERT INTO \`$E2E_DB\`.\`$E2E_TABLO\` (dolgu)
                  SELECT dolgu FROM \`$E2E_DB\`.\`$E2E_TABLO\`;"
    done
    my_calistir "$sql" >/dev/null || return 1
    return 0
}
my_veri_sil() {
    my_calistir "DELETE FROM \`$E2E_DB\`.\`$E2E_TABLO\`;" >/dev/null
}

# ---------------------------------------------------------------- temizlik --
# HER DURUMDA çalışır (başarı, hata, Ctrl+C). Bıraktığımız bir veritabanı
# üretim diskinde onlarca MB yer tutar ve kimse ne olduğunu bilmez.
TEMIZLIK_YAPILDI=0
PG_TEMIZ=""; MY_TEMIZ=""
temizle() {
    [ "$TEMIZLIK_YAPILDI" -eq 1 ] && return 0
    TEMIZLIK_YAPILDI=1
    if [ "$PG_KURULDU" -eq 1 ] && [ -n "$PG_C" ]; then
        # WITH (FORCE) açık bağlantıları koparır (PostgreSQL 13+). Eski
        # sürümde bu söz dizimi hata verir; o yüzden düz DROP'a düşüyoruz.
        pg_calistir postgres "DROP DATABASE IF EXISTS $E2E_DB WITH (FORCE);" \
            >/dev/null 2>&1 \
            || pg_calistir postgres "DROP DATABASE IF EXISTS $E2E_DB;" \
                 >/dev/null 2>&1
        PG_TEMIZ="$(pg_calistir postgres \
            "SELECT count(*) FROM pg_database WHERE datname = '$E2E_DB';" \
            2>/dev/null | tr -d '\r[:blank:]')"
    fi
    if [ "$MY_KURULDU" -eq 1 ] && [ -n "$MY_C" ]; then
        my_calistir "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null 2>&1
        MY_TEMIZ="$(my_calistir "SELECT COUNT(*) FROM
            information_schema.SCHEMATA WHERE SCHEMA_NAME = '$E2E_DB';" \
            2>/dev/null | tr -d '\r[:blank:]')"
    fi
    rm -rf "$E2E_TMP" 2>/dev/null
    return 0
}
trap 'temizle' EXIT

# =============================================================================
# KONTROLLER — kapsam ve çıkış kodları
# =============================================================================
# Bu üç kontrol docker'a ihtiyaç duymaz (araç motor kapsamını catalog.json'dan
# çözer, docker'a ancak ondan sonra bakar). Bilerek en başta: motorlar
# tamamen kapalıyken bile paket EN AZ BİR ŞEY ölçmüş olur; yoksa "hiçbir
# kontrol çalışmadı" (çıkış 2) ile "her şey yeşil" ayrımı kaybolurdu.
kontrol_kapsam_disi() {
    local ad="kapsam dışı motor 0 DEĞİL anlamlı bir kod döndürüyor (cassandra)"
    arac_calistir "kapsam dışı motor" durum cassandra
    if asildi_mi "$ARAC_RC"; then
        t_unknown "$ad" "araç $SURE_ARAC sn içinde bitmedi (rc=$ARAC_RC)"
        return 0
    fi
    if [ "$ARAC_RC" -eq 2 ]; then
        t_ok "$ad — çıkış 2 (kapsam dışı), hata koduyla karışmıyor"
    elif [ "$ARAC_RC" -eq 0 ]; then
        t_fail "$ad" \
            "çıkış 0: bakımı OLMAYAN bir motor BAŞARILI görünüyor"
    else
        t_fail "$ad" "beklenen çıkış 2, gelen $ARAC_RC: $(son_ozet)"
    fi

    local ad2="kapsam dışı çağrıda da son satır JSON (panel boş görmüyor)"
    local ok_alan kuyruk
    if ! ok_alan="$(json_alan ok)"; then
        kuyruk="$(tail -c 200 "$ARAC_JSON" | tr -d '\r\n')"
        t_fail "$ad2" "son satır geçerli JSON değil: $kuyruk"
    elif [ "$ok_alan" = "false" ]; then
        t_ok "$ad2"
    else
        t_fail "$ad2" "ok=$ok_alan — ölçüm yapılmadığı hâlde olumlu görünüyor"
    fi
}

kontrol_bilinmeyen_motor() {
    local ad="katalogda olmayan motorda anlamlı kod (yokmotor)"
    arac_calistir "bilinmeyen motor" durum yokmotor
    if asildi_mi "$ARAC_RC"; then
        t_unknown "$ad" "araç $SURE_ARAC sn içinde bitmedi (rc=$ARAC_RC)"
    elif [ "$ARAC_RC" -eq 2 ]; then
        t_ok "$ad — çıkış 2"
    elif [ "$ARAC_RC" -eq 0 ]; then
        t_fail "$ad" "çıkış 0 — olmayan bir motor için başarı bildiriliyor"
    else
        t_fail "$ad" "beklenen çıkış 2, gelen $ARAC_RC: $(son_ozet)"
    fi
}

# =============================================================================
# KONTROLLER — asıl ölçüm (motor başına)
# =============================================================================
motor_kontrolleri() {   # motor_kontrolleri <motor> <container> <tam ad>
    local motor="$1" C="$2" ad="$3"
    local n_gor="[$motor] BİLEREK üretilen şişkinliği 'durum' görüyor"
    local n_sira="[$motor] şişkin tablo, en şişkinler listesinde çıkıyor"
    local n_deg="[$motor] 'durum' hiçbir şeyi değiştirmiyor"
    local n_onay="[$motor] --agresif, --onayla yokken HİÇBİR ŞEY yapmıyor"
    local n_dus="[$motor] 'bakim' sonrası ölçülen şişkinlik DÜŞTÜ"
    local n_kanit="[$motor] önce/sonra ölçümü ekranda ve JSON'da var"
    local once sonra v en_kucuk agr_args=() jonce jsonra

    # --- 1) şişkinlik üret ---------------------------------------------------
    # Tablo yukarıda (çağıran döngüde) yaratılıp dolduruldu. Şişkinlik
    # SİLMEYLE doğuyor: iki motorda da silinen satırların yeri dosyada
    # kalır, geri verilmez.
    t_info "$motor: satırlar siliniyor (şişkinlik burada doğuyor)…"
    case "$motor" in
        postgresql) pg_veri_sil ;;
        mariadb)    my_veri_sil ;;
    esac

    once="$(sisme_bekle "$motor" "$ad" "$ESIK")" || true
    if ! sayi_mi "${once:-}"; then
        t_unknown "$n_gor"   "aracın ölçümü okunamadı (ayrıntı: $E2E_LOG)"
        t_unknown "$n_sira"  "ölçüm alınamadı"
        t_unknown "$n_deg"   "ölçüm alınamadı"
        t_unknown "$n_onay"  "ölçüm alınamadı"
        t_unknown "$n_dus"   "ölçüm alınamadı"
        t_unknown "$n_kanit" "ölçüm alınamadı"
        return 0
    fi
    if [ "$once" -lt "$ESIK" ]; then
        # Şişkinlik oluşmadı: bu ARACIN hatası olabilir de olmayabilir de
        # (InnoDB purge yetişmemiş olabilir). Ölçemediğimizi söylüyoruz,
        # "geçti" demiyoruz — "bilmiyorum" ile "iyi" aynı şey değil.
        t_unknown "$n_gor" \
            "$BEKLE sn içinde $ESIK bayt eşiği aşılmadı (ölçülen $once)"
        t_unknown "$n_sira"  "şişkinlik oluşmadı"
        t_unknown "$n_deg"   "şişkinlik oluşmadı"
        t_unknown "$n_onay"  "şişkinlik oluşmadı"
        t_unknown "$n_dus"   "şişkinlik oluşmadı"
        t_unknown "$n_kanit" "şişkinlik oluşmadı"
        return 0
    fi
    t_ok "$n_gor ($once bayt / $((once / 1048576)) MB)"

    # --- 2) sıralama: süzgeçsiz listede çıkıyor mu ---------------------------
    arac_calistir "durum $motor --adet 100" durum "$motor" --adet 100
    if [ "$ARAC_RC" -ne 0 ]; then
        t_unknown "$n_sira" "süzgeçsiz 'durum' çıkış $ARAC_RC: $(son_ozet)"
    elif json_tablo_var "$ad"; then
        t_ok "$n_sira"
    else
        # Listede yoksa iki ihtimal var ve ayırt etmek şart: ya sıralama
        # yanlış (bulgu), ya da üretimde bizden şişkin 100 tablo var
        # (meşru). En küçük listelenen değerle karşılaştırıyoruz.
        en_kucuk="$(json_en_kucuk_bos)" || en_kucuk=""
        if sayi_mi "${en_kucuk:-}" && [ "$once" -gt "$en_kucuk" ]; then
            t_fail "$n_sira" \
                "$once baytlık tablomuz yok, $en_kucuk baytlık biri var"
        else
            t_skip "$n_sira" \
                "üretimde daha şişkin 100 tablo var; sıralama sınanamadı"
        fi
    fi

    # --- 3) 'durum' bir şey değiştirmiyor mu --------------------------------
    v="$(olcum_al "$motor" "$ad")" || v=""
    if ! sayi_mi "${v:-}"; then
        t_unknown "$n_deg" "ikinci ölçüm okunamadı"
    elif [ "$v" -eq "$once" ]; then
        t_ok "$n_deg (iki ölçüm de $once bayt)"
    else
        # Küçük bir oynama motorun kendi arka plan işi olabilir; ama
        # 'durum' bir şey yapmıyorsa BÜYÜK bir düşüş olmamalı.
        if [ "$v" -lt $((once / 2)) ]; then
            t_fail "$n_deg" \
                "yalnız okuyan 'durum'dan sonra şişkinlik $once → $v"
        else
            t_ok "$n_deg (küçük oynama: $once → $v, motorun arka plan işi)"
        fi
    fi

    # --- 4) --agresif, onay yokken hiçbir şey yapmamalı ----------------------
    # stdin /dev/null olduğu için araç soru soramaz; --onayla da vermiyoruz.
    # Beklenen: çıkış 5 ve ŞİŞKİNLİKTE DEĞİŞİKLİK YOK.
    arac_calistir "bakim $motor --agresif (onaysız)" \
        bakim "$motor" --tablo "$ad" --agresif
    v="$(olcum_al "$motor" "$ad")" || v=""
    if [ "$ARAC_RC" -ne 5 ]; then
        t_fail "$n_onay" \
            "beklenen çıkış 5 (onay yok), gelen $ARAC_RC: $(son_ozet)"
    elif ! sayi_mi "${v:-}"; then
        t_unknown "$n_onay" "onaysız çağrıdan sonraki ölçüm okunamadı"
    elif [ "$v" -lt $((once / 2)) ]; then
        t_fail "$n_onay" \
            "çıkış 5 dedi ama şişkinlik $once → $v düştü: ONAYSIZ İŞ YAPILMIŞ"
    else
        t_ok "$n_onay (çıkış 5, şişkinlik $v bayt olarak duruyor)"
    fi

    # --- 5) asıl bakım -------------------------------------------------------
    # PostgreSQL'de VARSAYILAN yol (VACUUM ANALYZE) ölçülen şişkinliği zaten
    # sıfırlar ve tabloyu KİLİTLEMEZ — sınanacak doğru yol odur.
    # MariaDB'de varsayılan ANALYZE TABLE yalnız istatistik tazeler,
    # DATA_FREE'ye dokunmaz; oradaki düşüşü ancak OPTIMIZE TABLE yapar. Bu
    # yüzden MariaDB'de agresif yol sınanıyor — ve YALNIZ KENDİ tablomuzda:
    # üretim tablosunu kilitlemek bu paketin işi değil.
    case "$motor" in
        mariadb) agr_args=(--agresif --onayla) ;;
        *)       agr_args=() ;;
    esac
    arac_calistir "bakim $motor" \
        bakim "$motor" --tablo "$ad" ${agr_args[@]+"${agr_args[@]}"}

    if asildi_mi "$ARAC_RC"; then
        t_unknown "$n_dus"   "bakım $SURE_ARAC sn içinde bitmedi"
        t_unknown "$n_kanit" "bakım bitmedi"
        return 0
    fi
    if kilit_carpismasi; then
        t_skip "$n_dus"   "yedekleme/bakım kilidi başkasında"
        t_skip "$n_kanit" "yedekleme/bakım kilidi başkasında"
        return 0
    fi
    if [ "$ARAC_RC" -ne 0 ]; then
        t_fail "$n_dus" "bakım çıkış $ARAC_RC: $(son_ozet)"
        t_fail "$n_kanit" "bakım düştüğü için önce/sonra kanıtı yok"
        return 0
    fi

    jonce="$(json_alan before_bloat_bytes)"  || jonce=""
    jsonra="$(json_alan after_bloat_bytes)"  || jsonra=""
    # BAKIMIN EKRAN ÇIKTISI KENARA ALINIYOR. Aşağıdaki olcum_al aracı bir
    # kez daha çağırıyor ve $ARAC_CIKTI'yı ÜZERİNE YAZIYOR; kopyalamasaydık
    # "önce … sonra …" satırını 'durum' çıktısında arar ve bulamazdık.
    # (Bu satır tam olarak o yüzden eklendi: paket ilk koşumunda bakımın
    # kanıt satırını "yok" diye raporladı, oysa satır basılmıştı.)
    cp -f "$ARAC_CIKTI" "$E2E_TMP/bakim.out" 2>/dev/null
    sonra="$(olcum_al "$motor" "$ad")" || sonra=""

    if ! sayi_mi "${sonra:-}"; then
        t_unknown "$n_dus" "bakım sonrası bağımsız ölçüm okunamadı"
    elif [ "$sonra" -lt $((once / 2)) ]; then
        t_ok "$n_dus (önce $once bayt → sonra $sonra bayt)"
    else
        t_fail "$n_dus" \
            "bakım 0 ile çıktı ama şişkinlik düşmedi: önce $once, sonra $sonra"
    fi

    # Önce/sonra ölçümü BAKIMIN İŞE YARADIĞININ TEK KANITI. Hem insanın
    # okuduğu satırda hem panelin okuduğu JSON'da bulunmalı: biri eksikse
    # iki okuyucudan biri kanıtsız kalır.
    local ekranda=0 bkm="$E2E_TMP/bakim.out"
    grep -qa 'önce' "$bkm" && grep -qa 'sonra' "$bkm" && ekranda=1
    if [ "$ekranda" -ne 1 ]; then
        t_fail "$n_kanit" "ekranda 'önce … sonra …' satırı yok"
    elif ! sayi_mi "${jonce:-}" || ! sayi_mi "${jsonra:-}"; then
        t_fail "$n_kanit" \
            "JSON before=${jonce:-yok} after=${jsonra:-yok} — biri sayı değil"
    elif [ "$jsonra" -lt "$jonce" ]; then
        t_ok "$n_kanit (JSON: $jonce → $jsonra bayt)"
    else
        t_fail "$n_kanit" \
            "JSON önce=$jonce sonra=$jsonra — sonraki ölçüm düşmemiş"
    fi
}

# =============================================================================
# KONTROL — üretime dokunulmadı
# =============================================================================
# Ölçüt State.StartedAt: araç üretim container'ını yeniden başlatsaydı bu
# damga değişirdi. Ayrıca hâlâ ÇALIŞIYOR olmalı — durdurulmuş bir
# container'ın StartedAt'i de değişmez, o yüzden ikisine birden bakıyoruz.
damga_al() { docker inspect -f '{{.State.StartedAt}}|{{.State.Running}}' \
             "$1" 2>/dev/null; }
kontrol_dokunulmadi() {   # <ad> <container> <önceki damga>
    local ad="$1" C="$2" once="$3" sonra
    if [ -z "$once" ]; then
        t_skip "$ad" "$C bu koşumun başında çalışmıyordu"
        return 0
    fi
    sonra="$(damga_al "$C")"
    if [ -z "$sonra" ]; then
        t_unknown "$ad" "$C artık docker inspect ile okunamıyor"
    elif [ "$once" = "$sonra" ]; then
        t_ok "$ad ($C, StartedAt değişmedi)"
    else
        t_fail "$ad" "$C durumu değişti: önce [$once] sonra [$sonra]"
    fi
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
BASLANGIC="$(date +%s)"
heading "E2E şişkinlik ölçümü ve bakım — $(date '+%Y-%m-%d %H:%M')"
[ -f "$ARAC" ] || die "$ARAC yok — bu paket onu sınamak için var."
[ -x "$ARAC" ] || t_info "$ARAC çalıştırma izni yok; 'bash' ile çağrılacak."
t_info "günlük: $E2E_LOG"

t_head "Kapsam ve çıkış kodları"
kontrol_kapsam_disi
kontrol_bilinmeyen_motor

# Hangi motorlar? Argüman verildiyse yalnız o.
SECILEN="${1:-mariadb postgresql}"
case "$SECILEN" in
    mariadb|postgresql|"mariadb postgresql") ;;
    *) die "Bu pakette yalnız mariadb ve postgresql sınanır: $SECILEN" ;;
esac

t_head "Şişkinlik üret → gör → temizle"
if ! docker_yasiyor; then
    t_unknown "şişkinlik üretildi ve ölçüldü" "docker cevap vermiyor"
else
    OLCULEN=0
    for M in $SECILEN; do
        C="$(primary_of "$M")"
        if ! container_running "$C"; then
            t_skip "[$M] şişkinlik üretildi ve ölçüldü" \
                   "$M kapalı (container: $C)"
            continue
        fi
        case "$M" in
            postgresql) PG_C="$C" ;;
            mariadb)    MY_C="$C" ;;
        esac
        DAMGA="$(damga_al "$C")"

        # Tam ad biçimi motora göre değişiyor; araç da adları böyle basıyor.
        case "$M" in
            postgresql) TAM="$E2E_DB.public.$E2E_TABLO" ;;
            mariadb)    TAM="$E2E_DB.$E2E_TABLO" ;;
        esac

        t_head "$M — $TAM"
        KURULDU=1
        case "$M" in
            postgresql) pg_veri_kur || KURULDU=0 ;;
            mariadb)    my_veri_kur || KURULDU=0 ;;
        esac
        if [ "$KURULDU" -ne 1 ]; then
            t_unknown "[$M] test verisi kurulamadı" \
                      "geçici veritabanı yaratılamadı (ayrıntı: $E2E_LOG)"
            continue
        fi
        motor_kontrolleri "$M" "$C" "$TAM"
        kontrol_dokunulmadi "[$M] üretim container'ına dokunulmadı" \
                            "$C" "$DAMGA"
        OLCULEN=$((OLCULEN + 1))
    done
    [ "$OLCULEN" -eq 0 ] && t_info "hiçbir motor ölçülemedi (hepsi kapalı)"
fi

# =============================================================================
# TEMİZLİK — testin kendi ürettiğini geri alması
# =============================================================================
# Bu kontrol paketin en sonunda, çünkü ölçtüğü şey testin KENDİ davranışı:
# ürettiği veritabanını gerçekten sildi mi. Silmeseydi üretim diskinde
# onlarca MB'lık, adı 'e2e_' ile başlayan bir kalıntı kalır ve bir sonraki
# 'durum' onu "şişkin tablo" diye raporlardı.
t_head "Temizlik"
temizle
if [ "$PG_KURULDU" -eq 1 ]; then
    case "$PG_TEMIZ" in
        0) t_ok "[postgresql] test veritabanı ($E2E_DB) silindi" ;;
        '') t_unknown "[postgresql] test veritabanı silindi" \
                      "silinip silinmediği doğrulanamadı" ;;
        *) t_fail "[postgresql] test veritabanı silindi" \
                  "$E2E_DB hâlâ duruyor — elle silin: DROP DATABASE $E2E_DB" ;;
    esac
fi
if [ "$MY_KURULDU" -eq 1 ]; then
    case "$MY_TEMIZ" in
        0) t_ok "[mariadb] test veritabanı ($E2E_DB) silindi" ;;
        '') t_unknown "[mariadb] test veritabanı silindi" \
                      "silinip silinmediği doğrulanamadı" ;;
        *) t_fail "[mariadb] test veritabanı silindi" \
                  "$E2E_DB hâlâ duruyor — elle silin: DROP DATABASE $E2E_DB" ;;
    esac
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
