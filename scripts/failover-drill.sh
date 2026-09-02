#!/bin/bash
# =============================================================================
# databases-stack — DEVİR PROVASI (failover drill)
# =============================================================================
#   ./scripts/failover-drill.sh <motor> [--onayla]
#
# NEDEN VAR:
# Ürün devir yapabiliyor: scripts/failover/*.sh yedeği yükseltiyor, controller
# eski ana kopyayı fence edip yönlendirme tablosunu yeniden yazıyor, panel
# "otomatik devir açık" rozetini gösteriyor. Ölçülmemiş TEK şey bunların
# toplamı: UYGULAMANIN KAÇ SANİYE YAZAMADIĞI. "HA var" bir yapılandırma
# cümlesidir; "geçen hafta 6,4 saniyede devrettik ve tek satır kaybetmedik"
# bir ölçümdür. Bu betik ikincisini üretir.
#
# restore-drill.sh'ın İKİZİ — ama bir yeri BİLEREK terstir:
#   • restore-drill geçici container'ı '--network none' ile açar: üretime
#     dokunamayacağını niyete değil çekirdeğe onaylatır.
#   • bu prova sonda container'ını yığın ağına BAĞLAR ve yazmayı GATEWAY
#     portundan yapar. Ölçtüğümüz sayı yalnız orada vardır: doğrudan
#     container'a bağlanan bir ölçüm nginx'in yeniden yüklenmesini ve stream
#     resolver'ın DNS önbelleğini (gateway/nginx.conf: valid=10s) atlar; yani
#     uygulamanın yaşamadığı, gerçekte olmayan bir "kesinti" basar.
#
# BU PROVA GERÇEK BİR DEVİRDİR. Kuru koşum değildir, taklit değildir: ana
# kopya gerçekten durdurulur, yedek gerçekten yükseltilir ve roller KALICI
# olarak yer değiştirir. Bu yüzden --onayla verilmeden DEVİR YAPILMAZ:
# ön koşullar ölçülür, ne olacağı yazılır ve çıkılır (çıkış 5).
# ONAYSIZ KOŞUM DA VERİTABANINA DOKUNUR — ve bunu saklamıyoruz: tek
# satırlık bir kanıt kaydı yazılır, gateway'den geri okunur, yedek kopyada
# aranır ve sonunda SİLİNİR. Sebebi, "prova yapılabilir mi" sorusunun
# okuma ile cevaplanamamasıdır: replikasyonun aktığını ancak yazdığımız
# bir satırın öbür uçta belirmesi kanıtlar. Ana kopyaya (durdurma,
# yükseltme, yönlendirme) DOKUNULMAZ.
#
# KESİNTİ SÜRESİ TAM OLARAK NASIL ÖLÇÜLÜYOR:
# Sonda container'ı prova boyunca gateway portuna sürekli tek satır yazar ve
# her denemenin BİTİŞ anını damgalar.
#     T0 = kesintiden ÖNCEKİ son BAŞARILI yazmanın bittiği an
#     T1 = kesintiden SONRAKİ ilk BAŞARILI yazmanın bittiği an
#     KESİNTİ = T1 − T0
# İkisi de yazmanın çalıştığını KANITLADIĞIMIZ anlardır; aradaki her şey
# kanıtlayamadığımız aralıktır. Bu tanım gerçek kesintiyi asla OLDUĞUNDAN
# KISA göstermez — en fazla bir yoklama aralığı kadar UZUN gösterir. Ürünü
# kayıran yönde yanılmayan bir sayı, kayıran yönde yanılan bir sayıdan
# kıyaslanamayacak kadar değerlidir. Ölçülen çözünürlük (kesinti penceresinde
# art arda iki yoklama arasındaki en büyük boşluk) detail'e yazılır.
#
# ZAMAN KAYNAĞI date DEĞİL /proc/uptime: NTP düzeltmesi prova ortasında saati
# geriye alabilir; o hâlde kesinti negatif ya da dakikalarca çıkar ve rapor
# sessizce saçmalar. /proc/uptime monotondur ve her Linux container'ında
# vardır. Damgalar SONDA CONTAINER'ININ İÇİNDEN alınır — host saatiyle
# container saatini karşılaştırmıyoruz; time namespace kullanan bir çalışma
# zamanında o karşılaştırma sessizce yanlış olurdu.
#
# YOKLAMA DÖNGÜSÜ CONTAINER'IN İÇİNDE, HOST'TA DEĞİL: her yoklama için
# 'docker exec' çağırsaydık ölçüm tam da docker daemon'ın en meşgul olduğu
# ana denk gelirdi (container durdurma + yükseltme + controller'ın exporter'ı
# --force-recreate ile yeniden yaratması hep o pencerede olur). O hâlde
# ölçtüğümüz şey veritabanının erişilebilirliği değil daemon'ın gecikmesi
# olurdu. Döngü içeride koşar; host yalnız başlatır ve sonunda logu okur.
#
# DEVRİ KİM TETİKLİYOR: controller'ın kendi devir işi (POST
# /api/engines/<id>/failover). Ana kopyayı biz 'docker kill' ile düşürmüyoruz.
# Üç sebep:
#   1) Fence'i ürünün kendisi yapar (docker stop -t 15) — ölçtüğümüz şey
#      ürünün gerçek devri olur, bizim taklidimiz değil.
#   2) Yedek yükseltmeye hazır değilse controller ANA KOPYAYA DOKUNMADAN
#      reddeder. Üretimde koşan bir prova için bu, elimizdeki en değerli
#      güvenlik özelliğidir.
#   3) Yönlendirme tablosunu ve nginx reload'ı yalnız controller yapar;
#      betikleri elle çağıran bir prova "aynı adres" vaadini hiç ölçmemiş
#      olurdu.
# BEDELİ AÇIKÇA SÖYLENİR: ölçülen süre PLANLI devrin kesintisidir. Ana kopya
# kendiliğinden ölürse buna denetleyicinin tespit süresi eklenir
# (FAILOVER_STRIKES × FAILOVER_INTERVAL, varsayılan 3 × 10 = 30 sn). O sayı
# yapılandırmadan OKUNUR, ölçülmez; raporda ikisi karıştırılmaz.
#
# VERİ KAYBI NASIL ÖLÇÜLÜYOR — iki ayrı satırla:
#   • KANIT SATIRI: devirden önce gateway'den yazılır, gateway'den geri
#     okunur (COMMIT edildi) ve YEDEK KOPYANIN İÇİNDEN okunur (replikasyon
#     gerçekten aktı). Devirden sonra yeni ana kopyada duruyor mu?
#   • SON YAZMA: kesinti başlamadan hemen önce başarıyla yazılan son sonda
#     satırı. Kanıt satırı tek başına ZAYIF bir ölçüttür — yükseltilen düğümde
#     zaten vardır. Asıl soru devir ANINDA yazılmış son satırın hayatta kalıp
#     kalmadığıdır; asenkron replikasyonun kayıp penceresi tam orasıdır.
#   İkisinden biri kaybolduysa data_loss=true olur. "Onaylanmış bir yazma
#   kayboldu" ile "hiçbir şey kaybolmadı" arasındaki farkı yumuşatmıyoruz.
#
# ÇIKIŞ KODLARI (kapsam dışı, ölçüm yokluğu ve gerçek arıza AYRI):
#   0  prova geçti — devredildi, kesinti ölçüldü, onaylanmış veri kaybı yok
#   1  prova DÜŞTÜ — devir olmadı, veri kayboldu ya da kesinti üst sınırı aştı
#   2  KAPSAM DIŞI — bu motorda denetlenen devir yok (ya da motor tanınmıyor)
#   3  ÖLÇÜLEMEDİ — ön koşul yok (replikasyon akmıyor), docker/controller yok,
#      kilit başkasında… Prova hiç YAPILAMADI; "HA bozuk" demek DEĞİLDİR.
#   4  prova bitti ama TEMİZLİK yapılamadı — sonda container'ı ya da prova
#      tablosu kaldı (restore-drill.sh'taki 4 ile aynı anlam).
#   5  ONAY YOK — ön koşullar ölçüldü, plan basıldı, DEVİR YAPILMADI.
#
# SON SATIR HER ZAMAN TEK SATIR JSON'DUR (controller/panel bunu okur):
#   {"engine":…,"ok":…,"downtime_seconds":…,"data_loss":…,"new_primary":…,
#    "detail":"…"}
# downtime_seconds ÖLÇEMEDİĞİMİZDE null'dur, 0 DEĞİL. restore-drill.sh'ta
# seconds hiç null olmaz ve ölçülemeyince 0 basılır; orada 0 "geri gelmedi"
# demektir, yanlış anlaşılmaz. BURADA TAM TERSİ: 0 saniye kesinti,
# ölçülebilecek EN İYİ sonuçtur. Ölçemediğimizde 0 basmak, hiç devretmemiş
# bir yığını "kesintisiz devretti" diye belgelemek olurdu — bu paketin
# engellemeye çalıştığı yalanın en pahalı biçimi. data_loss da aynı sebeple
# üç değerlidir: true / false / null (ölçemedik).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3
source scripts/lib/common.sh
load_env

# printf '%.2f' ondalık ayıracı YERELDEN gelir: tr_TR.UTF-8 bir kabukta
# "6,42" basar ve bastığımız son satır JSON olmaktan çıkar — controller onu
# ayrıştıramaz, prova hiç koşmamış sayılır. LC_ALL=C bunu sabitler; Türkçe
# metinler UTF-8 bayt olarak basıldığı için bundan etkilenmez.
export LC_ALL=C
export PYTHONIOENCODING=utf-8

LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
LOG_FILE="$LOG_DIR/failover-drill_$(date +%Y%m%d).log"
mkdir -p "$LOG_DIR"
# Günlük dosyası GÜN ADIYLA açılır ve ona hem controller (container'da
# root) hem de buradaki kullanıcı yazar. İlk yazan sahibi olur; mod
# açılmazsa ikinci yazan o gün boyunca hiç çalışamaz.
paylasilan_dosya "$LOG_FILE"

# Etiket çöp toplamak içindir: yarıda ölen bir provanın (kill -9, host yeniden
# başladı) sonda container'ı ADIYLA aranamaz — adında o koşumun PID'i var.
# Etiket sabittir, sonraki koşum kalıntıyı ondan bulur.
ETIKET="dbstack-ha-prova"

KILIT="$STACK_ROOT/state/backup.lock"

# Prova verisi. SQL motorlarında tek tablo, Redis'te tek hash: temizlik tek
# komuta iner. Kanıt satırı ile sonda satırları AYNI kapta durur — ayrı
# kaplar, "hangisi replike oldu" sorusunu gereksiz yere ikiye bölerdi.
TABLO="ha_prova"
REDIS_ANAHTAR="dbstack:ha-prova"

# Sonda container'ının içindeki yoklama günlüğü.
SONDA_LOG="/tmp/ha-yoklama.log"

# ---------------------------------------------------------------- günlük ---
dlog() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
dok()  { ok  "$*"; printf '[%s] [OK] %s\n'  "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }
derr() { err "$*"; printf '[%s] [ERR] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

# ------------------------------------------------------------ zaman aşımı ---
# Hiçbir bekleme sonsuz değil: askıda kalmış bir prova hem "sürüyor" görünür
# hem de yedekleme kilidini tutup gece yedeğini öldürür.
ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman() {   # zaman <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}
SURE_SORGU="${HA_SORGU_SURESI:-60}"

# ------------------------------------------------------------ ayarlanabilir -
# Yoklama aralığı ÇÖZÜNÜRLÜKTÜR: ölçtüğümüz kesinti en fazla bu kadar uzun
# görünebilir. 0,2 sn'de bir yazmak 6 saniyelik bir devirde ~%3 belirsizlik
# demektir; daha sık yoklamak üretim veritabanına daha çok yük bindirmekten
# başka bir şey kazandırmaz.
YOKLAMA_ARALIGI="${HA_YOKLAMA_ARALIGI:-0.2}"
# Tek bir yoklamanın sert üst sınırı (sn). Sonda betiğindeki gerekçeye
# bakın: asılı kalan bir yoklama, ölçümün çözünürlüğünü olduğu gibi
# yutar.
YOKLAMA_TAVANI="${HA_YOKLAMA_TAVANI:-3}"
# Sonda kendi ömrünü kendisi bitirir: betik kill -9 yese bile container'ın
# içinde sonsuza kadar üretime yazan bir döngü kalmasın.
SONDA_OMRU="${HA_SONDA_OMRU:-1800}"
# Controller'ın devir işi için üst sınır. Yükseltme betiğinin controller
# tarafındaki tavanı 600 sn; ondan kısa bir sınır, ürün hâlâ çalışırken
# "devir olmadı" demek olurdu.
DEVIR_TO="${HA_DEVIR_TIMEOUT:-660}"
# Kanıt satırının yedeğe akması için üst sınır. Sağlıklı bir kurulumda gecikme
# milisaniyelerle ölçülür; akmıyorsa prova zaten YAPILAMAZ.
AKIS_TO="${HA_AKIS_TIMEOUT:-60}"

# KESİNTİ ÜST SINIRI — bir HEDEF değil, ALARM eşiğidir. Bunun üstü artık
# "devir çalışıyor ama yavaş" değil "bir yerde takıldı" demektir. Sabit sayı
# yazmıyoruz; ürünün kendi zaman aşımlarının toplamı:
#   fence       15 sn — controller'ın kendi değeri (docker stop -t 15)
#   yükseltme   60 sn — MariaDB relay log'un boşalmasını 30 sn bekler;
#                       PostgreSQL'in promote yoklaması 120 sn'lik bir TAVANA
#                       sahiptir (beklenen değer değil, tavan); Redis ~1 sn.
#                       60 sn üçünü de rahat kapsar.
#   yönlendirme 15 sn — nginx reload + stream resolver'ın DNS önbelleği
#                       (valid=10s): yeni hedefin çözülmesi bu kadar gecikir.
YUKSELTME_TAVANI="${HA_YUKSELTME_TAVANI:-60}"
YONLENDIRME_TAVANI="${HA_YONLENDIRME_TAVANI:-15}"
FENCE_TAVANI="${HA_FENCE_TAVANI:-15}"
TAVAN="${HA_KESINTI_TAVANI:-$(( FENCE_TAVANI + YUKSELTME_TAVANI + YONLENDIRME_TAVANI ))}"
# Toparlanmayı TAVAN'dan UZUN bekliyoruz. Tam tavanda pes etseydik üst sınırı
# aşan bir devir "çok yavaş" (ölçüm, çıkış 1) yerine "ölçülemedi" (çıkış 3)
# diye raporlanırdı — yani ürünün en kötü hâli, ölçüm yokluğuna benzetilip
# yumuşatılmış olurdu.
TOPARLANMA_TO="${HA_TOPARLANMA_TIMEOUT:-$(( TAVAN + 120 ))}"

# Denetleyicinin tespit süresi — ÖLÇÜLMEZ, yapılandırmadan okunur. Planlı
# devirde bu süre yoktur; plansız devirde (ana kopya kendiliğinden ölür)
# kesintinin başına eklenir. Raporda ikisi karıştırılmaz.
VURUS="${FAILOVER_STRIKES:-3}"
ARALIK="${FAILOVER_INTERVAL:-10}"
TESPIT=$(( VURUS * ARALIK ))

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
# Boş değer JSON'da null olmalı, "" değil: adı boş bir string olan yeni ana
# kopya, panelde "adsız bir container'a devredildi" gibi görünürdü.
js_ya_da_null() {
    if [ -n "${1:-}" ]; then js "$1"; else printf 'null'; fi
}

MOTOR=""
ONAY=0
OK=false
KESINTI=null
KAYIP=null
YENI_ANA=""
DETAY="prova başlatılmadı"
JSON_BASILDI=0
TEMIZ=true

json_bas() {
    [ "$JSON_BASILDI" -eq 1 ] && return 0
    JSON_BASILDI=1
    printf '{"engine":%s,"ok":%s,"downtime_seconds":%s,"data_loss":%s,"new_primary":%s,"detail":%s}\n' \
        "$(js "$MOTOR")" "$OK" "$KESINTI" "$KAYIP" \
        "$(js_ya_da_null "$YENI_ANA")" "$(js "$DETAY")"
}

# =============================================================================
# TEMİZLİK
# =============================================================================
SONDA_C=""          # sonda container'ının adı
GECICI=""           # host'taki geçici dizin
PROVA_VERISI=0      # prova tablosu/anahtarı yaratıldı mı
TEMIZ_YAPILDI=0

# Prova verisi ÜRETİM veritabanında durur (başka türlü gateway'den
# yazılamazdı). Bırakırsak kullanıcının şemasında bizim çöpümüz kalır;
# üstelik bir sonraki koşum eski satırları görüp yanlış "son yazma" hesaplar.
# Silme GATEWAY'den değil DÜĞÜMÜN İÇİNDEN yapılır: bu iş temizliktir, ölçüm
# değil — gateway o an yeniden yükleniyorsa temizliğin de onun kaderine
# ortak olması için bir sebep yok.
prova_verisini_sil() {
    [ "$PROVA_VERISI" -eq 1 ] || return 0
    local c; c="$(primary_of "$MOTOR")"
    container_running "$c" || return 1
    case "$MOTOR" in
        mariadb|postgresql)
            dugum_sorgu "$c" "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1 ;;
        redis)
            dugum_sorgu "$c" DEL "$REDIS_ANAHTAR" >/dev/null 2>&1 ;;
        *)  return 1 ;;
    esac
}

# HER DURUMDA çalışır (başarı, hata, Ctrl+C). Sessizce sızdırmak yasak:
# silinemeyen her şey ADIYLA hem ekrana hem JSON'a yazılır.
#
# SIRA ÖNEMLİ: ÖNCE sonda susturulur, SONRA prova verisi silinir. Ters sırada
# sonda hâlâ yazıyor olurdu: Redis'te sildiğimiz hash bir sonraki HSET ile
# yeniden doğar (yani "temizledim" derken temizlememiş oluruz), SQL tarafında
# ise açık istemci bağlantıları DROP TABLE'ı meta veri kilidinde bekletir.
temizle() {
    [ "$TEMIZ_YAPILDI" -eq 1 ] && return 0
    TEMIZ_YAPILDI=1
    local kalan=""
    if [ -n "$SONDA_C" ] && docker inspect "$SONDA_C" >/dev/null 2>&1; then
        docker rm -f "$SONDA_C" >>"$LOG_FILE" 2>&1
        docker inspect "$SONDA_C" >/dev/null 2>&1 \
            && kalan="${kalan:+$kalan, }container:$SONDA_C"
    fi
    if ! prova_verisini_sil; then
        kalan="${kalan:+$kalan, }prova verisi ($TABLO / $REDIS_ANAHTAR)"
    fi
    [ -n "$GECICI" ] && rm -rf "$GECICI" 2>/dev/null
    if [ -n "$kalan" ]; then
        TEMIZ=false
        derr "TEMİZLİK YAPILAMADI — geriye kalanlar: $kalan"
        [ -n "$SONDA_C" ] && derr "  Elle silin:  docker rm -f $SONDA_C"
        DETAY="$DETAY | TEMİZLİK YAPILAMADI: $kalan"
        return 1
    fi
    return 0
}

