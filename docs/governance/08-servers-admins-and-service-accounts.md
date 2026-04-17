# 08 — Server Naming, Admin Accounts & Service Account Catalog

Covers: **(A)** hostname / FQDN convention for every VM, **(B)** local admin + privileged account practices, **(C)** the full service-account catalog used by Jenkins pipelines, and **(D)** how those accounts are actually injected into a running pipeline.

---

## A. Server naming convention

### A.1 Hostname pattern

```
<site>-<env>-<tier>-<role><nn>.<domain>
```

| Segment | Values | Notes |
|---|---|---|
| `site` | `dc1`, `dc2`, `dr1` | Physical site / vSphere datacenter |
| `env` | `dev`, `tst`, `prd`, `mgt` | `mgt` = shared management (Jenkins, Nexus, etc.) |
| `tier` | `ocp`, `db`, `cicd`, `sec`, `obs`, `net`, `bkp` | Functional tier |
| `role` | `mst`, `wrk`, `inf`, `bas`, `jnk`, `nex`, `sql`, `tfe`, `con`, `vlt`, `efk`, `prm`, `kst` | Concrete role (3 chars) |
| `nn` | `01`–`99` | Zero-padded instance index |
| `domain` | `corp.local` | Internal DNS zone |

Rules:
- Lowercase only, hyphen-separated, **max 15 chars** before the domain (NetBIOS compatibility).
- No environment names inside other environments (no `prd` VM in `dev` VLAN).
- DNS `A` + `PTR` records mandatory; no host reachable without reverse DNS.

### A.2 Role codes

| Code | Role |
|---|---|
| `mst` | OpenShift control plane (master) |
| `wrk` | OpenShift worker |
| `inf` | OpenShift infra node (router/registry/logging) |
| `bas` | Bastion / jump host |
| `jnk` | Jenkins controller / agent host |
| `nex` | Nexus Repository |
| `sql` | SQL Server node |
| `tfe` | Terraform Enterprise |
| `con` | Consul server |
| `vlt` | CyberArk Vault component |
| `efk` | Elastic / OpenSearch |
| `prm` | Prometheus |
| `kst` | Kasten K10 |
| `rhc` | Red Hat Satellite / content mirror |
| `idm` | IdM / FreeIPA if used |

### A.3 Examples

| FQDN | Meaning |
|---|---|
| `dc1-prd-ocp-mst01.corp.local` | DC1, prod, OpenShift master #1 |
| `dc1-prd-ocp-wrk05.corp.local` | DC1, prod, worker #5 |
| `dc1-mgt-cicd-jnk01.corp.local` | Mgmt site, Jenkins controller |
| `dc1-mgt-cicd-jnk-ag01.corp.local` | Static Jenkins agent #1 (special form, 4-char role permitted for agents) |
| `dc1-mgt-cicd-nex01.corp.local` | Nexus primary |
| `dc1-mgt-cicd-tfe01.corp.local` | Terraform Enterprise |
| `dc1-prd-db-sql01.corp.local` | Prod SQL primary |
| `dc1-prd-db-sql02.corp.local` | Prod SQL secondary (AG) |
| `dc2-dr1-ocp-mst01.corp.local` | DR site master |

### A.4 Other naming that follows the same ethos

| Object | Pattern | Example |
|---|---|---|
| vSphere VM name | same as hostname (no domain) | `dc1-prd-ocp-wrk05` |
| vSphere folder | `acme/<env>/<tier>` | `acme/prd/ocp` |
| vSphere resource pool | `rp-<env>-<tier>` | `rp-prd-ocp` |
| vSphere tag category/tag | `acme:<env>`, `acme:<tier>`, `acme:owner` | `acme:env=prd` |
| F5 virtual server | `vs-<env>-<purpose>-<proto>` | `vs-prd-ocp-api-tcp6443` |
| F5 pool | `pool-<env>-<purpose>` | `pool-prd-ocp-api` |
| DNS record | matches hostname | — |
| NTP pool alias | `ntp-<site>.corp.local` | `ntp-dc1.corp.local` |
| PKI cert CN | full FQDN | `dc1-mgt-cicd-jnk01.corp.local` |
| Storage datastore | `ds-<site>-<tier>-<nn>` | `ds-dc1-ocp-01` |
| Backup job | `bkp-<env>-<tier>-<daily|weekly>` | `bkp-prd-ocp-daily` |

---

## B. Admin & privileged account practices

### B.1 Rule set (applies to every VM and every tool)

