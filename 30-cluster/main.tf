# =============================================================================
# 30-cluster/main.tf
#
# Cluster layer — EKS, NAT Gateway, ECR, ElastiCache Valkey, IRSA roles.
#
# LIFECYCLE: DESTROYED every session (make down). Everything here costs money
#   while running. Nothing here survives a make down — this is intentional.
#
# COST DURING SESSION (~3hr):
#   EKS control plane:       3hr  x $0.10          = $0.30
#   NAT Gateway:             3hr  x $0.056          = $0.17
#   SPOT t3.medium x2:       3hr  x 2 x $0.0147    = $0.09
#   EBS node volumes:                                ~ $0.01
#   ElastiCache Valkey:      3hr  x $0.016          = $0.05
#   Public IPv4 (EIP):       3hr  x $0.005          = $0.02 (approx)
#
# EKS VERSION NOTE: 1.31-1.33 entered EXTENDED SUPPORT — $0.60/hr.
#   This layer uses 1.35 (STANDARD SUPPORT — $0.10/hr, ends 2027-03-27).
#   NEVER use a version with status EXTENDED_SUPPORT; check with:
#     aws eks describe-cluster-versions --profile idp
#
# NAT GATEWAY: Lives here (not in 10-network) so it is destroyed nightly.
#   Left running permanently = $0.056/hr = $40/month. Not acceptable.
#   This layer adds the 0.0.0.0/0 -> NAT routes to the private route tables
#   created in 10-network, and removes them on destroy.
#
# ELASTICACHE VALKEY: Lives here (not in 20-data) because ElastiCache has
#   NO stop API — only run or destroy. Keeping it in 20-data would cost
#   $0.016/hr x 24 x 30 = $11.52/month during idle time. Not acceptable.
#   engine = "valkey" — same Redis API, ~20% cheaper. Never use "redis".
#
# IRSA ROLES (three, all here):
#   - ESO (External Secrets Operator): reads idp/* secrets from Secrets Manager
#   - ALB Controller: manages AWS ALBs for Ingress resources
#   - EBS CSI Driver: provisions gp3 EBS volumes for PVCs
#
# SECURITY NOTE: EKS API server is restricted to var.allowed_cidr (your IP).
#   If your IP changes between sessions, override: -var 'allowed_cidr=NEW_IP/32'
#   or temporarily set to 0.0.0.0/0 for the session (revert before shutdown).
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0" # v20 module requires >= 5.34; v21 was dropped due to planning bug
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket  = "idp-tfstate-693906847772"
    key     = "30-cluster/terraform.tfstate"
    region  = "ap-south-1"
    profile = "idp"
    # S3-native state lock (Terraform >= 1.10): a .tflock object next to the state.
    use_lockfile = true
  }
}

provider "aws" {
  region  = "ap-south-1"
  profile = "idp"

  default_tags {
    tags = {
      Project     = "idp"
      ManagedBy   = "terraform"
      Environment = var.environment
      Layer       = "30-cluster"
    }
  }
}

# ─── Remote state: read 10-network outputs ───────────────────────────────────

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket  = "idp-tfstate-693906847772"
    key     = "10-network/terraform.tfstate"
    region  = "ap-south-1"
    profile = "idp"
  }
}

# ─── Remote state: read 20-data outputs (for secret ARNs in IRSA policy) ─────

data "terraform_remote_state" "data" {
  backend = "s3"
  config = {
    bucket  = "idp-tfstate-693906847772"
    key     = "20-data/terraform.tfstate"
    region  = "ap-south-1"
    profile = "idp"
  }
}

# ─── AWS caller identity (for account-scoped ARNs) ───────────────────────────

data "aws_caller_identity" "current" {}

# =============================================================================
# NAT GATEWAY
# =============================================================================
# One NAT Gateway in the first public subnet (ap-south-1a) is enough for a lab.
# Both private subnets route through it — one AZ failure loses internet from
# both private subnets, but that is acceptable for a portfolio project.
# Production would have one NAT per AZ.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "idp-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.terraform_remote_state.network.outputs.public_subnet_ids[0]

  tags = {
    Name = "idp-nat"
  }

  depends_on = [aws_eip.nat]
}

# Add default route to BOTH private route tables.
# 10-network deliberately left these routes absent — 30-cluster owns the NAT lifecycle.
# When this layer is destroyed, these routes are removed and private subnets become
# fully isolated (correct — no cluster = nothing needs internet from private subnets).

