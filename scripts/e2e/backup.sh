#!/bin/bash
# =============================================================================
# databases-stack — E2E: YEDEKLEME VE GERİ YÜKLEME
# =============================================================================
# Bu betik CANLI bir kuruluma karşı çalışır ve tek bir soruyu cevaplar:
#
#     FELAKET GÜNÜ ELİMİZDEKİ DOSYA VERİYİ GERİ GETİRİYOR MU?
#
# "Container ayakta" ya da "yedek dosyası üretildi" bu sorunun cevabı DEĞİLDİR.
# Bir yedeğin geçerliliği ancak GERİ YÜKLENİP verinin geldiği görülünce
# kanıtlanır. Bu yüzden yedeklenebilen her motor için şu tur koşuluyor:
#
#     veri yaz → yedek al → verify → VERİYİ SİL → geri yükle → veriyi geri oku
#
# Asıl kanıt son adımdır; öncekiler yalnızca onun ön koşuludur. Ayrıca ürünün
# geçmişte GERÇEKTEN yaşadığı arızalar için negatif testler var: kesik dosyaya
# "doğrulandı" demek, yabancı dosyayla geri yükleyip veriyi silmek ve bir
# motorun yedeği patlayınca bütün turun ortasından kesilmesi.
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/backup.sh                  tüm motorlar + negatif testler
#     ./scripts/e2e/backup.sh mariadb redis    yalnız bu motorlar
#
# Ayarlar (ortam değişkeni):
#     E2E_GERI_YUKLEME=0    yıkıcı adımı atla (yalnız yedek al + doğrula)
#     E2E_NEO4J_OFFLINE=1   Neo4j'yi DURDURUP yedekle (Community'de tek yol)
#     E2E_TUR=0             "bir motor patlarsa tur ölüyor mu" testini atla
#     E2E_YEDEKLERI_KORU=1  testin ürettiği yedek dosyalarını silme
#     E2E_YEDEK_SURESI / E2E_GERI_SURESI / E2E_TUR_SURESI / …  zaman aşımı (sn)
#
# ⚠ YIKICI ADIM: geri yükleme, o motorun verisini YEDEK ANINA döndürür. Test
#   yedeği turun hemen başında aldığı için normal şartlarda kayıp olmaz; ama
#   test sürerken BAŞKASI veri yazarsa o yazma geri yüklemeyle kaybolur.
#   Üretimde bakım penceresinde çalıştırın ya da E2E_GERI_YUKLEME=0 verin.
#   (Redis ve Neo4j adımları ilgili container'ı kısa süreliğine durdurur.)
#
# set -e YOK: her kontrol tek tek raporlanmalı. İlk hatada ölen bir test,
# asıl bilgiyi (hangi motorun geri yüklenemediğini) hiç göstermez.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
PROJE="${STACK_PROJECT:-databases-stack}"

# --------------------------------------------------------------- sayaçlar ---
GECEN=0; DUSEN=0; ATLANAN=0
DUSEN_ADLAR=""

t_ok()   { GECEN=$((GECEN+1)); printf '  %s[GEÇTİ]%s   %s\n' "$GREEN" "$NC" "$1"; }
t_fail() { DUSEN=$((DUSEN+1))
           printf '  %s[DÜŞTÜ]%s   %s\n              → %s\n' "$RED" "$NC" "$1" "${2:-ayrıntı yok}" >&2
           DUSEN_ADLAR="$DUSEN_ADLAR  - $1"$'\n'; }
# ATLAMA da raporlanır. Sessizce atlanan test "geçti" sanılır; bir yedekleme
# ürününde bunun bedeli, kurtarma noktası olmadığını felaket günü öğrenmektir.
t_skip() { ATLANAN=$((ATLANAN+1))
           printf '  %s[ATLANDI]%s %s\n              → %s\n' "$YELLOW" "$NC" "$1" "${2:-sebep yok}"; }

# ------------------------------------------------------------ zaman aşımı ---
# Hiçbir bekleme sonsuz değil. `timeout` yoksa komutlar yine çalışır ama bunu
# kullanıcıya SÖYLÜYORUZ: askıda kalmış bir teste "sürüyor" demek, testin
# çöktüğünü hiç görmemekten beterdir.
ZAMAN=()
if command -v timeout >/dev/null 2>&1; then ZAMAN=(timeout -k 10); fi

SURE_YEDEK="${E2E_YEDEK_SURESI:-900}"      # tek motorun tam yedeği
SURE_GERI="${E2E_GERI_SURESI:-900}"        # tek motorun geri yüklenmesi
SURE_DOGRULA="${E2E_DOGRULA_SURESI:-300}"  # verify (arşivi baştan sona okur)
SURE_TUR="${E2E_TUR_SURESI:-2400}"         # `backup all` turu
SURE_ISTEMCI="${E2E_ISTEMCI_SURESI:-60}"   # tek sorgu / istemci çağrısı
SURE_OKUMA="${E2E_OKUMA_SURESI:-180}"      # geri yükleme sonrası veriyi bekleme

zaman_asimi() {   # zaman_asimi <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}

# --------------------------------------------------------- geçici alan/log --
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-yedek-XXXXXX")" || die "Geçici dizin açılamadı."
SON_CIKTI="$E2E_TMP/son.out"
: > "$SON_CIKTI"
mkdir -p "$LOG_DIR"
E2E_LOG="$LOG_DIR/e2e-backup_$(date +%Y%m%d_%H%M%S).log"
: > "$E2E_LOG"

# Çalıştırılan her ürün komutunun tam çıktısı log'a gider; ekranda yalnız
# kontrol satırları kalır. Son komutun çıktısı ayrıca SON_CIKTI'da durur —
# hata ayrıntısını oradan alıp DÜŞTÜ satırına yazıyoruz, böylece kullanıcı
# log dosyasını açmadan da ne olduğunu görür.
# stdin /dev/null: backup.sh'ın geri yükleme onayı (`read`) terminal olmayan
# bir ortamda bizi sonsuza kadar bekletmesin.
calistir() {   # calistir <saniye> <açıklama> <komut…>
    local sn="$1" ne="$2"; shift 2
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$ne"
      printf 'komut: %s\n' "$*"; } >> "$E2E_LOG"
    local rc=0
    zaman_asimi "$sn" "$@" > "$SON_CIKTI" 2>&1 < /dev/null || rc=$?
    cat "$SON_CIKTI" >> "$E2E_LOG"
    [ "$rc" -eq 124 ] && printf '(ZAMAN AŞIMI: %s sn)\n' "$sn" >> "$E2E_LOG"
    printf '(çıkış kodu: %s)\n' "$rc" >> "$E2E_LOG"
    return "$rc"
}
# Kasten bozuk dosyalarla yapılan çağrılar için: backup.sh'ın kendi günlüğünü
# GEÇİCİ dizine yönlendirir. Yoksa "Yedeğin İÇİ BOŞ: mariadb_full_e2e-bos…"
# gibi satırlar logs/backup_<tarih>.log dosyasına düşer ve ertesi sabah gece
# yedeğini inceleyen operatör, testin ürettiği sahte alarmları gerçek sanır.
# Gerçek motor yedekleri BİLEREK bunun dışında: onların günlüğü ürünün kendi
# yerinde kalmalı.
calistir_izole() {
    ( export LOG_DIR="$E2E_TMP"; calistir "$@" )
}
son_ozet() {   # DÜŞTÜ satırına yazılacak kısa ayrıntı
    local s
    s="$(tr -d '\r' < "$SON_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 2 | tr '\n' ' ')"
    printf '%s' "${s:-çıktı yok}"
}
son_icerir() { grep -aqF "$1" "$SON_CIKTI" 2>/dev/null; }

# Kilit çakışması ÜRÜN HATASI DEĞİLDİR: gece yedeği ya da elle başlatılmış bir
# iş sürüyorsa backup.sh doğru davranıp reddediyor. Bunu DÜŞTÜ saymak, testi
# cron saatlerinde güvenilmez yapardı.
kilit_carpismasi() { son_icerir "kilidi tutuyor"; }

