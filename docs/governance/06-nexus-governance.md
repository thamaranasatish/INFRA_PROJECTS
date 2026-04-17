# 06 — Nexus Governance (Maven + NPM + Docker)

**Golden rule:** nothing in this platform pulls from a public registry directly. Every resolver points at Nexus. Public upstreams are reached **only** by Nexus proxy repos, which are allow-listed, scanned, and audited.

---

## 6.1 Repository design

### Maven

| Repo | Type | Name | Purpose |
|---|---|---|---|
| Central proxy | **proxy** | `maven-central-proxy` | Proxies `https://repo.maven.apache.org/maven2/` (egress via corporate proxy) |
| Red Hat proxy | **proxy** | `maven-redhat-proxy` | `https://maven.repository.redhat.com/ga/` (for Red Hat artifacts) |
| Spring proxy | **proxy** | `maven-spring-proxy` | `https://repo.spring.io/release` (if needed) |
| Releases | **hosted** (release) | `maven-releases-acme` | Internally produced release artifacts |
| Snapshots | **hosted** (snapshot) | `maven-snapshots-acme` | SNAPSHOT artifacts |
| Group | **group** | `maven-public` | Order: releases → snapshots → central-proxy → redhat-proxy → spring-proxy |

Builds point **only** at `maven-public`. They never see individual upstream names.

### NPM

| Repo | Type | Name | Purpose |
|---|---|---|---|
| npmjs proxy | **proxy** | `npm-public-proxy` | Proxies `https://registry.npmjs.org` |
| Hosted (internal) | **hosted** | `npm-hosted-acme` | `@acme-<team>` scoped packages |
| Group | **group** | `npm-public` | Order: hosted → proxy |

Builds point at `npm-public`.

### Docker

| Repo | Type | Name | Purpose |
|---|---|---|---|
| Docker Hub proxy | **proxy** | `docker-hub-proxy` | Proxies `https://registry-1.docker.io` (subject to Docker Hub rate limits; consider a paid upstream account) |
| Red Hat registry proxy | **proxy** | `docker-redhat-proxy` | `https://registry.redhat.io` (requires RH auth) |
| Internal releases | **hosted** | `docker-hosted-acme` | Images produced by CI |
| Group | **group** | `docker-group` | Exposes everything via single URL |

Group `docker-group` is exposed on HTTPS port `8082` (separate connector).
OCP uses pull-secret pointing at `nexus.corp.local:8082`.

### Helm

| Repo | Type | Name |
|---|---|---|
| Internal | **hosted** | `helm-hosted-acme` |
| Group | **group** | `helm-group` (for future proxied upstreams) |

### Raw (optional — for installers, tarballs)

| Repo | Type | Name |
|---|---|---|
| Internal | hosted | `raw-hosted-acme` |

---

## 6.2 Enforced resolver configuration

### Maven — `settings.xml` generated at CI runtime

Never commit this file with credentials. Jenkins renders it per-build:

```xml
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">

  <mirrors>
    <!-- * means: override ALL upstreams, force everything through Nexus -->
    <mirror>
      <id>nexus-public</id>
      <mirrorOf>*</mirrorOf>
      <url>https://nexus.corp.local/repository/maven-public/</url>
      <name>Nexus group (all upstreams)</name>
    </mirror>
  </mirrors>

  <servers>
    <server>
      <id>nexus-public</id>
      <username>${env.NEXUS_USER}</username>
      <password>${env.NEXUS_PASS}</password>
    </server>
    <server>
      <id>maven-releases-acme</id>
      <username>${env.NEXUS_USER_PUBLISH}</username>
      <password>${env.NEXUS_PASS_PUBLISH}</password>
    </server>
    <server>
      <id>maven-snapshots-acme</id>
      <username>${env.NEXUS_USER_PUBLISH}</username>
      <password>${env.NEXUS_PASS_PUBLISH}</password>
    </server>
  </servers>

  <profiles>
    <profile>
      <id>nexus</id>
      <repositories>
        <repository>
          <id>nexus-public</id>
          <url>https://nexus.corp.local/repository/maven-public/</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>nexus-public</id>
          <url>https://nexus.corp.local/repository/maven-public/</url>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>

  <activeProfiles>
    <activeProfile>nexus</activeProfile>
  </activeProfiles>
</settings>
```

