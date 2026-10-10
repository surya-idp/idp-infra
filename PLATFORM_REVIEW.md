# Platform Review: Our Approach vs Industry Standard

> Written 2026-09-27 (Session 7). Scope: the whole IDP (identity, Terraform, cluster, GitOps, CI,
> secrets, networking, data, policy, observability, Backstage, GitHub governance). Templates are
> covered in depth in `TEMPLATES_RESEARCH.md`; this file only links to it.
>
> Method: every "Ours" cell was checked in the repos or AWS on 2026-09-27 (not from memory); every
> "Industry" cell cites a vendor or project source (section 6). The user's rule: **where we differ
> from industry without a real reason, follow industry.**

---

## 1. Verdict in one screen

**Solid (keep):** OIDC from CI to AWS with no stored AWS keys; immutable SHA image tags; a Trivy
gate; ESO + Secrets Manager (no Secret objects in Git); GitOps app-of-apps with automated sync;
a separate config repo; one shared ALB via IngressGroup; zero-downtime rollout proven under load
(Step 28); cost tagging, budgets and a teardown verifier that checks services directly.

**Deliberate deviations (keep, documented):** destroy-every-session (Option B); a single account
and single dev environment; no domain/TLS; Backstage reachable only through port-forward; a public
EKS endpoint restricted to one IP; single-AZ RDS with no backups; 2x t4g.small instead of
Karpenter. All are driven by the ~$200 credit budget or a solo operator, and each has a stated
production equivalent (section 4).

**Real flaws (fix):** 16, ranked in section 3. The top five:
1. **Laptop uses a long-lived IAM user access key** for full admin (AWS says humans should use
   temporary credentials).
2. **idp-gitops `main` is unprotected.** Anything with write access deploys straight to the
   cluster, with no validation, no required checks and no review.
3. **Every app connects to Postgres as the RDS master user** (Backstage and the flag API share it).
4. **Nothing enforces the security the golden path promises:** no Pod Security Admission labels,
   Kyverno not installed, and all Argo apps in the wide-open `default` AppProject.
5. **No observability at all**, so the platform cannot show whether anything is healthy.

---

## 2. Area-by-area mapping

Verdict: **A** = aligned, **D** = deliberate deviation (justified), **F** = flaw.

### 2.1 Identity and access

| Topic | Ours (verified) | Industry standard | Verdict |
|---|---|---|---|
| Human access to AWS | IAM user `idp-admin`, long-lived access key in `~/.aws/credentials` (`aws configure list`: shared-credentials-file) | temporary credentials for humans; IAM Identity Center for centralized access; avoid long-term keys [1][2] | **F1** |
| CI access to AWS | GitHub OIDC -> roles, exact `sub`, no stored keys | same [1] | A |
| Pod access to AWS | IRSA (ESO, ALB controller) | EKS Pod Identity recommended for new workloads, IRSA still supported; one role per app [3] | F (low) **F12** |
| Kubernetes API access | cluster-creator admin via access entry (`enable_cluster_creator_admin_permissions`), auth mode left at module default | Cluster Access Management API (access entries); aws-auth ConfigMap is deprecated [4] | A (set mode to `API` explicitly: F12) |
| Account structure | one account for everything | separate accounts per environment under AWS Organizations [5] | D (one env, credits); design must not block it |

### 2.2 Infrastructure as Code

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Layering | 00-bootstrap / 10 / 15 / 20 / 30 / 40 with remote state and S3-native locks | layered state, remote backend, locking | A |
| Provider lock files | **none committed** (`.terraform.lock.hcl` exists locally in all 6 layers; 0 in git) | commit `.terraform.lock.hcl` so every run uses the same providers [6] | **F6** |
| Who applies | laptop, `terraform apply -auto-approve` via `make up`; no plan on PR, no CI for Terraform | plan on every PR, reviewed; apply from main by automation [7] | **F7** (permanent layers); D for the per-session layers (the laptop is the operator in Option B) |
| Static checks | none (no fmt/validate/tflint/trivy config in CI) | validate + lint + security scan in CI | F7 |
| Versions | AWS provider 5.100.0 (latest 6.66.0), EKS module ~>20 (latest 21.26), ESO chart 0.10.3 | stay within supported majors; planned upgrades | **F10** |
| Bootstrap state | 00-bootstrap state local on the laptop only | chicken-and-egg is normal, but migrate it to the bucket after creation so a lost laptop does not orphan it | F (low) F7 |

