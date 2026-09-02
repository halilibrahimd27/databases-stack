#!/bin/bash
# =============================================================================
# databases-stack — ZAMANDA BİR ANA DÖNME (point-in-time recovery)
# =============================================================================
#   ./scripts/pitr.sh durum [motor] [--json]
#   ./scripts/pitr.sh kur   <motor>
#   ./scripts/pitr.sh taban <motor>
#   ./scripts/pitr.sh arsivle <motor>
#   ./scripts/pitr.sh don   <motor> "<zaman>" [--prova] [--dogrula "<SQL>"]
#   ./scripts/pitr.sh temizle [gün]
#
# NEDEN VAR:
# backup.sh günde bir tam yedek alır; onunla yapılabilecek en iyi şey "dünkü
# yedeğe dön"dür. Oysa istenen neredeyse hiçbir zaman bu değildir: veriyi
# bozan UPDATE dün 14:33'te koştuysa 14:32'ye dönmek gerekir. Aradaki fark bir
# günlük iştir. Tam yedek + o andan SONRAKİ değişiklik günlüğü (PostgreSQL'de
# WAL, MariaDB'de binlog) bu farkı kapatır.
#
# KAPSAM — ve neden yalnızca iki motor:
#   postgresql  archive_mode ile WAL arşivleniyor (docker-compose.yml)
#   mariadb     binlog zaten AÇIK (config/mariadb/my.cnf)
# Diğerlerinde PITR DESTEKLENMİYOR. MongoDB'de oplog ile teknik olarak
# MÜMKÜNDÜR (replica set şart, oplog penceresi kadar geriye) ama bu turda
# YAPILMADI — "yapılabilir" ile "yapıldı, ölçüldü" arasındaki farkı
# gizlememek için burada açıkça yazıyoruz.
#
# GERİ DÖNÜŞ VERİ SİLER. Üç kapı var, üçü de bilerek:
#   1. --prova : üretime HİÇ dokunmadan, tek kullanımlık bir container ve
#      hacimde aynı kurtarmayı yapar (restore-drill.sh deseni). İstenen ana
#      gerçekten dönülebildiğini görmeden üretimde denemek için sebep yok.
#   2. Üretimde çalışırken ÖNCE güvenlik yedeği alınır. Yanlış ana dönmek de
#      bir arızadır ve geri alınabilmelidir.
#   3. Hedef zaman dönülebilir aralığın DIŞINDAYSA reddedilir ve NEDEN
#      reddedildiği (aralık nedir, sınırını ne belirliyor) yazılır. Sessizce
#      "en yakın ana" dönmek, kullanıcıya olmayan bir veriyi var sanmasını
#      öğretirdi.
#
# ÇIKIŞ KODLARI (kapsam dışı, ret ve hata birbirine KARIŞMASIN diye ayrı):
#   0  iş tamam
#   1  BAŞARISIZ — iş denendi, olmadı
#   2  REDDEDİLDİ — hedef aralık dışında ya da onay verilmedi.
#      YIKICI HİÇBİR İŞ YAPILMADI; bu kod "veriniz yerinde" demektir.
#   3  KAPSAM DIŞI ya da ÖLÇÜLEMEDİ — motor PITR desteklemiyor, docker yok,
#      kilit başkasında… İş hiç DENENEMEDİ; "başarısız" ile aynı şey değil.
#   4  iş bitti ama geçici container/hacim SIZDI (temizlik yapılamadı)
#
# `don` ve `durum --json` SON SATIRDA TEK SATIR JSON basar (controller okur).
# Ayrıntı: docs/PITR.md
# =============================================================================
# `set -e` BİLEREK YOK: her adımın hatası kendi cümlesiyle raporlanmalı.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3
source scripts/lib/common.sh
load_env

# python3'ün Türkçe çıktısı yerel ayardan bağımsız olsun — failover e2e'sinde
# bozuk karakterler eşleşmeleri düşürmüştü.
export PYTHONIOENCODING=utf-8

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
LOG_FILE="$LOG_DIR/pitr_$(date +%Y%m%d).log"
mkdir -p "$LOG_DIR"

# Arşiv ve taban dizinleri YEDEKLERİN ALTINDA. Ayrı bir kök seçseydik
# (/var/lib/… gibi) iki şey bozulurdu: backup.sh'ın `stats` disk uyarısı
# arşivi saymazdı ve sync-remote.sh uzağa yalnız yedekleri gönderirdi — yani
# felaket günü tam yedek uzakta, PITR arşivi ölen sunucuda kalırdı.
WAL_DIR="$BACKUP_DIR/postgresql/wal"
PG_TABAN_DIR="$BACKUP_DIR/postgresql/taban"
BINLOG_DIR="$BACKUP_DIR/mariadb/binlog"
MY_TABAN_DIR="$BACKUP_DIR/mariadb/taban"

RETENTION_DAYS="${RETENTION_DAYS:-7}"
# Varsayılanı RETENTION_DAYS: arşiv yedeklerle AYNI politikaya tabi olmazsa
# disk sessizce dolar. Ayrı bir sayı vermek isteyen .env'e yazar, ama `durum`
# ikisi ayrıştığında bunu UYARI olarak gösterir.
PITR_RETENTION_DAYS="${PITR_RETENTION_DAYS:-$RETENTION_DAYS}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"

ETIKET="dbstack-pitr"
KILIT="$STACK_ROOT/state/backup.lock"
DATE="$(date +%Y%m%d_%H%M%S)"

# Kurtarma sonrası hangi zaman çizgisi izlenecek. 'latest' PostgreSQL 12+
# varsayılanıdır ve ÜST ÜSTE PITR yapılabilmesi için gerekli: bir kez üretimde
# döndükten sonra arşivde ikinci bir zaman çizgisi oluşur; 'current' yazsaydık
# sonraki kurtarma o çizgiyi hiç görmez ve "o ana dönülemiyor" derdi.
PITR_ZAMAN_CIZGISI="${PITR_ZAMAN_CIZGISI:-latest}"

# WAL arşivinde koruma tamponu: en eski SAKLANAN tabandan bu kadar saniye
# öncesine kadarki segmentler de silinmez. Taban dosyasının mtime'ı yedeğin
# BİTİŞİDİR, ihtiyaç duyulan WAL ise BAŞLANGICINDAN itibarendir; aradaki fark
# büyük bir veritabanında saatlerdir.
PITR_KORUMA_TAMPON="${PITR_KORUMA_TAMPON:-14400}"

# ---------------------------------------------------------------- günlük ---
plog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
pok()  { ok  "$*"; printf '[%s] [OK] %s\n'  "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
perr() { err "$*"; printf '[%s] [ERR] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# ------------------------------------------------------------ zaman aşımı ---
# Hiçbir bekleme sonsuz değil: askıda kalmış bir kurtarma hem "sürüyor"
# görünür hem de yedekleme kilidini tutup gece yedeğini öldürür.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman() { local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi; }

SURE_SORGU="${PITR_SORGU_SURESI:-300}"
SURE_TABAN="${PITR_TABAN_SURESI:-7200}"
SURE_KURTARMA="${PITR_KURTARMA_SURESI:-1800}"
SURE_YUKLEME="${PITR_YUKLEME_SURESI:-3600}"

# Geçici kopyanın bellek tavanı: restore-drill.sh ile aynı gerekçe — prova
# üretimle AYNI host'ta ikinci bir veritabanı açar, sınırsız bırakılırsa
# üretimin belleğini yer (backup.sh'ın başındaki OOM olayı).
PROVA_MEM_MB="${PROVA_MEM_MB:-1024}"
PROVA_CPU_SHARES="${PROVA_CPU_SHARES:-512}"

# ------------------------------------------------------------- JSON çıktı ---
js() {
    local s="${1:-}"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
    printf '"%s"' "$s"
}
jnum() { case "${1:-}" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

# =============================================================================
# ZAMAN
# =============================================================================
# `date -d` GNU'ya özgüdür. Yokluğunu SESSİZ geçemeyiz: hedef zamanı
# ayrıştıramayan bir PITR yanlış ana dönmekten iyi değildir — hiç dönmemeli.
zaman_epoch() {   # "2026-09-01 14:32" → epoch
    local e
    e="$(date -d "$1" +%s 2>/dev/null)" || return 1
    case "$e" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$e"
}
epoch_yaz() { date -d "@$1" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null; }
epoch_iso() { date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z'  2>/dev/null; }
# PostgreSQL'e SAAT DİLİMİ AÇIKÇA verilir. recovery_target_time dilimsiz
# yazılırsa sunucunun TimeZone ayarına göre yorumlanır; container UTC, host
# Europe/Istanbul olduğunda bu sessizce ÜÇ SAATLİK bir kayma demektir ve
# geri gelen veri "yaklaşık doğru" göründüğü için kimse fark etmez.
epoch_pg()  { date -d "@$1" '+%Y-%m-%d %H:%M:%S%z'  2>/dev/null; }
# MariaDB tarafında dilim UTC'ye sabitleniyor (mariadb-binlog TZ=UTC ile
# çağrılıyor); aynı kaymanın binlog süzmesinde çıkmaması için.
epoch_utc() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }

sayi_mi() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# =============================================================================
# DOSYA / BOYUT
# =============================================================================
bayt_dizin() {
    [ -d "$1" ] || { printf '0'; return 0; }
    local b; b="$(du -sb "$1" 2>/dev/null | cut -f1)"
    if sayi_mi "$b"; then printf '%s' "$b"; else printf '0'; fi
}
insan() {   # bayt → okunur
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{
        split("B KB MB GB TB", a, " "); i=1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        printf "%.1f %s", b, a[i] }'
}
# Değiştirilme zamanı (epoch). `stat -c` GNU; yoksa find ile.
mtime() {
    local m
    m="$(stat -c %Y "$1" 2>/dev/null)" \
        || m="$(find "$1" -maxdepth 0 -printf '%T@\n' 2>/dev/null | cut -d. -f1)"
    if sayi_mi "$m"; then printf '%s' "$m"; else return 1; fi
}

# meta dosyaları anahtar=değer biçiminde. Kabuk `source` ETMİYORUZ: meta bir
# VERİ dosyasıdır, içine düşen bir satır kabukta kod olarak çalışmamalı
# (common.sh'ın .env'i satır satır okumasıyla aynı gerekçe).
meta_oku() {   # meta_oku <dosya> <anahtar>
    local f="$1" k="$2" satir
    [ -f "$f" ] || return 1
    while IFS= read -r satir || [ -n "$satir" ]; do
        satir="${satir%$'\r'}"
        case "$satir" in "$k"=*) printf '%s' "${satir#*=}"; return 0 ;; esac
    done < "$f"
    return 1
}

# =============================================================================
# KAPSAM
# =============================================================================
pitr_motorlari() { printf 'postgresql\nmariadb\n'; }

pitr_destekli() {
    case "$1" in postgresql|mariadb) return 0 ;; *) return 1 ;; esac
}

# Desteklenmeyen motorda NEDEN desteklenmediğini söylüyoruz. "PITR
# desteklenmiyor" tek başına, kullanıcıya bunun bir eksiklik mi yoksa o
# motorun doğası mı olduğunu bırakmaz.
kapsam_notu() {
    case "$1" in
        mongodb)
            printf '%s' "oplog ile teknik olarak mümkün (replica set şart, oplog penceresi kadar geriye) ama BU TURDA YAPILMADI — kapsam dışı" ;;
        redis)
            printf '%s' "AOF yalnız komut akışıdır, olaylarda zaman damgası yoktur; \"14:32'ye dön\" ifade edilemez" ;;
        mssql)
            printf '%s' "işlem günlüğü yedeği (LOG backup) gerekir; bu yığın yalnız FULL yedek alıyor" ;;
        *)
            printf '%s' "bu motorda zaman damgalı bir değişiklik günlüğü yığında tutulmuyor" ;;
    esac
}

# =============================================================================
# ORTAM
# =============================================================================
# İmaj etiketi SABİT YAZILMAZ; önce ÜRETİMDE ŞU AN KOŞAN imaj sorulur.
# Kurtarma o sürümün veri dizinini açacak: PostgreSQL'in taban yedeği
# FİZİKSEL bir kopyadır ve farklı bir ana sürümle AÇILMAZ ("database files
# are incompatible with server"). Yanlış imajla açılan bir kurtarma, suçu
# yedeğe atan bir hata mesajı üretir.
motor_imaji() {
    local eid="$1" C img
    C="$(primary_of "$eid")"
    img="$(docker inspect "$C" --format '{{.Config.Image}}' 2>/dev/null)"
    if [ -n "$img" ]; then printf '%s' "$img"; return 0; fi
    case "$eid" in
        postgresql) printf '%s' "${POSTGRES_IMAGE:-postgres:${POSTGRES_VERSION:-16}}" ;;
        mariadb)    printf '%s' "${MARIADB_IMAGE:-mariadb:${MARIADB_VERSION:-11.4}}" ;;
        *)          return 1 ;;
    esac
}

motor_parolasi() {
    case "$1" in
        postgresql) printf '%s' "${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}" ;;
        mariadb)    printf '%s' "${MARIADB_PASSWORD:-${DB_PASSWORD:-}}" ;;
        *)          return 1 ;;
    esac
}

# Motorun veri dizini hangi hacimde? Adı `<proje>_<motor>_data` diye tahmin
# ETMİYORUZ: STACK_PROJECT değiştirilebilir ve var olan bir kurulumdan geçen
# yığında install.sh eski proje adını koruyor. Yanlış hacme yazmak, üretim
# verisini bir yerde bırakıp boş bir kopyayı üretim sanmak demek.
uretim_hacmi() {   # uretim_hacmi <container> <hedef yol>
    docker inspect "$1" --format \
        "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" \
        2>/dev/null | tr -d '\r'
}

# Container'da belirli bir bağlama noktası var mı? Compose'a PITR ayarları
# eklendikten SONRA container yeniden yaratılmadıysa /wal-archive yoktur ve
# restore_command hiçbir segmenti bulamaz. Bunu kurtarmanın ORTASINDA
# öğrenmek, üretim veri dizini çoktan silinmişken öğrenmektir.
baglama_var() {   # baglama_var <container> <hedef yol>
    docker inspect "$1" --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' \
        2>/dev/null | tr -d '\r' | grep -qx "$2"
}

