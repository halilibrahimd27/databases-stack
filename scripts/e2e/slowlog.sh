#!/bin/bash
# =============================================================================
# databases-stack — E2E: YAVAŞ SORGU ÖLÇÜMÜ (scripts/slowlog.sh)
# =============================================================================
# Bu paketin sorduğu soru "veritabanı yavaş mı" değil:
#
#     ARAÇ EN PAHALI SORGUYU GERÇEKTEN BULUYOR MU, VE SIRALAMAYI DOĞRU
#     ÖLÇÜTE GÖRE MI YAPIYOR?
#
# Sebep: bu araç bir LİSTE basıyor ve kullanıcı o listenin ilk satırına
# bakıp uygulamasını değiştirmeye, indeks eklemeye, sunucuyu büyütmeye
# karar veriyor. Böyle bir aracın üç şekilde zarar vermesi mümkün ve üçü de
# sessizdir:
#   1) GÖRMEZ — pahalı sorgu listede hiç çıkmaz; kullanıcı sorunu başka
#      yerde arar ve bulamaz.
#   2) YANLIŞ SIRALAR — ortalamaya göre sıralarsa, saniyede binlerce kez
#      koşan ucuz sorgu listenin dibinde kalır. Sunucuyu dolduran tam
#      olarak odur; kullanıcı onun yerine günde bir koşan raporu
#      "optimize eder" ve hiçbir şey değişmez.
#   3) BOŞ LİSTE BASAR — ölçüm hiç açılmamışken "yavaş sorgun yok" gibi
#      okunan bir çıktı verir. Bu üçünün en pahalısıdır.
#
# Bu yüzden buradaki kontroller ARACIN KENDİSİNİ ölçüyor: BİLEREK bilinen
# maliyette dört ayrı sorgu koşturuyoruz ve aracın onları hangi sırayla
# raporladığını sayıyla karşılaştırıyoruz.
#
# SIRALAMA KONTROLÜ NASIL AYIRT EDİCİ HÂLE GETİRİLDİ:
# İki sorgu bilerek TERS düşecek şekilde tasarlandı —
#     sik    : ÇOK çağrılır, tek koşumu UCUZ  → toplamı BÜYÜK, ortalaması KÜÇÜK
#     nadir  : AZ çağrılır, tek koşumu PAHALI → toplam KÜÇÜK, ortalama BÜYÜK
# Araç toplam süreye göre sıralıyorsa 'sik' ÜSTTE olmalı; ortalamaya göre
# sıralıyorsa 'nadir' üstte olurdu. Tek bir yavaş sorgu koşturan bir test bu
# ikisini birbirinden AYIRAMAZDI — ikisinde de aynı sonucu verirdi.
#
# ÖLÇÜLENLER
#   · kapsam dışı motorda 0 DEĞİL anlamlı bir kod dönüyor mu (çıkış 2)
#   · katalogda olmayan motorda ne yapıyor
#   · motorsuz 'kur' ne yapıyor
#   · son satır TEK SATIR ve GEÇERLİ JSON mu (panel bunu okuyacak)
#   · ÖLÇÜM KAPALIYKEN 'durum' sessizce boş liste mi basıyor, yoksa
#     "kapalı, şöyle açılır" mı diyor (çıkış 4)
#   · 'kur' sunucuyu SESSİZCE YENİDEN BAŞLATIYOR mu (başlatmamalı)
#   · BİLEREK yavaş koşturulan sorgu ilk N içinde çıkıyor mu
#   · o sorgunun ÇAĞRI SAYISI koşturduğumuz sayıya eşit mi
#   · sıralama gerçekten TOPLAM süreye göre mi (sik > nadir)
#   · ucuz ve seyrek sorgu ilk N'e GİRMİYOR mu
#   · 'sifirla' sayaçları gerçekten sıfırlıyor mu
#   · 'oneri' ölçtüğü şeyi buluyor mu VE hiçbir şey UYGULAMIYOR mu
#   · üretim container'ına dokunulmadı mı
#   · test kendi veritabanını SONUNDA siliyor mu
#
# ⚠ YAN ETKİLER — hepsi bilerek ve burada yazılı:
#   · Motorlarda 'e2e_' ile başlayan geçici bir VERİTABANI yaratılır,
#     onlarca MB veri yazılır ve paket sonunda DÜŞÜRÜLÜR.
#   · SAYAÇLAR SIFIRLANIR. PostgreSQL'de yalnız test veritabanı için
#     ('sifirla --vt'), yani üretim ölçümü korunur. MariaDB'de sayaçlar
#     veritabanı bazında sıfırlanamaz: orada SUNUCU GENELİ sıfırlanır ve
#     o ana kadar birikmiş yavaş sorgu ölçümü KAYBOLUR.
#   · MariaDB'de 'kur' GLOBAL slow_query_log / long_query_time değerlerini
#     değiştirir. Paket başlangıçtaki değerleri okur ve sonunda GERİ
#     YAZAR.
#   · PostgreSQL'de 'kur' postgresql.conf'a bir include satırı ekler ve
#     eklentiyi yaratır. Bu GERİ ALINMAZ — zaten ürünün kurulum adımıdır.
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/slowlog.sh              çalışan motorların hepsi
#     ./scripts/e2e/slowlog.sh postgresql   yalnız biri
#
# Ayarlar (ortam değişkeni):
#     E2E_SLOWLOG_SATIR=…    büyük tablodaki satır (varsayılan 120000)
#     E2E_SLOWLOG_KAT=…      MariaDB'de kaç kez ikiye katlanacak
#                            (varsayılan 17 → 131072 satır)
#     E2E_SLOWLOG_YENIDEN_BASLAT=1
#                            PostgreSQL'de ölçüm kapalıysa 'kur'dan sonra
#                            container'ı YENİDEN BAŞLATIR ki asıl ölçüm
#                            kontrolleri koşabilsin. VARSAYILAN KAPALI:
#                            bir test paketinin üretim veritabanını
#                            kendiliğinden kapatması kabul edilemez. Kapalı
#                            olduğunda ilgili kontroller ATLANIR ve sebebi
#                            yazılır (lib.sh bunu "eksik kapsam" sayar).
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
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi" \
           "olmadan bu paket ölçüm yapamaz."
E2E_SUITE="slowlog"
source scripts/e2e/lib.sh

