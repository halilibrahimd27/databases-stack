#!/bin/bash

# =============================================================================
# Database Backup Script V7 - PRODUCTION GRADE (günlük tam yedek)
# PostgreSQL 15 + MongoDB 4.4 + MariaDB 11.4 + Redis 8.2.2
#
# ✅ ALL DATABASES BACKUP (Not just defaultdb)
# ✅ Individual database backup support
# ✅ Backup verification
# ✅ Lock mechanism (prevents concurrent runs)
# ✅ Fast compression for frequent backups
# ✅ Detailed logging
# ✅ Container health checking
# =============================================================================

# =============================================================================
# Yapılandırma — .env dosyasından oku ya da ortam değişkenlerinden al
# =============================================================================
# Stack root dizini (compose ile aynı yer). DB_BASE_DIR ile override edilebilir.
DB_BASE_DIR="${DB_BASE_DIR:-/opt/databases}"
BACKUP_DIR="${BACKUP_DIR:-${DB_BASE_DIR}/backups}"
LOG_DIR="${LOG_DIR:-${DB_BASE_DIR}/logs}"
DATE=$(date +%Y%m%d_%H%M%S)

# .env'den yapılandırma oku — dosyayı SOURCE ETMEZ, sadece grep'ler; böylece
# boşluklu değerler ve .env içindeki keyfi kod güvenlidir. Yalnızca ortamda
# tanımlı OLMAYAN anahtarları doldurur → gerçek ortam değişkeni her zaman önce gelir.
_load_from_dotenv() {
    local env_file="${DB_BASE_DIR}/.env" key val
    [ -f "$env_file" ] || return 0
    for key in "$@"; do
        [ -n "${!key}" ] && continue
        val=$(grep -E "^${key}=" "$env_file" | head -1 | cut -d= -f2-)
        [ -n "$val" ] && printf -v "$key" '%s' "$val"
    done
}
_load_from_dotenv DB_PASSWORD RETENTION_DAYS COMPRESSION_LEVEL BACKUP_EXCLUDE_TABLE_PATTERNS

DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD ortam değişkeni veya .env dosyasında tanımlı olmalı}"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d).log"
RETENTION_DAYS="${RETENTION_DAYS:-7}"          # gün — `clean` komutu ve cron temizliği bunu kullanır
MAX_BACKUP_SIZE="50G"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"    # 1=hızlı, 9=en iyi; günlük yedek için 6 dengeli

# MariaDB dump'ından hariç tutulacak tablolar — SQL LIKE desenleri, boşlukla ayrılır.
# Varsayılan: Laravel Telescope/Pulse (büyük, atılabilir, sürekli yazılan tablolar).
# Kapatmak için boş bırak: BACKUP_EXCLUDE_TABLE_PATTERNS="" ./backup.sh all
BACKUP_EXCLUDE_TABLE_PATTERNS="${BACKUP_EXCLUDE_TABLE_PATTERNS:-telescope% pulse%}"

# Ağır dump/sıkıştırma adımlarını düşük CPU + idle disk önceliğiyle çalıştır: hedef
# donanım 3 diskli RAID5, yedek diziyi doyurup canlı DB trafiğini aç bırakmasın.
if command -v nice >/dev/null 2>&1 && command -v ionice >/dev/null 2>&1; then
    IO_NICE="nice -n 19 ionice -c3"
else
    IO_NICE=""
fi

# Lock mechanism (flock-based — bkz. acquire_lock)
LOCK_FILE="${LOCK_FILE:-/tmp/db_backup.lock}"

# Renk kodları
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# LOCK MECHANISM - Prevents concurrent backups (flock-based)
# =============================================================================
# Eski mantık lock dosyasının YAŞINA bakıyordu: LOCK_TIMEOUT'tan (840 sn, 15 dk
# cron aralığının altında) eskiyse, sahibi hâlâ çalışıyor olsa bile kilidi silip
# eşzamanlı ikinci bir yedek başlatabiliyordu. İki paralel `docker exec` dump =
# DB container cgroup'unda çift bellek baskısı = CONSTRAINT_MEMCG OOM.
#
# flock kilidi açık bir dosya tanımlayıcısına (fd 9) bağlar; kilit yalnızca
# process ölünce çekirdek tarafından bırakılır, sahibi yaşadığı sürece ASLA
# kırılmaz. Lock dosyası hiç silinmez (flock'lu bir path'i unlink etmek yarış
# koşuludur), sadece kilit fd üzerinden yönetilir.
acquire_lock() {
    command -v flock >/dev/null 2>&1 || {
        log "ERROR" "flock (util-linux) gerekli ama sistemde bulunamadı"
        exit 1
    }
    # Append modu: dosyayı truncate etmez, yoksa oluşturur.
    exec 9>>"$LOCK_FILE" || {
        log "ERROR" "Lock dosyası açılamadı: $LOCK_FILE"
        exit 1
    }
    if ! flock -n 9; then
        log "ERROR" "Başka bir yedek/işlem kilidi tutuyor ($LOCK_FILE)."
        log "ERROR" "Eşzamanlı çalışmayı önlemek için çıkılıyor."
        exit 1
    fi
    trap cleanup EXIT INT TERM
    log "INFO" "Lock acquired (PID: $$, flock: $LOCK_FILE)"
}

