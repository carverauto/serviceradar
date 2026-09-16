## Context

`timeseries_metrics_hourly` (bucket, device_id, metric_type, metric_name,
avg/min/max/count) is the only long-horizon aggregate the disk source can
read, and it has no series identity. The raw hypertable has `series_key` and
`tags.mount_point` but only 7 days of retention, which
`capacity-forecasting` forbids as a forecasting input. The interface hourly
aggregate (`timeseries_metrics_interface_hourly`) is keyed by series and shows
the pattern: a dedicated aggregate plus a dedicated SRQL entity.

## Goals / Non-Goals

- Goals: one forecast per (device, mount); no change to how device pages find
  a device's forecasts; no change to the forecasting math.
- Non-Goals: a generic per-series aggregate for every sysmon gauge (per-core
  CPU and per-process series would multiply rows for no consumer today);
  changing the device-level hourly aggregate.

## Decisions

- **Dedicated disk aggregate keyed by mount.** `GROUP BY bucket, device_id,
  metric_type, metric_name, series_key, tags->>'mount_point'`, filtered to
  `metric_type = 'sysmon.disk'`. Cardinality is mounts x hosts, small.
- **Dedicated SRQL entity, not a new `series:` mode.** The bucketed
  `timeseries_metrics` route is bound to the device aggregate; a separate
  entity keeps that route untouched and mirrors the interface precedent.
- **Resource id = device, resource key = device + mount, label = "device /
  mount".** `resource_key/2` joins key fields, `resource_id/2` takes the first
  present key field, so the existing worker needs no change for identity.
- **No baseline regeneration.** The schema baseline gate is a drift check; new
  migrations replay on top. Helm `expectedVersion` must move to the new
  migration version (`//helm/serviceradar:migrations_expected_version_test`).

## Risks / Trade-offs

- Seven days of history at cutover: the first week of per-mount forecasts can
  only label crossings inside ~14 days as within the cap; everything else is
  `exhaustion_beyond_history_cap` or `outside_forecast_horizon` with the
  crossing date, which is still more than the device average could say.
- Mounts that disappear leave a series that stops updating; the worker already
  records `insufficient_history` / stale windows for those.

## Migration Plan

- Migration adds the aggregate and its refresh policy; existing raw rows
  backfill the first refresh. Rollback drops the view. The source switch is
  code-only and rides the same release.
