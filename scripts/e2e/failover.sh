#!/bin/bash
# =============================================================================
# databases-stack — UÇTAN UCA TEST: OTOMATİK DEVİR (failover)
# =============================================================================
# Bu ürünün ana vaadi tek cümledir: ANA KOPYA ÖLÜRSE YEDEK KOPYA DEVREYE GİRER
# VE UYGULAMANIN BAĞLANTI ADRESİ DEĞİŞMEZ. Bu betik o vaadi CANLI kurulumda,
# gerçek veri yazıp geri okuyarak ölçer.
#
# Neden "container ayakta" diye bakmak yetmez: devirden sonra yedek yükselse
# bile gateway'in yönlendirme tablosu tazelenmezse `docker ps` sapasağlam
# görünür, uygulamalar ise ölü düğüme bağlanmaya devam eder. Aynı şekilde,
# yükselmiş ama hiç veri almamış bir replika da "çalışıyor" görünür — sessiz
# veri kaybı tam olarak böyle olur. Bu yüzden her adımda VERİ yazılıp geri
# okunur ve karşılaştırılır.
#
# DÖRT SONUÇ TÜRÜ (scripts/e2e/lib.sh):
#   t_ok       ölçtük, doğru
#   t_fail     ölçtük, yanlış
#   t_skip     ÖN KOŞUL YOK (motor kapalı, replikasyon kurulu değil) — meşru
#   t_unknown  ÖLÇEMEDİK (docker cevap vermedi, topology.json okunamadı,
#              istemci hiç çalışmadı) — BAŞARISIZ sayılır
# Bu betiğin denetiminde bulunan hataların tamamı tek bir kalıptandı: ÖLÇÜM
# ARACI BOZULUNCA KONTROL YEŞİL YANIYORDU. En kötüsü: './stack.sh failover now'
# ALAKASIZ bir sebeple (controller kapalı, zaman aşımı, onay istemi okunamadı)
# sıfırdan farklı dönünce "güvenlik kapısı çalıştı" yazılıyordu. Artık ret
# GEREKÇESİ ürünün kendi olay kaydından okunup beklenen kapıyla eşleştiriliyor;
# eşleşmiyorsa sonuç t_ok değil, t_unknown.
#
# Zincir (her supervised motor için):
#   1. Yedek kopya + otomatik devir açık mı (değilse ürünün kendi komutlarıyla kurulur)
#   2. gateway üzerinden veri yaz → replikada göründüğünü doğrula
#   3. GÜVENLİK KAPISI: yükseltmeyi bilerek imkânsız kıl, devri tetikle →
#      REDDEDİLMELİ, gerekçesi BEKLENEN kapı olmalı ve ana kopyaya DOKUNULMAMALI
#   4. Ana kopyayı ÖLDÜR (docker stop) → denetleyici devri kendisi tamamlamalı
#   5. AYNI ADRESTEN (gateway) yazma çalışmalı VE yazı YENİ ana kopyaya inmeli
#   6. Devir öncesi yazılan satır yeni ana kopyada KAYBOLMAMIŞ olmalı
#   7. ./stack.sh failover rebuild → eski kopya yedek olarak geri gelmeli,
#      ikinci bir YAZILABİLİR ana kopya olarak DEĞİL, ve replikasyon akmalı
#
# Kullanım (yığın kökünden):
#   ./scripts/e2e/failover.sh                  # katalogdaki tüm supervised motorlar
#   ./scripts/e2e/failover.sh postgresql       # yalnız biri
#   bash scripts/e2e/failover.sh redis mariadb # çalıştırma bitini vermeye üşendiyseniz
#
# ⚠️ BU TEST YIKICIDIR — ve bıraktığı izi kendisi toplar:
#   • Ana kopya bilerek durdurulur; devir sırasında saniyeler süren bir kesinti olur.
#   • Devirden sonra roller yer değiştirir. Betik ürünün kendi
#     `./stack.sh failover rebuild` komutuyla eski kopyayı yedek olarak geri alır;
#     yani kurulum testten çalışır durumda çıkar, ama ana kopya artık DİĞER
#     düğümdür (bu normaldir; ürün böyle tasarlandı). Sonda hangi düğümün ana
#     kopya olduğu yazılır.
#   • Kendi yarattığı tablo/anahtar sonunda silinir; betik üst üste çalıştırılabilir.
#   ÜRETİM SAATİNDE ÇALIŞTIRMAYIN.
#
# Süre: motor başına ~4–8 dk. Yedek kopya hiç kurulu değilse ilk kopyalama
# (pg_basebackup / dump) veritabanı büyüklüğüne göre bunu uzatır.
#
# Ayarlar (hepsi ortam değişkeniyle ezilebilir):
#   E2E_KUR=0                 eksik yedek kopyayı KURMA, testi atla
#   E2E_DEVIR_TIMEOUT=300     otomatik devrin tamamlanması için beklenecek süre
#   E2E_KAPANIS_TIMEOUT=180   devrin 4/4 kapanması (yönlendirme + izleme + kayıt)
#   E2E_REPLIKA_TIMEOUT=1800  `./stack.sh replica on` için üst sınır
#   E2E_REBUILD_TIMEOUT=1800  `./stack.sh failover rebuild` için üst sınır
#   E2E_AKIS_TIMEOUT=120      yazılan satırın yedeğe ulaşması için üst sınır
#   E2E_ISTEMCI_TIMEOUT=60    tek bir istemci çağrısı için üst sınır
#   E2E_SOGUTMA_MAX=330       devir bekleme süresi (cooldown) için beklenecek en fazla süre
#
# Çıkış kodu (lib.sh/e2e_finish):
#   0 = çalışan kontrollerin hepsi geçti
#   1 = en az bir kontrol kaldı ya da ÖLÇÜLEMEDİ
#   2 = HİÇBİR kontrol çalışmadı (hepsi atlandı). Ayrı kod, çünkü hiçbir şey
#       ölçmemiş yeşil bir koşu, alınabilecek en yanıltıcı sonuçtur.
#   130 = kesildi (lib.sh yakalar; temizlik EXIT üzerinde çalışır)
# =============================================================================
# `set -e` BİLEREK YOK: her kontrol tek tek raporlanmalı, ilk hatada ölmemeli.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env
# Sayaçlar, sonuç bildirimi ve ÇIKIŞ KODU ortak kütüphanede — paketin kendi
# kopyası YOK. Eski hâlde bu betiğin üç sonuç türü vardı (geçti/kaldı/atlandı)
# ve "ölçemedik" için yeri olmadığından ölçüm aracı bozulduğunda kontrol ya
# atlanıyor ya da GEÇMİŞ sayılıyordu.
source scripts/e2e/lib.sh
E2E_SUITE="failover"
# Yardımcı python3 çağrılarının çıktısı SABİT UTF-8 olsun. Yerel ayarı
# UTF-8 olmayan bir kabukta python3 stdout'u kod sayfasına çevirir; ürünün
# olay mesajındaki Türkçe harfler bozulur ve "gerekçe beklenen kapı mı"
# eşleşmesi tutmaz. Sonuç yanlış YEŞİL değil t_unknown olurdu ama yine de
# ölçemediğimiz bir şeyi ölçebiliyoruz.
export PYTHONIOENCODING=utf-8

# ------------------------------------------------------------------ ayarlar --
KUR="${E2E_KUR:-1}"
DEVIR_BEKLE="${E2E_DEVIR_TIMEOUT:-300}"
KAPANIS_BEKLE="${E2E_KAPANIS_TIMEOUT:-180}"
REPLIKA_TO="${E2E_REPLIKA_TIMEOUT:-1800}"
REBUILD_TO="${E2E_REBUILD_TIMEOUT:-1800}"
AKIS_TO="${E2E_AKIS_TIMEOUT:-120}"
ISTEMCI_TO="${E2E_ISTEMCI_TIMEOUT:-60}"
SOGUTMA_MAX="${E2E_SOGUTMA_MAX:-330}"
ELLE_DEVIR_TO="${E2E_ELLE_DEVIR_TIMEOUT:-300}"
# Denetleyicinin kendi ayarları — .env'de ne yazıyorsa devir kararı ona göre
# verilir. Beklediğimiz süreleri bunlardan hesaplıyoruz ki sabit yazılmış bir
# "60 saniye" FAILOVER_STRIKES=10 olan bir kurulumda testi yanlışlıkla
# başarısız göstermesin.
SOGUTMA="${FAILOVER_COOLDOWN:-300}"
LUTUF="${FAILOVER_STARTUP_GRACE:-120}"
VURUS="${FAILOVER_STRIKES:-3}"
ARALIK="${FAILOVER_INTERVAL:-10}"

TABLO="e2e_failover"                  # SQL motorlarında test tablosu
ANAHTAR_ONEK="e2e:failover"           # Redis'te test anahtarı öneki
KOSU="$(date +%s)-$$"                 # bu koşunun damgası (değer karşılaştırması için)
AS_ONCE="devir-oncesi"
AS_KAPI="kapi-testi"
AS_ONARIM="kapi-onarim"
AS_SONRA="devir-sonrasi"
AS_REBUILD="rebuild-sonrasi"
TMP="$(mktemp -d)" || { printf 'geçici dizin açılamadı\n' >&2; exit 1; }

# ------------------------------------------------- durdurulan düğüm defteri --
# Betik bir düğümü durdurursa bunu YAZAR. Kesilirse (Ctrl-C) ya da bir adım
# beklenmedik biçimde biterse geri açar: kullanıcının veritabanını kapalı
# bırakan bir test aracı, hatanın kendisidir.
DURDURULAN=()

# Temizlik YALNIZ EXIT üzerinde. INT/TERM lib.sh'in: kesilen koşu "geçti"
# sayılmasın diye 130 ile çıkıyor ve o çıkış zaten bu trap'i tetikliyor.
# Buraya INT/TERM yazmak lib.sh'in trap'ini ezer, Ctrl-C'yi sessiz bir başarıya
# çevirirdi.
cikis_temizligi() {
    local c
    for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
        warn "betiğin durdurduğu $c geri açılıyor"
        docker start "$c" >/dev/null 2>&1 || warn "  $c AÇILAMADI — elle: docker start $c"
    done
    rm -rf "$TMP"
}
trap cikis_temizligi EXIT

# =============================================================================
# ÖLÇÜM ARAÇLARI — "ölçemedik" ile "ölçtük, kötü" burada ayrılır
# =============================================================================
# Komutu çalıştırır; stdout'u OUT, stderr'i ERRT, çıkış kodunu RC'ye koyar.
# Boru hattı YOK: `cmd | tr -d ...` yazan eski hâlde çıkış kodu SON komuttan
# (tr) geliyordu ve istemcinin hiç çalışmaması bile "boş cevap" gibi görünüyordu.
kos() {
    local __e="$TMP/kos.err"
    OUT=""; ERRT=""; RC=0
    OUT="$("$@" 2>"$__e")"; RC=$?
    ERRT="$(cat "$__e" 2>/dev/null)"
    : > "$__e"
    return $RC
}

# Alt kabuk (komut ikamesi) içinde ayarlanan değişkenler kaybolur; sebebi
# dosyaya yazıyoruz ki çağıran taraf t_unknown satırında GERÇEK sebebi yazsın.
_hata_yaz() { printf '%s' "$1" > "$TMP/son_hata"; }
son_hata()  { local h; h="$(cat "$TMP/son_hata" 2>/dev/null)"; printf '%s' "${h:-sebep alınamadı}"; }

ozet_metin() {   # çok satırlı hatayı tek satıra indir, sonunu göster
    printf '%s' "$1" | tr '\n\t' '  ' | tr -s ' ' | tail -c 220
}

# Sayı bekleyip metin almak, `[ "$x" -gt 0 ]` satırını hata verdirip akışı
# sessizce yanlış dala sokar. Beklediğimiz sayı gelmediyse ÖLÇEMEDİK demektir.
sayi_mi() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Ölçüm ARACININ bozulduğu hâller: docker konuşmadı, imaj/ağ/container yok,
# istemci hiç başlamadı. Bunlar ürünün cevabı DEĞİL, bizim körlüğümüzdür.
arac_bozuk() {   # arac_bozuk <rc> <çıktı+hata metni>
    case "$1" in
        124) return 0 ;;                 # zaman aşımı — cevap ALAMADIK
        125|126|127) return 0 ;;         # docker/komut hiç çalışmadı
    esac
    printf '%s' "$2" | grep -qiE 'cannot connect to the docker daemon|is not running|no such container|no such image|unable to find image|network [^ ]* not found|error response from daemon|permission denied while trying to connect|executable file not found' \
        && return 0
    return 1
}

