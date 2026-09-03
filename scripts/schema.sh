#!/bin/bash
# =============================================================================
# databases-stack — ŞEMA PARMAK İZİ
# =============================================================================
# Bir veritabanının ŞEKLİNİ tek bir sayıya indirir: hangi tablolar, hangi
# sütunlar, hangi indeksler, kısıtlar, view'lar, trigger'lar ve rutinler var.
# Verinin KENDİSİ parmak izine girmez — bir milyon satır eklemek parmak izini
# değiştirmemelidir.
#
# NEDEN VAR
# Yedekleme ailesi bugün "kaç tablo, kaç satır" diyebiliyor ama "elimdeki bu
# dosya hangi ŞEMAYI geri getirir" sorusuna cevap veremiyordu. O yüzden bir
# indeksin ya da foreign key'in kaybı, prova dahil hiçbir kontrolden
# görünmüyordu. Parmak izi bu soruyu ölçülebilir kılıyor: yedeğin yanına
# yazılır, geri yüklendiğinde yeniden hesaplanır, ikisi karşılaştırılır.
#
# EN BÜYÜK RİSK YALANCI-KIRMIZI
# Aynı şema her koşumda AYNI parmak izini vermeli. Vermezse kullanıcı "şema
# değişti" uyarısını yok saymayı öğrenir ve uyarı ölür — sessiz yeşilin
# aynadaki hâli. Bu yüzden oynak olan her şey BİLEREK dışarıda:
#   • satır/istatistik tahminleri, son autovacuum, sayfa sayısı
#   • MariaDB'de AUTO_INCREMENT sayacı (SHOW CREATE TABLE bunu taşır —
#     tek satır eklemek parmak izini değiştirirdi)
#   • sequence'ın ANLIK değeri (tanımı girer, değeri girmez)
#   • OID ve iç kimlikler (yeniden yükleme farklı OID üretir)
#   • sıralama: her liste ORDER BY ile sabitleniyor, yoksa aynı şema iki
#     koşumda iki farklı metin verirdi
#
# BİÇİM SÜRÜMLENİR (SEMA_SURUM). v1 ile v2 parmak izi karşılaştırılamaz;
# karşılaştırmaya kalkmak dev bir sahte fark üretirdi. Sürüm farkında
# "ölçülemedi" denir.
#
# SALT OKUNURDUR: yalnız katalog ve information_schema görünümleri okunur;
# kullanıcı tablolarına dokunulmaz.
#
# Kullanım:
#   ./scripts/schema.sh <motor> [container]
#
# Çıkış kodları: 0 hesaplandı · 2 kapsam dışı (bu motorda şema yok/yazılmadı)
#                3 ölçülemedi (container kapalı, sorgu düştü)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$STACK_ROOT/scripts/lib/common.sh"
load_env

SEMA_SURUM=1
MOTOR="${1:-}"
C="${2:-}"
OK=false
PARMAK=""
NESNE=""
DETAY="hesaplanmadı"

js() {
    local s="${1:-}"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '"%s"' "$s"
}

json_bas() {
    printf '{"engine":%s,"ok":%s,"version":%s,"fingerprint":%s,"objects":%s,"detail":%s}\n' \
        "$(js "$MOTOR")" "$OK" "$SEMA_SURUM" "$(js "$PARMAK")" \
        "${NESNE:-null}" "$(js "$DETAY")"
}

bitir() { json_bas; exit "$1"; }
kapsam_disi() { DETAY="$*"; bitir 2; }
olcum_yok()   { DETAY="$*"; bitir 3; }

[ -n "$MOTOR" ] || kapsam_disi "motor belirtilmedi. Kullanım: ./scripts/schema.sh <motor>"

# =============================================================================
# KAPSAM — 'şema yok' ile 'ölçmüyoruz' AYRI ŞEYLER
# =============================================================================
# Redis, Kafka ve MinIO'da çevrilecek bir şema yoktur; bunu "ölçemedik" diye
# göstermek panelde yanlış güven ya da yanlış alarm üretirdi. Ayrımı çıkış
# koduyla taşıyoruz: 2 = bu motorda şema kavramı yok/henüz yazılmadı.
sema_var_mi() { declare -F "sema_$1" >/dev/null 2>&1; }

# Sorgu sarmalayıcıları BURADA, prova betiğindekinden ayrı: oradakiler
# provanın kendi zaman aşımını ve günlüğünü kullanıyor. Ortak olan asıl şey
# parolaydı, o da common.sh'a taşındı. Parola komut satırına DEĞİL ortama
# konuyor — host'ta `ps` çıktısında görünmesin.
SEMA_SORGU_SURESI="${SEMA_SORGU_SURESI:-60}"

