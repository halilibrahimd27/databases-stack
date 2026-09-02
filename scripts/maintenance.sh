#!/bin/bash
# =============================================================================
# databases-stack — ŞİŞKİNLİK (bloat) ÖLÇÜMÜ VE GÜVENLİ BAKIM
# =============================================================================
#   ./scripts/maintenance.sh durum [motor]   ÖLÇ ve raporla (hiçbir şeyi
#                                            değiştirmez)
#   ./scripts/maintenance.sh bakim <motor>   güvenli bakımı uygula
#
# NEDEN VAR:
# Sil-yaz döngüsü olan tablolar diskte şişer ve bunu kimse görmez:
#   • PostgreSQL bir satırı UPDATE/DELETE ettiğinde eskisini dosyadan
#     SİLMEZ, "ölü satır" (dead tuple) olarak bırakır. Temizliği autovacuum
#     yapar; kapalıysa ya da yetişemiyorsa ölü satırlar birikir.
#   • MariaDB/InnoDB silinen satırların yerini işletim sistemine GERİ
#     VERMEZ; .ibd dosyasının içinde boş sayfa olarak durur (DATA_FREE).
# İkisinde de disk sessizce dolar, sorgular yavaşlar ve sebep görünmez. Bu
# ürün "sunucuya bakmayı bilmeyen" kullanıcı için yazıldı: şişkinliği
# GÖRMESİ ve GÜVENLE temizleyebilmesi gerekiyor.
#
# İKİ KOMUT AYRI, ÇÜNKÜ RİSKLERİ AYRI:
# 'durum' yalnız SELECT çalıştırır; en kötü hâlde yanlış bir sayı basar.
# 'bakim' üretim tablolarına dokunur ve --agresif ile DAKİKALARCA KİLİT
# tutabilir. Tek komutta birleştirilseydi "bir bakayım" diyen kullanıcı
# farkında olmadan tabloyu kilitlerdi.
#
# BU BETİK VERİ SİLMEZ. Çalıştırdığı komutların hiçbiri satır silmez, şema
# değiştirmez: VACUUM / ANALYZE / OPTIMIZE yalnız YERLEŞİMİ ve İSTATİSTİĞİ
# düzenler. Tek gerçek riski KİLİTTİR; bu yüzden kilit tutan her yol
# --agresif'in arkasında ve onaya bağlı.
#
# ÇIKIŞ KODLARI (kapsam dışı ile hata birbirine KARIŞMASIN diye ayrı):
#   0  iş bitti
#   1  bakım DÜŞTÜ — motorun komutu hata verdi
#   2  KAPSAM DIŞI — bu motorda şişkinlik bakımı yok, ya da kullanım
#      hatası (bilinmeyen komut/seçenek, eksik motor)
#   3  ÖLÇÜLEMEDİ — motor kapalı, docker yok, kilit başkasında, sorgu
#      düştü. "Şişkinlik yok" DEMEK DEĞİLDİR.
#   5  ONAY YOK — agresif bakımın planı basıldı, ÜRETİMDE HİÇBİR ŞEY
#      YAPILMADI
#
# SON SATIR HER ZAMAN TEK SATIR JSON'DUR (panel/controller bunu okur):
#   {"engine":…,"command":…,"tables":[{"name":…,"bloat_bytes":N,
#     "bloat_pct":N,"dead_rows":N,"last_autovacuum":…}],
#    "total_bloat_bytes":N,"before_bloat_bytes":…,"after_bloat_bytes":…,
#    "action":…,"aggressive":…,"seconds":N,"ok":…,"detail":…}
#
# ALAN ADLARI HER MOTORDA AYNI, DOLU OLMALARI DEĞİL (restore-drill.sh'taki
# sözleşmenin aynısı): MariaDB'de dead_rows ve last_autovacuum JSON
# null'dur, 0 ya da "" DEĞİL. InnoDB'de "ölü satır" diye bir sayaç,
# autovacuum diye bir iş yoktur. 0 yazsaydık panel "ölü satır yok, her şey
# yolunda" derdi; oysa doğru cevap "bu motorda böyle bir ölçü yok".
#
# MOTOR VERİLMEDEN 'durum' çağrılırsa kapsamdaki AKTİF motorların hepsi
# ölçülür; o zaman engine "hepsi" olur ve tablo adları "<motor>:<ad>" ile
# başlar (iki motorda aynı adlı tablo olabilir; ön ek olmasa satırlar
# birbirine karışırdı). Makine okuyan taraf motoru VEREREK çağırmalı — o
# çağrıda çıktı tek motor, tek satırdır.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3
source scripts/lib/common.sh
load_env

LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/maintenance_$(date +%Y%m%d).log"

# Bakım, yedeklemeyle AYNI kilidi alır. Sebep somut: agresif bakım tabloyu
# yeniden kurar, mariadb-dump ise --single-transaction ile tutarlı bir
# görüntü okur. İkisi çakışınca ya dump saatlerce bekler ya da
# "table definition has changed" ile düşer — o gece yedek alınmamış olur.
# Ayrı bir kilit dosyası açsaydık ikisi birbirini hiç görmezdi.
KILIT="$STACK_ROOT/state/backup.lock"

# Bu makinede ÖLÇÜLEN yeniden yazma hızı burada birikir (aşağıdaki
# "KİLİT SÜRESİ TAHMİNİ" bölümüne bakın).
HIZ_DOSYA="$STACK_ROOT/state/bakim-hizi.env"

mlog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
         | tee -a "$LOG_FILE"; }
mok()  { ok  "$*"; printf '[%s] [OK] %s\n'  "$(date '+%F %T')" "$*" \
         >> "$LOG_FILE"; }
merr() { err "$*"; printf '[%s] [ERR] %s\n' "$(date '+%F %T')" "$*" \
         >> "$LOG_FILE"; }

# Hiçbir bekleme sonsuz değil: askıda kalmış bir bakım hem "sürüyor"
# görünür hem de yedekleme kilidini tutup gece yedeğini öldürür.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman() {   # zaman <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
SURE_SORGU="${BAKIM_SORGU_SURESI:-300}"
SURE_BAKIM="${BAKIM_KOMUT_SURESI:-7200}"

# Alan ayırıcı: 0x1f (ASCII "unit separator"). Sekme DEĞİL: PostgreSQL ve
# MariaDB tırnaklı tanımlayıcıya izin verir, yani bir tablo adı sekme
# içerebilir. O gün satır kayar ve YANLIŞ TABLOYA bakım uygulanırdı.
AYIRAC=$'\x1f'

# Ham sorgu çıktısının toplandığı geçici dizin. Fonksiyonlardan ÖNCE
# tanımlı, çünkü çıkış tuzağı (trap) bunu çağırıyor: argüman ayrıştırma
# sırasında çıkan bir koşumda fonksiyon henüz tanımlı olmasaydı trap
# "command not found" basardı.
GECICI=""
temizle_gecici() {
    [ -n "$GECICI" ] && rm -rf "$GECICI" 2>/dev/null
    return 0
}
gecici_ac() {
    [ -n "$GECICI" ] && return 0
    GECICI="$(mktemp -d "${TMPDIR:-/tmp}/dbstack-bakim-XXXXXX")" || return 1
    return 0
}

