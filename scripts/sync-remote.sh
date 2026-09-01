#!/bin/bash
# =============================================================================
# Uzak depoya yedek senkronizasyonu (rclone)
# =============================================================================
# Google Drive, S3, Backblaze, SFTP — rclone'un desteklediği her hedef.
#
# Bu betik ARTIK .env OKUR. Önceki sürümde BACKUP_DIR, RETENTION_REMOTE_DAYS,
# RCLONE_REMOTE_NAME ve REMOTE_SYNC_ENABLED betiğin içine SABİT yazılıydı;
# .env'de BACKUP_DIR=/mnt/backups tanımlayan biri yedeklerini /mnt'e alıyor,
# bu betik /opt/databases/backups'a bakıp sessizce hiçbir şey göndermiyordu.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
load_env

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
SYNC_LOG="$LOG_DIR/sync_$(date +%Y%m%d).log"
mkdir -p "$LOG_DIR"

REMOTE_SYNC_ENABLED="${REMOTE_SYNC_ENABLED:-false}"
RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-gdrive}"
GDRIVE_FOLDER="${GDRIVE_FOLDER:-Database Backups}"
RETENTION_REMOTE_DAYS="${RETENTION_REMOTE_DAYS:-30}"
TRANSFERS="${RCLONE_TRANSFERS:-4}"
CHECKERS="${RCLONE_CHECKERS:-8}"
BANDWIDTH_LIMIT="${RCLONE_BWLIMIT:-}"
RETRY_COUNT="${RCLONE_RETRIES:-3}"

REMOTE="${RCLONE_REMOTE_NAME}:${GDRIVE_FOLDER}"

slog() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$SYNC_LOG"; }

engines_with_backup() {
    python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if e.get("backup",{}).get("supported")))' "$CATALOG"
}

check_rclone() {
    command -v rclone >/dev/null 2>&1 || {
        err "rclone kurulu değil."
        log "Kurulum: curl https://rclone.org/install.sh | sudo bash"
        return 1
    }
    rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE_NAME}:" || {
        err "'${RCLONE_REMOTE_NAME}' adlı rclone hedefi tanımlı değil."
        log "Tanımlamak için: rclone config   (ayrıntı: docs/GOOGLE-DRIVE.md)"
        return 1
    }
    return 0
}

sync_one() {
    local eid="$1"
    local src="$BACKUP_DIR/$eid"
    [ -d "$src" ] || return 0
    local n; n="$(find "$src" -type f -name '*.gz' 2>/dev/null | wc -l)"
    [ "$n" -eq 0 ] && return 0

    slog "  $eid → $n dosya ($(du -sh "$src" 2>/dev/null | cut -f1))"
    local attempt=1
    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        [ "$attempt" -gt 1 ] && { warn "  yeniden deneme $attempt/$RETRY_COUNT"; sleep 10; }
        # Dizi olarak kuruluyor: eski sürüm komutu string'e ekleyip `eval`
        # ediyordu; klasör adında tırnak/boşluk olması komutu bozabiliyordu.
        local -a cmd=(rclone copy "$src" "$REMOTE/$eid"
                      --transfers "$TRANSFERS" --checkers "$CHECKERS"
                      --fast-list --exclude '*.tmp' --exclude '*.lock' --exclude '*.log'
                      --stats 30s --stats-one-line
                      --log-file "$SYNC_LOG" --log-level INFO)
        [ -n "$BANDWIDTH_LIMIT" ] && cmd+=(--bwlimit "$BANDWIDTH_LIMIT")
        if "${cmd[@]}"; then
            slog "  ✓ $eid gönderildi"
            return 0
        fi
        attempt=$((attempt+1))
    done
    slog "  ✗ $eid gönderilemedi ($RETRY_COUNT denemede)"
    return 1
}