# =============================================================================
# İSTEMCİLER
# =============================================================================
# Host'ta veritabanı istemcisi yok; her sorgu container'ın içinden koşar.
# Parola komut satırına DEĞİL ortama konur (host'ta `ps` çıktısında
# görünmesin) — backup.sh ve restore-drill.sh'taki desenin aynısı.
pg_sorgu() {   # pg_sorgu <container> <veritabanı> <sql>
    ( export PGPASSWORD="$(motor_parolasi postgresql)"
      zaman "$SURE_SORGU" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$2" -tAq -c "$3" ) \
      2>>"$LOG_FILE"
}
my_sorgu() {   # my_sorgu <container> <sql>
    ( export MYSQL_PWD="$(motor_parolasi mariadb)"
      zaman "$SURE_SORGU" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$2" ) 2>>"$LOG_FILE"
}
tek_satir() { printf '%s' "${1:-}" | tr -d '\r' | grep -v '^$' | head -1; }

# =============================================================================
# POSTGRESQL — WAL ARŞİVİ
# =============================================================================
# Arşivleme AÇIK MI: compose'daki değişkene DEĞİL, çalışan sunucuya soruyoruz.
# archive_mode yeniden başlatma ister; compose'da 'on' yazması, container o
# satırla yeniden yaratılmadıysa hiçbir şey ifade etmez. Yığında bu tam olarak
# beklenen hâl: ayar eklendi, `docker compose up -d` henüz koşmadı.
pg_arsiv_durumu() {   # <container> → "acik|kapali|bilinmiyor"
    local v
    v="$(tek_satir "$(pg_sorgu "$1" postgres 'SHOW archive_mode')")"
    case "$v" in
        on|always) printf 'acik' ;;
        off)       printf 'kapali' ;;
        *)         printf 'bilinmiyor' ;;
    esac
}

# Segment boyutu sabit varsayılmıyor: 16 MB varsayılan ama initdb ile
# değiştirilebilir ve boşluk hesabı doğrudan buna dayanıyor. Okunamazsa 16 MB
# kabul ediyoruz (o zaman boşluk raporunu "kesin" diye sunmuyoruz).
pg_segment_boyut() {   # <container> → bayt
    local v
    v="$(tek_satir "$(pg_sorgu "$1" postgres \
        'SELECT setting::bigint FROM pg_settings WHERE name = $$wal_segment_size$$')")"
    if sayi_mi "$v" && [ "$v" -gt 0 ]; then printf '%s' "$v"; else printf '16777216'; fi
}

# WAL segment adı 24 hex karakterdir: 8 zaman çizgisi + 8 log kimliği + 8 sıra.
# Sıra numarası her log kimliğinde 0'dan başlar, o yüzden düz bir sayıya
# çevirmek için "log kimliği başına kaç segment var" bilgisi gerekiyor:
# 2^32 / segment_boyutu (16 MB'ta 256). Bunu bilmeden ardışıklık ölçülemez ve
# arşivdeki BOŞLUK görülemez — boşluk ise "aralığın içindeyim" sanan bir
# kurtarmanın sessizce erken durması demek.
wal_sira() {   # wal_sira <segment adı> <segment/logid>
    local ad="$1" spl="$2"
    [ "${#ad}" -eq 24 ] || return 1
    local l="${ad:8:8}" s="${ad:16:8}"
    case "$l$s" in *[!0-9A-Fa-f]*) return 1 ;; esac
    printf '%s' "$(( 16#$l * spl + 16#$s ))"
}

pg_arsiv_segmentleri() {
    [ -d "$WAL_DIR" ] || return 0
    find "$WAL_DIR" -maxdepth 1 -type f -regextype posix-extended \
        -regex '.*/[0-9A-F]{24}' -printf '%f\n' 2>/dev/null | sort
}

# Arşivdeki ardışıklık boşluklarını sayar ve İLK boşluğun hemen öncesindeki
# segmenti bildirir. Zaman çizgileri AYRI AYRI değerlendirilir: yeni bir
# çizgi her zaman farklı bir sıra numarasından başlayabilir ve iki çizgiyi
# yan yana koyup "boşluk var" demek her PITR'dan sonra yanlış alarm üretirdi.
pg_arsiv_boslugu() {   # <segment/logid> → "sayı<TAB>son_saglam_segment"
    local spl="$1" seg onceki_tl="" onceki_no="" onceki_seg=""
    local no tl bosluk=0 son=""
    while IFS= read -r seg; do
        [ -n "$seg" ] || continue
        tl="${seg:0:8}"
        no="$(wal_sira "$seg" "$spl")" || continue
        if [ "$tl" = "$onceki_tl" ] && [ -n "$onceki_no" ]; then
            if [ "$no" -ne $(( onceki_no + 1 )) ]; then
                bosluk=$(( bosluk + 1 ))
                [ -z "$son" ] && son="$onceki_seg"
            fi
        fi
        onceki_tl="$tl"; onceki_no="$no"; onceki_seg="$seg"
    done <<< "$(pg_arsiv_segmentleri)"
    printf '%s\t%s' "$bosluk" "$son"
}

# ---------------------------------------------------------------- tabanlar --
# PITR'ın tabanı FİZİKSEL bir kopyadır (pg_basebackup). backup.sh'ın
# pg_dumpall çıktısı bu iş için KULLANILAMAZ ve bu, PITR'daki en pahalı
# yanılgıdır: mantıksal dump SQL cümleleridir, WAL ise blok düzeyi
# değişikliklerdir. Dump'ın üzerine WAL oynatılamaz — LSN'leri, blok
# düzenleri, dosya düğümleri tutmaz. Bu yüzden PITR'ın kendi tabanı var.
pg_tabanlar() {   # her satır: "<bitis_epoch>\t<dosya>"
    local f m e
    [ -d "$PG_TABAN_DIR" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -s "$f" ] || continue
        e="$(meta_oku "$f.meta" bitis_epoch)" || e=""
        if ! sayi_mi "$e"; then
            # meta yoksa dosyanın kendi zamanı: eksik bir sayıyla çalışmak,
            # elde duran bir tabanı yok saymaktan iyi. Ama meta'sız taban
            # `durum` çıktısında ayrıca işaretleniyor.
            m="$(mtime "$f")" || continue
            e="$m"
        fi
        printf '%s\t%s\n' "$e" "$f"
    done <<< "$(find "$PG_TABAN_DIR" -maxdepth 1 -type f -name '*.tar.gz' \
                 ! -name '*.bozuk' 2>/dev/null)" | sort -n
}

# Taban arşivi GERÇEKTEN bir veri dizini mi? backup.sh'ın verify_backup'ındaki
# ders: boş bir dizinin tar.gz'si de "bozuk değil"dir. Bir PostgreSQL veri
# dizininin olmazsa olmazı PG_VERSION'dır; o yoksa elimizdeki şey ne olursa
# olsun taban değildir. gzip ve tar çıkış kodları da alınıyor — kesik bir
# arşiv sonuna kadar okunmadan "sağlam" sayılamaz.
pg_taban_dogrula() {
    local f="$1" say rc
    say="$(gzip -dc "$f" 2>>"$LOG_FILE" | tar -tf - 2>>"$LOG_FILE" \
           | grep -cx 'PG_VERSION'
           ps=("${PIPESTATUS[@]}")
           [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ]; exit $?)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        perr "Taban arşivi sonuna kadar okunamadı (kesik ya da bozuk): $(basename "$f")"
        return 1
    fi
    if ! sayi_mi "$say" || [ "$say" -lt 1 ]; then
        perr "Taban arşivinde PG_VERSION yok: $(basename "$f") — bu bir PostgreSQL veri dizini değil."
        return 1
    fi
    return 0
}

pg_taban_al() {
    local C f meta bas_epoch bit_epoch bas_wal bit_wal tl segb
    C="$(primary_of postgresql)"
    container_running "$C" || {
        perr "postgresql çalışmıyor ($C) — taban yedeği canlı sunucudan alınır."
        return 1
    }
    mkdir -p "$PG_TABAN_DIR" || { perr "Dizin açılamadı: $PG_TABAN_DIR"; return 1; }
    f="$PG_TABAN_DIR/postgresql_taban_$DATE.tar.gz"
    meta="$f.meta"

    segb="$(pg_segment_boyut "$C")"
    bas_wal="$(tek_satir "$(pg_sorgu "$C" postgres \
        'SELECT pg_walfile_name(pg_current_wal_lsn())')")"
    bas_epoch="$(date +%s)"
    plog "PostgreSQL PITR tabanı alınıyor (pg_basebackup) → $(basename "$f")"

    # -Ft -z -D -  : arşiv tek bir akış olarak stdout'a; container içinde
    #   geçici dosya BIRAKMIYORUZ (veri hacmini yedeğin kendisiyle
    #   doldurmak, dolu bir diskte kurtarmayı imkânsız kılar).
    # -X fetch     : kopyanın tutarlı olması için gereken WAL arşivin
    #   İÇİNE konur. 'stream' kullanılamıyor — o ikinci bir tar üretir ve
    #   `-D -` ile birleşmez. 'none' ise tabanı tek başına AÇILAMAZ hâle
    #   getirirdi: kurtarma o WAL'ı arşivden bulmak zorunda kalırdı ve
    #   arşivin ilk segmenti eksikse taban da çöp olurdu.
    # --checkpoint=fast : yoksa PostgreSQL sıradaki zamanlanmış checkpoint'i
    #   bekler; boş bir sunucuda bu dakikalarca "hiçbir şey olmuyor" demek.
    ( export PGPASSWORD="$(motor_parolasi postgresql)"
      zaman "$SURE_TABAN" docker exec -e PGPASSWORD "$C" \
          pg_basebackup -U "${POSTGRES_USER:-root}" -h 127.0.0.1 \
              -Ft -z -X fetch -D - --checkpoint=fast \
              --label="dbstack-pitr-$DATE" ) 2>>"$LOG_FILE" > "$f"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        perr "pg_basebackup başarısız (çıkış $rc). Ayrıntı: $LOG_FILE"
        rm -f "$f"
        return 1
    fi

    bit_epoch="$(date +%s)"
    bit_wal="$(tek_satir "$(pg_sorgu "$C" postgres \
        'SELECT pg_walfile_name(pg_current_wal_lsn())')")"
    tl="$(tek_satir "$(pg_sorgu "$C" postgres \
        'SELECT timeline_id FROM pg_control_checkpoint()')")"

    pg_taban_dogrula "$f" || {
        # backup.sh'ın finalize_backup deseni: doğrulamayı geçemeyen dosyayı
        # SİLMİYORUZ, kenara alıyoruz. İncelenebilir kalsın ama `pg_tabanlar`
        # onu kurtarma noktası saymasın.
        mv -f "$f" "$f.bozuk" 2>/dev/null && perr "Kenara alındı: $(basename "$f").bozuk"
        return 1
    }

    {
        printf 'motor=postgresql\n'
        printf 'alindi=%s\n'          "$(epoch_iso "$bit_epoch")"
        printf 'baslangic_epoch=%s\n' "$bas_epoch"
        printf 'bitis_epoch=%s\n'     "$bit_epoch"
        printf 'baslangic_wal=%s\n'   "$bas_wal"
        printf 'bitis_wal=%s\n'       "$bit_wal"
        printf 'zaman_cizgisi=%s\n'   "$tl"
        printf 'segment_boyut=%s\n'   "$segb"
        printf 'imaj=%s\n'            "$(motor_imaji postgresql)"
    } > "$meta"

    pok "PITR tabanı hazır: $(basename "$f") ($(insan "$(stat -c %s "$f" 2>/dev/null || echo 0)"), $(( bit_epoch - bas_epoch )) sn)"
    plog "  bu tabandan İLERİ gidebilmek için arşivde $bit_wal ve sonrası gerekli"
    return 0
}

# ----------------------------------------------------------------- pencere --
# DÖNÜLEBİLİR ARALIK NASIL HESAPLANIYOR (postgresql):
#   EN ESKİ = en eski taban yedeğinin BİTTİĞİ an. Ondan öncesine dönmek
#     imkânsızdır — WAL bir tabanın üzerine oynatılır, tek başına veri değil.
#   EN YENİ = arşive DÜŞMÜŞ son segmentin arşivlenme anı. Sunucuda o andan
#     sonra üretilmiş WAL da var ama o henüz pg_wal'da; ölen bir sunucuda
#     ona ulaşılamaz, dolayısıyla "dönülebilir" saymak yalan olur.
#   Arşivde BOŞLUK varsa EN YENİ, boşluktan önceki son segmentin zamanına
#     çekilir: boşluğun ötesine geçen bir kurtarma istenen ana ULAŞMADAN
#     durur ve bunu ancak sonradan fark edersiniz.
# Çıktı: "<en_eski>\t<en_yeni>\t<taban_sayisi>\t<bosluk>\t<aciklama>"
# Aralık yoksa en_eski/en_yeni boş döner.
pg_pencere() {
    local C="$1" spl segb en_eski="" en_yeni="" taban_n=0 bosluk=0 son_saglam=""
    local satir m aciklama=""

    while IFS= read -r satir; do
        [ -n "$satir" ] || continue
        taban_n=$(( taban_n + 1 ))
        [ -z "$en_eski" ] && en_eski="${satir%%$'\t'*}"
    done <<< "$(pg_tabanlar)"

    segb=16777216
    if [ -n "$C" ] && container_running "$C"; then
        segb="$(pg_segment_boyut "$C")"
    fi
    spl=$(( 4294967296 / segb ))
    [ "$spl" -lt 1 ] && spl=256

    local bres
    bres="$(pg_arsiv_boslugu "$spl")"
    bosluk="${bres%%$'\t'*}"; son_saglam="${bres##*$'\t'}"

    # En yeni arşivlenmiş segmentin zamanı. Sunucuya pg_stat_archiver'dan da
    # sorabilirdik ama DOSYANIN kendi mtime'ı sunucu kapalıyken de okunur —
    # ve PITR'a en çok sunucu kapalıyken bakılır.
    local sonseg
    sonseg="$(pg_arsiv_segmentleri | tail -1)"
    if [ -n "$sonseg" ]; then
        m="$(mtime "$WAL_DIR/$sonseg")" && en_yeni="$m"
    fi
    if [ "${bosluk:-0}" -gt 0 ] && [ -n "$son_saglam" ]; then
        m="$(mtime "$WAL_DIR/$son_saglam")" && en_yeni="$m"
        aciklama="arşivde $bosluk boşluk var; aralık $son_saglam segmentinde kesiliyor"
    fi

    # Hiç WAL arşivlenmemişse taban tek başına yine bir kurtarma noktasıdır
    # (kendi bittiği ana dönülür). Aralığı "yok" göstermek, elde duran bir
    # kurtarma noktasını gizlemek olurdu.
    if [ -z "$en_yeni" ] && [ -n "$en_eski" ]; then
        en_yeni="$(pg_tabanlar | tail -1 | cut -f1)"
        aciklama="arşivde segment yok; yalnız taban yedeklerinin kendi anlarına dönülebilir"
    fi
    # Aralık tersse (son taban, arşivin son segmentinden yeni) üst sınır
    # tabanın kendisidir.
    if [ -n "$en_eski" ] && [ -n "$en_yeni" ] && [ "$en_yeni" -lt "$en_eski" ]; then
        en_yeni="$en_eski"
    fi
    printf '%s\t%s\t%s\t%s\t%s' "$en_eski" "$en_yeni" "$taban_n" "$bosluk" "$aciklama"
}

