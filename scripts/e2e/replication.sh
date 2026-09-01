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
# Kullanım:
#   ./scripts/e2e/replication.sh                    # kataloğun tüm uygun motorları
#   ./scripts/e2e/replication.sh postgresql redis   # yalnız seçilenler
#
# Ayarlar (ortam değişkeni):
#   E2E_ON_TIMEOUT   (vars. 1500)  './stack.sh replica on' üst sınırı, sn
#   E2E_OFF_TIMEOUT  (vars. 600)   './stack.sh replica off' üst sınırı, sn
#   E2E_LAG_TIMEOUT  (vars. 120)   replikasyon gecikmesi üst sınırı, sn
#
# DİKKAT: test replikasyonu AÇAR ve KAPATIR. Test başlarken zaten kurulu bir
# yedek kopya varsa betik onu önce kaldırır, döngüyü çalıştırır ve sonunda GERİ
# KURAR (geri kurma da ayrı bir kontrol olarak raporlanır).
#
# Çıkış kodu:
#   0 = çalışan kontrollerin hepsi geçti
#   1 = en az bir kontrol kaldı
#   2 = HİÇBİR kontrol çalışmadı (hepsi atlandı). Ayrı kod, çünkü hiçbir şey
#       ölçmemiş yeşil bir koşu, alınabilecek en yanıltıcı sonuçtur.
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

E2E_ON_TIMEOUT="${E2E_ON_TIMEOUT:-1500}"
E2E_OFF_TIMEOUT="${E2E_OFF_TIMEOUT:-600}"
E2E_LAG_TIMEOUT="${E2E_LAG_TIMEOUT:-120}"

# Test nesnelerinin ADLARI sabit (rastgele değil): yarıda kesilmiş bir koşunun
# kalıntısını sonraki koşu tanıyıp silsin diye. İçlerine yazılan DEĞER ise her
# koşuda farklı — bayat bir satırı "replikasyon çalışıyor" sanmayalım.
PROBE="e2e_repl_probe"
PROBE_PASS="$(rand_secret 24)"
TOKEN="e2e-$(date +%s)-$$"
RKEY="e2e:repl:probe"

# Hook'ların doldurduğu ayrıntı kutuları (hata mesajında ölçülen DEĞER görünsün).
ACC_DETAIL=""; READ_SEEN=""; DENY_DETAIL=""; SKIP_REASON=""

# =============================================================================
# RAPORLAMA
# =============================================================================
T_PASS=0; T_FAIL=0; T_SKIP=0
FAILED_NAMES=(); SKIPPED_NAMES=()

t_ok() {
    T_PASS=$((T_PASS + 1))
    printf '%s  [GEÇTİ]%s   %s\n' "$GREEN" "$NC" "$1"
    return 0
}

t_fail() {
    T_FAIL=$((T_FAIL + 1))
    FAILED_NAMES+=("$1")
    printf '%s  [KALDI]%s   %s\n' "$RED" "$NC" "$1"
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | sed 's/^/             /'
    fi
    return 0
}

# ATLAMA DA BİR SONUÇTUR. Sessizce atlanan test "geçti" sanılır; bu üründe
# "replikasyon zaten kurulu değildi, o yüzden bakmadım" cümlesi, diski dolduran
# bir slot'un hiç fark edilmemesi demektir. Her atlamanın SEBEBİ basılır.
t_skip() {
    T_SKIP=$((T_SKIP + 1))
    SKIPPED_NAMES+=("$1")
    printf '%s  [ATLANDI]%s %s\n' "$YELLOW" "$NC" "$1"
    printf '             sebep: %s\n' "${2:-belirtilmedi}"
    return 0
}

# Uzun komut çıktısından hata detayı süz (boş satırları at, son N satırı al).
detail_tail() {
    printf '%s' "${1:-}" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n "${2:-6}"
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

not_running() { ! container_running "$1"; }

# =============================================================================
# KATALOG — servis adı, profil ve port TEK gerçek kaynaktan okunur
# =============================================================================
# Sabit yazılmış bir servis adı, katalog değişince testi sessizce yanlış yere
# baktırır: "yedek kopya ayakta" der ama baktığı container başkasıdır.
cat_field() {   # $1 = motor, $2 = nokta ile ayrılmış yol (ör. replication.replica_port)
    # `tr -d '\r'`: python'un çıktısı Windows'ta düzenlenmiş/çalıştırılmış bir
    # ortamda CRLF olabilir; satır sonundaki \r servis adının PARÇASI sayılır ve
    # "mariadb-replica\r" diye bir container aranır — sonuç sessizce boş döner.
    python3 - "$CATALOG" "$1" "$2" <<'PY' | tr -d '\r'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
eng = next((e for e in cat["engines"] if e["id"] == sys.argv[2]), None)
cur = eng or {}
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
}

# Yedek kopyası olabilen motorlar: mode = primary-replica | replica-set
list_rep_engines() {
    python3 - "$CATALOG" <<'PY' | tr -d '\r'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
for e in cat["engines"]:
    if (e.get("replication") or {}).get("mode") in ("primary-replica", "replica-set"):
        print(e["id"])
PY
}

# Kapsam dışı motorlar ve sebepleri — rapor başında görünsün ki "12 motor vardı,
# neden 4'ü test edildi?" sorusu açıkta kalmasın.
list_other_engines() {
    python3 - "$CATALOG" <<'PY' | tr -d '\r'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
for e in cat["engines"]:
    m = (e.get("replication") or {}).get("mode")
    if m not in ("primary-replica", "replica-set"):
        print("%s=%s" % (e["id"], m or "yok"))
PY
}

known_engine() {
    python3 - "$CATALOG" "$1" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if any(e["id"] == sys.argv[2] for e in cat["engines"]) else 1)
PY
}

# Parola DEĞİŞKENİNİN ADI da katalogdan gelir (connection.password_env).
# compose'daki kural: MARIADB_PASSWORD boşsa DB_PASSWORD kullanılır.
engine_password() {
    local var val=""
    var="$(cat_field "$1" connection.password_env)"
    [ -n "$var" ] && val="${!var:-}"
    [ -n "$val" ] || val="${DB_PASSWORD:-}"
    printf '%s' "$val"
}