# --- SONUÇ SARMALAYICILARI ---------------------------------------------------
# lib.sh'in t_ok/t_fail/t_skip/t_unknown fonksiyonları YALNIZ İKİ argüman
# okur: $1 ad, $2 sebep. Uzun bir sebebi ters bölü ile satıra bölmek onu
# ÜÇÜNCÜ argümana çevirir ve o parça HİÇ BASILMAZ.
# Bu paketin ilk koşumunda tam olarak bu oldu: sıralama kontrolünün kanıt
# sayıları ("nadir sıra 3: toplam … ort …") ekranda yarıda kesildi — yani
# kontrol geçti ama NEYE dayanarak geçtiği görünmüyordu. 79 sütun sınırı
# olan bir depoda uzun gerekçeyi tek satırda tutmak da mümkün değil; bu
# sarmalayıcılar fazladan parçaları tek dizgede birleştiriyor.
r_ok()      { t_ok "$*"; }
r_fail()    { local a="$1"; shift; t_fail    "$a" "$*"; }
r_skip()    { local a="$1"; shift; t_skip    "$a" "$*"; }
r_unknown() { local a="$1"; shift; t_unknown "$a" "$*"; }

ARAC="scripts/slowlog.sh"
# Çalıştırma izni kaybolmuş bir checkout'ta (Windows'tan kopyalanmış depo,
# unzip edilmiş arşiv) "./betik" Permission denied verir. Paket bunu ÜRÜN
# HATASI gibi raporlamasın diye çağrı biçimini burada bir kez seçiyoruz.
ARAC_CAGRI=("./$ARAC")
[ -x "$ARAC" ] || ARAC_CAGRI=(bash "$ARAC")

LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
mkdir -p "$LOG_DIR"
E2E_LOG="$LOG_DIR/e2e-slowlog_$(date +%Y%m%d_%H%M%S).log"
: > "$E2E_LOG"
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-slowlog-XXXXXX")" \
    || die "Geçici dizin açılamadı."

SATIR="${E2E_SLOWLOG_SATIR:-120000}"
KAT="${E2E_SLOWLOG_KAT:-17}"
YENIDEN="${E2E_SLOWLOG_YENIDEN_BASLAT:-0}"

# --- İŞ YÜKÜ: dört sorgu, bilinen ve BİLEREK ters düşen maliyetlerle -------
# YAVAS_N × (büyük tablo taraması)  → toplamı en büyük olmalı
# SIK_N   × (küçük tablo taraması)  → toplam BÜYÜK, ortalama KÜÇÜK
# NADIR_N × (büyük tablo taraması)  → toplam KÜÇÜK, ortalama BÜYÜK
# HIZLI_N × (birincil anahtar)      → hepsinin en ucuzu
YAVAS_N="${E2E_SLOWLOG_YAVAS:-20}"
SIK_N="${E2E_SLOWLOG_SIK:-400}"
NADIR_N="${E2E_SLOWLOG_NADIR:-2}"
HIZLI_N="${E2E_SLOWLOG_HIZLI:-5}"

# Kendi adımız. PID'li: aynı makinede iki koşum çakışmasın. 'e2e' ile
# başlıyor ki elde kalan bir kalıntı üretim veritabanlarından BAKIŞTA
# ayrılabilsin. Tablo adları da PID taşıyor, çünkü sorguyu listede ADIYLA
# arıyoruz: 'yavas' gibi genel bir ad üretimdeki bir tabloyla çakışsaydı
# başka birinin sorgusunu kendi sorgumuz sanardık.
E2E_DB="e2e_slowlog_$$"
T_YAVAS="yavas_$$"
T_SIK="sik_$$"
T_NADIR="nadir_$$"
T_HIZLI="hizli_$$"
IX_HIC="ix_hic_$$"

# ------------------------------------------------------------ zaman aşımı ---
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman_asimi() {
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
SURE_SQL="${E2E_SLOWLOG_SQL_SURESI:-900}"
SURE_ARAC="${E2E_SLOWLOG_ARAC_SURESI:-900}"

# Ölçüm ARACI asıldıysa sonuç "ürün yanlış cevap verdi" değil "ÖLÇEMEDİK":
# timeout(1) zaman aşımında 124, -k ile öldürmek zorunda kalınca 137 döner.
asildi_mi() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }
docker_yasiyor() { docker ps -q >/dev/null 2>&1; }
sayi_mi() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
ondalik_mi() {
    case "${1:-}" in ''|*[!0-9.]*|*.*.*) return 1 ;; *) return 0 ;; esac
}

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Parola ORTAMA konuyor, komut satırına değil (backup.sh'taki gerekçe:
# `ps` çıktısı sistemdeki herkese açıktır).
PG_C=""; MY_C=""

pg_calistir() {   # pg_calistir <veritabanı> <sql>
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      zaman_asimi "$SURE_SQL" docker exec -e PGPASSWORD "$PG_C" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$1" \
               -v ON_ERROR_STOP=1 -tAq -c "$2" ) 2>>"$E2E_LOG"
}
# Dosyadan çalıştırma: iş yükü yüzlerce cümle ve bunları tek bir -c dizesine
# sığdırmak hem komut satırı sınırına dayanır hem de günlüğü okunmaz kılar.
pg_dosya() {   # pg_dosya <veritabanı> < sql
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      zaman_asimi "$SURE_SQL" docker exec -i -e PGPASSWORD "$PG_C" \
          psql -U "${POSTGRES_USER:-root}" -h 127.0.0.1 -d "$1" \
               -v ON_ERROR_STOP=1 -tAq -f - ) 2>>"$E2E_LOG"
}

my_calistir() {   # my_calistir <sql>
    ( export MYSQL_PWD="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
      zaman_asimi "$SURE_SQL" docker exec -e MYSQL_PWD "$MY_C" \
          mariadb -u root -N -B -e "$1" ) 2>>"$E2E_LOG"
}
# VERİTABANI SEÇİLEREK bağlanmak ŞART: hem performance_schema digest'i hem
# yavaş sorgu günlüğü, sorgunun hangi şemaya ait olduğunu OTURUMUN varsayılan
# veritabanından okur. Şemasız bağlansaydık aracın '--vt' süzgeci hiçbir
# satır bulamaz ve testin tamamı boş listeye bakardı.
my_dosya() {   # my_dosya <veritabanı> < sql
    ( export MYSQL_PWD="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
      zaman_asimi "$SURE_SQL" docker exec -i -e MYSQL_PWD "$MY_C" \
          mariadb -u root -N -B "$1" ) 2>>"$E2E_LOG"
}

