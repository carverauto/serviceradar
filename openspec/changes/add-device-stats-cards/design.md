## Context

The devices dashboard needs summary statistics (total count, availability breakdown, vendor distribution). Rather than creating a separate API endpoint and pre-computed CAGGs, we extend SRQL with GROUP BY support for devices. This gives users a powerful reporting/search tool while powering the dashboard stats.

**Stakeholders**: Operators viewing the devices dashboard, users creating custom reports via SRQL.

**Constraints**:
- SRQL is the canonical query interface - avoid bypassing it
- SRQL is Rust, called via Rustler NIF from web-ng
- Must follow existing patterns in `otel_metrics.rs` for GROUP BY

## Goals / Non-Goals

**Goals**:
- Enable `in:devices stats:count() as count by field` queries
- Power dashboard stats cards with SRQL queries
- Give users flexible device analytics via SRQL
- Follow established SRQL patterns (no hacks)

**Non-Goals**:
- Pre-computed CAGGs (SRQL queries are fast enough for dashboard use)
- Custom API endpoints (SRQL handles this)
- Historical stats trending (future enhancement)

## Decisions

### Decision 1: Extend SRQL with GROUP BY for Devices

**What**: Add GROUP BY support to `devices.rs` following the `otel_metrics.rs` pattern.

**Why**:
- SRQL is the canonical query interface - users expect it to work
- Pattern already exists and is proven (otel_metrics, logs)
- No new API surface area to maintain
- Users get the same power for custom reports

**Implementation approach**:
- Add `DeviceGroupField` enum for supported grouping fields
- Build raw SQL with GROUP BY (Diesel doesn't support this directly)
- Return JSONB array with field value and count

### Decision 2: No CAGGs Needed Initially

**What**: Use direct SRQL queries against `ocsf_devices` table without pre-computed aggregates.

**Why**:
- Device counts are simple aggregations, not time-series rollups
- Table has indexes on key fields (tenant_id, type_id, vendor_name, etc.)
- Can add CAGGs later if performance becomes an issue at scale
- Simpler implementation with fewer moving parts

**Trade-off**: Queries hit the table directly. If this becomes slow at 100k+ devices, we can add a CAGG and have SRQL query it instead.

### Decision 3: Stats Cards Use Parallel SRQL Queries

**What**: Dashboard loads stats via multiple parallel SRQL queries.

**Why**:
- Each stat card is independent
- Parallel queries complete faster than sequential
- Failures are isolated (one card can fail without breaking others)
- Same pattern used in analytics page

## SRQL Query Examples

**Simple counts (already working):**
```
in:devices stats:count() as total
in:devices is_available:true stats:count() as available
in:devices is_available:false stats:count() as unavailable
```

**Grouped stats (new capability):**
```
in:devices stats:count() as count by type
// Returns: [{"type": "Server", "count": 45}, {"type": "Router", "count": 23}, ...]

in:devices stats:count() as count by vendor_name
// Returns: [{"vendor_name": "Cisco", "count": 200}, {"vendor_name": "Dell", "count": 150}, ...]

in:devices stats:count() as count by risk_level
// Returns: [{"risk_level": "High", "count": 50}, {"risk_level": "Low", "count": 1000}, ...]

in:devices stats:count() as count by is_available
// Returns: [{"is_available": true, "count": 950}, {"is_available": false, "count": 50}]
```

**Combined filters + grouping:**
```
in:devices vendor_name:Cisco stats:count() as count by type
// Returns Cisco devices grouped by type
```

## Implementation Details

### Rust Changes (devices.rs)

```rust
// New enum for groupable fields
#[derive(Debug, Clone, PartialEq)]
pub enum DeviceGroupField {
    Type,
    VendorName,
    RiskLevel,
    IsAvailable,
    GatewayId,
}

impl DeviceGroupField {
    fn from_str(s: &str) -> Option<Self> {
        match s {
            "type" | "device_type" => Some(Self::Type),
            "vendor_name" | "vendor" => Some(Self::VendorName),
            "risk_level" => Some(Self::RiskLevel),
            "is_available" | "available" => Some(Self::IsAvailable),
            "gateway_id" => Some(Self::GatewayId),
            _ => None,
        }
    }

    fn sql_column(&self) -> &'static str {
        match self {
            Self::Type => "COALESCE(type, 'Unknown')",
            Self::VendorName => "COALESCE(vendor_name, 'Unknown')",
            Self::RiskLevel => "COALESCE(risk_level, 'Unknown')",
            Self::IsAvailable => "COALESCE(is_available, false)",
            Self::GatewayId => "gateway_id",
        }
    }
}
```

### SQL Generation Pattern

Following `otel_metrics.rs` lines 381-406:

```sql
SELECT jsonb_build_object(
    'type', COALESCE(type, 'Unknown'),
    'count', COUNT(*)
) AS payload
FROM ocsf_devices
WHERE tenant_id = $1
GROUP BY COALESCE(type, 'Unknown')
ORDER BY COUNT(*) DESC
LIMIT 20
```

### UI Stats Cards

```
┌─────────────┬─────────────┬─────────────┬─────────────┬─────────────┐
│   Total     │  Available  │ Unavailable │  By Type    │ Top Vendors │
│   52,341    │   51,200    │    1,141    │  Server: 15k│  Cisco: 20k │
│             │    97.8%    │    ⚠️ 2.2%  │  Switch: 12k│  Dell: 15k  │
│             │             │             │  Router: 8k │  HP: 10k    │
└─────────────┴─────────────┴─────────────┴─────────────┴─────────────┘
```

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Query performance at scale | Add indexes; can add CAGG later if needed |
| GROUP BY adds Rust complexity | Follow existing otel_metrics pattern exactly |
| Multiple parallel queries | Use Task.async_stream with timeout |

## Migration Plan

1. Implement SRQL GROUP BY support in Rust
2. Add tests for new query syntax
3. Update web-ng catalog with stats_fields
4. Implement UI stats cards
5. Deploy and monitor query performance

**Rollback**: Remove UI component; SRQL changes are additive and backward-compatible.

## Open Questions

- [ ] Should we limit GROUP BY results (e.g., top 20 vendors)? → Yes, add LIMIT 20 to prevent unbounded results
- [ ] Do we need ORDER BY count DESC? → Yes, show most common first
