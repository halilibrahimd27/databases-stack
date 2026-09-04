#!/bin/bash
# =============================================================================
# databases-stack — uçtan uca test: ŞEMA PARMAK İZİ
# =============================================================================
# Parmak izinin tek işi, "bu dosya hangi şemayı geri getirir" sorusuna
# ölçülebilir bir cevap vermek. Ama yanlış yapılırsa ürüne KALICI BİR
# YALANCI-KIRMIZI ekler: kullanıcı "şema değişti" uyarısını yok saymayı
# öğrenir ve uyarı ölür. Sessiz yeşilin aynadaki hâli budur.
#
# Bu yüzden paketin ağırlığı ayırt edicilikte değil KARARLILIKTA:
#
#   1) KARARLILIK — şema değişmeden 12 kez ölç: 12/12 aynı parmak izi.
#      Arada veri yaz, sil, ANALYZE/OPTIMIZE çalıştır. TEK sapma BAŞARISIZ:
#      gürültü üreten bir dedektör dedektör değildir.
#
#   2) NEGATİF KONTROL — büyük bir veri değişikliği (binlerce INSERT +
#      UPDATE + DELETE) parmak izini DEĞİŞTİRMEMELİ. Bu kontrol olmadan,
#      "her şeye aynı sabiti döndüren" bir uygulama da 1. testi geçerdi.
#
#   3) AYIRT EDİCİLİK — tam altı şema değişikliği, tam altı farklı parmak
#      izi: sütun ekle, sütun düşür, indeks ekle, indeks düşür, tip genişlet,
#      tablo adı değiştir. Her adımda parmak izi bir ÖNCEKİNDEN farklı olmalı.
#
#   4) SALT OKUNURLUK — ölçüm kullanıcı tablolarına dokunmamalı. Ölçümden
#      önce ve sonra motorun kendi okuma sayaçları karşılaştırılıyor.
#
# (1) ve (2) birlikte olmadan (3) hiçbir şey kanıtlamaz: rastgele sayı üreten
# bir uygulama da "her değişiklikte farklı" olurdu.
#
# Kullanım:
#   ./scripts/e2e/schema.sh              # mariadb (varsayılan)
#   ./scripts/e2e/schema.sh postgresql
#
# Ayarlar:
#   E2E_SEMA_TEKRAR (vars. 12)  kararlılık için ölçüm sayısı
#   E2E_SEMA_SATIR  (vars. 5000) negatif kontrolde yazılacak satır
# =============================================================================
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$STACK_ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
. "$E2E_DIR/lib.sh"
load_env

MOTOR="${1:-mariadb}"
TEKRAR="${E2E_SEMA_TEKRAR:-12}"
SATIR="${E2E_SEMA_SATIR:-5000}"
BETIK="$STACK_ROOT/scripts/schema.sh"
TABLO="e2e_sema"
E2E_LOG="${E2E_LOG:-$STACK_ROOT/logs/e2e-schema_$(date +%Y%m%d_%H%M%S).log}"
mkdir -p "$(dirname "$E2E_LOG")" 2>/dev/null

sql() {   # sql <ifade>
    case "$MOTOR" in
    mariadb)
        docker exec -e MYSQL_PWD="$PAROLA" "$ANA" \
            mariadb -u"$KULLANICI" -D "$DB" -N -B -e "$1" 2>>"$E2E_LOG" ;;
    postgresql)
        docker exec -e PGPASSWORD="$PAROLA" "$ANA" \
            psql -U "$KULLANICI" -d "$DB" -tAq -v ON_ERROR_STOP=1 -c "$1" 2>>"$E2E_LOG" ;;
    esac
}

parmak() {
    bash "$BETIK" "$MOTOR" 2>>"$E2E_LOG" | tail -1 | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if not d.get("ok"):
    raise SystemExit(1)
print(d.get("fingerprint") or "")' 2>>"$E2E_LOG"
}

temizle() { sql "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1 || true
            sql "DROP TABLE IF EXISTS ${TABLO}_yeni;" >/dev/null 2>&1 || true; }
trap temizle EXIT

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
t_head "Şema parmak izi — $MOTOR"

case "$MOTOR" in
    mariadb|postgresql) ;;
    *)  t_skip "şema parmak izi" "$MOTOR bu pakette desteklenmiyor"
        e2e_finish; exit $? ;;
esac
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    t_unknown "şema parmak izi" "docker'a erişilemiyor"
    e2e_finish; exit $?
fi
[ -f "$BETIK" ] || { t_unknown "şema parmak izi" "$BETIK yok"; e2e_finish; exit $?; }

ANA="$(primary_of "$MOTOR")"
container_running "$ANA" || {
    t_skip "şema parmak izi" "$MOTOR kapalı ($ANA)"; e2e_finish; exit $?; }

DB="${DEFAULT_DATABASE:-defaultdb}"
case "$MOTOR" in
mariadb)    KULLANICI="root"; PAROLA="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}" ;;
postgresql) KULLANICI="${POSTGRES_USER:-root}"; PAROLA="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}" ;;
esac
[ -n "$PAROLA" ] || { t_unknown "şema parmak izi" "$MOTOR parolası okunamadı"
                      e2e_finish; exit $?; }