do_sync() {
    acquire_lock /tmp/databases-stack-sync.lock

    if [ "$REMOTE_SYNC_ENABLED" != "true" ]; then
        err "Uzak senkronizasyon kapalı."
        log "Açmak için .env içinde: REMOTE_SYNC_ENABLED=true"
        return 1
    fi
    [ -d "$BACKUP_DIR" ] || die "Yedek dizini yok: $BACKUP_DIR"
    check_rclone || return 1

    heading "Uzak senkronizasyon → $REMOTE"
    slog "Kaynak: $BACKUP_DIR"
    rclone lsd "${RCLONE_REMOTE_NAME}:" >/dev/null 2>&1 || die "Hedefe bağlanılamıyor: $RCLONE_REMOTE_NAME"
    rclone mkdir "$REMOTE" 2>/dev/null

    local start; start="$(date +%s)"
    local okc=0 failc=0 eid
    for eid in $(engines_with_backup); do
        if sync_one "$eid"; then okc=$((okc+1)); else failc=$((failc+1)); fi
    done

    slog "Uzakta $RETENTION_REMOTE_DAYS günden eski dosyalar siliniyor…"
    rclone delete "$REMOTE" --min-age "${RETENTION_REMOTE_DAYS}d" --rmdirs \
        --log-file "$SYNC_LOG" 2>/dev/null || warn "Uzak temizlik kısmen başarısız (kritik değil)"

    local dur=$(( $(date +%s) - start ))
    heading "Özet"
    printf '  Gönderilen : %d motor\n  Başarısız  : %d\n  Süre       : %dm %ds\n' \
        "$okc" "$failc" $((dur/60)) $((dur%60))
    printf '  Uzak boyut : %s\n' "$(rclone size "$REMOTE" 2>/dev/null | awk '/Total size/{print $3,$4}')"
    printf '  Log        : %s\n\n' "$SYNC_LOG"
    [ "$failc" -eq 0 ]
}

do_status() {
    heading "Senkronizasyon durumu"
    printf '  Etkin   : %s\n  Hedef   : %s\n  Saklama : %s gün\n  Kaynak  : %s\n\n' \
        "$REMOTE_SYNC_ENABLED" "$REMOTE" "$RETENTION_REMOTE_DAYS" "$BACKUP_DIR"
    check_rclone || return 1
    printf '  %-14s %8s  %8s\n  %s\n' "MOTOR" "YEREL" "UZAK" "----------------------------------"
    local eid l r
    for eid in $(engines_with_backup); do
        l="$(find "$BACKUP_DIR/$eid" -type f -name '*.gz' 2>/dev/null | wc -l)"
        r="$(rclone ls "$REMOTE/$eid" 2>/dev/null | wc -l)"
        printf '  %-14s %8s  %8s\n' "$eid" "$l" "$r"
    done
    echo
}

do_test() {
    heading "Bağlantı testi"
    check_rclone || return 1
    ok "rclone $(rclone version 2>/dev/null | head -1 | awk '{print $2}')"
    rclone lsd "${RCLONE_REMOTE_NAME}:" >/dev/null 2>&1 \
        && ok "'${RCLONE_REMOTE_NAME}' hedefine bağlanıldı" \
        || { err "Bağlanılamadı. Deneyin: rclone config reconnect ${RCLONE_REMOTE_NAME}:"; return 1; }
    rclone lsd "$REMOTE" >/dev/null 2>&1 \
        && ok "Klasör mevcut: $GDRIVE_FOLDER" \
        || log "Klasör ilk senkronizasyonda oluşturulacak"
    ok "Her şey hazır — ./scripts/sync-remote.sh ile gönderebilirsiniz"
}

case "${1:-sync}" in
    sync|"")        do_sync ;;
    status|stats)   do_status ;;
    test)           do_test ;;
    clean)
        check_rclone || exit 1
        d="${2:-$RETENTION_REMOTE_DAYS}"
        warn "Uzakta $d günden eski dosyalar silinecek: $REMOTE"
        rclone ls "$REMOTE" --min-age "${d}d" 2>/dev/null | head -20
        printf "Devam etmek için 'evet' yazın: "; read -r a
        [ "$a" = "evet" ] || exit 0
        rclone delete "$REMOTE" --min-age "${d}d" --rmdirs --verbose | tee -a "$SYNC_LOG"
        ;;
    *)
cat <<EOF

Uzak yedek senkronizasyonu

  ./scripts/sync-remote.sh          Şimdi gönder
  ./scripts/sync-remote.sh test     Bağlantıyı test et
  ./scripts/sync-remote.sh status   Yerel/uzak dosya sayıları
  ./scripts/sync-remote.sh clean    Eski uzak dosyaları sil

Yapılandırma .env dosyasındadır (REMOTE_SYNC_ENABLED, RCLONE_REMOTE_NAME,
GDRIVE_FOLDER, RETENTION_REMOTE_DAYS). Kurulum: docs/GOOGLE-DRIVE.md

EOF
        exit 1 ;;
esac
