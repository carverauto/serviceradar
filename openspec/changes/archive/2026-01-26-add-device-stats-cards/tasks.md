# Tasks: Add Device Stats Cards

## 1. SRQL Rust Implementation

- [x] 1.1 Add `DeviceGroupField` enum in `devices.rs` (type, vendor_name, risk_level, is_available, gateway_id)
- [x] 1.2 Update `parse_stats_spec()` to extract GROUP BY field from query
- [x] 1.3 Implement `build_grouped_stats_query()` following `otel_metrics.rs` pattern (lines 356-409)
- [x] 1.4 Generate raw SQL with GROUP BY clause (Diesel doesn't support this directly)
- [x] 1.5 Return JSONB array: `[{ "field": value, "alias": count }, ...]`
- [x] 1.6 Add tests for grouped stats queries in devices module

## 2. SRQL Parser Updates (if needed)

- [x] 2.1 Verify parser handles `stats:count() as alias by field` syntax
- [x] 2.2 Add `group_field` to `StatsSpec` struct if not present
- [x] 2.3 Add parser tests for grouped stats syntax

## 3. Web-NG SRQL Catalog

- [x] 3.1 Add `stats_fields` to devices entity in `catalog.ex`
- [x] 3.2 Document which fields support grouping: type, vendor_name, risk_level, is_available, gateway_id

## 4. LiveView UI Layer

- [x] 4.1 Create `device_stats_cards` component in device_live/index.ex
  - Follow pattern from analytics_live/index.ex `stat_card` component
  - Use daisyUI styling with tone-based colors
- [x] 4.2 Add "Total Devices" stat card using `in:devices stats:count() as total`
- [x] 4.3 Add "Available" stat card using `in:devices is_available:true stats:count() as available`
- [x] 4.4 Add "Unavailable" stat card using `in:devices is_available:false stats:count() as unavailable`
- [x] 4.5 Add "By Type" stat card using `in:devices stats:count() as count by type` (top 5)
- [x] 4.6 Add "Top Vendors" stat card using `in:devices stats:count() as count by vendor_name` (top 5)
- [x] 4.7 Wire up stats loading in mount/handle_params using SRQL NIF
- [x] 4.8 Add async loading with skeleton placeholders
- [x] 4.9 Make stat cards clickable to filter the devices table

## 5. Testing

- [x] 5.1 Add Rust unit tests for devices GROUP BY queries
- [ ] 5.2 Add integration tests for SRQL grouped stats via NIF
- [ ] 5.3 Add LiveView tests for stats cards rendering

## 6. Documentation

- [ ] 6.1 Update SRQL documentation with new devices stats examples
- [ ] 6.2 Update device-inventory spec with stats requirements
