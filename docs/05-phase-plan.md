# 05 — Phased Execution Plan

Each phase has: **objective → tasks → artifacts → exit criteria → rollback**.
Teams: **PLAT** (Platform/OCP), **NET** (Network/F5), **VIRT** (vSphere), **SEC** (SecOps), **DB**, **SRE**, **CICD**, **APP** (AppDev), **CHG** (Change Mgmt).

---

## Phase 0 — Governance & prerequisites

**Objective:** agree the target state, freeze scope, establish working groups.

| # | Task | Owner |
|---|---|---|
| 0.1 | ARB sign-off on HLD + this repo | PLAT |
| 0.2 | RACI matrix, on-call rota drafted | PLAT |
| 0.3 | CMDB entries for all VMs, CIs linked to service | PLAT |
| 0.4 | Red Hat OCP entitlement + pull-secret retrieved | PLAT |
| 0.5 | Licences staged (RHEL, MSSQL, Kasten, Aqua, Nexus, Checkmarx) | Procurement |
| 0.6 | Risk register opened | PLAT+SEC |

**Exit:** ARB-approved design, licences available, teams identified.

---

## Phase 1 — Network, DNS, LB, PKI

**Objective:** build the network plumbing OCP install depends on.

| # | Task | Owner |
|---|---|---|
| 1.1 | Create VLANs 10/20/30/40/50/60/70 + ACLs | NET |
| 1.2 | Implement firewall matrix (02-network-design §2.4) | NET+SEC |
| 1.3 | Create internal DNS zone records (api, api-int, *.apps, nodes, etcd SRV) | NET |
| 1.4 | F5 VIPs: api:6443, api-int:22623, apps:80/443 with health monitors | NET |
| 1.5 | Internal CA issues wildcard `*.apps.ocp.corp.local` + `api.ocp.corp.local` | PKI |
| 1.6 | Corporate egress proxy rules for VLAN 30 allow-list | NET |
| 1.7 | NTP reachability from VLAN 30 | NET |
| 1.8 | Validate: `dig`, `nmap`, `curl -kvI` from bastion | PLAT |

**Artifacts:** DNS export, F5 config backup, firewall change record.
**Exit:** green reachability report (script [ansible/preflight.yml](../ansible/preflight.yml)).
**Rollback:** revert F5/FW changes via change ticket; no production impact at this point.

---

## Phase 2 — VMware foundation

**Objective:** produce hardened templates and VM provisioning automation.

| # | Task | Owner |
|---|---|---|
| 2.1 | Build RHEL 9 golden template — CIS L1 + corporate agents | VIRT+SEC |
| 2.2 | Upload RHCOS OVA for target OCP release to content library | PLAT |
| 2.3 | Create vSphere service account for Terraform (least priv) | VIRT |
| 2.4 | Create resource pools, VM folders, tag categories | VIRT |
| 2.5 | DRS anti-affinity rules (masters), must-run-on rules where needed | VIRT |
| 2.6 | Terraform module for OCP VMs reviewed + unit-planned | PLAT |
| 2.7 | Provision bastion VM; install pinned toolchain (06-tools-versions) | PLAT |
| 2.8 | Run `terraform plan` and dry-run validate | PLAT |

**Artifacts:** [terraform/vsphere/](../terraform/vsphere/), hardened templates, bastion VM image.
**Exit:** `terraform plan` clean, templates pass STIG scan.
**Rollback:** destroy any partially-created VMs; templates stay.

---

## Phase 3 — OpenShift cluster install (UPI)

**Objective:** a running 3-master / 3-worker cluster, all operators `Available=True`.

