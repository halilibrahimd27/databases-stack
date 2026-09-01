#!/bin/sh
# Redis replikasyonu compose'daki `--replicaof redis 6379` ile kendiliğinden
# kurulur; burada yalnızca gerçekten kurulduğunu doğruluyoruz.
set -eu
PHASE="${1:-prepare}"
[ "$PHASE" = "prepare" ] && { echo "[redis] hazırlık gerekmiyor"; exit 0; }

PASS="${REDIS_PASSWORD:-$DB_PASSWORD}"
i=0
while [ $i -lt 30 ]; do
    out=$(docker exec -e REDISCLI_AUTH="$PASS" redis-replica \
            redis-cli --no-auth-warning INFO replication 2>/dev/null || true)
    case "$out" in
      *role:slave*master_link_status:up*)
        echo "[redis] ✓ replika bağlandı"
        printf '%s\n' "$out" | grep -E 'role|master_link_status|slave_repl_offset'
        exit 0 ;;
    esac
    i=$((i+1)); sleep 3
done
echo "[redis] ✗ replika 90 sn'de bağlanmadı" >&2
exit 1
