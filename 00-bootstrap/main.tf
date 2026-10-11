# =============================================================================
# 00-bootstrap/main.tf
#
# Creates the foundation for all other Terraform layers:
#   1. S3 bucket for remote state (all layers 10-90 use this)
#   2. DynamoDB table for state locking (optional but good portfolio practice)
#   3. GitHub OIDC Identity Provider (enables keyless CI auth)
#   4. IAM role idp-github-ci (assumed by GitHub Actions via OIDC)
#   5. S3 bucket for documentation sites (Backstage TechDocs), written by service CI
#
# STATE: LOCAL — intentional chicken-and-egg.
#   This layer creates the S3 bucket that all other layers use as their backend.
#   It cannot itself use that bucket as a backend because the bucket doesn't
#   exist yet. Local state is the correct approach here.
#
#   DO NOT run `terraform destroy` on this layer.
#   DO NOT migrate this layer's state to S3 — it would create a circular
#   dependency where destroying the bucket destroys the state that tracked it.
#
# COST: $0 — IAM, OIDC provider, and S3 bucket (no objects yet) are free.
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # LOCAL STATE — do not add a backend block here.
  # See comment above explaining why this is intentional.
}

provider "aws" {
  region  = "ap-south-1"
  profile = "idp"

  default_tags {
    tags = {
      Project     = "idp"
      ManagedBy   = "terraform"
      Environment = "bootstrap"
      Layer       = "00-bootstrap"
    }
  }
}

# ─── Data sources ────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# Fetch the current TLS certificate for the GitHub Actions OIDC endpoint.
# This derives the thumbprint dynamically rather than hardcoding it.
# Hardcoded thumbprints go stale when GitHub rotates their certificate.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

# ─── S3 state bucket ─────────────────────────────────────────────────────────

resource "aws_s3_bucket" "tfstate" {
  bucket = "idp-tfstate-${data.aws_caller_identity.current.account_id}"

  # Prevent accidental destruction of the state bucket.
  # If you genuinely need to destroy it, remove this block first,
  # then run `terraform apply` to update, then `terraform destroy`.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Block all object ownership changes — no ACLs
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ─── DynamoDB state lock table ───────────────────────────────────────────────
# NOT USED for locking: no backend ever referenced it, so state was unlocked until
# 2026-09-27. All backends now use S3-native locking (use_lockfile = true, Terraform
# >= 1.10), which is HashiCorp's recommended replacement (dynamodb_table is deprecated).
# Kept only because it is free (PAY_PER_REQUEST, idle = $0); safe to remove later.

resource "aws_dynamodb_table" "tfstate_locks" {
  name         = "idp-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ─── GitHub Actions OIDC Identity Provider ───────────────────────────────────
# This tells AWS to trust JWTs issued by GitHub Actions.
# The thumbprint is fetched dynamically from GitHub's current TLS cert.

resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS occasionally updates required thumbprints. These are the current ones + the dynamic one.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
    data.tls_certificate.github_actions.certificates[0].sha1_fingerprint
  ]
}

# ─── IAM role: idp-github-ci ──────────────────────────────────────────────
# Assumed by GitHub Actions workflows in the feature-flag-service repo,
# main branch only. The condition is intentionally strict — no wildcards.
#
# SECURITY: The sub condition pins to a specific repo AND branch.
#   repo:surya-idp@334455734/feature-flag-service@1368152185:ref:refs/heads/main
#   Any other repo or branch cannot assume this role.
#   Never use repo:*:* — that would allow any GitHub Action in any repo
#   belonging to the GitHub OIDC provider to assume this role.

data "aws_iam_policy_document" "github_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      # Exact repo + exact branch. No wildcards.
      # GitHub's OIDC sub claim now embeds immutable owner and repo IDs
      # (repo:OWNER@OWNER_ID/REPO@REPO_ID:...). The old "repo:OWNER/REPO:..." form no longer
      # matches, which shows up as "Not authorized to perform sts:AssumeRoleWithWebIdentity".
      # IDs: org surya-idp = 334455734, feature-flag-service = 1368152185 (repo IDs survive transfers).
      # idp-portal = 1389614591 (Backstage, Step 29). Each entry is one exact repo + branch.
      values = [
        # Repos live in GitHub org surya-idp (id 334455734) since 2026-09-27 (PLATFORM_REVIEW F16).
        "repo:surya-idp@334455734/feature-flag-service@1368152185:ref:refs/heads/main",
        "repo:surya-idp@334455734/idp-portal@1389614591:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name               = "idp-github-ci"
  assume_role_policy = data.aws_iam_policy_document.github_ci_trust.json
  description        = "Assumed by GitHub Actions CI for feature-flag-service and idp-portal (main branch only)"
}

# ECR permissions — scoped to the specific repository.
# The ECR repo doesn't exist yet (created in 30-cluster); we use a predictable
# ARN pattern. GetAuthorizationToken is account-level, not repo-scoped.
data "aws_iam_policy_document" "github_ci_ecr" {
  # GetAuthorizationToken is account-level — cannot be scoped to a specific repo
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # All other ECR actions can be scoped to the specific repository
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/feature-flag-service",
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/idp-portal",
    ]
  }
}

resource "aws_iam_role_policy" "github_ci_ecr" {
  name   = "ecr-push"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci_ecr.json
}

