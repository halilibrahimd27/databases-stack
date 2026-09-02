#!/bin/bash
# =============================================================================
# databases-stack — EN PAHALI SORGULARI ÖLÇMEK
# =============================================================================
#   ./scripts/slowlog.sh kur <motor>        ölçümü aç (kalıcı ayar)
#   ./scripts/slowlog.sh durum [motor]      en pahalı ilk N sorgu
#   ./scripts/slowlog.sh oneri <motor>      indeks/ayar önerileri
#   ./scripts/slowlog.sh sifirla <motor>    sayaçları sıfırla
#
# NEDEN VAR:
# "Veritabanım yavaş" bu ürünün kullanıcısının en sık cümlesi; EXPLAIN
# okumak ise en son yapmak isteyeceği şey. Oysa cevap neredeyse her zaman
# ölçülebilir bir yerde duruyor: motor, hangi sorguya ne kadar zaman
# harcadığını ZATEN sayıyor. Eksik olan tek şey o sayacın açılması ve
# okunabilir hâle getirilmesi.
#
# SIRALAMA TOPLAM SÜREYE GÖRE — BU BETİĞİN EN ÖNEMLİ KARARI:
# İnsanlar yavaşlık ararken içgüdüsel olarak ORTALAMAYA bakar ve yanılır.
# 0.5 ms süren ama saniyede 2000 kez çağrılan bir sorgu sunucudan saniyede
# 1000 ms alır. 3 saniye süren ama günde bir koşan bir rapor günde 3000 ms
# alır. Birincisi üç saniyede ikincisinin GÜNLÜK maliyetini geçer.
# Ortalamaya göre sıralayan bir liste birinciyi hiç göstermez — ve sunucuyu
# gerçekten dolduran odur. Bu yüzden hem ekran hem JSON TOPLAM SÜREYE göre
# sıralı; ortalama sütunu yalnızca "tek koşum ne kadar sürüyor" sorusu için
# duruyor. (scripts/e2e/slowlog.sh bu kararı ölçüyor: az çağrılan ama
# ortalaması yüksek bir sorgu ile çok çağrılan ama ortalaması düşük bir
# sorgu koşturup listedeki sıralarına bakıyor.)
#
# ÖLÇÜM AÇIK DEĞİLSE BU BETİK BOŞ LİSTE BASMAZ (çıkış kodu 4). Sebebi
# somut: boş liste "yavaş sorgun yok" diye okunur. Ölçüm hiç yapılmamışken
# bunu söylemek, bu aracın verebileceği en pahalı yanlış cevaptır —
# kullanıcı asıl sorunu bambaşka bir yerde aramaya gider.
#
# MOTOR BAŞINA KAYNAK — ve neden aynı değiller:
#   postgresql  pg_stat_statements. Sorguları NORMALLEŞTİREREK sayar
#               (sabitler $1). shared_preload_libraries gerektirir, yani
#               açmak YENİDEN BAŞLATMA ister. 'kur' ayarı yazar ve bunu
#               AÇIKÇA söyler; SESSİZCE YENİDEN BAŞLATMAZ — üretim
#               veritabanını kapatma kararı kullanıcınındır.
#   mariadb     iki kaynak, bu öncelikle:
#               1) performance_schema.events_statements_summary_by_digest
#                  — normalleştirilmiş, EŞİKSİZ, sıfırlanabilir.
#               2) yavaş sorgu günlüğü (slow_query_log) — HAM SORGU yazar
#                  ve long_query_time EŞİĞİNİN ALTINDAKİLERİ HİÇ GÖRMEZ.
#               İkincisi tam da bu betiğin aradığı sorgu sınıfını (kısa ama
#               çok çağrılan) TANIMI GEREĞİ gizler: eşik 2 sn ise, 0.5 ms
#               süren ve sunucuyu dolduran sorgu o dosyaya hiç düşmez. Bu
#               yüzden digest varsa o tercih edilir ve fark ekranda yazılır.
#   diğerleri   KAPSAM DIŞI (çıkış 2). MongoDB'de profiler, MSSQL'de Query
#               Store, Elasticsearch'te kendi slow log'u — her biri ayrı bir
#               iş ve ayrı bir yorum ister. "Destekliyormuş gibi" yapmak,
#               kullanıcıyı yanlış yerde aratmaktan daha kötüdür.
#
# GİZLİLİK — SORGU METNİ VERİ TAŞIYABİLİR:
# pg_stat_statements ve performance_schema digest'i sabitleri kaldırır
# ($1 / ?), yani ekrana düşen metinde müşteri adı ya da kimlik numarası
# olmaz. MariaDB'nin yavaş sorgu GÜNLÜĞÜ ise sorguyu HAM yazar. O kaynaktan
# okunduğunda bu betik metni KENDİ maskeler (dizgi sabitleri ve sayılar '?'
# olur) ve ekranda bunu SÖYLER. Maskeleme sessiz yapılsaydı kullanıcı
# gördüğü metnin ham olmadığını bilemez, dolayısıyla diskteki günlük
# dosyasını da güvenli sanırdı — oysa orada ham hâli duruyor.
#
# ÖNERİ UYGULANMAZ, YALNIZ YAZILIR. İndeks eklemek okuma yolunu hızlandırıp
# YAZMA yolunu yavaşlatır ve diskte yer tutar; indeks silmek geri alması
# dakikalar süren bir iştir. Bu takası ancak uygulamayı bilen kişi yapabilir,
# ölçüm aracı değil. Bu yüzden 'oneri' yalnız SELECT/EXPLAIN çalıştırır ve
# komutları ekrana basar.
#
# ÇIKIŞ KODLARI (birbirine karışmasınlar diye ayrı — maintenance.sh'taki
# sözleşmenin aynısı):
#   0  iş bitti
#   1  İŞ DÜŞTÜ — ayar yazılamadı, sıfırlama başarısız oldu
#   2  KAPSAM DIŞI — bu motorda yavaş sorgu ölçümü yok, ya da kullanım
#      hatası (bilinmeyen komut/seçenek, eksik motor)
#   3  ÖLÇÜLEMEDİ — motor kapalı, docker yok, sorgu düştü. "Yavaş sorgu
#      yok" DEMEK DEĞİLDİR.
#   4  ÖLÇÜM KAPALI — sayaç hiç çalışmıyor. 0 ile de 3 ile de karıştırmak
#      yanlış olurdu: "hiç yavaş sorgu bulunmadı" değil, "hiç bakılmadı".
#
# SON SATIR HER ZAMAN TEK SATIR JSON'DUR (panel/controller bunu okur):
#   {"engine":…,"command":…,"source":…,"enabled":…,"pending_restart":…,
#    "masked":…,"rows_kind":…,"threshold_ms":…,
#    "queries":[{"query":…,"calls":N,"total_ms":N,"avg_ms":N,"rows":N,
#                "blocks":N,"db":…}],
#    "total_ms":N,"suggestions":[{"kind":…,"object":…,"reason":…,"sql":…}],
#    "seconds":N,"ok":…,"detail":…}
#
# ALAN ADLARI HER MOTORDA AYNI, DOLU OLMALARI DEĞİL (restore-drill.sh ve
# maintenance.sh'taki sözleşme): MariaDB'de "blocks" JSON null'dur, 0 değil
# — InnoDB sorgu başına okunan blok diye bir sayaç tutmuyor. 0 yazsaydık
# panel "hiç disk okumamış, sorun burada değil" derdi; oysa doğru cevap
# "bu motorda böyle bir ölçü yok".
#
# "rows" MOTORA GÖRE FARKLI ŞEY SAYAR, bu yüzden yanında rows_kind var:
# PostgreSQL'de DÖNEN satır (returned), MariaDB'de TARANAN satır (examined).
# Farkı yazmasaydık "10 satır döndüren sorgu neden yavaş" sorusunun cevabı
# kaybolurdu — MariaDB'deki o sayı 2 milyon satır tarandığını söylüyor
# olabilir ve asıl bulgu tam olarak budur.
#
# MOTOR VERİLMEDEN 'durum' çağrılırsa kapsamdaki AKTİF motorların hepsi
# okunur; engine "hepsi" olur ve sorgu satırları "<motor>:" ön ekiyle
# gelir (iki motorda aynı sorgu metni olabilir; ön ek olmasa satırlar
# birbirine karışırdı). Makine okuyan taraf motoru VEREREK çağırmalı.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3
source scripts/lib/common.sh
load_env

LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/slowlog_$(date +%Y%m%d).log"

slog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
         | tee -a "$LOG_FILE"; }
serr() { err "$*"; printf '[%s] [ERR] %s\n' "$(date '+%F %T')" "$*" \
         >> "$LOG_FILE"; }

# Hiçbir bekleme sonsuz değil: asılı kalmış bir ölçüm, panelin "yavaş
# sorgular" kartını süresiz "yükleniyor"da bırakır ve kullanıcı aracın
# bozulduğunu sanır.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman() {   # zaman <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
SURE_SORGU="${SLOWLOG_SORGU_SURESI:-120}"

# Alan ayırıcı: 0x1f (ASCII "unit separator"). Sekme DEĞİL — sorgu metninin
# İÇİNDE sekme olabilir; o gün satır kayar ve bir sorgunun çağrı sayısı
# başka bir sorgunun süresiyle eşleşirdi.
AYIRAC=$'\x1f'

# Ham çıktının toplandığı geçici dizin. Fonksiyonlardan ÖNCE tanımlı, çünkü
# çıkış tuzağı bunu çağırıyor (maintenance.sh'taki aynı gerekçe).
GECICI=""
temizle_gecici() {
    [ -n "$GECICI" ] && rm -rf "$GECICI" 2>/dev/null
    return 0
}
gecici_ac() {
    [ -n "$GECICI" ] && return 0
    GECICI="$(mktemp -d "${TMPDIR:-/tmp}/dbstack-slowlog-XXXXXX")" || return 1
    return 0
}

# =============================================================================
# KAPSAM
# =============================================================================
DESTEKLI="mariadb postgresql"

destekli_mi() {
    local e
    for e in $DESTEKLI; do [ "$e" = "$1" ] && return 0; done
    return 1
}

# tr -d '\r' ŞART: python3'ün print'i Windows'ta CRLF yazar ve bu depo
# Windows'ta düzenleniyor; \r taşıyan bir motor kimliği hiçbir
# karşılaştırmaya uymaz (maintenance.sh'taki aynı sınıf hata).
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
# python3'e bağlanmıyoruz (maintenance.sh / restore-drill.sh ile aynı karar).
js() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    s="${s//$'\t'/ }"
    s="${s//$AYIRAC/ }"
    printf '"%s"' "$s"
}

# SAYI ya da null. "Bilmiyorum"u 0 diye yazmak bu üründeki en pahalı sessiz
# hata sınıfı: 0 "hiç zaman harcanmamış" diye okunur, oysa ölçüm hiç
# yapılamamıştır.
jsnum() {
    case "${1:-}" in
        ''|*[!0-9.]*|*.*.*|.*|*.) printf 'null' ;;
        *) printf '%s' "$1" ;;
    esac
}
jsbool() {
    case "${1:-0}" in 1) printf 'true' ;; *) printf 'false' ;; esac
}

KOMUT="durum"
MOTOR=""
ADET=10
VT=""
ESIK=""

JS_MOTOR="hepsi"
JS_KAYNAK=null
JS_ACIK=0
JS_BEKLIYOR=0
JS_MASKE=0
JS_SATIR_TURU=null
JS_ESIK=null
JS_SORGULAR=""
JS_ONERILER=""
JS_TOPLAM=0
SANIYE=0
OK=false
DETAY="çalıştırılmadı"
JSON_BASILDI=0
BASLANGIC="$(date +%s)"

# Kaynak alanlarını (source/enabled/masked…) JSON değişkenlerine taşır.
# json_bas'tan ÖNCE tanımlı olmak zorunda: çıkış tuzağı json_bas'ı çağırıyor
# ve tuzak, betiğin herhangi bir noktasında tetiklenebilir. Sonraya
# bırakılsaydı erken bir hata "command not found" basar, JSON hiç çıkmazdı.
kaynak_json_yaz() {
    # Motora hiç gidilmeden çıkıldıysa (kullanım hatası, kapsam dışı)
    # kaynak diye bir şey yok: alanlar başlangıç değerlerinde kalsın.
    # "yok" yazsaydık, hiç sorulmamış bir soruya cevap vermiş olurduk.
    [ -n "${K_KAYNAK:-}" ] || return 0
    JS_KAYNAK="$(js "$K_KAYNAK")"
    JS_ACIK="$K_ACIK"
    JS_BEKLIYOR="$K_BEKLIYOR"
    JS_MASKE="$K_MASKE"
    JS_SATIR_TURU="$(js "${K_SATIR_TURU:-yok}")"
    JS_ESIK="$(jsnum "${K_ESIK_MS:-}")"
}

