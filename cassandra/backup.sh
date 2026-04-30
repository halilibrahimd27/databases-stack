#!/bin/bash

# =============================================================================
# Cassandra Backup Script V1 - PRODUCTION GRADE
# Apache Cassandra 5.0
#
# ✅ nodetool snapshot based backup
# ✅ Schema backup (CQL)
# ✅ All keyspaces backup support
# ✅ Individual keyspace backup
# ✅ Backup verification
# ✅ Lock mechanism (prevents concurrent runs)
# ✅ Compression with tar.gz
# ✅ Detailed logging
# ✅ Container health checking
# =============================================================================

# Yapılandırma — ortam değişkenleri ile override et
BASE_DIR="${CASSANDRA_BASE_DIR:-/opt/cassandra}"
BACKUP_DIR="${BACKUP_DIR:-${BASE_DIR}/backups}"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
DATE=$(date +%Y%m%d_%H%M%S)
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
CASSANDRA_PASS="${CASSANDRA_PASS:?CASSANDRA_PASS env var zorunlu}"
CONTAINER_NAME="${CONTAINER_NAME:-cassandra}"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d).log"
RETENTION_DAYS=7
COMPRESSION_LEVEL=6

# Lock mechanism
LOCK_FILE="/tmp/cassandra_backup.lock"
LOCK_TIMEOUT=1800  # 30 dakika

# Renk kodları
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# LOCK MECHANISM
# =============================================================================
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        local lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))

        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            if [ "$lock_age" -gt "$LOCK_TIMEOUT" ]; then
                log "WARNING" "Stale lock detected (${lock_age}s old), removing..."
                rm -f "$LOCK_FILE"
            else
                log "ERROR" "Another backup is running (PID: $lock_pid, Age: ${lock_age}s)"
                log "ERROR" "If this is incorrect, remove: $LOCK_FILE"
                exit 1
            fi
        else
            log "WARNING" "Orphaned lock file found (PID $lock_pid not running), removing..."
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap cleanup EXIT INT TERM
    log "INFO" "Lock acquired (PID: $$)"
}

release_lock() {
    rm -f "$LOCK_FILE"
    log "INFO" "Lock released"
}

cleanup() {
    release_lock
}

# =============================================================================
# DIRECTORIES & LOGGING
# =============================================================================
mkdir -p "$BACKUP_DIR"/{snapshots,schema,single}
mkdir -p "$LOG_DIR"

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

check_disk_space() {
    local available=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local available_kb=$(df "$BACKUP_DIR" | awk 'NR==2 {print $4}')

    log "INFO" "Available disk space: $available"

    if [ "$available_kb" -lt 5242880 ]; then
        log "ERROR" "CRITICAL: Less than 5GB available! Backup aborted."
        return 1
    elif [ "$available_kb" -lt 10485760 ]; then
        log "WARNING" "Low disk space! Less than 10GB available"
    fi
    return 0
}

check_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        log "ERROR" "Container '$CONTAINER_NAME' is not running!"
        return 1
    fi
    return 0
}

check_cassandra_status() {
    local status=$(docker exec $CONTAINER_NAME nodetool status 2>/dev/null | grep "^UN" | wc -l)
    if [ "$status" -eq 0 ]; then
        log "ERROR" "Cassandra node is not UP/NORMAL!"
        return 1
    fi
    log "SUCCESS" "Cassandra node is UP/NORMAL"
    return 0
}

format_duration() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local secs=$((seconds % 60))
    echo "${minutes}m ${secs}s"
}

# =============================================================================
# KEYSPACE FUNCTIONS
# =============================================================================

get_keyspaces() {
    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "SELECT keyspace_name FROM system_schema.keyspaces;" 2>/dev/null | \
        grep -v "system\|keyspace_name\|----\|rows\|^$" | \
        awk '{print $1}' | \
        grep -v "^$"
}

get_user_keyspaces() {
    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "SELECT keyspace_name FROM system_schema.keyspaces;" 2>/dev/null | \
        grep -v "^system\|keyspace_name\|----\|rows\|^$" | \
        awk '{print $1}' | \
        grep -v "^$"
}

