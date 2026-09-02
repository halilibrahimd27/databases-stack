#!/bin/sh
# PostgreSQL streaming replication.
#   prepare → primary'de replikasyon kullanıcısı + pg_hba satırı
#   attach  → replikanın gerçekten akış aldığını doğrula
#   cleanup → replikasyon slot'unu sil (silinemezse HATA döner; aşağıya bakın)
# Replikanın kendisi pg_basebackup'ı compose entrypoint'inde çeker.
set -eu
PHASE="${1:-prepare}"
USER_="${POSTGRES_REPLICATION_USER:-replicator}"
PASS="${POSTGRES_REPLICATION_PASSWORD:-${POSTGRES_PASSWORD:-$DB_PASSWORD}}"
SU="${POSTGRES_USER:-root}"

# YÖN, KATALOG ADINDAN DEĞİL ÇAĞIRANDAN GELİR.
# Bu betik "ana kopya her zaman 'postgresql' container'ıdır" varsayıyordu.
# Bir devirden sonra bu varsayım TERSİNE döner ve betik yanlış düğüme çalışır:
# slot'u yedekte arar (ana kopyada duran kalıntıya dokunmaz), replikasyon
# rolünü ve pg_hba satırını yanlış düğüme yazar. Ölçülen sonucu şuydu —
# "failover rebuild postgresql" 900 saniye şu döngüde kaldı:
#   pg_basebackup: error: could not send replication command
#   "CREATE_REPLICATION_SLOT ..." ERROR: replication slot
#   "replica_from_primary" already exists
# ve kullanıcıya gösterilen mesaj bambaşka bir şey söylüyordu:
#   "postgresql hiç WAL almamış — yükseltme veri kaybına yol açar"
# Gerçek sebep yalnız `docker logs postgresql` çıktısındaydı.
PRIMARY="${REPLICATION_PRIMARY:-postgresql}"
STANDBY="${REPLICATION_STANDBY:-postgresql-replica}"

# SLOT ADI DÜĞÜME GÖRE DEĞİŞİR. compose'da her düğüm standby olduğunda kendi
# adını kullanıyor: postgresql → replica_from_primary, postgresql-replica →
# replica_1. Tek bir ada bakan sürüm, devirden sonra VAR OLMAYAN slot'u
# siliyor ve gerçekten duran slot'u hiç görmüyordu.
if [ "$STANDBY" = "postgresql" ]; then
    SLOT="${POSTGRES_SLOT_PRIMARY:-replica_from_primary}"
else
    SLOT="${POSTGRES_REPLICATION_SLOT:-replica_1}"
fi

# Yön sağlaması: ikisi aynıysa elimizde tek düğüm var demektir ve temizlik
# yanlış yere gider. Sessizce devam etmek yerine duruyoruz.
if [ "$PRIMARY" = "$STANDBY" ]; then
    echo "[pg] ✗ yön belirsiz: ana kopya ve yedek aynı düğüm ('$PRIMARY')." >&2
    echo "[pg]   state/topology.json tutarsız; ./stack.sh doctor" >&2
    exit 1
fi

psql_() { docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:-$DB_PASSWORD}" -i "$PRIMARY" \
            psql -U "$SU" -d postgres -v ON_ERROR_STOP=1 "$@"; }

# Slot'u siler ve GERÇEKTEN silindiğini DOĞRULAR; 0 dönerse slot yok demektir.
# $slot_left: "0" = slot yok, boş = ana kopyaya hiç ulaşılamadı, başka = duruyor.
#
# Eskiden buradaki psql çağrılarının hepsi `>/dev/null 2>&1 || true` ile
# maskeliydi ve dallar `echo` ile bitiyordu: dal HER ZAMAN 0 dönüyordu.
# Controller'daki "temizlik başarısızsa replikayı kaldırma" koruması bu yüzden
# ölü koddu — oysa asıl risk tam buradaydı: silinemeyen bir slot PostgreSQL'e
# "bu WAL'ı hâlâ biri okuyacak" der, WAL sonsuza dek birikir, disk dolar ve ANA
# KOPYA DURUR. Sessizce başarılı görünen tek yol, en pahalı yoldu.
drop_slot() {
    slot_left=""; slot_err=""
    i=0
    while [ $i -lt 5 ]; do
        # Slot AKTİFKEN silinemez ("replication slot is active for PID …").
        # Önce onu tutan bağlantıyı kesiyoruz; backend'in ölmesi bir an
        # sürdüğü için silme birkaç kez denenir.
        psql_ -c "SELECT pg_terminate_backend(active_pid) FROM pg_replication_slots
                  WHERE slot_name='$SLOT' AND active;" >/dev/null 2>&1 || true
        slot_err="$(psql_ -tAc "SELECT pg_drop_replication_slot('$SLOT')
                    WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$SLOT');" 2>&1 || true)"
        slot_left="$(psql_ -tAc "SELECT count(*) FROM pg_replication_slots WHERE slot_name='$SLOT';" 2>/dev/null | tr -d '[:space:]')"
        [ "$slot_left" = "0" ] && return 0
        i=$((i+1)); sleep 2
    done
    return 1
}

