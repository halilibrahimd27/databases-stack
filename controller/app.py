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

import copy
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


# =============================================================================
# BELLEK MODELİ — REZERVE, TAVAN, DAĞITILABİLİR
# =============================================================================
# Ölçülen olay (16 GB test sunucusu): free -m → 15984 toplam, 1508 kullanımda,
# 13987 available. /proc/pressure/memory → some avg10=0.00: çekirdek SIFIR
# bellek baskısı bildiriyor. Container'lar tavanlarının çok altında —
# mariadb 3196 MB tavanın 213 MB'ını (%6), postgresql 2397 MB'ın 98 MB'ını
# (%4), redis 1278 MB'ın 5 MB'ını kullanıyordu. Buna rağmen panel "AYRILAN
# BELLEK 15 GB / 12 GB · %122 aşım" yazıyor, kapalı motorların hepsi "bellek
# yetmiyor" diye reddediliyordu. Makine %91 boşken ürün "yer yok" diyordu.
#
# Sebep model hatasıydı: docker --memory bir TAVANDIR, rezervasyon değil.
# Tavanları toplayıp RAM ile kıyaslamak kategori hatasıdır — yolda giden
# arabaların azami hızlarını toplayıp "yol kapasitesi aşıldı" demek gibi.
# Üç kavram artık ayrı tutuluyor:
#   REZERVE       motorun AÇILIŞTA gerçekten ayırdığı bellek (PostgreSQL
#                 shared_buffers, MariaDB innodb_buffer_pool_size, JVM -Xms).
#                 Hangi ayardan türediğini katalog söyler: resources.reserve.
#   TAVAN         docker --memory. Aşılırsa cgroup OOM killer devreye girer.
#   DAĞITILABİLİR toplam RAM − işletim sistemi payı − çekirdek servis payı.
#
# Aktivasyon üç kapıdan BİRDEN geçmek zorunda: SERT (Σ rezerve + yeni rezerve
# ≤ dağıtılabilir), YUMUŞAK (Σ tavan + yeni tavan ≤ dağıtılabilir × aşırı
# taahhüt) ve ÇEKİRDEK KEMERİ (MemAvailable ≥ yeni rezerve + emniyet payı).
def _env_float(name, default, low):
    """Politika sabitini ortamdan okur; saçma/boş değerde varsayılana döner."""
    try:
        v = float(os.environ.get(name) or default)
    except (TypeError, ValueError):
        v = default
    return max(v, low)


# Tavanların hepsi aynı anda dolmaz. 1.5 ölçülen orana göre bile temkinli:
# yukarıdaki dört container tavanlarının ortalama %5'ini kullanıyordu.
# 1.0 = aşırı taahhüt yok, yani eski (kategori hatalı) davranış.
OVERCOMMIT_LIMIT = _env_float("OVERCOMMIT_LIMIT", 1.5, 1.0)
# Çekirdek kemeri payı: yeni motorun rezervesinin ÜSTÜNE bu kadar boş bellek
# kalmalı. Rezerve açılışta bir defada ayrılır; MemAvailable'ı sıfıra indiren
# bir aktivasyon, defter "sığıyor" dese bile OOM killer'a davetiyedir.
KERNEL_SAFETY_MB = int(os.environ.get("KERNEL_SAFETY_MB", "512"))
# PSI eşikleri (/proc/pressure/memory, "some" avg10 = son 10 saniyenin yüzde
# kaçında en az bir görev bellek bekledi). Ölçümde 0.00 idi, yani "yok".
# 10 → geri kazanım (reclaim) çalışıyor demektir: felaket değil ama yeni bir
# rezerve için kötü zaman. 30 → görevler sürekli bekliyor; bu noktada motor
# açmak, çalışan motorların sayfalarını attırmaktan başka işe yaramaz.
PRESSURE_WARN = _env_float("PRESSURE_WARN", 10.0, 0.0)
PRESSURE_HIGH = _env_float("PRESSURE_HIGH", 30.0, 0.0)
# Yeniden dengelemede tavan, ölçülen GERÇEK kullanımın bu katının altına
# indirilmez. cgroup limiti anlık kullanımın altına inerse çekirdek
# container'ı ANINDA OOM eder; %30 pay, dump/checkpoint gibi ani sıçramalara
# yer bırakır.
REBALANCE_HEADROOM = _env_float("REBALANCE_HEADROOM", 1.3, 1.05)
# Bu eşiğin altındaki tavan değişikliği uygulanmaz: her yeniden dengelemede
# birkaç MB oynatmak, olay günlüğünü doldurmaktan başka bir şey yapmaz.
REBALANCE_MIN_DELTA_MB = 32

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


def run(cmd, timeout=900, env=None, cwd=None):
    """Kabuk YOK (shell=False) — argümanlar liste olarak geçer, enjeksiyon olamaz.

    cwd: göreli yol kullanan betikleri (yedekleme) /project'ten başlatmak için;
    verilmezse controller'ın kendi dizini (/app) kullanılır.
    """
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           env=e, cwd=cwd)
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


