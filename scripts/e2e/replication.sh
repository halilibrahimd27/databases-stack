#!/bin/bash
# =============================================================================
# databases-stack — uçtan uca test: YEDEK KOPYA (master-slave / replikasyon)
# =============================================================================
# CANLI bir kuruluma karşı çalışır. Ölçtüğü şey "container ayakta" DEĞİLDİR:
#
#   1) ./stack.sh replica on <motor>  ile yedek kopyayı ürünün KENDİ yolundan kurar
#   2) ana kopyaya bir satır YAZAR, replikada AYNI satırı geri okur (gecikmeyi bekler)
#   3) replikaya yazmayı DENER — reddedilmezse bu bir arızadır
#   4) ./stack.sh replica off <motor> ile kapatır ve KALINTI arar
#   5) replikasyondan ÖNCE var olan bir hesabın replikaya taşındığını doğrular
#
# En pahalı kontrol (4)'ün içindedir: PostgreSQL'de silinmeyen bir replikasyon
# slot'u sunucuya "bu WAL'ı biri hâlâ okuyacak" der; WAL sonsuza dek birikir,
# disk dolar ve ANA KOPYA DURUR. Bu arıza gerçekten yaşandı ve iki kez yanlış
# düzeltildi: temizlik dalındaki psql çağrıları `|| true` ile maskeliydi ve dal
# `echo` ile bitiyordu — yani çıkış kodu HER ZAMAN 0'dı, koruma ölü koddu. Bu
# yüzden burada betiğin çıkış koduna değil, pg_replication_slots'ın KENDİSİNE
# bakıyoruz.
#
# ÖLÇEMEDİĞİMİZİ ÖLÇTÜK SAYMIYORUZ
# Denetim bu betikte iki sınıf hata buldu; ikisinin de kökü aynıydı: ölçüm
# ARACININ (docker exec, psql, katalog okuma) düşmesi ile ÜRÜNÜN yanlış
# davranması aynı kefeye konuyordu.
#   • sessiz yeşil : docker cevap vermeyince container_running 1 döner ve
#                    "kalıntı yok" kontrolü GEÇER — oysa hiçbir şey sorulmadı.
#   • sahte kırmızı: sorgu düşünce hata METNİ sayı sanılır, "hâlâ 3 slot var"
#                    denir; kullanıcı olmayan bir arızayı kovalar.
# Bu yüzden dört sonuç türü kullanılıyor (bkz. scripts/e2e/lib.sh):
#   GEÇTİ / KALDI / ATLANDI (ön koşul yok) / ÖLÇÜLEMEDİ (araç düştü → başarısız)
#
# Kullanım:
#   ./scripts/e2e/replication.sh                    # kataloğun tüm uygun motorları
#   ./scripts/e2e/replication.sh postgresql redis   # yalnız seçilenler
#
# Ayarlar (ortam değişkeni):
#   E2E_ON_TIMEOUT   (vars. 1500)  './stack.sh replica on' üst sınırı, sn
#   E2E_OFF_TIMEOUT  (vars. 600)   './stack.sh replica off' üst sınırı, sn
#   E2E_LAG_TIMEOUT  (vars. 120)   replikasyon gecikmesi üst sınırı, sn
#   E2E_RESTORE      (vars. 1)     koşu yarıda kesilirse kullanıcının yedek
#                                  kopyasını geri kurmayı DENE (0 = yalnız uyar)
#
# DİKKAT: test replikasyonu AÇAR ve KAPATIR. Test başlarken zaten kurulu bir
# yedek kopya varsa betik onu önce kaldırır, döngüyü çalıştırır ve sonunda GERİ
# KURAR (geri kurma da ayrı bir kontrol olarak raporlanır). Koşu Ctrl-C ile
# kesilse bile EXIT tuzağı bunu hem yüksek sesle söyler hem geri kurmayı dener —
# eskiden kesilen koşu kullanıcıyı SESSİZCE yedeksiz bırakıyordu.
#
# Çıkış kodu (scripts/e2e/lib.sh'ten — burada ayrıca hesaplanmaz):
#   0   çalışan kontrollerin hepsi geçti
#   1   en az bir kontrol KALDI ya da ÖLÇÜLEMEDİ
#   2   HİÇBİR kontrol çalışmadı (hepsi atlandı) — "sağlam" değil, "ölçmedik"
#   130 koşu kesildi (kesinti başarı değildir)
# =============================================================================
# `set -e` BİLEREK YOK: her kontrol tek tek raporlanmalı, ilk hatada ölmemeli.
set -uo pipefail

# Yığın kökü: betik normalde kökten çalıştırılır (./scripts/e2e/replication.sh)
# ama cron'dan ya da başka bir dizinden de çağrılabilsin diye kökü kendimiz
# buluyoruz — ./stack.sh ve göreli yollar buna bağlı.
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$_self_dir/../.." || { echo "yığın kökü bulunamadı" >&2; exit 2; }

# shellcheck source=../lib/common.sh
source scripts/lib/common.sh || { echo "scripts/lib/common.sh okunamadı" >&2; exit 2; }
load_env

# ORTAK KOŞUM KÜTÜPHANESİ — sayaçlar, t_ok/t_fail/t_skip/t_unknown ve ÇIKIŞ
# KODU tek bir yerde. common.sh'ten SONRA source ediliyor: renkler oradan gelsin.
E2E_SUITE="replication"
# shellcheck source=lib.sh
source scripts/e2e/lib.sh || { echo "scripts/e2e/lib.sh okunamadı" >&2; exit 2; }

E2E_ON_TIMEOUT="${E2E_ON_TIMEOUT:-1500}"
E2E_OFF_TIMEOUT="${E2E_OFF_TIMEOUT:-600}"
E2E_LAG_TIMEOUT="${E2E_LAG_TIMEOUT:-120}"
E2E_RESTORE="${E2E_RESTORE:-1}"

# Test nesnelerinin ADLARI sabit (rastgele değil): yarıda kesilmiş bir koşunun
# kalıntısını sonraki koşu tanıyıp silsin diye. İçlerine yazılan DEĞER ise her
# koşuda farklı — bayat bir satırı "replikasyon çalışıyor" sanmayalım.
PROBE="e2e_repl_probe"
PROBE_PASS="$(rand_secret 24)"
TOKEN="e2e-$(date +%s)-$$"
RKEY="e2e:repl:probe"

# Hook'ların doldurduğu ayrıntı kutuları (hata mesajında ölçülen DEĞER görünsün).
ACC_DETAIL=""; READ_SEEN=""; DENY_DETAIL=""; WRITE_DETAIL=""; SEED_DETAIL=""
SKIP_REASON=""      # MEŞRU atlama sebebi (ön koşul yok)
UNK_REASON=""       # ÖLÇEMEDİK sebebi (araç düştü) — başarısız sayılır
DOCKER_ERR=""       # docker'ın kendi hata metni
Q_OUT=""; Q_RC=0    # son sorgunun çıktısı ve ÇIKIŞ KODU (ayrı ayrı tutulur)

# =============================================================================
# ÖLÇÜM ARACI SAĞLAM MI? — sessiz yeşilin ve sahte kırmızının ortak panzehiri
# =============================================================================
# Uzun komut çıktısından hata detayı süz (boş satırları at, son N satırı al).
# Boş çıktı "sorun yok" demek değildir; o yüzden boşluğu da adıyla yazıyoruz.
detail_tail() {
    local out
    out="$(printf '%s' "${1:-}" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n "${2:-6}")"
    printf '%s' "${out:-<çıktı yok>}"
}

# Cevap gerçekten SAYI mı? Sorgu düştüğünde çıktı hata METNİdir; onu sayı sanıp
# "hâlâ 3 slot var" demek, olmayan bir arızayı kullanıcıya kovalatır.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ÖLÇÜM ARACI MI DÜŞTÜ, ÜRÜN MÜ YANLIŞ?
# docker'ın kendi hataları (125 = daemon/uzak hata, 126/127 = çalıştırılamadı)
# ve daemon/container mesajları bize ÜRÜN hakkında hiçbir şey söylemez. Bunlar
# t_fail'e değil t_unknown'a gider.
dx_broken() {   # $1 = çıkış kodu, $2 = çıktı
    local rc="${1:-0}" out="${2:-}"
    [ "$rc" -eq 0 ] && return 1
    case "$rc" in 125|126|127) return 0 ;; esac
    printf '%s' "$out" | grep -qiE 'cannot connect to the docker daemon|is the docker daemon running|error response from daemon|no such container|is not running|no such object|executable file not found|permission denied while trying to connect'
}

# container_running (common.sh) docker cevap vermediğinde de 1 döner — yani
# "kalıntı container yok" kontrolü, docker ölüyken GEÇER. Denetimin aradığı
# sessiz yeşil tam olarak budur. Burada üç durum ayrı: çalışıyor / çalışmıyor /
# SORULAMADI.
running_state() {   # $1 = container adı → 0 çalışıyor · 1 çalışmıyor · 2 sorulamadı
    local out rc
    out="$(docker ps --format '{{.Names}}' 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        DOCKER_ERR="$(detail_tail "$out" 2)"
        return 2
    fi
    DOCKER_ERR=""
    printf '%s' "${out//$'\r'/}" | grep -qx "$1" && return 0
    return 1
}

# Container'ın SAĞLIK durumu → 0 healthy · 1 unhealthy · 2 sorulamadı ·
# 3 sağlık kontrolü tanımsız (bu bir hata değil, ölçüm konusu değil demek).
#
# Neden ayrı bir kontrol: "replikasyon akıyor" ile "düğüm sağlıklı görünüyor"
# aynı şey değil. MariaDB'de hesap taşıma, hedefin DÜĞÜME ÖZEL 'healthcheck'
# hesabını kaynağınkiyle eziyordu; veritabanı kusursuz çalışırken container
# sonsuza kadar 'unhealthy' kalıyordu. Testler yalnız veriye baktığı için bunu
# görmedi — oysa otomatik devir bekçisi sağlığa bakar ve "3 kez üst üste
# sağlıksız" görünce devir başlatır. Yani ölçülmeyen bu alan, kendi kendine
# kesinti üretebilecek bir boşluktu.
health_state() {
    local out rc
    out="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}yok{{end}}' "$1" 2>&1)"; rc=$?
    [ "$rc" -ne 0 ] && { HEALTH_ERR="$(detail_tail "$out" 2)"; return 2; }
    HEALTH_SEEN="${out//$'
'/}"
    case "$HEALTH_SEEN" in
        healthy)   return 0 ;;
        yok)       return 3 ;;
        unhealthy) HEALTH_ERR="$(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$1" 2>/dev/null | tail -c 400)"; return 1 ;;
        *)         return 1 ;;   # starting: aşağıdaki bekleme döngüsü tekrar sorar
    esac
}

# ---------------------------------------------------------------- bekleme ---
# HİÇBİR BEKLEME SONSUZ DEĞİL; üstelik beklerken NE beklediğini yazar. Takılan
# bir koşuda "hangi adımda kaldı?" sorusunun cevabı log'da bulunsun.
#   $1 = üst sınır (sn), $2 = ne bekleniyor, $3… = 0 dönünce biten komut
wait_until() {
    local limit="$1" what="$2"; shift 2
    local waited=0
    while :; do
        "$@" >/dev/null 2>&1 && return 0
        [ "$waited" -ge "$limit" ] && return 1
        [ $((waited % 10)) -eq 0 ] && \
            printf '             … bekleniyor: %s (%s/%s sn)\n' "$what" "$waited" "$limit"
        sleep 2
        waited=$((waited + 2))
    done
}

# Container'ın GERÇEKTEN kaldırıldığını bekler. wait_until + container_running
# ikilisi burada kullanılamazdı: docker ölürse "kaldırıldı" cevabı gelir.
wait_gone() {   # $1 = süre, $2 = servis → 0 gitti · 1 duruyor · 2 docker sorulamadı
    local limit="$1" svc="$2" waited=0 rs
    while :; do
        running_state "$svc"; rs=$?
        [ "$rs" = "1" ] && return 0
        [ "$rs" = "2" ] && return 2
        [ "$waited" -ge "$limit" ] && return 1
        [ $((waited % 10)) -eq 0 ] && \
            printf '             … bekleniyor: %s kaldırılması (%s/%s sn)\n' "$svc" "$waited" "$limit"
        sleep 2
        waited=$((waited + 2))
    done
}

