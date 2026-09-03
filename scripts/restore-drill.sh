#!/bin/bash
# =============================================================================
# databases-stack — GERİ YÜKLEME PROVASI (restore drill)
# =============================================================================
#   ./scripts/restore-drill.sh <motor> [dosya]
#
# NEDEN VAR:
# backup.sh'ın verify_backup'ı üç soru sorar: dosya boş mu, gzip akışı sonuna
# kadar sağlam mı, içinde o motorun biçiminden bir iz var mı. ÜÇÜ DE DOSYA
# HAKKINDA sorulardır; hiçbiri "bu dosya geri yüklenir mi" sorusunu
# cevaplamaz. Bir dump bu üç testten de geçip yine de geri yüklenmeyebilir:
# sunucu sürümü uyumsuz olabilir, .bak farklı bir SQL Server sürümünde
# açılmayabilir, arşivin içindeki dosya adları geri yükleyicinin aradığından
# başka olabilir. Bu betik o soruyu tek geçerli yoldan cevaplar: yedeği
# GERÇEKTEN geri yükler ve sonucu SAYAR.
#
# NEYE DOKUNUR, NEYE DOKUNMAZ:
#   • TEK KULLANIMLIK bir container + TEK KULLANIMLIK bir hacim açar.
#   • Geçici container '--network none' ile açılır: üretim container'ına,
#     gateway'e ya da yığın ağına giden bir yolu YOKTUR. Bu, "dokunmuyoruz"
#     sözünü niyete değil çekirdeğe bağlar.
#   • Üretim tarafında yaptığı TEK iş, karşılaştırma için sayı okumaktır
#     (yalnız SELECT / INFO). Üretim kapalıysa okumaz — ve "ölçülemedi" der,
#     sessizce geçmez.
#
# ÇIKIŞ KODLARI (kapsam dışı ile hata birbirine KARIŞMASIN diye ayrı):
#   0  prova geçti — yedek gerçekten geri yüklendi
#   1  prova DÜŞTÜ — yedek geri yüklenemedi ya da kopya boş çıktı
#   2  KAPSAM DIŞI — bu motorda geri yükleme yok (ya da motor tanınmıyor)
#   3  ÖLÇÜLEMEDİ — yedek dosyası yok, docker yok, kilit başkasında…
#      Prova hiç YAPILAMADI; bu "yedek bozuk" demek DEĞİLDİR.
#   4  prova bitti ama TEMİZLİK yapılamadı — geçici container/hacim SIZDI.
#      Tek sunuculuk bir yığında sızan bir DB container'ı üretimin belleğini
#      yer; bu yüzden provanın kendi sonucundan bağımsız olarak bu kod
#      basılır. Provanın gerçek cevabı JSON'daki "ok" alanındadır.
#
# SON SATIR HER ZAMAN TEK SATIR JSON'DUR (controller bunu okur):
#   {"engine":…,"file":…,"ok":…,"seconds":…,"restored_tables":…,
#    "restored_rows":…,"prod_tables":…,"prod_rows":…,"match":…,
#    "cleanup":…,"detail":"…"}
# prod_tables/prod_rows/match, üretim kapalıyken JSON null'dur — false DEĞİL.
# "Eşleşmedi" ile "karşılaştıramadım" aynı şey değildir; false yazsaydık
# panel, kapalı bir motoru "yedeği tutmuyor" diye gösterirdi.
# seconds HER ZAMAN bir tam sayıdır (null değil): ÖLÇÜLEN RTO. Geri yükleme
# tamamlanmadıysa 0'dır — yani "0 saniyede geri geldi" değil, "geri gelmedi";
# o hâlde ok zaten false ve sebebi detail'de yazar. Alanın tipini sabit
# tutuyoruz ki controller her satırı aynı şekilde ayrıştırabilsin.
#
# ALAN ADLARI HER MOTORDA AYNI, ANLAMLARI MOTORA GÖRE:
#   mariadb/postgresql/mssql : tablo = tablo,      satır = satır
#   mongodb                  : tablo = koleksiyon, satır = belge
#   redis                    : tablo = dolu dbN,   satır = anahtar
# Motora göre alan adı üretmek yerine anlamı "detail"e yazıyoruz: controller
# tek bir şema okusun, motor eklendikçe şema değişmesin.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3
source scripts/lib/common.sh
load_env

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
LOG_FILE="$LOG_DIR/restore-drill_$(date +%Y%m%d).log"
mkdir -p "$LOG_DIR"
# Günlük dosyası GÜN ADIYLA açılır ve ona hem controller (container'da
# root) hem de buradaki kullanıcı yazar. İlk yazan sahibi olur; mod
# açılmazsa ikinci yazan o gün boyunca hiç çalışamaz.
paylasilan_dosya "$LOG_FILE"

# Etiket çöp toplamak içindir: yarıda ölen bir provanın (kill -9, host
# yeniden başladı) container'ı ADIYLA aranamaz — adında o koşumun PID'i var.
# Etiket ise sabittir, sonraki koşum kalıntıyı ondan bulur.
ETIKET="dbstack-prova"
# GÖLGE HACMİ AYRI ETİKET TAŞIR. Prova kalıntı süpürücüsü "label=dbstack-prova"
# olan HER hacmi siliyor; gölgenin saklanan hacmi o etiketi taşısaydı bir
# sonraki prova koşumu, üretimin geri dönüş biletini sessizce silerdi.
ETIKET_GOLGE="dbstack-golge"
# Gölge için diskte istenen emniyet payı. Kapı "yer yok" derse ürün felaket
# anında kilitlenmemeli: klasik (tek yönlü) geri yükleme hâlâ mümkün ve
# mesajda sayılarla söyleniyor.
GOLGE_EMNIYET_MB="${GOLGE_EMNIYET_MB:-2048}"

KILIT="$STACK_ROOT/state/backup.lock"

# ---------------------------------------------------------------- günlük ---
dlog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
dok()  { ok  "$*"; printf '[%s] [OK] %s\n'  "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
derr() { err "$*"; printf '[%s] [ERR] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# ------------------------------------------------------------ zaman aşımı ---
# Hiçbir bekleme sonsuz değil: askıda kalmış bir prova hem "sürüyor" görünür
# hem de yedekleme kilidini tutmaya devam edip gece yedeğini öldürür.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman() {   # zaman <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}

SURE_YUKLEME="${PROVA_YUKLEME_SURESI:-3600}"
SURE_SORGU="${PROVA_SORGU_SURESI:-300}"

# ------------------------------------------------------------------ bellek --
# NEDEN SINIRLI VE NEDEN BU KADAR:
# Prova, üretim veritabanlarıyla AYNI host'ta ikinci bir veritabanı açar.
# Sınırsız bırakılırsa geri yükleme sırasında sayfa havuzunu şişirip üretimin
# belleğini yer — backup.sh'ın başındaki OOM hikâyesi (MariaDB'nin 172 kez
# yeniden başlaması) tam olarak "aynı host'ta iki ağır iş" hikâyesidir.
# Tavan 1 GB: katalogdaki motor tabanlarının (resources.min_mb — mariadb 512,
# postgresql 512, mongodb 512, redis 128) iki katı, üretim MariaDB'sinin
# varsayılan limitinin (MARIADB_MEM_LIMIT=8G) sekizde biri. Geri yükleme tek
# iş parçacıklı bir akıştır; hızını disk belirler, büyük tampon havuzu değil.
# TABAN KATALOGTAN OKUNUYOR — ürünün kendi "bu motor bunun altında çalışmaz"
# sayısı orada duruyor. MSSQL bunun görünür istisnası (min_mb=2048): SQL
# Server 2 GB'ın altında AÇILMAZ; sabit 1 GB yazsaydık mssql provası her
# koşumda "container ayakta kalmadı" derdi ve suç yedeğe atılırdı.
# --memory-swap = --memory ⇒ takas KAPALI. Takasa düşen bir geri yükleme hem
# saatler sürer hem de ölçtüğümüz RTO'yu anlamsız kılar; yanlış bir sayı
# basmaktansa container'ın OOM ile ölmesi ve bunu SÖYLEMEMİZ yeğdir.
PROVA_MEM_MB="${PROVA_MEM_MB:-1024}"
# --cpu-shares yalnızca ÇEKİŞME anında devreye giren bir ağırlıktır: host
# boştayken prova tam hızda koşar (RTO ölçümü gerçekçi kalır), üretim CPU
# istediğinde prova geri çekilir. Sabit bir --cpus tavanı ikisini de bozardı.
PROVA_CPU_SHARES="${PROVA_CPU_SHARES:-512}"

# ------------------------------------------------------------- JSON çıktı ---
# Son satır, ölçüm araçlarının hepsi bozulsa bile basılmalı; bu yüzden
# python3'e bağlanmıyoruz. Kaçırılması JSON'u bozacak karakterler bunlar.
js() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\t'/ }"
    printf '"%s"' "$s"
}

# --golge her yerde olabilir: "restore-drill.sh mariadb --golge" da,
# "restore-drill.sh mariadb dosya.sql.gz --golge" da çalışsın.
GOLGE=0
_ARGS=()
for _a in "$@"; do
    case "$_a" in
        --golge|--gölge) GOLGE=1 ;;
        *) _ARGS+=("$_a") ;;
    esac
done
MOTOR="${_ARGS[0]:-}"
DOSYA="${_ARGS[1]:-}"
KUSAK=null
HACIM_SAKLANDI=false
OK=false
SANIYE=0
R_TABLO=null; R_SATIR=null
P_TABLO=null; P_SATIR=null
ESLESME=null
TEMIZ=true
DETAY="prova başlatılmadı"
JSON_BASILDI=0
PROVA_C=""; HACIM=""; IMAJ=""; MEM_MB="$PROVA_MEM_MB"; GECICI=""
HATA=""

# Beş sayıyı adlandırılmış JSON'a çeviriyor. Boşsa null: "ölçülemedi" ile
# "hepsi sıfır" aynı şey değil.
sema_json() {   # sema_json "<i k v g r>"
    local -a a
    [ -n "${1:-}" ] || { printf 'null'; return 0; }
    read -ra a <<< "$1"
    [ "${#a[@]}" -eq 5 ] || { printf 'null'; return 0; }
    printf '{"index":%s,"constraint":%s,"view":%s,"trigger":%s,"routine":%s}' \
        "${a[0]}" "${a[1]}" "${a[2]}" "${a[3]}" "${a[4]}"
}

