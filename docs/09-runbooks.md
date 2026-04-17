# 09 — Day-2 Runbooks

High-level runbook index. Each entry is a skeleton — flesh out with site-specific commands during Phase 7.

## 9.1 Cluster upgrades

```
Pre:
  - Subscribe to OCP 4.16 stable channel
  - Review release notes + deprecated APIs (oc get apirequestcount)
  - Kasten pre-upgrade backup
  - Verify all operators healthy
Execute:
  - oc adm upgrade --to=4.16.x
  - Monitor: oc get clusterversion, oc get mcp
Post:
  - oc get co (Available=True); smoke tests; update CMDB
Rollback:
  - OCP minor rollback not supported; recover via K10 / etcd snapshot if needed
```

## 9.2 Node drain / patch

```
oc adm cordon <node>
oc adm drain  <node> --ignore-daemonsets --delete-emptydir-data --force
# patch / reboot / rotate
oc adm uncordon <node>
```

Schedule: monthly, during maintenance window, rolling one node at a time.

## 9.3 Certificate rotation

- F5 wildcard `*.apps`: 30-day expiry alert → CA request → F5 import → validate.
- Internal API cert: managed by cert-manager or OCP signer; verify on rotation day.
- OCP internal CA (`kube-apiserver-to-kubelet-signer` etc.) — auto-rotated by OCP; monitor `oc get csr` noise.

## 9.4 Scaling workers

- Terraform: bump `worker_count`; `terraform apply`.
- New VM boots → CSR auto-approval controller adds it → `oc get nodes` shows `Ready`.
- Verify MachineConfigPool converges.

## 9.5 Incident response

```
1. Acknowledge page (PagerDuty)
2. Declare severity (Sev1/2/3) in comms channel
3. Snapshot state: oc adm must-gather, Kasten pre-incident backup
4. Mitigate (rollback, scale, failover)
5. Write post-incident review within 5 business days
```

Contacts: on-call PLAT/SRE/SEC in PagerDuty schedule.

## 9.6 CyberArk credential rotation

- Rotation policy per safe (30/60/90 days).
- ExternalSecret refresh interval = 5 min → pods pick up new creds on restart or on secret hash annotation change.
- Dependency check: MSSQL login rotation must be coordinated with DB team (AG sync).

## 9.7 Backup restore (Kasten)

```
1. Open K10 dashboard
2. Applications → pick app → restore point
3. Restore to same or alternate namespace
4. Validate PVC bind, Deployment pods Ready
5. Run smoke tests; hand over to app team
```

Target time: < RTO defined per app.

## 9.8 etcd restore

See `runbook-etcd-restore.md` (skeleton). Key points:
- Only attempted when quorum is lost.
- Use OCP's documented procedure (single-member restore on a surviving master, force-new-cluster).
- Test quarterly in lab.

## 9.9 Pipeline failure triage

| Symptom | Check | Action |
|---|---|---|
| CI Sonar gate fails | Sonar dashboard | Fix code, re-run |
| CI Checkmarx blocker | CX report | Security sign-off or fix |
| Aqua block | Aqua console | Remediate CVE or time-boxed waiver |
| `helm upgrade` stuck | `oc describe pod`, `oc get events` | `--atomic` rolls back automatically; investigate cause |
| Smoke tests fail post-deploy | Ingress / DB connectivity | Check DNS, F5 pool, DB listener |

## 9.10 Access provisioning

- AD group addition → inherits OCP RBAC via OIDC.
- Break-glass: JIT via ticket, 4-hour max, auditable.

## 9.11 Image registry maintenance

- Weekly: Nexus blob store reconciliation, task `Compact blob store`.
- Monthly: clean-up policy prunes images older than 90 days not promoted to prod (production tags are retained indefinitely).

## 9.12 Observability housekeeping

- Elasticsearch index lifecycle management (ILM): hot 7d → warm 23d → delete.
- Prometheus retention 15d; long-term via Thanos / Grafana Mimir (future).
- Alert noise review quarterly.

## 9.13 Security operations

- Weekly: Compliance Operator report review.
- Weekly: Aqua risk report → remediate top 10.
- Monthly: CVE scan of base images; rebuild affected apps.
- Quarterly: SCC audit — ensure no workloads escalated.
