#!/bin/bash
# LabLink One-Time Setup Script
# Handles: Prerequisites, OIDC, IAM, S3, DynamoDB, Route53, GitHub Secrets
# Then calls configure.sh to generate config.yaml
#
# Usage: ./scripts/setup.sh
# Must be run from the repository root directory.
#
# For updating configuration later (instance types, image tags, etc.),
# run ./scripts/configure.sh directly — no need to re-run this script.

set -euo pipefail

# ============================================================================
# Colors and formatting
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}i${NC}  $*"; }
success() { echo -e "${GREEN}OK${NC} $*"; }
warn()    { echo -e "${YELLOW}!!${NC}  $*"; }
error()   { echo -e "${RED}ERR${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}$*${NC}"; echo -e "${CYAN}$(printf '=%.0s' $(seq 1 ${#1}))${NC}"; }
prompt()  { echo -en "${BOLD}$*${NC}"; }

# ============================================================================
# Phase 1: Prerequisites Check
# ============================================================================
header "LabLink One-Time Setup"
echo ""
echo "This script sets up AWS infrastructure and GitHub secrets (run once)."
echo "  - AWS resources (OIDC, IAM role, S3, DynamoDB, Route53)"
echo "  - GitHub Actions secrets"
echo "  - Calls configure.sh to generate config.yaml"
echo ""
echo "To update configuration later, run: ./scripts/configure.sh"
echo ""

header "Phase 1: Prerequisites Check"

# Check: running from repo root
if [ ! -d "lablink-infrastructure" ]; then
    error "Must be run from the repository root (lablink-infrastructure/ directory not found)."
    echo "  cd /path/to/your/lablink-template && ./scripts/setup.sh"
    exit 1
fi
success "Running from repository root"

# Check: AWS CLI installed
if ! command -v aws &> /dev/null; then
    error "AWS CLI is not installed."
    echo "  Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi
success "AWS CLI installed ($(aws --version 2>&1 | head -1))"

# Check: AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    error "AWS credentials are not configured."
    echo "  Run: aws configure"
    echo "  Docs: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html"
    exit 1
fi
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
AWS_CALLER_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
success "AWS authenticated (Account: ${AWS_ACCOUNT_ID}, Identity: ${AWS_CALLER_ARN})"

# Check: GitHub CLI installed
if ! command -v gh &> /dev/null; then
    error "GitHub CLI (gh) is not installed."
    echo "  Install: https://cli.github.com/"
    exit 1
fi
success "GitHub CLI installed ($(gh --version | head -1))"

# Check: GitHub CLI authenticated
if ! gh auth status &> /dev/null 2>&1; then
    error "GitHub CLI is not authenticated."
    echo "  Run: gh auth login"
    exit 1
fi
success "GitHub CLI authenticated"

# Check: openssl for password generation
if ! command -v openssl &> /dev/null; then
    warn "openssl not found — password auto-generation will use /dev/urandom fallback"
fi

# Check: configure.sh exists
if [ ! -f "scripts/configure.sh" ]; then
    error "scripts/configure.sh not found. This file is required."
    exit 1
fi

# Auto-detect values
AUTO_REGION=$(aws configure get region 2>/dev/null || echo "")
GITHUB_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")

if [ -n "$GITHUB_REPO" ]; then
    success "GitHub repo detected: ${GITHUB_REPO}"
else
    warn "Could not auto-detect GitHub repo. You'll be asked to enter it."
fi

if [ -n "$AUTO_REGION" ]; then
    success "AWS region detected: ${AUTO_REGION}"
fi

echo ""
success "All prerequisites passed!"

# ============================================================================
# Helper: prompt with default
# ============================================================================
ask() {
    local var_name="$1"
    local prompt_text="$2"
    local default="$3"
    local value

    if [ -n "$default" ]; then
        prompt "${prompt_text} [${default}]: "
    else
        prompt "${prompt_text}: "
    fi
    read -r value
    value="${value:-$default}"
    eval "$var_name=\"$value\""
}

