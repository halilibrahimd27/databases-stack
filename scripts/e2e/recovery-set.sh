#!/bin/bash
# =============================================================================
# databases-stack — uçtan uca test: KURTARMA NOKTASI SETİ
# =============================================================================
# Set, birden çok motoru TEK bir ana döndürme vaadi. Bu paketin işi o vaadin
# ABARTILMADIĞINI doğrulamak: ürün "hepsi aynı ana geldi" DEMEMELİ, "şu kadar
# geride kaldı" DEMELİ.
#
#   1) PENCERE ÖLÇÜLÜYOR — set bir an değil aralık; genişliği kayıtta olmalı
#      ve motor başına "hedeften kaç saniye geride" yazmalı.
#   2) GERİ YÜKLEME GERÇEKTEN DÖNDÜRÜYOR — setten SONRA yazılan veri, geri
#      yüklemeden sonra YOK olmalı. Sayıya değil VERİYE bakıyoruz.
#   3) DÜRÜSTLÜK — rapor, PITR'ı açık motor için 0 sn, kapalı motor için
#      gerçek farkı söylemeli. İkisini de "tam" demek, ölçmediğini iddia
#      etmek olurdu.
#   4) EKSİK DOSYA — setin bir dosyası silinmişse o nokta dönülebilir
#      GÖRÜNMEMELİ; saklama temizliği bunu er geç yapacak.
#
# BU PAKET ÜRETİM VERİSİNE DOKUNUR: kendi tablolarını/anahtarlarını yaratır,
# setini alır, geri yükler ve sonunda temizler.
#
# Kullanım:
#   ./scripts/e2e/recovery-set.sh                  # mariadb + redis
#   ./scripts/e2e/recovery-set.sh mariadb redis
# =============================================================================
set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
# shellcheck source=/dev/null
. "$STACK_ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
. "$E2E_DIR/lib.sh"
load_env

MOTORLAR=("$@")
[ "${#MOTORLAR[@]}" -gt 0 ] || MOTORLAR=(mariadb redis)
TABLO="e2e_set"
ISARET="e2e-set-sonrasi"
E2E_LOG="${E2E_LOG:-$STACK_ROOT/logs/e2e-recovery-set_$(date +%Y%m%d_%H%M%S).log}"
mkdir -p "$(dirname "$E2E_LOG")" 2>/dev/null

ctl() {   # ctl <python gövdesi> — ürünün KENDİ yolundan
    local ham
    ham="$(docker exec controller python3 -c "
import sys, json
sys.path.insert(0,'/app')
import app
def E2E(x): print('E2E>' + str(x))
$1
" 2>>"$E2E_LOG")"
    printf '%s\n' "$ham" >>"$E2E_LOG"
    printf '%s' "$ham" | sed -n 's/^E2E>//p' | tail -1
}

sql() {   # sql <motor> <ifade>
    local m="$1" c
    c="$(primary_of "$m")"
    case "$m" in
    mariadb)
        docker exec -e MYSQL_PWD="$(motor_parolasi mariadb)" "$c" \
            mariadb -uroot -D "${DEFAULT_DATABASE:-defaultdb}" -N -B -e "$2" 2>>"$E2E_LOG" ;;
    postgresql)
        docker exec -e PGPASSWORD="$(motor_parolasi postgresql)" "$c" \
            psql -U "${POSTGRES_USER:-root}" -d "${DEFAULT_DATABASE:-defaultdb}" \
            -tAq -v ON_ERROR_STOP=1 -c "$2" 2>>"$E2E_LOG" ;;
    redis)
        docker exec -e REDISCLI_AUTH="$(motor_parolasi redis)" "$c" \
            redis-cli --no-auth-warning $2 2>>"$E2E_LOG" ;;
    *)  return 1 ;;
    esac
}

isaret_yaz() {   # isaret_yaz <motor>
    case "$1" in
    mariadb)    sql mariadb "CREATE TABLE IF NOT EXISTS $TABLO (k VARCHAR(64) PRIMARY KEY);
                             REPLACE INTO $TABLO VALUES ('$ISARET');" >/dev/null ;;
    postgresql) sql postgresql "CREATE TABLE IF NOT EXISTS $TABLO (k text PRIMARY KEY);
                                INSERT INTO $TABLO VALUES ('$ISARET')
                                ON CONFLICT DO NOTHING;" >/dev/null ;;
    redis)      sql redis "SET $ISARET 1" >/dev/null ;;
    esac
}

isaret_var() {   # isaret_var <motor> → 1/0/HATA
    local n
    case "$1" in
    mariadb)    n="$(sql mariadb "SELECT COUNT(*) FROM $TABLO WHERE k='$ISARET';")" ;;
    postgresql) n="$(sql postgresql "SELECT COUNT(*) FROM $TABLO WHERE k='$ISARET';")" ;;
    redis)      n="$(sql redis "EXISTS $ISARET")" ;;
    esac
    n="$(printf '%s' "${n:-}" | tr -d '[:space:]')"
    case "$n" in ''|*[!0-9]*) printf 'HATA' ;; *) printf '%s' "$n" ;; esac
}

