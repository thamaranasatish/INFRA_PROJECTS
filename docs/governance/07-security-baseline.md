# 07 — Security Baseline

Spans credentials, audit, and SoD enforcement for Jenkins + OCP + Nexus + Terraform + AD.

---

## 1. Credential management

### 1.1 Where secrets live

| Secret class | System of record | Consumer | Delivery |
|---|---|---|---|
| Human passwords | Active Directory | Humans | Kerberos/LDAP/OIDC |
| Service account creds (infra glue) | **CyberArk** | Jenkins, Nexus, OCP | Jenkins Credentials Binding plugin fetches from CyberArk at build-time (CCP/Conjur); OCP via External Secrets Operator |
| App runtime secrets (DB pw, API keys) | **CyberArk** | Pods | External Secrets Operator → K8s Secret (refresh on interval) |
| TLS certs for workloads | cert-manager + internal CA | Pods (Routes/Ingress) | cert-manager issues; stored as K8s Secret |
| Terraform state backend token | CyberArk | Jenkins | Injected as env var at build-time only |
| Jenkins system config (admin pw, agent token) | CyberArk | Jenkins controller | Bootstrap via JCasC pulling from CyberArk |

**Forbidden:** plaintext secrets in Git, in Jenkins environment variables (the job script), in Helm values committed to VCS, in Dockerfiles, in `.env` files.

### 1.2 Jenkins credentials discipline

- **Scope:** every credential is defined at the **folder** level, not global, except shared read-only infra creds (`svc-ad-ldap-bind`, `svc-nexus-read`).
- Prod credentials live only in `acme/<team>/prod` folder; developer roles have no `Credentials/View` there.
- **Type:** prefer `Secret text` (tokens) over `Username/password`; avoid `Secret file` unless required.
- **Masking:** always use `withCredentials {}`; never `echo $PASS`.
- **Expiry annotation:** credential `description` field carries rotation date: `rotate-by: 2026-01-31`.
- **JCasC:** Jenkins config is code; credentials referenced by ID, values injected from CyberArk at controller boot.

### 1.3 Rotation policy

| Secret | Frequency | Trigger outside schedule |
|---|---|---|
| AD svc account passwords | 90 days | On group change or incident |
| Jenkins → OCP ServiceAccount tokens | 90 days | Namespace ownership change |
| Nexus publish tokens | 180 days | Team reorg, leaver |
| Terraform backend tokens (TFE team / Consul ACL) | 90 days | Pipeline reassignment |
| CyberArk APPID certs | 365 days | Jenkins rebuild |
| Docker registry pull secrets | 180 days | Compromise suspicion |
| Internal CA-issued certs | 365 days (cert-manager auto) | CA compromise |
| Break-glass `kubeadmin` (if retained) | 30 days + after each use | Always after use |

Rotations are scheduled in CyberArk where possible (auto-rotation for AD + DB). Non-auto-rotatable tokens are tracked on a calendar owned by Platform Admins.

### 1.4 Least privilege checklist (applied at every credential issuance)

- One identity per function (no "shared" svc accounts across teams/envs).
- Scope to single repo/namespace/workspace where the platform allows.
- Read vs write split (e.g. `svc-nexus-read` ≠ `svc-nexus-mvn-publish-<team>`).
- Env-scoped (`-dev`, `-test`, `-prod` suffix) for any credential that grants cluster or data access.
- IP / source-restricted where the system supports it (CyberArk, Nexus, TFE).
- MFA for interactive humans; disabled interactive login for service accounts.

---

## 2. Audit & logging

### 2.1 Logging expectations (by component)

| Component | What is logged | Where it goes | Retention |
|---|---|---|---|
| **AD / ADFS** | Logons, group changes, svc account usage | SIEM via Windows Event Forwarding | 1 year hot, 7 yrs archive |
| **Jenkins** | Login, job build start/finish, config change, credentials view, `input` submitter, pipeline console (sanitised) | Audit Trail plugin → syslog → SIEM; build logs retained on Jenkins per job policy | 90 days hot on Jenkins; 1 yr in SIEM |
| **OpenShift** | API audit log (RequestResponse level for RBAC/Secret/Pod exec), events, Router access logs | Forwarded via ClusterLogForwarder → EFK + SIEM | 90 days hot, 1 yr archive |
| **Nexus** | Login, repo access (incl. deploys), admin changes, new user/role | syslog → SIEM | 1 yr |
| **Terraform (TFE/Consul)** | TFE audit log; Consul ACL events; run/apply history | syslog → SIEM | 1 yr |
| **CyberArk** | Every secret retrieval with requester, app id, source IP, object | Native → SIEM | 7 yrs |
| **Aqua / Sonar / Checkmarx** | Scan results + admin changes | Tool UI + export to SIEM | 1 yr |

### 2.2 Minimum events alerted on

