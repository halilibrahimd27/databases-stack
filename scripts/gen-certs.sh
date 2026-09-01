#!/bin/bash
# =============================================================================
# İç ağ TLS sertifikaları — DOMAIN GEREKTİRMEZ
# =============================================================================
# İç ağda alan adı yok, Let's Encrypt de kullanılamaz (HTTP-01/DNS-01 doğrulaması
# için dışarıdan erişilebilir bir isim ister). Çözüm: kendi mini CA'mız.
#
#   ca.crt / ca.key       → yalnız bir kez üretilir, sunucuda kalır
#   server.crt / .key     → CA'nın imzaladığı, IP SAN'lı sunucu sertifikası
#
# CA'yı bir kez istemcilere kurunca (dashboard'daki "Güvenlik sertifikasını
# indir" bağlantısı) tarayıcı uyarısı tamamen kalkar — self-signed sertifikanın
# aksine, çünkü tarayıcılar IP'li self-signed sertifikaya asla güvenmez ama
# güvenilen bir CA'nın imzaladığı IP SAN'lı sertifikayı kabul eder.
#
# Kullanım:  ./scripts/gen-certs.sh [ek-isim-veya-IP ...]
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

CERT_DIR="$STACK_ROOT/certs"
DAYS_CA=3650      # 10 yıl — CA'yı sık değiştirmek istemcilere yeniden kurdurur
DAYS_SRV=825      # tarayıcıların kabul ettiği üst sınır

require_cmd openssl
mkdir -p "$CERT_DIR"
load_env

# --------------------------------------------------------------- SAN listesi
# Sunucuya hangi adreslerden erişilirse hepsi burada olmalı; olmayan bir
# adresten girildiğinde tarayıcı yine uyarı verir.
declare -a NAMES=() IPS=()
NAMES+=("localhost")
IPS+=("127.0.0.1")

[ -n "${STACK_HOST:-}" ] && {
    if [[ "$STACK_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then IPS+=("$STACK_HOST")
    else NAMES+=("$STACK_HOST"); fi
}
# Makinenin kendi adı ve tüm yerel IP'leri
NAMES+=("$(hostname -s 2>/dev/null || echo host)")
NAMES+=("$(hostname -f 2>/dev/null || true)")
if command -v hostname >/dev/null 2>&1; then
    for ip in $(hostname -I 2>/dev/null || true); do IPS+=("$ip"); done
fi
for extra in "$@"; do
    if [[ "$extra" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then IPS+=("$extra")
    else NAMES+=("$extra"); fi
done

# tekilleştir + boşları at
mapfile -t NAMES < <(printf '%s\n' "${NAMES[@]}" | awk 'NF' | sort -u)
mapfile -t IPS   < <(printf '%s\n' "${IPS[@]}"   | awk 'NF' | sort -u)

SAN=""
i=1; for n in "${NAMES[@]}"; do SAN+="DNS.$i = $n"$'\n'; i=$((i+1)); done
i=1; for a in "${IPS[@]}";   do SAN+="IP.$i = $a"$'\n';  i=$((i+1)); done

heading "TLS sertifikaları üretiliyor"
log "Adlar: ${NAMES[*]}"
log "IP'ler: ${IPS[*]}"

# ------------------------------------------------------------------- CA ----
if [ -f "$CERT_DIR/ca.key" ] && [ -f "$CERT_DIR/ca.crt" ]; then
    ok "Mevcut CA korunuyor (istemcilere kurulmuş olabilir, yenilemek onları bozar)"
else
    openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -sha256 -days "$DAYS_CA" \
        -key "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
        -subj "/CN=databases-stack Internal CA/O=databases-stack" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
    ok "Yeni CA üretildi (10 yıl geçerli)"
fi

# --------------------------------------------------------------- sunucu ----
cat > "$CERT_DIR/server.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions     = ext
prompt             = no
[dn]
CN = ${STACK_HOST:-databases-stack}
O  = databases-stack
[ext]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt
[alt]
$SAN
EOF

openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null
openssl req -new -key "$CERT_DIR/server.key" -out "$CERT_DIR/server.csr" \
    -config "$CERT_DIR/server.cnf" 2>/dev/null
openssl x509 -req -in "$CERT_DIR/server.csr" \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/server.crt" -days "$DAYS_SRV" -sha256 \
    -extfile "$CERT_DIR/server.cnf" -extensions ext 2>/dev/null
rm -f "$CERT_DIR/server.csr"

# CA'nın özel anahtarı sızarsa saldırgan bu ağ için geçerli sertifika üretebilir.
chmod 600 "$CERT_DIR/ca.key" "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt"

ok "Sunucu sertifikası üretildi (${DAYS_SRV} gün)"
log "Doğrulama:"
openssl x509 -in "$CERT_DIR/server.crt" -noout -text \
    | sed -n '/Subject Alternative Name/,+1p' | sed 's/^/       /'