# state/state.json profil listesi. 0 = var, 1 = yok, 2 = okunamadı.
# Üç durum ayrı tutulur: "okunamadı"yı "yok" saymak, kapatmadan sonra kalmış bir
# profili temiz göstermek olurdu.
state_has_profile() {
    python3 - "$STACK_ROOT/state/state.json" "$1" <<'PY'
import json, sys
try:
    st = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(2)
sys.exit(0 if sys.argv[2] in st.get("profiles", []) else 1)
PY
}

# =============================================================================
# ÜRÜNÜN KENDİ ARAYÜZÜ — replikasyon açma/kapama
# =============================================================================
# Doğrudan `docker compose up` çağırmıyoruz: kullanıcı da panelden/CLI'dan bu
# yoldan geçiyor, dolayısıyla test edilmesi gereken yol budur. Bütçe hesabı,
# override'lar, prepare/attach/cleanup fazları hep burada.
STACK_OUT=""
stack_replica() {   # $1 = on|off, $2 = motor
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

# =============================================================================
# MARIADB
# =============================================================================
# İstemci host'ta yok; sorgular container'ın içinden çalışır. Parola MYSQL_PWD
# ile GEÇİRİLİR, komut satırına yazılmaz — yazsaydık host'taki `ps` çıktısında
# ve container'ın /proc'unda görünürdü (ürünün kendi betikleri de böyle yapar).
e_mariadb_sql() {   # $1 = container, $2 = sql
    MYSQL_PWD="$E_PASS" docker exec -e MYSQL_PWD "$1" \
        mariadb -u "$E_USER" -N -B -e "$2" 2>&1
}

e_mariadb_ready() { e_mariadb_sql "$E_PRIM" "SELECT 1;" >/dev/null 2>&1; }

e_mariadb_seed() {
    # Yarıda kesilmiş eski bir koşunun kalıntısı varsa önce o gitsin (idempotent).
    e_mariadb_sql "$E_PRIM" "DROP DATABASE IF EXISTS $PROBE;" >/dev/null 2>&1
    e_mariadb_sql "$E_PRIM" "DROP USER IF EXISTS '$PROBE'@'%';" >/dev/null 2>&1
    # Hesap replikasyondan ÖNCE açılıyor: MariaDB'de bu AYRI BİR KOD YOLUDUR.
    # Binlog ile akmaz (henüz replikasyon yok); attach fazı `mysql` şemasını
    # kopyalamadan, SHOW CREATE USER + SHOW GRANTS ile tek tek taşır. O döngü
    # bozulursa devirden sonra uygulamalar "Access denied" alır — veri yerinde
    # durduğu hâlde sistem kullanılamaz olur.
    e_mariadb_sql "$E_PRIM" "
        CREATE USER '$PROBE'@'%' IDENTIFIED BY '$PROBE_PASS';
        GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP ON $PROBE.* TO '$PROBE'@'%';
        FLUSH PRIVILEGES;" >/dev/null
}

e_mariadb_account() {
    local n
    n="$(e_mariadb_sql "$E_REP" \
         "SELECT COUNT(*) FROM mysql.global_priv WHERE User='$PROBE';" | tr -d '[:space:]')"
    ACC_DETAIL="replikada ($E_REP) mysql.global_priv sorgusu → '${n:-<cevap yok>}' (beklenen 1)"
    [ "$n" = "1" ]
}

e_mariadb_write() {
    e_mariadb_sql "$E_PRIM" "
        CREATE DATABASE IF NOT EXISTS $PROBE;
        CREATE TABLE IF NOT EXISTS $PROBE.t (id INT PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
        REPLACE INTO $PROBE.t (id, v) VALUES (1, '$TOKEN');" >/dev/null
}

e_mariadb_read() {
    READ_SEEN="$(e_mariadb_sql "$E_REP" "SELECT v FROM $PROBE.t WHERE id=1;" | tr -d '[:space:]')"
    [ "$READ_SEEN" = "$TOKEN" ]
}

# Aynı satırı, kataloğun replica_port'undan (gateway'in stream yönlendirmesi)
# okur. Bu, kullanıcıya "okuma yükünü buraya verin" diye söylenen porttur;
# yönlendirme eskimişse container içi okuma çalışır ama bu port ölü kalır.
#
# Yalnız satırı okumak YETMEZ: yönlendirme yanlışlıkla ANA KOPYAYA çıkıyorsa
# satır orada da vardır ve kontrol boşuna geçerdi. O yüzden aynı sorguda
# düğümün salt okunur olduğunu da soruyoruz — beklenen cevap "1|<damga>".
e_mariadb_read_gw() {
    local v
    v="$(MYSQL_PWD="$E_PASS" docker exec -e MYSQL_PWD "$E_PRIM" \
         mariadb -h gateway -P "$E_PORT" -u "$E_USER" -N -B \
         -e "SELECT CONCAT(@@read_only, '|', COALESCE((SELECT v FROM $PROBE.t WHERE id=1),'YOK'));" \
         2>&1 | tr -d '[:space:]')"
    READ_SEEN="$v"
    [ "$v" = "1|$TOKEN" ]
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
    DENY_DETAIL="$(detail_tail "$out" 3)"
    if [ $rc -eq 0 ]; then
        DENY_DETAIL="replikaya YAZILDI (INSERT hatasız döndü) — yedek kopya salt okunur değil"
        return 1
    fi
    if printf '%s' "$out" | grep -qiE 'read.only|1290'; then
        return 0
    fi
    if printf '%s' "$out" | grep -qiE 'access denied|1045'; then
        SKIP_REASON="sonda hesabı replikada yok, yazma 'Access denied' ile döndü; salt okunurluk KANITLANAMADI: $DENY_DETAIL"
        return 2
    fi
    SKIP_REASON="yazma reddedildi ama sebebi salt okunurluk değil: $DENY_DETAIL"
    return 2
}

e_mariadb_leftover() {
    # MariaDB'de PostgreSQL'in slot'u gibi WAL biriktiren bir yapı yok; kalan
    # replikasyon hesabı tek başına zarar vermez. Yine de kontrol ediyoruz:
    # duruyorsa kapatma adımı yarım kalmış demektir ve bir sonraki kurulumda
    # parola değişmişse replika sessizce "Access denied" alır.
    local ruser n
    ruser="${MARIADB_REPLICATION_USER:-repl}"
    n="$(e_mariadb_sql "$E_PRIM" \
         "SELECT COUNT(*) FROM mysql.global_priv WHERE User='$ruser';" | tr -d '[:space:]')"
    if [ -z "$n" ]; then
        t_skip "mariadb: kapatmadan sonra replikasyon hesabı '$ruser' ana kopyada kalmadı" \
               "ana kopyaya ($E_PRIM) sorulamadı — sorulamaması 'temiz' demek değildir"
    elif [ "$n" = "0" ]; then
        t_ok "mariadb: kapatmadan sonra replikasyon hesabı '$ruser' ana kopyada kalmadı"
    else
        t_fail "mariadb: kapatmadan sonra replikasyon hesabı '$ruser' ana kopyada kalmadı" \
               "hesap duruyor (COUNT=$n). Diski doldurmaz ama cleanup fazı yarım kalmış."
    fi
}

e_mariadb_cleanup() {
    e_mariadb_sql "$E_PRIM" "DROP DATABASE IF EXISTS $PROBE;" >/dev/null 2>&1
    e_mariadb_sql "$E_PRIM" "DROP USER IF EXISTS '$PROBE'@'%'; FLUSH PRIVILEGES;" >/dev/null 2>&1
    return 0
}

# =============================================================================
# POSTGRESQL
# =============================================================================
e_postgresql_psql() {   # $1 = container, $2 = sql
    PGPASSWORD="$E_PASS" docker exec -e PGPASSWORD "$1" \
        psql -U "$E_USER" -d "$E_DB" -tAX -v ON_ERROR_STOP=1 -c "$2" 2>&1
}

e_postgresql_ready() { e_postgresql_psql "$E_PRIM" "SELECT 1;" >/dev/null 2>&1; }

e_postgresql_seed() {
    e_postgresql_psql "$E_PRIM" "DROP TABLE IF EXISTS $PROBE;" >/dev/null 2>&1
    e_postgresql_psql "$E_PRIM" "DROP ROLE IF EXISTS $PROBE;" >/dev/null 2>&1
    # Roller küme geneli nesnelerdir ve replika pg_basebackup ile FİZİKSEL kopya
    # olarak kurulur. Rolü replikasyondan önce açıp sonra replikada aramak,
    # klonun gerçekten ana kopyanın kimlik verisini taşıdığının tek kanıtıdır.
    e_postgresql_psql "$E_PRIM" "CREATE ROLE $PROBE LOGIN PASSWORD '$PROBE_PASS';" >/dev/null
}

e_postgresql_account() {
    local n
    n="$(e_postgresql_psql "$E_REP" \
         "SELECT count(*) FROM pg_roles WHERE rolname='$PROBE';" | tr -d '[:space:]')"
    ACC_DETAIL="replikada ($E_REP) pg_roles sorgusu → '${n:-<cevap yok>}' (beklenen 1)"
    [ "$n" = "1" ]
}

e_postgresql_write() {
    e_postgresql_psql "$E_PRIM" "
        CREATE TABLE IF NOT EXISTS $PROBE (id int PRIMARY KEY, v text);
        INSERT INTO $PROBE (id, v) VALUES (1, '$TOKEN')
        ON CONFLICT (id) DO UPDATE SET v = EXCLUDED.v;" >/dev/null
}

e_postgresql_read() {
    READ_SEEN="$(e_postgresql_psql "$E_REP" "SELECT v FROM $PROBE WHERE id=1;" | tr -d '[:space:]')"
    [ "$READ_SEEN" = "$TOKEN" ]
}

# Yönlendirmenin ANA KOPYAYA çıkması hâlinde satır orada da bulunur ve kontrol
# boşuna geçerdi; bu yüzden bağlanılan düğümün kurtarma modunda (standby)
# olduğunu da aynı sorguda soruyoruz. Beklenen cevap: "true|<damga>".
e_postgresql_read_gw() {
    local v
    v="$(PGPASSWORD="$E_PASS" docker exec -e PGPASSWORD "$E_PRIM" \
         psql -h gateway -p "$E_PORT" -U "$E_USER" -d "$E_DB" -tAX \
         -c "SELECT pg_is_in_recovery()::text || '|' || COALESCE((SELECT v FROM $PROBE WHERE id=1),'YOK');" \
         2>&1 | tr -d '[:space:]')"
    READ_SEEN="$v"
    [ "$v" = "true|$TOKEN" ]
}

e_postgresql_denied() {
    # Burada root ile denemek DOĞRU: PostgreSQL'de standby'a superuser bile
    # yazamaz, kurtarma modundaki küme tüm yazmaları reddeder.
    local out rc
    out="$(e_postgresql_psql "$E_REP" \
           "INSERT INTO $PROBE (id, v) VALUES (99, 'yazma-denemesi');")"; rc=$?
    DENY_DETAIL="$(detail_tail "$out" 3)"
    if [ $rc -eq 0 ]; then
        DENY_DETAIL="replikaya YAZILDI (INSERT hatasız döndü) — bu düğüm standby değil, İKİNCİ BİR YAZILABİLİR ANA KOPYA"
        return 1
    fi
    printf '%s' "$out" | grep -qiE 'read-only|25006|recovery' && return 0
    SKIP_REASON="yazma reddedildi ama sebebi salt okunurluk değil: $DENY_DETAIL"
    return 2
}

e_postgresql_leftover() {
    # ⚠️ BU BETİĞİN EN ÖNEMLİ KONTROLÜ.
    # Kapatmadan sonra ana kopyada kalan HER slot, PostgreSQL'e "bu WAL'ı hâlâ
    # biri okuyacak" der: WAL sonsuza dek birikir, disk dolar, ana kopya DURUR.
    # Slot adı da sabit değildir (POSTGRES_REPLICATION_SLOT / POSTGRES_SLOT_PRIMARY;
    # devirden sonra yeniden kurulan yedek BAŞKA adla açar), o yüzden ada değil
    # SAYIYA bakıyoruz: kalan slot sayısı sıfır olmalı.
    local name="postgresql: kapatmadan sonra pg_replication_slots BOŞ (WAL birikmiyor)"
    local out rc names n
    out="$(e_postgresql_psql "$E_PRIM" "SELECT slot_name FROM pg_replication_slots;")"; rc=$?
    if [ $rc -ne 0 ]; then
        t_skip "$name" "ana kopyaya ($E_PRIM) sorulamadı: $(detail_tail "$out" 2) — SORULAMAMASI TEMİZ DEMEK DEĞİLDİR; motoru açıp testi tekrar çalıştırın"
    else
        names="$(printf '%s' "$out" | tr -d '\r' | grep -v '^[[:space:]]*$' | tr '\n' ' ')"
        if [ -z "$names" ]; then
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
    n="$(e_postgresql_psql "$E_PRIM" "SELECT count(*) FROM pg_stat_replication;" | tr -d '[:space:]')"
    if [ -z "$n" ]; then
        t_skip "$name2" "ana kopyaya ($E_PRIM) sorulamadı"
    elif [ "$n" = "0" ]; then
        t_ok "$name2"
    else
        t_fail "$name2" "hâlâ $n bağlı replika görünüyor — yedek kopya kaldırıldıysa bu bağlantı kalıntıdır"
    fi
}

e_postgresql_cleanup() {
    e_postgresql_psql "$E_PRIM" "DROP TABLE IF EXISTS $PROBE;" >/dev/null 2>&1
    e_postgresql_psql "$E_PRIM" "DROP ROLE IF EXISTS $PROBE;" >/dev/null 2>&1
    return 0
}

# =============================================================================
# MONGODB  (replica-set)
# =============================================================================
# mongosh parolayı komut satırından alır (başka yolu yok); ürünün kendi
# replikasyon betiği de aynısını yapıyor.
e_mongodb_js() {   # $1 = container, $2 = javascript
    docker exec "$1" "${MONGO_SHELL:-mongosh}" --quiet \
        -u "$E_USER" -p "$E_PASS" --authenticationDatabase admin --eval "$2" 2>&1
}

e_mongodb_ready() {
    # `grep -x`: cevabın TAMAMI "1" olmalı. Gevşek arama, içinde 1 geçen bir
    # hata mesajını ("... on port 27017") da "hazır" sayardı.
    e_mongodb_js "$E_PRIM" 'db.adminCommand({ping:1}).ok' | tr -d '\r' | grep -qx '1'
}

e_mongodb_seed() {
    local out
    out="$(e_mongodb_js "$E_PRIM" "
        var a = db.getSiblingDB('admin');
        try { a.dropUser('$PROBE') } catch (e) {}
        try { db.getSiblingDB('$PROBE').dropDatabase() } catch (e) {}
        a.createUser({user:'$PROBE', pwd:'$PROBE_PASS', roles:[{role:'read', db:'$PROBE'}]});
        print('TAMAM');")"
    printf '%s' "$out" | grep -q 'TAMAM'
}

e_mongodb_account() {
    # İkincil üyeye doğrudan bağlanan istemci, okuma tercihini açıkça
    # söylemezse "not primary" alır — bu, replikasyonun bozuk olduğu anlamına
    # GELMEZ; o yüzden setReadPref şart.
    local out
    out="$(e_mongodb_js "$E_REP" "
        db.getMongo().setReadPref('secondaryPreferred');
        try { print('SAYI=' + db.getSiblingDB('admin').system.users.find({user:'$PROBE'}).itcount()) }
        catch (e) { print('HATA ' + e.message) }")"
    ACC_DETAIL="replikada ($E_REP) admin.system.users → $(detail_tail "$out" 2) (beklenen SAYI=1)"
    printf '%s' "$out" | grep -q 'SAYI=1'
}

e_mongodb_write() {
    e_mongodb_js "$E_PRIM" "
        db.getSiblingDB('$PROBE').t.replaceOne({_id:1}, {_id:1, v:'$TOKEN'}, {upsert:true});
        print('TAMAM');" | grep -q 'TAMAM'
}

e_mongodb_read() {
    READ_SEEN="$(e_mongodb_js "$E_REP" "
        db.getMongo().setReadPref('secondaryPreferred');
        var d = db.getSiblingDB('$PROBE').t.findOne({_id:1});
        print(d ? d.v : 'KAYIT-YOK');" | tr -d '\r')"
    printf '%s' "$READ_SEEN" | grep -Fq "$TOKEN"
}

# Bağlanılan düğüm gerçekten İKİNCİL üye mi (S) yoksa yönlendirme ana kopyaya mı
# çıkıyor (P)? Satır iki düğümde de bulunacağı için tek başına okuma, yanlış
# yönlendirmeyi yakalayamaz. Beklenen cevap: "S|<damga>".
e_mongodb_read_gw() {
    READ_SEEN="$(docker exec "$E_PRIM" "${MONGO_SHELL:-mongosh}" --quiet \
        --host gateway --port "$E_PORT" \
        -u "$E_USER" -p "$E_PASS" --authenticationDatabase admin --eval "
        db.getMongo().setReadPref('secondaryPreferred');
        var rol = db.hello().secondary ? 'S' : 'P';
        var d = db.getSiblingDB('$PROBE').t.findOne({_id:1});
        print(rol + '|' + (d ? d.v : 'KAYIT-YOK'));" 2>&1 | tr -d '\r')"
    printf '%s' "$READ_SEEN" | grep -Fq "S|$TOKEN"
}

e_mongodb_denied() {
    local out
    out="$(e_mongodb_js "$E_REP" "
        try { db.getSiblingDB('$PROBE').t.insertOne({_id:99, v:'yazma-denemesi'}); print('YAZDI') }
        catch (e) { print('RED ' + e.codeName + ' ' + e.message) }")"
    DENY_DETAIL="$(detail_tail "$out" 3)"
    if printf '%s' "$out" | grep -q 'YAZDI'; then
        DENY_DETAIL="ikincil üyeye YAZILDI — küme iki yazılabilir düğüme bölünmüş (split-brain)"
        return 1
    fi
    printf '%s' "$out" | grep -qiE 'not primary|notwritableprimary|10107|not master' && return 0
    SKIP_REASON="yazma reddedildi ama sebebi 'ikincil üye' değil: $DENY_DETAIL"
    return 2
}

e_mongodb_leftover() {
    # 1) Ana kopya --replSet'siz hâline döndü mü? MongoDB'de replikasyon açmak
    #    primary'yi de yeniden başlatır (overrides/mongodb-replica.yml). Kapatma
    #    sonrası override kaldırılmazsa düğüm tek üyeli bir kümede kalır; üye
    #    kümeden düzgün çıkarılmadıysa çoğunluk kaybolur ve düğüm PRIMARY'likten
    #    düşer — veritabanı o an YAZMAYA KAPANIR.
    local name="mongodb: kapatmadan sonra ana kopya replica set üyesi değil (--replSet kaldırıldı)"
    local out
    if wait_until 90 "ana kopyanın --replSet'siz açılması" e_mongodb_ready; then
        out="$(e_mongodb_js "$E_PRIM" "print(db.hello().setName || 'YOK')")"
        if printf '%s' "$out" | grep -q 'YOK'; then
            t_ok "$name"
        else
            t_fail "$name" "ana kopya hâlâ bir replica set üyesi: $(detail_tail "$out" 2)"
        fi
    else
        t_skip "$name" "ana kopya ($E_PRIM) 90 sn içinde cevap vermedi"
        return 0
    fi

    # 2) Ve gerçekten yazılabiliyor mu? "Üye değil" demek yetmez; ölçülmesi
    #    gereken şey kullanıcının yaşadığı sonuçtur: yazabiliyor muyum?
    local name2="mongodb: kapatmadan sonra ana kopya yeniden yazmaya açık"
    out="$(e_mongodb_js "$E_PRIM" "
        db.getSiblingDB('$PROBE').t.updateOne({_id:1}, {\$set:{v:'kapatma-sonrasi'}});
        print('TAMAM');")"
    if printf '%s' "$out" | grep -q 'TAMAM'; then
        t_ok "$name2"
    else
        t_fail "$name2" "$(detail_tail "$out" 3)"
    fi

    # 3) Replikasyonla birlikte gelen EK servisler de gitmiş olmalı (katalogdaki
    #    replication.extra_services — MongoDB'de arbiter). Geride çalışan bir
    #    arbiter, ölmüş bir kümenin oyunu taşır ve controller'ın bellek bütçesinde
    #    görünmeyen bir tüketici olarak kalır.
    local extras x name3
    extras="$(cat_field mongodb replication.extra_services)"
    if [ -n "$extras" ]; then
        for x in $extras; do
            name3="mongodb: kapatmadan sonra ek servis '$x' çalışmıyor"
            if container_running "$x"; then
                t_fail "$name3" "container hâlâ ayakta — 'replica off' onu kaldırmıyor"
            else
                t_ok "$name3"
            fi
        done
    fi
}

e_mongodb_cleanup() {
    e_mongodb_js "$E_PRIM" "
        try { db.getSiblingDB('$PROBE').dropDatabase() } catch (e) {}
        try { db.getSiblingDB('admin').dropUser('$PROBE') } catch (e) {}
        print('TAMAM');" >/dev/null 2>&1
    return 0
}

# =============================================================================
# REDIS
# =============================================================================
e_redis_cli() {   # $1 = container, sonrası redis-cli argümanları
    local c="$1"; shift
    REDISCLI_AUTH="$E_PASS" docker exec -e REDISCLI_AUTH "$c" \
        redis-cli --no-auth-warning "$@" 2>&1
}

e_redis_ready() { e_redis_cli "$E_PRIM" PING | grep -q PONG; }

e_redis_seed() {
    e_redis_cli "$E_PRIM" DEL "$RKEY" >/dev/null 2>&1
    return 0
}

e_redis_account() {
    # Redis'te hesaplar (ACL) VERİ KÜMESİNİN değil sunucu yapılandırmasının
    # parçasıdır: replika ilk bağlandığında RDB anlık görüntüsünü çeker ve o
    # görüntüde ACL yoktur. Yani "replikasyondan önce açılmış hesap replikaya
    # taşınır" iddiası bu motor için ürünün vaadi DEĞİL. Ölçüp FAIL vermek
    # yanlış alarm olurdu; sessizce geçmek ise daha kötü — o yüzden atlıyoruz.
    SKIP_REASON="Redis'te hesaplar (ACL) veri kümesinin parçası değildir; full resync RDB'si ACL taşımaz — ürün bunu vaat etmiyor"
    return 2
}

e_redis_write() { e_redis_cli "$E_PRIM" SET "$RKEY" "$TOKEN" | grep -q OK; }

e_redis_read() {
    READ_SEEN="$(e_redis_cli "$E_REP" GET "$RKEY" | tr -d '\r')"
    [ "$READ_SEEN" = "$TOKEN" ]
}

# Önce bu portun ucundaki düğümün rolünü soruyoruz: yönlendirme ana kopyaya
# çıkıyorsa anahtar orada da bulunur ve kontrol yanlışlıkla geçerdi.
e_redis_read_gw() {
    local rol val
    rol="$(REDISCLI_AUTH="$E_PASS" docker exec -e REDISCLI_AUTH "$E_PRIM" \
        redis-cli --no-auth-warning -h gateway -p "$E_PORT" INFO replication 2>&1 \
        | tr -d '\r' | sed -n 's/^role://p')"
    val="$(REDISCLI_AUTH="$E_PASS" docker exec -e REDISCLI_AUTH "$E_PRIM" \
        redis-cli --no-auth-warning -h gateway -p "$E_PORT" GET "$RKEY" 2>&1 | tr -d '\r')"
    READ_SEEN="rol=${rol:-<yok>} deger=${val:-<yok>}"
    [ "$rol" = "slave" ] && [ "$val" = "$TOKEN" ]
}

e_redis_denied() {
    local out
    out="$(e_redis_cli "$E_REP" SET "${RKEY}:yazma-denemesi" x)"
    DENY_DETAIL="$(detail_tail "$out" 2)"
    if printf '%s' "$out" | grep -q '^OK'; then
        DENY_DETAIL="replikaya YAZILDI (SET → OK) — replica-read-only kapalı; 6380'e bağlanan bir uygulama replikayı bozabilir"
        return 1
    fi
    printf '%s' "$out" | grep -qi 'READONLY' && return 0
    SKIP_REASON="yazma reddedildi ama sebebi salt okunurluk değil: $DENY_DETAIL"
    return 2
}

e_redis_leftover() {
    # Redis'te WAL benzeri bir kalıntı yok; asıl soru ana kopyanın kendini hâlâ
    # bir replikaya bağlı sanıp saymadığı. connected_slaves sıfırlanmazsa
    # ana kopya replikasyon tamponunu boşuna taşır ve panelde "yedek kopya var"
    # görünen bir hayalet kalır.
    local name="redis: kapatmadan sonra ana kopya role:master ve connected_slaves:0"
    _redis_no_slaves() {
        local info
        info="$(e_redis_cli "$E_PRIM" INFO replication | tr -d '\r')"
        printf '%s' "$info" | grep -q '^role:master' && \
        printf '%s' "$info" | grep -q '^connected_slaves:0'
    }
    if wait_until 60 "ana kopyanın replika bağlantısını bırakması" _redis_no_slaves; then
        t_ok "$name"
    else
        t_fail "$name" "$(e_redis_cli "$E_PRIM" INFO replication | tr -d '\r' | grep -E '^role:|^connected_slaves:|^slave0:' | tr '\n' ' ')"
    fi
}

e_redis_cleanup() {
    e_redis_cli "$E_PRIM" DEL "$RKEY" >/dev/null 2>&1
    e_redis_cli "$E_PRIM" DEL "${RKEY}:yazma-denemesi" >/dev/null 2>&1
    return 0
}

# =============================================================================
# MOTOR SÜRÜCÜSÜ — her motor için aynı 5 adımlı döngü
# =============================================================================
E_PASS=""; E_USER=""; E_DB=""; E_PRIM=""; E_REP=""; E_PORT=""
CUR_CLEANUP=""     # Ctrl-C hâlinde çağrılacak temizlik (yarım kalmış koşu için)

# Hook çağrısı. 0 = geçti, 1 = kaldı, 2 = ölçülemedi (SKIP_REASON dolu),
# 3 = bu motor için hiç yazılmamış (yine ATLANIR, sessizce geçilmez).
call_hook() {
    local f="$1"; shift
    if declare -F "$f" >/dev/null 2>&1; then "$f" "$@"; return $?; fi
    SKIP_REASON="bu motor için ölçüm yolu betikte tanımlı değil ($f)"
    return 3
}

run_engine() {
    local eid="$1"
    local name mode profile rep_profile rep_svc rep_port cat_prim prim fn
    local was_on=0 on_ok=0 arc drc sp

    name="$(cat_field "$eid" name)"; [ -n "$name" ] || name="$eid"
    mode="$(cat_field "$eid" replication.mode)"
    heading "── $name ($eid) — yedek kopya döngüsü (katalog: mode=$mode)"

    # --- ön koşullar ------------------------------------------------------
    case "$mode" in
        primary-replica|replica-set) ;;
        *)  t_skip "$eid: yedek kopya döngüsü" \
                   "katalogda replication.mode='${mode:-yok}' — $(cat_field "$eid" replication.note)"
            return 0 ;;
    esac

    profile="$(cat_field "$eid" profile)"
    rep_profile="$(cat_field "$eid" replication.profile)"
    rep_svc="$(cat_field "$eid" replication.replica_service)"
    rep_port="$(cat_field "$eid" replication.replica_port)"
    cat_prim="$(cat_field "$eid" primary_service)"
    fn="e_${eid//-/_}"

    if [ -z "$rep_svc" ] || [ -z "$rep_profile" ]; then
        t_skip "$eid: yedek kopya döngüsü" \
               "katalogda replica_service/profile boş — ./scripts/check-catalog.sh çalıştırın"
        return 0
    fi

    if ! container_running controller; then
        t_skip "$eid: yedek kopya döngüsü" \
               "controller çalışmıyor; './stack.sh replica' onun API'sine gider. Önce: ./install.sh"
        return 0
    fi

    # Devirden sonra "Replika Kur" YANLIŞ DÜĞMEDİR ve controller bunu bilerek
    # reddeder (yedek olacak düğüm eskimiş veriyi taşır). Testin burada FAIL
    # vermesi yanlış olur: ürün doğru davranıyor, ortam uygun değil.
    prim="$(primary_of "$eid")"
    if [ "$prim" != "$cat_prim" ]; then
        t_skip "$eid: yedek kopya döngüsü" \
               "devir yapılmış — güncel ana kopya '$prim'. Bu durumda 'replica on' bilerek reddedilir; önce ./stack.sh failover rebuild $eid"
        return 0
    fi

    if ! container_running "$cat_prim"; then
        t_skip "$eid: yedek kopya döngüsü" \
               "motor kapalı ($cat_prim çalışmıyor). Açmak için: ./stack.sh enable $eid"
        return 0
    fi
    # "Profil yok" ile "state.json okunamadı" AYRI şeylerdir; ikisini tek mesaja
    # sıkıştırmak, kullanıcıyı çalışan bir motoru "aç" diye uğraştırırdı.
    state_has_profile "$profile"; sp=$?
    if [ "$sp" = "1" ]; then
        t_skip "$eid: yedek kopya döngüsü" \
               "motor controller'ın state'inde aktif değil ('$profile' profili yok); 'replica on' 'Önce motoru aktif edin' der. Açmak için: ./stack.sh enable $eid"
        return 0
    elif [ "$sp" != "0" ]; then
        t_skip "$eid: yedek kopya döngüsü" \
               "state/state.json okunamadı — motorun aktif olup olmadığı belirlenemedi; ./stack.sh doctor"
        return 0
    fi

    # Bağlantı bilgileri de katalogdan (sabit yazılmış kullanıcı adı, katalog
    # değişince testi yanlış hesapla bağlar). compose'un okuduğu env değişkenleri
    # varsa onlar önceliklidir — kurulum onları kullanıyor.
    E_PASS="$(engine_password "$eid")"
    E_USER="$(cat_field "$eid" connection.username)"
    E_DB="${DEFAULT_DATABASE:-$(cat_field "$eid" connection.database)}"
    case "$eid" in
        postgresql) E_USER="${POSTGRES_USER:-$E_USER}" ;;
        mongodb)    E_USER="${MONGO_USER:-$E_USER}" ;;
    esac
    E_PRIM="$cat_prim"; E_REP="$rep_svc"; E_PORT="$rep_port"

    if [ -z "$E_PASS" ]; then
        t_skip "$eid: yedek kopya döngüsü" \
               ".env'de $(cat_field "$eid" connection.password_env) ve DB_PASSWORD boş — sorgu çalıştırılamaz"
        return 0
    fi
    if ! wait_until 30 "$E_PRIM istemcisinin cevap vermesi" "${fn}_ready"; then
        t_skip "$eid: yedek kopya döngüsü" \
               "ana kopya ($E_PRIM) 30 sn içinde sorguya cevap vermedi (parola yanlış ya da motor başlıyor olabilir)"
        return 0
    fi

    CUR_CLEANUP="${fn}_cleanup"

    # --- zaten kurulu bir yedek kopya varsa: önce kaldır, sonda geri kur ----
    # Döngünün ilk adımı "kurulum"; kurulu bir sistemde ölçüm yapmak, hem
    # 5. adımı (replikasyondan ÖNCE açılan hesap) imkânsız kılar hem de
    # kapatma/kalıntı kontrolünü kullanıcının kurulumuna uygular.
    if container_running "$rep_svc"; then
        was_on=1
        log "$eid: yedek kopya zaten kurulu — test için kaldırılıyor (sonunda geri kurulacak)"
        if ! stack_replica off "$eid"; then
            t_skip "$eid: yedek kopya döngüsü" \
                   "önceden kurulu yedek kopya kaldırılamadı, kullanıcının kurulumuna dokunmadan çıkılıyor: $(detail_tail "$STACK_OUT" 3)"
            return 0
        fi
    fi

    # --- 5. adımın tohumu: replikasyondan ÖNCE var olan hesap ---------------
    local N_ACC="$eid: replikasyondan ÖNCE açılan '$PROBE' hesabı replikaya taşındı"
    local seeded=0
    if call_hook "${fn}_seed"; then
        seeded=1
    else
        t_fail "$eid: test hesabı ana kopyada açıldı (5. adımın ön koşulu)" \
               "hesap açılamadı; hesap taşıma kontrolü ölçülemeyecek"
    fi

    # --- 1) replikasyonu kur ----------------------------------------------
    local N_ON="$eid: './stack.sh replica on' yedek kopyayı kurdu ($rep_svc ayakta)"
    if stack_replica on "$eid" && container_running "$rep_svc"; then
        on_ok=1
        t_ok "$N_ON"
    else
        t_fail "$N_ON" "$(detail_tail "$STACK_OUT" 12)"
    fi

    local N_REP="$eid: ana kopyaya yazılan satır $rep_svc üzerinde görünüyor"
    local N_GW="$eid: kataloğun replika portu ($rep_port) yedek kopyaya çıkıyor ve satır orada okunuyor"
    local N_RO="$eid: replikaya yazma denemesi REDDEDİLİYOR (salt okunur)"

    if [ "$on_ok" -eq 1 ]; then
        # --- 5) hesap taşındı mı? (yazma testinden önce: sıra önemli değil ama
        #        hesap MariaDB'de yazma-reddi testinin ön koşulu) ------------
        if [ "$seeded" -eq 1 ]; then
            call_hook "${fn}_account"; arc=$?
            case "$arc" in
                0) t_ok "$N_ACC" ;;
                2|3) t_skip "$N_ACC" "$SKIP_REASON" ;;
                *) if wait_until "$E2E_LAG_TIMEOUT" "hesabın replikaya ulaşması" "${fn}_account"; then
                       t_ok "$N_ACC"
                   else
                       t_fail "$N_ACC" "$ACC_DETAIL"
                   fi ;;
            esac
        else
            t_skip "$N_ACC" "test hesabı ana kopyada açılamadı"
        fi

        # --- 2) yaz → replikada oku → KARŞILAŞTIR -------------------------
        # "container ayakta" hiçbir şey kanıtlamaz; kanıt, yazdığımız DEĞERİN
        # replikada geri okunmasıdır. Değer her koşuda farklı, yoksa önceki
        # koşudan kalan satır "replikasyon çalışıyor" sanılırdı.
        if wait_until 60 "ana kopyanın yazmaya hazır olması" "${fn}_write"; then
            if wait_until "$E2E_LAG_TIMEOUT" "satırın replikaya ulaşması" "${fn}_read"; then
                t_ok "$N_REP"
            else
                t_fail "$N_REP" "beklenen: '$TOKEN' · replikada okunan: '${READ_SEEN:-<cevap yok>}' (${E2E_LAG_TIMEOUT} sn beklendi)"
            fi

            # --- kataloğun replika portu (gateway yönlendirmesi) ----------
            if ! container_running gateway; then
                t_skip "$N_GW" "gateway çalışmıyor; replika portu ($rep_port) yalnız onun üzerinden yayınlanıyor"
            elif wait_until 30 "replika portunun ($rep_port) cevap vermesi" "${fn}_read_gw"; then
                t_ok "$N_GW"
            else
                t_fail "$N_GW" \
