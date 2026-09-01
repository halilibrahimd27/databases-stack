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
# Zincir (her supervised motor için):
#   1. Yedek kopya + otomatik devir açık mı (değilse ürünün kendi komutlarıyla kurulur)
#   2. gateway üzerinden veri yaz → replikada göründüğünü doğrula
#   3. GÜVENLİK KAPISI: replikasyonu bilerek boz, devri tetikle → REDDEDİLMELİ
#      ve ana kopyaya DOKUNULMAMALI (bu kapı olmadan gerçek bir sunucuda veri
#      kaybedildi: senkron olmamış replika yükseltildi, ana kopya fence edildi)
#   4. Ana kopyayı ÖLDÜR (docker stop) → denetleyici devri kendisi tamamlamalı
#   5. AYNI ADRESTEN (gateway) yazma çalışmalı → uygulamanın adresi değişmedi
#   6. Devir öncesi yazılan satır KAYBOLMAMIŞ olmalı
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
#   E2E_REPLIKA_TIMEOUT=1800  `./stack.sh replica on` için üst sınır
#   E2E_REBUILD_TIMEOUT=1800  `./stack.sh failover rebuild` için üst sınır
#   E2E_AKIS_TIMEOUT=120      yazılan satırın yedeğe ulaşması için üst sınır
#   E2E_ISTEMCI_TIMEOUT=60    tek bir istemci çağrısı için üst sınır
#   E2E_SOGUTMA_MAX=330       devir bekleme süresi (cooldown) için beklenecek en fazla süre
#
# Çıkış kodu:
#   0 = çalışan kontrollerin hepsi geçti
#   1 = en az bir kontrol kaldı
#   2 = HİÇBİR kontrol çalışmadı (hepsi atlandı). Ayrı kod, çünkü hiçbir şey
#       ölçmemiş yeşil bir koşu, alınabilecek en yanıltıcı sonuçtur.
# =============================================================================
# `set -e` BİLEREK YOK: her kontrol tek tek raporlanmalı, ilk hatada ölmemeli.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

# ------------------------------------------------------------------ ayarlar --
KUR="${E2E_KUR:-1}"
DEVIR_BEKLE="${E2E_DEVIR_TIMEOUT:-300}"
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
TMP="$(mktemp -d)"

# ------------------------------------------------------------- test sayaçları --
GECEN=0; KALAN=0; ATLANAN=0
KALAN_ADLAR=(); ATLANAN_ADLAR=()

t_ok() {
    GECEN=$((GECEN + 1))
    printf '%s  [GEÇTİ]%s   %s\n' "$GREEN" "$NC" "$1"
    return 0
}

t_fail() {
    KALAN=$((KALAN + 1))
    KALAN_ADLAR+=("$1")
    printf '%s  [KALDI]%s   %s\n' "$RED" "$NC" "$1"
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | sed 's/^/             /'
    fi
    return 0
}

# ATLAMA DA BİR SONUÇTUR. Sessizce atlanan test "geçti" sanılır; bu betikte
# "replikasyon kurulu değildi, o yüzden devri denemedim" cümlesi, otomatik
# devrin hiç çalışmadığının fark edilmemesi demektir. Her atlamanın SEBEBİ
# basılır ve sonda ayrıca listelenir.
t_skip() {
    ATLANAN=$((ATLANAN + 1))
    ATLANAN_ADLAR+=("$1")
    printf '%s  [ATLANDI]%s %s\n' "$YELLOW" "$NC" "$1"
    printf '             sebep: %s\n' "${2:-belirtilmedi}"
    return 0
}

# ------------------------------------------------------------ genel yardımcı --
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

# Katalogdan alan oku. Portlar, servis adları, replikasyon/devir yetenekleri
# TEK YETKİ KAYNAĞINDAN gelir; burada sabit yazmak, katalog değiştiğinde
# sessizce yanlış düğümü test etmek demekti.
kat() {   # kat <motor> <python-ifadesi>
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e: sys.exit(1)
print(eval(sys.argv[3], {"e": e[0]}))' "$CATALOG" "$1" "$2" 2>/dev/null
}

denetlenen_motorlar() {
    python3 -c '
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
for e in c["engines"]:
    f = e.get("failover", {})
    if f.get("supported") and f.get("mode") == "supervised":
        print(e["id"])' "$CATALOG"
}

durum_listesinde() {   # durum_listesinde <anahtar> <değer>   (state/state.json)
    python3 -c '
import json, sys
try:
    s = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if sys.argv[3] in (s.get(sys.argv[2]) or []) else 1)' \
        "$STACK_ROOT/state/state.json" "$1" "$2"
}

profil_kurulu()   { durum_listesinde profiles       "$1"; }
oto_devir_acik()  { durum_listesinde auto_failover  "$1"; }

# Devirden sonra roller terstir: kataloğun "replica_service"i canlı ana kopya
# olabilir. Yedek düğümü her zaman ŞU ANKİ ana kopyaya göre hesaplıyoruz —
# sabit ad kullanan bir test, ikinci koşuda yanlış düğümü durdururdu.
yedek_dugum() {   # yedek_dugum <motor> <şu anki primary>
    if [ "$2" = "$M_PRIM_SVC" ]; then printf '%s' "$M_REP_SVC"
    else printf '%s' "$M_PRIM_SVC"; fi
}

# Denetleyicinin devir bekleme süresinden (cooldown) kaç saniye kaldı.
# Betik üst üste çalıştırıldığında ikinci koşu bu yüzden devir yapamaz;
# bilmeden beklemek yerine söylüyoruz.
sogutma_kalan() {   # sogutma_kalan <motor>
    python3 -c '
import json, sys, time
try:
    g = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    g = {}
try:
    son = float(g.get(sys.argv[2], 0))
except (TypeError, ValueError):
    son = 0.0
kalan = int(son + int(sys.argv[3]) - time.time())
print(kalan if kalan > 0 else 0)' "$STACK_ROOT/state/failover-guard.json" "$1" "$SOGUTMA"
}