# =============================================================================
# KAPSAM
# =============================================================================
# Kapsam BİLEREK dar: yalnız "şişkinlik"in hem ölçülebilir hem de GÜVENLE
# temizlenebilir olduğu iki motor. Diğerlerinde karşılığı ya yok ya
# bambaşka bir iş: MongoDB'de compact, MSSQL'de indeks parçalanması
# (REBUILD), Cassandra'da compaction, Elasticsearch'te force merge. Hepsini
# tek "bakım" başlığı altında toplasaydık aynı onay ekranı çok farklı
# riskleri temsil ederdi; kullanıcı "bakım yap" deyip Cassandra'da saatler
# süren bir compaction başlatırdı.
DESTEKLI="mariadb postgresql"

destekli_mi() {
    local e
    for e in $DESTEKLI; do [ "$e" = "$1" ] && return 0; done
    return 1
}

# tr -d '\r' ŞART: python3'ün print'i Windows'ta CRLF yazar ve bu depo
# Windows'ta düzenleniyor (.gitattributes'taki uyarı bu sınıf hata için
# konmuş). \r taşıyan bir motor kimliği hiçbir karşılaştırmaya uymaz.
katalog_motorlari() {
    catalog_query '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"]))' | tr -d '\r'
}
katalogda_var() {
    local e
    for e in $(katalog_motorlari); do [ "$e" = "$1" ] && return 0; done
    return 1
}

# =============================================================================
# JSON ÇIKTI
# =============================================================================
# Son satır, ölçüm araçlarının hepsi bozulsa bile basılmalı; bu yüzden
# python3'e bağlanmıyoruz (restore-drill.sh'taki gerekçenin aynısı).
js() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\t'/ }"
    printf '"%s"' "$s"
}

# SAYI ya da null. "Bilmiyorum"u 0 diye yazmak bu üründeki en pahalı sessiz
# hata sınıfı: 0 "şişkinlik yok" diye okunur, oysa ölçüm hiç yapılamamıştır.
jsnum() {
    case "${1:-}" in
        ''|*[!0-9.]*|*.*.*|.*|*.) printf 'null' ;;
        *) printf '%s' "$1" ;;
    esac
}

KOMUT="durum"
MOTOR=""
AGRESIF=0
ONAY=0
ADET=10
FILTRE=()

JS_MOTOR="hepsi"
JS_TABLOLAR=""
JS_TOPLAM=0
JS_ONCE=null
JS_SONRA=null
JS_EYLEM=null
SANIYE=0
OK=false
DETAY="çalıştırılmadı"
JSON_BASILDI=0

json_bas() {
    [ "$JSON_BASILDI" -eq 1 ] && return 0
    JSON_BASILDI=1
    local agr=false f
    [ "$AGRESIF" -eq 1 ] && agr=true
    f='{"engine":%s,"command":%s,"tables":[%s]'
    f+=',"total_bloat_bytes":%s,"before_bloat_bytes":%s'
    f+=',"after_bloat_bytes":%s,"action":%s,"aggressive":%s'
    f+=',"seconds":%s,"ok":%s,"detail":%s}\n'
    printf "$f" \
        "$(js "$JS_MOTOR")" "$(js "$KOMUT")" "$JS_TABLOLAR" \
        "$(jsnum "$JS_TOPLAM")" "$JS_ONCE" "$JS_SONRA" "$JS_EYLEM" \
        "$agr" "$SANIYE" "$OK" "$(js "$DETAY")"
}

# Beklenmedik çıkışta da (kabuk hatası, Ctrl+C) JSON şart: çıktısı olmayan
# bir koşum, panel için "hiç çalışmamış" ile aynıdır.
cikista() {
    local kod=$?
    temizle_gecici
    [ "$JSON_BASILDI" -eq 1 ] && return
    [ "$DETAY" = "çalıştırılmadı" ] \
        && DETAY="beklenmedik şekilde sonlandı (çıkış $kod)"
    json_bas
}
trap cikista EXIT
trap 'DETAY="kullanıcı tarafından kesildi (Ctrl+C)"; exit 130' INT TERM

bitir() { json_bas; exit "$1"; }

olcum_yok()   { merr "$*"; DETAY="ölçülemedi: $*";  bitir 3; }
kapsam_disi() { warn "$*"; DETAY="kapsam dışı: $*"; bitir 2; }
bakim_dustu() { merr "$*"; OK=false; DETAY="$*";    bitir 1; }

# =============================================================================
# BİÇİMLEME
# =============================================================================
# LC_ALL=C ŞART: bazı yerel ayarlarda awk ondalık ayırıcı olarak VİRGÜL
# basar ("412,3 GB"). Ekranda tuhaf durur; aynı awk bir sayıyı JSON'a
# üretseydi çıktı hiç ayrıştırılamazdı.
insan_bayt() {
    local b="${1:-}"
    case "$b" in ''|*[!0-9]*) printf '?' ; return 0 ;; esac
    LC_ALL=C awk -v b="$b" 'BEGIN{
        if (b >= 1073741824)   printf "%.1f GB", b/1073741824;
        else if (b >= 1048576) printf "%.0f MB", b/1048576;
        else if (b >= 1024)    printf "%.0f KB", b/1024;
        else                   printf "%d B",  b;
    }'
}

