#!/bin/bash
# =============================================================================
# databases-stack — E2E testi: AÇ / KAPAT ve VERİ KALICILIĞI
# =============================================================================
# Ürünün en temel iddiasını sınar: "motoru kapatınca veriniz SİLİNMEZ."
#
# Katalogdaki HER kayıt için (izleme aracı dahil) şu döngü çalışır:
#     aç → sağlıklı olmasını bekle → VERİ YAZ → geri oku → KAPAT →
#     tekrar aç → verinin YERİNDE olduğunu doğrula → yazdığını sil
#
# Neden "container ayakta" kontrolü yetmez: kapatmayı controller yapar
# (./stack.sh disable) ve controller yalnız `stop` demez, container'ı `rm -f`
# ile SİLER (bkz. controller/app.py: do_deactivate). Yeniden açıldığında
# container YENİDİR; veri ona yalnızca adlandırılmış volume'dan gelebilir.
# Eksik bir volume tanımı, yanlış bir data_path ya da imaj değişiminde kayan
# bir veri dizini tam burada patlar: container ayakta, healthcheck yeşil, panel
# açılıyor — ama içi boş. Dışarıdan hiçbir hata görünmez; kullanıcı kaybı ancak
# veriyi arayınca fark eder. Bu yüzden bu betik veri YAZAR, motoru gerçekten
# KAPATIR ve geri OKUR; ayrıca container KİMLİĞİNİN değiştiğini de doğrular —
# kapatma gerçekleşmediyse "veri duruyor" sonucu hiçbir şey kanıtlamaz.
#
# ÖLÇEMEDİK ≠ İYİ. Bu betikteki her kontrol iki soruyu ayrı ayrı cevaplar:
#   (a) ürün doğru davrandı mı?      → t_ok / t_fail
#   (b) ölçüm ARACI çalıştı mı?      → çalışmadıysa t_unknown (başarısız sayılır)
# Ölçüm aracı: docker daemon, docker exec, container'daki istemci ikilisi,
# HTTP durum kodu, JSON ayrıştırıcı. Bunların herhangi biri düştüğünde kontrol
# YEŞİL YAZAMAZ; "bilmiyorum" der. Sonuç türleri ve çıkış kodu için:
# scripts/e2e/lib.sh.
#
# Kullanım (yığın kökünden):
#   ./scripts/e2e/lifecycle.sh                 # katalogdaki bütün kayıtlar
#   ./scripts/e2e/lifecycle.sh mariadb redis   # yalnız seçilenler
#
# Ayarlar (ortam değişkeni):
#   E2E_ACTIVATE_TIMEOUT   ./stack.sh enable|disable üst sınırı (vars. 900 sn)
#   E2E_READY_TIMEOUT      hazır olma beklemesi (motor başına varsayılanı ezer)
#   E2E_QUERY_TIMEOUT      tek istemci komutu üst sınırı (vars. 90 sn)
#
# Bitince kurulum BULDUĞU HÂLE döner: testten önce kapalı olan motorlar tekrar
# kapatılır, yazılan probe verisi silinir. Geri alınamayan bir değişiklik
# kalırsa (kapatılamayan motor, silinemeyen probe kaydı) sonda AYRI bir liste
# hâlinde yazılır — sessizce bırakılmaz. Koşu Ctrl-C ile kesilirse EXIT
# temizliği aynı listeyi basar ve kalan artığı adıyla söyler.
#
# Süre: motor başına iki soğuk açılış. Üst sınır DUVAR SAATİYLE bağlıdır:
# motor başına en kötü hâl 2×E2E_ACTIVATE_TIMEOUT + 2×hazırlık sınırı; hazırlık
# sınırı motora göre 180-420 sn (ready_timeout). Tam katalog için 30-60 dakika
# ayırın (Cassandra ve MSSQL tek başına birkaç dakika alır).
# =============================================================================
# set -e YOK: bir motorun düşmesi diğerlerini ölçmemizi engellememeli. Her
# kontrol tek tek raporlanır, çıkış kodu sonda lib.sh tarafından belirlenir.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=../lib/common.sh
source scripts/lib/common.sh
load_env
# Ortak koşum kütüphanesi: dört sonuç türü (t_ok/t_fail/t_skip/t_unknown),
# sayaçlar, özet ve ÇIKIŞ KODU orada. common.sh'ten SONRA source ediliyor —
# renkleri common.sh tanımlar, lib.sh yalnız eksikse doldurur.
# shellcheck source=lib.sh
source scripts/e2e/lib.sh
E2E_SUITE="lifecycle"

ALAN="Aç/kapat ve veri kalıcılığı"

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
require_docker
# Hiçbir bekleme sonsuz olmayacak; bunun tek garantisi `timeout`.
command -v timeout >/dev/null 2>&1 || die "'timeout' (coreutils) gerekli: bu betikteki her bekleme üst sınırlı olmalı."
command -v python3 >/dev/null 2>&1 || die "'python3' gerekli (katalog ve JSON cevapları onunla okunuyor)."
[ -f "$ENV_FILE" ] || die ".env yok ($ENV_FILE). Önce ./install.sh çalıştırın."
[ -n "${DB_PASSWORD:-}" ] || die ".env içinde DB_PASSWORD boş — hiçbir motora bağlanılamaz."
container_running controller \
    || die "controller çalışmıyor. Aç/kapat işini controller yapar (bellek planı orada hesaplanır). Önce: ./stack.sh up"

ACT_TIMEOUT="${E2E_ACTIVATE_TIMEOUT:-900}"
DEX_TIMEOUT="${E2E_QUERY_TIMEOUT:-90}"

# Başarısızlık günlükleri burada durur; test tamamen temiz geçerse sonda silinir.
WORK="$STACK_ROOT/logs/e2e"
mkdir -p "$WORK" || die "Çalışma dizini açılamadı: $WORK"

# Probe adları SABİT (rastgele değil): yarıda kesilmiş bir çalıştırmadan kalan
# artığı bir sonraki çalıştırma bulup silebilsin diye. Değeri ise her turda
# FARKLI — böylece "geri okuduğum kayıt gerçekten AZ ÖNCE yazdığım kayıt mı?"
# sorusu cevaplanır; eski bir artık doğru cevabı taklit edemez.
TAG_SNAKE="e2e_lifecycle"                 # SQL/CQL/vhost/Grafana klasörü adı
TAG_DASH="e2e-lifecycle"                  # ES indeksi, Kafka topic'i, S3 bucket
TOKEN="lc$(date +%s)${RANDOM}"            # yalnız harf+rakam: hiçbir istemcide kaçış gerektirmez

# =============================================================================
# "ÖLÇEMEDİK" SINIFLANDIRMASI
# =============================================================================
# Bir istemci komutu sıfırdan farklı döndüğünde iki ihtimal var ve ikisi AYNI
# ŞEY DEĞİL:
#   • ürün yanlış cevap verdi          → t_fail
#   • komut hiç çalışamadı / bitmedi   → t_unknown ("bilmiyorum")
# Ayrım çıkış kodundan yapılıyor:
#   119  bu betiğin kendi kodu: cevabı çözemedik (HTTP durumu/JSON okunamadı,
#        istemci hiç çağrılamadı)
#   124  timeout(1) süreyi doldurdu — komut bitmedi, sonucu bilmiyoruz
#   125  docker komutu çalıştıramadı (daemon cevap vermiyor, container yok)
#   126  ikili çalıştırılamadı        127  ikili bulunamadı
# İstemcilerin kendi hata kodları bu aralığın dışında kalıyor (curl ≤ 99,
# psql 1-3, mariadb 1, sqlcmd 1, cqlsh 1-2, rabbitmqctl 64-70, mc 1-3).
E2E_RC_TOOL=119

tool_broke() { case "${1:-}" in 119|124|125|126|127) return 0 ;; *) return 1 ;; esac; }

rc_note() {
    case "${1:-}" in
        119) printf 'cevap çözülemedi (HTTP durumu ya da JSON ayrıştırılamadı)' ;;
        124) printf 'komut %s sn içinde bitmedi (timeout)' "$DEX_TIMEOUT" ;;
        125) printf 'docker komutu çalıştıramadı (daemon cevap vermiyor ya da container yok)' ;;
        126) printf "container'daki istemci çalıştırılamadı" ;;
        127) printf "container'da istemci bulunamadı" ;;
        *)   printf 'istemci çıkış kodu %s' "${1:-?}" ;;
    esac
}

# =============================================================================
# KESİNTİ TEMİZLİĞİ
# =============================================================================
# lib.sh INT/TERM'i yakalayıp 130 ile çıkıyor. Bizim temizliğimiz bu yüzden
# EXIT üzerinde: hem Ctrl-C'de hem normal çıkışta aynı yerden geçiyoruz ve
# lib.sh'in trap'iyle çakışmıyoruz.
#
# Denetim bulgusu: kesilen bir koşu, testin AÇTIĞI motoru açık ve içinde probe
# verisiyle bırakıyordu; bir sonraki koşu yazmadan önce temizlediği için artık
# görünmez oluyor ve "kurulum bulduğu hâle döner" garantisinin bozulduğu hiçbir
# yerde iz bırakmıyordu. Artık iz bırakıyor.
LC_DONE=0
# LC_BASLADI: motor döngüsüne girdik mi? Ön koşul `die`'ları da EXIT'ten geçer;
# onlarda "koşu yarıda kesildi, kurulum bozuldu" yazmak yanlış olurdu — o
# noktada henüz hiçbir şeye dokunmadık, die kendi sebebini zaten yazdı.
LC_BASLADI=0
LC_CUR_EID=""; LC_CUR_WAS_UP=1; LC_CUR_WROTE=0
LC_KALINTI=()

lc_kalinti_yaz() {
    [ "${#LC_KALINTI[@]}" -gt 0 ] || return 0
    warn "Bu koşu kurulumu bulduğu hâle TAM döndüremedi:"
    printf '    · %s\n' "${LC_KALINTI[@]}" >&2
}

lc_on_exit() {
    local rc=$? eid
    [ "$LC_DONE" -eq 1 ] && return "$rc"
    [ "$LC_BASLADI" -eq 0 ] && return "$rc"
    # Buraya düşmek KESİNTİ demektir (Ctrl-C, kill ya da beklenmedik çıkış).
    printf '\n' >&2
    warn "KOŞU YARIDA KESİLDİ — 'kurulum bulduğu hâle döner' garantisi BOZULDU."
    eid="$LC_CUR_EID"
    if [ -n "$eid" ]; then
        # Kesintide uzun işe girmiyoruz: './stack.sh disable' dakikalar sürer ve
        # ikinci bir Ctrl-C'yi bekletirdi. Yalnız KENDİ yazdığımız kaydı kısa
        # üst sınırla silmeyi deniyoruz; motorun açık kaldığı ekrana yazılıyor.
        DEX_TIMEOUT=15
        if [ "$LC_CUR_WROTE" -eq 1 ] && declare -F "clean_$eid" >/dev/null 2>&1; then
            if "clean_$eid" >/dev/null 2>&1; then
                warn "  · $eid: probe kaydı silindi ($TAG_SNAKE)"
            else
                warn "  · $eid: probe kaydı SİLİNEMEDİ — elle silin: '$TAG_SNAKE' / '$TAG_DASH' (değer $TOKEN)"
            fi
        fi
        if [ "$LC_CUR_WAS_UP" -eq 0 ]; then
            warn "  · $eid testten ÖNCE KAPALIYDI, şu an AÇIK kalmış olabilir. Geri almak için: ./stack.sh disable $eid"
        fi
    fi
    lc_kalinti_yaz
    warn "  Günlükler: $WORK"
    return "$rc"
}
trap lc_on_exit EXIT

