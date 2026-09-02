#!/bin/bash
# =============================================================================
# databases-stack — E2E: YEDEKLEME VE GERİ YÜKLEME
# =============================================================================
# Bu betik CANLI bir kuruluma karşı çalışır ve tek bir soruyu cevaplar:
#
#     FELAKET GÜNÜ ELİMİZDEKİ DOSYA VERİYİ GERİ GETİRİYOR MU?
#
# "Container ayakta" ya da "yedek dosyası üretildi" bu sorunun cevabı DEĞİLDİR.
# Bir yedeğin geçerliliği ancak GERİ YÜKLENİP verinin geldiği görülünce
# kanıtlanır. Bu yüzden yedeklenebilen her motor için şu tur koşuluyor:
#
#     veri yaz → yedek al → verify → VERİYİ SİL → geri yükle → veriyi geri oku
#
# Asıl kanıt son adımdır; öncekiler yalnızca onun ön koşuludur. Ayrıca ürünün
# geçmişte GERÇEKTEN yaşadığı arızalar için negatif testler var: kesik dosyaya
# "doğrulandı" demek, yabancı dosyayla geri yükleyip veriyi silmek ve bir
# motorun yedeği patlayınca bütün turun ortasından kesilmesi.
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/backup.sh                  tüm motorlar + negatif testler
#     ./scripts/e2e/backup.sh mariadb redis    yalnız bu motorlar
#
# Ayarlar (ortam değişkeni):
#     E2E_GERI_YUKLEME=0    yıkıcı adımı atla (yalnız yedek al + doğrula)
#     E2E_NEO4J_OFFLINE=1   Neo4j'yi DURDURUP yedekle (Community'de tek yol)
#     E2E_TUR=0             "bir motor patlarsa tur ölüyor mu" testini atla
#     E2E_YEDEKLERI_KORU=1  testin ürettiği yedek dosyalarını silme
#     E2E_YEDEK_SURESI / E2E_GERI_SURESI / E2E_TUR_SURESI / …  zaman aşımı (sn)
#
# ⚠ YIKICI ADIM: geri yükleme, o motorun verisini YEDEK ANINA döndürür. Test
#   yedeği turun hemen başında aldığı için normal şartlarda kayıp olmaz; ama
#   test sürerken BAŞKASI veri yazarsa o yazma geri yüklemeyle kaybolur.
#   Üretimde bakım penceresinde çalıştırın ya da E2E_GERI_YUKLEME=0 verin.
#   (Redis ve Neo4j adımları ilgili container'ı kısa süreliğine durdurur.)
#
# set -e YOK: her kontrol tek tek raporlanmalı. İlk hatada ölen bir test,
# asıl bilgiyi (hangi motorun geri yüklenemediğini) hiç göstermez.
#
# SONUÇ TÜRLERİ ORTAK KÜTÜPHANEDEN (scripts/e2e/lib.sh) gelir ve DÖRT tanedir:
#   t_ok      ölçtük, doğru çıktı
#   t_fail    ölçtük, yanlış çıktı
#   t_skip    ÖN KOŞUL YOK (motor kapalı, ürün o motora geri yükleme sunmuyor);
#             meşrudur, çıkış kodunu etkilemez
#   t_unknown ÖLÇEMEDİK (docker cevap vermedi, sorgu düştü, komut askıda kaldı,
#             test dosyası üretilemedi) — BAŞARISIZ SAYILIR.
# Bu paketin denetiminde bulunan hataların hepsi son iki durumun t_ok'a
# düşmesiydi: ölçüm aracı bozulunca kontrol "geçti" yazıyordu. Sayaçlar ve
# çıkış kodu da kütüphanede: hiçbir kontrol çalışmadıysa çıkış 2 — yani "her
# şey yeşil" değil, "hiçbir şey ölçülmedi".
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

# Ortak koşum kütüphanesi common.sh'TEN SONRA gelir (renkleri ondan alır).
[ -r scripts/e2e/lib.sh ] \
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi olmadan bu paket ölçüm yapamaz."
E2E_SUITE="backup"
source scripts/e2e/lib.sh

BACKUP_DIR="${BACKUP_DIR:-$STACK_ROOT/backups}"
LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
PROJE="${STACK_PROJECT:-databases-stack}"

# ------------------------------------------------------------ zaman aşımı ---
# Hiçbir bekleme sonsuz değil. `timeout` yoksa komutlar yine çalışır ama bunu
# kullanıcıya SÖYLÜYORUZ: askıda kalmış bir teste "sürüyor" demek, testin
# çöktüğünü hiç görmemekten beterdir.
ZAMAN=()
if command -v timeout >/dev/null 2>&1; then ZAMAN=(timeout -k 10); fi

SURE_YEDEK="${E2E_YEDEK_SURESI:-900}"      # tek motorun tam yedeği
SURE_GERI="${E2E_GERI_SURESI:-900}"        # tek motorun geri yüklenmesi
SURE_DOGRULA="${E2E_DOGRULA_SURESI:-300}"  # verify (arşivi baştan sona okur)
SURE_TUR="${E2E_TUR_SURESI:-2400}"         # `backup all` turu
SURE_ISTEMCI="${E2E_ISTEMCI_SURESI:-60}"   # tek sorgu / istemci çağrısı
SURE_OKUMA="${E2E_OKUMA_SURESI:-180}"      # geri yükleme sonrası veriyi bekleme

zaman_asimi() {   # zaman_asimi <saniye> <komut…>
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}

# Ölçüm ARACI asıldıysa sonuç "ürün reddetti" değil "ÖLÇEMEDİK"tir: timeout(1)
# zaman aşımında 124, -k ile öldürmek zorunda kalınca 137 döner. Denetimin
# bulduğu en pahalı kalıp buydu — asılı kalan bir verify/restore çağrısı bütün
# negatif kontrollerde "doğru şekilde reddetti" diye YEŞİL yazılıyordu.
asildi_mi() { [ "${1:-0}" -eq 124 ] || [ "${1:-0}" -eq 137 ]; }

# docker'ın kendisi cevap veriyor mu? container_running false döndüğünde iki
# ayrı ihtimal var: motor kapalı (ATLANDI, meşru) ya da docker ölü
# (ÖLÇÜLEMEDİ). Ayırmadan atlamak, docker daemon'ı düşmüş bir makinede bütün
# paketi "atlandı, sorun yok" diye gösterir.
docker_yasiyor() { docker ps -q >/dev/null 2>&1; }

# --------------------------------------------------------- geçici alan/log --
E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-yedek-XXXXXX")" || die "Geçici dizin açılamadı."
SON_CIKTI="$E2E_TMP/son.out"
: > "$SON_CIKTI"
mkdir -p "$LOG_DIR"
E2E_LOG="$LOG_DIR/e2e-backup_$(date +%Y%m%d_%H%M%S).log"
: > "$E2E_LOG"

# Çalıştırılan her ürün komutunun tam çıktısı log'a gider; ekranda yalnız
# kontrol satırları kalır. Son komutun çıktısı ayrıca SON_CIKTI'da durur —
# hata ayrıntısını oradan alıp DÜŞTÜ satırına yazıyoruz, böylece kullanıcı
# log dosyasını açmadan da ne olduğunu görür.
# stdin /dev/null: backup.sh'ın geri yükleme onayı (`read`) terminal olmayan
# bir ortamda bizi sonsuza kadar bekletmesin.
calistir() {   # calistir <saniye> <açıklama> <komut…>
    local sn="$1" ne="$2"; shift 2
    { printf '\n===== %s :: %s =====\n' "$(date '+%F %T')" "$ne"
      printf 'komut: %s\n' "$*"; } >> "$E2E_LOG"
    local rc=0
    zaman_asimi "$sn" "$@" > "$SON_CIKTI" 2>&1 < /dev/null || rc=$?
    cat "$SON_CIKTI" >> "$E2E_LOG"
    [ "$rc" -eq 124 ] && printf '(ZAMAN AŞIMI: %s sn)\n' "$sn" >> "$E2E_LOG"
    printf '(çıkış kodu: %s)\n' "$rc" >> "$E2E_LOG"
    return "$rc"
}
# Kasten bozuk dosyalarla yapılan çağrılar için: backup.sh'ın kendi günlüğünü
# GEÇİCİ dizine yönlendirir. Yoksa "Yedeğin İÇİ BOŞ: mariadb_full_e2e-bos…"
# gibi satırlar logs/backup_<tarih>.log dosyasına düşer ve ertesi sabah gece
# yedeğini inceleyen operatör, testin ürettiği sahte alarmları gerçek sanır.
# Gerçek motor yedekleri BİLEREK bunun dışında: onların günlüğü ürünün kendi
# yerinde kalmalı.
calistir_izole() {
    ( export LOG_DIR="$E2E_TMP"; calistir "$@" )
}
son_ozet() {   # DÜŞTÜ satırına yazılacak kısa ayrıntı
    local s
    s="$(tr -d '\r' < "$SON_CIKTI" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 2 | tr '\n' ' ')"
    printf '%s' "${s:-çıktı yok}"
}
son_icerir() { grep -aqF "$1" "$SON_CIKTI" 2>/dev/null; }

# Kilit çakışması ÜRÜN HATASI DEĞİLDİR: gece yedeği ya da elle başlatılmış bir
# iş sürüyorsa backup.sh doğru davranıp reddediyor. Bunu DÜŞTÜ saymak, testi
# cron saatlerinde güvenilmez yapardı.
kilit_carpismasi() { son_icerir "kilidi tutuyor"; }

# --------------------------------------------------------- ölçüm yardımcıları
# Bir dizinde, verilen zaman işaretinden SONRA oluşmuş en yeni .gz dosyası.
# ÇIKIŞ KODU ÜÇ DEĞERLİ: 0 bulundu · 1 yok · 2 ÖLÇEMEDİK (dizin taranamadı).
# Eskiden arama bir boru hattının içindeydi ve `find`in çıkış kodu son komutta
# (cut) kayboluyordu: bozuk bir tarama ile "dosya üretilmedi" aynı sonuca
# düşüyordu — oysa biri ürün hatası, öbürü ölçüm yokluğu.
en_yeni_gz() {   # en_yeni_gz <dizin> <isaret_dosyasi>
    local dizin="$1" isaret="$2"
    [ -d "$dizin" ] || return 1
    local ham="$E2E_TMP/bul.$$"
    if ! find "$dizin" -type f -name '*.gz' -newer "$isaret" -print > "$ham" 2>>"$E2E_LOG"; then
        rm -f "$ham"; return 2
    fi
    local -a adaylar=(); local satir yol
    while IFS= read -r satir; do [ -n "$satir" ] && adaylar+=("$satir"); done < "$ham"
    rm -f "$ham"
    [ "${#adaylar[@]}" -gt 0 ] || return 1
    if [ "${#adaylar[@]}" -eq 1 ]; then printf '%s' "${adaylar[0]}"; return 0; fi
    yol="$(ls -1t -- "${adaylar[@]}" 2>>"$E2E_LOG" | head -1)"
    [ -n "$yol" ] || return 2
    printf '%s' "$yol"
}

# Dizindeki .gz sayısı. rc=2 → sayılamadı. "0 dosya" ile "sayamadım" farklı.
gz_sayisi() {   # gz_sayisi <dizin>
    local dizin="$1"
    [ -d "$dizin" ] || { printf '0'; return 0; }
    local ham="$E2E_TMP/say.$$" n
    if ! find "$dizin" -type f -name '*.gz' -print > "$ham" 2>>"$E2E_LOG"; then
        rm -f "$ham"; return 2
    fi
    n="$(wc -l < "$ham" | tr -d '[:space:]')"
    rm -f "$ham"
    case "${n:-}" in ''|*[!0-9]*) return 2 ;; esac
    printf '%s' "$n"
}

# Bir yolun bulunduğu dosya sistemindeki boş alan (KB); ölçülemezse rc=1.
# "df çalışmadı" ile "yer yok" aynı şey değil: ikincisini varsaymak bütün
# turları sahte bir sebeple atlatır ve paket hiçbir şey ölçmeden biter.
bos_kb() {   # bos_kb <yol>
    local kb; kb="$(df -Pk "$1" 2>>"$E2E_LOG" | awk 'NR==2 {print $4}')"
    case "${kb:-}" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$kb"
}

# Okuma DENEMESİ ile okuma SONUCU iki ayrı bilgidir: istemci hiç çalışmadıysa
# (docker exec düştü, parola yanlış, container yeniden başlıyor) elimizde
# "veri yok" değil ÖLÇÜM YOK vardır. Boş çıktıyı "kayıt silinmiş" saymak,
# geri yükleme kontrolünü kendi kendini kandıran bir kontrole çeviriyordu.
OKUNAN=""; OKUMA_RC=0
oku() {   # oku <eid> <container> <parola>  → OKUNAN, OKUMA_RC
    OKUNAN="$(veri_oku "$1" "$2" "$3")"; OKUMA_RC=$?
    return 0
}
kanit_var() { case "$OKUNAN" in *"$KANIT"*) return 0 ;; esac; return 1; }