def container_usage_mb(c):
    """Container'ın GERÇEK bellek kullanımı (MB); ölçülemezse None.

    Önce cgroup: /sys/fs/cgroup altında memory.current (cgroup v2) ya da
    memory.usage_in_bytes (v1). Tek dosya okuması — docker daemon'a hiç
    dokunmaz ve `docker stats`ın saniyeler süren örneklemesini beklemez.
    Host'un cgroup ağacı bu container'a bağlanmamışsa (varsayılan kurulumda
    controller yalnız KENDİ cgroup'unu görür) `docker stats` önbelleğine
    düşüyoruz: tavan küçültürken ölçüsüz kalmak, cgroup'un container'ı ANINDA
    OOM etmesi demektir.

    cgroup'un memory.current'ı sayfa önbelleğini de sayar, `docker stats` ise
    inactive_file'ı düşer. Farkı bilerek kapatmıyoruz: yüksek olan sayı
    tavanı daha yukarıda tutar ve yanılma yönü GÜVENLİ taraftadır.
    """
    cid = (c.get("id") or "").strip()
    adaylar = []
    for kok in ("/sys/fs/cgroup/system.slice/docker-%s.scope" % cid,
                "/sys/fs/cgroup/docker/%s" % cid,
                "/sys/fs/cgroup/memory/docker/%s" % cid,
                "/sys/fs/cgroup/memory/system.slice/docker-%s.scope" % cid):
        if not cid:
            break
        adaylar.append(os.path.join(kok, "memory.current"))
        adaylar.append(os.path.join(kok, "memory.usage_in_bytes"))
    for yol in adaylar:
        try:
            with open(yol) as f:
                return int(f.read().strip()) // (1024 * 1024)
        except (OSError, ValueError):
            continue
    st = container_stats().get(c.get("name")) or {}
    kullanim = st.get("used_bytes")
    return int(kullanim // (1024 * 1024)) if kullanim else None


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
    # Grafikteki sayılarla panelin ve admission'ın sayıları AYNI fonksiyondan
    # geliyor: ayrı bir formül tutmak, "Grafana başka, panel başka söylüyor"
    # sınıfından hataların kaynağıydı.
    total, avail = host_memory_mb()
    committed = sum(c["memory_mb"] for c in conts if c["status"] == "running")
    os_reserve = os_reserve_mb(total)
    allocatable = allocatable_mb(total)
    reserved = stack_reserved_mb()
    psi = host_pressure()
    MB = 1024 * 1024
    add("dbstack_host_memory_total_bytes", "Sunucunun toplam RAM'i", "gauge",
        [([], total * MB)])
    add("dbstack_host_memory_available_bytes", "Sunucuda kullanilabilir RAM",
        "gauge", [([], avail * MB)])
    add("dbstack_memory_committed_bytes",
        "Calisan container'larin TAVAN toplami (docker --memory; rezervasyon "
        "DEGIL)", "gauge", [([], committed * MB)])
    add("dbstack_memory_reserved_bytes",
        "Acik motorlarin ACILISTA gercekten ayirdigi bellek (shared_buffers, "
        "buffer pool, JVM -Xms)", "gauge", [([], reserved * MB)])
    add("dbstack_memory_allocatable_bytes",
        "Dagitilabilir bellek (toplam - OS payi - cekirdek servisler)",
        "gauge", [([], allocatable * MB)])
    add("dbstack_memory_overcommit_ratio",
        "Tavan toplami / dagitilabilir. 1'in ustu asiri taahhuttur ve "
        "OVERCOMMIT_LIMIT'e kadar normaldir", "gauge",
        [([], round(committed / float(allocatable), 3) if allocatable > 0
           else 0.0)])
    add("dbstack_memory_pressure_some10",
        "Cekirdegin bellek baskisi olcumu: son 10 sn'nin yuzde kacinda en az "
        "bir gorev bellek bekledi (/proc/pressure/memory)", "gauge",
        [([], psi["some10"])])
    add("dbstack_memory_budget_bytes",
        "Yeni bir motora verilebilecek TAVAN (dagitilabilir x asiri taahhut - "
        "acik tavanlar)",
        "gauge", [([], max(0, int(allocatable * OVERCOMMIT_LIMIT)
                           - committed) * MB)])
    add("dbstack_memory_reserve_budget_bytes",
        "Yeni bir motorun ayirabilecegi REZERVE (dagitilabilir - acik "
        "motorlarin rezervesi); bu kural asla esnetilmez", "gauge",
        [([], max(0, allocatable - reserved) * MB)])
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


# "docker'a SORAMADIK" ile "container YOK" aynı şey değildir. run() zaman
# aşımını artık bir sonuç (rc=124) olarak döndürdüğü için, yoğun/askıda bir
# docker daemon'ında `docker ps` boş çıktıyla dönüyor ve liste BOŞ kalıyordu:
# denetleyici her motoru "absent" görüp sayaç işletiyor, üst üste 3 turda
# gereksiz bir devir denemesi başlatıyordu (eskiden istisna dış except'e
# düşerdi ve sayaç hiç artmazdı). Bu bayrak, listenin gerçekten docker'dan
# gelip gelmediğini söyler; denetleyici soramadığı turu atlar.
_DOCKER_PROBE = {"ok": True}


def docker_snapshot_ok():
    """En son container listesi docker'dan GERÇEKTEN alınabildi mi?"""
    return _DOCKER_PROBE["ok"]


def _docker_containers_uncached():
    if BACKEND == "kubernetes":
        return _k8s_workloads()
    rc, out, _ = run(
        ["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=" + PROJECT,
         "--format", "{{.ID}}"], timeout=30)
    if rc != 0:
        _DOCKER_PROBE["ok"] = False     # cevap alamadık — "hiç container yok" DEĞİL
        return []
    ids = [x for x in out.split() if x]
    _DOCKER_PROBE["ok"] = True
    if not ids:
        return []
    tmpl = ("{{.Name}}\t{{.State.Status}}\t"
            "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\t"
            "{{.HostConfig.Memory}}\t"
            "{{index .Config.Labels \"com.docker.compose.service\"}}\t"
            # ".Id" DEĞİL ".ID". İkisi de kimlik veriyor gibi görünür ama ".Id"
            # docker'ı ham JSON (map) yoluna düşürüyor; o yolda sağlık
            # kontrolü OLMAYAN container'da ".State.Health" "olmayan anahtar"
            # hatası veriyor ve docker o container'ı HİÇ YAZMIYOR. Ölçüldü:
            # ".Id" ile 15 container'ın 11'i geliyordu, düşenlerin hepsi
            # healthcheck'i olmayanlardı (bütün exporter'lar). Sonuç:
            # Prometheus hedef listesi boş, BÜTÜN panolar boş, bellek
            # muhasebesi eksik — ve hiçbir hata görünmüyordu. ".ID" ile 15/15.
            "{{.ID}}")
    rc, out, _ = run(["docker", "inspect", "--format", tmpl] + ids, timeout=60)
    res = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 6:
            continue
        name, status, health, mem, service, cid = parts
        try:
            mem_mb = int(mem) // (1024 * 1024)
        except ValueError:
            mem_mb = 0
        res.append({"name": name.lstrip("/"), "service": service, "status": status,
                    "health": health, "memory_mb": mem_mb, "id": cid.strip()})
    if rc != 0 and not res:
        _DOCKER_PROBE["ok"] = False     # inspect de cevap vermedi
    # EKSİK LİSTE, BOŞ LİSTEDEN TEHLİKELİDİR: boş liste hemen fark edilir,
    # eksik liste "her şey yolunda" gibi görünür. Yukarıdaki .Id hatası
    # tam olarak böyle görünmez kalmıştı. Artık gürültü çıkarıyor.
    if len(res) < len(ids):
        log("UYARI: docker inspect %d container'ın %d'sini döndürdü — "
            "eksik olanlar hiçbir hesaba girmiyor (hedef listesi, bellek "
            "muhasebesi, durum). inspect çıkış kodu: %d"
            % (len(ids), len(res), rc))
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


def _tuning_scratch(engine, limit_mb):
    """tuning kurallarının BİÇİMLENMEMİŞ sayısal değerleri (MB ya da adet).

    compute_tuning'ten ayrıldı çünkü rezerve hesabı da aynı sayılara bakıyor:
    rezerve, ürünün zaten hesapladığı ayarın KENDİSİDİR. İki yerde iki formül
    tutmak, panelin "ayrılan" dediğiyle motorun gerçekte ayırdığının
    ayrışması demek olurdu.
    """
    scratch = {}
    for t in engine.get("resources", {}).get("tuning", []):
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
    return scratch


def compute_tuning(engine, limit_mb):
    """Container limitinden motorun iç ayarlarını türetir."""
    spec = engine.get("resources", {}).get("tuning", [])
    out = {}
    # 1. geçiş — limit / fraction / per_gb
    scratch = _tuning_scratch(engine, limit_mb)
    for t in spec:
        if t["env"] in scratch:
            out[t["env"]] = _fmt(scratch[t["env"]], t.get("fmt", "int"))
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


def _tuning_fmt(engine, env):
    """Bir tuning anahtarının katalogdaki yazım biçimi."""
    for t in engine.get("resources", {}).get("tuning", []):
        if t.get("env") == env:
            return t.get("fmt", "int")
    return "int"


def _unfmt_mb(text, fmt):
    """_fmt'in TERSİ: motorun yazımından MB'ye. Anlaşılmazsa None.

    Neden tersine çeviriyoruz: rezerve, motora GERÇEKTEN verilmiş değerden
    okunmalı. state/tuning.env'deki dizge motorun açılışta gördüğü şeydir;
    onu limitten yeniden hesaplamak, aradan geçen elle bir `docker update`ten
    sonra defterle gerçeği ayırırdı. Tahmin yok: biçimi katalog söylüyor,
    yazan da _fmt — iki yön tek sözleşmeye bakıyor.
    """
    s = str(text or "").strip()
    if not s:
        return None
    try:
        if fmt == "java":
            # "-Xms512m -Xmx512m" → 512. Rezerve olan -Xms'tir: JVM o kadarını
            # açılışta ayırır, -Xmx ise büyüyebileceği tavandır.
            m = re.search(r"-Xms(\d+)([kmgKMG]?)", s)
            if not m:
                return None
            birim = {"": 1 / 1048576.0, "k": 1 / 1024.0, "m": 1.0, "g": 1024.0}
            return int(float(m.group(1)) * birim[m.group(2).lower()])
        if fmt == "bytes":
            return int(int(s) / 1048576)
        if fmt == "G_half":
            return int(float(s) * 1024)
        m = re.match(r"^(\d+(?:\.\d+)?)\s*([A-Za-z]*)$", s)
        if not m:
            return None
        carpan = {"": 1.0, "m": 1.0, "mb": 1.0, "k": 1 / 1024.0,
                  "kb": 1 / 1024.0, "g": 1024.0,
                  "gb": 1024.0}.get((m.group(2) or "").lower())
        if carpan is None:
            return None
        return int(float(m.group(1)) * carpan)
    except (ValueError, KeyError):
        return None


def engine_limit_mb(eid):
    """Motorun ŞU ANKİ docker tavanı (MB); çalışmıyorsa 0.

    Devirden sonra ana kopya kataloğun ilk servisi olmayabilir; tavanı
    topolojinin gösterdiği düğümden okuyoruz.
    """
    engine = CATALOG.engine(eid)
    if not engine:
        return 0
    prim = current_primary(engine)
    for c in docker_containers():
        if c["service"] == prim and c["status"] == "running":
            return c["memory_mb"]
    return 0


def engine_reserved_mb(eid, limit_mb=None, tuning=None):
    """Motorun AÇILIŞTA ayırdığı bellek (MB) — TAVANI DEĞİL.

    Kaynağı katalog söyler: resources.reserve.from, rezervenin hangi tuning
    anahtar(lar)ından türediğini yazar; boş liste "tabanı yok" demektir.
    Redis'in maxmemory'si, MSSQL'in 'max server memory'si, ClickHouse'un
    max_server_memory_usage'ı TAVANDIR — motor boş başlar, oraya doğru büyür.
    Onları rezerve saymak, ölçümde 1278 MB tavanının 5 MB'ını kullanan
    Redis'i "1278 MB ayrılmış" göstermek olurdu.

    Sıra: verilen tuning → yazılı kayıt (motor onunla açıldı) → limitten
    yeniden hesap.
    """
    engine = CATALOG.engine(eid)
    if not engine:
        return 0
    spec = engine.get("resources", {}).get("reserve") or {}
    kaynaklar = spec.get("from") or []
    toplam = int(spec.get("plus_mb") or 0)
    if not kaynaklar:
        return toplam
    if not tuning:
        if limit_mb is None:
            tuning = load_tuning().get(eid) or {}
        if not tuning:
            lim = int(limit_mb if limit_mb is not None
                      else engine_limit_mb(eid))
            tuning = compute_tuning(engine, lim) if lim > 0 else {}
    for env in kaynaklar:
        deger = _unfmt_mb(tuning.get(env), _tuning_fmt(engine, env))
        if deger:
            toplam += int(deger)
    return toplam


def stack_reserved_mb(exclude=None):
    """AÇIK motorların rezerve toplamı (MB); `exclude` verilen motor sayılmaz.

    Kapalı motorun rezervesi 0'dır — container'ı yoktur, ayırdığı bellek de.
    """
    calisan = {c["service"] for c in docker_containers()
               if c["status"] == "running"}
    # Topoloji ve tuning defterini motor başına DEĞİL bir kez okuyoruz:
    # /api/plans her motor için plan istiyor, her plan da bu toplamı soruyor.
    # current_primary() içeriden dosya açtığı için tek yenilemede yüzlerce
    # okuma ediyordu.
    topo = load_topology()
    tun = load_tuning()
    toplam = 0
    for e in CATALOG.engines:
        if exclude and e["id"] == exclude:
            continue
        prim = topo.get(e["id"], {}).get("primary", e["primary_service"])
        if prim in calisan:
            toplam += engine_reserved_mb(e["id"], tuning=tun.get(e["id"]))
    return toplam


def stack_ceiling_mb(exclude_services=None):
    """Çalışan container'ların docker --memory TAVANLARININ toplamı (MB)."""
    haric = exclude_services or set()
    return sum(c["memory_mb"] for c in docker_containers()
               if c["status"] == "running" and c["service"] not in haric)


def host_pressure():
    """/proc/pressure/memory — çekirdeğin bellek baskısı ölçümü (PSI).

    Neden defterimizden ÖNCE gelir: rezerve/tavan hesabı bizim modelimiz,
    PSI ise çekirdeğin gerçeğidir. "some avg10", son 10 saniyenin yüzde
    kaçında en az bir görevin bellek beklediğini söyler. Ölçümde 0.00'dı:
    panel "yer yok" derken çekirdek hiçbir görevi bekletmiyordu.

    PSI yoksa (eski çekirdek, CONFIG_PSI kapalı) seviye "bilinmiyor" döner ve
    admission bu kapıyı ATLAR — ölçemediğimiz bir şeyi gerekçe gösterip motor
    açtırmamak, kullanıcıya yalan söylemek olurdu.
    """
    out = {"some10": 0.0, "some60": 0.0, "full10": 0.0, "full60": 0.0,
           "seviye": "bilinmiyor"}
    try:
        with open("/proc/pressure/memory") as f:
            satirlar = f.readlines()
    except OSError:
        return out
    for line in satirlar:
        parca = line.split()
        if not parca:
            continue
        vals = {}
        for p in parca[1:]:
            if "=" in p:
                k, v = p.split("=", 1)
                try:
                    vals[k] = float(v)
                except ValueError:
                    pass
        if parca[0] == "some":
            out["some10"] = vals.get("avg10", 0.0)
            out["some60"] = vals.get("avg60", 0.0)
        elif parca[0] == "full":
            out["full10"] = vals.get("avg10", 0.0)
            out["full60"] = vals.get("avg60", 0.0)
    s = out["some10"]
    out["seviye"] = ("yuksek" if s >= PRESSURE_HIGH
                     else "orta" if s >= PRESSURE_WARN else "yok")
    return out


def os_reserve_mb(total):
    """İşletim sistemi payı — TEK yerden.

    OS payı toplam RAM'i aşamaz: 512 MB'lık bir makinede "1024 MB işletim
    sistemine ayrıldı" demek hem saçma hem yanlış bilgi. Üç hesap (plan,
    boş bütçe, durum) aynı fonksiyonu çağırıyor ki birbirini yalanlamasın —
    ölçülen %122 aşımının bir sebebi de iki ayrı yerde iki farklı OS payı
    hesaplanmasıydı.
    """
    if total <= 0:
        return 0
    return min(max(OS_RESERVE_MIN_MB, int(total * OS_RESERVE_RATIO)),
               int(total * 0.6))


def allocatable_mb(total=None):
    """DAĞITILABİLİR bellek: toplam RAM − OS payı − çekirdek servis payı."""
    if total is None:
        total = host_memory_mb()[0]
    if total <= 0:
        return 0
    return max(0, total - os_reserve_mb(total) - CORE_RESERVE_MB)


def _fit_reserve(eid, limit, min_mb, reserve_budget, available):
    """Tavanı, rezervesi SERT kurala ve ÇEKİRDEK KEMERİNE sığana dek küçültür.

    Reddetmek yerine küçültüyoruz: rezerve tavanla birlikte büyüdüğü için
    (MariaDB buffer pool = tavanın %60'ı) daha küçük bir tavan çoğu zaman
    sığar ve kullanıcı istediği motoru açar. %5'lik adımlarla iniyoruz;
    katalogdaki min_mb/max_mb clamp'leri yüzünden rezerve tavanın DÜZ bir
    oranı değil, tek bir formülle geri çözmek her motorda doğru olmazdı.
    """
    sinir = reserve_budget
    if available > 0:
        sinir = min(sinir, available - KERNEL_SAFETY_MB)
    limit = int(limit)
    rez = engine_reserved_mb(eid, limit_mb=limit)
    for _ in range(60):
        if rez <= sinir or limit <= min_mb:
            break
        limit = max(min_mb, int(limit * 0.95))
        rez = engine_reserved_mb(eid, limit_mb=limit)
    return limit, rez


def plan_engine(eid, requested_mb=None):
    """Motor açılabilir mi, hangi tavanla — ÜÇ KURALA göre karar verir.

    SERT   : Σ rezerve + yeni rezerve ≤ dağıtılabilir (asla esnetilmez)
    YUMUŞAK: Σ tavan + yeni tavan ≤ dağıtılabilir × OVERCOMMIT_LIMIT
    ÇEKİRDEK: MemAvailable ≥ yeni rezerve + KERNEL_SAFETY_MB

    Ret hâlinde hangi kuralın çiğnendiği `rule` alanında ve ret metninde
    ölçülen sayılarla birlikte döner. Eski davranış tek bir tavan defterine
    bakıyor ve %6 dolu bir sunucuda her motoru "bellek yetmiyor" diye
    reddediyordu.
    """
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

    os_reserve = os_reserve_mb(total)
    allocatable = allocatable_mb(total)

    # Zaten çalışan container'ların TAVAN toplamı — kendi defterimize değil
    # docker'ın söylediğine bakıyoruz, böylece elle yapılan değişiklikler de
    # hesaba katılır. Bu motorun kendi servisleri hariç tutulur (yeniden
    # boyutlandırma senaryosu).
    own = set(engine.get("services", []))
    committed = stack_ceiling_mb(own)
    # Açık motorların REZERVE toplamı. Tavandan bağımsız ve ondan çok daha
    # küçüktür: ölçümde mariadb 3196 MB tavan taşıyordu ama rezervesi (buffer
    # pool) 1917 MB, gerçek kullanımı 213 MB idi.
    reserved_others = stack_reserved_mb(exclude=eid)
    pressure = host_pressure()

    # YUMUŞAK KURAL bütçesi: tavanların toplamı, dağıtılabilirin aşırı taahhüt
    # katını aşmasın. Tavan bir söz değil bir sınırdır; hepsinin aynı anda
    # dolması, iş yüklerinin sözleşmiş gibi tepe yapmasını gerektirir.
    ceiling_budget = int(allocatable * OVERCOMMIT_LIMIT) - committed
    # SERT KURAL bütçesi: rezerveler gerçekten ayrılır, aşırı taahhüt edilemez.
    reserve_budget = allocatable - reserved_others

    # Panel (phpMyAdmin/pgAdmin/Kibana…) opsiyoneldir. Bütçe darsa onu ATLAYIP
    # veritabanının kendisini açıyoruz — küçük bir sunucuda "pgAdmin 512 MB
    # istiyor" diye PostgreSQL'i hiç açamamak saçma olurdu. Yönetim için
    # Adminer zaten her zaman ayakta (8085) ve MySQL/PostgreSQL/MSSQL'i yönetir.
    with_panel = True
    engine_budget = ceiling_budget - overhead
    if engine_budget < min_mb and panel_mb > 0 \
            and (ceiling_budget - exporter_mb) >= min_mb:
        with_panel = False
        engine_budget = ceiling_budget - exporter_mb

    detail = {
        "engine": eid,
        "host_total_mb": total,
        "host_available_mb": available,
        "os_reserve_mb": os_reserve,
        "core_reserve_mb": CORE_RESERVE_MB,
        "allocatable_mb": allocatable,
        "committed_mb": committed,
        "stack_reserved_mb": reserved_others,
        "reserve_budget_mb": reserve_budget,
        "ceiling_budget_mb": ceiling_budget,
        "overcommit_limit": OVERCOMMIT_LIMIT,
        "overcommit_ratio": (round(committed / float(allocatable), 2)
                             if allocatable > 0 else 0.0),
        "pressure": pressure,
        # budget_mb eski addır ve panel/selftest onu okuyor: yumuşak kuralın
        # (tavan) bütçesidir.
        "budget_mb": ceiling_budget,
        "overhead_mb": overhead if with_panel else exporter_mb,
        "panel_mb": panel_mb,
        "with_panel": with_panel,
        "engine_budget_mb": engine_budget,
        "min_mb": min_mb,
        "max_mb": max_mb,
        "cpus": host_cpus(),
        "disk_free_mb": disk_free_mb(),
    }

    # Üç kapının durumu HER cevapta bulunur — ret sebebi disk bile olsa panel
    # hangi kuralın sağlandığını gösterebilsin. reserved_mb burada asgari
    # tavana göredir; plan onaylanırsa aşağıda seçilen tavanla güncellenir.
    reserve_min = engine_reserved_mb(eid, limit_mb=min_mb)
    detail["reserved_mb"] = int(reserve_min)
    detail["ceiling_ok"] = bool(engine_budget >= min_mb)
    detail["reserve_ok"] = bool(reserve_min <= reserve_budget)
    detail["kernel_ok"] = bool(available <= 0
                               or available >= reserve_min + KERNEL_SAFETY_MB)

    if detail["disk_free_mb"] >= 0 and detail["disk_free_mb"] < MIN_FREE_DISK_MB:
        detail.update(ok=False, reason=(
            "Disk yetersiz: %d MB boş, en az %d MB gerekli."
            % (detail["disk_free_mb"], MIN_FREE_DISK_MB)), reason_kind="disk")
        return detail

    # --- YUMUŞAK KURAL: tavan bütçesi ---------------------------------------
    # Ret mesajı HANGİ kuralın çiğnendiğini ve ölçülen sayıları söyler.
    # "Bellek yetmiyor" demek yetmiyordu: kullanıcı boş belleğe bakıp haklı
    # olarak "ama yer var" diyordu — yer vardı, sıkışan tavan defteriydi.
    if not detail["ceiling_ok"]:
        detail.update(ok=False, rule="tavan", reason=(
            "YUMUŞAK KURAL (tavan) çiğneniyor. %s en az %d MB tavan ister "
            "(+ %d MB panel/exporter). Dağıtılabilir bellek %d MB; aşırı "
            "taahhüt katsayısı %.2f ile tavan bütçesi %d MB ediyor ve bunun "
            "%d MB'ı zaten çalışan container'ların tavanlarına verilmiş, "
            "geriye %d MB kalıyor. Bu bir TAVAN sıkışmasıdır, belleğin dolu "
            "olduğu anlamına GELMEZ: çekirdeğin bu andaki boş bellek ölçümü "
            "%d MB, bellek baskısı '%s'. Çözüm: 'Yeniden dengele' ile açık "
            "motorların tavanlarını güncel kullanıma göre düşürün, bir motoru "
            "durdurun ya da OVERCOMMIT_LIMIT'i yükseltin. (Toplam %d MB "
            "RAM'in %d MB'ı işletim sistemine, %d MB'ı çekirdek servislere "
            "ayrıldı.)"
            % (engine["name"], min_mb, overhead, allocatable, OVERCOMMIT_LIMIT,
               int(allocatable * OVERCOMMIT_LIMIT), committed,
               max(engine_budget, 0), available, pressure["seviye"],
               total, os_reserve, CORE_RESERVE_MB)), reason_kind="bellek")
        return detail

    # --- SERT KURAL: rezerve bütçesi ----------------------------------------
    # Bu kural asla esnetilmez: rezerve, motorun açılışta gerçekten ayırdığı
    # ve geri vermediği bellektir. Aşırı taahhüt edilirse ilk yazma yükünde
    # OOM killer devreye girer.
    if not detail["reserve_ok"]:
        detail.update(ok=False, rule="rezerve", reason=(
            "SERT KURAL (rezerve) çiğneniyor. %s açılışta en az %d MB'ı "
            "gerçekten ayırır (%s); açık motorların rezerve toplamı zaten "
            "%d MB ve dağıtılabilir bellek %d MB, yani ayrılabilecek %d MB "
            "kaldı. Rezerve tavan değildir: aşırı taahhüt edilemez. Başka "
            "bir motoru durdurun ya da sunucuya RAM ekleyin."
            % (engine["name"], reserve_min,
               ", ".join((engine.get("resources", {}).get("reserve") or {})
                         .get("from") or ["taban yok"]),
               reserved_others, allocatable, max(reserve_budget, 0))),
            reason_kind="bellek")
        return detail

    # --- ÇEKİRDEK KEMERİ ----------------------------------------------------
    # Defter ne derse desin çekirdeğin gerçeği bağlayıcıdır. MemAvailable
    # okunamadıysa (0) bu kapı atlanır; ölçemediğimiz şey gerekçe olamaz.
    if not detail["kernel_ok"]:
        detail.update(ok=False, rule="cekirdek", reason=(
            "ÇEKİRDEK KEMERİ çiğneniyor. %s açılışta %d MB ayıracak ve buna "
            "%d MB emniyet payı ekleniyor, ama /proc/meminfo MemAvailable şu "
            "an %d MB. Defter uygun görse bile bu belleği ayırmak OOM "
            "killer'ı çağırır. Bellek baskısı: '%s' (some avg10=%.2f)."
            % (engine["name"], reserve_min, KERNEL_SAFETY_MB, available,
               pressure["seviye"], pressure["some10"])), reason_kind="bellek")
        return detail

    if requested_mb:
        want = int(requested_mb)
        if want > engine_budget:
            detail.update(ok=False, rule="tavan", reason=(
                "İstenen %d MB tavan bütçesini aşıyor (kullanılabilir: %d MB; "
                "dağıtılabilir %d MB × aşırı taahhüt %.2f − açık tavanlar "
                "%d MB)." % (want, max(engine_budget, 0), allocatable,
                             OVERCOMMIT_LIMIT, committed)),
                reason_kind="bellek")
            return detail
        limit = _clamp(want, min_mb, None)
        source = "kullanıcı"
    else:
        limit = int(_clamp(total * share, min_mb, max_mb))
        limit = min(limit, engine_budget)
        source = "otomatik"

    pre = engine_preconditions(eid)
    if pre:
        # reason_kind: arayüz sebebi DOĞRU adlandırabilsin diye. Öncesinde
        # kapalı motor satırında sebep ne olursa olsun "bellek yetmiyor"
        # yazıyordu — AVX desteği olmayan bir CPU yüzünden açılamayan MongoDB
        # de öyle görünüyordu. Kullanıcı boş belleğe bakıp "ama yer var"
        # diyordu; haklıydı, mesele bellek değildi.
        detail.update(ok=False, reason=pre, reason_kind="onkosul")
        return detail

    # Seçilen tavanın rezervesi de sert kurala ve çekirdek kemerine sığmalı.
    # Sığmıyorsa reddetmiyoruz, tavanı küçültüyoruz: min_mb için üç kapı da
    # yukarıda geçildi, yani en kötü ihtimalle min_mb'de duruyoruz.
    limit, reserve_now = _fit_reserve(eid, limit, min_mb, reserve_budget,
                                      available)
    detail.update(ok=True, limit_mb=int(limit), source=source,
                  tuning=compute_tuning(engine, int(limit)),
                  reserved_mb=int(reserve_now),
                  headroom_mb=int(engine_budget - limit))
    return detail


def free_budget_mb():
    """ŞU AN boşta olan bellek: (boş_mb, ayrıntı). Hiçbir servis düşülmez.

    plan_engine'in budget_mb'si bu sorunun cevabı DEĞİLDİR ve olması da
    gerekmez: orada soru "bu motoru YENİDEN boyutlandırsam ne verebilirim"
    olduğu için motorun kendi servisleri taahhütten çıkarılır. "Yanına BİR
    TANE DAHA koyabilir miyim" diye soran taraf (replika kurulumu) o rakamı
    okuyunca motorun kendi container'larını boşta sanıyordu.

    Ölçülen olay: 15984 MB RAM'de OS payı 3196, çekirdek payı 448 → 12340 MB
    dağıtılabilirken ayrılan 15087 MB'a çıktı ve panel "%122 aşım" yazdı.
    Onay, silinmemiş olan 2397+512+64 MB'ı iki kez saymıştı.

    Hesap plan_engine ile BİREBİR aynı sırayı izler (aynı OS payı, aynı
    çekirdek payı, aynı docker defteri, aynı üç kural) — iki sayı birbirini
    yalanlamasın. Dönen `free` YUMUŞAK kuralın (tavan) boşluğudur; sert kural
    ve çekirdek kemeri için ayrıntıda reserve_free_mb ve kernel_free_mb var.
    Çağıran taraf üçünü birden sormak zorunda: tavanı boş bulup rezervesi
    sığmayan bir replika kurmak, ilk yazma yükünde OOM demektir.
    """
    total, available = host_memory_mb()
    if total <= 0:
        # /proc/meminfo okunamadı: sıfır bütçe döndürmek, "yer var" demekten
        # iyidir — bilinmeyen bir bütçeye replika kurdurmak aşırı taahhüdün
        # ta kendisi olurdu.
        return 0, {"host_total_mb": 0, "host_available_mb": 0,
                   "os_reserve_mb": 0, "core_reserve_mb": CORE_RESERVE_MB,
                   "allocatable_mb": 0, "committed_mb": 0,
                   "stack_reserved_mb": 0,
                   "overcommit_limit": OVERCOMMIT_LIMIT,
                   "overcommit_ratio": 0.0, "ceiling_free_mb": 0,
                   "reserve_free_mb": 0, "kernel_free_mb": 0,
                   "pressure": host_pressure(), "free_mb": 0}
    os_reserve = os_reserve_mb(total)
    allocatable = allocatable_mb(total)
    # Kendi defterimize değil docker'ın söylediğine bakıyoruz: elle konmuş
    # tavanlar da deftere yazılıdır ve tavan bütçesini onlar da tüketir.
    committed = stack_ceiling_mb()
    reserved = stack_reserved_mb()
    ceiling_free = int(allocatable * OVERCOMMIT_LIMIT) - committed
    reserve_free = allocatable - reserved
    return ceiling_free, {
        "host_total_mb": total, "host_available_mb": available,
        "os_reserve_mb": os_reserve, "core_reserve_mb": CORE_RESERVE_MB,
        "allocatable_mb": allocatable, "committed_mb": committed,
        "stack_reserved_mb": reserved,
        "overcommit_limit": OVERCOMMIT_LIMIT,
        "overcommit_ratio": (round(committed / float(allocatable), 2)
                             if allocatable > 0 else 0.0),
        "ceiling_free_mb": ceiling_free, "reserve_free_mb": reserve_free,
        "kernel_free_mb": available, "pressure": host_pressure(),
        # Eski ad: panel ve selftest bunu okuyor. Yumuşak kuralın boşluğudur.
        "free_mb": ceiling_free}


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


def catalog_for_client():
    """Kataloğu ORTAMA göre uyarlar.

    Şimdilik tek uyarlama SQL Server lisansı. Katalog Express'i (ücretsiz,
    üretimde kullanılabilir) anlatır çünkü ürünün varsayılanı odur; ama .env
    içinde MSSQL_PID=Developer yazan eski bir kurulumda panel o kurulumu
    "üretimde kullanılabilir" diye göstermemeli — Developer sürümü ücretsizdir
    ama üretimde kullanmak lisans ihlalidir. Kullanıcı kendi .env'ini
    değiştirdiğinde panelin de doğruyu söylemesi gerekiyor.
    """
    data = copy.deepcopy(CATALOG.data)
    pid = (_dotenv().get("MSSQL_PID") or "Express").strip()
    for e in data.get("engines", []):
        if e["id"] != "mssql":
            continue
        if pid.lower() == "express":
            break            # katalogdaki hâli zaten Express'i anlatıyor
        if pid.lower() == "developer":
            e["license"] = {
                "name": "Developer Edition — YALNIZ GELİŞTİRME/TEST",
                "free_for_production": False,
                "note": (".env içinde MSSQL_PID=Developer yazıyor. Bu sürüm ücretsizdir "
                         "ama üretimde kullanmak lisans ihlalidir. Ücretsiz ve üretimde "
                         "kullanılabilir sürüm için .env'de MSSQL_PID=Express yapın "
                         "(veritabanı başına 10 GB sınırı)."),
                "alternative": "MSSQL_PID=Express (ücretsiz, 10 GB/DB) ya da Standard/Enterprise",
            }
        else:
            e["license"] = {
                "name": "%s Edition — satın alınmış lisans gerekir" % pid,
                "free_for_production": False,
                "note": (".env içinde MSSQL_PID=%s yazıyor. Bu sürüm için Microsoft'tan "
                         "lisans satın alınmış olmalıdır. Ücretsiz seçenek: "
                         "MSSQL_PID=Express (veritabanı başına 10 GB)." % pid),
                "alternative": "MSSQL_PID=Express (ücretsiz, 10 GB/DB)",
            }
        e["summary"] = e["summary"].replace("Express", pid)
    return data


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
# eid → (servis, healthcheck'in "starting" demeye başladığı an). Servis adı
# ŞART: devirden sonra ana kopya başka bir container olur ve bayat damga yeni
# düğümü lütuf süresinden mahrum bırakırdı.
_STARTING_SINCE = {}
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
    # İzleme hedef listesi de burada tazeleniyor: motor açılıp kapandığında
    # yönlendirme tablosu neyse hedef listesi de odur. Ayrı bir çağrı noktası
    # bırakmak, iki listeden birinin unutulup sessizce eskimesi demekti.
    try:
        write_prometheus_targets()
    except Exception as e:
        log("prometheus hedef listesi yazılamadı:", e)
    return ROUTES_FILE


TARGETS_INTERVAL = int(os.environ.get("TARGETS_INTERVAL", "30"))


def write_prometheus_targets():
    """state/prometheus/targets.json — Prometheus'un file_sd hedef listesi.

    Prometheus dosyayı kendisi izler (refresh_interval), bu yüzden motor açıp
    kapatınca yeniden başlatma ya da reload GEREKMEZ.

    Yalnız AYAKTA olan exporter'lar yazılır. Kapalı motoru listede tutmak, her
    kapalı motor için "erişilemiyor" alarmı üretirdi — oysa kapalı olmak arıza
    değil, bu üründe normal bir durumdur.
    """
    path = os.path.join(STATE_DIR, "prometheus", "targets.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    running = {c["service"] for c in docker_containers() if c["status"] == "running"}
    items = []
    for e in CATALOG.engines:
        ex = e.get("exporter") or {}
        if not ex.get("port") or ex.get("service") not in running:
            continue
        items.append({
            "targets": ["%s:%d" % (ex["service"], int(ex["port"]))],
            "labels": {
                "engine": e["id"],
                "engine_name": e["name"],
                # file_sd'de bu özel etiket, hedefin metrik yolunu belirler.
                # MinIO gibi kendi ucunu farklı yolda sunanlar için şart.
                "__metrics_path__": ex.get("scrape_path", "/metrics"),
            },
        })
    body = json.dumps(items, ensure_ascii=False, indent=1)
    # YERİNDE yazılıyor: dosya gateway'e değil Prometheus'a bağlanıyor ve
    # bind-mount inode'a bağlıdır; geçici dosya + rename yapsaydık container
    # eskimiş inode'u okumaya devam ederdi (routes.conf'ta bu gerçek bir
    # olaydı — devir "başarılı" göründü ama bağlantılar koptu).
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
        f.flush()
        os.fsync(f.fileno())
    return path


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

        # Exporter'ın bağlanacağı düğüm. Adres SERVİS TANIMINDA sabit yazılıydı
        # ve devirden sonra fence edilmiş eski primary'yi göstermeye devam
        # ediyordu: gerçek sunucuda topoloji `mariadb-replica` derken exporter
        # hâlâ `mariadb:3306`e bakıyor, mysql_up=0 kalıyor ve o motorun BÜTÜN
        # grafikleri boşalıyordu. Yani izleme, tam da en çok ihtiyaç duyulan
        # anda — devirden hemen sonra — körleşiyordu. Yedekleme betiğinde aynı
        # sınıftan hata primary_of() ile kapatılmıştı; exporter'lar atlanmış.
        lines.append("%s_PRIMARY_HOST=%s" % (
            {"postgresql": "POSTGRES", "redis": "REDIS", "mariadb": "MARIADB"}[eid],
            prim))
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
    # Bağlam CÜMLENİN BAŞINDA veriliyor: "(mariadb yedeğinin yeniden kurulumu)"
    # parantezi, "veritabanı tarafında yapılacak bir şey yok" cümlesinin ardına
    # geldiğinde havada kalan bir parça gibi okunuyordu.
    msg = ("%s sırasında yönlendirme tablosu gateway'e uygulanamadı — uygulamalar "
           "hâlâ ESKİ adrese gidiyor. Sunucuda `docker restart gateway` "
           "çalıştırın; veritabanı tarafında yapılacak bir şey yok." % what)
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


def script_has_phase(script, phase):
    """Betikte `<faz>)` diye bir case dalı GERÇEKTEN var mı?

    Çıkış kodu bu soruyu cevaplayamıyor: `case` eşleşmeyen bir fazda sessizce 0
    döner (yani "yapıldı" sanılır), bazı betiklerde ise akış alakasız bir dala
    düşüp hata döndürür — Redis'te `cleanup` çağrısı replikanın bağlanmasını
    bekleyen döngüye düşüyor, 90 saniye sonra 1 dönüyor ve controller bunu
    "temizlik başarısız" sayıp yedeği hiç kaldırmıyordu. Fazı çağırmadan önce
    dosyada arıyoruz: yoksa çağırmıyoruz.
    """
    try:
        with open(script, encoding="utf-8") as f:
            for line in f:
                s = line.split("#", 1)[0].strip()
                if s.startswith(phase + ")") or s.startswith('"%s")' % phase) \
                        or s.startswith(phase + "|"):
                    return True
    except OSError as e:
        log("betik okunamadı:", script, e)
    return False


def _pg_slots_left(primary, env):
    """Ana kopyada GERİDE KALAN replikasyon slot'larının adları.

    [] = temiz, [ad, …] = kalıntı var, None = soramadık.

    Neden betiğin çıkış koduna güvenmiyoruz: temizlik dalındaki psql çağrıları
    `>/dev/null 2>&1 || true` ile bitiyor ve dal `echo` ile kapanıyor; docker
    exec tamamen başarısız olsa bile betik 0 döner. Üstelik betik tek bir slot
    adı biliyor (POSTGRES_REPLICATION_SLOT), oysa devirden sonra yeniden kurulan
    yedek ana kopyada BAŞKA adlı bir slot açar (POSTGRES_SLOT_PRIMARY) — adı ne
    olursa olsun geride kalan her slot WAL biriktirir, o yüzden hepsini sayarız.
    """
    pw = env.get("POSTGRES_PASSWORD") or env.get("DB_PASSWORD", "")
    su = env.get("POSTGRES_USER", "root")
    rc, out, _ = run(["docker", "exec", "-e", "PGPASSWORD=" + pw, primary,
                      "psql", "-U", su, "-d", "postgres", "-tAc",
                      "SELECT slot_name FROM pg_replication_slots"], timeout=60)
    if rc != 0:
        return None
    return [x.strip() for x in out.splitlines() if x.strip()]


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
BUSY_MSG = ("%s için şu anda başka bir işlem sürüyor (aç/durdur, yedek kopya kurma "
            "ya da devir). Bitmesini bekleyip tekrar deneyin; aynı anda ikisini "
            "birden çalıştırmak veri kaybına yol açabilir.")


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
    # Ana kopya artık BAŞKA bir container. "açılıyor" (starting) damgası eski
    # düğüme aitti; taşınırsa yeni ana kopya açılış lütfundan hiç yararlanamaz.
    _STARTING_SINCE.pop(eid, None)
    write_roles()      # roller yer değiştirdi — yeni rol dosyasını üret
    write_routes()
    routed, route_err = gateway_reload_or_alert(eid, "%s → %s devri" % (old, new))

    # Exporter'ı yeni ana kopyaya çevir. roles.env'i yazmak TEK BAŞINA yetmez:
    # env değişkenleri container YARATILIRKEN okunur, çalışan container eski
    # adresiyle kalır. Gerçek sunucuda ölçtüm — devirden sonra mysql_up=0'a
    # düşüyor ve o motorun bütün grafikleri boşalıyordu; yani izleme tam da
    # devirden sonra, en çok ihtiyaç duyulan anda körleşiyordu.
    # Bu adım başarısız olursa devir BAŞARISIZ SAYILMAZ: veritabanı çalışıyor,
    # yalnız grafikleri eksik kalır. Kullanıcıya olayla haber veriyoruz.
    # Yalnız AYRI bir exporter container'ı olan motorlar için. RabbitMQ,
    # ClickHouse ve MinIO metrikleri kendi içlerinden sunar (exporter.builtin);
    # onlarda çevrilecek ayrı bir container yok.
    exp = (engine.get("exporter") or {}).get("service")
    if exp and exp != engine["primary_service"] and exp in engine.get("services", []):
        rc_e, out_e, err_e = run(
            compose_base() + ["--profile", engine["profile"], "up", "-d",
                              "--force-recreate", "--no-deps", exp],
            timeout=300)
        if rc_e == 0:
            jl("   izleme ucu yeni ana kopyaya çevrildi:", exp, "→", new)
        else:
            jl("   UYARI: izleme ucu güncellenemedi:", (err_e or out_e).strip()[-200:])
            record_event("exporter_stale", eid,
                         "Devir tamamlandı ama izleme ucu (%s) yeni ana kopyaya "
                         "çevrilemedi; bu motorun grafikleri boş kalabilir. "
                         "Veritabanı etkilenmedi." % exp, level="warning")

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


def _son_gunluk(service, satir=6):
    """Container'ın son log satırları — tanı mesajına eklemek için.
    Ölçemezsek boş döneriz; tanı ipucu olmaması, yanlış ipucu vermekten iyidir."""
    rc, out, err = run(["docker", "logs", "--tail", str(satir), service],
                       timeout=20)
    metin = " | ".join(x.strip() for x in (out + err).splitlines() if x.strip())
    return metin[-400:] if rc == 0 or metin else ""


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

    ⚠️ `ready` TEK BAŞINA KANIT DEĞİLDİR: üç betikte de "zaten primary/zaten
    master" hâli 0 döner, çünkü `ready` "yükseltmeye hazır mısın" sorusudur,
    "yedek misin" sorusu değil. Tüm güvenlik `check`in ondan önce çalışmasına
    bağlıydı; `check` bir tur boyunca düğüme ulaşamazsa (motor tam o anda
    bağlantı kabul etmeye başlıyor, MariaDB'de is_primary iki ayrı sorgu yapar
    ve ilki geçici olarak düşebiliyor) doğrulama, hacmi AZ ÖNCE SİLİNMİŞ boş bir
    yazılabilir düğümü "yedek kuruldu" diye geçiriyordu. Bu yüzden 0 cevabını
    kabul etmeden önce ölçümü BİR KEZ DAHA yapıyoruz.
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
            low = last.lower()
            if ("zaten primary" in low or "zaten master" in low
                    or node_is_writable_primary(engine, service, None) is True):
                return False, ("%s yedek olarak değil, İKİNCİ BİR YAZILABİLİR ANA "
                               "KOPYA olarak açıldı (betik: %s)" % (service, last))
            return True, last
        if time.time() >= deadline:
            # CONTAINER'IN DURUMUNU DA SÖYLE. Betiğin cevabı "yedek değil"
            # olduğunda sebep çoğu zaman düğümün HİÇ AÇILMAMASIDIR ve o bilgi
            # yalnız docker'da durur. Gerçek bir olayda redis, compose'daki bir
            # yapılandırma hatası yüzünden her açılışta ölüyordu; kullanıcıya
            # 900 saniye sonra "yedek konumuna geçmedi" deniyor, "container
            # ayakta bile değil" denmiyordu. İnsan yanlış yerde arıyor.
            cstat, chealth = _health_of(service)
            ipucu = ""
            if cstat != "running":
                ipucu = (" Container ŞU AN ÇALIŞMIYOR (durum: %s) — sorun "
                         "kopyalamada değil, düğümün kendisinde. `docker logs "
                         "%s` çıktısına bakın." % (cstat, service))
                gunluk = _son_gunluk(service)
                if gunluk:
                    ipucu += " Son satırlar: %s" % gunluk
            elif chealth and chealth != "healthy":
                ipucu = (" Container çalışıyor ama sağlık durumu '%s'. `docker "
                         "logs %s` çıktısına bakın." % (chealth, service))
            return False, ("%s %d saniyede yedek konumuna geçmedi. Son durum: %s.%s "
                           "Büyük veritabanlarında ilk kopyalama bu süreyi aşabilir: "
                           "STANDBY_VERIFY_TIMEOUT değerini .env'de artırıp tekrar "
                           "deneyebilirsiniz."
                           % (service, STANDBY_VERIFY_TIMEOUT,
                              last or "(çıktı yok)", ipucu))
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
                      "değilken yedeği silmiyoruz. Sunucuda `docker logs %s` "
                      "çıktısına bakın; ana kopya yazmaya açıldıktan sonra bu "
                      "düğmeye tekrar basın." % (prim, prim), "critical")

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

    # ANA KOPYADAKİ KALINTIYI, DÜĞÜMÜ AÇMADAN ÖNCE TEMİZLE.
    # PostgreSQL'de yeni düğüm entrypoint'inde `pg_basebackup -S <slot> -C`
    # çalıştırır: slot'u YARATMAK ister. Önceki ilişkiden kalan aynı adlı bir
    # slot ana kopyada duruyorsa komut şununla ölür ve düğüm sonsuz
    # crash-loop'a girer:
    #     ERROR: replication slot "replica_from_primary" already exists
    # Sunucuda ölçüldü: 'failover rebuild postgresql' 900 saniye boyunca bu
    # döngüde kaldı ve kullanıcıya gösterilen mesaj bambaşkaydı ("postgresql
    # hiç WAL almamış"); gerçek sebep yalnız `docker logs` çıktısındaydı.
    #
    # Temizliği yapan faz zaten var: replikasyon betiğinin 'prepare' fazı.
    # Yalnız MariaDB için çağrılıyordu; PostgreSQL bu yolda hiç prepare
    # görmüyordu. Sıra ÖNEMLİ — düğüm açıldıktan sonra çalıştırmak yarış
    # demektir: entrypoint basebackup'ı slot silinmeden başlatabilir.
    script = script_path("replication", eid)
    if os.path.exists(script) and script_has_phase(script, "prepare"):
        prep_env = script_env()
        prep_env.update(REPLICATION_PRIMARY=prim, REPLICATION_STANDBY=old)
        jl("ana kopya hazırlanıyor (kalıntı slot/rol temizliği):", prim)
        rc, out, err = run(["sh", script, "prepare"], timeout=900, env=prep_env)
        jl((out + err).strip()[-2000:])
        if rc != 0:
            return refuse(
                "Ana kopya (%s) yeniden kurulum için hazırlanamadı "
                "(çıkış %d): %s. "
                "Önceki ilişkiden kalan replikasyon slot'u silinemediyse yeni "
                "düğüm 'replication slot already exists' ile açılamaz."
                % (prim, rc, (err or out).strip()[-300:]), "critical")

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
        # Yarıda kesilmiş bir kopyalama (pg_basebackup) DİSKTE KALIR ve
        # entrypoint klonlamayı yalnız veri dizini BOŞKEN yapar: düğüm olduğu
        # gibi açılırsa eksik veri dizinini açmaya çalışıp crash-loop'a girer.
        # Kurtarma yolu bu düğmenin kendisidir (hacmi silip baştan kopyalar);
        # kullanıcıya bunu açıkça söylüyoruz.
        return refuse("%s. Düğüm güvenlik için durduruldu; veri kaybı olmasın diye "
                      "ana kopyaya dokunulmadı. Sunucuda `docker logs %s` çıktısına "
                      "bakıp sorunu giderin, sonra 'Eski kopyayı yeniden kur'a "
                      "tekrar basın: bu işlem yarım kalan kopyayı silip baştan "
                      "alır." % (detail, old), "critical")
    jl("   doğrulandı:", detail)

    # ROLLER ARTIK TUTARLI — topolojiye bunu YAZIYORUZ. Eskiden rebuild
    # topolojiye hiç dokunmuyordu; devirden sonra kayıt sonsuza dek "devir
    # yapıldı, eski kopya durduruldu" diyor, dashboard aynı uyarıyı ve aynı
    # düğmeyi göstermeye devam ediyor, "Replikayı kapat"/"Replika kur" ise
    # "önce eski kopyayı yeniden kurun" diye reddediliyordu — oysa o işlem az
    # önce BAŞARIYLA bitmişti. Kullanıcı çıkışı olmayan bir döngüye giriyordu.
    # Devir kaydını SİLMİYORUZ (hangi düğümün güncel veriyi taşıdığını yalnız o
    # biliyor); yanına "yedek yeniden kuruldu" damgasını basıyoruz.
    topo = load_topology()
    ent = dict(topo.get(eid, {}))
    ent["primary"] = prim
    ent["standby"] = old
    ent["rebuilt_at"] = int(time.time())
    topo[eid] = ent
    save_topology(topo)
    _STARTING_SINCE.pop(eid, None)   # roller değişti, açılış damgası eskidi

    write_routes()
    routed, route_err = gateway_reload_or_alert(eid, "%s yedeğinin yeniden kurulumu" % old)
    record_event("rebuild", eid, "%s yeniden replika olarak kuruldu; roller tutarlı "
                                 "(ana kopya: %s)" % (old, prim), level="info")
    if not routed:
        jl("UYARI:", route_err)
        return False, ("Yedek kopya (%s) kuruldu ve ana kopyayı takip ediyor, ancak %s"
                       % (old, route_err))
    return True, None


def health_verdict(eid, pstat, phealth, service=None):
    """Denetleyicinin sağlık yorumu: "ok" | "starting" | "bad".

    "starting" HATA DEĞİLDİR — motor daha açılıyor demektir. Docker healthcheck'i
    start_period boyunca bunu döndürür (MariaDB'de 60 sn, PostgreSQL'de 30 sn).
    Eskiden bu da sağlıksızlık sayılıyordu: sıradan bir sunucu reboot'unda
    denetleyici 30 saniyede 3 vuruşu doldurup açılışını yapan ana kopyayı
    ortasından kesiyor, daha kendisi de açılmamış yedeği yükseltmeye çalışıyordu.
    Artık sayaç DONDURULUYOR — ama sonsuza kadar değil: açılış makul süreyi
    aşarsa (motor gerçekten açılamıyorsa) yeniden sağlıksızlık sayılır.

    Damga HANGİ SERVİSE ait olduğuyla birlikte tutulur. Motor kimliğine göre
    tutulduğunda devirden hemen sonra şu oluyordu: eski ana kopyanın bayat
    damgası kayıtta kalıyor, yükseltilen YENİ ana kopya "starting" dediğinde
    setdefault o bayat damgayı koruyor ve düğüm lütuf süresinden HİÇ
    yararlanmadan anında "bad" sayılıyordu — yani düzeltmenin asıl vaadi
    ("açılmakta olan ana kopyayı kesme") tam da en çok gerektiği anda
    geçersiz kalıyordu."""
    if pstat == "running" and phealth in ("healthy", "none"):
        _STARTING_SINCE.pop(eid, None)
        return "ok"
    if pstat == "running" and phealth == "starting":
        rec = _STARTING_SINCE.get(eid)
        if not rec or rec[0] != service:   # başka bir düğüm açılıyor → damgayı sıfırla
            rec = (service, time.time())
            _STARTING_SINCE[eid] = rec
        return "starting" if (time.time() - rec[1]) < FAILOVER_STARTING_GRACE else "bad"
    _STARTING_SINCE.pop(eid, None)
    return "bad"


def _alert_once(eid, key, message, every=600):
    """Aynı uyarıyı her 10 sn'de bir tekrarlamadan, ama unutmadan da bildirir."""
    now = time.time()
    if now - _ALERTED.get((eid, key), 0) < every:
        return
    _ALERTED[(eid, key)] = now
    record_event("failover_impossible", eid, message, level="critical")


def prometheus_target_refresher():
    """Hedef listesini düzenli olarak yeniden üretir.

    NEDEN ZAMANLAYICI: liste ilk sürümde write_routes()'a bağlıydı ve
    write_routes AKTİVASYONDA ÇAĞRILMIYOR — çağrılmasına gerek de yok, çünkü
    routes.conf'un içeriği hangi motorun ayakta olduğuna bağlı değil (nginx
    DNS'i istek anında çözüyor). Sonuç: temiz kurulumdan sonra beş motor
    açıldığı hâlde targets.json açılıştaki "[]" hâlinde kaldı ve İZLEMENİN
    TAMAMI boş çizdi. Uçtan uca test bunu yakaladı.
    Bir çağrı noktası eklemek yerine zamanlayıcı koyuyoruz: böylece gelecekte
    eklenecek hiçbir yol (elle `docker start` dahil) bunu unutamaz.
    """
    while True:
        try:
            write_prometheus_targets()
        except Exception as e:
            log("hedef listesi yazılamadı:", e)
        time.sleep(TARGETS_INTERVAL)


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
            # Bu turun container görüntüsü GERÇEKTEN docker'dan mı geldi?
            # "Soramadık" ile "container yok" karıştırılırsa yavaş bir docker
            # daemon'ı üst üste 3 vuruş üretip devir denemesi başlatır.
            docker_containers()
            if not docker_snapshot_ok():
                log("docker container listesi alınamadı (daemon yanıt vermiyor) — "
                    "bu tur atlandı, sayaçlara dokunulmadı")
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
                    # Koşul `pstat != "running"` DEĞİL, sağlık yorumudur: devrin
                    # asıl sebebi (disk dolu, bozuk tablo) container'ı çalışır
                    # bırakır, yalnız healthcheck'i düşürür — tam o durumda
                    # sistem yine sessiz kalıyordu.
                    if health_verdict(eid, pstat, phealth, prim) == "bad":
                        _alert_once(eid, "no-standby",
                                    "%s ana kopyası sağlıksız (%s/%s) ve devredilecek "
                                    "bir yedek kopya YOK — otomatik devir yapılamıyor. "
                                    "Elle müdahale gerekiyor: önce 'Yedek Kopya Kur' "
                                    "ile bir replika kurun."
                                    % (engine["name"], pstat, phealth))
                    continue

                verdict = health_verdict(eid, pstat, phealth, prim)
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
                waited = int(time.time() - _STARTING_SINCE.get(eid, (None, time.time()))[1])
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
    engine = CATALOG.engine(eid)
    # HTTP ucu motor kimliğini zaten katalogla doğruluyor; buradaki kontrol,
    # doğrudan çağrılan bir iş thread'inin sessizce "devam ediyor" kalmasını önler.
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    # Aç/kapat da devir/kurtarma ile AYNI SIRADA yürür. Devir sürerken (eski
    # primary fence edilmiş, yükseltme henüz bitmemiş, topology HENÜZ YAZILMAMIŞ)
    # panelden basılan bir düğme, kilitsiz okunan eski topolojiye göre yanlış
    # düğüme dokunuyordu.
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return job_done(jid, False, BUSY_MSG % engine["name"])
    try:
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
        failed_over = prim != engine["primary_service"] and bool(rep.get("profile"))
        if failed_over:
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
            if failed_over:
                # `--no-deps` BURADA ŞART. Yukarıda eskimiş primary'yi servis
                # listesinden çıkarmak TEK BAŞINA İŞE YARAMIYOR: panel, exporter
                # ve replika servislerinin hepsi compose'da
                # `depends_on: <asıl primary>: service_healthy` taşıyor, yani
                # compose onu YİNE yaratır ve sağlıklı olmasını bekler. O düğümün
                # veri hacmi dolu olduğu için entrypoint klonlamayı atlar ve düğüm
                # ESKİMİŞ veriyle yazılabilir İKİNCİ BİR ANA KOPYA olarak açılır
                # (replika okuma portu host'a açık olduğundan uygulamalar oraya
                # yazmaya bile başlayabilir) — engellemeye çalıştığımız
                # split-brain'in ta kendisi. Bayrak yalnız devir durumunda
                # veriliyor; normal açılışta depends_on'un sıralaması (önce
                # veritabanı, sonra panel) işimize yarıyor.
                #
                # Bayrak sıralamayı da iptal ettiği için sırayı kendimiz kuruyoruz:
                # önce güncel ana kopya, sonra panel/exporter.
                rest = [s for s in services if s != prim]
                cmd = compose_base() + args + ["up", "-d", "--no-deps", prim]
                job_log(jid, "$", " ".join(cmd[-8:]))
                rc, out, errout = run(cmd, timeout=1800)
                if rc == 0 and rest:
                    cmd2 = compose_base() + args + ["up", "-d", "--no-deps",
                                                    "--remove-orphans"] + rest
                    job_log(jid, "$", " ".join(cmd2[-8:]))
                    rc, o2, e2 = run(cmd2, timeout=1800)
                    out, errout = out + o2, errout + e2
            else:
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
        route_err = None
        if failed_over:
            # EMNİYET KEMERİ: eskimiş asıl primary bir şekilde ayaktaysa (elle
            # başlatılmış, restart politikasıyla geri gelmiş) ve YAZMA KABUL
            # EDİYORSA ortada iki ana kopya var demektir. Ölçüp durduruyoruz —
            # yeniden kurulmuş, read-only bir yedek bundan etkilenmez.
            stale = engine["primary_service"]
            if any(c["service"] == stale and c["status"] == "running"
                   for c in docker_containers(force=True)) \
                    and node_is_writable_primary(engine, stale) is True:
                job_log(jid, "UYARI: eskimiş kopya (%s) yazılabilir durumda ayakta — "
                             "durduruluyor" % stale)
                run(["docker", "stop", "-t", "15", stale], timeout=120)
                record_event("split_brain_prevented", eid,
                             "%s eskimiş verisiyle yazılabilir durumda ayaktaydı ve "
                             "durduruldu; güncel ana kopya %s. Eski kopyayı geri "
                             "almak için 'Eski kopyayı yeniden kur' düğmesini "
                             "kullanın." % (stale, prim), level="critical")
            # Yönlendirme tablosu açık motorları da göstermeli; devir sonrası
            # yeniden açılan motorda gateway'in hedefi tazelenmezse istekler
            # var olmayan container'a gider.
            write_routes()
            routed, route_err = gateway_reload_or_alert(
                eid, "%s yeniden açılışı" % engine["name"])
            if not routed:
                # Dönüş değerini ATMIYORUZ. Atıldığında iş "✅ Tamamlandı"
                # görünüyor, kullanıcı veritabanının açıldığını sanıyor, oysa
                # gateway hâlâ ölü hedefe yönlendirdiği için hiçbir uygulama
                # bağlanamıyordu. Devir ve yeniden kurma yollarında bu karar
                # zaten böyle verilmişti; burada da aynısını yapıyoruz.
                job_log(jid, "UYARI:", route_err)
        record_event("activate", eid,
                     "%s açıldı — %d MB ayrıldı%s"
                     % (engine["name"], p["limit_mb"],
                        "" if p.get("with_panel", True) else " (bellek dar, web paneli atlandı)"))
        if route_err:
            return job_done(jid, False, "Motor açıldı ancak " + route_err, {"plan": p})
        job_done(jid, True, None, {"plan": p})
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))
    finally:
        lock.release()