# ----------------------------------------------------------- katalog okuma --
# Motor listesi, uzantılar ve bağlantı bilgileri KATALOGTAN gelir. Burada sabit
# liste tutmak, katalog büyüdüğünde testin yeni motoru sessizce atlaması demek.
yedeklenebilir_motorlar() {
    python3 - "$CATALOG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if (e.get("backup") or {}).get("supported")))
PY
}
yedeklenemez_motorlar() {
    python3 - "$CATALOG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if not (e.get("backup") or {}).get("supported")))
PY
}
motor_bilgi() {   # motor_bilgi <id> → "ext|kullanıcı|veritabanı|parola_env|kind"
    python3 - "$CATALOG" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e:
    sys.exit(1)
e = e[0]
b = e.get("backup") or {}
k = e.get("connection") or {}
print("|".join(str(x or "") for x in
               (b.get("ext"), k.get("username"), k.get("database"),
                k.get("password_env"), b.get("kind"))))
PY
}

# Geri yükleme desteği KATALOGDA YOK; ürünün gerçek arayüzü backup.sh'ın case
# dalıdır. Sabit liste yazmak yerine betiğin kendisine soruyoruz — yarın
# restore-clickhouse eklenirse bu test onu kendiliğinden kapsar.
geri_yukleme_var() {
    grep -qE "^restore_$1\(\)" scripts/backup.sh && grep -qE "restore-$1[|)]" scripts/backup.sh
}

# ------------------------------------------------------ sabit test nesneleri
# Adlar SABİT: yarım kalmış bir koşumdan sonra betik tekrar çalıştırıldığında
# aynı nesneleri bulup üzerine yazar ve sonunda siler (idempotentlik).
# DEĞER her koşumda farklı — geri yüklemeden sonra okunan şeyin gerçekten BU
# koşumun yazdığı kayıt olduğunu ancak böyle kanıtlayabiliriz. Sabit bir değer
# kullansaydık, hiç geri yüklenmemiş eski veri de testi geçirirdi.
E2E_DB="e2e_yedek"
E2E_TABLO="kanit"
E2E_ANAHTAR="kanit"
E2E_ES_INDEKS="e2e-yedek"
E2E_REDIS_ANAHTAR="e2e:yedek:kanit"
E2E_MINIO_KOVA="e2e-yedek"
E2E_RABBIT_POLICY="e2e_kanit"
KANIT="e2e-$(date +%Y%m%d%H%M%S)-$$"