### 2.3 Cluster

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Control plane | EKS 1.35 standard support, audit+authenticator logs, 1-day retention | managed control plane in standard support | A |
| Nodes | managed node group 2x t4g.small ON_DEMAND, AL2023 ARM, prefix delegation | managed node groups or Karpenter / EKS Auto Mode | D (2 small nodes; Karpenter adds value at scale) |
| Endpoint | public, restricted to one /32 | private endpoint + VPN/bastion, or public with CIDR allowlist | D (acceptable) |
| Add-ons | vpc-cni, coredns, kube-proxy, metrics-server, pod-identity-agent via EKS add-ons | same | A |

### 2.4 GitOps and delivery

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Model | Argo CD app-of-apps, automated prune + selfHeal, separate config repo | same; separate config repo recommended [8] | A |
| Who installs platform add-ons | Terraform installs Argo CD **and** ESO + ALB controller (Helm) | Terraform bootstraps Argo CD only; Argo CD manages add-ons and itself [9] | **F9** (two reconcilers; add-on upgrades bypass GitOps) |
| AppProjects | every Application in `default` (any repo, any cluster, any namespace, cluster-scoped kinds) | restricted projects; the default project is maximally permissive and a known escalation path [10] | **F4** |
| Argo CD login | local admin (initial secret), no SSO, `server.insecure` behind port-forward | admin only for setup, then SSO; disable local users [10] | F (low while port-forward only) F4 |
| Config repo protection | **`main` unprotected** (GitHub API: "Branch not protected"); bots and humans push directly | protected main, required checks (manifest validation), reviews where a human gate is wanted | **F2** |
| Continuous deploy / promotion | CI bots bump tags for 2 apps; generated services never update (G2) | registry-driven updates (Image Updater) or a promotion layer (Kargo) | F -> TEMPLATES_RESEARCH section 4 |
| New app onboarding | one Application file per service | ApplicationSet generators | F -> TEMPLATES_RESEARCH |

### 2.5 CI and supply chain

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Tags, scan, arch | SHA tags, immutable ECR, Trivy HIGH/CRITICAL gate, native arm64 | same | A |
| Action pinning | tags (`actions/checkout@v4`, `trivy-action@v0.36.0`, ...) | full-length commit SHA is the only immutable reference; GitHub can enforce it [11] | **F11** |
| Signing / SBOM / provenance | none | keyless cosign + SLSA provenance, verified at admission [12] | F11 |
| Bot credentials | CI bot private key stored in each app repo; **unused PAT `ENV_CONFIG_REPO_PAT` still in feature-flag-service** | no unused long-lived credentials; fewest possible key copies | **F8** |
| Dependency updates | none (no Dependabot/Renovate) | automated update PRs | F11 |
| Central pipeline | copied per repo | reusable versioned workflows | F -> TEMPLATES_RESEARCH |

### 2.6 Secrets

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Pattern | ESO + Secrets Manager, ClusterSecretStore, scoped IRSA | same | A |
| ESO version/API | chart 0.10.3; manifests use `external-secrets.io/v1beta1` | `v1beta1` is **removed as of ESO 0.17**; current charts are 2.x [13] | **F10** (blocks every ESO upgrade until migrated) |
| App-only secrets on the laptop | GitHub App files in `~/.idp`, pushed to Secrets Manager each `make up` | secrets live in the secret store permanently | D ($0.40/secret/month saved; fine for a solo lab) |

### 2.7 Networking

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Ingress | ALB controller, one shared ALB (IngressGroup) | same (Gateway API is the direction of travel) | A |
| TLS | HTTP only, no domain | TLS everywhere (ACM + Route 53) | D (no domain; never expose Backstage/Argo) |
| Pod-to-pod | no NetworkPolicy | default-deny + explicit allows | **F13** |
| Cache encryption | Valkey at-rest and in-transit encryption **off** | on by default | **F13** |
| NAT | single NAT gateway | one per AZ in prod | D |

