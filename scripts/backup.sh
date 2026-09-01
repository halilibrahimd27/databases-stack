#!/bin/bash
# =============================================================================
# databases-stack — yedekleme ve geri yükleme
# =============================================================================
# Yalnızca AKTİF motorları yedekler (kapalı motorun container'ı yoktur).
#
# Kullanım:
#   ./scripts/backup.sh all                 aktif motorların hepsi
#   ./scripts/backup.sh mariadb             tek motor
#   ./scripts/backup.sh restore-mariadb <dosya>
#   ./scripts/backup.sh list | stats | clean [gün] | verify <dosya>
#
# NEDEN GÜNDE BİR (15 dakikada bir değil):
# Dump'lar DB container'ının İÇİNDE alınır; bellek tüketimi o container'ın
# kendi cgroup'una yazılır. Sık tam yedek MariaDB'yi tekrar tekrar
# CONSTRAINT_MEMCG OOM'a soktu (container 172 kez yeniden başladı). Daha sık
# kurtarma noktası gerekiyorsa dump yerine binlog/PITR kullanın — MariaDB'de
# binlog artık AÇIK (config/mariadb/my.cnf).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
load_env

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
DATE="$(date +%Y%m%d_%H%M%S)"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"
BACKUP_EXCLUDE_TABLE_PATTERNS="${BACKUP_EXCLUDE_TABLE_PATTERNS:-telescope% pulse%}"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d).log"
mkdir -p "$LOG_DIR"

# Yedekleme ağır I/O üretir. nice + ionice ile canlı DB trafiği öncelikli kalır
# (özellikle dönen disk / RAID üzerinde fark eder).
if command -v nice >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
    IO_NICE=(nice -n 19 ionice -c3)
else
    IO_NICE=()
fi

blog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
bok()  { ok   "$*"; printf '[%s] [OK] %s\n'   "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
berr() { err  "$*"; printf '[%s] [ERR] %s\n'  "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# ------------------------------------------------------------------ yardımcı
engine_field() {   # engine_field <id> <python-ifade>
    python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
e=[x for x in c["engines"] if x["id"]==sys.argv[2]]
if not e: sys.exit(1)
e=e[0]
print(eval(sys.argv[3], {"e": e}))' "$CATALOG" "$1" "$2" 2>/dev/null
}
backupable_engines() {
    python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if e.get("backup",{}).get("supported")))' "$CATALOG"
}

out_path() {  # out_path <motor> <tip> <uzantı>
    local d="$BACKUP_DIR/$1/$2"
    mkdir -p "$d"
    printf '%s/%s_%s_%s.%s' "$d" "$1" "$2" "$DATE" "$3"
}

check_disk() {
    local avail_kb; avail_kb="$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
    # -P (POSIX) şart: uzun aygıt adlarında df çıktısı iki satıra bölünür ve
    # sütun numaraları kayar; -P bunu engeller.
    if [ "${avail_kb:-0}" -lt 5242880 ]; then
        berr "Disk kritik: 5 GB'dan az boş alan var, yedekleme iptal."
        return 1
    fi
    [ "$avail_kb" -lt 10485760 ] && warn "Disk azalıyor: $((avail_kb/1024)) MB boş"
    return 0
}

verify_backup() {
    local f="$1"
    [ -f "$f" ] && [ -s "$f" ] || { berr "Yedek dosyası yok ya da boş: $f"; return 1; }
    case "$f" in
        *.tar.gz) tar -tzf "$f" >/dev/null 2>&1 || { berr "Bozuk arşiv: $f"; return 1; } ;;
        *.gz)     gzip -t "$f"  2>/dev/null     || { berr "Bozuk gzip: $f";  return 1; } ;;
    esac
    bok "Bütünlük doğrulandı: $(basename "$f") ($(du -h "$f" | cut -f1))"
}

# =============================================================================
# MOTOR YEDEKLERİ
# =============================================================================