# Beklenmedik çıkışta da (kabuk hatası, Ctrl+C) temizlik ve JSON şart:
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
# Ctrl+C bir devri GERİ ALMAZ: fence edilmiş bir ana kopya kesintiyle geri
# gelmez, yükseltilmiş bir yedek kendiliğinden replikaya dönmez. Bu yüzden
# kesilme mesajı "iptal edildi" demez, nereye bakılacağını söyler.
trap 'DETAY="prova kullanıcı tarafından kesildi (Ctrl+C) — devir başlamış olabilir; ./stack.sh failover status ile bakın"; exit 130' INT TERM

bitir() {   # bitir <çıkış kodu>
    local kod="$1"
    if ! temizle; then [ "$kod" -eq 0 ] && kod=4; fi
    json_bas
    exit "$kod"
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
prova_dustu() { # devir olmadı / veri kayboldu / çok yavaş — ASIL bulgu budur
    derr "$*"
    OK=false
    DETAY="$*"
    bitir 1
}

# =============================================================================
# KAPSAM
# =============================================================================
# Motor listesi SABİT YAZILMIYOR; ölçüt üç taraflı:
#   1) katalog "failover.supported" diyor mu,
#   2) mod "supervised" mi — yani devri CONTROLLER mı yapıyor (MongoDB kendi
#      seçimini yapar: orada durdurulacak/ölçülecek bir controller devri yok),
#   3) yükseltme betiği gerçekten var mı.
# Sabit liste yazsaydık, eklenen bir motor sessizce kapsam dışında kalırdı.
kat() {   # kat <motor> <python ifadesi>
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e: sys.exit(1)
v = eval(sys.argv[3], {"e": e[0]})
sys.stdout.write("" if v is None else str(v))' "$CATALOG" "$1" "$2" 2>/dev/null \
    | tr -d '\r'
}

# tr -d '\r' ŞART. python3'ün print'i Windows'ta CRLF yazar ve depo Windows'ta
# düzenleniyor; \r taşıyan bir motor kimliği hiçbir karşılaştırmaya uymaz ve
# betik "bu motorda prova yapılamıyor" deyip sessizce çıkardı.
katalog_motorlari() {
    catalog_query '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"]))' | tr -d '\r'
}

katalogda_var() {
    local eid
    for eid in $(katalog_motorlari); do
        [ "$eid" = "$1" ] && return 0
    done
    return 1
}

prova_uygulandi() {   # bu betikte o motorun sorgu yolu yazılmış mı
    case "$1" in mariadb|postgresql|redis) return 0 ;; *) return 1 ;; esac
}

prova_motorlari() {
    local eid
    for eid in $(katalog_motorlari); do
        [ "$(kat "$eid" 'e["failover"].get("supported") and True or ""')" = "True" ] || continue
        [ "$(kat "$eid" 'e["failover"].get("mode","")')" = "supervised" ] || continue
        prova_uygulandi "$eid" || continue
        printf '%s\n' "$eid"
    done
}

kullanim() {
cat <<EOF

Devir provası — databases-stack

  ./scripts/failover-drill.sh <motor> [--onayla]

  --onayla YOKSA hiçbir şey yapılmaz: ne olacağı yazılır ve çıkılır (çıkış 5).
  --onayla VARSA ana kopya durdurulur, yedek yükseltilir ve KESİNTİ SÜRESİ
  uygulamanın gördüğü adresten (gateway portu) ölçülür. Devir KALICIDIR.

  Prova yapılabilen motorlar: $(prova_motorlari | tr '\n' ' ')

  Ayarlar (ortam değişkeni):
    HA_KESINTI_TAVANI=$TAVAN     kesinti üst sınırı (sn); aşılırsa prova düşer
    HA_YOKLAMA_ARALIGI=$YOKLAMA_ARALIGI   yoklama aralığı = ölçüm çözünürlüğü (sn)
    HA_DEVIR_TIMEOUT=$DEVIR_TO      controller'ın devir işi için üst sınır (sn)

  Çıkış kodları: 0 geçti · 1 düştü · 2 kapsam dışı · 3 ölçülemedi
                 4 prova bitti ama temizlik yapılamadı · 5 onay yok

EOF
}

# =============================================================================
# MOTOR BAĞLAMI — her şey katalogdan + .env'den
# =============================================================================
motor_baglami() {
    local pv
    M_AD="$(kat "$MOTOR" 'e["name"]')"
    M_PRIM_SVC="$(kat "$MOTOR" 'e["primary_service"]')"
    M_REP_SVC="$(kat "$MOTOR" 'e["replication"].get("replica_service") or ""')"
    M_REP_PROFIL="$(kat "$MOTOR" 'e["replication"].get("profile") or ""')"
    M_LISTEN="$(kat "$MOTOR" 'e["route"][0]["listen"]')"
    M_BETIK="$(kat "$MOTOR" 'e["failover"].get("promote_script") or e["id"]')"
    M_KULLANICI="$(kat "$MOTOR" 'e["connection"]["username"]')"
    M_VTABANI="$(kat "$MOTOR" 'e["connection"]["database"]')"
    pv="$(kat "$MOTOR" 'e["connection"]["password_env"]')"
    [ -n "$M_PRIM_SVC" ] && [ -n "$M_LISTEN" ] || return 1
    FO_BETIK="$STACK_ROOT/scripts/failover/$M_BETIK.sh"
    # Parola: compose'daki kural neyse o — motora özel değer boşsa DB_PASSWORD.
    M_PAROLA="${!pv:-}"
    [ -n "$M_PAROLA" ] || M_PAROLA="${DB_PASSWORD:-}"
    # Kullanıcı/veritabanı adı .env'de değiştirilmiş olabilir (compose da
    # oradan okur); katalog varsayılanı yalnız yedek plan.
    M_VTABANI="${DEFAULT_DATABASE:-$M_VTABANI}"
    [ "$MOTOR" = "postgresql" ] && M_KULLANICI="${POSTGRES_USER:-$M_KULLANICI}"
    # Ürünün devir betikleri parolayı `${MOTOR_PASSWORD:-$DB_PASSWORD}` diye
    # okur ve `set -u` ile çalışır: DB_PASSWORD .env'de hiç tanımlı değilse
    # betik parola hatasıyla değil "unbound variable" ile ölür.
    export DB_PASSWORD="${DB_PASSWORD:-$M_PAROLA}"
    return 0
}

# Devirden sonra roller terstir: kataloğun "replica_service"i canlı ana kopya
# olabilir. Yedek düğümü her zaman ŞU ANKİ ana kopyaya göre hesaplıyoruz;
# sabit ad kullanan bir prova ikinci koşumda yanlış düğümü durdururdu.
yedek_dugum() {   # yedek_dugum <şu anki ana kopya>
    if [ "$1" = "$M_PRIM_SVC" ]; then printf '%s' "$M_REP_SVC"
    else printf '%s' "$M_PRIM_SVC"; fi
}

# state.json bir LİSTE dosyasıdır; "listede yok" ile "dosyayı okuyamadım" aynı
# şey değildir: okunamayan bir state.json "replikasyon kurulu değil" diye
# raporlanırsa, kurulu bir yığında prova hiç koşmaz.
durum_listesinde() {   # 0 = var · 1 = yok · 2 = ÖLÇEMEDİK
    python3 -c '
import json, os, sys
yol = sys.argv[1]
if not os.path.exists(yol):
    sys.exit(1)
try:
    s = json.load(open(yol, encoding="utf-8"))
except Exception:
    sys.exit(2)
sys.exit(0 if sys.argv[3] in (s.get(sys.argv[2]) or []) else 1)' \
        "$STACK_ROOT/state/state.json" "$1" "$2" 2>/dev/null
    local rc=$?
    [ "$rc" -le 2 ] || rc=2
    return $rc
}

# =============================================================================
# İSTEMCİLER
# =============================================================================
# Host'ta veritabanı istemcisi yok; her sorgu container'ın içinden çalışır.
# Parola komut satırına DEĞİL ortama konur (host'ta `ps` çıktısında
# görünmesin) — backup.sh ve restore-drill.sh'taki desenin aynısı. Alt kabuk
# şart: export'lar betiğin geri kalanına sızmasın.
#
# İKİ BAKIŞ AÇISI, TEK İSTEMCİ:
#   dugum_sorgu → container'ın İÇİNDEN, doğrudan o düğüme (rol/veri ölçümü)
#   gw_sorgu    → sonda container'ından GATEWAY'e (uygulamanın gördüğü yol)
# Aynı ikilik e2e/failover.sh'ta da var; oradaki isimlendirmeye uyuyoruz ki
# iki paket birbirinin çıktısını okuyan biri için tek dil konuşsun.
dugum_sorgu() {   # dugum_sorgu <container> <sql | redis argümanları…>
    local c="$1"; shift
    case "$MOTOR" in
    mariadb)
        ( export MYSQL_PWD="$M_PAROLA"
          zaman "$SURE_SORGU" docker exec -e MYSQL_PWD "$c" \
              mariadb -u "$M_KULLANICI" -D "$M_VTABANI" -N -B -e "$1" ) \
          2>>"$LOG_FILE" ;;
    postgresql)
        ( export PGPASSWORD="$M_PAROLA"
          zaman "$SURE_SORGU" docker exec -e PGPASSWORD "$c" \
              psql -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAq \
                   -v ON_ERROR_STOP=1 -c "$1" ) 2>>"$LOG_FILE" ;;
    redis)
        ( export REDISCLI_AUTH="$M_PAROLA"
          zaman "$SURE_SORGU" docker exec -e REDISCLI_AUTH "$c" \
              redis-cli --no-auth-warning "$@" ) 2>>"$LOG_FILE" ;;
    *)  return 1 ;;
    esac
}