### 2.8 Data

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| DB credentials | **Backstage and the flag API both use the RDS master user** (`idp/db-creds`) | one database user per app with least privilege; master for admin only | **F3** |
| Availability/backups | single-AZ, no backups, destroyed each session | Multi-AZ, PITR backups | D (Option B) |
| Encryption / TLS | SSL enforced by RDS 16 (`rds.force_ssl`), verified CA in Backstage | same | A |

### 2.9 Policy and guardrails

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Pod Security Standards | no `pod-security.kubernetes.io/*` labels on any namespace | built-in Pod Security Admission, `restricted` for app namespaces [14] | **F5** |
| Policy engine | Kyverno not installed; one parked policy | Kyverno/Gatekeeper: registries, limits, probes, no `latest`, signed images | F5 (Step 33) |
| Resource governance | no LimitRange/ResourceQuota | per-namespace defaults and quotas | F5 |

### 2.10 Observability

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Metrics / logs / traces / alerts | none live (Prometheus/Grafana existed only in the kind era) | metrics + logs + traces + SLO alerts from day one of a platform | **F14** (Step 34) |
| Delivery metrics | one measured number (5m31s) | DORA metrics (deploy frequency, lead time, change failure, MTTR) | F14 |

### 2.11 Developer portal (Backstage)

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Access | port-forward only; GitHub sign-in (plus guest) | SSO behind an ingress with TLS | D (only-me access; guest should go: F15) |
| Authorization | permission framework **disabled** (allow-all policy) | permission policies (who can run which template, edit catalog) | **F15** (low for one user; required before anyone else uses it) |
| Catalog ingestion | static URL locations | GitHub discovery provider + org data provider [15] | **F15** |
| Plugins | Kubernetes/Argo/Actions/TechDocs not configured | the portal shows deploys, runs and docs per entity | F (Step 31) |

### 2.12 GitHub governance

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Account type | personal account `DSurya11` | a GitHub organization (teams, org secrets, Apps that can create repos, rulesets) | **F16** (root cause of Finding 52 and of the CI-key sprawl) |
| Branch protection / rulesets | none on any repo checked (idp-gitops, feature-flag-service) | protected default branches, required checks | F2 |
| CODEOWNERS, secret scanning, CodeQL | not set | standard for public repos (free) | F11 |

### 2.13 Operations and cost

| Topic | Ours | Industry | Verdict |
|---|---|---|---|
| Cost controls | default tags, budgets, `verify-empty` (tag API + direct service checks) | same | A (strong) |
| Runbooks / DR | HANDOVER doc; DR drill planned (Step 35) | runbooks per service, rehearsed DR | F (planned) |
| Doc drift | Makefile header still says "spot node cost", "~$0.10/hr" | docs match reality | F (trivial) |

---

## 3. Flaws ranked, with the fix

Severity = impact x likelihood for *this* platform. Effort: S (< 1h), M (half day), L (1+ day).