# Hedefe uygun taban: bitiş anı hedeften ÖNCE olan EN YENİ taban.
# Daha yeni bir taban seçilseydi PostgreSQL "recovery_target_time is before
# the end of backup" ile açılmayı reddederdi; daha eskisi ise gereksiz yere
# saatlerce WAL oynatırdı.
pg_taban_sec() {   # <hedef epoch> → dosya yolu
    local hedef="$1" satir e f secilen=""
    while IFS= read -r satir; do
        [ -n "$satir" ] || continue
        e="${satir%%$'\t'*}"; f="${satir#*$'\t'}"
        [ "$e" -le "$hedef" ] && secilen="$f"
    done <<< "$(pg_tabanlar)"
    [ -n "$secilen" ] || return 1
    printf '%s' "$secilen"
}

# =============================================================================
# MARIADB — BİNLOG
# =============================================================================
# Binlog config/mariadb/my.cnf'te ZATEN AÇIK. Yine de compose'daki değere
# değil ÇALIŞAN SUNUCUYA soruyoruz: my.cnf `command:` ile ezilebiliyor
# (buffer pool, read-only ve server-id tam olarak öyle geçiliyor) ve
# --skip-log-bin ile açılmış bir container'ın my.cnf'i hâlâ log_bin yazar.
my_binlog_durumu() {   # <container> → "acik|kapali|bilinmiyor"
    local v
    v="$(tek_satir "$(my_sorgu "$1" 'SELECT @@log_bin')")"
    case "$v" in
        1|ON|on) printf 'acik' ;;
        0|OFF|off) printf 'kapali' ;;
        *) printf 'bilinmiyor' ;;
    esac
}

# Binlog dosyalarının yeri sabit yazılmıyor. log_bin'e göreli bir ad
# verildiğinde MariaDB onu datadir altına koyar; mutlak bir yol verilirse
# başka yere. Yolu sunucudan sormak, my.cnf ile compose arasında bir gün
# oluşacak ayrışmada betiğin boş bir dizine bakıp "binlog yok" demesini
# engelliyor.
my_binlog_temel() {   # <container> → /var/lib/mysql/mysql-bin
    tek_satir "$(my_sorgu "$1" 'SELECT @@log_bin_basename')"
}

# SHOW BINARY LOGS kullanıyoruz, SHOW MASTER STATUS değil: ikincisi
# MariaDB 11.4'te kullanımdan kaldırılma yolunda (SHOW BINLOG STATUS oldu) ve
# adı değiştiği gün bu betik sessizce boş liste okurdu. SHOW BINARY LOGS
# hem MySQL hem MariaDB'de aynı adla duruyor; son satır AKTİF dosyadır.
my_binlog_listesi() {   # <container> → sıralı ad listesi
    my_sorgu "$1" 'SHOW BINARY LOGS' | tr -d '\r' | awk 'NF {print $1}'
}

# Host'taki arşiv kopyası. Motorun hacmi ölse bile bunlar elde kalır.
my_arsiv_listesi() {
    [ -d "$BINLOG_DIR" ] || return 0
    find "$BINLOG_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
        | grep -E '[.][0-9]{6}$' | sort
}

# --------------------------------------------------------------- tabanlar ---
# MariaDB'de PITR tabanı MANTIKSAL bir dump'tır (PostgreSQL'den farklı olarak):
# binlog da mantıksal düzeydedir (satır/ifade olayları), ikisi aynı dilde
# konuşur. Şart olan tek şey, dump'ın hangi binlog konumundan sonrasını
# temsil ettiğinin dosyada YAZILI olmasıdır — bunu `--master-data=2` yapar.
# O satır yoksa dump geri yüklenir ama "nereden devam edeceğiz" bilinmez ve
# binlog'un başından oynatmak veriyi ikinci kez uygular.
my_taban_konum() {   # <gz dosyası> → "<binlog dosyası>\t<konum>"
    local f="$1" bas dosya pos
    # Yalnız başlığı açıyoruz: koca bir dump'ın tamamını çözmek bu soruyu
    # cevaplamak için gereksiz dakikalar demek. CHANGE MASTER satırı
    # mariadb-dump çıktısında ilk birkaç KB içindedir.
    bas="$(gzip -dc "$f" 2>/dev/null | head -c 262144)"
    # Desen hem MASTER_ hem SOURCE_ öneklerini kabul ediyor: MariaDB
    # MASTER_LOG_FILE yazar, MySQL 8 SOURCE_LOG_FILE. Tek önek yazsaydık
    # motorun bir sürüm sonrası bu betiği sessizce "taban yok" hâline
    # getirebilirdi.
    dosya="$(printf '%s' "$bas" | grep -oE "(MASTER|SOURCE)_LOG_FILE='[^']+'" \
             | head -1 | sed "s/.*='//; s/'$//")"
    pos="$(printf '%s' "$bas" | grep -oE "(MASTER|SOURCE)_LOG_POS=[0-9]+" \
           | head -1 | sed 's/.*=//')"
    [ -n "$dosya" ] || return 1
    sayi_mi "$pos" || return 1
    printf '%s\t%s' "$dosya" "$pos"
}

# Aday tabanlar İKİ yerden gelir:
#   1) backups/mariadb/taban/  — bu betiğin kendi aldığı tabanlar
#   2) backups/mariadb/full/   — backup.sh'ın gecelik tam yedekleri
# İkincisi bilerek: gecelik yedek zaten --master-data=2 ile alınıyor ve onu
# taban olarak kullanabilmek "her gün ayrıca bir dump daha al" demenin önüne
# geçiyor (backup.sh'ın başındaki OOM gerekçesi: aynı container'da ikinci bir
# ağır iş istemiyoruz). Ama BAĞIMLI DEĞİLİZ: konum satırını taşımayan bir
# dosya aday listesine hiç girmez, sessizce "taban var" sayılmaz.
# Her satır: "<epoch>\t<dosya>\t<binlog>\t<konum>"
my_tabanlar() {
    local f e k
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -s "$f" ] || continue
        k="$(my_taban_konum "$f")" || continue
        e="$(meta_oku "$f.meta" bitis_epoch)" || e=""
        if ! sayi_mi "$e"; then e="$(mtime "$f")" || continue; fi
        printf '%s\t%s\t%s\n' "$e" "$f" "$k"
    done <<< "$(find "$MY_TABAN_DIR" "$BACKUP_DIR/mariadb/full" -maxdepth 1 \
                 -type f -name '*.sql.gz' ! -name '*.bozuk' 2>/dev/null)" \
    | sort -n
}

my_taban_dogrula() {
    local f="$1"
    # gzip -t akışı SONUNA KADAR okur: kesik bir dump'ın başı sapasağlamdır
    # ve yalnız başına bakan bir kontrol onu geçirir (backup.sh'ın mongodb
    # dalındaki ders birebir bu).
    if ! gzip -t "$f" 2>>"$LOG_FILE"; then
        perr "Taban dump'ı sonuna kadar okunamadı (kesik gzip): $(basename "$f")"
        return 1
    fi
    if ! my_taban_konum "$f" >/dev/null; then
        perr "Taban dump'ında binlog konumu YOK: $(basename "$f") — PITR tabanı olamaz."
        perr "  (mariadb-dump --master-data=2 ile alınmamış ya da satır kırpılmış.)"
        return 1
    fi
    return 0
}

my_taban_al() {
    local C f meta bas_epoch bit_epoch k
    C="$(primary_of mariadb)"
    container_running "$C" || {
        perr "mariadb çalışmıyor ($C) — taban dump'ı canlı sunucudan alınır."
        return 1
    }
    if [ "$(my_binlog_durumu "$C")" != "acik" ]; then
        perr "mariadb'de binlog KAPALI — taban alınsa bile ileri gidilemez, PITR yapılamaz."
        perr "  config/mariadb/my.cnf'te log_bin açık olmalı ve container o ayarla açılmalı."
        return 1
    fi
    mkdir -p "$MY_TABAN_DIR" || { perr "Dizin açılamadı: $MY_TABAN_DIR"; return 1; }
    f="$MY_TABAN_DIR/mariadb_taban_$DATE.sql.gz"
    meta="$f.meta"
    bas_epoch="$(date +%s)"
    plog "MariaDB PITR tabanı alınıyor (mariadb-dump) → $(basename "$f")"

    # backup.sh'ın gecelik dump'ıyla AYNI bayraklar — bir istisnayla:
    # --skip-comments YOK. Konum satırı bir YORUMDUR (--master-data=2 onu
    # yorum olarak yazar) ve yorumları kısan bir bayrakla birlikte
    # kullanmanın davranışı sürümden sürüme değişir. Tabanın PITR için
    # kullanılabilirliği o tek satıra bağlı olduğundan burada riske
    # girmiyoruz; bedeli birkaç KB.
    ( export MYSQL_PWD="$(motor_parolasi mariadb)"
      zaman "$SURE_TABAN" docker exec -e MYSQL_PWD "$C" mariadb-dump -u root \
          --all-databases --single-transaction --quick --routines --triggers \
          --events --hex-blob --add-drop-database --add-drop-table \
          --master-data=2 ) 2>>"$LOG_FILE" | gzip -"$COMPRESSION_LEVEL" > "$f"
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ] || [ "${ps[1]}" -ne 0 ]; then
        perr "mariadb-dump başarısız (dump=${ps[0]} gzip=${ps[1]}). Ayrıntı: $LOG_FILE"
        rm -f "$f"
        return 1
    fi

    bit_epoch="$(date +%s)"
    if ! my_taban_dogrula "$f"; then
        mv -f "$f" "$f.bozuk" 2>/dev/null && perr "Kenara alındı: $(basename "$f").bozuk"
        return 1
    fi
    k="$(my_taban_konum "$f")"
    {
        printf 'motor=mariadb\n'
        printf 'alindi=%s\n'          "$(epoch_iso "$bit_epoch")"
        printf 'baslangic_epoch=%s\n' "$bas_epoch"
        printf 'bitis_epoch=%s\n'     "$bit_epoch"
        printf 'binlog_dosya=%s\n'    "${k%%$'\t'*}"
        printf 'binlog_konum=%s\n'    "${k##*$'\t'}"
        printf 'imaj=%s\n'            "$(motor_imaji mariadb)"
    } > "$meta"

    pok "PITR tabanı hazır: $(basename "$f") ($(insan "$(stat -c %s "$f" 2>/dev/null || echo 0)"), $(( bit_epoch - bas_epoch )) sn)"
    plog "  bu tabandan İLERİ gitmek için ${k%%$'\t'*} (konum ${k##*$'\t'}) ve sonrası gerekli"
    return 0
}

# ----------------------------------------------------------------- pencere --
# DÖNÜLEBİLİR ARALIK NASIL HESAPLANIYOR (mariadb):
#   EN ESKİ = binlog'u HÂLÂ DURAN en eski tabanın alındığı an. Tabanın
#     işaret ettiği binlog dosyası PURGE edilmişse (binlog_expire_logs_seconds)
#     o tabandan ileri gidilemez; o taban aralığa dahil edilmez ve `durum`
#     kaç tabanın bu yüzden kullanılamaz olduğunu ayrıca yazar. Bu sayı
#     sessiz kalsaydı, kullanıcı elinde 7 günlük yedek olduğu için 7 gün
#     geriye dönebildiğini sanardı.
#   EN YENİ = ŞU AN. MariaDB'de binlog yerel bir dosyadır ve her commit
#     anında yazılır; PostgreSQL'deki gibi bir "arşive düşme gecikmesi" yok.
#     Sunucu KAPALIYSA bu doğru olmaz — o hâlde host'taki arşiv kopyasının
#     en yenisinin zamanı kullanılır ve sebep yazılır.
# Çıktı: "<en_eski>\t<en_yeni>\t<taban_n>\t<kullanilamaz_n>\t<aciklama>"
my_pencere() {
    local C="$1" satir e f bl mevcut="" en_eski="" en_yeni="" n=0 kullanilamaz=0
    local aciklama="" calisiyor=0

    if [ -n "$C" ] && container_running "$C"; then
        calisiyor=1
        mevcut="$(my_binlog_listesi "$C")"
    fi
    # Arşiv kopyası da sayılır: sunucu kapalıyken ya da PURGE sonrası tek
    # kaynak odur.
    mevcut="$mevcut"$'\n'"$(my_arsiv_listesi)"

    while IFS= read -r satir; do
        [ -n "$satir" ] || continue
        n=$(( n + 1 ))
        e="$(printf '%s' "$satir" | cut -f1)"
        f="$(printf '%s' "$satir" | cut -f2)"
        bl="$(printf '%s' "$satir" | cut -f3)"
        if printf '%s\n' "$mevcut" | grep -Fxq "$bl"; then
            [ -z "$en_eski" ] && en_eski="$e"
        else
            kullanilamaz=$(( kullanilamaz + 1 ))
        fi
    done <<< "$(my_tabanlar)"

    if [ "$calisiyor" -eq 1 ]; then
        en_yeni="$(date +%s)"
    else
        local sonbl m
        sonbl="$(my_arsiv_listesi | tail -1)"
        if [ -n "$sonbl" ]; then
            m="$(mtime "$BINLOG_DIR/$sonbl")" && en_yeni="$m"
            aciklama="mariadb kapalı; üst sınır host arşivindeki son binlog ($sonbl)"
        else
            aciklama="mariadb kapalı ve host arşivinde binlog yok — üst sınır ölçülemedi"
        fi
    fi
    if [ "$kullanilamaz" -gt 0 ]; then
        aciklama="${aciklama:+$aciklama; }$kullanilamaz taban, işaret ettiği binlog PURGE edildiği için kullanılamıyor"
    fi
    [ -z "$en_eski" ] && en_yeni=""
    printf '%s\t%s\t%s\t%s\t%s' "$en_eski" "$en_yeni" "$n" "$kullanilamaz" "$aciklama"
}

# Hedefe uygun taban: alındığı an hedeften ÖNCE olan EN YENİ kullanılabilir
# taban. Çıktı: "<dosya>\t<binlog>\t<konum>"
my_taban_sec() {   # <hedef epoch> <container>
    local hedef="$1" C="${2:-}" satir e f bl pos mevcut="" secilen=""
    if [ -n "$C" ] && container_running "$C"; then
        mevcut="$(my_binlog_listesi "$C")"
    fi
    mevcut="$mevcut"$'\n'"$(my_arsiv_listesi)"
    while IFS= read -r satir; do
        [ -n "$satir" ] || continue
        e="$(printf '%s' "$satir" | cut -f1)"
        f="$(printf '%s' "$satir" | cut -f2)"
        bl="$(printf '%s' "$satir" | cut -f3)"
        pos="$(printf '%s' "$satir" | cut -f4)"
        [ "$e" -le "$hedef" ] || continue
        printf '%s\n' "$mevcut" | grep -Fxq "$bl" || continue
        secilen="$f"$'\t'"$bl"$'\t'"$pos"
    done <<< "$(my_tabanlar)"
    [ -n "$secilen" ] || return 1
    printf '%s' "$secilen"
}

