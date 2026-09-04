#!/usr/bin/env python3
"""
Kubernetes manifest üreticisi — catalog.json'dan üretir.

Neden üretiyoruz, elle yazmıyoruz: katalog tek yetki kaynağı. Yeni bir motor
eklendiğinde compose ve K8s'in ayrışmaması için ikisi de aynı kaynaktan gelir.

    python3 scripts/gen-k8s.py               → k8s/base/ altına yaz
    python3 scripts/gen-k8s.py --with-secrets → .env'deki parolaları da göm
                                                (k8s/secrets/ — .gitignore'da)

K8s'te "aktif et" = StatefulSet'i 0'dan 1 replikaya ölçeklemek. Bu yüzden tüm
veritabanları replicas: 0 ile üretilir — Docker'daki "container hiç yaratılmaz"
davranışının doğrudan karşılığı.
"""
import base64
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NS = "databases-stack"

# Motora özgü ortam değişkenleri. Parolalar Secret'tan referansla gelir;
# manifestlere düz yazılmaz.
ENV = {
    "mariadb": [("MARIADB_ROOT_PASSWORD", "secret:MARIADB_PASSWORD"),
                ("MARIADB_DATABASE", "defaultdb")],
    "postgresql": [("POSTGRES_USER", "root"), ("POSTGRES_DB", "defaultdb"),
                   ("POSTGRES_PASSWORD", "secret:POSTGRES_PASSWORD"),
                   ("PGDATA", "/var/lib/postgresql/data/pgdata")],
    "mongodb": [("MONGO_INITDB_ROOT_USERNAME", "root"),
                ("MONGO_INITDB_ROOT_PASSWORD", "secret:MONGO_PASSWORD")],
    "redis": [("REDISCLI_AUTH", "secret:REDIS_PASSWORD")],
    "mssql": [("ACCEPT_EULA", "Y"), ("MSSQL_PID", "Developer"),
              ("MSSQL_SA_PASSWORD", "secret:MSSQL_PASSWORD")],
    "cassandra": [("CASSANDRA_CLUSTER_NAME", "databases-stack"),
                  ("CASSANDRA_AUTHENTICATOR", "PasswordAuthenticator"),
                  ("CASSANDRA_AUTHORIZER", "CassandraAuthorizer"),
                  ("MAX_HEAP_SIZE", "1G"), ("HEAP_NEWSIZE", "256M")],
    "elasticsearch": [("discovery.type", "single-node"),
                      ("xpack.security.enabled", "true"),
                      ("xpack.security.http.ssl.enabled", "false"),
                      ("ES_JAVA_OPTS", "-Xms1g -Xmx1g"),
                      ("ELASTIC_PASSWORD", "secret:ELASTIC_PASSWORD")],
    "kafka": [("KAFKA_NODE_ID", "1"), ("KAFKA_PROCESS_ROLES", "broker,controller"),
              ("KAFKA_LISTENERS", "PLAINTEXT://:9092,CONTROLLER://:9093"),
              ("KAFKA_ADVERTISED_LISTENERS", "PLAINTEXT://kafka:9092"),
              ("KAFKA_LISTENER_SECURITY_PROTOCOL_MAP", "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"),
              ("KAFKA_CONTROLLER_LISTENER_NAMES", "CONTROLLER"),
              ("KAFKA_CONTROLLER_QUORUM_VOTERS", "1@kafka:9093"),
              ("KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR", "1"),
              ("KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR", "1"),
              ("KAFKA_LOG_DIRS", "/var/lib/kafka/data"),
              ("CLUSTER_ID", "5L6g3nShT-eMCtK--X86sw")],
    "rabbitmq": [("RABBITMQ_DEFAULT_USER", "admin"),
                 ("RABBITMQ_DEFAULT_PASS", "secret:RABBITMQ_PASSWORD")],
    "clickhouse": [("CLICKHOUSE_USER", "default"), ("CLICKHOUSE_DB", "defaultdb"),
                   ("CLICKHOUSE_PASSWORD", "secret:CLICKHOUSE_PASSWORD")],
    "neo4j": [("NEO4J_AUTH", "secret:NEO4J_AUTH")],
    "minio": [("MINIO_ROOT_USER", "minioadmin"),
              ("MINIO_ROOT_PASSWORD", "secret:MINIO_ROOT_PASSWORD")],
}
IMAGES = {
    "mariadb": "mariadb:11.4", "postgresql": "postgres:16", "mongodb": "mongo:7.0",
    "redis": "redis:8-alpine", "mssql": "mcr.microsoft.com/mssql/server:2022-latest",
    "cassandra": "cassandra:5.0",
    "elasticsearch": "docker.elastic.co/elasticsearch/elasticsearch:8.15.3",
    "kafka": "apache/kafka:3.9.0", "rabbitmq": "rabbitmq:3.13-management-alpine",
    "clickhouse": "clickhouse/clickhouse-server:24.8", "neo4j": "neo4j:5-community",
    "minio": "minio/minio:RELEASE.2024-10-13T13-34-11Z",
}
# Motorların ÇALIŞMA ARGÜMANLARI.
# ⚠ Bazı motorlar bellek ayarlarını yalnızca komut satırından alır (env
# değişkeni okumazlar). K8s'te args verilmezse controller'ın hesapladığı
# değerler pod'a env olarak geçer ama MOTOR ONLARI GÖRMEZ — veritabanı
# varsayılanlarla çalışır ve ürünün "sunucuya göre ayarlıyorum" vaadi
# sessizce boşa çıkar. $(VAR) K8s'in env yerine koyma sözdizimidir; bu yüzden
# aşağıdaki değişkenlerin TUNING_ENV_DEFAULTS içinde tanımlı olması şart.
ARGS = {
    "postgresql": [
        "postgres",
        "-c", "shared_buffers=$(POSTGRES_SHARED_BUFFERS)",
        "-c", "effective_cache_size=$(POSTGRES_EFFECTIVE_CACHE)",
        "-c", "max_connections=$(POSTGRES_MAX_CONNECTIONS)",
        "-c", "max_worker_processes=$(POSTGRES_MAX_WORKERS)",
        "-c", "max_locks_per_transaction=$(POSTGRES_MAX_LOCKS)",
        "-c", "work_mem=$(POSTGRES_WORK_MEM)",
        "-c", "log_min_duration_statement=2000",
        "-c", "wal_level=replica",
        "-c", "hot_standby=on",
    ],
    "mariadb": [
        "--innodb-buffer-pool-size=$(MARIADB_BUFFER_POOL)",
        "--innodb-log-file-size=$(MARIADB_LOG_FILE_SIZE)",
        "--max-connections=$(MARIADB_MAX_CONNECTIONS)",
    ],
    "mongodb": [
        "mongod", "--auth", "--bind_ip_all",
        "--wiredTigerCacheSizeGB", "$(MONGO_WIREDTIGER_CACHE_GB)",
    ],
    "redis": [
        "redis-server",
        "--requirepass", "$(REDISCLI_AUTH)",
        "--appendonly", "yes",
        "--maxmemory", "$(REDIS_MAXMEMORY)",
        "--maxmemory-policy", "$(REDIS_MAXMEMORY_POLICY)",
    ],
    "minio": ["server", "/data", "--console-address", ":9001"],
}