Add to app `pom.xml` `<distributionManagement>`:

```xml
<distributionManagement>
  <repository>
    <id>maven-releases-acme</id>
    <url>https://nexus.corp.local/repository/maven-releases-acme/</url>
  </repository>
  <snapshotRepository>
    <id>maven-snapshots-acme</id>
    <url>https://nexus.corp.local/repository/maven-snapshots-acme/</url>
  </snapshotRepository>
</distributionManagement>
```

### NPM — `.npmrc` generated at CI runtime

```
# Base registry — all resolution flows through this
registry=https://nexus.corp.local/repository/npm-public/

# Scoped packages still resolve through the same group
@acme-payments:registry=https://nexus.corp.local/repository/npm-public/

# Auth token for Nexus (generated: user:pass base64 or _authToken)
//nexus.corp.local/repository/npm-public/:_auth=${NEXUS_NPM_AUTH_BASE64}
//nexus.corp.local/repository/npm-hosted-acme/:_authToken=${NEXUS_NPM_TOKEN}

# Hard rules
always-auth=true
strict-ssl=true
audit=false        # npm audit hits public — we rely on Aqua/Sonar/OWASP instead
fund=false
```

### Docker — daemon config + pull secrets

Docker daemon on Jenkins agents:

```json
{
  "registry-mirrors": ["https://nexus.corp.local:8082"],
  "insecure-registries": []
}
```

OCP nodes pull through the registry mirror via the cluster-wide `ImageContentSourcePolicy` / `ImageDigestMirrorSet`:

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata: { name: nexus-mirror }
spec:
  imageDigestMirrors:
    - source: docker.io
      mirrors: [ nexus.corp.local:8082/docker-group ]
    - source: registry.redhat.io
      mirrors: [ nexus.corp.local:8082/docker-group ]
    - source: quay.io
      mirrors: [ nexus.corp.local:8082/docker-group ]
```

### Egress firewall

Nexus VM is the **only** host in DevSecOps VLAN allowed outbound (via corporate proxy) to:
- `repo.maven.apache.org:443`
- `maven.repository.redhat.com:443`
- `registry.npmjs.org:443`
- `registry-1.docker.io:443`
- `registry.redhat.io:443`
- …plus any additional **approved** upstreams from the onboarding register.

All other outbound from Jenkins agents + OCP workers = deny.

---

## 6.3 New-package onboarding process

Applies to any Maven coordinate, npm package, Docker image, Helm chart, or raw artifact not already resolvable from Nexus.

### Flow

```
  1. Developer opens "Package Onboarding Request" (ADO work item or ITSM ticket)
       ├── coordinates (groupId:artifactId:version / @scope/name@version / image:tag)
       ├── purpose + business justification
       ├── upstream URL + licence
       └── alternatives considered
  2. Maintainer (team lead) sponsors the request
  3. SecOps runs checks:
       ├── Licence review (approved list: Apache-2.0, MIT, BSD-2/3, EPL-2.0, LGPL w/ caveats)
       ├── CVE scan (OWASP Dependency-Check / Aqua / Snyk)
       ├── Maintainer/provenance check (known publisher, signing)
       └── SBOM generated and archived
  4. Platform adds upstream to Nexus proxy repo IF NEW UPSTREAM (rare)
     OR
     Pulls artifact into Nexus cache and verifies (standard case)
  5. Release Manager approves
  6. Add coordinate to the "Allowed Packages" list (git-tracked CSV in platform repo)
  7. Developer can now resolve via maven-public / npm-public / docker-group