"$rep_port üzerinden ölçülen: '${READ_SEEN:-<cevap yok>}' (yedek kopya işareti + damga '$TOKEN' bekleniyordu).
Container içi okuma geçtiyse sorun yönlendirmededir: state/routes.conf ve gateway.
Ölçüm ayrıca 'bu port ANA KOPYAYA çıkıyor mu' sorusunu da kapsar — satır iki
düğümde de bulunacağı için yalnız satırı okumak yanlış yönlendirmeyi gizlerdi."
            fi
        else
            t_fail "$N_REP" "ana kopyaya ($E_PRIM) yazılamadı; replikasyon gecikmesi ölçülemedi"
            t_skip "$N_GW" "ana kopyaya yazılamadığı için okunacak satır yok"
        fi

        # --- 3) replika SALT OKUNUR mu? ----------------------------------
        call_hook "${fn}_denied"; drc=$?
        case "$drc" in
            0) t_ok "$N_RO" ;;
            1) t_fail "$N_RO" "$DENY_DETAIL" ;;
            *) t_skip "$N_RO" "$SKIP_REASON" ;;
        esac
    else
        t_skip "$N_ACC" "yedek kopya kurulamadı"
        t_skip "$N_REP" "yedek kopya kurulamadı"
        t_skip "$N_GW"  "yedek kopya kurulamadı"
        t_skip "$N_RO"  "yedek kopya kurulamadı"
    fi

    # --- 4) replikasyonu kapat ve KALINTI ara -----------------------------
    # Kurulum başarısız olsa bile kapatma çalışır: yarım kalmış bir kurulumun
    # ardında da slot/kullanıcı kalabilir, asıl tehlike zaten odur.
    local N_OFF="$eid: './stack.sh replica off' hatasız tamamlandı"
    local N_GONE="$eid: kapatmadan sonra $rep_svc container'ı ayakta değil"
    local N_PROF="$eid: kapatmadan sonra state.json'da '$rep_profile' profili kalmadı"
    local off_ok=0
    if stack_replica off "$eid"; then
        off_ok=1
        t_ok "$N_OFF"
    else
        t_fail "$N_OFF" "$(detail_tail "$STACK_OUT" 12)"
    fi

    if wait_until 60 "$rep_svc container'ının kaldırılması" not_running "$rep_svc"; then
        t_ok "$N_GONE"
    else
        t_fail "$N_GONE" "container hâlâ çalışıyor. Ayakta kalan bir yedek kopya, otomatik devir açıksa sağlam sanılıp yükseltilebilir ve ESKİ verisini sunmaya başlar."
    fi

    state_has_profile "$rep_profile"; local prc=$?
    case "$prc" in
        1) t_ok "$N_PROF" ;;
        0) t_fail "$N_PROF" "profil state/state.json içinde duruyor — panel yedek kopyayı kurulu gösterir, sonraki 'up' onu geri getirir" ;;
        *) t_skip "$N_PROF" "state/state.json okunamadı" ;;
    esac

    # Motora özel kalıntı kontrolleri (PostgreSQL'de slot, MariaDB'de hesap,
    # Redis'te bağlı replika, MongoDB'de replica set üyeliği).
    call_hook "${fn}_leftover"
    case "$?" in
        2|3) t_skip "$eid: motora özel kalıntı kontrolleri" "$SKIP_REASON" ;;
    esac

    # --- temizlik: betiğin yarattığı her şey gider -------------------------
    call_hook "${fn}_cleanup" >/dev/null 2>&1
    CUR_CLEANUP=""

    # --- test öncesi durumu geri yükle -------------------------------------
    if [ "$was_on" -eq 1 ]; then
        local N_RESTORE="$eid: test öncesinde kurulu olan yedek kopya geri kuruldu"
        log "$eid: test öncesi kurulu olan yedek kopya geri kuruluyor"
        if stack_replica on "$eid" && container_running "$rep_svc"; then
            t_ok "$N_RESTORE"
        else
            t_fail "$N_RESTORE" "GERİ KURULAMADI — kurulum testten önce yedekliydi, şu anda DEĞİL: $(detail_tail "$STACK_OUT" 8)"
        fi
    fi
}

