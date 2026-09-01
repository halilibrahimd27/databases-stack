#!/bin/bash
# =============================================================================
# databases-stack — E2E testi: AÇ / KAPAT ve VERİ KALICILIĞI
# =============================================================================
# Ürünün en temel iddiasını sınar: "motoru kapatınca veriniz SİLİNMEZ."
#
# Katalogdaki HER kayıt için (izleme aracı dahil) şu döngü çalışır:
#     aç → sağlıklı olmasını bekle → VERİ YAZ → geri oku → KAPAT →
#     tekrar aç → verinin YERİNDE olduğunu doğrula → yazdığını sil
#
# Neden "container ayakta" kontrolü yetmez: kapatmayı controller yapar
# (./stack.sh disable) ve controller yalnız `stop` demez, container'ı `rm -f`
# ile SİLER (bkz. controller/app.py: do_deactivate). Yeniden açıldığında
# container YENİDİR; veri ona yalnızca adlandırılmış volume'dan gelebilir.
# Eksik bir volume tanımı, yanlış bir data_path ya da imaj değişiminde kayan
# bir veri dizini tam burada patlar: container ayakta, healthcheck yeşil, panel
# açılıyor — ama içi boş. Dışarıdan hiçbir hata görünmez; kullanıcı kaybı ancak
# veriyi arayınca fark eder. Bu yüzden bu betik veri YAZAR, motoru gerçekten
# KAPATIR ve geri OKUR; ayrıca container KİMLİĞİNİN değiştiğini de doğrular —
# kapatma gerçekleşmediyse "veri duruyor" sonucu hiçbir şey kanıtlamaz, o
# durumda GEÇTİ değil ATLANDI der.
#
# Kullanım (yığın kökünden):
#   ./scripts/e2e/lifecycle.sh                 # katalogdaki bütün kayıtlar
#   ./scripts/e2e/lifecycle.sh mariadb redis   # yalnız seçilenler
#
# Ayarlar (ortam değişkeni):
#   E2E_ACTIVATE_TIMEOUT   ./stack.sh enable|disable üst sınırı (vars. 900 sn)
#   E2E_READY_TIMEOUT      hazır olma beklemesi (motor başına varsayılanı ezer)
#   E2E_QUERY_TIMEOUT      tek istemci komutu üst sınırı (vars. 90 sn)
#
# Bitince kurulum BULDUĞU HÂLE döner: testten önce kapalı olan motorlar tekrar
# kapatılır, yazılan probe verisi silinir. Art arda iki kez çalıştırılabilir;
# önceki çalıştırma yarıda kesildiyse artıklar yazmadan ÖNCE temizlenir.
#
# Süre: motor başına iki soğuk açılış demek. Tam katalog için 30-60 dakika
# ayırın (Cassandra ve MSSQL tek başına birkaç dakika alır).
# =============================================================================
# set -e YOK: bir motorun düşmesi diğerlerini ölçmemizi engellememeli. Her
# kontrol tek tek raporlanır, çıkış kodu sonda belirlenir.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=../lib/common.sh
source scripts/lib/common.sh
load_env

ALAN="Aç/kapat ve veri kalıcılığı"

# =============================================================================
# TEST DEFTERİ
# =============================================================================
T_PASS=0; T_FAIL=0; T_SKIP=0
FAILED_NAMES=()

t_ok()   { T_PASS=$((T_PASS+1)); printf '  %s[GEÇTİ]%s   %s\n' "$GREEN" "$NC" "$1"; }
t_fail() { T_FAIL=$((T_FAIL+1)); FAILED_NAMES+=("$1")
           printf '  %s[KALDI]%s   %s\n            ↳ %s\n' "$RED" "$NC" "$1" "$2"; }
# ATLAMA da rapor edilir. Sessizce atlanan test "geçti" sanılır; bu betikte
# yapılabilecek en pahalı hata odur — bu yüzden atlamanın SEBEBİ zorunlu.
t_skip() { T_SKIP=$((T_SKIP+1)); printf '  %s[ATLANDI]%s %s\n            ↳ %s\n' "$YELLOW" "$NC" "$1" "$2"; }

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
require_docker
# Hiçbir bekleme sonsuz olmayacak; bunun tek garantisi `timeout`.
command -v timeout >/dev/null 2>&1 || die "'timeout' (coreutils) gerekli: bu betikteki her bekleme üst sınırlı olmalı."
command -v python3 >/dev/null 2>&1 || die "'python3' gerekli (katalog ve JSON cevapları onunla okunuyor)."
[ -f "$ENV_FILE" ] || die ".env yok ($ENV_FILE). Önce ./install.sh çalıştırın."
[ -n "${DB_PASSWORD:-}" ] || die ".env içinde DB_PASSWORD boş — hiçbir motora bağlanılamaz."
container_running controller \
    || die "controller çalışmıyor. Aç/kapat işini controller yapar (bellek planı orada hesaplanır). Önce: ./stack.sh up"

ACT_TIMEOUT="${E2E_ACTIVATE_TIMEOUT:-900}"
DEX_TIMEOUT="${E2E_QUERY_TIMEOUT:-90}"

# Başarısızlık günlükleri burada durur; test tamamen temiz geçerse sonda silinir.
WORK="$STACK_ROOT/logs/e2e"
mkdir -p "$WORK" || die "Çalışma dizini açılamadı: $WORK"

# Probe adları SABİT (rastgele değil): yarıda kesilmiş bir çalıştırmadan kalan
# artığı bir sonraki çalıştırma bulup silebilsin diye. Değeri ise her turda
# FARKLI — böylece "geri okuduğum kayıt gerçekten AZ ÖNCE yazdığım kayıt mı?"
# sorusu cevaplanır; eski bir artık doğru cevabı taklit edemez.
TAG_SNAKE="e2e_lifecycle"                 # SQL/CQL/vhost/Grafana klasörü adı
TAG_DASH="e2e-lifecycle"                  # ES indeksi, Kafka topic'i, S3 bucket
TOKEN="lc$(date +%s)${RANDOM}"            # yalnız harf+rakam: hiçbir istemcide kaçış gerektirmez