# =============================================================================
# SCHEMA BACKUP
# =============================================================================

backup_schema() {
    local keyspace=${1:-"all"}
    local schema_file="$BACKUP_DIR/schema/schema_${keyspace}_${DATE}.cql"
    
    log "INFO" "Backing up schema for: $keyspace"
    
    if [ "$keyspace" == "all" ]; then
        docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
            -e "DESCRIBE FULL SCHEMA" > "$schema_file" 2>> "$LOG_FILE"
    else
        docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
            -e "DESCRIBE KEYSPACE $keyspace" > "$schema_file" 2>> "$LOG_FILE"
    fi
    
    if [ $? -eq 0 ] && [ -s "$schema_file" ]; then
        gzip "$schema_file"
        log "SUCCESS" "Schema backup created: ${schema_file}.gz"
        return 0
    else
        log "ERROR" "Schema backup failed!"
        rm -f "$schema_file"
        return 1
    fi
}

# =============================================================================
# SNAPSHOT BACKUP
# =============================================================================

backup_cassandra() {
    local backup_type=${1:-"full"}
    local snapshot_name="backup_${DATE}"
    local backup_path="$BACKUP_DIR/snapshots"
    local start_time=$(date +%s)

    log "INFO" "========================================="
    log "INFO" "Starting Cassandra SNAPSHOT BACKUP"
    log "INFO" "========================================="

    # Pre-checks
    check_container || return 1
    check_cassandra_status || return 1
    check_disk_space || return 1

    # Get all user keyspaces
    local keyspaces=$(get_user_keyspaces)
    local ks_count=$(echo "$keyspaces" | grep -v "^$" | wc -l)

    log "INFO" "Found $ks_count user keyspaces to backup"
    echo "$keyspaces" | while read -r ks; do
        [ -n "$ks" ] && log "INFO" "  - $ks"
    done

    # Flush memtables to disk
    log "INFO" "Flushing memtables to disk..."
    docker exec $CONTAINER_NAME nodetool flush 2>> "$LOG_FILE"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to flush memtables!"
        return 1
    fi
    log "SUCCESS" "Memtables flushed"

    # Take snapshot
    log "INFO" "Creating snapshot: $snapshot_name"
    docker exec $CONTAINER_NAME nodetool snapshot -t "$snapshot_name" 2>> "$LOG_FILE"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create snapshot!"
        return 1
    fi
    log "SUCCESS" "Snapshot created: $snapshot_name"

    # Backup schema first
    backup_schema "all"

    # Create backup archive
    local archive_name="cassandra_${backup_type}_${DATE}.tar.gz"
    local archive_path="$backup_path/$archive_name"
    
    log "INFO" "Creating backup archive..."
    
    # Copy snapshot data from container
    docker exec $CONTAINER_NAME bash -c "
        find /var/lib/cassandra/data -type d -name '$snapshot_name' -exec tar cf - {} + 2>/dev/null
    " | gzip -${COMPRESSION_LEVEL} > "$archive_path"

    if [ $? -eq 0 ] && [ -s "$archive_path" ]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local size=$(du -h "$archive_path" | cut -f1)
        
        log "SUCCESS" "Backup archive created: $archive_name"
        log "SUCCESS" "Size: $size"
        log "SUCCESS" "Duration: $(format_duration $duration)"
        
        # Verify backup
        verify_backup "$archive_path"
        
        # Clean snapshot from Cassandra
        log "INFO" "Cleaning snapshot from Cassandra..."
        docker exec $CONTAINER_NAME nodetool clearsnapshot -t "$snapshot_name" 2>> "$LOG_FILE"
        log "SUCCESS" "Snapshot cleaned"
        
        log "SUCCESS" "========================================="
        log "SUCCESS" "Cassandra backup completed successfully!"
        log "SUCCESS" "========================================="
        return 0
    else
        log "ERROR" "Failed to create backup archive!"
        # Clean failed snapshot
        docker exec $CONTAINER_NAME nodetool clearsnapshot -t "$snapshot_name" 2>/dev/null
        return 1
    fi
}

# =============================================================================
# SINGLE KEYSPACE BACKUP
# =============================================================================

