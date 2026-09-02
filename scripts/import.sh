#!/bin/bash
# =============================================================================
# databases-stack — VAR OLAN VERİYİ İÇE AKTARMA
# =============================================================================
# Kullanım:
#   ./scripts/import.sh <motor> <dosya>          yerel dump dosyası
#   ./scripts/import.sh <motor> --kaynak <URI>   uzak CANLI kaynaktan çek
#
# NEDEN VAR: ürün bugüne kadar yalnız BOŞ veritabanı açıyordu. Oysa gerçek
# kullanıcının verisi zaten bir yerde: eski bir sunucuda ya da elindeki
# dump.sql'de. Panelden MariaDB açan kullanıcı verisini taşımak için komut
# satırına düşüyor ve orada `mysql < dump.sql` yazıp KEMERSİZ çalışıyordu —
# hedefte veri var mı diye bakmadan, geri dönüş noktası almadan, dosyanın
# hangi motorun dump'ı olduğunu doğrulamadan.
#
# BEŞ KEMER (bu betiğin bütün varlık sebebi):
#   1. Hedef boş değilse REDDEDER ve ne bulduğunu söyler; --uzerine-yaz ile
#      bilerek geçilir.
#   2. Üzerine yazmadan ÖNCE backup.sh ile güvenlik yedeği alır ve dosya
#      adını ekrana yazar — "yanlış dosyayı aktardım" anında dönülecek nokta.
#   3. Motor kapalıysa anlamlı hata verir.
#   4. Biçimi TAHMİN ETMEZ, DOĞRULAR. PostgreSQL dump'ını MariaDB'ye basmak
#      sessiz bir felakettir; doğrulayamıyorsa reddeder.
#   5. Bitince özet: kaç şema/tablo/satır geldi, ne kadar sürdü, kaç bayt.
#
# ÇIKIŞ KODLARI — panel ve e2e paketi bunlara bakar, DEĞİŞTİRMEYİN:
#   0  aktarıldı
#   1  aktarma sırasında hata (veri yarım kalmış olabilir)
#   2  kullanım hatası (eksik argüman, dosya yok, bilinmeyen motor)
#   3  KAPSAM DIŞI (bu motora içe aktarma yok / uzak kaynak desteklenmiyor)
#   4  BİÇİM (dosya bu motorun dump'ı değil ya da hangi motorun olduğu belli
#      değil)
#   5  HEDEF DOLU (--uzerine-yaz verilmedi)
#   6  motor kapalı
#   7  güvenlik yedeği alınamadı — üzerine yazma YAPILMADI
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
load_env

KOD_HATA=1; KOD_KULLANIM=2; KOD_KAPSAM=3; KOD_BICIM=4
KOD_DOLU=5; KOD_KAPALI=6; KOD_YEDEK=7

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/import_$(date +%Y%m%d).log"

ilog() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
# Hata + ÇIKIŞ KODU tek yerde. die() her zaman 1 ile çıkar; burada kodun
# kendisi bilgi taşıdığı için (panel "hedef dolu" ile "biçim yanlış"ı ayırt
# edebilmeli) ayrı bir yardımcı gerekiyor.
cik() { local k="$1"; shift; err "$@"; ilog "ÇIKIŞ $k: $*"; exit "$k"; }

# --------------------------------------------------------------- geçici alan
# /tmp'de DEĞİL: uzak kaynaktan çekilen dump gigabaytlar tutabilir ve pek çok
# sunucuda /tmp bellekte (tmpfs) durur — orada 20 GB'lık bir dump makineyi
# OOM'a sokar. backups/ ise bu yığında zaten "büyük dosya" için ayrılmış yer
# (backup.sh 5 GB eşiği bekler).
GECICI="${IMPORT_TMPDIR:-$BACKUP_DIR/.ice-aktarma}"
TEMIZLENDI=0
temizle() {
    [ "$TEMIZLENDI" = "1" ] && return 0
    TEMIZLENDI=1
    [ -n "${KAP_TEMIZ:-}" ] && docker exec "${KAP:-}" sh -c \
        "rm -f $KAP_TEMIZ" >/dev/null 2>&1
    [ -n "${GECICI_DIZIN:-}" ] && rm -rf "$GECICI_DIZIN"
    return 0
}
trap temizle EXIT

kullanim() {
cat <<EOF

İçe aktarma — databases-stack

  ./scripts/import.sh <motor> <dosya>            yerel dump dosyası
  ./scripts/import.sh <motor> --kaynak <URI>     uzak canlı kaynaktan çek

Seçenekler
  --uzerine-yaz        Hedef doluysa da aktar (önce güvenlik yedeği alınır)
  --hedef <ad>         Tek veritabanlık dump'ın yazılacağı veritabanı
                       (varsayılan: ${DEFAULT_DATABASE:-defaultdb})
  --kuru               Hiçbir şey yazma: dosyayı tanı, hedefi ölç, ne
                       olacağını anlat (panelin "önce göster" düğmesi)
  --bicime-guven       Hangi motorun dump'ı olduğu ANLAŞILAMAZSA yine de
                       dene. Yanlış motora aktarmak sessiz bir felakettir;
                       ancak dosyanın ne olduğunu BİLİYORSANIZ kullanın.
  --yedeksiz           Üzerine yazarken güvenlik yedeği ALMA (bkz. aşağı)

Desteklenen biçimler
  motor        yerel dosya                        uzak kaynak (--kaynak)
  ---------------------------------------------------------------------
  mariadb      .sql .sql.gz                       mysql:// mariadb://
  postgresql   .sql .sql.gz  .dump (-Fc özel)     postgres:// postgresql://
  mongodb      .archive .archive.gz               mongodb:// mongodb+srv://
  redis        .rdb .rdb.gz                       desteklenmiyor
  mssql        .bak .bak.gz  .tar.gz (yedeğimiz)  desteklenmiyor
  diğer motorlar (cassandra, elasticsearch, clickhouse, kafka, rabbitmq,
  neo4j, minio): içe aktarma DESTEKLENMİYOR — çıkış kodu $KOD_KAPSAM.

Çıkış kodları: 0 tamam · 1 hata · 2 kullanım · 3 kapsam dışı · 4 biçim
               5 hedef dolu · 6 motor kapalı · 7 güvenlik yedeği alınamadı

EOF
}

# ------------------------------------------------------------------ argüman
MOTOR=""; DOSYA=""; URI=""; HEDEF=""
UZERINE=0; KURU=0; BICIME_GUVEN=0; YEDEKSIZ=0

[ "$#" -ge 1 ] || { kullanim; exit "$KOD_KULLANIM"; }
case "$1" in
    -h|--yardim|--help|yardim|help) kullanim; exit 0 ;;
esac
MOTOR="$1"; shift

while [ "$#" -gt 0 ]; do
    case "$1" in
        --kaynak)  shift; [ "$#" -ge 1 ] \
                       || cik "$KOD_KULLANIM" "--kaynak bir URI bekler."
                   URI="$1" ;;
        --hedef)   shift; [ "$#" -ge 1 ] \
                       || cik "$KOD_KULLANIM" "--hedef bir ad bekler."
                   HEDEF="$1" ;;
        --uzerine-yaz)  UZERINE=1 ;;
        --kuru)         KURU=1 ;;
        --bicime-guven) BICIME_GUVEN=1 ;;
        --yedeksiz)     YEDEKSIZ=1 ;;
        -h|--yardim|--help) kullanim; exit 0 ;;
        -*) cik "$KOD_KULLANIM" "Bilinmeyen seçenek: $1  (--yardim)" ;;
        *)  [ -z "$DOSYA" ] || cik "$KOD_KULLANIM" \
                "Tek bir dosya verin; fazladan argüman: $1"
            DOSYA="$1" ;;
    esac
    shift
done

# Hedef adı doğrudan SQL'e/komuta giriyor. Serbest bırakmak, dosya adından
# gelen bir adın (`--hedef "a; DROP DATABASE b"`) sunucuda çalışması demekti.
if [ -n "$HEDEF" ]; then
    case "$HEDEF" in
        ''|*[!A-Za-z0-9_-]*)
            cik "$KOD_KULLANIM" \
                "Geçersiz hedef adı: '$HEDEF' — yalnız harf, rakam, _ ve -" ;;
    esac
fi

# =============================================================================
# MOTOR KAPSAMI
# =============================================================================
# Katalog "bu motor VAR mı" sorusunu cevaplar; "bu motora İÇE AKTARMA yazıldı
# mı" sorusunu değil. İkincisi bu betiğin kendi gerçeğidir, o yüzden burada
# duruyor — katalogda uydurma bir alan aramıyoruz.
katalogda_var() {
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if any(e["id"] == sys.argv[2] for e in c["engines"]) else 1)' \
        "$CATALOG" "$1" 2>/dev/null
}
katalog_motorlari() {
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
print(" ".join(e["id"] for e in c["engines"] if e.get("kind") != "tool"))' \
        "$CATALOG" 2>/dev/null
}

