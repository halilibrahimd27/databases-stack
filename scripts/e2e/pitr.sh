#!/bin/bash
# =============================================================================
# databases-stack — UÇTAN UCA TEST: ZAMANDA BİR ANA DÖNME (PITR)
# =============================================================================
# Bu paketin ölçtüğü TEK ASIL ŞEY tek cümledir:
#
#     T1'de A satırı yazılır · T2'de B satırı yazılır ·
#     T1 ile T2 ARASINA dönülür → kopyada A VAR, B YOK.
#
# Neden bu cümle: "kurtarma başarıyla bitti" ifadesi hiçbir şey kanıtlamaz.
# Yanlış bir ana dönmüş olabiliriz ve motor bundan şikâyet etmez; taban
# yedeğini olduğu gibi açıp WAL'ı hiç oynatmamış da olabiliriz — o da
# "başarılı" görünür. İki satırın biri VARKEN diğeri YOKSA, hem tabanın
# üzerine değişiklik günlüğünün oynatıldığı hem de DOĞRU YERDE durulduğu
# aynı anda kanıtlanmış olur. Tek bir satır saymak bunu ayırt edemez.
#
# ZAMAN ARALIKLARI NEDEN 3 SANİYE: MariaDB binlog olaylarının zaman damgası
# SANİYE çözünürlüğündedir. A ile hedef arasında 1 saniye bıraksaydık, ikisi
# aynı saniyeye düşer ve --stop-datetime A'yı da eleyebilirdi; ölçüm ürünü
# değil kendi kurgusunu düşürürdü.
#
# AYRICA ÖLÇÜLENLER:
#   • Aralık DIŞINA dönme denemesi REDDEDİLİYOR mu (çıkış 2) ve üretim
#     gerçekten ELLENMEDEN mi kalıyor
#   • Arşiv temizliği saklama süresine uyuyor mu — VE saklanan bir tabanın
#     ihtiyaç duyduğu dosyaya dokunmuyor mu (bu ikincisi asıl tehlike:
#     yaşa bakan düz bir silme, elde AÇILAMAYAN bir taban bırakır)
#
# BU PAKET YIKICI DEĞİLDİR — failover.sh'ın aksine.
#   • Kurtarma yalnız `--prova` ile, TEK KULLANIMLIK bir container ve
#     hacimde yapılır; üretim veri dizinine dokunulmaz.
#   • Üretimde yapılan tek değişiklik kendi test tablosudur (e2e_pitr) ve
#     sonunda düşürülür.
#   • `pitr.sh taban` GERÇEK bir taban yedeği üretir ve onu silmez: o dosya
#     kurulumun PITR penceresini genişletir, çöp değildir. Saklama
#     politikasına backup.sh'ın `clean` komutu bakar.
#
# Kullanım (yığın kökünden):
#   ./scripts/e2e/pitr.sh                 postgresql + mariadb
#   ./scripts/e2e/pitr.sh mariadb         yalnız biri
#
# Süre: motor başına ~2–5 dk (taban yedeği + geçici kopyanın açılması).
#
# Ayarlar:
#   E2E_PITR_ARA=3            A → hedef → B arasındaki saniye
#   E2E_PITR_PROVA_TO=900     tek bir `don --prova` için üst sınır
#
# Çıkış kodu (scripts/e2e/lib.sh):
#   0 çalışan kontrollerin hepsi geçti · 1 kaldı ya da ÖLÇÜLEMEDİ
#   2 HİÇBİR kontrol çalışmadı · 3 eksik kapsam · 130 kesildi
# =============================================================================
# `set -e` BİLEREK YOK: her kontrol tek tek raporlanmalı, ilk hatada ölmemeli.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env
source scripts/e2e/lib.sh
E2E_SUITE="pitr"
export PYTHONIOENCODING=utf-8

ARA="${E2E_PITR_ARA:-3}"
PROVA_TO="${E2E_PITR_PROVA_TO:-900}"
TABLO="e2e_pitr"
TMP="$(mktemp -d)" || { printf 'geçici dizin açılamadı\n' >&2; exit 1; }
temizlik() { rm -rf "$TMP" 2>/dev/null; }
trap temizlik EXIT