# Uzun tablo adı satır düzenini bozar; SONU korunuyor, başı değil: ad
# "veritabani.sema.tablo" biçiminde ve ayırt edici olan son parçadır.
kisalt() {   # kisalt <metin> <uzunluk>
    local s="$1" n="$2"
    if [ "${#s}" -le "$n" ]; then printf '%s' "$s"
    else printf '…%s' "${s: -$((n - 1))}"; fi
}

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Host'ta veritabanı istemcisi yok; her sorgu container'ın içinden çalışır.
# Parola komut satırına DEĞİL ortama konur (host'ta `ps` çıktısı herkese
# açıktır) — backup.sh ve restore-drill.sh'taki desenin aynısı. Alt kabuk
# şart: export'lar betiğin geri kalanına sızmasın.
my_sorgu() {   # my_sorgu <container> <sql>
    ( export MYSQL_PWD="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
      zaman "$SURE_SORGU" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$2" ) 2>>"$LOG_FILE"
}
my_bakim() {   # my_bakim <container> <sql> — dakikalarca sürebilir
    ( export MYSQL_PWD="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
      zaman "$SURE_BAKIM" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$2" ) 2>>"$LOG_FILE"
}

# ON_ERROR_STOP=1: onsuz psql'in çıkış kodu sürüme ve çağrı biçimine göre
# değişir, yani DÜŞEN bir VACUUM "başarılı" sanılabilir. backup.sh'ta
# sqlcmd için -b bayrağının çözdüğü sorunun aynısı.
pg_sorgu() {   # pg_sorgu <container> <veritabanı> <sql>
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      zaman "$SURE_SORGU" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$2" \
               -v ON_ERROR_STOP=1 -tAq -F "$AYIRAC" -c "$3" ) 2>>"$LOG_FILE"
}
pg_bakim() {   # pg_bakim <container> <veritabanı> <sql> — uzun sürebilir
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      zaman "$SURE_BAKIM" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$2" \
               -v ON_ERROR_STOP=1 -tAq -c "$3" ) 2>>"$LOG_FILE"
}

# Tanımlayıcı tırnaklama. Tablo adları VERİTABANINDAN geliyor, yani bizim
# üretmediğimiz metin: "my table", "büyük-tablo", hatta tırnak içerebilir.
# Tırnaklamadan komuta koysaydık VACUUM/OPTIMIZE söz dizimi hatasıyla düşer
# ve suç "bakım çalışmıyor"a yazılırdı.
pg_kimlik() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
my_kimlik() { local s="${1//\`/\`\`}"; printf '`%s`' "$s"; }

# --tablo ile verilen adları SQL IN listesine çevirir. Tek tırnak İKİYE
# katlanıyor: bu adlar operatörün komut satırından geliyor ve tek tırnak
# içeren bir ad sorguyu tam ortasından böler.
sql_liste() {
    [ "${#FILTRE[@]}" -eq 0 ] && return 1
    local t out=""
    for t in "${FILTRE[@]}"; do
        t="${t//\'/\'\'}"
        out="${out:+$out,}'$t'"
    done
    printf '%s' "$out"
}

# =============================================================================
# ÖLÇÜM
# =============================================================================
# Ölçüm sonucu bu dizilerde durur. Alan sırası HER MOTORDA AYNI; motor
# farkları SQL'in içinde kalıyor, dışarıda tek bir biçim var. Böylece rapor
# ve JSON kodu motor bilmiyor — yeni bir motor eklendiğinde değişmesi
# gereken tek yer o motorun sorgusudur.
#   O_BOS  boşa giden bayt   O_PCT  yüzde     O_OLU  ölü satır ('' = yok)
#   O_SAV  son autovacuum    O_KUL  kullanılan bayt (yeniden yazılacak)
#   O_AD   gösterilen ad     O_Q1/2/3  tırnaklanacak ad parçaları
O_BOS=(); O_PCT=(); O_OLU=(); O_SAV=(); O_KUL=()
O_AD=();  O_Q1=();  O_Q2=();  O_Q3=()
O_TOPLAM=0
O_NOT=""

olcum_sifirla() {
    O_BOS=(); O_PCT=(); O_OLU=(); O_SAV=(); O_KUL=()
    O_AD=();  O_Q1=();  O_Q2=();  O_Q3=()
    O_TOPLAM=0
    O_NOT=""
}

# Sıralanmış ham satırları dizilere okur.
satirlari_al() {   # satirlari_al <ham dosya>
    [ -f "$1" ] || return 0
    local bos pct olu sav kul ad q1 q2 q3
    while IFS="$AYIRAC" read -r bos pct olu sav kul ad q1 q2 q3; do
        [ -z "$ad" ] && continue
        O_BOS+=("$bos"); O_PCT+=("$pct"); O_OLU+=("$olu")
        O_SAV+=("$sav"); O_KUL+=("$kul"); O_AD+=("$ad")
        O_Q1+=("$q1");   O_Q2+=("$q2");   O_Q3+=("$q3")
        case "$bos" in ''|*[!0-9]*) ;; *) O_TOPLAM=$((O_TOPLAM + bos)) ;; esac
    done < "$1"
    return 0
}

# ---------------------------------------------------------------- PostgreSQL
# BOŞA GİDEN ALAN TAHMİNİ: pg_total_relation_size × ölü satır oranı.
#
# Neden bu çarpım: PostgreSQL ölü satırların kapladığı baytı ayrıca
# tutmuyor; elimizde satır SAYILARI (n_dead_tup / n_live_tup) ve nesnenin
# TOPLAM boyutu var. Ölü satırların ortalama boyu canlılarınkiyle aynı
# kabul edilirse boşa giden pay = ölü / (ölü + canlı) olur. Toplam boyutu
# (yalnız yığını değil) çarpıyoruz, çünkü her ölü satırın İNDEKS GİRDİLERİ
# de ölüdür ve yeri VACUUM'a kadar geri gelmez; indeksleri saymayan bir
# tahmin, indeksi ağır tablolarda gerçeğin yarısını gösterir.
# Bu bir TAHMİNDİR, kesin ölçüm değil. Kesini pgstattuple eklentisiyle
# olur ve o eklenti bu yığında kurulu değil — kurulu olmayan bir eklentiye
# bağlanan araç, ihtiyaç duyulduğu gün hiç çalışmaz.
#
# SON AUTOVACUUM da basılıyor, çünkü "neden şişti" sorusunun cevabı çoğu
# zaman orada: hiç koşmamış (autovacuum kapalı ya da tabloda
# autovacuum_enabled=false) veya günler önce koşmuş (yetişemiyor).
#
# BÜTÜN VERİTABANLARI taranıyor: pg_stat_user_tables veritabanı başına
# ayrıdır, tek veritabanına bakan bir araç diğerlerindeki şişkinliği hiç
# görmez.
olc_postgresql() {   # olc_postgresql <container>
    local C="$1" db kosul liste ham sql dblist satir av
    gecici_ac || { O_NOT="geçici dizin açılamadı"; return 1; }
    ham="$GECICI/pg.ham"; : > "$ham"

    dblist="$(pg_sorgu "$C" postgres \
        "SELECT datname FROM pg_database
          WHERE datallowconn AND NOT datistemplate ORDER BY 1;")" \
        || { O_NOT="veritabanı listesi alınamadı"; return 1; }
    [ -n "$dblist" ] || { O_NOT="hiç veritabanı yok"; return 1; }

    # FİLTRE VARSA "ölü satırı olanlar" koşulu KALKAR. Sebep: bakım sonrası
    # ölçümde tam olarak ölü satırı KALMAMIŞ tabloya bakıyoruz; koşul
    # kalsaydı tablo sonuçtan düşer ve "önce 412 MB / sonra —" görünürdü.
    # Oysa doğru cevap "sonra 0" ve bunun yazılması bakımın tek kanıtıdır.
    if liste="$(sql_liste)"; then
        kosul="current_database() || '.' || schemaname || '.' || relname
               IN ($liste)"
    else
        kosul="n_dead_tup > 0"
    fi

    sql="SELECT CASE WHEN n_dead_tup + n_live_tup > 0
                     THEN (pg_total_relation_size(relid)::numeric
                           * n_dead_tup / (n_dead_tup + n_live_tup))::bigint
                     ELSE 0 END,
                CASE WHEN n_dead_tup + n_live_tup > 0
                     THEN round(100.0 * n_dead_tup
                                / (n_dead_tup + n_live_tup), 1)
                     ELSE 0 END,
                n_dead_tup,
                COALESCE(to_char(last_autovacuum,
                                 'YYYY-MM-DD HH24:MI'), ''),
                pg_total_relation_size(relid),
                current_database() || '.' || schemaname || '.' || relname,
                current_database(), schemaname, relname
           FROM pg_stat_user_tables
          WHERE $kosul
          ORDER BY 1 DESC
          LIMIT $ADET;"

    while IFS= read -r db; do
        [ -z "$db" ] && continue
        satir="$(pg_sorgu "$C" "$db" "$sql")" \
            || { O_NOT="'$db' sorgulanamadı"; return 1; }
        [ -n "$satir" ] && printf '%s\n' "$satir" >> "$ham"
    done <<< "$dblist"

    # Veritabanları arası TEK sıralama; sonra ilk $ADET. Her veritabanının
    # kendi ilk 10'unu basmak "en şişkin 10 tablo" DEĞİLDİR.
    LC_ALL=C sort -t "$AYIRAC" -k1,1nr "$ham" 2>/dev/null \
        | grep -v '^[[:space:]]*$' | head -n "$ADET" > "$ham.sirali"
    satirlari_al "$ham.sirali"

    # Autovacuum GENEL olarak kapalıysa cevap zaten burada; tablo tablo
    # bakmadan söylüyoruz.
    av="$(pg_sorgu "$C" postgres "SHOW autovacuum;" | tr -d '\r[:blank:]')"
    case "$av" in
        off) O_NOT="autovacuum SUNUCU GENELİNDE KAPALI — ölü satırları"
             O_NOT="$O_NOT hiçbir arka plan işi toplamıyor" ;;
    esac
    return 0
}