case "$MOTOR" in
    mariadb|postgresql|mongodb|redis|mssql) ;;
    *)  if katalogda_var "$MOTOR"; then
            err "'$MOTOR' için içe aktarma DESTEKLENMİYOR."
            err "  Desteklenenler: mariadb postgresql mongodb redis mssql"
            err "  Bu motorlarda veri taşımanın ürün içindeki yolu yok;"
            err "  motorun kendi aracını kullanın (docs/BACKUP.md)."
            exit "$KOD_KAPSAM"
        fi
        err "Bilinmeyen motor: $MOTOR"
        err "  Katalogdakiler: $(katalog_motorlari)"
        exit "$KOD_KULLANIM" ;;
esac

[ -n "$DOSYA$URI" ] || { kullanim; \
    cik "$KOD_KULLANIM" "Bir dosya ya da --kaynak URI verin."; }
[ -z "$DOSYA" ] || [ -z "$URI" ] || cik "$KOD_KULLANIM" \
    "Hem dosya hem --kaynak verilemez; birini seçin."

require_docker
require_cmd python3 gzip od tar flock awk

KAP="$(primary_of "$MOTOR")"
if ! container_running "$KAP"; then
    err "$MOTOR çalışmıyor (container: $KAP) — içe aktarılacak bir hedef yok."
    err "  Önce açın:  ./stack.sh enable $MOTOR"
    exit "$KOD_KAPALI"
fi

# Motorun parolası: compose'daki `${X_PASSWORD:-${DB_PASSWORD}}` zincirinin
# aynısı. Zinciri burada tekrar kurmak yerine katalogdaki password_env'i
# okuyoruz — parola değişkeninin adı tek bir yerde tanımlı kalsın.
parola_env() {
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
print((e[0].get("connection") or {}).get("password_env") or "" if e else "")' \
        "$CATALOG" "$1" 2>/dev/null
}
PW_ENV="$(parola_env "$MOTOR")"
PW=""
[ -n "$PW_ENV" ] && PW="${!PW_ENV:-}"
[ -n "$PW" ] || PW="${DB_PASSWORD:-}"
[ -n "$PW" ] || cik "$KOD_HATA" \
    "$MOTOR parolası bulunamadı (.env içinde $PW_ENV ya da DB_PASSWORD)."

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Host'ta veritabanı istemcisi YOKTUR; her sorgu container'ın içindekiyle
# çalışır. Parola komut satırına değil ORTAMA konur: host'ta `ps` çıktısında
# görünmesin (backup.sh'taki desenin aynısı).
my_sql() {   # my_sql <sql>
    MYSQL_PWD="$PW" docker exec -e MYSQL_PWD "$KAP" \
        mariadb -u root -N -B -e "$1" 2>>"$LOG_FILE"
}
pg_sql() {   # pg_sql <veritabanı> <sql>
    PGPASSWORD="$PW" docker exec -e PGPASSWORD "$KAP" \
        psql -U "${POSTGRES_USER:-root}" -d "$1" -tAq -c "$2" 2>>"$LOG_FILE"
}
mongo_js() { # mongo_js <js>
    MPW="$PW" MUSER="${MONGO_USER:-root}" docker exec -e MPW -e MUSER "$KAP" \
        sh -c 'exec "$1" --quiet -u "$MUSER" -p "$MPW" \
               --authenticationDatabase admin --eval "$2"' \
        sh "${MONGO_SHELL:-mongosh}" "$1" 2>>"$LOG_FILE"
}
redis_cli() { # redis_cli <argümanlar…>
    REDISCLI_AUTH="$PW" docker exec -e REDISCLI_AUTH "$KAP" \
        redis-cli --no-auth-warning "$@" 2>>"$LOG_FILE"
}
ms_sql() {   # ms_sql <sorgu>
    # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir. Bu
    # olmadan düşen sorgu "başarılı" sanılır (backup.sh'ta da aynı sebeple).
    SQLCMDPASSWORD="$PW" docker exec -e SQLCMDPASSWORD "$KAP" \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W \
        -s '|' -Q "SET NOCOUNT ON; $1" 2>>"$LOG_FILE"
}

bayt_insan() {
    awk -v b="${1:-0}" 'BEGIN{
        split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}
dosya_boyutu() {
    # stat'ın BSD/GNU bayrakları farklı; wc -c her yerde aynı ve doğru.
    wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

# =============================================================================
# BİÇİM DOĞRULAMA  (KEMER 4)
# =============================================================================
# "Uzantıya bakıp devam et" YETMEZ: dosya adı kullanıcının yazdığı bir dizedir,
# içeriğe dair hiçbir şey söylemez. PostgreSQL dump'ını MariaDB'ye basmak
# sessiz bir felakettir — istemci ilk hatada durur ama o ana kadar CREATE/DROP
# çalışmıştır ve hedef ne eski ne yeni hâldedir. Bu yüzden burada dosyanın
# İÇİNE bakılıyor ve tanınmayan dosya reddediliyor.
SIKISTIRMA="yok"
BICIM=""
BICIM_MOTOR=""
COK_VT=0
BAS_BIN=""
BAS_TXT=""

akis() {   # akis <dosya> → içeriği (gzip'liyse açarak) stdout'a
    if [ "$SIKISTIRMA" = "gzip" ]; then gzip -dc "$1"; else cat "$1"; fi
}

imza()    { grep -qaF  "$1" "$BAS_TXT" 2>/dev/null; }
imza_re() { grep -qaEi "$1" "$BAS_TXT" 2>/dev/null; }

tespit_et() {   # tespit_et <dosya>
    local f="$1" sihir ic tar_sihir

    sihir="$(od -An -N4 -tx1 < "$f" 2>/dev/null | tr -d ' \n')"
    case "$sihir" in
        1f8b*) SIKISTIRMA="gzip" ;;
        *)     SIKISTIRMA="yok" ;;
    esac

    # Açılmış ilk 512 KB hem imza hem içerik sorusunu tek okumada cevaplar.
    # `head -c` erken çıkar (SIGPIPE): 40 GB'lık bir dump için bile tek
    # blokluk okuma.
    BAS_BIN="$GECICI_DIZIN/bas.bin"
    akis "$f" 2>/dev/null | head -c 524288 > "$BAS_BIN"
    [ -s "$BAS_BIN" ] || { BICIM="bos"; return 0; }

    ic="$(od -An -N8 -tx1 < "$BAS_BIN" | tr -d ' \n')"
    case "$ic" in
        6de29981*)   BICIM="mongo-arsiv"; BICIM_MOTOR="mongodb"; COK_VT=1
                     return 0 ;;
        5047444d50*) BICIM="pg-ozel";     BICIM_MOTOR="postgresql"
                     return 0 ;;
        5245444953*) BICIM="redis-rdb";   BICIM_MOTOR="redis";   COK_VT=1
                     return 0 ;;
        54415045*)   BICIM="mssql-bak";   BICIM_MOTOR="mssql"
                     return 0 ;;
    esac

    # tar: imzası dosyanın BAŞINDA değil 257. baytındadır ("ustar").
    tar_sihir="$(od -An -j257 -N5 -c < "$BAS_BIN" 2>/dev/null | tr -d ' \n')"
    if [ "$tar_sihir" = "ustar" ]; then
        # Bu yığının kendi MSSQL yedeği: içinde <veritabanı>.bak dosyaları
        # olan bir tar.gz. Üyeleri listelemek dosyanın TAMAMINI okur; yalnız
        # tar olduğu kesinleştikten sonra yapıyoruz.
        if akis "$f" 2>/dev/null | tar -tf - 2>/dev/null \
             | grep -qi '\.bak$'; then
            BICIM="mssql-tar"; BICIM_MOTOR="mssql"; COK_VT=1
        else
            BICIM="taninmayan-tar"
        fi
        return 0
    fi

    # NUL baytı taşıyan dosya metin değildir; SQL sanıp istemciye vermek,
    # ikili çöpü sunucuya akıtmak demek olurdu.
    local ham temiz
    ham="$(wc -c < "$BAS_BIN" | tr -d '[:space:]')"
    temiz="$(tr -d '\000' < "$BAS_BIN" | wc -c | tr -d '[:space:]')"
    if [ "${ham:-0}" != "${temiz:-0}" ]; then
        BICIM="ikili"; return 0
    fi

    BAS_TXT="$GECICI_DIZIN/bas.txt"
    tr -d '\r' < "$BAS_BIN" > "$BAS_TXT"

    # SQL METNİNİN HANGİ MOTORA AİT OLDUĞU
    # Tek bir imzaya bakmak yanıltıyor: `CREATE TABLE` her ikisinde de var,
    # `ENGINE=InnoDB` ise PostgreSQL dump'ının içindeki bir yorum satırında
    # bile geçebilir. Bu yüzden PUAN topluyoruz ve kazananın açık ara önde
    # olmasını şart koşuyoruz; berabere kalırsa "belirsiz" deyip reddediyoruz.
    local pg=0 my=0
    local sqlre='^[[:space:]]*(CREATE|INSERT|COPY|ALTER|DROP)[[:space:]]'
    imza    'PostgreSQL database dump'   && pg=$((pg + 4))
    imza_re '^\connect '                && pg=$((pg + 4))
    imza    'pg_catalog.'                && pg=$((pg + 3))
    imza_re '^SET (statement_timeout|search_path|lock_timeout)' \
                                         && pg=$((pg + 2))
    imza    'FROM stdin;'                && pg=$((pg + 2))
    imza_re 'OWNER TO '                  && pg=$((pg + 1))
    imza_re 'CREATE EXTENSION'           && pg=$((pg + 1))

    imza_re '(MySQL|MariaDB) dump'       && my=$((my + 4))
    imza_re '/\*!(40|50|M?1[01])[0-9]'   && my=$((my + 4))
    imza_re 'ENGINE=(InnoDB|MyISAM|Aria)' && my=$((my + 3))
    imza    'LOCK TABLES '               && my=$((my + 2))
    imza_re 'AUTO_INCREMENT'             && my=$((my + 2))
    imza_re 'DEFAULT CHARSET='           && my=$((my + 2))
    imza    '`'                          && my=$((my + 1))

    if [ "$pg" -ge 3 ] && [ "$pg" -gt "$my" ]; then
        BICIM="pg-duz"; BICIM_MOTOR="postgresql"
        imza_re '^(\connect |CREATE DATABASE)' && COK_VT=1
    elif [ "$my" -ge 3 ] && [ "$my" -gt "$pg" ]; then
        BICIM="mariadb-sql"; BICIM_MOTOR="mariadb"
        imza_re '^(USE `|CREATE DATABASE)' && COK_VT=1
    elif imza_re "$sqlre"; then
        # SQL olduğu belli ama motora özgü tek bir iz yok (elle yazılmış ya da
        # ORM'in ürettiği taşınabilir SQL). Reddediyoruz: bu dosya iki motorda
        # da ÇALIŞABİLİR ama çalışmayabilir de, ve yanlış tahmin geri
        # alınamaz. --bicime-guven ile kullanıcı sorumluluğu alabilir.
        BICIM="belirsiz-sql"
    else
        BICIM="bilinmiyor"
    fi
    return 0
}