def do_deactivate(jid, eid):
    engine = CATALOG.engine(eid)
    # HTTP ucu motor kimliğini zaten katalogla doğruluyor; buradaki kontrol,
    # doğrudan çağrılan bir iş thread'inin sessizce "devam ediyor" kalmasını önler.
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    # "Durdur" da container SİLER. Kilitsiz kaldığı sürece şu senaryo açıktı:
    # otomatik devir başlar (eski primary fence edilmiş, yükseltme sürüyor,
    # topology henüz yazılmamış), operatör panelde "postgresql çalışmıyor"
    # görüp Durdur'a basar ve tam o anda primary'ye YÜKSELTİLMEKTE olan düğüm
    # `compose rm -f` ile silinir. Elde tek bir çalışan veritabanı kalmaz;
    # üstelik devrin geri alma yolu (`docker start <eski primary>`) da artık
    # var olmayan bir container'ı arar.
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return job_done(jid, False, BUSY_MSG % engine["name"])
    try:
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
        job_done(jid, rc == 0, None if rc == 0 else
                 "Motor durdurulamadı (compose 'stop' çıkış %d). Sunucuda "
                 "`docker ps` ile container'ların durumuna bakın, sonra tekrar "
                 "deneyin." % rc)
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))
    finally:
        lock.release()


