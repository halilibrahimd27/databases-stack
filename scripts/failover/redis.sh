#!/bin/sh
# Redis failover.
#   promote <servis>  → replikayı primary yap (idempotent)
#   check   <servis>  → master rolünde mi? (0=evet)
#
# Redis Sentinel'e gerek yok: aynı işi (izleme + yükseltme + yönlendirme)
# controller yapıyor ve yönlendirmeyi de o güncelliyor.
set -eu
ACTION="${1:-check}"; SVC="${2:-redis-replica}"
PASS="${REDIS_PASSWORD:-$DB_PASSWORD}"
r() { docker exec -e REDISCLI_AUTH="$PASS" "$SVC" redis-cli --no-auth-warning "$@" 2>/dev/null; }

case "$ACTION" in
check) r INFO replication | grep -q 'role:master' ;;
promote)
  if r INFO replication | grep -q 'role:master'; then
      echo "[redis] $SVC zaten master"; exit 0
  fi
  echo "[redis] $SVC yükseltiliyor…"
  r REPLICAOF NO ONE >/dev/null
  sleep 1
  if r INFO replication | grep -q 'role:master'; then
      echo "[redis] ✓ $SVC artık master (yazmaya açık)"
      # replica-read-only komut satırından geldiği için master rolünde etkisizdir
      exit 0
  fi
  echo "[redis] ✗ yükseltme doğrulanamadı" >&2; exit 1
  ;;
esac