gw_sorgu() {      # gw_sorgu <sql | redis argümanları…>
    case "$MOTOR" in
    mariadb)
        ( export MYSQL_PWD="$M_PAROLA"
          zaman "$SURE_SORGU" docker exec -e MYSQL_PWD "$SONDA_C" \
              mariadb -h gateway -P "$M_LISTEN" -u "$M_KULLANICI" \
                      -D "$M_VTABANI" --connect-timeout=5 -N -B -e "$1" ) \
          2>>"$LOG_FILE" ;;
    postgresql)
        ( export PGPASSWORD="$M_PAROLA" PGCONNECT_TIMEOUT=5
          zaman "$SURE_SORGU" docker exec -e PGPASSWORD -e PGCONNECT_TIMEOUT \
              "$SONDA_C" psql -h gateway -p "$M_LISTEN" -U "$M_KULLANICI" \
                   -d "$M_VTABANI" -w -tAq -v ON_ERROR_STOP=1 -c "$1" ) \
          2>>"$LOG_FILE" ;;
    redis)
        ( export REDISCLI_AUTH="$M_PAROLA"
          zaman "$SURE_SORGU" docker exec -e REDISCLI_AUTH "$SONDA_C" \
              redis-cli --no-auth-warning -h gateway -p "$M_LISTEN" "$@" ) \
          2>>"$LOG_FILE" ;;
    *)  return 1 ;;
    esac
}

# Çıktıyı tek satıra indirger. `tr -d` ile boşluk silmek yetmez: istemci
# beklenmedik ikinci bir satır basarsa (uyarı, sürüm notu) o satır değere
# yapışır ve karşılaştırma sessizce yanlış sonuç verir.
ilk_satir() { printf '%s' "${1:-}" | tr -d '\r' | head -n 1 | tr -d '[:blank:]'; }

# =============================================================================
# PROVA VERİSİ — kanıt satırı ve sonda satırları
# =============================================================================
# Tablo/hash'i gateway üzerinden yaratıyoruz: uygulamanın yolunu kullanmayan
# bir hazırlık, o yolun çalıştığı hakkında hiçbir şey söylemez.
prova_kabini_yarat() {
    case "$MOTOR" in
    mariadb)
        gw_sorgu "CREATE TABLE IF NOT EXISTS $TABLO (
                    k VARCHAR(64) PRIMARY KEY,
                    v VARCHAR(96) NOT NULL) ENGINE=InnoDB;" >/dev/null || return 1 ;;
    postgresql)
        gw_sorgu "CREATE TABLE IF NOT EXISTS $TABLO (
                    k text PRIMARY KEY, v text NOT NULL);" >/dev/null || return 1 ;;
    redis)
        # Redis'te yaratılacak bir kap yok; hash ilk HSET ile doğar.
        : ;;
    esac
    PROVA_VERISI=1
    return 0
}

kanit_yaz() {   # kanit_yaz <değer>
    case "$MOTOR" in
    mariadb)    gw_sorgu "REPLACE INTO $TABLO (k,v) VALUES ('kanit','$1');" \
                    >/dev/null ;;
    postgresql) gw_sorgu "INSERT INTO $TABLO (k,v) VALUES ('kanit','$1')
                          ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" \
                    >/dev/null ;;
    redis)      local o; o="$(gw_sorgu HSET "$REDIS_ANAHTAR" kanit "$1")" || return 1
                # redis-cli read-only bir düğüme yazınca "-READONLY …" basıp
                # ÇIKIŞ 0 döner; karar çıkış koduna değil ÇIKTIYA dayanmalı.
                case "$(ilk_satir "$o")" in ''|*[!0-9]*) return 1 ;; esac ;;
    esac
}

# <bakış> = gw (gateway üzerinden) | container adı (düğümün içinden)
# DEĞERİ stdout'a DEĞİL SATIR_DEGER'e koyar; çıkış kodu SORGUNUN çalışıp
# çalışmadığını söyler. Sebep: ikisi de "boş cevap" üretir ama anlamları
# zıttır — "satır YOK" bir ölçümdür (veri kaybı), "sorgu çalışmadı" ölçüm
# yokluğudur. Komut ikamesiyle okusaydık çıkış kodu kaybolur, okunamayan bir
# düğüm kaybolmuş bir satırla aynı görünürdü.
SATIR_DEGER=""
satir_oku() {   # satir_oku <bakış> <anahtar> → 0 sorgu çalıştı · 1 çalışmadı
    local bakis="$1" k="$2" o
    SATIR_DEGER=""
    case "$MOTOR" in
    mariadb|postgresql)
        if [ "$bakis" = "gw" ]; then
            o="$(gw_sorgu "SELECT v FROM $TABLO WHERE k = '$k';")" || return 1
        else
            o="$(dugum_sorgu "$bakis" "SELECT v FROM $TABLO WHERE k = '$k';")" || return 1
        fi ;;
    redis)
        if [ "$bakis" = "gw" ]; then
            o="$(gw_sorgu HGET "$REDIS_ANAHTAR" "$k")" || return 1
        else
            o="$(dugum_sorgu "$bakis" HGET "$REDIS_ANAHTAR" "$k")" || return 1
        fi ;;
    *)  return 1 ;;
    esac
    SATIR_DEGER="$(ilk_satir "$o")"
    return 0
}

# =============================================================================
# SONDA CONTAINER'I
# =============================================================================
# İmaj: ÜRETİMDE ŞU AN KOŞAN imajın aynısı. Host'a hiçbir veritabanı istemcisi
# kurmadan, sürüm uyumu da garanti biçimde sorgu çalıştırmanın tek yolu bu —
# ve imaj zaten yereldedir, prova imaj indirmeyi beklemez.
motor_imaji() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }

sonda_ac() {   # sonda_ac <imaj> <ağ>
    # --memory 256m: sonda yalnız bir istemci çalıştırır. Tek sunuculuk bir
    # yığında ölçüm aracının üretimden bellek çalması, ölçtüğü şeyi bozar.
    # --restart no: prova bitince kendiliğinden geri gelmesin.
    docker run -d --name "$SONDA_C" --network "$2" --restart no \
        --memory 256m --memory-swap 256m --label "$ETIKET=1" \
        --entrypoint sh "$1" -c "sleep $SONDA_OMRU" >>"$LOG_FILE" 2>&1
}

# Sonda betiği: motora özel `yaz()` + motordan bağımsız döngü.
# Değişkenler ortamdan gelir (YP_*), betiğin içine gömülmez: tırnak kaçırmak
# bu boyda bir kabuk metninde sessiz bir yanlış sorguya dönüşürdü.
sonda_betigi() {
    case "$MOTOR" in
    mariadb) cat <<'SH'
yaz() {
  $TO mariadb -h "$YP_HOST" -P "$YP_PORT" -u "$YP_USER" -D "$YP_DB" \
      --connect-timeout=2 -N -B \
      -e "INSERT INTO $YP_TABLO (k,v) VALUES ('y-$1','$YP_KOSU');"
}
SH
    ;;
    postgresql) cat <<'SH'
yaz() {
  $TO psql -h "$YP_HOST" -p "$YP_PORT" -U "$YP_USER" -d "$YP_DB" -w -tAq \
      -v ON_ERROR_STOP=1 \
      -c "INSERT INTO $YP_TABLO (k,v) VALUES ('y-$1','$YP_KOSU');"
}
SH
    ;;
    redis) cat <<'SH'
yaz() {
  o=$($TO redis-cli --no-auth-warning -h "$YP_HOST" -p "$YP_PORT" -t 2 \
        HSET "$YP_TABLO" "y-$1" "$YP_KOSU" 2>/dev/null) || return 1
  # redis-cli hata mesajını basıp ÇIKIŞ 0 döndürebilir (-READONLY, -DENIED):
  # başarı ölçütü çıkış kodu değil, HSET'in döndürdüğü sayıdır.
  case "$o" in '' | *[!0-9]* ) return 1 ;; esac
  return 0
}
SH
    ;;
    esac
cat <<'SH'
# Zaman damgası /proc/uptime'dan: monoton, NTP düzeltmesinden etkilenmez ve
# her Linux container'ında vardır (busybox'ın date'i %N'i desteklemez).
u() { cut -d' ' -f1 /proc/uptime; }
# Her yoklamanın SERT üst sınırı. İstemcinin kendi bağlantı zaman aşımı
# (redis -t 2, mariadb --connect-timeout=2, PGCONNECT_TIMEOUT=2) TEK
# BAŞINA YETMİYOR: durdurulmuş bir container'ın adına bağlanmaya çalışan
# redis-cli, kendi -t 2 değerine rağmen 5,00 sn asılı kaldı (gerçek
# ölçüm: yoklama #63, 111253.84 → 111258.84). Asılan tek bir yoklama
# kesinti penceresindeki çözünürlüğü 5,2 sn'ye çıkardı — yani 8 sn'lik
# bir kesintinin belirsizliği 5 sn oldu. Sert sınır bu yüzden 3 sn:
# kara deliğe düşen bir bağlantı 3 sn'de kesilir, 3 sn'den uzun süren
# ama BAŞARILI bir yazma ise zaten kesintinin bir parçasıdır.
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout $YP_TO"
# Kesirli sleep her kabukta yok (busybox derleme seçeneği). Destek yoksa
# 1 sn'ye düşüyoruz: ölçüm kabalaşır ama SESSİZCE hızlı döngüye girip
# veritabanını dövmeyiz.
sleep "$YP_ARA" 2>/dev/null || YP_ARA=1
: > "$YP_LOG"
printf 'aralik %s\n' "$YP_ARA" >> "$YP_LOG"
i=0
son=$(( $(u | cut -d. -f1) + YP_SURE ))
while [ "$(u | cut -d. -f1)" -lt "$son" ]; do
    i=$((i+1))
    t1=$(u)
    if yaz "$i" >/dev/null 2>&1; then d=ok; else d=hata; fi
    t2=$(u)
    # Her satır AYRI bir >> ile yazılır: kabuğun stdio tamponu yüzünden
    # satırlar geç görünseydi, "toparlandı mı" beklemesi sonda hâlâ
    # yazarken bile "hiç yazamadı" derdi.
    printf '%s %s %s %s\n' "$t1" "$t2" "$d" "$i" >> "$YP_LOG"
    sleep "$YP_ARA"