cleanup() {
    # flock, fd 9 process çıkışında kapanınca çekirdek tarafından otomatik
    # bırakılır — burada rm YOK (bilerek).
    log "INFO" "Lock released"
}

# =============================================================================
# DIRECTORIES & LOGGING
# =============================================================================
mkdir -p "$BACKUP_DIR"/{mariadb,postgresql,mongodb,redis}/{full,incremental,single}
mkdir -p "$LOG_DIR"

# Logging function with colors
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"

    case $level in
        "INFO")
            echo -e "${BLUE}${timestamp} [INFO]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "SUCCESS")
            echo -e "${GREEN}${timestamp} [SUCCESS]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "WARNING")
            echo -e "${YELLOW}${timestamp} [WARNING]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "ERROR")
            echo -e "${RED}${timestamp} [ERROR]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "DEBUG")
            echo -e "${CYAN}${timestamp} [DEBUG]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        *)
            echo -e "${timestamp} $level $message" | tee -a "$LOG_FILE"
            ;;
    esac
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check disk space
check_disk_space() {
    local available=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local available_kb=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4}')

    log "INFO" "Available disk space: $available"

    if [ "$available_kb" -lt 5242880 ]; then  # 5GB in KB - Critical
        log "ERROR" "CRITICAL: Less than 5GB available! Backup aborted."
        return 1
    elif [ "$available_kb" -lt 10485760 ]; then  # 10GB in KB - Warning
        log "WARNING" "Low disk space! Less than 10GB available"
    fi
    return 0
}

# Check if container is running
check_container() {
    local container=$1
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log "ERROR" "Container '$container' is not running!"
        return 1
    fi
    return 0
}

# Calculate duration
format_duration() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local secs=$((seconds % 60))
    echo "${minutes}m ${secs}s"
}

# =============================================================================
# DATABASE LIST FUNCTIONS
# =============================================================================

# Get list of all databases from MariaDB
# Parola MYSQL_PWD ortam değişkeniyle geçirilir (docker exec -e MYSQL_PWD, değer
# argümanda DEĞİL); böylece host'ta `ps` çıktısında görünmez.
get_mariadb_databases() {
    MYSQL_PWD="$DB_PASSWORD" docker exec -e MYSQL_PWD mariadb mariadb -u root -N -e "SHOW DATABASES;" 2>/dev/null | \
        grep -Ev "^(information_schema|performance_schema|mysql|sys)$" || \
    MYSQL_PWD="$DB_PASSWORD" docker exec -e MYSQL_PWD mariadb mysql -u root -N -e "SHOW DATABASES;" 2>/dev/null | \
        grep -Ev "^(information_schema|performance_schema|mysql|sys)$"
}

# Get list of all PostgreSQL databases
get_postgresql_databases() {
    docker exec postgresql psql -U root -d postgres -t -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" 2>/dev/null | \
        grep -v "^$" | xargs
}

# Get list of all MongoDB databases
get_mongodb_databases() {
    docker exec mongodb mongo -u root -p $DB_PASSWORD --authenticationDatabase admin --quiet --eval \
        "db.adminCommand('listDatabases').databases.forEach(function(d) { print(d.name); })" 2>/dev/null | \
        grep -v "^$" | grep -Ev "^(admin|config|local)$"
}

# =============================================================================
# MARIADB BACKUP FUNCTIONS
# =============================================================================

# BACKUP_EXCLUDE_TABLE_PATTERNS ile eşleşen tabloları --ignore-table=db.tablo
# argümanlarına çevirir. Sorgu başarısız olursa ya da desen boşsa hiçbir şey
# hariç tutulmaz — güvenli varsayılan tam dump'tır.
build_mariadb_ignore_args() {
    [ -z "$BACKUP_EXCLUDE_TABLE_PATTERNS" ] && return 0
    local where="" p
    for p in $BACKUP_EXCLUDE_TABLE_PATTERNS; do
        [ -n "$where" ] && where+=" OR "
        where+="TABLE_NAME LIKE '$p'"
    done
    MYSQL_PWD="$DB_PASSWORD" docker exec -e MYSQL_PWD mariadb mariadb -u root -N -e \
        "SELECT CONCAT('--ignore-table=', TABLE_SCHEMA, '.', TABLE_NAME)
         FROM information_schema.TABLES WHERE $where;" 2>/dev/null | tr '\n' ' '
}

