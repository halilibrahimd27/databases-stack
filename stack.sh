#!/bin/bash
# =============================================================================
# databases-stack — komut satırı arayüzü
# =============================================================================
# Dashboard'un yaptığı her şeyi terminalden yapar. ÖNEMLİ: aktivasyon istekleri
# doğrudan compose'a değil CONTROLLER'a gider — böylece terminalden açtığınızda
# da aynı otomatik boyutlandırma (host RAM ölçümü + motor ayarlarının
# hesaplanması) çalışır. Elle `docker compose --profile X up` derseniz bu
# hesaplama atlanır ve muhafazakâr varsayılanlar kullanılır.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
source scripts/lib/common.sh
load_env

# ---------------------------------------------------------------- API çağrısı
# Controller host'a port açmaz (güvenlik). Ona ulaşmanın yolu ya gateway'den
# geçmek ya da container'ın içinden çağırmaktır; ikincisi TLS/auth derdi
# olmadığı için CLI bunu kullanır.
_api() {
    local method="$1" path="$2" body="${3:-}"
    container_running controller || die "controller çalışmıyor. Önce: ./install.sh"
    docker exec -e API_METHOD="$method" -e API_PATH="$path" -e API_BODY="$body" \
        controller python -c '
import os, json, urllib.request, urllib.error, sys
m = os.environ["API_METHOD"]; p = os.environ["API_PATH"]
b = os.environ.get("API_BODY") or None
req = urllib.request.Request(
    "http://127.0.0.1:8000" + p, method=m,
    data=b.encode() if b else None,
    headers={"X-Api-Token": os.environ.get("CONTROLLER_TOKEN", ""),
             "Content-Type": "application/json"})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=300).read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write(e.read().decode()); sys.exit(1)
'
}

_jq() { python3 -c "$1"; }   # stdin'den JSON okuyup biçimler

engine_ids() {
    python3 -c 'import json,sys;print("\n".join(e["id"] for e in json.load(open(sys.argv[1]))["engines"]))' "$CATALOG"
}

valid_engine() {
    engine_ids | grep -qx "$1" || {
        err "Bilinmeyen veritabanı: $1"
        echo "Geçerli olanlar:" >&2; engine_ids | sed 's/^/  /' >&2
        exit 1
    }
}

# İşi bitene kadar izle, log'u ekrana bas.
watch_job() {
    local job="$1" last=0
    while :; do
        local out; out="$(_api GET "/api/jobs/$job")"
        printf '%s' "$out" | python3 -c '
import json,sys
j=json.load(sys.stdin); last=int(sys.argv[1])
for line in j["log"][last:]: print("   ", line)
print("__STATE__", j["state"], len(j["log"]), j.get("reason",""))
' "$last" > /tmp/.stackjob.$$
        grep -v '^__STATE__' /tmp/.stackjob.$$ || true
        read -r _ state count reason < <(grep '^__STATE__' /tmp/.stackjob.$$)
        last="$count"
        if [ "$state" != "running" ]; then
            rm -f /tmp/.stackjob.$$
            if [ "$state" = "done" ]; then ok "Tamamlandı"; return 0
            else err "Başarısız${reason:+: $reason}"; return 1; fi
        fi
        sleep 2
    done
}

# =============================================================================
# KOMUTLAR
# =============================================================================
cmd_list() {
    _api GET /api/status > /tmp/.st.$$
    _api GET /api/plans  > /tmp/.pl.$$
    python3 - "$CATALOG" /tmp/.st.$$ /tmp/.pl.$$ <<'PY'
import json, sys
cat  = json.load(open(sys.argv[1], encoding="utf-8"))
st   = json.load(open(sys.argv[2], encoding="utf-8"))
pl   = json.load(open(sys.argv[3], encoding="utf-8"))["plans"]
by   = {e["id"]: e for e in st["engines"]}
sys_ = st["system"]

def mb(v):
    if v is None: return "-"
    return "%.1f GB" % (v/1024) if v >= 1024 else "%d MB" % v

print()
print("  Sunucu: %s RAM (%s boş) · %d CPU · %s disk boş"
      % (mb(sys_["mem_total_mb"]), mb(sys_["mem_available_mb"]),
         sys_["cpus"], mb(sys_["disk_free_mb"])))
print()
print("  %-15s %-12s %-10s %s" % ("VERİTABANI", "DURUM", "BELLEK", "AÇIKLAMA"))
print("  " + "-"*74)
for e in cat["engines"]:
    s = by.get(e["id"], {})
    p = pl.get(e["id"], {})
    if s.get("active"):
        state = "çalışıyor" if s.get("ready") else "başlıyor"
        mem = mb(s.get("memory_mb"))
        note = e["plain"]["title"]
    elif p.get("ok"):
        state, mem = "kapalı", mb(p.get("limit_mb"))
        note = e["plain"]["title"]
    else:
        state, mem = "kapalı", "—"
        note = "YER YOK: " + (p.get("reason","")[:44])
    print("  %-15s %-12s %-10s %s" % (e["id"], state, mem, note))
print()
PY
    rm -f /tmp/.st.$$ /tmp/.pl.$$
}