# $(VAR) çözülebilmesi için bu değişkenlerin container env'inde TANIMLI olması
# gerekir. Controller aktivasyonda `kubectl set env` ile bunları ezer;
# buradakiler yalnız başlangıç/yedek değerlerdir (compose'daki ile aynı).
TUNING_ENV_DEFAULTS = {
    "postgresql": [("POSTGRES_SHARED_BUFFERS", "512MB"),
                   ("POSTGRES_EFFECTIVE_CACHE", "1536MB"),
                   ("POSTGRES_MAX_CONNECTIONS", "200"),
                   ("POSTGRES_MAX_WORKERS", "8"),
                   ("POSTGRES_MAX_LOCKS", "64"),
                   ("POSTGRES_WORK_MEM", "4MB")],
    "mariadb": [("MARIADB_BUFFER_POOL", "1G"),
                ("MARIADB_LOG_FILE_SIZE", "256M"),
                ("MARIADB_MAX_CONNECTIONS", "200")],
    "mongodb": [("MONGO_WIREDTIGER_CACHE_GB", "1")],
    "redis": [("REDIS_MAXMEMORY", "384mb"),
              ("REDIS_MAXMEMORY_POLICY", "allkeys-lru")],
    "mssql": [("MSSQL_MEMORY_LIMIT_MB", "2048")],
    "cassandra": [("MAX_HEAP_SIZE", "1G"), ("HEAP_NEWSIZE", "256M")],
    "elasticsearch": [("ES_JAVA_OPTS", "-Xms1g -Xmx1g")],
    "kafka": [("KAFKA_HEAP_OPTS", "-Xms512m -Xmx512m")],
    "neo4j": [("NEO4J_server_memory_heap_max__size", "512m"),
              ("NEO4J_server_memory_pagecache_size", "512m")],
}
STORAGE = {"mariadb": "20Gi", "postgresql": "20Gi", "mongodb": "20Gi", "redis": "5Gi",
           "mssql": "30Gi", "cassandra": "30Gi", "elasticsearch": "30Gi", "kafka": "20Gi",
           "rabbitmq": "5Gi", "clickhouse": "30Gi", "neo4j": "10Gi", "minio": "50Gi"}