# Controller yeni açıldıysa (sunucu reboot'u, ./install.sh) FAILOVER_STARTUP_GRACE
# boyunca hiç devir kararı vermez. Beklediğimiz süreye bunu EKLEMEZSEK test,
# ürünün doğru davranışını "devir olmadı" diye raporlardı.
lutuf_kalan() {
    local basladi t simdi k
    basladi="$(docker inspect -f '{{.State.StartedAt}}' controller 2>/dev/null)" || basladi=""
    [ -n "$basladi" ] || { printf '0'; return; }
    t="$(date -d "$basladi" +%s 2>/dev/null)" || t=""
    [ -n "$t" ] || { printf '0'; return; }
    simdi="$(date +%s)"
    k=$(( LUTUF - (simdi - t) ))
    if [ "$k" -gt 0 ]; then printf '%s' "$k"; else printf '0'; fi
}

# Olay kaydı — reddedilen bir devir SESSİZ kalmamalı. Ürünün en pahalı
# hatalarından biri buydu: gece 03:00'te devir "yedek hazır değil" diye
# vazgeçiyor, hiçbir yere yazılmıyor, operatör durumu uygulama şikâyetiyle
# öğreniyordu.
olay_var() {   # olay_var <motor> <kind> <ts_alt_sinir>   0=var 1=yok 2=dosya yok
    python3 -c '
import json, sys
try:
    satirlar = open(sys.argv[1], encoding="utf-8").read().splitlines()[-500:]
except OSError:
    sys.exit(2)
for s in satirlar:
    try:
        e = json.loads(s)
    except ValueError:
        continue
    if (e.get("engine") == sys.argv[2] and e.get("kind") == sys.argv[3]
            and int(e.get("ts", 0)) >= int(sys.argv[4])):
        print((e.get("message") or "")[:180])
        sys.exit(0)
sys.exit(1)' "$STACK_ROOT/state/events.jsonl" "$1" "$2" "$3"
}

# ------------------------------------------------- durdurulan düğüm defteri --
# Betik bir düğümü durdurursa bunu YAZAR. Kesilirse (Ctrl-C) ya da bir adım
# beklenmedik biçimde biterse geri açar: kullanıcının veritabanını kapalı
# bırakan bir test aracı, hatanın kendisidir.
DURDURULAN=()

dugum_durdur() {
    docker stop -t 15 "$1" >/dev/null 2>&1
    DURDURULAN+=("$1")
}

dugum_baslat() {
    docker start "$1" >/dev/null 2>&1
    dugum_unut "$1"
}

dugum_unut() {   # devirden sonra fence edilmiş eski primary'yi GERİ AÇMAYIZ
    local yeni=() c
    for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
        [ "$c" = "$1" ] || yeni+=("$c")
    done
    DURDURULAN=(${yeni[@]+"${yeni[@]}"})
}

acil_cikis() {
    local c
    warn "kesildi — betiğin durdurduğu düğümler geri açılıyor"
    for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
        docker start "$c" >/dev/null 2>&1 && warn "  $c geri açıldı"
    done
    rm -rf "$TMP"
    exit 130
}
trap acil_cikis INT TERM
# Geçici dizin HER çıkışta silinir — ön koşul kontrollerinde die() ile erken
# çıkılan yollar dahil; test aracı /tmp'de çöp bırakmaz.
trap 'rm -rf "$TMP"' EXIT

# =============================================================================
# MOTOR BAĞLAMI — her şey katalogdan + .env'den
# =============================================================================
motor_baglami() {   # motor_baglami <motor>
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
# VERİ YAZ / OKU
# =============================================================================
# gw_* → GATEWAY üzerinden (uygulamanın gördüğü adres; devirde değişmemeli)
# dugum_* → doğrudan container'ın içinden (replikasyon gerçekten aktı mı?)

gw_yaz() {   # gw_yaz <motor> <asama> <deger>
    local eid="$1" asama="$2" deger="$3"
    case "$eid" in
    mariadb)
        MYSQL_PWD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e MYSQL_PWD --entrypoint mariadb "$M_IMAJ" \
            -h gateway -P "$M_LISTEN" -u "$M_KULLANICI" -D "$M_VTABANI" \
            --connect-timeout=10 -N -B -e \
            "CREATE TABLE IF NOT EXISTS $TABLO (asama VARCHAR(64) PRIMARY KEY, damga VARCHAR(96) NOT NULL) ENGINE=InnoDB;
             REPLACE INTO $TABLO (asama, damga) VALUES ('$asama', '$deger');" >/dev/null 2>&1
        ;;
    postgresql)
        PGPASSWORD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e PGPASSWORD --entrypoint psql "$M_IMAJ" \
            -h gateway -p "$M_LISTEN" -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAq -c \
            "CREATE TABLE IF NOT EXISTS $TABLO (asama text PRIMARY KEY, damga text NOT NULL);
             INSERT INTO $TABLO (asama, damga) VALUES ('$asama', '$deger')
             ON CONFLICT (asama) DO UPDATE SET damga = EXCLUDED.damga;" >/dev/null 2>&1
        ;;
    redis)
        # redis-cli çıkış kodu her sürümde hatayı yansıtmıyor; read-only bir
        # düğüme yazınca "-READONLY …" basar. Bu yüzden ÇIKTIYA bakıyoruz.
        local cikti
        cikti="$(REDISCLI_AUTH="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm \
            --network "$AG" -e REDISCLI_AUTH --entrypoint redis-cli "$M_IMAJ" \
            --no-auth-warning -h gateway -p "$M_LISTEN" \
            SET "$ANAHTAR_ONEK:$asama" "$deger" 2>&1)"
        [ "$(printf '%s' "$cikti" | tr -d '[:space:]')" = "OK" ]
        ;;
    *) return 1 ;;
    esac
}

