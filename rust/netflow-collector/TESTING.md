# NetFlow Implementation Testing Guide

This guide covers testing the complete NetFlow pipeline from collector to Web UI.

## Quick Start

The fastest way to test the NetFlow collector. Choose the method that works best for you:

### Option 1: Docker (Recommended - No Installation Required)

```bash
# 1. Start the collector (in one terminal)
cd /Users/michaelmileusnich/Code/serviceradar/rust/netflow-collector
cargo run -- --config netflow-collector.json

# 2. Send a test packet using Docker (in another terminal)
docker run --rm --network host ghcr.io/mikemiles-dev/netflow_generator:0.2.7 \
  --dest 127.0.0.1:2055 --once
```

### Option 2: Pre-built Binary (Fast - One-time Download)

```bash
# 1. Download the binary for your platform (one-time setup)
# macOS Apple Silicon:
curl -L https://github.com/mikemiles-dev/netflow_generator/releases/latest/download/netflow_generator-aarch64-apple-darwin \
  -o /usr/local/bin/netflow_generator && chmod +x /usr/local/bin/netflow_generator

# macOS Intel:
curl -L https://github.com/mikemiles-dev/netflow_generator/releases/latest/download/netflow_generator-x86_64-apple-darwin \
  -o /usr/local/bin/netflow_generator && chmod +x /usr/local/bin/netflow_generator

# Linux x86_64:
curl -L https://github.com/mikemiles-dev/netflow_generator/releases/latest/download/netflow_generator-x86_64-unknown-linux-gnu \
  -o /usr/local/bin/netflow_generator && chmod +x /usr/local/bin/netflow_generator

# Linux ARM64:
curl -L https://github.com/mikemiles-dev/netflow_generator/releases/latest/download/netflow_generator-aarch64-unknown-linux-gnu \
  -o /usr/local/bin/netflow_generator && chmod +x /usr/local/bin/netflow_generator

# 2. Start the collector (in one terminal)
cd /Users/michaelmileusnich/Code/serviceradar/rust/netflow-collector
cargo run -- --config netflow-collector.json

# 3. Send a test packet (in another terminal)
netflow_generator --dest 127.0.0.1:2055 --once
```

### Option 3: Cargo Install (For Development - Requires Rust Toolchain)

```bash
# 1. Install the generator (compiles from source)
cargo install netflow_generator

# 2. Start the collector (in one terminal)
cd /Users/michaelmileusnich/Code/serviceradar/rust/netflow-collector
cargo run -- --config netflow-collector.json

# 3. Send a test packet (in another terminal)
netflow_generator --dest 127.0.0.1:2055 --once
```

---

Each `--once` execution sends 6 packets: NetFlow v5, v7, v9 (template + data), and IPFIX (template + data).

**Common commands:**
```bash
# Continuous testing (sends every 2 seconds)
netflow_generator --dest 127.0.0.1:2055

# Or with Docker:
docker run --rm --network host ghcr.io/mikemiles-dev/netflow_generator:0.2.7 \
  --dest 127.0.0.1:2055

# Custom interval
netflow_generator --dest 127.0.0.1:2055 --interval 5

# High-volume testing
netflow_generator --dest 127.0.0.1:2055 --interval 0.1

# Multiple test rounds
for i in {1..5}; do netflow_generator --dest 127.0.0.1:2055 --once; sleep 1; done

# Or with Docker:
for i in {1..5}; do docker run --rm --network host ghcr.io/mikemiles-dev/netflow_generator:0.2.7 \
  --dest 127.0.0.1:2055 --once; sleep 1; done
```

### Option 4: Docker Compose with Testing Profile (Automated Continuous Testing)

For automated, continuous testing alongside your full stack:

```bash
# Start the entire stack with automated NetFlow generation
docker-compose --profile testing up -d

# The netflow-generator service will automatically send flows every 2 seconds
# Monitor the pipeline
docker-compose logs -f netflow-collector zen db-event-writer

# Stop when done
docker-compose --profile testing down
```

This option is ideal for:
- CI/CD pipelines
- Load testing
- Continuous integration testing
- Automated regression testing

For comprehensive testing scenarios, see the sections below.

## Prerequisites

For advanced testing, you may also need:

