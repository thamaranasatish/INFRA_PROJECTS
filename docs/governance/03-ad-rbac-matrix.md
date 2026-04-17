# 03 — AD Group Hierarchy & RBAC Matrix

## 3.1 AD group taxonomy

All groups live under OU: `OU=Platform-Groups,OU=Groups,DC=corp,DC=local`.
Naming: `<ORG>-<SCOPE>-<ROLE>[-<ENV>]`.

### Platform-wide groups

| Group | Members | Purpose |
|---|---|---|
| `acme-platform-admins` | Platform engineers | Break-glass cluster-admin; MFA required |
| `acme-platform-ops` | Platform + SRE | Day-2 ops on cluster-wide resources |
| `acme-security-admins` | SecOps | Security operator, Aqua, compliance tooling |
| `acme-security-auditors` | InfoSec audit | Read-only everywhere (cluster + Jenkins + Nexus) |
| `acme-release-managers` | Release mgmt | Approve TEST and PROD deploys (non-developers only) |
| `acme-cab` | Change Advisory Board | Co-approve PROD deploys |
| `acme-dba` | DB administrators | Schema migrations via pipeline; restricted DB namespace access |

### Team-scoped groups (created per onboarded team)

| Group | Purpose |
|---|---|
| `acme-<team>-developers` | Write to feature branches, read on dev/test, view on prod |
| `acme-<team>-maintainers` | PR approval on `main`, manage team Jenkins folder |
| `acme-<team>-deployers-test` | Trigger deploys to TEST for owned apps |
| `acme-<team>-viewers` | Read-only across team's envs (BA, PO, support) |

### Non-person accounts (service identities)

Stored in `OU=Service-Accounts`. Named `svc-<purpose>-<scope>`. Password > 32 chars, rotated per policy, never interactive.

Examples: `svc-ado-readonly`, `svc-nexus-jenkins`, `svc-ocp-jenkins-deploy-dev`, `svc-tfe-platform`.

---

## 3.2 Jenkins roles (Role-Based Authorization Strategy plugin)

### Global roles

| Role | Permissions |
|---|---|
| `jenkins-admin` | Administer (plugin install, credentials-system, config) |
| `jenkins-read-all` | Overall/Read only |
| `jenkins-auditor` | Overall/Read + Job/Read + Credentials/View (metadata only) |

### Item (folder/job) roles

Applied with pattern-matching to folder paths.

| Role | Pattern | Permissions |
|---|---|---|
| `team-developer` | `acme/<team>/.*` | Job: Read, Build, Cancel; Workspace: Read (no Configure, no Delete) |
| `team-maintainer` | `acme/<team>/.*` | Developer + Configure, Create, Move; NO Administer |
| `release-manager-test` | `acme/<team>/test/.*` | Job: Read, Build; authorised to approve TEST `input` steps |
| `release-manager-prod` | `acme/<team>/prod/.*` | Job: Read, Build; **only** group allowed to approve PROD `input` step |
| `cab` | `acme/<team>/prod/.*` | Same as release-manager-prod; dual approval enforced at pipeline level |
| `platform-pipelines` | `acme/platform/.*` | Configure, Build — platform team only |

### AD → Jenkins mapping

Configured under **Manage Jenkins → Configure Global Security → Role-Based Strategy → Assign Roles**:

```
Global roles:
  acme-platform-admins        → jenkins-admin
  acme-security-auditors      → jenkins-auditor
  (authenticated)             → jenkins-read-all   # minimal

Item roles (pattern acme/<team>/.*):
  acme-<team>-developers      → team-developer
  acme-<team>-maintainers     → team-maintainer
  acme-release-managers       → release-manager-test, release-manager-prod
  acme-cab                    → cab
  acme-platform-admins        → platform-pipelines
```

### SoD guarantees in Jenkins

1. Developers are not in `acme-release-managers`; therefore `input` step with
   `submitter: 'acme-release-managers'` rejects their approval.
