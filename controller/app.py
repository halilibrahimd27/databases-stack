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
RC_TIMEOUT = 124   # kabuk geleneği: `timeout` komutu da 124 döndürür


def _as_text(v):
    """TimeoutExpired'ın stdout/stderr'i bazen bytes, bazen None gelir."""
    if v is None:
        return ""
    return v if isinstance(v, str) else v.decode("utf-8", "replace")


def run(cmd, timeout=900, env=None):
    """Kabuk YOK (shell=False) — argümanlar liste olarak geçer, enjeksiyon olamaz."""
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=e)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as ex:
        # Zaman aşımı bir SONUÇTUR, istisna değil. Eskiden bu istisna hiçbir
        # yerde yakalanmıyordu: yükseltme betiği takılınca devir thread'i
        # sessizce ölüyor, job_done hiç çağrılmıyordu — dashboard işi sonsuza
        # dek "devam ediyor" gösterirken eski primary fence edilmiş, yeni
        # primary belirsiz durumda kalıyordu. Artık hata gibi davranıyoruz:
        # çağıran yer rc'yi görüp geri alma/uyarı yollarını çalıştırabilsin.
        log("komut %d sn'de bitmedi:" % timeout, " ".join(str(c) for c in cmd)[:200])
        return (RC_TIMEOUT, _as_text(ex.stdout),
                (_as_text(ex.stderr) + "\n[controller] komut %d saniyede bitmedi "
                 "(zaman aşımı) — işlem yarıda kalmış olabilir." % timeout))


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


# =============================================================================
# METRİKLER (/metrics — Prometheus)
# =============================================================================
# Container başına GERÇEK kullanım için önce cAdvisor kullanılmıştı; modern
# Docker'da (29.x, containerd snapshotter, "overlayfs") cAdvisor'ın docker
# entegrasyonu /var/lib/docker/image/overlay2/layerdb düzenini arıyor, o düzen
# artık yok ve container başına HİÇ metrik üretmiyor — hedef "up" görünüyor
# ama seriler boş. Grafikler görünür, içleri boştur.
#
# Bunu controller'ın kendisi yayınlaması hem daha sağlam hem daha dürüst:
#   • Her Docker sürümünde ve depolama sürücüsünde çalışır.
#   • privileged bir container ve /var/lib/docker bağlaması gerektirmez.
#   • ~190 MB tasarruf.
#   • En önemlisi: sayılar, belleği DAĞITAN kodun kullandığı kaynaktan gelir.
#     "Otomatik hesap tuttu mu?" sorusunun cevabı, hesabı yapanın kendi
#     defterinden okunur; ayrı bir aracın farklı sayması kafa karıştırırdı.
_STATS_LOCK = threading.Lock()
_STATS_CACHE = {"at": 0.0, "data": {}}
_STATS_TTL = 20.0     # metrik ucu 30 sn'de bir toplanıyor; bu yeterli

_SIZE_UNITS = {"b": 1, "kb": 10**3, "mb": 10**6, "gb": 10**9, "tb": 10**12,
               "kib": 1024, "mib": 1024**2, "gib": 1024**3, "tib": 1024**4}


def _parse_size(text):
    """'123.4MiB' → bayt. Anlaşılmazsa None (metriği hiç yayınlamayız —
    uydurma bir sayı yayınlamak, eksik veriden kötüdür)."""
    m = re.match(r"^\s*([0-9.]+)\s*([A-Za-z]+)\s*$", text or "")
    if not m:
        return None
    try:
        return int(float(m.group(1)) * _SIZE_UNITS[m.group(2).lower()])
    except (ValueError, KeyError):
        return None


def container_stats(force=False):
    """Container başına anlık bellek kullanımı ve CPU yüzdesi.

    `docker stats` her çağrıda tüm container'ları örnekler ve saniyeler
    sürebilir; bu yüzden önbellekli. Ayrı bir alan olarak tutuluyor çünkü
    docker_containers() LİMİTİ okur (boyutlandırma için), burası ise GERÇEK
    KULLANIMI (izleme için) — ikisinin yan yana görülmesi bu ürünün can alıcı
    sorusunu cevaplıyor: ayrılan bellek doğru muydu?
    """
    with _STATS_LOCK:
        if not force and (time.time() - _STATS_CACHE["at"]) < _STATS_TTL:
            return _STATS_CACHE["data"]
    out = {}
    rc, sout, _ = run(["docker", "stats", "--no-stream", "--format",
                       "{{.Name}}|{{.MemUsage}}|{{.CPUPerc}}"], timeout=60)
    if rc == 0:
        for line in sout.splitlines():
            parts = line.split("|")
            if len(parts) < 3:
                continue
            name = parts[0].strip()
            used = _parse_size((parts[1].split("/")[0]).strip())
            cpu = parts[2].strip().rstrip("%")
            try:
                cpu = float(cpu)
            except ValueError:
                cpu = None
            out[name] = {"used_bytes": used, "cpu_percent": cpu}
    with _STATS_LOCK:
        _STATS_CACHE["at"] = time.time()
        _STATS_CACHE["data"] = out
    return out


def _esc(v):
    """Prometheus etiket değeri kaçışı."""
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def render_metrics():
    """Prometheus metin biçimi. Kimlik doğrulaması istemez: controller portu
    host'a açılmaz, yalnız Docker ağından erişilir (/healthz ile aynı ilke)."""
    L = []

    def add(name, help_, typ, samples):
        if not samples:
            return
        L.append("# HELP %s %s" % (name, help_))
        L.append("# TYPE %s %s" % (name, typ))
        for labels, value in samples:
            lbl = ",".join('%s="%s"' % (k, _esc(v)) for k, v in labels)
            L.append("%s{%s} %s" % (name, lbl, value) if lbl else "%s %s" % (name, value))

    # Servis → motor eşlemesi: grafiklerde container'ın hangi veritabanına ait
    # olduğu görünsün (kullanıcı "postgres-exporter" değil "PostgreSQL" arar).
    svc2eng = {}
    for e in CATALOG.engines:
        for s in e.get("services", []):
            svc2eng[s] = e
        rep = e.get("replication") or {}
        if rep.get("replica_service"):
            svc2eng[rep["replica_service"]] = e

    conts = docker_containers()
    stats = container_stats()

    used_s, limit_s, cpu_s, up_s = [], [], [], []
    for c in conts:
        eng = svc2eng.get(c["service"])
        lbl = [("service", c["service"]),
               ("engine", eng["id"] if eng else ""),
               ("engine_name", eng["name"] if eng else "")]
        up_s.append((lbl, 1 if c["status"] == "running" else 0))
        if c["status"] != "running":
            continue
        st = stats.get(c["name"]) or {}
        if st.get("used_bytes") is not None:
            used_s.append((lbl, st["used_bytes"]))
        if st.get("cpu_percent") is not None:
            cpu_s.append((lbl, st["cpu_percent"]))
        if c.get("memory_mb"):
            limit_s.append((lbl, int(c["memory_mb"]) * 1024 * 1024))

    add("dbstack_container_up", "Container calisiyor mu (1/0)", "gauge", up_s)
    add("dbstack_container_memory_bytes", "Container'in su anki bellek kullanimi",
        "gauge", used_s)
    add("dbstack_container_memory_limit_bytes",
        "Container'a AYRILAN bellek limiti (otomatik hesaplanan)", "gauge", limit_s)
    add("dbstack_container_cpu_percent", "Container'in islemci kullanimi (%)",
        "gauge", cpu_s)

    # Motor düzeyi: kullanıcı "PostgreSQL açık mı" diye bakar, "postgresql
    # container'ı running mi" diye değil.
    eng_s = []
    running = {c["service"] for c in conts if c["status"] == "running"}
    for e in CATALOG.engines:
        eng_s.append(([("engine", e["id"]), ("engine_name", e["name"])],
                      1 if e["primary_service"] in running else 0))
    add("dbstack_engine_active", "Motor acik mi (1/0)", "gauge", eng_s)

    # Bütçe defteri — boyutlandırma motorunun gördüğü sayıların ta kendisi.
    total, avail = host_memory_mb()
    committed = sum(c["memory_mb"] for c in conts if c["status"] == "running")
    os_reserve = min(max(OS_RESERVE_MIN_MB, int(total * OS_RESERVE_RATIO)),
                     int(total * 0.6)) if total > 0 else 0
    MB = 1024 * 1024
    add("dbstack_host_memory_total_bytes", "Sunucunun toplam RAM'i", "gauge",
        [([], total * MB)])
    add("dbstack_host_memory_available_bytes", "Sunucuda kullanilabilir RAM",
        "gauge", [([], avail * MB)])
    add("dbstack_memory_committed_bytes",
        "Calisan container'lara AYRILMIS toplam bellek", "gauge",
        [([], committed * MB)])
    add("dbstack_memory_budget_bytes",
        "Yeni bir motora verilebilecek bellek (toplam - OS payi - cekirdek - ayrilmis)",
        "gauge", [([], max(0, total - os_reserve - CORE_RESERVE_MB - committed) * MB)])
    add("dbstack_disk_free_bytes", "Veri diskinde bos alan", "gauge",
        [([], disk_free_mb() * MB)])

    # Devir sayacı: "gece 3'te ne oldu" sorusunun cevabı grafikte görünsün.
    topo = load_topology()
    fo_s = [([("engine", eid)], int(v.get("failovers", 0)))
            for eid, v in topo.items()]
    add("dbstack_failover_total", "Bu motorda kac kez devir yapildi", "counter", fo_s)

    return "\n".join(L) + "\n"


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
    if os.path.exists(ROLES_ENV):
        cmd += ["--env-file", ROLES_ENV]
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

    pre = engine_preconditions(eid)
    if pre:
        detail.update(ok=False, reason=pre)
        return detail

    detail.update(ok=True, limit_mb=int(limit), source=source,
                  tuning=compute_tuning(engine, int(limit)),
                  headroom_mb=int(engine_budget - limit))
    return detail


