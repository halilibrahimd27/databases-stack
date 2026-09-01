#!/bin/sh
# MongoDB replica set (rs0).
#   prepare → keyfile var mı? (yoksa --replSet + --auth birlikte açılmaz)
#   attach  → replica set'i kur / ikinci üyeyi ekle, PRIMARY seçimini bekle
#   cleanup → yedek üyeyi kümeden çıkar (container silinmeden ÖNCE)
# DİKKAT: MongoDB'de replikasyon açmak primary'nin de --replSet ile YENİDEN
# BAŞLAMASINI gerektirir (overrides/mongodb-replica.yml bunu yapar). Kısa bir
# kesinti olur; diğer motorlarda böyle bir kesinti yoktur.
set -eu
PHASE="${1:-prepare}"
RS="${MONGO_REPLICA_SET:-rs0}"
USER_="${MONGO_USER:-root}"
PASS="${MONGO_PASSWORD:-$DB_PASSWORD}"
SHELL_BIN="${MONGO_SHELL:-mongosh}"

# Yön controller'dan gelir; varsayılanlar hiç devir olmamış ilk kurulumun hâli.
PRIMARY="${REPLICATION_PRIMARY:-mongodb}"
STANDBY="${REPLICATION_STANDBY:-mongodb-replica-1}"

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
      mongo_ "$PRIMARY" 'db.adminCommand({ping:1})' >/dev/null 2>&1 && break
      i=$((i+1)); sleep 3
  done
  [ $i -lt 40 ] || { echo "[mongo] ✗ primary açılmadı" >&2; exit 1; }

  if mongo_ "$PRIMARY" 'rs.status().ok' 2>/dev/null | grep -q '^1$'; then
      echo "[mongo] replica set zaten kurulu; ikinci üye ekleniyor (varsa)"
      mongo_ "$PRIMARY" "try { rs.add('$STANDBY:27017') } catch(e) { print(e.message) }"
  else
      echo "[mongo] replica set başlatılıyor: $RS"
      mongo_ "$PRIMARY" "rs.initiate({_id:'$RS', members:[
          {_id:0, host:'$PRIMARY:27017', priority:2},
          {_id:1, host:'$STANDBY:27017', priority:1}]})"
  fi

  echo "[mongo] PRIMARY seçimi bekleniyor…"
  i=0; while [ $i -lt 30 ]; do
      if mongo_ "$PRIMARY" 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
          echo "[mongo] ✓ replica set çalışıyor"
          mongo_ "$PRIMARY" 'rs.status().members.forEach(m => print(m.name, m.stateStr))'
          exit 0
      fi
      i=$((i+1)); sleep 3
  done
  echo "[mongo] ✗ PRIMARY seçilemedi" >&2
  exit 1
  ;;

cleanup)
  # Bu dal EKSİKTİ ve `case` hiçbir dala uymayınca 0 döndüğü için controller
  # temizliği "yapıldı" sayıyordu. Yapılmayan iş şuydu: iki üyeli bir replica
  # set'te ÇOĞUNLUK 2'dir. Üyelerden biri kümeden çıkarılmadan ortadan
  # kaybolursa (container siliniyor) kalan üye oy çoğunluğunu bulamaz ve
  # PRIMARY'likten DÜŞER — veritabanı o an yazmaya kapanır. Üyeyi önce düzgünce
  # çıkarmak bu pencereyi tamamen kapatır.
  echo "[mongo] replica set üyesi çıkarılıyor: $STANDBY"
  out="$(mongo_ "$PRIMARY" "try { rs.remove('$STANDBY:27017'); print('removed') }
                            catch(e) { print('ERR ' + e.message) }" 2>&1 || true)"
  case "$out" in
    *removed*) echo "[mongo] üye kümeden çıkarıldı" ;;
    *)         echo "[mongo] üye çıkarılamadı: $out" ;;
  esac
  # Çıkış kodu 0: controller bu adımdan sonra ana kopyayı --replSet'siz haline
  # geri alıyor, dolayısıyla geride WAL/slot gibi BİRİKEN bir kalıntı kalmıyor.
  # Hata döndürseydik hiçbir şey biriktirmeyen bir kalıntı yüzünden kullanıcı
  # "yedeği kaldıramıyorum" durumuna kilitlenirdi. (PostgreSQL'de tam tersi.)
  echo "[mongo] temizlendi"
  ;;

*)
  # Tanınmayan faz SESSİZCE 0 DÖNMEZ; controller 0'ı "yapıldı" sayar.
  echo "[mongo] ✗ bilinmeyen faz: '$PHASE' (prepare | attach | cleanup)" >&2
  exit 2
  ;;
esac