1. **No shared admin passwords.** `root`, `Administrator`, tool local `admin` are **never** used interactively.
2. **Humans log in as themselves** via AD; elevation via `sudo` (Linux) or RBAC (tools). Console logins disabled for humans except break-glass.
3. **Local built-in admin accounts are disabled or randomized.**
   - Linux `root`: password hashed with a long random string stored in CyberArk; SSH `PermitRootLogin no`; sudo for ops via AD group.
   - Windows `Administrator`: renamed, randomized 32-char password vaulted in CyberArk, disabled where possible.
   - Tool admins (Jenkins `admin`, Nexus `admin`, OCP `kubeadmin`): kept for bootstrap, then **password rotated and stored in CyberArk**, and login disabled / removed after SSO is proven.
4. **MFA** on every human login path (AD / OIDC). No MFA bypass for admins.
5. **Least privilege**: no blanket `wheel`/`Domain Admins`. Separate AD groups by tier (see `03-ad-rbac-matrix.md`).
6. **No service accounts in human roles**, no humans in service-account OUs.
7. **Password policy** (enforced in AD + CyberArk):
   - Humans: ≥14 chars, 4 of 4 complexity, history 24, max age 90 days, lockout after 5 fails / 15 min.
   - NPAs: ≥32 chars, rotated per schedule in `07-security-baseline.md §1.3`, auto-rotated by CyberArk where supported.
   - SSH keys: RSA-4096 or ED25519; passphrase-protected; stored in CyberArk; rotated 180 days.
8. **Break-glass** accounts (per tool) kept sealed in CyberArk; retrieval raises a SIEM alert + ticket; password rotated after every use.
9. **No local accounts for automation.** Automation always uses the catalog in §C.
10. **Audit every privileged action.** `sudo` logs → syslog → SIEM; tool admin audit logs forwarded.

### B.2 Linux VM baseline (OCP bastion, Jenkins hosts, Nexus, etc.)

- AD-join via SSSD (realm `CORP.LOCAL`), or vendor equivalent.
- `/etc/sudoers.d/acme-linux-admins`:
  ```
  %acme-linux-admins@corp.local ALL=(ALL) ALL
  %acme-linux-ops@corp.local ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/journalctl
  Defaults logfile=/var/log/sudo.log, log_input, log_output
  ```
- `sshd_config`:
  ```
  PermitRootLogin no
  PasswordAuthentication no
  PubkeyAuthentication yes
  AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
  AuthorizedKeysCommandUser nobody
  AllowGroups acme-linux-admins acme-linux-ops
  ```
- `root` password: 32-char random, stored in CyberArk safe `platform-linux-root`, rotated 90 days (auto).

### B.3 Tool-level admin handling

| Tool | Built-in admin | State after go-live |
|---|---|---|
| Jenkins | `admin` (created during bootstrap) | Password rotated, stored in CyberArk, used only for break-glass. Interactive login gated by AD group `acme-platform-admins` mapped to Jenkins `administer` |
| Nexus | `admin` | Same pattern; SSO via LDAP; `admin` login IP-restricted to bastion |
| OCP | `kubeadmin` | **Removed** after OIDC + `acme-platform-admins` binding is verified. Break-glass uses a sealed kubeconfig in CyberArk |
| TFE | site admin | Password in CyberArk; day-to-day uses SAML teams |
| Consul | bootstrap ACL token | Stored in CyberArk; daily ops use scoped tokens |
| CyberArk | master/admin | Governed by CyberArk's own dual-control (separate team) |
| SonarQube / Checkmarx / Aqua | local admin | SSO via AD; local admin password in CyberArk |
| vCenter | `administrator@vsphere.local` | Vaulted; day-to-day uses AD group `acme-vsphere-admins` |
| F5 | `admin` | Vaulted; TACACS/AD for humans |
| SQL Server | `sa` | Disabled / randomized; Windows-auth with AD group `acme-sqldba` |

---

## C. Service-account catalog

All accounts live under `OU=Service-Accounts,OU=Platform-Groups,DC=corp,DC=local` (or the equivalent non-AD identity store). Naming: `svc-<system>-<purpose>[-<env>]`. None has interactive logon.

### C.1 Accounts used by Jenkins (human view: credential ID in Jenkins)