# =============================================================================
# KATALOG — servis adı, profil ve port TEK gerçek kaynaktan okunur
# =============================================================================
# Sabit yazılmış bir servis adı, katalog değişince testi sessizce yanlış yere
# baktırır: "yedek kopya ayakta" der ama baktığı container başkasıdır.
#
# ÇIKIŞ KODU ARTIK KORUNUYOR: eskiden `python3 ... | tr -d '\r'` yazıyordu ve
# boru hattında çıkış kodu tr'den geliyordu — catalog.json bozuksa cat_field
# SESSİZCE boş dönüyor, betik de "katalogda replication.mode yok" deyip motoru
# ATLIYORDU. Şimdi \r temizliği kabuk içinde, çıkış kodu python'dan.
cat_field() {   # $1 = motor, $2 = nokta ile ayrılmış yol → 0 okundu · 1 OKUNAMADI
    local out rc
    out="$(python3 - "$CATALOG" "$1" "$2" <<'PY'
import json, sys
try:
    cat = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("catalog.json okunamadi: %s: %s\n" % (type(e).__name__, e))
    sys.exit(3)
eng = next((e for e in cat.get("engines", []) if e.get("id") == sys.argv[2]), None)
if eng is None:
    sys.stderr.write("katalogda motor yok: %s\n" % sys.argv[2])
    sys.exit(4)
cur = eng
for part in sys.argv[3].split("."):
    if not isinstance(cur, dict):
        cur = None
        break
    cur = cur.get(part)
if isinstance(cur, list):
    print(" ".join(str(x) for x in cur))
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is not None:
    print(cur)
PY
)"; rc=$?
    printf '%s' "${out//$'\r'/}"
    [ "$rc" -eq 0 ] || return 1
    return 0
}

# Yedek kopyası olabilen motorlar: mode = primary-replica | replica-set
list_rep_engines() {
    local out rc
    out="$(python3 - "$CATALOG" <<'PY'
import json, sys
try:
    cat = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("catalog.json okunamadi: %s: %s\n" % (type(e).__name__, e))
    sys.exit(3)
for e in cat.get("engines", []):
    if (e.get("replication") or {}).get("mode") in ("primary-replica", "replica-set"):
        print(e["id"])
PY
)"; rc=$?
    printf '%s' "${out//$'\r'/}"
    [ "$rc" -eq 0 ] || return 1
    return 0
}

# Kapsam dışı motorlar ve sebepleri — rapor başında görünsün ki "12 motor vardı,
# neden 4'ü test edildi?" sorusu açıkta kalmasın.
list_other_engines() {
    local out rc
    out="$(python3 - "$CATALOG" <<'PY'
import json, sys
try:
    cat = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(3)
for e in cat.get("engines", []):
    m = (e.get("replication") or {}).get("mode")
    if m not in ("primary-replica", "replica-set"):
        print("%s=%s" % (e["id"], m or "yok"))
PY
)"; rc=$?
    printf '%s' "${out//$'\r'/}"
    [ "$rc" -eq 0 ] || return 1
    return 0
}

# 0 = katalogda var, 1 = yok, 2 = KATALOG OKUNAMADI.
# "Okunamadı"yı "yok" saymak kullanıcıya yanlış sebep gösterirdi: motor duruyor,
# okunamayan catalog.json'dur.
known_engine() {
    python3 - "$CATALOG" "$1" <<'PY'
import json, sys
try:
    cat = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("catalog.json okunamadi: %s: %s\n" % (type(e).__name__, e))
    sys.exit(2)
sys.exit(0 if any(e.get("id") == sys.argv[2] for e in cat.get("engines", [])) else 1)
PY
}

# Parola DEĞİŞKENİNİN ADI da katalogdan gelir (connection.password_env).
# compose'daki kural: MARIADB_PASSWORD boşsa DB_PASSWORD kullanılır.
# Katalog okunamazsa 1 döner: "parola boş" ile "katalog bozuk" ayrı sebeplerdir.
engine_password() {
    local var val="" rc
    var="$(cat_field "$1" connection.password_env)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    [ -n "$var" ] && val="${!var:-}"
    [ -n "$val" ] || val="${DB_PASSWORD:-}"
    printf '%s' "$val"
}

# state/state.json profil listesi.
#   0 = profil var · 1 = yok · 2 = dosya YOK (controller hiç yazmamış)
#   3 = dosya var ama OKUNAMADI (bozuk/izin) → ölçemedik
# Dördü ayrı tutuluyor: "okunamadı"yı "yok" saymak, kapatmadan sonra kalmış bir
# profili temiz göstermek olurdu.
state_has_profile() {
    local f="$STACK_ROOT/state/state.json"
    [ -f "$f" ] || return 2
    python3 - "$f" "$1" <<'PY'
import json, sys
try:
    st = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("state.json okunamadi: %s: %s\n" % (type(e).__name__, e))
    sys.exit(3)
sys.exit(0 if sys.argv[2] in (st.get("profiles") or []) else 1)
PY
}

# Motorun ŞU ANKİ ana kopyası. common.sh'teki primary_of, topology.json bozuksa
# sessizce motorun kendi adını döndürür — yani "devir yapılmamış" der. Devir
# durumu BİLİNMİYORKEN 'replica on' denemek yanlış olur; burada üç durum var.
CUR_PRIM=""
current_primary() {   # $1 = motor, $2 = katalog varsayılanı → 0 belirlendi · 2 okunamadı
    local topo="$STACK_ROOT/state/topology.json" out rc
    CUR_PRIM="$2"
    [ -f "$topo" ] || return 0          # devir kaydı hiç yok = devir yapılmamış
    out="$(python3 - "$topo" "$1" <<'PY'
import json, sys
try:
    t = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("topology.json okunamadi: %s: %s\n" % (type(e).__name__, e))
    sys.exit(2)
print((t.get(sys.argv[2]) or {}).get("primary") or "")
PY
)"; rc=$?
    [ "$rc" -eq 0 ] || return 2
    out="${out//$'\r'/}"
    [ -n "$out" ] && CUR_PRIM="$out"
    return 0
}

# =============================================================================
# ÜRÜNÜN KENDİ ARAYÜZÜ — replikasyon açma/kapama
# =============================================================================
# Doğrudan `docker compose up` çağırmıyoruz: kullanıcı da panelden/CLI'dan bu
# yoldan geçiyor, dolayısıyla test edilmesi gereken yol budur. Bütçe hesabı,
# override'lar, prepare/attach/cleanup fazları hep burada.
STACK_OUT=""
stack_replica() {   # $1 = on|off, $2 = motor → ./stack.sh'in çıkış kodu (124 = süre doldu)
    local act="$1" eid="$2" limit rc
    limit="$E2E_OFF_TIMEOUT"; [ "$act" = "on" ] && limit="$E2E_ON_TIMEOUT"
    log "./stack.sh replica $act $eid  (üst sınır: ${limit} sn)"
    if command -v timeout >/dev/null 2>&1; then
        STACK_OUT="$(timeout "$limit" ./stack.sh replica "$act" "$eid" 2>&1)"; rc=$?
    else
        # timeout yoksa beklemeyi sınırlayamayız; en azından bunu SÖYLÜYORUZ —
        # sessizce sonsuz beklemek, testi asılı bir işe çevirir.
        warn "'timeout' komutu yok (coreutils) — bu adım sınırsız bekleyebilir"
        STACK_OUT="$(./stack.sh replica "$act" "$eid" 2>&1)"; rc=$?
    fi
    if [ "$rc" = "124" ]; then
        STACK_OUT="${STACK_OUT}
[e2e] işlem ${limit} sn içinde bitmedi; bekleme kesildi."
    fi
    return "$rc"
}

# './stack.sh' hiç koşamadıysa (yok, çalıştırılamıyor, süre doldu) ürün hakkında
# bir şey ÖĞRENMEDİK. Bunu "kaldı" saymak sahte kırmızı olurdu.
stack_unmeasurable() {   # $1 = çıkış kodu
    case "${1:-0}" in 124|126|127) return 0 ;; esac
    return 1
}
stack_why() {   # $1 = çıkış kodu → ölçülemedi sebebi
    case "${1:-0}" in
        124) printf 'işlem üst sınır içinde bitmedi; ne bitti ne başarısız oldu — sonucu BİLMİYORUZ' ;;
        126) printf './stack.sh çalıştırılamadı (izin?) — ürünün arayüzü koşulamadı' ;;
        127) printf './stack.sh bulunamadı — ürünün arayüzü koşulamadı' ;;
        *)   printf './stack.sh koşulamadı (kod %s)' "${1:-?}" ;;
    esac
}

# =============================================================================
# MARIADB
# =============================================================================
# İstemci host'ta yok; sorgular container'ın içinden çalışır. Parola MYSQL_PWD
# ile GEÇİRİLİR, komut satırına yazılmaz — yazsaydık host'taki `ps` çıktısında
# ve container'ın /proc'unda görünürdü (ürünün kendi betikleri de böyle yapar).
#
# Çıktı DEĞİŞKENE, çıkış kodu AYRI değişkene konuyor. Eski hâlde çıktı komut
# ikamesiyle alınıyor, kod kayboluyordu: docker exec düştüğünde hata metni
# "cevap" sanılıyor ve kontrol ölçmediği şeye sonuç yazıyordu.
q_mariadb() {   # $1 = container, $2 = sql → Q_OUT / Q_RC
    Q_OUT="$(MYSQL_PWD="$E_PASS" docker exec -e MYSQL_PWD "$1" \
        mariadb -u "$E_USER" -N -B -e "$2" 2>&1)"; Q_RC=$?
    Q_OUT="${Q_OUT//$'\r'/}"
    return "$Q_RC"
}

e_mariadb_ready() { q_mariadb "$E_PRIM" "SELECT 1;"; }

e_mariadb_seed() {
    # Yarıda kesilmiş eski bir koşunun kalıntısı varsa önce o gitsin (idempotent).
    q_mariadb "$E_PRIM" "DROP DATABASE IF EXISTS $PROBE;"
    q_mariadb "$E_PRIM" "DROP USER IF EXISTS '$PROBE'@'%';"
    # Hesap replikasyondan ÖNCE açılıyor: MariaDB'de bu AYRI BİR KOD YOLUDUR.
    # Binlog ile akmaz (henüz replikasyon yok); attach fazı `mysql` şemasını
    # kopyalamadan, SHOW CREATE USER + SHOW GRANTS ile tek tek taşır. O döngü
    # bozulursa devirden sonra uygulamalar "Access denied" alır — veri yerinde
    # durduğu hâlde sistem kullanılamaz olur.
    if q_mariadb "$E_PRIM" "
        CREATE USER '$PROBE'@'%' IDENTIFIED BY '$PROBE_PASS';
        GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP ON $PROBE.* TO '$PROBE'@'%';
        FLUSH PRIVILEGES;"; then
        return 0
    fi
    # Tohum BİZİM kurgumuz, ürünün vaadi değil: kurulamadıysa 5. adımı ÖLÇEMEDİK.
    SEED_DETAIL="$(detail_tail "$Q_OUT" 3)"
    UNK_REASON="ana kopyada ($E_PRIM) test hesabı açılamadı: $SEED_DETAIL"
    return 4
}

e_mariadb_account() {
    if ! q_mariadb "$E_REP" \
         "SELECT COUNT(*) FROM mysql.global_priv WHERE User='$PROBE';"; then
        ACC_DETAIL="replikaya ($E_REP) sorulamadı: $(detail_tail "$Q_OUT" 2)"
        UNK_REASON="$ACC_DETAIL"
        return 4
    fi
    local n="${Q_OUT//[[:space:]]/}"
    ACC_DETAIL="replikada ($E_REP) mysql.global_priv sorgusu → '${n:-<cevap yok>}' (beklenen 1)"
    if ! is_num "$n"; then
        UNK_REASON="sorgu sayı döndürmedi: $ACC_DETAIL"
        return 4
    fi
    [ "$n" = "1" ]
}