def do_rebalance(jid):
    """Açık motorların TAVANLARINI şu anki koşullara göre yeniden hesaplar.

    Neden gerekiyor: tavanlar motorlar TEK TEK açılırken hesaplandı. Üçüncü
    motor açılırken ilk ikisinin tavanı çoktan konmuştu ve kimse geri dönüp
    "artık daha az yer var, sen de kıs" demedi. Ölçülen sonuç: 15984 MB'lık
    makinede tavan toplamı 15 GB'a çıktı, panel %122 aşım yazdı ve yeni motor
    açılamaz oldu — oysa aynı anda gerçek kullanım 1508 MB idi.

    Container YENİDEN BAŞLATILMAZ: `docker update --memory` cgroup limitini
    canlı değiştirir, kesinti olmaz. Motorun İÇ ayarları (buffer pool, JVM
    heap) çalışırken değişmez; onları tuning.env'e yazıyoruz ki bir sonraki
    açılışta tavanla uyumlu olsunlar. Küçültmede iç ayarı da küçültmek
    ŞARTTIR: yoksa motor bir dahaki açılışta kendi tavanının üstünde bellek
    ayırıp ilk sorguda OOM olur.
    """
    if BACKEND == "kubernetes":
        return job_done(jid, False,
                        "Yeniden dengeleme yalnız Docker backend'inde "
                        "çalışır: K8s'te limit değişimi pod'u yeniden "
                        "yaratır, yani "
                        "kesinti demektir.")
    # Aç/durdur ve devirle AYNI SIRADA yürür: tam bir aktivasyon sürerken
    # tavanları oynatmak, compose'un yarattığı container'ın limitini
    # yarıştırırdı.
    if not ACTION_LOCK.acquire(blocking=False):
        return job_done(jid, False,
                        "Şu anda başka bir yığın işlemi sürüyor (aç/durdur, "
                        "devir, yedek kopya). Yeniden dengeleme sıraya "
                        "girmez; bitmesini bekleyip tekrar deneyin.")
    try:
        total, available = host_memory_mb()
        if total <= 0:
            return job_done(jid, False,
                            "Host belleği okunamadı (/proc/meminfo)")
        allocatable = allocatable_mb(total)
        containers = docker_containers(force=True)
        calisan = {c["service"]: c for c in containers
                   if c["status"] == "running"}
        hedefler = []
        for e in CATALOG.engines:
            c = calisan.get(current_primary(e))
            if c:
                hedefler.append((e, c))
        if not hedefler:
            return job_done(jid, False,
                            "Açık motor yok — dengelenecek bir tavan da yok.")

        job_log(jid, "dağıtılabilir %d MB (toplam %d − OS %d − çekirdek %d), "
                     "aşırı taahhüt %.2f, çekirdek %d MB boş bildiriyor, "
                     "bellek baskısı '%s'"
                % (allocatable, total, os_reserve_mb(total), CORE_RESERVE_MB,
                   OVERCOMMIT_LIMIT, available, host_pressure()["seviye"]))

        # 1) İstenen tavanlar: aktivasyondaki formülün AYNISI. İki yerde iki
        #    formül tutmak, "yeniden dengele"den sonra motoru kapatıp açınca
        #    başka bir sayı çıkması demek olurdu.
        istek = {}
        for e, _c in hedefler:
            res = e.get("resources", {})
            istek[e["id"]] = int(_clamp(total * float(res.get("share", 0.2)),
                                        int(res.get("min_mb", 256)),
                                        int(res.get("max_mb", 8192))))

        # 2) YUMUŞAK KURAL: motorların tavan toplamı, dağıtılabilirin aşırı
        #    taahhüt katından "bizim dokunmadığımız" container'ların (panel,
        #    exporter, replika, gateway) tavanları düşüldükten sonra kalanı
        #    aşamaz. Aşıyorsa hepsi AYNI oranda kısılır: kimse ayrıcalıklı
        #    değil, sıraya göre son açılan cezalandırılmıyor.
        prim_isimler = {c["service"] for _e, c in hedefler}
        disari = sum(c["memory_mb"] for c in containers
                     if c["status"] == "running"
                     and c["service"] not in prim_isimler)
        pay = int(allocatable * OVERCOMMIT_LIMIT) - disari
        toplam = sum(istek.values())
        if pay <= 0:
            # Motor dışı container'ların tavanları tek başına bütçeyi yemiş.
            # Motorlara verebileceğimiz en dürüst değer asgarileridir; daha
            # fazlasını vermek defteri yeniden şişirmek olurdu.
            for k in istek:
                istek[k] = int(CATALOG.engine(k).get("resources", {})
                               .get("min_mb", 256))
            job_log(jid, "UYARI: motor dışı container tavanları (%d MB) tavan "
                         "bütçesini tüketmiş — motorlar asgari tavana çekildi"
                    % disari)
        elif toplam > pay and toplam > 0:
            oran = float(pay) / toplam
            for k in istek:
                res = CATALOG.engine(k).get("resources", {})
                istek[k] = max(int(res.get("min_mb", 256)),
                               int(istek[k] * oran))
            job_log(jid, "tavan bütçesi dar (%d MB istendi, %d MB var): "
                         "istekler %.2f katsayısıyla kısıldı"
                    % (toplam, pay, oran))

        # 3) SERT KURAL: yeni tavanlardan türeyecek REZERVE toplamı
        #    dağıtılabiliri aşamaz. Aşıyorsa %10'luk adımlarla iniyoruz;
        #    min_mb'nin altına inmek motoru açılamaz hâle getirir, orada
        #    duruyoruz ve durumu günlüğe yazıyoruz.
        for _ in range(20):
            rez = sum(engine_reserved_mb(e["id"], limit_mb=istek[e["id"]])
                      for e, _c in hedefler)
            if rez <= allocatable:
                break
            for e, _c in hedefler:
                mn = int(e.get("resources", {}).get("min_mb", 256))
                istek[e["id"]] = max(mn, int(istek[e["id"]] * 0.9))
        else:
            rez = sum(engine_reserved_mb(e["id"], limit_mb=istek[e["id"]])
                      for e, _c in hedefler)
            job_log(jid, "UYARI: rezerve toplamı asgari tavanlarda bile "
                         "dağıtılabiliri aşıyor (%d MB > %d MB) — bir motoru "
                         "durdurmadan bu sunucuya sığmaz" % (rez, allocatable))

        # 4) Uygula. Tavan, ölçülen GERÇEK kullanımın altına İNDİRİLEMEZ.
        tun = load_tuning()
        degisen = uygulanan = hata = 0
        for e, c in hedefler:
            eid = e["id"]
            eski = c["memory_mb"]
            yeni = int(istek[eid])
            kullanim = container_usage_mb(c)
            if kullanim is not None:
                taban = int(kullanim * REBALANCE_HEADROOM)
                if yeni < taban:
                    job_log(jid, "%s: hesaplanan tavan %d MB, gerçek "
                                 "kullanımın %.2f katının (%d MB) altında "
                                 "kalıyordu — tabana çekildi; cgroup limiti "
                                 "anlık kullanımın altına inerse container "
                                 "ANINDA OOM olur"
                            % (eid, yeni, REBALANCE_HEADROOM, taban))
                    yeni = taban
            elif yeni < eski:
                job_log(jid, "%s: gerçek kullanım ölçülemedi — tavan "
                             "KÜÇÜLTÜLMÜYOR (körlemesine küçültmek anında OOM "
                             "demektir)" % eid)
                yeni = eski
            yeni = max(yeni, int(e.get("resources", {}).get("min_mb", 256)))
            if abs(yeni - eski) < REBALANCE_MIN_DELTA_MB:
                job_log(jid, "%s: %d MB — değişiklik yok (kullanım %s)"
                        % (eid, eski,
                           "%d MB" % kullanim if kullanim is not None
                           else "ölçülemedi"))
                continue
            degisen += 1
            # --memory-swap AYNI değerle veriliyor: swap'a taşma yok. Docker
            # memory-swap < memory kabul etmez, ikisini tek çağrıda vermek
            # büyütmede de küçültmede de doğru sırayı garanti eder.
            rc, out, err = run(["docker", "update",
                                "--memory", "%dm" % yeni,
                                "--memory-swap", "%dm" % yeni,
                                c["name"]], timeout=120)
            if rc != 0 and "swap" in (out + err).lower():
                # Bazı çekirdeklerde swap muhasebesi derlenmemiştir ("Your
                # kernel does not support swap limit capabilities") ve docker
                # --memory-swap'ı reddeder. Tavanın KENDİSİNİ yine de
                # koyabiliyoruz; swap zaten yoksa ikisi aynı şeydir. Bu dal
                # olmadan dengeleme, sırf bir çekirdek seçeneği yüzünden
                # hiçbir şey yapamadan başarısız görünürdü.
                job_log(jid, "%s: --memory-swap reddedildi (çekirdekte swap "
                             "muhasebesi kapalı olabilir), yalnız --memory "
                             "ile yeniden deneniyor" % eid)
                rc, out, err = run(["docker", "update",
                                    "--memory", "%dm" % yeni,
                                    c["name"]], timeout=120)
            if rc != 0:
                hata += 1
                job_log(jid, "%s: docker update BAŞARISIZ (%d): %s"
                        % (eid, rc, (out + err).strip()[-300:]))
                continue
            uygulanan += 1
            tun[eid] = compute_tuning(e, yeni)
            job_log(jid, "%s: %d MB → %d MB (kullanım %s, rezerve %d MB)"
                    % (eid, eski, yeni,
                       "%d MB" % kullanim if kullanim is not None
                       else "ölçülemedi",
                       engine_reserved_mb(eid, limit_mb=yeni)))

        if uygulanan:
            # tuning.env, bir sonraki açılışta compose'un okuyacağı dosya.
            # Yazmazsak `compose up` eski tavanı geri koyar ve dengeleme
            # sessizce geri alınırdı.
            save_tuning(tun)
            job_log(jid, "tuning.env güncellendi — iç ayarlar (buffer pool, "
                         "heap) motorun BİR SONRAKİ açılışında geçerli olur; "
                         "tavan ise şimdiden değişti, kesinti olmadı")
            docker_containers(force=True)     # panel güncel tavanı görsün

        record_event("rebalance", "tümü",
                     "Tavanlar yeniden dengelendi: %d motorun %d'sinde tavan "
                     "değişti%s. Dağıtılabilir %d MB, aşırı taahhüt sınırı "
                     "%.2f. Container'lar yeniden başlatılmadı."
                     % (len(hedefler), uygulanan,
                        (", %d tanesinde docker update başarısız" % hata)
                        if hata else "", allocatable, OVERCOMMIT_LIMIT),
                     level="warning" if hata else "info")
        if hata:
            return job_done(jid, False,
                            "%d motorun tavanı güncellendi ama %d tanesinde "
                            "docker update başarısız oldu; ayrıntı iş "
                            "günlüğünde." % (uygulanan, hata))
        return job_done(jid, True, None,
                        {"changed": uygulanan, "considered": len(hedefler)})
    finally:
        ACTION_LOCK.release()


def do_replication(jid, eid, enable):
    engine = CATALOG.engine(eid)
    # HTTP ucu motor kimliğini zaten katalogla doğruluyor; buradaki kontrol,
    # doğrudan çağrılan bir iş thread'inin sessizce "devam ediyor" kalmasını önler.
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    rep = engine.get("replication", {})
    # Bu yol da container SİLİYOR; devirle aynı sırada yürümesi ŞART. Aşağıdaki
    # "silinecek düğüm şu anki ana kopya mı" kontrolü kilitsiz yapıldığında
    # klasik bir TOCTOU'ydu: devir sürerken topology henüz eski primary'yi
    # gösterdiği için kapı AÇIK kalıyor ve tam o anda yükseltilmekte olan düğüm
    # siliniyordu. Kapıyı artık kilidi ALDIKTAN SONRA okuyoruz.
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return job_done(jid, False, BUSY_MSG % engine["name"])
    try:
        if rep.get("mode") in ("unsupported", "native-cluster"):
            return job_done(jid, False,
                            "Bu motorda primary-replica desteklenmiyor: " + rep.get("note", ""))
        if BACKEND == "kubernetes":
            n = 2 if enable else 1
            rc, out, errout = _k8s_scale(engine, n)
            job_log(jid, out.strip() or errout.strip())
            return job_done(jid, rc == 0, None if rc == 0 else errout.strip())

        profile = rep["profile"]
        override = "%s-replica" % eid  # overrides/<eid>-replica.yml (varsa)

        # DEVİRDEN SONRA ROLLER TERSTİR: kataloğun "replica_service"i (ör.
        # postgresql-replica) artık CANLI ANA KOPYADIR, yedek olan düğüm ise
        # kataloğun "primary_service"idir. Bu yüzden hedefi katalogdan değil
        # standby_of()'tan alıyoruz: kataloğa bakan sürüm "replikasyonu kapat"
        # derken canlı ana kopyayı durdurup container'ını siliyordu (eski
        # primary zaten fence edilmiş olduğu için ortada çalışan hiçbir
        # veritabanı kalmıyordu), "replikayı kur" tarafı ise aynı düğümün
        # HACMİNİ siliyordu.
        #
        # Bunu bir REDLE kapatmak da işe yaramıyordu: red mesajı "önce Eski
        # kopyayı yeniden kur deyin" diyor, ama o işlem topolojiyi geri
        # almadığı (alması da doğru olmazdı — güncel veri gerçekten yedekte)
        # için koşul hiç değişmiyor ve kullanıcı sonsuz döngüye giriyordu.
        prim = current_primary(engine)
        svc = standby_of(engine) or rep["replica_service"]
        if svc == prim:
            # Buraya ancak topoloji tutarsızsa düşülür (primary alanı iki
            # düğümden hiçbiri değil gibi). Son emniyet olarak duruyor.
            msg = ("%s için topoloji kaydı tutarsız: yedek kopya olarak da ana "
                   "kopya olarak da '%s' görünüyor. Yanlış düğümü silmemek için "
                   "işlem durduruldu. Sunucuda state/topology.json dosyasına "
                   "bakın." % (engine["name"], prim))
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

            # DEVİRDEN SONRA "Replika Kur" YANLIŞ DÜĞMEDİR: yedek olarak
            # kurulacak düğüm (svc) artık eskimiş veriyi taşıyan eski ana
            # kopyadır. Bu yol onun hacmini SİLMEDEN container'ı açar (temiz
            # hacim adımı yalnız ilk kurulumda çalışıyor), yani düğüm dolu veri
            # dizini yüzünden klonlamayı atlar ve ikinci bir YAZILABİLİR ana
            # kopya olarak gelir. Doğru işlem, hacmi silip baştan kopyalayan
            # "Eski kopyayı yeniden kur"dur — ve o işlem BİTTİĞİNDE topolojiye
            # rebuilt_at damgası düştüğü için bu kapı da açılır; kullanıcı
            # yapamayacağı bir şeye yönlendirilmiş olmuyor.
            if prim != engine["primary_service"] \
                    and not load_topology().get(eid, {}).get("rebuilt_at"):
                msg = ("%s için devir yapılmış: güncel veri artık %s üzerinde. "
                       "Yedek kopyayı geri getirmek için 'Eski kopyayı yeniden kur' "
                       "düğmesini kullanın — o işlem %s'in eskimiş verisini silip "
                       "ana kopyadan baştan kopyalar. Bu düğme eski veriyi silmeden "
                       "açacağı için ikinci bir ana kopya oluşurdu."
                       % (engine["name"], prim, svc))
                record_event("replication_blocked", eid, msg, level="warning")
                return job_done(jid, False, msg)

            # Replika, devirden sonra AYNI yükü taşıyacağı için primary kadar
            # bellek ister. Yer yoksa yarıda kalmış bir kurulum bırakmak yerine
            # baştan reddediyoruz. (Ölçüm ŞU ANKİ ana kopyadan alınır; devirden
            # sonra kataloğun primary_service'i çalışmıyor olabilir.)
            prim_mb = 0
            for c in docker_containers():
                if c["service"] == prim and c["status"] == "running":
                    prim_mb = c["memory_mb"]
            if prim_mb:
                # plan_engine DEĞİL, free_budget_mb: plan_engine motorun KENDİ
                # servislerini taahhütten çıkarır ("yeniden boyutlandırsam ne
                # verebilirim" sorusu). Replika ana kopyanın YERİNE değil
                # YANINA geliyor; o çıkarma burada sunucuyu aşırı taahhüde
                # sokuyordu — 15984 MB RAM'de 15087 MB ayrılmış hâlde panel
                # "%122 aşım" gösterdi. Sayıyı ekleme sorusuna göre soruyoruz.
                free, bd = free_budget_mb()
                # Replika ana kopyanın TAVANINI da REZERVESİNİ de tekrarlar:
                # aynı imaj, aynı tuning.env, aynı buffer pool. Üç kuralı da
                # ayrı ayrı soruyoruz ki ret mesajı hangisinin çiğnendiğini
                # söyleyebilsin — "bellek yetmiyor" cümlesi, %6 dolu bir
                # sunucuda kullanıcıya hiçbir şey anlatmıyordu.
                rep_reserve = engine_reserved_mb(eid)
                msg = None
                if free < prim_mb:
                    msg = ("YUMUŞAK KURAL (tavan): replika ana kopya kadar "
                           "tavan ister (%d MB) çünkü devirden sonra aynı "
                           "yükü taşıyacak; tavan bütçesinde yalnız %d MB "
                           "boş var "
                           "(dağıtılabilir %d MB × aşırı taahhüt %.2f − açık "
                           "tavanlar %d MB). Açık motorların tavanlarını "
                           "'Yeniden dengele' ile güncel kullanıma çekin, bir "
                           "motoru durdurun ya da RAM ekleyin."
                           % (prim_mb, max(free, 0), bd["allocatable_mb"],
                              bd["overcommit_limit"], bd["committed_mb"]))
                elif rep_reserve > bd["reserve_free_mb"]:
                    msg = ("SERT KURAL (rezerve): replika açılışta %d MB'ı "
                           "gerçekten ayırır; açık motorların rezerve toplamı "
                           "%d MB ve dağıtılabilir bellek %d MB, yani "
                           "ayrılabilecek %d MB kaldı. Rezerve aşırı taahhüt "
                           "edilemez."
                           % (rep_reserve, bd["stack_reserved_mb"],
                              bd["allocatable_mb"],
                              max(bd["reserve_free_mb"], 0)))
                elif bd["kernel_free_mb"] > 0 and \
                        bd["kernel_free_mb"] < rep_reserve + KERNEL_SAFETY_MB:
                    msg = ("ÇEKİRDEK KEMERİ: replika açılışta %d MB ayıracak "
                           "(+%d MB emniyet payı) ama /proc/meminfo "
                           "MemAvailable şu an %d MB. Defter uygun görse bile "
                           "bu belleği ayırmak OOM killer'ı çağırır."
                           % (rep_reserve, KERNEL_SAFETY_MB,
                              bd["kernel_free_mb"]))
                if msg:
                    # Olay günlüğüne de düşüyor: "yedek kopya neden kurulmadı"
                    # sorusu çoğu zaman iş penceresi kapandıktan sonra
                    # soruluyor, iş günlüğü ise o zamana kadar budanmış olur.
                    record_event("replication_blocked", eid, msg,
                                 level="warning")
                    return job_done(jid, False, msg)
                job_log(jid, "bütçe uygun: replika %d MB tavan / %d MB "
                             "rezerve alacak; tavan boşluğu %d MB, rezerve "
                             "boşluğu "
                             "%d MB, çekirdek %d MB boş bildiriyor"
                        % (prim_mb, rep_reserve, free, bd["reserve_free_mb"],
                           bd["kernel_free_mb"]))
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
                         "%s için yedek kopya kuruldu (%s)" % (engine["name"], svc))
            return job_done(jid, True)

        # devre dışı bırak
        # ÖNCE motora özel temizlik: PostgreSQL'de boşta kalan replikasyon
        # slot'u WAL'ı sonsuza dek biriktirip diski doldurur ve primary'yi
        # durdurur. Replika container'ı silinmeden önce yapılmalı.
        script = script_path("replication", eid)
        if os.path.exists(script) and script_has_phase(script, "cleanup"):
            job_log(jid, "replikasyon kalıntıları temizleniyor…")
            rc, out, err = run(["sh", script, "cleanup"], timeout=300, env=rep_env)
            job_log(jid, (out + err).strip()[-2000:])
            detail = (err or out).strip()[-300:]
            # KAPI ARTIK ÖLÇÜME DAYANIYOR, ÇIKIŞ KODUNA DEĞİL. Betiğin çıkış
            # kodu bu soruyu cevaplayamıyordu: temizlik dallarındaki psql/mysql
            # çağrıları `|| true` ile maskeli olduğu ve dal `echo` ile kapandığı
            # için PostgreSQL'de kapı ASLA tetiklenmiyordu (yani korumanın asıl
            # gerekçesi ölü koddu), buna karşılık cleanup fazı hiç tanımlı
            # olmayan motorlarda betik alakasız bir dala düşüp hata döndürüyor
            # ve "Replikayı kapat" kalıcı olarak kırılıyordu. Kalıntının pahalı
            # olduğu tek yer PostgreSQL'in slot'u; onu da burada SAYIYORUZ.
            # ÜÇ DURUM, ÜÇ AYRI DAL. Burada `None` iki farklı şeye çözülüyordu
            # ve ikisi aynı dala düşüyordu: "bu motorda kalıntı olmaz" ile
            # "PostgreSQL'de SORAMADIK". İkincisi sessiz başarıya dönüşüyordu —
            # yedek kaldırılıyor, slot ana kopyada kalıyor, WAL sonsuza dek
            # birikip diski dolduruyordu. Üstelik senaryo istisnai değil: devir
            # sonrası temizlik betiği sabit `postgresql` adına vurduğu için
            # rc != 0 KURALDIR.
            if eid == "postgresql":
                leftover = _pg_slots_left(prim, rep_env)   # [] | [ad…] | None
            else:
                leftover = []          # bu motorlarda diski dolduran kalıntı yok

            if leftover is None:
                pstat, _ = _health_of(prim)
                msg = ("Replikasyon slot'unun silindiği DOĞRULANAMADI: ana kopyaya "
                       "(%s) sorulamadı. Yedek kopya KALDIRILMADI — geride kalan bir "
                       "slot, WAL kayıtlarını sonsuza dek biriktirip ana kopyanın "
                       "diskini doldurur ve onu durdurur. %s" % (prim, detail))
                if pstat == "running":
                    msg += (" Ana kopya çalışıyor; birkaç dakika sonra tekrar deneyin. "
                            "Sürerse sunucuda `docker exec -it %s psql -U %s -d postgres "
                            "-c \"SELECT slot_name FROM pg_replication_slots;\"` ile "
                            "bakın." % (prim, rep_env.get("POSTGRES_USER", "root")))
                    record_event("replication_blocked", eid, msg, level="critical")
                    return job_done(jid, False, msg)
                # Ana kopya kapalıysa slot WAL biriktiremez; engellemenin anlamı
                # yok, ama kullanıcı motoru açtığında bu işi tekrarlamalı.
                record_event("replication", eid,
                             "Ana kopya (%s) çalışmadığı için slot durumu "
                             "sorulamadı. Motoru açtıktan sonra 'Yedek Kopya Kur / "
                             "Kapat' işlemini bir kez daha çalıştırın. %s"
                             % (prim, detail), level="warning")
            elif leftover:
                pstat, _ = _health_of(prim)
                msg = ("Replikasyon kalıntısı temizlenemedi — ana kopyada (%s) hâlâ "
                       "replikasyon slot'u duruyor: %s. Yedek kopya KALDIRILMADI: "
                       "kalan slot, WAL kayıtlarını sonsuza dek biriktirip ana "
                       "kopyanın diskini doldurur ve onu durdurur. %s"
                       % (prim, ", ".join(leftover), detail))
                if pstat == "running":
                    msg += (" Birkaç dakika sonra tekrar deneyin; sürerse sunucuda "
                            "`docker exec -it %s psql -U %s -d postgres -c \"SELECT "
                            "pg_drop_replication_slot('%s');\"` komutuyla slot'u elle "
                            "silip bu düğmeye yeniden basın."
                            % (prim, rep_env.get("POSTGRES_USER", "root"), leftover[0]))
                    record_event("replication_blocked", eid, msg, level="critical")
                    return job_done(jid, False, msg)
                # Ana kopya çalışmıyorsa slot zaten WAL biriktiremez (motor
                # kapalı); yedeği kaldırmayı engellemenin anlamı yok, ama
                # kullanıcı motoru açtığında bu işi tekrarlamalı.
                record_event("replication", eid,
                             "Ana kopya (%s) çalışmadığı için replikasyon slot'u "
                             "silinemedi (%s). Motoru açtıktan sonra 'Yedek Kopya "
                             "Kur / Kapat' işlemini bir kez daha çalıştırın."
                             % (prim, detail), level="warning")
            elif rc != 0:
                # Temizlik hata verdi ama geride diski dolduracak bir kalıntı
                # YOK (Redis'te repl-backlog sabit boyutludur, MariaDB'de binlog
                # kendi süresiyle silinir, MongoDB'de karşılığı yoktur). Burada
                # durmak, kullanıcıyı bozuk bir replikayı kaldıramaz hâle
                # sokardı — oysa replikayı kaldırmak istemesinin sebebi zaten
                # çoğu zaman replikanın bozuk olmasıdır.
                job_log(jid, "temizlik betiği hata verdi (çıkış %d) ama bu motorda "
                             "geride kalıcı bir kalıntı bırakmıyor — kaldırmaya "
                             "devam ediliyor" % rc)
                record_event("replication", eid,
                             "%s temizlik adımı hata verdi (%s); yedek kopya yine de "
                             "kaldırıldı — bu motorda ana kopyayı etkileyecek bir "
                             "kalıntı kalmıyor." % (engine["name"], detail),
                             level="warning")
        elif os.path.exists(script):
            job_log(jid, "bu motorda temizlenecek replikasyon kalıntısı yok")

        with ACTION_LOCK:
            args = ["--profile", engine["profile"], "--profile", profile]
            job_log(jid, "yedek kopya kaldırılıyor:", svc)
            run(compose_base() + args + ["stop", svc], timeout=600)
            rc, out, errout = run(compose_base() + args + ["rm", "-f", svc], timeout=600)
        job_log(jid, (out + errout).strip()[-2000:])
        st = load_state()
        st["profiles"] = [x for x in st["profiles"] if x != profile]
        # OTOMATİK DEVİR DE KAPANIR. Yedek kopya yokken devredilecek bir düğüm
        # de yoktur; rozet ekranda kalırsa kullanıcı korunduğunu sanmaya devam
        # eder (giriş kapısındaki kontrol yalnız AÇARKEN çalışıyor, bu durumu
        # düzeltmiyordu).
        if eid in set(st.get("auto_failover", [])):
            st["auto_failover"] = [x for x in st.get("auto_failover", []) if x != eid]
            record_event("config", eid,
                         "Yedek kopya kaldırıldığı için otomatik devir de kapatıldı — "
                         "yükseltilecek bir düğüm kalmadı. Yeniden korunmak için "
                         "'Yedek Kopya Kur' deyip otomatik devri tekrar açın.",
                         level="warning")
        if override in st.get("overrides", []):
            st["overrides"] = [x for x in st["overrides"] if x != override]
            save_state(st)
            with ACTION_LOCK:  # primary'i override'sız haline geri al
                run(compose_base() + ["--profile", engine["profile"], "up", "-d",
                                      prim], timeout=900)
        save_state(st)
        record_event("replication", eid,
                     "%s yedek kopyası kaldırıldı (%s)" % (engine["name"], svc))
        job_done(jid, True)
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))
    finally:
        lock.release()