```

**Emergency path** (active sev-1/2 incident):
- Platform admin can time-box allow an upstream for 48 h without full review.
- Ticket auto-created; full review completed within that window.
- Break-glass logged to SIEM + reviewed by CAB.

### Roles

| Step | Role |
|---|---|
| Raise | Developer |
| Sponsor | Team Maintainer |
| Security review | SecOps |
| Licence review | Legal/Compliance |
| Approve | Release Manager |
| Configure Nexus | Platform Admin |
| Publish "Allowed Packages" update | Platform Admin |

### SLA

- Standard request: 3 business days.
- Security-sensitive (new upstream, new maintainer, copyleft licence): 10 business days.

### What is documented per request

- Ticket ID
- Coordinate + version range
- Licence + SPDX ID
- CVE scan output (attached)
- SBOM (attached)
- Reviewer(s) + approver
- Date added to allow-list

---

## 6.4 Publishing internal packages

### Maven

1. `pom.xml` has `<distributionManagement>` pointing at `maven-releases-acme` / `maven-snapshots-acme`.
2. CI stage:
   ```
   mvn -B -s $SETTINGS deploy -DskipTests=false
   ```
   - `SNAPSHOT` versions → `maven-snapshots-acme`
   - Final versions → `maven-releases-acme` (release-staging plugin enforces no re-deploy)
3. Tag Git only when release artifact is successfully deployed.

### NPM (scoped)

1. Package name: `@acme-<team>/<pkg>` — tied to hosted repo ACL.
2. CI stage:
   ```
   npm config set //nexus.corp.local/repository/npm-hosted-acme/:_authToken=$NEXUS_NPM_TOKEN
   npm publish --registry=https://nexus.corp.local/repository/npm-hosted-acme/
   ```

### Docker

- Always push tag `<SHA>`; optionally `<VERSION>`.
- Never push `latest` from CI. Latest tag (if ever needed) is created only by a promotion job.

### Promotion / staging

Recommended pipeline promotion (implementable via Nexus "staging" plugin or repository-to-repository pushes):

```
docker-hosted-acme      (immutable builds)
   │  promote on test pass
   ▼
docker-hosted-acme-test (test-verified)
   │  promote on prod approval
   ▼
docker-hosted-acme-prod (prod-approved)
```

If staging plugin is not used, alternative is **retagging the same digest** in a single hosted repo with suffix `-test-verified` / `-prod-approved`. Helm values reference the specific tag.

### Retention / cleanup

Nexus cleanup tasks (run weekly):

| Repo | Rule |
|---|---|
| `maven-snapshots-acme` | Delete snapshots older than 30 days |
| `maven-releases-acme` | Keep last 10 versions per artifactId + all versions referenced in prod |
| `npm-hosted-acme` | Keep last 10 versions per package |
| `docker-hosted-acme` | Delete images older than 90 days **unless** tagged `*-prod-approved` |
| `docker-hosted-acme-prod` | Retain indefinitely (auditable artifact) |
| All proxy repos | Default: cache eviction only on low-touch artifacts >180 days |

Blob store compaction monthly.

---

## 6.5 Nexus security hardening

- LDAPS realm integrated with AD; map AD groups to Nexus roles.
- Local `admin` account: strong password, MFA via SSO, used only for break-glass.
- HTTPS enforced on all endpoints (8081, 8082); HTTP disabled.
- Anonymous access disabled globally.
- Content Selectors limit which groups a user can see (don't leak upstream structure).
- Audit log enabled; forwarded to SIEM via syslog.
- Role per team per repo tier (read, deploy-snapshot, deploy-release, admin).
- Backups: nightly Nexus backup task to NFS; file-level snapshot of blob store weekly.
- Blob store encryption via VM-level encryption or LUKS on the data disk.
- Firewall rules: only Jenkins agents, OCP node CIDRs, and approved user subnets can reach 8081/8082.
