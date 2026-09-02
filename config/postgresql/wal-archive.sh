#!/bin/sh
# =============================================================================
# PostgreSQL — WAL arşivleme komutu (archive_command)
# =============================================================================
# docker-compose.yml şöyle çağırır:
#     archive_command = sh /usr/local/bin/wal-archive.sh %p %f
#   $1 = %p  segmentin PGDATA'ya göreli yolu
#   $2 = %f  segmentin adı (24 hex karakter)
#
# NEDEN AYRI BİR DOSYA (compose'a tek satır yazmak yerine):
# archive_command'ın çıkış kodu PostgreSQL için "bu segment güvende mi"
# sorusunun TEK cevabıdır. 0 dönerse PostgreSQL segmenti pg_wal'dan geri
# dönüşüme sokar — yani yanlış bir 0, veriyi kalıcı olarak yok eder. Tek
# satırlık bir `cp` zincirinde bunu doğru yapmanın yolu yok; burada üç ayrı
# hâli ayrı ayrı ele alabiliyoruz (aşağıda). Ayrıca bu dosya `sh -n` ile
# sözdizimi denetiminden geçirilebiliyor, compose içindeki bir dize
# geçirilemiyordu.
#
# NEDEN `sh <yol>` OLARAK ÇAĞRILIYOR (doğrudan çalıştırılmak yerine):
# Dosya host'tan bind-mount ile geliyor. Depo Windows'ta klonlanıp kopyalandığı
# bir kurulumda çalıştırma biti kaybolur; o hâlde archive_command "Permission
# denied" ile SÜREKLİ başarısız olur, PostgreSQL hiçbir segmenti serbest
# bırakamaz ve pg_wal veri diskini doldurup sunucuyu PANIC ile durdurur.
# Yorumlayıcıyı biz verince çalıştırma biti tamamen konu dışı kalıyor.
# =============================================================================
set -u

KAYNAK="${1:-}"
AD="${2:-}"
D="${PG_WAL_ARSIV:-/wal-archive}"

# Hata mesajları stderr'e: PostgreSQL bunları kendi günlüğüne yazar ve
# `docker logs postgresql` ile görünür. Sessizce 1 dönmek, operatöre yalnızca
# "archive command failed" satırını bırakırdı.
hata() { printf 'wal-archive: %s\n' "$*" >&2; exit 1; }

[ -n "$KAYNAK" ] && [ -n "$AD" ] || hata "eksik argüman (%p %f verilmedi)"

# Adın İÇİNDE '/' OLMAMALI — kontrolün tek amacı bu: arşivin dışına yazan
# bir çağrı olmasın.
#
# BURAYA DAHA SIKI BİR KONTROL YAZMAK YIKICI: ilk sürüm "24 hex karakter"
# şartı koyuyordu ve ÖLÇÜMDE ANINDA PATLADI. PostgreSQL archive_command'ı
# yalnız WAL segmentleri için çağırmıyor; yedek geçmişi dosyalarını
# (000000010000000000000003.00000028.backup), zaman çizgisi geçmişini
# (00000002.history) ve yarım kalmış segmentleri (….partial) de aynı komutla
# arşivler. Ölçülen sonuç: pg_basebackup'tan hemen sonra .backup dosyası
# 9 kez reddedildi, PostgreSQL "archive command failed" deyip SONSUZA KADAR
# yeniden denedi — yani arşivleme o noktada DURDU ve pg_wal büyümeye başladı.
# Tam olarak engellemeye çalıştığımız arıza. Ders: PostgreSQL'in gönderdiği
# hiçbir adı geri çevirmiyoruz; ad denetimi yalnızca yol güvenliği içindir.
case "$AD" in
    */*|.|..|"") hata "beklenmeyen dosya adı: $AD" ;;
esac

[ -d "$D" ] || hata "arşiv dizini yok: $D (host'ta backups/postgresql/wal)"
[ -w "$D" ] || hata "arşiv dizinine yazılamıyor: $D — sahibi bu container'ın kullanıcısı olmalı. Düzeltmek için: ./scripts/pitr.sh kur postgresql"

HEDEF="$D/$AD"

# --- 1) Segment ZATEN arşivde ------------------------------------------------
# PostgreSQL bir segmenti ikinci kez arşivlemeyi deneyebilir: çökme sonrası
# yeniden başlarken son checkpoint'ten sonraki .ready dosyaları tekrar
# işlenir. Bu normaldir ve aynı içerik ikinci kez gelir.
#
# İçerik AYNIYSA iş zaten bitmiştir → 0 dönüyoruz. PostgreSQL belgelerinin
# önerdiği "var olanın üzerine yazma, hata ver" davranışı burada SONSUZ
# yeniden deneme üretirdi: aynı ad her denemede var olmaya devam eder,
# arşivleme bir daha asla ilerlemez ve pg_wal veri diskini doldurur.
#
# İçerik FARKLIYSA elimizde aynı adı taşıyan iki farklı segment var ve
# hangisinin doğru olduğunu bilmiyoruz; üzerine yazmak kurtarma zincirini
# sessizce bozar. Bu yüzden duruyoruz. Aynı sebeple, karşılaştırmayı
# YAPAMADIĞIMIZ hâlde de duruyoruz: "kontrol edemedim" ile "aynı" birbirinin
# yerine geçmez, ve bu dalda yanılmanın bedeli kurtarılamayan bir veritabanı.
if [ -e "$HEDEF" ]; then
    command -v cmp >/dev/null 2>&1 \
        || hata "arşivde $AD zaten var ama cmp yok, aynı mı farklı mı KARŞILAŞTIRILAMADI — elle inceleyin ($D)"
    cmp -s "$KAYNAK" "$HEDEF" && exit 0
    hata "arşivde AYNI ADLA FARKLI bir segment var: $AD — kurtarma zinciri tehlikede, elle inceleyin ($D)"
fi

# --- 2) Kopyala ve ATOMİK yerleştir ------------------------------------------
# Doğrudan "$HEDEF"e kopyalamıyoruz. Kopyalama ortasında container ölürse
# arşivde YARIM bir segment kalır; PostgreSQL onu tam sanır (adı doğrudur),
# bir daha arşivlemez ve kurtarma o segmentte "invalid record" ile durur.
# Geçici ada yazıp mv ile taşımak, arşivde bir dosyanın ya hiç olmamasını ya
# da TAM olmasını garanti eder (aynı dosya sistemi içinde rename atomiktir).
GECICI="$D/.gecici.$AD.$$"
trap 'rm -f "$GECICI"' EXIT INT TERM

cp "$KAYNAK" "$GECICI" || hata "kopyalanamadı: $AD → $GECICI (disk dolu olabilir)"
mv "$GECICI" "$HEDEF"  || hata "yerleştirilemedi: $GECICI → $HEDEF"

# --- 3) Diske indir ----------------------------------------------------------
# mv'den sonra dosya adı görünürdür ama içerik hâlâ sayfa önbelleğinde
# olabilir; host o anda güç kaybederse arşivde adı olan boş bir dosya kalır.
# `sync -d "$D"` dizin girdisini ve veriyi indirir. Başarısız olması işi
# BOZMAZ (eski coreutils'te -d yok), o yüzden çıkış kodunu yutuyoruz —
# ama tam bir `sync` de çağırmıyoruz: o, host'taki bütün dosya sistemlerini
# beklerdi ve her segmentte bunu yapmak yoğun bir sunucuda arşivlemeyi
# üretimin hızının altına düşürürdü.
sync -d "$D" 2>/dev/null || true

exit 0