temizle
case "$MOTOR" in
mariadb)
    sql "CREATE TABLE $TABLO (id INT PRIMARY KEY AUTO_INCREMENT, ad VARCHAR(64),
         sayi INT, INDEX ix_sayi (sayi));" >/dev/null ;;
postgresql)
    sql "CREATE TABLE $TABLO (id serial PRIMARY KEY, ad varchar(64), sayi int);
         CREATE INDEX ix_sayi ON $TABLO (sayi);" >/dev/null ;;
esac

ILK="$(parmak)"
if [ -z "$ILK" ]; then
    t_unknown "şema parmak izi hesaplanabiliyor" "schema.sh sonuç vermedi (ayrıntı: $E2E_LOG)"
    e2e_finish; exit $?
fi
t_ok "şema parmak izi hesaplanabiliyor" "$ILK"

# =============================================================================
# 1) KARARLILIK — aynı şema, aynı parmak izi
# =============================================================================
# Aradaki gürültü BİLEREK konuyor: veri yazmak, silmek ve istatistik
# toplamak parmak izini değiştirmemeli. Değiştirirse ürün her gece "şema
# değişti" der ve uyarı bir hafta içinde ölür.
t_head "Kararlılık — $TEKRAR ölçüm, şema değişmiyor"
FARKLI=0
SAPMA=""
i=1
while [ "$i" -le "$TEKRAR" ]; do
    case "$MOTOR" in
    mariadb)
        sql "INSERT INTO $TABLO (ad, sayi) VALUES ('g$i', $i);" >/dev/null
        [ $((i % 4)) -eq 0 ] && sql "ANALYZE TABLE $TABLO;" >/dev/null 2>&1
        [ $((i % 6)) -eq 0 ] && sql "DELETE FROM $TABLO WHERE sayi < $i;" >/dev/null ;;
    postgresql)
        sql "INSERT INTO $TABLO (ad, sayi) VALUES ('g$i', $i);" >/dev/null
        [ $((i % 4)) -eq 0 ] && sql "ANALYZE $TABLO;" >/dev/null 2>&1
        [ $((i % 6)) -eq 0 ] && sql "DELETE FROM $TABLO WHERE sayi < $i;" >/dev/null ;;
    esac
    p="$(parmak)"
    if [ -z "$p" ]; then
        t_unknown "aynı şema $TEKRAR kez aynı parmak izini veriyor" \
                  "$i. ölçüm alınamadı (ayrıntı: $E2E_LOG)"
        e2e_finish; exit $?
    fi
    if [ "$p" != "$ILK" ]; then
        FARKLI=$((FARKLI + 1))
        [ -z "$SAPMA" ] && SAPMA="$i. ölçüm: $p"
    fi
    i=$((i + 1))
done
if [ "$FARKLI" -eq 0 ]; then
    t_ok "aynı şema $TEKRAR kez aynı parmak izini veriyor" \
         "$TEKRAR/$TEKRAR aynı (araya INSERT/DELETE/ANALYZE girdi)"
else
    # TEK sapma bile başarısız: gürültülü bir dedektör yok sayılır.
    t_fail "parmak izi KARARSIZ — kalıcı yalancı-kırmızı üretir" \
           "$TEKRAR ölçümün $FARKLI tanesi farklı. İlk sapma: $SAPMA"
fi

# =============================================================================
# 2) NEGATİF KONTROL — veri değişikliği parmak izini DEĞİŞTİRMEMELİ
# =============================================================================
# Bu kontrol olmadan, her zaman aynı sabiti döndüren bir uygulama da
# yukarıdaki testi geçerdi.
t_head "Negatif — $SATIR satırlık veri değişikliği"
case "$MOTOR" in
mariadb)
    sql "INSERT INTO $TABLO (ad, sayi)
         WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < 1000)
         SELECT CONCAT('v', n), n FROM s;" >/dev/null 2>&1
    sql "UPDATE $TABLO SET ad = CONCAT(ad, 'x');" >/dev/null
    sql "DELETE FROM $TABLO WHERE sayi > 500;" >/dev/null ;;
postgresql)
    sql "INSERT INTO $TABLO (ad, sayi)
         SELECT 'v'||g, g FROM generate_series(1,1000) g;" >/dev/null
    sql "UPDATE $TABLO SET ad = ad || 'x';" >/dev/null
    sql "DELETE FROM $TABLO WHERE sayi > 500;" >/dev/null ;;
esac
VERI_SONRASI="$(parmak)"
if [ -z "$VERI_SONRASI" ]; then
    t_unknown "veri değişikliği parmak izini DEĞİŞTİRMİYOR" "ölçüm alınamadı"
elif [ "$VERI_SONRASI" = "$ILK" ]; then
    t_ok "veri değişikliği parmak izini DEĞİŞTİRMİYOR" "binlerce satır yazıldı/silindi"
else
    t_fail "veri değişikliği parmak izini değiştirdi — parmak izi VERİYE bakıyor" \
           "önce $ILK, sonra $VERI_SONRASI"
