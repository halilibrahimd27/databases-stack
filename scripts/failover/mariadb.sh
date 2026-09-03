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
# İKİ AYRI YARDIMCI — ve aradaki fark bir kere gerçek bir arızaya yol açtı.
#
# `-N` (--skip-column-names) DİKEY çıktıda (\G) ALAN ADLARINI DA siler: satır
# sayısı aynı kalır ama "Slave_IO_Running: Yes" yerine yalnız "Yes" gelir.
# Bu betikteki bütün SHOW SLAVE STATUS kontrolleri o adlara grep atıyordu,
# dolayısıyla HİÇBİRİ eşleşmiyordu. Sonucu şuydu: replikasyon sapasağlam
# akarken (Master_Host: mariadb, IO: Yes, SQL: Yes) `ready` "replika olarak
# yapılandırılmamış" diyordu — yani veri kaybını önlemek için konan kapı HER
# ZAMAN reddediyor ve MariaDB'de otomatik devir hiç çalışmıyordu. Ürünün
# başlıca özelliği sessizce kayıptı; uçtan uca test paketi ortaya çıkardı.
#
# m()  → tek değerli sorgular (SELECT @@read_only): -N ile, çıplak değer gelsin
# mv() → DİKEY sorgular (SHOW SLAVE STATUS\G): -N YOK, alan adları korunsun
m()  { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$SVC" mariadb -u root -N -e "$1" 2>/dev/null; }
# CONTAINER ÇALIŞMIYORSA BUNU KESİN BİLİYORUZ — öyle söylemeliyiz.
# Boş cevabı "kötü sonuç" diye yorumlamak bu projenin savaştığı hatanın ta
# kendisi: ölçülemeyeni ölçülmüş gibi göstermek. Ölçüldü — kapalı bir düğüm
# için ürün "hiç WAL almamış, yükseltme veri kaybına yol açar" diyordu;
# doğru cümle "düğüm çalışmıyor"du ve insan yanlış yerde arıyordu.
ayakta_mi() {   # <servis> → 0 çalışıyor
    [ "$(docker inspect -f "{{.State.Running}}" "$1" 2>/dev/null)" = "true" ]
}

mv() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$SVC" mariadb -u root    -e "$1" 2>/dev/null; }
mq() { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$SVC" mariadb -u root -N -e "$1" 2>&1; }

is_primary() {
    ro="$(m 'SELECT @@read_only;' | tr -d '[:space:]')"
    io="$(mv 'SHOW SLAVE STATUS\G' | grep -c 'Slave_IO_Running: Yes' || true)"
    [ "$ro" = "0" ] && [ "$io" = "0" ]
}

case "$ACTION" in
check) is_primary ;;

ready)
  if ! ayakta_mi "$SVC"; then
      echo "[mariadb] ✗ $SVC çalışmıyor — yükseltilecek düğüm yok" >&2
      exit 3
  fi
  # SIRA ÖNEMLİ. Önce "replika olarak yapılandırılmış mı" diye bakarız; ancak
  # ondan sonra "zaten primary mi" kısayoluna düşeriz. Ters sırada bakan eski
  # sürüm, SQL iş parçacığı ÖLMÜŞ ama read_only bayrağı kapalı kalmış bozuk bir
  # replikayı "zaten primary" sanıp devre izin veriyordu; gerçek sunucuda bir
  # satır böyle kayboldu.
  #
  # Ana kopya bu noktada çoktan ölmüş olabilir; bu yüzden CANLI bağlantı
  # ARAMIYORUZ (IO thread "Connecting" olacaktır). Aradığımız şey, replikanın
  # aldığı olayları gerçekten UYGULAYABİLDİĞİNİN kanıtı.
  st="$(mv 'SHOW SLAVE STATUS\G' 2>/dev/null || true)"
  if [ -n "$st" ]; then
      if printf '%s\n' "$st" | grep -q 'Slave_SQL_Running: Yes'; then
          echo "[mariadb] $SVC yükseltmeye hazır"
          exit 0
      fi
      echo "[mariadb] ✗ replikasyon sağlıklı değil — yükseltmek veri kaybı olur" >&2
      printf '%s\n' "$st" | grep -E 'Last_SQL_Error|Last_IO_Error'           | grep -vE ': *$' >&2 || true
      exit 1
  fi
  # Replikasyon hiç yapılandırılmamış: ya daha önce yükseltilmiş (RESET SLAVE
  # ALL) ya da hiç kurulmamış. Yazılabilir ise yarım kalmış bir devrin
  # kurtarılabilmesi için yükseltilmiş kabul ederiz.
  if is_primary; then echo "[mariadb] $SVC zaten primary"; exit 0; fi
  echo "[mariadb] ✗ $SVC replika olarak yapılandırılmamış" >&2
  exit 1
  ;;

promote)
  if is_primary; then echo "[mariadb] $SVC zaten primary"; exit 0; fi
  echo "[mariadb] $SVC yükseltiliyor…"
  # Relay log'daki kalan olayları uygulamasını bekle — aksi halde primary'nin
  # gönderdiği ama henüz işlenmemiş işlemler kaybolur.
  m 'STOP SLAVE IO_THREAD;' >/dev/null 2>&1 || true
  i=0
  while [ $i -lt 30 ]; do
      relay="$(mv 'SHOW SLAVE STATUS\G' | grep -c 'Slave_SQL_Running_State: Slave has read all relay log' || true)"
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