# ─── IAM role: idp-service-ci (Step 30 golden path) ───────────────────────
# Assumed by CI of services CREATED BY THE BACKSTAGE TEMPLATE. Those repos do not exist
# when this is applied, so their exact subjects cannot be listed like idp-github-ci's.
#
# DELIBERATE, NARROW EXCEPTION to "no wildcards in OIDC trust" (user decision 2026-09-27):
#   - trust: any repo whose owner is org ID 334455734 (surya-idp) (immutable - a renamed or
#     re-registered "surya-idp" cannot match), main branch only
#   - blast radius: this role can ONLY create and push to ECR repos under svc/*. It cannot
#     touch feature-flag-service or idp-portal images, or anything outside ECR.
# The exact-match role above is unchanged.

data "aws_iam_policy_document" "service_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:surya-idp@334455734/*:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "service_ci" {
  name               = "idp-service-ci"
  assume_role_policy = data.aws_iam_policy_document.service_ci_trust.json
  description        = "CI for template-created services: create/push ECR repos under svc/* only"
}

data "aws_iam_policy_document" "service_ci_ecr" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "SvcReposOnly"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy",
      "ecr:TagResource",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/svc/*",
    ]
  }
}

resource "aws_iam_role_policy" "service_ci_ecr" {
  name   = "ecr-svc-only"
  role   = aws_iam_role.service_ci.id
  policy = data.aws_iam_policy_document.service_ci_ecr.json
}

# ─── S3 bucket: documentation sites (Backstage TechDocs) ───────────────────
# Each service's CI builds its docs/ folder into a small website and uploads it here; Backstage
# only reads it. This is the setup the Backstage project recommends for production, and the
# only one that works here: Backstage's own builder needs Docker, which a pod does not have.
#
# WHY IN THIS LAYER (permanent, never destroyed): docs are written at push time, not at
# `make up` time. A bucket that was deleted with the cluster would be empty after every
# `make up` until each service was pushed again.
#
# COST: storage only. A site is a few hundred KB of HTML: a fraction of a cent per month.
resource "aws_s3_bucket" "techdocs" {
  bucket = "idp-techdocs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "idp-techdocs"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "techdocs" {
  bucket = aws_s3_bucket.techdocs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Never public: Backstage reads it with its IAM role and serves the pages to signed-in users.
resource "aws_s3_bucket_public_access_block" "techdocs" {
  bucket = aws_s3_bucket.techdocs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "techdocs" {
  bucket = aws_s3_bucket.techdocs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Service CI (the shared workflow's `docs` job) uploads a site under
# default/component/<service>/. One role serves every service repo, so a service could
# overwrite another service's docs. Accepted: it is documentation, the role still cannot read
# or write anything else, and every upload is a CI run with an author.
data "aws_iam_policy_document" "service_ci_techdocs" {
  statement {
    sid       = "ListDocs"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.techdocs.arn]
  }

  statement {
    sid    = "WriteComponentDocs"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject", # publishing removes pages that no longer exist
    ]
    resources = ["${aws_s3_bucket.techdocs.arn}/default/component/*"]
  }
}

resource "aws_iam_role_policy" "service_ci_techdocs" {
  name   = "techdocs-publish"
  role   = aws_iam_role.service_ci.id
  policy = data.aws_iam_policy_document.service_ci_techdocs.json
}

# ─── IAM role: idp-infra-plan (PLATFORM_REVIEW F7) ─────────────────────────
# Assumed by idp-infra's own CI to run `terraform plan -lock=false` for the PERMANENT layers
# (10-network, 15-registry) on pushes to main and on same-repo PRs (fork PRs never get an
# OIDC token). Read-only and scoped: EC2/ECR describes plus exactly those two state files.
# Deliberately NOT ReadOnlyAccess: that would expose every state file, including 20-data's
# generated DB password.

data "aws_iam_policy_document" "infra_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:surya-idp@334455734/idp-infra@1381729533:ref:refs/heads/main",
        "repo:surya-idp@334455734/idp-infra@1381729533:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "infra_plan" {
  name               = "idp-infra-plan"
  assume_role_policy = data.aws_iam_policy_document.infra_plan_trust.json
  description        = "idp-infra CI: read-only terraform plan of 10-network and 15-registry"
}

data "aws_iam_policy_document" "infra_plan" {
  statement {
    sid       = "Ec2Describe"
    effect    = "Allow"
    actions   = ["ec2:Describe*"]
    resources = ["*"] # Describe* has no resource-level permissions
  }

  statement {
    sid    = "EcrRead"
    effect = "Allow"
    actions = [
      "ecr:DescribeRepositories",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:ListTagsForResource",
    ]
    resources = [
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/feature-flag-service",
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/idp-portal",
    ]
  }

  statement {
    sid       = "StateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["10-network/*", "15-registry/*"]
    }
  }

  statement {
    sid     = "StateRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.tfstate.arn}/10-network/terraform.tfstate",
      "${aws_s3_bucket.tfstate.arn}/15-registry/terraform.tfstate",
    ]
  }
}

resource "aws_iam_role_policy" "infra_plan" {
  name   = "plan-permanent-layers"
  role   = aws_iam_role.infra_plan.id
  policy = data.aws_iam_policy_document.infra_plan.json
}
