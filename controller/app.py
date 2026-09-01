#!/usr/bin/env python3
"""
databases-stack — kontrol düzlemi.

Dashboard'daki düğmelerin arkasındaki servis. Üç iş yapar:

  1) AKTİVASYON: `docker compose --profile <motor> up -d <servisler>` çalıştırır
     (K8s backend'inde: StatefulSet'i 0 ↔ 1 replikaya ölçekler).

  2) BOYUTLANDIRMA: motoru açmadan ÖNCE host'un gerçek RAM/disk durumuna bakar.
     Bütçeye sığmıyorsa açmayı REDDEDER; sığıyorsa container limitini ve motorun
     kendi iç ayarlarını (buffer pool, JVM heap, WiredTiger cache, max_connections…)
     o bütçeden türetip state/tuning.env'e yazar. Böylece 4 GB'lık bir makinede
     16 GB'lık MariaDB açılmaya çalışılmaz; 128 GB'lık makinede de 1 GB'da kalmaz.

  3) OTOMATİK DEVİR: ana kopyayı izler. Üst üste birkaç kez yanıt vermezse eski
     ana kopyayı DURDURUR (split-brain koruması), yedeği yükseltir ve gateway'in
     yönlendirme tablosunu yeniden yazar — uygulamaların bağlantı adresi
     değişmeden yeni ana kopyaya gitmeye başlar.

Harici Python bağımlılığı yoktur (yalnız stdlib).
"""

import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import uuid

# =============================================================================
# YAPILANDIRMA
# =============================================================================
BACKEND = os.environ.get("BACKEND", "docker")
PROJECT = os.environ.get("COMPOSE_PROJECT", "databases-stack")
STACK_DIR = os.environ.get("STACK_DIR", "").strip()
TOKEN = os.environ.get("CONTROLLER_TOKEN", "")
CATALOG_PATH = os.environ.get("CATALOG_PATH", "/project/catalog.json")
STATE_DIR = os.environ.get("STATE_DIR", "/project/state")
PROJECT_DIR = "/project"
COMPOSE_FILE = "/project/docker-compose.yml"
OVERRIDE_DIR = "/project/overrides"
LISTEN_PORT = int(os.environ.get("PORT", "8000"))

K8S_NAMESPACE = os.environ.get("K8S_NAMESPACE", "databases-stack")

STATE_FILE = os.path.join(STATE_DIR, "state.json")
TUNING_JSON = os.path.join(STATE_DIR, "tuning.json")
TUNING_ENV = os.path.join(STATE_DIR, "tuning.env")

# Çekirdek servislerin (gateway + controller + adminer) sabit bellek payı.
CORE_RESERVE_MB = 448
# İşletim sistemi + page cache payı. DB dosyaları page cache'ten okunur; bu payı
# kısmak diskten okumayı artırır, o yüzden cömert bırakıldı.
OS_RESERVE_RATIO = 0.20
OS_RESERVE_MIN_MB = 1024
# Bir motoru açmak için gereken asgari boş disk.
MIN_FREE_DISK_MB = 2048

SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")


def log(*a):
    print("[controller]", *a, flush=True)


# =============================================================================
# KATALOG
# =============================================================================
class Catalog:
    """catalog.json'u okur ve değiştiğinde yeniden yükler."""

    def __init__(self, path):
        self.path = path
        self._mtime = 0
        self._data = {"engines": []}
        self.reload()

    def reload(self):
        try:
            m = os.path.getmtime(self.path)
            if m != self._mtime:
                with open(self.path, encoding="utf-8") as f:
                    self._data = json.load(f)
                self._mtime = m
        except Exception as e:  # katalog bozuksa son iyi kopyayla devam et
            log("katalog okunamadı:", e)
        return self._data

    @property
    def data(self):
        return self.reload()

    @property
    def engines(self):
        return self.data.get("engines", [])

    def engine(self, eid):
        for e in self.engines:
            if e["id"] == eid:
                return e
        return None


CATALOG = Catalog(CATALOG_PATH)


# =============================================================================
# DURUM DOSYALARI
# =============================================================================
def _read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def _write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)


def load_state():
    return _read_json(STATE_FILE, {"profiles": [], "overrides": []})


def save_state(st):
    st["profiles"] = sorted(set(st.get("profiles", [])))
    st["overrides"] = sorted(set(st.get("overrides", [])))
    st["updated_at"] = int(time.time())
    _write_json(STATE_FILE, st)


def load_tuning():
    return _read_json(TUNING_JSON, {})


def save_tuning(tun):
    """tuning.json'u yazar ve compose'un --env-file ile okuduğu .env'i render eder."""
    _write_json(TUNING_JSON, tun)
    lines = [
        "# OTOMATİK ÜRETİLDİ — elle düzenlemeyin.",
        "# controller her aktivasyonda host RAM'ine göre yeniden hesaplar.",
        "# compose bunu `--env-file .env --env-file state/tuning.env` ile okur;",
        "# sonraki dosya öncekini ezer, yani buradaki değerler .env'i geçersiz kılar.",
        "",
    ]
    for eid in sorted(tun):
        lines.append("# --- %s ---" % eid)
        for k in sorted(tun[eid]):
            lines.append("%s=%s" % (k, tun[eid][k]))
        lines.append("")
    os.makedirs(os.path.dirname(TUNING_ENV), exist_ok=True)
    tmp = TUNING_ENV + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    os.replace(tmp, TUNING_ENV)


# =============================================================================
# HOST KAYNAKLARI
# =============================================================================
def host_memory_mb():
    """Boyutlandırmanın dayandığı kapasite (toplam, kullanılabilir) MB.

    Docker: /proc/meminfo container içinden de HOST değerlerini gösterir —
    istediğimiz tam olarak budur.

    Kubernetes: pod'un gördüğü node değil, EN BÜYÜK node'un allocatable'ı
    esas alınır. Bir StatefulSet pod'u tek bir node'a sığmak zorundadır;
    cluster'ın toplam RAM'ine göre boyutlandırmak, hiçbir node'a sığmayan bir
    limit üretip pod'u sonsuza dek Pending'de bırakırdı.
    """
    if BACKEND == "kubernetes":
        mb = _k8s_largest_node_mb()
        if mb:
            return mb
    total = avail = 0
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    avail = int(line.split()[1]) // 1024
    except Exception as e:
        log("meminfo okunamadı:", e)
    return total, avail


def _parse_k8s_quantity(q):
    """K8s bellek birimlerini MB'ye çevirir (Ki/Mi/Gi/K/M/G ve düz bayt)."""
    q = str(q).strip()
    units = {"Ki": 1 / 1024.0, "Mi": 1.0, "Gi": 1024.0, "Ti": 1024.0 * 1024,
             "K": 1000.0 / (1024 * 1024), "M": 1e6 / (1024 * 1024),
             "G": 1e9 / (1024 * 1024)}
    for suf in ("Ki", "Mi", "Gi", "Ti", "K", "M", "G"):
        if q.endswith(suf):
            try:
                return int(float(q[:-len(suf)]) * units[suf])
            except ValueError:
                return 0
    try:
        return int(int(q) / (1024 * 1024))
    except ValueError:
        return 0