e_mariadb_write() {
    if q_mariadb "$E_PRIM" "
        CREATE DATABASE IF NOT EXISTS $PROBE;
        CREATE TABLE IF NOT EXISTS $PROBE.t (id INT PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
        REPLACE INTO $PROBE.t (id, v) VALUES (1, '$TOKEN');"; then
        return 0
    fi
    WRITE_DETAIL="$(detail_tail "$Q_OUT" 3)"
    if dx_broken "$Q_RC" "$Q_OUT"; then
        UNK_REASON="ana kopyaya ($E_PRIM) sorgu GÖNDERİLEMEDİ: $WRITE_DETAIL"
        return 4
    fi
    return 1
}

# İSTEMCİ UYARILARINI AYIKLA. mariadb istemcisi parolasız/TLS'siz bağlantıda
# stderr'e "WARNING: option --ssl-verify-server-cert is disabled…" basıyor;
# çıktıyı 2>&1 ile topladığımız için bu satır ÖLÇÜLEN DEĞERE karışıyordu ve
# karşılaştırma, beklenen damga çıktının içinde DURURKEN başarısız oluyordu.
# Ürün sağlamken kırmızı yanan bir test, gerçek hatayı gizler.
istemci_temizle() {
    printf '%s' "$1" | grep -vaiE '^[[:space:]]*(warning|note|mysql: \[Warning\])' || true
}

e_mariadb_read() {
    if ! q_mariadb "$E_REP" "SELECT v FROM $PROBE.t WHERE id=1;"; then
        READ_SEEN="$(detail_tail "$Q_OUT" 2)"
        if dx_broken "$Q_RC" "$Q_OUT"; then
            UNK_REASON="replikaya ($E_REP) sorgu GÖNDERİLEMEDİ: $READ_SEEN"
            return 4
        fi
        return 1        # tablo henüz gelmemiş olabilir — gecikme sayılır, tekrar denenir
    fi
    READ_SEEN="$(istemci_temizle "$Q_OUT")"; READ_SEEN="${READ_SEEN//[[:space:]]/}"
    [ "$READ_SEEN" = "$TOKEN" ]
}

# Aynı satırı, kataloğun replica_port'undan (gateway'in stream yönlendirmesi)
# okur. Bu, kullanıcıya "okuma yükünü buraya verin" diye söylenen porttur;
# yönlendirme eskimişse container içi okuma çalışır ama bu port ölü kalır.
#
# @@read_only DOĞRUDAN sorulmuyor, IF(@@read_only,1,0) ile soruluyor: MariaDB
# sürümüne göre aynı değişken bir yerde 1/0, başka yerde ON/OFF yazdırılıyor
# ve test, ürün kusursuz çalışırken "1|damga beklenirken ON|damga geldi" diye
# kırmızı yanıyordu. Soruyu biçimden bağımsız hale getirmek, iki biçimi de
# kabul etmekten daha doğru: ortada tek bir doğru cevap kalıyor.
#
# Yalnız satırı okumak YETMEZ: yönlendirme yanlışlıkla ANA KOPYAYA çıkıyorsa
# satır orada da vardır ve kontrol boşuna geçerdi. O yüzden aynı sorguda
# düğümün salt okunur olduğunu da soruyoruz — beklenen cevap "1|<damga>".
e_mariadb_read_gw() {
    local out rc
    out="$(MYSQL_PWD="$E_PASS" docker exec -e MYSQL_PWD "$E_PRIM" \
         mariadb -h gateway -P "$E_PORT" -u "$E_USER" -N -B \
         -e "SELECT CONCAT(IF(@@read_only,1,0), '|', COALESCE((SELECT v FROM $PROBE.t WHERE id=1),'YOK'));" \
         2>&1)"; rc=$?
    out="${out//$'\r'/}"
    if dx_broken "$rc" "$out"; then
        READ_SEEN="$(detail_tail "$out" 2)"
        UNK_REASON="sorgu $E_PRIM içinden ÇALIŞTIRILAMADI (gateway'e bakılamadı): $READ_SEEN"
        return 4
    fi
    READ_SEEN="$(istemci_temizle "$out")"; READ_SEEN="${READ_SEEN//[[:space:]]/}"
    [ "$READ_SEEN" = "1|$TOKEN" ]
}

e_mariadb_denied() {
    # ⚠️ root ile denemek YANLIŞ ÖLÇÜM olurdu: MariaDB'de read_only, SUPER
    # yetkisi olan hesapları BAĞLAMAZ — root replikaya rahatça yazar ve test
    # "salt okunur değil" diye yanlış alarm verirdi. Gerçek risk zaten yetkisiz
    # hesapta: 3307'ye bağlanan bir uygulama replikaya yazabiliyor mu?
    local out rc
    out="$(MYSQL_PWD="$PROBE_PASS" docker exec -e MYSQL_PWD "$E_REP" \
           mariadb -u "$PROBE" -N -B \
           -e "INSERT INTO $PROBE.t (id,v) VALUES (99,'yazma-denemesi');" 2>&1)"; rc=$?
    out="${out//$'\r'/}"
    DENY_DETAIL="$(detail_tail "$out" 3)"
    if dx_broken "$rc" "$out"; then
        UNK_REASON="yazma denemesi $E_REP içinde ÇALIŞTIRILAMADI; salt okunurluk ölçülmedi: $DENY_DETAIL"
        return 4
    fi
    if [ "$rc" -eq 0 ]; then
        DENY_DETAIL="replikaya YAZILDI (INSERT hatasız döndü) — yedek kopya salt okunur değil"
        return 1
    fi
    if printf '%s' "$out" | grep -qiE 'read.only|1290'; then
        return 0
    fi
    # Buradan aşağısı "ölçemedik"tir: yazma reddedildi ama SEBEBİNİN salt
    # okunurluk olduğunu göremedik. Eskiden ATLANDI yazıyordu ve çıkış kodunu
    # etkilemiyordu; oysa kontrolün cevabı "bilmiyorum"du.
    if printf '%s' "$out" | grep -qiE 'access denied|1045'; then
        UNK_REASON="sonda hesabı replikada yok, yazma 'Access denied' ile döndü; salt okunurluk KANITLANAMADI: $DENY_DETAIL"
    else
        UNK_REASON="yazma reddedildi ama sebebi salt okunurluk değil; kontrol sonuçsuz: $DENY_DETAIL"
    fi
    return 4
}

e_mariadb_leftover() {
    # MariaDB'de PostgreSQL'in slot'u gibi WAL biriktiren bir yapı yok; kalan
    # replikasyon hesabı tek başına zarar vermez. Yine de kontrol ediyoruz:
    # duruyorsa kapatma adımı yarım kalmış demektir ve bir sonraki kurulumda
    # parola değişmişse replika sessizce "Access denied" alır.
    local ruser="${MARIADB_REPLICATION_USER:-repl}"
    local name="mariadb: kapatmadan sonra replikasyon hesabı '$ruser' ana kopyada kalmadı"
    if ! q_mariadb "$E_PRIM" "SELECT COUNT(*) FROM mysql.global_priv WHERE User='$ruser';"; then
        t_unknown "$name" \
            "ana kopyaya ($E_PRIM) sorulamadı: $(detail_tail "$Q_OUT" 2) — sorulamaması 'temiz' demek DEĞİLDİR"
        return 0
    fi
    local n="${Q_OUT//[[:space:]]/}"
    if ! is_num "$n"; then
        # Eski hâlde bu dal ÖLÜ KODDU: sorgu düşünce hata metni geliyor, o metin
        # ne boş ne '0' olduğu için kontrol KALDI yazıyordu (sahte kırmızı).
        t_unknown "$name" "sorgu sayı döndürmedi: '${n:-<cevap yok>}' — hesabın kalıp kalmadığı BİLİNMİYOR"
    elif [ "$n" = "0" ]; then
        t_ok "$name"
    else
        t_fail "$name" \
            "hesap duruyor (COUNT=$n). Diski doldurmaz ama cleanup fazı yarım kalmış."
    fi
}

e_mariadb_cleanup() {
    local rc=0
    q_mariadb "$E_PRIM" "DROP DATABASE IF EXISTS $PROBE;" || rc=1
    q_mariadb "$E_PRIM" "DROP USER IF EXISTS '$PROBE'@'%'; FLUSH PRIVILEGES;" || rc=1
    return "$rc"
}

# =============================================================================
# POSTGRESQL
# =============================================================================
q_postgresql() {   # $1 = container, $2 = sql → Q_OUT / Q_RC
    Q_OUT="$(PGPASSWORD="$E_PASS" docker exec -e PGPASSWORD "$1" \
        psql -U "$E_USER" -d "$E_DB" -tAX -v ON_ERROR_STOP=1 -c "$2" 2>&1)"; Q_RC=$?
    Q_OUT="${Q_OUT//$'\r'/}"
    return "$Q_RC"
}

e_postgresql_ready() { q_postgresql "$E_PRIM" "SELECT 1;"; }

e_postgresql_seed() {
    q_postgresql "$E_PRIM" "DROP TABLE IF EXISTS $PROBE;"
    q_postgresql "$E_PRIM" "DROP ROLE IF EXISTS $PROBE;"
    # Roller küme geneli nesnelerdir ve replika pg_basebackup ile FİZİKSEL kopya
    # olarak kurulur. Rolü replikasyondan önce açıp sonra replikada aramak,
    # klonun gerçekten ana kopyanın kimlik verisini taşıdığının tek kanıtıdır.
    if q_postgresql "$E_PRIM" "CREATE ROLE $PROBE LOGIN PASSWORD '$PROBE_PASS';"; then
        return 0
    fi
    SEED_DETAIL="$(detail_tail "$Q_OUT" 3)"
    UNK_REASON="ana kopyada ($E_PRIM) test rolü açılamadı: $SEED_DETAIL"
    return 4
}

e_postgresql_account() {
    if ! q_postgresql "$E_REP" "SELECT count(*) FROM pg_roles WHERE rolname='$PROBE';"; then
        ACC_DETAIL="replikaya ($E_REP) sorulamadı: $(detail_tail "$Q_OUT" 2)"
        UNK_REASON="$ACC_DETAIL"
        return 4
    fi
    local n="${Q_OUT//[[:space:]]/}"
    ACC_DETAIL="replikada ($E_REP) pg_roles sorgusu → '${n:-<cevap yok>}' (beklenen 1)"
    if ! is_num "$n"; then
        UNK_REASON="sorgu sayı döndürmedi: $ACC_DETAIL"
        return 4
    fi
    [ "$n" = "1" ]
}

e_postgresql_write() {
    if q_postgresql "$E_PRIM" "
        CREATE TABLE IF NOT EXISTS $PROBE (id int PRIMARY KEY, v text);
        INSERT INTO $PROBE (id, v) VALUES (1, '$TOKEN')
        ON CONFLICT (id) DO UPDATE SET v = EXCLUDED.v;"; then
        return 0
    fi
    WRITE_DETAIL="$(detail_tail "$Q_OUT" 3)"
    if dx_broken "$Q_RC" "$Q_OUT"; then
        UNK_REASON="ana kopyaya ($E_PRIM) sorgu GÖNDERİLEMEDİ: $WRITE_DETAIL"
        return 4
    fi
    return 1
}

e_postgresql_read() {
    if ! q_postgresql "$E_REP" "SELECT v FROM $PROBE WHERE id=1;"; then
        READ_SEEN="$(detail_tail "$Q_OUT" 2)"
        if dx_broken "$Q_RC" "$Q_OUT"; then
            UNK_REASON="replikaya ($E_REP) sorgu GÖNDERİLEMEDİ: $READ_SEEN"
            return 4
        fi
        return 1        # tablo henüz gelmemiş olabilir — gecikme sayılır
    fi
    READ_SEEN="${Q_OUT//[[:space:]]/}"
    [ "$READ_SEEN" = "$TOKEN" ]
}

# Yönlendirmenin ANA KOPYAYA çıkması hâlinde satır orada da bulunur ve kontrol
# boşuna geçerdi; bu yüzden bağlanılan düğümün kurtarma modunda (standby)
# olduğunu da aynı sorguda soruyoruz. Beklenen cevap: "true|<damga>".
e_postgresql_read_gw() {
    local out rc
    out="$(PGPASSWORD="$E_PASS" docker exec -e PGPASSWORD "$E_PRIM" \
         psql -h gateway -p "$E_PORT" -U "$E_USER" -d "$E_DB" -tAX \
         -c "SELECT pg_is_in_recovery()::text || '|' || COALESCE((SELECT v FROM $PROBE WHERE id=1),'YOK');" \
         2>&1)"; rc=$?
    out="${out//$'\r'/}"
    if dx_broken "$rc" "$out"; then
        READ_SEEN="$(detail_tail "$out" 2)"
        UNK_REASON="sorgu $E_PRIM içinden ÇALIŞTIRILAMADI (gateway'e bakılamadı): $READ_SEEN"
        return 4
    fi
    READ_SEEN="${out//[[:space:]]/}"
    [ "$READ_SEEN" = "true|$TOKEN" ]
}

e_postgresql_denied() {
    # Burada root ile denemek DOĞRU: PostgreSQL'de standby'a superuser bile
    # yazamaz, kurtarma modundaki küme tüm yazmaları reddeder.
    q_postgresql "$E_REP" "INSERT INTO $PROBE (id, v) VALUES (99, 'yazma-denemesi');"
    local rc=$?
    DENY_DETAIL="$(detail_tail "$Q_OUT" 3)"
    if dx_broken "$rc" "$Q_OUT"; then
        UNK_REASON="yazma denemesi $E_REP içinde ÇALIŞTIRILAMADI; salt okunurluk ölçülmedi: $DENY_DETAIL"
        return 4
    fi
    if [ "$rc" -eq 0 ]; then
        DENY_DETAIL="replikaya YAZILDI (INSERT hatasız döndü) — bu düğüm standby değil, İKİNCİ BİR YAZILABİLİR ANA KOPYA"
        return 1
    fi
    printf '%s' "$Q_OUT" | grep -qiE 'read-only|25006|recovery' && return 0
    UNK_REASON="yazma reddedildi ama sebebi salt okunurluk değil; kontrol sonuçsuz: $DENY_DETAIL"
    return 4
}

e_postgresql_leftover() {
    # ⚠️ BU BETİĞİN EN ÖNEMLİ KONTROLÜ.
    # Kapatmadan sonra ana kopyada kalan HER slot, PostgreSQL'e "bu WAL'ı hâlâ
    # biri okuyacak" der: WAL sonsuza dek birikir, disk dolar, ana kopya DURUR.
    # Slot adı da sabit değildir (POSTGRES_REPLICATION_SLOT / POSTGRES_SLOT_PRIMARY;
    # devirden sonra yeniden kurulan yedek BAŞKA adla açar), o yüzden ada değil
    # SAYIYA bakıyoruz: kalan slot sayısı sıfır olmalı.
    local name="postgresql: kapatmadan sonra pg_replication_slots BOŞ (WAL birikmiyor)"
    local names n
    if ! q_postgresql "$E_PRIM" "SELECT slot_name FROM pg_replication_slots;"; then
        # ÖLÇÜLEMEDİ — eskiden ATLANDI yazıyordu ve çıkış kodunu HİÇ etkilemiyordu:
        # diski doldurup ana kopyayı durduracak slot hiç sorulmamışken koşu YEŞİL
        # bitiyordu. "Sorulamadı" ile "temiz" aynı şey değildir.
        t_unknown "$name" \
            "ana kopyaya ($E_PRIM) SORULAMADI: $(detail_tail "$Q_OUT" 2)
SORULAMAMASI TEMİZ DEMEK DEĞİLDİR — bu koşu WAL birikmesi hakkında hiçbir şey söylemiyor.
Motoru açıp testi tekrar çalıştırın; elle bakmak için:
  docker exec -it $E_PRIM psql -U $E_USER -d postgres -c 'SELECT slot_name FROM pg_replication_slots;'"
    else
        names="$(printf '%s' "$Q_OUT" | grep -v '^[[:space:]]*$' | tr '\n' ' ')"
        if [ -z "${names// /}" ]; then
            t_ok "$name"
        else
            t_fail "$name" \
"ana kopyada kalan slot(lar): $names
Bu slot(lar) WAL'ı sonsuza dek biriktirir; disk dolunca ana kopya durur.
Elle silmek için:
  docker exec -it $E_PRIM psql -U $E_USER -d postgres -c \"SELECT pg_drop_replication_slot('${names%% *}');\""
        fi
    fi

    # Slot yoksa da bir walsender takılı kalmış olabilir (replika kaldırıldığı
    # hâlde bağlantı düşmemişse). Slot kadar pahalı değil ama aynı arızanın
    # habercisi: bağlantı düşmediyse slot da 'active' kalır ve silinemez.
    local name2="postgresql: kapatmadan sonra pg_stat_replication'da bağlı replika kalmadı"
    if ! q_postgresql "$E_PRIM" "SELECT count(*) FROM pg_stat_replication;"; then
        t_unknown "$name2" "ana kopyaya ($E_PRIM) sorulamadı: $(detail_tail "$Q_OUT" 2)"
        return 0
    fi
    n="${Q_OUT//[[:space:]]/}"
    if ! is_num "$n"; then
        # Eski hâlde `-z` dalı ÖLÜ KODDU: psql hatası boş değil hata METNİ döner,
        # o metin de "0" olmadığı için kontrol KALDI yazıyordu (sahte kırmızı).
        t_unknown "$name2" "sorgu sayı döndürmedi: '${n:-<cevap yok>}'"
    elif [ "$n" = "0" ]; then
        t_ok "$name2"
    else
        t_fail "$name2" "hâlâ $n bağlı replika görünüyor — yedek kopya kaldırıldıysa bu bağlantı kalıntıdır"
    fi
}

e_postgresql_cleanup() {
    local rc=0
    q_postgresql "$E_PRIM" "DROP TABLE IF EXISTS $PROBE;" || rc=1
    q_postgresql "$E_PRIM" "DROP ROLE IF EXISTS $PROBE;" || rc=1
    return "$rc"
}

# =============================================================================
# MONGODB  (replica-set)
# =============================================================================
# mongosh parolayı komut satırından alır (başka yolu yok); ürünün kendi
# replikasyon betiği de aynısını yapıyor.
q_mongo() {   # $1 = container, $2 = javascript → Q_OUT / Q_RC
    Q_OUT="$(docker exec "$1" "${MONGO_SHELL:-mongosh}" --quiet \
        -u "$E_USER" -p "$E_PASS" --authenticationDatabase admin --eval "$2" 2>&1)"; Q_RC=$?
    Q_OUT="${Q_OUT//$'\r'/}"
    return "$Q_RC"
}

e_mongodb_ready() {
    # `grep -x`: cevabın TAMAMI "1" olmalı. Gevşek arama, içinde 1 geçen bir
    # hata mesajını ("... on port 27017") da "hazır" sayardı.
    q_mongo "$E_PRIM" 'db.adminCommand({ping:1}).ok' || return 1
    printf '%s' "$Q_OUT" | grep -qx '1'
}

e_mongodb_seed() {
    if q_mongo "$E_PRIM" "
        var a = db.getSiblingDB('admin');
        try { a.dropUser('$PROBE') } catch (e) {}
        try { db.getSiblingDB('$PROBE').dropDatabase() } catch (e) {}
        a.createUser({user:'$PROBE', pwd:'$PROBE_PASS', roles:[{role:'read', db:'$PROBE'}]});
        print('TAMAM');" && printf '%s' "$Q_OUT" | grep -q 'TAMAM'; then
        return 0
    fi
    SEED_DETAIL="$(detail_tail "$Q_OUT" 3)"
    UNK_REASON="ana kopyada ($E_PRIM) test hesabı açılamadı: $SEED_DETAIL"
    return 4
}

e_mongodb_account() {
    # İkincil üyeye doğrudan bağlanan istemci, okuma tercihini açıkça
    # söylemezse "not primary" alır — bu, replikasyonun bozuk olduğu anlamına
    # GELMEZ; o yüzden setReadPref şart.
    q_mongo "$E_REP" "
        db.getMongo().setReadPref('secondaryPreferred');
        try { print('SAYI=' + db.getSiblingDB('admin').system.users.find({user:'$PROBE'}).itcount()) }
        catch (e) { print('HATA ' + e.message) }"
    local rc=$?
    ACC_DETAIL="replikada ($E_REP) admin.system.users → $(detail_tail "$Q_OUT" 2) (beklenen SAYI=1)"
    if [ "$rc" -ne 0 ] || ! printf '%s' "$Q_OUT" | grep -q 'SAYI='; then
        # Cevap hiç gelmediyse ya da JS 'HATA' dediyse ölçüm YAPILAMADI; bunu
        # "hesap taşınmadı" diye KALDI yazmak, olmayan bir arızayı bildirmek olur.
        UNK_REASON="hesap sayısı okunamadı: $ACC_DETAIL"
        return 4
    fi
    printf '%s' "$Q_OUT" | grep -q 'SAYI=1'
}

e_mongodb_write() {
    if q_mongo "$E_PRIM" "
        db.getSiblingDB('$PROBE').t.replaceOne({_id:1}, {_id:1, v:'$TOKEN'}, {upsert:true});
        print('TAMAM');" && printf '%s' "$Q_OUT" | grep -q 'TAMAM'; then
        return 0
    fi
    WRITE_DETAIL="$(detail_tail "$Q_OUT" 3)"
    if dx_broken "$Q_RC" "$Q_OUT"; then
        UNK_REASON="ana kopyaya ($E_PRIM) komut GÖNDERİLEMEDİ: $WRITE_DETAIL"
        return 4
    fi
    return 1
}

e_mongodb_read() {
    q_mongo "$E_REP" "
        db.getMongo().setReadPref('secondaryPreferred');
        var d = db.getSiblingDB('$PROBE').t.findOne({_id:1});
        print(d ? d.v : 'KAYIT-YOK');"
    local rc=$?
    READ_SEEN="$Q_OUT"
    if [ "$rc" -ne 0 ]; then
        UNK_REASON="replikaya ($E_REP) komut GÖNDERİLEMEDİ: $(detail_tail "$Q_OUT" 2)"
        return 4
    fi
    printf '%s' "$Q_OUT" | grep -Fq "$TOKEN" && return 0
    printf '%s' "$Q_OUT" | grep -q 'KAYIT-YOK' && return 1   # henüz gelmedi — beklenir
    UNK_REASON="beklenmedik cevap (ne damga ne 'KAYIT-YOK'): $(detail_tail "$Q_OUT" 2)"
    return 4
}

# Bağlanılan düğüm gerçekten İKİNCİL üye mi (S) yoksa yönlendirme ana kopyaya mı
# çıkıyor (P)? Satır iki düğümde de bulunacağı için tek başına okuma, yanlış
# yönlendirmeyi yakalayamaz. Beklenen cevap: "S|<damga>".
e_mongodb_read_gw() {
    local out rc
    out="$(docker exec "$E_PRIM" "${MONGO_SHELL:-mongosh}" --quiet \
        --host gateway --port "$E_PORT" \
        -u "$E_USER" -p "$E_PASS" --authenticationDatabase admin --eval "
        db.getMongo().setReadPref('secondaryPreferred');
        var rol = db.hello().secondary ? 'S' : 'P';
        var d = db.getSiblingDB('$PROBE').t.findOne({_id:1});
        print(rol + '|' + (d ? d.v : 'KAYIT-YOK'));" 2>&1)"; rc=$?
    out="${out//$'\r'/}"
    READ_SEEN="$out"
    if dx_broken "$rc" "$out"; then
        UNK_REASON="komut $E_PRIM içinden ÇALIŞTIRILAMADI (gateway'e bakılamadı): $(detail_tail "$out" 2)"
        return 4
    fi
    printf '%s' "$out" | grep -Fq "S|$TOKEN"
}

e_mongodb_denied() {
    q_mongo "$E_REP" "
        try { db.getSiblingDB('$PROBE').t.insertOne({_id:99, v:'yazma-denemesi'}); print('YAZDI') }
        catch (e) { print('RED ' + e.codeName + ' ' + e.message) }"
    local rc=$?
    DENY_DETAIL="$(detail_tail "$Q_OUT" 3)"
    if dx_broken "$rc" "$Q_OUT"; then
        UNK_REASON="yazma denemesi $E_REP içinde ÇALIŞTIRILAMADI; ikincil üye koruması ölçülmedi: $DENY_DETAIL"
        return 4
    fi
    if printf '%s' "$Q_OUT" | grep -q 'YAZDI'; then
        DENY_DETAIL="ikincil üyeye YAZILDI — küme iki yazılabilir düğüme bölünmüş (split-brain)"
        return 1
    fi
    printf '%s' "$Q_OUT" | grep -qiE 'not primary|notwritableprimary|10107|not master' && return 0
    UNK_REASON="yazma reddedildi ama sebebi 'ikincil üye' değil; kontrol sonuçsuz: $DENY_DETAIL"
    return 4
}

e_mongodb_leftover() {
    # 1) Ana kopya --replSet'siz hâline döndü mü? MongoDB'de replikasyon açmak
    #    primary'yi de yeniden başlatır (overrides/mongodb-replica.yml). Kapatma
    #    sonrası override kaldırılmazsa düğüm tek üyeli bir kümede kalır; üye
    #    kümeden düzgün çıkarılmadıysa çoğunluk kaybolur ve düğüm PRIMARY'likten
    #    düşer — veritabanı o an YAZMAYA KAPANIR.
    local name="mongodb: kapatmadan sonra ana kopya replica set üyesi değil (--replSet kaldırıldı)"
    local name2="mongodb: kapatmadan sonra ana kopya yeniden yazmaya açık"
    local ready=0

    if wait_until 90 "ana kopyanın --replSet'siz açılması" e_mongodb_ready; then
        ready=1
    fi

    if [ "$ready" -eq 1 ] && q_mongo "$E_PRIM" "print(db.hello().setName || 'YOK')"; then
        if printf '%s' "$Q_OUT" | grep -q '^YOK$'; then
            t_ok "$name"
        elif printf '%s' "$Q_OUT" | grep -qE '^[A-Za-z0-9_.-]+$'; then
            t_fail "$name" "ana kopya hâlâ bir replica set üyesi: $(detail_tail "$Q_OUT" 2)"
        else
            # Cevap ne set adı ne 'YOK' — ölçemedik. Eski hâlde bu çıktı
            # doğrudan KALDI sayılıyordu (sahte kırmızı).
            t_unknown "$name" "beklenmedik cevap: $(detail_tail "$Q_OUT" 2)"
        fi
    else
        t_unknown "$name" "ana kopya ($E_PRIM) 90 sn içinde sorguya cevap vermedi: $(detail_tail "$Q_OUT" 2)"
    fi

    # 2) Ve gerçekten yazılabiliyor mu? "Üye değil" demek yetmez; ölçülmesi
    #    gereken şey kullanıcının yaşadığı sonuçtur: yazabiliyor muyum?
    if [ "$ready" -eq 1 ]; then
        q_mongo "$E_PRIM" "
            db.getSiblingDB('$PROBE').t.updateOne({_id:1}, {\$set:{v:'kapatma-sonrasi'}});
            print('TAMAM');"
        local wrc=$?
        if printf '%s' "$Q_OUT" | grep -q 'TAMAM'; then
            t_ok "$name2"
        elif dx_broken "$wrc" "$Q_OUT"; then
            t_unknown "$name2" "komut $E_PRIM içinde ÇALIŞTIRILAMADI: $(detail_tail "$Q_OUT" 3)"
        else
            t_fail "$name2" "$(detail_tail "$Q_OUT" 3)"
        fi
    else
        t_unknown "$name2" "ana kopya ($E_PRIM) cevap vermediği için yazılabilirlik ÖLÇÜLMEDİ"
    fi

    # 3) Replikasyonla birlikte gelen EK servisler de gitmiş olmalı (katalogdaki
    #    replication.extra_services — MongoDB'de arbiter). Geride çalışan bir
    #    arbiter, ölmüş bir kümenin oyunu taşır ve controller'ın bellek bütçesinde
    #    görünmeyen bir tüketici olarak kalır.
    #    Bu blok eskiden 1. adım atlanınca HİÇ ÇALIŞMIYORDU (erken return) ve
    #    kataloğu okuyamadığında da sessizce boş geçiyordu — iki ayrı sessiz yeşil.
    local extras x name3 rs
    if ! extras="$(cat_field mongodb replication.extra_services)"; then
        t_unknown "mongodb: kapatmadan sonra ek servisler (arbiter) çalışmıyor" \
                  "catalog.json okunamadı — hangi ek servislerin aranacağı BİLİNMİYOR"
        return 0
    fi
    for x in $extras; do
        name3="mongodb: kapatmadan sonra ek servis '$x' çalışmıyor"
        running_state "$x"; rs=$?
        case "$rs" in
            0) t_fail "$name3" "container hâlâ ayakta — 'replica off' onu kaldırmıyor" ;;
            1) t_ok "$name3" ;;
            *) t_unknown "$name3" "docker cevap vermedi: $DOCKER_ERR — 'kaldırıldı' SANMIYORUZ" ;;
        esac
    done
}