gw_oku() {   # gw_oku <motor> <asama>  → değeri stdout'a basar
    local eid="$1" asama="$2"
    case "$eid" in
    mariadb)
        MYSQL_PWD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e MYSQL_PWD --entrypoint mariadb "$M_IMAJ" \
            -h gateway -P "$M_LISTEN" -u "$M_KULLANICI" -D "$M_VTABANI" \
            --connect-timeout=10 -N -B -e \
            "SELECT damga FROM $TABLO WHERE asama = '$asama';" 2>/dev/null | tr -d '[:space:]'
        ;;
    postgresql)
        PGPASSWORD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e PGPASSWORD --entrypoint psql "$M_IMAJ" \
            -h gateway -p "$M_LISTEN" -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAc \
            "SELECT damga FROM $TABLO WHERE asama = '$asama';" 2>/dev/null | tr -d '[:space:]'
        ;;
    redis)
        REDISCLI_AUTH="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e REDISCLI_AUTH --entrypoint redis-cli "$M_IMAJ" --no-auth-warning \
            -h gateway -p "$M_LISTEN" GET "$ANAHTAR_ONEK:$asama" 2>/dev/null | tr -d '[:space:]'
        ;;
    esac
}

dugum_oku() {   # dugum_oku <motor> <container> <asama>
    local eid="$1" c="$2" asama="$3"
    case "$eid" in
    mariadb)
        MYSQL_PWD="$M_PAROLA" timeout "$ISTEMCI_TO" docker exec -e MYSQL_PWD "$c" \
            mariadb -u "$M_KULLANICI" -D "$M_VTABANI" -N -B \
            -e "SELECT damga FROM $TABLO WHERE asama = '$asama';" 2>/dev/null | tr -d '[:space:]'
        ;;
    postgresql)
        PGPASSWORD="$M_PAROLA" timeout "$ISTEMCI_TO" docker exec -e PGPASSWORD "$c" \
            psql -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAc \
            "SELECT damga FROM $TABLO WHERE asama = '$asama';" 2>/dev/null | tr -d '[:space:]'
        ;;
    redis)
        REDISCLI_AUTH="$M_PAROLA" timeout "$ISTEMCI_TO" docker exec -e REDISCLI_AUTH "$c" \
            redis-cli --no-auth-warning GET "$ANAHTAR_ONEK:$asama" 2>/dev/null | tr -d '[:space:]'
        ;;
    esac
}

# Karşılaştırmalı bekleme yüklemleri (bekle() bunları çağırır)
_gw_es()    { [ "$(gw_oku "$1" "$2")" = "$3" ]; }
_dugum_es() { [ "$(dugum_oku "$1" "$2" "$3")" = "$4" ]; }
_gw_yazilir() { gw_yaz "$1" "$2" "$3" && _gw_es "$1" "$2" "$3"; }

test_verisi_sil() {   # gateway üzerinden siler → silme de replikaya akar
    local eid="$1"
    case "$eid" in
    mariadb)
        MYSQL_PWD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e MYSQL_PWD --entrypoint mariadb "$M_IMAJ" \
            -h gateway -P "$M_LISTEN" -u "$M_KULLANICI" -D "$M_VTABANI" \
            --connect-timeout=10 -N -B -e "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1
        ;;
    postgresql)
        PGPASSWORD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e PGPASSWORD --entrypoint psql "$M_IMAJ" \
            -h gateway -p "$M_LISTEN" -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAq -c \
            "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1
        ;;
    redis)
        REDISCLI_AUTH="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e REDISCLI_AUTH --entrypoint redis-cli "$M_IMAJ" --no-auth-warning \
            -h gateway -p "$M_LISTEN" DEL \
            "$ANAHTAR_ONEK:$AS_ONCE" "$ANAHTAR_ONEK:$AS_KAPI" "$ANAHTAR_ONEK:$AS_ONARIM" \
            "$ANAHTAR_ONEK:$AS_SONRA" "$ANAHTAR_ONEK:$AS_REBUILD" >/dev/null 2>&1
        ;;
    esac
}

# "yok" | "var" | "sorulamadi"
# Üçüncü hâl ŞART: sorgu hiç çalışmadıysa (gateway ölü, motor kapalı) boş cevap
# gelir ve "boş = silinmiş" saymak, geride kalan test tablosunu temizlenmiş
# gibi raporlardı — yani temizlik testi tam da temizlik yapılamayan durumda
# yeşil yanardı.
test_verisi_durumu() {
    local eid="$1" c
    case "$eid" in
    mariadb)
        c="$(MYSQL_PWD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e MYSQL_PWD --entrypoint mariadb "$M_IMAJ" \
            -h gateway -P "$M_LISTEN" -u "$M_KULLANICI" -D "$M_VTABANI" \
            --connect-timeout=10 -N -B -e \
            "SELECT COUNT(*) FROM information_schema.TABLES
              WHERE table_schema = DATABASE() AND table_name = '$TABLO';" \
            2>/dev/null | tr -d '[:space:]')"
        ;;
    postgresql)
        c="$(PGPASSWORD="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e PGPASSWORD --entrypoint psql "$M_IMAJ" \
            -h gateway -p "$M_LISTEN" -U "$M_KULLANICI" -d "$M_VTABANI" -w -tAc \
            "SELECT COUNT(*) FROM pg_class WHERE relname = '$TABLO';" \
            2>/dev/null | tr -d '[:space:]')"
        ;;
    redis)
        c="$(REDISCLI_AUTH="$M_PAROLA" timeout "$ISTEMCI_TO" docker run --rm --network "$AG" \
            -e REDISCLI_AUTH --entrypoint redis-cli "$M_IMAJ" --no-auth-warning \
            -h gateway -p "$M_LISTEN" EXISTS \
            "$ANAHTAR_ONEK:$AS_ONCE" "$ANAHTAR_ONEK:$AS_KAPI" "$ANAHTAR_ONEK:$AS_ONARIM" \
            "$ANAHTAR_ONEK:$AS_SONRA" "$ANAHTAR_ONEK:$AS_REBUILD" 2>/dev/null | tr -d '[:space:]')"
        ;;
    esac
    case "$c" in
        "")  printf 'sorulamadi' ;;
        0)   printf 'yok' ;;
        *)   printf 'var' ;;
    esac
}