def _k8s_largest_node_mb():
    rc, out, _ = run(["kubectl", "get", "nodes", "-o",
                      "jsonpath={range .items[*]}{.status.allocatable.memory}{'\\n'}{end}"],
                     timeout=30)
    if rc != 0 or not out.strip():
        return None
    sizes = [_parse_k8s_quantity(x) for x in out.split() if x]
    sizes = [s for s in sizes if s > 0]
    if not sizes:
        return None
    biggest = max(sizes)
    return biggest, biggest  # allocatable zaten "kullanılabilir" demektir


def host_cpus():
    try:
        return os.cpu_count() or 1
    except Exception:
        return 1


def disk_free_mb(path=PROJECT_DIR):
    try:
        st = os.statvfs(path)
        return (st.f_bavail * st.f_frsize) // (1024 * 1024)
    except Exception:
        return -1


# =============================================================================
# DOCKER YARDIMCILARI
# =============================================================================
def run(cmd, timeout=900, env=None):
    """Kabuk YOK (shell=False) — argümanlar liste olarak geçer, enjeksiyon olamaz."""
    e = dict(os.environ)
    if env:
        e.update(env)
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=e)
    return p.returncode, p.stdout, p.stderr


_CC_LOCK = threading.Lock()
_CC_CACHE = {"at": 0.0, "data": []}
_CC_TTL = 2.0


def docker_containers(force=False):
    """Projeye ait container'lar (önbellekli).

    Dashboard 5 saniyede bir /api/status + /api/plans çağırıyor; plan hesabı
    motor başına container listesi istiyor. Önbellek olmadan her yenilemede
    ~25 docker çağrısı yapılırdı. 2 saniyelik TTL hem güncel hem ucuz.
    """
    with _CC_LOCK:
        if not force and (time.time() - _CC_CACHE["at"]) < _CC_TTL:
            return _CC_CACHE["data"]
    data = _docker_containers_uncached()
    with _CC_LOCK:
        _CC_CACHE["at"] = time.time()
        _CC_CACHE["data"] = data
    return data


def _k8s_workloads():
    """Docker'daki container listesinin K8s karşılığı — aynı sözlük biçiminde
    döner, böylece plan/status kodu iki backend için de aynı kalır."""
    tmpl = ("{range .items[*]}{.metadata.name}{'\\t'}{.spec.replicas}{'\\t'}"
            "{.status.readyReplicas}{'\\t'}"
            "{.spec.template.spec.containers[0].resources.limits.memory}{'\\n'}{end}")
    rc, out, _ = run(["kubectl", "-n", K8S_NAMESPACE, "get", "statefulsets",
                      "-o", "jsonpath=" + tmpl], timeout=30)
    if rc != 0:
        return []
    res = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        name, desired, ready, mem = parts[0], parts[1], parts[2], parts[3]
        running = (desired or "0").strip() not in ("", "0")
        res.append({
            "name": name, "service": name,
            "status": "running" if running else "exited",
            "health": "healthy" if (ready or "0").strip() not in ("", "0") else "starting",
            "memory_mb": _parse_k8s_quantity(mem) if mem else 0,
        })
    return res


def _docker_containers_uncached():
    if BACKEND == "kubernetes":
        return _k8s_workloads()
    rc, out, _ = run(
        ["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=" + PROJECT,
         "--format", "{{.ID}}"], timeout=30)
    ids = [x for x in out.split() if x]
    if rc != 0 or not ids:
        return []
    tmpl = ("{{.Name}}\t{{.State.Status}}\t"
            "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\t"
            "{{.HostConfig.Memory}}\t"
            "{{index .Config.Labels \"com.docker.compose.service\"}}")
    rc, out, _ = run(["docker", "inspect", "--format", tmpl] + ids, timeout=60)
    res = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        name, status, health, mem, service = parts
        try:
            mem_mb = int(mem) // (1024 * 1024)
        except ValueError:
            mem_mb = 0
        res.append({"name": name.lstrip("/"), "service": service, "status": status,
                    "health": health, "memory_mb": mem_mb})
    return res


def compose_base():
    """compose çağrılarının ortak ön eki (override dosyaları dahil)."""
    cmd = ["docker", "compose", "--project-directory", PROJECT_DIR, "-f", COMPOSE_FILE]
    for name in load_state().get("overrides", []):
        path = os.path.join(OVERRIDE_DIR, name + ".yml")
        if os.path.exists(path):
            cmd += ["-f", path]
    cmd += ["--env-file", os.path.join(PROJECT_DIR, ".env")]
    if os.path.exists(TUNING_ENV):
        cmd += ["--env-file", TUNING_ENV]
    cmd += ["-p", PROJECT]
    return cmd


def preflight():
    """Aktivasyonun mümkün olup olmadığını erkenden ve anlaşılır şekilde söyler."""
    if BACKEND == "kubernetes":
        if not shutil.which("kubectl"):
            return "kubectl bulunamadı"
        return None
    if not os.path.exists("/var/run/docker.sock"):
        return "docker soketi bağlı değil (/var/run/docker.sock)"
    if not STACK_DIR.startswith("/"):
        return ("STACK_DIR mutlak bir yol olmalı (şu an: %r). ./install.sh "
                "bunu .env'e yazar; compose'un bind-mount yolları buna bağlı."
                % STACK_DIR)
    return None


# =============================================================================
# BOYUTLANDIRMA MOTORU
# =============================================================================
def _clamp(v, lo, hi):
    if lo is not None:
        v = max(v, lo)
    if hi is not None:
        v = min(v, hi)
    return v


def _fmt(value_mb, fmt):
    """Hesaplanan MB değerini motorun beklediği yazıma çevirir."""
    v = int(value_mb)
    if fmt == "M":
        return "%dM" % v
    if fmt == "MB":
        return "%dMB" % v
    if fmt == "m":
        return "%dm" % v
    if fmt == "mb":
        return "%dmb" % v
    if fmt == "bytes":
        return str(v * 1024 * 1024)
    if fmt in ("int", "int_mb"):
        return str(v)
    if fmt == "java":
        return "-Xms%dm -Xmx%dm" % (v, v)
    if fmt == "G_half":
        # WiredTiger cache GB ister; 0.25 tabanına yuvarlanır (MongoDB minimumu).
        g = max(0.25, round((v / 1024.0) * 4) / 4.0)
        return ("%g" % g)
    return str(v)


def compute_tuning(engine, limit_mb):
    """Container limitinden motorun iç ayarlarını türetir."""
    spec = engine.get("resources", {}).get("tuning", [])
    out, scratch = {}, {}
    # 1. geçiş — limit / fraction / per_gb
    for t in spec:
        kind = t.get("kind")
        if kind == "limit":
            val = limit_mb
        elif kind == "fraction":
            val = _clamp(limit_mb * t.get("factor", 0.5), t.get("min_mb"), t.get("max_mb"))
        elif kind == "per_gb":
            val = _clamp(round(t.get("factor", 100) * limit_mb / 1024.0),
                         t.get("min"), t.get("max"))
        else:
            continue
        scratch[t["env"]] = val
        out[t["env"]] = _fmt(val, t.get("fmt", "int"))
    # 2. geçiş — başka bir ayara bağımlı olanlar
    for t in spec:
        if t.get("kind") != "workmem":
            continue
        # PostgreSQL work_mem BAĞLANTI BAŞINA ayrılır. En büyük tuzak burası:
        # work_mem × max_connections limiti aşarsa cgroup OOM gelir. Toplam
        # sorgu belleğini limitin %25'iyle sınırlayıp bağlantıya bölüyoruz.
        conns = max(1, int(scratch.get("POSTGRES_MAX_CONNECTIONS", 100)))
        val = _clamp(int((limit_mb * 0.25) / conns), 2, 64)
        out[t["env"]] = _fmt(val, t.get("fmt", "MB"))
    return out