| # | Task | Owner |
|---|---|---|
| 3.1 | Generate install-config (see [openshift/install-config.yaml.tmpl](../openshift/install-config.yaml.tmpl)) | PLAT |
| 3.2 | `openshift-install create manifests` + customise (network, proxy, registry) | PLAT |
| 3.3 | `openshift-install create ignition-configs` | PLAT |
| 3.4 | Publish ignition files to bastion web server (HTTPS) | PLAT |
| 3.5 | `terraform apply` → bootstrap + masters + workers with correct ignition | PLAT |
| 3.6 | Monitor `openshift-install wait-for bootstrap-complete` | PLAT |
| 3.7 | Remove bootstrap VM + bootstrap entry from F5 api/api-int pools | PLAT+NET |
| 3.8 | `openshift-install wait-for install-complete` | PLAT |
| 3.9 | Configure OIDC (Entra/ADFS), bind RBAC groups | PLAT+IAM |
| 3.10 | Remove `kubeadmin`, store break-glass admin in CyberArk | SEC |
| 3.11 | Configure image registry on persistent storage (ODF/NFS) | PLAT |
| 3.12 | Apply cluster-wide proxy, additional trust bundle (internal CA) | PLAT |
| 3.13 | Run OpenShift compliance operator baseline (CIS / NIST) | SEC |

**Exit:** `oc get co` all `Available=True Progressing=False Degraded=False`; console reachable via F5; SSO login works.
**Rollback:** destroy VMs via Terraform, clear DNS/F5 pools, re-plan.

---

## Phase 4 — Day-2 cluster services

**Objective:** the cluster is observable, backed-up, has storage and image registry.

| # | Task | Owner |
|---|---|---|
| 4.1 | Install **vSphere CSI** storage operator (if not built-in); create StorageClasses | PLAT |
| 4.2 | Install **OpenShift Logging** (EFK) — Elasticsearch + Fluentd + Kibana | PLAT |
| 4.3 | Install **OpenShift Monitoring** (in-cluster Prometheus + Alertmanager) + enable user-workload monitoring | PLAT |
| 4.4 | Deploy **Grafana** (community operator) + datasource → cluster Prometheus; dashboards imported | SRE |
| 4.5 | Alertmanager → email / Teams / PagerDuty routes | SRE |
| 4.6 | Install **Kasten K10** (Veeam) via OperatorHub; configure Location Profile (S3/NFS with immutability) | PLAT+BACKUP |
| 4.7 | Create K10 Policies: app-manifests, PVCs, etcd (daily + weekly + monthly, retention per policy) | BACKUP |
| 4.8 | Install **cert-manager** + `ClusterIssuer` pointing at internal CA | PLAT |
| 4.9 | Install **External Secrets Operator**; `ClusterSecretStore` targets CyberArk CCP | PLAT+SEC |
| 4.10 | Install **Aqua Enforcer** DaemonSet + Aqua Server integration | SEC |
| 4.11 | Install **Compliance Operator**, schedule weekly scans | SEC |
| 4.12 | Tag 3 workers as `infra` (if no dedicated infra nodes); move router/monitoring/logging there | PLAT |
| 4.13 | Test restore of a sample app from Kasten | BACKUP |

**Exit:** Kibana shows pod logs, Grafana shows node+pod metrics, Alertmanager fires a test alert to PagerDuty, K10 restore test green.

---

## Phase 5 — Shared services tier

Can run in partial parallel with Phase 4 if teams are separate.

### 5.A — Database tier (MSSQL AG)
| # | Task | Owner |
|---|---|---|
| 5.A.1 | Provision MSSQL primary + secondary + witness (Win 2022) | VIRT+DB |
| 5.A.2 | Configure WSFC + Always On Availability Group; listener VIP `sqlag.corp.local:1433` | DB |
| 5.A.3 | Enable TDE; backups to backup target VLAN 70 | DB |
| 5.A.4 | RedGate install + monitor targets | DB |
| 5.A.5 | Create app DBs, service logins; store creds in CyberArk safe | DB+SEC |

### 5.B — Caching tier (Redis)
| 5.B.1 | Deploy Redis Cluster (6 nodes, 3 primary + 3 replica) on VMs or in-cluster | PLAT |
| 5.B.2 | TLS + AUTH enabled; password in CyberArk | PLAT+SEC |

