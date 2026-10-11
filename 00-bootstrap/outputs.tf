output "tfstate_bucket_name" {
  description = "S3 bucket name for Terraform remote state (all layers 10-90)"
  value       = aws_s3_bucket.tfstate.id
}

output "tfstate_bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.tfstate.arn
}

output "dynamodb_lock_table" {
  description = "DynamoDB table name for state locking"
  value       = aws_dynamodb_table.tfstate_locks.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "github_ci_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions CI"
  value       = aws_iam_role.github_ci.arn
}

output "service_ci_role_arn" {
  description = "ARN of the IAM role for template-created services (svc/* ECR only)"
  value       = aws_iam_role.service_ci.arn
}

output "techdocs_bucket_name" {
  description = "S3 bucket holding the documentation sites that Backstage TechDocs serves"
  value       = aws_s3_bucket.techdocs.id
}
