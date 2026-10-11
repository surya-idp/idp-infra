# Golden Path Templates: Research and Target Design

> Written 2026-09-27, after the first live run of `python-service` (`hello-svc`, form to running in 5m31s).
> Purpose: define what a production-grade golden path means for this IDP, measure the current
> template against it, and fix the order of work. HANDOVER_DOC.md is still the master context;
> this file owns everything about templates.
>
> **Updated 2026-09-27 (Session 8): section 11 re-checks every claim and decision against sourced
> evidence (versions, consensus vs opinion vs vendor, criticisms, real companies) and changes three
> details of the plan (11.6). Section 12 is the interview explainer. New sources are [15]-[52].**
>
> **Updated 2026-10-11: section 14 is the final state.** Phases 5 and 6 are built and verified:
> signed provenance and SBOM, three day-2 templates, the annotation contract that keeps them
> generic. Sections 1 to 13 are kept as written.

---

## 1. Where we are, and what the first live run showed

What one template run touches today:

```
Backstage form (signed in with GitHub)
 ├─ 1. publish:github (user token)   -> NEW repo DSurya11/<name>        (created directly, no PR)
 │        └─ its CI: docker build (arm64) -> Trivy -> push ECR svc/<name>:<sha>
 ├─ 2. publish:github:pull-request   -> PR in idp-gitops                (NOT idp-infra)
 │        adds apps/<name>/{base,overlays/dev} + platform/argocd-apps/<name>.yaml
 ├─ 3. catalog:register              -> Component <name> in Backstage
 └─ human merges the idp-gitops PR   -> Argo CD root app creates Application <name> -> ALB route
```

- **idp-infra is never touched.** It holds Terraform only. A template changes idp-infra only if a
  service needs new AWS resources (a bucket, a queue or an IAM role).
- **The PR is into idp-gitops**, the repo Argo CD deploys from. The service's own repo is created
  directly. The deploy config lives in a separate repo on purpose: Argo CD's own best-practice
  guide recommends a separate config repo (a clean audit log, access separation, no CI loops when
  bots commit tags) [1].

What the run exposed (measured, not assumed):

| # | Problem | Consequence |
|---|---|---|
| G1 | A human has to merge the idp-gitops PR after watching CI | dev is not zero-touch. This contradicts HANDOVER section 14 ("dev: automated, any merged PR deploys") |
| G2 | **The generated CI never updates idp-gitops after the first deploy** | the service stays pinned to its first commit forever. A developer's second push builds an image that nothing deploys. **This is the most serious gap.** |
| G3 | CI runs no tests, lint or type checks, and there are no tests in the skeleton | "green CI" only means the image built and has no fixable HIGH CVEs |
| G4 | The whole CI pipeline is copied into every repo (70 lines) | a platform fix (a new scan, a new runner) never reaches existing services |
| G5 | Kubernetes manifests are copied into `apps/<name>/base` per service | same drift problem for deploy settings (Step 28 lessons stay frozen at copy time) |
| G6 | No observability (metrics, traces, structured logs), no docs (TechDocs), no API entity | the service is not operable or discoverable beyond "it exists" |
| G7 | Supply chain: no SBOM, no signature, no provenance; actions pinned by tag, not SHA | cannot prove what runs in the cluster came from CI |
| G8 | Owner is a free-text user, no System, lifecycle hardcoded `experimental` | the catalog cannot answer "who owns this, what is it part of" |
| G9 | Day-2 is missing: no way to add a DB, add a flag, promote or decommission | templates are one-shot scaffolding, not a platform |

The rest of this document explains what the industry does about each of these, then gives the target design.

---

## 2. What "golden path" means in industry (sources in section 10)

- **Spotify (originated the term, built Backstage):** "the opinionated and supported way to build
  something". It pairs a step-by-step tutorial (TechDocs) with a template, and golden path docs are
  Spotify's most-read internal documentation [2]. The template wires the new service into CI/CD,
  monitoring and logging from the first commit, so a new service starts compliant [3].
- **CNCF Platforms white paper and maturity model:** a platform is "an internal product providing a
  curated experience for developers, reducing cognitive load while retaining autonomy". Golden
  paths, self-service provisioning, a catalog and scorecards are core capabilities. The maturity
  model rates how consistently these are provided and measured [4][5].
- **What separates a golden path from a template:** it carries strong opinions on language, test
  framework, CI, observability and secret handling, "all of it provided in the form the
  organization has committed to" [6]. And it is *supported*: the platform team maintains it after
  day 1.
- **Red Hat's "10 tips" for Backstage templates:** one central template repo with a root Location
  (done, Finding 53), OwnerPicker/EntityPicker instead of free text, TechDocs in every template,
  test templates through the scaffolder API, and maintain them continuously [7].
- **Central, versioned CI:** the platform repo owns the delivery logic as reusable workflows
  (`workflow_call`), and each app repo holds one thin caller pinned to a version. Treat workflows as
  an API: inputs are the contract, breaking changes bump the major version [8].
- **Promotion is a separate layer from GitOps:** Argo CD syncs whatever Git says; something has to
  change Git per environment. Industry answers: CI bots (what we do), Argo CD Image Updater (watches
  the registry and writes the new tag back to Git) [9], or Kargo (Warehouse -> Freight -> Stages
  dev/staging/prod, each with its own promotion rules) [10].
