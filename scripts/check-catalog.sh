#!/bin/bash
# =============================================================================
# Katalog ↔ compose tutarlılık kontrolü
# =============================================================================
# catalog.json ile docker-compose.yml iki ayrı dosyadır ve birbirinden habersiz
# değişebilir. Katalogda olup compose'da olmayan bir servis, dashboard'da
# "Aktif Et" düğmesine basılınca anlaşılmaz bir compose hatasına dönüşür.
# Bu betik ayrışmayı ERKEN yakalar. ./stack.sh doctor bunu çağırır.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

# UTF-8'i zorla: bazı ortamlarda (Windows konsolu, LANG=C olan cron) Python'un
# varsayılan çıktı kodlaması ✓/✗ gibi karakterleri yazamaz ve betik çöker.
PYTHONIOENCODING=utf-8 python3 - <<'PY'
import json, re, sys

cat = json.load(open("catalog.json", encoding="utf-8"))
compose = open("docker-compose.yml", encoding="utf-8").read()

# Servis adları: "services:" altındaki 2 boşluk girintili anahtarlar
svc_block = compose.split("\nservices:\n", 1)[1]
services = set(re.findall(r"^  ([a-z0-9][a-z0-9_-]*):\s*$", svc_block, re.M))
profiles = set(re.findall(r"^\s*profiles:\s*\[([^\]]+)\]", compose, re.M))
profiles = {p.strip() for grp in profiles for p in grp.split(",")}

errors, warnings = [], []
panel_ports, client_ports = {}, {}

for e in cat["engines"]:
    eid = e["id"]

    for s in e["services"]:
        if s not in services:
            errors.append("%s: '%s' servisi catalog'da var ama compose'da YOK" % (eid, s))
    if e["primary_service"] not in e["services"]:
        errors.append("%s: primary_service listede değil" % eid)
    if e["profile"] not in profiles:
        errors.append("%s: '%s' profili compose'da tanımlı değil" % (eid, e["profile"]))

    rep = e.get("replication", {})
    if rep.get("profile"):
        if rep["profile"] not in profiles:
            errors.append("%s: replikasyon profili '%s' compose'da yok" % (eid, rep["profile"]))
        if rep.get("replica_service") not in services:
            errors.append("%s: replika servisi '%s' compose'da yok" % (eid, rep.get("replica_service")))

    p = e.get("panel")
    if p:
        if p["port"] in panel_ports:
            errors.append("panel portu %d çakışıyor: %s ↔ %s" % (p["port"], eid, panel_ports[p["port"]]))
        panel_ports[p["port"]] = eid
        # gateway o portu dinliyor mu?
        if ("listen %d ssl" % p["port"]) not in open(
                "gateway/templates/stack.conf.template", encoding="utf-8").read():
            errors.append("%s: gateway %d portunu dinlemiyor" % (eid, p["port"]))
        for s in p.get("services", []):
            if s not in e["services"]:
                errors.append("%s: panel.services içindeki '%s' motorun servisleri arasında yok" % (eid, s))

    for cp in e["client_ports"]:
        if cp["port"] in client_ports:
            warnings.append("istemci portu %d iki motorda: %s, %s"
                            % (cp["port"], eid, client_ports[cp["port"]]))
        client_ports[cp["port"]] = eid

    # --- yönlendirme: her istemci portu gateway'de yayınlanmalı ---
    for r_ in e.get("route", []):
        if ('"%d:%d"' % (r_["listen"], r_["listen"]) not in compose
                and (":%d\"" % r_["listen"]) not in compose):
            errors.append("%s: %d portu gateway'de yayınlanmıyor" % (eid, r_["listen"]))
    if not e.get("route"):
        errors.append("%s: route tanımı yok — istemciler bağlanamaz" % eid)

    # --- failover tutarlılığı ---
    fo = e.get("failover", {})
    if fo.get("supported") and fo.get("mode") == "supervised":
        if rep.get("mode") not in ("primary-replica",):
            errors.append("%s: supervised failover primary-replica replikasyon ister" % eid)
        sc = "scripts/failover/%s.sh" % (fo.get("promote_script") or eid)
        import os as _os
        if not _os.path.exists(sc):
            errors.append("%s: yükseltme betiği yok: %s" % (eid, sc))
    if fo.get("supported") and not fo.get("note"):
        warnings.append("%s: failover notu yok" % eid)

    lic = e.get("license") or {}
    if not lic.get("name"):
        errors.append("%s: lisans bilgisi yok" % eid)
    if lic.get("free_for_production") not in (True, False, "copyleft"):
        errors.append("%s: license.free_for_production geçersiz" % eid)
    if lic.get("free_for_production") is not True and not lic.get("note"):
        errors.append("%s: kısıtlı lisans ama açıklaması yok" % eid)

    r = e.get("resources")
    if not r:
        errors.append("%s: resources bloğu yok — boyutlandırma çalışmaz" % eid)
        continue
    for k in ("min_mb", "share", "max_mb", "panel_mb", "exporter_mb", "tuning"):
        if k not in r:
            errors.append("%s: resources.%s eksik" % (eid, k))
    if r.get("min_mb", 0) > r.get("max_mb", 0):
        errors.append("%s: min_mb > max_mb" % eid)
    if not any(t.get("kind") == "limit" for t in r.get("tuning", [])):
        errors.append("%s: tuning içinde 'limit' türü yok (container limiti hesaplanamaz)" % eid)
    # Türetilen ayarlar container limitini aşmamalı
    for t in r.get("tuning", []):
        if t.get("kind") == "fraction" and t.get("factor", 0) >= 1.0:
            errors.append("%s: %s factor >= 1.0 — motor kendi limitini aşar" % (eid, t["env"]))
    if not e.get("plain", {}).get("title"):
        warnings.append("%s: sade açıklama (plain.title) yok" % eid)

# Üretilmiş K8s manifestleri catalog.json ile GÜNCEL mi?
# Katalog değişip manifestler yeniden üretilmezse depoda BAYAT manifestler
# kalır; kullanıcı "kubectl apply -k k8s/base" ile eski yapılandırmayı uygular.
# Sessiz ve fark edilmesi zor bir tutarsızlık — burada yakalanır.
import os as _os
cm = "k8s/base/catalog-configmap.yaml"
if _os.path.exists(cm):
    embedded, started = [], False
    for line in open(cm, encoding="utf-8"):
        if line.strip().startswith("catalog.json: |"):
            started = True
            continue
        if started:
            embedded.append(line[4:] if line.startswith("    ") else line)
    try:
        if json.loads("".join(embedded)) != cat:
            errors.append("k8s/base/ BAYAT — catalog.json değişmiş. "
                          "Çalıştırın: python3 scripts/gen-k8s.py")
    except Exception as _e:
        errors.append("k8s/base/catalog-configmap.yaml okunamadı: %s" % _e)

for w in warnings:
    print("  uyarı : " + w)
for x in errors:
    print("  HATA  : " + x)

if errors:
    print("\n  ✗ %d hata bulundu." % len(errors))
    sys.exit(1)
print("  ✓ katalog tutarlı (%d motor, %d servis, K8s manifestleri güncel)"
      % (len(cat["engines"]), len(services)))
PY