# Ürünün KENDİ yükseltme betiği — testin kendi ölçüsünü uydurması yerine
# controller'ın kullandığı ölçüyü kullanıyoruz:
#   check <servis> → yazılabilir ana kopya mı?   ready <servis> → yükseltilebilir mi?
fo_betik() {   # fo_betik <faz> <servis>
    sh "$STACK_ROOT/scripts/failover/$M_BETIK.sh" "$1" "$2" 2>&1
}
fo_sessiz() { fo_betik "$1" "$2" >/dev/null 2>&1; }

# =============================================================================
# 1) ÖN KOŞULLAR — yedek kopya + otomatik devir
# =============================================================================
onkosullar() {   # 0 = zincire devam edilebilir
    local eid="$1" prim
    prim="$(primary_of "$eid")"

    if ! container_running "$prim"; then
        t_skip "$eid: devir zinciri" \
               "motor kapalı ($prim çalışmıyor). Açmak için: ./stack.sh enable $eid"
        return 1
    fi
    if [ -z "$M_PAROLA" ]; then
        t_skip "$eid: devir zinciri" \
               "$M_PAROLA_ENV ve DB_PASSWORD boş — istemci bağlanamaz, ölçüm yapılamaz"
        return 1
    fi
    M_IMAJ="$(motor_imaji "$prim")"
    if [ -z "$M_IMAJ" ]; then
        t_skip "$eid: devir zinciri" "$prim container'ının imajı okunamadı (docker inspect)"
        return 1
    fi
    if [ -z "$M_REP_SVC" ] || [ -z "$M_REP_PROFIL" ]; then
        t_skip "$eid: devir zinciri" "katalogda replika servisi/profili tanımlı değil"
        return 1
    fi

    # --- yedek kopya --------------------------------------------------------
    # Yoksa ÜRÜNÜN KENDİ komutuyla kurulur; sessizce geçilmez. Kurulum ürünün
    # arayüzünden geçtiği için testin kendisi de bir kullanım senaryosudur.
    if ! profil_kurulu "$M_REP_PROFIL"; then
        if [ "$KUR" != "1" ]; then
            t_skip "$eid: devir zinciri" \
                   "yedek kopya kurulu değil ve E2E_KUR=0. Kurmak için: ./stack.sh replica on $eid"
            return 1
        fi
        log "$eid: yedek kopya kurulu değil — './stack.sh replica on $eid' çalıştırılıyor"
        log "   (ilk kopyalama veritabanı büyüklüğüne göre dakikalar sürebilir; üst sınır ${REPLIKA_TO} sn)"
        if ! timeout "$REPLIKA_TO" ./stack.sh replica on "$eid" > "$TMP/replica.log" 2>&1; then
            t_fail "$eid: yedek kopya kuruldu (./stack.sh replica on)" \
                   "kurulum başarısız: $(tail -n 3 "$TMP/replica.log" | tr '\n' ' ')"
            return 1
        fi
    fi
    local yedek; yedek="$(yedek_dugum "$eid" "$prim")"
    if profil_kurulu "$M_REP_PROFIL" && container_running "$yedek"; then
        t_ok "$eid: yedek kopya ayakta ve replikasyon profili etkin ($yedek / $M_REP_PROFIL)"
    else
        # Yarım kalmış replikasyon en tehlikeli hâldir: dashboard "yedek var"
        # der, devir onu yükseltir ve ESKİ verisini sunmaya başlar.
        t_fail "$eid: yedek kopya ayakta ve replikasyon profili etkin" \
               "profil kurulu mu: $(profil_kurulu "$M_REP_PROFIL" && echo evet || echo hayır), $yedek çalışıyor mu: $(container_running "$yedek" && echo evet || echo hayır)"
        return 1
    fi

    # --- otomatik devir -----------------------------------------------------
    OTO_BIZ_ACTIK=0
    if ! oto_devir_acik "$eid"; then
        log "$eid: otomatik devir kapalı — './stack.sh failover on $eid' çalıştırılıyor"
        if timeout 120 ./stack.sh failover on "$eid" > "$TMP/oto.log" 2>&1; then
            OTO_BIZ_ACTIK=1
        fi
    fi
    if oto_devir_acik "$eid"; then
        t_ok "$eid: otomatik devir açık — denetleyici ana kopyayı izliyor (state.json/auto_failover)"
    else
        t_fail "$eid: otomatik devir açık" \
               "açılamadı: $(tail -n 2 "$TMP/oto.log" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# =============================================================================
# 2) TEMEL: gateway üzerinden yaz → replikada gör
# =============================================================================
temel_veri() {   # 0 = devam
    local eid="$1" prim yedek
    prim="$(primary_of "$eid")"; yedek="$(yedek_dugum "$eid" "$prim")"

    if _gw_yazilir "$eid" "$AS_ONCE" "$KOSU-once"; then
        t_ok "$eid: gateway:$M_LISTEN üzerinden yazılan satır aynı adresten geri okundu (devir öncesi)"
    else
        t_fail "$eid: gateway:$M_LISTEN üzerinden yazılan satır aynı adresten geri okundu (devir öncesi)" \
               "gateway üzerinden yazma/okuma çalışmıyor — yönlendirme bozuksa devir testi anlamsız olur"
        t_skip "$eid: devir zincirinin kalanı" "temel yazma çalışmadan ana kopya öldürülmez"
        return 1
    fi

    if bekle "$AKIS_TO" "'$AS_ONCE' satırı $yedek düğümüne ulaşsın (replikasyon)" \
             _dugum_es "$eid" "$yedek" "$AS_ONCE" "$KOSU-once"; then
        t_ok "$eid: devir öncesi yazılan satır yedek kopyada ($yedek) göründü — replikasyon akıyor"
    else
        t_fail "$eid: devir öncesi yazılan satır yedek kopyada ($yedek) göründü" \
               "replikasyon akmıyor; bu hâldeyken devir veri kaybıdır"
        t_skip "$eid: devir zincirinin kalanı" \
               "replikasyon akmıyorken ana kopyayı öldürmek gerçek veri kaybı riskidir"
        return 1
    fi
    return 0
}

# =============================================================================
# 3) GÜVENLİK KAPISI — replikasyon sağlıksızken devir YAPILMAMALI
# =============================================================================
# Bu kapı olmadan gerçek bir sunucuda veri kaybedildi: senkron olmamış replika
# yükseltildi, ana kopya fence edildi ve aradaki yazılar bir daha görülmedi.
# Testin kendisi de aynı riski taşıdığı için TETİKLEMEDEN ÖNCE bozmanın
# gerçekten tuttuğunu ürünün kendi 'ready' ölçüsüyle doğruluyoruz.
guvenlik_kapisi() {   # 0 = zincire devam edilebilir
    local eid="$1" prim yedek bozma ts0 cikti rc
    prim="$(primary_of "$eid")"; yedek="$(yedek_dugum "$eid" "$prim")"
    ts0="$(date +%s)"

    case "$eid" in
    mariadb)
        # SQL iş parçacığını durdurmak, "container ayakta ama replikasyon
        # akmıyor" hâlinin birebir kendisidir — devir betiğinin 'ready' kapısı
        # tam olarak bunu yakalamalı.
        MYSQL_PWD="$M_PAROLA" timeout "$ISTEMCI_TO" docker exec -e MYSQL_PWD "$yedek" \
            mariadb -u "$M_KULLANICI" -N -e "STOP SLAVE SQL_THREAD;" >/dev/null 2>&1
        bozma="replikanın SQL iş parçacığı durduruldu"
        ;;
    *)
        # PostgreSQL/Redis'te replikasyonu "yarım" bırakmanın güvenilir yolu
        # yok (bozdum sanıp bozamamak, canlı ana kopyayı öldürtürdü). Yedeği
        # tamamen devre dışı bırakmak aynı kapıyı ölçer: yükseltilecek sağlam
        # kopya yokken ana kopyaya dokunulmamalı.
        dugum_durdur "$yedek"
        bozma="yedek kopya ($yedek) durduruldu"
        ;;
    esac

    if fo_sessiz ready "$yedek"; then
        t_skip "$eid: replikasyon sağlıksızken devir REDDEDİLİR" \
               "yedeği bozamadık ($bozma sonrası ürünün 'ready' ölçüsü hâlâ 'hazır' diyor); canlı ana kopyayı riske atmamak için devir TETİKLENMEDİ"
        t_skip "$eid: reddedilen devirde ana kopyaya dokunulmaz" "devir tetiklenmedi"
        t_skip "$eid: devir reddi olay kaydına yazılır" "devir tetiklenmedi"
        # Bozmayı yine de geri alıyoruz; onarımın tuttuğunu ölçmeden yıkıcı
        # kısma geçmek veri kaybı riskidir.
        kapi_onar "$eid" "$yedek"
        return
    fi

    log "$eid: replikasyon bilerek bozuldu ($bozma) — şimdi elle devir tetikleniyor"
    cikti="$(printf 'evet\n' | timeout "$ELLE_DEVIR_TO" ./stack.sh failover now "$eid" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        t_ok "$eid: replikasyon sağlıksızken ($bozma) devir REDDEDİLDİ"
    else
        t_fail "$eid: replikasyon sağlıksızken ($bozma) devir REDDEDİLDİ" \
               "devir YAPILDI — güvenlik kapısı çalışmıyor, bu hâl gerçek veri kaybıdır. Çıktı: $(printf '%s' "$cikti" | tail -n 3 | tr '\n' ' ')"
    fi

    # Ana kopyaya dokunulmadı mı? "Container ayakta" yetmez: fence edilmiş ama
    # geri açılmış bir düğüm de ayakta görünür. Aynı adresten YAZIP okuyoruz.
    # Ölçümler bir kez yapılır; hata satırında tekrarlamak, ikinci denemede
    # tutan geçici bir arızayı gizlerdi.
    local ayakta="hayır" topo yazma="ÇALIŞMIYOR" dokunulmadi=1
    container_running "$prim" && ayakta="evet" || dokunulmadi=0
    topo="$(primary_of "$eid")"
    [ "$topo" = "$prim" ] || dokunulmadi=0
    if _gw_yazilir "$eid" "$AS_KAPI" "$KOSU-kapi"; then yazma="çalışıyor"; else dokunulmadi=0; fi
    if [ "$dokunulmadi" = "1" ]; then
        t_ok "$eid: reddedilen devirde ana kopyaya dokunulmadı ($prim ayakta, gateway'den hâlâ yazılıyor)"
    else
        t_fail "$eid: reddedilen devirde ana kopyaya dokunulmadı" \
               "$prim ayakta mı: $ayakta, topolojideki ana kopya: $topo (beklenen $prim), gateway'den yazma: $yazma"
    fi

    # Red SESSİZ kalmamalı.
    local mesaj rc2
    mesaj="$(olay_var "$eid" failover_blocked "$((ts0 - 2))")"; rc2=$?
    case "$rc2" in
    0) t_ok "$eid: devir reddi olay kaydına yazıldı (sessiz vazgeçme yok)" ;;
    2) t_skip "$eid: devir reddi olay kaydına yazılır" "state/events.jsonl okunamadı" ;;
    *) t_fail "$eid: devir reddi olay kaydına yazıldı (sessiz vazgeçme yok)" \
              "state/events.jsonl içinde failover_blocked kaydı yok — operatör devrin neden yapılmadığını öğrenemez" ;;
    esac
    [ -n "$mesaj" ] && printf '            olay: %s\n' "$mesaj"

    kapi_onar "$eid" "$yedek"
}

