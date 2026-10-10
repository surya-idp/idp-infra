PROFILE  := idp
ACCOUNT  := 693906847772
REGION   := ap-south-1

.PHONY: up down verify-empty

# =============================================================================
# LIFECYCLE STRATEGY — Option B (destroy-every-session)
#
# make up   → creates everything from zero, ~20-27 min total
# make down → destroys everything, AWS cost drops to $0.00 immediately
#
# WHAT SURVIVES make down:
#   - VPC, subnets, SGs, IGW, route tables   (free, not worth destroying)
#   - S3 state bucket (S3-native locks; the DynamoDB table is unused)  (free, never destroy)
#   - IAM role, OIDC provider                (free)
#
# WHAT IS DESTROYED every make down:
#   - RDS PostgreSQL (all data gone — no final snapshot, no storage cost)
#   - ElastiCache Valkey (stateless cache, fine to destroy)
#   - Secrets Manager (4 secrets — recreated fresh each session)
#   - EKS cluster + worker nodes
#   - NAT Gateway + Elastic IPs
#   - ALB (if created by AWS Load Balancer Controller)
#   - Argo CD and all platform components
#
# COST AFTER make down: $0.00/month
# COST DURING SESSION:  ~$0.28/hr (EKS, 3x t4g.small on-demand, NAT, ALB, RDS, Valkey; HANDOVER section 3)
#
# IMPORTANT: verify-empty MUST pass before closing laptop.
# If it shows any resources, something did not destroy cleanly — investigate.
# =============================================================================

# ─── Session start ────────────────────────────────────────────────────────────
# Order: data first (slowest — RDS takes ~5 min), then cluster, then platform.
up:
	@echo ""
	@echo "╔══════════════════════════════════════════════╗"
	@echo "║          idp — Starting session              ║"
	@echo "║    Estimated time: 20-27 minutes total       ║"
	@echo "╚══════════════════════════════════════════════╝"
	@echo ""
	@echo "==> [1/4] Creating data layer (RDS + Secrets Manager)..."
	terraform -chdir=20-data init -input=false
	terraform -chdir=20-data apply -auto-approve
	@./scripts/load-local-secrets.sh
	@echo ""
	@echo "==> [2/4] Creating cluster layer (EKS + NAT + Valkey)..."
	terraform -chdir=30-cluster init -input=false
	terraform -chdir=30-cluster apply -auto-approve
	@echo ""
	@echo "==> [3/4] Updating kubeconfig..."
	aws eks update-kubeconfig \
	  --name idp-cluster \
	  --region $(REGION) \
	  --profile $(PROFILE)
	@echo ""
	@echo "==> [4/4] Creating platform layer (Argo CD; it installs everything else from idp-gitops)..."
	terraform -chdir=40-platform init -input=false
	terraform -chdir=40-platform apply -auto-approve
	@echo ""
	@echo "==> Waiting for Argo CD root app to be Healthy..."
	kubectl wait --for=jsonpath='{.status.health.status}'=Healthy application/root \
	  -n argocd --timeout=900s || echo "WARN: root app not Healthy yet - check: kubectl get applications -n argocd"
	@echo ""
	@echo "╔══════════════════════════════════════════════╗"
	@echo "║         Environment ready!                   ║"
	@echo "║  Run 'make verify-empty' before shutdown.    ║"
	@echo "╚══════════════════════════════════════════════╝"

# ─── Session end ─────────────────────────────────────────────────────────────
# Order: platform first (safest), then cluster, then data.
# All layers are DESTROYED — not stopped. Cost after this: $0.00.
# Old data (feature flags, users) does NOT survive. This is expected.
down:
	@echo ""
	@echo "╔══════════════════════════════════════════════╗"
	@echo "║           idp — Shutting down                ║"
	@echo "║   All data will be permanently deleted.      ║"
	@echo "║   Cost after completion: $0.00/month         ║"
	@echo "╚══════════════════════════════════════════════╝"
	@echo ""
	@./scripts/down.sh

# ─── Cost safety check (must return OK before closing laptop) ─────────────────
# Checks ALL tagged idp resources still running.
# VPC/subnets/SGs are free and will show up — that is normal and expected.
# The check filters to only BILLABLE resource types.
verify-empty:
	@python3 scripts/verify-empty.py
