#!/bin/bash
# =============================================================================
# databases-stack — AKTİF OTURUM GEÇMİŞİ (ASH)
# =============================================================================
#   ./scripts/ash.sh ornekle <motor>   saniyede bir örnek al, her örneği TEK
#                                      SATIR JSON olarak bas (sonsuz akış)
#   ./scripts/ash.sh destek [--json]   hangi motorda ölçüm var, olmayanlarda
#                                      NEDEN yok
#
# NEDEN VAR:
# "Dün gece site 4 dakika dondu, sabah baktım her şey normal" — bu sorunun
# cevabı bu üründe yoktu. Elimizdeki iki ölçüm de o soruyu cevaplayamıyor:
#   • Prometheus 15-60 saniyede bir "motor ayakta mı" diye bakıyor. Donmuş
#     bir veritabanı up=1 döndürür: bağlantıyı kabul eder, sorguyu kilit
#     bekler. Yani klasik sessiz-yeşil.
#   • Yavaş sorgu ölçümü KÜMÜLATİF sayaç okuyor. Dört dakikalık bir olay,
#     24 saatlik toplamın içinde kaybolur ve o dört dakikada KİMİN KİMİ
#     beklettiğini hiç söylemez.
# Eksik olan şey, zaman içinde ÖRNEKLENMİŞ bir defter: her saniye "şu an
# hangi oturumlar var, ne bekliyorlar, kim kimi bekletiyor".
#
# NEDEN CONTAINER'IN İÇİNDE DÖNGÜ (her saniye yeni `docker exec` değil):
# `docker exec` süreç açma maliyeti ölçüldüğünde ~100 ms; saniyelik örnekleme
# bunun üstüne kurulamaz — hem ölçüm aracı ölçtüğü sunucuyu meşgul eder hem
# de örnek aralığı kayar. Bu yüzden motor başına TEK uzun ömürlü exec açılır
# ve döngü container'ın içinde döner.
#
# NEDEN HER ÖRNEKTE "ok" ALANI VAR — bu betiğin en önemli tasarım kararı:
# Sorgu düştüğünde (motor kapandı, bağlantı koptu, parola değişti) sıfır
# oturum yazmak, ölçüm YOKLUĞUNU "sistem boştu" diye kaydetmektir. O kayıt
# bir daha düzeltilemez: aylar sonra olayın grafiğine bakan insan, tam da
# olayın olduğu dakikada "hiç oturum yoktu" görür ve yanlış yere bakar.
# Bu yüzden her örnek ya ok=true (ölçüldü) ya ok=false (ölçülemedi) taşır;
# ikisinin arası yoktur ve "0 oturum" YALNIZCA ok=true ile anlamlıdır.
#
# ÇIKIŞ KODLARI:
#   0  akış düzgün bitti (normalde bitmez; öldürülene kadar akar)
#   1  hata
#   2  KAPSAM DIŞI — bu motorda ASH yok, ya da kullanım hatası
#   3  ÖLÇÜLEMEDİ — motor kapalı, docker yok, parola okunamadı
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/common.sh
load_env

KOD_HATA=1
KOD_KAPSAM=2
KOD_OLCUM_YOK=3

# Örnek aralığı. 1 saniye "olayın içini görmek" için gereken çözünürlük:
# 2 saniyeye çıkarıldığında 4 saniyelik bir kilit zincirinin yarısı kayboluyor.
ARALIK="${ASH_ARALIK_SN:-1}"
# Bir örnekte en çok kaç oturum taşınır. Sınırsız bırakmak, 500 bağlantılı bir
# olayda saniyede 500 satır demek — hem akışı hem defteri boğar. Kesilirse
# kesildiği JSON'da YAZILIR (kirli=true); sessizce kırpmıyoruz.
ADET="${ASH_ORNEK_ADET:-40}"
# Sorgu metni uzunluğu. Tam metin gerekmiyor: aranan şey "hangi sorgu", "ne
# kadar uzun" değil.
METIN="${ASH_SORGU_UZUNLUK:-200}"

# ---------------------------------------------------------------- kapsam ---
# Kapsam dışı motorda NEDEN olmadığını yazıyoruz. "Desteklenmiyor" tek başına,
# kullanıcıya bunun bir eksiklik mi yoksa motorun doğası mı olduğunu bırakmaz.
ash_motorlari() { printf 'postgresql\nmariadb\n'; }

