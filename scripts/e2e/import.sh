#!/bin/bash
# =============================================================================
# databases-stack — E2E: İÇE AKTARMA
# =============================================================================
# Bu paket CANLI bir kuruluma karşı çalışır ve dört soruyu cevaplar:
#
#   1. GERÇEK bir dump BOŞ bir hedefe aktarılınca SATIRLAR GELİYOR mu?
#   2. DOLU bir hedefe aktarma --uzerine-yaz olmadan REDDEDİLİYOR mu?
#   3. --uzerine-yaz ile önce GÜVENLİK YEDEĞİ alınıyor mu (dosya oluştu mu)?
#   4. YANLIŞ MOTORUN dump'ı reddediliyor mu?
#
# Neden bu dördü: içe aktarmanın değeri "komut 0 döndü"de değil, bu dört
# cümlenin aynı anda doğru olmasında. Biri yanlışsa ürün, kullanıcının
# verisini sessizce yok edebilen bir araca dönüşür — ve o hata ancak felaket
# günü görülür.
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/import.sh                 çalışan bütün motorlar
#     ./scripts/e2e/import.sh mariadb mongodb yalnız bunlar
#
# Ayarlar (ortam değişkeni):
#     E2E_YEDEKLERI_KORU=1   testin ürettiği güvenlik yedeklerini silme
#     E2E_UZERINE=0          3. soruyu (güvenlik yedeği) atla — tam yedek
#                            alındığı için uzun sürer ve disk ister
#     E2E_*_SURESI           zaman aşımları (saniye)
#
# ⚠ Bu paket KENDİ verisiyle çalışır: e2e_ia_kaynak ve e2e_ia_hedef adlı
#   veritabanlarını yaratır, doldurur ve sonunda siler. Başka hiçbir
#   veritabanına yazmaz. Yine de 3. soru gerçek bir TAM YEDEK aldırır
#   (backup.sh <motor>): disk ve zaman ister.
#
# set -e YOK: her kontrol tek tek raporlanmalı. İlk hatada ölen bir test, asıl
# bilgiyi (hangi kemerin koptuğunu) hiç göstermez.
#
# SONUÇ TÜRLERİ ORTAK KÜTÜPHANEDEN (scripts/e2e/lib.sh) gelir ve DÖRT tanedir:
#   t_ok      ölçtük, doğru çıktı
#   t_fail    ölçtük, yanlış çıktı
#   t_skip    ÖN KOŞUL YOK (motor kapalı, ürün o motora aktarma sunmuyor)
#   t_unknown ÖLÇEMEDİK (docker cevap vermedi, dump üretilemedi, komut askıda
#             kaldı) — BAŞARISIZ SAYILIR: "bilmiyorum" ile "iyi" ayrı şey.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

[ -r scripts/e2e/lib.sh ] \
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi yok, \
bu paket ölçüm yapamaz."
E2E_SUITE="import"
source scripts/e2e/lib.sh

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
mkdir -p "$LOG_DIR"

# ------------------------------------------------------------ zaman aşımı ---
# Hiçbir bekleme sonsuz değil. `timeout` yoksa komutlar yine çalışır ama bunu
# SÖYLÜYORUZ: askıda kalmış bir teste "sürüyor" demek, çöktüğünü hiç
# görmemekten beterdir.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)

SURE_ISTEMCI="${E2E_ISTEMCI_SURESI:-60}"    # tek sorgu
SURE_DUMP="${E2E_DUMP_SURESI:-600}"         # test dump'ının üretilmesi
SURE_AKTAR="${E2E_AKTAR_SURESI:-900}"       # tek aktarma
SURE_YEDEK="${E2E_YEDEK_SURESI:-1800}"      # güvenlik yedekli aktarma

zaman_asimi() {   # zaman_asimi <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
# Ölçüm ARACI asıldıysa sonuç "ürün reddetti" değil "ÖLÇEMEDİK"tir: timeout(1)
# zaman aşımında 124, -k ile öldürmek zorunda kalınca 137 döner. Bu ayrımı
# yapmayan bir negatif test, asılı kalan her çağrıyı "doğru şekilde reddetti"
# diye YEŞİL yazar.
asildi_mi() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }
docker_yasiyor() { docker ps -q >/dev/null 2>&1; }

# --------------------------------------------------------- geçici alan/log --
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-ice-XXXXXX")" \
    || die "Geçici dizin açılamadı."
SON_CIKTI="$E2E_TMP/son.out"; : > "$SON_CIKTI"
E2E_LOG="$LOG_DIR/e2e-import_$(date +%Y%m%d_%H%M%S).log"; : > "$E2E_LOG"

# Çalıştırılan her ürün komutunun tam çıktısı log'a gider; ekranda yalnız
# kontrol satırları kalır. Son komutun çıktısı ayrıca SON_CIKTI'da durur —
# hata ayrıntısını oradan alıp DÜŞTÜ satırına yazıyoruz, böylece kullanıcı log
# dosyasını açmadan da ne olduğunu görür.
# stdin /dev/null: ürünün herhangi bir onay sorusu bizi sonsuza kadar
# bekletmesin.
calistir() {   # calistir <saniye> <açıklama> <komut…>
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$2"
      printf 'komut: %s\n' "${*:3}"; } >> "$E2E_LOG"
    local sn="$1"; shift 2
    local rc=0
    zaman_asimi "$sn" "$@" > "$SON_CIKTI" 2>&1 < /dev/null || rc=$?
    cat "$SON_CIKTI" >> "$E2E_LOG"
    printf '(çıkış kodu: %s)\n' "$rc" >> "$E2E_LOG"
    return "$rc"
}
son_ozet() {
    local s
    s="$(tr -d '\r' < "$SON_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' \
         | tail -n 2 | tr '\n' ' ')"
    printf '%s' "${s:-çıktı yok}"
}
son_icerir() { grep -aqF "$1" "$SON_CIKTI" 2>/dev/null; }

# Yedekleme kilidi çakışması ÜRÜN HATASI DEĞİLDİR: gece yedeği ya da elle
# başlatılmış bir yedek sürüyor olabilir. Bunu "başarısız" saymak, testi
# saatin kaç olduğuna bağlı hâle getirirdi.
kilit_carpismasi() { son_icerir "kilidi tutuyor"; }