| ID | Flaw | Severity | Fix (industry way) | Effort | Needs cluster? |
|---|---|---|---|---|---|
| F1 | Long-lived admin access key on the laptop | High | Temporary credentials: IAM Identity Center (needs AWS Organizations, free) with a permission set and `aws sso login`; or at minimum an MFA-protected role assumed from a key that can do nothing else. Then deactivate the old key | M | No |
| F2 | idp-gitops main unprotected; no rulesets anywhere | High | Ruleset on idp-gitops main: required validation check (`kustomize build` + kubeconform), no force-push/deletion, bypass only for the platform Apps; rulesets on app repos (required CI) | S-M | No |
| F3 | Apps use the RDS master user | High | Per-app DB + user created declaratively in-cluster each session (idempotent Job/operator, credentials via ESO), master only for that Job (also the base of template T3) | M | Yes (verify) |
| F4 | All apps in `default` AppProject; admin-only login | High | AppProjects `platform` (cluster-scoped allowed) and `apps` (namespaced only, source idp-gitops only, destinations = their namespaces); lock `default` to nothing | S-M | Yes |
| F5 | No Pod Security Admission, no policy engine, no quotas | High | PSA labels via Argo `managedNamespaceMetadata` (`restricted` for apps, `baseline` where a chart needs it); Kyverno Step 33 suite; LimitRange per app namespace | M | Yes |
| F14 | No observability | High | Step 34, sized for 2 GiB nodes (or managed: Amazon Managed Prometheus/Grafana, to be priced) | L | Yes |
| F7 | Terraform: no plan-on-PR/CI, local bootstrap state | Medium | idp-infra CI: fmt, validate, tflint, trivy config, `plan` per layer via OIDC (read-only role); permanent layers applied by CI after merge; move bootstrap state into the bucket | M | No |
| F6 | Provider lock files not committed | Medium | commit all `.terraform.lock.hcl` (multi-platform `providers lock`) | S | No |
| F10 | ESO 0.10.3 + `v1beta1` API; AWS provider 5.x, EKS module 20.x | Medium | migrate manifests to `external-secrets.io/v1`, then upgrade ESO; move ESO/ALB controller under Argo (F9); schedule AWS provider 6 / EKS module 21 upgrade with plan diffs | M | Yes |
| F9 | Terraform installs ESO + ALB controller | Medium | Terraform installs Argo CD only; ESO/ALB controller (and later Argo CD itself) become Argo Applications in wave -1 | M | Yes |
| F8 | Unused PAT secret; CI bot key copied into repos | Medium | delete `ENV_CONFIG_REPO_PAT` and revoke the PAT; Image Updater removes the key copies (TEMPLATES_RESEARCH 4.1 B) | S (+ phase 1) | No |
| F11 | Actions pinned by tag; no SBOM/signing; no Dependabot/CodeQL/secret scanning | Medium | SHA pins (+ Dependabot keeps them current), keyless cosign + provenance, Dependabot, CodeQL default setup, push protection | M | No |
| F16 | Personal GitHub account | Medium (strategic) | create a free GitHub organization and transfer the repos; update OIDC `sub` trust (owner changes), Argo repo URLs, catalog locations, App installation. Unblocks Apps creating repos, org secrets, teams | M | No (but touches everything) |
| F12 | IRSA instead of Pod Identity; auth mode implicit | Low | new roles via Pod Identity associations; set `authentication_mode = "API"` | S-M | Yes |
| F13 | No NetworkPolicy; Valkey unencrypted | Low-Med | enable transit encryption (clients need TLS); NetworkPolicy after checking VPC CNI network-policy agent memory | M | Yes |
| F15 | Backstage: guest enabled, permissions off, static catalog | Low (solo) | remove guest; permission policy; GitHub discovery provider for `catalog-info.yaml` in all repos | M | Yes |

---

## 4. Deviations we keep, and their production equivalent

| Deviation | Why | Production equivalent (say this in interviews) |
|---|---|---|
| Destroy every session (Option B) | ~$0.26/hr, $0 idle | long-lived envs; ephemeral preview envs per PR |
| One account, one env | credits | account per env under Organizations/Control Tower [5] |
| No domain/TLS | cost | ACM + Route 53, HTTPS-only listeners |
| Port-forward to Backstage/Argo | only-me access, no domain | SSO behind an internal ALB/VPN |
| Single-AZ RDS, no backups | cost; data is disposable | Multi-AZ + PITR, restore drills |
| 2x t4g.small, no Karpenter | cost | Karpenter / Auto Mode, Spot + On-Demand mix |
| Laptop secrets pushed each session | $0 idle | permanent secrets with rotation |

---

## 5. Recommended order (merged with TEMPLATES_RESEARCH.md)

Order follows dependencies: governance before automation (auto-merge needs required checks),
guardrails before golden path v2 (the template must pass the policies it claims to meet).

1. **Decide F16 first (GitHub org or not).** It changes repo owners, OIDC trust, Argo URLs and how
   templates create repos. Doing it after template v2 means redoing that work.
