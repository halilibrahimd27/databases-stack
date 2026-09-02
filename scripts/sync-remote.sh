#!/bin/bash
# =============================================================================
# Uzak depoya yedek senkronizasyonu (rclone)
# =============================================================================
# Google Drive, S3, Backblaze, SFTP — rclone'un desteklediği her hedef.
#
# ŞİFRELEME: yedekler .env'de BACKUP_ENCRYPT_KEY tanımlıysa şifreli üretilir
# (*.gz.enc) ve bu betik ŞİFRESİZ (*.gz) dosyaları göndermez. Şifreleme
# kapalıyken gönderim yine yapılır ama her koşumda AÇIKÇA uyarı basılır —
# veritabanı dökümünü şifrelemeden binadan çıkarmak sessizce yapılacak bir iş
# değildir. Ayrıntı: docs/BACKUP.md
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

# =============================================================================
# ŞİFRELEME KAPISI
# =============================================================================
# Bu betiğin varlık sebebi yedekleri BİNADAN ÇIKARMAK; o yüzden "şifreli mi"
# sorusu burada bir ayrıntı değil, ana sorudur. Uzak depo hesabı ele geçen
# biri düz gzip'i `gzip -dc` ile açıp bütün veritabanını okur — üstelik en
# eskisi bile aynı tabloları taşır.
#
# KARARI BURADA YENİDEN HESAPLAMIYORUZ, backup.sh'a SORUYORUZ. Sözleşmenin
# (anahtar nereden okunur, BACKUP_ENCRYPT=false ne demek, dosya uzantısı ne
# olur) tek sahibi o dosya. Buraya ikinci bir kopya yazsaydık, .env'e
# BACKUP_ENCRYPT=false eklendiği gün iki betik farklı düşünür ve bu betik
# "nasılsa şifreli" deyip düz metin gönderirdi — tam olarak engellemeye
# çalıştığımız şey.
#
# Çıkış kodu sözleşmesi (backup.sh sifreleme-durumu):
#   0 AÇIK · 1 yapılandırılmış ama KULLANILAMIYOR · 2 KAPALI
ENC_EXT="enc"
SIFRELEME="bilinmiyor"      # acik | kapali | bozuk | bilinmiyor
SIFRELEME_NOT=""

sifreleme_belirle() {
    local cikti rc
    cikti="$("$STACK_ROOT/scripts/backup.sh" sifreleme-durumu 2>&1)"; rc=$?
    SIFRELEME_NOT="$(printf '%s' "$cikti" | sed -n 's/^sebep *: //p' | head -1)"
    case "$rc" in
        0) SIFRELEME="acik" ;;
        2) SIFRELEME="kapali" ;;
        1) SIFRELEME="bozuk" ;;
        # backup.sh hiç çalışmadıysa (silinmiş, çalıştırma izni yok, bash
        # bulunamadı) cevap "kapalı" DEĞİL "bilinmiyor"dur. Bilmediğimiz
        # durumda dosya göndermek, şifresiz gönderme riskini sessizce almaktır.
        *) SIFRELEME="bilinmiyor"; SIFRELEME_NOT="backup.sh sifreleme-durumu çalışmadı (rc=$rc): $cikti" ;;
    esac
}
sifreleme_belirle

# Gönderilecek dosya deseni. Şifreleme AÇIKKEN yalnız *.gz.enc gider.
# `.bozuk` dosyalar İKİ DURUMDA DA gitmez: onları finalize_backup kenara aldı,
# yani ürün "bu kurtarma noktası değil" dedi. (Eski sürümde yalnız --exclude
# vardı ve include listesi olmadığı için .bozuk dosyalar da uzağa
# kopyalanıyordu; uzakta "yedeğim var" sanılan dosyaların bir kısmı aslında
# reddedilmiş dosyalardı.)
FILTRE=()
filtre_kur() {
    if [ "$SIFRELEME" = "acik" ]; then
        FILTRE=(--include "*.gz.$ENC_EXT")
    else
        FILTRE=(--include '*.gz' --include "*.gz.$ENC_EXT")
    fi
}
filtre_kur

# Kaç dosya gidecek, kaç dosya ATLANACAK? Atlananları saymak şart: sessizce
# atlamak, operatörün uzakta olduğunu sandığı bir kurtarma noktasının aslında
# hiç gitmemesi demektir.
say_gonderilecek() {   # say_gonderilecek <dizin>
    if [ "$SIFRELEME" = "acik" ]; then
        find "$1" -type f -name "*.gz.$ENC_EXT" 2>/dev/null | wc -l
    else
        find "$1" -type f '(' -name '*.gz' -o -name "*.gz.$ENC_EXT" ')' 2>/dev/null | wc -l
    fi
}
say_atlanacak() {      # say_atlanacak <dizin>  → şifreleme açıkken şifresizler
    if [ "$SIFRELEME" = "acik" ]; then
        find "$1" -type f -name '*.gz' 2>/dev/null | wc -l
    else
        printf '0'
    fi
}

