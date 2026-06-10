#!/bin/bash
# LabLink Configuration Wizard
# Generates lablink-infrastructure/config/config.yaml interactively.
#
# Usage: ./scripts/configure.sh
# Must be run from the repository root directory.
#
# This script can be run as many times as needed to update configuration.
# If config.yaml already exists, current values are used as defaults.
#
# Environment variable overrides (set by setup.sh):
#   LABLINK_REGION        - AWS region
#   LABLINK_BUCKET        - S3 bucket name
#   LABLINK_DNS_ENABLED   - DNS enabled (true/false)
#   LABLINK_DOMAIN        - Domain name
#   LABLINK_DNS_PROVIDER  - DNS provider (route53/cloudflare)
#   LABLINK_ZONE_ID       - Route53 zone ID

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
# Prerequisites
# ============================================================================
if [ ! -d "lablink-infrastructure" ]; then
    error "Must be run from the repository root (lablink-infrastructure/ directory not found)."
    echo "  cd /path/to/your/lablink-template && ./scripts/configure.sh"
    exit 1
fi

CONFIG_FILE="lablink-infrastructure/config/config.yaml"

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

# ============================================================================
# Read existing config.yaml for defaults
# ============================================================================
# Helper to read a value from existing config.yaml
# Usage: cfg_get "key.subkey" "fallback"
cfg_get() {
    local key="$1"
    local fallback="${2:-}"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$fallback"
        return
    fi

    local value=""
    case "$key" in
        # Top-level keys
        bucket_name)
            value=$(grep -E '^bucket_name:' "$CONFIG_FILE" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
            ;;
        # Nested keys — use the last match for the specific subkey
        app.region)
            value=$(awk '/^app:/{found=1} found && /region:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        dns.enabled)
            value=$(awk '/^dns:/{found=1} found && /enabled:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        dns.terraform_managed)
            value=$(awk '/^dns:/{found=1} found && /terraform_managed:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        dns.domain)
            value=$(awk '/^dns:/{found=1} found && /domain:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        dns.zone_id)
            value=$(awk '/^dns:/{found=1} found && /zone_id:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        machine.machine_type)
            value=$(awk '/^machine:/{found=1} found && /machine_type:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        machine.ami_id)
            value=$(awk '/^machine:/{found=1} found && /ami_id:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        machine.repository)
            value=$(awk '/^machine:/{found=1} found && /repository:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        machine.software)
            value=$(awk '/^machine:/{found=1} found && /software:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        machine.extension)
            value=$(awk '/^machine:/{found=1} found && /extension:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        machine.image)
            value=$(awk '/^machine:/{found=1} found && /image:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        allocator.image_tag)
            value=$(awk '/^allocator:/{found=1} found && /image_tag:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        eip.strategy)
            value=$(awk '/^eip:/{found=1} found && /strategy:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        ssl.provider)
            value=$(awk '/^ssl:/{found=1} found && /provider:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        ssl.email)
            value=$(awk '/^ssl:/{found=1} found && /email:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        startup_script.enabled)
            value=$(awk '/^startup_script:/{found=1} found && /enabled:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        startup_script.path)
            value=$(awk '/^startup_script:/{found=1} found && /path:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        startup_script.on_error)
            value=$(awk '/^startup_script:/{found=1} found && /on_error:/{print $2; exit}' "$CONFIG_FILE" 2>/dev/null | tr -d '"' || true)
            ;;
        *)
            value=""
            ;;
    esac

    # Strip inline comments (e.g., "value # comment" -> "value")
    value=$(echo "$value" | sed 's/ *#.*//' | xargs 2>/dev/null || true)

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$fallback"
    fi
}

# ============================================================================
# Determine defaults: env vars > existing config > hardcoded
# ============================================================================

# Region and bucket are fixed — read from existing config or env vars.
# They cannot be changed here because they are tied to the Terraform backend.
EXISTING_REGION="${LABLINK_REGION:-$(cfg_get app.region "")}"
EXISTING_BUCKET="${LABLINK_BUCKET:-$(cfg_get bucket_name "")}"

if [ -z "$EXISTING_REGION" ] || [ -z "$EXISTING_BUCKET" ]; then
    error "Region and S3 bucket name are required but not found."
    echo ""
    echo "  These values are set during initial setup and cannot be changed"
    echo "  (they are tied to the Terraform backend)."
    echo ""
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "  No existing config.yaml found. Run setup.sh first:"
        echo "    ./scripts/setup.sh"
    else
        echo "  Your config.yaml is missing region or bucket_name."
        echo "  Please fix it manually or re-run setup.sh."
    fi
    exit 1
fi

# ============================================================================
# Interactive Configuration Wizard
# ============================================================================
header "LabLink Configuration Wizard"
echo ""

if [ -f "$CONFIG_FILE" ]; then
    info "Found existing config.yaml — current values will be used as defaults."
else
    info "No existing config.yaml — using sensible defaults."
fi

echo ""
echo "Press Enter to accept the default value shown in brackets."
echo ""

# Show fixed values
echo -e "${BOLD}--- Fixed Values (from setup) ---${NC}"
echo "  Region:     ${EXISTING_REGION}"
echo "  S3 Bucket:  ${EXISTING_BUCKET}"
echo ""

# --- DNS & SSL ---
echo -e "${BOLD}--- DNS & SSL Settings ---${NC}"

# DNS enabled
DEFAULT_DNS_ENABLED="${LABLINK_DNS_ENABLED:-$(cfg_get dns.enabled "false")}"
if [ "$DEFAULT_DNS_ENABLED" = "true" ]; then
    DNS_YN_DEFAULT="y"
else
    DNS_YN_DEFAULT="N"
fi
ask_yes_no CFG_DNS_ENABLED "Enable custom domain? (y/N)" "$DNS_YN_DEFAULT"

CFG_DOMAIN=""
CFG_DNS_PROVIDER="route53"
CFG_TERRAFORM_MANAGED="false"
CFG_SSL_PROVIDER="none"
CFG_SSL_EMAIL=""
CFG_ZONE_ID=""

if [ "$CFG_DNS_ENABLED" = "true" ]; then
    DEFAULT_DOMAIN="${LABLINK_DOMAIN:-$(cfg_get dns.domain "")}"
    ask CFG_DOMAIN "Domain name (e.g., lablink.example.com)" "$DEFAULT_DOMAIN"
    if [ -z "$CFG_DOMAIN" ]; then
        error "Domain name is required when DNS is enabled."
        exit 1
    fi

    echo ""
    echo "  DNS Provider options:"
    echo "    1) route53   - AWS Route53"
    echo "    2) cloudflare - CloudFlare"
    # Config doesn't store dns_provider explicitly; use env var or default to route53
    DEFAULT_DNS_PROVIDER="${LABLINK_DNS_PROVIDER:-route53}"
    ask CFG_DNS_PROVIDER "DNS provider" "$DEFAULT_DNS_PROVIDER"

    if [ "$CFG_DNS_PROVIDER" = "route53" ]; then
        DEFAULT_TF_MANAGED=$(cfg_get dns.terraform_managed "true")
        if [ "$DEFAULT_TF_MANAGED" = "true" ]; then
            TF_YN="y"
        else
            TF_YN="N"
        fi
        ask_yes_no CFG_TERRAFORM_MANAGED "Let Terraform manage DNS records? (y/N)" "$TF_YN"
    fi

    # Zone ID (from env var or existing config)
    CFG_ZONE_ID="${LABLINK_ZONE_ID:-$(cfg_get dns.zone_id "")}"

    echo ""
    echo "  SSL Provider options:"
    echo "    1) letsencrypt - Automatic SSL via Caddy (rate limits apply: 5 certs/domain/week)"
    echo "    2) cloudflare  - SSL via CloudFlare proxy"
    echo "    3) acm         - AWS Certificate Manager"
    echo "    4) none        - HTTP only (no SSL)"
    DEFAULT_SSL_PROVIDER=$(cfg_get ssl.provider "letsencrypt")
    ask CFG_SSL_PROVIDER "SSL provider" "$DEFAULT_SSL_PROVIDER"

    if [ "$CFG_SSL_PROVIDER" = "letsencrypt" ]; then
        warn "Let's Encrypt rate limit: 5 certificates per exact domain per 7 days."
        warn "If you redeploy frequently, consider 'cloudflare' or 'none' for testing."
        DEFAULT_SSL_EMAIL=$(cfg_get ssl.email "")
        ask CFG_SSL_EMAIL "Email for Let's Encrypt notifications" "$DEFAULT_SSL_EMAIL"
    fi
fi

# --- EC2 & Machine Settings ---
echo ""
echo -e "${BOLD}--- EC2 & Machine Settings ---${NC}"

echo "  Common GPU instance types:"
echo "    g4dn.xlarge  - NVIDIA T4 (good for ML, ~\$0.53/hr)"
echo "    g5.xlarge    - NVIDIA A10G (better GPU, ~\$1.01/hr)"
echo "    p3.2xlarge   - NVIDIA V100 (powerful, ~\$3.06/hr)"
echo "    t3.large     - CPU only (no GPU, ~\$0.08/hr)"
DEFAULT_INSTANCE_TYPE=$(cfg_get machine.machine_type "g4dn.xlarge")
while true; do
    ask CFG_INSTANCE_TYPE "EC2 instance type" "$DEFAULT_INSTANCE_TYPE"

    # Validate the instance type against AWS API
    if command -v aws &>/dev/null; then
        if aws_output=$(aws ec2 describe-instance-types \
            --instance-types "$CFG_INSTANCE_TYPE" \
            --region "$EXISTING_REGION" 2>&1); then
            success "Instance type '${CFG_INSTANCE_TYPE}' is valid in ${EXISTING_REGION}."
            break
        elif echo "$aws_output" | grep -q "InvalidInstanceType"; then
            warn "Invalid instance type '${CFG_INSTANCE_TYPE}'. Please enter a valid EC2 instance type."
            DEFAULT_INSTANCE_TYPE="$CFG_INSTANCE_TYPE"
            continue
        else
            warn "Could not validate instance type (AWS API error). Proceeding anyway."
            break
        fi
    else
        warn "AWS CLI not found. Skipping instance type validation."
        break
    fi
done

DEFAULT_AMI=$(cfg_get machine.ami_id "")
if [ -z "$DEFAULT_AMI" ] && [ "$EXISTING_REGION" = "us-west-2" ]; then
    DEFAULT_AMI="ami-0601752c11b394251"
fi
while true; do
    ask CFG_AMI_ID "AMI ID (Ubuntu 24.04 with Docker+Nvidia)" "$DEFAULT_AMI"

    # Allow empty — user may set it later
    if [ -z "$CFG_AMI_ID" ]; then
        warn "No AMI ID provided. You will need to set this in config.yaml before deploying."
        break
    fi

    # Validate the AMI exists in the region
    if command -v aws &>/dev/null; then
        if aws_output=$(aws ec2 describe-images \
            --image-ids "$CFG_AMI_ID" \
            --region "$EXISTING_REGION" 2>&1); then
            success "AMI '${CFG_AMI_ID}' found in ${EXISTING_REGION}."
            break
        elif echo "$aws_output" | grep -q "InvalidAMIID"; then
            warn "AMI '${CFG_AMI_ID}' not found in ${EXISTING_REGION}. Please enter a valid AMI ID."
            DEFAULT_AMI="$CFG_AMI_ID"
            continue
        else
            warn "Could not validate AMI (AWS API error). Proceeding anyway."
            break
        fi
    else
        warn "AWS CLI not found. Skipping AMI validation."
        break
    fi
done

DEFAULT_DATA_REPO=$(cfg_get machine.repository "")
ask CFG_DATA_REPO "Data repository URL (optional, press Enter to skip)" "$DEFAULT_DATA_REPO"

DEFAULT_SOFTWARE=$(cfg_get machine.software "sleap")
ask CFG_SOFTWARE "Software name" "$DEFAULT_SOFTWARE"

DEFAULT_EXTENSION=$(cfg_get machine.extension "slp")
ask CFG_EXTENSION "File extension" "$DEFAULT_EXTENSION"

# --- Image Configuration ---
echo ""
echo -e "${BOLD}--- Image Configuration ---${NC}"
echo "  These control which Docker images are used."
echo "  For testing, use tag 'linux-amd64-latest-test'."
echo "  For production, pin to a specific version like 'linux-amd64-v1.2.3'."

DEFAULT_ALLOCATOR_TAG=$(cfg_get allocator.image_tag "linux-amd64-latest-test")
ask CFG_ALLOCATOR_TAG "Allocator image tag" "$DEFAULT_ALLOCATOR_TAG"

echo ""
echo "  Client VM image: full Docker image URL (e.g., ghcr.io/your-org/your-image:tag)."
echo "  Use a custom image or the default LabLink base image."
DEFAULT_CLIENT_IMAGE=$(cfg_get machine.image "ghcr.io/talmolab/lablink-client-base-image:linux-amd64-latest-test")
ask CFG_CLIENT_IMAGE "Client VM image" "$DEFAULT_CLIENT_IMAGE"

# --- EIP Settings ---
echo ""
echo -e "${BOLD}--- EIP Settings ---${NC}"
echo "  persistent - Reuse the same Elastic IP across deployments"
echo "  dynamic    - Create a new Elastic IP each deployment"
DEFAULT_EIP_STRATEGY=$(cfg_get eip.strategy "dynamic")
ask CFG_EIP_STRATEGY "EIP strategy" "$DEFAULT_EIP_STRATEGY"

# --- Startup Script ---
echo ""
echo -e "${BOLD}--- Startup Script ---${NC}"
echo "  Optional script to run on client VMs at startup."

DEFAULT_STARTUP_ENABLED=$(cfg_get startup_script.enabled "false")
if [ "$DEFAULT_STARTUP_ENABLED" = "true" ]; then
    STARTUP_YN="y"
else
    STARTUP_YN="N"
fi
ask_yes_no CFG_STARTUP_ENABLED "Enable startup script? (y/N)" "$STARTUP_YN"

CFG_STARTUP_PATH=""
CFG_STARTUP_ON_ERROR="continue"

if [ "$CFG_STARTUP_ENABLED" = "true" ]; then
    DEFAULT_STARTUP_PATH=$(cfg_get startup_script.path "config/custom-startup.sh")
    ask CFG_STARTUP_PATH "Startup script path" "$DEFAULT_STARTUP_PATH"

    echo "  On-error behavior:"
    echo "    continue - Ignore errors and continue VM setup"
    echo "    fail     - Stop VM setup on error"
    DEFAULT_ON_ERROR=$(cfg_get startup_script.on_error "continue")
    ask CFG_STARTUP_ON_ERROR "On-error behavior" "$DEFAULT_ON_ERROR"
fi

# ============================================================================
# Generate config.yaml
# ============================================================================
header "Generating config.yaml"
echo ""

cat > "$CONFIG_FILE" <<CONFIGEOF
# LabLink Configuration
# Generated by configure.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

db:
  dbname: "lablink_db"
  user: "lablink"
  password: "PLACEHOLDER_DB_PASSWORD"  # Injected from GitHub secret at deploy time
  host: "localhost"
  port: 5432
  table_name: "vms"
  message_channel: "vm_updates"

machine:
  machine_type: "${CFG_INSTANCE_TYPE}"
  image: "${CFG_CLIENT_IMAGE}"
  ami_id: "${CFG_AMI_ID}"
  repository: "${CFG_DATA_REPO}"
  software: "${CFG_SOFTWARE}"
  extension: "${CFG_EXTENSION}"

allocator:
  image_tag: "${CFG_ALLOCATOR_TAG}"

app:
  admin_user: "admin"
  admin_password: "PLACEHOLDER_ADMIN_PASSWORD"  # Injected from GitHub secret at deploy time
  region: "${EXISTING_REGION}"

dns:
  enabled: ${CFG_DNS_ENABLED}
  terraform_managed: ${CFG_TERRAFORM_MANAGED}
  domain: "${CFG_DOMAIN}"
  zone_id: "${CFG_ZONE_ID}"

eip:
  strategy: "${CFG_EIP_STRATEGY}"
  tag_name: "lablink-eip"

ssl:
  provider: "${CFG_SSL_PROVIDER}"
  email: "${CFG_SSL_EMAIL}"
  certificate_arn: ""

startup_script:
  enabled: ${CFG_STARTUP_ENABLED}
  path: "${CFG_STARTUP_PATH}"
  on_error: "${CFG_STARTUP_ON_ERROR}"

bucket_name: "${EXISTING_BUCKET}"
CONFIGEOF

success "Generated ${CONFIG_FILE}"
echo ""
info "Review the config:"
echo "    ${CONFIG_FILE}"
echo ""

# ============================================================================
# Auto-commit and push config.yaml
# ============================================================================
if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    # Compare non-comment content to detect real changes (ignore timestamp in header)
    if git ls-files --error-unmatch "$CONFIG_FILE" &>/dev/null 2>&1 && \
       diff <(grep -v '^#' "$CONFIG_FILE") <(git show HEAD:"$CONFIG_FILE" 2>/dev/null | grep -v '^#') &>/dev/null; then
        git checkout -- "$CONFIG_FILE"
        info "Config unchanged, nothing to commit."
    else
        prompt "Commit and push config.yaml to git? [Y/n]: "
        read -r PUSH_CONFIRM
        PUSH_CONFIRM="${PUSH_CONFIRM:-Y}"

        if [[ "$PUSH_CONFIRM" =~ ^[Yy]$ ]]; then
        info "Committing config.yaml..."
        git add "$CONFIG_FILE"

        # Detect if this is a new file or an update
        if git ls-files --error-unmatch "$CONFIG_FILE" &>/dev/null 2>&1 && git log -1 -- "$CONFIG_FILE" &>/dev/null 2>&1 && [ "$(git log --oneline -- "$CONFIG_FILE" 2>/dev/null | wc -l)" -gt 0 ]; then
            COMMIT_MSG="Update LabLink configuration"
        else
            COMMIT_MSG="Add LabLink configuration"
        fi

        if git commit -m "$COMMIT_MSG" &>/dev/null; then
            success "Committed: ${COMMIT_MSG}"

            # Push to remote
            CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
            if [ -n "$CURRENT_BRANCH" ] && git remote get-url origin &>/dev/null 2>&1; then
                if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" &>/dev/null 2>&1; then
                    if git push 2>/dev/null; then
                        success "Pushed to remote."
                    else
                        warn "Push failed. You can push manually:"
                        echo "    git push"
                    fi
                else
                    if git push -u origin "$CURRENT_BRANCH" 2>/dev/null; then
                        success "Pushed to remote (set upstream to origin/${CURRENT_BRANCH})."
                    else
                        warn "Push failed. You can push manually:"
                        echo "    git push -u origin ${CURRENT_BRANCH}"
                    fi
                fi
            else
                warn "No git remote found. Push manually when ready."
            fi
        else
            warn "Commit failed. You can commit manually:"
            echo "    git add ${CONFIG_FILE}"
            echo "    git commit -m \"${COMMIT_MSG}\""
            echo "    git push"
        fi
        else
            info "Skipped commit and push. You can do it manually:"
            echo "    git add ${CONFIG_FILE}"
            echo "    git commit -m \"Update LabLink configuration\""
            echo "    git push"
        fi
    fi
fi
