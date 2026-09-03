#!/bin/bash
# =============================================================================
# databases-stack — E2E: AKTİF OTURUM GEÇMİŞİ (scripts/ash.sh + /api/ash)
# =============================================================================
# Bu paketin sorduğu soru "ASH açık mı" değil:
#
#     KURGULANMIŞ BİR OLAYI, OLDUĞU GİBİ ANLATABİLİYOR MU?
#     VE ÖLÇEMEDİĞİ ANI "SİSTEM BOŞTU" DİYE YAZIYOR MU?
#
# İkisi de tek bir ölçümle kanıtlanamaz, bu yüzden iki ayrı deney var:
#
#   1) KURGULU KİLİT. Bir oturum bir satırı kilitler ve işlemi açık tutar;
#      N yazıcı aynı satıra yazmaya çalışıp bekler. Doğru cevap bellidir ve
#      ÖNCEDEN bilinir: o pencerede en az N+1 oturum olmalı, bekleme türü
#      kilit olmalı ve KÖK ENGELLEYEN pid raporda çıkmalı. Ölçüm aracı
#      "bir şeyler oluyordu" demekle kalmamalı, kimin kimi beklettiğini
#      söylemeli — bu özelliğin varlık sebebi o.
#
#   2) SAHTE SIFIR. Örnekleyicinin sorgusu düştüğünde defter ne yazıyor?
#      Doğru cevap "ölçülemedi"dir. "0 oturum" yazan bir defter, aylar sonra
#      olayın grafiğine bakan insana tam olayın dakikasında "sistem boştu"
#      der ve onu yanlış yere gönderir; üstelik o kayıt düzeltilemez.
#      Bu tuzağa geliştirme sırasında ÜÇ AYRI YOLDAN düşüldü (ayraç kabuktan
#      geçerken bozuldu · çözülemeyen satır sessizce atlandı · psql
#      ON_ERROR_STOP=0 ile hatada bile 0 döndü). Üçü de burada bağlanıyor.
#
# ÖLÇÜLENLER
#   · 'destek' kapsamı JSON olarak veriyor ve kapsam dışı motorda SEBEP yazıyor
#   · 'sorgu' motora sorulan SQL'i basıyor (ölçüm aracı okunabilir olmalı)
#   · ayrıştırıcı üç hâli AYIRIYOR: ölçüldü / gerçekten boş / ölçülemedi
#   · çözülemeyen satır SESSİZCE DÜŞMÜYOR
#   · kurgulu kilitte: en çok oturum ≥ yazıcı sayısı, kök engelleyen bulunuyor
#   · aynı pencerede kapsama raporlanıyor (kaç saniye ÖLÇÜLDÜ)
#   · /api/ash ve /api/ash/<motor> aynı sayıları veriyor
#
# Kullanım (yığın kökünden):
#     ./scripts/e2e/ash.sh
#
# Ayarlar:
#     E2E_ASH_YAZICI=…   kaç yazıcı bekletilsin (varsayılan 6)
#     E2E_ASH_SURE=…     kilit kaç saniye tutulsun (varsayılan 20)
#
# ⚠ YAN ETKİ: üretim veritabanında kendi tablosunu (e2e_ash) açar, kilitler
#   ve SONUNDA düşürür. Başka hiçbir tabloya dokunmaz.
#
# set -e YOK: her kontrol tek tek raporlanmalı. "Ölçemedik" (t_unknown)
# BAŞARISIZ sayılır — "bilmiyorum" ile "iyi" aynı şey değildir.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh
load_env

[ -r scripts/e2e/lib.sh ] \
    || die "scripts/e2e/lib.sh okunamıyor — ortak sonuç kütüphanesi olmadan bu paket ölçüm yapamaz."
E2E_SUITE="ash"
source scripts/e2e/lib.sh

ASH="scripts/ash.sh"
ASH_CAGRI=("./$ASH")
[ -x "$ASH" ] || ASH_CAGRI=(bash "$ASH")