e_mongodb_cleanup() {
    q_mongo "$E_PRIM" "
        try { db.getSiblingDB('$PROBE').dropDatabase() } catch (e) {}
        try { db.getSiblingDB('admin').dropUser('$PROBE') } catch (e) {}
        print('TAMAM');" || return 1
    printf '%s' "$Q_OUT" | grep -q 'TAMAM'
}

# =============================================================================
# REDIS
# =============================================================================
q_redis() {   # $1 = container, sonrası redis-cli argümanları → Q_OUT / Q_RC
    local c="$1"; shift
    Q_OUT="$(REDISCLI_AUTH="$E_PASS" docker exec -e REDISCLI_AUTH "$c" \
        redis-cli --no-auth-warning "$@" 2>&1)"; Q_RC=$?
    Q_OUT="${Q_OUT//$'\r'/}"
    return "$Q_RC"
}

e_redis_ready() {
    q_redis "$E_PRIM" PING || return 1
    printf '%s' "$Q_OUT" | grep -q 'PONG'
}

e_redis_seed() {
    q_redis "$E_PRIM" DEL "$RKEY" || {
        SEED_DETAIL="$(detail_tail "$Q_OUT" 2)"
        UNK_REASON="ana kopyaya ($E_PRIM) komut gönderilemedi: $SEED_DETAIL"
        return 4
    }
    return 0
}

