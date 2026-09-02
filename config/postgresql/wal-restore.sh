#!/bin/sh
# =============================================================================
# PostgreSQL — WAL geri okuma komutu (restore_command)
# =============================================================================
# Kurtarma sırasında scripts/pitr.sh şu satırı postgresql.auto.conf'a yazar:
#     restore_command = 'sh /etc/pitr/wal-restore.sh %f %p'
#   $1 = %f  istenen segmentin adı
#   $2 = %p  segmentin konulacağı yol (PGDATA'ya göreli)
#
# BU BETİKTE "DOSYA YOK" BİR HATA DEĞİLDİR.
# PostgreSQL arşivin SONUNU tam olarak buradan anlar: sıradaki segmenti
# ister, komut sıfırdan farklı döner ve kurtarma orada biter. Yani sıfırdan
# farklı çıkış, bu betiğin normal ve gerekli davranışıdır.
#
# Ama "yok" ile "var, okuyamadım" AYNI ŞEY DEĞİLDİR: birincisinde kurtarma
# doğru yerde durur, ikincisinde İSTENEN ZAMANA ULAŞMADAN durur ve kimse fark
# etmez — çünkü PostgreSQL ikisini de aynı biçimde görür. Bu yüzden ikinci
# hâli stderr'e ayrı bir cümleyle yazıyoruz; scripts/pitr.sh kurtarma
# sonrasında container günlüğünde tam olarak bu cümleyi arıyor ve bulursa
# "istenen ana ulaşıldı" DEMİYOR.
# =============================================================================
set -u

AD="${1:-}"
HEDEF="${2:-}"
D="${PG_WAL_ARSIV:-/wal-archive}"

[ -n "$AD" ] && [ -n "$HEDEF" ] || {
    printf 'wal-restore: eksik argüman (%%f %%p verilmedi)\n' >&2
    exit 1
}

KAYNAK="$D/$AD"

# Zaman çizgisi geçmiş dosyaları (.history) da bu komutla istenir; onların
# yokluğu da olağandır. Ek bir dal açmıyoruz, ikisi de aynı yoldan geçiyor.
if [ ! -f "$KAYNAK" ]; then
    # Sessiz çıkış: bu satır kurtarmanın normal sonu. Günlüğe yazsaydık her
    # kurtarmanın sonunda "hata" gibi görünen bir satır bırakırdık.
    exit 1
fi

if [ ! -r "$KAYNAK" ]; then
    printf 'wal-restore: ARŞİVDE VAR AMA OKUNAMIYOR: %s (izinler)\n' "$KAYNAK" >&2
    exit 1
fi

# cp'nin kendisi de yarıda kalabilir (disk dolu). Kısmi bir segment
# PostgreSQL'e "invalid record" dedirtir ve kurtarma erken biter; sebebi
# görünsün diye ayrıca yazıyoruz.
if ! cp "$KAYNAK" "$HEDEF"; then
    printf 'wal-restore: KOPYALANAMADI: %s → %s (hedef disk dolu olabilir)\n' \
        "$KAYNAK" "$HEDEF" >&2
    exit 1
fi

exit 0