backup_keyspace() {
    local keyspace=$1
    local snapshot_name="backup_${keyspace}_${DATE}"
    local backup_path="$BACKUP_DIR/single"
    local start_time=$(date +%s)

    if [ -z "$keyspace" ]; then
        log "ERROR" "Keyspace name required!"
        log "INFO" "Usage: $0 keyspace <keyspace_name>"
        return 1
    fi

    log "INFO" "========================================="
    log "INFO" "Starting Keyspace Backup: $keyspace"
    log "INFO" "========================================="

    # Pre-checks
    check_container || return 1
    check_cassandra_status || return 1

    # Check if keyspace exists
    local ks_exists=$(docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "DESCRIBE KEYSPACE $keyspace" 2>&1)
    
    if echo "$ks_exists" | grep -qi "not found\|invalid"; then
        log "ERROR" "Keyspace '$keyspace' not found!"
        return 1
    fi

    # Flush keyspace
    log "INFO" "Flushing keyspace: $keyspace"
    docker exec $CONTAINER_NAME nodetool flush $keyspace 2>> "$LOG_FILE"

    # Take snapshot
    log "INFO" "Creating snapshot for keyspace: $keyspace"
    docker exec $CONTAINER_NAME nodetool snapshot -t "$snapshot_name" -- $keyspace 2>> "$LOG_FILE"

    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to create keyspace snapshot!"
        return 1
    fi

    # Backup schema
    backup_schema "$keyspace"

    # Create archive
    local archive_name="${keyspace}_${DATE}.tar.gz"
    local archive_path="$backup_path/$archive_name"
    
    docker exec $CONTAINER_NAME bash -c "
        find /var/lib/cassandra/data/$keyspace -type d -name '$snapshot_name' -exec tar cf - {} + 2>/dev/null
    " | gzip -${COMPRESSION_LEVEL} > "$archive_path"

    if [ $? -eq 0 ] && [ -s "$archive_path" ]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local size=$(du -h "$archive_path" | cut -f1)
        
        log "SUCCESS" "Keyspace backup created: $archive_name"
        log "SUCCESS" "Size: $size, Duration: $(format_duration $duration)"
        
        # Clean snapshot
        docker exec $CONTAINER_NAME nodetool clearsnapshot -t "$snapshot_name" 2>> "$LOG_FILE"
        
        return 0
    else
        log "ERROR" "Failed to create keyspace backup!"
        docker exec $CONTAINER_NAME nodetool clearsnapshot -t "$snapshot_name" 2>/dev/null
        return 1
    fi
}

# =============================================================================
# VERIFY BACKUP
# =============================================================================

verify_backup() {
    local backup_file=$1
    
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi
    
    log "INFO" "Verifying backup integrity..."
    
    # Check gzip integrity
    if gzip -t "$backup_file" 2>/dev/null; then
        log "SUCCESS" "✓ Archive integrity verified"
    else
        log "ERROR" "✗ Archive is corrupted!"
        return 1
    fi
    
    # Check archive contents
    local file_count=$(tar -tzf "$backup_file" 2>/dev/null | wc -l)
    if [ "$file_count" -gt 0 ]; then
        log "SUCCESS" "✓ Archive contains $file_count files"
    else
        log "WARNING" "⚠ Archive appears to be empty"
    fi
    
    return 0
}

# =============================================================================
# RESTORE FUNCTIONS
# =============================================================================

