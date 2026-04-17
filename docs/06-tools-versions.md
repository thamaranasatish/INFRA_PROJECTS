# 06 — Pinned Tool & Component Versions

Lock versions. Floating tags in production = operational debt.

## 6.1 Core platform

| Component | Version | Notes |
|---|---|---|
| VMware vCenter / ESXi | 8.0 Update 3 | HCL-verified for OCP 4.16 |
| Red Hat OpenShift | 4.16.latest z-stream | 4.16 is EUS; stay on a z-stream for 3 months before jumping |
| RHCOS | bundled with OCP 4.16 | Do not mix versions |
| RHEL (bastion + service VMs) | 9.4 | STIG-baseline |
| Windows Server (MSSQL/Checkmarx) | 2022 Datacenter (latest CU) | |
| vSphere CSI Driver | per OCP 4.16 support matrix | Built-in |
| OVN-Kubernetes | default in OCP 4.16 | |

## 6.2 OCP operators (OperatorHub)

| Operator | Channel | Pinned version |
|---|---|---|
| OpenShift Logging | stable-5.9 | 5.9.x |
| OpenShift Elasticsearch | stable-5.8 | 5.8.x (EOL watch) — migrate to Loki if possible |
| Cluster Logging → Loki Stack | stable-6.0 | 6.0.x (preferred over ES) |
| Cluster Monitoring | shipped | n/a |
| Compliance Operator | stable | 1.5.x |
| cert-manager | stable-v1 | 1.14.x |
| External Secrets Operator | stable | 0.9.x |
| Kasten K10 | stable | 7.0.x |
| Aqua Enforcer | stable | 2022.4 LTS or newer |
| Red Hat Advanced Cluster Security (optional) | stable | 4.5.x |

## 6.3 Shared services

| Component | Version | Notes |
|---|---|---|
| MS SQL Server Enterprise | 2022 CU14+ | Always On AG |
| Redis | 7.2 LTS | Cluster mode |
| Apache ActiveMQ Artemis | 2.33.0 | Master/slave |
| Apache Kafka | 3.7 (KRaft) | No ZooKeeper |
| MirrorMaker 2 | bundled | Cross-site |
| CyberArk Vault | existing 12.x+ | AIM CCP or Conjur Enterprise |

## 6.4 DevSecOps stack

| Tool | Version | Notes |
|---|---|---|
| Jenkins LTS | 2.452.x | |
| Jenkins Kubernetes plugin | latest compatible | For dynamic OCP agents |
| Jenkins plugins pinned set | `plugins.txt` checked into config repo | No "install suggested" |
| Nexus Repository Pro | 3.70.x | |
| SonarQube | 10.5 LTS | Community OK; DE recommended |
| SonarScanner for Maven | 4.0.0.4121 | |
| SonarLint (IDE) | latest | Dev workstations only |
| Checkmarx SAST | 9.6 | |
| Aqua Enterprise | 2022.4 LTS | Server + Enforcer + Scanner |
| Veeam Kasten K10 | 7.0 | |
| HashiCorp Terraform | 1.9.x | |
| Terraform vSphere provider | 2.8.x | |
| Ansible Core | 2.16 | |
| `openshift-install` / `oc` | matches OCP 4.16 | From cluster pull URL |
| `helm` | 3.15.x | |
| `govc` | 0.42.x | |
| `jq` | 1.7 | |
| `yq` | 4.44 | |

## 6.5 Application runtime (from `java_project`)

| | Version |
|---|---|
| JDK | Temurin 17 LTS |
| Maven | 3.9.x |
| Spring Boot | 3.3.x |
| Node.js | 20 LTS |
| React | 18.3 |
| nginx (unprivileged) | 1.27 |

## 6.6 Image base policy

- Only base images from approved registries:
  - Red Hat UBI 9 (minimal/micro preferred)
  - `eclipse-temurin:17-jre-alpine` (for Java runtime; signed, SBOM-available)
  - `nginxinc/nginx-unprivileged:1.27-alpine`
- No `:latest` outside dev.
- Images must be **signed** (cosign) and **SBOM-attached** (syft); Aqua policy blocks unsigned.

## 6.7 Change / patch cadence

| Layer | Cadence |
|---|---|
| Emergency CVEs (CVSS ≥ 9) | within 72 h |
| OCP z-stream (patch) | monthly |
| OCP y-stream (minor) | every 6 months, after 30 days of upstream GA |
| RHEL patches | monthly rolling |
| MSSQL CU | quarterly |
| Jenkins LTS | quarterly |
| Nexus / Sonar / Checkmarx | quarterly |
