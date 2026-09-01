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
    ./scripts/check-catalog.sh || true
    if container_running controller; then
        _api GET /api/status | python3 -c '
import json,sys
s=json.load(sys.stdin)
if s.get("preflight_error"): print("  ⚠ ", s["preflight_error"])
else: print("  ✓ controller aktivasyona hazır")
'
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
  ./stack.sh restore <motor> <dosya>
  ./stack.sh sync                 Yedekleri uzak depoya gönder
  ./stack.sh app-user             Uygulama için kısıtlı kullanıcı oluştur
  ./stack.sh logs <servis>        Son 200 satır log
  ./stack.sh licenses             Motorların lisansları ve kısıtları
  ./stack.sh doctor               Kurulum sağlık kontrolü
  ./stack.sh selftest             Boyutlandırma + API + nginx testleri (docker gerekmez)

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
    app-user)        shift; exec ./scripts/setup-app-users.sh "$@" ;;
    logs)            shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh logs <servis>"
                     compose logs --tail 200 --no-color "$1" ;;
    failover)        shift; [ $# -ge 1 ] || die "Kullanım: ./stack.sh failover status|on|off|now|rebuild [motor]"
                     cmd_failover "$1" "${2:-}" ;;
    events)          cmd_events ;;
    licenses|lisans) cmd_licenses ;;
    doctor)          cmd_doctor ;;
    selftest|test)   PYTHONIOENCODING=utf-8 python3 scripts/selftest.py ;;
    up)              compose up -d gateway controller adminer ;;
    down)            compose down --remove-orphans ;;
    restart)         compose restart gateway controller ;;
    ps)              compose ps --all ;;
    help|-h|--help)  cmd_help ;;
    *)               err "Bilinmeyen komut: $1"; cmd_help; exit 1 ;;
esac
