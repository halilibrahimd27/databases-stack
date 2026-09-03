#!/bin/bash
# =============================================================================
# databases-stack — E2E: GERİ YÜKLEME PROVASI (scripts/restore-drill.sh)
# =============================================================================
# Bu paket provanın kendisini sınar. Sorduğu soru "yedek sağlam mı" değil:
#
#     PROVA ARACI DOĞRU SÖYLÜYOR MU, VE ARKASINDA ÇÖP BIRAKIYOR MU?
#
# Sebep: prova, üretim veritabanlarıyla aynı host'ta ikinci bir veritabanı
# açar. Böyle bir aracın iki şekilde zarar vermesi mümkündür ve ikisi de
# sessizdir:
#   1) YANLIŞ SÖYLER — bozuk bir yedeğe "geri yüklendi" der. O zaman prova,
#      olmayan bir güvenceyi belgelemiş olur; verify_backup'ın yerine geçmesi
#      istenen araç, onun yaptığı hatayı daha büyük harflerle yapar.
#   2) SIZDIRIR — geçici container'ı ya da hacmi bırakır. Tek sunuculuk bir
#      yığında bu, üretimin belleğinden ve diskinden çalar; kimse
#      `docker volume ls`ye bakmadığı için haftalarca fark edilmez.
# Bu yüzden buradaki kontrollerin yarısı "doğru cevap verdi mi", yarısı
# "arkasını topladı mı" sorusudur.
#
# ÖLÇÜLENLER
#   · kapsam dışı motorda 0 DEĞİL anlamlı bir kod dönüyor mu
#   · motor verilmeden çağrıldığında ne yapıyor
#   · son satır TEK SATIR ve GEÇERLİ JSON mu (controller bunu okuyacak)
#   · prova geçen bir yedekte ok=true / çıkış 0
#   · BİLEREK BOZULMUŞ bir yedekte ok=false / çıkış 1
#   · geçici container ve hacim SONUNDA gerçekten silinmiş mi
#     (docker ps -a ve docker volume ls ile, hem ADLA hem ETİKETLE)
#   · üretim container'ına ve gateway'e dokunulmamış mı
#     (State.StartedAt değişmemeli)
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/drill.sh              uygun ilk motorla
#     ./scripts/e2e/drill.sh redis        motoru sen seç
#
# Ayarlar (ortam değişkeni):
#     E2E_PROVA_YEDEK_AL=0   yedeği olmayan motor için yedek ALMA (atla)
#     E2E_PROVA_SURESI=…     tek prova için zaman aşımı (sn, varsayılan 1800)
#
# ⚠ YAN ETKİ: prova geçici bir DB container'ı açar (varsayılan bellek tavanı
#   1 GB). Üretim verisine dokunmaz — bu paketin işi zaten bunu KANITLAMAK.
#   Seçilen motorun hiç yedeği yoksa bir yedek ALINIR (E2E_PROVA_YEDEK_AL=0
#   ile kapatılır); yedek almak üretim container'ında dump çalıştırır.
#
# BOZUK DOSYA NEREYE YAZILIYOR: backups/ ALTINA DEĞİL, geçici dizine. Bozuk
# kopyayı yedek dizinine koysaydık `backup.sh list`, `stats` ve sync-remote.sh
# onu geçerli bir kurtarma noktası sayar, hatta uzak sunucuya kopyalardı —
# test, ölçtüğü ürünü bozmuş olurdu.
#
# set -e YOK: her kontrol tek tek raporlanmalı. Sonuç türleri ve çıkış kodu
# ortak kütüphanede (scripts/e2e/lib.sh); "ölçemedik" (t_unknown) BAŞARISIZ
# sayılır, çünkü "bilmiyorum" ile "iyi" aynı şey değildir.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

[ -r scripts/e2e/lib.sh ] \
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi olmadan bu paket ölçüm yapamaz."
E2E_SUITE="drill"
source scripts/e2e/lib.sh

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
PROVA="scripts/restore-drill.sh"
# Çalıştırma izni kaybolmuş bir checkout'ta (Windows'tan kopyalanmış depo,
# unzip edilmiş arşiv) `./betik` "Permission denied" verir. Paket bunu ÜRÜN
# HATASI gibi raporlamasın diye çağrı biçimini burada bir kez seçiyoruz.
PROVA_CAGRI=("./$PROVA")
[ -x "$PROVA" ] || PROVA_CAGRI=(bash "$PROVA")
ETIKET="dbstack-prova"

