# Change: Add Device Stats Cards to Devices Dashboard

## Why

The devices dashboard currently shows only a paginated table of devices without any summary statistics. Operators need at-a-glance visibility into device inventory health: total counts, availability status breakdown, and vendor distribution. By extending SRQL with GROUP BY support for devices, users also gain a powerful reporting/search tool for custom device analytics.

Ref: GitHub Issue #2252

## What Changes

- **ADDED**: SRQL GROUP BY support for devices entity (Rust)
  - Enables: `in:devices stats:count() as count by type`
  - Enables: `in:devices stats:count() as count by vendor_name`
  - Enables: `in:devices stats:count() as count by risk_level`
  - Enables: `in:devices stats:count() as count by is_available`
- **ADDED**: LiveView stats cards component above the devices table
  - Uses SRQL queries to fetch stats (no custom API endpoint needed)
  - Total devices, available/unavailable breakdown, type distribution, vendor distribution
- **MODIFIED**: Devices index page to include stats cards header section

**Note**: No custom API endpoint needed - all stats are queryable via SRQL, giving users the same power for custom reporting.

## Impact

- Affected specs: `device-inventory`, `srql`
- Affected code:
  - `rust/srql/src/query/devices.rs` - Add GROUP BY support following otel_metrics pattern
  - `rust/srql/src/parser.rs` - May need minor parser updates for group field
  - `web-ng/lib/serviceradar_web_ng_web/live/device_live/index.ex` - Stats cards UI
  - `web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex` - Add stats_fields for devices