json_bas() {
    [ "$JSON_BASILDI" -eq 1 ] && return 0
    JSON_BASILDI=1
    SANIYE=$(( $(date +%s) - BASLANGIC ))
    # Kaynak alanlarını TAM BURADA topluyoruz. Her komutun sonunda ayrı ayrı
    # çağırmak zorunda kalsaydık biri unutulur ve o komutun JSON'u
    # "source":null, "enabled":false derdi — yani ölçüm açıkken panel onu
    # kapalı gösterirdi.
    kaynak_json_yaz
    local f
    f='{"engine":%s,"command":%s,"source":%s,"enabled":%s'
    f+=',"pending_restart":%s,"masked":%s,"rows_kind":%s'
    f+=',"threshold_ms":%s,"queries":[%s],"total_ms":%s'
    f+=',"suggestions":[%s],"seconds":%s,"ok":%s,"detail":%s}\n'
    printf "$f" \
        "$(js "$JS_MOTOR")" "$(js "$KOMUT")" "$JS_KAYNAK" \
        "$(jsbool "$JS_ACIK")" "$(jsbool "$JS_BEKLIYOR")" \
        "$(jsbool "$JS_MASKE")" "$JS_SATIR_TURU" "$JS_ESIK" \
        "$JS_SORGULAR" "$(jsnum "$JS_TOPLAM")" "$JS_ONERILER" \
        "$SANIYE" "$OK" "$(js "$DETAY")"
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

olcum_yok()   { serr "$*"; DETAY="ölçülemedi: $*";  bitir 3; }
kapsam_disi() { warn "$*"; DETAY="kapsam dışı: $*"; bitir 2; }
is_dustu()    { serr "$*"; OK=false; DETAY="$*";    bitir 1; }

# =============================================================================
# BİÇİMLEME
# =============================================================================
# LC_ALL=C ŞART: bazı yerel ayarlarda awk ondalık ayırıcı olarak VİRGÜL
# basar ("12,4 sn"); aynı awk'ın ürettiği bir sayı JSON'a girseydi çıktı hiç
# ayrıştırılamazdı (maintenance.sh'taki aynı tuzak).
insan_sure() {   # insan_sure <milisaniye>
    local ms="${1:-}"
    case "$ms" in ''|*[!0-9.]*) printf '?'; return 0 ;; esac
    LC_ALL=C awk -v m="$ms" 'BEGIN{
        if (m >= 3600000)    printf "%.1f sa", m/3600000;
        else if (m >= 60000) printf "%.1f dk", m/60000;
        else if (m >= 1000)  printf "%.1f sn", m/1000;
        else if (m >= 1)     printf "%.0f ms", m;
        else                 printf "%.2f ms", m;
    }'
}

insan_sayi() {   # insan_sayi <tam sayı>
    local n="${1:-}"
    case "$n" in ''|*[!0-9]*) printf '—'; return 0 ;; esac
    LC_ALL=C awk -v n="$n" 'BEGIN{
        if (n >= 1000000000)  printf "%.1f G", n/1000000000;
        else if (n >= 1000000) printf "%.1f M", n/1000000;
        else if (n >= 10000)   printf "%.0f K", n/1000;
        else                   printf "%d", n;
    }'
}

# Sorgu metninde AYIRT EDİCİ olan BAŞTIR ("SELECT … FROM tablo"), tablo
# adlarının tersine. Bu yüzden burada son değil BAŞ korunuyor; tam metin
# zaten JSON'da duruyor.
kisalt_bas() {   # kisalt_bas <metin> <uzunluk>
    local s="$1" n="$2"
    if [ "${#s}" -le "$n" ]; then printf '%s' "$s"
    else printf '%s…' "${s:0:$((n - 1))}"; fi
}
kisalt_son() {   # kisalt_son <metin> <uzunluk>
    local s="$1" n="$2"
    if [ "${#s}" -le "$n" ]; then printf '%s' "$s"
    else printf '…%s' "${s: -$((n - 1))}"; fi
}

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Host'ta veritabanı istemcisi yok; her sorgu container'ın içinden çalışır.
# Parola komut satırına DEĞİL ortama konur (host'ta `ps` çıktısı sistemdeki
# herkese açıktır) — backup.sh ve maintenance.sh'taki desenin aynısı. Alt
# kabuk şart: export'lar betiğin geri kalanına sızmasın.
my_sorgu() {   # my_sorgu <container> <sql>
    ( export MYSQL_PWD="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
      zaman "$SURE_SORGU" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$2" ) 2>>"$LOG_FILE"
}

# ON_ERROR_STOP=1: onsuz psql'in çıkış kodu sürüme ve çağrı biçimine göre
# değişir, yani DÜŞEN bir sorgu "başarılı" sanılabilir (backup.sh'ta sqlcmd
# için -b bayrağının çözdüğü sorunun aynısı).
# BU BETİĞİN GÖNDERDİĞİ HER SORGU İMZALANIYOR ve listeden süzülüyor.
# Sebep ÖLÇÜLDÜ: araç her koşumda pg_stat_user_tables ve
# pg_stat_user_indexes okuyor, pg_stat_statements de bunları sayıyor.
# İlk koşumlardan sonra "en pahalı sorgular" listesinin üçüncü sırasında
# ARACIN KENDİ SORGUSU çıktı — kullanıcı kendi uygulamasında hiç bulunmayan
# bir sorguyu aramaya başlardı.
# Ad üzerinden süzmek ("%pg_stat%") YETMEZ: kullanıcının kendi izleme
# sorgusu da o desene uyar ve HAKLI OLARAK listede olmalıdır. İmza, bizim
# gönderdiğimizi ayırt eden tek kesin ölçüt.
PG_IMZA="/* dbstack-slowlog */"

pg_sorgu() {   # pg_sorgu <container> <veritabanı> <sql>
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      zaman "$SURE_SORGU" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$2" \
               -v ON_ERROR_STOP=1 -tAq -F "$AYIRAC" \
               -c "$PG_IMZA $3" ) 2>>"$LOG_FILE"
}

# EXPLAIN çıktısı SÜTUNLU DEĞİL, satır satır metindir; ayırıcı vermiyoruz.
pg_metin() {   # pg_metin <container> <veritabanı> <sql>
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      zaman "$SURE_SORGU" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$2" \
               -v ON_ERROR_STOP=1 -tAq -c "$PG_IMZA $3" ) 2>>"$LOG_FILE"
}

# SQL'e gömülecek metinler için tek tırnak katlama. Bu değerler kullanıcının
# komut satırından geliyor (--vt); tek tırnak içeren bir ad, tırnaklanmasa
# sorguyu tam ortasından bölerdi.
sql_metin() { local s="${1//\'/\'\'}"; printf '%s' "$s"; }
pg_kimlik() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
my_kimlik() { local s="${1//\`/\`\`}"; printf '`%s`' "$s"; }

# =============================================================================
# ÖLÇÜM SONUCU
# =============================================================================
# Alan sırası HER MOTORDA AYNI; motor farkları SQL'in / ayrıştırıcının
# içinde kalıyor. Böylece rapor ve JSON kodu motor bilmiyor — yeni bir motor
# eklendiğinde değişmesi gereken tek yer o motorun okuma fonksiyonudur.
#   Q_CAGRI  çağrı sayısı        Q_TOPLAM toplam ms       Q_ORT ortalama ms
#   Q_SATIR  satır ('' = yok)    Q_BLOK   blok ('' = yok) Q_VT  veritabanı
#   Q_EK     motora özel ek alan (MariaDB: dönen satır)
#   Q_METIN  sorgu metni
Q_CAGRI=(); Q_TOPLAM=(); Q_ORT=(); Q_SATIR=(); Q_BLOK=()
Q_VT=();    Q_EK=();     Q_METIN=()
Q_TOPLAM_MS=0

# Kaynağın kendisi hakkında ölçülenler.
K_KAYNAK=""      # pg_stat_statements | performance_schema | slow_log
K_ACIK=0
K_BEKLIYOR=0
K_MASKE=0
K_SATIR_TURU=""  # returned | examined
K_ESIK_MS=""     # slow_log eşiği (ms); diğer kaynaklarda boş
K_NOT=""         # ekranda uyarı olarak basılır
K_NASIL=""       # ölçüm kapalıysa "şöyle açılır" metni
K_PENCERE=""     # gözlem penceresi: sayaçlar ne zamandan beri topluyor

olcum_sifirla() {
    Q_CAGRI=(); Q_TOPLAM=(); Q_ORT=(); Q_SATIR=(); Q_BLOK=()
    Q_VT=();    Q_EK=();     Q_METIN=()
    Q_TOPLAM_MS=0
    K_KAYNAK=""; K_ACIK=0; K_BEKLIYOR=0; K_MASKE=0
    K_SATIR_TURU=""; K_ESIK_MS=""; K_NOT=""; K_NASIL=""; K_PENCERE=""
}

# Ham satırları dizilere okur. Alanlar AYIRAC ile ayrılmış; sorgu metni EN
# SONDA, çünkü içinde her şey olabilir ve `read` son değişkene satırın
# kalanını verir.
satirlari_al() {   # satirlari_al <ham dosya>
    [ -f "$1" ] || return 0
    local c t o s b v e m
    while IFS="$AYIRAC" read -r c t o s b v e m; do
        [ -z "$m" ] && continue
        Q_CAGRI+=("$c"); Q_TOPLAM+=("$t"); Q_ORT+=("$o")
        Q_SATIR+=("$s"); Q_BLOK+=("$b");   Q_VT+=("$v")
        Q_EK+=("$e");    Q_METIN+=("$m")
        Q_TOPLAM_MS="$(LC_ALL=C awk -v a="$Q_TOPLAM_MS" -v b="$t" \
            'BEGIN{printf "%.1f", a + (b + 0)}')"
    done < "$1"
    return 0
}

# ÖNERİLER. Aynı dizin sırası: tür, nesne, gerekçe, komut.
O_TUR=(); O_NESNE=(); O_NEDEN=(); O_SQL=()
oneri_ekle() {   # oneri_ekle <tür> <nesne> <neden> <sql>
    O_TUR+=("$1"); O_NESNE+=("$2"); O_NEDEN+=("$3"); O_SQL+=("$4")
}

# =============================================================================
# POSTGRESQL
# =============================================================================
# pg_stat_statements sorguları normalleştirerek sayar; sabitler $1, $2 olur.
# Ölçümün açık olması İKİ ŞARTA bağlı ve ikisi ayrı ayrı bildiriliyor,
# çünkü çözümleri farklı:
#   1) kütüphane ÖN YÜKLÜ mü (shared_preload_libraries) → yeniden başlatma
#   2) eklenti bir veritabanında YARATILMIŞ mı (CREATE EXTENSION) → anında
# İkisini tek "kapalı" mesajında birleştirseydik, yalnız CREATE EXTENSION
# eksik olan kullanıcıya gereksiz yere sunucuyu yeniden başlatmasını
# söylemiş olurduk.
PG_SURUM=0        # server_version_num
PG_ONYUK=0        # kütüphane ön yüklü mü
PG_EXT_DB=""      # eklentinin yaratılmış olduğu ilk veritabanı

pg_kesfet() {   # pg_kesfet <container>
    local C="$1" spl db dblist
    PG_SURUM=0; PG_ONYUK=0; PG_EXT_DB=""

    PG_SURUM="$(pg_sorgu "$C" postgres "SHOW server_version_num;" \
                | tr -d '\r[:blank:]')"
    case "$PG_SURUM" in ''|*[!0-9]*) PG_SURUM=0 ;; esac

    spl="$(pg_sorgu "$C" postgres "SHOW shared_preload_libraries;")" \
        || return 1
    case "$spl" in *pg_stat_statements*) PG_ONYUK=1 ;; esac

    # Sayaçlar KÜME GENELİNDE tek bir paylaşılan bellekte tutulur; eklenti
    # yalnız o belleği OKUYAN görünümü açar. Bu yüzden tek bir veritabanında
    # yaratılmış olması yeter ve hangisi olduğu önemli değil — ilk buldu-
    # ğumuzdan okuyoruz.
    dblist="$(pg_sorgu "$C" postgres \
        "SELECT datname FROM pg_database
          WHERE datallowconn AND NOT datistemplate ORDER BY 1;")" || return 1
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        if [ "$(pg_sorgu "$C" "$db" \
              "SELECT 1 FROM pg_extension
                WHERE extname = 'pg_stat_statements';" \
              | tr -d '\r[:blank:]')" = "1" ]; then
            PG_EXT_DB="$db"; break
        fi
    done <<< "$dblist"
    return 0
}

# PG13'te total_time → total_exec_time oldu. Sürümü ölçüp sütun adını
# seçiyoruz; sabit yazsaydık eski sürümde sorgu düşer ve araç "ölçüm yok"
# derdi — oysa ölçüm vardı, biz okuyamıyorduk.
pg_kolon_toplam() {
    if [ "$PG_SURUM" -ge 130000 ]; then printf 'total_exec_time'
    else printf 'total_time'; fi
}
pg_kolon_ort() {
    if [ "$PG_SURUM" -ge 130000 ]; then printf 'mean_exec_time'
    else printf 'mean_time'; fi
}

pg_kapali_mesaji() {
    if [ "$PG_ONYUK" -ne 1 ]; then
        K_NASIL="./scripts/slowlog.sh kur postgresql"
        K_NOT="pg_stat_statements ÖN YÜKLÜ DEĞİL — PostgreSQL hiçbir"
        K_NOT="$K_NOT sorgunun süresini saymıyor."
    else
        K_NASIL="./scripts/slowlog.sh kur postgresql"
        K_NOT="Kütüphane yüklü ama eklenti hiçbir veritabanında"
        K_NOT="$K_NOT yaratılmamış — sayaçlar dolu, okunacak görünüm yok."
    fi
}

