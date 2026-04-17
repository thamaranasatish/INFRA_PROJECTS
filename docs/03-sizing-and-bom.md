# 03 — Sizing, Capacity & Bill of Materials

## 3.1 VM sizing

### OpenShift cluster VMs (RHCOS)

| Role | Count | vCPU | RAM | OS disk | Data disk | Notes |
|---|---|---|---|---|---|---|
| Bootstrap | 1 (temp) | 4 | 16 GB | 120 GB | — | Destroyed after install |
| Master/Control-plane | 3 | 8 | 32 GB | 120 GB | 100 GB (etcd, SSD, IOPS ≥ 5000) | No workloads |
| Worker (app) | 3 | 16 | 64 GB | 120 GB | 200 GB (container storage) | `schedulable=true` |
| Infra (optional) | 3 | 8 | 32 GB | 120 GB | 200 GB | Logging/monitoring/registry |
| Bastion (RHEL 9) | 1 | 4 | 8 GB | 80 GB | — | Ansible controller |

### Shared services VMs

| Role | Count | vCPU | RAM | OS disk | Data disk | OS |
|---|---|---|---|---|---|---|
| MS SQL primary | 1 | 16 | 64 GB | 100 GB | 500 GB data + 200 GB log (RAID10 SSD) | Windows Server 2022 |
| MS SQL secondary | 1 | 16 | 64 GB | 100 GB | 500 GB + 200 GB | Windows Server 2022 |
| SQL witness (AG) | 1 | 2 | 4 GB | 80 GB | — | Windows |
| RedGate host | 1 | 4 | 16 GB | 100 GB | — | Windows |
| Redis node | 6 | 4 | 16 GB | 80 GB | 100 GB | RHEL 9 |
| ActiveMQ | 2 | 8 | 32 GB | 100 GB | 200 GB | RHEL 9 |
| Kafka broker | 2 | 8 | 32 GB | 100 GB | 500 GB (SSD) | RHEL 9 |
| ZooKeeper (if Kafka < 3.x KRaft) | 3 | 2 | 4 GB | 50 GB | — | RHEL 9 |
| Jenkins controller | 1 | 8 | 16 GB | 100 GB | 500 GB | RHEL 9 |
| Jenkins agents (static) | 2 | 8 | 16 GB | 100 GB | — | RHEL 9 |
| Nexus Repository Pro | 1 | 8 | 32 GB | 100 GB | 2 TB (for Docker blobs) | RHEL 9 |
| SonarQube | 1 | 4 | 16 GB | 100 GB | 200 GB | RHEL 9 |
| SonarQube PostgreSQL | 1 | 2 | 8 GB | 80 GB | 100 GB | RHEL 9 |
| Checkmarx SAST | 1 | 8 | 32 GB | 200 GB | 500 GB | Windows Server 2022 |
| Aqua Server | 1 | 4 | 16 GB | 100 GB | 100 GB | RHEL 9 |
| Aqua DB (PostgreSQL) | 1 | 4 | 16 GB | 80 GB | 200 GB | RHEL 9 |
| CyberArk Vault / CCP | existing | — | — | — | — | Re-used |
| Backup target (S3/NFS) | 1 | 4 | 16 GB | 100 GB | 10 TB | MinIO on RHEL, or NetApp |

### Totals (excluding CyberArk and existing F5)

- VMs: ~30
- Aggregate vCPU: ~190
- Aggregate RAM: ~780 GB
- Aggregate storage: ~25 TB

Plan for **1.3× headroom** on ESXi hosts after vSphere HA reservations.

## 3.2 vSphere host requirements

Assuming a 3-node ESXi cluster dedicated to OCP + services:

| Item | Spec |
|---|---|
| ESXi hosts | 3 × dual-socket, 24 cores/socket, 768 GB RAM |
| Storage | vSAN or NetApp NFS/FC; All-Flash tier for etcd + MSSQL; hybrid OK for rest |
| Network | 2 × 25 GbE (vMotion + VM + mgmt separated via vDS port groups) |
| vCenter | 8.0 U3 or later |
| vSphere HA | Enabled with admission control (25% CPU / 25% RAM reserved) |
| DRS | Fully automated; anti-affinity rules for OCP masters |

## 3.3 Storage classes inside OCP

| StorageClass | Backed by | Use |
|---|---|---|
| `thin-csi` (default) | vSphere CSI — thin-provisioned | General app PVCs |
| `thin-csi-encrypted` | vSphere CSI + VM encryption | Sensitive workloads |
| `odf-rbd` (optional) | OpenShift Data Foundation | ReadWriteMany via CephFS, block via RBD |

## 3.4 Licence inventory

| Product | Licence type |
|---|---|
| Red Hat OpenShift Container Platform | Subscription per core (cluster-wide) |
| Red Hat Enterprise Linux (bastion, services) | RHEL Standard/Premium |
| VMware vSphere + vCenter | Standard/Enterprise Plus |
| Microsoft SQL Server Enterprise | Core-based, SA for AG |
| Windows Server 2022 | Datacenter (covers unlimited VMs per host) |
| Veeam Kasten K10 | Per worker node |
| CyberArk Vault + CCP | Existing |
| Nexus Repository Pro | Per instance |
| SonarQube Enterprise (optional) or Community | Per LOC for Enterprise |
| Checkmarx SAST | Per developer |
| Aqua Enterprise | Per node / per scan |
| F5 BIG-IP LTM + ASM (WAF) | Per appliance |
| F5 NGINX Plus (if used as ingress controller) | Per instance |

## 3.5 Capacity growth model

- Start with 3 workers; each worker ≈ 12 usable vCPU / 48 GB after overhead.
- Expect ~20 app pods/worker (small Java pods).
- Scale-out trigger: cluster CPU > 70% for 7 days → add 1 worker.
- Scale-up triggers per service: see Alertmanager rules in Phase 4.
