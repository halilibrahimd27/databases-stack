#!/bin/bash
# =============================================================================
# databases-stack — uçtan uca paketlerin ORTAK KOŞUM KÜTÜPHANESİ
# =============================================================================
# Her e2e betiği bunu source eder. Sayaçlar, sonuç bildirimi ve ÇIKIŞ KODU
# burada tek bir yerde tanımlıdır.
#
# NEDEN ORTAK: sekiz paket ayrı ayrı yazıldığında sekizinin de aynı hatayı
# yaptığı görüldü — hiçbir kontrol çalışmadığında (motorlar kapalı, ön koşul
# yok) betik "0/0 geçti" yazıp ÇIKIŞ 0 veriyordu. Bir CI için bu, "hiçbir şey
# ölçülmedi" ile "her şey sağlam" arasında hiçbir fark bırakmaz — ve bir test
# paketinin yapabileceği en kötü şey budur: ölçmediğini ölçmüş gibi göstermek.
#
# DÖRT SONUÇ TÜRÜ VAR, ÜÇÜ DEĞİL:
#   t_ok      — ölçtük, doğru çıktı
#   t_fail    — ölçtük, yanlış çıktı
#   t_skip    — ÖN KOŞUL YOK (motor kapalı, replikasyon kurulu değil).
#               Meşrudur; çıkış kodunu etkilemez ama özette AYRI görünür.
#   t_unknown — ÖLÇEMEDİK (sorgu düştü, docker cevap vermedi, dosya okunamadı).
#               BAŞARISIZ SAYILIR. Denetimde en sık rastlanan sessiz-yeşil
#               kalıbı tam buydu: ölçüm başarısız olunca kontrol "geçti"
#               yazıyordu. "Bilmiyorum" ile "iyi" aynı şey değildir.
# =============================================================================

# Renkler common.sh'ten gelir; o source edilmediyse kendimiz tanımlayalım.
if [ -z "${GREEN:-}" ]; then
    if [ -t 1 ]; then
        RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
        BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
    else
        RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
    fi
fi

E2E_SUITE="${E2E_SUITE:-$(basename "${BASH_SOURCE[1]:-e2e}" .sh)}"
E2E_PASS=0; E2E_FAIL=0; E2E_SKIP=0; E2E_UNKNOWN=0
E2E_FAILED_NAMES=(); E2E_UNKNOWN_NAMES=(); E2E_SKIPPED_NAMES=()

t_ok() {
    E2E_PASS=$((E2E_PASS + 1))
    printf '  %s[GEÇTİ]%s      %s\n' "$GREEN" "$NC" "$1"
}

t_fail() {
    E2E_FAIL=$((E2E_FAIL + 1))
    E2E_FAILED_NAMES+=("$1")
    printf '  %s[BAŞARISIZ]%s %s\n' "$RED" "$NC" "$1"
    [ -n "${2:-}" ] && printf '               ↳ %s\n' "$2"
    return 0
}

# Ön koşul yok — ölçülemedi ama ölçülmesi de beklenmiyordu.
t_skip() {
    E2E_SKIP=$((E2E_SKIP + 1))
    E2E_SKIPPED_NAMES+=("$1")
    printf '  %s[ATLANDI]%s    %s\n               ↳ %s\n' "$YELLOW" "$NC" "$1" "${2:-sebep belirtilmedi}"
    return 0
}

# ÖLÇEMEDİK. Başarısız sayılır — bilerek.
t_unknown() {
    E2E_UNKNOWN=$((E2E_UNKNOWN + 1))
    E2E_UNKNOWN_NAMES+=("$1")
    printf '  %s[ÖLÇÜLEMEDİ]%s %s\n               ↳ %s\n' "$RED" "$NC" "$1" "${2:-sebep belirtilmedi}"
    return 0
}

t_head() { printf '\n%s%s%s\n' "${BOLD}" "$*" "${NC}"; }
t_info() { printf '  %s·%s %s\n' "$BLUE" "$NC" "$*"; }

# Kesinti BAŞARI DEĞİLDİR. Ctrl-C ile yarıda kalan koşu, denetimde "3/3 geçti,
# ÇIKIŞ 0" veriyordu — oysa kritik kontrollere hiç sıra gelmemişti.
e2e_interrupt() {
    printf '\n%s[KESİLDİ]%s %s paketi tamamlanmadan durduruldu — sonuç GEÇERSİZ.\n' \
        "$RED" "$NC" "$E2E_SUITE" >&2
    exit 130
}
trap e2e_interrupt INT TERM

