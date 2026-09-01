#!/bin/sh
# MongoDB replica set (rs0).
# DİKKAT: MongoDB'de replikasyon açmak primary'nin de --replSet ile YENİDEN
# BAŞLAMASINI gerektirir (overrides/mongodb-replica.yml bunu yapar). Kısa bir
# kesinti olur; diğer motorlarda böyle bir kesinti yoktur.
set -eu
PHASE="${1:-prepare}"
RS="${MONGO_REPLICA_SET:-rs0}"
USER_="${MONGO_USER:-root}"
PASS="${MONGO_PASSWORD:-$DB_PASSWORD}"
SHELL_BIN="${MONGO_SHELL:-mongosh}"

mongo_() {  # $1 = container, $2 = js
    docker exec -e M_PW="$PASS" "$1" "$SHELL_BIN" --quiet \
        -u "$USER_" -p "$PASS" --authenticationDatabase admin --eval "$2"
}

case "$PHASE" in
prepare)
  # keyfile olmadan --replSet + --auth birlikte çalışmaz; mongod açılışta ölür.
  [ -f "${STACK_DIR:-/project}/state/mongo-keyfile" ] || \
      { echo "[mongo] ✗ state/mongo-keyfile yok — ./install.sh çalıştırın" >&2; exit 1; }
  echo "[mongo] keyfile mevcut; primary --replSet ile yeniden başlatılacak"
  ;;
attach)
  echo "[mongo] üyeler bekleniyor…"
  i=0; while [ $i -lt 40 ]; do
      mongo_ mongodb 'db.adminCommand({ping:1})' >/dev/null 2>&1 && break
      i=$((i+1)); sleep 3
  done
  [ $i -lt 40 ] || { echo "[mongo] ✗ primary açılmadı" >&2; exit 1; }

  if mongo_ mongodb 'rs.status().ok' 2>/dev/null | grep -q '^1$'; then
      echo "[mongo] replica set zaten kurulu; ikinci üye ekleniyor (varsa)"
      mongo_ mongodb "try { rs.add('mongodb-replica-1:27017') } catch(e) { print(e.message) }"
  else
      echo "[mongo] replica set başlatılıyor: $RS"
      mongo_ mongodb "rs.initiate({_id:'$RS', members:[
          {_id:0, host:'mongodb:27017', priority:2},
          {_id:1, host:'mongodb-replica-1:27017', priority:1}]})"
  fi

  echo "[mongo] PRIMARY seçimi bekleniyor…"
  i=0; while [ $i -lt 30 ]; do
      if mongo_ mongodb 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
          echo "[mongo] ✓ replica set çalışıyor"
          mongo_ mongodb 'rs.status().members.forEach(m => print(m.name, m.stateStr))'
          exit 0
      fi
      i=$((i+1)); sleep 3
  done
  echo "[mongo] ✗ PRIMARY seçilemedi" >&2
  exit 1
  ;;
esac