| Jenkins credential ID | Identity (where) | Purpose | Used by pipeline stage | Scope / least-priv |
|---|---|---|---|---|
| `svc-ad-ldap-bind` | AD user | Jenkins LDAP bind | Controller auth (not pipeline) | Read `OU=Users`, `OU=Platform-Groups` |
| `svc-ado-readonly` | ADO PAT | Git checkout | Checkout stage | `Code (Read)` on team project |
| `svc-ado-cibot` | ADO PAT | Tag releases, write status | CI final stage | `Code (Read & Write)` on team project; `Bypass policies OFF` |
| `svc-nexus-read` | Nexus user | Resolve Maven/NPM/Docker | Build + Docker pull | `nx-read-all` on proxies/groups |
| `svc-nexus-mvn-publish-<team>` | Nexus user | `mvn deploy` | CI publish | Write on team's Maven hosted repo only |
| `svc-nexus-npm-publish-<team>` | Nexus token | `npm publish` | CI publish | Write on `@<org>-<team>` npm hosted only |
| `svc-nexus-docker-push-<team>` | Nexus user | `docker push` | CI image stage | Write on team's Docker hosted repo only |
| `svc-nexus-docker-promote` | Nexus user | Re-tag test→prod | Promotion job | Write tag on `-test-verified`/`-prod-approved` only |
| `svc-sonar-token` | Sonar token | SAST scan | CI SAST stage | Analyse on team projects only |
| `svc-checkmarx-<team>` | CxSAST token | SAST | CI SAST stage | Scan on team project |
| `svc-aqua-scanner` | Aqua token | Image scan | CI scan stage | Scan only |
| `svc-tfe-<workspace>` | TFE team token | Terraform plan/apply | IaC pipeline | Per-workspace; read+plan, apply gated |
| `svc-consul-<env>` | Consul ACL token | Terraform backend (Consul path) | IaC pipeline | `key_prefix terraform/state/<ws>` write + session write |
| `svc-ocp-deploy-<env>` | OCP SA token | `oc login` + `helm upgrade` | CD deploy stage | SA `jenkins-deploy` → ClusterRole `acme-deployer` in that namespace |
| `svc-cyberark-appid-<env>` | CyberArk AppID cert | Fetch app runtime secrets | CD prep stage | Retrieve only on safe `platform-<team>-<env>` |
| `svc-jfrog-xray-*` (if used) | Xray token | SCA | CI | Read-only scan |
| `svc-smtp-jenkins` | SMTP creds | Build notifications | Post-build | Send only |
| `svc-slack-webhook-<team>` | Webhook URL | Chat notif | Post-build | Channel-scoped |
| `svc-git-signer` | GPG private key | Sign release tags | CI release | Signing only |

### C.2 Accounts used by OpenShift (pulled via ESO/CyberArk, not Jenkins)

| OCP Secret / binding | Identity | Purpose | Scope |
|---|---|---|---|
| `nexus-registry` (dockerconfigjson) | `svc-nexus-docker-pull` | Image pulls | Read on docker proxy + hosted |
| `sa/jenkins-deploy` | namespaced SA | Target of Jenkins CD | `acme-deployer` in ns only |
| `sa/app-runtime` | namespaced SA | Workload runtime SA | Minimum roles the app actually needs |
| `sa/external-secrets` | namespaced SA | Pulls secrets from CyberArk | Talks to CyberArk CCP only |
| `sa/backup-agent` | namespaced SA | Kasten K10 | Backup/restore only |
| `sa/logging-forwarder` | cluster SA | Log forwarding | Read logs, write to EFK |

### C.3 Infrastructure / platform NPAs

| Identity | Where | Purpose |
|---|---|---|
| `svc-vsphere-tf` | vCenter | Terraform vSphere provider (VM create/destroy) |
| `svc-vsphere-backup` | vCenter | Veeam/Kasten snapshots |
| `svc-ansible-automation` | AD / SSH | Ansible plays against RHEL fleet |
| `svc-satellite-content` | Satellite | Content mirror for RHCOS/RHEL |
| `svc-dns-updater` | Infoblox/AD-DNS | Cert-manager DNS-01 + dynamic records |
| `svc-smtp-relay` | Mail gateway | Outbound notifications |
| `svc-sql-backup` | SQL Server | Scheduled backups |
| `svc-f5-automation` | BIG-IP | Programmatic VIP/pool config |
| `svc-siem-forwarder` | SIEM ingest | Log shipping |

### C.4 Allocation rules

- One account **per system × per purpose × per environment**. Never reuse across env.
- One account **per team** for publish-type rights (so revocation / offboarding is surgical).
- No account is both read and write on the same system unless the tool cannot separate.
- Every account has an **owner** (AD group) and an **expiry/review date**.
- Non-rotatable tokens (e.g. legacy webhook URLs) are declared in an exceptions register with compensating controls.