json_bas() {
    [ "$JSON_BASILDI" -eq 1 ] && return 0
    JSON_BASILDI=1
    local _satir
    _satir="$(
        printf '{"engine":%s,"file":%s,"ok":%s,"seconds":%s,"restored_tables":%s,"restored_rows":%s,"prod_tables":%s,"prod_rows":%s,"match":%s,"restored_schema":%s,"prod_schema":%s,"schema_match":%s,"cleanup":%s,"shadow":%s,"volume":%s,"generation":%s,"kept":%s,"detail":%s}\n' \
            "$(js "$MOTOR")" "$(js "$DOSYA")" "$OK" "$SANIYE" \
            "$R_TABLO" "$R_SATIR" "$P_TABLO" "$P_SATIR" "$ESLESME" \
            "$(sema_json "${R_SEMA:-}")" "$(sema_json "${P_SEMA:-}")" \
            "${SEMA_ESLESME:-null}" \
            "$TEMIZ" "$([ "$GOLGE" -eq 1 ] && echo true || echo false)" \
            "$(js "$HACIM")" "$KUSAK" "$HACIM_SAKLANDI" "$(js "$DETAY")"
    )"
    printf '%s\n' "$_satir"
    # SONUÇ TEK DEFTERE DE YAZILIR. Bu satır olmadan komut satırından
    # koşan prova panelde HİÇ GÖRÜNMÜYORDU: ölçüm yapılmış, sayı
    # bulunmuş, ama defteri yalnız controller yazdığı için sonuç
    # kayboluyordu. Kaynağı da yazıyoruz (elle / zamanlı) — yedek
    # listesindeki kaynak etiketinin aynısı.
    case "${CIKIS_KODU:-0}" in 2) return 0 ;; esac
    # GÖLGE PROVA DEĞİLDİR: haftalık prova defterine yazarsa panel "prova
    # geçti" der, oysa yapılan şey üretimin yeni kuşağını hazırlamaktı.
    # İki iş ayrı defterlerde durur.
    if [ "$GOLGE" -eq 1 ]; then
        sonuc_defterine_yaz "$STACK_ROOT/state/shadow.json" "$MOTOR" "$_satir" \
            "${DEFTER_KAYNAK:-elle}" 2>/dev/null || true
    else
        sonuc_defterine_yaz "$STACK_ROOT/state/drill.json" "$MOTOR" "$_satir" \
            "${DEFTER_KAYNAK:-elle}" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------------- temizlik -
# HER DURUMDA çalışır (başarı, hata, Ctrl+C). Sessizce sızdırmak yasak:
# silinemeyen her şey ADIYLA hem ekrana hem JSON'a yazılır.
TEMIZ_YAPILDI=0
temizle() {
    [ "$TEMIZ_YAPILDI" -eq 1 ] && return 0
    TEMIZ_YAPILDI=1
    local kalan="" i
    if [ -n "$PROVA_C" ] && docker inspect "$PROVA_C" >/dev/null 2>&1; then
        docker rm -f "$PROVA_C" >>"$LOG_FILE" 2>&1
        docker inspect "$PROVA_C" >/dev/null 2>&1 && kalan="container:$PROVA_C"
    fi
    # GÖLGE KİPİ: doğrulanmış hacim SAKLANIR — zaten bütün mesele o.
    # Ama yalnız doğrulama GEÇTİYSE: düşen bir gölge, diskte adı üretim
    # hacmine benzeyen ve içi güvenilmez bir kopya bırakırdı. En tehlikeli
    # kalıntı türü budur, çünkü bir sonraki koşum onu "var zaten" diye
    # görüp kuşak numarasını atlar.
    if [ "$GOLGE" -eq 1 ] && [ "$OK" = "true" ] && [ -n "$HACIM" ]; then
        HACIM_SAKLANDI=true
        dlog "gölge hacim SAKLANIYOR: $HACIM"
    elif [ -n "$HACIM" ] && docker volume inspect "$HACIM" >/dev/null 2>&1; then
        # Container kaydı silinene kadar hacim "in use" görünebiliyor; tek
        # denemede pes etmek her provada bir hacim bırakırdı. Diskteki
        # sızıntı en sinsisidir: kimse `docker volume ls`ye bakmaz.
        i=0
        while [ "$i" -lt 10 ]; do
            docker volume rm "$HACIM" >>"$LOG_FILE" 2>&1 && break
            i=$((i+1)); sleep 1
        done
        docker volume inspect "$HACIM" >/dev/null 2>&1 \
            && kalan="${kalan:+$kalan, }hacim:$HACIM"
    fi
    [ -n "$GECICI" ] && rm -rf "$GECICI" 2>/dev/null
    if [ -n "$kalan" ]; then
        TEMIZ=false
        derr "TEMİZLİK YAPILAMADI — geçici kaynaklar duruyor: $kalan"
        derr "  Elle silin:  docker rm -f $PROVA_C ; docker volume rm $HACIM"
        DETAY="$DETAY | TEMİZLİK YAPILAMADI: $kalan"
        return 1
    fi
    return 0
}

# Beklenmedik çıkışta da (die, kabuk hatası, Ctrl+C) temizlik ve JSON şart:
# çıktısı olmayan bir prova, controller için "hiç koşmamış" ile aynıdır.
cikista() {
    local kod=$?
    [ "$JSON_BASILDI" -eq 1 ] && return
    temizle
    [ "$DETAY" = "prova başlatılmadı" ] \
        && DETAY="prova beklenmedik şekilde sonlandı (çıkış $kod)"
    json_bas
}
trap cikista EXIT
trap 'DETAY="prova kullanıcı tarafından kesildi (Ctrl+C)"; exit 130' INT TERM

bitir() {   # bitir <çıkış kodu>
    local kod="$1"
    if ! temizle; then [ "$kod" -eq 0 ] && kod=4; fi
    # Çıkış kodu json_bas tarafından okunur: KAPSAM DIŞI (2) bir prova
    # sonucu değildir ve sonuç defterine girmemeli. Ölçülemedi (3) ise
    # gerçek bir sonuçtur — "bilmiyorum" da bir cevaptır ve yazılır.
    CIKIS_KODU="$kod"
    json_bas
    exit "$kod"
}

golge_reddedildi() {   # ÖNKOŞUL sağlanmadı — ölçüm yokluğu DEĞİL
    # Ayrı bir çıkış kodu şart: "ölçemedim" (3) ile "ölçtüm, olmaz" (5) aynı
    # şey değil. Controller bu ikisini farklı cümlelerle sunacak; 3'te
    # "bilmiyoruz" der, 5'te kullanıcıya SAYIYI ve seçeneği verir.
    DETAY="$*"
    derr "$DETAY"
    bitir 5
}

olcum_yok() {   # prova YAPILAMADI (ürün hatası değil, ölçüm yokluğu)
    derr "$*"
    DETAY="ölçülemedi: $*"
    bitir 3
}
kapsam_disi() { # bu motorda prova mümkün değil (hata DEĞİL)
    warn "$*"
    DETAY="kapsam dışı: $*"
    bitir 2
}
prova_dustu() { # yedek geri yüklenemedi — ASIL bulgu budur
    derr "$*"
    OK=false
    DETAY="$*"
    bitir 1
}

kullanim() {
cat <<EOF

Geri yükleme provası — databases-stack

  ./scripts/restore-drill.sh <motor> [dosya]

  Dosya verilmezse o motorun EN YENİ yedeği seçilir (.bozuk sayılmaz).
  Prova, TEK KULLANIMLIK bir container ve hacimde çalışır; üretim
  container'ına, üretim hacmine ve gateway'e dokunmaz.

  Prova yapılabilen motorlar: $(prova_motorlari | tr '\n' ' ')

  Ayarlar (ortam değişkeni):
    PROVA_MEM_MB=$PROVA_MEM_MB        geçici container bellek tavanı (MB)
    PROVA_CPU_SHARES=$PROVA_CPU_SHARES      CPU ağırlığı (yalnız çekişmede)
    PROVA_YUKLEME_SURESI=$SURE_YUKLEME  geri yükleme zaman aşımı (sn)

  --golge   Hacmi SİLMEZ: doğrulama geçerse onu üretimin bir sonraki
            kuşağı olarak saklar ve adını JSON'da verir. İşaretçiyi
            ÇEVİRMEZ — takası controller yapar. Üretim bu sırada
            çalışmaya devam eder; kesinti yalnız takas anındadır.

  Çıkış kodları: 0 geçti · 1 düştü · 2 kapsam dışı · 3 ölçülemedi
                 4 prova bitti ama temizlik yapılamadı
                 5 gölge önkoşulu sağlanmadı (disk yetmiyor, kuşak çakışıyor)

EOF
}

# =============================================================================
# KAPSAM
# =============================================================================
# Motor listesi SABİT YAZILMIYOR. Ölçüt iki taraflı:
#   1) backup.sh'ta o motorun restore_ fonksiyonu ve restore-<motor> alt
#      komutu var mı — yani ürün o motora geri yükleme VAAT ediyor mu,
#   2) bu betikte o motoru geçici bir kopyaya yükleyecek kod var mı.
# İkisi ayrı ayrı sorulur: yarın restore_clickhouse eklenirse prova "henüz
# uygulanmadı" der; tersi olursa "ürün bu motora geri yükleme sunmuyor".
# Sabit liste yazsaydık, eklenen motor sessizce kapsam dışında kalırdı.
urun_geri_yukluyor() {
    grep -qE "^restore_$1\(\)" scripts/backup.sh \
        && grep -qE "restore-$1[|)]" scripts/backup.sh
}
prova_uygulandi() { declare -F "yukle_$1" >/dev/null 2>&1; }

# tr -d '\r' ŞART. python3'ün print'i Windows'ta CRLF yazar ve depo Windows'ta
# düzenleniyor (.gitattributes'taki uyarı da tam bu sınıf hata için konmuş).
# \r taşıyan bir motor kimliği hiçbir grep desenine uymaz: betik "bu motorda
# prova yapılamıyor" deyip ÇIKIŞ 2 verirdi — yani sessizce hiçbir şey ölçmezdi.
katalog_motorlari() {
    catalog_query '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"]))' | tr -d '\r'
}

prova_motorlari() {
    local eid
    for eid in $(katalog_motorlari); do
        urun_geri_yukluyor "$eid" && prova_uygulandi "$eid" && printf '%s\n' "$eid"
    done
}

katalogda_var() {
    local eid
    for eid in $(katalog_motorlari); do
        [ "$eid" = "$1" ] && return 0
    done
    return 1
}