# =============================================================================
# ARACI ÇALIŞTIRAN SARMALAYICI
# =============================================================================
# Aracın üç çıktısı ayrı ayrı lazım: çıkış kodu, TAM metin ve SON SATIR
# (JSON). Boru hattında çıkış kodunun kaybolması bu paketlerdeki
# sahte-yeşilin bir numaralı sebebi olduğu için çıktı dosyaya alınıp rc
# ayrıca saklanıyor.
ARAC_RC=0
ARAC_CIKTI="$E2E_TMP/arac.out"
ARAC_JSON="$E2E_TMP/arac.json"
arac_calistir() {   # arac_calistir <etiket> <argümanlar…>
    local ne="$1"; shift
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$ne"
      printf 'komut: %s %s\n' "${ARAC_CAGRI[*]}" "$*"; } >> "$E2E_LOG"
    ARAC_RC=0
    # stdin /dev/null: terminal olmayan ortamda araç hiçbir soru soramasın
    # ve sonsuza kadar asılı kalmasın.
    zaman_asimi "$SURE_ARAC" "${ARAC_CAGRI[@]}" "$@" \
        > "$ARAC_CIKTI" 2>&1 < /dev/null || ARAC_RC=$?
    cat "$ARAC_CIKTI" >> "$E2E_LOG"
    tail -n 1 "$ARAC_CIKTI" > "$ARAC_JSON" 2>/dev/null
    return 0
}

son_ozet() {
    tr -d '\r' < "$ARAC_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' \
        | tail -n 2 | tr '\n' ' '
}

