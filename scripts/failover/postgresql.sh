#!/bin/sh
# PostgreSQL failover.
#   promote <servis>  → standby'ı primary yap (idempotent)
#   check   <servis>  → yazılabilir primary mi? (0=evet)
#
# Eski primary bu betik çağrılmadan ÖNCE durdurulmuştur (fence). İki kopyanın
# aynı anda yazma kabul etmesi (split-brain) böyle engellenir.
set -eu
ACTION="${1:-check}"; SVC="${2:-postgresql-replica}"
SU="${POSTGRES_USER:-root}"
psql_() { docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" "$SVC" \
            psql -U "$SU" -d postgres -tAc "$1" 2>/dev/null | tr -d '[:space:]'; }

case "$ACTION" in
check)
  # 'f' = recovery modunda DEĞİL = yazılabilir primary
  [ "$(psql_ 'SELECT pg_is_in_recovery();')" = "f" ]
  ;;
promote)
  if [ "$(psql_ 'SELECT pg_is_in_recovery();')" = "f" ]; then
      echo "[pg] $SVC zaten primary"; exit 0
  fi
  echo "[pg] $SVC yükseltiliyor…"
  # pg_ctl promote standby'ı recovery'den çıkarır. Veri kaybı, primary'nin
  # ölmeden önce göndermeye yetişemediği WAL kadardır (asenkron replikasyon).
  docker exec -u postgres "$SVC" pg_ctl promote -D "${PGDATA:-/var/lib/postgresql/data/pgdata}" || true
  i=0
  while [ $i -lt 60 ]; do
      if [ "$(psql_ 'SELECT pg_is_in_recovery();')" = "f" ]; then
          echo "[pg] ✓ $SVC artık primary (yazmaya açık)"
          exit 0
      fi
      i=$((i+1)); sleep 2
  done
  echo "[pg] ✗ 120 sn'de yükselmedi" >&2; exit 1
  ;;
esac