# ------------------------------------------------------------------ MariaDB
# InnoDB'de ölçü DATA_FREE: tablonun kendi .ibd dosyasında ayrılmış ama
# KULLANILMAYAN alan. Silinen satırların yeri buraya düşer ve işletim
# sistemine geri dönmez; oran = DATA_FREE / (veri + indeks + DATA_FREE).
#
# innodb_file_per_table KAPALIYSA BU SAYI YALAN OLUR: o kipte bütün
# tablolar tek paylaşılan tablo alanında (ibdata1) durur ve
# information_schema HER TABLO için o paylaşılan alanın boşunu basar. Yani
# 40 tablolu bir sunucuda aynı 2 GB kırk kez sayılır ve "80 GB boşa
# gidiyor" gibi bir toplam çıkar. Bu yüzden ayarı okuyup söylüyoruz —
# yanlış sayıyı sessizce basmaktansa neye baktığımızı söylemek yeğdir.
olc_mariadb() {   # olc_mariadb <container>
    local C="$1" kosul liste ham sql satir fpt
    gecici_ac || { O_NOT="geçici dizin açılamadı"; return 1; }
    ham="$GECICI/my.ham"; : > "$ham"

    if liste="$(sql_liste)"; then
        kosul="CONCAT(TABLE_SCHEMA,'.',TABLE_NAME) IN ($liste)"
    else
        kosul="DATA_FREE > 0"
    fi

    # CONCAT_WS(CHAR(31),…): tek sütun üretiyoruz ki istemcinin sekmeyle
    # ayırdığı çıktıya güvenmek zorunda kalmayalım (tablo adı sekme
    # içerebilir). Ölü satır ve son autovacuum alanları BOŞ geçiliyor:
    # InnoDB'de ikisinin de karşılığı yok, JSON'da null olacaklar.
    sql="SELECT CONCAT_WS(CHAR(31),
                  IFNULL(DATA_FREE,0),
                  ROUND(100 * IFNULL(DATA_FREE,0)
                        / GREATEST(IFNULL(DATA_LENGTH,0)
                                   + IFNULL(INDEX_LENGTH,0)
                                   + IFNULL(DATA_FREE,0), 1), 1),
                  '', '',
                  IFNULL(DATA_LENGTH,0) + IFNULL(INDEX_LENGTH,0),
                  CONCAT(TABLE_SCHEMA,'.',TABLE_NAME),
                  '', TABLE_SCHEMA, TABLE_NAME)
           FROM information_schema.TABLES
          WHERE ENGINE = 'InnoDB' AND TABLE_TYPE = 'BASE TABLE'
            AND TABLE_SCHEMA NOT IN ('information_schema',
                'performance_schema','mysql','sys')
            AND ($kosul)
          ORDER BY DATA_FREE DESC
          LIMIT $ADET;"

    satir="$(my_sorgu "$C" "$sql")" \
        || { O_NOT="information_schema sorgulanamadı"; return 1; }
    [ -n "$satir" ] && printf '%s\n' "$satir" > "$ham"
    grep -v '^[[:space:]]*$' "$ham" 2>/dev/null | head -n "$ADET" \
        > "$ham.sirali"
    satirlari_al "$ham.sirali"

    fpt="$(my_sorgu "$C" "SELECT @@innodb_file_per_table;" \
           | tr -d '\r[:blank:]')"
    case "$fpt" in
        0|OFF|off)
            O_NOT="innodb_file_per_table KAPALI — DATA_FREE paylaşılan"
            O_NOT="$O_NOT tablo alanının boşunu gösterir, tablo başına"
            O_NOT="$O_NOT değil; aşağıdaki sayılar aynı boşluğu tekrar"
            O_NOT="$O_NOT tekrar sayar" ;;
    esac
    return 0
}

olc() {   # olc <motor> <container>
    olcum_sifirla
    case "$1" in
        postgresql) olc_postgresql "$2" ;;
        mariadb)    olc_mariadb "$2" ;;
        *)          return 1 ;;
    esac
}

# =============================================================================
# RAPOR
# =============================================================================
# Sütun genişlikleri 79 sütuna sığacak şekilde seçildi; ad SONDAN kırpılır.
rapor_yaz() {   # rapor_yaz <motor>
    local motor="$1" i n="${#O_AD[@]}" sav
    if [ "$n" -eq 0 ]; then
        ok "Şişkinlik bulunmadı — ölçülen tablolarda boşa giden alan yok."
        return 0
    fi
    printf '  %-34s %9s %5s %8s %s\n' \
        "tablo" "boş alan" "oran" "ölü sat." "son autovacuum"
    printf '  %s\n' "$(printf '%.0s-' $(seq 1 74))"
    for i in $(seq 0 $((n - 1))); do
        # BOŞ ALANIN ANLAMI MOTORA GÖRE DEĞİŞİR: PostgreSQL'de "autovacuum
        # bu tabloya hiç uğramadı" (asıl bulgu), MariaDB'de "böyle bir iş
        # yok". İkisini aynı yazsaydık okuyan, InnoDB'de çalışması gereken
        # bir şeyin çalışmadığını sanırdı.
        sav="${O_SAV[$i]}"
        if [ -z "$sav" ]; then
            case "$motor" in
                postgresql) sav="hiç koşmamış" ;;
                *)          sav="—" ;;
            esac
        fi
        printf '  %-34s %9s %4s%% %8s %s\n' \
            "$(kisalt "${O_AD[$i]}" 34)" \
            "$(insan_bayt "${O_BOS[$i]}")" \
            "${O_PCT[$i]:-?}" \
            "${O_OLU[$i]:-—}" \
            "$sav"
    done
    case "$motor" in
        mariadb)
            printf '  (InnoDB: ölü satır sayacı ve autovacuum yok)\n' ;;
    esac
    printf '\n  %stoplam boşa giden alan: %s%s  (%d tablo)\n' \
        "$BOLD" "$(insan_bayt "$O_TOPLAM")" "$NC" "$n"
}

# Ölçümü JSON parçasına çevirir. Ön ek yalnız çok motorlu 'durum'da dolu.
json_parcasi() {   # json_parcasi <ön ek>
    local onek="$1" i n="${#O_AD[@]}" out=""
    for i in $(seq 0 $((n - 1))); do
        out="${out:+$out,}"
        out="$out{\"name\":$(js "$onek${O_AD[$i]}")"
        out="$out,\"bloat_bytes\":$(jsnum "${O_BOS[$i]}")"
        out="$out,\"bloat_pct\":$(jsnum "${O_PCT[$i]}")"
        out="$out,\"dead_rows\":$(jsnum "${O_OLU[$i]}")"
        if [ -n "${O_SAV[$i]}" ]; then
            out="$out,\"last_autovacuum\":$(js "${O_SAV[$i]}")}"
        else
            # BOŞ DİZGE DEĞİL null: "hiç koşmadı" bir tarih değildir ve
            # MariaDB'de böyle bir iş hiç yoktur. "" yazsaydık panel onu
            # bilinmeyen biçimde bir tarih sanıp ayrıştırmaya çalışırdı.
            out="$out,\"last_autovacuum\":null}"
        fi
    done
    printf '%s' "$out"
}

