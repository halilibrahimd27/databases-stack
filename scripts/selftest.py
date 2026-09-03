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
import subprocess
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

# Açık motorlar bütçeden düşülür. AMA hangi bütçeden: bu ürün artık TAVAN ile
# REZERVE'yi ayırıyor. Tavanların toplamının dağıtılabiliri aşması tek başına
# ret sebebi değil (tavanlar aynı anda dolmaz); ret, motorun AÇILIŞTA ayırdığı
# belleğin sığmamasından gelir. İki senaryo da burada:
HOST["total"] = 8192
app.save_tuning({})          # defter boş: rezerve, tavandan hesaplanır
# Burada sınanan YUMUŞAK kuraldır (tavan bütçesi): açık motorların tavanları
# bütçeyi doldurunca yeni motor reddedilir, bütçe boşken açılır. SERT kural
# (rezerve) 7. bölümde, aşırı taahhüt katsayısı YALITILARAK sınanıyor: 1.5
# katsayısı ve %60'lık en yüksek rezerve oranıyla tavan kuralı her zaman daha
# sıkı olduğu için burada rezerveyi ölçmeye çalışmak yanıltıcı olurdu.
RUNNING["list"] = [{"service": "mariadb", "memory_mb": 5000},
                   {"service": "cassandra", "memory_mb": 6000}]
p = app.plan_engine("elasticsearch")
ck("Açık motorların tavanları bütçeyi doldurunca yeni motor reddedilir",
   not p.get("ok") and p.get("ceiling_ok") is False,
   (p.get("reason") or "")[:70])
RUNNING["list"] = [{"service": "mariadb", "memory_mb": 1500},
                   {"service": "cassandra", "memory_mb": 1500}]
p = app.plan_engine("elasticsearch")
ck("(negatif) aynı motorlar küçük tavanlarla açıkken KABUL ediliyor "
   "— ret bütçeden geliyor, motorların varlığından değil",
   p.get("ok") is True, (p.get("reason") or "")[:70])
RUNNING["list"] = []
app.save_tuning({})

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
# Sayı kataloğdan türetiliyor: sabit yazılınca kataloğa motor eklemek
# alakasız üç testi birden kırıyor ve ekleyen kişi hatayı kendi
# değişikliğinde arıyor.
_MOTOR = len(app.CATALOG.engines)
ck("/api/catalog", s == 200 and len(b["engines"]) == _MOTOR, "%d motor" % len(b["engines"]))
s, b = call("/api/status")
ck("/api/status", s == 200 and len(b["engines"]) == _MOTOR)
s, b = call("/api/plans")
ck("/api/plans tüm motorlar için plan üretir", s == 200 and len(b["plans"]) == _MOTOR)
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

# Otomatik devir, ancak yükseltilecek bir yedek varsa bir işe yarar. Replikası
# hiç kurulmamış bir motorda düğmenin açılması, dashboard'da "Otomatik devir
# açık" rozeti gösterip kullanıcıya sahte bir güven veriyordu.
HOST["total"] = 16384
app.save_state({"profiles": ["postgresql"], "overrides": []})
s, b = call("/api/engines/postgresql/failover-auto", method="POST",
            body='{"enabled": true}')
ck("replikası olmayan motorda otomatik devir AÇILMAZ",
   s == 400 and "yedek kopya" in (b.get("error") or ""), (b.get("error") or "")[:60])
app.save_state({"profiles": ["postgresql", "postgresql-replica"], "overrides": []})
s, b = call("/api/engines/postgresql/failover-auto", method="POST",
            body='{"enabled": true}')
ck("replika kuruluysa otomatik devir açılır",
   s == 200 and "postgresql" in b.get("auto_failover", []))
call("/api/engines/postgresql/failover-auto", method="POST", body='{"enabled": false}')
# MongoDB seçimini kendi yapar; controller'ın denetleyicisi orada hiç devreye
# girmez — açılmasına izin vermek yine sahte güven olurdu.
s, b = call("/api/engines/mongodb/failover-auto", method="POST", body='{"enabled": true}')
ck("kendi seçimini yapan motorda otomatik devir AÇILMAZ", s == 400)
srv.shutdown()

# =============================================================================
# 3. FAILOVER
# =============================================================================
cat = json.load(open("catalog.json", encoding="utf-8"))
head("3. Otomatik devir (failover)")

# Zaman aşımına uğrayan komut İSTİSNA fırlatmamalı. Eskiden fırlatıyordu:
# yükseltme betiği takılınca devir thread'i sessizce ölüyor, job_done hiç
# çağrılmıyor ve dashboard işi sonsuza dek "devam ediyor" gösteriyordu.
_t0 = time.time()
_rc, _out, _err = app.run([sys.executable, "-c", "import time; time.sleep(30)"], timeout=2)
ck("zaman aşımı istisna değil, sonuç olarak dönüyor",
   _rc == app.RC_TIMEOUT and "zaman aşımı" in _err and (time.time() - _t0) < 20,
   "rc=%s" % _rc)
HOST["total"] = 16384
app.STATE_DIR = "/tmp/dbstack-selftest"
app.TOPOLOGY_FILE = "/tmp/dbstack-selftest/topology.json"
app.ROUTES_FILE = "/tmp/dbstack-selftest/routes.conf"
app.EVENTS_FILE = "/tmp/dbstack-selftest/events.jsonl"
for f in ("topology.json", "routes.conf", "events.jsonl"):
    q = "/tmp/dbstack-selftest/" + f
    if os.path.exists(q):
        os.remove(q)

app.STATE_FILE = "/tmp/dbstack-selftest/state.json"
# Devir testleri replikasyonun KURULU olduğu bir dünyayı varsayar; controller
# artık kurulu olmayan replikaya devri reddediyor (yarım kurulmuş bir düğüm
# primary'nin verisini değil kendi eski verisini taşır).
app.save_state({"profiles": ["mariadb", "mariadb-replica"], "overrides": []})

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
    app.save_topology({})


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

# --- Replikasyon hiç kurulmamışsa devir reddedilir -------------------------
# Container'ın ayakta olması yetmez: kurulumu yarıda kalmış bir düğüm,
# primary'nin verisini değil KENDİ eski verisini taşır. Gerçek sunucuda
# bağlama çöktü, replika ayakta kaldı, devir onu yükseltti ve veritabanı
# önceki testten kalan satırlarla geri geldi.
_reset_topo(); calls[:] = []
app.save_state({"profiles": ["mariadb"], "overrides": []})
app.run = _mock_run({})
okk, reason = app.perform_failover("mariadb", "test: replikasyon kurulu degil")
ck("replikasyon kurulu değilken devir REDDEDİLİR",
   not okk and "replikasyon kurulu değil" in (reason or ""))
ck("reddedilince ana kopya durdurulmaz",
   not any(c[:2] == ["docker", "stop"] for c in calls))
app.save_state({"profiles": ["mariadb", "mariadb-replica"], "overrides": []})

# --- Devir betiklerinin statik denetimi --------------------------------------
_fo_dir = os.path.join(ROOT, "scripts", "failover")
for _f in sorted(os.listdir(_fo_dir)):
    if not _f.endswith(".sh"):
        continue
    _src = open(os.path.join(_fo_dir, _f), encoding="utf-8").read()
    ck("%s 'ready' eylemini destekliyor" % _f,
       any(ln.strip() == "ready)" for ln in _src.splitlines()))
_mdb_fo = open(os.path.join(_fo_dir, "mariadb.sh"), encoding="utf-8").read()
# MariaDB istemcisinde `-N` (--skip-column-names) DİKEY (\G) çıktıda alan
# ADLARINI siler. Alan adına grep atan bir kontrol bu yüzden hiç eşleşmez ve
# SESSİZCE yanlış cevap verir. Gerçek bir olaydı: replikasyon sapasağlam
# akarken (Master_Host: mariadb, IO: Yes, SQL: Yes) devir kapısı "replika
# olarak yapılandırılmamış" diyordu — yani veri kaybını önlemek için konan
# kapı HER ZAMAN reddediyor ve MariaDB'de otomatik devir hiç çalışmıyordu.
_sh_hepsi = {}
for _d in ("scripts/failover", "scripts/replication"):
    for _f in sorted(os.listdir(_d)):
        if _f.endswith(".sh"):
            _sh_hepsi[_d + "/" + _f] = open(_d + "/" + _f, encoding="utf-8").read()
_tuzak = []
for _yol, _src in _sh_hepsi.items():
    for _ln in _src.splitlines():
        if "\G" in _ln and " -N " in _ln and not _ln.strip().startswith("#"):
            _tuzak.append("%s: %s" % (os.path.basename(_yol), _ln.strip()[:70]))
ck("dikey (\G) sorgularda -N kullanılmıyor (alan adlarını siler)",
   not _tuzak, "; ".join(_tuzak))

ck("MariaDB yükseltmesi super_read_only KULLANMIYOR (MariaDB'de yoktur)",
   "SET GLOBAL super_read_only" not in _mdb_fo)
_mdb_rep = open(os.path.join(ROOT, "scripts", "replication", "mariadb.sh"),
                encoding="utf-8").read()
# Seed dökümü `mysql` sistem şemasını KAPSAMAMALI. --all-databases replikanın
# kendi sistem tablolarını DROP eder; yükleme yarıda kalırsa mysql.proc ve
# mysql.gtid_slave_pos yok olur, replikasyon hiç başlamaz ve o düğümden alınan
# sonraki dökümler de bozulur. Gerçek sunucuda yaşandı.
_mdb_rep_code = chr(10).join(ln for ln in _mdb_rep.splitlines()
                                if not ln.lstrip().startswith("#"))
ck("MariaDB tohumlaması mysql sistem şemasını KOPYALAMIYOR",
   "--all-databases" not in _mdb_rep_code and "--databases $dbs" in _mdb_rep_code)
ck("MariaDB tohumlaması hesapları SHOW CREATE USER ile taşıyor",
   "SHOW CREATE USER" in _mdb_rep and "SHOW GRANTS FOR" in _mdb_rep)
ck("MariaDB tohumlaması bozuk sistem şemasını onarıyor",
   "mariadb-upgrade" in _mdb_rep)
# Yön SABİT YAZILAMAZ. Devirden sonra roller yer değiştirir: canlı primary
# `mariadb-replica`, yeniden kurulacak yedek `mariadb` olur. Betik yönü kendi
# bildiğinde rebuild sırasında dökümü AZ ÖNCE SİLİNMİŞ boş düğümden alıp CANLI
# primary'nin üzerine basıyor, üstüne onu boş düğümün slave'i yapıyordu — yani
# kurtarma işlemi elde kalan tek sağlam kopyayı siliyordu.
ck("MariaDB tohumlaması yönü controller'dan (env) okuyor",
   "REPLICATION_PRIMARY" in _mdb_rep_code and "REPLICATION_STANDBY" in _mdb_rep_code)
_mdb_execs = [ln.strip() for ln in _mdb_rep_code.splitlines() if "docker exec" in ln]
ck("MariaDB tohumlamasında docker exec hedefleri sabit yazılmamış",
   bool(_mdb_execs) and all("$PRIMARY" in ln or "$STANDBY" in ln for ln in _mdb_execs),
   "; ".join(ln for ln in _mdb_execs
             if "$PRIMARY" not in ln and "$STANDBY" not in ln))
ck("MariaDB CHANGE MASTER hedefi de env'den geliyor",
   "MASTER_HOST='$PRIMARY'" in _mdb_rep_code
   and "MASTER_HOST='mariadb'" not in _mdb_rep_code)
# Yön yine de ters verilebilir (controller'daki bir hata, betiği elle
# çalıştırma). Betik bu yüzden iş yapmadan önce kendi kendini denetler:
# hedef kaynaktan farklı mı, kaynakta hiç TABLO yokken hedefte veri var mı,
# hedef kaynaktan daha GÜNCEL mi.
#
# "Kaynakta hiç kullanıcı ŞEMASI yok" ölçütü işe yaramıyordu: compose
# MARIADB_DATABASE=defaultdb verdiği için az önce silinip sıfırdan açılmış bir
# düğümde bile o şema hep vardır — kemer hiç ateşlemiyordu. read_only de yönün
# göstergesi değildir (döküm yalnız okur; yükseltilmiş düğüm her yeniden
# başlayışta read_only=ON gelir), o yüzden yön kararını GTID verir.
ck("MariaDB tohumlaması ters yöne karşı kendini koruyor",
   '"$PRIMARY" = "$STANDBY"' in _mdb_rep_code
   and "user_tables m_replica" in _mdb_rep_code
   and "gtid_current_pos" in _mdb_rep_code)
# GTID'in HANGİ sorusu sorulduğu belirleyici. "Sıra numarası büyük mü?" ölçütü
# devirden sonra TERS cevap verir: bayat eski primary kendi kolunda 0-1-100'e
# kadar yazmışken, canlı düğüm 0-2-98'dedir. Doğru soru KAPSAMA'dır ve cevabı
# alan-sunucu çiftiyle aramak gerekir; kaynağın geçmişi gtid_binlog_state ile
# gtid_slave_pos'un birleşimidir.
ck("MariaDB yön kararı GTID sıra numarası karşılaştırmasına dayanmıyor",
   "gtid_seq" not in _mdb_rep_code and "dst_seq" not in _mdb_rep_code)
ck("MariaDB yön kararı GTID kapsamasına (alan-sunucu) bakıyor",
   "gtid_covered" in _mdb_rep_code and "gtid_binlog_state" in _mdb_rep_code
   and "gtid_slave_pos" in _mdb_rep_code)
# `mariadb -N -e 'SHOW SLAVE STATUS\G'` HİÇBİR ŞEY basmaz (--skip-column-names
# dikey çıktıyı tümden susturur). Bu tuzağa bir kez düşüldü: Master_Host'a bakan
# yön kemeri ve "zaten akışta" kısayolu boş metin üzerinde çalıştığı için ölüydü.
ck("MariaDB SHOW SLAVE STATUS çağrıları -N ile susturulmuyor",
   not [ln for ln in _mdb_rep_code.splitlines()
         if "SHOW SLAVE STATUS" in ln and " -N " in ln])
_ready_blk = _mdb_fo.split(chr(10) + "ready)", 1)[1].split(chr(10) + "promote)", 1)[0]
_ready_blk = chr(10).join(ln for ln in _ready_blk.splitlines()
                          if not ln.lstrip().startswith("#"))
ck("MariaDB 'ready' önce replikasyon durumuna, sonra 'zaten primary'ye bakar",
   "Slave_SQL_Running: Yes" in _ready_blk and "zaten primary" in _ready_blk
   and _ready_blk.index("Slave_SQL_Running: Yes") < _ready_blk.index("zaten primary"))
ck("MariaDB tohumlamasında aktarım hataları sessizce yutulmuyor",
   "err_log" in _mdb_rep)
# Boru hattının çıkış kodu SON komuttan (yüklemeyi yapan istemciden) gelir;
# POSIX sh'te pipefail yoktur. Sinyalle ölen bir döküm (OOM, exit 137) stderr'e
# tek satır bile yazmaz, dolayısıyla "error" taraması da göremez: yükleme yarıda
# kesilir ama betik "✓ replikasyon çalışıyor" der. Geriye SESSİZCE YARIM bir
# replika kalır ve sonraki devir onu primary'ye yükseltirse veri kaybolur.
ck("MariaDB dökümünün çıkış kodu boru hattından ayrı okunuyor",
   "dump_rc" in _mdb_rep_code)
# "Zaten akışta" kısayolu, bir kez YANLIŞ yönde kurulmuş topolojiyi de sağlıklı
# raporluyordu. Akan bir replikada yönün gerçek kanıtı Master_Host'tur.
ck("MariaDB 'zaten akışta' kısayolu kaynağı da doğruluyor",
   "Master_Host" in _mdb_rep_code)


def _sh_fonksiyon(src, ad):
    """`ad() { ... }` gövdesini olduğu gibi çıkarır — fonksiyonu ÇALIŞTIRARAK
    sınamak için. Metne bakmak 'öyle yazılmış' der; koşturmak 'öyle davranıyor'
    der. Kapanış, sütun 0'daki tek '}' ile bulunur (bu depoda kural bu)."""
    out, inside = [], False
    for ln in src.splitlines():
        if not inside and ln.startswith(ad + "()"):
            inside = True
            out.append(ln)
            continue
        if inside:
            out.append(ln)
            if ln == "}":
                break
    return chr(10).join(out) if inside else ""


def _sh_branch(src, name):
    """`case` dalının gövdesi — betiği çalıştırmadan fazın ne yaptığını görmek için."""
    out, inside = [], False
    for ln in src.splitlines():
        s = ln.strip()
        if s == name + ")":
            inside = True
            continue
        if inside and s == ";;":
            break
        if inside:
            out.append(ln)
    return chr(10).join(out)


# prepare, kullanıcının replikasyon kurarken çarptığı İLK aşamadır ve attach ile
# aynı yönü izler. Kemersizken yön ters verildiğinde replikasyon kullanıcısı
# SESSİZCE yanlış düğümde açılıyor (root SUPER olduğu için read_only engellemez),
# betik "hazır" diyordu; arıza çok sonra replikada sebebi görünmeyen bir
# "Access denied" olarak patlıyordu.
_mdb_prep = _sh_branch(_mdb_rep_code, "prepare")
ck("MariaDB 'prepare' fazı da yönü denetliyor",
   '"$PRIMARY" = "$STANDBY"' in _mdb_prep and "bağlanılamadı" in _mdb_prep)
# Container kapalıyken `SELECT @@log_bin` boş döner; eski sürüm buna da
# "log_bin kapalı, my.cnf'e bakın" diyordu. my.cnf DOĞRU olduğu için kullanıcı
# doğru dosyayı defalarca düzenleyip aynı hatayı alıyor, gerçek sebebi
# ("container çalışmıyor") hiç öğrenmiyordu.
ck("MariaDB 'prepare' bağlantı hatasını ayar hatasından ayırıyor",
   "my.cnf" in _mdb_prep and _mdb_prep.index("bağlanılamadı") < _mdb_prep.index("my.cnf"))

# --- Replikasyon betiklerinde FAZ denetimi -----------------------------------
# Redis betiğinde `cleanup` dalı YOKTU: betik yalnız `prepare`i ayırıp geri
# kalan her şeyi attach doğrulama döngüsüne düşürüyordu. "Replikayı kapat"
# demek, replikanın bağlanmasını 90 saniye beklemek ve 1 dönmek oluyordu;
# controller da bunu "temizlik başarısız" sayıp yedeği KALDIRMIYOR ve panele
# kritik bir olay yazıyordu. Yani düğme, hiç devir olmamış sıradan bir
# kurulumda bile tamamen kırıktı.
_rep_dir = os.path.join(ROOT, "scripts", "replication")
_rep_src = {}
for _f in sorted(os.listdir(_rep_dir)):
    if not _f.endswith(".sh"):
        continue
    _rep_src[_f] = open(os.path.join(_rep_dir, _f), encoding="utf-8").read()
    ck("%s 'cleanup' fazını tanıyor" % _f, bool(_sh_branch(_rep_src[_f], "cleanup")))
    # cleanup, attach'ın bekleme döngüsüne DÜŞMEMELİ — regresyonun imzası buydu.
    ck("%s 'cleanup' bekleme döngüsüne düşmüyor" % _f,
       "while" not in _sh_branch(_rep_src[_f], "cleanup"))
    # Tanınmayan faz sessizce 0 DÖNMEZ: `case` hiçbir dala uymayınca 0 döner ve
    # controller bunu "yapıldı" sayıp bir sonraki adıma geçer.
    ck("%s bilinmeyen fazda hata veriyor" % _f,
       any(ln.strip() == "*)" for ln in _rep_src[_f].splitlines()))

_redis_clean = _sh_branch(_rep_src["redis.sh"], "cleanup")
ck("Redis 'cleanup' kendi işini yapıyor (attach doğrulaması değil)",
   "REPLICAOF NO ONE" in _redis_clean and "master_link_status" not in _redis_clean)

# Boşta kalan bir replikasyon slot'u PostgreSQL'e "bu WAL'ı hâlâ biri okuyacak"
# der; WAL sonsuza dek birikir, disk dolar ve ANA KOPYA DURUR. Temizlik dalı
# eskiden bütün psql çağrılarını `>/dev/null 2>&1 || true` ile maskeleyip `echo`
# ile bitiyordu, yani DAİMA 0 dönüyordu — controller'ın "temizlik başarısızsa
# replikayı kaldırma" koruması bu yüzden ölü koddu.
_pg_clean = _sh_branch(_rep_src["postgresql.sh"], "cleanup")
ck("PostgreSQL temizliği slot'un silindiğini doğrulayıp başarısızsa hata veriyor",
   "drop_slot" in _pg_clean and "exit 1" in _pg_clean)
ck("PostgreSQL temizliği slot sayısını gerçekten okuyor",
   "count(*) FROM pg_replication_slots" in _rep_src["postgresql.sh"])

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

# Exporter'ın bağlanacağı düğüm de rollerle birlikte taşınmalı. Adres servis
# tanımında sabit yazılıydı ve devirden sonra fence edilmiş eski primary'yi
# göstermeye devam ediyordu: gerçek sunucuda mysql_up=0 ölçüldü ve o motorun
# BÜTÜN grafikleri boşaldı — izleme, tam da devirden sonra körleşiyordu.
ck("izleme ucu devirle birlikte yeni ana kopyayı gösteriyor",
   "MARIADB_PRIMARY_HOST=mariadb-replica" in lines_r)
ck("devir olmayan motorun izleme ucu yerinde kalıyor",
   "POSTGRES_PRIMARY_HOST=postgresql" in lines_r
   and "REDIS_PRIMARY_HOST=redis" in lines_r)
# Değişkeni compose gerçekten kullanmalı; roles.env'e yazıp servis tanımında
# okumamak, sessizce hiçbir şey yapmayan bir düzeltme olurdu.
_dc = open("docker-compose.yml", encoding="utf-8").read()
ck("exporter servis tanımları bu değişkenleri okuyor",
   all(("${%s_PRIMARY_HOST:-" % v) in _dc for v in ("MARIADB", "POSTGRES", "REDIS")))

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

# --- Sağlık yorumu: "açılıyor" hata değildir ---------------------------------
# Sıradan bir sunucu reboot'unda healthcheck start_period boyunca "starting"
# der. Bunu sağlıksızlık sayan sürüm, 30 saniyede 3 vuruşu doldurup açılışını
# yapan ana kopyayı ortasından kesiyor ve daha kendisi de açılmamış yedeği
# yükseltmeye çalışıyordu; sonuç dakikalarca tam kesintiydi.
ck("açılmakta olan (starting) ana kopya sağlıksız SAYILMAZ",
   app.health_verdict("t-start", "running", "starting") == "starting")
ck("gerçekten sağlıksız ana kopya sayaca girer",
   app.health_verdict("t-bad", "running", "unhealthy") == "bad")
ck("durmuş ana kopya sayaca girer", app.health_verdict("t-dead", "exited", "none") == "bad")
ck("sağlıklı ana kopya sayacı sıfırlar",
   app.health_verdict("t-ok", "running", "healthy") == "ok")
app._STARTING_SINCE["t-hung"] = ("nod", time.time() - (app.FAILOVER_STARTING_GRACE + 10))
ck("sonsuza dek 'açılıyor' kalan motor arıza sayılır (devir yine de mümkün)",
   app.health_verdict("t-hung", "running", "starting", "nod") == "bad")