def plan_engine(eid, requested_mb=None):
    """Bir motoru açmanın mümkün olup olmadığını ve hangi boyutla açılacağını hesaplar."""
    engine = CATALOG.engine(eid)
    if not engine:
        return {"ok": False, "reason": "Bilinmeyen motor: %s" % eid}

    res = engine.get("resources", {})
    min_mb = int(res.get("min_mb", 256))
    max_mb = int(res.get("max_mb", 8192))
    share = float(res.get("share", 0.2))
    panel_mb = int(res.get("panel_mb", 0))
    exporter_mb = int(res.get("exporter_mb", 0))
    overhead = panel_mb + exporter_mb

    total, available = host_memory_mb()
    if total <= 0:
        return {"ok": False, "reason": "Host belleği okunamadı (/proc/meminfo)"}

    # OS payı toplam RAM'i aşamaz: 512 MB'lık bir makinede "1024 MB işletim
    # sistemine ayrıldı" demek hem saçma hem de kullanıcıya yanlış bilgi verir.
    os_reserve = min(max(OS_RESERVE_MIN_MB, int(total * OS_RESERVE_RATIO)),
                     int(total * 0.6))

    # Zaten çalışan container'ların GERÇEK limit toplamı — kendi defterimize
    # değil docker'ın söylediğine bakıyoruz, böylece elle yapılan değişiklikler
    # de hesaba katılır. Bu motorun kendi servisleri hariç tutulur (yeniden
    # boyutlandırma senaryosu).
    own = set(engine.get("services", []))
    committed = 0
    for c in docker_containers():
        if c["status"] != "running":
            continue
        if c["service"] in own:
            continue
        committed += c["memory_mb"]

    budget = total - os_reserve - CORE_RESERVE_MB - committed

    # Panel (phpMyAdmin/pgAdmin/Kibana…) opsiyoneldir. Bütçe darsa onu ATLAYIP
    # veritabanının kendisini açıyoruz — küçük bir sunucuda "pgAdmin 512 MB
    # istiyor" diye PostgreSQL'i hiç açamamak saçma olurdu. Yönetim için
    # Adminer zaten her zaman ayakta (8085) ve MySQL/PostgreSQL/MSSQL'i yönetir.
    with_panel = True
    engine_budget = budget - overhead
    if engine_budget < min_mb and panel_mb > 0 and (budget - exporter_mb) >= min_mb:
        with_panel = False
        engine_budget = budget - exporter_mb

    detail = {
        "engine": eid,
        "host_total_mb": total,
        "host_available_mb": available,
        "os_reserve_mb": os_reserve,
        "core_reserve_mb": CORE_RESERVE_MB,
        "committed_mb": committed,
        "budget_mb": budget,
        "overhead_mb": overhead if with_panel else exporter_mb,
        "panel_mb": panel_mb,
        "with_panel": with_panel,
        "engine_budget_mb": engine_budget,
        "min_mb": min_mb,
        "max_mb": max_mb,
        "cpus": host_cpus(),
        "disk_free_mb": disk_free_mb(),
    }

    if detail["disk_free_mb"] >= 0 and detail["disk_free_mb"] < MIN_FREE_DISK_MB:
        detail.update(ok=False, reason=(
            "Disk yetersiz: %d MB boş, en az %d MB gerekli."
            % (detail["disk_free_mb"], MIN_FREE_DISK_MB)))
        return detail

    if engine_budget < min_mb:
        detail.update(ok=False, reason=(
            "%s en az %d MB ister (+ %d MB panel/exporter), kullanılabilir bütçe "
            "yalnız %d MB. Toplam %d MB RAM'in %d MB'ı işletim sistemine, %d MB'ı "
            "çekirdek servislere, %d MB'ı zaten açık motorlara ayrılmış durumda. "
            "Başka bir motoru durdurun ya da sunucuya RAM ekleyin."
            % (engine["name"], min_mb, overhead, max(engine_budget, 0),
               total, os_reserve, CORE_RESERVE_MB, committed)))
        return detail

    if requested_mb:
        want = int(requested_mb)
        if want > engine_budget:
            detail.update(ok=False, reason=(
                "İstenen %d MB bütçeyi aşıyor (kullanılabilir: %d MB)."
                % (want, engine_budget)))
            return detail
        limit = _clamp(want, min_mb, None)
        source = "kullanıcı"
    else:
        limit = int(_clamp(total * share, min_mb, max_mb))
        limit = min(limit, engine_budget)
        source = "otomatik"

    detail.update(ok=True, limit_mb=int(limit), source=source,
                  tuning=compute_tuning(engine, int(limit)),
                  headroom_mb=int(engine_budget - limit))
    return detail


def plan_all():
    """Tüm motorlar için plan — dashboard kartları bunu tek çağrıda alır."""
    return {"plans": {e["id"]: plan_engine(e["id"]) for e in CATALOG.engines}}


# =============================================================================
# BAĞLANTI BİLGİSİ
# =============================================================================
# Kullanıcının uygulamasını bağlayabilmesi için gereken her şeyi tek yerden
# verir. Parola içerir — bu uç yalnızca gateway'in basic auth'u + token'ın
# ardındadır; oraya erişebilen zaten phpMyAdmin/pgAdmin ile de tam yetkilidir.
def _dotenv():
    """.env'i OKUR ama SOURCE ETMEZ (içindeki keyfi kod çalışmasın).
    Tırnakları ve satır sonu \\r'yi temizler — compose da böyle yorumlar;
    aksi halde `PASS="abc"` compose'da abc, betikte "abc" olur ve parola tutmaz."""
    env = {}
    path = os.path.join(PROJECT_DIR, ".env")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip().rstrip("\r")
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                env[k.strip()] = v
    except Exception as e:
        log(".env okunamadı:", e)
    return env


def connection_info(eid):
    engine = CATALOG.engine(eid)
    env = _dotenv()
    host = env.get("STACK_HOST") or os.environ.get("STACK_HOST") or "localhost"
    conn = engine.get("connection", {})

    pw = ""
    if conn.get("password_env"):
        pw = env.get(conn["password_env"]) or env.get("DB_PASSWORD", "")
    user = conn.get("username", "")
    db = conn.get("database", "")
    port = engine["client_ports"][0]["port"]
    # .env'de port değiştirilmişse onu kullan
    for key in ("%s_PORT" % eid.upper(), "MINIO_API_PORT", "CLICKHOUSE_NATIVE_PORT"):
        if key.startswith(eid.upper()) and env.get(key):
            port = env[key]
            break

    uri = ""
    if eid == "mariadb":
        uri = "mysql://%s:%s@%s:%s/%s" % (user, pw, host, port, db)
    elif eid == "postgresql":
        uri = "postgresql://%s:%s@%s:%s/%s" % (user, pw, host, port, db)
    elif eid == "mongodb":
        uri = "mongodb://%s:%s@%s:%s/?authSource=admin" % (user, pw, host, port)
    elif eid == "redis":
        uri = "redis://:%s@%s:%s/0" % (pw, host, port)
    elif eid == "mssql":
        uri = ("Server=%s,%s;User Id=%s;Password=%s;TrustServerCertificate=True"
               % (host, port, user, pw))
    elif eid == "elasticsearch":
        uri = "http://%s:%s@%s:%s" % (user, pw, host, port)
    elif eid == "rabbitmq":
        uri = "amqp://%s:%s@%s:%s/" % (user, pw, host, port)
    elif eid == "clickhouse":
        uri = "clickhouse://%s:%s@%s:%s/%s" % (user, pw, host, port, db)
    elif eid == "neo4j":
        uri = "neo4j://%s:%s" % (host, port)
    elif eid == "kafka":
        uri = "%s:%s" % (host, port)
    elif eid == "minio":
        uri = "http://%s:%s" % (host, port)
    elif eid == "cassandra":
        uri = "%s:%s" % (host, port)

    return {"engine": eid, "host": host, "port": str(port), "username": user,
            "password": pw, "database": db, "uri": uri}