# Tabandan itibaren oynatılacak binlog dosyaları, SIRAYLA. Ad biçimi sabit
# genişlikte (mysql-bin.000007) olduğu için sözlük sırası = üretim sırası;
# sayıya çevirip sıralamaya gerek yok ve 000009 → 000010 geçişi de doğru.
my_oynatilacaklar() {   # <ilk binlog> <liste kaynağı satırları>
    local ilk="$1" ad
    while IFS= read -r ad; do
        [ -n "$ad" ] || continue
        [[ "$ad" < "$ilk" ]] && continue
        printf '%s\n' "$ad"
    done
}

# =============================================================================
# GEÇİCİ KOPYA (--prova) ALTYAPISI
# =============================================================================
# restore-drill.sh ile aynı sözleşme: TEK KULLANIMLIK container + TEK
# KULLANIMLIK hacim, '--network none' ile açılır. Üretime, gateway'e ya da
# yığın ağına giden bir yolu YOKTUR — "dokunmuyoruz" sözü niyete değil
# çekirdeğe bağlanmış olur. WAL/binlog arşivi de SALT OKUNUR bağlanır:
# provanın arşivi kirletmesi teknik olarak imkânsız.
PROVA_C=""; HACIM=""; IMAJ=""; MEM_MB="$PROVA_MEM_MB"; HATA=""
TEMIZ=true; TEMIZ_YAPILDI=0

# --- `don` çıktısının JSON alanları -----------------------------------------
J_MOTOR=""; J_HEDEF=""; J_MOD=""; J_OK=false; J_SANIYE=0
J_TABAN=""; J_DURMA=""; J_DOGRULAMA="null"; J_DETAY="işlem başlatılmadı"
JSON_BASILDI=0
JSON_ISTENIR=0

json_bas() {
    [ "$JSON_ISTENIR" -eq 1 ] || return 0
    [ "$JSON_BASILDI" -eq 1 ] && return 0
    JSON_BASILDI=1
    printf '{"komut":"don","engine":%s,"target":%s,"mode":%s,"ok":%s,"seconds":%s,"base":%s,"stopped_at":%s,"verify":%s,"cleanup":%s,"detail":%s}\n' \
        "$(js "$J_MOTOR")" "$(js "$J_HEDEF")" "$(js "$J_MOD")" "$J_OK" \
        "$(jnum "$J_SANIYE")" "$(js "$J_TABAN")" "$(js "$J_DURMA")" \
        "$J_DOGRULAMA" "$TEMIZ" "$(js "$J_DETAY")"
}

temizle_gecici() {
    [ "$TEMIZ_YAPILDI" -eq 1 ] && return 0
    TEMIZ_YAPILDI=1
    local kalan="" i
    # gtid_strict_mode üretimde binlog oynatmak için geçici olarak
    # kapatılmıştı. Geri koymayı "işin sonuna" bırakmak yetmez: hata,
    # zaman aşımı ya da Ctrl+C hâlinde sunucu KATI OLMAYAN kipte kalır ve
    # bunu kimse fark etmez — bir sonraki replika kurulumunda bozuk GTID
    # sırası olarak patlar. Bu yüzden HER çıkış yolunda buradan geri alınıyor.
    if [ -n "${MY_STRICT_GERI:-}" ] && [ -n "${MY_STRICT_C:-}" ]; then
        my_sorgu "$MY_STRICT_C" "SET GLOBAL gtid_strict_mode=$MY_STRICT_GERI"             >/dev/null 2>&1             || perr "gtid_strict_mode eski değerine ($MY_STRICT_GERI) DÖNDÜRÜLEMEDİ — elle geri alın: SET GLOBAL gtid_strict_mode=$MY_STRICT_GERI"
        MY_STRICT_GERI=""
    fi
    # `docker container inspect` — çıplak `docker inspect` DEĞİL.
    # Çıplak biçim adı BÜTÜN nesne türlerinde arar: container, imaj, hacim,
    # ağ. Geçici container ile geçici hacme AYNI adı verdiğimiz için,
    # container silindikten sonra `docker inspect <ad>` HACMİ bulup 0
    # dönüyordu ve betik her koşumda "container SIZDI" diyip çıkış kodunu
    # 4'e çeviriyordu. Ölçümde iki koşumda da böyle oldu; oysa container
    # gerçekten silinmişti. Yanlış bir sızıntı alarmı, gerçek olanı da
    # inandırıcılıktan eder — o yüzden tür açıkça yazılıyor.
    if [ -n "$PROVA_C" ] && docker container inspect "$PROVA_C" >/dev/null 2>&1; then
        docker rm -f "$PROVA_C" >>"$LOG_FILE" 2>&1
        docker container inspect "$PROVA_C" >/dev/null 2>&1 \n            && kalan="container:$PROVA_C"
    fi
    if [ -n "$HACIM" ] && docker volume inspect "$HACIM" >/dev/null 2>&1; then
        # Container kaydı silinene kadar hacim "in use" görünebiliyor; tek
        # denemede pes etmek her provada bir hacim bırakırdı. Diskteki
        # sızıntı en sinsisidir: kimse `docker volume ls`ye bakmaz.
        i=0
        while [ "$i" -lt 10 ]; do
            docker volume rm "$HACIM" >>"$LOG_FILE" 2>&1 && break
            i=$(( i + 1 )); sleep 1
        done
        docker volume inspect "$HACIM" >/dev/null 2>&1 \
            && kalan="${kalan:+$kalan, }hacim:$HACIM"
    fi
    if [ -n "$kalan" ]; then
        TEMIZ=false
        perr "TEMİZLİK YAPILAMADI — geçici kaynaklar duruyor: $kalan"
        perr "  Elle silin:  docker rm -f $PROVA_C ; docker volume rm $HACIM"
        J_DETAY="$J_DETAY | TEMİZLİK YAPILAMADI: $kalan"
        return 1
    fi
    return 0
}

# Beklenmedik çıkışta da (die, kabuk hatası, Ctrl+C) temizlik ve JSON şart:
# çıktısı olmayan bir koşum, controller için "hiç çalışmamış" ile aynıdır.
cikista() {
    local kod=$?
    [ "$JSON_BASILDI" -eq 1 ] && return
    temizle_gecici
    [ "$J_DETAY" = "işlem başlatılmadı" ] \
        && J_DETAY="işlem beklenmedik şekilde sonlandı (çıkış $kod)"
    json_bas
}
trap cikista EXIT
trap 'J_DETAY="işlem kullanıcı tarafından kesildi (Ctrl+C)"; exit 130' INT TERM

bitir() {   # bitir <çıkış kodu>
    local kod="$1"
    if ! temizle_gecici; then [ "$kod" -eq 0 ] && kod=4; fi
    json_bas
    exit "$kod"
}
reddet()     { perr "$*"; J_DETAY="reddedildi: $*"; bitir 2; }
olcum_yok()  { perr "$*"; J_DETAY="ölçülemedi: $*"; bitir 3; }
kapsam_disi(){ warn "$*"; J_DETAY="kapsam dışı: $*"; bitir 3; }
dustu()      { perr "$*"; J_OK=false; J_DETAY="$*"; bitir 1; }

# Kilit: yedekleme/prova ile AYNI. Gerekçe restore-drill.sh'ta uzun uzun
# yazılı — tek sunucuda iki ağır iş aynı cgroup'u zorluyor ve temizlik turu
# ayağımızın altındaki dosyayı silebiliyor. acquire_lock DOĞRUDAN
# çağrılmıyor: o die ile ÇIKIŞ 1 verir ve controller bunu "kurtarma
# başarısız" diye okurdu; oysa kurtarma hiç DENENEMEDİ (çıkış 3).
kilit_al() {
    command -v flock >/dev/null 2>&1 \
        || olcum_yok "flock (util-linux) yok — yedekleme kilidi alınamadı."
    mkdir -p "$(dirname "$KILIT")" 2>/dev/null || true
    exec 9>>"$KILIT" || olcum_yok "Kilit dosyası açılamadı: $KILIT"
    flock -n 9 || olcum_yok "Yedekleme kilidi başkasında ($KILIT) — yedekleme, prova ya da geri yükleme sürüyor. HİÇBİR ŞEY YAPILMADI."
}

kalintilari_topla() {
    local id n=0
    for id in $(docker ps -aq --filter "label=$ETIKET" 2>/dev/null); do
        docker rm -f "$id" >>"$LOG_FILE" 2>&1 && n=$(( n + 1 ))
    done
    for id in $(docker volume ls -q --filter "label=$ETIKET" 2>/dev/null); do
        docker volume rm "$id" >>"$LOG_FILE" 2>&1 && n=$(( n + 1 ))
    done
    [ "$n" -gt 0 ] && warn "Önceki yarım kalmış PITR koşumlarından $n kalıntı temizlendi."
    return 0
}

onay_al() {   # onay_al <cümle>
    if [ "${ASSUME_YES:-}" = "yes" ]; then
        warn "ASSUME_YES=yes — onay sorulmadan devam ediliyor."
        return 0
    fi
    printf '\n%s%s%s\n' "$BOLD" "$1" "$NC"
    printf "Devam etmek için 'evet' yazın: "
    local a; read -r a
    [ "$a" = "evet" ]
}

# =============================================================================
# POSTGRESQL — KURTARMA
# =============================================================================
# Kurtarma yapılandırması PGDATA'ya yazılır. PostgreSQL 12'den beri ayrı bir
# recovery.conf YOKTUR: ayarlar normal yapılandırmaya, "kurtarma modundayım"
# bilgisi ise recovery.signal DOSYASININ VARLIĞINA taşındı. İkisinden birini
# unutmak sessizce yanlış sonuç verir — signal'sız bir sunucu ayarları okur
# ama kurtarmaya hiç girmez ve tabanın alındığı ana takılı kalır.
pg_kurtarma_ayari() {   # <hedef epoch>
    cat <<AYAR
# --- scripts/pitr.sh ($(date '+%F %T')) ---
restore_command = 'sh /etc/pitr/wal-restore.sh %f %p'
recovery_target_time = '$(epoch_pg "$1")'
recovery_target_action = 'promote'
recovery_target_inclusive = on
recovery_target_timeline = '$PITR_ZAMAN_CIZGISI'
AYAR
}

# Tabanı hacme açar ve kurtarma ayarını yerleştirir. Açma işi AYRI, kısa
# ömürlü bir container'da yapılıyor: motorun kendi entrypoint'i boş bir
# PGDATA gördüğünde initdb çalıştırır ve elimizde tabanın yerine YEPYENİ,
# BOŞ bir cluster kalırdı — üstelik "başarıyla açıldı" diyerek.
pg_hacme_yerlestir() {   # <hacim> <taban dosyası> <ayar metni>
    local hacim="$1" taban="$2" ayar="$3"
    gzip -dc "$taban" 2>>"$LOG_FILE" \
      | zaman "$SURE_YUKLEME" docker run --rm -i --network none \
            -v "$hacim:/var/lib/postgresql/data" \
            -e AYAR="$ayar" --entrypoint bash "$IMAJ" -c '
set -e
P=/var/lib/postgresql/data/pgdata
rm -rf "$P"
mkdir -p "$P"
tar -xf - -C "$P"
printf "%s\n" "$AYAR" >> "$P/postgresql.auto.conf"
: > "$P/recovery.signal"
rm -f "$P/postmaster.pid"
chown -R postgres:postgres /var/lib/postgresql/data
chmod 700 "$P"
' >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ]; then
        HATA="taban arşivi sonuna kadar açılamadı (gzip rc=${ps[0]})"; return 1
    fi
    if [ "${ps[1]}" -ne 0 ]; then
        HATA="taban hacme yerleştirilemedi (rc=${ps[1]}, $LOG_FILE)"; return 1
    fi
    return 0
}

pg_kopya_baslat() {
    # NEDEN hot_standby=off:
    # Açık olsaydı PostgreSQL, kurtarma başlamadan ÖNCE max_connections,
    # max_worker_processes ve max_locks_per_transaction değerlerinin tabanın
    # alındığı sunucudakinden KÜÇÜK olmadığını doğrular ve küçükse FATAL ile
    # durur. Üretim bu değerleri compose'daki `command:` ile geçiyor, taban
    # arşivi ise onları TAŞIMAZ (komut satırı argümanları dosyaya yazılmaz).
    # Yani varsayılanlarla açılan geçici kopya, yedekte hiçbir sorun yokken
    # "hot standby is not possible" diyerek düşerdi. Kapalıyken bu denetim
    # hiç çalışmaz ve kurtarma sırasında bağlantı kabul edilmez — bizim için
    # sorun değil, tersine işimize yarıyor: "bağlanabiliyorum" artık
    # doğrudan "yükseltme bitti" demek.
    # Yine de üç değeri üretimin kullandığı DEĞİŞKENLERDEN geçiyoruz; biri
    # yarın hot_standby'ı açarsa kopya yine de açılsın.
    docker run -d --name "$PROVA_C" --network none --restart no \
        --memory "${MEM_MB}m" --memory-swap "${MEM_MB}m" \
        --cpu-shares "$PROVA_CPU_SHARES" --label "$ETIKET=1" \
        -v "$HACIM:/var/lib/postgresql/data" \
        -v "$WAL_DIR:/wal-archive:ro" \
        -v "$STACK_ROOT/config/postgresql:/etc/pitr:ro" \
        -e PGDATA=/var/lib/postgresql/data/pgdata \
        -e PG_WAL_ARSIV=/wal-archive \
        -e POSTGRES_USER="${POSTGRES_USER:-root}" \
        -e POSTGRES_PASSWORD="$(motor_parolasi postgresql)" \
        "$IMAJ" postgres \
            -c hot_standby=off \
            -c listen_addresses=127.0.0.1 \
            -c max_connections="${POSTGRES_MAX_CONNECTIONS:-200}" \
            -c max_worker_processes="${POSTGRES_MAX_WORKERS:-8}" \
            -c max_locks_per_transaction="${POSTGRES_MAX_LOCKS:-64}" \
            -c archive_mode=off \
        >>"$LOG_FILE" 2>&1
}