# Panel kimliği ve gateway adresi: diğer paketlerle aynı kaynak (.env).
PANEL_USER="${PANEL_USER:-admin}"
GW="https://127.0.0.1:${GATEWAY_HTTPS_PORT:-443}"

YAZICI="${E2E_ASH_YAZICI:-6}"
KILIT_SN="${E2E_ASH_SURE:-20}"
MOTOR=postgresql          # kök engelleyen zinciri yalnız burada ölçülebiliyor
TABLO=e2e_ash
BASLANGIC="$(date +%s)"

ZAMAN=()
command -v timeout >/dev/null 2>&1 && ZAMAN=(timeout -k 10)
zaman_asimi() {
    local sn="$1"; shift
    if [ "${#ZAMAN[@]}" -gt 0 ]; then "${ZAMAN[@]}" "$sn" "$@"; else "$@"; fi
}

heading "AKTİF OTURUM GEÇMİŞİ — $(date '+%Y-%m-%d %H:%M:%S')"

# =============================================================================
# 1) ARAÇ KENDİNİ ANLATIYOR MU
# =============================================================================
heading "Kapsam ve okunabilirlik"

D_JSON="$("${ASH_CAGRI[@]}" destek --json 2>/dev/null)"
if [ -z "$D_JSON" ]; then
    t_unknown "destek --json geçerli JSON veriyor" "çıktı boş"
else
    if printf '%s' "$D_JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        t_ok "destek --json geçerli JSON veriyor"
        # Kapsam dışı motorda SEBEP olmalı: "desteklenmiyor" tek başına,
        # kullanıcıya bunun eksiklik mi motorun doğası mı olduğunu bırakmaz.
        SEBEPSIZ="$(printf '%s' "$D_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)["engines"]
print(" ".join(k for k, v in d.items()
                if not v.get("supported") and not (v.get("reason") or "").strip()))' 2>/dev/null)"
        if [ -z "$SEBEPSIZ" ]; then
            t_ok "kapsam dışı her motorda SEBEP yazılı"
        else
            t_fail "kapsam dışı her motorda SEBEP yazılı" \
                   "sebepsiz motorlar:$SEBEPSIZ — 'desteklenmiyor' tek başına hiçbir şey anlatmaz"
        fi
    else
        t_fail "destek --json geçerli JSON veriyor" "$(printf '%s' "$D_JSON" | head -c 160)"
    fi
fi

SORGU="$("${ASH_CAGRI[@]}" sorgu "$MOTOR" 2>/dev/null)"
if printf '%s' "$SORGU" | grep -q 'pg_blocking_pids'; then
    t_ok "'sorgu' komutu motora sorulan SQL'i basıyor (bekleme zinciri dahil)"
else
    t_fail "'sorgu' komutu motora sorulan SQL'i basıyor (bekleme zinciri dahil)" \
           "çıktıda pg_blocking_pids yok: $(printf '%s' "$SORGU" | head -c 120)"
fi

# =============================================================================
# 2) AYRIŞTIRICI — CANLI VERİTABANI OLMADAN
# =============================================================================
# Üç hâli ayırdığının kanıtı ancak ham girdiyle alınabilir: canlı bir
# veritabanında "sorgu düştü" hâlini güvenle üretmenin yolu yok.
heading "Ayrıştırıcı: ölçüldü / gerçekten boş / ölçülemedi"

US="$(printf '\037')"
HAM="$(printf 'S\t1000\tok\n7%sactive%sLock%stuple%sclient backend%sroot%sdb%s3.5%s42,43%sUPDATE x\nE\nS\t1001\tok\nCOZULEMEYEN\nE\nS\t1002\tok\nE\nS\t1003\thata\nE\n' \
        "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US")"