# =============================================================================
# KİLİT SÜRESİ TAHMİNİ  (agresif bakım)
# =============================================================================
# NE HESAPLIYORUZ: agresif bakım tabloyu YENİDEN KURAR — VACUUM FULL yeni
# bir dosyaya kopyalar ve bütün indeksleri baştan üretir; OPTIMIZE TABLE
# InnoDB'de ALTER TABLE … FORCE'a dönüşür ve aynısını yapar. İşin süresi bu
# yüzden yeniden yazılacak BAYT ile orantılıdır:
#
#     kilit_saniye = yeniden_yazilacak_bayt / (MB_SN × 1 MB)
#
#   • yeniden_yazilacak_bayt — PostgreSQL'de pg_total_relation_size (yığın
#     + TOAST + indeksler; hepsi yeniden kuruluyor), MariaDB'de
#     DATA_LENGTH + INDEX_LENGTH.
#   • MB_SN üç kaynaktan gelir, sırayla:
#       1) BAKIM_MBPS ortam değişkeni — diskini ölçmüş operatörün son sözü.
#       2) state/bakim-hizi.env — BU MAKİNEDE önceki agresif bakımlarda
#          GERÇEKTEN ölçülmüş hız (aşağıda hiz_ogren).
#       3) 50 MB/sn — ilk koşumun varsayılanı.
#
# NEDEN 50 MB/sn: bu iş tek iş parçacıklıdır, nesneyi baştan sona OKUR, bir
# kopyasını YAZAR ve her indeksi sıralayıp yeniden üretir; yani ham ardışık
# disk hızının (tipik bir sunucu SSD'sinde 200-500 MB/sn) çok altında
# kalır. Tahmin BİLEREK KÖTÜMSER: kullanıcı bu sayıya bakıp kesintiyi kabul
# edip etmeyeceğine karar veriyor. "5 sn" deyip 60 sn kilitlemek, "60 sn"
# deyip 5 sn'de bitirmekten çok daha pahalı bir yanılmadır.
#
# TAHMİNE DAHİL OLMAYAN: kilidi ALMAK için beklenen süre. Tabloyu okuyan
# uzun bir sorgu varsa agresif bakım o bitene kadar sıraya girer ve bu süre
# tamamen o sorguya bağlıdır. Bilmediğimiz bir şeyi tahmine katmıyoruz;
# bunun yerine ekranda söylüyoruz.
VARSAYILAN_MBPS=50

hiz_oku() {
    local h="${BAKIM_MBPS:-}"
    if [ -z "$h" ] && [ -f "$HIZ_DOSYA" ]; then
        h="$(env_get BAKIM_MBPS_OLCULEN "$HIZ_DOSYA" 2>/dev/null)"
    fi
    case "${h:-}" in
        ''|*[!0-9]*|0) printf '%s' "$VARSAYILAN_MBPS" ;;
        *)             printf '%s' "$h" ;;
    esac
}

tahmini_sn() {   # tahmini_sn <bayt>
    local b="${1:-0}" mbps; mbps="$(hiz_oku)"
    case "$b" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
    LC_ALL=C awk -v b="$b" -v m="$mbps" 'BEGIN{
        s = b / (m * 1048576);
        if (s < 1) s = 1;
        printf "%d", (s == int(s) ? s : int(s) + 1);
    }'
}

# GERÇEKLEŞEN hızı öğrenip bir dahaki tahmini düzeltir. Üstel hareketli
# ortalama (yarı yarıya): tek bir yavaş koşum (o sırada koşan bir yedek,
# dolmuş bir disk) tahmini kalıcı olarak bozmasın, ama makine gerçekten
# hızlıysa birkaç koşumda oraya yaklaşsın.
# 2 SANİYENİN ALTINDAKİ KOŞUM KAYDEDİLMEZ: küçük bir tabloda süreyi
# container'a girmek, kilidi almak ve istemci el sıkışması belirler;
# oradan çıkan "MB/sn" makinenin diski hakkında hiçbir şey söylemez ve bir
# dahaki büyük tablo için felaket bir tahmin üretir. Aynı sebeple 1 MB'ın
# altındaki iş de sayılmaz.
hiz_ogren() {   # hiz_ogren <bayt> <saniye>
    local b="${1:-0}" sn="${2:-0}" eski yeni
    case "$b$sn" in *[!0-9]*) return 0 ;; esac
    [ "$sn" -lt 2 ] && return 0
    [ "$b" -lt 1048576 ] && return 0
    eski="$(hiz_oku)"
    yeni="$(LC_ALL=C awk -v b="$b" -v s="$sn" -v e="$eski" 'BEGIN{
        g = b / 1048576 / s;
        v = (e + g) / 2;
        if (v < 1) v = 1;
        printf "%d", v + 0.5;
    }')"
    case "$yeni" in ''|*[!0-9]*) return 0 ;; esac
    mkdir -p "$(dirname "$HIZ_DOSYA")" 2>/dev/null || return 0
    env_set BAKIM_MBPS_OLCULEN "$yeni" "$HIZ_DOSYA" 2>/dev/null || return 0
    mlog "ölçülen yeniden yazma hızı: ${yeni} MB/sn — tahminler bundan" \
         "sonra bunu kullanır ($HIZ_DOSYA)"
    return 0
}

# =============================================================================
# BAKIM
# =============================================================================
# GÜVENLİ (varsayılan) ve AGRESİF yolların farkı KİLİTTİR, iş değil:
#
#   PostgreSQL
#     güvenli : VACUUM (ANALYZE) — tabloyu KİLİTLEMEZ. Okuma ve yazma
#               sürerken çalışır; ölü satırları "yeniden kullanılabilir"
#               diye işaretler. DOSYA KÜÇÜLMEZ: şişkinliğin büyümesi
#               durur, yer işletim sistemine geri DÖNMEZ.
#     agresif : VACUUM (FULL, ANALYZE) — yeri gerçekten geri verir ama
#               tabloyu ACCESS EXCLUSIVE ile kilitler: SELECT bile bekler.
#               Tablonun bir KOPYASINI yazdığı için işlem sırasında tablo
#               boyutu kadar EK DİSK ister.
#   MariaDB
#     güvenli : ANALYZE TABLE — yalnız istatistik tazeler. Boşa giden
#               alanı GERİ VERMEZ; iyileştirdiği şey planlayıcının
#               seçimleridir.
#     agresif : OPTIMIZE TABLE — InnoDB'de tabloyu yeniden kurar (sunucu
#               "doing recreate + analyze instead" notunu basar), yeri geri
#               verir ve bu sırada tabloyu kilitler.
#
# ÇOĞALTMAYA ETKİSİ: OPTIMIZE TABLE binlog'a yazılır ve replikada da
# çalışır — replika aynı süre boyunca o tabloda gecikir. VACUUM FULL ise
# tablo boyutu kadar WAL üretir; akış replikasyonu bu WAL'ı taşımak
# zorunda kalır. İkisi de "yalnız ana kopyayı ilgilendiren" işler
# değildir; bu yüzden onay metninde yazıyor.
bakim_komutu() {   # bakim_komutu <motor>
    case "$1" in
        postgresql)
            if [ "$AGRESIF" -eq 1 ]; then printf 'VACUUM (FULL, ANALYZE)'
            else printf 'VACUUM (ANALYZE)'; fi ;;
        mariadb)
            if [ "$AGRESIF" -eq 1 ]; then printf 'OPTIMIZE TABLE'
            else printf 'ANALYZE TABLE'; fi ;;
    esac
}