restore_cassandra() {
    local backup_file=$1
    
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        log "INFO" "Usage: $0 restore <backup_file.tar.gz>"
        return 1
    fi

    log "INFO" "========================================="
    log "INFO" "Starting Cassandra RESTORE"
    log "INFO" "========================================="
    
    log "WARNING" "This will restore data from: $backup_file"
    read -p "Are you sure? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log "INFO" "Restore cancelled"
        return 1
    fi

    check_container || return 1
    check_cassandra_status || return 1

    # Extract backup info
    local backup_name=$(basename "$backup_file" .tar.gz)
    local restore_dir="/tmp/cassandra_restore_$$"
    
    mkdir -p "$restore_dir"
    
    log "INFO" "Extracting backup archive..."
    tar -xzf "$backup_file" -C "$restore_dir" 2>> "$LOG_FILE"
    
    if [ $? -ne 0 ]; then
        log "ERROR" "Failed to extract backup!"
        rm -rf "$restore_dir"
        return 1
    fi

    # Find and copy SSTable files
    log "INFO" "Restoring SSTables..."
    
    # Copy SSTables to container
    find "$restore_dir" -type f \( -name "*.db" -o -name "*.txt" -o -name "*.crc32" -o -name "*.sha1" \) | while read -r file; do
        local relative_path=$(echo "$file" | sed "s|$restore_dir||")
        local dest_path="/var/lib/cassandra/data${relative_path}"
        
        # Remove snapshot directory from path
        dest_path=$(echo "$dest_path" | sed 's|/snapshots/[^/]*/|/|')
        
        docker cp "$file" "$CONTAINER_NAME:$dest_path" 2>> "$LOG_FILE"
    done

    # Refresh tables
    log "INFO" "Refreshing Cassandra tables..."
    local keyspaces=$(get_user_keyspaces)
    
    for ks in $keyspaces; do
        local tables=$(docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
            -e "SELECT table_name FROM system_schema.tables WHERE keyspace_name='$ks';" 2>/dev/null | \
            grep -v "table_name\|----\|rows\|^$" | awk '{print $1}')
        
        for table in $tables; do
            [ -n "$table" ] && docker exec $CONTAINER_NAME nodetool refresh $ks $table 2>> "$LOG_FILE"
        done
    done

    # Cleanup
    rm -rf "$restore_dir"
    
    log "SUCCESS" "========================================="
    log "SUCCESS" "Cassandra restore completed!"
    log "SUCCESS" "========================================="
    
    return 0
}

# =============================================================================
# MAINTENANCE FUNCTIONS
# =============================================================================

clean_old_backups() {
    local days=${1:-$RETENTION_DAYS}
    
    log "INFO" "========================================="
    log "INFO" "Cleaning backups older than $days days"
    log "INFO" "========================================="
    
    local deleted=0
    
    # Clean snapshots
    while IFS= read -r -d '' file; do
        log "INFO" "Removing: $(basename "$file")"
        rm -f "$file"
        ((deleted++))
    done < <(find "$BACKUP_DIR" -type f \( -name "*.tar.gz" -o -name "*.gz" \) -mtime +${days} -print0 2>/dev/null)
    
    log "SUCCESS" "Removed $deleted old backup files"
    log "INFO" "========================================="
}

list_backups() {
    log "INFO" "========================================="
    log "INFO" "AVAILABLE BACKUPS"
    log "INFO" "========================================="
    
    echo ""
    log "INFO" "Snapshot Backups:"
    ls -lh "$BACKUP_DIR/snapshots/"*.tar.gz 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
    
    echo ""
    log "INFO" "Schema Backups:"
    ls -lh "$BACKUP_DIR/schema/"*.gz 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
    
    echo ""
    log "INFO" "Single Keyspace Backups:"
    ls -lh "$BACKUP_DIR/single/"*.tar.gz 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
    
    log "INFO" "========================================="
}

backup_stats() {
    log "INFO" "========================================="
    log "INFO" "BACKUP STATISTICS"
    log "INFO" "========================================="
    
    local total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    local disk_free=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    local disk_used=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $5}')
    
    echo ""
    log "INFO" "Storage:"
    log "INFO" "  Backup directory: $BACKUP_DIR"
    log "INFO" "  Total backup size: $total_size"
    log "INFO" "  Disk free: $disk_free"
    log "INFO" "  Disk usage: $disk_used"
    
    echo ""
    local snapshot_count=$(find "$BACKUP_DIR/snapshots" -type f -name "*.tar.gz" 2>/dev/null | wc -l)
    local schema_count=$(find "$BACKUP_DIR/schema" -type f -name "*.gz" 2>/dev/null | wc -l)
    local single_count=$(find "$BACKUP_DIR/single" -type f -name "*.tar.gz" 2>/dev/null | wc -l)
    
    log "INFO" "Backup Counts:"
    log "INFO" "  Snapshot backups: $snapshot_count"
    log "INFO" "  Schema backups: $schema_count"
    log "INFO" "  Single keyspace: $single_count"
    log "INFO" "  TOTAL: $((snapshot_count + schema_count + single_count))"
    
    echo ""
    log "INFO" "Most Recent Backups:"
    local recent=$(find "$BACKUP_DIR" -type f -name "*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -3)
    echo "$recent" | while read -r line; do
        local file=$(echo "$line" | cut -d' ' -f2)
        [ -n "$file" ] && log "INFO" "  $(basename "$file") - $(ls -lh "$file" 2>/dev/null | awk '{print $6, $7, $8}')"
    done
    
    echo ""
    log "INFO" "Cassandra Status:"
    docker exec $CONTAINER_NAME nodetool status 2>/dev/null | head -10
    
    log "INFO" "========================================="
}