CIKTI="$(printf '%s' "$HAM" | "${ASH_CAGRI[@]}" cevir "$MOTOR" 2>/dev/null)"
SAYIM="$(printf '%s\n' "$CIKTI" | grep -c '^{' || true)"
if [ "${SAYIM:-0}" -ne 4 ]; then
    t_unknown "ayrıştırıcı dört örneği de üretiyor" "gelen satır: ${SAYIM:-0}"
else
    t_ok "ayrıştırıcı dört örneği de üretiyor"
    DEGER="$(printf '%s' "$CIKTI" | python3 -c '
import json, sys
k = [json.loads(x) for x in sys.stdin if x.strip()]
# 0: ölçüldü + oturum · 1: satır çözülemedi · 2: gerçekten boş · 3: sorgu hatası
print("olculdu=%s" % (k[0].get("ok") is True and k[0].get("n") == 1))
print("zincir=%s" % (k[0]["oturumlar"][0]["bekleten"] == [42, 43]))
print("cozulemedi=%s" % (k[1].get("ok") is False and "n" not in k[1]))
print("bos=%s" % (k[2].get("ok") is True and k[2].get("n") == 0))
print("hata=%s" % (k[3].get("ok") is False and "n" not in k[3]))' 2>/dev/null)"
    esitle() { printf '%s\n' "$DEGER" | grep -q "^$1=True$"; }
    esitle olculdu && t_ok "ölçülen örnek: ok=true ve oturum sayısı var" \
        || t_fail "ölçülen örnek: ok=true ve oturum sayısı var" "$DEGER"
    esitle zincir && t_ok "bekleme zinciri sayı listesine çevriliyor" \
        || t_fail "bekleme zinciri sayı listesine çevriliyor" "$DEGER"
    esitle bos && t_ok "gerçekten boş örnek: ok=true ve n=0" \
        || t_fail "gerçekten boş örnek: ok=true ve n=0" "$DEGER"
    # AYNI SINIFIN İKİ AYRI TUZAĞI: satır çözülemedi ve sorgu düştü.
    # İkisinde de "0 oturum" yazmak, ölçüm yokluğunu "sistem boştu" diye
    # kaydetmek olurdu ve o kayıt bir daha düzeltilemez.
    esitle cozulemedi && t_ok "çözülemeyen satır SESSİZCE DÜŞMÜYOR (ok=false)" \
        || t_fail "çözülemeyen satır SESSİZCE DÜŞMÜYOR (ok=false)" "$DEGER"
    esitle hata && t_ok "sorgu düştüğünde 'n' alanı HİÇ YOK (0 yazılmıyor)" \
        || t_fail "sorgu düştüğünde 'n' alanı HİÇ YOK (0 yazılmıyor)" "$DEGER"
fi

# =============================================================================
# 3) KURGULU KİLİT — asıl kanıt
# =============================================================================
heading "Kurgulu kilit olayı: $YAZICI yazıcı, $KILIT_SN sn"

C="$(primary_of "$MOTOR")"
KUL="${POSTGRES_USER:-root}"
VT="${DEFAULT_DATABASE:-defaultdb}"
PW="${POSTGRES_PASSWORD:-${DB_PASSWORD:-}}"

pq() { docker exec -e PGPASSWORD="$PW" -i "$C" psql -qtAX -U "$KUL" -d "$VT" "$@"; }

ATLA=""
if ! docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null | grep -q true; then
    ATLA="$MOTOR çalışmıyor ($C) — kurgulu olay üretilemez"
elif [ -z "$PW" ]; then
    ATLA=".env'de POSTGRES_PASSWORD/DB_PASSWORD boş — sorgu çalıştırılamaz"
fi

if [ -n "$ATLA" ]; then
    t_skip "kurgulu kilitte en çok oturum ≥ yazıcı sayısı" "$ATLA"
    t_skip "kurgulu kilitte KÖK ENGELLEYEN bulunuyor" "$ATLA"
    t_skip "aynı pencerede kapsama raporlanıyor" "$ATLA"