# =============================================================================
# KATALOG — bağlantı bilgisinin TEK kaynağı
# =============================================================================
# Portlar, servis adları, kullanıcı/veritabanı adları ve hangi .env anahtarının
# parolayı taşıdığı katalogdan okunur. Sabit yazılsaydı katalog değiştiğinde bu
# test eski gerçeği doğrulamaya devam eder, yeşil kalır ve ayrışmayı kimse fark
# etmezdi.
CAT_DUMP="$WORK/catalog.fields"
# PYTHONIOENCODING: motor adları ASCII değil ("İzleme"). LANG=C olan bir cron
# ya da ssh oturumunda python varsayılan kodlamayla bunu yazamaz ve döküm
# yarım kalırdı — check-catalog.sh de aynı sebeple bunu açıkça veriyor.
PYTHONIOENCODING=utf-8 python3 - "$CATALOG" > "$CAT_DUMP" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
for e in cat["engines"]:
    c  = e.get("connection") or {}
    p  = e.get("panel") or {}
    cp = e.get("client_ports") or []
    print("|".join([
        e["id"],                                   # 1
        e.get("name", ""),                         # 2
        e.get("kind", "database"),                 # 3
        e.get("primary_service", ""),              # 4
        e.get("profile", ""),                      # 5
        str(c.get("username") or ""),              # 6
        str(c.get("database") or ""),              # 7
        str(c.get("password_env") or ""),          # 8
        str(cp[0]["port"]) if cp else "",          # 9
        str(p.get("port") or ""),                  # 10
    ]))
PY
[ -s "$CAT_DUMP" ] || die "catalog.json okunamadı: $CATALOG"

cat_field()     { awk -F'|' -v id="$1" -v n="$2" '$1==id {print $n; exit}' "$CAT_DUMP"; }
all_engine_ids(){ awk -F'|' '{print $1}' "$CAT_DUMP"; }

# Parola: katalog hangi .env anahtarını okuyacağımızı söyler; anahtar BOŞSA
# compose'un kendi kuralı geçerlidir → ${X:-${DB_PASSWORD}}. Bu satır olmasaydı
# .env'de "MARIADB_PASSWORD=" (boş) bırakan her kurulumda test boş parolayla
# bağlanmaya çalışır, "Access denied" alır ve hatayı motorda arardı.
pw_of() {
    local var val=""
    var="$(cat_field "$1" 8)"
    # İzleme aracının katalogda connection bloğu yoktur (veritabanı değil);
    # Grafana parolasını compose ${GRAFANA_PASSWORD:-${DB_PASSWORD}} ile okur.
    [ "$1" = "monitoring" ] && var="GRAFANA_PASSWORD"
    [ -n "$var" ] && val="${!var:-}"
    [ -n "$val" ] || val="${DB_PASSWORD:-}"
    printf '%s' "$val"
}

# Kullanıcı adı: katalog varsayılanı + compose'un GERÇEKTEN okuduğu env
# override'ı. Kullanıcı adını .env'de değiştiren bir kurulumda katalog
# varsayılanıyla bağlanmak "authentication failed" verir; hata motorda sanılır,
# oysa yalnız test yanlış hesapla bağlanmıştır.
user_of() {
    local u; u="$(cat_field "$1" 6)"
    case "$1" in
        postgresql) u="${POSTGRES_USER:-$u}" ;;
        mongodb)    u="${MONGO_USER:-$u}" ;;
        cassandra)  u="${CASSANDRA_USER:-$u}" ;;
        clickhouse) u="${CLICKHOUSE_USER:-$u}" ;;
        rabbitmq)   u="${RABBITMQ_USER:-$u}" ;;
        neo4j)      u="${NEO4J_USER:-$u}" ;;
        minio)      u="${MINIO_ROOT_USER:-$u}" ;;
        monitoring) u="${GRAFANA_USER:-admin}" ;;
    esac
    printf '%s' "$u"
}

db_of() {
    local d; d="$(cat_field "$1" 7)"
    case "$1" in mariadb|postgresql) d="${DEFAULT_DATABASE:-$d}" ;; esac
    printf '%s' "$d"
}

# Motorun ŞU ANKİ ana kopya CONTAINER'ı.
# primary_of() topolojide kayıt yoksa MOTOR KİMLİĞİNİ döndürür. Kimliği birincil
# servis adıyla aynı olan motorlarda (mariadb → mariadb) bu tesadüfen doğrudur;
# olmayanlarda DEĞİLDİR: "monitoring" diye bir container yoktur, o kaydın
# birincil servisi "grafana"dır. Katalog kaydına düşmeseydik izleme aracı her
# koşulda "kapalı" görünür ve testi sessizce atlanırdı.
primary_container() {
    local eid="$1" p
    p="$(primary_of "$eid")"
    [ "$p" = "$eid" ] && p="$(cat_field "$eid" 4)"
    printf '%s' "$p"
}

eng_up() { container_running "$(primary_container "$1")"; }

health_note() {
    docker inspect -f '{{.State.Status}}{{if .State.Health}} / sağlık: {{.State.Health.Status}}{{end}}' "$1" 2>/dev/null \
        || printf 'container yok'
}
cid_of() { local id; id="$(docker inspect -f '{{.Id}}' "$1" 2>/dev/null)"; printf '%.12s' "$id"; }

# Soğuk açılış süreleri çok farklı (Redis 5 sn, Cassandra 3 dakika). Değerler
# compose'daki healthcheck start_period'larından bir tık cömerttir: "hazır
# olmadı" demek gerçek bir arıza olsun, yavaş diskin faturası olmasın.
ready_timeout() {
    [ -n "${E2E_READY_TIMEOUT:-}" ] && { printf '%s' "$E2E_READY_TIMEOUT"; return; }
    case "$1" in
        cassandra)              printf '420' ;;
        mssql|elasticsearch)    printf '300' ;;
        kafka|neo4j|monitoring) printf '240' ;;
        *)                      printf '180' ;;
    esac
}