# Katalogdaki taban bellek. Okunamazsa 0 döner ve tavan olduğu gibi kalır —
# katalog bozukken provayı iptal etmek yerine varsayılanla devam etmek daha
# doğru: prova, kataloğun değil YEDEĞİN testidir.
# catalog_query BURADA KULLANILAMAZ: o yalnız $CATALOG'u python'a geçirir,
# ikinci bir argüman (motor kimliği) alamaz. Kullansaydık python IndexError
# ile ölür, 2>/dev/null onu yutar ve taban sessizce 0 çıkardı — mssql provası
# 1 GB'la açılmaya çalışıp her seferinde düşerdi.
katalog_min_mb() {
    local v
    v="$(python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
e=[x for x in c["engines"] if x["id"]==sys.argv[2]]
print(int(((e[0].get("resources") or {}).get("min_mb") or 0)) if e else 0)' \
        "$CATALOG" "$1" 2>/dev/null)"
    case "${v:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# =============================================================================
# ORTAM: imaj, parola, dosya
# =============================================================================
# İmaj etiketi SABİT YAZILMAZ. Önce ÜRETİMDE ŞU AN KOŞAN imajı soruyoruz:
# .env'de sürüm yükseltilmiş ama container henüz yeniden yaratılmamışsa
# compose'un değişkeni gerçeği söylemez, çalışan container söyler. Yedek de o
# çalışan sürümden alındığı için provanın onunla yapılması gerekir (dump'ı
# eski sunucuya yüklemek yeni sürüm söz dizimine takılabilir).
# Üretim kapalıysa compose'un kullandığı AYNI değişken ifadesine düşülür.
motor_imaji() {
    local eid="$1" C img
    C="$(primary_of "$eid")"
    img="$(docker inspect "$C" --format '{{.Config.Image}}' 2>/dev/null)"
    if [ -n "$img" ]; then printf '%s' "$img"; return 0; fi
    case "$eid" in
        mariadb)    printf '%s' "${MARIADB_IMAGE:-mariadb:${MARIADB_VERSION:-11.4}}" ;;
        postgresql) printf '%s' "${POSTGRES_IMAGE:-postgres:${POSTGRES_VERSION:-16}}" ;;
        mongodb)    printf '%s' "${MONGO_IMAGE:-mongo:${MONGO_VERSION:-7.0}}" ;;
        redis)      printf '%s' "${REDIS_IMAGE:-redis:${REDIS_VERSION:-8-alpine}}" ;;
        mssql)      printf '%s' "${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:${MSSQL_VERSION:-2022-latest}}" ;;
        *)          return 1 ;;
    esac
}

motor_parolasi() {
    case "$1" in
        mariadb)    printf '%s' "${MARIADB_PASSWORD:-${DB_PASSWORD:-}}" ;;
        postgresql) printf '%s' "${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}" ;;
        mongodb)    printf '%s' "${MONGO_PASSWORD:-${DB_PASSWORD:-}}" ;;
        redis)      printf '%s' "${REDIS_PASSWORD:-${DB_PASSWORD:-}}" ;;
        mssql)      printf '%s' "${MSSQL_PASSWORD:-${DB_PASSWORD:-}}" ;;
        *)          return 1 ;;
    esac
}

# Alt dizin ('full') SABİT YAZILMIYOR: dosya yerleşimini out_path <motor>
# <tip> üretiyor ve tip ileride 'single' olabilir. 'full' yazsaydık, tek
# veritabanlık bir yedek dizini eklendiği gün prova onu hiç görmezdi.
# .bozuk dosyalar aday DEĞİLDİR: onları finalize_backup kenara aldı, yani
# ürün "bu kurtarma noktası değil" dedi. En yeni .bozuk'u seçip provayı
# düşürmek, hatayı yanlış yere yazmak olurdu.
EN_YENI_NOT=""