# Tespitin sonucunu KULLANICI DİLİNDE anlat. "BICIM=pg-ozel" bir kullanıcıya
# hiçbir şey söylemez; "PostgreSQL özel arşivi (pg_dump -Fc)" söyler.
bicim_adi() {
    case "$1" in
        mariadb-sql)    printf 'MariaDB/MySQL SQL dump' ;;
        pg-duz)         printf 'PostgreSQL düz SQL dump' ;;
        pg-ozel)        printf 'PostgreSQL özel arşivi (pg_dump -Fc)' ;;
        mongo-arsiv)    printf 'MongoDB arşivi (mongodump --archive)' ;;
        redis-rdb)      printf 'Redis RDB anlık görüntüsü' ;;
        mssql-bak)      printf 'SQL Server yedeği (.bak)' ;;
        mssql-tar)      printf 'SQL Server yedek arşivi (.bak içeren tar)' ;;
        belirsiz-sql)   printf 'motoru belirsiz SQL metni' ;;
        taninmayan-tar) printf 'içeriği tanınmayan tar arşivi' ;;
        ikili)          printf 'tanınmayan ikili dosya' ;;
        bos)            printf 'boş dosya' ;;
        *)              printf 'tanınmayan dosya' ;;
    esac
}

# =============================================================================
# HEDEFİN DURUMU  (KEMER 1)
# =============================================================================
# "Hedef boş mu" sorusunun cevabı KAPSAMA bağlı:
#   kapsam=db     → dump tek bir veritabanına gidiyor; yalnız o veritabanına
#                   bakılır. Yanındaki başka veritabanları bu aktarmadan
#                   etkilenmez, onları "dolu" saymak kullanıcıyı boş yere
#                   durdurur.
#   kapsam=motor  → dump birden çok veritabanına dokunuyor (ya da hangi
#                   veritabanlarına dokunduğu dosyanın tamamı okunmadan
#                   bilinemiyor: mongodump arşivi, Redis RDB'si). O zaman
#                   hedef MOTORUN TAMAMIDIR. Bilmediğimiz bir şeye "boş" demek
#                   bu ürünün yapmayacağı şeydir.
DUR_SEMA=0; DUR_TABLO=0; DUR_SATIR=0; DUR_BAYT=0; DUR_METIN=""

durum_oku() {   # 0 = ölçüldü · 2 = ÖLÇÜLEMEDİ
    DUR_SEMA=0; DUR_TABLO=0; DUR_SATIR=0; DUR_BAYT=0; DUR_METIN=""
    local out rc

    case "$MOTOR" in
    mariadb)
        local kosul=""
        [ "$KAPSAM" = "db" ] && kosul="AND TABLE_SCHEMA='$HEDEF'"
        out="$(my_sql "SELECT COUNT(DISTINCT TABLE_SCHEMA), COUNT(*),
                 COALESCE(SUM(TABLE_ROWS),0),
                 COALESCE(SUM(DATA_LENGTH+INDEX_LENGTH),0)
               FROM information_schema.TABLES
               WHERE TABLE_SCHEMA NOT IN ('information_schema',
                     'performance_schema','mysql','sys') $kosul;")"; rc=$?
        [ "$rc" -eq 0 ] && [ -n "$out" ] || return 2
        IFS=$'\t' read -r DUR_SEMA DUR_TABLO DUR_SATIR DUR_BAYT <<< "$out"
        # TABLE_ROWS InnoDB'de KESİN DEĞİL, istatistiklerden gelen bir
        # tahmindir; "~" işareti bu yüzden var. Kesin sayım için her tabloda
        # COUNT(*) gerekir ve büyük bir veritabanında bu dakikalar sürer —
        # sırf ekrana sayı yazmak için üretimi kilitlemeyiz.
        DUR_METIN="$DUR_SEMA şema, $DUR_TABLO tablo, ~$DUR_SATIR satır, \
$(bayt_insan "$DUR_BAYT") veri"
        ;;
    postgresql)
        local d liste t s b
        if [ "$KAPSAM" = "db" ]; then
            out="$(pg_sql postgres \
                "SELECT count(*) FROM pg_database WHERE datname='$HEDEF'")"
            rc=$?
            [ "$rc" -eq 0 ] && [ -n "$out" ] || return 2
            if [ "${out//[[:space:]]/}" = "0" ]; then
                DUR_METIN="veritabanı yok (aktarma sırasında oluşturulacak)"
                return 0
            fi
            liste="$HEDEF"
        else
            liste="$(pg_sql postgres "SELECT datname FROM pg_database
                     WHERE datistemplate=false AND datallowconn")"; rc=$?
            [ "$rc" -eq 0 ] || return 2
        fi
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            out="$(pg_sql "$d" "SELECT
                (SELECT count(*) FROM information_schema.tables
                   WHERE table_schema NOT IN ('pg_catalog',
                         'information_schema')),
                (SELECT COALESCE(sum(n_live_tup),0)
                   FROM pg_stat_user_tables),
                pg_database_size(current_database())")"; rc=$?
            [ "$rc" -eq 0 ] && [ -n "$out" ] || return 2
            IFS='|' read -r t s b <<< "$out"
            DUR_TABLO=$((DUR_TABLO + ${t:-0}))
            DUR_SATIR=$((DUR_SATIR + ${s:-0}))
            DUR_BAYT=$((DUR_BAYT + ${b:-0}))
            [ "${t:-0}" -gt 0 ] && DUR_SEMA=$((DUR_SEMA + 1))
        done <<< "$liste"
        # n_live_tup da tahmindir (istatistik toplayıcıdan gelir); pg_database
        # _size ise şişme (bloat) ve WAL dışı dosyaları da sayar. İkisi de
        # "boş mu dolu mu" sorusunu cevaplamaya yeter, muhasebe için değil.
        DUR_METIN="$DUR_SEMA veritabanı, $DUR_TABLO tablo, ~$DUR_SATIR satır, \
$(bayt_insan "$DUR_BAYT") veri"
        ;;
    mongodb)
        out="$(mongo_js "
var ad = db.getMongo().getDBNames().filter(function (n) {
    return ['admin', 'config', 'local'].indexOf(n) < 0; });
var k = 0, o = 0, b = 0;
ad.forEach(function (n) {
    var d = db.getSiblingDB(n), s = d.stats();
    k += d.getCollectionNames().length;
    o += s.objects || 0; b += s.dataSize || 0; });
