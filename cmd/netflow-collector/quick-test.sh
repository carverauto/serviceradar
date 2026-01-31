#!/bin/bash
# Quick NetFlow Pipeline Test
# This script performs a basic end-to-end test of the NetFlow implementation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}NetFlow Quick Test${NC}"
echo -e "${BLUE}================================${NC}"
echo

# Check if services are running
echo -e "${YELLOW}[1/7] Checking services...${NC}"
if ! docker ps | grep -q "serviceradar-netflow-collector"; then
    echo -e "${RED}✗ NetFlow collector not running${NC}"
    echo "Start with: docker-compose up -d netflow-collector"
    exit 1
fi
echo -e "${GREEN}✓ NetFlow collector running${NC}"

if ! docker ps | grep -q "serviceradar-nats"; then
    echo -e "${RED}✗ NATS not running${NC}"
    echo "Start with: docker-compose up -d nats"
    exit 1
fi
echo -e "${GREEN}✓ NATS running${NC}"

if ! docker ps | grep -q "serviceradar-cnpg"; then
    echo -e "${RED}✗ CNPG not running${NC}"
    echo "Start with: docker-compose up -d cnpg"
    exit 1
fi
echo -e "${GREEN}✓ CNPG running${NC}"
echo

# Send test NetFlow packets
echo -e "${YELLOW}[2/7] Sending test NetFlow packets...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ docker not found${NC}"
    echo "Install Docker or use: netflow_generator --dest 127.0.0.1:2055 --once"
    exit 1
fi

# Send 5 test rounds using netflow_generator Docker image
for i in {1..5}; do
    docker run --rm --network host ghcr.io/mikemiles-dev/netflow_generator:0.2.6 \
        --dest 127.0.0.1:2055 --once > /dev/null 2>&1
    sleep 0.5
done
echo -e "${GREEN}✓ Sent 5 test rounds (30 flows total)${NC}"
echo

# Wait for processing
echo -e "${YELLOW}[3/7] Waiting for pipeline processing...${NC}"
sleep 3
echo -e "${GREEN}✓ Wait complete${NC}"
echo

# Check collector logs
echo -e "${YELLOW}[4/7] Checking collector logs...${NC}"
COLLECTOR_LOGS=$(docker logs --tail 20 serviceradar-netflow-collector-mtls 2>&1)
if echo "$COLLECTOR_LOGS" | grep -q "Received NetFlow packet"; then
    echo -e "${GREEN}✓ Collector received packets${NC}"
    PACKET_COUNT=$(echo "$COLLECTOR_LOGS" | grep -c "Received NetFlow packet" || echo "0")
    echo "  Packets received: $PACKET_COUNT"
else
    echo -e "${RED}✗ No packets received by collector${NC}"
    echo "Check logs with: docker logs serviceradar-netflow-collector-mtls"
fi
echo

# Check NATS
echo -e "${YELLOW}[5/7] Checking NATS stream...${NC}"
if command -v nats &> /dev/null; then
    NATS_MSGS=$(nats stream info flows -j 2>/dev/null | jq -r '.state.messages' 2>/dev/null || echo "0")
    if [ "$NATS_MSGS" -gt 0 ]; then
        echo -e "${GREEN}✓ NATS stream has messages${NC}"
        echo "  Total messages: $NATS_MSGS"
    else
        echo -e "${YELLOW}⚠ No messages in NATS stream (may still be processing)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ NATS CLI not installed, skipping check${NC}"
    echo "  Install: brew install nats-io/nats-tools/nats"
fi
echo

# Check database
echo -e "${YELLOW}[6/7] Checking database...${NC}"
DB_COUNT=$(docker exec serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -t -c \
    "SELECT COUNT(*) FROM ocsf_network_activity WHERE time > NOW() - INTERVAL '2 minutes';" 2>/dev/null | tr -d ' ' || echo "0")

if [ "$DB_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Flows found in database${NC}"
    echo "  Flow count (last 2 min): $DB_COUNT"

    # Show sample flow
    echo
    echo "  Sample flow:"
    docker exec serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -c \
        "SELECT time, src_endpoint_ip, dst_endpoint_ip, dst_endpoint_port, protocol_name, bytes_total
         FROM ocsf_network_activity
         ORDER BY time DESC LIMIT 1;" 2>/dev/null | grep -v "^$" || true
else
    echo -e "${YELLOW}⚠ No flows in database yet${NC}"
    echo "  This may be normal if:"
    echo "  - Zen consumer is still processing"
    echo "  - db-event-writer hasn't written yet"
    echo "  Check logs: docker-compose logs zen db-event-writer"
fi
echo

# Test SRQL query
echo -e "${YELLOW}[7/7] Testing SRQL query...${NC}"
if command -v curl &> /dev/null && [ -n "${SERVICERADAR_API_TOKEN:-}" ]; then
    SRQL_RESULT=$(curl -s -H "Authorization: Bearer $SERVICERADAR_API_TOKEN" \
        "http://localhost:8080/api/query?q=in:flows+time:last_5m+limit:5" 2>/dev/null | jq -r '.results | length' 2>/dev/null || echo "0")

    if [ "$SRQL_RESULT" -gt 0 ]; then
        echo -e "${GREEN}✓ SRQL query successful${NC}"
        echo "  Results returned: $SRQL_RESULT"
    else
        echo -e "${YELLOW}⚠ SRQL returned no results${NC}"
        echo "  Set SERVICERADAR_API_TOKEN env var for API access"
    fi
else
    echo -e "${YELLOW}⚠ Skipping SRQL test${NC}"
    echo "  Set SERVICERADAR_API_TOKEN env var to test"
fi
echo

# Summary
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}================================${NC}"

if [ "$DB_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ End-to-end pipeline working!${NC}"
    echo
    echo "Next steps:"
    echo "1. View flows in Web UI: http://localhost:3000/network (NetFlow tab)"
    echo "2. Run full test suite: ./quick-test.sh"
    echo "3. Query flows: SRQL query 'in:flows time:last_24h limit:10'"
    echo
    echo "Performance tips:"
    echo "- Send real NetFlow from network devices to port 2055"
    echo "- Monitor: docker stats"
    echo "- View metrics: http://localhost:3000/metrics"
else
    echo -e "${YELLOW}⚠ Pipeline test incomplete${NC}"
    echo
    echo "Troubleshooting:"
    echo "1. Check all logs: docker-compose logs"
    echo "2. Verify services: docker-compose ps"
    echo "3. Re-run test: ./quick-test.sh"
    echo "4. See full guide: cat TESTING.md"
fi
echo
