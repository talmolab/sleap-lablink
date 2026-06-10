# Backend configuration for DEV environment
# Uses local state file for rapid development and testing
# No S3 bucket or DynamoDB table required
# State stored in: ./terraform.tfstate
#
# Usage (Local):
#   ../scripts/init-terraform.sh dev
#   terraform plan -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=dev"
#   terraform apply -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=dev"
#
# Usage (Manual):
#   terraform init -backend-config=backend-dev.hcl
#   terraform plan -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=dev"
#   terraform apply -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=dev"
#
# Usage (GitHub Actions):
#   NOT AVAILABLE - Local development only
#
# Note: Not suitable for team collaboration or CI/CD
# Resource naming: {deployment_name}-{resource-type}-dev (e.g., sleap-lablink-eip-dev)