# 02 — Naming Conventions Standard

All names are **lowercase, hyphen-separated, no underscores, no camelCase**, ASCII only, ≤ 63 chars (DNS-compatible).
Teams must comply before onboarding; violations are blocked by linters + admission policy.

General pattern: `<ORG>-<TEAM>-<APP>-<COMPONENT>-<ENV>-<QUALIFIER>`
Not all tools need every segment; each section below defines which.

---

## 2.1 Git repositories (ADO Repos)

| Repo type | Pattern | Example |
|---|---|---|
| Application code | `<org>-<team>-<app>` | `acme-payments-product-api` |
| Shared library | `<org>-<team>-lib-<name>` | `acme-payments-lib-auth` |
| Deploy/Helm | `<org>-<team>-<app>-deploy` | `acme-payments-product-api-deploy` |
| IaC (terraform) | `<org>-infra-<domain>` | `acme-infra-vsphere`, `acme-infra-ocp-day2` |
| Platform pipelines | `<org>-platform-<purpose>` | `acme-platform-jenkins-shared-library` |

### Branching strategy (trunk-based with short-lived feature branches)

```
main              protected, always deployable to dev after CI
feature/<APP>-<ticket>-<short-desc>      ex: feature/product-api-1234-add-audit
hotfix/<APP>-<ticket>-<short-desc>       ex: hotfix/product-api-9999-npe-fix
release/<VERSION>                        (optional, for LTS branches)
```

Protected-branch rules on `main`:
- PR required, ≥1 reviewer from `<ORG>-<TEAM>-maintainers` AD group.
- Required status checks: CI pipeline green, SAST quality gate pass, secret-scan pass.
- No direct push, no force-push, no branch deletion.

### Tags & releases

```
<app>-v<MAJOR>.<MINOR>.<PATCH>            ex: product-api-v1.4.2
<app>-v<MAJOR>.<MINOR>.<PATCH>-rc.<N>     ex: product-api-v1.4.2-rc.1
```

Tags are created by CI only, never manually.

---

## 2.2 Jenkins

### Folders (matches AD group scoping)

```
/<org>/
  /platform/                  ← platform team pipelines
  /<team>/
    /dev/
    /test/
    /prod/
    /shared/                  ← team-wide utilities
```

### Job / pipeline names

| Type | Pattern | Example |
|---|---|---|
| CI | `<org>/<team>/<app>-<component>-ci` | `acme/payments/product-api-backend-ci` |
| CD | `<org>/<team>/<app>-cd` | `acme/payments/product-api-cd` |
| IaC | `<org>/platform/infra-<domain>-<action>` | `acme/platform/infra-ocp-day2-apply` |
| Utility | `<org>/<team>/util-<purpose>` | `acme/payments/util-rotate-db-creds` |

Build number is Jenkins native `#<N>`. Display name override:
```
#${BUILD_NUMBER}-${GIT_COMMIT_SHORT}${ROLLBACK?'-ROLLBACK':''}
```
Example display: `#427-a1b2c3d4e5f6`.

### Jenkins credentials IDs

Pattern: `<scope>-<system>-<purpose>-<env?>`

| Purpose | Credential ID |
|---|---|
| Git checkout (ADO PAT) | `svc-ado-readonly` |
| Nexus read | `svc-nexus-read` |
| Nexus publish (Maven hosted) | `svc-nexus-mvn-publish-<team>` |
| Nexus publish (npm hosted) | `svc-nexus-npm-publish-<team>` |
| Docker push to Nexus | `svc-nexus-docker-push-<team>` |
| OCP deploy SA token | `svc-ocp-deploy-<env>` |
| CyberArk app auth | `svc-cyberark-<appid>` |
| Sonar token | `svc-sonar-token` |
| Checkmarx creds | `svc-checkmarx-<team>` |
| Aqua creds | `svc-aqua-scanner` |
| Terraform state token (TFE) | `svc-tfe-<workspace>` |
| Terraform Consul token | `svc-consul-<env>` |

Rule: **no human names in credential IDs**. Only service-account identities.

---

## 2.3 Kubernetes / OpenShift

### Namespaces

Pattern: `<team>-<app>-<env>` (keep short — 63-char limit for DNS).

| Example | Meaning |
|---|---|
| `payments-product-api-dev` | Team "payments", app "product-api", dev |
| `payments-product-api-test` | … test |
| `payments-product-api-prod` | … prod |
| `platform-monitoring` | Platform-owned (no env suffix for shared) |
| `security-aqua` | Security team owned |

### Service accounts

Pattern: `<purpose>-<scope>`

| Example | Use |
|---|---|
| `app-runtime` | Default SA for the app workload pods |
| `jenkins-deploy` | Jenkins CD deploys into this namespace using this SA's token |
| `external-secrets` | Used by ESO to pull from CyberArk |
| `backup-agent` | Used by Kasten |

