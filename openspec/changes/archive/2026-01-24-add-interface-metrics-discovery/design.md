# Design: Interface Metrics Discovery

## Context

The SNMP mapper performs network discovery by walking interface tables on SNMP-enabled devices. While it successfully enumerates interfaces and their properties (ifIndex, ifDescr, ifSpeed, etc.), it does not record which monitoring metrics are available for each interface.

Users enabling metrics collection for an interface currently have no visibility into which OIDs will actually work. They must either:
1. Use predefined templates and hope they work
2. Manually test OIDs via SNMP tools
3. Experience polling failures when configuring unsupported OIDs

This enhancement adds OID probing during interface discovery to provide a capability-aware metrics selection experience.

## Goals / Non-Goals

**Goals:**
- Discover which standard interface metrics are available per interface
- Detect 64-bit counter support (ifHC* OIDs)
- Store discovered metrics in the interface record
- Enable UI to show only available metrics for selection

**Non-Goals:**
- Automatic OID configuration based on discovery
- Vendor-specific OID discovery
- Performance counter optimization
- Polling service changes

## Decisions

### Decision: Probe standard MIB-II OIDs only

We will probe only standard IF-MIB and IF-MIB extensions (RFC 2863). Vendor-specific OIDs (Cisco IOS-XE, Juniper, Arista EOS) are out of scope for this change.

**Rationale**: Standard OIDs work across all SNMP-enabled devices. Vendor discovery would require device identification logic and MIB databases.

**Alternatives considered:**
- Probe based on sysObjectID → vendor → known OIDs: Adds complexity, requires maintaining vendor mappings
- Full MIB walk: Too slow, returns thousands of OIDs

### Decision: Use SNMP GET for probing (not walk)

For each interface, we'll issue SNMP GET requests for specific OIDs (e.g., `.1.3.6.1.2.1.2.2.1.10.{ifIndex}` for ifInOctets). A successful response means the metric is available.

**Rationale**: GET is fast and deterministic. We know exactly which OIDs to probe.

**Alternatives considered:**
- SNMP GETNEXT: Could walk into unexpected OIDs
- Full ifTable walk with all columns: Too slow for many interfaces

### Decision: Store as JSONB array

Available metrics will be stored as a JSONB array on the interface record:

```json
{
  "available_metrics": [
    {"name": "ifInOctets", "oid": ".1.3.6.1.2.1.2.2.1.10", "data_type": "counter", "supports_64bit": true},
    {"name": "ifOutOctets", "oid": ".1.3.6.1.2.1.2.2.1.16", "data_type": "counter", "supports_64bit": true},
    {"name": "ifInErrors", "oid": ".1.3.6.1.2.1.2.2.1.14", "data_type": "counter", "supports_64bit": false}
  ]
}
```

**Rationale**: JSONB provides schema flexibility. New metrics can be added without migrations.

**Alternatives considered:**
- Separate `interface_metrics` junction table: Adds join complexity, migration overhead
- Bitmap flags: Less extensible, harder to add new metrics

### Decision: Prefer 64-bit counters when available

When both 32-bit (ifInOctets) and 64-bit (ifHCInOctets) counters are available, the UI should default to 64-bit. The `supports_64bit` flag indicates whether to use the HC (High Capacity) counter.

**Rationale**: 64-bit counters avoid wrap-around issues on high-speed interfaces.

## Data Flow

```
Interface Discovery (Go Mapper)
    │
    ├─► Walk ifTable → Get interface list
    │
    ├─► For each interface:
    │       │
    │       ├─► SNMP GET ifInOctets.{ifIndex}
    │       ├─► SNMP GET ifHCInOctets.{ifIndex}
    │       ├─► SNMP GET ifOutOctets.{ifIndex}
    │       ├─► ... (probe all standard OIDs)
    │       │
    │       └─► Build available_metrics list
    │
    └─► Publish DiscoveredInterface with available_metrics
            │
            ▼
    gRPC → Elixir Backend
            │
            ▼
    MapperResultsIngestor
            │
            └─► Persist to discovered_interfaces.available_metrics (JSONB)
                    │
                    ▼
            Interface Details UI
                    │
                    └─► Show dropdown filtered by available_metrics
```

## Risks / Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Probing slows discovery | Medium | Medium | Batch GET requests, limit concurrent probes |
| Device doesn't respond to all OIDs | High | Low | Timeout after 1s per OID, mark as unavailable |
| Too many interfaces to probe | Low | Medium | Add interface count limit (e.g., 1000) for probing |
| Stale metrics (device firmware changes) | Low | Low | Re-probe on manual refresh or periodic rediscovery |

## Migration Plan

1. **Backward compatibility**: Existing interfaces will have `null` available_metrics. UI will show "Unknown" and allow manual OID configuration.

2. **No data migration needed**: New field is nullable, existing records remain valid.

3. **Rollback**: If issues arise, set `available_metrics` to null and revert UI to manual mode.

## Open Questions

1. **Probing frequency**: Should we re-probe metrics on every discovery scan or only on first discovery / manual refresh?
   - Proposed: Only on first discovery or manual "Refresh Capabilities" button

2. **Timeout values**: What's the appropriate timeout for OID probes?
   - Proposed: 1 second per OID, 5 seconds total per interface

3. **Maximum interfaces to probe**: Should we limit probing to prevent very long discovery times?
   - Proposed: Probe first 1000 interfaces, skip probing for excess
