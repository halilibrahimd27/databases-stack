# Kubernetes

Aynı ürün, aynı mantık. Docker'da "aktif et" bir container yaratmaktı;
Kubernetes'te **StatefulSet'i 0 replikadan 1'e ölçeklemek**. Kapalı motorun
pod'u hiç yoktur — sıfır bellek, sıfır CPU.

## Manifestler üretilir, elle yazılmaz

`catalog.json` tek yetki kaynağıdır. Compose ve Kubernetes aynı kaynaktan
türetilir ki zamanla ayrışmasınlar.

```bash
python3 scripts/gen-k8s.py --with-secrets
kubectl apply -k k8s/base
```

Üretilenler:

| Dosya | İçerik |
|---|---|
| `namespace.yaml` | `databases-stack` isim alanı |
| `engine-<motor>.yaml` | StatefulSet (**replicas: 0**) + Service + PVC şablonu |
| `controller.yaml` | Kontrol servisi + ServiceAccount + Role + RoleBinding |
| `catalog-configmap.yaml` | Motor kataloğu (kontrol servisi bunu okur) |
| `secret.yaml` | Parolalar — `k8s/secrets/` altında, `.gitignore` içinde |

`--with-secrets` vermezseniz `secret.example.yaml` üretilir (yer tutucularla).

## Kontrol servisinin yetkisi

```yaml
rules:
- apiGroups: ["apps"]
  resources: ["statefulsets", "statefulsets/scale"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: [""]
  resources: ["pods", "services"]
  verbs: ["get", "list", "watch"]
```

Docker kurulumunda kontrol servisi `docker.sock`a bağlıdır — bu host üzerinde
root'a eşdeğerdir. Kubernetes'te yetki yalnızca StatefulSet ölçekleme ile
sınırlıdır. **Güvenlik açısından K8s yolu belirgin şekilde daha iyidir.**

## Boyutlandırma K8s'te nasıl çalışır?

Mantık aynıdır, iki fark vardır:

**1. Kapasite ölçümü.** Docker'da host'un `/proc/meminfo`'su okunur. Kubernetes'te
**en büyük node'un allocatable belleği** esas alınır — cluster'ın toplamı değil.
Sebep: bir StatefulSet pod'u tek bir node'a sığmak zorundadır. Toplam RAM'e göre
hesaplamak, hiçbir node'a sığmayan bir limit üretip pod'u sonsuza dek `Pending`
durumunda bırakırdı.

**2. Uygulama.** Docker'da hesaplanan değerler `state/tuning.env`e yazılıp
compose'a verilir. K8s'te aynı değerler doğrudan kaynağa uygulanır:

```
kubectl set resources statefulset/postgresql --limits=memory=3276Mi --requests=memory=3276Mi
kubectl set env       statefulset/postgresql POSTGRES_SHARED_BUFFERS=819MB ...
kubectl scale         statefulset/postgresql --replicas=1
```

## Depolama

`volumeClaimTemplates` varsayılan StorageClass'ı kullanır. Kendi sınıfınızı
vermek için `k8s/base/engine-<motor>.yaml` içine ekleyin:

```yaml
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      storageClassName: fast-ssd      # ← buraya
      accessModes: ["ReadWriteOnce"]
```

Boyutlar `scripts/gen-k8s.py` içindeki `STORAGE` sözlüğündedir; değiştirip
yeniden üretin.

## Kapsam dışı olanlar

Üretilen manifestler **veritabanlarını ve kontrol düzlemini** kapsar. Şunlar
Docker kurulumundadır ama K8s tarafına dahil edilmemiştir:

- **Web panelleri** (phpMyAdmin, pgAdmin, Kibana…) — kendi Deployment'ları
  gerekir; K8s'te genelde Ingress arkasında ayrı yönetilir
- **Gateway/TLS** — K8s'te bu iş Ingress Controller + cert-manager'ın işidir
- **Yedekleme cron'ları** — `CronJob` olarak yazılmalıdır

Bunları eklemek isterseniz `scripts/gen-k8s.py` genişletilebilir; katalogda
gereken bilgi (panel adı, port, servis) zaten mevcuttur.

## Üretim için öneriler

- **Sırlar**: `secret.yaml`ı git'e koymayın. sealed-secrets, external-secrets
  ya da Vault kullanın.
- **Gerçek yüksek erişilebilirlik** istiyorsanız operatörlere bakın:
  CloudNativePG (PostgreSQL), Strimzi (Kafka), ECK (Elasticsearch),
  Percona/MongoDB Operator. Bu ürünün StatefulSet'leri tek instance içindir.
- **Anti-affinity ve PodDisruptionBudget** çok node'lu cluster'da eklenmelidir.
