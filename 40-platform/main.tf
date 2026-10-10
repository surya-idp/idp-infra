# =============================================================================
# 40-platform/main.tf
#
# Platform layer — Argo CD + External Secrets Operator (ESO).
#
# PHILOSOPHY: Terraform installs ONLY Argo CD and ESO here.
#   Everything else (Kyverno, ALB Controller, Prometheus, Grafana, app namespaces,
#   ExternalSecrets, ClusterSecretStore) is installed BY Argo CD via app-of-apps.
#   Two reconcilers fighting is a real failure mode — Terraform owns the bootstrap,
#   Argo CD owns everything that Argo CD can manage.
#
# LIFECYCLE: DESTROYED every session (make down). Goes with 30-cluster.
#   Argo CD has no meaningful persistent state — all config is in Git.
#
# INSTALL ORDER (sync waves in Argo CD, but also logical dependency):
#   Wave 0: ESO (ExternalSecret CRDs must exist before apps reference them)
#   Wave 1: ALB Controller (Ingress resources need this to provision ALBs)
#   Wave 2: Kyverno (policy enforcement starts after controllers are up)
#   Wave 3: Prometheus + Grafana + metrics-server
#   Wave 4: Feature-flag-service app (depends on all above)
#
# COST: Argo CD runs on the EKS nodes — no extra AWS cost.
#   ESO runs on EKS nodes — no extra AWS cost.
#   ALB Controller provisions an ALB at ~$0.0239/hr — cost starts when app is deployed.
#
# ARGO CD VERSION: chart 10.9.2 -> Argo CD v3.5.3
#   Pin to a specific chart version to avoid surprises on make up.
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket  = "idp-tfstate-693906847772"
    key     = "40-platform/terraform.tfstate"
    region  = "ap-south-1"
    profile = "idp"
    # S3-native state lock (Terraform >= 1.10): a .tflock object next to the state.
    use_lockfile = true
  }
}

# ─── AWS provider (for reading remote state only) ─────────────────────────────

provider "aws" {
  region  = "ap-south-1"
  profile = "idp"

  default_tags {
    tags = {
      Project     = "idp"
      ManagedBy   = "terraform"
      Environment = "shared"
      Layer       = "40-platform"
    }
  }
}

# ─── Read cluster outputs from 30-cluster state ───────────────────────────────

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket  = "idp-tfstate-693906847772"
    key     = "30-cluster/terraform.tfstate"
    region  = "ap-south-1"
    profile = "idp"
  }
}

# ─── EKS cluster auth — used by helm and kubernetes providers ─────────────────

data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.cluster.outputs.cluster_name
}

# ─── Helm provider ────────────────────────────────────────────────────────────

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

# ─── Kubernetes provider (for namespaces and post-deploy manifests) ───────────

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

# =============================================================================
# EXTERNAL SECRETS OPERATOR (ESO)
# =============================================================================
# ESO bridges Kubernetes with AWS Secrets Manager.
# Installs CRDs: ExternalSecret, ClusterSecretStore, SecretStore.
# The ESO pod uses IRSA (via ServiceAccount annotation) to call secretsmanager:*.
#
# IRSA wiring:
#   ServiceAccount "external-secrets" in namespace "external-secrets"
#   → annotated with idp-eso IAM role ARN (from 30-cluster)
#   → role trust policy allows sts:AssumeRoleWithWebIdentity from this SA
#
# Chart: external-secrets/external-secrets
# installCRDs: true — CRDs installed with the chart (cleaner than separate apply)
# =============================================================================

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "eso" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.3"
  namespace        = kubernetes_namespace.external_secrets.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 300

  set {
    name  = "installCRDs"
    value = "true"
  }

  # Wire the ESO controller ServiceAccount to the IRSA role.
  # The trust policy in 30-cluster is already scoped to this exact SA name + namespace.
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.cluster.outputs.eso_irsa_role_arn
  }

  # The ALB controller registers a mutating webhook on ALL Services; until its pod is
  # ready, creating any Service (including ESO's) fails with "no endpoints available".
  depends_on = [kubernetes_namespace.external_secrets, helm_release.alb_controller]
}

# =============================================================================
# AWS LOAD BALANCER CONTROLLER
# =============================================================================
# Turns Ingress resources into ALBs. Installed here (not by Argo CD) because the
# Ingress in env-config cannot become healthy without it, and nothing else in the
# repo installs it yet - Step 26 may move it into an Argo CD app.
#
# IRSA role + policy come from 30-cluster (policy version must match chart version).
# ALBs it creates are NOT tracked by Terraform: scripts/down.sh deletes them
# before the cluster layer is destroyed.
# One replica: t4g.small nodes are small and this is a lab.
# =============================================================================

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"
  namespace  = "kube-system"
  wait       = true
  timeout    = 300

  set {
    name  = "clusterName"
    value = data.terraform_remote_state.cluster.outputs.cluster_name
  }
  set {
    name  = "region"
    value = "ap-south-1"
  }
  set {
    name  = "vpcId"
    value = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.terraform_remote_state.cluster.outputs.alb_controller_irsa_role_arn
  }
  set {
    name  = "replicaCount"
    value = "1"
  }
}