ash_destekli() {
    case "$1" in postgresql|mariadb) return 0 ;; *) return 1 ;; esac
}

kapsam_notu() {
    case "$1" in
        mongodb)
            printf '%s' "currentOp() ile teknik olarak mümkün ama BU TURDA YAPILMADI — kapsam dışı" ;;
        redis)
            printf '%s' "tek iş parçacıklı; \"kim kimi bekletiyor\" sorusu yok, yavaş komut zaten SLOWLOG'da" ;;
        mssql)
            printf '%s' "sys.dm_exec_requests ile mümkün ama BU TURDA YAPILMADI — kapsam dışı" ;;
        clickhouse|cassandra|elasticsearch|kafka|rabbitmq|neo4j|minio)
            printf '%s' "bu motorda oturum/bekleme modeli ilişkisel motorlarınkinden farklı; ayrı bir tasarım ister" ;;
        *)
            printf '%s' "bu motorda oturum örneklemesi tanımlı değil" ;;
    esac
}

# ------------------------------------------------------------------ araç ---
js() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "${1-}"; }

motor_kontrol() {
    [ -n "${1:-}" ] || { err "Motor belirtilmedi. Örnek: ./scripts/ash.sh ornekle postgresql"; exit "$KOD_KAPSAM"; }
    ash_destekli "$1" || { err "ASH bu motorda yok: $1 — $(kapsam_notu "$1")"; exit "$KOD_KAPSAM"; }
}

docker_var_mi() {
    command -v docker >/dev/null 2>&1 || { err "docker yok"; exit "$KOD_OLCUM_YOK"; }
}

# =============================================================================
# ÖRNEKLEYİCİ
# =============================================================================
# Container'ın içinde dönen döngü şu üçlüyü basar:
#   S<TAB><epoch><TAB>ok|hata      örnek başlığı
#   <oturum satırları>             sekmeyle ayrılmış alanlar
#   E                              örnek sonu
# Bunu bir python3 süzgeci tek satır JSON'a çeviriyor. Ayrıştırmayı kabuğa
# yaptırmıyoruz: sorgu metninde her karakter geçebilir ve awk/sed ile doğru
# JSON kaçışı yapmanın güvenli yolu yok.

pg_dongu() {
    local kul="${POSTGRES_USER:-root}" db="${DEFAULT_DATABASE:-postgres}"
    # pg_blocking_pids: "bu oturumu kim bekletiyor" sorusunun DOĞRUDAN cevabı.
    # Kendi bağlantımızı (pg_backend_pid) dışarıda bırakıyoruz — ölçüm aracının
    # kendisi ölçümde görünmemeli, yoksa her örnekte bir oturum fazla sayılır.
    local sql
    # TEK SÜTUN, ayraç chr(31) (unit separator). Neden sekme değil:
    # psql'in -F'	' seçeneği kabuktan geçerken GERÇEK SEKME değil, iki
    # karakterlik "	" dizgisi olarak gidiyordu; ayrıştırıcı satırı
    # bölemiyor, pid sayıya çevrilemiyor ve satır SESSİZCE düşüyordu.
    # Sonuç ekranda "ölçüldü, 0 oturum" görünüyordu — yani tam da bu
    # özelliğin engellemek için yazıldığı sahte sıfır. chr(31) veride
    # geçmez; sorgu metnindeki sekme/satır sonu da zaten temizleniyor.
    sql="SELECT concat_ws(chr(31),
                pid,
                coalesce(state,''),
                coalesce(wait_event_type,''),
                coalesce(wait_event,''),
                coalesce(backend_type,''),
                coalesce(usename,''),
                coalesce(datname,''),
                coalesce(round(extract(epoch from (now() - xact_start))::numeric, 1)::text, ''),
                coalesce(array_to_string(pg_blocking_pids(pid), ','), ''),
                left(regexp_replace(coalesce(query, ''), '[[:space:]]+', ' ', 'g'), $METIN))
         FROM pg_stat_activity
         WHERE pid <> pg_backend_pid()
           AND coalesce(state, '') <> 'idle'
           AND coalesce(backend_type, 'client backend') = 'client backend'
         ORDER BY xact_start NULLS LAST
         LIMIT $ADET;"
    printf '%s' "$sql"
}

