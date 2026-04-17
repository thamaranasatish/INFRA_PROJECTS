# 07 — Security & Hardening

## 7.1 Principles

- Default-deny networking (NetworkPolicy, firewall, SCC).
- Least privilege RBAC; no shared service accounts.
- Secrets never at rest in Git, config maps, or env templates — only in CyberArk, projected at runtime.
- Signed images, attested SBOMs, scanned at build and at admission.
- Continuous compliance scanning (Compliance Operator + Aqua + SIEM ingestion).

## 7.2 OS hardening (RHEL 9 service VMs)

- CIS RHEL 9 Level 1 benchmark via OpenSCAP (`xccdf_org.ssgproject.content_profile_cis`).
- SSH: key-only auth, root login disabled, idle timeout 15 min, allow-list via AD group.
- `auditd` enabled; forward to SIEM.
- FIPS mode enabled where required.
- `fapolicyd` allow-list for critical hosts (Jenkins, CyberArk clients).
- Automatic patching via Satellite / RHSM with maintenance windows.

## 7.3 OpenShift hardening

- **SCC**: default = `restricted-v2`. No workload uses `anyuid`/`privileged`/`hostnetwork` without a documented SEC exception. Audit with `oc get pods -A -o json | jq ...`.
- **Pod Security Admission**: `restricted` enforce across app namespaces.
- **NetworkPolicy** per namespace — default-deny ingress + egress; explicit allow to DB/Redis/MQ/Kafka CIDRs and to `openshift-dns`.
- **Egress firewall** (`EgressNetworkPolicy` or `AdminNetworkPolicy`) locks down external destinations.
- **etcd encryption at rest** enabled (`aescbc` or `aesgcm`).
- **Audit logging**: cluster audit policy set to `WriteRequestBodies` for sensitive verbs, forwarded to Kafka audit topic → SIEM.
- **API server**: OIDC only, `kubeadmin` removed, `system:anonymous` revoked, rate limiting via API Priority & Fairness.
- **Compliance Operator**: weekly scans — `cis-ocp`, `nist-800-53-moderate`, `pci-dss`.

## 7.4 Image supply chain

- **Build**: Maven + `jacoco`, `dependency-check` (OWASP) at CI.
- **SAST**: SonarQube Quality Gate + Checkmarx High=0 / Med ≤5.
- **SCA**: OWASP Dependency-Check or Snyk (licence check).
- **Image scan (pre-push)**: Aqua scanner (CVSS ≥ 7 blocks unless waived).
- **Sign**: `cosign sign` with KMS-backed key; attach SBOM (`syft`).
- **Admission**: Aqua Enforcer + (optional) Red Hat ACS verifies signature + policy; deployments of unscanned or unsigned images rejected.
- **Runtime**: Aqua runtime policies — file integrity, drift prevention, process allow-lists on high-value pods.

## 7.5 Secrets

| Consumer | Mechanism |
|---|---|
| App pods | `ExternalSecret` → CyberArk CCP → K8s `Secret` → env or mounted file. TTL refresh 5 min. |
| Jenkins pipelines | CyberArk `summon` / CCP REST call; never stored in Jenkins credentials for prod. |
| VM-level service accounts | CyberArk Password Vault — passwords rotated per policy. |
| TLS private keys | cert-manager with KMS issuer (HashiCorp Vault or internal CA). |

Rules:
- **No** secret in `values.yaml`, Dockerfile, Git history, or ConfigMap.
- Rotate DB creds at minimum every 90 days; audit via CyberArk.
- Dev can use chart-managed secrets (convenience); test and prod must not.

## 7.6 RBAC — application namespaces

| Role | dev | test | prod |
|---|---|---|---|
| `appdev-products` AD group | admin | edit | view |
| `sre` | view | view | edit |
| `cluster-admin` (break-glass) | admin | admin | admin (MFA + JIT, auditable) |
| Jenkins SA `jenkins-deploy-<env>` | edit | edit | edit (no delete-namespace) |

Break-glass access is JIT-issued via ticket workflow, time-boxed, and logged.

## 7.7 F5 / WAF controls

- Wildcard cert for `*.apps`, TLS 1.2+ only, HSTS, secure ciphers (Mozilla modern).
- OWASP CRS signature set; positive model for admin paths.
- Rate limiting: 100 rps/IP default, lower for `/api/auth/*`.
- Geolocation block-list; integration with threat-intel feeds.
- Bot defence on login endpoints.

## 7.8 Data protection

- MSSQL TDE + backup encryption.
- Redis TLS + AUTH; rotate password.
- Kafka SASL_SSL + ACLs per topic.
- ActiveMQ TLS + JAAS with per-queue ACLs.
- Volume-level encryption via vSphere VM encryption (KMIP — HSM-backed).

## 7.9 Audit & logging

- Cluster audit → Fluentd → Elasticsearch (cluster) + Kafka audit topic → SIEM.
- App audit events → Kafka → SIEM.
- RHEL `auditd` → SIEM.
- vCenter + ESXi logs → syslog → SIEM.
- F5 logs → syslog → SIEM.
- Retention: online 30 days, cold 1 year (regulatory may extend).

## 7.10 Vulnerability management

- CVE feed: RHSA, NVD, vendor advisories.
- SLA: critical (CVSS ≥ 9) patched ≤ 72 h; high ≤ 7 days; medium ≤ 30 days.
- Monthly pen test of non-prod; annual external pen test of prod.
- Table-top incident-response exercise each quarter.

## 7.11 Compliance reporting

- Compliance Operator + Aqua compliance feed into GRC tool.
- Evidence packages auto-generated: etcd-encryption status, PSA mode, SCC usage, image signing coverage, NetworkPolicy coverage, backup RPO, patch SLA.