cmd_plan() {
    valid_engine "$1"
    _api GET "/api/engines/$1/plan" | python3 -c '
import json,sys
p=json.load(sys.stdin)
def mb(v): return "-" if v is None else ("%.1f GB"%(v/1024) if v>=1024 else "%d MB"%v)
print()
if not p.get("ok"):
    print("  AÇILAMAZ:", p.get("reason")); print(); raise SystemExit(1)
print("  Ayrılacak bellek     :", mb(p["limit_mb"]), "(%s)" % p["source"])
print("  Sonrasında boşta     :", mb(p["headroom_mb"]))
print("  Sunucu toplam / boş  :", mb(p["host_total_mb"]), "/", mb(p["host_available_mb"]))
print("  İşletim sistemi payı :", mb(p["os_reserve_mb"]))
print("  Açık motorlar        :", mb(p["committed_mb"]))
print()
print("  Hesaplanan ayarlar:")
for k in sorted(p["tuning"]): print("    %-32s %s" % (k, p["tuning"][k]))
print()
'
}

cmd_enable() {
    valid_engine "$1"
    log "$1 için kaynak planı hesaplanıyor…"
    local job; job="$(_api POST "/api/engines/$1/activate" '{}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"])')"
    watch_job "$job"
}

cmd_disable() {
    valid_engine "$1"
    local job; job="$(_api POST "/api/engines/$1/deactivate" '{}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"])')"
    watch_job "$job"
}

cmd_replica() {
    local action="$1" engine="$2"
    valid_engine "$engine"
    local ep="replication-enable"; [ "$action" = "off" ] && ep="replication-disable"
    local job; job="$(_api POST "/api/engines/$engine/$ep" '{}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"])')"
    watch_job "$job"
}

cmd_conn() {
    valid_engine "$1"
    _api GET "/api/engines/$1/connection" | python3 -c '
import json,sys
c=json.load(sys.stdin)
print()
if c["uri"]: print("  Bağlantı adresi :", c["uri"])
print("  Sunucu          :", c["host"])
print("  Port            :", c["port"])
if c["username"]: print("  Kullanıcı       :", c["username"])
if c["password"]: print("  Parola          :", c["password"])
if c["database"]: print("  Veritabanı      :", c["database"])
print()
'
}

cmd_panel() {
    valid_engine "$1"
    python3 -c '
import json,sys,os
cat=json.load(open(sys.argv[1],encoding="utf-8")); eid=sys.argv[2]
e=[x for x in cat["engines"] if x["id"]==eid][0]
if not e.get("panel"): print("Bu veritabanının web paneli yok."); raise SystemExit
p=e["panel"]
print("%s: https://%s:%d%s" % (p["name"], os.environ.get("STACK_HOST","localhost"),
                               p["port"], p.get("path","/")))
' "$CATALOG" "$1"
}

cmd_failover() {
    local action="$1" engine="${2:-}"
    case "$action" in
        status)
            _api GET /api/topology | python3 -c '
import json,sys,time
d=json.load(sys.stdin); topo=d["topology"]; auto=set(d["auto_failover"])
print()
print("  Otomatik devir açık : %s" % (", ".join(sorted(auto)) or "hiçbiri"))
print()
if not topo:
    print("  Hiç devir yaşanmadı — tüm motorlar özgün ana kopyalarında.")
else:
    print("  %-14s %-24s %-8s %s" % ("MOTOR","ŞU ANKİ ANA KOPYA","DEVİR","NE ZAMAN"))
    for k,v in sorted(topo.items()):
        print("  %-14s %-24s %-8s %s" % (k, v.get("primary","?"), v.get("failovers",0),
              time.strftime("%Y-%m-%d %H:%M", time.localtime(v.get("since",0)))))
print()
' ;;
        on|off)
            valid_engine "$engine"
            local en=true; [ "$action" = "off" ] && en=false
            _api POST "/api/engines/$engine/failover-auto" "{\"enabled\": $en}" >/dev/null                 && ok "$engine için otomatik devir: $action"
            ;;
        now)
            valid_engine "$engine"
            warn "Elle devir: ana kopya DURDURULACAK, yedek kopya devreye alınacak."
            printf "Devam etmek için 'evet' yazın: "; read -r a
            [ "$a" = "evet" ] || exit 0
            local job; job="$(_api POST "/api/engines/$engine/failover" '{}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"])')"
            watch_job "$job" ;;
        rebuild)
            valid_engine "$engine"
            local job; job="$(_api POST "/api/engines/$engine/rebuild-standby" '{}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["job"])')"
            watch_job "$job" ;;
        *) die "Kullanım: ./stack.sh failover status|on|off|now|rebuild [motor]" ;;
    esac
}

cmd_events() {
    _api GET /api/events | python3 -c '
import json,sys,time
ev=json.load(sys.stdin)["events"]
print()
if not ev: print("  Henüz olay yok."); raise SystemExit
for e in ev[-40:]:
    print("  %s  [%-8s] %-14s %s" % (
        time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e["ts"])),
        e["level"], e["engine"], e["message"]))
print()
'
}

cmd_licenses() {
    PYTHONIOENCODING=utf-8 python3 - "$CATALOG" <<'PY'
import json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
sym = {True: "  serbest", "copyleft": "! copyleft", False: "X LISANS GEREKIR"}
print()
print("  %-14s %-34s %s" % ("MOTOR", "LISANS", "URETIMDE"))
print("  " + "-"*72)
for e in cat["engines"]:
    l = e.get("license", {})
    print("  %-14s %-34s %s" % (e["id"], l.get("name","?"),
          sym.get(l.get("free_for_production"), "?")))
print()
for e in cat["engines"]:
    l = e.get("license", {})
    if l.get("free_for_production") is not True:
        print("  %s (%s)" % (e["name"], l.get("name")))
        print("    " + (l.get("note") or ""))
        if l.get("alternative"):
            print("    Alternatif: " + l["alternative"])
        print()
print("  Ayrinti: docs/LICENSING.md")
print()
PY
}