# JSON'dan tek alan. rc=2 → dosya JSON DEĞİL (bu da bir bulgudur, ayrı
# raporlanır); rc=3 → alan yok.
json_alan() {   # json_alan <alan>
    python3 - "$ARAC_JSON" "$1" <<'PY'
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

# queries[] içinde METNİ verilen parçayı taşıyan ilk satır.
# SIRA NUMARASINA DEĞİL METNE bakıyoruz: sıralama değişse de doğru satırı
# buluruz. Çıktı: "<sıra> <çağrı> <toplam_ms> <ortalama_ms>"
# ('sıra' 1'den başlar ve tam olarak listedeki yeridir — sıralama kontrolü
# bu sayıya bakıyor.)
json_sorgu() {   # json_sorgu <metin parçası>
    python3 - "$ARAC_JSON" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
for i, q in enumerate(d.get("queries") or [], start=1):
    if sys.argv[2] in (q.get("query") or ""):
        print(i, q.get("calls"), q.get("total_ms"), q.get("avg_ms"))
        sys.exit(0)
sys.exit(4)
PY
}

json_sorgu_sayisi() {
    python3 - "$ARAC_JSON" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
print(len(d.get("queries") or []))
PY
}

# suggestions[] içinde türü ve nesnesi verilen öneri var mı?
json_oneri_var() {   # json_oneri_var <tür> <nesne parçası>
    python3 - "$ARAC_JSON" "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
for o in (d.get("suggestions") or []):
    if o.get("kind") == sys.argv[2] and sys.argv[3] in (o.get("object") or ""):
        print(o.get("sql") or "")
        sys.exit(0)
sys.exit(4)
PY
}

# İki ondalık sayıyı karşılaştır (bash tam sayı bilir, süreler ondalıklı).
buyuk_mu() {   # buyuk_mu <a> <b> → a > b ise 0
    LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN{exit !(a + 0 > b + 0)}'
}

# =============================================================================
# TEST VERİSİ
# =============================================================================
PG_KURULDU=0
MY_KURULDU=0
# MariaDB'nin DEĞİŞTİRİLEN global ayarları burada saklanır ve sonunda geri
# yazılır. Bir test paketinin ürünün ayarını kalıcı olarak değiştirmesi,
# bir sonraki koşumun neyi ölçtüğünü belirsizleştirir.
MY_ESKI_SLOW=""
MY_ESKI_ESIK=""

pg_veri_kur() {
    pg_calistir postgres "DROP DATABASE IF EXISTS $E2E_DB;" >/dev/null 2>&1
    pg_calistir postgres "CREATE DATABASE $E2E_DB;" >/dev/null || return 1
    PG_KURULDU=1
    # 'bos' sütunu ve üzerindeki indeks BİLEREK hiç sorgulanmıyor: 'oneri'
    # komutunun "kullanılmayan indeks" ölçümünün sınanabilmesi için elimizde
    # kesinlikle kullanılmamış bir indeks olması lazım. Büyük tabloya
    # konuyor, çünkü araç küçük indeksleri (varsayılan 1 MB altı) bilerek
    # eler — küçük bir indeksi silmek kazanç getirmez.
    pg_calistir "$E2E_DB" "
        CREATE TABLE $T_YAVAS (id bigserial PRIMARY KEY,
                               bos int NOT NULL, dolgu text NOT NULL);
        CREATE TABLE $T_NADIR (id bigserial PRIMARY KEY, dolgu text NOT NULL);
        CREATE TABLE $T_SIK   (id bigserial PRIMARY KEY, dolgu text NOT NULL);
        CREATE TABLE $T_HIZLI (id bigserial PRIMARY KEY, dolgu text NOT NULL);
        INSERT INTO $T_YAVAS (bos, dolgu)
             SELECT g, repeat('x', 60) FROM generate_series(1, $SATIR) g;
        INSERT INTO $T_NADIR (dolgu)
             SELECT repeat('y', 60) FROM generate_series(1, $SATIR);
        INSERT INTO $T_SIK (dolgu)
             SELECT repeat('z', 60) FROM generate_series(1, 2000);
        INSERT INTO $T_HIZLI (dolgu)
             SELECT repeat('w', 60) FROM generate_series(1, 100);
        CREATE INDEX $IX_HIC ON $T_YAVAS (bos);
        ANALYZE;" >/dev/null || return 1
    return 0
}

# generate_series yerine İKİYE KATLAMA: MariaDB'nin sequence eklentisi her
# kurulumda etkin değil, ama INSERT … SELECT her sürümde çalışır
# (maintenance.sh e2e'sindeki aynı gerekçe).
my_katla() {   # my_katla <tablo> <kaç kez> <dolgu harfi>
    local t="$1" kez="$2" harf="$3" i sql=""
    my_calistir "INSERT INTO \`$E2E_DB\`.\`$t\` (bos, dolgu)
                 VALUES (1, REPEAT('$harf', 60));" >/dev/null || return 1
    for i in $(seq 1 "$kez"); do
        sql="$sql INSERT INTO \`$E2E_DB\`.\`$t\` (bos, dolgu)
                  SELECT bos, dolgu FROM \`$E2E_DB\`.\`$t\`;"
    done
    my_calistir "$sql" >/dev/null || return 1
    return 0
}

my_veri_kur() {
    my_calistir "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null 2>&1
    my_calistir "CREATE DATABASE \`$E2E_DB\`;" >/dev/null || return 1
    MY_KURULDU=1
    # Dört tablo da AYNI ŞEMADA (bos + dolgu): her biri kendi içinde ikiye
    # katlanarak dolduruluyor, hiçbiri diğerinden OKUNMUYOR. Bu tesadüf
    # değil — ilk yazımda küçük tablolar büyük tablodan SELECT ile
    # dolduruluyordu ve ÖLÇÜMDE PATLADI: InnoDB o taramalar için tablonun
    # en dar indeksini (aşağıdaki 'kullanılmayan' indeksi) seçti, indeks
    # okunmuş sayıldı ve "kullanılmayan indeks" kontrolü BAŞARISIZ oldu.
    # Ölçmek istediğimiz şey aracın doğruluğuydu, testin veri kurulumu
    # değil.
    my_calistir "
        CREATE TABLE \`$E2E_DB\`.\`$T_YAVAS\` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            bos INT NOT NULL,
            dolgu CHAR(60) NOT NULL) ENGINE=InnoDB;
        CREATE TABLE \`$E2E_DB\`.\`$T_NADIR\` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            bos INT NOT NULL,
            dolgu CHAR(60) NOT NULL) ENGINE=InnoDB;
        CREATE TABLE \`$E2E_DB\`.\`$T_SIK\` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            bos INT NOT NULL,
            dolgu CHAR(60) NOT NULL) ENGINE=InnoDB;
        CREATE TABLE \`$E2E_DB\`.\`$T_HIZLI\` (
            id INT AUTO_INCREMENT PRIMARY KEY,
            bos INT NOT NULL,
            dolgu CHAR(60) NOT NULL) ENGINE=InnoDB;" >/dev/null || return 1

    my_katla "$T_YAVAS" "$KAT" x || return 1
    my_katla "$T_NADIR" "$KAT" y || return 1
    my_katla "$T_SIK"   11     z || return 1
    my_katla "$T_HIZLI"  7     w || return 1

    # İNDEKS EN SONDA yaratılıyor: veriyi yüklerken var olsaydı yükleme
    # sırasında okunmuş olabilirdi ve "hiç kullanılmadı" önkoşulu daha
    # başlamadan bozulurdu.
    my_calistir "ALTER TABLE \`$E2E_DB\`.\`$T_YAVAS\`
                   ADD KEY \`$IX_HIC\` (bos);" >/dev/null || return 1
    return 0
}

# --- İŞ YÜKÜ ÜRETİCİ ---------------------------------------------------------
# Cümleleri bir DOSYAYA yazıp tek oturumda koşturuyoruz. Her cümle için ayrı
# `docker exec` çağrılsaydı 400 çağrı dakikalar sürerdi ve ölçtüğümüz şey
# sorgunun değil docker'ın maliyeti olurdu.
yuk_uret() {   # yuk_uret <motor> <dosya>
    local motor="$1" dosya="$2"
    : > "$dosya"
    # MariaDB'de OTURUM eşiği sıfırlanıyor, GLOBAL değil. Sebep: yavaş sorgu
    # günlüğü kaynağı kullanılıyorsa eşiğin altındaki sorgular dosyaya hiç
    # düşmez ve test kendi iş yükünü göremez. Global ayarı değiştirmek
    # yerine oturumda yapmak, üretim trafiğinin günlük davranışını
    # değiştirmiyor.
    [ "$motor" = "mariadb" ] && printf 'SET SESSION long_query_time=0;\n' \
        >> "$dosya"
    python3 - "$dosya" "$T_YAVAS" "$T_SIK" "$T_NADIR" "$T_HIZLI" \
        "$YAVAS_N" "$SIK_N" "$NADIR_N" "$HIZLI_N" <<'PY'
import sys
dosya, yavas, sik, nadir, hizli = sys.argv[1:6]
n_yavas, n_sik, n_nadir, n_hizli = (int(x) for x in sys.argv[6:10])
satirlar = []
satirlar += ["SELECT count(*) FROM %s WHERE dolgu = 'bulunmaz';" % yavas] \
            * n_yavas
satirlar += ["SELECT count(*) FROM %s WHERE dolgu = 'bulunmaz';" % sik] \
            * n_sik
satirlar += ["SELECT count(*) FROM %s WHERE dolgu = 'bulunmaz';" % nadir] \
            * n_nadir
satirlar += ["SELECT dolgu FROM %s WHERE id = 1;" % hizli] * n_hizli
with open(dosya, "a", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(satirlar) + "\n")
PY
}

yuk_kostur() {   # yuk_kostur <motor>
    local dosya="$E2E_TMP/yuk.sql"
    yuk_uret "$1" "$dosya" || return 1
    case "$1" in
        postgresql) pg_dosya "$E2E_DB" < "$dosya" >/dev/null ;;
        mariadb)    my_dosya "$E2E_DB" < "$dosya" >/dev/null ;;
    esac
}

indeks_sayisi() {   # indeks_sayisi <motor>
    case "$1" in
        postgresql)
            pg_calistir "$E2E_DB" \
                "SELECT count(*) FROM pg_indexes
                  WHERE schemaname = 'public';" \
                | tr -d '\r[:blank:]' ;;
        mariadb)
            my_calistir "SELECT COUNT(DISTINCT TABLE_NAME, INDEX_NAME)
                           FROM information_schema.STATISTICS
                          WHERE TABLE_SCHEMA = '$E2E_DB';" \
                | tr -d '\r[:blank:]' ;;
    esac
}

# ---------------------------------------------------------------- temizlik --
# HER DURUMDA çalışır (başarı, hata, Ctrl+C). Bıraktığımız bir veritabanı
# üretim diskinde onlarca MB yer tutar ve kimse ne olduğunu bilmez;
# değiştirilmiş bir global ayar ise bir sonraki koşumun ne ölçtüğünü
# belirsizleştirir.
TEMIZLIK_YAPILDI=0
PG_TEMIZ=""; MY_TEMIZ=""
temizle() {
    [ "$TEMIZLIK_YAPILDI" -eq 1 ] && return 0
    TEMIZLIK_YAPILDI=1
    if [ "$PG_KURULDU" -eq 1 ] && [ -n "$PG_C" ]; then
        # WITH (FORCE) açık bağlantıları koparır (PostgreSQL 13+). Eski
        # sürümde bu söz dizimi hata verir; o yüzden düz DROP'a düşüyoruz.
        pg_calistir postgres "DROP DATABASE IF EXISTS $E2E_DB WITH (FORCE);" \
            >/dev/null 2>&1 \
            || pg_calistir postgres "DROP DATABASE IF EXISTS $E2E_DB;" \
                 >/dev/null 2>&1
        PG_TEMIZ="$(pg_calistir postgres \
            "SELECT count(*) FROM pg_database WHERE datname = '$E2E_DB';" \
            2>/dev/null | tr -d '\r[:blank:]')"
    fi
    if [ "$MY_KURULDU" -eq 1 ] && [ -n "$MY_C" ]; then
        my_calistir "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null 2>&1
        MY_TEMIZ="$(my_calistir "SELECT COUNT(*) FROM
            information_schema.SCHEMATA WHERE SCHEMA_NAME = '$E2E_DB';" \
            2>/dev/null | tr -d '\r[:blank:]')"
    fi
    if [ -n "$MY_C" ] && [ -n "$MY_ESKI_ESIK" ]; then
        my_calistir "SET GLOBAL slow_query_log = $MY_ESKI_SLOW;
                     SET GLOBAL long_query_time = $MY_ESKI_ESIK;" \
            >/dev/null 2>&1
    fi
    rm -rf "$E2E_TMP" 2>/dev/null
    return 0
}
trap 'temizle' EXIT

# =============================================================================
# KONTROLLER — kapsam ve çıkış kodları
# =============================================================================
# Bu üç kontrol docker'a ihtiyaç duymaz (araç motor kapsamını catalog.json'dan
# çözer, docker'a ancak ondan sonra bakar). Bilerek en başta: motorlar
# tamamen kapalıyken bile paket EN AZ BİR ŞEY ölçmüş olur; yoksa "hiçbir
# kontrol çalışmadı" ile "her şey yeşil" ayrımı kaybolurdu.
kontrol_kapsam_disi() {
    local ad="kapsam dışı motor 0 DEĞİL anlamlı bir kod döndürüyor (mongodb)"
    arac_calistir "kapsam dışı motor" durum mongodb
    if asildi_mi "$ARAC_RC"; then
        r_unknown "$ad" "araç $SURE_ARAC sn içinde bitmedi (rc=$ARAC_RC)"
    elif [ "$ARAC_RC" -eq 2 ]; then
        r_ok "$ad — çıkış 2 (kapsam dışı), hata koduyla karışmıyor"
    elif [ "$ARAC_RC" -eq 0 ]; then
        r_fail "$ad" \
            "çıkış 0: ölçümü OLMAYAN bir motor BAŞARILI görünüyor"
    else
        r_fail "$ad" "beklenen çıkış 2, gelen $ARAC_RC: $(son_ozet)"
    fi

    local ad2="kapsam dışı çağrıda da son satır JSON (panel boş görmüyor)"
    local ok_alan kuyruk
    if ! ok_alan="$(json_alan ok)"; then
        kuyruk="$(tail -c 200 "$ARAC_JSON" | tr -d '\r\n')"
        r_fail "$ad2" "son satır geçerli JSON değil: $kuyruk"
    elif [ "$ok_alan" = "false" ]; then
        r_ok "$ad2"
    else
        r_fail "$ad2" "ok=$ok_alan — ölçüm yapılmadığı hâlde olumlu görünüyor"
    fi
}

kontrol_bilinmeyen_motor() {
    local ad="katalogda olmayan motorda anlamlı kod (yokmotor)"
    arac_calistir "bilinmeyen motor" durum yokmotor
    if asildi_mi "$ARAC_RC"; then
        r_unknown "$ad" "araç $SURE_ARAC sn içinde bitmedi (rc=$ARAC_RC)"
    elif [ "$ARAC_RC" -eq 2 ]; then
        r_ok "$ad — çıkış 2"
    elif [ "$ARAC_RC" -eq 0 ]; then
        r_fail "$ad" "çıkış 0 — olmayan bir motor için başarı bildiriliyor"
    else
        r_fail "$ad" "beklenen çıkış 2, gelen $ARAC_RC: $(son_ozet)"
    fi
}

kontrol_motorsuz_kur() {
    # 'kur' hangi motorda çalışacağını TAHMİN ETMEMELİ. Etseydi, tek motor
    # sanıp yanlış sunucuya kalıcı ayar yazma ihtimali doğardı.
    local ad="'kur' motor verilmeden çalışmıyor (tahmin etmiyor)"
    arac_calistir "motorsuz kur" kur
    if [ "$ARAC_RC" -eq 2 ]; then
        r_ok "$ad — çıkış 2"
    else
        r_fail "$ad" "beklenen çıkış 2, gelen $ARAC_RC: $(son_ozet)"
    fi
}

# =============================================================================
# KONTROL — ölçüm KAPALIYKEN ne diyor
# =============================================================================
# Bu, paketin en önemli kontrollerinden biri. Ölçüm kapalıyken boş liste
# basan bir araç, kullanıcıya "sorgularınız hızlı" demiş olur. Beklenen:
# çıkış 4 VE ekranda ölçümü açan komutun kendisi.
kontrol_kapaliyken() {   # kontrol_kapaliyken <motor>
    local motor="$1"
    local ad="[$motor] ölçüm kapalıyken 'durum' boş liste DEĞİL, uyarı basıyor"
    arac_calistir "durum $motor (kur öncesi)" durum "$motor"

    if [ "$ARAC_RC" -eq 0 ]; then
        r_skip "$ad" "ölçüm bu sunucuda zaten açık; kapalı hâli sınanamaz"
        return 0
    fi
    if [ "$ARAC_RC" -ne 4 ]; then
        r_fail "$ad" "beklenen çıkış 4 (ölçüm kapalı), gelen $ARAC_RC:" \
            "$(son_ozet)"
        return 0
    fi
    # Çıkış kodu doğru; şimdi asıl soru: KULLANICI NE OKUYOR?
    if grep -qaF "slowlog.sh kur $motor" "$ARAC_CIKTI"; then
        r_ok "$ad (çıkış 4 ve ekranda 'kur $motor' komutu yazıyor)"
    else
        r_fail "$ad" \
            "çıkış 4 doğru ama ekranda ölçümü AÇAN komut yok; kullanıcı" \
            "ne yapacağını bilemez"
    fi
}

# =============================================================================
# KONTROL — 'kur' sessizce yeniden başlatıyor mu
# =============================================================================
# Ölçüt State.StartedAt: araç container'ı yeniden başlatsaydı bu damga
# değişirdi. Ayrıca hâlâ ÇALIŞIYOR olmalı — durdurulmuş bir container'ın
# StartedAt'i de değişmez, o yüzden ikisine birden bakıyoruz.
damga_al() { docker inspect -f '{{.State.StartedAt}}|{{.State.Running}}' \
             "$1" 2>/dev/null; }

kontrol_kur() {   # kontrol_kur <motor> <container>
    local motor="$1" C="$2" once sonra acik bekliyor
    local ad="[$motor] 'kur' sunucuyu SESSİZCE yeniden başlatmıyor"
    local ad2="[$motor] 'kur' ölçümü açtı ya da ne gerektiğini SÖYLEDİ"

    once="$(damga_al "$C")"
    arac_calistir "kur $motor" kur "$motor"
    sonra="$(damga_al "$C")"

    if asildi_mi "$ARAC_RC"; then
        r_unknown "$ad"  "araç $SURE_ARAC sn içinde bitmedi"
        r_unknown "$ad2" "araç bitmedi"
        return 0
    fi

    if [ -z "$once" ] || [ -z "$sonra" ]; then
        r_unknown "$ad" "$C docker inspect ile okunamadı"
    elif [ "$once" = "$sonra" ]; then
        r_ok "$ad ($C StartedAt değişmedi)"
    else
        r_fail "$ad" \
            "$C yeniden başlatılmış: önce [$once] sonra [$sonra] —" \
            "kesinti kararı kullanıcının olmalıydı"
    fi

    if [ "$ARAC_RC" -ne 0 ]; then
        r_fail "$ad2" "'kur' çıkış $ARAC_RC: $(son_ozet)"
        return 0
    fi
    acik="$(json_alan enabled)"           || acik=""
    bekliyor="$(json_alan pending_restart)" || bekliyor=""
    if [ "$acik" = "true" ]; then
        r_ok "$ad2 (ölçüm açık, yeniden başlatma gerekmedi)"
    elif [ "$bekliyor" = "true" ]; then
        # "Ayar yazdım ama ölçüm başlamadı" AYRI bir hâl ve JSON'da ayrı bir
        # alanla söylenmesi şart: panel bunu "açık" gösterseydi kullanıcı
        # ertesi gün boş listeye bakıp aracın bozulduğunu düşünürdü.
        if grep -qaF "docker compose up -d $motor" "$ARAC_CIKTI"; then
            r_ok "$ad2 (pending_restart=true ve yeniden başlatma komutu" \
                 "ekranda)"
        else
            r_fail "$ad2" \
                "pending_restart=true ama ekranda yeniden başlatma komutu yok"
        fi
    else
        r_fail "$ad2" \
            "enabled=$acik, pending_restart=$bekliyor — 'kur' 0 ile çıktı" \
            "ama ne açtı ne de ne gerektiğini söyledi"
    fi
}

# PostgreSQL'de shared_preload_libraries yeniden başlatma ister. Paket bunu
# KENDİLİĞİNDEN yapmaz; yalnız operatör açıkça istediyse (ortam değişkeni).
yeniden_baslat() {   # yeniden_baslat <container>
    t_info "E2E_SLOWLOG_YENIDEN_BASLAT=1 — $1 yeniden başlatılıyor…"
    docker restart "$1" >>"$E2E_LOG" 2>&1 || return 1
    local i
    for i in $(seq 1 60); do
        pg_calistir postgres "SELECT 1;" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# =============================================================================
# KONTROLLER — asıl ölçüm
# =============================================================================
motor_kontrolleri() {   # motor_kontrolleri <motor>
    local motor="$1"
    local n_gor="[$motor] bilerek pahalı koşturulan sorgu ilk N'de çıkıyor"
    local n_cagri="[$motor] o sorgunun ÇAĞRI SAYISI doğru"
    local n_sira="[$motor] sıralama TOPLAM süreye göre (ortalamaya göre değil)"
    local n_ucuz="[$motor] ucuz ve seyrek sorgu ilk 3'e GİRMİYOR"
    local n_sif="[$motor] 'sifirla' sayaçları gerçekten sıfırlıyor"
    local n_one="[$motor] 'oneri' kullanılmayan indeksi ölçüyor"
    local n_uyg="[$motor] 'oneri' HİÇBİR ÖNERİYİ UYGULAMIYOR"
    local sat_yavas sat_sik sat_nadir
    local r_yavas c_yavas t_yavas_ms o_yavas
    local r_sik c_sik t_sik_ms o_sik
    local r_nadir c_nadir t_nadir_ms o_nadir
    local ix_once ix_sonra komut

    # --- 1) sayaçları temizle, sonra iş yükünü koştur -----------------------
    # Sıfırlama BURADA, ölçümden ÖNCE: tabloları dolduran INSERT'ler
    # dakikalarca CPU harcadı ve listeye onlar çıkardı. Ölçmek istediğimiz
    # şey bizim dört sorgumuzun BİRBİRİNE göre sırası.
    arac_calistir "sifirla $motor (iş yükü öncesi)" \
        sifirla "$motor" --vt "$E2E_DB"
    t_info "$motor: iş yükü koşturuluyor ($YAVAS_N + $SIK_N + $NADIR_N +" \
           "$HIZLI_N sorgu)…"
    if ! yuk_kostur "$motor"; then
        r_unknown "$n_gor"   "iş yükü koşturulamadı (ayrıntı: $E2E_LOG)"
        r_unknown "$n_cagri" "iş yükü koşturulamadı"
        r_unknown "$n_sira"  "iş yükü koşturulamadı"
        r_unknown "$n_ucuz"  "iş yükü koşturulamadı"
        r_unknown "$n_sif"   "iş yükü koşturulamadı"
        r_unknown "$n_one"   "iş yükü koşturulamadı"
        r_unknown "$n_uyg"   "iş yükü koşturulamadı"
        return 0
    fi

    # --- 2) 'durum' listesi --------------------------------------------------
    arac_calistir "durum $motor --vt $E2E_DB" \
        durum "$motor" --vt "$E2E_DB" --adet 20
    if [ "$ARAC_RC" -ne 0 ]; then
        r_unknown "$n_gor"   "'durum' çıkış $ARAC_RC: $(son_ozet)"
        r_unknown "$n_cagri" "'durum' okunamadı"
        r_unknown "$n_sira"  "'durum' okunamadı"
        r_unknown "$n_ucuz"  "'durum' okunamadı"
    else
        sat_yavas="$(json_sorgu "$T_YAVAS")" || sat_yavas=""
        sat_sik="$(json_sorgu   "$T_SIK")"   || sat_sik=""
        sat_nadir="$(json_sorgu "$T_NADIR")" || sat_nadir=""

        if [ -z "$sat_yavas" ]; then
            r_fail "$n_gor" \
                "$YAVAS_N kez koşturulan pahalı sorgu ($T_YAVAS) listede" \
                "YOK — araç en pahalı sorguyu bulamıyor"
            r_unknown "$n_cagri" "sorgu listede yok"
        else
            read -r r_yavas c_yavas t_yavas_ms o_yavas <<< "$sat_yavas"
            r_ok "$n_gor (sıra $r_yavas, toplam $t_yavas_ms ms)"
            if [ "$c_yavas" = "$YAVAS_N" ]; then
                r_ok "$n_cagri ($YAVAS_N koşum, $c_yavas sayıldı)"
            else
                r_fail "$n_cagri" \
                    "$YAVAS_N kez koşturuldu, araç $c_yavas diyor"
            fi
        fi

        # --- SIRALAMA: asıl ayırt edici kontrol ------------------------------
        if [ -z "$sat_sik" ] || [ -z "$sat_nadir" ]; then
            r_unknown "$n_sira" \
                "karşılaştırılacak iki sorgudan biri listede yok"
        else
            read -r r_sik   c_sik   t_sik_ms   o_sik   <<< "$sat_sik"
            read -r r_nadir c_nadir t_nadir_ms o_nadir <<< "$sat_nadir"
            # ÖNCE ÖNKOŞULU DOĞRULA. Testin ayırt edici olması için 'sik'in
            # toplamı BÜYÜK ama ortalaması KÜÇÜK olmalı. Bu makinede öyle
            # çıkmadıysa test sıralamayı sınayamaz; "geçti" demek yanlış
            # olur, "başarısız" demek de.
            if ! buyuk_mu "$t_sik_ms" "$t_nadir_ms" \
               || ! buyuk_mu "$o_nadir" "$o_sik"; then
                r_unknown "$n_sira" \
                    "ayırt edici önkoşul oluşmadı: sik(toplam $t_sik_ms," \
                    "ort $o_sik) / nadir(toplam $t_nadir_ms, ort $o_nadir)"
            elif [ "$r_sik" -lt "$r_nadir" ]; then
                r_ok "$n_sira (sik sıra $r_sik: toplam $t_sik_ms ms /" \
                     "ort $o_sik ms — nadir sıra $r_nadir: toplam" \
                     "$t_nadir_ms ms / ort $o_nadir ms)"
            else
                r_fail "$n_sira" \
                    "ORTALAMAYA göre sıralanmış: ortalaması $o_nadir ms" \
                    "olan sorgu (toplam $t_nadir_ms ms) sıra $r_nadir'de," \
                    "toplamı $t_sik_ms ms olan sorgu sıra $r_sik'te"
            fi
        fi
    fi

    # --- 3) ucuz sorgu ilk 3'e girmemeli ------------------------------------
    arac_calistir "durum $motor --adet 3" \
        durum "$motor" --vt "$E2E_DB" --adet 3
    if [ "$ARAC_RC" -ne 0 ]; then
        r_unknown "$n_ucuz" "'durum --adet 3' çıkış $ARAC_RC"
    elif json_sorgu "$T_HIZLI" >/dev/null 2>&1; then
        r_fail "$n_ucuz" \
            "$HIZLI_N kez koşan birincil anahtar sorgusu ilk 3'te —" \
            "liste maliyete göre sıralanmıyor"
    elif json_sorgu "$T_YAVAS" >/dev/null 2>&1; then
        r_ok "$n_ucuz (ilk 3'te pahalı sorgu var, ucuz sorgu yok)"
    else
        # Ucuz sorgu yok ama pahalı sorgu da yok: liste bambaşka. Bu
        # "geçti" değil, "ölçemedik".
        r_unknown "$n_ucuz" "ilk 3'te bizim sorgularımızdan hiçbiri yok"
    fi

    # --- 4) 'oneri' ---------------------------------------------------------
    # İKİ AYRI SORU: (a) ölçtüğünü buluyor mu, (b) bulduğunu UYGULUYOR mu.
    # (b) bu betiğin en sert sözü: "öneriyi uygulamam". Sözün tutulduğunu
    # indeks sayısını önce ve sonra sayarak kanıtlıyoruz.
    ix_once="$(indeks_sayisi "$motor")"
    arac_calistir "oneri $motor" oneri "$motor" --vt "$E2E_DB"
    ix_sonra="$(indeks_sayisi "$motor")"

    if [ "$ARAC_RC" -ne 0 ]; then
        r_unknown "$n_one" "'oneri' çıkış $ARAC_RC: $(son_ozet)"
    elif komut="$(json_oneri_var kullanilmayan-indeks "$IX_HIC")"; then
        r_ok "$n_one (hiç kullanılmayan $IX_HIC bulundu: $komut)"
    else
        # Öneri çıkmadıysa iki ihtimal var ve ayırmak şart: ya araç
        # ölçemedi (bulgu), ya da bu motorda o sayaç yok
        # (performance_schema kapalı → meşru).
        if grep -qaF "performance_schema kapalı" "$ARAC_CIKTI"; then
            r_skip "$n_one" \
                "performance_schema kapalı — indeks kullanım sayacı yok"
        else
            r_fail "$n_one" \
                "hiç kullanılmayan $IX_HIC indeksi önerilerde YOK"
        fi
    fi

    if ! sayi_mi "${ix_once:-}" || ! sayi_mi "${ix_sonra:-}"; then
        r_unknown "$n_uyg" "indeks sayısı okunamadı"
    elif [ "$ix_once" -ne "$ix_sonra" ]; then
        r_fail "$n_uyg" \
            "'oneri' indeks sayısını değiştirdi: $ix_once → $ix_sonra —" \
            "yalnız yazması gereken komutu ÇALIŞTIRMIŞ"
    elif grep -qaF "ÇALIŞTIRILMADI" "$ARAC_CIKTI"; then
        r_ok "$n_uyg ($ix_once indeks önce, $ix_sonra sonra; ekranda da" \
             "uygulanmadığı yazıyor)"
    else
        r_fail "$n_uyg" \
            "indeks sayısı değişmedi ama ekranda 'uygulanmadı' uyarısı yok"
    fi

    # --- 5) 'sifirla' --------------------------------------------------------
    # EN SONDA, çünkü yukarıdaki bütün kontroller bu sayaçları okuyor.
    arac_calistir "sifirla $motor" sifirla "$motor" --vt "$E2E_DB"
    if [ "$ARAC_RC" -ne 0 ]; then
        r_fail "$n_sif" "'sifirla' çıkış $ARAC_RC: $(son_ozet)"
    else
        arac_calistir "durum $motor (sıfırlama sonrası)" \
            durum "$motor" --vt "$E2E_DB" --adet 20
        if [ "$ARAC_RC" -ne 0 ]; then
            r_unknown "$n_sif" "sıfırlama sonrası 'durum' çıkış $ARAC_RC"
        elif json_sorgu "$T_YAVAS" >/dev/null 2>&1; then
            sat_yavas="$(json_sorgu "$T_YAVAS")"
            r_fail "$n_sif" \
                "sıfırlamadan sonra sorgu hâlâ listede: $sat_yavas"
        else
            r_ok "$n_sif ($(json_sorgu_sayisi) sorgu kaldı, bizimki yok)"
        fi
    fi
    return 0
}

# =============================================================================
# KONTROL — üretime dokunulmadı
# =============================================================================
kontrol_dokunulmadi() {   # <ad> <container> <önceki damga>
    local ad="$1" C="$2" once="$3" sonra
    if [ -z "$once" ]; then
        r_skip "$ad" "$C bu koşumun başında çalışmıyordu"
        return 0
    fi
    sonra="$(damga_al "$C")"
    if [ -z "$sonra" ]; then
        r_unknown "$ad" "$C artık docker inspect ile okunamıyor"
    elif [ "$once" = "$sonra" ]; then
        r_ok "$ad ($C, StartedAt değişmedi)"
    else
        r_fail "$ad" "$C durumu değişti: önce [$once] sonra [$sonra]"
    fi
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
BASLANGIC="$(date +%s)"
heading "E2E yavaş sorgu ölçümü — $(date '+%Y-%m-%d %H:%M')"
[ -f "$ARAC" ] || die "$ARAC yok — bu paket onu sınamak için var."
[ -x "$ARAC" ] || t_info "$ARAC çalıştırma izni yok; 'bash' ile çağrılacak."
t_info "günlük: $E2E_LOG"

t_head "Kapsam ve çıkış kodları"
kontrol_kapsam_disi
kontrol_bilinmeyen_motor
kontrol_motorsuz_kur

SECILEN="${1:-mariadb postgresql}"
case "$SECILEN" in
    mariadb|postgresql|"mariadb postgresql") ;;
    *) die "Bu pakette yalnız mariadb ve postgresql sınanır: $SECILEN" ;;
esac

t_head "Ölç → gör → sırala → sıfırla"
if ! docker_yasiyor; then
    r_unknown "iş yükü koşturuldu ve ölçüldü" "docker cevap vermiyor"
else
    OLCULEN=0
    for M in $SECILEN; do
        C="$(primary_of "$M")"
        if ! container_running "$C"; then
            r_skip "[$M] iş yükü koşturuldu ve ölçüldü" \
                   "$M kapalı (container: $C)"
            continue
        fi
        case "$M" in
            postgresql) PG_C="$C" ;;
            mariadb)
                MY_C="$C"
                # Değiştireceğimiz global ayarları ÖNCE okuyoruz; temizlikte
                # geri yazılacaklar.
                MY_ESKI_SLOW="$(my_calistir \
                    "SELECT @@global.slow_query_log;" | tr -d '\r[:blank:]')"
                MY_ESKI_ESIK="$(my_calistir \
                    "SELECT @@global.long_query_time;" \
                    | tr -d '\r[:blank:]')"
                case "$MY_ESKI_SLOW" in
                    ON|on|1) MY_ESKI_SLOW=1 ;;
                    *)       MY_ESKI_SLOW=0 ;;
                esac
                ;;
        esac
        DAMGA="$(damga_al "$C")"

        t_head "$M — $E2E_DB"
        kontrol_kapaliyken "$M"
        kontrol_kur "$M" "$C"

        # Ölçüm hâlâ kapalıysa (PostgreSQL'de yeniden başlatma bekliyor)
        # asıl kontroller koşamaz. SESSİZCE ATLAMIYORUZ: sebebi ve çözümü
        # yazılıyor, lib.sh de bunu "eksik kapsam" olarak sayıyor.
        arac_calistir "durum $M (kur sonrası)" durum "$M"
        if [ "$ARAC_RC" -eq 4 ] && [ "$M" = "postgresql" ] \
           && [ "$YENIDEN" = "1" ]; then
            if yeniden_baslat "$C"; then
                DAMGA="$(damga_al "$C")"   # kasıtlı yeniden başlatma
                arac_calistir "kur $M (yeniden başlatmadan sonra)" kur "$M"
                arac_calistir "durum $M" durum "$M"
            else
                t_info "$C yeniden başlatılamadı."
            fi
        fi

        if [ "$ARAC_RC" -eq 4 ]; then
            r_skip "[$M] iş yükü ölçüldü" \
                "ölçüm hâlâ kapalı. PostgreSQL'de shared_preload_libraries" \
                "yeniden başlatma ister: 'docker compose up -d $M' koşup" \
                "bu paketi tekrar çalıştırın (ya da" \
                "E2E_SLOWLOG_YENIDEN_BASLAT=1 verin)."
            kontrol_dokunulmadi "[$M] üretim container'ına dokunulmadı" \
                                "$C" "$DAMGA"
            continue
        fi

        KURULDU=1
        t_info "$M: test verisi kuruluyor…"
        case "$M" in
            postgresql) pg_veri_kur || KURULDU=0 ;;
            mariadb)    my_veri_kur || KURULDU=0 ;;
        esac
        if [ "$KURULDU" -ne 1 ]; then
            r_unknown "[$M] test verisi kurulamadı" \
                      "geçici veritabanı yaratılamadı (ayrıntı: $E2E_LOG)"
            continue
        fi
        motor_kontrolleri "$M"
        kontrol_dokunulmadi "[$M] üretim container'ına dokunulmadı" \
                            "$C" "$DAMGA"
        OLCULEN=$((OLCULEN + 1))
    done
    [ "$OLCULEN" -eq 0 ] && t_info "hiçbir motorda ölçüm koşturulamadı"
fi

# =============================================================================
# TEMİZLİK — testin kendi ürettiğini geri alması
# =============================================================================
# Bu kontrol paketin en sonunda, çünkü ölçtüğü şey testin KENDİ davranışı:
# ürettiği veritabanını gerçekten sildi mi. Silmeseydi üretim diskinde
# onlarca MB'lık, adı 'e2e_' ile başlayan bir kalıntı kalır ve bir sonraki
# 'durum' onun sorgularını üretim sorgusu sanıp listelerdi.
t_head "Temizlik"
temizle
if [ "$PG_KURULDU" -eq 1 ]; then
    case "$PG_TEMIZ" in
        0)  r_ok "[postgresql] test veritabanı ($E2E_DB) silindi" ;;
        '') r_unknown "[postgresql] test veritabanı silindi" \
                      "silinip silinmediği doğrulanamadı" ;;
        *)  r_fail "[postgresql] test veritabanı silindi" \
                  "$E2E_DB hâlâ duruyor — elle silin: DROP DATABASE $E2E_DB" ;;
    esac
fi
if [ "$MY_KURULDU" -eq 1 ]; then
    case "$MY_TEMIZ" in
        0)  r_ok "[mariadb] test veritabanı ($E2E_DB) silindi" ;;
        '') r_unknown "[mariadb] test veritabanı silindi" \
                      "silinip silinmediği doğrulanamadı" ;;
        *)  r_fail "[mariadb] test veritabanı silindi" \
                  "$E2E_DB hâlâ duruyor — elle silin: DROP DATABASE $E2E_DB" ;;
    esac
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