def env_block(eid, indent):
    pad = " " * indent
    out = []
    for k, v in list(ENV.get(eid, [])) + list(TUNING_ENV_DEFAULTS.get(eid, [])):
        if isinstance(v, str) and v.startswith("secret:"):
            out.append("%s- name: %s\n%s  valueFrom:\n%s    secretKeyRef:\n"
                       "%s      name: db-secrets\n%s      key: %s"
                       % (pad, k, pad, pad, pad, pad, v.split(":", 1)[1]))
        else:
            out.append('%s- name: %s\n%s  value: "%s"' % (pad, k, pad, v))
    return "\n".join(out) or (pad + "[]")


def statefulset(e):
    eid = e["id"]
    k8s = e["k8s"]
    res = e["resources"]
    # Başlangıç limiti muhafazakâr: gerçek değeri controller aktivasyon anında
    # `kubectl set resources` ile host/node kapasitesine göre günceller.
    mem = max(res["min_mb"], 512)
    args = ARGS.get(eid)
    args_yaml = ""
    if args:
        args_yaml = "        args:\n" + "\n".join('        - "%s"' % a for a in args) + "\n"
    return f"""---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {eid}
  namespace: {NS}
  labels: {{app.kubernetes.io/name: {eid}, app.kubernetes.io/part-of: databases-stack}}
spec:
  # replicas: 0 → motor KAPALI. Dashboard'daki "Aktif Et" bunu 1 yapar.
  replicas: 0
  serviceName: {eid}
  selector:
    matchLabels: {{app.kubernetes.io/name: {eid}}}
  template:
    metadata:
      labels: {{app.kubernetes.io/name: {eid}}}
    spec:
      securityContext:
        fsGroup: 1000
      containers:
      - name: {eid}
        image: {IMAGES[eid]}
        imagePullPolicy: IfNotPresent
        ports:
        - name: client
          containerPort: {k8s["port"]}
{args_yaml}        env:
{env_block(eid, 8)}
        resources:
          requests:
            memory: "{mem}Mi"
            cpu: "100m"
          limits:
            memory: "{mem}Mi"
        volumeMounts:
        - name: data
          mountPath: {k8s["data_path"]}
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: {STORAGE[eid]}
---
apiVersion: v1
kind: Service
metadata:
  name: {eid}
  namespace: {NS}
  labels: {{app.kubernetes.io/name: {eid}}}
spec:
  selector: {{app.kubernetes.io/name: {eid}}}
  ports:
""" + "\n".join("  - name: %s\n    port: %d\n    targetPort: %d"
                % (p.get("label", "client").split()[0].lower().replace("/", "-"),
                   p["port"], p["port"])
                for p in e["client_ports"]) + "\n"