# =============================================================================
# KATALOG — bağlantı bilgisinin TEK kaynağı
# =============================================================================
# Portlar, servis adları, kullanıcı/veritabanı adları ve hangi .env anahtarının
# parolayı taşıdığı katalogdan okunur. Sabit yazılsaydı katalog değiştiğinde bu
# test eski gerçeği doğrulamaya devam eder, yeşil kalır ve ayrışmayı kimse fark
# etmezdi.
CAT_DUMP="$WORK/catalog.fields"
# PYTHONIOENCODING: motor adları ASCII değil ("İzleme"). LANG=C olan bir cron
# ya da ssh oturumunda python varsayılan kodlamayla bunu yazamaz ve döküm
# yarım kalırdı — check-catalog.sh de aynı sebeple bunu açıkça veriyor.
PYTHONIOENCODING=utf-8 python3 - "$CATALOG" > "$CAT_DUMP" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
for e in cat["engines"]:
    c  = e.get("connection") or {}
    p  = e.get("panel") or {}
    cp = e.get("client_ports") or []
    print("|".join([
        e["id"],                                   # 1
        e.get("name", ""),                         # 2
        e.get("kind", "database"),                 # 3
        e.get("primary_service", ""),              # 4
        e.get("profile", ""),                      # 5
        str(c.get("username") or ""),              # 6
        str(c.get("database") or ""),              # 7
        str(c.get("password_env") or ""),          # 8
        str(cp[0]["port"]) if cp else "",          # 9
        str(p.get("port") or ""),                  # 10
    ]))
PY
CAT_RC=$?
# Dökümün ÇIKIŞ KODUNU okumak şart: python yarıda düşerse dosya boş değil
# ama EKSİK olur ve kalan motorlar sessizce "katalogda yok" sayılırdı —
# hiç ölçülmedikleri hâlde hiçbir yerde görünmezlerdi.
[ "$CAT_RC" -eq 0 ] || die "catalog.json dökümü başarısız (python3 çıkış $CAT_RC): $CATALOG"
[ -s "$CAT_DUMP" ] || die "catalog.json okunamadı (döküm boş): $CATALOG"
CAT_N="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1],encoding="utf-8"))["engines"]))' "$CATALOG" 2>/dev/null)"
DUMP_N="$(awk 'NF{n++} END{print n+0}' "$CAT_DUMP")"
case "$CAT_N" in ''|*[!0-9]*) die "catalog.json içindeki motor sayısı okunamadı: $CATALOG" ;; esac
[ "$CAT_N" -eq "$DUMP_N" ] \
    || die "catalog.json dökümü eksik: katalogda $CAT_N motor var, döküme $DUMP_N satır düştü ($CAT_DUMP). Eksik satırlar sessizce ÖLÇÜLMEZDİ."

cat_field()     { awk -F'|' -v id="$1" -v n="$2" '$1==id {print $n; exit}' "$CAT_DUMP"; }
all_engine_ids(){ awk -F'|' '{print $1}' "$CAT_DUMP"; }

# Parola: katalog hangi .env anahtarını okuyacağımızı söyler; anahtar BOŞSA
# compose'un kendi kuralı geçerlidir → ${X:-${DB_PASSWORD}}. Bu satır olmasaydı
# .env'de "MARIADB_PASSWORD=" (boş) bırakan her kurulumda test boş parolayla
# bağlanmaya çalışır, "Access denied" alır ve hatayı motorda arardı.
pw_of() {
    local var val=""
    var="$(cat_field "$1" 8)"
    # İzleme aracının katalogda connection bloğu yoktur (veritabanı değil);
    # Grafana parolasını compose ${GRAFANA_PASSWORD:-${DB_PASSWORD}} ile okur.
    [ "$1" = "monitoring" ] && var="GRAFANA_PASSWORD"
    [ -n "$var" ] && val="${!var:-}"
    [ -n "$val" ] || val="${DB_PASSWORD:-}"
    printf '%s' "$val"
}

# Kullanıcı adı: katalog varsayılanı + compose'un GERÇEKTEN okuduğu env
# override'ı. Kullanıcı adını .env'de değiştiren bir kurulumda katalog
# varsayılanıyla bağlanmak "authentication failed" verir; hata motorda sanılır,
# oysa yalnız test yanlış hesapla bağlanmıştır.
user_of() {
    local u; u="$(cat_field "$1" 6)"
    case "$1" in
        postgresql) u="${POSTGRES_USER:-$u}" ;;
        mongodb)    u="${MONGO_USER:-$u}" ;;
        cassandra)  u="${CASSANDRA_USER:-$u}" ;;
        clickhouse) u="${CLICKHOUSE_USER:-$u}" ;;
        rabbitmq)   u="${RABBITMQ_USER:-$u}" ;;
        neo4j)      u="${NEO4J_USER:-$u}" ;;
        minio)      u="${MINIO_ROOT_USER:-$u}" ;;
        monitoring) u="${GRAFANA_USER:-admin}" ;;
    esac
    printf '%s' "$u"
}

db_of() {
    local d; d="$(cat_field "$1" 7)"
    case "$1" in mariadb|postgresql) d="${DEFAULT_DATABASE:-$d}" ;; esac
    printf '%s' "$d"
}

# Motorun ŞU ANKİ ana kopya CONTAINER'ı.
# primary_of() topolojide kayıt yoksa MOTOR KİMLİĞİNİ döndürür. Kimliği birincil
# servis adıyla aynı olan motorlarda (mariadb → mariadb) bu tesadüfen doğrudur;
# olmayanlarda DEĞİLDİR: "monitoring" diye bir container yoktur, o kaydın
# birincil servisi "grafana"dır. Katalog kaydına düşmeseydik izleme aracı her
# koşulda "kapalı" görünür ve testi sessizce atlanırdı.
primary_container() {
    local eid="$1" p
    p="$(primary_of "$eid")"
    [ "$p" = "$eid" ] && p="$(cat_field "$eid" 4)"
    printf '%s' "$p"
}

# =============================================================================
# DOCKER'A SORARKEN "CEVAP GELMEDİ"Yİ AYIRT ET
# =============================================================================
# common.sh'teki container_running `docker ps | grep -qx` yapıyor: docker ps
# DÜŞERSE boru hattının kodu grep'ten gelir (1 = eşleşme yok) ve motor
# "çalışmıyor" sanılır. Bu betikte o cevap C3'ü doğrudan YEŞİL yazardı
# ("container kaldırıldı"), oysa kaldırılıp kaldırılmadığını hiç ölçemedik.
# Bu yüzden kendi üç durumlu sürümümüz var.
name_running() {   # 0 çalışıyor · 1 çalışmıyor · 2 DOCKER CEVAP VERMEDİ
    local out rc
    [ -n "${1:-}" ] || return 2
    out="$(timeout 30 docker ps --format '{{.Names}}' 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 2
    printf '%s\n' "$out" | grep -qx "$1"
}
eng_up() { name_running "$(primary_container "$1")"; }

# 0: container VAR (durumu stdout'ta) · 1: container YOK · 2: ÖLÇEMEDİK
container_state() {
    local out rc
    [ -n "${1:-}" ] || { printf 'container adı boş'; return 2; }
    out="$(timeout 30 docker inspect -f '{{.State.Status}}' "$1" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
    # "No such object" docker'ın "böyle bir container yok" cevabıdır — bu bir
    # ÖLÇÜM, arıza değil. Başka her hata (daemon yok, izin yok) ölçemedik.
    case "$out" in
        *"No such object"*|*"no such object"*|*"No such container"*) printf 'yok'; return 1 ;;
    esac
    printf '%s' "$(printf '%s' "$out" | tr -d '\n' | cut -c1-120)"
    return 2
}

# docker exec bu container'da çalışıyor mu? "İstemci ikilisi yok" ile "docker
# cevap vermiyor" iki AYRI sonuçtur: birincisi ATLANDI, ikincisi ÖLÇÜLEMEDİ.
exec_alive() { timeout "$DEX_TIMEOUT" docker exec "$1" sh -c ':' >/dev/null 2>&1; }

health_note() {
    local out
    out="$(timeout 30 docker inspect -f '{{.State.Status}}{{if .State.Health}} / sağlık: {{.State.Health.Status}}{{end}}' "$1" 2>/dev/null)" \
        || { printf 'durum okunamadı (docker inspect düştü)'; return 0; }
    printf '%s' "${out:-durum boş döndü}"
}

# Container kimliği; OKUNAMAZSA boş yazar ve 1 döner. Çağıran bu farkı görmek
# ZORUNDA: kimlik okunamadığında "container yeniden yaratıldı" şartı
# doğrulanamaz ve o şart sessizce devre dışı kalırsa kapanmamış bir motordan
# okunan veri GEÇTİ sayılırdı (denetim bulgusu).
cid_of() {
    local id rc
    id="$(timeout 30 docker inspect -f '{{.Id}}' "$1" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    [ -n "$id" ] || return 1
    printf '%.12s' "$id"
}

# Soğuk açılış süreleri çok farklı (Redis 5 sn, Cassandra 3 dakika). Değerler
# compose'daki healthcheck start_period'larından bir tık cömerttir: "hazır
# olmadı" demek gerçek bir arıza olsun, yavaş diskin faturası olmasın.
ready_timeout() {
    [ -n "${E2E_READY_TIMEOUT:-}" ] && { printf '%s' "$E2E_READY_TIMEOUT"; return; }
    case "$1" in
        cassandra)              printf '420' ;;
        mssql|elasticsearch)    printf '300' ;;
        kafka|neo4j|monitoring) printf '240' ;;
        *)                      printf '180' ;;
    esac
}

client_of() {
    case "$1" in
        mariadb)       printf 'mariadb istemcisi' ;;
        postgresql)    printf 'psql' ;;
        mongodb)       printf '%s' "${MONGO_SHELL:-mongosh}" ;;
        redis)         printf 'redis-cli' ;;
        mssql)         printf 'sqlcmd' ;;
        cassandra)     printf 'cqlsh' ;;
        elasticsearch) printf 'curl (REST)' ;;
        kafka)         printf 'kafka-topics.sh' ;;
        rabbitmq)      printf 'rabbitmqctl' ;;
        clickhouse)    printf 'clickhouse-client' ;;
        neo4j)         printf 'cypher-shell' ;;
        minio)         printf 'mc (S3)' ;;
        monitoring)    printf 'Grafana HTTP API' ;;
        *)             printf 'istemci' ;;
    esac
}
port_note() {
    local p; p="$(cat_field "$1" 9)"
    [ -n "$p" ] || p="$(cat_field "$1" 10)"   # araç kaydının istemci portu yok, panel portu var
    [ -n "$p" ] && printf ' (port %s)' "$p"
    return 0
}