pg_oku() {   # pg_oku <container>
    local C="$1" ham sql kosul="" tp mn bilgi
    gecici_ac || { K_NOT="geçici dizin açılamadı"; return 1; }
    ham="$GECICI/pg.ham"; : > "$ham"

    K_KAYNAK="pg_stat_statements"
    K_SATIR_TURU="returned"
    K_MASKE=0

    pg_kesfet "$C" || { K_NOT="sunucu durumu okunamadı"; return 1; }
    if [ "$PG_ONYUK" -ne 1 ] || [ -z "$PG_EXT_DB" ]; then
        K_ACIK=0; pg_kapali_mesaji; return 0
    fi
    K_ACIK=1

    tp="$(pg_kolon_toplam)"; mn="$(pg_kolon_ort)"
    [ -n "$VT" ] && kosul="AND d.datname = '$(sql_metin "$VT")'"

    # ARACIN KENDİ SORGULARI LİSTEDEN ÇIKARILIYOR. Bu betik her koşumda
    # pg_stat_statements'a bakıyor; süzmeseydik birkaç koşum sonra "en
    # pahalı sorgu" olarak kendi ölçüm sorgumuz çıkardı ve kullanıcı
    # kendi uygulamasında olmayan bir sorguyu aramaya başlardı.
    #
    # translate + regexp_replace: sorgu metni ÇOK SATIRLI olabilir ve içinde
    # sekme/0x1f bulunabilir. Tek satıra indirmezsek ayırıcı düzeni bozulur
    # ve bir sorgunun metni bir sonraki satırın çağrı sayısı sanılırdı.
    sql="SELECT s.calls,
                round(s.$tp::numeric, 1),
                round(s.$mn::numeric, 3),
                s.rows,
                s.shared_blks_hit + s.shared_blks_read,
                COALESCE(d.datname, ''),
                '',
                regexp_replace(
                    translate(s.query,
                              chr(10) || chr(13) || chr(9) || chr(31),
                              '    '),
                    '\\s+', ' ', 'g')
           FROM pg_stat_statements s
           LEFT JOIN pg_database d ON d.oid = s.dbid
          WHERE s.query NOT LIKE '%dbstack-slowlog%'
            $kosul
          ORDER BY s.$tp DESC
          LIMIT $ADET;"

    pg_sorgu "$C" "$PG_EXT_DB" "$sql" > "$ham" \
        || { K_NOT="pg_stat_statements okunamadı"; return 1; }
    satirlari_al "$ham"

    # GÖZLEM PENCERESİ. "En pahalı sorgu" cümlesi ancak bir zaman aralığıyla
    # anlamlı: sayaçlar bir saat önce sıfırlandıysa gecelik toplu iş listede
    # hiç yoktur ve kullanıcı onu "sorun değil" sanır.
    if [ "$PG_SURUM" -ge 140000 ]; then
        bilgi="$(pg_sorgu "$C" "$PG_EXT_DB" \
            "SELECT COALESCE(to_char(stats_reset,'YYYY-MM-DD HH24:MI'),'?'),
                    dealloc
               FROM pg_stat_statements_info;")"
        if [ -n "$bilgi" ]; then
            K_PENCERE="${bilgi%%$AYIRAC*} tarihinden beri"
            # dealloc > 0 = liste taştı ve en az kullanılan kayıtlar ATILDI.
            # Söylenmezse kullanıcı eksik bir listeye tam liste diye bakar.
            case "${bilgi##*$AYIRAC}" in
                0|'') ;;
                *) K_NOT="pg_stat_statements.max doldu ve ${bilgi##*$AYIRAC}"
                   K_NOT="$K_NOT kez kayıt ATILDI — liste eksik olabilir." ;;
            esac
        fi
    fi
    return 0
}

# --- kur ---------------------------------------------------------------------
# İKİ AYRI İŞ, ayrı ayrı raporlanıyor:
#   a) ayar dosyasını postgresql.conf'a dahil et  → YENİDEN BAŞLATMA ister
#   b) CREATE EXTENSION                            → anında etkili
# (a) yapıldıysa ve ön yükleme hâlâ yoksa çıktı "beklemede"dir: ayar yazıldı,
# ÖLÇÜM HENÜZ BAŞLAMADI. Bunu "açıldı" diye raporlamak, kullanıcının ertesi
# gün boş listeye bakıp aracın bozuk olduğunu düşünmesi demekti.
PG_INCLUDE="include_if_exists = '/etc/postgresql/slowlog.conf'"

pg_kur() {   # pg_kur <container>
    local C="$1" hedef

    pg_kesfet "$C" || olcum_yok "PostgreSQL durumu okunamadı."

    if [ "$PG_ONYUK" -eq 1 ]; then
        ok "pg_stat_statements ZATEN ön yüklü — yeniden başlatma gerekmiyor."
    else
        # Ayar dosyası container'da yoksa compose bağlaması henüz
        # uygulanmamıştır. Bunu ŞİMDİ söylüyoruz: aşağıdaki include satırı
        # yazılır, dosya bulunmadığı için sessizce atlanır ve kullanıcı
        # "kurdum ama çalışmıyor" derdi.
        if ! docker exec "$C" test -r /etc/postgresql/slowlog.conf \
             2>>"$LOG_FILE"; then
            warn "config/postgresql/slowlog.conf container'a BAĞLI DEĞİL."
            warn "  docker-compose.yml'deki bağlama henüz uygulanmamış."
            warn "  Aşağıdaki komut hem bağlamayı hem ayarı etkinleştirir."
        fi

        # postgresql.conf'un SONUNA yazıyoruz: PostgreSQL dosyayı baştan
        # sona okur ve AYNI ayarın son değeri kazanır. Başa yazsaydık,
        # aşağıda duran bir shared_preload_libraries satırı bizimkini
        # ezerdi.
        #
        # Betik container'a STDIN'den veriliyor. Tek satırlık `sh -c` ile
        # yazsaydık tırnak içinde tırnak zinciri kaçınılmazdı ve o zincirin
        # bir gün yanlış yere yazması, veritabanının açılmamasıyla
        # sonuçlanırdı.
        if ! docker exec -i "$C" sh -s >>"$LOG_FILE" 2>&1 <<'ICSEL'
set -e
f="${PGDATA:-/var/lib/postgresql/data/pgdata}/postgresql.conf"
[ -f "$f" ] || { echo "postgresql.conf bulunamadi: $f" >&2; exit 1; }
if grep -q "^include_if_exists = '/etc/postgresql/slowlog.conf'" "$f"; then
    exit 0
fi
printf '\n# databases-stack: yavas sorgu olcumu (scripts/slowlog.sh)\n' >> "$f"
printf "include_if_exists = '/etc/postgresql/slowlog.conf'\n" >> "$f"
ICSEL
        then
            is_dustu "postgresql.conf'a ayar YAZILAMADI (ayrıntı:" \
                "$LOG_FILE). Ölçüm açılmadı."
        fi
        # YAZDIK DİYE YAZILMIŞ SAYMIYORUZ: `>>` dolu ya da salt okunur bir
        # dosya sisteminde sessizce başarısız olabiliyor. Ayarın gerçekten
        # dosyada olduğunu OKUYARAK doğruluyoruz — yoksa kullanıcı
        # sunucusunu boşuna yeniden başlatır ve ölçüm yine açılmazdı.
        hedef="$(docker exec -i "$C" sh -s <<'DOGRULA' 2>>"$LOG_FILE"
d="${PGDATA:-/var/lib/postgresql/data/pgdata}"
grep -c slowlog.conf "$d/postgresql.conf"
DOGRULA
)"
        hedef="$(printf '%s' "$hedef" | tr -d '\r[:blank:]')"
        case "$hedef" in
            ''|0) is_dustu "Ayar satırı yazıldı sanıldı ama" \
                      "postgresql.conf'ta bulunamadı." ;;
        esac
        K_BEKLIYOR=1
        ok "Ayar yazıldı: postgresql.conf → $PG_INCLUDE"
    fi

    # CREATE EXTENSION ön yükleme olmadan da başarılı olabilir (görünüm
    # yaratılır, okunduğunda hata verir). Yine de deniyoruz: ön yükleme
    # yapıldıktan sonra kullanıcının ikinci bir komut çalıştırması
    # gerekmesin.
    if [ -z "$PG_EXT_DB" ]; then
        local db="${DEFAULT_DATABASE:-defaultdb}"
        if pg_sorgu "$C" "$db" \
             "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" \
             >>"$LOG_FILE" 2>&1; then
            PG_EXT_DB="$db"
            ok "Eklenti yaratıldı: $db.pg_stat_statements"
        elif pg_sorgu "$C" postgres \
             "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" \
             >>"$LOG_FILE" 2>&1; then
            PG_EXT_DB="postgres"
            ok "Eklenti yaratıldı: postgres.pg_stat_statements"
        elif [ "$PG_ONYUK" -eq 1 ]; then
            # Kütüphane YÜKLÜ ve eklenti yine de yaratılamıyorsa açacak
            # başka bir şey yok: bu gerçek bir arıza, iş DÜŞTÜ.
            is_dustu "CREATE EXTENSION pg_stat_statements düştü" \
                "(ayrıntı: $LOG_FILE)."
        else
            # Kütüphane henüz ön yüklü değilken bazı sürümler CREATE
            # EXTENSION'ı reddediyor. Bu bir arıza DEĞİL, sıra sorunu:
            # yeniden başlatmadan sonra çalışacak. is_dustu deseydik,
            # doğru yazılmış bir ayarın ardından "kurulum başarısız"
            # raporlanır ve kullanıcı geri alma yollarını arardı.
            warn "Eklenti şimdi yaratılamadı — kütüphane henüz ön yüklü"
            warn "değil. Yeniden başlatmadan sonra 'kur' komutunu bir kez"
            warn "daha çalıştırın; o zaman yaratılacak."
        fi
    else
        ok "Eklenti zaten var: $PG_EXT_DB.pg_stat_statements"
    fi

    K_KAYNAK="pg_stat_statements"
    K_SATIR_TURU="returned"

    if [ "$PG_ONYUK" -eq 1 ]; then
        K_ACIK=1
        OK=true
        DETAY="ölçüm açık: pg_stat_statements yüklü ve eklenti $PG_EXT_DB"
        DETAY="$DETAY veritabanında"
        printf '\n'
        ok "ÖLÇÜM AÇIK. Şimdi: ./scripts/slowlog.sh durum postgresql"
        bitir 0
    fi

    # --- Yeniden başlatma: SÖYLENİR, YAPILMAZ -------------------------------
    K_ACIK=0
    OK=true
    DETAY="ayar yazıldı; shared_preload_libraries için YENİDEN BAŞLATMA"
    DETAY="$DETAY gerekiyor, ölçüm HENÜZ BAŞLAMADI"
    printf '\n'
    warn "ÖLÇÜM HENÜZ BAŞLAMADI."
    log  "shared_preload_libraries bir POSTMASTER parametresidir: sunucu"
    log  "AÇILIRKEN okunur. reload (SIGHUP) yetmez, SELECT ile"
    log  "değiştirilemez — tek yolu yeniden başlatmaktır."
    printf '\n'
    log  "Bu betik sunucunuzu KENDİLİĞİNDEN yeniden başlatmaz: o an ne"
    log  "koştuğunu bilmiyor. Kesintiyi siz seçin:"
    printf '\n'
    printf '    docker compose up -d postgresql\n'
    printf '\n'
    log  "Sonra: ./scripts/slowlog.sh durum postgresql"
    log  "Ölçüm başlamamışsa 'durum' bunu söyler (çıkış kodu 4)."
    bitir 0
}