resource "aws_route" "private_nat_1a" {
  route_table_id         = data.terraform_remote_state.network.outputs.private_route_table_ids[0]
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id

  depends_on = [aws_nat_gateway.this]
}

resource "aws_route" "private_nat_1b" {
  route_table_id         = data.terraform_remote_state.network.outputs.private_route_table_ids[1]
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id

  depends_on = [aws_nat_gateway.this]
}

# =============================================================================
# ECR REPOSITORY - moved to 15-registry (permanent layer; images survive make down)
# =============================================================================

# =============================================================================
# ELASTICACHE VALKEY
# =============================================================================
# engine = "valkey" — same Redis protocol/API, ~20% cheaper. NEVER use "redis".
# num_cache_clusters = 1 — single node, no replication. Fine for a lab cache.
# parameter_group_name = "default.valkey7" — NOT "default.redis7".
# ASCII hyphens in description — AWS rejects non-ASCII characters in description fields.

resource "aws_elasticache_subnet_group" "valkey" {
  name        = "idp-valkey"
  description = "Private subnets for ElastiCache Valkey"
  subnet_ids  = data.terraform_remote_state.network.outputs.private_subnet_ids

  tags = {
    Name = "idp-valkey-subnet-group"
  }
}

resource "aws_elasticache_replication_group" "valkey" {
  replication_group_id = "idp-valkey"
  description          = "Feature Flag IDP - Valkey cache layer"

  engine               = "valkey"
  engine_version       = "7.2"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  parameter_group_name = "default.valkey7"

  subnet_group_name  = aws_elasticache_subnet_group.valkey.name
  security_group_ids = [data.terraform_remote_state.network.outputs.sg_elasticache_id]

  # At rest: free, transparent to clients. In transit: needs TLS in every client (rediss://),
  # tracked as PLATFORM_REVIEW F13; .trivyignore.yaml records the exception until then.
  at_rest_encryption_enabled = true
  transit_encryption_enabled = false

  # lifecycle: ignore auth_token fields — the v6 AWS provider schema wrote
  # auth_token_wo into state during an aborted apply. The v5 provider sees this
  # as a diff and tries to set it, but ElastiCache rejects auth token changes
  # when transit_encryption_enabled = false. Ignoring silences the spurious diff.
  lifecycle {
    ignore_changes = [auth_token, auth_token_update_strategy]
  }

  tags = {
    Name = "idp-valkey"
  }
}

# The replication group endpoint contains a random hash that changes every time the
# group is recreated (i.e. every session under Option B), so it cannot live in Git.
# Publish it to Secrets Manager; ESO syncs it into the app's K8s Secret as REDIS_URL.
resource "aws_secretsmanager_secret" "valkey" {
  name                    = "idp/valkey"
  description             = "Valkey connection URL - recreated every session"
  recovery_window_in_days = 0 # immediate deletion so the name is free on next make up
}

resource "aws_secretsmanager_secret_version" "valkey" {
  secret_id = aws_secretsmanager_secret.valkey.id
  secret_string = jsonencode({
    url = "redis://${aws_elasticache_replication_group.valkey.primary_endpoint_address}:6379"
  })
}

