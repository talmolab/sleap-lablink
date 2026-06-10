#!/bin/bash
# cleanup-orphaned-resources.sh
# Manually clean up orphaned AWS resources for a LabLink environment
#
# Usage: ./cleanup-orphaned-resources.sh <environment> [--dry-run] [--yes]
# Example: ./cleanup-orphaned-resources.sh test
# Example: ./cleanup-orphaned-resources.sh test --dry-run
# Example: ./cleanup-orphaned-resources.sh test --yes
#
# Flags:
#   --dry-run  Show what would be deleted without making changes
#   --yes      Skip confirmation prompt and proceed automatically
#
# Environment variables:
#   NO_COLOR   Set to any value to disable colored output

set -e

# Colors for output (respects NO_COLOR environment variable)
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$REPO_ROOT/lablink-infrastructure/config/config.yaml"

# Parse arguments
ENV="${1:-}"
DRY_RUN=false
AUTO_CONFIRM=false

# Parse all arguments
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --yes)
      AUTO_CONFIRM=true
      ;;
    *)
      if [ -z "$ENV" ]; then
        ENV="$arg"
      fi
      ;;
  esac
done

if [ -z "$ENV" ]; then
  echo -e "${RED}Error: Environment name required${NC}"
  echo "Usage: $0 <environment> [--dry-run] [--yes]"
  echo "Example: $0 test"
  echo "Example: $0 test --dry-run"
  echo "Example: $0 test --yes"
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}DRY RUN MODE - No resources will be deleted${NC}"
  echo ""
fi

# Extract configuration from config.yaml
echo -e "${BLUE}Reading configuration...${NC}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
  exit 1
fi

# Extract bucket name
BUCKET=$(grep "^bucket_name:" "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
if [ -z "$BUCKET" ]; then
  echo -e "${RED}Error: bucket_name not found in $CONFIG_FILE${NC}"
  exit 1
fi

# Extract region from config.yaml, fall back to AWS CLI config
REGION=$(grep -A 5 "^app:" "$CONFIG_FILE" | grep "^  region:" | awk '{print $2}' | tr -d '"')
if [ -z "$REGION" ]; then
  echo -e "${YELLOW}Region not found in config.yaml, checking AWS CLI configuration...${NC}"
  REGION=$(aws configure get region 2>/dev/null || echo "")
fi

if [ -z "$REGION" ]; then
  echo -e "${YELLOW}Region not configured, defaulting to us-west-2${NC}"
  REGION="us-west-2"
fi

echo -e "${GREEN}Configuration:${NC}"
echo "  Environment: $ENV"
echo "  S3 Bucket:   $BUCKET"
echo "  AWS Region:  $REGION"
echo ""

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
  echo -e "${RED}Error: Unable to get AWS account ID. Are AWS credentials configured?${NC}"
  exit 1
fi
echo "  Account ID:  $ACCOUNT_ID"
echo ""

# Function to execute or simulate command
execute_cmd() {
  local description="$1"
  shift

  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY RUN]${NC} $description"
    echo -e "${BLUE}  Would run: $@${NC}"
  else
    echo -e "${description}"
    "$@"
  fi
}

echo -e "${YELLOW}=== Verification: Checking what exists ===${NC}"
echo ""

echo "Checking EC2 resources..."
aws ec2 describe-instances --region ${REGION} \
  --filters "Name=tag:Name,Values=*${ENV}*" "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table || echo "  No instances found"

echo ""
echo "Checking IAM resources..."
aws iam list-roles --query "Roles[?contains(RoleName, '${ENV}')].RoleName" --output table || echo "  No roles found"

echo ""
echo "Checking Security Groups..."
aws ec2 describe-security-groups --region ${REGION} \
  --filters "Name=group-name,Values=*${ENV}*" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' \
  --output table || echo "  No security groups found"

echo ""
echo "Checking Key Pairs..."
aws ec2 describe-key-pairs --region ${REGION} \
  --filters "Name=key-name,Values=*${ENV}*" \
  --query 'KeyPairs[*].KeyName' \
  --output table || echo "  No key pairs found"

echo ""
echo -e "${YELLOW}=== End Verification ===${NC}"
echo ""

# Confirmation prompt
if [ "$DRY_RUN" = false ] && [ "$AUTO_CONFIRM" = false ]; then
  echo -e "${RED}WARNING: This will permanently delete all resources for environment '${ENV}'${NC}"
  echo -e "${RED}This action cannot be undone!${NC}"
  echo ""
  read -p "Type 'yes' to confirm deletion: " CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted"
    exit 1
  fi
  echo ""
