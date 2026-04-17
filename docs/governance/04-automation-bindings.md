# 04 — Automation Bindings (Connection 1..N)

Each binding: **what connects**, **plugins/tools**, **credentials**, **least-priv permissions**, **setup steps**.

---

## Connection 1 — AD ↔ Jenkins (authentication + authorization)

**What:** Jenkins authenticates users against AD (LDAPS). Authorization uses AD group membership mapped to Jenkins roles.

**Plugins:**
- `ldap` (for LDAPS authentication), **or** `oic-auth` (OIDC via ADFS/Entra ID — preferred if available)
- `role-based-authorization-strategy`
- `matrix-auth` (fallback for very fine-grained item perms)

**Credentials in Jenkins:**
- `svc-ad-ldap-bind` — username/password of the LDAP bind account (read-only on user/group OUs)

**Minimum AD permissions:**
- `svc-ad-ldap-bind` needs: `Read` on `OU=Users` and `OU=Platform-Groups`; **no write**.

**Setup steps:**
1. Create AD svc account `svc-ad-ldap-bind`; password vaulted in CyberArk.
2. Manage Jenkins → Security → Security Realm → **LDAP** (or OIDC):
   - Server: `ldaps://dc1.corp.local:636 ldaps://dc2.corp.local:636`
   - Root DN: `DC=corp,DC=local`
   - User search base: `OU=Users`
   - User search filter: `sAMAccountName={0}`
   - Group search base: `OU=Platform-Groups`
   - Group search filter: `(&(objectclass=group)(member={0}))`
   - Manager DN: `CN=svc-ad-ldap-bind,OU=Service-Accounts,DC=corp,DC=local`
   - Manager password: from credential `svc-ad-ldap-bind`
   - **TLS verification enabled**, internal CA bundled in JVM truststore.