done
printf 'bitti\n' >> "$YP_LOG"
SH
}

sonda_baslat() {
    local betik; betik="$(sonda_betigi)"
    [ -n "$betik" ] || return 1
    # -d: exec'i arka planda bırakıyoruz. Çıktı boruya değil container içindeki
    # dosyaya gidiyor; böylece host'un exec'i kesilse bile ölçüm kaybolmaz.
    case "$MOTOR" in
    mariadb)
        ( export MYSQL_PWD="$M_PAROLA"
          docker exec -d -e MYSQL_PWD \
            -e YP_HOST=gateway -e YP_PORT="$M_LISTEN" -e YP_USER="$M_KULLANICI" \
            -e YP_DB="$M_VTABANI" -e YP_TABLO="$TABLO" -e YP_KOSU="$KOSU" \
            -e YP_ARA="$YOKLAMA_ARALIGI" -e YP_SURE="$SONDA_OMRU" -e YP_TO="$YOKLAMA_TAVANI" \
            -e YP_LOG="$SONDA_LOG" "$SONDA_C" sh -c "$betik" ) >>"$LOG_FILE" 2>&1 ;;
    postgresql)
        ( export PGPASSWORD="$M_PAROLA" PGCONNECT_TIMEOUT=2
          docker exec -d -e PGPASSWORD -e PGCONNECT_TIMEOUT \
            -e YP_HOST=gateway -e YP_PORT="$M_LISTEN" -e YP_USER="$M_KULLANICI" \
            -e YP_DB="$M_VTABANI" -e YP_TABLO="$TABLO" -e YP_KOSU="$KOSU" \
            -e YP_ARA="$YOKLAMA_ARALIGI" -e YP_SURE="$SONDA_OMRU" -e YP_TO="$YOKLAMA_TAVANI" \
            -e YP_LOG="$SONDA_LOG" "$SONDA_C" sh -c "$betik" ) >>"$LOG_FILE" 2>&1 ;;
    redis)
        ( export REDISCLI_AUTH="$M_PAROLA"
          docker exec -d -e REDISCLI_AUTH \
            -e YP_HOST=gateway -e YP_PORT="$M_LISTEN" -e YP_USER="$M_KULLANICI" \
            -e YP_DB="$M_VTABANI" -e YP_TABLO="$REDIS_ANAHTAR" -e YP_KOSU="$KOSU" \
            -e YP_ARA="$YOKLAMA_ARALIGI" -e YP_SURE="$SONDA_OMRU" -e YP_TO="$YOKLAMA_TAVANI" \
            -e YP_LOG="$SONDA_LOG" "$SONDA_C" sh -c "$betik" ) >>"$LOG_FILE" 2>&1 ;;
    *)  return 1 ;;
    esac
}

yoklama_al() {   # sonda günlüğünü host'a kopyala
    zaman 30 docker exec "$SONDA_C" cat "$SONDA_LOG" > "$GECICI/yoklama.log" \
        2>>"$LOG_FILE"
}

# =============================================================================
# ÖLÇÜMÜN ÇÖZÜMLENMESİ
# =============================================================================
# Kesinti, sonda günlüğünden HESAPLANIR; bizim ne zaman baktığımızın sonuca
# etkisi yoktur. (Bu yüzden aşağıdaki beklemelerin sırası ölçümü bozmaz.)
# python3 kullanıyoruz: kayan nokta aritmetiğini awk'a bırakmak, ondalık
# ayıracı yerelden gelen bir ortamda sessizce yanlış sayı üretir.
yoklama_coz() {   # stdout: DURUM=… KESINTI=… SON_OK=… ILK_OK=… COZ=… HATA=…
    python3 - "$GECICI/yoklama.log" <<'PY'
import sys

satirlar = []
try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as f:
        for s in f:
            p = s.split()
            if len(p) != 4 or p[2] not in ("ok", "hata"):
                continue          # 'aralik …' ve 'bitti' satırları
            try:
                satirlar.append((float(p[0]), float(p[1]), p[2], int(p[3])))
            except ValueError:
                continue
except OSError:
    print("DURUM=okunamadi"); raise SystemExit

if not satirlar:
    print("DURUM=bos"); raise SystemExit

ilk_ok = next((i for i, s in enumerate(satirlar) if s[2] == "ok"), None)
if ilk_ok is None:
    print("DURUM=hicyazamadi HATA=%d" % len(satirlar)); raise SystemExit

# İlk BAŞARILI yazmadan SONRAKİ ilk hata: kesintinin başladığı yer.
h = next((i for i in range(ilk_ok, len(satirlar)) if satirlar[i][2] == "hata"),
         None)
if h is None:
    # Hiç hata görülmedi. Bu "kesinti olmadı" demek DEĞİL, "kesinti bir
    # yoklama aralığından kısaydı" demektir; ikisini karıştırmıyoruz.
    print("DURUM=kesintisiz OK_SAYISI=%d SON_OK=%d"
          % (sum(1 for s in satirlar if s[2] == "ok"), satirlar[-1][3]))
    raise SystemExit

s = next((i for i in range(h, len(satirlar)) if satirlar[i][2] == "ok"), None)
if s is None:
    print("DURUM=toparlanmadi HATA=%d SON_OK=%d"
          % (sum(1 for x in satirlar[h:] if x[2] == "hata"),
             satirlar[h - 1][3]))
    raise SystemExit

l = h - 1                      # kesintiden önceki son başarılı yazma
kesinti = satirlar[s][1] - satirlar[l][1]
# Çözünürlük: kesinti penceresinde art arda iki yoklamanın bitişleri
# arasındaki EN BÜYÜK boşluk. Ölçülen kesinti bu kadar uzun görünmüş olabilir.
coz = 0.0
for i in range(l, s):
    coz = max(coz, satirlar[i + 1][1] - satirlar[i][1])
print("DURUM=olctuk KESINTI=%.2f SON_OK=%d ILK_OK=%d COZ=%.2f HATA=%d"
      % (kesinti, satirlar[l][3], satirlar[s][3],
         coz, sum(1 for x in satirlar[l:s] if x[2] == "hata")))
PY
}

# =============================================================================
# CONTROLLER API
# =============================================================================
# Controller host'a port açmaz (güvenlik). Ona ulaşmanın yolu ya gateway'den
# TLS+token ile geçmek ya da container'ın içinden çağırmaktır; stack.sh
# ikincisini kullanıyor, biz de aynı yolu kullanıyoruz — prova, ürünün kendi
# arayüzünden geçsin.
api_cagir() {   # api_cagir <METOD> <YOL> [gövde]
    docker exec -e API_METHOD="$1" -e API_PATH="$2" -e API_BODY="${3:-}" \
        controller python -c '
import os, sys, urllib.request, urllib.error
m = os.environ["API_METHOD"]; p = os.environ["API_PATH"]
b = os.environ.get("API_BODY") or None
req = urllib.request.Request(
    "http://127.0.0.1:8000" + p, method=m,
    data=b.encode() if b else None,
    headers={"X-Api-Token": os.environ.get("CONTROLLER_TOKEN", ""),
             "Content-Type": "application/json"})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=120).read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write(e.read().decode()); sys.exit(1)
' 2>>"$LOG_FILE"
}

json_alan() {   # stdin JSON → <alan>
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
sys.stdout.write("" if v is None else str(v))' "$1" 2>/dev/null
}

# İşin bitmesini bekler. 0 = iş başarıyla bitti · 1 = iş BAŞARISIZ (sebep
# İS_SEBEP'te) · 2 = ÖLÇEMEDİK (controller cevap vermedi / süre doldu).
IS_SEBEP=""
is_bekle() {   # is_bekle <iş kimliği> <saniye>
    local jid="$1" bitis=$(( $(date +%s) + $2 )) cikti durum
    IS_SEBEP=""
    while :; do
        cikti="$(api_cagir GET "/api/jobs/$jid")" || {
            IS_SEBEP="controller iş durumunu vermedi (/api/jobs/$jid)"; return 2; }
        durum="$(printf '%s' "$cikti" | json_alan state)"
        case "$durum" in
            done)   return 0 ;;
            failed) IS_SEBEP="$(printf '%s' "$cikti" | json_alan reason)"
                    [ -n "$IS_SEBEP" ] || IS_SEBEP="sebep bildirilmedi"
                    return 1 ;;
            running) ;;
            *)      IS_SEBEP="iş durumu okunamadı ('${durum:-boş}')"; return 2 ;;
        esac
        if [ "$(date +%s)" -ge "$bitis" ]; then
            IS_SEBEP="devir işi $2 sn içinde bitmedi (iş $jid hâlâ sürüyor)"
            return 2
        fi
        sleep 2
    done
}

