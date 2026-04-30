#!/bin/bash

# =============================================================================
# CASSANDRA SERVER SETUP SCRIPT
# Apache Cassandra 5.0 production deployment
# =============================================================================

set -e

# RENK KODLARI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# =============================================================================
# KONFIGÜRASYON
# =============================================================================
SERVER_IP="${1:-$(hostname -I | awk '{print $1}')}"
SERVER_NAME="${2:-Cassandra}"
CASSANDRA_USER="${CASSANDRA_USER:-cassandra}"
CASSANDRA_PASS="${CASSANDRA_PASS:?CASSANDRA_PASS env var zorunlu}"
NGINX_USER="${NGINX_USER:-root}"
NGINX_PASS="${NGINX_PASS:-${CASSANDRA_PASS}}"
APP_PASSWORD="${APP_PASSWORD:?APP_PASSWORD env var zorunlu}"
INSTALL_DIR="${INSTALL_DIR:-/opt/cassandra}"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  CASSANDRA SERVER SETUP${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Server IP:        $SERVER_IP"
echo "Server Name:      $SERVER_NAME"
echo "Install Dir:      $INSTALL_DIR"
echo "Cassandra User:   $CASSANDRA_USER"
echo "Cassandra Pass:   $CASSANDRA_PASS"
echo "Nginx Auth:       $NGINX_USER / $NGINX_PASS"
echo ""
read -p "Devam edilsin mi? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "İptal edildi."
    exit 0
fi

# =============================================================================
# 1. DİZİNLERİ OLUŞTUR
# =============================================================================
log "Dizinler oluşturuluyor..."

mkdir -p $INSTALL_DIR/cassandra/config
mkdir -p $INSTALL_DIR/nginx/html
mkdir -p $INSTALL_DIR/logs
mkdir -p $INSTALL_DIR/backups/snapshots
mkdir -p $INSTALL_DIR/backups/schema
mkdir -p $INSTALL_DIR/backups/single

success "Dizinler oluşturuldu"

# =============================================================================
# 2. CASSANDRA ENV CONFIG
# =============================================================================
log "Cassandra config oluşturuluyor..."

cat > $INSTALL_DIR/cassandra/config/cassandra-env.sh << 'EOF'
# Cassandra environment configuration

# JVM Options
JVM_OPTS="$JVM_OPTS -Dcassandra.allow_unsafe_aggressive_sstable_expiration=true"
JVM_OPTS="$JVM_OPTS -Djava.net.preferIPv4Stack=true"

# GC Settings (for containers)
JVM_OPTS="$JVM_OPTS -XX:+UseG1GC"
JVM_OPTS="$JVM_OPTS -XX:G1RSetUpdatingPauseTimePercent=5"
JVM_OPTS="$JVM_OPTS -XX:MaxGCPauseMillis=500"
JVM_OPTS="$JVM_OPTS -XX:+ParallelRefProcEnabled"

# Memory settings (will be overridden by MAX_HEAP_SIZE env var)
# MAX_HEAP_SIZE="1G"
# HEAP_NEWSIZE="256M"

# JMX remote access
LOCAL_JMX=no
JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.authenticate=false"
JVM_OPTS="$JVM_OPTS -Dcom.sun.management.jmxremote.ssl=false"
JVM_OPTS="$JVM_OPTS -Djava.rmi.server.hostname=0.0.0.0"
EOF

success "Cassandra config hazır"

# =============================================================================
# 3. NGINX CONFIG
# =============================================================================
log "Nginx config oluşturuluyor..."

cat > $INSTALL_DIR/nginx/nginx.conf << 'EOF'
events {
    worker_connections 1024;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
    
    server {
        listen 80;
        server_name _;
        
        auth_basic "Cassandra Administration Panel";
        auth_basic_user_file /etc/nginx/.htpasswd;
        
        location / {
            root /usr/share/nginx/html;
            index index.html;
            try_files $uri $uri/ =404;
        }
        
        location /health {
            auth_basic off;
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
        
        location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }
}
EOF

success "Nginx config hazır"

# =============================================================================
# 4. NGINX DASHBOARD HTML
# =============================================================================
log "Dashboard oluşturuluyor..."

cat > $INSTALL_DIR/nginx/html/index.html << EOF
<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${SERVER_NAME} - Cassandra Administration Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.3);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #1a1a2e 0%, #0f3460 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .header p { font-size: 1.1em; opacity: 0.9; }
        .cassandra-logo { font-size: 4em; margin-bottom: 15px; }
        .main-content { padding: 40px; }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 25px;
            margin-top: 30px;
        }
        .card {
            background: white;
            border: 1px solid #e1e8ed;
            border-radius: 12px;
            padding: 25px;
            text-align: center;
            transition: all 0.3s ease;
            position: relative;
            overflow: hidden;
        }
        .card::before {
            content: '';
            position: absolute;
            top: 0; left: 0; right: 0;
            height: 4px;
            background: linear-gradient(90deg, #1a1a2e, #0f3460);
        }
        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 15px 35px rgba(0, 0, 0, 0.1);
        }
        .card-icon { font-size: 3em; margin-bottom: 15px; }
        .card h3 { color: #2c3e50; margin-bottom: 10px; font-size: 1.4em; }
        .card p { color: #7f8c8d; margin-bottom: 20px; line-height: 1.6; }
        .card a {
            display: inline-block;
            background: linear-gradient(135deg, #1a1a2e 0%, #0f3460 100%);
            color: white;
            padding: 12px 25px;
            text-decoration: none;
            border-radius: 25px;
            font-weight: 600;
            transition: all 0.3s ease;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            font-size: 0.9em;
        }
        .card a:hover {
            transform: scale(1.05);
            box-shadow: 0 5px 15px rgba(26, 26, 46, 0.4);
        }
        .status {
            margin-top: 15px;
            padding: 5px 12px;
            border-radius: 15px;
            font-size: 0.8em;
            font-weight: 600;
            background: #d4edda;
            color: #155724;
        }
        .info-section {
            margin-top: 40px;
            padding: 25px;
            background: #f8f9fa;
            border-radius: 12px;
        }
        .info-section h3 { 
            color: #1a1a2e; 
            margin-bottom: 15px;
            font-size: 1.3em;
        }
        .connection-info {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 15px;
        }
        .connection-card {
            background: white;
            padding: 15px;
            border-radius: 8px;
            border-left: 4px solid #0f3460;
        }
        .connection-card h4 { color: #1a1a2e; margin-bottom: 8px; }
        .connection-details { 
            font-family: monospace; 
            font-size: 0.85em; 
            color: #555; 
            line-height: 1.6;
        }
        .footer {
            text-align: center;
            padding: 20px;
            color: #7f8c8d;
            font-size: 0.9em;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="cassandra-logo">🗃️</div>
            <h1>${SERVER_NAME}</h1>
            <p>Apache Cassandra Administration Panel</p>
        </div>
        <div class="main-content">
            <div class="grid">
                <div class="card">
                    <div class="card-icon">🌐</div>
                    <h3>Cassandra Web UI</h3>
                    <p>Web-based Cassandra management interface for browsing keyspaces and tables</p>
                    <a href="http://${SERVER_IP}:3000" target="_blank">Open Web UI</a>
                    <div class="status">● Online</div>
                </div>
                <div class="card">
                    <div class="card-icon">📊</div>
                    <h3>Prometheus Metrics</h3>
                    <p>Cassandra metrics exporter for monitoring and alerting</p>
                    <a href="http://${SERVER_IP}:9500/metrics" target="_blank">View Metrics</a>
                    <div class="status">● Exporting</div>
                </div>
                <div class="card">
                    <div class="card-icon">💻</div>
                    <h3>CQL Shell</h3>
                    <p>Connect via command line for CQL queries</p>
                    <a href="#" onclick="alert('docker exec -it cassandra cqlsh -u cassandra -p \$CASSANDRA_PASS'); return false;">Show Command</a>
                    <div class="status">● Available</div>
                </div>
                <div class="card">
                    <div class="card-icon">🔧</div>
                    <h3>Node Tools</h3>
                    <p>Cassandra cluster management and monitoring</p>
                    <a href="#" onclick="alert('docker exec cassandra nodetool status'); return false;">Show Command</a>
                    <div class="status">● Ready</div>
                </div>
            </div>
            <div class="info-section">
                <h3>📋 Connection Information</h3>
                <p>Use these connection details for your applications:</p>
                <div class="connection-info">
                    <div class="connection-card">
                        <h4>CQL Native</h4>
                        <div class="connection-details">
                            Host: ${SERVER_IP}<br>
                            Port: 9042<br>
                            User: cassandra<br>
                            Auth: PasswordAuthenticator
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>Inter-node</h4>
                        <div class="connection-details">
                            Host: ${SERVER_IP}<br>
                            Port: 7000<br>
                            Cluster: ProductionCluster<br>
                            DC: datacenter1
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>JMX Monitoring</h4>
                        <div class="connection-details">
                            Host: ${SERVER_IP}<br>
                            Port: 7199<br>
                            Auth: None<br>
                            SSL: Disabled
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>Web UI</h4>
                        <div class="connection-details">
                            URL: http://${SERVER_IP}:3000<br>
                            Auth: None<br>
                            Mode: Read/Write
                        </div>
                    </div>
                </div>
            </div>
            <div class="info-section">
                <h3>🚀 Quick Commands</h3>
                <div class="connection-info">
                    <div class="connection-card">
                        <h4>Status Check</h4>
                        <div class="connection-details">
                            docker exec cassandra nodetool status<br>
                            docker exec cassandra nodetool info<br>
                            docker exec cassandra nodetool describecluster
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>Backup</h4>
                        <div class="connection-details">
                            /opt/cassandra/backup.sh all<br>
                            /opt/cassandra/backup.sh stats<br>
                            /opt/cassandra/backup.sh keyspaces
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>Maintenance</h4>
                        <div class="connection-details">
                            docker exec cassandra nodetool repair<br>
                            docker exec cassandra nodetool flush<br>
                            docker exec cassandra nodetool compactionstats
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>Logs</h4>
                        <div class="connection-details">
                            docker-compose logs -f cassandra<br>
                            tail -f /opt/cassandra/logs/*.log
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <div class="footer">
            Apache Cassandra 5.0 | ${SERVER_NAME} | $(date +%Y)
        </div>
    </div>
</body>
</html>
EOF

success "Dashboard hazır"

# =============================================================================
# 5. İZİNLERİ DÜZELT
# =============================================================================
log "İzinler düzeltiliyor..."

chmod 755 $INSTALL_DIR/logs
chmod 755 $INSTALL_DIR/backups
chmod 644 $INSTALL_DIR/nginx/nginx.conf
chmod 755 $INSTALL_DIR/nginx/html
chmod 644 $INSTALL_DIR/nginx/html/index.html
chmod +x $INSTALL_DIR/*.sh 2>/dev/null || true

success "İzinler düzeltildi"

# =============================================================================
# 6. HTPASSWD OLUŞTUR
# =============================================================================
log "Nginx kullanıcıları oluşturuluyor..."

# htpasswd dosyasını docker ile oluştur
docker run --rm httpd:alpine htpasswd -nb root "${NGINX_PASS}" > $INSTALL_DIR/nginx/.htpasswd
docker run --rm httpd:alpine htpasswd -nb appuser "${APP_PASSWORD}" >> $INSTALL_DIR/nginx/.htpasswd

chmod 644 $INSTALL_DIR/nginx/.htpasswd

success "Nginx kullanıcıları oluşturuldu (root, appuser)"

# =============================================================================
# 7. DOCKER COMPOSE BAŞLAT
# =============================================================================
log "Docker Compose başlatılıyor..."

cd $INSTALL_DIR
docker-compose up -d

success "Docker Compose başlatıldı"

# =============================================================================
# 8. CASSANDRA'NIN HAZIR OLMASINI BEKLE
# =============================================================================
log "Cassandra'nın başlamasını bekliyoruz (bu 2-3 dakika sürebilir)..."

max_attempts=60
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if docker exec cassandra nodetool status 2>/dev/null | grep -q "^UN"; then
        success "Cassandra hazır!"
        break
    fi
    echo -n "."
    sleep 5
    ((attempt++))
done

if [ $attempt -eq $max_attempts ]; then
    warning "Cassandra henüz hazır değil, logları kontrol edin: docker-compose logs cassandra"
fi

# =============================================================================
# 9. VARSAYILAN KULLANICI ŞİFRESİNİ DEĞİŞTİR
# =============================================================================
log "Cassandra kullanıcı şifresi değiştiriliyor..."

# Cassandra default user'ın şifresini değiştir
sleep 10
docker exec cassandra cqlsh -u cassandra -p cassandra \
    -e "ALTER USER cassandra WITH PASSWORD '$CASSANDRA_PASS';" 2>/dev/null || \
    warning "Şifre zaten değiştirilmiş olabilir"

success "Cassandra kullanıcı şifresi güncellendi"

# =============================================================================
# 10. ÖRNEK KEYSPACE OLUŞTUR
# =============================================================================
log "Örnek keyspace oluşturuluyor..."

docker exec cassandra cqlsh -u cassandra -p $CASSANDRA_PASS -e "
CREATE KEYSPACE IF NOT EXISTS example_keyspace
WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};

USE example_keyspace;

CREATE TABLE IF NOT EXISTS users (
    user_id UUID PRIMARY KEY,
    username TEXT,
    email TEXT,
    created_at TIMESTAMP
);

INSERT INTO users (user_id, username, email, created_at)
VALUES (uuid(), 'testuser', 'test@example.com', toTimestamp(now()));
" 2>/dev/null || warning "Örnek keyspace zaten mevcut olabilir"

success "Örnek keyspace oluşturuldu: example_keyspace"

# =============================================================================
# 11. KONTROL
# =============================================================================
echo ""
log "Container durumları kontrol ediliyor..."
sleep 3
docker-compose ps

echo ""
log "Cassandra cluster durumu:"
docker exec cassandra nodetool status 2>/dev/null || warning "Henüz hazır değil"

# =============================================================================
# 12. SONUÇ
# =============================================================================
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  KURULUM TAMAMLANDI!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Dashboard URL:      http://${SERVER_IP}"
echo ""
echo "Nginx Giriş Bilgileri:"
echo "  - root / ${NGINX_PASS}"
echo "  - appuser / [APP_PASSWORD]"
echo ""
echo "Cassandra Bağlantı Bilgileri:"
echo "  - Host: ${SERVER_IP}"
echo "  - Port: 9042"
echo "  - User: cassandra"
echo "  - Pass: ${CASSANDRA_PASS}"
echo ""
echo "Web Arayüzleri:"
echo "  - Dashboard:       http://${SERVER_IP}"
echo "  - Cassandra Web:   http://${SERVER_IP}:3000"
echo "  - Prometheus:      http://${SERVER_IP}:9500/metrics"
echo ""
echo "Sonraki Adımlar:"
echo "  1. crontab crontab           # Backup cron'u yükle"
echo "  2. ./backup.sh all           # İlk backup'ı al"
echo "  3. ./sync_remote.sh setup    # Google Drive sync kur"
echo "  4. ./backup.sh stats         # Backup durumunu kontrol et"
echo ""
echo "Faydalı Komutlar:"
echo "  docker exec -it cassandra cqlsh -u cassandra -p $CASSANDRA_PASS"
echo "  docker exec cassandra nodetool status"
echo "  docker-compose logs -f cassandra"
echo ""
echo -e "${GREEN}================================================${NC}"