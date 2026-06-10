#!/bin/bash
#
# LabLink Deployment Verification Script
#
# This script verifies that a LabLink deployment is fully operational.
# It adapts verification based on your configuration (DNS, SSL, etc.)
#
# Requirements:
#   - curl, nslookup (for DNS verification)
#
# Usage:
#   verify-deployment.sh [--ci] <environment>       # Config-aware (reads config.yaml + terraform outputs)
#   verify-deployment.sh [--ci] <domain> <ip>        # Backwards-compatible (explicit values)
#
# Options:
#   --ci    Disable ANSI colors for clean CI logs
#
# Examples:
#   # Config-aware: auto-detect domain and IP from config + terraform
#   verify-deployment.sh prod
#   verify-deployment.sh --ci ci-test
#
#   # Backwards-compatible: explicit domain and IP
#   verify-deployment.sh test.lablink.sleap.ai 52.10.119.234
#   verify-deployment.sh --ci test.lablink.sleap.ai 52.10.119.234
#   verify-deployment.sh "" 52.10.119.234
#

set -e

# Parse --ci flag
CI_MODE=false
if [ "${1:-}" = "--ci" ]; then
    CI_MODE=true
    shift
fi

# Colors for output (disabled in CI mode)
if [ "$CI_MODE" = true ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
fi

# ============================================================================
# Config helper (lightweight version of configure.sh's cfg_get)
# ============================================================================
cfg_get() {
    local key="$1"
    local fallback="${2:-}"
    local file="config/config.yaml"

    if [ ! -f "$file" ]; then
        echo "$fallback"
        return
    fi

    local value=""
    case "$key" in
        dns.enabled)
            value=$(awk '/^dns:/{found=1} found && /enabled:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' || true)
            ;;
        dns.domain)
            value=$(awk '/^dns:/{found=1} found && /domain:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' || true)
            ;;
        dns.terraform_managed)
            value=$(awk '/^dns:/{found=1} found && /terraform_managed:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' || true)
            ;;
        dns.zone_id)
            value=$(awk '/^dns:/{found=1} found && /zone_id:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' || true)
            ;;
        ssl.provider)
            value=$(awk '/^ssl:/{found=1} found && /provider:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' || true)
            ;;
        ssl.email)
            value=$(awk '/^ssl:/{found=1} found && /email:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' || true)
            ;;
        app.region)
            value=$(awk '/^app:/{found=1} found && /region:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' || true)
            ;;
    esac

    # Strip inline comments and whitespace
    value=$(echo "$value" | sed 's/ *#.*//' | xargs 2>/dev/null || true)

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$fallback"
    fi
}

# ============================================================================
# Determine mode: config-aware vs backwards-compatible
# ============================================================================
MODE=""
ENVIRONMENT=""

