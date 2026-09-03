#!/bin/bash
# =============================================================================
# databases-stack — uçtan uca doğrulama paketi (koşucu)
# =============================================================================
# Bu paket, ÇALIŞAN bir kuruluma karşı ürünün vaatlerini tek tek sınar. Amaç
# "kod derleniyor mu" değil: veri yazılıp geri okunuyor mu, devirden sonra
# uygulama aynı adrese yazabiliyor mu, yedek gerçekten geri yükleniyor mu.
#
# NEDEN AYRI BİR PAKET (selftest yetmiyor mu):
# scripts/selftest.py docker'ı TAKLİT eder; hızlıdır, her yerde çalışır ve
# mantık hatalarını yakalar. Ama taklit edilen bir docker, gerçek bir
# container'ın yapmadığını yapmaz: bind-mount'un inode'a bağlanması, exporter'ın
# ölü bir düğüme bakması, kesik bir gzip'in doğrulamayı geçmesi — bunların
# hepsi ancak GERÇEK kurulumda görülür ve hepsi bu üründe gerçekten yaşandı.
#
# KULLANIM
#   ./scripts/e2e/run.sh                 güvenli paketleri sırayla çalıştır
#   ./scripts/e2e/run.sh replication     yalnız birini çalıştır
#   ./scripts/e2e/run.sh --hepsi         Kubernetes dahil (aşağıdaki uyarı)
#   ./scripts/e2e/run.sh --liste         paketleri ve ne yaptıklarını yaz
#
# UYARI — BU BİR TEST ORTAMI ARACIDIR. Paketler veritabanı açıp kapatır,
# replikasyon kurar, ana kopyayı ÖLDÜRÜP devir tetikler ve geri yükleme sınamak
# için kendi yarattığı veriyi siler. Üretim verisi olan bir kurulumda
# çalıştırmayın.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
source scripts/lib/common.sh

LOG_DIR="${LOG_DIR:-$STACK_ROOT/logs}"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/e2e_$(date +%Y%m%d_%H%M%S).log"

# Sıra tesadüfi değil.
# security ve sizing en ucuz ve en az yan etkili olanlar, başta.
# lifecycle EN SONDA: katalogdaki HER motoru açıp kapattığı için hem bütçeyi
#   doldurup hem de replika/devir kurulumlarını dağıtıyor. Ortada çalıştığı
#   ölçümde kendinden sonraki iki paket (replication, failover) hiç kontrol
#   çalıştıramadı — replication "ÖLÇÜLMEDİ" (çıkış 2), failover ön koşulda
#   düştü. Yani en uzun süren paket, en değerli iki paketi ölçüsüz bırakıyordu.
# k8s
# EN SONDA ve isteğe bağlı, çünkü k3s aynı host'ta 80/443'ü Docker'dan kapar
# (bkz. docs/KUBERNETES.md) ve paketin sonundaki temizlik adımı kritiktir.
# drill ve import, yedekleme ailesinin hemen ardından: ikisi de yedek
# dosyalarını girdi olarak kullanıyor, backup paketi koştuktan sonra
# elde taze bir dump oluyor.
# pitr ve encrypt yedekleme ailesinden: ikisi de backup paketinden sonra
# koşmalı (taze bir dump ve arşiv gerekiyor). ha-drill GERÇEK bir devir
# yapar — failover paketiyle aynı aileden, onun hemen ardında.
GUVENLI=(security sizing replication failover ha-drill backup drill import
         encrypt pitr maintenance slowlog ash monitoring lifecycle)
ISTEGE_BAGLI=(k8s)

declare -A ACIKLAMA=(
  [security]="Erişim denetimi: panel/API/metrik parolası, tek oturum, çapraz-site koruması"
  [sizing]="Otomatik boyutlandırma: hesaplanan limit gerçekten uygulanıyor mu, bütçe dolunca reddediyor mu"
  [lifecycle]="Aç/kapat ve veri kalıcılığı: kapatınca veri silinmiyor"
  [replication]="Yedek kopya: akıyor mu, salt-okunur mu, kapatınca kalıntı bırakmıyor mu"
  [failover]="Otomatik devir: ölüm → devir → AYNI ADRESTEN yazma → veri kaybı yok"
  [backup]="Yedek al → veriyi sil → geri yükle → veri geri geldi"
  [monitoring]="İzleme zinciri: hedefler, metrikler, her panonun her sorgusu"
  [k8s]="Kubernetes: ayarlar pod içinde uygulanıyor mu (k3s açar ve SONUNDA kapatır)"
)

liste() {
    heading "Uçtan uca doğrulama paketleri"
    for s in "${GUVENLI[@]}"; do printf '  %-13s %s\n' "$s" "${ACIKLAMA[$s]}"; done
    echo
    printf '  %s(isteğe bağlı — --hepsi ile)%s\n' "$YELLOW" "$NC"
    for s in "${ISTEGE_BAGLI[@]}"; do printf '  %-13s %s\n' "$s" "${ACIKLAMA[$s]}"; done
    echo
}

# --------------------------------------------------------------- argümanlar --
SECILEN=()
HEPSI=0
for a in "$@"; do
    case "$a" in
        --liste|-l) liste; exit 0 ;;
        --hepsi|-a) HEPSI=1 ;;
        -*) die "Bilinmeyen seçenek: $a  (./scripts/e2e/run.sh --liste)" ;;
        *)  [ -f "scripts/e2e/$a.sh" ] || die "Böyle bir paket yok: $a  (--liste ile bakın)"
            SECILEN+=("$a") ;;
    esac
