#!/bin/sh
# MariaDB GTID replikasyonu.
#   prepare → primary'de replikasyon kullanıcısı (binlog my.cnf'te zaten açık)
#   attach  → primary'nin tutarlı bir kopyasını replikaya bas, sonra START SLAVE
#   cleanup → replikasyon kullanıcısını kaldır
set -eu
PHASE="${1:-prepare}"
PASS="${MARIADB_PASSWORD:-$DB_PASSWORD}"
RUSER="${MARIADB_REPLICATION_USER:-repl}"
RPASS="${MARIADB_REPLICATION_PASSWORD:-$PASS}"

# YÖN SABİT DEĞİLDİR. Devirden sonra roller yer değiştirir: canlı primary
# `mariadb-replica`, yeniden kurulacak yedek ise `mariadb` olur. Bu betik
# eskiden yönü sabit yazıyordu; controller doğru adları ortamda veriyordu ama
# betik onları hiç okumuyordu. Kurtarma sanılan şey felaketti: yedeği yeniden
# kurarken döküm AZ ÖNCE SİLİNMİŞ boş düğümden alınıp CANLI primary'nin üzerine
# basılıyor, üstüne canlı primary o boş düğümün slave'i yapılıyordu — yani elde
# kalan tek sağlam kopya siliniyordu. Artık kaynak ve hedef hep dışarıdan gelir;
# varsayılanlar hiç devir olmamış ilk kurulumun hâlidir.
PRIMARY="${REPLICATION_PRIMARY:-mariadb}"           # dökümün ALINACAĞI canlı primary
STANDBY="${REPLICATION_STANDBY:-mariadb-replica}"   # dökümün BASILACAĞI yedek

# Parola MYSQL_PWD ile geçer — komut satırında olsaydı host'ta `ps` çıktısında
# ve container'ın /proc'unda görünürdü.
m_primary() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD -i "$PRIMARY" mariadb -u root "$@"; }
m_replica() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD -i "$STANDBY" mariadb -u root "$@"; }

# Bir düğümdeki KULLANICI veritabanları (sistem şemaları hariç). Hem yön
# doğrulaması hem de tohumlama bunu kullanır.
user_dbs() {
    "$1" -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys');" 2>/dev/null | tr -d '\r'
}