# docker'ın kendisi cevap vermezse "container kapalı" demek yanlıştır:
# 0 = çalışıyor · 1 = çalışmıyor · 2 = DOCKER CEVAP VERMEDİ (ölçemedik)
calisiyor_mu() {
    local liste rc
    liste="$(docker ps --format '{{.Names}}' 2>"$TMP/ps.err")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        _hata_yaz "docker ps çalışmadı (çıkış $rc): $(ozet_metin "$(cat "$TMP/ps.err" 2>/dev/null)")"
        return 2
    fi
    printf '%s\n' "$liste" | grep -qx "$1"
}

# Katalogdan alan oku. Portlar, servis adları, replikasyon/devir yetenekleri
# TEK YETKİ KAYNAĞINDAN gelir; burada sabit yazmak, katalog değiştiğinde
# sessizce yanlış düğümü test etmek demekti.
kat() {   # kat <motor> <python-ifadesi>
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e: sys.exit(1)
v = eval(sys.argv[3], {"e": e[0]})
sys.stdout.write("" if v is None else str(v))' "$CATALOG" "$1" "$2" 2>/dev/null
}

denetlenen_motorlar() {
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
for e in c["engines"]:
    f = e.get("failover", {})
    if f.get("supported") and f.get("mode") == "supervised":
        print(e["id"])' "$CATALOG" 2>/dev/null
}

# state.json bir LİSTE dosyasıdır; "listede yok" ile "dosyayı okuyamadım"
# aynı şey değildir. Eski hâlde ikisi de 1 dönüyordu ve okunamayan bir
# state.json "replikasyon kurulu değil" diye raporlanıyordu.
durum_listesinde() {   # 0 = var · 1 = yok · 2 = ÖLÇEMEDİK
    python3 -c '
import json, os, sys
yol = sys.argv[1]
if not os.path.exists(yol):
    sys.exit(1)          # dosya hiç yok: hiçbir profil kurulmamış (ölçüm)
try:
    s = json.load(open(yol, encoding="utf-8"))
except Exception:
    sys.exit(2)          # dosya var ama okunamadı: ÖLÇEMEDİK
sys.exit(0 if sys.argv[3] in (s.get(sys.argv[2]) or []) else 1)' \
        "$STACK_ROOT/state/state.json" "$1" "$2" 2>/dev/null
    local rc=$?
    [ "$rc" -le 2 ] || rc=2
    [ "$rc" -eq 2 ] && _hata_yaz "state/state.json okunamadı (bozuk JSON ya da izin yok)"
    return $rc
}

profil_kurulu()   { durum_listesinde profiles       "$1"; }
oto_devir_acik()  { durum_listesinde auto_failover  "$1"; }

# ŞU ANKİ ana kopya. common.sh'teki primary_of, topology.json okunamazsa MOTOR
# KİMLİĞİNİ basar — yani kataloğun özgün primary'sini. Devirden SONRA bu, eski
# ana kopyanın adının geri gelmesi demektir: ikinci koşuda "ana kopya değişti"
# kontrolü ölçüm hatasıyla YEŞİL yanıyor, üstelik öldürülen düğüm "fence
# edilmiş" sayılıp geri-açma defterinden düşürülüyordu (veritabanı kapalı
# kalıyordu). Burada tahmin yok: okuyamadıysak okuyamadığımızı söylüyoruz.
prim_oku() {   # prim_oku <motor> → stdout: container adı; 0 = ölçtük · 1 = ÖLÇEMEDİK
    local vars cikti rc
    vars="$(kat "$1" 'e["primary_service"]')"
    if [ -z "$vars" ]; then
        _hata_yaz "catalog.json okunamadı — $1 için primary_service alınamadı"
        return 1
    fi
    cikti="$(python3 -c '
import json, os, sys
yol, eid, varsayilan = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.exists(yol):
    sys.stdout.write(varsayilan); sys.exit(0)   # hiç devir yaşanmamış
try:
    t = json.load(open(yol, encoding="utf-8"))
except Exception:
    sys.exit(3)                                  # dosya var, okunamadı
k = t.get(eid) or {}
p = k.get("primary") or varsayilan
if not isinstance(p, str) or not p:
    sys.exit(3)
sys.stdout.write(p)' "$STACK_ROOT/state/topology.json" "$1" "$vars" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$cikti" ]; then
        _hata_yaz "state/topology.json okunamadı (python3 çıkışı $rc) — ana kopyanın kim olduğunu ölçemedik"
        return 1
    fi
    printf '%s' "$cikti"
    return 0
}

# Devirden sonra roller terstir: kataloğun "replica_service"i canlı ana kopya
# olabilir. Yedek düğümü her zaman ŞU ANKİ ana kopyaya göre hesaplıyoruz —
# sabit ad kullanan bir test, ikinci koşuda yanlış düğümü durdururdu.
yedek_dugum() {   # yedek_dugum <motor> <şu anki primary>
    if [ "$2" = "$M_PRIM_SVC" ]; then printf '%s' "$M_REP_SVC"
    else printf '%s' "$M_PRIM_SVC"; fi
}

# Denetleyicinin devir bekleme süresinden (cooldown) kaç saniye kaldı.
# Betik üst üste çalıştırıldığında ikinci koşu bu yüzden devir yapamaz.
# Dosya YOKSA hiç devir denenmemiş demektir (0, ölçüm); dosya VAR ama
# okunamıyorsa devir yapılıp yapılmayacağını ÖLÇEMEYİZ — o hâlde canlı ana
# kopyayı öldürmeyiz.
sogutma_kalan() {   # stdout: kalan sn · 0 = ölçtük · 2 = ÖLÇEMEDİK
    local cikti rc
    cikti="$(python3 -c '
import json, os, sys, time
yol = sys.argv[1]
if not os.path.exists(yol):
    print(0); sys.exit(0)
try:
    g = json.load(open(yol, encoding="utf-8"))
except Exception:
    sys.exit(3)
try:
    son = float(g.get(sys.argv[2], 0))
except (TypeError, ValueError):
    sys.exit(3)
kalan = int(son + int(sys.argv[3]) - time.time())
print(kalan if kalan > 0 else 0)' \
        "$STACK_ROOT/state/failover-guard.json" "$1" "$SOGUTMA" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$cikti" ]; then
        _hata_yaz "state/failover-guard.json okunamadı — denetleyicinin devir bekleme süresini ölçemedik"
        return 2
    fi
    printf '%s' "$cikti"
    return 0
}

# Controller yeni açıldıysa (sunucu reboot'u, ./install.sh) FAILOVER_STARTUP_GRACE
# boyunca hiç devir kararı vermez. Beklediğimiz süreye bunu EKLEMEZSEK test,
# ürünün doğru davranışını "devir olmadı" diye raporlardı. Okuyamazsak EN KÖTÜYÜ
# varsayıp tam lütuf süresini ekleriz: ölçemediğimiz için ürünü suçlamayız.
lutuf_kalan() {   # stdout: sn · 0 = ölçtük · 1 = ölçemedik (tam lütuf basıldı)
    local basladi t simdi k
    basladi="$(docker inspect -f '{{.State.StartedAt}}' controller 2>/dev/null)" || basladi=""
    [ -n "$basladi" ] || { printf '%s' "$LUTUF"; return 1; }
    t="$(date -d "$basladi" +%s 2>/dev/null)" || t=""
    [ -n "$t" ] || { printf '%s' "$LUTUF"; return 1; }
    simdi="$(date +%s)"
    k=$(( LUTUF - (simdi - t) ))
    if [ "$k" -gt 0 ]; then printf '%s' "$k"; else printf '0'; fi
    return 0
}

# Olay kaydı — reddedilen bir devir SESSİZ kalmamalı. Ürünün en pahalı
# hatalarından biri buydu: gece 03:00'te devir "yedek hazır değil" diye
# vazgeçiyor, hiçbir yere yazılmıyor, operatör durumu uygulama şikâyetiyle
# öğreniyordu. Betik için ikinci bir işi daha var: REDDİN GEREKÇESİ buradan
# okunur — controller tüm ret yollarında aynı kind'ı yazdığı için, hangi
# kapının çalıştığını yalnız mesaj ayırt eder.
olay_bul() {   # olay_bul <motor> <kind> <ts_alt> → SON eşleşen mesaj; 0=var 1=yok 2=okunamadı
    python3 -c '
import json, sys
try:
    satirlar = open(sys.argv[1], encoding="utf-8").read().splitlines()[-800:]
except OSError:
    sys.exit(2)
son = None
for s in satirlar:
    try:
        e = json.loads(s)
    except ValueError:
        continue
    try:
        ts = int(e.get("ts", 0))
    except (TypeError, ValueError):
        continue
    if (e.get("engine") == sys.argv[2] and e.get("kind") == sys.argv[3]
            and ts >= int(sys.argv[4])):
        son = e.get("message") or ""
if son is None:
    sys.exit(1)
sys.stdout.write(son[:400])' "$STACK_ROOT/state/events.jsonl" "$1" "$2" "$3" 2>/dev/null
}

# Hiçbir bekleme sonsuz değildir; beklerken NE beklediğimizi yazarız, çünkü
# "takıldı mı, sürüyor mu" ayrımını yapamayan bir test aracı işkencedir.
bekle() {   # bekle <saniye> <ne bekleniyor> <komut…>
    local sure="$1" ne="$2"; shift 2
    local son=$((SECONDS + sure)) tur=0
    while :; do
        if "$@"; then return 0; fi
        if [ "$SECONDS" -ge "$son" ]; then
            warn "zaman aşımı (${sure} sn): $ne"
            return 1
        fi
        tur=$((tur + 1))
        if [ $((tur % 5)) -eq 0 ]; then
            printf '   … bekleniyor (%d/%d sn): %s\n' "$((sure - son + SECONDS))" "$sure" "$ne"
        fi
        sleep 3
    done
}

uyu_sayarak() {   # uyu_sayarak <saniye> <sebep>
    local kalan="$1"
    while [ "$kalan" -gt 0 ]; do
        printf '   … %s — %d sn kaldı\n' "$2" "$kalan"
        sleep 10
        kalan=$((kalan - 10))
    done
}

dugum_durdur() {   # 0 = gerçekten durdu · 2 = ÖLÇEMEDİK/durduramadık
    local c="$1" rc
    DURDURULAN+=("$c")      # ÖNCE deftere: yarıda kesilirse bile geri açılır
    kos docker stop -t 15 "$c"
    if [ "$RC" -ne 0 ]; then
        _hata_yaz "docker stop $c başarısız (çıkış $RC): $(ozet_metin "$ERRT$OUT")"
        return 2
    fi
    calisiyor_mu "$c"; rc=$?
    case "$rc" in
        1) return 0 ;;                       # durdu — ölçtük
        0) _hata_yaz "$c 'docker stop' sonrası hâlâ çalışıyor"; return 2 ;;
        *) return 2 ;;                       # docker cevap vermedi (sebep yazıldı)
    esac
}

dugum_baslat() {   # 0 = açıldı · 2 = açılamadı
    local c="$1" rc
    kos docker start "$c"
    if [ "$RC" -ne 0 ]; then
        _hata_yaz "docker start $c başarısız (çıkış $RC): $(ozet_metin "$ERRT$OUT")"
        return 2
    fi
    calisiyor_mu "$c"; rc=$?
    if [ "$rc" -eq 0 ]; then dugum_unut "$c"; return 0; fi
    [ "$rc" -eq 1 ] && _hata_yaz "$c 'docker start' sonrası çalışmıyor"
    return 2
}

dugum_unut() {   # devirden sonra fence edilmiş eski primary'yi GERİ AÇMAYIZ
    local yeni=() c
    for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
        [ "$c" = "$1" ] || yeni+=("$c")
    done
    DURDURULAN=(${yeni[@]+"${yeni[@]}"})
}

