# =============================================================================
# 40-platform/outputs.tf
# =============================================================================

output "argocd_server_service" {
  description = "Port-forward command to access Argo CD UI"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

output "argocd_initial_password_command" {
  description = "Command to retrieve the Argo CD initial admin password"
  value       = "kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d && echo"
}

output "argocd_namespace" {
  description = "Namespace where Argo CD is installed"
  value       = kubernetes_namespace.argocd.metadata[0].name
}
