# Backend configuration for CI-TEST environment
# For CI automated testing and manual pre-merge validation
# Uses S3 backend with separate state file to avoid conflicts with test/prod
# State stored in: s3://<bucket_name>/ci-test/terraform.tfstate
#
# Usage (Local):
#   ../scripts/init-terraform.sh ci-test  # Reads bucket from config/config.yaml (once supported)
#   terraform plan -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=ci-test"
#   terraform apply -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=ci-test"
#
# Usage (Manual):
#   terraform init -backend-config=backend-ci-test.hcl -backend-config="bucket=YOUR-BUCKET"
#   terraform plan -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=ci-test"
#   terraform apply -var="deployment_name=YOUR-DEPLOYMENT" -var="environment=ci-test"
#
# Usage (GitHub Actions):
#   Deploy LabLink Infrastructure -> Choose environment: ci-test
#   Destroy LabLink Infrastructure -> Choose environment: ci-test
#
# Resource naming: {deployment_name}-{resource-type}-ci-test (e.g., sleap-lablink-eip-ci-test)
# This allows simultaneous deployments alongside test/prod environments
key            = "ci-test/terraform.tfstate"
dynamodb_table = "lock-table"
encrypt        = true