# =============================================================================
# MOTOR BAĞLAMI — her şey katalogdan + .env'den
# =============================================================================
motor_baglami() {   # 0 = bağlam kuruldu · 1 = KATALOG OKUNAMADI
    local eid="$1" pv
    M_AD="$(kat "$eid" 'e["name"]')"
    M_PRIM_SVC="$(kat "$eid" 'e["primary_service"]')"
    M_REP_SVC="$(kat "$eid" 'e["replication"].get("replica_service") or ""')"
    M_REP_PROFIL="$(kat "$eid" 'e["replication"].get("profile") or ""')"
    M_LISTEN="$(kat "$eid" 'e["route"][0]["listen"]')"
    M_BETIK="$(kat "$eid" 'e["failover"].get("promote_script") or e["id"]')"
    M_KULLANICI="$(kat "$eid" 'e["connection"]["username"]')"
    M_VTABANI="$(kat "$eid" 'e["connection"]["database"]')"
    pv="$(kat "$eid" 'e["connection"]["password_env"]')"
    [ -n "$M_PRIM_SVC" ] && [ -n "$M_LISTEN" ] || return 1
    FO_BETIK_YOLU="$STACK_ROOT/scripts/failover/$M_BETIK.sh"

    # Parola: compose'daki kural neyse o — motora özel değer boşsa DB_PASSWORD.
    M_PAROLA="${!pv:-}"
    [ -n "$M_PAROLA" ] || M_PAROLA="${DB_PASSWORD:-}"
    M_PAROLA_ENV="$pv"
    # Kullanıcı/veritabanı adı .env'de değiştirilmiş olabilir (compose da
    # oradan okur); katalog varsayılanı yalnız yedek plan.
    M_VTABANI="${DEFAULT_DATABASE:-$M_VTABANI}"
    if [ "$eid" = "postgresql" ]; then M_KULLANICI="${POSTGRES_USER:-$M_KULLANICI}"; fi
    # Ürünün devir betikleri parolayı `${MOTOR_PASSWORD:-$DB_PASSWORD}` diye okur
    # ve `set -u` ile çalışır: DB_PASSWORD .env'de hiç tanımlı değilse betik
    # parola hatası değil "unbound variable" ile ölür. Testin ölçtüğü şey bu
    # olmasın diye tanımsızsa motorun kendi parolasını veriyoruz.
    export DB_PASSWORD="${DB_PASSWORD:-$M_PAROLA}"
    M_IMAJ=""
    return 0
}

# İstemci imajı: motorun KENDİ container'ının imajı. Böylece host'a hiçbir
# veritabanı istemcisi kurulmadan, sürüm uyumu da garanti biçimde sorgu
# çalıştırılabilir (imaj zaten yerelde vardır, indirme beklenmez).
motor_imaji() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }

# =============================================================================
# ÜRÜNÜN KENDİ ÖLÇÜLERİ — testin kendi ölçüsünü uydurması yerine
# controller'ın kullandığı betik: check = yazılabilir ana kopya mı?
#                                  ready = yükseltilebilir mi?
# =============================================================================
fo_calistir() {   # fo_calistir <faz> <servis> → OUT/ERRT/RC ; RC=3 → betik YOK
    if [ ! -f "$FO_BETIK_YOLU" ]; then
        OUT=""; ERRT="yükseltme betiği yok: $FO_BETIK_YOLU"; RC=3
        return 3
    fi
    kos timeout 150 sh "$FO_BETIK_YOLU" "$1" "$2"
}
fo_sessiz() { fo_calistir "$1" "$2" >/dev/null 2>&1; }

# Düğümün rolünü DOĞRUDAN sorar. "Ayakta ama sorgulanamayan" bir düğümü
# "yedek rolünde" saymak, split-brain kontrolünü tam da split-brain varken
# yeşil yakardı: 0 = ölçtük (stdout: ana|yedek) · 2 = ÖLÇEMEDİK
rol_sor() {   # rol_sor <motor> <container>
    local eid="$1" c="$2" v rc
    case "$eid" in
    mariadb)
        export MYSQL_PWD="$M_PAROLA"
        kos timeout "$ISTEMCI_TO" docker exec -e MYSQL_PWD "$c" \
            mariadb -u "$M_KULLANICI" -N -B -e "SELECT @@read_only;"
        rc=$?; unset MYSQL_PWD
        v="$(printf '%s' "$OUT" | tr -d '[:space:]')"
        if [ "$rc" -ne 0 ]; then _hata_yaz "$c rolü sorulamadı: $(ozet_metin "$ERRT$OUT")"; return 2; fi
        case "$v" in
            0) printf 'ana' ;;
            1) printf 'yedek' ;;
            *) _hata_yaz "$c: @@read_only beklenmedik değer döndü: '${v:-boş}'"; return 2 ;;
        esac
        ;;
    postgresql)
        export PGPASSWORD="$M_PAROLA"
        kos timeout "$ISTEMCI_TO" docker exec -e PGPASSWORD "$c" \
            psql -U "$M_KULLANICI" -d postgres -w -tAc "SELECT pg_is_in_recovery();"
        rc=$?; unset PGPASSWORD
        v="$(printf '%s' "$OUT" | tr -d '[:space:]')"
        if [ "$rc" -ne 0 ]; then _hata_yaz "$c rolü sorulamadı: $(ozet_metin "$ERRT$OUT")"; return 2; fi
        case "$v" in
            f) printf 'ana' ;;
            t) printf 'yedek' ;;
            *) _hata_yaz "$c: pg_is_in_recovery() beklenmedik değer döndü: '${v:-boş}'"; return 2 ;;
        esac
        ;;
    redis)
        export REDISCLI_AUTH="$M_PAROLA"
        kos timeout "$ISTEMCI_TO" docker exec -e REDISCLI_AUTH "$c" \
            redis-cli --no-auth-warning INFO replication
        rc=$?; unset REDISCLI_AUTH
        if [ "$rc" -ne 0 ]; then _hata_yaz "$c rolü sorulamadı: $(ozet_metin "$ERRT$OUT")"; return 2; fi
        if printf '%s' "$OUT" | grep -q 'role:master'; then printf 'ana'
        elif printf '%s' "$OUT" | grep -q 'role:slave'; then printf 'yedek'
        else _hata_yaz "$c: INFO replication içinde rol satırı yok: $(ozet_metin "$OUT")"; return 2; fi
        ;;
    *) _hata_yaz "$eid için rol sorgusu tanımlı değil"; return 2 ;;
    esac
    return 0
}

# =============================================================================
# VERİ YAZ / OKU
# =============================================================================
# gw_* → GATEWAY üzerinden (uygulamanın gördüğü adres; devirde değişmemeli)
# dugum_* → doğrudan container'ın içinden (replikasyon gerçekten aktı mı?)
# Üçü de aynı sözleşmeyi taşır: 0 = ölçtük · 1 = ürün reddetti · 2 = ÖLÇEMEDİK

_mariadb_gw() {   # _mariadb_gw <sql>
    local rc
    export MYSQL_PWD="$M_PAROLA"
    kos timeout "$ISTEMCI_TO" docker run --rm --network "$AG" -e MYSQL_PWD \
        --entrypoint mariadb "$M_IMAJ" -h gateway -P "$M_LISTEN" \
        -u "$M_KULLANICI" -D "$M_VTABANI" --connect-timeout=10 -N -B -e "$1"
    rc=$?; unset MYSQL_PWD; return $rc
}
_pg_gw() {        # _pg_gw <sql>
    local rc
    export PGPASSWORD="$M_PAROLA"
    kos timeout "$ISTEMCI_TO" docker run --rm --network "$AG" -e PGPASSWORD \
        --entrypoint psql "$M_IMAJ" -h gateway -p "$M_LISTEN" \
        -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAq -c "$1"
    rc=$?; unset PGPASSWORD; return $rc
}
_redis_gw() {     # _redis_gw <redis-cli argümanları…>
    local rc
    export REDISCLI_AUTH="$M_PAROLA"
    kos timeout "$ISTEMCI_TO" docker run --rm --network "$AG" -e REDISCLI_AUTH \
        --entrypoint redis-cli "$M_IMAJ" --no-auth-warning \
        -h gateway -p "$M_LISTEN" "$@"
    rc=$?; unset REDISCLI_AUTH; return $rc
}
_mariadb_dugum() {   # _mariadb_dugum <container> <sql>
    local rc
    export MYSQL_PWD="$M_PAROLA"
    kos timeout "$ISTEMCI_TO" docker exec -e MYSQL_PWD "$1" \
        mariadb -u "$M_KULLANICI" -D "$M_VTABANI" -N -B -e "$2"
    rc=$?; unset MYSQL_PWD; return $rc
}
_pg_dugum() {        # _pg_dugum <container> <sql>
    local rc
    export PGPASSWORD="$M_PAROLA"
    kos timeout "$ISTEMCI_TO" docker exec -e PGPASSWORD "$1" \
        psql -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAc "$2"
    rc=$?; unset PGPASSWORD; return $rc
}
_redis_dugum() {     # _redis_dugum <container> <redis-cli argümanları…>
    local c="$1" rc; shift
    export REDISCLI_AUTH="$M_PAROLA"
    kos timeout "$ISTEMCI_TO" docker exec -e REDISCLI_AUTH "$c" \
        redis-cli --no-auth-warning "$@"
    rc=$?; unset REDISCLI_AUTH; return $rc
}

gw_yaz() {   # gw_yaz <motor> <asama> <deger> → 0 yazıldı · 1 yazılamadı · 2 ÖLÇEMEDİK
    local eid="$1" asama="$2" deger="$3" rc
    case "$eid" in
    mariadb)
        _mariadb_gw "CREATE TABLE IF NOT EXISTS $TABLO (asama VARCHAR(64) PRIMARY KEY, damga VARCHAR(96) NOT NULL) ENGINE=InnoDB;
             REPLACE INTO $TABLO (asama, damga) VALUES ('$asama', '$deger');"
        ;;
    postgresql)
        _pg_gw "CREATE TABLE IF NOT EXISTS $TABLO (asama text PRIMARY KEY, damga text NOT NULL);
             INSERT INTO $TABLO (asama, damga) VALUES ('$asama', '$deger')
             ON CONFLICT (asama) DO UPDATE SET damga = EXCLUDED.damga;"
        ;;
    redis)
        _redis_gw SET "$ANAHTAR_ONEK:$asama" "$deger"
        ;;
    *) _hata_yaz "$eid için yazma yolu tanımlı değil"; return 2 ;;
    esac
    rc=$?
    if arac_bozuk "$rc" "$ERRT$OUT"; then
        _hata_yaz "istemci çalıştırılamadı (çıkış $rc): $(ozet_metin "$ERRT$OUT")"; return 2
    fi
    if [ "$rc" -ne 0 ]; then
        _hata_yaz "yazma başarısız (çıkış $rc): $(ozet_metin "$ERRT$OUT")"; return 1
    fi
    # redis-cli çıkış kodu her sürümde hatayı yansıtmıyor; read-only bir düğüme
    # yazınca "-READONLY …" basıp 0 döner. Bu yüzden ÇIKTIYA bakıyoruz.
    if [ "$eid" = "redis" ] && [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" != "OK" ]; then
        _hata_yaz "redis-cli 'OK' demedi: $(ozet_metin "$OUT$ERRT")"; return 1
    fi
    return 0
}

gw_oku() {   # gw_oku <motor> <asama> → stdout: değer · 0 ölçtük · 2 ÖLÇEMEDİK
    local eid="$1" asama="$2" rc
    case "$eid" in
    mariadb)    _mariadb_gw "SELECT damga FROM $TABLO WHERE asama = '$asama';" ;;
    postgresql) _pg_gw "SELECT damga FROM $TABLO WHERE asama = '$asama';" ;;
    redis)      _redis_gw GET "$ANAHTAR_ONEK:$asama" ;;
    *) _hata_yaz "$eid için okuma yolu tanımlı değil"; return 2 ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _hata_yaz "gateway:$M_LISTEN üzerinden okunamadı (çıkış $rc): $(ozet_metin "$ERRT$OUT")"
        return 2
    fi
    printf '%s' "$(printf '%s' "$OUT" | tr -d '[:space:]')"
    return 0
}

dugum_oku() {   # dugum_oku <motor> <container> <asama> → stdout: değer · 0/2
    local eid="$1" c="$2" asama="$3" rc
    case "$eid" in
    mariadb)    _mariadb_dugum "$c" "SELECT damga FROM $TABLO WHERE asama = '$asama';" ;;
    postgresql) _pg_dugum "$c" "SELECT damga FROM $TABLO WHERE asama = '$asama';" ;;
    redis)      _redis_dugum "$c" GET "$ANAHTAR_ONEK:$asama" ;;
    *) _hata_yaz "$eid için düğüm okuma yolu tanımlı değil"; return 2 ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _hata_yaz "$c içinden okunamadı (çıkış $rc): $(ozet_metin "$ERRT$OUT")"
        return 2
    fi
    printf '%s' "$(printf '%s' "$OUT" | tr -d '[:space:]')"
    return 0
}

