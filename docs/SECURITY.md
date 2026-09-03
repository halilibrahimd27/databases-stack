# Security

*[Türkçe](SECURITY.tr.md) · **English***

This product was designed for use **on an internal network / behind a VPN**.

## Default security posture

| Topic | Status |
|---|---|
| Panel ports | **Not published** to the host — reachable only through the gateway |
| Panel traffic | TLS (internal CA, with IP SANs) + HTTP basic auth |
| Database ports | Published to the host (so your application can connect) |
| Passwords | Separate per engine, generated randomly by `install.sh` |
| Controller | No port of its own; only from the gateway, with a shared token |
| Metric endpoints | On a single TLS+auth port (9443), exporter ports closed |
| Passwords in scripts | Passed through an environment variable, **not visible** on the command line |

### Why it matters that passwords are not on the command line

If you type `docker exec mariadb mariadb -u root -pPAROLA`, the password shows up
on the host in `ps aux` output and inside `/proc/<pid>/cmdline` — every user on
the server can read it. That is why all scripts use environment variables such as
`MYSQL_PWD`, `PGPASSWORD`, `REDISCLI_AUTH`, `SQLCMDPASSWORD`.

## The controller's privileges

The controller is bound to the Docker socket. **This is a privilege equivalent to
root on the host** — anything that can start a container can mount the host file
system. That is why:

- It publishes no port to the host at all; it cannot be reached directly from the network
- It refuses every request with 401 unless it carries the `X-Api-Token` the gateway
  adds (not even a compromised panel on the same docker network can reach it)
- It accepts only the engine ids defined in `catalog.json`; no arbitrary service
  name or file path can be passed in
- It runs its subprocesses without a shell (`shell=False`) — no command injection

> On the Kubernetes deployment this privilege is far narrower: reading and scaling
> StatefulSets, nothing more. If you have strict security requirements, prefer the
> K8s path.

## TLS — without a domain

There is no domain name on an internal network, and Let's Encrypt cannot be used
(its validation wants a name reachable from outside). The solution is our own
miniature certificate authority (`scripts/gen-certs.sh`):

- `certs/ca.crt` — installed on the clients, valid for 10 years
- `certs/server.crt` — every IP and name of the server written in as a SAN, 825 days

Why a CA rather than self-signed: browsers **never** trust a self-signed
certificate with an IP address, but they do accept a certificate with an IP SAN
signed by a trusted CA. Install the CA once and the warning goes away entirely.

If the CA's private key (`certs/ca.key`) leaks, an attacker can produce valid
certificates for this network — the file is mode `600` and is in `.gitignore`.

If the server's IP changes:

```bash
./scripts/gen-certs.sh 192.168.1.55
docker restart gateway
```

## Recommended steps

**1. Don't let your application connect as root**

```bash
./stack.sh app-user
```

Creates a user with no `DROP DATABASE`, `DROP TABLE`, `TRUNCATE` or `FLUSHALL`
privilege. On MariaDB the grants are given on the user databases, not on `*.*` —
so it cannot read the password hashes in the `mysql` schema.

**2. Close the database ports to the outside**

If your applications are on the same server, don't publish the ports at all:

```yaml
# docker-compose.override.yml
services:
  mariadb:    { ports: [] }
  postgresql: { ports: [] }
  mongodb:    { ports: [] }
  redis:      { ports: [] }
```

**3. Firewall**

```bash
ufw allow from 10.8.0.0/24 to any port 443            # yalnız VPN ağı
ufw allow from 10.8.0.0/24 to any port 8081:8091 proto tcp
ufw deny 3306,5432,27017,6379,1433/tcp                # gerekmiyorsa
```

(`# yalnız VPN ağı` = the VPN network only; `# gerekmiyorsa` = if you don't need them.)

**4. Test your backups**

An untested backup is not a backup:

```bash
./scripts/backup.sh verify backups/mariadb/full/<dosya>
```

(`<dosya>` = the file name.) Run a real restore drill at least once a year.

## Known accepted compromises

- **Elasticsearch's HTTP TLS is off.** Basic auth is on, and the traffic stays on
  the internal network, behind the gateway's TLS. Do not open port 9200 to the outside.
- **Kafka has no authentication.** Setting up SASL is out of scope for a
  single-machine stack; open 9092 only to a network you trust.
- **Redis's `default` user has full privileges.** Move your applications to the
  restricted user created by `./stack.sh app-user`.
- **`credentials.txt` and `.env` are plain text** (mode 600). Limit who has access
  to the server.
- **The Dashboard's "Bağlantı bilgisi" (connection info) button shows the
  password.** This is deliberate: anyone who can reach it already has full
  privileges through phpMyAdmin/pgAdmin.