# =============================================================================
# KİLİT
# =============================================================================
# Prova ile YEDEKLEME AYNI KİLİDİ paylaşır. Sebebi somut: yedekleme ANA
# KOPYADAN dump alır; devir tam o sırada ana kopyayı durdurursa yedek yarıda
# kesilir ve geriye .bozuk bir dosya kalır. Tersi de doğru: dump sürerken
# ölçülen bir kesinti süresi, devrin değil disk yükünün sayısıdır.
# acquire_lock DOĞRUDAN çağrılmıyor: o, kilit meşgulken die ile ÇIKIŞ 1
# veriyor ve JSON basılmıyor — controller bunu "devir başarısız" diye okurdu.
# Oysa gerçek tam tersi: prova hiç DENENEMEDİ (çıkış 3).
kilit_al() {
    command -v flock >/dev/null 2>&1 \
        || olcum_yok "flock (util-linux) yok — yedekleme kilidi alınamadı, prova yapılmadı."
    mkdir -p "$(dirname "$KILIT")" 2>/dev/null || true
    # Kilidi controller (container'da root) ile PAYLAŞIYORUZ; modu
    # açılmazsa iki taraf ayrı kilit tutar ve kilit hiçbir şeyi
    # engellemez olur.
    paylasilan_dosya "$KILIT" 0666
    exec 9>>"$KILIT" || olcum_yok "Kilit dosyası açılamadı: $KILIT (sahibi $(stat -c '%U:%G %a' "$KILIT" 2>/dev/null || echo bilinmiyor), siz $(id -un)). Onarım: ./stack.sh doctor --duzelt"
    flock -n 9 || olcum_yok "Yedekleme kilidi başkasında ($KILIT) — yedekleme ya da geri yükleme sürüyor. Prova YAPILMADI; devrin durumu hakkında bir şey söylemiyoruz."
}

# Kilit alındıktan sonra bu host'ta başka prova koşamaz; dolayısıyla etiketli
# ne varsa ÖNCEKİ bir koşumun kalıntısıdır. Sessizce bırakmak, tek sunuculuk
# bir yığında yavaş yavaş biriken bir bellek sızıntısı demek.
kalintilari_topla() {
    local id n=0
    for id in $(docker ps -aq --filter "label=$ETIKET" 2>/dev/null); do
        docker rm -f "$id" >>"$LOG_FILE" 2>&1 && n=$((n+1))
    done
    [ "$n" -gt 0 ] && warn "Önceki yarım kalmış provalardan $n kalıntı temizlendi."
    return 0
}

# =============================================================================
# ÇALIŞTIR — argümanlar
# =============================================================================
for arg in "$@"; do
    case "$arg" in
        --onayla)      ONAY=1 ;;
        -h|--yardim)   MOTOR=""; break ;;
        -*)            MOTOR="${MOTOR:-}"
                       kullanim
                       DETAY="bilinmeyen seçenek: $arg"
                       bitir 2 ;;
        *)             [ -z "$MOTOR" ] && MOTOR="$arg" ;;
    esac
done

if [ -z "$MOTOR" ]; then
    kullanim
    DETAY="motor belirtilmedi"
    bitir 2
fi

command -v python3 >/dev/null 2>&1 \
    || olcum_yok "python3 yok — katalog ve ölçüm çözümlemesi yapılamaz."

if ! katalogda_var "$MOTOR"; then
    kapsam_disi "Kataloğda böyle bir motor yok: $MOTOR (bkz. catalog.json)"
fi

# Kapsam: katalog ne diyorsa o. Gerekçesini de katalogdan alıp basıyoruz —
# "desteklenmiyor" deyip sebebini söylememek, kullanıcıyı ürünün içine bakmaya
# zorlar.
if [ "$(kat "$MOTOR" 'e["failover"].get("supported") and True or ""')" != "True" ]; then
    kapsam_disi "$MOTOR devir yapamıyor: $(kat "$MOTOR" 'e["failover"].get("note","")')"
fi
if [ "$(kat "$MOTOR" 'e["failover"].get("mode","")')" != "supervised" ]; then
    kapsam_disi "$MOTOR devri controller yönetmiyor (mod: $(kat "$MOTOR" 'e["failover"].get("mode","")')) — durdurulup ölçülecek bir devir işi yok. $(kat "$MOTOR" 'e["failover"].get("note","")')"
fi
if ! prova_uygulandi "$MOTOR"; then
    kapsam_disi "Bu motorda prova yapılamıyor: $MOTOR — katalog devri destekliyor ama bu betikte yoklama yolu (istemci sorgusu) henüz yazılmadı."
fi

motor_baglami || olcum_yok "catalog.json'dan $MOTOR bağlamı okunamadı (primary_service / route)."
[ -f "$FO_BETIK" ] || olcum_yok "Yükseltme betiği yok: $FO_BETIK — controller devri yapamaz."
[ -n "$M_REP_SVC" ] || kapsam_disi "$M_AD için katalogda yedek kopya (replica_service) tanımlı değil."
[ -n "$M_PAROLA" ] || olcum_yok "$MOTOR parolası okunamadı (.env yok ya da eksik) — sonda bağlanamaz."

command -v docker >/dev/null 2>&1 || olcum_yok "docker bulunamadı — prova yapılamadı."
docker info >/dev/null 2>&1 \
    || olcum_yok "docker'a erişilemiyor (servis kapalı ya da yetki yok) — prova yapılamadı."
container_running controller \
    || olcum_yok "controller çalışmıyor — devri ve yönlendirmeyi o yapar. Önce: ./stack.sh up"
container_running gateway \
    || olcum_yok "gateway çalışmıyor — kesinti süresi ancak uygulamanın gördüğü adresten ölçülebilir. Önce: ./stack.sh up"

kilit_al
kalintilari_topla

# =============================================================================
# ÖN KOŞUL: replikasyon açık ve AKIYOR mu
# =============================================================================
ESKI_ANA="$(primary_of "$MOTOR")"
YEDEK="$(yedek_dugum "$ESKI_ANA")"

container_running "$ESKI_ANA" \
    || olcum_yok "$M_AD ana kopyası ($ESKI_ANA) çalışmıyor — ölçülecek bir kesinti yok. Önce: ./stack.sh enable $MOTOR"

durum_listesinde profiles "$M_REP_PROFIL"; _rc=$?
case "$_rc" in
    0) ;;
    1) olcum_yok "$M_AD için replikasyon kurulu değil (state.json/profiles içinde $M_REP_PROFIL yok) — yükseltilecek yedek kopya olmadan prova YAPILAMAZ. Kurmak için: ./stack.sh replica on $MOTOR" ;;
    *) olcum_yok "state/state.json okunamadı — replikasyonun kurulu olup olmadığını ölçemedik; ana kopyaya dokunmuyoruz." ;;
esac
container_running "$YEDEK" \
    || olcum_yok "Yedek kopya ($YEDEK) çalışmıyor — yükseltilecek düğüm yok, prova yapılamaz."

# Ürünün KENDİ kapısı: controller devirden hemen önce aynı soruyu soruyor.
# Provanın kendi ölçütünü uydurması, ürünün reddedeceği bir devri "yapılabilir"
# sanmasına yol açardı.
if ! zaman 150 sh "$FO_BETIK" ready "$YEDEK" >>"$LOG_FILE" 2>&1; then
    olcum_yok "Yedek kopya ($YEDEK) yükseltmeye hazır değil — replikasyon akmıyor. Ürünün kendi kapısı reddetti (scripts/failover/$M_BETIK.sh ready). Ana kopyaya DOKUNULMADI. Ayrıntı: $LOG_FILE"
fi

AG="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' gateway 2>/dev/null)"
[ -n "$AG" ] || olcum_yok "gateway'in ağı okunamadı — sonda container'ı uygulamanın durduğu yere bağlanamaz."
IMAJ="$(motor_imaji "$ESKI_ANA")"
[ -n "$IMAJ" ] || olcum_yok "$ESKI_ANA container'ının imajı okunamadı — sorgu çalıştıracak istemcimiz yok."

KOSU="$(date +%s)-$$"
SONDA_C="dbstack-ha-prova-$MOTOR-$$-$(date +%Y%m%d%H%M%S)"
docker inspect "$SONDA_C" >/dev/null 2>&1 \
    && olcum_yok "Sonda container adı zaten kullanımda: $SONDA_C"
GECICI="$(mktemp -d "${TMPDIR:-/tmp}/dbstack-ha-XXXXXX")" \
    || olcum_yok "Geçici dizin açılamadı."

heading "Devir provası — $M_AD"
dlog "ana kopya : $ESKI_ANA"
dlog "yedek     : $YEDEK"
dlog "adres     : gateway:$M_LISTEN  (uygulamanın gördüğü adres)"
dlog "sonda     : $SONDA_C  (imaj $IMAJ, ağ $AG)"

sonda_ac "$IMAJ" "$AG" \
    || olcum_yok "Sonda container'ı açılamadı ($IMAJ) — ayrıntı: $LOG_FILE"

# --------------------------------------------------------- kanıt satırı ----
prova_kabini_yarat \
    || olcum_yok "Prova tablosu gateway üzerinden yaratılamadı — devir öncesi yazma zaten çalışmıyor. Ayrıntı: $LOG_FILE"
kanit_yaz "$KOSU-kanit" \
    || olcum_yok "Kanıt satırı gateway üzerinden YAZILAMADI — devir öncesi yazma çalışmıyor, ölçülecek bir kesinti yok. Ayrıntı: $LOG_FILE"
