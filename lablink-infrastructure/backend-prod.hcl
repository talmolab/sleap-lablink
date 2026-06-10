# Backend configuration for PROD environment
# Uses S3 backend for shared state management
# State stored in: s3://<bucket_name>/prod/terraform.tfstate
#
# Usage (Local):
#   ../scripts/init-terraform.sh prod  # Reads bucket from config/config.yaml
#   terraform plan -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=prod"
#   terraform apply -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=prod"
#
# Usage (Manual):
#   terraform init -backend-config=backend-prod.hcl -backend-config="bucket=YOUR-BUCKET"
#   terraform plan -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=prod"
#   terraform apply -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=prod"
#
# Usage (GitHub Actions):
#   Workflow: Deploy LabLink Infrastructure
#   Choose environment: prod
#
# Resource naming: {deployment_name}-{resource-type}-prod (e.g., sleap-lablink-eip-prod)
key            = "prod/terraform.tfstate"
dynamodb_table = "lock-table"
encrypt        = true