# =============================================================================
# ARGO CD
# =============================================================================
# Argo CD is installed by Terraform (bootstrap problem: Argo CD cannot install itself).
# After this, Argo CD owns everything — never apply K8s manifests to Argo-managed
# resources via kubectl or Terraform (selfHeal will fight you).
#
# Chart: argo/argo-cd
# Version: 10.9.2 (Argo CD v3.5.3) - pinned for reproducibility
#
# ADMIN PASSWORD: Auto-generated by the chart as a bcrypt hash.
#   Retrieve with:
#     kubectl get secret argocd-initial-admin-secret -n argocd \
#       -o jsonpath='{.data.password}' | base64 -d
#
# ACCESS: Port-forward only (no ALB for Argo CD — not worth the cost for a lab).
#   kubectl port-forward svc/argocd-server -n argocd 8080:443
#   Then: https://localhost:8080
#
# SERVER.INSECURE: true — disables TLS inside the pod (port-forward handles it).
#   This removes the double TLS which causes cert errors in the UI.
#
# REPO SERVER: pulls manifests from GitHub. The env-config repo is public so no
#   credentials needed. Private repos would need a GitHub App credential secret.
#
# NOTIFICATIONS: disabled — no alerting infra yet (Step 34).
# =============================================================================

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # 10.9.2 = Argo CD v3.5.3. Was 7.7.3 (v2.13), whose embedded Kubernetes schema predates
  # k8s 1.33 and broke server-side diffs against the 1.35 cluster (Finding 38).
  # Keep this within the Kubernetes versions Argo CD tests against when bumping EKS.
  version          = "10.9.2"
  namespace        = kubernetes_namespace.argocd.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [<<-EOT
    global:
      domain: localhost

    configs:
      params:
        server.insecure: true

      # Allow Argo CD to manage resources in all namespaces (needed for app-of-apps).
      # Without this, Argo CD can only sync into its own namespace.
      cm:
        # App-of-apps: Argo CD 1.8+ no longer reports health for Application resources,
        # so the root app would not wait for wave 0 (platform-cluster) before wave 1
        # (feature-flag-dev). This is the upstream-documented health check that restores it.
        resource.customizations.health.argoproj.io_Application: |
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.health ~= nil then
              hs.status = obj.status.health.status
              if obj.status.health.message ~= nil then
                hs.message = obj.status.health.message
              end
            end
          end
          return hs

    server:
      # Resource requests sized for t4g.small (2vCPU/2GiB per node, shared with system pods)
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 500m
          memory: 256Mi

    repoServer:
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 500m
          memory: 256Mi

    applicationSet:
      resources:
        requests:
          cpu: 20m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi

    notifications:
      enabled: false

    dex:
      enabled: false
  EOT
  ]

  depends_on = [kubernetes_namespace.argocd, helm_release.eso]
}

# =============================================================================
# ARGO CD - APP OF APPS ROOT APPLICATION
# =============================================================================
# The ONLY Application Terraform creates. It syncs env-config/platform/argocd-apps,
# which holds one child Application per concern (platform-cluster, feature-flag-dev).
# Children carry sync waves; the Application health check in argocd-cm (above) makes
# the root wait for each wave to be Healthy before starting the next.
#
# SYNC POLICY: automated + prune + selfHeal. Adding/removing a child Application file
# in Git is all it takes to deploy/remove an environment.
#
# WHY null_resource + kubectl, NOT kubernetes_manifest:
#   kubernetes_manifest validates the CRD at PLAN time, and Argo CD's CRDs do not exist
#   until helm_release.argocd is applied. local-exec runs at apply time, after the CRDs.
#
# DESTROY: scripts/down.sh deletes this Application first. Its finalizer cascades to the
#   children, whose finalizers delete their resources, including the Ingress, so the ALB
#   controller removes the ALB while it is still running. The destroy provisioner below
#   is the fallback when 40-platform is destroyed directly.
# =============================================================================

locals {
  # Project "bootstrap" holds only the root app: it may create Applications and AppProjects
  # in the argocd namespace, nothing else. idp-gitops then locks "default" (PLATFORM_REVIEW F4).
  argocd_root_app = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: bootstrap
      namespace: argocd
    spec:
      description: The root app-of-apps only
      sourceRepos:
        - https://github.com/surya-idp/idp-gitops
      destinations:
        - server: https://kubernetes.default.svc
          namespace: argocd
      clusterResourceWhitelist: []
      namespaceResourceWhitelist:
        - group: argoproj.io
          kind: Application
        - group: argoproj.io
          kind: AppProject
    ---
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: root
      namespace: argocd
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: bootstrap
      source:
        repoURL: https://github.com/surya-idp/idp-gitops
        targetRevision: HEAD
        path: platform/argocd-apps
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
  YAML
}

resource "null_resource" "argocd_root_app" {
  triggers = {
    # Re-apply if the cluster is new (every make up) or the manifest changes
    cluster_endpoint = data.aws_eks_cluster.this.endpoint
    manifest_hash    = sha256(local.argocd_root_app)
  }

  provisioner "local-exec" {
    command = "kubectl apply -f - <<'YAML'\n${local.argocd_root_app}YAML"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete application root -n argocd --ignore-not-found=true --timeout=180s || true"
  }

  depends_on = [helm_release.argocd, helm_release.alb_controller]
}