# --- sifirla -----------------------------------------------------------------
pg_sifirla() {   # pg_sifirla <container>
    local C="$1" once sonra hedef

    pg_kesfet "$C" || olcum_yok "PostgreSQL durumu okunamadı."
    K_KAYNAK="pg_stat_statements"
    K_SATIR_TURU="returned"
    if [ "$PG_ONYUK" -ne 1 ] || [ -z "$PG_EXT_DB" ]; then
        K_ACIK=0; pg_kapali_mesaji
        warn "$K_NOT"
        DETAY="ölçüm kapalı: sıfırlanacak sayaç yok"
        log "Açmak için: $K_NASIL"
        bitir 4
    fi
    K_ACIK=1

    once="$(pg_sorgu "$C" "$PG_EXT_DB" \
        "SELECT count(*) FROM pg_stat_statements;" | tr -d '\r[:blank:]')"

    # KAPSAM: --vt verildiyse YALNIZ o veritabanının kayıtları silinir.
    # pg_stat_statements_reset(userid, dbid, queryid) tam bunun için var.
    # Süzgeçsiz sıfırlama KÜME GENELİNDEDİR ve geri alınamaz: haftalardır
    # biriken ölçüm bir komutla gider. Bu yüzden hangisinin yapıldığı
    # ekranda açıkça yazıyor.
    if [ -n "$VT" ]; then
        hedef="yalnız '$VT' veritabanı"
        pg_sorgu "$C" "$PG_EXT_DB" \
            "SELECT pg_stat_statements_reset(0,
                 (SELECT oid FROM pg_database
                   WHERE datname = '$(sql_metin "$VT")'), 0);" \
            >>"$LOG_FILE" 2>&1 \
            || is_dustu "Sıfırlama düştü (ayrıntı: $LOG_FILE)."
    else
        hedef="KÜME GENELİ (bütün veritabanları)"
        pg_sorgu "$C" "$PG_EXT_DB" "SELECT pg_stat_statements_reset();" \
            >>"$LOG_FILE" 2>&1 \
            || is_dustu "Sıfırlama düştü (ayrıntı: $LOG_FILE)."
    fi

    sonra="$(pg_sorgu "$C" "$PG_EXT_DB" \
        "SELECT count(*) FROM pg_stat_statements;" | tr -d '\r[:blank:]')"

    # ÇIKIŞ KODU YETMEZ: fonksiyon hatasız dönse de sayaç durabilir (yetki,
    # sürüm farkı). Sıfırlamanın tek kanıtı önce/sonra sayımıdır.
    slog "sayaçlar sıfırlandı ($hedef): $once kayıt → $sonra kayıt"
    OK=true
    DETAY="sıfırlandı ($hedef): $once → $sonra kayıt"
    ok "Sayaçlar sıfırlandı — $hedef."
    log "Kayıt sayısı: $once → $sonra"
    log "Ölçüm şimdi SIFIRDAN başlıyor; ilk 'durum' için biraz trafik lazım."
    bitir 0
}

# --- oneri -------------------------------------------------------------------
# ÜÇ ÖLÇÜM, üçü de motorun kendi sayaçlarından:
#   1) EXPLAIN (GENERIC_PLAN) — en pahalı sorguların planına BAKARAK hangi
#      tabloda hangi sütun için indeks düşünüleceğini söyler. Tahmin değil:
#      planlayıcının kendi çıktısında "Seq Scan … Filter: (sütun = $1)"
#      yazıyorsa o sütun okunuyor demektir.
#   2) Ardışık tarama baskın büyük tablolar (pg_stat_user_tables)
#   3) Hiç kullanılmayan indeksler (pg_stat_user_indexes.idx_scan = 0)
#
# EXPLAIN SORGUYU ÇALIŞTIRMAZ — ANALYZE verilmiyor, yalnız plan üretiliyor.
# GENERIC_PLAN ise PG16 ile geldi ve tam olarak bu iş için var:
# pg_stat_statements metnindeki $1 parametrelerini gerçek değer olmadan
# planlatır. Daha eski sürümde bu adım ATLANIR ve atlandığı SÖYLENİR;
# uydurma bir sütun adı basmaktansa "doğrulayamadım" demek yeğdir.
#
# Yalnız SELECT'ler EXPLAIN'e giriyor. Sebebi güvenlik değil dürüstlük:
# planlayıcı sabit katlama sırasında IMMUTABLE işlevleri çağırabilir; bunu
# üretim UPDATE/DELETE metinleriyle yapma riskini almıyoruz.
SLOWLOG_MIN_SATIR="${SLOWLOG_MIN_SATIR:-10000}"
SLOWLOG_MIN_INDEKS="${SLOWLOG_MIN_INDEKS:-1048576}"

pg_explain_oneri() {   # pg_explain_oneri <container> <veritabanı>
    local C="$1" db="$2" tp sql metin plan tbl col n satirlar
    local -a ciftler=()

    if [ "$PG_SURUM" -lt 160000 ]; then
        K_NOT="${K_NOT:+$K_NOT }EXPLAIN doğrulaması atlandı:"
        K_NOT="$K_NOT GENERIC_PLAN PostgreSQL 16 ile geldi (bu sunucu"
        K_NOT="$K_NOT $PG_SURUM)."
        return 0
    fi

    # İKİ AYRI BAĞLANTI, ve bu zorunlu:
    #   · SORGU LİSTESİ $PG_EXT_DB'den okunuyor — sayaçlar küme genelinde
    #     ortak bir bellekte, ama onları GÖSTEREN görünüm yalnız eklentinin
    #     yaratıldığı veritabanında var.
    #   · EXPLAIN ise $db'de koşuyor — sorgunun TABLOLARI orada.
    # İkisi tek bağlantıda yapılmaya çalışıldığında (ilk yazımda öyleydi)
    # sonuç sessiz bir boşluktu: 'oneri' hiç indeks önermiyordu, çünkü
    # $db'de "pg_stat_statements diye bir tablo yok" hatası alınıp
    # yutuluyordu. Ölçülen davranış: e2e paketi bunu yakalar.
    tp="$(pg_kolon_toplam)"
    sql="SELECT regexp_replace(
                    translate(s.query,
                              chr(10) || chr(13) || chr(9) || chr(31),
                              '    '),
                    '\\s+', ' ', 'g')
           FROM pg_stat_statements s
           JOIN pg_database d ON d.oid = s.dbid
          WHERE d.datname = '$(sql_metin "$db")'
            AND s.query ~* '^[[:space:]]*select'
            AND s.query NOT LIKE '%dbstack-slowlog%'
          ORDER BY s.$tp DESC
          LIMIT 5;"

    while IFS= read -r metin; do
        [ -z "$metin" ] && continue
        plan="$(pg_metin "$C" "$db" \
                "EXPLAIN (GENERIC_PLAN, COSTS OFF) $metin")" || continue
        # Plan metninden (tablo, sütun) çiftleri: "Seq Scan on X" satırından
        # sonra gelen ilk "Filter:" satırındaki EŞİTLİK süzgeçleri.
        # YALNIZ EŞİTLİK: '<', 'LIKE %…%' ya da işlev çağrısı içeren bir
        # süzgeç için sıradan bir B-tree indeksi çoğu zaman İŞE YARAMAZ;
        # onları da önerseydik "indeks ekledim, hiçbir şey değişmedi"
        # sonucunu üretirdik.
        tbl=""
        while IFS= read -r satirlar; do
            case "$satirlar" in
                *"Seq Scan on "*)
                    tbl="$(printf '%s' "$satirlar" \
                        | sed -n 's/.*Seq Scan on \([A-Za-z0-9_.]*\).*/\1/p')"
                    tbl="${tbl##*.}"
                    ;;
                *"Filter: "*)
                    [ -z "$tbl" ] && continue
                    while IFS= read -r col; do
                        [ -z "$col" ] && continue
                        ciftler+=("$tbl.$col")
                    done < <(printf '%s' "$satirlar" \
                        | grep -oE '[A-Za-z_][A-Za-z0-9_]* = ' \
                        | sed 's/ = $//')
                    tbl=""
                    ;;
            esac
        done <<< "$plan"
    done < <(pg_sorgu "$C" "$PG_EXT_DB" "$sql")

    [ "${#ciftler[@]}" -eq 0 ] && return 0

    # DOĞRULAMA. Plan metninden çıkarılan ad gerçekten o tablonun bir sütunu
    # mu, ve tablo indeks düşünülecek kadar büyük mü? İkisi de sorulmasaydı
    # araç 40 satırlık bir tablo için indeks önerir ve "uydurma"nın tam
    # tanımını yapardı — küçük tabloda ardışık tarama zaten DOĞRU plandır.
    local gorulen="" cift t c bilgi komut
    for cift in "${ciftler[@]}"; do
        case " $gorulen " in *" $cift "*) continue ;; esac
        gorulen="$gorulen $cift"
        t="${cift%%.*}"; c="${cift#*.}"
        bilgi="$(pg_sorgu "$C" "$db" \
            "SELECT COALESCE(st.n_live_tup, 0)
               FROM pg_class k
               JOIN pg_attribute a ON a.attrelid = k.oid
               LEFT JOIN pg_stat_user_tables st ON st.relid = k.oid
              WHERE k.relname = '$(sql_metin "$t")'
                AND a.attname = '$(sql_metin "$c")'
                AND a.attnum > 0 AND NOT a.attisdropped
              LIMIT 1;" | tr -d '\r[:blank:]')"
        case "$bilgi" in ''|*[!0-9]*) continue ;; esac
        [ "$bilgi" -lt "$SLOWLOG_MIN_SATIR" ] && continue
        n="$(insan_sayi "$bilgi")"
        # CONCURRENTLY: indeks kurulurken tablo YAZMAYA AÇIK kalır. Düz
        # CREATE INDEX tabloyu indeks bitene kadar yazmaya kapatır ve büyük
        # bir tabloda bu dakikalarca sürer — önerdiğimiz komutun kendisi
        # kesinti üretmemeli.
        komut="CREATE INDEX CONCURRENTLY ON $(pg_kimlik "$t")"
        komut="$komut ($(pg_kimlik "$c"));"
        oneri_ekle "indeks" "$db.$t.$c" \
            "EXPLAIN: en pahalı sorgulardan biri $t tablosunu ARDIŞIK
             TARIYOR ve $c sütununda eşitlik süzgeci var ($n satır)" \
            "$komut"
    done
    return 0
}

