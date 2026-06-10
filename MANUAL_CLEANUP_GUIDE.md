# Manual Cleanup Guide

## Overview

This guide provides step-by-step procedures for manually cleaning up AWS resources when the automated destroy workflow fails or leaves orphaned resources.

### When to Use This Guide

- Destroy workflow fails with errors
- Terraform state becomes corrupted or out of sync
- Resources remain after running destroy
- Need to clean up a test environment manually
- Troubleshooting partial deployment failures

### Prerequisites

- AWS CLI installed and configured
- Credentials with sufficient permissions (PowerUser or Administrator)
- Know your environment name (`test`, `prod`, `ci-test`, etc.)
- Know your S3 bucket name (from config.yaml: `bucket_name`)

### Safety Warnings

⚠️ **IMPORTANT**: Manual cleanup bypasses Terraform state tracking. Only use these procedures when automated destroy fails.

⚠️ **DATA LOSS**: These procedures permanently delete resources and data. Verify you're targeting the correct environment.

⚠️ **VERIFY FIRST**: Always list resources before deleting them to ensure you're removing the right ones.

---

## Quick Resource Verification

Before starting cleanup, verify what resources exist for your environment:

```bash
# Set your environment name
ENV="ci-test"  # or "test" or "prod"

# Check EC2 instances
aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:Name,Values=*${ENV}*" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output table

# Check IAM roles
aws iam list-roles --query "Roles[?contains(RoleName, '${ENV}')].RoleName" --output table

# Check security groups
aws ec2 describe-security-groups --region us-west-2 \
  --filters "Name=group-name,Values=*${ENV}*" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' \
  --output table

# Check key pairs
aws ec2 describe-key-pairs --region us-west-2 \
  --filters "Name=key-name,Values=*${ENV}*" \
  --query 'KeyPairs[*].KeyName' \
  --output table

# Check S3 state files
BUCKET="your-bucket-name"  # Replace with your bucket from config.yaml
aws s3 ls s3://${BUCKET}/${ENV}/ --recursive
```

---

## Manual Cleanup Procedures by Resource Type

### 1. IAM Resources

IAM resources must be cleaned in this order: detach policies → delete instance profiles → delete roles → delete custom policies.

#### A. List All IAM Resources for Environment

```bash
ENV="ci-test"

# List roles
echo "=== IAM Roles ==="
aws iam list-roles --query "Roles[?contains(RoleName, '${ENV}')].RoleName" --output table

# List policies
echo "=== IAM Policies ==="
aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, '${ENV}')].PolicyName" --output table

# List instance profiles
echo "=== Instance Profiles ==="
aws iam list-instance-profiles --query "InstanceProfiles[?contains(InstanceProfileName, '${ENV}')].[InstanceProfileName,Roles[0].RoleName]" --output table
```

#### B. Delete CloudWatch Agent Role (Client VMs)

```bash
ENV="ci-test"
ROLE_NAME="lablink_cloud_watch_agent_role_${ENV}"
PROFILE_NAME="lablink_client_instance_profile_${ENV}"

# Detach managed policy
aws iam detach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"

# Remove role from instance profile
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${PROFILE_NAME}" \
  --role-name "${ROLE_NAME}"

# Delete instance profile
aws iam delete-instance-profile --instance-profile-name "${PROFILE_NAME}"

# Delete role
aws iam delete-role --role-name "${ROLE_NAME}"

echo "✓ Deleted CloudWatch agent role"
```

#### C. Delete Allocator Instance Role

```bash
ENV="ci-test"
ROLE_NAME="lablink_instance_role_${ENV}"
PROFILE_NAME="lablink_instance_profile_${ENV}"

# Get custom policy ARN
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/lablink_s3_backend_${ENV}"

# Detach custom policy
aws iam detach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}"

# Remove role from instance profile
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${PROFILE_NAME}" \
  --role-name "${ROLE_NAME}"

# Delete instance profile
aws iam delete-instance-profile --instance-profile-name "${PROFILE_NAME}"

# Delete role
aws iam delete-role --role-name "${ROLE_NAME}"

# Delete custom policy
aws iam delete-policy --policy-arn "${POLICY_ARN}"

echo "✓ Deleted allocator instance role and policy"
```