# state/ ve logs/ altındaki dosyalara İKİ AYRI KİMLİK yazar: controller
# (container'ın içinde root) ve sunucudaki yönetici. Kim önce yazarsa dosya
# onun olur; 0644/root:root bir dosyaya yönetici bir daha yazamaz. Bunun
# sonucu SESSİZDİR ve tam olarak şudur: crontab'daki gece işleri
# (backup.sh, pitr.sh taban, restore-drill.sh, failover-drill.sh) "Kilit
# dosyası açılamadı" ile düşer, panel kendi yolundan yedek almayı sürdürdüğü
# için de kimse aylarca fark etmez.
#
# Kontrol dosyanın MODUNA değil, GERÇEKTEN YAZILABİLİRLİĞİNE bakar: mod
# doğru görünüp grup üyeliği eksikse yine yazamayız.
_paylasilan_yollar() {
    printf '%s\n' "$STACK_ROOT/state" "$STACK_ROOT/logs"
    # PITR dizinlerine de İKİ TARAF yazar: motorun kendi kullanıcısı
    # (archive_command, container'ın içinden) ve buradaki yönetici
    # (pitr.sh taban / temizle). Biri sahiplenirse diğeri sessizce düşer:
    #   backups/mariadb/taban/...sql.gz: Permission denied   (ölçüldü)
    printf '%s\n' \
        "$STACK_ROOT/backups/postgresql/wal" "$STACK_ROOT/backups/postgresql/taban" \
        "$STACK_ROOT/backups/mariadb/binlog" "$STACK_ROOT/backups/mariadb/taban" \
        "$STACK_ROOT/backups/.ice-aktarma"
    # SIRLAR BU LİSTEDE YOK — bilerek. state/mongo-keyfile 0400 olmak
    # ZORUNDA: MongoDB, gruba/başkasına açık bir keyfile görürse
    # "permissions on keyfile are too open" deyip HİÇ AÇILMAZ. Onu
    # "yazılamıyor" diye raporlayıp g+w vermek replica set'i tamamen
    # kırardı — bir kez yaşandı, --duzelt keyfile'ı 0460 yaptı.
    # Bu yüzden dosyalar TÜRÜNE göre seçiliyor: kilitler, durum kayıtları
    # ve günlükler paylaşılır; anahtarlar ve sertifikalar paylaşılmaz.
    find "$STACK_ROOT/state" "$STACK_ROOT/logs" -maxdepth 1 -type f \
         \( -name "*.lock" -o -name "*.json" -o -name "*.jsonl" \
            -o -name "*.env" -o -name "*.conf" -o -name "*.log" \) 2>/dev/null
}

_yazilamayanlar() {
    local y
    while IFS= read -r y; do
        [ -e "$y" ] || continue
        [ -w "$y" ] || printf '%s\n' "$y"
    done < <(_paylasilan_yollar)
}

cmd_doctor_duzelt() {
    heading "Paylaşılan dosya izinleri onarılıyor"
    local grup S=""
    # Grup, kök dizinin grubu: kurulumda yöneticinin ait olduğu grup budur
    # (docker host'unda tipik olarak 'docker').
    grup="$(stat -c '%G' "$STACK_ROOT" 2>/dev/null)" || grup=""
    [ -n "$grup" ] || die "Kök dizinin grubu okunamadı: $STACK_ROOT"
    # Root'a ait dosyaları ancak root düzeltebilir.
    if [ "$(id -u)" != "0" ]; then
        command -v sudo >/dev/null 2>&1             || die "Bazı dosyalar root'a ait; düzeltmek için root gerekiyor ve sudo yok."
        S="sudo"
        log "root'a ait dosyalar var — sudo ile düzeltiliyor"
    fi
    # setgid: bundan SONRA açılacak dosyalar grubu miras alır. Tek başına
    # yetmez (yazma bitini vermez), umask 0002 ile birlikte çalışır.
    $S chgrp -R "$grup" "$STACK_ROOT/state" "$STACK_ROOT/logs" 2>/dev/null || true
    # PITR dizinlerinde YALNIZ DİZİNİN kendisi düzeltiliyor: içindeki WAL/
    # binlog dosyalarının sahibi motorun kullanıcısıdır ve öyle kalmalı.
    # Silme yetkisi dosyanın değil DİZİNİN yazma bitine bağlı olduğu için
    # yönetici yine temizlik yapabilir.
    for _d in "$STACK_ROOT"/backups/postgresql/wal "$STACK_ROOT"/backups/postgresql/taban \
              "$STACK_ROOT"/backups/mariadb/binlog "$STACK_ROOT"/backups/mariadb/taban \
              "$STACK_ROOT"/backups/.ice-aktarma; do
        [ -d "$_d" ] || continue
        $S chgrp "$grup" "$_d" 2>/dev/null || true
        $S chmod 2775 "$_d" 2>/dev/null || true
    done
    if ! $S chmod 2775 "$STACK_ROOT/state" "$STACK_ROOT/logs"; then
        die "Dizin izni değiştirilemedi.
  Dosyaların bir kısmı root'a ait ve sudo parola isteyemedi (tty yok).
  Doğrudan root olarak çalıştırın:
    sudo ./stack.sh doctor --duzelt"
    fi
    # Yalnız paylaşılan TÜRLER; sırlara (mongo-keyfile, *.key) dokunulmuyor.
    $S find "$STACK_ROOT/state" "$STACK_ROOT/logs" -maxdepth 1 -type f \
         \( -name "*.lock" -o -name "*.json" -o -name "*.jsonl" \
            -o -name "*.env" -o -name "*.conf" -o -name "*.log" \) \
        -exec chmod g+w {} + 2>/dev/null || true
    # Kilit dosyaları veri TAŞIMAZ; iki kimliğin paylaşabilmesi için en geniş
    # modu hak ederler. Paylaşamazlarsa kilit hiçbir şeyi engellemez olur.
    $S find "$STACK_ROOT/state" -maxdepth 1 -name '*.lock'         -exec chmod 0666 {} + 2>/dev/null || true
    local kalan
    kalan="$(_yazilamayanlar | wc -l)"
    if [ "$kalan" -eq 0 ]; then
        ok "paylaşılan dosyaların hepsi yazılabilir"
    else
        err "$kalan dosya hâlâ yazılamıyor:"
        _yazilamayanlar | sed 's/^/    /' >&2
        return 1
    fi
}

