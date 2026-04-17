# 05 — Terraform Remote State & Locking (On-Prem, No S3)

Local state is banned for any shared environment. Two approved backends below, each with **native locking**.

---

## Option 1 — **Terraform Enterprise (self-hosted)** — PREFERRED

### Why preferred

- First-class state management: versioned, encrypted at rest, access-controlled per workspace.
- Native state locking via the API; no extra component to operate.
- Run environments (remote plan/apply) give auditability and policy enforcement (Sentinel/OPA).
- SSO via AD/OIDC → maps to the same identity model.
- Backup/restore is a supported platform feature.
- Integrates cleanly with Jenkins via Team API tokens.

### State storage

- Encrypted at rest in TFE's internal object store (file-based on the TFE VM's mounted volume, backed up by Veeam/Kasten).
- State versioned automatically; prior versions retrievable via UI/API.
- Access-controlled at the workspace level via Teams.

### Locking

- Locks are **first-class** in the TFE API:
  - `POST /workspaces/:id/actions/lock`
  - A run (plan/apply) auto-locks the workspace for its duration.
  - Concurrent runs queue automatically.
- Locks survive agent crashes; TFE clears them on operator unlock or timeout.

### Setup steps

1. Procure TFE licence; size VM per HashiCorp (`~8 vCPU / 32 GB RAM` for up to 50 workspaces).
2. Install TFE (airgapped installer) on RHEL 9 VM in DevSecOps VLAN; PostgreSQL external, object store = disk (no S3).
3. Configure SAML/OIDC to AD; create teams matching AD groups:
   - `platform-admins` (owners)
   - `<team>-developers` (read)
   - `<team>-maintainers` (plan)
   - `release-managers` (apply on prod workspaces)