#### D. Delete Lambda Execution Role

```bash
ENV="ci-test"
ROLE_NAME="lablink_lambda_exec_${ENV}"

# Detach AWS managed policy
aws iam detach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

# Delete role
aws iam delete-role --role-name "${ROLE_NAME}"

echo "✓ Deleted Lambda execution role"
```

---

### 2. Client VM Resources

Client VMs are created by the allocator and may be orphaned if the allocator is destroyed first.

#### A. Find and Terminate Client VMs

```bash
ENV="ci-test"

# List client VMs
echo "=== Client VMs ==="
aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:Name,Values=lablink-vm-${ENV}-*" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0],LaunchTime]' \
  --output table

# Get instance IDs
INSTANCE_IDS=$(aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:Name,Values=lablink-vm-${ENV}-*" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

# Terminate instances
if [ ! -z "$INSTANCE_IDS" ]; then
  echo "Terminating instances: $INSTANCE_IDS"
  aws ec2 terminate-instances --region us-west-2 --instance-ids $INSTANCE_IDS
  echo "✓ Client VMs terminating"
else
  echo "✓ No client VMs found"
fi
```

#### B. Delete Client VM Security Group

```bash
ENV="ci-test"
SG_NAME="lablink_client_${ENV}_sg"

# Find security group ID
SG_ID=$(aws ec2 describe-security-groups --region us-west-2 \
  --filters "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [ "$SG_ID" != "None" ] && [ ! -z "$SG_ID" ]; then
  # Wait for instances to fully terminate
  echo "Waiting for instances to detach from security group..."
  sleep 30

  # Delete security group
  aws ec2 delete-security-group --region us-west-2 --group-id "${SG_ID}"
  echo "✓ Deleted client VM security group"
else
  echo "✓ No client VM security group found"
fi
```

#### C. Delete Client VM Key Pair

```bash
ENV="ci-test"
KEY_NAME="lablink_key_pair_client_${ENV}"

# Check if key exists
if aws ec2 describe-key-pairs --region us-west-2 --key-names "${KEY_NAME}" 2>/dev/null; then
  aws ec2 delete-key-pair --region us-west-2 --key-name "${KEY_NAME}"
  echo "✓ Deleted client VM key pair"
else
  echo "✓ No client VM key pair found"
fi
```

---

### 3. Allocator Infrastructure Resources

#### A. Terminate Allocator Instance

```bash
ENV="ci-test"

# Find allocator instance
INSTANCE_ID=$(aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:Name,Values=lablink_allocator_server_${ENV}" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

if [ "$INSTANCE_ID" != "None" ] && [ ! -z "$INSTANCE_ID" ]; then
  aws ec2 terminate-instances --region us-west-2 --instance-ids "${INSTANCE_ID}"
  echo "✓ Allocator instance terminating: ${INSTANCE_ID}"
else
  echo "✓ No allocator instance found"
fi
```

#### B. Release Elastic IP (if using dynamic strategy)

```bash
ENV="ci-test"

# Find EIP allocation ID
ALLOCATION_ID=$(aws ec2 describe-addresses --region us-west-2 \
  --filters "Name=tag:Name,Values=lablink-eip-${ENV}" \
  --query 'Addresses[0].AllocationId' \
  --output text)

if [ "$ALLOCATION_ID" != "None" ] && [ ! -z "$ALLOCATION_ID" ]; then
  aws ec2 release-address --region us-west-2 --allocation-id "${ALLOCATION_ID}"
  echo "✓ Released Elastic IP"
else
  echo "✓ No Elastic IP found"
fi
```

