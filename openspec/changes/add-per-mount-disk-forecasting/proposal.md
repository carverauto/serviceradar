# Change: Forecast disk capacity per mount point

## Why

The `disk_usage` capacity source reads the device-level hourly aggregate
(`timeseries_metrics_hourly`), which groups by device, metric type and metric
name only, so every mount point on a host is averaged into one series. A single
filesystem filling up is diluted by every other mount on the box and cannot
surface as a runway finding. The interface path already keeps a series-keyed
hourly aggregate; disk needs the same.

## What Changes

- A new continuous aggregate `platform.timeseries_metrics_disk_hourly` keyed
  by device, series key and the `mount_point` tag, restricted to `sysmon.disk`,
  with avg/min/max/sample_count per hour and the same refresh cadence as the
  interface hourly aggregate. Helm `expectedVersion` moves to it.
- A new SRQL entity `timeseries_metric_disk_hourly` mirroring
  `timeseries_metric_interface_hourly`: device, metric, mount and series
  filters, time bounds, sort, limit, plain rows.
- The `disk_usage` capacity source reads that entity keyed by device and mount
  (`key_fields: ["device_id", "mount_point"]`, label "device / mount"). The
  resource id stays the device so device pages keep filtering correctly.
- Docs: SRQL reference lists the entity; the anomaly-detection page notes
  per-mount runway and the ramp-up.

## Impact

- Affected specs: `capacity-forecasting`
- Affected code: `elixir/serviceradar_core/priv/repo/migrations/`,
  `helm/serviceradar/values.yaml`, `rust/srql/src/query/timeseries_metrics.rs`
  (plus entity registration), `elixir/serviceradar_core/lib/serviceradar/observability/capacity_forecasting/source.ex`,
  docs.
- Ramp-up: raw retention is 7 days, so per-mount history starts at 7 days and
  grows; the first per-mount forecasts appear after 24 hourly buckets and the
  history-relative extrapolation cap widens with time. Device-averaged rows keep
  their old resource keys and age out of the 24-hour runway view.