4. For each root module under `acme-infra-*/live/<env>/<stack>/`:
   - Create a TFE workspace named `acme-<domain>-<env>-<stack>` (see [02-naming-conventions.md §2.4](02-naming-conventions.md#24-terraform)).
   - Set execution mode: **Remote**.
   - Attach VCS: ADO repo + branch `main`.
   - Variables: inject non-secret via TFE variables; secrets via CyberArk-populated variables (value never readable).
   - Run triggers: plan on PR, apply on merge + approval for prod.
5. Issue a Team API Token per Jenkins pipeline that needs to interact; store as Jenkins credential `svc-tfe-<workspace>`.

### Backend configuration (HCL)

```hcl
# acme-infra-ocp-day2/live/prod/logging/versions.tf
terraform {
  required_version = ">= 1.9.0"
  cloud {
    hostname     = "tfe.corp.local"
    organization = "acme"
    workspaces {
      name = "acme-ocp-day2-prod-logging"
    }
  }
}
```

Jenkins pipeline (sanitised):

```groovy
environment {
  TF_CLI_CONFIG_FILE = "${WORKSPACE}/.terraformrc"
}
stages {
  stage('terraform init/plan') {
    steps {
      withCredentials([string(credentialsId: "svc-tfe-acme-ocp-day2-prod-logging", variable: 'TFE_TOKEN')]) {
        sh '''
          cat > $TF_CLI_CONFIG_FILE <<EOF
          credentials "tfe.corp.local" { token = "$TFE_TOKEN" }
          EOF
          terraform init -input=false
          terraform plan -input=false -out=tfplan
        '''
      }
    }
  }
}
```

### Operational runbook

- **Backups:** daily TFE snapshot via Kasten + weekly export of state versions via API.
- **DR:** restore snapshot to standby TFE VM; DNS cutover; re-issue tokens if needed.
- **Access control:** Teams map to AD groups (SAML claim `MemberOf`); workspace permissions follow RBAC matrix.
- **Token rotation:** Team API Tokens regenerated quarterly; old token invalidated immediately in TFE.
- **State protection:** set `Remote state sharing = explicit only`; `Terraform version = pinned`; `Execution mode = Remote` to prevent anyone running apply from a laptop.
- **Audit:** TFE audit log shipped to SIEM via syslog.

---

## Option 2 — **Consul backend (OSS, HA cluster)**

Use only when TFE is not available. Requires operating a Consul cluster.

### Why safe and standard

- Officially supported Terraform backend (`terraform { backend "consul" {} }`).
- Uses Consul sessions for distributed locking — atomic KV compare-and-swap prevents concurrent apply.
- ACL system provides least-priv per state key.
- HA via Raft (3 or 5 server nodes).

### State storage

- State stored as a single KV entry: `terraform/state/<workspace>`
- Value is the raw JSON state; encrypted at rest via Consul Enterprise (if licensed) or via VM-level disk encryption.

### Locking

- On `terraform plan/apply`, the provider:
  1. Creates a **session** in Consul tied to a node check.
  2. Tries to acquire a lock on `terraform/state/<workspace>/.lock` via `PUT?acquire=<session>`.
  3. Session TTL ensures lock is released if agent dies.
- Concurrent apply attempts fail fast with `Error: Error locking state`.

### Setup steps

1. Provision 3 Consul server VMs (RHEL 9) in the DevSecOps VLAN — 4 vCPU / 8 GB RAM each; separate disks for `data_dir`.
2. Enable:
   - TLS on 8501 (HTTPS) and 8300/8301/8302 for gossip/RPC (gossip encrypted).
   - ACLs (`acl.enabled = true`, `default_policy = "deny"`).
   - Snapshots via `consul snapshot` cronjob to NFS backup target.
3. Create policies:
   ```hcl
   # terraform-rw policy (per env)
   key_prefix "terraform/state/acme-" {
     policy = "write"
   }
   session_prefix "" {
     policy = "write"
   }
   ```
4. Issue ACL tokens per Jenkins pipeline (or per team) — one token per workspace.
5. Store token in Jenkins as `svc-consul-<workspace>` (secret text).

### Backend configuration (HCL)

```hcl
terraform {
  required_version = ">= 1.9.0"
  backend "consul" {
    address = "consul.corp.local:8501"
    scheme  = "https"
    path    = "terraform/state/acme-ocp-day2-prod-logging"
    lock    = true
    gzip    = true
    # CA cert shipped to agent image
    ca_file = "/etc/pki/tls/certs/corp-ca.pem"
  }
}
```

Jenkins pipeline excerpt:

```groovy
withCredentials([string(credentialsId: 'svc-consul-acme-ocp-day2-prod-logging', variable: 'CONSUL_HTTP_TOKEN')]) {
  sh '''
    export CONSUL_HTTP_TOKEN
    terraform init -input=false
    terraform plan -input=false -out=tfplan
  '''
}
```

### Operational runbook

- **Backups:** `consul snapshot save` hourly to backup target; retain 30 days.
- **DR:** rebuild 3-node cluster, `consul snapshot restore` from latest; validate KV size.
- **Access control:** one ACL token per workspace; tokens stored in CyberArk; rotated quarterly.
- **Lock recovery (operator):**
  - List sessions: `consul kv get -detailed terraform/state/<ws>/.lock`
  - Force release on confirmed dead session: `consul kv delete terraform/state/<ws>/.lock` (requires ACL token with `key_prefix "terraform/state/"` write).
  - **Action only after paging the owning team** — releasing a live lock corrupts state.
- **State migration** (Consul → TFE later): `terraform state pull` → reconfigure backend → `terraform init -migrate-state`.

---

## Decision: which to choose

| Criterion | TFE self-hosted | Consul |
|---|---|---|
| Licence cost | Paid | Free (OSS) |
| Operational overhead | Low (managed by vendor) | Medium (operate Consul cluster) |
| Built-in policy/compliance (Sentinel/OPA) | ✅ | ❌ (bolt-on needed) |
| Remote execution environments | ✅ | ❌ (still run from Jenkins) |
| Native SSO | ✅ | Partial (via Vault, extra work) |
| Audit log | Built-in | Via ACL events + SIEM ingestion |

**Default recommendation:** start with **Consul** if there's no TFE procurement in flight; plan migration to **TFE** when infra team scales beyond ~20 workspaces or when Sentinel/OPA policy-as-code becomes required.

---

## Explicitly rejected options

- **Local backend (`terraform.tfstate` on disk)** — no locking, corruption risk, not acceptable for shared envs.
- **HTTP backend to a generic file server** — no atomic locking semantics.
- **Public cloud S3** — explicitly excluded by constraints.
- **PostgreSQL backend without advisory-lock discipline** — possible but operationally fragile; Consul is a better OSS choice.