# Şifreleme durumunu EKRANA yazan tek yer. Her alt komut bunu çağırıyor:
# "sessizce şifresiz gönderdi" hâli, bu üründe kabul edilebilir bir hâl değil.
sifreleme_bildir() {
    case "$SIFRELEME" in
        acik)
            ok "Yedek şifrelemesi AÇIK — yalnız *.gz.$ENC_EXT gönderilecek"
            log "  $SIFRELEME_NOT" ;;
        kapali)
            warn "Yedek şifrelemesi KAPALI: yedekler uzak depoya ŞİFRELENMEDEN gidiyor."
            warn "  Uzak depo hesabı ele geçen biri dump'ları açıp bütün veriyi okur."
            warn "  Açmak için .env → BACKUP_ENCRYPT_KEY (ayrıntı: docs/BACKUP.md)"
            [ -n "$SIFRELEME_NOT" ] && log "  sebep: $SIFRELEME_NOT" ;;
        bozuk)
            err "Yedek şifrelemesi yapılandırılmış ama KULLANILAMIYOR: ${SIFRELEME_NOT:-?}"
            err "  Bu durumda üretilen yedekler ŞİFRESİZ olabilir; gönderim yapılmayacak." ;;
        *)
            err "Şifreleme durumu ÖĞRENİLEMEDİ: ${SIFRELEME_NOT:-?}"
            err "  Bilmediğimiz bir durumda dosya göndermiyoruz — şifresiz gönderme riski sessizce alınamaz." ;;
    esac
}

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
    local n atlanan
    n="$(say_gonderilecek "$src")"
    atlanan="$(say_atlanacak "$src")"
    # ATLANANLARI DUYURUYORUZ. Şifreleme açıldıktan sonra dizinde kalan eski
    # şifresiz kopyalar bir daha uzağa gitmez; bu doğru davranıştır ama
    # SESSİZ olursa operatör uzakta duran yedek sayısının neden azaldığını
    # anlayamaz ve bunu bir arıza sanır.
    if [ "${atlanan:-0}" -gt 0 ]; then
        warn "  $eid: $atlanan ŞİFRESİZ dosya gönderilmedi (şifreleme açık)"
        slog "  $eid: $atlanan şifresiz dosya atlandı — şifreli kopya için yeniden yedek alın"
    fi
    [ "${n:-0}" -eq 0 ] && return 0

    slog "  $eid → $n dosya ($(du -sh "$src" 2>/dev/null | cut -f1))"
    local attempt=1
    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        [ "$attempt" -gt 1 ] && { warn "  yeniden deneme $attempt/$RETRY_COUNT"; sleep 10; }
        # Dizi olarak kuruluyor: eski sürüm komutu string'e ekleyip `eval`
        # ediyordu; klasör adında tırnak/boşluk olması komutu bozabiliyordu.
        # FİLTRE SIRASI ÖNEMLİ: rclone kuralları komut satırındaki SIRAYLA
        # değerlendirir ve ilk eşleşen kazanır; ayrıca listede bir --include
        # varsa sona örtük bir "- *" eklenir. Önce --exclude'lar, sonra
        # --include'lar: .tmp/.lock/.log elenir, ardından yalnız izin verilen
        # uzantılar geçer, kalan her şey (özellikle .bozuk dosyalar) örtük
        # kuralla düşer.
        local -a cmd=(rclone copy "$src" "$REMOTE/$eid"
                      --transfers "$TRANSFERS" --checkers "$CHECKERS"
                      --fast-list --exclude '*.tmp' --exclude '*.lock' --exclude '*.log'
                      "${FILTRE[@]}"
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

    # ŞİFRELEME KAPISI — gönderimden ÖNCE. "bozuk" ve "bilinmiyor" hâllerinde
    # üretilen dosyaların şifreli olduğunu SÖYLEYEMEYİZ; söyleyemediğimiz bir
    # şeyi uzak depoya göndermek, şifrelemeyi açmış olmanın anlamını yok eder.
    sifreleme_bildir
    case "$SIFRELEME" in
        bozuk|bilinmiyor)
            err "Gönderim yapılmadı. Önce: ./scripts/backup.sh sifreleme"
            return 1 ;;
    esac

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
    printf '  Etkin   : %s\n  Hedef   : %s\n  Saklama : %s gün\n  Kaynak  : %s\n  Şifrele : %s\n\n' \
        "$REMOTE_SYNC_ENABLED" "$REMOTE" "$RETENTION_REMOTE_DAYS" "$BACKUP_DIR" "$SIFRELEME"
    sifreleme_bildir
    check_rclone || return 1
    # YEREL sütunu "gönderilebilir dosya" sayar, dizindeki her .gz'yi değil:
    # şifreleme açıkken şifresiz dosyalar gitmeyecek, onları yerel sayıp uzakla
    # karşılaştırmak her satırda kalıcı bir fark gösterir ve operatöre her gece
    # "senkron tutmuyor" dedirtirdi.
    printf '\n  %-14s %8s  %8s  %9s\n  %s\n' \
        "MOTOR" "YEREL" "UZAK" "ATLANAN" "---------------------------------------------"
    local eid l r a
    for eid in $(engines_with_backup); do
        l="$(say_gonderilecek "$BACKUP_DIR/$eid")"
        a="$(say_atlanacak "$BACKUP_DIR/$eid")"
        r="$(rclone ls "$REMOTE/$eid" 2>/dev/null | wc -l)"
        printf '  %-14s %8s  %8s  %9s\n' "$eid" "$l" "$r" "$a"
    done
    echo
}