ask_yes_no() {
    local var_name="$1"
    local prompt_text="$2"
    local default="$3"
    local value

    prompt "${prompt_text} [${default}]: "
    read -r value
    value="${value:-$default}"
    # Normalize to lowercase
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
    if [[ "$value" == "y" || "$value" == "yes" ]]; then
        eval "$var_name=true"
    else
        eval "$var_name=false"
    fi
}

generate_password() {
    if command -v openssl &> /dev/null; then
        openssl rand -base64 16 | tr -d '/+=' | head -c 20
    else
        LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
    fi
}

# ============================================================================
# Phase 2: Infrastructure Configuration
# ============================================================================
header "Phase 2: Infrastructure Configuration"
echo ""
echo "Answer the following prompts to configure AWS infrastructure."
echo "Press Enter to accept the default value shown in brackets."
echo ""

# --- AWS Region ---
echo -e "${BOLD}--- AWS Region ---${NC}"
ask CFG_REGION "AWS Region" "${AUTO_REGION:-us-west-2}"

# Validate region
if ! aws ec2 describe-regions --region-names "$CFG_REGION" &> /dev/null 2>&1; then
    error "Invalid AWS region: ${CFG_REGION}"
    exit 1
fi

# --- S3 Bucket ---
echo ""
echo -e "${BOLD}--- S3 Bucket ---${NC}"

# Derive a default org name from the GitHub repo
DEFAULT_ORG=""
if [ -n "$GITHUB_REPO" ]; then
    DEFAULT_ORG=$(echo "$GITHUB_REPO" | cut -d'/' -f1 | tr '[:upper:]' '[:lower:]')
fi

# Check for existing S3 buckets that look like terraform state buckets
info "Checking for existing S3 buckets..."
EXISTING_BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null \
    | tr '\t' '\n' | grep -iE 'tf-state|terraform|lablink' | sort || echo "")

if [ -n "$EXISTING_BUCKETS" ]; then
    echo ""
    echo -e "  ${BOLD}Existing buckets that may be terraform state buckets:${NC}"
    BUCKET_INDEX=0
    declare -a BUCKET_ARRAY=()
    while IFS= read -r bucket; do
        BUCKET_INDEX=$((BUCKET_INDEX + 1))
        BUCKET_ARRAY+=("$bucket")
        echo "    ${BUCKET_INDEX}) ${bucket}"
    done <<< "$EXISTING_BUCKETS"
    echo "    N) Create a new bucket"
    echo ""

    prompt "Select a bucket number or 'N' to create new [N]: "
    read -r BUCKET_CHOICE
    BUCKET_CHOICE="${BUCKET_CHOICE:-N}"

    if [[ "$BUCKET_CHOICE" =~ ^[0-9]+$ ]] && [ "$BUCKET_CHOICE" -ge 1 ] && [ "$BUCKET_CHOICE" -le "$BUCKET_INDEX" ]; then
        CFG_BUCKET="${BUCKET_ARRAY[$((BUCKET_CHOICE - 1))]}"
        success "Using existing bucket: ${CFG_BUCKET}"
    else
        ask CFG_BUCKET "New S3 bucket name (must be globally unique)" "tf-state-${DEFAULT_ORG:-myorg}-lablink"
    fi
else
    info "No existing terraform state buckets found"
    ask CFG_BUCKET "S3 bucket name (must be globally unique)" "tf-state-${DEFAULT_ORG:-myorg}-lablink"
fi

# Validate bucket: check ownership if it already exists
if aws s3api head-bucket --bucket "$CFG_BUCKET" 2>/dev/null; then
    info "Bucket '${CFG_BUCKET}' already exists (will reuse)"
elif aws s3api head-bucket --bucket "$CFG_BUCKET" 2>&1 | grep -q "403"; then
    error "Bucket '${CFG_BUCKET}' exists but is owned by another AWS account. Choose a different name."
    exit 1
fi

