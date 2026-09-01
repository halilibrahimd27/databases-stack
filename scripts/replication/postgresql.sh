#!/bin/sh
# PostgreSQL streaming replication.
#   prepare → primary'de replikasyon kullanıcısı + pg_hba satırı
#   attach  → replikanın gerçekten akış aldığını doğrula
# Replikanın kendisi pg_basebackup'ı compose entrypoint'inde çeker.
set -eu
PHASE="${1:-prepare}"
USER_="${POSTGRES_REPLICATION_USER:-replicator}"
PASS="${POSTGRES_REPLICATION_PASSWORD:-${POSTGRES_PASSWORD:-$DB_PASSWORD}}"
SU="${POSTGRES_USER:-root}"

psql_() { docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" -i postgresql \
            psql -U "$SU" -d postgres -v ON_ERROR_STOP=1 "$@"; }

case "$PHASE" in
prepare)
  echo "[pg] replikasyon rolü hazırlanıyor: $USER_"
  psql_ -c "DO \$\$ BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='$USER_') THEN
          CREATE ROLE $USER_ WITH REPLICATION LOGIN PASSWORD '$PASS';
      ELSE
          ALTER ROLE $USER_ WITH REPLICATION LOGIN PASSWORD '$PASS';
      END IF;
  END \$\$;"

  # initdb'nin ürettiği pg_hba yalnız 127.0.0.1 için replikasyona izin verir;
  # replika ayrı bir container olduğu için ağdan gelen satırı eklemeliyiz.
  echo "[pg] pg_hba.conf güncelleniyor"
  docker exec postgresql sh -c '
      HBA="$PGDATA/pg_hba.conf"
      grep -q "databases-stack-replication" "$HBA" 2>/dev/null && exit 0
      printf "\n# databases-stack-replication\nhost replication %s all scram-sha-256\n" "'"$USER_"'" >> "$HBA"
  '
  psql_ -c "SELECT pg_reload_conf();" >/dev/null
  echo "[pg] hazır"
  ;;
attach)
  echo "[pg] replika bağlantısı bekleniyor…"
  i=0
  while [ $i -lt 60 ]; do
      # state='streaming' ŞART. Sadece satır saymak yetmez: ilk klonlama
      # sırasında pg_basebackup'ın kendi bağlantısı da burada görünür
      # (state='backup') ve "hazır" sanılıp erken dönülürdü.
      n=$(psql_ -tAc "SELECT count(*) FROM pg_stat_replication WHERE state='streaming';" 2>/dev/null || echo 0)
      if [ "${n:-0}" -ge 1 ]; then
          echo "[pg] ✓ replika akışta (streaming)"
          psql_ -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
          exit 0
      fi
      i=$((i+1)); sleep 5
  done
  echo "[pg] ✗ replika 5 dakikada bağlanmadı — 'docker logs postgresql-replica' bakın" >&2
  exit 1
  ;;
esac
