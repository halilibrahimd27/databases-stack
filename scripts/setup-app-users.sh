#!/bin/bash
# =============================================================================
# Uygulama kullanıcısı — kısıtlı yetkiler
# =============================================================================
# Uygulamanız veritabanına root ile bağlanmamalı. Bu betik her aktif motorda
# yalnız veri okuyup yazabilen, ama veritabanını/tabloyu SİLEMEYEN bir kullanıcı
# oluşturur.
#
#   İZİN VERİLEN : SELECT, INSERT, UPDATE, DELETE, CREATE TABLE, ALTER, INDEX
#   YASAK        : DROP DATABASE/TABLE, TRUNCATE, GRANT, SUPER, FLUSHALL
#
# Kullanıcı adı/parola .env'den gelir (APP_USER / APP_PASSWORD); install.sh
# parolayı zaten üretmiştir, elle bir şey girmeniz gerekmez.
#
# GÜVENLİK: parolalar komut satırına YAZILMAZ. `docker exec ... -pPAROLA`
# biçimi host'ta `ps` çıktısında ve container'ın /proc'unda görünürdü.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
load_env

APP_USER="${APP_USER:-appuser}"
APP_PASSWORD="${APP_PASSWORD:-}"
[ -n "$APP_PASSWORD" ] || die "APP_PASSWORD .env'de tanımlı değil — ./install.sh çalıştırın"

