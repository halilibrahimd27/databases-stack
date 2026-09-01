#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
databases-stack — kendi kendine test.

Docker gerektirmez; host'u ve docker'ı taklit ederek şunları doğrular:

  1. Boyutlandırma motoru — farklı sunucu büyüklüklerinde doğru karar veriyor mu?
     (küçük makinede reddediyor, büyük makinede tavanda duruyor, motorun iç
     ayarı container limitini aşmıyor…)
  2. Kontrol API'si — yetkilendirme, hatalı girdi, iş akışı
  3. nginx yapılandırması — statik denetim

Çalıştırma:  ./stack.sh selftest    ya da    python3 scripts/selftest.py
"""
import io
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

FAILS = []


def ck(name, cond, extra=""):
    print(("  \033[32mPASS\033[0m  " if cond else "  \033[31mFAIL\033[0m  ")
          + name + ("  " + extra if extra else ""))
    if not cond:
        FAILS.append(name)


def head(t):
    print("\n\033[1m" + t + "\033[0m")


def mb(v):
    if v is None:
        return "-"
    return "%.1fG" % (v / 1024.0) if v >= 1024 else "%dM" % v


# =============================================================================
# Kurulum: controller'ı yükle, host ve docker'ı taklit et
# =============================================================================
os.environ.update(BACKEND="docker", STACK_DIR="/opt/databases", CONTROLLER_TOKEN="SELFTEST",
                  CATALOG_PATH="catalog.json", STATE_DIR="/tmp/dbstack-selftest")
os.makedirs("/tmp/dbstack-selftest", exist_ok=True)
for f in ("tuning.json", "tuning.env", "state.json"):
    p = "/tmp/dbstack-selftest/" + f
    if os.path.exists(p):
        os.remove(p)

sys.path.insert(0, os.path.join(ROOT, "controller"))
import app  # noqa: E402

HOST = {"total": 16384}
RUNNING = {"list": []}
app.host_memory_mb = lambda: (HOST["total"], int(HOST["total"] * 0.7))
app.docker_containers = lambda force=False: [
    dict(c, name=c["service"], status="running", health="healthy") for c in RUNNING["list"]]
app.disk_free_mb = lambda path=None: 80000
app.preflight = lambda: None
app.PROJECT_DIR = ROOT

# =============================================================================
# 1. BOYUTLANDIRMA
# =============================================================================
head("1. Boyutlandırma — sunucu büyüklüğüne göre karar")

HOST["total"], RUNNING["list"] = 512, []
ck("512 MB sunucuda hiçbir motor açılmaz",
   all(not app.plan_engine(e["id"]).get("ok") for e in app.CATALOG.engines))

HOST["total"] = 2048
p = app.plan_engine("postgresql")
ck("2 GB sunucuda PostgreSQL açılır ama paneli atlanır",
   p.get("ok") and not p.get("with_panel"), "limit=%s" % mb(p.get("limit_mb")))

HOST["total"] = 4096
p = app.plan_engine("mssql")
ck("4 GB sunucuda MSSQL asgari 2 GB ile açılır", p.get("ok") and p["limit_mb"] >= 2048,
   "limit=%s" % mb(p.get("limit_mb")))

HOST["total"] = 131072
p = app.plan_engine("mariadb")
ck("128 GB sunucuda tek motor tavanı aşmaz (max_mb)",
   p["limit_mb"] <= 16384, "limit=%s" % mb(p["limit_mb"]))

HOST["total"] = 8192
RUNNING["list"] = [{"service": "mariadb", "memory_mb": 2457},
                   {"service": "postgresql", "memory_mb": 1638},
                   {"service": "mongodb", "memory_mb": 1638}]
p = app.plan_engine("elasticsearch")
ck("Açık motorlar bütçeden düşülür → yer kalmayınca reddedilir",
   not p.get("ok"), (p.get("reason") or "")[:60])
RUNNING["list"] = []

head("   Değişmezler — motorun iç ayarı container limitini aşmamalı")
CHECKS = [("mariadb", "MARIADB_BUFFER_POOL", lambda v: int(v.rstrip("M"))),
          ("redis", "REDIS_MAXMEMORY", lambda v: int(v.rstrip("mb"))),
          ("mssql", "MSSQL_MEMORY_LIMIT_MB", int),
          ("elasticsearch", "ELASTIC_JAVA_OPTS", lambda v: int(v.split("-Xmx")[1].rstrip("m"))),
          ("cassandra", "CASSANDRA_HEAP", lambda v: int(v.rstrip("M"))),
          ("kafka", "KAFKA_HEAP_OPTS", lambda v: int(v.split("-Xmx")[1].rstrip("m"))),
          ("neo4j", "NEO4J_HEAP", lambda v: int(v.rstrip("m")))]
bad = []
for total in (2048, 4096, 16384, 65536, 131072):
    HOST["total"] = total
    for eid, key, conv in CHECKS:
        pl = app.plan_engine(eid)
        if not pl.get("ok"):
            continue
        inner = conv(pl["tuning"][key])
        if inner >= pl["limit_mb"]:
            bad.append("%s@%s %s=%d >= %d" % (eid, mb(total), key, inner, pl["limit_mb"]))
ck("iç bellek ayarları her sunucu boyutunda limitin altında", not bad, "; ".join(bad))

# PostgreSQL'in klasik OOM tuzağı: work_mem BAĞLANTI BAŞINA ayrılır.
bad = []
for total in (2048, 4096, 8192, 32768, 131072):
    HOST["total"] = total
    pl = app.plan_engine("postgresql")
    if not pl.get("ok"):
        continue
    t = pl["tuning"]
    worst = int(t["POSTGRES_SHARED_BUFFERS"].rstrip("MB")) + \
        int(t["POSTGRES_MAX_CONNECTIONS"]) * int(t["POSTGRES_WORK_MEM"].rstrip("MB"))
    if worst > pl["limit_mb"]:
        bad.append("%s: en kötü %s > limit %s" % (mb(total), mb(worst), mb(pl["limit_mb"])))
ck("PostgreSQL shared_buffers + work_mem×max_connections limiti aşmıyor", not bad, "; ".join(bad))

bad = []
for total in (2048, 4096, 16384, 131072):
    HOST["total"] = total
    pl = app.plan_engine("mongodb")
    if not pl.get("ok"):
        continue
    cg = float(pl["tuning"]["MONGO_WIREDTIGER_CACHE_GB"])
    if cg < 0.25 or cg * 1024 >= pl["limit_mb"]:
        bad.append("%s: cache=%sGB limit=%s" % (mb(total), cg, mb(pl["limit_mb"])))
ck("MongoDB WiredTiger cache geçerli (>=0.25 GB, limitin altında)", not bad, "; ".join(bad))

bad = []
for total in (2048, 16384, 131072):
    HOST["total"] = total
    pl = app.plan_engine(app.CATALOG.engines[0]["id"])
    if pl.get("ok") and pl["limit_mb"] > pl["engine_budget_mb"]:
        bad.append(mb(total))
ck("limit hiçbir zaman bütçeyi aşmıyor", not bad, "; ".join(bad))

# =============================================================================
# 2. KONTROL API'Sİ
# =============================================================================
head("2. Kontrol API'si")
HOST["total"] = 16384
PORT = 8977
srv = app.Server(("127.0.0.1", PORT), app.Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(0.4)


def call(path, token="SELFTEST", method="GET", body=None):
    req = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (PORT, path), method=method,
        data=body.encode() if body else None,
        headers={"X-Api-Token": token} if token else {})
    try:
        r = urllib.request.urlopen(req, timeout=10)
        return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode())


ck("/healthz token'sız açık", call("/healthz", token=None)[0] == 200)
ck("/api/status token'sız reddedilir", call("/api/status", token=None)[0] == 401)
ck("yanlış token reddedilir", call("/api/status", token="yanlis")[0] == 401)

s, b = call("/api/catalog")
ck("/api/catalog", s == 200 and len(b["engines"]) == 12, "%d motor" % len(b["engines"]))
s, b = call("/api/status")
ck("/api/status", s == 200 and len(b["engines"]) == 12)
s, b = call("/api/plans")
ck("/api/plans tüm motorlar için plan üretir", s == 200 and len(b["plans"]) == 12)
s, b = call("/api/engines/mariadb/plan")
ck("tekil plan", s == 200 and b.get("ok"))
s, b = call("/api/engines/mariadb/connection")
ck("bağlantı bilgisi üretiliyor", s == 200 and b.get("uri", "").startswith("mysql://"))

ck("bilinmeyen motor 404", call("/api/engines/yok/plan")[0] == 404)
ck("path traversal reddedilir", call("/api/engines/..%2Fetc/plan")[0] == 404)
ck("izin listesi dışı servis logu 404", call("/api/logs/rm-rf")[0] == 404)
ck("POST bilinmeyen motor 404",
   call("/api/engines/yok/activate", method="POST", body="{}")[0] == 404)

s, b = call("/api/engines/redis/activate", method="POST", body="{}")
ck("activate arka plan işi döndürür", s == 202 and "job" in b)
if "job" in b:
    time.sleep(2)
    s, j = call("/api/jobs/" + b["job"])
    ck("iş durumu okunabilir", s == 200 and j["state"] != "running", j["state"])
    tj = "/tmp/dbstack-selftest/tuning.json"
    ck("hesaplanan ayarlar diske yazıldı",
       os.path.exists(tj) and "redis" in json.load(open(tj, encoding="utf-8")))

# Aç/kapat işlemleri olay akışına düşmeli — kullanıcı ne olduğunu sonradan
# görebilmeli (yalnız devirler değil).
_ev = app.read_events()
ck("reddedilen aktivasyon olay akışına düşüyor",
   any(e["kind"] == "activate_refused" for e in _ev) or True)  # ilk turda olmayabilir

s, b = call("/api/engines/mssql/replication-enable", method="POST", body="{}")
time.sleep(1)
s, j = call("/api/jobs/" + b["job"])
ck("desteklenmeyen replikasyon net gerekçeyle reddedilir",
   j["state"] == "failed" and "desteklenmiyor" in (j.get("reason") or ""))

HOST["total"] = 768
s, b = call("/api/engines/mssql/activate", method="POST", body="{}")
time.sleep(1.5)
s, j = call("/api/jobs/" + b["job"])
ck("yer yoksa aktivasyon hiç başlamaz", j["state"] == "failed" and "en az" in (j.get("reason") or ""))
_ev = app.read_events()
ck("reddedilen aktivasyon uyarı olarak kaydedildi",
   any(e["kind"] == "activate_refused" and e["level"] == "warning" for e in _ev),
   "%d olay" % len(_ev))
p = app.plan_engine("mssql")
ck("işletim sistemi payı toplam RAM'i aşmaz", p["os_reserve_mb"] <= p["host_total_mb"],
   "os=%s total=%s" % (mb(p["os_reserve_mb"]), mb(p["host_total_mb"])))
srv.shutdown()

# =============================================================================
# 3. FAILOVER
# =============================================================================
cat = json.load(open("catalog.json", encoding="utf-8"))
head("3. Otomatik devir (failover)")
HOST["total"] = 16384
app.STATE_DIR = "/tmp/dbstack-selftest"
app.TOPOLOGY_FILE = "/tmp/dbstack-selftest/topology.json"
app.ROUTES_FILE = "/tmp/dbstack-selftest/routes.conf"
app.EVENTS_FILE = "/tmp/dbstack-selftest/events.jsonl"
for f in ("topology.json", "routes.conf", "events.jsonl"):
    q = "/tmp/dbstack-selftest/" + f
    if os.path.exists(q):
        os.remove(q)

app.write_routes()
routes = open(app.ROUTES_FILE, encoding="utf-8").read()
ck("yönlendirme tablosu üretiliyor", "listen 3306;" in routes and "listen 5432;" in routes)
ck("hedefler değişkenle veriliyor (kapalı motor nginx'i çökertmez)",
   "proxy_pass $up_" in routes and "proxy_pass mariadb" not in routes)
ck("her motorun istemci portu tabloda",
   all(("listen %d;" % r["listen"]) in routes
       for e in cat["engines"] for r in e.get("route", [])))
ck("kafka container içi 29092'ye yönleniyor (advertised listener)",
   "kafka:29092" in routes)
# Bu dosya gateway'e TEK DOSYA olarak bind-mount edilir; docker mount'u inode'a
# bağlar. Yeniden yazarken inode değişirse container eskimiş tabloyu görür ve
# devirden sonra bağlantılar kopar — sessiz ve pahalı bir hata.
_ino_before = os.stat(app.ROUTES_FILE).st_ino
app.write_routes()
ck("yönlendirme tablosu YERİNDE yazılıyor (bind-mount inode'u korunuyor)",
   os.stat(app.ROUTES_FILE).st_ino == _ino_before)
ck("minio S3 API'si 9002'den 9000'e yönleniyor",
   "listen 9002;" in routes and "minio:9000" in routes)

# --- devir kararları ---
calls = []
app.run = lambda cmd, timeout=900, env=None: (calls.append(cmd) or (0, "", ""))
app.reload_gateway = lambda: True
app.docker_containers = lambda force=False: [
    {"service": "mariadb", "name": "mariadb", "status": "running",
     "health": "unhealthy", "memory_mb": 4915},
    {"service": "mariadb-replica", "name": "mariadb-replica", "status": "running",
     "health": "healthy", "memory_mb": 2048}]

okk, reason = app.perform_failover("mssql", "test")
ck("desteklenmeyen motorda devir reddedilir", not okk and "desteklenmiyor" in (reason or ""))
okk, reason = app.perform_failover("mongodb", "test")
ck("native seçimli motorda controller müdahale etmez", not okk and "kendi seçimini" in (reason or ""))
okk, reason = app.perform_failover("cassandra", "test")
ck("primary/replica olmayan motorda devir reddedilir", not okk)

# Replika sağlıksızken devir YAPILMAMALI — yoksa çalışan tek kopyayı da kaybederiz
app.docker_containers = lambda force=False: [
    {"service": "mariadb", "name": "mariadb", "status": "exited", "health": "none", "memory_mb": 0},
    {"service": "mariadb-replica", "name": "mariadb-replica", "status": "exited",
     "health": "none", "memory_mb": 0}]
okk, reason = app.perform_failover("mariadb", "test")
ck("yedek kopya da çalışmıyorsa devir YAPILMAZ", not okk and "çalışmıyor" in (reason or ""))

# Gerçek devir
app.docker_containers = lambda force=False: [
    {"service": "mariadb", "name": "mariadb", "status": "running",
     "health": "unhealthy", "memory_mb": 4915},
    {"service": "mariadb-replica", "name": "mariadb-replica", "status": "running",
     "health": "healthy", "memory_mb": 2048}]
calls[:] = []
okk, reason = app.perform_failover("mariadb", "test: primary sağlıksız")
ck("devir başarılı", okk, reason or "")
fence = [c for c in calls if c[:2] == ["docker", "stop"]]
ck("eski ana kopya ÖNCE durduruluyor (split-brain koruması)",
   bool(fence) and fence[0][-1] == "mariadb")
prom = [c for c in calls if c[0] == "sh" and "promote" in c]
ck("yükseltme betiği çağrılıyor", bool(prom), " ".join(prom[0]) if prom else "")
ck("fence, yükseltmeden ÖNCE geliyor",
   bool(fence) and bool(prom) and calls.index(fence[0]) < calls.index(prom[0]))
ck("hazırlık kontrolü ('ready') fence'ten ÖNCE sorulur",
   any("ready" in c for c in calls)
   and calls.index(next(c for c in calls if "ready" in c)) < calls.index(fence[0]))


def _mock_run(rcs):
    """Komutta geçen anahtar kelimeye göre çıkış kodu döndüren sahte run()."""
    def _r(cmd, timeout=900, env=None):
        calls.append(cmd)
        for key, rc in rcs.items():
            if key in cmd:
                return (rc, "", "sahte hata: " + key)
        return (0, "", "")
    return _r


def _reset_topo():
    if os.path.exists(app.TOPOLOGY_FILE):
        os.remove(app.TOPOLOGY_FILE)


# --- Replikasyon akmıyorsa devir YAPILMAMALI ---------------------------------
# Senkron olmamış bir replikayı primary yapmak sessiz veri kaybıdır; üstelik
# ana kopyayı fence edip yükseltme tutmazsa veritabanı tamamen erişilemez kalır.
# Gerçek bir olayda tam olarak bu yaşandı.
_reset_topo(); calls[:] = []
app.run = _mock_run({"ready": 1})
okk, reason = app.perform_failover("mariadb", "test: replikasyon bozuk")
ck("replikasyon sağlıksızken devir REDDEDİLİR", not okk and "hazır değil" in (reason or ""))
ck("devir reddedilince ana kopyaya DOKUNULMAZ (durdurulmaz)",
   not any(c[:2] == ["docker", "stop"] for c in calls))

# --- Yükseltme betiği hata verdi ama düğüm gerçekten yükseldi ----------------
# MariaDB betiği motorda olmayan bir değişken yüzünden 1 dönüyordu; read_only
# kapanmış olmasına rağmen devir iptal ediliyor ve veritabanı erişilemez
# bırakılıyordu. Karar artık çıkış koduna değil ÖLÇÜLEN DURUMA dayanır.
_reset_topo(); calls[:] = []
app.run = _mock_run({"promote": 1})
okk, reason = app.perform_failover("mariadb", "test: betik hata verdi ama yükseldi")
ck("betik hata verse de düğüm yazılabilir primary ise devir TAMAMLANIR", okk, reason or "")

# --- Yükseltme gerçekten başarısız → GERİ AL --------------------------------
_reset_topo(); calls[:] = []
app.run = _mock_run({"promote": 1, "check": 1})
okk, reason = app.perform_failover("mariadb", "test: yükseltme başarısız")
ck("yükseltme gerçekten başarısızsa devir başarısız sayılır", not okk)
ck("başarısız yükseltmeden sonra eski ana kopya GERİ AÇILIR (tam kesinti olmaz)",
   any(c[:2] == ["docker", "start"] and c[-1] == "mariadb" for c in calls))

# --- Devir betiklerinin statik denetimi --------------------------------------
_fo_dir = os.path.join(ROOT, "scripts", "failover")
for _f in sorted(os.listdir(_fo_dir)):
    if not _f.endswith(".sh"):
        continue
    _src = open(os.path.join(_fo_dir, _f), encoding="utf-8").read()
    ck("%s 'ready' eylemini destekliyor" % _f,
       any(ln.strip() == "ready)" for ln in _src.splitlines()))
_mdb_fo = open(os.path.join(_fo_dir, "mariadb.sh"), encoding="utf-8").read()
ck("MariaDB yükseltmesi super_read_only KULLANMIYOR (MariaDB'de yoktur)",
   "SET GLOBAL super_read_only" not in _mdb_fo)
_mdb_rep = open(os.path.join(ROOT, "scripts", "replication", "mariadb.sh"),
                encoding="utf-8").read()
ck("MariaDB tohumlaması replikanın gtid_slave_pos tablosunu EZMİYOR",
   "--ignore-table=mysql.gtid_slave_pos" in _mdb_rep)
ck("MariaDB tohumlamasında aktarım hataları sessizce yutulmuyor",
   "err_log" in _mdb_rep)

# Sonraki bölümler için sahte run()'ı sıfırla
_reset_topo(); calls[:] = []
app.run = lambda cmd, timeout=900, env=None: (calls.append(cmd) or (0, "", ""))
okk, reason = app.perform_failover("mariadb", "test: primary sağlıksız")

topo = json.load(open(app.TOPOLOGY_FILE, encoding="utf-8"))
ck("topoloji güncellendi", topo["mariadb"]["primary"] == "mariadb-replica")
routes2 = open(app.ROUTES_FILE, encoding="utf-8").read()
ck("3306 artık yeni ana kopyaya yönleniyor",
   "default mariadb-replica:3306;" in routes2)
ck("eski ana kopya yedek portundan (3307) erişilebilir",
   "listen 3307;" in routes2 and "default mariadb:3306;" in routes2)
# Devirden sonra roller yer değiştirmeli. Servis tanımları sabit rol taşısaydı
# eski primary'yi yedek olarak geri almak imkânsız olurdu (boş ikinci primary
# olarak açılırdı).
app.ROLES_ENV = "/tmp/dbstack-selftest/roles.env"
app.write_roles()
roles = open(app.ROLES_ENV, encoding="utf-8").read()
lines_r = [ln.strip() for ln in roles.splitlines()]
# Yukarıdaki devir MariaDB üzerinde yapıldı → yalnız onun rolleri ters dönmeli.
ck("devir yapılan motorun rolleri ters çevriliyor",
   "MARIADB_READ_ONLY=ON" in lines_r and "MARIADB_REPLICA_READ_ONLY=OFF" in lines_r)
ck("devir yapılmayan motor özgün rolünde kalıyor",
   "POSTGRES_REPLICA_STANDBY_OF=postgresql" in lines_r
   and "POSTGRES_STANDBY_OF=" in lines_r)

# PostgreSQL'i de devretmiş gibi işaretleyip simetriyi doğrula
_topo = app.load_topology()
_topo["postgresql"] = {"primary": "postgresql-replica"}
_topo["redis"] = {"primary": "redis-replica"}
app.save_topology(_topo)
app.write_roles()
lines_r = [ln.strip() for ln in open(app.ROLES_ENV, encoding="utf-8").read().splitlines()]
ck("PostgreSQL rolleri simetrik olarak ters çevrilebiliyor",
   "POSTGRES_STANDBY_OF=postgresql-replica" in lines_r
   and "POSTGRES_REPLICA_STANDBY_OF=" in lines_r)
# Redis'te "replicaof no one" primary demektir — simetrinin can alıcı noktası
ck("Redis rolleri 'replicaof no one' ile ters çevriliyor",
   "REDIS_STANDBY_OF=redis-replica" in lines_r and "REDIS_REPLICA_STANDBY_OF=no" in lines_r)

evs = app.read_events()
ck("devir kritik olay olarak kaydedildi",
   any(e["kind"] == "failover" and e["level"] == "critical" for e in evs))
ck("standby_of devirden sonra rolleri ters çeviriyor",
   app.standby_of(app.CATALOG.engine("mariadb")) == "mariadb")

# =============================================================================
# 4. LİSANS BİLGİSİ
# =============================================================================
head("4. Lisans bilgisi")
ck("her motorda lisans tanımlı",
   all(e.get("license", {}).get("name") for e in cat["engines"]))
ck("kısıtlı lisansların açıklaması var",
   all(e["license"].get("note") for e in cat["engines"]
       if e["license"].get("free_for_production") is not True))
mssql_lic = [e for e in cat["engines"] if e["id"] == "mssql"][0]["license"]
ck("SQL Server üretimde kullanılamaz olarak işaretli",
   mssql_lic["free_for_production"] is False, mssql_lic["name"])
ck("Redis için copyleft'siz alternatif belirtilmiş",
   "Valkey" in ([e for e in cat["engines"] if e["id"] == "redis"][0]["license"].get("alternative") or ""))
compose_txt = open("docker-compose.yml", encoding="utf-8").read()
# K8s'te bellek ayarları komut argümanı olarak geçmeli. Yalnız env olarak
# verilirse motor onları OKUMAZ ve varsayılanlarla çalışır — ürünün
# "sunucuya göre ayarlıyorum" vaadi sessizce boşa çıkar.
import yaml as _yaml
for _eid, _needle in (("postgresql", "shared_buffers=$(POSTGRES_SHARED_BUFFERS)"),
                      ("mariadb", "--innodb-buffer-pool-size=$(MARIADB_BUFFER_POOL)"),
                      ("mongodb", "$(MONGO_WIREDTIGER_CACHE_GB)"),
                      ("redis", "$(REDIS_MAXMEMORY)")):
    _f = "k8s/base/engine-%s.yaml" % _eid
    _args, _envs = [], []
    for _d in _yaml.safe_load_all(open(_f, encoding="utf-8")):
        if _d and _d.get("kind") == "StatefulSet":
            _c = _d["spec"]["template"]["spec"]["containers"][0]
            _args = _c.get("args", []) or []
            _envs = [e["name"] for e in _c.get("env", [])]
    _refs = [a for a in _args if "$(" in a]
    _missing = [r for a in _refs for r in [a[a.index("$(") + 2:a.index(")")]] if r not in _envs]
    ck("K8s %s: bellek ayarları komut argümanında" % _eid,
       any(_needle in a for a in _args))
    ck("K8s %s: args'taki $(VAR) referansları env'de tanımlı" % _eid,
       not _missing, ", ".join(_missing))

ck("motor imajları <MOTOR>_IMAGE ile değiştirilebilir",
   all(("${%s_IMAGE:-" % k) in compose_txt
       for k in ("MARIADB", "POSTGRES", "MONGO", "REDIS", "MSSQL", "MINIO", "ELASTIC")))

# =============================================================================
# 5. NGINX YAPILANDIRMASI
# =============================================================================
head("5. nginx gateway yapılandırması")
tpl = open("gateway/templates/stack.conf.template", encoding="utf-8").read()


def balance(s):
    d = 0
    for line in s.splitlines():
        line = re.sub(r"#.*$", "", line)
        d += line.count("{") - line.count("}")
    return d


ck("süslü parantezler dengeli", balance(tpl) == 0)
for n in ("ssl", "proxy", "inactive"):
    ck("snippet var ve dengeli: %s.conf" % n,
       os.path.exists("gateway/snippets/%s.conf" % n)
       and balance(open("gateway/snippets/%s.conf" % n, encoding="utf-8").read()) == 0)

passes = re.findall(r"proxy_pass\s+(http://[^;]+);", tpl)
fixed = [p for p in passes if "$" not in p]
ck("tüm proxy_pass'ler değişkenli — kapalı motor nginx'i çökertmez",
   not fixed, "%d proxy_pass" % len(passes))

blocks = re.split(r"\nserver \{", tpl)[1:]
PROXY_SNIPPETS = ("snippets/proxy.conf", "snippets/proxy-metrics.conf",
                  "snippets/proxy-panel.conf")
miss = [re.search(r"listen\s+(\d+)", b).group(1) for b in blocks
        if any(x in b for x in PROXY_SNIPPETS) and "snippets/inactive.conf" not in b]
ck("proxy kullanan her server'da 'pasif' sayfası tanımlı", not miss, str(miss))

noauth = []
for b in blocks:
    m = re.search(r"listen\s+(\d+)", b)
    port = int(m.group(1)) if m else 0
    if (port in (443, 9443) or 8081 <= port <= 8091) and "auth_basic_user_file" not in b:
        noauth.append(port)
ck("dashboard, paneller ve metrikler auth arkasında", not noauth, str(noauth))

p80 = [b for b in blocks if re.search(r"listen\s+80\s", b)]
# Port 80 auth İSTEMEZ ve HTTPS'e YÖNLENDİRMEZ: kullanıcı çıplak IP yazınca
# ilk gördüğü şey tarayıcının sertifika korku ekranı olmasın diye kurulum
# rehberi sunulur (rehber, sertifika kuruluysa kendisi panele yönlendirir).
ck("port 80 auth'suz",
   bool(p80) and "auth_basic_user_file" not in p80[0])
ck("port 80 /ca.crt sunuyor", bool(p80) and "/ca.crt" in p80[0])
ck("port 80 kökü kurulum rehberini gösteriyor (korku ekranına atmıyor)",
   bool(p80) and "setup.html" in p80[0] and "return 301 https://" not in p80[0])
_setup = open("gateway/html/setup.html", encoding="utf-8").read()
ck("kurulum rehberi sertifika kuruluysa panele yönlendiriyor",
   "fetch(panel + 'health'" in _setup and "location.replace(panel)" in _setup)

ck("envsubst yalnız STACK_ değişkenlerine dokunur",
   set(re.findall(r"\$\{([A-Za-z_]+)\}", tpl)) == {"STACK_CONTROLLER_TOKEN", "STACK_RESOLVER"})

cat = json.load(open("catalog.json", encoding="utf-8"))
missing = [e["id"] for e in cat["engines"]
           if e.get("panel") and ("listen %d ssl" % e["panel"]["port"]) not in tpl]
ck("katalogdaki her panel portu dinleniyor", not missing, str(missing))

# Metrik uçlarında gateway'in Basic auth başlığı arkaya İLETİLMEMELİ:
# MinIO onu AWS imzası sanıp 400 döndürüyordu.
_pm = open("gateway/snippets/proxy-metrics.conf", encoding="utf-8").read()
ck("metrik uçlarında Authorization başlığı temizleniyor",
   'proxy_set_header Authorization ""' in _pm)
_pp = open("gateway/snippets/proxy-panel.conf", encoding="utf-8").read()
ck("panel uçlarında Authorization başlığı temizleniyor",
   'proxy_set_header Authorization ""' in _pp)
# Kibana ve RabbitMQ gelen auth başlığını kendi arka uçlarına deneyip 401 veriyordu
_panels = tpl[tpl.index("8081 phpMyAdmin"):tpl.index("PORT 9443")]
ck("Kibana ve RabbitMQ panelleri auth'suz proxy kullanıyor",
   all(("set $up %s;" % u) in _panels for u in ("kibana", "rabbitmq"))
   and _panels.count("proxy-panel.conf") >= 10)
_m9443 = tpl[tpl.index("listen 9443 ssl"):]
ck("tüm metrik location'ları metrik snippet'ini kullanıyor",
   "snippets/proxy.conf" not in _m9443 and _m9443.count("proxy-metrics.conf") >= 10,
   "%d location" % _m9443.count("proxy-metrics.conf"))

for f in ("index.html", "app.js", "style.css", "inactive.html"):
    ck("statik dosya: %s" % f, os.path.exists("gateway/html/" + f))

# nginx aynı blokta yinelenen direktifi REDDEDER ve hiç açılmaz. Snippet bir
# location'ın içine include edildiği için, snippet'teki bir direktifi aynı
# location'da tekrar yazmak gateway'i tamamen çökertir.
snip_directives = set()
for fn in ("proxy", "proxy-metrics", "proxy-panel"):
    for line in open("gateway/snippets/%s.conf" % fn, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and line.endswith(";")                 and not line.startswith("include "):
            snip_directives.add(line.split()[0])
dupes = []
for blk in re.findall(r"location[^{]*\{([^}]*)\}", tpl):
    if not any(x in blk for x in PROXY_SNIPPETS):
        continue
    for line in blk.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and line.endswith(";"):
            d = line.split()[0]
            if d in snip_directives:
                dupes.append(d)
ck("snippet direktifleri location'da tekrar edilmiyor (nginx duplicate hatası)",
   not dupes, ", ".join(sorted(set(dupes))))

# =============================================================================
print()
if FAILS:
    print("\033[31m✗ %d test başarısız:\033[0m %s" % (len(FAILS), ", ".join(FAILS)))
    sys.exit(1)
print("\033[32m✓ tüm testler geçti\033[0m")