---

## D. How pipelines actually use these accounts

The Jenkinsfile **never** contains a secret. It references credential **IDs** only. Secret materialisation happens in three layers:

```
CyberArk (source of truth)
     │
     ▼
Jenkins Credentials Store (synced at controller boot via JCasC / plugin)
     │
     ▼  (only inside `withCredentials {}` scope)
Pipeline step environment (masked, short-lived)
```

### D.1 JCasC bootstrap (controller side)

Jenkins config is code. On controller start, JCasC pulls current values from CyberArk and registers them as credentials:

```yaml
# jenkins/casc/credentials.yaml (excerpt)
credentials:
  system:
    domainCredentials:
      - credentials:
          - usernamePassword:
              id: "svc-nexus-read"
              scope: GLOBAL
              username: "${cyberark:platform-shared/svc-nexus-read/username}"
              password: "${cyberark:platform-shared/svc-nexus-read/password}"
              description: "Nexus read (all resolvers). rotate-by: 2026-07-31"
      - credentials:
          - string:
              id: "svc-ocp-deploy-prod"
              scope: GLOBAL
              secret: "${cyberark:platform-ocp-prod/jenkins-deploy-token}"
              description: "OCP SA token for prod deploys. rotate-by: 2026-06-30"
```

- `${cyberark:...}` is resolved by the CyberArk / Conjur Jenkins plugin at load time.
- Credentials are **folder-scoped** for prod (put the credential block under the `acme/<team>/prod` folder config), so dev/test pipelines cannot read prod tokens.

### D.2 In the pipeline — inject, use, let it expire

The declarative pipeline only ever sees credential **IDs**:

```groovy
// Jenkinsfile.ci (excerpt)
pipeline {
  agent { kubernetes { yamlFile 'ci-agent-pod.yaml' } }

  environment {
    REGISTRY = 'nexus.corp.local:8082/docker-hosted-acme'
  }

  stages {

    stage('Checkout') {
      steps {
        // Git plugin uses credential by ID
        checkout([$class: 'GitSCM',
          branches: [[name: "*/${env.BRANCH_NAME}"]],
          userRemoteConfigs: [[
            url: 'https://dev.azure.com/acme/payments/_git/product-api',
            credentialsId: 'svc-ado-readonly'
          ]]
        ])
      }
    }

    stage('Build + publish Maven') {
      steps {
        configFileProvider([configFile(fileId: 'maven-settings', variable: 'MVN_SETTINGS')]) {
          withCredentials([
            usernamePassword(credentialsId: 'svc-nexus-read',
                             usernameVariable: 'NEXUS_USER',
                             passwordVariable: 'NEXUS_PASS'),
            usernamePassword(credentialsId: "svc-nexus-mvn-publish-payments",
                             usernameVariable: 'NEXUS_USER_PUBLISH',
                             passwordVariable: 'NEXUS_PASS_PUBLISH')
          ]) {
            sh 'mvn -B -s "$MVN_SETTINGS" clean deploy'
          }
        }
      }
    }

    stage('Build + push image') {
      steps {
        withCredentials([usernamePassword(
          credentialsId: "svc-nexus-docker-push-payments",
          usernameVariable: 'REG_USER', passwordVariable: 'REG_PASS')]) {
          sh '''
            echo "$REG_PASS" | docker login nexus.corp.local:8082 -u "$REG_USER" --password-stdin
            docker build -t $REGISTRY/product-api:${GIT_SHA} .
            docker push $REGISTRY/product-api:${GIT_SHA}
            docker logout nexus.corp.local:8082
          '''
        }
      }
    }

    stage('SAST') {
      steps {
        withCredentials([string(credentialsId: 'svc-sonar-token', variable: 'SONAR_TOKEN')]) {
          sh 'mvn -B sonar:sonar -Dsonar.login=$SONAR_TOKEN -Dsonar.host.url=https://sonar.corp.local'
        }
      }
    }
  }
}
```

Key properties:

- Secrets appear **only** inside the `withCredentials { … }` block.
- They are injected as env vars, **automatically masked** in console output.
- They never touch `environment {}` at pipeline level, never get `echo`ed, never get written to workspace files unless explicitly sanitised.
- `docker logout` and similar teardown at end of the block (or in `post { always {} }`).

### D.3 CD pipeline — prod needs a second layer