```bash
# Install NATS CLI (for message inspection)
# macOS:
brew install nats-io/nats-tools/nats

# Linux:
curl -L https://github.com/nats-io/natscli/releases/download/v0.1.1/nats-0.1.1-linux-amd64.tar.gz | tar xz
sudo mv nats /usr/local/bin/

# PostgreSQL client (for database queries)
# macOS: already available via psql
# Linux: apt-get install postgresql-client
```

## Test Levels

### **Level 1: Unit Tests**

Test individual Rust modules:

```bash
# Test SRQL flows query module
cd /Users/michaelmileusnich/Code/serviceradar/rust/srql
cargo test flows::tests --lib -- --nocapture

# Expected output:
# running 3 tests
# test query::flows::tests::test_parse_stats_expr ... ok
# test query::flows::tests::builds_query_with_ip_filter ... ok
# test query::flows::tests::unknown_filter_field_returns_error ... ok
```

### **Level 2: Component Tests**

Test each component independently:

#### **2.1 Test NetFlow Collector (Standalone)**

```bash
# Terminal 1: Start the collector with file-based config
cd /Users/michaelmileusnich/Code/serviceradar/rust/netflow-collector
cargo run -- --config netflow-collector.json

# Terminal 2: Send test packets
netflow_generator --dest 127.0.0.1:2055 --once

# Expected collector logs:
# [INFO] Received NetFlow packet from 127.0.0.1:xxxxx (96 bytes)
# [INFO] Parsed 2 flows from NetFlow v5 packet
# [INFO] Published 2 flows to NATS (flows.raw.netflow)
```

#### **2.2 Test NATS Message Flow**

```bash
# Subscribe to raw NetFlow messages
nats sub "flows.raw.netflow" --translate "jq"

# Subscribe to processed OCSF messages
nats sub "flows.raw.netflow.processed" --translate "jq"

# Send test packet in another terminal
netflow_generator --dest 127.0.0.1:2055 --once

# Expected NATS output (flows.raw.netflow):
# {
#   "version": 5,
#   "src_addr": "10.0.0.100",
#   "dst_addr": "10.0.0.1",
#   "src_port": 45678,
#   "dst_port": 443,
#   "protocol": 6,
#   "bytes": 150000,
#   "packets": 100,
#   ...
# }
```

#### **2.3 Test Zen Transformation**

```bash
# Check Zen consumer logs for transformation
docker logs -f serviceradar-zen-mtls 2>&1 | grep -i "netflow\|flow"

# Expected logs:
# [INFO] Processing message from flows.raw.netflow
# [INFO] Applied rule: netflow_to_ocsf
# [INFO] Published to flows.raw.netflow.processed
```

#### **2.4 Test Database Persistence**

```bash
# Connect to database
psql "postgresql://serviceradar:serviceradar@localhost:5455/serviceradar?sslmode=require&sslrootcert=/path/to/root.pem"

# Check if flows are being written
SELECT COUNT(*) FROM ocsf_network_activity;

# View recent flows
SELECT
    time,
    src_endpoint_ip,
    dst_endpoint_ip,
    dst_endpoint_port,
    protocol_name,
    bytes_total,
    packets_total
FROM ocsf_network_activity
ORDER BY time DESC
LIMIT 10;

# Expected output:
#          time           | src_endpoint_ip | dst_endpoint_ip | dst_endpoint_port | protocol_name | bytes_total | packets_total
# ------------------------+-----------------+-----------------+-------------------+---------------+-------------+---------------
#  2025-12-22 13:45:30.123| 10.0.0.100      | 10.0.0.1        |               443 | TCP           |      150000 |           100
#  2025-12-22 13:45:30.123| 10.0.0.200      | 8.8.8.8         |                53 | UDP           |        5000 |            10
```

#### **2.5 Test SRQL Query Engine**

```bash
# Test SRQL via API
curl -s -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "in:flows time:last_1h limit:5"}' \
  http://localhost:8080/api/query | jq

# Test with filters
curl -s -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "in:flows time:last_1h src_ip:10.0.0.100 limit:5"}' \
  http://localhost:8080/api/query | jq

# Test stats aggregation
curl -s -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"query": "in:flows time:last_24h stats:\"sum(bytes_total) as total_bytes by src_endpoint_ip\" sort:total_bytes:desc limit:10"}' \
  http://localhost:8080/api/query | jq
```