### Roles / ClusterRoles

Pattern: `<org>-<purpose>` for custom ClusterRoles; prefer built-ins (`view`, `edit`, `admin`) where possible.

| Name | Scope | Use |
|---|---|---|
| `acme-namespace-admin` | Namespaced | Same as `admin` but excludes Secret read and RoleBinding create |
| `acme-deployer` | Namespaced | `get/list/watch/patch/update` on workloads; no delete-namespace |
| `acme-ops` | ClusterRole | Read everything + exec into pods (used by SRE) |
| `acme-auditor` | ClusterRole | `get/list/watch` on everything incl. events & audit sources |
| `acme-security-readonly` | ClusterRole | Read all + Aqua/Compliance CRs |

### RoleBindings

Pattern: `<role>-<group-or-sa>` within the namespace.

| Example |
|---|
| `view-<org>-<team>-developers` → binds ClusterRole `view` to AD group |
| `edit-<org>-<team>-maintainers` |
| `acme-deployer-jenkins-deploy` (SA) |

### Helm

Release name pattern: `<app>-<component>` (env comes from namespace, not release name).

| Example |
|---|
| `product-api-backend` in `payments-product-api-prod` |
| `product-api-frontend` in `payments-product-api-prod` |

Values files (see `java_project/helm/...`):
```
values.yaml                    ← chart defaults
values-dev.yaml
values-test.yaml
values-prod.yaml
```

---

## 2.4 Terraform

### Repos / modules

```
<org>-infra-<domain>/
  ├── modules/
  │    └── <resource-type>/        ← reusable modules
  │           main.tf  variables.tf  outputs.tf  README.md
  └── live/
       └── <env>/<stack>/          ← root modules (one state per dir)
              main.tf  backend.tf  versions.tf
```

Examples:
```
acme-infra-vsphere/live/prod/ocp-cluster/
acme-infra-ocp-day2/live/prod/logging/
```

### Workspace / state naming

Pattern: `<org>-<domain>-<env>-<stack>`

| Example |
|---|
| `acme-vsphere-prod-ocp-cluster` |
| `acme-ocp-day2-prod-logging` |
| `acme-network-test-f5-vips` |

Used as:
- TFE workspace name, or
- Consul KV path: `terraform/state/<workspace>`

### Variables

- `snake_case` (matches HCL convention).
- Booleans: `enable_<feature>`.
- Sensitive vars marked `sensitive = true`; never logged.

### Resource names in HCL

```hcl
resource "aws_instance" "<role>_<index>" { ... }     # e.g. "worker_0"
```

### Tags on every resource

```hcl
tags = {
  org     = "acme"
  team    = var.team
  app     = var.app
  env     = var.env
  owner   = var.owner_email
  managed = "terraform"
  repo    = var.repo_url
  cost    = var.cost_center
}
```

---

## 2.5 Artifacts

### Maven

| Kind | Pattern | Example |
|---|---|---|
| `groupId` | `com.<org>.<team>` | `com.acme.payments` |
| `artifactId` | `<app>-<component>` | `product-api-backend` |
| `version` | `<MAJOR>.<MINOR>.<PATCH>[-<QUALIFIER>]` | `1.4.2`, `1.4.3-SNAPSHOT` |
| File output | `<artifactId>-<version>.jar` | `product-api-backend-1.4.2.jar` |

### NPM

| | |
|---|---|
| Scope | `@<org>-<team>` |
| Package | `@acme-payments/product-ui` |
| Version | semver |

### Docker images

Pattern: `<nexus-host>/<org>-<tier>/<app>-<component>:<tag>`

Tag strategy:
- Built by CI: `<SHA>` (immutable, 12-char git short SHA) — **always required**
- Also tag: `<VERSION>` on tag builds — e.g. `1.4.2`
- Promotion tiers (optional but recommended): tag the same digest as
  - `<SHA>-dev-verified`
  - `<SHA>-test-verified`
  - `<SHA>-prod-approved`

Never use `:latest` in test or prod manifests.

Examples:
```
nexus.corp.local:8082/acme-hosted/product-api-backend:a1b2c3d4e5f6
nexus.corp.local:8082/acme-hosted/product-api-backend:1.4.2
nexus.corp.local:8082/acme-hosted/product-ui-frontend:a1b2c3d4e5f6
```

### Helm charts

| | Pattern | Example |
|---|---|---|
| Chart name | `<app>-<component>` | `product-api-backend` |
| Chart version | semver, independent of app version | `0.3.1` |
| appVersion | matches image VERSION | `1.4.2` |
| Published to | Nexus Helm hosted repo `acme-helm-hosted` | |

---

## 2.6 Environments

Never deviate from these codes: `dev`, `test`, `prod`.
No `stage`, `staging`, `uat`, `preprod` aliases inside this platform.