# Bozduğumuzu ONARIRIZ ve onarımı ÖLÇERİZ. Onarılmadıysa zincirin yıkıcı
# kısmına geçmek gerçek veri kaybı riskidir — orada dururuz.
kapi_onar() {   # kapi_onar <motor> <yedek>
    local eid="$1" yedek="$2"
    case "$eid" in
    mariadb)
        MYSQL_PWD="$M_PAROLA" timeout "$ISTEMCI_TO" docker exec -e MYSQL_PWD "$yedek" \
            mariadb -u "$M_KULLANICI" -N -e "START SLAVE;" >/dev/null 2>&1
        ;;
    *)
        dugum_baslat "$yedek"
        ;;
    esac
    if ! bekle 120 "$yedek yeniden yükseltilebilir duruma gelsin (ürünün 'ready' ölçüsü)" \
                fo_sessiz ready "$yedek"; then
        t_fail "$eid: güvenlik kapısı testinden sonra replikasyon onarıldı" \
               "$yedek 120 sn'de yeniden hazır olmadı; zincirin yıkıcı kısmı ATLANIYOR"
        return 1
    fi
    if gw_yaz "$eid" "$AS_ONARIM" "$KOSU-onarim" \
       && bekle "$AKIS_TO" "'$AS_ONARIM' satırı $yedek düğümüne ulaşsın" \
                _dugum_es "$eid" "$yedek" "$AS_ONARIM" "$KOSU-onarim"; then
        t_ok "$eid: güvenlik kapısı testinden sonra replikasyon yeniden akıyor ($yedek güncel)"
        return 0
    fi
    t_fail "$eid: güvenlik kapısı testinden sonra replikasyon yeniden akıyor" \
           "$yedek yeni satırı almadı; zincirin yıkıcı kısmı ATLANIYOR"
    return 1
}

