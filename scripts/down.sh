#!/usr/bin/env bash
# down.sh - tear down every billable layer, and fail loudly if anything is left.
#
# Called by: make down
# Order: k8s-created AWS resources (ALBs) -> 40-platform -> 30-cluster -> 20-data -> verify.
# Unlike the old `|| true` chain, a failed step is recorded, the remaining layers are
# still attempted, and the script exits non-zero so a leak cannot go unnoticed.
set -uo pipefail

export AWS_PROFILE="${AWS_PROFILE:-idp}" AWS_PAGER=""
REGION=ap-south-1
CLUSTER=idp-cluster
cd "$(dirname "$0")/.."
FAILED=()

step() { echo; echo "==> $*"; }

# --- 0. Kubernetes-created ALBs --------------------------------------------------
# The ALB controller creates ALBs/target groups/ENIs outside Terraform. If they still
# exist when 30-cluster is destroyed, the VPC/subnets/SGs cannot be deleted.
step "[0/3] Removing Argo CD apps so the ALB controller deletes its ALB..."
if aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1
  # Argo CD selfHeal would recreate a deleted Ingress, so delete the root Application
  # instead: its finalizer cascades to the children, which delete their resources
  # (Ingress included) while the ALB controller is still running.
  # Children are removed in reverse wave order (apps first, the load balancer controller
  # last), so this takes longer than when the root had three children.
  kubectl delete application root -n argocd --ignore-not-found --timeout=600s 2>&1 \
    || echo "WARN: root app delete timed out; falling back to direct deletes"
  kubectl delete ingress --all --all-namespaces --timeout=120s 2>&1 \
    || echo "WARN: ingress delete failed/timed out; falling back to direct ALB delete"
else
  echo "Cluster not found - skipping kubectl cleanup."
fi

# Fallback / confirmation: delete any ALB tagged by the controller for this cluster,
# or in this project's VPC, that is still around.
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=tag:Project,Values=idp \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  for arn in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "Deleting leftover load balancer $arn"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn" || FAILED+=("delete ALB $arn")
  done
  for arn in $(aws elbv2 describe-target-groups --region "$REGION" \
      --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null); do
    aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" 2>/dev/null \
      || { sleep 20; aws elbv2 delete-target-group --region "$REGION" --target-group-arn "$arn" || FAILED+=("delete target group $arn"); }
  done
fi

# --- 1-3. Terraform layers -------------------------------------------------------
destroy() {
  step "$1 Destroying $2..."
  terraform -chdir="$2" init -input=false >/dev/null || { FAILED+=("init $2"); return; }
  terraform -chdir="$2" destroy -auto-approve || FAILED+=("destroy $2")
}
destroy "[1/3]" 40-platform
destroy "[2/3]" 30-cluster
destroy "[3/3]" 20-data

# --- Verify ---------------------------------------------------------------------
step "Verifying AWS is empty..."
python3 scripts/verify-empty.py || FAILED+=("verify-empty")

echo
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "!!! make down did NOT finish cleanly. Do NOT close the laptop:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
echo "make down finished cleanly. Cost until next 'make up': \$0.00"