bakim_uygula_postgresql() {   # <container> <dizin indisi>
    local C="$1" i="$2" db sema rel sql
    db="${O_Q1[$i]}"; sema="${O_Q2[$i]}"; rel="${O_Q3[$i]}"
    if [ "$AGRESIF" -eq 1 ]; then
        sql="VACUUM (FULL, ANALYZE) $(pg_kimlik "$sema").$(pg_kimlik "$rel");"
    else
        sql="VACUUM (ANALYZE) $(pg_kimlik "$sema").$(pg_kimlik "$rel");"
    fi
    # TABLO BAŞINA AYRI ÇAĞRI. Birden çok VACUUM'u tek -c dizgesinde
    # göndermek işe yaramaz: psql onları örtük bir işlem bloğunda çalıştırır
    # ve PostgreSQL "VACUUM cannot run inside a transaction block" der.
    # Ayrıca tablo tablo koşmak, biri düştüğünde HANGİSİNİN düştüğünü
    # söyleyebilmeyi sağlıyor.
    pg_bakim "$C" "$db" "$sql" >>"$LOG_FILE" 2>&1
}

bakim_uygula_mariadb() {   # <container> <dizin indisi>
    local C="$1" i="$2" sema tbl sql cikti
    sema="${O_Q2[$i]}"; tbl="${O_Q3[$i]}"
    if [ "$AGRESIF" -eq 1 ]; then
        sql="OPTIMIZE TABLE $(my_kimlik "$sema").$(my_kimlik "$tbl");"
    else
        sql="ANALYZE TABLE $(my_kimlik "$sema").$(my_kimlik "$tbl");"
    fi
    cikti="$(my_bakim "$C" "$sql")" || return 1
    printf '%s\n' "$cikti" >> "$LOG_FILE"
    # ÇIKIŞ KODU YETMEZ. OPTIMIZE/ANALYZE TABLE hatayı sonuç KÜMESİNDE
    # bildirir, istemci yine 0 ile çıkar. Üstelik InnoDB'de her OPTIMIZE
    # bir "note" satırı basar ("Table does not support optimize, doing
    # recreate + analyze instead") ve bu NORMALDİR. Bu yüzden yalnız
    # Msg_type alanı 'error' olan satırlara bakıyoruz; "note gördüm,
    # düştü" demek her agresif bakımı başarısız gösterirdi.
    printf '%s\n' "$cikti" | awk -F'\t' '
        tolower($3) == "error" { n++ }
        END { exit (n ? 1 : 0) }'
}

bakim_uygula() {   # bakim_uygula <motor> <container> <indis>
    case "$1" in
        postgresql) bakim_uygula_postgresql "$2" "$3" ;;
        mariadb)    bakim_uygula_mariadb "$2" "$3" ;;
        *)          return 1 ;;
    esac
}

# =============================================================================
# KİLİT
# =============================================================================
# Yalnız 'bakim' kilit alır. 'durum' almaz: o yalnız SELECT çalıştırır ve
# kilit isteseydi gece yedeği sürerken "durum" bile çalışmazdı — oysa
# operatörün en çok bakmak isteyeceği an tam olarak o andır.
kilit_al() {
    command -v flock >/dev/null 2>&1 \
        || olcum_yok "flock (util-linux) yok — bakım ile yedeklemenin" \
                     "çakışmadığı garanti edilemez."
    mkdir -p "$(dirname "$KILIT")" 2>/dev/null || true
    exec 9>>"$KILIT" || olcum_yok "Kilit dosyası açılamadı: $KILIT"
    flock -n 9 || olcum_yok "Yedekleme/bakım kilidi başkasında" \
        "($KILIT) — yedekleme, geri yükleme ya da başka bir bakım" \
        "sürüyor. HİÇBİR ŞEY YAPILMADI."
}

# =============================================================================
# KULLANIM
# =============================================================================
kullanim() {
cat <<'EOF'

Şişkinlik ölçümü ve bakım — databases-stack

  ./scripts/maintenance.sh durum [motor]
  ./scripts/maintenance.sh bakim <motor> [seçenekler]

  durum   Ölçer ve raporlar; HİÇBİR ŞEYİ DEĞİŞTİRMEZ. Motor verilmezse
          kapsamdaki çalışan motorların hepsi ölçülür.
  bakim   Güvenli bakımı uygular (PostgreSQL: VACUUM (ANALYZE),
          MariaDB: ANALYZE TABLE). Bunlar tabloyu KİLİTLEMEZ.

  Seçenekler
    --agresif        Yeri GERÇEKTEN geri veren ama tabloyu TAMAMEN
                     KİLİTLEYEN bakım (PostgreSQL: VACUUM FULL,
                     MariaDB: OPTIMIZE TABLE). Tahmini kilit süresi
                     yazılır ve onay istenir.
    --onayla         Agresif bakımın onayını komut satırından ver
                     (cron / panel için; soru sorulmaz).
    --tablo <ad>     Yalnız bu tabloya bak / bu tabloya bakım yap.
                     Birden çok kez verilebilir.
                     Ad biçimi: PostgreSQL 'veritabani.sema.tablo',
                                MariaDB   'veritabani.tablo'.
    --adet <n>       En şişkin kaç tablo (varsayılan 10, en çok 200).

  Kapsam: mariadb, postgresql. Diğer motorlarda şişkinliğin karşılığı
  bambaşka bir iştir (compact / REBUILD / compaction / force merge) ve
  bu betiğin kapsamı dışındadır — çıkış kodu 2.

  Örnekler
    ./scripts/maintenance.sh durum
    ./scripts/maintenance.sh durum postgresql --adet 20
    ./scripts/maintenance.sh bakim postgresql
    ./scripts/maintenance.sh bakim mariadb --agresif --onayla

EOF
}