# Karşılaştırmalı bekleme yüklemleri (bekle() bunları çağırır). ÖLÇEMEDİK hâli
# burada "eşit değil" gibi davranır: bekleme sürer, sonunda çağıran taraf tek
# bir sınıflandırılmış ölçüm daha yapıp t_fail mi t_unknown mı olduğunu söyler.
_gw_es()      { [ "$(gw_oku "$1" "$2")" = "$3" ]; }
_dugum_es()   { [ "$(dugum_oku "$1" "$2" "$3")" = "$4" ]; }
_gw_yazilir() { gw_yaz "$1" "$2" "$3" && _gw_es "$1" "$2" "$3"; }

test_verisi_sil() {   # gateway üzerinden siler → silme de replikaya akar
    local eid="$1"
    case "$eid" in
    mariadb)    _mariadb_gw "DROP TABLE IF EXISTS $TABLO;" ;;
    postgresql) _pg_gw "DROP TABLE IF EXISTS $TABLO;" ;;
    redis)      _redis_gw DEL "$ANAHTAR_ONEK:$AS_ONCE" "$ANAHTAR_ONEK:$AS_KAPI" \
                    "$ANAHTAR_ONEK:$AS_ONARIM" "$ANAHTAR_ONEK:$AS_SONRA" \
                    "$ANAHTAR_ONEK:$AS_REBUILD" ;;
    esac
}

# "yok" | "var" | "sorulamadi"
# Üçüncü hâl ŞART: sorgu hiç çalışmadıysa (gateway ölü, motor kapalı) boş cevap
# gelir ve "boş = silinmiş" saymak, geride kalan test tablosunu temizlenmiş
# gibi raporlardı — yani temizlik testi tam da temizlik yapılamayan durumda
# yeşil yanardı.
test_verisi_durumu() {
    local eid="$1" c rc
    case "$eid" in
    mariadb)
        _mariadb_gw "SELECT COUNT(*) FROM information_schema.TABLES
              WHERE table_schema = DATABASE() AND table_name = '$TABLO';" ;;
    postgresql)
        _pg_gw "SELECT COUNT(*) FROM pg_class WHERE relname = '$TABLO';" ;;
    redis)
        _redis_gw EXISTS "$ANAHTAR_ONEK:$AS_ONCE" "$ANAHTAR_ONEK:$AS_KAPI" \
            "$ANAHTAR_ONEK:$AS_ONARIM" "$ANAHTAR_ONEK:$AS_SONRA" \
            "$ANAHTAR_ONEK:$AS_REBUILD" ;;
    *) printf 'sorulamadi'; return ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _hata_yaz "sorgu çalışmadı (çıkış $rc): $(ozet_metin "$ERRT$OUT")"
        printf 'sorulamadi'; return
    fi
    c="$(printf '%s' "$OUT" | tr -d '[:space:]')"
    case "$c" in
        ""|*[!0-9]*) _hata_yaz "beklenen sayı yerine '${c:-boş}' geldi"; printf 'sorulamadi' ;;
        0)   printf 'yok' ;;
        *)   printf 'var' ;;
    esac
}

# =============================================================================
# 1) ÖN KOŞULLAR — yedek kopya + otomatik devir
# =============================================================================
onkosullar() {   # 0 = zincire devam edilebilir
    local eid="$1" prim rc yedek

    prim="$(prim_oku "$eid")" || {
        t_unknown "$eid: devir zinciri" "$(son_hata)"
        return 1
    }
    calisiyor_mu "$prim"; rc=$?
    case "$rc" in
        0) ;;
        1) t_skip "$eid: devir zinciri" \
                  "motor kapalı ($prim çalışmıyor). Açmak için: ./stack.sh enable $eid"
           return 1 ;;
        *) t_unknown "$eid: devir zinciri" "$(son_hata)"; return 1 ;;
    esac
    if [ -z "$M_PAROLA" ]; then
        t_unknown "$eid: devir zinciri" \
                  "$M_PAROLA_ENV ve DB_PASSWORD boş — istemci bağlanamaz, HİÇBİR ölçüm yapılamaz"
        return 1
    fi
    M_IMAJ="$(motor_imaji "$prim")"
    if [ -z "$M_IMAJ" ]; then
        t_unknown "$eid: devir zinciri" \
                  "$prim container'ının imajı okunamadı (docker inspect) — sorgu çalıştıracak istemcimiz yok"
        return 1
    fi
    if [ -z "$M_REP_SVC" ] || [ -z "$M_REP_PROFIL" ]; then
        t_skip "$eid: devir zinciri" "katalogda replika servisi/profili tanımlı değil"
        return 1
    fi

    # --- yedek kopya --------------------------------------------------------
    # Yoksa ÜRÜNÜN KENDİ komutuyla kurulur; sessizce geçilmez. Kurulum ürünün
    # arayüzünden geçtiği için testin kendisi de bir kullanım senaryosudur.
    profil_kurulu "$M_REP_PROFIL"; rc=$?
    if [ "$rc" -eq 2 ]; then
        t_unknown "$eid: yedek kopya ayakta ve replikasyon profili etkin" "$(son_hata)"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        if [ "$KUR" != "1" ]; then
            t_skip "$eid: devir zinciri" \
                   "yedek kopya kurulu değil ve E2E_KUR=0. Kurmak için: ./stack.sh replica on $eid"
            return 1
        fi
        log "$eid: yedek kopya kurulu değil — './stack.sh replica on $eid' çalıştırılıyor"
        log "   (ilk kopyalama veritabanı büyüklüğüne göre dakikalar sürebilir; üst sınır ${REPLIKA_TO} sn)"
        timeout "$REPLIKA_TO" ./stack.sh replica on "$eid" > "$TMP/replica.log" 2>&1
        rc=$?
        if [ "$rc" -eq 124 ]; then
            t_unknown "$eid: yedek kopya kuruldu (./stack.sh replica on)" \
                      "kurulum ${REPLIKA_TO} sn'de bitmedi (E2E_REPLIKA_TIMEOUT); sürüyor olabilir — sonuç ÖLÇÜLEMEDİ"
            return 1
        fi
        if [ "$rc" -ne 0 ]; then
            t_fail "$eid: yedek kopya kuruldu (./stack.sh replica on)" \
                   "kurulum başarısız (çıkış $rc): $(ozet_metin "$(tail -n 3 "$TMP/replica.log" 2>/dev/null)")"
            return 1
        fi
    fi

    yedek="$(yedek_dugum "$eid" "$prim")"
    profil_kurulu "$M_REP_PROFIL"; local prc=$?
    calisiyor_mu "$yedek"; local crc=$?
    if [ "$prc" -eq 2 ] || [ "$crc" -eq 2 ]; then
        t_unknown "$eid: yedek kopya ayakta ve replikasyon profili etkin" "$(son_hata)"
        return 1
    fi
    if [ "$prc" -eq 0 ] && [ "$crc" -eq 0 ]; then
        t_ok "$eid: yedek kopya ayakta ve replikasyon profili etkin ($yedek / $M_REP_PROFIL)"
    else
        # Yarım kalmış replikasyon en tehlikeli hâldir: dashboard "yedek var"
        # der, devir onu yükseltir ve ESKİ verisini sunmaya başlar.
        t_fail "$eid: yedek kopya ayakta ve replikasyon profili etkin" \
               "profil kurulu mu: $([ "$prc" -eq 0 ] && echo evet || echo hayır), $yedek çalışıyor mu: $([ "$crc" -eq 0 ] && echo evet || echo hayır)"
        return 1
    fi

    # --- otomatik devir -----------------------------------------------------
    OTO_BIZ_ACTIK=0
    oto_devir_acik "$eid"; rc=$?
    if [ "$rc" -eq 1 ]; then
        log "$eid: otomatik devir kapalı — './stack.sh failover on $eid' çalıştırılıyor"
        if timeout 120 ./stack.sh failover on "$eid" > "$TMP/oto.log" 2>&1; then
            OTO_BIZ_ACTIK=1
        fi
        oto_devir_acik "$eid"; rc=$?
    fi
    case "$rc" in
    0) t_ok "$eid: otomatik devir açık — denetleyici ana kopyayı izliyor (state.json/auto_failover)" ;;
    1) t_fail "$eid: otomatik devir açık" \
              "açılamadı: $(ozet_metin "$(tail -n 2 "$TMP/oto.log" 2>/dev/null)")"
       return 1 ;;
    *) t_unknown "$eid: otomatik devir açık" "$(son_hata)"; return 1 ;;
    esac
    return 0
}

# =============================================================================
# 2) TEMEL: gateway üzerinden yaz → replikada gör
# =============================================================================
temel_veri() {   # 0 = devam
    local eid="$1" prim yedek rc deger

    prim="$(prim_oku "$eid")" || { t_unknown "$eid: devir zinciri" "$(son_hata)"; return 1; }
    yedek="$(yedek_dugum "$eid" "$prim")"

    gw_yaz "$eid" "$AS_ONCE" "$KOSU-once"; rc=$?
    if [ "$rc" -eq 2 ]; then
        t_unknown "$eid: gateway:$M_LISTEN üzerinden yazılan satır aynı adresten geri okundu (devir öncesi)" \
                  "$(son_hata)"
        t_skip "$eid: devir zincirinin kalanı" "temel yazma ÖLÇÜLEMEDEN ana kopya öldürülmez"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        t_fail "$eid: gateway:$M_LISTEN üzerinden yazılan satır aynı adresten geri okundu (devir öncesi)" \
               "gateway üzerinden yazılamadı: $(son_hata)"
        t_skip "$eid: devir zincirinin kalanı" "temel yazma çalışmadan ana kopya öldürülmez"
        return 1
    fi
    deger="$(gw_oku "$eid" "$AS_ONCE")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        t_unknown "$eid: gateway:$M_LISTEN üzerinden yazılan satır aynı adresten geri okundu (devir öncesi)" \
                  "$(son_hata)"
        t_skip "$eid: devir zincirinin kalanı" "temel okuma ÖLÇÜLEMEDEN ana kopya öldürülmez"
        return 1
    fi
    if [ "$deger" = "$KOSU-once" ]; then
        t_ok "$eid: gateway:$M_LISTEN üzerinden yazılan satır aynı adresten geri okundu (devir öncesi)"
    else
        t_fail "$eid: gateway:$M_LISTEN üzerinden yazılan satır aynı adresten geri okundu (devir öncesi)" \
               "beklenen '$KOSU-once', okunan '${deger:-(boş)}' — yönlendirme bozuksa devir testi anlamsız olur"
        t_skip "$eid: devir zincirinin kalanı" "temel yazma/okuma çalışmadan ana kopya öldürülmez"
        return 1
    fi

    if bekle "$AKIS_TO" "'$AS_ONCE' satırı $yedek düğümüne ulaşsın (replikasyon)" \
             _dugum_es "$eid" "$yedek" "$AS_ONCE" "$KOSU-once"; then
        t_ok "$eid: devir öncesi yazılan satır yedek kopyada ($yedek) göründü — replikasyon akıyor"
        return 0
    fi
    # Bekleme bitti: SON bir ölçüm daha yapıp "yanlış değer" ile "hiç
    # ölçemedik"i ayırıyoruz. Eski hâlde ikisi de aynı [KALDI] satırıydı.
    deger="$(dugum_oku "$eid" "$yedek" "$AS_ONCE")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        t_unknown "$eid: devir öncesi yazılan satır yedek kopyada ($yedek) göründü" "$(son_hata)"
    else
        t_fail "$eid: devir öncesi yazılan satır yedek kopyada ($yedek) göründü" \
               "beklenen '$KOSU-once', okunan '${deger:-(boş)}' — replikasyon akmıyor; bu hâldeyken devir veri kaybıdır"
    fi
    t_skip "$eid: devir zincirinin kalanı" \
           "replikasyon akmıyorken (ya da ölçülemezken) ana kopyayı öldürmek gerçek veri kaybı riskidir"
    return 1
}

