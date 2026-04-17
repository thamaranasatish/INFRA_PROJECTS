# Infra_Project — Enterprise DevSecOps Platform on VMware + OpenShift

**Author role:** Principal DevSecOps Architect
**Target platform:** VMware vSphere on-prem cluster hosting a Red Hat OpenShift Container Platform (OCP) cluster, supporting application workloads from [../java_project](../java_project).
**Deployment model:** UPI (User-Provisioned Infrastructure) on vSphere — 3 control-plane VMs + 3 worker VMs + ancillary service VMs.

---

## Executive summary

This project provisions the complete infrastructure, tooling, security controls and operational procedures required to build, secure, deploy and run the `product-platform` application (Spring Boot + React + MS SQL) on OpenShift. It is broken into **7 phases** that can be executed sequentially or in partial parallel by a coordinated platform team.

```
Phase 0  Governance & prerequisites
Phase 1  Network, DNS, load-balancing, certificates
Phase 2  VMware foundation (templates, VM provisioning)
Phase 3  OpenShift cluster install (UPI)
Phase 4  Day-2 cluster services (logging, monitoring, backup, storage)
Phase 5  Shared services tier (DB, MQ, Redis, Kafka, CyberArk, Nexus, Jenkins, SonarQube, Checkmarx, Aqua)
Phase 6  CI/CD onboarding and application go-live
Phase 7  Operate, audit, DR drill, handover
```

---

## Table of contents

| # | Document | Purpose |
|---|---|---|
| 1 | [docs/01-architecture-overview.md](docs/01-architecture-overview.md) | Logical + physical architecture, data flows, tier responsibilities |
| 2 | [docs/02-network-design.md](docs/02-network-design.md) | VLANs, subnets, firewall matrix, DNS, load-balancers, F5 |
| 3 | [docs/03-sizing-and-bom.md](docs/03-sizing-and-bom.md) | VM sizing, storage, licences, capacity model |
| 4 | [docs/04-preinstall-checklist.md](docs/04-preinstall-checklist.md) | Preflight gate before Phase 3 |
| 5 | [docs/05-phase-plan.md](docs/05-phase-plan.md) | Detailed phase-by-phase execution plan with RACI |
| 6 | [docs/06-tools-versions.md](docs/06-tools-versions.md) | Pinned versions for every component in the stack |
| 7 | [docs/07-security-hardening.md](docs/07-security-hardening.md) | STIG, CIS, OpenShift SCC, image policy, secret handling |
| 8 | [docs/08-backup-dr.md](docs/08-backup-dr.md) | Kasten K10 policies, RPO/RTO, DR runbook |
| 9 | [docs/09-runbooks.md](docs/09-runbooks.md) | Day-2 operations: upgrades, node drain, cert rotation, incident |

### Skeletons / artifacts

| Path | Purpose |
|---|---|
| [terraform/vsphere/](terraform/vsphere/) | vSphere VM provisioning (control-plane, workers, bootstrap, services) |
| [ansible/](ansible/) | Post-VM config (NTP, DNS, OS hardening, tool install) |
| [openshift/install-config.yaml.tmpl](openshift/install-config.yaml.tmpl) | OCP UPI install-config template |
| [diagrams/topology.mmd](diagrams/topology.mmd) | Mermaid architecture diagram |

---

## Guiding principles

1. **Defence in depth.** Network segmentation, host hardening, SCC, admission control (Aqua Enforcer / Gatekeeper), secret management, image scanning, runtime scanning.
2. **Immutable infrastructure.** VMs from hardened templates; OCP nodes are cattle, not pets; app images tagged by git SHA.
3. **Separation of duties.** Platform team owns infra; AppDev owns workloads; SecOps owns policies; no single human has end-to-end prod access.
4. **Zero secrets at rest in Git.** All secrets in CyberArk; injected at deploy time.
5. **Everything as code.** Terraform for vSphere, Ansible for OS, Helm for apps, Jenkins Pipelines as code.
6. **Observability from day one.** Metrics, logs, traces, audit — provisioned before the first app.
7. **Tested DR.** Quarterly restore drills from Kasten K10; monthly failover test for DB/MQ.

---

## High-level topology