CONTROLLER = f"""---
apiVersion: v1
kind: ServiceAccount
metadata: {{name: controller, namespace: {NS}}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {{name: controller, namespace: {NS}}}
rules:
# Controller'ın TEK yetkisi StatefulSet'leri okumak ve ölçeklemek/boyutlandırmak.
# Docker kurulumundaki docker.sock erişiminin (host'ta tam yetki) aksine bu
# yetki dar kapsamlıdır — K8s dağıtımı bu açıdan daha güvenlidir.
- apiGroups: ["apps"]
  resources: ["statefulsets", "statefulsets/scale"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {{name: controller, namespace: {NS}}}
roleRef: {{apiGroup: rbac.authorization.k8s.io, kind: Role, name: controller}}
subjects: [{{kind: ServiceAccount, name: controller, namespace: {NS}}}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {{name: controller, namespace: {NS}}}
spec:
  replicas: 1
  selector: {{matchLabels: {{app.kubernetes.io/name: controller}}}}
  template:
    metadata: {{labels: {{app.kubernetes.io/name: controller}}}}
    spec:
      serviceAccountName: controller
      containers:
      - name: controller
        image: databases-stack/controller:1.0
        env:
        - {{name: BACKEND, value: "kubernetes"}}
        - {{name: K8S_NAMESPACE, value: "{NS}"}}
        # Katalog SALT-OKUNUR bir ConfigMap'ten, durum ise YAZILABİLİR bir
        # PVC'den gelir. İkisi aynı yola bağlanırsa controller state yazamaz:
        #   HATA: OSError(30, 'Read-only file system')
        - {{name: CATALOG_PATH, value: "/config/catalog.json"}}
        - {{name: STATE_DIR, value: "/state"}}
        - name: CONTROLLER_TOKEN
          valueFrom: {{secretKeyRef: {{name: db-secrets, key: CONTROLLER_TOKEN}}}}
        ports: [{{containerPort: 8000}}]
        readinessProbe:
          httpGet: {{path: /healthz, port: 8000}}
        resources:
          requests: {{memory: "128Mi", cpu: "50m"}}
          limits:   {{memory: "192Mi"}}
        volumeMounts:
        - {{name: catalog, mountPath: /config, readOnly: true}}
        - {{name: state, mountPath: /state}}
      volumes:
      - name: catalog
        configMap: {{name: catalog}}
      - name: state
        persistentVolumeClaim: {{claimName: controller-state}}
---
# Controller'ın kalıcı durumu: replikasyon topolojisi (hangi düğüm primary),
# otomatik devir açık olan motorlar ve olay geçmişi. Pod yeniden yaratılınca
# kaybolmamalı — devirden sonra topoloji kaybolursa sistem yanlış düğümü
# primary sanar.
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {{name: controller-state, namespace: {NS}}}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Service
metadata: {{name: controller, namespace: {NS}}}
spec:
  selector: {{app.kubernetes.io/name: controller}}
  ports: [{{port: 8000, targetPort: 8000}}]
"""


