#!/usr/bin/env bash
# Validate all example configuration files
# This script validates each *.example.yaml file in lablink-infrastructure/config

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lablink-infrastructure/config" && pwd)"
DOCKER_IMAGE="ghcr.io/talmolab/lablink-allocator-image:linux-amd64-latest-test"

echo -e "${CYAN}=== Validating All Example Configs ===${NC}"
echo ""

passed=0
failed=0
failed_files=()

# Find all example configs
mapfile -t examples < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.example.yaml" -o -name "example.config.yaml" | sort)

for example in "${examples[@]}"; do
    example_name=$(basename "$example")
    echo -e "${YELLOW}Validating: $example_name${NC}"

    # Copy to config.yaml for validation
    cp "$example" "$CONFIG_DIR/config.yaml"

    # Run validation and capture output
    if docker run --rm \
        -v "$CONFIG_DIR/config.yaml:/config/config.yaml:ro" \
        "$DOCKER_IMAGE" \
        uv run lablink-validate-config /config/config.yaml 2>&1 | tee /tmp/validate-output.txt | grep -q "\[PASS\]"; then
        echo -e "  ${GREEN}[PASS]${NC}"
        ((passed++))
    else
        echo -e "  ${RED}[FAIL]${NC}"
        # Show error details
        grep -v "UserWarning" /tmp/validate-output.txt | tail -5 | sed 's/^/  /' || true
        ((failed++))
        failed_files+=("$example_name")
    fi

    # Clean up
    rm -f "$CONFIG_DIR/config.yaml"
    echo ""
done

echo -e "${CYAN}=== Validation Summary ===${NC}"
echo -e "${GREEN}Passed: $passed${NC}"
if [ $failed -eq 0 ]; then
    echo -e "${GREEN}Failed: $failed${NC}"
else
    echo -e "${RED}Failed: $failed${NC}"
fi

if [ $failed -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed files:${NC}"
    for file in "${failed_files[@]}"; do
        echo -e "  ${RED}- $file${NC}"
    done
    exit 1
else
    echo ""
    echo -e "${GREEN}All configurations validated successfully!${NC}"
    exit 0
fi