en_yeni_yedek() {
    local d="$BACKUP_DIR/$1"
    [ -d "$d" ] || return 1
    EN_YENI_NOT=""
    local hepsi y satir atlanan=0
    # ŞİFRELİ YEDEKLER DE ADAY. Yalnız '*.gz' aranınca '.gz.enc' uzantılı
    # şifreli yedekler SESSİZCE atlanıyordu: şifrelemeyi açan kullanıcının
    # provası "yedek yok" deyip geçiyor — yani en çok güvence isteyen kurulum
    # en az güvence alıyordu. (e2e/encrypt.sh yakaladı.)
    hepsi="$(find "$d" -type f \( -name '*.gz' -o -name '*.gz.enc' \) \
         ! -name '*.bozuk' -printf '%T@\t%p\n' \
         2>/dev/null | sort -rn | cut -f2-)"
    [ -n "$hepsi" ] || return 1

    if [ -n "${ENC_KEY:-}" ]; then
        printf '%s' "$(printf '%s\n' "$hepsi" | head -1)"
        return 0
    fi

    # ANAHTAR YOKSA ŞİFRELİ DOSYA KURTARMA NOKTASI DEĞİLDİR. Ölçülen durum:
    # sunucudaki en yeni mariadb yedeği '.sql.gz.enc' idi ve .env'de anahtar
    # yoktu; prova onu seçip DÜŞÜYORDU. Bu, sapasağlam yedeklere "geri
    # yüklenemedi" damgası vurmak demek — ürünün en pahalı yanlış alarmı.
    # Atlamayı SESSİZ yapmıyoruz: kaç dosyanın neden atlandığını söylüyoruz,
    # yoksa "şifreli yedekler sessizce atlanıyordu" hatasını geri getirirdik.
    y=""
    while IFS= read -r satir; do
        [ -z "$satir" ] && continue
        case "$satir" in
            *".$ENC_EXT") atlanan=$((atlanan + 1)); continue ;;
        esac
        y="$satir"
        break
    done <<< "$hepsi"

    if [ "$atlanan" -gt 0 ]; then
        EN_YENI_NOT="$atlanan şifreli yedek atlandı (BACKUP_ENCRYPT_KEY tanımlı değil — açılamazlar)"
    fi
    [ -n "$y" ] || return 1
    printf '%s' "$y"
}

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Host'ta veritabanı istemcisi yok; her sorgu container'ın içinden çalışır.
# Parola komut satırına DEĞİL ortama konur (host'ta `ps` çıktısında
# görünmesin) — backup.sh'taki desenin aynısı. Alt kabuk şart: export'lar
# betiğin geri kalanına sızmasın.
my_sorgu() {   # my_sorgu <container> <sql>
    ( export MYSQL_PWD="$(motor_parolasi mariadb)"
      zaman "$SURE_SORGU" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$2" ) 2>>"$LOG_FILE"
}
pg_sorgu() {   # pg_sorgu <container> <veritabanı> <sql>
    ( export PGPASSWORD="$(motor_parolasi postgresql)"
      zaman "$SURE_SORGU" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$2" -tAq -c "$3" ) \
      2>>"$LOG_FILE"
}
mongo_js() {   # mongo_js <container> <js>
    ( export MPW="$(motor_parolasi mongodb)" MUSER="${MONGO_USER:-root}"
      zaman "$SURE_SORGU" docker exec -e MPW -e MUSER "$1" sh -c \
          'exec "$1" --quiet -u "$MUSER" -p "$MPW" --authenticationDatabase admin --eval "$2"' \
          sh "${MONGO_SHELL:-mongosh}" "$2" ) 2>>"$LOG_FILE"
}
redis_sorgu() { # redis_sorgu <container> <argümanlar…>
    local c="$1"; shift
    ( export REDISCLI_AUTH="$(motor_parolasi redis)"
      zaman "$SURE_SORGU" docker exec -e REDISCLI_AUTH "$c" \
          redis-cli --no-auth-warning "$@" ) 2>>"$LOG_FILE"
}
ms_sorgu() {   # ms_sorgu <container> <sorgu>
    # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir. Bu olmadan
    # düşen sorgu "başarılı" sanılır (backup.sh'ta da aynı sebeple var).
    ( export SQLCMDPASSWORD="$(motor_parolasi mssql)"
      zaman "$SURE_SORGU" docker exec -e SQLCMDPASSWORD "$1" \
          /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W \
          -Q "SET NOCOUNT ON; $2" ) 2>>"$LOG_FILE"
}

# Sayı bekliyoruz; gelmezse ÖLÇEMEDİK. Boş çıktıyı 0 saymak, ölçüm aracının
# bozulmasını "veri yok"a çevirir — bu paketin engellemeye çalıştığı şeyin ta
# kendisi.
sayi_mi() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Çıktıdan TEK bir sayı çıkarır. `tr -dc '0-9'` BİLEREK kullanılmıyor: istemci
# beklenmedik ikinci bir satır basarsa (uyarı, sürüm notu, boş satır sonrası
# hata) o satırın rakamları sonuca YAPIŞIR — 8 ile 15402 birleşip 815402 olur.
# Sessiz ve tamamen yanlış bir sayım, ölçüm yokluğundan beterdir.
tek_sayi() {
    printf '%s' "${1:-}" | tr -d '\r' | tr -d '[:blank:]' \
        | grep -E '^[0-9]+$' | head -1
}

# =============================================================================
# MOTOR: MARIADB
# =============================================================================
baslat_mariadb() {
    # --skip-log-bin: geri yükleme milyonlarca satır yazar; ikili günlük
    # bunları bir de binlog'a yazardı ve bu provada kimse o binlog'u
    # okumayacak. my.cnf BİLEREK bağlanmıyor (üretimde binlog AÇIK): prova
    # geçici bir kopyadır, üretimin PITR ayarına ihtiyacı yok.
    docker run "${ORTAK[@]}" \
        -v "$HACIM:/var/lib/mysql" \
        -e MARIADB_ROOT_PASSWORD="$(motor_parolasi mariadb)" \
        "$IMAJ" --skip-log-bin >>"$LOG_FILE" 2>&1
}
hazir_mariadb() { my_sorgu "$1" 'SELECT 1' >/dev/null 2>&1; }

yukle_mariadb() {
    local C="$1" f="$2"
    # Boru hattı, restore_mariadb'nin kullandığının AYNISI. Prova farklı bir
    # komutla yüklerse ürünün geri yükleme yolu hakkında hiçbir şey kanıtlamış
    # olmaz; kaçınılmaz tek fark hedefin BOŞ olmasıdır.
    oku_akis "$f" 2>>"$LOG_FILE" \
        | ( export MYSQL_PWD="$(motor_parolasi mariadb)"
            zaman "$SURE_YUKLEME" docker exec -e MYSQL_PWD -i "$C" \
                mariadb -u root ) >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ]; then
        HATA="yedek dosyası sonuna kadar OKUNAMADI (okuma rc=${ps[0]}) — şifreli bir yedekte bu, anahtarın eksik ya da yanlış olduğu anlamına da gelir"; return 1
    fi
    if [ "${ps[1]}" -ne 0 ]; then
        HATA="mariadb istemcisi geri yüklemeyi tamamlamadı (rc=${ps[1]}, $LOG_FILE)"
        return 1
    fi
    return 0
}

# NEDEN TAHMİN DEĞİL, TAM SAYIM:
# information_schema.TABLES.TABLE_ROWS InnoDB'de bir TAHMİNDİR ve istatistik
# tazeliğine göre değişir. Yeni geri yüklenmiş bir kopyanın istatistikleri
# taze, üretimin ki eski olur; iki tahmini karşılaştırmak, aynı veride bile
# "eşleşmedi" dedirtir. Yedeğe haksız yere "tutmuyor" demek, ona hiç
# bakmamaktan beterdir — o yüzden COUNT(*) ile tam sayıyoruz. Bedeli tam
# tarama; prova zaten bunun için var.
say_mariadb() {
    local C="$1" liste satir n=0 birlesik="" toplam
    liste="$(my_sorgu "$C" "SELECT CONCAT('SELECT COUNT(*) AS c FROM ',
                 CHAR(96),TABLE_SCHEMA,CHAR(96),'.',CHAR(96),TABLE_NAME,CHAR(96))
             FROM information_schema.TABLES
             WHERE TABLE_TYPE='BASE TABLE' AND TABLE_SCHEMA NOT IN
                   ('information_schema','performance_schema','mysql','sys')")" || return 1
    # CHAR(96) = ters tırnak. Kabuk → SQL yolunda ters tırnak kaçırmak yerine
    # sunucuya ürettiriyoruz; bir kaçış hatası burada sessiz bir yanlış sayım
    # olurdu.
    while IFS= read -r satir; do
        [ -n "$satir" ] || continue
        n=$((n+1))
        if [ -z "$birlesik" ]; then birlesik="$satir"
        else birlesik="$birlesik UNION ALL $satir"; fi
    done <<< "$liste"
    if [ "$n" -eq 0 ]; then printf '0 0'; return 0; fi
    toplam="$(my_sorgu "$C" "SELECT COALESCE(SUM(c),0) FROM ($birlesik) t")" || return 1
    toplam="$(tek_sayi "$toplam")"
    sayi_mi "$toplam" || return 1
    printf '%s %s' "$n" "$toplam"
}

# =============================================================================
# MOTOR: POSTGRESQL
# =============================================================================
baslat_postgresql() {
    # compose'daki özel entrypoint BİLEREK kullanılmıyor: onun tek işi
    # PG_STANDBY_OF ile bu düğümü bir standby'a çevirmek. Prova hiçbir
    # düğümden klonlanmamalı — yedek dosyasından yüklenmeli.
    docker run "${ORTAK[@]}" \
        -v "$HACIM:/var/lib/postgresql/data" \
        -e POSTGRES_PASSWORD="$(motor_parolasi postgresql)" \
        -e POSTGRES_USER="${POSTGRES_USER:-root}" \
        -e POSTGRES_DB=postgres \
        -e PGDATA=/var/lib/postgresql/data/pgdata \
        "$IMAJ" >>"$LOG_FILE" 2>&1
}
# Hazırlık ölçütü TCP üzerinden: initdb sırasında entrypoint geçici bir sunucu
# açar ama o sunucu YALNIZ unix soketini dinler. Soketten sorsaydık, kurulum
# daha bitmeden "hazır" der ve geri yüklemeyi yarım kurulmuş bir cluster'a
# göndermiş olurduk.
hazir_postgresql() { pg_sorgu "$1" postgres 'SELECT 1' >/dev/null 2>&1; }

yukle_postgresql() {
    local C="$1" f="$2" hatalar gercek
    hatalar="$GECICI/pg.err"
    # ON_ERROR_STOP ve --single-transaction YOK — sebebi restore_postgresql'de
    # uzun uzun yazılı: pg_dumpall --clean, bağlı olduğumuz rolü ve
    # veritabanını da düşürmeye çalışır, bu iki hata normaldir. Prova o
    # kararı DEĞİŞTİRMEZ, aynı süzgeci kullanır: farklı süzen bir prova,
    # ürünün geri yükleme yolunu değil kendi yolunu ölçmüş olurdu.
    oku_akis "$f" 2>>"$LOG_FILE" \
        | ( export PGPASSWORD="$(motor_parolasi postgresql)"
            zaman "$SURE_YUKLEME" docker exec -e PGPASSWORD -i "$C" \
                psql -U "${POSTGRES_USER:-root}" -d postgres ) \
          >>"$LOG_FILE" 2>"$hatalar"
    local ps=("${PIPESTATUS[@]}")
    cat "$hatalar" >>"$LOG_FILE" 2>/dev/null
    if [ "${ps[0]}" -ne 0 ]; then
        HATA="yedek dosyası sonuna kadar OKUNAMADI (okuma rc=${ps[0]}) — şifreli bir yedekte bu, anahtarın eksik ya da yanlış olduğu anlamına da gelir"; return 1
    fi
    gercek="$(grep -E '^(psql:|ERROR|FATAL|HATA)' "$hatalar" 2>/dev/null \
        | grep -viE 'current user cannot be dropped|cannot drop the currently open database|role .* already exists|database .* already exists|is being accessed by other users' \
        || true)"
    if [ -n "$gercek" ]; then
        HATA="psql geri yüklerken hata verdi: $(printf '%s' "$gercek" | head -2 | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# pg_dumpall TÜM cluster'ı taşır; sayım da tüm veritabanlarını gezmeli.
# Tek veritabanına bakan bir sayım, 9 veritabanının 8'i geri gelmemişken
# "eşleşti" derdi. Satırlar query_to_xml ile TAM sayılıyor (reltuples bir
# tahmindir; gerekçesi say_mariadb'de).
say_postgresql() {
    local C="$1" dbler db cikti t=0 r=0 tt rr
    dbler="$(pg_sorgu "$C" postgres \
        "SELECT datname FROM pg_database WHERE datallowconn
         AND datname NOT IN ('template0','template1')")" || return 1
    [ -n "$dbler" ] || return 1
    while IFS= read -r db; do
        db="${db%$'\r'}"
        [ -n "$db" ] || continue
        cikti="$(pg_sorgu "$C" "$db" "
            SELECT count(*), COALESCE(sum(cnt),0) FROM (
              SELECT (xpath('/row/c/text()',
                        query_to_xml(format('SELECT count(*) AS c FROM %I.%I',
                                            table_schema, table_name),
                                     false, true, '')))[1]::text::bigint AS cnt
              FROM information_schema.tables
              WHERE table_type='BASE TABLE'
                AND table_schema NOT IN ('pg_catalog','information_schema')
            ) s")" || return 1
        cikti="$(printf '%s' "$cikti" | tr -d '\r' | grep -v '^$' | head -1)"
        tt="${cikti%%|*}"; rr="${cikti##*|}"
        sayi_mi "$tt" && sayi_mi "$rr" || return 1
        t=$((t+tt)); r=$((r+rr))
    done <<< "$dbler"
    printf '%s %s' "$t" "$r"
}

# =============================================================================
# MOTOR: MONGODB
# =============================================================================
baslat_mongodb() {
    # WiredTiger önbelleğinin ALT SINIRI 256 MB'tır; katalog tabanı 512 MB'lık
    # container'da 0.25 GB önbellek + mongod'un kendisi sığar. Üretimin
    # MONGO_WIREDTIGER_CACHE_GB değerini kullanmıyoruz: o, host RAM'ine göre
    # hesaplanmış bir üretim ayarı; prova container'ının tavanını aşabilir ve
    # container OOM ile ölürdü.
    docker run "${ORTAK[@]}" \
        -v "$HACIM:/data/db" \
        -e MONGO_INITDB_ROOT_USERNAME="${MONGO_USER:-root}" \
        -e MONGO_INITDB_ROOT_PASSWORD="$(motor_parolasi mongodb)" \
        "$IMAJ" mongod --auth --bind_ip_all \
        --wiredTigerCacheSizeGB 0.25 >>"$LOG_FILE" 2>&1
}
# Hazırlık ölçütü KİMLİKLİ bir sorgu: ping kimlik doğrulamadan da cevap verir,
# yani entrypoint kullanıcıyı yaratmadan önce de "hazır" derdi ve
# mongorestore kimlik hatasıyla düşerdi.
hazir_mongodb() { mongo_js "$1" 'db.adminCommand({listDatabases:1}).ok' >/dev/null 2>&1; }

yukle_mongodb() {
    local C="$1" f="$2" rc=0
    # --drop, restore_mongodb ile aynı. Parola komut satırı yerine ortamdan
    # geçiyor: host'ta `ps` çıktısında görünmesin (üretim yolundaki tek fark
    # budur ve geri yükleme davranışını değiştirmez).
    ( export MPW="$(motor_parolasi mongodb)" MUSER="${MONGO_USER:-root}"
      zaman "$SURE_YUKLEME" docker exec -e MPW -e MUSER -i "$C" sh -c \
        'exec mongorestore --username "$MUSER" --password "$MPW" \
             --authenticationDatabase admin --archive --gzip --drop' \
      ) < "$f" >>"$LOG_FILE" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        HATA="mongorestore düştü (rc=$rc, $LOG_FILE)"; return 1
    fi
    return 0
}

# admin/local/config İKİ TARAFTA DA dışarıda: local çoğaltma günlüğüdür,
# admin/config yönetim verisidir; ikisi de kullanıcı verisi değil ve
# provadaki sayıları üretimden farklı çıkarırdı (mongodump local'i almaz).
say_mongodb() {
    local C="$1" cikti t r
    cikti="$(mongo_js "$C" 'var t=0,r=0;db.getMongo().getDBNames().forEach(function(n){if(n==="admin"||n==="local"||n==="config")return;var d=db.getSiblingDB(n);d.getCollectionNames().forEach(function(k){t++;r+=d.getCollection(k).countDocuments({});});});print(t+" "+r);')" || return 1
    cikti="$(printf '%s' "$cikti" | tr -d '\r' | grep -E '^[0-9]+ [0-9]+$' | tail -1)"
    [ -n "$cikti" ] || return 1
    t="${cikti%% *}"; r="${cikti##* }"
    sayi_mi "$t" && sayi_mi "$r" || return 1
    printf '%s %s' "$t" "$r"
}

# =============================================================================
# MOTOR: REDIS
# =============================================================================
# Redis'in provası ötekilerden farklı sırada: RDB, sunucu AÇILMADAN ÖNCE
# hacme konur. Sebebi restore_redis'in başındaki uyarı: appendonly=yes ile
# açılan Redis AOF yoksa BOŞ başlar ve dump.rdb'ye hiç bakmaz. Bu yüzden
# geçici sunucu AOF KAPALI açılıyor — provanın sorusu "RDB okunuyor mu".
hazirla_redis() {
    local f="$1"
    oku_akis "$f" 2>>"$LOG_FILE" \
        | zaman "$SURE_YUKLEME" docker run -i --rm --network none \
            --memory "${MEM_MB}m" --memory-swap "${MEM_MB}m" \
            --label "$ETIKET=1" -v "$HACIM:/d" --entrypoint sh "$IMAJ" \
            -c 'rm -rf /d/appendonlydir /d/appendonly.aof* /d/dump.rdb
                cat > /d/dump.rdb && chown 999:999 /d/dump.rdb' \
          >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ]; then
        HATA="yedek dosyası sonuna kadar OKUNAMADI (okuma rc=${ps[0]}) — şifreli bir yedekte bu, anahtarın eksik ya da yanlış olduğu anlamına da gelir"; return 1
    fi
    if [ "${ps[1]}" -ne 0 ]; then
        HATA="RDB geçici hacme yazılamadı (rc=${ps[1]}, $LOG_FILE)"; return 1
    fi
    return 0
}
baslat_redis() {
    # --maxmemory 0: prova sırasında ANAHTAR ATMAK yasak. Üretimin
    # allkeys-lru politikasıyla açsaydık, tavana çarpan yükleme sessizce
    # anahtar atar ve sayım "eşleşmedi" derdi — suç yedekte değil provada
    # olurdu. Tavansız açıp cgroup'un öldürmesine izin veriyoruz: OOM
    # gürültülüdür ve sebebini SÖYLEYEBİLİRİZ (bkz. olum_sebebi).
    # --save '': prova kopyası kendi anlık görüntüsünü almasın; yazacağı tek
    # şey okuduğumuz RDB'nin üzerine olurdu.
    docker run "${ORTAK[@]}" \
        -v "$HACIM:/data" "$IMAJ" \
        redis-server --appendonly no --save '' --maxmemory 0 \
        --dir /data --dbfilename dump.rdb \
        --requirepass "$(motor_parolasi redis)" >>"$LOG_FILE" 2>&1
}
hazir_redis() { redis_sorgu "$1" PING 2>/dev/null | grep -q PONG; }
# Yükleme açılışta oldu; burada yapılacak iş yok. Yine de bir fonksiyon var:
# kapsam ölçütü (prova_uygulandi) yukle_<motor> arıyor ve redis'in kapsamda
# olduğu tek bir yerden görünmeli.
yukle_redis() { return 0; }

# DBSIZE yalnız o anki veritabanını sayar. RDB'de db0 dışında veri varsa
# (SELECT 1..15) DBSIZE onları görmez ve eksik sayardı; INFO keyspace hepsini
# listeler.
say_redis() {
    local C="$1" cikti satir k t=0 r=0
    cikti="$(redis_sorgu "$C" INFO keyspace)" || return 1
    # Ölçüm aracının çalıştığının kanıtı bölüm başlığıdır: boş bir sunucuda da
    # "# Keyspace" basılır. Yoksa elimizde "0 anahtar" değil "ölçüm yok" var.
    printf '%s' "$cikti" | grep -qi 'Keyspace' || return 1
    while IFS= read -r satir; do
        satir="${satir%$'\r'}"
        case "$satir" in db*:keys=*) ;; *) continue ;; esac
        k="${satir#*keys=}"; k="${k%%,*}"
        sayi_mi "$k" || continue
        t=$((t+1)); r=$((r+k))
    done <<< "$cikti"
    printf '%s %s' "$t" "$r"
}

