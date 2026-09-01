#!/bin/sh
# MariaDB failover.
#   ready   <servis>  → yükseltmeye HAZIR mı? (0=evet)  ← fence'ten ÖNCE sorulur
#   promote <servis>  → replikayı primary yap (idempotent)
#   check   <servis>  → yazılabilir primary mi? (0=evet)
set -eu
ACTION="${1:-check}"; SVC="${2:-mariadb-replica}"
PASS="${MARIADB_PASSWORD:-$DB_PASSWORD}"

# m()  — sessiz sorgu (durum okuma; hata gürültüsü istemiyoruz)
# mq() — hatası GÖRÜNEN komut. Yükseltme komutlarının sessizce yutulması,
#        "read_only kapandı ama betik yine de 1 döndü" gibi teşhis edilmesi
#        zor arızalara yol açıyordu.
m()  { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$SVC" mariadb -u root -N -e "$1" 2>/dev/null; }
mq() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$SVC" mariadb -u root -N -e "$1" 2>&1; }

is_primary() {
    ro="$(m 'SELECT @@read_only;' | tr -d '[:space:]')"
    io="$(m 'SHOW SLAVE STATUS\G' | grep -c 'Slave_IO_Running: Yes' || true)"
    [ "$ro" = "0" ] && [ "$io" = "0" ]
}

case "$ACTION" in
check) is_primary ;;

ready)
  # Ana kopya bu noktada çoktan ölmüş olabilir; bu yüzden CANLI bağlantı
  # aramıyoruz (IO thread "Connecting" olacaktır). Aradığımız şey replikanın
  # gerçekten senkron olduğunun kanıtı: SQL (uygulama) iş parçacığı sağlam mı.
  # Hiç veri almamış ya da replikasyonu kırık bir replikayı primary yapmak
  # SESSİZ VERİ KAYBIDIR — o yüzden burada dururuz ve ana kopyaya dokunmayız.
  if is_primary; then echo "[mariadb] $SVC zaten primary"; exit 0; fi
  st="$(m 'SHOW SLAVE STATUS\G' || true)"
  if [ -z "$st" ]; then
      echo "[mariadb] ✗ $SVC replika olarak yapılandırılmamış" >&2; exit 1
  fi
  if ! printf '%s\n' "$st" | grep -q 'Slave_SQL_Running: Yes'; then
      echo "[mariadb] ✗ replikasyon sağlıklı değil — yükseltme veri kaybına yol açar" >&2
      printf '%s\n' "$st" | grep -E 'Last_SQL_Error|Last_IO_Error' \
          | grep -vE ': *$' >&2 || true
      exit 1
  fi
  echo "[mariadb] $SVC yükseltmeye hazır"
  ;;

promote)
  if is_primary; then echo "[mariadb] $SVC zaten primary"; exit 0; fi
  echo "[mariadb] $SVC yükseltiliyor…"
  # Relay log'daki kalan olayları uygulamasını bekle — aksi halde primary'nin
  # gönderdiği ama henüz işlenmemiş işlemler kaybolur.
  m 'STOP SLAVE IO_THREAD;' >/dev/null 2>&1 || true
  i=0
  while [ $i -lt 30 ]; do
      relay="$(m 'SHOW SLAVE STATUS\G' | grep -c 'Slave_SQL_Running_State: Slave has read all relay log' || true)"
      [ "$relay" = "1" ] && break
      i=$((i+1)); sleep 1
  done
  # DİKKAT: MariaDB'de `super_read_only` YOKTUR (MySQL'e özgüdür). Eski sürüm
  # onu da yazıyordu: RESET SLAVE ALL ve read_only=OFF uygulanıyor, sonra
  # "Unknown system variable" ile çıkış 1 dönüyordu. Controller devri BAŞARISIZ
  # sayıp yönlendirmeyi güncellemiyor, eski primary de fence edilmiş kaldığı
  # için veritabanı TAMAMEN ERİŞİLEMEZ kalıyordu. Gerçek bir olaydı.
  out="$(mq 'STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=OFF;')" || {
      echo "[mariadb] yükseltme komutu uyarı verdi: $out" >&2
  }
  if is_primary; then
      echo "[mariadb] ✓ $SVC artık primary (yazmaya açık)"
      exit 0
  fi
  echo "[mariadb] ✗ yükseltme doğrulanamadı: $out" >&2; exit 1
  ;;
esac