cmd_doctor() {
    heading "Sistem kontrolü"
    require_docker && ok "Docker çalışıyor"
    [ -f .env ] || die ".env yok — ./install.sh çalıştırın"
    [ -f certs/server.crt ] || warn "TLS sertifikası yok — ./scripts/gen-certs.sh"
    [ -f gateway/.htpasswd ] || warn "Panel parolası yok — ./install.sh çalıştırın"
    [ -n "${STACK_DIR:-}" ] && [[ "$STACK_DIR" = /* ]] \
        && ok "STACK_DIR mutlak: $STACK_DIR" \
        || warn "STACK_DIR mutlak değil — aktivasyon çalışmaz"
    container_running gateway    && ok "gateway ayakta"    || warn "gateway kapalı"
    container_running controller && ok "controller ayakta" || warn "controller kapalı"
    compose config -q && ok "docker-compose.yml geçerli"
    # nginx yapılandırmasını GERÇEK nginx ile doğrula. Statik denetim
    # "duplicate directive" gibi hataları yakalayamaz; bu yakalar.
    if container_running gateway; then
        if docker exec gateway nginx -t >/dev/null 2>&1; then
            ok "nginx yapılandırması geçerli"
        else
            err "nginx yapılandırması HATALI:"
            docker exec gateway nginx -t 2>&1 | sed "s/^/    /"
        fi
    fi
    # --- Yayınlanan portlar GERÇEKTEN gateway'e ulaşıyor mu? ------------------
    # nginx sapasağlam olabilir ve panel yine de açılmayabilir: host'taki başka
    # bir yönlendirme trafiği yolda kaçırıyorsa. Gerçek bir olayda aynı sunucuda
    # kurulu k3s buna yol açtı — `systemctl stop k3s` sonrası bile pod'ları
    # containerd altında yaşamaya devam etti ve iptables'ta KUBE-SERVICES /
    # CNI-HOSTPORT-DNAT zincirleri DOCKER zincirinden ÖNCE geldiği için 80 ve
    # 443, Traefik'e gitti. Kullanıcı "404 page not found" gördü; docker ps,
    # nginx -t ve container içi istek hepsi sağlıklıydı. Bu yüzden kontrol
    # işlevsel: dışarıdan gelen cevap, container'ın kendi cevabıyla aynı mı?
    if container_running gateway; then
        _in="$(docker exec gateway curl -s -o /dev/null -w '%{http_code}' \
                 http://127.0.0.1:80/ 2>/dev/null || echo 000)"
        _out="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                 http://127.0.0.1:80/ 2>/dev/null || echo 000)"
        if [ "$_in" = "$_out" ]; then
            ok "yayınlanan portlar gateway'e ulaşıyor (80 → $_out)"
        else
            err "80 portu gateway'e ULAŞMIYOR: container içinden $_in, dışarıdan $_out"
            cat >&2 <<'HINT'

    Host'ta başka bir şey 80/443'ü kaçırıyor. En sık sebep: aynı makinede
    kurulu Kubernetes (k3s). k3s'i durdurmak YETMEZ — pod'ları containerd
    altında yaşamaya devam eder ve iptables kuralları kalır:

      sudo /usr/local/bin/k3s-killall.sh     # pod'ları ve kuralları temizler
      sudo systemctl disable --now k3s       # açılışta geri gelmesin
      docker restart gateway

    Kimin dinlediğini görmek için:  sudo ss -lntp | grep -E ':80 |:443 '
    Yönlendirme kurallarını görmek için:  sudo iptables -t nat -L PREROUTING -n

HINT
        fi
    fi
    # --- Çalışan controller, depodaki kodla AYNI mı? ------------------------
    # Controller bir İMAJDAN çalışır (compose'da `build:` var), gateway gibi
    # bind-mount'tan değil. Yani `git pull` + `docker compose up -d` controller
    # kodunu GÜNCELLEMEZ: yeni kod diskte durur, container eski imajla çalışmaya
    # devam eder ve hiçbir hata çıkmaz. Belgelenen yükseltme yolu (`./install.sh`)
    # imajı yeniden derlediği için doğrudur — ama alışkanlıktan `up -d` diyen
    # biri "düzelttim ama hiçbir şey değişmedi" ile karşılaşır ve hatayı yanlış
    # yerde arar. Burada karşılaştırıp söylüyoruz.
    if container_running controller && [ -f controller/app.py ]; then
        _local_md5="$(md5sum controller/app.py 2>/dev/null | cut -d' ' -f1)"
        _img_md5="$(docker exec controller md5sum /app/app.py 2>/dev/null | cut -d' ' -f1)"
        if [ -n "$_local_md5" ] && [ -n "$_img_md5" ] && [ "$_local_md5" != "$_img_md5" ]; then
            warn "Çalışan controller, depodaki koddan FARKLI (imaj eski)."
            cat >&2 <<'HINT'

    Controller bir imajdan çalışır; `docker compose up -d` onu yeniden
    derlemez. Güncellemek için:

      ./install.sh          # imajı yeniden derler, parolalara dokunmaz

    ya da yalnız controller için:

      docker compose --env-file .env -p databases-stack up -d --build controller

HINT
        else
            [ -n "$_img_md5" ] && ok "controller imajı depodaki kodla aynı"
        fi
    fi
    # --- TOPOLOJİDEKİ ANA KOPYA GERÇEKTEN YAZMA KABUL EDİYOR MU? ---------
    # Roller compose'a state/roles.env ile geçiyor. `docker compose up -d`
    # ELLE, o env dosyası olmadan çalıştırılırsa (ya da başka bir yoldan
    # container yeniden oluşturulursa) yükseltilmiş ana kopya varsayılan
    # salt-okunur ayarıyla açılır: topoloji "ana kopya mariadb-replica" der,
    # o düğüm ise hiçbir yazmayı kabul etmez. Hiçbir hata çıkmaz; yazan
    # uygulama "read-only" alır ve sebebi panelde görünmez.
    # Ölçüldü: elle recreate sonrası read_only=1, ürünün kendi yolundan
    # (./stack.sh enable) sonra read_only=0.
    if container_running controller; then
        _api GET /api/status 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
kopuk = [e for e in d.get("engines", [])
         if e.get("replication_active") and e.get("replication_flowing") is False]
if kopuk:
    print("  ⚠  Yedek kopyası AYAKTA ama replikasyonu AKMAYAN motorlar:")
    for e in kopuk:
        print("       %-14s %s" % (e["id"], (e.get("replication_detail") or "")[:60]))
    print("     Devirde bu yedek kopyalar İŞE YARAMAZ. Onarım:")
    print("       ./stack.sh failover rebuild <motor>")
else:
    print("  ✓ açık yedek kopyaların replikasyonu akıyor")
'
    fi
    # --- COMPOSE'DAKİ PORTLAR GERÇEKTEN YAYINLANMIŞ MI? ------------------
    # `docker restart` compose değişikliğini UYGULAMAZ: yeni port ya da yeni
    # mount ancak container YENİDEN OLUŞTURULUNCA geçerli olur. Arada hiçbir
    # hata çıkmaz — servis ayakta, sağlıklı, ama yeni port kapalıdır.
    # Gerçek olay: PgBouncer eklendi, container sağlıklı çalışıyordu, kendi
    # sağlık kontrolü her 30 saniyede başarıyla bağlanıyordu; ama gateway
    # 6432'yi hiç dinlemiyordu çünkü yalnız `docker restart` yapılmıştı.
    if container_running gateway; then
        _eksik_port=""
        for _p in $(grep -oE '^      - "[0-9]+:[0-9]+"' docker-compose.yml                     | grep -oE '[0-9]+:' | tr -d ':' | sort -u); do
            docker port gateway 2>/dev/null | grep -q "^${_p}/"                 || docker ps --filter name=gateway --format '{{.Ports}}'                    | grep -q ":${_p}->" || _eksik_port="$_eksik_port $_p"
        done
        if [ -n "$_eksik_port" ]; then
            warn "Compose'da tanımlı ama gateway'de YAYINLANMAYAN portlar:$_eksik_port"
            warn "→ `docker restart` yetmez; container yeniden oluşturulmalı:"
            warn "   docker compose --env-file .env -p $STACK_PROJECT up -d gateway"
        else
            ok "compose'daki portların hepsi gateway'de yayınlanmış"
        fi
    fi
    # --- ÇALIŞAN nginx yapılandırması ŞABLONLA aynı mı? -------------------
    # nginx resmi imajı templates/*.template dosyalarını AÇILIŞTA envsubst ile
    # işler. Yani şablonu değiştirmek yetmez, gateway'in yeniden başlaması
    # gerekir — ve bu unutulduğunda hiçbir hata çıkmaz: nginx eski üretilmiş
    # dosyayla sapasağlam çalışır. Gerçek olay: /yedekler sayfası eklendi,
    # dosyalar yerindeydi, doctor "panel dosyaları aynı" diyordu ve sayfa
    # 404 veriyordu. Şablondaki her `location = /…` yolunun çalışan
    # yapılandırmada da bulunduğunu kontrol ediyoruz.
    if container_running gateway; then
        _tpl=gateway/templates/stack.conf.template
        _eksik=""
        if [ -f "$_tpl" ]; then
            for _loc in $(grep -oE "location = /[a-zA-Z0-9_.-]+" "$_tpl" | awk "{print \$3}" | sort -u); do
                docker exec gateway grep -qF "location = $_loc" /etc/nginx/conf.d/stack.conf 2>/dev/null                     || _eksik="$_eksik $_loc"
            done
        fi
        if [ -n "$_eksik" ]; then
            warn "Çalışan nginx yapılandırması ŞABLONDAN ESKİ — eksik adresler:$_eksik"
            warn "→ Şablon açılışta işlenir; düzeltmek için: docker restart gateway"
        else
            ok "çalışan nginx yapılandırması şablonla aynı"
        fi
    fi
    # --- PANELİN STATİK DOSYALARI gateway'in gördüğüyle AYNI mı? -----------
    # Controller bir imajdan çalıştığı için yukarıda md5 karşılaştırması var;
    # panelin html/js/css'i ise bind-mount'tur ve "git pull yeter" sanılır.
    # Sanılmaz: dosyalar başka bir yoldan (elle kopyalama, kısmi kurulum)
    # eskimiş olabilir ve HİÇBİR HATA ÇIKMAZ — panel açılır, yalnız yeni
    # özellik yoktur. Gerçek olay: tema düğmesi depoda vardı, sunucudaki
    # index.html eskiydi; kullanıcı düğmeyi göremedi, biz de günlerce
    # fark etmedik çünkü hiçbir şey bozuk görünmüyordu.
    if container_running gateway; then
        _panel_fark=""
        for _f in index.html app.js style.css setup.html inactive.html; do
            [ -f "gateway/html/$_f" ] || continue
            _a="$(md5sum "gateway/html/$_f" 2>/dev/null | cut -d' ' -f1)"
            _b="$(docker exec gateway md5sum "/usr/share/nginx/html/$_f" 2>/dev/null | cut -d' ' -f1)"
            [ -n "$_b" ] && [ "$_a" != "$_b" ] && _panel_fark="$_panel_fark $_f"
        done
        if [ -n "$_panel_fark" ]; then
            warn "Panelin gateway'de GÖRÜNEN dosyaları depodakinden farklı:$_panel_fark"
            warn "→ Bu sessiz bir arızadır: panel açılır ama yeni özellikler yoktur."
            warn "→ Düzeltmek için: docker restart gateway  (bind-mount ise dosyaları kopyalayın)"
        else
            ok "panelin statik dosyaları depodakiyle aynı"
        fi
    fi
    ./scripts/check-catalog.sh || true
    if container_running controller; then
        _api GET /api/status | python3 -c '
import json,sys
s=json.load(sys.stdin)
if s.get("preflight_error"): print("  ⚠ ", s["preflight_error"])
else: print("  ✓ controller aktivasyona hazır")
# ARTIK CONTAINER: motor kapalı sayılıyor ama servisleri hâlâ ayakta.
# Bu sessiz bir yüktür — panelde "kapalı" yazarken `docker ps` doludur ve
# yeniden başlayan bir container işlemci yakar. Kapatma komutu temizler.
artik = [(e["id"], e["stray"]) for e in s.get("engines", []) if e.get("stray")]
if artik:
    print()
    print("  ⚠  Kapalı görünen motorların ayakta kalan containerları var:")
    for eid, sv in artik:
        print("       %-14s %s" % (eid, ", ".join("%s (%s)" % (x["service"], x["status"]) for x in sv)))
    print("     Temizlemek için: %s" % " ; ".join("./stack.sh disable %s" % e for e, _ in artik))
else:
    print("  ✓ kapalı motorlardan artık container kalmamış")
'
    fi
    # --- Yedekleme GERÇEKTEN koşuyor mu? -------------------------------------
    # En pahalı yanılgı, yedek alındığını SANMAKTIR. Eski kurulum çıktısı
    # "state/crontab hazır" diyordu; dosyayı kuran olmadığı için bir test
    # sunucusunda `crontab -l` boş, backups/ altındaki klasörler de boştu ve
    # bu aylarca fark edilmedi. Bu yüzden doctor artık dosyaya/varsayıma değil,
    # zamanlamayı asıl yürüten controller'a soruyor: açık mı, son koşu ne oldu?
    if container_running controller; then
        if _api GET /api/backups > /tmp/.bk.$$ 2>/dev/null; then
            python3 -c '
import json, sys, time
d = json.load(sys.stdin)
s = d.get("schedule") or {}
if not s.get("enabled"):
    print("  ⚠  Otomatik yedek KAPALI — hiçbir yedek alınmıyor.")
    print("     Panelde Yedekler bölümünden açın; saat ve saklama süresi orada.")
else:
    print("  ✓ otomatik yedek açık — her gün %s, %s gün saklanıyor"
          % (s.get("time") or "??:??", s.get("retention_days")))
    last = s.get("last_run")
    if not last:
        print("  ⚠  Zamanlama açık ama HENÜZ HİÇ koşmadı — ilk koşudan önce")
        print("     bu normaldir; saati geçtiyse: docker logs controller")
    elif not s.get("last_ok"):
        print("  ⚠  Son yedekleme BAŞARISIZ: %s%s" % (
              time.strftime("%Y-%m-%d %H:%M", time.localtime(last)),
              " — " + str(s.get("last_error")) if s.get("last_error") else ""))
        print("     Ayrıntı: logs/backup_<tarih>.log")
    else:
        print("  ✓ son yedekleme başarılı: %s"
              % time.strftime("%Y-%m-%d %H:%M", time.localtime(last)))
    if s.get("running"):
        print("  ✓ şu anda bir yedekleme koşuyor")
print("__SCHED__ %d" % (1 if s.get("enabled") else 0))
' < /tmp/.bk.$$ > /tmp/.bkout.$$
            grep -v '^__SCHED__' /tmp/.bkout.$$ || true
            _sched="$(awk '$1=="__SCHED__" {print $2}' /tmp/.bkout.$$)"
            rm -f /tmp/.bk.$$ /tmp/.bkout.$$
            # Host cron ile panel zamanlaması AYNI ANDA açık olabilir: eski
            # kurulumda `crontab state/crontab` yükleyip sonra panelden de
            # açanlar böyle kalıyor. Veri riski yok — backup.sh acquire_lock
            # ile tek koşuya zorlar, ikincisi kilide takılıp çıkar — ama iki
            # ayrı yerden yönetilen bir zamanlama, ilerideki "neden 02:00'de
            # koştu" sorusunu iki kat zorlaştırır. Bilgi olarak yazıyoruz.
            if [ "${_sched:-0}" = "1" ] && command -v crontab >/dev/null 2>&1 \
               && crontab -l 2>/dev/null | grep -q "backup\.sh"; then
                log "Host crontab'ında da backup.sh var; panel zamanlaması açık olduğu için yedek iki yerden tetikleniyor. Zararsız (backup.sh kilit alır) ama gereksiz — birini bırakın, panel tek başına yeterli."
            fi
        else
            warn "Yedek durumu okunamadı (/api/backups) — controller imajı eski olabilir: ./install.sh"
            rm -f /tmp/.bk.$$
        fi
    fi

    # --- Betiklerde Windows satır sonu (\r) var mı? ------------------
    # Depo LF'e zorlanmış (.gitattributes) ama dosyalar depoyu ATLAYARAK da
    # gelebiliyor: WinSCP/FileZilla ile kopyalama, Windows'ta düzenleyip
    # yapıştırma, panoya alıp `cat > dosya` ile yazma. Sonucu her seferinde
    # aynı ve teşhisi zor:
    #     ./backup.sh: /bin/bash^M: bad interpreter: No such file or directory
    #     set: line 7: illegal option -
    # İkinci mesaj hiçbir yerde "\r" demiyor; insan hatayı betikte arar.
    local _cr=0 _f
    for _f in "$STACK_ROOT"/stack.sh "$STACK_ROOT"/install.sh \
              "$STACK_ROOT"/scripts/*.sh "$STACK_ROOT"/scripts/*/*.sh; do
        [ -f "$_f" ] || continue
        if LC_ALL=C grep -q "$(printf '\r')" "$_f" 2>/dev/null; then
            [ "$_cr" -eq 0 ] && err "Bu betiklerde Windows satır sonu (\r) var — kabuk onları komutun parçası sanar:"
            printf '    %s\n' "${_f#$STACK_ROOT/}" >&2
            _cr=$((_cr+1))
        fi
    done
    if [ "$_cr" -eq 0 ]; then
        ok "betiklerde Windows satır sonu yok"
    else
        printf '\n    Onarım:  sed -i "s/\r$//" <dosya>\n\n' >&2
    fi

    # --- Paylaşılan dosyalar gerçekten yazılabilir mi? -----------------------
    local _kotu
    _kotu="$(_yazilamayanlar)"
    if [ -z "$_kotu" ]; then
        ok "state/ ve logs/ altındaki paylaşılan dosyalar yazılabilir"
    else
        err "Bu dosyalara YAZAMIYORSUNUZ (controller root olarak yazmış):"
        printf '%s\n' "$_kotu" | while IFS= read -r _f; do
            printf '    %s  (%s)\n' "$_f" "$(stat -c '%U:%G %a' "$_f" 2>/dev/null || echo '?')" >&2
        done
        cat >&2 <<'HINT'

    Sonucu sessizdir: crontab'daki gece işleri (backup.sh, pitr.sh taban,
    restore-drill.sh, failover-drill.sh) "Kilit dosyası açılamadı" ile
    düşer. Panel kendi yolundan çalışmayı sürdürdüğü için hata görünmez.

    Onarım:  ./stack.sh doctor --duzelt

HINT
    fi
}

cmd_help() {
cat <<EOF

${BOLD}databases-stack${NC} — tek sunucuda çok veritabanlı yığın

${BOLD}Veritabanı yönetimi${NC}
  ./stack.sh list                 Motorları, durumlarını ve tahmini belleği listele
  ./stack.sh enable <motor>       Aç (bellek otomatik hesaplanır)
  ./stack.sh disable <motor>      Kapat (veri silinmez)
  ./stack.sh plan <motor>         Açılsa ne kadar bellek ayrılırdı, göster
  ./stack.sh conn <motor>         Uygulamanın kullanacağı bağlantı bilgisi
  ./stack.sh panel <motor>        Web panelinin adresi
  ./stack.sh replica on|off <motor>   Yedek kopya (master-slave) kur/kaldır

${BOLD}Otomatik devir (failover)${NC}
  ./stack.sh failover status          Hangi motorlarda açık, devir geçmişi
  ./stack.sh failover on <motor>      Otomatik devri aç
  ./stack.sh failover off <motor>     Kapat
  ./stack.sh failover now <motor>     Elle devir yap (test/bakım için)
  ./stack.sh failover rebuild <motor> Eski ana kopyayı yedek olarak yeniden kur
  ./stack.sh events                   Son olaylar (devirler, uyarılar)

${BOLD}Bakım${NC}
  ./stack.sh backup [motor|all]   Yedek al (varsayılan: aktif motorların hepsi)
  ./stack.sh prova <motor>        Kurtarma provası — yedeği GERÇEKTEN geri yükler
                                  (tek kullanımlık kopyada, üretime dokunmadan)
  ./stack.sh getir <motor> <dosya>  Dışarıdan veri aktar (dump ya da uzak kaynak)
  ./stack.sh pitr durum|don ...   Zaman noktasına dönüş (PostgreSQL, MariaDB)
  ./stack.sh bakim [durum|bakim]  Tablo şişkinliğini ölç / temizle
  ./stack.sh sorgu [durum|oneri]  En pahalı sorgular ve indeks önerileri
  ./stack.sh devir-provasi <motor>  Gerçek devir yapıp KESİNTİ SÜRESİNİ ölç
  ./stack.sh restore <motor> <dosya>
  ./stack.sh sync                 Yedekleri uzak depoya gönder
  ./stack.sh app-user             Uygulama için kısıtlı kullanıcı oluştur
  ./stack.sh logs <servis>        Son 200 satır log
  ./stack.sh licenses             Motorların lisansları ve kısıtları
  ./stack.sh doctor [--duzelt]    Kurulum sağlık kontrolü (--duzelt: paylaşılan
                                  dosya izinlerini onarır)
  ./stack.sh selftest             Boyutlandırma + API + nginx testleri (docker gerekmez)
  ./stack.sh e2e [paket]          Uçtan uca doğrulama — ÇALIŞAN kuruluma karşı
                                  (veri yazar/siler, devir tetikler; test ortamı için)

${BOLD}Çekirdek${NC}
  ./stack.sh up | down | restart  Gateway + controller
  ./stack.sh ps                   Tüm container'lar

Motorlar: $(engine_ids | tr '\n' ' ')

EOF
}

# =============================================================================
case "${1:-help}" in
    list|ls|status)  cmd_list ;;
    enable|on)       shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh enable <motor>";  cmd_enable "$1" ;;
    disable|off)     shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh disable <motor>"; cmd_disable "$1" ;;
    plan)            shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh plan <motor>";    cmd_plan "$1" ;;
    conn|connection) shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh conn <motor>";    cmd_conn "$1" ;;
    panel)           shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh panel <motor>";   cmd_panel "$1" ;;
    replica)         shift; [ $# -ge 2 ] || die "Kullanım: ./stack.sh replica on|off <motor>"; cmd_replica "$1" "$2" ;;
    backup)          shift; exec ./scripts/backup.sh "${@:-all}" ;;
    restore)         shift; [ $# -ge 2 ] || die "Kullanım: ./stack.sh restore <motor> <dosya>"
                     exec ./scripts/backup.sh "restore-$1" "$2" ;;
    sync)            shift; exec ./scripts/sync-remote.sh "$@" ;;
    # Yeni araçlar tek kapıdan. Kullanıcı "./stack.sh" yazıp yardım ekranına
    # bakıyor; bir özellik yalnız scripts/ altında dururken KEŞFEDİLEMEZ olur
    # ve yazılmamış sayılır.
    prova)           shift; exec ./scripts/restore-drill.sh "$@" ;;
    getir)           shift; exec ./scripts/import.sh "$@" ;;
    pitr)            shift; exec ./scripts/pitr.sh "$@" ;;
    bakim)           shift; exec ./scripts/maintenance.sh "${@:-durum}" ;;
    sorgu)           shift; exec ./scripts/slowlog.sh "${@:-durum}" ;;
    devir-provasi)   shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh devir-provasi <motor> [--onayla]"
                     exec ./scripts/failover-drill.sh "$@" ;;
    app-user)        shift; exec ./scripts/setup-app-users.sh "$@" ;;
    logs)            shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh logs <servis>"
                     compose logs --tail 200 --no-color "$1" ;;
    failover)        shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh failover status|on|off|now|rebuild [motor]"
                     cmd_failover "$1" "${2:-}" ;;
    events)          cmd_events ;;
    licenses|lisans) cmd_licenses ;;
    doctor)          shift
                     if [ "${1:-}" = "--duzelt" ]; then cmd_doctor_duzelt
                     else cmd_doctor; fi ;;
    selftest|test)   PYTHONIOENCODING=utf-8 python3 scripts/selftest.py ;;
    e2e)             shift; ./scripts/e2e/run.sh "$@" ;;
    up)              compose up -d gateway controller adminer ;;
    down)            compose down --remove-orphans ;;
    restart)         compose restart gateway controller ;;
    ps)              compose ps --all ;;
    help|-h|--help)  cmd_help ;;
    *)               err "Bilinmeyen komut: $1"; cmd_help; exit 1 ;;
esac