done
if [ ${#SECILEN[@]} -eq 0 ]; then
    SECILEN=("${GUVENLI[@]}")
    [ "$HEPSI" -eq 1 ] && SECILEN+=("${ISTEGE_BAGLI[@]}")
fi

require_docker
[ -f .env ] || die ".env yok — bu paket ÇALIŞAN bir kuruluma karşı koşar. Önce ./install.sh"

heading "Uçtan uca doğrulama — $(date '+%Y-%m-%d %H:%M:%S')"
log "paketler : ${SECILEN[*]}"
log "günlük   : $RUN_LOG"
warn "Bu paket veritabanı açar/kapatır, ana kopyayı öldürür ve kendi verisini siler."
warn "Üretim verisi olan bir kurulumda ÇALIŞTIRMAYIN."
echo

declare -A SONUC SURE
BASARISIZ=0   # geçemeyen paket sayısı (başarısız + ölçülmedi + kesildi)

for s in "${SECILEN[@]}"; do
    # Açıklaması olmayan bir paket (yeni eklenmiş bir dosya) `set -u`
    # altında koşucuyu çökertiyordu; paket çalışmadan koşucu ölünce
    # sonuç "hiç ölçülmedi" bile olmuyor, sessizce hiçbir şey olmuyordu.
    heading "▶ $s — ${ACIKLAMA[$s]:-(açıklama yok)}"
    bas=$(date +%s)
    # Çıktıyı hem ekrana hem günlüğe veriyoruz; paketin çıkış kodunu
    # Çıktıyı hem ekrana hem günlüğe veriyoruz; paketin çıkış kodunu
    # PIPESTATUS[0] ile alıyoruz. İNDİS ÖNEMLİ: boru hattının iki elemanı
    # var — [0] süslü parantez grubu (paketin kendisi), [1] tee. tee HER
    # ZAMAN 0 döner, dolayısıyla [1] okumak paketin 1/2/130 kodlarının
    # ÜÇÜNÜ DE yutar ve başarısız paketi "GEÇTİ" raporlar. Bu satırda tam
    # olarak o hata vardı: yorum doğruydu, indis yanlıştı.
    { echo "===== $s ====="; "scripts/e2e/$s.sh"; } 2>&1 | tee -a "$RUN_LOG"
    rc=${PIPESTATUS[0]}
    SURE[$s]=$(( $(date +%s) - bas ))

    # Sayıları paketin kendi çıktısından topluyoruz (ortak biçim).
    # (özet aşağıda günlüğü bir kez sayıyor; burada tekrar saymaya gerek yok)
    # kontrol çalışmadı" ile "her kontrol geçti" aynı satıra yazılırsa
    # paketin tüm anlamı kaybolur.
    case "$rc" in
        0)   SONUC[$s]="GEÇTİ" ;;
        2)   SONUC[$s]="ÖLÇÜLMEDİ"; BASARISIZ=$((BASARISIZ+1)) ;;
        3)   SONUC[$s]="EKSİK-KAPSAM"; BASARISIZ=$((BASARISIZ+1)) ;;
        130) SONUC[$s]="KESİLDİ";   BASARISIZ=$((BASARISIZ+1)) ;;
        *)   SONUC[$s]="BAŞARISIZ"; BASARISIZ=$((BASARISIZ+1)) ;;
    esac
    echo
done

# --------------------------------------------------------------------- özet --
heading "ÖZET"
for s in "${SECILEN[@]}"; do
    d=${SURE[$s]}
    if [ "${SONUC[$s]}" = "GEÇTİ" ]; then
        printf '  %s✓%s %-13s %-10s %3d sn\n' "$GREEN" "$NC" "$s" "${SONUC[$s]}" "$d"
    else
        printf '  %s✗%s %-13s %-10s %3d sn\n' "$RED" "$NC" "$s" "${SONUC[$s]}" "$d"
    fi
done
echo
# grep -c EŞLEŞME YOKKEN de "0" basar AMA çıkış kodu 1'dir; `|| echo 0`
# o durumda İKİNCİ bir 0 ekliyordu ve printf "0\n0: invalid number" diyordu.
# Özet satırı bozuluyor, sayı yerine hata görünüyordu.
say() { grep -c "$1" "$RUN_LOG" 2>/dev/null | head -1 | tr -dc '0-9'; }
printf '  toplam [GEÇTİ] satırı : %d\n' \
    "$(say '\[GEÇTİ\]')"
printf '  toplam [BAŞARISIZ]    : %d\n' \
    "$(say '\[BAŞARISIZ\]')"
printf '  toplam [ÖLÇÜLEMEDİ]   : %d   <- başarısız sayılır\n' \
    "$(say '\[ÖLÇÜLEMEDİ\]')"
printf '  toplam [ATLANDI]      : %d   ← sebepleri günlükte, sessizce geçilmedi\n' \
    "$(say '\[ATLANDI\]')"
printf '  günlük                : %s\n\n' "$RUN_LOG"

if [ "$BASARISIZ" -gt 0 ]; then
    err "$BASARISIZ paket geçemedi (başarısız / ölçülemedi / kesildi). Ayrıntı: $RUN_LOG"
    exit 1
fi
# "Hiçbir paket başarısız değil" ile "ürün doğrulandı" aynı şey değil: her
# paket EN AZ BİR kontrol çalıştırmış olmalı. lib.sh bunu çıkış 2 ile
# bildiriyor ve yukarıdaki döngü onu başarısız sayıyor.
ok "Bütün paketler geçti — her biri en az bir kontrol çalıştırdı."