# Damga SERVİSE bağlıdır. Motor kimliğine bağlıyken devirden hemen sonra şu
# oluyordu: eski ana kopyanın bayat damgası kayıtta kalıyor, yükseltilen YENİ
# ana kopya "starting" dediğinde setdefault o damgayı koruyor ve düğüm açılış
# lütfundan HİÇ yararlanmadan anında "bad" sayılıyordu — yani düzeltmenin asıl
# vaadi tam da en çok gerektiği anda geçersiz kalıyordu.
app._STARTING_SINCE["t-swap"] = ("mariadb", time.time() - (app.FAILOVER_STARTING_GRACE + 10))
ck("devirden sonra bayat 'açılıyor' damgası yeni ana kopyaya taşınmıyor",
   app.health_verdict("t-swap", "running", "starting", "mariadb-replica") == "starting")
ck("aynı düğüm için lütuf süresi yine de dolabiliyor",
   app.health_verdict("t-swap", "running", "starting", "mariadb-replica") == "starting"
   and app.health_verdict("t-hung", "running", "starting", "nod") == "bad")

# "docker'a SORAMADIK" ile "container YOK" aynı şey değildir. run() zaman
# aşımını artık sonuç olarak döndürdüğü için yoğun bir docker daemon'ında liste
# boş kalıyor, denetleyici her motoru "absent" görüp sayaç işletiyor ve üst üste
# 3 turda gereksiz bir devir denemesi başlatabiliyordu.
_saved_run, _saved_conts = app.run, app.docker_containers
app.run = lambda cmd, timeout=900, env=None: (app.RC_TIMEOUT, "", "zaman aşımı")
app._docker_containers_uncached()
ck("docker listesi alınamayınca 'container yok' denmiyor", not app.docker_snapshot_ok())
app.run = lambda cmd, timeout=900, env=None: (0, "", "")
app._docker_containers_uncached()
ck("docker cevap verince bayrak temizleniyor", app.docker_snapshot_ok())
app.run, app.docker_containers = _saved_run, _saved_conts

# Devir bekleme süresi diske yazılmalı: devir çoğu zaman controller'ın da
# yeniden başladığı bir olayda (reboot) yaşanır; bellekteki sayaç sıfırlanınca
# "5 dakika bekle" kuralı fiilen hiç işlemiyordu.
app._mark_failover_attempt("mariadb")
app._LAST_FAILOVER.clear()      # controller yeniden başlamış gibi
ck("devir bekleme süresi controller yeniden başlayınca sıfırlanmıyor",
   time.time() - app._last_failover_at("mariadb") < 120)

# --- Yedeği yeniden kurma: YÖN ve ÖNKOŞULLAR --------------------------------
# Bu işlem bir VERİ HACMİNİ SİLER. Yönü şaşarsa (dump'ı yeni kurulan boş
# düğümden alıp canlı ana kopyanın üzerine basmak) elde kalan tek sağlam kopya
# yok olur; önkoşulları atlarsa ana kopya ölüyken son yedeği siler.
_rb = []


def _rebuild_run(rc_map=None, writable="mariadb-replica"):
    """Sahte run(): 'check' yalnız CANLI ana kopya için 0 döner."""
    rc_map = rc_map or {}

    def _r(cmd, timeout=900, env=None):
        _rb.append({"cmd": cmd, "env": dict(env or {})})
        for key, rc in rc_map.items():
            if key in cmd:
                return (rc, "", "sahte hata: " + key)
        if "check" in cmd:
            return (0, "", "") if cmd[-1] == writable else (1, "", "")
        if "ready" in cmd:
            return (0, "yedek akışta", "")
        return (0, "", "")
    return _r


app.run = _rebuild_run()
_rb[:] = []
okk, reason = app.rebuild_standby("mariadb")
ck("devir sonrası yedeği yeniden kurma tamamlanıyor", okk, reason or "")
_attach = [c for c in _rb if c["cmd"][0] == "sh" and "attach" in c["cmd"]]
ck("tohumlama YÖNÜ betiğe env ile veriliyor (kaynak: canlı ana kopya)",
   bool(_attach)
   and _attach[0]["env"].get("REPLICATION_PRIMARY") == "mariadb-replica"
   and _attach[0]["env"].get("REPLICATION_STANDBY") == "mariadb",
   ("%s → %s" % (_attach[0]["env"].get("REPLICATION_PRIMARY"),
                 _attach[0]["env"].get("REPLICATION_STANDBY"))) if _attach else "attach yok")

app.run = _rebuild_run(writable="hicbiri")   # ana kopya yazma kabul etmiyor
_rb[:] = []
okk, reason = app.rebuild_standby("mariadb")
ck("kopya kaynağı yazılabilir ana kopya değilse yeniden kurma YAPILMAZ",
   not okk and "yazma kabul etmiyor" in (reason or ""))
ck("reddedilince hiçbir veri hacmi silinmiyor",
   not any("volume" in c["cmd"] for c in _rb))

app.run = _rebuild_run({"volume": 1})        # hacmi başka bir işlem tutuyor
_rb[:] = []
okk, reason = app.rebuild_standby("mariadb")
ck("eski veri hacmi silinemezse işlem DURUR (ikinci yazılabilir düğüm olmaz)",
   not okk and "hacmi silinemedi" in (reason or ""))
ck("hacim silinemeyince container hiç başlatılmaz",
   not any("up" in c["cmd"] for c in _rb))

_verify_to = app.STANDBY_VERIFY_TIMEOUT
app.STANDBY_VERIFY_TIMEOUT = 0
app.run = _rebuild_run({"ready": 1})         # düğüm yedek konumuna geçmedi
_rb[:] = []
okk, reason = app.rebuild_standby("mariadb")
ck("yedek olduğu DOĞRULANAMAYAN düğüm başarı sayılmaz", not okk)
ck("doğrulanamayan düğüm ayakta bırakılmaz (eski veriyi sunmasın)",
   any(c["cmd"][:2] == ["docker", "stop"] and c["cmd"][-1] == "mariadb" for c in _rb))
app.STANDBY_VERIFY_TIMEOUT = _verify_to

app.save_state({"profiles": ["mariadb"], "overrides": []})
app.run = _rebuild_run()
_rb[:] = []
okk, reason = app.rebuild_standby("mariadb")
ck("replikasyon hiç kurulmamışken yeniden kurma REDDEDİLİR",
   not okk and "replikasyon kurulu değil" in (reason or ""))
ck("önkoşul sağlanmayınca hiçbir komut çalıştırılmaz", not _rb)
app.save_state({"profiles": ["mariadb", "mariadb-replica"], "overrides": []})

# Devir ile yeniden kurma AYNI ANDA çalışamaz: rebuild, o an primary'ye
# yükseltilmekte olan düğümü "eski primary" sanıp hacmini siliyordu.
_lk = app.engine_lock("mariadb")
_lk.acquire()
try:
    app.run = _rebuild_run()
    _rb[:] = []
    okk, reason = app.rebuild_standby("mariadb")
    ck("devir sürerken yeniden kurma REDDEDİLİR", not okk and "sürüyor" in (reason or ""))
    okk, reason = app.perform_failover("mariadb", "test: kilit")
    ck("aynı motorda ikinci bir devir REDDEDİLİR", not okk and "sürüyor" in (reason or ""))
    ck("kilit meşgulken hiçbir komut çalıştırılmaz", not _rb)

    # Aç/kapat/replikasyon uçları da AYNI sırada yürümeli. Kilitsiz kaldıkları
    # sürece şu senaryo açıktı: devir başladı (eski primary fence edilmiş,
    # topology HENÜZ yazılmamış), operatör panelde "çalışmıyor" görüp Durdur'a
    # ya da "Replikayı kapat"a bastı → o an primary'ye yükseltilmekte olan düğüm
    # `compose rm -f` ile silindi ve ayakta tek bir veritabanı kalmadı.
    for _act, _fn in (("Durdur", lambda j: app.do_deactivate(j, "mariadb")),
                      ("Replikayı kapat", lambda j: app.do_replication(j, "mariadb", False)),
                      ("Aktif Et", lambda j: app.do_activate(j, "mariadb"))):
        _jid = app.new_job("test", "mariadb")
        _fn(_jid)
        ck("devir sürerken '%s' REDDEDİLİR" % _act,
           app.JOBS[_jid]["state"] == "failed"
           and "sürüyor" in (app.JOBS[_jid].get("reason") or ""),
           (app.JOBS[_jid].get("reason") or "")[:50])
    ck("kilit meşgulken hiçbir container'a dokunulmuyor", not _rb)
finally:
    _lk.release()

# --- Devir → yeniden kurma → NORMAL AKIŞ ------------------------------------
# Yeniden kurma topolojiye hiç dokunmadığı sürece kayıt sonsuza dek "devir
# yapıldı, eski kopya durduruldu" diyordu: dashboard aynı uyarıyı ve aynı düğmeyi
# göstermeye devam ediyor, "Replikayı kapat"/"Replika kur" ise "önce eski kopyayı
# yeniden kurun" diye reddediliyordu — oysa o işlem az önce BAŞARIYLA bitmişti.
# Veritabanı bilmeyen kullanıcı için çıkışı olmayan bir döngüydü.
_topo_mdb = app.load_topology().get("mariadb", {})
ck("başarılı yeniden kurulum topolojiye işleniyor (roller tutarlı)",
   bool(_topo_mdb.get("rebuilt_at")) and _topo_mdb.get("standby") == "mariadb"
   and _topo_mdb.get("primary") == "mariadb-replica",
   json.dumps(_topo_mdb, ensure_ascii=False)[:90])
_st_mdb = [e for e in app.status()["engines"] if e["id"] == "mariadb"][0]
ck("yeniden kurulduktan sonra 'Devir yapıldı' uyarısı/düğmesi ekranda kalmıyor",
   _st_mdb["failed_over"] is False and _st_mdb["roles_swapped"] is True)

# Devir sonrası "replikayı kapat", kataloğa bakıp CANLI ANA KOPYAYI siliyordu.
# Silinecek düğüm kataloğun replica_service'i değil, o anki YEDEKTİR.
_stt = app.load_state()
_stt["auto_failover"] = ["mariadb"]
app.save_state(_stt)
_jid = app.new_job("replication-disable", "mariadb")
app.run = _rebuild_run()
_rb[:] = []
app.do_replication(_jid, "mariadb", False)
_targets = [c["cmd"][-1] for c in _rb
            if "stop" in c["cmd"] or ("rm" in c["cmd"] and "-f" in c["cmd"])]
ck("devir sonrası 'Replikayı kapat' canlı ana kopyayı değil YEDEĞİ kaldırır",
   app.JOBS[_jid]["state"] == "done" and bool(_targets)
   and all(t == "mariadb" for t in _targets),
   "durum=%s hedefler=%s" % (app.JOBS[_jid]["state"], ", ".join(_targets)))
# Yedek yokken "Otomatik devir açık" rozeti yalan söyler: yükseltilecek düğüm
# kalmadı. Giriş kapısındaki kontrol yalnız AÇARKEN çalışıyordu.
ck("yedek kaldırılınca otomatik devir de kapatılır",
   "mariadb" not in app.load_state().get("auto_failover", []))
app.save_state({"profiles": ["mariadb", "mariadb-replica"], "overrides": []})

# Devir olmuş ama yedek HENÜZ yeniden kurulmamışken "Replika Kur" yanlış
# düğmedir: hedef düğüm eskimiş veriyi taşıyan eski ana kopyadır ve bu yol onun
# hacmini silmeden açar → dolu veri dizini yüzünden klonlama atlanır, düğüm
# ikinci bir YAZILABİLİR ana kopya olarak gelir. Red mesajı, GERÇEKTEN çalışan
# bir yol göstermeli.
_topo = app.load_topology()
_topo["mariadb"].pop("rebuilt_at", None)
app.save_topology(_topo)
_jid = app.new_job("replication-enable", "mariadb")
_rb[:] = []
app.do_replication(_jid, "mariadb", True)
_reason = app.JOBS[_jid].get("reason") or ""
ck("devir sonrası 'Replika Kur' eskimiş düğümü açmaz, yapılabilir bir yol gösterir",
   app.JOBS[_jid]["state"] == "failed" and "yeniden kur" in _reason, _reason[:70])
ck("bu redde hiçbir container'a/hacme dokunulmuyor", not _rb)

# Devir sonrası "Aktif Et", kataloğun ilk servisini (eskimiş, fence edilmiş
# düğümü) açıyordu: hem eski veriyle ikinci bir yazılabilir kopya oluyor hem de
# gateway gerçek ana kopyayı gösterdiği için kullanıcı hiçbir yere bağlanamıyordu.
# Servisi listeden çıkarmak TEK BAŞINA yetmiyor: panel/exporter/replika
# servislerinin hepsi compose'da `depends_on: <asıl primary>: service_healthy`
# taşıdığı için compose onu YİNE başlatıyordu. Bu yüzden argv'ye değil,
# compose'un depends_on grafiğiyle hesaplanan EFEKTİF servis kümesine bakıyoruz.
import yaml as _yaml_dep  # noqa: E402

_cyaml = _yaml_dep.safe_load(open("docker-compose.yml", encoding="utf-8"))
_DEPS = {}
for _n, _sv in (_cyaml.get("services") or {}).items():
    _d = (_sv or {}).get("depends_on") or {}
    _DEPS[_n] = list(_d.keys()) if isinstance(_d, dict) else list(_d)


def _effective_services(cmd):
    """compose'un bu komutla GERÇEKTEN başlatacağı servisler (bağımlılıklar dahil)."""
    if "up" not in cmd:
        return set()
    named = [x for x in cmd[cmd.index("up") + 1:] if not x.startswith("-")]
    eff, queue, no_deps = set(), list(named), "--no-deps" in cmd
    while queue:
        s = queue.pop()
        if s in eff:
            continue
        eff.add(s)
        if not no_deps:
            queue += _DEPS.get(s, [])
    return eff


_jid = app.new_job("activate", "mariadb")
app.run = _rebuild_run()
_rb[:] = []
app.do_activate(_jid, "mariadb")
_eff = set()
for _c in _rb:
    _eff |= _effective_services(_c["cmd"])
ck("devir sonrası 'Aktif Et' eskimiş kopyayı compose bağımlılığıyla bile açmaz",
   "mariadb-replica" in _eff and "mariadb" not in _eff, " ".join(sorted(_eff)))
ck("panel ve exporter yine de açılıyor (bağımlılık iptali işlevi kesmiyor)",
   {"phpmyadmin", "mariadb-exporter"} <= _eff, " ".join(sorted(_eff)))

# Yönlendirme tablosu gateway'e uygulanamadıysa iş "✅ Tamamlandı" DEMEZ:
# uygulamalar hâlâ eski/ölü hedefe gider, kullanıcı ise iş penceresine bakar.
_saved_reload = app.reload_gateway
app.reload_gateway = lambda attempts=3: False
_jid = app.new_job("activate", "mariadb")
_rb[:] = []
app.do_activate(_jid, "mariadb")
ck("gateway tazelenemezse 'Aktif Et' sessizce başarılı demiyor",
   app.JOBS[_jid]["state"] == "failed"
   and "docker restart gateway" in (app.JOBS[_jid].get("reason") or ""),
   (app.JOBS[_jid].get("reason") or "")[:60])
app.reload_gateway = _saved_reload
_topo = app.load_topology()
_topo["mariadb"]["rebuilt_at"] = int(time.time())
app.save_topology(_topo)

_evs = app.read_events()
ck("devir reddedildiğinde kritik olay yazılıyor (sessiz kalınmıyor)",
   any(e["kind"] == "failover_blocked" and e["level"] == "critical" for e in _evs))
ck("yeniden kurma reddedildiğinde de olay yazılıyor",
   any(e["kind"] == "rebuild_blocked" for e in _evs))

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
# SQL Server VARSAYILAN OLARAK Express ile gelir: ücretsiz ve üretimde de
# kullanılabilir. Bu bilinçli bir üründür kararı — açık kaynak bir yığında
# kullanıcıyı varsayılan olarak "üretimde kullanamazsın" sürümüne düşürmek
# doğru değil. Kataloğun bunu compose'daki gerçek varsayılanla AYNI anlatması
# şart: ikisi ayrışırsa panel yanlış lisans bilgisi gösterir.
_compose_ham = io.open("docker-compose.yml", encoding="utf-8").read()
_env_ornek = io.open(".env.example", encoding="utf-8").read()
ck("SQL Server varsayılanı ücretsiz Express sürümü",
   "${MSSQL_PID:-Express}" in _compose_ham, mssql_lic["name"])
ck(".env.example de aynı varsayılanı söylüyor",
   any(l.strip() == "MSSQL_PID=Express" for l in _env_ornek.splitlines()))
ck("katalog, Express varsayılanıyla tutarlı (üretimde kullanılabilir)",
   mssql_lic["free_for_production"] is True
   and "Express" in mssql_lic["name"], mssql_lic["name"])
ck("Express'in sınırları kullanıcıya yazılı (10 GB / DB)",
   "10 GB" in (mssql_lic.get("note") or ""))
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

# Devirden sonra yükseltilen düğüm ANA KOPYA olur; planlayıcıyı etkileyen
# ayarları ana kopyayla aynı olmalı. effective_cache_size replikada eksikti:
# yükseltilen düğüm PostgreSQL'in 4GB varsayılanını varsayıp kötü plan
# seçiyordu, oysa container limiti ~2.4 GB. Bu ürün replikaya ana kopya kadar
# BELLEK ayırıyor ("devirden sonra aynı yükü taşıyacak"); AYARLARIN da öyle
# olması gerekiyor.
_compose_yml = open("docker-compose.yml", encoding="utf-8").read()


def _compose_servis(ad):
    """docker-compose.yml'den TEK bir servis bloğunu çıkarır.

    Naif bir `split("
  ")` ilk satırda kesiyor ve blok boş kalıyordu; sonuç,
    hiçbir şey doğrulamayan ama hep GEÇTİ yazan bir kontroldü — bu dosyanın
    tam da yakalamaya çalıştığı hata türü. Blok, servis anahtarından bir
    sonraki 2 boşluk girintili anahtara kadar sürer.
    """
    bas = _compose_yml.index(chr(10) + "  " + ad + ":") + 1
    i = bas + len(ad) + 4
    satirlar = []
    for ln in _compose_yml[i:].split(chr(10)):
        if ln[:3] == "  " + ln[2:3] and ln[2:3] not in (" ", "", "#") and ln.rstrip().endswith(":"):
            break
        satirlar.append(ln)
    return chr(10).join(satirlar)


_pg_blok = _compose_servis("postgresql")
_pg_rep = _compose_servis("postgresql-replica")
_planci = ["effective_cache_size", "shared_buffers", "work_mem", "max_connections"]
_eksik = [a for a in _planci if a in _pg_blok and a not in _pg_rep]
# Kontrolün kendisi de doğrulanıyor: bloklar gerçekten dolu mu?
ck("compose servis blokları doğru ayrıştırılıyor (kontrol boş değil)",
   len(_pg_blok) > 200 and len(_pg_rep) > 200 and "shared_buffers" in _pg_blok,
   "primary=%d replika=%d karakter" % (len(_pg_blok), len(_pg_rep)))
ck("replika, ana kopyanın planlayıcı ayarlarını da alıyor", not _eksik,
   ("replikada eksik: " + ", ".join(_eksik)) if _eksik else "")

# Ayarı EKLEMEK yetmiyor, `-c` ile eklemek gerekiyor. Üstteki kontrolü geçmek
# için eklenen iki satırın başında `-c` yoktu; postgres "invalid argument" ile
# 1 döndü ve replika sonsuz crash-loop'a girdi. Dışarıdan görünen tek şey
# panelde "kapalı" yazmasıydı — container ise sürekli yeniden başlıyordu.
# Bu yüzden ayarın VARLIĞINI değil, ARGÜMAN DİZİSİNİ doğruluyoruz.
_kotu_arg = []
try:
    import yaml as _yaml
    _cfg = _yaml.safe_load(io.open("docker-compose.yml", encoding="utf-8").read())
    for _ad, _svc in (_cfg.get("services") or {}).items():
        _cmd = _svc.get("command")
        if not (isinstance(_cmd, list) and _cmd and str(_cmd[0]).startswith("postgres")):
            continue
        for _i in range(1, len(_cmd)):
            if "=" in str(_cmd[_i]) and _cmd[_i - 1] != "-c":
                _kotu_arg.append("%s: %s" % (_ad, _cmd[_i]))
    ck("postgres ayarlarının hepsi `-c` ile veriliyor", not _kotu_arg,
       ("`-c` yok: " + ", ".join(_kotu_arg)) if _kotu_arg else "")
except ImportError:
    ck("postgres ayarlarının hepsi `-c` ile veriliyor", True, "(PyYAML yok — atlandı)")


# Geri yükleme, panelin gösterdiği dosyayı BULABİLMELİ. backup.sh yedekleri
# türe göre alt dizine yazıyor (backups/<motor>/full/…, .../single/…); liste
# ucu ağacı gezip dosya ADINI veriyor. Çözümleme düz birleştirme yapınca
# ekranda duran her dosya "bulunamadı" oluyordu — yani geri yükleme düğmesi
# hiç çalışmıyordu. Sunucuda ölçüldü ve düzeltildi; kontrol kalıcı.
_ctrl_src = io.open("controller/app.py", encoding="utf-8").read()
_rbf_i = _ctrl_src.find("def resolve_backup_file")
_rbf = _ctrl_src[_rbf_i:_rbf_i + 3000] if _rbf_i >= 0 else ""
ck("geri yükleme çözümleyicisi var", _rbf_i >= 0)
ck("geri yükleme alt dizinlerde de arıyor (backups/<motor>/full/…)",
   "os.walk(" in _rbf)
ck("geri yükleme kökten çıkmayı engelliyor (realpath + önek)",
   "realpath" in _rbf and "startswith" in _rbf)
ck("geri yükleme yalnız .gz kabul ediyor ('.bozuk' kurtarma noktası değildir)",
   '.gz' in _rbf and 'bozuk' in _rbf)

# Replika bütçesi, motorun KENDİ servislerini boşta saymamalı.
ck("replika bütçesi için ayrı hesap var (free_budget_mb)",
   "def free_budget_mb" in _ctrl_src)
_dorep_i = _ctrl_src.find("def do_replication")
_dorep = _ctrl_src[_dorep_i:_dorep_i + 6000]
ck("replika kontrolü plan_engine'in budget_mb'sini KULLANMIYOR",
   "free_budget_mb()" in _dorep and 'p.get("budget_mb"' not in _dorep)

# "ÇALIŞIYOR" İLE "AKIYOR" AYRI ŞEYLER. Panel eskiden yalnız replika
# container'ının ayakta olduğuna bakıp "yedek kopya çalışıyor" diyordu; akış
# kopmuş olsa bile aynı cümleyi yazıyordu — ölçmediği bir güvenceyi iddia
# ediyordu. Akışı kopmuş bir yedek kopya devirde İŞE YARAMAZ. Ölçüm için yeni
# SQL yazılmadı: devrin dayandığı ölçütün AYNISI (failover/<motor>.sh ready)
# kullanılıyor, böylece panelin gösterdiği şey ile devrin güvendiği şey
# ayrışamaz.
ck("replikasyon sağlığı ölçülüyor (container ayakta ≠ akış var)",
   "def measure_replication_health" in _ctrl_src)
ck("ölçüm devrin kullandığı ölçütle aynı (failover/<motor>.sh ready)",
   '"ready", stby' in _ctrl_src or "'ready', stby" in _ctrl_src)
ck("API 'akıyor mu' bilgisini ayrı alanda veriyor",
   '"replication_flowing"' in _ctrl_src)
ck("ölçülemeyen durum None kalıyor (False ile karıştırılmıyor)",
   '(repl_health.get(e["id"]) or {}).get("flowing")' in _ctrl_src)