# ------------------------------------------------------------ zaman aşımı ---
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman_asimi() {
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
SURE_PROVA="${E2E_PROVA_SURESI:-1800}"
SURE_YEDEK="${E2E_PROVA_YEDEK_SURESI:-900}"

# Ölçüm ARACI asıldıysa sonuç "ürün yanlış cevap verdi" değil "ÖLÇEMEDİK"tir:
# timeout(1) zaman aşımında 124, -k ile öldürmek zorunda kalınca 137 döner.
asildi_mi() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }
docker_yasiyor() { docker ps -q >/dev/null 2>&1; }

mkdir -p "$LOG_DIR"
E2E_LOG="$LOG_DIR/e2e-drill_$(date +%Y%m%d_%H%M%S).log"
: > "$E2E_LOG"
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-prova-XXXXXX")" \
    || die "Geçici dizin açılamadı."
temizle() { [ -n "${E2E_TMP:-}" ] && rm -rf "$E2E_TMP" 2>/dev/null; return 0; }
trap 'temizle' EXIT

# =============================================================================
# PROVAYI ÇALIŞTIRAN SARMALAYICI
# =============================================================================
# Provanın üç çıktısı ayrı ayrı lazım: çıkış kodu, TAM metin (container/hacim
# adları oradan okunuyor) ve SON SATIR (JSON). Boru hattında çıkış kodunun
# kaybolması bu paketlerdeki sahte-yeşilin bir numaralı sebebi olduğu için
# çıktı dosyaya alınıp rc ayrıca saklanıyor.
PROVA_RC=0
PROVA_CIKTI=""
PROVA_JSON=""
prova_calistir() {   # prova_calistir <etiket> <argümanlar…>
    local ne="$1"; shift
    PROVA_CIKTI="$E2E_TMP/prova.out"
    PROVA_JSON="$E2E_TMP/prova.json"
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$ne"
      printf 'komut: %s %s\n' "${PROVA_CAGRI[*]}" "$*"; } >> "$E2E_LOG"
    PROVA_RC=0
    # stdin /dev/null: prova onay beklemez ama beklese bile bu paket terminal
    # olmayan bir ortamda sonsuza kadar asılı kalmasın.
    zaman_asimi "$SURE_PROVA" "${PROVA_CAGRI[@]}" "$@" > "$PROVA_CIKTI" 2>&1 \
        < /dev/null || PROVA_RC=$?
    cat "$PROVA_CIKTI" >> "$E2E_LOG"
    tail -n 1 "$PROVA_CIKTI" > "$PROVA_JSON" 2>/dev/null
    return 0
}

son_ozet() {
    tr -d '\r' < "$PROVA_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' \
        | tail -n 2 | tr '\n' ' '
}
kilit_carpismasi() { grep -qaF "kilidi başkasında" "$PROVA_CIKTI" 2>/dev/null; }

# JSON'dan tek alan. rc=2 → dosya JSON DEĞİL (bu da bir bulgudur, ayrı
# raporlanır); rc=3 → alan yok.
json_alan() {   # json_alan <alan>
    python3 - "$PROVA_JSON" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
if not isinstance(d, dict) or sys.argv[2] not in d:
    sys.exit(3)
v = d[sys.argv[2]]
if v is None:   print("null")
elif v is True: print("true")
elif v is False:print("false")
else:           print(v)
PY
}

# Provanın açtığı geçici kaynakların ADLARI. Ad okunamazsa temizlik kontrolü
# "geçti" DİYEMEZ: neyin silinmiş olması gerektiğini bilmiyoruz demektir.
prova_adi() {   # prova_adi <container|hacim>
    local anahtar="$1" satir
    case "$anahtar" in
        container) satir="$(grep -a 'container :' "$PROVA_CIKTI" | tail -1)" ;;
        hacim)     satir="$(grep -a 'hacim     :' "$PROVA_CIKTI" | tail -1)" ;;
        *) return 1 ;;
    esac
    [ -n "$satir" ] || return 1
    # "…container : dbstack-prova-redis-123-2026…  (bellek 1024 MB, ağ yok)"
    satir="${satir#*: }"
    satir="${satir%% *}"
    satir="$(printf '%s' "$satir" | tr -d '\r')"
    case "$satir" in dbstack-prova-*) printf '%s' "$satir" ;; *) return 1 ;; esac
}