#### C. Delete Allocator Security Group

```bash
ENV="ci-test"
SG_NAME="allow_http_https_${ENV}"

# Find security group ID
SG_ID=$(aws ec2 describe-security-groups --region us-west-2 \
  --filters "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [ "$SG_ID" != "None" ] && [ ! -z "$SG_ID" ]; then
  aws ec2 delete-security-group --region us-west-2 --group-id "${SG_ID}"
  echo "✓ Deleted allocator security group"
else
  echo "✓ No allocator security group found"
fi
```

#### D. Delete Allocator Key Pair

```bash
ENV="ci-test"
KEY_NAME="lablink-key-${ENV}"

if aws ec2 describe-key-pairs --region us-west-2 --key-names "${KEY_NAME}" 2>/dev/null; then
  aws ec2 delete-key-pair --region us-west-2 --key-name "${KEY_NAME}"
  echo "✓ Deleted allocator key pair"
else
  echo "✓ No allocator key pair found"
fi
```

---

### 4. DNS Resources

If using Terraform-managed DNS (`dns.terraform_managed: true`), you may need to manually remove DNS records.

```bash
ENV="ci-test"
ZONE_ID="Z1038183268T83E91AYJF"  # Replace with your zone ID
RECORD_NAME="ci-test.lablink-template-testing.com"  # Replace with your record

# List A records
aws route53 list-resource-record-sets \
  --hosted-zone-id "${ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']"

# If record exists, create a change batch file
cat > /tmp/delete-record.json <<EOF
{
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "1.2.3.4"
          }
        ]
      }
    }
  ]
}
EOF

# Note: Replace "Value" with actual IP from list command above
# Then run:
# aws route53 change-resource-record-sets --hosted-zone-id "${ZONE_ID}" --change-batch file:///tmp/delete-record.json
```

---

### 5. CloudWatch Resources

CloudWatch log groups may contain valuable historical logs. Consider archiving before deletion.

```bash
ENV="ci-test"

# List log groups
echo "=== CloudWatch Log Groups ==="
aws logs describe-log-groups --region us-west-2 \
  --log-group-name-prefix lablink \
  --query "logGroups[?contains(logGroupName, '${ENV}')].logGroupName" \
  --output table

# Delete client VM log group
LOG_GROUP="lablink-cloud-init-${ENV}"
if aws logs describe-log-groups --region us-west-2 --log-group-name-prefix "${LOG_GROUP}" --query "logGroups[0]" 2>/dev/null; then
  aws logs delete-log-group --region us-west-2 --log-group-name "${LOG_GROUP}"
  echo "✓ Deleted ${LOG_GROUP}"
fi

# Delete Lambda log group
LOG_GROUP="/aws/lambda/lablink_log_processor_${ENV}"
if aws logs describe-log-groups --region us-west-2 --log-group-name-prefix "${LOG_GROUP}" --query "logGroups[0]" 2>/dev/null; then
  aws logs delete-log-group --region us-west-2 --log-group-name "${LOG_GROUP}"
  echo "✓ Deleted ${LOG_GROUP}"
fi
```

---

### 6. Lambda Functions

```bash
ENV="ci-test"
FUNCTION_NAME="lablink_log_processor_${ENV}"

# Check if function exists
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region us-west-2 2>/dev/null; then
  aws lambda delete-function --function-name "${FUNCTION_NAME}" --region us-west-2
  echo "✓ Deleted Lambda function"
else
  echo "✓ No Lambda function found"
fi
```

---

### 7. S3 and DynamoDB State Management

#### A. List State Files

```bash
ENV="ci-test"
BUCKET="your-bucket-name"  # Replace with your bucket

# List all state files for environment
aws s3 ls s3://${BUCKET}/${ENV}/ --recursive
```

#### B. Backup State Files (Recommended)

