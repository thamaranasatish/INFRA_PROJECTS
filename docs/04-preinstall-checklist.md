# 04 — Pre-install Checklist

**Gate: no VM in the OCP VLAN is powered on until every item here is ✅.**
Owner column shows who signs off.

## 4.1 Governance

- [ ] Architecture Review Board approval (design doc + this repo tagged `v1.0`) — *Architect*
- [ ] Change ticket raised covering Phases 1-3 — *Change Mgmt*
- [ ] RACI matrix signed — *Platform Lead*
- [ ] Naming convention doc approved (VMs, namespaces, service accounts, Helm releases) — *Platform Lead*
- [ ] CMDB entries created for all planned VMs — *CMDB owner*
- [ ] Pull Secret from Red Hat console downloaded to secure location — *Platform*
- [ ] OCP subscription / entitlement SKU confirmed — *Procurement*

## 4.2 Network

- [ ] VLANs 10/20/30/40/50/60/70 provisioned with ACLs per [02-network-design.md](02-network-design.md) — *Network*
- [ ] Firewall matrix implemented and tested (nmap between tiers) — *Network + SecOps*
- [ ] Wildcard `*.apps.ocp.corp.local` DNS record created — *Network*
- [ ] `api.ocp.corp.local` and `api-int.ocp.corp.local` A records created — *Network*
- [ ] Per-node A + PTR records for masters/workers/bootstrap — *Network*
- [ ] etcd SRV records created — *Network*
- [ ] F5 VIPs created (api 6443, api-int 22623, apps 80/443) — *Network/F5*
- [ ] F5 health monitors configured and passing against placeholder pool — *Network/F5*
- [ ] Internal CA issues wildcard cert `*.apps.ocp.corp.local` (1-year validity) — *PKI*
- [ ] Corporate egress proxy reachable from VLAN 30; `noProxy` list finalised — *Network*
- [ ] NTP (2+ servers) reachable from VLAN 30 — *Platform*
- [ ] DNS test: forward+reverse for every planned FQDN from bastion — *Platform*

## 4.3 VMware

- [ ] vCenter 8.0 U3 at patch level ≥ latest — *Virtualisation*
- [ ] Dedicated cluster / resource pools for OCP — *Virtualisation*
- [ ] DRS anti-affinity rules created (masters on different hosts) — *Virtualisation*
- [ ] SSD-backed datastore available for etcd (IOPS ≥ 5000 verified with HCIBench/vdbench) — *Storage*
- [ ] vSphere HA admission control tuned (25/25) — *Virtualisation*
- [ ] vSphere CSI driver version compatible with target OCP release — *Platform*
- [ ] vSphere service account for Terraform/CSI created with role `openshift-csi` (least privilege per Red Hat docs) — *Virtualisation*
- [ ] RHCOS OVA for target OCP version uploaded to content library — *Platform*
- [ ] RHEL 9 base template, STIG-hardened, updated within 30 days — *Platform*
- [ ] Time sync on ESXi hosts verified — *Virtualisation*

## 4.4 Identity & secrets

- [ ] CyberArk safe `products-platform` created — *IAM/SecOps*
- [ ] CyberArk application IDs for Jenkins + ESO registered — *IAM/SecOps*
- [ ] Service accounts for Ansible/Terraform stored in CyberArk — *IAM/SecOps*
- [ ] ADFS/Entra group membership finalised (see RBAC in 01) — *IAM*
- [ ] MFA enforced for cluster-admin group — *IAM*

## 4.5 Tooling prerequisites

- [ ] Bastion VM provisioned, hardened, joined to AD (or not, per policy) — *Platform*
- [ ] `openshift-install`, `oc`, `helm`, `jq`, `yq`, `ansible-core`, `terraform`, `govc` installed on bastion at pinned versions ([06-tools-versions.md](06-tools-versions.md)) — *Platform*
- [ ] Terraform state backend (S3/Azure Blob/vSphere-backed Consul) configured with locking — *Platform*
- [ ] Nexus reachable and `docker login` succeeds — *CI/CD*
- [ ] Jenkins controller online; agents connected — *CI/CD*
- [ ] SonarQube, Checkmarx, Aqua consoles healthy; admin creds in CyberArk — *SecOps*

## 4.6 Security pre-approvals

- [ ] OS hardening baseline (CIS RHEL 9 Level 1) signed off — *SecOps*
- [ ] Image signing policy documented (cosign / Red Hat Trusted Artifact Signer) — *SecOps*
- [ ] SCC plan: no `anyuid`, `privileged`, `hostnetwork` without an approved exception — *SecOps*
- [ ] Admission policy (Aqua Enforcer or OPA/Gatekeeper) designed — *SecOps*
- [ ] Secret-scan + SBOM generation steps added to CI pipeline plan — *SecOps*
- [ ] Data classification for MSSQL schema complete; encryption-at-rest configured — *Data Protection Officer*

## 4.7 Backup / DR pre-approvals

- [ ] Backup target (S3 bucket / NFS share) provisioned with immutability / object-lock — *Backup*
- [ ] Kasten K10 licence staged — *Backup*
- [ ] RPO/RTO objectives signed (default: RPO 1 h, RTO 4 h for prod) — *Business + Platform*
- [ ] DR run-book template approved — *Platform*

## 4.8 Observability pre-approvals

- [ ] Central SIEM endpoint and credentials — *SecOps*
- [ ] Alert routing: email group, Teams webhook, PagerDuty service key — *SRE*
- [ ] Retention policy: logs 30 days hot / 1 year cold; metrics 15 days high-res / 1 year downsampled — *SRE*

## 4.9 Final go/no-go

- [ ] Smoke test: `openshift-install create manifests` dry-run succeeds on bastion — *Platform*
- [ ] Preflight script (see [ansible/preflight.yml](../ansible/preflight.yml)) returns zero failures — *Platform*
- [ ] Change window scheduled, comms sent, rollback plan attached — *Change Mgmt*