# =============================================================================
# EKS CLUSTER
# =============================================================================
# Using terraform-aws-modules/eks ~> 21.0 (latest: 21.26.0 as of 2026-09-23).
#
# SECURITY: API server restricted to var.allowed_cidr (your current IP).
#   If kubectl fails with connection refused, your IP likely changed. Fix:
#     terraform -chdir=30-cluster apply -var 'allowed_cidr=NEW_IP/32' -auto-approve
#
# NODE SECURITY GROUPS:
#   The module creates its own cluster SG (for control-plane <-> node comms).
#   We ALSO attach sg-nodes (from 10-network) as an additional SG on each node.
#   This is required because sg-rds and sg-elasticache allow inbound from sg-nodes.
#   Nodes must have sg-nodes in their SG list for that traffic to be permitted.
#
# SPOT INSTANCES: ["t3.medium", "t3a.medium"] — two types = fewer interruptions.
#   AWS selects whichever has capacity. Both have 2vCPU/4GB.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  # v20 argument names (v21 renamed them — we use v20 to avoid a planning-phase bug
  # in v21 where count in the node group submodule references partition before it's known)
  cluster_name    = "idp-cluster"
  cluster_version = "1.35" # STANDARD_SUPPORT until 2027-03-27 — $0.10/hr

  vpc_id     = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  # API server: accessible from internet BUT restricted to your IP.
  # Also accessible from inside the VPC (private access = true).
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = [var.allowed_cidr]
  cluster_endpoint_private_access      = true

  # CloudWatch control plane logs — 1 day retention ONLY.
  # Default is 90 days at $0.50-$0.67/GB ingestion. Silent credit drain.
  cluster_enabled_log_types              = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 1

  # Enable IRSA — creates an OIDC provider for the cluster (required for ESO, ALB Controller, EBS CSI)
  enable_irsa = true

  # Grant the IAM caller (idp-admin) cluster-admin via EKS API access entries.
  # Without this, kubectl fails with "server has asked for credentials" after creation.
  # The module uses API_AND_CONFIG_MAP auth mode; this adds an access entry automatically.
  enable_cluster_creator_admin_permissions = true

  # The module opens cluster -> node only on 443/4443/6443/8443/9443/10250. The EKS
  # metrics-server add-on serves on 10251, so without this the aggregated Metrics API
  # times out ("failing or missing response ... :10251") and HPAs show <unknown>.
  node_security_group_additional_rules = {
    ingress_cluster_metrics_server = {
      description                   = "Cluster API to metrics-server"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  cluster_addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true # must be configured before nodes join, or max-pods stays at 11
      # Prefix delegation: each ENI slot hands out a /28 instead of one IP, lifting
      # t4g.small from 11 pods to 110 (paired with maxPods in the node group below).
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    # Resource metrics API (kubectl top, HorizontalPodAutoscaler). EKS does not ship it
    # by default; the community add-on has arm64 builds for t4g nodes.
    metrics-server = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    spot = {
      # Account restricts Spot to free-tier-eligible types only.
      # t4g.small = 2 vCPU / 2 GiB — Graviton, free-tier eligible, enough for EKS system pods.
      instance_types = ["t4g.small"]
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_ARM_64_STANDARD"

      # AL2023 kubelet must be told the higher limit explicitly; the default is
      # computed from ENI count (11 on t4g.small) even with prefix delegation on.
      cloudinit_pre_nodeadm = [{
        content_type = "application/node.eks.aws"
        content      = <<-EOT
          ---
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                maxPods: 110
        EOT
      }]

      # Three nodes since the observability stack (Prometheus, Grafana, Loki, Tempo: about
      # 1.2 GiB of requests) joined Kyverno, the database operator and Image Updater. Two
      # 2 GiB nodes were at 52-57% memory with the platform before any of those.
      # One more t4g.small is about $0.017/hr.
      min_size     = 2
      max_size     = 4
      desired_size = 3

      # Nodes go into private subnets — never publicly reachable
      subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

      # Attach sg-nodes (from 10-network) as additional SG on each node.
      # sg-rds and sg-elasticache allow inbound from sg-nodes specifically.
      # Without this, pods cannot reach RDS or Valkey.
      vpc_security_group_ids = [
        data.terraform_remote_state.network.outputs.sg_nodes_id
      ]
    }
  }

  tags = {
    Name = "idp-cluster"
  }

  depends_on = [aws_nat_gateway.this, aws_route.private_nat_1a, aws_route.private_nat_1b]
}

# =============================================================================
# IRSA — External Secrets Operator
# =============================================================================
# ESO needs to call secretsmanager:GetSecretValue and DescribeSecret.
# Policy is scoped to idp/* secrets only — NOT "*".
# The trailing -* wildcard covers the random suffix AWS appends to secret names.

data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "eso_policy" {
  statement {
    sid = "ReadSecretsManager"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      # Scoped to idp/* with suffix wildcard (AWS appends random chars)
      "arn:aws:secretsmanager:ap-south-1:${data.aws_caller_identity.current.account_id}:secret:idp/*",
    ]
  }
}