# Geri yükleme container'ı yeniden başlatabiliyor; okumayı zaman sınırlı
# tekrarlıyoruz. Sonuç yine OKUNAN/OKUMA_RC'de.
veri_bekle() {   # veri_bekle <eid> <container> <parola> [saniye]
    local bitis=$(( $(date +%s) + ${4:-$SURE_OKUMA} ))
    while :; do
        oku "$1" "$2" "$3"
        [ "$OKUMA_RC" -eq 0 ] && kanit_var && return 0
        [ "$(date +%s)" -ge "$bitis" ] && return 1
        sleep 3
    done
}

# Arşivin HAM baytlarında BU KOŞUMUN değeri var mı?
#   0 var · 1 yok · 2 ÖLÇEMEDİK (gzip açamadı)
# grep -q erken çıkınca gzip SIGPIPE (141) alır; bu normaldir, o yüzden önce
# grep'in sonucuna bakıyoruz. Boru hattında kaybedilen çıkış kodu = sahte yeşil.
arsivde_ham_kanit() {   # arsivde_ham_kanit <dosya>
    local dosya="$1"; local -a ps
    gzip -dc "$dosya" 2>>"$E2E_LOG" | grep -qaF "$KANIT"
    ps=("${PIPESTATUS[@]}")
    [ "${ps[1]}" -eq 0 ] && return 0        # bulundu
    [ "${ps[0]}" -eq 0 ] || return 2        # arşiv baştan sona açılamadı
    [ "${ps[1]}" -eq 1 ] || return 2        # grep'in kendisi düştü
    return 1
}

# Arşivde, verilen desenlerin HEPSİNİ birden taşıyan bir üye adı var mı?
#   0 var · 1 yok · 2 ÖLÇEMEDİK (gzip/tar düştü)
arsivde_uye() {   # arsivde_uye <dosya> <desen…>
    local dosya="$1"; shift
    local ham="$E2E_TMP/uye.$$" suz="$E2E_TMP/uye.suz.$$" d g rc=0
    local -a ps
    gzip -dc "$dosya" 2>>"$E2E_LOG" | tar -tf - > "$ham" 2>>"$E2E_LOG"
    ps=("${PIPESTATUS[@]}")
    if [ "${ps[0]}" -ne 0 ] || [ "${ps[1]}" -ne 0 ]; then rm -f "$ham"; return 2; fi
    cp "$ham" "$suz" 2>>"$E2E_LOG" || { rm -f "$ham" "$suz"; return 2; }
    for d in "$@"; do
        grep -F -- "$d" "$suz" > "$suz.yeni" 2>>"$E2E_LOG"; g=$?
        if [ "$g" -eq 0 ]; then mv -f "$suz.yeni" "$suz"
        elif [ "$g" -eq 1 ]; then rc=1; break
        else rc=2; break
        fi
    done
    rm -f "$ham" "$suz" "$suz.yeni"
    return "$rc"
}

# ----------------------------------------------------------- katalog okuma --
# Motor listesi, uzantılar ve bağlantı bilgileri KATALOGTAN gelir. Burada sabit
# liste tutmak, katalog büyüdüğünde testin yeni motoru sessizce atlaması demek.
yedeklenebilir_motorlar() {
    python3 - "$CATALOG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if (e.get("backup") or {}).get("supported")))
PY
}
yedeklenemez_motorlar() {
    python3 - "$CATALOG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if not (e.get("backup") or {}).get("supported")))
PY
}
motor_bilgi() {   # motor_bilgi <id> → "ext|kullanıcı|veritabanı|parola_env|kind"
    python3 - "$CATALOG" "$1" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
e = [x for x in c["engines"] if x["id"] == sys.argv[2]]
if not e:
    sys.exit(1)
e = e[0]
b = e.get("backup") or {}
k = e.get("connection") or {}
print("|".join(str(x or "") for x in
               (b.get("ext"), k.get("username"), k.get("database"),
                k.get("password_env"), b.get("kind"))))
PY
}

# Geri yükleme desteği KATALOGDA YOK; ürünün gerçek arayüzü backup.sh'ın case
# dalıdır. Sabit liste yazmak yerine betiğin kendisine soruyoruz — yarın
# restore-clickhouse eklenirse bu test onu kendiliğinden kapsar.
geri_yukleme_var() {
    grep -qE "^restore_$1\(\)" scripts/backup.sh && grep -qE "restore-$1[|)]" scripts/backup.sh
}

# ------------------------------------------------------ sabit test nesneleri
# Adlar SABİT: yarım kalmış bir koşumdan sonra betik tekrar çalıştırıldığında
# aynı nesneleri bulup üzerine yazar ve sonunda siler (idempotentlik).
# DEĞER her koşumda farklı — geri yüklemeden sonra okunan şeyin gerçekten BU
# koşumun yazdığı kayıt olduğunu ancak böyle kanıtlayabiliriz. Sabit bir değer
# kullansaydık, hiç geri yüklenmemiş eski veri de testi geçirirdi.
E2E_DB="e2e_yedek"
E2E_TABLO="kanit"
E2E_ANAHTAR="kanit"
E2E_ES_INDEKS="e2e-yedek"
E2E_REDIS_ANAHTAR="e2e:yedek:kanit"
E2E_MINIO_KOVA="e2e-yedek"
E2E_RABBIT_POLICY="e2e_kanit"
KANIT="e2e-$(date +%Y%m%d%H%M%S)-$$"

DOKUNULAN=""        # veri yazdığımız motorlar (sonunda temizlenecek)
URETILEN=""         # bu koşumun ürettiği gerçek yedek dosyaları
ILK_GERCEK=""       # negatif testlerde kullanılacak gerçek yedek dosyası
TUR_DIZIN=""        # tur testinin yedek dizini (yarıda kesilse de silinsin)

