# =============================================================================
# 20-data/main.tf
#
# Data layer — RDS PostgreSQL, ElastiCache Valkey, Secrets Manager.
#
# LIFECYCLE RULE: Keep resources UP between sessions, but STOP instances.
#   make down → stops RDS + ElastiCache (preserves data, stops compute billing)
#   make up   → starts them again before bringing up the cluster
#
# COST BETWEEN SESSIONS (instances stopped):
#   RDS 20GB gp3 storage:  $0.131/GB-month × 20GB = $2.62/month
#   ElastiCache (stopped):  ~$0/month (Valkey single-node has no storage charge)
#   Secrets Manager:        $0.40/secret × 4 secrets = $1.60/month
#   Total idle cost:        ~$4.22/month
#
# RDS COMPUTE (when running during sessions):
#   db.t4g.micro: $0.021/hr × 3hr × 12 sessions = $0.76/month
#
# VALKEY NOTE: engine = "valkey" — same API as Redis, ~20% cheaper.
#   Do NOT use engine = "redis" for this project.
# =============================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket  = "idp-tfstate-693906847772"
    key     = "20-data/terraform.tfstate"
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
      Layer       = "20-data"
    }
  }
}

# ─── Remote state: read network outputs ──────────────────────────────────────

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket  = "idp-tfstate-693906847772"
    key     = "10-network/terraform.tfstate"
    region  = "ap-south-1"
    profile = "idp"
  }
}

# ─── RDS subnet group ────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "postgres" {
  name        = "idp-postgres"
  description = "Private subnets for RDS PostgreSQL"
  subnet_ids  = data.terraform_remote_state.network.outputs.private_subnet_ids

  tags = {
    Name = "idp-postgres-subnet-group"
  }
}

# ─── RDS password (never in tfvars, never in outputs) ────────────────────────

resource "random_password" "db" {
  length  = 32
  special = false # avoid characters that break PostgreSQL connection string parsing
}

# ─── RDS PostgreSQL ──────────────────────────────────────────────────────────

resource "aws_db_instance" "postgres" {
  identifier        = "idp-postgres"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro" # t4g.micro has no capacity in ap-south-1a/1b; t3.micro does
  allocated_storage = 20
  storage_type      = "gp2"
  storage_encrypted = true # AWS-managed KMS key: free; RDS is recreated every session, nothing to migrate

  db_name  = "feature_flags"
  username = "ff_admin"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.postgres.name
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.sg_rds_id]

  # HARD REQUIREMENT: RDS must never be reachable from the internet.
  # Verified post-apply: aws rds describe-db-instances ... --query PubliclyAccessible
  # must return false. psql from laptop must fail/timeout.
  publicly_accessible = false

  # Option B (destroy-every-session): skip_final_snapshot = true
  # If set to false, every terraform destroy takes a 20GB snapshot at $0.131/GB-month.
  # 12 destroys/month = $31/month in snapshots — completely defeats Option B's purpose.
  skip_final_snapshot = true
  deletion_protection = false

  # backup_retention_period = 0 means no automated daily backups.
  # Automated backups = extra storage cost. Not needed for ephemeral lab instances.
  backup_retention_period = 0

  # Performance Insights adds cost — disable in lab
  performance_insights_enabled = false

  lifecycle {
    # final_snapshot_identifier uses timestamp() which re-evaluates on every plan,
    # producing a permanent "will update" diff even when nothing changed.
    ignore_changes = [final_snapshot_identifier]
  }

  tags = {
    Name = "idp-postgres"
  }
}

# ─── Secrets Manager ─────────────────────────────────────────────────────────
# All secrets are created here. Values are populated immediately for DB creds
# (auto-generated) and as placeholder strings for the rest (filled manually
# or by ESO rotation once the cluster is up).
#
# NEVER output plaintext secret values.
# Verification pattern: compare sha256sum before/after rotation, never echo.

# DB credentials — auto-generated, stored immediately
resource "aws_secretsmanager_secret" "db_creds" {
  name                    = "idp/db-creds"
  description             = "RDS PostgreSQL credentials and connection info"
  recovery_window_in_days = 0 # immediate deletion in lab (no 7-30 day quarantine)
}

resource "aws_secretsmanager_secret_version" "db_creds" {
  secret_id = aws_secretsmanager_secret.db_creds.id
  secret_string = jsonencode({
    username = aws_db_instance.postgres.username
    password = random_password.db.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = aws_db_instance.postgres.db_name
    url      = "postgresql+psycopg2://${aws_db_instance.postgres.username}:${random_password.db.result}@${aws_db_instance.postgres.endpoint}/feature_flags"
  })

  # Lifecycle: ignore_changes on secret_string so manual rotations in the console
  # do not get overwritten on the next terraform apply.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# JWT signing key - generated fresh every make up.
# Was a placeholder to fill in by hand, but Argo CD now deploys the app automatically
# right after make up, so a placeholder would be live before anyone could replace it.
# A new key per session is fine: the whole database (users, tokens' audience) is new too.
resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "idp/jwt-secret"
  description             = "JWT signing key for feature-flag-service"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id = aws_secretsmanager_secret.jwt_secret.id
  secret_string = jsonencode({
    JWT_SECRET_KEY = random_password.jwt.result
  })

  # Manual rotation in the console (ESO rotation test) must not be overwritten.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Grafana admin password — placeholder
resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "idp/grafana-admin"
  description             = "Grafana admin password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    admin-password = "REPLACE_ME_before_first_cluster_up"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Backstage GitHub App — placeholder; populated in Step 29
resource "aws_secretsmanager_secret" "backstage_github_app" {
  name                    = "idp/backstage-github-app"
  description             = "Backstage GitHub App idp-backstage (appId, clientId, clientSecret, privateKey)"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "backstage_github_app" {
  secret_id = aws_secretsmanager_secret.backstage_github_app.id
  secret_string = jsonencode({
    # Placeholders only. Real values are loaded from ~/.idp by
    # scripts/load-local-secrets.sh during `make up` (ignore_changes below keeps them).
    appId        = "REPLACE_ME"
    clientId     = "REPLACE_ME"
    clientSecret = "REPLACE_ME"
    privateKey   = "REPLACE_ME"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