print(ad.length + '|' + k + '|' + o + '|' + b);")"; rc=$?
        [ "$rc" -eq 0 ] || return 2
        out="$(printf '%s' "$out" | grep -aE '^[0-9]+\|' | tail -1)"
        [ -n "$out" ] || return 2
        IFS='|' read -r DUR_SEMA DUR_TABLO DUR_SATIR DUR_BAYT <<< "$out"
        DUR_METIN="$DUR_SEMA veritabanı, $DUR_TABLO koleksiyon, \
$DUR_SATIR belge, $(bayt_insan "$DUR_BAYT") veri"
        ;;
    redis)
        # Anahtarlar db0..db15'e dağılmış olabilir; DBSIZE yalnız SEÇİLİ
        # veritabanını sayar ve 15 numaralı veritabanında duran veriyi "boş"
        # gösterirdi. INFO keyspace hepsini bir kerede verir.
        out="$(redis_cli INFO keyspace)"; rc=$?
        [ "$rc" -eq 0 ] || return 2
        DUR_SATIR="$(printf '%s' "$out" | tr -d '\r' \
            | sed -n 's/^db[0-9]*:keys=\([0-9]*\).*/\1/p' \
            | awk '{t += $1} END {printf "%d", t}')"
        DUR_SEMA="$(printf '%s' "$out" | grep -ac '^db[0-9]*:keys=')"
        out="$(redis_cli INFO memory)"
        DUR_BAYT="$(printf '%s' "$out" | tr -d '\r' \
            | sed -n 's/^used_memory:\([0-9]*\).*/\1/p' | head -1)"
        DUR_TABLO="$DUR_SEMA"
        DUR_METIN="$DUR_SATIR anahtar ($DUR_SEMA veritabanında), \
$(bayt_insan "${DUR_BAYT:-0}") bellek"
        ;;
    mssql)
        out="$(ms_sql "SELECT CASE WHEN DB_ID('$HEDEF') IS NULL
                       THEN 0 ELSE 1 END;")"; rc=$?
        [ "$rc" -eq 0 ] || return 2
        out="${out//[[:space:]]/}"
        if [ "$out" = "0" ]; then
            DUR_METIN="veritabanı yok (aktarma sırasında oluşturulacak)"
            return 0
        fi
        out="$(ms_sql "SELECT CAST((SELECT COUNT(*) FROM [$HEDEF].sys.tables
                         WHERE is_ms_shipped = 0) AS varchar(20))
                     + '|' + CAST((SELECT ISNULL(SUM(p.rows), 0)
                         FROM [$HEDEF].sys.partitions p
                         JOIN [$HEDEF].sys.tables t
                           ON p.object_id = t.object_id
                         WHERE p.index_id IN (0, 1)) AS varchar(20))
                     + '|' + CAST((SELECT ISNULL(SUM(CAST(size AS bigint)), 0)
                         * 8192 FROM [$HEDEF].sys.database_files)
                         AS varchar(20));")"; rc=$?
        [ "$rc" -eq 0 ] || return 2
        out="$(printf '%s' "$out" | tr -d '\r' \
               | grep -aE '^[0-9]+\|' | tail -1)"
        [ -n "$out" ] || return 2
        IFS='|' read -r DUR_TABLO DUR_SATIR DUR_BAYT <<< "$out"
        [ "${DUR_TABLO:-0}" -gt 0 ] && DUR_SEMA=1
        DUR_METIN="$DUR_TABLO tablo, $DUR_SATIR satır, \
$(bayt_insan "$DUR_BAYT") ayrılmış dosya"
        ;;
    esac
    return 0
}

hedef_dolu_mu() {   # 0 = dolu · 1 = boş
    case "$MOTOR" in
        redis) [ "${DUR_SATIR:-0}" -gt 0 ] ;;
        *)     [ "${DUR_TABLO:-0}" -gt 0 ] ;;
    esac
}

# =============================================================================
# GÜVENLİK YEDEĞİ  (KEMER 2)
# =============================================================================
# Üzerine yazmadan önce ALINIR ve dosya adı EKRANA YAZILIR. "Yanlış dosyayı
# aktardım" cümlesi bu üründe er geç kurulacak; o an aranan tek şey dönülecek
# noktanın adıdır. Yalnız log'a yazmak yetmez — kullanıcı log'u açmaz.
#
# YEDEĞİ KİLİT ALMADAN ÖNCE ALIYORUZ. Sebep somut: backup.sh kendi içinde
# state/backup.lock'u flock ile kapar. Bu betik o kilidi tutuyorken backup.sh'ı
# çağırsaydık çağrılan süreç "Başka bir işlem kilidi tutuyor" deyip çıkardı —
# yani güvenlik yedeği HİÇ ALINAMAZDI ve kemer sessizce kopmuş olurdu.
GUVENLIK_DOSYA=""
guvenlik_yedegi() {
    local isaret="$GECICI_DIZIN/yedek-isareti"
    local dizin="$BACKUP_DIR/$MOTOR/full"
    mkdir -p "$dizin" || { err "Yedek dizini açılamadı: $dizin"; return 1; }
    : > "$isaret" || return 1

    heading "Güvenlik yedeği"
    log "Üzerine yazmadan önce yedekleniyor: ./scripts/backup.sh $MOTOR"
    log "Büyük veritabanlarında dakikalar sürebilir — kesmeyin."
    ./scripts/backup.sh "$MOTOR" 2>&1 | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"

    # Dosyayı ADINDAN TAHMİN ETMİYORUZ (backup.sh'ın ad şeması değişebilir);
    # işaret dosyasından SONRA yazılmış olana bakıyoruz. Doğrulamayı geçemeyip
    # .bozuk uzantısıyla kenara alınan dosya geri dönüş noktası DEĞİLDİR;
    # onu da eliyoruz.
    GUVENLIK_DOSYA="$(find "$dizin" -type f -newer "$isaret" \
        ! -name '*.bozuk' -printf '%T@\t%p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -f2-)"

    if [ "$rc" -ne 0 ] || [ -z "$GUVENLIK_DOSYA" ]; then
        err "Güvenlik yedeği ALINAMADI (backup.sh çıkış kodu: $rc)."
        if [ "$rc" -eq 0 ] && [ -z "$GUVENLIK_DOSYA" ]; then
            err "  backup.sh başarı bildirdi ama yeni bir dosya yok."
        fi
        err "  Ayrıntı: $LOG_FILE"
        err "  Üzerine YAZILMADI — dönüş noktası olmadan veri silmeyiz."
        err "  Yine de ısrar ediyorsanız: --yedeksiz (geri dönüşü yoktur)"
        return 1
    fi
    ok "Geri dönüş noktası: $GUVENLIK_DOSYA"
    log "  Yanlış dosyayı aktardıysanız buradan dönersiniz:"
    log "    ./scripts/backup.sh restore-$MOTOR $GUVENLIK_DOSYA"
    return 0
}

# =============================================================================
# UZAK KAYNAKTAN ÇEKME
# =============================================================================
# Dump'ı HOST'ta değil HEDEF CONTAINER'IN İÇİNDE alıyoruz: istemciler
# (mariadb-dump, pg_dump, mongodump) orada zaten var ve sürümleri sunucuyla
# uyumlu. Host'ta istemci aramak kullanıcıyı "önce şunu kur" duvarına
# çarptırır — bu betiğin varlık sebebiyle çelişir.
# Uzak sunucuya erişim de container'ın ağından geçer; kaynak yalnız host'un
# göreceği bir adresteyse (127.0.0.1 gibi) buradan görünmez.
uri_coz() {
    python3 - "$1" <<'PY'
import sys, urllib.parse as u
p = u.urlparse(sys.argv[1])
v = [p.scheme, u.unquote(p.username or ""), u.unquote(p.password or ""),
     p.hostname or "", str(p.port or ""), (p.path or "").lstrip("/")]
# Satir sonu tasiyan bir alan, asagidaki satir satir okumayi kaydirir ve
# parolayi host adi sanmamiza yol acardi; boyle bir URI kabul edilmiyor.
if any("\n" in x for x in v):
    sys.exit(3)
print("\n".join(v))
print("SON")
PY
}