# PostgreSQL'in kendi cümleleri. Kurtarmanın nerede durduğunu ondan başka
# kimse bilmiyor; tahmin etmek yerine günlüğünü okuyoruz.
pg_gunluk_kaniti() {   # <container>
    docker logs "$1" 2>&1 | tr -d '\r' \
        | grep -aE 'recovery stopping|last completed transaction was at log time|recovery ended before configured recovery target|starting point-in-time recovery' \
        | tail -3 | tr '\n' ' ' | cut -c1-400
}

pg_olum_sebebi() {   # <container>
    local oom kod son gunluk betik_hatasi son_islem
    oom="$(docker inspect -f '{{.State.OOMKilled}}' "$1" 2>/dev/null)"
    kod="$(docker inspect -f '{{.State.ExitCode}}' "$1" 2>/dev/null)"
    gunluk="$(docker logs "$1" 2>&1 | tr -d '\r')"
    son="$(printf '%s' "$gunluk" | tail -20 | tr '\n' ' ' | cut -c1-300)"

    # ÖNCE bunu soruyoruz: restore_command'ın KENDİSİ çalışabildi mi?
    # Ölçümde bu ayrım kritik çıktı. Betik erişilemez olduğunda
    # (bind-mount eksik → "sh: 0: cannot open /etc/pitr/wal-restore.sh")
    # PostgreSQL'in gördüğü şey "arşiv bitti"dir ve günlüğe yazdığı cümle
    # aşağıdakiyle BİREBİR AYNI olur. Suçu arşive atan bir mesaj, operatörü
    # var olmayan bir eksik segmenti aramaya gönderirdi.
    betik_hatasi="$(printf '%s' "$gunluk"         | grep -aE 'wal-restore:|cannot open /etc/pitr' | tail -1)"
    if [ -n "$betik_hatasi" ]; then
        printf 'KURTARMA KOMUTU ÇALIŞTIRILAMADI, arşiv okunamadı: %s — bu bir yedek/arşiv sorunu DEĞİL, container yapılandırması sorunu (/etc/pitr bağlaması). Çözüm: docker compose up -d postgresql'             "$betik_hatasi"
        return 0
    fi

    if printf '%s' "$gunluk"         | grep -qa 'recovery ended before configured recovery target'; then
        # PostgreSQL hedefe ULAŞAMADIĞINDA nereye kadar geldiğini kendi
        # yazar. O satırı çıkarıp kullanıcıya ULAŞILABİLİR bir hedef
        # veriyoruz; yoksa elinde "aralık içindeydi ama olmadı" cümlesi
        # kalırdı.
        # NEDEN OLUR: en sık sebep eksik segment değil, SESSİZ BİR
        # VERİTABANIDIR. Hedefle son işlem arasında hiç yazı yoksa o
        # aralıkta WAL kaydı da yoktur ve PostgreSQL hedefi reddeder.
        # Ölçümde tam bu görüldü: son işlem 17:53:14, hedef 17:55:00,
        # arada tek yazı yok → FATAL.
        son_islem="$(printf '%s' "$gunluk"             | grep -a 'last completed transaction was at log time'             | tail -1 | sed 's/.*log time //')"
        printf 'PostgreSQL İSTENEN ANA ULAŞAMADI: arşivdeki WAL hedeften ÖNCE bitti. Arşivin ulaştığı son işlem: %s. İki sebebi olabilir: (1) o andan sonra veritabanına HİÇ YAZILMADI — hedefi o ana (ya da öncesine) çekin; (2) aradaki segmentler arşive düşmedi/silindi (./scripts/pitr.sh durum postgresql). Sunucunun son satırları: %s'             "${son_islem:-ÖLÇÜLEMEDİ}" "$son"
        return 0
    fi
    if [ "$oom" = "true" ]; then
        printf 'geçici container BELLEK YETMEDİĞİ için öldü (OOM, çıkış %s). Tavan %s MB; PROVA_MEM_MB ile artırın. Son satırlar: %s' \
            "${kod:-?}" "$MEM_MB" "$son"
        return 0
    fi
    printf 'container çıktı (çıkış kodu %s). Son satırlar: %s' "${kod:-bilinmiyor}" "$son"
}

pg_kurtarma_bekle() {   # <container> <saniye>
    local C="$1" bitis=$(( $(date +%s) + $2 )) durum r
    while :; do
        durum="$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)"
        if [ "$durum" != "true" ]; then
            HATA="$(pg_olum_sebebi "$C")"; return 1
        fi
        r="$(tek_satir "$(pg_sorgu "$C" postgres 'SELECT pg_is_in_recovery()')")"
        [ "$r" = "f" ] && return 0
        if [ "$(date +%s)" -ge "$bitis" ]; then
            HATA="kurtarma $2 sn içinde bitmedi (PITR_KURTARMA_SURESI). $(pg_olum_sebebi "$C")"
            return 1
        fi
        sleep 2
    done
}

# =============================================================================
# MARIADB — KURTARMA
# =============================================================================
my_kopya_baslat() {
    # NEDEN BURADA BİNLOG AÇIK (restore-drill.sh --skip-log-bin ile açıyor):
    # mariadb-binlog çıktısı her olaydan önce `SET @@session.gtid_seq_no=…`
    # yazar ve MariaDB bunu binlog KAPALIYKEN reddeder. Kapalı bıraksaydık
    # oynatma daha ilk olayda dururdu ve suç yedeğe/arşive atılırdı.
    # gtid-strict-mode=OFF da aynı sebepten: eski GTID'leri yeniden yazmak
    # katı kipte "out-of-order sequence number" hatasıdır.
    docker run -d --name "$PROVA_C" --network none --restart no \
        --memory "${MEM_MB}m" --memory-swap "${MEM_MB}m" \
        --cpu-shares "$PROVA_CPU_SHARES" --label "$ETIKET=1" \
        -v "$HACIM:/var/lib/mysql" \
        -v "$BINLOG_DIR:/binlog-archive:ro" \
        -e MARIADB_ROOT_PASSWORD="$(motor_parolasi mariadb)" \
        "$IMAJ" \
            --server-id=99 --log-bin=mysql-bin --binlog-format=ROW \
            --gtid-strict-mode=OFF --skip-slave-start \
        >>"$LOG_FILE" 2>&1
}

my_hazir_bekle() {   # <container> <saniye>
    local C="$1" bitis=$(( $(date +%s) + $2 )) durum
    while :; do
        durum="$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)"
        if [ "$durum" != "true" ]; then
            HATA="$(pg_olum_sebebi "$C")"; return 1
        fi
        my_sorgu "$C" 'SELECT 1' >/dev/null 2>&1 && return 0
        if [ "$(date +%s)" -ge "$bitis" ]; then
            HATA="geçici container $2 sn içinde hazır olmadı. $(pg_olum_sebebi "$C")"
            return 1
        fi
        sleep 2
    done
}

my_dump_yukle() {   # <hedef container> <dump>
    local C="$1" f="$2"
    gzip -dc "$f" 2>>"$LOG_FILE" \
      | ( export MYSQL_PWD="$(motor_parolasi mariadb)"
          zaman "$SURE_YUKLEME" docker exec -e MYSQL_PWD -i "$C" mariadb -u root ) \
        >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ]; then
        HATA="taban dump'ı sonuna kadar açılamadı (gzip rc=${ps[0]})"; return 1
    fi
    if [ "${ps[1]}" -ne 0 ]; then
        HATA="taban dump'ı yüklenemedi (istemci rc=${ps[1]}, $LOG_FILE)"; return 1
    fi
    return 0
}

# Binlog'u tabanın konumundan HEDEF ANA KADAR oynatır.
#   <kaynak container> <dizin> <ad listesi> <ilk binlog> <konum>
#   <hedef container> <hedef epoch>
my_binlog_oynat() {
    local kc="$1" dizin="$2" liste="$3" ilk="$4" pos="$5" hc="$6" hedef="$7"
    local ad yollar=() n=0
    while IFS= read -r ad; do
        [ -n "$ad" ] || continue
        yollar+=("$dizin/$ad"); n=$(( n + 1 ))
    done <<< "$(printf '%s\n' "$liste" | my_oynatilacaklar "$ilk")"
    if [ "$n" -eq 0 ]; then
        HATA="oynatılacak binlog bulunamadı ($ilk ve sonrası yok) — taban ile hedef arası KAPATILAMAZ"
        return 1
    fi
    plog "  $n binlog dosyası oynatılıyor: ${yollar[0]} … konumdan $pos"

    # TZ=UTC ve hedefin UTC yazılması BİRLİKTE gerekiyor:
    # --stop-datetime, mariadb-binlog'un çalıştığı yerin YEREL saatine göre
    # yorumlanır. Container UTC, host Europe/Istanbul iken bu üç saatlik
    # sessiz bir kayma demek — "14:32'ye döndük" denir, 11:32'ye dönülür.
    # --start-position YALNIZ İLK dosyaya uygulanır (belgelenmiş davranış);
    # sonraki dosyalar baştan oynatılır, ki doğrusu da budur.
    # NOT: --stop-datetime, damgası hedefe EŞİT ya da ondan BÜYÜK ilk olayda
    # durur; yani hedef an DAHİL DEĞİLDİR (PostgreSQL'de dahildir).
    ( zaman "$SURE_YUKLEME" docker exec -e TZ=UTC "$kc" mariadb-binlog \
          --start-position="$pos" --stop-datetime="$(epoch_utc "$hedef")" \
          "${yollar[@]}" ) 2>>"$LOG_FILE" \
      | ( export MYSQL_PWD="$(motor_parolasi mariadb)"
          zaman "$SURE_YUKLEME" docker exec -e MYSQL_PWD -i "$hc" mariadb -u root ) \
        >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ]; then
        HATA="binlog okunamadı (mariadb-binlog rc=${ps[0]}, $LOG_FILE)"; return 1
    fi
    if [ "${ps[1]}" -ne 0 ]; then
        HATA="binlog oynatılamadı (istemci rc=${ps[1]}, $LOG_FILE)"; return 1
    fi
    J_DURMA="$n binlog dosyası, konum $pos'tan $(epoch_utc "$hedef") UTC'ye kadar oynatıldı"
    return 0
}

# Üretimde binlog oynatırken gtid_strict_mode geçici olarak kapatılıyor
# (aşağıda gerekçesi). Hangi değere döneceğimizi burada tutuyoruz ki
# temizlik her çıkış yolunda onu geri koyabilsin.
MY_STRICT_GERI=""
MY_STRICT_C=""

# =============================================================================
# ORTAK ÖN KONTROLLER
# =============================================================================
docker_var_mi() {
    command -v docker >/dev/null 2>&1 \
        || olcum_yok "docker bulunamadı — hiçbir şey yapılamadı."
    docker info >/dev/null 2>&1 \
        || olcum_yok "docker'a erişilemiyor (servis kapalı ya da yetki yok)."
}

motor_kontrol() {   # <motor>
    [ -n "$1" ] || kapsam_disi "Motor belirtilmedi. Örnek: ./scripts/pitr.sh durum postgresql"
    pitr_destekli "$1" || kapsam_disi "PITR desteklenmiyor: $1 — $(kapsam_notu "$1")"
}

imaj_hazirla() {   # <motor>
    IMAJ="$(motor_imaji "$1")" \
        || olcum_yok "$1 için imaj belirlenemedi."
    docker image inspect "$IMAJ" >/dev/null 2>&1 && return 0
    plog "imaj yerelde yok, indiriliyor: $IMAJ"
    docker pull "$IMAJ" >>"$LOG_FILE" 2>&1 \
        || olcum_yok "İmaj indirilemedi: $IMAJ — geçici kopya açılamaz."
}

# --dogrula: kurtarılan KOPYAYA kullanıcının kendi sorgusunu sorar ve
# sonucunu JSON'a koyar. Neden var: "kurtarma başarıyla bitti" cümlesi
# istenen verinin geldiğini KANITLAMAZ; yanlış bir ana dönmüş olabiliriz ve
# motor bundan hiç şikâyet etmez. Üretimde uygulamadan önce sorulacak tek
# doğru soru "o satır orada mı, sonraki satır orada değil mi" sorusudur.
dogrulama_calistir() {   # <motor> <container> <sql>
    local motor="$1" C="$2" sql="$3" cikti
    [ -n "$sql" ] || return 0
    case "$motor" in
        postgresql) cikti="$(pg_sorgu "$C" "${PITR_DOGRULA_DB:-${DEFAULT_DATABASE:-defaultdb}}" "$sql")" ;;
        mariadb)    cikti="$(my_sorgu "$C" "$sql")" ;;
    esac
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        # Sorgu düştüyse "boş sonuç" DEMİYORUZ. Ölçüm aracının bozulmasını
        # "veri yok"a çevirmek, bu betiğin engellemeye çalıştığı şeyin ta
        # kendisi (e2e/lib.sh'taki t_unknown ile aynı ayrım).
        J_DOGRULAMA="$(js "ÖLÇÜLEMEDİ: doğrulama sorgusu çalıştırılamadı (rc=$rc)")"
        warn "Doğrulama sorgusu çalıştırılamadı — sonuç ölçülemedi."
        return 1
    fi
    cikti="$(printf '%s' "$cikti" | tr -d '\r' | tr '\n' ' ' | cut -c1-300)"
    J_DOGRULAMA="$(js "$cikti")"
    plog "  doğrulama sorgusunun kopyadaki cevabı: ${cikti:-<boş>}"
    return 0
}