### 5.C — Messaging (ActiveMQ + Kafka)
| 5.C.1 | ActiveMQ Artemis master/slave cluster; JAAS auth; TLS | PLAT |
| 5.C.2 | Kafka 3.x with KRaft (no ZK) — primary + secondary brokers + MirrorMaker 2 for cross-replication | PLAT |
| 5.C.3 | Create audit topic; retention policy per compliance | PLAT+SEC |

### 5.D — DevSecOps stack
| 5.D.1 | Install **Nexus Repository Pro** with Docker hosted + proxy + maven + npm + raw repos; HTTPS via corp CA | CICD |
| 5.D.2 | Install **Jenkins** (LTS) controller + 2 static agents + dynamic Kubernetes agents in OCP; plugins pinned | CICD |
| 5.D.3 | Install **SonarQube** (Community or DE) + PostgreSQL backing DB | CICD+SEC |
| 5.D.4 | Install **Checkmarx SAST** server + scan engines | SEC |
| 5.D.5 | Install **Aqua Server** (already scanning via Enforcer) + image assurance policies | SEC |
| 5.D.6 | Configure **CyberArk** safes + applications for Jenkins (per env) and ESO | SEC+IAM |
| 5.D.7 | Wire **ADO Repos** webhooks → Jenkins | CICD |

**Exit:** hello-world pipeline builds, scans, pushes to Nexus, deploys to `products-dev`.

---

## Phase 6 — Application onboarding

**Objective:** `product-platform` live end-to-end.

| # | Task | Owner |
|---|---|---|
| 6.1 | Create namespaces `products-dev`, `products-test`, `products-prod` with quotas + LimitRange + NetworkPolicy | PLAT |
| 6.2 | Service accounts + RoleBindings (jenkins-deploy-dev/test/prod) | PLAT+IAM |
| 6.3 | Pull-secret for Nexus registry per namespace | PLAT |
| 6.4 | `ExternalSecret` → Secret `product-api-db` per namespace from CyberArk | SEC |
| 6.5 | TLS cert requests for `*.products.example.com` via cert-manager | PLAT |
| 6.6 | Onboard `Jenkinsfile.ci` and `Jenkinsfile.cd` as Jenkins pipeline jobs | CICD+APP |
| 6.7 | Run CI on a feature branch → dev deploy → smoke tests | APP |
| 6.8 | Promote tag to test; UAT/perf tests | APP+SRE |
| 6.9 | Prod approval gate → `helm upgrade --atomic` → smoke | APP+SRE |
| 6.10 | Synthetic monitoring (Blackbox exporter / Pingdom) → Alertmanager | SRE |

**Exit:** prod CRUD works via F5 VIP, dashboards populated, alerts wired, DR drill passes for the app.

---

## Phase 7 — Operate, audit, handover

| # | Task | Owner |
|---|---|---|
| 7.1 | Publish runbooks (09-runbooks) | PLAT+SRE |
| 7.2 | Quarterly K10 restore drill | BACKUP |
| 7.3 | Quarterly DB failover test | DB |
| 7.4 | Monthly patching window for RHEL VMs and OCP minor updates | PLAT |
| 7.5 | Pen-test + red-team exercise | SEC |
| 7.6 | ARB review at 30/60/90 days | PLAT |
| 7.7 | Lessons-learned retro; backlog groomed for Phase 8 (GitOps / Service Mesh) | PLAT |

**Exit:** 30 days stable, SLOs met, handover signed.

---

## Dependencies & critical path

```
P0 ──► P1 ──► P2 ──► P3 ──► P4 ──┬──► P6 ──► P7
                                 │
                          P5 ────┘
```

P4 and P5 can run in parallel after P3 completes, provided teams are separate.

## RACI summary

| Activity | R | A | C | I |
|---|---|---|---|---|
| Network changes | NET | Head of Infra | SEC | PLAT, APP |
| OCP install | PLAT | Head of Platform | NET, SEC | APP, SRE |
| Security controls | SEC | CISO | PLAT | All |
| Shared services | PLAT | Head of Platform | DB, APP | SRE |
| CI/CD pipelines | CICD | Eng Mgr | SEC, APP | PLAT |
| DR drill | BACKUP | Head of Platform | DB, PLAT | Business |