# =============================================================================
# 3) GÜVENLİK KAPISI — yükseltilecek sağlam kopya yokken devir YAPILMAMALI
# =============================================================================
# Bu kapı olmadan gerçek bir sunucuda veri kaybedildi: senkron olmamış replika
# yükseltildi, ana kopya fence edildi ve aradaki yazılar bir daha görülmedi.
#
# NE ÖLÇTÜĞÜMÜZÜ ADIYLA SÖYLÜYORUZ. Controller'ın iki ayrı ret kapısı var ve
# ikisi de aynı kind='failover_blocked' kaydını yazıyor:
#   (a) yedek container ÇALIŞMIYOR            → app.py: nstat != "running"
#   (b) yedek çalışıyor ama HAZIR DEĞİL       → app.py: `sh <betik> ready` != 0
# MariaDB'de (b)'yi üretebiliyoruz (SQL iş parçacığını durdurmak tam olarak o
# hâldir). PostgreSQL/Redis'te replikayı ayakta bırakıp ürünün 'ready' ölçüsünü
# düşürmenin yıkıcı olmayan bir yolu yok (pg 'hiç WAL almamış', redis
# 'offset<=0' arıyor; ikisi de ancak veriyi yok ederek üretilir). Orada (a)
# kapısını ölçüyoruz ve (b)'yi AÇIKÇA atlanmış sayıyoruz — eski hâlde ikisi de
# "replikasyon sağlıksızken devir REDDEDİLDİ" diye raporlanıyordu, yani
# ölçülmeyen bir kapı ölçülmüş gibi görünüyordu.
guvenlik_kapisi() {   # 0 = zincire devam edilebilir
    local eid="$1" prim yedek ts0 rc
    local kapi_ad bozma bekleneni

    prim="$(prim_oku "$eid")" || { t_unknown "$eid: güvenlik kapısı" "$(son_hata)"; return 1; }
    yedek="$(yedek_dugum "$eid" "$prim")"
    ts0="$(date +%s)"

    if [ ! -f "$FO_BETIK_YOLU" ]; then
        t_unknown "$eid: güvenlik kapısı" \
                  "ürünün yükseltme betiği yok: $FO_BETIK_YOLU — kapının ölçüsünü çalıştıramayız"
        return 1
    fi

    case "$eid" in
    mariadb)
        # SQL iş parçacığını durdurmak, "container ayakta ama replikasyon
        # akmıyor" hâlinin birebir kendisidir — devir betiğinin 'ready' kapısı
        # tam olarak bunu yakalamalı.
        _mariadb_dugum "$yedek" "STOP SLAVE SQL_THREAD;" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            t_unknown "$eid: replikasyon sağlıksızken devir REDDEDİLİR ('ready' kapısı)" \
                      "replikasyonu bozamadık (STOP SLAVE SQL_THREAD çıkış $rc): $(ozet_metin "$ERRT$OUT") — canlı ana kopyayı riske atmamak için devir TETİKLENMEDİ"
            kapi_atla "$eid"
            kapi_onar "$eid" "$yedek" "$prim"
            return $?
        fi
        bozma="replikanın SQL iş parçacığı durduruldu"
        kapi_ad="$eid: replikasyon sağlıksızken ($bozma) devir REDDEDİLDİ ('ready' kapısı)"
        bekleneni="yükseltmeye hazır değil"
        # Bozmanın TUTTUĞUNU ürünün kendi ölçüsüyle doğruluyoruz. Ölçü "hazır"
        # diyorsa devri TETİKLEMİYORUZ: canlı ana kopyayı bir varsayım uğruna
        # öldürmek testin kendisini veri kaybı hâline getirirdi.
        fo_calistir ready "$yedek"; rc=$?
        if [ "$rc" -eq 0 ]; then
            t_skip "$kapi_ad" \
                   "yedeği bozamadık ($bozma sonrası ürünün 'ready' ölçüsü hâlâ 'hazır' diyor); devir TETİKLENMEDİ"
            kapi_atla "$eid"
            kapi_onar "$eid" "$yedek" "$prim"
            return $?
        fi
        # 'ready' 1 döndü — ama BİZİM ürettiğimiz sebepten mi, yoksa betik hiç
        # çalışamadığı için mi? İkincisinde devri tetiklemek körlemesine olurdu.
        if ! printf '%s' "$OUT$ERRT" | grep -qi 'sağlıklı değil'; then
            t_unknown "$kapi_ad" \
                      "'ready' 1 döndü ama gerekçesi beklediğimiz hâl değil: $(ozet_metin "$OUT$ERRT") — devir TETİKLENMEDİ"
            kapi_atla "$eid"
            kapi_onar "$eid" "$yedek" "$prim"
            return $?
        fi
        ;;
    *)
        # PostgreSQL/Redis: yedeği tamamen durdurup (a) kapısını ölçüyoruz.
        dugum_durdur "$yedek"; rc=$?
        if [ "$rc" -ne 0 ]; then
            t_unknown "$eid: yedek kopya KAPALIYKEN devir REDDEDİLDİ" \
                      "yedeği ($yedek) durduramadık: $(son_hata) — devir TETİKLENMEDİ"
            kapi_atla "$eid"
            t_skip "$eid: güvenlik kapısı testinden sonra replikasyon yeniden akıyor" \
                   "bozma yapılamadı, onarılacak bir şey yok"
            return 1
        fi
        bozma="yedek kopya ($yedek) durduruldu"
        kapi_ad="$eid: yedek kopya KAPALIYKEN devir REDDEDİLDİ (ana kopyaya dokunulmadı)"
        bekleneni="çalışmıyor"
        t_skip "$eid: senkron olmamış replika yükseltilmez ('ready' kapısı)" \
               "bu motorda replikayı AYAKTA bırakıp ürünün 'ready' ölçüsünü düşürmenin yıkıcı olmayan yolu yok (pg: 'hiç WAL almamış', redis: 'offset<=0'); bu koşuda ölçülen kapı 'yedek kopya çalışmıyor'dur"
        ;;
    esac

    log "$eid: yükseltme bilerek imkânsız kılındı ($bozma) — şimdi elle devir tetikleniyor"
    # Onayı BORU yerine here-string ile veriyoruz: `printf 'evet' | ...` boru
    # hattında stack.sh onayı okumadan çıkarsa printf SIGPIPE alıyor ve
    # `set -o pipefail` yüzünden çıkış kodu 141 oluyordu — yani ürüne hiç
    # sorulmamış bir soru "kapı çalıştı" diye yeşil yanıyordu.
    kos timeout "$ELLE_DEVIR_TO" ./stack.sh failover now "$eid" <<< 'evet'
    rc=$?
    local cikti="$OUT$ERRT"

    # --- REDDİN GEREKÇESİ ---------------------------------------------------
    # Çıkış kodu TEK BAŞINA delil değildir: controller kapalıysa, komut zaman
    # aşımına uğrarsa, motor adı geçersizse de 1 gelir. Ürünün kendi olay
    # kaydından gerekçeyi okuyup BEKLENEN kapıyla eşleştiriyoruz.
    local mesaj erc tetik
    mesaj="$(olay_bul "$eid" failover_blocked "$((ts0 - 2))")"; erc=$?

    # Tetiklemenin SONUCU üç hâlden biridir ve bağlı kontroller buna göre
    # raporlanır. Eskiden hepsi "ret" varsayılıyordu: zaman aşımına uğramış bir
    # komuttan sonra "ret kaydı yok" diye ürün suçlanıyordu.
    if [ "$rc" -eq 124 ]; then
        tetik="olcemedik"
    elif [ "$rc" -eq 0 ]; then
        if printf '%s' "$cikti" | grep -q 'Tamamland'; then tetik="devir"; else tetik="olcemedik"; fi
    else
        tetik="red"
    fi

    if [ "$rc" -eq 124 ]; then
        t_unknown "$kapi_ad" \
                  "'./stack.sh failover now' ${ELLE_DEVIR_TO} sn'de dönmedi — kapının çalışıp çalışmadığını ÖLÇEMEDİK"
    elif [ "$rc" -eq 0 ]; then
        # 0: ya devir GERÇEKTEN yapıldı (kapı çalışmadı), ya da komut onayı hiç
        # soramadan çıktı (stack.sh onay 'evet' değilse 0 ile çıkar).
        if [ "$tetik" = "devir" ]; then
            t_fail "$kapi_ad" \
                   "devir YAPILDI — güvenlik kapısı çalışmıyor, bu hâl gerçek veri kaybıdır. Çıktı: $(ozet_metin "$cikti")"
        else
            t_unknown "$kapi_ad" \
                      "komut 0 döndü ama devrin yapıldığına dair kanıt yok (onay istemi okunamamış olabilir): $(ozet_metin "$cikti")"
        fi
    elif [ "$erc" -eq 2 ]; then
        t_unknown "$kapi_ad" \
                  "komut $rc ile döndü ama gerekçeyi ölçemedik: state/events.jsonl okunamadı. Çıktı: $(ozet_metin "$cikti")"
    elif [ "$erc" -eq 1 ]; then
        # Ret var gibi görünüyor ama ürün hiçbir failover_blocked kaydı
        # yazmamış: red BAŞKA bir sebepten (komut hatası, controller kapalı)
        # olabilir. Bunu "kapı çalıştı" saymak, denetimde bulunan tam da o hata.
        t_fail "$kapi_ad" \
               "komut $rc ile döndü ama ürün hiçbir 'failover_blocked' kaydı yazmadı — ret güvenlik kapısından mı geldi belli değil. Çıktı: $(ozet_metin "$cikti")"
    elif printf '%s' "$mesaj" | grep -Fq "$bekleneni" && printf '%s' "$mesaj" | grep -Fq "$yedek"; then
        t_ok "$kapi_ad"
    else
        t_unknown "$kapi_ad" \
                  "devir reddedildi ama gerekçe beklediğimiz kapı değil (aranan: '$bekleneni' + '$yedek'). Olay: $(ozet_metin "$mesaj")"
    fi

    # --- ana kopyaya dokunulmadı mı? ---------------------------------------
    # "Container ayakta" yetmez: fence edilmiş ama geri açılmış bir düğüm de
    # ayakta görünür. Üç ölçü birlikte: ayakta mı, topolojide hâlâ ana kopya mı,
    # aynı adresten YAZILIYOR mu. Ölçemediğimiz tek ölçü bile varsa sonuç
    # t_ok DEĞİL t_unknown'dır.
    # Kontrolün ADI ölçtüğü şeyi söylemeli: ret ÖLÇÜLEMEDİYSE "reddedilen
    # devirde dokunulmadı" cümlesi kurulamaz; ölçtüğümüz şey "denemeden sonra
    # ana kopya hâlâ yerinde mi"dir.
    local dokunma_ad="$eid: elle devir denemesinden sonra ana kopya ($prim) yerinde ve yazılabilir"
    [ "$tetik" = "red" ] && dokunma_ad="$eid: reddedilen devirde ana kopyaya dokunulmadı"
    local ayakta topo yrc olcemedik="" dokunulmadi=1
    calisiyor_mu "$prim"; rc=$?
    case "$rc" in
        0) ayakta="evet" ;;
        1) ayakta="hayır"; dokunulmadi=0 ;;
        *) ayakta="ÖLÇÜLEMEDİ"; olcemedik="$(son_hata)" ;;
    esac
    topo="$(prim_oku "$eid")" || { topo="ÖLÇÜLEMEDİ"; olcemedik="${olcemedik:+$olcemedik; }$(son_hata)"; }
    [ "$topo" = "ÖLÇÜLEMEDİ" ] || [ "$topo" = "$prim" ] || dokunulmadi=0
    local yazma
    gw_yaz "$eid" "$AS_KAPI" "$KOSU-kapi"; yrc=$?
    if [ "$yrc" -eq 2 ]; then
        yazma="ÖLÇÜLEMEDİ"; olcemedik="${olcemedik:+$olcemedik; }$(son_hata)"
    elif [ "$yrc" -ne 0 ]; then
        yazma="ÇALIŞMIYOR"; dokunulmadi=0
    else
        local d; d="$(gw_oku "$eid" "$AS_KAPI")"; rc=$?
        if [ "$rc" -ne 0 ]; then
            yazma="ÖLÇÜLEMEDİ"; olcemedik="${olcemedik:+$olcemedik; }$(son_hata)"
        elif [ "$d" = "$KOSU-kapi" ]; then
            yazma="çalışıyor"
        else
            yazma="geri okunamadı (beklenen '$KOSU-kapi', okunan '${d:-boş}')"; dokunulmadi=0
        fi
    fi
    if [ -n "$olcemedik" ]; then
        t_unknown "$dokunma_ad" \
                  "$prim ayakta mı: $ayakta, topolojideki ana kopya: $topo, gateway'den yazma: $yazma — $olcemedik"
    elif [ "$dokunulmadi" = "1" ]; then
        t_ok "$dokunma_ad ($prim ayakta, gateway'den hâlâ yazılıyor)"
    else
        t_fail "$dokunma_ad" \
               "$prim ayakta mı: $ayakta, topolojideki ana kopya: $topo (beklenen $prim), gateway'den yazma: $yazma"
    fi

    # --- red SESSİZ kalmamalı ----------------------------------------------
    # Ancak GERÇEKTEN bir ret olduysa kayıt aranır: zaman aşımına uğramış ya da
    # hiç sorulamamış bir denemeden sonra "kayıt yok" demek, ürünü ölçmediğimiz
    # bir şeyle suçlamaktır (yanlış KIRMIZI da güveni yıkar).
    case "$tetik" in
    red)
        case "$erc" in
        0) t_ok "$eid: devir reddi olay kaydına gerekçesiyle yazıldı (sessiz vazgeçme yok)"
           printf '            olay: %s\n' "$(ozet_metin "$mesaj")" ;;
        2) t_unknown "$eid: devir reddi olay kaydına yazıldı" \
                     "state/events.jsonl okunamadı — operatörün göreceği kaydı ÖLÇEMEDİK" ;;
        *) t_fail "$eid: devir reddi olay kaydına yazıldı" \
                  "state/events.jsonl içinde failover_blocked kaydı yok — operatör devrin neden yapılmadığını öğrenemez" ;;
        esac ;;
    devir)
        t_skip "$eid: devir reddi olay kaydına yazılır" \
               "devir reddedilmedi, YAPILDI — yazılacak bir ret kaydı yok (kapı kontrolü zaten başarısız)" ;;
    *)
        t_unknown "$eid: devir reddi olay kaydına yazılır" \
                  "devrin reddedilip reddedilmediğini ölçemedik; kaydın olması da olmaması da bir şey söylemez" ;;
    esac

    kapi_onar "$eid" "$yedek" "$prim"
    return $?
}

