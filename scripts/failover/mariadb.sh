#!/bin/sh
# MariaDB failover.
#   promote <servis>  → replikayı primary yap (idempotent)
#   check   <servis>  → yazılabilir primary mi? (0=evet)
set -eu
ACTION="${1:-check}"; SVC="${2:-mariadb-replica}"
PASS="${MARIADB_PASSWORD:-$DB_PASSWORD}"
m() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$SVC" mariadb -u root -N -e "$1" 2>/dev/null; }

is_primary() {
    ro="$(m 'SELECT @@read_only;' | tr -d '[:space:]')"
    io="$(m 'SHOW SLAVE STATUS\G' | grep -c 'Slave_IO_Running: Yes' || true)"
    [ "$ro" = "0" ] && [ "$io" = "0" ]
}

case "$ACTION" in
check) is_primary ;;
promote)
  if is_primary; then echo "[mariadb] $SVC zaten primary"; exit 0; fi
  echo "[mariadb] $SVC yükseltiliyor…"
  # Relay log'daki kalan olayları uygulamasını bekle — aksi halde primary'nin
  # gönderdiği ama henüz işlenmemiş işlemler kaybolur.
  m 'STOP SLAVE IO_THREAD;' >/dev/null || true
  i=0
  while [ $i -lt 30 ]; do
      left="$(m 'SHOW SLAVE STATUS\G' | grep 'Read_Master_Log_Pos\|Exec_Master_Log_Pos' | tr -d ' ' || true)"
      relay="$(m 'SHOW SLAVE STATUS\G' | grep -c 'Slave_SQL_Running_State: Slave has read all relay log' || true)"
      [ "$relay" = "1" ] && break
      i=$((i+1)); sleep 1
  done
  # read_only container komut satırından geldiği için yeniden başlatmada geri
  # gelir; denetleyici `check` ile bunu görüp promote'u tekrar çalıştırır.
  m 'STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=OFF; SET GLOBAL super_read_only=OFF;' >/dev/null
  if is_primary; then
      echo "[mariadb] ✓ $SVC artık primary (yazmaya açık)"
      exit 0
  fi
  echo "[mariadb] ✗ yükseltme doğrulanamadı" >&2; exit 1
  ;;
esac