# =============================================================================
# MOTOR: MSSQL
# =============================================================================
baslat_mssql() {
    # MSSQL_MEMORY_LIMIT_MB, container tavanının ALTINDA olmalı — yoksa motor
    # limiti aşar ve cgroup OOM-killer'a yakalanır (compose'daki aynı yorum).
    # Oran katalogdan: mssql.resources.tuning'de MSSQL_MEMORY_LIMIT_MB
    # factor 0.8 ile hesaplanıyor; prova da aynı oranı kullanıyor ki ölçtüğü
    # RTO üretimdekiyle karşılaştırılabilir olsun.
    docker run "${ORTAK[@]}" \
        -v "$HACIM:/var/opt/mssql" \
        -e ACCEPT_EULA=Y \
        -e MSSQL_SA_PASSWORD="$(motor_parolasi mssql)" \
        -e MSSQL_PID="${MSSQL_PID:-Express}" \
        -e MSSQL_MEMORY_LIMIT_MB="$(( MEM_MB * 8 / 10 ))" \
        "$IMAJ" >>"$LOG_FILE" 2>&1
}
hazir_mssql() { ms_sorgu "$1" 'SELECT 1;' >/dev/null 2>&1; }

yukle_mssql() {
    local C="$1" f="$2" bak db esc bulunan=0 yuklenen=0 rc=0
    docker exec "$C" sh -c \
        'mkdir -p /var/opt/mssql/backup && rm -f /var/opt/mssql/backup/*.bak' \
        >>"$LOG_FILE" 2>&1
    oku_akis "$f" 2>>"$LOG_FILE" \
        | zaman "$SURE_YUKLEME" docker exec -i "$C" \
            tar -xf - -C /var/opt/mssql/backup >>"$LOG_FILE" 2>&1
    local ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ]; then
        HATA="yedek dosyası sonuna kadar OKUNAMADI (okuma rc=${ps[0]}) — şifreli bir yedekte bu, anahtarın eksik ya da yanlış olduğu anlamına da gelir"; return 1
    fi
    if [ "${ps[1]}" -ne 0 ]; then
        HATA="yedek arşivi açılamadı (tar rc=${ps[1]}, $LOG_FILE)"; return 1
    fi
    for bak in $(docker exec "$C" sh -c 'ls /var/opt/mssql/backup/*.bak 2>/dev/null'); do
        bak="${bak%$'\r'}"
        bulunan=$((bulunan+1))
        db="$(basename "$bak" .bak)"
        # master/msdb, restore_mssql'de de atlanıyor: sistem veritabanları
        # çalışan bir örneğe çevrimiçi geri yüklenemez. Sayımda da yoklar
        # (database_id>4), yani atlanmaları karşılaştırmayı bozmaz.
        case "$db" in master|msdb) continue ;; esac
        esc="${db//]/]]}"
        # ms_sorgu DEĞİL: onun zaman aşımı SORGU ölçeğinde (300 sn). RESTORE
        # bir sorgu değil, geri yüklemenin kendisidir; büyük bir veritabanında
        # 300 sn'de bitmez ve prova, ürün kusursuz çalışırken "düştü" derdi.
        if ( export SQLCMDPASSWORD="$(motor_parolasi mssql)"
             zaman "$SURE_YUKLEME" docker exec -e SQLCMDPASSWORD "$C" \
                 /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b \
                 -Q "RESTORE DATABASE [$esc] FROM DISK=N'$bak' WITH REPLACE;" \
           ) >>"$LOG_FILE" 2>&1
        then yuklenen=$((yuklenen+1)); else rc=1; fi
    done
    # "Hiç dönmeyen döngü = başarı" tuzağı burada da kapalı (restore_mssql'de
    # de aynısı var): arşivde .bak yoksa ya da hiçbiri yüklenmediyse bu iş
    # BAŞARISIZDIR.
    if [ "$bulunan" -eq 0 ]; then
        HATA="arşivin içinde .bak dosyası yok — bu dosya bir MSSQL yedeği değil"
        return 1
    fi
    if [ "$yuklenen" -eq 0 ]; then
        HATA="hiçbir veritabanı geri yüklenemedi ($bulunan .bak vardı, $LOG_FILE)"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        HATA="bazı veritabanları geri yüklenemedi ($yuklenen/$bulunan, $LOG_FILE)"
        return 1
    fi
    return 0
}

# database_id>4 → master/tempdb/model/msdb dışarıda. Satırlar sys.partitions
# yerine COUNT_BIG(*) ile: sys.partitions.rows belgelerde de "yaklaşık" diye
# geçer ve iki yaklaşık sayıyı karşılaştırmak sağlam bir yedeğe "tutmuyor"
# dedirtebilir.
say_mssql() {
    local C="$1" dbler db esc n s t=0 r=0
    dbler="$(ms_sorgu "$C" \
        "SELECT name FROM sys.databases WHERE database_id>4 AND state_desc='ONLINE';")" \
        || return 1
    while IFS= read -r db; do
        db="$(printf '%s' "$db" | tr -d '\r' | sed 's/[[:space:]]*$//')"
        [ -n "$db" ] || continue
        esc="${db//]/]]}"
        n="$(ms_sorgu "$C" "USE [$esc]; SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped=0;")" \
            || return 1
        n="$(tek_sayi "$n")"
        sayi_mi "$n" || return 1
        s="$(ms_sorgu "$C" "USE [$esc];
             DECLARE @s nvarchar(max)=N'SELECT CAST(0 AS bigint) AS c';
             SELECT @s=@s+N' UNION ALL SELECT COUNT_BIG(*) FROM '
                        +QUOTENAME(sc.name)+N'.'+QUOTENAME(t.name)
             FROM sys.tables t JOIN sys.schemas sc ON sc.schema_id=t.schema_id
             WHERE t.is_ms_shipped=0;
             EXEC(N'SELECT SUM(c) FROM ('+@s+N') x');")" || return 1
        s="$(tek_sayi "$s")"
        sayi_mi "$s" || return 1
        t=$((t+n)); r=$((r+s))
    done <<< "$dbler"
    printf '%s %s' "$t" "$r"
}

# =============================================================================
# ORTAK KOŞUM
# =============================================================================
# Container ölmüşse SEBEBİNİ söylüyoruz. "Hazır olmadı" tek başına yedeği
# suçlar; oysa en sık sebep bellek tavanıdır ve çaresi tek satırdır.
# =============================================================================
# ŞEMA NESNESİ SAYIMI — "prova geçti" rozetinin göremediği kayıp
# =============================================================================
# Tablo ve satır saymak, bir yedeğin geri yüklendiğini göstermeye YETMEZ:
# indeksleri, kısıtları, view'ları, trigger'ları ve rutinleri kaybetmiş bir
# kopya da aynı tablo/satır sayısını verir. Uygulama açılır, sorgular
# yavaşlar, foreign key'ler yoktur ve bu ancak aylar sonra fark edilir.
#
# Sayım SALT OKUNURDUR: yalnız katalog/şema görünümlerine bakılıyor,
# kullanıcı tablolarına dokunulmuyor.
#
# Sonuç TEK SATIR, boşlukla ayrılmış BEŞ sayı:
#   <indeks> <kısıt> <view> <trigger> <rutin>
# Ölçülemezse hiçbir şey basmıyoruz ve rc=1 dönüyoruz: eksik sayıyı sıfır
# saymak, kaybı "hiç yoktu" diye göstermek olurdu.