def _cpu_flags():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("flags") or line.startswith("Features"):
                    return set(line.split(":", 1)[1].split())
    except Exception:
        pass
    return set()


def engine_preconditions(eid):
    """Motora özgü, bellekten BAĞIMSIZ önkoşullar.

    Bunları aktivasyondan önce kontrol ediyoruz: aksi halde container sonsuz
    crash-loop'a girer ve kullanıcı sebebini ancak docker loglarında bulur.
    """
    if eid == "mongodb":
        ver = _dotenv().get("MONGO_VERSION", "7.0")
        if not ver.startswith("4.") and "avx" not in _cpu_flags():
            return ("MongoDB %s bu sunucuda çalışamaz: 5.0 ve sonrası CPU'da AVX "
                    "komut setini zorunlu tutar, bu işlemcide yok (eski Xeon'lar ve "
                    "bazı sanallaştırma profillerinde olmaz). Container açılışta "
                    "'Illegal instruction' ile ölür. Çözüm: .env içinde "
                    "MONGO_VERSION=4.4 ve MONGO_SHELL=mongo yapın — 4.4 bu CPU'da "
                    "sorunsuz çalışır." % ver)
    return None


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
ROLES_ENV = os.path.join(STATE_DIR, "roles.env")

FAILOVER_INTERVAL = int(os.environ.get("FAILOVER_INTERVAL", "10"))     # saniye
FAILOVER_STRIKES = int(os.environ.get("FAILOVER_STRIKES", "3"))        # üst üste hata
FAILOVER_COOLDOWN = int(os.environ.get("FAILOVER_COOLDOWN", "300"))    # saniye
# Controller açıldıktan sonra hiçbir devir kararı verilmeyen süre. Sunucu
# yeniden başladığında controller ile veritabanları BİRLİKTE kalkar; bu
# pencerede "ana kopya yanıt vermiyor" demek yanlış olur.
FAILOVER_STARTUP_GRACE = int(os.environ.get("FAILOVER_STARTUP_GRACE", "120"))
# Bir motorun "açılıyor" (health=starting) kalabileceği makul süre. Docker
# healthcheck'lerinin start_period'u en fazla 60 sn; 5 dakikayı aşan bir açılış
# artık açılış değil arızadır.
FAILOVER_STARTING_GRACE = int(os.environ.get("FAILOVER_STARTING_GRACE", "300"))
NOTIFY_WEBHOOK = os.environ.get("NOTIFY_WEBHOOK", "").strip()