my_dongu() {
    # MariaDB'de bekleme zinciri BU TURDA YOK: INNODB_LOCK_WAITS sürümden
    # sürüme yer değiştirdi (10.6'da performance_schema.data_lock_waits'e
    # taşındı) ve yanlış sürümde sessizce boş döner. Boş dönen bir zincir
    # "kimse kimseyi bekletmiyor" diye okunur — yani ölçemediğimizi ölçmüş
    # gibi göstermiş oluruz. Zincir alanı bu motorda BOŞ ve bunu 'destek'
    # çıktısı açıkça söylüyor.
    printf '%s' "SELECT CONCAT_WS(CHAR(31),
                ID,
                IFNULL(COMMAND,''),
                IFNULL(STATE,''),
                '',
                'client',
                IFNULL(USER,''),
                IFNULL(DB,''),
                IFNULL(TIME,0),
                '',
                LEFT(REPLACE(REPLACE(REPLACE(IFNULL(INFO,''), '
', ' '), '
', ' '), '	', ' '), $METIN))
         FROM information_schema.PROCESSLIST
         WHERE COMMAND NOT IN ('Sleep','Daemon','Binlog Dump')
           AND ID <> CONNECTION_ID()
         ORDER BY TIME DESC
         LIMIT $ADET;"
}

cmd_ornekle() {
    local motor="$1"
    motor_kontrol "$motor"
    docker_var_mi
    local C; C="$(primary_of "$motor")"
    if ! docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true; then
        err "$motor çalışmıyor ($C) — örnekleme canlı sunucudan yapılır."
        exit "$KOD_OLCUM_YOK"
    fi

    local sql ic
    case "$motor" in
        postgresql)
            sql="$(pg_dongu)"
            # -q sessiz, -t başlıksız, -A hizalamasız, -F sekme ayraç.
            # ON_ERROR_STOP=1 ŞART: 0 iken psql hatalı sorguda bile ÇIKIŞ 0
            # döner, çıktı da boş olur — yani sorgu hatası 'ölçüldü, 0 oturum'
            # diye kaydedilir. Bu tam olarak engellemeye çalıştığımız sahte
            # sıfırdır ve sahada birebir yaşandı: SQL bozukken defter 30
            # saniye boyunca 'sistem boştu' yazdı.
            ic="export PGPASSWORD=\"\$PGPW\";
                while :; do
                  now=\$(date +%s)
                  if out=\$(psql -qtAX -U \"\$PGUSER_\" -d \"\$PGDB_\" -v ON_ERROR_STOP=1 -c \"\$SQL\" 2>/dev/null); then
                      printf 'S\t%s\tok\n' \"\$now\"
                      [ -n \"\$out\" ] && printf '%s\n' \"\$out\"
                  else
                      printf 'S\t%s\thata\n' \"\$now\"
                  fi
                  printf 'E\n'
                  sleep $ARALIK
                done"
            docker exec \
                -e PGPW="${POSTGRES_PASSWORD:-$DB_PASSWORD}" \
                -e PGUSER_="${POSTGRES_USER:-root}" \
                -e PGDB_="${DEFAULT_DATABASE:-postgres}" \
                -e SQL="$sql" \
                "$C" sh -c "$ic"
            ;;
        mariadb)
            sql="$(my_dongu)"
            ic="while :; do
                  now=\$(date +%s)
                  if out=\$(MYSQL_PWD=\"\$MYPW\" mariadb -N -B -u \"\$MYUSER_\" -e \"\$SQL\" 2>/dev/null); then
                      printf 'S\t%s\tok\n' \"\$now\"
                      [ -n \"\$out\" ] && printf '%s\n' \"\$out\"
                  else
                      printf 'S\t%s\thata\n' \"\$now\"
                  fi
                  printf 'E\n'
                  sleep $ARALIK
                done"
            # Parola adı DEPONUN KURALINA göre: MARIADB_PASSWORD, yoksa
            # DB_PASSWORD (bkz. pitr.sh'taki motor_parolasi). İlk sürümde
            # MARIADB_ROOT_PASSWORD yazmıştım; o değişken bu depoda YOK ve
            # sorgu her örnekte düşüyordu. Üç değerli defter sayesinde bu
            # "0 oturum" diye DEĞİL "27 örnek ÖLÇÜLEMEDİ" diye göründü —
            # yani hatanın kendisi tasarımın işe yaradığının kanıtı oldu.
            docker exec \
                -e MYPW="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}" \
                -e MYUSER_=root \
                -e SQL="$sql" \
                "$C" sh -c "$ic"
            ;;
    esac
}

# Ham akışı tek satır JSON'a çeviren süzgeç. Ayrı bir komut olarak duruyor ki
# hem 'ornekle' onu boru ile besleyebilsin hem de testler onu ham girdiyle
# TEK BAŞINA sınayabilsin — ayrıştırıcıyı canlı veritabanı olmadan ölçmenin
# tek yolu bu.
cmd_cevir() {
    # PROGRAM GEÇİCİ DOSYAYA YAZILIYOR, heredoc ile stdin'e DEĞİL:
    # `python3 - <<EOF` yazıldığında program stdin'den okunur ve VERİ
    # BORUSU KAYBOLUR — süzgeç hiçbir şey basmaz, üstelik hata da vermez.
    # Sessizce boş çıktı üreten bir ölçüm aracı, bu projenin en sevmediği
    # şey. (Bu hata yazılırken yapıldı ve ilk denemede yakalandı.)
    local prog
    prog="$(mktemp "${TMPDIR:-/tmp}/ash-cevir.XXXXXX")" || return 1
    trap 'rm -f "$prog"' RETURN
    cat > "$prog" <<'PY'
import json, os, sys

motor = os.environ.get("ASH_MOTOR", "")
ALAN = ("pid", "durum", "bekleme_turu", "bekleme", "tur",
        "kullanici", "vt", "islem_sn", "bekleten", "sorgu")
AYRAC = chr(31)          # unit separator — veride geçmez

zaman = None
ok = None
satirlar = []


def bas():
    if zaman is None:
        return
    kayit = {"t": zaman, "motor": motor, "ok": bool(ok)}
    if ok:
        oturumlar = []
        bozuk = 0
        for ham in satirlar:
            # Ayraç chr(31): veride geçmez. Sekme kullanan ilk sürümde
            # ayraç kabuktan geçerken iki karakterlik "\t" dizgisine
            # dönüşüyordu; satır bölünemiyor, pid sayıya çevrilemiyor ve
            # satır SESSİZCE düşüyordu — sonuç "ölçüldü, 0 oturum".
            p = ham.split(AYRAC)
            if len(p) < len(ALAN):
                p += [""] * (len(ALAN) - len(p))
            o = dict(zip(ALAN, p[:len(ALAN)]))
            try:
                o["pid"] = int(o["pid"])
            except ValueError:
                # ÇÖZÜLEMEYEN SATIR SESSİZCE DÜŞMEZ. Sayılır; hepsi
                # çözülemediyse örnek "ölçüldü" sayılmaz.
                bozuk += 1
                continue
            try:
                o["islem_sn"] = float(o["islem_sn"]) if o["islem_sn"] else None
            except ValueError:
                o["islem_sn"] = None
            o["bekleten"] = [int(x) for x in o["bekleten"].split(",")
                             if x.strip().isdigit()]
            oturumlar.append(o)
        if bozuk and not oturumlar:
            # Satır geldi ama HİÇBİRİ çözülemedi: bu "boştu" değil,
            # "okuyamadım"dır. Sıfır yazmak sahte sıfır olurdu.
            kayit["ok"] = False
            kayit["neden"] = "%d satır çözülemedi (ayraç/biçim)" % bozuk
        else:
            kayit["n"] = len(oturumlar)
            kayit["oturumlar"] = oturumlar
            if bozuk:
                kayit["bozuk"] = bozuk
    sys.stdout.write(json.dumps(kayit, ensure_ascii=False) + "\n")
    sys.stdout.flush()


for ham in sys.stdin:
    ham = ham.rstrip("\n").rstrip("\r")
    if ham.startswith("S\t"):
        p = ham.split("\t")
        zaman = int(p[1]) if len(p) > 1 and p[1].isdigit() else None
        ok = (len(p) > 2 and p[2] == "ok")
        satirlar = []
    elif ham == "E":
        bas()
        zaman, ok, satirlar = None, None, []
    elif zaman is not None:
        satirlar.append(ham)
PY
    ASH_MOTOR="${1:-}" python3 "$prog"
}

# =============================================================================
# KOMUT: destek
# =============================================================================
cmd_destek() {
    local json="${1:-0}" m
    if [ "$json" = "1" ]; then
        printf '{"engines":{'
        local ilk=1
        for m in $(katalog_motorlari); do
            [ "$ilk" = 1 ] || printf ','
            ilk=0
            if ash_destekli "$m"; then
                printf '%s:{"supported":true,"chain":%s}' "$(js "$m")" \
                    "$([ "$m" = postgresql ] && echo true || echo false)"
            else
                printf '%s:{"supported":false,"reason":%s}' "$(js "$m")" \
                    "$(js "$(kapsam_notu "$m")")"
            fi
        done
        printf '}}\n'
        return 0
    fi
    heading "Aktif oturum geçmişi — kapsam"
    for m in $(katalog_motorlari); do
        if ash_destekli "$m"; then
            if [ "$m" = postgresql ]; then
                ok "$m — örnekleniyor · bekleme zinciri VAR (pg_blocking_pids)"
            else
                ok "$m — örnekleniyor · bekleme zinciri YOK (aşağıya bakın)"
            fi
        else
            warn "$m — kapsam dışı: $(kapsam_notu "$m")"
        fi
    done
    cat <<'EOF'

MariaDB'de bekleme zinciri neden yok: INNODB_LOCK_WAITS sürümden sürüme yer
değiştirdi (10.6'da performance_schema.data_lock_waits'e taşındı) ve yanlış
sürümde SESSİZCE BOŞ döner. Boş dönen bir zincir "kimse kimseyi bekletmiyor"
diye okunur — yani ölçemediğimizi ölçmüş gibi göstermiş oluruz. Bu yüzden
alan boş bırakılıyor ve burada yazıyor.

EOF
}

katalog_motorlari() {
    python3 -c '
import json,sys
c=json.load(open(sys.argv[1],encoding="utf-8"))
print("\n".join(e["id"] for e in c["engines"] if e.get("category") != "tool"))' \
        "$CATALOG" 2>/dev/null || ash_motorlari
}

kullanim() {
cat <<EOF

Aktif oturum geçmişi (ASH) — databases-stack

  ./scripts/ash.sh ornekle <motor>
        Saniyede bir örnek alır ve her örneği TEK SATIR JSON olarak basar.
        Sonsuz akıştır; controller bunu okuyup deftere yazar.
        Her satırda "ok" alanı vardır: ok=false ise O AN ÖLÇÜLEMEDİ demektir,
        "sistem boştu" DEMEK DEĞİLDİR.

  ./scripts/ash.sh cevir
        Ham akışı (stdin) JSON'a çevirir. 'ornekle' bunu kendi kullanır;
        ayrı durmasının sebebi ayrıştırıcının canlı veritabanı olmadan
        sınanabilmesi.

  ./scripts/ash.sh sorgu <motor>
        Örnekleyicinin motora sorduğu SQL'i basar. Neyin ölçüldüğünü
        okuyamadığınız bir ölçüme güvenemezsiniz.

  ./scripts/ash.sh destek [--json]
        Hangi motorda ölçüm var, olmayanlarda NEDEN yok.

  Ayarlar: ASH_ARALIK_SN=$ARALIK · ASH_ORNEK_ADET=$ADET · ASH_SORGU_UZUNLUK=$METIN

  Çıkış kodları: 0 tamam · 1 hata · 2 kapsam dışı · 3 ölçülemedi

EOF
}

KOMUT="${1:-yardim}"
shift 2>/dev/null || true

case "$KOMUT" in
    ornekle)  cmd_ornekle "${1:-}" | cmd_cevir "${1:-}" ;;
    sorgu)    # Ölçüm aracının motora SORDUĞU şey görünür olmalı: neyin
              # ölçüldüğünü okuyamadığınız bir ölçüme güvenemezsiniz.
              motor_kontrol "${1:-}"
              case "${1:-}" in postgresql) pg_dongu ;; mariadb) my_dongu ;; esac
              printf '
' ;;
    cevir)    cmd_cevir "${1:-}" ;;
    destek)   [ "${1:-}" = "--json" ] && cmd_destek 1 || cmd_destek 0 ;;
    *)        kullanim; exit "$KOD_KAPSAM" ;;
esac
