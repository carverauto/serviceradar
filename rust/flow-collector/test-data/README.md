# NetFlow BGP Test Data

This directory contains YAML configuration files for testing BGP field extraction in IPFIX flows using `netflow_generator`.

## Test Files

### `ipfix_bgp_flows.yaml` - Basic BGP Flow Tests

Tests core BGP functionality with realistic scenarios:

1. **Flow 1**: HTTPS traffic between AS 64512 and AS 64513
   - BGP Community: 65000:100 (encoded as 4259840100)
   - Direct path (no intermediate AS)
   - Tests basic AS path construction

2. **Flow 2**: DNS query to Google (AS 15169)
   - BGP Community: 65000:200 (encoded as 4259840200)
   - Transit AS: 64514
   - Tests AS path with next-hop

3. **Flow 3**: HTTP traffic with multiple hops
   - AS path: 64512 → 64514 → 64515
   - Tests full AS path reconstruction

4. **Flow 4**: Flow without BGP data
   - Tests backward compatibility
   - Verifies collector handles flows without BGP fields

**Usage:**
```bash
netflow_generator --config test-data/ipfix_bgp_flows.yaml --verbose --once
```

### `ipfix_bgp_edge_cases.yaml` - Edge Cases & Boundary Conditions

Tests edge cases and error handling:

1. **Long AS Path**: Tests AS path truncation at 50 ASNs limit
2. **Same Source/Dest AS**: Internal routing within single AS
3. **Zero AS Numbers**: Uninitialized or non-BGP traffic
4. **Large ASNs**: 4-byte AS numbers (AS 131072+)
5. **Multiple Communities**: Testing community field handling
6. **Well-known Communities**: NO_EXPORT (0xFFFFFF01), etc.
7. **Various Protocols**: BGP with different L4 protocols

**Usage:**
```bash
netflow_generator --config test-data/ipfix_bgp_edge_cases.yaml --verbose --once
```

## Running Tests

### Quick Test
```bash
# From rust/netflow-collector directory
./test-bgp-flows.sh
```

This script:
1. Sends IPFIX flows with BGP data
2. Waits for pipeline processing
3. Queries database for BGP flows
4. Verifies AS numbers and communities
5. Shows sample results

### Manual Testing

**1. Start the collector:**
```bash
cargo run -- --config netflow-collector.json
```

**2. Send test flows:**
```bash
# Basic BGP flows
netflow_generator --config test-data/ipfix_bgp_flows.yaml --once

# Edge cases
netflow_generator --config test-data/ipfix_bgp_edge_cases.yaml --once
```

**3. Verify in database:**
```bash
psql -h localhost -p 5455 -U serviceradar -d serviceradar << 'EOF'
-- Show recent flows with BGP data
SELECT
    timestamp,
    src_addr,
    dst_addr,
    src_port,
    dst_port,
    as_path,
    bgp_communities
FROM netflow_metrics
WHERE timestamp > NOW() - INTERVAL '5 minutes'
    AND (as_path IS NOT NULL OR bgp_communities IS NOT NULL)
ORDER BY timestamp DESC
LIMIT 10;

-- Test AS number filtering
SELECT COUNT(*)
FROM netflow_metrics
WHERE as_path @> ARRAY[64512]::INTEGER[];

-- Test BGP community filtering
SELECT COUNT(*)
FROM netflow_metrics
WHERE bgp_communities @> ARRAY[4259840100]::INTEGER[];
EOF
```

## BGP Community Encoding

BGP communities are encoded as 32-bit integers using the format: `(AS_NUMBER << 16) | VALUE`

**Common Examples:**
- `65000:100` → `(65000 << 16) | 100` = `4259840100`
- `65000:200` → `(65000 << 16) | 200` = `4259840200`
- `65000:300` → `(65000 << 16) | 300` = `4259840300`

**Well-known Communities:**
- `NO_EXPORT` → `0xFFFFFF01` = `4294967041`
- `NO_ADVERTISE` → `0xFFFFFF02` = `4294967042`
- `NO_EXPORT_SUBCONFED` → `0xFFFFFF03` = `4294967043`

## IPFIX Field Reference

**BGP AS Fields:**
- `bgpSourceAsNumber` (IE 16) - 4 bytes - Source AS number
- `bgpDestinationAsNumber` (IE 17) - 4 bytes - Destination AS number
- `bgpNextHopAsNumber` (IE 128) - 4 bytes - Next-hop AS number

**BGP Community Fields (RFC 8549):**
- `bgpCommunity` (IE 485) - 4 bytes - Single BGP community value
- `bgpSourceCommunityList` (IE 483) - Variable - List of source communities
- `bgpDestinationCommunityList` (IE 484) - Variable - List of destination communities

## Expected Results

### Collector Output

When processing BGP flows, the collector should log:

```
[INFO] Received IPFIX packet from 127.0.0.1:2056 (template + data)
[INFO] Extracted AS path: [64512, 64513]
[INFO] Extracted BGP communities: [4259840100]
[INFO] Published flow to NATS (flows.raw.netflow)
```

### Database State

Flows should be stored with:
- `as_path` column populated (PostgreSQL INTEGER[] array)
- `bgp_communities` column populated (PostgreSQL INTEGER[] array)
- GIN indexes allowing fast queries with `@>` operator

### API Queries

Test API endpoints once they're wired up:

```bash
# Query flows from AS 64512
curl "http://localhost:4000/api/v1/netflow/flows?as=64512"

# Query flows with community 65000:100
curl "http://localhost:4000/api/v1/netflow/flows?community=4259840100"

# Traffic by AS
curl "http://localhost:4000/api/v1/netflow/bgp/traffic-by-as?start_time=2024-01-01T00:00:00Z&end_time=2024-01-02T00:00:00Z"

# Top communities
curl "http://localhost:4000/api/v1/netflow/bgp/top-communities?start_time=2024-01-01T00:00:00Z&end_time=2024-01-02T00:00:00Z"
```

## Troubleshooting

**Flows not showing BGP data:**
1. Check collector logs for "Extracted AS path" messages
2. Verify IPFIX template includes BGP fields
3. Ensure AS numbers are non-zero in YAML config
4. Check database migration ran successfully

**AS path is empty:**
- Collector constructs AS path from source/dest/next-hop AS
- If all AS numbers are zero, path will be empty
- This is expected for non-BGP traffic

**Community values seem wrong:**
- Verify encoding: `(AS << 16) | VALUE`
- Example: 65000:100 = 4259840100, not 65000100
- Use Python: `hex((65000 << 16) | 100)` to verify

## Integration Testing

For full end-to-end testing:

```bash
# 1. Start all services
docker-compose up -d

# 2. Run test suite
cd rust/netflow-collector
./test-bgp-flows.sh

# 3. Check results in Web UI
# Open: http://localhost:3000/network/netflow
# Verify BGP data displays in flow details
```

## Next Steps

- Add SNMP trap tests for BGP events
- Add vendor-specific IPFIX enterprise fields (Cisco, Juniper)
- Add integration tests for API endpoints
- Add UI tests for BGP visualization components