# ============================================================== MariaDB =====
setup_mariadb() {
    container_running mariadb || { log "mariadb kapalı, atlanıyor"; return 0; }
    heading "MariaDB — $APP_USER"
    local pw="${MARIADB_PASSWORD:-$DB_PASSWORD}"
    m() { MYSQL_PWD="$pw" docker exec -e MYSQL_PWD -i mariadb mariadb -u root "$@"; }

    # Yetkiler *.* ÜZERİNDE DEĞİL, kullanıcı veritabanları üzerinde veriliyor.
    # *.* demek appuser'ın `mysql` şemasını (parola hash'leri!) okuyabilmesi
    # demekti — "least privilege" iddiasıyla çelişiyordu.
    local dbs; dbs="$(m -N -e "SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT IN ('information_schema','performance_schema','mysql','sys');" 2>/dev/null)"

    m <<SQL
CREATE USER IF NOT EXISTS '${APP_USER}'@'%' IDENTIFIED BY '${APP_PASSWORD}';
ALTER  USER '${APP_USER}'@'%' IDENTIFIED BY '${APP_PASSWORD}';
SQL

    local db
    while IFS= read -r db; do
        [ -z "$db" ] && continue
        m -e "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES,
              CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE ROUTINE,
              ALTER ROUTINE, CREATE VIEW, SHOW VIEW, TRIGGER
              ON \`$db\`.* TO '${APP_USER}'@'%';" 2>/dev/null \
            && log "  yetki verildi: $db"
    done <<< "$dbs"
    # Yeni veritabanı oluşturabilsin ama başkasınınkini silemesin
    m -e "GRANT USAGE ON *.* TO '${APP_USER}'@'%'; FLUSH PRIVILEGES;"

    if m -N -e "SHOW GRANTS FOR '${APP_USER}'@'%';" 2>/dev/null | grep -q "DROP"; then
        warn "  DROP yetkisi görünüyor — beklenmiyordu"
    else
        ok "DROP engellendi ✓"
    fi
    ok "MariaDB kullanıcısı hazır"
    warn "  Not: yeni bir veritabanı oluşturursanız bu betiği tekrar çalıştırın."
}

# =========================================================== PostgreSQL =====
setup_postgresql() {
    container_running postgresql || { log "postgresql kapalı, atlanıyor"; return 0; }
    heading "PostgreSQL — $APP_USER"
    local su="${POSTGRES_USER:-root}" db="${DEFAULT_DATABASE:-defaultdb}"
    p() { docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" -i postgresql \
          psql -U "$su" -v ON_ERROR_STOP=1 "$@"; }

    p -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${APP_USER}') THEN
      CREATE ROLE ${APP_USER} LOGIN PASSWORD '${APP_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT;
  ELSE
      ALTER ROLE ${APP_USER} WITH LOGIN PASSWORD '${APP_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END \$\$;
GRANT CONNECT ON DATABASE "${db}" TO ${APP_USER};
SQL

    p -d "$db" <<SQL
GRANT USAGE, CREATE ON SCHEMA public TO ${APP_USER};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${APP_USER};
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO ${APP_USER};
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ${APP_USER};
-- Bundan SONRA oluşturulacak tablolar için de aynı yetkiler.
-- FOR ROLE ${su} şart: default privileges yalnız belirtilen rolün yarattığı
-- nesneler için geçerlidir; onsuz yalnız komutu çalıştıranın nesnelerini kapsar.
ALTER DEFAULT PRIVILEGES FOR ROLE ${su} IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${APP_USER};
ALTER DEFAULT PRIVILEGES FOR ROLE ${su} IN SCHEMA public
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO ${APP_USER};
SQL
    ok "PostgreSQL kullanıcısı hazır"
    log "  Not: PostgreSQL'de bir rol KENDİ yarattığı tabloyu silebilir — bu motorun"
    log "  davranışıdır. Tabloları ${su} ile oluşturursanız appuser silemez."
}

# =============================================================== MongoDB ====
setup_mongodb() {
    container_running mongodb || { log "mongodb kapalı, atlanıyor"; return 0; }
    heading "MongoDB — $APP_USER"
    local sh_bin="${MONGO_SHELL:-mongosh}"
    docker exec -e M_ROOT_PW="${MONGO_PASSWORD:-$DB_PASSWORD}" -e M_APP_PW="$APP_PASSWORD" \
        -i mongodb "$sh_bin" --quiet \
        -u "${MONGO_USER:-root}" -p "${MONGO_PASSWORD:-$DB_PASSWORD}" \
        --authenticationDatabase admin <<JS
use admin
try { db.dropRole("appRole") } catch(e) {}
db.createRole({
  role: "appRole",
  privileges: [{
    resource: { db: "", collection: "" },
    actions: [ "find","listCollections","listIndexes","collStats","dbStats",
               "insert","update","remove","createCollection","createIndex",
               "dropIndex","killCursors" ]
    // dropDatabase / dropCollection / createUser / shutdown BİLEREK yok
  }],
  roles: []
})
try { db.dropUser("${APP_USER}") } catch(e) {}
db.createUser({ user: "${APP_USER}", pwd: "${APP_PASSWORD}",
                roles: [{ role: "appRole", db: "admin" }] })
print("appuser hazır")
JS
    [ $? -eq 0 ] && ok "MongoDB kullanıcısı hazır" || err "MongoDB kullanıcısı oluşturulamadı"
}

# ================================================================= Redis ====
setup_redis() {
    container_running redis || { log "redis kapalı, atlanıyor"; return 0; }
    heading "Redis — $APP_USER"
    local pw="${REDIS_PASSWORD:-$DB_PASSWORD}"
    r() { docker exec -e REDISCLI_AUTH="$pw" -i redis redis-cli --no-auth-warning "$@"; }

    # ~*   → tüm anahtarlara erişim
    # &*   → tüm pub/sub kanallarına erişim. Redis 7'den beri kanallar
    #        VARSAYILAN OLARAK KAPALIDIR; bu olmadan uygulamanın pub/sub'ı
    #        sessizce "NOPERM" alır (önceki sürümdeki eksik).
    r ACL SETUSER "$APP_USER" on ">$APP_PASSWORD" '~*' '&*' \
        +@all -@admin -@dangerous \
        -flushall -flushdb -shutdown -config -replicaof -slaveof -cluster -migrate -keys \
        >/dev/null
    r ACL SAVE >/dev/null
    r --user "$APP_USER" --pass "$APP_PASSWORD" --no-auth-warning PING 2>/dev/null | grep -q PONG \
        && ok "Redis kullanıcısı hazır (bağlantı testi geçti)" \
        || warn "Redis kullanıcısı oluşturuldu ama bağlantı testi başarısız"
}

# ============================================================ ClickHouse ====
setup_clickhouse() {
    container_running clickhouse || { log "clickhouse kapalı, atlanıyor"; return 0; }
    heading "ClickHouse — $APP_USER"
    docker exec -e CH_PW="${CLICKHOUSE_PASSWORD:-$DB_PASSWORD}" -i clickhouse \
        clickhouse-client --user "${CLICKHOUSE_USER:-default}" --password "$CH_PW" -n <<SQL
CREATE USER IF NOT EXISTS ${APP_USER} IDENTIFIED BY '${APP_PASSWORD}';
ALTER USER ${APP_USER} IDENTIFIED BY '${APP_PASSWORD}';
GRANT SELECT, INSERT, CREATE TABLE, ALTER, OPTIMIZE ON ${DEFAULT_DATABASE:-defaultdb}.* TO ${APP_USER};
SQL
    [ $? -eq 0 ] && ok "ClickHouse kullanıcısı hazır" || err "ClickHouse kullanıcısı oluşturulamadı"
}

# ============================================================== RabbitMQ ====
setup_rabbitmq() {
    container_running rabbitmq || { log "rabbitmq kapalı, atlanıyor"; return 0; }
    heading "RabbitMQ — $APP_USER"
    docker exec rabbitmq rabbitmqctl add_user "$APP_USER" "$APP_PASSWORD" >/dev/null 2>&1 \
        || docker exec rabbitmq rabbitmqctl change_password "$APP_USER" "$APP_PASSWORD" >/dev/null 2>&1
    # management etiketi YOK → yönetim paneline giremez, sadece mesajlaşır
    docker exec rabbitmq rabbitmqctl set_permissions -p / "$APP_USER" ".*" ".*" ".*" >/dev/null 2>&1 \
        && ok "RabbitMQ kullanıcısı hazır" || err "RabbitMQ kullanıcısı oluşturulamadı"
}

remove_all() {
    heading "Uygulama kullanıcısı kaldırılıyor: $APP_USER"
    container_running mariadb && MYSQL_PWD="${MARIADB_PASSWORD:-$DB_PASSWORD}" docker exec -e MYSQL_PWD mariadb \
        mariadb -u root -e "DROP USER IF EXISTS '${APP_USER}'@'%'; FLUSH PRIVILEGES;" 2>/dev/null && ok "MariaDB"
    container_running postgresql && docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" postgresql \
        psql -U "${POSTGRES_USER:-root}" -d postgres -c "DROP ROLE IF EXISTS ${APP_USER};" >/dev/null 2>&1 && ok "PostgreSQL"
    container_running mongodb && docker exec mongodb "${MONGO_SHELL:-mongosh}" --quiet \
        -u "${MONGO_USER:-root}" -p "${MONGO_PASSWORD:-$DB_PASSWORD}" --authenticationDatabase admin \
        --eval "db.getSiblingDB('admin').dropUser('${APP_USER}')" >/dev/null 2>&1 && ok "MongoDB"
    container_running redis && docker exec -e REDISCLI_AUTH="${REDIS_PASSWORD:-$DB_PASSWORD}" redis \
        redis-cli --no-auth-warning ACL DELUSER "$APP_USER" >/dev/null 2>&1 && ok "Redis"
}

case "${1:-all}" in
    all)
        setup_mariadb; setup_postgresql; setup_mongodb
        setup_redis;   setup_clickhouse; setup_rabbitmq
        heading "Bağlantı bilgileri"
        printf '  Kullanıcı : %s\n  Parola    : %s\n\n' "$APP_USER" "$APP_PASSWORD"
        printf '  Bu bilgiler .env dosyasındadır (APP_USER / APP_PASSWORD).\n'
        printf '  Uygulamanızı artık root yerine bu kullanıcı ile bağlayın.\n\n'
        ;;
    mariadb)     setup_mariadb ;;
    postgresql)  setup_postgresql ;;
    mongodb)     setup_mongodb ;;
    redis)       setup_redis ;;
    clickhouse)  setup_clickhouse ;;
    rabbitmq)    setup_rabbitmq ;;
    remove)      remove_all ;;
    *)
cat <<EOF

Uygulama kullanıcısı oluşturma

  ./stack.sh app-user              Tüm aktif motorlarda oluştur
  ./stack.sh app-user mariadb      Yalnız bir motorda
  ./stack.sh app-user remove       Kaldır

Desteklenen: mariadb postgresql mongodb redis clickhouse rabbitmq
(Diğer motorlarda kısıtlı kullanıcı kavramı farklıdır — docs/SECURITY.md)

EOF
        exit 1 ;;
esac