_zaman() {
    if command -v timeout >/dev/null 2>&1; then timeout -k 5 "$@"; else shift; "$@"; fi
}

my_sorgu() {   # my_sorgu <container> <sql>
    ( export MYSQL_PWD="$(motor_parolasi mariadb)"
      _zaman "$SEMA_SORGU_SURESI" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$2" ) 2>/dev/null
}

pg_sorgu() {   # pg_sorgu <container> <veritabanı> <sql>
    ( export PGPASSWORD="$(motor_parolasi postgresql)"
      _zaman "$SEMA_SORGU_SURESI" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$2" -tAq \
          -v ON_ERROR_STOP=1 -c "$3" ) 2>/dev/null
}

# --------------------------------------------------------------- PostgreSQL --
# Kaynak pg_catalog: pg_get_*def() işlevleri tanımı KANONİK metne çeviriyor —
# elle metin kurmaktan güvenli, çünkü sunucu kendi ayrıştırıcısını kullanıyor.
sema_postgresql() {
    local db out=""
    local dbler
    dbler="$(pg_sorgu "$C" postgres \
        "SELECT datname FROM pg_database WHERE datallowconn
           AND datname NOT IN ('template0','template1') ORDER BY datname")" || return 1
    [ -n "$dbler" ] || return 1
    while IFS= read -r db; do
        db="${db%$'\r'}"
        [ -n "$db" ] || continue
        local p
        p="$(pg_sorgu "$C" "$db" "
          SELECT string_agg(satir, E'\n' ORDER BY satir) FROM (
            SELECT 'T|'||n.nspname||'|'||c.relname||'|'||a.attname||'|'||
                   format_type(a.atttypid, a.atttypmod)||'|'||
                   a.attnotnull::text||'|'||
                   COALESCE(pg_get_expr(d.adbin, d.adrelid), '') AS satir
              FROM pg_attribute a
              JOIN pg_class c ON c.oid = a.attrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
              LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
             WHERE a.attnum > 0 AND NOT a.attisdropped
               AND c.relkind IN ('r','p')
               AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
            UNION ALL
            SELECT 'I|'||n.nspname||'|'||pg_get_indexdef(x.indexrelid)
              FROM pg_index x
              JOIN pg_class c ON c.oid = x.indrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
            UNION ALL
            SELECT 'K|'||n.nspname||'|'||co.conname||'|'||pg_get_constraintdef(co.oid)
              FROM pg_constraint co
              JOIN pg_namespace n ON n.oid = co.connamespace
             WHERE n.nspname NOT IN ('pg_catalog','information_schema')
            UNION ALL
            SELECT 'V|'||n.nspname||'|'||c.relname||'|'||pg_get_viewdef(c.oid, true)
              FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind IN ('v','m')
               AND n.nspname NOT IN ('pg_catalog','information_schema')
            UNION ALL
            SELECT 'G|'||n.nspname||'|'||pg_get_triggerdef(t.oid)
              FROM pg_trigger t
              JOIN pg_class c ON c.oid = t.tgrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE NOT t.tgisinternal
               AND n.nspname NOT IN ('pg_catalog','information_schema')
            UNION ALL
            SELECT 'R|'||n.nspname||'|'||p.proname||'|'||
                   pg_get_function_identity_arguments(p.oid)
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname NOT IN ('pg_catalog','information_schema')
            UNION ALL
            -- Sequence'ın TANIMI girer, ANLIK DEĞERİ girmez: değer her
            -- INSERT'te artar ve parmak izini gürültüye boğardı.
            SELECT 'S|'||sequence_schema||'|'||sequence_name||'|'||data_type
              FROM information_schema.sequences
             WHERE sequence_schema NOT IN ('pg_catalog','information_schema')
          ) s")" || return 1
        out="$out
DB|$db
$p"
    done <<< "$dbler"
    printf '%s' "$out"
}

# ------------------------------------------------------------------ MariaDB --
# SHOW CREATE TABLE KULLANILMIYOR: çıktısı AUTO_INCREMENT=<n> taşıyor ve tek
# satır eklemek parmak izini değiştirirdi. Onun yerine information_schema'dan
# alan alan kuruyoruz; oynak sütunlar (TABLE_ROWS, DATA_LENGTH, AUTO_INCREMENT,
# CREATE_TIME, UPDATE_TIME, CHECKSUM, CARDINALITY) hiç okunmuyor.
sema_mariadb() {
    my_sorgu "$C" "
      SELECT GROUP_CONCAT(satir ORDER BY satir SEPARATOR '\n') FROM (
        SELECT CONCAT_WS('|','T',TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,
                         COLUMN_TYPE,IS_NULLABLE,
                         COALESCE(COLUMN_DEFAULT,''),EXTRA) AS satir
          FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
        UNION ALL
        SELECT CONCAT_WS('|','I',TABLE_SCHEMA,TABLE_NAME,INDEX_NAME,
                         SEQ_IN_INDEX,COLUMN_NAME,NON_UNIQUE,INDEX_TYPE)
          FROM information_schema.STATISTICS
         WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
        UNION ALL
        SELECT CONCAT_WS('|','K',TABLE_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,CONSTRAINT_TYPE)
          FROM information_schema.TABLE_CONSTRAINTS
         WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
        UNION ALL
        SELECT CONCAT_WS('|','F',CONSTRAINT_SCHEMA,TABLE_NAME,CONSTRAINT_NAME,
                         REFERENCED_TABLE_NAME,COALESCE(UPDATE_RULE,''),COALESCE(DELETE_RULE,''))
          FROM information_schema.REFERENTIAL_CONSTRAINTS
         WHERE CONSTRAINT_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
        UNION ALL
        SELECT CONCAT_WS('|','V',TABLE_SCHEMA,TABLE_NAME,VIEW_DEFINITION)
          FROM information_schema.VIEWS
         WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
        UNION ALL
        SELECT CONCAT_WS('|','G',TRIGGER_SCHEMA,TRIGGER_NAME,EVENT_OBJECT_TABLE,
                         ACTION_TIMING,EVENT_MANIPULATION)
          FROM information_schema.TRIGGERS
         WHERE TRIGGER_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
        UNION ALL
        SELECT CONCAT_WS('|','R',ROUTINE_SCHEMA,ROUTINE_NAME,ROUTINE_TYPE,
                         COALESCE(DTD_IDENTIFIER,''))
          FROM information_schema.ROUTINES
         WHERE ROUTINE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')
      ) s"
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
katalogda_var() {
    catalog_query '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("evet" if any(e["id"]==sys.argv[2] for e in c["engines"]) else "")' \
        "$MOTOR" | tr -d '\r'
}

[ -n "$(katalogda_var)" ] || kapsam_disi "Kataloğda böyle bir motor yok: $MOTOR"
sema_var_mi "$MOTOR" || kapsam_disi \
    "$MOTOR için şema parmak izi yazılmadı (bu motorda çevrilecek bir şema olmayabilir)"

command -v docker >/dev/null 2>&1 || olcum_yok "docker bulunamadı"
[ -n "$C" ] || C="$(primary_of "$MOTOR")"
container_running "$C" || olcum_yok "$C çalışmıyor — şema okunamaz"

command -v sha256sum >/dev/null 2>&1 || olcum_yok "sha256sum yok — parmak izi hesaplanamaz"

HAM="$("sema_$MOTOR")" || olcum_yok "$MOTOR şeması okunamadı (sorgu düştü)"
# BOŞ ÇIKTI 'ŞEMA BOŞ' DEMEK DEĞİL: sorgu sessizce hiçbir şey döndürmüş
# olabilir. Boş bir şemanın da en az bir satırı olur (DB| başlığı ya da
# sistem dışı tek tablo); hiç satır yoksa ölçemedik diyoruz.
HAM="$(printf '%s' "$HAM" | tr -d '\r' | grep -v '^$' | LC_ALL=C sort)"
[ -n "$HAM" ] || olcum_yok "$MOTOR şeması boş döndü — okunamadı sayılıyor"

PARMAK="sha256:$(printf '%s\n' "$HAM" | sha256sum | cut -d' ' -f1)"

# Tür başına sayı: parmak izi 'ne kadar değişti' demiyor, sayılar diyor.
NESNE="$(printf '%s\n' "$HAM" | LC_ALL=C awk -F'|' '
    $1=="T" {t[$2"."$3]=1; sutun++}
    $1=="I" {i[$2"."$3"."$4]=1}
    $1=="K" {k++} $1=="F" {f++} $1=="V" {v++} $1=="G" {g++} $1=="R" {r++}
    END {
      nt=0; for (x in t) nt++
      ni=0; for (x in i) ni++
      printf "{\"table\":%d,\"column\":%d,\"index\":%d,\"constraint\":%d,\"foreign_key\":%d,\"view\":%d,\"trigger\":%d,\"routine\":%d}",
             nt, sutun+0, ni, k+0, f+0, v+0, g+0, r+0
    }')"

OK=true
DETAY="$MOTOR şeması okundu ($C)"
bitir 0