# Kapı testi hiç tetiklenemediğinde onun bağlı kontrolleri de RAPOR EDİLİR;
# sessizce yok saymak "ölçüldü" izlenimi bırakırdı.
kapi_atla() {
    t_skip "$1: reddedilen devirde ana kopyaya dokunulmaz" "devir tetiklenmedi"
    t_skip "$1: devir reddi olay kaydına yazılır" "devir tetiklenmedi"
}

# Bozduğumuzu ONARIRIZ ve onarımı ÖLÇERİZ. Onarılmadıysa zincirin yıkıcı
# kısmına geçmek gerçek veri kaybı riskidir — orada dururuz.
kapi_onar() {   # kapi_onar <motor> <yedek> <kapı öncesi ana kopya>
    local eid="$1" yedek="$2" onceki_prim="$3" rc simdiki rol deger
    local ad="$eid: güvenlik kapısı testinden sonra replikasyon yeniden akıyor"

    # ÖNCE: kapı testi sırasında devir GERÇEKTEN oldu mu? Olduysa $yedek artık
    # ana kopyadır; ürünün 'ready' ölçüsü "zaten primary" der, biz de kendi
    # yazdığımız satırı AYNI düğümden okuyup "replikasyon akıyor" sanardık.
    simdiki="$(prim_oku "$eid")" || {
        t_unknown "$ad" "$(son_hata) — devrin olup olmadığını bilmeden yıkıcı kısma geçilmez"
        return 1
    }
    if [ "$simdiki" != "$onceki_prim" ]; then
        t_fail "$ad" \
               "kapı testi sırasında devir GERÇEKTEN yapıldı (ana kopya artık $simdiki); onarım ölçüsü anlamsız olurdu, zincirin yıkıcı kısmı ATLANIYOR"
        return 1
    fi

    case "$eid" in
    mariadb)
        _mariadb_dugum "$yedek" "START SLAVE;" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -ne 0 ]; then
            t_unknown "$ad" "START SLAVE çalıştırılamadı (çıkış $rc): $(ozet_metin "$ERRT$OUT")"
            return 1
        fi
        ;;
    *)
        dugum_baslat "$yedek"; rc=$?
        if [ "$rc" -ne 0 ]; then
            t_unknown "$ad" "$yedek geri açılamadı: $(son_hata)"
            return 1
        fi
        ;;
    esac

    if ! bekle 120 "$yedek yeniden yükseltilebilir duruma gelsin (ürünün 'ready' ölçüsü)" \
                fo_sessiz ready "$yedek"; then
        fo_calistir ready "$yedek"
        t_fail "$ad" "$yedek 120 sn'de yeniden hazır olmadı ($(ozet_metin "$OUT$ERRT")); zincirin yıkıcı kısmı ATLANIYOR"
        return 1
    fi

    # 'ready' "zaten primary" de diyebilir; rolü AYRICA soruyoruz ki kendi
    # yazdığımızı yükselmiş bir düğümden okuyup "replikasyon akıyor" demeyelim.
    rol="$(rol_sor "$eid" "$yedek")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        t_unknown "$ad" "$yedek rolü sorulamadı: $(son_hata)"
        return 1
    fi
    if [ "$rol" != "yedek" ]; then
        t_fail "$ad" "$yedek onarımdan sonra YEDEK değil '$rol' rolünde — ikinci bir yazılabilir kopya var, zincirin yıkıcı kısmı ATLANIYOR"
        return 1
    fi

    gw_yaz "$eid" "$AS_ONARIM" "$KOSU-onarim"; rc=$?
    if [ "$rc" -eq 2 ]; then
        t_unknown "$ad" "onarım satırı yazılamadı: $(son_hata)"; return 1
    fi
    if [ "$rc" -ne 0 ]; then
        t_fail "$ad" "gateway'den yazılamadı: $(son_hata); zincirin yıkıcı kısmı ATLANIYOR"; return 1
    fi
    if bekle "$AKIS_TO" "'$AS_ONARIM' satırı $yedek düğümüne ulaşsın" \
             _dugum_es "$eid" "$yedek" "$AS_ONARIM" "$KOSU-onarim"; then
        t_ok "$eid: güvenlik kapısı testinden sonra replikasyon yeniden akıyor ($yedek güncel)"
        return 0
    fi
    deger="$(dugum_oku "$eid" "$yedek" "$AS_ONARIM")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        t_unknown "$ad" "$(son_hata); zincirin yıkıcı kısmı ATLANIYOR"
    else
        t_fail "$ad" "beklenen '$KOSU-onarim', $yedek üzerinde okunan '${deger:-(boş)}'; zincirin yıkıcı kısmı ATLANIYOR"
    fi
    return 1
}

# =============================================================================
# 4-6) ANA KOPYAYI ÖLDÜR → DEVİR → AYNI ADRES → VERİ DURUYOR MU
# =============================================================================
devir_atla() {   # devir tetiklenemediğinde bağlı kontroller RAPOR EDİLİR
    local eid="$1" sebep="$2"
    t_skip "$eid: devir 4/4 tamamlandı (yönlendirme + izleme + kayıt)" "$sebep"
    t_skip "$eid: devirden sonra AYNI ADRESTEN yazma çalışıyor" "$sebep"
    t_skip "$eid: gateway'den yazılan satır YENİ ana kopyaya indi" "$sebep"
    t_skip "$eid: devir öncesi yazılan satır yeni ana kopyada duruyor" "$sebep"
}

# Devir OLMADIYSA ana kopyayı geri açarız. OLDUYSA açmak split-brain olurdu:
# önce yedeğin rolünü ÖLÇÜYORUZ; ölçemezsek açmayız ve bunu söyleriz.
eski_geri_ac() {   # eski_geri_ac <motor> <eski primary> <yedek>
    local eid="$1" eski="$2" yedek="$3" rol rc
    rol="$(rol_sor "$eid" "$yedek")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "$eid: $yedek rolü ölçülemedi ($(son_hata)) — $eski GERİ AÇILMIYOR (iki yazılabilir kopya riski). Elle: docker start $eski"
        return 1
    fi
    if [ "$rol" = "ana" ]; then
        warn "$eid: $yedek yükselmiş görünüyor — $eski GERİ AÇILMIYOR (split-brain riski). Durumu './stack.sh failover status' ile inceleyin."
        dugum_unut "$eski"
        return 1
    fi
    warn "$eid: devir olmadı — durdurduğumuz ana kopya ($eski) geri açılıyor"
    dugum_baslat "$eski" || warn "$eid: $eski geri açılamadı: $(son_hata)"
    return 0
}