sema_say_postgresql() {
    local C="$1" dbler db cikti i=0 k=0 v=0 g=0 r=0 p
    dbler="$(pg_sorgu "$C" postgres \
        "SELECT datname FROM pg_database WHERE datallowconn
         AND datname NOT IN ('template0','template1')")" || return 1
    [ -n "$dbler" ] || return 1
    while IFS= read -r db; do
        db="${db%$'\r'}"
        [ -n "$db" ] || continue
        # Sistem şemaları dışarıda; otomatik üretilen TOAST indeksleri de.
        cikti="$(pg_sorgu "$C" "$db" "
            SELECT
              (SELECT count(*) FROM pg_index x
                 JOIN pg_class c ON c.oid = x.indrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')),
              (SELECT count(*) FROM pg_constraint co
                 JOIN pg_namespace n ON n.oid = co.connamespace
                WHERE n.nspname NOT IN ('pg_catalog','information_schema')),
              (SELECT count(*) FROM information_schema.views
                WHERE table_schema NOT IN ('pg_catalog','information_schema')),
              (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal),
              (SELECT count(*) FROM information_schema.routines
                WHERE routine_schema NOT IN ('pg_catalog','information_schema'))
        ")" || return 1
        cikti="$(printf '%s' "$cikti" | tr -d '\r' | grep -v '^$' | head -1)"
        # 'a|b|c|d|e' → beş sayı
        IFS='|' read -r p1 p2 p3 p4 p5 <<< "$cikti"
        for p in "$p1" "$p2" "$p3" "$p4" "$p5"; do sayi_mi "$p" || return 1; done
        i=$((i+p1)); k=$((k+p2)); v=$((v+p3)); g=$((g+p4)); r=$((r+p5))
    done <<< "$dbler"
    printf '%s %s %s %s %s' "$i" "$k" "$v" "$g" "$r"
}

sema_say_mariadb() {
    local C="$1" cikti p
    # STATISTICS her SÜTUN için bir satır verir; indeks sayısı için
    # (şema, tablo, indeks) üçlüsü tekilleştiriliyor. Bunu atlamak çok
    # sütunlu indekslerde sayıyı şişirir ve her provada yalancı fark üretirdi.
    cikti="$(my_sorgu "$C" "
        SELECT
          (SELECT COUNT(*) FROM (SELECT DISTINCT TABLE_SCHEMA,TABLE_NAME,INDEX_NAME
             FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')) x),
          (SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS
            WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')),
          (SELECT COUNT(*) FROM information_schema.VIEWS
            WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')),
          (SELECT COUNT(*) FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys')),
          (SELECT COUNT(*) FROM information_schema.ROUTINES
            WHERE ROUTINE_SCHEMA NOT IN ('information_schema','performance_schema','mysql','sys'))
    ")" || return 1
    cikti="$(printf '%s' "$cikti" | tr -d '\r' | grep -v '^$' | head -1)"
    IFS=$'\t' read -r p1 p2 p3 p4 p5 <<< "$cikti"
    for p in "$p1" "$p2" "$p3" "$p4" "$p5"; do sayi_mi "$p" || return 1; done
    printf '%s %s %s %s %s' "$p1" "$p2" "$p3" "$p4" "$p5"
}

sema_uygulandi() { declare -F "sema_say_$1" >/dev/null 2>&1; }

# Farkı insan diline çeviriyor: hangi tür kaç eksik/fazla.
sema_fark_metni() {   # sema_fark_metni <kopya> <üretim>
    local -a a b
    read -ra a <<< "$1"
    read -ra b <<< "$2"
    local adlar=(indeks kısıt view trigger rutin) i out=""
    for i in 0 1 2 3 4; do
        if [ "${a[$i]}" -ne "${b[$i]}" ]; then
            out="${out:+$out, }${adlar[$i]} ${a[$i]}≠${b[$i]}"
        fi
    done
    printf '%s' "$out"
}

olum_sebebi() {
    local C="$1" oom kod son
    oom="$(docker inspect -f '{{.State.OOMKilled}}' "$C" 2>/dev/null)"
    kod="$(docker inspect -f '{{.State.ExitCode}}' "$C" 2>/dev/null)"
    son="$(docker logs --tail 5 "$C" 2>&1 | tr -d '\r' | tr '\n' ' ' | cut -c1-300)"
    if [ "$oom" = "true" ]; then
        printf 'geçici container BELLEK YETMEDİĞİ için öldü (OOM, çıkış %s). Şu anki tavan %s MB; PROVA_MEM_MB ile artırın. Son satırlar: %s' \
            "${kod:-?}" "$MEM_MB" "$son"
    else
        printf 'geçici container çıktı (çıkış kodu %s). Son satırlar: %s' \
            "${kod:-bilinmiyor}" "$son"
    fi
}

# ÜST ÜSTE KAÇ KEZ CEVAP VERİRSE HAZIR SAYILIR. Bir kez yetmiyor ve bu
# ÖLÇÜLDÜ: MariaDB imajı ilk açılışta önce GEÇİCİ bir kurulum sunucusu
# başlatıyor, veri dizinini kuruyor, sonra onu KAPATIP asıl sunucuyu
# açıyor. Tek atışlık 'SELECT 1' o geçici sunucuya denk gelince "hazır"
# diyorduk; hemen ardından sunucu kapanıyor ve dökümü boşluğa akıtıyorduk.
# Sonuç, sapasağlam bir yedeğe "yedek dosyası sonuna kadar OKUNAMADI"
# damgası vurmaktı — hatanın sebebini de yanlış yere yazıyordu (şifreleme).
# Üst üste üç cevap, kapanan bir sunucuyu eler; sayaç her düşüşte sıfırlanır.
HAZIR_USTUSTE="${PROVA_HAZIR_USTUSTE:-3}"

hazir_bekle() {   # hazir_bekle <saniye> <container>
    local bitis=$(( $(date +%s) + $1 )) C="$2" durum ardarda=0
    while :; do
        durum="$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)"
        if [ "$durum" != "true" ]; then
            HATA="$(olum_sebebi "$C")"; return 1
        fi
        if "hazir_$MOTOR" "$C"; then
            ardarda=$(( ardarda + 1 ))
            [ "$ardarda" -ge "$HAZIR_USTUSTE" ] && return 0
        else
            # Bir kez bile düşerse baştan sayıyoruz: aradaki düşüş, kurulum
            # sunucusunun kapandığı andır.
            ardarda=0
        fi
        if [ "$(date +%s)" -ge "$bitis" ]; then
            HATA="geçici container $1 sn içinde hazır olmadı. $(olum_sebebi "$C")"
            return 1
        fi
        sleep 2
    done
}

# Motorun ilk açılış süresi çok farklı: MSSQL'in compose'daki healthcheck
# start_period'ı 90 sn, MariaDB'ninki 60, Redis'inki 10. Buradaki değerler o
# beklentilerin üstünde (ilk açılış + veri dizini kurulumu) ama sonsuz değil.
hazir_suresi() {
    case "$1" in
        mssql)      printf '600' ;;
        mariadb)    printf '300' ;;
        postgresql) printf '300' ;;
        mongodb)    printf '300' ;;
        redis)      printf '120' ;;
        *)          printf '300' ;;
    esac
}

birim_notu() {
    case "$1" in
        mongodb) printf 'tablo=koleksiyon, satır=belge' ;;
        redis)   printf 'tablo=dolu veritabanı (dbN), satır=anahtar' ;;
        *)       printf 'tablo=tablo, satır=satır' ;;
    esac
}

# Prova ile YEDEKLEME AYNI KİLİDİ paylaşır. Karar ve gerekçesi:
#   • Prova üretim container'ına dokunmuyor ama AYNI HOST'ta ikinci bir
#     veritabanı açıyor. backup.sh'ın başındaki OOM olayı (MariaDB'nin 172
#     kez yeniden başlaması) "aynı anda iki ağır iş" yüzündendi; gece yedeği
#     dump alırken prova da bir motoru ayağa kaldırıp veri yüklerse aynı
#     çukur yeniden kazılmış olur.
#   • Prova, yedekleme turunun HER AN silebileceği/yeniden adlandırabileceği
#     bir dosyayı okuyor: clean_old eskiyi siler, finalize_backup doğrulamayı
#     geçemeyeni .bozuk'a taşır. Kilitsiz prova, ayağının altındaki dosya
#     çekilirken "yedek geri yüklenmedi" diye rapor edebilirdi.
#   • Ölçtüğümüz şey RTO. Tam yedek diski doldururken alınan bir süre ölçümü
#     yanlış bir sayıdır ve yanlış sayı basmak hiç basmamaktan kötüdür.
# BEDELİ: prova sürerken başlayan bir yedekleme kilidi bulamaz ve backup.sh
# "Başka bir işlem kilidi tutuyor" deyip ÇIKAR. Bu yüzden prova, yedekleme
# penceresinin DIŞINDA çalıştırılmalıdır.
# acquire_lock DOĞRUDAN çağrılmıyor: o, kilit meşgulken die ile ÇIKIŞ 1
# veriyor ve JSON basılmıyor — controller bunu "yedek geri yüklenmedi" diye
# okurdu. Oysa gerçek tam tersi: prova hiç DENENEMEDİ (çıkış 3). Aynı kilit
# dosyası, aynı flock; farklı olan yalnızca sonucun bildirimi.
kilit_al() {
    command -v flock >/dev/null 2>&1 \
        || olcum_yok "flock (util-linux) yok — yedekleme kilidi alınamadı, prova yapılmadı."
    mkdir -p "$(dirname "$KILIT")" 2>/dev/null || true
    # Kilidi controller (container'da root) ile PAYLAŞIYORUZ; modu
    # açılmazsa iki taraf ayrı kilit tutar ve kilit hiçbir şeyi
    # engellemez olur.
    paylasilan_dosya "$KILIT" 0666
    exec 9>>"$KILIT" || olcum_yok "Kilit dosyası açılamadı: $KILIT (sahibi $(stat -c '%U:%G %a' "$KILIT" 2>/dev/null || echo bilinmiyor), siz $(id -un)). Onarım: ./stack.sh doctor --duzelt"
    flock -n 9 || olcum_yok "Yedekleme kilidi başkasında ($KILIT) — yedekleme ya da geri yükleme sürüyor. Prova YAPILMADI; yedeğin durumu hakkında bir şey söylemiyoruz."
}

# Kilit alındıktan sonra bu host'ta başka prova koşamaz; dolayısıyla etiketli
# ne varsa ÖNCEKİ bir koşumun kalıntısıdır. Sessizce bırakmak, tek sunuculuk
# bir yığında yavaş yavaş biriken bir bellek/disk sızıntısı demek.
kalintilari_topla() {
    local id n=0
    for id in $(docker ps -aq --filter "label=$ETIKET" 2>/dev/null); do
        docker rm -f "$id" >>"$LOG_FILE" 2>&1 && n=$((n+1))
    done
    for id in $(docker volume ls -q --filter "label=$ETIKET" 2>/dev/null); do
        docker volume rm "$id" >>"$LOG_FILE" 2>&1 && n=$((n+1))
    done
    [ "$n" -gt 0 ] && warn "Önceki yarım kalmış provalardan $n kalıntı temizlendi."
    return 0
}


# =============================================================================
# GÖLGE KİPİ — kuşak adı ve disk muhasebesi
# =============================================================================
# Gölge geri yükleme, üretimin veri hacmini SİLMEDEN yeni bir hacme yüklüyor;
# doğrulama geçerse controller işaretçiyi çeviriyor. Buradaki iş, doğru adı
# bulmak ve diskin yeteceğini ÖNCEDEN sayıyla söylemek.

KUSAK_AYIRAC="__g"

# Motorun üretim veri hacminin TABAN adı (kuşak eki olmadan). Katalogdan
# okunuyor: adı burada da elle yazmak, iki kaynağın ayrışması demekti.
uretim_hacmi() {   # uretim_hacmi <motor>
    local eid="$1" prim
    prim="$(primary_of "$eid")" || return 1
    local kisa
    kisa="$(catalog_query '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
hedef=sys.argv[2]
for e in c["engines"]:
    for s,vs in (e.get("data_volumes") or {}).items():
        if s==hedef:
            for v in vs:
                if v.endswith("_data") or len(vs)==1:
                    print(v); raise SystemExit(0)
' "$prim" | tr -d '\r')" || return 1
    [ -n "$kisa" ] || return 1
    printf '%s_%s\n' "${STACK_PROJECT:-databases-stack}" "$kisa"
}