# =============================================================================
# TOPOLOJİ + YÖNLENDİRME  (otomatik failover'ın temeli)
# =============================================================================
# Uygulamalar veritabanına DOĞRUDAN değil gateway üzerinden bağlanır:
#     uygulama → gateway:3306 → (o an primary olan neyse)
# Failover'da yalnız bu yönlendirme tablosu değişir; uygulamanın bağlantı
# adresi hiç değişmez. Bu olmadan "otomatik failover" bir işe yaramaz —
# replika yükselse bile uygulama ölü sunucuya bağlanmaya devam ederdi.

TOPOLOGY_FILE = os.path.join(STATE_DIR, "topology.json")
ROUTES_FILE = os.path.join(STATE_DIR, "routes.conf")
EVENTS_FILE = os.path.join(STATE_DIR, "events.jsonl")

FAILOVER_INTERVAL = int(os.environ.get("FAILOVER_INTERVAL", "10"))     # saniye
FAILOVER_STRIKES = int(os.environ.get("FAILOVER_STRIKES", "3"))        # üst üste hata
FAILOVER_COOLDOWN = int(os.environ.get("FAILOVER_COOLDOWN", "300"))    # saniye
NOTIFY_WEBHOOK = os.environ.get("NOTIFY_WEBHOOK", "").strip()


def load_topology():
    return _read_json(TOPOLOGY_FILE, {})


def save_topology(t):
    _write_json(TOPOLOGY_FILE, t)


def current_primary(engine):
    """Bu motorun ŞU ANDAKİ primary servisi (failover sonrası replika olabilir)."""
    return load_topology().get(engine["id"], {}).get("primary", engine["primary_service"])


def standby_of(engine):
    rep = engine.get("replication", {})
    if not rep.get("replica_service"):
        return None
    prim = current_primary(engine)
    return (rep["replica_service"] if prim == engine["primary_service"]
            else engine["primary_service"])


def write_routes():
    """state/routes.conf üretir — gateway'in stream bloğu bunu include eder.

    Hedefler `map` ile bir DEĞİŞKENE atanır; nginx böylece DNS'i açılışta değil
    istek anında çözer. Sabit yazsaydık kapalı bir motor yüzünden nginx hiç
    açılmaz ve TÜM veritabanları erişilemez olurdu.
    """
    topo = load_topology()
    out = ["# OTOMATİK ÜRETİLDİ — controller yazar, elle düzenlemeyin.",
           "# Üretim zamanı: %s" % time.strftime("%Y-%m-%d %H:%M:%S"), ""]
    for e in CATALOG.engines:
        eid = e["id"]
        prim = topo.get(eid, {}).get("primary", e["primary_service"])
        rep = e.get("replication", {})
        stand = (rep.get("replica_service") if prim == e["primary_service"]
                 else e["primary_service"]) if rep.get("replica_service") else None
        for idx, r in enumerate(e.get("route", [])):
            var = "up_%s_%d" % (eid.replace("-", "_"), idx)
            out += ["map $remote_addr $%s { default %s:%d; }" % (var, prim, r["upstream_port"]),
                    "server {",
                    "    listen %d;" % r["listen"],
                    "    proxy_pass $%s;" % var,
                    "}", ""]
        # Replika portu — okuma ölçekleme için doğrudan erişim
        if stand and rep.get("replica_port"):
            var = "up_%s_standby" % eid.replace("-", "_")
            up_port = e["route"][0]["upstream_port"] if e.get("route") else rep["replica_port"]
            out += ["map $remote_addr $%s { default %s:%d; }" % (var, stand, up_port),
                    "server {",
                    "    listen %d;" % rep["replica_port"],
                    "    proxy_pass $%s;" % var,
                    "}", ""]
    os.makedirs(os.path.dirname(ROUTES_FILE), exist_ok=True)
    tmp = ROUTES_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    os.replace(tmp, ROUTES_FILE)
    return ROUTES_FILE


def reload_gateway():
    """Yönlendirme değişince nginx'i tazele. `reload` mevcut bağlantıları
    KOPARMAZ — eski worker'lar boşalana kadar çalışmaya devam eder."""
    rc, out, err = run(["docker", "exec", "gateway", "nginx", "-s", "reload"], timeout=60)
    if rc != 0:
        log("gateway reload başarısız:", (err or out).strip()[:300])
    return rc == 0