# ---------------------------------------------------------------- yardımcı --
# pitr.sh'ın SON SATIRI tek satır JSON'dur. Çıktının tamamını ayrıştırmaya
# çalışmıyoruz: ilerleme satırları da aynı akışta ve onları JSON sanmak,
# ölçüm aracını ürünün log biçimine bağımlı kılardı.
son_json() { printf '%s\n' "$1" | grep -a '^{' | tail -1; }

json_alan() {   # json_alan <json> <alan>
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
print("" if v is None else v)' "$2" 2>/dev/null
}

pg_c()  { primary_of postgresql; }
my_c()  { primary_of mariadb; }

pg_q() {   # pg_q <sql>   (varsayılan veritabanında)
    ( export PGPASSWORD="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"
      docker exec -e PGPASSWORD "$(pg_c)" psql -U "${POSTGRES_USER:-root}" \
          -h 127.0.0.1 -d "${DEFAULT_DATABASE:-defaultdb}" -tAq -c "$1" ) 2>&1
}
my_q() {   # my_q <sql>
    ( export MYSQL_PWD="${MARIADB_PASSWORD:-${DB_PASSWORD:-}}"
      docker exec -e MYSQL_PWD "$(my_c)" mariadb -u root -N -B -e "$1" ) 2>&1
}

motor_q() { case "$1" in postgresql) pg_q "$2" ;; mariadb) my_q "$2" ;; esac; }

# Kurtarılan kopyaya sorulacak soru. İki motorda da AYNI cevabı üretmeli:
# etiketler alfabetik, virgülle. Böylece karşılaştırma tek bir dizge
# eşitliğine iner ve "A" ile "A,B" arasındaki fark tartışmasız olur.
dogrula_sql() {
    case "$1" in
        postgresql) printf "SELECT coalesce(string_agg(etiket,',' ORDER BY etiket),'<bos>') FROM %s" "$TABLO" ;;
        mariadb)    printf "SELECT IFNULL(GROUP_CONCAT(etiket ORDER BY etiket),'<bos>') FROM \`%s\`.%s" "${DEFAULT_DATABASE:-defaultdb}" "$TABLO" ;;
    esac
}

tablo_kur() {
    case "$1" in
        postgresql)
            pg_q "DROP TABLE IF EXISTS $TABLO" >/dev/null
            pg_q "CREATE TABLE $TABLO (etiket text PRIMARY KEY, yazildi timestamptz DEFAULT now())" >/dev/null
            ;;
        mariadb)
            my_q "CREATE DATABASE IF NOT EXISTS \`${DEFAULT_DATABASE:-defaultdb}\`" >/dev/null
            my_q "DROP TABLE IF EXISTS \`${DEFAULT_DATABASE:-defaultdb}\`.$TABLO" >/dev/null
            my_q "CREATE TABLE \`${DEFAULT_DATABASE:-defaultdb}\`.$TABLO (etiket varchar(16) PRIMARY KEY, yazildi datetime DEFAULT current_timestamp)" >/dev/null
            ;;
    esac
}
satir_yaz() {   # satir_yaz <motor> <etiket>
    case "$1" in
        postgresql) pg_q "INSERT INTO $TABLO(etiket) VALUES ('$2')" >/dev/null ;;
        mariadb)    my_q "INSERT INTO \`${DEFAULT_DATABASE:-defaultdb}\`.$TABLO(etiket) VALUES ('$2')" >/dev/null ;;
    esac
}
tablo_kaldir() {
    case "$1" in
        postgresql) pg_q "DROP TABLE IF EXISTS $TABLO" >/dev/null 2>&1 ;;
        mariadb)    my_q "DROP TABLE IF EXISTS \`${DEFAULT_DATABASE:-defaultdb}\`.$TABLO" >/dev/null 2>&1 ;;
    esac
}
uretim_etiketleri() { motor_q "$1" "$(dogrula_sql "$1")" | tr -d '\r' | grep -v '^$' | head -1; }

