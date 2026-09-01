#!/bin/sh
# MariaDB GTID replikasyonu.
#   prepare → primary'de replikasyon kullanıcısı (binlog my.cnf'te zaten açık)
#   attach  → primary'nin tutarlı bir kopyasını replikaya bas, sonra START SLAVE
set -eu
PHASE="${1:-prepare}"
PASS="${MARIADB_PASSWORD:-$DB_PASSWORD}"
RUSER="${MARIADB_REPLICATION_USER:-repl}"
RPASS="${MARIADB_REPLICATION_PASSWORD:-$PASS}"

# Parola MYSQL_PWD ile geçer — komut satırında olsaydı host'ta `ps` çıktısında
# ve container'ın /proc'unda görünürdü.
m_primary() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD -i mariadb mariadb -u root "$@"; }
m_replica() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD -i mariadb-replica mariadb -u root "$@"; }

case "$PHASE" in
prepare)
  echo "[mariadb] binlog kontrolü"
  v=$(m_primary -N -e "SELECT @@log_bin;" 2>/dev/null | tr -d '[:space:]')
  [ "$v" = "1" ] || { echo "[mariadb] ✗ log_bin kapalı — config/mariadb/my.cnf içinde açık olmalı" >&2; exit 1; }

  echo "[mariadb] replikasyon kullanıcısı: $RUSER"
  m_primary -e "
      CREATE USER IF NOT EXISTS '$RUSER'@'%' IDENTIFIED BY '$RPASS';
      ALTER USER '$RUSER'@'%' IDENTIFIED BY '$RPASS';
      GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '$RUSER'@'%';
      FLUSH PRIVILEGES;"
  echo "[mariadb] hazır"
  ;;
attach)
  echo "[mariadb] replika hazır olması bekleniyor…"
  i=0; while [ $i -lt 40 ]; do
      m_replica -e "SELECT 1" >/dev/null 2>&1 && break
      i=$((i+1)); sleep 3
  done
  [ $i -lt 40 ] || { echo "[mariadb] ✗ replika açılmadı" >&2; exit 1; }

  # Zaten bağlıysa tekrar kopyalama (uzun sürer, gereksiz).
  if m_replica -N -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -q "Slave_IO_Running: Yes"; then
      echo "[mariadb] ✓ replika zaten akışta"; exit 0
  fi

  echo "[mariadb] primary'den tutarlı kopya alınıyor (--gtid ile)…"
  # --single-transaction: tabloları kilitlemeden tutarlı anlık görüntü.
  # --gtid: dump'a `SET GLOBAL gtid_slave_pos=...` yazar → replika tam olarak
  #         doğru noktadan devam eder, veri atlanmaz/tekrarlanmaz.
  MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD mariadb mariadb-dump -u root \
      --all-databases --single-transaction --quick --gtid --master-data=2 \
      --routines --triggers --events \
    | m_replica

  echo "[mariadb] CHANGE MASTER"
  m_replica -e "
      STOP SLAVE;
      CHANGE MASTER TO
          MASTER_HOST='mariadb', MASTER_PORT=3306,
          MASTER_USER='$RUSER', MASTER_PASSWORD='$RPASS',
          MASTER_USE_GTID=slave_pos,
          MASTER_CONNECT_RETRY=10;
      START SLAVE;"

  sleep 5
  st=$(m_replica -e "SHOW SLAVE STATUS\G" 2>/dev/null)
  if printf '%s' "$st" | grep -q "Slave_IO_Running: Yes" && \
     printf '%s' "$st" | grep -q "Slave_SQL_Running: Yes"; then
      echo "[mariadb] ✓ replikasyon çalışıyor"
      printf '%s' "$st" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Gtid_IO_Pos"
      exit 0
  fi
  echo "[mariadb] ✗ replikasyon başlamadı:" >&2
  printf '%s' "$st" | grep -E "Last_.*Error" >&2 || true
  exit 1
  ;;
cleanup)
  # MariaDB'de PostgreSQL'in slot'u gibi WAL tutan bir yapı yok; binlog
  # zaten binlog_expire_logs_seconds ile temizleniyor. Yine de replikanın
  # bağlantısını düzgün kapatıp replikasyon kullanıcısını kaldırıyoruz.
  echo "[mariadb] replikasyon kullanıcısı kaldırılıyor: $RUSER"
  m_primary -e "DROP USER IF EXISTS '$RUSER'@'%'; FLUSH PRIVILEGES;" 2>/dev/null || true
  echo "[mariadb] temizlendi"
  ;;
esac