# =============================================================================
# ARGÜMANLAR
# =============================================================================
if [ $# -gt 0 ]; then
    case "$1" in
        durum|bakim) KOMUT="$1"; shift ;;
        -h|--yardim|yardim)
            kullanim; DETAY="yardım basıldı"; bitir 2 ;;
        -*) ;;   # seçenek: komut varsayılan 'durum' kalsın
        *)  # Sık yapılan hata: komut yerine doğrudan motor adı yazmak.
            if katalogda_var "$1"; then
                kullanim
                kapsam_disi "Komut eksik: '$1' bir motor adı. Şunu" \
                    "demek istediniz: ./scripts/maintenance.sh durum $1"
            fi
            kullanim
            kapsam_disi "Bilinmeyen komut: $1" ;;
    esac
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --agresif)  AGRESIF=1 ;;
        --onayla)   ONAY=1 ;;
        --tablo)
            [ $# -ge 2 ] || { kullanim; kapsam_disi "--tablo bir ad ister."; }
            FILTRE+=("$2"); shift ;;
        --adet)
            [ $# -ge 2 ] || { kullanim; kapsam_disi "--adet bir sayı ister."; }
            case "$2" in
                ''|*[!0-9]*|0)
                    kapsam_disi "--adet 1-200 arası olmalı: $2" ;;
            esac
            [ "$2" -gt 200 ] && kapsam_disi "--adet en çok 200: $2"
            ADET="$2"; shift ;;
        -h|--yardim) kullanim; DETAY="yardım basıldı"; bitir 2 ;;
        -*) kullanim; kapsam_disi "Bilinmeyen seçenek: $1" ;;
        *)  if [ -z "$MOTOR" ]; then
                MOTOR="$1"
                # JSON'daki engine alanı DA hemen doluyor: motor
                # okunduktan SONRA gelen bir seçenek hatasında (ör.
                # "durum mariadb --adet 0") çıktı "hepsi" derdi ve panel
                # hatayı yanlış motora yazardı.
                JS_MOTOR="$1"
            else kapsam_disi "Fazladan argüman: $1"; fi ;;
    esac
    shift
done

if [ "$KOMUT" = "bakim" ] && [ -z "$MOTOR" ]; then
    kullanim
    kapsam_disi "'bakim' bir motor ister — hangi motora bakım" \
        "yapılacağı tahmin edilemez."
fi

if [ -n "$MOTOR" ]; then
    JS_MOTOR="$MOTOR"
    if ! katalogda_var "$MOTOR"; then
        kapsam_disi "Kataloğda böyle bir motor yok: $MOTOR" \
            "(bkz. catalog.json)"
    fi
    if ! destekli_mi "$MOTOR"; then
        kapsam_disi "Bu motorda şişkinlik bakımı yok: $MOTOR —" \
            "kapsam: $DESTEKLI. Diğer motorlarda karşılığı farklı bir" \
            "iştir (MongoDB compact, MSSQL indeks REBUILD, Cassandra" \
            "compaction, Elasticsearch force merge) ve bu betikte" \
            "uygulanmadı."
    fi
fi

if [ "${#FILTRE[@]}" -gt 0 ] && [ -z "$MOTOR" ]; then
    kapsam_disi "--tablo yalnız motor verildiğinde anlamlı (adın hangi" \
        "motorda aranacağı belli olmalı)."
fi

command -v docker >/dev/null 2>&1 \
    || olcum_yok "docker bulunamadı — motorların içine bakılamıyor."
docker info >/dev/null 2>&1 \
    || olcum_yok "docker'a erişilemiyor (servis kapalı ya da yetki yok)."

# =============================================================================
# DURUM
# =============================================================================
durum_calistir() {
    local hedefler="" eid C olculen=0 parca onek=""

    if [ -n "$MOTOR" ]; then
        hedefler="$MOTOR"
    else
        for eid in $DESTEKLI; do
            container_running "$(primary_of "$eid")" \
                && hedefler="${hedefler:+$hedefler }$eid"
        done
        [ -n "$hedefler" ] \
            || olcum_yok "Kapsamdaki motorların ($DESTEKLI) hiçbiri" \
                "çalışmıyor — ölçülecek bir şey yok."
    fi

    for eid in $hedefler; do
        C="$(primary_of "$eid")"
        if ! container_running "$C"; then
            # Motor KAPALI. Tek motor istendiyse bu bir ölçüm yokluğudur ve
            # 0 ile çıkmak yalan olurdu: "şişkinlik yok" ile "bakamadım"
            # aynı şey değildir.
            if [ -n "$MOTOR" ]; then
                olcum_yok "$eid kapalı (container: $C) — şişkinlik" \
                    "ölçülemez. Önce açın: ./stack.sh up $eid"
            fi
            continue
        fi
        heading "$eid — şişkinlik durumu ($C)"
        if ! olc "$eid" "$C"; then
            if [ -n "$MOTOR" ]; then
                olcum_yok "$eid ölçülemedi: ${O_NOT:-sorgu düştü}." \
                    "Ayrıntı: $LOG_FILE"
            fi
            warn "$eid ölçülemedi: ${O_NOT:-sorgu düştü}"
            continue
        fi
        [ -n "$O_NOT" ] && warn "$O_NOT"
        rapor_yaz "$eid"
        onek=""
        [ -z "$MOTOR" ] && onek="$eid:"
        parca="$(json_parcasi "$onek")"
        [ -n "$parca" ] && JS_TABLOLAR="${JS_TABLOLAR:+$JS_TABLOLAR,}$parca"
        JS_TOPLAM=$((JS_TOPLAM + O_TOPLAM))
        olculen=$((olculen + 1))
        echo
    done

    [ "$olculen" -gt 0 ] || olcum_yok "Hiçbir motor ölçülemedi."

    OK=true
    DETAY="ölçüldü: toplam $JS_TOPLAM bayt boşa gidiyor"
    if [ "$JS_TOPLAM" -gt 0 ]; then
        log "Bu alanı geri almak için: ./scripts/maintenance.sh bakim <motor>"
        log "Yalnız --agresif yeri işletim sistemine GERİ VERİR ve" \
            "tabloyu kilitler."
    fi
    bitir 0
}