kusak_no() {   # kusak_no <hacim adı>
    local ad="${1:-}" kuyruk
    case "$ad" in
        *"$KUSAK_AYIRAC"*) kuyruk="${ad##*$KUSAK_AYIRAC}" ;;
        *) printf '0\n'; return 0 ;;
    esac
    if sayi_mi "$kuyruk"; then printf '%s\n' "$kuyruk"; else printf '0\n'; fi
}

# CANLI kuşak container'dan ÖLÇÜLÜR. volumes.env yalnız NİYETTİR: takas
# yarıda kalmışsa ikisi ayrışır ve o anda doğru olan, motorun gerçekten
# bağladığı hacimdir. Container kapalıysa dosyaya düşüyoruz — ama bunu
# "ölçtük" diye değil, elimizdeki tek bilgi olduğu için.
canli_hacim() {   # canli_hacim <motor> <taban>
    local eid="$1" taban="$2" prim ad
    prim="$(primary_of "$eid")" || return 1
    if docker inspect "$prim" >/dev/null 2>&1; then
        for ad in $(docker inspect "$prim" \
                    --format '{{range .Mounts}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null); do
            case "$ad" in
                "$taban"|"$taban$KUSAK_AYIRAC"*) printf '%s\n' "$ad"; return 0 ;;
            esac
        done
    fi
    local ni
    ni="$(grep -E "^$(printf '%s' "${taban#${STACK_PROJECT:-databases-stack}_}" \
          | tr '[:lower:]-' '[:upper:]_')_VOLUME=" \
          "$STACK_ROOT/state/volumes.env" 2>/dev/null | tail -1)"
    [ -n "$ni" ] && { printf '%s\n' "${ni#*=}"; return 0; }
    printf '%s\n' "$taban"
}