2. **Offline, no cluster:** F1 (temporary AWS credentials), F6 (lock files), F8 (delete PAT),
   F2 (rulesets + idp-gitops validation workflow), F7 (Terraform CI), F11 (SHA pins, Dependabot,
   CodeQL, push protection).
3. **Cluster session A (guardrails):** F4 AppProjects, F5 PSA + LimitRange, F10/F9 (ESO v1 API,
   ESO + ALB controller under Argo), F3 per-app DB users.
4. **Templates phase 1-4** (TEMPLATES_RESEARCH section 8): zero-touch delivery, central CI +
   Kustomize component, skeleton v2, template CI.
5. **Cluster session B:** F14 observability (Step 34) + Kyverno suite (Step 33) + supply-chain
   verification (F11 part 2).
6. Then day-2 templates, Backstage plugins/permissions (F15, Step 31), F12/F13, DR drill (Step 35).

Each item ends with command output as evidence, per the HANDOVER convention.

### Decisions needed from the user
1. F16: create a GitHub organization and move the repos (recommended), or stay personal and accept
   the workarounds (user-token repo creation, key copies or in-cluster updater).
2. F1: IAM Identity Center via AWS Organizations (recommended; free, account becomes the
   management account) vs an MFA-assumed role from the existing user.
3. The four template decisions in TEMPLATES_RESEARCH.md section 9.

---

## 5a. Progress (2026-10-10, cluster down, $0)