```bash
ENV="ci-test"
BUCKET="your-bucket-name"
BACKUP_DIR="./terraform-state-backup-$(date +%Y%m%d-%H%M%S)"

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Download state files
aws s3 cp s3://${BUCKET}/${ENV}/ "${BACKUP_DIR}/" --recursive

echo "✓ State files backed up to ${BACKUP_DIR}"
```

#### C. Delete State Files

```bash
ENV="ci-test"
BUCKET="your-bucket-name"

# Delete infrastructure state
aws s3 rm s3://${BUCKET}/${ENV}/terraform.tfstate

# Delete client VM state
aws s3 rm s3://${BUCKET}/${ENV}/client/terraform.tfstate
aws s3 rm s3://${BUCKET}/${ENV}/client/terraform.runtime.tfvars

echo "✓ State files deleted"
```

#### D. Clean DynamoDB Lock Entries

**⚠️ CRITICAL**: Only delete lock entries if you're certain no Terraform operations are running.

```bash
ENV="ci-test"
BUCKET="your-bucket-name"

# List lock entries for environment
aws dynamodb scan --table-name lock-table --region us-west-2 \
  --filter-expression "contains(LockID, :prefix)" \
  --expression-attribute-values "{\":prefix\": {\"S\": \"${BUCKET}/${ENV}\"}}" \
  --query 'Items[*].LockID.S' \
  --output table

# Delete infrastructure state lock
aws dynamodb delete-item --table-name lock-table --region us-west-2 \
  --key "{\"LockID\": {\"S\": \"${BUCKET}/${ENV}/terraform.tfstate-md5\"}}"

# Delete client VM state lock
aws dynamodb delete-item --table-name lock-table --region us-west-2 \
  --key "{\"LockID\": {\"S\": \"${BUCKET}/${ENV}/client/terraform.tfstate-md5\"}}"

echo "✓ DynamoDB lock entries deleted"
```

---

## Common Failure Scenarios

### Scenario 1: "State Data in S3 Does Not Have Expected Content"

**Error:**
```
Error refreshing state: state data in S3 does not have the expected content.
The checksum calculated for the state stored in S3 does not match the checksum stored in DynamoDB.
```

**Cause:** DynamoDB has a digest entry for a state file that doesn't exist, is empty, or was modified outside of Terraform.

**Fix:**

```bash
ENV="ci-test"
BUCKET="your-bucket-name"

# Delete the corrupted DynamoDB digest entry
aws dynamodb delete-item --table-name lock-table --region us-west-2 \
  --key "{\"LockID\": {\"S\": \"${BUCKET}/${ENV}/client/terraform.tfstate-md5\"}}"

# If state file is corrupted, delete it
aws s3 rm s3://${BUCKET}/${ENV}/client/terraform.tfstate

echo "✓ Fixed checksum mismatch"
```

---

### Scenario 2: "Cannot Delete Entity, Must Detach All Policies First"

**Error:**
```
An error occurred (DeleteConflict) when calling the DeleteRole operation:
Cannot delete entity, must detach all policies first.
```

**Cause:** Trying to delete an IAM role that still has policies attached.

**Fix:**

```bash
ROLE_NAME="lablink_instance_role_ci-test"

# List attached policies
echo "Attached policies:"
aws iam list-attached-role-policies --role-name "${ROLE_NAME}"

# Detach each policy (get ARN from list above)
aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "arn:aws:iam::ACCOUNT:policy/POLICY_NAME"

# Now delete role
aws iam delete-role --role-name "${ROLE_NAME}"
```

---

### Scenario 3: "Cannot Delete Entity, Must Remove Roles from Instance Profile First"

**Error:**
```
An error occurred (DeleteConflict) when calling the DeleteRole operation:
Cannot delete entity, must remove roles from instance profile first.
```

**Cause:** Role is still attached to an instance profile.

**Fix:**