client_of() {
    case "$1" in
        mariadb)       printf 'mariadb istemcisi' ;;
        postgresql)    printf 'psql' ;;
        mongodb)       printf '%s' "${MONGO_SHELL:-mongosh}" ;;
        redis)         printf 'redis-cli' ;;
        mssql)         printf 'sqlcmd' ;;
        cassandra)     printf 'cqlsh' ;;
        elasticsearch) printf 'curl (REST)' ;;
        kafka)         printf 'kafka-topics.sh' ;;
        rabbitmq)      printf 'rabbitmqctl' ;;
        clickhouse)    printf 'clickhouse-client' ;;
        neo4j)         printf 'cypher-shell' ;;
        minio)         printf 'mc (S3)' ;;
        monitoring)    printf 'Grafana HTTP API' ;;
        *)             printf 'istemci' ;;
    esac
}
port_note() {
    local p; p="$(cat_field "$1" 9)"
    [ -n "$p" ] || p="$(cat_field "$1" 10)"   # araç kaydının istemci portu yok, panel portu var
    [ -n "$p" ] && printf ' (port %s)' "$p"
}

# =============================================================================
# İSTEMCİ ÇAĞRILARI
# =============================================================================
# Hepsi `docker exec <container> <istemci>` — host'ta veritabanı istemcisi YOK.
# Parolalar komut satırına DEĞİL ortama konur (-e): komut satırında olsalardı
# host'ta `ps` çıktısında ve container'ın /proc'unda görünürlerdi. Bu, depodaki
# backup.sh ve scripts/replication/*.sh ile aynı desen.
dex()  { timeout "$DEX_TIMEOUT" docker exec "$@"; }
dexi() { timeout "$DEX_TIMEOUT" docker exec -i "$@"; }