# =============================================================================
# ÖZET / ÇIKIŞ
# =============================================================================
finish() {
    local ran=$((T_PASS + T_FAIL)) n
    printf '\n'
    if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
        printf '%sKalan kontroller:%s\n' "$BOLD" "$NC"
        for n in "${FAILED_NAMES[@]}"; do printf '  ✗ %s\n' "$n"; done
    fi
    if [ "${#SKIPPED_NAMES[@]}" -gt 0 ]; then
        printf '%sAtlanan kontroller (ÖLÇÜLMEDİ — geçmiş sayılmaz):%s\n' "$BOLD" "$NC"
        for n in "${SKIPPED_NAMES[@]}"; do printf '  · %s\n' "$n"; done
    fi
    printf '\n%syedek kopya (master-slave): %d/%d geçti%s · %d kaldı · %d atlandı\n\n' \
           "$BOLD" "$T_PASS" "$ran" "$NC" "$T_FAIL" "$T_SKIP"

    if [ "$T_FAIL" -gt 0 ]; then exit 1; fi
    if [ "$ran" -eq 0 ]; then
        err "HİÇBİR KONTROL ÇALIŞMADI — bu bir BAŞARI değildir; yukarıdaki atlama sebeplerine bakın."
        exit 2
    fi
    exit 0
}