uzaktan_cek() {   # DOSYA'yı çekilen dump ile doldurur
    local coz
    coz="$(uri_coz "$URI")" || cik "$KOD_KULLANIM" "URI çözümlenemedi: $URI"
    local -a P; mapfile -t P <<< "$coz"
    [ "${P[6]:-}" = "SON" ] || cik "$KOD_KULLANIM" "URI çözümlenemedi: $URI"
    local sema="${P[0]}" kul="${P[1]}" pw="${P[2]}"
    local host="${P[3]}" port="${P[4]}" yol="${P[5]}"
    [ -n "$host" ] || cik "$KOD_KULLANIM" "URI'de sunucu adı yok: $URI"

    # Şema ile motorun uyuşması KEMER 4'ün uzak hâlidir: postgres:// URI'sini
    # mariadb'ye çekmek, dosya hâlinde yapılan hatanın aynısı.
    local beklenen=""
    case "$sema" in
        mysql|mariadb)       beklenen="mariadb" ;;
        postgres|postgresql) beklenen="postgresql" ;;
        mongodb|mongodb+srv) beklenen="mongodb" ;;
        "") cik "$KOD_KULLANIM" "URI'de şema yok (örnek: mysql://…)" ;;
        *)  cik "$KOD_BICIM" "Bilinmeyen URI şeması: $sema://" ;;
    esac
    [ "$beklenen" = "$MOTOR" ] || cik "$KOD_BICIM" \
        "$sema:// bir $beklenen kaynağıdır; siz $MOTOR'a aktarıyorsunuz."

    local cikti rc=0
    heading "Uzak kaynaktan çekiliyor"
    log "kaynak: $sema://$host${port:+:$port}${yol:+/$yol}"
    case "$MOTOR" in
    mariadb)
        cikti="$GECICI_DIZIN/uzak.sql"
        [ -n "$kul" ] || kul="root"
        if [ -n "$yol" ]; then
            log "veritabanı: $yol → hedef: ${HEDEF:-$yol}"
            MYSQL_PWD="$pw" docker exec -e MYSQL_PWD "$KAP" mariadb-dump \
                -h "$host" -P "${port:-3306}" -u "$kul" \
                --single-transaction --quick --routines --triggers \
                --events --hex-blob "$yol" > "$cikti" 2>>"$LOG_FILE" || rc=$?
        else
            log "URI'de veritabanı yok → SUNUCUNUN TAMAMI çekiliyor"
            MYSQL_PWD="$pw" docker exec -e MYSQL_PWD "$KAP" mariadb-dump \
                -h "$host" -P "${port:-3306}" -u "$kul" \
                --all-databases --single-transaction --quick --routines \
                --triggers --events --hex-blob \
                > "$cikti" 2>>"$LOG_FILE" || rc=$?
        fi ;;
    postgresql)
        cikti="$GECICI_DIZIN/uzak.sql"
        [ -n "$kul" ] || kul="${POSTGRES_USER:-postgres}"
        if [ -n "$yol" ]; then
            log "veritabanı: $yol → hedef: ${HEDEF:-$yol}"
            # --no-owner/--no-privileges: kaynaktaki rol adları BU kümede
            # yoktur; sahiplik satırları her nesnede hataya düşer ve aktarma
            # yarıda kalırdı. Taşınan şey veri, rol dünyası değil.
            PGPASSWORD="$pw" docker exec -e PGPASSWORD "$KAP" pg_dump \
                -h "$host" -p "${port:-5432}" -U "$kul" -d "$yol" \
                --no-owner --no-privileges > "$cikti" 2>>"$LOG_FILE" || rc=$?
        else
            log "URI'de veritabanı yok → KÜMENİN TAMAMI çekiliyor"
            PGPASSWORD="$pw" docker exec -e PGPASSWORD "$KAP" pg_dumpall \
                -h "$host" -p "${port:-5432}" -U "$kul" \
                --clean --if-exists > "$cikti" 2>>"$LOG_FILE" || rc=$?
        fi ;;
    mongodb)
        cikti="$GECICI_DIZIN/uzak.archive.gz"
        # URI parolayı içerir; komut satırına koyarsak container içindeki
        # `ps` çıktısında görünür. Ortamdan geçiriyoruz.
        MURI="$URI" docker exec -e MURI "$KAP" sh -c \
            'exec mongodump --uri="$MURI" --archive --gzip --quiet' \
            > "$cikti" 2>>"$LOG_FILE" || rc=$? ;;
    esac

    if [ "$rc" -ne 0 ]; then
        err "Uzak kaynaktan çekilemedi (çıkış kodu: $rc)."
        tail -5 "$LOG_FILE" | sed 's/^/    /' >&2
        err "  Tam çıktı: $LOG_FILE"
        exit "$KOD_HATA"
    fi
    [ -s "$cikti" ] || cik "$KOD_HATA" \
        "Uzaktan BOŞ dump geldi — aktaracak veri yok, hedefe dokunulmadı."

    DOSYA="$cikti"
    # Kullanıcı --hedef vermediyse kaynaktaki veritabanı adı sürdürülür:
    # "shop" veritabanını çeken biri onu "defaultdb" adıyla bulmayı beklemez.
    [ -n "$HEDEF" ] || [ -z "$yol" ] || HEDEF="$yol"
    ok "Çekildi: $(bayt_insan "$(dosya_boyutu "$DOSYA")")"
}

# Uzak kaynağı olmayan motorlarda NE YAPILACAĞINI söylüyoruz. "Desteklenmiyor"
# deyip susmak, kullanıcıyı aramaya yollar; oysa ikisinde de elle yapılacak
# adım kısa ve sonrası yine bu betik.
uzak_desteklenmiyor() {
    err "$MOTOR için uzak kaynaktan çekme DESTEKLENMİYOR."
    case "$MOTOR" in
    redis)
        err "  Redis'te ağ üzerinden tutarlı kopya almanın bu üründe sınanmış"
        err "  bir yolu yok. Kaynakta BGSAVE çalıştırıp dump.rdb'yi getirin:"
        err "    ./scripts/import.sh redis /yol/dump.rdb" ;;
    mssql)
        err "  SQL Server yedeği yalnız sunucunun KENDİ diskine yazılır;"
        err "  uzaktan akış alınamaz. Kaynakta BACKUP DATABASE çalıştırıp"
        err "  .bak dosyasını getirin:"
        err "    ./scripts/import.sh mssql /yol/veritabani.bak" ;;
    esac
    exit "$KOD_KAPSAM"
}

# =============================================================================
# AKTARMA — MOTOR BAŞINA
# =============================================================================
# Ortak kural: boru hattının HER İKİ ucu da kontrol edilir. Kesik bir .gz
# kısmi SQL üretip 1 ile çıkar, istemci o kısmı sorunsuz yutar ve YARIM bir
# aktarma "başarılı" görünür (backup.sh'ta aynı hata gerçekten yaşandı).

aktar_mariadb() {
    local ps
    if [ "$KAPSAM" = "db" ]; then
        # Üzerine yazma tek veritabanıyla SINIRLI: yanındaki veritabanlarına
        # dokunmuyoruz. Kullanıcı "shop'u değiştir" dedi, "sunucuyu sil"
        # demedi.
        if [ "$UZERINE" = "1" ]; then
            my_sql "DROP DATABASE IF EXISTS \`$HEDEF\`;" >/dev/null || return 1
        fi
        # Karakter kümesini burada sabitliyoruz çünkü dump'ın CREATE TABLE
        # satırları kendi kümesini zaten taşır; eksik olan yalnız veritabanı
        # seviyesindeki varsayılandır ve sunucu varsayılanı latin1 kalmış
        # kurulumlarda Türkçe kolon adları bozuk geliyordu.
        my_sql "CREATE DATABASE IF NOT EXISTS \`$HEDEF\`
                CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
            >/dev/null || return 1
        akis "$DOSYA" | MYSQL_PWD="$PW" docker exec -e MYSQL_PWD -i "$KAP" \
            mariadb -u root "$HEDEF" >>"$LOG_FILE" 2>&1
    else
        # Çok veritabanlı dump kendi CREATE DATABASE/USE satırlarını taşır;
        # varsayılan veritabanı VERMİYORUZ ki dosya nereye yazacağını kendi
        # söylesin.
        akis "$DOSYA" | MYSQL_PWD="$PW" docker exec -e MYSQL_PWD -i "$KAP" \
            mariadb -u root >>"$LOG_FILE" 2>&1
    fi
    ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] || { err "Dump dosyası okunamadı (bozuk gzip?)."
                              return 1; }
    [ "${ps[1]}" -eq 0 ] || {
        err "MariaDB aktarmayı reddetti — ilk hatada durdu."
        tail -5 "$LOG_FILE" | sed 's/^/    /' >&2
        err "  DDL geri alınamaz: hedef YARIM kalmış olabilir."
        return 1; }
    return 0
}

# pg_dumpall çıktısı (küme geneli) için ON_ERROR_STOP KULLANILMAZ.
# backup.sh'taki restore_postgresql aynı tuzağa düşüp veri kaybettirmişti:
# --clean çıktısı bağlı olduğumuz rolü ve veritabanını da düşürmeye çalışır
#     DROP DATABASE IF EXISTS "postgres";  → cannot drop the currently open db
#     DROP ROLE     IF EXISTS "root";      → current user cannot be dropped
# Bu iki hata NORMALDİR; ama ON_ERROR_STOP=1 ile psql tam orada durur — diğer
# veritabanları çoktan düşürülmüşken. Bunun yerine hataları TOPLUYOR,
# beklenenleri eliyor ve geriye gerçek hata kalıp kalmadığına bakıyoruz.
pg_kume_aktar() {
    local errf; errf="$(mktemp)"
    akis "$DOSYA" | PGPASSWORD="$PW" docker exec -e PGPASSWORD -i "$KAP" \
        psql -U "${POSTGRES_USER:-root}" -d postgres 2>"$errf" >>"$LOG_FILE"
    local ps=("${PIPESTATUS[@]}")
    cat "$errf" >> "$LOG_FILE"
    if [ "${ps[0]}" -ne 0 ]; then
        rm -f "$errf"; err "Dump dosyası okunamadı (bozuk gzip?)."; return 1
    fi
    local gercek
    gercek="$(grep -aE '^(psql:|ERROR|FATAL|HATA)' "$errf" 2>/dev/null \
        | grep -avi -e 'current user cannot be dropped' \
                    -e 'cannot drop the currently open database' \
                    -e 'role .* already exists' \
                    -e 'database .* already exists' \
                    -e 'is being accessed by other users' \
        || true)"
    rm -f "$errf"
    if [ -n "$gercek" ]; then
        err "PostgreSQL aktarmada hata — küme YARIM kalmış olabilir:"
        printf '%s\n' "$gercek" | head -5 | sed 's/^/    /' >&2
        err "  Tam çıktı: $LOG_FILE"
        return 1
    fi
    return 0
}

