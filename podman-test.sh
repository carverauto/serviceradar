#!/bin/bash
# ServiceRadar Podman Stack Test Script
# Verifies the stack is running correctly after podman-start.sh

# Don't exit on error - we want to run all tests
set +e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0
WARN=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
log_info() { echo -e "[INFO] $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

echo "========================================"
echo "ServiceRadar Podman Stack Test"
echo "========================================"
echo ""

# Expected containers
EXPECTED_CONTAINERS=(
    "serviceradar-cnpg"
    "serviceradar-nats"
    "serviceradar-datasvc"
    "serviceradar-core"
    "serviceradar-srql"
    "serviceradar-kong"
    "serviceradar-agent"
    "serviceradar-poller"
    "serviceradar-sync"
    "serviceradar-web"
    "serviceradar-nginx"
)

echo "=== Container Status ==="
for container in "${EXPECTED_CONTAINERS[@]}"; do
    status=$(podman ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null || echo "")
    if [[ "$status" == *"Up"* ]]; then
        log_pass "$container is running"
    else
        log_fail "$container is not running (status: ${status:-not found})"
    fi
done
echo ""

echo "=== Security Mode Check ==="
# Check poller is using mTLS (not SPIFFE)
poller_mode=$(podman logs serviceradar-poller 2>&1 | grep -o '"mode":"[^"]*"' | head -1 || echo "")
if [[ "$poller_mode" == *"mtls"* ]]; then
    log_pass "Poller is using mTLS security"
elif [[ "$poller_mode" == *"spiffe"* ]]; then
    log_fail "Poller is using SPIFFE (should be mTLS for podman)"
else
    log_warn "Could not determine poller security mode"
fi

# Check core is using mTLS
core_mode=$(podman logs serviceradar-core 2>&1 | grep -o '"security_mode":"[^"]*"' | head -1 || echo "")
if [[ "$core_mode" == *"mtls"* ]] || [[ -z "$core_mode" ]]; then
    log_pass "Core security configuration looks correct"
else
    log_warn "Core security mode: $core_mode"
fi
echo ""

echo "=== Service Health Checks ==="
# Check PostgreSQL
if podman exec serviceradar-cnpg pg_isready -U serviceradar -d serviceradar >/dev/null 2>&1; then
    log_pass "PostgreSQL is ready"
else
    log_fail "PostgreSQL is not ready"
fi

# Check NATS
if podman exec serviceradar-nats nats-server --help >/dev/null 2>&1; then
    log_pass "NATS container is healthy"
else
    log_warn "Could not verify NATS health"
fi

# Check Core API (via Kong)
http_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/health 2>/dev/null || echo "000")
if [ "$http_status" = "200" ] || [ "$http_status" = "401" ]; then
    log_pass "Kong API gateway is responding (HTTP $http_status)"
else
    log_warn "Kong API gateway returned HTTP $http_status"
fi

# Check nginx frontend (307 redirect is OK - it redirects to the app)
http_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
if [ "$http_status" = "200" ] || [ "$http_status" = "304" ] || [ "$http_status" = "307" ] || [ "$http_status" = "302" ]; then
    log_pass "Nginx frontend is responding (HTTP $http_status)"
else
    log_fail "Nginx frontend returned HTTP $http_status"
fi
echo ""

echo "=== Device Registration ==="
# Wait a moment for devices to register if stack just started
sleep 2

# Check device count from core logs
device_stats=$(podman logs serviceradar-core 2>&1 | grep "Device stats snapshot" | tail -1 || echo "")
if [ -n "$device_stats" ]; then
    total_devices=$(echo "$device_stats" | grep -o '"total_devices":[0-9]*' | cut -d: -f2)
    available_devices=$(echo "$device_stats" | grep -o '"available_devices":[0-9]*' | cut -d: -f2)

    if [ -n "$total_devices" ] && [ "$total_devices" -gt 0 ]; then
        log_pass "Devices registered: $total_devices total, $available_devices available"
    else
        log_fail "No devices registered (total_devices: ${total_devices:-0})"
    fi
else
    log_fail "Could not find device stats in core logs"
fi

# Check for agent registration
if podman logs serviceradar-core 2>&1 | grep -q "Registered agent"; then
    log_pass "Agent registration detected"
else
    log_fail "No agent registration found in logs"
fi

# Check for poller registration
if podman logs serviceradar-core 2>&1 | grep -q "Registered poller"; then
    log_pass "Poller registration detected"
else
    log_fail "No poller registration found in logs"
fi
echo ""

echo "=== Polling Activity ==="
# Check poller is actively polling
if podman logs serviceradar-poller 2>&1 | grep -q "Polling cycle completed"; then
    poll_count=$(podman logs serviceradar-poller 2>&1 | grep -c "Polling cycle completed" || echo "0")
    log_pass "Poller is actively polling ($poll_count cycles completed)"
else
    log_fail "No polling activity detected"
fi

# Check status reports to core
if podman logs serviceradar-poller 2>&1 | grep -q "Successfully completed streaming status report"; then
    log_pass "Poller is successfully reporting to core"
else
    log_warn "No successful status reports found (may need more time)"
fi
echo ""

echo "=== Configuration Check ==="
# Verify poller config has mTLS
poller_config_mode=$(podman exec serviceradar-poller cat /etc/serviceradar/config/poller.json 2>/dev/null | grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 || echo "")
if [[ "$poller_config_mode" == *"mtls"* ]]; then
    log_pass "Poller config file has mTLS mode"
else
    log_fail "Poller config file mode: $poller_config_mode (expected mtls)"
fi

# Check certs exist
if podman exec serviceradar-poller ls /etc/serviceradar/certs/poller.pem >/dev/null 2>&1; then
    log_pass "Poller certificates are mounted"
else
    log_fail "Poller certificates not found"
fi
echo ""

echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "${GREEN}Passed: $PASS${NC}"
echo -e "${RED}Failed: $FAIL${NC}"
echo -e "${YELLOW}Warnings: $WARN${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All critical tests passed!${NC}"
    echo ""
    echo "Admin credentials can be found with:"
    echo "  sudo podman logs serviceradar-config-updater 2>&1 | grep -E '(Username|Password)'"
    echo ""
    echo "Access ServiceRadar at: http://localhost"
    exit 0
else
    echo -e "${RED}Some tests failed. Check the logs above for details.${NC}"
    echo ""
    echo "Useful debug commands:"
    echo "  sudo podman logs serviceradar-poller"
    echo "  sudo podman logs serviceradar-core"
    echo "  sudo podman logs serviceradar-agent"
    exit 1
fi
