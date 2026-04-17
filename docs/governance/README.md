# Platform Governance — On-Prem DevOps Standards

**Author role:** Senior DevOps / Platform Architect
**Scope:** End-to-end **governance and implementation standards** for the on-prem DevOps platform (**AD + Jenkins + Kubernetes/OpenShift + Terraform + Nexus**) covering **DEV / TEST / PROD** with strict Separation of Duties.

This folder complements the infrastructure build plan in [`../`](../) (docs 01–09). Every team onboarding to the platform must comply with these standards.

---

## Index

| # | Document | Purpose |
|---|---|---|
| A | [01-architecture-and-integration.md](01-architecture-and-integration.md) | Narrative of how AD, Jenkins, Git, Nexus, Terraform, OCP connect |
| B | [02-naming-conventions.md](02-naming-conventions.md) | Canonical naming across every tool |
| C | [03-ad-rbac-matrix.md](03-ad-rbac-matrix.md) | AD group taxonomy, role matrix, SoD enforcement |
| D | [04-automation-bindings.md](04-automation-bindings.md) | "Connection 1..N" walkthrough with credentials + least-priv perms |
| E | [05-terraform-state-onprem.md](05-terraform-state-onprem.md) | Remote state + locking without S3 (TFE self-hosted; Consul alt) |
| F | [06-nexus-governance.md](06-nexus-governance.md) | Repo design, enforced mirrors, package onboarding, publishing |
| G | [07-security-baseline.md](07-security-baseline.md) | Credentials, rotation, audit, SoD enforcement points |

---

## Platform at a glance

```
                    ┌────────────────────────┐
                    │  Active Directory      │  ← single source of identity
                    └───────────┬────────────┘
                   LDAPS/OIDC   │
       ┌─────────────────────┬──┴──┬────────────────────────┐
       │                     │     │                        │
  ┌────▼─────┐         ┌─────▼─────▼────┐           ┌───────▼────────┐
  │ Jenkins  │ ──────► │  OCP/Kubernetes│           │ Nexus Repo Pro │
  │  CI/CD   │  ◄────► │  DEV/TEST/PROD │           │ mvn/npm/docker │
  └────┬─────┘         └────────┬───────┘           └───────▲────────┘
       │ checkout/webhook       │ pull images & helm         │
       ▼                        ▼                             │
  ┌────────┐              ┌───────────────┐                   │
  │  Git   │              │   Terraform   │ ──state+lock──►   │  Consul (OSS) or TFE (preferred)
  │  ADO   │              │     IaC       │                   │
  └────────┘              └───────────────┘                   │
                                                              │
                                                              └── builds publish here
```

---

## Constraints honoured

- ❌ **No S3** — Terraform state uses **Terraform Enterprise (self-hosted)** [preferred] or **Consul** [OSS alternative], both with native locking.
- ❌ **No direct public registries** — Maven/NPM/Docker always resolve through Nexus group repos. Builds fail if they reach `repo.maven.apache.org`, `registry.npmjs.org`, or `docker.io` directly.
- ✅ **AD is the single identity provider** for humans. Service accounts use short-lived tokens vaulted in Jenkins/CyberArk.
- ✅ **Developers cannot approve PROD** — prod deploys require a **Release Manager + CAB** gate (see [03-ad-rbac-matrix.md §4](03-ad-rbac-matrix.md)).
- ✅ **Least privilege by default**, SoD enforced in Jenkins (matrix auth), OCP (RBAC), Git (protected branches), Nexus (repo-level roles).

---

## Placeholders used throughout

| Placeholder | Example | Meaning |
|---|---|---|
| `<ORG>` | `acme` | Company / tenant short code |
| `<APP>` | `product-api` | Application / service name |
| `<TEAM>` | `payments` | Owning team code |
| `<ENV>` | `dev` / `test` / `prod` | Environment |
| `<COMPONENT>` | `backend` / `frontend` | App component |
| `<VERSION>` | `1.4.2` | Semantic version |
| `<SHA>` | `a1b2c3d4e5f6` | 12-char git short SHA |

---

## Reading order

1. [01-architecture-and-integration.md](01-architecture-and-integration.md) — big picture
2. [02-naming-conventions.md](02-naming-conventions.md) — **read before creating anything**
3. [03-ad-rbac-matrix.md](03-ad-rbac-matrix.md) — identity model
4. [04-automation-bindings.md](04-automation-bindings.md) — wiring
5. [05](05-terraform-state-onprem.md) / [06](06-nexus-governance.md) / [07](07-security-baseline.md) — prerequisites live before first pipeline