```
                ┌───────────────────────────────────────────────────────────────────┐
                │                       Corporate / User Network                    │
                └────────────────┬──────────────────────────────┬───────────────────┘
                                 │ HTTPS                        │ HTTPS (admin)
                          ┌──────▼──────┐                ┌──────▼──────┐
                          │  F5 BIG-IP  │                │ Bastion /   │
                          │  + NGINX    │                │ Jump host   │
                          │  API GW/WAF │                └─────────────┘
                          └──────┬──────┘
                                 │  (DMZ VLAN)
         ╔═══════════════════════▼═══════════════════════════════════════════════╗
         ║   OpenShift Ingress  (HAProxy Operator) — *.apps.ocp.corp.local       ║
         ╠═══════════════════════════════════════════════════════════════════════╣
         ║  OCP cluster — 3 master VMs + 3 worker VMs on vSphere                 ║
         ║  - products-dev / products-test / products-prod namespaces            ║
         ║  - Observability ns: openshift-logging, openshift-monitoring, grafana ║
         ║  - Backup ns:        kasten-io                                        ║
         ║  - Security ns:      aqua                                             ║
         ╚═══════════════════════════════════════════════════════════════════════╝
                                 │ east-west
         ┌───────────────────────┼──────────────────────────────────────────────┐
         │                       │                                              │
    ┌────▼────┐          ┌───────▼───────┐          ┌────────┐        ┌────────┐
    │ MS SQL  │          │ Redis cluster │          │ ActiveMQ│       │ Kafka  │
    │ Pri/Sec │          │  (3 nodes)    │          │ cluster │       │Pri/Sec │
    └────┬────┘          └───────────────┘          └─────────┘       └────────┘
         │
    ┌────▼────┐
    │ RedGate │  ◄── DBA platform
    └─────────┘

         ┌──────────────────────────────────────────────────────────────────────┐
         │  DevSecOps VLAN: Jenkins, SonarQube, Checkmarx, Nexus, Aqua console, │
         │                  CyberArk Vault, ADO agent, Kasten K10 dashboard     │
         └──────────────────────────────────────────────────────────────────────┘
```

See [docs/02-network-design.md](docs/02-network-design.md) for the full VLAN/firewall matrix and [diagrams/topology.mmd](diagrams/topology.mmd) for the rendered diagram.

---

## Phase summary (see [docs/05-phase-plan.md](docs/05-phase-plan.md) for detail)

| Phase | Outcome | Key exit criteria |
|---|---|---|
| 0 — Governance | Change tickets, RBAC matrix, CMDB entries, IP plan signed off | Architecture Review Board approval |
| 1 — Network & DNS | VLANs, firewall rules, F5 VIPs, wildcard `*.apps` DNS, internal CA | Successful reachability tests across tiers |
| 2 — VMware foundation | RHCOS + RHEL templates, resource pools, affinity rules, Terraform module tested | `terraform apply` produces 6+ VMs; templates STIG-scanned |
| 3 — OCP install (UPI) | 3-master / 3-worker cluster `Available=True`, console reachable | `oc get clusteroperators` all `Available=True`, CNCF conformance pass |
| 4 — Day-2 services | Logging (EFK+Kibana), monitoring (Prom+Grafana+AM), storage (ODF/vSphere CSI), backup (Kasten K10), image registry | Dashboards green; test restore succeeds |
| 5 — Shared services | DB, Redis, MQ, Kafka, CyberArk, Nexus, Jenkins, Sonar, Checkmarx, Aqua wired up | E2E test pipeline deploys hello-world to dev |
| 6 — App onboarding | `product-platform` dev/test/prod namespaces, pipelines, secrets, TLS | CI+CD green; synthetic traffic passes SLO |
| 7 — Operate | Runbooks published, on-call rota, DR drill executed | DR RTO/RPO met; 30-day stability |

---

## How to use this repo

1. Start with [docs/01-architecture-overview.md](docs/01-architecture-overview.md) to understand the target state.
2. Use [docs/04-preinstall-checklist.md](docs/04-preinstall-checklist.md) as a gate before touching vSphere.
3. Execute phases per [docs/05-phase-plan.md](docs/05-phase-plan.md); each phase has a "definition of done".
4. Artifact skeletons under `terraform/`, `ansible/`, `openshift/` are starting points — they are **not** production-complete and must be reviewed with your security and network teams before apply.
5. Version-pin every tool from [docs/06-tools-versions.md](docs/06-tools-versions.md); do not float.

---

## Out of scope

- Public cloud DR site (planned for future phase)
- Service Mesh (Istio/OSSM) — phase 7 candidate once app count >5
- GitOps (ArgoCD) — possible replacement for Jenkins CD in a future iteration
- Zero-trust SPIFFE/SPIRE identities