e_redis_account() {
    # Redis'te hesaplar (ACL) VERİ KÜMESİNİN değil sunucu yapılandırmasının
    # parçasıdır: replika ilk bağlandığında RDB anlık görüntüsünü çeker ve o
    # görüntüde ACL yoktur. Yani "replikasyondan önce açılmış hesap replikaya
    # taşınır" iddiası bu motor için ürünün vaadi DEĞİL. Ölçüp FAIL vermek
    # yanlış alarm olurdu; sessizce geçmek ise daha kötü — o yüzden atlıyoruz.
    # Bu MEŞRU bir atlamadır (ön koşul yok değil, VAAT yok): kod 2.
    SKIP_REASON="Redis'te hesaplar (ACL) veri kümesinin parçası değildir; full resync RDB'si ACL taşımaz — ürün bunu vaat etmiyor"
    return 2
}

e_redis_write() {
    if q_redis "$E_PRIM" SET "$RKEY" "$TOKEN" && printf '%s' "$Q_OUT" | grep -q 'OK'; then
        return 0
    fi
    WRITE_DETAIL="$(detail_tail "$Q_OUT" 2)"
    if dx_broken "$Q_RC" "$Q_OUT"; then
        UNK_REASON="ana kopyaya ($E_PRIM) komut GÖNDERİLEMEDİ: $WRITE_DETAIL"
        return 4
    fi
    return 1
}

e_redis_read() {
    if ! q_redis "$E_REP" GET "$RKEY"; then
        READ_SEEN="$(detail_tail "$Q_OUT" 2)"
        if dx_broken "$Q_RC" "$Q_OUT"; then
            UNK_REASON="replikaya ($E_REP) komut GÖNDERİLEMEDİ: $READ_SEEN"
            return 4
        fi
        return 1
    fi
    READ_SEEN="$Q_OUT"
    [ "$READ_SEEN" = "$TOKEN" ]
}

# Önce bu portun ucundaki düğümün rolünü soruyoruz: yönlendirme ana kopyaya
# çıkıyorsa anahtar orada da bulunur ve kontrol yanlışlıkla geçerdi.
e_redis_read_gw() {
    local out rc rol val
    out="$(REDISCLI_AUTH="$E_PASS" docker exec -e REDISCLI_AUTH "$E_PRIM" \
        redis-cli --no-auth-warning -h gateway -p "$E_PORT" INFO replication 2>&1)"; rc=$?
    out="${out//$'\r'/}"
    if dx_broken "$rc" "$out"; then
        READ_SEEN="$(detail_tail "$out" 2)"
        UNK_REASON="komut $E_PRIM içinden ÇALIŞTIRILAMADI (gateway'e bakılamadı): $READ_SEEN"
        return 4
    fi
    rol="$(printf '%s' "$out" | sed -n 's/^role://p')"

    out="$(REDISCLI_AUTH="$E_PASS" docker exec -e REDISCLI_AUTH "$E_PRIM" \
        redis-cli --no-auth-warning -h gateway -p "$E_PORT" GET "$RKEY" 2>&1)"; rc=$?
    out="${out//$'\r'/}"
    if dx_broken "$rc" "$out"; then
        READ_SEEN="$(detail_tail "$out" 2)"
        UNK_REASON="komut $E_PRIM içinden ÇALIŞTIRILAMADI (gateway'e bakılamadı): $READ_SEEN"
        return 4
    fi
    val="$out"

    READ_SEEN="rol=${rol:-<yok>} deger=${val:-<yok>}"
    [ "$rol" = "slave" ] && [ "$val" = "$TOKEN" ]
}

e_redis_denied() {
    q_redis "$E_REP" SET "${RKEY}:yazma-denemesi" x
    local rc=$?
    DENY_DETAIL="$(detail_tail "$Q_OUT" 2)"
    if dx_broken "$rc" "$Q_OUT"; then
        UNK_REASON="yazma denemesi $E_REP içinde ÇALIŞTIRILAMADI; salt okunurluk ölçülmedi: $DENY_DETAIL"
        return 4
    fi
    if printf '%s' "$Q_OUT" | grep -q '^OK'; then
        DENY_DETAIL="replikaya YAZILDI (SET → OK) — replica-read-only kapalı; 6380'e bağlanan bir uygulama replikayı bozabilir"
        return 1
    fi
    printf '%s' "$Q_OUT" | grep -qi 'READONLY' && return 0
    UNK_REASON="yazma reddedildi ama sebebi salt okunurluk değil; kontrol sonuçsuz: $DENY_DETAIL"
    return 4
}

# Ana kopya replika bağlantısını bıraktı mı? (wait_until ile beklenir)
_redis_no_slaves() {
    q_redis "$E_PRIM" INFO replication || return 1
    printf '%s' "$Q_OUT" | grep -q '^role:master' && \
    printf '%s' "$Q_OUT" | grep -q '^connected_slaves:0'
}

e_redis_leftover() {
    # Redis'te WAL benzeri bir kalıntı yok; asıl soru ana kopyanın kendini hâlâ
    # bir replikaya bağlı sanıp saymadığı. connected_slaves sıfırlanmazsa
    # ana kopya replikasyon tamponunu boşuna taşır ve panelde "yedek kopya var"
    # görünen bir hayalet kalır.
    local name="redis: kapatmadan sonra ana kopya role:master ve connected_slaves:0"
    if wait_until 60 "ana kopyanın replika bağlantısını bırakması" _redis_no_slaves; then
        t_ok "$name"
        return 0
    fi
    # Neden geçmedi: ölçebildik mi, yoksa cevap mı yanlıştı?
    q_redis "$E_PRIM" INFO replication
    local rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$Q_OUT" | grep -q '^role:'; then
        t_unknown "$name" \
            "ana kopyaya ($E_PRIM) INFO replication sorulamadı: $(detail_tail "$Q_OUT" 2) — bağlı replika kalıp kalmadığı BİLİNMİYOR"
    else
        t_fail "$name" \
            "$(printf '%s' "$Q_OUT" | grep -E '^role:|^connected_slaves:|^slave0:' | tr '\n' ' ')"
    fi
}

e_redis_cleanup() {
    local rc=0
    q_redis "$E_PRIM" DEL "$RKEY" || rc=1
    q_redis "$E_PRIM" DEL "${RKEY}:yazma-denemesi" || rc=1
    return "$rc"
}