list_keyspaces() {
    log "INFO" "========================================="
    log "INFO" "CASSANDRA KEYSPACES"
    log "INFO" "========================================="
    
    check_container || return 1
    
    echo ""
    log "INFO" "User Keyspaces:"
    local keyspaces=$(get_user_keyspaces)
    echo "$keyspaces" | while read -r ks; do
        if [ -n "$ks" ]; then
            local tables=$(docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
                -e "SELECT count(*) FROM system_schema.tables WHERE keyspace_name='$ks';" 2>/dev/null | \
                grep -E "^\s*[0-9]+" | awk '{print $1}')
            log "INFO" "  - $ks (${tables:-0} tables)"
        fi
    done
    
    echo ""
    log "INFO" "System Keyspaces:"
    docker exec $CONTAINER_NAME cqlsh -u $CASSANDRA_USER -p $CASSANDRA_PASS \
        -e "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name LIKE 'system%';" 2>/dev/null | \
        grep "system" | while read -r ks; do
            log "INFO" "  - $ks"
        done
    
    log "INFO" "========================================="
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}  Cassandra Backup Script V1 - PRODUCTION${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "System Configuration:"
    echo "  Cassandra:    v5.0"
    echo "  Container:    $CONTAINER_NAME"
    echo "  Backup Dir:   $BACKUP_DIR"
    echo ""
    echo "✅ Features:"
    echo "  - nodetool snapshot based backup"
    echo "  - Schema backup (CQL)"
    echo "  - All keyspaces backup"
    echo "  - Individual keyspace backup"
    echo "  - Backup verification"
    echo "  - Lock mechanism"
    echo "  - Compression (tar.gz)"
    echo ""
    echo "Usage: $0 {command} [options]"
    echo ""
    echo -e "${BLUE}Backup Commands:${NC}"
    echo "  $0 all                    - Full cluster backup (RECOMMENDED)"
    echo "  $0 schema                 - Backup schema only"
    echo "  $0 keyspace <name>        - Backup single keyspace"
    echo ""
    echo -e "${BLUE}Restore Commands:${NC}"
    echo "  $0 restore <file>         - Restore from backup file"
    echo ""
    echo -e "${BLUE}Maintenance Commands:${NC}"
    echo "  $0 clean [days]           - Clean old backups (default: $RETENTION_DAYS days)"
    echo "  $0 list                   - List available backups"
    echo "  $0 stats                  - Show detailed statistics"
    echo "  $0 verify <file>          - Verify backup integrity"
    echo "  $0 keyspaces              - List all keyspaces"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  $0 all"
    echo "  $0 keyspace my_keyspace"
    echo "  $0 stats"
    echo "  $0 clean 7"
    echo "  $0 restore /opt/cassandra/backups/snapshots/cassandra_full_20250128.tar.gz"
    echo ""
    echo -e "${CYAN}Cron Example (hourly):${NC}"
    echo "  0 * * * * $0 all >> /opt/cassandra/logs/cron.log 2>&1"
    echo ""
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

case "$1" in
    "all"|"full")
        acquire_lock
        backup_cassandra "full"
        ;;
    "schema")
        acquire_lock
        backup_schema "all"
        ;;
    "keyspace")
        acquire_lock
        backup_keyspace "$2"
        ;;
    "restore")
        restore_cassandra "$2"
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
    "keyspaces"|"list-keyspaces")
        list_keyspaces
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