pg_oneri() {   # pg_oneri <container>
    local C="$1" dblist db satir ad sq str idx n_tup boyut

    pg_kesfet "$C" || olcum_yok "PostgreSQL durumu okunamadı."
    K_KAYNAK="pg_stat_statements"
    K_SATIR_TURU="returned"
    if [ "$PG_ONYUK" -ne 1 ] || [ -z "$PG_EXT_DB" ]; then
        K_ACIK=0; pg_kapali_mesaji
    else
        K_ACIK=1
    fi

    if [ -n "$VT" ]; then
        dblist="$VT"
    else
        dblist="$(pg_sorgu "$C" postgres \
            "SELECT datname FROM pg_database
              WHERE datallowconn AND NOT datistemplate ORDER BY 1;")" \
            || olcum_yok "Veritabanı listesi alınamadı."
    fi

    while IFS= read -r db; do
        [ -z "$db" ] && continue

        # GÖZLEM PENCERESİ: idx_scan = 0 "hiç kullanılmadı" demek DEĞİL,
        # "sayaç sıfırlandığından beri kullanılmadı" demektir. Sayaç dün
        # sıfırlandıysa haftalık rapora hizmet eden bir indeks de sıfır
        # görünür ve silinmesi önerilirdi.
        #
        # stats_reset NULL ise sayaç HİÇ sıfırlanmamış demektir; o zaman
        # pencere sunucunun açılışından başlar. 'bilinmiyor' yazsaydık,
        # elimizde ölçülmüş bir tarih varken bilmiyormuş gibi yapardık.
        if [ -z "$K_PENCERE" ]; then
            K_PENCERE="$(pg_sorgu "$C" "$db" \
                "SELECT COALESCE(
                          to_char(stats_reset, 'YYYY-MM-DD HH24:MI')
                            || ' tarihinden beri',
                          to_char(pg_postmaster_start_time(),
                                  'YYYY-MM-DD HH24:MI') || ' tarihinden
                                  beri (sunucu açılışı; sayaç hiç
                                  sıfırlanmamış)')
                   FROM pg_stat_database WHERE datname = current_database();" \
                | tr -d '\r' | tr -s ' ')"
        fi

        # --- 1) ardışık tarama baskın büyük tablolar ------------------------
        # SIRALAMA seq_tup_read'e göre, seq_scan'e göre DEĞİL: asıl maliyet
        # kaç kez tarandığı değil, o taramalarda KAÇ SATIR OKUNDUĞUDUR.
        # 40 satırlık bir tabloyu bir milyon kez taramak ucuzdur; 10 milyon
        # satırlık bir tabloyu on kez taramak değildir.
        while IFS="$AYIRAC" read -r ad sq str idx n_tup; do
            [ -z "$ad" ] && continue
            oneri_ekle "ardisik-tarama" "$db.$ad" \
                "$sq ardışık taramada $(insan_sayi "$str") satır okundu;
                 indeksle okunan $(insan_sayi "$idx") tarama var
                 (tabloda $(insan_sayi "$n_tup") satır)" \
                "EXPLAIN (ANALYZE, BUFFERS) <bu tabloya giden sorgunuz>;"
        done < <(pg_sorgu "$C" "$db" \
            "SELECT relname, seq_scan, seq_tup_read,
                    COALESCE(idx_scan, 0), n_live_tup
               FROM pg_stat_user_tables
              WHERE seq_scan > 0
                AND n_live_tup >= $SLOWLOG_MIN_SATIR
                AND seq_scan > COALESCE(idx_scan, 0)
              ORDER BY seq_tup_read DESC
              LIMIT 3;")

        # --- 2) hiç kullanılmayan indeksler ---------------------------------
        # DIŞARIDA BIRAKILANLAR ve sebepleri:
        #   indisunique / indisprimary → veri bütünlüğü kısıtını taşıyor;
        #     silmek indeksi değil KURALI kaldırır.
        #   indisexclusion             → aynı şey (dışlama kısıtı).
        #   indisreplident             → mantıksal çoğaltma satırı bu
        #     indeksle tanıyor; silinirse replikasyon kırılır.
        # Bu üçü "kullanılmıyor" görünse bile silinemez; önerseydik
        # kullanıcı komutu çalıştırır ve üretimde bir kısıtı kaybederdi.
        while IFS="$AYIRAC" read -r ad idx boyut; do
            [ -z "$idx" ] && continue
            oneri_ekle "kullanilmayan-indeks" "$db.$ad.$idx" \
                "sayaç $K_PENCERE tarihinden beri bu indeksi HİÇ okumadı
                 (idx_scan = 0) ama $(insan_sayi "$boyut") bayt yer tutuyor
                 ve $ad tablosuna yapılan her yazmada güncelleniyor" \
                "DROP INDEX CONCURRENTLY $(pg_kimlik "$idx");"
        done < <(pg_sorgu "$C" "$db" \
            "SELECT s.relname, s.indexrelname,
                    pg_relation_size(s.indexrelid)
               FROM pg_stat_user_indexes s
               JOIN pg_index i ON i.indexrelid = s.indexrelid
              WHERE s.idx_scan = 0
                AND NOT i.indisunique AND NOT i.indisprimary
                AND NOT i.indisexclusion AND NOT i.indisreplident
                AND pg_relation_size(s.indexrelid) >= $SLOWLOG_MIN_INDEKS
              ORDER BY pg_relation_size(s.indexrelid) DESC
              LIMIT 3;")

        # --- 3) EXPLAIN ile doğrulanmış indeks adayları ---------------------
        [ "$K_ACIK" -eq 1 ] && pg_explain_oneri "$C" "$db"
    done <<< "$dblist"
    return 0
}

# =============================================================================
# MARIADB
# =============================================================================
# İKİ KAYNAK, ve seçim ÖLÇÜLEREK yapılıyor:
#
#   performance_schema digest'i — sorguyu normalleştirir ('?'), EŞİK
#     TANIMAZ, her sorguyu sayar ve TRUNCATE ile sıfırlanır. İstediğimiz her
#     şey burada. Bedeli: performance_schema açıkken birkaç yüz MB bellek.
#
#   yavaş sorgu günlüğü — long_query_time'dan UZUN süren sorguları HAM
#     METİNLE dosyaya yazar. İki ayrı sorunu var:
#       a) EŞİK. Bu betiğin aradığı asıl sınıf (kısa ama çok çağrılan)
#          eşiğin altında kalır ve dosyaya HİÇ düşmez. Yani "yavaş sorgu
#          günlüğü boş" demek "yavaş sorgu yok" demek değildir.
#       b) GİZLİLİK. Ham metin diskte durur; WHERE tcno = '12345678901'
#          orada aynen yazılıdır. Biz ekrana basarken maskeliyoruz ama
#          DOSYADAKİ hâli ham; kullanıcıya bunu söylüyoruz.
#
# Bu yüzden digest varsa o seçilir, yoksa günlüğe düşülür ve fark yazılır.

# MariaDB MANTIKSAL DEĞİŞKENLERİ "ON"/"OFF" DİYE DÖNDÜRÜR, 1/0 değil —
# CONCAT_WS onları metne çevirdiği anda "ON" olurlar. İlk yazımda yalnız
# rakam kabul eden bir kontrol vardı ve ÖLÇÜMDE ANINDA PATLADI: my.cnf'te
# slow_query_log = 1 yazılı, sunucu "ON" diyor, araç bunu 0 okuyup "hiçbir
# ölçüm açık değil" raporluyordu. Yani AÇIK olan bir ölçümü kapalı ilan
# ediyorduk — bu betiğin verebileceği en yanıltıcı cevap.
bayrak() {   # bayrak <değer> → 1 / 0
    case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
        1|on|yes|true) printf '1' ;;
        *)             printf '0' ;;
    esac
}

MY_PS=0          # performance_schema açık mı
MY_DIGEST=0      # statements_digest tüketicisi açık mı
MY_SLOW=0        # slow_query_log açık mı
MY_SLOW_DOSYA=""
MY_ESIK_SN=""

my_kesfet() {   # my_kesfet <container>
    local C="$1" satir
    MY_PS=0; MY_DIGEST=0; MY_SLOW=0; MY_SLOW_DOSYA=""; MY_ESIK_SN=""

    satir="$(my_sorgu "$C" \
        "SELECT CONCAT_WS(CHAR(31), @@performance_schema, @@slow_query_log,
                          @@long_query_time, @@slow_query_log_file);")" \
        || return 1
    satir="${satir%$'\r'}"
    IFS="$AYIRAC" read -r MY_PS MY_SLOW MY_ESIK_SN MY_SLOW_DOSYA \
        <<< "$satir"
    MY_PS="$(bayrak "$MY_PS")"
    MY_SLOW="$(bayrak "$MY_SLOW")"

    # performance_schema AÇIK olması yetmez: digest tüketicisi kapalıysa
    # tablo boş kalır. "Açık ama boş"u "yavaş sorgu yok" diye okumamak için
    # ikisi ayrı ölçülüyor.
    if [ "$MY_PS" -eq 1 ]; then
        satir="$(my_sorgu "$C" \
            "SELECT COUNT(*) FROM performance_schema.setup_consumers
              WHERE NAME = 'statements_digest' AND ENABLED = 'YES';" \
            | tr -d '\r[:blank:]')"
        [ "$satir" = "1" ] && MY_DIGEST=1
    fi
    return 0
}

# Yavaş sorgu günlüğü göreli bir adla verilmiş olabilir (my.cnf'te
# 'slow.log'); o zaman datadir'e görelidir.
my_slow_yolu() {   # my_slow_yolu <container>
    case "$MY_SLOW_DOSYA" in
        /*) printf '%s' "$MY_SLOW_DOSYA" ;;
        '') printf '' ;;
        *)  printf '/var/lib/mysql/%s' "$MY_SLOW_DOSYA" ;;
    esac
}

my_kapali_mesaji() {
    K_NASIL="./scripts/slowlog.sh kur mariadb"
    K_NOT="Ne performance_schema digest'i ne de yavaş sorgu günlüğü açık"
    K_NOT="$K_NOT — MariaDB hiçbir sorgunun süresini biriktirmiyor."
}

# --- ölçüm okuma -------------------------------------------------------------
my_oku_digest() {   # my_oku_digest <container> <ham dosya> <sıra> <adet>
    local C="$1" ham="$2" sira="$3" adet="$4" kosul="" sql
    [ -n "$VT" ] && kosul="AND d.SCHEMA_NAME = '$(sql_metin "$VT")'"

    # SUM_TIMER_WAIT PİKOSANİYEDİR (10^-12 sn). 10^9'a bölmek milisaniye
    # verir. Bu bölme unutulursa sayılar bir MİLYAR kat büyük çıkar ve
    # "12 saatlik sorgu" gibi saçma bir liste görünür.
    #
    # ARACIN KENDİ SORGULARI SÜZÜLÜYOR (PostgreSQL tarafındaki aynı
    # gerekçe): süzmeseydik birkaç koşumdan sonra en pahalı sorgu bizim
    # ölçüm sorgumuz olurdu.
    sql="SELECT CONCAT_WS(CHAR(31),
                  d.COUNT_STAR,
                  ROUND(d.SUM_TIMER_WAIT / 1000000000, 1),
                  ROUND(d.AVG_TIMER_WAIT / 1000000000, 3),
                  d.SUM_ROWS_EXAMINED,
                  '',
                  IFNULL(d.SCHEMA_NAME, ''),
                  d.SUM_ROWS_SENT,
                  TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
                      LEFT(d.DIGEST_TEXT, 600),
                      CHAR(10), ' '), CHAR(13), ' '),
                      CHAR(9), ' '), CHAR(31), ' ')))
           FROM performance_schema.events_statements_summary_by_digest d
          WHERE d.DIGEST_TEXT IS NOT NULL
            AND d.DIGEST_TEXT NOT LIKE '%events_statements_summary%'
            AND d.DIGEST_TEXT NOT LIKE '%table_io_waits_summary%'
            AND IFNULL(d.SCHEMA_NAME, '') NOT IN
                ('mysql', 'performance_schema', 'information_schema', 'sys')
            $kosul
          ORDER BY $sira DESC
          LIMIT $adet;"
    my_sorgu "$C" "$sql" > "$ham"
}

# Yavaş sorgu günlüğü ayrıştırıcısı. python3 kullanılıyor (common.sh zaten
# ona bağlı): maskeleme "sayıyı maskele ama tablo1'in 1'ine dokunma" gibi
# geriye bakışlı bir kural istiyor ve bunu awk'ta doğru yazmanın yolu yok —
# yanlış yazıldığında tablo adlarını da maskeler, liste okunamaz hâle gelirdi.
my_oku_slowlog() {   # my_oku_slowlog <container> <ham dosya> <sıra> <adet>
    local C="$1" ham="$2" sira="$3" adet="$4" yol boyut

    yol="$(my_slow_yolu "$C")"
    [ -n "$yol" ] || { K_NOT="slow_query_log_file okunamadı"; return 1; }

    # SON N BAYT okunuyor, dosyanın tamamı değil. Yoğun bir sunucuda bu
    # dosya gigabaytlara çıkar; tamamını container'dan çekmek hem dakikalar
    # sürer hem host'un diskini doldurur. Ne kadar okunduğu ekranda yazıyor
    # — "son 20 MB" ile "her şey" arasındaki farkı kullanıcı bilmeli.
    boyut="${SLOWLOG_KUYRUK_BAYT:-20971520}"
    docker exec "$C" sh -c "tail -c $boyut '$yol' 2>/dev/null" \
        > "$GECICI/slow.log" 2>>"$LOG_FILE" \
        || { K_NOT="yavaş sorgu günlüğü okunamadı: $yol"; return 1; }

    # tr -d '\r' ŞART (maintenance.sh'taki aynı gerekçe): python3'ün print'i
    # Windows'ta CRLF yazar ve bu depo Windows'ta düzenleniyor. Kalan \r
    # SORGU METNİNİN SONUNA yapışıyordu ve JSON'a boşluğa çevrilmiş hâlde
    # giriyordu — yani aynı sorgu iki farklı ortamda iki farklı metin
    # olarak görünürdü. pipefail açık olduğu için python'un çıkış kodu
    # borudan sonra da korunuyor.
    python3 - "$GECICI/slow.log" "$adet" "${VT:-}" "$sira" \
        <<'PY' | tr -d '\r' > "$ham"
import re, sys

yol, adet, vt, sira = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
AYIRAC = "\x1f"

YORUM  = re.compile(r"/\*.*?\*/", re.S)
DIZGI1 = re.compile(r"'(?:[^'\\]|\\.|'')*'")
DIZGI2 = re.compile(r'"(?:[^"\\]|\\.|"")*"')
HEX    = re.compile(r"\b0x[0-9a-fA-F]+\b")
# Geriye bakış ŞART: 'tablo1' içindeki 1 maskelenmemeli, 'LIMIT 10'daki 10
# maskelenmeli. Ayrım tam olarak "önceki karakter tanımlayıcı mı" sorusudur.
SAYI   = re.compile(r"(?<![A-Za-z0-9_$.])\d+(?:\.\d+)?(?:[eE][+-]?\d+)?")
LISTE  = re.compile(r"\?(?:\s*,\s*\?)+")
BOSLUK = re.compile(r"\s+")


def maskele(s):
    s = YORUM.sub(" ", s)
    s = DIZGI1.sub("'?'", s)
    s = DIZGI2.sub("'?'", s)
    s = HEX.sub("?", s)
    s = SAYI.sub("?", s)
    # IN (?, ?, ?, …) tek bir şekle indirilmezse aynı sorgu, listenin
    # uzunluğu kadar ayrı satır olarak görünür ve toplam süre bölünür.
    s = LISTE.sub("?", s)
    s = BOSLUK.sub(" ", s).strip()
    return s.rstrip(";").strip()


kayit = {}
sema = ""
sure = None
tarandi = 0
donen = 0
buf = []


def yaz():
    global sure, buf
    if sure is None or not buf:
        sure, buf = None, []
        return
    metin = maskele(" ".join(buf))
    if metin:
        a = kayit.setdefault((sema, metin), [0, 0.0, 0, 0])
        a[0] += 1
        a[1] += sure * 1000.0
        a[2] += tarandi
        a[3] += donen
    sure, buf = None, []


with open(yol, "r", encoding="utf-8", errors="replace") as f:
    for satir in f:
        satir = satir.rstrip("\n").rstrip("\r")
        if satir.startswith("#"):
            if satir.startswith("# Query_time:"):
                yaz()
                m = re.search(r"Query_time:\s*([0-9.]+)", satir)
                sure = float(m.group(1)) if m else None
                m = re.search(r"Rows_examined:\s*(\d+)", satir)
                tarandi = int(m.group(1)) if m else 0
                m = re.search(r"Rows_sent:\s*(\d+)", satir)
                donen = int(m.group(1)) if m else 0
                buf = []
            elif "Schema:" in satir:
                # BAŞLIK SATIRI İKİ BOŞLUKLA ayrılmış alanlardan oluşur:
                #   # Thread_id: 17  Schema: uygulama  QC_hit: No
                # Basit bir "Schema:\s*(\S+)" deseni, şema BOŞ olduğunda
                # (varsayılan veritabanı seçilmeden bağlanan istemci) bir
                # sonraki alan adını yakalıyordu: her satırın veritabanı
                # "QC_hit:" görünüyordu. Alanlara bölüp adıyla aramak
                # boş şemayı da doğru okuyor.
                sema = ""
                for parca in re.split(r"\s{2,}", satir.lstrip("# ")):
                    if parca.startswith("Schema:"):
                        sema = parca[7:].strip()
            continue
        if sure is None:
            continue
        s = satir.strip()
        if not s:
            continue
        d = s.lower()
        # mysqld'nin kendi başlık satırları ve her kayda eklediği yönetim
        # cümleleri sorgu DEĞİL; sayılsalardı listenin başına onlar geçerdi.
        if d.startswith("set timestamp=") or d.startswith("use "):
            continue
        if s.startswith("/*!") or d.startswith("tcp port:") \
                or d.startswith("time  ") or "started with:" in d:
            continue
        buf.append(s)
        if s.endswith(";"):
            yaz()
    yaz()

satirlar = []
for (sm, metin), (n, ms, tar, don) in kayit.items():
    if vt and sm != vt:
        continue
    satirlar.append((n, ms, tar, don, sm, metin))

if sira == "oran":
    satirlar.sort(key=lambda r: (r[2] / max(r[3], 1), r[1]), reverse=True)
else:
    satirlar.sort(key=lambda r: r[1], reverse=True)

for n, ms, tar, don, sm, metin in satirlar[:adet]:
    print(AYIRAC.join([
        str(n), "%.1f" % ms, "%.3f" % (ms / n if n else 0),
        str(tar), "", sm, str(don), metin]))
PY
    return $?
}

my_oku() {   # my_oku <container> [sıra]
    local C="$1" sira="${2:-toplam}" ham sirala
    gecici_ac || { K_NOT="geçici dizin açılamadı"; return 1; }
    ham="$GECICI/my.ham"; : > "$ham"

    K_SATIR_TURU="examined"
    my_kesfet "$C" || { K_NOT="MariaDB durumu okunamadı"; return 1; }

    if [ "$MY_PS" -eq 1 ] && [ "$MY_DIGEST" -eq 1 ]; then
        K_KAYNAK="performance_schema"
        K_ACIK=1
        K_MASKE=0
        case "$sira" in
            oran) sirala="d.SUM_ROWS_EXAMINED / GREATEST(d.SUM_ROWS_SENT,1)" ;;
            *)    sirala="d.SUM_TIMER_WAIT" ;;
        esac
        my_oku_digest "$C" "$ham" "$sirala" "$ADET" \
            || { K_NOT="digest tablosu okunamadı"; return 1; }
        # Sunucu açılışından beri geçen süre = gözlem penceresi. MariaDB
        # digest'i diske yazılmaz; yeniden başlatma onu SIFIRLAR ve bunu
        # söylemezsek kullanıcı 3 dakikalık ölçüme "haftanın en pahalı
        # sorgusu" diye bakar.
        K_PENCERE="$(my_sorgu "$C" "SHOW GLOBAL STATUS LIKE 'Uptime';" \
                     | awk '{print $2}' | tr -d '\r')"
        [ -n "$K_PENCERE" ] \
            && K_PENCERE="son $((K_PENCERE / 60)) dk, sunucu açılışından beri"
    elif [ "$MY_SLOW" -eq 1 ]; then
        K_KAYNAK="slow_log"
        K_ACIK=1
        K_MASKE=1
        K_ESIK_MS="$(LC_ALL=C awk -v s="${MY_ESIK_SN:-0}" \
                     'BEGIN{printf "%.0f", s * 1000}')"
        my_oku_slowlog "$C" "$ham" "$sira" "$ADET" \
            || { K_NOT="${K_NOT:-yavaş sorgu günlüğü ayrıştırılamadı}"
                 return 1; }
        sirala=""
    else
        K_ACIK=0
        my_kapali_mesaji
        return 0
    fi
    satirlari_al "$ham"
    return 0
}