# =============================================================================
# YEDEKLEME
# =============================================================================
# Yedeği ALAN taraf scripts/backup.sh'tır; controller yalnız onu çağırır.
# Aynı işin ikinci bir uygulamasını buraya yazmak, iki uygulamanın er geç
# ayrışması demekti: gece cron'un ürettiği dosya ile panelin ürettiği dosya
# farklı yollardan geçseydi, hangisinin geri yüklenebildiği ancak felaket
# günü anlaşılırdı. Buradaki iş üçle sınırlı: ne zaman koşacağına karar
# vermek, aynı anda ikinci bir koşum başlatmamak, sonucu görünür kılmak.

BACKUP_SCRIPT = os.path.join(PROJECT_DIR, "scripts", "backup.sh")
BACKUP_CFG_FILE = os.path.join(STATE_DIR, "backup.json")
BACKUP_DEFAULTS = {"enabled": False, "time": "02:00", "retention_days": 7}
BACKUP_RETENTION_MIN = 1
BACKUP_RETENTION_MAX = 365
# Zamanlayıcı yarım dakikada bir uyanır: "time" alanı DAKİKA hassasiyetinde,
# yani hedef dakikanın penceresine en az bir kez düşmek zorundayız.
BACKUP_TICK = 30
# Tam bir dump saatler sürebilir; run()'ın 900 sn'lik varsayılanı yedeği
# ORTASINDAN keserdi. Yine de sınırsız değil: takılmış bir dump'ı sonsuza
# dek beklemek, o motorda bir daha hiç yedek alınmaması demektir.
BACKUP_TIMEOUT = int(os.environ.get("BACKUP_TIMEOUT", "14400"))

_HHMM = re.compile(r"^([01][0-9]|2[0-3]):([0-5][0-9])$")

# Yedekleme işleri controller içinde de TEK SIRADA yürür. Betiğin kendi
# flock'u ikinci koşumu zaten reddediyor, ama bunu ÖNCEDEN bilmek gerekiyor:
# aksi halde elle başlatılan iş betiğin "Başka bir işlem kilidi tutuyor"
# ölümüyle düşüyor ve panelde "yedekleme başarısız" görünüyordu — oysa yedek
# alınıyordu, sadece başka bir koşum tarafından. Bu kilit aynı zamanda "şu an
# yedek alınıyor mu" sorusunun tek cevabı (GET /api/backups → running).
BACKUP_LOCK = threading.Lock()
BACKUP_BUSY_MSG = ("Şu anda başka bir yedekleme sürüyor. İki dump aynı anda "
                   "koşarsa aynı container'ın belleğini iki kez zorlar; "
                   "bitmesini bekleyip tekrar deneyin.")

# BACKUP_LOCK yalnız BU süreçteki işleri sıraya sokar. Betiğin kendi flock'u
# (state/backup.lock) host'tan başlatılan koşumları da kapsıyor ve alamadığında
# common.sh'ın acquire_lock'ı şu satırı basıp 1 ile çıkıyor:
#   "[✗] Başka bir işlem kilidi tutuyor (/project/state/backup.lock). Çıkılıyor."
# Metni tahmin etmiyoruz, kaynağı scripts/lib/common.sh acquire_lock; renk
# kodları yok çünkü çıktı boruya yazılıyor (tty değil). Panelde bu çıkış
# "Son yedek: az önce · BAŞARISIZ — backup.sh çıkış 1" diye kırmızı
# görünüyordu; oysa o an başka bir yedek/geri yükleme koşuyordu ve kilit tam
# görevini yapmıştı. Yanlış alarm, gerçek alarmı değersizleştirir.
BACKUP_LOCK_TEXT = "Başka bir işlem kilidi tutuyor"
# Ertelenen ya da BAŞARISIZ olan tur, ARTAN ARALIKLA aynı gün içinde yeniden
# denenir: 10 dk → 30 dk → saatlik. Ölçülen olay: zamanlama açıldı, tek deneme
# kilide takıldı, panel "Sıradaki yedek: 24 saat sonra" yazdı ve o gün AÇIK
# olan PostgreSQL ile Redis'in HİÇ yedeği alınmadı. Oysa mekanizma sağlamdı —
# elle çalıştırılan `backup.sh all` üç motoru 3 saniyede yedekliyor. Tek şansa
# bırakmak, kilidi tutan iş bittikten sonra bile o günü harcamak demekti.
# Aralığın artması, kilidi dakikalarca tutan uzun bir geri yüklemede olay
# günlüğünü 30 saniyede bir doldurmamak için.
BACKUP_RETRY_AFTER = int(os.environ.get("BACKUP_RETRY_AFTER", "600"))
BACKUP_RETRY_STEPS = (BACKUP_RETRY_AFTER, 1800, 3600)
# Zamanlama İLK açıldığında — ya da controller açılırken zamanlama açık olduğu
# hâlde hiç başarılı tur yoksa — bu kadar sonra bir TABAN YEDEĞİ alınır.
# Sabah 11'de zamanlamayı açan kullanıcı gece 02:00'yi beklememeli: o 15 saat
# yedeksizdir. "Hemen" değil 180 sn: controller yeni başladıysa container'lar
# henüz healthcheck'ten geçmemiş olabilir ve dump boşuna düşer.
BACKUP_BASELINE_DELAY = int(os.environ.get("BACKUP_BASELINE_DELAY", "180"))


# Panelde gösterilecek dosya listesinin üst sınırı ve YEDEĞİN KAYNAĞI defteri.
#
# "Alınan yedeklerin hepsi bu sayfada olsun" isteği, listeyi tek tek dosya
# düzeyine indiriyor. İki şeye dikkat: (1) liste sınırsız olamaz — bir yıllık
# günlük yedek 365 satır demek ve panel bunu 30 saniyede bir yeniden çiziyor;
# (2) bir dosyaya bakıp "bunu elle mi aldım, gece mi alındı" demek mümkün
# değil, çünkü backup.sh dosya adına kaynağını yazmıyor ve yazdırmak dosya
# adı sözleşmesini değiştirmek olurdu (geri yükleme, temizlik ve e2e hepsi o
# ada bakıyor). Bu yüzden kaynağı AYRI bir defterde tutuyoruz: controller
# kendi başlattığı koşumdan sonra oluşan dosyaları etiketler. Defterde
# olmayan dosya "dış"tır — host cron'u ya da komut satırından alınmış
# demektir; bunu "zamanlı" saymak yalan olurdu.
BACKUP_LIST_MAX = 40
BACKUP_INDEX_FILE = os.path.join(STATE_DIR, "backup_index.json")


def load_backup_index():
    try:
        with open(BACKUP_INDEX_FILE, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}          # bozuk/boş defter, yedeklerin kendisini etkilemez


# ŞİFRELİ YEDEK DE YEDEKTİR. Şifreleme açıkken dosyalar '.gz.enc' uzantısıyla
# yazılıyor; yalnız '.gz' arayan her yer o kurulumu SESSİZCE görmez oldu:
# panelde "hiç yedek yok", geri yüklemede "dosya bulunamadı", provada
# "yedek yok". Yani şifrelemeyi açan — en çok güvence isteyen — kullanıcı
# en az güvence alıyordu. Uzantı sözleşmesi tek yerde tanımlı.
BACKUP_EXTS = (".gz", ".gz.enc")


def yedek_dosyasi_mi(ad):
    """Ad bir yedek dosyası mı? '.bozuk' kenara alınmış dosya SAYILMAZ:
    doğrulamayı geçemediği için kurtarma noktası değildir."""
    if ad.endswith(".bozuk"):
        return False
    return any(ad.endswith(x) for x in BACKUP_EXTS)


def tag_new_backups(kind, since, eids=None):
    """`since`dan sonra oluşan yedek dosyalarını `kind` ile işaretler.

    Dosya adını değil dosyanın KENDİSİNİ arıyoruz: backup.sh'ın ürettiği ad
    biçimi motora göre değişiyor ve buradan tahmin etmek kırılgan olurdu.
    Defter, artık var olmayan dosyalardan temizlenir — yoksa saklama süresi
    dosyaları sildikçe defter sonsuza kadar büyürdü.
    """
    root = backups_dir()
    idx = load_backup_index()
    hedef = eids if eids is not None else [e["id"] for e in CATALOG.engines]
    mevcut = set()
    for eid in hedef:
        d = os.path.join(root, eid)
        for dirpath, _dirs, files in os.walk(d):
            for name in files:
                if not yedek_dosyasi_mi(name):
                    continue
                try:
                    stt = os.stat(os.path.join(dirpath, name))
                except OSError:
                    continue
                mevcut.add(name)
                if stt.st_mtime >= since - 1:
                    idx[name] = kind
    # temizlik: yalnız TARANAN motorların artık var olmayan kayıtları atılır
    for name in list(idx):
        if name not in mevcut and any(
                name.startswith(eid) for eid in hedef):
            idx.pop(name, None)
    try:
        tmp = BACKUP_INDEX_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(idx, fh, ensure_ascii=False)
        os.replace(tmp, BACKUP_INDEX_FILE)
    except OSError as e:
        log("yedek defteri yazılamadı: %r" % e)


def backups_dir():
    """Yedeklerin durduğu dizin — backup.sh ile AYNI sırayla çözülür:
    ortam değişkeni, sonra .env, sonra <kök>/backups. (common.sh'ın load_env'i
    de ortamda tanımlı bir değişkene dokunmaz; öncelik birebir aynı.)

    İki taraf ayrışırsa panel "hiç yedek yok" derken diskte yedekler durur —
    üstelik do_backup'ın "yeni dosya oluştu mu" kontrolü sapasağlam bir yedeğe
    "bu koşum çıktı üretmedi" derdi.
    """
    d = os.environ.get("BACKUP_DIR") or _dotenv().get("BACKUP_DIR") or ""
    return d.strip() or os.path.join(PROJECT_DIR, "backups")


def _parse_hhmm(value):
    """'HH:MM' → (saat, dakika); geçersizse None."""
    m = _HHMM.match(str(value or "").strip())
    return (int(m.group(1)), int(m.group(2))) if m else None


def _same_local_day(a, b):
    """İki epoch aynı YEREL güne mi düşüyor?

    Gün sınırı UTC'ye göre sorulursa, saat 02:00'de koşan bir yedek UTC+3'te
    bir önceki günün hanesine yazılır ve zamanlayıcı aynı günü "koşulmadı"
    sayardı. Kullanıcının girdiği saat yerel; karşılaştırma da yerel.
    """
    la, lb = time.localtime(a), time.localtime(b)
    return (la.tm_year, la.tm_yday) == (lb.tm_year, lb.tm_yday)


def load_backup_cfg():
    """state/backup.json — yoksa varsayılan, BOZUKSA da varsayılan.

    Bozuk/boş dosyada çökmek en pahalı seçenekti: sunucu tam bu dosya
    yazılırken kapandığında geriye 0 baytlık bir backup.json kaldı; okuyan
    taraf çöktüğü için zamanlayıcı thread'i öldü ve gece yedeği kimseye haber
    vermeden durdu. Artık varsayılana dönüyoruz — ama sessizce değil: "ayarım
    neden 02:00'ye döndü" sorusunun cevabı bu log satırıdır.

    Alanlar TEK TEK doğrulanır: elle düzenlenmiş bir dosyada tek bozuk alan
    yüzünden bütün zamanlamayı çöpe atmak gerekmiyor.
    """
    cfg = dict(BACKUP_DEFAULTS)
    # last_deferred: son turun KOŞMADIĞI, kilit yüzünden ertelendiği an.
    # last_ok'tan ayrı bir alan, çünkü "yedek alınamadı" ile "sıra bekliyor"
    # aynı şey değil; ikisini tek alanda toplamak paneli yanlış alarma
    # sokuyordu.
    # last_success: son BAŞARILI turun anı. "Hiç başarılı yedek alındı mı"
    #   sorusunun tek cevabı; taban yedeği kararı buna bakıyor.
    # slot_done_at: BUGÜNÜN zamanlı saatini karşılayan tur. last_run'dan ayrı,
    #   çünkü sabah alınan taban yedeği o gecenin turunu iptal etmemeli.
    # attempts/next_attempt/attempt_note: artan aralıklı yeniden deneme.
    cfg.update({"last_run": None, "last_ok": None, "last_error": None,
                "last_deferred": None, "last_success": None,
                "slot_done_at": None, "attempts": 0,
                "next_attempt": None, "attempt_note": None})
    try:
        with open(BACKUP_CFG_FILE, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return cfg                       # ilk açılış — varsayılan
    except OSError as e:
        log("backup.json okunamadı (%s) — varsayılan zamanlama kullanılıyor"
            % e)
        return cfg
    try:
        if not raw.strip():
            raise ValueError("dosya boş")
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("içerik bir nesne değil")
    except ValueError as e:
        log("backup.json bozuk (%s) — varsayılan zamanlamaya dönüldü" % e)
        return cfg

    if isinstance(data.get("enabled"), bool):
        cfg["enabled"] = data["enabled"]
    hm = _parse_hhmm(data.get("time"))
    if hm:
        cfg["time"] = "%02d:%02d" % hm
    rd = data.get("retention_days")
    if isinstance(rd, int) and not isinstance(rd, bool) \
            and BACKUP_RETENTION_MIN <= rd <= BACKUP_RETENTION_MAX:
        cfg["retention_days"] = rd
    lr = data.get("last_run")
    if isinstance(lr, (int, float)) and not isinstance(lr, bool):
        cfg["last_run"] = int(lr)
    if isinstance(data.get("last_ok"), bool):
        cfg["last_ok"] = data["last_ok"]
    if isinstance(data.get("last_error"), str):
        cfg["last_error"] = data["last_error"]
    ld = data.get("last_deferred")
    if isinstance(ld, (int, float)) and not isinstance(ld, bool):
        cfg["last_deferred"] = int(ld)
    for alan in ("last_success", "slot_done_at", "next_attempt"):
        v = data.get(alan)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            cfg[alan] = int(v)
    at = data.get("attempts")
    if isinstance(at, int) and not isinstance(at, bool) and at >= 0:
        cfg["attempts"] = at
    if isinstance(data.get("attempt_note"), str):
        cfg["attempt_note"] = data["attempt_note"]

    # Yükseltme göçü: eski dosyada last_success/slot_done_at yok. Haftalardır
    # sorunsuz yedekleyen bir sunucuda bu iki alanı boş bırakmak, gereksiz bir
    # taban yedeği başlatır, o günün zamanlı turunu da ikinci kez
    # koşturabilirdi.
    if cfg["last_success"] is None and cfg["last_ok"] and cfg["last_run"]:
        cfg["last_success"] = cfg["last_run"]
    if cfg["slot_done_at"] is None and cfg["last_run"]:
        cfg["slot_done_at"] = cfg["last_run"]
    return cfg


def save_backup_cfg(cfg):
    """Yalnız sözleşmedeki alanları yazar — elle eklenmiş çöpü taşımayalım."""
    out = {
        "enabled": bool(cfg.get("enabled")),
        "time": cfg.get("time") or BACKUP_DEFAULTS["time"],
        "retention_days": int(cfg.get("retention_days")
                              or BACKUP_DEFAULTS["retention_days"]),
        "last_run": cfg.get("last_run"),
        "last_ok": cfg.get("last_ok"),
        "last_error": cfg.get("last_error"),
        "last_deferred": cfg.get("last_deferred"),
        "last_success": cfg.get("last_success"),
        "slot_done_at": cfg.get("slot_done_at"),
        "attempts": int(cfg.get("attempts") or 0),
        "next_attempt": cfg.get("next_attempt"),
        "attempt_note": cfg.get("attempt_note"),
    }
    _write_json(BACKUP_CFG_FILE, out)
    return out


def backup_pending_attempt(cfg, now=None):
    """Bekleyen DENEMENİN zamanı ve sebebi: (epoch|None, not|None).

    Neden türetiyoruz da yalnız kayda bakmıyoruz: next_attempt'i yazan tek
    yer _schedule_backup_retry. Kayıt bir sebeple eksik kalırsa (eski sürümden
    yükseltme, yarım yazılmış dosya, kilidi tutan koşum ölmüş) elde yalnız
    "son tur başarısız/ertelendi" bilgisi kalıyor ve panel bir sonraki an
    olarak ERTESİ GÜNÜN zamanlı saatini gösteriyordu — kullanıcının
    "otomatik yedek çalışmıyor" dediği durum tam olarak buydu. Sunucudaki
    gerçek kayıt da öyleydi: last_ok=False, next_attempt yok, panel
    "Sıradaki yedek: 24 saat sonra".

    Kural: son tur başarıyla bitmediyse ve o günden beri başarılı tur yoksa
    bekleyen bir deneme VARDIR. Kayıtta duruyorsa o, durmuyorsa son
    olaydan BACKUP_RETRY_AFTER sonrası.
    """
    now = time.time() if now is None else now
    if not cfg.get("enabled"):
        return None, None
    kayitli = cfg.get("next_attempt")
    if kayitli:
        return int(kayitli), cfg.get("attempt_note")
    # Kayıt yok: son turun sonucuna bakarak türet.
    son_olay = cfg.get("last_deferred") or 0
    basarisiz = cfg.get("last_ok") is False
    if basarisiz and (cfg.get("last_run") or 0) > son_olay:
        son_olay = cfg["last_run"]
    if not son_olay:
        return None, None
    basari = cfg.get("last_success") or 0
    if basari >= son_olay:
        return None, None          # sonrasında başarılı tur olmuş, borç yok
    hedef = son_olay + BACKUP_RETRY_AFTER
    if not _same_local_day(hedef, now):
        return None, cfg.get("attempt_note")
    not_ = cfg.get("attempt_note") or (
        "önceki tur %s; en geç %s içinde tekrar denenecek"
        % ("ertelendi" if cfg.get("last_deferred") else "başarısız oldu",
           _sure_metni(BACKUP_RETRY_AFTER)))
    return int(max(hedef, now)), not_


def backup_next_run(cfg=None, now=None):
    """Bir sonraki zamanlanmış yedeğin epoch'u; zamanlama kapalıysa None."""
    cfg = load_backup_cfg() if cfg is None else cfg
    if not cfg.get("enabled"):
        return None
    hm = _parse_hhmm(cfg.get("time"))
    if not hm:
        return None
    now = time.time() if now is None else now
    # İkiye değil ÜÇ güne bakıyoruz: yaz saatinin bittiği 25 saatlik günde
    # "now + 86400" hâlâ AYNI güne düşebiliyor; hedef saat o gün geçmişse
    # elde tek aday kalmıyor ve panel "sonraki koşum: —" gösteriyordu.
    for gun in (0, 1, 2):
        lt = time.localtime(now + gun * 86400)
        try:
            t = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday,
                             hm[0], hm[1], 0, 0, 0, -1))
        except (OverflowError, ValueError):
            return None
        if t > now:
            return int(t)
    return None


def backup_stats(eid, root=None):
    """backups/<motor>/ altındaki yedekler: (adet, toplam bayt, en yeni).

    `root` verilebilir: dashboard bu bilgiyi saniyeler arayla istiyor ve
    dizini her motor için yeniden çözmek .env'i motor sayısı kadar okumak
    demekti.

    Dizin yoksa (0, 0, None) — os.walk boş bir ağaçta hata vermez.

    Yalnız *.gz sayılır. Doğrulamayı geçemeyip `.bozuk` uzantısıyla kenara
    alınmış dosyalar KURTARMA NOKTASI DEĞİLDİR; onları saymak panelde "3
    yedeğiniz var" yazdırıp elde hiç yedek olmaması demek olurdu. backup.sh'ın
    list/stats komutları da aynı süzgeci kullanıyor — iki taraf aynı şeyi
    sayıyor.
    """
    root = os.path.join(root or backups_dir(), eid)
    idx = load_backup_index()
    count = total = 0
    latest = None
    latest_at = -1.0
    liste = []          # `files` DEĞİL: os.walk'ın döngü değişkeni o adı
                        # kullanıyor ve her dizinde üzerine yazıyordu
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not yedek_dosyasi_mi(name):
                continue
            try:
                stt = os.stat(os.path.join(dirpath, name))
            except OSError:
                continue          # tam o anda temizlik silmiş olabilir
            count += 1
            total += stt.st_size
            liste.append({"file": name, "epoch": int(stt.st_mtime),
                          "bytes": stt.st_size, "kind": idx.get(name, "dış")})
            if stt.st_mtime > latest_at:
                latest_at = stt.st_mtime
                latest = liste[-1]
    # En yeni üstte. Liste PANELDE gösteriliyor: "hepsi burada olsun" isteği
    # bunu gerektiriyor, ama sınırsız da olamaz — bir yıllık günlük yedek 365
    # satır demek ve JSON her 30 saniyede bir yeniden çiziliyor. Üst sınır
    # dışında kalanların VARLIĞI count'ta duruyor, panel de "listede son N"
    # yazıyor; sayı ile liste birbirini yalanlamıyor.
    liste.sort(key=lambda x: x["epoch"], reverse=True)
    return count, total, latest, liste[:BACKUP_LIST_MAX]


# =============================================================================
# KURTARMA PROVASI
# =============================================================================
# verify_backup dosyanın bozulmadığını söyler; "geri yüklenebilir" DEMEZ.
# Prova, yedeği tek kullanımlık bir container'da GERÇEKTEN geri yükler ve
# süreyi ölçer — yani RTO'yu vaat etmek yerine ÖLÇERİZ. Sonucu burada
# saklıyoruz ki panel "bu yedek 2 gün önce gerçekten geri yüklendi, 42 saniye
# sürdü" diyebilsin. Bir yedekleme sisteminin verebileceği en değerli cümle bu.
DRILL_SCRIPT = os.path.join(PROJECT_DIR, "scripts", "restore-drill.sh")
DRILL_FILE = os.path.join(STATE_DIR, "drill.json")
DRILL_TIMEOUT = int(os.environ.get("DRILL_TIMEOUT", "3600"))
# Haftalık: prova ucuz değil (ikinci bir veritabanı açıp veri yüklüyor) ama
# ayda bir de yetmez — iki prova arasında bozulan bir yedek zinciri fark
# edilmeden birikir. Gecelik yedekten SONRA koşar, çünkü provanın anlamı en
# taze kurtarma noktasını sınamaktır.
DRILL_EVERY_DAYS = int(os.environ.get("DRILL_EVERY_DAYS", "7"))


