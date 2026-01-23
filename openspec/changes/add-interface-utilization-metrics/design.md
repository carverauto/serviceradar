# Design: Interface Utilization Metrics

## Context
Interface traffic metrics from SNMP (ifInOctets, ifOutOctets) are cumulative byte counters. We already implemented rate calculation (`agg:rate`) to convert these to bytes/second. However, operators need to:
1. Set thresholds as percentage of interface capacity (not absolute values)
2. See inbound/outbound traffic together for comparison
3. Understand utilization at a glance (badge showing %)

## Goals
- Support percentage-based thresholds using interface speed (ifSpeed)
- Render combined inbound+outbound charts with shared Y-axis
- Display utilization percentage prominently in UI

## Non-Goals
- Complex utilization forecasting/trending (future work)
- Bandwidth shaping or QoS configuration
- Historical utilization reports

## Decisions

### Decision: Threshold Type Field
Store threshold type as an enum field in the metric threshold configuration.

**Schema addition to InterfaceSettings:**
```elixir
# In metric_thresholds JSONB map
%{
  "ifInOctets" => %{
    "threshold_type" => "percentage",  # or "absolute"
    "threshold_value" => 50,           # 50% or 50000000 bytes/sec
    "event_enabled" => true,
    "alert_enabled" => true,
    "alert_duration_minutes" => 60
  }
}
```

**Rationale**: Keeping both types allows operators who prefer absolute values to continue using them, while new users can use intuitive percentages.

### Decision: Threshold Evaluation Flow
```
1. Load interface settings with thresholds
2. For each metric with threshold:
   a. Get current metric value (bytes/sec from rate aggregation)
   b. If threshold_type == "percentage":
      - Fetch interface.if_speed (bps)
      - If no if_speed, skip with warning
      - effective_threshold = if_speed / 8 * threshold_value / 100
   c. Else: effective_threshold = threshold_value
   d. Compare current value to effective_threshold
   e. Generate event if breached
```

### Decision: Combined Chart Implementation
Add a `chart_mode` parameter to the timeseries plugin:
- `single` (default): One chart per series (current behavior)
- `combined`: Multiple series on same chart

**Y-axis scaling priority:**
1. If `max_speed_bytes_per_sec` provided → use as Y-axis max
2. Else → auto-scale to max value in data

**Series colors for combined chart:**
- Inbound: Primary color (blue)
- Outbound: Secondary color (green)
- Both use gradient fills with lower opacity for overlap visibility

### Decision: Interface Speed Source
Use existing `if_speed` field from SNMP interface discovery. This is already polled via ifSpeed OID (1.3.6.1.2.1.2.2.1.5) in standard interface MIBs.

**Conversion:**
- ifSpeed returns bits/second
- Store as bits/second in database
- Convert to bytes/second for threshold evaluation: `if_speed_bps / 8`

## Risks / Trade-offs

### Risk: Missing ifSpeed Data
Some devices don't report ifSpeed (especially virtual interfaces).

**Mitigation:**
- Skip percentage threshold evaluation gracefully
- Show warning in UI when configuring percentage threshold without speed data
- Allow manual speed override in interface settings (future enhancement)

### Risk: ifSpeed Inaccuracy
Some devices report ifSpeed as 0 or incorrect values (e.g., reporting 10M for a 1G interface).

**Mitigation:**
- Validate ifSpeed > 0 before using
- Consider using ifHighSpeed (1.3.6.1.2.1.31.1.1.1.15) for high-speed interfaces
- Future: allow manual speed correction in settings

## Migration Plan
1. No data migration needed - new field with default behavior
2. Existing absolute thresholds continue to work unchanged
3. New UI enables percentage option for new configurations

## Open Questions
- Should we support ifHighSpeed (64-bit counter) for >2Gbps interfaces?
- Should combined charts be the default or opt-in?