# --- kur ---------------------------------------------------------------------
# MariaDB'de 'kur' YENİDEN BAŞLATMA GEREKTİRMEZ — PostgreSQL'in tersine.
# slow_query_log ve long_query_time çalışırken değiştirilebilir, digest
# tüketicileri de öyle. Bu farkı ekranda söylüyoruz: iki motorda aynı
# komutun aynı bedeli olduğunu sanmak, "acaba MariaDB de mi kapanacak"
# tereddüdüne yol açardı.
my_kur() {   # my_kur <container>
    local C="$1" esik="${ESIK:-0.5}" acildi=0

    my_kesfet "$C" || olcum_yok "MariaDB durumu okunamadı."
    K_SATIR_TURU="examined"

    if [ "$MY_PS" -eq 1 ]; then
        # Digest tüketicisi ve statement enstrümanları çalışırken açılır.
        # KALICI DEĞİLDİR: yeniden başlatmada performance_schema'nın kendi
        # varsayılanlarına döner. Bunu aşağıda söylüyoruz.
        my_sorgu "$C" "
            UPDATE performance_schema.setup_consumers
               SET ENABLED = 'YES'
             WHERE NAME IN ('statements_digest',
                            'events_statements_current');
            UPDATE performance_schema.setup_instruments
               SET ENABLED = 'YES', TIMED = 'YES'
             WHERE NAME LIKE 'statement/%';" >>"$LOG_FILE" 2>&1 \
            || warn "performance_schema tüketicileri açılamadı (yetki?)."
        acildi=1
        ok "performance_schema digest'i açık — EŞİKSİZ ölçüm."
        log "  Her sorgu sayılıyor; kısa ama çok çağrılanlar da görünür."
    else
        warn "performance_schema KAPALI."
        log  "  Açılırsa ölçüm eşiksiz olur ve sorgu metni normalleştirilir"
        log  "  (ham veri diske yazılmaz). Açmak YENİDEN BAŞLATMA ister:"
        log  "  config/mariadb/my.cnf → [mysqld] bölümüne:"
        log  "    performance_schema = ON"
        log  "  sonra: docker compose up -d mariadb"
    fi

    # Yavaş sorgu günlüğü her hâlde açılıyor: digest yoksa tek kaynak odur,
    # varsa da eşiği aşan tek tek koşumları (ham metin, zaman damgası)
    # incelemek için işe yarar.
    if my_sorgu "$C" "SET GLOBAL slow_query_log = 1;
                      SET GLOBAL long_query_time = $esik;" \
         >>"$LOG_FILE" 2>&1; then
        acildi=1
        ok "Yavaş sorgu günlüğü açık, eşik: $esik sn"
    else
        warn "slow_query_log açılamadı (yetki?)."
    fi

    my_kesfet "$C" || true
    if [ "$MY_PS" -eq 1 ] && [ "$MY_DIGEST" -eq 1 ]; then
        K_KAYNAK="performance_schema"; K_ACIK=1
    elif [ "$MY_SLOW" -eq 1 ]; then
        K_KAYNAK="slow_log"; K_ACIK=1; K_MASKE=1
    else
        K_ACIK=0
    fi

    [ "$acildi" -eq 1 ] || is_dustu "Hiçbir ölçüm kaynağı açılamadı."

    K_ESIK_MS="$(LC_ALL=C awk -v s="$esik" 'BEGIN{printf "%.0f", s * 1000}')"

    printf '\n'
    warn "BU AYARLAR KALICI DEĞİL: SET GLOBAL yeniden başlatmada kaybolur."
    log  "  Kalıcı olması için config/mariadb/my.cnf'teki [mysqld] bölümü:"
    log  "    slow_query_log  = 1"
    log  "    long_query_time = $esik"
    # DOSYAYI BİZ DEĞİŞTİRMİYORUZ ve bunu söylüyoruz. my.cnf motorun bellek
    # ayarlarını da taşıyor; bir ölçüm aracının oraya yazması, bir daha
    # kimsenin o dosyanın kim tarafından düzenlendiğini bilememesi demek.
    log  "  Bu dosyaya DOKUNULMADI — ölçüm aracı motorun ayar dosyasını"
    log  "  sessizce düzenlemez; satırı siz ekleyin."
    if [ "$K_KAYNAK" = "slow_log" ]; then
        printf '\n'
        warn "KAYNAK YAVAŞ SORGU GÜNLÜĞÜ — iki sınırı var:"
        warn "  1) EŞİK: $esik sn'den kısa süren sorgular dosyaya HİÇ"
        warn "     düşmez. Saniyede 2000 kez çağrılan 0.5 ms'lik bir sorgu"
        warn "     sunucunun yarısını yiyor olabilir ve bu listede GÖRÜNMEZ."
        warn "  2) GİZLİLİK: dosyaya HAM SORGU yazılır (WHERE tcno = '…')."
        warn "     'durum' ekranda maskeler; DOSYADAKİ hâli ham kalır."
    fi
    OK=true
    DETAY="ölçüm açık (kaynak: $K_KAYNAK, eşik $esik sn);"
    DETAY="$DETAY yeniden başlatma gerekmedi"
    printf '\n'
    ok "ÖLÇÜM AÇIK. Şimdi: ./scripts/slowlog.sh durum mariadb"
    bitir 0
}

# --- sifirla -----------------------------------------------------------------
my_sifirla() {   # my_sifirla <container>
    local C="$1" yol once sonra

    my_kesfet "$C" || olcum_yok "MariaDB durumu okunamadı."
    K_SATIR_TURU="examined"
    if [ "$MY_PS" -eq 1 ] && [ "$MY_DIGEST" -eq 1 ]; then
        K_KAYNAK="performance_schema"; K_ACIK=1
    elif [ "$MY_SLOW" -eq 1 ]; then
        K_KAYNAK="slow_log"; K_ACIK=1; K_MASKE=1
    else
        K_ACIK=0; my_kapali_mesaji
        warn "$K_NOT"
        log  "Açmak için: $K_NASIL"
        DETAY="ölçüm kapalı: sıfırlanacak sayaç yok"
        bitir 4
    fi

    # --vt BURADA İŞLEMEZ ve bunu söylüyoruz. performance_schema tabloları
    # yalnız TRUNCATE kabul eder, WHERE ile satır silinemez; günlük dosyası
    # da veritabanı bazında bölünmez. Sessizce küme genelini sıfırlasaydık
    # kullanıcı "yalnız kendi veritabanımı sıfırladım" sanırdı.
    [ -n "$VT" ] && warn "MariaDB'de sayaçlar veritabanı bazında" \
        "sıfırlanamaz — '--vt $VT' yok sayıldı, SUNUCU GENELİ sıfırlanıyor."

    if [ "$K_KAYNAK" = "performance_schema" ]; then
        once="$(my_sorgu "$C" "SELECT COUNT(*) FROM
            performance_schema.events_statements_summary_by_digest
            WHERE DIGEST_TEXT IS NOT NULL;" | tr -d '\r[:blank:]')"
        my_sorgu "$C" "TRUNCATE TABLE
            performance_schema.events_statements_summary_by_digest;" \
            >>"$LOG_FILE" 2>&1 \
            || is_dustu "digest tablosu sıfırlanamadı (ayrıntı: $LOG_FILE)."
        sonra="$(my_sorgu "$C" "SELECT COUNT(*) FROM
            performance_schema.events_statements_summary_by_digest
            WHERE DIGEST_TEXT IS NOT NULL;" | tr -d '\r[:blank:]')"
    else
        yol="$(my_slow_yolu "$C")"
        [ -n "$yol" ] || is_dustu "slow_query_log_file okunamadı."
        once="$(docker exec "$C" sh -c "wc -c < '$yol' 2>/dev/null" \
                2>>"$LOG_FILE" | tr -d '\r[:blank:]')"
        # ÖNCE dosyayı boşalt, SONRA FLUSH. Ters sırada yapılsaydı, flush
        # ile yeniden açılan dosyaya araya giren bir sorgu yazılır ve o
        # kayıt truncate ile kaybolurdu.
        docker exec "$C" sh -c ": > '$yol'" >>"$LOG_FILE" 2>&1 \
            || is_dustu "Günlük dosyası boşaltılamadı: $yol"
        my_sorgu "$C" "FLUSH SLOW LOGS;" >>"$LOG_FILE" 2>&1 || true
        sonra="$(docker exec "$C" sh -c "wc -c < '$yol' 2>/dev/null" \
                 2>>"$LOG_FILE" | tr -d '\r[:blank:]')"
    fi

    slog "sayaçlar sıfırlandı (kaynak: $K_KAYNAK): $once → $sonra"
    OK=true
    DETAY="sıfırlandı (kaynak $K_KAYNAK, sunucu geneli): $once → $sonra"
    ok "Sayaçlar sıfırlandı — kaynak: $K_KAYNAK"
    log "Ölçüm birimi: $once → $sonra"
    bitir 0
}