def load_drills():
    try:
        with open(DRILL_FILE, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_drill(eid, sonuc):
    d = load_drills()
    d[eid] = sonuc
    try:
        tmp = DRILL_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(d, fh, ensure_ascii=False)
        os.replace(tmp, DRILL_FILE)
    except OSError as e:
        log("prova defteri yazılamadı: %r" % e)


def drill_supported(eid):
    """backup.sh'ta geri yükleme yolu VAR MI. Listeyi elle yazmıyoruz:
    katalog büyüdüğünde sessizce eksik kalmasın diye betiğin kendi
    gerçeğinden okuyoruz."""
    try:
        with open(BACKUP_SCRIPT, encoding="utf-8") as fh:
            return ("restore_%s()" % eid) in fh.read()
    except OSError:
        return False


def do_drill(jid, eid):
    """Kurtarma provası — üretime DOKUNMAZ, tek kullanımlık kopyada çalışır."""
    engine = CATALOG.engine(eid)
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    if not drill_supported(eid):
        return job_done(jid, False,
                        "%s için geri yükleme yolu yok; prova yapılamaz."
                        % engine["name"])
    if not shutil.which("bash"):
        return job_done(jid, False, "Bu container'da bash yok.")
    # Prova üretim container'ına dokunmuyor ama AYNI yedek dosyasını okuyor ve
    # diski/CPU'yu kullanıyor: yedekleme kilidini alıyoruz. Alamıyorsak bu bir
    # arıza değil sıradır — "ertelendi" diyoruz (bkz. do_backup).
    if not BACKUP_LOCK.acquire(blocking=False):
        return job_done(jid, False, BACKUP_BUSY_MSG, {"deferred": True})
    try:
        basladi = time.time()
        job_log(jid, "%s kurtarma provası başlıyor…" % engine["name"])
        rc, out, err = run(["bash", DRILL_SCRIPT, eid], cwd=PROJECT_DIR,
                           timeout=DRILL_TIMEOUT, env=script_env())
        metin = (out + err).strip()
        for satir in metin.splitlines()[-120:]:
            job_log(jid, satir)
        # Son satır TEK SATIR JSON — sözleşme betiğin kendisinde de yazılı.
        sonuc = None
        for satir in reversed(metin.splitlines()):
            satir = satir.strip()
            if satir.startswith("{") and satir.endswith("}"):
                try:
                    sonuc = json.loads(satir)
                except ValueError:
                    sonuc = None
                break
        if sonuc is None:
            # Çıktıyı okuyamadıysak "prova başarısız" DEMİYORUZ: ölçemedik.
            # İkisini karıştırmak, sağlam bir yedeği bozuk göstermek olurdu.
            kayit = {"at": int(basladi), "ok": None, "seconds": None,
                     "detail": "prova çıktısı okunamadı (çıkış %d)" % rc,
                     "file": None}
            save_drill(eid, kayit)
            return job_done(jid, False, kayit["detail"])
        kayit = {"at": int(basladi), "ok": bool(sonuc.get("ok")),
                 "seconds": sonuc.get("seconds"),
                 "detail": sonuc.get("detail") or "",
                 "file": os.path.basename(sonuc.get("file") or "") or None,
                 "match": sonuc.get("match")}
        save_drill(eid, kayit)
        if kayit["ok"]:
            record_event("drill", eid,
                         "%s kurtarma provası GEÇTİ — yedek gerçekten geri "
                         "yüklendi (%s sn)." % (engine["name"], kayit["seconds"]))
            return job_done(jid, True)
        # Prova düşmesi CRITICAL: elde geri yüklenemeyen bir yedek var ve bunu
        # felaket gününden ÖNCE öğrenmek bu özelliğin tek varlık sebebi.
        record_event("drill_failed", eid,
                     "%s kurtarma provası BAŞARISIZ: %s"
                     % (engine["name"], kayit["detail"]), level="critical")
        return job_done(jid, False, kayit["detail"])
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        return job_done(jid, False, repr(e))
    finally:
        BACKUP_LOCK.release()


# =============================================================================
# REPLİKASYON SAĞLIĞI — "çalışıyor" ile "akıyor" ayrı şeyler
# =============================================================================
# Panel "yedek kopya çalışıyor" derken yalnız REPLİKA CONTAINER'ININ AYAKTA
# olduğuna bakıyordu. Container ayakta ama replikasyon kopmuşsa panel yine
# "çalışıyor" diyordu — yani ölçmediği bir sağlığı iddia ediyordu. Bu, bu
# projede defalarca yakalanan hata sınıfının aynısı (healthcheck hesabı,
# .Id şablonu): sessizce yanlış olan bir güvence.
#
# Ölçüm için var olan mantığı kullanıyoruz: scripts/failover/<motor>.sh
# 'ready' eylemi, "yedek kopya yükseltmeye hazır mı" sorusuna cevap veriyor
# ve bu ancak replikasyon gerçekten UYGULANIYORSA doğru olur. Yeni bir SQL
# yazmıyoruz — devirle aynı ölçütü kullanmak, panelin gösterdiği şeyle
# devrin dayandığı şeyin AYNI olmasını garanti eder.
REPL_FILE = os.path.join(STATE_DIR, "replication.json")
REPL_EVERY_SEC = int(os.environ.get("REPL_CHECK_EVERY_SEC", "60"))


def load_replication_health():
    return _oku_json_dosya(REPL_FILE)


def _standby_service(engine, prim):
    """Şu anki ana kopya DEĞİL olan düğüm. Devirden sonra roller yer
    değiştirdiği için katalogdaki 'replica_service' her zaman yedek değildir."""
    rep = engine.get("replication", {})
    rs = rep.get("replica_service")
    if not rs:
        return None
    return engine["primary_service"] if prim == rs else rs


def measure_replication_health():
    out = {}
    calisan = {c["service"] for c in docker_containers() if c["status"] == "running"}
    for e in CATALOG.engines:
        eid = e["id"]
        rep = e.get("replication", {})
        if rep.get("mode") != "primary-replica":
            continue
        betik = os.path.join(PROJECT_DIR, "scripts", "failover", eid + ".sh")
        if not os.path.exists(betik) or not shutil.which("bash"):
            continue
        # REPLİKASYON AÇIKKEN YEDEK KOPYA YOKSA, SÖYLENECEK ÇOK ŞEY VAR.
        # Eski hâli burada `continue` diyordu ("yedek kopya yok: söylenecek bir
        # şey de yok"). Sonucu ölçüldü: e2e turundan sonra profiller açık
        # kalmış ama yedek container'lar silinmişti ve panel
        # replication_flowing=null gördüğü için "yedek kopya çalışıyor"
        # yazıyordu — ortada tek bir yedek düğüm yokken. Kullanıcı korunduğunu
        # sanıyor; otomatik devir de yükseltecek düğüm bulamayacak.
        acik = rep.get("profile") in load_state().get("profiles", [])
        if not acik:
            continue          # replikasyon zaten kurulu değil, iddia da yok
        prim = current_primary(e)
        stby = _standby_service(e, prim)
        if not stby:
            # Topoloji tutarsız: hangi düğümün yedek olduğunu söyleyemiyoruz.
            # Bu "iyi" değil, "bilmiyorum" — üçüncü değer olarak yazılıyor.
            out[eid] = {"at": int(time.time()), "standby": None, "flowing": None,
                        "detail": "topoloji kaydından yedek düğüm belirlenemedi "
                                  "(ana kopya: %s) — state/topology.json'a bakın"
                                  % prim}
            continue
        if stby not in calisan:
            out[eid] = {"at": int(time.time()), "standby": stby, "flowing": False,
                        "detail": "yedek kopya (%s) ÇALIŞMIYOR — replikasyon "
                                  "açık görünüyor ama yükseltilecek düğüm yok. "
                                  "Kurmak için: ./stack.sh replica on %s"
                                  % (stby, eid)}
            continue
        rc, o, er = run(["bash", betik, "ready", stby], cwd=PROJECT_DIR,
                        timeout=60, env=script_env())
        out[eid] = {"at": int(time.time()), "standby": stby,
                    "flowing": rc == 0,
                    "detail": (o + er).strip().splitlines()[-1][:200]
                              if (o + er).strip() else ""}
    _yaz_json_dosya(REPL_FILE, out)
    return out


def replication_refresher():
    while True:
        try:
            measure_replication_health()
        except Exception as e:
            log("replikasyon sağlığı ölçülemedi: %r" % e)
        time.sleep(REPL_EVERY_SEC)


# =============================================================================
# PITR DURUMU ve DEVİR PROVASI
# =============================================================================
# İkisi de "ölçülmüş güvence" ailesinden: biri "ne kadar geriye dönebilirim",
# öteki "devir gerçekten kaç saniye sürüyor". Panelin bunları göstermesi,
# vaat ile ölçüm arasındaki farkın tek görünür yeri.
PITR_SCRIPT = os.path.join(PROJECT_DIR, "scripts", "pitr.sh")
HADRILL_SCRIPT = os.path.join(PROJECT_DIR, "scripts", "failover-drill.sh")
PITR_FILE = os.path.join(STATE_DIR, "pitr.json")
HADRILL_FILE = os.path.join(STATE_DIR, "ha-drill.json")
PITR_EVERY_MIN = int(os.environ.get("PITR_STATUS_EVERY_MIN", "30"))


def _son_satir_json(metin):
    for satir in reversed((metin or "").splitlines()):
        satir = satir.strip()
        if satir.startswith("{") and satir.endswith("}"):
            try:
                return json.loads(satir)
            except ValueError:
                return None
    return None


def _oku_json_dosya(yol):
    try:
        with open(yol, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _yaz_json_dosya(yol, d):
    try:
        tmp = yol + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(d, fh, ensure_ascii=False)
        os.replace(tmp, yol)
    except OSError as e:
        log("%s yazılamadı: %r" % (os.path.basename(yol), e))


def load_pitr():
    return _oku_json_dosya(PITR_FILE)


def measure_pitr():
    """PITR penceresini ölçer: ne kadar geriye dönülebilir. Hiçbir şey değiştirmez."""
    if not shutil.which("bash") or not os.path.exists(PITR_SCRIPT):
        return None
    rc, out, err = run(["bash", PITR_SCRIPT, "durum", "--json"], cwd=PROJECT_DIR,
                       timeout=300, env=script_env())
    d = _son_satir_json(out + err)
    kayit = {"at": int(time.time()), "ok": bool(d) and bool(d.get("ok")),
             "rapor": d,
             "detail": (d or {}).get("detail")
                       or ("pitr.sh çıkış %d, JSON okunamadı" % rc)}
    _yaz_json_dosya(PITR_FILE, kayit)
    return kayit


def pitr_refresher():
    """PITR penceresi seyrek ölçülür: arşiv dosya sistemine bakmak ucuz değil
    ve pencere dakikalar mertebesinde değişir."""
    while True:
        try:
            son = (load_pitr().get("at") or 0)
            if time.time() - son >= PITR_EVERY_MIN * 60:
                measure_pitr()
        except Exception as e:
            log("PITR ölçümü hatası: %r" % e)
        time.sleep(300)


def do_ha_drill(jid, eid):
    """DEVİR PROVASI — bu YIKICI bir iştir: gerçek bir devir yapar.

    Onay HTTP ucunda alınıyor (gövdede açık bayrak); burada ayrıca --onayla
    veriyoruz çünkü betiğin kendi onayı terminal içindir. Kilit sırası
    aktivasyon/devirle AYNI: prova sırasında motorun kapatılması ya da ikinci
    bir devirin başlaması, elde tek çalışan kopya bırakmayabilirdi.
    """
    engine = CATALOG.engine(eid)
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    if not shutil.which("bash"):
        return job_done(jid, False, "Bu container'da bash yok.")
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return job_done(jid, False, BUSY_MSG % engine["name"])
    try:
        job_log(jid, "%s devir provası başlıyor — GERÇEK bir devir yapılacak."
                % engine["name"])
        record_event("ha_drill_started", eid,
                     "%s devir provası başlatıldı (gerçek devir)." % engine["name"],
                     level="warning")
        rc, out, err = run(["bash", HADRILL_SCRIPT, eid, "--onayla"],
                           cwd=PROJECT_DIR, timeout=1800, env=script_env())
        metin = (out + err).strip()
        for satir in metin.splitlines()[-150:]:
            job_log(jid, satir)
        d = _son_satir_json(metin)
        kayit = {"at": int(time.time()), "engine": eid,
                 "ok": bool(d) and bool(d.get("ok")),
                 "downtime_seconds": (d or {}).get("downtime_seconds"),
                 "data_loss": (d or {}).get("data_loss"),
                 "new_primary": (d or {}).get("new_primary"),
                 "detail": (d or {}).get("detail") or
                           ("failover-drill.sh çıkış %d" % rc)}
        hepsi = _oku_json_dosya(HADRILL_FILE); hepsi[eid] = kayit
        _yaz_json_dosya(HADRILL_FILE, hepsi)
        if kayit["ok"]:
            record_event("ha_drill", eid,
                         "%s devir provası GEÇTİ — ölçülen kesinti %s sn, veri kaybı: %s"
                         % (engine["name"], kayit["downtime_seconds"],
                            "yok" if kayit["data_loss"] is False else kayit["data_loss"]))
            return job_done(jid, True)
        record_event("ha_drill_failed", eid,
                     "%s devir provası BAŞARISIZ: %s" % (engine["name"], kayit["detail"]),
                     level="critical")
        return job_done(jid, False, kayit["detail"])
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        return job_done(jid, False, repr(e))
    finally:
        lock.release()


# =============================================================================
# BAKIM (tablo şişkinliği)
# =============================================================================
# Şişkinlik YAVAŞ değişen bir büyüklüktür: sil-yaz döngüsüyle günler içinde
# birikir. Her /api/status çağrısında ölçmek, panelin 5 saniyelik yenilemesini
# her motorda bir sistem katalogu sorgusuna çevirirdi. Bu yüzden arka planda
# seyrek ölçüp önbelleğe yazıyoruz — panel hazır sayıyı okuyor.
MAINT_SCRIPT = os.path.join(PROJECT_DIR, "scripts", "maintenance.sh")
MAINT_FILE = os.path.join(STATE_DIR, "maintenance.json")
MAINT_EVERY_HOURS = int(os.environ.get("MAINT_EVERY_HOURS", "6"))
MAINT_TIMEOUT = int(os.environ.get("MAINT_TIMEOUT", "900"))


def load_maintenance():
    try:
        with open(MAINT_FILE, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _save_maintenance(d):
    try:
        tmp = MAINT_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(d, fh, ensure_ascii=False)
        os.replace(tmp, MAINT_FILE)
    except OSError as e:
        log("bakım defteri yazılamadı: %r" % e)


def _maint_json(metin):
    """Betiğin son satırındaki TEK SATIR JSON — sözleşme betikte de yazılı."""
    for satir in reversed((metin or "").splitlines()):
        satir = satir.strip()
        if satir.startswith("{") and satir.endswith("}"):
            try:
                return json.loads(satir)
            except ValueError:
                return None
    return None


def measure_bloat():
    """Tüm motorlarda şişkinliği ölçer ve önbelleğe yazar. HİÇBİR ŞEY değiştirmez."""
    if not shutil.which("bash") or not os.path.exists(MAINT_SCRIPT):
        return None
    rc, out, err = run(["bash", MAINT_SCRIPT, "durum"], cwd=PROJECT_DIR,
                       timeout=MAINT_TIMEOUT, env=script_env())
    d = _maint_json(out + err)
    kayit = {"at": int(time.time()),
             # ok=None: ölçemedik. "şişkinlik yok" ile "bakamadık" AYRI şeyler;
             # ikisini birleştirmek, ölçüm bozulduğunda paneli sessizce
             # "her şey yolunda" gösterirdi.
             "ok": bool(d.get("ok")) if d else None,
             "total_bloat_bytes": (d or {}).get("total_bloat_bytes"),
             "tables": (d or {}).get("tables") or [],
             "detail": (d or {}).get("detail") or
                       ("bakım betiği çıkış %d, JSON okunamadı" % rc)}
    _save_maintenance(kayit)
    return kayit


def do_maintenance(jid, eid, agresif=False):
    """Bakım işi. Varsayılan GÜVENLİ: tabloyu kilitlemez."""
    engine = CATALOG.engine(eid)
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    if not shutil.which("bash"):
        return job_done(jid, False, "Bu container'da bash yok.")
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return job_done(jid, False, BUSY_MSG % engine["name"])
    try:
        args = [MAINT_SCRIPT, "bakim", eid]
        if agresif:
            # --onayla'yı BURADA veriyoruz çünkü onay zaten panelde alındı;
            # betiğin kendi onayı terminal içindir. Agresif bakım tabloyu
            # KİLİTLER ve bunu kullanıcı panelde okuyup kabul etti.
            args += ["--agresif", "--onayla"]
        job_log(jid, "%s bakımı başlıyor%s…"
                % (engine["name"], " (agresif — tablo kilitlenecek)" if agresif else ""))
        rc, out, err = run(["bash"] + args, cwd=PROJECT_DIR,
                           timeout=MAINT_TIMEOUT, env=script_env())
        metin = (out + err).strip()
        for satir in metin.splitlines()[-120:]:
            job_log(jid, satir)
        d = _maint_json(metin)
        if d and d.get("ok"):
            record_event("maintenance", eid,
                         "%s bakımı tamamlandı: %s"
                         % (engine["name"], d.get("detail") or ""))
            measure_bloat()          # panel taze sayıyı görsün
            return job_done(jid, True)
        return job_done(jid, False,
                        (d or {}).get("detail")
                        or "bakım başarısız (çıkış %d): %s" % (rc, metin[-300:]))
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        return job_done(jid, False, repr(e))
    finally:
        lock.release()


def maintenance_refresher():
    """Şişkinliği seyrek ölç, önbelleğe yaz. prometheus_target_refresher deseni."""
    while True:
        try:
            kayit = load_maintenance()
            son = kayit.get("at") or 0
            if time.time() - son >= MAINT_EVERY_HOURS * 3600:
                measure_bloat()
        except Exception as e:
            log("bakım ölçümü hatası: %r" % e)
        time.sleep(600)


def backups_overview():
    """GET /api/backups gövdesi: zamanlama + motor başına yedek özeti."""
    cfg = load_backup_cfg()
    root = backups_dir()
    drills = load_drills()
    engines = {}
    for e in CATALOG.engines:
        bk = e.get("backup") or {}
        count, total, latest, files = backup_stats(e["id"], root)
        prova = drills.get(e["id"])
        engines[e["id"]] = {"supported": bool(bk.get("supported")),
                            "drill_supported": drill_supported(e["id"]),
                            "drill": prova,
                            "count": count, "total_bytes": total,
                            "latest": latest, "files": files,
                            "listed": len(files)}
    return {
        "schedule": {
            "enabled": bool(cfg["enabled"]),
            "time": cfg["time"],
            "retention_days": int(cfg["retention_days"]),
            "last_run": cfg["last_run"],
            "last_ok": cfg["last_ok"],
            "last_error": cfg["last_error"],
            # Panel bunu "BAŞARISIZ" değil "ertelendi" diye gösterir: tur
            # koşmadı, kilit sırayı korudu ve zamanlayıcı yeniden deneyecek.
            "last_deferred": cfg["last_deferred"],
            "last_success": cfg["last_success"],
            "attempts": int(cfg["attempts"] or 0),
            "next_run": backup_next_run(cfg),
            # Bir sonraki DENEME. Bekleyen bir deneme (taban yedeği ya da
            # ertelenen/başarısız turun tekrarı) varsa O gösterilir; yoksa
            # zamanlı turun kendisi. "24 saat sonra" ancak gerçekten başarılı
            # bir turdan sonra doğrudur — ölçülen olayda tek deneme kilide
            # takılmıştı ve panel yine de 24 saat sonrasını gösteriyordu.
            "next_attempt": (backup_pending_attempt(cfg)[0]
                             or backup_next_run(cfg)),
            "attempt_note": (cfg["attempt_note"]
                             or backup_pending_attempt(cfg)[1]),
            "running": BACKUP_LOCK.locked(),
        },
        "engines": engines,
    }


def _backup_run(args, jl, extra_env=None):
    """backup.sh'ı çalıştırır: (rc, hata_metni, ertelendi).

    `ertelendi`, betiğin İŞ YAPMADAN dosya kilidine takıldığı durumdur
    (BACKUP_LOCK_TEXT). Bunu ayrı döndürmek zorundayız: çıkış kodu 1, yani
    "yedek alınamadı" ile aynı; oysa ortada arıza yok, sıra var. Çağıran
    taraf bunu kırmızı bir başarısızlık olarak göstermemeli.

    `extra_env` betiğe ek ortam verir (geri yüklemede ASSUME_YES=yes).
    script_env()'in ÜZERİNE yazılır, yerine geçmez — parolalar oradan gelir;
    yerine geçseydi geri yükleme boş parolayla "Access denied" alırdı.

    `bash` ŞART: betik dizi, PIPESTATUS ve `<<<` kullanıyor; busybox sh ile
    çalıştırılırsa hata bile vermeden YANLIŞ davranır — ve bu ürünün yedekleme
    tarafının tamamı, sessizce yanlış davranan bir yedeklemenin ne kadar
    pahalı olduğu üzerine yazılmış. Yoksa çalıştırmıyoruz; ne yapılması
    gerektiğini söyleyip duruyoruz.
    """
    if not shutil.which("bash"):
        return 1, ("Bu container'da `bash` yok. scripts/backup.sh saf bash "
                   "betiğidir ve busybox sh ile çalıştırılamaz; controller "
                   "imajına bash eklenmeli (controller/Dockerfile)."), False
    env = script_env()
    if extra_env:
        env.update(extra_env)
    rc, out, err = run(["bash", BACKUP_SCRIPT] + list(args), cwd=PROJECT_DIR,
                       timeout=BACKUP_TIMEOUT, env=env)
    text = (out + err).strip()
    for line in text.splitlines()[-120:]:
        jl(line)
    if rc == RC_TIMEOUT:
        return rc, ("Yedekleme %d saniyede bitmedi ve kesildi; yarım kalmış "
                    "bir dosya kalmış olabilir (backup.sh doğrulamayı "
                    "geçemeyeni .bozuk diye kenara alır)." % BACKUP_TIMEOUT), \
            False
    if rc != 0 and BACKUP_LOCK_TEXT in text:
        return rc, ("Başka bir yedekleme ya da geri yükleme sürüyor "
                    "(state/backup.lock). Bu koşum veriye HİÇ dokunmadan "
                    "ertelendi; kilit, iki ağır işin aynı container'da "
                    "çakışmasını önlüyor."), True
    if rc != 0:
        return rc, ("backup.sh çıkış %d: %s"
                    % (rc, text[-500:] or "(çıktı yok)")), False
    return 0, None, False


def do_backup(jid, eid):
    """Tek motoru yedekler — aktivasyonla AYNI iş (job) mekanizması."""
    engine = CATALOG.engine(eid)
    # HTTP ucu motor kimliğini zaten katalogla doğruluyor; buradaki kontrol,
    # doğrudan çağrılan bir iş thread'inin sessizce "devam ediyor" kalmasını
    # önler.
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    bk = engine.get("backup") or {}
    if not bk.get("supported"):
        # Katalog "neden yedeklenmiyor"u zaten yazıyor (Kafka bir log'dur;
        # izleme verisi kaybolursa yeniden toplanır). Kullanıcıya kendi
        # cümlemizi değil onu veriyoruz — tek yetki kaynağı katalog.
        return job_done(jid, False, "%s yedeklenmiyor: %s" % (
            engine["name"],
            bk.get("note") or "bu motorda yedekleme desteklenmiyor."))

    # Yedekleme de aç/durdur ve devirle AYNI SIRADA yürür. Kilitsiz kalırsa
    # dump, tam o anda fence edilen ya da hacmi silinen bir düğümden alınır;
    # elde "başarılı" damgalı ama yarım bir kurtarma noktası kalırdı.
    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return job_done(jid, False, BUSY_MSG % engine["name"])
    try:
        # Kapalı motorun container'ı yoktur; `docker exec` hedefi bulamaz.
        # Betik de aynı kontrolü yapıyor ama oradan gelen cevap bir kabuk
        # hatası gibi okunuyor — panelden basılan düğmeye panelin diliyle
        # cevap vermek gerekiyor. Ana kopya devirden sonra başka bir
        # container olabilir; o yüzden topolojiden soruyoruz.
        prim = current_primary(engine)
        pstat, _phealth = _health_of(prim)
        if pstat != "running":
            return job_done(jid, False,
                            "%s kapalı (%s) — yedeklenecek çalışan bir kopya "
                            "yok. Önce motoru aktif edin."
                            % (engine["name"], pstat))
        if not BACKUP_LOCK.acquire(blocking=False):
            return job_done(jid, False, BACKUP_BUSY_MSG)
        try:
            before_count, _bt, before_latest, _bf = backup_stats(eid)
            before_at = before_latest["epoch"] if before_latest else 0
            basladi = time.time()
            job_log(jid, "%s yedekleniyor…" % engine["name"])
            rc, err, ertelendi = _backup_run([eid],
                                             lambda *m: job_log(jid, *m))
            if ertelendi:
                # Kilit devredeydi: koşum başlamadı bile. "Başarısız" demek
                # yanlış alarm olurdu (bkz. BACKUP_LOCK_TEXT); "başarılı" da
                # diyemeyiz, ortada yeni bir kurtarma noktası yok. İş
                # ayrı bir bayrakla kapanıyor, panel bunu ayrı gösterir.
                record_event("backup_deferred", eid,
                             "%s yedeklenmedi, ertelendi: sunucuda başka bir "
                             "yedekleme ya da geri yükleme sürüyor. Bittiğinde "
                             "tekrar deneyin." % engine["name"])
                return job_done(jid, False, err, {"deferred": True})
            tag_new_backups("elle", basladi, [eid])
            count, _t, latest, _f = backup_stats(eid)
            yeni = (count > before_count
                    or (latest is not None and latest["epoch"] > before_at))
            if rc == 0 and not yeni:
                # Betik 0 ile bitip DOSYA ÜRETMEMİŞ olabilir: Neo4j
                # Community'de çevrimdışı yedek açıkça istenmediyse backup.sh
                # uyarıp 0 ile geçiyor. Buna "yedeklendi" demek, olmayan bir
                # kurtarma noktasına güvenmek olurdu.
                rc = 1
                err = ("Betik hatasız bitti ama backups/%s altında yeni bir "
                       "dosya oluşmadı — bu koşumdan kurtarma noktası "
                       "ÇIKMADI. Sebebi iş günlüğünün son satırlarında." % eid)
            if rc == 0:
                mb = (latest["bytes"] / 1048576.0) if latest else 0.0
                record_event("backup", eid, "%s yedeklendi: %s (%.1f MB)"
                             % (engine["name"],
                                latest["file"] if latest else "?", mb))
                return job_done(jid, True)
            record_event("backup_failed", eid,
                         "%s yedeklenemedi: %s" % (engine["name"], err),
                         level="warning")
            return job_done(jid, False, err)
        finally:
            BACKUP_LOCK.release()
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))
    finally:
        lock.release()


def backup_script_can_restore(eid):
    """backup.sh'ta bu motor için gerçekten bir restore_<motor>() var mı?

    Katalogda backup.supported olan her motorun geri yüklemesi YAZILMIŞ
    değil: Cassandra/Elasticsearch/MinIO gibi motorların snapshot'ları elle
    geri alınıyor ve betiğin `restore-*` dalı bu durumda 1 ile ölüyor. Çıkış
    kodu bu ayrımı taşımıyor — 1, "veritabanı yarım kaldı" ile aynı kod. O
    yüzden fonksiyonu dosyada arıyoruz (script_has_phase ile aynı gerekçe):
    yoksa hiç çağırmıyor, kullanıcıya yıkıcı olmayan bir cevap veriyoruz.

    Betik okunamıyorsa True: burada karar vermek uydurmak olurdu, cevabı
    çalıştırma denemesi versin.
    """
    try:
        with open(BACKUP_SCRIPT, encoding="utf-8") as f:
            return ("restore_%s()" % eid) in f.read()
    except OSError as e:
        log("backup.sh okunamadı:", e)
        return True


BACKUP_NO_RESTORE_MSG = (
    "%s için otomatik geri yükleme yok: scripts/backup.sh'ta restore_%s "
    "yordamı tanımlı değil (bu motorun anlık görüntüsü elle geri alınır). "
    "Adımlar için docs/BACKUP.md.")


def resolve_backup_file(eid, name):
    """Uçtan gelen dosya adını backups/<motor>/ altında çözer: (yol, hata).

    Buradaki kontrollerin hepsi, geri yüklemenin VERİ SİLDİĞİ için var:
    backup.sh'a hangi yolu verirsek onu `gzip -dc … | docker exec …` ile
    veritabanının üstüne yazıyor. Yani bu fonksiyon, panelden gelen bir
    dizgenin dosya sisteminde nereye bakabileceğini belirleyen kapıdır.

    • Ad YALNIZ dosya adıdır: basename'i kendisine eşit değilse (a/../b),
      "." ya da ".." ise reddedilir.
    • Yol realpath ile çözülür ve backups/<motor>/ altında kaldığı DOĞRULANIR.
      Dizgi karşılaştırması tek başına yetmez: dizinin içine konmuş bir
      sembolik link, adında hiç "/" olmadan dışarıyı gösterebilir.
    • Yalnız .gz kabul edilir. Doğrulamayı geçemeyip ".bozuk" diye kenara
      alınmış dosya kurtarma noktası DEĞİLDİR; onunla geri yüklemeye başlamak
      veriyi geri getirmez, sadece yok eder (backup.sh verify_backup'ın
      varlık sebebi de bu).
    """
    ad = name.strip() if isinstance(name, str) else ""
    if not ad:
        return None, "Geri yüklenecek dosyanın adı ('file') gerekli."
    if ad in (".", "..") or ad != os.path.basename(ad) or "\\" in ad \
            or "\x00" in ad:
        return None, ("Dosya adı yalnız dosya adı olabilir; dizin ayracı ya "
                      "da '..' içeremez.")
    # backups_dir() .env'den GÖRELİ bir yol da dönebilir; betik /project'ten
    # çalıştığı için (do_backup'taki cwd) göreli yol oraya göre çözülür.
    # Controller'ın kendi dizini (/app) referans alınsaydı iki taraf farklı
    # dizine bakardı ve "dosya yok" derken dosya diskte dururdu.
    kok = os.path.realpath(os.path.join(PROJECT_DIR, backups_dir(), eid))
    # Yedekler DÜZ DURMUYOR: backup.sh türe göre alt dizin açıyor
    # (backups/mariadb/full/…, .../single/…). Liste ucu os.walk ile ağacı
    # gezip DOSYA ADINI veriyor; burada düz birleştirme yapınca panelin
    # gösterdiği her dosya "bulunamadı" oluyordu — ekranda duran bir dosyaya
    # "yok" demek, geri yüklemeyi kullanılamaz hâle getiriyordu.
    # Ağacı gezip adı eşleşen dosyayı buluyoruz; kök kontrolü aşağıda
    # ayrıca yapılıyor, yani alt dizin serbestliği kökten çıkmayı serbest
    # bırakmıyor.
    yol = os.path.realpath(os.path.join(kok, ad))
    if not os.path.isfile(yol):
        for dizin, _alt, dosyalar in os.walk(kok):
            if ad in dosyalar:
                yol = os.path.realpath(os.path.join(dizin, ad))
                break
    if not yol.startswith(kok + os.sep):
        return None, ("Dosya %s dizininin dışına çıkıyor; geri yükleme yalnız "
                      "o motorun kendi yedekleriyle yapılır." % kok)
    if not yedek_dosyasi_mi(ad):
        return None, ("Yalnız .gz ya da .gz.enc uzantılı yedekler geri yüklenir. "
                      "Doğrulamayı geçemediği için '.bozuk' diye kenara "
                      "alınmış bir dosya kurtarma noktası değildir.")
    if not os.path.isfile(yol):
        return None, "Yedek dosyası bulunamadı: %s" % ad
    return yol, None


def do_restore(jid, eid, filename):
    """Bir yedek dosyasından geri yükler — do_backup ile aynı iş mekanizması.

    Ayrım şu: bu yol MEVCUT VERİYİ SİLİYOR. backup.sh önce veritabanını
    düşürüp dosyadan yeniden kuruyor; yarıda kalırsa elde ne eskisi ne
    yenisi kalır. Bu yüzden kapılar dar: ad doğrulanır, motorun açık olması
    aranır ve HEM engine_lock HEM BACKUP_LOCK alınır. İkincisi olmasaydı
    geri yükleme sürerken 02:00 turu yarı yüklenmiş veritabanını "geçerli
    yedek" diye dosyalayıp uzağa senkronlardı — backup.sh'ın kendi flock'u
    da tam bu yüzden restore dalında alınıyor.
    """
    engine = CATALOG.engine(eid)
    # HTTP ucu bunları zaten doğruluyor; buradaki kontroller, doğrudan
    # çağrılan bir iş thread'inin sessizce "devam ediyor" kalmasını önler.
    if not engine:
        return job_done(jid, False, "Bilinmeyen motor: %s" % eid)
    bk = engine.get("backup") or {}
    if not bk.get("supported"):
        # Yedeklenmeyen motorun geri yükleyeceği bir dosyası da yoktur.
        # Sebebi katalog yazıyor; kendi cümlemizi değil onu veriyoruz.
        return job_done(jid, False, "%s yedeklenmiyor: %s" % (
            engine["name"],
            bk.get("note") or "bu motorda yedekleme desteklenmiyor."))
    if not backup_script_can_restore(eid):
        return job_done(jid, False,
                        BACKUP_NO_RESTORE_MSG % (engine["name"], eid))
    # Ad, uçta doğrulandıktan sonra burada TEKRAR çözülüyor: aradaki
    # saniyelerde saklama temizliği dosyayı silmiş olabilir ve o dosyayı
    # betiğe vermek "Dosya yok" ile ölen bir geri yükleme demek.
    yol, hata = resolve_backup_file(eid, filename)
    if hata:
        return job_done(jid, False, hata)

    lock = engine_lock(eid)
    if not lock.acquire(blocking=False):
        return job_done(jid, False, BUSY_MSG % engine["name"])
    try:
        # Geri yükleme çalışan bir container'ın İÇİNE yazar; kapalı motorda
        # `docker exec` hedefi yoktur. Ana kopya devirden sonra başka bir
        # container olabilir, o yüzden topolojiden soruyoruz.
        prim = current_primary(engine)
        pstat, _phealth = _health_of(prim)
        if pstat != "running":
            return job_done(jid, False,
                            "%s kapalı (%s) — geri yükleme çalışan bir "
                            "veritabanına yapılır. Önce motoru aktif edin."
                            % (engine["name"], pstat))
        if not BACKUP_LOCK.acquire(blocking=False):
            return job_done(jid, False, BACKUP_BUSY_MSG)
        try:
            ad = os.path.basename(yol)
            # Olay ÖNCEDEN yazılıyor. İş yarıda kalırsa (container OOM,
            # controller yeniden başlarsa) günlükte "şu dosyadan geri yükleme
            # başlatıldı" satırı yine de durur; sonradan yazsaydık tam da
            # açıklanması gereken durumda hiçbir kayıt olmazdı.
            record_event("restore_started", eid,
                         "%s için geri yükleme başlatıldı: %s — mevcut "
                         "veriler ÜZERİNE YAZILIYOR."
                         % (engine["name"], ad), level="warning")
            job_log(jid, "%s geri yükleniyor: %s" % (engine["name"], ad))
            # ASSUME_YES: betik terminalden "evet" bekler (confirm_restore);
            # burada okunacak bir terminal yok ve onayı kullanıcı panelde
            # verdi. Bu değişkeni yalnız bu çağrıya veriyoruz — script_env'e
            # kalıcı koymak, onay isteyen HER yolu sessizce onaylardı.
            rc, err, ertelendi = _backup_run(
                ["restore-%s" % eid, yol], lambda *m: job_log(jid, *m),
                {"ASSUME_YES": "yes"})
            if ertelendi:
                # Kilide takıldı: betik veriye dokunmadan çıktı. Kullanıcıya
                # "geri yükleme başarısız" demek burada özellikle yanlış
                # olurdu — veritabanının bozulduğunu düşündürür.
                record_event("restore_deferred", eid,
                             "%s geri yüklenmedi, ertelendi: başka bir "
                             "yedekleme ya da geri yükleme sürüyor. Veriye "
                             "dokunulmadı." % engine["name"])
                return job_done(jid, False, err, {"deferred": True})
            if rc == 0:
                record_event("restore", eid,
                             "%s %s dosyasından geri yüklendi; önceki veriler "
                             "bu dosyanın içeriğiyle değiştirildi."
                             % (engine["name"], ad), level="warning")
                return job_done(jid, True)
            # Başarısız geri yükleme, başarısız yedekten daha ağırdır: yedek
            # düşerse elde eski kurtarma noktası kalır, burada veritabanının
            # kendisi yarım kalmış olabilir. "critical" seviyesi bildirimi de
            # tetikler; bu, sabahı beklemeyecek bir haberdir.
            record_event("restore_failed", eid,
                         "%s geri yüklenemedi: %s — veritabanı YARIM kalmış "
                         "olabilir, durumunu hemen kontrol edin."
                         % (engine["name"], err), level="critical")
            return job_done(jid, False, err)
        finally:
            BACKUP_LOCK.release()
    except Exception as e:
        job_log(jid, "HATA:", repr(e))
        job_done(jid, False, repr(e))
    finally:
        lock.release()


def _slot_epoch(cfg, now):
    """Bugünün zamanlı yedek saatinin epoch'u; saat geçersizse None."""
    hm = _parse_hhmm(cfg.get("time"))
    if not hm:
        return None
    lt = time.localtime(now)
    try:
        return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday,
                            hm[0], hm[1], 0, 0, 0, -1))
    except (OverflowError, ValueError):
        return None