# Backup ALL MariaDB databases
backup_mariadb() {
    local backup_type=${1:-"full"}
    local backup_name="mariadb_${backup_type}_${DATE}"
    local backup_path="$BACKUP_DIR/mariadb/$backup_type"
    local start_time=$(date +%s)

    log "INFO" "========================================="
    log "INFO" "Starting MariaDB FULL BACKUP"
    log "INFO" "========================================="

    # Pre-checks
    check_container "mariadb" || return 1
    check_disk_space || return 1

    # Get all databases
    local databases=$(get_mariadb_databases)
    local db_count=$(echo "$databases" | wc -l)

    log "INFO" "Found $db_count databases to backup"
    echo "$databases" | while read -r db; do
        [ -n "$db" ] && log "INFO" "  - $db"
    done

    # Telescope/Pulse gibi tabloları dump dışında bırak (yapılandırılabilir)
    local ignore_args
    ignore_args=$(build_mariadb_ignore_args)
    [ -n "$ignore_args" ] && log "INFO" "Excluding tables from dump: $ignore_args"

    # Create backup with optimized options
    log "INFO" "Creating comprehensive backup..."

    MYSQL_PWD="$DB_PASSWORD" $IO_NICE docker exec -e MYSQL_PWD mariadb mariadb-dump \
        -u root \
        --all-databases \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        --add-drop-database \
        --add-drop-table \
        --complete-insert \
        --skip-comments \
        $ignore_args \
        2>> "$LOG_FILE" | $IO_NICE gzip -${COMPRESSION_LEVEL} > "$backup_path/${backup_name}.sql.gz"

    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ] && [ -s "$backup_path/${backup_name}.sql.gz" ]; then
        local size=$(du -h "$backup_path/${backup_name}.sql.gz" | cut -f1)
        local duration=$(( $(date +%s) - start_time ))

        log "SUCCESS" "✓ MariaDB backup completed"
        log "INFO" "  Size: $size | Duration: $(format_duration $duration)"
        log "INFO" "  Location: $backup_path/${backup_name}.sql.gz"
        log "INFO" "  Databases: $db_count"

        # Verify backup integrity
        verify_backup "$backup_path/${backup_name}.sql.gz"
        return 0
    else
        log "ERROR" "✗ MariaDB backup failed (exit code: $exit_code)"
        rm -f "$backup_path/${backup_name}.sql.gz"
        return 1
    fi
}

# Backup SINGLE MariaDB database
backup_mariadb_single() {
    local db_name=$1
    local backup_name="mariadb_${db_name}_${DATE}"
    local backup_path="$BACKUP_DIR/mariadb/single"

    if [ -z "$db_name" ]; then
        log "ERROR" "Database name required for single backup"
        echo "Usage: $0 mariadb-single <database_name>"
        return 1
    fi

    check_container "mariadb" || return 1

    log "INFO" "Creating backup for database: $db_name"

    local ignore_args
    ignore_args=$(build_mariadb_ignore_args)

    MYSQL_PWD="$DB_PASSWORD" $IO_NICE docker exec -e MYSQL_PWD mariadb mariadb-dump \
        -u root \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        $ignore_args \
        "$db_name" \
        2>> "$LOG_FILE" | $IO_NICE gzip -${COMPRESSION_LEVEL} > "$backup_path/${backup_name}.sql.gz"

    if [ ${PIPESTATUS[0]} -eq 0 ] && [ -s "$backup_path/${backup_name}.sql.gz" ]; then
        local size=$(du -h "$backup_path/${backup_name}.sql.gz" | cut -f1)
        log "SUCCESS" "✓ Database '$db_name' backed up - Size: $size"
        return 0
    else
        log "ERROR" "✗ Failed to backup database '$db_name'"
        rm -f "$backup_path/${backup_name}.sql.gz"
        return 1
    fi
}

# =============================================================================
# POSTGRESQL BACKUP FUNCTIONS
# =============================================================================

backup_postgresql() {
    local backup_type=${1:-"full"}
    local backup_name="postgresql_${backup_type}_${DATE}"
    local backup_path="$BACKUP_DIR/postgresql/$backup_type"
    local start_time=$(date +%s)

    log "INFO" "========================================="
    log "INFO" "Starting PostgreSQL FULL BACKUP"
    log "INFO" "========================================="

    check_container "postgresql" || return 1
    check_disk_space || return 1

    # Get all databases
    local databases=$(get_postgresql_databases)
    local db_count=$(echo "$databases" | wc -w)

    log "INFO" "Found $db_count databases to backup"
    echo "$databases" | tr ' ' '\n' | while read -r db; do
        [ -n "$db" ] && log "INFO" "  - $db"
    done

    # Create comprehensive backup
    log "INFO" "Creating comprehensive backup..."

    $IO_NICE docker exec postgresql pg_dumpall -U root \
        --clean \
        --if-exists \
        --quote-all-identifiers \
        2>> "$LOG_FILE" | $IO_NICE gzip -${COMPRESSION_LEVEL} > "$backup_path/${backup_name}.sql.gz"

    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ] && [ -s "$backup_path/${backup_name}.sql.gz" ]; then
        local size=$(du -h "$backup_path/${backup_name}.sql.gz" | cut -f1)
        local duration=$(( $(date +%s) - start_time ))

        log "SUCCESS" "✓ PostgreSQL backup completed"
        log "INFO" "  Size: $size | Duration: $(format_duration $duration)"
        log "INFO" "  Location: $backup_path/${backup_name}.sql.gz"
        log "INFO" "  Databases: $db_count"

        verify_backup "$backup_path/${backup_name}.sql.gz"
        return 0
    else
        log "ERROR" "✗ PostgreSQL backup failed (exit code: $exit_code)"
        rm -f "$backup_path/${backup_name}.sql.gz"
        return 1
    fi
}