# Diskte yer var mı — TAHMİNLE değil, ölçümle. Üretim hacminin boyutu
# docker'ın kendi muhasebesinden okunuyor; okunamazsa dump boyutundan
# türetiyoruz ve hangi yöntemi kullandığımızı SÖYLÜYORUZ. "Yer yok" demek
# felaket anında ürünü kilitlemek olurdu; o yüzden sayıyı da yazıyoruz.
disk_bos_mb() {   # disk_bos_mb [hacim]
    # ÖLÇÜLDÜ: controller container'ının içinden `df /var/lib/docker` diye
    # sormak işe yaramıyor — o yol orada YOK, df düşüyor ve kapı sessizce
    # "ölçemedim"e geçiyordu. Yani ürünün "önceden sayıyla söyle" sözü,
    # panelden çalıştırıldığında hiç tutmuyordu.
    # Doğru soru şu: HACMİN DURDUĞU dosya sisteminde ne kadar yer var. Bunu
    # o hacmi bağlayan bir container'a soruyoruz; imaj zaten yerelde duruyor
    # (motorun kendi imajı), yeni bir şey indirmiyoruz.
    local hacim="${1:-}" mb=""
    if [ -n "$hacim" ] && [ -n "${IMAJ:-}" ]; then
        mb="$(docker run --rm --network none -v "$hacim":/olcum                 --entrypoint df "$IMAJ" -Pk /olcum 2>/dev/null               | awk 'NR==2 {print int($4/1024)}')"
        if printf '%s' "${mb:-}" | grep -qE '^[0-9]+$'; then
            printf '%s' "$mb"; return 0
        fi
    fi
    # Host'ta çalışıyorsak bu yol doğrudur ve bir container başlatmaya gerek yok.
    local kok
    kok="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
    [ -n "$kok" ] || kok="/var/lib/docker"
    df -Pk "$kok" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

hacim_boyut_mb() {   # hacim_boyut_mb <hacim>
    docker system df -v --format '{{json .Volumes}}' 2>/dev/null \
      | python3 -c '
import json,sys,re
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
hedef=sys.argv[1]
for v in d:
    if v.get("Name")==hedef:
        s=(v.get("Size") or "").strip()
        m=re.match(r"([0-9.]+)\s*([KMGT]?i?B)", s)
        if not m: raise SystemExit(1)
        n=float(m.group(1)); b=m.group(2)[0]
        print(int(n*{"B":1/1048576.0,"K":1/1024.0,"M":1,"G":1024,"T":1048576}.get(b,1)))
        raise SystemExit(0)
raise SystemExit(1)' "$1" 2>/dev/null
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
if [ -z "$MOTOR" ] || [ "$MOTOR" = "-h" ] || [ "$MOTOR" = "--yardim" ]; then
    kullanim
    DETAY="motor belirtilmedi"
    bitir 2
fi

if ! katalogda_var "$MOTOR"; then
    kapsam_disi "Kataloğda böyle bir motor yok: $MOTOR (bkz. catalog.json)"
fi
if ! urun_geri_yukluyor "$MOTOR"; then
    kapsam_disi "Bu motorda prova yapılamıyor: $MOTOR — backup.sh bu motora otomatik geri yükleme sunmuyor (docs/BACKUP.md)."
fi
if ! prova_uygulandi "$MOTOR"; then
    kapsam_disi "Bu motorda prova yapılamıyor: $MOTOR — backup.sh geri yüklüyor ama bu betikte henüz prova adımı yazılmadı."
fi

command -v docker >/dev/null 2>&1 || olcum_yok "docker bulunamadı — prova yapılamadı."
docker info >/dev/null 2>&1 \
    || olcum_yok "docker'a erişilemiyor (servis kapalı ya da yetki yok) — prova yapılamadı."

if [ -z "$(motor_parolasi "$MOTOR")" ]; then
    olcum_yok "$MOTOR parolası okunamadı (.env yok ya da eksik) — geçici kopya açılamaz."
fi

kilit_al
kalintilari_topla

if [ -z "$DOSYA" ]; then
    if ! DOSYA="$(en_yeni_yedek "$MOTOR")"; then
        # Atlama notu MESAJIN İÇİNE giriyor: "yedek yok" ile "yedek var ama
        # açamıyorum" bambaşka iki durum ve ikincisinde yapılacak şey belli.
        olcum_yok "$MOTOR için açılabilir yedek yok: $BACKUP_DIR/$MOTOR${EN_YENI_NOT:+ — $EN_YENI_NOT}"
    fi
    [ -n "$EN_YENI_NOT" ] && warn "$EN_YENI_NOT"
fi
[ -f "$DOSYA" ] || olcum_yok "Yedek dosyası yok: $DOSYA"
[ -s "$DOSYA" ] || prova_dustu "Yedek dosyası BOŞ: $DOSYA — geri yüklenecek bir şey yok."

IMAJ="$(motor_imaji "$MOTOR")" || olcum_yok "$MOTOR için imaj adı çözülemedi."
MEM_MB="$PROVA_MEM_MB"
_min="$(katalog_min_mb "$MOTOR")"
[ "$_min" -gt "$MEM_MB" ] && MEM_MB="$_min"

# Ad, çakışmayacak biçimde benzersiz: motor + PID + saniyeli zaman damgası.
# Aynı saniyede iki koşum olsa bile PID'ler farklıdır.
AD="dbstack-prova-$MOTOR-$$-$(date +%Y%m%d%H%M%S)"
PROVA_C="$AD"
HACIM="$AD-veri"
HACIM_ETIKET="$ETIKET"

# ------------------------------------------------------------------- gölge ---
# Gölge kipinde hacim GEÇİCİ DEĞİL: doğrulama geçerse bu hacim üretimin yeni
# kuşağı olacak. Adı bu yüzden rastgele değil, kuşak dizisinin sıradaki üyesi.
if [ "$GOLGE" -eq 1 ]; then
    TABAN="$(uretim_hacmi "$MOTOR")" || golge_reddedildi \
        "Bu motorun veri hacmi katalogda bildirilmemiş — gölge geri yükleme yapılamaz."
    CANLI="$(canli_hacim "$MOTOR" "$TABAN")"
    KUSAK=$(( $(kusak_no "$CANLI") + 1 ))
    HACIM="${TABAN}${KUSAK_AYIRAC}${KUSAK}"
    HACIM_ETIKET="$ETIKET_GOLGE"
    dlog "gölge: canlı kuşak $CANLI → hazırlanacak $HACIM"

    # Hedef zaten varsa DURUYORUZ. İçini bilmediğimiz bir hacmin üstüne
    # yazmak, geri dönüş biletini yok etmek olabilirdi.
    docker volume inspect "$HACIM" >/dev/null 2>&1 && golge_reddedildi \
        "Bir sonraki kuşak hacmi zaten var: $HACIM — önceki bir gölge yarım kalmış olabilir. İçini kontrol edip silin: docker volume rm $HACIM"

    # DİSK MUHASEBESİ ÖNCEDEN VE SAYIYLA. Gölge, üretim hacminin bir kopyası
    # kadar yer ister; felaket anında "yer kalmadı" demek, geri yüklemeyi
    # tamamen kilitlemek olurdu. O yüzden ölçüp söylüyoruz ve hangi yöntemle
    # ölçtüğümüzü de yazıyoruz — tahmini kesin sayı gibi sunmuyoruz.
    GEREK_MB=""; GEREK_KAYNAK=""
    _b="$(hacim_boyut_mb "$CANLI" 2>/dev/null || true)"
    if sayi_mi "${_b:-}" && [ "${_b:-0}" -gt 0 ]; then
        GEREK_MB="$_b"; GEREK_KAYNAK="üretim hacminin ölçülen boyutu"
    else
        _d="$(du -m "$DOSYA" 2>/dev/null | cut -f1)"
        sayi_mi "${_d:-}" || _d=0
        # Sıkıştırılmış döküm açıldığında büyür; 3× kaba ama kasıtlı olarak
        # cömert bir üst sınır. Tahmin olduğunu mesajda söylüyoruz.
        GEREK_MB=$(( _d * 3 )); GEREK_KAYNAK="dökümün 3 katı (üretim hacmi ölçülemedi — TAHMİN)"
    fi
    BOS_MB="$(disk_bos_mb "$CANLI")"
    if sayi_mi "${BOS_MB:-}"; then
        dlog "disk: gereken ~${GEREK_MB} MB ($GEREK_KAYNAK) + ${GOLGE_EMNIYET_MB} MB emniyet, boşta ${BOS_MB} MB"
        if [ "$BOS_MB" -lt $(( GEREK_MB + GOLGE_EMNIYET_MB )) ]; then
            golge_reddedildi "Gölge geri yükleme için disk yetmiyor: ~${GEREK_MB} MB gerekiyor ($GEREK_KAYNAK) + ${GOLGE_EMNIYET_MB} MB emniyet payı, boşta ${BOS_MB} MB var. Yer açın ya da klasik geri yüklemeyi kullanın (üretim hacmine yazar, geri dönüş bileti olmaz)."
        fi
    else
        # 'Ölçemedim' ile 'yeter' aynı şey değil: reddetmiyoruz ama
        # bilmediğimizi de saklamıyoruz.
        warn "Diskteki boş alan ÖLÇÜLEMEDİ — gölge denenecek, yer biterse geri yükleme yarıda kalır."
        dlog "disk boşluğu ölçülemedi (gereken ~${GEREK_MB} MB, $GEREK_KAYNAK)"
    fi
fi

docker inspect "$PROVA_C" >/dev/null 2>&1 \
    && olcum_yok "Geçici container adı zaten kullanımda: $PROVA_C"
if [ "$GOLGE" -eq 0 ]; then
    docker volume inspect "$HACIM" >/dev/null 2>&1 \
        && olcum_yok "Geçici hacim adı zaten kullanımda: $HACIM"
fi

GECICI="$(mktemp -d "${TMPDIR:-/tmp}/dbstack-prova-XXXXXX")" \
    || olcum_yok "Geçici dizin açılamadı."

heading "Geri yükleme provası — $MOTOR"
dlog "yedek     : $DOSYA ($(du -h "$DOSYA" 2>/dev/null | cut -f1))"
dlog "imaj      : $IMAJ"
dlog "container : $PROVA_C  (bellek ${MEM_MB} MB, ağ yok)"
dlog "hacim     : $HACIM"
log  "Üretim container'ına, üretim hacmine ve gateway'e dokunulmuyor."

# ORTAK docker run argümanları. --network none, "üretime dokunmuyoruz" sözünü
# niyete değil çekirdeğe bağlar: bu container'ın yığın ağına giden bir yolu
# yoktur, yanlışlıkla üretime bağlanması MÜMKÜN DEĞİLDİR.
ORTAK=(-d --name "$PROVA_C" --network none --restart no
       --memory "${MEM_MB}m" --memory-swap "${MEM_MB}m"
       --cpu-shares "$PROVA_CPU_SHARES" --label "$ETIKET=1")
# Hacmi ELLE yaratıyoruz: `docker run -v ad:/yol` da yaratır ama ETİKETSİZ —
# yarıda ölen bir koşumun hacmini sonra kimse bulamazdı.
docker volume create --label "$HACIM_ETIKET=1" --label "dbstack-motor=$MOTOR" \
    "$HACIM" >>"$LOG_FILE" 2>&1 \
    || olcum_yok "Hacim yaratılamadı: $HACIM"

# --------------------------------------------------------------- ölçüm başlar
# ÖLÇÜLEN RTO: geçici kopyayı ayağa kaldırmak + yedeği yüklemek. İmaj indirme
# süresi bilerek DIŞARIDA: felaket günü imaj zaten diskte olur. Sağlamlık
# sayımı da dışarıda — o kurtarma değil, doğrulama.
docker image inspect "$IMAJ" >/dev/null 2>&1 || {
    dlog "imaj yerelde yok, indiriliyor (bu süre RTO'ya sayılmaz): $IMAJ"
    docker pull "$IMAJ" >>"$LOG_FILE" 2>&1 \
        || olcum_yok "İmaj indirilemedi: $IMAJ — prova yapılamadı."
}

BASLA="$(date +%s)"

if declare -F "hazirla_$MOTOR" >/dev/null 2>&1; then
    dlog "1/3 yedek geçici hacme yerleştiriliyor"
    "hazirla_$MOTOR" "$DOSYA" \
        || prova_dustu "Yedek geçici kopyaya konulamadı: ${HATA:-sebep bilinmiyor}"
fi

dlog "2/3 geçici $MOTOR açılıyor"
"baslat_$MOTOR" || olcum_yok "Geçici container başlatılamadı ($IMAJ) — ayrıntı: $LOG_FILE"
hazir_bekle "$(hazir_suresi "$MOTOR")" "$PROVA_C" || prova_dustu "$HATA"

dlog "3/3 yedek geri yükleniyor"
"yukle_$MOTOR" "$PROVA_C" "$DOSYA" \
    || prova_dustu "GERİ YÜKLENEMEDİ: ${HATA:-sebep bilinmiyor}"

SANIYE=$(( $(date +%s) - BASLA ))
dok "Geri yükleme tamamlandı — ölçülen RTO: ${SANIYE} sn"

# ------------------------------------------------------------ sağlamlık ----
# "Komut hata vermedi" yetmez: geri yükleme sessizce hiçbir şey yüklemiş
# olabilir (restore_mssql'deki "hiç dönmeyen döngü" tuzağının aynısı, ama bu
# sefer motorun kendi içinde). Bu yüzden kopyayı SAYIYORUZ.
if _s="$("say_$MOTOR" "$PROVA_C")"; then
    R_TABLO="${_s%% *}"; R_SATIR="${_s##* }"
    dlog "geri yüklenen kopya: $R_TABLO tablo / $R_SATIR satır ($(birim_notu "$MOTOR"))"
else
    R_TABLO=null; R_SATIR=null
    warn "Geri yüklenen kopya sayılamadı — sağlamlık kontrolü ÖLÇÜLEMEDİ."
fi

# --------------------------------------------------- şema nesnesi sayımı ---
# Tablo/satır eşleşmesi ŞEMA KAYBINI GÖRMEZ. Bu sayım, "prova geçti"
# rozetinin bugüne kadar iddia ettiği ama ölçmediği şeyi ölçüyor.
R_SEMA=""; P_SEMA=""; SEMA_ESLESME=null; SEMA_NOT=""
if sema_uygulandi "$MOTOR"; then
    if R_SEMA="$("sema_say_$MOTOR" "$PROVA_C")"; then
        dlog "geri yüklenen şema: $R_SEMA (indeks kısıt view trigger rutin)"
    else
        R_SEMA=""
        warn "Geri yüklenen kopyanın ŞEMASI sayılamadı — şema kontrolü ÖLÇÜLEMEDİ."
    fi
fi

# --------------------------------------------------------- üretimle kıyas ---
URETIM_C="$(primary_of "$MOTOR")"
URETIM_NOT=""
if ! container_running "$URETIM_C"; then
    URETIM_NOT="üretim ($URETIM_C) kapalı — karşılaştırma YAPILAMADI"
    warn "$URETIM_NOT"
elif _p="$("say_$MOTOR" "$URETIM_C")"; then
    P_TABLO="${_p%% *}"; P_SATIR="${_p##* }"
    dlog "üretim ($URETIM_C): $P_TABLO tablo / $P_SATIR satır"
    if sema_uygulandi "$MOTOR" && [ -n "$R_SEMA" ]; then
        if P_SEMA="$("sema_say_$MOTOR" "$URETIM_C")"; then
            dlog "üretim şeması : $P_SEMA"
            if [ "$R_SEMA" = "$P_SEMA" ]; then
                SEMA_ESLESME=true
                SEMA_NOT="şema nesneleri birebir"
            else
                # EŞLEŞMEMEK TEK BAŞINA YEDEĞİN SUÇU DEĞİLDİR — yedek
                # alındıktan sonra üretime indeks eklenmiş olabilir. Ama
                # SESSİZ KALMAK, indeks kaybını "geçti" diye göstermekti.
                SEMA_ESLESME=false
                SEMA_NOT="ŞEMA FARKI: $(sema_fark_metni "$R_SEMA" "$P_SEMA") (kopya≠üretim) — yedek alındıktan sonra şema değişmiş olabilir; değişmediyse geri yükleme nesne kaybediyor"
                warn "$SEMA_NOT"
            fi
        else
            P_SEMA=""
            SEMA_NOT="üretimin şeması sayılamadı — şema karşılaştırması ÖLÇÜLEMEDİ"
            warn "$SEMA_NOT"
        fi
    fi
    if [ "$R_TABLO" = "null" ]; then
        # Üretim sayıldı ama KOPYA sayılamadı. İki tarafı karşılaştırmaya
        # kalkarsak "null ≠ 8" çıkar ve match=false basılır — yani panelde
        # "yedek tutmuyor" görünür. Oysa elimizde bir kıyas değil, eksik bir
        # ölçüm var: match null kalmalı.
        URETIM_NOT="üretim okundu ama geri yüklenen kopya sayılamadı — karşılaştırma ÖLÇÜLEMEDİ"
        warn "$URETIM_NOT"
    elif [ "$R_TABLO" = "$P_TABLO" ] && [ "$R_SATIR" = "$P_SATIR" ]; then
        ESLESME=true
        URETIM_NOT="üretimle birebir eşleşti"
    else
        # EŞLEŞMEMEK TEK BAŞINA YEDEĞİN SUÇU DEĞİLDİR: yedek alındıktan sonra
        # üretime yazılan her satır farkı büyütür. Bu yüzden "ok"u değil
        # yalnız "match"i etkiliyor; yorumu operatöre bırakıyoruz.
        ESLESME=false
        URETIM_NOT="üretimle eşleşmedi (kopya $R_TABLO/$R_SATIR, üretim $P_TABLO/$P_SATIR) — yedek alındıktan sonra üretime yazılmış olabilir"
        warn "$URETIM_NOT"
    fi
else
    URETIM_NOT="üretim ($URETIM_C) sayılamadı — karşılaştırma ÖLÇÜLEMEDİ"
    warn "$URETIM_NOT"
fi

# ------------------------------------------------------------------ karar ---
# Geri yükleme hatasız bitip kopyada tek tablo/anahtar çıkmadıysa: bu, bu
# ürünün en pahalı arıza sınıfı (İÇİ BOŞ yedek). Üretim de boşsa doğrudur ve
# geçer; üretim ölçülemiyorsa DOĞRU OLDUĞUNU BİLMİYORUZ, o yüzden düşürüyoruz.
if [ "$R_TABLO" = "null" ]; then
    prova_dustu "Geri yükleme hatasız bitti ama kopya SAYILAMADI — geri yüklendiği doğrulanamadı. Ayrıntı: $LOG_FILE"
fi
if [ "$R_TABLO" -eq 0 ] && [ "$R_SATIR" -eq 0 ]; then
    if [ "$ESLESME" = "true" ]; then
        OK=true
        DETAY="geri yüklendi ama kopya BOŞ; üretim de boş — $URETIM_NOT ($(birim_notu "$MOTOR"))"
        dok "Prova geçti (kopya da üretim de boş)."
        bitir 0
    fi
    prova_dustu "Geri yükleme hatasız bitti ama kopyada TEK KAYIT YOK — bu yedek kurtarma noktası değil. $URETIM_NOT"
fi

OK=true
DETAY="geri yüklendi: $R_TABLO tablo / $R_SATIR satır ($(birim_notu "$MOTOR")), ölçülen RTO ${SANIYE} sn; $URETIM_NOT${SEMA_NOT:+; $SEMA_NOT}"
dok "PROVA GEÇTİ — $MOTOR yedeği gerçekten geri yüklendi (${SANIYE} sn)."
bitir 0