def _sure_metni(sn):
    """Saniyeyi panelde ve olay günlüğünde okunur Türkçeye çevirir."""
    sn = int(sn)
    if sn < 90:
        return "%d saniye" % sn
    if sn < 3600:
        return "%d dakika" % int(round(sn / 60.0))
    return "%d saat" % int(round(sn / 3600.0))


def _schedule_backup_retry(cfg, neden, now=None):
    """Bir sonraki DENEMEYİ planlar (artan aralık) ve diske yazar.

    Panelin "Sıradaki yedek: 24 saat sonra" cümlesi tam olarak burada
    doğuyordu: tur koşmayınca akla gelen tek "sonraki an" ertesi günün
    zamanlı saatiydi. Deneme ile zamanlı tur ayrı şeyler; artık ayrı
    alanlarda duruyorlar (next_attempt / next_run).
    """
    now = time.time() if now is None else now
    sira = int(cfg.get("attempts") or 0) + 1
    gecikme = BACKUP_RETRY_STEPS[min(sira, len(BACKUP_RETRY_STEPS)) - 1]
    cfg = dict(cfg)
    cfg["attempts"] = sira
    hedef = now + gecikme
    if _same_local_day(hedef, now):
        cfg["next_attempt"] = int(hedef)
        cfg["attempt_note"] = "%s, %s sonra tekrar" % (neden,
                                                       _sure_metni(gecikme))
    else:
        # Gün bitti. Yarına sarkan bir "gece yedeği" kullanıcının sandığı şey
        # değildir; ertesi günün zamanlı turu zaten gelecek.
        cfg["next_attempt"] = None
        cfg["attempt_note"] = ("%s; gün bittiği için bir sonraki zamanlı tura "
                               "bırakıldı" % neden)
    save_backup_cfg(cfg)
    return cfg


def _ensure_baseline_backup(neden):
    """Zamanlama açık ama HİÇ başarılı tur yoksa kısa süre içinde bir TABAN
    YEDEĞİ planlar. Planladıysa yeni yapılandırmayı, planlamadıysa None döner.

    Ölçülen olay: kullanıcı sabah zamanlamayı açtı, tek deneme kilide takıldı
    ve panel "Sıradaki yedek: 24 saat sonra" yazdı — o gün AÇIK olan
    PostgreSQL ve Redis'in hiç yedeği alınmadı. Kullanıcının zamanlamayı
    açarken beklediği şey "yarın gece" değil "artık yedekleniyorum"dur; aradaki
    saatler yedeksiz geçiyordu.
    """
    cfg = load_backup_cfg()
    if not cfg.get("enabled") or cfg.get("last_success"):
        return None
    if cfg.get("next_attempt"):
        return None                      # zaten planlı, üstüne yazma
    cfg = dict(cfg)
    cfg["next_attempt"] = int(time.time()) + BACKUP_BASELINE_DELAY
    cfg["attempt_note"] = ("ilk taban yedeği %s içinde alınacak (%s)"
                           % (_sure_metni(BACKUP_BASELINE_DELAY), neden))
    save_backup_cfg(cfg)
    record_event("backup", "tümü",
                 "Zamanlama açık ve henüz başarılı bir tur yok — taban yedeği "
                 "%s içinde alınacak (%s). Gece saatini beklemek, o ana kadar "
                 "yedeksiz kalmak demekti."
                 % (_sure_metni(BACKUP_BASELINE_DELAY), neden))
    return cfg


def _mark_backup_deferred(cfg, neden):
    """Zamanlanmış turu 'ertelendi' diye işaretler ve TEKRARINI planlar.

    last_ok'a DOKUNMAZ: erteleme bir sonuç değil, sıraya girme. Panelde
    "BAŞARISIZ" yazan kırmızı satır tam olarak bu ayrımın olmamasından
    doğuyordu — kilit görevini yapmışken kullanıcı yedeğinin bozulduğunu
    sanıyordu.
    """
    cfg = dict(cfg)
    cfg["last_deferred"] = int(time.time())
    cfg = _schedule_backup_retry(cfg, "kilit meşguldü")
    record_event("backup_deferred", "tümü",
                 "Zamanlanmış yedekleme ertelendi: %s. Tur koşmuş sayılmıyor; "
                 "%s." % (neden, cfg["attempt_note"] or "yeniden denenecek"))
    return cfg


# Tur adları olay günlüğünde ve panelde olduğu gibi görünüyor.
BACKUP_TUR_ADI = {"zamanlı": "Zamanlanmış yedekleme", "taban": "Taban yedeği"}


def _run_scheduled_backup(cfg, tur="zamanlı"):
    """Zamanlayıcının turu: önce tüm AKTİF motorlar, sonra saklama temizliği.

    (backup.sh `all` kapalı motoru zaten atlar — kapalı motorun container'ı
    yoktur, dump alınacak bir yer de yoktur.)

    last_run işin BAŞINDA yazılır. Sonda yazsaydık: tam yedek saatler
    sürebiliyor ve controller o sırada yeniden başlarsa (imaj güncellemeleri
    tam da gece bakım penceresinde yapılıyor) aynı gün İKİNCİ bir tur
    başlardı — iki paralel dump, aynı container'ın cgroup'unda çift bellek
    baskısı, yani backup.sh'ın başında anlatılan OOM demek.

    slot_done_at ise "BUGÜNÜN zamanlı saati karşılandı" demektir ve yalnız o
    saat GEÇMİŞSE yazılır. Fark önemli: sabah 11'de alınan taban yedeği,
    saati 23:00 olan turu iptal etmemeli — asıl gece yedeği odur.

    Tek istisna ERTELEME: betik kilide takılıp iş yapmadan çıkarsa tur hiç
    koşmamıştır ve iki alan da geri alınır. Aksi halde "aynı gün bir kez"
    kuralı o günü harcar; kilidi tutan uzun iş bittiğinde bile o gece yedek
    alınmaz — kaydı tutulan tek şey yanlış bir "BAŞARISIZ" satırı olurdu.
    """
    simdi = time.time()
    slot = _slot_epoch(cfg, simdi)
    kapsiyor = (slot is None) or (simdi >= slot)
    onceki_run = cfg.get("last_run")
    onceki_slot = cfg.get("slot_done_at")
    ad = BACKUP_TUR_ADI.get(tur, "Yedekleme")

    cfg = dict(cfg)
    cfg.update({"last_run": int(simdi), "last_ok": None, "last_error": None,
                "last_deferred": None, "next_attempt": None,
                "attempt_note": "%s şu anda koşuyor" % ad})
    if kapsiyor:
        cfg["slot_done_at"] = int(simdi)
    save_backup_cfg(cfg)
    log("%s başlıyor (saklama: %d gün)" % (ad, cfg["retention_days"]))

    basladi = time.time()
    rc, err, ertelendi = _backup_run(["all"], log)
    if ertelendi:
        # Ne dosya oluştu ne de temizlik anlamlı: tur başlamadı. Saklama
        # temizliğini de atlıyoruz, çünkü kilidi tutan iş bir geri yükleme
        # olabilir ve o sırada dosya silmek işi zorlaştırmaktan başka bir işe
        # yaramaz — tur yeniden denendiğinde temizlik de onunla gelecek.
        cfg["last_run"] = onceki_run
        cfg["slot_done_at"] = onceki_slot
        cfg["last_ok"] = None
        cfg["last_error"] = None
        _mark_backup_deferred(cfg, "başka bir yedekleme ya da geri yükleme "
                                   "state/backup.lock kilidini tutuyordu")
        return
    # Bu turda oluşan dosyaları "zamanlı" diye işaretle. Panelde elle alınanla
    # zamanlayıcının turu ayrı görünsün diye: "dün gece yedek alındı mı"
    # sorusunun cevabı, elle alınmış bir yedeğin varlığıyla karışmamalı.
    # (Taban yedeği de zamanlayıcının turudur, aynı etiketi taşır.)
    tag_new_backups("zamanlı", basladi)
    cfg["last_ok"] = (rc == 0)
    cfg["last_error"] = err
    if rc == 0:
        # BAŞARILI TUR ESKİ KAYDI TEMİZLER. Eskiden last_error diskte kalıyor,
        # panel günler önce düzelmiş bir arızayı kırmızı göstermeye devam
        # ediyordu; gerçek bir arıza çıktığında ona kimse bakmıyordu.
        cfg.update({"last_success": int(time.time()), "last_error": None,
                    "last_deferred": None, "attempts": 0,
                    "next_attempt": None, "attempt_note": None})
        record_event("backup", "tümü", "%s tamamlandı." % ad)
    else:
        # Seviye "critical": bu tur kimsenin başında olmadığı saatte koşuyor.
        # Elle basılan düğmenin sonucunu kullanıcı ekranda görür, buranınkini
        # yalnız bildirim gösterir — "gece yedeği alınamadı", öğrenilmesinde
        # en geç kalınmaması gereken şeydir.
        record_event("backup_failed", "tümü",
                     "%s başarısız: %s" % (ad, err), level="critical")
        # Başarısızlık da tekrar denenir: o günün yedeği tek bir denemeye
        # bağlı kalmamalı. Kalıcı bir arızada aralık büyüyerek gün sonunda
        # kendiliğinden susar.
        cfg = _schedule_backup_retry(cfg, "yedekleme başarısız oldu")

    # Temizlik, yedekleme düşse bile çalışır: yedeğin düşme sebebi çoğu zaman
    # diskin dolmasıdır ve tam o durumda temizliği atlamak işi kötüleştirir.
    rc2, err2, ertelendi2 = _backup_run(["clean", str(cfg["retention_days"])],
                                        log)
    # `ertelendi2` de sessizce geçilir: temizlik kilide takıldıysa hiçbir
    # dosya silinmemiştir ve bu bir arıza değil, sıradır. Bugün clean_old
    # kilit almıyor — bu dal, betiğin kilit alanına taşınması hâlinde yanlış
    # alarm üretmemek için duruyor.
    if rc2 != 0 and not ertelendi2:
        # last_ok'a YANSITMIYORUZ: elde geçerli kurtarma noktaları var, yalnız
        # eskiler birikiyor. Bunu "gece yedeği alınamadı" diye göstermek
        # alarmı yanlış yere çalardı; uyarı olarak olay günlüğüne düşüyor.
        record_event("backup_clean_failed", "tümü",
                     "Eski yedekler temizlenemedi: %s — yedek dizini büyümeye "
                     "devam eder." % err2, level="warning")
    save_backup_cfg(cfg)
    _haftalik_prova()