# =============================================================================
# ANA ÖLÇÜM: A VAR, B YOK
# =============================================================================
olc_motor() {
    local motor="$1" C hedef cikti rc j sonuc uretim

    C="$(primary_of "$motor")"
    if ! container_running "$C"; then
        t_skip "$motor · A-var-B-yok" "motor kapalı ($C) — PITR ölçülemez, ön koşul yok"
        return 0
    fi

    # PITR gerçekten açık mı? Ürünün KENDİ durum çıktısından okuyoruz;
    # "compose'da yazıyor" ile "sunucuda açık" farklı şeyler ve aradaki fark
    # tam olarak bu paketin yakalaması gereken şey.
    local durum_json state
    durum_json="$(./scripts/pitr.sh durum "$motor" --json 2>/dev/null | grep -a '^{' | tail -1)"
    if [ -z "$durum_json" ]; then
        t_unknown "$motor · PITR açık mı" "pitr.sh durum --json çıktı vermedi"
        return 0
    fi
    state="$(printf '%s' "$durum_json" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
e = (d.get("engines") or [{}])[0]
print(e.get("state", ""))' 2>/dev/null)"
    if [ "$state" != "acik" ]; then
        t_skip "$motor · A-var-B-yok" \
            "PITR açık değil (durum: ${state:-okunamadı}) — önce: ./scripts/pitr.sh kur $motor && docker compose up -d $motor"
        return 0
    fi
    t_ok "$motor · PITR açık (ürünün kendi durum çıktısından: $state)"

    # --- 1) TABAN --------------------------------------------------------
    # Taban ÖNCE alınıyor: A ve B tabandan SONRA yazılmalı ki ikisi de
    # yalnızca değişiklik günlüğünden gelsin. Tabandan önce yazılsalardı A
    # zaten tabanın içinde olurdu ve "A var" hiçbir şey kanıtlamazdı.
    tablo_kur "$motor"
    if ! ./scripts/pitr.sh taban "$motor" >"$TMP/taban.log" 2>&1; then
        t_unknown "$motor · A-var-B-yok" \
            "taban yedeği alınamadı — ölçüm KURULAMADI: $(tail -2 "$TMP/taban.log" | tr '\n' ' ')"
        return 0
    fi
    t_ok "$motor · PITR tabanı alındı"

    # --- 2) A · hedef · B -------------------------------------------------
    satir_yaz "$motor" A
    sleep "$ARA"
    hedef="$(date '+%Y-%m-%d %H:%M:%S')"
    sleep "$ARA"
    satir_yaz "$motor" B

    uretim="$(uretim_etiketleri "$motor")"
    if [ "$uretim" != "A,B" ]; then
        t_unknown "$motor · A-var-B-yok" \
            "kurgu kurulamadı: üretimde beklenen 'A,B' yerine '${uretim:-<okunamadı>}' var"
        tablo_kaldir "$motor"
        return 0
    fi
    t_info "üretimde A,B var · hedef an: $hedef (A'dan ${ARA} sn sonra, B'den ${ARA} sn önce)"

    # --- 3) Değişiklik günlüğünü arşive it -------------------------------
    # PostgreSQL'de WAL segmenti DOLMADAN arşive düşmez; itmezsek hedef an
    # "henüz arşivde değil" diye REDDEDİLİR ve paket ürünü değil kendi
    # aceleciliğini ölçmüş olur.
    if ! ./scripts/pitr.sh arsivle "$motor" >"$TMP/ars.log" 2>&1; then
        # MariaDB'de prova binlog'u doğrudan üretim container'ından okuyor;
        # host arşivine kopyalama başarısız olsa da ana ölçüm yapılabilir.
        # PostgreSQL'de ise arşiv ŞART.
        if [ "$motor" = "postgresql" ]; then
            t_unknown "$motor · A-var-B-yok" \
                "WAL arşive itilemedi — ölçüm KURULAMADI: $(tail -2 "$TMP/ars.log" | tr '\n' ' ')"
            tablo_kaldir "$motor"
            return 0
        fi
        t_unknown "$motor · binlog host arşivine kopyalanıyor" \
            "$(tail -2 "$TMP/ars.log" | tr '\n' ' ')"
    else
        t_ok "$motor · değişiklik günlüğü arşive itildi"
    fi

    # --- 4) ASIL ÖLÇÜM ----------------------------------------------------
    cikti="$(timeout "$PROVA_TO" ./scripts/pitr.sh don "$motor" "$hedef" --prova \
                --dogrula "$(dogrula_sql "$motor")" 2>&1)"
    rc=$?
    j="$(son_json "$cikti")"
    if [ -z "$j" ]; then
        t_unknown "$motor · A-var-B-yok" "pitr.sh don JSON basmadı (çıkış $rc)"
        tablo_kaldir "$motor"
        return 0
    fi
    if [ "$(json_alan "$j" ok)" != "True" ] && [ "$(json_alan "$j" ok)" != "true" ]; then
        t_fail "$motor · A-var-B-yok" \
            "kurtarma yapılamadı (çıkış $rc): $(json_alan "$j" detail)"
        tablo_kaldir "$motor"
        return 0
    fi

    sonuc="$(json_alan "$j" verify)"
    case "$sonuc" in
        A)
            t_ok "$motor · A-VAR-B-YOK — $hedef anına dönüldü, kopyada yalnız A var ($(json_alan "$j" seconds) sn)"
            ;;
        A,B)
            t_fail "$motor · A-var-B-yok" \
                "kopyada B DE VAR — hedef an aşılmış, kurtarma doğru yerde durmamış (kopya: '$sonuc')"
            ;;
        '<bos>'|'')
            t_fail "$motor · A-var-B-yok" \
                "kopya BOŞ — taban açıldı ama değişiklik günlüğü hiç oynatılmamış görünüyor (kopya: '${sonuc:-<yok>}')"
            ;;
        ÖLÇÜLEMEDİ*)
            t_unknown "$motor · A-var-B-yok" "doğrulama sorgusu kopyada çalıştırılamadı: $sonuc"
            ;;
        *)
            t_fail "$motor · A-var-B-yok" "kopyada beklenmeyen içerik: '$sonuc' (beklenen: 'A')"
            ;;
    esac
    t_info "kurtarmanın durduğu yer (motorun kendi cümlesi): $(json_alan "$j" stopped_at)"

    # --- 5) --prova ÜRETİME DOKUNMADI mı ---------------------------------
    # Bunu ayrıca ölçüyoruz çünkü "dokunmuyoruz" sözü bir NİYET beyanıdır;
    # üretimde B'nin hâlâ duruyor olması ise bir ölçümdür.
    uretim="$(uretim_etiketleri "$motor")"
    if [ "$uretim" = "A,B" ]; then
        t_ok "$motor · prova üretime dokunmadı (üretimde hâlâ A,B)"
    else
        t_fail "$motor · prova üretime dokunmadı" \
            "üretimde 'A,B' bekleniyordu, '${uretim:-<okunamadı>}' var — PROVA ÜRETİMİ DEĞİŞTİRMİŞ"
    fi

    # --- 6) ARALIK DIŞI HEDEF REDDEDİLİYOR mu ----------------------------
    # İki yön de deneniyor. Yalnız geleceği denemek yetmez: "gelecek"
    # tarihi ayrıştırma aşamasında da elenebilir ve aralık kapısının
    # çalıştığını sanırdık.
    local gelecek gecmis
    gelecek="$(date -d "+2 days" '+%Y-%m-%d %H:%M:%S')"
    gecmis="$(date -d "-3650 days" '+%Y-%m-%d %H:%M:%S')"
    local i ad zaman
    for i in gelecek gecmis; do
        if [ "$i" = "gelecek" ]; then ad="aralığın SONRASI"; zaman="$gelecek"
        else ad="aralığın ÖNCESİ"; zaman="$gecmis"; fi
        cikti="$(./scripts/pitr.sh don "$motor" "$zaman" --prova 2>&1)"; rc=$?
        j="$(son_json "$cikti")"
        if [ "$rc" -ne 2 ]; then
            t_fail "$motor · $ad reddediliyor" \
                "çıkış 2 (REDDEDİLDİ) bekleniyordu, $rc geldi: $(json_alan "$j" detail)"
            continue
        fi
        case "$(json_alan "$j" detail)" in
            reddedildi:*)
                t_ok "$motor · $ad reddedildi ve gerekçesi yazıldı"
                ;;
            *)
                t_fail "$motor · $ad reddediliyor" \
                    "çıkış 2 doğru ama gerekçe 'reddedildi:' ile başlamıyor: $(json_alan "$j" detail)"
                ;;
        esac
    done
    uretim="$(uretim_etiketleri "$motor")"
    if [ "$uretim" = "A,B" ]; then
        t_ok "$motor · reddedilen denemeler üretimi ELLEMEDİ"
    else
        t_fail "$motor · reddedilen denemeler üretimi ellemedi" \
            "üretimde 'A,B' bekleniyordu, '${uretim:-<okunamadı>}' var"
    fi

    tablo_kaldir "$motor"
    return 0
}