# =============================================================================
# MOTOR SEÇİMİ
# =============================================================================
# Sıra ucuzdan pahalıya: prova her motor için ayrı bir container açıp veri
# yüklüyor; mssql tek başına dakikalarca sürer. Paketin işi motorları taramak
# değil, PROVA ARACINI sınamak — bir motor yeter, en ucuz olanı seçiliyor.
SIRA="${E2E_PROVA_MOTOR:-redis mariadb postgresql mongodb mssql}"

kapsamdaki_motorlar() {
    zaman_asimi 60 "${PROVA_CAGRI[@]}" 2>/dev/null \
        | grep -a 'Prova yapılabilen motorlar:' \
        | sed 's/.*motorlar: *//' | tr -d '\r'
}

yedek_bul() {   # yedek_bul <motor>  → en yeni .gz (yoksa rc=1)
    local d="$BACKUP_DIR/$1" y
    [ -d "$d" ] || return 1
    y="$(find "$d" -type f -name '*.gz' ! -name '*.bozuk' -printf '%T@\t%p\n' \
         2>/dev/null | sort -rn | head -1 | cut -f2-)"
    [ -n "$y" ] || return 1
    printf '%s' "$y"
}

MOTOR=""; YEDEK=""; SECIM_NOTU=""
motor_sec() {
    local kapsam eid aday=""
    kapsam="$(kapsamdaki_motorlar)"
    if [ -z "$kapsam" ]; then
        SECIM_NOTU="restore-drill.sh kapsam listesini basmadı — betik çalışıyor mu?"
        return 1
    fi
    for eid in $SIRA; do
        printf '%s\n' "$kapsam" | tr ' ' '\n' | grep -qx "$eid" || continue
        container_running "$(primary_of "$eid")" || continue
        [ -z "$aday" ] && aday="$eid"
        if YEDEK="$(yedek_bul "$eid")"; then MOTOR="$eid"; return 0; fi
    done
    if [ -z "$aday" ]; then
        SECIM_NOTU="prova yapılabilen motorların ($kapsam) hiçbiri çalışmıyor"
        return 1
    fi
    if [ "${E2E_PROVA_YEDEK_AL:-1}" = "0" ]; then
        SECIM_NOTU="$aday çalışıyor ama yedeği yok; E2E_PROVA_YEDEK_AL=0 ile yedek alma kapalı"
        return 1
    fi
    t_info "$aday çalışıyor ama yedeği yok — prova için bir yedek alınıyor…"
    if ! zaman_asimi "$SURE_YEDEK" ./scripts/backup.sh "$aday" >>"$E2E_LOG" 2>&1; then
        SECIM_NOTU="$aday için yedek alınamadı (ayrıntı: $E2E_LOG)"
        return 1
    fi
    if YEDEK="$(yedek_bul "$aday")"; then MOTOR="$aday"; return 0; fi
    SECIM_NOTU="$aday yedeklendi ama dosya bulunamadı: $BACKUP_DIR/$aday"
    return 1
}

# =============================================================================
# KONTROLLER — kapsam ve çıkış kodları
# =============================================================================
# Bu iki kontrol docker'a ihtiyaç duymaz (prova, motor kapsamını backup.sh ve
# catalog.json'dan çözer; docker'a ancak ondan sonra bakar). Bilerek en başta:
# yığın tamamen kapalıyken bile paket EN AZ BİR ŞEY ölçmüş olur, yoksa "hiçbir
# kontrol çalışmadı" (çıkış 2) ile "her şey yeşil" ayrımı kaybolurdu.
kontrol_kapsam_disi() {
    local ad="kapsam dışı motor 0 DEĞİL anlamlı bir kod döndürüyor (cassandra)"
    prova_calistir "kapsam dışı motor" cassandra
    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad" "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        return 0
    fi
    if [ "$PROVA_RC" -eq 2 ]; then
        t_ok "$ad — çıkış 2 (kapsam dışı), hata koduyla karışmıyor"
    elif [ "$PROVA_RC" -eq 0 ]; then
        t_fail "$ad" \
               "çıkış 0: geri yüklemesi OLMAYAN bir motor için prova BAŞARILI görünüyor"
    else
        t_fail "$ad" "beklenen çıkış 2, gelen $PROVA_RC: $(son_ozet)"
    fi

    local ad2="kapsam dışı çağrıda da son satır JSON (controller boş çıktı görmüyor)"
    local ok_alan
    if ! ok_alan="$(json_alan ok)"; then
        t_fail "$ad2" "son satır geçerli JSON değil: $(tail -c 200 "$PROVA_JSON" | tr -d '\r\n')"
    elif [ "$ok_alan" = "false" ]; then
        t_ok "$ad2"
    else
        t_fail "$ad2" "ok=$ok_alan — prova yapılmadığı hâlde olumlu görünüyor"
    fi
}

