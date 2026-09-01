#!/bin/sh
# Redis failover.
#   ready   <servis>  → yükseltmeye HAZIR mı? (0=evet)  ← fence'ten ÖNCE sorulur
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
ready)
  # Master ölmüşse master_link_status:down olur — bu NORMALDİR, engel değil.
  # Bakılan şey: bu replika hiç senkron oldu mu (offset ilerledi mi)?
  info="$(r INFO replication || true)"
  printf '%s
' "$info" | grep -q 'role:master' && { echo "[redis] $SVC zaten master"; exit 0; }
  printf '%s
' "$info" | grep -q 'role:slave' || {
      echo "[redis] ✗ $SVC replika olarak yapılandırılmamış" >&2; exit 1; }
  off="$(printf '%s
' "$info" | grep -o 'slave_repl_offset:[0-9-]*' | cut -d: -f2 | tr -d '[:space:]')"
  if [ -z "$off" ] || [ "$off" -le 0 ] 2>/dev/null; then
      echo "[redis] ✗ $SVC hiç senkron olmamış (offset=${off:-yok}) — yükseltme veri kaybıdır" >&2
      exit 1
  fi
  echo "[redis] $SVC yükseltmeye hazır (offset: $off)"
  ;;
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
