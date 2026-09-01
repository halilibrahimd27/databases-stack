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

# Bir düğümdeki KULLANICI TABLOSU sayısı. "Kaynak boş mu?" sorusunu ŞEMA
# düzeyinde sormak işe yaramıyordu: compose `MARIADB_DATABASE=defaultdb`
# verdiği için MariaDB, AZ ÖNCE SİLİNİP sıfırdan açılmış bir düğümde bile o
# şemayı ilk açılışta mutlaka yaratır (root SUPER olduğundan read_only da
# engellemez). Yani "boş düğüm" hiçbir zaman boş görünmüyor, boşluk kemeri hiç
# ateşlemiyordu. Tablo saymak DEFAULT_DATABASE'in adından ve varlığından
# bağımsızdır.
user_tables() {
    "$1" -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys');" 2>/dev/null | tr -d '[:space:]'
}

# Bir düğümün ŞU ANKİ GTID KONUMU: alan başına TEK üçlü ("0-2-24"), yani
# "0 numaralı alanda gördüğüm son işlem, 2 numaralı sunucunun 24. işlemidir".
node_gtid_pos() {
    "$1" -N -e "SELECT @@gtid_current_pos;" 2>/dev/null | tr -d '[:space:]'
}

# Bir düğümün GTID GEÇMİŞİ — "ben neyi biliyorum?" sorusunun cevabı.
#   gtid_binlog_state : bu düğümün binlog'unda yazmış HER alan-sunucu çifti için
#                       ayrı bir üçlü ("0-1-19,0-2-24"). gtid_binlog_pos'un
#                       aksine sunucuları tek satıra ezmez.
#   gtid_slave_pos    : düğümün SLAVE olarak uyguladığı son konum.
# Kapsama kararı bu ikisinin BİRLEŞİMİNE bakar: bir düğüm, kendi yazdıklarını
# ve replikasyonla uyguladıklarını bilir; başkasını bilmez.
node_gtid_history() {
    "$1" -N -e "SELECT @@gtid_binlog_state; SELECT @@gtid_slave_pos;" 2>/dev/null \
        | tr -d ' \t\r' | tr ',' '\n' | grep -E '^[0-9]+-[0-9]+-[0-9]+$' || true
}

# KAPSAMA (containment) ölçütü: hedefin konumundaki HER üçlü, kaynağın
# geçmişinde AYNI alan-sunucu çiftiyle ve EN AZ o sırayla var mı?
#   $1 = hedefin gtid konumu, $2 = kaynağın gtid geçmişi (satır satır)
# Çıktı:
#   yes      → hedefin gördüğü her şey kaynakta da var; üzerine yazmak veri kaybettirmez
#   no       → hedefte, kaynağın HİÇ görmediği yazılar var → TERS YÖN, dur
#   bos      → hedef hiç GTID bildirmiyor; kapsama kanıtlanamaz
#   okunmadi → konum çözümlenemedi (bağlantı yok / beklenmedik biçim); kanıt yok
gtid_covered() {
    printf '%s\n' "$2" | awk -v want="$1" '
        NF { split($0, s, "-"); k = s[1] "-" s[2]
             if (s[3]+0 > seen[k]+0) seen[k] = s[3]+0 }
        END {
            n = split(want, w, ",")
            for (i = 1; i <= n; i++) {
                if (w[i] == "") continue
                if (w[i] !~ /^[0-9]+-[0-9]+-[0-9]+$/) { print "okunmadi"; exit }
                split(w[i], t, "-"); k = t[1] "-" t[2]
                if (!(k in seen) || seen[k]+0 < t[3]+0) { print "no"; exit }
                c++
            }
            print (c ? "yes" : "bos")
        }'
}

# Ana kopya cevap verene kadar 30 sn bekler; $ro'ya read_only değerini yazar,
# hiç cevap alınamazsa boş bırakır. Tek atışlık prob şuna takılıyordu: uzun bir
# imaj çekimi sırasında ya da OOM sonrası yeniden başlarken ana kopya birkaç
# saniye geç cevap veriyor, betik de daha ilk temasta "bağlanılamadı" deyip
# vazgeçiyordu. Betikteki diğer bütün beklemeler zaten yeniden denemeli.
wait_primary_ro() {
    ro=""; i=0
    while [ $i -lt 10 ]; do
        ro="$(m_primary -N -e "SELECT @@read_only;" 2>/dev/null | tr -d '[:space:]')"
        [ -n "$ro" ] && break
        i=$((i+1)); sleep 3
    done
}

