#!/bin/bash
# Test script for NetFlow BGP field extraction
# Tests the complete pipeline: IPFIX collector → NATS → database

set -e

echo "=== NetFlow BGP Test Suite ==="
echo

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
COLLECTOR_PORT=2055
TEST_CONFIG="test-data/ipfix_bgp_simple.yaml"
DB_CONTAINER="serviceradar-cnpg-mtls"
DB_USER="serviceradar"
DB_NAME="serviceradar"

# Check if netflow_generator is available
if ! command -v netflow_generator &> /dev/null; then
    echo -e "${RED}✗ netflow_generator not found${NC}"
    echo "  Install with: cargo install netflow_generator"
    echo "  Or use Docker: docker run --rm --network host ghcr.io/mikemiles-dev/netflow_generator:0.2.7"
    exit 1
fi

# Check if test config exists
if [ ! -f "$TEST_CONFIG" ]; then
    echo -e "${RED}✗ Test config not found: $TEST_CONFIG${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/5] Sending IPFIX test flows with BGP data...${NC}"
netflow_generator --config "$TEST_CONFIG" --verbose --once
echo -e "${GREEN}✓ Sent 4 test flows${NC}"
echo

# Wait for processing
echo -e "${YELLOW}[2/5] Waiting for pipeline processing (5 seconds)...${NC}"
sleep 5
echo -e "${GREEN}✓ Pipeline processing complete${NC}"
echo

# Check NATS (if nats CLI is available)
if command -v nats &> /dev/null; then
    echo -e "${YELLOW}[3/5] Checking NATS messages...${NC}"
    MSG_COUNT=$(nats stream info events -j 2>/dev/null | jq '.state.messages' 2>/dev/null || echo "0")
    if [ "$MSG_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ NATS has $MSG_COUNT messages${NC}"
    else
        echo -e "${YELLOW}⚠ Cannot verify NATS (stream may not exist yet)${NC}"
    fi
    echo
else
    echo -e "${YELLOW}[3/5] Skipping NATS check (nats CLI not installed)${NC}"
    echo
fi

# Check database for flows with BGP data
echo -e "${YELLOW}[4/5] Querying database for BGP flows...${NC}"

# Try to query the database
if command -v docker &> /dev/null && docker ps | grep -q "$DB_CONTAINER"; then
    QUERY="SELECT
        timestamp,
        src_addr,
        dst_addr,
        array_length(as_path, 1) as as_path_length,
        array_length(bgp_communities, 1) as community_count,
        as_path,
        bgp_communities
    FROM netflow_metrics
    WHERE timestamp > NOW() - INTERVAL '2 minutes'
        AND (as_path IS NOT NULL OR bgp_communities IS NOT NULL)
    ORDER BY timestamp DESC
    LIMIT 10;"

    echo "Executing query..."
    RESULT=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "$QUERY" 2>&1)

    if echo "$RESULT" | grep -q "rows)"; then
        ROW_COUNT=$(echo "$RESULT" | grep "rows)" | sed 's/.*(\([0-9]*\) rows).*/\1/')
        if [ "$ROW_COUNT" -gt 0 ]; then
            echo -e "${GREEN}✓ Found $ROW_COUNT flows with BGP data${NC}"
            echo
            echo "$RESULT"
        else
            echo -e "${RED}✗ No flows with BGP data found${NC}"
            echo "  Possible issues:"
            echo "  - Collector may not be running"
            echo "  - Database ingestor may not be running"
            echo "  - NATS connectivity issue"
        fi
    else
        echo -e "${RED}✗ Database query failed${NC}"
        echo "$RESULT"
    fi
else
    echo -e "${YELLOW}⚠ Cannot query database (Docker not available or container not running)${NC}"
fi
echo

# Verify specific BGP data
echo -e "${YELLOW}[5/5] Verifying BGP field values...${NC}"

if command -v docker &> /dev/null && docker ps | grep -q "$DB_CONTAINER"; then
    # Check for specific AS numbers
    AS_QUERY="SELECT COUNT(*) as count
    FROM netflow_metrics
    WHERE timestamp > NOW() - INTERVAL '2 minutes'
        AND as_path @> ARRAY[64512]::INTEGER[];"

    AS_COUNT=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "$AS_QUERY" 2>/dev/null | tr -d ' ' || echo "0")

    if [ "$AS_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Flows from AS 64512: $AS_COUNT${NC}"
    else
        echo -e "${RED}✗ No flows from AS 64512 found${NC}"
    fi

    # Check for specific BGP community (65000:100 = 4259840100)
    COMM_QUERY="SELECT COUNT(*) as count
    FROM netflow_metrics
    WHERE timestamp > NOW() - INTERVAL '2 minutes'
        AND bgp_communities @> ARRAY[4259840100]::INTEGER[];"

    COMM_COUNT=$(docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c "$COMM_QUERY" 2>/dev/null | tr -d ' ' || echo "0")

    if [ "$COMM_COUNT" -gt 0 ]; then
        echo -e "${GREEN}✓ Flows with community 65000:100: $COMM_COUNT${NC}"
    else
        echo -e "${RED}✗ No flows with community 65000:100 found${NC}"
    fi

    # Show sample BGP data
    SAMPLE_QUERY="SELECT
        src_addr,
        dst_addr,
        as_path,
        bgp_communities
    FROM netflow_metrics
    WHERE timestamp > NOW() - INTERVAL '2 minutes'
        AND as_path IS NOT NULL
    LIMIT 3;"

    echo
    echo "Sample BGP data:"
    docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "$SAMPLE_QUERY" 2>/dev/null || echo "No samples available"
fi

echo
echo -e "${GREEN}=== BGP Flow Test Complete ===${NC}"
echo
echo "Next steps:"
echo "  1. Review the database results above"
echo "  2. Check collector logs: docker logs serviceradar-netflow-collector-mtls"
echo "  3. Test API queries: curl 'http://localhost:4000/api/v1/netflow/flows?as=64512'"
echo "  4. Test BGP community filter: curl 'http://localhost:4000/api/v1/netflow/flows?community=4259840100'"
