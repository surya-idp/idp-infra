---
# Feature Flag IDP — Master Handover Document
> Last updated: 2026-09-27 (Session 7: Step 30 live demo, GitHub sign-in, template research -> TEMPLATES_RESEARCH.md)
> Purpose: Self-contained context for any AI/agent to continue this project from any point.
> Nothing should need to be re-verified or re-asked if this document is read first.

---

## 0. Naming (renamed 2026-09-27)

The project is an IDP; the feature flag service is one workload running on it. The old
`ff-idp` prefix implied otherwise, so everything was renamed. Older notes/transcripts use the
old names.

| Old | New |
|---|---|
| repo `ff-idp-infra` | `idp-infra` |
| repo `feature-flag-service-env-config` | `idp-gitops` |
| repo `Feature-Flag-Service` | `feature-flag-service` |
| repo `idp-portal` | unchanged |
| AWS prefix `ff-idp-*`, secrets `ff-idp/*`, tag `Project=ff-idp`, ALB group `ff-idp` | `idp-*`, `idp/*`, `Project=idp`, `idp` |
| state bucket `ff-idp-tfstate-693906847772`, table `ff-idp-tf-locks` | `idp-tfstate-693906847772`, `idp-tf-locks` |
| CI roles `ff-idp-github-ci`, `ff-idp-service-ci` | `idp-github-ci`, `idp-service-ci` |
| AWS profile `ff-idp`, IAM user `ff-idp-admin`, laptop secrets dir `~/.ff-idp` | `idp`, `idp-admin`, `~/.idp` |
| GitHub owner `DSurya11` (personal) | GitHub org **`surya-idp`** (id 334455734, Free; user DSurya11 is admin). All 4 repos transferred 2026-09-27, same repo IDs (F16) |
| GitHub Apps `ff-idp-ci-bot`, `ff-idp-backstage` | renamed 2026-09-27 by the user in the GitHub UI (to `idp-ci-bot` / `idp-backstage` as suggested; confirm). IDs unchanged. Still to do: bot `git config user.name` in both CI workflows (use the token action's `app-slug` output), comments, secrets `FF_IDP_CI_BOT_*` |

The old state bucket and lock table were detached from 00-bootstrap state (not destroyed) as a
backup. Delete them after the first successful `make up` on the new bucket. `verify-empty`
scans both `Project=idp` and `Project=ff-idp` tags.

---

## 0a. Current State at a Glance (2026-10-11, cluster work finished)

**AWS right now:** everything destroyed except the permanent layers (00-bootstrap, 10-network,
15-registry). `make verify-empty` passes. Nothing runs; the idle cost is a few cents a month
(image storage, state bucket, an empty docs bucket).

**Money: read this before starting anything in AWS.** The credits this project was planned on
are gone. Billing > Credits lists every credit as `Expired` with status date **2026-09-27** and
$0.00 active; Cost Explorer shows October usage with no credit applied. The likely cause, not
confirmed by AWS: IAM Identity Center was set up on 2026-09-27, which creates an AWS
Organization, and that ends the Free Tier plan and its credits. Every cluster hour (~$0.33) is
billed to the card. Owner's decision of 2026-10-11: no change that costs money, and no further
cluster session without an explicit yes. A billing support case asking for the credits to be
reinstated is free to open (Finding 91).

| Step / package | Status |
|---|---|
| 1-22 (app, kind platform, Terraform bootstrap, network, data, CI rewrite) | Done |
| 23 EKS, 24 ESO, 25 ALB ingress, 26 Argo CD app-of-apps, 27 Kustomize overlays, 28 zero-downtime rollouts | Done and verified 2026-09-26 |
| 29 Backstage in the cluster, 30 template `python-service` v2 (form -> live with zero clicks) | Done and verified 2026-09-27 / 2026-10-10 |
| Guardrails F4/F5 (AppProjects, Pod Security), F10 (ESO 2.11.0) | Done and verified 2026-10-10 |
| Package 0: supply chain (signed build provenance + SBOM in the shared CI workflow) | Done; verified 2026-10-11 (`gh attestation verify`, provenance policy report) |
| Package 1: per-service database logins (F3), template `add-postgres-database` (T3) | Done and verified 2026-10-11 |
| Package 2: Kyverno and eight admission policies (Step 33, F5) | Done and verified 2026-10-11 |
| Package 3: observability: metrics, dashboards, alerts, logs, traces (Step 34, F14) | Done and verified 2026-10-11 through the APIs; nobody has opened the Grafana dashboard in a browser |
| Package 4: Argo CD installs the platform controllers (F9); EKS Pod Identity (F12) | Done and verified 2026-10-11 |
| Package 5: NetworkPolicy, TLS to Valkey (F13) | Done and verified 2026-10-11 |
| Package 6: portal for more than one person (Step 31, F15): GitHub discovery, permission policy, no guest, TechDocs from S3, Kubernetes and GitHub Actions tabs | Done and verified 2026-10-11, except the refusal of a non-admin (unit tests only). Argo CD and Grafana plugins deliberately not built |
| Package 7: feature flag golden path (T2): Kubernetes identity for the flag API, template `add-feature-flag`, flag helper in the skeleton | Done and verified 2026-10-11 |
| Package 8: delivery clean-up (F8): every app deployed by Image Updater, scan before push, only the newest commit is pushed | Done and verified 2026-10-11 |
| Package 9: `make e2e` (Step 36), rollout under load on a template service, recovery drill (Step 35) | e2e 42/42 and rollout (3,001 requests, 0 failed) verified. Drill: `make down` 17 min 16 s; the rebuild has no clean single number (Finding 89), roughly 40 minutes from nothing |
| Template `decommission-service` (T4) | Done and verified 2026-10-11: nothing left behind. Its "delete the repository" option is not yet run for real |
| Package 10: READMEs and these three documents | This change |
| Package 11: study guide and video course | In progress, local (`~/projects/idp-study-guide/ROADMAP.md`) |

**How a session works:** merge everything and `git pull` in idp-infra first. Then
`aws sso login --profile idp` (the login lasts a few hours: log in again before a long run),
`TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32" make up` (about 27 minutes;
it now waits for Argo CD's first full sync and exits 1 if the platform is not ready),
`make e2e` (42 checks), work, `make down` (about 17 minutes, must exit 0). Cost while up:
~$0.33/hr (three `t4g.medium` nodes since 2026-10-11).

**One delivery chain for everything:** push -> CI (tests, arm64 image, Trivy scan, then push to
ECR via OIDC, only for the newest commit of main) -> Argo CD Image Updater commits the tag to
idp-gitops as `idp-ci-bot[bot]` (signed) -> Argo CD rolls it out. The flag API and Backstage use
it since 2026-10-11, like every template service. No application repository holds a credential
for idp-gitops; the bot's key exists only in the cluster (and in `~/.idp` for the next
`make up`). With the cluster down, a merge only pushes an image; the tag is committed at the
next start.

**The five repositories:** idp-infra, idp-gitops, idp-portal, idp-platform (shared CI workflow,
tags v1.0.0, v2.0.0, v2.1.0, v2.1.1 = `3d15dbf`), feature-flag-service. Each has a README that
describes its final state.

**What 2026-10-10 and 2026-10-11 added, in one paragraph:** packages 0-5 were built offline on
the 10th (15 pull requests), verified in cluster session A on the 11th (13 checks, seven bugs
found and fixed), packages 6-8 were built offline the same day, and verified in session B
(14 checks, ten more bugs found and fixed, including one that mattered: the older of two quick
pushes could end up deployed). Findings 62-93 in section 13 are the record. Results tables:
`~/projects/idp-study-guide/COMPLETION-PLAN.md` sections 5a and 5c.

**Never verified, so say so:** a real second user being refused by the permission policy; the
"delete the repository" box of `decommission-service`; the Grafana dashboard opened in a
browser; an exact first-response time through the load balancer for a new service.

**Deliberately not built** (reasons in PLATFORM_REVIEW section 4 and
`COMPLETION-PLAN.md` section 4): staging and production with promotion; other languages;
a domain, HTTPS on the load balancer and single sign-on for the tools; multi-AZ RDS and
backups; declarative ECR repositories; the Argo CD and Grafana plugins of Backstage.

**Standing chores:**
- Every release of idp-platform needs two follow-ups: its commit added to the signer list in
  `idp-gitops/platform/kyverno/verify-image-provenance.yaml`, and the pin in
  `idp-portal/templates/python-service/skeleton/.github/workflows/ci.yml`.
- idp-portal `.trivyignore` expires 2026-12-10: after that date its CI fails until the two
  entries are reviewed.
- Review the open Dependabot pull requests before any session (Finding 60).

---

## 1. Account & Environment Facts (Verified, Not Assumed)

| Key | Value |
|---|---|
| AWS Account ID | `693906847772` |
| AWS Account Name | D S S V Raju |
| Human access | IAM Identity Center (since 2026-09-27, F1): user `surya`, permission set AdministratorAccess (8h), portal https://d-9f6758cf96.awsapps.com/start. The account is now an AWS Organizations management account |
| Legacy IAM user | `idp-admin`: access key AKIA2DEASHAOE7YCAZFJ **Inactive** since 2026-09-27, no console password. Delete the key after ~2026-10-04 if nothing broke, plus `~/.aws/credentials.disabled` / `.bak` |
| AWS CLI Profile | `idp` = SSO profile (`sso_session = surya`). Start of every session: `aws sso login --profile idp` |
| AWS CLI Version | `aws-cli/2.36.49` |
| Default Region | `ap-south-1` (Mumbai) |
| Credit Balance | ~$200 USD |
| Credit Expiry | March 21, 2027 (181 days from 2026-09-21) |
| Free Tier Type | Credit-based (account created after July 15, 2025) |
| Free Tier Reality | NO traditional 750hr/month free tier. ALL costs come from $200 credits. |
| OS | Fedora Linux (Fedora 44) |
| GitHub User | `DSurya11` |
| Local projects path | `/home/surya/projects/` |
| Terraform | v1.16.3 (installed via HashiCorp dnf repo) |

**Verify identity before any session:**
```bash
aws sso login --profile idp          # browser: surya + authenticator MFA
aws sts get-caller-identity --profile idp
# Must show: Account: 693906847772, Arn: ...:assumed-role/AWSReservedSSO_AdministratorAccess_.../surya
# NEVER operate as root (root: MFA on, no access keys - verified 2026-09-27)
```

---

## 2. Verified Prices — ap-south-1 (Mumbai)
> Verified 2026-09-21 via `aws pricing get-products` API.

| Service | Rate | Unit | Notes |
|---|---|---|---|
| EKS control plane | $0.10 | /hr | Always charged when cluster exists |
| EC2 t4g.small On-Demand | $0.0168 | /hr | **Chosen** — ARM Graviton, free-tier eligible |
| EC2 t3.medium SPOT | $0.0147–$0.0197 | /hr | **Blocked** by account-level free-tier restrictions |
| NAT Gateway | $0.056 | /hr | + $0.056/GB processed |
| ALB | $0.0239 | /hr | + $0.008/LCU-hr |
| RDS db.t3.micro PostgreSQL | $0.017 | /hr | **Chosen** — On-demand, t4g had no capacity |
| RDS gp2 storage | $0.114 | /GB-month | **Chosen** — gp3 had no capacity for micro DBs |
| RDS final snapshot | $0.131 | /GB-month | ACCUMULATES with each destroy — use skip_final_snapshot=true |
| ElastiCache cache.t4g.micro Valkey | $0.016 | /hr | Use Valkey not Redis — same API, 20% cheaper |
| Secrets Manager | $0.40 | /secret/month | + $0.05/10k API calls |
| ECR | $0.10 | /GB-month | Storage only |
| S3 Standard | $0.025 | /GB-month | Verified: tfstate is ~34KB = $0.00000078/mo |
| DynamoDB | ~$0 | | First 25GB free. tf-locks is PAY_PER_REQUEST ($0 idle) |
| EBS gp3 | $0.0912 | /GB-month | Node root volumes |
| Public IPv4 | $0.005 | /hr | Per IP, in-use OR idle |
| CloudWatch Logs ingestion | $0.50–$0.67 | /GB | EXPENSIVE — minimize aggressively |
| CloudWatch Logs storage | $0.03 | /GB-month | |

---

## 3. Cost Model

> **Update 2026-10-11.** Two things below are out of date and are kept as the record of the
> original plan. (1) The cluster now costs about **$0.33/hr**, not $0.26: three `t4g.medium`
> nodes instead of two `t4g.small` (Finding 70). Per hour: EKS $0.10, nodes 3 x $0.0336,
> NAT $0.056, ALB $0.024, public IPv4 about $0.015, RDS $0.017, Valkey $0.016.
> (2) **The credits expired on 2026-09-27** (Finding 91). The "credits remaining after
> project" line further down no longer applies: usage is billed to the card.

### CHOSEN: Option B — Full Destroy Every Session ($0.00 Idle)

User chose Option B on 2026-09-22 after full explanation of tradeoffs:
- Option A: $4.22/month idle (RDS stopped storage + Secrets Manager)
- Option B: $0.00/month idle (full destroy — nothing runs between sessions)

Option B was chosen because ElastiCache has NO stop API (discovered in Step 21), and the
only way to stop paying for it is to destroy it. Once destruction is required anyway, full
destroy of all layers costs nothing extra and is simpler to reason about.

**CRITICAL: skip_final_snapshot = true on RDS**
With Option B (full destroy each session), false = 12 × 20GB × $0.131 = $31.44/month in
orphaned snapshots. Must be true. Set and verified in 20-data/main.tf.

### Per 3-Hour Session (cluster up)
| Component | Calculation | Cost |
|---|---|---|
| EKS control plane | 3hr × $0.10 | $0.30 |
| EC2 t4g.small ×2 | 2 × 3hr × $0.0168 | $0.10 |
| NAT Gateway | 3hr × $0.056 | $0.17 |
| ALB | 3hr × $0.0239 | $0.07 |
| Public IPv4 (~3 IPs) | 3 × 3hr × $0.005 | $0.05 |
| EBS (negligible) | | ~$0.01 |
| RDS db.t3.micro | 3hr × $0.017 | $0.05 |
| ElastiCache Valkey | 3hr × $0.016 | $0.05 |
| Secrets Manager (4-5 secrets, proration) | | ~$0.01 |
| **Session total** | ~$0.26/hr | **~$0.80** (+$0.05 if HPA adds a 3rd node) |

### Monthly (12 sessions/month, 3hr each)
| Component | Monthly |
|---|---|
| Sessions (12 × $0.80) | $9.60 |
| Between sessions | $0.00 (Option B — everything destroyed) |
| ECR (~1GB, kept between sessions) | $0.10 |
| S3 + DynamoDB (state) | ~$0.01 |
| **Monthly total** | **~$9.71** |

### Project Total
- 6 months × $9.71 = ~$58 total
- Credits remaining after project: ~$140
- Verdict: Very comfortable. No need to cut scope.

---

## 4. Cost Rules (Non-Negotiable)

1. **`make down` before closing the laptop. VERIFY with `make verify-empty`.** Must show OK: $0.00.

2. **CloudWatch log retention = 1 day.** Set everywhere. Default 90-day at $0.50/GB is a silent credit drain.

3. **Option B lifecycle: DESTROY all layers (20-data, 30-cluster, 40-platform) in make down.**
   ElastiCache has NO stop API — the only way to not pay for it is to destroy it.
   RDS also destroyed (not stopped) — simpler, cheaper under Option B.

4. **Tag EVERY resource with `Project=idp`.** Via Terraform `default_tags`. Untagged orphans = surprise bills.

5. **Budget alerts confirmed in place:**
   - `My Zero-Spend Budget`: $1/month alert
   - `Total-180-of-200-Alert`: $180 cumulative over project lifetime

6. **Valkey, not Redis.** `engine = "valkey"` in ElastiCache Terraform. Same API, 20% cheaper.

7. **No paid domain.** Use ALB DNS name directly. Document as "production would use ACM + Route53; deferred."

8. **skip_final_snapshot = true on ALL RDS instances.** With Option B, false = $31/month snapshots.

9. **Check Billing > Credits before relying on credits** (added 2026-10-11, Finding 91). Look at
   the *active* tab, not "inactive credits": the inactive tab shows what was left when a credit
   expired. Cost Explorer lags about a day and each API query costs $0.01.

10. **Log in again before a long run** (added 2026-10-11, Finding 89). An expired single
    sign-on session stops Terraform mid-run; a half-built platform still costs money. After any
    failed `make up`, either finish it or run `make down`.

---

## 5. Repository State (as of 2026-10-11)

| Repo | Local path | What it holds |
|---|---|---|
| [idp-infra](https://github.com/surya-idp/idp-infra) | `~/projects/idp-infra` | Terraform layers, Makefile (`up`, `down`, `e2e`, `verify-empty`), `scripts/` (down.sh, verify-empty.py, load-local-secrets.sh), `tests/` (e2e.sh, rollout-load.js), this doc, `PLATFORM_REVIEW.md`, `TEMPLATES_RESEARCH.md` |
| [idp-gitops](https://github.com/surya-idp/idp-gitops) | `~/projects/idp-gitops` | Everything Argo CD deploys: the Applications, the platform folders (cluster, db-operator, image-updater, kyverno, monitoring), the apps, the three Kustomize components, the validation scripts and their tests. Layout and sync waves: its README |
| [idp-portal](https://github.com/surya-idp/idp-portal) (public) | `~/projects/idp-portal` | Backstage 1.54 app, its CI, four templates (`python-service`, `add-postgres-database`, `add-feature-flag`, `decommission-service`), eleven custom scaffolder actions and the permission policy in `packages/backend/src/`, template CI in `scripts/` |
| [idp-platform](https://github.com/surya-idp/idp-platform) (public, since 2026-10-10) | `~/projects/idp-platform` | Reusable CI workflow `python-service.yml` for template services: check, image (scan, push, attest), docs. Tags v1.0.0, v2.0.0, v2.1.0, v2.1.1. Tested against `tests/fixture-service` |
| [feature-flag-service](https://github.com/surya-idp/feature-flag-service) | `~/projects/feature-flag-service` | The flag API (FastAPI, Alembic), its tests and CI, `catalog-info.yaml` |

Every repository's README was rewritten on 2026-10-11 to describe the final state; section 18
of this document (the list of README additions) is closed.

Cleaned 2026-09-27: one-off helper scripts, old transcripts, duplicate kubectl/terraform
binaries, committed test `.db` files, the Step 11 `terraform/` folder in feature-flag-service
(later idp-infra/90-legacy-neon, retired 2026-09-27) and Backstage's demo entities/template are gone. The only
untracked file left is feature-flag-service `tests/test_e2e.sh` (kind-era; replaced by
`idp-infra/tests/e2e.sh`). Interview write-ups live outside the repos in `~/projects/to read/`.
Cleaned 2026-10-11: a compiled Python file that had been committed to idp-gitops (Finding 93).

### idp-gitops layout (short; the full one is in its README)
```
platform/argocd-apps/        the Applications; the root app (created by 40-platform) syncs this folder
  projects.yaml              wave -3: AppProjects default (locked), platform, apps
  platform-controllers.yaml  wave -2: AWS Load Balancer Controller; wave -1: External Secrets
  platform-cluster.yaml, kyverno.yaml, db-operator.yaml, monitoring-*.yaml     wave 0
  image-updater.yaml, feature-flag-dev.yaml, idp-portal.yaml                   wave 1
  golden-path-services.yaml  wave 1: ApplicationSet, apps/*/overlays/dev -> one Application each
platform/cluster/            ClusterSecretStore, PriorityClasses, Backstage's read-only cluster role,
                             the flag API's right to verify ServiceAccount tokens
platform/db-operator/        the operator's credentials (the only reader of the RDS master password)
platform/image-updater/      Argo CD Image Updater v1.3.1: two ImageUpdaters (template services; the
                             platform's two apps); commits as idp-ci-bot
platform/kyverno/            eight admission policies
platform/monitoring/         PodMonitor, alert rules, alert receiver, dashboard, NetworkPolicy
components/golden-path/      the standard for template services, including their namespace
components/public-route/     a path on the shared ALB
components/postgres/         a database and a login of the service's own
apps/feature-flag-service/   base + overlays dev/staging/prod (only dev deployed)
apps/idp-portal/             Backstage
apps/<service>/              added by the template's pull request: only the service's own values
tests/                       sample services, policy tests, alert rule tests (never deployed)
scripts/                     validate.sh and its checkers
```
Only Image Updater changes `newTag:` in `apps/*/overlays/dev/kustomization.yaml`.
`scripts/validate.sh` pins the public CRD schema catalog by commit (Finding 59).

---

## 6. What Is Done — Steps 1–23 (history; current status is in section 0a)

### Application Layer (Steps 1–9) ✅ All Complete
| Step | What | Key files |
|---|---|---|
| 1 | DB schema: `flags`, `targeting_rules`, `audit_log` (CASCADE/SET NULL) | `alembic/` |
| 2 | `/health` (503 on DB down) + fail-fast startup check | `app/main.py`, `app/routers/health.py` |
| 3 | JWT auth + bcrypt, admin role | `app/auth.py`, `app/dependencies.py` |
| 4 | Flag CRUD + audit logging | `app/routers/flags.py` |
| 5 | `/evaluate`: fail-safe, percentage hash, targeting rules | `app/evaluation.py`, `app/routers/evaluate.py` |
| 6 | Redis caching (shared across replicas, ~0.6ms) | `app/cache.py` |
| 7 | `docker-compose.yml` (local full-stack) | `docker-compose.yml` |
| 8 | Multi-stage Dockerfile (non-root appuser UID 999, HEALTHCHECK) | `Dockerfile` |
| 9 | GitHub Actions CI: test → build → push to GHCR (SHA + latest) | `.github/workflows/ci.yml` (rewritten in Step 22) |

### Platform Layer (Steps 10–16) ✅ All Complete
| Step | What | Key files |
|---|---|---|
| 10 | kind cluster, 2-replica deployment, liveness/readiness probes | `idp-gitops/api-deployment.yaml` |
| 11 | Terraform manages Neon (local state, `kislerdm/neon` v0.18.0) | `terraform/main.tf` |
| 12 | App/env-config split; CI auto-updates image SHA via sed + PAT | `ci.yml` lines 261–272 |
| 13 | Argo CD (automated sync, selfHeal, prune); secret-template trap found+fixed | `argocd/application.yaml` |
| 14 | Backstage catalog: Component + 2 Resources | `catalog-info.yaml` |
| 15 | Kyverno `disallow-root-containers` (Enforce) | `kyverno-policy-disallow-root.yaml` |
| 16 | Prometheus + Grafana, ServiceMonitor, 4 custom metrics, latency investigation | `app/metrics.py` |

### Key Findings From Steps 1-16 (Already in README)
1. p95 latency ~0.97s. Redis ~0.6ms. Postgres fetch ~780ms every request.
2. CrashLoopBackOff vs readiness failure — fail-fast startup bypasses probes.
3. Secret-template GitOps trap — Argo CD picks up any `kind: Secret` in watched path.
4. Kyverno optional-match `=(field)` bug — policy looked fine but enforced nothing.
5. CRD size limit → `kubectl apply --server-side`.
6. Argo CD selfHeal fighting manual `kubectl apply`.
7. conntrack stickiness on sequential in-cluster requests (not yet in README — add in Section 14).

### Infrastructure Phase (Steps 17–23) ✅ Complete

#### Step 17 — AWS Account Hygiene ✅
- IAM user idp-admin confirmed (NEVER root)
- Budget alerts confirmed:
  - `My Zero-Spend Budget`: $1/month threshold
  - `Total-180-of-200-Alert`: $180 cumulative
- AWS CLI profile idp working
- Verified: `aws sts get-caller-identity --profile idp` → Account 693906847772

#### Step 18 — Terraform Bootstrap (00-bootstrap) ✅
Applied 2026-09-22. Resources: 9 created. State: LOCAL (intentional).

Resources created:
- **S3 bucket** `idp-tfstate-693906847772`: versioning=Enabled, SSE=AES256, all public access blocked
- **DynamoDB table** `idp-tf-locks`: PAY_PER_REQUEST, hash key LockID
- **GitHub OIDC Provider**: thumbprint fetched dynamically via `tls_certificate` data source (NOT hardcoded — survives GitHub cert rotation)
- **IAM Role** `idp-github-ci`:
  - Trust: StringEquals on `sub` for exact repo + main branch (current subjects: section 11)
  - Trust: StringEquals `token.actions.githubusercontent.com:aud` = `sts.amazonaws.com`
  - No wildcards anywhere
  - Inline policy: `GetAuthorizationToken` on `*` (AWS requirement — account-level), all other ECR actions scoped to `arn:aws:ecr:ap-south-1:693906847772:repository/feature-flag-service`

#### Step 19 — Neon State Migration (90-legacy-neon) ✅
Applied 2026-09-22. State migrated from local to S3. Neon project untouched.
Retired 2026-09-27 after the A/B finished: project destroyed, layer removed (Finding 51).

#### Step 20 — Network Layer (10-network) ✅
Applied 2026-09-22. Resources: 17 created. Cost: $0/month permanently.
- VPC, 4 subnets (ap-south-1a/b), IGW, route tables, and SGs created permanently ($0/month).

#### Step 21 — Data Layer (20-data) ✅ (Revised Session 3)
Applied and destroyed 2026-09-22. Option B lifecycle: full destroy each session.
- ElastiCache moved to `30-cluster` to allow nightly destruction.
- **Session 3 Fix:** Switched to `db.t3.micro` and `gp2` storage type due to an active AWS capacity shortage for Graviton (`t4g`) databases with `gp3` in Mumbai (`ap-south-1`).

#### Step 22 — CI Rewrite ✅
Committed and pushed 2026-09-22. Commit: 907c464 to feature-flag-service repo.
- CI refactored to use GitHub App for env-config updates, ECR registry, and strictly OIDC auth (no static credentials).

#### Step 23 — EKS Cluster Layer (30-cluster) ✅
- `main.tf` written utilizing `terraform-aws-modules/eks/aws ~> 20.0` (Avoided v21 due to known `var.partition` planning freeze bug).
- **Session 3 Blockers Overcome:**
  - Account strictly blocks non-Free-Tier instance types (like `t3.medium`) from running as SPOT. 
  - Node group configuration altered to `t4g.small` (ARM Graviton) using `ON_DEMAND` capacity.
  - Required specifying `ami_type = "AL2023_ARM_64_STANDARD"` because EKS rejects mismatched architectures.
- Completed in Sessions 4-5: EKS 1.35, t4g.small ON_DEMAND nodes, prefix delegation (maxPods 110), metrics-server add-on.

---

## 7. Terraform Layer Architecture (idp-infra) — CURRENT STATE

```
idp-infra/
  00-bootstrap/     S3 state bucket, DynamoDB table (unused, Finding 49), GitHub OIDC provider,
  │                 CI roles idp-github-ci (the two platform apps), idp-service-ci (template
  │                 services: ECR svc/* and docs uploads), idp-infra-plan (read-only plan), and
  │                 the docs bucket idp-techdocs-<account> (since 2026-10-11).
  │                 LOCAL state (chicken-and-egg). Applied by hand. NEVER destroyed.
  10-network/       VPC 10.0.0.0/16, 2 AZs, public + private subnets, IGW, route tables, 4 SGs.
  │                 No NAT here (it is in 30). PERMANENT ($0).
  15-registry/      ECR feature-flag-service (keep 20) + idp-portal (keep 5). PERMANENT.
  │                 Not part of make up/down. (Template services create ECR svc/<name> from CI.)
  20-data/          RDS db.t3.micro PostgreSQL 16 (gp2, encrypted), Secrets Manager: idp/db-creds,
  │                 idp/jwt-secret and idp/grafana-admin (generated), idp/backstage-github-app and
  │                 idp/ci-bot-github-app (filled from ~/.idp). Destroyed every session.
  30-cluster/       EKS 1.35 (authentication mode API) + managed node group (3x ON_DEMAND
  │                 t4g.medium, prefix delegation, network policy agent on), metrics-server and
  │                 Pod Identity agent add-ons, NAT Gateway, ElastiCache Valkey with TLS +
  │                 idp/valkey secret, and one IAM role per controller bound through EKS Pod
  │                 Identity: idp-eso, idp-alb-controller, idp-image-updater, idp-portal,
  │                 idp-kyverno. Destroyed every session.
  40-platform/      Helm: Argo CD 10.9.2 (v3.5.3) only, plus the root Application
  │                 (app-of-apps -> idp-gitops/platform/argocd-apps). Argo CD installs the load
  │                 balancer controller, External Secrets and everything else. Destroyed every
  │                 session.
  modules/vpc/      the only module (used by 10-network)
  scripts/          down.sh (make down), verify-empty.py, load-local-secrets.sh
  tests/            e2e.sh (make e2e), rollout-load.js (k6 zero-downtime test)
  test_latency.py   latency A/B (Step 21)
  Makefile          make up / make e2e / make down / make verify-empty
```

### Backend Config (per layer, all except 00-bootstrap)
```hcl
terraform {
  backend "s3" {
    bucket         = "idp-tfstate-693906847772"
    key            = "XX-layername/terraform.tfstate"
    region         = "ap-south-1"
    profile        = "idp"
    use_lockfile   = true   # S3-native lock (Finding 49); the DynamoDB table is unused
  }
}
```

### Terraform Default Tags (EVERY resource)
```hcl
provider "aws" {
  region  = "ap-south-1"
  profile = "idp"
  default_tags {
    tags = {
      Project     = "idp"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
```

---

## 8. Session Lifecycle Commands (Option B — Full Destroy)

### make up (~27 min, measured)
```
[1/4] 20-data apply            RDS + 5 secrets (DB password, JWT key, Grafana password generated
                               by Terraform)
      scripts/load-local-secrets.sh
                               ~/.idp/{backstage-app.env, backstage-app.pem, backstage-client-secret}
                               -> idp/backstage-github-app
                               ~/.idp/{ci-bot-app.env, ci-bot-app.pem} -> idp/ci-bot-github-app
                               (via stdin; warns and skips if a file is missing)
[2/4] 30-cluster apply         EKS, 3 nodes, NAT, Valkey, the pod roles and their Pod Identity
                               associations
[3/4] aws eks update-kubeconfig --name idp-cluster
[4/4] 40-platform apply        Argo CD and the root app
      then waits (900s) for the root app's FIRST SYNC to succeed, then (300s) for Healthy;
      exits 1 if the platform is not ready (Finding 80)
```
Argo CD then installs, wave by wave: AppProjects (-3), load balancer controller (-2), External
Secrets (-1), cluster config + Kyverno + database operator + monitoring (0), Image Updater +
the flag API + Backstage + the ApplicationSet (1). That part takes about 8 of the 27 minutes.
No manual steps after it: secrets come from ESO, databases and logins from the operator,
migrations run as an Argo CD Sync hook. Run `make e2e` to confirm (42 checks).
Always pass today's address: `TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32" make up`
(the EKS API accepts one address; the default in 30-cluster/variables.tf is stale).

### make down (~17 min) = scripts/down.sh
```
[0/3] delete the root Argo app (cascade -> Ingresses -> the ALB controller deletes the ALB),
      then delete any leftover ALBs / target groups in the VPC
[1/3] destroy 40-platform   [2/3] destroy 30-cluster   [3/3] destroy 20-data
then  verify-empty.py
```
Exits non-zero if ANY step failed. Watch it finish; if interrupted, run it again (Finding 37).

Lost every session: RDS data (flags, users, audit log), secrets, cluster state, Valkey cache.
Survives: permanent layers (section 9), Git, Terraform state, ECR images.

### make verify-empty
`scripts/verify-empty.py`: (1) tagging API for `Project=idp` and `Project=ff-idp`, with free and
pending-deletion resources listed as INFO; (2) direct per-service checks (EKS, EC2, NAT, ELB,
RDS, ElastiCache, Secrets Manager, EIPs...) that do not depend on tags. Exit 0 = $0.00.

## 9. All Permanent AWS Resources (Live Right Now, Never Destroyed)

| Resource | ID / Name | Layer |
|---|---|---|
| S3 state bucket | idp-tfstate-693906847772 (versioned, S3-native lock files) | 00 |
| DynamoDB table | idp-tf-locks (unused, $0) | 00 |
| GitHub OIDC provider | oidc-provider/token.actions.githubusercontent.com | 00 |
| IAM roles | idp-github-ci, idp-service-ci, idp-infra-plan | 00 |
| S3 docs bucket | idp-techdocs-693906847772 (private, encrypted; documentation sites uploaded by service CI, read by Backstage; since 2026-10-11) | 00 |
| VPC | vpc-0adcac5ff98908f3b (10.0.0.0/16) | 10 |
| Subnets | public subnet-0acd17491022c527e (1a), subnet-01c8679e5fd4bf485 (1b); private subnet-038e07909e55745b9 (1a), subnet-0ffe3fe2c3c0167cd (1b) | 10 |
| IGW / route tables | igw-0497cc66bfde6497a; rtb-06be6c352335c4528 (public), rtb-05a36c795c8121544, rtb-0a792e4f26cc2f99e (private) | 10 |
| Security groups (recreated in the rename) | nodes sg-00fb3157d1737b8ae, rds sg-07f548e791862a77a, elasticache sg-06e3a1f4faf783e45, alb sg-053fa6f01bf151f17 | 10 |
| ECR | feature-flag-service, idp-portal (+ svc/<name> created by template CI) | 15 |
| ~~Backups~~ | S3 ff-idp-tfstate-693906847772 and DynamoDB ff-idp-tf-locks were deleted on 2026-09-27 (session notes of that day) | - |

All free except storage: ECR (~$0.10/GB-month) and a few cents for the buckets.

## 10. Ephemeral Resources (Destroyed Each Session, Recreated Each make up)

| Resource | Layer | Notes |
|---|---|---|
| RDS idp-postgres | 20-data | db.t3.micro, PostgreSQL 16, 20GB gp2, encrypted, SSL enforced (Finding 47). Holds one database per app, created by the database operator |
| Secret idp/db-creds | 20-data | master credentials, generated; read only by the database operator |
| Secret idp/jwt-secret | 20-data | generated (`random_password`) |
| Secret idp/grafana-admin | 20-data | generated |
| Secrets idp/backstage-github-app, idp/ci-bot-github-app | 20-data | placeholders, filled from `~/.idp` by make up |
| NAT Gateway + EIP | 30-cluster | |
| ElastiCache idp-valkey + secret idp/valkey | 30-cluster | cache.t4g.micro, engine valkey, TLS in transit (`rediss://`) |
| EKS idp-cluster + node group | 30-cluster | 1.35, 3x t4g.medium ON_DEMAND |
| IAM roles idp-eso, idp-alb-controller, idp-image-updater, idp-portal, idp-kyverno | 30-cluster | EKS Pod Identity associations (no role name in any manifest) |
| Argo CD, root app | 40-platform | |
| Load balancer controller, External Secrets, Kyverno, database operator, monitoring stack, Image Updater, the apps | installed by Argo CD from idp-gitops | |
| ALB (IngressGroup `idp`) | created by the load balancer controller | deleted by down.sh step 0 |

## 11. CI/CD State

### feature-flag-service and idp-portal (.github/workflows/ci.yml in each)
Same shape since 2026-10-11:
- tests on every push and pull request (flag API: pytest with Postgres and Redis services;
  portal: typecheck, unit tests, backend bundle, plus the `template` job).
- on main, on the native `ubuntu-24.04-arm` runner: **build -> Trivy scan -> push**. The scan
  is before the push because whatever is in ECR gets deployed. AWS login is OIDC -> role
  `idp-github-ci`. A re-run does not fail on the immutable tag.
- builds of one branch run one at a time, and **only the newest commit of main is pushed**:
  before pushing, the job compares its commit with the branch head (Finding 86).
- there is no `update-env-config` job and no bot key in these repositories any more. Argo CD
  Image Updater (ImageUpdater `platform-apps`) commits the tag to idp-gitops.

### Services created by the python-service template
Their CI is a ~15-line caller of `surya-idp/idp-platform/.github/workflows/python-service.yml`,
pinned by commit (v2.1.1 = `3d15dbf`). Three jobs:
- `check`: lock file, ruff, format check, mypy, pytest with a coverage gate.
- `image`: build arm64, Trivy, then on main: assume `idp-service-ci`, create ECR `svc/<name>`
  on first run, push (only for the branch's newest commit), then attest: signed build
  provenance and a signed CycloneDX SBOM, stored next to the image.
- `docs`: if the repo has a `mkdocs.yml`, build the TechDocs site on every run and on main
  publish it to the docs bucket under `default/component/<name>/`.
The deploy config is added by the template's pull request to idp-gitops, pinned to the first
commit SHA; the template merges that pull request itself after the first CI run is green.
Later tags are committed by Argo CD Image Updater (ImageUpdater `golden-path`).
idp-portal CI also has a `template` job: scaffolder dry runs of all four templates and the
rendered service's own checks.

### OIDC trust (00-bootstrap)
`sub` embeds immutable IDs: `repo:surya-idp@334455734/<repo>@<repo_id>:ref:refs/heads/main`
(org since 2026-09-27; repo IDs survived the transfer).
- idp-github-ci, StringEquals: `feature-flag-service@1368152185`, `idp-portal@1389614591`.
- idp-service-ci, StringLike: `repo:surya-idp@334455734/*:ref:refs/heads/main` (user-approved
  exception; the role can only touch ECR `svc/*`).
- idp-infra-plan, StringEquals: `idp-infra@1381729533` main + `pull_request` (read-only plan, F7).
Renaming a repo changes `sub` (the name is in it): update the trust before pushing (Finding 50).

### GitHub Apps
| App | ID | Installed on | Used by |
|---|---|---|---|
| `idp-ci-bot` (was ff-idp-ci-bot) | 5034584 (installation 165415314) | org surya-idp, only idp-gitops | Argo CD Image Updater in the cluster, for every app's tag commits. The repository secrets `FF_IDP_CI_BOT_APP_ID` / `FF_IDP_CI_BOT_PRIVATE_KEY` were deleted from feature-flag-service and idp-portal on 2026-10-11; the key now exists in `~/.idp` and, while the cluster is up, in Secrets Manager |
| `idp-backstage-surya` (was ff-idp-backstage; NOT "idp-backstage") | 5088974 (client Iv23lij5ChFBE8WFtPEH) | org surya-idp, All repositories | Backstage catalog + scaffolder + GitHub sign-in. Credentials in `~/.idp` (700/600), never in Git or TF state. Actions: read not granted yet (Step 31) |

Both Apps are owned by org surya-idp (transferred 2026-09-27; IDs, client ID and keys unchanged).
Only `idp-ci-bot` bypasses the idp-gitops ruleset (since 2026-10-10). `idp-backstage-surya` opens
PRs and merges them only when the required `validate` check is green; "Allow auto-merge" and
"Delete head branch on merge" are on for idp-gitops.

## 12. Key Terraform Snippets

### RDS (20-data/main.tf) — FIXED (Session 3)
```hcl
resource "random_password" "db" {
  length  = 32
  special = false  # avoid chars that break connection strings
  upper   = true
  lower   = true
  numeric = true
}

resource "aws_db_subnet_group" "postgres" {
  name       = "idp-postgres"
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
}

resource "aws_db_instance" "postgres" {
  identifier             = "idp-postgres"
  engine                 = "postgres"
  engine_version         = "16"
  # t4g.micro + gp3 had NO CAPACITY in ap-south-1a/b. Switched to t3.micro + gp2.
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  db_name                = "feature_flags"
  username               = "ffidp"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.sg_rds_id]
  publicly_accessible    = false  # CRITICAL — never true
  skip_final_snapshot    = true   # CRITICAL for Option B — false = $31/month snapshots
  deletion_protection    = false
  backup_retention_period       = 0
  performance_insights_enabled  = false
  tags = { Name = "idp-postgres" }
  lifecycle {
    ignore_changes = [final_snapshot_identifier]  # timestamp() re-evaluates every plan
  }
}
```

### EKS Node Group (30-cluster/main.tf) — FIXED (Session 3)
```hcl
  eks_managed_node_groups = {
    spot = {
      # Account restricts Spot to free-tier-eligible types only (t3.medium rejected).
      # Switched to t4g.small (Graviton, free-tier eligible) and ON_DEMAND.
      instance_types = ["t4g.small"]
      capacity_type  = "ON_DEMAND"
      
      # EKS rejects mismatched AMI architectures (cannot mix x86 and ARM). 
      # Must explicitly define ARM64 for t4g instances.
      ami_type       = "AL2023_ARM_64_STANDARD"

      min_size     = 2
      max_size     = 3
      desired_size = 2
    }
  }
```

### scripts/verify-empty.py — FIXED (Session 3)
```python
        # KMS keys are $0 while PendingDeletion
        if ":key/" in arn:
            free_or_pending.append(f"{arn} (Pending Deletion / Free)")
            continue
            
        # NAT Gateways in "deleted" state cost $0, but AWS Tagging API caches them for ~1 hour.
        # Must check the actual live state dynamically via ec2 describe-nat-gateways.
        if ":natgateway/" in arn:
            gw_id = arn.split("/")[-1]
            state_check = subprocess.run(["aws", "ec2", "describe-nat-gateways"...])
            if state_check.stdout.strip() == "deleted":
                free_or_pending.append(f"{arn} (Deleted state)")
                continue
```

---

## 13. Real-World Findings and Gotchas

### From Steps 1-16 (Already in README)
1. p95 latency ~0.97s — not sub-50ms. Root cause: Postgres fetch ~780ms every request.
2. CrashLoopBackOff vs readiness failure — fail-fast startup bypasses probes.
3. Secret-template GitOps trap — Argo CD picks up any `kind: Secret` in watched path.
4. Kyverno optional-match `=(field)` bug — policy enforced nothing silently.
5. CRD size limit → `kubectl apply --server-side`.
6. Argo CD selfHeal fighting manual `kubectl apply`.
7. conntrack stickiness on sequential in-cluster requests (not yet in README).

### From Steps 17-22 (New Findings 2026-09-22)

**Finding 1: AWS rejects em-dashes in ALL description/GroupDescription fields**
- APIs affected: EC2 `CreateSecurityGroup` (`GroupDescription`), ElastiCache `CreateReplicationGroup` (`description`)
- Error: `InvalidParameterValue: Character sets beyond ASCII are not supported` (EC2) or `non-printable control characters` (ElastiCache)
- Rule: Use ASCII hyphens (-) ONLY in ALL description fields in ALL Terraform resources
- This applies to EVERY future resource with a description field

**Finding 2: ElastiCache has NO stop API**
- `aws elasticache stop-replication-group` — does not exist (invalid choice)
- Unlike RDS which has `stop-db-instance` (pauses compute, keeps storage)
- ElastiCache options: running ($0.016/hr) OR destroyed. Nothing in between.
- Consequence: Must live in 30-cluster (destroyed nightly), cannot live in 20-data
- $0.016/hr × 24 × 30 = $11.52/month if kept in 20-data with no stop

**Finding 3: RDS final snapshots accumulate silently**
- With `skip_final_snapshot = false`, every `terraform destroy` creates a snapshot
- 12 destroys/month × 20GB × $0.131/GB-month = $31.44/month in orphaned snapshots
- Check RDS Snapshots in console and delete manually if any exist from accidents
- Solution: `skip_final_snapshot = true` in ALL lab/portfolio RDS configs

**Finding 4: timestamp() causes permanent Terraform drift**
- `timestamp()` re-evaluates on every `terraform plan` → shows change every time
- Fix: `lifecycle { ignore_changes = [field_that_uses_timestamp] }`

**Finding 5: Python heredoc in Makefile requires tab on EVERY line**
- Multi-line Python inside a Makefile heredoc must have tab (not spaces) on each line
- Nearly impossible to maintain correctly → moved to `scripts/verify-empty.py`

**Finding 6: Dynamic OIDC thumbprint is critical**
- Do NOT hardcode the GitHub Actions OIDC thumbprint
- Use `tls_certificate` data source to fetch at apply time
- GitHub rotates their cert periodically — hardcoded thumbprint will break

**Finding 7: RDS console visibility**
- RDS instances only appear in the AWS console region selector for the region they were created in
- Must be on `ap-south-1` (Asia Pacific Mumbai) in the console to see idp-postgres
- After `terraform destroy 20-data`, the DB disappears — this is correct

### New Findings (Session 3 / Step 23)
**Finding 14: AWS Region Capacity Exhaustion:** `ap-south-1` completely ran out of `db.t4g.micro` and `gp3` combination capacity. Workaround applied: dropped back to x86 `db.t3.micro` and standard `gp2` storage.
**Finding 15: New-style Free Tier Spot Restrictions:** Recent AWS accounts aggressively block EC2 Spot instance requests for non-free-tier instance sizes (e.g., `t3.medium`). The API throws a misleading `InvalidParameterCombination` error. Workaround: Switch to `ON_DEMAND` or strictly use `t4g.small` / `t3.micro`.
**Finding 16: EKS Node Group Architecture Lock:** EKS Managed Node Groups strictly evaluate the underlying AMI architecture. If you request a Graviton (`t4g`) instance, you MUST explicitly override the default `ami_type` to `AL2023_ARM_64_STANDARD`. You cannot provide a fallback array mixing x86 and ARM sizes.
**Finding 17: AWS Tagging API Ghosting:** `aws resourcegroupstaggingapi` will confidently return ARNs for resources that cost $0 or are already destroyed. NAT Gateways linger for 1 hour after hitting the `"deleted"` state. KMS keys linger for the entirety of their mandatory 7-day `"PendingDeletion"` window. Scripts checking for billing leaks must query the active state (e.g., `describe-nat-gateways`), not just check for the ARN's existence.


### New Findings (Session 4 / Step 25)
**Finding 18: GitHub OIDC Thumbprint Drift:** The dynamic `tls_certificate` data source fetches the leaf certificate thumbprint, but AWS STS occasionally expects intermediate/root thumbprints, leading to `AssumeRoleWithWebIdentity` failures. Fix: Hardcode well-known AWS thumbprints alongside the dynamic one.
**Finding 19: CI Cross-Compilation Requirement (Exec Format Error):** EKS nodes (`t4g.small`) are ARM64, but GitHub Actions runner (`ubuntu-latest`) builds x86_64 images by default, causing `CrashLoopBackOff (exec format error)`. Fix: Updated CI to use `docker/setup-qemu-action` and `buildx` for `linux/arm64`.
**Finding 20: Missing Python Dependency Crash:** `20-data/main.tf` stored the DB URL as `postgresql+asyncpg://`, but the app uses synchronous SQLAlchemy (`create_engine`) with `psycopg2`. This caused a `ModuleNotFoundError: No module named 'asyncpg'` crash on startup. **FIXED Session 5** (uncommitted): `20-data/main.tf` now emits `postgresql+psycopg2://`.
**Finding 21: EKS t4g.small ENI Pod Limit Exhaustion:** `t4g.small` nodes have a default max-pods limit of 11. ArgoCD, ESO, ALB Controller, and CoreDNS completely filled both nodes, causing API pods to be stuck in `Pending` (`Too many pods`). **FIXED Session 5** (uncommitted, untested on a live cluster): vpc-cni addon `ENABLE_PREFIX_DELEGATION=true` + `before_compute`, and node group `cloudinit_pre_nodeadm` sets kubelet `maxPods: 110`. VERIFY after next `make up`: `kubectl get node -o jsonpath='{.items[*].status.allocatable.pods}'` should show 110.
**Finding 22: Out-of-band ALB blocks VPC Destruction:** ALBs created by the AWS Load Balancer Controller are not managed by Terraform. `make down` fails to destroy the VPC because the ALB is still attached to the subnets. **FIXED Session 5**: `scripts/down.sh` deletes Ingresses, then any leftover ALBs/target groups in the project VPC, before destroying layers.
**Finding 23: Non-empty ECR blocks make down:** `aws_ecr_repository` cannot be destroyed if it contains images. **FIXED Session 5**: `force_delete = true` on the ECR repo.

### New Findings (Session 5 - cost audit)
**Finding 24: Orphaned RDS final snapshot.** `idp-postgres-final-2026-09-22` (20GB, ~$2.62/mo) was left by the first destroy, before `skip_final_snapshot=true`. `make verify-empty` reported OK because the Tagging API does not surface it. Deleted manually 2026-09-26.
**Finding 25: Tag-based verification is not enough.** Snapshots, controller-created ALBs, ENIs and PVC volumes are not reliably visible via `resourcegroupstaggingapi`. `verify-empty.py` now ALSO queries each service directly (EKS, EC2, NAT, EIP, ELB, RDS + snapshots, ElastiCache, EBS + snapshots, Secrets, VPC endpoints, ECR, CloudWatch logs).
**Finding 26: `|| true` hid failed destroys.** `make down` now runs `scripts/down.sh`, which continues through all layers but exits non-zero and lists what failed. Never close the laptop on a non-zero exit.
**Finding 28: GitHub OIDC `sub` claim now embeds immutable IDs.** CI failed with "Not authorized to perform sts:AssumeRoleWithWebIdentity" for days. CloudTrail (ap-south-1, `AssumeRoleWithWebIdentity`) showed the real subject: `repo:DSurya11@162597218/feature-flag-service@1368152185:ref:refs/heads/main`. The old `repo:OWNER/REPO:...` form (and a hand-made wildcard) never matched. Fixed in `00-bootstrap` with the exact new subject, no wildcard. The live role had also drifted from Terraform (console edit) - Terraform now owns it again. Debug tip: read the principal in the failed CloudTrail event.
**Finding 29: ECR must not live in a destroyed layer.** It was in 30-cluster, so each `make down` either failed (non-empty repo) or, with force_delete, wiped all images. Moved to permanent layer `15-registry` (NOT part of make up/down; apply once). CI pushes there.
**Finding 30: ALB controller was never installed by any code.** Session 4 must have installed it by hand. Now a `helm_release` in 40-platform (chart 3.5.0, IAM policy v3.5.0). ESO must depend on it: the controller's mutating webhook covers ALL Services, so installing anything in parallel fails with "no endpoints available".
**Finding 31: Prefix delegation works.** `vpc-cni` addon with `ENABLE_PREFIX_DELEGATION` + `before_compute`, plus kubelet `maxPods: 110` via `cloudinit_pre_nodeadm`: both nodes report 110 allocatable pods (was 11).
**Finding 32: Trivy could not scan the pushed image.** buildx pushes without loading into the local daemon, and the image is arm64 on an amd64 runner. Fix: `TRIVY_USERNAME/PASSWORD` from `aws ecr get-login-password`, `TRIVY_PLATFORM=linux/arm64`, and `--provenance=false` on the build.
**Finding 33: The CI bot could not update env-config - FIXED 2026-09-26.** The `ff-idp-ci-bot` GitHub App existed but had 0 installations (`GET /app` showed `installations_count: 0`; token minting returned 404). Installed on `idp-gitops` only; verified by an empty-commit CI run: all 3 jobs green and `ff-idp-ci-bot[bot]` committed the new SHA. Diagnostic that works: sign an app JWT with the private key and call `GET /app/installations` (never print the key).
**Finding 34: Fresh RDS has no schema; the app does not migrate itself.** AUTOMATED and VERIFIED LIVE 2026-09-26: `eks-db-migrate-job.yaml` in env-config is an Argo CD Sync-hook Job (`alembic upgrade head`) on sync-wave 1; the Deployment is wave 2; ExternalSecret/namespace wave 0. Evidence: job ran `initial_schema` and completed 13:12:39Z, API pods created 13:12:39-40Z (after), `/health` 200 and flag create/evaluate work with no manual alembic. A second sync re-ran the Job as a no-op (already at head) and did not restart the API pods. CI bumps the image in both `eks-api-deployment.yaml` and `eks-db-migrate-job.yaml`. Fallback by hand: `kubectl exec -n feature-flag-dev deploy/feature-flag-api -- sh -c "cd /app; alembic upgrade head"`.
**Finding 36: Tag API ghosts purged NAT gateways.** ~1h after deletion AWS purges a NAT gateway, but `resourcegroupstaggingapi` still lists its ARN and `describe-nat-gateways --nat-gateway-ids` fails with `NatGatewayNotFound`. `verify-empty.py` treated that as billable (false alarm, make down exited non-zero). Fixed: NotFound = free. The direct service checks were empty the whole time.
**Finding 37: An interrupted `make down` leaves billable resources.** A teardown that was cut off (session/process ended) left the NAT gateway, its EIP and RDS running (~$0.09/hr) while EKS and Valkey were already gone. `make down` is idempotent: just re-run it. After ANY interruption, run `make verify-empty` (or query EKS/NAT/RDS directly) before closing the laptop. Do not start `make down` and walk away from the session.
**Finding 35: Argo root app YAML bug.** `syncOptions` must be under `spec.syncPolicy`, not `spec`. Root app is manual-sync and scoped by `directory.include` to the EKS manifests until Step 27.
**Finding 38: Argo CD v2.13 vs Kubernetes 1.35 schema skew.** With `ServerSideApply=true`, Argo's structured-merge diff fails on the live Deployment: `.status.terminatingReplicas: field not declared in schema` (field added in k8s 1.33). Sync status goes `Unknown` and auto-sync silently stops; the FIRST sync works (nothing live to diff), so it only shows on the second deploy. Workaround: no ServerSideApply on `feature-flag-dev`. Real fix (TODO): upgrade the Argo CD chart (7.7.3 = v2.13, tested only to k8s ~1.31) to a release that supports 1.35.
**Finding 39: selfHeal vs teardown.** With automated sync + selfHeal, deleting the Ingress in `make down` would just be recreated. `down.sh` now deletes the `root` Application first; finalizers cascade root -> children -> resources, so the Ingress (and the ALB, via the still-running controller) is gone before Terraform runs. Verified: ALB list empty before 40-platform destroy.
**Finding 40: App-of-apps needs an Application health check.** Argo CD 1.8+ reports no health for Application resources, so child sync waves are not waited on. 40-platform adds the upstream `resource.customizations.health.argoproj.io_Application` Lua. Verified: platform-cluster (wave 0) synced 14:45:57, feature-flag-dev (wave 1) created 14:45:59.
**Finding 41: HPA in an early sync wave deadlocks Argo CD v3.** Argo CD v3 health-checks HPAs; one whose target Deployment does not exist yet is Degraded. In wave 0 (default) it blocked the wave-2 Deployment forever ("unable to get the target's current scale ... not found", sync retrying). Fix: HPA and PDB on wave 3, after the Deployment.
**Finding 42: EKS metrics-server add-on needs port 10251 open.** The terraform-aws-modules/eks node SG allows cluster->node only on 443/4443/6443/8443/9443/10250; the add-on serves on 10251. Symptom: pods Running but `kubectl top` says "Metrics API not available", APIService "failing or missing response ... :10251 context deadline exceeded", HPA shows `<unknown>`. Fix: `node_security_group_additional_rules` for 10251 from the cluster SG.
**Finding 43: Argo CD upgraded 7.7.3 (v2.13) -> chart 10.9.2 (v3.5.3).** Fresh install each session, so no in-place migration. Dropped `application.namespaces` from argocd-cm (it belongs in cmd-params, and was unused). ServerSideApply stays off on feature-flag-dev (not needed; SSA was not re-tested on v3).
**Finding 44: Preemption ignores PodDisruptionBudgets (Step 28).** First drain test under load: 105/14258 requests failed (502/503/504 in a ~10s window). Isolated by re-running each event alone with per-failure logging: rolling restart alone = 0 failures; steady state = 0; drain with no API pod on the node = 0; drain of the node holding an API pod = 82 failures. Events showed `Preempted by pod ...` on BOTH API replicas: after the drain, everything had to fit on one t4g.small (memory requests 82%), a system-cluster-critical pod (ebs-csi-controller) could not schedule, and the scheduler preempted the lowest-priority pods - the API, at priority 0. PDBs only govern evictions, not preemption. Fixes: (1) `business-critical` PriorityClass (1e6) for the API, (2) zone topology spread, (3) realistic node replacement = surge a node first (what EKS managed node group updates do), not drain with zero headroom. Root cause is capacity: 2x 2GiB nodes cannot absorb a whole node. Also: ebs-csi-controller runs 2 replicas x 6 containers and nothing uses EBS yet - a candidate to remove to free memory.
**Finding 45: Step 28 proof (final run).** Under 20 rps constant k6 load through the ALB: GitOps rollout (push -> Argo) + node group surge 2->3 + drain of a node holding an API pod: **28,800 requests, 0 failed, p95 43.8 ms**. The drain logged "Cannot evict pod as it would violate the pod's disruption budget" x5 - the PDB held the second replica until its replacement was Ready. HPA burst (150 iterations/s = 300 req/s): CPU 26% -> 329% of request, scaled 3 -> 4 (max) in ~30 s, **53,602 requests, 0 failed, p95 73 ms**. Mechanisms: maxUnavailable 0 / maxSurge 1, ALB pod readiness gate (namespace label), preStop sleep 20s > ALB deregistration delay 10s, PDB minAvailable 1, HPA owns replicas (none in Git). Reproduce: `tests/rollout-load.js` (logs every failure with timestamp + status).
**Finding 46: Backstage image failed the Trivy gate - 27 HIGH/CRITICAL, none in app code.** Sources: (a) the node base image's global npm (bundled tar/brace-expansion/ip-address) - npm is never used at runtime, so the Dockerfile now deletes npm/npx; (b) tar 6.2.1 under node-gyp 10 + cacache (18 findings; fixes exist only in tar 7) - the scaffold pins node-gyp ^10, bumped to ^13 (tar ^7, no cacache); (c) protobufjs 7.5.5 via @google-cloud/firestore - `yarn up -R protobufjs` -> 7.6.6. Result: Trivy clean. Lesson: read the file PATH in Trivy output before touching dependencies - most findings were in tooling the app never loads.
**Finding 47: RDS PostgreSQL 16 enforces SSL (rds.force_ssl=1).** psycopg2 negotiates SSL by default (the API just works); Node's `pg` does not. Backstage config sets `ssl.ca` to the bundled RDS global CA (verified TLS, not rejectUnauthorized:false).
**Finding 48: Duplicate GitHub Actions runs + immutable ECR tags.** GitHub started two runs for one push; the second failed pushing the same immutable tag. idp-portal CI now has `concurrency: ci-${{ github.sha }}` with cancel-in-progress. feature-flag-service CI has the same latent issue (and "Re-run" of a green build would also fail on the immutable tag). FIXED 2026-09-27 in both repos: concurrency per event+SHA, "image already in ECR" check (re-runs skip the push), and a rebase-and-retry loop for the bot push to idp-gitops (several CI bots now push there). feature-flag-service build also moved to the native `ubuntu-24.04-arm` runner (no QEMU).
**Finding 49: Terraform state was never locked.** The DynamoDB lock table existed, but no backend referenced it (`dynamodb_table` was only in this doc's example), so two concurrent applies could have corrupted state. Found during the rename migration. All backends now set `use_lockfile = true` (S3-native lock, TF >= 1.10; `dynamodb_table` is deprecated). Verified: a second concurrent plan fails with "Error acquiring the state lock".
**Finding 50: Renaming a "permanent" layer is a state migration, not a find-and-replace.** S3 buckets and security groups cannot be renamed; IAM roles are replaced. Done as: `state rm` old bucket/table (kept as backup) -> apply new -> `s3 sync` state -> `init -reconfigure` per layer -> no-change plans prove code == AWS. The GitHub OIDC `sub` claim contains the repo NAME, so renaming a repo breaks CI until the trust policy matches (IDs are stable, names are not).
**Finding 51: Neon retired.** The Step 21 A/B was the only reason to keep the Neon project (Step 11, `90-legacy-neon`). With the result recorded (section 16a: p95 ~970 ms -> ~20 ms), the project was destroyed and the layer, its tfvars (Neon API key) and `make neon-plan` removed. Nothing deployed ever read from Neon after Step 21 (DATABASE_URL comes from idp/db-creds = RDS).
**Finding 56: Transferring a repo to an org silently drops security settings and ruleset bypass actors.** After moving the 4 repos to surya-idp (2026-09-27): secret scanning, push protection and CodeQL default setup were all back to disabled, and the idp-gitops ruleset kept its rules but lost its App bypass list (bot pushes to main would have been rejected). Repo IDs, secrets, rulesets, PRs and Dependabot config survived. Re-enabled/restored immediately; verified with a real CI bot push (dfb88f3, 6728c5e). Checklist for any transfer: re-check `security_and_analysis`, code-scanning default setup and each ruleset's `bypass_actors`.

**Finding 57: User input must not reach generated code (Session 9, first live template run).** A description typed with a trailing space was rendered into a Python docstring; the new repo's first CI run failed `ruff format --check`. The auto-merge action correctly refused to merge. Fix (idp-portal#26): trim the description, keep it out of code, write it into TOML/YAML with the Nunjucks `dump` filter; template CI renders a hostile description (quotes, colon, backslash, spaces, >100 chars).

**Finding 58: The scaffolder validates action input against the schema but does not apply schema defaults.** `idp:github:await-ci-auto-merge` declared `mergeMethod` and `timeoutMinutes` with zod `.default()`; both arrived `undefined`, GitHub rejected the mutation, and the timeout was `NaN` (no timeout at all). Unit tests called the logic with every option set, so only a real run showed it. Fix (idp-portal#27): defaults applied in the handler; the template passes both.

**Finding 59: An unpinned schema download broke the required check.** datreeio/CRDs-catalog updated its external-secrets.io schemas on 2026-10-08; kubeconform v0.8.0 cannot load the new ClusterSecretStore v1 schema ("could not find schema"), so `validate` went red on idp-gitops `main` with no change of ours, which would have blocked every PR including template deploy PRs. Fix (idp-gitops#10): `CRD_CATALOG_REF` pinned to the commit before that update. Related: the catalog's ImageUpdater schema was older than v1.3.1, so `validate.sh` now generates schemas from the CRDs a kustomization installs (`scripts/crd-schemas.py`).

**Finding 60: An image gate also fires on old code.** idp-portal had not been built since 2026-09-27; on the next merge its Trivy gate found 14 HIGH/CRITICAL fixable findings and (correctly) blocked the deploy, so the cluster kept the old Backstage image without the new action. Fix (idp-portal#23): 12 in-range lockfile updates; 2 findings inside `mockttp` (shipped by `@backstage/backend-openapi-utils`, never started; fixes are majors it does not accept) ignored in `.trivyignore` until 2026-12-10. Lesson: review Dependabot PRs before a session, or the first merge of the day pays for two weeks of drift.

**Finding 61: A commit SHA made only of digits breaks a kustomization.** `newTag: 0000...` is parsed as a number ("cannot unmarshal number into ... newTag of type string"). Found with the all-zero sample tag. The template now quotes `newTag`.
**Finding 27: Spend audit.** As of 2026-09-26, ~$1 of credits used over 3 sessions, consistent with the ~$0.73/session model. Cost Explorer lags ~24h and shows ~$0; use Billing > Credits for the real balance. All regions checked empty.

### Findings 62-93: packages 0-9 and the two cluster sessions (2026-10-10 and 2026-10-11)

Grouped by when they were found. "Fix" names the pull request. The full session tables are in
`~/projects/idp-study-guide/COMPLETION-PLAN.md` sections 5a and 5c.

**Found while building offline (2026-10-10)**

**Finding 62: The Kyverno CLI needs CRDs as files and guesses plurals.** Offline policy tests of a custom resource failed: `--crd-paths` wants files, and the CLI pluralises `Postgres` as `postgreses`, so a policy matching `postgres` never saw the test resource. Fix (idp-gitops#17, #16): the tests pass the CRD files and the policy lists both plural forms; the "good example" check was strengthened so that a policy that matches nothing cannot pass.

**Finding 63: PyYAML cannot load the Prometheus CRDs.** They contain the YAML `=` value tag, which `yaml.safe_load` rejects. Fix (idp-gitops#18): `scripts/yamlsafe.py`, a loader that knows the tag, used by every script.

**Finding 64: The Tempo chart moved.** The chart in the `grafana` Helm repository is deprecated. The stack uses the `grafana-community` chart 2.4.0 (idp-gitops#18).

**Finding 65: Attesting to a throwaway registry needs real authentication.** The shared workflow's self-test pushes to a registry started inside the job. `actions/attest` needs a Docker config entry for the registry and an authentication challenge, so an open registry does not work. Fix (idp-platform#2): the test registry runs with htpasswd basic auth.

**Finding 66: A metrics label lost the service's path prefix.** The route label of `http_requests_total` was built from the matched route, which does not include the `/<service>` prefix the router is mounted under, so dashboards could not tell services apart by path. Fix (idp-portal#32): the label is built from the request path with path parameters replaced by their names; a test pins it.

**Finding 67: Removing a resource left an output pointing at it.** idp-infra CI failed after External Secrets left Terraform: `40-platform/outputs.tf` still referenced `kubernetes_namespace.external_secrets`. `terraform validate` in CI caught it before any apply (idp-infra#22).

**Finding 68: Four quick merges committed image tags out of order.** After the batch merge of 2026-10-10, idp-portal's CI runs finished in a different order than their commits and the deploy repository ended up pointing at an older image until a job was re-run by hand. Root cause: each CI run commits its own tag. Removed by design in package 8 (Finding 79, Finding 86).

**Finding 69: The flag API answered 500 for an invalid PATCH.** Written while adding API tests: a PATCH that made a flag inconsistent (for example a rollout percentage on a boolean flag) raised a `ValidationError` that nothing caught. Fix (feature-flag-service#2): it is a 422 with the reason. Same change: uvicorn keep-alive raised to 75 s, above the load balancer's 60 s idle timeout, so the load balancer never reuses a connection the server has just closed.

**Found in session A (2026-10-11)**

**Finding 70: The platform no longer fitted on `t4g.small` nodes.** Argo CD's repo server was OOMKilled at its 256Mi limit while rendering the charts of the platform, and one 2 GiB node went NotReady from memory exhaustion: the application controller had no memory request, so the scheduler placed it as if it were free. Fix (idp-infra#24): three `t4g.medium` nodes; memory requests and limits for the repo server and the controller. Cost went from ~$0.26 to ~$0.33 an hour. Lesson: a pod without a request is invisible to the scheduler.

**Finding 71: The database operator's pod was refused by pod security.** Its namespace enforces the `restricted` level and the chart's pod had no seccomp profile. Fix (idp-gitops#21): `podSecurityContext` with `runAsNonRoot` and `seccompProfile: RuntimeDefault` in the chart values.

**Finding 72: Two applications were permanently OutOfSync.** `kyverno` and `monitoring-stack` showed OutOfSync although nothing differed that a person had written: the API server fills in defaults (in CRDs and in the PodMonitor) that are not in the rendered manifest, and self-heal kept re-applying an identical manifest. Fix (idp-gitops#21): `ServerSideDiff=true` for both, so Argo CD compares with what the API server would store. Both were Synced without help in session B.

**Finding 73: Alertmanager never started.** The operator refused the configuration: `undefined receiver "null" used in route`. Helm merges maps but replaces lists: our `receivers` list replaced the chart's default list, while the chart's default *route* to the receiver `null` (for the Watchdog alert) survived the merge. Alerts were firing in Prometheus with nowhere to go. Fix (idp-gitops#22): the route and the `null` receiver are written out; `scripts/alertmanager-check.py` now fails `validate` when any route names a receiver that is not defined.

**Finding 74: The provenance policy rejected every correctly signed image.** `gh attestation verify` passed, the policy reported "no build provenance". The signing certificate names the workflow by the ref its caller used; services pin the workflow by commit, so the name ends in a commit id, and the policy accepted only `refs/heads/main` and `refs/tags/v*`. Fix (idp-gitops#24): the commit of each release is listed explicitly. Not "any commit": a commit on an unreviewed branch would then count as a trusted signer. Consequence: every idp-platform release needs its commit added (idp-gitops#35, #39).

**Finding 75: Two alert rules were wrong in ways the unit tests did not see.** `ServiceDown` (`sum(up) == 0`) cannot fire when a service has no pods at all: no pods, no `up` series, and "no data" is not "equal to zero". `PodRestarting` arrived with `service="kps-kube-state-metrics"`, the exporter's own label. Fix (idp-gitops#25): a new alert `NoPodsAvailable` from `kube_deployment_status_replicas_available`, and an aggregation that keeps only the pod's labels; both with unit tests, including one that shows `ServiceDown` staying silent in the zero-pods case.

**Finding 76: Every pull request was validated twice.** The `validate` workflow ran on every branch push and on `pull_request`, so the same commit was checked two times. Fix (idp-gitops#29): pushes are checked on `main` only.

**Finding 77: A check that failed for the wrong reason.** The session's check script queried Prometheus with `wget` inside its pod; the image has neither `wget` nor `curl`, so the check reported "no scrape targets" on a healthy stack. Fix: query through a port-forward. Lesson: when a check fails, first make sure the check itself can succeed.

**Finding 78: Decommissioning left two things behind.** The service's Postgres login role and its empty namespace. The operator drops a role only while its database exists and is *not being deleted*; removing a service deleted both at the same moment. And a namespace created by `CreateNamespace=true` belongs to no application, so nothing deletes it. Fix (idp-gitops#31): the service declares its own namespace (the `golden-path` component), and sync waves order namespace -3, database -2, login -1, everything else 0 or later. Argo CD 3.5 deletes an application in reverse wave order (`controller/sort_delete.go`). Verified in session B: nothing left.

**Found between the sessions (2026-10-11)**

**Finding 79: Two merges seconds apart built in parallel.** After moving the two platform apps to Image Updater, two quick merges of the flag API built side by side and the older commit's image was pushed second. Image Updater's rule is "newest build wins". First fix (idp-platform#3 = v2.1.0, feature-flag-service#6, idp-portal#37): a concurrency group, one build per branch at a time. Not sufficient: Finding 86.

**Finding 92: The monitoring data stores were reachable from any pod.** Seen in session A: Grafana answered a probe from an unrelated namespace (it still needs its password; Prometheus, Alertmanager and Loki have no login at all). Fix (idp-gitops#34): a NetworkPolicy that lets only the `monitoring` namespace connect to Grafana, Prometheus, Alertmanager, Loki and the alert receiver, plus Backstage to Grafana. Tempo (traces arrive from every namespace) and the Prometheus operator (its webhook is called by the API server, whose address cannot be told apart from pods with the VPC CNI) are deliberately outside it. Verified in session B.

**Found in session B (2026-10-11)**

**Finding 80: A just-created Application reports Healthy.** It has no resources yet, so nothing is unhealthy. Two consequences. (a) The root app moved on to wave 0 while External Secrets (wave -1) was still installing; the database operator's ExternalSecret was rejected by a webhook that did not exist yet, and the sync then waited forever for a pod that needed that Secret. (b) `make up` printed "Environment ready" 3 minutes in, and `make e2e` right after it failed 31 checks. Fixes: the Application health check says Progressing until the first sync has finished and while one is running (idp-infra#28); the operator's ExternalSecret is in an earlier wave than its Deployment, so a rejection fails the sync and is retried (idp-gitops#37); `make up` waits for the root app's sync operation to succeed and exits 1 otherwise (idp-infra#30). Session A did not hit this: it is a race.

**Finding 81: A new service waited 2.5 minutes to be noticed.** Argo CD's 60-second polling (idp-infra#25) applies to existing Applications. *Discovering a new folder* is the ApplicationSet's git generator, with its own 3-minute default. Fix (idp-gitops#37): `requeueAfterSeconds: 60`. Form to running pod went from 4 min 58 s to 2 min 36 s.

**Finding 82: Dependabot's runs were counted as CI.** GitHub starts three "Dependabot Updates" runs for the first commit of a new repository, listed with `event: dynamic` beside the real workflow run. `idp:github:await-ci-auto-merge` treated every run of the commit as CI: the log linked a Dependabot run as "CI passed", and had they all finished before the real run was listed, the deploy pull request would have merged for an image that did not exist. Fix (idp-portal#39): runs with event `dynamic` are ignored.

**Finding 83: "Loading chunk failed" after Backstage redeploys.** Not a platform fault: a browser tab opened before a rollout still holds the old page and asks for files only the old version had. Reload the tab. It appears more often now because Backstage redeploys itself a few minutes after `make up` whenever a newer image exists.

**Finding 84: Policy reports arrived up to an hour late.** A new service's image had been verified at admission, but no policy report existed 50 minutes later. Reports for running resources are written by Kyverno's background scan: at start, then every hour by default. Fix (idp-gitops#38): `backgroundScanInterval: 10m`. Confirmed on the next service: reports within about 90 seconds. Enforcement at admission never depended on it.

**Finding 85: The flag helper remembered a default.** `is_enabled("x")` followed by `is_enabled("x", default=True)` returned False: the first call's fallback was cached as if it were the flag's answer. Found by calling the helper from a real pod. Fix (idp-portal#40): only real answers from the flag service are cached. The test that should have caught it cleared the cache between its two calls.

**Finding 86: A concurrency group does not order builds: the older of two quick pushes was deployed.** Check 9 of session B. Two commits pushed one second apart: GitHub ran the *newer* commit's image job first and the older one second, so the older commit's image was built last and Image Updater deployed it. Fix (idp-platform#4 = v2.1.1, feature-flag-service#7, idp-portal#41): before pushing, the job asks GitHub for the branch head and skips the push when a newer commit exists; that commit's own run pushes. Either order now ends with the newest commit built last. Proven by repeating the test: only the newest commit's image reached ECR.

**Finding 87: Decommissioning did not know about flags and docs.** Both features were added after the template was written: the service's flag stayed in the flag API and its documentation stayed in the (permanent) docs bucket. Fix (idp-portal#43, idp-infra#29): two more steps, `idp:flags:delete-for-service` and `idp:aws:s3:delete-docs`, both admin-only, both fine with "there are none"; Backstage's role may delete under `default/component/*` only. Verified: 1 flag and 53 files deleted, nothing left anywhere.

**Finding 88: `InfoInhibitor` is not an alert about anything.** It fires whenever an info-level alert does (here: CPU throttling while Argo CD started) and exists only to mute those. It failed `make e2e` on a healthy platform and was delivered to the receiver. Fix (idp-infra#30, idp-gitops#41): the test counts only warning and critical alerts; the route sends `InfoInhibitor` to the `null` receiver with `Watchdog`.

**Finding 89: The recovery drill was interrupted twice by the laptop, not by the platform.** `make down` took 17 min 16 s and was clean. `make up` then (a) stopped after 51 seconds because the single sign-on session had expired (`unable to refresh SSO token ... InvalidGrantException`; `aws sts get-caller-identity` still worked from a cached role credential, which hid it), and (b) on the next attempt failed at the last layer after 29 minutes with `dial tcp ...:443: i/o timeout`, because the laptop had been on a different network when the run started and the cluster's allowed address no longer matched. Re-running `make up` on one network finished it. Lessons: log in again before a long run; check the login with the cache file's expiry, not with `sts`; stay on one network; `make up` is safe to repeat.

**Finding 90: An archived repository keeps its name.** Creating a service with the name of a decommissioned one failed at "Create GitHub repository": `name already exists on this account`. A second attempt with a different name failed the same way, because the form's Name field is a repository picker whose autocomplete had put the old name back. Fix (idp-portal#44): `decommission-service` has an optional, off-by-default "delete the repository instead of archiving it" box for throwaway services; the action refuses the platform's own repositories whatever its input. The GitHub App needed no new permission (it archives with `administration: write` already). Not run for real yet.

**Finding 91: The credits had expired two weeks earlier.** Found on 2026-10-11 when the credits page was opened for another reason: every credit `Expired`, status date 2026-09-27, $0.00 active. The page that was being read showed "$196.80 remaining" because it was the *inactive* tab. Cost Explorer: September usage $3.23 fully covered by credit; October usage billed with none. Likely cause, not confirmed by AWS: enabling IAM Identity Center on 2026-09-27 created an AWS Organization, and a Free Tier plan account that creates or joins an Organization is moved to the paid plan and its credits expire. The sessions of 2026-10-10 and 2026-10-11 were therefore paid for (estimate $4-6). Lessons: a security improvement (F1) had a billing side effect nobody checked; "credits remaining" must be read from the active tab on the day; this document's cost plan was treated as true for two weeks without being re-checked.

**Finding 93: A compiled Python file was in the deploy repository.** `scripts/__pycache__/yamlsafe.cpython-314.pyc` had been committed with the script. Found while listing every tracked file for the documentation. Removed; a `.gitignore` keeps caches out.

**Working-practice notes from these two days** (mistakes of the assistant, kept because they will happen again): a `pkill -f` pattern matched its own shell; a throwaway backend on port 7007 clashed with a port-forward (template CI now uses 7107); a local `main` that had not been pulled made a correct edit fail; a probe against the wrong path lost a timing; a statement that the AWS login was valid was based on `sts` instead of the session file.


---

## 14. Target env-config Structure (Step 27)

```
idp-gitops/
  platform/
    argocd-apps/
    eso/
    kyverno/
    monitoring/
    backstage/
  
  apps/
    feature-flag-service/
      base/
        deployment.yaml
        service.yaml
        ingress.yaml
        servicemonitor.yaml
        externalsecret.yaml    ← ExternalSecret only — NO kind:Secret in git
        hpa.yaml
        kustomization.yaml
      overlays/
        dev/
          kustomization.yaml   ← CI updates image SHA here
          patch-replicas.yaml  ← replicas: 2
        staging/
          kustomization.yaml
          patch-replicas.yaml  ← replicas: 2
        prod/
          kustomization.yaml
          patch-replicas.yaml  ← replicas: 3
          pdb.yaml             ← PodDisruptionBudget minAvailable: 2
  
  applicationsets/
    feature-flag-appset.yaml
```

### Sync Policy by Environment
| Environment | Sync | Gate |
|---|---|---|
| dev | Automated | None — any merged PR deploys |
| staging | Automated | Promotion PR required |
| prod | Manual sync | Deliberate human action required |

---

## 15. Secrets Strategy (Steps 21 + 24)

### Secrets Manager Entries
| Secret Name | Contents | Who reads it |
|---|---|---|
| `idp/db-creds` | password, url | ESO → K8s Secret → app |
| `idp/jwt-secret` | JWT_SECRET_KEY | ESO → K8s Secret → app |
| `idp/grafana-admin` | admin-password | ESO → K8s Secret → Grafana |
| `idp/backstage-github-app` | GitHub App private key, app ID | ESO → K8s Secret → Backstage |

### ESO Pattern
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: feature-flag-secrets
  namespace: feature-flag-dev
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: feature-flag-secrets
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: idp/db-creds
        property: url
    - secretKey: JWT_SECRET_KEY
      remoteRef:
        key: idp/jwt-secret
        property: JWT_SECRET_KEY
```

Why ESO matters: No `kind: Secret` exists in Git at all. Structurally eliminates the secret-template GitOps trap from Step 13.

### Verification (NEVER echo plaintext)
```bash
kubectl get secret feature-flag-secrets -n feature-flag-dev \
  -o jsonpath='{.data.JWT_SECRET_KEY}' | base64 -d | sha256sum
# Compare hashes before/after rotation — never compare plaintext values
```

---

## 16. The Latency Story (A/B Experiment — Step 21)

### Current Finding (Step 16, Neon)
- p95: ~0.97s
- Redis: ~0.6ms (fast)
- Postgres fetch: ~780ms (slow — every request)
- Neon pooled endpoint used
- Root cause NOT isolated

### A/B Experiment Plan (do after Step 23 cluster is up)
- One variable changed: Neon over WAN → RDS in same VPC as pods
- Same code, same timing instrumentation (`time.perf_counter()` in `app/evaluation.py`)
- Same test: burst of /evaluate requests, check p95 from Prometheus histogram
- Keep Neon alive until this test is done (done 2026-09-26; Neon retired 2026-09-27)

### Possible Outcomes
| Result | Conclusion |
|---|---|
| p95 collapses to <10ms | Root cause was WAN RTT / TLS / Neon pooler hop |
| p95 stays high | Root cause is SQLAlchemy session/pool handling → add OpenTelemetry (Step 34) |

---

## 16a. Step 21 A/B RESULT (measured 2026-09-26, RDS in VPC, same code)
| Path | Neon over WAN (Step 16) | RDS in VPC, server-side (in-pod) | Via ALB from laptop |
|---|---|---|---|
| `/evaluate` p95 | ~970 ms | 20 ms (DB miss) / 30 ms (Redis hit) | ~58 ms |
DB miss p50 8.3 ms vs Redis hit p50 3.9 ms => Postgres fetch ~4 ms. ~48 ms floor via ALB = laptop-to-ALB RTT (`/health` identical). Conclusion: WAN RTT/TLS/pooler was the root cause, NOT SQLAlchemy session handling. Caveat: cluster also changed (kind -> EKS); the DB location is the dominant change. Reproduce: `test_latency.py` (header explains in-pod vs ALB modes). Neon (90-legacy-neon) is no longer needed for the experiment.

---

## 16c. Measured timings (2026-09-26, clean runs, ap-south-1)
| Operation | Time |
|---|---|
| `make up` (20-data + 30-cluster + 40-platform), first-try clean run | **26.6 min** (1596 s): RDS ~10 min, cluster ~10 min, platform ~6 min |
| Sync -> API serving through ALB (incl. migration) | ~1 min after ALB provisioning |
| `make down`, clean run | **16.4 min** (981 s); slowest steps: EKS node group drain, then control plane |
Build+teardown overhead is ~43 min of billing (~$0.20) even for a 5-minute test.

---

## 16b. Session Checklist (current, 2026-10-11)

No session is planned: cluster work is finished and cluster time is billed to the card
(section 0a, Finding 91). If one is run anyway:

1. Merge first, then `git pull` in idp-infra. 40-platform is applied from the local checkout and Argo CD reads idp-gitops `main`.
2. `aws sso login --profile idp` (username `surya`, not the email) **immediately before** `make up`, even if a login from the morning still seems to work (Finding 89).
3. Stay on one network. `TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32" make up` (~27 min). It exits 1 if the platform is not ready. If it fails for a laptop reason, run the same command again.
4. `make e2e`: 42 checks, exit code 0.
5. Backstage: `kubectl -n backstage port-forward svc/idp-portal 7007:7007` -> http://localhost:7007, sign in with GitHub. After Backstage redeploys (a few minutes after `make up` if a newer image exists, and after every merge to idp-portal): restart the port-forward and hard-reload the tab (Finding 83).
6. Template check: Create -> Python service -> check the name on the review page (Finding 90) -> the task must end green and `http://<ALB>/<name>/` must return 200 with no click after the form.
7. Clean up test services with the form: Create -> Decommission a service, with "delete the repository" ticked for throwaway services. Check afterwards: namespace gone, database and login gone, ECR repository gone, flags and docs gone.
8. `make down` must exit 0 and you must SEE it finish (Finding 37). Re-run it if interrupted. Then `make verify-empty`.
9. Claude cannot merge pull requests, push tags, run `terraform apply` or delete repositories in this setup: those are handed to the owner as exact commands.
10. Three things still worth doing in a session, because they were never verified: a second GitHub user being refused by the permission policy; the "delete the repository" box; opening the Grafana dashboard in a browser.

---

## 17. Remaining Steps — Full Specification

> **Status 2026-10-11: nothing in this section remains.** It is kept as the original
> specification, to compare the plan with what was built.
>
> | Step | Planned | What became of it |
> |---|---|---|
> | 23-30 | Cluster, GitOps, Backstage, templates | Done (see the DONE notes below) |
> | 31 | Backstage plugins: Argo CD, Kubernetes, GitHub Actions, Grafana, TechDocs | Kubernetes, GitHub Actions and TechDocs (S3) built and verified. Argo CD and Grafana plugins deliberately not built: one more stored credential for the first, no reachable address for the second |
> | 33 | Five more Kyverno policies | Eight policies on the new `policies.kyverno.io/v1` API, with offline tests; one of them verifies image provenance (audit) |
> | 34 | Alerting to Slack/Discord, Loki + promtail, Tempo | Prometheus, Grafana, Alertmanager, Loki, Alloy (promtail's successor), Tempo. Alerts go to a receiver inside the cluster that logs them: no chat token to store, the delivery path is the real one |
> | 35 | DR drill with `make nuke` and a final snapshot | Timed `make down` and `make up` plus `make e2e`. No snapshot: data is disposable by design. Teardown 17 min 16 s; rebuild about 40 min including a laptop-caused detour (Finding 89) |
> | 36 | Rewrite `test_e2e.sh` for EKS | `tests/e2e.sh`, 42 read-only checks, `make e2e` |

> Convention: every step must be verified with real command output before moving to next.

---

### PHASE B — Cluster (Cost Starts)

#### Step 23 — EKS Cluster (30-cluster) — DONE (original spec below)

File to create: `/home/surya/projects/idp-infra/30-cluster/main.tf`

**BEFORE STARTING:** Verify EKS version support:
- https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
- Standard support = $0.10/hr. Extended support = $0.60/hr. DO NOT use extended.
- As of 2026-09-22, versions 1.28-1.32 are in standard support (verify before creating)

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"  # verify latest at creation time

  cluster_name    = "idp-cluster"
  cluster_version = "1.31"  # CHECK support calendar — wrong = $0.60/hr not $0.10/hr

  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = ["<your-current-ip>/32"]
  cluster_endpoint_private_access      = true

  cluster_enabled_log_types = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 1  # 1 day ONLY — CloudWatch is $0.50/GB

  eks_managed_node_groups = {
    spot = {
      instance_types = ["t4g.small"]  # Free-tier eligible ON_DEMAND to bypass Spot restrictions
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }

  cluster_addons = {
    vpc-cni                = { most_recent = true }
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
    eks-pod-identity-agent = { most_recent = true }
  }
}

# NAT Gateway (lives here — destroyed nightly)
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.terraform_remote_state.network.outputs.public_subnet_ids[0]
  tags = { Name = "idp-nat" }
}
# Add 0.0.0.0/0 → NAT to BOTH private route tables:
# rtb-05a36c795c8121544 (ap-south-1a) and rtb-0a792e4f26cc2f99e (ap-south-1b)

# ECR repo (here — immutable tags, scan on push)
resource "aws_ecr_repository" "feature_flag_service" {
  name                 = "feature-flag-service"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

# ElastiCache Valkey (here — destroyed nightly, no stop API)
resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "idp-valkey"
  description          = "Feature Flag IDP - Valkey cache"  # ASCII hyphens ONLY
  engine               = "valkey"
  engine_version       = "7.2"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  parameter_group_name = "default.valkey7"
  subnet_group_name    = aws_elasticache_subnet_group.valkey.name
  security_group_ids   = [data.terraform_remote_state.network.outputs.sg_elasticache_id]
}
```

Measure build time: `time terraform apply -auto-approve` from start to `kubectl get nodes Ready`
This is your "mean time to environment" metric for the README.

**Verify:**
```bash
kubectl get nodes -o wide
# Must show 2 nodes in DIFFERENT AZs with PRIVATE IPs

aws eks describe-cluster --name idp-cluster --profile idp --query 'cluster.version'
# Must match standard-support version

# After Step 23, full green CI run will work — ECR repo now exists
```

---

#### Step 24 — External Secrets Operator + IRSA — DONE (original spec below)

```hcl
data "aws_iam_policy_document" "eso" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      # Specific secret ARNs — NOT "*"
      "arn:aws:secretsmanager:ap-south-1:693906847772:secret:idp/*"
    ]
  }
}
```

**ClusterSecretStore:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

**Verify:**
```bash
kubectl delete secret feature-flag-secrets -n feature-flag-dev
sleep 60
kubectl get secret feature-flag-secrets -n feature-flag-dev
# Must exist again (ESO recreated it)

# Secret rotation test (never echo plaintext — compare hashes)
kubectl get secret feature-flag-secrets -n feature-flag-dev \
  -o jsonpath='{.data.JWT_SECRET_KEY}' | base64 -d | sha256sum
# Rotate in Secrets Manager console, wait refreshInterval
kubectl get secret feature-flag-secrets -n feature-flag-dev \
  -o jsonpath='{.data.JWT_SECRET_KEY}' | base64 -d | sha256sum
# Hashes must differ
```

---

#### Step 25 — Ingress: ALB Controller + No-Domain Setup — DONE (original spec below)

**ONE shared ALB via IngressGroup (not three separate ALBs):**
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/group.name: idp
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
```

**Verify:**
```bash
curl -sI http://<alb-dns>/health
# HTTP/1.1 200

aws elbv2 describe-load-balancers --profile idp \
  --query 'LoadBalancers[?contains(LoadBalancerName, `idp`)].LoadBalancerArn'
# Must show EXACTLY ONE ALB for all environments
```

---

### PHASE C — GitOps Properly

#### Steps 26 + 27 - DONE and VERIFIED 2026-09-26
- Root Application (40-platform, automated) -> `platform/argocd-apps/` -> `platform-cluster` (wave 0, ClusterSecretStore) + `feature-flag-dev` (wave 1, `apps/feature-flag-service/overlays/dev`, automated prune+selfHeal).
- env-config is Kustomize: `apps/feature-flag-service/base` + `overlays/{dev,staging,prod}`. staging/prod are defined but NOT deployed (need own DB, distinct ingress rule, more nodes - see their kustomization.yaml). Kind-era manifests deleted (in git history). Kyverno policy parked in `platform/kyverno/` (not synced until Kyverno is installed).
- JWT key is generated by 20-data each session (no manual step).
- Verified: `make up` alone -> app live, migration ran, ALB 200, zero manual syncs. Full GitOps chain: empty commit -> CI green -> bot bumps `overlays/dev` newTag -> Argo auto-rolls out the new SHA (~9 min push-to-running incl. CI; Argo polls every 3 min).
- Deviations from the original plan: Argo CD installs ESO and the ALB controller via Terraform, not Argo (bootstrap order; revisit later). No ApplicationSet yet (one env live - an ApplicationSet is worth it when staging goes live).

#### Step 26 — Argo CD via Terraform + App-of-Apps (original plan)
Terraform installs Argo CD ONLY. Argo CD installs everything else.
Sync wave order: 0=ESO, 1=ALB Controller, 2=Kyverno, 3=Prometheus+metrics-server, 4=Apps.

#### Step 27 — Multi-Environment env-config Restructure
See Section 14 for target structure. Pause Argo CD auto-sync during restructure.
Promotion: dev auto-deploys → staging PR → prod manual sync.

#### Step 28 - DONE and VERIFIED 2026-09-26 (see Findings 41, 42, 44, 45)
Zero failed requests across GitOps rollout + node surge + drain; HPA scale-out verified.

#### Step 28 — HPA + PDB + Rolling Update Proof (original plan)
k6 load during rolling update. Zero failed requests required.

---

### PHASE D — The Actual IDP

#### Step 29 - Backstage in cluster: DONE and VERIFIED (2026-09-27)
Verified live: `make up` alone deployed it (Argo `idp-portal` Synced/Healthy); Ready ~30s after start; catalog DB migrations ran on RDS over verified TLS; via port-forward: UI HTTP 200, `/.backstage/health/v1/readiness` ok, guest sign-in ok; catalog contains `feature-flag-service` (owner DSurya11) + resources feature-flag-postgres / feature-flag-redis, read live from GitHub. Node memory after removing EBS CSI and adding Backstage: 52-57% used. Expected warnings: kubernetes plugin unconfigured (Step 31), permissions disabled.
- Repo: github.com/surya-idp/idp-portal (public; native ubuntu-24.04-arm runners, ~3 min build). CI: install/tsc/build -> arm64 image -> ECR `idp-portal` (15-registry, keep 5) via the same OIDC role (exact subject added) -> Trivy gate -> ff-idp-ci-bot bumps `apps/idp-portal/overlays/dev`.
- env-config: `apps/idp-portal` (namespace `backstage`, 1 replica, 512Mi request / 1Gi limit, DB creds from idp/db-creds via ESO), Argo Application `idp-portal` (wave 1).
- ACCESS: NO Ingress. `kubectl port-forward svc/idp-portal -n backstage 7007:7007` -> http://localhost:7007. Reason: Backstage needs a fixed baseUrl and the ALB hostname changes every session; guest sign-in is acceptable only while unexposed. User asked for "only me" access - port-forward is stricter than an IP allowlist.
- Capacity: EBS CSI add-on removed (unused; freed memory for Backstage).
- Deferred to Step 30: GitHub App for Backstage (catalog reads of public repos need no token).

#### Step 29 — Backstage in Cluster (original plan)
- Containerize idp-portal (multi-stage, non-root)
- Second DATABASE on same RDS instance (`CREATE DATABASE backstage_db`)
- Replace GitHub PAT with GitHub App, store in idp/backstage-github-app secret

#### Step 30 - Software Templates: LIVE DEMO DONE (2026-09-27, `hello-svc`)
Form submit -> `http://<ALB>/hello-svc/` 200 in **5m31s** (06:40:47Z -> 06:46:18Z), of which ~3.5 min
was a human waiting to merge. Machine time ~2 min: scaffolder 17 s (repo, idp-gitops PR, catalog),
new repo CI green 1m12s (image in ECR `svc/hello-svc`), merge -> first 200 in 36 s (Argo refresh
forced; otherwise up to +3 min poll). Verified: 2 pods uid 10001, PriorityClass business-critical,
HPA 2-3, PDB minAvailable 1, Argo `hello-svc` Synced/Healthy, catalog component `hello-svc`.
- Finding 52: publish:github with the App's installation token fails "Resource not accessible by
  integration": POST /user/repos accepts only user tokens (App user token or PAT), never an
  installation token. Fixed (idp-portal cb1f197): GitHub sign-in via the App's OAuth client
  (redirect URI http://localhost:7007/api/auth/github/handler/frame, resolver
  usernameMatchingUserEntityName, User DSurya11 in examples/org.yaml), RepoUrlPicker
  requestUserCredentials -> publish:github `token: secrets.USER_OAUTH_TOKEN`. The idp-gitops PR
  still goes through the App. Task runs as user:default/dsurya11.
- Finding 53: templates now load from ONE Location `idp-portal/templates/all-templates.yaml`
  (new template = add a target + git push, no image rebuild). Nested Location targets do not
  inherit per-location `rules`, so `Template` is in the global `catalog.rules`.
- Finding 54: the first pod of a brand-new service has no ALB readiness gate: the webhook injects
  it only when the TargetGroupBinding already exists at pod creation. Pods from later rollouts get it.
- Finding 55: the generated CI builds and pushes on every main push but nothing updates
  idp-gitops afterwards, so a generated service stays on its first commit forever. The merge is
  also manual, which contradicts section 14 (dev auto-deploys). Target design and plan:
  TEMPLATES_RESEARCH.md sections 4 and 8.
- GitHub App `ff-idp-backstage` (App ID 5088974, installed on ALL repos of DSurya11; administration/contents/workflows/pull_requests write). Actions:read not granted yet (needed for Step 31).
- Credentials live on the laptop in `~/.idp/` (700/600): `backstage-app.env` (APP_ID, CLIENT_ID), `backstage-app.pem`, `backstage-client-secret`. `make up` runs `scripts/load-local-secrets.sh` -> idp/backstage-github-app (stdin only; keeps $0 idle vs $0.40/mo permanent secret) -> ESO -> Backstage env.
- Template `idp-portal/templates/python-service` (loaded from GitHub URL): fetch skeleton -> publish:github (public repo) -> render env-config slice pinned to `steps.publish.output.commitHash` -> publish:github:pull-request -> catalog:register.
- Generated repo CI uses role `idp-service-ci`: trust `repo:DSurya11@162597218/*` main only, ECR `svc/*` only (creates its repo on first run). Deliberate exception to the exact-subject rule (user decision).
- Golden path bakes in Step 28: maxUnavailable 0, preStop 20s, readiness gate, PDB, HPA (wave 3), PriorityClass, zone spread, non-root uid 10001, uvicorn keep-alive 75s > ALB 60s. Route: `/<name>` on the shared ALB (group.order 10; feature-flag-api catch-all moved to 1000).
- Skeleton verified locally: renders, builds, serves /health and /<name>/, uid 10001, Trivy clean (after pinning starlette 1.7.0 - fastapi 0.118 pulled starlette 0.48 with 3 HIGH).

#### Step 30 — Software Templates (The Whole Point) (original plan)
**Template 1:** `create-python-service` — new repo + CI + env-config PR + catalog register
**Template 2:** `add-feature-flag` — domain-specific golden path

**⭐ Headline demo:** Fill form → repo created → CI green → PR in env-config → merge → service deployed via ALB → appears in catalog. Time it. Put duration in README.

#### Step 31 — Backstage Plugins
Argo CD, Kubernetes, GitHub Actions, Grafana, TechDocs (S3 backed)

---

### PHASE E — Hardening

#### Step 33 — Extended Kyverno Policy Suite
5 new policies: require-resource-limits, restrict-image-registries (ECR only), require-labels, disallow-latest-tag, require-probes

#### Step 34 — Observability
Alerting: PrometheusRule → Alertmanager → Slack/Discord webhook (induce each alert, paste received notification)
Logs: Loki + promtail (cheaper than CloudWatch Container Insights)
Traces: OpenTelemetry → Tempo (resolves the Step 16 latency mystery)

#### Step 35 — DR Drill
```bash
time make nuke    # full destroy with final snapshot
time make up      # full rebuild
./tests/test_e2e.sh  # N/N checks pass
```
Mean time to full environment from zero → in README.

#### Step 36 — Rewrite test_e2e.sh for AWS/EKS
EKS context check, ALB DNS + HTTP 200, RDS from pod, ESO ExternalSecret=Ready, all 3 envs, Argo CD sync status, ECR scan (no HIGH/CRITICAL), 5 Kyverno policies, Prometheus target UP.

---

## 18. README Additions Still Needed

> **Closed 2026-10-11.** The READMEs of all five repositories were rewritten for the final
> state. The list below is the original wish list for the feature-flag-service README; the
> points that still apply are in that README's "Engineering decisions" and "History" sections,
> the others describe earlier stages that no longer exist.

Add to Section 3 "Real Engineering Decisions":
8. conntrack stickiness on sequential in-cluster requests
9. NAT Gateway vs NAT instance vs VPC endpoints — arithmetic, chosen approach
10. SPOT node groups with multi-instance-type fallback — fewer interruptions
11. Terraform bootstraps Argo CD; Argo CD owns everything else — two reconcilers fighting is a real failure mode
12. ESO structurally eliminates the secret-template GitOps trap — design vs. symptom fix
13. Prod on manual sync; dev/staging auto-sync — deliberate
14. One shared ALB via IngressGroup — three ALBs = three times the hourly charge
15. The latency resolution — Neon-over-internet vs RDS-in-VPC, same code, one variable changed
16. ElastiCache has no stop API — why Valkey lives in 30-cluster not 20-data (new finding)
17. Option B lifecycle — full destroy every session, $0.00 idle, why it's better than stopping (new)
18. skip_final_snapshot = true — why it's non-negotiable for destroy-based lifecycle (new)
19. AWS em-dash rejection — non-ASCII in resource descriptions causes API errors (new)
20. Dynamic OIDC thumbprint — hardcoded thumbprints break when GitHub rotates cert (new)
21. **Region Capacity Engineering:** How we gracefully degraded from ARM/gp3 to x86/gp2 when AWS Mumbai ran out of hardware dynamically during `make up`.
22. **Spot Restrictions & AMI Types:** Understanding that cost-saving with Spot instances on new AWS accounts is tightly coupled to Free Tier guardrails, and how EKS forces architectural lock-in (ARM vs x86) at the Node Group AMI layer.
23. **API Ghosting in Verification Scripts:** The complexity of writing a "zero-cost verification" script that must navigate the AWS Tagging API's aggressive caching of deleted NAT Gateways and pending-deletion KMS keys.
24. **OIDC Thumbprint Instability:** Why relying purely on dynamic TLS certificate thumbprints for GitHub Actions OIDC fails, and why well-known static thumbprints are required as fallbacks.
25. **The ENI Pod Limit Trap:** Why `t4g.small` EKS nodes cap out at 11 pods by default, how system pods (ArgoCD, ESO, ALB Controller) easily consume this limit, and the necessity of VPC CNI Prefix Delegation.

Add "Cost Engineering" section:
- Per-hour table from verified AWS Pricing API data
- Option B vs Option A comparison
- Mean time to environment (measure in Step 23)

Add "Self-Service" section:
- Backstage template demo with measured developer-to-running-service time

Update "Known Simplifications":
- REMOVE: Secrets applied imperatively (fixed by ESO)
- REMOVE: No Ingress (fixed by ALB Controller)
- ADD: Single-AZ RDS (no Multi-AZ)
- ADD: No service mesh
- ADD: SPOT-only nodes (no on-demand fallback)
- ADD: No paid domain — HTTP only via ALB DNS
- ADD: Option B lifecycle — data not persistent between sessions

---

## 19. Interview Stories (Per Step)

Strongest stories in order:
1. **Step 30** — "developer to running service in X minutes, zero platform-team involvement"
2. **Step 21** — latency A/B: one variable changed, real data
3. **Step 24** — ESO structurally eliminates the GitOps trap class
4. **Step 35** — destroy and rebuild the entire platform every session; mean time: X minutes
5. **Step 15** — Kyverno optional-match bug (testing policy works ≠ testing policy enforces)
6. **Step 13** — secret-template GitOps trap (real, non-obvious failure mode)
7. **Step 16** — p95 0.97s discovery (data overturning untested assumption)
8. **Step 21+** — ElastiCache no-stop-API discovery; architecture decision explained by arithmetic
9. **Step 22** — Zero long-lived credentials in CI (OIDC + GitHub App = no static secrets)

---

## 20. Things That Must Never Happen

- Never operate as AWS root
- Never echo plaintext secret values — use SHA256 checksums
- Never leave EKS running unattended — make down before closing laptop, make verify-empty must pass
- Never use `Resource: "*"` in IAM policies for ESO or any scoped role
- Never use wildcards in OIDC trust policy (single approved exception: idp-service-ci, owner-ID scoped, ECR svc/* only)
- Never use engine="redis" — use engine="valkey"
- Never hardcode OIDC thumbprint — use tls_certificate data source
- Never use em-dashes in AWS resource description fields — use ASCII hyphens
- Never set skip_final_snapshot=false on RDS with Option B lifecycle — $31/month snapshots
- Never drop the `terraform plan` → "No changes" check after state migrations
- Never claim a step is done without real command output as evidence
- Never assume ElastiCache can be stopped — it cannot, it must be destroyed
- Never mix ARM (t4g) and x86 (t3) instance types in the same EKS Managed Node Group.
- Never forget `force_delete = true` on ECR repositories intended for ephemeral lab teardown.
- Never rely solely on dynamic OIDC thumbprints without static fallbacks for GitHub Actions.
- Never deploy heavy system components (ArgoCD, ESO) to `t4g.small` nodes without VPC CNI Prefix Delegation enabled.
- Never add a Terraform backend without `use_lockfile = true` (state was silently unlocked until Finding 49).
- Never rename a GitHub repo that CI uses without updating the OIDC trust `sub` first.
- Never put GitHub App secrets or private keys in Git, chat or TF state; they live in `~/.idp`.

---

*End of master handover document. Any agent reading this from the top has everything needed to continue from any step without asking setup questions.*