# =============================================================================
# 4-6) ANA KOPYAYI ÖLDÜR → DEVİR → AYNI ADRES → VERİ DURUYOR MU
# =============================================================================
devir_zinciri() {   # 0 = devam (rebuild aşamasına)
    local eid="$1" eski yeni t0 gecen butce lk sk son_log

    # Denetleyici bekleme süresindeyse (art arda iki koşu) devir yapmaz.
    # Bunu bilmeden beklemek "devir çalışmıyor" gibi görünürdü.
    sk="$(sogutma_kalan "$eid")"
    if [ "${sk:-0}" -gt 0 ]; then
        if [ "$sk" -le "$SOGUTMA_MAX" ]; then
            log "$eid: denetleyici devir bekleme süresinde (FAILOVER_COOLDOWN=$SOGUTMA sn)"
            uyu_sayarak "$sk" "devir bekleme süresinin dolması bekleniyor"
        else
            t_skip "$eid: ana kopya öldürülünce devir kendiliğinden tamamlanır" \
                   "son devir çok yeni; denetleyici $sk sn daha devir yapmaz (FAILOVER_COOLDOWN=$SOGUTMA). E2E_SOGUTMA_MAX ile bekleme süresini artırabilir ya da sonra tekrar çalıştırabilirsiniz."
            t_skip "$eid: devir controller logunda '4/4 tamam' ile kapandı" "devir tetiklenmedi"
            t_skip "$eid: devirden sonra AYNI ADRESTEN yazma çalışıyor" "devir tetiklenmedi"
            t_skip "$eid: devir öncesi yazılan satır yeni ana kopyada duruyor" "devir tetiklenmedi"
            return 1
        fi
    fi

    eski="$(primary_of "$eid")"
    lk="$(lutuf_kalan)"
    butce=$(( DEVIR_BEKLE + lk ))
    [ "$lk" -gt 0 ] && log "$eid: controller yeni açılmış — açılış lütuf süresi için $lk sn ekleniyor"
    log "$eid: ana kopya ($eski) BİLEREK durduruluyor; denetleyici ~$((VURUS * ARALIK)) sn içinde devri kendisi yapmalı"
    t0="$(date +%s)"
    dugum_durdur "$eski"

    if bekle "$butce" "denetleyici devri tamamlasın (topolojide ana kopya $eski olmaktan çıksın)" \
             _primary_degisti "$eid" "$eski"; then
        yeni="$(primary_of "$eid")"
        # Devir başarılıysa eski ana kopya FENCE edilmiş demektir; geri açmak
        # split-brain olurdu. Defterden düşüyoruz ki çıkışta açılmasın.
        dugum_unut "$eski"
        t_ok "$eid: ana kopya ($eski) öldürülünce devir kendiliğinden tamamlandı — yeni ana kopya: $yeni"
    else
        # Kullanıcının veritabanını kapalı bırakmıyoruz.
        warn "$eid: devir olmadı — durdurduğumuz ana kopya ($eski) geri açılıyor"
        dugum_baslat "$eski"
        t_fail "$eid: ana kopya öldürülünce devir kendiliğinden tamamlandı" \
               "$butce sn içinde topolojide ana kopya değişmedi. 'docker logs controller' ve './stack.sh events' çıktısına bakın. Ana kopya geri açıldı."
        t_skip "$eid: devir controller logunda '4/4 tamam' ile kapandı" "devir gerçekleşmedi"
        t_skip "$eid: devirden sonra AYNI ADRESTEN yazma çalışıyor" "devir gerçekleşmedi"
        t_skip "$eid: devir öncesi yazılan satır yeni ana kopyada duruyor" "devir gerçekleşmedi"
        return 1
    fi

    # Devir 4 adımdır (fence → promote → reroute → kayıt). Yalnız son adım
    # "4/4 tamam" der; ara adımda kalmış bir devir (yönlendirme güncellenmemiş)
    # topolojiye bakınca tamam görünürdü.
    gecen=$(( $(date +%s) - t0 + 10 ))
    son_log="$(docker logs controller --since "${gecen}s" 2>&1 | grep -F '4/4 tamam' | tail -n 1)"
    if [ -n "$son_log" ] && printf '%s' "$son_log" | grep -Fq "$yeni"; then
        t_ok "$eid: devir controller logunda '4/4 tamam' ile kapandı (yeni ana kopya: $yeni)"
    else
        t_fail "$eid: devir controller logunda '4/4 tamam' ile kapandı" \
               "son ${gecen} sn'lik controller logunda '4/4 tamam … $yeni' satırı yok: ${son_log:-(satır yok)}"
    fi

    # ÜRÜNÜN ANA VAADİ: uygulamanın bağlantı adresi değişmez. nginx yeniden
    # yüklendikten sonra istemcinin yeniden bağlanması birkaç saniye sürebilir;
    # bu yüzden ölçüm tekrarlanır ama süresi sınırlıdır.
    if bekle 90 "gateway:$M_LISTEN yeni ana kopyaya yönlensin (uygulama adresi değişmeden)" \
             _gw_yazilir "$eid" "$AS_SONRA" "$KOSU-sonra"; then
        t_ok "$eid: devirden sonra AYNI ADRESTEN (gateway:$M_LISTEN) yazma çalışıyor — uygulamanın bağlantı adresi değişmedi"
    else
        t_fail "$eid: devirden sonra AYNI ADRESTEN (gateway:$M_LISTEN) yazma çalışıyor" \
               "yedek yükseldi ama gateway trafiği oraya taşımıyor; uygulamalar hâlâ bağlanamaz (yönlendirme tablosu/nginx reload)"
    fi

    # Devirden önce yazdığımız satır duruyor mu? Asenkron replikasyonda kayıp
    # ancak ana kopyanın göndermeye yetişemediği kadar olabilir; bizim satır
    # devirden dakikalar önce yazıldı ve replikada GÖRÜLDÜ — kaybolması,
    # yükseltmenin yanlış düğümü seçtiği (ya da hacmin silindiği) anlamına gelir.
    local deger; deger="$(gw_oku "$eid" "$AS_ONCE")"
    if [ "$deger" = "$KOSU-once" ]; then
        t_ok "$eid: devir öncesi yazılan satır yeni ana kopyada duruyor — veri kaybı yok"
    else
        t_fail "$eid: devir öncesi yazılan satır yeni ana kopyada duruyor" \
               "beklenen '$KOSU-once', okunan '${deger:-(boş)}' — devirde veri kaybedildi"
    fi
    return 0
}