temizle() {
    local m
    for m in "${MOTORLAR[@]}"; do
        case "$m" in
        mariadb)    sql mariadb "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1 ;;
        postgresql) sql postgresql "DROP TABLE IF EXISTS $TABLO;" >/dev/null 2>&1 ;;
        redis)      sql redis "DEL $ISARET" >/dev/null 2>&1 ;;
        esac
    done
}
trap temizle EXIT

# =============================================================================
# ÖN KOŞULLAR
# =============================================================================
t_head "Kurtarma noktası seti — ${MOTORLAR[*]}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    t_unknown "kurtarma noktası seti" "docker'a erişilemiyor"
    e2e_finish; exit $?
fi
container_running controller || {
    t_skip "kurtarma noktası seti" "controller çalışmıyor — seti o alıyor"
    e2e_finish; exit $?; }

UYGUN=()
for M in "${MOTORLAR[@]}"; do
    case "$M" in
        mariadb|postgresql|redis) ;;
        *) t_info "$M bu pakette desteklenmiyor, atlanıyor"; continue ;;
    esac
    container_running "$(primary_of "$M")" || {
        t_info "$M kapalı, sete alınmıyor"; continue; }
    UYGUN+=("$M")
done
if [ "${#UYGUN[@]}" -lt 2 ]; then
    t_skip "kurtarma noktası seti" \
        "en az iki motor açık olmalı (açık olanlar: ${UYGUN[*]:-yok}) — setin anlamı çok motorlu olmasında"
    e2e_finish; exit $?
fi
MOTORLAR=("${UYGUN[@]}")
t_info "sete girecek motorlar: ${MOTORLAR[*]}"

# =============================================================================
# 1) SET AL — pencere ölçülüyor mu
# =============================================================================
t_head "Set alınıyor"
LISTE="$(printf "'%s'," "${MOTORLAR[@]}")"
SET_JSON="$(ctl "
import json
jid = app.new_job('recovery-set', None)
app.do_recovery_set(jid, 'e2e', [${LISTE%,}])
j = app.JOBS[jid]
E2E(json.dumps({'state': j['state'], 'set': j.get('set'),
                'window': j.get('window_seconds'), 'reason': j.get('reason')}))