_STARTED_AT = time.time()
_STARTING_SINCE = {}   # eid → healthcheck'in "starting" demeye başladığı an
_ALERTED = {}          # (eid, konu) → son bildirim zamanı (aynı uyarıyı susturur)


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
    # ⚠️ YERİNDE YAZILIYOR — geçici dosya + rename KULLANILMAZ.
    # Bu dosya gateway'e TEK DOSYA olarak bind-mount edilir ve Docker dosya
    # mount'unu INODE'a bağlar, yola değil. os.replace() yeni inode üretir;
    # container eski inode'u görmeye devam eder. Sonuç: host'ta yeni hedef
    # yazılıdır ama nginx hâlâ ölü sunucuyu çözmeye çalışır ve devirden sonra
    # bütün bağlantılar kopar. Truncate + write inode'u korur.
    with open(ROUTES_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
        f.flush()
        os.fsync(f.fileno())
    return ROUTES_FILE


def write_roles():
    """state/roles.env — hangi düğümün primary, hangisinin standby olduğunu yazar.

    Servis TANIMLARI rol taşımaz; rol bu dosyadaki env değişkenleriyle verilir.
    Devirden sonra roller yer değiştirdiğinde eski primary'yi yeni primary'nin
    yedeği olarak geri alabilmek için şart — aksi halde boş bir ikinci primary
    olarak açılır ve replikasyon hiç kurulamaz.
    """
    topo = load_topology()
    lines = ["# OTOMATİK ÜRETİLDİ — controller yazar. Replikasyon rollerini tutar.",
             "# Boş STANDBY_OF = o düğüm PRIMARY demektir.", ""]

    def emit(prim_var, rep_var, primary_svc, default_primary, default_replica, port=None):
        if primary_svc == default_primary:      # roller özgün hâlinde
            lines.append("%s=" % prim_var)
            lines.append("%s=%s" % (rep_var, default_primary))
        else:                                   # devir olmuş, roller ters
            lines.append("%s=%s" % (prim_var, default_replica))
            lines.append("%s=" % rep_var)

    for e in CATALOG.engines:
        rep = e.get("replication", {})
        if rep.get("mode") != "primary-replica":
            continue
        eid = e["id"]
        prim = topo.get(eid, {}).get("primary", e["primary_service"])
        lines.append("# --- %s (ana kopya: %s) ---" % (eid, prim))
        if eid == "postgresql":
            emit("POSTGRES_STANDBY_OF", "POSTGRES_REPLICA_STANDBY_OF", prim,
                 "postgresql", "postgresql-replica")
        elif eid == "redis":
            # Redis'te "replicaof no one" = primary. İki alan gerektiği için
            # host ve port ayrı ayrı yazılır.
            if prim == "redis":
                lines += ["REDIS_STANDBY_OF=no", "REDIS_STANDBY_PORT=one",
                          "REDIS_REPLICA_STANDBY_OF=redis", "REDIS_REPLICA_STANDBY_PORT=6379",
                          "REDIS_REPLICA_READ_ONLY=yes"]
            else:
                lines += ["REDIS_STANDBY_OF=redis-replica", "REDIS_STANDBY_PORT=6379",
                          "REDIS_REPLICA_STANDBY_OF=no", "REDIS_REPLICA_STANDBY_PORT=one",
                          "REDIS_REPLICA_READ_ONLY=no"]
        elif eid == "mariadb":
            if prim == "mariadb":
                lines += ["MARIADB_READ_ONLY=OFF", "MARIADB_REPLICA_READ_ONLY=ON"]
            else:
                lines += ["MARIADB_READ_ONLY=ON", "MARIADB_REPLICA_READ_ONLY=OFF"]
        lines.append("")

    os.makedirs(os.path.dirname(ROLES_ENV), exist_ok=True)
    with open(ROLES_ENV, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return ROLES_ENV


def reload_gateway(attempts=3):
    """Yönlendirme değişince nginx'i tazele. `reload` mevcut bağlantıları
    KOPARMAZ — eski worker'lar boşalana kadar çalışmaya devam eder.

    Dönüş: True = gateway ARTIK yeni tabloyu uyguluyor. False dönerse trafik
    hâlâ ESKİ hedefe (devirde: fence edilmiş ölü düğüme) gidiyor demektir;
    çağıran yer bunu kullanıcıya söylemek zorundadır."""
    # Container GERÇEKTEN güncel dosyayı görüyor mu? Bind-mount inode'a bağlı
    # olduğu için bu sessizce eskimiş olabilir — devirdeki en pahalı hata budur,
    # çünkü her şey başarılı görünürken uygulamalar bağlanamaz. Eskiden burada
    # yalnız log'a bir uyarı düşüyordu ve devir "başarılı" ilan ediliyordu;
    # oysa bu durumda reload'ın başarılı olması hiçbir şey ifade etmez —
    # nginx eski dosyayı yeniden okur. O yüzden artık BAŞARISIZLIK sayılıyor.
    try:
        import hashlib
        with open(ROUTES_FILE, "rb") as f:
            want = hashlib.md5(f.read()).hexdigest()
        rc0, seen, _ = run(["docker", "exec", "gateway", "md5sum",
                            "/etc/nginx/stream.d/routes.conf"], timeout=30)
        if rc0 == 0 and want not in seen:
            log("gateway ESKİMİŞ yönlendirme tablosu görüyor — bind-mount "
                "inode'u kopmuş, reload işe yaramaz; gateway yeniden yaratılmalı")
            return False
    except Exception:
        pass

    for i in range(max(1, attempts)):
        rc, out, err = run(["docker", "exec", "gateway", "nginx", "-s", "reload"], timeout=60)
        if rc == 0:
            log("gateway yönlendirmesi tazelendi")
            return True
        log("gateway reload BAŞARISIZ (%d/%d):" % (i + 1, attempts),
            (err or out).strip()[:300])
        # Gateway o an yeniden başlıyor olabilir (compose up sırası); birkaç
        # saniyelik bir pencere için bütün devri kaybetmek istemiyoruz.
        if i + 1 < attempts:
            time.sleep(3)
    return False


def gateway_reload_or_alert(eid, what):
    """reload_gateway()'i çalıştırır; başarısızsa KULLANICIYA SÖYLER.

    Yönlendirme güncellenmeden yapılan devir, yapılmamış devirden farksızdır:
    uygulamalar durdurulmuş eski düğüme bağlanmaya devam eder. Bu sessiz
    kalınacak bir hata değil; olay akışına kritik olarak düşüyor."""
    if reload_gateway():
        return True, None
    msg = ("Yönlendirme tablosu gateway'e uygulanamadı — uygulamalar hâlâ ESKİ "
           "adrese gidiyor. Sunucuda `docker restart gateway` çalıştırın; "
           "veritabanı tarafında yapılacak bir şey yok (%s)." % what)
    record_event("gateway_reload_failed", eid, msg, level="critical")
    return False, msg


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


# --- Devir/kurtarma işlemleri motor başına TEK SIRADA yürür ------------------
# Eskiden ACTION_LOCK yalnız compose çağrısını sarıyordu; devrin kendisi kilitsizdi.
# Gerçek riski şuydu: denetleyici mariadb-replica'yı yükseltirken (topology
# henüz YAZILMAMIŞ) operatör dashboard'dan "eski kopyayı yeniden kur" derse,
# rebuild o an primary'ye yükseltilmekte olan düğümü "eski primary" sanıp
# container'ını ve VOLUME'unu siliyordu — eski primary zaten fence edilmiş
# olduğu için elde tek bir sağlam kopya bile kalmıyordu.
_ENGINE_LOCKS = {}
_ENGINE_LOCKS_GUARD = threading.Lock()
BUSY_MSG = ("%s için zaten bir devir/kurtarma işlemi sürüyor. Bitmesini bekleyin; "
            "aynı anda ikisini birden çalıştırmak veri kaybına yol açabilir.")


def engine_lock(eid):
    with _ENGINE_LOCKS_GUARD:
        return _ENGINE_LOCKS.setdefault(eid, threading.Lock())


# Devir bekleme süresi (cooldown) yalnız bellekte tutuluyordu; controller her
# yeniden başladığında sıfırlanıyordu. Devir çoğunlukla controller'ın da
# yeniden başladığı bir olayda (sunucu reboot'u) yaşandığı için bu kural fiilen
# hiç işlemiyordu: aynı motor peş peşe devredebiliyordu. Artık diske yazılıyor.
FAILOVER_GUARD_FILE = os.path.join(STATE_DIR, "failover-guard.json")
_STRIKES = {}
_LAST_FAILOVER = {}


def _last_failover_at(eid):
    if eid not in _LAST_FAILOVER:
        try:
            _LAST_FAILOVER[eid] = float(_read_json(FAILOVER_GUARD_FILE, {}).get(eid, 0))
        except (TypeError, ValueError):
            _LAST_FAILOVER[eid] = 0.0
    return _LAST_FAILOVER.get(eid, 0.0)


def _mark_failover_attempt(eid):
    _LAST_FAILOVER[eid] = time.time()
    try:
        g = _read_json(FAILOVER_GUARD_FILE, {})
        g[eid] = int(_LAST_FAILOVER[eid])
        _write_json(FAILOVER_GUARD_FILE, g)
    except OSError as e:  # disk doluysa bile devri engellemeyiz, sadece uyarırız
        log("devir bekleme süresi diske yazılamadı:", e)


def node_is_writable_primary(engine, service, jl=None):
    """Bu düğüm GERÇEKTEN yazılabilir ana kopya mı? (failover betiğinin 'check'i)

    True  = evet, ölçtük.   False = hayır (replika, read-only ya da erişilemez).
    None  = soramadık (betik yok / motor desteklemiyor).
    """
    fo = engine.get("failover", {})
    script = script_path("failover", fo.get("promote_script") or engine["id"])
    if not fo.get("supported") or not os.path.exists(script):
        return None
    rc, out, err = run(["sh", script, "check", service], timeout=60, env=script_env())
    if jl and (out or err):
        jl(("check %s: " % service) + (out + err).strip()[-300:])
    return rc == 0


def perform_failover(eid, reason, jid=None):
    """Replikayı primary'ye yükseltir. Sıra kritiktir."""
    engine = CATALOG.engine(eid)
    fo = engine.get("failover", {})

    # Devrin REDDEDİLDİĞİ her yol da bir olaydır. Eskiden bu yollarda hiçbir
    # olay yazılmıyordu: gece 03:00'te ana kopya ölüyor, otomatik devir
    # "yedek yok" diye sessizce vazgeçiyor, webhook'a hiçbir bildirim gitmiyor
    # ve operatör durumu ancak uygulama şikâyetiyle öğreniyordu. Tam olarak
    # bildirim gerektiren an, sistemin en sessiz kaldığı an oluyordu.
    def refuse(msg, level="critical", kind="failover_blocked"):
        record_event(kind, eid, "Devir YAPILMADI: " + msg, level=level)
        return False, msg

    if not fo.get("supported"):
        return refuse("Bu motorda failover desteklenmiyor: " + fo.get("note", ""),
                      level="warning")
    if fo.get("mode") == "native":
        return refuse("%s kendi seçimini yapar; controller müdahale etmez. "
                      "Replica set üyelerini kontrol edin." % engine["name"],
                      level="warning")

    # Aynı motorda ikinci bir devir/kurtarma işi varsa BEKLEMİYORUZ, reddediyoruz:
    # sıraya alınmış bir devir, aradaki topology değişikliğini görmediği için
    # yanlış düğümü fence eder.
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return refuse(BUSY_MSG % engine["name"], level="warning")
    try:
        return _perform_failover_locked(engine, eid, fo, reason, jid, refuse)
    finally:
        lock.release()


def _perform_failover_locked(engine, eid, fo, reason, jid, refuse):
    old = current_primary(engine)
    new = standby_of(engine)
    if not new:
        return refuse("%s için yedek kopya yok — yükseltilecek bir düğüm "
                      "bulunmadığı için devir yapılamadı. Ana kopya erişilemez "
                      "durumdaysa elle müdahale gerekiyor." % engine["name"])

    ostat, ohealth = _health_of(old)
    nstat, nhealth = _health_of(new)
    if nstat != "running":
        return refuse("Yedek kopya (%s) çalışmıyor — yükseltilecek sağlam bir "
                      "kopya yok. Ana kopyaya dokunulmadı." % new)

    def jl(*m):
        if jid:
            job_log(jid, *m)
        else:
            log(*m)

    script = script_path("failover", fo.get("promote_script") or eid)
    if not os.path.exists(script):
        return refuse("Yükseltme betiği yok: " + script)

    # Replikasyon hiç BAŞARIYLA kurulmadıysa ortada yükseltilecek bir yedek de
    # yoktur. Container'ın ayakta olması yetmez: kurulumu yarıda kalmış bir
    # düğüm, primary'nin verisini değil kendi eski verisini taşır.
    rep_profile = (engine.get("replication") or {}).get("profile")
    if rep_profile and rep_profile not in load_state().get("profiles", []):
        return refuse("%s için replikasyon kurulu değil — yükseltilecek geçerli "
                      "bir yedek kopya yok." % engine["name"])

    # 0) ÖN KONTROL — yedek gerçekten yükseltilebilir durumda mı?
    #    Bu adım FENCE'TEN ÖNCE gelir ve iki ayrı felaketi engeller:
    #      • Senkron olmamış bir replikayı primary yapmak = sessiz veri kaybı.
    #      • Yükseltme başarısız olursa eski primary fence edilmiş kalır ve
    #        veritabanı tamamen erişilemez olur (hiç devir yapmamaktan kötü).
    #    Hazır değilse ana kopyaya DOKUNMUYORUZ; kullanıcıya sebebi söylüyoruz.
    rrc, rout, rerr = run(["sh", script, "ready", new], timeout=120, env=script_env())
    if rrc != 0:
        detail = (rout + rerr).strip()[-600:]
        record_event("failover_blocked", eid,
                     "Devir YAPILMADI: %s yükseltmeye hazır değil (replikasyon "
                     "sağlıklı değil). Ana kopyaya dokunulmadı — veri kaybı "
                     "riski alınmadı. %s" % (new, detail),
                     level="critical")
        return False, ("Yedek kopya (%s) yükseltmeye hazır değil: replikasyon "
                       "akmıyor. Devir yapılmadı. %s" % (new, detail))

    jl("FAILOVER: %s → %s  (sebep: %s)" % (old, new, reason))
    # Bekleme süresi (cooldown) TAM BURADA, ana kopyaya dokunmadan hemen önce
    # başlar ve diske yazılır. Elle tetiklenen devir de sayılır: denetleyici,
    # controller yeniden başlasa bile aynı motoru hemen ikinci kez devretmesin.
    _mark_failover_attempt(eid)

    # 1) FENCE — eski primary'yi durdur. Bu adım ATLANAMAZ: iki kopya aynı anda
    #    yazma kabul ederse (split-brain) veriler ayrışır ve birleştirilemez.
    #    `docker stop` restart politikasını da bastırır, kendiliğinden geri gelmez.
    jl("1/4 eski primary fence ediliyor (durduruluyor):", old)
    run(["docker", "stop", "-t", "15", old], timeout=120)

    # 2) PROMOTE
    jl("2/4 yükseltiliyor:", new)
    rc, out, err = run(["sh", script, "promote", new], timeout=600, env=script_env())
    jl((out + err).strip()[-3000:])
    if rc != 0:
        # Betik hata döndürdü diye düğümün yükselmediğini VARSAYMIYORUZ. Gerçek
        # bir olayda MariaDB betiği son komutunda takıldı (motorda olmayan bir
        # değişken), oysa read_only kapanmış ve düğüm yazılabilir olmuştu; buna
        # rağmen devir iptal edilip veritabanı erişilemez bırakılmıştı.
        # Karar, çıkış koduna değil ÖLÇÜLEN DURUMA dayanır.
        crc, _, _ = run(["sh", script, "check", new], timeout=60, env=script_env())
        if crc == 0:
            jl("   betik hata verdi ama", new, "yazılabilir primary — devam ediliyor")
        else:
            # GERİ AL: yükseltme gerçekten olmadı. Eski primary fence'te kalırsa
            # veritabanı tamamen erişilemez olur; onu geri açmak split-brain
            # riski taşımaz, çünkü yedek YÜKSELMEDİ (ölçtük).
            jl("   yükseltme başarısız — eski primary geri açılıyor:", old)
            rb, _, rberr = run(["docker", "start", old], timeout=180)
            if rb == 0:
                record_event("failover_rolled_back", eid,
                             "Yükseltme başarısız oldu; %s geri açıldı ve hizmet "
                             "sürüyor. Replikasyonu kontrol edin." % old,
                             level="critical")
                return False, ("Yükseltme başarısız (çıkış %d) — eski primary geri "
                               "açıldı, veritabanı erişilebilir durumda." % rc)
            record_event("failover_failed", eid,
                         "Yükseltme başarısız ve eski primary geri açılamadı (%s) — "
                         "veritabanı ŞU AN ERİŞİLEMEZ." % rberr.strip()[-200:],
                         level="critical")
            return False, "Yükseltme başarısız (çıkış %d) ve geri alınamadı" % rc

    # 3) REROUTE — uygulamalar aynı adrese bağlanmaya devam eder
    jl("3/4 yönlendirme güncelleniyor")
    topo = load_topology()
    prev = topo.get(eid, {})
    topo[eid] = {"primary": new, "since": int(time.time()),
                 "failovers": int(prev.get("failovers", 0)) + 1,
                 "previous_primary": old, "reason": reason}
    save_topology(topo)
    write_roles()      # roller yer değiştirdi — yeni rol dosyasını üret
    write_routes()
    routed, route_err = gateway_reload_or_alert(eid, "%s → %s devri" % (old, new))

    # 4) KAYDET
    jl("4/4 tamam — yeni primary:", new)
    record_event("failover", eid,
                 "Otomatik failover: %s devre dışı, %s primary oldu. Sebep: %s"
                 % (old, new, reason),
                 level="critical", old_primary=old, new_primary=new)
    if not routed:
        # Yükseltme oldu ama trafik hâlâ ölü düğüme gidiyor. Bunu "başarılı"
        # saymak, kullanıcıya çalışan bir veritabanı olduğunu söylemek olurdu;
        # oysa uygulamaları hâlâ bağlanamıyor. İşi BAŞARISIZ kapatıp ne
        # yapması gerektiğini tek cümlede söylüyoruz.
        jl("UYARI:", route_err)
        return False, ("Yedek kopya (%s) yükseltildi ve yazmaya açık, ancak %s"
                       % (new, route_err))
    return True, None


VOLUME_OF = {
    "mariadb": "mariadb_data", "mariadb-replica": "mariadb_replica_data",
    "postgresql": "postgresql_data", "postgresql-replica": "postgresql_replica_data",
    "redis": "redis_data", "redis-replica": "redis_replica_data",
}


def volume_of(service):
    """Servisin veri hacminin tam adı (proje öneki ile), yoksa None."""
    v = VOLUME_OF.get(service)
    return ("%s_%s" % (PROJECT, v)) if v else None


# Yeni kurulan yedeğin gerçekten yedek olduğunu doğrulamak için beklenecek
# süre. İlk klonlama (pg_basebackup / dump) büyük veritabanlarında dakikalar
# sürebilir; bu yüzden cömert.
STANDBY_VERIFY_TIMEOUT = int(os.environ.get("STANDBY_VERIFY_TIMEOUT", "900"))


def verify_standby(engine, service, jl):
    """Yeni kurulan düğüm GERÇEKTEN yedek mi? (ok, açıklama)

    Eskiden yalnız `compose up`'ın çıkış koduna bakılıyordu. Ama container'ın
    ayağa kalkması hiçbir şey kanıtlamaz: veri hacmi silinemediyse düğüm eski
    verisiyle İKİNCİ BİR YAZILABİLİR ANA KOPYA olarak açılır (replika okuma
    portu 5433/3307 host'a açık olduğu için uygulamalar oraya yazmaya bile
    başlayabilir), replikasyon kullanıcısı yoksa da sonsuz crash-loop'a girer.
    İki durumda da işlem "başarılı" görünüyordu. Artık ölçüyoruz:
      • failover betiğinin `check`i 0 dönerse düğüm YAZILABİLİR primary'dir → felaket,
      • `ready` 0 dönerse düğüm gerçekten veri almış bir yedektir → tamam.
    """
    fo = engine.get("failover", {})
    script = script_path("failover", fo.get("promote_script") or engine["id"])
    if not os.path.exists(script):
        return True, "doğrulama betiği yok (%s) — atlandı" % script
    env = script_env()
    deadline = time.time() + STANDBY_VERIFY_TIMEOUT
    turn, last = 0, ""
    while True:
        if node_is_writable_primary(engine, service, None) is True:
            return False, ("%s yedek olarak değil, İKİNCİ BİR YAZILABİLİR ANA KOPYA "
                           "olarak açıldı" % service)
        rrc, rout, rerr = run(["sh", script, "ready", service], timeout=120, env=env)
        last = (rout + rerr).strip()[-400:]
        if rrc == 0:
            return True, last
        if time.time() >= deadline:
            return False, ("%s %d saniyede yedek konumuna geçmedi. Son durum: %s"
                           % (service, STANDBY_VERIFY_TIMEOUT, last or "(çıktı yok)"))
        turn += 1
        if turn % 6 == 1:
            jl("   yedek kopya hâlâ senkronlanıyor…", last)
        time.sleep(5)


def rebuild_standby(eid, jid=None):
    """Failover sonrası eski primary'yi yeni primary'nin REPLİKASI olarak geri alır.

    Eski primary'yi olduğu gibi başlatmak tehlikelidir: eskimiş verisiyle
    yazma kabul edebilir. Bu yüzden verisi silinip baştan senkronize edilir.
    """
    engine = CATALOG.engine(eid)
    rep = engine.get("replication", {})

    def jl(*m):
        job_log(jid, *m) if jid else log(*m)

    def refuse(msg, level="warning"):
        record_event("rebuild_blocked", eid, "Yeniden kurulum YAPILMADI: " + msg,
                     level=level)
        return False, msg

    # Bu işlem BİR VERİ HACMİNİ SİLER. Aynı motorda bir devir sürerken
    # çalışırsa, o an primary'ye yükseltilmekte olan düğümü silebilir; eski
    # primary de fence edilmiş olduğu için elde hiçbir sağlam kopya kalmaz.
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return refuse(BUSY_MSG % engine["name"])
    try:
        return _rebuild_standby_locked(engine, eid, rep, jid, jl, refuse)
    finally:
        lock.release()


def _rebuild_standby_locked(engine, eid, rep, jid, jl, refuse):
    old = standby_of(engine)   # failover sonrası eski primary artık "standby" rolünde
    if not old:
        return refuse("%s primary-replica desteklemiyor; yeniden kurulacak bir "
                      "yedek kopya yok." % engine["name"])

    # ÖNKOŞUL 1 — replikasyon kurulu olmalı. Kurulmadan çağrılırsa (dashboard'da
    # düğme görünmese de uç açıktır) replika hacmi siliniyor, container ise
    # olmayan replikasyon kullanıcısıyla bağlanmayı deneyip crash-loop'a
    # giriyordu; state["profiles"] güncellenmediği için ne durdurulabiliyor ne
    # de bellek defterine giriyordu — sessiz bir kaynak sızıntısı.
    if rep.get("profile") and rep["profile"] not in load_state().get("profiles", []):
        return refuse("%s için replikasyon kurulu değil. Önce 'Yedek Kopya Kur' "
                      "deyin; yeniden kurulacak bir yedek yok." % engine["name"])

    prim = current_primary(engine)
    if old == prim:
        # Buraya düşülmemeli; düşülürse topoloji tutarsız demektir.
        return refuse("Hedef düğüm (%s) şu anda ANA KOPYA olarak görünüyor — "
                      "yanlış düğümü silmemek için işlem durduruldu." % old, "critical")

    # ÖNKOŞUL 2 — kopyanın alınacağı ana kopya AYAKTA ve YAZILABİLİR olmalı.
    # Bu adım atlanırsa elde kalan tek sağlam kopyanın verisi silinir: yedeği
    # yeniden kurmak, ana kopya sağlamken anlamlıdır.
    pstat, phealth = _health_of(prim)
    if pstat != "running":
        return refuse("Ana kopya (%s) şu anda çalışmıyor (%s). Yedeği silip "
                      "yeniden kurmak, elinizdeki tek kopyayı yok ederdi. Önce "
                      "ana kopyayı ayağa kaldırın." % (prim, pstat), "critical")
    if node_is_writable_primary(engine, prim, jl) is False:
        return refuse("Ana kopya (%s) yazma kabul etmiyor (hâlâ yedek/read-only "
                      "durumda olabilir). Kopyanın alınacağı kaynak sağlam "
                      "değilken yedeği silmiyoruz." % prim, "critical")

    jl("Eski primary yeni primary'nin replikası olarak kuruluyor:", old)
    jl("   kopya kaynağı (ana kopya):", prim, " hedef (yeniden kurulacak):", old)
    # Rolleri ÖNCE yaz: container yaratılırken doğru STANDBY_OF değerini
    # görmeli, yoksa yine primary olarak açılır.
    write_roles()
    rc, out, err = run(["docker", "rm", "-f", old], timeout=120)
    if rc != 0:
        # Container zaten yoksa docker sürümüne göre 0 ya da 1 dönebilir; asıl
        # kapıyı aşağıdaki volume silme tutuyor (container duruyorsa hacim
        # "in use" der ve orada duruyoruz).
        jl("   not: container silinemedi/zaten yok:", (err or out).strip()[-200:])

    # Eski verinin silinmesi ZORUNLU — yoksa yeni primary ile ayrışmış geçmiş
    # birleşemez ve replikasyon tutarsız veriyle başlar.
    full = volume_of(old)
    if full:
        jl("eski veri temizleniyor:", full)
        rc, out, err = run(["docker", "volume", "rm", "-f", full], timeout=120)
        if rc != 0:
            # Sessizce devam etmek en pahalı hataydı: hacim silinmeyince düğüm
            # ESKİ verisiyle ve (PGDATA dolu olduğu için klonlama atlanarak)
            # NORMAL PRIMARY olarak açılıyor, ortada iki yazılabilir kopya
            # kalıyordu. Hacmi genelde yedekleme betiği ya da hâlâ silinmemiş
            # container tutar; ikisi de birkaç dakikada biter.
            return refuse(
                "Eski verinin hacmi silinemedi (%s): %s\nBaşka bir işlem (yedekleme "
                "olabilir) hacmi kullanıyor. Birkaç dakika sonra tekrar deneyin — "
                "eski veriyle açılan bir düğüm ikinci bir ana kopya olurdu."
                % (full, (err or out).strip()[-300:]), "critical")

    with ACTION_LOCK:
        rc, out, err = run(compose_base() + ["--profile", engine["profile"],
                                             "--profile", rep["profile"], "up", "-d", old],
                           timeout=1800)
    jl((out + err).strip()[-2000:])
    if rc != 0:
        return refuse("Yedek kopya yeniden kurulamadı (compose çıkış %d): %s"
                      % (rc, (err or out).strip()[-300:]), "critical")

    # PostgreSQL ve Redis rol env'iyle kendi kendine bağlanır (entrypoint /
    # --replicaof). MariaDB'de dump+CHANGE MASTER gerekir; betik onu yapar.
    script = script_path("replication", eid)
    if os.path.exists(script) and eid == "mariadb":
        # YÖN, betiğe AÇIKÇA verilir. Betik yönü kendi içinde sabit tutarsa
        # (eskiden öyleydi) devirden sonra dump AZ ÖNCE SİLİNMİŞ boş düğümden
        # alınıp CANLI ana kopyanın üzerine basılır; canlı kopya da o boş
        # düğümün replikası yapılır. Yani veriyi kurtarmak için başlatılan
        # işlem, elde kalan tek sağlam kopyayı siler.
        env = script_env()
        env.update(REPLICATION_PRIMARY=prim, REPLICATION_STANDBY=old)

        # Son emniyet kemeri: dump BASILMADAN hemen önce yönü bir kez daha
        # ölçüyoruz. Kaynak yazılabilir ana kopya DEĞİLSE ya da hedef
        # yazılabilir görünüyorsa dökümü hiç başlatmıyoruz.
        if node_is_writable_primary(engine, prim, jl) is False:
            return refuse("Kopya kaynağı (%s) yazılabilir ana kopya değil — "
                          "yanlış yönde kopyalama yapıp canlı veriyi ezmemek için "
                          "durduruldu." % prim, "critical")
        if node_is_writable_primary(engine, old, jl) is True:
            return refuse("Yeniden kurulan düğüm (%s) yazılabilir ana kopya olarak "
                          "açılmış — üzerine döküm basmak iki kopyayı da bozardı. "
                          "Durduruldu; `docker logs %s` çıktısına bakın."
                          % (old, old), "critical")

        rc, out, err = run(["sh", script, "attach"], timeout=1800, env=env)
        jl((out + err).strip()[-3000:])
        if rc != 0:
            return refuse("Yedek kopya ana kopyaya bağlanamadı (çıkış %d): %s"
                          % (rc, (err or out).strip()[-300:]), "critical")

    # Doğrulama: düğüm gerçekten yedek mi? Bu adım olmadan crash-loop'taki ya da
    # ikinci bir primary olarak açılmış düğüm "kuruldu" diye rapor ediliyordu.
    jl("yedek kopya doğrulanıyor…")
    ok, detail = verify_standby(engine, old, jl)
    if not ok:
        # Doğrulanamayan düğüm AYAKTA BIRAKILMAZ: yazılabilir olabilir ve
        # replika okuma portundan eski veriyi sunar.
        run(["docker", "stop", "-t", "15", old], timeout=120)
        return refuse("%s. Düğüm güvenlik için durduruldu; veri kaybı olmasın diye "
                      "ana kopyaya dokunulmadı." % detail, "critical")
    jl("   doğrulandı:", detail)

    write_routes()
    routed, route_err = gateway_reload_or_alert(eid, "%s yedeğinin yeniden kurulumu" % old)
    record_event("rebuild", eid, "%s yeniden replika olarak kuruldu" % old, level="info")
    if not routed:
        jl("UYARI:", route_err)
        return False, ("Yedek kopya (%s) kuruldu ve ana kopyayı takip ediyor, ancak %s"
                       % (old, route_err))
    return True, None


def health_verdict(eid, pstat, phealth):
    """Denetleyicinin sağlık yorumu: "ok" | "starting" | "bad".

    "starting" HATA DEĞİLDİR — motor daha açılıyor demektir. Docker healthcheck'i
    start_period boyunca bunu döndürür (MariaDB'de 60 sn, PostgreSQL'de 30 sn).
    Eskiden bu da sağlıksızlık sayılıyordu: sıradan bir sunucu reboot'unda
    denetleyici 30 saniyede 3 vuruşu doldurup açılışını yapan ana kopyayı
    ortasından kesiyor, daha kendisi de açılmamış yedeği yükseltmeye çalışıyordu.
    Artık sayaç DONDURULUYOR — ama sonsuza kadar değil: açılış makul süreyi
    aşarsa (motor gerçekten açılamıyorsa) yeniden sağlıksızlık sayılır."""
    if pstat == "running" and phealth in ("healthy", "none"):
        _STARTING_SINCE.pop(eid, None)
        return "ok"
    if pstat == "running" and phealth == "starting":
        since = _STARTING_SINCE.setdefault(eid, time.time())
        return "starting" if (time.time() - since) < FAILOVER_STARTING_GRACE else "bad"
    _STARTING_SINCE.pop(eid, None)
    return "bad"


def _alert_once(eid, key, message, every=600):
    """Aynı uyarıyı her 10 sn'de bir tekrarlamadan, ama unutmadan da bildirir."""
    now = time.time()
    if now - _ALERTED.get((eid, key), 0) < every:
        return
    _ALERTED[(eid, key)] = now
    record_event("failover_impossible", eid, message, level="critical")


def failover_supervisor():
    """Arka plan denetleyicisi: primary'yi izler, ölürse replikayı yükseltir.

    Neden üst üste birkaç hata bekliyoruz: tek bir başarısız healthcheck geçici
    olabilir (yoğun anlık yük, kısa GC duraklaması). Gereksiz failover, gereksiz
    kesinti demektir — bu yüzden eşik FAILOVER_STRIKES kadar arka arkaya hatadır.

    Açılış lütuf süresi neden var: devir kararının en tehlikeli anı, sunucunun
    yeni açıldığı andır. Reboot sonrası hem veritabanı hem controller birlikte
    kalkar; veritabanının healthcheck'i start_period boyunca "starting" der.
    Bunu sağlıksızlık sayan eski sürüm, sıradan bir reboot'ta 30 saniye içinde
    3 vuruşu doldurup açılışını yapan ana kopyayı ortasından kesiyor (crash
    recovery sırasında olabiliyor) ve daha kendisi de açılmamış replikayı
    yükseltmeye çalışıyordu — sonuç 5+ dakikalık tam kesintiydi.
    """
    log("failover denetleyicisi başladı (her %ds, eşik %d, açılış lütfu %ds)"
        % (FAILOVER_INTERVAL, FAILOVER_STRIKES, FAILOVER_STARTUP_GRACE))
    while True:
        time.sleep(FAILOVER_INTERVAL)
        try:
            enabled = auto_failover_engines()
            if not enabled:
                continue
            grace_left = FAILOVER_STARTUP_GRACE - (time.time() - _STARTED_AT)
            if grace_left > 0:
                # Açılışta hiçbir devir kararı verilmez; sayaçlar da temiz kalır.
                if int(grace_left) % 30 < FAILOVER_INTERVAL:
                    log("açılış lütuf süresi: devir kararları %d sn sonra başlıyor"
                        % int(grace_left))
                _STRIKES.clear()
                continue
            for eid in list(enabled):
                engine = CATALOG.engine(eid)
                if not engine or not engine.get("failover", {}).get("supported"):
                    continue
                if engine["failover"].get("mode") != "supervised":
                    continue
                prim = current_primary(engine)
                pstat, phealth = _health_of(prim)
                stand = standby_of(engine)
                rep_profile = (engine.get("replication") or {}).get("profile")
                can_fail_over = bool(stand) and (
                    not rep_profile or rep_profile in load_state().get("profiles", []))
                if not can_fail_over:
                    # Otomatik devir AÇIK ama yükseltilecek yedek yok. Ana kopya
                    # da ölüyse sistem eskiden tamamen sessiz kalıyordu: dashboard
                    # "otomatik devir açık" yazdığı için sahte bir güven veriyor,
                    # kimse durumu öğrenmiyordu. Artık düzenli olarak haber veriyoruz.
                    if pstat != "running":
                        _alert_once(eid, "no-standby",
                                    "%s ana kopyası çalışmıyor (%s) ve devredilecek "
                                    "bir yedek kopya YOK — otomatik devir yapılamıyor. "
                                    "Elle müdahale gerekiyor."
                                    % (engine["name"], pstat))
                    continue

                verdict = health_verdict(eid, pstat, phealth)
                if verdict == "ok":
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

                # Motor açılıyorsa (health=starting) sayaç DONDURULUR; devir
                # kararı vermek için ortada bir arıza yok.
                waited = int(time.time() - _STARTING_SINCE.get(eid, time.time()))
                if verdict == "starting":
                    if waited % 60 < FAILOVER_INTERVAL:
                        log("%s: ana kopya açılıyor (%d sn) — sayaç dondu"
                            % (eid, waited))
                    continue
                if phealth == "starting":
                    log("%s: ana kopya %d sn'dir açılamıyor — sağlıksız sayılıyor"
                        % (eid, waited))

                _STRIKES[eid] = _STRIKES.get(eid, 0) + 1
                # Devir denendi ve olmadıysa bekleme süresi boyunca sayaç artmaya
                # devam eder; her turda satır basmak logu doldurup asıl hatayı
                # görünmez yapıyordu (gerçek bir olayda "24/3" e kadar gitti).
                cooling = time.time() - _last_failover_at(eid) < FAILOVER_COOLDOWN
                if _STRIKES[eid] <= FAILOVER_STRIKES or _STRIKES[eid] % 20 == 0:
                    log("%s: primary sağlıksız (%s/%s) — %d/%d%s"
                        % (eid, pstat, phealth, _STRIKES[eid], FAILOVER_STRIKES,
                           "  (devir bekleme süresinde)" if cooling else ""))
                if _STRIKES[eid] < FAILOVER_STRIKES or cooling:
                    continue

                _STRIKES[eid] = 0
                _mark_failover_attempt(eid)
                jid = new_job("failover", eid)
                # perform_failover'ın kendisi de istisna fırlatabilir (docker
                # daemon kayıp, betik zaman aşımı…). Yakalamazsak iş sonsuza dek
                # "devam ediyor" görünür ve kimse ne olduğunu bilemez.
                try:
                    okk, reason = perform_failover(
                        eid, "primary %d kez üst üste sağlıksız (%s)"
                        % (FAILOVER_STRIKES, phealth), jid)
                except Exception as e:
                    okk, reason = False, repr(e)
                    record_event("failover_failed", eid,
                                 "Otomatik devir sırasında beklenmeyen hata: %r — "
                                 "veritabanının durumunu elle kontrol edin." % e,
                                 level="critical")
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

        pre = engine_preconditions(eid)
        if pre:
            job_log(jid, "ÖNKOŞUL SAĞLANMADI:", pre)
            record_event("activate_refused", eid,
                         "%s açılamadı: %s" % (engine["name"], pre), level="warning")
            return job_done(jid, False, pre)

        job_log(jid, "kaynak planı hesaplanıyor…")
        p = plan_engine(eid, requested_mb)
        if not p.get("ok"):
            job_log(jid, "REDDEDİLDİ:", p.get("reason"))
            record_event("activate_refused", eid,
                         "%s açılamadı: %s" % (engine["name"], p.get("reason", "")),
                         level="warning")
            return job_done(jid, False, p.get("reason"), {"plan": p})

        job_log(jid, "plan: limit=%d MB (%s), bütçe sonrası kalan=%d MB"
                % (p["limit_mb"], p["source"], p["headroom_mb"]))
        for k, v in sorted(p["tuning"].items()):
            job_log(jid, "  %s=%s" % (k, v))

        try:
            tun = load_tuning()
            tun[eid] = p["tuning"]
            save_tuning(tun)
            job_log(jid, "tuning.env yazıldı")
        except OSError as e:
            # Docker'da bu dosya ŞART (compose onu --env-file ile okur).
            # Kubernetes'te değerler doğrudan `kubectl set env` ile gider,
            # dosya yalnızca kayıt amaçlıdır — yazılamıyorsa aktivasyonu
            # iptal etmek yerine uyarıp devam ediyoruz.
            if BACKEND == "kubernetes":
                job_log(jid, "UYARI: ayarlar diske yazılamadı (%s) — "
                             "K8s'te değerler doğrudan uygulanıyor, devam ediliyor" % e)
            else:
                raise

        if BACKEND == "kubernetes":
            rc, out, errout = _k8s_scale(engine, 1, p["limit_mb"], p["tuning"])
            job_log(jid, out.strip() or errout.strip())
            return job_done(jid, rc == 0, None if rc == 0 else errout.strip(), {"plan": p})

        services = list(engine["services"])
        profiles = [engine["profile"]]

        # DEVİR OLMUŞSA GÜNCEL VERİ ARTIK YEDEKTEDİR. Kataloğun "asıl" ana
        # kopyası (ör. postgresql) devirde durdurulmuş, ESKİMİŞ veriyle duran
        # düğümdür; onu açmak iki felaketi birden getirirdi: veri dolu olduğu
        # için entrypoint klonlamayı atlar ve düğüm eski verisiyle yazma kabul
        # eden ikinci bir primary olur; üstelik yönlendirme tablosu gerçek ana
        # kopyayı gösterdiği için kullanıcı gateway'den ona hiç ulaşamaz ve
        # dashboard motoru "açılmadı" gösterir. Bu yüzden ŞU ANKİ ana kopyayı
        # açıyoruz; eski düğüm ancak "Eski kopyayı yeniden kur" ile geri gelir.
        prim = current_primary(engine)
        rep = engine.get("replication", {})
        if prim != engine["primary_service"] and rep.get("profile"):
            services = [s for s in services if s != engine["primary_service"]] + [prim]
            profiles.append(rep["profile"])
            write_roles()   # container doğru rolle yaratılsın
            job_log(jid, "NOT: bu motorda devir yapılmış — güncel veriyi taşıyan "
                         "%s açılıyor. Eski kopyayı (%s) geri almak için "
                         "'Eski kopyayı yeniden kur' düğmesini kullanın."
                    % (prim, engine["primary_service"]))

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
            args = []
            for pr in profiles:
                args += ["--profile", pr]
            cmd = compose_base() + args + ["up", "-d", "--remove-orphans"] + services
            job_log(jid, "$", " ".join(cmd[-8:]))
            rc, out, errout = run(cmd, timeout=1800)
        for line in (out + errout).splitlines()[-40:]:
            job_log(jid, line)
        if rc != 0:
            return job_done(jid, False, "compose başarısız (çıkış %d)" % rc, {"plan": p})

        st = load_state()
        st["profiles"] = list(set(st.get("profiles", [])) | set(profiles))
        save_state(st)
        # Yönlendirme tablosu açık motorları da göstermeli; devir sonrası
        # yeniden açılan motorda gateway'in hedefi tazelenmezse istekler
        # var olmayan container'a gider.
        if prim != engine["primary_service"]:
            write_routes()
            gateway_reload_or_alert(eid, "%s yeniden açıldı" % engine["name"])
        record_event("activate", eid,
                     "%s açıldı — %d MB ayrıldı%s"
                     % (engine["name"], p["limit_mb"],
                        "" if p.get("with_panel", True) else " (bellek dar, web paneli atlandı)"))
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
        prim = current_primary(engine)
        # Devir olmuşsa ŞU ANKİ ana kopya replika servisidir; onu listeye
        # almazsak "durdur" dediğimiz motor aslında ayakta kalır ve yazma kabul
        # etmeye devam eder. (Profil defterine bakmak yetmiyor: devirden sonra
        # profil listesi elle bozulmuş olabilir.)
        if rep.get("profile") and (rep["profile"] in load_state().get("profiles", [])
                                   or prim != engine["primary_service"]):
            targets.append(rep["replica_service"])
            profiles.append(rep["profile"])
        # TOPOLOJİ KAYDI SİLİNMEZ. Motor kapatılıp yeniden açıldığında hangi
        # düğümün güncel veriyi taşıdığını yalnız bu kayıt biliyor; silersek
        # bir sonraki "Aktif Et" eskimiş eski primary'yi açardı.

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
        if rc == 0:
            record_event("deactivate", eid,
                         "%s kapatıldı — belleği serbest bırakıldı (veriler duruyor)"
                         % engine["name"])
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

        # DEVİRDEN SONRA ROLLER TERSTİR: replika servisi (ör. postgresql-replica)
        # artık CANLI ANA KOPYADIR. Bu kontrol olmadan "replikasyonu kapat",
        # kataloğa bakıp o servisi durdurup container'ını siliyordu — eski
        # primary zaten fence edilmiş olduğu için ortada çalışan hiçbir
        # veritabanı kalmıyordu. "Replikayı kur" tarafı ise aynı düğümün
        # HACMİNİ siliyordu. İkisi de tek komutla toplam veri kaybı demek.
        prim = current_primary(engine)
        if svc == prim:
            msg = ("%s için devir yapılmış durumda: şu anki ANA KOPYA '%s'. "
                   "Bu işlem ana kopyayı silerdi. Önce 'Eski kopyayı yeniden kur' "
                   "ile rolleri eski hâline getirin." % (engine["name"], prim))
            record_event("replication_blocked", eid, msg, level="critical")
            return job_done(jid, False, msg)

        # Betiklere yönü AÇIKÇA söylüyoruz: hangi düğümden kopyalanacak, hangi
        # düğüme basılacak. Yönü betiğin içine sabitlemek, devirden sonra canlı
        # kopyanın üzerine yazmakla sonuçlanıyordu.
        rep_env = script_env()
        rep_env.update(REPLICATION_PRIMARY=prim, REPLICATION_STANDBY=svc)

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
                rc, out, errout = run(["sh", script, "prepare"], timeout=900, env=rep_env)
                job_log(jid, (out + errout).strip()[-3000:])
                if rc != 0:
                    return job_done(jid, False, "primary hazırlanamadı (çıkış %d)" % rc)

            # Replika TEMİZ bir hacimle başlamalı. Tohumlama dökümü yalnız
            # primary'de VAR OLAN veritabanlarını yazar; replikada kalmış eski
            # bir veritabanı silinmez. Gerçek sunucuda tam olarak bu oldu:
            # önceki testten kalan tablo replikada durdu, devirden sonra
            # "hayalet" satırlar olarak ortaya çıktı. Replika tanımı gereği
            # atılabilir bir kopyadır; ilk kurulumda sıfırdan başlatıyoruz.
            if profile not in load_state().get("profiles", []):
                vol = volume_of(svc)
                if vol:
                    run(["docker", "rm", "-f", svc], timeout=120)
                    run(["docker", "volume", "rm", "-f", vol], timeout=120)
                    job_log(jid, "replika sıfırdan kuruluyor (temiz hacim)")

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
                rc, out, errout = run(["sh", script, "attach"], timeout=1800, env=rep_env)
                job_log(jid, (out + errout).strip()[-4000:])
                if rc != 0:
                    # YARIM YAPILANDIRILMIŞ REPLİKA BIRAKILMAZ. Ayakta kalırsa
                    # otomatik devir onu sağlam bir yedek sanıp primary yapar ve
                    # ESKİ verisini sunmaya başlar. Gerçek sunucuda yaşandı:
                    # bağlama çöktü, replika ayakta kaldı, devir onu yükseltti ve
                    # veritabanı önceki testten kalan satırlarla geri geldi.
                    job_log(jid, "bağlama başarısız — yarım replika kaldırılıyor:", svc)
                    run(["docker", "rm", "-f", svc], timeout=120)
                    record_event("replication_failed", eid,
                                 "Yedek kopya kurulamadı ve kaldırıldı; ana kopya "
                                 "etkilenmedi.", level="warning")
                    return job_done(jid, False, "bağlama başarısız (çıkış %d)" % rc)

            st = load_state()
            st["profiles"] = list(set(st["profiles"]) | {profile})
            save_state(st)
            record_event("replication", eid,
                         "%s için yedek kopya kuruldu (%s)"
                         % (engine["name"], rep.get("replica_service", "")))
            return job_done(jid, True)

        # devre dışı bırak
        # ÖNCE motora özel temizlik: PostgreSQL'de boşta kalan replikasyon
        # slot'u WAL'ı sonsuza dek biriktirip diski doldurur ve primary'yi
        # durdurur. Replika container'ı silinmeden önce yapılmalı.
        script = script_path("replication", eid)
        if os.path.exists(script):
            job_log(jid, "replikasyon kalıntıları temizleniyor…")
            rc, out, err = run(["sh", script, "cleanup"], timeout=300, env=rep_env)
            job_log(jid, (out + err).strip()[-2000:])
            if rc != 0:
                # Temizlik çıkış kodu eskiden hiç okunmuyordu. PostgreSQL'de
                # kalan slot, "bu WAL'ı hâlâ biri okuyacak" anlamına gelir ve
                # disk dolana kadar WAL biriktirir — sonu ana kopyanın durması.
                # Ana kopya ayaktayken bu iş her zaman yeniden denenebilir, o
                # yüzden replikayı silmeden duruyoruz.
                pstat, _ = _health_of(prim)
                detail = (err or out).strip()[-300:]
                if pstat == "running":
                    msg = ("Replikasyon kalıntıları temizlenemedi (%s). Yedek kopya "
                           "KALDIRILMADI: temizlenmemiş bir kalıntı, ana kopyanın "
                           "diskini doldurup onu durdurabilir. Birkaç dakika sonra "
                           "tekrar deneyin." % detail)
                    record_event("replication_blocked", eid, msg, level="critical")
                    return job_done(jid, False, msg)
                record_event("replication", eid,
                             "Ana kopya (%s) çalışmadığı için replikasyon kalıntıları "
                             "temizlenemedi (%s). Ana kopya açıldıktan sonra 'Yedek "
                             "Kopya Kur / Kapat' işlemini bir kez daha çalıştırın."
                             % (prim, detail), level="warning")

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
        record_event("replication", eid, "%s yedek kopyası kaldırıldı" % engine["name"])
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
            # Uzun işlerin gövdesi try/except ile sarılır. Eskiden sarılmıyordu:
            # yükseltme betiği zaman aşımına uğradığında (subprocess.TimeoutExpired)
            # thread sessizce ölüyor, job_done hiç çağrılmıyor ve dashboard işi
            # sonsuza dek "devam ediyor" gösteriyordu — üstelik ana kopya fence
            # edilmiş, yükseltme yarıda kalmış hâldeyken.
            def _job_runner(fn, jid, eid, kind):
                def _go():
                    try:
                        okk, reason = fn(eid, jid)
                    except Exception as e:
                        job_log(jid, "HATA:", repr(e))
                        record_event("%s_failed" % kind, eid,
                                     "%s işlemi beklenmeyen bir hatayla durdu: %r — "
                                     "veritabanının durumunu kontrol edin." % (kind, e),
                                     level="critical")
                        okk, reason = False, repr(e)
                    job_done(jid, okk, reason)
                return _go

            if action == "failover":
                jid = new_job("failover", eid)
                threading.Thread(
                    target=_job_runner(
                        lambda e, j: perform_failover(e, "elle tetiklendi", j),
                        jid, eid, "failover"),
                    daemon=True).start()
                return self._send(202, {"job": jid})

            if action == "failover-auto":
                engine = CATALOG.engine(eid)
                want = bool(body.get("enabled"))
                fo = engine.get("failover", {})
                rep = engine.get("replication", {})
                # Otomatik devir, ancak yükseltilecek bir yedek varsa bir şey
                # ifade eder. Eskiden yalnız "motor destekliyor mu" diye
                # bakılıyordu: replikası hiç kurulmamış bir motorda düğme
                # açılıyor, dashboard "Otomatik devir açık" rozetini gösteriyor
                # ve kullanıcı korunduğunu sanıyordu. Ana kopya öldüğünde ise
                # yapılacak hiçbir şey olmuyordu.
                if want and not fo.get("supported"):
                    return self._send(400, {"error": fo.get("note", "")})
                if want and fo.get("mode") != "supervised":
                    msg = ("%s devri kendi içinde yapar; controller'ın otomatik "
                           "devri burada devreye girmez. %s"
                           % (engine["name"], fo.get("note", "")))
                    record_event("config_refused", eid,
                                 "Otomatik devir açılmadı: " + msg, level="warning")
                    return self._send(400, {"error": msg})
                if want and rep.get("profile") not in load_state().get("profiles", []):
                    msg = ("%s için önce yedek kopya (replika) kurun. Yedek kopya "
                           "olmadan otomatik devir yapılamaz — ana kopya çökerse "
                           "devreye alınacak bir düğüm olmaz." % engine["name"])
                    record_event("config_refused", eid,
                                 "Otomatik devir açılmadı: " + msg, level="warning")
                    return self._send(400, {"error": msg})
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
                threading.Thread(
                    target=_job_runner(lambda e, j: rebuild_standby(e, j),
                                       jid, eid, "rebuild"),
                    daemon=True).start()
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
            write_roles()
            write_routes()
            log("rol ve yönlendirme tabloları yazıldı")
            threading.Timer(5.0, reload_gateway).start()
        except Exception as e:
            log("yönlendirme tablosu yazılamadı:", e)
        threading.Thread(target=failover_supervisor, daemon=True).start()

    Server(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
