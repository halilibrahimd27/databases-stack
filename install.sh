#!/bin/bash
# =============================================================================
# databases-stack — kurulum
# =============================================================================
# Tek komut, soru sormaz:   sudo ./install.sh
#
# TASARIM İLKESİ: kullanıcıdan bilemeyeceği hiçbir şey istenmez. Parolalar,
# sertifikalar, API anahtarları, sunucu adresi, bellek ayarları — hepsi burada
# otomatik üretilir ya da ölçülür. Kurulum bitince tarayıcıdan girilir ve
# istenen veritabanı düğmeye basılarak açılır.
#
# Seçimlik bayraklar:
#   --host <ip|ad>   Sunucu adresi (varsayılan: otomatik algılanır)
#   --no-start       Sadece hazırla, container başlatma
#   --force-secrets  Mevcut parolaları yeniden üret (DİKKAT: çalışan DB'leri bozar)
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"
source scripts/lib/common.sh

HOST_ARG=""; NO_START=0; FORCE_SECRETS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST_ARG="${2:-}"; shift 2 ;;
        --no-start) NO_START=1; shift ;;
        --force-secrets) FORCE_SECRETS=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "Bilinmeyen seçenek: $1" ;;
    esac
done

printf '\n%s╔════════════════════════════════════════════════╗%s\n' "$CYAN" "$NC"
printf '%s║   databases-stack — kurulum                    ║%s\n' "$CYAN" "$NC"
printf '%s╚════════════════════════════════════════════════╝%s\n' "$CYAN" "$NC"

# =============================================================================
# 1. ÖN KONTROLLER
# =============================================================================
heading "1/8  Ortam kontrolü"
require_docker
require_cmd openssl python3 awk grep sed
command -v flock >/dev/null 2>&1 || warn "flock yok — yedekleme kilidi çalışmaz (util-linux kurun)"
ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') + Compose v2"