# =============================================================================
# PLAN — NE GİDECEK, NE GİTMEYECEK (uzak depoya HİÇ dokunmadan)
# =============================================================================
# NEDEN VAR: "şifresiz dosya göndermiyoruz" bir GÜVENCE. Gözlenemeyen bir
# güvence sınanamaz, sınanamayan güvence de zamanla sessizce bozulur. Bu alt
# komut kararı gönderimden ÖNCE ve rclone olmadan gösterir; scripts/e2e/
# encrypt.sh de tam olarak bunu ölçüyor.
do_plan() {
    heading "Gönderim planı → $REMOTE"
    sifreleme_bildir
    # Durumu BİLMEDİĞİMİZ hâlde tablo basmıyoruz. Basılsaydı
    # "2 gönderilir" yazardı ve okuyan bunu bir PLAN sanırdı; oysa o
    # koşumda gönderim hiç yapılmayacak. Yanlış bir plan, plansızlıktan
    # beterdir.
    case "$SIFRELEME" in
        bozuk|bilinmiyor)
            err "Gönderim yapılmayacak; plan da çıkarılamaz."
            err "  Önce yapılandırmayı düzeltin: ./scripts/backup.sh sifreleme"
            return 1 ;;
    esac
    printf '\n  %-14s %11s %9s\n  %s\n' \
        "MOTOR" "GÖNDERİLİR" "ATLANIR" "-------------------------------------"
    local eid g a f topg=0 topa=0
    for eid in $(engines_with_backup); do
        local src="$BACKUP_DIR/$eid"
        [ -d "$src" ] || continue
        g="$(say_gonderilecek "$src")"; a="$(say_atlanacak "$src")"
        [ "${g:-0}" -eq 0 ] && [ "${a:-0}" -eq 0 ] && continue
        printf '  %-14s %11s %9s\n' "$eid" "$g" "$a"
        topg=$((topg + g)); topa=$((topa + a))
        # Atlanan dosyaları ADIYLA yazıyoruz: sayı "bir şey atlandı" der,
        # ad "HANGİ kurtarma noktası uzağa gitmiyor" der. Felaket planı
        # yapan için ikisi aynı şey değil.
        if [ "${a:-0}" -gt 0 ]; then
            find "$src" -type f -name '*.gz' 2>/dev/null | sort | head -5 \
                | while IFS= read -r f; do
                      printf '      - %s  (ŞİFRESİZ — gönderilmez)\n' "$(basename "$f")"
                  done
            [ "$a" -gt 5 ] && printf '      … ve %s dosya daha\n' "$((a - 5))"
        fi
    done
    printf '\n  Toplam: %d gönderilir, %d atlanır\n' "$topg" "$topa"
    if [ "$topa" -gt 0 ]; then
        printf '  Atlananlar şifreleme açılmadan ÖNCE alınmış kopyalardır; şifreli\n'
        printf '  bir kopya için o motorun yedeğini yeniden alın.\n'
    fi
    echo
    return 0
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
    plan)           do_plan ;;
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
  ./scripts/sync-remote.sh plan     NE gidecek, ne gitmeyecek (uzağa dokunmaz)
  ./scripts/sync-remote.sh test     Bağlantıyı test et
  ./scripts/sync-remote.sh status   Yerel/uzak dosya sayıları
  ./scripts/sync-remote.sh clean    Eski uzak dosyaları sil

ŞİFRELEME: .env'de BACKUP_ENCRYPT_KEY tanımlıysa yalnız *.gz.enc gönderilir;
şifresiz (*.gz) dosyalar gönderilmez. Tanımlı değilse gönderim yapılır ama
her koşumda uyarı basılır. Durum: ./scripts/backup.sh sifreleme

Yapılandırma .env dosyasındadır (REMOTE_SYNC_ENABLED, RCLONE_REMOTE_NAME,
GDRIVE_FOLDER, RETENTION_REMOTE_DAYS). Kurulum: docs/GOOGLE-DRIVE.md

EOF
        exit 1 ;;
esac