bos_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# =============================================================================
# SABİT TEST NESNELERİ
# =============================================================================
# Adlar SABİT: yarım kalmış bir koşumdan sonra betik tekrar çalıştırıldığında
# aynı nesneleri bulup üzerine yazar ve sonunda siler.
# DEĞER her koşumda farklı — hedefte okunan şeyin gerçekten BU koşumun
# aktardığı kayıt olduğunu ancak böyle kanıtlayabiliriz. Sabit bir değer
# kullansaydık, hiç aktarılmamış eski veri de testi geçirirdi.
KAYNAK_DB="e2e_ia_kaynak"
HEDEF_DB="e2e_ia_hedef"
TABLO="kanit"
KANIT="e2e-$(date +%Y%m%d%H%M%S)-$$"

DOKUNULAN=""     # veri yazdığımız motorlar (sonunda temizlenir)
URETILEN=""      # bu koşumun ürettiği GERÇEK yedek dosyaları
TEMIZLENDI=0

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Host'ta veritabanı istemcisi YOK; her sorgu container'ın içindekiyle çalışır.
# Parolalar komut satırına DEĞİL ortama konuyor (host'ta `ps` çıktısında
# görünmesinler) — backup.sh ve import.sh'taki desenin aynısı.
my_sql() {   # my_sql <container> <parola> <sql>
    ( export MYSQL_PWD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$3" ) 2>>"$E2E_LOG"
}
pg_sql() {   # pg_sql <container> <parola> <veritabanı> <sql>
    ( export PGPASSWORD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -d "$3" -tAq -c "$4" ) 2>>"$E2E_LOG"
}
mongo_js() { # mongo_js <container> <parola> <js>
    ( export MPW="$2" MUSER="${MONGO_USER:-root}"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e MPW -e MUSER "$1" sh -c \
          'exec "$1" --quiet -u "$MUSER" -p "$MPW" \
               --authenticationDatabase admin --eval "$2"' \
          sh "${MONGO_SHELL:-mongosh}" "$3" ) 2>>"$E2E_LOG"
}
ms_sql() {   # ms_sql <container> <parola> <sorgu>
    ( export SQLCMDPASSWORD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e SQLCMDPASSWORD "$1" \
          /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W \
          -Q "SET NOCOUNT ON; $3" ) 2>>"$E2E_LOG"
}

# Motorun parolası: katalogtaki password_env, yoksa DB_PASSWORD — compose'daki
# `${X_PASSWORD:-${DB_PASSWORD}}` zincirinin aynısı.
motor_pw() {   # motor_pw <eid>
    local ad v=""
    # tr -d: python çıktısı bazı ortamlarda CRLF gelir ve bu dize DEĞİŞKEN
    # ADI olarak kullanılıyor; sondaki \r parolayı sessizce boş bırakırdı.
    ad="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
print((e[0].get("connection") or {}).get("password_env") or "" if e else "")' \
        "$CATALOG" "$1" 2>/dev/null | tr -d '\r')"
    [ -n "$ad" ] && v="${!ad:-}"
    [ -n "$v" ] || v="${DB_PASSWORD:-}"
    printf '%s' "$v"
}

# =============================================================================
# KAYNAK VERİ · DUMP ÜRETİMİ · HEDEFTEN OKUMA
# =============================================================================
# Testin kullandığı dump'lar UYDURMA DEĞİL: her motorun kendi istemcisiyle,
# kullanıcının elindeki dosyanın üretildiği yolla üretiliyor. Elle yazılmış
# sahte bir SQL metni, biçim doğrulamasını da veri yolunu da sınamazdı.
kaynak_yaz() {   # kaynak_yaz <eid> <container> <parola>
    case "$1" in
    mariadb)
        my_sql "$2" "$3" "CREATE DATABASE IF NOT EXISTS \`$KAYNAK_DB\`;
            CREATE TABLE IF NOT EXISTS \`$KAYNAK_DB\`.\`$TABLO\`
                (k VARCHAR(64) PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
            REPLACE INTO \`$KAYNAK_DB\`.\`$TABLO\` VALUES
                ('kanit','$KANIT'), ('bir','1'), ('iki','2');" >/dev/null ;;
    postgresql)
        local var
        var="$(pg_sql "$2" "$3" postgres \
              "SELECT 1 FROM pg_database WHERE datname='$KAYNAK_DB'")"
        [ -n "${var//[[:space:]]/}" ] || pg_sql "$2" "$3" postgres \
            "CREATE DATABASE \"$KAYNAK_DB\"" >/dev/null || return 1
        pg_sql "$2" "$3" "$KAYNAK_DB" \
            "CREATE TABLE IF NOT EXISTS \"$TABLO\" (k text PRIMARY KEY,
                 v text);
             INSERT INTO \"$TABLO\" VALUES ('kanit','$KANIT'),
                 ('bir','1'), ('iki','2')
             ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" >/dev/null ;;
    mongodb)
        mongo_js "$2" "$3" "
var c = db.getSiblingDB('$KAYNAK_DB').$TABLO;
c.replaceOne({_id:'kanit'}, {_id:'kanit', v:'$KANIT'}, {upsert:true});
c.replaceOne({_id:'bir'}, {_id:'bir', v:'1'}, {upsert:true});
c.replaceOne({_id:'iki'}, {_id:'iki', v:'2'}, {upsert:true});" >/dev/null ;;
    mssql)
        # CREATE DATABASE kendi grubunda çalışmalı; aynı batch'te tablo
        # yaratmaya kalkışmak "database does not exist" hatası verir.
        ms_sql "$2" "$3" "IF DB_ID('$KAYNAK_DB') IS NULL
                CREATE DATABASE [$KAYNAK_DB];" >/dev/null || return 1
        ms_sql "$2" "$3" "IF OBJECT_ID('[$KAYNAK_DB].dbo.$TABLO') IS NULL
                CREATE TABLE [$KAYNAK_DB].dbo.$TABLO
                    (k varchar(64) PRIMARY KEY, v varchar(64));
            DELETE FROM [$KAYNAK_DB].dbo.$TABLO;
            INSERT INTO [$KAYNAK_DB].dbo.$TABLO VALUES
                ('kanit','$KANIT'), ('bir','1'), ('iki','2');" >/dev/null ;;
    *) return 3 ;;
    esac
}

dump_uret() {   # dump_uret <eid> <container> <parola> <çıktı dosyası>
    local eid="$1" C="$2" pw="$3" f="$4" rc=0
    case "$eid" in
    mariadb)
        ( export MYSQL_PWD="$pw"
          zaman_asimi "$SURE_DUMP" docker exec -e MYSQL_PWD "$C" \
              mariadb-dump -u root --single-transaction --quick \
              --hex-blob "$KAYNAK_DB" ) > "$f" 2>>"$E2E_LOG" || rc=$? ;;
    postgresql)
        ( export PGPASSWORD="$pw"
          zaman_asimi "$SURE_DUMP" docker exec -e PGPASSWORD "$C" \
              pg_dump -U "${POSTGRES_USER:-root}" -d "$KAYNAK_DB" \
              --no-owner --no-privileges ) > "$f" 2>>"$E2E_LOG" || rc=$? ;;
    mongodb)
        ( export MPW="$pw" MUSER="${MONGO_USER:-root}"
          zaman_asimi "$SURE_DUMP" docker exec -e MPW -e MUSER "$C" sh -c \
              'exec mongodump -u "$MUSER" -p "$MPW" \
                   --authenticationDatabase admin --db "$1" \
                   --archive --gzip --quiet' \
              sh "$KAYNAK_DB" ) > "$f" 2>>"$E2E_LOG" || rc=$? ;;
    mssql)
        # SQL Server yedeği yalnız SUNUCUNUN diskine yazılır; sonra dışarı
        # okuyoruz. Kullanıcının elindeki .bak dosyası da tam böyle doğar.
        docker exec "$C" sh -c \
            'mkdir -p /var/opt/mssql/backup' >>"$E2E_LOG" 2>&1
        ms_sql "$C" "$pw" "BACKUP DATABASE [$KAYNAK_DB]
            TO DISK=N'/var/opt/mssql/backup/e2e_ia.bak' WITH FORMAT, INIT;" \
            >>"$E2E_LOG" 2>&1 || rc=$?
        [ "$rc" -eq 0 ] && { zaman_asimi "$SURE_DUMP" docker exec "$C" \
            cat /var/opt/mssql/backup/e2e_ia.bak > "$f" 2>>"$E2E_LOG" \
            || rc=$?; }
        docker exec "$C" sh -c \
            'rm -f /var/opt/mssql/backup/e2e_ia.bak' >>"$E2E_LOG" 2>&1 ;;
    *) return 3 ;;
    esac
    [ "$rc" -eq 0 ] && [ -s "$f" ] || return 1
    return 0
}

# Hedefi BOŞ hâle getir: T1'in ölçtüğü şey "boş hedefe aktarınca veri gelir mi"
# olduğu için hedefin gerçekten yok olması ön koşul.
hedef_sil() {   # hedef_sil <eid> <container> <parola>
    case "$1" in
    mariadb)    my_sql "$2" "$3" "DROP DATABASE IF EXISTS \`$HEDEF_DB\`;" \
                    >/dev/null 2>&1 ;;
    postgresql) pg_sql "$2" "$3" postgres "SELECT pg_terminate_backend(pid)
                    FROM pg_stat_activity WHERE datname='$HEDEF_DB'
                      AND pid <> pg_backend_pid()" >/dev/null 2>&1
                pg_sql "$2" "$3" postgres \
                    "DROP DATABASE IF EXISTS \"$HEDEF_DB\"" >/dev/null 2>&1 ;;
    mongodb)    mongo_js "$2" "$3" \
                    "db.getSiblingDB('$KAYNAK_DB').dropDatabase()" \
                    >/dev/null 2>&1 ;;
    mssql)      ms_sql "$2" "$3" "IF DB_ID('$HEDEF_DB') IS NOT NULL BEGIN
                    ALTER DATABASE [$HEDEF_DB] SET SINGLE_USER
                        WITH ROLLBACK IMMEDIATE;
                    DROP DATABASE [$HEDEF_DB]; END" >/dev/null 2>&1 ;;
    esac
    return 0
}

# Aktarılan kanıt kaydını HEDEFTEN oku. MongoDB'de hedef, arşivin kendi
# taşıdığı veritabanı adıdır (mongorestore ad değiştirmez) — bu yüzden orada
# kaynak adına bakılıyor.
hedef_oku() {   # hedef_oku <eid> <container> <parola>
    case "$1" in
    mariadb)    my_sql "$2" "$3" \
                    "SELECT v FROM \`$HEDEF_DB\`.\`$TABLO\`
                     WHERE k='kanit';" ;;
    postgresql) pg_sql "$2" "$3" "$HEDEF_DB" \
                    "SELECT v FROM \"$TABLO\" WHERE k='kanit'" ;;
    mongodb)    mongo_js "$2" "$3" "var d = db.getSiblingDB('$KAYNAK_DB').\
$TABLO.findOne({_id:'kanit'}); print(d ? d.v : '')" ;;
    mssql)      ms_sql "$2" "$3" \
                    "SELECT v FROM [$HEDEF_DB].dbo.$TABLO WHERE k='kanit';" ;;
    *) return 3 ;;
    esac
}

temizlik_motor() {   # temizlik_motor <eid> <container> <parola>
    case "$1" in
    mariadb)    my_sql "$2" "$3" "DROP DATABASE IF EXISTS \`$KAYNAK_DB\`;
                    DROP DATABASE IF EXISTS \`$HEDEF_DB\`;" >/dev/null 2>&1 ;;
    postgresql) pg_sql "$2" "$3" postgres "SELECT pg_terminate_backend(pid)
                    FROM pg_stat_activity
                    WHERE datname IN ('$KAYNAK_DB','$HEDEF_DB')
                      AND pid <> pg_backend_pid()" >/dev/null 2>&1
                pg_sql "$2" "$3" postgres \
                    "DROP DATABASE IF EXISTS \"$KAYNAK_DB\"" >/dev/null 2>&1
                pg_sql "$2" "$3" postgres \
                    "DROP DATABASE IF EXISTS \"$HEDEF_DB\"" >/dev/null 2>&1 ;;
    mongodb)    mongo_js "$2" "$3" "
db.getSiblingDB('$KAYNAK_DB').dropDatabase();
db.getSiblingDB('$HEDEF_DB').dropDatabase();" >/dev/null 2>&1 ;;
    mssql)      ms_sql "$2" "$3" "
IF DB_ID('$KAYNAK_DB') IS NOT NULL BEGIN
    ALTER DATABASE [$KAYNAK_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$KAYNAK_DB]; END
IF DB_ID('$HEDEF_DB') IS NOT NULL BEGIN
    ALTER DATABASE [$HEDEF_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$HEDEF_DB]; END" >/dev/null 2>&1
                docker exec "$2" sh -c \
                    'rm -f /var/opt/mssql/backup/e2e_ia.bak' \
                    >/dev/null 2>&1 ;;
    esac
    return 0
}

temizle() {
    [ "$TEMIZLENDI" = "1" ] && return 0
    TEMIZLENDI=1
    if [ -n "$DOKUNULAN$URETILEN" ]; then
        heading "Temizlik"
        local eid C f
        for eid in $DOKUNULAN; do
            C="$(primary_of "$eid")"
            if container_running "$C"; then
                temizlik_motor "$eid" "$C" "$(motor_pw "$eid")"
                log "  $eid: test veritabanları kaldırıldı"
            else
                warn "  $eid: container kapalı, test verisi KALDIRILAMADI"
            fi
        done
        if [ "${E2E_YEDEKLERI_KORU:-0}" = "1" ]; then
            [ -n "$URETILEN" ] \
                && log "  güvenlik yedekleri korundu (KORU=1)"
        else
            for f in $URETILEN; do
                [ -f "$f" ] && rm -f "$f" && log "  silindi: $(basename "$f")"
            done
        fi
    fi
    rm -rf "$E2E_TMP"
    # Ön koşulda düşen bir koşum boş bir günlük bırakıyordu; boş dosya bilgi
    # taşımaz, yalnız logs/ dizinini şişirir.
    [ -s "$E2E_LOG" ] || rm -f "$E2E_LOG"
    return 0
}
# INT/TERM'i lib.sh yakalıyor (kesinti BAŞARI DEĞİLDİR: 130 ile çıkar). Bizim
# temizliğimiz EXIT üzerinde — 130'la çıkarken de, die'da da çalışır.
trap temizle EXIT

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
heading "Ön koşullar"
require_docker
require_cmd python3 flock gzip tar awk df
[ -f "$CATALOG" ] || die "catalog.json bulunamadı: $CATALOG"
[ -x scripts/import.sh ] \
    || die "scripts/import.sh yok ya da çalıştırılamıyor — ölçülecek şey bu."
[ -f "$ENV_FILE" ] \
    || warn ".env yok ($ENV_FILE) — parolalar ortamdan okunacak."
if [ "${#ZAMAN[@]}" -eq 0 ]; then
    warn "'timeout' komutu yok: komutlar zaman aşımı OLMADAN çalışacak."
fi
ok "Ön koşullar hazır — bu koşumun kanıt değeri: $KANIT"
log "Ayrıntılı komut çıktısı: $E2E_LOG"

# import.sh'ın desteklediği motorlar SABİT LİSTE DEĞİL, betiğin kendisinden
# okunuyor: yarın clickhouse eklenirse bu paket onu kendiliğinden kapsar ve
# "desteklenmiyor" cevabı beklemeye devam etmez.
DESTEKLENEN="$(grep -oE '^    mariadb\|postgresql\|mongodb\|redis\|mssql\)' \
    scripts/import.sh | head -1 | tr -d ' )' | tr '|' ' ')"
[ -n "$DESTEKLENEN" ] || DESTEKLENEN="mariadb postgresql mongodb redis mssql"
log "import.sh'ın desteklediği motorlar: $DESTEKLENEN"

SECILEN=""
if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        printf '%s\n' $DESTEKLENEN | grep -qx "$arg" \
            || die "'$arg' desteklenmiyor. Seçenekler: $DESTEKLENEN"
        SECILEN="$SECILEN $arg"
    done
else
    SECILEN="$DESTEKLENEN"
fi

# =============================================================================
# YABANCI DOSYALAR
# =============================================================================
# Yanlış motorun dump'ı testinde ÜRETİLMİŞ dosyalar kullanılıyor: bir motor
# kapalıyken bile bu kontrol çalışsın diye. Dosyalar gerçek dump'ların
# BAŞLANGICINI birebir taşır — biçim tespiti zaten dosyanın başına bakıyor,
# yani ürünün gerçekte gördüğü şeyin aynısını görüyor.
sahte_dosyalar() {
    printf -- '-- MariaDB dump 10.19  Distrib 11.4.2-MariaDB\n' \
        > "$E2E_TMP/sahte_mariadb.sql"
    {   printf '/*!40101 SET @OLD_CHARACTER_SET_CLIENT='
        printf '@@CHARACTER_SET_CLIENT */;\n'
        printf 'CREATE TABLE `t` (`id` int NOT NULL AUTO_INCREMENT,\n'
        printf '  PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;\n'
        printf 'LOCK TABLES `t` WRITE;\nINSERT INTO `t` VALUES (1);\n'
    } >> "$E2E_TMP/sahte_mariadb.sql"
    {   printf -- '--\n-- PostgreSQL database dump\n--\n'
        printf 'SET statement_timeout = 0;\n'
        printf 'SET search_path = public, pg_catalog;\n'
        printf 'CREATE TABLE public.t (id integer NOT NULL);\n'
        printf 'ALTER TABLE public.t OWNER TO root;\n'
        printf 'COPY public.t (id) FROM stdin;\n1\n'
    } > "$E2E_TMP/sahte_postgres.sql"
    printf '\x6d\xe2\x99\x81gerisi arsiv govdesi' \
        > "$E2E_TMP/sahte_mongo.archive"
    printf 'REDIS0011\x00\x00\x00govde' > "$E2E_TMP/sahte_redis.rdb"
    printf 'TAPE\x00\x00\x00\x00MTF govdesi' > "$E2E_TMP/sahte_mssql.bak"
    # Motora özgü tek bir iz taşımayan, taşınabilir SQL: ürün bunu da
    # reddetmeli, çünkü "iki motorda da çalışabilir" ile "bu motorun dump'ı"
    # aynı şey değil.
    printf 'CREATE TABLE t (a int);\nINSERT INTO t VALUES (1);\n' \
        > "$E2E_TMP/belirsiz.sql"
}
sahte_dosyalar

# Bir motora YABANCI olan dosyayı seç: kendi biçimi dışındaki ilk dosya.
yabanci_dosya() {   # yabanci_dosya <eid>
    case "$1" in
        mariadb)    printf '%s' "$E2E_TMP/sahte_postgres.sql" ;;
        postgresql) printf '%s' "$E2E_TMP/sahte_mariadb.sql" ;;
        mongodb)    printf '%s' "$E2E_TMP/sahte_mariadb.sql" ;;
        redis)      printf '%s' "$E2E_TMP/sahte_mongo.archive" ;;
        mssql)      printf '%s' "$E2E_TMP/sahte_postgres.sql" ;;
    esac
}
yabanci_adi() {   # yabanci_adi <eid> — hata mesajında ne yazacağız
    case "$1" in
        mariadb|mssql) printf 'PostgreSQL' ;;
        postgresql|mongodb) printf 'MariaDB' ;;
        redis)      printf 'MongoDB' ;;
    esac
}

redis_cli() {   # redis_cli <container> <parola> <argümanlar…>
    local c="$1" pw="$2"; shift 2
    ( export REDISCLI_AUTH="$pw"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e REDISCLI_AUTH "$c" \
          redis-cli --no-auth-warning "$@" ) 2>>"$E2E_LOG"
}

# =============================================================================
# BİR MOTORUN TAM TURU
# =============================================================================
# Sıra tesadüfi değil ve her adım bir öncekinin kurduğu duruma dayanıyor:
#   kuru koşum  → hedef gerçekten boş mu (T1'in ön koşulu, hiçbir şey yazmaz)
#   T1          → BOŞ hedefe aktar, kanıt kaydını hedeften OKU
#   T2          → aynı dosyayı tekrar aktar; hedef artık DOLU, reddedilmeli
#   T3          → --uzerine-yaz ile aktar; güvenlik yedeği DOSYASI oluşmalı
#   T4/T5       → yabancı ve belirsiz dosyalar reddedilmeli (veriye dokunmaz)
# T2'nin anlamlı olması T1'in gerçekten veri yazmasına bağlı; bu yüzden T1
# düşerse T2 "ölçülemedi" olur, "geçti" değil.

motor_turu() {   # motor_turu <eid>
    local eid="$1"
    local ad1="$eid: boş hedefe aktarma satırları getiriyor"
    local ad2="$eid: dolu hedefe aktarma --uzerine-yaz olmadan reddediliyor"
    local ad3="$eid: --uzerine-yaz önce güvenlik yedeği alıyor"
    local ad4="$eid: yabancı motorun dump'ı reddediliyor"
    local ad5="$eid: motoru belirsiz SQL reddediliyor"

    t_head "$eid"
    local C pw
    C="$(primary_of "$eid")"
    if ! container_running "$C"; then
        if ! docker_yasiyor; then
            t_unknown "$ad1" "docker cevap vermiyor — durum ölçülemedi"
            t_unknown "$ad2" "docker cevap vermiyor"
            t_unknown "$ad3" "docker cevap vermiyor"
            t_unknown "$ad4" "docker cevap vermiyor"
            t_unknown "$ad5" "docker cevap vermiyor"
        else
            t_skip "$ad1" "$eid kapalı (container: $C)"
            t_skip "$ad2" "$eid kapalı"
            t_skip "$ad3" "$eid kapalı"
            t_skip "$ad4" "$eid kapalı"
            t_skip "$ad5" "$eid kapalı"
        fi
        return 0
    fi
    pw="$(motor_pw "$eid")"
    if [ -z "$pw" ]; then
        t_unknown "$ad1" "$eid parolası okunamadı (.env/DB_PASSWORD)"
        t_unknown "$ad2" "parola yok"; t_unknown "$ad3" "parola yok"
        t_unknown "$ad4" "parola yok"; t_unknown "$ad5" "parola yok"
        return 0
    fi

    # --------------------------------------------------- yabancı/belirsiz ---
    # Bu iki kontrol VERİYE DOKUNMAZ (ürün biçim kapısında durur), o yüzden
    # dump üretimi başarısız olsa bile çalışabilsinler diye önce koşuyorlar.
    negatif_bicim "$eid" "$ad4" "$ad5"

    # Redis'in içe aktarma yolu motorun TAMAMINI değiştirir ve container'ı
    # yeniden başlatır. Bu paket o yıkıcı adımı çalıştırmıyor: aynı yol
    # scripts/e2e/backup.sh'ta (restore-redis) zaten uçtan uca ölçülüyor.
    # Burada yalnız KEMER 1'i ölçüyoruz ve onu da --kuru ile, yani tek bayt
    # yazmadan.
    if [ "$eid" = "redis" ]; then
        redis_turu "$ad1" "$ad2" "$ad3" "$C" "$pw"
        return 0
    fi

    # ------------------------------------------------ kaynak veri ve dump ---
    if ! kaynak_yaz "$eid" "$C" "$pw"; then
        t_unknown "$ad1" "kaynak veri yazılamadı — dump üretilemez"
        t_unknown "$ad2" "kaynak veri yazılamadı"
        t_unknown "$ad3" "kaynak veri yazılamadı"
        return 0
    fi
    case " $DOKUNULAN " in
        *" $eid "*) ;;
        *) DOKUNULAN="$DOKUNULAN $eid" ;;
    esac

    local dump
    case "$eid" in
        mongodb) dump="$E2E_TMP/$eid-kaynak.archive.gz" ;;
        mssql)   dump="$E2E_TMP/$eid-kaynak.bak" ;;
        *)       dump="$E2E_TMP/$eid-kaynak.sql" ;;
    esac
    if ! dump_uret "$eid" "$C" "$pw" "$dump"; then
        t_unknown "$ad1" "gerçek dump üretilemedi (ayrıntı: $E2E_LOG)"
        t_unknown "$ad2" "dump üretilemedi"
        t_unknown "$ad3" "dump üretilemedi"
        return 0
    fi
    t_info "dump üretildi: $(basename "$dump") \
($(wc -c < "$dump" | tr -d '[:space:]') bayt)"

    # Aktarma komutu: mongodb dışında hedef veritabanını AÇIKÇA veriyoruz.
    # MongoDB'de arşiv kendi veritabanı adını taşır ve ürün --hedef kabul
    # etmez; orada hedef "motorun tamamı"dır.
    local -a komut=(./scripts/import.sh "$eid" "$dump")
    [ "$eid" = "mongodb" ] || komut+=(--hedef "$HEDEF_DB")

    # ------------------------------------------- hedefi boşalt + kuru koşum -
    hedef_sil "$eid" "$C" "$pw"
    local krc=0
    calistir "$SURE_AKTAR" "kuru koşum ($eid)" "${komut[@]}" --kuru || krc=$?
    if asildi_mi "$krc"; then
        t_unknown "$ad1" "kuru koşum $SURE_AKTAR sn'de bitmedi (rc=$krc)"
        t_unknown "$ad2" "kuru koşum askıda kaldı"
        t_unknown "$ad3" "kuru koşum askıda kaldı"
        return 0
    fi
    if [ "$krc" -eq 5 ]; then
        # Hedef zaten dolu: T1 "boş hedefe aktarma"yı ölçemez. Bu meşru bir
        # durum (mongodb'de hedef motorun tamamıdır ve kurulumda başka veri
        # olabilir), ama "geçti" demek yanlış olurdu.
        t_skip "$ad1" "hedef zaten dolu — 'boş hedefe aktarma' ölçülemez"
    elif [ "$krc" -ne 0 ]; then
        t_unknown "$ad1" \
            "kuru koşum beklenmedik kodla düştü (rc=$krc): $(son_ozet)"
        t_unknown "$ad2" "ön koşul kurulamadı"
        t_unknown "$ad3" "ön koşul kurulamadı"
        return 0
    else
        # ------------------------------------------------------------ T1 ---
        local arc=0
        calistir "$SURE_AKTAR" "aktarma ($eid, boş hedef)" "${komut[@]}" \
            || arc=$?
        if asildi_mi "$arc"; then
            t_unknown "$ad1" "aktarma $SURE_AKTAR sn'de bitmedi (rc=$arc)"
        elif [ "$arc" -ne 0 ]; then
            t_fail "$ad1" "aktarma rc=$arc: $(son_ozet)"
        else
            local okunan rc2=0 kisa=""
            okunan="$(hedef_oku "$eid" "$C" "$pw")" || rc2=$?
            if [ "$rc2" -ne 0 ]; then
                t_unknown "$ad1" \
                    "aktarma 0 döndü ama hedef OKUNAMADI (rc=$rc2)"
            else
                case "$okunan" in
                    *"$KANIT"*) t_ok "$ad1" ;;
                    *) kisa="$(printf '%s' "$okunan" | tr -d '\n' \
                               | cut -c1-40)"
                       t_fail "$ad1" \
                           "hedefte bu koşumun kanıt değeri yok: '$kisa'" ;;
                esac
            fi
        fi
    fi

    # ---------------------------------------------------------------- T2 ---
    # Hedef artık dolu (T1 yazdı ya da zaten doluydu). Aynı komut yeniden
    # çalıştırılıyor: ürün REDDETMELİ ve NE BULDUĞUNU söylemeli.
    local brc=0
    calistir "$SURE_AKTAR" "aktarma ($eid, dolu hedef, kemersiz)" \
        "${komut[@]}" || brc=$?
    if asildi_mi "$brc"; then
        t_unknown "$ad2" "komut $SURE_AKTAR sn'de bitmedi (rc=$brc)"
    elif [ "$brc" -eq 5 ] && son_icerir "HEDEF BOŞ DEĞİL"; then
        # Kod da mesaj da doğru: panel koda, kullanıcı mesaja bakıyor.
        t_ok "$ad2"
    elif [ "$brc" -eq 5 ]; then
        t_fail "$ad2" \
            "5 ile reddetti ama ne bulduğunu söylemedi: $(son_ozet)"
    elif [ "$brc" -eq 0 ]; then
        t_fail "$ad2" "DOLU hedefin üzerine SESSİZCE yazdı — bu kemer kopmuş"
    else
        t_fail "$ad2" "beklenen çıkış kodu 5, gelen $brc: $(son_ozet)"
    fi

    # ---------------------------------------------------------------- T3 ---
    uzerine_yaz_turu "$eid" "$ad3" komut
    return 0
}

# --uzerine-yaz: ÖNCE güvenlik yedeği alınmalı ve DOSYA GERÇEKTEN OLUŞMALI.
# "Yedek aldım" satırını basıp dosya üretmemek, bu üründe en pahalı sessiz
# hatadır: kullanıcı dönüş noktası olduğunu sanarak üzerine yazdırır.
uzerine_yaz_turu() {   # uzerine_yaz_turu <eid> <ad> <komut dizisi adı>
    local eid="$1" ad="$2"
    local -n kmt="$3"

    if [ "${E2E_UZERINE:-1}" = "0" ]; then
        t_skip "$ad" "E2E_UZERINE=0 verildi (tam yedek alınmıyor)"
        return 0
    fi
    local kb; kb="$(bos_kb "$BACKUP_DIR")"
    if [ -z "$kb" ]; then
        t_unknown "$ad" "yedek diskinin boş alanı ölçülemedi (df çalışmadı)"
        return 0
    fi
    if [ "$kb" -lt 5242880 ]; then
        # backup.sh 5 GB altında yedek almayı REDDEDER. Bunu ürün hatası gibi
        # göstermek yanlış olurdu.
        t_skip "$ad" \
            "yedek diskinde 5 GB'dan az yer var ($((kb / 1024)) MB)"
        return 0
    fi

    local dizin="$BACKUP_DIR/$eid/full"
    local once; once="$(find "$dizin" -type f 2>/dev/null | wc -l)"
    local rc=0
    calistir "$SURE_YEDEK" "aktarma ($eid, --uzerine-yaz)" \
        "${kmt[@]}" --uzerine-yaz || rc=$?

    if kilit_carpismasi; then
        t_skip "$ad" \
            "başka bir yedekleme kilidi tutuyor (gece yedeği olabilir)"
        return 0
    fi
    if asildi_mi "$rc"; then
        t_unknown "$ad" "komut $SURE_YEDEK sn'de bitmedi (rc=$rc)"
        return 0
    fi

    # Ekranda duyurulan yol GERÇEKTEN var mı? Sayı karşılaştırması tek başına
    # yetmez: dosya oluşup da adı yanlış duyurulursa kullanıcı felaket günü
    # olmayan bir dosyayı arar.
    local yol sonra
    yol="$(grep -a 'Geri dönüş noktası:' "$SON_CIKTI" | tail -1 \
           | sed 's/^.*Geri dönüş noktası:[[:space:]]*//' | tr -d '\r')"
    sonra="$(find "$dizin" -type f 2>/dev/null | wc -l)"
    [ -n "$yol" ] && [ -f "$yol" ] && URETILEN="$URETILEN $yol"

    if [ "$rc" -ne 0 ]; then
        t_fail "$ad" "--uzerine-yaz aktarması rc=$rc: $(son_ozet)"
    elif [ -z "$yol" ]; then
        t_fail "$ad" "üzerine yazdı ama güvenlik yedeğinin adını hiç duyurmadı"
    elif [ ! -f "$yol" ]; then
        t_fail "$ad" "duyurulan dönüş noktası DOSYA OLARAK YOK: $yol"
    elif [ "$sonra" -le "$once" ]; then
        t_fail "$ad" "yedek dizinine yeni dosya eklenmedi ($once → $sonra)"
    else
        t_ok "$ad"
        t_info "dönüş noktası: $(basename "$yol")"
    fi
    return 0
}

# Redis: yalnız KEMER 1, hem de --kuru ile (tek bayt yazılmaz).
redis_turu() {   # redis_turu <ad1> <ad2> <ad3> <container> <parola>
    local ad1="$1" ad2="$2" ad3="$3" C="$4" pw="$5"
    local neden="Redis'te içe aktarma motorun TAMAMINI değiştirip"
    neden="$neden container'ı yeniden başlatır; bu paket o yıkıcı adımı"
    neden="$neden koşmuyor (aynı yol scripts/e2e/backup.sh'ta ölçülüyor)"
    t_skip "$ad1" "$neden"
    t_skip "$ad3" "$neden"

    local anahtar rc=0
    anahtar="$(redis_cli "$C" "$pw" DBSIZE)" || rc=$?
    anahtar="${anahtar//[[:space:]]/}"
    if [ "$rc" -ne 0 ] || [ -z "$anahtar" ]; then
        t_unknown "$ad2" \
            "redis DBSIZE okunamadı — hedefin dolu olduğu ölçülemedi"
        return 0
    fi
    if [ "$anahtar" -eq 0 ]; then
        t_skip "$ad2" "redis boş: 'dolu hedef reddediliyor mu' ölçülemez"
        return 0
    fi
    local krc=0
    calistir "$SURE_AKTAR" "kuru koşum (redis, dolu hedef)" \
        ./scripts/import.sh redis "$E2E_TMP/sahte_redis.rdb" --kuru || krc=$?
    if asildi_mi "$krc"; then
        t_unknown "$ad2" "kuru koşum $SURE_AKTAR sn'de bitmedi (rc=$krc)"
    elif [ "$krc" -eq 5 ] && son_icerir "HEDEF BOŞ DEĞİL"; then
        t_ok "$ad2"
    elif [ "$krc" -eq 5 ]; then
        t_fail "$ad2" \
            "5 ile reddetti ama ne bulduğunu söylemedi: $(son_ozet)"
    elif [ "$krc" -eq 0 ]; then
        t_fail "$ad2" \
            "$anahtar anahtarlık redis'i BOŞ saydı — yazılabilirdi"
    else
        t_fail "$ad2" "beklenen çıkış kodu 5, gelen $krc: $(son_ozet)"
    fi
    return 0
}

# Yanlış motorun dump'ı ve motoru belirsiz SQL. İkisi de ürünün BİÇİM
# kapısında durmalı (çıkış 4) — veriye hiç dokunmadan.
negatif_bicim() {   # negatif_bicim <eid> <ad4> <ad5>
    local eid="$1" ad4="$2" ad5="$3" f rc
    f="$(yabanci_dosya "$eid")"
    rc=0
    calistir "$SURE_ISTEMCI" "yabancı dump ($eid)" \
        ./scripts/import.sh "$eid" "$f" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "$ad4" "komut $SURE_ISTEMCI sn'de bitmedi (rc=$rc)"
    elif [ "$rc" -eq 4 ]; then
        t_ok "$ad4"
    elif [ "$rc" -eq 0 ]; then
        t_fail "$ad4" \
            "$(yabanci_adi "$eid") dump'ını $eid'e AKTARDI — sessiz felaket"
    else
        t_fail "$ad4" "beklenen çıkış kodu 4, gelen $rc: $(son_ozet)"
    fi

    rc=0
    calistir "$SURE_ISTEMCI" "belirsiz SQL ($eid)" \
        ./scripts/import.sh "$eid" "$E2E_TMP/belirsiz.sql" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "$ad5" "komut $SURE_ISTEMCI sn'de bitmedi (rc=$rc)"
    elif [ "$rc" -eq 4 ]; then
        t_ok "$ad5"
    elif [ "$rc" -eq 0 ]; then
        t_fail "$ad5" "hangi motora ait olduğu belirsiz SQL'i aktardı"
    else
        t_fail "$ad5" "beklenen çıkış kodu 4, gelen $rc: $(son_ozet)"
    fi
    return 0
}

# =============================================================================
# GENEL KONTROLLER (motordan bağımsız)
# =============================================================================
# Çıkış kodları panelin ve betiklerin sözleşmesi: "kapsam dışı motor" ile
# "hedef dolu" farklı kodlar vermezse arayüz ikisine de aynı cümleyi yazar.
genel_kontroller() {
    t_head "genel"
    local rc

    rc=0
    calistir "$SURE_ISTEMCI" "kapsam dışı motor" \
        ./scripts/import.sh cassandra "$E2E_TMP/belirsiz.sql" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "kapsam dışı motor 3 ile reddediliyor" "komut askıda kaldı"
    elif [ "$rc" -eq 3 ] && son_icerir "DESTEKLENMİYOR"; then
        t_ok "kapsam dışı motor 3 ile reddediliyor"
    else
        t_fail "kapsam dışı motor 3 ile reddediliyor" \
            "beklenen 3 + 'DESTEKLENMİYOR', gelen rc=$rc: $(son_ozet)"
    fi

    rc=0
    calistir "$SURE_ISTEMCI" "bilinmeyen motor" \
        ./scripts/import.sh yokboylebirmotor "$E2E_TMP/belirsiz.sql" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "bilinmeyen motor 2 ile reddediliyor" "komut askıda kaldı"
    elif [ "$rc" -eq 2 ]; then
        t_ok "bilinmeyen motor 2 ile reddediliyor"
    else
        t_fail "bilinmeyen motor 2 ile reddediliyor" \
            "beklenen 2, gelen rc=$rc: $(son_ozet)"
    fi

    # Aşağıdaki iki kontrol motorun AÇIK olmasını gerektiriyor: import.sh
    # önce motorun ayakta olduğuna bakıyor (çıkış 6), dosyaya sonra. Bu sıra
    # doğru — kapalı bir motora dosya doğrulamak anlamsız — ama testin de bunu
    # bilmesi gerek, yoksa "olmayan dosya" kontrolü 6 görüp DÜŞTÜ yazardı.
    local acik="" kapali="" eid
    for eid in $SECILEN; do
        if container_running "$(primary_of "$eid")"; then
            [ -n "$acik" ] || acik="$eid"
        else
            [ -n "$kapali" ] || kapali="$eid"
        fi
    done

    if [ -z "$acik" ]; then
        t_skip "olmayan dosya 2 ile reddediliyor" \
            "desteklenen motorların hepsi kapalı"
    else
        rc=0
        calistir "$SURE_ISTEMCI" "olmayan dosya" \
            ./scripts/import.sh "$acik" "$E2E_TMP/hic-olmayan-dosya.sql" \
            || rc=$?
        if asildi_mi "$rc"; then
            t_unknown "olmayan dosya 2 ile reddediliyor" "komut askıda kaldı"
        elif [ "$rc" -eq 2 ]; then
            t_ok "olmayan dosya 2 ile reddediliyor"
        else
            t_fail "olmayan dosya 2 ile reddediliyor" \
                "beklenen 2, gelen rc=$rc: $(son_ozet)"
        fi
    fi

    if [ -z "$kapali" ]; then
        t_skip "kapalı motor 6 ile reddediliyor" \
            "desteklenen motorların hepsi açık — kapalı motor senaryosu yok"
    else
        rc=0
        calistir "$SURE_ISTEMCI" "kapalı motor" \
            ./scripts/import.sh "$kapali" "$E2E_TMP/belirsiz.sql" || rc=$?
        if asildi_mi "$rc"; then
            t_unknown "kapalı motor 6 ile reddediliyor" "komut askıda kaldı"
        elif [ "$rc" -eq 6 ] && son_icerir "stack.sh enable"; then
            t_ok "kapalı motor 6 ile reddediliyor"
        elif [ "$rc" -eq 6 ]; then
            t_fail "kapalı motor 6 ile reddediliyor" \
                "doğru kodla reddetti ama nasıl açılacağını söylemedi"
        else
            t_fail "kapalı motor 6 ile reddediliyor" \
                "beklenen 6, gelen rc=$rc ($kapali): $(son_ozet)"
        fi
    fi
    return 0
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
BASLANGIC="$(date +%s)"
heading "E2E içe aktarma testi — $(date '+%Y-%m-%d %H:%M')"
log "Test veritabanları: $KAYNAK_DB → $HEDEF_DB (sonunda silinir)"
if [ "${E2E_UZERINE:-1}" = "0" ]; then
    log "Güvenlik yedeği kontrolü KAPALI (E2E_UZERINE=0)."
else
    warn "Bu paket --uzerine-yaz kontrolü için GERÇEK bir tam yedek aldırır"
    warn "  (./scripts/backup.sh <motor>): disk ve zaman ister."
    warn "  Atlamak için: E2E_UZERINE=0 ./scripts/e2e/import.sh"
fi

for motor in $SECILEN; do
    motor_turu "$motor"
done
genel_kontroller

temizle

SURE=$(( $(date +%s) - BASLANGIC ))
t_info "süre: $((SURE / 60))m $((SURE % 60))s · kanıt değeri: $KANIT"
# Hata ya da ÖLÇÜLEMEYEN kontrol varsa günlük DURUYOR: tek ayrıntı orada.
if [ "$E2E_FAIL" -eq 0 ] && [ "$E2E_UNKNOWN" -eq 0 ]; then
    rm -f "$E2E_LOG"
else
    t_info "komut çıktılarının tamamı: $E2E_LOG"
fi

# Sayaçlar, özet ve ÇIKIŞ KODU ortak kütüphanede (scripts/e2e/lib.sh):
#   0 çalışan kontrollerin hepsi geçti · 1 başarısız/ölçülemedi var
#   2 HİÇBİR KONTROL ÇALIŞMADI — "hepsi yeşil" değil, "hiçbir şey ölçülmedi"
#   3 EKSİK KAPSAM — çalışanlar geçti ama atlama sayısı ölçülenden çok
e2e_finish
exit $?