# Ctrl-C: yarıda kesilen koşu, ana kopyada test tablosu/hesabı bırakmasın.
on_interrupt() {
    printf '\n'
    warn "kesildi — test nesneleri temizleniyor"
    [ -n "$CUR_CLEANUP" ] && call_hook "$CUR_CLEANUP" >/dev/null 2>&1
    finish
}
trap on_interrupt INT TERM

# =============================================================================
# ANA AKIŞ
# =============================================================================
command -v docker  >/dev/null 2>&1 || die "docker bulunamadı — bu test canlı bir kuruluma karşı çalışır."
command -v python3 >/dev/null 2>&1 || die "python3 bulunamadı — katalog okunamıyor."
[ -f "$CATALOG" ] || die "catalog.json bulunamadı: $CATALOG"
[ -f "$ENV_FILE" ] || die ".env bulunamadı ($ENV_FILE) — önce ./install.sh"

heading "databases-stack — uçtan uca test: YEDEK KOPYA (master-slave)"
printf '  yığın kökü : %s\n' "$STACK_ROOT"
printf '  koşu damgası: %s\n' "$TOKEN"

ENGINES=()
if [ "$#" -gt 0 ]; then
    # Elle motor verildiyse, kapsam dışı olsa bile ATLAMA olarak raporlanır —
    # kullanıcı istediği motorun neden test edilmediğini görmeli.
    for a in "$@"; do
        if known_engine "$a"; then
            ENGINES+=("$a")
        else
            t_skip "$a: yedek kopya döngüsü" "katalogda böyle bir motor yok"
        fi
    done
else
    while IFS= read -r e; do [ -n "$e" ] && ENGINES+=("$e"); done < <(list_rep_engines)
    others="$(list_other_engines | tr '\n' ' ')"
    [ -n "$others" ] && log "kapsam dışı motorlar (katalogda primary-replica/replica-set değil): $others"
fi

# Tek bir motor bile çalışmayacaksa `die` ile kısa yoldan çıkmıyoruz: özet ve
# atlama sebepleri basılsın, çıkış kodu da belgelenen 2 olsun ("hiçbir kontrol
# çalışmadı"). Sessizce 1 dönen bir çıkış, "test koştu ve kaldı" sanılırdı.
if [ "${#ENGINES[@]}" -eq 0 ]; then
    err "test edilecek motor yok."
    finish
fi

for e in "${ENGINES[@]}"; do
    run_engine "$e"
done

finish