# =============================================================================
# MONGODB BACKUP FUNCTIONS
# =============================================================================

backup_mongodb() {
    local backup_type=${1:-"full"}
    local backup_name="mongodb_${backup_type}_${DATE}"
    local backup_path="$BACKUP_DIR/mongodb/$backup_type"
    local start_time=$(date +%s)

    log "INFO" "========================================="
    log "INFO" "Starting MongoDB FULL BACKUP"
    log "INFO" "========================================="

    check_container "mongodb" || return 1
    check_disk_space || return 1

    # Get all databases
    local databases=$(get_mongodb_databases)
    local db_count=$(echo "$databases" | wc -l)

    log "INFO" "Found $db_count user databases to backup"
    echo "$databases" | while read -r db; do
        [ -n "$db" ] && log "INFO" "  - $db"
    done

    # Clean temp directory
    docker exec mongodb rm -rf /tmp/backup 2>/dev/null

    # Create backup with mongodump
    log "INFO" "Creating comprehensive backup..."

    $IO_NICE docker exec mongodb mongodump \
        --host localhost \
        --port 27017 \
        --username root \
        --password "$DB_PASSWORD" \
        --authenticationDatabase admin \
        --out /tmp/backup \
        --gzip \
        --quiet \
        2>> "$LOG_FILE"

    if [ $? -eq 0 ]; then
        # Create tar archive
        $IO_NICE docker exec mongodb tar -cf - -C /tmp backup 2>/dev/null | \
            $IO_NICE gzip -${COMPRESSION_LEVEL} > "$backup_path/${backup_name}.tar.gz"

        if [ $? -eq 0 ] && [ -s "$backup_path/${backup_name}.tar.gz" ]; then
            docker exec mongodb rm -rf /tmp/backup 2>/dev/null

            local size=$(du -h "$backup_path/${backup_name}.tar.gz" | cut -f1)
            local duration=$(( $(date +%s) - start_time ))

            log "SUCCESS" "✓ MongoDB backup completed"
            log "INFO" "  Size: $size | Duration: $(format_duration $duration)"
            log "INFO" "  Location: $backup_path/${backup_name}.tar.gz"
            log "INFO" "  Databases: $db_count"

            verify_backup "$backup_path/${backup_name}.tar.gz"
            return 0
        fi
    fi

    log "ERROR" "✗ MongoDB backup failed"
    docker exec mongodb rm -rf /tmp/backup 2>/dev/null
    rm -f "$backup_path/${backup_name}.tar.gz"
    return 1
}

# =============================================================================
# REDIS BACKUP FUNCTIONS
# =============================================================================

backup_redis() {
    local backup_type=${1:-"full"}
    local backup_name="redis_${backup_type}_${DATE}"
    local backup_path="$BACKUP_DIR/redis/$backup_type"
    local start_time=$(date +%s)

    log "INFO" "========================================="
    log "INFO" "Starting Redis BACKUP"
    log "INFO" "========================================="

    check_container "redis" || return 1
    check_disk_space || return 1

    # Get Redis info
    local db_keys=$(docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning DBSIZE 2>/dev/null | grep -oE '[0-9]+')
    log "INFO" "Redis contains $db_keys keys"

    # Trigger BGSAVE
    log "INFO" "Triggering BGSAVE..."
    docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning BGSAVE >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        # Wait for BGSAVE to complete
        log "INFO" "Waiting for BGSAVE to complete..."
        local max_wait=30
        local waited=0
        while [ $waited -lt $max_wait ]; do
            local lastsave=$(docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning LASTSAVE 2>/dev/null)
            sleep 1
            local newsave=$(docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning LASTSAVE 2>/dev/null)
            if [ "$lastsave" != "$newsave" ] || [ $waited -gt 5 ]; then
                break
            fi
            ((waited++))
        done

        # Copy dump.rdb
        $IO_NICE docker exec redis cat /data/dump.rdb 2>/dev/null | \
            $IO_NICE gzip -${COMPRESSION_LEVEL} > "$backup_path/${backup_name}.rdb.gz"

        if [ $? -eq 0 ] && [ -s "$backup_path/${backup_name}.rdb.gz" ]; then
            local size=$(du -h "$backup_path/${backup_name}.rdb.gz" | cut -f1)
            local duration=$(( $(date +%s) - start_time ))

            log "SUCCESS" "✓ Redis backup completed"
            log "INFO" "  Size: $size | Duration: $(format_duration $duration)"
            log "INFO" "  Location: $backup_path/${backup_name}.rdb.gz"
            log "INFO" "  Keys: $db_keys"

            verify_backup "$backup_path/${backup_name}.rdb.gz"
            return 0
        fi
    fi

    log "ERROR" "✗ Redis backup failed"
    rm -f "$backup_path/${backup_name}.rdb.gz"
    return 1
}

# =============================================================================
# BACKUP ALL DATABASES
# =============================================================================

