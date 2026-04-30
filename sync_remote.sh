#!/bin/bash

# =============================================================================
# GOOGLE DRIVE BACKUP SYNC V2 - PRODUCTION OPTIMIZED
# Automatically sync database backups to Google Drive
#
# ✅ Lock mechanism (prevents concurrent syncs)
# ✅ Retry on failure
# ✅ Bandwidth limiting (optional)
# ✅ Detailed statistics
# ✅ Sync verification
# =============================================================================

BACKUP_DIR="/opt/databases/backups"
LOG_DIR="/opt/databases/logs"
SYNC_LOG="$LOG_DIR/backup_sync_$(date +%Y%m%d).log"

# Configuration
REMOTE_SYNC_ENABLED="true"      # Enabled for production ✅
RCLONE_REMOTE_NAME="gdrive"     # rclone remote name
GDRIVE_FOLDER="${GDRIVE_FOLDER:-Database Backups}" # Google Drive klasör adı (env override)
RETENTION_REMOTE_DAYS=30         # 15 dk'da bir backup = 7 gün yeterli

# Performance settings
TRANSFERS=4                     # Paralel transfer sayısı
CHECKERS=8                      # Paralel kontrol sayısı
BANDWIDTH_LIMIT=""              # Boş = limitsiz, örn: "10M" = 10MB/s
RETRY_COUNT=3                   # Hata durumunda tekrar deneme
RETRY_SLEEP=10                  # Tekrar denemeler arası bekleme (saniye)

# Lock mechanism
LOCK_FILE="/tmp/sync_remote.lock"
LOCK_TIMEOUT=1800               # 30 dakika timeout

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Create log directory
mkdir -p "$LOG_DIR"

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
                log "ERROR" "Another sync is running (PID: $lock_pid, Age: ${lock_age}s)"
                exit 1
            fi
        else
            log "WARNING" "Orphaned lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    trap cleanup EXIT INT TERM
    log "INFO" "Lock acquired (PID: $$)"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

cleanup() {
    release_lock
    log "INFO" "Lock released"
}

# =============================================================================
# LOGGING
# =============================================================================
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"

    case $level in
        "INFO")
            echo -e "${BLUE}${timestamp} [INFO]${NC} $message" | tee -a "$SYNC_LOG"
            ;;
        "SUCCESS")
            echo -e "${GREEN}${timestamp} [SUCCESS]${NC} $message" | tee -a "$SYNC_LOG"
            ;;
        "WARNING")
            echo -e "${YELLOW}${timestamp} [WARNING]${NC} $message" | tee -a "$SYNC_LOG"
            ;;
        "ERROR")
            echo -e "${RED}${timestamp} [ERROR]${NC} $message" | tee -a "$SYNC_LOG"
            ;;
        "DEBUG")
            echo -e "${CYAN}${timestamp} [DEBUG]${NC} $message" | tee -a "$SYNC_LOG"
            ;;
    esac
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
format_duration() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local secs=$((seconds % 60))
    echo "${minutes}m ${secs}s"
}

format_bytes() {
    local bytes=$1
    if [ $bytes -ge 1073741824 ]; then
        echo "$(echo "scale=2; $bytes / 1073741824" | bc)GB"
    elif [ $bytes -ge 1048576 ]; then
        echo "$(echo "scale=2; $bytes / 1048576" | bc)MB"
    elif [ $bytes -ge 1024 ]; then
        echo "$(echo "scale=2; $bytes / 1024" | bc)KB"
    else
        echo "${bytes}B"
    fi
}

check_rclone() {
    if ! command -v rclone &> /dev/null; then
        log "ERROR" "rclone not installed!"
        log "INFO" "Install: curl https://rclone.org/install.sh | sudo bash"
        return 1
    fi

    if ! rclone listremotes | grep -q "${RCLONE_REMOTE_NAME}:"; then
        log "ERROR" "Google Drive remote '${RCLONE_REMOTE_NAME}' not configured!"
        log "INFO" "Configure: rclone config"
        return 1
    fi

    return 0
}