devir_zinciri() {   # 0 = devam (rebuild aşamasına)
    local eid="$1" eski yedek yeni t0 gecen butce lk sk rc erc mesaj deger

    # Denetleyici bekleme süresindeyse (art arda iki koşu) devir yapmaz.
    # Bunu bilmeden beklemek "devir çalışmıyor" gibi görünürdü.
    sk="$(sogutma_kalan "$eid")"; rc=$?
    sayi_mi "$sk" || { rc=2; _hata_yaz "devir bekleme süresi sayı olarak okunamadı: '${sk:-boş}'"; }
    if [ "$rc" -ne 0 ]; then
        t_unknown "$eid: ana kopya öldürülünce devir kendiliğinden tamamlanır" \
                  "$(son_hata) — denetleyicinin devir yapıp yapmayacağını bilmeden canlı ana kopya öldürülmez"
        devir_atla "$eid" "devir tetiklenmedi (bekleme süresi ölçülemedi)"
        return 1
    fi
    if [ "$sk" -gt 0 ]; then
        if [ "$sk" -le "$SOGUTMA_MAX" ]; then
            log "$eid: denetleyici devir bekleme süresinde (FAILOVER_COOLDOWN=$SOGUTMA sn)"
            uyu_sayarak "$sk" "devir bekleme süresinin dolması bekleniyor"
        else
            t_skip "$eid: ana kopya öldürülünce devir kendiliğinden tamamlanır" \
                   "son devir çok yeni; denetleyici $sk sn daha devir yapmaz (FAILOVER_COOLDOWN=$SOGUTMA). E2E_SOGUTMA_MAX ile bekleme süresini artırabilir ya da sonra tekrar çalıştırabilirsiniz."
            devir_atla "$eid" "devir tetiklenmedi (bekleme süresi)"
            return 1
        fi
    fi

    eski="$(prim_oku "$eid")" || {
        t_unknown "$eid: ana kopya öldürülünce devir kendiliğinden tamamlanır" "$(son_hata)"
        devir_atla "$eid" "devir tetiklenmedi (ana kopya ölçülemedi)"
        return 1
    }
    yedek="$(yedek_dugum "$eid" "$eski")"

    lk="$(lutuf_kalan)" || \
        log "$eid: controller açılış zamanı okunamadı — bütçeye TAM lütuf süresi ($LUTUF sn) ekleniyor"
    sayi_mi "$lk" || { log "$eid: lütuf süresi sayı değil ('${lk:-boş}') — 0 sayılıyor"; lk=0; }
    sayi_mi "$DEVIR_BEKLE" || DEVIR_BEKLE=300
    butce=$(( DEVIR_BEKLE + lk ))
    [ "$lk" -gt 0 ] && log "$eid: controller açılış lütuf süresi için $lk sn ekleniyor"
    log "$eid: ana kopya ($eski) BİLEREK durduruluyor; denetleyici ~$((VURUS * ARALIK)) sn içinde devri kendisi yapmalı"
    t0="$(date +%s)"
    if ! dugum_durdur "$eski"; then
        # docker stop çalışmadıysa senaryoyu HİÇ üretemedik. Eski hâlde bu,
        # "devir olmadı" diye ürünü suçlayan bir [KALDI] satırıydı.
        t_unknown "$eid: ana kopya ($eski) öldürülünce devir kendiliğinden tamamlandı" \
                  "$(son_hata) — devir senaryosu ÜRETİLEMEDİ"
        devir_atla "$eid" "ana kopya durdurulamadı"
        return 1
    fi

    if bekle "$butce" "denetleyici devri tamamlasın (topolojide ana kopya $eski olmaktan çıksın)" \
             _prim_degisti "$eid" "$eski"; then
        yeni="$(prim_oku "$eid")" || yeni=""
        if [ -z "$yeni" ] || [ "$yeni" = "$eski" ]; then
            # Beklemeyi bitiren okuma ile bu okuma çelişiyor: ölçüm oynak.
            t_unknown "$eid: ana kopya ($eski) öldürülünce devir kendiliğinden tamamlandı" \
                      "topolojideki ana kopya son anda okunamadı: $(son_hata). $eski geri-açma defterinde KALIYOR."
            devir_atla "$eid" "devrin olup olmadığı ölçülemedi"
            return 1
        fi
        if [ "$yeni" != "$yedek" ]; then
            t_fail "$eid: ana kopya ($eski) öldürülünce devir kendiliğinden tamamlandı" \
                   "topolojide ana kopya '$yeni' oldu; beklenen yedek '$yedek' — zincirin kalanı yanlış düğümü ölçerdi"
            devir_atla "$eid" "beklenmeyen düğüm yükseltildi"
            return 1
        fi
        # Devir başarılıysa eski ana kopya FENCE edilmiş demektir; geri açmak
        # split-brain olurdu. Defterden ANCAK devri ölçtükten sonra düşüyoruz.
        dugum_unut "$eski"
        t_ok "$eid: ana kopya ($eski) öldürülünce devir kendiliğinden tamamlandı — yeni ana kopya: $yeni"
    else
        # Sebebi ÖNCE saklıyoruz: eski_geri_ac kendi ölçümlerini yapıp
        # son_hata'yı üzerine yazıyor.
        local topo_hata=""
        prim_oku "$eid" >/dev/null; rc=$?
        [ "$rc" -ne 0 ] && topo_hata="$(son_hata)"
        eski_geri_ac "$eid" "$eski" "$yedek"
        if [ "$rc" -ne 0 ]; then
            t_unknown "$eid: ana kopya öldürülünce devir kendiliğinden tamamlandı" \
                      "$butce sn boyunca topolojiyi hiç okuyamadık: $topo_hata"
        else
            t_fail "$eid: ana kopya öldürülünce devir kendiliğinden tamamlandı" \
                   "$butce sn içinde topolojide ana kopya değişmedi. 'docker logs controller' ve './stack.sh events' çıktısına bakın."
        fi
        devir_atla "$eid" "devir gerçekleşmedi"
        return 1
    fi

    # --- devir 4/4 kapandı mı? ---------------------------------------------
    # Devir 4 adımdır (fence → promote → reroute+izleme → kayıt). Topolojiye
    # yazma ADIM 3'ün BAŞINDA olur; ondan sonra roles.env, routes, gateway
    # reload ve exporter container'ının YENİDEN YARATILMASI gelir. Tek atışlık
    # bir `docker logs | grep`, controller'ın bu adımlarıyla YARIŞIR ve çalışan
    # bir devirde bile "kaldı" yazardı. Ürünün kendi kapanış kaydını (kind:
    # failover — '4/4 tamam' satırının hemen ardından yazılır) SINIRLI TEKRARLA
    # bekliyoruz.
    local ad44="$eid: devir 4/4 tamamlandı (yönlendirme + izleme + kayıt)"
    if bekle "$KAPANIS_BEKLE" "controller devri kapatsın (olay kaydı: failover)" \
             _devir_olayi "$eid" "$((t0 - 2))"; then
        mesaj="$(olay_bul "$eid" failover "$((t0 - 2))")"
        if printf '%s' "$mesaj" | grep -Fq "$yeni"; then
            t_ok "$ad44 — olay: $(ozet_metin "$mesaj")"
        else
            t_fail "$ad44" "kapanış kaydı yeni ana kopyayı ($yeni) anmıyor: $(ozet_metin "$mesaj")"
        fi
    else
        olay_bul "$eid" failover "$((t0 - 2))" >/dev/null; erc=$?
        if [ "$erc" -eq 2 ]; then
            # Olay defteri okunamıyor — son çare controller logu.
            gecen=$(( $(date +%s) - t0 + 10 ))
            kos docker logs controller --since "${gecen}s"
            if [ "$RC" -ne 0 ]; then
                t_unknown "$ad44" \
                          "state/events.jsonl okunamadı ve controller logu da alınamadı ($(ozet_metin "$ERRT")) — devrin kapanıp kapanmadığını ÖLÇEMEDİK"
            else
                local son_log
                son_log="$(printf '%s\n' "$OUT" | grep -F '4/4 tamam' | tail -n 1)"
                if [ -n "$son_log" ] && printf '%s' "$son_log" | grep -Fq "$yeni"; then
                    t_ok "$ad44 (olay defteri okunamadı; controller logundan doğrulandı)"
                else
                    t_fail "$ad44" \
                           "son ${gecen} sn'lik controller logunda '4/4 tamam … $yeni' satırı yok: ${son_log:-(satır yok)}"
                fi
            fi
        else
            t_fail "$ad44" \
                   "topolojide ana kopya değişti ama ${KAPANIS_BEKLE} sn içinde kapanış kaydı (kind: failover) yazılmadı — devir 3. adımda (yönlendirme/izleme) takılmış olabilir"
        fi
    fi

    # --- ÜRÜNÜN ANA VAADİ: uygulamanın bağlantı adresi değişmez ------------
    # nginx yeniden yüklendikten sonra istemcinin yeniden bağlanması birkaç
    # saniye sürebilir; bu yüzden ölçüm tekrarlanır ama süresi sınırlıdır.
    local adres_ok=0
    if bekle 90 "gateway:$M_LISTEN yeni ana kopyaya yönlensin (uygulama adresi değişmeden)" \
             _gw_yazilir "$eid" "$AS_SONRA" "$KOSU-sonra"; then
        t_ok "$eid: devirden sonra AYNI ADRESTEN (gateway:$M_LISTEN) yazma çalışıyor — uygulamanın bağlantı adresi değişmedi"
        adres_ok=1
    else
        gw_yaz "$eid" "$AS_SONRA" "$KOSU-sonra"; rc=$?
        if [ "$rc" -eq 2 ]; then
            t_unknown "$eid: devirden sonra AYNI ADRESTEN yazma çalışıyor" "$(son_hata)"
        else
            t_fail "$eid: devirden sonra AYNI ADRESTEN (gateway:$M_LISTEN) yazma çalışıyor" \
                   "$(son_hata) — yedek yükseldi ama gateway trafiği oraya taşımıyor; uygulamalar hâlâ bağlanamaz (yönlendirme tablosu/nginx reload)"
        fi
    fi

    # Yalnız gateway'den okumak yetmez: yönlendirme eski (ya da diriltilmiş)
    # ana kopyayı gösteriyorsa yazma yine "çalışıyor" görünür. Yazının YENİ ana
    # kopyaya indiğini o düğümün İÇİNDEN doğruluyoruz.
    local ad_indi="$eid: gateway'den yazılan satır YENİ ana kopyaya indi"
    if [ "$adres_ok" = "1" ]; then
        deger="$(dugum_oku "$eid" "$yeni" "$AS_SONRA")"; rc=$?
        if [ "$rc" -ne 0 ]; then
            t_unknown "$ad_indi" "$(son_hata)"
        elif [ "$deger" = "$KOSU-sonra" ]; then
            t_ok "$ad_indi ($yeni) — trafik gerçekten yükseltilen düğüme gidiyor"
        else
            t_fail "$ad_indi" \
                   "$yeni içinde beklenen '$KOSU-sonra' yok (okunan: '${deger:-(boş)}') — gateway başka bir düğüme yazıyor olabilir"
        fi
    else
        t_skip "$ad_indi" "gateway üzerinden yazma çalışmadı; inecek bir satır yok"
    fi

    # --- devir öncesi satır duruyor mu? ------------------------------------
    # Asenkron replikasyonda kayıp ancak ana kopyanın göndermeye yetişemediği
    # kadar olabilir; bizim satır devirden dakikalar önce yazıldı ve replikada
    # GÖRÜLDÜ — kaybolması, yükseltmenin yanlış düğümü seçtiği (ya da hacmin
    # silindiği) anlamına gelir. Ölçüyü YENİ ANA KOPYANIN İÇİNDEN alıyoruz:
    # kontrolün adı da bu.
    deger="$(dugum_oku "$eid" "$yeni" "$AS_ONCE")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        t_unknown "$eid: devir öncesi yazılan satır yeni ana kopyada duruyor" "$(son_hata)"
    elif [ "$deger" = "$KOSU-once" ]; then
        t_ok "$eid: devir öncesi yazılan satır yeni ana kopyada ($yeni) duruyor — veri kaybı yok"
    else
        t_fail "$eid: devir öncesi yazılan satır yeni ana kopyada duruyor" \
               "beklenen '$KOSU-once', $yeni üzerinde okunan '${deger:-(boş)}' — devirde veri kaybedildi"
    fi
    return 0
}

# bekle() yüklemleri: ÖLÇEMEDİĞİMİZDE "oldu" demiyoruz.
_prim_degisti() {   # _prim_degisti <motor> <eski>
    local p
    p="$(prim_oku "$1")" || return 1
    [ -n "$p" ] && [ "$p" != "$2" ]
}
_devir_olayi() { olay_bul "$1" failover "$2" >/dev/null 2>&1; }

# =============================================================================
# 7) REBUILD — eski ana kopyayı yedek olarak geri al
# =============================================================================
rebuild_zinciri() {
    local eid="$1" prim eski rc rol deger

    prim="$(prim_oku "$eid")" || {
        t_unknown "$eid: eski ana kopya './stack.sh failover rebuild' ile yedek olarak geri alındı" "$(son_hata)"
        t_skip "$eid: geri alınan düğüm ikinci bir YAZILABİLİR ana kopya değil" "rebuild çalıştırılmadı"
        t_skip "$eid: yeniden kurulan yedeğe replikasyon tekrar akıyor" "rebuild çalıştırılmadı"
        return 1
    }
    eski="$(yedek_dugum "$eid" "$prim")"

    log "$eid: './stack.sh failover rebuild $eid' — $eski, $prim'in yedeği olarak yeniden kuruluyor"
    timeout "$REBUILD_TO" ./stack.sh failover rebuild "$eid" > "$TMP/rebuild.log" 2>&1
    rc=$?
    local kuyruk; kuyruk="$(ozet_metin "$(tail -n 4 "$TMP/rebuild.log" 2>/dev/null)")"
    if [ "$rc" -eq 124 ]; then
        t_unknown "$eid: eski ana kopya ($eski) './stack.sh failover rebuild' ile yedek olarak geri alındı" \
                  "komut ${REBUILD_TO} sn'de dönmedi (E2E_REBUILD_TIMEOUT) — sürüyor olabilir, sonuç ÖLÇÜLEMEDİ: $kuyruk"
        t_skip "$eid: geri alınan düğüm ikinci bir YAZILABİLİR ana kopya değil" "rebuild sonucu ölçülemedi"
        t_skip "$eid: yeniden kurulan yedeğe replikasyon tekrar akıyor" "rebuild sonucu ölçülemedi"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        if printf '%s' "$kuyruk" | grep -qiE 'controller çalışmıyor|Kullanım:|Bilinmeyen veritabanı'; then
            t_unknown "$eid: eski ana kopya ($eski) './stack.sh failover rebuild' ile yedek olarak geri alındı" \
                      "komut ürünün rebuild adımına HİÇ ulaşmadı (çıkış $rc): $kuyruk"
        else
            t_fail "$eid: eski ana kopya ($eski) './stack.sh failover rebuild' ile yedek olarak geri alındı" \
                   "çıkış $rc: $kuyruk"
        fi
        t_skip "$eid: geri alınan düğüm ikinci bir YAZILABİLİR ana kopya değil" "rebuild başarısız"
        t_skip "$eid: yeniden kurulan yedeğe replikasyon tekrar akıyor" "rebuild başarısız"
        return 1
    fi
    t_ok "$eid: eski ana kopya ($eski) './stack.sh failover rebuild' ile yedek olarak geri alındı"
    dugum_unut "$eski"   # ürün geri getirdi; defterde tutmaya gerek yok

    # En pahalı sessiz arıza: düğüm ayağa kalkar ama YEDEK DEĞİL, ikinci bir
    # yazılabilir ana kopyadır (hacim silinememiş, rol env'i okunmamış). İki
    # kopya da yazı kabul ederse veriler ayrışır ve birleştirilemez.
    # "Ayakta ama sorgulanamayan" bir düğümü yedek saymak bu kontrolü tam da
    # split-brain varken yeşil yakardı: rolü DOĞRUDAN soruyoruz.
    local ad_sb="$eid: geri alınan düğüm ($eski) ikinci bir YAZILABİLİR ana kopya değil"
    calisiyor_mu "$eski"; rc=$?
    case "$rc" in
    1) t_fail "$ad_sb" "$eski rebuild'den sonra ÇALIŞMIYOR — yedek geri gelmedi" ;;
    0)
        rol="$(rol_sor "$eid" "$eski")"; rc=$?
        if [ "$rc" -ne 0 ]; then
            t_unknown "$ad_sb" "$eski ayakta ama rolü sorulamadı: $(son_hata) — 'cevap vermeyen düğüm' yedek sayılmaz"
        elif [ "$rol" = "yedek" ]; then
            t_ok "$ad_sb — split-brain yok (rol doğrudan soruldu: yedek)"
        else
            t_fail "$ad_sb" "$eski YAZILABİLİR ANA KOPYA rolünde — iki kopya da yazı kabul ediyor (split-brain)"
        fi
        ;;
    *) t_unknown "$ad_sb" "$(son_hata)" ;;
    esac

    local ad_akis="$eid: yeniden kurulan yedeğe ($eski) replikasyon tekrar akıyor"
    gw_yaz "$eid" "$AS_REBUILD" "$KOSU-rebuild"; rc=$?
    if [ "$rc" -eq 2 ]; then
        t_unknown "$ad_akis" "$(son_hata)"; return 0
    fi
    if [ "$rc" -ne 0 ]; then
        t_fail "$ad_akis" "gateway'den yazılamadı: $(son_hata)"; return 0
    fi
    if bekle "$AKIS_TO" "'$AS_REBUILD' satırı yeniden kurulan yedeğe ($eski) ulaşsın" \
             _dugum_es "$eid" "$eski" "$AS_REBUILD" "$KOSU-rebuild"; then
        t_ok "$ad_akis — yeni satır yedekte göründü"
        return 0
    fi
    deger="$(dugum_oku "$eid" "$eski" "$AS_REBUILD")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        t_unknown "$ad_akis" "$(son_hata)"
    else
        t_fail "$ad_akis" \
               "beklenen '$KOSU-rebuild', $eski üzerinde okunan '${deger:-(boş)}' — yedek kuruldu ama beslenmiyor"
    fi
    return 0
}