# =============================================================================
# OLAYLAR + BİLDİRİM
# =============================================================================
def record_event(kind, engine, message, level="info", **extra):
    ev = {"ts": int(time.time()), "kind": kind, "engine": engine,
          "level": level, "message": message}
    ev.update(extra)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(EVENTS_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    except Exception as e:
        log("olay yazılamadı:", e)
    log("OLAY[%s] %s: %s" % (level, engine, message))
    if NOTIFY_WEBHOOK and level in ("warning", "critical"):
        threading.Thread(target=_notify, args=(ev,), daemon=True).start()
    return ev


def _notify(ev):
    """Webhook bildirimi. Slack/Teams/Discord uyumlu olsun diye hem düz `text`
    hem de yapılandırılmış alanlar gönderilir."""
    import urllib.request
    body = json.dumps({
        "text": "[databases-stack] %s — %s" % (ev["engine"], ev["message"]),
        "event": ev,
    }).encode()
    try:
        req = urllib.request.Request(NOTIFY_WEBHOOK, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:
        log("bildirim gönderilemedi:", e)


def read_events(limit=100):
    try:
        with open(EVENTS_FILE, encoding="utf-8") as f:
            lines = f.readlines()[-limit:]
        return [json.loads(x) for x in lines if x.strip()]
    except Exception:
        return []


# =============================================================================
# FAILOVER
# =============================================================================
def script_path(kind, name):
    """scripts/<kind>/<name>.sh — PROJECT_DIR'e göre çözülür."""
    return os.path.join(PROJECT_DIR, "scripts", kind, "%s.sh" % name)


def script_env():
    """Alt betiklere verilecek ortam. Parolalar controller'ın kendi ortamında
    YOKTUR (compose ona yalnız kontrol değişkenlerini verir); .env'den okunup
    burada eklenir. Aksi halde replikasyon/failover betikleri boş parolayla
    çalışıp sessizce "Access denied" alırdı."""
    env = _dotenv()
    env.setdefault("STACK_DIR", STACK_DIR)
    return env


def auto_failover_engines():
    return set(load_state().get("auto_failover", []))


def _health_of(service):
    for c in docker_containers():
        if c["service"] == service:
            return c["status"], c["health"]
    return "absent", "none"


def perform_failover(eid, reason, jid=None):
    """Replikayı primary'ye yükseltir. Sıra kritiktir."""
    engine = CATALOG.engine(eid)
    fo = engine.get("failover", {})
    if not fo.get("supported"):
        return False, "Bu motorda failover desteklenmiyor: " + fo.get("note", "")
    if fo.get("mode") == "native":
        return False, ("%s kendi seçimini yapar; controller müdahale etmez. "
                       "Replica set üyelerini kontrol edin." % engine["name"])

    old = current_primary(engine)
    new = standby_of(engine)
    if not new:
        return False, "Replika yok — önce replikasyonu açın."

    ostat, ohealth = _health_of(old)
    nstat, nhealth = _health_of(new)
    if nstat != "running":
        return False, ("Yedek kopya (%s) çalışmıyor — yükseltilecek sağlam bir "
                       "kopya yok. Failover yapılmadı." % new)

    def jl(*m):
        if jid:
            job_log(jid, *m)
        else:
            log(*m)

    jl("FAILOVER: %s → %s  (sebep: %s)" % (old, new, reason))

    # 1) FENCE — eski primary'yi durdur. Bu adım ATLANAMAZ: iki kopya aynı anda
    #    yazma kabul ederse (split-brain) veriler ayrışır ve birleştirilemez.
    #    `docker stop` restart politikasını da bastırır, kendiliğinden geri gelmez.
    jl("1/4 eski primary fence ediliyor (durduruluyor):", old)
    run(["docker", "stop", "-t", "15", old], timeout=120)

    # 2) PROMOTE
    script = script_path("failover", fo.get("promote_script") or eid)
    if os.path.exists(script):
        jl("2/4 yükseltiliyor:", new)
        rc, out, err = run(["sh", script, "promote", new], timeout=600, env=script_env())
        jl((out + err).strip()[-3000:])
        if rc != 0:
            record_event("failover_failed", eid,
                         "Yükseltme başarısız — eski primary durduruldu, "
                         "veritabanı ŞU AN ERİŞİLEMEZ durumda.", level="critical")
            return False, "Yükseltme betiği başarısız (çıkış %d)" % rc
    else:
        return False, "Yükseltme betiği yok: " + script

    # 3) REROUTE — uygulamalar aynı adrese bağlanmaya devam eder
    jl("3/4 yönlendirme güncelleniyor")
    topo = load_topology()
    prev = topo.get(eid, {})
    topo[eid] = {"primary": new, "since": int(time.time()),
                 "failovers": int(prev.get("failovers", 0)) + 1,
                 "previous_primary": old, "reason": reason}
    save_topology(topo)
    write_routes()
    reload_gateway()

    # 4) KAYDET
    jl("4/4 tamam — yeni primary:", new)
    record_event("failover", eid,
                 "Otomatik failover: %s devre dışı, %s primary oldu. Sebep: %s"
                 % (old, new, reason),
                 level="critical", old_primary=old, new_primary=new)
    return True, None


def rebuild_standby(eid, jid=None):
    """Failover sonrası eski primary'yi yeni primary'nin REPLİKASI olarak geri alır.

    Eski primary'yi olduğu gibi başlatmak tehlikelidir: eskimiş verisiyle
    yazma kabul edebilir. Bu yüzden verisi silinip baştan senkronize edilir.
    """
    engine = CATALOG.engine(eid)
    rep = engine.get("replication", {})
    old = standby_of(engine)   # failover sonrası eski primary artık "standby" rolünde
    if not old:
        return False, "Yeniden kurulacak kopya bulunamadı"

    def jl(*m):
        job_log(jid, *m) if jid else log(*m)

    jl("Eski primary yeni primary'nin replikası olarak kuruluyor:", old)
    run(["docker", "rm", "-f", old], timeout=120)

    # Eski verinin silinmesi ZORUNLU — yoksa yeni primary ile ayrışmış geçmiş
    # birleşemez ve replikasyon tutarsız veriyle başlar.
    vol_map = {"mariadb": "mariadb_data", "mariadb-replica": "mariadb_replica_data",
               "postgresql": "postgresql_data", "postgresql-replica": "postgresql_replica_data",
               "redis": "redis_data", "redis-replica": "redis_replica_data"}
    vol = vol_map.get(old)
    if vol:
        full = "%s_%s" % (PROJECT, vol)
        jl("eski veri temizleniyor:", full)
        run(["docker", "volume", "rm", "-f", full], timeout=120)

    with ACTION_LOCK:
        rc, out, err = run(compose_base() + ["--profile", engine["profile"],
                                             "--profile", rep["profile"], "up", "-d", old],
                           timeout=1800)
    jl((out + err).strip()[-2000:])
    if rc != 0:
        return False, "Replika yeniden kurulamadı"

    script = script_path("replication", eid)
    if os.path.exists(script):
        env = script_env()
        env.update(REPLICATION_PRIMARY=current_primary(engine), REPLICATION_STANDBY=old)
        rc, out, err = run(["sh", script, "attach"], timeout=1800, env=env)
        jl((out + err).strip()[-3000:])
        if rc != 0:
            return False, "Replika primary'e bağlanamadı"

    write_routes()
    reload_gateway()
    record_event("rebuild", eid, "%s yeniden replika olarak kuruldu" % old, level="info")
    return True, None


_STRIKES = {}
_LAST_FAILOVER = {}


def failover_supervisor():
    """Arka plan denetleyicisi: primary'yi izler, ölürse replikayı yükseltir.

    Neden üst üste birkaç hata bekliyoruz: tek bir başarısız healthcheck geçici
    olabilir (yoğun anlık yük, kısa GC duraklaması). Gereksiz failover, gereksiz
    kesinti demektir — bu yüzden eşik FAILOVER_STRIKES kadar arka arkaya hatadır.
    """
    log("failover denetleyicisi başladı (her %ds, eşik %d)"
        % (FAILOVER_INTERVAL, FAILOVER_STRIKES))
    while True:
        time.sleep(FAILOVER_INTERVAL)
        try:
            enabled = auto_failover_engines()
            if not enabled:
                continue
            for eid in list(enabled):
                engine = CATALOG.engine(eid)
                if not engine or not engine.get("failover", {}).get("supported"):
                    continue
                if engine["failover"].get("mode") != "supervised":
                    continue
                stand = standby_of(engine)
                if not stand:
                    continue
                prim = current_primary(engine)
                pstat, phealth = _health_of(prim)

                healthy = (pstat == "running" and phealth in ("healthy", "none"))
                if healthy:
                    if _STRIKES.get(eid):
                        log("%s: primary toparlandı, sayaç sıfırlandı" % eid)
                    _STRIKES[eid] = 0
                    # Failover yapılmış bir motorda yükseltilmiş düğüm yeniden
                    # başlarsa standby bayrakları (--read-only, --replicaof)
                    # komut satırından geri gelir ve yazma reddedilir. Rolü
                    # burada yeniden dayatıyoruz — promote betikleri idempotent.
                    if prim != engine["primary_service"]:
                        sc = script_path("failover",
                            engine["failover"].get("promote_script") or eid)
                        if os.path.exists(sc):
                            rc, _, _ = run(["sh", sc, "check", prim], timeout=60,
                                           env=script_env())
                            if rc != 0:
                                log("%s: %s yeniden başlamış, primary rolü "
                                    "yeniden uygulanıyor" % (eid, prim))
                                run(["sh", sc, "promote", prim], timeout=300,
                                    env=script_env())
                                record_event("role_reapplied", eid,
                                             "%s yeniden başlatıldıktan sonra primary "
                                             "rolü yeniden uygulandı" % prim,
                                             level="warning")
                    continue

                _STRIKES[eid] = _STRIKES.get(eid, 0) + 1
                log("%s: primary sağlıksız (%s/%s) — %d/%d"
                    % (eid, pstat, phealth, _STRIKES[eid], FAILOVER_STRIKES))
                if _STRIKES[eid] < FAILOVER_STRIKES:
                    continue

                # Ard arda failover döngüsüne girmemek için bekleme süresi
                if time.time() - _LAST_FAILOVER.get(eid, 0) < FAILOVER_COOLDOWN:
                    continue

                _STRIKES[eid] = 0
                _LAST_FAILOVER[eid] = time.time()
                jid = new_job("failover", eid)
                okk, reason = perform_failover(
                    eid, "primary %d kez üst üste sağlıksız (%s)" % (FAILOVER_STRIKES, phealth),
                    jid)
                job_done(jid, okk, reason)
        except Exception as e:
            log("denetleyici hatası:", repr(e))


# =============================================================================
# İŞLER (uzun süren aktivasyonlar arka planda çalışır)
# =============================================================================
JOBS = {}
JOBS_LOCK = threading.Lock()
ACTION_LOCK = threading.Lock()  # aynı anda tek compose çağrısı


def new_job(kind, engine):
    jid = uuid.uuid4().hex[:12]
    with JOBS_LOCK:
        JOBS[jid] = {"id": jid, "kind": kind, "engine": engine, "state": "running",
                     "log": [], "started": time.time()}
        # Eski işleri budayalım, bellek sızmasın.
        if len(JOBS) > 50:
            for k in sorted(JOBS, key=lambda x: JOBS[x]["started"])[:10]:
                if JOBS[k]["state"] != "running":
                    JOBS.pop(k, None)
    return jid


def job_log(jid, *msg):
    line = " ".join(str(m) for m in msg)
    log("[%s]" % jid, line)
    with JOBS_LOCK:
        if jid in JOBS:
            JOBS[jid]["log"].append(line)


def job_done(jid, ok, reason=None, extra=None):
    with JOBS_LOCK:
        if jid in JOBS:
            JOBS[jid]["state"] = "done" if ok else "failed"
            JOBS[jid]["finished"] = time.time()
            if reason:
                JOBS[jid]["reason"] = reason
            if extra:
                JOBS[jid].update(extra)


# =============================================================================
# EYLEMLER
# =============================================================================
def _k8s_scale(engine, replicas, limit_mb=None, tuning=None):
    """K8s karşılığı: 'aktif et' = replicas 0→1, 'durdur' = 1→0.

    Boyutlandırma Docker'daki ile aynı mantığı izler; burada container limiti
    yerine pod'un resources.limits/requests'i ve motorun iç ayarlarını taşıyan
    env değişkenleri güncellenir.
    """
    name = engine["primary_service"]
    if replicas > 0 and limit_mb:
        run(["kubectl", "-n", K8S_NAMESPACE, "set", "resources",
             "statefulset/" + name, "--containers", name,
             "--limits", "memory=%dMi" % limit_mb,
             "--requests", "memory=%dMi" % limit_mb], timeout=120)
        if tuning:
            # Motorun kendi ayarları (JVM heap, buffer pool…) env üzerinden gider.
            pairs = ["%s=%s" % (k, v) for k, v in sorted(tuning.items())
                     if not k.endswith("_MEM_LIMIT")]
            if pairs:
                run(["kubectl", "-n", K8S_NAMESPACE, "set", "env",
                     "statefulset/" + name] + pairs, timeout=120)
    return run(["kubectl", "-n", K8S_NAMESPACE, "scale", "statefulset", name,
                "--replicas", str(replicas)], timeout=120)


def do_activate(jid, eid, requested_mb=None):
    try:
        engine = CATALOG.engine(eid)
        err = preflight()
        if err:
            return job_done(jid, False, err)

        job_log(jid, "kaynak planı hesaplanıyor…")
        p = plan_engine(eid, requested_mb)
        if not p.get("ok"):
            job_log(jid, "REDDEDİLDİ:", p.get("reason"))
            return job_done(jid, False, p.get("reason"), {"plan": p})

        job_log(jid, "plan: limit=%d MB (%s), bütçe sonrası kalan=%d MB"
                % (p["limit_mb"], p["source"], p["headroom_mb"]))
        for k, v in sorted(p["tuning"].items()):
            job_log(jid, "  %s=%s" % (k, v))

        tun = load_tuning()
        tun[eid] = p["tuning"]
        save_tuning(tun)
        job_log(jid, "tuning.env yazıldı")

        if BACKEND == "kubernetes":
            rc, out, errout = _k8s_scale(engine, 1, p["limit_mb"], p["tuning"])
            job_log(jid, out.strip() or errout.strip())
            return job_done(jid, rc == 0, None if rc == 0 else errout.strip(), {"plan": p})

        services = list(engine["services"])
        if not p.get("with_panel", True):
            skip = set((engine.get("panel") or {}).get("services", []))
            services = [s for s in services if s not in skip]
            job_log(jid, "NOT: bellek dar olduğu için web paneli açılmadı "
                         "(%s). Veritabanını Adminer'dan yönetebilirsiniz: "
                         "https://<sunucu>:8085" % ", ".join(sorted(skip)))

        with ACTION_LOCK:
            # Servisler AÇIKÇA isimlendirilir. İsim vermeden `--profile X up -d`
            # demek profilsiz servisleri de (controller dahil!) yeniden yaratır —
            # controller kendini öldürürdü.
            cmd = compose_base() + ["--profile", engine["profile"], "up", "-d",
                                    "--remove-orphans"] + services
            job_log(jid, "$", " ".join(cmd[-8:]))
            rc, out, errout = run(cmd, timeout=1800)
        for line in (out + errout).splitlines()[-40:]:
            job_log(jid, line)
        if rc != 0:
            return job_done(jid, False, "compose başarısız (çıkış %d)" % rc, {"plan": p})

        st = load_state()
        st["profiles"] = list(set(st.get("profiles", [])) | {engine["profile"]})
        save_state(st)
        job_done(jid, True, None, {"plan": p})
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))