# HTTP cevabını gövde + son satırda durum kodu olarak alıyoruz. Sebep: curl'ün
# ÇIKIŞ KODU HTTP durumunu ayırt etmez — `-f` altında 401 (parola yanlış) ile
# 404 (belge yok) aynı koda (22) düşer. Birincisi "ÖLÇEMEDİK", ikincisi "veri
# kayboldu" demektir; ikisini karıştırmak sağlam bir kurulumu "veri kaybediyor"
# diye suçlamak ya da tersi olurdu.
http_code_of() { printf '%s' "${1##*$'\n'}"; }
http_body_of() { printf '%s' "${1%$'\n'*}"; }

# =============================================================================
# İSTEMCİ ÇAĞRILARI
# =============================================================================
# Hepsi `docker exec <container> <istemci>` — host'ta veritabanı istemcisi YOK.
# Parolalar komut satırına DEĞİL ortama konur (-e): komut satırında olsalardı
# host'ta `ps` çıktısında ve container'ın /proc'unda görünürlerdi. Bu, depodaki
# backup.sh ve scripts/replication/*.sh ile aynı desen.
#
# read_* SÖZLEŞMESİ (dört sonuç türü buna dayanıyor):
#   çıkış 0            → sorgu çalıştı; okunan değer stdout'ta (BOŞ olabilir:
#                        "kayıt yok" gerçek bir ölçümdür → veri kaybı sinyali)
#   tool_broke çıkışı  → sorgu HİÇ çalışamadı → ÖLÇEMEDİK
#   başka çıkış        → istemci hata verdi → ürün tarafında arıza
# Bu yüzden hiçbir read_* filtre borusunun çıkış kodunu istemcininkinin yerine
# döndürmez: `grep`/`head` kodu istemcinin kodunu yutar ve "sorgu düştü"yü
# "kayıt yok"a çevirirdi.
dex()  { timeout "$DEX_TIMEOUT" docker exec "$@"; }
dexi() { timeout "$DEX_TIMEOUT" docker exec -i "$@"; }