```bash
ROLE_NAME="lablink_cloud_watch_agent_role_ci-test"

# Find instance profile
PROFILE_NAME=$(aws iam list-instance-profiles-for-role --role-name "${ROLE_NAME}" \
  --query 'InstanceProfiles[0].InstanceProfileName' --output text)

# Remove role from instance profile
aws iam remove-role-from-instance-profile \
  --instance-profile-name "${PROFILE_NAME}" \
  --role-name "${ROLE_NAME}"

# Delete instance profile
aws iam delete-instance-profile --instance-profile-name "${PROFILE_NAME}"

# Now delete role
aws iam delete-role --role-name "${ROLE_NAME}"
```

---

### Scenario 4: "Security Group Cannot Be Deleted (Resource in Use)"

**Error:**
```
An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation:
resource sg-xxx has a dependent object
```

**Cause:** Security group is still attached to running or recently terminated instances.

**Fix:**

```bash
SG_ID="sg-xxx"

# Check what's using it
aws ec2 describe-network-interfaces --region us-west-2 \
  --filters "Name=group-id,Values=${SG_ID}"

# Wait for instances to fully terminate (can take 1-2 minutes)
echo "Waiting 60 seconds for instances to detach..."
sleep 60

# Retry deletion
aws ec2 delete-security-group --region us-west-2 --group-id "${SG_ID}"
```

---

### Scenario 5: Orphaned Client VMs After Allocator Destroyed

**Situation:** Allocator was destroyed but client VMs are still running.

