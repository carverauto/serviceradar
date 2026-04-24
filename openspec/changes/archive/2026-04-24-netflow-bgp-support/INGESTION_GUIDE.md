# NetFlow BGP Field Ingestion Guide

## Overview

This guide documents how to extract BGP fields from protobuf FlowMessages and populate the NetflowMetric struct for database storage.

## Protobuf Schema

The `flowpb.FlowMessage` protobuf already includes BGP fields:

```protobuf
message FlowMessage {
  // ... existing fields ...

  // BGP information (lines 87-88 in flow.proto)
  repeated uint32 bgp_communities = 101;  // BGP community values (32-bit)
  repeated uint32 as_path = 102;          // AS path sequence
}
```

## Go Model

The `models.NetflowMetric` struct has been updated:

```go
type NetflowMetric struct {
    // ... existing fields ...

    AsPath         []uint32  `json:"as_path,omitempty"`         // BGP AS path sequence
    BgpCommunities []uint32  `json:"bgp_communities,omitempty"` // BGP community values

    // ... metadata ...
}
```

## Ingestion Handler Updates

### Location

The ingestion handler that consumes protobuf FlowMessages from NATS and converts them to NetflowMetric structs needs to be updated.

**Expected locations:**
- NATS consumer service (Go or Elixir)
- Flow processor/transformer
- Message handler in backend service

### Required Changes

When converting `flowpb.FlowMessage` → `models.NetflowMetric`:

```go
// Pseudocode for ingestion handler
func convertFlowMessage(pbMsg *flowpb.FlowMessage) *models.NetflowMetric {
    metric := &models.NetflowMetric{
        // ... existing field mappings ...

        // NEW: Extract BGP AS path
        AsPath: pbMsg.AsPath,  // Direct copy - both are []uint32

        // NEW: Extract BGP communities
        BgpCommunities: pbMsg.BgpCommunities,  // Direct copy - both are []uint32
    }

    return metric
}
```

### Validation

Optional validation to add:

```go
// Limit AS path length (collector should already enforce, but defense in depth)
if len(pbMsg.AsPath) > 50 {
    metric.AsPath = pbMsg.AsPath[:50]
    log.Warn().Int("actual_length", len(pbMsg.AsPath)).Msg("AS path truncated to 50 ASNs")
}

// BGP communities are unlimited in the spec, but sanity check
if len(pbMsg.BgpCommunities) > 100 {
    log.Warn().Int("count", len(pbMsg.BgpCommunities)).Msg("Large number of BGP communities")
}
```

## Database Insert

The database insert logic has been updated in `pkg/db/cnpg_netflow.go`:

✅ `insertNetflowSQL` - includes `as_path` and `bgp_communities` columns
✅ `buildNetflowMetricArgs()` - converts []uint32 to []int32 for PostgreSQL

No further changes needed for database layer.

## Testing the Ingestion

### Test with Sample Data

```go
// Create test flow with BGP data
testFlow := &flowpb.FlowMessage{
    // ... basic flow fields ...

    AsPath: []uint32{64512, 64513, 64514},  // 3-hop path
    BgpCommunities: []uint32{
        0xFDE80064,  // 65000:100
        0xFDE800C8,  // 65000:200
    },
}

// Convert and store
metric := convertFlowMessage(testFlow)
err := db.StoreNetflowMetrics(ctx, []*models.NetflowMetric{metric})

// Verify in database
rows := db.Query("SELECT as_path, bgp_communities FROM netflow_metrics WHERE src_addr = $1", testSrcAddr)
// Expected: as_path = {64512,64513,64514}, bgp_communities = {4259840100,4259840200}
```

### Query Examples

```sql
-- Find flows traversing AS 64512
SELECT * FROM netflow_metrics WHERE as_path @> ARRAY[64512];

-- Find flows with BGP community 65000:100 (0xFDE80064 = 4259840100)
SELECT * FROM netflow_metrics WHERE bgp_communities @> ARRAY[4259840100];

-- Count flows by AS
SELECT unnest(as_path) AS asn, COUNT(*)
FROM netflow_metrics
WHERE as_path IS NOT NULL
GROUP BY asn
ORDER BY COUNT(*) DESC
LIMIT 10;
```

## Checklist

- [ ] Locate the NATS consumer / flow ingestion handler
- [ ] Add `AsPath` extraction from protobuf to NetflowMetric
- [ ] Add `BgpCommunities` extraction from protobuf to NetflowMetric
- [ ] Add optional validation for array sizes
- [ ] Test with sample IPFIX flows containing BGP data
- [ ] Verify data appears correctly in database
- [ ] Verify GIN indexes are being used for queries