# --- oneri -------------------------------------------------------------------
# MariaDB'de EXPLAIN ile DOĞRULAMA YAPILMIYOR ve sebebi teknik: elimizdeki
# metin normalleştirilmiş (DIGEST_TEXT) ya da maskelenmiş, yani içinde '?'
# var; MariaDB'de PostgreSQL 16'nın GENERIC_PLAN'ı gibi "parametresiz
# planla" diyen bir seçenek yok. Uydurma bir sütun adı üretmektense
# kullanıcıya ÇALIŞTIRACAĞI EXPLAIN komutunu veriyoruz.
my_oneri() {   # my_oneri <container>
    local C="$1" satir sema tbl idx n ms tar don metin komut

    my_kesfet "$C" || olcum_yok "MariaDB durumu okunamadı."
    K_SATIR_TURU="examined"

    if [ "$MY_PS" -eq 1 ] && [ "$MY_DIGEST" -eq 1 ]; then
        K_KAYNAK="performance_schema"; K_ACIK=1
    elif [ "$MY_SLOW" -eq 1 ]; then
        K_KAYNAK="slow_log"; K_ACIK=1; K_MASKE=1
    else
        K_ACIK=0; my_kapali_mesaji; return 0
    fi

    K_PENCERE="$(my_sorgu "$C" "SHOW GLOBAL STATUS LIKE 'Uptime';" \
                 | awk '{print $2}' | tr -d '\r')"
    [ -n "$K_PENCERE" ] \
        && K_PENCERE="son $((K_PENCERE / 60)) dk, sunucu açılışından beri"

    if [ "$K_KAYNAK" = "performance_schema" ]; then
        # 1) İNDEKS KULLANMAYAN sorgular. Bu bir tahmin değil: MariaDB'nin
        # kendi sayacı (SUM_NO_INDEX_USED) o sorgunun kaç kez indekssiz
        # koştuğunu sayıyor.
        while IFS="$AYIRAC" read -r sema n ms tar metin; do
            [ -z "$metin" ] && continue
            oneri_ekle "indeks-kullanilmiyor" "${sema:-?}" \
                "$n koşumun tamamı indeks kullanmadı; toplam
                 $(insan_sure "$ms") sürdü ve $(insan_sayi "$tar") satır
                 tarandı" \
                "EXPLAIN $(kisalt_bas "$metin" 60)"
        done < <(my_sorgu "$C" \
            "SELECT CONCAT_WS(CHAR(31),
                      IFNULL(SCHEMA_NAME, ''), COUNT_STAR,
                      ROUND(SUM_TIMER_WAIT / 1000000000, 1),
                      SUM_ROWS_EXAMINED,
                      TRIM(REPLACE(REPLACE(REPLACE(LEFT(DIGEST_TEXT, 300),
                          CHAR(10), ' '), CHAR(9), ' '), CHAR(31), ' ')))
               FROM performance_schema.events_statements_summary_by_digest
              WHERE SUM_NO_INDEX_USED > 0 AND DIGEST_TEXT IS NOT NULL
                AND IFNULL(SCHEMA_NAME, '') NOT IN
                    ('mysql', 'performance_schema', 'information_schema',
                     'sys')
              ORDER BY SUM_TIMER_WAIT DESC LIMIT 3;")

        # 2) HİÇ KULLANILMAYAN indeksler.
        # PRIMARY ve UNIQUE dışarıda: onlar kısıt taşıyor, silmek kuralı
        # kaldırır. YABANCI ANAHTAR indeksleri de dışarıda — MariaDB
        # onların silinmesini zaten reddeder; önerseydik kullanıcıya
        # çalışmayacak bir komut vermiş olurduk.
        while IFS="$AYIRAC" read -r sema tbl idx; do
            [ -z "$idx" ] && continue
            komut="DROP INDEX $(my_kimlik "$idx") ON"
            komut="$komut $(my_kimlik "$sema").$(my_kimlik "$tbl");"
            oneri_ekle "kullanilmayan-indeks" "$sema.$tbl.$idx" \
                "sayaç ${K_PENCERE:-?} boyunca bu indeksi HİÇ okumadı ama
                 $tbl tablosuna yapılan her yazmada güncelleniyor" \
                "$komut"
        done < <(my_sorgu "$C" \
            "SELECT CONCAT_WS(CHAR(31), u.OBJECT_SCHEMA, u.OBJECT_NAME,
                              u.INDEX_NAME)
               FROM performance_schema.table_io_waits_summary_by_index_usage u
               JOIN information_schema.STATISTICS st
                 ON st.TABLE_SCHEMA = u.OBJECT_SCHEMA
                AND st.TABLE_NAME   = u.OBJECT_NAME
                AND st.INDEX_NAME   = u.INDEX_NAME
                AND st.SEQ_IN_INDEX = 1
              WHERE u.INDEX_NAME IS NOT NULL
                AND u.INDEX_NAME <> 'PRIMARY'
                AND u.COUNT_STAR = 0
                AND st.NON_UNIQUE = 1
                AND u.OBJECT_SCHEMA NOT IN
                    ('mysql', 'performance_schema', 'information_schema',
                     'sys')
                AND NOT EXISTS (
                    SELECT 1 FROM information_schema.KEY_COLUMN_USAGE k
                     WHERE k.TABLE_SCHEMA = u.OBJECT_SCHEMA
                       AND k.TABLE_NAME = u.OBJECT_NAME
                       AND k.CONSTRAINT_NAME = u.INDEX_NAME
                       AND k.REFERENCED_TABLE_NAME IS NOT NULL)
              ORDER BY u.OBJECT_SCHEMA, u.OBJECT_NAME LIMIT 3;")
    else
        K_NOT="performance_schema kapalı: KULLANILMAYAN İNDEKSLER"
        K_NOT="$K_NOT ölçülemiyor (o sayaç yalnız orada var)."
    fi

    # 3) TARANAN / DÖNEN satır oranı. Her iki kaynakta da ölçülebilir ve
    # indeks eksikliğinin en doğrudan işareti: 2 milyon satır tarayıp 10
    # satır döndüren bir sorgu, işini yapmak için tablonun tamamını
    # okuyordur.
    # my_oku kaynak alanlarını yeniden ölçüyor ve K_NOT'u siliyor; yukarıda
    # yazdığımız "performance_schema kapalı" notu kaybolmasın diye kenara
    # alınıyor. Not kaybolsaydı, ölçülemeyen bir şeyin ölçülemediği
    # söylenmemiş olurdu — bu betikteki en pahalı sessiz hata sınıfı.
    local not_yedek="$K_NOT" adet_yedek="$ADET"
    olcum_sifirla
    ADET=3
    my_oku "$C" "oran" >/dev/null 2>&1
    ADET="$adet_yedek"
    K_NOT="$not_yedek"
    local i n2="${#Q_METIN[@]}" oran
    for i in $(seq 0 $((n2 - 1))); do
        [ "$n2" -eq 0 ] && break
        tar="${Q_SATIR[$i]}"; don="${Q_EK[$i]}"
        case "$tar$don" in *[!0-9]*|'') continue ;; esac
        [ "$tar" -lt 100000 ] && continue
        oran=$(( tar / (don > 0 ? don : 1) ))
        [ "$oran" -lt 100 ] && continue
        oneri_ekle "tarama-orani" "${Q_VT[$i]:-?}" \
            "$(insan_sayi "$tar") satır tarayıp $(insan_sayi "$don") satır
             döndürdü (oran 1:$oran); süzgeç sütununda indeks yok gibi
             görünüyor" \
            "EXPLAIN $(kisalt_bas "${Q_METIN[$i]}" 60)"
    done
    return 0
}

# =============================================================================
# RAPOR
# =============================================================================
# Sütun genişlikleri 79 sütuna sığacak şekilde seçildi. Sorgu metni AYRI BİR
# SATIRDA: sayılarla aynı satıra sıkıştırılsaydı 20 karaktere düşerdi ve
# "SELECT * FRO…" hiçbir sorunun cevabı değildir.
rapor_yaz() {   # rapor_yaz <motor>
    local motor="$1" i n="${#Q_METIN[@]}"

    log "kaynak : $K_KAYNAK"
    [ -n "$K_PENCERE" ] && log "pencere: $K_PENCERE"
    if [ -n "$K_ESIK_MS" ]; then
        log "eşik   : $(insan_sure "$K_ESIK_MS") — BUNDAN KISA SÜREN"
        log "         sorgular bu listede HİÇ GÖRÜNMEZ"
    fi
    if [ "$K_MASKE" -eq 1 ]; then
        warn "Bu kaynak HAM SORGU saklar. Aşağıdaki metinlerde dizgi"
        warn "sabitleri ve sayılar '?' ile MASKELENDİ; diskteki günlük"
        warn "dosyasında ham hâlleri duruyor."
    fi
    [ -n "$K_NOT" ] && warn "$K_NOT"

    if [ "$n" -eq 0 ]; then
        ok "Ölçüm açık ama henüz hiç sorgu birikmemiş."
        log "Sayaçlar yeni sıfırlanmış olabilir; biraz trafikten sonra" \
            "tekrar bakın."
        return 0
    fi

    printf '\n'
    printf '  %-3s %8s %10s %10s %9s  %s\n' \
        "#" "çağrı" "TOPLAM" "ortalama" "satır" "veritabanı"
    printf '  %s\n' "$(printf '%.0s-' $(seq 1 74))"
    for i in $(seq 0 $((n - 1))); do
        printf '  %-3s %8s %10s %10s %9s  %s\n' \
            "$((i + 1))" \
            "$(insan_sayi "${Q_CAGRI[$i]}")" \
            "$(insan_sure "${Q_TOPLAM[$i]}")" \
            "$(insan_sure "${Q_ORT[$i]}")" \
            "$(insan_sayi "${Q_SATIR[$i]}")" \
            "$(kisalt_son "${Q_VT[$i]:-—}" 16)"
        printf '      %s\n' "$(kisalt_bas "${Q_METIN[$i]}" 70)"
    done
    printf '\n'
    printf '  %sSıralama TOPLAM süreye göre%s — ortalamaya göre değil.\n' \
        "$BOLD" "$NC"
    printf '  Kısa süren ama çok çağrılan bir sorgu, uzun süren ama\n'
    printf '  seyrek çağrılandan pahalıdır; sunucuyu dolduran ilkidir.\n'
    case "$K_SATIR_TURU" in
        examined) printf '  "satır" = TARANAN satır (MariaDB).\n' ;;
        returned) printf '  "satır" = DÖNEN satır (PostgreSQL).\n' ;;
    esac
    return 0
}

oneri_yaz() {   # oneri_yaz <motor>
    local i n="${#O_TUR[@]}" neden

    [ -n "$K_PENCERE" ] && log "pencere: $K_PENCERE"
    [ -n "$K_NOT" ] && warn "$K_NOT"

    if [ "$n" -eq 0 ]; then
        ok "Ölçülebilen bir öneri çıkmadı."
        log "Bu 'her şey mükemmel' demek değil: bu betik yalnız SAYAÇLA" \
            "ÖLÇÜLEBİLEN üç şeyi söyler (ardışık tarama, kullanılmayan" \
            "indeks, EXPLAIN'de görülen süzgeç). Ölçemediğini uydurmuyor."
        return 0
    fi

    printf '\n'
    for i in $(seq 0 $((n - 1))); do
        # Gerekçe metni kaynak kodda birden çok satıra yazılmış olabilir;
        # boşlukları tek satıra indiriyoruz ki ekran düzeni bozulmasın.
        neden="$(printf '%s' "${O_NEDEN[$i]}" | tr -s ' \n\t' ' ')"
        printf '  %s[%s]%s %s\n' "$BOLD" "${O_TUR[$i]}" "$NC" \
            "$(kisalt_son "${O_NESNE[$i]}" 55)"
        printf '     neden : %s\n' "$(kisalt_bas "$neden" 64)"
        printf '     komut : %s\n' "$(kisalt_bas "${O_SQL[$i]}" 64)"
        printf '\n'
    done

    # Bu uyarı BİLEREK her koşumda basılıyor. Öneri listesi bir "yapılacaklar
    # listesi" gibi okunmaya çok müsait; oysa her satırın bir bedeli var ve
    # o bedeli ödeyecek olan kullanıcının uygulaması.
    warn "BU KOMUTLARIN HİÇBİRİ ÇALIŞTIRILMADI — yalnız yazıldı."
    log  "  İndeks EKLEMEK okumayı hızlandırır ama HER INSERT/UPDATE'i"
    log  "  yavaşlatır ve disk kullanır. İndeks SİLMEK geri alması"
    log  "  dakikalar süren bir iştir. Bu takası ancak uygulamayı bilen"
    log  "  kişi yapabilir; ölçüm aracı yapamaz."
    log  "  Önce test/kopya bir ortamda deneyin."
    return 0
}

# =============================================================================
# JSON PARÇALARI
# =============================================================================
json_sorgular() {   # json_sorgular <ön ek>
    local onek="$1" i n="${#Q_METIN[@]}" out=""
    for i in $(seq 0 $((n - 1))); do
        [ "$n" -eq 0 ] && break
        out="${out:+$out,}"
        out="$out{\"query\":$(js "${Q_METIN[$i]}")"
        out="$out,\"calls\":$(jsnum "${Q_CAGRI[$i]}")"
        out="$out,\"total_ms\":$(jsnum "${Q_TOPLAM[$i]}")"
        out="$out,\"avg_ms\":$(jsnum "${Q_ORT[$i]}")"
        out="$out,\"rows\":$(jsnum "${Q_SATIR[$i]}")"
        # BOŞ DİZGE DEĞİL null: MariaDB'de sorgu başına okunan blok diye bir
        # sayaç yok. 0 yazsaydık panel "disk okuması yok" derdi.
        out="$out,\"blocks\":$(jsnum "${Q_BLOK[$i]}")"
        out="$out,\"db\":$(js "$onek${Q_VT[$i]}")}"
    done
    printf '%s' "$out"
}