fi

echo -e "${BLUE}=== Starting cleanup for environment: ${ENV} ===${NC}"
echo ""

# Step 1: Terminate EC2 Instances
echo -e "${BLUE}1. Terminating EC2 instances...${NC}"

# Client VMs
INSTANCE_IDS=$(aws ec2 describe-instances --region ${REGION} \
  --filters "Name=tag:Name,Values=lablink-vm-${ENV}-*" "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text 2>/dev/null || echo "")

if [ -n "$INSTANCE_IDS" ]; then
  if [ "$DRY_RUN" = false ]; then
    aws ec2 terminate-instances --region ${REGION} --instance-ids $INSTANCE_IDS
    echo -e "  ${GREEN}[OK]${NC} Terminated client VMs: $INSTANCE_IDS"
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would terminate client VMs: $INSTANCE_IDS"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No client VMs found"
fi

# Allocator
INSTANCE_ID=$(aws ec2 describe-instances --region ${REGION} \
  --filters "Name=tag:Name,Values=LabLink Allocator Server (${ENV})" "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null || echo "")

if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
  if [ "$DRY_RUN" = false ]; then
    aws ec2 terminate-instances --region ${REGION} --instance-ids ${INSTANCE_ID}
    echo -e "  ${GREEN}[OK]${NC} Terminated allocator: ${INSTANCE_ID}"
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would terminate allocator: ${INSTANCE_ID}"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No allocator instance found"
fi

# Step 2: Wait for termination
echo ""
echo -e "${BLUE}2. Waiting for instances to terminate...${NC}"
if [ "$DRY_RUN" = false ] && { [ -n "$INSTANCE_IDS" ] || ( [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] ); }; then
  echo "  Waiting 30 seconds..."
  sleep 30
else
  echo -e "${YELLOW}[DRY RUN]${NC} Would wait 30 seconds"
fi

# Step 3: Delete Security Groups
echo ""
echo -e "${BLUE}3. Deleting security groups...${NC}"

# Client SG
SG_ID=$(aws ec2 describe-security-groups --region ${REGION} \
  --filters "Name=group-name,Values=lablink_client_${ENV}_sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  if [ "$DRY_RUN" = false ]; then
    if aws ec2 delete-security-group --region ${REGION} --group-id ${SG_ID} 2>/dev/null; then
      echo -e "  ${GREEN}[OK]${NC} Deleted client SG: ${SG_ID}"
    else
      echo -e "  ${YELLOW}⚠${NC} Client SG deletion failed (may need retry): ${SG_ID}"
    fi
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would delete client SG: ${SG_ID}"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No client security group found"
fi

# Allocator SG
SG_ID=$(aws ec2 describe-security-groups --region ${REGION} \
  --filters "Name=group-name,Values=allow_http_https_${ENV}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  if [ "$DRY_RUN" = false ]; then
    if aws ec2 delete-security-group --region ${REGION} --group-id ${SG_ID} 2>/dev/null; then
      echo -e "  ${GREEN}[OK]${NC} Deleted allocator SG: ${SG_ID}"
    else
      echo -e "  ${YELLOW}⚠${NC} Allocator SG deletion failed (may need retry): ${SG_ID}"
    fi
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would delete allocator SG: ${SG_ID}"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No allocator security group found"
fi

# Step 4: Delete Key Pairs
echo ""
echo -e "${BLUE}4. Deleting key pairs...${NC}"

if aws ec2 describe-key-pairs --region ${REGION} --key-names "lablink_key_pair_client_${ENV}" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = false ]; then
    if aws ec2 delete-key-pair --region ${REGION} --key-name "lablink_key_pair_client_${ENV}" 2>/dev/null; then
      echo -e "  ${GREEN}[OK]${NC} Deleted client key"
    else
      echo -e "  ${RED}[FAIL]${NC} Failed to delete client key"
    fi
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would delete client key: lablink_key_pair_client_${ENV}"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No client key pair found"
fi

if aws ec2 describe-key-pairs --region ${REGION} --key-names "lablink-key-${ENV}" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = false ]; then
    if aws ec2 delete-key-pair --region ${REGION} --key-name "lablink-key-${ENV}" 2>/dev/null; then
      echo -e "  ${GREEN}[OK]${NC} Deleted allocator key"
    else
      echo -e "  ${RED}[FAIL]${NC} Failed to delete allocator key"
    fi
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would delete allocator key: lablink-key-${ENV}"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No allocator key pair found"
fi

# Step 5: Release Elastic IP
echo ""
echo -e "${BLUE}5. Releasing Elastic IP...${NC}"

ALLOCATION_ID=$(aws ec2 describe-addresses --region ${REGION} \
  --filters "Name=tag:Name,Values=lablink-eip-${ENV}" \
  --query 'Addresses[0].AllocationId' \
  --output text 2>/dev/null || echo "")

if [ -n "$ALLOCATION_ID" ] && [ "$ALLOCATION_ID" != "None" ]; then
  if [ "$DRY_RUN" = false ]; then
    aws ec2 release-address --region ${REGION} --allocation-id ${ALLOCATION_ID}
    echo -e "  ${GREEN}[OK]${NC} Released EIP: ${ALLOCATION_ID}"
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would release EIP: ${ALLOCATION_ID}"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No Elastic IP found"
fi

# Step 6: Delete Lambda Function
echo ""
echo -e "${BLUE}6. Deleting Lambda function...${NC}"

if aws lambda get-function --function-name "lablink_log_processor_${ENV}" --region ${REGION} >/dev/null 2>&1; then
  if [ "$DRY_RUN" = false ]; then
    if aws lambda delete-function --function-name "lablink_log_processor_${ENV}" --region ${REGION} 2>/dev/null; then
      echo -e "  ${GREEN}[OK]${NC} Deleted Lambda"
    else
      echo -e "  ${RED}[FAIL]${NC} Failed to delete Lambda"
    fi
  else
    echo -e "${YELLOW}[DRY RUN]${NC} Would delete Lambda: lablink_log_processor_${ENV}"
  fi
else
  echo -e "  ${GREEN}[OK]${NC} No Lambda function found"
fi

# Step 7: Delete IAM Resources
echo ""
echo -e "${BLUE}7. Deleting IAM resources...${NC}"

# Lambda role
echo "  Deleting Lambda execution role..."
if [ "$DRY_RUN" = false ]; then
  aws iam detach-role-policy --role-name "lablink_lambda_exec_${ENV}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
  aws iam delete-role --role-name "lablink_lambda_exec_${ENV}" 2>/dev/null && echo -e "    ${GREEN}[OK]${NC} Deleted Lambda role" || echo -e "    ${GREEN}[OK]${NC} Lambda role not found"
else
  echo -e "  ${YELLOW}[DRY RUN]${NC} Would delete Lambda role: lablink_lambda_exec_${ENV}"
fi

# Legacy CloudWatch agent role (may exist from older deployments)
echo "  Deleting legacy CloudWatch agent role (if exists)..."
if [ "$DRY_RUN" = false ]; then
  aws iam detach-role-policy --role-name "lablink_cloud_watch_agent_role_${ENV}" \
    --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy" 2>/dev/null || true
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "lablink_client_instance_profile_${ENV}" \
    --role-name "lablink_cloud_watch_agent_role_${ENV}" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "lablink_client_instance_profile_${ENV}" 2>/dev/null || true
  aws iam delete-role --role-name "lablink_cloud_watch_agent_role_${ENV}" 2>/dev/null && echo -e "    ${GREEN}[OK]${NC} Deleted legacy CloudWatch agent role" || echo -e "    ${GREEN}[OK]${NC} Legacy CloudWatch agent role not found"
else
  echo -e "  ${YELLOW}[DRY RUN]${NC} Would delete legacy CloudWatch agent role and instance profile"
fi

# Instance role
echo "  Deleting allocator instance role..."
if [ "$DRY_RUN" = false ]; then
  aws iam detach-role-policy --role-name "lablink_instance_role_${ENV}" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/lablink_s3_backend_${ENV}" 2>/dev/null || true
  aws iam detach-role-policy --role-name "lablink_instance_role_${ENV}" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/lablink_cloudwatch_${ENV}" 2>/dev/null || true
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "lablink_instance_profile_${ENV}" \
    --role-name "lablink_instance_role_${ENV}" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "lablink_instance_profile_${ENV}" 2>/dev/null || true
  aws iam delete-role --role-name "lablink_instance_role_${ENV}" 2>/dev/null && echo -e "    ${GREEN}[OK]${NC} Deleted instance role" || echo -e "    ${GREEN}[OK]${NC} Instance role not found"
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/lablink_s3_backend_${ENV}" 2>/dev/null && echo -e "    ${GREEN}[OK]${NC} Deleted S3 backend policy" || echo -e "    ${GREEN}[OK]${NC} S3 backend policy not found"
  aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/lablink_cloudwatch_${ENV}" 2>/dev/null && echo -e "    ${GREEN}[OK]${NC} Deleted CloudWatch policy" || echo -e "    ${GREEN}[OK]${NC} CloudWatch policy not found"
else
  echo -e "  ${YELLOW}[DRY RUN]${NC} Would delete instance role, instance profile, and policies"
fi

# Step 8: Delete CloudWatch Log Groups
echo ""
echo -e "${BLUE}8. Deleting CloudWatch log groups...${NC}"

if [ "$DRY_RUN" = false ]; then
  aws logs delete-log-group --region ${REGION} --log-group-name "lablink-cloud-init-${ENV}" 2>/dev/null && echo -e "  ${GREEN}[OK]${NC} Deleted client log group" || echo -e "  ${GREEN}[OK]${NC} Client log group not found"
  aws logs delete-log-group --region ${REGION} --log-group-name "/aws/lambda/lablink_log_processor_${ENV}" 2>/dev/null && echo -e "  ${GREEN}[OK]${NC} Deleted Lambda log group" || echo -e "  ${GREEN}[OK]${NC} Lambda log group not found"
else
  echo -e "${YELLOW}[DRY RUN]${NC} Would delete CloudWatch log groups"
fi

# Step 9: Clean S3 State Files
echo ""
echo -e "${BLUE}9. Cleaning S3 state files...${NC}"

if [ "$DRY_RUN" = false ]; then
  # Backup state files first
  BACKUP_DIR="$REPO_ROOT/terraform-state-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${BACKUP_DIR}"
  echo "  Backing up state files to ${BACKUP_DIR}..."
  aws s3 cp s3://${BUCKET}/${ENV}/ "${BACKUP_DIR}/" --recursive 2>/dev/null && echo -e "  ${GREEN}[OK]${NC} State files backed up" || echo -e "  ${GREEN}[OK]${NC} No state files to backup"

  # Delete state files
  aws s3 rm s3://${BUCKET}/${ENV}/terraform.tfstate 2>/dev/null && echo -e "  ${GREEN}[OK]${NC} Deleted infrastructure state" || echo -e "  ${GREEN}[OK]${NC} Infrastructure state not found"
  aws s3 rm s3://${BUCKET}/${ENV}/client/ --recursive 2>/dev/null && echo -e "  ${GREEN}[OK]${NC} Deleted client state" || echo -e "  ${GREEN}[OK]${NC} Client state not found"
else
  echo -e "${YELLOW}[DRY RUN]${NC} Would backup and delete S3 state files"
fi

# Step 10: Clean DynamoDB Lock Entries
echo ""
echo -e "${BLUE}10. Cleaning DynamoDB lock entries...${NC}"

if [ "$DRY_RUN" = false ]; then
  aws dynamodb delete-item --table-name lock-table --region ${REGION} \
    --key "{\"LockID\": {\"S\": \"${BUCKET}/${ENV}/terraform.tfstate-md5\"}}" 2>/dev/null && echo -e "  ${GREEN}[OK]${NC} Deleted infrastructure lock" || echo -e "  ${GREEN}[OK]${NC} Infrastructure lock not found"
  aws dynamodb delete-item --table-name lock-table --region ${REGION} \
    --key "{\"LockID\": {\"S\": \"${BUCKET}/${ENV}/client/terraform.tfstate-md5\"}}" 2>/dev/null && echo -e "  ${GREEN}[OK]${NC} Deleted client lock" || echo -e "  ${GREEN}[OK]${NC} Client lock not found"
else
  echo -e "${YELLOW}[DRY RUN]${NC} Would delete DynamoDB lock entries"
fi

echo ""
echo -e "${GREEN}=== Cleanup complete for ${ENV} ===${NC}"
echo ""

if [ "$DRY_RUN" = false ]; then
  echo "Run the following command to verify everything is cleaned up:"
  echo "  aws ec2 describe-instances --region ${REGION} --filters \"Name=tag:Name,Values=*${ENV}*\" --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output table"
else
  echo -e "${YELLOW}This was a dry run. No resources were deleted.${NC}"
  echo "To actually delete resources, run without --dry-run flag:"
  echo "  $0 $ENV"
fi
echo ""