backup_all() {
    acquire_lock

    log "INFO" "========================================="
    log "INFO" "Starting FULL BACKUP of ALL DATABASES"
    log "INFO" "========================================="
    log "INFO" "Backup directory: $BACKUP_DIR"
    log "INFO" "Timestamp: $DATE"
    log "INFO" "Compression level: $COMPRESSION_LEVEL"
    log "INFO" ""

    local start_time=$(date +%s)
    local success_count=0
    local fail_count=0

    # MariaDB
    backup_mariadb "full" && ((success_count++)) || ((fail_count++))
    echo ""

    # PostgreSQL
    backup_postgresql "full" && ((success_count++)) || ((fail_count++))
    echo ""

    # MongoDB
    backup_mongodb "full" && ((success_count++)) || ((fail_count++))
    echo ""

    # Redis
    backup_redis "full" && ((success_count++)) || ((fail_count++))

    # Summary
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    log "INFO" "========================================="
    log "INFO" "BACKUP SUMMARY"
    log "INFO" "========================================="
    log "INFO" "Total time: $(format_duration $duration)"
    log "SUCCESS" "Successful backups: $success_count"
    [ $fail_count -gt 0 ] && log "ERROR" "Failed backups: $fail_count" || log "INFO" "Failed backups: $fail_count"

    # Calculate total backup size
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    local available=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    log "INFO" "Total backup size: $total_size"
    log "INFO" "Available space: $available"
    log "INFO" "========================================="

    return $fail_count
}

# =============================================================================
# BACKUP VERIFICATION
# =============================================================================

verify_backup() {
    local backup_file=$1

    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi

    log "INFO" "Verifying backup integrity..."

    if [[ $backup_file == *.tar.gz ]]; then
        if tar -tzf "$backup_file" > /dev/null 2>&1; then
            log "SUCCESS" "✓ Backup integrity verified (tar.gz)"
            return 0
        fi
    elif [[ $backup_file == *.gz ]]; then
        if gzip -t "$backup_file" 2>&1; then
            log "SUCCESS" "✓ Backup integrity verified (gz)"
            return 0
        fi
    else
        log "INFO" "✓ Backup file exists (uncompressed)"
        return 0
    fi

    log "ERROR" "✗ Backup file is corrupted!"
    return 1
}

# =============================================================================
# RESTORE FUNCTIONS
# =============================================================================

restore_mariadb() {
    local backup_file=$1

    if [ -z "$backup_file" ]; then
        echo "Usage: $0 restore-mariadb <backup_file.sql.gz>"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi

    log "WARNING" "⚠️  RESTORING MARIADB - This will overwrite existing data!"
    log "INFO" "From: $backup_file"
    echo ""
    read -p "Type 'yes' to continue: " confirm

    if [ "$confirm" != "yes" ]; then
        log "INFO" "Restore cancelled"
        return 1
    fi

    log "INFO" "Starting MariaDB restore..."

    if [[ $backup_file == *.gz ]]; then
        gunzip -c "$backup_file" | MYSQL_PWD="$DB_PASSWORD" docker exec -e MYSQL_PWD -i mariadb mariadb -u root
    else
        MYSQL_PWD="$DB_PASSWORD" docker exec -e MYSQL_PWD -i mariadb mariadb -u root < "$backup_file"
    fi

    if [ $? -eq 0 ]; then
        log "SUCCESS" "✓ MariaDB restore completed successfully"
        return 0
    else
        log "ERROR" "✗ MariaDB restore failed"
        return 1
    fi
}

restore_postgresql() {
    local backup_file=$1

    if [ -z "$backup_file" ]; then
        echo "Usage: $0 restore-postgresql <backup_file.sql.gz>"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi

    log "WARNING" "⚠️  RESTORING POSTGRESQL - This will overwrite existing data!"
    log "INFO" "From: $backup_file"
    echo ""
    read -p "Type 'yes' to continue: " confirm

    if [ "$confirm" != "yes" ]; then
        log "INFO" "Restore cancelled"
        return 1
    fi

    log "INFO" "Starting PostgreSQL restore..."

    if [[ $backup_file == *.gz ]]; then
        gunzip -c "$backup_file" | docker exec -i postgresql psql -U root -d postgres
    else
        docker exec -i postgresql psql -U root -d postgres < "$backup_file"
    fi

    if [ $? -eq 0 ]; then
        log "SUCCESS" "✓ PostgreSQL restore completed successfully"
        return 0
    else
        log "ERROR" "✗ PostgreSQL restore failed"
        return 1
    fi
}

restore_mongodb() {
    local backup_file=$1

    if [ -z "$backup_file" ]; then
        echo "Usage: $0 restore-mongodb <backup_file.tar.gz>"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi

    log "WARNING" "⚠️  RESTORING MONGODB - This will overwrite existing data!"
    log "INFO" "From: $backup_file"
    echo ""
    read -p "Type 'yes' to continue: " confirm

    if [ "$confirm" != "yes" ]; then
        log "INFO" "Restore cancelled"
        return 1
    fi

    log "INFO" "Starting MongoDB restore..."

    # Extract and restore
    cat "$backup_file" | docker exec -i mongodb tar -xzf - -C /tmp

    if [ $? -eq 0 ]; then
        docker exec mongodb mongorestore \
            --host localhost \
            --port 27017 \
            --username root \
            --password $DB_PASSWORD \
            --authenticationDatabase admin \
            --drop \
            --gzip \
            /tmp/backup

        local result=$?
        docker exec mongodb rm -rf /tmp/backup

        if [ $result -eq 0 ]; then
            log "SUCCESS" "✓ MongoDB restore completed successfully"
            return 0
        fi
    fi

    log "ERROR" "✗ MongoDB restore failed"
    docker exec mongodb rm -rf /tmp/backup 2>/dev/null
    return 1
}