def _haftalik_prova():
    """Gecelik turdan sonra, süresi gelmiş motorlar için KURTARMA PROVASI.

    Neden yedeğin hemen ardından: provanın anlamı EN TAZE kurtarma noktasını
    sınamaktır. Bir hafta önceki yedeğin geri yüklendiğini bilmek, dün gece
    bozulmuş bir zincir hakkında hiçbir şey söylemez.

    Neden hepsi değil de "süresi gelen": prova ikinci bir veritabanı açıp veri
    yüklüyor; her gece her motor için koşmak, gecelik pencereyi doldurur ve
    yedeklemenin önüne geçer. Haftalık aralık, "hiç prova yok" ile "her gece
    prova" arasındaki dürüst orta yol — ve aralık DRILL_EVERY_DAYS ile
    değiştirilebilir.

    Kilit: do_drill BACKUP_LOCK'u kendisi alıyor; buraya kadar geldiğimizde
    yedek turu bitmiş oluyor.
    """
    if DRILL_EVERY_DAYS <= 0:
        return
    simdi = time.time()
    kayitlar = load_drills()
    for e in CATALOG.engines:
        eid = e["id"]
        if not drill_supported(eid):
            continue
        # Yedeği olmayan motorun provası yapılamaz — bu bir arıza değil.
        _c, _t, latest, _f = backup_stats(eid)
        if not latest:
            continue
        son = (kayitlar.get(eid) or {}).get("at") or 0
        if simdi - son < DRILL_EVERY_DAYS * 86400:
            continue
        jid = new_job("drill", eid)
        log("haftalık kurtarma provası: %s (iş %s)" % (eid, jid))
        do_drill(jid, eid)      # sırayla: iki prova aynı anda koşmasın


def backup_scheduler():
    """Zamanlanmış yedekleme — prometheus_target_refresher ile aynı desen.

    Neden ayrı bir cron değil: zamanlamayı panelden değiştirmek, container
    içindeki crontab'ı yeniden yazmak demekti — üstelik o dosya READ-ONLY
    mount'un altında. Ayarı okuyanla koşturanın aynı süreç olması,
    "kaydettim ama gece yine eski saatte koştu" sınıfından hataları baştan
    imkânsız kılıyor.

    İki ayrı tetik var ve bu ayrım bu üründeki en pahalı sessizliği kapatıyor:
      (a) ZAMANLI TUR — hedef dakika geldi ve bugünün turu henüz koşmadı.
      (b) PLANLI DENEME — taban yedeği ya da ertelenen/başarısız turun artan
          aralıklı tekrarı. Zamanlı saatten BAĞIMSIZ; eskiden tek deneme
          kilide takılınca o gün hiç yedek alınmıyordu.

    Her tur try/except ile sarılı. Thread ölürse hiçbir yerde hata görünmez,
    yalnız yedekler durur.
    """
    log("yedek zamanlayıcısı başladı (her %d sn kontrol)" % BACKUP_TICK)
    # Açılışta: zamanlama açık ama hiç başarılı tur yoksa taban yedeği planla.
    # "Zamanlamayı açtım, akşama kadar hiç yedeğim olmadı" ölçülmüş bir
    # olaydır ve controller yeniden başladığında da geçerlidir.
    try:
        _ensure_baseline_backup("controller açılışı")
    except Exception as e:
        log("taban yedeği planlanamadı:", repr(e))
    while True:
        time.sleep(BACKUP_TICK)
        try:
            cfg = load_backup_cfg()
            if not cfg.get("enabled"):
                continue
            hm = _parse_hhmm(cfg.get("time"))
            if not hm:
                continue
            now = time.time()
            lt = time.localtime(now)
            # (a) Hedef dakika 30 sn'lik turlarla en az iki kez yakalanıyor.
            #     Bugünün turu koştuysa (slot_done_at) ikinci kez koşmaz.
            zamani = ((lt.tm_hour, lt.tm_min) == hm
                      and not (cfg.get("slot_done_at")
                               and _same_local_day(cfg["slot_done_at"], now)))
            # (b) Bekleyen denemenin vakti geldi mi?
            # Bekleyen deneme KAYITTAN DEĞİL, türetilmiş kaynaktan okunuyor:
            # kayıt eksikse bile borçlu bir tur varsa denenmeli (bkz.
            # backup_pending_attempt). Aksi hâlde eksik kayıt, zamanlayıcıyı
            # sessizce ertesi güne bırakıyordu.
            bekleyen = backup_pending_attempt(cfg, now)[0] or 0
            deneme = bool(bekleyen and now >= bekleyen)
            if not (zamani or deneme):
                continue
            # Hiç başarılı tur yokken koşan deneme TABAN yedeğidir; kullanıcı
            # panelde bunu gecenin turuyla karıştırmasın diye ayrı adlanıyor.
            tur = "taban" if (deneme and not cfg.get("last_success")) \
                else "zamanlı"
            if not BACKUP_LOCK.acquire(blocking=False):
                # Controller'ın kendi içinde bir yedek/geri yükleme sürüyor.
                # Eskiden yalnız log satırıydı: tur sessizce düşüyor, hedef
                # dakika geçiyor ve o günün yedeği alınmıyordu. Artık bu da
                # ERTELEME — panel görüyor, zamanlayıcı yeniden deniyor.
                cfg = _mark_backup_deferred(
                    cfg, "controller içinde başka bir yedekleme ya da geri "
                         "yükleme sürüyordu")
                continue
            try:
                _run_scheduled_backup(cfg, tur)
            except Exception as e:
                # Tur yarıda kaldı. Yeniden denemeyi PLANLAMADAN geçmek, o
                # günü harcamak olurdu. (_run_scheduled_backup bekleyen
                # denemeyi işin başında sildiği için burada sonsuz döngü yok.)
                log("yedekleme turu hatayla durdu:", repr(e))
                record_event("backup_failed", "tümü",
                             "Yedekleme turu beklenmeyen bir hatayla durdu: "
                             "%r" % e, level="critical")
                _schedule_backup_retry(load_backup_cfg(),
                                       "tur beklenmeyen hatayla durdu")
            finally:
                BACKUP_LOCK.release()
        except Exception as e:
            log("yedek zamanlayıcısı hatası:", repr(e))


# =============================================================================
# DURUM
# =============================================================================
def status():
    containers = {c["service"]: c for c in docker_containers()}
    st = load_state()
    tun = load_tuning()
    total, available = host_memory_mb()
    # used_by_stack TAVANLARIN toplamıdır, kullanılan bellek DEĞİL. Adı
    # (stack_committed_mb) bunu söylüyor ama panel onu "AYRILAN BELLEK" diye
    # gösterip RAM ile kıyaslıyordu; yanına dağıtılabiliri, rezerve toplamını
    # ve çekirdeğin baskı ölçümünü koyuyoruz ki tek başına okunmasın.
    used_by_stack = sum(c["memory_mb"] for c in containers.values() if c["status"] == "running")
    allocatable = allocatable_mb(total)
    reserved_total = stack_reserved_mb()

    topo = load_topology()
    auto_fo = auto_failover_engines()
    repl_health = load_replication_health()

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
        # "Kapalı" ile "container'ı var ama çalışmıyor" AYNI ŞEY DEĞİL.
        # Sürekli yeniden başlayan (restarting) bir motor CPU yakar, ama
        # active=False olduğu için panelde kapalılar listesinde görünüyordu:
        # ekranda "kapalı", `docker ps`te canlı. Operatör orada olduğunu bile
        # bilmediği için kapatmıyor da. Artık ayrı bildiriyoruz.
        present = bool(primary)
        # active=False iken AYAKTA kalan servisler (yönetim ekranı, exporter,
        # yükseltilmiş replika...). Kapatma bunları temizler; panelin bunu
        # gösterebilmesi için listeyi buradan veriyoruz.
        stray = []
        if not active:
            for x in svcs:
                if x["status"] not in ("absent", "exited", "dead", "created"):
                    stray.append({"service": x["service"], "status": x["status"]})
            if rep_svc and rep_svc["status"] not in ("absent", "exited", "dead", "created"):
                if rep_svc["service"] not in [y["service"] for y in stray]:
                    stray.append({"service": rep_svc["service"], "status": rep_svc["status"]})
        engines.append({
            "id": e["id"],
            "active": active,
            "present": present,
            "primary_status": primary["status"] if primary else "absent",
            "stray": stray,
            "ready": bool(active and primary["health"] in ("healthy", "none")),
            "health": primary["health"] if primary else "none",
            "services": svcs,
            "memory_mb": primary["memory_mb"] if primary else 0,
            # Kapalı motorun rezervesi 0'dır: ayırdığı bellek yok. Açıkken
            # tuning kaydından türer — motor o değerlerle açıldı.
            "reserved_mb": (engine_reserved_mb(e["id"],
                                               tuning=tun.get(e["id"]))
                            if active else 0),
            "tuning": tun.get(e["id"], {}),
            "replication_active": bool(rep_svc and rep_svc["status"] == "running"),
            # AYRI ALAN: "container ayakta" ile "replikasyon akıyor" aynı şey
            # değil. None = ölçülmedi (yedek kopya yok ya da ölçüm yapılamadı);
            # False = container ayakta AMA akış kopuk — panelin en çok
            # göstermesi gereken durum bu.
            "replication_flowing": (repl_health.get(e["id"]) or {}).get("flowing"),
            "replication_detail": (repl_health.get(e["id"]) or {}).get("detail"),
            "primary_service": prim_name,
            # "failed_over" dashboard'da "Devir yapıldı — eski kopya durduruldu"
            # uyarısını ve "Eski kopyayı yeniden kur" düğmesini açar. Yalnız
            # topolojiye bakınca bu ikisi BAŞARILI bir yeniden kurulumdan sonra
            # da ekranda kalıyordu: uyarı artık yanlıştı (eski kopya çalışıyor ve
            # yedek durumda), düğmeye tekrar basmak ise çalışan yedeğin hacmini
            # yeniden silip 15+ dakika yedeksiz kalmak demekti. Roller yer
            # değiştirmiş olabilir (roles_swapped) ama iş bitmiştir.
            "failed_over": (prim_name != e["primary_service"]
                            and not topo.get(e["id"], {}).get("rebuilt_at")),
            "roles_swapped": prim_name != e["primary_service"],
            "standby_rebuilt_at": topo.get(e["id"], {}).get("rebuilt_at", 0),
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
            # Açık motorların AÇILIŞTA gerçekten ayırdığı bellek. Ölçümde
            # tavan toplamı 15 GB iken bu sayı bunun çok altındadır; ikisini
            # yan yana göstermek "%122 aşım" yanılgısını kapatıyor.
            "stack_reserved_mb": reserved_total,
            "allocatable_mb": allocatable,
            "overcommit_ratio": (round(used_by_stack / float(allocatable), 2)
                                 if allocatable > 0 else 0.0),
            "overcommit_limit": OVERCOMMIT_LIMIT,
            # Çekirdeğin kendi ölçümü. Defter ne derse desin bağlayıcı olan
            # budur: baskı "yok" iken "bellek yetmiyor" demek ölçülebilir
            # biçimde yanlıştır.
            "pressure": host_pressure(),
            "cpus": host_cpus(),
            "disk_free_mb": disk_free_mb(),
            "os_reserve_mb": os_reserve_mb(total),
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
        if path == "/metrics":
            # Token İSTEMEZ, /healthz ile aynı gerekçeyle: controller portu
            # host'a açılmaz, buraya yalnız Docker ağının içinden ulaşılır.
            # Prometheus'a token dağıtmak, sırrı bir de scrape yapılandırmasına
            # yazmak demekti.
            try:
                body = render_metrics().encode("utf-8")
            except Exception as e:
                log("metrik üretilemedi:", repr(e))
                body = ("# metrik üretilemedi: %s\n" % e).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if not self._authed():
            return self._send(401, {"error": "yetkisiz"})
        if path == "/api/catalog":
            return self._send(200, catalog_for_client())
        if path == "/api/status":
            return self._send(200, status())
        if path == "/api/plans":
            return self._send(200, plan_all())
        if path == "/api/events":
            return self._send(200, {"events": read_events(200)})
        if path == "/api/topology":
            return self._send(200, {"topology": load_topology(),
                                    "auto_failover": sorted(auto_failover_engines())})
        if path == "/api/pitr":
            return self._send(200, load_pitr())
        if path == "/api/ha-drill":
            return self._send(200, _oku_json_dosya(HADRILL_FILE))
        if path == "/api/maintenance":
            return self._send(200, load_maintenance())
        if path == "/api/backups":
            return self._send(200, backups_overview())
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

        # --- yedekleme zamanlaması ------------------------------------
        # Gövde BURADA doğrulanır, zamanlayıcıda değil: geçersiz bir saat
        # diske yazılırsa hata ancak gece, kimse bakmazken ortaya çıkar ve
        # o gecenin yedeği hiç alınmaz. Reddi kullanıcı ekranda görsün.
        if path == "/api/backup/schedule":
            if not isinstance(body.get("enabled"), bool):
                return self._send(400, {"error": "'enabled' alanı true ya da "
                                                 "false olmalı."})
            hm = _parse_hhmm(body.get("time"))
            if not hm:
                return self._send(400, {"error": "Saat 'SS:DD' biçiminde "
                                                 "olmalı (00:00 – 23:59)."})
            rd = body.get("retention_days")
            # Panel sayıyı dizge olarak da gönderebilir (<input type="number">
            # değeri bir dizgedir). Ekranda 7 yazarken "tam sayı olmalı"
            # demek kullanıcıya çözülemeyen bir hata verirdi.
            if isinstance(rd, str) and rd.strip().isdigit():
                rd = int(rd.strip())
            if isinstance(rd, bool) or not isinstance(rd, int):
                return self._send(400, {"error": "'retention_days' gün sayısı "
                                                 "(tam sayı) olmalı."})
            if not BACKUP_RETENTION_MIN <= rd <= BACKUP_RETENTION_MAX:
                return self._send(400, {
                    "error": "Saklama süresi %d ile %d gün arasında olmalı."
                             % (BACKUP_RETENTION_MIN, BACKUP_RETENTION_MAX)})
            cfg = load_backup_cfg()
            cfg.update({"enabled": body["enabled"], "time": "%02d:%02d" % hm,
                        "retention_days": rd})
            if not cfg["enabled"]:
                # Kapatıldıysa bekleyen deneme de düşer: kapalı bir
                # zamanlamanın "10 dakika sonra tekrar" demesi anlamsızdır.
                cfg.update({"next_attempt": None, "attempt_note": None,
                            "attempts": 0})
            save_backup_cfg(cfg)
            nxt = backup_next_run(cfg)
            record_event("config", "tümü",
                         "Yedek zamanlaması: %s, saat %s, %d gün saklama%s"
                         % ("açık" if cfg["enabled"] else "kapalı",
                            cfg["time"], rd,
                            (" — sonraki koşum %s" % time.strftime(
                                "%Y-%m-%d %H:%M", time.localtime(nxt)))
                            if nxt else ""))
            # Zamanlama AÇILDIYSA ve hiç başarılı tur yoksa taban yedeğini
            # şimdi planla: kullanıcı düğmeye bastığı an korunmaya başlamalı,
            # gece 02:00'yi beklememeli.
            yeni = _ensure_baseline_backup("zamanlama açıldı")
            if yeni:
                cfg = yeni
            return self._send(200, {"ok": True, "next_run": nxt,
                                    "next_attempt": (cfg.get("next_attempt")
                                                     or nxt),
                                    "attempt_note": cfg.get("attempt_note")})

        # --- tavanları yeniden dengele --------------------------------
        # Tek motora değil YIĞINA ait bir işlem: motor kimliği almıyor.
        if path == "/api/rebalance":
            jid = new_job("rebalance", "tümü")

            def _dengele():
                # do_rebalance kendi job_done'unu çağırıyor; buradaki sarmal,
                # beklenmedik bir istisnada işin sonsuza dek "devam ediyor"
                # kalmasını önler (failover yolunda aynısı yapılıyor).
                try:
                    do_rebalance(jid)
                except Exception as e:
                    job_log(jid, "HATA:", repr(e))
                    record_event("rebalance_failed", "tümü",
                                 "Yeniden dengeleme beklenmeyen bir hatayla "
                                 "durdu: %r" % e, level="warning")
                    job_done(jid, False, repr(e))

            threading.Thread(target=_dengele, daemon=True).start()
            return self._send(202, {"job": jid})

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
            if action == "backup":
                jid = new_job("backup", eid)
                threading.Thread(target=do_backup, daemon=True,
                                 args=(jid, eid)).start()
                return self._send(202, {"job": jid})
            if action == "ha-drill":
                # DEVİR PROVASI GERÇEK BİR DEVİRDİR. Onay gövdede AÇIKÇA
                # istenmeli; bunu varsayılan yapmak, bir düğmeyi yanlışlıkla
                # tıklayan operatöre üretimde kesinti yaşatmak olurdu.
                if not body.get("onayla"):
                    return self._send(400, {"error":
                        "Devir provası GERÇEK bir devir yapar ve kısa bir "
                        "kesinti oluşur. Onay için gövdede {\"onayla\": true} "
                        "gönderin."})
                jid = new_job("ha-drill", eid)
                threading.Thread(target=do_ha_drill, daemon=True,
                                 args=(jid, eid)).start()
                return self._send(202, {"job": jid})
            if action == "maintenance":
                # Agresif bakım TABLOYU KİLİTLER. Varsayılan güvenli; agresif
                # ancak gövdede açıkça istenirse. Onayı panel alıyor: kilit
                # süresi TAHMİNİ orada gösteriliyor ve kullanıcı ona bakarak
                # karar veriyor.
                jid = new_job("maintenance", eid)
                threading.Thread(target=do_maintenance, daemon=True,
                                 args=(jid, eid, bool(body.get("agresif")))).start()
                return self._send(202, {"job": jid})
            if action == "drill":
                # Prova YIKICI DEĞİLDİR: tek kullanımlık bir kopyada çalışır,
                # üretime dokunmaz. Bu yüzden geri yükleme gibi onay istemiyor.
                jid = new_job("drill", eid)
                threading.Thread(target=do_drill, daemon=True,
                                 args=(jid, eid)).start()
                return self._send(202, {"job": jid})
            if action == "restore":
                # Geri yükleme VERİ SİLER; gövde İŞ BAŞLAMADAN doğrulanıyor.
                # Doğrulama do_restore'da da var (doğrudan çağrılabilir), ama
                # hatalı bir istek "202, iş başladı" cevabı almamalı:
                # kullanıcı sebebi ekranda görsün.
                engine = CATALOG.engine(eid)
                bk = engine.get("backup") or {}
                if not bk.get("supported"):
                    return self._send(400, {"error": "%s yedeklenmiyor: %s" % (
                        engine["name"],
                        bk.get("note")
                        or "bu motorda yedekleme desteklenmiyor.")})
                if not backup_script_can_restore(eid):
                    return self._send(400, {
                        "error": BACKUP_NO_RESTORE_MSG % (engine["name"],
                                                          eid)})
                _yol, hata = resolve_backup_file(eid, body.get("file"))
                if hata:
                    return self._send(400, {"error": hata})
                jid = new_job("restore", eid)
                threading.Thread(target=do_restore, daemon=True,
                                 args=(jid, eid, body.get("file"))).start()
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


def paylasilan_izin(yol, mod=0o664):
    """state/ ve logs/ altındaki dosyaları controller (container'da root) ile
    sunucudaki yönetici PAYLAŞIR. Kim önce yazarsa dosya onun olur; varsayılan
    umask ile root'un açtığı dosya 0644/root:root olur ve yönetici o dosyaya
    bir daha ASLA yazamaz. Ölçülen sonucu: state/backup.lock root'a geçtiğinde
    `backup.sh`, `pitr.sh taban`, `restore-drill.sh` ve `failover-drill.sh`
    "Kilit dosyası açılamadı" ile düşüyor — yani crontab'daki gece işleri
    sessizce hiç çalışmıyor, panel kendi yolundan yedek aldığı için de kimse
    fark etmiyor. Sahibi biz değilsek chmod düşer; sorun değil, o durumda
    dosya zaten bizim değildir."""
    try:
        os.chmod(yol, mod)
    except OSError:
        pass


def main():
    # Yeni dosyalar GRUP-YAZILABİLİR doğsun. Dizinler setgid olduğu için
    # (install.sh / stack.sh doctor --duzelt) grup ortak kalır ve iki kimlik
    # aynı dosyaya yazabilir. Tek başına umask yetmez, tek başına setgid de
    # yetmez — ikisi birlikte gerekir.
    os.umask(0o002)
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
        threading.Thread(target=prometheus_target_refresher, daemon=True).start()
        # Yedek zamanlayıcısı da yalnız Docker backend'inde: backup.sh
        # dump'ları `docker exec` ile alıyor, K8s'te karşılığı yok. Orada
        # başlatmak, her gece "container bulunamadı" ile düşen bir tur demek.
        threading.Thread(target=backup_scheduler, daemon=True).start()
        threading.Thread(target=maintenance_refresher, daemon=True).start()
        threading.Thread(target=pitr_refresher, daemon=True).start()
        threading.Thread(target=replication_refresher, daemon=True).start()

    Server(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