# --- GitHub Repo ---
echo ""
echo -e "${BOLD}--- GitHub Repository ---${NC}"

if [ -z "$GITHUB_REPO" ]; then
    ask GITHUB_REPO "GitHub repository (org/repo)" ""
    if [ -z "$GITHUB_REPO" ]; then
        error "GitHub repository is required."
        exit 1
    fi
fi

# --- DNS (basic — just enough for Route53 zone + IAM policy) ---
echo ""
echo -e "${BOLD}--- DNS Settings ---${NC}"

ask_yes_no CFG_DNS_ENABLED "Enable custom domain? (y/N)" "N"

CFG_DOMAIN=""
CFG_DNS_PROVIDER="route53"

if [ "$CFG_DNS_ENABLED" = "true" ]; then
    ask CFG_DOMAIN "Domain name (e.g., lablink.example.com)" ""
    if [ -z "$CFG_DOMAIN" ]; then
        error "Domain name is required when DNS is enabled."
        exit 1
    fi

    echo ""
    echo "  DNS Provider options:"
    echo "    1) route53   - AWS Route53 (this script will create hosted zone)"
    echo "    2) cloudflare - CloudFlare (you manage DNS in CloudFlare)"
    ask CFG_DNS_PROVIDER "DNS provider" "route53"
fi

# --- Passwords ---
echo ""
echo -e "${BOLD}--- Passwords ---${NC}"

AUTO_ADMIN_PW=$(generate_password)
AUTO_DB_PW=$(generate_password)

echo "  Auto-generated passwords are available. Press Enter to use them,"
echo "  or type a custom password."
ask CFG_ADMIN_PASSWORD "Admin password" "$AUTO_ADMIN_PW"
ask CFG_DB_PASSWORD "Database password" "$AUTO_DB_PW"

# ============================================================================
# Phase 3: Summary + Confirm
# ============================================================================
header "Phase 3: Review Configuration"
echo ""
printf "  %-25s %s\n" "AWS Account:" "$AWS_ACCOUNT_ID"
printf "  %-25s %s\n" "AWS Region:" "$CFG_REGION"
printf "  %-25s %s\n" "GitHub Repo:" "$GITHUB_REPO"
printf "  %-25s %s\n" "S3 Bucket:" "$CFG_BUCKET"

if [ "$CFG_DNS_ENABLED" = "true" ]; then
    printf "  %-25s %s\n" "DNS:" "Enabled"
    printf "  %-25s %s\n" "Domain:" "$CFG_DOMAIN"
    printf "  %-25s %s\n" "DNS Provider:" "$CFG_DNS_PROVIDER"
else
    printf "  %-25s %s\n" "DNS:" "Disabled (IP-only)"
fi
echo ""

echo -e "${BOLD}Resources that will be created/configured:${NC}"
echo "  1. AWS OIDC Provider (for GitHub Actions)"
echo "  2. IAM Role: github-actions-lablink (with managed policies)"
echo "  3. S3 Bucket: ${CFG_BUCKET}"
echo "  4. DynamoDB Table: lock-table"
if [ "$CFG_DNS_ENABLED" = "true" ] && [ "$CFG_DNS_PROVIDER" = "route53" ]; then
    echo "  5. Route53 Hosted Zone for $(echo "$CFG_DOMAIN" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')"
fi
echo "  6. GitHub Secrets (AWS_ROLE_ARN, AWS_REGION, ADMIN_PASSWORD, DB_PASSWORD)"
echo "  7. Config file via configure.sh"
echo ""

prompt "Proceed with setup? [y/N]: "
read -r CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# ============================================================================
# Phase 4: Automated AWS + GitHub Setup
# ============================================================================
header "Phase 4: Creating Resources"

ROLE_NAME="github-actions-lablink"
OIDC_URL="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL}"

# Track what we've done for error reporting
COMPLETED_STEPS=()

# --- Step 1: OIDC Provider ---
echo ""
info "Step 1/6: OIDC Provider"