restore_redis() {
    local backup_file=$1

    if [ -z "$backup_file" ]; then
        echo "Usage: $0 restore-redis <backup_file.rdb.gz>"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi

    log "WARNING" "⚠️  RESTORING REDIS - This will overwrite existing data!"
    log "INFO" "From: $backup_file"
    echo ""
    read -p "Type 'yes' to continue: " confirm

    if [ "$confirm" != "yes" ]; then
        log "INFO" "Restore cancelled"
        return 1
    fi

    log "INFO" "Starting Redis restore..."

    # Stop Redis, replace dump, restart
    docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning SHUTDOWN NOSAVE 2>/dev/null
    sleep 2

    # Backup old dump
    docker exec redis mv /data/dump.rdb /data/dump.rdb.old 2>/dev/null

    # Restore new dump
    if [[ $backup_file == *.gz ]]; then
        gunzip -c "$backup_file" | docker exec -i redis sh -c 'cat > /data/dump.rdb'
    else
        cat "$backup_file" | docker exec -i redis sh -c 'cat > /data/dump.rdb'
    fi

    # Restart Redis
    docker restart redis
    sleep 5

    # Verify
    if docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning PING 2>/dev/null | grep -q "PONG"; then
        log "SUCCESS" "✓ Redis restore completed successfully"
        return 0
    else
        log "ERROR" "✗ Redis restore failed - container may not be healthy"
        return 1
    fi
}

# =============================================================================
# MAINTENANCE FUNCTIONS
# =============================================================================

clean_old_backups() {
    local days=${1:-$RETENTION_DAYS}

    log "INFO" "========================================="
    log "INFO" "Cleaning backups older than $days days..."
    log "INFO" "========================================="

    local before_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

    # Count files before deletion
    local gz_count=$(find "$BACKUP_DIR" -type f -name "*.gz" -mtime +$days 2>/dev/null | wc -l)
    local tar_count=$(find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$days 2>/dev/null | wc -l)
    local total_count=$((gz_count + tar_count))

    if [ $total_count -gt 0 ]; then
        log "INFO" "Found $total_count old backup files"

        # List files to be deleted
        find "$BACKUP_DIR" -type f \( -name "*.gz" -o -name "*.tar.gz" \) -mtime +$days 2>/dev/null | \
            head -10 | while read -r f; do
                log "INFO" "  Deleting: $(basename $f)"
            done

        [ $total_count -gt 10 ] && log "INFO" "  ... and $((total_count - 10)) more"

        # Delete old backups
        find "$BACKUP_DIR" -type f -name "*.gz" -mtime +$days -delete 2>/dev/null
        find "$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +$days -delete 2>/dev/null

        local after_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

        log "SUCCESS" "✓ Cleaned $total_count old backup file(s)"
        log "INFO" "Space before: $before_size"
        log "INFO" "Space after: $after_size"
    else
        log "INFO" "No old backups found to clean"
    fi

    log "INFO" "========================================="
}

list_backups() {
    log "INFO" "========================================="
    log "INFO" "AVAILABLE BACKUPS"
    log "INFO" "========================================="
    log "INFO" "Backup directory: $BACKUP_DIR"
    echo ""

    # MariaDB backups
    echo -e "${BLUE}MariaDB Backups (last 10):${NC}"
    find "$BACKUP_DIR/mariadb" -type f -name "*.gz" 2>/dev/null | \
        xargs ls -lht 2>/dev/null | head -10 | \
        awk '{printf "  %s %s %s  %s  %s\n", $6, $7, $8, $5, $9}'
    [ $(find "$BACKUP_DIR/mariadb" -type f -name "*.gz" 2>/dev/null | wc -l) -eq 0 ] && echo "  (no backups)"
    echo ""

    # PostgreSQL backups
    echo -e "${BLUE}PostgreSQL Backups (last 10):${NC}"
    find "$BACKUP_DIR/postgresql" -type f -name "*.gz" 2>/dev/null | \
        xargs ls -lht 2>/dev/null | head -10 | \
        awk '{printf "  %s %s %s  %s  %s\n", $6, $7, $8, $5, $9}'
    [ $(find "$BACKUP_DIR/postgresql" -type f -name "*.gz" 2>/dev/null | wc -l) -eq 0 ] && echo "  (no backups)"
    echo ""

    # MongoDB backups
    echo -e "${BLUE}MongoDB Backups (last 10):${NC}"
    find "$BACKUP_DIR/mongodb" -type f -name "*.tar.gz" 2>/dev/null | \
        xargs ls -lht 2>/dev/null | head -10 | \
        awk '{printf "  %s %s %s  %s  %s\n", $6, $7, $8, $5, $9}'
    [ $(find "$BACKUP_DIR/mongodb" -type f -name "*.tar.gz" 2>/dev/null | wc -l) -eq 0 ] && echo "  (no backups)"
    echo ""

    # Redis backups
    echo -e "${BLUE}Redis Backups (last 10):${NC}"
    find "$BACKUP_DIR/redis" -type f -name "*.gz" 2>/dev/null | \
        xargs ls -lht 2>/dev/null | head -10 | \
        awk '{printf "  %s %s %s  %s  %s\n", $6, $7, $8, $5, $9}'
    [ $(find "$BACKUP_DIR/redis" -type f -name "*.gz" 2>/dev/null | wc -l) -eq 0 ] && echo "  (no backups)"
    echo ""

    # Total size
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    log "INFO" "Total backup size: $total_size"
    log "INFO" "========================================="
}