# =============================================================================
# ARŞİV TEMİZLİĞİ
# =============================================================================
# SAHTE bir arşivde ölçülüyor (BACKUP_DIR başka bir dizine yönlendirilerek).
# Gerçek arşiv üzerinde ölçmek iki şeyi birden bozardı: kurulumun PITR
# penceresini gerçekten kısaltırdı ve sonucu o anki dosya yaşlarına bağımlı
# kılardı — yani her koşumda başka bir şey ölçülürdü.
olc_temizlik() {
    local kok="$TMP/arsiv" w t
    w="$kok/postgresql/wal"; t="$kok/postgresql/taban"
    mkdir -p "$w" "$t" "$kok/postgresql/full" \
             "$kok/mariadb/binlog" "$kok/mariadb/taban" "$kok/mariadb/full"

    # Taban: 20 gün önce alınmış ve HÂLÂ SAKLANIYOR (backup.sh'ın "her
    # motorda en yeni N kopyayı yaşı ne olursa olsun koru" kuralı yüzünden
    # bu gerçek bir durumdur, kurgu değil).
    printf 'sahte taban\n' | gzip > "$t/postgresql_taban_eski.tar.gz"
    touch -d "20 days ago" "$t/postgresql_taban_eski.tar.gz"

    # ESKİ segment: tabandan da önce → SİLİNMELİ
    printf 'x' > "$w/000000010000000000000001"; touch -d "40 days ago" "$w/000000010000000000000001"
    # GEREKLİ segment: tabandan sonra → yaşı 15 gün olsa da KALMALI
    printf 'x' > "$w/000000010000000000000009"; touch -d "15 days ago" "$w/000000010000000000000009"
    # Zaman çizgisi geçmişi: yaşı ne olursa olsun KALMALI
    printf 'x' > "$w/00000002.history"; touch -d "60 days ago" "$w/00000002.history"

    local cikti rc
    cikti="$(BACKUP_DIR="$kok" ./scripts/pitr.sh temizle 7 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        t_unknown "arşiv temizliği" "pitr.sh temizle çıkış $rc: $(printf '%s' "$cikti" | tail -2 | tr '\n' ' ')"
        return 0
    fi

    if [ -e "$w/000000010000000000000001" ]; then
        t_fail "arşiv temizliği · saklama süresi uygulanıyor" \
            "40 günlük segment 7 gün kuralına rağmen SİLİNMEDİ — arşiv sınırsız büyür"
    else
        t_ok "arşiv temizliği · saklama süresini aşan segment silindi (40 gün > 7 gün)"
    fi

    if [ -e "$w/000000010000000000000009" ]; then
        t_ok "arşiv temizliği · SAKLANAN TABANIN gerektirdiği segment korundu (15 günlük, ama taban 20 günlük)"
    else
        t_fail "arşiv temizliği · taban zinciri korunuyor" \
            "20 günlük taban hâlâ dururken onun WAL'ı SİLİNDİ — elde AÇILAMAYAN bir taban kaldı"
    fi

    if [ -e "$w/00000002.history" ]; then
        t_ok "arşiv temizliği · zaman çizgisi geçmişi (*.history) korundu"
    else
        t_fail "arşiv temizliği · *.history korunuyor" \
            "60 günlük .history silindi — 'latest' zaman çizgisini izleyen kurtarmalar eski çizgide takılır"
    fi
    return 0
}

# =============================================================================
# ÇALIŞTIR
# =============================================================================
t_head "PITR — zamanda bir ana dönme"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    t_unknown "docker erişimi" "docker yok ya da erişilemiyor — hiçbir motor ölçülemedi"
    e2e_finish; exit $?
fi

MOTORLAR=("$@")
if [ "${#MOTORLAR[@]}" -eq 0 ]; then MOTORLAR=(postgresql mariadb); fi

for M in "${MOTORLAR[@]}"; do
    case "$M" in
        postgresql|mariadb) ;;
        *) t_skip "$M" "PITR yalnız postgresql ve mariadb'de destekleniyor (./scripts/pitr.sh durum)"
           continue ;;
    esac
    t_head "$M"
    olc_motor "$M"
done

t_head "arşiv saklama politikası"
olc_temizlik

e2e_finish
exit $?
