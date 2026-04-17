# 01 — Architecture & Integration Narrative

## 1.1 Components

| Component | Role |
|---|---|
| **Active Directory** | Authoritative identity + group store. LDAPS on 636. OIDC via ADFS/Entra where supported. |
| **Azure DevOps Repos (Git)** | Source of truth for app + IaC code. Protected branches, required reviewers, webhooks. |
| **Jenkins LTS** | CI/CD orchestrator. Matrix-auth authorization. Declarative pipelines. Jenkins Kubernetes plugin runs ephemeral agents on OCP. |
| **Nexus Repository Pro** | The only egress point for Maven, NPM, Docker, Helm, raw artifacts. Proxy + Hosted + Group repos. |
| **Terraform** | IaC for VMware, OCP Day-2, app-adjacent infra. State in **TFE self-hosted** (preferred) or **Consul** (OSS fallback). |
| **OpenShift (OCP)** | Runtime for workloads. RBAC backed by AD groups via OIDC. NetworkPolicy + SCC + Aqua admission. |
| **CyberArk** | Secrets vault for humans + automation. Jenkins fetches via CCP or Credentials Provider plugin. |

## 1.2 End-to-end developer-to-prod flow

```
Developer          AD/ADO             Jenkins (CI)                 Nexus              Jenkins (CD)           OpenShift
─────────          ──────             ────────────                 ─────              ────────────           ─────────
git push  ──► ADO Repos (protected)
                     │ webhook
                     ▼
              Jenkins CI job "<APP>-<COMPONENT>/ci"
                     │  checkout  ──► git creds (AD svc account)
                     │  build     ──► Maven/NPM resolve through Nexus group
                     │  SAST      ──► SonarQube + Quality Gate
                     │  image     ──► tag <IMAGE>:<SHA>
                     │  scan      ──► Aqua
                     │  push      ──► Nexus docker-hosted
                     ▼
              triggers CD with IMAGE_TAG=<SHA>, ENV=dev
                                                                            Jenkins CD job "<APP>/cd"
                                                                                   │ fetch creds  ◄── CyberArk
                                                                                   │ helm upgrade --atomic
                                                                                   ▼
                                                                            products-dev namespace
                                                                                   │ (smoke OK)
                                                                                   ▼
              Release Manager triggers CD with ENV=test (human action)
                                                                            products-test namespace
                                                                                   │ (UAT sign-off)
                                                                                   ▼
              CAB + Release Manager approve PROD gate (Jenkins input step)
              Developer has NO approval rights in prod job
                                                                            products-prod namespace
                                                                                   │ (atomic, auto-rollback on failure)
                                                                                   ▼
                                                                            smoke + synthetic tests
```

Key properties:
- **Build once, deploy many.** The image produced in CI is promoted byte-identical through dev → test → prod.
- **No developer writes to prod.** Prod pipeline requires approval from `<ORG>-release-managers` AD group; developers in that job get 403 on the input step.
- **All egress through Nexus.** Build agents and OCP nodes have no direct internet access for package/image pulls.

## 1.3 Where each integration boundary lives

| Boundary | Protocol / Port | Authenticated as | Authorized by |
|---|---|---|---|
| Human → Jenkins UI | HTTPS/443 | AD user (LDAPS bind) | Jenkins matrix-auth + role-based-auth plugin reading AD groups |
| Human → OCP console | HTTPS/6443 | AD user via OIDC | OCP RBAC bound to AD groups |
| Jenkins → Git (ADO) | HTTPS/443 | AD service account (PAT in Jenkins creds) | ADO repo permissions: Read/Contribute |
| Jenkins → Nexus | HTTPS/8443 | `svc-jenkins-ci` (NPA) | Nexus role: read on all groups, deploy on hosted per team |
| Jenkins → OCP | HTTPS/6443 | ServiceAccount token per env | OCP RoleBinding on target namespace only |
| Jenkins → Terraform state | HTTPS | Token (TFE team token) or Consul ACL token | State-level RBAC |
| Jenkins → CyberArk | HTTPS/443 | App identity (CCP) | Safe-level ACL |
| OCP → Nexus (image pull) | HTTPS/8082 | `svc-ocp-nexus-pull` | Nexus role: read on docker-group |
| OCP → CyberArk | HTTPS/443 | External Secrets Operator identity | Safe-level ACL |
| Nexus → Public registries | HTTPS via corporate egress proxy | Proxy whitelist | Network/firewall + approved upstream list |

## 1.4 Trust model

1. **AD is authoritative.** Every human permission derives from AD group membership.
2. **Tools don't issue permissions directly** — they map AD groups to their internal roles.
3. **Service accounts are not humans.** NPA (non-person accounts) are vaulted, short-lived where possible, and scoped to a single purpose.
4. **Public internet is not trusted.** Only Nexus proxies reach public registries (and only for approved upstreams).

## 1.5 Environment isolation

| Aspect | DEV | TEST | PROD |
|---|---|---|---|
| OCP namespace | `<app>-dev` | `<app>-test` | `<app>-prod` |
| Jenkins folder | `<team>/dev` | `<team>/test` | `<team>/prod` |
| Nexus docker repo tier | `<app>-dev` | `<app>-test` (promoted) | `<app>-prod` (promoted) |
| Approval required | None (on CI success) | Release Manager | Release Manager **+** CAB |
| Deployer SA | `jenkins-deploy-dev` | `jenkins-deploy-test` | `jenkins-deploy-prod` |
| AD approval group | — | `<ORG>-release-managers` | `<ORG>-release-managers` + `<ORG>-cab` |

## 1.6 Promotion model (GitOps-like)

- Source code lives in `<app>-app` repo (application).
- Deploy manifests (Helm values per env) live in `<app>-deploy` repo (or `deploy/` folder with protected `main` branch).
- CI publishes image + Helm chart to Nexus; CD reads from Nexus.
- `test` and `prod` promotion = re-run CD with the already-built `IMAGE_TAG`. No rebuild, no new code path.
- Optional future step: replace Jenkins CD with ArgoCD watching the deploy repo.