_primary_degisti() { [ "$(primary_of "$1")" != "$2" ]; }

# =============================================================================
# 7) REBUILD — eski ana kopyayı yedek olarak geri al
# =============================================================================
rebuild_zinciri() {
    local eid="$1" prim eski
    prim="$(primary_of "$eid")"
    eski="$(yedek_dugum "$eid" "$prim")"

    log "$eid: './stack.sh failover rebuild $eid' — $eski, $prim'in yedeği olarak yeniden kuruluyor"
    if timeout "$REBUILD_TO" ./stack.sh failover rebuild "$eid" > "$TMP/rebuild.log" 2>&1; then
        t_ok "$eid: eski ana kopya ($eski) './stack.sh failover rebuild' ile yedek olarak geri alındı"
    else
        t_fail "$eid: eski ana kopya ($eski) './stack.sh failover rebuild' ile yedek olarak geri alındı" \
               "$(tail -n 4 "$TMP/rebuild.log" | tr '\n' ' ')"
        t_skip "$eid: geri alınan düğüm ikinci bir YAZILABİLİR ana kopya değil" "rebuild başarısız"
        t_skip "$eid: yeniden kurulan yedeğe replikasyon tekrar akıyor" "rebuild başarısız"
        return 1
    fi

    # En pahalı sessiz arıza: düğüm ayağa kalkar ama YEDEK DEĞİL, ikinci bir
    # yazılabilir ana kopyadır (hacim silinememiş, rol env'i okunmamış). İki
    # kopya da yazı kabul ederse veriler ayrışır ve birleştirilemez.
    local ayakta="hayır" rol="yedek/erişilemez"
    container_running "$eski" && ayakta="evet"
    fo_sessiz check "$eski" && rol="YAZILABİLİR ANA KOPYA"
    if [ "$ayakta" = "evet" ] && [ "$rol" != "YAZILABİLİR ANA KOPYA" ]; then
        t_ok "$eid: geri alınan düğüm ($eski) ikinci bir YAZILABİLİR ana kopya değil — split-brain yok"
    else
        t_fail "$eid: geri alınan düğüm ($eski) ikinci bir YAZILABİLİR ana kopya değil" \
               "$eski ayakta mı: $ayakta; ürünün 'check' ölçüsüne göre rolü: $rol"
    fi

    if gw_yaz "$eid" "$AS_REBUILD" "$KOSU-rebuild" \
       && bekle "$AKIS_TO" "'$AS_REBUILD' satırı yeniden kurulan yedeğe ($eski) ulaşsın" \
                _dugum_es "$eid" "$eski" "$AS_REBUILD" "$KOSU-rebuild"; then
        t_ok "$eid: yeniden kurulan yedeğe ($eski) replikasyon tekrar akıyor — yeni satır yedekte göründü"
    else
        t_fail "$eid: yeniden kurulan yedeğe ($eski) replikasyon tekrar akıyor" \
               "gateway'den yazılan satır ${AKIS_TO} sn'de $eski düğümüne ulaşmadı; yedek kuruldu ama beslenmiyor"
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
        t_skip "$eid: test verisi silindi (betik üst üste çalıştırılabilir)" \
               "gateway:$M_LISTEN üzerinden sorgu çalışmadı; temizlik DOĞRULANAMADI, $TABLO / $ANAHTAR_ONEK:* kalmış olabilir" ;;
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
        t_skip "$eid: devir zinciri" "katalog kaydı okunamadı (catalog.json)"
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
                   "güvenlik kapısı testinden sonra replikasyon onarılamadı — ana kopya öldürülmedi"
        fi
    fi
    zincir_temizlik "$eid"
}