backup_stats() {
    log "INFO" "========================================="
    log "INFO" "BACKUP SYSTEM STATISTICS"
    log "INFO" "========================================="

    # Disk usage
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    local available=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local used_percent=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $5}')

    log "INFO" "Storage Information:"
    log "INFO" "  Total backup size: $total_size"
    log "INFO" "  Available space: $available"
    log "INFO" "  Disk usage: $used_percent"
    echo ""

    # Count by type
    local mariadb_count=$(find "$BACKUP_DIR/mariadb" -type f -name "*.gz" 2>/dev/null | wc -l)
    local postgresql_count=$(find "$BACKUP_DIR/postgresql" -type f -name "*.gz" 2>/dev/null | wc -l)
    local mongodb_count=$(find "$BACKUP_DIR/mongodb" -type f -name "*.tar.gz" 2>/dev/null | wc -l)
    local redis_count=$(find "$BACKUP_DIR/redis" -type f -name "*.gz" 2>/dev/null | wc -l)
    local total_count=$((mariadb_count + postgresql_count + mongodb_count + redis_count))

    log "INFO" "Backup Counts:"
    log "INFO" "  MariaDB:    $mariadb_count backups"
    log "INFO" "  PostgreSQL: $postgresql_count backups"
    log "INFO" "  MongoDB:    $mongodb_count backups"
    log "INFO" "  Redis:      $redis_count backups"
    log "INFO" "  TOTAL:      $total_count backups"
    echo ""

    # Size by type
    local mariadb_size=$(du -sh "$BACKUP_DIR/mariadb" 2>/dev/null | cut -f1)
    local postgresql_size=$(du -sh "$BACKUP_DIR/postgresql" 2>/dev/null | cut -f1)
    local mongodb_size=$(du -sh "$BACKUP_DIR/mongodb" 2>/dev/null | cut -f1)
    local redis_size=$(du -sh "$BACKUP_DIR/redis" 2>/dev/null | cut -f1)

    log "INFO" "Size by Type:"
    log "INFO" "  MariaDB:    $mariadb_size"
    log "INFO" "  PostgreSQL: $postgresql_size"
    log "INFO" "  MongoDB:    $mongodb_size"
    log "INFO" "  Redis:      $redis_size"
    echo ""

    # Most recent backups
    log "INFO" "Most Recent Backups:"
    local recent_mariadb=$(find "$BACKUP_DIR/mariadb" -type f -name "*.gz" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2)
    local recent_postgresql=$(find "$BACKUP_DIR/postgresql" -type f -name "*.gz" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2)
    local recent_mongodb=$(find "$BACKUP_DIR/mongodb" -type f -name "*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2)
    local recent_redis=$(find "$BACKUP_DIR/redis" -type f -name "*.gz" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2)

    [ -n "$recent_mariadb" ] && log "INFO" "  MariaDB:    $(ls -lh "$recent_mariadb" 2>/dev/null | awk '{print $6, $7, $8, "-", $5}')"
    [ -n "$recent_postgresql" ] && log "INFO" "  PostgreSQL: $(ls -lh "$recent_postgresql" 2>/dev/null | awk '{print $6, $7, $8, "-", $5}')"
    [ -n "$recent_mongodb" ] && log "INFO" "  MongoDB:    $(ls -lh "$recent_mongodb" 2>/dev/null | awk '{print $6, $7, $8, "-", $5}')"
    [ -n "$recent_redis" ] && log "INFO" "  Redis:      $(ls -lh "$recent_redis" 2>/dev/null | awk '{print $6, $7, $8, "-", $5}')"

    echo ""
    log "INFO" "Configuration:"
    log "INFO" "  Retention: $RETENTION_DAYS days"
    log "INFO" "  Compression: gzip -$COMPRESSION_LEVEL"
    log "INFO" "  Lock: flock ($LOCK_FILE)"
    log "INFO" "========================================="
}

