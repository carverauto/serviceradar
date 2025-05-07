#!/bin/bash

# Test script to verify Swagger generation and API endpoint coverage

set -e

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Change to project root directory
cd "$(dirname "$0")/.."

echo -e "${YELLOW}Testing Swagger documentation generation...${NC}"

# Check if swag is installed
if ! command -v swag &> /dev/null; then
    echo -e "${RED}Error: swag is not installed.${NC}"
    echo "Please run: go install github.com/swaggo/swag/cmd/swag@latest"
    exit 1
fi

# Create temporary directory for test output
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Run swag init to generate docs
echo "Generating Swagger documentation..."
swag init \
  --generalInfo main.go \
  --dir ./cmd/api,./pkg/core/api,./pkg/models \
  --output "$TMP_DIR" \
  --parseInternal \
  --parseDependency

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to generate Swagger documentation.${NC}"
    exit 1
fi

echo -e "${GREEN}Swagger documentation generated successfully!${NC}"

# Check that swagger.json was created
if [ ! -f "$TMP_DIR/swagger.json" ]; then
    echo -e "${RED}Error: swagger.json was not generated.${NC}"
    exit 1
fi

# Verify key API endpoints are documented
echo "Verifying API endpoints coverage..."

# Function to check if a pattern exists in swagger.json
check_endpoint() {
    local pattern="$1"
    local endpoint_name="$2"

    if grep -q "$pattern" "$TMP_DIR/swagger.json"; then
        echo -e "  ${GREEN}✓${NC} Found endpoint: $endpoint_name"
        return 0
    else
        echo -e "  ${RED}✗${NC} Missing endpoint: $endpoint_name"
        return 1
    fi
}

# List of important endpoints to check
ENDPOINTS=(
    '"/api/pollers"' "Get all pollers"
    '"/api/pollers/{id}"' "Get poller by ID"
    '"/api/status"' "Get system status"
    '"/api/pollers/{id}/metrics"' "Get poller metrics"
    '"/api/pollers/{id}/services"' "Get poller services"
    '"/api/pollers/{id}/snmp"' "Get SNMP data"
    '"/api/pollers/{id}/sysmon/cpu"' "Get CPU metrics"
    '"/api/pollers/{id}/sysmon/disk"' "Get disk metrics"
    '"/api/pollers/{id}/sysmon/memory"' "Get memory metrics"
    '"/auth/login"' "Login endpoint"
)

FAILED=0
for ((i=0; i<${#ENDPOINTS[@]}; i+=2)); do
    if ! check_endpoint "${ENDPOINTS[$i]}" "${ENDPOINTS[$i+1]}"; then
        FAILED=1
    fi
done

# Check that models are documented
echo "Verifying model documentation..."

# Function to check if a model exists in swagger.json
check_model() {
    local model="$1"

    if grep -q "\"$model\":{" "$TMP_DIR/swagger.json"; then
        echo -e "  ${GREEN}✓${NC} Found model: $model"
        return 0
    else
        echo -e "  ${RED}✗${NC} Missing model: $model"
        return 1
    fi
}

# List of important models to check
MODELS=(
    "PollerStatus"
    "ServiceStatus"
    "SystemStatus"
    "MetricPoint"
    "CPUMetric"
    "DiskMetric"
    "MemoryMetric"
    "RperfMetric"
    "Token"
    "ErrorResponse"
)

for model in "${MODELS[@]}"; do
    if ! check_model "$model"; then
        FAILED=1
    fi
done

# Print summary
if [ $FAILED -eq 0 ]; then
    echo -e "\n${GREEN}All checks passed! Swagger documentation is complete.${NC}"
    echo "To view the documentation, run your API server and visit:"
    echo "http://localhost:8080/swagger/index.html"
else
    echo -e "\n${RED}Some checks failed. Please review the issues above.${NC}"
    echo "Make sure all endpoints have proper Swagger annotations and models are documented."
    exit 1
fi

# Copy the generated files to pkg/docs if desired
read -p "Do you want to update the pkg/docs directory with these Swagger files? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    mkdir -p pkg/docs
    cp "$TMP_DIR"/* pkg/docs/
    echo -e "${GREEN}Swagger files copied to pkg/docs/${NC}"
fi