backup_mariadb() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of mariadb)"
    local f; f="$(out_path mariadb full sql.gz)"
    blog "MariaDB yedekleniyor…"

    # Hariç tutulacak tablolar (Telescope/Pulse gibi büyük, atılabilir tablolar)
    local ignore=""
    if [ -n "$BACKUP_EXCLUDE_TABLE_PATTERNS" ]; then
        local where="" p
        for p in $BACKUP_EXCLUDE_TABLE_PATTERNS; do
            [ -n "$where" ] && where+=" OR "
            where+="TABLE_NAME LIKE '$p'"
        done
        ignore="$(MYSQL_PWD="${MARIADB_PASSWORD:-$DB_PASSWORD}" docker exec -e MYSQL_PWD "$C" \
            mariadb -u root -N -e "SELECT CONCAT('--ignore-table=',TABLE_SCHEMA,'.',TABLE_NAME)
            FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN
            ('information_schema','performance_schema','mysql','sys') AND ($where);" \
            2>>"$LOG_FILE" | tr '\n' ' ')"
        [ -n "$ignore" ] && blog "  hariç: $ignore"
    fi

    # --master-data=2: dump'a binlog konumunu YORUM olarak yazar → bu yedekten
    # sonra biriken binlog'larla point-in-time recovery yapılabilir.
    MYSQL_PWD="${MARIADB_PASSWORD:-$DB_PASSWORD}" "${IO_NICE[@]}" \
        docker exec -e MYSQL_PWD "$C" mariadb-dump -u root \
            --all-databases --single-transaction --quick --routines --triggers \
            --events --hex-blob --add-drop-database --add-drop-table \
            --master-data=2 --skip-comments $ignore \
        2>>"$LOG_FILE" | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "MariaDB dump başarısız"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_postgresql() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of postgresql)"
    local f; f="$(out_path postgresql full sql.gz)"
    blog "PostgreSQL yedekleniyor…"
    # pg_dumpall roller/parolalar dahil TÜM cluster'ı alır — tek DB'lik
    # pg_dump'ın aksine geri yüklemede kullanıcılar da geri gelir.
    "${IO_NICE[@]}" docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" "$C" \
        pg_dumpall -U "${POSTGRES_USER:-root}" --clean --if-exists --quote-all-identifiers \
        2>>"$LOG_FILE" | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "PostgreSQL dump başarısız"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_mongodb() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of mongodb)"
    local f; f="$(out_path mongodb full archive.gz)"
    blog "MongoDB yedekleniyor…"
    # --archive ile doğrudan stdout'a yazıyoruz: eski sürüm önce container
    # içinde /tmp/backup dizinine döküp sonra tar'lıyordu; bu, container'ın
    # diskini ve belleğini iki kez zorluyordu.
    "${IO_NICE[@]}" docker exec "$C" mongodump \
        --username "${MONGO_USER:-root}" --password "${MONGO_PASSWORD:-$DB_PASSWORD}" \
        --authenticationDatabase admin --archive --gzip --quiet \
        2>>"$LOG_FILE" > "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] && [ -s "$f" ] || { berr "MongoDB dump başarısız"; rm -f "$f"; return 1; }
    bok "MongoDB yedeklendi ($(du -h "$f" | cut -f1))"
}

