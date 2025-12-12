#!/bin/bash
# Copyright 2025 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# E2E Test Script for ServiceRadar
# Tests API endpoints via HTTP (no kubectl required)
#
# Required Environment Variables:
#   SERVICERADAR_CORE_URL - Base URL (e.g., https://staging.serviceradar.cloud)
#   SERVICERADAR_ADMIN_PASSWORD - Admin password for authentication
#
# Optional Environment Variables:
#   SERVICERADAR_ADMIN_USER - Admin username (default: admin)
#   E2E_TIMEOUT - Request timeout in seconds (default: 30)
#   E2E_VERBOSE - Set to "true" for verbose output

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Configuration
CORE_URL="${SERVICERADAR_CORE_URL:-}"
ADMIN_USER="${SERVICERADAR_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${SERVICERADAR_ADMIN_PASSWORD:-}"
TIMEOUT="${E2E_TIMEOUT:-30}"
VERBOSE="${E2E_VERBOSE:-false}"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# JWT Token (set after authentication)
ACCESS_TOKEN=""

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "[DEBUG] $1"
    fi
}

# Validate required environment variables
validate_env() {
    local missing=0

    if [[ -z "$CORE_URL" ]]; then
        log_error "SERVICERADAR_CORE_URL is required"
        missing=1
    fi

    if [[ -z "$ADMIN_PASSWORD" ]]; then
        log_error "SERVICERADAR_ADMIN_PASSWORD is required"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Usage: SERVICERADAR_CORE_URL=https://staging.serviceradar.cloud \\"
        echo "       SERVICERADAR_ADMIN_PASSWORD=secret \\"
        echo "       $0"
        exit 1
    fi

    log_info "Testing against: $CORE_URL"
}

# Make HTTP request and return response
http_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local auth_header=""

    if [[ -n "$ACCESS_TOKEN" ]]; then
        auth_header="-H \"Authorization: Bearer $ACCESS_TOKEN\""
    fi

    local url="${CORE_URL}${endpoint}"
    log_verbose "Request: $method $url"

    local response
    local http_code

    if [[ -n "$data" ]]; then
        response=$(curl -s -w "\n%{http_code}" \
            --max-time "$TIMEOUT" \
            -X "$method" \
            -H "Content-Type: application/json" \
            ${auth_header:+-H "Authorization: Bearer $ACCESS_TOKEN"} \
            -d "$data" \
            "$url" 2>&1) || true
    else
        response=$(curl -s -w "\n%{http_code}" \
            --max-time "$TIMEOUT" \
            -X "$method" \
            -H "Content-Type: application/json" \
            ${auth_header:+-H "Authorization: Bearer $ACCESS_TOKEN"} \
            "$url" 2>&1) || true
    fi

    # Extract HTTP code from last line
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    log_verbose "Response code: $http_code"
    log_verbose "Response body: $response"

    echo "$http_code"
    echo "$response"
}

# Test wrapper function
run_test() {
    local test_name="$1"
    local test_func="$2"

    echo -n "  Testing: $test_name... "

    if $test_func; then
        echo -e "${GREEN}PASS${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Skip test wrapper
skip_test() {
    local test_name="$1"
    local reason="$2"

    echo -e "  Testing: $test_name... ${YELLOW}SKIP${NC} ($reason)"
    ((TESTS_SKIPPED++))
}

# ============================================================================
# Test Functions
# ============================================================================

test_auth_login() {
    local result
    result=$(http_request "POST" "/auth/login" "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASSWORD\"}")

    local http_code
    http_code=$(echo "$result" | head -n1)
    local body
    body=$(echo "$result" | tail -n +2)

    if [[ "$http_code" != "200" ]]; then
        log_verbose "Login failed with HTTP $http_code: $body"
        return 1
    fi

    # Extract access token from response
    ACCESS_TOKEN=$(echo "$body" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    if [[ -z "$ACCESS_TOKEN" ]]; then
        log_verbose "No access_token in response"
        return 1
    fi

    log_verbose "Got access token: ${ACCESS_TOKEN:0:20}..."
    return 0
}

test_api_status() {
    local result
    result=$(http_request "GET" "/api/status")

    local http_code
    http_code=$(echo "$result" | head -n1)

    [[ "$http_code" == "200" ]]
}

test_api_pollers() {
    local result
    result=$(http_request "GET" "/api/pollers")

    local http_code
    http_code=$(echo "$result" | head -n1)

    # 200 OK or 204 No Content (empty list) are both acceptable
    [[ "$http_code" == "200" || "$http_code" == "204" ]]
}

test_api_devices() {
    local result
    result=$(http_request "GET" "/api/devices")

    local http_code
    http_code=$(echo "$result" | head -n1)

    # 200 OK or 204 No Content are acceptable
    [[ "$http_code" == "200" || "$http_code" == "204" ]]
}

test_srql_query() {
    # Simple SRQL query to test the query endpoint
    local query='{"query":"*","limit":1}'
    local result
    result=$(http_request "POST" "/api/query" "$query")

    local http_code
    http_code=$(echo "$result" | head -n1)

    [[ "$http_code" == "200" ]]
}

test_health_endpoint() {
    # Test Kong gateway health (if available)
    local result
    result=$(http_request "GET" "/health")

    local http_code
    http_code=$(echo "$result" | head -n1)

    # Health endpoint might not exist - 200 or 404 are both acceptable for this test
    [[ "$http_code" == "200" || "$http_code" == "404" ]]
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    echo "=============================================="
    echo "ServiceRadar E2E Tests"
    echo "=============================================="
    echo ""

    validate_env

    echo ""
    echo "--- Authentication Tests ---"
    if ! run_test "Login with admin credentials" test_auth_login; then
        log_error "Authentication failed - cannot proceed with authenticated tests"
        echo ""
        echo "=============================================="
        echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"
        echo "=============================================="
        exit 1
    fi

    echo ""
    echo "--- API Endpoint Tests ---"
    run_test "GET /api/status" test_api_status || true
    run_test "GET /api/pollers" test_api_pollers || true
    run_test "GET /api/devices" test_api_devices || true
    run_test "POST /api/query (SRQL)" test_srql_query || true

    echo ""
    echo "--- Health Check Tests ---"
    run_test "GET /health" test_health_endpoint || true

    echo ""
    echo "=============================================="
    echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_SKIPPED skipped"
    echo "=============================================="

    # Exit with failure if any tests failed
    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
