# ─── EKS cluster ─────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name — used in aws eks update-kubeconfig and make up step 3"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint URL"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA cert for the EKS cluster (needed for kubeconfig)"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster — verify it is STANDARD_SUPPORT"
  value       = module.eks.cluster_version
}

# ─── OIDC / IRSA ─────────────────────────────────────────────────────────────

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for this cluster — used to build IRSA trust policies"
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — used in IRSA trust policy Federated principal"
  value       = module.eks.oidc_provider_arn
}

# ─── IRSA role ARNs (consumed by 40-platform Helm values) ────────────────────

output "eso_irsa_role_arn" {
  description = "IAM role ARN for External Secrets Operator — annotate its ServiceAccount with this"
  value       = aws_iam_role.eso.arn
}

output "alb_controller_irsa_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller — annotate its ServiceAccount"
  value       = aws_iam_role.alb_controller.arn
}

output "image_updater_irsa_role_arn" {
  description = "IAM role ARN for Argo CD Image Updater (annotated on its ServiceAccount in idp-gitops)"
  value       = aws_iam_role.image_updater.arn
}

output "portal_irsa_role_arn" {
  description = "IAM role ARN for Backstage (annotated on its ServiceAccount in idp-gitops)"
  value       = aws_iam_role.portal.arn
}

# ─── ElastiCache Valkey ───────────────────────────────────────────────────────

output "valkey_primary_endpoint" {
  description = "Valkey primary endpoint (host) — used in REDIS_URL env var for the app"
  value       = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "valkey_port" {
  description = "Valkey port (6379)"
  value       = 6379
}

# ─── NAT Gateway ─────────────────────────────────────────────────────────────

output "nat_gateway_public_ip" {
  description = "Public IP of the NAT Gateway — useful for whitelisting egress in external services"
  value       = aws_eip.nat.public_ip
}