```groovy
// Jenkinsfile.cd (excerpt)
stage('Approve prod') {
  when { expression { params.ENVIRONMENT == 'prod' } }
  steps {
    script {
      def rm  = input(id: 'rm',  message: 'Release Manager approval',
                      submitter: 'acme-release-managers', submitterParameter: 'rmUser')
      def cab = input(id: 'cab', message: 'CAB approval',
                      submitter: 'acme-cab', submitterParameter: 'cabUser')
      if (rm == cab || rm == env.BUILD_USER_ID || cab == env.BUILD_USER_ID) {
        error "SoD violation: duplicate or self-approval (rm=${rm}, cab=${cab}, builder=${env.BUILD_USER_ID})"
      }
    }
  }
}

stage('Fetch runtime secrets from CyberArk') {
  steps {
    withCredentials([certificate(credentialsId: "svc-cyberark-appid-${params.ENVIRONMENT}",
                                 keystoreVariable: 'CA_PFX', passwordVariable: 'CA_PFX_PW')]) {
      sh '''
        DB_PW=$(curl -sS --cert-type P12 --cert "$CA_PFX:$CA_PFX_PW" \
          "https://cyberark.corp.local/AIMWebService/api/Accounts?AppID=jenkins-${ENV}&Safe=platform-payments-${ENV}&Object=product-api-db" \
          | jq -r .Content)
        # Write to an ephemeral file inside workspace, chmod 600, use in helm --set-file
        umask 077
        echo "$DB_PW" > "$WORKSPACE/.db.pw"
      '''
    }
  }
}

stage('Deploy') {
  steps {
    withCredentials([string(credentialsId: "svc-ocp-deploy-${params.ENVIRONMENT}", variable: 'OCP_TOKEN')]) {
      sh '''
        oc login https://api.ocp.corp.local:6443 --token="$OCP_TOKEN"
        oc project payments-product-api-${ENV}
        helm upgrade --install product-api ./helm/backend \
          -f ./helm/backend/values-${ENV}.yaml \
          --set image.tag=${IMAGE_TAG} \
          --set-file secrets.dbPassword=$WORKSPACE/.db.pw \
          --atomic --timeout 5m
      '''
    }
  }
  post {
    always {
      sh 'shred -u "$WORKSPACE/.db.pw" || rm -f "$WORKSPACE/.db.pw"'
    }
  }
}
```

### D.4 Ephemeral agents, ephemeral secrets

- Each pipeline runs on a **Kubernetes pod agent** that is destroyed at the end of the build.
- Agent images come from `docker-hosted-acme` (no public pulls).
- Because the pod is disposable, leaked material (tmp files, caches, Docker config) is gone with the pod.
- The controller never executes pipeline code directly — reduces blast radius of a malicious Jenkinsfile.

### D.5 Guardrails enforced in the shared pipeline library

`acme-jenkins-pipeline-lib` is imported by every Jenkinsfile. It wraps native Jenkins steps and enforces:

- Only allowed credential IDs per folder (pattern check).
- Mandatory `withCredentials` usage — global `environment { }` secrets rejected by lint.
- Automatic post-step `docker logout`, `oc logout`, `kdestroy`.
- Automatic audit log emit: `{buildId, credentialId, purpose, outcome}` to SIEM.
- `input` step wrapper that enforces distinct-approver SoD (example in D.3).
- Forbidden patterns: `sh "echo ${PASS}"`, `writeFile text: "${password}"`, interpolation of credentials into Groovy strings.

### D.6 Rotation without pipeline changes

Because pipelines reference IDs only:
- Rotating a secret = update CyberArk → JCasC reload on controller → next build picks up new value.
- **No pipeline edit, no commit, no re-deploy** needed for rotation.
- Emergency rotation (suspected leak): rotate in CyberArk, force JCasC reload, revoke the old token at source system — builds in flight that held the stale secret fail cleanly.

---

## E. Summary / checklist

- [ ] Every VM follows `<site>-<env>-<tier>-<role><nn>.corp.local`.
- [ ] Built-in admin accounts disabled or vaulted; no shared passwords; MFA on humans.
- [ ] Sudoers tied to AD groups; root login disabled; SSH key-only via SSSD.
- [ ] Every tool's `admin` rotated into CyberArk and used only as break-glass.
- [ ] One service account per system × purpose × env — all in `OU=Service-Accounts`.
- [ ] Jenkins holds only credential **IDs**; secret values come from CyberArk via JCasC.
- [ ] Pipelines consume secrets exclusively inside `withCredentials { }`.
- [ ] Ephemeral pod agents; shared library enforces SoD, lint, audit emission.
- [ ] Rotation is a CyberArk-side operation — pipelines need no change.
