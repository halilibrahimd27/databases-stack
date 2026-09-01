#!/bin/sh
# Redis replikasyonu compose'daki `--replicaof redis 6379` ile kendiliğinden
# kurulur; burada yalnızca gerçekten kurulduğunu doğruluyor ve replikasyon
# kapatılırken yedeği düzgünce kopartıyoruz.
#   prepare → yapılacak bir şey yok (compose zaten kuruyor)
#   attach  → replikanın gerçekten ana kopyaya bağlandığını doğrula
#   cleanup → yedek silinmeden önce replikasyonu durdur
set -eu
PHASE="${1:-prepare}"
PASS="${REDIS_PASSWORD:-$DB_PASSWORD}"

# Yön controller'dan gelir; devirden sonra roller yer değiştirebilir.
# Varsayılanlar hiç devir olmamış ilk kurulumun hâlidir.
PRIMARY="${REPLICATION_PRIMARY:-redis}"
STANDBY="${REPLICATION_STANDBY:-redis-replica}"

# Parola REDISCLI_AUTH ile geçer — komut satırında olsaydı host'ta `ps`
# çıktısında ve container'ın /proc'unda görünürdü.
r() { c="$1"; shift; docker exec -e REDISCLI_AUTH="$PASS" "$c" redis-cli --no-auth-warning "$@"; }

# FAZLAR AÇIKÇA AYRILIR. Eskiden yalnız `prepare` ayrılıyor, geri kalan her şey
# doğrudan aşağıdaki doğrulama döngüsüne düşüyordu. Sonuç: `cleanup` çağrısı
# REPLİKANIN BAĞLANMASINI beklemeye başlıyor, 90 saniye sonra 1 dönüyordu.
# Controller bunu "temizlik başarısız" sayıp yedeği KALDIRMIYOR ve panele
# kritik bir olay yazıyordu — yani "Replikayı kapat" düğmesi, hiç devir
# olmamış sıradan bir kurulumda bile tamamen kırıktı.
case "$PHASE" in
prepare)
  echo "[redis] hazırlık gerekmiyor (replikasyon compose'daki --replicaof ile kurulur)"
  ;;

attach)
  echo "[redis] yön: $PRIMARY (kaynak) → $STANDBY (hedef)"
  i=0
  while [ $i -lt 30 ]; do
      out=$(r "$STANDBY" INFO replication 2>/dev/null || true)
      case "$out" in
        *role:slave*master_link_status:up*)
          echo "[redis] ✓ replika bağlandı"
          printf '%s\n' "$out" | grep -E 'role|master_link_status|slave_repl_offset' || true
          exit 0 ;;
      esac
      i=$((i+1)); sleep 3
  done
  echo "[redis] ✗ replika 90 sn'de bağlanmadı" >&2
  echo "[redis]   Ana kopya ($PRIMARY) çalışıyor olmalı; 'docker logs $STANDBY' çıktısına bakın." >&2
  exit 1
  ;;

cleanup)
  echo "[redis] yön: $PRIMARY (ana kopya) / $STANDBY (kaldırılacak yedek)"
  # Redis'te PostgreSQL'in replikasyon slot'u gibi arkada BİRİKEN bir yapı
  # yoktur: bağlantı kopunca ana kopya sabit boyutlu replikasyon tamponunu
  # (repl-backlog) bırakır ve başka hiçbir şey tutmaz. Bu yüzden buradaki tek
  # iş, yedeği silinmeden önce nazikçe kopartmak — ulaşılamaması hata değildir,
  # çünkü geride diski dolduracak bir kalıntı kalmıyor. (PostgreSQL'de tam
  # tersi: orada kalan slot WAL biriktirip ana kopyayı durdurur, o yüzden
  # oradaki temizlik doğrulanır ve başarısızsa hata verir.)
  out=$(r "$STANDBY" REPLICAOF NO ONE 2>&1 || true)
  case "$out" in
    *OK*) echo "[redis] yedek kopyanın replikasyonu durduruldu" ;;
    *)    echo "[redis] yedek kopyaya ulaşılamadı (zaten durmuş olabilir) — kalıntı bırakmaz" ;;
  esac
  echo "[redis] temizlendi"
  ;;

*)
  # Tanınmayan faz SESSİZCE 0 DÖNMEZ: controller 0'ı "yapıldı" sayıp bir sonraki
  # adıma geçer. Bu betikteki asıl arıza tam olarak bu sınıftandı.
  echo "[redis] ✗ bilinmeyen faz: '$PHASE' (prepare | attach | cleanup)" >&2
  exit 2
  ;;
esac