json_oneriler() {
    local i n="${#O_TUR[@]}" out="" neden
    for i in $(seq 0 $((n - 1))); do
        [ "$n" -eq 0 ] && break
        neden="$(printf '%s' "${O_NEDEN[$i]}" | tr -s ' \n\t' ' ')"
        out="${out:+$out,}"
        out="$out{\"kind\":$(js "${O_TUR[$i]}")"
        out="$out,\"object\":$(js "${O_NESNE[$i]}")"
        out="$out,\"reason\":$(js "$neden")"
        out="$out,\"sql\":$(js "${O_SQL[$i]}")}"
    done
    printf '%s' "$out"
}

# =============================================================================
# KULLANIM
# =============================================================================
kullanim() {
cat <<'EOF'

Yavaş sorgu ölçümü — databases-stack

  ./scripts/slowlog.sh kur <motor>
  ./scripts/slowlog.sh durum [motor]
  ./scripts/slowlog.sh oneri <motor>
  ./scripts/slowlog.sh sifirla <motor>

  kur      Ölçümü açar. PostgreSQL'de ayarı yazar ve YENİDEN BAŞLATMA
           gerektiğini söyler — sunucuyu KENDİ BAŞINA yeniden başlatmaz.
           MariaDB'de yeniden başlatma gerekmez.
  durum    En pahalı ilk N sorgu, TOPLAM SÜREYE göre sıralı. Hiçbir şeyi
           değiştirmez. Motor verilmezse kapsamdaki çalışan motorların
           hepsine bakılır.
  oneri    Ölçülebilen indeks/ayar önerileri. Komutları YALNIZ YAZAR,
           çalıştırmaz.
  sifirla  Sayaçları sıfırlar. Biriken ölçüm GERİ GELMEZ.

  Seçenekler
    --adet <n>    Kaç sorgu listelensin (varsayılan 10, en çok 200).
    --vt <ad>     Yalnız bu veritabanı. PostgreSQL'de 'sifirla' da bu
                  veritabanıyla sınırlanır; MariaDB'de sayaçlar
                  veritabanı bazında sıfırlanamaz (söylenir).
    --esik <sn>   'kur mariadb' için long_query_time (varsayılan 0.5).

  Kapsam: mariadb, postgresql. Diğer motorlarda yavaş sorgu ölçümünün
  karşılığı bambaşka bir iştir (MongoDB profiler, MSSQL Query Store,
  Elasticsearch slow log) ve bu betikte yapılmadı — çıkış kodu 2.

  Çıkış kodları: 0 tamam · 1 iş düştü · 2 kapsam dışı / kullanım hatası
                 3 ölçülemedi · 4 ÖLÇÜM KAPALI (boş liste ile aynı şey
                 değildir)

  Örnekler
    ./scripts/slowlog.sh kur postgresql
    ./scripts/slowlog.sh durum
    ./scripts/slowlog.sh durum postgresql --adet 20 --vt uygulama
    ./scripts/slowlog.sh oneri mariadb
    ./scripts/slowlog.sh sifirla postgresql --vt uygulama

EOF
}

# =============================================================================
# ARGÜMANLAR
# =============================================================================
if [ $# -gt 0 ]; then
    case "$1" in
        kur|durum|oneri|sifirla) KOMUT="$1"; shift ;;
        -h|--yardim|yardim)
            kullanim; DETAY="yardım basıldı"; bitir 2 ;;
        -*) ;;   # seçenek: komut varsayılan 'durum' kalsın
        *)  # Sık yapılan hata: komut yerine doğrudan motor adı yazmak.
            if katalogda_var "$1"; then
                kullanim
                kapsam_disi "Komut eksik: '$1' bir motor adı. Şunu demek" \
                    "istediniz: ./scripts/slowlog.sh durum $1"
            fi
            kullanim
            kapsam_disi "Bilinmeyen komut: $1" ;;
    esac
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --adet)
            [ $# -ge 2 ] || { kullanim; kapsam_disi "--adet bir sayı ister."; }
            case "$2" in
                ''|*[!0-9]*|0) kapsam_disi "--adet 1-200 arası olmalı: $2" ;;
            esac
            [ "$2" -gt 200 ] && kapsam_disi "--adet en çok 200: $2"
            ADET="$2"; shift ;;
        --vt)
            [ $# -ge 2 ] || { kullanim; kapsam_disi "--vt bir ad ister."; }
            VT="$2"; shift ;;
        --esik)
            [ $# -ge 2 ] || { kullanim; kapsam_disi "--esik bir sayı ister."; }
            case "$2" in
                ''|*[!0-9.]*|*.*.*) kapsam_disi "--esik saniye olmalı: $2" ;;
            esac
            ESIK="$2"; shift ;;
        -h|--yardim) kullanim; DETAY="yardım basıldı"; bitir 2 ;;
        -*) kullanim; kapsam_disi "Bilinmeyen seçenek: $1" ;;
        *)  if [ -z "$MOTOR" ]; then
                MOTOR="$1"
                # JSON'daki engine alanı DA hemen doluyor: motor okunduktan
                # SONRA gelen bir seçenek hatasında çıktı "hepsi" derdi ve
                # panel hatayı yanlış motora yazardı (maintenance.sh'taki
                # aynı gerekçe).
                JS_MOTOR="$1"
            else kapsam_disi "Fazladan argüman: $1"; fi ;;
    esac
    shift
done

case "$KOMUT" in
    kur|oneri|sifirla)
        [ -n "$MOTOR" ] || { kullanim
            kapsam_disi "'$KOMUT' bir motor ister — hangi motorda" \
                "çalışacağı tahmin edilemez."; } ;;
esac

if [ -n "$MOTOR" ]; then
    JS_MOTOR="$MOTOR"
    if ! katalogda_var "$MOTOR"; then
        kapsam_disi "Kataloğda böyle bir motor yok: $MOTOR (bkz." \
            "catalog.json)"
    fi
    if ! destekli_mi "$MOTOR"; then
        kapsam_disi "Bu motorda yavaş sorgu ölçümü yok: $MOTOR — kapsam:" \
            "$DESTEKLI. Diğer motorlarda karşılığı farklı bir iştir" \
            "(MongoDB profiler, MSSQL Query Store, Elasticsearch slow" \
            "log) ve bu betikte uygulanmadı."
    fi
fi

if [ -n "$ESIK" ] && { [ "$KOMUT" != "kur" ] || [ "$MOTOR" != "mariadb" ]; }
then
    kapsam_disi "--esik yalnız 'kur mariadb' için anlamlı: PostgreSQL'de" \
        "pg_stat_statements eşik tanımaz, her sorguyu sayar."
fi

command -v docker >/dev/null 2>&1 \
    || olcum_yok "docker bulunamadı — motorların içine bakılamıyor."
docker info >/dev/null 2>&1 \
    || olcum_yok "docker'a erişilemiyor (servis kapalı ya da yetki yok)."

motor_container() {   # motor_container <motor>
    local C; C="$(primary_of "$1")"
    container_running "$C" || return 1
    printf '%s' "$C"
}

# =============================================================================
# DURUM
# =============================================================================
durum_calistir() {
    local hedefler="" eid C olculen=0 acik=0 parca onek="" listelenen=0

    if [ -n "$MOTOR" ]; then
        hedefler="$MOTOR"
    else
        for eid in $DESTEKLI; do
            container_running "$(primary_of "$eid")" \
                && hedefler="${hedefler:+$hedefler }$eid"
        done
        [ -n "$hedefler" ] \
            || olcum_yok "Kapsamdaki motorların ($DESTEKLI) hiçbiri" \
                "çalışmıyor — okunacak bir sayaç yok."
    fi

    for eid in $hedefler; do
        C="$(primary_of "$eid")"
        if ! container_running "$C"; then
            # Motor KAPALI. Tek motor istendiyse bu bir ölçüm yokluğudur ve
            # 0 ile çıkmak yalan olurdu: "yavaş sorgu yok" ile "bakamadım"
            # aynı şey değildir.
            if [ -n "$MOTOR" ]; then
                olcum_yok "$eid kapalı (container: $C) — sayaçlar" \
                    "okunamaz. Önce açın: ./stack.sh enable $eid"
            fi
            continue
        fi
        olcum_sifirla
        heading "$eid — en pahalı sorgular ($C)"
        case "$eid" in
            postgresql) pg_oku "$C" ;;
            mariadb)    my_oku "$C" ;;
        esac
        if [ "$?" -ne 0 ]; then
            if [ -n "$MOTOR" ]; then
                olcum_yok "$eid okunamadı: ${K_NOT:-sorgu düştü}." \
                    "Ayrıntı: $LOG_FILE"
            fi
            warn "$eid okunamadı: ${K_NOT:-sorgu düştü}"
            continue
        fi

        if [ "$K_ACIK" -ne 1 ]; then
            # BOŞ LİSTE BASMIYORUZ. Kullanıcının bu ekrandan çıkarması
            # gereken tek cümle "ölçüm kapalı"dır; sayı basmak onu
            # "sorgularım hızlıymış" sonucuna götürürdü.
            warn "ÖLÇÜM KAPALI — $eid"
            warn "  $K_NOT"
            log  "  Açmak için:  $K_NASIL"
            kaynak_json_yaz
            [ -n "$MOTOR" ] && {
                DETAY="ölçüm kapalı: $K_NOT"
                bitir 4
            }
            echo
            continue
        fi

        rapor_yaz "$eid"
        onek=""
        [ -z "$MOTOR" ] && onek="$eid:"
        parca="$(json_sorgular "$onek")"
        [ -n "$parca" ] && JS_SORGULAR="${JS_SORGULAR:+$JS_SORGULAR,}$parca"
        JS_TOPLAM="$(LC_ALL=C awk -v a="$JS_TOPLAM" -v b="$Q_TOPLAM_MS" \
                     'BEGIN{printf "%.1f", a + b}')"
        listelenen=$((listelenen + ${#Q_METIN[@]}))
        olculen=$((olculen + 1))
        acik=$((acik + 1))
        echo
    done

    if [ "$acik" -eq 0 ]; then
        # Hiçbir motorda ölçüm açık değil: çıkış 4. Çıkış 0 verseydik
        # "baktım, temiz" ile "hiç bakılmadı" tek koda sıkışırdı.
        DETAY="kapsamdaki hiçbir motorda yavaş sorgu ölçümü açık değil"
        warn "Hiçbir motorda ölçüm açık değil."
        log  "Açmak için: ./scripts/slowlog.sh kur <motor>"
        bitir 4
    fi

    OK=true
    DETAY="ölçüldü: $olculen motor, $listelenen sorgu listelendi,"
    DETAY="$DETAY toplam $JS_TOPLAM ms"
    log "Öneri için: ./scripts/slowlog.sh oneri <motor>"
    bitir 0
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
kur_calistir() {
    local C
    C="$(motor_container "$MOTOR")" \
        || olcum_yok "$MOTOR kapalı — ayar yazılamaz. Önce açın:" \
            "./stack.sh enable $MOTOR"
    heading "$MOTOR — yavaş sorgu ölçümünü aç ($C)"
    case "$MOTOR" in
        postgresql) pg_kur "$C" ;;
        mariadb)    my_kur "$C" ;;
    esac
}

sifirla_calistir() {
    local C
    C="$(motor_container "$MOTOR")" \
        || olcum_yok "$MOTOR kapalı — sayaçlara erişilemez."
    heading "$MOTOR — sayaçları sıfırla ($C)"
    warn "Biriken ölçüm GERİ GELMEZ; sıfırladıktan sonra 'durum' bir süre" \
         "boş kalır."
    case "$MOTOR" in
        postgresql) pg_sifirla "$C" ;;
        mariadb)    my_sifirla "$C" ;;
    esac
}

oneri_calistir() {
    local C
    C="$(motor_container "$MOTOR")" \
        || olcum_yok "$MOTOR kapalı — öneri için sayaçlar okunamaz."
    olcum_sifirla
    heading "$MOTOR — ölçülebilen öneriler ($C)"
    case "$MOTOR" in
        postgresql) pg_oneri "$C" ;;
        mariadb)    my_oneri "$C" ;;
    esac
    kaynak_json_yaz
    if [ "$K_ACIK" -ne 1 ]; then
        warn "ÖLÇÜM KAPALI — $K_NOT"
        log  "Açmak için: $K_NASIL"
        log  "Not: 'kullanılmayan indeks' ve 'ardışık tarama' ölçümleri" \
             "ölçümden bağımsız çalışır; aşağıdaki liste yalnız onları" \
             "içeriyor olabilir."
    fi
    oneri_yaz "$MOTOR"
    JS_ONERILER="$(json_oneriler)"
    OK=true
    DETAY="${#O_TUR[@]} öneri ölçüldü; HİÇBİRİ UYGULANMADI"
    bitir 0
}

case "$KOMUT" in
    durum)   durum_calistir ;;
    kur)     kur_calistir ;;
    sifirla) sifirla_calistir ;;
    oneri)   oneri_calistir ;;
    *)       kullanim; kapsam_disi "Bilinmeyen komut: $KOMUT" ;;
esac