### **Level 3: End-to-End Integration Tests**

#### **3.1 Full Pipeline Test**

```bash
# 1. Start all services via Docker Compose
cd /Users/michaelmileusnich/Code/serviceradar
docker-compose up -d

# 2. Wait for services to be healthy
docker-compose ps

# 3. Send test NetFlow packets (multiple iterations)
for i in {1..5}; do netflow_generator --dest 127.0.0.1:2055 --once; sleep 0.5; done

# 4. Wait 5 seconds for processing
sleep 5

# 5. Verify in database
docker exec -it serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -c \
  "SELECT COUNT(*) as flow_count FROM ocsf_network_activity WHERE time > NOW() - INTERVAL '1 minute';"

# Expected output:
#  flow_count
# ------------
#          20
# (1 row)

# 6. Query via SRQL API
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/api/query?q=in:flows+time:last_5m+limit:5" | jq '.results | length'

# Expected output: 5

# 7. Check Web UI
# Open browser: http://localhost:3000/network
# Click "NetFlow" tab
# Should see flows in dashboard
```

#### **3.2 Test Web UI Dashboard**

Manual testing steps:

1. **Navigate to NetFlow Dashboard**:
   - Open: `http://localhost:3000/network`
   - Click the "NetFlow" tab

2. **Verify Summary Cards**:
   - ✓ "Top Talkers" shows count > 0
   - ✓ "Total Bandwidth" shows formatted bytes (e.g., "150.00 KB")
   - ✓ "Active Flows" shows recent flow count

3. **Verify Top Talkers Panel**:
   - ✓ Shows ranked list of source IPs
   - ✓ Displays byte totals formatted (KB/MB/GB)
   - ✓ Sorted by total bytes descending

4. **Verify Top Ports Panel**:
   - ✓ Shows destination ports
   - ✓ Shows well-known service names (e.g., "443 HTTPS")
   - ✓ Displays byte totals

5. **Verify Recent Flows Table**:
   - ✓ Shows timestamp, source, destination, protocol
   - ✓ Displays bytes and packets
   - ✓ Auto-refreshes every 30 seconds

### **Level 4: Performance & Load Tests**

#### **4.1 Throughput Test**

Test sustained flow ingestion rate:

```bash
# Send continuous packets for throughput testing
# netflow_generator sends 6 packets per cycle (v5, v7, 2xv9, 2xIPFIX)
time timeout 60s netflow_generator --dest 127.0.0.1:2055 --interval 0.1

# Measure throughput
# Expected: ~60 packets/sec, ~10k flows/sec with minimal drops
```

#### **4.2 Stress Test**

```bash
# Run multiple senders in parallel (each runs for 30 seconds)
for i in {1..10}; do
  timeout 30s netflow_generator --dest 127.0.0.1:2055 --interval 0.5 &
done
wait

# Check collector logs for drops
docker logs serviceradar-netflow-collector-mtls 2>&1 | grep -i "drop\|buffer full"

# Check NATS backlog
nats stream info events
```

#### **4.3 Query Performance Test**

```bash
# Time a basic query
time curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/api/query?q=in:flows+time:last_24h+limit:100" > /dev/null

# Expected: < 1 second

# Time a stats aggregation query
time curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/api/query?q=in:flows+time:last_24h+stats:sum(bytes_total)+as+total+by+src_endpoint_ip+limit:25" > /dev/null

# Expected: < 2 seconds
```

## Troubleshooting

### **Collector not receiving packets**

```bash
# Check if collector is listening
netstat -an | grep 2055

# Check firewall
sudo iptables -L -n | grep 2055  # Linux
sudo pfctl -sr | grep 2055       # macOS

# Test with tcpdump
sudo tcpdump -i any -n udp port 2055
```

### **Flows not appearing in NATS**

```bash
# Check collector logs
docker logs serviceradar-netflow-collector-mtls

# Check NATS connectivity
nats server check connection

# Check stream exists
nats stream ls
nats stream info events
```

### **Flows not in database**