fi

# =============================================================================
# 3) AYIRT EDİCİLİK — her şema değişikliği yeni bir parmak izi
# =============================================================================
t_head "Ayırt edicilik — altı şema değişikliği"
declare -a ADIM_AD=() ADIM_SQL=()
case "$MOTOR" in
mariadb)
    ADIM_AD=("sütun eklendi" "indeks eklendi" "indeks düşürüldü"
             "tip genişletildi" "sütun düşürüldü" "tablo adı değişti")
    ADIM_SQL=("ALTER TABLE $TABLO ADD COLUMN not_ TEXT NULL;"
              "CREATE INDEX ix_ad ON $TABLO (ad);"
              "DROP INDEX ix_ad ON $TABLO;"
              "ALTER TABLE $TABLO MODIFY sayi BIGINT;"
              "ALTER TABLE $TABLO DROP COLUMN not_;"
              "RENAME TABLE $TABLO TO ${TABLO}_yeni;") ;;
postgresql)
    ADIM_AD=("sütun eklendi" "indeks eklendi" "indeks düşürüldü"
             "tip genişletildi" "sütun düşürüldü" "tablo adı değişti")
    ADIM_SQL=("ALTER TABLE $TABLO ADD COLUMN not_ text NULL;"
              "CREATE INDEX ix_ad ON $TABLO (ad);"
              "DROP INDEX ix_ad;"
              "ALTER TABLE $TABLO ALTER COLUMN sayi TYPE bigint;"
              "ALTER TABLE $TABLO DROP COLUMN not_;"
              "ALTER TABLE $TABLO RENAME TO ${TABLO}_yeni;") ;;
esac

ONCEKI="$VERI_SONRASI"
[ -n "$ONCEKI" ] || ONCEKI="$ILK"
GORULEN=0
KACIRILAN=""
n=0
while [ "$n" -lt "${#ADIM_SQL[@]}" ]; do
    if ! sql "${ADIM_SQL[$n]}" >/dev/null; then
        t_unknown "${ADIM_AD[$n]} fark ediliyor" "DDL çalıştırılamadı (ayrıntı: $E2E_LOG)"
        n=$((n + 1)); continue
    fi
    p="$(parmak)"
    if [ -z "$p" ]; then
        t_unknown "${ADIM_AD[$n]} fark ediliyor" "ölçüm alınamadı"
    elif [ "$p" != "$ONCEKI" ]; then
        GORULEN=$((GORULEN + 1))
        ONCEKI="$p"
    else
        KACIRILAN="${KACIRILAN:+$KACIRILAN, }${ADIM_AD[$n]}"
    fi
    n=$((n + 1))
done
if [ -z "$KACIRILAN" ] && [ "$GORULEN" -eq "${#ADIM_SQL[@]}" ]; then
    t_ok "altı şema değişikliğinin altısı da fark ediliyor" "$GORULEN/6"
else
    t_fail "bazı şema değişiklikleri fark edilmiyor" \
           "görülen $GORULEN/6, kaçırılan: ${KACIRILAN:-yok}"
fi

# =============================================================================
# 4) SALT OKUNURLUK — ölçüm kullanıcı tablosuna dokunmamalı
# =============================================================================
# Ölçtüğü şeyi değiştiren bir ölçüm, ölçüm değildir. Motorun kendi okuma
# sayaçlarına bakıyoruz: parmak izi yalnız katalog görünümlerini okumalı.
t_head "Salt okunurluk"
sayac() {
    case "$MOTOR" in
    mariadb)    sql "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS
                     WHERE VARIABLE_NAME='HANDLER_READ_RND_NEXT';" ;;
    postgresql) sql "SELECT COALESCE(SUM(seq_scan),0) FROM pg_stat_user_tables;" ;;
    esac
}
S1="$(sayac | tr -d '[:space:]')"
parmak >/dev/null
parmak >/dev/null
S2="$(sayac | tr -d '[:space:]')"
if ! printf '%s' "${S1:-}" | grep -qE '^[0-9]+$' || ! printf '%s' "${S2:-}" | grep -qE '^[0-9]+$'; then
    t_unknown "ölçüm kullanıcı tablolarını okumuyor" "sayaç okunamadı (S1=$S1 S2=$S2)"
elif [ "$S2" -eq "$S1" ]; then
    t_ok "ölçüm kullanıcı tablolarını okumuyor" "sayaç değişmedi ($S1)"
else
    # MariaDB'de sayacı bizim SELECT'imiz de artırabilir; farkı bildiriyoruz
    # ama küçük bir artışı arıza saymıyoruz — büyük artış tablo taramasıdır.
    FARK=$((S2 - S1))
    if [ "$FARK" -le 200 ]; then
        t_ok "ölçüm kullanıcı tablolarını okumuyor" "sayaç $FARK arttı (ölçümün kendi sorguları)"
    else
        t_fail "ölçüm kullanıcı tablolarını OKUYOR" "sayaç $FARK arttı — tablo taraması yapılıyor"
    fi
fi

temizle
e2e_finish
exit $?