# =============================================================================
# TEMİZLİK — betik kendi bıraktığını toplar (iki kez üst üste çalışabilsin)
# =============================================================================
zincir_temizlik() {
    local eid="$1" durum
    test_verisi_sil "$eid"
    durum="$(test_verisi_durumu "$eid")"
    case "$durum" in
    yok)
        t_ok "$eid: test verisi silindi (betik üst üste çalıştırılabilir)" ;;
    var)
        t_fail "$eid: test verisi silindi (betik üst üste çalıştırılabilir)" \
               "$TABLO / $ANAHTAR_ONEK:* hâlâ duruyor — elle silin" ;;
    *)
        # Temizliğin doğrulanamaması "temiz" DEĞİLDİR: geride kalan test verisi
        # bir sonraki koşuyu da yanıltır.
        t_unknown "$eid: test verisi silindi (betik üst üste çalıştırılabilir)" \
                  "gateway:$M_LISTEN üzerinden sorgu çalışmadı ($(son_hata)); $TABLO / $ANAHTAR_ONEK:* kalmış olabilir" ;;
    esac

    # Otomatik devri BİZ açtıysak eski hâline döndürüyoruz: test aracı,
    # kurulumun ayarlarını kendi arkasında değiştirmemeli.
    if [ "${OTO_BIZ_ACTIK:-0}" = "1" ]; then
        if timeout 120 ./stack.sh failover off "$eid" >/dev/null 2>&1; then
            log "$eid: otomatik devir test öncesindeki hâline (kapalı) döndürüldü"
        else
            warn "$eid: otomatik devir kapatılamadı — açık kaldı: ./stack.sh failover off $eid"
        fi
    fi
}

# =============================================================================
# BİR MOTORUN TAM ZİNCİRİ
# =============================================================================
motor_zinciri() {
    local eid="$1"
    heading "═══ $eid — otomatik devir zinciri ═══"

    if ! motor_baglami "$eid"; then
        # catalog.json okunamıyorsa hangi düğümü test edeceğimizi bile
        # bilmiyoruz: bu bir ATLAMA değil, ÖLÇEMEME hâlidir.
        t_unknown "$eid: devir zinciri" "katalog kaydı okunamadı (catalog.json / python3)"
        return
    fi
    if ! onkosullar "$eid"; then
        return
    fi

    # Önceki koşudan kalmış olabilecek test verisi — karşılaştırmalar bu
    # koşunun damgasına göre yapılsa da temiz başlamak teşhisi kolaylaştırır.
    test_verisi_sil "$eid"

    if temel_veri "$eid"; then
        if guvenlik_kapisi "$eid"; then
            if devir_zinciri "$eid"; then
                rebuild_zinciri "$eid"
            else
                t_skip "$eid: eski ana kopya yedek olarak geri alınır (rebuild)" "devir yapılmadı"
                t_skip "$eid: geri alınan düğüm ikinci bir YAZILABİLİR ana kopya değil" "devir yapılmadı"
                t_skip "$eid: yeniden kurulan yedeğe replikasyon tekrar akıyor" "devir yapılmadı"
            fi
        else
            t_skip "$eid: devir zincirinin yıkıcı kısmı" \
                   "güvenlik kapısı testinden sonra replikasyon onarılamadı/ölçülemedi — ana kopya öldürülmedi"
        fi
    fi
    zincir_temizlik "$eid"
}

# =============================================================================
# GİRİŞ
# =============================================================================
# Ön koşul yoksa (yığın kurulu değil, controller kapalı) bu bir ATLAMADIR ve
# e2e_finish 2 ile çıkar: "hiçbir şey ölçmedik" ile "her şey sağlam" aynı şey
# değildir. Ölçüm ARACI yoksa (python3, docker cevap vermiyor) t_unknown.
bitir() { e2e_finish; exit $?; }

if ! command -v docker >/dev/null 2>&1; then
    t_skip "otomatik devir zinciri" "docker yok — bu betik KURULU bir yığına karşı çalışır"
    bitir
fi
if ! command -v python3 >/dev/null 2>&1; then
    t_unknown "otomatik devir zinciri" "python3 yok — katalog/topoloji/olay defteri okunamaz, HİÇBİR ölçüm yapılamaz"
    bitir
fi
if ! command -v timeout >/dev/null 2>&1; then
    t_unknown "otomatik devir zinciri" "'timeout' komutu yok — asılı kalan bir istemci koşuyu sonsuza dek bekletirdi"
    bitir
fi
if [ ! -f "$ENV_FILE" ]; then
    t_skip "otomatik devir zinciri" ".env yok — bu betik KURULU bir yığına karşı çalışır. Önce: ./install.sh"
    bitir
fi
if [ ! -f "$CATALOG" ]; then
    t_unknown "otomatik devir zinciri" "catalog.json bulunamadı: $CATALOG — hangi motorun test edileceğini okuyamıyoruz"
    bitir
fi
calisiyor_mu controller; _rc=$?
case "$_rc" in
    0) ;;
    1) t_skip "otomatik devir zinciri" "controller çalışmıyor — devir kararlarını o veriyor. Önce: ./stack.sh up"; bitir ;;
    *) t_unknown "otomatik devir zinciri" "$(son_hata)"; bitir ;;
esac
calisiyor_mu gateway; _rc=$?
case "$_rc" in
    0) ;;
    1) t_skip "otomatik devir zinciri" "gateway çalışmıyor — 'aynı adres' vaadi ancak onun üzerinden ölçülebilir. Önce: ./stack.sh up"; bitir ;;
    *) t_unknown "otomatik devir zinciri" "$(son_hata)"; bitir ;;
esac

# Yedekleme kilidiyle AYNI kilidi alıyoruz. Sebebi somut: rebuild bir veri
# hacmini siler, o sırada çalışan bir yedekleme hacmi tutar ve rebuild
# "hacim kullanımda" diye başarısız olur — test de ürünü haksız yere suçlar.
# common.sh/acquire_lock kilidi alamazsa die() ile çıkıyor; burada özet
# basılabilsin diye kilidi kendimiz alıyoruz (aynı dosya, aynı flock).
KILIT_DOSYASI=/tmp/databases-stack-backup.lock
if ! command -v flock >/dev/null 2>&1; then
    t_unknown "otomatik devir zinciri" \
              "flock yok — yedekleme kilidi alınamaz; rebuild çalışan bir yedeklemeyle çakışıp ürünü haksız yere suçlayabilirdi"
    bitir
fi
if ! exec 9>>"$KILIT_DOSYASI" 2>/dev/null || ! flock -n 9; then
    t_skip "otomatik devir zinciri" \
           "yedekleme kilidini ($KILIT_DOSYASI) başka bir işlem tutuyor — yedekleme sürerken devir testi ürünü haksız yere suçlar"
    bitir
fi

AG="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' gateway 2>/dev/null)"
[ -n "$AG" ] || AG="databases-stack_net"

heading "OTOMATİK DEVİR TESTİ — $(date '+%Y-%m-%d %H:%M:%S')"
log "yığın kökü : $STACK_ROOT"
log "ağ         : $AG"
log "denetleyici: her ${ARALIK} sn kontrol, ${VURUS} vuruşta devir, ${SOGUTMA} sn devir bekleme süresi"
warn "Bu test ana kopyayı BİLEREK durdurur; kısa bir kesinti olur."

MOTORLAR=()
if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        if [ -z "$(kat "$arg" 'e["id"]')" ]; then
            t_unknown "$arg: devir zinciri" \
                      "katalogda böyle bir motor yok (ya da catalog.json okunamadı) — geçerli olanlar: $(denetlenen_motorlar | tr '\n' ' ')"
            continue
        fi
        # Katalog "bu motorda devir denetlenmiyor" diyorsa test de bunu
        # RAPOR EDER; sessizce listeden düşürmek, kullanıcının istediği testin
        # hiç çalışmadığını gizlerdi.
        mod="$(kat "$arg" 'e["failover"].get("mode","none")')"
        if [ -z "$mod" ]; then
            t_unknown "$arg: devir zinciri" "katalogda failover.mode alanı okunamadı"
            continue
        fi
        if [ "$mod" != "supervised" ]; then
            t_skip "$arg: devir zinciri" \
                   "katalogda failover.mode=$mod — controller devri yönetmiyor: $(kat "$arg" 'e["failover"].get("note","")')"
            continue
        fi
        MOTORLAR+=("$arg")
    done
else
    while IFS= read -r m; do [ -n "$m" ] && MOTORLAR+=("$m"); done < <(denetlenen_motorlar)
    if [ "${#MOTORLAR[@]}" -eq 0 ]; then
        t_unknown "otomatik devir zinciri" \
                  "katalogdan denetlenen (supervised) motor listesi okunamadı — hangi motorun test edileceğini bilmiyoruz"
        bitir
    fi
fi

log "test edilecek motorlar: ${MOTORLAR[*]-(yok)}"

for eid in ${MOTORLAR[@]+"${MOTORLAR[@]}"}; do
    motor_zinciri "$eid"
done

# Bir aksilikte açık kalmış olabilecek düğümler — kullanıcının veritabanını
# kapalı bırakmıyoruz. (EXIT trap'i de aynı defteri boşaltır; burada erken
# yapıyoruz ki uyarılar özetin ÜSTÜNDE görünsün.)
for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
    warn "betiğin durdurduğu $c geri açılıyor"
    dugum_baslat "$c" || warn "  $c AÇILAMADI: $(son_hata)"
done

# ------------------------------------------------------------------- özet --
# Devirden sonra ana kopya DİĞER düğümdür; bu normaldir ama kullanıcı bunu
# raporda görmeli — yedekleme/izleme hangi düğüme baktığını bilmek ister.
heading "ÖZET"
for eid in ${MOTORLAR[@]+"${MOTORLAR[@]}"}; do
    _p="$(prim_oku "$eid")" || { printf '  %-14s ana kopya şu an: ÖLÇÜLEMEDİ (%s)\n' "$eid" "$(son_hata)"; continue; }
    calisiyor_mu "$_p"; _rc=$?
    case "$_rc" in
        0) printf '  %-14s ana kopya şu an: %s\n' "$eid" "$_p" ;;
        1) printf '  %-14s ana kopya şu an: %s (ÇALIŞMIYOR)\n' "$eid" "$_p" ;;
        *) printf '  %-14s ana kopya şu an: %s (durumu ÖLÇÜLEMEDİ)\n' "$eid" "$_p" ;;
    esac
done

e2e_finish
exit $?