kontrol_argumansiz() {
    local ad="motor verilmeden çağrıldığında kullanımı basıp 0 DEĞİL kod dönüyor"
    prova_calistir "argümansız"
    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad" "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        return 0
    fi
    if [ "$PROVA_RC" -eq 0 ]; then
        t_fail "$ad" "çıkış 0 — hiçbir şey yapılmadığı hâlde başarı bildiriliyor"
    elif grep -qa 'restore-drill.sh <motor>' "$PROVA_CIKTI"; then
        t_ok "$ad (çıkış $PROVA_RC, kullanım basıldı)"
    else
        t_fail "$ad" "çıkış $PROVA_RC ama kullanım metni yok: $(son_ozet)"
    fi
}

# =============================================================================
# KONTROLLER — asıl prova
# =============================================================================
POZITIF_C=""; POZITIF_V=""; BOZUK_C=""; BOZUK_V=""

kontrol_pozitif() {
    local ad="prova geçen bir yedekte ok=true diyor ve 0 ile çıkıyor"
    local ad_json="son satır TEK SATIR ve geçerli JSON"
    local ad_sayi="ölçülen RTO ve sayımlar JSON'da SAYI olarak var"

    prova_calistir "pozitif prova ($MOTOR)" "$MOTOR" "$YEDEK"
    POZITIF_C="$(prova_adi container || true)"
    POZITIF_V="$(prova_adi hacim || true)"

    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad"      "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        t_unknown "$ad_json" "prova bitmedi"
        t_unknown "$ad_sayi" "prova bitmedi"
        return 0
    fi
    if kilit_carpismasi; then
        t_skip "$ad"      "yedekleme kilidi başkasında — prova koşulamadı"
        t_skip "$ad_json" "prova koşulamadı (kilit başkasında)"
        t_skip "$ad_sayi" "prova koşulamadı (kilit başkasında)"
        return 0
    fi
    if [ "$PROVA_RC" -eq 3 ]; then
        t_unknown "$ad"      "prova ÖLÇEMEDİ (çıkış 3): $(son_ozet)"
        t_unknown "$ad_json" "prova ölçemedi"
        t_unknown "$ad_sayi" "prova ölçemedi"
        return 0
    fi

    # --- JSON biçimi ---------------------------------------------------------
    local satir_sayisi ok_alan sn rt rr
    satir_sayisi="$(wc -l < "$PROVA_JSON" | tr -d '[:space:]')"
    if ! ok_alan="$(json_alan ok)"; then
        t_fail "$ad_json" "son satır JSON olarak ayrıştırılamadı: $(tail -c 200 "$PROVA_JSON" | tr -d '\r\n')"
    elif [ "${satir_sayisi:-0}" -gt 1 ]; then
        t_fail "$ad_json" "son satır $satir_sayisi satır — controller tek satır bekliyor"
    else
        t_ok "$ad_json"
    fi

    # --- asıl cevap ----------------------------------------------------------
    if [ "$PROVA_RC" -eq 0 ] && [ "${ok_alan:-}" = "true" ]; then
        t_ok "$ad ($MOTOR, $(basename "$YEDEK"))"
    elif [ "$PROVA_RC" -eq 4 ]; then
        # 4 = prova geçti ama temizlik yapılamadı. Cevap doğru, arkası kirli;
        # ikisini ayrı raporluyoruz ki temizlik kontrolü suçu üstlensin.
        t_fail "$ad" "çıkış 4: prova geçti ama TEMİZLİK yapılamadı — $(son_ozet)"
    else
        t_fail "$ad" \
               "çıkış $PROVA_RC, ok=${ok_alan:-okunamadı}. Sağlam bir yedek geri yüklenemedi: $(son_ozet)"
    fi

    # --- sayılar -------------------------------------------------------------
    sn="$(json_alan seconds || true)"
    rt="$(json_alan restored_tables || true)"
    rr="$(json_alan restored_rows || true)"
    case "${sn:-x}${rt:-x}${rr:-x}" in
        *[!0-9]*) t_fail "$ad_sayi" \
                  "seconds=${sn:-yok} restored_tables=${rt:-yok} restored_rows=${rr:-yok} — en az biri sayı değil" ;;
        *)        t_ok "$ad_sayi (RTO ${sn} sn, $rt tablo, $rr satır)"
                  local es; es="$(json_alan match || true)"
                  case "$es" in
                      true)  t_info "üretimle karşılaştırma: eşleşti" ;;
                      false) t_info "üretimle karşılaştırma: eşleşmedi (yedekten sonra yazılmış olabilir)" ;;
                      *)     t_info "üretimle karşılaştırma: ölçülemedi (match=null)" ;;
                  esac ;;
    esac
}