case "$PHASE" in
prepare)
  # Eski replikasyon slot'unu temizle. Replika sıfırdan kurulacağı için
  # pg_basebackup slot'u YENİDEN yaratmak isteyecek (`-S $SLOT -C`); kalıntı
  # varsa "replication slot already exists" ile ölür ve crash-loop'a girer.
  echo "[pg] yön: $PRIMARY (kaynak) → $STANDBY (hedef)"
  echo "[pg] eski replikasyon slot'u temizleniyor (varsa): $SLOT"
  if ! drop_slot; then
      # Burada durup sebebi söylemek, replikanın 5 dakika crash-loop'ta
      # dönmesini bekleyip anlamsız bir zaman aşımı hatası vermekten iyidir.
      if [ -z "$slot_left" ]; then
          echo "[pg] ✗ ana kopyaya ($PRIMARY) bağlanılamadı." >&2
          echo "[pg]   Panelde PostgreSQL'in durumu 'çalışıyor' olmalı; başlatıp tekrar deneyin." >&2
      else
          echo "[pg] ✗ eski replikasyon slot'u silinemedi: $SLOT" >&2
          echo "[pg]   $slot_err" >&2
          echo "[pg]   Yedek kopya bu kalıntı dururken kurulamaz. Birkaç dakika sonra tekrar deneyin." >&2
      fi
      exit 1
  fi

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
  docker exec "$PRIMARY" sh -c '
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
  echo "[pg] ✗ replika 5 dakikada bağlanmadı — 'docker logs $STANDBY' bakın" >&2
  exit 1
  ;;
cleanup)
  # ⚠️ BU ADIM ATLANAMAZ. Boşta kalan bir replikasyon slot'u, PostgreSQL'e
  # "bu WAL'ı hâlâ birinin okuması gerekiyor" der ve WAL SONSUZA DEK BİRİKİR.
  # Sonu diskin dolması ve primary'nin durmasıdır. Replikasyon kapatılırken
  # slot mutlaka silinmeli.
  echo "[pg] replikasyon slot'u siliniyor: $SLOT (yoksa WAL sonsuza dek birikir)"
  if ! drop_slot; then
      # Bu daldan HATA dönmek şart. Controller çıkış kodunu okuyor: sıfırdan
      # farklıysa yedeği KALDIRMIYOR ve kullanıcıya tekrar denemesini söylüyor.
      # Ana kopya ayaktayken bu iş her zaman yeniden denenebilir; kaldırılmış
      # bir replikanın geride bıraktığı slot ise geri alınamaz biçimde WAL
      # biriktirmeye devam ederdi.
      if [ -z "$slot_left" ]; then
          echo "[pg] ✗ ana kopyaya ($PRIMARY) bağlanılamadı — slot'un silindiği DOĞRULANAMADI." >&2
          echo "[pg]   Ana kopya çalışırken 'Yedek Kopya Kur / Kapat' işlemini bir kez daha çalıştırın." >&2
      else
          echo "[pg] ✗ replikasyon slot'u SİLİNEMEDİ: $SLOT" >&2
          echo "[pg]   $slot_err" >&2
          echo "[pg]   Bu kalıntı dururken ana kopya WAL biriktirir, sonunda disk dolar ve durur." >&2
          echo "[pg]   Yedek kopya bilerek KALDIRILMADI; birkaç dakika sonra tekrar deneyin." >&2
      fi
      exit 1
  fi
  echo "[pg] ✓ slot silindi; ana kopyada kalan slot'lar:"
  psql_ -c "SELECT slot_name, active, pg_size_pretty(
              pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS tutulan_wal
            FROM pg_replication_slots;" 2>/dev/null || true
  echo "[pg] temizlendi"
  ;;

*)
  # Tanınmayan faz SESSİZCE 0 DÖNMEZ: `case` hiçbir dala uymadığında 0 döner ve
  # controller bunu "yapıldı" sayıp bir sonraki adıma geçer. Redis betiğinde
  # eksik bir faz tam olarak böyle sessiz bir arızaya yol açmıştı.
  echo "[pg] ✗ bilinmeyen faz: '$PHASE' (prepare | attach | cleanup)" >&2
  exit 2
  ;;
esac