def do_deactivate(jid, eid):
    try:
        engine = CATALOG.engine(eid)
        err = preflight()
        if err:
            return job_done(jid, False, err)

        if BACKEND == "kubernetes":
            rc, out, errout = _k8s_scale(engine, 0)
            job_log(jid, out.strip() or errout.strip())
            return job_done(jid, rc == 0, None if rc == 0 else errout.strip())

        # Replikası açıksa önce onu indir — primary'siz replika anlamsız.
        rep = engine.get("replication", {})
        targets = list(engine["services"])
        profiles = [engine["profile"]]
        if rep.get("profile") and rep["profile"] in load_state().get("profiles", []):
            targets.append(rep["replica_service"])
            profiles.append(rep["profile"])

        with ACTION_LOCK:
            args = []
            for pr in profiles:
                args += ["--profile", pr]
            job_log(jid, "durduruluyor:", ", ".join(targets))
            rc, out, errout = run(compose_base() + args + ["stop"] + targets, timeout=600)
            job_log(jid, (out + errout).strip()[-2000:])
            # Container'ı da siliyoruz: veriler ADLANDIRILMIŞ volume'larda durur,
            # silinmez. Böylece `docker ps -a` temiz kalır ve gateway kapalı
            # motoru DNS'te bulamayıp temiz bir "pasif" sayfası gösterir.
            rc2, out2, err2 = run(compose_base() + args + ["rm", "-f"] + targets, timeout=600)
            job_log(jid, (out2 + err2).strip()[-2000:])

        st = load_state()
        st["profiles"] = [x for x in st.get("profiles", []) if x not in profiles]
        save_state(st)
        tun = load_tuning()
        tun.pop(eid, None)  # bir dahaki açılışta güncel koşullara göre yeniden planla
        save_tuning(tun)
        job_done(jid, rc == 0, None if rc == 0 else "stop başarısız")
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))