# =============================================================================
# AYIRT EDİCİ KONTROL — satır sayısının GÖREMEDİĞİ kayıp
# =============================================================================
# Prova bugüne kadar yalnız tablo ve satır sayıyordu. İndeks, kısıt, view,
# trigger ve rutin kaybı bu ölçütten sessizce geçiyordu — yani "prova geçti"
# rozeti, ölçmediği bir şeyi iddia ediyordu.
#
# Bu kontrolün tamamı o iddiayı sınamak için: öyle bir durum kuruyoruz ki
# ESKİ ölçüt "birebir eşleşti" desin, YENİ ölçüt farkı görsün. İkisi aynı
# cevabı verirse yeni ölçüt hiçbir şey eklemiyor demektir ve kontrol
# BAŞARISIZ olmalı — "her ikisi de geçti" bir kanıt değildir.
SEMA_TABLO="e2e_sema_kanit"

sema_sql() {   # sema_sql <ifade>
    case "$MOTOR" in
    mariadb)
        docker exec -e MYSQL_PWD="$SEMA_PAROLA" "$URETIM_C" \
            mariadb -u"$SEMA_KULLANICI" -D "$SEMA_DB" -N -B -e "$1" 2>>"$E2E_LOG" ;;
    postgresql)
        docker exec -e PGPASSWORD="$SEMA_PAROLA" "$URETIM_C" \
            psql -U "$SEMA_KULLANICI" -d "$SEMA_DB" -tAq -v ON_ERROR_STOP=1 \
            -c "$1" 2>>"$E2E_LOG" ;;
    *)  return 1 ;;
    esac
}

sema_hazirla() {
    SEMA_DB="${DEFAULT_DATABASE:-defaultdb}"
    case "$MOTOR" in
    mariadb)
        SEMA_KULLANICI="root"
        SEMA_PAROLA="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}" ;;
    postgresql)
        SEMA_KULLANICI="${POSTGRES_USER:-root}"
        SEMA_PAROLA="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}" ;;
    *)  return 1 ;;
    esac
    [ -n "$SEMA_PAROLA" ] || return 1
    sema_sql "DROP TABLE IF EXISTS $SEMA_TABLO;" >/dev/null || return 1
    sema_sql "CREATE TABLE $SEMA_TABLO (id INT PRIMARY KEY, x INT);" >/dev/null || return 1
    sema_sql "INSERT INTO $SEMA_TABLO VALUES (1,10),(2,20),(3,30);" >/dev/null || return 1
    sema_sql "CREATE INDEX ix_e2e_sema ON $SEMA_TABLO (x);" >/dev/null || return 1
    return 0
}

sema_temizle() {
    [ -n "${SEMA_DB:-}" ] || return 0
    sema_sql "DROP TABLE IF EXISTS $SEMA_TABLO;" >/dev/null 2>&1 || true
}

kontrol_sema_ayirt_edici() {
    local ad="şema kaybını görüyor (satır sayısı GÖREMEZ)"
    case "$MOTOR" in
        mariadb|postgresql) ;;
        *) t_skip "$ad" "$MOTOR için şema sayımı yazılmadı"; return 0 ;;
    esac
    if ! sema_hazirla; then
        t_unknown "$ad" "kanıt tablosu kurulamadı (parola/erişim) — ayrıntı: $E2E_LOG"
        return 0
    fi
    # Yedek ŞİMDİ alınıyor: içinde indeks VAR.
    if ! zaman_asimi "$SURE_YEDEK" "$STACK_ROOT/scripts/backup.sh" "$MOTOR" \
            >>"$E2E_LOG" 2>&1; then
        sema_temizle
        t_unknown "$ad" "yedek alınamadı — ayrıntı: $E2E_LOG"
        return 0
    fi
    # Üretimden YALNIZ indeksi düşürüyoruz: satır sayısı DEĞİŞMİYOR.
    if ! sema_sql "DROP INDEX ix_e2e_sema ON $SEMA_TABLO;" >/dev/null 2>&1 \
       && ! sema_sql "DROP INDEX ix_e2e_sema;" >/dev/null 2>&1; then
        sema_temizle
        t_unknown "$ad" "indeks düşürülemedi — ayrıntı: $E2E_LOG"
        return 0
    fi

    prova_calistir "şema ayırt ediciliği ($MOTOR)" "$MOTOR"
    local es sema_es ri pi
    es="$(json_alan match || true)"
    sema_es="$(json_alan schema_match || true)"
    ri="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