# Tek veritabanlık düz dump. Burada ON_ERROR_STOP=1 + --single-transaction
# KULLANILIYOR ve bu bilerek yukarıdakinin tersi: bu dosyada CREATE/DROP
# DATABASE yok, dolayısıyla "kendi ayağını kesme" tuzağı da yok. Kazandığımız
# şey büyük: aktarma yarıda düşerse işlem geri alınır ve hedef veritabanı
# dokunulmamış hâlde kalır — yani başarısız bir aktarma veri kaybettirmez.
pg_tek_aktar() {
    if [ "$UZERINE" = "1" ]; then
        # DROP DATABASE açık bağlantı varken düşer. pgAdmin sekmesi açık
        # unutulmuş bir tarayıcı yüzünden aktarmanın reddedilmesi, kullanıcıya
        # anlatılamayacak bir hatadır; bağlantıları önce kapatıyoruz.
        pg_sql postgres "SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname='$HEDEF' AND pid <> pg_backend_pid()" >/dev/null
        pg_sql postgres "DROP DATABASE IF EXISTS \"$HEDEF\"" >/dev/null \
            || { err "Hedef veritabanı düşürülemedi: $HEDEF"; return 1; }
    fi
    local var
    var="$(pg_sql postgres \
        "SELECT 1 FROM pg_database WHERE datname='$HEDEF'")"
    if [ -z "${var//[[:space:]]/}" ]; then
        pg_sql postgres "CREATE DATABASE \"$HEDEF\"" >/dev/null \
            || { err "Hedef veritabanı oluşturulamadı: $HEDEF"; return 1; }
    fi
    akis "$DOSYA" | PGPASSWORD="$PW" docker exec -e PGPASSWORD -i "$KAP" \
        psql -U "${POSTGRES_USER:-root}" -d "$HEDEF" \
        -v ON_ERROR_STOP=1 --single-transaction >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] || { err "Dump okunamadı (bozuk gzip?)."; return 1; }
    [ "${ps[1]}" -eq 0 ] || {
        err "PostgreSQL aktarmayı reddetti; işlem GERİ ALINDI."
        tail -5 "$LOG_FILE" | sed 's/^/    /' >&2
        err "  '$HEDEF' aktarma öncesindeki hâlinde."
        return 1; }
    return 0
}

# pg_dump -Fc arşivi. Düz SQL değil; psql okuyamaz, pg_restore gerekir.
pg_ozel_aktar() {
    if [ "$UZERINE" = "1" ]; then
        pg_sql postgres "SELECT pg_terminate_backend(pid)
            FROM pg_stat_activity
            WHERE datname='$HEDEF' AND pid <> pg_backend_pid()" >/dev/null
        pg_sql postgres "DROP DATABASE IF EXISTS \"$HEDEF\"" >/dev/null \
            || { err "Hedef veritabanı düşürülemedi: $HEDEF"; return 1; }
    fi
    local var
    var="$(pg_sql postgres \
        "SELECT 1 FROM pg_database WHERE datname='$HEDEF'")"
    if [ -z "${var//[[:space:]]/}" ]; then
        pg_sql postgres "CREATE DATABASE \"$HEDEF\"" >/dev/null \
            || { err "Hedef veritabanı oluşturulamadı: $HEDEF"; return 1; }
    fi
    # --no-owner/--no-privileges: kaynak kümenin rol adları burada yoktur;
    # sahiplik satırları her nesnede hataya düşerdi. --exit-on-error olmadan
    # pg_restore hataları SAYIP 0 ile çıkar; o hâlde yarım bir veritabanı
    # "aktarıldı" damgası alırdı.
    akis "$DOSYA" | PGPASSWORD="$PW" docker exec -e PGPASSWORD -i "$KAP" \
        pg_restore -U "${POSTGRES_USER:-root}" -d "$HEDEF" \
        --no-owner --no-privileges --exit-on-error --single-transaction \
        >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] || { err "Arşiv okunamadı (bozuk gzip?)."; return 1; }
    [ "${ps[1]}" -eq 0 ] || {
        err "pg_restore aktarmayı reddetti; işlem GERİ ALINDI."
        tail -5 "$LOG_FILE" | sed 's/^/    /' >&2
        return 1; }
    return 0
}

aktar_postgresql() {
    case "$BICIM" in
        pg-ozel) pg_ozel_aktar ;;
        pg-duz)  if [ "$KAPSAM" = "db" ]; then pg_tek_aktar
                 else pg_kume_aktar; fi ;;
        *)       err "İç hata: PostgreSQL için beklenmeyen biçim: $BICIM"
                 return 1 ;;
    esac
}

aktar_mongodb() {
    local -a arg=()
    [ "$SIKISTIRMA" = "gzip" ] && arg+=(--gzip)
    # --drop YALNIZ üzerine yazarken. Arşivde OLMAYAN koleksiyonlara
    # dokunmaz: "hedefi sil" değil, "getirdiğim koleksiyonun eskisini at"
    # demektir. Bu ayrım önemli — --uzerine-yaz motoru boşaltmaz.
    [ "$UZERINE" = "1" ] && arg+=(--drop)
    MPW="$PW" MUSER="${MONGO_USER:-root}" \
    docker exec -i -e MPW -e MUSER "$KAP" sh -c \
        'exec mongorestore -u "$MUSER" -p "$MPW" \
             --authenticationDatabase admin --archive "$@"' \
        sh "${arg[@]}" < "$DOSYA" >>"$LOG_FILE" 2>&1
    local rc=$?
    [ "$rc" -eq 0 ] || {
        err "mongorestore aktarmayı tamamlayamadı (çıkış kodu: $rc)."
        tail -5 "$LOG_FILE" | sed 's/^/    /' >&2
        return 1; }
    return 0
}