def do_replication(jid, eid, enable):
    try:
        engine = CATALOG.engine(eid)
        rep = engine.get("replication", {})
        if rep.get("mode") in ("unsupported", "native-cluster"):
            return job_done(jid, False,
                            "Bu motorda primary-replica desteklenmiyor: " + rep.get("note", ""))
        if BACKEND == "kubernetes":
            n = 2 if enable else 1
            rc, out, errout = _k8s_scale(engine, n)
            job_log(jid, out.strip() or errout.strip())
            return job_done(jid, rc == 0, None if rc == 0 else errout.strip())

        profile = rep["profile"]
        svc = rep["replica_service"]
        override = "%s-replica" % eid  # overrides/<eid>-replica.yml (varsa)

        if enable:
            if engine["profile"] not in load_state().get("profiles", []):
                return job_done(jid, False, "Önce %s motorunu aktif edin." % engine["name"])

            # Replika, devirden sonra AYNI yükü taşıyacağı için primary kadar
            # bellek ister. Yer yoksa yarıda kalmış bir kurulum bırakmak yerine
            # baştan reddediyoruz.
            prim_mb = 0
            for c in docker_containers():
                if c["service"] == engine["primary_service"] and c["status"] == "running":
                    prim_mb = c["memory_mb"]
            if prim_mb:
                p = plan_engine(eid)
                free = p.get("budget_mb", 0)
                if free < prim_mb:
                    return job_done(jid, False, (
                        "Replika ana kopya kadar bellek ister (%d MB) çünkü devirden "
                        "sonra aynı yükü taşıyacak; kullanılabilir bütçe %d MB. "
                        "Başka bir motoru durdurun ya da sunucuya RAM ekleyin."
                        % (prim_mb, max(free, 0))))
                job_log(jid, "bütçe uygun: replika %d MB alacak, %d MB kullanılabilir"
                        % (prim_mb, free))
            st = load_state()
            if os.path.exists(os.path.join(OVERRIDE_DIR, override + ".yml")):
                st["overrides"] = list(set(st.get("overrides", [])) | {override})
                save_state(st)
                job_log(jid, "override etkin:", override)

            # PRIMARY'İ ÖNCE HAZIRLA. Replika ayağa kalkar kalkmaz primary'e
            # bağlanmayı dener (PostgreSQL doğrudan pg_basebackup çeker); replikasyon
            # kullanıcısı ve pg_hba/GRANT satırı o an hazır olmazsa boşuna
            # çöküp yeniden başlar.
            script = script_path("replication", eid)
            if os.path.exists(script):
                job_log(jid, "primary hazırlanıyor…")
                rc, out, errout = run(["sh", script, "prepare"], timeout=900, env=script_env())
                job_log(jid, (out + errout).strip()[-3000:])
                if rc != 0:
                    return job_done(jid, False, "primary hazırlanamadı (çıkış %d)" % rc)

            with ACTION_LOCK:
                # MongoDB'de primary de --replSet ile yeniden başlamalı; override
                # bunu yapar, bu yüzden primary servis de listeye giriyor.
                extra = [engine["primary_service"]] if override in load_state()["overrides"] else []
                cmd = compose_base() + ["--profile", engine["profile"], "--profile", profile,
                                        "up", "-d"] + extra + [svc]
                rc, out, errout = run(cmd, timeout=1800)
            job_log(jid, (out + errout).strip()[-3000:])
            if rc != 0:
                return job_done(jid, False, "replika ayağa kalkmadı (çıkış %d)" % rc)

            # Bağlama aşaması: replika ayakta, şimdi primary'e bağlanıyor.
            if os.path.exists(script):
                job_log(jid, "replika primary'e bağlanıyor…")
                rc, out, errout = run(["sh", script, "attach"], timeout=1800, env=script_env())
                job_log(jid, (out + errout).strip()[-4000:])
                if rc != 0:
                    return job_done(jid, False, "bağlama başarısız (çıkış %d)" % rc)

            st = load_state()
            st["profiles"] = list(set(st["profiles"]) | {profile})
            save_state(st)
            return job_done(jid, True)

        # devre dışı bırak
        with ACTION_LOCK:
            args = ["--profile", engine["profile"], "--profile", profile]
            run(compose_base() + args + ["stop", svc], timeout=600)
            rc, out, errout = run(compose_base() + args + ["rm", "-f", svc], timeout=600)
        job_log(jid, (out + errout).strip()[-2000:])
        st = load_state()
        st["profiles"] = [x for x in st["profiles"] if x != profile]
        if override in st.get("overrides", []):
            st["overrides"] = [x for x in st["overrides"] if x != override]
            save_state(st)
            with ACTION_LOCK:  # primary'i override'sız haline geri al
                run(compose_base() + ["--profile", engine["profile"], "up", "-d",
                                      engine["primary_service"]], timeout=900)
        save_state(st)
        job_done(jid, True)
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))


# =============================================================================
# DURUM
# =============================================================================
def status():
    containers = {c["service"]: c for c in docker_containers()}
    st = load_state()
    tun = load_tuning()
    total, available = host_memory_mb()
    used_by_stack = sum(c["memory_mb"] for c in containers.values() if c["status"] == "running")

    topo = load_topology()
    auto_fo = auto_failover_engines()

    engines = []
    for e in CATALOG.engines:
        # Failover olduysa "primary" artık kataloğun ilk servisi olmayabilir.
        prim_name = topo.get(e["id"], {}).get("primary", e["primary_service"])
        primary = containers.get(prim_name)
        svcs = []
        for s in e["services"]:
            c = containers.get(s)
            svcs.append({"service": s,
                         "status": c["status"] if c else "absent",
                         "health": c["health"] if c else "none",
                         "memory_mb": c["memory_mb"] if c else 0})
        rep = e.get("replication", {})
        rep_svc = containers.get(rep.get("replica_service")) if rep.get("replica_service") else None
        active = bool(primary and primary["status"] == "running")
        engines.append({
            "id": e["id"],
            "active": active,
            "ready": bool(active and primary["health"] in ("healthy", "none")),
            "health": primary["health"] if primary else "none",
            "services": svcs,
            "memory_mb": primary["memory_mb"] if primary else 0,
            "tuning": tun.get(e["id"], {}),
            "replication_active": bool(rep_svc and rep_svc["status"] == "running"),
            "primary_service": prim_name,
            "failed_over": prim_name != e["primary_service"],
            "failover_count": topo.get(e["id"], {}).get("failovers", 0),
            "auto_failover": e["id"] in auto_fo,
        })

    return {
        "backend": BACKEND,
        "engines": engines,
        "profiles": st.get("profiles", []),
        "system": {
            "mem_total_mb": total,
            "mem_available_mb": available,
            "stack_committed_mb": used_by_stack,
            "cpus": host_cpus(),
            "disk_free_mb": disk_free_mb(),
            "os_reserve_mb": max(OS_RESERVE_MIN_MB, int(total * OS_RESERVE_RATIO)),
            "core_reserve_mb": CORE_RESERVE_MB,
        },
        "preflight_error": preflight(),
    }