- Unauthorised prod deploy attempt (pipeline aborted due to non-matching approver).
- Use of break-glass account (`acme-platform-admins` cluster-admin binding).
- CyberArk secret retrieval from non-approved source IP.
- Nexus repository admin change, or proxy upstream URL change.
- AD group `acme-release-managers` / `acme-cab` membership change.
- Jenkins `Administer` permission granted to a new principal.
- Terraform apply to prod workspace.
- Image pushed to `docker-hosted-acme-prod` outside a CI pipeline.
- Failed LDAP binds > threshold (brute-force).
- OCP SA token issued outside automation.

### 2.3 Audit trail integrity

- SIEM collectors are append-only (WORM where available).
- Clock sync: NTP enforced across all components; drift > 5 s alerts.
- Log forwarding uses TLS; collectors authenticated.
- Audit logs reviewed: automated SIEM rules continuously; human spot-check monthly by `acme-security-auditors`.

---

## 3. SoD enforcement points

These are the concrete technical controls. Policy alone is not sufficient.

### 3.1 Source control (ADO / Git)

- `main` branch policies:
  - Require PR.
  - Minimum reviewers: **2**, at least one from `acme-<team>-maintainers`.
  - PR author cannot approve their own PR.
  - Required status check: `jenkins/ci` green.
  - Linear history enforced; force-push disabled.
  - Commit signing required (GPG or Azure DevOps signing).
- Service account `svc-ado-cibot` has `Bypass policies = OFF`.

### 3.2 CI/CD pipelines

- **CI** stage runs SAST + image scan; quality-gate failure blocks artifact publish.
- **CD** to prod requires `input` with `submitter: 'acme-release-managers,acme-cab'`.
- Shared pipeline library enforces:
  - Merger identity ≠ approver identity.
  - Release Manager approver ≠ CAB approver (dual approval).
  - Build-once-deploy-many: prod must deploy the **exact digest** that passed test; pipeline asserts the image's `sha256:` in test equals prod before applying.
- Jenkins folder ACLs prevent developers from editing prod pipelines.

### 3.3 Container registry

- Nexus role split:
  - CI push to `docker-hosted-acme` allowed.
  - Only promotion jobs (running under `svc-nexus-docker-promote`) can tag `-test-verified` / `-prod-approved`.
  - Developers cannot push directly.

### 3.4 Cluster (OCP)

- Developers: `view` in prod namespace; no `edit`/`admin`.
- Jenkins CD SA: `acme-deployer` role (no RBAC mutation, no namespace deletion).
- `NetworkPolicy` mutations in prod ns require `acme-platform-admins`.
- PodSecurity (SCC) enforced: no privileged, no hostPath, no root unless explicitly approved.
- Admission webhooks (Kyverno/Gatekeeper) block:
  - Images not from `nexus.corp.local:8082/docker-hosted-acme*`.
  - `latest` tag.
  - Missing `resources.requests/limits`.
  - Missing liveness/readiness on workloads.

### 3.5 Infrastructure (Terraform)

- Prod workspaces (`*-prod-*`):
  - Execution mode remote only.
  - `apply` requires approval from `acme-release-managers` team in TFE (or gated Jenkins job for Consul path).
  - Sentinel/OPA policy (when TFE) enforces:
    - No public IP on vSphere networks outside DMZ.
    - Mandatory tags (`owner`, `cost-center`, `env`).
    - Version pinning on modules.
- State cannot be modified manually: humans have read-only access to state UI; write paths are pipeline-only.

### 3.6 Nexus

- Role "admin" restricted to `acme-platform-admins`.
- Content selector enforces `acme-<team>-maintainers` can publish only under `com.acme.<team>` / `@acme-<team>/*`.
- Onboarding of a new proxy upstream requires Platform Admin + SecOps dual sign-off.

### 3.7 AD

- `acme-release-managers` and `acme-cab` memberships:
  - Changes require ticket + manager approval.
  - Any add/remove alerted to SIEM + sent to InfoSec.
  - Developers cannot be members of either.
- Nested group restrictions: service account OU cannot be a member of human role groups.

### 3.8 Break-glass

- One time-boxed `cluster-admin` kubeconfig retained in CyberArk, sealed.
- Retrieval logs a high-priority SIEM event + pages the on-call Platform Admin + opens an incident ticket.
- Post-incident review required within 5 business days.

---

## 4. Platform-level controls (summary checklist)

- [ ] All tools integrated with AD for humans (no local accounts used interactively).
- [ ] All automation uses dedicated NPAs (`svc-*`) with scoped permissions.
- [ ] All secrets resolved from CyberArk at runtime; none in Git or Jenkins stored-plaintext.
- [ ] All outbound package traffic flows via Nexus; egress firewall blocks public registries from agents/cluster.
- [ ] All prod approvals require two humans from different AD groups; pipeline enforces distinct identities.
- [ ] Terraform state is remote + locked; local state blocked by policy + CI linting.
- [ ] Audit logs from every component forwarded to SIEM with ≥ 1 year retention.
- [ ] Rotation schedule documented per credential class; calendared and owned.
- [ ] RBAC matrix ([03-ad-rbac-matrix.md](03-ad-rbac-matrix.md)) implemented and reviewed quarterly.
- [ ] Admission policies (Kyverno/Gatekeeper) deny non-compliant workloads.
- [ ] Break-glass paths documented, logged, and reviewed after every use.