s=d.get('restored_schema') or {}
print(s.get('index','yok'))" "$PROVA_JSON" 2>/dev/null || true)"
    pi="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
s=d.get('prod_schema') or {}
print(s.get('index','yok'))" "$PROVA_JSON" 2>/dev/null || true)"
    sema_temizle

    if [ -z "$es" ] || [ -z "$sema_es" ]; then
        t_unknown "$ad" "prova JSON'ı okunamadı (match=$es schema_match=$sema_es)"
        return 0
    fi
    # ESKİ ÖLÇÜT KÖR OLMALI: satır sayıları eşit. Değilse kurgu tutmamıştır
    # ve bu kontrol bir şey kanıtlamaz — 'ölçemedik' diyoruz.
    if [ "$es" != "true" ]; then
        t_unknown "$ad" \
            "kurgu tutmadı: satır sayıları da farklı çıktı (match=$es) — ayırt edicilik gösterilemedi"
        return 0
    fi
    if [ "$sema_es" = "false" ] && [ "${ri:-0}" != "${pi:-0}" ]; then
        t_ok "$ad" "satır sayısı eşit (match=true) ama indeks $ri≠$pi — eski ölçüt bunu göremezdi"
    else
        t_fail "$ad" \
            "düşürülen indeks fark edilmedi: schema_match=$sema_es, kopya indeks=$ri üretim indeks=$pi"
    fi
}

kontrol_bozuk() {
    local ad="BOZULMUŞ bir yedekte ok=false diyor ve 1 ile çıkıyor"
    local bozuk boyut yari
    boyut="$(wc -c < "$YEDEK" 2>/dev/null | tr -d '[:space:]')"
    case "${boyut:-}" in ''|*[!0-9]*)
        t_unknown "$ad" "yedek dosyasının boyutu okunamadı: $YEDEK"; return 0 ;;
    esac
    if [ "$boyut" -lt 32 ]; then
        t_unknown "$ad" "yedek $boyut bayt — kesip bozulacak kadar bile değil"
        return 0
    fi
    # ORTADAN KESİYORUZ, çöp EKLEMİYORUZ. Sahada görülen bozulma budur: dump
    # borusunun sol tarafı ölür, dosyanın BAŞI kusursuz kalır. Başına çöp
    # yazsaydık her araç ilk baytta reddederdi ve test hiçbir şey kanıtlamazdı;
    # asıl soru "başı doğru, sonu yok" dosyayı yakalıyor mu.
    yari=$(( boyut / 2 ))
    bozuk="$E2E_TMP/$(basename "$YEDEK")"
    if ! head -c "$yari" "$YEDEK" > "$bozuk" 2>>"$E2E_LOG"; then
        t_unknown "$ad" "bozuk kopya üretilemedi: $bozuk"
        return 0
    fi
    t_info "bozuk kopya: $boyut bayt → $yari bayt (yedek dizinine DEĞİL, $E2E_TMP altına)"

    prova_calistir "bozuk yedek provası ($MOTOR)" "$MOTOR" "$bozuk"
    BOZUK_C="$(prova_adi container || true)"
    BOZUK_V="$(prova_adi hacim || true)"

    if asildi_mi "$PROVA_RC"; then
        t_unknown "$ad" "prova $SURE_PROVA sn içinde bitmedi (rc=$PROVA_RC)"
        return 0
    fi
    if kilit_carpismasi; then
        t_skip "$ad" "yedekleme kilidi başkasında — prova koşulamadı"
        return 0
    fi
    local ok_alan detay
    ok_alan="$(json_alan ok || true)"
    detay="$(json_alan detail 2>/dev/null || true)"
    if [ "$PROVA_RC" -eq 0 ] || [ "$ok_alan" = "true" ]; then
        t_fail "$ad" \
               "yarısı kesilmiş bir yedek için çıkış $PROVA_RC / ok=$ok_alan — prova bozuk dosyaya 'geri yüklendi' diyor"
    elif [ "$PROVA_RC" -eq 1 ] && [ "$ok_alan" = "false" ]; then
        if [ -n "$detay" ] && [ "$detay" != "null" ]; then
            t_ok "$ad (detail NEDENİ söylüyor)"
        else
            t_fail "$ad" "ok=false doğru ama detail boş — operatör NEDENİNİ göremiyor"
        fi
    elif [ "$PROVA_RC" -eq 3 ]; then
        t_unknown "$ad" "prova ÖLÇEMEDİ (çıkış 3): $(son_ozet)"
    else
        t_fail "$ad" "ok=$ok_alan ama çıkış $PROVA_RC (beklenen 1): $(son_ozet)"
    fi
}