else
    pq -c "DROP TABLE IF EXISTS $TABLO; CREATE TABLE $TABLO(id int primary key, v int); INSERT INTO $TABLO VALUES (1,0);" \
        >/dev/null 2>&1
    T_BAS="$(date +%s)"
    # Engelleyen: işlemi açık tutup uyur.
    docker exec -e PGPASSWORD="$PW" -i "$C" psql -qtAX -U "$KUL" -d "$VT" \
        >/dev/null 2>&1 <<SQL &
BEGIN;
UPDATE $TABLO SET v = v + 1 WHERE id = 1;
SELECT pg_sleep($KILIT_SN);
COMMIT;
SQL
    ENGELLEYEN_BG=$!
    sleep 3
    for _ in $(seq 1 "$YAZICI"); do
        docker exec -e PGPASSWORD="$PW" -i "$C" psql -qtAX -U "$KUL" -d "$VT" \
            -c "UPDATE $TABLO SET v = v + 1 WHERE id = 1;" >/dev/null 2>&1 &
    done
    t_info "$YAZICI yazıcı bekletiliyor…"
    wait "$ENGELLEYEN_BG" 2>/dev/null
    sleep 3
    T_BIT="$(date +%s)"
    wait 2>/dev/null
    pq -c "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1

    P_JSON="$(zaman_asimi 60 curl -sk -u "$PANEL_USER:$PANEL_PASSWORD" \
        "$GW/api/ash/$MOTOR?from=$T_BAS&to=$T_BIT" 2>/dev/null)"
    if [ -z "$P_JSON" ]; then
        t_unknown "kurgulu kilitte en çok oturum ≥ yazıcı sayısı" "/api/ash cevapsız"
        t_unknown "kurgulu kilitte KÖK ENGELLEYEN bulunuyor" "/api/ash cevapsız"
        t_unknown "aynı pencerede kapsama raporlanıyor" "/api/ash cevapsız"
    else
        OZET="$(printf '%s' "$P_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
k = d["kapsama"]
print("encok=%d" % (d["en_cok_oturum"]["n"] or 0))
print("engelleyen=%d" % len(d["bekletenler"]))
print("kilit=%d" % sum(1 for b in d["beklemeler"] if b["ad"].startswith("Lock")))
print("olculen=%d" % k["olculen_sn"])
print("aralik=%d" % k["aralik_sn"])
print("olculemedi=%d" % k["olculemedi_ornek"])' 2>/dev/null)"
        al() { printf '%s\n' "$OZET" | sed -n "s/^$1=//p"; }
        EN_COK="$(al encok)"; ENG="$(al engelleyen)"; KILITLI="$(al kilit)"
        OLCULEN="$(al olculen)"; ARALIK="$(al aralik)"; OLCULEMEDI="$(al olculemedi)"

        if [ -z "$EN_COK" ]; then
            t_unknown "kurgulu kilitte en çok oturum ≥ yazıcı sayısı" \
                      "cevap ayrıştırılamadı: $(printf '%s' "$P_JSON" | head -c 140)"
        elif [ "$EN_COK" -ge "$YAZICI" ]; then
            t_ok "kurgulu kilitte en çok oturum ≥ yazıcı sayısı (ölçülen: $EN_COK, beklenen ≥ $YAZICI)"
        else
            t_fail "kurgulu kilitte en çok oturum ≥ yazıcı sayısı" \
                   "ölçülen en çok $EN_COK oturum; $YAZICI yazıcı bilerek bekletildi — örnekleme olayı KAÇIRDI"
        fi

        # Asıl değer bu: "bir şeyler oluyordu" değil, KİM KİMİ bekletiyordu.
        if [ -z "$ENG" ]; then
            t_unknown "kurgulu kilitte KÖK ENGELLEYEN bulunuyor" "cevap ayrıştırılamadı"
        elif [ "$ENG" -ge 1 ] && [ "${KILITLI:-0}" -ge 1 ]; then
            t_ok "kurgulu kilitte KÖK ENGELLEYEN bulunuyor ($ENG pid, kilit beklemesi ölçüldü)"
        else
            t_fail "kurgulu kilitte KÖK ENGELLEYEN bulunuyor" \
                   "engelleyen pid sayısı=$ENG, kilit beklemesi=$KILITLI — zincir çözülemedi"
        fi

        # Kapsama olmadan özetin anlamı yok: %10 kapsamalı bir aralıktan
        # çıkarılan "en çok bekleten sorgu" hiçbir şey kanıtlamaz.
        if [ -z "$OLCULEN" ]; then
            t_unknown "aynı pencerede kapsama raporlanıyor" "cevap ayrıştırılamadı"
        elif [ "$OLCULEN" -ge 1 ] && [ "${OLCULEMEDI:-0}" -eq 0 ]; then
            t_ok "aynı pencerede kapsama raporlanıyor ($OLCULEN/$ARALIK sn ölçüldü, ölçülemeyen yok)"
        elif [ "${OLCULEMEDI:-0}" -gt 0 ]; then
            t_fail "aynı pencerede kapsama raporlanıyor" \
                   "$OLCULEMEDI örnek ÖLÇÜLEMEDİ — örnekleyici olay sırasında sorgu yapamadı"
        else
            t_fail "aynı pencerede kapsama raporlanıyor" \
                   "$ARALIK saniyelik pencerede HİÇ örnek yok — örnekleyici çalışmıyor"
        fi
    fi