")"
DURUM="$(printf '%s' "$SET_JSON" | sed -n 's/.*"state": *"\([^"]*\)".*/\1/p')"
SID="$(printf '%s' "$SET_JSON" | sed -n 's/.*"set": *"\([^"]*\)".*/\1/p')"
PENCERE="$(printf '%s' "$SET_JSON" | sed -n 's/.*"window": *\([0-9]*\).*/\1/p')"

if [ "$DURUM" != "done" ] || [ -z "$SID" ]; then
    t_fail "kurtarma noktası alınabiliyor" "iş durumu: ${DURUM:-okunamadı} — $SET_JSON"
    e2e_finish; exit $?
fi
t_ok "kurtarma noktası alınabiliyor" "$SID"

if printf '%s' "${PENCERE:-}" | grep -qE '^[0-9]+$'; then
    # PENCERE, SETİN BİR AN OLMADIĞINI SÖYLEYEN TEK SAYI. Ölçülmemesi,
    # kullanıcının onu bir anlık görüntü sanması demek.
    t_ok "pencere ölçülüyor ve kaydediliyor" "$PENCERE sn (${#MOTORLAR[@]} motor)"
else
    t_fail "pencere ölçülmedi" "window=${PENCERE:-yok}"
fi

OZET="$(ctl "
import json
s = [x for x in app.recovery_set_ozet() if x['id'] == '$SID']
E2E(json.dumps(s[0] if s else {}))
")"
if printf '%s' "$OZET" | grep -q '"behind_seconds"'; then
    t_ok "motor başına 'hedeften ne kadar geride' raporlanıyor"
else
    t_fail "motor başına geride kalma raporlanmıyor" "$(printf '%s' "$OZET" | cut -c1-160)"
fi

# =============================================================================
# 2) SETTEN SONRA VERİ YAZ — geri yükleme bunu SİLMELİ
# =============================================================================
t_head "Geri yükleme gerçekten o ana döndürüyor mu"
for M in "${MOTORLAR[@]}"; do isaret_yaz "$M"; done
EKSIK=""
for M in "${MOTORLAR[@]}"; do
    [ "$(isaret_var "$M")" = "1" ] || EKSIK="${EKSIK:+$EKSIK, }$M"
done
if [ -n "$EKSIK" ]; then
    t_unknown "setten sonra yazılan veri geri yüklemede siliniyor" \
              "işaret yazılamadı: $EKSIK (ayrıntı: $E2E_LOG)"
    e2e_finish; exit $?
fi
t_info "setten SONRA her motora bir işaret yazıldı"

GERI="$(ctl "
import json
jid = app.new_job('recovery-set-restore', None)
app.do_recovery_set_restore(jid, '$SID', True)
j = app.JOBS[jid]
E2E(json.dumps({'state': j['state'], 'summary': j.get('summary'),
                'engines': j.get('engines')}))
")"
G_DURUM="$(printf '%s' "$GERI" | sed -n 's/.*"state": *"\([^"]*\)".*/\1/p')"
if [ "$G_DURUM" != "done" ]; then
    t_fail "set geri yüklenebiliyor" "iş durumu: ${G_DURUM:-okunamadı} — $(printf '%s' "$GERI" | cut -c1-200)"
    e2e_finish; exit $?
fi
t_ok "set geri yüklenebiliyor"

# Motorların hazır olmasını bekle: container yeniden başlamış olabilir.
for _ in $(seq 1 40); do
    HAZIR=1
    for M in "${MOTORLAR[@]}"; do
        [ "$(isaret_var "$M")" = "HATA" ] && HAZIR=0
    done
    [ "$HAZIR" -eq 1 ] && break
    sleep 3
done

KALAN=""
OLCULEMEYEN=""
for M in "${MOTORLAR[@]}"; do
    v="$(isaret_var "$M")"
    case "$v" in
        0)    ;;
        1)    KALAN="${KALAN:+$KALAN, }$M" ;;
        *)    OLCULEMEYEN="${OLCULEMEYEN:+$OLCULEMEYEN, }$M" ;;
    esac
done
if [ -n "$OLCULEMEYEN" ]; then
    t_unknown "setten sonra yazılan veri geri yüklemede siliniyor" \
              "ölçülemedi: $OLCULEMEYEN"
elif [ -z "$KALAN" ]; then
    t_ok "setten sonra yazılan veri geri yüklemede siliniyor" \
         "${#MOTORLAR[@]} motorun hepsinde işaret yok"
else
    # PITR'ı AÇIK bir motor hedef ana sarılır ve işaret hedeften SONRA
    # yazıldığı için yine silinmeli. Kalıyorsa geri yükleme o motorda
    # gerçekten çalışmamıştır.
    t_fail "geri yükleme bazı motorlarda veriyi döndürmedi" "işaret duruyor: $KALAN"
fi

# =============================================================================
# 3) DÜRÜSTLÜK — rapor ne elde edildiğini söylüyor mu
# =============================================================================
t_head "Rapor dürüstlüğü"
if printf '%s' "$GERI" | grep -q '"summary"'; then
    OZ="$(printf '%s' "$GERI" | sed -n 's/.*"summary": *"\([^"]*\)".*/\1/p')"
    if printf '%s' "$OZ" | grep -q 'hedef anda'; then
        t_ok "özet, kaç motorun hedefe tam oturduğunu söylüyor" "$OZ"
    else
        t_fail "özet ne elde edildiğini söylemiyor" "${OZ:-boş}"
    fi
else
    t_fail "geri yükleme özeti yok" "$(printf '%s' "$GERI" | cut -c1-160)"
fi

# =============================================================================
# 4) EKSİK DOSYA — dönülebilir GÖRÜNMEMELİ
# =============================================================================
# Saklama temizliği er geç setin dosyalarını silecek. Kaydı olup dosyası
# olmayan bir nokta, "geri dönebilirim" sanılan ama dönülemeyen bir kapıdır.
t_head "Dosyası silinmiş set"
SAHTE="$(ctl "
import json
d = app.load_recovery_sets()
d['sets'].append({'id': 'rs_e2e_sahte', 'name': 'e2e-sahte',
                  'started': 1, 'finished': 2, 'target': 2,
                  'window_seconds': 0,
                  'engines': {'mariadb': {'file': 'olmayan-dosya.sql.gz', 'at': 2}},
                  'source': 'e2e'})
app.save_recovery_sets(d)
s = [x for x in app.recovery_set_ozet() if x['id'] == 'rs_e2e_sahte']
d = app.load_recovery_sets()
d['sets'] = [x for x in d['sets'] if x.get('id') != 'rs_e2e_sahte']
app.save_recovery_sets(d)
E2E(json.dumps(s[0] if s else {}))
")"
if printf '%s' "$SAHTE" | grep -q '"missing_files": 1'; then
    t_ok "dosyası silinmiş set 'eksik' olarak işaretleniyor"
else
    t_fail "dosyası silinmiş set eksik gösterilmiyor" "$(printf '%s' "$SAHTE" | cut -c1-160)"
fi

temizle
e2e_finish
exit $?
