# 02 — Network Design

## 2.1 VLAN / subnet plan

Example allocations — replace with your site's real CIDRs before apply.

| VLAN | Purpose | CIDR | Gateway | DHCP? |
|---|---|---|---|---|
| 10 | Management (vCenter/ESXi/bastion) | 10.10.10.0/24 | 10.10.10.1 | No, static |
| 20 | DMZ (F5 data, reverse proxies) | 10.10.20.0/24 | 10.10.20.1 | No |
| 30 | OCP nodes (masters + workers + bootstrap) | 10.10.30.0/24 | 10.10.30.1 | Static MAC reservations |
| 31 | OCP pod network (internal) | 10.128.0.0/14 | n/a | n/a (SDN) |
| 32 | OCP service network (internal) | 172.30.0.0/16 | n/a | n/a |
| 40 | Data tier (MSSQL, Redis, ActiveMQ, Kafka) | 10.10.40.0/24 | 10.10.40.1 | No |
| 50 | DevSecOps (Jenkins, Nexus, Sonar, Checkmarx, Aqua) | 10.10.50.0/24 | 10.10.50.1 | No |
| 60 | CyberArk Vault | 10.10.60.0/24 | 10.10.60.1 | No |
| 70 | Backup target (S3/NFS) | 10.10.70.0/24 | 10.10.70.1 | No |

### IP allocations (example)

| Host | IP |
|---|---|
| bastion | 10.10.10.20 |
| bootstrap | 10.10.30.10 (temporary) |
| master-0..2 | 10.10.30.11..13 |
| worker-0..2 | 10.10.30.21..23 |
| api.ocp.corp.local (VIP) | 10.10.30.100 |
| api-int.ocp.corp.local (VIP) | 10.10.30.100 |
| *.apps.ocp.corp.local (VIP) | 10.10.30.101 |
| mssql-pri / mssql-sec | 10.10.40.11 / .12 |
| sqlag-listener (AG VIP) | 10.10.40.100 |
| redis-0..5 | 10.10.40.21..26 |
| activemq-1..2 | 10.10.40.31..32 |
| kafka-1..2 | 10.10.40.41..42 |
| jenkins | 10.10.50.10 |
| nexus | 10.10.50.20 |
| sonarqube | 10.10.50.30 |
| checkmarx | 10.10.50.40 |
| aqua-console | 10.10.50.50 |

## 2.2 DNS

Split-horizon internal zone `corp.local`:

```
api.ocp.corp.local         A   10.10.30.100     ; control-plane VIP (F5)
api-int.ocp.corp.local     A   10.10.30.100     ; internal API (F5 or HAProxy)
*.apps.ocp.corp.local      A   10.10.30.101     ; apps wildcard (F5)
bootstrap.ocp.corp.local   A   10.10.30.10
master-{0..2}.ocp.corp.local A 10.10.30.{11..13}
worker-{0..2}.ocp.corp.local A 10.10.30.{21..23}
sqlag.corp.local           A   10.10.40.100
jenkins.corp.local         A   10.10.50.10
nexus.corp.local           A   10.10.50.20
...
```

Reverse PTR records for every A record.
SRV/PTR: `_etcd-server-ssl._tcp.ocp.corp.local` per master (required by OCP).

## 2.3 Load balancers (F5 BIG-IP)

Three VIPs required for OCP install:

| VIP | Port | Pool members | Monitor |
|---|---|---|---|
| api | 6443/TCP | bootstrap + master-0..2 (remove bootstrap after install) | `GET /readyz` on 6443 TLS |
| api-int | 22623/TCP | bootstrap + master-0..2 | `GET /healthz` on 22623 TLS |
| *.apps | 80/TCP & 443/TCP | worker-0..2 (router pods) | `GET /healthz/ready` on 1936 |

F5 NGINX API Gateway (in front of *.apps):
- HTTPS termination with corporate-CA-signed wildcard cert for `*.apps.corp.local`
- WAF policy: OWASP Top 10 signature set, bot defence, rate limit 100 rps/IP
- mTLS to OCP routers (optional)
- Forwarded-For header preservation

## 2.4 Firewall matrix (default-deny, list what is allowed)

| Source | Destination | Port/Proto | Purpose |
|---|---|---|---|
| Users (corporate) | F5 VIPs (DMZ) | 443/TCP | App + API access |
| F5 DMZ | Workers VLAN 30 | 80,443,1936/TCP | Ingress traffic |
| F5 DMZ | Masters VLAN 30 | 6443,22623/TCP | API access |
| Bastion (mgmt) | All VLANs | 22/TCP | Ops SSH |
| Bastion | Masters VLAN 30 | 6443/TCP | `oc`/`openshift-install` |
| Masters ↔ Masters | etcd | 2379,2380/TCP | etcd peer |
| Masters ↔ Workers | Kubelet/SDN | 10250/TCP, 4789/UDP (VXLAN), 6081/UDP (Geneve for OVN-K) | Control traffic |
| Workers ↔ Workers | SDN | 4789/UDP or 6081/UDP, 9000-9999/TCP | Pod-to-pod (OVN-K) |
| Workers | Data VLAN 40 | 1433 (MSSQL), 6379 (Redis), 61616 (ActiveMQ), 9092 (Kafka) | App → backends |
| Jenkins (VLAN 50) | OCP API (VLAN 30) | 6443/TCP | `helm`/`oc` |
| Jenkins | Nexus (50) | 8081,8082/TCP | Image push |
| Workers | Nexus (50) | 8082/TCP (registry) | Image pull |
| Workers | CyberArk (60) | 443/TCP | Secret fetch (ESO) |
| Jenkins | CyberArk (60) | 443/TCP | Secret fetch for deploys |
| Jenkins | SonarQube, Checkmarx, Aqua (50) | 9000, 80/443, 8443 | Scans |
| Workers | Observability (in-cluster) | n/a | Logs/metrics |
| Kasten | Backup target VLAN 70 | 443/TCP (S3) or 2049 (NFS) | Backups |
| OCP nodes | NTP, DNS, proxy | 123/UDP, 53, 8080 | Time/DNS/egress |
| All → Internet | Denied except via egress proxy | — | Controlled egress only |

## 2.5 Egress

- Cluster-wide HTTP(S) proxy configured at install time (`proxy.httpProxy`, `proxy.httpsProxy`, `proxy.noProxy`).
- `noProxy` includes cluster CIDRs, `.cluster.local`, `.svc`, `api-int.ocp.corp.local`, `.corp.local`.

## 2.6 TLS / PKI

- **Internal CA** (Corporate PKI) issues:
  - Wildcard `*.apps.corp.local` cert (F5)
  - API server cert
  - Service-level certs where OCP's self-signed service CA isn't acceptable
- Cert-manager inside cluster for app-level certs (ACME/internal CA via `ClusterIssuer`).
- Rotation: 1 year max, alert at 30 days to expiry (Prometheus rule).

## 2.7 NTP

All VMs time-sync from 2+ internal NTP servers (VLAN 10). `chrony` on RHEL; vSphere tools for Windows.
OCP requires clock skew < 500 ms across masters.