list_all_databases() {
    log "INFO" "========================================="
    log "INFO" "ALL DATABASES IN SYSTEM"
    log "INFO" "========================================="

    echo -e "\n${BLUE}MariaDB Databases:${NC}"
    if check_container "mariadb" 2>/dev/null; then
        get_mariadb_databases | while read -r db; do
            [ -n "$db" ] && echo "  - $db"
        done
    else
        echo "  (container not running)"
    fi

    echo -e "\n${BLUE}PostgreSQL Databases:${NC}"
    if check_container "postgresql" 2>/dev/null; then
        get_postgresql_databases | tr ' ' '\n' | while read -r db; do
            [ -n "$db" ] && echo "  - $db"
        done
    else
        echo "  (container not running)"
    fi

    echo -e "\n${BLUE}MongoDB Databases:${NC}"
    if check_container "mongodb" 2>/dev/null; then
        get_mongodb_databases | while read -r db; do
            [ -n "$db" ] && echo "  - $db"
        done
    else
        echo "  (container not running)"
    fi

    echo -e "\n${BLUE}Redis:${NC}"
    if check_container "redis" 2>/dev/null; then
        local redis_keys=$(docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning DBSIZE 2>/dev/null)
        echo "  - Keys: $redis_keys"
        local redis_memory=$(docker exec redis redis-cli -a $DB_PASSWORD --no-auth-warning INFO memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
        echo "  - Memory: $redis_memory"
    else
        echo "  (container not running)"
    fi

    log "INFO" "========================================="
}

# =============================================================================
# HELP & MAIN
# =============================================================================

show_help() {
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  Database Backup Script V7${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "System Configuration:"
    echo "  MariaDB:    v11.4 (ALL databases backup)"
    echo "  PostgreSQL: v15 (full backup)"
    echo "  MongoDB:    v4.4 (full backup)"
    echo "  Redis:      v8.2.2 (RDB snapshot)"
    echo ""
    echo "✅ Features:"
    echo "  - Lock mechanism (prevents concurrent runs)"
    echo "  - ALL databases backup (not just defaultdb)"
    echo "  - Individual database backup"
    echo "  - Backup verification"
    echo "  - Disk space checking"
    echo "  - Container health checking"
    echo "  - Fast compression (gzip -$COMPRESSION_LEVEL)"
    echo "  - Detailed logging with colors"
    echo ""
    echo "Usage: $0 {command} [options]"
    echo ""
    echo -e "${BLUE}Backup Commands:${NC}"
    echo "  $0 all                        - Backup ALL databases (RECOMMENDED)"
    echo "  $0 mariadb [type]             - Backup ALL MariaDB databases"
    echo "  $0 mariadb-single <db_name>   - Backup single MariaDB database"
    echo "  $0 postgresql [type]          - Backup ALL PostgreSQL databases"
    echo "  $0 mongodb [type]             - Backup ALL MongoDB databases"
    echo "  $0 redis [type]               - Backup Redis"
    echo ""
    echo -e "${BLUE}Restore Commands:${NC}"
    echo "  $0 restore-mariadb <file>     - Restore MariaDB from backup"
    echo "  $0 restore-postgresql <file>  - Restore PostgreSQL from backup"
    echo "  $0 restore-mongodb <file>     - Restore MongoDB from backup"
    echo "  $0 restore-redis <file>       - Restore Redis from backup"
    echo ""
    echo -e "${BLUE}Maintenance Commands:${NC}"
    echo "  $0 clean [days]               - Clean old backups (default: $RETENTION_DAYS days)"
    echo "  $0 list                       - List recent backups"
    echo "  $0 stats                      - Show detailed statistics"
    echo "  $0 verify <file>              - Verify backup integrity"
    echo "  $0 list-databases             - List all databases in system"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  $0 all"
    echo "  $0 mariadb-single ecommerce_db"
    echo "  $0 list-databases"
    echo "  $0 stats"
    echo "  $0 clean 7"
    echo "  $0 restore-mariadb /opt/databases/backups/mariadb/full/mariadb_full_20250127.sql.gz"
    echo ""
    echo -e "${CYAN}Cron Example (daily 02:00):${NC}"
    echo "  0 2 * * * $0 all >> /opt/databases/logs/cron_backup.log 2>&1"
    echo ""
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

case "$1" in
    "all")
        backup_all
        ;;
    "mariadb")
        acquire_lock
        backup_mariadb "$2"
        ;;
    "mariadb-single")
        acquire_lock
        backup_mariadb_single "$2"
        ;;
    "postgresql")
        acquire_lock
        backup_postgresql "$2"
        ;;
    "mongodb")
        acquire_lock
        backup_mongodb "$2"
        ;;
    "redis")
        acquire_lock
        backup_redis "$2"
        ;;
    "restore-mariadb")
        restore_mariadb "$2"
        ;;
    "restore-postgresql")
        restore_postgresql "$2"
        ;;
    "restore-mongodb")
        restore_mongodb "$2"
        ;;
    "restore-redis")
        restore_redis "$2"
        ;;
    "clean")
        clean_old_backups "$2"
        ;;
    "list")
        list_backups
        ;;
    "stats")
        backup_stats
        ;;
    "verify")
        verify_backup "$2"
        ;;
    "list-databases")
        list_all_databases
        ;;
    "help"|"--help"|"-h")
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac

exit $?