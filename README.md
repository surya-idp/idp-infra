# idp-infra

The AWS side of the IDP, in Terraform: network, image registry, database, cache, secrets, the
Kubernetes cluster (EKS) and Argo CD. Everything that runs **inside** the cluster is deployed by
Argo CD from [idp-gitops](https://github.com/surya-idp/idp-gitops); Terraform installs Argo CD
and stops there.

The platform is built to exist only while someone is working with it: `make up` creates it
from nothing, `make down` destroys it and checks that nothing billable is left.

It is one of five repositories:

| Repository | Role |
|---|---|
| **idp-infra** (this one) | Terraform for AWS, `make up` / `make down`, the end-to-end test, the project's master documents |
| [idp-gitops](https://github.com/surya-idp/idp-gitops) | What runs in the cluster |
| [idp-portal](https://github.com/surya-idp/idp-portal) | Backstage and the software templates |
| [idp-platform](https://github.com/surya-idp/idp-platform) | The CI workflow every template service calls |
| [feature-flag-service](https://github.com/surya-idp/feature-flag-service) | The platform's first application, the flag API |

## The layers

Terraform is split into layers with separate state, applied in number order. A layer reads what
it needs from the layers below it (remote state), so the short-lived layers can be destroyed
without touching the permanent ones.

| Layer | What it holds | Lives | State |
|---|---|---|---|
| `00-bootstrap` | The state bucket, the GitHub OIDC provider, the three CI roles, the docs bucket | Permanent. Applied by hand; never destroyed | local file |
| `10-network` | VPC, two public and two private subnets, route tables, security groups | Permanent (free) | S3 |
| `15-registry` | The two ECR repositories of the platform's own images | Permanent (storage only) | S3 |
| `20-data` | RDS PostgreSQL 16, the secrets in Secrets Manager | Per session | S3 |
| `30-cluster` | EKS, three `t4g.medium` nodes, NAT gateway, Valkey cache, the IAM roles pods use (EKS Pod Identity) | Per session | S3 |
| `40-platform` | Argo CD and its root Application | Per session | S3 |

State in S3 is locked with S3-native lock files (`use_lockfile = true`). Provider versions are
pinned by the committed `.terraform.lock.hcl` files.

## A session

```bash
aws sso login --profile idp
git checkout main && git pull

TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32" make up    # about 27 minutes
make e2e                                                                     # is everything working?

# ... work ...

make down            # about 17 minutes; must end with exit code 0
```

| Command | What it does |
|---|---|
| `make up` | Applies `20-data`, loads the GitHub App credentials from `~/.idp` into Secrets Manager, applies `30-cluster`, points `kubectl` at the cluster, applies `40-platform`, then waits until Argo CD's first full sync has succeeded |
| `make e2e` | `tests/e2e.sh`: 42 read-only checks of the running platform. Exit code 0, or a list of what failed |
| `make down` | `scripts/down.sh`: deletes the Argo CD applications so the load balancer is removed, destroys `40`, `30`, `20`, then runs the emptiness check. A failed step is recorded, the remaining layers are still attempted, and the exit code is non-zero |
| `make verify-empty` | `scripts/verify-empty.py`: asks AWS which billable resources exist, by tag and by querying each service directly |

Things that go wrong if skipped:

- **`TF_VAR_allowed_cidr`.** The cluster's API endpoint accepts connections from one address
  only. Home internet addresses change; without the variable the default in
  `30-cluster/variables.tf` is used and `kubectl` times out. If your address changes during a
  run (a laptop that switches networks), the last layer fails with `i/o timeout`: run `make up`
  again, it continues where it stopped.
- **`aws sso login`.** The login lasts a few hours. If it expires mid-run, Terraform stops with
  `unable to refresh SSO token`. Log in again and repeat the command.
- **`git pull` before `make up`.** The run uses the code on disk. A merge made while it runs is
  not part of it.
- **`make down` at the end, and reading its last line.** The cluster costs money for every hour
  it exists.

### What `make up` needs on the laptop

Tools: `terraform`, `aws` (v2), `kubectl`, `python3`. For `make e2e` also `curl`.

Files in `~/.idp/` (mode 600; never in git, never in Terraform state). They are the credentials
of the two GitHub Apps, which have to survive a teardown:

| File | For |
|---|---|
| `backstage-app.env`, `backstage-app.pem`, `backstage-client-secret` | The Backstage GitHub App: catalog, templates, sign-in |
| `ci-bot-app.env`, `ci-bot-app.pem` | The `idp-ci-bot` GitHub App: Argo CD Image Updater commits image tags with it |

If a file is missing, `make up` prints a warning and carries on; the feature that needs it does
not work in that session.

## Cost

| When | Cost |
|---|---|
| Cluster down | A few cents a month: image storage in ECR and the (nearly empty) state and docs buckets. Everything else is destroyed |
| Cluster up | About **$0.33 an hour**: EKS control plane, three `t4g.medium` nodes, one NAT gateway, one load balancer, one `db.t3.micro` database, one cache node |

The price breakdown is in `HANDOVER_DOC.md` section 3. Check the account's billing page before
relying on credits: on this account they ended earlier than the date first noted.

## Who can do what in AWS

No long-lived AWS key exists anywhere.

| Who | How it logs in | What it may do |
|---|---|---|
| A person | IAM Identity Center (single sign-on), temporary credentials | Administrator |
| CI of the two platform apps | GitHub OIDC -> role `idp-github-ci` | Push to its own ECR repository |
| CI of template services | GitHub OIDC -> role `idp-service-ci` | Create and push ECR repositories under `svc/*`; upload docs under `default/component/*` |
| CI of this repository | GitHub OIDC -> role `idp-infra-plan` | Read-only: `terraform plan` of the permanent layers |
| Pods (External Secrets, load balancer controller, Image Updater, Kyverno, Backstage) | EKS Pod Identity -> one role each | Only what that controller needs; listed in `30-cluster/main.tf` |

## CI of this repository

`.github/workflows/ci.yml`, on every push and pull request:

| Job | Checks |
|---|---|
| `terraform` | `fmt`, `validate` and `tflint` for every layer |
| `trivy` | Configuration scan; HIGH and CRITICAL findings fail. Accepted findings are listed with reasons in `.trivyignore.yaml` |
| `plan` | `terraform plan` of the permanent layers (`10-network`, `15-registry`). On `main` a non-empty plan fails: either AWS drifted, or a merged change was not applied |

The session layers are not planned in CI: they do not exist between sessions. `00-bootstrap`
has local state and is applied by hand:

```bash
terraform -chdir=00-bootstrap plan
terraform -chdir=00-bootstrap apply
```

## Other files

| File | What it is |
|---|---|
| `tests/e2e.sh` | The end-to-end test behind `make e2e` |
| `tests/rollout-load.js` | k6 script: steady traffic through the load balancer during a rollout; the claim is zero failed requests |
| `test_latency.py` | The latency comparison of the first database (outside AWS) against RDS inside the VPC |
| `modules/vpc/` | The VPC module `10-network` uses |
| `HANDOVER_DOC.md` | The master record: every step, every finding, the current state, the checklists |
| `PLATFORM_REVIEW.md` | The platform compared with industry practice: sixteen flaws, ranked, and what became of each |
| `TEMPLATES_RESEARCH.md` | The research and decisions behind the software templates |

## Deliberate limits

These are choices, each written down with its reason in `PLATFORM_REVIEW.md`:

- **One environment.** No staging or production; they need separate data and a domain.
- **No domain, so no HTTPS on the load balancer.** A certificate needs a domain name. Service
  traffic through the load balancer is plain HTTP; the database and the cache use TLS.
- **The platform's own tools have no public address.** Backstage, Argo CD, Grafana and
  Prometheus are reached with `kubectl port-forward`, which means only someone with cluster
  access can reach them.
- **One NAT gateway, one database instance, no backups.** Data does not survive a session by
  design.
- **The cluster API endpoint is public but restricted to one address.** No VPN.