# =============================================================================
# SYNC FUNCTIONS
# =============================================================================

# Sync specific folder with retry
sync_folder() {
    local folder=$1
    local source_path="$BACKUP_DIR/$folder"
    local dest_path="${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}/$folder"

    if [ ! -d "$source_path" ]; then
        log "WARNING" "Folder not found: $source_path"
        return 1
    fi

    local file_count=$(find "$source_path" -type f \( -name "*.gz" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)

    if [ $file_count -eq 0 ]; then
        log "WARNING" "No backup files in: $folder"
        return 0
    fi

    local folder_size=$(du -sh "$source_path" 2>/dev/null | cut -f1)
    log "INFO" "  → Syncing $folder ($file_count files, $folder_size)..."

    # Build rclone command
    local rclone_cmd="rclone copy '$source_path' '$dest_path'"
    rclone_cmd+=" --transfers $TRANSFERS"
    rclone_cmd+=" --checkers $CHECKERS"
    rclone_cmd+=" --fast-list"
    rclone_cmd+=" --exclude '*.tmp'"
    rclone_cmd+=" --exclude '*.lock'"
    rclone_cmd+=" --exclude '*.log'"
    rclone_cmd+=" --stats 5s"
    rclone_cmd+=" --stats-one-line"
    rclone_cmd+=" --log-file='$SYNC_LOG'"
    rclone_cmd+=" --log-level INFO"

    # Add bandwidth limit if set
    if [ -n "$BANDWIDTH_LIMIT" ]; then
        rclone_cmd+=" --bwlimit $BANDWIDTH_LIMIT"
    fi

    # Retry loop
    local attempt=1
    while [ $attempt -le $RETRY_COUNT ]; do
        if [ $attempt -gt 1 ]; then
            log "WARNING" "  Retry attempt $attempt/$RETRY_COUNT..."
            sleep $RETRY_SLEEP
        fi

        eval $rclone_cmd 2>> "$SYNC_LOG"

        if [ $? -eq 0 ]; then
            log "SUCCESS" "  ✓ $folder synced successfully"
            return 0
        fi

        ((attempt++))
    done

    log "ERROR" "  ✗ Failed to sync $folder after $RETRY_COUNT attempts"
    return 1
}

# Verify sync by comparing file counts
verify_sync() {
    local folder=$1
    local source_path="$BACKUP_DIR/$folder"
    local dest_path="${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}/$folder"

    local local_count=$(find "$source_path" -type f \( -name "*.gz" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)
    local remote_count=$(rclone ls "$dest_path" 2>/dev/null | wc -l)

    if [ "$local_count" -eq "$remote_count" ]; then
        log "SUCCESS" "  ✓ Verified: $folder ($local_count files)"
        return 0
    else
        log "WARNING" "  ⚠ Mismatch: $folder (local: $local_count, remote: $remote_count)"
        return 1
    fi
}

# Main sync function
sync_to_google_drive() {
    log "INFO" "========================================="
    log "INFO" "Starting Google Drive Sync"
    log "INFO" "========================================="

    # Pre-checks
    check_rclone || return 1

    log "SUCCESS" "✓ rclone found and configured"

    # Test connection
    log "INFO" "Testing Google Drive connection..."
    if ! rclone lsd "${RCLONE_REMOTE_NAME}:" &> /dev/null; then
        log "ERROR" "Cannot connect to Google Drive!"
        return 1
    fi
    log "SUCCESS" "✓ Google Drive connection OK"

    # Create remote folder if needed
    log "INFO" "Remote folder: $GDRIVE_FOLDER"
    rclone mkdir "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" 2>/dev/null

    # Statistics
    local synced_count=0
    local failed_count=0
    local start_time=$(date +%s)

    # Sync each database folder
    echo ""
    for db in mariadb postgresql mongodb redis; do
        if sync_folder "$db"; then
            ((synced_count++))
        else
            ((failed_count++))
        fi
    done

    # Cleanup old files on remote
    echo ""
    log "INFO" "Cleaning old files on Google Drive (older than $RETENTION_REMOTE_DAYS days)..."
    rclone delete "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" \
        --min-age ${RETENTION_REMOTE_DAYS}d \
        --rmdirs \
        2>> "$SYNC_LOG"

    if [ $? -eq 0 ]; then
        log "SUCCESS" "✓ Remote cleanup complete"
    else
        log "WARNING" "Remote cleanup had issues (non-critical)"
    fi

    # Verification (optional but recommended)
    echo ""
    log "INFO" "Verifying sync..."
    local verify_ok=0
    local verify_fail=0
    for db in mariadb postgresql mongodb redis; do
        if verify_sync "$db"; then
            ((verify_ok++))
        else
            ((verify_fail++))
        fi
    done

    # Get remote size
    local remote_size=$(rclone size "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" 2>/dev/null | grep "Total size" | awk '{print $3, $4}')

    # Summary
    local duration=$(( $(date +%s) - start_time ))

    echo ""
    log "INFO" "========================================="
    log "INFO" "SYNC SUMMARY"
    log "INFO" "========================================="
    log "INFO" "Duration: $(format_duration $duration)"
    log "SUCCESS" "Synced: $synced_count folders"
    [ $failed_count -gt 0 ] && log "ERROR" "Failed: $failed_count folders" || log "INFO" "Failed: $failed_count folders"
    log "INFO" "Verified: $verify_ok OK, $verify_fail warnings"
    log "INFO" "Remote size: $remote_size"
    log "INFO" "Remote location: ${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}"
    log "INFO" "Retention: $RETENTION_REMOTE_DAYS days"
    log "INFO" "========================================="

    [ $failed_count -eq 0 ] && return 0 || return 1
}

# =============================================================================
# MAIN SYNC
# =============================================================================
sync_backups() {
    acquire_lock

    log "INFO" "========================================="
    log "INFO" "GOOGLE DRIVE BACKUP SYNC V2"
    log "INFO" "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    log "INFO" "========================================="

    if [ "$REMOTE_SYNC_ENABLED" != "true" ]; then
        log "ERROR" "Remote sync is DISABLED!"
        log "INFO" "Enable by setting REMOTE_SYNC_ENABLED='true'"
        return 1
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        log "ERROR" "Backup directory not found: $BACKUP_DIR"
        return 1
    fi

    # Show local backup stats
    local local_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    local local_files=$(find "$BACKUP_DIR" -type f \( -name "*.gz" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)
    log "INFO" "Local backups: $local_files files ($local_size)"

    # Run sync
    sync_to_google_drive
    local sync_result=$?

    echo ""
    if [ $sync_result -eq 0 ]; then
        log "SUCCESS" "========================================="
        log "SUCCESS" "SYNC COMPLETED SUCCESSFULLY ✓"
        log "SUCCESS" "========================================="
    else
        log "ERROR" "========================================="
        log "ERROR" "SYNC COMPLETED WITH ERRORS ✗"
        log "ERROR" "========================================="
    fi

    log "INFO" "Log file: $SYNC_LOG"

    return $sync_result
}

# =============================================================================
# STATUS & STATISTICS
# =============================================================================
show_status() {
    log "INFO" "========================================="
    log "INFO" "SYNC STATUS"
    log "INFO" "========================================="

    # Check rclone
    if ! check_rclone; then
        return 1
    fi

    log "SUCCESS" "✓ rclone configured"

    # Local stats
    local local_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    local local_files=$(find "$BACKUP_DIR" -type f \( -name "*.gz" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)

    log "INFO" ""
    log "INFO" "Local Backups:"
    log "INFO" "  Directory: $BACKUP_DIR"
    log "INFO" "  Files: $local_files"
    log "INFO" "  Size: $local_size"

    # Remote stats
    log "INFO" ""
    log "INFO" "Remote (Google Drive):"
    log "INFO" "  Folder: $GDRIVE_FOLDER"

    local remote_info=$(rclone size "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" 2>/dev/null)
    if [ -n "$remote_info" ]; then
        local remote_count=$(echo "$remote_info" | grep "Total objects" | awk '{print $3}')
        local remote_size=$(echo "$remote_info" | grep "Total size" | awk '{print $3, $4}')
        log "INFO" "  Files: $remote_count"
        log "INFO" "  Size: $remote_size"
    else
        log "WARNING" "  Unable to get remote stats"
    fi

    # Per-database breakdown
    log "INFO" ""
    log "INFO" "Breakdown by Database:"
    for db in mariadb postgresql mongodb redis; do
        local db_local=$(find "$BACKUP_DIR/$db" -type f \( -name "*.gz" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)
        local db_size=$(du -sh "$BACKUP_DIR/$db" 2>/dev/null | cut -f1)
        log "INFO" "  $db: $db_local files ($db_size)"
    done

    # Configuration
    log "INFO" ""
    log "INFO" "Configuration:"
    log "INFO" "  Sync enabled: $REMOTE_SYNC_ENABLED"
    log "INFO" "  Retention: $RETENTION_REMOTE_DAYS days"
    log "INFO" "  Transfers: $TRANSFERS parallel"
    log "INFO" "  Bandwidth: ${BANDWIDTH_LIMIT:-unlimited}"

    log "INFO" "========================================="
}

# =============================================================================
# SETUP INSTRUCTIONS
# =============================================================================
show_setup_instructions() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  🚀 GOOGLE DRIVE BACKUP SYNC V2${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo "STEP 1: Install rclone"
    echo "  curl https://rclone.org/install.sh | sudo bash"
    echo ""
    echo "STEP 2: Configure Google Drive"
    echo "  rclone config"
    echo "  → n (new remote)"
    echo "  → Name: gdrive"
    echo "  → Storage: drive (or type 'drive')"
    echo "  → Leave defaults (press ENTER)"
    echo "  → Auto config: n (No) - for headless server"
    echo "  → Follow instructions to get token"
    echo "  → Confirm: y"
    echo ""
    echo "STEP 3: Test Connection"
    echo "  ./sync_remote.sh test"
    echo ""
    echo "STEP 4: Run First Sync"
    echo "  ./sync_remote.sh"
    echo ""
    echo "STEP 5: Automate with Cron"
    echo "  crontab -e"
    echo "  # Sync 5 minutes after each backup (every 15 min)"
    echo "  5,20,35,50 * * * * /opt/databases/sync_remote.sh >> /opt/databases/logs/cron_sync.log 2>&1"
    echo ""
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}  📊 CURRENT CONFIGURATION${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo "  Sync Enabled:  $REMOTE_SYNC_ENABLED"
    echo "  Remote Name:   $RCLONE_REMOTE_NAME"
    echo "  Remote Folder: $GDRIVE_FOLDER"
    echo "  Retention:     $RETENTION_REMOTE_DAYS days"
    echo "  Backup Dir:    $BACKUP_DIR"
    echo "  Transfers:     $TRANSFERS parallel"
    echo "  Bandwidth:     ${BANDWIDTH_LIMIT:-unlimited}"
    echo ""
    echo -e "${YELLOW}COMMANDS:${NC}"
    echo "  ./sync_remote.sh           - Sync now"
    echo "  ./sync_remote.sh test      - Test connection"
    echo "  ./sync_remote.sh status    - Show statistics"
    echo "  ./sync_remote.sh setup     - This help"
    echo "  ./sync_remote.sh cleanup   - Force cleanup old files"
    echo ""
}

# =============================================================================
# FORCE CLEANUP
# =============================================================================
force_cleanup() {
    acquire_lock

    log "INFO" "========================================="
    log "INFO" "FORCE CLEANUP - Remote Old Files"
    log "INFO" "========================================="

    check_rclone || return 1

    local days=${1:-$RETENTION_REMOTE_DAYS}

    log "INFO" "Removing files older than $days days from Google Drive..."
    log "INFO" "Remote folder: ${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}"

    # Show what will be deleted (dry run)
    log "INFO" ""
    log "INFO" "Files to be deleted:"
    rclone ls "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" --min-age ${days}d 2>/dev/null | head -20

    echo ""
    read -p "Continue with deletion? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log "INFO" "Cleanup cancelled"
        return 1
    fi

    rclone delete "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" \
        --min-age ${days}d \
        --rmdirs \
        --verbose \
        2>&1 | tee -a "$SYNC_LOG"

    if [ $? -eq 0 ]; then
        log "SUCCESS" "✓ Cleanup completed"
    else
        log "ERROR" "✗ Cleanup failed"
        return 1
    fi

    log "INFO" "========================================="
}

# =============================================================================
# TEST CONNECTION
# =============================================================================
test_connection() {
    log "INFO" "========================================="
    log "INFO" "Testing Google Drive Connection"
    log "INFO" "========================================="

    # Check rclone installation
    if ! command -v rclone &> /dev/null; then
        log "ERROR" "rclone not installed!"
        log "INFO" "Install: curl https://rclone.org/install.sh | sudo bash"
        return 1
    fi
    log "SUCCESS" "✓ rclone is installed ($(rclone version | head -1))"

    # Check remote configuration
    if ! rclone listremotes | grep -q "${RCLONE_REMOTE_NAME}:"; then
        log "ERROR" "Remote '${RCLONE_REMOTE_NAME}' not configured!"
        log "INFO" "Configure: rclone config"
        return 1
    fi
    log "SUCCESS" "✓ Remote '${RCLONE_REMOTE_NAME}' is configured"

    # Test connection
    log "INFO" "Testing connection..."
    if rclone lsd "${RCLONE_REMOTE_NAME}:" &> /dev/null; then
        log "SUCCESS" "✓ Connection successful!"
    else
        log "ERROR" "✗ Connection failed!"
        log "INFO" "Check: rclone config reconnect ${RCLONE_REMOTE_NAME}:"
        return 1
    fi

    # Check/create backup folder
    log "INFO" "Checking backup folder..."
    if rclone lsd "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" &> /dev/null; then
        log "SUCCESS" "✓ Folder exists: $GDRIVE_FOLDER"

        # Show folder contents summary
        local remote_info=$(rclone size "${RCLONE_REMOTE_NAME}:/${GDRIVE_FOLDER}" 2>/dev/null)
        local remote_count=$(echo "$remote_info" | grep "Total objects" | awk '{print $3}')
        local remote_size=$(echo "$remote_info" | grep "Total size" | awk '{print $3, $4}')
        log "INFO" "  Files: $remote_count"
        log "INFO" "  Size: $remote_size"
    else
        log "WARNING" "Folder will be created on first sync"
    fi

    echo ""
    log "SUCCESS" "========================================="
    log "SUCCESS" "All checks passed! Ready to sync."
    log "SUCCESS" "========================================="
    log "INFO" "Run './sync_remote.sh' to start syncing"

    return 0
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
case "${1:-sync}" in
    "sync"|"")
        sync_backups
        ;;
    "test")
        test_connection
        ;;
    "status"|"stats")
        show_status
        ;;
    "setup"|"help"|"--help"|"-h")
        show_setup_instructions
        ;;
    "cleanup"|"clean")
        force_cleanup "$2"
        ;;
    *)
        echo "Google Drive Backup Sync V2"
        echo ""
        echo "Usage: $0 {command}"
        echo ""
        echo "Commands:"
        echo "  sync     - Sync backups to Google Drive (default)"
        echo "  test     - Test Google Drive connection"
        echo "  status   - Show sync statistics"
        echo "  setup    - Show setup instructions"
        echo "  cleanup  - Force cleanup old remote files"
        echo ""
        exit 1
        ;;
esac

exit $?