if [ $# -eq 0 ]; then
    echo -e "${RED}Error: Missing arguments${NC}"
    echo ""
    echo "Usage:"
    echo "  verify-deployment.sh [--ci] <environment>       # Config-aware mode"
    echo "  verify-deployment.sh [--ci] <domain> <ip>        # Backwards-compatible mode"
    echo ""
    echo "Examples:"
    echo "  verify-deployment.sh prod"
    echo "  verify-deployment.sh test.lablink.sleap.ai 52.10.119.234"
    exit 1
elif [ $# -eq 1 ]; then
    # Single arg: if it contains a dot, treat as domain (legacy); otherwise environment name
    if echo "$1" | grep -q '\.'; then
        MODE="legacy"
        DOMAIN_NAME="$1"
        EXPECTED_IP=""
    else
        MODE="config-aware"
        ENVIRONMENT="$1"
    fi
elif [ $# -eq 2 ]; then
    MODE="legacy"
    DOMAIN_NAME="$1"
    EXPECTED_IP="$2"
else
    echo -e "${RED}Error: Too many arguments${NC}"
    echo "Usage:"
    echo "  verify-deployment.sh [--ci] <environment>"
    echo "  verify-deployment.sh [--ci] <domain> <ip>"
    exit 1
fi

# ============================================================================
# Config-aware mode: resolve values from config.yaml + terraform outputs
# ============================================================================
if [ "$MODE" = "config-aware" ]; then
    # Locate lablink-infrastructure directory
    if [ -f "config/config.yaml" ]; then
        # Already in lablink-infrastructure/
        true
    elif [ -f "lablink-infrastructure/config/config.yaml" ]; then
        cd lablink-infrastructure
    else
        echo -e "${RED}Error: Cannot find config/config.yaml${NC}"
        echo "  Run this script from the lablink-infrastructure/ directory,"
        echo "  or from the repository root (lablink-infrastructure/ must exist)."
        exit 1
    fi

    # Read config values
    DNS_ENABLED=$(cfg_get "dns.enabled" "false")
    DNS_TF_MANAGED=$(cfg_get "dns.terraform_managed" "false")
    SSL_PROVIDER=$(cfg_get "ssl.provider" "letsencrypt")
    REGION=$(cfg_get "app.region" "us-west-2")

    # Read IP from terraform output
    EXPECTED_IP=$(terraform output -raw ec2_public_ip 2>/dev/null || echo "")
    if [ -z "$EXPECTED_IP" ]; then
        echo -e "${RED}Error: Could not read ec2_public_ip from Terraform outputs${NC}"
        echo "  Terraform may not be initialized for the '$ENVIRONMENT' environment."
        echo "  Run: ./scripts/init-terraform.sh $ENVIRONMENT"
        echo "  Then: terraform apply -var=\"resource_suffix=$ENVIRONMENT\""
        exit 1
    fi

    # Resolve domain: only if DNS is enabled
    DOMAIN_NAME=""
    if [ "$DNS_ENABLED" = "true" ]; then
        # Try FQDN from terraform output first, fallback to config domain
        FQDN_RAW=$(terraform output -raw allocator_fqdn 2>/dev/null || echo "")
        if [ -n "$FQDN_RAW" ]; then
            # Strip protocol prefix if present
            DOMAIN_NAME=$(echo "$FQDN_RAW" | sed 's|^https\?://||')
        else
            DOMAIN_NAME=$(cfg_get "dns.domain" "")
        fi
    fi

    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}LabLink Deployment Verification${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    echo -e "Domain:             ${GREEN}${DOMAIN_NAME:-N/A (IP-only)}${NC}"
    echo -e "IP Address:         ${GREEN}${EXPECTED_IP}${NC}"
    echo -e "SSL Provider:       ${GREEN}${SSL_PROVIDER}${NC}"
    echo -e "DNS Enabled:        ${GREEN}${DNS_ENABLED}${NC}"
    echo -e "Terraform Managed:  ${GREEN}${DNS_TF_MANAGED}${NC}"
    echo -e "Region:             ${GREEN}${REGION}${NC}"
    echo -e "Environment:        ${GREEN}${ENVIRONMENT}${NC}"
    echo -e "Mode:               ${GREEN}config-aware${NC}"
    echo ""
else
    # ============================================================================
    # Legacy mode: use provided domain and IP directly
    # ============================================================================
    DOMAIN_NAME="${DOMAIN_NAME:-}"
    EXPECTED_IP="${EXPECTED_IP:-}"

    # Read configuration from config.yaml (best-effort, may not exist in legacy mode)
    DNS_ENABLED=false
    SSL_PROVIDER="letsencrypt"
    if [ -f "config/config.yaml" ]; then
        DNS_ENABLED_RAW=$(cfg_get "dns.enabled" "false")
        if [ "$DNS_ENABLED_RAW" = "true" ]; then
            DNS_ENABLED=true
        fi
        SSL_PROVIDER=$(cfg_get "ssl.provider" "letsencrypt")
    fi

    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}LabLink Deployment Verification${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    echo -e "Domain:       ${GREEN}${DOMAIN_NAME:-N/A (IP-only)}${NC}"
    echo -e "IP Address:   ${GREEN}${EXPECTED_IP}${NC}"
    echo -e "SSL Provider: ${GREEN}${SSL_PROVIDER}${NC}"
    echo -e "DNS Enabled:  ${GREEN}${DNS_ENABLED}${NC}"
    echo -e "Mode:         ${GREEN}legacy${NC}"
    echo ""
fi

# Step 0: Validate DNS Configuration
if [ "$DNS_ENABLED" = true ]; then
    echo -e "${YELLOW}[0/3] Validating DNS configuration...${NC}"

    if [ "$MODE" = "config-aware" ]; then
        CONFIG_DOMAIN=$(cfg_get "dns.domain" "")
    else
        CONFIG_DOMAIN=$(grep -A 10 "^dns:" config/config.yaml 2>/dev/null | grep "domain:" | awk '{print $2}' | tr -d '"' 2>/dev/null || echo "")
    fi

    if [ -z "$CONFIG_DOMAIN" ]; then
        echo -e "${RED}Error: DNS is enabled but domain is empty in config/config.yaml${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ DNS configuration valid (domain: $CONFIG_DOMAIN)${NC}"
    echo ""
else
    echo -e "${YELLOW}[0/3] DNS is disabled in configuration${NC}"
    echo ""
fi

# Step 1: DNS Resolution (only if domain provided AND dns.enabled)
if [ -n "$DOMAIN_NAME" ] && [ "$DNS_ENABLED" = true ]; then
    echo -e "${YELLOW}[1/3] Verifying DNS resolution...${NC}"

    MAX_WAIT=300
    WAIT_INTERVAL=10
    ELAPSED=0
    DNS_RESOLVED=false

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        GOOGLE_IP=$(nslookup "$DOMAIN_NAME" 8.8.8.8 2>/dev/null | grep -A1 "Name:" | tail -n1 | awk '{print $2}' || echo "")

        if [ "$GOOGLE_IP" = "$EXPECTED_IP" ]; then
            echo -e "${GREEN}✓ DNS propagated successfully${NC}"
            echo -e "  $DOMAIN_NAME → $EXPECTED_IP"
            DNS_RESOLVED=true
            break
        fi

        if [ $ELAPSED -eq 0 ]; then
            echo -e "  Waiting for DNS propagation..."
        fi

        printf "  Elapsed: ${ELAPSED}s / ${MAX_WAIT}s (resolved: ${GOOGLE_IP:-NXDOMAIN})\r"
        sleep $WAIT_INTERVAL
        ELAPSED=$((ELAPSED + WAIT_INTERVAL))
    done

    echo ""

    if [ "$DNS_RESOLVED" = false ]; then
        echo -e "${YELLOW}⚠ DNS propagation timed out after ${MAX_WAIT}s${NC}"
        echo -e "  This may be normal for newly created DNS records"
        echo -e "  Try: nslookup $DOMAIN_NAME"
        echo ""
        exit 0
    fi
    echo ""
else
    echo -e "${YELLOW}[1/3] Skipping DNS verification (DNS disabled or no domain)${NC}"
    echo ""
fi

# Step 2: HTTP Health Check
echo -e "${YELLOW}[2/3] Verifying HTTP connectivity...${NC}"

echo -e "  Waiting for allocator container to start (60s)..."
sleep 60

# Determine test URL
if [ "$DNS_ENABLED" = true ] && [ -n "$DOMAIN_NAME" ]; then
    TEST_URL="http://$DOMAIN_NAME"
else
    TEST_URL="http://$EXPECTED_IP"
fi

echo -e "  Testing: $TEST_URL"

MAX_WAIT=120
WAIT_INTERVAL=10
ELAPSED=0
HTTP_OK=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$TEST_URL" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "308" ] || [ "$HTTP_CODE" = "301" ]; then
        echo -e "${GREEN}✓ HTTP responding (status $HTTP_CODE)${NC}"
        HTTP_OK=true
        break
    fi

    if [ $ELAPSED -eq 0 ]; then
        echo -e "  Waiting for allocator to respond..."
    fi

    printf "  Elapsed: ${ELAPSED}s / ${MAX_WAIT}s (status: $HTTP_CODE)\r"
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

echo ""

if [ "$HTTP_OK" = false ]; then
    echo -e "${YELLOW}⚠ Allocator not responding via HTTP after ${MAX_WAIT}s${NC}"
    echo -e "  This may be normal if the container is still starting"
    echo -e "  Check logs: ssh ubuntu@$EXPECTED_IP sudo docker logs \$(sudo docker ps -q)"
    echo ""
    exit 0
fi
echo ""

# Step 3: HTTPS / SSL (only if letsencrypt + dns.enabled + domain)
if [ "$SSL_PROVIDER" = "letsencrypt" ] && [ "$DNS_ENABLED" = true ] && [ -n "$DOMAIN_NAME" ]; then
    echo -e "${YELLOW}[3/3] Verifying HTTPS and SSL certificate...${NC}"
    echo -e "  Waiting for Let's Encrypt certificate acquisition..."

    MAX_WAIT=180
    WAIT_INTERVAL=10
    ELAPSED=0
    HTTPS_OK=false

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "https://$DOMAIN_NAME" 2>/dev/null || echo "000")

        if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "302" ] || [ "$HTTPS_CODE" = "301" ]; then
            echo -e "${GREEN}✓ HTTPS responding (status $HTTPS_CODE)${NC}"

            CERT_INFO=$(echo | openssl s_client -servername "$DOMAIN_NAME" -connect "$DOMAIN_NAME:443" 2>/dev/null | openssl x509 -noout -issuer -dates 2>/dev/null || echo "")

            if [ -n "$CERT_INFO" ]; then
                echo -e "${GREEN}✓ SSL certificate obtained:${NC}"
                echo "$CERT_INFO" | sed 's/^/  /'
            fi

            HTTPS_OK=true
            break
        fi

        if [ $ELAPSED -eq 0 ]; then
            echo -e "  Waiting for SSL certificate..."
        fi

        printf "  Elapsed: ${ELAPSED}s / ${MAX_WAIT}s (status: $HTTPS_CODE)\r"
        sleep $WAIT_INTERVAL
        ELAPSED=$((ELAPSED + WAIT_INTERVAL))
    done

    echo ""

    if [ "$HTTPS_OK" = false ]; then
        echo -e "${YELLOW}⚠ SSL certificate not yet available after ${MAX_WAIT}s${NC}"
        echo -e "  Caddy may still be acquiring the certificate"
        echo -e "  Check logs: ssh ubuntu@$EXPECTED_IP sudo journalctl -u caddy -f"
        echo ""
        exit 0
    fi
elif [ "$SSL_PROVIDER" = "cloudflare" ]; then
    echo -e "${YELLOW}[3/3] Skipping SSL verification (CloudFlare handles SSL)${NC}"
elif [ "$SSL_PROVIDER" = "none" ]; then
    echo -e "${YELLOW}[3/3] Skipping SSL verification (SSL disabled)${NC}"
else
    echo -e "${YELLOW}[3/3] Skipping SSL verification (no domain or DNS disabled)${NC}"
fi

echo ""

# Final summary
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}================================${NC}"
echo ""
echo -e "${GREEN}✓ Deployment verification complete!${NC}"
echo ""

if [ "$DNS_ENABLED" = true ] && [ -n "$DOMAIN_NAME" ]; then
    echo -e "Access your allocator at:"
    echo -e "  HTTP:  ${GREEN}http://${DOMAIN_NAME}${NC}"
    if [ "$SSL_PROVIDER" = "letsencrypt" ]; then
        echo -e "  HTTPS: ${GREEN}https://${DOMAIN_NAME}${NC}"
    fi
    echo ""
    echo -e "Admin dashboard:"
    if [ "$SSL_PROVIDER" != "none" ]; then
        echo -e "  ${GREEN}https://${DOMAIN_NAME}/admin${NC}"
    else
        echo -e "  ${GREEN}http://${DOMAIN_NAME}/admin${NC}"
    fi
else
    echo -e "Access your allocator at:"
    echo -e "  HTTP:  ${GREEN}http://${EXPECTED_IP}${NC}"
    echo ""
    echo -e "Admin dashboard:"
    echo -e "  ${GREEN}http://${EXPECTED_IP}/admin${NC}"
fi

echo ""