backup_redis() {
    # Devirden sonra ana kopya yedek düğüm olabilir — topolojiden çöz.
    local C; C="$(primary_of redis)"
    local f; f="$(out_path redis full rdb.gz)"
    blog "Redis yedekleniyor…"
    local pw="${REDIS_PASSWORD:-$DB_PASSWORD}"
    rcli() { docker exec -e REDISCLI_AUTH="$pw" "$C" redis-cli --no-auth-warning "$@"; }

    local before; before="$(rcli LASTSAVE 2>/dev/null | tr -d '[:space:]')"
    rcli BGSAVE >>"$LOG_FILE" 2>&1 || { berr "BGSAVE reddedildi"; return 1; }

    # LASTSAVE değişene kadar bekle — sabit `sleep` ile büyük veri setlerinde
    # yarım yazılmış dump.rdb kopyalanabiliyordu.
    local i=0 now
    while [ $i -lt 120 ]; do
        now="$(rcli LASTSAVE 2>/dev/null | tr -d '[:space:]')"
        [ -n "$now" ] && [ "$now" != "$before" ] && break
        i=$((i+1)); sleep 1
    done
    [ $i -lt 120 ] || warn "BGSAVE 120 sn'de bitmedi; mevcut dump.rdb kopyalanıyor"

    "${IO_NICE[@]}" docker exec "$C" cat /data/dump.rdb 2>>"$LOG_FILE" \
        | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "Redis dump kopyalanamadı"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_mssql() {
    local f; f="$(out_path mssql full tar.gz)"
    local SQLCMD=/opt/mssql-tools18/bin/sqlcmd
    blog "MSSQL yedekleniyor…"
    sq() { SQLCMDPASSWORD="${MSSQL_PASSWORD:-$DB_PASSWORD}" \
           docker exec -e SQLCMDPASSWORD mssql "$SQLCMD" -S localhost -U sa -C "$@"; }

    docker exec "$C" sh -c 'mkdir -p /var/opt/mssql/backup && rm -f /var/opt/mssql/backup/*.bak' 2>/dev/null

    # database_id>4 → master/tempdb/model/msdb hariç. msdb ve master ayrıca
    # alınıyor: SQL login'leri ve agent job'ları oradadır, yoksa geri yüklemede
    # kullanıcılar "orphaned" kalır.
    local dbs failed=0 db
    dbs="$(sq -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id>4 OR name IN ('master','msdb');" \
           2>>"$LOG_FILE" | tr -d '\r' | grep -v '^$')"
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        blog "  - $db"
        # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir. Bu
        # olmadan başarısız BACKUP sessizce "başarılı" sanılıyordu.
        sq -b -Q "BACKUP DATABASE [$db] TO DISK=N'/var/opt/mssql/backup/${db}.bak' WITH FORMAT, INIT;" \
            >>"$LOG_FILE" 2>&1 || { failed=1; berr "  BACKUP başarısız: $db"; }
    done <<< "$dbs"
    [ "$failed" -eq 0 ] || { docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*.bak'; return 1; }

    "${IO_NICE[@]}" docker exec mssql tar -cf - -C /var/opt/mssql/backup . 2>>"$LOG_FILE" \
        | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    local rc="${PIPESTATUS[0]}"
    docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*.bak' 2>/dev/null
    [ "$rc" -eq 0 ] || { berr "MSSQL arşivi alınamadı"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_cassandra() {
    local f; f="$(out_path cassandra full tar.gz)"
    local snap="bk_$DATE"
    blog "Cassandra yedekleniyor…"
    # Önce flush: memtable'daki veri diske inmeden snapshot eksik olur.
    docker exec cassandra nodetool flush >>"$LOG_FILE" 2>&1
    docker exec cassandra nodetool snapshot -t "$snap" >>"$LOG_FILE" 2>&1 \
        || { berr "snapshot alınamadı"; return 1; }
    # Şema de gerekli: snapshot yalnız SSTable'ları içerir, tablo tanımlarını değil.
    docker exec -e CQLSH_PW="${CASSANDRA_PASSWORD:-$DB_PASSWORD}" cassandra sh -c \
        'cqlsh -u ${CASSANDRA_USER:-cassandra} -p "$CQLSH_PW" -e "DESCRIBE SCHEMA;" > /tmp/schema.cql' \
        2>>"$LOG_FILE"
    "${IO_NICE[@]}" docker exec cassandra sh -c \
        "tar -cf - -C /tmp schema.cql \$(find /var/lib/cassandra/data -type d -name '$snap' -printf '%P\n' 2>/dev/null | sed 's|^|-C /var/lib/cassandra/data |') 2>/dev/null || tar -cf - -C /var/lib/cassandra/data . --wildcards '*/snapshots/$snap/*'" \
        2>>"$LOG_FILE" | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    local rc="${PIPESTATUS[0]}"
    docker exec cassandra nodetool clearsnapshot -t "$snap" >>"$LOG_FILE" 2>&1
    [ "$rc" -eq 0 ] || { berr "Cassandra arşivi alınamadı"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_elasticsearch() {
    local f; f="$(out_path elasticsearch full tar.gz)"
    local snap="bk_$DATE"
    blog "Elasticsearch yedekleniyor…"
    es() { docker exec elasticsearch curl -sf -u "elastic:${ELASTIC_PASSWORD:-$DB_PASSWORD}" "$@"; }

    # Snapshot deposu (path.repo=/snapshots compose'da tanımlı). Veri dizinini
    # kopyalamak TUTARSIZ olur — ES'te doğru yol snapshot API'sidir.
    es -X PUT "http://localhost:9200/_snapshot/backup_repo" -H 'Content-Type: application/json' \
       -d '{"type":"fs","settings":{"location":"/snapshots"}}' >>"$LOG_FILE" 2>&1
    es -X PUT "http://localhost:9200/_snapshot/backup_repo/$snap?wait_for_completion=true" \
       -H 'Content-Type: application/json' -d '{"indices":"*","include_global_state":true}' \
       >>"$LOG_FILE" 2>&1 || { berr "snapshot başarısız"; return 1; }

    "${IO_NICE[@]}" docker exec elasticsearch tar -cf - -C /snapshots . 2>>"$LOG_FILE" \
        | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "ES arşivi alınamadı"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_clickhouse() {
    local f; f="$(out_path clickhouse full tar.gz)"
    blog "ClickHouse yedekleniyor…"
    ch() { docker exec -e CH_PW="${CLICKHOUSE_PASSWORD:-$DB_PASSWORD}" clickhouse \
           clickhouse-client --user "${CLICKHOUSE_USER:-default}" --password "$CH_PW" "$@"; }
    local dbs db
    dbs="$(ch --query "SELECT name FROM system.databases WHERE name NOT IN ('system','INFORMATION_SCHEMA','information_schema')" 2>>"$LOG_FILE")"
    docker exec clickhouse sh -c 'rm -rf /var/lib/clickhouse/backups/* ' 2>/dev/null
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        blog "  - $db"
        ch --query "BACKUP DATABASE \`$db\` TO Disk('backups', '${db}.zip')" >>"$LOG_FILE" 2>&1 \
            || { berr "  BACKUP başarısız: $db"; return 1; }
    done <<< "$dbs"
    "${IO_NICE[@]}" docker exec clickhouse tar -cf - -C /var/lib/clickhouse/backups . 2>>"$LOG_FILE" \
        | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    local rc="${PIPESTATUS[0]}"
    docker exec clickhouse sh -c 'rm -rf /var/lib/clickhouse/backups/*' 2>/dev/null
    [ "$rc" -eq 0 ] || { berr "ClickHouse arşivi alınamadı"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_rabbitmq() {
    local f; f="$(out_path rabbitmq full json.gz)"
    blog "RabbitMQ tanımları yedekleniyor…"
    # NOT: Kuyruklardaki MESAJLAR yedeklenmez — mesajlar geçicidir, yedeklenecek
    # şey exchange/queue/binding/policy tanımlarıdır.
    docker exec rabbitmq rabbitmqctl export_definitions /tmp/defs.json >>"$LOG_FILE" 2>&1 \
        || { berr "export_definitions başarısız"; return 1; }
    docker exec rabbitmq cat /tmp/defs.json | gzip -"$COMPRESSION_LEVEL" > "$f"
    docker exec rabbitmq rm -f /tmp/defs.json 2>/dev/null
    verify_backup "$f"
}

backup_minio() {
    local f; f="$(out_path minio full tar.gz)"
    blog "MinIO nesneleri yedekleniyor…"
    # Nesneler değişmezdir (immutable); veri dizinini tar'lamak tutarlıdır.
    "${IO_NICE[@]}" docker exec minio tar -cf - -C /data . 2>>"$LOG_FILE" \
        | "${IO_NICE[@]}" gzip -"$COMPRESSION_LEVEL" > "$f"
    [ "${PIPESTATUS[0]}" -eq 0 ] || { berr "MinIO arşivi alınamadı"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

backup_neo4j() {
    # Neo4j Community'de ÇEVRİMİÇİ yedek yoktur (Enterprise özelliğidir).
    # Dump için veritabanının durması gerekir → kesinti. Bu yüzden `all`
    # içinde otomatik çalışmaz; bilinçli olarak istenmelidir.
    if [ "${BACKUP_NEO4J_OFFLINE:-false}" != "true" ]; then
        warn "Neo4j atlandı: Community sürümde yedek almak veritabanını DURDURMAYI gerektirir."
        warn "  Kesintiyi göze alıyorsanız: BACKUP_NEO4J_OFFLINE=true ./scripts/backup.sh neo4j"
        return 0
    fi
    local f; f="$(out_path neo4j full dump.gz)"
    blog "Neo4j durduruluyor (çevrimdışı yedek)…"
    compose stop neo4j >>"$LOG_FILE" 2>&1
    docker run --rm -v "${STACK_PROJECT:-databases-stack}_neo4j_data:/data" \
        "neo4j:${NEO4J_VERSION:-5-community}" \
        neo4j-admin database dump neo4j --to-stdout 2>>"$LOG_FILE" \
        | gzip -"$COMPRESSION_LEVEL" > "$f"
    local rc="${PIPESTATUS[0]}"
    blog "Neo4j yeniden başlatılıyor…"
    compose --profile neo4j up -d neo4j >>"$LOG_FILE" 2>&1
    [ "$rc" -eq 0 ] || { berr "Neo4j dump başarısız"; rm -f "$f"; return 1; }
    verify_backup "$f"
}

# =============================================================================
# TÜMÜ
# =============================================================================
backup_all() {
    acquire_lock /tmp/databases-stack-backup.lock
    check_disk || exit 1

    heading "Yedekleme — $(date '+%Y-%m-%d %H:%M')"
    local start; start="$(date +%s)"
    local okc=0 failc=0 skipc=0 eid primary

    for eid in $(backupable_engines); do
        primary="$(primary_of "$eid")"
        if ! container_running "$primary"; then
            printf '  %-14s %s\n' "$eid" "atlandı (kapalı)"
            skipc=$((skipc+1)); continue
        fi
        if "backup_$eid"; then okc=$((okc+1)); else failc=$((failc+1)); fi
    done

    local dur=$(( $(date +%s) - start ))
    heading "Özet"
    printf '  Başarılı : %d\n  Başarısız: %d\n  Atlanan  : %d (kapalı motorlar)\n' \
        "$okc" "$failc" "$skipc"
    printf '  Süre     : %dm %ds\n' $((dur/60)) $((dur%60))
    printf '  Toplam   : %s\n' "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    printf '  Boş disk : %s\n' "$(df -Ph "$BACKUP_DIR" | awk 'NR==2{print $4}')"
    [ "$failc" -eq 0 ] || return 1
}

# =============================================================================
# GERİ YÜKLEME
# =============================================================================
confirm_restore() {
    local what="$1"
    warn "GERİ YÜKLEME: $what — mevcut veriler ÜZERİNE YAZILACAK."
    if [ "${ASSUME_YES:-}" = "yes" ]; then return 0; fi
    printf "Devam etmek için 'evet' yazın: "
    read -r a; [ "$a" = "evet" ] || { log "İptal edildi"; return 1; }
}

restore_mariadb() {
    local C; C="$(primary_of mariadb)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    confirm_restore "MariaDB" || return 1
    gzip -dc "$f" | MYSQL_PWD="${MARIADB_PASSWORD:-$DB_PASSWORD}" \
        docker exec -e MYSQL_PWD -i "$C" mariadb -u root
    [ "${PIPESTATUS[1]}" -eq 0 ] && bok "MariaDB geri yüklendi" || { berr "başarısız"; return 1; }
}

restore_postgresql() {
    local C; C="$(primary_of postgresql)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    confirm_restore "PostgreSQL" || return 1
    gzip -dc "$f" | docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" -i "$C" \
        psql -U "${POSTGRES_USER:-root}" -d postgres
    [ "${PIPESTATUS[1]}" -eq 0 ] && bok "PostgreSQL geri yüklendi" || { berr "başarısız"; return 1; }
}

restore_mongodb() {
    local C; C="$(primary_of mongodb)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    confirm_restore "MongoDB" || return 1
    docker exec -i "$C" mongorestore \
        --username "${MONGO_USER:-root}" --password "${MONGO_PASSWORD:-$DB_PASSWORD}" \
        --authenticationDatabase admin --archive --gzip --drop < "$f" \
        && bok "MongoDB geri yüklendi" || { berr "başarısız"; return 1; }
}

restore_redis() {
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    confirm_restore "Redis" || return 1
    # ⚠ KRİTİK: AOF açıkken Redis açılışta dump.rdb'yi DEĞİL AOF'u okur.
    # Eski sürüm sadece dump.rdb'yi değiştirip yeniden başlatıyordu — "başarılı"
    # yazıp hiçbir şey geri yüklemiyordu. Doğru sıra: AOF'u kapat, RDB'yi koy,
    # AOF'u yeniden üret (BGREWRITEAOF), sonra tekrar aç.
    local pw="${REDIS_PASSWORD:-$DB_PASSWORD}"
    # Geri yükleme her zaman O ANKİ ana kopyaya yapılır (devir olmuşsa yedek düğüm).
    local C; C="$(primary_of redis)"
    rcli() { docker exec -e REDISCLI_AUTH="$pw" "$C" redis-cli --no-auth-warning "$@"; }

    local aof; aof="$(rcli CONFIG GET appendonly | tail -1 | tr -d '[:space:]')"
    blog "Mevcut appendonly=$aof"
    rcli CONFIG SET appendonly no >/dev/null
    rcli FLUSHALL >/dev/null
    rcli CONFIG SET save "" >/dev/null     # kapanışta RDB'yi ezmesin
    rcli SHUTDOWN NOSAVE >/dev/null 2>&1 || true

    blog "Container'ın yeniden başlaması bekleniyor…"
    local i=0; while [ $i -lt 30 ] && ! container_running "$C"; do sleep 1; i=$((i+1)); done
    sleep 2

    gzip -dc "$f" | docker exec -i "$C" sh -c 'cat > /data/dump.rdb'
    docker exec "$C" sh -c 'rm -rf /data/appendonlydir /data/appendonly.aof*' 2>/dev/null
    docker restart "$C" >/dev/null
    blog "Redis yeniden başlatıldı, RDB yükleniyor…"
    i=0; while [ $i -lt 60 ]; do rcli PING 2>/dev/null | grep -q PONG && break; sleep 2; i=$((i+1)); done

    if [ "$aof" = "yes" ]; then
        rcli CONFIG SET appendonly yes >/dev/null
        rcli BGREWRITEAOF >/dev/null
        blog "AOF yeniden üretildi"
    fi
    rcli PING 2>/dev/null | grep -q PONG \
        && bok "Redis geri yüklendi ($(rcli DBSIZE | tr -d '[:space:]') anahtar)" \
        || { berr "Redis açılmadı"; return 1; }
}

restore_mssql() {
    local C; C="$(primary_of mssql)"
    local f="$1"; [ -f "$f" ] || die "Dosya yok: $f"
    confirm_restore "MSSQL" || return 1
    local SQLCMD=/opt/mssql-tools18/bin/sqlcmd rc=0
    docker exec "$C" sh -c 'mkdir -p /var/opt/mssql/backup && rm -f /var/opt/mssql/backup/*.bak'
    gzip -dc "$f" | docker exec -i "$C" tar -xf - -C /var/opt/mssql/backup
    for bak in $(docker exec "$C" sh -c 'ls /var/opt/mssql/backup/*.bak 2>/dev/null'); do
        local db; db="$(basename "$bak" .bak)"
        case "$db" in master|msdb) blog "  $db atlandı (sistem DB'si elle geri yüklenir)"; continue ;; esac
        blog "  geri yükleniyor: $db"
        SQLCMDPASSWORD="${MSSQL_PASSWORD:-$DB_PASSWORD}" docker exec -e SQLCMDPASSWORD mssql \
            "$SQLCMD" -S localhost -U sa -C -b \
            -Q "RESTORE DATABASE [$db] FROM DISK=N'$bak' WITH REPLACE;" >>"$LOG_FILE" 2>&1 || rc=1
    done
    docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*.bak'
    [ "$rc" -eq 0 ] && bok "MSSQL geri yüklendi" || { berr "başarısız"; return 1; }
}

# =============================================================================
# BAKIM
# =============================================================================
clean_old() {
    local days="${1:-$RETENTION_DAYS}"
    heading "$days günden eski yedekler temizleniyor"
    # Tek find: eski sürüm "*.gz" ve "*.tar.gz" için ayrı sayıyordu; "*.gz"
    # deseni tar.gz'yi de yakaladığı için toplam ÇİFT görünüyordu.
    local n; n="$(find "$BACKUP_DIR" -type f -name '*.gz' -mtime +"$days" 2>/dev/null | wc -l)"
    if [ "$n" -eq 0 ]; then log "Silinecek yedek yok"; return 0; fi
    find "$BACKUP_DIR" -type f -name '*.gz' -mtime +"$days" -printf '  siliniyor: %f\n' 2>/dev/null | head -10
    [ "$n" -gt 10 ] && log "  … ve $((n-10)) dosya daha"
    find "$BACKUP_DIR" -type f -name '*.gz' -mtime +"$days" -delete 2>/dev/null
    bok "$n dosya silindi (kalan: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1))"
}

list_backups() {
    heading "Mevcut yedekler"
    local eid n
    for eid in $(backupable_engines); do
        n="$(find "$BACKUP_DIR/$eid" -type f -name '*.gz' 2>/dev/null | wc -l)"
        printf '\n  %s%s%s  (%d yedek)\n' "$BOLD" "$eid" "$NC" "$n"
        [ "$n" -eq 0 ] && { printf '    yedek yok\n'; continue; }
        find "$BACKUP_DIR/$eid" -type f -name '*.gz' -printf '%T@\t%TY-%Tm-%Td %TH:%TM\t%s\t%f\n' 2>/dev/null \
            | sort -rn | head -5 \
            | awk -F'\t' '{printf "    %s  %8.1f MB  %s\n", $2, $3/1048576, $4}'
    done
    printf '\n  Toplam: %s\n\n' "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
}

stats() {
    heading "Yedekleme istatistikleri"
    printf '  Dizin      : %s\n' "$BACKUP_DIR"
    printf '  Toplam     : %s\n' "$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    printf '  Boş disk   : %s (%s dolu)\n' \
        "$(df -Ph "$BACKUP_DIR" | awk 'NR==2{print $4}')" \
        "$(df -Ph "$BACKUP_DIR" | awk 'NR==2{print $5}')"
    printf '  Saklama    : %s gün\n\n' "$RETENTION_DAYS"
    printf '  %-14s %6s  %10s  %s\n' "MOTOR" "ADET" "BOYUT" "EN SON"
    printf '  %s\n' "------------------------------------------------------------"
    local eid n sz last
    for eid in $(backupable_engines); do
        n="$(find "$BACKUP_DIR/$eid" -type f -name '*.gz' 2>/dev/null | wc -l)"
        sz="$(du -sh "$BACKUP_DIR/$eid" 2>/dev/null | cut -f1)"
        last="$(find "$BACKUP_DIR/$eid" -type f -name '*.gz' -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort -r | head -1)"
        printf '  %-14s %6s  %10s  %s\n' "$eid" "$n" "${sz:-0}" "${last:-hiç}"
    done
    echo
}

# =============================================================================
case "${1:-help}" in
    all)        backup_all ;;
    mariadb|postgresql|mongodb|redis|mssql|cassandra|elasticsearch|clickhouse|rabbitmq|minio|neo4j)
                acquire_lock /tmp/databases-stack-backup.lock
                primary="$(primary_of "$1")"
                container_running "$primary" || die "$1 çalışmıyor. Önce: ./stack.sh enable $1"
                check_disk || exit 1
                "backup_$1" ;;
    restore-mariadb)     restore_mariadb "${2:-}" ;;
    restore-postgresql)  restore_postgresql "${2:-}" ;;
    restore-mongodb)     restore_mongodb "${2:-}" ;;
    restore-redis)       restore_redis "${2:-}" ;;
    restore-mssql)       restore_mssql "${2:-}" ;;
    restore-*)           die "Bu motor için otomatik geri yükleme yok: ${1#restore-}. docs/BACKUP.md bakın." ;;
    clean)      clean_old "${2:-}" ;;
    list)       list_backups ;;
    stats)      stats ;;
    verify)     verify_backup "${2:-}" ;;
    *)
cat <<EOF

Yedekleme — databases-stack

  ./scripts/backup.sh all                 Aktif motorların hepsini yedekle
  ./scripts/backup.sh <motor>             Tek motor
  ./scripts/backup.sh list                Yedekleri listele
  ./scripts/backup.sh stats               İstatistikler
  ./scripts/backup.sh clean [gün]         Eski yedekleri sil (varsayılan $RETENTION_DAYS)
  ./scripts/backup.sh verify <dosya>      Bütünlük kontrolü

  Geri yükleme:
  ./scripts/backup.sh restore-mariadb <dosya>
  ./scripts/backup.sh restore-postgresql <dosya>
  ./scripts/backup.sh restore-mongodb <dosya>
  ./scripts/backup.sh restore-redis <dosya>
  ./scripts/backup.sh restore-mssql <dosya>

Yedeklenebilen motorlar: $(backupable_engines | tr '\n' ' ')
Kafka yedeklenmez (log'dur, veritabanı değil — replication.factor kullanın).

EOF
        exit 1 ;;
esac