# =============================================================================
# KONTROLLER — sızıntı ve üretime dokunmama
# =============================================================================
yok_mu() {   # yok_mu <container|hacim> <ad> → 0 gerçekten yok
    case "$1" in
        container) ! docker ps -a --format '{{.Names}}' 2>/dev/null \
                       | grep -qx "$2" ;;
        hacim)     ! docker volume ls -q 2>/dev/null | grep -qx "$2" ;;
    esac
}

kontrol_temizlik() {
    local ad_c="geçici container SONUNDA gerçekten silinmiş (docker ps -a)"
    local ad_v="geçici hacim SONUNDA gerçekten silinmiş (docker volume ls)"
    local ad_e="etiketli hiçbir kalıntı kalmamış (label=$ETIKET)"

    if ! docker_yasiyor; then
        t_unknown "$ad_c" "docker cevap vermiyor — kalıntı olup olmadığı ölçülemedi"
        t_unknown "$ad_v" "docker cevap vermiyor"
        t_unknown "$ad_e" "docker cevap vermiyor"
        return 0
    fi

    # ADLARI provanın kendi çıktısından okuduk. Okunamadıysa "temizlik geçti"
    # DEMİYORUZ: neyin silinmiş olması gerektiğini bilmiyoruz. Bu ayrım
    # olmadan, hiç container açmadan düşen bir prova da "tertemiz" görünürdü.
    local adlar="" ad
    for ad in "$POZITIF_C" "$BOZUK_C"; do [ -n "$ad" ] && adlar="$adlar $ad"; done
    if [ -z "$adlar" ]; then
        t_unknown "$ad_c" "provanın açtığı container adı çıktısından okunamadı"
    else
        local kalan=""
        for ad in $adlar; do yok_mu container "$ad" || kalan="$kalan $ad"; done
        if [ -n "$kalan" ]; then
            t_fail "$ad_c" "docker ps -a hâlâ görüyor:$kalan"
        else
            t_ok "$ad_c ($(printf '%s' "$adlar" | wc -w) container)"
        fi
    fi

    adlar=""
    for ad in "$POZITIF_V" "$BOZUK_V"; do [ -n "$ad" ] && adlar="$adlar $ad"; done
    if [ -z "$adlar" ]; then
        t_unknown "$ad_v" "provanın açtığı hacim adı çıktısından okunamadı"
    else
        local kalanv=""
        for ad in $adlar; do yok_mu hacim "$ad" || kalanv="$kalanv $ad"; done
        if [ -n "$kalanv" ]; then
            t_fail "$ad_v" "docker volume ls hâlâ görüyor:$kalanv"
        else
            t_ok "$ad_v ($(printf '%s' "$adlar" | wc -w) hacim)"
        fi
    fi

    # Etiket taraması ADI tamamlar, onun yerine geçmez: adını okuyamadığımız
    # (ör. yarıda ölen) bir kalıntıyı ancak bu yakalar.
    local ec ev
    ec="$(docker ps -aq --filter "label=$ETIKET" 2>/dev/null | wc -l | tr -d '[:space:]')"
    ev="$(docker volume ls -q --filter "label=$ETIKET" 2>/dev/null | wc -l | tr -d '[:space:]')"
    case "${ec:-x}${ev:-x}" in
        *[!0-9]*) t_unknown "$ad_e" "etiket taraması yapılamadı" ;;
        *) if [ "$ec" -eq 0 ] && [ "$ev" -eq 0 ]; then
               t_ok "$ad_e"
           else
               t_fail "$ad_e" "$ec container + $ev hacim etiketli kalıntı duruyor"
           fi ;;
    esac
}