- **App onboarding without editing platform files:** an Argo CD ApplicationSet with a Git directory
  generator creates one Application per matching directory automatically ("whenever a new
  subdirectory is added ... automatically deploy ... within new Application resources") [11].
- **Supply chain:** keyless cosign signing with the GitHub Actions OIDC identity (no keys), SLSA
  provenance via `actions/attest-build-provenance`, and admission control (Kyverno `verifyImages`)
  that rejects unsigned images [12][13].
- **Keeping services on the path after day 1:** scorecards (Backstage Tech Insights, Spotify
  Soundcheck) turn standards into checks per catalog entity (for example: has TechDocs, CI green,
  template version current) [14].

### How industry handles dev vs staging vs prod

| Environment | Industry norm | Human involvement |
|---|---|---|
| dev | every green build on main deploys automatically (CD) | none |
| staging | automatic or one-click promotion of a build that passed dev | optional |
| prod | promotion of the exact artifact that passed staging, with approval | yes (approval and audit trail) |

A PR is used where review adds information (a human decision, a diff someone should read). For dev,
the "review" we had was a person waiting for CI to go green. A machine does that better. **So G1 is
a real defect, not a safety feature.**

---

## 3. Gap matrix: industry standard vs `python-service` today

Legend: Have / Partial / Missing. "Fit" = worth doing in this project given its constraints (section 7).

| Area | Industry standard | Today | Fit |
|---|---|---|---|
| **Delivery** | zero-touch dev deploy on every green main build | Missing (G1, G2) | **P0** |
| | onboarding creates no hand-written platform files (ApplicationSet) | Missing: one Application file per service | P0 |
| | promotion to staging/prod with a gate | Missing (overlays only) | P2 |
| **CI** | central reusable workflow, thin caller, pinned version | Missing (G4) | **P0** |
| | lint (ruff), types (mypy), tests (pytest + coverage gate) | Missing (G3) | **P0** |
| | native arm64 build, immutable SHA tags, OIDC to AWS | Have | - |
| | vuln gate (Trivy image + filesystem/deps) | Partial (image only) | P1 |
| | SBOM, cosign keyless signature, SLSA provenance | Missing (G7) | P1 |
| | actions pinned by SHA, least-privilege `permissions:` | Partial | P1 |
| | Dependabot/Renovate for deps + base image | Missing | P1 |
| **Code skeleton** | dependency lock (uv + `uv.lock`), `pyproject.toml` | Missing (plain requirements.txt) | P0 |
| | settings from env (pydantic-settings), structured JSON logs with request id | Missing | P0 |
| | liveness vs readiness (readiness checks dependencies), graceful shutdown | Partial (one /health) | P0 |
| | `/metrics` (Prometheus), OpenTelemetry tracing hooks | Missing | P1 (needs Step 34 stack) |
| | feature flag client helper (our own flag service) | Missing | P1 (planned) |
| | example tests, pre-commit, Makefile/justfile, `.editorconfig` | Missing | P0 |
| **Container** | multi-stage build, base pinned by digest, non-root, no shell tools needed at runtime | Partial (non-root, single stage, tag not digest) | P0 |
| **Kubernetes** | shared base maintained centrally (Kustomize component / remote base) | Missing (G5, copied) | **P0** |
| | zero-downtime set (maxUnavailable 0, preStop, readiness gate, PDB, HPA, spread, priority) | Have (Step 28) | - |
| | Pod Security "restricted": readOnlyRootFilesystem, drop ALL, seccomp RuntimeDefault, no SA token | Partial (non-root, no privilege escalation) | P0 |
| | own ServiceAccount (IRSA-ready), startupProbe | Missing | P0 |
| | NetworkPolicy default-deny | Missing (VPC CNI needs network policy enabled, costs memory) | P2 |
| | LimitRange/ResourceQuota per namespace | Missing | P1 |
| **Catalog** | owner = Group (OwnerPicker), System, lifecycle chosen, API entity from OpenAPI | Partial (G8) | P0 |
| | TechDocs (mkdocs + docs/), runbook, links to dashboards/logs/Argo | Missing (G6) | P0 (docs), P1 (links) |
| | plugin annotations (Argo CD, Kubernetes, GitHub Actions) | Partial (k8s id only; plugins are Step 31) | P1 |
| **Repo** | branch ruleset on main (required checks), CODEOWNERS, secret scanning + push protection | Missing | P1 |
| **Template itself** | tested in CI (render -> lint/test/build/kubeconform/kyverno) | Missing (tested by hand once) | **P0** |
| | versioned; generated repos record the template version | Missing | P1 |
| | form: pickers, validation, conditional options (DB? cache? public route?) | Partial | P1 |
| **Day 2** | add DB / add flag / promote / decommission templates | Missing (G9) | P1 |
| | scorecards (Tech Insights) | Missing | P2 (Step 31) |

---

## 4. Target design: zero-touch dev delivery

### 4.1 Options for "every green build deploys to dev"

| Option | How | Credentials | Verdict |
|---|---|---|---|
| A. CI bot in every repo (today's feature-flag-service pattern) | service CI mints an App token and commits the new tag to idp-gitops | the bot's **private key copied into every generated repo** (a personal account has no org-level secrets) | Reject: credential sprawl grows with every service. *Update (11.2 D1): with the org, one org secret would work for public repos, but every service repo's workflows could then read a key that writes to the deploy repo. Still rejected, now for least privilege* |
| B. **Argo CD Image Updater** | in-cluster controller watches ECR `svc/*`, strategy `newest-build` (SHA tags), writes `newTag` back to idp-gitops (git write-back) [9] | **one** GitHub credential in the cluster (via ESO) + IRSA for ECR read | **Recommended for dev.** Small (one pod), CRD-based since v1.0 |
| C. Kargo | Warehouse watches ECR, Stage `dev` auto-promotes; staging/prod gated [10] | one credential, in cluster | Best for multi-stage promotion. Heavier (controller + API + UI) on 2x t4g.small. Revisit when staging is real |
| D. App repo holds its own manifests + ApplicationSet SCM generator | no gitops repo PR at all | none extra | Reject: loses the config-repo separation Argo CD recommends [1], and tag bumps inside the app repo cause CI loops |

Note on B: ECR tokens expire (12h). The updater must use IRSA plus a credentials helper, or a
refreshed pull secret. Verify against the Argo CD 3.5 / Image Updater version matrix at build
time [9].

### 4.2 Onboarding (the first deploy) without a click

The ordering problem: the deploy config pins an image that the new repo's CI has not pushed yet.

Target flow:

```
Form submit
 1. publish:github (user token)                -> repo + first CI run starts
 2. publish:github:pull-request (App)          -> idp-gitops PR: apps/<name>/overlays/dev ONLY
                                                  (no Argo Application file: the ApplicationSet finds it)
 3. idp:github:await-and-merge (custom action) -> waits for (a) the service CI run on the first
                                                  commit and (b) idp-gitops validation checks on the PR;
                                                  both green -> merge (App). Any red -> task fails,
                                                  PR stays open with the reason.
                                                  REVISED (11.6): waits for (a) only, then turns on
                                                  GitHub's native auto-merge; GitHub enforces (b).
 4. catalog:register
 Argo ApplicationSet (git directory generator over apps/*/overlays/dev) -> Application -> sync -> ALB route
Every later push to main: CI (reusable workflow) -> ECR -> Image Updater writes newTag -> Argo syncs
```

- The PR still exists as the audit record (who asked, which task, which commit), but nobody clicks it.
- idp-gitops gets a validation workflow (`kustomize build` + kubeconform + Kyverno CLI), so a bad
  config cannot merge, whether a human or a bot wrote it.
- The custom action is a small scaffolder backend module in idp-portal (Octokit: poll
  check-runs/workflow runs for the SHA, then `pulls.merge`), with a timeout (for example 10 min).
- Staging/prod (later): a `promote` template opens a PR that a human approves, or Kargo stages.
  That is where the gate belongs.

---

## 5. Target design: making the path maintainable (fixing drift)

A template is copied once. Everything that must keep improving after day 1 moves out of the copy:

| Concern | Lives in (central, versioned) | Generated repo contains |
|---|---|---|
| CI pipeline | reusable workflow in a platform repo, e.g. `DSurya11/idp-platform/.github/workflows/python-service.yml@v1` [8] | a ~15-line caller with inputs |
| K8s deployment settings | Kustomize component in `idp-gitops/components/python-service` (the Step 28 set + pod security + SA) | an overlay with name, image, resources, env |
| Lint/type/test config | template skeleton (`pyproject.toml`), kept current by Dependabot | its own copy (normal for code) |
| Standards compliance | Tech Insights checks (template version, docs present, CI green) [14] | `backstage.io/source-template` annotation (written automatically by the built-in `catalog:write` action, 11.6) + a template version annotation |

Platform upgrade path: bump the reusable workflow `v1 -> v1.1` (non-breaking, callers on `@v1`
pick it up) or ship `v2` and let Dependabot/Renovate open PRs in service repos.

---

## 6. Proposed template catalog for this IDP (prioritized)

Strength over count: one golden path done properly beats five toy templates. Order:

### T1. `python-service` v2: the flagship golden path (P0)
- **Form:** name (validated), description, owner (OwnerPicker -> Group), system (EntityPicker),
  lifecycle, options: *needs Postgres*, *needs cache*, *public route on ALB (else internal only)*,
  *include feature flag client*.
- **Repo:** uv + `pyproject.toml` + `uv.lock`, ruff, mypy, pytest with coverage gate, example
  tests, pre-commit, Makefile, Dependabot, CODEOWNERS, `.editorconfig`.
- **App:** FastAPI, pydantic-settings, JSON logs with request id, `/health/live` and
  `/health/ready` (checks the DB/cache when enabled), graceful shutdown, `/metrics`, OpenTelemetry
  hooks (off until Step 34), feature flag helper (fail-safe default, cached), exported OpenAPI.
- **Container:** multi-stage, base pinned by digest, non-root 10001, compatible with a read-only root.
- **CI:** thin caller of the reusable workflow: lint, types, test, build arm64, Trivy (fs +
  image), SBOM, cosign keyless sign, provenance attestation, push. Actions pinned by SHA.
- **Deploy:** overlay on the central component, own ServiceAccount, restricted pod security,
  startupProbe, LimitRange. Zero-touch via section 4.
- **Catalog/docs:** Component + API (OpenAPI) + TechDocs (`mkdocs.yml`, `docs/index.md`,
  `docs/runbook.md`), links to Argo/ALB URL, template version annotation.
- **Tested:** idp-portal CI renders the template with fixed values and runs the generated repo's
  own checks + `kustomize build | kubeconform` + Kyverno CLI. A template change that produces a
  broken service fails before merge.

### T2. `add-feature-flag` (P1, domain-specific, the IDP's differentiator)
Day-2 template on an existing service (EntityPicker restricted to Components): creates the flag in
feature-flag-service through its API (percentage, targeting rules), registers it in the catalog as
a Resource that the component `dependsOn`, and opens a PR in the service repo adding the flag
check through the helper from T1. Needs a service credential for the flag API (ESO-managed, used
by a scaffolder action, never by the browser).

### T3. `add-postgres-database` (P1)
Day-2: a dedicated database + user on the shared RDS, the password in Secrets Manager, an
ExternalSecret in the service overlay, a catalog Resource. Design constraint: RDS is recreated
every session (Option B) and is private (`publicly_accessible=false`), so the laptop's Terraform
cannot run `CREATE DATABASE`. Provisioning must be declarative and in-cluster: a list in idp-gitops
(`platform/databases/<name>.yaml`) reconciled by an idempotent Job (Argo sync hook, master
credentials via ESO) or by a Postgres operator. It then re-creates itself after every `make up`.

### T4. `decommission-service` (P1)
Removes `apps/<name>` from idp-gitops (Argo prunes it, which removes the ALB rule), deletes ECR
`svc/<name>`, archives the repo, unregisters the catalog entities. Lifecycle is part of the path,
and on 2x t4g.small every abandoned service holds 2 pods of capacity.

### T5. `promote` (P2, when staging exists)
PR from dev tag -> staging/prod overlay with a required approval, or Kargo stages (section 4.1 C).

### Not planned (and why)
Other languages (Go, Node): nothing in this IDP needs them yet, and one excellent path is the
point. Library/package template: no internal package registry. Terraform-backed resource
templates (S3, SQS + IRSA): only when a service needs one (HANDOVER section 0a).

---

## 7. Constraints of this project that shape the design

| Constraint | Effect |
|---|---|
| ~~Personal GitHub account (no org)~~ **GitHub org `surya-idp` (Free) since 2026-09-27** | Free-plan org secrets reach public repos only [52]; an App installation token can now create org repos, so the user-token workaround (Finding 52) becomes optional (verify at build time); GitHub Teams exist (catalog owner Groups can map to them) |
| 2x t4g.small (2 GiB), HPA min 2 per service | every in-cluster addition (Image Updater, Kyverno, Kargo, observability) is weighed in memory; decommissioning matters |
| Destroy-every-session (Option B) | anything a template provisions must be declarative in Git or Terraform so `make up` recreates it; RDS data does not survive |
| No domain, Backstage via port-forward only | GitHub OAuth redirect is `localhost:7007`; no webhooks into the cluster (Argo polls, 3 min) |
| Credits (~$0.26/hr while up) | build and render-test templates **offline**; bring the cluster up only to verify end to end |

---

## 8. Implementation plan

**Status 2026-10-10: phases 1-4 are done and verified on the cluster (section 13).** Phases 5-7 are open.

Each phase ends with evidence (command output), per the HANDOVER convention.

| Phase | Work | Done when |
|---|---|---|
| 1. Delivery (P0) | ApplicationSet over `apps/*/overlays/dev` (project hard-coded); Image Updater (IRSA + one GitHub credential via ESO); await-CI-then-auto-merge action; Backstage App removed from the idp-gitops bypass list + "Allow auto-merge" on (11.6); idp-gitops validation workflow (exists, F2); template stops writing Application files | new service from the form reaches ALB 200 with **zero clicks**; a second push to it deploys automatically; time recorded |
| 2. Central CI + component (P0) | `idp-platform` repo with the reusable workflow (lint/type/test/build/scan/push); Kustomize component in idp-gitops; migrate `hello-svc` onto both | hello-svc repo CI is a thin caller; changing the component changes hello-svc on the next sync |
| 3. Skeleton v2 (P0) | uv/pyproject, tests, settings, logs, live/ready, pod security, SA, TechDocs, API entity, owner/system pickers | rendered skeleton passes its own CI locally and in GitHub; Trivy clean; restricted pod security admitted |
| 4. Template CI (P0) | render-and-test job in idp-portal CI (real scaffolder dry-run API on a CI-local backend, 11.2) | a deliberately broken skeleton change fails idp-portal CI |
| 5. Supply chain (P1) | SBOM + cosign keyless + provenance in the reusable workflow; Kyverno verifyImages (with Step 33) | an unsigned image is rejected by admission |
| 6. Day-2 (P1) | T2 add-feature-flag, T3 add-postgres-database, T4 decommission | each run end to end from the form |
| 7. Later (P2) | T5 promote / Kargo, NetworkPolicy, scorecards (Step 31), observability hooks live (Step 34) | - |

The feature-flag-service and idp-portal CI bots (option A) can move to Image Updater in phase 1 as
well, removing the CI bot private key from those repos.

---

## 9. Decisions (made by the user 2026-09-27)

1. Zero-touch mechanism: **the industry standard** -> Argo CD Image Updater now (Argo's own
   registry-to-Git tool, one in-cluster credential); Kargo when staging/prod exist.
2. Onboarding merge: **PR + automatic merge** after the service CI and idp-gitops `validate` pass.
3. Central CI repo: **`idp-platform`** (in the new GitHub org `surya-idp`).
4. `hello-svc`: **deleted** (repo, ECR `svc/hello-svc`, idp-gitops manifests via PR #6); a new demo
   service is created from template v2.
5. GitHub organization: **yes**, `surya-idp` (id 334455734, Free) - PLATFORM_REVIEW F16.

### Original options (kept for context)

1. Zero-touch mechanism: Image Updater now, Kargo later (recommended) vs Kargo now.
2. Onboarding merge: PR + automatic merge after checks (recommended, keeps an audit record) vs a
   direct commit to idp-gitops main.
3. The name of the central platform repo (`idp-platform` suggested) for reusable workflows.
4. Whether `hello-svc` is migrated to v2 (recommended: it proves the upgrade path) or decommissioned.

---

## 10. Sources

1. Argo CD, Best Practices (separate config repo): https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/
2. Spotify Engineering, How we use Golden Paths to solve fragmentation (2020): https://engineering.atspotify.com/2020/08/how-we-use-golden-paths-to-solve-fragmentation-in-our-software-ecosystem
3. Spotify for Backstage, Onboarding software / templates: https://backstage.spotify.com/learn/onboarding-software-to-backstage/setting-up-software-templates/11-spotify-templates/ and InfoQ on Spotify paved paths: https://www.infoq.com/news/2021/03/spotify-paved-paths/
4. CNCF TAG App Delivery, Platforms White Paper: https://tag-app-delivery.cncf.io/whitepapers/platforms/
5. CNCF TAG App Delivery, Platform Engineering Maturity Model: https://tag-app-delivery.cncf.io/whitepapers/platform-eng-maturity-model/
6. Scale Wars #6, Spotify golden paths: https://dev.to/turacthethinker/scale-wars-6-spotify-the-squad-model-and-the-power-of-golden-paths-4poa
7. Red Hat Developer, 10 tips for better Backstage Software Templates (2025): https://developers.redhat.com/articles/2025/03/17/10-tips-better-backstage-software-templates
8. Reusable workflows as a platform (versioned `workflow_call`): https://rajivonai.com/blog/2024-08-20-github-actions-for-platform-teams-reusable-workflows-oidc-environments-and-audit/ and https://techcommunity.microsoft.com/blog/azureinfrastructureblog/cicd-as-a-platform-shipping-microservices-and-ai-agents-with-reusable-github-act/4504550
9. Argo CD Image Updater, update methods and v1 migration: https://argocd-image-updater.readthedocs.io/en/stable/basics/update-methods/ and https://argocd-image-updater.readthedocs.io/en/stable/configuration/migration/ ; ECR setup: https://devopscube.com/setup-argocd-image-updater/
10. Akuity, Kargo (promotion layer for GitOps): https://akuity.io/blog/how-kargo-fixes-gitops-with-promotion and https://docs.kargo.io/user-guide/how-to-guides/working-with-stages
11. Argo CD ApplicationSet, Git generator: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/
12. Kyverno, Verify SLSA provenance (keyless): https://kyverno.io/policies/other/verify-image-slsa/verify-image-slsa/
13. Cosign keyless signing with GitHub Actions OIDC: https://www.qcecuring.com/blog/sigstore-cosign-keyless-github-actions
14. Roadie, Tech Insights scorecards: https://roadie.io/backstage/plugins/tech-insights/ ; Spotify Soundcheck: https://backstage.spotify.com/partners/spotify/plugin/soundcheck
15. Argo CD Image Updater releases (v1.3.0 2026-08-13, v1.2.0 2026-05-04; dates from the GitHub API): https://github.com/argoproj-labs/argocd-image-updater/releases
16. Argo CD Image Updater README (project status warning): https://github.com/argoproj-labs/argocd-image-updater
17. Argo CD Image Updater docs, overview and limitations (v1.x, CRD-based): https://argocd-image-updater.readthedocs.io/en/stable/
18. Image Updater update methods (git write-back targets, PR mode, commits via GitHub API): https://argocd-image-updater.readthedocs.io/en/stable/basics/update-methods/
19. Image Updater registries (`ext:` credential scripts, `credsexpire`): https://argocd-image-updater.readthedocs.io/en/stable/configuration/registries/
20. argoproj/argo-cd issue #7385, "Merge Argo CD Image Updater into Argo CD" (open since 2021-10-07): https://github.com/argoproj/argo-cd/issues/7385
21. CNCF, Argo CD End User Survey announcement (2025-07-24): https://www.cncf.io/announcements/2025/07/24/cncf-end-user-survey-finds-argo-cd-as-majority-adopted-gitops-solution-for-kubernetes/
22. Argo Project blog, Argo CD 2026 User Survey Results (2026-07-09). **Could not open (HTTP 403 to both WebFetch and curl)**; figures quoted from a search-engine summary only: https://blog.argoproj.io/argo-cd-2026-user-survey-results-dcffc9a8e48e
23. Kargo releases (v1.11.4 2026-09-03, v1.12.0-rc.1 2026-09-23) and install prerequisites: https://github.com/akuity/kargo/releases , https://docs.kargo.io/operator-guide/basic-installation
24. GitOps Promoter (argoproj-labs, v0.42.1 2026-09-25, API v1alpha1): https://github.com/argoproj-labs/gitops-promoter ; Argo CD Source Hydrator ("Beta Feature (Since v3.5.0)"): https://argo-cd.readthedocs.io/en/stable/user-guide/source-hydrator/
25. A. R. Daftuar, "CI to GitOps Handoff: Argo Image Updater vs. CI-Writes-the-Commit vs. Kargo" (2026-09-03): https://aloknecessary.in/blogs/ci-to-gitops-handoff/
26. Argo CD, ApplicationSet security: https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Security/
27. GitHub Docs, Automatically merging a pull request: https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request
28. GitHub GraphQL `enablePullRequestAutoMerge` (inputs checked by schema introspection with `gh api graphql`): https://docs.github.com/en/graphql/reference/mutations#enablepullrequestautomerge
29. GitHub Docs, Creating rulesets (bypass "Always" vs "For pull requests only"): https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository
30. Backstage PR #34947, `autoMerge` input for `publish:gitlab:merge-request` (merged 2026-08-29, released in v1.55.0): https://github.com/backstage/backstage/pull/34947
31. GitHub Docs, Reusing workflows (limits, pinning): https://docs.github.com/en/actions/sharing-automations/reusing-workflows
32. GitHub Docs, Artifact attestations (SLSA Build L2) and reaching SLSA Build L3 with reusable workflows: https://docs.github.com/en/actions/concepts/security/artifact-attestations , https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/increase-security-rating
33. Grafana Labs, public shared-workflows repo (per-component release tags, e.g. `get-vault-secrets/v2.1.0` 2026-09-15): https://github.com/grafana/shared-workflows
34. Kustomize, Components: https://kubectl.docs.kubernetes.io/guides/config_management/components/
35. CNCF Annual Survey 2024 (published 2025-04; PDF text checked: Helm 75%, Kustomize 14% as preferred packaging): https://www.cncf.io/wp-content/uploads/2025/04/cncf_annual_survey24_031225a.pdf
36. Generic "one chart for every app" Helm charts, maintained in 2026: https://github.com/stakater/application , https://github.com/bjw-s-labs/helm-charts
37. Backstage, template dry-run testing: https://backstage.io/docs/features/software-templates/dry-run-testing/ ; CI script against `/api/scaffolder/v2/dry-run`: https://github.com/backstage/backstage/blob/master/contrib/scaffolder/template-testing-dry-run.md ; `backstage-cli template dry-run` (only in the "next" docs as of v1.55): https://backstage.io/docs/next/tooling/cli/module-scaffolder/
38. Backstage issues asking to update components after scaffolding, all closed NOT_PLANNED by the stale bot: #14416 (2022, 23 reactions), #30494 (2025), #31361 (2025): https://github.com/backstage/backstage/issues/14416 , https://github.com/backstage/backstage/issues/31361
39. Spotify Engineering, Fleet Management Part 3: Fleet-wide refactoring (2023-05): https://engineering.atspotify.com/2023/05/fleet-management-at-spotify-part-3-fleet-wide-refactoring
40. TechTarget, "Behind the scenes, Spotify's Backstage a work in progress" (2023-11-07): https://www.techtarget.com/searchitoperations/news/366558592/Behind-the-scenes-Spotify-Backstage-a-work-in-progress
41. Stack Overflow blog/podcast with Pia Nilsson (Spotify), 2025-09-26: https://stackoverflow.blog/2025/09/26/getting-backstage-in-front-of-a-shifting-dev-experience/
42. Earthly (a dev-tools vendor), "Backstage Is at the Peak of Its Hype" (2025-07-15): https://earthly.dev/blog/backstage-is-at-peak-hype/
43. platformengineering.org (launched by Humanitec, a platform-orchestrator vendor), "How to pave golden paths that actually go somewhere" (2023-12-13): https://platformengineering.org/blog/how-to-pave-golden-paths-that-actually-go-somewhere ; affiliation: https://humanitec.com/newsletter/vol-35-community-matters-were-doubling-down-on-you
44. Google Cloud blog, Platform engineering control mechanisms (2025-08-16): https://cloud.google.com/blog/products/application-modernization/platform-engineering-control-mechanisms
45. Thoughtworks Technology Radar, Backstage (Adopt, **last assessed Oct 2022, outdated**): https://www.thoughtworks.com/en-us/radar/platforms/backstage
46. Hacker News practitioner comments (via the Algolia HN API): 2024-05-04 https://news.ycombinator.com/item?id=40259435 and https://news.ycombinator.com/item?id=40259501 ; 2026-04-12 (from a competing vendor) https://news.ycombinator.com/item?id=47745340
47. American Airlines "Runway" (Backstage + Argo CD via a Roadie plugin), DX newsletter 2023-04-05: https://newsletter.getdx.com/p/implementing-a-developer-portal (their own blog tech.aa.com did not resolve, DNS error)
48. Backstage blog, BackstageCon + KubeCon NA 2025 recap (RBC talk "Supercharging Backstage Scaffolder for Workflows"; title only, talk not reviewed): https://backstage.io/blog/2025/11/25/backstagecon-kubecon-25-atlanta/
49. Red Hat Developer Hub software templates ("learning aids, NOT intended for production use"): https://github.com/redhat-developer/red-hat-developer-hub-software-templates
50. PSF + JetBrains, Python Developers Survey 2024 (collected Oct-Nov 2024, published 2025; newest found): https://lp.jetbrains.com/python-developers-survey-2024/
51. Backstage source, built-in `catalog:write` adds `backstage.io/source-template` (checked in the installed plugin-scaffolder-backend of idp-portal): https://github.com/backstage/backstage/blob/master/plugins/scaffolder-backend/src/scaffolder/actions/builtin/catalog/write.ts
52. GitHub Docs, Using secrets ("Organization-level secrets ... are not accessible by private repositories for GitHub Free"): https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets

---

## 11. Evidence review (2026-09-27, Session 8)

Every claim in sections 2-9 was re-checked against a source I could open. New sources are [15]-[52]
in section 10.

### 11.0 Method, labels and access limits

**Labels used below:**
- **OFFICIAL**: the project's or vendor's own docs, source code or issue tracker. Facts about the tool.
- **CONSENSUS**: several independent sources agree (official docs, surveys, companies unrelated to each other).
- **SURVEY**: measured data (CNCF, Argo CD, PSF surveys). Say the year.
- **OPINION**: one blog, talk or thread. Useful, but only one voice.
- **VENDOR**: written by a company that sells a product in this space. Read the claim, discount the conclusion.

**What I could not read (not filled in from memory):**
- **Reddit** (r/devops, r/kubernetes, r/platformengineering, r/sre): blocked for every tool I have.
  WebFetch refuses the domain, the JSON API returns a block page, old.reddit returns HTTP 403, and the
  search tool rejects `reddit.com`. **This review contains no Reddit evidence.** Hacker News (via the
  Algolia API) and GitHub issues stand in for practitioner opinion.
- **Argo Project blog on Medium** (2025 and 2026 Argo CD user surveys): HTTP 403. The CNCF announcement
  of the 2025 survey [21] was readable and is quoted instead. 2026 figures appear only as "unverified".
- **tech.aa.com** (American Airlines engineering blog): DNS failure. A 2023 DX newsletter [47] is used.

**Versions checked on 2026-09-27 (GitHub API):** Argo CD v3.5.3 (3.6.0-rc1 out), Image Updater v1.3.0
(2026-08-13), Kargo v1.11.4 (2026-09-03), GitOps Promoter v0.42.1 (2026-09-25), Backstage v1.55.2
(idp-portal runs 1.54.0), uv 0.12.19.

**Outdated sources, flagged:** Thoughtworks Radar on Backstage is from Oct 2022 [45]. The "10% adoption"
figure is from 2023 [40]. Spotify's golden-path post is from 2020 [2], but it is where the term comes from.
The newest Python survey found covers 2024 [50].

### 11.1 Verdict on the five decisions (section 9)

| # | Decision | Industry standard? | Verdict |
|---|---|---|---|
| D1 | Image Updater for dev auto-deploy, Kargo later | **There is no standard for this step.** CNCF, 2025: "environment promotion remains a major challenge. Most teams still rely on manual processes or custom scripts ... a standard solution has yet to emerge" [21] (SURVEY) | **Keep.** Our case is defensible, but don't call it "the standard". The most common real practice is CI committing the tag (what feature-flag-service does today) |
| D2 | First deploy = PR + automatic merge | PR as audit record + machine merge after required checks is how GitHub/GitLab auto-merge work [27]; Backstage added native auto-merge for GitLab in v1.55 [30] (OFFICIAL) | **Keep the decision, change the mechanism** (11.2 D2): use GitHub's native auto-merge, and take the Backstage App off the ruleset bypass list |
| D3 | Shared CI repo `idp-platform` (reusable workflows) | CONSENSUS: GitHub docs [31][32], Grafana Labs runs this publicly [33], Spotify's central-artifact model [39] | **Keep.** Adds a supply-chain argument: reusable workflows are GitHub's route to SLSA Build L3 [32] |
| D4 | hello-svc deleted, new demo from v2 | No industry question | **Keep.** The upgrade-path proof (section 8 phase 2) moves to the new demo service |
| D5 | GitHub org `surya-idp` | Consistent with PLATFORM_REVIEW F16 | **Keep.** New constraint: Free-plan org secrets reach only public repos [52] |

**None of the five decisions is contradicted by the evidence.** One design detail inside the plan does
not match the most common practice: the shared deploy config (11.2, "Shared deploy config"). It needs
your decision.

### 11.2 Claim-by-claim evidence

**D1. How a new image reaches the dev environment**

| Claim | Evidence | Label |
|---|---|---|
| No standard tool exists for moving images between environments | CNCF 2025 quote above [21]. Emerging tools named: GitOps Promoter, Kargo, Codefresh GitOps | SURVEY |
| The three real patterns are CI commits the tag, a registry-watching controller (Image Updater) and a promotion controller (Kargo) | [25] compares exactly these three; the same split appears in the Image Updater and Kargo docs [17][23] | OPINION (one comparison) + OFFICIAL (each tool's docs) |
| Image Updater is an Argo project, active, and v1.x is CRD-based | argoproj-labs; v1.3.0 2026-08-13; v1.2.0 added PR mode, metrics and a status subresource, and made namespace scope the default (breaking) [15][17] | OFFICIAL |
| Image Updater is **not** declared production-ready | README: "We would not recommend it yet for _critical_ production workloads" [16]. The proposal to merge it into Argo CD has been open since 2021 [20] | OFFICIAL. Acceptable for a dev environment, and it must be said in an interview |
| It only works with Kustomize, Helm or CMP apps and needs Argo CD | [17] | OFFICIAL. Fine: our overlays are Kustomize |
| It can commit through the GitHub API as a GitHub App (signed commits) | `GIT_COMMIT_METHOD=api` [18] | OFFICIAL |
| ECR needs a credential script | ECR is not a built-in provider: use an `ext:` script with `credsexpire` [19]. ECR tokens last 12h | OFFICIAL. Extra work in phase 1 |
| Why Image Updater over CI commits here | With CI commits, every service repo needs a credential that can write to idp-gitops. With the org this is now possible (one org secret, public repos only [52]), but any workflow in any service repo could read a key that writes to the deploy repo, and that key bypasses the main ruleset. With Image Updater that credential lives only in the cluster, and service CI only pushes to ECR | Our reasoning from [18][52]. Least privilege is CONSENSUS; the trade-off itself is ours |
| Kargo is GA but heavier | v1.11.4 is stable [23]; cert-manager is required with the default configuration; it adds a controller, API server and webhooks. Built by Akuity (VENDOR, also the creators of Argo) | OFFICIAL |
| GitOps Promoter is Argo's newer answer, still early | v0.42, API `v1alpha1`, needs a hydrator (Argo CD Source Hydrator is Beta since 3.5) [24] | OFFICIAL. Revisit together with Kargo when staging exists |

**D2. The first deploy: PR + automatic merge**

| Claim | Evidence | Label |
|---|---|---|
| GitHub has native auto-merge: the PR merges when all required reviews and checks pass | [27]; the GraphQL mutation `enablePullRequestAutoMerge` takes `pullRequestId`, `mergeMethod` and `expectedHeadOid` [28] | OFFICIAL |
| Backstage chose the platform's native auto-merge rather than polling | v1.55 added `autoMerge` to `publish:gitlab:merge-request`, "merged automatically once all merge checks succeed" [30]. No GitHub equivalent exists yet (searched the backstage and community-plugins repos) | OFFICIAL (upstream precedent) |
| **Our ruleset would let the Backstage App skip `validate`** | `gh api repos/surya-idp/idp-gitops/rulesets/24067635`: bypass actors are 5034584 (idp-ci-bot) **and 5088974 (idp-backstage-surya)**, both `bypass_mode: always`. "Always" means that actor skips the rules [29] | Verified by command output |
| idp-gitops does not allow auto-merge yet | `gh api repos/surya-idp/idp-gitops` -> `allow_auto_merge: false` | Verified by command output |
| A human merge in dev adds no information | Google's taxonomy: use manual checkpoints where human judgment is needed; "overly burdensome manual gates can become significant bottlenecks" [44] | VENDOR-neutral official blog (Google Cloud), OPINION-level guidance |

**D3. Central CI (`idp-platform`)**

| Claim | Evidence | Label |
|---|---|---|
| Reusable workflows are GitHub's mechanism for shared CI | [31]: up to 10 levels of nesting, no loops; environment secrets cannot be passed through `workflow_call`; "Using the commit SHA is the safest option" | OFFICIAL |
| Central workflows make provenance stronger | Artifact attestations give SLSA Build L2; with reusable workflows, L3; `gh attestation verify --signer-workflow` pins which workflow may sign [32] | OFFICIAL |
| Real companies run central, versioned CI | Grafana Labs `shared-workflows`: public, per-component release tags via release-please [33] | CONSENSUS (with [8]) |
| Platform changes should reach every repo automatically | Spotify: 270,000+ automated PRs in 2022, 77% auto-merged; framework rollout to 70% of services dropped from ~200 days to under 7 [39] | OFFICIAL (Spotify engineering, 2023) |

**Separate config repo and ApplicationSet**

| Claim | Evidence | Label |
|---|---|---|
| Deploy config in its own repo | Argo CD best practices [1] | OFFICIAL, and the norm in the Argo docs |
| ApplicationSets are mainstream | CNCF 2025 names "AppSets" among the most valued features [21]. The 2026 Argo survey reportedly shows 66% -> 76% usage [22] (**unverified**, page returned 403) | SURVEY |
| ApplicationSet risk: templated `project` | "a malicious user with write access to the generator's source of truth ... could create Applications under Projects with insufficient restrictions"; only admins should manage ApplicationSets [26] | OFFICIAL -> **hard-code `project: apps`** |

**Shared deploy config: Kustomize component vs a shared Helm chart (your decision)**

| Claim | Evidence | Label |
|---|---|---|
| Helm is the dominant packaging tool | Helm 75%, Kustomize 14% as the preferred way to package K8s apps (2024) [35]. Note: this is packaging in general, including third-party charts, not golden paths | SURVEY |
| "One generic chart for every service" is a real, maintained pattern | stakater/application and bjw-s app-template, both updated in Sep 2026 [36] | CONSENSUS among practitioners, **not measured** |
| Kustomize components are meant for optional features | "applications that support multiple optional features" [34] | OFFICIAL |

Recommendation: **stay on Kustomize**, but use components for what the docs describe them for:
- one `golden-path` component applies the Step 28 hardening to the service's Deployment (patches
  targeted by kind);
- opt-in components cover the form options (postgres, cache, public-route).

Why stay: the entire platform (feature-flag-service, idp-portal, Image Updater's `kustomization`
write-back target) is Kustomize. A chart needs a release pipeline and an OCI registry, plus
registry credentials in Argo CD. On ECR that brings back the 12h-token problem.

The trade-off: a component lives in the same repo, so a change reaches every service at once. You
cannot pin one service to an older version. The `validate` check renders every overlay before
merge, which limits the damage.

When to switch to a versioned chart: when several teams or real staging and prod environments need
a platform change rolled out in stages.

**Template testing**

| Claim | Evidence | Label |
|---|---|---|
| The official way to test a template is a dry run | `/api/scaffolder/v2/dry-run` returns the rendered files; the contrib script uses it in CI; it **needs a running backend** [37] | OFFICIAL |
| The CLI `template dry-run` command is not released yet | appears only in the "next" docs as of v1.55 [37] | OFFICIAL -> plan: start the idp-portal backend in CI (in-memory DB, static token), call the API, then run the rendered repo's own checks + `kustomize build \| kubeconform` |
| Test templates in CI | Red Hat's tips [7] | VENDOR (Red Hat sells a Backstage distribution); consistent with [37] |

**Skeleton stack**

| Choice | Evidence (2024 survey, newest found [50]) | Label |
|---|---|---|
| FastAPI | most-used Python web framework: 38% (Django 35%, Flask 34%) | SURVEY |
| pytest | 53% (unittest 23%) | SURVEY, consensus |
| uv + lock file | **only 12%** (pip 74%, Poetry 20%), but in its first year. The choice rests on the lock file and speed, not on popularity | SURVEY. Say "fast-growing", not "standard" |
| ruff | named in the survey as part of the Rust-tooling trend; no usage % found | OPINION-level; widely used, not quantified here |

### 11.3 Criticisms of golden paths and Backstage templates, and how this design answers them

| Criticism | Source (label, date) | How we avoid it |
|---|---|---|
| **Low adoption:** average Backstage adoption outside Spotify ~10% vs 99% inside; adopters stall at proof of concept without a clear developer problem | TechTarget reporting Spotify's own estimate [40] (2023, dated); repeated by a vendor in 2025 [42] | Solve one measured problem (form -> running service, time recorded); the path is optional, as at Spotify ("if you are an adventurer ... you will not have the same support") [2] |
| **Backstage is a framework you build and run, not a product** | HN: a ~3,000-engineer company succeeded "with a dedicated team", but migrating old tooling onto templates "has been a struggle"; for ~50 engineers they would buy instead [46] (OPINION, 2024). Earthly: plugin work is "table stakes" [42] (VENDOR, 2025) | Few plugins, templates in one repo (Finding 53), Backstage kept current by Dependabot (F11). In an interview: at 50 engineers, buying (Port, Cortex, Roadie) is a fair choice |
| **Templates are one-shot, so generated repos drift** | Three upstream requests to update scaffolded components, all closed NOT_PLANNED by the stale bot, the latest in 2025 [38] (OFFICIAL) | Section 5: CI and deploy settings live centrally (idp-platform, component); only app code is copied; Dependabot bump PRs; `backstage.io/source-template` lets us list every service made from a template [51] |
| **How Spotify actually fixes drift:** central versioned artifacts plus automated fleet-wide PRs, mostly auto-merged | [39] (OFFICIAL, 2023) | Same model at small scale: reusable workflow pinned by SHA, Dependabot opens the bump PRs, auto-merge when green |
| **Day-1 bias:** creation is "below 1%" of the time spent on an application; paths ignore day 2 | [43] (VENDOR-affiliated: Humanitec, 2023); Earthly: templates only help new services [42] (VENDOR) | Every later push deploys itself (D1); day-2 templates T2-T4 are in the plan, not an afterthought |
| **Demo templates are not golden paths** | Red Hat's own 60+ templates are "learning aids, NOT intended for production use" [49] (VENDOR, about itself) | Tested in CI, maintained centrally, backed by guardrails |
| **Scorecards become "a dashboard of guilt that nobody looks at"; ownership data decays** | [42] (VENDOR opinion) | Enforce with guardrails (PSA, AppProjects, required checks), not dashboards [44]. Owner comes from the form (Group) and lives in the repo's catalog-info |
| **Templates cost a lot and go unused without user input** | HN: "be sure to get plenty of stakeholder feedback so the thing you make is something that actually gets used"; the upstream sample template repo was stale [46] (OPINION, 2024) | v2 is built from a real service's lessons (Step 28, the feature flag service). In an interview: say who the users are and what was measured |
| **Mandatory paths become a "golden cage"** | Spotify: the path is optional [2]; Google: golden paths steer, guardrails stop [44] | The path is optional; guardrails (PSA, AppProjects, `validate`) apply to everyone, on or off the path |

### 11.4 Our design vs what real companies run

| | Scaffolding | CI | Deploy | Day 2 / drift | Source |
|---|---|---|---|---|---|
| **Spotify** | Backstage templates (the origin), golden-path tutorials in TechDocs, path optional | internal | internal (not Argo) | central BOM (96% of backend services), Fleetshift PRs (77% auto-merged), Soundcheck scorecards | [2][39][41] |
| **American Airlines (Runway)** | Backstage "Create App" template library | not described | Argo CD, integrated with Roadie (open-sourced plugin) | not described | [47] (2023; their blog unreachable) |
| **Grafana Labs** | not public | central `shared-workflows`, per-action release tags | not public | versioned, release-please | [33] |
| **Royal Bank of Canada** | extends the Backstage scaffolder for workflows (BackstageCon NA 2025) | - | - | - | [48] (title only) |
| **Red Hat reference templates** | 60+ templates, Argo CD and Tekton or GitHub Actions | per template | Argo CD | none: "learning aids" | [49] |
| **This IDP (v2 plan)** | Backstage template, optional, tested in CI | `idp-platform` reusable workflow, SHA-pinned, attestations | separate gitops repo, ApplicationSet, Image Updater (dev) | central CI + component, Dependabot bumps, source-template annotation, day-2 templates | this file |

Honest gap: no public source describes a whole company pipeline (template -> CI -> GitOps -> day 2) end
to end. The table is assembled from parts. Most published "Backstage + Argo CD" material is tutorials
and was not counted as evidence.

### 11.5 What the research did not change

The separate config repo, ApplicationSet discovery, the zero-downtime settings from Step 28, TechDocs
in every template, supply-chain attestations, the day-2 templates and doing all of it offline first.

### 11.6 Changes to the plan (apply in phases 1-4)

1. **Auto-merge (phase 1).** The custom action shrinks to: wait for the new repo's first CI run to
   succeed, then call `enablePullRequestAutoMerge` on the idp-gitops PR. GitHub then merges only when
   `validate` is green. This needs two settings changes on idp-gitops, which a repo admin makes
   through the API or the UI:
   - remove `idp-backstage-surya` (5088974) from the ruleset bypass list. It only opens PRs and never
     needs to bypass.
   - turn on "Allow auto-merge".

   `idp-ci-bot` keeps its bypass so Image Updater can commit tag bumps directly. Image Updater's PR
   mode (v1.2+) is the stricter option if bot commits should also pass `validate`. For dev, tag-only
   commits don't need it.
2. **ApplicationSet (phase 1):** `project: apps` hard-coded in the template, never taken from the path [26].
3. **Image Updater (phase 1):** v1.3.x; `ImageUpdater` CRD; namespace scope (the v1.2 default); ECR
   through an `ext:` script with IRSA and `credsexpire` [19]; `writeBackTarget: kustomization`; commits
   through the GitHub API as `idp-ci-bot`, so they are signed [18]. Pending reminder: limit the
   idp-ci-bot installation to idp-gitops (your REMINDERS.md item).
4. **Central CI (phase 2):** callers pin the reusable workflow by SHA, as F11 does for actions.
   Dependabot opens the bump PRs, and they auto-merge when CI is green (Spotify's model [39]).
   Provenance is verified with `--signer-workflow` pointing at the idp-platform workflow [32].
5. **Shared deploy config (phase 2):** Kustomize components as described in 11.2. **Decided 2026-10-10: Kustomize components.**
6. **Catalog (phase 3):** write catalog-info with the built-in `catalog:write`, which adds
   `backstage.io/source-template` [51]; the template version goes in a second annotation.
7. **Template CI (phase 4):** the dry-run API on a backend started in CI [37]. It does not use a
   home-made renderer, which could drift from the real scaffolder.
8. **Repo creation (phase 3, optional):** in an org, the App's installation token can create repos. The
   user-token workaround (Finding 52) can then go, but the repo would be created by the bot instead of
   the person. Verify at build time before choosing.

---

## 12. Interview explainer (say it out loud)

**The 30-second version.** "A developer fills in one form. It creates a repo from a tested template.
The repo's CI is a thin call into a central, versioned pipeline, and a PR in a separate GitOps repo
merges itself once the first image exists and validation passes. An ApplicationSet picks the service
up, and from then on every green build deploys to dev with no human. Anything that must improve after
day 1, like CI and deploy hardening, lives centrally, so fixing it once fixes every service. Humans
approve where their judgment adds something: production, not dev."

Each choice below: **what** we chose, **instead of** what, **why**, the **trade-off**, and the **source**.

**1. What a golden path is**
- **What:** an optional, supported, opinionated path: template + central CI + central deploy settings + docs.
- **Instead of:** a template that copies everything once.
- **Why:** copies drift. Spotify's answer is central artifacts plus automated update PRs.
- **Trade-off:** the platform team owns the central pieces forever.
- **Source:** Spotify [2][39]; Backstage has no built-in update for scaffolded repos [38].

**2. Separate GitOps repo**
- **What:** deploy config in idp-gitops, not in the app repo.
- **Instead of:** manifests next to the code.
- **Why:** clean audit log, separate access, and bot tag commits don't retrigger app CI.
- **Trade-off:** two repos to change for some features.
- **Source:** Argo CD best practices [1].

**3. ApplicationSet discovery**
- **What:** a Git directory generator creates an Argo Application per `apps/*/overlays/dev`.
- **Instead of:** one hand-written Application file per service.
- **Why:** onboarding adds no platform files, and AppSets are mainstream.
- **Trade-off:** whoever can write the repo can create apps, so the project is hard-coded and main is protected.
- **Source:** [11][21][26].

**4. First deploy: PR + native auto-merge**
- **What:** the template opens a PR, waits for the first image, then turns on GitHub auto-merge. GitHub merges when `validate` passes.
- **Instead of:** a human clicking merge, or a bot pushing to main.
- **Why:** keeps an audit record without a human who adds nothing, and GitHub enforces the checks, not our code.
- **Trade-off:** the bot must not be on the bypass list, or the checks become optional.
- **Source:** [27][28][29]; Backstage did the same for GitLab in v1.55 [30].

**5. Every later deploy: Argo CD Image Updater**
- **What:** an in-cluster controller watches ECR and commits the new tag to idp-gitops.
- **Instead of:** each service's CI committing the tag (the most common practice), or Kargo.
- **Why:** only one credential can write the deploy repo, and it lives in the cluster. Service CI can only push images.
- **Trade-off:** polling delay (minutes); the project itself says it is not for critical production; ECR needs a credential script.
- **Source:** [16][18][19]; CNCF: no standard for this step yet [21].

**6. Promotion beyond dev: later, with a gate**
- **What:** dev is automatic. Staging and prod will promote the exact artifact that passed, with approval.
- **Instead of:** auto-deploying everything, or pretending a prod exists.
- **Why:** that is where human judgment adds value.
- **Trade-off:** not built yet. Choose between Kargo (GA, heavier, vendor-backed) and GitOps Promoter (Argo, pre-1.0) when staging exists.
- **Source:** [23][24][44].

**7. Central CI: `idp-platform` reusable workflows**
- **What:** each service has a ~15-line caller pinned by SHA; Dependabot bumps it.
- **Instead of:** 70 lines of copied CI per repo.
- **Why:** one fix reaches every service, and reusable workflows plus attestations reach SLSA Build L3.
- **Trade-off:** a breaking change needs a major version, and callers cannot pass environment secrets.
- **Source:** [31][32]; Grafana Labs does it publicly [33].

**8. Shared deploy settings: Kustomize components**
- **What:** a central component adds the zero-downtime and pod-security settings; opt-in components cover the DB, cache and public route.
- **Instead of:** a shared Helm chart, which is more common.
- **Why:** the whole platform is Kustomize, and a chart would need an OCI registry and ECR tokens in Argo.
- **Trade-off:** no per-service version pin; `validate` renders every service before merge to compensate.
- **Source:** [34][35][36].

**9. Templates are tested like code**
- **What:** idp-portal CI runs the real scaffolder dry-run, then the generated repo's own lint, tests and build, plus `kustomize build | kubeconform`.
- **Instead of:** testing by hand once.
- **Why:** a template change that produces a broken service must fail before merge.
- **Trade-off:** CI must start a Backstage backend, which is slower.
- **Source:** [37][7].

**10. Skeleton stack**
- **What:** FastAPI, pytest, uv with a lock file, ruff, mypy.
- **Instead of:** pip + requirements.txt.
- **Why:** FastAPI (38%) and pytest (53%) are the most used, and uv gives reproducible installs.
- **Trade-off:** uv is only 12% (fast-growing, not the majority); Poetry (20%) is the conservative choice.
- **Source:** [50].

**11. Supply chain**
- **What:** SBOM, build provenance attestation, keyless signing; admission rejects unsigned images (Kyverno, with Step 33).
- **Instead of:** trusting any image in ECR.
- **Why:** proves that what runs came from our CI.
- **Trade-off:** another controller on small nodes.
- **Source:** [12][13][32].

**12. Keeping services on the path (day 2)**
- **What:** central pieces, Dependabot PRs, a `backstage.io/source-template` annotation, and day-2 templates (add flag, add DB, decommission).
- **Instead of:** scorecards alone.
- **Why:** templates only help day 1, and dashboards get ignored; automation and guardrails don't.
- **Trade-off:** more platform code to own.
- **Source:** [38][39][42][43].

**13. Why not just buy a portal**
- **Honest answer:** at ~50 engineers, a hosted portal (Port, Cortex, Roadie) is a fair choice. Backstage succeeds with a dedicated team, and average adoption outside Spotify has been ~10%.
- **Why here:** this project exists to learn and show how the platform works end to end.
- **Source:** [40][46].

**14. Least privilege, throughout**
- **What:**
  - the Backstage App only opens PRs, with no bypass;
  - the CI bot is limited to idp-gitops and used only in the cluster;
  - service CI can only push to `svc/*` in ECR, through OIDC.
- **Why:** each credential can do one job, so a leaked one does limited damage.
- **Source:** PLATFORM_REVIEW F1/F8/F16, [29].

---

## 13. Results: phases 1-4 built and verified (2026-10-10, Session 9)

### 13.1 What was built, against the plan in section 8

| Phase | Built | Where |
|---|---|---|
| 1 Delivery | ApplicationSet `golden-path-services` (git directory generator, `project: apps` hard-coded, two legacy apps excluded); Argo CD Image Updater v1.3.1 pinned by commit, one `ImageUpdater` with `useAnnotations`, `newest-build` over 40-char SHA tags, write-back to the overlay's kustomization, commits through the GitHub API as `idp-ci-bot`; ECR login by `ext:` script + IRSA role `idp-image-updater` (read-only `svc/*`), `credsexpire: 10h`; scaffolder action `idp:github:await-ci-auto-merge`; Backstage App off the bypass list, "Allow auto-merge" on | idp-gitops `platform/`; idp-infra 20-data, 30-cluster, 40-platform; idp-portal `packages/backend/src/scaffolder/` |
| 2 Central CI + component | repo `surya-idp/idp-platform`, reusable workflow `python-service.yml` (ruff, format, mypy, pytest + coverage gate, arm64 image, Trivy, ECR push on main), tag v1.0.0, self-test against a fixture service; `components/golden-path` and `components/public-route` | idp-platform; idp-gitops `components/`, `tests/golden-path-service` |
| 3 Skeleton v2 | uv + lock, ruff, mypy strict, 8 tests with an 80% gate, pydantic-settings, JSON logs with request id, `/health/live` + `/health/ready`, two-stage image pinned by digest, restricted pod security, own ServiceAccount, TechDocs + runbook, `catalog:write`, OwnerPicker | idp-portal `templates/python-service/` |
| 4 Template CI | `scripts/test-template.sh`: throwaway backend, scaffolder dry-run API, the rendered service's checks, image build, deploy files validated inside idp-gitops | idp-portal CI job `template` |

### 13.2 Deviations from the plan

| Planned | Done instead | Why |
|---|---|---|
| `enablePullRequestAutoMerge` always | enable auto-merge, **or merge directly** when GitHub answers "clean status" | GitHub refuses auto-merge on a PR whose checks already passed. The direct merge is still subject to the ruleset, because the App no longer bypasses it. In the live run this branch was the one taken |
| "~15-line caller" | ~20 lines including comments | concurrency group and explicit permissions |
| opt-in components postgres, cache, public-route | only `public-route` | postgres/cache need per-service databases (PLATFORM_REVIEW F3 / T3) |
| skeleton: `/metrics`, OpenTelemetry hooks, feature flag helper, API entity, System picker | not included | Step 34, T2; the catalog has no Systems yet |
| ImageUpdater CR with explicit images | `useAnnotations: true`, annotations templated by the ApplicationSet | each service has a different image; upstream documents this for ApplicationSets |
| CRD schemas from the public catalog | catalog pinned by commit; schemas for CRDs a kustomization installs are generated from those CRDs | Finding 59 (HANDOVER section 13) |
| migrate `hello-svc` to v2 (phase 2 "done when") | not applicable | `hello-svc` was deleted (decision 4); new services were created from v2 |

### 13.3 Evidence (cluster session 2026-10-10, UTC)

Zero-click creation, service `zero-click-svc`:

| Stage | Time | Elapsed |
|---|---|---|
| repo created by the form | 15:12:15 | 0:00 |
| service CI green, image in ECR | 15:13:41 | 1:26 |
| deploy PR merged by `app/idp-backstage-surya` | 15:13:59 | 1:44 |
| first ALB 200 on `/zero-click-svc/` | 15:15:01 | 2:46 |

v1 (2026-09-27): 5m31s with a human merge.

Second push, service `hello-svc`: push 15:03:28 -> CI green 15:04:52 -> commit
`chore(deploy): update hello-svc image to 9b56897...` by `idp-ci-bot[bot]`, `verified: true`,
15:05:48 -> new version served 15:10:03 (6m35s). Image Updater log:
`applications=2 images_considered=2 ... errors=0`.

Also: all Argo CD apps Synced/Healthy in projects bootstrap/platform/apps; ESO v2.11.0, four
ExternalSecrets SecretSynced; `ecr-login.sh` returns a token inside the Image Updater pod;
template pods admitted with no Pod Security warning; catalog-info carries
`backstage.io/source-template: template:default/python-service`; after `make down` with both
template services present, `verify-empty` reported no billable resources.

Offline evidence: 9 unit tests of the action; template CI green and failing on three deliberate
breakages (type error in the skeleton, misspelled field in a deploy file, dependency added without
`relock.sh`); `validate.sh` failing on a misspelled field in the component; the shared workflow
green on GitHub's arm64 runner against the fixture service.

### 13.4 What the live run found (HANDOVER Findings 57-61)

A free-text description broke generated code (57); scaffolder actions do not get schema defaults
(58); an unpinned schema catalog turned the required check red (59); the image gate blocked a
two-week-old dependency set (60); an all-digit image tag is parsed as a number (61).

### 13.5 Not verified

- A rollout under load on a template service (the Step 28 test).
- TechDocs for a template service in the cluster (local builder needs Docker).
- The action's enable-auto-merge-and-wait branch on a real PR (unit tests only).
- `make down`'s own exit code in that session (AWS was checked empty afterwards).

### 13.6 Follow-ups

1. Shorten the Argo CD poll or add a webhook (3 of the 6.5 minutes of a second push).
2. Move feature-flag-service and idp-portal to Image Updater (section 8 note; removes the CI bot key from two repos).
3. Phase 5: SBOM, keyless signing, provenance with `--signer-workflow` pointing at idp-platform.
4. Phase 6: T4 decommission-service first (the session's clean-up was manual in four places), then T2, then T3 after F3.

---

## 14. Final state: phases 5 and 6, and what two cluster sessions changed (2026-10-11)

### 14.1 The template catalog, against section 6

| Planned | Built | Verified on the cluster |
|---|---|---|
| T1 `python-service` v2 | Yes, and extended since section 13: request metrics and tracing, a feature flag helper, documentation published by CI, signed provenance and SBOM, an optional database | 2026-10-10 and 2026-10-11. Form to running pods: 2 min 36 s with a database (was 5 min 31 s for v1 with a manual merge) |
| T2 `add-feature-flag` | Yes | 2026-10-11: flag created, audited, evaluated by the service with its own identity |
| T3 `add-postgres-database` | Yes | 2026-10-11: database and login within 90 s of the merge, pods restarted with `DATABASE_URL`, the route answered 200 afterwards |
| T4 `decommission-service` | Yes | 2026-10-11, three runs. The last left nothing behind anywhere |
| T5 `promote` | No | Out of scope: there is one environment |

### 14.2 The decision that shaped phase 6: day-2 templates are generic

The owner's objection to a first draft, 2026-10-10: a removal template written for one creation
template means every new creation template doubles the number of templates. The design that
answers it:

- A creation template **records** what it created, as annotations in the service's catalog
  entry: `idp.surya-idp/template-version` (the marker of a golden-path service),
  `github.com/project-slug`, `idp.surya-idp/gitops-path`, `idp.surya-idp/ecr-repository`.
- A day-2 template **reads** those annotations. It lists services by the marker, not by a
  template's name, and every step that depends on an annotation is conditional on it.
- A new kind of resource should live **inside the service's deploy folder** as an opt-in
  component, so removing the folder removes it and the controller behind it cleans up. The
  database works this way. Only what lives outside the folder (the image repository, the flags,
  the docs) needs a step of its own.

Evidence that it holds: template CI dry-runs `decommission-service` against a stand-in service
"from another template" that deploys nothing and builds no image; the steps without an
annotation are skipped. The contract is `idp-portal/templates/README.md`.

On the question whether real companies remove services with a template: Backstage has no
built-in service lifecycle or rollback (backstage/backstage#28818, closed as not planned); an
`unregister` action exists; there is no public description of how Spotify does it. Deleting
declaratively (remove the folder, let controllers clean up) is the production pattern, and the
template is a front end to exactly that plus the three things that live elsewhere.

### 14.3 Phase 5: supply chain

| Piece | What |
|---|---|
| Where it is signed | In the **shared** workflow (`idp-platform`), with `actions/attest`: build provenance and a CycloneDX SBOM per pushed image, stored next to the image in ECR |
| Why there | The signer identity is the workflow file. A service cannot produce a valid attestation with a pipeline of its own |
| How it is checked by a person | `gh attestation verify oci://<image>@<digest> --owner surya-idp --signer-workflow surya-idp/idp-platform/.github/workflows/python-service.yml` |
| How it is checked by the cluster | Kyverno `ImageValidatingPolicy` `verify-image-provenance`, audit mode |
| What went wrong | The certificate names the workflow by the caller's ref. Services pin by commit, so the policy must list release commits, not tags (HANDOVER Finding 74). Each release needs its commit added |

### 14.4 Phase 6 details that are easy to get wrong

| Topic | Decision | Reason |
|---|---|---|
| Who may decommission | Group `platform-admins`. The template's first step is an admin-only no-op | The scaffolder checks an action when its step starts. Without the guard a refused user would be stopped halfway through a removal |
| Order inside a removal | Deploy files first (a pull request, merged when `validate` is green), then images, flags, docs, repository, catalog entry | Nothing is left running that points at something already gone |
| Order inside the cluster | Sync waves: namespace -3, database -2, login -1, the rest 0 or later; Argo CD deletes in reverse | The operator drops a login only while its database exists and is not being deleted (Finding 78) |
| Archive or delete the repository | Archive by default; delete is a box on the form | Deleting cannot be undone. But an archived repository keeps its name taken (Finding 90) |
| How a service authenticates to the flag API | Its Kubernetes ServiceAccount token, issued for the audience `feature-flag-api`, verified with TokenReview | No secret to create, deliver or rotate. Alternatives rejected: API keys (credential sprawl), sharing the signing key (every holder can mint an admin token) |
| Flag names | Stored as `<service>.<flag>`; the helper adds the prefix | Two services can both have `new-checkout`; a removed service's flags can be found |
| A catalog entry per flag | No | Flags change often and are switched without a deploy; the flag API is their source of truth and keeps the audit trail |
| The helper's failure mode | Never raises, 0.5 s timeout, 10 s cache of real answers only, returns the caller's default | A flag service outage must not break its callers (Finding 85 was a bug in exactly this) |

### 14.5 What the two sessions changed in the path itself

Section 13.6 listed four follow-ups. All are done:

1. Polling: Argo CD every 60 s, and the ApplicationSet's own timer 60 s (it was the larger
   part: Finding 81). A webhook is not possible without a public address.
2. The two platform apps use Image Updater; no application repository holds a deploy credential.
3. Phase 5, above.
4. Phase 6, above.

And three things nobody had planned:

- **Build ordering.** "Newest build wins" deployed the older of two quick pushes. The shared
  workflow (v2.1.1) pushes an image only for the branch's newest commit (Findings 79, 86).
- **What counts as CI.** GitHub's own runs for a commit (Dependabot, code scanning) are not the
  service's CI (Finding 82).
- **User input in a picker.** The Name field's autocomplete put an existing repository's name
  back into the form (Finding 90).

### 14.6 Not verified

- The "delete the repository" option, for real.
- A non-admin being refused at the guard step, with a second real user.
- A creation template in another language. The claim "day-2 templates need no change" is
  supported by a dry run against a stand-in, not by a second real template.