2. The prod job's `input` has `submitter: 'acme-release-managers,acme-cab'` and
   the pipeline enforces distinct approvers via a shared-library helper (see
   [07-security-baseline.md §5](07-security-baseline.md#5-sod-enforcement-points)).

---

## 3.3 OpenShift / Kubernetes RBAC

### Custom ClusterRoles (created once at platform bootstrap)

```yaml
# acme-namespace-admin — like built-in admin but cannot escalate via Secrets
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: acme-namespace-admin }
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io", "route.openshift.io"]
    resources: ["*"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get","list","watch"]        # no create/update of Secrets
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles","rolebindings"]
    verbs: ["get","list","watch"]        # cannot modify RBAC
```

```yaml
# acme-deployer — minimum needed to run helm upgrade
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: acme-deployer }
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io", "route.openshift.io"]
    resources: ["deployments","statefulsets","daemonsets","jobs","cronjobs",
                "services","routes","ingresses","configmaps","secrets",
                "serviceaccounts","persistentvolumeclaims","pods","pods/log"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get","list","watch"]
```

```yaml
# acme-auditor — read-only platform auditor
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: acme-auditor }
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get","list","watch"]
```

### RoleBindings per namespace

```yaml
# Developers: view-only in prod, edit in dev
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: view-acme-payments-developers
  namespace: payments-product-api-prod
subjects:
  - kind: Group
    name: acme-payments-developers     # matches AD group via OIDC
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: edit-acme-payments-maintainers
  namespace: payments-product-api-dev
subjects:
  - kind: Group
    name: acme-payments-maintainers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: acme-namespace-admin
  apiGroup: rbac.authorization.k8s.io
---
# Jenkins CD service account — least priv deployer
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: acme-deployer-jenkins
  namespace: payments-product-api-prod
subjects:
  - kind: ServiceAccount
    name: jenkins-deploy
    namespace: payments-product-api-prod
roleRef:
  kind: ClusterRole
  name: acme-deployer
  apiGroup: rbac.authorization.k8s.io
```

### ClusterRoleBindings (use sparingly)

| Binding | Subject | ClusterRole |
|---|---|---|
| `platform-admin-break-glass` | group `acme-platform-admins` | `cluster-admin` (MFA + audited) |
| `platform-ops` | group `acme-platform-ops` | `acme-ops` |
| `auditor` | group `acme-security-auditors` | `acme-auditor` |

---

## 3.4 Separation of Duties (SoD)

### Non-negotiables

1. **Developers must not approve PROD.** Enforced at three layers:
   - Jenkins `input` step: `submitter: 'acme-release-managers,acme-cab'`
   - Pipeline library: asserts distinct approvers (release-mgr ≠ CAB ≠ pipeline submitter)
   - AD: developers never placed in `acme-release-managers` or `acme-cab`
2. **The person who merged the PR cannot approve the PROD deploy.** Pipeline compares `CHANGE_AUTHOR` / merger against approvers and rejects self-approval.
3. **Prod credentials not available to developers.** Jenkins prod credentials are scoped to the `acme/<team>/prod` folder only; developer roles lack Credentials/View there.
4. **No direct cluster writes to prod.** Developers have `view` only in prod namespace; writes happen via Jenkins CD SA.
5. **Infrastructure changes** (Terraform) require: plan reviewed by `acme-platform-admins` AND approved by `acme-release-managers` for prod.

### Role matrix

Legend: **A**=Approve, **W**=Write, **R**=Read, **—**=None

| Action | Developer | Maintainer | Release Mgr | CAB | Platform Admin | Auditor |
|---|---|---|---|---|---|---|
| Push to feature branch | W | W | — | — | W | R |
| Merge PR to `main` | — | A+W | — | — | W | R |
| Trigger CI | W | W | W | — | W | R |
| Approve TEST deploy | — | — | A | — | A | R |
| Approve PROD deploy | — | — | A (req.) | A (req.) | A (break-glass) | R |
| Configure Jenkins pipeline | R | W (team folder) | — | — | W (anywhere) | R |
| Edit Jenkins credentials | — | — | — | — | W | R (metadata) |
| Modify RBAC on cluster | — | — | — | — | W | R |
| Modify NetworkPolicy | — | W (dev/test ns) | — | — | W | R |
| Read prod Secrets | — | — | — | — | W (audited) | — |
| View prod logs | R | R | R | R | R | R |
| Run Terraform plan | R | W (dev/test) | R | R | W | R |
| Run Terraform apply (prod) | — | — | A | — | W | R |
| Promote image in Nexus | — | — | W | — | W | R |
| Publish new Maven/npm | — | W (team hosted) | — | — | W | R |
| Onboard new package to Nexus | Request | Sponsor | Approve | — | W | R |

### Break-glass

- `acme-platform-admins` can bypass gates in declared incidents only.
- All break-glass actions logged to SIEM with ticket reference; reviewed weekly.