resource "aws_iam_role" "eso" {
  name               = "idp-eso"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json

  tags = {
    Name = "idp-eso"
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "idp-eso-secrets-policy"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_policy.json
}

# =============================================================================
# IRSA — AWS Load Balancer Controller
# =============================================================================
# ALB Controller manages ALBs for Kubernetes Ingress resources.
# The IAM policy is the official one from the aws-load-balancer-controller repo.
# Fetched at apply time so it stays current with new controller releases.

data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Official ALB controller IAM policy from the upstream repo (v3.5.0 - matches chart 3.5.0 installed by 40-platform).
# Fetched at terraform apply time — no manual copy-paste needed.
# Finding: v2.8.3 policy is missing elasticloadbalancing:DescribeListenerAttributes
# which ALB controller v2.11+ requires. Always align policy version with chart version
# (chart 3.5.0 = controller v3.5.0; the old 2.11.0 policy predates the v3 line).
data "http" "alb_controller_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json"

  request_headers = {
    Accept = "application/json"
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "idp-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json

  tags = {
    Name = "idp-alb-controller"
  }
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "idp-alb-controller-policy"
  role   = aws_iam_role.alb_controller.id
  policy = data.http.alb_controller_iam_policy.response_body
}

# =============================================================================
# IRSA — Argo CD Image Updater
# =============================================================================
# Image Updater (installed by Argo CD from idp-gitops/platform/image-updater) lists the tags
# of golden-path service images to find new builds. Read-only, and only ECR repos under
# svc/* (the same prefix idp-service-ci may push to). It never pulls for a workload: nodes
# pull with their own role.

data "aws_iam_policy_document" "image_updater_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:argocd:argocd-image-updater-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "image_updater_policy" {
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid = "ReadSvcRepos"
    actions = [
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer", # newest-build reads the image config for its build date
    ]
    resources = [
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/svc/*",
    ]
  }
}

resource "aws_iam_role" "image_updater" {
  # idp-gitops/platform/image-updater/patch-serviceaccount.yaml refers to this name.
  name               = "idp-image-updater"
  assume_role_policy = data.aws_iam_policy_document.image_updater_assume_role.json

  tags = {
    Name = "idp-image-updater"
  }
}

resource "aws_iam_role_policy" "image_updater" {
  name   = "idp-image-updater-ecr-read"
  role   = aws_iam_role.image_updater.id
  policy = data.aws_iam_policy_document.image_updater_policy.json
}

# =============================================================================
# IRSA — Backstage (idp-portal)
# =============================================================================
# The decommission-service template deletes a retired service's images. Backstage gets
# exactly that: delete ECR repositories under svc/* (the prefix template services use).
# It cannot touch feature-flag-service or idp-portal images, or anything outside ECR.

data "aws_iam_policy_document" "portal_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:backstage:idp-portal"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "portal_policy" {
  statement {
    sid = "DeleteSvcRepos"
    actions = [
      "ecr:DeleteRepository", # with force = also removes the images
      "ecr:DescribeRepositories",
    ]
    resources = [
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/svc/*",
    ]
  }
}

resource "aws_iam_role" "portal" {
  # idp-gitops/apps/idp-portal/base/serviceaccount.yaml refers to this name.
  name               = "idp-portal"
  assume_role_policy = data.aws_iam_policy_document.portal_assume_role.json

  tags = {
    Name = "idp-portal"
  }
}

resource "aws_iam_role_policy" "portal" {
  name   = "idp-portal-ecr-delete-svc"
  role   = aws_iam_role.portal.id
  policy = data.aws_iam_policy_document.portal_policy.json
}

# =============================================================================
# IRSA — Kyverno admission controller
# =============================================================================
# The policy verify-image-provenance (idp-gitops/platform/kyverno) reads an image's signed
# build provenance from ECR before a pod is admitted. Read-only, repositories under svc/* only.

data "aws_iam_policy_document" "kyverno_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kyverno:kyverno-admission-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "kyverno_policy" {
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid = "ReadSvcRepos"
    actions = [
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [
      "arn:aws:ecr:ap-south-1:${data.aws_caller_identity.current.account_id}:repository/svc/*",
    ]
  }
}

resource "aws_iam_role" "kyverno" {
  # idp-gitops/platform/argocd-apps/kyverno.yaml refers to this name.
  name               = "idp-kyverno"
  assume_role_policy = data.aws_iam_policy_document.kyverno_assume_role.json

  tags = {
    Name = "idp-kyverno"
  }
}

resource "aws_iam_role_policy" "kyverno" {
  name   = "idp-kyverno-ecr-read"
  role   = aws_iam_role.kyverno.id
  policy = data.aws_iam_policy_document.kyverno_policy.json
}

# =============================================================================
# EBS CSI driver - REMOVED (Step 29)
# =============================================================================
# Nothing in the cluster uses EBS volumes, and its controller (2 replicas x 6
# containers, system-cluster-critical) was the pod that preempted the API in the
# Step 28 drain test. Removed to free memory on 2x t4g.small for Backstage.
# Re-add the add-on + an IRSA role with AmazonEBSCSIDriverPolicy if a PVC is needed.

