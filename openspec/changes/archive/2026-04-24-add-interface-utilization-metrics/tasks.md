# Tasks: Add Interface Utilization Metrics

## 1. Interface Speed Data
- [x] 1.1 Verify SRQL interfaces query returns `if_speed` or `speed_bps` field
- [x] 1.2 Add `if_speed` to Ash Interface resource if not present (already exists)
- [x] 1.3 Update interface discovery to capture and persist `ifSpeed` from SNMP (already implemented)

## 2. Percentage-Based Thresholds (Data Model)
- [x] 2.1 Add `threshold_type` field to `InterfaceSettings` metric thresholds (using existing map - no schema change)
- [x] 2.2 Add migration via `mix ash.codegen add_threshold_type` (not needed - uses existing map field)
- [ ] 2.3 Default new thresholds to percentage type when interface has speed data (UI logic)

## 3. Threshold Evaluation
- [x] 3.1 Update `InterfaceThresholdWorker` to resolve interface speed for threshold evaluation
- [x] 3.2 Add percentage-to-absolute conversion: `threshold_value * (if_speed / 8) / 100`
- [x] 3.3 Handle missing `if_speed` gracefully (fall back to absolute comparison or skip)
- [x] 3.4 Add utilization percentage to generated event metadata

## 4. Event/Alert Integration
- [x] 4.1 Create events when utilization exceeds threshold (e.g., "Inbound utilization > 50%")
- [x] 4.2 Include `utilization_percent`, `threshold_percent`, `if_speed_bps` in event payload
- [x] 4.3 Support duration-based alert promotion (already existed - duration_seconds support)

## 5. Combined Multi-Series Charts
- [x] 5.1 Add `chart_mode` option to timeseries plugin (single/combined)
- [x] 5.2 Implement combined chart rendering with multiple series on same Y-axis
- [x] 5.3 Add series legend showing both metrics with distinct colors
- [x] 5.4 Scale Y-axis to interface speed when available
- [x] 5.5 Fix viz series grouping (pass full SRQL response with viz to Engine.build_panels)

## 6. UI Updates
- [x] 6.1 Add threshold type toggle (absolute/percentage) in interface threshold config
- [x] 6.2 Show percentage input (0-100) when percentage type selected (with interface speed context)
- [x] 6.3 Add drag-and-drop metric grouping for composite charts (group compatible metrics together)
- [x] 6.4 Update interface details page to use combined chart when enabled
- [x] 6.5 Show utilization badge on interface cards (already implemented)

## 7. Tests
- [x] 7.1 Unit tests for percentage threshold evaluation with various if_speed values
- [x] 7.2 Unit tests for combined chart path generation
- [ ] 7.3 Integration test for event creation from percentage threshold breach (requires DB)