# =============================================================================
# KOMUT: don
# =============================================================================
cmd_don() {
    local motor="${1:-}" zamanstr="${2:-}" prova="${3:-0}" dsql="${4:-}"
    JSON_ISTENIR=1
    J_MOTOR="$motor"
    J_MOD="$([ "$prova" = "1" ] && printf 'prova' || printf 'uretim')"

    motor_kontrol "$motor"
    [ -n "$zamanstr" ] || reddet "Hedef zaman verilmedi. Örnek: ./scripts/pitr.sh don $motor \"2026-09-01 14:32:00\""
    docker_var_mi

    local hedef
    hedef="$(zaman_epoch "$zamanstr")" \
        || reddet "Hedef zaman anlaşılmadı: '$zamanstr'. Beklenen biçim: \"YYYY-AA-GG SS:DD:ss\" (yerel saat)."
    J_HEDEF="$(epoch_iso "$hedef")"

    [ -z "$(motor_parolasi "$motor")" ] \
        && olcum_yok "$motor parolası okunamadı (.env yok ya da eksik)."

    kilit_al
    kalintilari_topla

    local C; C="$(primary_of "$motor")"
    local pen en_eski en_yeni aciklama
    if [ "$motor" = "postgresql" ]; then pen="$(pg_pencere "$C")"; else pen="$(my_pencere "$C")"; fi
    en_eski="$(printf '%s' "$pen" | cut -f1)"
    en_yeni="$(printf '%s' "$pen" | cut -f2)"
    aciklama="$(printf '%s' "$pen" | cut -f5)"

    # --- ARALIK KAPISI -------------------------------------------------------
    # Reddin gerekçesi HER ZAMAN sayılarla yazılıyor. "Aralık dışında" tek
    # başına kullanıcıyı ekranın karşısında bırakır; ne kadar geriye
    # gidilebildiğini ve o sınırı NEYİN koyduğunu bilmeden ne yapacağına
    # karar veremez.
    if [ -z "$en_eski" ] || [ -z "$en_yeni" ]; then
        reddet "$motor için dönülebilir bir aralık YOK — taban yedeği bulunamadı. Önce: ./scripts/pitr.sh taban $motor${aciklama:+ ($aciklama)}"
    fi
    if [ "$hedef" -lt "$en_eski" ]; then
        reddet "Hedef aralığın ÖNCESİNDE: istenen $(epoch_yaz "$hedef") · en eski dönülebilir an $(epoch_yaz "$en_eski") (bunu en eski taban yedeği belirliyor). Daha geriye gitmek için o tarihi kapsayan bir taban gerekir; elde yok."
    fi
    if [ "$hedef" -gt "$en_yeni" ]; then
        reddet "Hedef aralığın SONRASINDA: istenen $(epoch_yaz "$hedef") · en yeni dönülebilir an $(epoch_yaz "$en_yeni")${aciklama:+ ($aciklama)}. Gelecekteki bir ana dönülemez; henüz arşive düşmemiş bir ana da dönülemez (önce: ./scripts/pitr.sh arsivle $motor)."
    fi

    plog "Hedef: $(epoch_yaz "$hedef") — aralık $(epoch_yaz "$en_eski") … $(epoch_yaz "$en_yeni") içinde."

    if [ "$motor" = "postgresql" ]; then
        pg_don "$hedef" "$prova" "$dsql"
    else
        my_don "$hedef" "$prova" "$dsql"
    fi
}

# ------------------------------------------------------------- postgresql ---
pg_don() {
    local hedef="$1" prova="$2" dsql="$3"
    local taban ayar C basla
    taban="$(pg_taban_sec "$hedef")" \
        || reddet "Hedeften önce alınmış bir taban yedeği yok — WAL tek başına veri değildir, bir tabanın üzerine oynatılır."
    J_TABAN="$taban"
    plog "Taban: $(basename "$taban")"
    pg_taban_dogrula "$taban" \
        || dustu "Seçilen taban arşivi bozuk — bu dosyayla kurtarma yapılmaz."

    ayar="$(pg_kurtarma_ayari "$hedef")"
    imaj_hazirla postgresql
    C="$(primary_of postgresql)"

    if [ "$prova" = "1" ]; then
        PROVA_C="dbstack-pitr-postgresql-$$"
        HACIM="dbstack-pitr-postgresql-$$"
        docker volume create --label "$ETIKET=1" "$HACIM" >>"$LOG_FILE" 2>&1 \
            || olcum_yok "Geçici hacim yaratılamadı: $HACIM"
        basla="$(date +%s)"
        plog "1/3 taban geçici hacme açılıyor"
        pg_hacme_yerlestir "$HACIM" "$taban" "$ayar" || dustu "$HATA"
        plog "2/3 geçici PostgreSQL açılıyor ve WAL oynatılıyor"
        pg_kopya_baslat || olcum_yok "Geçici container başlatılamadı ($IMAJ) — ayrıntı: $LOG_FILE"
        pg_kurtarma_bekle "$PROVA_C" "$SURE_KURTARMA" || dustu "$HATA"
        J_SANIYE=$(( $(date +%s) - basla ))
        J_DURMA="$(pg_gunluk_kaniti "$PROVA_C")"
        [ -n "$J_DURMA" ] || J_DURMA="ÖLÇÜLEMEDİ: sunucu günlüğünde durma noktası satırı bulunamadı"
        plog "3/3 kopya ayakta — yükseltme tamam (${J_SANIYE} sn)"
        dogrulama_calistir postgresql "$PROVA_C" "$dsql"
        J_OK=true
        J_DETAY="PROVA GEÇTİ: geçici kopya $(epoch_yaz "$hedef") anına kurtarıldı (${J_SANIYE} sn). Üretime DOKUNULMADI."
        pok "$J_DETAY"
        bitir 0
    fi

    # --- ÜRETİM --------------------------------------------------------------
    container_running "$C" || docker inspect "$C" >/dev/null 2>&1 \
        || reddet "postgresql container'ı yok ($C) — üretime kurtarma yapılamaz."
    # Compose'a PITR ayarları eklendikten sonra container YENİDEN
    # YARATILMADIYSA bu bağlamalar yoktur ve restore_command hiçbir
    # segmenti bulamaz. Bunu
    # kurtarmanın ORTASINDA öğrenmek, üretim veri dizini çoktan silinmişken
    # öğrenmek demektir; o yüzden kapı burada.
    baglama_var "$C" /wal-archive \
        || reddet "$C container'ında /wal-archive bağlaması yok — compose'daki PITR ayarları henüz uygulanmamış. Önce: docker compose up -d postgresql"
    baglama_var "$C" /etc/pitr \
        || reddet "$C container'ında /etc/pitr bağlaması yok — restore_command betiği erişilemez. Önce: docker compose up -d postgresql"

    local hacim; hacim="$(uretim_hacmi "$C" /var/lib/postgresql/data)"
    [ -n "$hacim" ] || reddet "$C container'ının veri hacmi bulunamadı — yanlış yere yazmaktansa duruyoruz."

    onay_al "DİKKAT: postgresql ÜRETİM verisi $(epoch_yaz "$hedef") anına döndürülecek.
O andan SONRAKİ TÜM VERİ SİLİNECEK. Hacim: $hacim
Önce güvenlik yedeği alınacak (pg_basebackup)." \
        || reddet "Onay verilmedi — hiçbir şey yapılmadı."

    plog "1/5 güvenlik yedeği (mevcut hâlin fiziksel kopyası)"
    pg_taban_al || dustu "Güvenlik yedeği ALINAMADI — yıkıcı işleme geçilmedi, veriniz yerinde."

    basla="$(date +%s)"
    plog "2/5 postgresql durduruluyor"
    # `docker stop` — compose değil. compose stop, servisin profili aktif
    # değilse "no such service" der; container ise adıyla her zaman durur.
    docker stop "$C" >>"$LOG_FILE" 2>&1 \
        || dustu "postgresql durdurulamadı — kurtarma başlatılmadı."

    plog "3/5 taban üretim hacmine açılıyor: $hacim"
    if ! pg_hacme_yerlestir "$hacim" "$taban" "$ayar"; then
        docker start "$C" >>"$LOG_FILE" 2>&1
        dustu "$HATA (postgresql yeniden başlatıldı; veri dizini YARIM kalmış olabilir — güvenlik yedeğinden dönün: $PG_TABAN_DIR)"
    fi

    plog "4/5 postgresql açılıyor ve WAL oynatılıyor"
    docker start "$C" >>"$LOG_FILE" 2>&1 \
        || dustu "postgresql başlatılamadı — $LOG_FILE"
    pg_kurtarma_bekle "$C" "$SURE_KURTARMA" || dustu "$HATA"

    J_SANIYE=$(( $(date +%s) - basla ))
    J_DURMA="$(pg_gunluk_kaniti "$C")"
    [ -n "$J_DURMA" ] || J_DURMA="ÖLÇÜLEMEDİ: sunucu günlüğünde durma noktası satırı bulunamadı"
    dogrulama_calistir postgresql "$C" "$dsql"
    J_OK=true
    J_DETAY="postgresql $(epoch_yaz "$hedef") anına döndürüldü (${J_SANIYE} sn)."
    pok "$J_DETAY"
    plog "5/5 SONRAKİ ADIM: kurtarma YENİ BİR ZAMAN ÇİZGİSİ başlattı."
    warn "Varsa REPLİKALAR artık uyumsuz — ./stack.sh replica off/on ile yeniden kurun."
    warn "Yeni bir PITR tabanı alın: ./scripts/pitr.sh taban postgresql"
    bitir 0
}

# ---------------------------------------------------------------- mariadb ---
my_don() {
    local hedef="$1" prova="$2" dsql="$3"
    local sec taban ilk pos C temel dizin liste kaynak basla
    C="$(primary_of mariadb)"
    sec="$(my_taban_sec "$hedef" "$C")" \
        || reddet "Hedeften önce alınmış, binlog'u hâlâ duran bir taban yok — binlog tek başına veri değildir, bir dump'ın üzerine oynatılır."
    taban="$(printf '%s' "$sec" | cut -f1)"
    ilk="$(printf '%s'  "$sec" | cut -f2)"
    pos="$(printf '%s'  "$sec" | cut -f3)"
    J_TABAN="$taban"
    plog "Taban: $(basename "$taban") → binlog $ilk konum $pos"
    my_taban_dogrula "$taban" \
        || dustu "Seçilen taban dump'ı bozuk — bu dosyayla kurtarma yapılmaz."

    imaj_hazirla mariadb

    if [ "$prova" = "1" ]; then
        # Binlog'u nereden okuyacağız? Üretim ayaktaysa ORADAN: dosyalar
        # eksiksiz ve günceldir. Değilse host'taki arşiv kopyası tek
        # kaynaktır — ve bu, arşiv kopyasının var olma sebebi.
        if container_running "$C"; then
            temel="$(my_binlog_temel "$C")"
            [ -n "$temel" ] || olcum_yok "mariadb'de log_bin_basename okunamadı."
            dizin="$(dirname "$temel")"
            liste="$(my_binlog_listesi "$C")"
            kaynak="uretim"
        else
            dizin="/binlog-archive"
            liste="$(my_arsiv_listesi)"
            kaynak="arsiv"
            [ -n "$liste" ] || olcum_yok "mariadb kapalı ve host arşivinde binlog yok — oynatacak bir şey bulunamadı."
        fi

        PROVA_C="dbstack-pitr-mariadb-$$"
        HACIM="dbstack-pitr-mariadb-$$"
        docker volume create --label "$ETIKET=1" "$HACIM" >>"$LOG_FILE" 2>&1 \
            || olcum_yok "Geçici hacim yaratılamadı: $HACIM"
        basla="$(date +%s)"
        plog "1/4 geçici MariaDB açılıyor"
        my_kopya_baslat || olcum_yok "Geçici container başlatılamadı ($IMAJ) — ayrıntı: $LOG_FILE"
        my_hazir_bekle "$PROVA_C" 300 || dustu "$HATA"
        plog "2/4 taban dump'ı yükleniyor"
        my_dump_yukle "$PROVA_C" "$taban" || dustu "$HATA"
        plog "3/4 binlog oynatılıyor (kaynak: $kaynak)"
        local kc="$C"; [ "$kaynak" = "arsiv" ] && kc="$PROVA_C"
        my_binlog_oynat "$kc" "$dizin" "$liste" "$ilk" "$pos" "$PROVA_C" "$hedef" \
            || dustu "$HATA"
        J_SANIYE=$(( $(date +%s) - basla ))
        plog "4/4 kopya hazır (${J_SANIYE} sn)"
        dogrulama_calistir mariadb "$PROVA_C" "$dsql"
        J_OK=true
        J_DETAY="PROVA GEÇTİ: geçici kopya $(epoch_yaz "$hedef") anına kurtarıldı (${J_SANIYE} sn). Üretime DOKUNULMADI."
        pok "$J_DETAY"
        bitir 0
    fi

    # --- ÜRETİM --------------------------------------------------------------
    container_running "$C" \
        || reddet "mariadb çalışmıyor ($C) — üretime kurtarma canlı sunucuya yapılır."
    onay_al "DİKKAT: mariadb ÜRETİM verisi $(epoch_yaz "$hedef") anına döndürülecek.
O andan SONRAKİ TÜM VERİ SİLİNECEK.
Önce güvenlik yedeği alınacak (mariadb-dump)." \
        || reddet "Onay verilmedi — hiçbir şey yapılmadı."

    plog "1/6 güvenlik yedeği"
    my_taban_al || dustu "Güvenlik yedeği ALINAMADI — yıkıcı işleme geçilmedi, veriniz yerinde."

    basla="$(date +%s)"
    # ADIM SIRASI KRİTİK. FLUSH, o anda açık olan binlog'u MÜHÜRLER ve yeni
    # bir dosya açar. Böylece birazdan yapacağımız geri yükleme (ki kendisi de
    # binlog'a yazar) MÜHÜRLENMİŞ dosyalara değil, yeni dosyaya düşer.
    # Oynatacağımız listeyi de tam bu anda alıyoruz: aksi hâlde kendi geri
    # yüklememizin olaylarını kendimize geri oynatma riski olurdu.
    plog "2/6 binlog mühürleniyor (FLUSH BINARY LOGS)"
    my_sorgu "$C" 'FLUSH BINARY LOGS' >/dev/null \
        || dustu "FLUSH BINARY LOGS başarısız — oynatılacak sınır belirlenemedi."
    temel="$(my_binlog_temel "$C")"
    dizin="$(dirname "$temel")"
    # Son satır YENİ aktif dosyadır; onu listeden çıkarıyoruz.
    liste="$(my_binlog_listesi "$C" | head -n -1)"
    [ -n "$liste" ] || dustu "Mühürlenmiş binlog kalmadı — oynatacak bir şey yok."

    # gtid_strict_mode: eski GTID'leri yeniden binlog'a yazmak katı kipte
    # "out-of-order sequence number" hatasıdır ve oynatma daha ilk olayda
    # durur. Geçici olarak kapatıyoruz; temizlik her çıkış yolunda geri koyar.
    MY_STRICT_GERI="$(tek_satir "$(my_sorgu "$C" 'SELECT @@gtid_strict_mode')")"
    MY_STRICT_C="$C"
    case "$MY_STRICT_GERI" in 1|ON|on) MY_STRICT_GERI=1 ;; *) MY_STRICT_GERI=0 ;; esac
    my_sorgu "$C" 'SET GLOBAL gtid_strict_mode=0' >/dev/null 2>&1

    plog "3/6 taban dump'ı üretime yükleniyor"
    my_dump_yukle "$C" "$taban" || dustu "$HATA"
    plog "4/6 binlog oynatılıyor"
    my_binlog_oynat "$C" "$dizin" "$liste" "$ilk" "$pos" "$C" "$hedef" || dustu "$HATA"
    plog "5/6 gtid_strict_mode geri alınıyor"

    J_SANIYE=$(( $(date +%s) - basla ))
    dogrulama_calistir mariadb "$C" "$dsql"
    J_OK=true
    J_DETAY="mariadb $(epoch_yaz "$hedef") anına döndürüldü (${J_SANIYE} sn)."
    pok "$J_DETAY"
    plog "6/6 SONRAKİ ADIM:"
    warn "Varsa REPLİKALAR artık uyumsuz — ./stack.sh replica off/on ile yeniden kurun."
    warn "Yeni bir PITR tabanı alın: ./scripts/pitr.sh taban mariadb"
    bitir 0
}