fi

# =============================================================================
# 4) GENEL BAKIŞ UCU
# =============================================================================
heading "/api/ash genel bakışı"

O_JSON="$(zaman_asimi 60 curl -sk -u "$PANEL_USER:$PANEL_PASSWORD" "$GW/api/ash" 2>/dev/null)"
if [ -z "$O_JSON" ]; then
    t_unknown "/api/ash örnekleyicinin durumunu veriyor" "cevapsız"
else
    DURUM="$(printf '%s' "$O_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
e = d.get("engines", {}).get("postgresql", {})
print("var=%s" % bool(e))
print("kapsama=%s" % ("son_saat" in e))
print("gecikme=%s" % (e.get("gecikme_sn") if e.get("gecikme_sn") is not None else -1))' 2>/dev/null)"
    d_al() { printf '%s\n' "$DURUM" | sed -n "s/^$1=//p"; }
    if [ "$(d_al var)" = "True" ] && [ "$(d_al kapsama)" = "True" ]; then
        t_ok "/api/ash örnekleyicinin durumunu ve KAPSAMASINI veriyor"
    else
        t_fail "/api/ash örnekleyicinin durumunu ve KAPSAMASINI veriyor" "$DURUM"
    fi
    G="$(d_al gecikme)"
    # Gecikme, örnekleyicinin canlı olup olmadığının tek dürüst göstergesi:
    # "çalışıyor" bayrağı sürecin ayakta olduğunu söyler, VERİ GELDİĞİNİ değil.
    if [ -n "$G" ] && [ "$G" -ge 0 ] && [ "$G" -le 120 ]; then
        t_ok "son örnek yakın zamanlı (gecikme ${G} sn) — akış canlı"
    elif [ -n "$G" ] && [ "$G" -lt 0 ]; then
        t_fail "son örnek yakın zamanlı — akış canlı" \
               "hiç örnek gelmemiş (son_ornek boş)"
    else
        t_fail "son örnek yakın zamanlı — akış canlı" \
               "son örnek ${G} saniye önce — akış kopmuş olabilir"
    fi
fi

# ------------------------------------------------------------------- özet ---
SURE=$(( $(date +%s) - BASLANGIC ))
t_info "süre: $((SURE / 60))m $((SURE % 60))s"
e2e_finish
exit $?