# =============================================================================
# MOTOR SÜRÜCÜSÜ — her motor için aynı 5 adımlı döngü
# =============================================================================
E_PASS=""; E_USER=""; E_DB=""; E_PRIM=""; E_REP=""; E_PORT=""
CUR_CLEANUP=""     # yarıda kesilirse çağrılacak temizlik (EXIT tuzağı kullanır)
ENGINE_CYCLED=0    # bu motorun döngüsüne GERÇEKTEN girildi mi
CYCLED=(); NOT_CYCLED=()

# Kullanıcının kurulumu: test için kaldırılmış ve GERİ KURULMASI gereken
# yedek kopyalar. run_engine'in local'lerinde tutulunca tuzak bunları GÖREMİYOR
# ve kesilen koşu kullanıcıyı sessizce yedeksiz bırakıyordu — bu yüzden GLOBAL.
G_PENDING=()       # "motor servis" — henüz geri kurma denenmedi
G_UNRESTORED=()    # "motor servis" — denendi, OLMADI (tuzak tekrar denemez, bağırır)

pending_add() { G_PENDING+=("$1 $2"); }
pending_del() {
    local keep=() x
    [ "${#G_PENDING[@]}" -eq 0 ] && return 0
    for x in "${G_PENDING[@]}"; do [ "$x" = "$1 $2" ] || keep+=("$x"); done
    G_PENDING=()
    [ "${#keep[@]}" -gt 0 ] && G_PENDING=("${keep[@]}")
    return 0
}

# Hook çağrısı.
#   0 = geçti · 1 = KALDI (ölçtük, yanlış) · 2 = MEŞRU ATLAMA (SKIP_REASON)
#   3 = bu motor için hiç yazılmamış · 4 = ÖLÇEMEDİK (UNK_REASON)
# 3 ve 4 ikisi de ÖLÇÜLEMEDİ'ye gider: yazılmamış bir ölçüm yolu da bir ölçüm
# eksiğidir, "ön koşul yok" değil.
call_hook() {
    local f="$1"; shift
    SKIP_REASON=""; UNK_REASON=""     # bayat sebep metni kendi başına bir yalandır
    if declare -F "$f" >/dev/null 2>&1; then "$f" "$@"; return $?; fi
    UNK_REASON="bu motor için ölçüm yolu betikte tanımlı değil ($f)"
    return 3
}

# Bir ölçümü gecikme payıyla tekrarlar ve SON denemenin kodunu döndürür.
# Bekleme bitince "olmadı" demek yetmez: son denemede ölçüm ARACI mı düştü (4)
# yoksa cevap YANLIŞ mıydı (1) — ikisi ayrı sonuçtur.
retry_hook() {   # $1 = hook, $2 = süre, $3 = ne bekleniyor
    local h="$1" limit="$2" what="$3" rc
    call_hook "$h"; rc=$?
    case "$rc" in 0|2|3) return "$rc" ;; esac
    wait_until "$limit" "$what" "$h"
    call_hook "$h"
    return $?
}

run_engine() {
    local eid="$1"
    local N_CYCLE="$eid: yedek kopya döngüsü"
    local name mode profile rep_profile rep_svc rep_port cat_prim fn note
    # Sayısal yerel değişkenler BAŞLANGIÇTA sıfırlanıyor: `set -u` altında hiç
    # atanmamış bir kod okunursa betik ölür ve kontroller hiç raporlanmaz.
    local was_on=0 on_ok=0 seeded=0 rs=0 sp=0 arc=0 drc=0 wrc=0 rrc=0 grc=0 src=0 prc=0 lrc=0

    if ! name="$(cat_field "$eid" name)"; then
        t_unknown "$N_CYCLE" "catalog.json okunamadı — motorun ayarları alınamadı, HİÇBİR ŞEY ölçülmedi"
        return 0
    fi
    [ -n "$name" ] || name="$eid"
    if ! mode="$(cat_field "$eid" replication.mode)"; then
        t_unknown "$N_CYCLE" "catalog.json okunamadı — replikasyon kipi bilinmiyor"
        return 0
    fi
    heading "── $name ($eid) — yedek kopya döngüsü (katalog: mode=$mode)"

    # --- ön koşullar ------------------------------------------------------
    case "$mode" in
        primary-replica|replica-set) ;;
        *)  note="$(cat_field "$eid" replication.note)" || note=""
            t_skip "$N_CYCLE" "katalogda replication.mode='${mode:-yok}' — ${note:-bu motorda yedek kopya kipi yok}"
            return 0 ;;
    esac

    if ! profile="$(cat_field "$eid" profile)" \
       || ! rep_profile="$(cat_field "$eid" replication.profile)" \
       || ! rep_svc="$(cat_field "$eid" replication.replica_service)" \
       || ! rep_port="$(cat_field "$eid" replication.replica_port)" \
       || ! cat_prim="$(cat_field "$eid" primary_service)"; then
        t_unknown "$N_CYCLE" "catalog.json okunamadı — servis/profil adları alınamadı"
        return 0
    fi
    fn="e_${eid//-/_}"

    if [ -z "$rep_svc" ] || [ -z "$rep_profile" ]; then
        t_skip "$N_CYCLE" \
               "katalogda replica_service/profile boş — ./scripts/check-catalog.sh çalıştırın"
        return 0
    fi

    running_state controller; rs=$?
    case "$rs" in
        0) ;;
        1) t_skip "$N_CYCLE" \
                  "controller çalışmıyor; './stack.sh replica' onun API'sine gider. Önce: ./install.sh"
           return 0 ;;
        *) t_unknown "$N_CYCLE" \
                     "docker sorulamadı ($DOCKER_ERR) — controller'ın durumu bile BİLİNMİYOR"
           return 0 ;;
    esac

    # Devirden sonra "Replika Kur" YANLIŞ DÜĞMEDİR ve controller bunu bilerek
    # reddeder (yedek olacak düğüm eskimiş veriyi taşır). Testin burada FAIL
    # vermesi yanlış olur: ürün doğru davranıyor, ortam uygun değil.
    if ! current_primary "$eid" "$cat_prim"; then
        t_unknown "$N_CYCLE" \
                  "state/topology.json okunamadı — devir yapılmış mı BİLİNMİYOR; bu belirsizlikte 'replica on' denemek yanlış düğümü yedek yapabilir. ./stack.sh doctor"
        return 0
    fi
    # ROLLER TAKASSA ÖNCE DÜZELT, SONRA ÖLÇ. Bir devirden sonra ürün
    # 'replica on'u bilerek reddediyor (hangi düğümün güncel veriyi taşıdığı
    # belirsizken yedek kurmak yanlış düğümü silebilir); doğru komut
    # 'failover rebuild'. Paket bunu bilmediği için, bir kez devir yaşamış
    # her kurulumda replikasyon SONSUZA KADAR ölçülemez kalıyordu: tur
    # "atlandı" diyor ve replikasyonun çalıştığını kimse bir daha
    # doğrulamıyordu. Artık ön koşulu ürünün KENDİ komutuyla kuruyoruz.
    if [ "$CUR_PRIM" != "$cat_prim" ]; then
        if [ "${E2E_KUR:-1}" != "1" ]; then
            t_skip "$N_CYCLE" \
                   "devir yapılmış (ana kopya '$CUR_PRIM') ve E2E_KUR=0 — düzeltmek için: ./stack.sh failover rebuild $eid"
            return 0
        fi
        t_info "$eid: roller takas (ana kopya $CUR_PRIM) — ön koşul 'failover rebuild' ile kuruluyor"
        if ! timeout "${E2E_REBUILD_TIMEOUT:-1800}" ./stack.sh failover rebuild "$eid" \
                > "/tmp/e2e_rebuild_$eid.log" 2>&1; then
            t_unknown "$N_CYCLE" \
                      "ön koşul kurulamadı: './stack.sh failover rebuild $eid' başarısız"
            return 0
        fi
        t_info "$eid: yedek kopya yeniden kuruldu, ölçüme devam"
        # Rebuild rolleri GERİ ÇEVİRMEZ; yalnız eskimiş düğümü ana kopyadan
        # baştan kopyalar. Topolojiyi yeniden okuyoruz ki aşağıdaki eşleme
        # varsayıma değil ölçüme dayansın.
        current_primary "$eid" "$cat_prim" || true
    fi

    # ROLLERİ TOPOLOJİDEN AL, KATALOGDAN DEĞİL.
    # Bir devirden sonra kataloğun "primary_service"i artık YEDEK,
    # "replica_service"i ise CANLI ANA KOPYADIR ve bu kalıcıdır. Paket
    # katalog adlarına baktığı için devir yaşamış bir kurulumda ölçümlerin
    # yönü tersine dönüyordu: ana kopya sanılan düğüme yazmaya çalışıp
    # "READONLY You can't write against a read only replica" alıyor,
    # kaldırılmış düğüme komut gönderip "No such container" diyor, kaldırılan
    # düğümün adını yanlış bildiği için de "kapatmadan sonra container ayakta
    # değil" diye ÜRÜNÜ suçluyordu. Ölçülen dördü de paketin kendi hatasıydı.
    #
    # Gateway zaten ROLE göre yönlendiriyor (replica_port her zaman YEDEĞE
    # çıkar), o yüzden port çevrilmiyor — yalnız container adları.
    if [ "$CUR_PRIM" = "$rep_svc" ]; then
        t_info "$eid: roller takas — ana kopya '$CUR_PRIM', yedek '$cat_prim' (ölçüm buna göre)"
        local _takas="$cat_prim"
        cat_prim="$rep_svc"
        rep_svc="$_takas"
    fi

    running_state "$cat_prim"; rs=$?
    case "$rs" in
        0) ;;
        1) t_skip "$N_CYCLE" "motor kapalı ($cat_prim çalışmıyor). Açmak için: ./stack.sh enable $eid"
           return 0 ;;
        *) t_unknown "$N_CYCLE" "docker sorulamadı ($DOCKER_ERR) — motorun açık olup olmadığı BİLİNMİYOR"
           return 0 ;;
    esac

    # "Profil yok", "state.json hiç yok" ve "state.json okunamadı" AYRI şeylerdir;
    # üçünü tek mesaja sıkıştırmak kullanıcıyı çalışan bir motoru "aç" diye
    # uğraştırırdı — üstelik okunamayan bir state ölçüm eksiğidir, ön koşul değil.
    state_has_profile "$profile"; sp=$?
    case "$sp" in
        0) ;;
        1) t_skip "$N_CYCLE" \
                  "motor controller'ın state'inde aktif değil ('$profile' profili yok); 'replica on' 'Önce motoru aktif edin' der. Açmak için: ./stack.sh enable $eid"
           return 0 ;;
        2) t_skip "$N_CYCLE" \
                  "state/state.json hiç yok — controller henüz hiçbir motoru aktif etmemiş. Önce: ./install.sh"
           return 0 ;;
        *) t_unknown "$N_CYCLE" \
                     "state/state.json OKUNAMADI — motorun aktif olup olmadığı belirlenemedi; ./stack.sh doctor"
           return 0 ;;
    esac

    # Bağlantı bilgileri de katalogdan (sabit yazılmış kullanıcı adı, katalog
    # değişince testi yanlış hesapla bağlar). compose'un okuduğu env değişkenleri
    # varsa onlar önceliklidir — kurulum onları kullanıyor.
    if ! E_PASS="$(engine_password "$eid")" || ! E_USER="$(cat_field "$eid" connection.username)"; then
        t_unknown "$N_CYCLE" "catalog.json okunamadı — bağlantı bilgileri alınamadı"
        return 0
    fi
    if [ -n "${DEFAULT_DATABASE:-}" ]; then
        E_DB="$DEFAULT_DATABASE"
    elif ! E_DB="$(cat_field "$eid" connection.database)"; then
        t_unknown "$N_CYCLE" "catalog.json okunamadı — veritabanı adı alınamadı"
        return 0
    fi
    case "$eid" in
        postgresql) E_USER="${POSTGRES_USER:-$E_USER}" ;;
        mongodb)    E_USER="${MONGO_USER:-$E_USER}" ;;
    esac
    E_PRIM="$cat_prim"; E_REP="$rep_svc"; E_PORT="$rep_port"

    if [ -z "$E_PASS" ]; then
        # Parolasız hiçbir sorgu çalışmaz: ATLAMA değil, ÖLÇÜM EKSİĞİ. Yeşil bir
        # koşu üretmemeli — .env eksikse hiçbir vaat doğrulanmamıştır.
        t_unknown "$N_CYCLE" \
                  ".env'de $(cat_field "$eid" connection.password_env) ve DB_PASSWORD boş — tek bir sorgu bile çalıştırılamaz"
        return 0
    fi
    if ! declare -F "${fn}_ready" >/dev/null 2>&1; then
        t_unknown "$N_CYCLE" "bu motor için ölçüm yolu betikte tanımlı değil (${fn}_ready)"
        return 0
    fi
    if ! wait_until 30 "$E_PRIM istemcisinin cevap vermesi" "${fn}_ready"; then
        t_unknown "$N_CYCLE" \
                  "ana kopya ($E_PRIM) 30 sn içinde sorguya cevap vermedi (parola yanlış ya da motor başlıyor olabilir) — bu koşu $eid hakkında hiçbir şey ölçmedi"
        return 0
    fi

    CUR_CLEANUP="${fn}_cleanup"

    # --- zaten kurulu bir yedek kopya varsa: önce kaldır, sonda geri kur ----
    # Döngünün ilk adımı "kurulum"; kurulu bir sistemde ölçüm yapmak, hem
    # 5. adımı (replikasyondan ÖNCE açılan hesap) imkânsız kılar hem de
    # kapatma/kalıntı kontrolünü kullanıcının kurulumuna uygular.
    running_state "$rep_svc"; rs=$?
    if [ "$rs" = "2" ]; then
        t_unknown "$N_CYCLE" "docker sorulamadı ($DOCKER_ERR) — kurulu bir yedek kopya var mı BİLİNMİYOR; kullanıcının kurulumuna dokunmuyoruz"
        CUR_CLEANUP=""
        return 0
    fi
    if [ "$rs" = "0" ]; then
        was_on=1
        pending_add "$eid" "$rep_svc"     # tuzak bunu görsün: koşu kesilse de geri kurulsun
        log "$eid: yedek kopya zaten kurulu — test için kaldırılıyor (sonunda geri kurulacak)"
        stack_replica off "$eid"; src=$?
        if [ "$src" -ne 0 ]; then
            t_unknown "$N_CYCLE" \
                      "önceden kurulu yedek kopya kaldırılamadı ($(stack_why "$src")); kullanıcının kurulumuna dokunmadan çıkılıyor: $(detail_tail "$STACK_OUT" 3)"
            CUR_CLEANUP=""
            # G_PENDING'de kalıyor: 'off' yarım kalmış olabilir, EXIT tuzağı
            # yedek kopyanın gerçekten ayakta olup olmadığına BAKIP karar verecek.
            return 0
        fi
    fi

    ENGINE_CYCLED=1

    # --- 5. adımın tohumu: replikasyondan ÖNCE var olan hesap ---------------
    local N_ACC="$eid: replikasyondan ÖNCE açılan '$PROBE' hesabı replikaya taşındı"
    local N_SEED="$eid: test hesabı ana kopyada açıldı (5. adımın ön koşulu)"
    call_hook "${fn}_seed"; arc=$?
    case "$arc" in
        0) seeded=1 ;;
        2) t_skip "$N_SEED" "$SKIP_REASON" ;;
        *) # Tohum kurulamadı: hesap taşıma kontrolü ÖLÇÜLEMEYECEK. Bunu "kaldı"
           # diye ürüne yazmak da, sessizce geçmek de yanlış olurdu.
           t_unknown "$N_SEED" "${UNK_REASON:-test hesabı açılamadı}" ;;
    esac

    # --- 1) replikasyonu kur ----------------------------------------------
    local N_ON="$eid: './stack.sh replica on' yedek kopyayı kurdu ($rep_svc ayakta)"
    stack_replica on "$eid"; src=$?
    if [ "$src" -eq 0 ]; then
        running_state "$rep_svc"; rs=$?
        case "$rs" in
            0) on_ok=1; t_ok "$N_ON" ;;
            1) t_fail "$N_ON" "stack.sh 0 döndü ama $rep_svc ayakta değil: $(detail_tail "$STACK_OUT" 12)" ;;
            *) t_unknown "$N_ON" "docker sorulamadı ($DOCKER_ERR) — $rep_svc ayakta mı BİLİNMİYOR" ;;
        esac
    elif stack_unmeasurable "$src"; then
        t_unknown "$N_ON" "$(stack_why "$src"): $(detail_tail "$STACK_OUT" 12)"
    else
        # Bütçe dolduğu için gelen ret BAŞARISIZLIK DEĞİLDİR: ürünün tam da
        # yapması gereken şeydir (replika, devirden sonra aynı yükü taşıyacağı
        # için ana kopya kadar bellek ister). Bunu kırmızı yakmak gerçek bir
        # replikasyon hatasını gürültüye boğar. Yine de SESSİZCE geçilmiyor:
        # sebep ve ölçülen sayılar atlama gerekçesine yazılıyor.
        if printf '%s' "$STACK_OUT" | grep -qiE "bellek ister|yeterli bellek yok|bütçe"; then
            t_skip "$N_ON" "sunucuda bütçe kalmadığı için ret — MEŞRU: $(detail_tail "$STACK_OUT" 4)"
        else
            t_fail "$N_ON" "$(detail_tail "$STACK_OUT" 12)"
        fi
    fi

    local N_REP="$eid: ana kopyaya yazılan satır $rep_svc üzerinde görünüyor"
    local N_GW="$eid: kataloğun replika portu ($rep_port) yedek kopyaya çıkıyor ve satır orada okunuyor"
    local N_RO="$eid: replikaya yazma denemesi REDDEDİLİYOR (salt okunur)"

    if [ "$on_ok" -eq 1 ]; then
        # --- 5) hesap taşındı mı? (yazma testinden önce: sıra önemli değil ama
        #        hesap MariaDB'de yazma-reddi testinin ön koşulu) ------------
        if [ "$seeded" -eq 1 ]; then
            retry_hook "${fn}_account" "$E2E_LAG_TIMEOUT" "hesabın replikaya ulaşması"; arc=$?
            case "$arc" in
                0) t_ok "$N_ACC" ;;
                1) t_fail "$N_ACC" "$ACC_DETAIL" ;;
                2) t_skip "$N_ACC" "$SKIP_REASON" ;;
                *) t_unknown "$N_ACC" "${UNK_REASON:-hesap sorgusu yapılamadı}" ;;
            esac
        else
            t_unknown "$N_ACC" "test hesabı ana kopyada açılamadı — hesabın taşınıp taşınmadığı ÖLÇÜLMEDİ"
        fi

        # --- 2) yaz → replikada oku → KARŞILAŞTIR -------------------------
        # "container ayakta" hiçbir şey kanıtlamaz; kanıt, yazdığımız DEĞERİN
        # replikada geri okunmasıdır. Değer her koşuda farklı, yoksa önceki
        # koşudan kalan satır "replikasyon çalışıyor" sanılırdı.
        retry_hook "${fn}_write" 60 "ana kopyanın yazmaya hazır olması"; wrc=$?
        if [ "$wrc" -eq 0 ]; then
            retry_hook "${fn}_read" "$E2E_LAG_TIMEOUT" "satırın replikaya ulaşması"; rrc=$?
            case "$rrc" in
                0) t_ok "$N_REP" ;;
                1) t_fail "$N_REP" "beklenen: '$TOKEN' · replikada okunan: '${READ_SEEN:-<cevap yok>}' (${E2E_LAG_TIMEOUT} sn beklendi)" ;;
                2) t_skip "$N_REP" "$SKIP_REASON" ;;
                *) t_unknown "$N_REP" "${UNK_REASON:-replikadan okuma yapılamadı} — satır gelmiş de olabilir, gelmemiş de" ;;
            esac

            # --- kataloğun replika portu (gateway yönlendirmesi) ----------
            running_state gateway; rs=$?
            case "$rs" in
                1) t_skip "$N_GW" "gateway çalışmıyor; replika portu ($rep_port) yalnız onun üzerinden yayınlanıyor" ;;
                2) t_unknown "$N_GW" "docker sorulamadı ($DOCKER_ERR) — gateway'in durumu bilinmiyor" ;;
                *) retry_hook "${fn}_read_gw" 30 "replika portunun ($rep_port) cevap vermesi"; grc=$?
                   case "$grc" in
                       0) t_ok "$N_GW" ;;
                       2) t_skip "$N_GW" "$SKIP_REASON" ;;
                       1) t_fail "$N_GW" \