# --- MariaDB ---------------------------------------------------------------
_my() {
    MYSQL_PWD="$(pw_of mariadb)" dex -e MYSQL_PWD "$(primary_container mariadb)" \
        mariadb -u "$(user_of mariadb)" -N -B -e "$1"
}
probe_mariadb() { _my "SELECT 1;" >/dev/null 2>&1; }
write_mariadb() {
    local db; db="$(db_of mariadb)"
    _my "CREATE DATABASE IF NOT EXISTS \`$db\`;
         CREATE TABLE IF NOT EXISTS \`$db\`.$TAG_SNAKE (k VARCHAR(32) PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
         REPLACE INTO \`$db\`.$TAG_SNAKE (k,v) VALUES ('probe','$TOKEN');"
}
read_mariadb()  { local db; db="$(db_of mariadb)"; _my "SELECT v FROM \`$db\`.$TAG_SNAKE WHERE k='probe';" 2>/dev/null; }
clean_mariadb() { local db; db="$(db_of mariadb)"; _my "DROP TABLE IF EXISTS \`$db\`.$TAG_SNAKE;"; }

# --- PostgreSQL ------------------------------------------------------------
_pg() {
    dex -e PGPASSWORD="$(pw_of postgresql)" "$(primary_container postgresql)" \
        psql -X -q -A -t -v ON_ERROR_STOP=1 -U "$(user_of postgresql)" -d "$(db_of postgresql)" -c "$1"
}
probe_postgresql() { _pg "SELECT 1;" >/dev/null 2>&1; }
write_postgresql() {
    _pg "CREATE TABLE IF NOT EXISTS $TAG_SNAKE (k text PRIMARY KEY, v text);
         DELETE FROM $TAG_SNAKE;
         INSERT INTO $TAG_SNAKE (k,v) VALUES ('probe','$TOKEN');"
}
read_postgresql()  { _pg "SELECT v FROM $TAG_SNAKE WHERE k='probe';" 2>/dev/null; }
clean_postgresql() { _pg "DROP TABLE IF EXISTS $TAG_SNAKE;"; }

# --- MongoDB ---------------------------------------------------------------
# MONGO_SHELL: 5.0 öncesinde mongosh yoktur, .env onu `mongo`ya çevirebilir —
# compose healthcheck'i de aynı değişkeni okur, biz de ona uyuyoruz.
_mongo() {
    dex -e M_PW="$(pw_of mongodb)" -e M_USER="$(user_of mongodb)" \
        -e M_SH="${MONGO_SHELL:-mongosh}" "$(primary_container mongodb)" \
        sh -c 'exec "$M_SH" --quiet -u "$M_USER" -p "$M_PW" --authenticationDatabase admin --eval "$1"' sh "$1"
}
probe_mongodb() { _mongo 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; }
write_mongodb() {
    _mongo "db.getSiblingDB('$TAG_SNAKE').probe.replaceOne({_id:'probe'},{_id:'probe',v:'$TOKEN'},{upsert:true})" >/dev/null
}
read_mongodb()  { _mongo "var d=db.getSiblingDB('$TAG_SNAKE').probe.findOne({_id:'probe'}); print(d ? d.v : '')" 2>/dev/null; }
clean_mongodb() { _mongo "db.getSiblingDB('$TAG_SNAKE').dropDatabase()" >/dev/null; }

# --- Redis -----------------------------------------------------------------
# Bilerek SAVE/BGSAVE ÇAĞIRMIYORUZ: elle kaydettirseydik kalıcılık ayarı
# (REDIS_APPENDONLY) kapalı olan bir kurulumda da test geçerdi. Ölçmek
# istediğimiz tam olarak şu: normal kapanışta veri kendiliğinden kalıyor mu?
_redis() { dex -e REDISCLI_AUTH="$(pw_of redis)" "$(primary_container redis)" redis-cli --no-auth-warning "$@"; }
probe_redis() { [ "$(_redis PING 2>/dev/null | tr -d '[:space:]')" = "PONG" ]; }
write_redis() { _redis SET "$TAG_SNAKE:probe" "$TOKEN" >/dev/null; }
read_redis()  { _redis GET "$TAG_SNAKE:probe" 2>/dev/null; }
clean_redis() { _redis DEL "$TAG_SNAKE:probe" >/dev/null; }

# --- SQL Server ------------------------------------------------------------
# sqlcmd'nin yeri imaj sürümüyle değişti (mssql-tools → mssql-tools18). Yolu
# sabit yazmak yerine container'da arıyoruz: imaj değişince test "bağlanamadı"
# demek yerine ya doğru yoldan çalışsın ya da NEDENİNİ söyleyip atlasın.
_sqlcmd_bin() {
    docker exec "$1" sh -c '
        for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
            [ -x "$p" ] && { printf "%s" "$p"; exit 0; }
        done
        command -v sqlcmd 2>/dev/null && exit 0
        exit 1' 2>/dev/null
}
_sq() {
    local c bin
    c="$(primary_container mssql)"
    bin="$(_sqlcmd_bin "$c")" || return 1
    [ -n "$bin" ] || return 1
    # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir (yoksa
    # başarısız yazma "başarılı" sanılırdı). -h -1 -W: başlıksız, kırpılmış çıktı.
    SQLCMDPASSWORD="$(pw_of mssql)" dex -e SQLCMDPASSWORD "$c" \
        "$bin" -S localhost -U "$(user_of mssql)" -C -b -h -1 -W -Q "SET NOCOUNT ON; $1"
}
probe_mssql() { _sq "SELECT 1;" >/dev/null 2>&1; }
precheck_mssql() {
    _sqlcmd_bin "$(primary_container mssql)" >/dev/null 2>&1 \
        || printf '%s' "container'da sqlcmd yok (/opt/mssql-tools18/bin ve /opt/mssql-tools/bin boş) — MSSQL_IMAGE değiştirilmiş olabilir"
}
write_mssql() {
    _sq "IF OBJECT_ID('dbo.$TAG_SNAKE','U') IS NULL CREATE TABLE dbo.$TAG_SNAKE (k varchar(32) PRIMARY KEY, v varchar(64));
         DELETE FROM dbo.$TAG_SNAKE;
         INSERT INTO dbo.$TAG_SNAKE (k,v) VALUES ('probe','$TOKEN');"
}
read_mssql()  { _sq "SELECT v FROM dbo.$TAG_SNAKE WHERE k='probe';" 2>/dev/null; }
clean_mssql() { _sq "IF OBJECT_ID('dbo.$TAG_SNAKE','U') IS NOT NULL DROP TABLE dbo.$TAG_SNAKE;"; }

# --- Cassandra -------------------------------------------------------------
# Kullanıcı adı da -e ile geçiyor: tek tırnaklı sh -c içindeki değişkenler
# HOST'ta değil CONTAINER'da çözülür (backup.sh'te bu tam olarak bir hataydı).
_cql() {
    dex -e CQLSH_USER="$(user_of cassandra)" -e CQLSH_PW="$(pw_of cassandra)" \
        "$(primary_container cassandra)" \
        sh -c 'exec cqlsh -u "$CQLSH_USER" -p "$CQLSH_PW" -e "$1"' sh "$1"
}
probe_cassandra() { _cql "SELECT release_version FROM system.local;" >/dev/null 2>&1; }
write_cassandra() {
    _cql "CREATE KEYSPACE IF NOT EXISTS $TAG_SNAKE WITH replication={'class':'SimpleStrategy','replication_factor':1};" >/dev/null \
        && _cql "CREATE TABLE IF NOT EXISTS $TAG_SNAKE.probe (k text PRIMARY KEY, v text);" >/dev/null \
        && _cql "INSERT INTO $TAG_SNAKE.probe (k,v) VALUES ('probe','$TOKEN');" >/dev/null
}
# cqlsh tabloyu çerçeveli basar: başlık, tire satırı, boş satırlar, "(1 rows)".
# Değeri bunları eleyerek çıkarıyoruz.
read_cassandra() {
    _cql "SELECT v FROM $TAG_SNAKE.probe WHERE k='probe';" 2>/dev/null \
        | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -vE '^$|^-+$|^v$|^\([0-9]+ rows?\)$' | head -1
}
clean_cassandra() { _cql "DROP KEYSPACE IF EXISTS $TAG_SNAKE;" >/dev/null; }

# --- Elasticsearch ---------------------------------------------------------
_es() {
    dex -e ES_USER="$(user_of elasticsearch)" -e ES_PW="$(pw_of elasticsearch)" \
        "$(primary_container elasticsearch)" \
        sh -c 'exec curl -sS --max-time 30 -u "$ES_USER:$ES_PW" "$@"' sh "$@"
}
probe_elasticsearch() { _es -f "http://127.0.0.1:9200/_cluster/health" >/dev/null 2>&1; }
# refresh=true: belge yazıldıktan HEMEN sonra aranabilir olsun — yoksa "yazdım
# ama okuyamadım" hatası, aslında yalnız 1 saniyelik refresh gecikmesi olurdu.
write_elasticsearch() {
    _es -f -X PUT -H "Content-Type: application/json" -d "{\"v\":\"$TOKEN\"}" \
        "http://127.0.0.1:9200/$TAG_DASH/_doc/probe?refresh=true" >/dev/null
}
read_elasticsearch() {
    _es -f "http://127.0.0.1:9200/$TAG_DASH/_doc/probe" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("_source",{}).get("v",""))
except Exception: print("")'
}
clean_elasticsearch() { _es -f -X DELETE "http://127.0.0.1:9200/$TAG_DASH" >/dev/null; }

# --- Kafka -----------------------------------------------------------------
_kt() { dex "$(primary_container kafka)" /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 "$@"; }
probe_kafka() { _kt --list >/dev/null 2>&1; }
write_kafka() {
    # Topic SİLME KRaft'ta eşzamansızdır: az önce silinmiş bir topic'i hemen
    # yaratmak "marked for deletion" hatası verir. Bu tam olarak yarıda kesilmiş
    # bir çalıştırmanın ardından olur — test KENDİ temizliği yüzünden
    # düşmesin diye create birkaç kez deneniyor (üst sınır: 30 sn).
    local i=0
    until _kt --create --if-not-exists --topic "$TAG_DASH" --partitions 1 --replication-factor 1 >/dev/null 2>&1; do
        i=$((i+1)); [ "$i" -ge 6 ] && return 1
        sleep 5
    done
    printf '%s\n' "$TOKEN" | dexi "$(primary_container kafka)" \
        /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic "$TAG_DASH" >/dev/null 2>&1
}
# SON mesajı okuyoruz, ilkini değil: yarıda kesilmiş bir çalıştırmadan kalan
# eski mesaj topic'te duruyorsa --from-beginning onu döndürür ve test, sağlam
# bir kurulumu "veri değişmiş" diye düşürürdü. Offset alınamazsa baştan
# okumaya düşüyoruz — ölçmemektense zayıf ölçmek yeğdir, ama sebebi burada yazılı.
read_kafka() {
    local c end off=""
    c="$(primary_container kafka)"
    end="$(dex "$c" /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 \
              --topic "$TAG_DASH" --time -1 2>/dev/null | tr -d '\r' | head -1)"
    end="${end##*:}"
    case "$end" in ''|*[!0-9]*) off="" ;; *) [ "$end" -gt 0 ] && off=$((end-1)) ;; esac
    if [ -n "$off" ]; then
        dex "$c" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
            --topic "$TAG_DASH" --partition 0 --offset "$off" --max-messages 1 --timeout-ms 20000 2>/dev/null \
            | tr -d '\r' | head -1
    else
        dex "$c" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
            --topic "$TAG_DASH" --from-beginning --max-messages 1 --timeout-ms 20000 2>/dev/null \
            | tr -d '\r' | head -1
    fi
}
clean_kafka() { _kt --delete --topic "$TAG_DASH" >/dev/null 2>&1; }

# --- RabbitMQ --------------------------------------------------------------
# Kuyruktaki MESAJ değil, TANIM kalıcılığı ölçülüyor — backup.sh de RabbitMQ'da
# tanımları yedekler ("mesajlar geçicidir"). Token'ı vhost ADINDA taşıyoruz:
# rabbitmqctl ile mesaj üretilemez, ama vhost dayanıklı yazılır ve
# /var/lib/rabbitmq volume'unda durur — kalıcılık sorusu için doğru nesne budur.
_rmq() { dex "$(primary_container rabbitmq)" rabbitmqctl "$@"; }
probe_rabbitmq() { dex "$(primary_container rabbitmq)" rabbitmq-diagnostics -q ping >/dev/null 2>&1; }
write_rabbitmq() { _rmq add_vhost "${TAG_SNAKE}_$TOKEN" >/dev/null; }
read_rabbitmq() {
    _rmq -q list_vhosts name 2>/dev/null | tr -d '\r' \
        | grep "^${TAG_SNAKE}_" | head -1 | sed "s/^${TAG_SNAKE}_//"
}
clean_rabbitmq() {
    local v rc=0
    for v in $(_rmq -q list_vhosts name 2>/dev/null | tr -d '\r' | grep "^${TAG_SNAKE}_"); do
        _rmq delete_vhost "$v" >/dev/null 2>&1 || rc=1
    done
    return "$rc"
}

# --- ClickHouse ------------------------------------------------------------
_ch() {
    dex -e CH_USER="$(user_of clickhouse)" -e CH_PW="$(pw_of clickhouse)" \
        "$(primary_container clickhouse)" \
        sh -c 'exec clickhouse-client --user "$CH_USER" --password "$CH_PW" "$@"' sh "$@"
}
probe_clickhouse() { _ch --query "SELECT 1" >/dev/null 2>&1; }
write_clickhouse() {
    local db; db="$(db_of clickhouse)"
    _ch --query "CREATE TABLE IF NOT EXISTS \`$db\`.$TAG_SNAKE (k String, v String) ENGINE=MergeTree ORDER BY k" >/dev/null \
        && _ch --query "TRUNCATE TABLE \`$db\`.$TAG_SNAKE" >/dev/null \
        && _ch --query "INSERT INTO \`$db\`.$TAG_SNAKE (k,v) VALUES ('probe','$TOKEN')" >/dev/null
}
read_clickhouse()  { local db; db="$(db_of clickhouse)"; _ch --query "SELECT v FROM \`$db\`.$TAG_SNAKE WHERE k='probe' LIMIT 1" 2>/dev/null; }
clean_clickhouse() { local db; db="$(db_of clickhouse)"; _ch --query "DROP TABLE IF EXISTS \`$db\`.$TAG_SNAKE" >/dev/null; }

# --- Neo4j -----------------------------------------------------------------
# cypher-shell kullanıcı/parolayı NEO4J_USERNAME / NEO4J_PASSWORD ortamından
# okur; komut satırına yazmıyoruz.
_cyp() {
    dex -e NEO4J_USERNAME="$(user_of neo4j)" -e NEO4J_PASSWORD="$(pw_of neo4j)" \
        "$(primary_container neo4j)" cypher-shell --non-interactive --format plain "$1"
}
probe_neo4j() { _cyp "RETURN 1;" >/dev/null 2>&1; }
write_neo4j() { _cyp "MERGE (n:E2eLifecycle {k:'probe'}) SET n.v='$TOKEN';" >/dev/null; }
read_neo4j() {
    _cyp "MATCH (n:E2eLifecycle {k:'probe'}) RETURN n.v;" 2>/dev/null \
        | tr -d '"\r' | grep -vE '^n\.v$|^$' | head -1
}
clean_neo4j() { _cyp "MATCH (n:E2eLifecycle) DETACH DELETE n;" >/dev/null; }

# --- MinIO -----------------------------------------------------------------
# S3 API'sine kabuktan imzalı istek atmak SigV4 gerektirir; imajın kendi `mc`
# istemcisini kullanıyoruz. Alias yapılandırması /tmp'ye yazılır ve container
# kapat-aç turunda SİLİNİR (controller container'ı `rm -f` ediyor) — bu yüzden
# her çağrıda yeniden kuruluyor. Bir kez kurup bıraksaydık ikinci okuma "alias
# yok" diye düşer ve bu, veri kaybı gibi raporlanırdı.
_mc() {
    dex -e MC_USER="$(user_of minio)" -e MC_PW="$(pw_of minio)" "$(primary_container minio)" sh -c '
        mc --config-dir /tmp/e2e-mc alias set e2e http://127.0.0.1:9000 "$MC_USER" "$MC_PW" >/dev/null 2>&1 || exit 3
        exec mc --config-dir /tmp/e2e-mc "$@"' sh "$@"
}
_mc_stdin() {
    dexi -e MC_USER="$(user_of minio)" -e MC_PW="$(pw_of minio)" "$(primary_container minio)" sh -c '
        mc --config-dir /tmp/e2e-mc alias set e2e http://127.0.0.1:9000 "$MC_USER" "$MC_PW" >/dev/null 2>&1 || exit 3
        exec mc --config-dir /tmp/e2e-mc "$@"' sh "$@"
}
# Hazırlık kontrolü curl ile: MinIO healthcheck'i de bunu kullanır ve `mc`
# olmasa bile doğru cevabı verir (mc'nin yokluğunu precheck ayrıca raporlar).
probe_minio() { dex "$(primary_container minio)" curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; }
precheck_minio() {
    docker exec "$(primary_container minio)" sh -c 'command -v mc >/dev/null 2>&1' >/dev/null 2>&1 \
        || printf '%s' "MinIO imajında 'mc' istemcisi yok; S3 imzası (SigV4) kabuk betiğinden üretilemiyor — MINIO_IMAGE mc içeren bir imaja çevrilirse ölçülebilir"
}
write_minio() {
    _mc mb --ignore-existing "e2e/$TAG_DASH" >/dev/null || return 1
    printf '%s' "$TOKEN" | _mc_stdin pipe "e2e/$TAG_DASH/probe.txt" >/dev/null
}
read_minio() { _mc cat "e2e/$TAG_DASH/probe.txt" 2>/dev/null; }
clean_minio() {
    local rc=0
    _mc rb --force "e2e/$TAG_DASH" >/dev/null 2>&1 || rc=1
    docker exec "$(primary_container minio)" sh -c 'rm -rf /tmp/e2e-mc' >/dev/null 2>&1
    return "$rc"
}

# --- İzleme (Prometheus + Grafana) -----------------------------------------
# Kalıcılığı ölçülen şey Grafana'nın kendi veritabanı (grafana_data volume):
# token'ı taşıyan bir klasör yaratılıp kapat-aç turundan sonra aranıyor.
# Prometheus'un ölçüm verisi bilerek kapsam dışı — katalog da onun
# yedeklenmeyeceğini söylüyor ("kaybolursa yeniden toplanır").
GF_C=""; GF_BASE=""
_gf_pick() {
    [ -n "$GF_C" ] && return 0
    local c; c="$(primary_container monitoring)"
    if docker exec "$c" sh -c 'command -v curl >/dev/null 2>&1' >/dev/null 2>&1; then
        GF_C="$c"; GF_BASE="http://127.0.0.1:3000"; return 0
    fi
    # Grafana imajında curl yoksa aynı ağdaki gateway'den geçiyoruz; orada curl
    # olduğunu ./stack.sh doctor da varsayıyor.
    if container_running gateway && docker exec gateway sh -c 'command -v curl >/dev/null 2>&1' >/dev/null 2>&1; then
        GF_C="gateway"; GF_BASE="http://$c:3000"; return 0
    fi
    return 1
}
_gf() {   # _gf <METOD> <yol> [gövde]
    _gf_pick || return 1
    local m="$1" p="$2" b="${3:-}"
    if [ -n "$b" ]; then
        dex -e GF_U="$(user_of monitoring)" -e GF_P="$(pw_of monitoring)" "$GF_C" sh -c \
            'exec curl -sS --max-time 30 -u "$GF_U:$GF_P" -X "$1" -H "Content-Type: application/json" --data "$3" "$2"' \
            sh "$m" "$GF_BASE$p" "$b"
    else
        dex -e GF_U="$(user_of monitoring)" -e GF_P="$(pw_of monitoring)" "$GF_C" sh -c \
            'exec curl -sS --max-time 30 -u "$GF_U:$GF_P" -X "$1" "$2"' sh "$m" "$GF_BASE$p"
    fi
}
# Hazırlık için container'ın KENDİ healthcheck'ine bakıyoruz: HTTP istemcisi
# olmayan bir imajda bile doğru cevabı verir ve ürünün "hazır" tanımıyla aynıdır.
probe_monitoring() {
    [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
         "$(primary_container monitoring)" 2>/dev/null)" = "healthy" ]
}
precheck_monitoring() {
    _gf_pick || printf '%s' "ne grafana ne de gateway container'ında curl var — Grafana API'sine istek atılamıyor"
}
# Cevabı boruya değil değişkene alıyoruz: `| grep -q` eşleşince erken kapanır,
# pipefail açıkken bu sağlam bir yazmayı "başarısız" gösterebilirdi. Ayrıca
# Grafana'nın 401/403 gövdesi böylece günlüğe düşüyor — parola yanlışsa hata
# "veri kayboldu" gibi değil, olduğu gibi okunuyor.
write_monitoring() {
    local out
    out="$(_gf POST /api/folders "{\"title\":\"${TAG_SNAKE}_$TOKEN\"}")" || return 1
    case "$out" in
        *'"uid"'*) return 0 ;;
        *) printf 'Grafana cevabı: %s\n' "$out"; return 1 ;;
    esac
}
read_monitoring() {
    _gf GET /api/folders 2>/dev/null | python3 -c 'import json,sys
pre = sys.argv[1] + "_"
try: rows = json.load(sys.stdin)
except Exception: rows = []
out = ""
for f in (rows if isinstance(rows, list) else []):
    t = f.get("title", "")
    if t.startswith(pre):
        out = t[len(pre):]; break
print(out)' "$TAG_SNAKE"
}
clean_monitoring() {
    local uid rc=0
    for uid in $(_gf GET /api/folders 2>/dev/null | python3 -c 'import json,sys
pre = sys.argv[1] + "_"
try: rows = json.load(sys.stdin)
except Exception: rows = []
for f in (rows if isinstance(rows, list) else []):
    if f.get("title","").startswith(pre) and f.get("uid"): print(f["uid"])' "$TAG_SNAKE"); do
        _gf DELETE "/api/folders/$uid" >/dev/null 2>&1 || rc=1
    done
    return "$rc"
}

# =============================================================================
# AÇ / KAPAT — ürünün gerçek arayüzü üzerinden
# =============================================================================
# Doğrudan `docker compose up` DEMİYORUZ. Aktivasyonu controller yapar: host
# RAM'ini ölçer, motorun bütçeye sığıp sığmadığına karar verir, tuning.env'i
# yazar. Elle compose çağırmak bu hesabı atlar ve testi kullanıcının gerçekte
# kullandığı yoldan uzaklaştırırdı. Kapatmada da fark var: controller `stop`
# üstüne `rm -f` yapar — container SİLİNİR. Asıl ölçmek istediğimiz de budur.
ACT_ERR=""
stack_act() {   # stack_act enable|disable <motor>
    local action="$1" eid="$2" out rc logf
    ACT_ERR=""; logf="$WORK/${action}_${eid}.log"
    out="$(timeout "$ACT_TIMEOUT" ./stack.sh "$action" "$eid" 2>&1)"; rc=$?
    printf '%s\n' "$out" > "$logf"
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 124 ]; then
        ACT_ERR="'./stack.sh $action $eid' $ACT_TIMEOUT sn içinde bitmedi; controller işi hâlâ sürüyor olabilir (./stack.sh events)"
    else
        # Controller'ın kendi gerekçesi ("REDDEDİLDİ: … yer yok", "ÖNKOŞUL
        # SAĞLANMADI: …") kullanıcı için en yararlı satırdır; onu öne çıkarıyoruz.
        ACT_ERR="$(printf '%s' "$out" | grep -aE 'Başarısız|REDDEDİLDİ|ÖNKOŞUL|YER YOK|yetersiz|çalışmıyor' \
                   | tail -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$ACT_ERR" ] || ACT_ERR="$(printf '%s' "$out" | grep -av '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//')"
        # stack.sh'in kendi işaretlerini ("[✗] Başarısız: ") söküyoruz; okunan
        # şey bizim raporumuzun içinde bir CÜMLE, ikinci bir hata satırı değil.
        ACT_ERR="$(printf '%s' "$ACT_ERR" | sed -e 's/^\[[^]]*\][[:space:]]*//' -e 's/^Başarısız:[[:space:]]*//')"
        [ -n "$ACT_ERR" ] || ACT_ERR="çıkış kodu $rc"
        ACT_ERR="$ACT_ERR — tam çıktı: $logf"
    fi
    return 1
}

# Hazır olma beklemesi: motorun KENDİ istemcisiyle gerçek bir sorgu çalışana
# kadar. "container running" yetmez — MariaDB açılırken saniyelerce bağlantı
# reddeder, Cassandra dakikalarca. Beklerken ne beklediğimizi yazıyoruz ki
# takılan bir motorda kullanıcı ekrana bakıp karar verebilsin.
wait_ready() {   # wait_ready <motor> <üst sınır sn>
    local eid="$1" limit="$2" waited=0 step=5
    while :; do
        "probe_$eid" && return 0
        [ "$waited" -ge "$limit" ] && return 1
        sleep "$step"; waited=$((waited+step))
        if [ $((waited % 30)) -eq 0 ]; then
            log "   … $eid hazır değil, bekleniyor (${waited}/${limit} sn) — durum: $(health_note "$(primary_container "$eid")")"
        fi
    done
}

# Testten önce kapalı olan motor testten sonra da kapalı kalmalı: aksi hâlde bu
# betiği çalıştırmak sunucunun bellek tablosunu sessizce değiştirirdi.
restore_engine() {   # restore_engine <motor> <testten_önce_açık_mıydı:0|1>
    [ "$2" -eq 1 ] && return 0
    log "$1 testten önce kapalıydı — tekrar kapatılıyor"
    stack_act disable "$1" || warn "$1 tekrar kapatılamadı ($ACT_ERR). Elle: ./stack.sh disable $1"
}

# =============================================================================
# BİR MOTORUN TAM DÖNGÜSÜ
# =============================================================================
run_engine() {
    local eid="$1" ename prim was_up=1 ready_to cl why
    ename="$(cat_field "$eid" 2)"
    heading "── $eid — $ename ──"

    cl="$(client_of "$eid")$(port_note "$eid")"
    local C1="$eid: açıldıktan sonra $cl ile sorguya cevap veriyor"
    local C2="$eid: probe kaydı yazıldı ve aynı bağlantıdan geri okundu"
    local C3="$eid: ./stack.sh disable container'ı gerçekten kaldırdı"
    local C4="$eid: kapatılıp yeniden açıldıktan sonra yazılan kayıt yerinde"

    # Katalogda olup bu betikte istemcisi tanımlı olmayan bir motor SESSİZCE
    # geçilmemeli: kataloğa yeni bir motor eklendiğinde test onu "geçti"
    # saymasın, "ölçmedim" desin.
    if ! declare -F "probe_$eid" >/dev/null 2>&1; then
        why="bu betikte $eid için istemci tanımlı değil; lifecycle.sh'e probe_$eid / write_$eid / read_$eid / clean_$eid ekleyin"
        t_skip "$C1" "$why"; t_skip "$C2" "$why"; t_skip "$C3" "$why"; t_skip "$C4" "$why"
        return
    fi

    prim="$(primary_container "$eid")"
    eng_up "$eid" || was_up=0
    ready_to="$(ready_timeout "$eid")"

    # --- 1) motoru aç ------------------------------------------------------
    if [ "$was_up" -eq 0 ]; then
        log "$eid kapalı — açılıyor: ./stack.sh enable $eid (bellek planını controller hesaplar)"
        if ! stack_act enable "$eid"; then
            # Bellek yetmediyse ya da önkoşul sağlanmadıysa ATLANDI diyoruz: bu
            # bir ürün arızası değil, o sunucunun kapasitesidir — ama sessizce
            # geçmek de olmaz, sebebi yazılır.
            why="açılamadı: $ACT_ERR"
            t_skip "$C1" "$why"; t_skip "$C2" "$why"; t_skip "$C3" "$why"; t_skip "$C4" "$why"
            return
        fi
        prim="$(primary_container "$eid")"
    else
        log "$eid zaten açık ($prim) — test sonunda açık bırakılacak"
    fi

    # --- 2) hazır mı? ------------------------------------------------------
    if wait_ready "$eid" "$ready_to"; then
        t_ok "$C1"
    else
        t_fail "$C1" "$ready_to sn içinde sorguya cevap vermedi (durum: $(health_note "$prim")). Log: ./stack.sh logs $prim"
        why="motor hazır olmadığı için ölçülemedi"
        t_skip "$C2" "$why"; t_skip "$C3" "$why"; t_skip "$C4" "$why"
        restore_engine "$eid" "$was_up"
        return
    fi

    # --- 2b) motora özgü ön koşul (istemci ikilisi vb.) --------------------
    if declare -F "precheck_$eid" >/dev/null 2>&1; then
        why="$("precheck_$eid" 2>/dev/null)"
        if [ -n "$why" ]; then
            t_skip "$C2" "$why"; t_skip "$C3" "$why"; t_skip "$C4" "$why"
            restore_engine "$eid" "$was_up"
            return
        fi
    fi

    # --- 3) yaz ve hemen geri oku -----------------------------------------
    # Önce artık temizliği: yarıda kesilmiş bir önceki çalıştırmadan kalan kayıt
    # bu turun okumasını kirletmesin (betik iki kez üst üste çalıştırılabilir).
    "clean_$eid" >/dev/null 2>&1
    local got=""
    if "write_$eid" >"$WORK/write_$eid.log" 2>&1; then
        got="$("read_$eid" 2>/dev/null | tr -d '\r' | head -1 | tr -d '[:space:]')"
    fi
    if [ "$got" != "$TOKEN" ]; then
        t_fail "$C2" "beklenen '$TOKEN', gelen '${got:-<boş>}' — istemci çıktısı: $WORK/write_$eid.log"
        why="veri yazılamadığı için kalıcılık ölçülemez"
        t_skip "$C3" "$why"; t_skip "$C4" "$why"
        "clean_$eid" >/dev/null 2>&1
        restore_engine "$eid" "$was_up"
        return
    fi
    t_ok "$C2"

    # --- 4) kapat ----------------------------------------------------------
    local cid_before; cid_before="$(cid_of "$prim")"
    log "$eid kapatılıyor: ./stack.sh disable $eid"
    if ! stack_act disable "$eid"; then
        t_fail "$C3" "kapatılamadı: $ACT_ERR"
        t_skip "$C4" "motor kapanmadığı için kalıcılık ölçülemedi"
        "clean_$eid" >/dev/null 2>&1
        restore_engine "$eid" "$was_up"
        return
    fi
    if eng_up "$eid"; then
        t_fail "$C3" "'$prim' hâlâ çalışıyor (durum: $(health_note "$prim")) — kapatma gerçekleşmemiş"
    else
        t_ok "$C3"
    fi

    # --- 5) tekrar aç ve veriyi ara ---------------------------------------
    log "$eid yeniden açılıyor: ./stack.sh enable $eid"
    if ! stack_act enable "$eid"; then
        t_fail "$C4" "kapatıldıktan sonra TEKRAR AÇILAMADI: $ACT_ERR — motor ŞU AN KAPALI; './stack.sh enable $eid' ile açın ve içeride kalan '$TAG_SNAKE' probe kaydını elle silin"
        return
    fi
    prim="$(primary_container "$eid")"
    if ! wait_ready "$eid" "$ready_to"; then
        t_fail "$C4" "yeniden açıldı ama $ready_to sn içinde sorguya cevap vermedi (durum: $(health_note "$prim")). Log: ./stack.sh logs $prim"
        restore_engine "$eid" "$was_up"
        return
    fi

    local cid_after got2
    cid_after="$(cid_of "$prim")"
    got2="$("read_$eid" 2>/dev/null | tr -d '\r' | head -1 | tr -d '[:space:]')"

    if [ -n "$cid_before" ] && [ "$cid_before" = "$cid_after" ]; then
        # Aynı container geri geldiyse volume hiç devreye girmemiştir; "veri
        # duruyor" sonucu hiçbir şey kanıtlamaz. Burada GEÇTİ demek testin
        # kendisini yalancı yapardı — ölçemediğimizi söylüyoruz (asıl arıza
        # zaten C3'te raporlandı).
        t_skip "$C4" "container yeniden yaratılmadı (kimlik $cid_before değişmedi) — kalıcılık ölçülemedi"
    elif [ "$got2" = "$TOKEN" ]; then
        t_ok "$C4 (container $cid_before → $cid_after olarak yeniden yaratıldı; veri volume'dan geldi)"
    else
        t_fail "$C4" "yeni container'da ($cid_before → $cid_after) beklenen '$TOKEN' yerine '${got2:-<boş>}' geldi — kapatınca veri KAYBOLUYOR; bu motorun volume tanımını ve veri dizinini kontrol edin"
    fi

    # --- 6) kendi verimizi sil --------------------------------------------
    if "clean_$eid" >/dev/null 2>&1; then
        log "$eid: probe kaydı silindi ($TAG_SNAKE)"
    else
        warn "$eid: probe kaydı silinemedi — '$TAG_SNAKE' adlı nesneyi elle silmeniz gerekebilir"
    fi

    # --- 7) motoru bulduğumuz hâle döndür ---------------------------------
    restore_engine "$eid" "$was_up"
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
ENGINES=()
if [ $# -gt 0 ]; then
    for a in "$@"; do
        if all_engine_ids | grep -qx "$a"; then
            ENGINES+=("$a")
        else
            err "Katalogda böyle bir motor yok: $a"
            echo "Geçerli olanlar:" >&2; all_engine_ids | sed 's/^/  /' >&2
            exit 1
        fi
    done
else
    while IFS= read -r e; do [ -n "$e" ] && ENGINES+=("$e"); done < <(all_engine_ids)
fi

heading "$ALAN — ${#ENGINES[@]} katalog kaydı sınanacak"
echo "  Ölçülen iddia : 'motoru kapatınca veriniz silinmez'"
echo "  Yöntem        : aç → yaz → geri oku → KAPAT (container silinir) → aç → veriyi ara → temizle"
echo "  Probe adı     : $TAG_SNAKE / $TAG_DASH   ·   bu turun değeri: $TOKEN"
echo "  Üst sınırlar  : aktivasyon ${ACT_TIMEOUT} sn · istemci komutu ${DEX_TIMEOUT} sn"
echo

for e in "${ENGINES[@]}"; do
    run_engine "$e"
done

# =============================================================================
# ÖZET
# =============================================================================
heading "ÖZET"
printf '  %s: %d/%d geçti' "$ALAN" "$T_PASS" "$((T_PASS + T_FAIL))"
[ "$T_SKIP" -gt 0 ] && printf ' · %d kontrol atlandı (sebepleri yukarıda)' "$T_SKIP"
printf '\n'

if [ "$T_FAIL" -gt 0 ]; then
    echo
    err "Başarısız kontroller:"
    for n in "${FAILED_NAMES[@]}"; do printf '    · %s\n' "$n" >&2; done
    printf '\n  Ayrıntılı çıktılar: %s\n\n' "$WORK"
    exit 1
fi

# Temiz geçtiyse kendi artığımızı da bırakmıyoruz. (Başarısızlıkta günlükler
# KALIR — yukarıdaki hata satırları o dosyaları gösteriyor.)
rm -rf "$WORK"
if [ "$T_PASS" -eq 0 ]; then
    warn "Hiçbir kontrol çalıştırılamadı — yukarıdaki ATLANDI sebeplerine bakın."
else
    ok "Çalıştırılan bütün kontroller geçti."
fi
exit 0