DOKUNULAN=""        # veri yazdığımız motorlar (sonunda temizlenecek)
URETILEN=""         # bu koşumun ürettiği gerçek yedek dosyaları
ILK_GERCEK=""       # negatif testlerde kullanılacak gerçek yedek dosyası

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Host'ta veritabanı istemcisi YOK; her sorgu container'ın içindeki istemciyle
# çalışıyor. Parolalar komut satırına DEĞİL ortama konuyor (host'ta `ps`
# çıktısında görünmesinler) — backup.sh'taki desenin aynısı. Alt kabuk (…)
# şart: export'lar betiğin geri kalanına sızmasın.
my_sql() {   # my_sql <container> <parola> <sql>
    ( export MYSQL_PWD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$3" ) 2>>"$E2E_LOG"
}
pg_sql() {   # pg_sql <container> <parola> <veritabanı> <sql>
    ( export PGPASSWORD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -d "$3" -tAq -c "$4" ) 2>>"$E2E_LOG"
}
mongo_js() { # mongo_js <container> <kullanıcı> <parola> <js>
    ( export MPW="$3" MUSER="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e MPW -e MUSER "$1" sh -c \
          'exec "$1" --quiet -u "$MUSER" -p "$MPW" --authenticationDatabase admin --eval "$2"' \
          sh "${MONGO_SHELL:-mongosh}" "$4" ) 2>>"$E2E_LOG"
}
redis_cli() { # redis_cli <container> <parola> <argümanlar…>
    local c="$1" pw="$2"; shift 2
    ( export REDISCLI_AUTH="$pw"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e REDISCLI_AUTH "$c" \
          redis-cli --no-auth-warning "$@" ) 2>>"$E2E_LOG"
}
ms_sql() {   # ms_sql <container> <parola> <sorgu>
    # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir. Bu olmadan
    # düşen sorgu "başarılı" sanılır (backup.sh'ta da aynı sebeple var).
    ( export SQLCMDPASSWORD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e SQLCMDPASSWORD "$1" \
          /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W \
          -Q "SET NOCOUNT ON; $3" ) 2>>"$E2E_LOG"
}
cql() {      # cql <container> <kullanıcı> <parola> <cql>
    ( export CQLSH_USER="$2" CQLSH_PW="$3"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e CQLSH_USER -e CQLSH_PW "$1" sh -c \
          'exec cqlsh -u "$CQLSH_USER" -p "$CQLSH_PW" -e "$1"' sh "$4" ) 2>>"$E2E_LOG"
}
ch_sql() {   # ch_sql <container> <kullanıcı> <parola> <sql>
    ( export CH_USER="$2" CH_PW="$3"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e CH_USER -e CH_PW "$1" sh -c \
          'exec clickhouse-client --user "$CH_USER" --password "$CH_PW" --query "$1"' sh "$4" ) 2>>"$E2E_LOG"
}
es_istek() { # es_istek <container> <parola> <metod> <yol> [gövde]
    local c="$1" pw="$2" m="$3" yol="$4" govde="${5:-}"
    ( export EPW="$pw"
      if [ -n "$govde" ]; then
          zaman_asimi "$SURE_ISTEMCI" docker exec -e EPW "$c" sh -c \
              'exec curl -sS -u "elastic:$EPW" -X "$1" -H "Content-Type: application/json" -d "$3" "http://localhost:9200$2"' \
              sh "$m" "$yol" "$govde"
      else
          zaman_asimi "$SURE_ISTEMCI" docker exec -e EPW "$c" sh -c \
              'exec curl -sS -u "elastic:$EPW" -X "$1" "http://localhost:9200$2"' \
              sh "$m" "$yol"
      fi ) 2>>"$E2E_LOG"
}
neo_cypher() { # neo_cypher <container> <parola> <cypher>
    ( export NPW="$2" NUSER="${NEO4J_USER:-neo4j}"
      printf '%s\n' "$3" | zaman_asimi "$SURE_ISTEMCI" docker exec -i -e NPW -e NUSER "$1" sh -c \
          'exec cypher-shell -u "$NUSER" -p "$NPW" --format plain' ) 2>>"$E2E_LOG"
}
rabbit_ctl() { # rabbit_ctl <container> <argümanlar…>
    local c="$1"; shift
    zaman_asimi "$SURE_ISTEMCI" docker exec "$c" rabbitmqctl "$@" 2>>"$E2E_LOG"
}

# Motorun parolası: katalogtaki password_env, yoksa DB_PASSWORD — compose'daki
# `${X_PASSWORD:-${DB_PASSWORD}}` zincirinin aynısı.
motor_parolasi() {   # motor_parolasi <parola_env>
    local ad="$1" v=""
    [ -n "$ad" ] && v="${!ad:-}"
    [ -n "$v" ] || v="${DB_PASSWORD:-}"
    printf '%s' "$v"
}
motor_pw() { motor_parolasi "$(motor_bilgi "$1" | cut -d'|' -f4)"; }

# =============================================================================
# VERİ YAZ / OKU / SİL   (motor başına)
# =============================================================================
# veri_yaz     : kanıt kaydını yazar
# veri_oku     : kanıt kaydını basar (yoksa boş) — karşılaştırma KANIT değerini arar
# veri_yikim   : geri yüklemenin gerçekten iş yapması için kaydı SİLER
# veri_temizle : testin bıraktığı her şeyi kaldırır
veri_yaz() {   # veri_yaz <eid> <container> <parola>
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)
            my_sql "$C" "$pw" "CREATE DATABASE IF NOT EXISTS \`$E2E_DB\`;
                CREATE TABLE IF NOT EXISTS \`$E2E_DB\`.\`$E2E_TABLO\`
                    (k VARCHAR(64) PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
                REPLACE INTO \`$E2E_DB\`.\`$E2E_TABLO\` VALUES ('$E2E_ANAHTAR','$KANIT');" >/dev/null
            ;;
        postgresql)
            local var
            var="$(pg_sql "$C" "$pw" postgres "SELECT 1 FROM pg_database WHERE datname='$E2E_DB'")"
            if [ -z "$var" ]; then
                pg_sql "$C" "$pw" postgres "CREATE DATABASE \"$E2E_DB\"" >/dev/null || return 1
            fi
            pg_sql "$C" "$pw" "$E2E_DB" \
                "CREATE TABLE IF NOT EXISTS \"$E2E_TABLO\" (k text PRIMARY KEY, v text);
                 INSERT INTO \"$E2E_TABLO\" VALUES ('$E2E_ANAHTAR','$KANIT')
                 ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" >/dev/null
            ;;
        mongodb)
            mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                "db.getSiblingDB('$E2E_DB').$E2E_TABLO.replaceOne({_id:'$E2E_ANAHTAR'},{_id:'$E2E_ANAHTAR',v:'$KANIT'},{upsert:true})" >/dev/null
            ;;
        redis)
            redis_cli "$C" "$pw" SET "$E2E_REDIS_ANAHTAR" "$KANIT" >/dev/null
            ;;
        mssql)
            # CREATE DATABASE kendi grubunda çalışmalı; aynı batch'te tablo
            # yaratmaya kalkışmak "database does not exist" hatası verir.
            ms_sql "$C" "$pw" "IF DB_ID('$E2E_DB') IS NULL CREATE DATABASE [$E2E_DB];" >/dev/null || return 1
            ms_sql "$C" "$pw" "IF OBJECT_ID('[$E2E_DB].dbo.$E2E_TABLO') IS NULL
                    CREATE TABLE [$E2E_DB].dbo.$E2E_TABLO (k varchar(64) PRIMARY KEY, v varchar(64));
                DELETE FROM [$E2E_DB].dbo.$E2E_TABLO WHERE k='$E2E_ANAHTAR';
                INSERT INTO [$E2E_DB].dbo.$E2E_TABLO VALUES ('$E2E_ANAHTAR','$KANIT');" >/dev/null
            ;;
        cassandra)
            cql "$C" "${CASSANDRA_USER:-cassandra}" "$pw" \
                "CREATE KEYSPACE IF NOT EXISTS $E2E_DB WITH replication={'class':'SimpleStrategy','replication_factor':1};
                 CREATE TABLE IF NOT EXISTS $E2E_DB.$E2E_TABLO (k text PRIMARY KEY, v text);
                 INSERT INTO $E2E_DB.$E2E_TABLO (k,v) VALUES ('$E2E_ANAHTAR','$KANIT');" >/dev/null
            ;;
        elasticsearch)
            # refresh=true: belge yazıldıktan hemen sonra aranabilir olsun —
            # yoksa yedek anında henüz segmente inmemiş olabilir.
            es_istek "$C" "$pw" PUT "/$E2E_ES_INDEKS/_doc/$E2E_ANAHTAR?refresh=true" "{\"v\":\"$KANIT\"}" >/dev/null
            ;;
        clickhouse)
            ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" "CREATE DATABASE IF NOT EXISTS $E2E_DB" >/dev/null || return 1
            ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" \
                "CREATE TABLE IF NOT EXISTS $E2E_DB.$E2E_TABLO (k String, v String) ENGINE=MergeTree ORDER BY k" >/dev/null || return 1
            ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" \
                "INSERT INTO $E2E_DB.$E2E_TABLO VALUES ('$E2E_ANAHTAR','$KANIT')" >/dev/null
            ;;
        rabbitmq)
            # RabbitMQ'da MESAJLAR yedeklenmiyor (ürün bilerek yalnız tanımları
            # alıyor), o yüzden kanıt da bir TANIM olmalı. Policy seçildi çünkü
            # deseni içinde KANIT değerini taşır: hem sunucudan hem de yedek
            # dosyasının içinden bu koşuma ait olduğu doğrulanabilir.
            rabbit_ctl "$C" add_vhost "$E2E_DB" >/dev/null 2>&1
            rabbit_ctl "$C" set_policy -p "$E2E_DB" "$E2E_RABBIT_POLICY" "^$KANIT\$" \
                '{"max-length":1}' --apply-to queues >/dev/null
            ;;
        minio)
            # MinIO imajında kabuk YOK (backup.sh de bu yüzden `docker cp`
            # kullanıyor: arşivi docker'a çıkarttırıyor). Nesneyi de aynı
            # yoldan koyuyoruz — imajın içinde hiçbir araç gerekmiyor.
            mkdir -p "$E2E_TMP/$E2E_MINIO_KOVA"
            printf '%s\n' "$KANIT" > "$E2E_TMP/$E2E_MINIO_KOVA/$E2E_TABLO.txt"
            zaman_asimi "$SURE_ISTEMCI" docker cp "$E2E_TMP/$E2E_MINIO_KOVA" "$C:/data/" >>"$E2E_LOG" 2>&1
            ;;
        neo4j)
            neo_cypher "$C" "$pw" "MERGE (n:E2EKanit {k:'$E2E_ANAHTAR'}) SET n.v='$KANIT';" >/dev/null
            ;;
        *) return 1 ;;
    esac
}

veri_oku() {   # veri_oku <eid> <container> <parola> → kanıt (yoksa boş)
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)    my_sql "$C" "$pw" "SELECT v FROM \`$E2E_DB\`.\`$E2E_TABLO\` WHERE k='$E2E_ANAHTAR';" ;;
        postgresql) pg_sql "$C" "$pw" "$E2E_DB" "SELECT v FROM \"$E2E_TABLO\" WHERE k='$E2E_ANAHTAR'" ;;
        mongodb)    mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                        "var d=db.getSiblingDB('$E2E_DB').$E2E_TABLO.findOne({_id:'$E2E_ANAHTAR'}); print(d?d.v:'')" ;;
        redis)      redis_cli "$C" "$pw" GET "$E2E_REDIS_ANAHTAR" ;;
        mssql)      ms_sql "$C" "$pw" "SELECT v FROM [$E2E_DB].dbo.$E2E_TABLO WHERE k='$E2E_ANAHTAR';" ;;
        cassandra)  cql "$C" "${CASSANDRA_USER:-cassandra}" "$pw" \
                        "SELECT v FROM $E2E_DB.$E2E_TABLO WHERE k='$E2E_ANAHTAR';" ;;
        elasticsearch) es_istek "$C" "$pw" GET "/$E2E_ES_INDEKS/_doc/$E2E_ANAHTAR" ;;
        clickhouse) ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" \
                        "SELECT v FROM $E2E_DB.$E2E_TABLO WHERE k='$E2E_ANAHTAR'" ;;
        rabbitmq)   rabbit_ctl "$C" list_policies -p "$E2E_DB" ;;
        # MinIO'da `docker exec … cat` yapılamaz (imajda kabuk/araç yok);
        # nesneyi docker'ın tar akışından okuyoruz.
        minio)      zaman_asimi "$SURE_ISTEMCI" docker cp \
                        "$C:/data/$E2E_MINIO_KOVA/$E2E_TABLO.txt" - 2>>"$E2E_LOG" | tar -xO 2>/dev/null ;;
        neo4j)      neo_cypher "$C" "$pw" "MATCH (n:E2EKanit {k:'$E2E_ANAHTAR'}) RETURN n.v;" ;;
    esac
}

veri_yikim() { # veri_yikim <eid> <container> <parola> — geri yüklemeye iş çıkar
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)    my_sql "$C" "$pw" "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null ;;
        postgresql) pg_sql "$C" "$pw" postgres "DROP DATABASE IF EXISTS \"$E2E_DB\"" >/dev/null ;;
        mongodb)    mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                        "db.getSiblingDB('$E2E_DB').dropDatabase()" >/dev/null ;;
        redis)      redis_cli "$C" "$pw" DEL "$E2E_REDIS_ANAHTAR" >/dev/null ;;
        # MSSQL'de veritabanını düşürmek yerine SATIRI siliyoruz: RESTORE
        # DATABASE … WITH REPLACE zaten üzerine yazar; kanıt satırının geri
        # gelmesi aynı şeyi ispatlar, üstelik dosya yolu sürprizi olmadan.
        mssql)      ms_sql "$C" "$pw" "DELETE FROM [$E2E_DB].dbo.$E2E_TABLO WHERE k='$E2E_ANAHTAR';" >/dev/null ;;
    esac
}

veri_temizle() { # veri_temizle <eid> <container> <parola>
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)    my_sql "$C" "$pw" "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null 2>&1 ;;
        postgresql) pg_sql "$C" "$pw" postgres "DROP DATABASE IF EXISTS \"$E2E_DB\"" >/dev/null 2>&1 ;;
        mongodb)    mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                        "db.getSiblingDB('$E2E_DB').dropDatabase()" >/dev/null 2>&1 ;;
        redis)      redis_cli "$C" "$pw" DEL "$E2E_REDIS_ANAHTAR" >/dev/null 2>&1 ;;
        mssql)      ms_sql "$C" "$pw" "IF DB_ID('$E2E_DB') IS NOT NULL BEGIN
                        ALTER DATABASE [$E2E_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                        DROP DATABASE [$E2E_DB]; END" >/dev/null 2>&1
                    # Yabancı arşiv testi staging klasörüne dosya bırakmış olabilir.
                    docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*' >/dev/null 2>&1 ;;
        cassandra)  cql "$C" "${CASSANDRA_USER:-cassandra}" "$pw" "DROP KEYSPACE IF EXISTS $E2E_DB;" >/dev/null 2>&1 ;;
        elasticsearch) es_istek "$C" "$pw" DELETE "/$E2E_ES_INDEKS" >/dev/null 2>&1 ;;
        clickhouse) ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" "DROP DATABASE IF EXISTS $E2E_DB" >/dev/null 2>&1 ;;
        rabbitmq)   rabbit_ctl "$C" delete_vhost "$E2E_DB" >/dev/null 2>&1 ;;
        minio)      minio_nesnesini_sil "$C" ;;
        neo4j)      neo_cypher "$C" "$pw" "MATCH (n:E2EKanit) DETACH DELETE n;" >/dev/null 2>&1 ;;
    esac
}

# MinIO'nun volume'undaki test nesnesini silmek için kabuğu olan bir imaj
# gerekiyor. YENİ İMAJ ÇEKMİYORUZ: bu yığın iç ağda çalışır, internet
# olmayabilir — çalışan container'lardan birinin imajını ödünç alıyoruz.
yardimci_imaj() {
    local c img deneme=0
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        [ "$c" = "minio" ] && continue
        [ "$deneme" -ge 5 ] && break
        img="$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)"
        [ -n "$img" ] || continue
        deneme=$((deneme+1))
        if docker run --rm --entrypoint sh "$img" -c 'exit 0' >/dev/null 2>&1; then
            printf '%s' "$img"; return 0
        fi
    done
    return 1
}
minio_nesnesini_sil() {
    local img
    img="$(yardimci_imaj)" || {
        warn "MinIO test nesnesi silinemedi (kabuğu olan imaj yok): /data/$E2E_MINIO_KOVA"; return 1; }
    docker run --rm -v "${PROJE}_minio_data:/d" --entrypoint sh "$img" \
        -c 'rm -rf "/d/$1"' sh "$E2E_MINIO_KOVA" >/dev/null 2>&1 \
        || warn "MinIO test nesnesi silinemedi: /data/$E2E_MINIO_KOVA"
}

# =============================================================================
# TEMİZLİK — betik kendi yarattığı her şeyi geri alır, iki kez üst üste
# çalıştırılabilsin diye. Trap'e bağlı: Ctrl+C'de ve die'da da çalışır.
# =============================================================================
TEMIZLENDI=0
temizle() {
    [ "$TEMIZLENDI" = "1" ] && return 0
    TEMIZLENDI=1
    if [ -n "$DOKUNULAN$URETILEN" ]; then
        heading "Temizlik"
        local eid C f
        for eid in $DOKUNULAN; do
            C="$(primary_of "$eid")"
            if container_running "$C"; then
                veri_temizle "$eid" "$C" "$(motor_pw "$eid")"
                log "  $eid: test verisi kaldırıldı"
            else
                warn "  $eid: container kapalı, test verisi KALDIRILAMADI ($E2E_DB)"
            fi
        done
        if [ "${E2E_YEDEKLERI_KORU:-0}" = "1" ]; then
            [ -n "$URETILEN" ] && log "  testin ürettiği yedek dosyaları korundu (E2E_YEDEKLERI_KORU=1)"
        else
            for f in $URETILEN; do
                [ -f "$f" ] && rm -f "$f" && log "  silindi: $(basename "$f")"
            done
        fi
    fi
    rm -rf "$E2E_TMP"
    # Ön koşulda düşen bir koşum boş bir günlük bırakıyordu; boş dosya bilgi
    # taşımaz, yalnız logs/ dizinini şişirir.
    [ -s "$E2E_LOG" ] || rm -f "$E2E_LOG"
}
trap temizle EXIT INT TERM

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
heading "Ön koşullar"
require_docker
require_cmd python3 flock tar gzip find awk
[ -f "$CATALOG" ] || die "catalog.json bulunamadı: $CATALOG"
[ -f "$ENV_FILE" ] || warn ".env yok ($ENV_FILE) — parolalar yalnız ortamdan okunacak."
[ -r scripts/backup.sh ] || die "scripts/backup.sh okunamıyor — yığın kökünde miyiz?"
if [ "${#ZAMAN[@]}" -eq 0 ]; then
    warn "'timeout' komutu yok: komutlar zaman aşımı OLMADAN çalışacak (coreutils kurun)."
fi
mkdir -p "$BACKUP_DIR"
# backup.sh 5 GB'ın altında yedek almayı reddeder. Bunu testin hatası gibi
# göstermek yerine önden söyleyip ilgili turları ATLANDI diye raporluyoruz.
DISK_KB="$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
DISK_YETER=1
if [ "${DISK_KB:-0}" -lt 5242880 ]; then
    DISK_YETER=0
    warn "Yedek diskinde 5 GB'dan az boş alan var ($(( ${DISK_KB:-0} / 1024 )) MB); backup.sh yedek almayı reddeder."
fi
ok "Ön koşullar hazır — bu koşumun kanıt değeri: $KANIT"
log "Ayrıntılı komut çıktısı: $E2E_LOG"

# ---------------------------------------------------------- motor seçimi ----
TUM_MOTORLAR="$(yedeklenebilir_motorlar)"
[ -n "$TUM_MOTORLAR" ] || die "Katalogda backup.supported=true olan motor yok."
SECILEN=""
if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        printf '%s\n' "$TUM_MOTORLAR" | grep -qx "$arg" \
            || die "'$arg' yedeklenebilir bir motor değil. Seçenekler: $(printf '%s' "$TUM_MOTORLAR" | tr '\n' ' ')"
        SECILEN="$SECILEN $arg"
    done
else
    SECILEN="$(printf '%s' "$TUM_MOTORLAR" | tr '\n' ' ')"
fi

# =============================================================================
# BİR MOTORUN TAM TURU
# =============================================================================
motor_turu() {
    local eid="$1"
    local bilgi ext pwenv C pw rc=0 okunan dosya isaret

    bilgi="$(motor_bilgi "$eid")"
    ext="$(printf '%s' "$bilgi" | cut -d'|' -f1)"
    pwenv="$(printf '%s' "$bilgi" | cut -d'|' -f4)"
    pw="$(motor_parolasi "$pwenv")"
    # Devirden sonra ana kopya kataloğun varsayılan servisi DEĞİLDİR; sabit ad
    # kullanan bir test durdurulmuş container'a bakıp "kapalı" sanardı.
    C="$(primary_of "$eid")"

    heading "$eid   (container: $C)"

    if ! container_running "$C"; then
        t_skip "$eid: yedek → geri yükleme turu" \
               "motor kapalı ('$C' çalışmıyor). Açmak için: ./stack.sh enable $eid"
        return 0
    fi
    if [ "$DISK_YETER" = "0" ]; then
        t_skip "$eid: yedek → geri yükleme turu" \
               "yedek diskinde 5 GB'dan az yer var; backup.sh zaten reddeder"
        return 0
    fi
    # Neo4j Community'de çevrimiçi yedek YOK: yedek almak motoru DURDURUR.
    # Bunu sormadan yapmak, testin üretimde kesinti yaratması demek olurdu.
    if [ "$eid" = "neo4j" ] && [ "${E2E_NEO4J_OFFLINE:-0}" != "1" ]; then
        t_skip "neo4j: yedek → geri yükleme turu" \
               "Community sürümde yedek almak motoru DURDURUR; kesintiyi göze alıyorsanız: E2E_NEO4J_OFFLINE=1 ./scripts/e2e/backup.sh neo4j"
        return 0
    fi

    # ---- 1. veri yaz ve GERİ OKU -------------------------------------------
    # Önce ölçüm aletini sınıyoruz. Yazdığımızı okuyamıyorsak, geri yükleme
    # sonrası "veri yok" demenin anlamı olmaz — suçu yedeğe atardık.
    DOKUNULAN="$DOKUNULAN $eid"
    if ! veri_yaz "$eid" "$C" "$pw"; then
        t_fail "$eid: kanıt kaydı yazıldı ve geri okundu" \
               "veri yazılamadı (parola/yetki?) — ayrıntı: $E2E_LOG"
        return 0
    fi
    okunan="$(veri_oku "$eid" "$C" "$pw")"
    case "$okunan" in
        *"$KANIT"*) t_ok "$eid: kanıt kaydı yazıldı ve geri okundu ($E2E_DB/$E2E_ANAHTAR = $KANIT)" ;;
        *) t_fail "$eid: kanıt kaydı yazıldı ve geri okundu" \
                  "yazıldı ama okunamadı; okunan: '${okunan:-boş}'"
           return 0 ;;
    esac

    # ---- 2. yedek al --------------------------------------------------------
    isaret="$E2E_TMP/isaret.$eid"; : > "$isaret"
    if [ "$eid" = "neo4j" ]; then
        ( export BACKUP_NEO4J_OFFLINE=true
          calistir "$SURE_YEDEK" "backup $eid" ./scripts/backup.sh "$eid" ); rc=$?
    else
        calistir "$SURE_YEDEK" "backup $eid" ./scripts/backup.sh "$eid"; rc=$?
    fi
    if [ "$rc" -ne 0 ] && kilit_carpismasi; then
        t_skip "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti" \
               "başka bir yedekleme/geri yükleme kilidi tutuyor (gece cron'u olabilir); test daha sonra tekrarlanmalı"
        return 0
    fi
    # Üretilen dosyayı `list`/`stats` ile aynı ölçütle (*.gz) arıyoruz ama
    # YALNIZ bu koşumdan sonra oluşanları: yoksa dünkü yedek "yeni alındı"
    # sanılır ve sonuç tamamen sahte olurdu.
    dosya="$(find "$BACKUP_DIR/$eid" -type f -name '*.gz' -newer "$isaret" -printf '%T@\t%p\n' 2>/dev/null \
             | sort -rn | head -1 | cut -f2-)"
    if [ "$rc" -ne 0 ] || [ -z "$dosya" ]; then
        t_fail "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti" \
               "çıkış kodu=$rc, yeni dosya=${dosya:-YOK} — $(son_ozet)"
        return 0
    fi
    URETILEN="$URETILEN $dosya"
    [ -n "$ILK_GERCEK" ] || ILK_GERCEK="$dosya"
    t_ok "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti ($(basename "$dosya"))"

    # ---- 3. dosya adı katalogla uyuşuyor mu --------------------------------
    # Kataloğun backup.ext alanı ürünün ilanıdır; yedeği ARAYAN her araç o
    # uzantıya güvenir. Gerçek dosya başka uzantı taşıyorsa arama sessizce boş
    # döner ve "yedek yok" denir — oysa yedek vardır.
    case "$(basename "$dosya")" in
        *".$ext") t_ok "$eid: üretilen dosyanın uzantısı katalogdaki backup.ext ile aynı (.$ext)" ;;
        *) t_fail "$eid: üretilen dosyanın uzantısı katalogdaki backup.ext ile aynı" \
                  "katalog '.$ext' diyor, üretilen dosya '$(basename "$dosya")'" ;;
    esac

    # ---- 4. verify ----------------------------------------------------------
    if calistir "$SURE_DOGRULA" "verify $eid" ./scripts/backup.sh verify "$dosya"; then
        t_ok "$eid: yedek bütünlük doğrulamasından (verify) geçti"
    else
        t_fail "$eid: yedek bütünlük doğrulamasından (verify) geçti" "$(son_ozet)"
    fi

    # ---- 5. kanıt gerçekten ARŞİVİN İÇİNDE mi ------------------------------
    # Geri yükleme yolu olmayan motorlarda elimizdeki tek içerik kanıtı bu:
    # "dosya doğrulandı" yetmez, az önce yazdığımız nesne arşive girdi mi?
    case "$eid" in
        rabbitmq)
            if gzip -dc "$dosya" 2>>"$E2E_LOG" | grep -qF "$KANIT"; then
                t_ok "rabbitmq: az önce yazılan tanım (policy) yedek dosyasının içinde"
            else
                t_fail "rabbitmq: az önce yazılan tanım (policy) yedek dosyasının içinde" \
                       "tanımlar dışa aktarıldı ama bu koşumun policy'si yok — dosyadan topoloji geri gelmez"
            fi ;;
        minio|cassandra|clickhouse)
            local ara="$E2E_DB"
            [ "$eid" = "minio" ] && ara="$E2E_MINIO_KOVA"
            if gzip -dc "$dosya" 2>>"$E2E_LOG" | tar -tf - 2>/dev/null | grep -qF "$ara"; then
                t_ok "$eid: az önce yazılan '$ara' arşivin içinde (yedek gerçekten veri taşıyor)"
            else
                t_fail "$eid: az önce yazılan '$ara' arşivin içinde" \
                       "arşiv doğrulamayı geçti ama bu koşumun verisi içinde yok"
            fi ;;
        elasticsearch)
            t_skip "elasticsearch: kanıt belgesi arşivin içinde" \
                   "ES arşivinde indeks adları UUID'lidir; içerik ancak geri yüklenerek görülür, ürün restore-elasticsearch sunmuyor (docs/BACKUP.md)" ;;
    esac

    # ---- 6. geri yükleme desteği yoksa ------------------------------------
    if ! geri_yukleme_var "$eid"; then
        # Sessizce geçmiyoruz: hem kanıtlanamadığını SÖYLÜYORUZ hem de betiğin
        # bunu kendisinin de söylediğini doğruluyoruz. Var olmayan bir kurtarma
        # yoluna "başarılı" demek, olmayan bir yedeğe güvenmekle aynı şey.
        t_skip "$eid: silinen verinin yedekten geri geldiği" \
               "ürün bu motor için otomatik geri yükleme sunmuyor (docs/BACKUP.md: elle yapılır)"
        if calistir_izole "$SURE_ISTEMCI" "restore-$eid (desteklenmiyor mu)" ./scripts/backup.sh "restore-$eid" "$dosya"; then
            t_fail "$eid: desteklenmeyen geri yükleme açıkça reddediliyor" \
                   "restore-$eid 0 ile döndü — hiçbir şey yapmadan 'başarılı' demiş olabilir"
        elif son_icerir "otomatik geri yükleme yok"; then
            t_ok "$eid: desteklenmeyen geri yükleme açıkça reddediliyor (sessizce başarılı demiyor)"
        else
            t_fail "$eid: desteklenmeyen geri yükleme açıkça reddediliyor" \
                   "reddetti ama sebebi anlaşılmıyor: $(son_ozet)"
        fi
        return 0
    fi

    if [ "${E2E_GERI_YUKLEME:-1}" = "0" ]; then
        t_skip "$eid: silinen verinin yedekten geri geldiği" \
               "yıkıcı adım kapalı (E2E_GERI_YUKLEME=0) — bu yedeğin geri yüklenebildiği KANITLANMADI"
        return 0
    fi

    # ---- 7. VERİYİ SİL ------------------------------------------------------
    # Silmeyi doğrulamadan geri yüklemek en tehlikeli sahte testtir: veri
    # yerinde kalırsa, geri yükleme hiçbir şey yapmasa bile "geldi" derdik.
    veri_yikim "$eid" "$C" "$pw"
    okunan="$(veri_oku "$eid" "$C" "$pw")"
    case "$okunan" in
        *"$KANIT"*)
            t_fail "$eid: kanıt kaydı silindi (geri yükleme gerçekten iş yapmak zorunda)" \
                   "silme işe yaramadı, kayıt hâlâ duruyor — geri yükleme kanıtı anlamsız olurdu"
            return 0 ;;
        *) t_ok "$eid: kanıt kaydı silindi (geri yükleme gerçekten iş yapmak zorunda)" ;;
    esac

    # ---- 8. geri yükle ------------------------------------------------------
    # ASSUME_YES=yes: confirm_restore'un 'evet' sorusu otomasyonda beklenemez.
    ( export ASSUME_YES=yes
      calistir "$SURE_GERI" "restore-$eid" ./scripts/backup.sh "restore-$eid" "$dosya" ); rc=$?
    if [ "$rc" -eq 0 ]; then
        t_ok "$eid: restore-$eid hata vermeden tamamlandı"
    elif kilit_carpismasi; then
        t_skip "$eid: restore-$eid hata vermeden tamamlandı" "kilit başkasında (gece cron'u olabilir)"
    else
        t_fail "$eid: restore-$eid hata vermeden tamamlandı" "çıkış kodu=$rc — $(son_ozet)"
    fi

    # ---- 9. VERİ GERİ GELDİ Mİ?  (bütün turun sebebi) ----------------------
    # Geri yükleme container'ı yeniden başlatabiliyor (Redis'te tam olarak öyle
    # oluyor), bu yüzden okuma zaman sınırlı bir bekleyişle tekrarlanıyor.
    # Geri yükleme düşmüş olsa bile okuyoruz: "hem başarısız hem veri gitmiş"
    # ile "başarısız ama veri duruyor" bir felakette çok farklı iki durum.
    local bitis=$(( $(date +%s) + SURE_OKUMA )) son=""
    log "  bekleniyor: $eid üzerinde '$E2E_ANAHTAR' kaydının geri gelmesi (en fazla $SURE_OKUMA sn)"
    while :; do
        son="$(veri_oku "$eid" "$C" "$pw")"
        case "$son" in *"$KANIT"*) break ;; esac
        [ "$(date +%s)" -ge "$bitis" ] && break
        sleep 3
    done
    case "$son" in
        *"$KANIT"*) t_ok "$eid: SİLİNEN kanıt kaydı yedekten geri geldi, değeri birebir aynı ($KANIT)" ;;
        *) t_fail "$eid: SİLİNEN kanıt kaydı yedekten geri geldi, değeri birebir aynı" \
                  "$SURE_OKUMA sn beklendi, okunan: '${son:-boş}' — bu dosya bir kurtarma noktası DEĞİL" ;;
    esac
}

# =============================================================================
# NEGATİF TESTLER — hepsi ürünün GERÇEKTEN yaşadığı arızalar
# =============================================================================
# Bir doğrulayıcının değeri, neye "hayır" dediğiyle ölçülür. Aşağıdaki dosyalar
# kasten bozuk; verify hepsini REDDETMELİ. Sonda pozitif kontrol var: her şeye
# "hayır" diyen bir verify de aynı derecede işe yaramaz.
dogrulama_reddetmeli() {   # dogrulama_reddetmeli <kontrol adı> <dosya> <ne olduğu>
    if calistir_izole "$SURE_DOGRULA" "verify $2" ./scripts/backup.sh verify "$2"; then
        t_fail "$1" "$3 — verify bu dosyaya 'doğrulandı' dedi; felaket günü elde boş/yarım veri kalır"
    else
        t_ok "$1"
    fi
}

negatif_testler() {
    heading "Negatif testler — bozuk dosya 'doğrulandı' DEMEMELİ"
    local d="$E2E_TMP"

    # 1) 0 bayt dosya: diskin dolduğu ya da dump'ın hiç başlamadığı hâl.
    : > "$d/mariadb_full_e2e-sifir.sql.gz"
    dogrulama_reddetmeli "0 baytlık yedek dosyası doğrulamayı geçmiyor" \
        "$d/mariadb_full_e2e-sifir.sql.gz" "boş dosya"

    # 2) Geçerli gzip ama İÇİ BOŞ. Boş girdinin gzip'i 20 bayttır ve `gzip -t`
    #    açısından KUSURSUZDUR; eski sürümde bu dosya yeşil tik alıyordu.
    printf '' | gzip -6 > "$d/mariadb_full_e2e-bos.sql.gz"
    dogrulama_reddetmeli "içi boş (geçerli gzip, sıfır satır) dump doğrulamayı geçmiyor" \
        "$d/mariadb_full_e2e-bos.sql.gz" "20 baytlık boş gzip"

    # 3) Yalnız 0 baytlık üye taşıyan arşiv: dosya ADLARI var, veri yok.
    mkdir -p "$d/bos_arsiv"
    : > "$d/bos_arsiv/veritabani.bak"
    tar -czf "$d/mssql_full_e2e-bosarsiv.tar.gz" -C "$d/bos_arsiv" . 2>>"$E2E_LOG"
    dogrulama_reddetmeli "içindeki dosyaların hepsi 0 bayt olan arşiv doğrulamayı geçmiyor" \
        "$d/mssql_full_e2e-bosarsiv.tar.gz" "0 baytlık .bak"

    # 4) Yalnız üstveri taşıyan arşiv: MSSQL geri yüklemesi .bak okur; arşivde
    #    .bak yoksa elde kurtarma noktası değil, klasör vardır.
    mkdir -p "$d/baksiz"
    printf 'yalnizca ustveri\n' > "$d/baksiz/okuma.txt"
    tar -czf "$d/mssql_full_e2e-baksiz.tar.gz" -C "$d/baksiz" . 2>>"$E2E_LOG"
    dogrulama_reddetmeli "içinde .bak olmayan MSSQL arşivi doğrulamayı geçmiyor" \
        "$d/mssql_full_e2e-baksiz.tar.gz" "yalnız üstveri"

    # 5) Kenara alınmış dosya (.bozuk): doğrulamayı geçemediği için karantinaya
    #    alınmış dosyayı operatör elle doğrulayınca ESKİDEN yeşil tik alıyor,
    #    uzantıyı geri alıp o dosyayla geri yüklemeye kalkıyordu.
    printf 'CREATE TABLE t(a int);\n' | gzip -6 > "$d/mariadb_full_e2e.sql.gz.bozuk"
    dogrulama_reddetmeli "kenara alınmış (.bozuk) dosya doğrulamayı geçmiyor" \
        "$d/mariadb_full_e2e.sql.gz.bozuk" "karantinadaki dosya"

    # 6) GERÇEK bir yedeğin KESİLMİŞ hâli. Sentetik dosyalar kaçırılabilir;
    #    asıl korkulan, gerçek bir dump'ın ortasında diskin/borunun ölmesidir.
    #    Kesik dosyanın BAŞI her zaman doğrudur — ölçüt akışın SONU olmalı.
    if [ -n "$ILK_GERCEK" ] && [ -s "$ILK_GERCEK" ]; then
        local ad taban uzanti boy yeni
        ad="$(basename "$ILK_GERCEK")"
        taban="${ad%%_*}"                          # motor adı: verify dalını seçer
        uzanti="${ad#*_full_}"; uzanti="${uzanti#*.}"   # sql.gz / tar.gz / archive.gz …
        boy="$(wc -c < "$ILK_GERCEK" | tr -d '[:space:]')"
        yeni="$d/${taban}_full_e2e-kesik.${uzanti}"
        head -c "$(( boy / 2 ))" "$ILK_GERCEK" > "$yeni" 2>>"$E2E_LOG"
        dogrulama_reddetmeli "gerçek bir yedeğin yarısından kesilmiş kopyası doğrulamayı geçmiyor ($taban)" \
            "$yeni" "$(( boy / 2 )) / $boy bayt"

        # POZİTİF KONTROL: aynı verify sağlam dosyaya EVET demeli. Yoksa
        # yukarıdaki "reddetti" satırlarının hiçbiri bir şey kanıtlamaz.
        if calistir_izole "$SURE_DOGRULA" "verify (pozitif kontrol)" ./scripts/backup.sh verify "$ILK_GERCEK"; then
            t_ok "pozitif kontrol: sağlam yedek doğrulamadan geçiyor (verify her şeye 'hayır' demiyor)"
        else
            t_fail "pozitif kontrol: sağlam yedek doğrulamadan geçiyor" "$(son_ozet)"
        fi
    else
        t_skip "gerçek bir yedeğin yarısından kesilmiş kopyası doğrulamayı geçmiyor" \
               "bu koşumda hiç gerçek yedek üretilemedi (motorlar kapalı olabilir)"
        t_skip "pozitif kontrol: sağlam yedek doğrulamadan geçiyor" \
               "bu koşumda hiç gerçek yedek üretilemedi"
    fi

    # 7) Katalogda backup.supported=false olan motorlar (Kafka, izleme) için
    #    betik yedek almayı REDDETMELİ. Sessizce boş bir dosya üretseydi,
    #    kullanıcı olmayan bir kurtarma noktasına güvenirdi.
    local eid
    for eid in $(yedeklenemez_motorlar); do
        if calistir_izole "$SURE_ISTEMCI" "backup $eid (desteklenmiyor)" ./scripts/backup.sh "$eid"; then
            t_fail "$eid: katalogda yedeklenemez yazıyor, betik de yedek almayı reddediyor" \
                   "komut 0 ile döndü — desteklenmeyen motor için yedek almış gibi davranıyor"
        else
            t_ok "$eid: katalogda yedeklenemez yazıyor, betik de yedek almayı reddediyor"
        fi
    done
}

# ---------------------------------------------------------------------------
# YABANCI DOSYAYLA GERİ YÜKLEME — "veriyi sildim ama başarılı dedim" arızası
# ---------------------------------------------------------------------------
yabanci_dosya_testleri() {
    heading "Negatif testler — yanlış dosyayla geri yükleme veriyi SİLMEMELİ"
    local C pw rc sonra

    # (a) REDIS. restore_redis, dosyayı volume'a koymadan ÖNCE eski dump.rdb'yi
    # ve AOF'u SİLER; yani yabancı içerikli bir dosya doğrulamadan geçerse elde
    # ne eski veri ne yenisi kalır. Onay sorusuna BİLEREK 'evet' demiyoruz
    # (ASSUME_YES yok): doğrulama sızdırsa bile veri güvende kalsın. O durumda
    # çıktıda "İptal edildi" görürüz ve bunu DÜŞTÜ sayarız — çünkü ASSUME_YES
    # ile çalışan gerçek bir otomasyonda veri gitmiş olurdu.
    C="$(primary_of redis)"
    if container_running "$C" && printf '%s\n' "$SECILEN" | grep -qw redis; then
        pw="$(motor_pw redis)"
        local yanlis="$E2E_TMP/redis_full_e2e-yanlis.rdb.gz"
        printf '%s\n' "-- bu dosya bir SQL dump'i, RDB degil" \
                      "CREATE TABLE t(a int);" "INSERT INTO t VALUES (1);" \
            | gzip -6 > "$yanlis"
        calistir_izole "$SURE_GERI" "restore-redis (yabancı içerik)" ./scripts/backup.sh restore-redis "$yanlis"
        rc=$?
        sonra="$(veri_oku redis "$C" "$pw")"
        if [ "$rc" -eq 0 ]; then
            t_fail "redis: başka motorun içeriğini taşıyan dosya geri yüklemeyi durduruyor" \
                   "restore-redis 0 ile döndü — yabancı dosyayı yüklemiş sayıyor"
        elif son_icerir "İptal edildi"; then
            t_fail "redis: başka motorun içeriğini taşıyan dosya geri yüklemeyi durduruyor" \
                   "doğrulama dosyayı GEÇİRDİ, iş yalnızca onay sorusunda durdu; ASSUME_YES=yes ile Redis'in verisi silinirdi"
        else
            t_ok "redis: başka motorun içeriğini taşıyan dosya geri yüklemeyi durdurdu (doğrulama reddetti)"
        fi
        case "$sonra" in
            *"$KANIT"*) t_ok "redis: reddedilen geri yüklemeden sonra mevcut veri yerinde duruyor" ;;
            *) t_fail "redis: reddedilen geri yüklemeden sonra mevcut veri yerinde duruyor" \
                      "kanıt anahtarı kayboldu — reddedilen bir geri yükleme veriyi SİLMİŞ (okunan: '${sonra:-boş}')" ;;
        esac
    else
        t_skip "redis: başka motorun içeriğini taşıyan dosya geri yüklemeyi durduruyor" \
               "redis çalışmıyor ya da bu koşumda seçilmedi"
    fi

    # (b) MSSQL. Bu arşiv doğrulamayı GEÇER (minio adıyla üretilmiş, sağlam bir
    # tar.gz) — savunma restore_mssql'in kendisindedir: içinde .bak yoksa
    # durmalı. "Hiç dönmeyen döngü = başarı" tuzağı tam buradaydı; betik
    # hiçbir şey yapmadan "MSSQL geri yüklendi" deyip 0 ile çıkıyordu.
    C="$(primary_of mssql)"
    if container_running "$C" && printf '%s\n' "$SECILEN" | grep -qw mssql; then
        pw="$(motor_pw mssql)"
        mkdir -p "$E2E_TMP/yabanci"
        printf 'bu bir MSSQL yedegi degil\n' > "$E2E_TMP/yabanci/nesne.txt"
        local yab="$E2E_TMP/minio_full_e2e-yabanci.tar.gz"
        tar -czf "$yab" -C "$E2E_TMP/yabanci" . 2>>"$E2E_LOG"
        ( export ASSUME_YES=yes
          calistir_izole "$SURE_GERI" "restore-mssql (yabancı arşiv)" ./scripts/backup.sh restore-mssql "$yab" )
        rc=$?
        sonra="$(veri_oku mssql "$C" "$pw")"
        if [ "$rc" -eq 0 ]; then
            t_fail "mssql: içinde .bak olmayan yabancı arşivle geri yükleme reddediliyor" \
                   "restore-mssql hiçbir veritabanı geri yüklemeden 0 ile döndü"
        else
            t_ok "mssql: içinde .bak olmayan yabancı arşivle geri yükleme reddedildi"
        fi
        case "$sonra" in
            *"$KANIT"*) t_ok "mssql: reddedilen geri yüklemeden sonra veritabanı olduğu gibi duruyor" ;;
            *) t_fail "mssql: reddedilen geri yüklemeden sonra veritabanı olduğu gibi duruyor" \
                      "kanıt satırı kayboldu (okunan: '${sonra:-boş}')" ;;
        esac
    else
        t_skip "mssql: içinde .bak olmayan yabancı arşivle geri yükleme reddediliyor" \
               "mssql çalışmıyor ya da bu koşumda seçilmedi"
    fi
}

# ---------------------------------------------------------------------------
# TUR DAYANIKLILIĞI — bir motorun yedeği patlarsa TÜM TUR ölmemeli
# ---------------------------------------------------------------------------
# Gerçek arıza: backup_mssql'de tanımsız bir değişken yüzünden `set -u` bütün
# betiği ortasından kesti; o geceden sonraki motorların (cassandra, es,
# rabbitmq, clickhouse, neo4j, minio) hiçbiri yedeklenmedi ve ÖZET TABLOSU BİLE
# BASILMADI — kimse fark etmedi. Burada bir motorun parolasını kasten bozup
# turu koşuyoruz: özet basılmalı, hata sayılmalı, diğer motorlar yedeklenmeye
# devam etmeli. Yedekler geçici bir dizine yazılır; gerçek kurtarma
# noktalarına dokunulmaz.
tur_dayanikliligi() {
    heading "Tur dayanıklılığı — bir motor patlayınca diğerleri devam ediyor mu"

    if [ "${E2E_TUR:-1}" = "0" ]; then
        t_skip "bir motorun yedeği patlayınca tur ölmüyor (özet yine basılıyor)" "E2E_TUR=0 ile kapatıldı"
        return 0
    fi
    if [ "$DISK_YETER" = "0" ]; then
        t_skip "bir motorun yedeği patlayınca tur ölmüyor (özet yine basılıyor)" \
               "yedek diskinde 5 GB'dan az yer var"
        return 0
    fi

    # Sabotaj için parolayla konuşan bir motor lazım: rabbitmq/minio/neo4j
    # yedekleri parola kullanmaz, yanlış parola onları düşürmez.
    local sabotaj="" eid
    for eid in mariadb postgresql mongodb mssql clickhouse elasticsearch cassandra redis; do
        printf '%s\n' "$TUM_MOTORLAR" | grep -qx "$eid" || continue
        container_running "$(primary_of "$eid")" || continue
        sabotaj="$eid"; break
    done
    if [ -z "$sabotaj" ]; then
        t_skip "bir motorun yedeği patlayınca tur ölmüyor (özet yine basılıyor)" \
               "parolayla yedeklenen çalışan motor yok — kasten bozulacak bir şey bulunamadı"
        return 0
    fi

    # Devamlılığı ölçebilmek için sabotajlı motor dışında kaç motorun dosya
    # üretebileceğini sayıyoruz (neo4j hariç: `all` içinde bilerek atlanır).
    local digerleri=0
    for eid in $TUM_MOTORLAR; do
        [ "$eid" = "$sabotaj" ] && continue
        [ "$eid" = "neo4j" ] && continue
        container_running "$(primary_of "$eid")" && digerleri=$((digerleri+1))
    done

    local pwenv tur_dizin="$E2E_TMP/tur-yedekleri" rc basarisiz uretilen
    pwenv="$(motor_bilgi "$sabotaj" | cut -d'|' -f4)"
    mkdir -p "$tur_dizin"    # backup.sh'ın disk kontrolü için dizin VAR olmalı
    log "  sabote edilen motor: $sabotaj ($pwenv kasten yanlış); yedekler $tur_dizin altına yazılıyor"
    log "  bu tur çalışan bütün motorları yedekler, uzun sürebilir (en fazla $SURE_TUR sn)"

    # COMPRESSION_LEVEL=1: bu tur akışı sınıyor, sıkıştırma oranını değil.
    ( export BACKUP_DIR="$tur_dizin" COMPRESSION_LEVEL=1
      export "$pwenv=e2e-kasten-yanlis-parola"
      calistir "$SURE_TUR" "backup all (sabotajlı)" ./scripts/backup.sh all )
    rc=$?

    if kilit_carpismasi; then
        t_skip "bir motorun yedeği patlayınca tur ölmüyor (özet yine basılıyor)" \
               "başka bir yedekleme kilidi tutuyor"
        rm -rf "$tur_dizin"
        return 0
    fi

    basarisiz="$(grep -a 'Başarısız' "$SON_CIKTI" 2>/dev/null | head -1 | tr -dc '0-9')"
    if grep -qa 'Özet' "$SON_CIKTI" 2>/dev/null && [ -n "$basarisiz" ]; then
        t_ok "bir motorun yedeği patlayınca tur ölmüyor: özet tablosu yine basılıyor"
    else
        t_fail "bir motorun yedeği patlayınca tur ölmüyor: özet tablosu yine basılıyor" \
               "çıkış kodu=$rc, özette 'Başarısız' satırı yok — tur ortasından kesilmiş olabilir: $(son_ozet)"
    fi

    if [ "${basarisiz:-0}" -ge 1 ]; then
        t_ok "sabote edilen motor ($sabotaj) turda BAŞARISIZ sayıldı (yanlış parola sessizce yutulmuyor)"
    else
        t_fail "sabote edilen motor ($sabotaj) turda BAŞARISIZ sayıldı" \
               "yanlış parolayla alınan yedek başarılı sayılmış — boş/eksik dosya kurtarma noktası sanılır"
    fi

    if [ "$digerleri" -eq 0 ]; then
        t_skip "sabote edilen motordan sonraki motorlar yedeklenmeye devam etti" \
               "çalışan başka yedeklenebilir motor yok, devamlılık ölçülemez"
    else
        uretilen="$(find "$tur_dizin" -type f -name '*.gz' ! -path "$tur_dizin/$sabotaj/*" 2>/dev/null | wc -l)"
        if [ "${uretilen:-0}" -ge 1 ]; then
            t_ok "sabote edilen motordan sonraki motorlar yedeklenmeye devam etti ($uretilen dosya üretildi)"
        else
            t_fail "sabote edilen motordan sonraki motorlar yedeklenmeye devam etti" \
                   "$digerleri motor çalışıyordu ama tek dosya bile üretilmedi — tur ilk hatada ölmüş"
        fi
    fi
    rm -rf "$tur_dizin"
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
BASLANGIC="$(date +%s)"
heading "E2E yedekleme testi — $(date '+%Y-%m-%d %H:%M')"
if [ "${E2E_GERI_YUKLEME:-1}" = "0" ]; then
    log "Yıkıcı adım KAPALI: yedekler alınıp doğrulanacak, geri yükleme denenmeyecek."
else
    warn "Bu test GERİ YÜKLEME yapar: ilgili motorun verisi, testin başında alınan yedeğe döner."
    warn "  Bakım penceresi dışında çalıştırıyorsanız: E2E_GERI_YUKLEME=0 ./scripts/e2e/backup.sh"
fi

for motor in $SECILEN; do
    motor_turu "$motor"
done

negatif_testler
yabanci_dosya_testleri
tur_dayanikliligi

temizle

# ------------------------------------------------------------------- özet ---
TOPLAM=$((GECEN + DUSEN))
SURE=$(( $(date +%s) - BASLANGIC ))
heading "Özet"
printf '  yedekleme: %d/%d geçti  (%d atlandı, %dm %ds)\n' \
    "$GECEN" "$TOPLAM" "$ATLANAN" "$((SURE / 60))" "$((SURE % 60))"

if [ "$DUSEN" -gt 0 ]; then
    printf '\n  Düşen kontroller:\n%s' "$DUSEN_ADLAR"
    printf '  Komut çıktılarının tamamı: %s\n\n' "$E2E_LOG"
    exit 1
fi
# Her şey geçtiyse log'u da bırakmıyoruz (betik kendi ürettiği dosyayı siler).
# Bir hata varsa log DURUYOR: hatanın tek ayrıntısı orada.
rm -f "$E2E_LOG"
printf '\n'
# "Hepsi geçti" ile "hiç ölçülmedi" karıştırılmamalı: kapalı motorların
# yedekleri bu koşumda DENENMEDİ; onlar için hiçbir şey kanıtlanmadı.
if [ "$ATLANAN" -gt 0 ]; then
    ok "Denenen motorların yedekleri geri yüklenebilir durumda."
    warn "$ATLANAN kontrol ATLANDI — atlanan motorlar için geri yüklenebilirlik KANITLANMADI."
else
    ok "Yedeklenen her motorun verisi geri yüklendi ve doğrulandı."
fi
exit 0