# Üretime dokunmama ölçütü State.StartedAt: prova üretim container'ını
# yeniden başlatsaydı (ya da restore_redis gibi durdurup açsaydı) bu damga
# değişirdi. Ayrıca hâlâ ÇALIŞIYOR olmalı — durdurulmuş bir container'ın
# StartedAt'i de değişmez, o yüzden ikisine birden bakıyoruz.
BASLANGIC_DAMGA=""
damga_al() {   # damga_al <container>
    docker inspect -f '{{.State.StartedAt}}|{{.State.Running}}' "$1" 2>/dev/null
}
kontrol_uretim_dokunulmadi() {   # kontrol_uretim_dokunulmadi <ad> <container> <önceki>
    local ad="$1" C="$2" once="$3" sonra
    if [ -z "$once" ]; then
        t_skip "$ad" "$C bu koşumun başında çalışmıyordu — karşılaştırılacak damga yok"
        return 0
    fi
    sonra="$(damga_al "$C")"
    if [ -z "$sonra" ]; then
        t_unknown "$ad" "$C artık docker inspect ile okunamıyor — durumu ÖLÇÜLEMEDİ"
        return 0
    fi
    if [ "$once" = "$sonra" ]; then
        t_ok "$ad ($C, StartedAt değişmedi)"
    else
        t_fail "$ad" "$C durumu değişti: önce [$once] sonra [$sonra]"
    fi
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
BASLANGIC="$(date +%s)"
heading "E2E geri yükleme provası — $(date '+%Y-%m-%d %H:%M')"
[ -x "$PROVA" ] || t_info "$PROVA çalıştırma izni yok; 'bash' ile çağrılacak."
[ -f "$PROVA" ] || die "$PROVA yok — bu paket onu sınamak için var."

t_head "Kapsam ve çıkış kodları"
kontrol_kapsam_disi
kontrol_argumansiz

t_head "Prova: sağlam yedek · bozuk yedek"
if ! docker_yasiyor; then
    t_unknown "prova geçen bir yedekte ok=true diyor"  "docker cevap vermiyor"
    t_unknown "BOZULMUŞ bir yedekte ok=false diyor"    "docker cevap vermiyor"
    t_unknown "geçici container/hacim silinmiş"        "docker cevap vermiyor"
    t_unknown "üretim container'ına dokunulmamış"      "docker cevap vermiyor"
elif ! motor_sec; then
    t_skip "prova geçen bir yedekte ok=true diyor" "$SECIM_NOTU"
    t_skip "BOZULMUŞ bir yedekte ok=false diyor"   "$SECIM_NOTU"
    t_skip "geçici container/hacim silinmiş"       "$SECIM_NOTU"
    t_skip "üretim container'ına dokunulmamış"     "$SECIM_NOTU"
else
    URETIM_C="$(primary_of "$MOTOR")"
    URETIM_DAMGA="$(damga_al "$URETIM_C")"
    GATEWAY_DAMGA="$(damga_al gateway)"
    t_info "motor: $MOTOR · üretim container: $URETIM_C"
    t_info "yedek: $YEDEK"

    kontrol_pozitif
    kontrol_bozuk

    t_head "Şema kaybı — 'prova geçti' rozetinin göremediği"
    kontrol_sema_ayirt_edici

    t_head "Sızıntı ve üretime dokunmama"
    kontrol_temizlik
    kontrol_uretim_dokunulmadi \
        "üretim container'ına dokunulmamış" "$URETIM_C" "$URETIM_DAMGA"
    kontrol_uretim_dokunulmadi \
        "gateway'e dokunulmamış" "gateway" "$GATEWAY_DAMGA"
fi

# ------------------------------------------------------------------- özet ---
SURE=$(( $(date +%s) - BASLANGIC ))
t_info "süre: $((SURE / 60))m $((SURE % 60))s"
if [ "$E2E_FAIL" -eq 0 ] && [ "$E2E_UNKNOWN" -eq 0 ]; then
    rm -f "$E2E_LOG"
else
    t_info "komut çıktılarının tamamı: $E2E_LOG"
fi

# Sayaçlar, özet ve ÇIKIŞ KODU ortak kütüphanede (scripts/e2e/lib.sh):
#   0 çalışan kontrollerin hepsi geçti · 1 başarısız/ölçülemedi var
#   2 HİÇBİR KONTROL ÇALIŞMADI · 3 eksik kapsam
e2e_finish
exit $?