"$rep_port üzerinden ölçülen: '${READ_SEEN:-<cevap yok>}' (yedek kopya işareti + damga '$TOKEN' bekleniyordu).
Container içi okuma geçtiyse sorun yönlendirmededir: state/routes.conf ve gateway.
Ölçüm ayrıca 'bu port ANA KOPYAYA çıkıyor mu' sorusunu da kapsar — satır iki
düğümde de bulunacağı için yalnız satırı okumak yanlış yönlendirmeyi gizlerdi." ;;
                       *) t_unknown "$N_GW" "${UNK_REASON:-replika portu sorgulanamadı} — port doğru yere çıkıyor olabilir de, çıkmıyor da" ;;
                   esac ;;
            esac
        elif [ "$wrc" -eq 1 ]; then
            t_fail "$N_REP" "ana kopyaya ($E_PRIM) YAZILAMADI: ${WRITE_DETAIL:-<ayrıntı yok>} — replikasyon gecikmesi ölçülemedi"
            t_unknown "$N_GW" "ana kopyaya yazılamadığı için okunacak satır yok; replika portu ÖLÇÜLMEDİ"
        else
            t_unknown "$N_REP" "${UNK_REASON:-ana kopyaya yazma denemesi çalıştırılamadı}"
            t_unknown "$N_GW" "yazma ölçülemediği için replika portu da ÖLÇÜLMEDİ"
        fi

        # --- 2b) İKİ DÜĞÜM DE SAĞLIKLI mı? -------------------------------
        for _n in "$E_PRIM" "$rep_svc"; do
            local N_HC="$eid: $_n replikasyon kurulduktan sonra da sağlıklı"
            local _hrc=1 _i=0
            while [ "$_i" -lt 24 ]; do          # 24 × 5 sn = 2 dk
                health_state "$_n"; _hrc=$?
                [ "$_hrc" -ne 1 ] && break
                [ "$HEALTH_SEEN" = "unhealthy" ] && sleep 5 || sleep 5
                _i=$((_i+1))
            done
            case "$_hrc" in
                0) t_ok "$N_HC" ;;
                3) t_skip "$N_HC" "$_n için sağlık kontrolü tanımlı değil" ;;
                2) t_unknown "$N_HC" "docker sorulamadı: ${HEALTH_ERR:-<ayrıntı yok>}" ;;
                *) t_fail "$N_HC" "durum: ${HEALTH_SEEN:-?} · son sağlık kontrolü çıktısı: ${HEALTH_ERR:-<yok>}