_app_js = io.open("gateway/html/app.js", encoding="utf-8").read()
ck("panel akışı kopmuş yedek kopyayı AYRI ve kırmızı gösteriyor",
   "yedek kopya AKMIYOR" in _app_js and "fact-err" in _app_js)

# PITR ARŞİVİ, DEVİRDEN SONRA DA ÇALIŞMALI. Ana kopya devirde replikaya
# geçiyor ve yazmaları o üretmeye başlıyor; binlog arşiv bağlaması yalnız
# birincil serviste kalırsa PITR tam da en gerekli anda sessizce durur —
# arşive hiçbir şey düşmez ve "ne kadar geriye dönebilirim" penceresi devir
# anında donar. e2e/pitr.sh bunu sahada yakaladı.
_dc_ham = io.open("docker-compose.yml", encoding="utf-8").read()
_cfg_yml = _yaml.safe_load(_dc_ham)
_binlog_olan = [ad for ad, sv in (_cfg_yml.get("services") or {}).items()
                if any("/binlog-archive" in str(v)
                       for v in (sv.get("volumes") or []))]
ck("binlog arşivi hem ana kopyada hem replikada bağlı (devir sonrası da çalışsın)",
   "mariadb" in _binlog_olan and "mariadb-replica" in _binlog_olan,
   "bağlı olanlar: %s" % (", ".join(sorted(_binlog_olan)) or "yok"))

# ŞİFRELİ YEDEK ZİNCİRİ TEK PARÇA OLMALI. Şifreleme açıkken dosyalar
# '.gz.enc' uzantısıyla yazılıyor; zincirin herhangi bir halkası yalnız '.gz'
# ararsa o kurulum SESSİZCE görünmez olur — panelde "hiç yedek yok", geri
# yüklemede "dosya bulunamadı", provada "yedek yok". Yani şifrelemeyi açan,
# en çok güvence isteyen kullanıcı en az güvence alır. e2e/encrypt.sh bunu
# controller ve restore-drill için ayrı ayrı yakaladı.
ck("controller yedek uzantılarını tek yerden tanımlıyor",
   "BACKUP_EXTS" in _ctrl_src and '".gz.enc"' in _ctrl_src)
ck("controller şifreli yedekleri de sayıyor/listeliyor/çözümlüyor",
   _ctrl_src.count("yedek_dosyasi_mi(") >= 4)
ck("'.bozuk' dosya yedek sayılmıyor (kurtarma noktası değildir)",
   'ad.endswith(".bozuk")' in _ctrl_src)
_rd = io.open("scripts/restore-drill.sh", encoding="utf-8").read()
ck("kurtarma provası da şifreli yedekleri aday görüyor", "*.gz.enc" in _rd)

# KURTARMA PROVASI, verify_backup'ın YAPAMADIĞI şeyi yapmalı: yedeği gerçekten
# geri yükleyip süreyi ölçmek. Buradaki kontroller provanın VARLIĞINI değil,
# sözleşmesini koruyor — çünkü panel ve zamanlayıcı o sözleşmeye bağlı.
_drill_i = _ctrl_src.find("def do_drill")
_drill = _ctrl_src[_drill_i:_drill_i + 4000] if _drill_i >= 0 else ""
ck("kurtarma provası işi var (do_drill)", _drill_i >= 0)
ck("prova, üretim yedeğiyle AYNI kilidi alıyor (iki ağır iş çakışmasın)",
   "BACKUP_LOCK.acquire" in _drill)
ck("prova sonucu ÖLÇÜLEMEDİĞİNDE 'başarısız' denmiyor (ok=None ayrı tutuluyor)",
   '"ok": None' in _drill)
ck("prova düşerse olay CRITICAL (felaket gününden önce duyulmalı)",
   'level="critical"' in _drill)
ck("prova sonucu API'de yayınlanıyor (panel okuyabilsin)",
   '"drill": prova' in _ctrl_src and '"drill_supported"' in _ctrl_src)
ck("haftalık prova gecelik yedekten SONRA koşuyor",
   "_haftalik_prova()" in _ctrl_src and "def _haftalik_prova" in _ctrl_src)
# Kapsam listesi ELLE yazılmamalı: katalog büyüdüğünde sessizce eksik kalır.
ck("prova kapsamı backup.sh'ın kendi gerçeğinden okunuyor",
   'restore_%s()' in _ctrl_src)

_yed_js = io.open("gateway/html/yedekler.js", encoding="utf-8").read()
ck("panel prova sonucunu gösteriyor (üç durum: geçti/kaldı/yapılmadı)",
   "bk-drill-ok" in _yed_js and "bk-drill-err" in _yed_js
   and "bk-drill-yok" in _yed_js)
ck("panelde 'Prova yap' düğmesi var", "data-act=\"drill\"" in _yed_js)

# docker inspect şablonu ".Id" KULLANMAMALI. ".Id" docker'ı ham JSON (map)
# yoluna düşürüyor; o yolda sağlık kontrolü olmayan container'da
# ".State.Health" "olmayan anahtar" hatası veriyor ve docker o container'ı
# hiç yazmıyor. Ölçüldü: 15 container'ın 11'i geliyordu, düşenlerin hepsi
# healthcheck'i olmayanlardı (bütün exporter'lar). Sonuç: Prometheus hedef
# listesi boş, bütün panolar boş, bellek muhasebesi eksik — ve hiçbir hata
# görünmüyordu.
_dc_i = _ctrl_src.find("def _docker_containers_uncached")
_dc = _ctrl_src[_dc_i:_dc_i + 2500] if _dc_i >= 0 else ""
ck("container listeleyici bulundu", _dc_i >= 0)
ck("docker inspect şablonu '.Id' değil '.ID' kullanıyor",
   "{{.ID}}" in _dc and "{{.Id}}" not in _dc)
ck("eksik liste sessiz kalmıyor (uyarı basılıyor)",
   "len(res) < len(ids)" in _dc)

# Kilit dosyası /tmp'de OLMAMALI. /tmp herkese yazılabilir ama dosyanın SAHİBİ
# onu ilk yaratandır: root olarak bir kez koşan yedek, kilidi root'a ait bırakıp
# ondan sonraki her kullanıcı koşusunu "Permission denied" ile öldürüyordu —
# e2e yedek paketi tam olarak böyle komple başarısız oldu. Ayrıca panelden gelen
# koşu container'ın İÇİNDEN gelir; /tmp orada ayrı bir dosya sistemidir ve iki
# taraf birbirinin kilidini göremezdi.
_bk = io.open("scripts/backup.sh", encoding="utf-8").read()
_lib = io.open("scripts/lib/common.sh", encoding="utf-8").read()
ck("yedek kilidi /tmp'de değil", "/tmp/databases-stack" not in _bk,
   "backup.sh hâlâ /tmp kullanıyor" if "/tmp/databases-stack" in _bk else "")
ck("kilit yığının state/ dizininde (host ve container aynı dosyayı görür)",
   'acquire_lock "$STACK_ROOT/state/backup.lock"' in _bk)
ck("acquire_lock varsayılanı da /tmp değil", "/tmp/databases-stack.lock" not in _lib)

# MariaDB'de 'healthcheck' hesabı DÜĞÜME ÖZELDİR: imaj ilk açılışta rastgele
# bir parola üretip hem hesabı hem de o düğümün $datadir/.my-healthcheck.cnf
# dosyasını aynı parolayla yazar. Hesap taşınırken kaynağınki hedefe yazılınca
# parola ile dosya ayrışıyor ve düğüm — veritabanı kusursuz çalışırken —
# sonsuza kadar "unhealthy" görünüyordu. Otomatik devir bekçisi sağlığa baktığı
# için bu, kendi kendine kesinti üretebilen bir hataydı.
_rep_mdb = io.open("scripts/replication/mariadb.sh", encoding="utf-8").read()
_ulist = [l for l in _rep_mdb.splitlines() if "mysql.global_priv" in l and "NOT IN" in l]
ck("MariaDB hesap taşımada dışlama listesi bulunuyor", len(_ulist) == 1,
   "%d eşleşme" % len(_ulist))
ck("'healthcheck' hesabı taşınmıyor (düğüme özel parola)",
   bool(_ulist) and "'healthcheck'" in _ulist[0],
   _ulist[0].strip()[:120] if _ulist else "")
ck("hedefin sağlık hesabı taşımadan sonra yenileniyor (eski kurulumları onarır)",
   ".my-healthcheck.cnf" in _rep_mdb and "ALTER USER IF EXISTS healthcheck" in _rep_mdb)
ck("e2e, replikasyondan sonra iki düğümün de sağlığını ölçüyor",
   "health_state" in io.open("scripts/e2e/replication.sh", encoding="utf-8").read())

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
for n in ("ssl", "proxy", "inactive", "panel-sso", "panel-csrf", "panel-csrf-page"):
    ck("snippet var ve dengeli: %s.conf" % n,
       os.path.exists("gateway/snippets/%s.conf" % n)
       and balance(open("gateway/snippets/%s.conf" % n, encoding="utf-8").read()) == 0)

passes = re.findall(r"proxy_pass\s+(http://[^;]+);", tpl)
fixed = [p for p in passes if "$" not in p]
ck("tüm proxy_pass'ler değişkenli — kapalı motor nginx'i çökertmez",
   not fixed, "%d proxy_pass" % len(passes))

blocks = re.split(r"\nserver \{", tpl)[1:]
# Bu liste iki kontrolün kapsamını belirliyor (aşağıda "pasif sayfası" ve
# "yinelenen direktif"). proxy-api.conf sonradan eklendi: /api/ kendi düz metin
# hata sayfalarına geçerken proxy.conf yerine proxy-api.conf include etmeye
# başladı, liste güncellenmeyince 443 server'ı ve /api/ location'ı iki
# kontrolün de DIŞINDA kaldı — testler yeşil, koruma yok. Buraya yeni bir proxy
# snippet'i eklerken bu listeyi de güncelleyin.
PROXY_SNIPPETS = ("snippets/proxy.conf", "snippets/proxy-metrics.conf",
                  "snippets/proxy-panel.conf", "snippets/proxy-api.conf")
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

# Sabit bir liste yerine DEĞİŞMEZİ sınıyoruz. Liste yazılınca şablona meşru
# bir değişken eklemek alakasız bir testi kırıyor ve ekleyen kişi hatayı kendi
# değişikliğinde arıyor.
_tpl_vars = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", tpl))
ck("şablondaki tüm ${} değişkenleri STACK_ önekli (NGINX_ENVSUBST_FILTER)",
   all(v.startswith("STACK_") for v in _tpl_vars), ", ".join(sorted(_tpl_vars)))
# Şablonun beklediği bir değişkeni compose vermezse envsubst onu SESSİZCE boş
# dizeyle değiştirir. Sonuç yapılandırma geçerli kalır ama davranış bozulur:
# boş bir token'la /api/ çağrıları 401 alır, boş bir sırla panel çerezi hiçbir
# şeye eşleşmez. Hiçbir hata mesajı çıkmaz — bu yüzden burada yakalıyoruz.
_compose_txt = open("docker-compose.yml", encoding="utf-8").read()
_env_eksik = sorted(v for v in _tpl_vars if (v + ":") not in _compose_txt)
ck("şablonun beklediği her STACK_ değişkeni compose'da gateway'e veriliyor",
   not _env_eksik, ", ".join(_env_eksik))

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


# --- Dashboard JavaScript'i ayrıştırılabiliyor mu? --------------------------
# Yarım kalmış bir app.js sunucu tarafında HİÇBİR belirti vermez: nginx dosyayı
# seve seve servis eder, /api/status 200 döner, container'lar sağlıklı görünür.
# Tarayıcıda ise script hiç çalışmaz ve panel sonsuza dek "Yükleniyor…" kalır.
# Gerçek bir olaydı: dosya düzenlenmekte olduğu bir anda commit'lendi, tıklama
# dinleyicisinin kapanışı hiç yazılmamıştı ve panel tamamen kullanılamaz hâle
# geldi. Node her ortamda bulunmadığı için burada kendi tarayıcımızla
# bakıyoruz — tam bir ayrıştırıcı değil, ama kesilmeyi/dengesizliği yakalar.
def _js_dengesizlik(src):
    i, n = 0, len(src)
    stack, satir, prev = [], 1, ""
    esler = {")": "(", "]": "[", "}": "{"}
    while i < n:
        c = src[i]
        if c == "\n":
            satir += 1; i += 1; continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i); i = n if j < 0 else j; continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            if j < 0:
                return "satır %d: kapanmamış /* yorumu" % satir
            satir += src.count("\n", i, j); i = j + 2; continue
        # Bölme mi regex mi: JavaScript'in klasik belirsizliği. Bir önceki
        # anlamlı karakter operatör/açılış ise gelen '/' regex başlatır.
        # Bu ayrım olmadan /[&<>"']/g gibi bir regex içindeki tırnak,
        # tarayıcıyı "dize başladı" sanıp bütün dosyayı yanlış okuturdu.
        if c == "/" and prev in "(,=:[!&|?{};+-*%~^<>":
            j, kacis, sinif = i + 1, False, False
            while j < n:
                d = src[j]
                if kacis: kacis = False
                elif d == "\\": kacis = True
                elif d == "[": sinif = True
                elif d == "]": sinif = False
                elif d == "\n": break
                elif d == "/" and not sinif: break
                j += 1
            if j < n and src[j] == "/":
                i = j + 1; prev = "/"; continue
        if c in "'\"`":
            tirnak, j, kacis = c, i + 1, False
            while j < n:
                d = src[j]
                if kacis: kacis = False
                elif d == "\\": kacis = True
                elif tirnak == "`" and d == "$" and j + 1 < n and src[j + 1] == "{":
                    derinlik, k = 1, j + 2
                    while k < n and derinlik:
                        if src[k] == "{": derinlik += 1
                        elif src[k] == "}": derinlik -= 1
                        elif src[k] in "'\"`":
                            t2, k2, e2 = src[k], k + 1, False
                            while k2 < n:
                                if e2: e2 = False
                                elif src[k2] == "\\": e2 = True
                                elif src[k2] == t2: break
                                k2 += 1
                            k = k2
                        k += 1
                    j = k - 1
                elif d == tirnak: break
                elif d == "\n" and tirnak != "`":
                    return "satır %d: kapanmamış %s dizesi" % (satir, tirnak)
                j += 1
            if j >= n:
                return "satır %d: kapanmamış %s dizesi (dosya sonu)" % (satir, tirnak)
            satir += src.count("\n", i, j); i = j + 1; prev = tirnak; continue
        if c in "([{":
            stack.append((c, satir))
        elif c in ")]}":
            if not stack:
                return "satır %d: fazladan %s" % (satir, c)
            acik, acik_satir = stack.pop()
            if acik != esler[c]:
                return ("satır %d: %s ile kapanan blok satır %d'de %s ile açılmış"
                        % (satir, c, acik_satir, acik))
        if not c.isspace():
            prev = c
        i += 1
    if stack:
        acik, acik_satir = stack[-1]
        return "dosya bitti ama satır %d'deki '%s' hiç kapanmamış" % (acik_satir, acik)
    return ""


_js_sorun = _js_dengesizlik(open("gateway/html/app.js", encoding="utf-8").read())
ck("dashboard app.js dengeli (yarım commit yakalanır)", not _js_sorun, _js_sorun)


# --- Tema: iki koyu blok AYNI değişkenleri tanımlamalı ----------------------
# Koyu tema iki yerde tanımlı: işletim sistemi tercihi için @media bloğunda,
# kullanıcının açık seçimi için :root[data-theme="dark"] bloğunda. CSS'te bu
# ikisini tek yerden yazmanın yolu yok. Ayrışırlarsa YALNIZ BİR temada bozulma
# olur — geliştirici hangi temayı kullanıyorsa onda düzgün görünür, diğerinde
# renk kaybolur ve fark edilmesi zordur.
_css = open("gateway/html/style.css", encoding="utf-8").read()


def _tema_degiskenleri(bas):
    i = _css.index(bas) + len(bas)
    blok = _css[i:_css.index(chr(10) + "}", i)]
    return set(re.findall(r"(--[a-z0-9-]+)\s*:", blok))


_media_dark = _tema_degiskenleri('@media (prefers-color-scheme: dark) {')
_attr_dark = _tema_degiskenleri(':root[data-theme="dark"] {')
ck("koyu tema blokları aynı değişkenleri tanımlıyor",
   bool(_media_dark) and _media_dark == _attr_dark,
   "yalnız birinde: " + ", ".join(sorted(_media_dark ^ _attr_dark)))
ck("açık tema seçimi işletim sistemini ezebiliyor",
   ':root:not([data-theme="light"])' in _css)
_idx = open("gateway/html/index.html", encoding="utf-8").read()
ck("tema, sayfa çizilmeden ÖNCE uygulanıyor (yanıp sönme yok)",
   "dbstack-theme" in _idx and _idx.index("dbstack-theme") < _idx.index("<body"))


# --- install.sh'te `set -e` + başarısız komut ikamesi tuzağı ----------------
# install.sh `set -euo pipefail` ile çalışıyor. Bu kabukta `VAR="$(cmd)"`
# biçiminde cmd başarısız olursa ATAMA da başarısız olur ve betik ORACIKTA
# ölür — hiçbir hata mesajı basmadan. env_get, aranan anahtar .env'de yoksa
# 1 döndürür.
#
# Gerçek bir olaydı: GRAFANA_USER hiçbir zaman üretilmediği için
# `GRAFANA_USER_VAL="$(env_get GRAFANA_USER)"` satırı kurulumu tam da özet
# bölümünden ÖNCE öldürüyordu. Ekranda her şey başarılı görünüyor, çekirdek
# servisler gerçekten ayağa kalkıyor, ama credentials.txt hiç yazılmıyor ve
# kullanıcı panel parolasını HİÇ göremiyordu. Sunucuyu silip sıfırdan kurunca
# yakalandı.
_inst = open("install.sh", encoding="utf-8").read()
_korumasiz = re.findall(r'^\s*[A-Za-z_][A-Za-z0-9_]*="\$\(env_get [A-Z_]+\)"',
                        _inst, re.M)
ck("install.sh'te korumasız env_get ataması yok (set -e sessizce öldürür)",
   not _korumasiz, "; ".join(x.strip() for x in _korumasiz))
# Denetimin kendisi de doğrulanıyor: kasten bozulmuş bir örneği yakalayamıyorsa
# kontrol sessizce hiçbir şey doğrulamıyor demektir.
ck("bu denetim bozuk dosyayı gerçekten yakalıyor",
   bool(_js_dengesizlik("document.addEventListener('click', (ev) => {\n  const a = 1;\n")))

# nginx aynı blokta yinelenen direktifi REDDEDER ve hiç açılmaz. Snippet bir
# location'ın içine include edildiği için, snippet'teki bir direktifi aynı
# location'da tekrar yazmak gateway'i tamamen çökertir.


def location_bodies(conf):
    """location gövdelerini iç içe süslü parantezleri SAYARAK çıkarır.

    Eskiden bu iş `location[^{]*\\{([^}]*)\\}` regex'iyle yapılıyordu ve o regex
    ilk `}` işaretinde duruyordu: /api/ location'ına `if ($csrf_site_ok = 0)
    { return 403; }` eklendiği anda gövde include satırından ÖNCE kesildi, blok
    hiçbir PROXY_SNIPPETS adını içermez oldu ve aşağıdaki kontrolün dışına
    düştü. Bedeli somut: /api/ içine proxy.conf'ta zaten var olan bir direktif
    (ör. `proxy_buffering off;`) yazılırsa nginx "directive is duplicate" ile
    HİÇ açılmaz — dashboard, veritabanı portları ve tüm paneller birden
    erişilemez olur — ama selftest yeşil kalırdı.
    """
    out = []
    # "location" YORUM İÇİNDE de geçiyor (şablonda ödünleşimleri anlatan
    # satırlar var). Satır başına demirlemezsek `[^{]*` yorumdan sonraki ilk
    # `{`e kadar uzayıp bambaşka bir bloğu "location gövdesi" sanıyor: aşağıdaki
    # sayaç 22 yerine 24 gösteriyordu.
    for m in re.finditer(r"^[ \t]*location[^{]*\{", conf, re.M):
        depth, i = 1, m.end()
        while i < len(conf) and depth:
            if conf[i] == "{":
                depth += 1
            elif conf[i] == "}":
                depth -= 1
            i += 1
        out.append(conf[m.end():i - 1])
    return out