# Betikler zip/scp/rsync ile kopyalanmışsa çalıştırma biti kaybolmuş olabilir.
# git klonunda mod zaten doğru gelir; bu yalnızca güvenlik ağı.
# DİKKAT: scripts/lib/ HARİÇ — oradaki dosyalar source edilir, çalıştırılmaz ve
# git'te 644'tür. Toplu chmod onları da 755 yapıp git ağacını kirletiyor ve
# sonraki `git pull` "local changes would be overwritten" ile başarısız oluyordu.
chmod +x stack.sh scripts/*.sh scripts/*.py          scripts/replication/*.sh scripts/failover/*.sh 2>/dev/null || true

# Bind mount'lar mutlak yol ister; controller compose'u kendi içinden çağırıyor.
STACK_DIR_VAL="$(pwd -P)"
ok "Stack dizini: $STACK_DIR_VAL"

# =============================================================================
# 2. MEVCUT KURULUM TESPİTİ (veri kaybını önle)
# =============================================================================
heading "2/8  Mevcut veri kontrolü"

# Volume adları <proje>_<volume> biçimindedir. Eski kurulum farklı bir proje
# adıyla (ör. dizin adı "databases") oluşturulmuşsa, yeni proje adıyla
# başlatmak BOŞ volume'lar yaratır ve veriler kayıp sanılır. Onun yerine eski
# proje adını tespit edip kullanmaya devam ediyoruz.
DETECTED_PROJECT=""
for vol in $(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '_(mariadb|postgresql|mongodb|redis|mssql)_data$' || true); do
    proj="${vol%_*_data}"
    [ -n "$proj" ] && DETECTED_PROJECT="$proj" && break
done
STACK_PROJECT_VAL="${DETECTED_PROJECT:-databases-stack}"
if [ -n "$DETECTED_PROJECT" ] && [ "$DETECTED_PROJECT" != "databases-stack" ]; then
    warn "Eski kurulum bulundu (proje adı: $DETECTED_PROJECT)."
    warn "Verileriniz orada duruyor; proje adı KORUNUYOR ki volume'lar aynı kalsın."
else
    ok "Proje adı: $STACK_PROJECT_VAL"
fi

# Var olan veriyle uyumsuz major sürüm = servis hiç açılmaz. Mevcut volume
# varsa sürümü sabitle; yükseltmeyi kullanıcı docs/UPGRADE.md ile bilinçli yapsın.
volume_has_data() {
    docker volume inspect "${STACK_PROJECT_VAL}_$1" >/dev/null 2>&1
}
PIN_NOTES=()
if volume_has_data mongodb_data; then
    PIN_NOTES+=("MongoDB")
fi
if volume_has_data postgresql_data; then
    PIN_NOTES+=("PostgreSQL")
fi

# =============================================================================
# 3. SUNUCU ADRESİ
# =============================================================================
heading "3/8  Sunucu adresi"
detect_host() {
    [ -n "$HOST_ARG" ] && { printf '%s' "$HOST_ARG"; return; }
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
    [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$ip" ] && ip="127.0.0.1"
    printf '%s' "$ip"
}
STACK_HOST_VAL="$(detect_host)"
ok "Sunucu adresi: $STACK_HOST_VAL  (değiştirmek için: ./install.sh --host <ip>)"

# =============================================================================
# 4. .env ÜRETİMİ
# =============================================================================
heading "4/8  Yapılandırma ve parolalar"
if [ ! -f .env ]; then
    cp .env.example .env
    chmod 600 .env
    ok ".env oluşturuldu (.env.example'dan)"
else
    ok "Mevcut .env korunuyor (eksik alanlar tamamlanacak)"
fi

# Boş bırakılmış her sırrı üret. Doluysa DOKUNMA — çalışan bir veritabanının
# parolasını değiştirmek onu erişilemez hâle getirir (parola volume'daki veriye
# yazılıdır, env'i değiştirmek geçmişe dönük çalışmaz).
gen_if_empty() {
    local key="$1" len="${2:-32}" cur
    cur="$(env_get "$key" || true)"
    if [ -z "$cur" ] || [ "$FORCE_SECRETS" = 1 ]; then
        env_set "$key" "$(rand_secret "$len")"
        return 0
    fi
    return 1
}
gen_if_empty DB_PASSWORD 32           && log "  DB_PASSWORD üretildi"
gen_if_empty CONTROLLER_TOKEN 40      && log "  CONTROLLER_TOKEN üretildi"
gen_if_empty KIBANA_ENCRYPTION_KEY 48 && log "  KIBANA_ENCRYPTION_KEY üretildi"
gen_if_empty PANEL_PASSWORD 24        && log "  PANEL_PASSWORD üretildi"
gen_if_empty PGADMIN_PASSWORD 24      && log "  PGADMIN_PASSWORD üretildi"
gen_if_empty APP_PASSWORD 24          && log "  APP_PASSWORD üretildi"
gen_if_empty GRAFANA_PASSWORD 24      && log "  GRAFANA_PASSWORD üretildi"
# Panellerde ikinci kez parola sorulmasın diye kullanılan çerez sırrı.
gen_if_empty PANEL_SSO_TOKEN 40       && log "  PANEL_SSO_TOKEN üretildi"
# Motor başına ayrı parola — tek sızıntı 12 motoru birden açmasın.
for k in MARIADB_PASSWORD POSTGRES_PASSWORD MONGO_PASSWORD REDIS_PASSWORD \
         MSSQL_PASSWORD CASSANDRA_PASSWORD ELASTIC_PASSWORD KIBANA_SYSTEM_PASSWORD \
         RABBITMQ_PASSWORD CLICKHOUSE_PASSWORD NEO4J_PASSWORD MINIO_ROOT_PASSWORD; do
    gen_if_empty "$k" 28 >/dev/null || true
done

env_set STACK_DIR     "$STACK_DIR_VAL"
env_set STACK_HOST    "$STACK_HOST_VAL"
env_set STACK_PROJECT "$STACK_PROJECT_VAL"

# Mevcut veriye göre sürüm sabitleme
if volume_has_data mongodb_data; then
    cur_mongo="$(env_get MONGO_VERSION || echo '')"
    if [ "$cur_mongo" != "4.4" ] && docker volume inspect "${STACK_PROJECT_VAL}_mongodb_data" >/dev/null 2>&1; then
        warn "Mevcut MongoDB verisi bulundu. Sürüm 4.4'te sabitlendi."
        warn "→ Yükseltme veri taşıma gerektirir: docs/UPGRADE.md"
        env_set MONGO_VERSION "4.4"
        env_set MONGO_SHELL   "mongo"    # mongosh 5.0 ile geldi
    fi
fi
# MongoDB 5.0+ CPU'da AVX komut seti İSTER. Eski Xeon'lar, bazı sanallaştırma
# profilleri (QEMU varsayılan CPU modeli) ve düşük seviye VPS'lerde AVX yoktur;
# mongod açılışta "Illegal instruction (core dumped)" ile ölür ve sonsuz
# crash-loop'a girer. 4.4 bu CPU'larda sorunsuz çalışır.
if ! grep -qm1 ' avx ' /proc/cpuinfo 2>/dev/null; then
    cur_mv="$(env_get MONGO_VERSION || echo '')"
    case "$cur_mv" in
        4.*) ;;
        *)  warn "Bu işlemcide AVX desteği yok — MongoDB 5.0+ çalışamaz."
            warn "→ MongoDB sürümü 4.4'te sabitlendi (bu CPU'da çalışan son sürüm)."
            env_set MONGO_VERSION "4.4"
            env_set MONGO_SHELL   "mongo"   # mongosh 5.0 ile geldi
            ;;
    esac
fi

if volume_has_data postgresql_data; then
    warn "Mevcut PostgreSQL verisi bulundu. Sürüm 15'te sabitlendi."
    warn "→ Yükseltme pg_upgrade gerektirir: docs/UPGRADE.md"
    env_set POSTGRES_VERSION "15"
fi
chmod 600 .env
ok "Parolalar hazır (.env, mod 600)"

load_env

# =============================================================================
# 5. DİZİNLER
# =============================================================================
heading "5/8  Dizinler"
mkdir -p state certs overrides backups logs \
         backups/{mariadb,postgresql,mongodb,redis,mssql,cassandra,elasticsearch,clickhouse,neo4j,rabbitmq,minio}/{full,single}
# İZİNLER — container'lar bu dosyaları KENDİ kullanıcılarıyla okur, host
# kullanıcısıyla değil. Dizinler 700 bırakılırsa:
#   • nginx worker'ı (uid 101) .htpasswd ve sertifikayı okuyamaz → her istek 500
#   • mongod (uid 999) replica set keyfile'ını okuyamaz → replica set açılmaz
# Bu yüzden dizinler geçilebilir; GİZLİ dosyalar tek tek kısıtlanır
# (server.key 600, mongo-keyfile 400).
chmod 755 state certs
# Yönlendirme tablosu gateway'e dosya olarak bağlanır. Yoksa docker onun yerine
# bir DİZİN yaratır ve nginx açılmaz — bu yüzden boş da olsa şimdi oluşturuluyor.
# İçeriğini controller açılışta üretir.
[ -f state/routes.conf ] || printf '# controller açılışta dolduracak
' > state/routes.conf
ok "state/ certs/ backups/ logs/ hazır"

# MongoDB replica set üyeleri birbirini keyfile ile doğrular. mongod, dosyanın
# grup/diğer okumasına kapalı olmasını ŞART koşar ve kendi kullanıcısıyla (999)
# okuyabilmelidir; bu yüzden sahiplik de ayarlanıyor.
if [ ! -f state/mongo-keyfile ]; then
    openssl rand -base64 756 > state/mongo-keyfile
    chmod 400 state/mongo-keyfile
    chown 999:999 state/mongo-keyfile 2>/dev/null || \
        warn "mongo-keyfile sahipliği ayarlanamadı (root değilsiniz) — replica set gerekirse: sudo chown 999:999 state/mongo-keyfile"
    ok "MongoDB keyfile üretildi"
fi

# =============================================================================
# 6. TLS
# =============================================================================
heading "6/8  TLS sertifikaları"
./scripts/gen-certs.sh >/dev/null 2>&1 || ./scripts/gen-certs.sh
ok "certs/ hazır — CA'yı istemcilere kurmak için: http://$STACK_HOST_VAL/ca.crt"

# =============================================================================
# 7. PANEL GİRİŞİ (basic auth)
# =============================================================================
heading "7/8  Panel girişi"
PANEL_USER_VAL="$(env_get PANEL_USER || echo admin)"
PANEL_PASS_VAL="$(env_get PANEL_PASSWORD || true)"   # bkz. aşağıdaki set -e notu
[ -z "$PANEL_PASS_VAL" ] && PANEL_PASS_VAL="$(env_get DB_PASSWORD)"

# htpasswd yoksa docker ile üret — ek paket kurdurmamak için.
if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbB "$PANEL_USER_VAL" "$PANEL_PASS_VAL" > gateway/.htpasswd
else
    docker run --rm httpd:2.4-alpine htpasswd -nbB "$PANEL_USER_VAL" "$PANEL_PASS_VAL" \
        > gateway/.htpasswd
fi
# 644 olmak zorunda: auth_basic_user_file'ı nginx'in WORKER süreçleri
# (uid 101) her istekte okur, root olan master değil. İçinde bcrypt özeti
# vardır, düz parola değil.
chmod 644 gateway/.htpasswd
ok "Panel kullanıcısı: $PANEL_USER_VAL"

# =============================================================================
# 8. BAŞLAT
# =============================================================================
heading "8/8  Çekirdek servisler"
if [ "$NO_START" = 1 ]; then
    warn "--no-start verildi, container başlatılmadı."
else
    log "Controller imajı derleniyor…"
    compose build controller >/dev/null 2>&1 || compose build controller
    log "Gateway + controller + adminer başlatılıyor…"
    compose up -d gateway controller adminer
    ok "Çekirdek ayakta. Veritabanları KAPALI — panelden açacaksınız."
fi

# =============================================================================
# ZAMANLANMIŞ GÖREVLER (şablondan gerçek yollarla üretilir)
# =============================================================================
sed "s|__STACK_DIR__|$STACK_DIR_VAL|g" scripts/crontab.template > state/crontab
ok "state/crontab hazır — yüklemek için: crontab state/crontab"

# =============================================================================
# ÖZET
# =============================================================================
# DİKKAT — `set -e` ile atamalar: `VAR="$(cmd)"` biçiminde cmd başarısız
# olursa ATAMA da başarısız olur ve betik ORACIKTA ölür. env_get, anahtar
# .env'de yoksa 1 döner; GRAFANA_USER hiçbir zaman üretilmediği için bu satır
# kurulumu tam da özet bölümünden ÖNCE öldürüyordu: çekirdek servisler ayağa
# kalkıyor, ekranda her şey başarılı görünüyor, ama credentials.txt hiç
# yazılmıyor ve kullanıcı parolasını HİÇ göremiyordu. Temiz kurulum testinde
# yakalandı; çıkış kodu 1 idi ama son satır "[✓] state/crontab hazır"dı.
GRAFANA_USER_VAL="$(env_get GRAFANA_USER || true)"
[ -n "$GRAFANA_USER_VAL" ] || GRAFANA_USER_VAL=admin
GRAFANA_PASS_VAL="$(env_get GRAFANA_PASSWORD || true)"
[ -n "$GRAFANA_PASS_VAL" ] || GRAFANA_PASS_VAL="$(env_get DB_PASSWORD || true)"
CRED=credentials.txt
{
    echo "databases-stack — erişim bilgileri"
    echo "Üretim tarihi: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "Sertifika kurulumu (önce bunu yapın): http://$STACK_HOST_VAL/setup"
    echo "Yönetim paneli : https://$STACK_HOST_VAL/"
    echo "Kullanıcı      : $PANEL_USER_VAL"
    echo "Parola         : $PANEL_PASS_VAL"
    echo
    echo "İzleme panosu  : https://$STACK_HOST_VAL:8092/  (aynı panel parolası)"
    echo "  Grafana'ya ziyaretçi olarak girersiniz; pano düzenlemek için:"
    echo "  Kullanıcı    : ${GRAFANA_USER_VAL}"
    echo "  Parola       : ${GRAFANA_PASS_VAL}"
    echo
    echo "Veritabanı parolaları .env dosyasındadır."
    echo "Bir veritabanının bağlantı bilgisini panelden 'Bağlantı bilgisi' ile alın."
} > "$CRED"
chmod 600 "$CRED"

printf '\n%s╔════════════════════════════════════════════════╗%s\n' "$GREEN" "$NC"
printf '%s║   KURULUM TAMAMLANDI                           ║%s\n' "$GREEN" "$NC"
printf '%s╚════════════════════════════════════════════════╝%s\n' "$GREEN" "$NC"
cat <<EOF

  Yönetim paneli :  ${BOLD}https://$STACK_HOST_VAL/${NC}
  Kullanıcı      :  $PANEL_USER_VAL
  Parola         :  $PANEL_PASS_VAL
                    (ayrıca $CRED dosyasında, mod 600)

  ${BOLD}Önce şunu yapın${NC} — tarayıcı uyarısını kalıcı olarak kaldırır:
  ${BOLD}http://$STACK_HOST_VAL/setup${NC}
  (adım adım anlatır; iç ağa özel sertifika otoritesidir, domain gerekmez)

  Kurmadan da girebilirsiniz: uyarı ekranında "Gelişmiş → Devam et".
  Bağlantı yine şifrelidir, tarayıcı sadece imzalayanı tanımaz.

  ${BOLD}Sırada ne var?${NC}
  Panele girin, ihtiyacınız olan veritabanının kartındaki
  "Aktif Et" düğmesine basın. Sistem sunucunuzun belleğini ölçer,
  ayarları kendisi hesaplar. Hiçbir teknik değer girmenize gerek yok.

  Terminalden yönetmek isterseniz:
    ./stack.sh list              # motorlar ve durumları
    ./stack.sh enable postgresql # aç
    ./stack.sh disable redis     # kapat
    ./stack.sh backup            # tüm aktif motorları yedekle
    ./stack.sh doctor            # kurulum sağlık kontrolü
EOF

if [ ${#PIN_NOTES[@]} -gt 0 ]; then
    printf '\n%s  Not:%s Mevcut veri bulunduğu için şu motorların sürümü sabitlendi: %s\n' \
        "$YELLOW" "$NC" "${PIN_NOTES[*]}"
    printf '       Yükseltmek için docs/UPGRADE.md okuyun.\n'
fi
echo