def main():
    with_secrets = "--with-secrets" in sys.argv
    cat = json.load(open(os.path.join(ROOT, "catalog.json"), encoding="utf-8"))

    base = os.path.join(ROOT, "k8s", "base")
    os.makedirs(base, exist_ok=True)

    files = []
    open(os.path.join(base, "namespace.yaml"), "w", encoding="utf-8").write(
        "---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n" % NS)
    files.append("namespace.yaml")

    for e in cat["engines"]:
        # "tool" türü kayıtlar (izleme gibi yardımcı modüller) veritabanı
        # değildir: kalıcı disk, istemci portu ve boyutlandırma profili
        # veritabanı varsayımlarına göre yazılmıştır. K8s'te bu işi zaten
        # kube-prometheus-stack gibi olgun Helm chart'ları yapıyor; onların
        # yerine yarım bir StatefulSet üretmek kullanıcıyı yanıltır.
        if e.get("kind", "database") != "database":
            continue
        name = "engine-%s.yaml" % e["id"]
        open(os.path.join(base, name), "w", encoding="utf-8").write(statefulset(e))
        files.append(name)

    open(os.path.join(base, "controller.yaml"), "w", encoding="utf-8").write(CONTROLLER)
    files.append("controller.yaml")

    # Katalog ConfigMap — controller motor listesini ve kaynak profillerini buradan okur
    cat_json = json.dumps(cat, ensure_ascii=False, indent=2)
    cm = ("---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n"
          "  name: catalog\n  namespace: %s\ndata:\n  catalog.json: |\n" % NS)
    cm += "\n".join("    " + ln for ln in cat_json.splitlines()) + "\n"
    open(os.path.join(base, "catalog-configmap.yaml"), "w", encoding="utf-8").write(cm)
    files.append("catalog-configmap.yaml")

    open(os.path.join(base, "kustomization.yaml"), "w", encoding="utf-8").write(
        "---\napiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n"
        "namespace: %s\nresources:\n%s\n" % (NS, "\n".join("- " + f for f in files)))

    # --- Secret ---------------------------------------------------------------
    keys = ["DB_PASSWORD", "CONTROLLER_TOKEN", "MARIADB_PASSWORD", "POSTGRES_PASSWORD",
            "MONGO_PASSWORD", "REDIS_PASSWORD", "MSSQL_PASSWORD", "CASSANDRA_PASSWORD",
            "ELASTIC_PASSWORD", "RABBITMQ_PASSWORD", "CLICKHOUSE_PASSWORD",
            "NEO4J_PASSWORD", "MINIO_ROOT_PASSWORD"]
    vals = {k: "DEĞİŞTİRİN" for k in keys}
    outdir, fname = base, "secret.example.yaml"
    if with_secrets:
        envf = os.path.join(ROOT, ".env")
        cur = {}
        if os.path.exists(envf):
            for line in open(envf, encoding="utf-8"):
                line = line.strip().rstrip("\r")
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cur[k.strip()] = v.strip().strip("\"'")
        for k in keys:
            vals[k] = cur.get(k) or cur.get("DB_PASSWORD", "")
        outdir = os.path.join(ROOT, "k8s", "secrets")
        os.makedirs(outdir, exist_ok=True)
        fname = "secret.yaml"

    # Neo4j parolayı "kullanıcı/parola" biçiminde ister
    vals["NEO4J_AUTH"] = "neo4j/" + vals.get("NEO4J_PASSWORD", "DEĞİŞTİRİN")
    # BAŞLIK HANGİ DOSYAYI YAZDIĞIMIZA BAĞLI. Eskiden ikisine de aynı uyarı
    # yazılıyordu ve depoda duran ÖRNEK dosya "gerçek parola içerir, commit
    # etmeyin" diyordu. İçinde gerçek parola yok — değerler 'DEĞİŞTİRİN'
    # yer tutucusunun base64'ü — ama depoyu açan biri için o uyarı ya yanlış
    # ya da bir sızıntı işareti. İkisi de doğru değil.
    if with_secrets:
        basmetin = ("# ⚠️ GERÇEK PAROLA İÇERİR — git'e commit ETMEYİN.\n"
                    "# Üretimde bunun yerine sealed-secrets / external-secrets"
                    " / Vault kullanın.\n")
    else:
        basmetin = ("# ÖRNEK. Değerler yer tutucudur ('DEĞİŞTİRİN' kelimesinin"
                    " base64'ü);\n"
                    "# gerçek parola YOKTUR ve bu dosyanın depoda durması"
                    " güvenlidir.\n"
                    "# Gerçeğini üretmek için:"
                    " python3 scripts/gen-k8s.py --with-secrets\n"
                    "# Çıktı k8s/secrets/ altına yazılır ve orası"
                    " .gitignore'dadır.\n"
                    "# Üretimde sealed-secrets / external-secrets / Vault"
                    " kullanın.\n")
    sec = ("---\n" + basmetin +
           "apiVersion: v1\nkind: Secret\nmetadata:\n  name: db-secrets\n"
           "  namespace: %s\ntype: Opaque\ndata:\n" % NS)
    for k in sorted(vals):
        sec += "  %s: %s\n" % (k, base64.b64encode(vals[k].encode()).decode())
    open(os.path.join(outdir, fname), "w", encoding="utf-8").write(sec)

    print("k8s/base/ üretildi: %d dosya" % (len(files) + 1))
    print("secret: %s" % os.path.join(outdir, fname))
    if not with_secrets:
        print("  (parolalar için: python3 scripts/gen-k8s.py --with-secrets)")


if __name__ == "__main__":
    main()