# Redis ve MSSQL'in kendi yedek biçimleri ürünün GERİ YÜKLEME yolunda zaten
# var; burada ikinci bir uygulama yazmıyoruz. Sebep somut: restore_redis beş
# adımlı bir AOF dansı yapıyor (AOF kapalı başlat → RDB oku → AOF'u yeniden
# üret → normale dön) ve bu dansın yanlış yapılmış hâli "hiçbir şey yüklenmedi
# ama eski veri de silindi" demek. O yordamın ikinci, sınanmamış bir kopyasını
# üretmek bu üründe en pahalı hatayı davet etmek olurdu.
#
# Dosyayı .rdb.gz ADIYLA hazırlamamız şart: verify_backup uzantıya bakarak
# karar veriyor ve düz bir .rdb "tanınmayan biçim" dalına düşüyor; ardından
# restore_redis `gzip -dc` ile okumaya çalışıyor. O borunun sol tarafı hemen
# düşse bile sağ taraf ESKİ dump.rdb'yi ve AOF'u ÇOKTAN SİLMİŞ oluyor
# (tek bir `rm -rf … && cat > …` zinciri) — elde ne yeni ne eski veri kalır.
aktar_redis() {
    local hazir="$DOSYA"
    case "$SIKISTIRMA/$DOSYA" in
        gzip/*.rdb.gz) ;;                       # zaten doğru ad, kopyalama
        gzip/*)  hazir="$GECICI_DIZIN/ice-aktarma.rdb.gz"
                 cp "$DOSYA" "$hazir" || return 1 ;;
        *)       hazir="$GECICI_DIZIN/ice-aktarma.rdb.gz"
                 gzip -c "$DOSYA" > "$hazir" || return 1 ;;
    esac
    ASSUME_YES=yes ./scripts/backup.sh restore-redis "$hazir" 2>&1 \
        | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"
    [ "$rc" -eq 0 ] || { err "Redis aktarması başarısız (çıkış kodu: $rc)."
                         return 1; }
    return 0
}

# Bu yığının kendi MSSQL yedeği (içinde <veritabanı>.bak olan tar.gz):
# restore_mssql zaten arşivi açıp her veritabanını tek tek geri yüklüyor ve
# "hiç .bak yoksa sessizce başarılı sayma" tuzağını kapatmış durumda.
mssql_tar_aktar() {
    local hazir="$DOSYA"
    case "$DOSYA" in
        *.tar.gz) ;;
        *) hazir="$GECICI_DIZIN/ice-aktarma.tar.gz"
           cp "$DOSYA" "$hazir" || return 1 ;;
    esac
    ASSUME_YES=yes ./scripts/backup.sh restore-mssql "$hazir" 2>&1 \
        | tee -a "$LOG_FILE"
    local rc="${PIPESTATUS[0]}"
    [ "$rc" -eq 0 ] || { err "MSSQL aktarması başarısız (çıkış kodu: $rc)."
                         return 1; }
    return 0
}

# Tek bir .bak dosyası — asıl içe aktarma hâli (başka sunucudan gelen yedek).
# restore_mssql'e veremiyoruz çünkü o, dosya adından veritabanı adı türetip
# MOVE'suz RESTORE çalıştırıyor: Windows'ta alınmış bir yedekte dosya yolları
# C:\… ile başlar ve Linux sunucuda RESTORE "directory lookup failed" ile
# düşer. Bu yüzden mantıksal dosya adlarını FILELISTONLY ile okuyup MOVE
# üretiyoruz — içe aktarmanın gerçek dünyada çalışması buna bağlı.
mssql_bak_aktar() {
    local yol="/var/opt/mssql/backup/ice-aktarma.bak"
    docker exec "$KAP" sh -c 'mkdir -p /var/opt/mssql/backup' \
        >>"$LOG_FILE" 2>&1 || { err "Container'da yedek dizini açılamadı."
                                return 1; }
    KAP_TEMIZ="$yol"     # temizle() bunu her çıkışta siler
    akis "$DOSYA" | docker exec -i "$KAP" sh -c 'cat > "$1"' sh "$yol"
    local ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ] \
        || { err "Yedek dosyası container'a kopyalanamadı."; return 1; }

    local satirlar tasi="" veri=0 gunluk=0 ad tip ek
    satirlar="$(ms_sql "RESTORE FILELISTONLY FROM DISK=N'$yol';")"
    if [ $? -ne 0 ] || [ -z "$satirlar" ]; then
        warn "FILELISTONLY okunamadı; MOVE üretilmeden denenecek."
        warn "  Kaynak Windows ise RESTORE dosya yolu yüzünden düşebilir."
    else
        while IFS='|' read -r ad tip _; do
            ad="$(printf '%s' "$ad" | sed 's/[[:space:]]*$//')"
            tip="$(printf '%s' "$tip" | tr -d '[:space:]')"
            [ -n "$ad" ] || continue
            case "$tip" in
                D) veri=$((veri + 1))
                   ek="ndf"; [ "$veri" -eq 1 ] && ek="mdf"
                   ad="${ad//\'/\'\'}"
                   tasi="$tasi, MOVE N'$ad' TO \
N'/var/opt/mssql/data/${HEDEF}_$veri.$ek'" ;;
                L) gunluk=$((gunluk + 1))
                   ad="${ad//\'/\'\'}"
                   tasi="$tasi, MOVE N'$ad' TO \
N'/var/opt/mssql/data/${HEDEF}_log$gunluk.ldf'" ;;
            esac
        done <<< "$(printf '%s' "$satirlar" | tr -d '\r' \
                    | awk -F'|' 'NF >= 3 {print $1 "|" $3 "|"}')"
    fi

    # REPLACE yalnız --uzerine-yaz ile: onsuz SQL Server aynı adda BAŞKA bir
    # veritabanının üzerine yazmayı kendisi reddeder. Kemer 1'in motor
    # tarafındaki karşılığı; iki kapı birden kapalı olsun.
    local secenek="RECOVERY"
    [ "$UZERINE" = "1" ] && secenek="REPLACE, RECOVERY"
    ms_sql "RESTORE DATABASE [$HEDEF] FROM DISK=N'$yol' \
            WITH $secenek$tasi;" >>"$LOG_FILE" 2>&1
    local rc=$?
    docker exec "$KAP" sh -c "rm -f $yol" >/dev/null 2>&1
    KAP_TEMIZ=""
    [ "$rc" -eq 0 ] || {
        err "RESTORE DATABASE başarısız (çıkış kodu: $rc)."
        tail -5 "$LOG_FILE" | sed 's/^/    /' >&2
        return 1; }
    return 0
}

aktar_mssql() {
    case "$BICIM" in
        mssql-tar) mssql_tar_aktar ;;
        mssql-bak) mssql_bak_aktar ;;
        *) err "İç hata: MSSQL için beklenmeyen biçim: $BICIM"; return 1 ;;
    esac
}

# =============================================================================
# KİLİTLER
# =============================================================================
# İki içe aktarma aynı motora aynı anda yazarsa ikisi de yarım kalır ve hangi
# satırın hangi dosyadan geldiği bir daha ölçülemez. Kilit MOTOR BAŞINA:
# farklı motorlara paralel aktarma meşru bir iştir, engellemek için sebep yok.
#
# fd 8 KULLANILIYOR, 9 DEĞİL. common.sh'ın acquire_lock'u fd 9'a bağlı ve
# aşağıda YEDEKLEME kilidini onunla alıyoruz; ikisini aynı tanımlayıcıya
# bağlasaydık ikinci `exec 9>>` birincisini kapatır, yani ilk kilidi sessizce
# bırakmış olurduk.
import_kilidi() {
    local f="$STACK_ROOT/state/import-$MOTOR.lock"
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    exec 8>>"$f" || cik "$KOD_HATA" "Kilit dosyası açılamadı: $f"
    flock -n 8 || cik "$KOD_HATA" \
        "$MOTOR motoruna süren bir aktarma var. Bitmesini bekleyin:" \
        "$f"
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
mkdir -p "$GECICI" || cik "$KOD_HATA" "Geçici dizin açılamadı: $GECICI"
GECICI_DIZIN="$(mktemp -d "$GECICI/ia-XXXXXX")" \
    || cik "$KOD_HATA" "Geçici dizin açılamadı: $GECICI"

BASLANGIC="$(date +%s)"
heading "İçe aktarma — $MOTOR"
ilog "başlıyor: motor=$MOTOR dosya=${DOSYA:-yok} hedef=${HEDEF:-varsayılan}"
import_kilidi

if [ -n "$URI" ]; then
    case "$MOTOR" in redis|mssql) uzak_desteklenmiyor ;; esac
    uzaktan_cek
fi

[ -e "$DOSYA" ] || cik "$KOD_KULLANIM" "Dosya yok: $DOSYA"
if [ -d "$DOSYA" ]; then
    err "Bu bir dizin: $DOSYA"
    err "  Dizin biçimindeki dump'lar (pg_dump -Fd, mongodump dizini)"
    err "  desteklenmiyor. Tek dosyaya çevirin:"
    err "    tar -czf dump.tar.gz -C $DOSYA ."
    exit "$KOD_KULLANIM"
fi
[ -f "$DOSYA" ] && [ -r "$DOSYA" ] || cik "$KOD_KULLANIM" \
    "Dosya okunamıyor: $DOSYA"
[ -s "$DOSYA" ] || cik "$KOD_BICIM" "Dosya BOŞ: $DOSYA — aktaracak veri yok."

KAYNAK_BAYT="$(dosya_boyutu "$DOSYA")"
tespit_et "$DOSYA"
log "dosya : $DOSYA"
log "boyut : $(bayt_insan "$KAYNAK_BAYT") ($SIKISTIRMA)"
log "biçim : $(bicim_adi "$BICIM")"

# --------------------------------------------------------- biçim × motor ---
if [ -z "$BICIM_MOTOR" ]; then
    if [ "$BICIM" = "belirsiz-sql" ] && [ "$BICIME_GUVEN" = "1" ] \
       && { [ "$MOTOR" = "mariadb" ] || [ "$MOTOR" = "postgresql" ]; }; then
        warn "Dosyanın hangi motora ait olduğu ANLAŞILAMADI."
        warn "  --bicime-guven verildiği için $MOTOR dump'ı sayılıyor."
        warn "  Yanlışsa hedef yarım kalır; sorumluluk sizde."
        BICIM_MOTOR="$MOTOR"
        case "$MOTOR" in
            mariadb)    BICIM="mariadb-sql"
                        imza_re '^(USE `|CREATE DATABASE)' && COK_VT=1 ;;
            postgresql) BICIM="pg-duz"
                        imza_re '^(\\connect |CREATE DATABASE)' && COK_VT=1 ;;
        esac
    else
        err "Bu dosyanın hangi motorun dump'ı olduğu DOĞRULANAMADI."
        err "  Görülen: $(bicim_adi "$BICIM")"
        err "  Tahmin etmiyoruz: yanlış motora aktarmak sessiz bir felakettir"
        err "  (PostgreSQL dump'ı MariaDB'de ilk hatada durur ama o ana kadar"
        err "  CREATE/DROP çalışmıştır; hedef ne eski ne yeni hâlde kalır)."
        case "$BICIM" in
            belirsiz-sql)
                err "  SQL olduğu belli ama motora özgü iz yok. Emin"
                err "  olduğunuz dosyalarda: --bicime-guven" ;;
            ikili|taninmayan-tar)
                err "  Sıkıştırılmış bir klasör verdiyseniz içindeki dump"
                err "  dosyasını çıkarıp öyle verin." ;;
        esac
        exit "$KOD_BICIM"
    fi
elif [ "$BICIM_MOTOR" != "$MOTOR" ]; then
    err "Bu dosya bir $BICIM_MOTOR dump'ı, siz $MOTOR'a aktarıyorsunuz."
    err "  Görülen: $(bicim_adi "$BICIM")"
    err "  Doğrusu:  ./scripts/import.sh $BICIM_MOTOR $DOSYA"
    exit "$KOD_BICIM"
fi

# ------------------------------------------------------- kapsam ve hedef ---
if [ "$COK_VT" = "1" ]; then
    KAPSAM="motor"
    if [ -n "$HEDEF" ]; then
        warn "--hedef yok sayıldı: bu dump veritabanı adlarını KENDİ taşıyor."
        HEDEF=""
    fi
else
    KAPSAM="db"
    if [ -z "$HEDEF" ]; then
        if [ "$BICIM" = "mssql-bak" ]; then
            # .bak içindeki veritabanı adını okumak için RESTORE HEADERONLY
            # gerekir ve o sorgunun sütun düzeni SQL Server sürümüne göre
            # kayar — sürüm yükseldiği gün yanlış sütunu ad sanmak, veriyi
            # rastgele bir veritabanına yazmak demek. Dosya adı en azından
            # kullanıcının GÖRDÜĞÜ bir şey; hangi ada yazacağımızı da
            # aşağıda açıkça söylüyoruz.
            HEDEF="$(basename "$DOSYA")"
            HEDEF="${HEDEF%.gz}"; HEDEF="${HEDEF%.bak}"
            HEDEF="$(printf '%s' "$HEDEF" | tr -c 'A-Za-z0-9_-' '_')"
        else
            HEDEF="${DEFAULT_DATABASE:-defaultdb}"
        fi
    fi
fi

if [ "$KAPSAM" = "db" ]; then
    log "hedef : $MOTOR / $HEDEF veritabanı"
else
    log "hedef : $MOTOR / MOTORUN TAMAMI (dump birden çok veritabanı taşıyor)"
fi

# ------------------------------------------------ hedefin durumu (KEMER 1) --
durum_oku; DURUM_RC=$?
if [ "$DURUM_RC" -ne 0 ]; then
    # "Ölçemedim" ile "boş" aynı şey değildir. Ölçemediğimiz bir hedefe
    # sessizce yazmak, bu ürünün yapmayacağı tek şey.
    err "Hedefin durumu ÖLÇÜLEMEDİ ($MOTOR sorguya cevap vermedi)."
    err "  Ayrıntı: $LOG_FILE"
    if [ "$UZERINE" != "1" ]; then
        err "  Boş olduğunu VARSAYMIYORUZ; aktarma yapılmadı."
        exit "$KOD_DOLU"
    fi
    warn "  --uzerine-yaz verildi; ölçülemeyen hedefe devam ediliyor."
    DUR_METIN="ölçülemedi"
fi
ONCE_METIN="$DUR_METIN"
ONCE_TABLO="$DUR_TABLO"; ONCE_SATIR="$DUR_SATIR"
log "durum : $DUR_METIN"

# ------------------------------------------------------------------ kuru ---
if [ "$KURU" = "1" ]; then
    heading "Kuru koşum — hiçbir şey yazılmadı"
    if [ "$DURUM_RC" -eq 0 ] && hedef_dolu_mu && [ "$UZERINE" != "1" ]; then
        err "Bu dosya AKTARILAMAZ: hedef dolu ve --uzerine-yaz verilmedi."
        exit "$KOD_DOLU"
    fi
    if hedef_dolu_mu; then
        log "Aktarılırdı: önce güvenlik yedeği, sonra üzerine yazma."
    else
        log "Aktarılırdı; hedef boş olduğu için güvenlik yedeği gerekmezdi."
    fi
    exit 0
fi

# --------------------------------------------- dolu hedef + güvenlik yedeği -
if [ "$DURUM_RC" -eq 0 ] && hedef_dolu_mu; then
    if [ "$UZERINE" != "1" ]; then
        err "HEDEF BOŞ DEĞİL — üzerine sessizce yazmıyoruz."
        err "  Hedefte: $DUR_METIN"
        err "  Bu veriyi gerçekten değiştirmek istiyorsanız (önce güvenlik"
        err "  yedeği alınır):"
        err "    ./scripts/import.sh $MOTOR $DOSYA --uzerine-yaz"
        err "  Ne olacağını önce görmek için: --kuru"
        exit "$KOD_DOLU"
    fi
fi

if [ "$UZERINE" = "1" ] && { [ "$DURUM_RC" -ne 0 ] || hedef_dolu_mu; }; then
    if [ "$YEDEKSIZ" = "1" ]; then
        # Bu seçenek KEMER 2'yi deler ve bilerek duruyor: yedek alınamayan
        # gerçek durumlar var (backup.sh 5 GB'ın altında yedek almayı
        # reddeder). Seçeneği hiç vermezsek kullanıcı ürünü bırakıp elle
        # `mysql < dump.sql` yazar — o zaman geriye HİÇBİR kemer kalmaz.
        warn "GÜVENLİK YEDEĞİ ALINMIYOR (--yedeksiz)."
        warn "  Bu aktarmanın geri dönüşü YOKTUR: eski veri kaybolacak."
    else
        guvenlik_yedegi || exit "$KOD_YEDEK"
    fi
fi

# ----------------------------------------------------------------- aktar ---
# Yedekleme kilidi: gece 02:00 cron'u, yarı aktarılmış bir veritabanını
# (bazı tablolar yeni, bazıları henüz yok) döküp "geçerli kurtarma noktası"
# diye saklayabilir ve uzak sunucuya senkronlayabilirdi. backup.sh'ın geri
# yükleme dalı da tam bu sebeple aynı kilidi alıyor.
# Redis ve MSSQL-tar yollarında kilidi ALMIYORUZ: o iki yolda işi backup.sh
# restore-* yapıyor ve kilidi kendisi kapıyor — burada tutsaydık çağrılan
# süreç "kilidi başkası tutuyor" deyip çıkardı.
KILIT=1
case "$MOTOR/$BICIM" in
    redis/*|mssql/mssql-tar) KILIT=0 ;;
esac
[ "$KILIT" = "1" ] && acquire_lock "$STACK_ROOT/state/backup.lock"

heading "Aktarılıyor"
log "Büyük dosyalarda uzun sürebilir; ayrıntılı çıktı: $LOG_FILE"
AKTARMA_RC=0
case "$MOTOR" in
    mariadb)    aktar_mariadb    || AKTARMA_RC=$? ;;
    postgresql) aktar_postgresql || AKTARMA_RC=$? ;;
    mongodb)    aktar_mongodb    || AKTARMA_RC=$? ;;
    redis)      aktar_redis      || AKTARMA_RC=$? ;;
    mssql)      aktar_mssql      || AKTARMA_RC=$? ;;
esac
[ "$KILIT" = "1" ] && exec 9>&-

# ------------------------------------------------------------ özet (KEMER 5)
SURE=$(( $(date +%s) - BASLANGIC ))
durum_oku; SON_RC=$?
[ "$SON_RC" -eq 0 ] || DUR_METIN="ölçülemedi (bkz. $LOG_FILE)"

heading "Özet"
printf '  Motor        : %s (%s)\n' "$MOTOR" "$KAP"
printf '  Kaynak       : %s\n' "$DOSYA"
printf '  Biçim        : %s\n' "$(bicim_adi "$BICIM")"
printf '  Okunan       : %s\n' "$(bayt_insan "$KAYNAK_BAYT")"
if [ "$KAPSAM" = "db" ]; then
    printf '  Hedef        : %s veritabanı\n' "$HEDEF"
else
    printf '  Hedef        : motorun tamamı\n'
fi
printf '  Önce         : %s\n' "$ONCE_METIN"
printf '  Sonra        : %s\n' "$DUR_METIN"
if [ "$SON_RC" -eq 0 ] && [ "$DURUM_RC" -eq 0 ]; then
    printf '  Değişim      : %+d tablo, %+d satır\n' \
        "$(( DUR_TABLO - ONCE_TABLO ))" "$(( DUR_SATIR - ONCE_SATIR ))"
fi
printf '  Süre         : %dm %ds\n' "$((SURE / 60))" "$((SURE % 60))"
[ -n "$GUVENLIK_DOSYA" ] && \
    printf '  Dönüş noktası: %s\n' "$GUVENLIK_DOSYA"
printf '  Günlük       : %s\n\n' "$LOG_FILE"
ilog "bitti: rc=$AKTARMA_RC sonra='$DUR_METIN' süre=${SURE}s"

if [ "$AKTARMA_RC" -ne 0 ]; then
    err "İçe aktarma BAŞARISIZ."
    [ -n "$GUVENLIK_DOSYA" ] && \
        err "  Geri dönmek için:"
    [ -n "$GUVENLIK_DOSYA" ] && \
        err "    ./scripts/backup.sh restore-$MOTOR $GUVENLIK_DOSYA"
    exit "$KOD_HATA"
fi

# "Komut 0 döndü" ile "veri geldi" aynı şey değildir. Bu ürünün en pahalı
# hata sınıfı tam burada: boş bir dosyayla yapılan aktarma sessizce başarılı
# görünüyor, kullanıcı taşımayı bitmiş sanıyor ve eski sunucuyu kapatıyordu.
if [ "$SON_RC" -eq 0 ] && ! hedef_dolu_mu; then
    err "Aktarma hatasız bitti AMA hedefte hâlâ veri yok."
    err "  Dosya ($(bicim_adi "$BICIM")) tanım taşıyor ama tablo/kayıt"
    err "  taşımıyor olabilir. Ayrıntı: $LOG_FILE"
    exit "$KOD_HATA"
fi

ok "İçe aktarma tamamlandı."
exit 0
