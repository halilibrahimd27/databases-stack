# Monitoring

*[Türkçe](MONITORING.tr.md) · **English***

It shows you with graphs how the databases you have turned on are running. It
needs no setup and asks for no configuration: open **Monitoring** ("İzleme")
from the panel, and the graphs are already there.

```bash
./stack.sh enable monitoring
./stack.sh panel monitoring        # adresi ve parolayı yazar
```

(`# adresi ve parolayı yazar` = it prints the address and the password.)

When you turn it off no container runs and RAM usage is zero — the same logic
as the other engines.

## What you will see

| Dashboard | The question it answers |
|---|---|
| **Overview** ("Genel Bakış") | Is everything up? Which engine is using how much RAM? When does the disk fill up? |
| **Engine dashboards** | How many connections are there? How many operations per second? Is the cache doing any good? Is the replica behind? |

Under each panel it says what it means and **when you should worry**. The goal
is that you can answer the question "is something going wrong?" at a glance,
without knowing how to administer a database.

**The Overview dashboard matters especially for this product:** the stack
calculates and distributes memory automatically (see
[SIZING](../README.md#memory-is-calculated-automatically)). On this
dashboard you see how much each container is *actually* using side by side
with the limit allocated to it — that is, you can verify with your own eyes
whether the calculation is right.

## How it works

```
  engines           Prometheus            Grafana
 ┌─────────┐       ┌────────────┐       ┌──────────┐
 │exporter │──────▶│ scrapes    │──────▶│ draws    │
 └─────────┘       │ stores     │       │ alerts   │
                   └────────────┘       └──────────┘
                          ▲
                   target list
                   (controller generates)
```

Every engine already had an **exporter**; what was missing was the face that
reads it.

**The target list is not written by hand.** When you turn an engine on or off,
the controller regenerates `state/prometheus/targets.json`; Prometheus watches
the file and updates the list on its own. No restart is needed. An engine that
is off is not in the list, so no "unreachable" warnings rain down either —
being off is not a failure.

Prometheus connects to the exporters **directly** over the Docker network; TLS
and passwords drop out of the path. If you have a corporate Prometheus
outside, it can keep scraping through the gateway:

```yaml
scrape_configs:
  - job_name: databases-stack
    scheme: https
    metrics_path: /metrics/postgresql        # motor başına bir uç
    basic_auth: { username: admin, password: <panel parolası> }
    tls_config:  { ca_file: databases-stack-ca.crt }
    static_configs: [{ targets: ['<sunucu>:9443'] }]
```

(`# motor başına bir uç` = one endpoint per engine; `<panel parolası>` = the
panel password, `<sunucu>` = your server.)

## Resource usage

| Service | Memory | What it does |
|---|---|---|
| Prometheus | ~512 MB | Collects and stores the metrics |
| Grafana | ~256 MB | Draws the graphs |
| node-exporter | ~64 MB | The server's RAM/disk/CPU state |

~830 MB in total. A separate tool for per-container memory/CPU (cAdvisor) is
not run: that information is already published by the controller that
distributes the memory itself. This way the numbers in the graphs come from
the very ledger of the code that makes the allocation decision — a separate
tool counting differently would be confusing.

Like the other engines, if there is no room on the server it **does not start**
and tells you why — it does not silently choke the server.

The retention period is **15 days** by default, the disk limit **2 GB**. The
two are limited together: if only the period were limited, on a busy
installation the disk would silently fill up and the databases would stop
writing. To change them, `.env`:

```
PROMETHEUS_RETENTION=30d
PROMETHEUS_RETENTION_SIZE=5GB
```

## Alerts

There are **four** rules in `config/prometheus/rules/databases.yml`, and that
number is deliberately small:

- **MotorErisilemiyor** — an engine that is on has not answered for 2 minutes
- **BellekSinirinaYaklasiyor** — a container has exceeded 90% of the memory
  allocated to it (warning beforehand is better than it going down at midnight
  with an OOM)
- **ReplikasyonGeride** — the replica is more than 5 minutes behind; if an
  automatic failover happens in this state, the data in between is lost
- **DiskDoluyor** — less than 10% of the space is left

Hundreds of finely tuned rules are nothing but noise for a non-expert user.
Each alert's description says **what to do**.

If you want to set up notifications (e-mail, Slack, webhook), from inside
Grafana: **Alerting → Contact points**.

## Changing the dashboards

The dashboards live under `config/grafana/dashboards/*.json` as **part of the
code** and are mounted read-only: they stay in version control, they arrive by
themselves at install time, and they cannot be deleted by accident.

If you want to build your own dashboard, create a new dashboard in Grafana —
the ones here are not affected. If you want to change one of the ready-made
dashboards, edit the JSON file; Grafana re-reads it every 30 seconds.

## Troubleshooting

**The graphs are empty.** Check whether Prometheus is scraping the targets:
from inside Grafana, **Connections → Data sources → Prometheus → Explore**, and
run the query `up{job="databases"}`. If there is no row at all, the target list
is empty — make sure an engine is on, then:

```bash
cat state/prometheus/targets.json      # controller ne üretmiş?
./stack.sh logs prometheus
```

(`# controller ne üretmiş?` = what did the controller generate?)

**One engine's dashboard is empty, the others are full.** That engine's
exporter may not be running:

```bash
docker ps --filter name=-exporter
./stack.sh logs <motor>-exporter
```

MSSQL and Neo4j have no exporter; they appear only on the Overview dashboard
(as the memory/CPU usage the controller publishes).

**Logging in to Grafana.** Since the panel is already behind a password, you
enter Grafana as a viewer; to edit dashboards, log in with the `admin` user.
The password is in `credentials.txt`.