# Replikanın sistem şeması sağlam mı? Bu üç tablo MariaDB'nin kendi
# kurulumundan gelir; biri bile eksikse şema bozulmuştur.
sys_schema_ok() {
    n="$(m_replica -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='mysql' AND table_name IN ('gtid_slave_pos','proc','global_priv');" 2>/dev/null | tr -d '[:space:]')"
    [ "$n" = "3" ]
}

case "$PHASE" in
prepare)
  # prepare, kullanıcının replikasyon kurarken çarptığı İLK aşamadır ve attach
  # ile AYNI yönü izler — kemerleri de aynı olmalı. Eskiden burada hiçbir
  # kontrol yoktu: yön ters verildiğinde replikasyon kullanıcısı SESSİZCE
  # yanlış düğümde açılıyor (root SUPER olduğu için read_only bile engellemez),
  # betik "hazır" diyor, controller da başarı sayıp devam ediyordu. Arıza çok
  # sonra, replikada sebebi görünmeyen bir "Access denied" olarak patlıyordu.
  echo "[mariadb] yön: $PRIMARY (kaynak) → $STANDBY (hedef)"
  if [ "$PRIMARY" = "$STANDBY" ]; then
      echo "[mariadb] ✗ kaynak ve hedef aynı düğüm: $PRIMARY" >&2
      echo "[mariadb]   Yedek kopya, ana kopyadan FARKLI bir düğüm olmalı. Hiçbir şey yapılmadı." >&2
      exit 1
  fi

  wait_primary_ro
  if [ -z "$ro" ]; then
      echo "[mariadb] ✗ ana kopyaya bağlanılamadı: $PRIMARY" >&2
      echo "[mariadb]   Panelde bu veritabanının durumu 'çalışıyor' olmalı." >&2
      exit 1
  fi
  if [ "$ro" != "0" ]; then
      # Uyarı, hata değil: CREATE USER bu düğümde yine de çalışır. Ama ana kopya
      # olması gereken düğümün yazmaya kapalı olması, yönün yanlış verilmiş
      # olabileceğinin görünür tek işaretidir — kullanıcı bunu okuyabilmeli.
      echo "[mariadb] ⚠ ana kopya ($PRIMARY) şu an yazmaya kapalı (read_only)."
      echo "[mariadb]   Bu genelde sunucu yeniden başladıktan sonra olur ve kendiliğinden düzelir."
      echo "[mariadb]   Panelde 'ana kopya' olarak BAŞKA bir düğüm görünüyorsa işlemi durdurun."
  fi

  echo "[mariadb] binlog kontrolü"
  v=$(m_primary -N -e "SELECT @@log_bin;" 2>/dev/null | tr -d '[:space:]')
  # Bağlantı hatası ile AYAR hatası ayrı şeylerdir. Container kapalıyken sorgu
  # boş döner; eski sürüm buna da "log_bin kapalı, my.cnf'e bakın" diyordu.
  # Oysa config/mariadb/my.cnf'te `log_bin = mysql-bin` zaten yazılı: veritabanı
  # bilmeyen kullanıcı DOĞRU olan dosyayı defalarca düzenleyip servisi yeniden
  # başlatıyor, her seferinde aynı mesajı alıyor ve gerçek sebebi hiç öğrenmiyordu.
  if [ -z "$v" ]; then
      echo "[mariadb] ✗ ana kopyaya bağlanılamadı: $PRIMARY" >&2
      echo "[mariadb]   Panelde bu veritabanının durumu 'çalışıyor' olmalı." >&2
      exit 1
  fi
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

  echo "[mariadb] replika hazır olması bekleniyor…"
  i=0; while [ $i -lt 40 ]; do
      m_replica -e "SELECT 1" >/dev/null 2>&1 && break
      i=$((i+1)); sleep 3
  done
  [ $i -lt 40 ] || { echo "[mariadb] ✗ replika açılmadı" >&2; exit 1; }

  # Zaten bağlıysa tekrar kopyalama (uzun sürer, gereksiz). AMA "akışta olmak"
  # tek başına yetmez: bir kez YANLIŞ yönde kurulmuş topoloji de akışta görünür
  # ve her tekrar denemede "sağlıklı" diye raporlanırdı — kemerlerin hiçbiri o
  # topolojiyi bir daha denetlemiyordu. Akan bir replikada yönün GERÇEK kanıtı
  # Master_Host'tur; onu doğrulamadan kısayola girmiyoruz.
  # `-N` (--skip-column-names) BURADA KULLANILMAZ. Dikey (\G) çıktıda -N,
  # satırları değil ALAN ADLARINI siler: aynı sayıda satır gelir ama
  # "Slave_IO_Running: Yes" yerine yalnız "Yes" yazar. Alan adına grep atan
  # her kontrol bu yüzden HİÇ eşleşmez. Bu yüzden yukarıdaki iki kemer de fiilen ölüydü: "zaten akışta"
  # kısayolu hiç çalışmıyor (her çağrı baştan döküm alıyordu) ve ondan da
  # önemlisi, YANLIŞ kaynaktan akan bir topoloji hiç yakalanamıyordu. Gerçek
  # container'da ölçüldü: `mariadb -N -e 'SHOW SLAVE STATUS\G'` → sıfır satır,
  # `-N` olmadan → Master_Host dâhil tüm alanlar. (Aşağıdaki son doğrulama
  # zaten -N'siz çağırıyor; bu satır onunla tutarsızdı.)
  st="$(m_replica -e "SHOW SLAVE STATUS\G" 2>/dev/null || true)"
  if printf '%s\n' "$st" | grep -q "Slave_IO_Running: Yes"; then
      mh="$(printf '%s\n' "$st" | sed -n 's/^ *Master_Host: *//p' | head -1 | tr -d '[:space:]')"
      if [ "$mh" = "$PRIMARY" ]; then
          echo "[mariadb] ✓ replika zaten akışta (kaynak: $mh)"; exit 0
      fi
      echo "[mariadb] ✗ yedek kopya akışta ama YANLIŞ kaynaktan: '$mh' (beklenen: '$PRIMARY')" >&2
      echo "[mariadb]   Kopyalar birbirine ters bağlanmış olabilir. Hiçbir şey yapılmadı; veriler duruyor." >&2
      echo "[mariadb]   Panelde hangi kopyanın 'ana' olduğunu kontrol edip 'Yedek Kopyayı Yeniden Kur' deyin." >&2
      exit 1
  fi

  # BURADAN SONRASI DÖKÜM YOLUDUR. Kaynağa bağlanmayı gerektiren kontroller
  # buraya, dökümün hemen önüne taşındı. Yukarıda dururken zararsız bir tekrar
  # çağrıyı sert hataya çeviriyorlardı: sağlıklı akan bir replikada, kaynak o an
  # cevap vermiyor diye betik 1 dönüyor, controller da "yarım replika bırakılmaz"
  # kuralıyla ÇALIŞAN yedeği `docker rm -f` ile siliyordu.
  wait_primary_ro
  if [ -z "$ro" ]; then
      echo "[mariadb] ✗ ana kopyaya bağlanılamadı: $PRIMARY" >&2
      # "Başlatıp tekrar deneyin" tavsiyesi her durumda doğru DEĞİL: devirden
      # sonra eski kopya BİLEREK durdurulur (fence). Kullanıcı onu elle
      # başlatırsa eski verisiyle ikinci bir yazılabilir kopya olur — yani bu
      # tavsiye, veri kaybına götüren adımı tarif eder. Hedef yazmaya açık ve
      # doluysa ana kopyanın O olduğunu ölçebiliyoruz; o zaman ters konuşuruz.
      d_ro="$(m_replica -N -e "SELECT @@read_only;" 2>/dev/null | tr -d '[:space:]')"
      if [ "$d_ro" = "0" ] && [ "$(user_tables m_replica)" != "0" ]; then
          echo "[mariadb]   Diğer kopya ($STANDBY) şu an yazmaya açık ve içinde veri var:" >&2
          echo "[mariadb]   ana kopya büyük ihtimalle O. $PRIMARY ise devirden sonra bilerek" >&2
          echo "[mariadb]   durdurulmuş olabilir — ELLE BAŞLATMAYIN, eski verisiyle geri gelir." >&2
          echo "[mariadb]   Panelde 'Yedek Kopyayı Yeniden Kur' düğmesini kullanın." >&2
      else
          echo "[mariadb]   Panelde bu veritabanının durumu 'çalışıyor' olmalı; başlatıp tekrar deneyin." >&2
      fi
      exit 1
  fi
  if [ "$ro" != "0" ]; then
      # read_only YÖNÜN GÖSTERGESİ DEĞİLDİR ve bu daldan çıkış vermek panelden
      # çıkışı olmayan bir kilit yaratıyordu: yükseltilen düğüm compose'da
      # --read-only=ON ile yaratıldığı, promote ise yalnız çalışma anında
      # read_only=OFF yaptığı için o düğüm HER yeniden başlayışta read_only=ON
      # gelir. Yön doğruyken bile betik "yön ters" deyip reddediyor, kullanıcı
      # panele bakıp yönü onaylıyor ve her denemede aynı hatayı alıyordu.
      # Döküm zaten yalnızca OKUR; read-only bir ana kopyadan alınan kopya
      # sonuna kadar geçerlidir. Yön kararını aşağıdaki güncellik ölçümü verir.
      echo "[mariadb] ⚠ ana kopya ($PRIMARY) şu an yazmaya kapalı (read_only)."
      echo "[mariadb]   Kopyalamayı engellemez (döküm yalnız okur); bu genelde sunucu yeniden"
      echo "[mariadb]   başladıktan sonra görülür ve otomatik devir açıksa kendiliğinden düzelir."
  fi

  # SON VE EN ÖNEMLİ YÖN KONTROLÜ — hedefte, kaynağın BİLMEDİĞİ veri var mı?
  #
  # Bu kemer iki kez yazıldı ve iki kez de yanlış SORUYU ölçtü:
  #   1) "kaynakta hiç tablo yok ama hedefte var mı?" — devir sonrasının olağan
  #      hâlinde İKİ düğümde de veri vardır, biri bayattır; kemer hiç ateşlemedi.
  #   2) "hedefin GTID SIRASI kaynağınkinden büyük mü?" — sıra numarası
  #      GÜNCELLİK ölçüsü DEĞİLDİR. GTID "alan-sunucu-sıra" üçlüsüdür ve sıra,
  #      alan içinde sayaç gibi ilerler. Devirden sonra iki düğüm AYNI alanda
  #      AYRI kollara ayrılır: bayat eski primary kendi yazılarını 0-1-96…0-1-100
  #      diye sürdürür, yükseltilen canlı düğüm ise 0-2-96…0-2-98 diye. Sayıca
  #      BAYAT olan daha büyüktür (100 > 98) — yani ölçüt tam ters cevabı verir.
  #      Canlı üretimde doğrulandı: PRIMARY=bayat(0-1-100), STANDBY=canlı(0-2-98)
  #      → kemer sessiz kaldı, döküm canlı kopyanın üzerine basıldı.
  #
  # DOĞRU SORU "sıra büyük mü" değil, KAPSAMA'dır: hedefin gördüğü her işlem
  # kaynakta da VAR MI? Cevabı sunucu kimliğiyle birlikte aramak gerekir —
  # 0-2-98 ile 0-1-100 aynı alanda ama AYRI kollardır.
  #
  # (Denenip ELENDİ: kaynakta `SELECT MASTER_GTID_WAIT('<hedef konumu>',0)`.
  #  Gerçek MariaDB 11.4 ile ölçüldü: bu fonksiyon YALNIZ gtid_slave_pos'a bakar,
  #  düğümün kendi binlog'una değil. Hiç slave olmamış bir ana kopya KENDİ
  #  konumunu sorduğunda bile -1 döner. Yani yön doğruyken de "kapsanmıyor" der;
  #  dolu bir hedefe yapılan her meşru yeniden tohumlamayı reddederdi.)
  #
  # Ölçüt şu: hedefte veri varsa, hedefin konumundaki her alan-sunucu çifti
  # kaynağın GEÇMİŞİNDE (gtid_binlog_state + gtid_slave_pos) en az o sırayla
  # bulunmalı. Hedef boşsa (controller tohumlamadan önce hacmi siler) kaybedilecek
  # bir şey yoktur, kontrol aranmaz.
  n_src="$(user_tables m_primary)"
  n_dst="$(user_tables m_replica)"
  if [ "${n_src:-0}" = "0" ] && [ "${n_dst:-0}" != "0" ]; then
      echo "[mariadb] ✗ yön ters görünüyor: kaynakta ($PRIMARY) hiç tablo yok, hedefte ($STANDBY) veri var." >&2
      echo "[mariadb]   Kopyalama iptal edildi; hedefteki veriler OLDUĞU GİBİ duruyor, hiçbir şey silinmedi." >&2
      echo "[mariadb]   Panelde hangi kopyanın 'ana' (primary) olduğunu kontrol edip tekrar deneyin." >&2
      exit 1
  fi
  if [ "${n_dst:-0}" != "0" ]; then
      cover="$(gtid_covered "$(node_gtid_pos m_replica)" "$(node_gtid_history m_primary)")"
      if [ "$cover" = "yes" ]; then
          echo "[mariadb] ✓ hedefteki ($STANDBY) veriler kaynakta da var (GTID kapsaması doğrulandı)"
      else
          echo "[mariadb] ✗ hedefteki kopyada ($STANDBY), kaynakta ($PRIMARY) BULUNMAYAN veri var." >&2
          case "$cover" in
          no)
              echo "[mariadb]   İki kopya birbirinden ayrılmış: hedefte, kaynağın hiç görmediği" >&2
              echo "[mariadb]   yazılar var. Üzerine kopyalasaydık o yazılar geri getirilemezdi." >&2
              echo "[mariadb]   Bu genelde yönün ters verilmesidir: güncel veri $STANDBY üzerinde." >&2 ;;
          bos)
              echo "[mariadb]   Hedefte tablolar var ama hiç GTID kaydı yok; verinin kaynaktan" >&2
              echo "[mariadb]   geldiği KANITLANAMIYOR. Elle yüklenmiş ya da binlog'suz yazılmış olabilir." >&2 ;;
          *)
              echo "[mariadb]   GTID konumu okunamadı, bu yüzden güvenli olduğu KANITLANAMADI." >&2
              echo "[mariadb]   Her iki veritabanının da 'çalışıyor' durumda olduğundan emin olun." >&2 ;;
          esac
          if [ "${FORCE_SEED:-0}" != "1" ]; then
              echo "[mariadb]   Hiçbir şey yapılmadı; her iki kopyadaki veriler olduğu gibi duruyor." >&2
              echo "[mariadb]   Doğru yol: panelde 'Eski kopyayı yeniden kur' — o işlem hedefin eskimiş" >&2
              echo "[mariadb]   verisini önce SİLER, sonra ana kopyadan baştan kopyalar." >&2
              echo "[mariadb]   (Hedefteki veriyi bilerek gözden çıkarıyorsanız: FORCE_SEED=1 ile çalıştırın.)" >&2
              exit 1
          fi
          echo "[mariadb] ⚠ FORCE_SEED=1 verildi — hedefteki ($STANDBY) veri ezilerek devam ediliyor." >&2
      fi
  fi

  dbs="$(user_dbs m_primary)"

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

  err_log="$(mktemp)"; dump_rc="$(mktemp)"
  if [ -n "$dbs" ]; then
      echo "[mariadb] kullanıcı veritabanları kopyalanıyor:" $dbs
      # --single-transaction: tabloları kilitlemeden tutarlı anlık görüntü.
      # --gtid + --master-data=1: dökümün başına `SET GLOBAL gtid_slave_pos=…`
      #   yazar → replika tam olarak doğru noktadan devam eder.
      #
      # DİKKAT — =1, =2 DEĞİL. `--master-data=2` aynı ifadeleri YORUM olarak
      # yazar; yani konum hiç uygulanmaz. Gerçek sunucuda ölçüldü: kaynağın
      # konumu 0-2-89 iken dökümde `-- SET GLOBAL gtid_slave_pos='0-2-89';`
      # satırı yorumluydu ve hedef kendi eski konumunda (0-2-9) kaldı. START
      # SLAVE, dökümde ZATEN bulunan 10..89 arası işlemleri tekrar oynatıp
      # "Error_code: 1062 — HA_ERR_FOUND_DUPP_KEY" ile öldü. Belirtisi
      # kafa karıştırıcıydı: döküm başarılı, hesaplar taşındı, CHANGE MASTER
      # çalıştı, sonra replikasyon "yinelenen anahtar" dedi.
      #
      # DÖKÜMÜN ÇIKIŞ KODU DOSYAYLA TAŞINIR. POSIX sh'te `pipefail` yoktur;
      # boru hattının durumu SON komuttan (yani yüklemeyi yapan m_replica'dan)
      # gelir. Sinyalle ölen bir döküm (OOM-killer, container restart; çıkış
      # 137) stderr'e tek satır bile yazmaz, dolayısıyla aşağıdaki "error"
      # taraması da onu göremez: yükleme yarıda kesilir, betik hiç durmadan
      # CHANGE MASTER'a geçer ve "✓ replikasyon çalışıyor" der. Geriye SESSİZCE
      # YARIM bir replika kalır — sonraki devir onu primary'ye yükseltirse veri
      # kaybolur. `|| echo $?` yalnız döküm başarısız olduğunda dosyaya yazar.
      : > "$dump_rc"
      if ! { MYSQL_PWD="$PASS" docker exec -e MYSQL_PWD "$PRIMARY" mariadb-dump -u root \
                 --databases $dbs \
                 --single-transaction --quick --gtid --master-data=1 \
                 --routines --triggers --events 2>"$err_log" \
             || echo "$?" > "$dump_rc"; } \
            | m_replica 2>>"$err_log"; then
          echo "[mariadb] ✗ kopya aktarımı başarısız (yükleme hatası):" >&2
          tail -5 "$err_log" >&2; rm -f "$err_log" "$dump_rc"; exit 1
      fi
      if [ -s "$dump_rc" ]; then
          echo "[mariadb] ✗ kopya ALINAMADI: mariadb-dump çıkış kodu $(cat "$dump_rc")" >&2
          echo "[mariadb]   Yedeğe eksik veri yazılmış olabilir; replikasyon başlatılmadı." >&2
          echo "[mariadb]   (128'den büyük bir kod, dökümün bellek yetersizliğinden öldürüldüğü anlamına gelir.)" >&2
          tail -5 "$err_log" >&2; rm -f "$err_log" "$dump_rc"; exit 1
      fi
      # Kısmi yükleme replikasyonu sessizce bozar; hata geçiştirilmez.
      if grep -qi "error" "$err_log" 2>/dev/null; then
          echo "[mariadb] ✗ kopya aktarımında hata:" >&2
          grep -i "error" "$err_log" | head -5 >&2; rm -f "$err_log" "$dump_rc"; exit 1
      fi
  else
      # Hiç kullanıcı veritabanı yok — taşınacak veri de yok. GTID konumunu
      # yine de vermeliyiz, yoksa replika binlog'un BAŞINDAN okumaya çalışır.
      echo "[mariadb] taşınacak kullanıcı veritabanı yok, yalnız GTID konumu alınıyor"
      pos="$(m_primary -N -e "SELECT @@gtid_binlog_pos;" 2>/dev/null | tr -d '[:space:]')"
      m_replica -e "SET GLOBAL gtid_slave_pos='$pos';" >/dev/null
  fi
  rm -f "$err_log" "$dump_rc"

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

  # Konumun gerçekten uygulandığını DOĞRULA. Uygulanmazsa START SLAVE, dökümde
  # zaten bulunan işlemleri tekrar oynatır ve yinelenen anahtar hatasıyla ölür;
  # üstelik bu, dökümün kendisi başarılı göründüğü için teşhisi zor bir arızadır.
  hedef_pos="$(m_replica -N -e "SELECT @@gtid_slave_pos;" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$hedef_pos" ]; then
      echo "[mariadb] ✗ GTID konumu hedefe uygulanmadı — döküm konumu taşımamış." >&2
      echo "[mariadb]   START SLAVE bu hâlde dökümdeki işlemleri tekrar oynatır" >&2
      echo "[mariadb]   ve 'yinelenen anahtar' hatasıyla ölür. Durduruldu." >&2
      exit 1
  fi
  echo "[mariadb] GTID konumu: $hedef_pos"

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
  # Buradaki `|| true` BİLEREK duruyor: kalan bir `repl` hesabı hiçbir şey
  # biriktirmez, ana kopya kapalıyken de silinemez. Hata verirsek controller
  # "temizlik başarısız" deyip yedeği kaldırmaz ve kullanıcı hiçbir zararı
  # olmayan bir kalıntı yüzünden kilitlenir. (PostgreSQL'de tam tersi:
  # orada kalıntı diski doldurur, o yüzden orası doğrulanıp hata verir.)
  echo "[mariadb] replikasyon kullanıcısı kaldırılıyor: $RUSER"
  m_primary -e "DROP USER IF EXISTS '$RUSER'@'%'; FLUSH PRIVILEGES;" 2>/dev/null || true
  echo "[mariadb] temizlendi"
  ;;

*)
  # Tanınmayan faz SESSİZCE 0 DÖNMEZ. `case` hiçbir dala uymadığında 0 döner;
  # controller bunu "yapıldı" sayar ve bir sonraki adıma geçer. Redis betiğinde
  # tam olarak bu sınıf hata yaşandı (eksik faz, yanlış dala düşen çağrı).
  echo "[mariadb] ✗ bilinmeyen faz: '$PHASE' (prepare | attach | cleanup)" >&2
  exit 2
  ;;
esac