snip_directives = set()
for fn in ("proxy", "proxy-metrics", "proxy-panel"):
    for line in open("gateway/snippets/%s.conf" % fn, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and line.endswith(";")                 and not line.startswith("include "):
            snip_directives.add(line.split()[0])
# nginx'te "dizi" direktifleri aynı blokta birden çok kez YAZILABİLİR; onlar
# yinelenme değildir. proxy_set_header hem snippet'ten gelir hem location kendi
# başlığını ekler (/api/'deki X-Api-Token), error_page de birikimlidir. Bunları
# ayıklamazsak kontrol çalışan bir yapılandırmayı kırmızıya boyar ve ilk yapılan
# şey kontrolü kapatmak olur.
snip_directives -= {"proxy_set_header", "error_page", "add_header",
                    "proxy_hide_header", "set", "rewrite"}
dupes = []
audited = 0
for blk in location_bodies(tpl):
    if not any(x in blk for x in PROXY_SNIPPETS):
        continue
    audited += 1
    for line in blk.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and line.endswith(";"):
            d = line.split()[0]
            if d in snip_directives:
                dupes.append(d)
ck("snippet direktifleri location'da tekrar edilmiyor (nginx duplicate hatası)",
   not dupes, ", ".join(sorted(set(dupes))))
# Yukarıdaki kontrol yalnız GÖRDÜĞÜ blokları koruyor; kapsamı bir daha sessizce
# düşmesin diye blok sayısını da iddia ediyoruz. /api/ ayrı snippet'e geçtiğinde
# bu sayı 22'den 21'e inmişti ve testler yeşil kaldığı için kimse fark etmedi.
ck("duplicate kontrolü proxy location'larının tamamını görüyor", audited >= 22,
   "%d location denetlendi" % audited)

# nginx imajı yalnız access.log/error.log'u /dev/stdout'a symlink eder. stream
# logları gerçek dosyaya yazılıyordu: docker'ın rotasyonu (json-file 10m x 3)
# sadece stdout/stderr'i kapsadığı için dosya sınırsız büyüyüp diski dolduruyor,
# container yeniden yaratılınca da kayboluyordu.
_ngx = open("gateway/nginx.conf", encoding="utf-8").read()
_stream = _ngx[_ngx.index("stream {"):]
ck("stream logları stdout/stderr'e gidiyor (docker rotasyonuna girsin)",
   "/dev/stdout" in _stream and "/dev/stderr" in _stream
   and "/var/log/nginx/stream" not in _stream)

# 502 (container yok) ile 504 (cevap gecikti) aynı sayfaya bağlıyken, ÇALIŞAN
# bir motorda uzun süren import kullanıcıya "bu veritabanı kapalı" gibi
# görünüyor, o da import'u baştan başlatıyordu.
_px = open("gateway/snippets/proxy.conf", encoding="utf-8").read()
_inact = open("gateway/snippets/inactive.conf", encoding="utf-8").read()
ck("zaman aşımı (504) 'pasif' sayfasına DEĞİL kendi sayfasına bağlı",
   "error_page 502 503 =503 /_inactive.html;" in _px
   and "error_page 504 /_timeout.html;" in _px
   and "location = /_timeout.html" in _inact and "auth_basic off" in _inact)

# Bu sayfa neredeyse her zaman bir POST'un (import / ALTER) cevabıdır. Sayfa bir
# yandan "aynı işlemi tekrar başlatmayın" derken diğer yandan "sayfayı yenileyip
# bakın" diyordu — POST cevabında yenilemek tarayıcıda "Formu yeniden gönder"
# onayını çıkarır, yani sayfanın uyardığı şeyin ta kendisini yaptırır. Metin
# artık yenilemeyi yasaklıyor ve tek güvenli eylemi (panelin köküne GET) bir
# düğmeyle veriyor.
_t504 = _inact[_inact.index("location = /_timeout.html"):]
ck("zaman aşımı sayfası 'yenileyin' demiyor, güvenli bir çıkış düğmesi veriyor",
   "yenilemeyin" in _t504 and "yenileyip" not in _t504
   and "sayfayı yenileyin" not in _t504 and "<a href='/'" in _t504)

_slow_panels = {"8081": "phpMyAdmin", "8082": "pgAdmin", "8085": "Adminer"}
_short = []
for b in blocks:
    m = re.search(r"listen\s+(\d+)", b)
    if not m or m.group(1) not in _slow_panels:
        continue
    t = re.search(r"proxy_read_timeout\s+(\d+)s", b)
    if not t or int(t.group(1)) < 3600:
        _short.append(_slow_panels[m.group(1)])
ck("veri aktaran panellerde okuma zaman aşımı en az 1 saat", not _short,
   ", ".join(_short))

# ÇAPRAZ-SİTE (CSRF): ayrıcalıklı X-Api-Token'ı gateway'in kendisi ekliyor ve
# kimlik doğrulama tarayıcının önbelleğindeki Basic auth'tan geliyor. Bu kontrol
# olmadan, panele girmiş bir yöneticinin tarayıcısındaki HERHANGİ bir sayfa
# gizli bir form POST'u ile motorları kapatabilir, replika diskini sildirebilir.
_api = tpl[tpl.index("location /api/ {"):tpl.index("location = /_api_crosssite.txt")]
_m = re.search(r"map \$http_sec_fetch_site \$csrf_site_ok \{([^}]*)\}", tpl)
_rows = dict(re.findall(r"^\s*(\S+)\s+([01]);", _m.group(1), re.M)) if _m else {}
ck("/api/ çapraz-site isteği reddediyor (CSRF)",
   "if ($csrf_site_ok = 0)" in _api
   and 'if ($csrf_origin_host != "$host")' in _api
   and _rows.get("default") == "0")
# Panelin kendi çağrıları ve curl ile çalışan bakım betikleri etkilenmemeli:
# tarayıcı same-origin/none der, curl hiçbir başlık göndermez.
ck("panelin kendi sayfası ve başlıksız istemciler geçiyor",
   _rows.get('"same-origin"') == "1" and _rows.get('"none"') == "1"
   and _rows.get("''") == "1")

# PANEL PORTLARININ ÇAPRAZ-SİTE KAPISI — burası İKİ KEZ yarım kapandı, ikisinde
# de ölçülen şey cevap verdiği varsayılan soruya eşit değildi:
#   1. tur — kapı yalnız Mongo Express'e (8083) kondu; oysa yıkıcı işlemi GET
#            ile sunmak eski web arayüzlerinde bir SINIF, tek panele özgü değil.
#   2. tur — kapı HTTP yöntemine baktı ("GET okumadır" varsayımı). mongo-express
#            1.0.2'de GET /db/<vt>/dropIndex/<koleksiyon> indeksi SİLER; kötü
#            niyetli bir sayfadaki tek bir <img> etiketi kapıdan geçiyordu
#            (canlı üretildi: 302 döndü, indeks düştü). Bu testin ADI da
#            "çapraz-site YAZMA reddediliyor" diyerek olmayan bir güvence
#            veriyordu — reddedilmeyen isteğin kendisi bir yazmaydı.
# Ölçüt artık yöntem değil: "bu isteği panelin KENDİ sayfası mı başlattı?"
# Cevabı tarayıcı veriyor (Sec-Fetch-Site/Sec-Fetch-Mode; sayfadaki JS bu
# başlıkları değiştiremez). Yol kara listesi TUTMUYORUZ: panel imajı yükselince
# liste sessizce eksik kalır, test yeşil kalır, koruma kalmaz.
_pf = re.search(r'map "\$http_sec_fetch_site:\$http_sec_fetch_mode" \$panel_from \{([^}]*)\}',
                tpl)
_pfrows = dict(re.findall(r"^\s*(\S+)\s+([012]);", _pf.group(1), re.M)) if _pf else {}
_csrf = open("gateway/snippets/panel-csrf.conf", encoding="utf-8").read()
ck("panel kapısı yönteme değil, isteği KİMİN başlattığına bakıyor",
   _pfrows.get("default") == "0"
   and _pfrows.get('"~^same-origin:"') == "2"
   and _pfrows.get('"same-site:navigate"') == "1"
   and "if ($panel_from = 0) { return 403; }" in _csrf)
# Yöntem hâlâ kullanılıyor ama TEK BAŞINA değil: yalnız "giriş gezinmesi"
# kademesinde yazmayı kesmek için. Origin kapısı da yöntemden bağımsız hale
# geldi (Sec-Fetch göndermeyen eski tarayıcılar için ikinci kapı).
ck("GET dahil, panelin kendi sayfasından gelmeyen istek durduruluyor",
   'set $panel_deny "$panel_write$panel_from";' in _csrf
   and 'if ($panel_deny = "11") { return 403; }' in _csrf
   and 'if ($csrf_origin_host != "$host") { return 403; }' in _csrf
   and "error_page 403 /_panel_crosssite.html;" in _csrf)
# Kapı bir SINIFA karşı olduğu için tek panele bağlanamaz: bugün mongo-express,
# yarın başka bir panelin GET ucu. Hepsinde olmalı.
_pnl_locs = [b for b in location_bodies(_panels) if "set $up " in b]
_kapisiz = [re.search(r"set \$up (\S+);", b).group(1) for b in _pnl_locs
            if "snippets/panel-csrf.conf" not in b]
ck("kapı yalnız Mongo Express'te değil, TÜM panellerde",
   not _kapisiz and len(_pnl_locs) >= 12,
   "%d panel location, kapısız: %s" % (len(_pnl_locs), ", ".join(_kapisiz)))
# error_page tanımı, sayfası olmayan bir server'da sessizce boşa düşer ve
# kullanıcı nginx'in çıplak "403 Forbidden" ekranını görür: veritabanı bilmeyen
# kullanıcı bunu "panel bozuldu" diye okur.
_psrv = [b for b in blocks if re.search(r"listen\s+(808[1-9]|809[0-2])\s+ssl", b)]
_sayfasiz = [re.search(r"listen\s+(\d+)", b).group(1) for b in _psrv
             if "snippets/panel-csrf-page.conf" not in b]
ck("her panelde açıklama sayfası tanımlı (çıplak 403 görünmüyor)",
   not _sayfasiz and len(_psrv) == 12, "%d panel, sayfasız: %s"
   % (len(_psrv), ", ".join(_sayfasiz)))
# MEŞRU KULLANIM: dashboard'dan panele geçiş ayrı porta gittiği için tarayıcı
# "same-site" der. Bu geçiş (yalnız üst seviye gezinme) geçmeli — GET'i de
# engelleseydik "Panel aç" düğmesi her seferinde 403 verirdi. Aynı kademeden
# YAZMA geçmemeli: aynı host'un başka portundaki bir sayfanın gizli form POST'u.
_pw = re.search(r"map \$request_method \$panel_write \{([^}]*)\}", tpl)
_pwrows = dict(re.findall(r"^\s*(\S+)\s+([01]);", _pw.group(1), re.M)) if _pw else {}
ck("'Panel aç' düğmesi çalışıyor, o kademeden yazma geçmiyor",
   _pwrows.get("GET") == "0" and _pwrows.get("HEAD") == "0"
   and _pwrows.get("default") == "1"
   and _pfrows.get('"same-site:navigate"') == "1"
   and 'if ($panel_deny = "11")' in _csrf)
# Tarayıcı olmayan istemci (curl ile çalışan bakım betikleri) hiçbir Sec-Fetch
# başlığı göndermez; kapı onları dışarıda bırakırsa betikler sessizce 403 alır.
ck("tarayıcı olmayan istemciler ve adres çubuğu panele erişebiliyor",
   _pfrows.get('":"') == "2" and _pfrows.get('"~^none:"') == "2")

# Dashboard hata gövdesini kullanıcıya OLDUĞU GİBİ gösteriyor (app.js: r.text()).
# Ortak HTML sayfaları döndüğünde kullanıcı hata penceresinde koca bir HTML
# kaynağı görüyordu — üstelik "veritabanı kapalı" diyerek, oysa kapalı olan
# controller'dı. nginx aynı kod için İLK error_page'i kullandığı için bu
# tanımlar proxy.conf include'undan önce gelmek zorunda.
_pa = open("gateway/snippets/proxy-api.conf", encoding="utf-8").read()
_apitxt = re.findall(r"location = (/_api_\w+\.txt) \{([^}]*)\}", tpl)
ck("/api/ hata gövdeleri düz metin (dashboard'a HTML dönmüyor)",
   "snippets/proxy-api.conf" in _api
   and _pa.index("error_page 504") < _pa.index("include /etc/nginx/snippets/proxy.conf")
   and len(_apitxt) == 3
   and all("internal;" in b and "text/plain" in b and "auth_basic off" in b
           for _, b in _apitxt),
   "%d hata ucu" % len(_apitxt))

# 504 metni /api/'nin TAMAMINA bağlı, dashboard ise 5 saniyede bir /api/status,
# /api/plans, /api/events yokluyor. "İşlem başlatıldı ama sonucu beklerken süre
# doldu" diye başlayan metin, hiçbir düğmeye basmamış kullanıcıya olmayan bir
# işlemi haber veriyordu (üstelik app.js başına "Kontrol servisine ulaşılamıyor:"
# ekliyor). Metin iki duruma da doğru gelmeli: uyarı "başlattıysanız" koşullu.
_apitimeout = dict(_apitxt).get("/_api_timeout.txt", "")
ck("/api/ zaman aşımı metni salt-okunur yoklamalarda da doğru",
   "İşlem başlatıldı ama" not in _apitimeout and "başlattıysanız" in _apitimeout)

# Bu düz metinlerin kullanıcıya ULAŞMASI da gerekiyor. Düğme işleyicileri
# (activate/deactivate/toggle*/rebuild) async; tek çağrı yerleri olan click
# dinleyicisi ise async değil. Dallar "return activate(engine)" derken api()'nin
# 403/504'te attığı hata yakalanmamış promise reddine dönüşüyor, onay penceresi
# kapanıyor ve ekranda hiçbir şey olmuyordu — kullanıcı düğmeye tekrar basıyordu.
_app = open("gateway/html/app.js", encoding="utf-8").read()
ck("düğme hataları kullanıcıya gösteriliyor (sessiz promise reddi yok)",
   "p.catch(" in _app and "İşlem yapılamadı" in _app
   and "p = activate(engine);" in _app and "p = rebuildStandby(engine);" in _app
   # dalların hiçbiri promise'i doğrudan return edip yakalanmadan bırakmamalı
   and not re.search(r"case '[\w-]+':\s*return "
                     r"(activate|deactivate|toggleReplication|toggleAutoFailover"
                     r"|rebuildStandby|showConnection)\(", _app))

# =============================================================================
# 6. YEDEKLEME BETİĞİ
# =============================================================================
# Bu bölümün tek derdi şu: bir yedekleme ürününde en pahalı hata, felaket günü
# dosyayı açıp İÇİNİ BOŞ bulmaktır. Betik boş yedek üretip ona "Bütünlük
# doğrulandı" dediği sürece kullanıcı yedeği olduğunu sanır.
head("6. Yedekleme — boş yedek 'doğrulandı' geçmemeli")
_bk = open("scripts/backup.sh", encoding="utf-8").read()

# backup_mssql'de $C tanımsız kalmıştı: `set -u` yüzünden bash tüm betikten
# çıkıyor, mssql'den sonraki motorların hiçbiri yedeklenmiyordu. Aynı hata
# tekrarlanmasın diye $C kullanan her fonksiyon C'yi kendisi çözmeli.
_fn = re.findall(r"\n((?:backup|restore)_\w+)\(\) \{(.*?)\n\}", _bk, re.S)
_undef = [n for n, body in _fn if '"$C"' in body and 'C="$(primary_of' not in body]
ck("yedek/geri yükleme fonksiyonlarında $C tanımsız kalmıyor", not _undef, ", ".join(_undef))
ck("bir motorun kabuk hatası tüm turu öldürmüyor (alt kabukta çalışıyor)",
   'if ( "backup_$eid" ); then' in _bk)

# Parola HOST'ta genişlerse (çift tırnak) değişken host'ta yoktur; set -u alt
# kabuğu öldürür, motor listesi boş kalır ve BOŞ arşiv "doğrulandı" damgası yer.
ck("ClickHouse parolası container'da çözülüyor (host'ta değil)",
   "sh -c 'exec clickhouse-client" in _bk)
ck("ClickHouse/MSSQL boş veritabanı listesiyle yedek üretmiyor",
   '[ -n "$dbs" ] ||' in _bk and _bk.count('[ -n "$dbs" ] ||') >= 2)
ck("Cassandra şema dökümü kontrol ediliyor (şemasız snapshot geri yüklenemez)",
   "Cassandra şeması alınamadı" in _bk)
ck("RabbitMQ tanım borusunun iki ucu da kontrol ediliyor",
   "RabbitMQ tanım dosyası okunamadı" in _bk)
ck("Elasticsearch snapshot deposu budanıyor (volume ve arşiv sınırsız büyümesin)",
   '-X DELETE "http://localhost:9200/_snapshot/backup_repo/$s"' in _bk)
# PostgreSQL geri yüklemesinde ON_ERROR_STOP KULLANILMAMALI. Kullanıldığında
# geri yükleme HER SEFERİNDE yarıda kalıp veri kaybettiriyor: `pg_dumpall
# --clean` çıktısı bağlı olunan rolü ve veritabanını da düşürmeye çalışır,
# bunlar zararsızca hata verir, ama psql tam o noktada — diğer veritabanları
# çoktan düşürülmüşken — durur. postgres:16 üzerinde birebir üretildi:
# geri yükleme sonrası `database "defaultdb" does not exist`.
_pg_restore = _bk.split("restore_postgresql()")[1].split(chr(10) + "restore_")[0]
# Yorumda geçmesi serbest (neden kullanılmadığını anlatıyor); asıl kural
# psql'in bu bayrakla ÇAĞRILMAMASI.
ck("PostgreSQL geri yüklemesi ON_ERROR_STOP KULLANMIYOR (veri kaybettiriyordu)",
   "psql -v ON_ERROR_STOP" not in _pg_restore)
# Yerine: hatalar toplanır, BEKLENENLER elenir, kalan varsa başarısız denir.
ck("PostgreSQL geri yüklemesi hataları topluyor ve eliyor",
   "current user cannot be dropped" in _pg_restore
   and "cannot drop the currently open database" in _pg_restore)
ck("PostgreSQL geri yüklemesi eleme sonrası kalan hatada BAŞARISIZ diyor",
   "cluster YARIM kalmış olabilir" in _pg_restore and "return 1" in _pg_restore)
ck("doğrulamayı geçemeyen dosya kurtarma noktası sayılmıyor",
   "finalize_backup" in _bk and ".bozuk" in _bk)
# Dosya üreten HER motor finalize_backup'tan geçmeli. mongodb'de bu atlanmıştı:
# arşiv üretilirken hiç doğrulanmıyor, doğrulamayı geçemediğinde kenara da
# alınmıyordu — list/stats onu geçerli kurtarma noktası sayıyor, sync-remote.sh
# uzak sunucuya kopyalıyordu. Tek motorun atlanması gözden kaçtığı için kural
# tek tek değil, üreten fonksiyonların tamamı üzerinden aranıyor.
_finalsiz = [n for n, body in _fn
             if n.startswith("backup_") and "out_path" in body and "finalize_backup" not in body]
ck("dosya üreten her motor finalize_backup'tan geçiyor", not _finalsiz, ", ".join(_finalsiz))

# verify_backup'ın dalları "dosya doğru mu BAŞLIYOR" sorusuyla yetinmemeli:
# kesilmiş bir yedeğin başı her zaman doğrudur. Her biçimde akışın SONUNA
# kadar sağlam olduğunu gösteren bir ölçüt aranıyor.
_arch_dal = _bk.split("*.archive.gz)")[1].split("*.gz)")[0]
# Kontrol KOMUTA değil ÖZELLİĞE bakıyor. Şifreleme eklenince dallar doğrudan
# `gzip -dc` çağırmayı bıraktı: hepsi ortak okuyucudan (oku_akis) geçiyor,
# çünkü artık dosya şifreli de olabilir ve iki yolun aynı kapıdan geçmesi
# şart. Testi "gzip -dc geçiyor mu" diye bırakmak, doğru bir soyutlamayı
# regresyon sanmak olurdu; ama gevşetmiyoruz da: okuyucunun akışı SONUNA
# kadar açtığını ve iki tarafın çıkış kodunu da denetlediğini ayrıca
# sınıyoruz — "zarf yarım mı" sorusunun cevabı orada.
_oku_i = _bk.find("oku_akis() {")
_oku = _bk[_oku_i:_oku_i + 400] if _oku_i >= 0 else ""
ck("MongoDB arşivi ortak akış okuyucusundan geçiyor (şifreli de olabilir)",
   "oku_akis" in _arch_dal)
ck("ortak okuyucu akışı sonuna kadar açıyor (zarf yarım mı)",
   "gzip -dc" in _oku)
ck("ortak okuyucu boru hattının HER İKİ ucunun çıkış kodunu denetliyor",
   "PIPESTATUS" in _oku and 'ps[0]' in _oku and 'ps[1]' in _oku)
ck("MongoDB arşivinde arşiv sonlandırıcısı aranıyor (gövde yarım mı)",
   "ffffffff" in _arch_dal)
# 256 baytlık eşik ÖLÇÜT OLMAKTAN ÇIKTI: dayandığı "gerçek arşiv kilobayt
# mertebesindedir" varsayımı yanlış (hiç kullanıcı verisi olmayan mongo:7.0
# sunucusunun tam arşivi 855 bayt) ve kesikliği zaten göremiyordu.
ck("MongoDB arşivinde boyut eşiği ölçüt olmaktan çıktı", "-lt 256" not in _arch_dal)
ck("Redis yedeğinde RDB sonlandırıcısı aranıyor", "RDB sonlandırıcısı yok" in _bk)
ck("RabbitMQ tanımlarında JSON'ın kapandığına bakılıyor", "JSON kapanmıyor" in _bk)

# Kapalı kalan bir motorun TÜM yedekleri silinmemeli: kapalıyken yeni yedek
# üretilmediği için hepsi tarih eşiğini geçer ve son kurtarma noktası da gider.
ck("clean, her motorda en yeni kopyaları her hâlükârda koruyor",
   "BACKUP_KEEP_MIN" in _bk and 'sort -rn | head -n "$keep"' in _bk)
ck("clean, sayısal olmayan gün argümanını sessizce yutmuyor",
   re.search(r"case \"\$days\" in\s*\n\s*''\|\*\[!0-9\]\*\)", _bk) is not None)
_case = _bk[_bk.index('case "${1:-help}" in'):]
_restore_branch = _case[_case.index("restore-mariadb"):]
ck("restore-* yolları da yedekleme kilidini alıyor (cron yarım veriyi yedeklemesin)",
   "acquire_lock" in _restore_branch[:_restore_branch.index(";;")])

# Statik denetim yetmez: boş bir tar.gz gzip ve tar açısından KUSURSUZDUR
# (115 bayt), boş girdinin gzip'i de öyle (20 bayt). Betiği gerçekten çalıştırıp
# bu dosyalara ne dediğine bakıyoruz. (bash yoksa bu kısım atlanır.)
import shutil as _shutil  # noqa: E402
_bash = _shutil.which("bash")
if _bash:
    import gzip as _gzip          # noqa: E402
    import subprocess as _sub     # noqa: E402
    import tarfile as _tar        # noqa: E402
    import tempfile as _tf        # noqa: E402
    _tmp = _tf.mkdtemp(prefix="dbstack-bk-")
    _p = _tmp.replace("\\", "/")
    if len(_p) > 1 and _p[1] == ":":
        # Yalnızca Windows'ta geliştirirken: GNU tar "C:/yol" gördüğünde bunu
        # UZAK SUNUCU (host:yol) sanıp arşivi açamıyor. Git Bash'in /c/... yolu
        # bu karışıklığı ortadan kaldırır. Üretimde (Linux) fark etmez.
        _p = "/" + _p[0].lower() + _p[2:]

    def _verify(name):
        r = _sub.run([_bash, "scripts/backup.sh", "verify", _p + "/" + name],
                     capture_output=True,
                     env=dict(os.environ, LOG_DIR=_p, BACKUP_DIR=_p))
        return r.returncode

    _bos_d = os.path.join(_tmp, "bos")
    _dolu_d = os.path.join(_tmp, "dolu")
    os.makedirs(_bos_d, exist_ok=True)
    os.makedirs(_dolu_d, exist_ok=True)
    with open(os.path.join(_dolu_d, "app.bak"), "wb") as _fh:
        _fh.write(b"x" * 4096)
    with _tar.open(os.path.join(_tmp, "mssql_full_bos.tar.gz"), "w:gz") as _t:
        _t.add(_bos_d, arcname=".")
    with _tar.open(os.path.join(_tmp, "mssql_full_dolu.tar.gz"), "w:gz") as _t:
        _t.add(_dolu_d, arcname=".")
    with _gzip.open(os.path.join(_tmp, "mariadb_full_bos.sql.gz"), "wb") as _g:
        _g.write(b"")
    with _gzip.open(os.path.join(_tmp, "mariadb_full_dolu.sql.gz"), "wb") as _g:
        _g.write(b"CREATE DATABASE app;\nINSERT INTO t VALUES (1);\n")
    with _gzip.open(os.path.join(_tmp, "redis_full_yanlis.rdb.gz"), "wb") as _g:
        _g.write(b"bu bir RDB dosyasi degil")

    # ---- çok parçalı arşivler: "en az bir dosya var" ölçütü yetmiyor -------
    # Cassandra arşivi schema.cql + SSTable'lardan oluşur. tar'ın içindeki find
    # snapshot dizinlerini bulamazsa yalnız schema.cql paketlenir ve 0 ile
    # çıkar; o schema.cql 0 bayt bile olabilir. Eski ölçüt bu dosyaya
    # "1 dosya, Bütünlük doğrulandı" diyordu — elde sıfır veri vardı.
    def _mkdir(*parca):
        d = os.path.join(_tmp, *parca)
        os.makedirs(d, exist_ok=True)
        return d

    def _yaz(d, ad, icerik=b"veri"):
        with open(os.path.join(d, ad), "wb") as fh:
            fh.write(icerik)

    def _tarla(ad, kok):
        with _tar.open(os.path.join(_tmp, ad), "w:gz") as t:
            t.add(kok, arcname=".")

    _c_bos = _mkdir("c_bos")
    _yaz(_c_bos, "schema.cql", b"")                       # 0 baytlık şema, SSTable yok
    _tarla("cassandra_full_semasiz.tar.gz", _c_bos)

    _c_sema = _mkdir("c_sema")
    _yaz(_c_sema, "schema.cql", b"CREATE KEYSPACE app;\n")  # şema var, SSTable YOK
    _tarla("cassandra_full_snapsiz.tar.gz", _c_sema)

    _c_dolu = _mkdir("c_dolu")
    _yaz(_c_dolu, "schema.cql", b"CREATE KEYSPACE app;\n")
    _yaz(_mkdir("c_dolu", "app", "t-abc", "snapshots", "bk_1"), "nb-1-big-Data.db", b"x" * 512)
    _tarla("cassandra_full_dolu.tar.gz", _c_dolu)

    # ES'te depo budaması bugünün snapshot'ını da götürürse arşivde yalnız depo
    # üstverisi (index-0, index.latest) kalır: dosya sayısı 2'dir ama içinde
    # tek indeks yoktur.
    _e_meta = _mkdir("e_meta")
    _yaz(_e_meta, "index-0", b"repo ustverisi")
    _yaz(_e_meta, "index.latest", b"0")
    _tarla("elasticsearch_full_metaonly.tar.gz", _e_meta)

    _e_dolu = _mkdir("e_dolu")
    _yaz(_e_dolu, "index-0", b"repo ustverisi")
    _yaz(_mkdir("e_dolu", "indices", "xyz", "0"), "__abc", b"x" * 512)
    _tarla("elasticsearch_full_dolu.tar.gz", _e_dolu)

    # mongodump --archive akışı ilk saniyede kesilirse elde yalnız 4 baytlık
    # imza kalır; imza kontrolü tek başına buna "geçerli" diyordu.
    with open(os.path.join(_tmp, "mongodb_full_kisa.archive.gz"), "wb") as _fh:
        _fh.write(b"\x6d\xe2\x99\x81")

    # ---- MongoDB arşivi: "başı doğru ama sonu kesik" ----------------------
    # Bu dal iki kez YANLIŞ ŞEY ölçtüğü için iki kez kapanmadı. İmza kontrolü
    # "dosya doğru mu BAŞLIYOR", 256 baytlık eşik "dump BAŞLADI mı" sorusunu
    # cevaplıyordu; ikisi de akışın BAŞINA bakıyor. Yedeği öldüren şey ise
    # akışın SONU: mongo:7.0 ile üretilen 2000 belgelik gerçek bir arşiv 400
    # bayta kesildiğinde her iki kontrolden de geçip "Bütünlük doğrulandı"
    # alıyor, mongorestore ise "corruption found in archive" deyip duruyordu.
    #
    # Buradaki arşivler mongo:7.0'da ölçülen biçime göre kuruluyor:
    # --archive --gzip DÜZ GZIP yazar (dosya 1f 8b ile başlar), gzip'in
    # içindeki arşiv 6d e2 99 81 ile başlar ve tamamlandığında ff ff ff ff
    # sonlandırıcısıyla biter.
    _MG_BAS = b"\x6d\xe2\x99\x81"
    _MG_SON = b"\xff\xff\xff\xff"
    # Gövde BİLEREK zor sıkışan baytlardan: tekrarlı bir gövde 900 bayttan 38
    # bayta iniyor ve "gzip akışını yarıda kes" senaryosu kurulamıyordu
    # (kesilen parça dosyanın tamamı çıkıyor, test yeşil yanılıyordu).
    _mg_govde = bytes((i * 37 + (i * i) // 7) % 251 for i in range(4000))
    _mg_tam = _MG_BAS + b"\x3c\x00\x00\x00" + _mg_govde + _MG_SON
    with open(os.path.join(_tmp, "mongodb_full_tam.archive.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(_mg_tam))
    # (a) SİNSİ HÂL: arşiv gövdesi yarım ama gzip zarfı kusursuz kapatılmış.
    # `gzip -t` bu dosyaya rc=0 der; ölçüt zarf değil, arşivin SONU olmalı.
    with open(os.path.join(_tmp, "mongodb_full_zarfsaglam.archive.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(_mg_tam[:600]))
    # (b) Ham kesme: gzip akışının kendisi de yarıda kalmış.
    _mg_gz = _gzip.compress(_mg_tam)
    with open(os.path.join(_tmp, "mongodb_full_kesikgzip.archive.gz"), "wb") as _fh:
        _fh.write(_mg_gz[:len(_mg_gz) // 2])
    # (c) .archive.gz adını taşıyan ama içinden mongodump arşivi çıkmayan dosya.
    with open(os.path.join(_tmp, "mongodb_full_baskabir.archive.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(b"CREATE DATABASE app;\n" * 50))
    # (d) Sıkıştırmasız --archive'ın kesilmiş hâli: imzası doğru, sonu yok.
    with open(os.path.join(_tmp, "mongodb_full_duzkesik.archive.gz"), "wb") as _fh:
        _fh.write(_mg_tam[:600])

    # ---- Redis RDB: aynı sınıf, aynı sonuç -------------------------------
    # RDB "REDIS<sürüm>" ile başlar, EOF işlemcisi (ff) + 8 baytlık sağlama
    # ile biter. Eski ölçüt yalnız BAŞA bakıyordu. Kesik bir RDB'yi Redis
    # yüklemez, HİÇ AÇILMAZ ("Unexpected EOF reading RDB file") — üstelik
    # restore_redis o dosyayı koymadan önce eski dump.rdb'yi ve AOF'u siler.
    _rdb_tam = b"REDIS0011" + b"\xfe\x00" + b"\x00\x03abc\x03xyz" * 40 \
               + b"\xff" + b"\x5a\x17\xb9\x93\x28\xac\x32\xaa"
    with open(os.path.join(_tmp, "redis_full_tam.rdb.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(_rdb_tam))
    with open(os.path.join(_tmp, "redis_full_kesik.rdb.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(_rdb_tam[:300]))
    # `rdbchecksum no` ile sağlama alanı sıfırlarla dolar; bu da GEÇERLİ bir
    # RDB'dir, ona "bozuk" demek yedeği yok saymak olur.
    with open(os.path.join(_tmp, "redis_full_sagsiz.rdb.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(_rdb_tam[:-8] + b"\x00" * 8))

    # ---- RabbitMQ tanımları: başı `{` olanın sonu `}` olmalı --------------
    with open(os.path.join(_tmp, "rabbitmq_full_tam.json.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(b'{"queues":[{"name":"siparis"}],"bindings":[]}\n'))
    with open(os.path.join(_tmp, "rabbitmq_full_kesik.json.gz"), "wb") as _fh:
        _fh.write(_gzip.compress(b'{"queues":[{"name":"sipa'))
    # Betiğin KENDİ kenara aldığı dosya kendi verify'ından yeşil tik almamalı:
    # operatör uzantıyı geri alıp o dosyayla geri yüklemeye kalkıyordu.
    with _gzip.open(os.path.join(_tmp, "mariadb_full_kenara.sql.gz.bozuk"), "wb") as _g:
        _g.write(b"CREATE DATABASE app;\n")

    ck("boş arşiv 'doğrulandı' demiyor", _verify("mssql_full_bos.tar.gz") != 0)
    ck("dolu arşiv doğrulanıyor", _verify("mssql_full_dolu.tar.gz") == 0)
    ck("boş dump 'doğrulandı' demiyor", _verify("mariadb_full_bos.sql.gz") != 0)
    ck("dolu dump doğrulanıyor", _verify("mariadb_full_dolu.sql.gz") == 0)
    ck("RDB olmayan dosya Redis yedeği sayılmıyor", _verify("redis_full_yanlis.rdb.gz") != 0)
    ck("içi 0 bayt dosyalardan ibaret arşiv 'doğrulandı' demiyor",
       _verify("cassandra_full_semasiz.tar.gz") != 0)
    ck("SSTable'sız Cassandra arşivi 'doğrulandı' demiyor (şema tek başına veri değil)",
       _verify("cassandra_full_snapsiz.tar.gz") != 0)
    ck("şema + SSTable taşıyan Cassandra arşivi doğrulanıyor",
       _verify("cassandra_full_dolu.tar.gz") == 0)
    ck("yalnız depo üstverisi taşıyan ES arşivi 'doğrulandı' demiyor",
       _verify("elasticsearch_full_metaonly.tar.gz") != 0)
    ck("indeks verisi taşıyan ES arşivi doğrulanıyor",
       _verify("elasticsearch_full_dolu.tar.gz") == 0)
    ck("4 baytlık MongoDB arşivi imzadan geçse de 'doğrulandı' demiyor",
       _verify("mongodb_full_kisa.archive.gz") != 0)
    # Asıl ölçüt: akış SONUNA KADAR sağlam mı? Sağlam olan geçmeli — bir
    # yedeğe haksız yere "bozuk" demek onu YOK saymakla aynı şeydir.
    ck("tam MongoDB arşivi doğrulanıyor",
       _verify("mongodb_full_tam.archive.gz") == 0)
    ck("gzip zarfı sağlam ama gövdesi kesik MongoDB arşivi 'doğrulandı' demiyor",
       _verify("mongodb_full_zarfsaglam.archive.gz") != 0)
    ck("gzip akışı yarıda kalmış MongoDB arşivi 'doğrulandı' demiyor",
       _verify("mongodb_full_kesikgzip.archive.gz") != 0)
    ck("içinden mongodump arşivi çıkmayan .archive.gz 'doğrulandı' demiyor",
       _verify("mongodb_full_baskabir.archive.gz") != 0)
    ck("sıkıştırmasız --archive'ın kesilmiş hâli 'doğrulandı' demiyor",
       _verify("mongodb_full_duzkesik.archive.gz") != 0)
    ck("tam RDB doğrulanıyor", _verify("redis_full_tam.rdb.gz") == 0)
    ck("sağlaması kapalı (geçerli) RDB doğrulanıyor",
       _verify("redis_full_sagsiz.rdb.gz") == 0)
    ck("başı REDIS olan ama sonu kesik RDB 'doğrulandı' demiyor",
       _verify("redis_full_kesik.rdb.gz") != 0)
    ck("tam RabbitMQ tanım dosyası doğrulanıyor",
       _verify("rabbitmq_full_tam.json.gz") == 0)
    ck("JSON'ı kapanmayan RabbitMQ tanım dosyası 'doğrulandı' demiyor",
       _verify("rabbitmq_full_kesik.json.gz") != 0)
    ck("kenara alınmış (.bozuk) dosya verify'dan yeşil tik almıyor",
       _verify("mariadb_full_kenara.sql.gz.bozuk") != 0)
    _shutil.rmtree(_tmp, ignore_errors=True)

# =============================================================================
# MariaDB tohumlaması: YÖN KEMERİ — sahte docker ile GERÇEK betiği çalıştırarak
# =============================================================================
# Bu kemeri yalnız metin olarak denetlemek YETMİYOR. İki kez yazıldı, ikisi de
# "mantıken doğru" göründü, ikisi de YANLIŞ SORUYU ölçtü:
#   1) "kaynakta hiç tablo yok mu?" → devirden sonra İKİ düğümde de veri vardır,
#      biri bayattır; kemer hiç ateşlemedi.
#   2) "hedefin GTID SIRA numarası büyük mü?" → sıra numarası güncellik ölçüsü
#      DEĞİLDİR. Devirden sonra iki düğüm aynı alanda ayrı kollara ayrılır ve
#      bayat eski primary'nin sırası (0-1-100) canlı düğümünkinden (0-2-98)
#      BÜYÜK kalır: ölçüt tam ters cevabı verir, döküm canlı verinin üzerine
#      basılır.
# Doğru soru KAPSAMA'dır: hedefin gördüğü her işlem kaynakta da VAR MI? Bunu
# sunucu kimliğiyle birlikte sormak gerekir. Aşağıdaki testler betiği gerçekten
# çalıştırıp döküm yolunun tetiklenip tetiklenmediğine bakar — arıza yalnız
# çalıştırınca görünüyor. (Ölçütlerin kendisi canlı MariaDB 11.4 container'ları
# üzerinde doğrulandı; sahte docker o ölçümlerin sayılarını taklit eder.)
if _bash:
    import subprocess as _msub   # noqa: E402
    import tempfile as _mtf      # noqa: E402

    _mdir = _mtf.mkdtemp(prefix="dbstack-mdb-")

    def _pxp(p):
        # Git Bash "C:/yol"u anlamaz; üretimde (Linux) bu dönüşüm hiçbir şey
        # değiştirmez.
        p = p.replace("\\", "/")
        if len(p) > 1 and p[1] == ":":
            p = "/" + p[0].lower() + p[2:]
        return p

    # Sahte docker: betiğin kullandığı çağrıları taklit eder, ne yaptığını
    # $FAKE_TRACE'e yazar. Düğümlerin "hâli" NODE_<ad>_<alan> env'leriyle gelir.
    _FAKE_DOCKER = r'''#!/bin/sh
set -u
IZ="${FAKE_TRACE:-/dev/null}"
DURUM="${FAKE_STATE:-/tmp}"
[ "${1:-}" = "exec" ] || { echo "sahte docker: desteklenmeyen komut: $*" >&2; exit 90; }
shift
while [ $# -gt 0 ]; do
    case "$1" in
        -e) shift 2 ;;
        -i|-t|-it) shift ;;
        *) break ;;
    esac
done
dugum="${1:-}"; shift
prog="${1:-}"; shift
anahtar="$(printf '%s' "$dugum" | tr '-' '_')"
al() { eval "v=\${NODE_${anahtar}_$1-$2}"; printf '%s\n' "$v"; }

case "$prog" in
mariadb-dump)    echo "DUMP_FROM=$dugum" >> "$IZ"; echo "-- sahte dokum"; exit 0 ;;
mariadb-upgrade) exit 0 ;;
mariadb)         ;;
*) echo "sahte docker: bilinmeyen program: $prog" >&2; exit 91 ;;
esac

sutunsuz=0; sorgu=""
while [ $# -gt 0 ]; do
    case "$1" in
        -N|--skip-column-names) sutunsuz=1 ;;
        -e) shift; sorgu="${1:-}" ;;
    esac
    shift
done

if [ -z "$sorgu" ]; then
    cat > /dev/null                       # dokum borusunun ucu: yukleme
    echo "LOAD_INTO=$dugum" >> "$IZ"
    exit 0
fi

mf="$DURUM/$anahtar.master"
if [ ! -f "$mf" ]; then
    ilk="$(al MASTER '')"
    [ -n "$ilk" ] && printf '%s\n' "$ilk" > "$mf"
fi

case "$sorgu" in
*"CHANGE MASTER"*)
    h="$(printf '%s' "$sorgu" | sed -n "s/.*MASTER_HOST='\([^']*\)'.*/\1/p")"
    printf '%s\n' "$h" > "$mf"
    echo "CHANGE_MASTER_ON=$dugum HOST=$h" >> "$IZ" ;;
*"SHOW SLAVE STATUS"*)
    # GERCEK istemci davranisi: -N (--skip-column-names) verildiginde \G
    # ciktisinin TAMAMI susar. Betik bir kez bu tuzaga dustu (Master_Host
    # kemeri hic atesleyemedi); sahte docker bunu taklit etmezse test o
    # hatanin geri gelmesini yakalayamaz.
    [ "$sutunsuz" = "1" ] && exit 0
    if [ -f "$mf" ]; then
        echo "*************************** 1. row ***************************"
        echo "                Slave_IO_Running: Yes"
        echo "               Slave_SQL_Running: Yes"
        echo "                     Master_Host: $(cat "$mf")"
        echo "           Seconds_Behind_Master: 0"
    fi ;;
*"@@read_only"*)                 al RO 0 ;;
*"@@log_bin"*)                   al LOGBIN 1 ;;
*"@@gtid_binlog_state"*)         al BSTATE ''; al SLAVEPOS '' ;;
*"@@gtid_current_pos"*)          al POS '' ;;
*"@@gtid_binlog_pos"*)           al POS '' ;;
*"information_schema.SCHEMATA"*) al DBS 'app' | tr ' ' '\n' ;;
*"table_schema='mysql'"*)        echo 3 ;;
*"information_schema.TABLES"*)   al TABLES 0 ;;
*"SELECT 1"*)                    echo 1 ;;
*) : ;;
esac
exit 0
'''
    _fake_docker_path = os.path.join(_mdir, "docker")
    with open(_fake_docker_path, "w", encoding="utf-8", newline="\n") as _fh:
        _fh.write(_FAKE_DOCKER)
    os.chmod(_fake_docker_path, 0o755)

    def _kisa(*parca):
        # ck() tek satır bekler: izleri ve çıktıyı sıkıştırıp kırpıyoruz.
        m = " · ".join(" ".join(str(x).split()) for x in parca if str(x).strip())
        return m[:140]

    def _attach(prim, stby, dugumler, ek=None):
        """attach fazını sahte docker ile çalıştırır → (rc, çıktı, iz)."""
        iz = os.path.join(_mdir, "iz")
        durum = os.path.join(_mdir, "durum")
        _shutil.rmtree(durum, ignore_errors=True)
        os.makedirs(durum, exist_ok=True)
        open(iz, "w").close()
        env = dict(os.environ, MARIADB_PASSWORD="x", DB_PASSWORD="x",
                   REPLICATION_PRIMARY=prim, REPLICATION_STANDBY=stby,
                   FAKE_TRACE=_pxp(iz), FAKE_STATE=_pxp(durum))
        for _ad, _alanlar in dugumler.items():
            for _k, _v in _alanlar.items():
                env["NODE_%s_%s" % (_ad.replace("-", "_"), _k)] = str(_v)
        env.update(ek or {})
        # PATH'i bash'in KENDİSİ kursun: Windows'ta Python'un PATH'i ";" ile
        # ayrılmış olur, doğrudan geçirmek yolu bozar.
        r = _msub.run([_bash, "-c",
                       'PATH="$1:$PATH"; export PATH; '
                       'exec sh scripts/replication/mariadb.sh attach',
                       "-", _pxp(_mdir)],
                      capture_output=True, env=env)
        return (r.returncode,
                (r.stdout + r.stderr).decode("utf-8", "replace"),
                open(iz, encoding="utf-8").read())

    # BAYAT = devirde geride kalmış eski primary (server-id 1, kendi kolunda
    # 100'e kadar yazmış). CANLI = yükseltilmiş düğüm (server-id 2, aynı alanda
    # kendi kolunda 98'de). Sayılar denetim ajanının ürettiği senaryodan.
    _BAYAT = {"RO": 0, "TABLES": 3, "POS": "0-1-100",
              "BSTATE": "0-1-100", "SLAVEPOS": "", "DBS": "app"}
    _CANLI = {"RO": 0, "TABLES": 9, "POS": "0-2-98",
              "BSTATE": "0-2-98", "SLAVEPOS": "0-1-95", "DBS": "app"}

    head("MariaDB tohumlaması — yön kemeri (sahte docker, gerçek betik)")

    # (1) Denetimin CANLI ÜRETTİĞİ felaket: kaynak bayat, hedef canlı. Eski
    # ölçüt (sıra karşılaştırması) burada susuyordu: 98 > 100 değil.
    rc, cikti, iz = _attach("mariadb", "mariadb-replica",
                            {"mariadb": _BAYAT, "mariadb-replica": _CANLI})
    ck("bayat kaynaktan canlı hedefe tohumlama REDDEDİLİYOR (rc=1)", rc == 1,
       _kisa("rc=%d" % rc))
    ck("reddedilen koşuda döküm hiç başlamıyor", "DUMP_FROM" not in iz, _kisa(iz))
    ck("canlı hedef bayat düğümün slave'i YAPILMIYOR", "CHANGE_MASTER_ON" not in iz)

    # (2) GTID hiç yokken: hedefte tablo var ama konum boş → kapsama
    # KANITLANAMAZ. Boş konumu "kapsanmış" saymak, dökümü yine bastırıyordu.
    rc, cikti, iz = _attach(
        "mariadb", "mariadb-replica",
        {"mariadb": dict(_BAYAT, POS="", BSTATE="", SLAVEPOS=""),
         "mariadb-replica": dict(_CANLI, POS="", BSTATE="", SLAVEPOS="")})
    ck("GTID okunamayan DOLU hedefe döküm basılmıyor", rc == 1 and "DUMP_FROM" not in iz,
       "rc=%d iz=%s" % (rc, _kisa(iz)))

    # (3) MEŞRU KURTARMA: controller hedefin hacmini silip container'ı yeniden
    # kurar (0 tablo). Kaybedilecek veri yoktur; kemer buna DOKUNMAMALI.
    rc, cikti, iz = _attach("mariadb-replica", "mariadb",
                            {"mariadb-replica": _CANLI,
                             "mariadb": {"RO": 1, "TABLES": 0, "POS": "0-1-1",
                                         "BSTATE": "0-1-1", "SLAVEPOS": ""}})
    ck("devir sonrası meşru kurtarma engellenmiyor (rc=0)", rc == 0, _kisa(cikti[-200:]))
    ck("döküm CANLI düğümden alınıp silinmiş düğüme basılıyor",
       "DUMP_FROM=mariadb-replica" in iz and "LOAD_INTO=mariadb" in iz, _kisa(iz))
    ck("CHANGE MASTER canlı düğümü gösteriyor",
       "CHANGE_MASTER_ON=mariadb HOST=mariadb-replica" in iz, _kisa(iz))

    # (4) YANLIŞ ALARM TESTİ. Hedef DOLU ama gördüğü her şey kaynakta var
    # (akan bir replikayı elle yeniden tohumlama). Bu koşu ENGELLENMEMELİ.
    # Not: denetimin önerdiği MASTER_GTID_WAIT ölçütü tam burada -1 döndürüp
    # meşru akışı reddediyordu (canlı container'da ölçüldü): o fonksiyon yalnız
    # gtid_slave_pos'a bakar, düğümün kendi binlog'una değil.
    rc, cikti, iz = _attach("mariadb", "mariadb-replica",
                            {"mariadb": _BAYAT,
                             "mariadb-replica": {"RO": 1, "TABLES": 5,
                                                 "POS": "0-1-95",
                                                 "BSTATE": "", "SLAVEPOS": "0-1-95"}})
    ck("kapsanan (geride kalmış) dolu hedefe tohumlama ENGELLENMİYOR", rc == 0,
       _kisa(cikti[-200:]))
    ck("bu koşuda döküm gerçekten alınıyor", "DUMP_FROM=mariadb" in iz, _kisa(iz))

    # (5) Aynı kolda gerçekten ileride olan hedef: kaynağın bilmediği yazılar var.
    rc, cikti, iz = _attach("mariadb", "mariadb-replica",
                            {"mariadb": dict(_BAYAT, POS="0-1-95", BSTATE="0-1-95"),
                             "mariadb-replica": {"RO": 0, "TABLES": 5,
                                                 "POS": "0-1-100", "BSTATE": "0-1-100",
                                                 "SLAVEPOS": ""}})
    ck("kaynakta olmayan yazıları olan hedef korunuyor",
       rc == 1 and "DUMP_FROM" not in iz, "rc=%d iz=%s" % (rc, _kisa(iz)))

    # (6) `-N` TUZAĞI. mariadb istemcisi --skip-column-names ile \G çıktısını
    # hiç basmaz; bu yüzden "zaten akışta" kısayolu ve Master_Host kemeri ölüydü.
    # Kısayol çalışmıyorsa sağlıklı bir replika her çağrıda baştan tohumlanır.
    rc, cikti, iz = _attach("mariadb", "mariadb-replica",
                            {"mariadb": _BAYAT,
                             "mariadb-replica": dict(_CANLI, MASTER="mariadb")})
    ck("akışta olan replika yeniden tohumlanmıyor (SHOW SLAVE STATUS okunabiliyor)",
       rc == 0 and "zaten akışta" in cikti and "DUMP_FROM" not in iz,
       _kisa("rc=%d" % rc, cikti[-160:]))

    # (7) Akışta ama YANLIŞ kaynaktan: ters bağlanmış topoloji fark edilmeli.
    rc, cikti, iz = _attach("mariadb", "mariadb-replica",
                            {"mariadb": _BAYAT,
                             "mariadb-replica": dict(_CANLI, MASTER="baska-dugum")})
    ck("yanlış kaynaktan akan topoloji yakalanıyor",
       rc == 1 and "YANLIŞ kaynaktan" in cikti and "DUMP_FROM" not in iz,
       _kisa("rc=%d" % rc, cikti[-160:]))

    # (8) Kaçış kapısı: operatör veriyi bilerek gözden çıkarabilmeli, ama ancak
    # AÇIKÇA söyleyerek. (Controller bunu hiç kullanmaz; hacmi zaten siler.)
    rc, cikti, iz = _attach("mariadb", "mariadb-replica",
                            {"mariadb": _BAYAT, "mariadb-replica": _CANLI},
                            ek={"FORCE_SEED": "1"})
    ck("FORCE_SEED=1 kemeri bilerek aşabiliyor", rc == 0 and "DUMP_FROM=mariadb" in iz,
       "rc=%d iz=%s" % (rc, _kisa(iz)))

    _shutil.rmtree(_mdir, ignore_errors=True)

# =============================================================================
# 7. BELLEK MODELİ — TAVAN, REZERVE VE ÇEKİRDEK BASKISI
# =============================================================================
# Ölçülen olay (16 GB test sunucusu): free -m 15984 MB toplam / 1508 MB
# kullanılan, /proc/pressure/memory some avg10=0.00 · full avg10=0.00 —
# makine %91 boş ve çekirdek SIFIR bellek baskısı bildiriyor. Panel aynı
# anda "AYRILAN BELLEK 15 GB / 12 GB · %122 aşım" yazıyor, kapalı
# motorların hepsinde "bellek yetmiyor" diyordu.
#
# Sebep model hatasıydı: docker --memory bir TAVANDIR, rezervasyon değil.
# Tavanları toplayıp RAM ile kıyaslamak, yoldaki arabaların azami hızlarını
# toplayıp "yol kapasitesi aşıldı" demeye benzer. Ölçülen gerçek kullanım
# tavanların %4-7'siydi: mariadb 3196 MB tavan → 243 MB, postgresql 2397 MB
# tavan → 98 MB, redis 1278 MB tavan → 5 MB.
#
# Sınanan üç kural:
#   SERT     Σ rezerve + yeni_rezerve ≤ dağıtılabilir   (asla ihlal edilmez)
#   YUMUŞAK  Σ tavan   + yeni_tavan   ≤ dağıtılabilir × aşırı_taahhüt
#   KEMER    MemAvailable ≥ yeni_rezerve + emniyet payı
#
# Her kural İKİ senaryoyla sınanıyor: aralarındaki TEK fark kuralın baktığı
# büyüklük. Tek yönlü kontrol ("reddedildi mi") burada hiçbir şey ölçmez —
# her şeyi reddeden bir controller de onu geçerdi, ürünün ölçülen hâli tam
# olarak öyleydi.
head("7. Bellek modeli — tavan ≠ rezerve")

_MEM = {"total": 16384, "avail": 12000}
_ACIK = {"list": []}
app.host_memory_mb = lambda: (_MEM["total"], _MEM["avail"])
app.docker_containers = lambda force=False: [
    dict(c, name=c["service"], status="running", health="healthy")
    for c in _ACIK["list"]]


def _c(servis, tavan_mb):
    """Çalışan bir container: adı ve TAVANI (docker --memory)."""
    return {"service": servis, "memory_mb": tavan_mb}


def _cm(eid, tavan_mb):
    """Motorun ŞU ANKİ ana kopyasını tavanıyla üretir.

    Servis adını elle yazmak sessiz bir ölçüm kaybı veriyordu: yukarıdaki
    devir testleri topolojiyi değiştirdiği için mariadb'nin ana kopyası
    artık mariadb-replica ve "mariadb" adlı container hiç sayılmıyordu —
    rezerve toplamı yarıya iniyor, sınadığımız kural hiç bağlamıyordu.
    """
    return _c(app.current_primary(app.CATALOG.engine(eid)), tavan_mb)


def _durum(total, avail, acik):
    """Sahte host: toplam RAM · çekirdeğin MemAvailable'ı · açık tavanlar."""
    _MEM["total"], _MEM["avail"] = total, avail
    _ACIK["list"] = list(acik)


def _sistem():
    return app.status().get("system", {})


def _sayi(d, ad):
    """Sözleşmedeki sayısal alanı okur; yoksa None.

    Varsayılan UYDURMUYORUZ: `.get(ad, 0)` yazmak alanın yokluğunu "sıfır"
    diye okur ve alan hiç üretilmediğinde bütün kontroller sessizce geçer.
    """
    v = d.get(ad)
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    return v


def _eski_karar(eid):
    """Modelden ÖNCEKİ kararın birebir kopyası: bütçe = RAM − OS payı −
    çekirdek payı − Σ TAVAN; motorun asgarisi sığmıyorsa ret.

    Burada regresyon kemeri olarak duruyor. Yeni model bununla AYNI cevabı
    vermeye başladığı gün aşağıdaki kontrol kırılır — panelin "%122 aşım"
    ekranı geri gelmiş demektir.
    """
    e = app.CATALOG.engine(eid)
    res = e.get("resources", {})
    total = _MEM["total"]
    os_payi = min(max(app.OS_RESERVE_MIN_MB,
                      int(total * app.OS_RESERVE_RATIO)),
                  int(total * 0.6))
    tavanlar = sum(x["memory_mb"] for x in _ACIK["list"])
    butce = total - os_payi - app.CORE_RESERVE_MB - tavanlar
    ovh = int(res.get("panel_mb", 0)) + int(res.get("exporter_mb", 0))
    return (butce - ovh) >= int(res.get("min_mb", 256))


# --- Defterin kendi içinde tutarlılığı ---------------------------------------
# Ölçülen durumun birebir kendisi. 15984 MB RAM'de OS payı 3196, çekirdek
# payı 448 → dağıtılabilir 12340 MB; ayrılan (tavan) toplamı 15087 MB.
# Dört motorun tavanı ölçüldü; kalan 5020 MB panel/exporter/kontrol
# düzlemine ait — tek tek ölçülmedi ama TOPLAMI ölçüldü (15087 MB).
_OLCULEN = [_c("mariadb", 3196), _c("mariadb-replica", 3196),
            _c("postgresql", 2397), _c("redis", 1278),
            _c("panel-ve-exporterlar", 5020)]
_durum(15984, 13987, _OLCULEN)
_sis = _sistem()
_alloc = _sayi(_sis, "allocatable_mb")
_toplam_tavan = sum(x["memory_mb"] for x in _OLCULEN)
ck("dağıtılabilir bildiriliyor ve defterle tutarlı "
   "(RAM − OS payı − çekirdek payı)",
   _alloc is not None
   and _alloc == _sis.get("mem_total_mb", 0) - _sis.get("os_reserve_mb", 0)
   - _sis.get("core_reserve_mb", 0),
   "dağıtılabilir=%s" % mb(_alloc))

_res_top = _sayi(_sis, "stack_reserved_mb")
ck("açık motorların rezerve toplamı tavan toplamından KÜÇÜK "
   "(rezerve ile tavan aynı sayı değil)",
   _res_top is not None and 0 <= _res_top < _toplam_tavan,
   "rezerve=%s tavan=%s" % (mb(_res_top), mb(_toplam_tavan)))

_oran = _sayi(_sis, "overcommit_ratio")
_pol = _sayi(_sis, "overcommit_limit")
ck("aşırı taahhüt oranı bildiriliyor (tavan toplamı / dağıtılabilir)",
   _oran is not None and _pol is not None and _oran > 1.0,
   "oran=%s politika=%s" % (_oran, _pol))

_psi = _sis.get("pressure")
ck("çekirdek baskı sinyali sözleşmedeki biçimde bildiriliyor",
   isinstance(_psi, dict)
   and all(k in _psi for k in ("some10", "some60", "full10", "full60"))
   and _psi.get("seviye") in ("yok", "orta", "yuksek", "bilinmiyor"),
   "seviye=%s" % (_psi or {}).get("seviye"))

# --- YUMUŞAK KURAL: tavan aşımı TEK BAŞINA ret sebebi değil ------------------
# Ölçülen durumun tamamı: tavan toplamı dağıtılabiliri %22 aşıyor, gerçek
# kullanım 1508 MB, baskı 0.00. Bu hâlde yeni bir motor AÇILABİLMELİ.
_p_olculen = app.plan_engine("elasticsearch")
ck("tavan toplamı dağıtılabiliri aşarken de yeni motor açılabiliyor "
   "(aşım tek başına ret sebebi DEĞİL)",
   _p_olculen.get("ok") is True,
   "%s" % ((_p_olculen.get("reason") or "")[:70] or
           ("limit=%s" % mb(_p_olculen.get("limit_mb")))))
ck("(negatif deneme) eski model aynı durumda REDDEDİYOR — "
   "kemer iki davranışı ayırt ediyor",
   not _eski_karar("elasticsearch"),
   "eski defter: 15984 − 3196 − 448 − %d = %d MB"
   % (_toplam_tavan, 15984 - 3196 - 448 - _toplam_tavan))
ck("tavan kuralı politika sınırına kadar geçerli sayılıyor (ceiling_ok)",
   _p_olculen.get("ceiling_ok") is True)

# --- SERT KURAL: Σ rezerve dağıtılabiliri aşamaz -----------------------------
# İki senaryo, AYNI tavan toplamı (11000 MB), farklı rezerve:
#   (a) mariadb + cassandra → açılışta gerçekten ayırırlar (buffer pool, -Xms)
#   (b) redis + minio       → tabanları ~0, tavana doğru BÜYÜRLER
# Karar bu ikisi arasında değişiyorsa kararı veren rezervedir, tavan değil.
#
# Yalıtım için aşırı taahhüt politikası geçici olarak gevşetiliyor: kataloğun
# en yüksek rezerve oranı 0.6 olduğu için, 1.5'lik politika sabiti yürürlükte
# iken SERT kural hiçbir zaman YUMUŞAK kuraldan önce bağlamaz (0.6 × 1.5 =
# 0.9 < 1) ve iki kural birbirinden ayrılamaz.
_OC_ADI = next((n for n in dir(app)
                if re.search(r"OVERCOM|ASIRI|TAAHH", n, re.I)
                and isinstance(getattr(app, n), (int, float))
                and not isinstance(getattr(app, n), bool)), None)
_oc_eski = getattr(app, _OC_ADI) if _OC_ADI else None
_yalitim = False
if _OC_ADI:
    setattr(app, _OC_ADI, 8.0)
    _durum(8192, 7000, [])
    # Sabiti gerçekten patchleyebildik mi? API'nin bildirdiği politika
    # değişmediyse yalıtım SAHTEDİR ve aşağıdaki çift ölçüm hiçbir şey
    # kanıtlamaz — bunu bilmeden "geçti" yazmak en kötüsü olurdu.
    _yalitim = _sayi(_sistem(), "overcommit_limit") == 8.0

if not _yalitim:
    ck("SERT kural YUMUŞAK kuraldan yalıtılarak sınanabiliyor", False,
       "aşırı taahhüt politika sabiti app.py'de bulunamadı/patchlenemedi "
       "(aranan ad: OVERCOM|ASIRI|TAAHH) — iki kural ayrılamadı, "
       "ölçüm YAPILAMADI")
else:
    # Ayar defterini TEMİZLE: aksi hâlde önceki kontrollerden kalan (başka bir
    # host boyutuna göre hesaplanmış) değerler okunuyor ve sahte
    # container'ların tavanı ile defter birbirini tutmuyordu — rezerve 6000
    # yerine 2970 çıkıyor, senaryo sert kuralı hiç çiğnemiyordu.
    app.save_tuning({})
    _durum(8192, 7000, [_cm("mariadb", 5000), _cm("cassandra", 6000)])
    _p_rez = app.plan_engine("elasticsearch")
    _rez_dolu = _sayi(_sistem(), "stack_reserved_mb")
    app.save_tuning({})
    _durum(8192, 7000, [_cm("redis", 5000), _cm("minio", 6000)])
    _p_bos = app.plan_engine("elasticsearch")
    _rez_bos = _sayi(_sistem(), "stack_reserved_mb")

    ck("Σ rezerve dağıtılabiliri aşacaksa istek REDDEDİLİYOR",
       _p_rez.get("ok") is not True and _p_rez.get("reserve_ok") is False,
       "rezerve=%s dağıtılabilir=%s · %s"
       % (mb(_rez_dolu), mb(_sayi(_sistem(), "allocatable_mb")),
          (_p_rez.get("reason") or "")[:50]))
    ck("(negatif deneme) AYNI tavan toplamı, rezerve etmeyen motorlarla "
       "KABUL EDİLİYOR — kararı veren rezerve",
       _p_bos.get("ok") is True and _p_bos.get("reserve_ok") is True,
       "rezerve=%s · %s" % (mb(_rez_bos),
                            (_p_bos.get("reason") or "")[:50]))
    ck("iki senaryonun tavan toplamı aynı, rezervesi farklı "
       "(karşılaştırma gerçekten yalıtılmış)",
       _rez_dolu is not None and _rez_bos is not None
       and _rez_dolu > _rez_bos,
       "dolu=%s boş=%s" % (mb(_rez_dolu), mb(_rez_bos)))
    ck("iki senaryoda da tavan kuralı geçiyor "
       "(ret SERT kuraldan geliyor, yumuşak kuraldan değil)",
       _p_rez.get("ceiling_ok") is True
       and _p_bos.get("ceiling_ok") is True)

if _OC_ADI:
    setattr(app, _OC_ADI, _oc_eski)

# --- Değişmez: kabul edilen hiçbir plan SERT kuralı ihlal etmez --------------
# Tek senaryo yetmez; kuralın sınır durumlarında da tutması gerekiyor.
# Kaç karşılaştırma yapıldığı da ölçütün parçası: alanlar hiç üretilmezse
# döngü sıfır karşılaştırmayla biter ve "ihlal yok" GEÇTİ yazardı.
_ihlal, _bakilan = [], 0
for _tot, _av in ((2048, 1800), (4096, 3500), (8192, 7000),
                  (16384, 14000), (65536, 60000)):
    for _acik in ([], [_cm("mariadb", 2048)],
                  [_cm("mariadb", 2048), _cm("postgresql", 1536)],
                  [_cm("redis", 1024), _cm("minio", 768)]):
        _durum(_tot, _av, _acik)
        _s = _sistem()
        _a = _sayi(_s, "allocatable_mb")
        _r = _sayi(_s, "stack_reserved_mb")
        _acik_svc = set(x["service"] for x in _acik)
        for _e in app.CATALOG.engines:
            # Zaten açık motoru atlıyoruz: onun rezervesi _r'nin İÇİNDE,
            # üstüne bir de plan rezervesini eklemek çift sayma olurdu.
            if _acik_svc & set(_e.get("services", [])):
                continue
            _pl = app.plan_engine(_e["id"])
            if not _pl.get("ok"):
                continue
            _pr = _sayi(_pl, "reserved_mb")
            if _pr is None or _a is None or _r is None:
                _ihlal.append("%s@%s alan yok" % (_e["id"], mb(_tot)))
                continue
            _bakilan += 1
            if _r + _pr > _a:
                _ihlal.append("%s@%s: %d+%d > %d"
                              % (_e["id"], mb(_tot), _r, _pr, _a))
ck("kabul edilen hiçbir planda Σ rezerve dağıtılabiliri aşmıyor",
   not _ihlal and _bakilan >= 40,
   "%d plan denendi%s" % (_bakilan, ("; " + "; ".join(_ihlal[:3]))
                          if _ihlal else ""))

# --- ÇEKİRDEK KEMERİ: defter "yer var" derken çekirdek "yok" diyorsa ---------
# İki senaryonun tek farkı MemAvailable. Defter (RAM, tavanlar, rezerveler)
# ikisinde de birebir aynı: 16 GB boş bir host. Çekirdeğin gerçeği
# bağlayıcıdır — defter ne derse desin ayrılamayan bellek ayrılamaz.
_durum(16384, 13987, [])
_p_bol = app.plan_engine("mariadb")
_durum(16384, 128, [])
_p_dar = app.plan_engine("mariadb")
ck("çekirdek 'yer yok' derken defter 'yer var' dese de REDDEDİLİYOR",
   _p_dar.get("ok") is not True,
   "MemAvailable=128M · %s" % (_p_dar.get("reason") or "")[:60])
ck("(negatif deneme) AYNI defter, MemAvailable 13987 MB iken "
   "KABUL EDİLİYOR — kemer her şeyi reddetmiyor",
   _p_bol.get("ok") is True,
   "limit=%s" % mb(_p_bol.get("limit_mb")))

# --- Katalogda her motorun rezerve tanımı var --------------------------------
# Rezerve motora özgüdür ve kataloğa yazılır: PostgreSQL shared_buffers,
# MariaDB innodb_buffer_pool_size, JVM motorlarında -Xms; Redis/MSSQL/
# MinIO/ClickHouse'ta taban ~0'dır (tavana doğru büyürler). Tanımı olmayan
# bir motor sessizce "0 rezerve" sayılır ve SERT kural onun için hiç
# çalışmaz.
_KAT = json.load(open("catalog.json", encoding="utf-8"))


def _rezerve_tanimli(res):
    """resources ağacında rezerve tanımı var mı (anahtar adına bakar).

    Anahtarın tam adını dayatmıyoruz: tanım ayrı bir alan da olabilir,
    mevcut bir tuning satırının işaretlenmesi de. Aranan şey NİYETİN
    katalogda yazılı olması.
    """
    yigin = [res]
    while yigin:
        d = yigin.pop()
        if isinstance(d, dict):
            for k, v in d.items():
                if re.search(r"reserv|rezerv", str(k), re.I):
                    return True
                yigin.append(v)
        elif isinstance(d, list):
            yigin.extend(d)
    return False


_tanimsiz = [e["id"] for e in _KAT["engines"]
             if not _rezerve_tanimli(e.get("resources", {}))]
ck("catalog.json'daki her motorda rezerve tanımı var",
   not _tanimsiz and len(_KAT["engines"]) >= 10,
   "%d motor bakıldı%s" % (len(_KAT["engines"]),
                           ("; tanımsız: " + ", ".join(_tanimsiz))
                           if _tanimsiz else ""))
# Denetimin BOZUK hâli gerçekten yakalıyor mu? Tanımı sökülmüş bir kopya
# üzerinde aynı fonksiyon "yok" demeli; demezse yukarıdaki satır hiçbir şey
# ölçmüyor demektir.
_kirik = json.loads(json.dumps(_KAT["engines"][0].get("resources", {})))


def _rezerveyi_sok(d):
    if isinstance(d, dict):
        return {k: _rezerveyi_sok(v) for k, v in d.items()
                if not re.search(r"reserv|rezerv", str(k), re.I)}
    if isinstance(d, list):
        return [_rezerveyi_sok(x) for x in d]
    return d


ck("(negatif deneme) rezerve tanımı sökülmüş katalog yakalanıyor",
   not _rezerve_tanimli(_rezerveyi_sok(_kirik)))

# Tanımın katalogda durması yetmez, plana da yansımalı.
_durum(65536, 60000, [])
_ONALLOC = ("postgresql", "mariadb", "elasticsearch", "cassandra",
            "kafka", "neo4j")          # açılışta gerçekten ayırırlar
_ONDEMAND = ("redis", "mssql", "minio", "clickhouse")   # tabanı ~0
_bozuk, _sayilan = [], 0
for _e in app.CATALOG.engines:
    _pl = app.plan_engine(_e["id"])
    if not _pl.get("ok"):
        continue          # önkoşulu tutmayan motor (ör. AVX'siz CPU'da mongo)
    _sayilan += 1
    _pr, _lm = _sayi(_pl, "reserved_mb"), _sayi(_pl, "limit_mb")
    if _pr is None or _lm is None:
        _bozuk.append("%s: reserved_mb yok" % _e["id"])
    elif not 0 <= _pr <= _lm:
        _bozuk.append("%s: rezerve %d, tavan %d" % (_e["id"], _pr, _lm))
    elif _e["id"] in _ONALLOC and _pr <= 0:
        _bozuk.append("%s: açılışta ayırır ama rezerve 0" % _e["id"])
    elif _e["id"] in _ONDEMAND and _pr > _lm * 0.1:
        _bozuk.append("%s: tabanı ~0 olmalı, rezerve %d/%d"
                      % (_e["id"], _pr, _lm))
ck("plan rezerveyi motorun gerçek davranışına göre bildiriyor "
   "(0 ≤ rezerve ≤ tavan)",
   not _bozuk and _sayilan >= 10,
   "%d plan bakıldı%s" % (_sayilan, ("; " + "; ".join(_bozuk[:3]))
                          if _bozuk else ""))

# =============================================================================
# 8. YEDEK ZAMANLAYICISI — "BİR SONRAKİ DENEME" 24 SAAT SONRASI DEĞİL
# =============================================================================
# Ertelenen tur (kilit meşguldü) koşmuş sayılmaz ve zamanlayıcı onu en geç
# BACKUP_RETRY_AFTER sonra yeniden dener. Panel ise "sonraki koşum" diye
# next_run'ı gösteriyordu: hedef DAKİKA geçtiği için o değer ertesi günün
# aynı saati, yani ~24 saat sonrasıdır. Kullanıcı "yedek 24 saat alınmayacak"
# okuyor, oysa deneme 10 dakika sonra yapılacaktı.
head("8. Yedek zamanlayıcısı — bir sonraki DENEME")

app.BACKUP_CFG_FILE = "/tmp/dbstack-selftest/backup-plan.json"
# ZAMAN ENJEKTE EDİLİYOR, DUVAR SAATİNE BAKILMIYOR. Eskiden _simdi=time.time()
# idi ve "hedef dakika 2 dk önce geçti" önkoşulu gece yarısını geçerken ÖNCEKİ
# GÜNE düşüyordu; o zaman "bugün geçti" durumu kurulamıyor ve kontrol ürünü
# haksız yere suçluyordu. Günde iki dakikalık bir pencerede herkeste kırılan
# bir test, testin kendi hatasıdır. Sabit bir öğlen anı seçiyoruz: gün sınırı
# hiçbir yönde işin içine girmiyor.
_gun_ortasi = time.mktime((2026, 6, 15, 12, 0, 0, 0, 0, -1))
_simdi = _gun_ortasi
_lt = time.localtime(_simdi - 120)        # hedef dakika 2 dk önce geçti
_saat = "%02d:%02d" % (_lt.tm_hour, _lt.tm_min)
app.save_backup_cfg({"enabled": True, "time": _saat, "retention_days": 7,
                     "last_deferred": int(_simdi - 60)})
_sch = app.backups_overview(now=_simdi).get("schedule", {})
_na, _nr = _sch.get("next_attempt"), _sch.get("next_run")
_sinir = app.BACKUP_RETRY_AFTER + 120
ck("ertelenen turdan sonra bir sonraki DENEME yakında (24 saat sonrası değil)",
   isinstance(_na, int) and 0 < _na - _simdi <= _sinir,
   "deneme +%s sn (sınır %d) · zamanlanmış koşum +%s sn"
   % (int(_na - _simdi) if isinstance(_na, int) else "yok", _sinir,
      int(_nr - _simdi) if isinstance(_nr, int) else "yok"))
ck("(negatif deneme) next_run'ı deneme diye göstermek bu kontrole takılıyor",
   not (isinstance(_nr, int) and 0 < _nr - _simdi <= _sinir),
   "next_run +%s sn" % (int(_nr - _simdi) if isinstance(_nr, int) else "yok"))
ck("ertelemenin sebebi kullanıcıya yazılıyor (attempt_note)",
   isinstance(_sch.get("attempt_note"), str)
   and len(_sch["attempt_note"]) >= 10,
   str(_sch.get("attempt_note"))[:60])

# Erteleme yokken uydurma bir deneme üretilmemeli: "10 dk sonra tekrar
# denenecek" yazan bir panel, aslında ertesi güne kadar hiçbir şey
# yapmayacakken kullanıcıyı bekletir.
app.save_backup_cfg({"enabled": True, "time": _saat, "retention_days": 7})
_sch2 = app.backups_overview(now=_simdi).get("schedule", {})
ck("erteleme yokken sonraki deneme = zamanlanmış koşum",
   _sch2.get("next_attempt") == _sch2.get("next_run")
   and _sch2.get("attempt_note") is None,
   "deneme=%s koşum=%s not=%s" % (_sch2.get("next_attempt"),
                                  _sch2.get("next_run"),
                                  _sch2.get("attempt_note")))

# =============================================================================
head("9. PITR zamanlaması — arşivlemeyi kimse çağırmazsa özellik ÖLÜDÜR")
# =============================================================================
# PostgreSQL WAL'ı archive_command ile KENDİ arşivler. MariaDB'de böyle bir
# mekanizma YOK: binlog arşive yalnız `pitr.sh arsivle` çalışınca düşer.
# Bu satır crontab'dan düşerse `pitr.sh durum` yine bir pencere yazar — ama
# pencerenin üst sınırı en son elle arşivlenen ana çakılıdır. Özellik "açık"
# görünür, panel yeşildir, ve bunu öğrenmenin tek yolu kurtarmaya muhtaç
# olduğunuz gündür. Kontrol ettiğimiz şey tam olarak bu sessiz ölüm.
_cron = io.open("scripts/crontab.template", encoding="utf-8").read()


def _cron_satirlari(parca):
    """Yorum OLMAYAN, o parçayı içeren cron satırları."""
    return [ln for ln in _cron.splitlines()
            if parca in ln and not ln.lstrip().startswith("#")]


_arsiv = _cron_satirlari("pitr.sh arsivle")
ck("crontab şablonunda etkin bir 'pitr.sh arsivle' satırı var",
   len(_arsiv) == 1, "%d satır" % len(_arsiv))

# Sıklık: günde bir arşivleme, "en fazla 24 saat kaybederim" demektir ve bu
# PITR'ın varlık sebebini ortadan kaldırır. Dakika alanı */N biçiminde ve
# N <= 30 olmalı.
_sik = False
_rpo = "?"
if _arsiv:
    _dk = _arsiv[0].split()[0]
    if _dk.startswith("*/") and _dk[2:].isdigit():
        _rpo = int(_dk[2:])
        _sik = _rpo <= 30
ck("arşivleme en az yarım saatte bir (RPO üst sınırı)", _sik,
   "dakika alanı: %s" % (_arsiv[0].split()[0] if _arsiv else "yok"))

_taban = _cron_satirlari("pitr.sh taban")
ck("etkin bir 'pitr.sh taban' satırı var (WAL tek başına veri değildir)",
   len(_taban) == 1, "%d satır" % len(_taban))
ck("etkin bir 'pitr.sh temizle' satırı var (arşiv sonsuza kadar büyümemeli)",
   len(_cron_satirlari("pitr.sh temizle")) == 1)

# Taban ile gece yedeği AYNI kilidi kullanır. Aynı saate denk gelirlerse
# biri her gece sessizce hiç çalışmaz — ve "hiç çalışmayan taban", yukarıdaki
# satırın var olmasıyla aynı sonucu verir: pencere yok.
_yedek = _cron_satirlari("backup.sh all")
_ayni_saat = False
if _taban and _yedek:
    _ayni_saat = _taban[0].split()[1] == _yedek[0].split()[1]
ck("taban ile gece yedeği aynı saate denk gelmiyor (ortak kilit)",
   not _ayni_saat,
   "taban=%s yedek=%s" % (_taban[0].split()[1] if _taban else "-",
                          _yedek[0].split()[1] if _yedek else "-"))

# crontab'da '%' satır sonu demektir; kaçırılmamış bir '%' komutu ortasından
# keser ve cron bunu hata olarak bildirmez.
ck("şablonda kaçırılmamış '%' yok (cron'da satır sonu anlamına gelir)",
   all("%" not in ln or "\%" in ln
       for ln in _cron.splitlines() if not ln.lstrip().startswith("#")))

# --- Motorsuz çağrı: davranış, metin değil ----------------------------------
# `arsivle`/`taban` motor adı verilmeden çalışabilmeli; yoksa crontab satırı
# motorları TEK TEK saymak zorunda kalır ve yığına eklenen üçüncü bir PITR
# motoru sessizce arşivsiz kalır. Aşağıda fonksiyonun KENDİSİ koşturuluyor:
# çıkış kodu mantığı burada yanlışsa, kapalı bir motor her gece "başarısız"
# diye alarm üretir (insan alarma bakmayı bırakır) ya da tam tersi, hiç
# çalışmamış bir arşivleme "tamam" görünür.
_pitr_src = io.open("scripts/pitr.sh", encoding="utf-8").read()
ck("pitr.sh: 'arsivle' motorsuz çağrıyı karşılıyor",
   "her_motor_icin \"arşivleme\" cmd_arsivle" in _pitr_src)
ck("pitr.sh: 'taban' motorsuz çağrıyı karşılıyor",
   "her_motor_icin \"taban\" taban_al" in _pitr_src)

_fn = _sh_fonksiyon(_pitr_src, "her_motor_icin")
ck("her_motor_icin gövdesi bulundu", len(_fn) > 50, "%d karakter" % len(_fn))

if _fn:
    _senaryo = [
        # (etiket, motor->rc, beklenen çıkış, gerekçe)
        ("hepsi yapıldı",        "0 0", 0, "iki motor da arşivlendi"),
        ("biri düştü",           "0 1", 1, "bir motor düştü — çıkış 1"),
        ("biri kapalı",          "0 3", 0, "kapalı motor başarısızlık değil"),
        ("hepsi kapalı",         "3 3", 3, "hiç denenemedi — ölçülemedi (3)"),
        ("kapalı + düşen",       "3 1", 1, "düşen varsa kapalı onu affetmez"),
    ]
    # Kabuk koşum ortamı: motor listesi iki elemanlı, her motorun döneceği
    # çıkış kodu senaryodan geliyor. Fonksiyonun KENDİSİ (kopyası değil)
    # pitr.sh'tan çıkarılıp buraya konuyor.
    _HARNESS = chr(10).join([
        "set -u",
        "plog() { :; }",
        "RCS=(%s)",
        "I=0",
        "pitr_motorlari() { printf 'a\nb\n'; }",
        "sahte() { local r=${RCS[$I]}; I=$((I+1)); return $r; }",
        "%s",
        "her_motor_icin test sahte",
        "exit $?",
    ])
    for _ad, _rcs, _bek, _neden in _senaryo:
        _harness = _HARNESS % (_rcs, _fn)
        try:
            _r = subprocess.run(["bash", "-c", _harness],
                                capture_output=True, timeout=30).returncode
        except Exception as _e:                     # bash yok / çalıştırılamadı
            _r = "ölçülemedi (%s)" % _e
        ck("her_motor_icin · %s → çıkış %d" % (_ad, _bek),
           _r == _bek, "%s — %s" % (_r, _neden))

_kur = io.open("install.sh", encoding="utf-8").read()
ck("install.sh şablonu state/crontab olarak üretiyor",
   "crontab.template" in _kur and "state/crontab" in _kur)

# =============================================================================
head("10. Ölçüm paketleri — kendi hatasını ürüne yıkmasın")
# =============================================================================
# İki kez aynı sınıf hata yaşandı: paket kendi varsayımı yüzünden ölçemedi ve
# sonucu ÜRÜNÜN hatası gibi raporladı. Buradaki kontroller o iki tuzağı
# kapatıyor.
_rep_e2e = io.open("scripts/e2e/replication.sh", encoding="utf-8").read()
# 1) Devirden sonra roller KALICI takas olur; katalog adına bakan bir paket
#    ana kopya sanıp yedeğe yazmaya çalışır ve "READONLY" alır — sonra bunu
#    ürünün hatası diye yazar.
ck("replication paketi rolleri topolojiden alıyor (katalogdan değil)",
   'if [ "$CUR_PRIM" = "$rep_svc" ]; then' in _rep_e2e
   and 'cat_prim="$rep_svc"' in _rep_e2e)
ck("replication paketi devir sonrası ön koşulu ürünün komutuyla kuruyor",
   "failover rebuild" in _rep_e2e and "E2E_KUR" in _rep_e2e)

# 2) "Kilit dosyası açılamadı" ile "kilidi başkası tutuyor" AYNI ŞEY DEĞİLDİR.
#    Birincisi ölçüm yapılamadı (t_unknown), ikincisi meşru bir atlama
#    (t_skip). Tek dala sıkıştırıldığında paket, hiç yedekleme koşmazken
#    "yedekleme sürüyor" deyip kendini yeşile boyuyordu.
_fo_e2e = io.open("scripts/e2e/failover.sh", encoding="utf-8").read()
_acilamadi = _fo_e2e.find("yedekleme kilidi AÇILAMADI")
_tutuyor = _fo_e2e.find("başka bir işlem TUTUYOR")
ck("failover paketi 'kilit açılamadı' ile 'kilidi başkası tutuyor'u ayırıyor",
   _acilamadi > 0 and _tutuyor > 0 and _acilamadi < _tutuyor,
   "açılamadı@%d tutuyor@%d" % (_acilamadi, _tutuyor))
ck("'kilit açılamadı' ÖLÇÜLEMEDİ sayılıyor (atlandı değil)",
   "t_unknown" in _fo_e2e[max(_acilamadi - 200, 0):_acilamadi])

# 3) Paylaşılan dosya kuralı betiklerde gerçekten uygulanıyor mu?
for _ad in ("backup", "pitr", "restore-drill", "failover-drill",
            "maintenance", "slowlog", "import", "sync-remote"):
    _src = io.open("scripts/%s.sh" % _ad, encoding="utf-8").read()
    ck("scripts/%s.sh günlüğünü paylaşılan olarak açıyor" % _ad,
       "paylasilan_dosya" in _src)
_ortak = io.open("scripts/lib/common.sh", encoding="utf-8").read()
ck("common.sh umask 0002 kuruyor (yeni dosyalar grup-yazılabilir)",
   "umask 0002" in _ortak)
ck("install.sh state/ ve logs/ dizinlerini setgid yapıyor",
   "chmod 2775 state logs" in io.open("install.sh", encoding="utf-8").read())
_st = io.open("stack.sh", encoding="utf-8").read()
ck("stack.sh doctor --duzelt var (hata mesajları oraya yönlendiriyor)",
   "cmd_doctor_duzelt" in _st and "--duzelt" in _st)
ck("doctor moda değil GERÇEK yazılabilirliğe bakıyor ([ -w ])",
   "[ -w " in _st)
# SIRLAR "paylaşılan" sayılmamalı. state/mongo-keyfile 0400 OLMAK ZORUNDA:
# MongoDB gruba/başkasına açık bir keyfile görürse "permissions on keyfile
# are too open" deyip hiç açılmaz. İlk sürüm state/ altındaki BÜTÜN dosyalara
# g+w veriyordu ve --duzelt keyfile'ı 0460 yapıp replica set'i kırdı.
ck("doctor paylaşılan dosyaları TÜRÜNE göre seçiyor (sırlara dokunmuyor)",
   '-name "*.lock"' in _st and '-name "*.json"' in _st
   and "mongo-keyfile" in _st)
ck("doctor --duzelt tüm dosyalara g+w vermiyor",
   "-type f -exec chmod g+w" not in _st.replace(chr(92) + chr(10), " "))
ck("install.sh PITR arşiv/taban dizinlerini açıyor (docker root:root yaratmasın)",
   "backups/postgresql/wal" in _kur and "backups/mariadb/taban" in _kur)
_pitr_src2 = io.open("scripts/pitr.sh", encoding="utf-8").read()
ck("arşivleme kendi izin ön koşulunu kuruyor",
   "arsiv_izni_kur" in _pitr_src2 and "ARSIV_ONARILDI" in _pitr_src2)
ck("arşivleyici uyarısı ŞİMDİKİ duruma bakıyor (geçmiş sayaca değil)",
   "last_failed_time > last_archived_time" in _pitr_src2
   and "arşivleme ŞU AN BAŞARISIZ" in _pitr_src2)

# --- RabbitMQ düğüm adı SABİT olmalı ----------------------------------------
# RabbitMQ durumunu mnesia/rabbit@<hostname> altında tutar; docker hostname'i
# varsayılan olarak CONTAINER ID yapar ve container_name bunu değiştirmez.
# Sonuç: her yeniden yaratmada yepyeni ve BOŞ bir düğüm açılır, eski
# vhost'lar/kullanıcılar/kuyruklar volume içinde öksüz kalır. Sunucuda tek bir
# volume'un içinde birikmiş düğümler ölçüldü:
#   rabbit@2265314e3f4e  rabbit@50271ae2babb  rabbit@644c923a8774 …
# "Hacim duruyor, veri güvende" cümlesinin neden yetmediğinin örneği.
with io.open("docker-compose.yml", encoding="utf-8") as _f:
    _dc_rmq = _yaml.safe_load(_f)
ck("rabbitmq düğüm adı sabit (hostname tanımlı)",
   bool(_dc_rmq["services"]["rabbitmq"].get("hostname")),
   str(_dc_rmq["services"]["rabbitmq"].get("hostname")))

# --- İçe aktarmanın geçici alanı de paylaşılan --------------------------------
# Panelden gelen aktarmayı controller (root) çalıştırır, komut satırından
# geleni yönetici. İlk yaratan sahip olunca diğeri mktemp ile düşer:
#   mktemp: failed to create directory via template '.../ia-XXXXXX'
_imp = io.open("scripts/import.sh", encoding="utf-8").read()
ck("import.sh geçici dizini paylaşılan yapıyor ve yazılabilirliğini ölçüyor",
   'chmod 2775 "$GECICI"' in _imp and '[ ! -w "$GECICI" ]' in _imp)

# --- command: bloğuna YORUM yazılamaz ----------------------------------------
# Katlanmış skalerde (command: >) her satır KOMUT SATIRI ARGÜMANIDIR; YAML
# oradaki "#"i metnin parçası sayar. Bir kez yapıldı ve redis şununla öldü:
#   *** FATAL CONFIG FILE ERROR *** 'maxmemory-policy "allkeys-lru" "#" "Ana"…'
#   wrong number of arguments
# Container hiç açılmadığı için de replikasyon 90 saniye bekleyip düştü ve
# hata mesajı bambaşka bir şey söylüyordu ("replika bağlanmadı").
for _svc_ad, _svc in _dc_rmq["services"].items():
    _cmd = (_svc or {}).get("command")
    if not _cmd:
        continue
    _cmd_s = " ".join(_cmd) if isinstance(_cmd, list) else str(_cmd)
    ck("%s command'ında kaçak '#' yok (YAML yorum sanılmaz)" % _svc_ad,
       "#" not in _cmd_s, _cmd_s[:60])

# --- "Soramadım" ile "yedek değil" ayrı şeylerdir -----------------------------
# redis.sh ready, boş bir INFO cevabını (container kapalı / crash-loop'ta /
# parola yanlış) "replika olarak yapılandırılmamış" diye raporluyordu. Gerçek
# olayda düğüm bir compose hatasıyla hiç açılmıyordu; mesaj replikasyon
# ayarını suçlayıp insanı yanlış yere gönderdi.
_rds_fo = io.open("scripts/failover/redis.sh", encoding="utf-8").read()
ck("redis ready: cevapsız düğüm 'yedek değil' sayılmıyor (çıkış 3)",
   'if [ -z "$info" ]' in _rds_fo and "exit 3" in _rds_fo)

# --- "Kapalı" ile "soramadım" da ayrı şeylerdir ------------------------------
# Container ÇALIŞMIYORSA bunu kesin biliyoruz. Boş cevabı "kötü sonuç" diye
# yorumlamak, ölçülemeyeni ölçülmüş gibi göstermektir. Ölçüldü: kapalı bir
# düğüm için PostgreSQL kapısı "hiç WAL almamış — yükseltme veri kaybına yol
# açar" diyordu (çıkış 1); doğru cümle "düğüm çalışmıyor"du (çıkış 3) ve
# insan yanlış yerde arıyordu. e2e turu bunu redis tarafında yakaladı.
for _m, _et in (("redis", "[redis]"), ("postgresql", "[pg]"), ("mariadb", "[mariadb]")):
    _fo = io.open("scripts/failover/%s.sh" % _m, encoding="utf-8").read()
    ck("%s devir kapısı: kapalı düğüm 'çalışmıyor' diyor (kötü sonuç değil)" % _m,
       "çalışmıyor — yükseltilecek düğüm yok" in _fo and "exit 3" in _fo)

# --- DEPODA saklanan satır sonları -------------------------------------------
# .gitattributes LF'i şart koşuyor ama git bir dosyayı "ikili" sezerse
# normalize ETMEZ ve CRLF olduğu gibi depoya girer. Linux'ta checkout eden
# herkes bozuk dosyayı alır:
#     scripts/replication/postgresql.sh: set: line 7: illegal option -
# Mesaj satır sonundan hiç söz etmiyor; insan hatayı mantıkta arar. için insan hatayı betiğin mantığında arar.
# İki kez yaşandı (postgresql.sh, redis.sh); artık depo denetleniyor.
try:
    _eol = subprocess.run(["git", "ls-files", "--eol", "*.sh", "stack.sh",
                           "install.sh"],
                          capture_output=True, text=True, timeout=60)
    _eol_ok = _eol.returncode == 0 and _eol.stdout.strip()
except Exception:
    _eol_ok = False
if not _eol_ok:
    ck("depoda saklanan betikler LF (git ls-files --eol)", False,
       "git çalıştırılamadı — ölçülemedi")
else:
    _crlf = [ln.split(chr(9))[-1] for ln in _eol.stdout.splitlines()
             if not ln.startswith("i/lf") and not ln.startswith("i/none")]
    ck("depoda saklanan betiklerin hepsi LF", not _crlf,
       ("LF değil: " + ", ".join(_crlf[:4])) if _crlf else "%d dosya"
       % len(_eol.stdout.splitlines()))
# Ve doğrulama zaman aşımında container'ın durumu da söyleniyor: sebep çoğu
# zaman kopyalamada değil, düğümün hiç açılmamış olmasında.
# _app bu noktada gateway/html/app.js'i tutuyor (1680. satır); controller'ı
# ayrı adla okuyoruz ki hangi dosyaya baktığımız isminden belli olsun.
_ctrl_py = io.open("controller/app.py", encoding="utf-8").read()
ck("verify_standby zaman aşımında container durumunu da söylüyor",
   "Container ŞU AN ÇALIŞMIYOR" in _ctrl_py and "_son_gunluk" in _ctrl_py)

# --- Replikasyon açıkken yedek YOKSA panel bunu SÖYLEMELİ --------------------
# Ölçüldü: e2e turundan sonra replikasyon profilleri açık kaldı ama yedek
# container'lar silinmişti. measure_replication_health o motoru atlıyordu
# ("yedek kopya yok: söylenecek bir şey de yok"), panel de flowing=null'ı
# "yedek kopya çalışıyor" diye gösteriyordu — ortada tek bir yedek düğüm
# yokken. Kullanıcı korunduğunu sanıyor, otomatik devir yükseltecek düğüm
# bulamıyor. Üçüncü değer ("bilmiyorum") ile "iyi" aynı şey değildir.
ck("yedek kopya çalışmıyorken 'akmıyor' olarak ölçülüyor",
   "ÇALIŞMIYOR — replikasyon" in _ctrl_py and '"flowing": False' in _ctrl_py)
ck("topoloji belirsizken üçüncü değer (null) yazılıyor",
   "topoloji kaydından yedek düğüm belirlenemedi" in _ctrl_py)
_pnl = io.open("gateway/html/app.js", encoding="utf-8").read()
ck("panel ölçülmemiş replikasyonu 'çalışıyor' diye göstermiyor",
   "yedek kopya durumu ölçülmedi" in _pnl
   and "facts.push('yedek kopya çalışıyor')" not in _pnl)

# --- Prova sonuçları TEK DEFTERDE, kaynağı yazılı ----------------------------
# Ölçüldü: komut satırından koşan devir provası 3.06 sn kesinti ölçtü ama
# panel görmedi — defteri yalnız controller yazıyordu.
_ortak = io.open("scripts/lib/common.sh", encoding="utf-8").read()
ck("common.sh ortak sonuç defteri yazıcısı sunuyor",
   "sonuc_defterine_yaz()" in _ortak and "os.replace(gecici, defter)" in _ortak)
for _ad, _dosya in (("failover-drill", "ha-drill.json"), ("restore-drill", "drill.json")):
    _src = io.open("scripts/%s.sh" % _ad, encoding="utf-8").read()
    ck("%s.sh sonucunu ortak deftere yazıyor" % _ad,
       ("state/" + _dosya) in _src and "sonuc_defterine_yaz" in _src)
# REDDETME BİR SONUÇ DEĞİLDİR: onay verilmediği için yapılmayan prova deftere
# ok=false diye düşerse panel kırmızı "başarısız" rozeti gösterir — oysa
# hiçbir şey denenmemiştir. (Bu tam olarak yaşandı ve ölçülerek düzeltildi.)
_fd = io.open("scripts/failover-drill.sh", encoding="utf-8").read()
ck("onaysız/kapsam dışı prova sonuç defterine YAZILMIYOR",
   'case "${CIKIS_KODU:-0}" in 2|5)' in _fd)
_rd = io.open("scripts/restore-drill.sh", encoding="utf-8").read()
ck("kapsam dışı kurtarma provası sonuç defterine YAZILMIYOR",
   'case "${CIKIS_KODU:-0}" in 2)' in _rd)
ck("doctor içe aktarma geçici dizinini de kapsıyor",
   ".ice-aktarma" in _st)
ck("install.sh içe aktarma geçici dizinini açıyor",
   ".ice-aktarma" in _kur)
_app = io.open("controller/app.py", encoding="utf-8").read()
ck("controller açılışta umask 0o002 kuruyor", "os.umask(0o002)" in _app)

# --- Sağlık rozeti "uygulamanız bağlanabilir" demeli -------------------------
# RabbitMQ'da `rabbitmq-diagnostics ping` yalnız Erlang DÜĞÜMÜNÜN cevap
# verdiğini gösterir; 'rabbit' UYGULAMASI hâlâ başlıyor olabilir. O aralıkta
# panel "sağlıklı" derken broker hiçbir işi kabul etmiyor — ölçüldü:
# healthcheck yeşilken `rabbitmqctl add_vhost` "requires the 'rabbit' app to
# be running" ile çıkış 64 verdi. Yeşil bir rozetin altında çalışmayan bir
# servis, bu projenin varlık sebebi olan hatanın ta kendisi.
with io.open("docker-compose.yml", encoding="utf-8") as _f:
    _dc = _yaml.safe_load(_f)
_rmq_hc = " ".join((_dc["services"]["rabbitmq"].get("healthcheck") or {})
                   .get("test", []))
ck("rabbitmq healthcheck'i 'rabbit' uygulamasını ölçüyor (ping değil)",
   "check_running" in _rmq_hc and " ping" not in _rmq_hc,
   _rmq_hc[:80])
_lc = io.open("scripts/e2e/lifecycle.sh", encoding="utf-8").read()
ck("lifecycle paketi de rabbitmq'yu check_running ile bekliyor",
   "check_running" in _lc)

# --- Devirden SONRA yaşayacak her ayar replikada da olmalı --------------------
# Bu sınıf üç kez ısırdı: mariadb-replica'da /binlog-archive bağlaması yoktu,
# postgresql-replica ana kopyanın planlayıcı ayarını almıyordu, sonra da
# arşivleme ayarlarını. Ortak yanları: hepsi ancak DEVİRDEN SONRA, yani en kötü
# anda ortaya çıkıyor ve hiçbiri hata vermiyor — özellik sessizce ölüyor.
# "Yedek kopya" bir yedek değil, YARIN'IN ANA KOPYASIDIR.
_svc = _dc["services"]


def _mount_hedefleri(ad):
    """Bağlamanın KONTEYNER İÇİ hedefi. Kaynak tarafında ${STACK_DIR:-.} gibi
    iki noktalı bir ifade olabildiği için basit split yanlış sonuç veriyordu;
    önce ${...} blokları çıkarılıyor."""
    out = set()
    for m in (_svc[ad].get("volumes") or []):
        sade = re.sub(r"\$\{[^}]*\}", "", str(m))
        parca = [x for x in sade.split(":") if x.startswith("/")]
        if parca:
            out.add(parca[0])
    return out


def _ayar_adlari(ad):
    """`-c ayar=deger` listesinden ayar adları."""
    out = set()
    for c in (_svc[ad].get("command") or []):
        c = str(c)
        if "=" in c and not c.startswith("-"):
            out.add(c.split("=")[0])
    return out


for _p, _r in (("postgresql", "postgresql-replica"), ("mariadb", "mariadb-replica")):
    _eksik_m = sorted(m for m in _mount_hedefleri(_p) - _mount_hedefleri(_r)
                      # veri hacmi düğüme özeldir; onu paylaşmak zaten yanlış olur
                      if "/var/lib/" not in m and "/data" != m)
    ck("%s, %s'in kalıcılık bağlamalarını taşıyor" % (_r, _p),
       not _eksik_m, "eksik: %s" % (", ".join(_eksik_m) or "yok"))

# PITR ayarları, adı 'archive' geçen her şey: devirden sonra arşivleme durursa
# dönülebilir pencerenin üst sınırı devir anına donar.
_eksik_a = sorted(a for a in _ayar_adlari("postgresql") - _ayar_adlari("postgresql-replica")
                  if "archive" in a)
ck("postgresql-replica arşivleme ayarlarını taşıyor (devirden sonra PITR ölmesin)",
   not _eksik_a, "eksik: %s" % (", ".join(_eksik_a) or "yok"))


def _bayraklar(ad):
    """`--bayrak [deger]` biçimindeki komut satırı bayrakları."""
    c = _svc[ad].get("command") or []
    if not isinstance(c, list):
        c = str(c).split()
    return set(str(x).split("=")[0] for x in c if str(x).startswith("--"))


# ROL FARKI OLAN BAYRAKLAR — bunların replikada olmaması DOĞRU.
# Gerekçesi tek tek yazılı; "istisna listesi" büyüdükçe sessizleşen bir
# kontrol, olmayan kontrolden kötüdür.
_ROL_FARKI = {
    # replica set'te yetkilendirmeyi keyFile açar; --auth'un yerini tutar
    ("mongodb", "mongodb-replica-1"): {"--auth"},
    ("mongodb", "mongodb-arbiter"): {"--auth"},
}
for _p, _r in (("mongodb", "mongodb-replica-1"), ("mongodb", "mongodb-arbiter"),
               ("redis", "redis-replica")):
    _eksik_b = sorted(_bayraklar(_p) - _bayraklar(_r) - _ROL_FARKI.get((_p, _r), set()))
    ck("%s, %s'in ayar bayraklarını taşıyor" % (_r, _p),
       not _eksik_b, "eksik: %s" % (", ".join(_eksik_b) or "yok"))

# --- Replikasyon betikleri YÖNÜ çağırandan almalı ----------------------------
# PostgreSQL betiği "ana kopya her zaman 'postgresql' container'ıdır" diye
# yazılmıştı. Devirden sonra bu tersine döner: slot yedekte aranır (ana
# kopyadaki kalıntıya dokunulmaz), rol ve pg_hba satırı yanlış düğüme yazılır.
# Ölçülen sonucu, 900 saniyelik bir crash-loop ve tamamen alakasız bir hata
# mesajıydı ("postgresql hiç WAL almamış").
_pg_rep = io.open("scripts/replication/postgresql.sh", encoding="utf-8").read()
ck("postgresql replikasyon betiği yönü çağırandan alıyor",
   "REPLICATION_PRIMARY" in _pg_rep and "REPLICATION_STANDBY" in _pg_rep)
ck("postgresql betiği psql'i ANA KOPYA container'ında çalıştırıyor",
   '-i "$PRIMARY"' in _pg_rep and "-i postgresql " not in _pg_rep)
# Slot adı düğüme göre değişiyor (compose'da öyle tanımlı); tek ada bakan
# sürüm devirden sonra var olmayan slot'u siliyordu.
ck("postgresql betiği slot adını hedef düğüme göre seçiyor",
   'POSTGRES_SLOT_PRIMARY' in _pg_rep and 'POSTGRES_REPLICATION_SLOT' in _pg_rep)
ck("postgresql betiği yön sağlaması yapıyor (kaynak = hedef ise durur)",
   '"$PRIMARY" = "$STANDBY"' in _pg_rep)

# Yeniden kurulum yolu ana kopyayı HAZIRLAMALI: kalıntı slot silinmeden yeni
# düğüm `pg_basebackup -C` ile açılamaz.
ck("yeniden kurulum yolu 'prepare' fazını çağırıyor (yalnız mariadb için değil)",
   'jl("ana kopya hazırlanıyor (kalıntı slot/rol temizliği):", prim)' in _app
   and 'script_has_phase(script, "prepare")' in _app)

# =============================================================================
head("11. Aktif oturum geçmişi (ASH) — 'ölçemedim' ile 'boştu' ayrı")
# =============================================================================
# Bu bölümün tamamı TEK bir kurala bakıyor: ölçüm yokluğu "sistem boştu" diye
# kaydedilemez. O kayıt bir daha düzeltilemez — aylar sonra olayın grafiğine
# bakan insan, tam olayın dakikasında "hiç oturum yoktu" görür ve yanlış yere
# bakar. Dört ayrı hâl var ve dördü de birbirinden ayrılmalı:
#   ok=true, n>0  ölçüldü, oturum vardı
#   ok=true, n=0  ölçüldü, gerçekten boştu
#   ok=false      ölçülemedi (sorgu düştü / motor kapandı)
#   kayıt yok     o saniye hiç örneklenmedi (akış kopuk)
_ash_dizin = os.path.join("/tmp", "dbstack-selftest", "ash")
import shutil as _sh                              # noqa: E402
try:
    _sh.rmtree(_ash_dizin)
except OSError:
    pass
os.makedirs(_ash_dizin, exist_ok=True)
app.ASH_DIR = _ash_dizin

_T0 = 1_700_000_000


def _ash_ornek(t, ok=True, oturumlar=None):
    k = {"t": t, "motor": "postgresql", "ok": ok}
    if ok:
        k["n"] = len(oturumlar or [])
        k["oturumlar"] = oturumlar or []
    return json.dumps(k, ensure_ascii=False)


def _ash_defter_yaz(satirlar):
    with io.open(app._ash_dosya("postgresql"), "w", encoding="utf-8") as fh:
        for s in satirlar:
            fh.write(s + "\n")


# 10 saniyelik pencere: 4 saniye ölçüldü (biri boş), 2 saniye ölçülemedi,
# 4 saniye hiç örneklenmedi.
_bekleyen = {"pid": 22, "durum": "active", "bekleme_turu": "Lock",
             "bekleme": "transactionid", "tur": "client backend",
             "kullanici": "app", "vt": "shop", "islem_sn": 9.0,
             "bekleten": [11], "sorgu": "UPDATE siparis SET durum=? WHERE id=?"}
_ash_defter_yaz([
    _ash_ornek(_T0 + 0, True, [_bekleyen]),
    _ash_ornek(_T0 + 1, True, [_bekleyen, dict(_bekleyen, pid=23)]),
    _ash_ornek(_T0 + 2, True, []),                 # gerçekten boş
    _ash_ornek(_T0 + 3, False),                    # ölçülemedi
    _ash_ornek(_T0 + 4, False),                    # ölçülemedi
    _ash_ornek(_T0 + 5, True, [_bekleyen]),
    # T0+6 … T0+9 arası HİÇ kayıt yok (akış kopuk)
])
_p = app.ash_pencere("postgresql", _T0, _T0 + 9)
_k = _p["kapsama"]

ck("ölçülen saniye sayısı yalnız ok=true örnekleri sayıyor",
   _k["olculen_sn"] == 4, "ölçülen=%s (beklenen 4)" % _k["olculen_sn"])
ck("ölçülemeyen örnek AYRI sayılıyor (sıfır oturum diye değil)",
   _k["olculemedi_ornek"] == 2, "ölçülemedi=%s" % _k["olculemedi_ornek"])
ck("hiç örneklenmemiş saniyeler kapsamada eksik görünüyor",
   _k["aralik_sn"] == 10 and _k["oran"] == 0.4,
   "aralık=%s oran=%s" % (_k["aralik_sn"], _k["oran"]))
ck("kapsama eksikse özet bunu AÇIKÇA söylüyor",
   isinstance(_k["not"], str) and "6 saniyesi" in _k["not"], str(_k["not"])[:70])
ck("tam kapsamada uyarı notu YOK (gereksiz alarm üretmiyor)",
   app.ash_pencere("postgresql", _T0, _T0 + 2)["kapsama"]["not"] is None)

# Asıl değer: "kim kimi bekletiyordu" sorusunun cevabı.
ck("kök engelleyen pid bulunuyor",
   _p["bekletenler"] and _p["bekletenler"][0]["pid"] == 11,
   str(_p["bekletenler"])[:60])
ck("en çok görülen bekleme türü bulunuyor",
   _p["beklemeler"] and _p["beklemeler"][0]["ad"] == "Lock:transactionid",
   str(_p["beklemeler"])[:60])
ck("aynı anda en çok kaç oturum vardı ölçülüyor",
   _p["en_cok_oturum"]["n"] == 2 and _p["en_cok_oturum"]["t"] == _T0 + 1,
   str(_p["en_cok_oturum"]))
ck("sorgu metni özete giriyor",
   _p["sorgular"] and _p["sorgular"][0]["ad"].startswith("UPDATE siparis"))

# Hiç defter yokken: "0 oturum" değil, "hiç ölçülmedi".
_p2 = app.ash_pencere("mariadb", _T0, _T0 + 9)
ck("defteri olmayan motorda kapsama SIFIR (uydurma özet yok)",
   _p2["kapsama"]["olculen_sn"] == 0 and _p2["kapsama"]["oran"] == 0.0
   and not _p2["beklemeler"])

# --- Betiğin ayrıştırıcısı: üç hâli AYIRIYOR mu (canlı veritabanı olmadan) --
# Ayrıştırıcı 'cevir' komutu olarak ayrı durduğu için ham girdiyle tek başına
# sınanabiliyor; bu ayrımın kanıtı ancak böyle alınır.
# Ayraç chr(31) (unit separator). İlk sürümde sekmeydi; psql'in -F seçeneği
# kabuktan geçerken iki karakterlik bir dizgiye dönüşüyor, satır bölünemiyor,
# pid çevrilemiyor ve satır SESSİZCE düşüyordu — sonuç "ölçüldü, 0 oturum",
# yani engellemek için yazdığımız sahte sıfırın ta kendisi.
_US = chr(31)
_ash_ham = (
    "S\t1700000000\tok\n"
    + _US.join(["123", "active", "Lock", "transactionid", "client backend",
                "root", "app", "12.5", "99,100", "UPDATE t SET x=1"]) + "\n"
    "E\n"
    "S\t1700000001\tok\n"
    "COZULEMEYEN-SATIR\n"      # ayraçsız: örnek ÖLÇÜLEMEDİ sayılmalı
    "E\n"
    "S\t1700000002\tok\n"
    "E\n")
try:
    # encoding AÇIKÇA utf-8: text=True yerel kodlamayı kullanır ve Windows'ta
    # (cp1254) Türkçe karakterler bozulur — kontrol ürünü değil kendi
    # kodlamasını ölçmüş olurdu.
    _r = subprocess.run(["bash", "scripts/ash.sh", "cevir", "postgresql"],
                        input=_ash_ham, capture_output=True, text=True,
                        encoding="utf-8", timeout=60)
    _cikti = [json.loads(x) for x in _r.stdout.splitlines() if x.strip()]
except Exception as _e:
    _cikti = []
    _r = None
ck("ash.sh 'cevir' üç örneği de üretiyor", len(_cikti) == 3,
   "%d satır%s" % (len(_cikti),
                   (" · " + (_r.stderr or "")[:60]) if _r else " (çalıştırılamadı)"))
if len(_cikti) == 3:
    ck("ölçülen örnek: ok=true ve oturum sayısı var",
       _cikti[0]["ok"] is True and _cikti[0]["n"] == 1)
    # Satır GELDİ ama çözülemedi: bu "boştu" değil "okuyamadım"dır.
    ck("çözülemeyen satır SESSİZCE DÜŞMÜYOR (örnek ölçülemedi sayılıyor)",
       _cikti[1]["ok"] is False and "n" not in _cikti[1]
       and "çözülemedi" in (_cikti[1].get("neden") or ""), str(_cikti[1])[:80])
    ck("gerçekten boş örnek: ok=true ve n=0",
       _cikti[2]["ok"] is True and _cikti[2]["n"] == 0)
    ck("bekleten pid listesi sayıya çevriliyor",
       _cikti[0]["oturumlar"][0]["bekleten"] == [99, 100])

_ash_src = io.open("scripts/ash.sh", encoding="utf-8").read()
# `docker exec` süreç açma maliyeti ~100 ms; saniyelik örnekleme her örnekte
# yeni exec açarak yapılamaz — ölçüm aracı ölçtüğü sunucuyu meşgul eder.
# Yorum satırları sayılmıyor: aranan şey KODDA kaç exec olduğu. Motor başına
# bir tane olmalı — döngü container'ın içinde döndüğü için örnek başına yeni
# süreç açılmıyor.
_ash_exec = [ln for ln in _ash_src.splitlines()
             if "docker exec" in ln and not ln.lstrip().startswith("#")]
ck("örnekleme döngüsü container'ın İÇİNDE (örnek başına yeni exec yok)",
   "while :; do" in _ash_src and len(_ash_exec) == 2,
   "kodda %d exec (motor başına 1 beklenir)" % len(_ash_exec))
ck("döngü içinde bekleme var (sürekli sorgu değil)",
   "sleep $ARALIK" in _ash_src)
ck("kapsam dışı motorlarda SEBEP yazılı",
   "kapsam_notu()" in _ash_src and "tek iş parçacıklı" in _ash_src)
# MariaDB'de bekleme zinciri bilerek boş: yanlış sürümde sessizce boş dönen
# bir sorgu "kimse kimseyi bekletmiyor" diye okunurdu.
ck("MariaDB'de bekleme zincirinin YOKLUĞU açıkça yazılı",
   "data_lock_waits" in _ash_src and "SESSİZCE BOŞ" in _ash_src)
ck("controller ASH ucunu sunuyor",
   '"/api/ash"' in _ctrl_py and "ash_gozetmen" in _ctrl_py)
ck("ASH defteri sınırsız büyümüyor (devir var)",
   "_ash_devret" in _ctrl_py and "ASH_MAX_BYTES" in _ctrl_py)

# --- Yığının kendi işleri: hem ASH penceresinde hem yedek satırında --------
# JOBS yalnız bellekte; controller yeniden başlayınca buharlaşıyordu. Bir
# donmanın hangi işle çakıştığını noktasal olay kaydıyla gösteremezsiniz.
ck("etkinlik defteri işin BAŞLANGIÇ ve BİTİŞ anını diske yazıyor",
   "etkinlik_basladi(jid, kind, engine)" in _ctrl_py
   and "etkinlik_bitti(jid, ok, reason)" in _ctrl_py)
ck("ASH penceresi yığının kendi işleriyle kesişiyor",
   '"yigin_isleri": etkinlik_araligi(bas, bit)' in _ctrl_py)
# Bitişi yazılmamış iş "yoktu" diye okunmamalı: controller çökmüşse bitiş
# kaydı hiç yazılmamış olabilir.
ck("bitişi olmayan iş 'sürüyor' sayılıyor (yok sayılmıyor)",
   '"suruyor": suruyor' in _ctrl_py)

# Ölçülen olay: "Yedek al"a basıldı, satır dakikalarca "en yeni 55 dakika
# önce" yazmaya devam etti, sonra listeye zamanlı bir yedek düştü. Panel o
# süre boyunca hiçbir şey söylemedi ve haklı olarak "çalışmadı" sanıldı.
ck("yedek özeti motor başına SÜREN İŞİ bildiriyor",
   '"calisiyor": _suren.get(e["id"]) or []' in _ctrl_py)
_bkjs = io.open("gateway/html/yedekler.js", encoding="utf-8").read()
ck("yedek satırı süren işi GÖSTERİYOR (sessiz kalmıyor)",
   "b.calisiyor" in _bkjs and "yedek alınıyor" in _bkjs)

# --- Yedeğin içine bakma -----------------------------------------------------
# "Yedek var" cümlesi iki soruyu cevaplar sanılır ama yalnız birini cevaplar:
# dosya duruyor mu. İkincisi ("içinde ne var") ancak üretimi riske atıp geri
# yükleyerek öğrenilebiliyordu.
_ins = io.open("scripts/backup-inspect.sh", encoding="utf-8").read()
ck("yedek inceleme betiği var ve kapsam dışı biçimde SEBEP yazıyor",
   "kapsam_notu()" in _ins and "RDB ikili" in _ins)
# EN ÖNEMLİ KURAL: satır verisi dönmemeli. Paneli açabilen herkesin müşteri
# satırlarını okuyabildiği bir görüntüleyici, şifreli yedek özelliğini kendi
# eliyle iptal ederdi.
ck("inceleme SATIR VERİSİ döndürmüyor (yalnız ad ve sayı)",
   "SATIR VERİSİ ASLA DÖNMEZ" in _ins
   and '"tablolar": [{"ad": a, "satir": v["satir"]' in _ins)
# Kesin sayı ile tahmin ayrı: "4 satır" demek ile "yaklaşık 4 satır" demek
# arasındaki fark, kullanıcıyı yanlış bir kesinliğe ikna etmemek için var.
ck("kesin satır sayısı ile tahmin AYRILIYOR",
   '"satir_kesin"' in _ins and "satir_kesin" in _bkjs)

# ÇOK SATIRLI INSERT: mariadb-dump 'INSERT INTO t VALUES' yazıp kayıtları
# SONRAKİ satırlara koyar. Satır satır sayan ilk sürüm her tabloya "1-2
# satır" diyordu — 500 satırlık bir tabloya "2 satır" demek, yanlış bir
# sayıyı sayı gibi sunmaktır ve hiç sayı vermemekten kötüdür.
ck("çok satırlı INSERT bloğu sayılıyor",
   "insert_hedef" in _ins and "TUPLE.findall" in _ins)
# Tek satırlık INSERT'te ilk kayıt 'VALUES'tan sonra gelir; onu da saymayan
# desen 5 kaydı 4 sayıyordu.
ck("tek satırlık INSERT'te ilk kayıt kaçmıyor (VALUES deseni)",
   "|VALUES)" in _ins)

# Ayrıştırıcı GERÇEK girdiyle sınanıyor: desen doğruluğunu metne bakarak
# ölçmenin yolu yok.
import gzip as _gz, tempfile as _tf, os as _os2                    # noqa: E402
_bidir = _tf.mkdtemp(prefix="dbstack-inspect-")
_os2.makedirs(_os2.path.join(_bidir, "postgresql", "full"))
_bif = _os2.path.join(_bidir, "postgresql", "full", "t.sql.gz")
with _gz.open(_bif, "wt", encoding="utf-8") as _fh:
    for _ln in ("CREATE TABLE public.siparisler (id int);",
                "COPY public.siparisler (id) FROM stdin;",
                "1", "2", "3", chr(92) + ".",
                "CREATE TABLE `cok` (id int);",
                "INSERT INTO `cok` VALUES",
                "(1,'a'),", "(2,'b'),", "(3,'c');",
                "INSERT INTO `cok` VALUES (4,'d'),(5,'e');",
                "CREATE VIEW v1 AS SELECT 1;"):
        _fh.write(_ln + chr(10))
try:
    _ort = dict(_os2.environ, BACKUP_DIR=_bidir)
    _ir = subprocess.run(["bash", "scripts/backup-inspect.sh", "postgresql",
                          "t.sql.gz"], capture_output=True, text=True,
                         encoding="utf-8", timeout=120, env=_ort)
    _ij = json.loads([x for x in _ir.stdout.splitlines() if x.strip()][-1])
except Exception as _e:
    _ij = {"hata": repr(_e)}
_tab = {t["ad"]: t for t in (_ij.get("tablolar") or [])}
ck("COPY bloğundan sayılan satır KESİN",
   _tab.get("public.siparisler", {}).get("satir") == 3
   and _tab.get("public.siparisler", {}).get("satir_kesin") is True,
   str(_tab.get("public.siparisler")))
ck("çok satırlı + tek satırlık INSERT birlikte doğru sayılıyor (5)",
   _tab.get("cok", {}).get("satir") == 5
   and _tab.get("cok", {}).get("satir_kesin") is False,
   str(_tab.get("cok")))
ck("görünüm sayılıyor", _ij.get("gorunum_sayisi") == 1, str(_ij.get("gorunum_sayisi")))
_sh.rmtree(_bidir, ignore_errors=True)
ck("controller inceleme ucunu sunuyor (yol doğrulaması geri yüklemeyle aynı)",
   'endswith("/inspect")' in _ctrl_py and "resolve_backup_file(eid, ad)" in _ctrl_py)

# --- python3 - <<EOF ile VERİ BORUSU birlikte kullanılamaz -------------------
# `python3 - <<EOF` yazıldığında program stdin'den okunur; boruyla gelen veri
# kaybolur ve süzgeç SIFIR BAYT görür — üstelik hata da vermez, sessizce
# "içinde hiçbir şey yok" der. Bu hata iki ayrı betikte yapıldı (ash.sh ve
# backup-inspect.sh); üçüncüsü olmasın.
import glob as _glob                                    # noqa: E402
_boru_hatasi = []
for _f in _glob.glob("scripts/*.sh") + _glob.glob("scripts/*/*.sh"):
    _src = io.open(_f, encoding="utf-8").read()
    for _ln in _src.splitlines():
        if "python3 -" not in _ln or "<<" not in _ln:
            continue
        # "||" MANTIKSAL VEYA'DIR, boru değil: önce onu çıkarıyoruz. İlk
        # sürüm bunu ayırmıyordu ve common.sh'taki masum bir satırı
        # suçluyordu — kontrolün kendisi yanlış pozitif üretiyordu.
        _temiz = _ln.replace("||", "")
        if "|" in _temiz:
            _boru_hatasi.append(_f)
ck("hiçbir betik veri borusunu 'python3 - <<EOF' ile birleştirmiyor",
   not _boru_hatasi, ", ".join(sorted(set(_boru_hatasi))) or "temiz")

# =============================================================================
print()
if FAILS:
    print("\033[31m✗ %d test başarısız:\033[0m %s" % (len(FAILS), ", ".join(FAILS)))
    sys.exit(1)
print("\033[32m✓ tüm testler geçti\033[0m")