Veritabanı çalışıyor olabilir ama container 'sağlıksız' göründüğü sürece
otomatik devir bekçisi onu ölü sayar ve gereksiz devir başlatır." ;;
            esac
        done

        # --- 3) replika SALT OKUNUR mu? ----------------------------------
        call_hook "${fn}_denied"; drc=$?
        case "$drc" in
            0) t_ok "$N_RO" ;;
            1) t_fail "$N_RO" "$DENY_DETAIL" ;;
            2) t_skip "$N_RO" "$SKIP_REASON" ;;
            *) t_unknown "$N_RO" "${UNK_REASON:-yazma denemesi sonuçsuz kaldı}" ;;
        esac
    else
        # Kurulum olmadı: aşağıdaki dördü ÖLÇÜLMEDİ. Eskiden "atlandı" yazıyordu
        # ve çıkış koduna hiç yansımıyordu; oysa ürünün asıl vaatleri bunlar.
        t_unknown "$N_ACC" "yedek kopya kurulamadı — hesap taşıma ölçülmedi"
        t_unknown "$N_REP" "yedek kopya kurulamadı — replikasyon akışı ölçülmedi"
        t_unknown "$N_GW"  "yedek kopya kurulamadı — replika portu ölçülmedi"
        t_unknown "$N_RO"  "yedek kopya kurulamadı — salt okunurluk ölçülmedi"
    fi

    # --- 4) replikasyonu kapat ve KALINTI ara -----------------------------
    # Kurulum başarısız olsa bile kapatma çalışır: yarım kalmış bir kurulumun
    # ardında da slot/kullanıcı kalabilir, asıl tehlike zaten odur.
    local N_OFF="$eid: './stack.sh replica off' hatasız tamamlandı"
    local N_GONE="$eid: kapatmadan sonra $rep_svc container'ı ayakta değil"
    local N_PROF="$eid: kapatmadan sonra state.json'da '$rep_profile' profili kalmadı"
    stack_replica off "$eid"; src=$?
    if [ "$src" -eq 0 ]; then
        t_ok "$N_OFF"
    elif stack_unmeasurable "$src"; then
        t_unknown "$N_OFF" "$(stack_why "$src"): $(detail_tail "$STACK_OUT" 12)"
    else
        t_fail "$N_OFF" "$(detail_tail "$STACK_OUT" 12)"
    fi

    wait_gone 60 "$rep_svc"; rs=$?
    case "$rs" in
        0) t_ok "$N_GONE" ;;
        1) t_fail "$N_GONE" "container hâlâ çalışıyor. Ayakta kalan bir yedek kopya, otomatik devir açıksa sağlam sanılıp yükseltilebilir ve ESKİ verisini sunmaya başlar." ;;
        *) t_unknown "$N_GONE" "docker sorulamadı ($DOCKER_ERR) — container'ın kaldırılıp kaldırılmadığı BİLİNMİYOR. (docker cevap vermezken 'kaldırıldı' demek, ölçmediğini ölçtüm demektir.)" ;;
    esac

    state_has_profile "$rep_profile"; prc=$?
    case "$prc" in
        1) t_ok "$N_PROF" ;;
        0) t_fail "$N_PROF" "profil state/state.json içinde duruyor — panel yedek kopyayı kurulu gösterir, sonraki 'up' onu geri getirir" ;;
        2) t_unknown "$N_PROF" "state/state.json ORTADAN KALKTI — testin başında okunabiliyordu; profilin kalıp kalmadığı bilinmiyor" ;;
        *) t_unknown "$N_PROF" "state/state.json okunamadı — profilin kalıp kalmadığı BİLİNMİYOR" ;;
    esac

    # Motora özel kalıntı kontrolleri (PostgreSQL'de slot, MariaDB'de hesap,
    # Redis'te bağlı replika, MongoDB'de replica set üyeliği). Bu hook'lar kendi
    # sonuçlarını kendileri yazar; buraya yalnız "hiç çalışamadı" hâli düşer.
    call_hook "${fn}_leftover"; lrc=$?
    case "$lrc" in
        0|1) ;;
        2)   t_skip "$eid: motora özel kalıntı kontrolleri" "$SKIP_REASON" ;;
        *)   t_unknown "$eid: motora özel kalıntı kontrolleri" "${UNK_REASON:-kalıntı kontrolleri çalıştırılamadı}" ;;
    esac

    # --- temizlik: betiğin yarattığı her şey gider -------------------------
    # Başarısızlığı yutmuyoruz: temizlik olmadıysa kullanıcının ana kopyasında
    # bizim nesnelerimiz kalır, bunu SÖYLEMEK zorundayız (kontrol değil, uyarı).
    if ! call_hook "${fn}_cleanup"; then
        warn "$eid: test nesneleri ($PROBE) silinemedi — elle bakın: $(detail_tail "$Q_OUT" 2)"
    fi
    CUR_CLEANUP=""

    # --- test öncesi durumu geri yükle -------------------------------------
    if [ "$was_on" -eq 1 ]; then
        local N_RESTORE="$eid: test öncesinde kurulu olan yedek kopya geri kuruldu"
        log "$eid: test öncesi kurulu olan yedek kopya geri kuruluyor"
        stack_replica on "$eid"; src=$?
        running_state "$rep_svc"; rs=$?
        if [ "$src" -eq 0 ] && [ "$rs" = "0" ]; then
            t_ok "$N_RESTORE"
            pending_del "$eid" "$rep_svc"
        else
            t_fail "$N_RESTORE" \
                   "GERİ KURULAMADI — kurulum testten önce yedekliydi, şu anda DEĞİL: $(detail_tail "$STACK_OUT" 8)"
            pending_del "$eid" "$rep_svc"
            G_UNRESTORED+=("$eid $rep_svc")   # koşu sonunda tekrar, yüksek sesle
        fi
    fi
}

# =============================================================================
# ÇIKIŞ TUZAĞI — kesinti de bir sonuçtur
# =============================================================================
# lib.sh INT/TERM'i yakalar ve 130 ile çıkar (kesilen koşu ARTIK yeşil olamaz).
# Buradaki tuzak EXIT üzerinde: hem normal bitişte hem 130'da çalışır, çakışmaz.
# İki işi var:
#   1) ana kopyada bizim test nesnelerimizi bırakmamak,
#   2) TEST İÇİN KALDIRILMIŞ yedek kopyayı geri kurmak — eskiden Ctrl-C bunu
#      atlıyor ve kullanıcı sessizce YEDEKSİZ kalıyordu ("kesildi — temizleniyor"
#      yazıp çıkıyordu, replika ise kurulmuyordu).
on_exit() {
    local rc=$?
    trap - EXIT
    if [ -n "$CUR_CLEANUP" ]; then
        call_hook "$CUR_CLEANUP" >/dev/null 2>&1 \
            || warn "test nesneleri ($PROBE) silinemedi — ana kopyada kalmış olabilir"
        CUR_CLEANUP=""
    fi

    local ent eid svc rs
    for ent in ${G_PENDING[@]+"${G_PENDING[@]}"} ${G_UNRESTORED[@]+"${G_UNRESTORED[@]}"}; do
        set -- $ent; eid="$1"; svc="$2"
        running_state "$svc"; rs=$?
        [ "$rs" = "0" ] && continue          # yerinde duruyor, söylenecek bir şey yok
        printf '\n%s%s================================================================%s\n' \
               "$BOLD" "$RED" "$NC" >&2
        printf '%sUYARI: %s kurulumu TESTTEN ÖNCE YEDEKLİYDİ, ŞU ANDA DEĞİL.%s\n' \
               "$RED" "$eid" "$NC" >&2
        if [ "$rs" = "2" ]; then
            printf '  Yedek kopya (%s) durumu docker cevap vermediği için doğrulanamadı.\n' "$svc" >&2
        else
            printf '  Yedek kopya (%s) test için kaldırıldı ve geri kurulmadı.\n' "$svc" >&2
        fi
        printf '  HEMEN ÇALIŞTIRIN:  ./stack.sh replica on %s\n' "$eid" >&2
        printf '%s================================================================%s\n' "$RED" "$NC" >&2

        # Denenmemişleri bir kez denemek doğru olan: kullanıcıyı yedeksiz
        # bırakmaktansa fazladan bekletmek yeğdir. E2E_RESTORE=0 ile kapatılır.
        case " ${G_PENDING[*]-} " in
            *" $ent "*)
                if [ "$E2E_RESTORE" = "1" ] && [ "$rs" != "2" ]; then
                    warn "$eid: yedek kopya geri kurulmaya çalışılıyor (üst sınır ${E2E_ON_TIMEOUT} sn) — vazgeçmek için Ctrl-C"
                    if stack_replica on "$eid" && running_state "$svc"; then
                        ok "$eid: yedek kopya geri kuruldu"
                    else
                        err "$eid: GERİ KURULAMADI — elle: ./stack.sh replica on $eid"
                    fi
                fi ;;
        esac
    done
    exit "$rc"
}
trap on_exit EXIT

# =============================================================================
# ANA AKIŞ
# =============================================================================
# Ön koşul eksikse `die` ile sessizce çıkmıyoruz: koşu ÖZET basmadan biterse
# "hiçbir şey ölçülmedi" bilgisi kaybolur. Bunlar ÖLÇÜLEMEDİ olarak raporlanır,
# çıkış kodunu lib.sh verir.
preflight_stop() {   # $1 = ad, $2 = sebep
    t_unknown "$1" "$2"
    e2e_finish
    exit $?
}

command -v docker  >/dev/null 2>&1 || \
    preflight_stop "replication: ön koşullar" "docker bulunamadı — bu test CANLI bir kuruluma karşı çalışır, hiçbir kontrol yapılamadı"
command -v python3 >/dev/null 2>&1 || \
    preflight_stop "replication: ön koşullar" "python3 bulunamadı — katalog okunamıyor, motorların ayarları alınamadı"
[ -f "$CATALOG" ] || \
    preflight_stop "replication: ön koşullar" "catalog.json bulunamadı: $CATALOG"
[ -f "$ENV_FILE" ] || \
    preflight_stop "replication: ön koşullar" ".env bulunamadı ($ENV_FILE) — önce ./install.sh"
[ -x ./stack.sh ] || \
    preflight_stop "replication: ön koşullar" "./stack.sh çalıştırılabilir değil — ürünün kendi arayüzü koşulamaz, replikasyon açılıp kapatılamaz"
[ -n "$PROBE_PASS" ] || \
    preflight_stop "replication: ön koşullar" "rastgele parola üretilemedi (openssl/urandom) — test hesabı açılamaz, hiçbir sorgu yapılamaz"

heading "databases-stack — uçtan uca test: YEDEK KOPYA (master-slave)"
printf '  yığın kökü : %s\n' "$STACK_ROOT"
printf '  koşu damgası: %s\n' "$TOKEN"

ENGINES=()
if [ "$#" -gt 0 ]; then
    # Elle motor verildiyse, kapsam dışı olsa bile ATLAMA olarak raporlanır —
    # kullanıcı istediği motorun neden test edilmediğini görmeli.
    for a in "$@"; do
        known_engine "$a"; rc=$?
        case "$rc" in
            0) ENGINES+=("$a") ;;
            1) t_skip "$a: yedek kopya döngüsü" "katalogda böyle bir motor yok" ;;
            *) t_unknown "$a: yedek kopya döngüsü" "catalog.json okunamadı — motorun var olup olmadığı bile belirlenemedi" ;;
        esac
    done
else
    if ! engine_list="$(list_rep_engines)"; then
        preflight_stop "replication: motor listesi" \
                       "catalog.json okunamadı — hangi motorların yedek kopyası olduğu belirlenemedi"
    fi
    while IFS= read -r e; do [ -n "$e" ] && ENGINES+=("$e"); done <<< "$engine_list"
    if others="$(list_other_engines)"; then
        others="$(printf '%s' "$others" | tr '\n' ' ')"
        [ -n "$others" ] && log "kapsam dışı motorlar (katalogda primary-replica/replica-set değil): $others"
    else
        warn "kapsam dışı motorlar listelenemedi (catalog.json) — rapor eksik kalabilir"
    fi
fi

# Tek bir motor bile çalışmayacaksa `die` ile kısa yoldan çıkmıyoruz: özet ve
# atlama sebepleri basılsın, çıkış kodunu lib.sh versin ("hiçbir kontrol
# çalışmadı" = 2). Sessizce 1 dönen bir çıkış, "test koştu ve kaldı" sanılırdı.
if [ "${#ENGINES[@]}" -eq 0 ]; then
    err "test edilecek motor yok."
else
    for e in "${ENGINES[@]}"; do
        ENGINE_CYCLED=0
        run_engine "$e"
        if [ "$ENGINE_CYCLED" -eq 1 ]; then CYCLED+=("$e"); else NOT_CYCLED+=("$e"); fi
    done
fi

# Hangi motorun döngüsüne hiç GİRİLMEDİĞİNİ ayrıca yazıyoruz. "4 geçti" satırını
# hızlı okuyan biri, 4 motordan 3'ünün hiç denenmediğini fark etmiyordu.
if [ "${#NOT_CYCLED[@]}" -gt 0 ]; then
    printf '\n%sYedek kopya döngüsüne HİÇ GİRİLMEYEN motorlar:%s %s\n' \
           "$YELLOW" "$NC" "${NOT_CYCLED[*]}"
    printf '  Sebepleri yukarıda (ATLANDI / ÖLÇÜLEMEDİ). Bu koşu bu motorlar hakkında\n'
    printf '  hiçbir şey söylemiyor — "geçti" sayılan kontroller yalnız %s için.\n' \
           "${CYCLED[*]:-hiçbir motor}"
fi

e2e_finish
exit $?