# =============================================================================
# KOMUT: durum
# =============================================================================
# Bir motorun durumunu ÖLÇER. Global olarak doldurulan alanlar:
#   D_ACIK D_ESKI D_YENI D_ARSIV D_TABAN_BAYT D_TABAN_N D_BOSLUK D_NOT
#   D_UYARI[] (dizi)
D_ACIK=""; D_ESKI=""; D_YENI=""; D_ARSIV=0; D_TABAN_BAYT=0
D_TABAN_N=0; D_BOSLUK=0; D_NOT=""; D_UYARI=()

durum_olc() {   # <motor>
    local motor="$1" C pen
    D_ACIK="bilinmiyor"; D_ESKI=""; D_YENI=""; D_ARSIV=0; D_TABAN_BAYT=0
    D_TABAN_N=0; D_BOSLUK=0; D_NOT=""; D_UYARI=()
    C="$(primary_of "$motor")"

    if [ "$motor" = "postgresql" ]; then
        D_ARSIV="$(bayt_dizin "$WAL_DIR")"
        D_TABAN_BAYT="$(bayt_dizin "$PG_TABAN_DIR")"
        if container_running "$C"; then
            D_ACIK="$(pg_arsiv_durumu "$C")"
            if [ "$D_ACIK" = "kapali" ]; then
                D_UYARI+=("archive_mode KAPALI — WAL arşivlenmiyor, PITR penceresi İLERLEMİYOR. compose'da açık görünüyorsa container o ayarla yeniden yaratılmamıştır: docker compose up -d postgresql")
            fi
            # Arşivleyicinin kendi sayacı. Bir tek başarısızlık bile kalıcı
            # olabilir: PostgreSQL aynı segmenti sonsuza kadar dener ve
            # bu arada pg_wal büyür. Diski dolduran arıza budur.
            local hata_n hata_wal hata_zaman
            hata_n="$(tek_satir "$(pg_sorgu "$C" postgres \
                'SELECT failed_count FROM pg_stat_archiver')")"
            if sayi_mi "$hata_n" && [ "$hata_n" -gt 0 ]; then
                hata_wal="$(tek_satir "$(pg_sorgu "$C" postgres \
                    'SELECT coalesce(last_failed_wal, $$-$$) FROM pg_stat_archiver')")"
                hata_zaman="$(tek_satir "$(pg_sorgu "$C" postgres \
                    'SELECT coalesce(last_failed_time::text, $$-$$) FROM pg_stat_archiver')")"
                D_UYARI+=("arşivleme $hata_n kez BAŞARISIZ oldu (son: $hata_wal @ $hata_zaman). Sebebi genelde izindir: ./scripts/pitr.sh kur postgresql")
            fi
            # pg_wal birikiyorsa arşivleme tıkanmış demektir; sayıyı
            # göstermek, "disk doldu" sürprizini birkaç gün öne çeker.
            local wal_n
            wal_n="$(tek_satir "$(pg_sorgu "$C" postgres \
                'SELECT count(*) FROM pg_ls_waldir()')")"
            if sayi_mi "$wal_n" && [ "$wal_n" -gt 200 ]; then
                D_UYARI+=("pg_wal'da $wal_n segment birikmiş — arşivleme geride kalıyor ya da tıkalı; veri diski dolabilir")
            fi
        else
            D_ACIK="motor kapalı"
            D_NOT="postgresql kapalı; ayarlar sunucuya sorulamadı, aralık yalnız DOSYALARDAN hesaplandı"
        fi
        pen="$(pg_pencere "$C")"
    else
        D_ARSIV="$(bayt_dizin "$BINLOG_DIR")"
        D_TABAN_BAYT="$(bayt_dizin "$MY_TABAN_DIR")"
        if container_running "$C"; then
            D_ACIK="$(my_binlog_durumu "$C")"
            if [ "$D_ACIK" != "acik" ]; then
                D_UYARI+=("log_bin KAPALI — binlog yazılmıyor, PITR yapılamaz (config/mariadb/my.cnf)")
            fi
            # Binlog'un canlı hacimdeki toplam boyutu: arşiv kopyası
            # alınmasa bile diski dolduran şey budur.
            local canli
            canli="$(my_sorgu "$C" 'SHOW BINARY LOGS' | tr -d '\r' \
                     | awk 'NF>=2 {t+=$2} END {printf "%d", t+0}')"
            sayi_mi "$canli" && D_NOT="canlı binlog (motorun hacminde): $(insan "$canli")"
            # Saklama süresi karşılaştırması. İki sayı ayrıştığında ortaya
            # çıkan şey bir hata mesajı değil, felaket günü "o ana
            # dönemiyoruz" cümlesidir.
            local exp gun
            exp="$(tek_satir "$(my_sorgu "$C" 'SELECT @@binlog_expire_logs_seconds')")"
            if sayi_mi "$exp"; then
                gun=$(( exp / 86400 ))
                if [ "$gun" -lt "$PITR_RETENTION_DAYS" ]; then
                    D_UYARI+=("binlog $gun gün saklanıyor ama yedek/arşiv saklaması $PITR_RETENTION_DAYS gün — PITR penceresi yedeklerden KISA, aradaki fark kurtarılamaz")
                fi
            fi
        else
            D_ACIK="motor kapalı"
        fi
        pen="$(my_pencere "$C")"
    fi

    D_ESKI="$(printf '%s' "$pen" | cut -f1)"
    D_YENI="$(printf '%s' "$pen" | cut -f2)"
    D_TABAN_N="$(printf '%s' "$pen" | cut -f3)"
    D_BOSLUK="$(printf '%s' "$pen" | cut -f4)"
    local pen_not; pen_not="$(printf '%s' "$pen" | cut -f5)"
    [ -n "$pen_not" ] && D_UYARI+=("$pen_not")
    # "Aralık yok" ile "taban yok" AYNI ŞEY DEĞİL ve karıştırılırsa
    # kullanıcı yanlış işi yapar: elinde taban varken bir taban daha alır,
    # oysa sorun arşivin/binlog'un eksilmesidir. Ölçümde bu ikisi gerçekten
    # birbirine karıştı (1 taban duruyorken "taban yedeği YOK" yazıldı).
    if [ -z "$D_ESKI" ]; then
        if [ "${D_TABAN_N:-0}" -gt 0 ]; then
            D_UYARI+=("$D_TABAN_N taban yedeği var ama HİÇBİRİ KULLANILAMIYOR — ilerlemek için gereken WAL/binlog artık yok. Yeni bir taban alın: ./scripts/pitr.sh taban $motor")
        else
            D_UYARI+=("taban yedeği YOK — WAL/binlog tek başına veri değildir. Önce: ./scripts/pitr.sh taban $motor")
        fi
    fi
}

cmd_durum() {
    local istenen="${1:-}" json="${2:-0}"
    local motorlar motor i satirlar=""

    if [ -n "$istenen" ]; then
        pitr_destekli "$istenen" || {
            if [ "$json" = "1" ]; then
                printf '{"komut":"durum","engines":[{"engine":%s,"supported":false,"reason":%s}]}\n' \
                    "$(js "$istenen")" "$(js "$(kapsam_notu "$istenen")")"
            else
                warn "PITR desteklenmiyor: $istenen — $(kapsam_notu "$istenen")"
            fi
            return 3
        }
        motorlar="$istenen"
    else
        motorlar="$(pitr_motorlari)"
    fi

    [ "$json" = "1" ] || heading "PITR durumu (zamanda bir ana dönme)"

    for motor in $motorlar; do
        durum_olc "$motor"
        if [ "$json" = "1" ]; then
            local u="" ; for i in "${D_UYARI[@]:-}"; do
                [ -n "$i" ] || continue
                u="${u:+$u,}$(js "$i")"
            done
            satirlar="${satirlar:+$satirlar,}$(printf '{"engine":%s,"supported":true,"state":%s,"oldest":%s,"newest":%s,"archive_bytes":%s,"base_bytes":%s,"bases":%s,"gaps":%s,"warnings":[%s]}' \
                "$(js "$motor")" "$(js "$D_ACIK")" \
                "$([ -n "$D_ESKI" ] && js "$(epoch_iso "$D_ESKI")" || printf 'null')" \
                "$([ -n "$D_YENI" ] && js "$(epoch_iso "$D_YENI")" || printf 'null')" \
                "$(jnum "$D_ARSIV")" "$(jnum "$D_TABAN_BAYT")" \
                "$(jnum "$D_TABAN_N")" "$(jnum "$D_BOSLUK")" "$u")"
            continue
        fi

        printf '\n  %s%s%s\n' "$BOLD" "$motor" "$NC"
        printf '    PITR         : %s\n' "$D_ACIK"
        if [ -n "$D_ESKI" ] && [ -n "$D_YENI" ]; then
            printf '    Dönülebilir  : %s\n' "$(epoch_yaz "$D_ESKI")"
            printf '                 → %s\n' "$(epoch_yaz "$D_YENI")"
            printf '                   (%s)\n' "$(sure_yaz $(( D_YENI - D_ESKI )))"
        else
            printf '    Dönülebilir  : %sYOK%s — aşağıdaki sebebe bakın\n' "$RED" "$NC"
        fi
        printf '    Taban yedeği : %s adet, %s\n' "$D_TABAN_N" "$(insan "$D_TABAN_BAYT")"
        printf '    Arşiv        : %s' "$(insan "$D_ARSIV")"
        [ "$motor" = "postgresql" ] && printf ' (WAL: %s)' "$WAL_DIR"
        [ "$motor" = "mariadb" ]    && printf ' (binlog kopyası: %s)' "$BINLOG_DIR"
        printf '\n'
        [ -n "$D_NOT" ] && printf '    Not          : %s\n' "$D_NOT"
        for i in "${D_UYARI[@]:-}"; do
            [ -n "$i" ] || continue
            printf '    %s!%s %s\n' "$YELLOW" "$NC" "$i"
        done
    done

    if [ "$json" = "1" ]; then
        printf '{"komut":"durum","retention_days":%s,"backup_retention_days":%s,"engines":[%s]}\n' \
            "$(jnum "$PITR_RETENTION_DAYS")" "$(jnum "$RETENTION_DAYS")" "$satirlar"
        return 0
    fi

    printf '\n  %sSaklama%s: arşiv %s gün · yedekler %s gün\n' \
        "$BOLD" "$NC" "$PITR_RETENTION_DAYS" "$RETENTION_DAYS"
    if [ "$PITR_RETENTION_DAYS" != "$RETENTION_DAYS" ]; then
        warn "Arşiv ve yedek saklama süreleri AYRIŞMIŞ. Arşiv daha uzunsa disk sessizce dolar; kısaysa elinizdeki yedeklerin bir kısmından ileri gidilemez."
    fi
    if [ -z "$istenen" ]; then
        printf '\n  Diğer motorlarda PITR %sdesteklenmiyor%s:\n' "$YELLOW" "$NC"
        printf '    mongodb : %s\n' "$(kapsam_notu mongodb)"
        printf '    redis   : %s\n' "$(kapsam_notu redis)"
        printf '    mssql   : %s\n' "$(kapsam_notu mssql)"
    fi
    printf '\n'
    return 0
}

sure_yaz() {   # saniye → "3 gün 4 saat"
    local s="${1:-0}" g sa dk
    [ "$s" -lt 0 ] && s=0
    g=$(( s / 86400 )); sa=$(( (s % 86400) / 3600 )); dk=$(( (s % 3600) / 60 ))
    if   [ "$g"  -gt 0 ]; then printf '%d gün %d saat' "$g" "$sa"
    elif [ "$sa" -gt 0 ]; then printf '%d saat %d dakika' "$sa" "$dk"
    else printf '%d dakika' "$dk"; fi
}

# =============================================================================
# KOMUT: kur
# =============================================================================
# Arşiv dizini HOST'ta yaratılıyor ama CONTAINER'ın kullanıcısı yazacak.
# Dizin yoksa docker onu kendisi yaratır — root:root olarak; postgres (uid
# 999) oraya yazamaz ve archive_command her segmentte "Permission denied"
# der. Bunun kötü tarafı gürültülü olması değil, SESSİZ olması: PostgreSQL
# yeniden dener, pg_wal büyür ve arıza ancak veri diski dolduğunda görünür.
cmd_kur() {
    local motor="${1:-}"
    motor_kontrol "$motor"
    docker_var_mi
    local C; C="$(primary_of "$motor")"
    local dizinler=() ic_yol="" kullanici=""

    case "$motor" in
        postgresql) dizinler=("$WAL_DIR" "$PG_TABAN_DIR"); ic_yol=/wal-archive; kullanici=postgres ;;
        mariadb)    dizinler=("$BINLOG_DIR" "$MY_TABAN_DIR"); ic_yol=/binlog-archive; kullanici=mysql ;;
    esac

    local d
    for d in "${dizinler[@]}"; do
        mkdir -p "$d" || die "Dizin açılamadı: $d"
        plog "dizin hazır: $d"
    done

    if ! container_running "$C"; then
        warn "$motor kapalı — dizinler açıldı ama container içindeki izinler DÜZELTİLEMEDİ."
        warn "Motoru açtıktan sonra bu komutu tekrar çalıştırın: ./scripts/pitr.sh kur $motor"
        return 3
    fi
    if ! baglama_var "$C" "$ic_yol"; then
        err "$C container'ında $ic_yol bağlaması YOK."
        err "  docker-compose.yml'deki PITR ayarları henüz uygulanmamış."
        err "  Çözüm:  docker compose up -d $motor   (container yeniden yaratılmalı)"
        return 1
    fi

    # chown container'ın İÇİNDEN yapılıyor: bind-mount'ta inode host ile
    # ortaktır, yani buradaki chown host'taki dizini de düzeltir. Host'ta
    # `chown 999` demek ise sunucuda o uid'in ne olduğunu bilmeyi gerektirir
    # ve imaj sürümüyle değişebilir.
    docker exec -u 0 "$C" sh -c \
        "mkdir -p '$ic_yol' && chown '$kullanici' '$ic_yol' && chmod 750 '$ic_yol'" \
        >>"$LOG_FILE" 2>&1 \
        || { err "İzinler düzeltilemedi ($ic_yol). Ayrıntı: $LOG_FILE"; return 1; }

    # Sözle değil ÖLÇÜMLE: motorun kendi kullanıcısı gerçekten yazabiliyor mu?
    if ! docker exec "$C" sh -c \
            "touch '$ic_yol/.yazma-testi' && rm -f '$ic_yol/.yazma-testi'" \
            >>"$LOG_FILE" 2>&1; then
        err "$ic_yol motorun kullanıcısı ($kullanici) tarafından hâlâ YAZILAMIYOR."
        err "  Host tarafında dizinin sahibini kontrol edin: ${dizinler[0]}"
        return 1
    fi
    pok "$ic_yol yazılabilir ($kullanici) — arşivleme çalışabilir."

    if [ "$motor" = "postgresql" ]; then
        local am; am="$(pg_arsiv_durumu "$C")"
        if [ "$am" = "acik" ]; then
            pok "archive_mode açık."
        else
            warn "archive_mode = $am. Bu ayar YENİDEN BAŞLATMA ister (reload yetmez):"
            warn "  docker compose up -d postgresql"
        fi
    else
        local lb; lb="$(my_binlog_durumu "$C")"
        if [ "$lb" = "acik" ]; then pok "log_bin açık."
        else warn "log_bin = $lb — config/mariadb/my.cnf'i ve compose'daki command satırını kontrol edin."; fi
    fi
    printf '\n  Sıradaki adım: ./scripts/pitr.sh taban %s\n\n' "$motor"
    return 0
}