satir_oku gw kanit \
    || olcum_yok "Kanıt satırı yazıldı ama gateway'den geri okuma SORGUSU çalışmadı — COMMIT edildiği doğrulanamadı. Ayrıntı: $LOG_FILE"
[ "$SATIR_DEGER" = "$KOSU-kanit" ] \
    || olcum_yok "Kanıt satırı gateway'den geri okundu ama değer tutmuyor (okunan: '${SATIR_DEGER:-boş}') — COMMIT edildiği doğrulanamadı."
dok "Kanıt satırı yazıldı ve gateway'den geri okundu (COMMIT edildi)."

# Replikasyonun AKTIĞINI yapılandırmadan değil, satırın kendisinden
# öğreniyoruz: "profil kurulu" ve "container ayakta" bir replikanın veriyi
# gerçekten aldığını söylemez.
_akti=0
_bitis=$(( $(date +%s) + AKIS_TO ))
while :; do
    if satir_oku "$YEDEK" kanit \
       && [ "$SATIR_DEGER" = "$KOSU-kanit" ]; then _akti=1; break; fi
    [ "$(date +%s)" -ge "$_bitis" ] && break
    sleep 1
done
[ "$_akti" -eq 1 ] \
    || olcum_yok "Kanıt satırı $AKIS_TO sn içinde yedek kopyaya ($YEDEK) ULAŞMADI — replikasyon akmıyor. Bu düğümü yükseltmek veri kaybı olurdu; ana kopyaya DOKUNULMADI."
dok "Kanıt satırı yedek kopyada ($YEDEK) görüldü — replikasyon akıyor."

# =============================================================================
# PLAN — ne olacağını devirden ÖNCE yazıyoruz
# =============================================================================
heading "Prova ne yapacak"
cat <<PLAN
  1) $ESKI_ANA DURDURULACAK (fence). İki kopyanın aynı anda yazı kabul edip
     verilerin ayrışmasını (split-brain) önlemek için bu adım zorunludur.
  2) $YEDEK yükseltilecek ve yazmaya açılacak.
  3) Yönlendirme tablosu yeniden yazılıp gateway yeniden yüklenecek.
     Uygulamanızın bağlantı adresi DEĞİŞMEZ: gateway:$M_LISTEN.

  KESİNTİ: bu provanın ölçtüğü şey tam olarak budur; önceden bilinen tek şey
  ÜST SINIRDIR — $TAVAN sn (fence $FENCE_TAVANI + yükseltme $YUKSELTME_TAVANI
  + yönlendirme $YONLENDIRME_TAVANI). Aşılırsa prova DÜŞER.
  Bu, PLANLI devrin kesintisidir. Ana kopya kendiliğinden ölürse buna
  denetleyicinin tespit süresi eklenir: $VURUS vuruş x $ARALIK sn = $TESPIT sn.

  DEVİR KALICIDIR. Ana kopya $YEDEK olarak kalır; roller yer değiştirmiş olur.
  Geri takas etmek gereksiz ikinci bir kesinti demek olurdu, o yüzden
  yapılmaz. Prova bittiğinde yedek kopya YOKTUR.

  YEDEK KOPYAYI GERİ GETİRMEK provanın parçası DEĞİLDİR; ayrı bir komuttur ve
  bunu bilerek siz çalıştırırsınız (eski düğümün verisi silinip yeni ana
  kopyadan baştan kopyalanır, dakikalar sürebilir):

      ./stack.sh failover rebuild $MOTOR

  Bu komut çalıştırılana kadar sistem TEK KOPYAYLA çalışır: ikinci bir arıza
  için yedeğiniz olmaz. Provanın ölçtüğü kesinti kadar önemli olan şey budur.

  Prova, $M_VTABANI içine küçük bir kap ($TABLO / $REDIS_ANAHTAR) yazar ve
  sonunda siler.
PLAN

if [ "$ONAY" -ne 1 ]; then
    warn "ONAY YOK — DEVİR YAPILMADI. Ana kopya ($ESKI_ANA) çalışmaya devam ediyor."
    log  "Yapılan tek şey ön koşul ölçümüydü: kanıt satırı yazıldı, yedekte"
    log  "görüldü ve şimdi siliniyor. Roller değişmedi."
    log  "Provayı gerçekten çalıştırmak için:  ./scripts/failover-drill.sh $MOTOR --onayla"
    DETAY="onay yok (--onayla verilmedi): ön koşullar ölçüldü ve plan basıldı, DEVİR YAPILMADI"
    bitir 5
fi

# =============================================================================
# ÖLÇÜM
# =============================================================================
dlog "sonda başlatılıyor (her ${YOKLAMA_ARALIGI} sn'de bir gateway:$M_LISTEN üzerinden yazma)"
sonda_baslat || olcum_yok "Sonda döngüsü başlatılamadı — ayrıntı: $LOG_FILE"

# Sonda ÇALIŞTIĞINI kanıtlamadan ana kopyaya dokunmuyoruz: ölçemeyeceğimiz
# bir kesintiyi üretmek, kullanıcıya bedeli ödetip karşılığında hiçbir sayı
# vermemek olurdu.
_hazir=0
_bitis=$(( $(date +%s) + 60 ))
while :; do
    yoklama_al
    case "$(yoklama_coz)" in
        DURUM=olctuk*|DURUM=kesintisiz*) _hazir=1; break ;;
    esac
    [ "$(date +%s)" -ge "$_bitis" ] && break
    sleep 2
done
if [ "$_hazir" -ne 1 ]; then
    olcum_yok "Sonda 60 sn içinde gateway üzerinden TEK BİR başarılı yazma yapamadı — ölçüm aracı çalışmıyor, ana kopyaya DOKUNULMADI. Ayrıntı: $LOG_FILE ve $GECICI/yoklama.log"
fi
dok "Sonda yazıyor — ölçüm başladı."

heading "Devir"
dlog "controller'ın devir işi tetikleniyor (POST /api/engines/$MOTOR/failover)"
_cevap="$(api_cagir POST "/api/engines/$MOTOR/failover" '{}')" \
    || olcum_yok "Devir isteği controller tarafından kabul edilmedi. Ayrıntı: $LOG_FILE"
JOB="$(printf '%s' "$_cevap" | json_alan job)"
[ -n "$JOB" ] \
    || olcum_yok "Controller iş kimliği vermedi (cevap: $(printf '%s' "$_cevap" | tr -d '\n' | head -c 200))"
dlog "devir işi: $JOB"

is_bekle "$JOB" "$DEVIR_TO"; IS_RC=$?

# Devir işi başarısız olsa bile ÖLÇMEYE DEVAM EDİYORUZ: controller yükseltme
# tutmayınca eski ana kopyayı geri açıyor ve uygulama yine bir süre yazamıyor.
# "Devir olmadı" ile "devir olmadı ve uygulama 40 sn yazamadı" aynı şey değil;
# ikincisi raporlanmazsa geri alınan bir devir bedelsiz sanılır.
_bitis=$(( $(date +%s) + TOPARLANMA_TO ))
# Kesinti hiç görünmediyse ne kadar bekleyeceğimizin de bir sonu olmalı.
# Devir bittiyse, topoloji değiştiyse ve bu kısa pencerede tek bir yazma
# bile düşmediyse cevap "kesinti bir yoklama aralığından kısaydı"dır.
# Bunu TOPARLANMA_TO boyunca beklemek, ÜRÜNÜN EN İYİ SONUCUNU provanın
# EN UZUN koşumu yapardı — üstelik hiçbir şey öğrenmeden.
_yerlesme=$(( $(date +%s) + 10 ))
COZUM=""
while :; do
    yoklama_al
    COZUM="$(yoklama_coz)"
    case "$COZUM" in DURUM=olctuk*) break ;; esac
    if [ "$(date +%s)" -ge "$_yerlesme" ] && [ "$IS_RC" -eq 0 ] \
       && [ "$(primary_of "$MOTOR")" != "$ESKI_ANA" ]; then
        case "$COZUM" in DURUM=kesintisiz*) break ;; esac
    fi
    [ "$(date +%s)" -ge "$_bitis" ] && break
    sleep 2
done

YENI_ANA="$(primary_of "$MOTOR")"

# Alanları kabuk değişkenlerine al. `eval` YOK: çözümleyicinin çıktısı
# beklenmedik bir şey basarsa eval onu ÇALIŞTIRIRDI.
D_DURUM=""; D_KESINTI=""; D_SON_OK=""; D_ILK_OK=""; D_COZ=""; D_HATA=""
KABA_NOT=""
for _p in $COZUM; do
    case "$_p" in
        DURUM=*)   D_DURUM="${_p#*=}" ;;
        KESINTI=*) D_KESINTI="${_p#*=}" ;;
        SON_OK=*)  D_SON_OK="${_p#*=}" ;;
        ILK_OK=*)  D_ILK_OK="${_p#*=}" ;;
        COZ=*)     D_COZ="${_p#*=}" ;;
        HATA=*)    D_HATA="${_p#*=}" ;;
    esac
done

# =============================================================================
# SONUÇ — önce devir oldu mu, sonra ne kadar sürdü, sonra ne kaybettik
# =============================================================================
if [ "$YENI_ANA" = "$ESKI_ANA" ]; then
    # Topoloji değişmedi: devir YAPILMADI. Ölçülen kesinti (varsa) yine
    # değerlidir — bedeli ödedik, karşılığını almadık.
    _ek=""
    case "$D_DURUM" in
        olctuk) KESINTI="$D_KESINTI"
                _ek=" Uygulama yine de ${D_KESINTI} sn yazamadı." ;;
    esac
    case "$IS_RC" in
        1) prova_dustu "DEVİR YAPILMADI — controller reddetti ya da geri aldı: ${IS_SEBEP}.${_ek} Ana kopya hâlâ $ESKI_ANA." ;;
        2) prova_dustu "DEVİR DOĞRULANAMADI — ${IS_SEBEP}. Topolojide ana kopya hâlâ $ESKI_ANA.${_ek}" ;;
        *) prova_dustu "Devir işi başarılı bildirdi ama topolojide ana kopya değişmedi (hâlâ $ESKI_ANA).${_ek} state/topology.json ve './stack.sh events' çıktısına bakın." ;;
    esac
