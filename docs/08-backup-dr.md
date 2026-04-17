# 08 — Backup & Disaster Recovery

## 8.1 Scope

| Asset | Tool | Frequency | Retention | RPO | RTO |
|---|---|---|---|---|---|
| etcd | Kasten K10 (etcd addon) + cronjob snapshot | every 6 h | 14 days | 6 h | 1 h |
| Cluster resources (YAML) | Kasten K10 | daily | 30 days | 24 h | 1 h |
| App PVCs | Kasten K10 (CSI snapshot) | daily + on pre-deploy | 30 days daily / 12 weekly / 12 monthly | 24 h | 2 h |
| MS SQL (AG) | Native + Kasten | tx-log 15 min, full daily, diff hourly | 35 days | 15 min | 30 min (AG failover) |
| Redis | AOF + RDB dump to backup target | 1 h | 7 days | 1 h | 30 min |
| Kafka | MirrorMaker 2 replicate to secondary + daily topic snapshot | continuous | 7 days | minutes | 30 min |
| ActiveMQ | message store replicated (master/slave) + daily backup | continuous | 7 days | minutes | 30 min |
| CyberArk Vault | Vault replication + immutable backup | built-in + daily | per policy | 1 h | 1 h |
| Jenkins config | `thinBackup` + pipeline-as-code in Git | daily | 30 days | 24 h | 2 h |
| Nexus blobs + DB | Nexus backup task + FS snapshot | daily | 30 days | 24 h | 4 h |
| SonarQube | PG dump | daily | 30 days | 24 h | 4 h |
| Checkmarx | Native backup | daily | 30 days | 24 h | 4 h |
| VMware VMs (non-OCP) | Veeam B&R | daily incremental, weekly full | 60 days | 24 h | 2 h |

## 8.2 Kasten K10 setup

- Install via OperatorHub in `kasten-io` namespace.
- **Location Profile**: S3-compatible (MinIO on-prem or NetApp StorageGRID) with **object lock / immutability** (WORM 30 days).
- **Infrastructure Profile**: vSphere CSI + VolumeSnapshotClass (CSI snapshots, not Veeam agent inside pod).
- **Policies**:
  - `platform-etcd-6h` — subject: etcd; schedule 6h; retention 14×6h + 7×1d
  - `apps-daily` — subjects: `products-*`, `openshift-logging`, `openshift-monitoring`; schedule 01:00 daily; retention 30d + 12w + 12m; includes manifests + PVCs
  - `apps-pre-deploy` — hook from Jenkins CD before `helm upgrade` in prod
- **Blueprints** for stateful apps (e.g. Redis flush-all-before-snapshot hooks).
- RBAC: `kasten-admin` group only; restore requires ticket + approval.

## 8.3 etcd additional safety

- Built-in OCP backup CronJob (`cluster-backup.sh`) to a PV, rotated to backup target nightly.
- Quarterly restore drill on a lab cluster.

## 8.4 DR tiers

| Tier | Example | Recovery strategy |
|---|---|---|
| **App failure** | pod crashloop | `helm rollback` (CD pipeline) |
| **Namespace failure** | bad migration | K10 restore of previous point-in-time |
| **Worker failure** | ESXi host down | vSphere HA restarts VMs; cluster self-heals |
| **Control-plane failure** | quorum loss | etcd restore from K10 snapshot on surviving masters |
| **Cluster destruction** | ransomware | Re-install OCP on new VMs; K10 restore manifests + PVCs into new cluster |
| **Site loss** | datacentre down | Secondary-site cluster (planned future phase); MSSQL AG async replica already at DR site; Kafka MM2 already replicating; app images pulled from DR Nexus replica |

## 8.5 Runbooks (linked from [09-runbooks.md](09-runbooks.md))

- `runbook-etcd-restore.md`
- `runbook-kasten-app-restore.md`
- `runbook-mssql-ag-failover.md`
- `runbook-cluster-rebuild.md`
- `runbook-dr-drill.md`

## 8.6 DR testing calendar

| Test | Frequency | Owner |
|---|---|---|
| App restore (non-prod) | monthly | Backup |
| MSSQL AG failover | quarterly | DB |
| etcd restore (lab) | quarterly | PLAT |
| Full cluster rebuild (lab) | twice a year | PLAT |
| Site-fail simulation | annually | PLAT + Business |

All tests produce evidence (screenshots, timings, ticket) uploaded to GRC.