```bash
# Check db-event-writer logs
docker logs serviceradar-db-event-writer-mtls 2>&1 | grep -i "netflow\|ocsf_network_activity"

# Check for errors
docker logs serviceradar-db-event-writer-mtls 2>&1 | grep -i "error\|failed"

# Verify table exists
docker exec -it serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -c "\dt ocsf_network_activity"
```

### **SRQL queries returning no results**

```bash
# Check if data exists
psql -c "SELECT COUNT(*) FROM ocsf_network_activity;"

# Check time filter
psql -c "SELECT MIN(time), MAX(time) FROM ocsf_network_activity;"

# Test raw SQL
psql -c "SELECT * FROM ocsf_network_activity ORDER BY time DESC LIMIT 5;"
```

## Continuous Testing

### **Automated Test Suite**

Create a simple test script:

```bash
#!/bin/bash
# test-netflow-pipeline.sh

set -e

echo "=== NetFlow Pipeline Test Suite ==="
echo

# 1. Send test packets
echo "[1/5] Sending test NetFlow packets..."
for i in {1..3}; do netflow_generator --dest 127.0.0.1:2055 --once; sleep 1; done
sleep 3

# 2. Check NATS
echo "[2/5] Checking NATS messages..."
MSG_COUNT=$(nats stream info events -j | jq '.state.messages')
if [ "$MSG_COUNT" -gt 0 ]; then
  echo "✓ NATS has $MSG_COUNT messages"
else
  echo "✗ No messages in NATS"
  exit 1
fi

# 3. Check database
echo "[3/5] Checking database..."
DB_COUNT=$(docker exec serviceradar-cnpg-mtls psql -U serviceradar -d serviceradar -t -c "SELECT COUNT(*) FROM ocsf_network_activity WHERE time > NOW() - INTERVAL '1 minute';")
if [ "$DB_COUNT" -gt 0 ]; then
  echo "✓ Database has $DB_COUNT flows"
else
  echo "✗ No flows in database"
  exit 1
fi

# 4. Test SRQL query
echo "[4/5] Testing SRQL query..."
QUERY_RESULT=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/api/query?q=in:flows+time:last_5m+limit:5" | jq '.results | length')
if [ "$QUERY_RESULT" -gt 0 ]; then
  echo "✓ SRQL returned $QUERY_RESULT results"
else
  echo "✗ SRQL returned no results"
  exit 1
fi

# 5. Test stats query
echo "[5/5] Testing SRQL stats aggregation..."
STATS_RESULT=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8080/api/query?q=in:flows+time:last_5m+stats:sum(bytes_total)+as+total+by+src_endpoint_ip+limit:10" | jq '.results | length')
if [ "$STATS_RESULT" -gt 0 ]; then
  echo "✓ Stats query returned $STATS_RESULT results"
else
  echo "✗ Stats query returned no results"
  exit 1
fi

echo
echo "=== All Tests Passed! ==="
```

## Real NetFlow Device Testing

For testing with real network devices:

```bash
# Configure your router/switch to export NetFlow to:
# IP: <serviceradar-host-ip>
# Port: 2055 (NetFlow v5/v9) or 4739 (IPFIX)

# Example Cisco IOS configuration:
# ip flow-export version 5
# ip flow-export destination <serviceradar-ip> 2055
# ip flow-export source <interface>
#
# interface GigabitEthernet0/1
#   ip flow ingress
#   ip flow egress
```

## Success Criteria

- ✅ Collector receives and parses NetFlow packets
- ✅ Messages published to NATS JetStream
- ✅ Zen transforms flows to OCSF format
- ✅ Flows persisted in TimescaleDB
- ✅ SRQL queries return correct results
- ✅ Stats aggregations work correctly
- ✅ Web UI displays flows in real-time
- ✅ System handles 10k+ flows/sec with < 1% drops
- ✅ Queries complete in < 2 seconds

## Next Steps

After successful testing:

1. **Monitor Performance**: Set up Prometheus metrics for collector
2. **Alert Setup**: Configure alerts for flow drops, query latency
3. **Retention Policy**: Configure TimescaleDB compression/retention
4. **Backup Strategy**: Set up CNPG backups for flow data
5. **Documentation**: Document production deployment steps