**Fix:** Follow [Section 2: Client VM Resources](#2-client-vm-resources) to:
1. Terminate client VMs
2. Delete client security group
3. Delete client key pair
4. Clean up client VM state files

---

### Scenario 6: Let's Encrypt Rate Limit Reached

**Error:**
```
too many certificates already issued for exact set of domains
```

**Cause:** Let's Encrypt has strict rate limits:
- **5 certificates per exact domain every 7 days** (e.g., `test.lablink.example.com`)
- 50 certificates per registered domain every 7 days (e.g., all `*.example.com` subdomains)
- Rate limit violations result in **7-day lockout with NO override available**

**What Triggers a New Certificate:**
- Deploying with `terraform apply` (first time or after destroy)
- Re-deploying after DNS changes
- Re-deploying after changing the domain name
- Caddy container restart with lost certificate cache

**Important:** Deleting old certificates from Let's Encrypt does NOT help. The limit is on **certificate issuance**, not on active certificates. Once you've requested 5 certificates for a domain within 7 days, you must wait.

**Recovery Options:**

**Option 1: Wait for Rate Limit to Reset**
```bash
# Check current certificate usage for your domain
# Visit: https://crt.sh/?q=your-domain.com

# Rate limit window is sliding 7-day basis
# Calculate reset time: 7 days from oldest certificate in the window
```

**Option 2: Switch to Different Subdomain**
```bash
# Each subdomain gets its own 5-certificate quota
# Example: If test.lablink.example.com is locked out, use test2.lablink.example.com

# Update config.yaml
sed -i 's/domain: "test\.lablink\.example\.com"/domain: "test2.lablink.example.com"/' \
  lablink-infrastructure/config/config.yaml

# Deploy with new subdomain
# Don't forget to update DNS records if using terraform_managed: false
```

**Option 3: Switch to IP-Only Deployment (No Rate Limits)**
```bash
# Edit lablink-infrastructure/config/config.yaml
# Set:
#   dns:
#     enabled: false
#   ssl:
#     provider: "none"
#   eip:
#     strategy: "dynamic"  # or "persistent" if you have an EIP

# Deploy without DNS/SSL
# Access via IP address: http://<ALLOCATOR_IP>:5000
```

**Option 4: Switch to CloudFlare SSL (No Let's Encrypt Limits)**
```bash
# Edit lablink-infrastructure/config/config.yaml
# Set:
#   dns:
#     enabled: true
#     terraform_managed: false  # Manage DNS in CloudFlare
#     domain: "test.lablink.example.com"
#   ssl:
#     provider: "cloudflare"

# Deploy infrastructure
# Then manually create A record in CloudFlare console pointing to allocator IP
# Enable CloudFlare proxy (orange cloud icon) for SSL
```

**Prevention:**

Before deploying with Let's Encrypt, check your certificate quota:

```bash
# Visit crt.sh to monitor certificate issuance
# URL: https://crt.sh/?q=your-domain.com

# Count certificates issued in last 7 days
# Calculate remaining quota: 5 - (certificates in last 7 days)

# If quota is low (1-2 remaining), consider:
# - Using CloudFlare SSL instead
# - Using IP-only deployment for testing
# - Using subdomain rotation for multiple test deployments
```

**See Also:**
- [TESTING_BEST_PRACTICES.md](docs/TESTING_BEST_PRACTICES.md) - Comprehensive testing strategies to avoid rate limits
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/) - Official documentation

---

## Automated Cleanup Script

An automated cleanup script is available at [scripts/cleanup-orphaned-resources.sh](scripts/cleanup-orphaned-resources.sh) that handles the complete cleanup process for orphaned resources.

### Key Features

- **Automatic Configuration**: Reads `bucket_name` and `region` from `lablink-infrastructure/config/config.yaml`
- **Dry-Run Mode**: Test the cleanup process without making changes
- **State Backup**: Automatically backs up Terraform state files before deletion
- **Color-Coded Output**: Visual feedback with green (success), yellow (warnings), and red (errors)
- **Dependency-Aware**: Deletes resources in correct order to avoid dependency conflicts

### Usage

**Dry-run mode** (see what would be deleted without making changes):
```bash
./scripts/cleanup-orphaned-resources.sh <environment> --dry-run
```

**Actual cleanup**:
```bash
./scripts/cleanup-orphaned-resources.sh <environment>
# Example: ./scripts/cleanup-orphaned-resources.sh test
```

**Automatic cleanup** (skip confirmation prompt):
```bash
./scripts/cleanup-orphaned-resources.sh <environment> --yes
```

### When to Use This Script

Use the automated script when:
- Terraform state is out of sync with actual AWS resources
- `terraform destroy` fails with "No changes" but resources still exist
- You need to clean up an environment that was partially deployed
- You want to remove all resources for a specific environment

For complex scenarios or if the script fails, refer to the manual cleanup procedures in the sections above.

### Script Output Example

The script provides detailed progress information:
```
=== LabLink Environment Cleanup ===
Environment: test
Bucket: lablink-terraform-state-bucket
Region: us-west-2

WARNING: This will delete ALL resources for environment 'test'
Continue? (yes/no): yes

Deleting EC2 instances...
  ✓ Terminated 2 client VMs
  ✓ Terminated allocator instance

Waiting for instances to terminate...

Deleting security groups...
  ✓ Deleted client security group
  ✓ Deleted allocator security group
...
```

### Verification After Automated Cleanup

After running the cleanup script, verify all resources are removed using the commands in the [Verification Checklist](#verification-checklist) section below.

---

## Verification Checklist

After manual cleanup, verify all resources are removed:

```bash
ENV="ci-test"
BUCKET="your-bucket-name"

echo "=== Verification for ${ENV} ==="

echo "EC2 Instances:"
aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:Name,Values=*${ENV}*" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' --output table

echo "IAM Roles:"
aws iam list-roles --query "Roles[?contains(RoleName, '${ENV}')].RoleName" --output table

echo "Security Groups:"
aws ec2 describe-security-groups --region us-west-2 \
  --filters "Name=group-name,Values=*${ENV}*" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' --output table

echo "Key Pairs:"
aws ec2 describe-key-pairs --region us-west-2 \
  --filters "Name=key-name,Values=*${ENV}*" --query 'KeyPairs[*].KeyName' --output table

echo "Elastic IPs:"
aws ec2 describe-addresses --region us-west-2 \
  --filters "Name=tag:Name,Values=*${ENV}*" --query 'Addresses[*].[AllocationId,PublicIp]' --output table

echo "CloudWatch Log Groups:"
aws logs describe-log-groups --region us-west-2 --log-group-name-prefix lablink \
  --query "logGroups[?contains(logGroupName, '${ENV}')].logGroupName" --output table

echo "S3 State Files:"
aws s3 ls s3://${BUCKET}/${ENV}/ --recursive

echo "DynamoDB Locks:"
aws dynamodb scan --table-name lock-table --region us-west-2 \
  --filter-expression "contains(LockID, :env)" \
  --expression-attribute-values "{\":env\": {\"S\": \"${ENV}\"}}" \
  --query 'Items[*].LockID.S' --output table

echo ""
echo "If all outputs are empty, cleanup is complete!"
```

---

## Troubleshooting the Cleanup Script

### Common Issues and Solutions

#### 1. Security Group Deletion Fails

**Error**: `An error occurred (DependencyViolation) when calling the DeleteSecurityGroup operation`

**Cause**: Security group still has dependencies (instances, network interfaces, or other security group references)

**Solution**:
```bash
# Check what's using the security group
ENV="test"
SG_ID="sg-xxxxx"  # Replace with actual security group ID

# List network interfaces
aws ec2 describe-network-interfaces --region us-west-2 \
  --filters "Name=group-id,Values=${SG_ID}" \
  --query 'NetworkInterfaces[*].[NetworkInterfaceId,Status,Attachment.InstanceId]' \
  --output table

# If instances are still terminating, wait and retry
sleep 30
aws ec2 delete-security-group --region us-west-2 --group-id ${SG_ID}
```

#### 2. IAM Role Deletion Fails

**Error**: `An error occurred (DeleteConflict) when calling the DeleteRole operation`

**Cause**: Role still has attached policies or is in an instance profile

**Solution**:
```bash
ENV="test"
ROLE_NAME="lablink_instance_role_${ENV}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# List and detach all attached policies
aws iam list-attached-role-policies --role-name ${ROLE_NAME} \
  --query 'AttachedPolicies[*].PolicyArn' --output text | \
  xargs -I {} aws iam detach-role-policy --role-name ${ROLE_NAME} --policy-arn {}

# List and remove from instance profiles
aws iam list-instance-profiles-for-role --role-name ${ROLE_NAME} \
  --query 'InstanceProfiles[*].InstanceProfileName' --output text | \
  xargs -I {} aws iam remove-role-from-instance-profile --instance-profile-name {} --role-name ${ROLE_NAME}

# Now delete the role
aws iam delete-role --role-name ${ROLE_NAME}
```

#### 3. Allocator Instance Not Found

**Error**: Script reports "No allocator instance found" but instance still exists

**Cause**: Instance tag name doesn't match expected format

**Solution**:
```bash
# Find the instance manually
ENV="test"
aws ec2 describe-instances --region us-west-2 \
  --filters "Name=tag:Name,Values=*allocator*${ENV}*" \
  --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name]' \
  --output table

# Terminate manually
INSTANCE_ID="i-xxxxx"  # Replace with actual ID
aws ec2 terminate-instances --region us-west-2 --instance-ids ${INSTANCE_ID}
```

#### 4. S3 State File Access Denied

**Error**: `An error occurred (AccessDenied) when calling the DeleteObject operation`

**Cause**: AWS credentials lack S3 permissions or bucket versioning is enabled

**Solution**:
```bash
# Check your AWS credentials
aws sts get-caller-identity

# Check bucket versioning
BUCKET="your-bucket-name"
aws s3api get-bucket-versioning --bucket ${BUCKET}

# If versioning is enabled, delete all versions
ENV="test"
aws s3api list-object-versions --bucket ${BUCKET} --prefix ${ENV}/ \
  --query 'Versions[*].[Key,VersionId]' --output text | \
  while read key versionId; do
    aws s3api delete-object --bucket ${BUCKET} --key "$key" --version-id "$versionId"
  done
```

#### 5. DynamoDB Lock Not Deleted

**Error**: Lock entry still exists after cleanup

**Cause**: Lock ID format mismatch or permissions issue

**Solution**:
```bash
ENV="test"
BUCKET="your-bucket-name"

# List all locks to find exact format
aws dynamodb scan --table-name lock-table --region us-west-2 \
  --query 'Items[*].LockID.S' --output table

# Delete with exact lock ID
LOCK_ID="${BUCKET}/${ENV}/terraform.tfstate-md5"
aws dynamodb delete-item --table-name lock-table --region us-west-2 \
  --key "{\"LockID\": {\"S\": \"${LOCK_ID}\"}}"
```

#### 6. Script Cannot Read config.yaml

**Error**: `Failed to read bucket_name or region from config.yaml`

**Cause**: config.yaml doesn't exist or has incorrect format

**Solution**:
```bash
# Check if config.yaml exists
ls -la lablink-infrastructure/config/config.yaml

# Verify format
grep "bucket_name:" lablink-infrastructure/config/config.yaml
grep "region:" lablink-infrastructure/config/config.yaml

# Manually specify values
BUCKET="your-bucket-name"
REGION="us-west-2"
# Edit the script to use these values or pass them as arguments
```

### Verification Commands Reference

Quick verification commands to check cleanup status:

```bash
ENV="test"
BUCKET="your-bucket-name"
REGION="us-west-2"

# Check all EC2 resources
aws ec2 describe-instances --region ${REGION} --filters "Name=tag:Name,Values=*${ENV}*" --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table

# Check all IAM resources
aws iam list-roles --query "Roles[?contains(RoleName, '${ENV}')].RoleName" --output table
aws iam list-policies --scope Local --query "Policies[?contains(PolicyName, '${ENV}')].PolicyName" --output table

# Check Lambda functions
aws lambda list-functions --region ${REGION} --query "Functions[?contains(FunctionName, '${ENV}')].FunctionName" --output table

# Check CloudWatch log groups
aws logs describe-log-groups --region ${REGION} --query "logGroups[?contains(logGroupName, '${ENV}')].logGroupName" --output table

# Check S3 and DynamoDB
aws s3 ls s3://${BUCKET}/${ENV}/ 2>/dev/null || echo "No S3 state files found"
aws dynamodb scan --table-name lock-table --region ${REGION} --filter-expression "contains(LockID, :env)" --expression-attribute-values "{\":env\": {\"S\": \"${ENV}\"}}" --query 'Items[*].LockID.S' --output table
```

### Running Cleanup in Stages

If the full cleanup fails, run it in stages:

```bash
ENV="test"

# Stage 1: Terminate instances only
./scripts/cleanup-orphaned-resources.sh ${ENV} --dry-run
# Manually verify and wait for termination (use AWS console)

# Stage 2: Delete security groups and network resources
# After instances are terminated, security groups can be deleted

# Stage 3: Delete IAM resources
# No dependencies on EC2 resources

# Stage 4: Delete Lambda and logs
# Independent of other resources

# Stage 5: Clean state files
# Only after confirming all resources are gone
```

---

## Getting Help

If you encounter issues not covered in this guide:

1. Check the [README.md](README.md) for general troubleshooting
2. Review the [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md) for deployment verification steps
3. Check AWS CloudWatch logs for error messages
4. Open an issue in the GitHub repository with:
   - The error message
   - What resources remain (from verification commands)
   - Your environment name and configuration

---

## Best Practices

1. **Always backup state files** before deleting them
2. **Verify before deleting** - use list commands first
3. **Delete in order** - follow the dependency chain (policies → profiles → roles)
4. **Use scripts** for repeatable cleanup
5. **Document deviations** - if you modify procedures, update this guide
6. **Test in ci-test first** - verify cleanup procedures work before using in prod