OIDC_EXISTS=false
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &> /dev/null 2>&1; then
    OIDC_EXISTS=true
fi

if [ "$OIDC_EXISTS" = "true" ]; then
    success "OIDC provider already exists: ${OIDC_PROVIDER_ARN}"
else
    info "Creating OIDC provider for GitHub Actions..."
    # Get the GitHub OIDC thumbprint
    THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

    aws iam create-open-id-connect-provider \
        --url "https://${OIDC_URL}" \
        --client-id-list "sts.amazonaws.com" \
        --thumbprint-list "$THUMBPRINT" \
        --output text > /dev/null
    success "Created OIDC provider"
fi
COMPLETED_STEPS+=("OIDC Provider")

# --- Step 2: IAM Role ---
echo ""
info "Step 2/6: IAM Role"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null 2>&1; then
    success "IAM role already exists: ${ROLE_NAME}"
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
else
    info "Creating IAM role: ${ROLE_NAME}..."

    TRUST_POLICY=$(cat <<TRUSTEOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "${OIDC_PROVIDER_ARN}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringLike": {
                    "${OIDC_URL}:sub": "repo:${GITHUB_REPO}:*"
                },
                "StringEquals": {
                    "${OIDC_URL}:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
TRUSTEOF
)

    ROLE_ARN=$(aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --description "GitHub Actions role for LabLink deployment (${GITHUB_REPO})" \
        --query 'Role.Arn' \
        --output text)
    success "Created IAM role: ${ROLE_ARN}"
fi

# Always ensure managed policies are attached (handles re-runs and partial setups)
info "Ensuring managed policies are attached..."
POLICIES=(
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
    "arn:aws:iam::aws:policy/AmazonS3FullAccess"
    "arn:aws:iam::aws:policy/IAMFullAccess"
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
    "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
    "arn:aws:iam::aws:policy/AWSCloudTrail_FullAccess"
    "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
    "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
)

# Attach Route53 if DNS is enabled with Route53
if [ "$CFG_DNS_ENABLED" = "true" ] && [ "$CFG_DNS_PROVIDER" = "route53" ]; then
    POLICIES+=("arn:aws:iam::aws:policy/AmazonRoute53FullAccess")
fi

for POLICY_ARN in "${POLICIES[@]}"; do
    POLICY_SHORT=$(echo "$POLICY_ARN" | awk -F'/' '{print $NF}')
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY_ARN" 2>/dev/null || true
    success "  Attached: ${POLICY_SHORT}"
done
COMPLETED_STEPS+=("IAM Role")

# --- Step 3: S3 Bucket ---
echo ""
info "Step 3/6: S3 Bucket"

if aws s3api head-bucket --bucket "$CFG_BUCKET" 2>/dev/null; then
    success "S3 bucket already exists: ${CFG_BUCKET}"
else
    info "Creating S3 bucket: ${CFG_BUCKET}..."
    # us-east-1 doesn't support LocationConstraint
    if [ "$CFG_REGION" = "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$CFG_BUCKET" \
            --region "$CFG_REGION" > /dev/null
    else
        aws s3api create-bucket \
            --bucket "$CFG_BUCKET" \
            --region "$CFG_REGION" \
            --create-bucket-configuration LocationConstraint="$CFG_REGION" > /dev/null
    fi

    aws s3api put-bucket-versioning \
        --bucket "$CFG_BUCKET" \
        --versioning-configuration Status=Enabled \
        --region "$CFG_REGION"
    success "Created S3 bucket with versioning: ${CFG_BUCKET}"
fi
COMPLETED_STEPS+=("S3 Bucket")

# --- Step 4: DynamoDB Table ---
echo ""
info "Step 4/6: DynamoDB Table"

if aws dynamodb describe-table --table-name lock-table --region "$CFG_REGION" &> /dev/null 2>&1; then
    success "DynamoDB table already exists: lock-table"
else
    info "Creating DynamoDB table: lock-table..."
    aws dynamodb create-table \
        --table-name lock-table \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "$CFG_REGION" > /dev/null
    success "Created DynamoDB table: lock-table"
fi
COMPLETED_STEPS+=("DynamoDB Table")

# --- Step 5: Route53 Hosted Zone ---
echo ""
info "Step 5/6: Route53 Hosted Zone"

CFG_ZONE_ID=""

if [ "$CFG_DNS_ENABLED" = "true" ] && [ "$CFG_DNS_PROVIDER" = "route53" ]; then
    # Extract root domain (e.g., example.com from test.example.com)
    ZONE_NAME=$(echo "$CFG_DOMAIN" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')

    EXISTING_ZONES=$(aws route53 list-hosted-zones-by-name \
        --dns-name "$ZONE_NAME" \
        --query "HostedZones[?Name=='${ZONE_NAME}.'].Id" \
        --output text 2>/dev/null || echo "")

    ZONE_COUNT=$(echo "$EXISTING_ZONES" | wc -w | tr -d ' ')

    if [ "$ZONE_COUNT" -eq 0 ] || [ -z "$EXISTING_ZONES" ]; then
        info "Creating Route53 hosted zone: ${ZONE_NAME}..."
        ZONE_OUTPUT=$(aws route53 create-hosted-zone \
            --name "$ZONE_NAME" \
            --caller-reference "lablink-setup-$(date +%s)" \
            --query 'HostedZone.Id' \
            --output text)
        CFG_ZONE_ID="${ZONE_OUTPUT//\/hostedzone\//}"
        success "Created hosted zone: ${ZONE_NAME} (ID: ${CFG_ZONE_ID})"

        NS_RECORDS=$(aws route53 get-hosted-zone --id "$CFG_ZONE_ID" \
            --query 'DelegationSet.NameServers' \
            --output text)

        echo ""
        warn "IMPORTANT: Update your domain registrar with these nameservers:"
        echo "$NS_RECORDS" | tr '\t' '\n' | sed 's/^/    /'
        echo ""
    elif [ "$ZONE_COUNT" -eq 1 ]; then
        CFG_ZONE_ID=$(echo "$EXISTING_ZONES" | awk '{print $1}' | sed 's|/hostedzone/||')
        success "Found existing hosted zone: ${ZONE_NAME} (ID: ${CFG_ZONE_ID})"
    else
        error "Multiple hosted zones found for ${ZONE_NAME}."
        echo "  Please resolve this manually (delete duplicates or pick one)."
        echo "  Then re-run this script."
        echo ""
        echo "  Completed steps so far: ${COMPLETED_STEPS[*]}"
        exit 1
    fi
else
    info "DNS not using Route53 — skipping hosted zone creation"
fi
COMPLETED_STEPS+=("Route53")

# --- Step 6: GitHub Secrets ---
echo ""
info "Step 6/6: GitHub Secrets"

info "Setting AWS_ROLE_ARN..."
echo "$ROLE_ARN" | gh secret set AWS_ROLE_ARN --repo "$GITHUB_REPO"
success "Set AWS_ROLE_ARN"

info "Setting AWS_REGION..."
echo "$CFG_REGION" | gh secret set AWS_REGION --repo "$GITHUB_REPO"
success "Set AWS_REGION"

info "Setting ADMIN_PASSWORD..."
echo "$CFG_ADMIN_PASSWORD" | gh secret set ADMIN_PASSWORD --repo "$GITHUB_REPO"
success "Set ADMIN_PASSWORD"

info "Setting DB_PASSWORD..."
echo "$CFG_DB_PASSWORD" | gh secret set DB_PASSWORD --repo "$GITHUB_REPO"
success "Set DB_PASSWORD"

COMPLETED_STEPS+=("GitHub Secrets")

# ============================================================================
# Phase 5: Verification
# ============================================================================
header "Phase 5: Verification"

VERIFY_PASS=true

# Verify S3 bucket
if aws s3api head-bucket --bucket "$CFG_BUCKET" 2>/dev/null; then
    success "S3 bucket exists: ${CFG_BUCKET}"
else
    error "S3 bucket NOT found: ${CFG_BUCKET}"
    VERIFY_PASS=false
fi

# Verify DynamoDB table
if aws dynamodb describe-table --table-name lock-table --region "$CFG_REGION" &> /dev/null 2>&1; then
    success "DynamoDB table exists: lock-table"
else
    error "DynamoDB table NOT found: lock-table"
    VERIFY_PASS=false
fi

# Verify IAM role
if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null 2>&1; then
    success "IAM role exists: ${ROLE_NAME}"
else
    error "IAM role NOT found: ${ROLE_NAME}"
    VERIFY_PASS=false
fi

# Verify OIDC provider
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" &> /dev/null 2>&1; then
    success "OIDC provider exists"
else
    error "OIDC provider NOT found"
    VERIFY_PASS=false
fi

# Verify GitHub secrets
SECRET_LIST=$(gh secret list --repo "$GITHUB_REPO" 2>/dev/null || echo "")
for SECRET_NAME in AWS_ROLE_ARN AWS_REGION ADMIN_PASSWORD DB_PASSWORD; do
    if echo "$SECRET_LIST" | grep -q "$SECRET_NAME"; then
        success "GitHub secret set: ${SECRET_NAME}"
    else
        error "GitHub secret NOT found: ${SECRET_NAME}"
        VERIFY_PASS=false
    fi
done

echo ""
if [ "$VERIFY_PASS" = "true" ]; then
    success "All verifications passed!"
else
    warn "Some verifications failed. Review the errors above."
fi

# ============================================================================
# Phase 6: Passwords & Config Generation
# ============================================================================
header "Infrastructure Setup Complete!"
echo ""
echo -e "${BOLD}Passwords (save these now — they won't be shown again):${NC}"
echo -e "  Admin password: ${YELLOW}${CFG_ADMIN_PASSWORD}${NC}"
echo -e "  DB password:    ${YELLOW}${CFG_DB_PASSWORD}${NC}"
echo ""

# ============================================================================
# Phase 7: Call configure.sh with env var bridge
# ============================================================================
header "Phase 7: Generating config.yaml"
echo ""
info "Calling configure.sh to generate config.yaml..."
echo "  (You can re-run ./scripts/configure.sh later to update config.)"
echo ""

# Export values so configure.sh can use them as defaults
export LABLINK_REGION="$CFG_REGION"
export LABLINK_BUCKET="$CFG_BUCKET"
export LABLINK_DNS_ENABLED="$CFG_DNS_ENABLED"
if [ "$CFG_DNS_ENABLED" = "true" ]; then
    export LABLINK_DOMAIN="$CFG_DOMAIN"
    export LABLINK_DNS_PROVIDER="$CFG_DNS_PROVIDER"
    if [ -n "$CFG_ZONE_ID" ]; then
        export LABLINK_ZONE_ID="$CFG_ZONE_ID"
    fi
fi

bash scripts/configure.sh

echo ""
header "All Done!"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "  1. Review the generated config:"
echo "     lablink-infrastructure/config/config.yaml"
echo ""
echo "  2. Deploy via GitHub Actions:"
echo "     Go to Actions -> 'Deploy LabLink Infrastructure' -> Run workflow"
echo "     Select your environment (test or prod)"
echo ""

if [ "$CFG_DNS_ENABLED" = "true" ] && [ "$CFG_DNS_PROVIDER" = "route53" ]; then
    echo "  3. (DNS) Update your domain registrar's nameservers to point to Route53"
    echo "     Then wait for DNS propagation (usually minutes, up to 48 hours)"
    echo ""
fi

echo "  To update configuration later (instance type, image tags, etc.):"
echo "     ./scripts/configure.sh"
echo ""
echo "  For help: see README.md or https://talmolab.github.io/lablink/"
echo ""
