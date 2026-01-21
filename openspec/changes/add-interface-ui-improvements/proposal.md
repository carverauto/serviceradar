# Change: Interface UI Improvements

## Why

The current interfaces table and device details view lack key usability features that users need for effective network interface management. Users cannot select interfaces for bulk operations, view detailed interface information, or enable metrics collection directly from the UI. The status column shows raw values instead of human-friendly indicators, and there's no way to favorite important interfaces for quick access to their metrics.

## What Changes

- **Interfaces Table Enhancements**
  - Add row selection for bulk operations
  - Add bulk edit feature for selected interfaces
  - Add favorite/star icon column with click-to-toggle
  - Add interface ID column
  - Add metrics collection indicator icon (clickable to details)
  - Improve status column with colorized labels/icons (color-blind accessible)
  - Map `ethernetCsmacd` and other interface types to human-readable names

- **Interface Details Screen** (new)
  - Create dedicated interface details page
  - Display OID information
  - Enable/disable metrics collection toggle
  - Show interface properties and configuration

- **Metrics & Visualization**
  - Display auto-viz graphs for favorited interfaces with metrics collection enabled
  - Render appropriate visualization based on metric type (gauge, counter, etc.)

- **Alerting Integration**
  - Add threshold configuration on utilization metrics
  - Generate events when thresholds are exceeded
  - Create alerts on events using existing alert editor UI from settings

## Impact

- Affected specs: `build-web-ui`
- Affected code:
  - `web-ng/lib/serviceradar_web/live/devices/` - device details LiveView
  - `web-ng/lib/serviceradar_web/components/` - interface table components
  - `elixir/serviceradar_core/lib/serviceradar/inventory/` - interface Ash resources
  - Potentially `observability-rule-management` for threshold/alert integration