fi

dok "Devir tamamlandı — yeni ana kopya: $YENI_ANA"

# --------------------------------------------------------------- kesinti ---
case "$D_DURUM" in
olctuk)
    KESINTI="$D_KESINTI"
    dlog "ÖLÇÜLEN KESİNTİ: ${KESINTI} sn (çözünürlük ${D_COZ} sn, $D_HATA başarısız yazma denemesi)"
    # Çözünürlük, kesintinin yarısından büyükse sayı bir büyüklük
    # mertebesidir, ölçüm değil. Bunu söylememek, 2 sn belirsizlikle
    # bulunmuş bir "3 sn" ile 0,2 sn belirsizlikle bulunmuş bir "3 sn"yi
    # aynı cümleyle raporlamak olurdu.
    if python3 -c 'import sys
sys.exit(0 if float(sys.argv[1]) * 2 > float(sys.argv[2]) else 1)' "$D_COZ" "$KESINTI" 2>/dev/null; then
        KABA_NOT="ölçüm KABA: çözünürlük (${D_COZ} sn) kesintinin yarısından büyük"
        warn "$KABA_NOT"
    fi
    ;;
kesintisiz)
    # Devir oldu, tek bir yazma bile düşmedi: kesinti bir yoklama aralığından
    # kısaydı. 0 basıyoruz ama "0" derken neyi ölçtüğümüzü de yazıyoruz.
    KESINTI="0.00"
    dlog "ÖLÇÜLEN KESİNTİ: 0 sn — hiçbir yazma denemesi düşmedi; kesinti bir yoklama aralığından (${YOKLAMA_ARALIGI} sn) kısa."
    ;;
toparlanmadi)
    # Devir topolojide oldu ama uygulama hâlâ yazamıyor. Bu, ürünün en pahalı
    # arıza sınıfı: yedek yükseldi, trafik oraya gitmiyor.
    prova_dustu "Devir yapıldı (yeni ana kopya $YENI_ANA) ama uygulama $TOPARLANMA_TO sn boyunca gateway:$M_LISTEN üzerinden YAZAMADI — yükseltme oldu, trafik yeni düğüme taşınmadı (yönlendirme tablosu / nginx reload). Kesinti hâlâ SÜRÜYOR."
    ;;
*)
    prova_dustu "Kesinti süresi ÖLÇÜLEMEDİ (yoklama günlüğü: ${D_DURUM:-boş}). Devir yapılmış olabilir — yeni ana kopya: $YENI_ANA. Günlük: $LOG_FILE"
    ;;
esac

# ------------------------------------------------------------- veri kaybı ---
# İki soru, iki ayrı okuma. İkisi de YENİ ANA KOPYANIN İÇİNDEN yapılır:
# gateway'den okumak, yönlendirme eski düğümü gösteriyorsa doğru cevabı
# yanlış yerden almak olurdu.
if ! satir_oku "$YENI_ANA" kanit; then
    # Sorgu HİÇ çalışmadı: satır kayboldu mu bilmiyoruz. Bunu "kayıp
    # yok" saymak, ölçemediğimiz şeyi iyi ilan etmek olurdu.
    KAYIP=null
    KAYIP_NOT="kanıt satırı sorgusu yeni ana kopyada ($YENI_ANA) çalışmadı — veri kaybı ÖLÇÜLEMEDİ"
    warn "$KAYIP_NOT"
elif [ "$SATIR_DEGER" = "$KOSU-kanit" ]; then
    KAYIP=false
    KAYIP_NOT="kanıt satırı duruyor"
else
    # Sorgu çalıştı ve satır YOK: bu bir ÖLÇÜMDÜR, körlük değil.
    KAYIP=true
    KAYIP_NOT="KANIT SATIRI KAYBOLDU (okunan: '${SATIR_DEGER:-boş}') — devirden önce COMMIT edilip yedeğe aktığı DOĞRULANMIŞ bir satır yeni ana kopyada yok"
    derr "$KAYIP_NOT"
fi

# Son yazma: kesinti başlamadan hemen önce BAŞARIYLA yazılmış satır. Asıl
# kayıp penceresi burasıdır — asenkron replikasyonda ana kopyanın göndermeye
# yetişemediği işlemler tam bu aralıkta kaybolur.
if [ "$D_DURUM" = "olctuk" ] && [ -n "$D_SON_OK" ]; then
    if ! satir_oku "$YENI_ANA" "y-$D_SON_OK"; then
        [ "$KAYIP" = "false" ] && KAYIP=null
        KAYIP_NOT="$KAYIP_NOT; son yazma (#$D_SON_OK) sorgusu çalışmadı — ölçülemedi"
    elif [ "$SATIR_DEGER" = "$KOSU" ]; then
        KAYIP_NOT="$KAYIP_NOT; devir anındaki son yazma (#$D_SON_OK) da duruyor"
    else
        KAYIP=true
        KAYIP_NOT="$KAYIP_NOT; devir anındaki son yazma (#$D_SON_OK) yeni ana kopyada YOK (okunan: '${SATIR_DEGER:-boş}') — asenkron replikasyonun kayıp penceresi"
        derr "Devir anındaki son yazma (#$D_SON_OK) yeni ana kopyada yok."
    fi
else
    KAYIP_NOT="$KAYIP_NOT; devir anındaki son yazma ayrıştırılamadı (kesinti penceresi yok)"
fi

# Yazma GERÇEKTEN yeni ana kopyaya mı iniyor? Gateway'den yazabiliyor olmak
# tek başına yetmez: yönlendirme diriltilmiş eski bir düğümü gösteriyorsa
# yazma yine "çalışıyor" görünür ve iki yazılabilir kopya (split-brain)
# gözden kaçar.
YER_NOT=""
if [ "$D_DURUM" = "olctuk" ] && [ -n "$D_ILK_OK" ]; then
    if ! satir_oku "$YENI_ANA" "y-$D_ILK_OK"; then
        YER_NOT="devir sonrası yazmanın nereye indiği ÖLÇÜLEMEDİ (sorgu çalışmadı)"
        warn "$YER_NOT"
    elif [ "$SATIR_DEGER" = "$KOSU" ]; then
        YER_NOT="devir sonrası yazma yeni ana kopyaya iniyor"
    else
        prova_dustu "Kesinti ${KESINTI} sn ölçüldü ama devirden SONRA gateway'e yazılan satır (#$D_ILK_OK) yeni ana kopyada ($YENI_ANA) YOK (okunan: '${SATIR_DEGER:-boş}') — yazma çalışıyor ama başka bir düğüme gidiyor. $KAYIP_NOT"
    fi
fi

# --------------------------------------------------------------- roller ----
# Panelin kullandığı dilin aynısı. İki farklı yerde iki farklı cümle,
# kullanıcıya iki farklı ürün gibi görünür.
heading "Devirden sonra"
log "Ana kopya artık $YENI_ANA — bu KALICIDIR. Uygulamanız AYNI ADRESE"
log "(gateway:$M_LISTEN) bağlanmaya devam eder, bağlantı bilgisi değişmez."
log "Rollerin yer değiştirmiş olması zararsızdır; geri takas etmek gereksiz"
log "ikinci bir kesinti demek olurdu."
log ""
log "Şu an yedek kopya YOK. Eski düğümü ($ESKI_ANA) yedek olarak geri getirmek için:"
log "    ./stack.sh failover rebuild $MOTOR"
warn "Bu komut $ESKI_ANA içindeki verileri SİLER ve yeni ana kopyadan baştan"
warn "kopyalar; iki kopyanın geçmişi devir anında ayrıştığı için bu bilinçlidir."

# ------------------------------------------------------------------ karar ---
_ozet="devir $ESKI_ANA → $YENI_ANA, kesinti ${KESINTI} sn (üst sınır $TAVAN sn, çözünürlük ${D_COZ:-?} sn)${KABA_NOT:+; $KABA_NOT}; $KAYIP_NOT${YER_NOT:+; $YER_NOT}; planlı devir — kendiliğinden ölümde denetleyicinin tespit süresi ($TESPIT sn) eklenir"

if [ "$KAYIP" = "true" ]; then
    prova_dustu "VERİ KAYBI: $_ozet"
fi

# Kesinti karşılaştırması python3 ile: kesirli sayıyı `[ ]` ile
# karşılaştırmak kabukta hatadır ve akış sessizce yanlış dala girer.
if ! python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' \
        "$KESINTI" "$TAVAN" 2>/dev/null; then
    prova_dustu "KESİNTİ ÜST SINIRI AŞTI (${KESINTI} sn > $TAVAN sn): $_ozet"
fi

if [ "$KAYIP" = "null" ]; then
    # Devir oldu, süre ölçüldü ama veri kaybını doğrulayamadık. "Bilmiyorum"
    # ile "iyi" aynı şey değildir; provayı geçmiş saymıyoruz.
    prova_dustu "Devir ölçüldü ama VERİ KAYBI DOĞRULANAMADI: $_ozet"
fi

OK=true
DETAY="$_ozet"
dok "PROVA GEÇTİ — $M_AD ${KESINTI} sn kesintiyle devretti, onaylanmış veri kaybı yok."
bitir 0
