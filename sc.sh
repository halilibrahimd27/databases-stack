#!/bin/bash

# =============================================================================
# DATABASE SERVER SETUP SCRIPT - SNAP DOCKER
# Tüm database sunucuları için tek script
# =============================================================================

set -e

# RENK KODLARI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }

# =============================================================================
# KONFIGÜRASYON - BURADAN DEĞİŞTİR
# =============================================================================
SERVER_IP="${1:-$(hostname -I | awk '{print $1}')}"
SERVER_NAME="${2:-Database}"

# .env'den oku ya da ortam değişkeni olarak ver:
#   DB_PASSWORD=...   ./sc.sh
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD env var veya .env zorunlu}"
NGINX_USER="${NGINX_USER:-root}"
NGINX_PASS="${NGINX_PASS:-${DB_PASSWORD}}"

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  DATABASE SERVER SETUP - SNAP DOCKER${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Server IP:   $SERVER_IP"
echo "Server Name: $SERVER_NAME"
echo "DB Password: $DB_PASSWORD"
echo "Nginx Auth:  $NGINX_USER / $NGINX_PASS"
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

mkdir -p /opt/databases/mariadb/config
mkdir -p /opt/databases/nginx/html
mkdir -p /opt/databases/pgadmin
mkdir -p /opt/databases/logs
mkdir -p /opt/databases/backups
mkdir -p /opt/databases/backups/mariadb/full
mkdir -p /opt/databases/backups/postgresql/full
mkdir -p /opt/databases/backups/mongodb/full
mkdir -p /opt/databases/backups/redis/full
mkdir -p /opt/databases/redisinsight-data


success "Dizinler oluşturuldu"

# =============================================================================
# 2. MARIADB CONFIG
# =============================================================================
log "MariaDB config oluşturuluyor..."

cat > /opt/databases/mariadb/config/my.cnf << 'EOF'
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

[client]
default-character-set=utf8mb4
EOF

success "MariaDB config hazır"

# =============================================================================
# 3. NGINX CONFIG
# =============================================================================
log "Nginx config oluşturuluyor..."

cat > /opt/databases/nginx/nginx.conf << 'EOF'
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

        auth_basic "Database Administration Panel";
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
# 4. NGINX INDEX.HTML (DASHBOARD)
# =============================================================================
log "Dashboard oluşturuluyor..."

cat > /opt/databases/nginx/html/index.html << EOF
<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${SERVER_NAME} Database Administration Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.1);
            overflow: hidden;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }
        .header h1 { font-size: 2.5em; margin-bottom: 10px; }
        .header p { font-size: 1.1em; opacity: 0.9; }
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
            background: linear-gradient(90deg, #667eea, #764ba2);
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
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
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
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
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
            background: #f8f9fa;
            padding: 30px;
            margin-top: 40px;
            border-radius: 10px;
            border-left: 5px solid #667eea;
        }
        .info-section h3 { color: #2c3e50; margin-bottom: 15px; }
        .connection-info {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-top: 20px;
        }
        .connection-card {
            background: white;
            padding: 20px;
            border-radius: 8px;
            border: 1px solid #dee2e6;
        }
        .connection-card h4 { color: #495057; margin-bottom: 10px; }
        .connection-details {
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            color: #6c757d;
            line-height: 1.8;
        }
        .welcome-message {
            background: #e7f3ff;
            padding: 20px;
            margin-bottom: 30px;
            border-radius: 8px;
            border-left: 4px solid #0066cc;
        }
        .welcome-message h3 { color: #0066cc; margin-bottom: 10px; }
        .welcome-message p { color: #495057; margin: 0; }
        @media (max-width: 768px) {
            .header h1 { font-size: 2em; }
            .main-content { padding: 20px; }
            .grid { grid-template-columns: 1fr; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🗄️ ${SERVER_NAME} Database Administration</h1>
            <p>Centralized Database Management Panel</p>
        </div>
        <div class="main-content">
            <div class="welcome-message">
                <h3>🎉 Hoş Geldiniz!</h3>
                <p>Tüm veritabanı yönetim araçlarınıza buradan güvenli şekilde erişebilirsiniz.</p>
            </div>
            <div class="grid">
                <div class="card">
                    <div class="card-icon">📊</div>
                    <h3>MariaDB</h3>
                    <p>MySQL/MariaDB Database Management with phpMyAdmin</p>
                    <a href="http://${SERVER_IP}:8081" target="_blank">Open phpMyAdmin</a>
                    <div class="status">● Online</div>
                </div>
                <div class="card">
                    <div class="card-icon">🐘</div>
                    <h3>PostgreSQL</h3>
                    <p>Advanced PostgreSQL database administration via pgAdmin</p>
                    <a href="http://${SERVER_IP}:8082" target="_blank">Open pgAdmin</a>
                    <div class="status">● Online</div>
                </div>
                <div class="card">
                    <div class="card-icon">🍃</div>
                    <h3>MongoDB</h3>
                    <p>NoSQL document database management with Mongo Express</p>
                    <a href="http://${SERVER_IP}:8083" target="_blank">Open Mongo Express</a>
                    <div class="status">● Online</div>
                </div>
                <div class="card">
                    <div class="card-icon">🔴</div>
                    <h3>Redis</h3>
                    <p>In-memory data structure store management</p>
                    <a href="http://${SERVER_IP}:8084" target="_blank">Open Redis Commander</a>
                    <div class="status">● Online</div>
                </div>
                <div class="card">
                    <div class="card-icon">🔧</div>
                    <h3>Universal Admin</h3>
                    <p>Multi-database administration tool</p>
                    <a href="http://${SERVER_IP}:8085" target="_blank">Open Adminer</a>
                    <div class="status">● Online</div>
                </div>
                <div class="card">
                    <div class="card-icon">📈</div>
                    <h3>Health Monitor</h3>
                    <p>Database server health monitoring</p>
                    <a href="/health" target="_blank">Check Health</a>
                    <div class="status">● Monitoring</div>
                </div>
            </div>
            <div class="info-section">
                <h3>📋 Database Connection Information</h3>
                <p>Use these connection details for your applications:</p>
                <div class="connection-info">
                    <div class="connection-card">
                        <h4>MariaDB</h4>
                        <div class="connection-details">
                            Host: ${SERVER_IP}<br>
                            Port: 3306<br>
                            User: root / appuser<br>
                            DB: defaultdb
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>PostgreSQL</h4>
                        <div class="connection-details">
                            Host: ${SERVER_IP}<br>
                            Port: 5432<br>
                            User: root / appuser<br>
                            DB: defaultdb
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>MongoDB</h4>
                        <div class="connection-details">
                            Host: ${SERVER_IP}<br>
                            Port: 27017<br>
                            User: root / appuser<br>
                            Auth DB: admin
                        </div>
                    </div>
                    <div class="connection-card">
                        <h4>Redis</h4>
                        <div class="connection-details">
                            Host: ${SERVER_IP}<br>
                            Port: 6379<br>
                            User: default / appuser
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</body>
</html>
EOF

success "Dashboard hazır"

# =============================================================================
# 5. PGADMIN SERVERS.JSON
# =============================================================================
log "pgAdmin config oluşturuluyor..."

cat > /opt/databases/pgadmin_servers.json << 'EOF'
{
  "Servers": {
    "1": {
      "Name": "PostgreSQL",
      "Group": "Servers",
      "Host": "postgresql",
      "Port": 5432,
      "MaintenanceDB": "postgres",
      "Username": "root",
      "SSLMode": "prefer"
    }
  }
}
EOF

success "pgAdmin config hazır"

# =============================================================================
# 6. İZİNLERİ DÜZELT
# =============================================================================
log "İzinler düzeltiliyor..."

chown -R 5050:5050 /opt/databases/pgadmin
chmod 755 /opt/databases/logs
chmod 755 /opt/databases/backups
chmod 644 /opt/databases/nginx/nginx.conf
chmod 755 /opt/databases/nginx/html
chmod 644 /opt/databases/nginx/html/index.html
chown -R 1001:1001 /opt/databases/redisinsight-data

chmod +x /opt/databases/*.sh 2>/dev/null || true

success "İzinler düzeltildi"

# =============================================================================
# 7. DOCKER COMPOSE DURDUR
# =============================================================================
log "Docker Compose durduruluyor..."

cd /opt/databases 2>/dev/null || true
docker-compose down --remove-orphans 2>/dev/null || true

success "Docker Compose durduruldu"

# =============================================================================
# 8. SNAP DİZİNİNE TAŞI
# =============================================================================
log "Snap dizinine taşınıyor..."

mkdir -p /var/snap/docker/common/databases
cp -r /opt/databases/* /var/snap/docker/common/databases/
cd /var/snap/docker/common/databases

success "Snap dizinine taşındı"

# =============================================================================
# 9. HTPASSWD OLUŞTUR (DOCKER İLE)
# =============================================================================
log "Nginx kullanıcıları oluşturuluyor..."

# htpasswd dosyasını docker ile oluştur — APP_PASSWORD env var üzerinden
docker run --rm httpd:alpine htpasswd -nb "${NGINX_USER}" "${NGINX_PASS}" > /var/snap/docker/common/databases/nginx/.htpasswd
docker run --rm httpd:alpine htpasswd -nb appuser "${APP_PASSWORD:?APP_PASSWORD env var zorunlu}" >> /var/snap/docker/common/databases/nginx/.htpasswd

chmod 644 /var/snap/docker/common/databases/nginx/.htpasswd

success "Nginx kullanıcıları oluşturuldu (root, appuser)"

# =============================================================================
# 10. İZİNLERİ TEKRAR DÜZELT
# =============================================================================
log "Son izin düzenlemeleri..."

chown -R root:root /var/snap/docker/common/databases/
chown -R 5050:5050 /var/snap/docker/common/databases/pgadmin
chmod 755 /var/snap/docker/common/databases/nginx
chmod 755 /var/snap/docker/common/databases/nginx/html
chmod 644 /var/snap/docker/common/databases/nginx/html/index.html
chown -R 1001:1001 /opt/databases/redisinsight-data

success "İzinler tamamlandı"

# =============================================================================
# 11. DOCKER COMPOSE BAŞLAT
# =============================================================================
log "Docker Compose başlatılıyor..."

cd /var/snap/docker/common/databases
docker-compose up -d

success "Docker Compose başlatıldı"

# =============================================================================
# 12. KONTROL
# =============================================================================
echo ""
log "Container durumları kontrol ediliyor..."
sleep 5
docker-compose ps

# =============================================================================
# 13. SONUÇ
# =============================================================================
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  KURULUM TAMAMLANDI!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Dashboard URL:  http://${SERVER_IP}"
echo ""
echo "Nginx Giriş Bilgileri:"
echo "  - root / ${DB_PASSWORD}"
echo "  - appuser / [APP_PASSWORD env var değeri]"
echo ""
echo "Database Panelleri:"
echo "  - phpMyAdmin:     http://${SERVER_IP}:8081"
echo "  - pgAdmin:        http://${SERVER_IP}:8082"
echo "  - Mongo Express:  http://${SERVER_IP}:8083"
echo "  - Redis Insight:  http://${SERVER_IP}:8084"
echo "  - Adminer:        http://${SERVER_IP}:8085"
echo ""
echo "Sonraki Adımlar:"
echo "  1. ./setup_db_users.sh   # Kısıtlı kullanıcı oluştur"
echo "  2. crontab crontab.txt   # Backup cron'u yükle"
echo "  3. ./backup.sh stats     # Backup durumunu kontrol et"
echo ""
echo -e "${GREEN}================================================${NC}"