# --- MariaDB ---------------------------------------------------------------
_my() {
    MYSQL_PWD="$(pw_of mariadb)" dex -e MYSQL_PWD "$(primary_container mariadb)" \
        mariadb -u "$(user_of mariadb)" -N -B -e "$1"
}
probe_mariadb() { _my "SELECT 1;" >/dev/null 2>&1; }
write_mariadb() {
    local db; db="$(db_of mariadb)"
    _my "CREATE DATABASE IF NOT EXISTS \`$db\`;
         CREATE TABLE IF NOT EXISTS \`$db\`.$TAG_SNAKE (k VARCHAR(32) PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
         REPLACE INTO \`$db\`.$TAG_SNAKE (k,v) VALUES ('probe','$TOKEN');"
}
read_mariadb() {
    local db raw; db="$(db_of mariadb)"
    raw="$(_my "SELECT v FROM \`$db\`.$TAG_SNAKE WHERE k='probe';")" || return $?
    printf '%s' "$raw"
    return 0
}
clean_mariadb() { local db; db="$(db_of mariadb)"; _my "DROP TABLE IF EXISTS \`$db\`.$TAG_SNAKE;"; }

# --- PostgreSQL ------------------------------------------------------------
_pg() {
    dex -e PGPASSWORD="$(pw_of postgresql)" "$(primary_container postgresql)" \
        psql -X -q -A -t -v ON_ERROR_STOP=1 -U "$(user_of postgresql)" -d "$(db_of postgresql)" -c "$1"
}
probe_postgresql() { _pg "SELECT 1;" >/dev/null 2>&1; }
write_postgresql() {
    _pg "CREATE TABLE IF NOT EXISTS $TAG_SNAKE (k text PRIMARY KEY, v text);
         DELETE FROM $TAG_SNAKE;
         INSERT INTO $TAG_SNAKE (k,v) VALUES ('probe','$TOKEN');"
}
read_postgresql() {
    local raw
    raw="$(_pg "SELECT v FROM $TAG_SNAKE WHERE k='probe';")" || return $?
    printf '%s' "$raw"
    return 0
}
clean_postgresql() { _pg "DROP TABLE IF EXISTS $TAG_SNAKE;"; }

# --- MongoDB ---------------------------------------------------------------
# MONGO_SHELL: 5.0 öncesinde mongosh yoktur, .env onu `mongo`ya çevirebilir —
# compose healthcheck'i de aynı değişkeni okur, biz de ona uyuyoruz.
_mongo() {
    dex -e M_PW="$(pw_of mongodb)" -e M_USER="$(user_of mongodb)" \
        -e M_SH="${MONGO_SHELL:-mongosh}" "$(primary_container mongodb)" \
        sh -c 'exec "$M_SH" --quiet -u "$M_USER" -p "$M_PW" --authenticationDatabase admin --eval "$1"' sh "$1"
}
probe_mongodb() { _mongo 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; }
write_mongodb() {
    _mongo "db.getSiblingDB('$TAG_SNAKE').probe.replaceOne({_id:'probe'},{_id:'probe',v:'$TOKEN'},{upsert:true})" >/dev/null
}
read_mongodb() {
    local raw
    raw="$(_mongo "var d=db.getSiblingDB('$TAG_SNAKE').probe.findOne({_id:'probe'}); print(d ? d.v : '')")" || return $?
    printf '%s' "$raw"
    return 0
}
clean_mongodb() { _mongo "db.getSiblingDB('$TAG_SNAKE').dropDatabase()" >/dev/null; }

# --- Redis -----------------------------------------------------------------
# Bilerek SAVE/BGSAVE ÇAĞIRMIYORUZ: elle kaydettirseydik kalıcılık ayarı
# (REDIS_APPENDONLY) kapalı olan bir kurulumda da test geçerdi. Ölçmek
# istediğimiz tam olarak şu: normal kapanışta veri kendiliğinden kalıyor mu?
_redis() { dex -e REDISCLI_AUTH="$(pw_of redis)" "$(primary_container redis)" redis-cli --no-auth-warning "$@"; }
probe_redis() {
    local out
    # `|| return 1` demiyoruz: docker/timeout kodu (125/124) buradan geçmeli,
    # yoksa "ölçemedik" hâli "motor cevap vermedi"ye dönüşür.
    out="$(_redis PING 2>/dev/null)" || return $?
    [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "PONG" ]
}
write_redis() { _redis SET "$TAG_SNAKE:probe" "$TOKEN" >/dev/null; }
read_redis() {
    local raw
    raw="$(_redis GET "$TAG_SNAKE:probe")" || return $?
    printf '%s' "$raw"
    return 0
}
clean_redis() { _redis DEL "$TAG_SNAKE:probe" >/dev/null; }

# --- SQL Server ------------------------------------------------------------
# sqlcmd'nin yeri imaj sürümüyle değişti (mssql-tools → mssql-tools18). Yolu
# sabit yazmak yerine container'da arıyoruz: imaj değişince test "bağlanamadı"
# demek yerine ya doğru yoldan çalışsın ya da NEDENİNİ söyleyip atlasın.
_sqlcmd_bin() {
    dex "$1" sh -c '
        for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
            [ -x "$p" ] && { printf "%s" "$p"; exit 0; }
        done
        command -v sqlcmd 2>/dev/null && exit 0
        exit 1' 2>/dev/null
}
_sq() {
    local c bin rc
    c="$(primary_container mssql)"
    bin="$(_sqlcmd_bin "$c")"; rc=$?
    # sqlcmd bulunamadıysa bu bir İSTEMCİ eksikliğidir, "sunucu yanlış cevap
    # verdi" değil — ölçemedik koduyla dönüyoruz (precheck zaten önce atlatır).
    [ "$rc" -eq 0 ] && [ -n "$bin" ] || return "$E2E_RC_TOOL"
    # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir (yoksa
    # başarısız yazma "başarılı" sanılırdı). -h -1 -W: başlıksız, kırpılmış çıktı.
    SQLCMDPASSWORD="$(pw_of mssql)" dex -e SQLCMDPASSWORD "$c" \
        "$bin" -S localhost -U "$(user_of mssql)" -C -b -h -1 -W -Q "SET NOCOUNT ON; $1"
}
probe_mssql() { _sq "SELECT 1;" >/dev/null 2>&1; }
precheck_mssql() {
    local c bin rc
    c="$(primary_container mssql)"
    bin="$(_sqlcmd_bin "$c")"; rc=$?
    [ "$rc" -eq 0 ] && [ -n "$bin" ] && return 0
    if ! exec_alive "$c"; then
        printf '%s' "'$c' container'ında docker exec çalışmıyor — sqlcmd var mı yok mu ÖLÇEMEDİK"
        return 2
    fi
    printf '%s' "container'da sqlcmd yok (/opt/mssql-tools18/bin ve /opt/mssql-tools/bin boş) — MSSQL_IMAGE değiştirilmiş olabilir"
    return 1
}
write_mssql() {
    _sq "IF OBJECT_ID('dbo.$TAG_SNAKE','U') IS NULL CREATE TABLE dbo.$TAG_SNAKE (k varchar(32) PRIMARY KEY, v varchar(64));
         DELETE FROM dbo.$TAG_SNAKE;
         INSERT INTO dbo.$TAG_SNAKE (k,v) VALUES ('probe','$TOKEN');"
}
read_mssql() {
    local raw
    raw="$(_sq "SELECT v FROM dbo.$TAG_SNAKE WHERE k='probe';")" || return $?
    printf '%s' "$raw"
    return 0
}
clean_mssql() { _sq "IF OBJECT_ID('dbo.$TAG_SNAKE','U') IS NOT NULL DROP TABLE dbo.$TAG_SNAKE;"; }

# --- Cassandra -------------------------------------------------------------
# Kullanıcı adı da -e ile geçiyor: tek tırnaklı sh -c içindeki değişkenler
# HOST'ta değil CONTAINER'da çözülür (backup.sh'te bu tam olarak bir hataydı).
_cql() {
    dex -e CQLSH_USER="$(user_of cassandra)" -e CQLSH_PW="$(pw_of cassandra)" \
        "$(primary_container cassandra)" \
        sh -c 'exec cqlsh -u "$CQLSH_USER" -p "$CQLSH_PW" -e "$1"' sh "$1"
}
probe_cassandra() { _cql "SELECT release_version FROM system.local;" >/dev/null 2>&1; }
write_cassandra() {
    _cql "CREATE KEYSPACE IF NOT EXISTS $TAG_SNAKE WITH replication={'class':'SimpleStrategy','replication_factor':1};" >/dev/null \
        && _cql "CREATE TABLE IF NOT EXISTS $TAG_SNAKE.probe (k text PRIMARY KEY, v text);" >/dev/null \
        && _cql "INSERT INTO $TAG_SNAKE.probe (k,v) VALUES ('probe','$TOKEN');" >/dev/null
}
read_cassandra() {
    local raw val
    raw="$(_cql "SELECT v FROM $TAG_SNAKE.probe WHERE k='probe';")" || return $?
    # cqlsh tabloyu çerçeveli basar: başlık, tire satırı, boş satırlar,
    # "(1 rows)". Değeri bunları eleyerek çıkarıyoruz. Filtrenin çıkış kodu
    # KULLANILMIYOR — eşleşme bulunmaması "sorgu düştü" değil "kayıt yok"tur.
    val="$(printf '%s\n' "$raw" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
           | grep -vE '^$|^-+$|^v$|^\([0-9]+ rows?\)$' | head -1)"
    printf '%s' "$val"
    return 0
}
clean_cassandra() { _cql "DROP KEYSPACE IF EXISTS $TAG_SNAKE;" >/dev/null; }

# --- Elasticsearch ---------------------------------------------------------
_es() {
    dex -e ES_USER="$(user_of elasticsearch)" -e ES_PW="$(pw_of elasticsearch)" \
        "$(primary_container elasticsearch)" \
        sh -c 'exec curl -sS --max-time 30 -u "$ES_USER:$ES_PW" "$@"' sh "$@"
}
# Gövdeyle birlikte HTTP durumunu da alan sürüm (bkz. http_code_of yorumu).
_es_http() { _es -w '\n%{http_code}' "$@"; }
probe_elasticsearch() { _es -f "http://127.0.0.1:9200/_cluster/health" >/dev/null 2>&1; }
# C1'i yetkili bir çağrıyla ölçüyoruz ve 401'i "hazır değil" ile karıştırmıyoruz.
verify_elasticsearch() {
    local out code
    out="$(_es_http "http://127.0.0.1:9200/_cluster/health")" || return $?
    code="$(http_code_of "$out")"
    case "$code" in
        2*)          return 0 ;;
        401|403)     printf 'Elasticsearch kimlik doğrulamayı reddetti (HTTP %s) — .env parolası ile sorgu yapılamıyor\n' "$code" >&2
                     return "$E2E_RC_TOOL" ;;
        ''|*[!0-9]*) printf 'HTTP durumu okunamadı: %s\n' "$out" >&2; return "$E2E_RC_TOOL" ;;
        *)           printf 'Elasticsearch HTTP %s: %s\n' "$code" "$(http_body_of "$out")" >&2; return 1 ;;
    esac
}
# refresh=true: belge yazıldıktan HEMEN sonra aranabilir olsun — yoksa "yazdım
# ama okuyamadım" hatası, aslında yalnız 1 saniyelik refresh gecikmesi olurdu.
write_elasticsearch() {
    local out code
    out="$(_es_http -X PUT -H "Content-Type: application/json" -d "{\"v\":\"$TOKEN\"}" \
           "http://127.0.0.1:9200/$TAG_DASH/_doc/probe?refresh=true")" || return $?
    code="$(http_code_of "$out")"
    case "$code" in
        2*)          return 0 ;;
        401|403)     printf 'Elasticsearch kimlik doğrulamayı reddetti (HTTP %s)\n' "$code" >&2; return "$E2E_RC_TOOL" ;;
        ''|*[!0-9]*) printf 'HTTP durumu okunamadı: %s\n' "$out" >&2; return "$E2E_RC_TOOL" ;;
        *)           printf 'Elasticsearch HTTP %s: %s\n' "$code" "$(http_body_of "$out")" >&2; return 1 ;;
    esac
}
read_elasticsearch() {
    local out code body val prc
    out="$(_es_http "http://127.0.0.1:9200/$TAG_DASH/_doc/probe")" || return $?
    code="$(http_code_of "$out")"; body="$(http_body_of "$out")"
    case "$code" in
        2*)  ;;
        # 404 GERÇEK BİR ÖLÇÜMDÜR: indeks/belge yok → boş dön, çağıran bunu
        # "veri kayboldu" diye raporlasın.
        404) return 0 ;;
        401|403)     printf 'Elasticsearch kimlik doğrulamayı reddetti (HTTP %s)\n' "$code" >&2; return "$E2E_RC_TOOL" ;;
        ''|*[!0-9]*) printf 'HTTP durumu okunamadı: %s\n' "$out" >&2; return "$E2E_RC_TOOL" ;;
        # 5xx: sunucu arızalı; belge var mı yok mu BİLMİYORUZ.
        *)           printf 'Elasticsearch HTTP %s: %s\n' "$code" "$body" >&2; return "$E2E_RC_TOOL" ;;
    esac
    val="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
print(d.get("_source", {}).get("v", ""))')"; prc=$?
    [ "$prc" -eq 0 ] || { printf 'Elasticsearch cevabı JSON değil: %s\n' "$body" >&2; return "$E2E_RC_TOOL"; }
    printf '%s' "$val"
    return 0
}
clean_elasticsearch() { _es -f -X DELETE "http://127.0.0.1:9200/$TAG_DASH" >/dev/null; }

# --- Kafka -----------------------------------------------------------------
_kt() { dex "$(primary_container kafka)" /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 "$@"; }
probe_kafka() { _kt --list >/dev/null 2>&1; }
write_kafka() {
    # Topic SİLME KRaft'ta eşzamansızdır: az önce silinmiş bir topic'i hemen
    # yaratmak "marked for deletion" hatası verir. Bu tam olarak yarıda kesilmiş
    # bir çalıştırmanın ardından olur — test KENDİ temizliği yüzünden
    # düşmesin diye create birkaç kez deneniyor (üst sınır: 30 sn).
    local i=0 rc=0
    until _kt --create --if-not-exists --topic "$TAG_DASH" --partitions 1 --replication-factor 1 >/dev/null 2>&1; do
        rc=$?
        # docker/timeout arızasında yeniden denemek anlamsız: cevabı bilmiyoruz.
        tool_broke "$rc" && return "$rc"
        i=$((i+1)); [ "$i" -ge 6 ] && return "$rc"
        sleep 5
    done
    printf '%s\n' "$TOKEN" | dexi "$(primary_container kafka)" \
        /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic "$TAG_DASH" >/dev/null 2>&1
}
# SON mesajı okuyoruz, ilkini değil: yarıda kesilmiş bir çalıştırmadan kalan
# eski mesaj topic'te duruyorsa --from-beginning onu döndürür ve test, sağlam
# bir kurulumu "veri değişmiş" diye düşürürdü. Offset alınamazsa baştan
# okumaya düşüyoruz — ölçmemektense zayıf ölçmek yeğdir, ama docker/timeout
# arızasında zayıf da ölçemeyiz: o hâlde ÖLÇEMEDİK deyip dönüyoruz.
read_kafka() {
    local c end off="" raw rc
    c="$(primary_container kafka)"
    end="$(dex "$c" /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server localhost:9092 \
              --topic "$TAG_DASH" --time -1 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        end="$(printf '%s\n' "$end" | tr -d '\r' | head -1)"; end="${end##*:}"
        case "$end" in ''|*[!0-9]*) off="" ;; *) [ "$end" -gt 0 ] && off=$((end-1)) ;; esac
    elif tool_broke "$rc"; then
        return "$rc"
    fi
    if [ -n "$off" ]; then
        raw="$(dex "$c" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
              --topic "$TAG_DASH" --partition 0 --offset "$off" --max-messages 1 --timeout-ms 20000 2>/dev/null)"; rc=$?
    else
        raw="$(dex "$c" /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
              --topic "$TAG_DASH" --from-beginning --max-messages 1 --timeout-ms 20000 2>/dev/null)"; rc=$?
    fi
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$(printf '%s\n' "$raw" | tr -d '\r' | head -1)"
    return 0
}
clean_kafka() { _kt --delete --topic "$TAG_DASH" >/dev/null 2>&1; }

# --- RabbitMQ --------------------------------------------------------------
# Kuyruktaki MESAJ değil, TANIM kalıcılığı ölçülüyor — backup.sh de RabbitMQ'da
# tanımları yedekler ("mesajlar geçicidir"). Token'ı vhost ADINDA taşıyoruz:
# rabbitmqctl ile mesaj üretilemez, ama vhost dayanıklı yazılır ve
# /var/lib/rabbitmq volume'unda durur — kalıcılık sorusu için doğru nesne budur.
_rmq() { dex "$(primary_container rabbitmq)" rabbitmqctl "$@"; }
# ping YETMEZ: yalnız Erlang düğümünün cevap verdiğini gösterir, 'rabbit'
# uygulaması hâlâ başlıyor olabilir. Paket o aralıkta "hazır" deyip
# add_vhost çağırıyor ve çıkış 64 ile düşüyordu — ürün suçlanıyordu,
# oysa hazır olduğunu SÖYLEYEN bizdik. check_running uygulamanın
# çalıştığını ölçer (compose healthcheck'i de artık bunu kullanıyor).
probe_rabbitmq() { dex "$(primary_container rabbitmq)" rabbitmq-diagnostics -q check_running >/dev/null 2>&1; }
write_rabbitmq() { _rmq add_vhost "${TAG_SNAKE}_$TOKEN" >/dev/null; }
read_rabbitmq() {
    local raw val
    raw="$(_rmq -q list_vhosts name)" || return $?
    raw="$(printf '%s\n' "$raw" | tr -d '\r')"
    # ÖNCE TAM eşleşme: yarıda kesilmiş bir koşudan kalan eski vhost listede
    # önce gelirse `head -1` onu döndürür ve sağlam bir kurulum "veri değişmiş"
    # diye düşerdi. Tam eşleşme yoksa artığı raporlayabilmek için ilk öneki
    # döndürüyoruz — hata satırında hangi değerin bulunduğu görünsün.
    if printf '%s\n' "$raw" | grep -qx "${TAG_SNAKE}_$TOKEN"; then
        printf '%s' "$TOKEN"; return 0
    fi
    val="$(printf '%s\n' "$raw" | grep "^${TAG_SNAKE}_" | head -1)"
    [ -n "$val" ] && printf '%s' "${val#"${TAG_SNAKE}_"}"
    return 0
}
clean_rabbitmq() {
    local v raw rc=0
    raw="$(_rmq -q list_vhosts name)" || return $?
    for v in $(printf '%s\n' "$raw" | tr -d '\r' | grep "^${TAG_SNAKE}_"); do
        _rmq delete_vhost "$v" >/dev/null 2>&1 || rc=1
    done
    return "$rc"
}

# --- ClickHouse ------------------------------------------------------------
_ch() {
    dex -e CH_USER="$(user_of clickhouse)" -e CH_PW="$(pw_of clickhouse)" \
        "$(primary_container clickhouse)" \
        sh -c 'exec clickhouse-client --user "$CH_USER" --password "$CH_PW" "$@"' sh "$@"
}
probe_clickhouse() { _ch --query "SELECT 1" >/dev/null 2>&1; }
write_clickhouse() {
    local db; db="$(db_of clickhouse)"
    _ch --query "CREATE TABLE IF NOT EXISTS \`$db\`.$TAG_SNAKE (k String, v String) ENGINE=MergeTree ORDER BY k" >/dev/null \
        && _ch --query "TRUNCATE TABLE \`$db\`.$TAG_SNAKE" >/dev/null \
        && _ch --query "INSERT INTO \`$db\`.$TAG_SNAKE (k,v) VALUES ('probe','$TOKEN')" >/dev/null
}
read_clickhouse() {
    local db raw; db="$(db_of clickhouse)"
    raw="$(_ch --query "SELECT v FROM \`$db\`.$TAG_SNAKE WHERE k='probe' LIMIT 1")" || return $?
    printf '%s' "$raw"
    return 0
}
clean_clickhouse() { local db; db="$(db_of clickhouse)"; _ch --query "DROP TABLE IF EXISTS \`$db\`.$TAG_SNAKE" >/dev/null; }

# --- Neo4j -----------------------------------------------------------------
# cypher-shell kullanıcı/parolayı NEO4J_USERNAME / NEO4J_PASSWORD ortamından
# okur; komut satırına yazmıyoruz.
_cyp() {
    dex -e NEO4J_USERNAME="$(user_of neo4j)" -e NEO4J_PASSWORD="$(pw_of neo4j)" \
        "$(primary_container neo4j)" cypher-shell --non-interactive --format plain "$1"
}
probe_neo4j() { _cyp "RETURN 1;" >/dev/null 2>&1; }
write_neo4j() { _cyp "MERGE (n:E2eLifecycle {k:'probe'}) SET n.v='$TOKEN';" >/dev/null; }
read_neo4j() {
    local raw val
    raw="$(_cyp "MATCH (n:E2eLifecycle {k:'probe'}) RETURN n.v;")" || return $?
    val="$(printf '%s\n' "$raw" | tr -d '"\r' | grep -vE '^n\.v$|^$' | head -1)"
    printf '%s' "$val"
    return 0
}
clean_neo4j() { _cyp "MATCH (n:E2eLifecycle) DETACH DELETE n;" >/dev/null; }

# --- MinIO -----------------------------------------------------------------
# S3 API'sine kabuktan imzalı istek atmak SigV4 gerektirir; imajın kendi `mc`
# istemcisini kullanıyoruz. Alias yapılandırması /tmp'ye yazılır ve container
# kapat-aç turunda SİLİNİR (controller container'ı `rm -f` ediyor) — bu yüzden
# her çağrıda yeniden kuruluyor. Bir kez kurup bıraksaydık ikinci okuma "alias
# yok" diye düşer ve bu, veri kaybı gibi raporlanırdı.
_mc() {
    dex -e MC_USER="$(user_of minio)" -e MC_PW="$(pw_of minio)" "$(primary_container minio)" sh -c '
        mc --config-dir /tmp/e2e-mc alias set e2e http://127.0.0.1:9000 "$MC_USER" "$MC_PW" >/dev/null 2>&1 || exit 3
        exec mc --config-dir /tmp/e2e-mc "$@"' sh "$@"
}
_mc_stdin() {
    dexi -e MC_USER="$(user_of minio)" -e MC_PW="$(pw_of minio)" "$(primary_container minio)" sh -c '
        mc --config-dir /tmp/e2e-mc alias set e2e http://127.0.0.1:9000 "$MC_USER" "$MC_PW" >/dev/null 2>&1 || exit 3
        exec mc --config-dir /tmp/e2e-mc "$@"' sh "$@"
}
# Hazırlık kontrolü curl ile: MinIO healthcheck'i de bunu kullanır ve `mc`
# olmasa bile doğru cevabı verir (mc'nin yokluğunu precheck ayrıca raporlar).
probe_minio() { dex "$(primary_container minio)" curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; }
# C1 "mc (S3) ile sorguya cevap veriyor" DİYOR; /minio/health/live ise imzasız
# ve KİMLİK DOĞRULAMAYAN bir uçtur. Sırf onunla yeşil yazmak, yanlış anahtarla
# da GEÇTİ demek olurdu — C1'i gerçek bir S3 çağrısıyla ölçüyoruz.
verify_minio() { _mc ls e2e/ >/dev/null; }
precheck_minio() {
    local c
    c="$(primary_container minio)"
    dex "$c" sh -c 'command -v mc >/dev/null 2>&1' >/dev/null 2>&1 && return 0
    if ! exec_alive "$c"; then
        printf '%s' "'$c' container'ında docker exec çalışmıyor — mc var mı yok mu ÖLÇEMEDİK"
        return 2
    fi
    printf '%s' "MinIO imajında 'mc' istemcisi yok; S3 imzası (SigV4) kabuk betiğinden üretilemiyor — MINIO_IMAGE mc içeren bir imaja çevrilirse ölçülebilir"
    return 1
}
write_minio() {
    local rc
    _mc mb --ignore-existing "e2e/$TAG_DASH" >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$TOKEN" | _mc_stdin pipe "e2e/$TAG_DASH/probe.txt" >/dev/null
}
read_minio() {
    local raw
    raw="$(_mc cat "e2e/$TAG_DASH/probe.txt")" || return $?
    printf '%s' "$raw"
    return 0
}
clean_minio() {
    local rc=0
    _mc rb --force "e2e/$TAG_DASH" >/dev/null 2>&1 || rc=1
    dex "$(primary_container minio)" sh -c 'rm -rf /tmp/e2e-mc' >/dev/null 2>&1
    return "$rc"
}

# --- İzleme (Prometheus + Grafana) -----------------------------------------
# Kalıcılığı ölçülen şey Grafana'nın kendi veritabanı (grafana_data volume):
# token'ı taşıyan bir klasör yaratılıp kapat-aç turundan sonra aranıyor.
# Prometheus'un ölçüm verisi bilerek kapsam dışı — katalog da onun
# yedeklenmeyeceğini söylüyor ("kaybolursa yeniden toplanır").
GF_C=""; GF_BASE=""
_gf_pick() {
    [ -n "$GF_C" ] && return 0
    local c; c="$(primary_container monitoring)"
    [ -n "$c" ] || return 1
    if dex "$c" sh -c 'command -v curl >/dev/null 2>&1' >/dev/null 2>&1; then
        GF_C="$c"; GF_BASE="http://127.0.0.1:3000"; return 0
    fi
    # Grafana imajında curl yoksa aynı ağdaki gateway'den geçiyoruz; orada curl
    # olduğunu ./stack.sh doctor da varsayıyor.
    if name_running gateway && dex gateway sh -c 'command -v curl >/dev/null 2>&1' >/dev/null 2>&1; then
        GF_C="gateway"; GF_BASE="http://$c:3000"; return 0
    fi
    return 1
}
# ÇIKTI: gövde + son satırda HTTP durum kodu. curl'ün çıkış kodu 401'i 200'den
# ayırmaz; denetimde bulunan "yanlış parolayla da GEÇTİ" ve "401 gövdesini boş
# cevap sanıp veri kayboldu deme" hatalarının ikisi de buradan çıkıyordu.
_gf() {   # _gf <METOD> <yol> [gövde]
    _gf_pick || return "$E2E_RC_TOOL"
    local m="$1" p="$2" b="${3:-}"
    if [ -n "$b" ]; then
        dex -e GF_U="$(user_of monitoring)" -e GF_P="$(pw_of monitoring)" "$GF_C" sh -c \
            'exec curl -sS -w "\n%{http_code}" --max-time 30 -u "$GF_U:$GF_P" -X "$1" -H "Content-Type: application/json" --data "$3" "$2"' \
            sh "$m" "$GF_BASE$p" "$b"
    else
        dex -e GF_U="$(user_of monitoring)" -e GF_P="$(pw_of monitoring)" "$GF_C" sh -c \
            'exec curl -sS -w "\n%{http_code}" --max-time 30 -u "$GF_U:$GF_P" -X "$1" "$2"' sh "$m" "$GF_BASE$p"
    fi
}
# Hazırlık için container'ın KENDİ healthcheck'ine bakıyoruz: HTTP istemcisi
# olmayan bir imajda bile doğru cevabı verir ve ürünün "hazır" tanımıyla aynıdır.
# AMA healthcheck KİMLİK DOĞRULAMAZ; C1'i onunla vermiyoruz (verify_monitoring).
probe_monitoring() {
    local out rc
    out="$(timeout 30 docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
           "$(primary_container monitoring)" 2>/dev/null)"; rc=$?
    # inspect düşerse "sağlıklı değil" değil, "ÖLÇEMEDİK" demektir.
    [ "$rc" -eq 0 ] || return "$E2E_RC_TOOL"
    [ "$out" = "healthy" ]
}
# C1'in adı "Grafana HTTP API ile sorguya cevap veriyor". Denetim bulgusu: bu
# kontrol yalnız docker healthcheck'ini okuyordu ve healthcheck kimlik
# doğrulamadığı için YANLIŞ PAROLAYLA DA GEÇTİ yazıyordu. Artık adının söylediği
# şeyi ölçüyor: .env'deki hesapla gerçek bir API çağrısı.
verify_monitoring() {
    local out code
    out="$(_gf GET /api/folders)" || return $?
    code="$(http_code_of "$out")"
    case "$code" in
        2*)          return 0 ;;
        401|403)     printf 'Grafana kimlik doğrulamayı reddetti (HTTP %s) — .env GRAFANA_PASSWORD ile API açılmıyor\n' "$code" >&2
                     return "$E2E_RC_TOOL" ;;
        ''|*[!0-9]*) printf 'HTTP durumu okunamadı: %s\n' "$out" >&2; return "$E2E_RC_TOOL" ;;
        *)           printf 'Grafana HTTP %s: %s\n' "$code" "$(http_body_of "$out")" >&2; return 1 ;;
    esac
}
precheck_monitoring() {
    local c
    _gf_pick && return 0
    c="$(primary_container monitoring)"
    if [ -n "$c" ] && ! exec_alive "$c"; then
        printf '%s' "'$c' container'ında docker exec çalışmıyor — curl var mı yok mu ÖLÇEMEDİK"
        return 2
    fi
    printf '%s' "ne grafana ne de gateway container'ında curl var — Grafana API'sine istek atılamıyor"
    return 1
}
write_monitoring() {
    local out code body
    out="$(_gf POST /api/folders "{\"title\":\"${TAG_SNAKE}_$TOKEN\"}")" || return $?
    code="$(http_code_of "$out")"; body="$(http_body_of "$out")"
    case "$code" in
        2*) case "$body" in *'"uid"'*) return 0 ;; esac
            printf 'Grafana HTTP %s döndü ama cevapta uid yok: %s\n' "$code" "$body" >&2; return 1 ;;
        401|403)     printf 'Grafana kimlik doğrulamayı reddetti (HTTP %s)\n' "$code" >&2; return "$E2E_RC_TOOL" ;;
        ''|*[!0-9]*) printf 'HTTP durumu okunamadı: %s\n' "$out" >&2; return "$E2E_RC_TOOL" ;;
        *)           printf 'Grafana HTTP %s: %s\n' "$code" "$body" >&2; return 1 ;;
    esac
}
read_monitoring() {
    local out code body val prc
    out="$(_gf GET /api/folders)" || return $?
    code="$(http_code_of "$out")"; body="$(http_body_of "$out")"
    case "$code" in
        2*) ;;
        401|403)     printf 'Grafana kimlik doğrulamayı reddetti (HTTP %s)\n' "$code" >&2; return "$E2E_RC_TOOL" ;;
        ''|*[!0-9]*) printf 'HTTP durumu okunamadı: %s\n' "$out" >&2; return "$E2E_RC_TOOL" ;;
        *)           printf 'Grafana HTTP %s: %s\n' "$code" "$body" >&2; return "$E2E_RC_TOOL" ;;
    esac
    # Önce TAM eşleşme (bu turun token'ı), yoksa artık bir klasörün değeri —
    # hata satırında hangi eski değerin bulunduğu görünsün diye.
    val="$(printf '%s' "$body" | python3 -c 'import json,sys
pre  = sys.argv[1] + "_"
want = pre + sys.argv[2]
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if not isinstance(rows, list):
    sys.exit(3)
titles = [f.get("title", "") for f in rows if isinstance(f, dict)]
if want in titles:
    print(sys.argv[2]); raise SystemExit(0)
for t in titles:
    if t.startswith(pre):
        print(t[len(pre):]); raise SystemExit(0)
print("")' "$TAG_SNAKE" "$TOKEN")"; prc=$?
    [ "$prc" -eq 0 ] || { printf 'Grafana cevabı beklenen JSON listesi değil: %s\n' "$body" >&2; return "$E2E_RC_TOOL"; }
    printf '%s' "$val"
    return 0
}
clean_monitoring() {
    local uid out body rc=0 prc
    out="$(_gf GET /api/folders)" || return $?
    body="$(http_body_of "$out")"
    case "$(http_code_of "$out")" in 2*) ;; *) return "$E2E_RC_TOOL" ;; esac
    for uid in $(printf '%s' "$body" | python3 -c 'import json,sys
pre = sys.argv[1] + "_"
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for f in (rows if isinstance(rows, list) else []):
    if isinstance(f, dict) and f.get("title","").startswith(pre) and f.get("uid"):
        print(f["uid"])' "$TAG_SNAKE"); do
        _gf DELETE "/api/folders/$uid" >/dev/null 2>&1 || rc=1
    done
    return "$rc"
}

# =============================================================================
# AÇ / KAPAT — ürünün gerçek arayüzü üzerinden
# =============================================================================
# Doğrudan `docker compose up` DEMİYORUZ. Aktivasyonu controller yapar: host
# RAM'ini ölçer, motorun bütçeye sığıp sığmadığına karar verir, tuning.env'i
# yazar. Elle compose çağırmak bu hesabı atlar ve testi kullanıcının gerçekte
# kullandığı yoldan uzaklaştırırdı. Kapatmada da fark var: controller `stop`
# üstüne `rm -f` yapar — container SİLİNİR. Asıl ölçmek istediğimiz de budur.
#
# ACT_KIND, sonucun HANGİ sonuç türüne düşeceğini söyler:
#   ok        komut başarılı
#   kapasite  controller AÇIKÇA reddetti (yer yok / önkoşul yok) → ATLANDI;
#             bu sunucunun kapasitesidir, üründe arıza değildir
#   hata      komut başarısız → ürün tarafında arıza → KALDI
#   olcum     komut hiç bitmedi / çalıştırılamadı → ÖLÇÜLEMEDİ
ACT_ERR=""; ACT_KIND=""
stack_act() {   # stack_act enable|disable <motor>
    local action="$1" eid="$2" out rc logf
    ACT_ERR=""; ACT_KIND="hata"; logf="$WORK/${action}_${eid}.log"
    out="$(timeout "$ACT_TIMEOUT" ./stack.sh "$action" "$eid" 2>&1)"; rc=$?
    printf '%s\n' "$out" > "$logf"
    if [ "$rc" -eq 0 ]; then ACT_KIND="ok"; return 0; fi

    if [ "$rc" -eq 124 ]; then
        ACT_KIND="olcum"
        ACT_ERR="'./stack.sh $action $eid' $ACT_TIMEOUT sn içinde BİTMEDİ; controller işi hâlâ sürüyor olabilir — sonucu bilmiyoruz (./stack.sh events · tam çıktı: $logf)"
        return 1
    fi
    if [ "$rc" -ge 125 ] && [ "$rc" -le 127 ]; then
        ACT_KIND="olcum"
        ACT_ERR="'./stack.sh' çalıştırılamadı (çıkış $rc) — bu ÜRÜN değil ÖLÇÜM ARACI arızası (tam çıktı: $logf)"
        return 1
    fi

    # Controller'ın kendi gerekçesi ("REDDEDİLDİ: … yer yok", "ÖNKOŞUL
    # SAĞLANMADI: …") kullanıcı için en yararlı satırdır; onu öne çıkarıyoruz.
    ACT_ERR="$(printf '%s\n' "$out" | grep -aE 'Başarısız|REDDEDİLDİ|ÖNKOŞUL|YER YOK|yetersiz|çalışmıyor' \
               | tail -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$ACT_ERR" ] || ACT_ERR="$(printf '%s\n' "$out" | grep -av '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//')"
    # stack.sh'in kendi işaretlerini ("[✗] Başarısız: ") söküyoruz; okunan
    # şey bizim raporumuzun içinde bir CÜMLE, ikinci bir hata satırı değil.
    ACT_ERR="$(printf '%s' "$ACT_ERR" | sed -e 's/^\[[^]]*\][[:space:]]*//' -e 's/^Başarısız:[[:space:]]*//')"
    [ -n "$ACT_ERR" ] || ACT_ERR="çıkış kodu $rc"
    ACT_ERR="$ACT_ERR — tam çıktı: $logf"

    # KAPASİTE mi ARIZA mı? controller/app.py: do_activate yer yoksa
    # "REDDEDİLDİ:", önkoşul eksikse "ÖNKOŞUL SAĞLANMADI:" yazar. Yalnız bu iki
    # gerekçe meşru bir ATLAMA sebebidir; başka her başarısızlık üründe arızadır
    # ve "atlandı" diye yumuşatılamaz.
    case "$out" in
        *REDDEDİLDİ*|*"ÖNKOŞUL SAĞLANMADI"*|*"YER YOK"*) ACT_KIND="kapasite" ;;
        *) ACT_KIND="hata" ;;
    esac
    return 1
}

# Hazır olma beklemesi: motorun KENDİ istemcisiyle gerçek bir sorgu çalışana
# kadar. "container running" yetmez — MariaDB açılırken saniyelerce bağlantı
# reddeder, Cassandra dakikalarca.
#
# DUVAR SAATİYLE ölçülüyor. Eski hâli yalnız UYKULARI topluyordu; probe'un
# kendisi DEX_TIMEOUT'a (vars. 90 sn) kadar bloklayabildiği için ilan edilen üst
# sınır gerçekte katlarına çıkıyordu (denetimde ölçüldü: 10 sn'lik sınır 27 sn
# sürdü; cassandra varsayılanıyla en kötü hâl saatlere gidiyordu). Ayrıca her
# probe'un kendi üst sınırını KALAN süreyle kısıtlıyoruz — yoksa son probe tek
# başına sınırı 90 sn aşardı.
# WAIT_LAST_RC: son probe denemesinin ÇIKIŞ KODU. Çağıran bunu okuyor, çünkü
# "motor 180 sn içinde cevap vermedi" ile "docker exec hiç çalışmadı" aynı
# ekranda aynı satırı yazamaz — ikincisi ölçüm arızasıdır.
WAIT_LAST_RC=0
wait_ready() {   # wait_ready <motor> <üst sınır sn>
    local eid="$1" limit="$2" step=5
    local basla gecen kalan sav rc next_log=30 sonuc=1
    WAIT_LAST_RC=0
    basla="$(date +%s)"; sav="$DEX_TIMEOUT"
    while :; do
        gecen=$(( $(date +%s) - basla ))
        kalan=$(( limit - gecen ))
        if [ "$kalan" -le 0 ]; then sonuc=1; break; fi
        DEX_TIMEOUT=$(( kalan < sav ? kalan : sav ))
        [ "$DEX_TIMEOUT" -lt 1 ] && DEX_TIMEOUT=1
        "probe_$eid"; rc=$?
        DEX_TIMEOUT="$sav"; WAIT_LAST_RC="$rc"
        if [ "$rc" -eq 0 ]; then sonuc=0; break; fi
        gecen=$(( $(date +%s) - basla ))
        if [ "$gecen" -ge "$limit" ]; then sonuc=1; break; fi
        if [ "$gecen" -ge "$next_log" ]; then
            log "   … $eid hazır değil, bekleniyor (${gecen}/${limit} sn) — durum: $(health_note "$(primary_container "$eid")")"
            next_log=$(( gecen + 30 ))
        fi
        sleep "$step"
    done
    DEX_TIMEOUT="$sav"
    return "$sonuc"
}

# Testten önce kapalı olan motor testten sonra da kapalı kalmalı: aksi hâlde bu
# betiği çalıştırmak sunucunun bellek tablosunu sessizce değiştirirdi.
restore_engine() {   # restore_engine <motor> <testten_önce_açık_mıydı:0|1>
    [ "$2" -eq 1 ] && return 0
    log "$1 testten önce kapalıydı — tekrar kapatılıyor"
    if ! stack_act disable "$1"; then
        warn "$1 tekrar kapatılamadı ($ACT_ERR). Elle: ./stack.sh disable $1"
        LC_KALINTI+=("$1 testten önce KAPALIYDI ama AÇIK kaldı — geri almak için: ./stack.sh disable $1")
    fi
    return 0
}

# Kendi yazdığımızı sil; başarısızlığı YUTMA. Denetim bulgusu: temizlik
# `>/dev/null 2>&1` ile çağrılıyordu, hem çıktısı hem çıkış kodu kayboluyordu.
temizle() {   # temizle <motor> <"once"|"sonra">
    local eid="$1" ne="$2" rc
    "clean_$eid" >"$WORK/clean_${ne}_$eid.log" 2>&1; rc=$?
    return "$rc"
}

skip_rest() {   # skip_rest "<sebep>" <kontrol adı...>
    local why="$1" n; shift
    for n in "$@"; do t_skip "$n" "$why"; done
}

# =============================================================================
# BİR MOTORUN TAM DÖNGÜSÜ
# =============================================================================
run_engine() {
    local eid="$1" ename prim was_up=1 ready_to cl why rc st f eksik=""
    local C1 C2 C3 C4
    local pre_not="" got="" got2="" wrc rrc cid_before="" cid_after="" crc arc
    ename="$(cat_field "$eid" 2)"
    heading "── $eid — ${ename:-(katalogda ad yok)} ──"

    cl="$(client_of "$eid")$(port_note "$eid")"
    C1="$eid: açıldıktan sonra $cl ile sorguya cevap veriyor"
    C2="$eid: probe kaydı yazıldı ve aynı bağlantıdan geri okundu"
    C3="$eid: ./stack.sh disable container'ı gerçekten kaldırdı"
    C4="$eid: kapatılıp yeniden açıldıktan sonra yazılan kayıt yerinde"

    # Katalogda olup bu betikte istemcisi tanımlı olmayan bir motor SESSİZCE
    # geçilmemeli: kataloğa yeni bir motor eklendiğinde test onu "geçti"
    # saymasın, "ölçmedim" desin. DÖRT fonksiyonun da olması şart — yalnız
    # probe eklenmişse write_x çağrısı "command not found" (127) verir ve bu,
    # C2'de "veri yazılamadı" gibi görünürdü.
    for f in probe write read clean; do
        declare -F "${f}_$eid" >/dev/null 2>&1 || eksik="$eksik ${f}_$eid"
    done
    if [ -n "$eksik" ]; then
        why="bu betikte $eid için istemci eksik (yok:$eksik); lifecycle.sh'e ekleyin"
        skip_rest "$why" "$C1" "$C2" "$C3" "$C4"
        return 0
    fi

    prim="$(primary_container "$eid")"
    if [ -z "$prim" ]; then
        why="katalogda $eid için primary_service boş — hangi container'a bakacağımızı bilmiyoruz"
        t_unknown "$C1" "$why"
        skip_rest "C1 ölçülemedi: $why" "$C2" "$C3" "$C4"
        return 0
    fi
    ready_to="$(ready_timeout "$eid")"

    eng_up "$eid"; rc=$?
    case "$rc" in
        0) was_up=1 ;;
        1) was_up=0 ;;
        *) why="docker cevap vermedi ('docker ps' düştü) — motorun açık olup olmadığını bile okuyamadık"
           t_unknown "$C1" "$why"
           skip_rest "C1 ölçülemedi: $why" "$C2" "$C3" "$C4"
           return 0 ;;
    esac
    LC_CUR_EID="$eid"; LC_CUR_WAS_UP="$was_up"; LC_CUR_WROTE=0

    # --- 1) motoru aç ------------------------------------------------------
    if [ "$was_up" -eq 0 ]; then
        log "$eid kapalı — açılıyor: ./stack.sh enable $eid (bellek planını controller hesaplar)"
        if ! stack_act enable "$eid"; then
            case "$ACT_KIND" in
                kapasite)
                    # Bellek yetmediyse ya da önkoşul sağlanmadıysa ATLANDI: bu
                    # bir ürün arızası değil, o sunucunun kapasitesidir — ama
                    # sessizce geçmek de olmaz, sebebi yazılır.
                    skip_rest "açılamadı (controller reddetti): $ACT_ERR" "$C1" "$C2" "$C3" "$C4" ;;
                olcum)
                    why="açılış komutunun sonucunu bilmiyoruz: $ACT_ERR"
                    t_unknown "$C1" "$why"
                    skip_rest "C1 ölçülemedi: $why" "$C2" "$C3" "$C4"
                    # Motor testten önce KAPALIYDI ve açma komutunun ne yaptığını
                    # bilmiyoruz — arkamızda açık bir motor bırakmış olabiliriz.
                    LC_KALINTI+=("$eid testten önce kapalıydı; açma komutu bitmedi, motor AÇILMIŞ olabilir — kontrol: ./stack.sh list") ;;
                *)
                    t_fail "$C1" "motor açılamadı: $ACT_ERR"
                    skip_rest "motor açılamadığı için ölçülemedi" "$C2" "$C3" "$C4" ;;
            esac
            return 0
        fi
        prim="$(primary_container "$eid")"
        # "enable başarılı döndü" ile "container ayakta" aynı şey değil.
        eng_up "$eid"; rc=$?
        if [ "$rc" -eq 2 ]; then
            why="docker cevap vermedi — açılıştan sonra container'ın durumu okunamadı"
            t_unknown "$C1" "$why"
            skip_rest "C1 ölçülemedi: $why" "$C2" "$C3" "$C4"
            # Motoru BİZ açtık; ölçemesek de bulduğumuz hâle döndürmeyi deniyoruz.
            restore_engine "$eid" "$was_up"
            return 0
        fi
        if [ "$rc" -ne 0 ]; then
            t_fail "$C1" "'./stack.sh enable $eid' başarılı döndü ama '$prim' çalışmıyor (durum: $(health_note "$prim")). Log: ./stack.sh logs $prim"
            skip_rest "container ayakta olmadığı için ölçülemedi" "$C2" "$C3" "$C4"
            restore_engine "$eid" "$was_up"
            return 0
        fi
    else
        log "$eid zaten açık ($prim) — test sonunda açık bırakılacak"
    fi

    # --- 2) motora özgü ön koşul (istemci ikilisi vb.) --------------------
    # HAZIRLIK BEKLEMESİNDEN ÖNCE: istemci ikilisi yoksa probe zaten hiç
    # çalışamaz ve "180 sn içinde cevap vermedi" diye YANLIŞ bir arıza
    # raporlanırdı. Ön koşulun yokluğu ATLANDI'dır, ölçüm aracının bozukluğu
    # ÖLÇÜLEMEDİ.
    if declare -F "precheck_$eid" >/dev/null 2>&1; then
        why="$("precheck_$eid" 2>>"$WORK/precheck_$eid.log")"; rc=$?
        case "$rc" in
            0) : ;;
            2) t_unknown "$C1" "${why:-ön koşul ölçülemedi}"
               skip_rest "C1 ölçülemedi: ${why:-ön koşul ölçülemedi}" "$C2" "$C3" "$C4"
               restore_engine "$eid" "$was_up"; return 0 ;;
            *) skip_rest "${why:-ön koşul yok (sebep bildirilmedi)}" "$C1" "$C2" "$C3" "$C4"
               restore_engine "$eid" "$was_up"; return 0 ;;
        esac
    fi

    # --- 3) hazır mı? (C1) -------------------------------------------------
    if wait_ready "$eid" "$ready_to"; then
        # Hazırlık probe'u BAZI motorlarda kimlik doğrulamaz (Grafana
        # healthcheck'i, MinIO /minio/health/live). Orada "geçti" demek yanlış
        # parolayla da yeşil yazmak olurdu; o motorlarda C1'i gerçek bir yetkili
        # istemci çağrısıyla ölçüyoruz.
        if declare -F "verify_$eid" >/dev/null 2>&1; then
            "verify_$eid" >/dev/null 2>>"$WORK/verify_$eid.log"; rc=$?
            if [ "$rc" -eq 0 ]; then
                t_ok "$C1"
            elif tool_broke "$rc"; then
                why="$cl çağrısı ölçülemedi: $(rc_note "$rc") — ayrıntı: $WORK/verify_$eid.log"
                t_unknown "$C1" "$why"
                skip_rest "C1 ölçülemedi: $why" "$C2" "$C3" "$C4"
                restore_engine "$eid" "$was_up"; return 0
            else
                t_fail "$C1" "$cl çağrısı hata verdi ($(rc_note "$rc")) — ayrıntı: $WORK/verify_$eid.log"
                skip_rest "istemci cevap vermediği için ölçülemedi" "$C2" "$C3" "$C4"
                restore_engine "$eid" "$was_up"; return 0
            fi
        else
            t_ok "$C1"
        fi
    else
        # Hazır olmadı — ÜRÜN mü ÖLÇÜM mü? Ayrımı container'ın durumundan
        # yapıyoruz: docker cevap vermiyorsa hiçbir şey ölçmedik.
        st="$(container_state "$prim")"; rc=$?
        if [ "$rc" -eq 2 ]; then
            why="docker cevap vermedi ($st) — motorun hazır olup olmadığı ölçülemedi"
            t_unknown "$C1" "$why"
            skip_rest "C1 ölçülemedi: $why" "$C2" "$C3" "$C4"
        elif tool_broke "$WAIT_LAST_RC"; then
            # Container ayakta ama SORGUYU HİÇ ÇALIŞTIRAMADIK (docker exec
            # düştü, istemci yok, timeout). Bunu "motor cevap vermedi" diye
            # yazmak, ölçüm arızasını ürün arızası gibi göstermek olurdu.
            why="hazırlık sorgusu çalıştırılamadı: $(rc_note "$WAIT_LAST_RC") (container durumu: $st)"
            t_unknown "$C1" "$why"
            skip_rest "C1 ölçülemedi: $why" "$C2" "$C3" "$C4"
        elif [ "$rc" -eq 1 ]; then
            t_fail "$C1" "'$prim' container'ı YOK — açılış sırasında silinmiş ya da hiç yaratılmamış"
            skip_rest "motor hazır olmadığı için ölçülemedi" "$C2" "$C3" "$C4"
        else
            t_fail "$C1" "$ready_to sn içinde sorguya cevap vermedi (durum: $st). Log: ./stack.sh logs $prim"
            skip_rest "motor hazır olmadığı için ölçülemedi" "$C2" "$C3" "$C4"
        fi
        restore_engine "$eid" "$was_up"
        return 0
    fi

    # --- 4) yaz ve hemen geri oku (C2) ------------------------------------
    # Önce artık temizliği: yarıda kesilmiş bir önceki çalıştırmadan kalan kayıt
    # bu turun okumasını kirletmesin (betik iki kez üst üste çalıştırılabilir).
    # Bu temizliğin BAŞARISIZLIĞI bir VERDİKT değil NOT'tur: ilk koşuda silinecek
    # nesne zaten yoktur ve çoğu istemci bunu hata sayar. Ama sessizce yutmuyoruz
    # — C2 düşerse gerekçeye ekleniyor, çünkü o durumda okuduğumuz şey eski bir
    # artık olabilir.
    temizle "$eid" once; rc=$?
    # `if ! temizle …; then rc=$?` YAZILAMAZ: orada $? `!` işlecinin kodudur (0),
    # komutunki değil — hata satırına "çıkış kodu 0" düşerdi.
    if [ "$rc" -ne 0 ]; then
        pre_not=" · NOT: yazmadan önceki temizlik başarısız ($(rc_note "$rc")); okunan değer önceki koşudan kalmış olabilir — $WORK/clean_once_$eid.log"
        t_info "$eid: yazmadan önceki temizlik başarısız oldu ($(rc_note "$rc")) — ilk koşuda normaldir, ayrıntı: $WORK/clean_once_$eid.log"
    fi

    "write_$eid" >"$WORK/write_$eid.log" 2>&1; wrc=$?
    if [ "$wrc" -ne 0 ]; then
        if tool_broke "$wrc"; then
            t_unknown "$C2" "yazma DENENEMEDİ: $(rc_note "$wrc") — istemci çıktısı: $WORK/write_$eid.log$pre_not"
        else
            t_fail "$C2" "istemci probe kaydını yazamadı ($(rc_note "$wrc")) — istemci çıktısı: $WORK/write_$eid.log$pre_not"
        fi
        skip_rest "probe kaydı yazılamadığı için kalıcılık ölçülemez" "$C3" "$C4"
        temizle "$eid" sonra >/dev/null 2>&1
        restore_engine "$eid" "$was_up"
        return 0
    fi
    LC_CUR_WROTE=1

    got="$("read_$eid" 2>"$WORK/read_$eid.log")"; rrc=$?
    got="$(printf '%s' "$got" | tr -d '\r' | head -1 | tr -d '[:space:]')"
    if tool_broke "$rrc"; then
        t_unknown "$C2" "geri okuma YAPILAMADI: $(rc_note "$rrc") — kayıt var mı yok mu bilmiyoruz ($WORK/read_$eid.log)$pre_not"
        skip_rest "C2 ölçülemedi" "$C3" "$C4"
        temizle "$eid" sonra >/dev/null 2>&1
        restore_engine "$eid" "$was_up"
        return 0
    fi
    if [ "$got" != "$TOKEN" ]; then
        if [ "$rrc" -ne 0 ]; then
            t_fail "$C2" "yazma başarılı göründü ama geri okuma hata verdi ($(rc_note "$rrc")) — $WORK/read_$eid.log$pre_not"
        else
            t_fail "$C2" "beklenen '$TOKEN', gelen '${got:-<boş>}' — istemci çıktısı: $WORK/write_$eid.log$pre_not"
        fi
        skip_rest "veri yazılıp okunamadığı için kalıcılık ölçülemez" "$C3" "$C4"
        temizle "$eid" sonra >/dev/null 2>&1
        restore_engine "$eid" "$was_up"
        return 0
    fi
    t_ok "$C2"

    # --- 5) kapat (C3) -----------------------------------------------------
    # Kimliği KAPATMADAN ÖNCE alıyoruz; C4'ün "container yeniden yaratıldı"
    # şartı buna dayanır. Okunamazsa bunu C4'e taşıyoruz — şartın sessizce
    # devre dışı kalması, kapanmamış bir motordan okunan veriyi GEÇTİ yapardı.
    cid_before="$(cid_of "$prim")"; crc=$?
    log "$eid kapatılıyor: ./stack.sh disable $eid"
    if ! stack_act disable "$eid"; then
        if [ "$ACT_KIND" = "olcum" ]; then
            t_unknown "$C3" "kapatma komutunun sonucu bilinmiyor: $ACT_ERR"
            skip_rest "kapatmanın gerçekleşip gerçekleşmediği bilinmediği için ölçülemedi" "$C4"
        else
            t_fail "$C3" "kapatılamadı: $ACT_ERR"
            skip_rest "motor kapanmadığı için kalıcılık ölçülemedi" "$C4"
        fi
        temizle "$eid" sonra >/dev/null 2>&1
        restore_engine "$eid" "$was_up"
        return 0
    fi

    # C3'ün iddiası "KALDIRDI" — yalnız "docker ps'te yok" bunu kanıtlamaz.
    # controller `stop` üstüne `rm -f` çalıştırır (do_deactivate) ve rm'in
    # çıkış kodunu kontrol ETMEZ: durdurulup silinmemiş bir container işi
    # "başarılı" gösterir. Tam olarak onu arıyoruz.
    st="$(container_state "$prim")"; rc=$?
    case "$rc" in
        1) t_ok "$C3" ;;
        0) if [ "$st" = "running" ]; then
               t_fail "$C3" "'$prim' hâlâ çalışıyor (durum: $st) — kapatma gerçekleşmemiş"
           else
               t_fail "$C3" "'$prim' silinmemiş, yalnız durdurulmuş (durum: $st) — controller 'compose rm -f' de çalıştırır; bu adım düşerse yeniden açılışta AYNI container geri gelir ve verinin volume'dan geldiği hiç sınanmaz"
           fi ;;
        *) t_unknown "$C3" "docker cevap vermedi ($st) — container'ın kaldırılıp kaldırılmadığı ölçülemedi" ;;
    esac

    # --- 6) tekrar aç ve veriyi ara (C4) ----------------------------------
    log "$eid yeniden açılıyor: ./stack.sh enable $eid"
    if ! stack_act enable "$eid"; then
        if [ "$ACT_KIND" = "olcum" ]; then
            t_unknown "$C4" "kapattıktan sonra yeniden açma komutunun sonucu bilinmiyor: $ACT_ERR — motorun durumunu './stack.sh list' ile kontrol edin"
        else
            t_fail "$C4" "kapatıldıktan sonra TEKRAR AÇILAMADI: $ACT_ERR"
        fi
        LC_KALINTI+=("$eid kapatıldı ama tekrar AÇILAMADI — './stack.sh enable $eid' ile açın ve içeride kalan '$TAG_SNAKE' probe kaydını elle silin (değer $TOKEN)")
        return 0
    fi
    prim="$(primary_container "$eid")"
    if ! wait_ready "$eid" "$ready_to"; then
        st="$(container_state "$prim")"; rc=$?
        if [ "$rc" -eq 2 ]; then
            t_unknown "$C4" "yeniden açıldıktan sonra docker cevap vermedi ($st) — veri yerinde mi ölçülemedi"
        elif tool_broke "$WAIT_LAST_RC"; then
            t_unknown "$C4" "yeniden açıldı ama hazırlık sorgusu çalıştırılamadı: $(rc_note "$WAIT_LAST_RC") (container durumu: $st) — veri duruyor mu bilmiyoruz"
        else
            t_fail "$C4" "yeniden açıldı ama $ready_to sn içinde sorguya cevap vermedi (durum: $st). Log: ./stack.sh logs $prim"
        fi
        restore_engine "$eid" "$was_up"
        return 0
    fi

    cid_after="$(cid_of "$prim")"; arc=$?
    got2="$("read_$eid" 2>"$WORK/read2_$eid.log")"; rrc=$?
    got2="$(printf '%s' "$got2" | tr -d '\r' | head -1 | tr -d '[:space:]')"

    if [ "$crc" -ne 0 ] || [ -z "$cid_before" ]; then
        # Denetim bulgusu: bu şart eskiden `[ -n "$cid_before" ] && …` ile
        # sessizce devre dışı kalıyor, kontrol yalnız token karşılaştırmasına
        # düşüyordu. Kapanmamış bir motordan okunan veri hiçbir şey kanıtlamaz.
        t_unknown "$C4" "kapatmadan ÖNCE container kimliği okunamadı (docker inspect '$prim' düştü) — 'container yeniden yaratıldı' şartı doğrulanamıyor, veri duruyor olsa bile kalıcılığı kanıtlamaz"
    elif [ "$arc" -ne 0 ] || [ -z "$cid_after" ]; then
        t_unknown "$C4" "yeniden açılıştan SONRA container kimliği okunamadı (docker inspect '$prim' düştü) — aynı container mı yeni container mı bilmiyoruz"
    elif [ "$cid_before" = "$cid_after" ]; then
        # Aynı container geri geldiyse volume hiç devreye girmemiştir; "veri
        # duruyor" sonucu hiçbir şey kanıtlamaz. Burada GEÇTİ demek testin
        # kendisini yalancı yapardı (asıl arıza zaten C3'te raporlandı).
        t_skip "$C4" "container yeniden yaratılmadı (kimlik $cid_before değişmedi) — kalıcılık ölçülemedi"
    elif tool_broke "$rrc"; then
        t_unknown "$C4" "yeni container'dan ($cid_before → $cid_after) geri okuma YAPILAMADI: $(rc_note "$rrc") — veri duruyor mu bilmiyoruz ($WORK/read2_$eid.log)"
    elif [ "$got2" = "$TOKEN" ]; then
        t_ok "$C4"
        t_info "container $cid_before → $cid_after olarak yeniden yaratıldı; veri volume'dan geldi"
    elif [ "$rrc" -ne 0 ]; then
        t_fail "$C4" "yeni container'da ($cid_before → $cid_after) geri okuma hata verdi ($(rc_note "$rrc")) — $WORK/read2_$eid.log"
    else
        t_fail "$C4" "yeni container'da ($cid_before → $cid_after) beklenen '$TOKEN' yerine '${got2:-<boş>}' geldi — kapatınca veri KAYBOLUYOR; bu motorun volume tanımını ve veri dizinini kontrol edin"
    fi

    # --- 7) kendi verimizi sil --------------------------------------------
    if temizle "$eid" sonra; then
        LC_CUR_WROTE=0
        log "$eid: probe kaydı silindi ($TAG_SNAKE)"
    else
        rc=$?
        warn "$eid: probe kaydı silinemedi ($(rc_note "$rc")) — ayrıntı: $WORK/clean_sonra_$eid.log"
        LC_KALINTI+=("$eid: probe kaydı ('$TAG_SNAKE' / '$TAG_DASH', değer $TOKEN) SİLİNEMEDİ — elle silin")
    fi

    # --- 8) motoru bulduğumuz hâle döndür ---------------------------------
    restore_engine "$eid" "$was_up"
    return 0
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
ENGINES=()
if [ $# -gt 0 ]; then
    for a in "$@"; do
        if all_engine_ids | grep -qx "$a"; then
            ENGINES+=("$a")
        else
            err "Katalogda böyle bir motor yok: $a"
            echo "Geçerli olanlar:" >&2; all_engine_ids | sed 's/^/  /' >&2
            LC_DONE=1
            exit 1
        fi
    done
else
    while IFS= read -r e; do [ -n "$e" ] && ENGINES+=("$e"); done < <(all_engine_ids)
fi
[ "${#ENGINES[@]}" -gt 0 ] || die "Sınanacak motor yok — katalog dökümü boş ($CAT_DUMP)."

heading "$ALAN — ${#ENGINES[@]} katalog kaydı sınanacak"
echo "  Ölçülen iddia : 'motoru kapatınca veriniz silinmez'"
echo "  Yöntem        : aç → yaz → geri oku → KAPAT (container silinir) → aç → veriyi ara → temizle"
echo "  Probe adı     : $TAG_SNAKE / $TAG_DASH   ·   bu turun değeri: $TOKEN"
echo "  Üst sınırlar  : aktivasyon ${ACT_TIMEOUT} sn · istemci komutu ${DEX_TIMEOUT} sn · hazırlık beklemesi duvar saatiyle"
echo

LC_BASLADI=1
for e in "${ENGINES[@]}"; do
    run_engine "$e"
    LC_CUR_EID=""; LC_CUR_WROTE=0
done

# =============================================================================
# SONUÇ
# =============================================================================
# Sayaçlar, özet ve çıkış kodu lib.sh'te: 0 = çalışan kontrollerin hepsi geçti,
# 1 = başarısız/ölçülemedi var, 2 = HİÇBİR kontrol çalışmadı ("ölçmedik", başarı
# değil), 130 = kesildi. Eskiden bu betiğin kendi özeti "0/0 geçti" yazıp ÇIKIŞ
# 0 veriyordu; bütün motorlar atlandığında CI bunu "her şey sağlam" okurdu.
lc_kalinti_yaz
e2e_finish; RC=$?
LC_DONE=1
# Temiz geçtiyse kendi artığımızı da bırakmıyoruz. Başarısız ya da ÖLÇÜLEMEDİ
# varsa günlükler KALIR — yukarıdaki satırlar o dosyaları adıyla gösteriyor.
if [ "$RC" -eq 0 ] && [ "${#LC_KALINTI[@]}" -eq 0 ]; then rm -rf "$WORK"; fi
exit "$RC"