# =============================================================================
# MOTOR İSTEMCİLERİ
# =============================================================================
# Host'ta veritabanı istemcisi YOK; her sorgu container'ın içindeki istemciyle
# çalışıyor. Parolalar komut satırına DEĞİL ortama konuyor (host'ta `ps`
# çıktısında görünmesinler) — backup.sh'taki desenin aynısı. Alt kabuk (…)
# şart: export'lar betiğin geri kalanına sızmasın.
my_sql() {   # my_sql <container> <parola> <sql>
    ( export MYSQL_PWD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e MYSQL_PWD "$1" \
          mariadb -u root -N -B -e "$3" ) 2>>"$E2E_LOG"
}
pg_sql() {   # pg_sql <container> <parola> <veritabanı> <sql>
    ( export PGPASSWORD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e PGPASSWORD "$1" \
          psql -U "${POSTGRES_USER:-root}" -d "$3" -tAq -c "$4" ) 2>>"$E2E_LOG"
}
mongo_js() { # mongo_js <container> <kullanıcı> <parola> <js>
    ( export MPW="$3" MUSER="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e MPW -e MUSER "$1" sh -c \
          'exec "$1" --quiet -u "$MUSER" -p "$MPW" --authenticationDatabase admin --eval "$2"' \
          sh "${MONGO_SHELL:-mongosh}" "$4" ) 2>>"$E2E_LOG"
}
redis_cli() { # redis_cli <container> <parola> <argümanlar…>
    local c="$1" pw="$2"; shift 2
    ( export REDISCLI_AUTH="$pw"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e REDISCLI_AUTH "$c" \
          redis-cli --no-auth-warning "$@" ) 2>>"$E2E_LOG"
}
ms_sql() {   # ms_sql <container> <parola> <sorgu>
    # -b: T-SQL hatasında sqlcmd sıfırdan farklı çıkış kodu verir. Bu olmadan
    # düşen sorgu "başarılı" sanılır (backup.sh'ta da aynı sebeple var).
    ( export SQLCMDPASSWORD="$2"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e SQLCMDPASSWORD "$1" \
          /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -h -1 -W \
          -Q "SET NOCOUNT ON; $3" ) 2>>"$E2E_LOG"
}
cql() {      # cql <container> <kullanıcı> <parola> <cql>
    ( export CQLSH_USER="$2" CQLSH_PW="$3"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e CQLSH_USER -e CQLSH_PW "$1" sh -c \
          'exec cqlsh -u "$CQLSH_USER" -p "$CQLSH_PW" -e "$1"' sh "$4" ) 2>>"$E2E_LOG"
}
ch_sql() {   # ch_sql <container> <kullanıcı> <parola> <sql>
    ( export CH_USER="$2" CH_PW="$3"
      zaman_asimi "$SURE_ISTEMCI" docker exec -e CH_USER -e CH_PW "$1" sh -c \
          'exec clickhouse-client --user "$CH_USER" --password "$CH_PW" --query "$1"' sh "$4" ) 2>>"$E2E_LOG"
}
es_istek() { # es_istek <container> <parola> <metod> <yol> [gövde]
    local c="$1" pw="$2" m="$3" yol="$4" govde="${5:-}"
    ( export EPW="$pw"
      if [ -n "$govde" ]; then
          zaman_asimi "$SURE_ISTEMCI" docker exec -e EPW "$c" sh -c \
              'exec curl -sS -u "elastic:$EPW" -X "$1" -H "Content-Type: application/json" -d "$3" "http://localhost:9200$2"' \
              sh "$m" "$yol" "$govde"
      else
          zaman_asimi "$SURE_ISTEMCI" docker exec -e EPW "$c" sh -c \
              'exec curl -sS -u "elastic:$EPW" -X "$1" "http://localhost:9200$2"' \
              sh "$m" "$yol"
      fi ) 2>>"$E2E_LOG"
}
neo_cypher() { # neo_cypher <container> <parola> <cypher>
    ( export NPW="$2" NUSER="${NEO4J_USER:-neo4j}"
      printf '%s\n' "$3" | zaman_asimi "$SURE_ISTEMCI" docker exec -i -e NPW -e NUSER "$1" sh -c \
          'exec cypher-shell -u "$NUSER" -p "$NPW" --format plain' ) 2>>"$E2E_LOG"
}
rabbit_ctl() { # rabbit_ctl <container> <argümanlar…>
    local c="$1"; shift
    zaman_asimi "$SURE_ISTEMCI" docker exec "$c" rabbitmqctl "$@" 2>>"$E2E_LOG"
}

# Motorun parolası: katalogtaki password_env, yoksa DB_PASSWORD — compose'daki
# `${X_PASSWORD:-${DB_PASSWORD}}` zincirinin aynısı.
motor_parolasi() {   # motor_parolasi <parola_env>
    local ad="$1" v=""
    [ -n "$ad" ] && v="${!ad:-}"
    [ -n "$v" ] || v="${DB_PASSWORD:-}"
    printf '%s' "$v"
}
motor_pw() { motor_parolasi "$(motor_bilgi "$1" | cut -d'|' -f4)"; }

# =============================================================================
# VERİ YAZ / OKU / SİL   (motor başına)
# =============================================================================
# veri_yaz     : kanıt kaydını yazar
# veri_oku     : kanıt kaydını basar (yoksa boş) — karşılaştırma KANIT değerini arar
# veri_yikim   : geri yüklemenin gerçekten iş yapması için kaydı SİLER
# veri_temizle : testin bıraktığı her şeyi kaldırır
veri_yaz() {   # veri_yaz <eid> <container> <parola>
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)
            my_sql "$C" "$pw" "CREATE DATABASE IF NOT EXISTS \`$E2E_DB\`;
                CREATE TABLE IF NOT EXISTS \`$E2E_DB\`.\`$E2E_TABLO\`
                    (k VARCHAR(64) PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB;
                REPLACE INTO \`$E2E_DB\`.\`$E2E_TABLO\` VALUES ('$E2E_ANAHTAR','$KANIT');" >/dev/null
            ;;
        postgresql)
            local var
            var="$(pg_sql "$C" "$pw" postgres "SELECT 1 FROM pg_database WHERE datname='$E2E_DB'")"
            if [ -z "$var" ]; then
                pg_sql "$C" "$pw" postgres "CREATE DATABASE \"$E2E_DB\"" >/dev/null || return 1
            fi
            pg_sql "$C" "$pw" "$E2E_DB" \
                "CREATE TABLE IF NOT EXISTS \"$E2E_TABLO\" (k text PRIMARY KEY, v text);
                 INSERT INTO \"$E2E_TABLO\" VALUES ('$E2E_ANAHTAR','$KANIT')
                 ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;" >/dev/null
            ;;
        mongodb)
            mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                "db.getSiblingDB('$E2E_DB').$E2E_TABLO.replaceOne({_id:'$E2E_ANAHTAR'},{_id:'$E2E_ANAHTAR',v:'$KANIT'},{upsert:true})" >/dev/null
            ;;
        redis)
            redis_cli "$C" "$pw" SET "$E2E_REDIS_ANAHTAR" "$KANIT" >/dev/null
            ;;
        mssql)
            # CREATE DATABASE kendi grubunda çalışmalı; aynı batch'te tablo
            # yaratmaya kalkışmak "database does not exist" hatası verir.
            ms_sql "$C" "$pw" "IF DB_ID('$E2E_DB') IS NULL CREATE DATABASE [$E2E_DB];" >/dev/null || return 1
            ms_sql "$C" "$pw" "IF OBJECT_ID('[$E2E_DB].dbo.$E2E_TABLO') IS NULL
                    CREATE TABLE [$E2E_DB].dbo.$E2E_TABLO (k varchar(64) PRIMARY KEY, v varchar(64));
                DELETE FROM [$E2E_DB].dbo.$E2E_TABLO WHERE k='$E2E_ANAHTAR';
                INSERT INTO [$E2E_DB].dbo.$E2E_TABLO VALUES ('$E2E_ANAHTAR','$KANIT');" >/dev/null
            ;;
        cassandra)
            cql "$C" "${CASSANDRA_USER:-cassandra}" "$pw" \
                "CREATE KEYSPACE IF NOT EXISTS $E2E_DB WITH replication={'class':'SimpleStrategy','replication_factor':1};
                 CREATE TABLE IF NOT EXISTS $E2E_DB.$E2E_TABLO (k text PRIMARY KEY, v text);
                 INSERT INTO $E2E_DB.$E2E_TABLO (k,v) VALUES ('$E2E_ANAHTAR','$KANIT');" >/dev/null
            ;;
        elasticsearch)
            # refresh=true: belge yazıldıktan hemen sonra aranabilir olsun —
            # yoksa yedek anında henüz segmente inmemiş olabilir.
            es_istek "$C" "$pw" PUT "/$E2E_ES_INDEKS/_doc/$E2E_ANAHTAR?refresh=true" "{\"v\":\"$KANIT\"}" >/dev/null
            ;;
        clickhouse)
            ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" "CREATE DATABASE IF NOT EXISTS $E2E_DB" >/dev/null || return 1
            ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" \
                "CREATE TABLE IF NOT EXISTS $E2E_DB.$E2E_TABLO (k String, v String) ENGINE=MergeTree ORDER BY k" >/dev/null || return 1
            ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" \
                "INSERT INTO $E2E_DB.$E2E_TABLO VALUES ('$E2E_ANAHTAR','$KANIT')" >/dev/null
            ;;
        rabbitmq)
            # RabbitMQ'da MESAJLAR yedeklenmiyor (ürün bilerek yalnız tanımları
            # alıyor), o yüzden kanıt da bir TANIM olmalı. Policy seçildi çünkü
            # deseni içinde KANIT değerini taşır: hem sunucudan hem de yedek
            # dosyasının içinden bu koşuma ait olduğu doğrulanabilir.
            rabbit_ctl "$C" add_vhost "$E2E_DB" >/dev/null 2>&1
            rabbit_ctl "$C" set_policy -p "$E2E_DB" "$E2E_RABBIT_POLICY" "^$KANIT\$" \
                '{"max-length":1}' --apply-to queues >/dev/null
            ;;
        minio)
            # MinIO imajında kabuk YOK (backup.sh de bu yüzden `docker cp`
            # kullanıyor: arşivi docker'a çıkarttırıyor). Nesneyi de aynı
            # yoldan koyuyoruz — imajın içinde hiçbir araç gerekmiyor.
            mkdir -p "$E2E_TMP/$E2E_MINIO_KOVA"
            printf '%s\n' "$KANIT" > "$E2E_TMP/$E2E_MINIO_KOVA/$E2E_TABLO.txt"
            zaman_asimi "$SURE_ISTEMCI" docker cp "$E2E_TMP/$E2E_MINIO_KOVA" "$C:/data/" >>"$E2E_LOG" 2>&1
            ;;
        neo4j)
            neo_cypher "$C" "$pw" "MERGE (n:E2EKanit {k:'$E2E_ANAHTAR'}) SET n.v='$KANIT';" >/dev/null
            ;;
        *) return 1 ;;
    esac
}

veri_oku() {   # veri_oku <eid> <container> <parola> → kanıt (yoksa boş)
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)    my_sql "$C" "$pw" "SELECT v FROM \`$E2E_DB\`.\`$E2E_TABLO\` WHERE k='$E2E_ANAHTAR';" ;;
        postgresql) pg_sql "$C" "$pw" "$E2E_DB" "SELECT v FROM \"$E2E_TABLO\" WHERE k='$E2E_ANAHTAR'" ;;
        mongodb)    mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                        "var d=db.getSiblingDB('$E2E_DB').$E2E_TABLO.findOne({_id:'$E2E_ANAHTAR'}); print(d?d.v:'')" ;;
        redis)      redis_cli "$C" "$pw" GET "$E2E_REDIS_ANAHTAR" ;;
        mssql)      ms_sql "$C" "$pw" "SELECT v FROM [$E2E_DB].dbo.$E2E_TABLO WHERE k='$E2E_ANAHTAR';" ;;
        cassandra)  cql "$C" "${CASSANDRA_USER:-cassandra}" "$pw" \
                        "SELECT v FROM $E2E_DB.$E2E_TABLO WHERE k='$E2E_ANAHTAR';" ;;
        elasticsearch) es_istek "$C" "$pw" GET "/$E2E_ES_INDEKS/_doc/$E2E_ANAHTAR" ;;
        clickhouse) ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" \
                        "SELECT v FROM $E2E_DB.$E2E_TABLO WHERE k='$E2E_ANAHTAR'" ;;
        rabbitmq)   rabbit_ctl "$C" list_policies -p "$E2E_DB" ;;
        # MinIO'da `docker exec … cat` yapılamaz (imajda kabuk/araç yok);
        # nesneyi docker'ın tar akışından okuyoruz.
        minio)      zaman_asimi "$SURE_ISTEMCI" docker cp \
                        "$C:/data/$E2E_MINIO_KOVA/$E2E_TABLO.txt" - 2>>"$E2E_LOG" | tar -xO 2>/dev/null ;;
        neo4j)      neo_cypher "$C" "$pw" "MATCH (n:E2EKanit {k:'$E2E_ANAHTAR'}) RETURN n.v;" ;;
        # Katalog büyüdüğünde tanımadığımız motor SESSİZCE boş dönüyordu; boş
        # çıktı "kayıt yok" gibi okunur, oysa doğrusu "okuma yolu tanımlı
        # değil" — yani ölçüm yapılmadı. Çağıran bunu OKUMA_RC'den görür.
        *) return 3 ;;
    esac
}

veri_yikim() { # veri_yikim <eid> <container> <parola> — geri yüklemeye iş çıkar
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)    my_sql "$C" "$pw" "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null ;;
        postgresql) pg_sql "$C" "$pw" postgres "DROP DATABASE IF EXISTS \"$E2E_DB\"" >/dev/null ;;
        mongodb)    mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                        "db.getSiblingDB('$E2E_DB').dropDatabase()" >/dev/null ;;
        redis)      redis_cli "$C" "$pw" DEL "$E2E_REDIS_ANAHTAR" >/dev/null ;;
        # MSSQL'de veritabanını düşürmek yerine SATIRI siliyoruz: RESTORE
        # DATABASE … WITH REPLACE zaten üzerine yazar; kanıt satırının geri
        # gelmesi aynı şeyi ispatlar, üstelik dosya yolu sürprizi olmadan.
        mssql)      ms_sql "$C" "$pw" "DELETE FROM [$E2E_DB].dbo.$E2E_TABLO WHERE k='$E2E_ANAHTAR';" >/dev/null ;;
    esac
}

# Yıkımı, SİLİNEN NESNENİN YOKLUĞUNU sorarak doğrular.
#   0 = silinmiş · 1 = hâlâ duruyor · 2 = ölçülemedi · 3 = bu motorda veritabanı
#   düşürülmüyor (çağıran eski yola düşsün)
#
# Neden ayrı bir soru: yıkım adımı mariadb/postgresql'de VERİTABANININ TAMAMINI
# düşürüyor. Sonra eski kontrol aynı tabloyu okumaya çalışıyordu ve istemci
# "veritabanı yok" diyerek sıfırdan farklı bir kod döndürüyordu (mariadb 1,
# psql 2). Test bunu "ölçemedim" sayıyordu — oysa veritabanının yokluğu,
# silmenin OLABİLECEK EN GÜÇLÜ kanıtıdır. Sonuç: yedekleme paketi, ürün
# kusursuz çalışırken iki motorda birden "ÖLÇÜLEMEDİ" veriyordu.
#
# Bu soru, nesne var da olsa yok da olsa CEVAP VEREBİLEN bir soru: sistem
# kataloğuna bakıyor, silinen nesneye dokunmuyor.
yikim_dogrula() { # yikim_dogrula <eid> <container> <parola>
    local eid="$1" C="$2" pw="$3" out rc
    case "$eid" in
        mariadb)
            out="$(my_sql "$C" "$pw"                  "SELECT COUNT(*) FROM information_schema.SCHEMATA                   WHERE SCHEMA_NAME='$E2E_DB';")"; rc=$? ;;
        postgresql)
            out="$(pg_sql "$C" "$pw" postgres                  "SELECT count(*) FROM pg_database WHERE datname='$E2E_DB'")"; rc=$? ;;
        mongodb)
            out="$(mongo_js "$C" "${MONGO_USER:-root}" "$pw"                  "print(db.getMongo().getDBNames().indexOf('$E2E_DB') >= 0 ? 1 : 0)")"; rc=$? ;;
        *) return 3 ;;
    esac
    [ "$rc" -ne 0 ] && return 2
    out="${out//[[:space:]]/}"
    case "$out" in
        0) return 0 ;;
        "") return 2 ;;
        *) return 1 ;;
    esac
}

veri_temizle() { # veri_temizle <eid> <container> <parola>
    local eid="$1" C="$2" pw="$3"
    case "$eid" in
        mariadb)    my_sql "$C" "$pw" "DROP DATABASE IF EXISTS \`$E2E_DB\`;" >/dev/null 2>&1 ;;
        postgresql) pg_sql "$C" "$pw" postgres "DROP DATABASE IF EXISTS \"$E2E_DB\"" >/dev/null 2>&1 ;;
        mongodb)    mongo_js "$C" "${MONGO_USER:-root}" "$pw" \
                        "db.getSiblingDB('$E2E_DB').dropDatabase()" >/dev/null 2>&1 ;;
        redis)      redis_cli "$C" "$pw" DEL "$E2E_REDIS_ANAHTAR" >/dev/null 2>&1 ;;
        mssql)      ms_sql "$C" "$pw" "IF DB_ID('$E2E_DB') IS NOT NULL BEGIN
                        ALTER DATABASE [$E2E_DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                        DROP DATABASE [$E2E_DB]; END" >/dev/null 2>&1
                    # Yabancı arşiv testi staging klasörüne dosya bırakmış olabilir.
                    docker exec "$C" sh -c 'rm -f /var/opt/mssql/backup/*' >/dev/null 2>&1 ;;
        cassandra)  cql "$C" "${CASSANDRA_USER:-cassandra}" "$pw" "DROP KEYSPACE IF EXISTS $E2E_DB;" >/dev/null 2>&1 ;;
        elasticsearch) es_istek "$C" "$pw" DELETE "/$E2E_ES_INDEKS" >/dev/null 2>&1 ;;
        clickhouse) ch_sql "$C" "${CLICKHOUSE_USER:-default}" "$pw" "DROP DATABASE IF EXISTS $E2E_DB" >/dev/null 2>&1 ;;
        rabbitmq)   rabbit_ctl "$C" delete_vhost "$E2E_DB" >/dev/null 2>&1 ;;
        minio)      minio_nesnesini_sil "$C" ;;
        neo4j)      neo_cypher "$C" "$pw" "MATCH (n:E2EKanit) DETACH DELETE n;" >/dev/null 2>&1 ;;
    esac
}

# MinIO'nun volume'undaki test nesnesini silmek için kabuğu olan bir imaj
# gerekiyor. YENİ İMAJ ÇEKMİYORUZ: bu yığın iç ağda çalışır, internet
# olmayabilir — çalışan container'lardan birinin imajını ödünç alıyoruz.
yardimci_imaj() {
    local c img deneme=0
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
        [ "$c" = "minio" ] && continue
        [ "$deneme" -ge 5 ] && break
        img="$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)"
        [ -n "$img" ] || continue
        deneme=$((deneme+1))
        if docker run --rm --entrypoint sh "$img" -c 'exit 0' >/dev/null 2>&1; then
            printf '%s' "$img"; return 0
        fi
    done
    return 1
}
minio_nesnesini_sil() {
    local img
    img="$(yardimci_imaj)" || {
        warn "MinIO test nesnesi silinemedi (kabuğu olan imaj yok): /data/$E2E_MINIO_KOVA"; return 1; }
    docker run --rm -v "${PROJE}_minio_data:/d" --entrypoint sh "$img" \
        -c 'rm -rf "/d/$1"' sh "$E2E_MINIO_KOVA" >/dev/null 2>&1 \
        || warn "MinIO test nesnesi silinemedi: /data/$E2E_MINIO_KOVA"
}

# =============================================================================
# TEMİZLİK — betik kendi yarattığı her şeyi geri alır, iki kez üst üste
# çalıştırılabilsin diye. Trap'e bağlı: Ctrl+C'de ve die'da da çalışır.
# =============================================================================
TEMIZLENDI=0
temizle() {
    [ "$TEMIZLENDI" = "1" ] && return 0
    TEMIZLENDI=1
    if [ -n "$DOKUNULAN$URETILEN" ]; then
        heading "Temizlik"
        local eid C f
        for eid in $DOKUNULAN; do
            C="$(primary_of "$eid")"
            if container_running "$C"; then
                veri_temizle "$eid" "$C" "$(motor_pw "$eid")"
                log "  $eid: test verisi kaldırıldı"
            else
                warn "  $eid: container kapalı, test verisi KALDIRILAMADI ($E2E_DB)"
            fi
        done
        if [ "${E2E_YEDEKLERI_KORU:-0}" = "1" ]; then
            [ -n "$URETILEN" ] && log "  testin ürettiği yedek dosyaları korundu (E2E_YEDEKLERI_KORU=1)"
        else
            for f in $URETILEN; do
                [ -f "$f" ] && rm -f "$f" && log "  silindi: $(basename "$f")"
            done
        fi
    fi
    # Tur testinin yedek dizini gerçek yedeklerin yanına düşmüş olabilir
    # (geçici alanda 5 GB yoksa oraya yazıyoruz); yarıda kesilse de kalmasın.
    if [ -n "$TUR_DIZIN" ] && [ -d "$TUR_DIZIN" ]; then
        rm -rf "$TUR_DIZIN" || warn "  tur yedek dizini silinemedi: $TUR_DIZIN"
    fi
    rm -rf "$E2E_TMP"
    # Ön koşulda düşen bir koşum boş bir günlük bırakıyordu; boş dosya bilgi
    # taşımaz, yalnız logs/ dizinini şişirir.
    [ -s "$E2E_LOG" ] || rm -f "$E2E_LOG"
}
# INT/TERM'i lib.sh yakalıyor (kesinti BAŞARI DEĞİLDİR: 130 ile çıkar). Bizim
# temizliğimiz EXIT üzerinde — 130'la çıkarken de, die'da da çalışır. İkisini
# aynı sinyale bağlamak lib.sh'in kesinti raporunu yutardı.
trap temizle EXIT

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
heading "Ön koşullar"
require_docker
require_cmd python3 flock tar gzip find awk df
[ -f "$CATALOG" ] || die "catalog.json bulunamadı: $CATALOG"
[ -f "$ENV_FILE" ] || warn ".env yok ($ENV_FILE) — parolalar yalnız ortamdan okunacak."
[ -r scripts/backup.sh ] || die "scripts/backup.sh okunamıyor — yığın kökünde miyiz?"
if [ "${#ZAMAN[@]}" -eq 0 ]; then
    warn "'timeout' komutu yok: komutlar zaman aşımı OLMADAN çalışacak (coreutils kurun)."
fi
mkdir -p "$BACKUP_DIR" || die "Yedek dizini oluşturulamadı: $BACKUP_DIR"
# backup.sh 5 GB'ın altında yedek almayı reddeder. Bunu testin hatası gibi
# göstermek yerine önden söyleyip ilgili turları ATLANDI diye raporluyoruz.
# ÜÇ DURUM var, iki değil: df'in KENDİSİ çalışmadıysa "yer yok" diyemeyiz —
# öyle desek bütün turlar uydurma bir sebeple atlanır ve paket hiçbir şey
# ölçmeden "yeşil" biterdi.
DISK_KB=""; DISK_DURUM="bilinmiyor"
if DISK_KB="$(bos_kb "$BACKUP_DIR")"; then
    if [ "$DISK_KB" -lt 5242880 ]; then
        DISK_DURUM="yetersiz"
        warn "Yedek diskinde 5 GB'dan az boş alan var ($(( DISK_KB / 1024 )) MB); backup.sh yedek almayı reddeder."
    else
        DISK_DURUM="yeterli"
    fi
else
    warn "Yedek diskinin boş alanı ÖLÇÜLEMEDİ (df çalışmadı): $BACKUP_DIR — turlar yine denenecek."
fi
ok "Ön koşullar hazır — bu koşumun kanıt değeri: $KANIT"
log "Ayrıntılı komut çıktısı: $E2E_LOG"

# ---------------------------------------------------------- motor seçimi ----
# Katalog okunamazsa liste BOŞ dönüyordu ve betik "katalogda yedeklenebilir
# motor yok" diyordu — yanlış sebep. Ölçüm aracının bozulduğunu söylemek şart.
TUM_MOTORLAR="$(yedeklenebilir_motorlar)" \
    || die "Katalog okunamadı ($CATALOG): yedeklenebilir motor listesi çıkarılamadı — python3 çalışıyor mu?"
[ -n "$TUM_MOTORLAR" ] || die "Katalogda backup.supported=true olan motor yok."
SECILEN=""
if [ "$#" -gt 0 ]; then
    for arg in "$@"; do
        printf '%s\n' "$TUM_MOTORLAR" | grep -qx "$arg" \
            || die "'$arg' yedeklenebilir bir motor değil. Seçenekler: $(printf '%s' "$TUM_MOTORLAR" | tr '\n' ' ')"
        SECILEN="$SECILEN $arg"
    done
else
    SECILEN="$(printf '%s' "$TUM_MOTORLAR" | tr '\n' ' ')"
fi

# =============================================================================
# BİR MOTORUN TAM TURU
# =============================================================================
# Adım 5 — kanıt gerçekten ARŞİVİN İÇİNDE mi?
# Ölçüt "arşivde şu AD geçiyor" DEĞİL, "BU KOŞUMUN DEĞERİ orada" olmalı: sabit
# adlar (e2e_yedek kovası) yarım kalmış eski bir koşumdan kalmış olabilir ve o
# eski nesne kontrolü geçirirdi. Nerede ham bayt araması işe yaramıyorsa
# (sıkıştırılmış SSTable, tescilli dump) bunu SÖYLÜYORUZ; sessizce geçmiyoruz.
icerik_kaniti() {   # icerik_kaniti <eid> <dosya>
    local eid="$1" dosya="$2" rc=0
    case "$eid" in
        rabbitmq)
            local ad="rabbitmq: az önce yazılan tanım (policy) yedek dosyasının içinde"
            arsivde_ham_kanit "$dosya"; rc=$?
            case "$rc" in
                0) t_ok "$ad" ;;
                1) t_fail "$ad" "tanımlar dışa aktarıldı ama bu koşumun policy'si yok — dosyadan topoloji geri gelmez" ;;
                *) t_unknown "$ad" "yedek dosyası açılamadı (gzip düştü): $dosya — içerik ÖLÇÜLEMEDİ" ;;
            esac ;;
        minio)
            # MinIO nesnesi düz metin: bu koşumun DEĞERİ arşivde ham olarak
            # bulunmalı. Yalnız kova adına bakmak yetmez — `docker cp` /data'nın
            # TAMAMINI arşivliyor, eski bir koşumdan kalan kova da orada olurdu
            # ve kontrolü o geçirirdi (denetim bulgusu).
            local ad="minio: bu koşumun değeri arşivin içinde ($E2E_MINIO_KOVA/$E2E_TABLO.txt)"
            arsivde_ham_kanit "$dosya"; rc=$?
            case "$rc" in
                0) t_ok "$ad" ;;
                1) t_fail "$ad" "arşiv doğrulamayı geçti ama içinde '$KANIT' yok — yedek az önce yazılan nesneyi taşımıyor" ;;
                *) t_unknown "$ad" "arşiv açılamadı (gzip düştü): $dosya — içerik ÖLÇÜLEMEDİ" ;;
            esac ;;
        cassandra|clickhouse)
            # Bu iki formatta veri SIKIŞTIRILMIŞ bloklarda durur (SSTable / zip):
            # değeri ham baytta aramak çoğu zaman boş döner. Önce yine de
            # deniyoruz (bulunursa en güçlü kanıt); bulunamazsa BU KOŞUMDA
            # üretilen üye adlarına bakıyoruz — cassandra'da keyspace + bu
            # koşumun snapshot dizini, clickhouse'ta bu koşumda alınan
            # veritabanı yedeği. Sabit ada bakan eski ölçüt kaldırıldı.
            local ad="$eid: bu koşumda yazılan '$E2E_DB' arşivin içinde"
            arsivde_ham_kanit "$dosya"; rc=$?
            if [ "$rc" -eq 0 ]; then
                t_ok "$eid: bu koşumun değeri ($KANIT) arşivin ham içeriğinde"
                return 0
            fi
            if [ "$rc" -eq 2 ]; then
                t_unknown "$ad" "arşiv açılamadı (gzip düştü): $dosya — içerik ÖLÇÜLEMEDİ"
                return 0
            fi
            local -a desen
            if [ "$eid" = "cassandra" ]; then desen=("$E2E_DB" "snapshots"); else desen=("$E2E_DB"); fi
            arsivde_uye "$dosya" "${desen[@]}"; rc=$?
            case "$rc" in
                0) t_ok "$ad (değerin kendisi sıkıştırılmış blokta; arşiv bu koşumun yedeğinden)"
                   t_info "  not: '$eid' arşivinde ham bayt araması sonuç vermez; kanıt, bu koşumda üretilen üye adlarıdır" ;;
                1) t_fail "$ad" "arşiv doğrulamayı geçti ama içinde '$E2E_DB' yok — bu yedek az önce yazılan veriyi taşımıyor" ;;
                *) t_unknown "$ad" "arşiv listelenemedi (gzip/tar düştü): $dosya — içerik ÖLÇÜLEMEDİ" ;;
            esac ;;
        elasticsearch)
            t_skip "elasticsearch: kanıt belgesi arşivin içinde" \
                   "ES arşivinde indeks adları UUID'lidir; içerik ancak geri yüklenerek görülür, ürün restore-elasticsearch sunmuyor (docs/BACKUP.md)" ;;
        neo4j)
            # DENETİM BULGUSU: burada hiçbir dal YOKTU. Neo4j'nin dump'ının içi
            # hiç ölçülmediği hâlde motorun bütün satırları yeşil görünüyordu —
            # oysa geri yükleme de sunulmadığı için içerik hakkında elimizde
            # tek kanıt buydu.
            local ad="neo4j: kanıt düğümü dump'ın içinde"
            arsivde_ham_kanit "$dosya"; rc=$?
            case "$rc" in
                0) t_ok "neo4j: bu koşumun değeri ($KANIT) dump'ın içinde" ;;
                1) t_skip "$ad" "neo4j-admin dump'ı kendi içinde sıkıştırılmış tescilli bir formattır; değer ham baytta aranamıyor ve ürün restore-neo4j sunmuyor — İÇERİK KANITLANMADI" ;;
                *) t_unknown "$ad" "dump açılamadı (gzip düştü): $dosya — içerik ÖLÇÜLEMEDİ" ;;
            esac ;;
        *)
            # Varsayılan dal ŞART: katalog büyüdüğünde yeni motor buradan
            # sessizce geçiyor, "hiçbir şey demedik" ile "geçti" aynı şeye
            # dönüşüyordu.
            if geri_yukleme_var "$eid"; then
                t_info "$eid: arşiv-içi ad ölçütü tanımlı değil; içerik kanıtı 9. adımda (sil → geri yükle → oku) alınıyor"
            else
                t_skip "$eid: kanıt kaydı yedek dosyasının içinde" \
                       "bu motor için arşiv-içi içerik ölçütü tanımlı değil ve ürün geri yükleme sunmuyor — içerik ÖLÇÜLMEDİ"
            fi ;;
    esac
}

motor_turu() {
    local eid="$1"
    local bilgi ext pwenv C pw rc=0 frc=0 dosya isaret

    # Katalog okunamıyorsa uzantı, parola ve tür bilinmiyor: bu motor hakkında
    # hiçbir şey ölçemeyiz. "Sorun yok" ile karıştırılmasın.
    if ! bilgi="$(motor_bilgi "$eid")"; then
        t_unknown "$eid: yedek → geri yükleme turu" \
                  "katalogdan motor bilgisi okunamadı ($CATALOG / python3) — ölçüm yapılamadı"
        return 0
    fi
    ext="$(printf '%s' "$bilgi" | cut -d'|' -f1)"
    pwenv="$(printf '%s' "$bilgi" | cut -d'|' -f4)"
    pw="$(motor_parolasi "$pwenv")"
    # Devirden sonra ana kopya kataloğun varsayılan servisi DEĞİLDİR; sabit ad
    # kullanan bir test durdurulmuş container'a bakıp "kapalı" sanardı.
    C="$(primary_of "$eid")"

    heading "$eid   (container: $C)"

    if ! container_running "$C"; then
        if docker_yasiyor; then
            t_skip "$eid: yedek → geri yükleme turu" \
                   "motor kapalı ('$C' çalışmıyor). Açmak için: ./stack.sh enable $eid"
        else
            t_unknown "$eid: yedek → geri yükleme turu" \
                      "docker cevap vermiyor; '$C' açık mı kapalı mı ÖLÇÜLEMEDİ — motor kapalı sanılmasın"
        fi
        return 0
    fi
    if [ "$DISK_DURUM" = "yetersiz" ]; then
        t_skip "$eid: yedek → geri yükleme turu" \
               "yedek diskinde 5 GB'dan az yer var; backup.sh zaten reddeder"
        return 0
    fi
    # Neo4j Community'de çevrimiçi yedek YOK: yedek almak motoru DURDURUR.
    # Bunu sormadan yapmak, testin üretimde kesinti yaratması demek olurdu.
    if [ "$eid" = "neo4j" ] && [ "${E2E_NEO4J_OFFLINE:-0}" != "1" ]; then
        t_skip "neo4j: yedek → geri yükleme turu" \
               "Community sürümde yedek almak motoru DURDURUR; kesintiyi göze alıyorsanız: E2E_NEO4J_OFFLINE=1 ./scripts/e2e/backup.sh neo4j"
        return 0
    fi

    # ---- 1. veri yaz ve GERİ OKU -------------------------------------------
    # Önce ÖLÇÜM ALETİNİ sınıyoruz. Alet çalışmıyorsa turun geri kalanı hiçbir
    # şey kanıtlamaz; bu yüzden burada t_fail değil t_unknown var: "ürün bozuk"
    # demiyoruz, "ölçemedik" diyoruz — ama yine de başarısız sayılıyor.
    DOKUNULAN="$DOKUNULAN $eid"
    if ! veri_yaz "$eid" "$C" "$pw"; then
        t_unknown "$eid: kanıt kaydı yazıldı ve geri okundu" \
                  "kanıt kaydı YAZILAMADI (istemci/parola/yetki?) — ayrıntı: $E2E_LOG"
        return 0
    fi
    oku "$eid" "$C" "$pw"
    if [ "$OKUMA_RC" -ne 0 ]; then
        t_unknown "$eid: kanıt kaydı yazıldı ve geri okundu" \
                  "okuma istemcisi hata verdi (rc=$OKUMA_RC); boş çıktı 'veri yok' sayılmadı — ayrıntı: $E2E_LOG"
        return 0
    fi
    if kanit_var; then
        t_ok "$eid: kanıt kaydı yazıldı ve geri okundu ($E2E_DB/$E2E_ANAHTAR = $KANIT)"
    else
        t_fail "$eid: kanıt kaydı yazıldı ve geri okundu" \
               "yazma başarılı döndü ama kayıt geri gelmedi; okunan: '${OKUNAN:-boş}'"
        return 0
    fi

    # ---- 2. yedek al --------------------------------------------------------
    isaret="$E2E_TMP/isaret.$eid"
    if ! : > "$isaret"; then
        t_unknown "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti" \
                  "zaman işareti dosyası yazılamadı ($isaret) — 'bu koşumda üretildi' ölçütü kurulamadı"
        return 0
    fi
    rc=0
    if [ "$eid" = "neo4j" ]; then
        ( export BACKUP_NEO4J_OFFLINE=true
          calistir "$SURE_YEDEK" "backup $eid" ./scripts/backup.sh "$eid" ) || rc=$?
    else
        calistir "$SURE_YEDEK" "backup $eid" ./scripts/backup.sh "$eid" || rc=$?
    fi
    if [ "$rc" -ne 0 ] && kilit_carpismasi; then
        t_skip "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti" \
               "başka bir yedekleme/geri yükleme kilidi tutuyor (gece cron'u olabilir); test daha sonra tekrarlanmalı"
        return 0
    fi
    if asildi_mi "$rc"; then
        t_unknown "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti" \
                  "yedekleme $SURE_YEDEK sn içinde dönmedi (rc=$rc); yarım kalan dosya üzerinden karar verilemez"
        return 0
    fi
    # Üretilen dosyayı `list`/`stats` ile aynı ölçütle (*.gz) arıyoruz ama
    # YALNIZ bu koşumdan sonra oluşanları: yoksa dünkü yedek "yeni alındı"
    # sanılırdı. Aramanın KENDİSİ düşerse bu bir sonuç değil, ölçüm yokluğudur.
    dosya="$(en_yeni_gz "$BACKUP_DIR/$eid" "$isaret")"; frc=$?
    if [ "$frc" -eq 2 ]; then
        t_unknown "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti" \
                  "$BACKUP_DIR/$eid taranamadı (çıkış kodu=$rc) — dosya üretilip üretilmediği ÖLÇÜLEMEDİ"
        return 0
    fi
    if [ "$rc" -ne 0 ] || [ -z "$dosya" ]; then
        t_fail "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti" \
               "çıkış kodu=$rc, yeni dosya=${dosya:-YOK} — $(son_ozet)"
        return 0
    fi
    URETILEN="$URETILEN $dosya"
    [ -n "$ILK_GERCEK" ] || ILK_GERCEK="$dosya"
    t_ok "$eid: ./scripts/backup.sh $eid yeni bir yedek dosyası üretti ($(basename "$dosya"))"

    # ---- 3. dosya adı katalogla uyuşuyor mu --------------------------------
    # Kataloğun backup.ext alanı ürünün ilanıdır; yedeği ARAYAN her araç o
    # uzantıya güvenir. Gerçek dosya başka uzantı taşıyorsa arama sessizce boş
    # döner ve "yedek yok" denir — oysa yedek vardır.
    if [ -z "$ext" ]; then
        t_unknown "$eid: üretilen dosyanın uzantısı katalogdaki backup.ext ile aynı" \
                  "katalogda backup.ext boş — karşılaştırılacak BEKLENTİ yok, kontrol yapılamadı"
    else
        case "$(basename "$dosya")" in
            *".$ext") t_ok "$eid: üretilen dosyanın uzantısı katalogdaki backup.ext ile aynı (.$ext)" ;;
            *) t_fail "$eid: üretilen dosyanın uzantısı katalogdaki backup.ext ile aynı" \
                      "katalog '.$ext' diyor, üretilen dosya '$(basename "$dosya")'" ;;
        esac
    fi

    # ---- 4. verify ----------------------------------------------------------
    rc=0
    calistir "$SURE_DOGRULA" "verify $eid" ./scripts/backup.sh verify "$dosya" || rc=$?
    if [ "$rc" -eq 0 ]; then
        t_ok "$eid: yedek bütünlük doğrulamasından (verify) geçti"
    elif asildi_mi "$rc"; then
        t_unknown "$eid: yedek bütünlük doğrulamasından (verify) geçti" \
                  "verify $SURE_DOGRULA sn içinde dönmedi (rc=$rc) — dosyanın sağlamlığı ÖLÇÜLEMEDİ"
    else
        t_fail "$eid: yedek bütünlük doğrulamasından (verify) geçti" "$(son_ozet)"
    fi

    # ---- 5. kanıt gerçekten ARŞİVİN İÇİNDE mi ------------------------------
    icerik_kaniti "$eid" "$dosya"

    # ---- 6. geri yükleme desteği yoksa ------------------------------------
    if ! geri_yukleme_var "$eid"; then
        # Sessizce geçmiyoruz: hem kanıtlanamadığını SÖYLÜYORUZ hem de betiğin
        # bunu kendisinin de söylediğini doğruluyoruz. Var olmayan bir kurtarma
        # yoluna "başarılı" demek, olmayan bir yedeğe güvenmekle aynı şey.
        t_skip "$eid: silinen verinin yedekten geri geldiği" \
               "ürün bu motor için otomatik geri yükleme sunmuyor (docs/BACKUP.md: elle yapılır)"
        rc=0
        calistir_izole "$SURE_ISTEMCI" "restore-$eid (desteklenmiyor mu)" ./scripts/backup.sh "restore-$eid" "$dosya" || rc=$?
        if asildi_mi "$rc"; then
            t_unknown "$eid: desteklenmeyen geri yükleme açıkça reddediliyor" \
                      "komut $SURE_ISTEMCI sn içinde dönmedi (rc=$rc) — reddedip reddetmediği ÖLÇÜLEMEDİ"
        elif [ "$rc" -eq 0 ]; then
            t_fail "$eid: desteklenmeyen geri yükleme açıkça reddediliyor" \
                   "restore-$eid 0 ile döndü — hiçbir şey yapmadan 'başarılı' demiş olabilir"
        elif son_icerir "otomatik geri yükleme yok"; then
            t_ok "$eid: desteklenmeyen geri yükleme açıkça reddediliyor (sessizce başarılı demiyor)"
        else
            t_fail "$eid: desteklenmeyen geri yükleme açıkça reddediliyor" \
                   "reddetti ama sebebi anlaşılmıyor: $(son_ozet)"
        fi
        return 0
    fi

    if [ "${E2E_GERI_YUKLEME:-1}" = "0" ]; then
        t_skip "$eid: silinen verinin yedekten geri geldiği" \
               "yıkıcı adım kapalı (E2E_GERI_YUKLEME=0) — bu yedeğin geri yüklenebildiği KANITLANMADI"
        return 0
    fi

    # ---- 7. VERİYİ SİL ------------------------------------------------------
    # Silmeyi doğrulamadan geri yüklemek en tehlikeli sahte testtir: veri
    # yerinde kalırsa, geri yükleme hiçbir şey yapmasa bile "geldi" derdik.
    veri_yikim "$eid" "$C" "$pw"
    local N_SIL="$eid: kanıt kaydı silindi (geri yükleme gerçekten iş yapmak zorunda)"
    yikim_dogrula "$eid" "$C" "$pw"; local ydrc=$?
    case "$ydrc" in
        0) t_ok "$N_SIL" ;;
        1) t_fail "$N_SIL"              "silme işe yaramadı, $E2E_DB hâlâ duruyor — geri yükleme kanıtı anlamsız olurdu"
           return 0 ;;
        2) t_unknown "$N_SIL"              "yıkım sorgusu cevap vermedi; silinip silinmediği ÖLÇÜLEMEDİ"
           return 0 ;;
    esac

    # ydrc=3 → bu motorda yıkım veritabanını DÜŞÜRMÜYOR (MSSQL satırı siler).
    # Orada doğru soru hâlâ "kanıt kaydı duruyor mu".
    if [ "$ydrc" -eq 3 ]; then
        oku "$eid" "$C" "$pw"
        if [ "$OKUMA_RC" -ne 0 ]; then
            # Denetim bulgusu: istemci düştüğünde okuma BOŞ dönüyor, boş çıktı
            # da "silindi" sayılıyordu. Silmeyi doğrulayamadıysak sonraki
            # adımın hiçbir kanıt değeri kalmaz.
            t_unknown "$N_SIL"                 "silmeden sonraki okuma istemcisi hata verdi (rc=$OKUMA_RC); kaydın silinip silinmediği ÖLÇÜLEMEDİ"
            return 0
        fi
        if kanit_var; then
            t_fail "$N_SIL"                 "silme işe yaramadı, kayıt hâlâ duruyor — geri yükleme kanıtı anlamsız olurdu"
            return 0
        fi
        t_ok "$N_SIL"
    fi


    # ---- 8. geri yükle ------------------------------------------------------
    # ASSUME_YES=yes: confirm_restore'un 'evet' sorusu otomasyonda beklenemez.
    rc=0
    ( export ASSUME_YES=yes
      calistir "$SURE_GERI" "restore-$eid" ./scripts/backup.sh "restore-$eid" "$dosya" ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        t_ok "$eid: restore-$eid hata vermeden tamamlandı"
    elif kilit_carpismasi; then
        t_skip "$eid: restore-$eid hata vermeden tamamlandı" "kilit başkasında (gece cron'u olabilir)"
    elif asildi_mi "$rc"; then
        t_unknown "$eid: restore-$eid hata vermeden tamamlandı" \
                  "geri yükleme $SURE_GERI sn içinde dönmedi (rc=$rc) — yarıda kesildi"
    else
        t_fail "$eid: restore-$eid hata vermeden tamamlandı" "çıkış kodu=$rc — $(son_ozet)"
    fi

    # ---- 9. VERİ GERİ GELDİ Mİ?  (bütün turun sebebi) ----------------------
    # Geri yükleme container'ı yeniden başlatabiliyor (Redis'te tam olarak öyle
    # oluyor), bu yüzden okuma zaman sınırlı bir bekleyişle tekrarlanıyor.
    # Geri yükleme düşmüş olsa bile okuyoruz: "hem başarısız hem veri gitmiş"
    # ile "başarısız ama veri duruyor" bir felakette çok farklı iki durum.
    log "  bekleniyor: $eid üzerinde '$E2E_ANAHTAR' kaydının geri gelmesi (en fazla $SURE_OKUMA sn)"
    veri_bekle "$eid" "$C" "$pw"
    if [ "$OKUMA_RC" -ne 0 ]; then
        t_unknown "$eid: SİLİNEN kanıt kaydı yedekten geri geldi, değeri birebir aynı" \
                  "$SURE_OKUMA sn boyunca okuma istemcisi hata verdi (rc=$OKUMA_RC); verinin geri gelip gelmediği ÖLÇÜLEMEDİ — $E2E_LOG"
    elif kanit_var; then
        t_ok "$eid: SİLİNEN kanıt kaydı yedekten geri geldi, değeri birebir aynı ($KANIT)"
    else
        t_fail "$eid: SİLİNEN kanıt kaydı yedekten geri geldi, değeri birebir aynı" \
               "$SURE_OKUMA sn beklendi, okunan: '${OKUNAN:-boş}' — bu dosya bir kurtarma noktası DEĞİL"
    fi
}

# =============================================================================
# NEGATİF TESTLER — hepsi ürünün GERÇEKTEN yaşadığı arızalar
# =============================================================================
# Bir doğrulayıcının değeri, neye "hayır" dediğiyle ölçülür. Aşağıdaki dosyalar
# kasten bozuk; verify hepsini REDDETMELİ. Sonda pozitif kontrol var: her şeye
# "hayır" diyen bir verify de aynı derecede işe yaramaz.
#
# ÜÇ SONUÇ VAR, İKİ DEĞİL: "reddetti" (t_ok), "kabul etti" (t_fail) ve "hiç
# dönmedi / test dosyası kurulamadı" (t_unknown). Eskiden zaman aşımı (rc=124)
# ve üretilemeyen fikstür de "doğru şekilde reddetti" sayılıyordu: asılı kalan
# bir verify çağrısı ekranda YEŞİL yazıyordu.
dogrulama_reddetmeli() {   # dogrulama_reddetmeli <kontrol adı> <dosya> <ne olduğu>
    local ad="$1" dosya="$2" ne="$3" rc=0
    if [ ! -f "$dosya" ]; then
        t_unknown "$ad" "test dosyası üretilemedi ($dosya) — verify'a hiç sorulmadı"
        return 0
    fi
    calistir_izole "$SURE_DOGRULA" "verify $dosya" ./scripts/backup.sh verify "$dosya" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "$ad" "verify $SURE_DOGRULA sn içinde dönmedi (rc=$rc) — reddedip reddetmediği ÖLÇÜLEMEDİ"
    elif [ "$rc" -eq 0 ]; then
        t_fail "$ad" "$ne — verify bu dosyaya 'doğrulandı' dedi; felaket günü elde boş/yarım veri kalır"
    else
        t_ok "$ad"
    fi
}

# Katalogda yedeklenemez yazan motor: ürün yedek DOSYASI ÜRETMEMELİ. Ölçüt
# yalnız çıkış kodu DEĞİL — ortada dosya da olmamalı. (Denetim bulgusu: eski
# ölçüt sıfırdan farklı çıkışa bakıyordu, oysa ürün komutu tanımayıp yardım
# metni basınca da çıkış kodu 1'dir; aşağıdaki yazım hatası kontrolü bu sınırı
# açıkça ölçüyor ve kontrolün adı artık yalnız ölçtüğü kadarını söylüyor.)
reddetmeli_motor() {   # reddetmeli_motor <eid>
    local eid="$1" ad rc=0 frc=0 dosya isaret
    ad="$eid: katalogda yedeklenemez yazıyor, ürün de yedek dosyası üretmiyor"
    isaret="$E2E_TMP/isaret.red.$eid"
    if ! : > "$isaret"; then
        t_unknown "$ad" "zaman işareti dosyası yazılamadı ($isaret)"
        return 0
    fi
    calistir_izole "$SURE_ISTEMCI" "backup $eid (desteklenmiyor)" ./scripts/backup.sh "$eid" || rc=$?
    dosya="$(en_yeni_gz "$BACKUP_DIR/$eid" "$isaret")"; frc=$?
    [ -n "$dosya" ] && URETILEN="$URETILEN $dosya"
    if asildi_mi "$rc"; then
        t_unknown "$ad" "komut $SURE_ISTEMCI sn içinde dönmedi (rc=$rc) — reddedip reddetmediği ÖLÇÜLEMEDİ"
    elif [ "$frc" -eq 2 ]; then
        t_unknown "$ad" "çıkış kodu $rc ama $BACKUP_DIR/$eid taranamadı: dosya üretilip üretilmediği ÖLÇÜLEMEDİ"
    elif [ "$rc" -eq 0 ]; then
        t_fail "$ad" "komut 0 ile döndü — desteklenmeyen motor için yedek almış gibi davranıyor"
    elif [ -n "$dosya" ]; then
        t_fail "$ad" "sıfırdan farklı çıktı (rc=$rc) ama yine de dosya üretti: $dosya"
    else
        t_ok "$ad (çıkış kodu $rc, yeni dosya yok)"
    fi
}

# Yukarıdaki satır "üretmiyor" diyor ama NEDEN üretmediğini söylemiyor: ürün
# tanımadığı her argüman için aynı yardım metnini basıp 1 ile çıkıyor. Bu
# yüzden aynı ölçütü UYDURMA bir motor adıyla da koşuyoruz. İkisi de aynı
# davranıyorsa yukarıdaki kontrol "ürün kafka'nın yedeklenemez olduğunu
# BİLİYOR" demez; yalnızca "dosya üretmiyor" der. Denetimin işaret ettiği
# boşluk buydu — kapatmanın yolu, kontrolü ölçebildiği şeye daraltmak ve
# sınırını yazmaktı.
tanimsiz_altkomut_kontrolu() {
    local ad="tanınmayan alt komut da yedek dosyası üretmiyor (yazım hatası sessizce geçmiyor)"
    local rc=0 uydurma="e2e-olmayan-motor"
    calistir_izole "$SURE_ISTEMCI" "backup $uydurma (yazım hatası)" ./scripts/backup.sh "$uydurma" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "$ad" "komut $SURE_ISTEMCI sn içinde dönmedi (rc=$rc)"
    elif [ "$rc" -eq 0 ]; then
        t_fail "$ad" "'$uydurma' argümanı 0 ile döndü — tanınmayan komut sessizce başarılı sayılıyor"
    else
        t_ok "$ad (çıkış kodu $rc)"
        t_info "not: ürün yedeklenemez motora da uydurma ada da AYNI yardım metnini basıyor;"
        t_info "     yukarıdaki satırlar dosya üretilmediğini kanıtlar, katalog farkındalığını DEĞİL."
    fi
}

negatif_testler() {
    heading "Negatif testler — bozuk dosya 'doğrulandı' DEMEMELİ"
    local d="$E2E_TMP" f

    # 1) 0 bayt dosya: diskin dolduğu ya da dump'ın hiç başlamadığı hâl.
    f="$d/mariadb_full_e2e-sifir.sql.gz"
    if : > "$f"; then
        dogrulama_reddetmeli "0 baytlık yedek dosyası doğrulamayı geçmiyor" "$f" "boş dosya"
    else
        t_unknown "0 baytlık yedek dosyası doğrulamayı geçmiyor" "test dosyası yazılamadı: $f"
    fi

    # 2) Geçerli gzip ama İÇİ BOŞ. Boş girdinin gzip'i 20 bayttır ve `gzip -t`
    #    açısından KUSURSUZDUR; eski sürümde bu dosya yeşil tik alıyordu.
    f="$d/mariadb_full_e2e-bos.sql.gz"
    if printf '' | gzip -6 > "$f" && [ -s "$f" ]; then
        dogrulama_reddetmeli "içi boş (geçerli gzip, sıfır satır) dump doğrulamayı geçmiyor" \
            "$f" "20 baytlık boş gzip"
    else
        t_unknown "içi boş (geçerli gzip, sıfır satır) dump doğrulamayı geçmiyor" \
                  "boş gzip üretilemedi ($f) — verify'a hiç sorulmadı"
    fi

    # 3) Yalnız 0 baytlık üye taşıyan arşiv: dosya ADLARI var, veri yok.
    f="$d/mssql_full_e2e-bosarsiv.tar.gz"
    if mkdir -p "$d/bos_arsiv" && : > "$d/bos_arsiv/veritabani.bak" \
       && tar -czf "$f" -C "$d/bos_arsiv" . 2>>"$E2E_LOG" && [ -s "$f" ]; then
        dogrulama_reddetmeli "içindeki dosyaların hepsi 0 bayt olan arşiv doğrulamayı geçmiyor" \
            "$f" "0 baytlık .bak"
    else
        t_unknown "içindeki dosyaların hepsi 0 bayt olan arşiv doğrulamayı geçmiyor" \
                  "test arşivi üretilemedi ($f) — tar/gzip düştü, verify'a hiç sorulmadı"
    fi

    # 4) Yalnız üstveri taşıyan arşiv: MSSQL geri yüklemesi .bak okur; arşivde
    #    .bak yoksa elde kurtarma noktası değil, klasör vardır.
    f="$d/mssql_full_e2e-baksiz.tar.gz"
    if mkdir -p "$d/baksiz" && printf 'yalnizca ustveri\n' > "$d/baksiz/okuma.txt" \
       && tar -czf "$f" -C "$d/baksiz" . 2>>"$E2E_LOG" && [ -s "$f" ]; then
        dogrulama_reddetmeli "içinde .bak olmayan MSSQL arşivi doğrulamayı geçmiyor" \
            "$f" "yalnız üstveri"
    else
        t_unknown "içinde .bak olmayan MSSQL arşivi doğrulamayı geçmiyor" \
                  "test arşivi üretilemedi ($f) — verify'a hiç sorulmadı"
    fi

    # 5) Kenara alınmış dosya (.bozuk): doğrulamayı geçemediği için karantinaya
    #    alınmış dosyayı operatör elle doğrulayınca ESKİDEN yeşil tik alıyor,
    #    uzantıyı geri alıp o dosyayla geri yüklemeye kalkıyordu.
    f="$d/mariadb_full_e2e.sql.gz.bozuk"
    if printf 'CREATE TABLE t(a int);\n' | gzip -6 > "$f" && [ -s "$f" ]; then
        dogrulama_reddetmeli "kenara alınmış (.bozuk) dosya doğrulamayı geçmiyor" \
            "$f" "karantinadaki dosya"
    else
        t_unknown "kenara alınmış (.bozuk) dosya doğrulamayı geçmiyor" \
                  "test dosyası üretilemedi ($f) — verify'a hiç sorulmadı"
    fi

    # 6) GERÇEK bir yedeğin KESİLMİŞ hâli. Sentetik dosyalar kaçırılabilir;
    #    asıl korkulan, gerçek bir dump'ın ortasında diskin/borunun ölmesidir.
    #    Kesik dosyanın BAŞI her zaman doğrudur — ölçüt akışın SONU olmalı.
    if [ -n "$ILK_GERCEK" ] && [ -s "$ILK_GERCEK" ]; then
        local ad taban uzanti boy yeni prc=0
        ad="$(basename "$ILK_GERCEK")"
        taban="${ad%%_*}"                          # motor adı: verify dalını seçer
        uzanti="${ad#*_full_}"; uzanti="${uzanti#*.}"   # sql.gz / tar.gz / dump.gz …
        boy="$(wc -c < "$ILK_GERCEK" 2>>"$E2E_LOG" | tr -d '[:space:]')"
        case "${boy:-}" in ''|*[!0-9]*) boy=0 ;; esac
        yeni="$d/${taban}_full_e2e-kesik.${uzanti}"
        # boy ölçülemezse head -c 0 ile BOŞ dosya üretiliyordu; verify onu da
        # reddeder ve kontrol "kesik dosya yakalandı" diye YEŞİL yazardı —
        # oysa ölçülen şey 1. testin (boş dosya) tekrarıydı.
        if [ "$boy" -lt 2 ]; then
            t_unknown "gerçek bir yedeğin yarısından kesilmiş kopyası doğrulamayı geçmiyor ($taban)" \
                      "kaynak dosyanın boyu okunamadı: $ILK_GERCEK — kesik kopya üretilemedi"
        elif head -c "$(( boy / 2 ))" "$ILK_GERCEK" > "$yeni" 2>>"$E2E_LOG" && [ -s "$yeni" ]; then
            dogrulama_reddetmeli "gerçek bir yedeğin yarısından kesilmiş kopyası doğrulamayı geçmiyor ($taban)" \
                "$yeni" "$(( boy / 2 )) / $boy bayt"
        else
            t_unknown "gerçek bir yedeğin yarısından kesilmiş kopyası doğrulamayı geçmiyor ($taban)" \
                      "kesik kopya yazılamadı ($yeni) — geçici alanda yer kalmamış olabilir"
        fi

        # POZİTİF KONTROL: aynı verify sağlam dosyaya EVET demeli. Yoksa
        # yukarıdaki "reddetti" satırlarının hiçbiri bir şey kanıtlamaz.
        calistir_izole "$SURE_DOGRULA" "verify (pozitif kontrol)" ./scripts/backup.sh verify "$ILK_GERCEK" || prc=$?
        if [ "$prc" -eq 0 ]; then
            t_ok "pozitif kontrol: sağlam yedek doğrulamadan geçiyor (verify her şeye 'hayır' demiyor)"
        elif asildi_mi "$prc"; then
            t_unknown "pozitif kontrol: sağlam yedek doğrulamadan geçiyor" \
                      "verify $SURE_DOGRULA sn içinde dönmedi (rc=$prc) — ölçülemedi"
        else
            t_fail "pozitif kontrol: sağlam yedek doğrulamadan geçiyor" "$(son_ozet)"
        fi
    else
        t_skip "gerçek bir yedeğin yarısından kesilmiş kopyası doğrulamayı geçmiyor" \
               "bu koşumda hiç gerçek yedek üretilemedi (motorlar kapalı olabilir)"
        t_skip "pozitif kontrol: sağlam yedek doğrulamadan geçiyor" \
               "bu koşumda hiç gerçek yedek üretilemedi"
    fi

    # 7) Katalogda backup.supported=false olan motorlar (Kafka, izleme) için
    #    betik yedek DOSYASI üretmemeli. Sessizce boş bir dosya üretseydi,
    #    kullanıcı olmayan bir kurtarma noktasına güvenirdi.
    local liste="" lrc=0 eid
    liste="$(yedeklenemez_motorlar)" || lrc=$?
    if [ "$lrc" -ne 0 ]; then
        t_unknown "katalogda yedeklenemez yazan motorlar için yedek üretilmiyor" \
                  "katalog okunamadı ($CATALOG / python3) — hangi motorların yedeklenemez olduğu ÖLÇÜLEMEDİ"
    elif [ -z "$liste" ]; then
        t_skip "katalogda yedeklenemez yazan motorlar için yedek üretilmiyor" \
               "katalogda backup.supported=false olan motor yok"
    else
        for eid in $liste; do
            reddetmeli_motor "$eid"
        done
    fi
    tanimsiz_altkomut_kontrolu
}

# ---------------------------------------------------------------------------
# YABANCI DOSYAYLA GERİ YÜKLEME — "veriyi sildim ama başarılı dedim" arızası
# ---------------------------------------------------------------------------
# Bu iki testin ÖN KOŞULU var: "reddedilen geri yükleme veriyi silmedi"
# diyebilmek için verinin testten ÖNCE yerinde olması gerekir. Önceki adımda
# geri yükleme düşmüşse kanıt kaydı zaten yoktur; bunu "yabancı dosya veriyi
# sildi" diye raporlamak HAKSIZ KIRMIZI olurdu. O yüzden önce taban ölçüm
# alınıyor, yoksa iki kontrol de ATLANDI/ÖLÇÜLEMEDİ diye işaretleniyor.
yabanci_redis() {
    local ad_red="redis: başka motorun içeriğini taşıyan dosya geri yüklemeyi durduruyor"
    local ad_veri="redis: reddedilen geri yüklemeden sonra mevcut veri yerinde duruyor"
    local C pw rc=0 yanlis

    if ! printf '%s\n' "$SECILEN" | grep -qw redis; then
        t_skip "$ad_red" "redis bu koşumda seçilmedi"
        t_skip "$ad_veri" "redis bu koşumda seçilmedi"
        return 0
    fi
    C="$(primary_of redis)"
    if ! container_running "$C"; then
        if docker_yasiyor; then
            t_skip "$ad_red"  "redis çalışmıyor ('$C')"
            t_skip "$ad_veri" "redis çalışmıyor ('$C')"
        else
            t_unknown "$ad_red"  "docker cevap vermiyor; '$C' durumu ÖLÇÜLEMEDİ"
            t_unknown "$ad_veri" "docker cevap vermiyor; '$C' durumu ÖLÇÜLEMEDİ"
        fi
        return 0
    fi
    pw="$(motor_pw redis)"

    oku redis "$C" "$pw"
    if [ "$OKUMA_RC" -ne 0 ]; then
        t_unknown "$ad_red"  "testten ÖNCE okuma istemcisi hata verdi (rc=$OKUMA_RC) — ölçüm kurulamadı"
        t_unknown "$ad_veri" "testten ÖNCE okuma istemcisi hata verdi (rc=$OKUMA_RC)"
        return 0
    fi
    if ! kanit_var; then
        t_skip "$ad_red"  "kanıt anahtarı testten önce zaten yok (önceki adımda geri yükleme düşmüş olabilir)"
        t_skip "$ad_veri" "karşılaştırılacak veri yok; 'veri yerinde kaldı' ölçülemez"
        return 0
    fi

    # restore_redis, dosyayı volume'a koymadan ÖNCE eski dump.rdb'yi ve AOF'u
    # SİLER; yani yabancı içerikli bir dosya doğrulamadan geçerse elde ne eski
    # veri ne yenisi kalır. Onay sorusuna BİLEREK 'evet' demiyoruz (ASSUME_YES
    # yok): doğrulama sızdırsa bile veri güvende kalsın. O durumda çıktıda
    # "İptal edildi" görürüz ve bunu DÜŞTÜ sayarız — çünkü ASSUME_YES ile
    # çalışan gerçek bir otomasyonda veri gitmiş olurdu.
    yanlis="$E2E_TMP/redis_full_e2e-yanlis.rdb.gz"
    if ! printf '%s\n' "-- bu dosya bir SQL dump'i, RDB degil" \
                       "CREATE TABLE t(a int);" "INSERT INTO t VALUES (1);" \
         | gzip -6 > "$yanlis" || [ ! -s "$yanlis" ]; then
        t_unknown "$ad_red"  "yabancı içerikli test dosyası üretilemedi: $yanlis"
        t_unknown "$ad_veri" "test dosyası üretilemediği için geri yükleme hiç denenmedi"
        return 0
    fi

    calistir_izole "$SURE_GERI" "restore-redis (yabancı içerik)" ./scripts/backup.sh restore-redis "$yanlis" || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "$ad_red" "restore-redis $SURE_GERI sn içinde dönmedi (rc=$rc) — durdurup durdurmadığı ÖLÇÜLEMEDİ"
    elif [ "$rc" -eq 0 ]; then
        t_fail "$ad_red" "restore-redis 0 ile döndü — yabancı dosyayı yüklemiş sayıyor"
    elif son_icerir "İptal edildi"; then
        t_fail "$ad_red" "doğrulama dosyayı GEÇİRDİ, iş yalnızca onay sorusunda durdu; ASSUME_YES=yes ile Redis'in verisi silinirdi"
    else
        t_ok "redis: başka motorun içeriğini taşıyan dosya geri yüklemeyi durdurdu (doğrulama reddetti)"
    fi

    # Geri yükleme container'ı durdurup başlatmış olabilir; okumaya kısa bir
    # pencere tanıyoruz, yoksa "veri gitti" demek ölçüm hatası olur.
    veri_bekle redis "$C" "$pw" "$SURE_ISTEMCI"
    if [ "$OKUMA_RC" -ne 0 ]; then
        t_unknown "$ad_veri" "okuma istemcisi hata verdi (rc=$OKUMA_RC) — verinin yerinde olup olmadığı ÖLÇÜLEMEDİ"
    elif kanit_var; then
        t_ok "$ad_veri"
    else
        t_fail "$ad_veri" "kanıt anahtarı kayboldu — reddedilen bir geri yükleme veriyi SİLMİŞ (okunan: '${OKUNAN:-boş}')"
    fi
}

yabanci_mssql() {
    local ad_red="mssql: içinde .bak olmayan yabancı arşivle geri yükleme reddediliyor"
    local ad_veri="mssql: reddedilen geri yüklemeden sonra veritabanı olduğu gibi duruyor"
    local C pw rc=0 yab

    if ! printf '%s\n' "$SECILEN" | grep -qw mssql; then
        t_skip "$ad_red"  "mssql bu koşumda seçilmedi"
        t_skip "$ad_veri" "mssql bu koşumda seçilmedi"
        return 0
    fi
    C="$(primary_of mssql)"
    if ! container_running "$C"; then
        if docker_yasiyor; then
            t_skip "$ad_red"  "mssql çalışmıyor ('$C')"
            t_skip "$ad_veri" "mssql çalışmıyor ('$C')"
        else
            t_unknown "$ad_red"  "docker cevap vermiyor; '$C' durumu ÖLÇÜLEMEDİ"
            t_unknown "$ad_veri" "docker cevap vermiyor; '$C' durumu ÖLÇÜLEMEDİ"
        fi
        return 0
    fi
    pw="$(motor_pw mssql)"

    oku mssql "$C" "$pw"
    if [ "$OKUMA_RC" -ne 0 ]; then
        t_unknown "$ad_red"  "testten ÖNCE okuma istemcisi hata verdi (rc=$OKUMA_RC) — ölçüm kurulamadı"
        t_unknown "$ad_veri" "testten ÖNCE okuma istemcisi hata verdi (rc=$OKUMA_RC)"
        return 0
    fi
    if ! kanit_var; then
        t_skip "$ad_red"  "kanıt satırı testten önce zaten yok (önceki adımda geri yükleme düşmüş olabilir)"
        t_skip "$ad_veri" "karşılaştırılacak veri yok; 'veritabanı olduğu gibi duruyor' ölçülemez"
        return 0
    fi

    # Bu arşiv doğrulamayı GEÇER (minio adıyla üretilmiş, sağlam bir tar.gz) —
    # savunma restore_mssql'in kendisindedir: içinde .bak yoksa durmalı.
    # "Hiç dönmeyen döngü = başarı" tuzağı tam buradaydı; betik hiçbir şey
    # yapmadan "MSSQL geri yüklendi" deyip 0 ile çıkıyordu.
    yab="$E2E_TMP/minio_full_e2e-yabanci.tar.gz"
    if ! { mkdir -p "$E2E_TMP/yabanci" \
           && printf 'bu bir MSSQL yedegi degil\n' > "$E2E_TMP/yabanci/nesne.txt" \
           && tar -czf "$yab" -C "$E2E_TMP/yabanci" . 2>>"$E2E_LOG" && [ -s "$yab" ]; }; then
        t_unknown "$ad_red"  "yabancı arşiv üretilemedi: $yab (tar/gzip düştü)"
        t_unknown "$ad_veri" "test arşivi üretilemediği için geri yükleme hiç denenmedi"
        return 0
    fi

    ( export ASSUME_YES=yes
      calistir_izole "$SURE_GERI" "restore-mssql (yabancı arşiv)" ./scripts/backup.sh restore-mssql "$yab" ) || rc=$?
    if asildi_mi "$rc"; then
        t_unknown "$ad_red" "restore-mssql $SURE_GERI sn içinde dönmedi (rc=$rc) — reddedip reddetmediği ÖLÇÜLEMEDİ"
    elif [ "$rc" -eq 0 ]; then
        t_fail "$ad_red" "restore-mssql hiçbir veritabanı geri yüklemeden 0 ile döndü"
    else
        t_ok "mssql: içinde .bak olmayan yabancı arşivle geri yükleme reddedildi"
    fi

    veri_bekle mssql "$C" "$pw" "$SURE_ISTEMCI"
    if [ "$OKUMA_RC" -ne 0 ]; then
        t_unknown "$ad_veri" "okuma istemcisi hata verdi (rc=$OKUMA_RC) — veritabanının durumu ÖLÇÜLEMEDİ"
    elif kanit_var; then
        t_ok "$ad_veri"
    else
        t_fail "$ad_veri" "kanıt satırı kayboldu (okunan: '${OKUNAN:-boş}')"
    fi
}

yabanci_dosya_testleri() {
    heading "Negatif testler — yanlış dosyayla geri yükleme veriyi SİLMEMELİ"
    yabanci_redis
    yabanci_mssql
}

# ---------------------------------------------------------------------------
# TUR DAYANIKLILIĞI — bir motorun yedeği patlarsa TÜM TUR ölmemeli
# ---------------------------------------------------------------------------
# Gerçek arıza: backup_mssql'de tanımsız bir değişken yüzünden `set -u` bütün
# betiği ortasından kesti; o geceden sonraki motorların (cassandra, es,
# rabbitmq, clickhouse, neo4j, minio) hiçbiri yedeklenmedi ve ÖZET TABLOSU BİLE
# BASILMADI — kimse fark etmedi. Burada bir motorun parolasını kasten bozup
# turu koşuyoruz: özet basılmalı, hata sayılmalı, SONRAKİ motorlar yedeklenmeye
# devam etmeli. Yedekler ayrı bir dizine yazılır; gerçek kurtarma noktalarına
# dokunulmaz.
tur_dizinini_sil() {
    [ -n "$TUR_DIZIN" ] || return 0
    rm -rf "$TUR_DIZIN" || warn "tur yedek dizini silinemedi: $TUR_DIZIN"
    TUR_DIZIN=""
}

# Devamlılık ölçütü: `backup all` katalog SIRASIYLA ilerliyor; tur ilk hatada
# ölmüşse sabote edilen motordan SONRAKİLERİN hiçbirinden dosya çıkmaz.
# Eski ölçüt "en az bir dosya üretildi" idi ve hesaplanan beklenti hiç
# kullanılmıyordu: sabote edilen motor listenin sonundaysa o tek dosya ondan
# ÖNCEKİ bir motorun olabilirdi — yani devamlılık aslında hiç ölçülmemiş olurdu.
tur_devamliligi() {   # tur_devamliligi <sabotaj> <sonrakiler> <sayı> <kontrol adı>
    local sabotaj="$1" sonrakiler="$2" sonra="$3" ad="$4"
    if [ "$sonra" -eq 0 ]; then
        t_skip "$ad" \
               "sabote edilen motor ($sabotaj) sıradaki SON motor; ondan sonra çalışan yedeklenebilir motor yok — devamlılık ölçülemez"
        return 0
    fi
    local eid adet uretti=0 eksik=""
    for eid in $sonrakiler; do
        if ! adet="$(gz_sayisi "$TUR_DIZIN/$eid")"; then
            t_unknown "$ad" "$TUR_DIZIN/$eid taranamadı — üretilen dosyalar sayılamadı"
            return 0
        fi
        if [ "$adet" -ge 1 ]; then uretti=$((uretti+1)); else eksik="$eksik $eid"; fi
    done
    if [ "$uretti" -eq 0 ]; then
        t_fail "$ad" \
               "$sabotaj sonrasında çalışan $sonra motor vardı ($sonrakiler ) ama tek dosya bile üretilmedi — tur ilk hatada ölmüş"
    elif [ "$uretti" -lt "$sonra" ]; then
        t_fail "$ad" \
               "tur devam etti ama $sonra motordan yalnız $uretti tanesi dosya üretti; dosyası olmayanlar:$eksik"
    else
        t_ok "$ad ($sonra motor, hepsi dosya üretti)"
    fi
}

# DENETİM BULGUSU: `all` turunda neo4j hiç dosya üretmeden "Başarılı" sayılıyor
# (backup_neo4j uyarı basıp 0 dönüyor). Test bu ürün davranışını artık
# SORGULUYOR: en azından operatöre söyleniyor mu, yoksa sessizce mi geçiliyor?
tur_neo4j_kontrolu() {
    local ad="neo4j: 'all' turunda dosyasız geçildiği operatöre söyleniyor"
    printf '%s\n' "$TUM_MOTORLAR" | grep -qx neo4j || return 0
    local C adet; C="$(primary_of neo4j)"
    if ! container_running "$C"; then
        t_skip "$ad" "neo4j çalışmıyor ('$C'); turda sırası hiç gelmedi"
        return 0
    fi
    if ! adet="$(gz_sayisi "$TUR_DIZIN/neo4j")"; then
        t_unknown "$ad" "$TUR_DIZIN/neo4j taranamadı — dosya üretilip üretilmediği ÖLÇÜLEMEDİ"
        return 0
    fi
    if [ "$adet" -ge 1 ]; then
        t_ok "neo4j: 'all' turunda gerçekten yedek dosyası üretildi ($adet dosya)"
    elif son_icerir "Neo4j atlandı"; then
        t_ok "$ad"
        t_info "ürün davranışı: neo4j dosyasız geçilmesine rağmen özetteki 'Başarılı' sayısına giriyor —"
        t_info "     'Başarılı: N' satırı N adet kurtarma noktası ANLAMINA GELMEZ (docs/BACKUP.md)."
    else
        t_fail "$ad" \
               "ne yedek dosyası var ne de 'Neo4j atlandı' uyarısı — motor sessizce başarılı sayılmış"
    fi
}

tur_dayanikliligi() {
    heading "Tur dayanıklılığı — bir motor patlayınca diğerleri devam ediyor mu"
    local ad_ozet="bir motorun yedeği patlayınca tur ölmüyor (özet yine basılıyor)"
    local ad_sayim="sabote edilen motor turda BAŞARISIZ sayıldı (yanlış parola sessizce yutulmuyor)"
    local ad_devam="sabote edilen motordan sonraki motorların hepsi yedeklendi"

    if [ "${E2E_TUR:-1}" = "0" ]; then
        t_skip "$ad_ozet"  "E2E_TUR=0 ile kapatıldı"
        t_skip "$ad_sayim" "E2E_TUR=0 ile kapatıldı"
        t_skip "$ad_devam" "E2E_TUR=0 ile kapatıldı"
        return 0
    fi
    if ! docker_yasiyor; then
        t_unknown "$ad_ozet"  "docker cevap vermiyor — tur hiç koşturulamadı"
        t_unknown "$ad_sayim" "docker cevap vermiyor — tur hiç koşturulamadı"
        t_unknown "$ad_devam" "docker cevap vermiyor — tur hiç koşturulamadı"
        return 0
    fi

    # Sabotaj için parolayla konuşan bir motor lazım: rabbitmq/minio/neo4j
    # yedekleri parola kullanmaz, yanlış parola onları düşürmez.
    local sabotaj="" eid
    for eid in mariadb postgresql mongodb mssql clickhouse elasticsearch cassandra redis; do
        printf '%s\n' "$TUM_MOTORLAR" | grep -qx "$eid" || continue
        container_running "$(primary_of "$eid")" || continue
        sabotaj="$eid"; break
    done
    if [ -z "$sabotaj" ]; then
        t_skip "$ad_ozet"  "parolayla yedeklenen çalışan motor yok — kasten bozulacak bir şey bulunamadı"
        t_skip "$ad_sayim" "sabote edilecek çalışan motor yok"
        t_skip "$ad_devam" "sabote edilecek çalışan motor yok"
        return 0
    fi

    # DENETİM BULGUSU (ters yön — HAKSIZ KIRMIZI): bu tur yedekleri $BACKUP_DIR'e
    # değil geçici alana yazıyor, ama 5 GB ön kontrolü $BACKUP_DIR üzerinde
    # yapılıyordu. /tmp küçükse backup.sh'ın disk kuralı burada patlıyor ve üç
    # kontrol birden ÜRÜNÜN suçu gibi DÜŞTÜ görünüyordu. Artık turun GERÇEKTEN
    # yazacağı yerin boş alanına bakıyoruz; orada yer yoksa yedek dizininin
    # altına (gerçek kurtarma noktalarına dokunmadan) yazıyoruz.
    local tmp_kb=""
    tmp_kb="$(bos_kb "$E2E_TMP")" || tmp_kb=""
    if [ -n "$tmp_kb" ] && [ "$tmp_kb" -ge 5242880 ]; then
        TUR_DIZIN="$E2E_TMP/tur-yedekleri"
    elif [ "$DISK_DURUM" = "yeterli" ]; then
        TUR_DIZIN="$BACKUP_DIR/.e2e-tur-$$"
        t_info "geçici alanda 5 GB yok; tur yedekleri $TUR_DIZIN altına yazılacak (sonunda siliniyor)"
    else
        t_skip "$ad_ozet"  "ne geçici alanda ($E2E_TMP) ne de $BACKUP_DIR'de 5 GB boş yer var; backup.sh zaten reddeder"
        t_skip "$ad_sayim" "tur koşulamadı (yazılacak yer yok)"
        t_skip "$ad_devam" "tur koşulamadı (yazılacak yer yok)"
        return 0
    fi

    local sonrakiler="" sonra=0 gordu=0
    for eid in $TUM_MOTORLAR; do
        if [ "$eid" = "$sabotaj" ]; then gordu=1; continue; fi
        [ "$gordu" = "1" ] || continue
        [ "$eid" = "neo4j" ] && continue      # `all` içinde bilerek atlanır
        container_running "$(primary_of "$eid")" || continue
        sonrakiler="$sonrakiler $eid"; sonra=$((sonra+1))
    done

    local pwenv rc=0
    pwenv="$(motor_bilgi "$sabotaj" | cut -d'|' -f4)"
    if [ -z "$pwenv" ]; then
        t_unknown "$ad_ozet"  "$sabotaj için parola değişkeni katalogdan okunamadı — sabotaj KURULAMADI"
        t_unknown "$ad_sayim" "sabotaj kurulamadı"
        t_unknown "$ad_devam" "sabotaj kurulamadı"
        TUR_DIZIN=""
        return 0
    fi
    if ! mkdir -p "$TUR_DIZIN"; then    # backup.sh'ın disk kontrolü için dizin VAR olmalı
        t_unknown "$ad_ozet"  "tur dizini oluşturulamadı: $TUR_DIZIN"
        t_unknown "$ad_sayim" "tur dizini oluşturulamadı"
        t_unknown "$ad_devam" "tur dizini oluşturulamadı"
        TUR_DIZIN=""
        return 0
    fi
    log "  sabote edilen motor: $sabotaj ($pwenv kasten yanlış); yedekler $TUR_DIZIN altına yazılıyor"
    log "  bu tur çalışan bütün motorları yedekler, uzun sürebilir (en fazla $SURE_TUR sn)"

    # COMPRESSION_LEVEL=1: bu tur akışı sınıyor, sıkıştırma oranını değil.
    ( export BACKUP_DIR="$TUR_DIZIN" COMPRESSION_LEVEL=1
      export "$pwenv=e2e-kasten-yanlis-parola"
      calistir "$SURE_TUR" "backup all (sabotajlı)" ./scripts/backup.sh all ) || rc=$?

    if kilit_carpismasi; then
        t_skip "$ad_ozet"  "başka bir yedekleme kilidi tutuyor"
        t_skip "$ad_sayim" "tur koşulamadı (kilit başkasında)"
        t_skip "$ad_devam" "tur koşulamadı (kilit başkasında)"
        tur_dizinini_sil
        return 0
    fi
    # Askıda kalan tur "özet basılmadı" demek değildir: hiç bitmedi. Eskiden
    # zaman aşımı da "özet yok → tur ölmüş" diye DÜŞTÜ yazılıyordu; ikisi
    # farklı: biri ürün hatası, öbürü ölçümün tamamlanmaması.
    if asildi_mi "$rc"; then
        t_unknown "$ad_ozet"  "tur $SURE_TUR sn içinde bitmedi (rc=$rc) — özet basılıp basılmayacağı ÖLÇÜLEMEDİ"
        t_unknown "$ad_sayim" "tur yarıda kesildi"
        t_unknown "$ad_devam" "tur yarıda kesildi"
        tur_dizinini_sil
        return 0
    fi
    if [ ! -r "$SON_CIKTI" ]; then
        t_unknown "$ad_ozet"  "turun çıktısı okunamadı ($SON_CIKTI)"
        t_unknown "$ad_sayim" "turun çıktısı okunamadı"
        t_unknown "$ad_devam" "turun çıktısı okunamadı"
        tur_dizinini_sil
        return 0
    fi

    # Özet satırını SATIR BAŞINDAN yakalıyoruz ve SONUNCUSUNU alıyoruz: ürünün
    # ara satırlarında da 'başarısız' geçebiliyor, ilk eşleşme yanlış sayıyı
    # verirdi.
    local basarisiz
    basarisiz="$(grep -aE '^[[:space:]]*Başarısız[[:space:]]*:' "$SON_CIKTI" | tail -1 | tr -dc '0-9')"
    if son_icerir 'Özet' && [ -n "$basarisiz" ]; then
        t_ok "bir motorun yedeği patlayınca tur ölmüyor: özet tablosu yine basılıyor"
    else
        t_fail "$ad_ozet" \
               "çıkış kodu=$rc, özette 'Başarısız' satırı yok — tur ortasından kesilmiş olabilir: $(son_ozet)"
    fi

    if [ -z "$basarisiz" ]; then
        t_unknown "$ad_sayim" "özetteki 'Başarısız' sayısı okunamadı — sabotajın sayılıp sayılmadığı ÖLÇÜLEMEDİ"
    elif [ "$basarisiz" -ge 1 ]; then
        t_ok "sabote edilen motor ($sabotaj) turda BAŞARISIZ sayıldı (yanlış parola sessizce yutulmuyor)"
    else
        t_fail "$ad_sayim" \
               "yanlış parolayla alınan yedek başarılı sayılmış — boş/eksik dosya kurtarma noktası sanılır"
    fi

    tur_devamliligi "$sabotaj" "$sonrakiler" "$sonra" "$ad_devam"
    tur_neo4j_kontrolu
    tur_dizinini_sil
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
BASLANGIC="$(date +%s)"
heading "E2E yedekleme testi — $(date '+%Y-%m-%d %H:%M')"
if [ "${E2E_GERI_YUKLEME:-1}" = "0" ]; then
    log "Yıkıcı adım KAPALI: yedekler alınıp doğrulanacak, geri yükleme denenmeyecek."
else
    warn "Bu test GERİ YÜKLEME yapar: ilgili motorun verisi, testin başında alınan yedeğe döner."
    warn "  Bakım penceresi dışında çalıştırıyorsanız: E2E_GERI_YUKLEME=0 ./scripts/e2e/backup.sh"
fi

for motor in $SECILEN; do
    motor_turu "$motor"
done

negatif_testler
yabanci_dosya_testleri
tur_dayanikliligi

temizle

# ------------------------------------------------------------------- özet ---
SURE=$(( $(date +%s) - BASLANGIC ))
t_info "süre: $((SURE / 60))m $((SURE % 60))s · kanıt değeri: $KANIT"
# Hata ya da ÖLÇÜLEMEYEN kontrol varsa günlük DURUYOR: tek ayrıntı orada.
# Hepsi ölçülüp geçtiyse betik kendi ürettiği dosyayı bırakmıyor.
if [ "$E2E_FAIL" -eq 0 ] && [ "$E2E_UNKNOWN" -eq 0 ]; then
    rm -f "$E2E_LOG"
else
    t_info "komut çıktılarının tamamı: $E2E_LOG"
fi

# Sayaçlar, özet ve ÇIKIŞ KODU ortak kütüphanede (scripts/e2e/lib.sh):
#   0 çalışan kontrollerin hepsi geçti · 1 başarısız/ölçülemedi var
#   2 HİÇBİR KONTROL ÇALIŞMADI — "hepsi yeşil" değil, "hiçbir şey ölçülmedi"
# Bu ayrımı eski özet yapamıyordu: motorların hepsi kapalıyken "7/7 geçti,
# 16 atlandı" yazıp 0 ile çıkıyordu.
e2e_finish
exit $?