# =============================================================================
# HTTP
# =============================================================================
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "databases-stack-controller"

    def log_message(self, fmt, *args):  # varsayılan gürültülü logger'ı sustur
        pass

    # -- yardımcılar --------------------------------------------------------
    def _send(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        if not TOKEN:
            return True  # token tanımlı değilse (geliştirme) serbest
        return self.headers.get("X-Api-Token", "") == TOKEN

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def _engine_from(self, path, idx=2):
        # /api/engines/<id>/<eylem> → strip("/") baştaki eğik çizgiyi attığı için
        # parçalar: 0=api 1=engines 2=<id> 3=<eylem>. Motor kimliği 2. sırada.
        parts = path.strip("/").split("/")
        if len(parts) <= idx:
            return None
        eid = parts[idx]
        # Katalogda olmayan hiçbir kimlik kabul edilmez → compose'a keyfi servis
        # adı geçirilemez (path traversal ve komut enjeksiyonu kapalı).
        return eid if SAFE_ID.match(eid) and CATALOG.engine(eid) else None

    # -- yönlendirme --------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/healthz":
            return self._send(200, {"ok": True})
        if not self._authed():
            return self._send(401, {"error": "yetkisiz"})
        if path == "/api/catalog":
            return self._send(200, CATALOG.data)
        if path == "/api/status":
            return self._send(200, status())
        if path == "/api/plans":
            return self._send(200, plan_all())
        if path == "/api/events":
            return self._send(200, {"events": read_events(200)})
        if path == "/api/topology":
            return self._send(200, {"topology": load_topology(),
                                    "auto_failover": sorted(auto_failover_engines())})
        if path.startswith("/api/engines/") and path.endswith("/connection"):
            eid = self._engine_from(path)
            if not eid:
                return self._send(404, {"error": "bilinmeyen motor"})
            return self._send(200, connection_info(eid))
        if path.startswith("/api/jobs/"):
            jid = path.rsplit("/", 1)[-1]
            with JOBS_LOCK:
                job = JOBS.get(jid)
            return self._send(200, job) if job else self._send(404, {"error": "iş bulunamadı"})
        if path.startswith("/api/engines/") and path.endswith("/plan"):
            eid = self._engine_from(path)
            if not eid:
                return self._send(404, {"error": "bilinmeyen motor"})
            return self._send(200, plan_engine(eid))
        if path.startswith("/api/logs/"):
            svc = path.rsplit("/", 1)[-1]
            allowed = {s for e in CATALOG.engines for s in e["services"]}
            if svc not in allowed:
                return self._send(404, {"error": "bilinmeyen servis"})
            rc, out, err = run(compose_base() + ["logs", "--tail", "200", "--no-color", svc],
                               timeout=60)
            return self._send(200, {"service": svc, "log": (out + err)[-20000:]})
        return self._send(404, {"error": "bulunamadı"})

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self._authed():
            return self._send(401, {"error": "yetkisiz"})
        body = self._body()

        if path.startswith("/api/engines/"):
            eid = self._engine_from(path)
            if not eid:
                return self._send(404, {"error": "bilinmeyen motor"})
            action = path.rstrip("/").rsplit("/", 1)[-1]

            if action == "activate":
                jid = new_job("activate", eid)
                threading.Thread(target=do_activate, daemon=True,
                                 args=(jid, eid, body.get("memory_mb"))).start()
                return self._send(202, {"job": jid})
            if action == "deactivate":
                jid = new_job("deactivate", eid)
                threading.Thread(target=do_deactivate, daemon=True, args=(jid, eid)).start()
                return self._send(202, {"job": jid})
            if action in ("replication-enable", "replication-disable"):
                jid = new_job(action, eid)
                threading.Thread(target=do_replication, daemon=True,
                                 args=(jid, eid, action.endswith("enable"))).start()
                return self._send(202, {"job": jid})

            # --- failover -------------------------------------------------
            if action == "failover":
                jid = new_job("failover", eid)

                def _run(jid=jid, eid=eid):
                    okk, reason = perform_failover(eid, "elle tetiklendi", jid)
                    job_done(jid, okk, reason)
                threading.Thread(target=_run, daemon=True).start()
                return self._send(202, {"job": jid})

            if action == "failover-auto":
                engine = CATALOG.engine(eid)
                want = bool(body.get("enabled"))
                if want and not engine.get("failover", {}).get("supported"):
                    return self._send(400, {"error": engine["failover"]["note"]})
                st = load_state()
                cur = set(st.get("auto_failover", []))
                cur.add(eid) if want else cur.discard(eid)
                st["auto_failover"] = sorted(cur)
                save_state(st)
                record_event("config", eid,
                             "Otomatik failover " + ("açıldı" if want else "kapatıldı"))
                return self._send(200, {"auto_failover": st["auto_failover"]})

            if action == "rebuild-standby":
                jid = new_job("rebuild", eid)

                def _run2(jid=jid, eid=eid):
                    okk, reason = rebuild_standby(eid, jid)
                    job_done(jid, okk, reason)
                threading.Thread(target=_run2, daemon=True).start()
                return self._send(202, {"job": jid})
        return self._send(404, {"error": "bulunamadı"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    log("backend=%s project=%s stack_dir=%s" % (BACKEND, PROJECT, STACK_DIR or "(boş)"))
    err = preflight()
    if err:
        log("UYARI — aktivasyon şu an mümkün değil:", err)
    total, avail = host_memory_mb()
    log("host: %d MB RAM (%d MB boş), %d CPU, %d MB disk"
        % (total, avail, host_cpus(), disk_free_mb()))
    log("%d motor kataloğa yüklendi" % len(CATALOG.engines))

    if BACKEND != "kubernetes":
        # Yönlendirme tablosunu açılışta üret. Gateway boş bir routes.conf ile
        # de sorunsuz açılır (nginx boş include'a kızmaz); burada doldurup
        # tazeliyoruz. Böylece tablo tek bir yerde, burada üretiliyor.
        try:
            write_routes()
            log("yönlendirme tablosu yazıldı:", ROUTES_FILE)
            threading.Timer(5.0, reload_gateway).start()
        except Exception as e:
            log("yönlendirme tablosu yazılamadı:", e)
        threading.Thread(target=failover_supervisor, daemon=True).start()

    Server(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