# =============================================================================
# KOMUT: arsivle
# =============================================================================
cmd_arsivle() {
    local motor="${1:-}"
    motor_kontrol "$motor"
    docker_var_mi
    local C; C="$(primary_of "$motor")"
    # Motor kapalıysa çıkış 3: iş BAŞARISIZ olmadı, hiç DENENEMEDİ. Aradaki
    # fark cron çıktısında önemli — kapalı bir motor her gece "arşivleme
    # başarısız" diye alarm üretmemeli.
    container_running "$C" || {
        err "$motor çalışmıyor ($C) — arşivleme canlı sunucudan yapılır."
        return 3
    }

    if [ "$motor" = "postgresql" ]; then
        # WAL segmenti dolmadan arşive düşmez. Yazı olmuş ama segment
        # dolmamışsa "en yeni dönülebilir an" saatlerce geride kalır ve
        # kullanıcı aslında elinde olan bir veriye dönemez. pg_switch_wal
        # segmenti zorla kapatır.
        # AKTİF segmentin adını ÖNCEDEN alıyoruz:
        # pg_walfile_name(pg_switch_wal()) sınır LSN'inde BİR SONRAKİ
        # segmentin adını verebilir ve o dosya hiç
        # arşivlenmediği için beklememiz sonsuza kadar sürerdi.
        local seg
        seg="$(tek_satir "$(pg_sorgu "$C" postgres \
            'SELECT pg_walfile_name(pg_current_wal_lsn())')")"
        [ -n "$seg" ] || { err "Aktif WAL segmenti okunamadı."; return 1; }
        pg_sorgu "$C" postgres 'SELECT pg_switch_wal()' >/dev/null 2>&1
        local bitis=$(( $(date +%s) + 60 ))
        while :; do
            [ -f "$WAL_DIR/$seg" ] && { pok "Arşive düştü: $seg"; return 0; }
            if [ "$(date +%s)" -ge "$bitis" ]; then
                err "$seg 60 sn içinde arşive DÜŞMEDİ."
                err "  Arşivleyicinin durumu için: ./scripts/pitr.sh durum postgresql"
                return 1
            fi
            sleep 2
        done
    fi

    # --- mariadb -------------------------------------------------------------
    baglama_var "$C" /binlog-archive || {
        err "$C container'ında /binlog-archive bağlaması yok — compose ayarları uygulanmamış."
        err "  Çözüm:  docker compose up -d mariadb"
        return 1
    }
    my_sorgu "$C" 'FLUSH BINARY LOGS' >/dev/null \
        || { err "FLUSH BINARY LOGS başarısız."; return 1; }
    local temel aktif n
    temel="$(my_binlog_temel "$C")"
    [ -n "$temel" ] || { err "log_bin_basename okunamadı."; return 1; }
    aktif="$(my_binlog_listesi "$C" | tail -1)"

    # AKTİF dosya KOPYALANMIYOR: hâlâ yazılıyor ve yarım bir kopya, arşivde
    # tam sanılan eksik bir dosya bırakır. FLUSH'tan sonra aktif dosya
    # zaten boştur; bir sonraki tur onu mühürlenmiş olarak alır.
    # Kopyalama container'ın İÇİNDE: `docker cp` her dosyayı daemon üzerinden
    # akıtır, buradaki cp ise iki bind-mount arasında doğrudan çalışır.
    n="$(docker exec -e TEMEL="$temel" -e AKTIF="$aktif" "$C" sh -c '
        d="$(dirname "$TEMEL")"; b="$(basename "$TEMEL")"
        n=0
        for f in "$d/$b".[0-9]*; do
            [ -f "$f" ] || continue
            ad="$(basename "$f")"
            [ "$ad" = "$AKTIF" ] && continue
            [ -e "/binlog-archive/$ad" ] && continue
            cp "$f" "/binlog-archive/.gecici.$ad" || exit 1
            mv "/binlog-archive/.gecici.$ad" "/binlog-archive/$ad" || exit 1
            n=$((n+1))
        done
        printf "%s\n" "$n"' 2>>"$LOG_FILE")"
    local rc=$?
    n="$(tek_satir "$n")"
    if [ "$rc" -ne 0 ] || ! sayi_mi "$n"; then
        err "Binlog arşive kopyalanamadı. Ayrıntı: $LOG_FILE"
        err "  İzin sorunu olabilir: ./scripts/pitr.sh kur mariadb"
        return 1
    fi
    pok "$n binlog dosyası host arşivine kopyalandı ($BINLOG_DIR, toplam $(insan "$(bayt_dizin "$BINLOG_DIR")"))"
    return 0
}

# =============================================================================
# KOMUT: temizle
# =============================================================================
# ARŞİV, YEDEKLERLE AYNI POLİTİKAYA TABİ — ama "aynı gün sayısı" tek başına
# yetmez ve buradaki asıl mesele bu:
#   Yaşa bakan düz bir silme, saklanan bir TABANIN ihtiyaç duyduğu WAL'ı da
#   siler. backup.sh'ın clean_old'u her motorda EN YENİ 3 kopyayı yaşı ne
#   olursa olsun korur (kapalı bir motorun son kurtarma noktası yok
#   olmasın diye). O kural yüzünden 30 günlük bir taban elde kalabilir;
#   WAL'ını 7 günde silersek elimizde AÇILAMAYAN bir taban kalır ve kimse
#   fark etmez — felaket günü "yedek var ama dönülemiyor" denir.
# Bu yüzden burada iki ölçüt birlikte uygulanıyor:
#   (1) yaş > PITR_RETENTION_DAYS
#   (2) VE dosya, saklanan en eski tabanın gerektirdiği zamandan eski
# TABAN DOSYALARINI BU KOMUT SİLMEZ: onlar backups/<motor>/taban/ altında
# ve backup.sh'ın `clean` komutu oraya da bakıyor (find özyinelemeli,
# *.gz deseni tar.gz ve sql.gz'yi kapsıyor). İki sahibi olan bir politika,
# hiç sahibi olmayandan beterdir.
cmd_temizle() {
    local gun="${1:-$PITR_RETENTION_DAYS}"
    case "$gun" in
        ''|*[!0-9]*) die "Gün sayısı bir tam sayı olmalı, '$gun' değil. Örnek: ./scripts/pitr.sh temizle 7" ;;
    esac
    heading "PITR arşivi temizleniyor ($gun günden eski, tabanların gerektirdikleri hariç)"

    local motor dizin taban_dizin taban_en_eski taban_dosya
    local silinen=0 korunan=0 yetim=0
    for motor in postgresql mariadb; do
        if [ "$motor" = "postgresql" ]; then
            dizin="$WAL_DIR"; taban_dizin="$PG_TABAN_DIR"
        else
            dizin="$BINLOG_DIR"; taban_dizin="$MY_TABAN_DIR"
        fi
        [ -d "$dizin" ] || continue

        # Saklanan en eski tabanın zamanı. Hiç taban yoksa taban 0 kalır ve
        # yalnız yaş ölçütü işler — çünkü korunacak bir zincir de yoktur.
        taban_en_eski=0
        taban_dosya="$(find "$taban_dizin" "$BACKUP_DIR/$motor/full" -maxdepth 1 \
                        -type f \( -name '*.tar.gz' -o -name '*.sql.gz' \) \
                        ! -name '*.bozuk' -printf '%T@\t%p\n' 2>/dev/null \
                       | sort -n | head -1 | cut -f2-)"
        if [ -n "$taban_dosya" ]; then
            taban_en_eski="$(mtime "$taban_dosya")" || taban_en_eski=0
            taban_en_eski=$(( taban_en_eski - PITR_KORUMA_TAMPON ))
            [ "$taban_en_eski" -lt 0 ] && taban_en_eski=0
        fi

        local f m n_sil=0 n_kor=0
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            # Zaman çizgisi geçmişi (*.history) YAŞ NE OLURSA OLSUN kalır.
            # Birkaç yüz bayttır ama kurtarma, hangi çizginin nereden
            # ayrıldığını yalnız oradan okur; silinirse 'latest' zaman
            # çizgisini izleyen her kurtarma eski çizgide takılı kalır ve
            # bunu hiçbir hata mesajı söylemez.
            case "$f" in *.history) n_kor=$(( n_kor + 1 )); continue ;; esac
            m="$(mtime "$f")" || continue
            if [ "$taban_en_eski" -gt 0 ] && [ "$m" -ge "$taban_en_eski" ]; then
                n_kor=$(( n_kor + 1 )); continue
            fi
            rm -f "$f" && n_sil=$(( n_sil + 1 ))
        done <<< "$(find "$dizin" -maxdepth 1 -type f -mtime +"$gun" 2>/dev/null)"

        silinen=$(( silinen + n_sil )); korunan=$(( korunan + n_kor ))
        printf '  %-12s %d silindi · %d korundu (%s)\n' "$motor" "$n_sil" "$n_kor" \
            "$( [ -n "$taban_dosya" ] \
                && printf 'en eski taban: %s' "$(basename "$taban_dosya")" \
                || printf 'taban yok — yalnız yaş ölçütü uygulandı' )"

        # Öksüz meta dosyaları: taban .gz'si backup.sh'ın temizliğiyle
        # gittiğinde .meta arkada kalır (deseni *.gz değil). Tek başına
        # zararsız ama biriktikçe `durum` çıktısını yanıltır.
        local mf
        while IFS= read -r mf; do
            [ -n "$mf" ] || continue
            [ -f "${mf%.meta}" ] && continue
            rm -f "$mf" && yetim=$(( yetim + 1 ))
        done <<< "$(find "$taban_dizin" -maxdepth 1 -type f -name '*.meta' 2>/dev/null)"
    done

    [ "$yetim" -gt 0 ] && plog "  $yetim öksüz meta dosyası silindi"
    pok "$silinen dosya silindi, $korunan dosya taban zinciri için korundu."
    printf '  WAL arşivi: %s · binlog arşivi: %s\n\n' \
        "$(insan "$(bayt_dizin "$WAL_DIR")")" "$(insan "$(bayt_dizin "$BINLOG_DIR")")"
    return 0
}

# =============================================================================
# KULLANIM
# =============================================================================
kullanim() {
cat <<EOF

Zamanda bir ana dönme (PITR) — databases-stack

  ./scripts/pitr.sh durum [motor] [--json]
        Hangi motorda PITR açık, HANGİ ZAMAN ARALIĞINA dönülebilir,
        arşiv ne kadar yer tutuyor.

  ./scripts/pitr.sh kur <motor>
        Arşiv dizinini açar ve motorun oraya YAZABİLDİĞİNİ ölçer.

  ./scripts/pitr.sh taban <motor>
        PITR tabanı alır. WAL/binlog tek başına veri değildir; bir tabanın
        üzerine oynatılır. Taban yoksa dönülebilir aralık da yoktur.

  ./scripts/pitr.sh arsivle <motor>
        Biriken WAL/binlog'u ŞİMDİ arşive iter (üst sınırı bugüne çeker).

  ./scripts/pitr.sh don <motor> "<zaman>" [--prova] [--dogrula "<SQL>"]
        O ana kurtarır. --prova ile üretime DOKUNMADAN, tek kullanımlık bir
        kopyada dener. --dogrula, kurtarılan kopyaya kendi sorgunuzu sorar.
        Örnek:
          ./scripts/pitr.sh don postgresql "2026-09-01 14:32:00" --prova \\
              --dogrula "SELECT count(*) FROM siparisler"

  ./scripts/pitr.sh temizle [gün]
        Arşivi saklama süresine göre temizler; saklanan tabanların
        gerektirdiği dosyalara DOKUNMAZ. Varsayılan: $PITR_RETENTION_DAYS gün.

  Desteklenen motorlar: $(pitr_motorlari | tr '\n' ' ')
  Desteklenmeyenler ve sebepleri: ./scripts/pitr.sh durum

  Çıkış kodları: 0 tamam · 1 başarısız · 2 REDDEDİLDİ (yıkıcı iş yapılmadı)
                 3 kapsam dışı / ölçülemedi · 4 temizlik yapılamadı

  Ayrıntı: docs/PITR.md

EOF
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
KOMUT="${1:-yardim}"
shift 2>/dev/null || true

case "$KOMUT" in
    durum)
        MOTOR=""; JSON=0
        for a in "$@"; do
            case "$a" in
                --json) JSON=1 ;;
                -*)     die "Bilinmeyen seçenek: $a" ;;
                *)      MOTOR="$a" ;;
            esac
        done
        cmd_durum "$MOTOR" "$JSON"
        exit $?
        ;;
    kur)      cmd_kur "${1:-}"; exit $? ;;
    taban)
        MOTOR="${1:-}"
        motor_kontrol "$MOTOR"
        docker_var_mi
        kilit_al
        case "$MOTOR" in
            postgresql) pg_taban_al ;;
            mariadb)    my_taban_al ;;
        esac
        exit $?
        ;;
    arsivle)  cmd_arsivle "${1:-}"; exit $? ;;
    temizle)  cmd_temizle "${1:-}"; exit $? ;;
    don)
        MOTOR="${1:-}"; shift 2>/dev/null || true
        HEDEF_STR="${1:-}"; shift 2>/dev/null || true
        PROVA=0; DSQL=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --prova)   PROVA=1 ;;
                --dogrula) shift; DSQL="${1:-}" ;;
                *)         die "Bilinmeyen seçenek: $1" ;;
            esac
            shift 2>/dev/null || break
        done
        cmd_don "$MOTOR" "$HEDEF_STR" "$PROVA" "$DSQL"
        exit $?
        ;;
    *)
        kullanim
        exit 1
        ;;
esac