# =============================================================================
# GİRİŞ
# =============================================================================
require_docker
[ -f "$ENV_FILE" ] || die ".env yok — bu betik KURULU bir yığına karşı çalışır. Önce: ./install.sh"
[ -f "$CATALOG" ] || die "catalog.json bulunamadı: $CATALOG"
container_running controller || die "controller çalışmıyor — devir kararlarını o veriyor. Önce: ./stack.sh up"
container_running gateway    || die "gateway çalışmıyor — 'aynı adres' vaadi ancak onun üzerinden ölçülebilir. Önce: ./stack.sh up"

# Yedekleme kilidiyle AYNI kilidi alıyoruz. Sebebi somut: rebuild bir veri
# hacmini siler, o sırada çalışan bir yedekleme hacmi tutar ve rebuild
# "hacim kullanımda" diye başarısız olur — test de ürünü haksız yere suçlar.
acquire_lock /tmp/databases-stack-backup.lock

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
        if ! kat "$arg" 'e["id"]' >/dev/null 2>&1; then
            die "Bilinmeyen veritabanı: $arg — geçerli olanlar: $(denetlenen_motorlar | tr '\n' ' ')"
        fi
        # Katalog "bu motorda devir denetlenmiyor" diyorsa test de bunu
        # RAPOR EDER; sessizce listeden düşürmek, kullanıcının istediği testin
        # hiç çalışmadığını gizlerdi.
        mod="$(kat "$arg" 'e["failover"].get("mode","none")')"
        if [ "$mod" != "supervised" ]; then
            t_skip "$arg: devir zinciri" \
                   "katalogda failover.mode=$mod — controller devri yönetmiyor: $(kat "$arg" 'e["failover"].get("note","")')"
            continue
        fi
        MOTORLAR+=("$arg")
    done
else
    while IFS= read -r m; do [ -n "$m" ] && MOTORLAR+=("$m"); done < <(denetlenen_motorlar)
fi

log "test edilecek motorlar: ${MOTORLAR[*]-(yok)}"

for eid in ${MOTORLAR[@]+"${MOTORLAR[@]}"}; do
    motor_zinciri "$eid"
done

# Bir aksilikte açık kalmış olabilecek düğümler — kullanıcının veritabanını
# kapalı bırakmıyoruz.
for c in ${DURDURULAN[@]+"${DURDURULAN[@]}"}; do
    warn "betiğin durdurduğu $c geri açılıyor"
    docker start "$c" >/dev/null 2>&1
done
rm -rf "$TMP"

# ------------------------------------------------------------------- özet --
heading "ÖZET"
# Devirden sonra ana kopya DİĞER düğümdür; bu normaldir ama kullanıcı bunu
# raporda görmeli — yedekleme/izleme hangi düğüme baktığını bilmek ister.
for eid in ${MOTORLAR[@]+"${MOTORLAR[@]}"}; do
    _p="$(primary_of "$eid")"
    if container_running "$_p"; then
        printf '  %-14s ana kopya şu an: %s\n' "$eid" "$_p"
    else
        printf '  %-14s ana kopya şu an: %s (ÇALIŞMIYOR)\n' "$eid" "$_p"
    fi
done
CALISAN=$(( GECEN + KALAN ))
if [ "${#KALAN_ADLAR[@]}" -gt 0 ]; then
    printf '\n%sBaşarısız kontroller:%s\n' "$BOLD" "$NC"
    for n in "${KALAN_ADLAR[@]}"; do printf '  · %s\n' "$n"; done
fi
if [ "${#ATLANAN_ADLAR[@]}" -gt 0 ]; then
    printf '\n%sAtlanan kontroller (ÖLÇÜLMEDİ — geçmiş sayılmaz):%s\n' "$BOLD" "$NC"
    for n in "${ATLANAN_ADLAR[@]}"; do printf '  · %s\n' "$n"; done
fi
printf '\n%sotomatik devir: %d/%d geçti%s · %d kaldı · %d atlandı\n\n' \
       "$BOLD" "$GECEN" "$CALISAN" "$NC" "$KALAN" "$ATLANAN"

if [ "$KALAN" -gt 0 ]; then
    err "Başarısız kontroller var — yukarıdaki [KALDI] satırlarına bakın."
    exit 1
fi
if [ "$CALISAN" -eq 0 ]; then
    # Hiçbir şey ölçmemiş yeşil bir koşu, alınabilecek en yanıltıcı sonuçtur.
    err "HİÇBİR KONTROL ÇALIŞMADI — bu bir BAŞARI değildir; atlama sebeplerine bakın."
    exit 2
fi
if [ "$ATLANAN" -gt 0 ]; then
    ok "Çalışan kontrollerin hepsi geçti; $ATLANAN kontrol atlandı (sebepleri yukarıda)."
else
    ok "Otomatik devir zinciri baştan sona doğrulandı."
fi
exit 0