| ID | Status | Evidence / where |
|---|---|---|
| F2 | **Done** for idp-gitops: ruleset (no delete/force-push, PR + required `validate` check from GitHub Actions; bypass only for the idp-ci-bot and idp-backstage Apps). Other 4 repos: no delete/force-push. | direct push rejected (GH013); bot pushes a09f3d0/abec630 went through; PR #3 merged via check |
| F2 | `validate` workflow: every overlay rendered + kubeconform strict (K8s 1.35 + CRD catalog), kubeconform pinned + sha256 | negative test rejects wrong types and misspelled fields |
| F6 | **Done**: lock files committed (linux amd64/arm64, darwin arm64); `.gitignore` excluded them | idp-infra 31d7d6a |
| F7 | **Static CI done** (fmt, validate, tflint, Trivy IaC gate with reasoned `.trivyignore.yaml`). Plan-on-PR + drift check: idp-infra PR #10 (needs the user to apply the 00-bootstrap role) | CI green on 31d7d6a |
| F8 | PAT secret deleted from feature-flag-service. The PAT itself: user revokes it | `gh secret list` |
| F10 | **Done 2026-10-10**: ESO chart 2.11.0 + `external-secrets.io/v1` manifests merged (idp-infra#9, idp-gitops#5) and verified on the cluster | pod image `external-secrets:v2.11.0`; all four ExternalSecrets `SecretSynced` |
| F11 | **Done**: all actions pinned to full SHAs; Dependabot (actions, pip/npm/docker, terraform grouped; Backstage-coupled majors ignored); secret scanning + push protection, Dependabot security updates, CodeQL default setup on all 5 repos | idp-portal c17d263, feature-flag-service 651344a |
| F4, F5 | **Done 2026-10-10**: AppProjects (bootstrap/default-locked/platform/apps) + PSA baseline-enforce / restricted-warn merged (idp-infra#8, idp-gitops#4, idp-portal#6) and verified. Template services go further: the `golden-path` component meets the *restricted* profile (non-root, read-only root, no capabilities, seccomp). Still open in F5: Kyverno suite (Step 33), LimitRange | all Argo apps Synced/Healthy in their projects; template pods admitted with no PSA warning |
| F13 | RDS `storage_encrypted`, Valkey at-rest encryption (apply at next `make up`); public subnets `map_public_ip_on_launch=false` (10-network: user applies) | Trivy findings AWS-0080/0045/0164 gone |
| F1 | **Done**: IAM Identity Center (AWS Organizations), user `surya` + authenticator MFA, AdministratorAccess 8h; profile `idp` is SSO; idp-admin access key Inactive (delete after a week) | `aws sts get-caller-identity` -> AWSReservedSSO role; 10-network plan via SSO: No changes |
| F7 | Plan role applied by the user; PR #10 merged: CI plans 10-network/15-registry on PRs and checks drift on main | plan jobs: No changes |
| F16 | **Done**: org `surya-idp`; 4 repos transferred (same IDs); Apps owned by and installed on the org; all refs updated; OIDC trust moved (old subjects removed in PR #14, user applies); security settings + ruleset bypass restored after transfer (Finding 56) | CI green under the org: ECR push + bot bumps dfb88f3/6728c5e; plan jobs green |
| F2 | Tightened 2026-10-10: the Backstage App is off the idp-gitops bypass list (only `idp-ci-bot` bypasses); "Allow auto-merge" on; the CRD schema catalog used by `validate` is pinned by commit | deploy PR of a template service merged by the App only after `validate` passed |
| F8 | Partly: golden-path service repos hold no deploy-repo credential (Image Updater holds the only copy, in the cluster). feature-flag-service and idp-portal still carry the CI bot key | bot commit `chore(deploy): update hello-svc image` authored by `idp-ci-bot[bot]`, Verified |
| Templates phases 1-4 | **Done 2026-10-10** (TEMPLATES_RESEARCH section 13): zero-click first deploy, Image Updater, shared CI repo `idp-platform`, Kustomize components, skeleton v2, template CI | form -> ALB 200 in 2m46s; second push live in 6m35s |
| F3, F9, F12, F14, F15 | Not started (need a cluster session) | - |

Also found: idp-portal has 14 Dependabot alerts (2 high) in dependencies; the image Trivy gate passes,
so they are in build-time/dev dependencies or have no fixed version yet. Review the security PRs.

## 6. Sources

1. AWS IAM, Security best practices (temporary credentials, Identity Center): https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
2. AWS Well-Architected SEC02-BP02, Use temporary credentials: https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/sec_identities_unique.html
3. Amazon EKS Best Practices, Identity and Access Management (Pod Identity recommended): https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html
4. Amazon EKS Best Practices, Cluster access management (access entries; aws-auth deprecated): https://docs.aws.amazon.com/eks/latest/best-practices/cluster-access-management.html
5. AWS whitepaper, Organizing Your AWS Environment Using Multiple Accounts: https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/organizing-your-aws-environment.html ; Organizations best practices: https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices.html
6. HashiCorp, Dependency Lock File: https://developer.hashicorp.com/terraform/language/files/dependency-lock
7. HashiCorp, Automate Terraform with GitHub Actions (plan on PR, apply on main): https://developer.hashicorp.com/terraform/tutorials/automation/github-actions ; Core workflow: https://developer.hashicorp.com/terraform/intro/core-workflow
8. Argo CD, Best Practices (separate config repo): https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
9. Argo CD, Cluster Bootstrapping (app of apps) and Declarative Setup (manage Argo CD with Argo CD): https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/ , https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
10. Argo CD, Projects (default project is maximally permissive) and Security considerations; User management (admin only for initial setup, then SSO): https://argo-cd.readthedocs.io/en/stable/user-guide/projects/ , https://argo-cd.readthedocs.io/en/stable/security_considerations/ , https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/
11. GitHub, Secure use reference (pin actions to a full-length commit SHA): https://docs.github.com/en/actions/reference/security/secure-use
12. Kyverno, Verify SLSA provenance (keyless): https://kyverno.io/policies/other/verify-image-slsa/verify-image-slsa/
13. External Secrets Operator, v1beta1 removal in 0.17 (upgrade notes and issue): https://external-secrets.io/latest/guides/v1beta1/ , https://github.com/external-secrets/external-secrets/issues/5141 ; current chart: https://artifacthub.io/packages/helm/external-secrets-operator/external-secrets
14. Kubernetes, Pod Security Admission and namespace labels: https://kubernetes.io/docs/concepts/security/pod-security-admission/ , https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/
15. Backstage, GitHub Discovery and GitHub Organizational Data: https://backstage.io/docs/integrations/github/discovery/ , https://backstage.io/docs/integrations/github/org/
16. Terraform Registry (latest versions checked 2026-09-27): hashicorp/aws 6.66.0, terraform-aws-modules/eks 21.26.0
