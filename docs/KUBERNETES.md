# Kubernetes

*[Türkçe](KUBERNETES.tr.md) · **English***

Same product, same logic. In Docker, "activate" meant creating a container; in
Kubernetes it means **scaling the StatefulSet from 0 replicas to 1**. A stopped
engine has no pod at all — zero memory, zero CPU.

## Manifests are generated, not hand-written

`catalog.json` is the single source of truth. Compose and Kubernetes are derived
from the same source so that they do not drift apart over time.

```bash
python3 scripts/gen-k8s.py --with-secrets
kubectl apply -k k8s/base
```

What gets generated:

| File | Contents |
|---|---|
| `namespace.yaml` | The `databases-stack` namespace |
| `engine-<motor>.yaml` | StatefulSet (**replicas: 0**) + Service + PVC template |
| `controller.yaml` | The controller + ServiceAccount + Role + RoleBinding |
| `catalog-configmap.yaml` | The engine catalog (the controller reads this) |
| `secret.yaml` | Passwords — under `k8s/secrets/`, in `.gitignore` |

If you do not pass `--with-secrets`, `secret.example.yaml` is generated instead
(with placeholders).

## What the controller is allowed to do

```yaml
rules:
- apiGroups: ["apps"]
  resources: ["statefulsets", "statefulsets/scale"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list", "watch"]
```

In the Docker setup the controller is bound to `docker.sock` — on the host that
is equivalent to root. In Kubernetes its authority is limited to StatefulSet
scaling and nothing else. **From a security standpoint the K8s path is clearly
better.**

## How does sizing work on K8s?

The logic is the same; there are two differences.

**1. Capacity measurement.** In Docker the host's `/proc/meminfo` is read. In
Kubernetes **the allocatable memory of the largest node** is taken as the basis —
not the cluster total. The reason: a StatefulSet pod has to fit on a single node.
Calculating from the total RAM would produce a limit that fits on no node and
would leave the pod `Pending` forever.

**2. Application.** In Docker the computed values are written to
`state/tuning.env` and handed to compose. On K8s the same values are applied
directly to the resource:

```
kubectl set resources statefulset/postgresql --limits=memory=3276Mi --requests=memory=3276Mi
kubectl set env       statefulset/postgresql POSTGRES_SHARED_BUFFERS=819MB ...
kubectl scale         statefulset/postgresql --replicas=1
```

## Storage

`volumeClaimTemplates` uses the default StorageClass. To supply your own class,
add it inside `k8s/base/engine-<motor>.yaml`:

```yaml
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      storageClassName: fast-ssd      # ← buraya
      accessModes: ["ReadWriteOnce"]
```

(`# ← buraya` = "← here"; the comment marks the line you add.)

The sizes live in the `STORAGE` dictionary inside `scripts/gen-k8s.py`; change it
and regenerate.

## What is out of scope

The generated manifests cover **the databases and the control plane**. The
following exist in the Docker setup but were not included on the K8s side:

- **Web panels** (phpMyAdmin, pgAdmin, Kibana…) — they need their own
  Deployments; on K8s they are usually managed separately behind an Ingress
- **Gateway/TLS** — on K8s that job belongs to the Ingress Controller +
  cert-manager
- **Backup crons** — they should be written as `CronJob`s

If you want to add them, `scripts/gen-k8s.py` can be extended; the catalog
already holds the information needed (panel name, port, service).

## Recommendations for production

- **Secrets**: do not put `secret.yaml` into git. Use sealed-secrets,
  external-secrets or Vault.
- **Real high availability**: if that is what you want, look at the operators:
  CloudNativePG (PostgreSQL), Strimzi (Kafka), ECK (Elasticsearch),
  Percona/MongoDB Operator. This product's StatefulSets are for a single instance.
- **Anti-affinity and PodDisruptionBudget** should be added on a multi-node
  cluster.

## Do not run the Docker stack and k3s on the same machine

Installing k3s on the same server to try the product looks tempting, but **k3s
takes the published ports 80 and 443 away from Docker**. The reason is that in
the iptables `nat/PREROUTING` chain the `KUBE-SERVICES` and `CNI-HOSTPORT-DNAT`
rules come **before** the `DOCKER` chain: the packet is routed to Traefik without
ever reaching the gateway.

The symptom is confusing — everything looks healthy:

- `docker ps` → gateway "Up (healthy)"
- `docker exec gateway nginx -t` → valid
- `docker exec gateway curl http://127.0.0.1/` → 200
- but in the browser, plain text **`404 page not found`** (Traefik's answer)

`./stack.sh doctor` now catches this functionally: it compares the answer coming
from inside the container with the one coming from outside.

**Important:** `systemctl stop k3s` does NOT fix this. When k3s stops, its pods
keep living under containerd and the iptables rules stay in place. To really
clean up:

```bash
sudo /usr/local/bin/k3s-killall.sh     # pod'ları öldürür, iptables kurallarını temizler
sudo systemctl disable --now k3s       # yeniden başlatmada geri gelmesin
docker restart gateway
```

(The comments: the first line kills the pods and clears the iptables rules, the
second keeps k3s from coming back on reboot.)

To remove k3s completely: `sudo /usr/local/bin/k3s-uninstall.sh`.

The right approach: keep the Docker setup and the Kubernetes setup **on separate
machines**. Both are fed from the same catalog, but they cannot share the same
host's network stack.