3. Authorization → **Role-Based Strategy** → map AD groups to roles per [03-ad-rbac-matrix.md §2](03-ad-rbac-matrix.md#32-jenkins-roles).
4. Disable local user sign-up.
5. Verify: login as member of `acme-payments-developers`, confirm only `acme/payments/**` jobs are visible.

---

## Connection 2 — AD ↔ OpenShift (OIDC SSO)

**What:** OCP authenticates humans via OIDC to ADFS/Entra ID; group claims drive RBAC.

**Tools:**
- OCP OAuth configured with `OpenID` IDP
- AD group claim mapped to OCP groups

**Credentials:**
- Application registration in Entra ID / ADFS trust: Client ID + Client Secret (stored in OCP `Secret` in `openshift-config`)

**Minimum permissions:**
- App registration: `openid`, `profile`, `email`, `groups` claims — no graph-API write.

**Setup steps:**
1. Register OIDC application in ADFS/Entra: redirect URI `https://<oauth-ocp-console>/oauth2callback/<idp-name>`.
2. Configure group claim (`groups`), emit only groups under `OU=Platform-Groups`.
3. `oc create secret generic oidc-client-secret --from-literal=clientSecret=... -n openshift-config`
4. Patch `OAuth/cluster` with the `OpenID` identityProvider.
5. Remove `kubeadmin` after testing SSO login.
6. Apply RoleBindings/ClusterRoleBindings per [03-ad-rbac-matrix.md §3.3](03-ad-rbac-matrix.md#33-openshift--kubernetes-rbac).

---

## Connection 3 — Jenkins ↔ Git (ADO Repos)

**What:** Jenkins checks out source + listens to webhooks from ADO.

**Plugins:** `git`, `azure-devops` (for PR builder), `workflow-multibranch`

**Credentials in Jenkins:**
- `svc-ado-readonly` — **PAT** for `svc-ado-readonly` account, scopes: `Code (Read)`, `Code (Status)` for status reporting; **no write scope**.
- For CI that needs to push tags: `svc-ado-cibot` with `Code (Read & Write)` — used **only** in CI final stage for tagging releases.

**Minimum ADO permissions:**
- `svc-ado-readonly`: Reader on the repo.
- `svc-ado-cibot`: Contributor with `Bypass policies when pushing: OFF`. Tags created by script.

**Setup steps:**
1. Register ADO webhook → Jenkins URL `/generic-webhook-trigger/invoke?token=...` or use ADO's built-in Jenkins service hook.
2. Multibranch pipeline `<app>-ci` defines sources from `https://dev.azure.com/<org>/<project>/_git/<app>`.
3. Use `checkout scm` with credential `svc-ado-readonly`.
4. Required status check in ADO repo policy: `jenkins/ci` — prevents merging red builds.

---

## Connection 4 — Jenkins ↔ Nexus (read + publish)

**What:** Jenkins resolves Maven/NPM/Docker artifacts through Nexus; publishes build outputs to Nexus hosted repos.

**Plugins:**
- Declarative uses `withCredentials` + CLI tools (`mvn`, `npm`, `docker`) — no special Nexus plugin required.
- Optional: `nexus-artifact-uploader` (rarely needed).

**Credentials in Jenkins:**
| ID | Type | Used by |
|---|---|---|
| `svc-nexus-read` | username/password | Resolve through `maven-group` / `npm-group` / `docker-proxy` |
| `svc-nexus-mvn-publish-<team>` | username/password | `mvn deploy` to `maven-releases` or `maven-snapshots` |
| `svc-nexus-npm-publish-<team>` | secret text (npm auth token) | `npm publish` to `npm-hosted-<team>` |
| `svc-nexus-docker-push-<team>` | username/password | `docker login` + `docker push` to `docker-hosted-<team>` |

**Least-priv in Nexus:**
- `svc-nexus-read`: role `nx-read-all` (read on every group/proxy). No write.
- `svc-nexus-mvn-publish-payments`: only `nx-repository-view-maven2-maven-releases-acme-payments-*` (add/edit), nothing else.
- Same pattern for npm and docker hosted repos — per-team scoping.

**Setup steps:**
1. Create roles in Nexus matching the credentials above.
2. Create users (realm: LDAP or local); link to roles.
3. Store user/password in Jenkins credential store (the IDs above).
4. In pipelines, inject via `withCredentials` and use Maven's `settings.xml` or `~/.npmrc` generated at runtime (see [06-nexus-governance.md](06-nexus-governance.md)).

---

## Connection 5 — Jenkins ↔ Terraform backend

**What:** Terraform reads/writes state and acquires locks during plan/apply.

**Tools:**
- Terraform CLI (pinned version)
- TFE (preferred) **or** Consul backend (OSS)

**Credentials in Jenkins:**
- **TFE path:** `svc-tfe-<workspace>` — secret text, a TFE Team Token scoped to the workspace (read+plan+apply). Supplied via `TF_TOKEN_<HOST>` env var.
- **Consul path:** `svc-consul-<env>` — secret text (Consul ACL token) with `key_prefix "terraform/state/"` `read+write` and `session "*"` `write` (for locking); nothing else.

**Least-priv:**
- One token per state / workspace. No shared "super token".
- Separate tokens for `plan` and `apply` if possible; otherwise separate pipelines.

**Setup steps:** see [05-terraform-state-onprem.md](05-terraform-state-onprem.md).

---

## Connection 6 — Jenkins ↔ OpenShift (deploy)

**What:** Jenkins CD authenticates to OCP API and runs `helm upgrade --atomic`.

**Plugins / tools:**
- `openshift-client` plugin or straight `oc` + `helm` CLI in the agent image
- Agent image preloaded with pinned `oc`, `helm`, `kubectl`, `jq`, `yq`

**Credentials in Jenkins:**
- `svc-ocp-deploy-<env>` — **secret text** containing a ServiceAccount token from the target namespace.

**Minimum OCP permissions:**
- SA `jenkins-deploy` in `payments-product-api-<env>`, bound to ClusterRole `acme-deployer` via **RoleBinding** (namespaced) — not ClusterRoleBinding.
- The SA cannot delete the namespace, cannot modify RBAC, cannot read cluster-wide Secrets.

**Setup steps:**
1. In each target namespace:
   ```
   oc create sa jenkins-deploy
   oc adm policy add-role-to-user admin -z jenkins-deploy      # OR the restricted acme-deployer ClusterRole
   # issue long-lived-ish token (OCP 4.11+: create a Secret of type kubernetes.io/service-account-token)
   ```
2. Extract the token, store in Jenkins credential `svc-ocp-deploy-<env>` (folder-scoped to `acme/<team>/<env>/`).
3. In the pipeline:
   ```groovy
   withCredentials([string(credentialsId: "svc-ocp-deploy-${env}", variable: 'OCP_TOKEN')]) {
     sh '''
       oc login https://api.ocp.corp.local:6443 --token=$OCP_TOKEN
       oc project payments-product-api-${env}
       helm upgrade --install ...
     '''
   }
   ```
4. Rotate token quarterly (see [07-security-baseline.md](07-security-baseline.md)).

---

## Connection 7 — Jenkins ↔ Container registry (Nexus Docker hosted)

**What:** Jenkins pushes images; OCP pulls images.

**Credentials:**
- Jenkins push: `svc-nexus-docker-push-<team>` (Connection 4).
- OCP pull: `svc-nexus-docker-pull` — stored as an OCP `Secret` of type `kubernetes.io/dockerconfigjson`, referenced by Deployments via `imagePullSecrets` (the Helm chart already templates this).

**Least-priv:**
- Pull SA has **read** on `docker-hosted-*` + `docker-proxy`, nothing else.

**Setup steps:**
1. Create `svc-nexus-docker-pull` in Nexus with read-only role.
2. `oc create secret docker-registry nexus-registry --docker-server=... --docker-username=... --docker-password=... -n <namespace>`
3. Helm `values*.yaml` sets `imagePullSecrets: [{ name: nexus-registry }]` (already done).

---

## Connection 8 — Jenkins ↔ CyberArk (secret fetch at runtime)

**What:** Prod DB credentials etc. fetched at deploy time, never stored in Jenkins credential store for prod.

**Plugins:**
- `conjur-credentials` (if Conjur), or direct `curl` to CCP AIMWebService.

**Credentials in Jenkins:**
- `svc-cyberark-appid-<env>` — secret text / client cert authenticating the Jenkins agent as an application to CyberArk.

**Minimum CyberArk permissions:**
- Application ID `jenkins-<env>` allowed to read safe `platform-<team>-<env>` only; IP allow-list restricts to Jenkins agent subnet.

**Setup steps:**
1. Register app ID with CyberArk; bind to Jenkins agent authentication (IP/hostname/cert).
2. Grant safe access to that app ID: `Retrieve accounts` only.
3. In pipeline:
   ```groovy
   withCredentials([string(credentialsId: "svc-cyberark-appid-${env}", variable: 'CYBERARK_APPID')]) {
     sh '''
       DB_USER=$(curl -sS --cert /etc/jenkins/cyberark.pem \
         "https://cyberark.corp.local/AIMWebService/api/Accounts?AppID=$CYBERARK_APPID&Safe=platform-payments-${env}&Object=product-api-db" \
         | jq -r .UserName)
     '''
   }
   ```

---

## Connection 9 — Jenkins ↔ SonarQube / Checkmarx / Aqua

**What:** SAST + image scanning gates.

**Credentials:** `svc-sonar-token`, `svc-checkmarx-<team>`, `svc-aqua-scanner`.
**Least-priv:** each token can write scan results to its project only; no admin.
**Plugins:** SonarQube Scanner, Checkmarx, Aqua Security.

See [../../java_project/Jenkinsfile.ci](../../../java_project/Jenkinsfile.ci) for the reference pipeline wiring.

---

## Connection 10 — Jenkins agents on OpenShift (dynamic)

**What:** Ephemeral pod agents for scalability.

**Plugins:** `kubernetes`

**Credentials:** Jenkins uses a dedicated SA `jenkins-agents` in namespace `devsecops-jenkins` with **pod create/delete** RBAC limited to that namespace.

**Setup:**
1. Namespace `devsecops-jenkins`.
2. SA `jenkins-agents` + Role with `pods/exec`, `pods`, `pods/log`: `get,list,watch,create,delete`.
3. In Jenkins → Manage Nodes → Kubernetes cloud → credentials = SA token; pod templates per language (`maven-agent`, `node-agent`, `tools-agent`).
4. Agent container images pulled from Nexus (no public pulls).

---

## Open questions (clarifications sought)

Only ask if answers change the design materially:

1. **OIDC vs LDAP for Jenkins:** is ADFS/Entra OIDC available, or must we stay on LDAPS?
2. **TFE licence:** is self-hosted Terraform Enterprise procured, or do we default to Consul?
3. **ADO service hook** vs **custom webhook to Jenkins** — any network constraint from ADO to Jenkins URL?
4. **CyberArk integration mode:** CCP (AIMWebService REST) or Conjur Enterprise? Affects Jenkins plugin choice.
5. **Release Manager vs CAB dual approval:** must both approve every prod deploy, or only high-risk changes?
6. **Branch strategy:** trunk-based OK, or does policy mandate GitFlow?
7. **Container registry:** will a dedicated registry (Quay/Harbor) be introduced later, or Nexus docker-hosted for the foreseeable?
8. **Rollback authority:** who can trigger prod rollback under incident — Release Manager, Platform on-call, or both?