# Replikanın sistem şeması sağlam mı? Bu üç tablo MariaDB'nin kendi
# kurulumundan gelir; biri bile eksikse şema bozulmuştur.
sys_schema_ok() {
    n="$(m_replica -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='mysql' AND table_name IN ('gtid_slave_pos','proc','global_priv');" 2>/dev/null | tr -d '[:space:]')"
    [ "$n" = "3" ]
}

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
  echo "[mariadb] yön: $PRIMARY (kaynak) → $STANDBY (hedef)"

  # Kaynakla hedef aynı olursa düğüm kendi kendinin slave'i yapılır; hiçbir
  # şey kopyalanmaz ama SLAVE ayarı düğümü bozar. Adları önce karşılaştırıyoruz.
  if [ "$PRIMARY" = "$STANDBY" ]; then
      echo "[mariadb] ✗ kaynak ve hedef aynı düğüm: $PRIMARY" >&2
      echo "[mariadb]   Yedek kopya, ana kopyadan FARKLI bir düğüm olmalı. Hiçbir şey yapılmadı." >&2
      exit 1
  fi

  # Döküm YALNIZCA yazılabilir primary'den alınır. read_only açıksa o düğüm ya
  # bir replikadır ya da devir sırasında kapatılmıştır; oradan alınacak kopya
  # eksik/eskimiş olur ve hedefteki veriyi boş yere ezerdik.
  ro="$(m_primary -N -e "SELECT @@read_only;" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$ro" ]; then
      echo "[mariadb] ✗ ana kopyaya bağlanılamadı: $PRIMARY" >&2
      echo "[mariadb]   Panelde bu veritabanının durumu 'çalışıyor' olmalı; başlatıp tekrar deneyin." >&2
      exit 1
  fi
  if [ "$ro" != "0" ]; then
      echo "[mariadb] ✗ kaynak düğüm ($PRIMARY) şu an yazma kabul etmiyor (read_only)." >&2
      echo "[mariadb]   Kopya CANLI ana veritabanından alınmalı — yön ters görünüyor. Hiçbir şey yapılmadı." >&2
      exit 1
  fi

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

  # Son ve en önemli yön kontrolü: kaynakta hiç kullanıcı veritabanı yokken
  # hedefte veri VARSA yön neredeyse kesin terstir — az önce silinip boş açılmış
  # bir düğümden, elde kalan tek dolu kopyanın üzerine döküm basmak üzereyiz.
  # Bu noktada devam etmek veriyi kurtarmak değil yok etmek olur.
  dbs="$(user_dbs m_primary)"
  if [ -z "$dbs" ] && [ -n "$(user_dbs m_replica)" ]; then
      echo "[mariadb] ✗ yön ters görünüyor: kaynakta ($PRIMARY) hiç veritabanı yok, hedefte ($STANDBY) veri var." >&2
      echo "[mariadb]   Kopyalama iptal edildi; hedefteki veriler OLDUĞU GİBİ duruyor, hiçbir şey silinmedi." >&2
      echo "[mariadb]   Panelde hangi kopyanın 'ana' (primary) olduğunu kontrol edip tekrar deneyin." >&2
      exit 1
  fi

  # ---------------------------------------------------------------------------
  # DİKKAT — burada `mariadb-dump --all-databases` KULLANILMAZ.
  #
  # O bayrak `mysql` sistem şemasını da döküme katar. Döküm replikaya basılınca
  # replikanın KENDİ sistem tabloları DROP edilir; yükleme herhangi bir satırda
  # durursa (istemci hatada durur) geri kalanlar bir daha yaratılmaz. Gerçek
  # sunucuda tam olarak bu oldu: replikada `mysql.proc` ve `mysql.gtid_slave_pos`
  # yok oldu, START SLAVE ilk COMMIT'te
  #   "failed to update GTID state in mysql.gtid_slave_pos: Table doesn't exist"
  # ile öldü; üstelik o düğümden alınan sonraki dökümler de bozuk çıktı.
  #
  # Replika zaten aynı imajla ve aynı root parolasıyla kuruluyor; sistem
  # şemasına ihtiyacı yok. Yalnız KULLANICI veritabanlarını taşıyoruz,
  # hesapları da `mysql` tablolarını kopyalayarak değil SHOW CREATE USER ile.
  # ---------------------------------------------------------------------------
  if ! sys_schema_ok; then
      echo "[mariadb] replikanın sistem şeması eksik — onarılıyor (mariadb-upgrade)"
      MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$STANDBY" \
          mariadb-upgrade -u root --force >/dev/null 2>&1 || true
      sys_schema_ok || { echo "[mariadb] ✗ replikanın sistem şeması onarılamadı" >&2; exit 1; }
      echo "[mariadb] ✓ sistem şeması onarıldı"
  fi

  err_log="$(mktemp)"
  if [ -n "$dbs" ]; then
      echo "[mariadb] kullanıcı veritabanları kopyalanıyor:" $dbs
      # --single-transaction: tabloları kilitlemeden tutarlı anlık görüntü.
      # --gtid + --master-data=2: dökümün başına `SET GLOBAL gtid_slave_pos=…`
      #   yazar → replika tam olarak doğru noktadan devam eder, veri atlanmaz.
      if ! MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$PRIMARY" mariadb-dump -u root \
              --databases $dbs \
              --single-transaction --quick --gtid --master-data=2 \
              --routines --triggers --events 2>"$err_log" \
            | m_replica 2>>"$err_log"; then
          echo "[mariadb] ✗ kopya aktarımı başarısız:" >&2
          tail -5 "$err_log" >&2; rm -f "$err_log"; exit 1
      fi
      # Kısmi yükleme replikasyonu sessizce bozar; hata geçiştirilmez.
      if grep -qi "error" "$err_log" 2>/dev/null; then
          echo "[mariadb] ✗ kopya aktarımında hata:" >&2
          grep -i "error" "$err_log" | head -5 >&2; rm -f "$err_log"; exit 1
      fi
  else
      # Hiç kullanıcı veritabanı yok — taşınacak veri de yok. GTID konumunu
      # yine de vermeliyiz, yoksa replika binlog'un BAŞINDAN okumaya çalışır.
      echo "[mariadb] taşınacak kullanıcı veritabanı yok, yalnız GTID konumu alınıyor"
      pos="$(m_primary -N -e "SELECT @@gtid_binlog_pos;" 2>/dev/null | tr -d '[:space:]')"
      m_replica -e "SET GLOBAL gtid_slave_pos='$pos';" >/dev/null
  fi
  rm -f "$err_log"

  # Hesaplar: `mysql` şemasını KOPYALAMADAN. Replikasyon başladıktan sonra
  # açılan kullanıcılar binlog ile zaten akar; buradaki iş, replikasyon
  # AÇILMADAN ÖNCE var olan hesapların devirden sonra da çalışmasını sağlamak.
  # root/mariadb.sys dışlanır — replikanın kendi hesapları bozulmasın.
  echo "[mariadb] kullanıcı hesapları taşınıyor"
  ulist="$(m_primary -N -e "SELECT CONCAT(QUOTE(User),'@',QUOTE(Host)) FROM mysql.global_priv WHERE User NOT IN ('root','mariadb.sys','mysql','PUBLIC') AND User <> '';" 2>/dev/null || true)"
  for u in $ulist; do
      cu="$(m_primary -N -e "SHOW CREATE USER $u;" 2>/dev/null)" || continue
      # IF NOT EXISTS: hesap replikada zaten varsa hata verip akışı kesmesin.
      printf '%s;\n' "$cu" | sed 's/^CREATE USER /CREATE USER IF NOT EXISTS /' \
          | m_replica >/dev/null 2>&1 || true
      m_primary -N -e "SHOW GRANTS FOR $u;" 2>/dev/null | sed 's/$/;/' \
          | m_replica >/dev/null 2>&1 || true
  done

  echo "[mariadb] CHANGE MASTER"
  m_replica -e "
      STOP SLAVE;
      CHANGE MASTER TO
          MASTER_HOST='$PRIMARY', MASTER_PORT=3306,
          MASTER_USER='$RUSER', MASTER_PASSWORD='$RPASS',
          MASTER_USE_GTID=slave_pos,
          MASTER_CONNECT_RETRY=10;
      START SLAVE;"

  sleep 5
  st=$(m_replica -e "SHOW SLAVE STATUS\G" 2>/dev/null)
  if printf '%s\n' "$st" | grep -q "Slave_IO_Running: Yes" && \
     printf '%s\n' "$st" | grep -q "Slave_SQL_Running: Yes"; then
      echo "[mariadb] ✓ replikasyon çalışıyor"
      printf '%s\n' "$st" | grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Gtid_IO_Pos"
      exit 0
  fi
  echo "[mariadb] ✗ replikasyon başlamadı:" >&2
  printf '%s\n' "$st" | grep -E "Last_.*Error" | grep -vE ": *$" >&2 || true
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
