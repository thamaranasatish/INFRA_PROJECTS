# 01 — Architecture Overview

## 1.1 Logical tiers

| Tier | Components | Hosting |
|---|---|---|
| **Edge / Access** | F5 BIG-IP + NGINX API Gateway (WAF, TLS termination, rate-limiting) | Existing F5 appliance pair |
| **Ingress (cluster)** | OpenShift Ingress Operator (HAProxy) — default; F5 NGINX Ingress Controller optional | OCP worker nodes |
| **Application** | `product-api` (Spring Boot), `product-ui` (React/nginx) in `products-dev/test/prod` | OCP worker pods |
| **Caching** | Redis Cluster (3 primaries + 3 replicas, in-cluster Operator or dedicated VMs) | OCP StatefulSet or VM cluster |
| **Messaging** | ActiveMQ Artemis master/slave cluster with multiple queues | Dedicated VMs |
| **Audit stream** | Kafka (primary + secondary) for audit-log topic | Dedicated VMs |
| **Database** | MS SQL Server Enterprise — Always On AG, primary + secondary | Dedicated VMs (Windows Server) |
| **DB management** | RedGate SQL Toolbelt / SQL Monitor | Admin Windows VM |
| **Config / Secrets** | CyberArk Conjur Enterprise / AIM CCP | CyberArk cluster (existing) |
| **CI/CD** | Jenkins controller + agents, Nexus, SonarQube, Checkmarx, Aqua console | DevSecOps VMs |
| **Source control** | Azure DevOps (ADO) Repos | SaaS |
| **Observability** | Elasticsearch + Kibana + Fluentd (logs), Prometheus + Alertmanager + Grafana (metrics) | OCP in-cluster |
| **Backup** | Veeam Kasten K10 | OCP Operator |
| **VM platform** | VMware vSphere 8.x | Existing |

## 1.2 OpenShift cluster layout

- **3 × Control-plane VMs** (RHCOS) — run etcd, API server, controller-manager, scheduler. **Dedicated VMs. No workloads.**
- **3 × Worker VMs** (RHCOS) — application workloads + ingress routers (host network).
- **(Optional) 3 × Infra VMs** — recommended so logging/monitoring/registry don't consume app capacity. If budget-constrained, tag 3 workers as `node-role.kubernetes.io/infra=` and use `NodeSelector`/`Toleration` to pin infra workloads there (see [docs/03-sizing-and-bom.md](03-sizing-and-bom.md)).
- **1 × Bootstrap VM** — temporary, destroyed after install.
- **1 × Bastion VM (RHEL 9)** — Ansible controller, `oc`/`openshift-install`, HAProxy for install-time LB (later replaced by F5).

vSphere placement rules:
- Control-plane VMs on **different ESXi hosts** (DRS anti-affinity "must").
- Worker VMs spread across hosts via DRS anti-affinity "should".
- Datastore diversity: etcd on SSD-backed datastore with `IOPS ≥ 5000`.

## 1.3 Namespaces

| Namespace | Purpose | Owner |
|---|---|---|
| `openshift-*` | Platform (managed by OCP) | Platform |
| `openshift-logging` | EFK stack | Platform |
| `openshift-monitoring` / `openshift-user-workload-monitoring` | Prometheus stack | Platform |
| `openshift-storage` | ODF (if used) | Platform |
| `kasten-io` | Kasten K10 | Platform/Backup |
| `aqua` | Aqua Enforcer + Server | SecOps |
| `cert-manager` | ACME/internal CA integration | Platform |
| `external-secrets` | External Secrets Operator (CyberArk sync) | Platform/SecOps |
| `products-dev` / `products-test` / `products-prod` | Application | AppDev |
| `devsecops` | Jenkins agents (if in-cluster) | CI/CD |

## 1.4 Data flows

1. **User → App.** Browser → F5 VIP (443) → OCP Ingress (HAProxy) → `product-ui` pod → backend via cluster DNS → `product-api` pod → external MS SQL.
2. **CI.** Dev push → ADO Repos → Jenkins webhook → build/test/SAST/image/scan/push Nexus.
3. **CD.** Jenkins → CyberArk (fetch DB creds) → `helm upgrade` via `oc` against OCP API (6443) → new pods pulled from Nexus → smoke tests.
4. **Observability.** Pods → Fluentd DaemonSet → Elasticsearch → Kibana/Grafana; node-exporter/kube-state → Prometheus → Alertmanager → email/Teams/PagerDuty.
5. **Audit.** App → Kafka audit topic → SIEM / long-term store.
6. **Backup.** Kasten → snapshots of etcd (via Velero add-on), PVCs, app manifests → target: on-prem S3/NFS + optional offsite.

## 1.5 Network boundaries

See [02-network-design.md](02-network-design.md). Summary:
- **DMZ VLAN** — F5 only.
- **OCP VLAN** — masters, workers (east-west allowed).
- **Data VLAN** — MS SQL, Redis, ActiveMQ, Kafka.
- **DevSecOps VLAN** — Jenkins, Nexus, Sonar, Checkmarx, Aqua.
- **Management VLAN** — vCenter, ESXi mgmt, bastion, backup target.
- Firewalls between every tier; default-deny egress from OCP.

## 1.6 Identity & RBAC

- **Cluster identity**: OCP OIDC → corporate ADFS/Entra ID.
- **Groups**:
  - `ocp-cluster-admins` — cluster-admin (break-glass only, MFA)
  - `ocp-platform-ops` — admin on `openshift-*`, `kasten-io`, `aqua`
  - `ocp-appdev-products` — admin on `products-dev`, edit on `products-test`, view on `products-prod`
  - `ocp-sre` — view cluster-wide, admin on observability
- **Service accounts** for Jenkins per environment (`jenkins-deploy-dev`, `-test`, `-prod`) with least privilege RoleBindings (edit on that namespace only).