# =============================================================================
# BAKIM
# =============================================================================
bakim_calistir() {
    local C i n toplam_kul=0 tahmin sn0 basla bitis eylem cevap
    local dusen=0 dusen_ad="" once_toplam=0
    local hedef_adlar=()
    C="$(primary_of "$MOTOR")"
    container_running "$C" \
        || olcum_yok "$MOTOR kapalı (container: $C) — bakım" \
            "yapılamaz. Önce açın: ./stack.sh up $MOTOR"

    heading "$MOTOR — bakım öncesi ölçüm ($C)"
    olc "$MOTOR" "$C" \
        || olcum_yok "$MOTOR ölçülemedi: ${O_NOT:-sorgu düştü}." \
            "Bakım YAPILMADI — neyi düzelteceğini bilmeyen bir bakım," \
            "tanımı gereği körlemedir."
    [ -n "$O_NOT" ] && warn "$O_NOT"
    rapor_yaz "$MOTOR"

    n="${#O_AD[@]}"
    if [ "$n" -eq 0 ]; then
        OK=true
        JS_ONCE=0; JS_SONRA=0; JS_EYLEM="$(js "yok")"
        DETAY="bakıma gerek yok: ölçülen tablolarda boşa giden alan yok"
        ok "Bakıma gerek yok — şişkinlik bulunmadı."
        bitir 0
    fi

    # Hedefler artık SABİT: bakım sonrası ölçüm TAM OLARAK bu tablolara
    # bakacak. Sabitlemeseydik "sonra" ölçümü yeniden en şişkin N tabloyu
    # seçerdi ve bakım yaptığımız tablolar listeden düşünce yerlerine
    # BAŞKA tablolar gelirdi: "önce 412 MB, sonra 380 MB" gibi, bakımla
    # hiç ilgisi olmayan bir karşılaştırma çıkardı.
    for i in $(seq 0 $((n - 1))); do
        hedef_adlar+=("${O_AD[$i]}")
        case "${O_KUL[$i]}" in
            ''|*[!0-9]*) ;;
            *) toplam_kul=$((toplam_kul + O_KUL[i])) ;;
        esac
    done
    once_toplam="$O_TOPLAM"
    JS_ONCE="$(jsnum "$O_TOPLAM")"

    # ------------------------------------------------------------- onay ----
    eylem="$(bakim_komutu "$MOTOR")"
    JS_EYLEM="$(js "$eylem")"
    heading "Yapılacak iş"
    log "komut : $eylem"
    # "CANLI VERİ" demek şart: boşa giden alanla karıştırılmasın. Agresif
    # bakım boşluğu KOPYALAMAZ, canlı satırları yeni bir dosyaya yazar —
    # bu yüzden 44 MB boşluğu olan bir tabloda yeniden yazılacak miktar
    # 16 KB de olabilir. Süreyi belirleyen bu ikinci sayıdır.
    log "tablo : $n adet, yeniden yazılacak canlı veri:" \
        "$(insan_bayt "$toplam_kul")"

    if [ "$AGRESIF" -eq 1 ]; then
        tahmin="$(tahmini_sn "$toplam_kul")"
        printf '\n'
        warn "AGRESİF BAKIM — bu tablolar işlem boyunca TAMAMEN KİLİTLİ."
        warn "  Okuma da yazma da bekler; uygulamanız o süre boyunca durur."
        log  "  Tahmini kilit süresi: ~${tahmin} sn" \
             "($(hiz_oku) MB/sn varsayımıyla)"
        log  "  Tablo başına:"
        for i in $(seq 0 $((n - 1))); do
            printf '    %-40s %8s  ~%s sn\n' \
                "$(kisalt "${O_AD[$i]}" 40)" \
                "$(insan_bayt "${O_KUL[$i]}")" \
                "$(tahmini_sn "${O_KUL[$i]}")"
        done
        log  "  Bu süreye kilidi ALMAK için beklenecek zaman DAHİL DEĞİL:"
        log  "  tabloyu okuyan uzun bir sorgu varsa bakım onu bekler."
        case "$MOTOR" in
            postgresql)
                log "  PostgreSQL VACUUM FULL tablonun KOPYASINI" \
                    "yazar: işlem sırasında tablo boyutu kadar EK DİSK" \
                    "gerekir." ;;
            mariadb)
                log "  OPTIMIZE TABLE binlog'a yazılır: replika da" \
                    "aynı işi yapar ve o süre boyunca gecikir." ;;
        esac
        printf '\n'

        if [ "$ONAY" -ne 1 ] && [ -t 0 ]; then
            printf '  Devam edilsin mi? (evet/hayır): '
            cevap=""
            read -r cevap || cevap=""
            case "$cevap" in
                evet|EVET|e|E|yes|y|Y) ONAY=1 ;;
            esac
        fi
        if [ "$ONAY" -ne 1 ]; then
            warn "ONAY YOK — hiçbir şey yapılmadı."
            log  "Onaylayarak çalıştırmak için:" \
                 "./scripts/maintenance.sh bakim $MOTOR --agresif --onayla"
            DETAY="onay yok (--agresif için --onayla verilmedi):"
            DETAY="$DETAY plan basıldı, üretimde hiçbir şey yapılmadı"
            bitir 5
        fi
    fi

    # ------------------------------------------------------------ uygula ---
    kilit_al

    heading "Bakım uygulanıyor"
    basla="$(date +%s)"
    for i in $(seq 0 $((n - 1))); do
        sn0="$(date +%s)"
        mlog "  $eylem ${O_AD[$i]} ($(insan_bayt "${O_KUL[$i]}"))"
        if bakim_uygula "$MOTOR" "$C" "$i"; then
            mlog "    bitti — $(( $(date +%s) - sn0 )) sn"
        else
            dusen=$((dusen + 1))
            dusen_ad="${dusen_ad:+$dusen_ad, }${O_AD[$i]}"
            merr "    DÜŞTÜ: ${O_AD[$i]} — ayrıntı: $LOG_FILE"
        fi
    done
    bitis="$(date +%s)"
    SANIYE=$((bitis - basla))

    [ "$AGRESIF" -eq 1 ] && [ "$dusen" -eq 0 ] \
        && hiz_ogren "$toplam_kul" "$SANIYE"

    # ------------------------------------------------------------- sonra ---
    # İSTATİSTİKLER ANINDA GÜNCELLENMEZ. PostgreSQL'de VACUUM bittiğinde
    # sayaçları istatistik altyapısına BİLDİRİR, o da okuyucuya bir
    # görüntü olarak sunar; hemen sorgulanırsa ESKİ ölü satır sayısı
    # okunabilir. O zaman "önce 412 MB, sonra 412 MB" yazardık ve araç
    # hiçbir şey yapmamış görünürdü. Kısa bekleme bu yanlış raporu
    # engelliyor; bakımın kendi süresinin yanında ihmal edilebilir.
    sleep 2

    FILTRE=("${hedef_adlar[@]}")
    heading "$MOTOR — bakım sonrası ölçüm"
    if ! olc "$MOTOR" "$C"; then
        # Bakım yapıldı ama sonucu ölçemedik. Bu "başarılı" DEĞİLDİR:
        # işe yarayıp yaramadığının tek kanıtı bu ölçümdür.
        JS_SONRA=null
        olcum_yok "Bakım komutları çalıştı ama SONRAKİ ölçüm" \
            "yapılamadı: ${O_NOT:-sorgu düştü}." \
            "İşe yarayıp yaramadığı bilinmiyor."
    fi
    rapor_yaz "$MOTOR"
    JS_SONRA="$(jsnum "$O_TOPLAM")"
    JS_TOPLAM="$O_TOPLAM"
    JS_TABLOLAR="$(json_parcasi "")"

    printf '\n'
    mlog "önce $(insan_bayt "$once_toplam") boşa gidiyordu," \
         "sonra $(insan_bayt "$O_TOPLAM") ($SANIYE sn)"

    # DÜRÜSTLÜK NOTU. Güvenli bakımda ölçülen şişkinlik düşer ama DOSYA
    # KÜÇÜLMEZ; kullanıcı bu satırı okumazsa diskte yer açıldığını sanır ve
    # dolmakta olan diski o gece yine dolmuş bulur.
    if [ "$AGRESIF" -ne 1 ]; then
        case "$MOTOR" in
            postgresql)
                warn "Dosya KÜÇÜLMEDİ: VACUUM yeri işletim sistemine" \
                     "geri vermez, tabloya YENİDEN KULLANILABİLİR alan" \
                     "olarak bırakır." ;;
            mariadb)
                warn "ANALYZE TABLE yalnız İSTATİSTİK tazeler; boşa" \
                     "giden alan olduğu yerde durur." ;;
        esac
        log "Yeri gerçekten geri almak için:" \
            "./scripts/maintenance.sh bakim $MOTOR --agresif"
    fi

    if [ "$dusen" -gt 0 ]; then
        bakim_dustu "$n tablodan $dusen tanesinde bakım DÜŞTÜ:" \
            "$dusen_ad. Ayrıntı: $LOG_FILE"
    fi

    OK=true
    DETAY="$eylem uygulandı: $n tablo, önce $once_toplam bayt,"
    DETAY="$DETAY sonra $O_TOPLAM bayt, $SANIYE sn"
    mok "Bakım tamamlandı."
    bitir 0
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
case "$KOMUT" in
    durum) durum_calistir ;;
    bakim) bakim_calistir ;;
    *)     kullanim; kapsam_disi "Bilinmeyen komut: $KOMUT" ;;
esac