# ---------------------------------------------------------------- sonuç -----
# ÇIKIŞ KODLARI
#   0   en az bir kontrol çalıştı, hiçbiri başarısız/ölçülemedi
#   1   en az bir kontrol başarısız ya da ölçülemedi
#   2   HİÇBİR KONTROL ÇALIŞMADI — "ölçmedik" demektir, "sağlam" değil
#   3   EKSİK KAPSAM — çalışanlar geçti ama atlama sayısı ölçülenden çok
#   130 kesildi
e2e_finish() {
    local calisan=$((E2E_PASS + E2E_FAIL + E2E_UNKNOWN))
    t_head "$E2E_SUITE — sonuç"
    printf '  geçti %d · başarısız %d · ölçülemedi %d · atlandı %d\n' \
        "$E2E_PASS" "$E2E_FAIL" "$E2E_UNKNOWN" "$E2E_SKIP"

    if [ ${#E2E_FAILED_NAMES[@]} -gt 0 ]; then
        printf '\n  %sBaşarısız:%s\n' "$RED" "$NC"
        printf '    · %s\n' "${E2E_FAILED_NAMES[@]}"
    fi
    if [ ${#E2E_UNKNOWN_NAMES[@]} -gt 0 ]; then
        printf '\n  %sÖlçülemedi%s (başarısız sayılır — "bilmiyorum" ile "iyi" aynı şey değil):\n' "$RED" "$NC"
        printf '    · %s\n' "${E2E_UNKNOWN_NAMES[@]}"
    fi

    # KAPSAM KAPISI. Atlamalar meşrudur (motor kapalı olabilir) ama çalışan
    # kontrolden ÇOĞU atlandıysa o koşu ürünü ölçmüş sayılmaz. Denetimde
    # üretilen kalıp tam buydu: 4 motordan 3'ü atlandı, 1'i geçti, paket
    # "çalışan kontrollerin hepsi geçti" yazıp ÇIKIŞ 0 verdi — okuyan
    # "replikasyon doğrulandı" anladı, oysa üç motor hiç denenmemişti.
    if [ "$calisan" -gt 0 ] && [ "$E2E_SKIP" -ge "$calisan" ] \
       && [ "$E2E_FAIL" -eq 0 ] && [ "$E2E_UNKNOWN" -eq 0 ]; then
        printf '\n  %sEKSİK KAPSAM:%s ölçülen %d kontrole karşılık %d atlama var.\n' \
            "$YELLOW" "$NC" "$calisan" "$E2E_SKIP"
        printf '  Çalışanlar geçti, ama bu koşu ürünün büyük kısmını ÖLÇMEDİ.\n\n'
        return 3
    fi

    if [ "$calisan" -eq 0 ]; then
        printf '\n  %sHİÇBİR KONTROL ÇALIŞMADI.%s Bu bir başarı değil, ölçüm yapılamadı.\n' \
            "$RED" "$NC"
        printf '  Ön koşullar eksik olabilir: motorlar kapalı, controller çalışmıyor\n'
        printf '  ya da .env okunamıyor. Yukarıdaki ATLANDI sebeplerine bakın.\n\n'
        return 2
    fi
    if [ "$E2E_FAIL" -gt 0 ] || [ "$E2E_UNKNOWN" -gt 0 ]; then
        printf '\n'
        return 1
    fi
    printf '\n  %s✓%s çalışan %d kontrolün hepsi geçti.\n\n' "$GREEN" "$NC" "$calisan"
    return 0
}

# ------------------------------------------------------------- yardımcılar --
# Komut çalıştır; çıkış kodunu VE çıktısını ayrı ayrı ver. Boru hattında
# çıkış kodunun kaybolması (en sık sessiz-yeşil sebebi) böyle engelleniyor.
e2e_run() {          # e2e_run <degisken_adi> <komut...>
    local __var="$1"; shift
    local __out __rc
    __out="$("$@" 2>&1)"; __rc=$?
    printf -v "$__var" '%s' "$__out"
    return $__rc
}

# Bir koşulun gerçekleşmesini bekle. Beklerken NE beklediğini yazar; sonsuz
# bekleme yoktur.
e2e_wait() {         # e2e_wait <saniye> "<açıklama>" <komut...>
    local limit="$1" ne="$2"; shift 2
    local basla; basla=$(date +%s)
    while :; do
        "$@" >/dev/null 2>&1 && return 0
        if [ $(( $(date +%s) - basla )) -ge "$limit" ]; then
            return 1
        fi
        sleep 2
    done
}
