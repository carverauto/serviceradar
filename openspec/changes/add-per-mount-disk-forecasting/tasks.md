## 1. Aggregate
- [x] 1.1 Migration creating `platform.timeseries_metrics_disk_hourly` (continuous aggregate keyed by device, series key, mount point; sysmon.disk only) with refresh policy and indexes; helm `expectedVersion` updated.

## 2. SRQL
- [x] 2.1 Entity `timeseries_metric_disk_hourly`: filters (device_id, metric_name, mount_point, series_key, sample_count), time bounds, sort, limit; translation and execution tests.
- [x] 2.2 SRQL reference documents the entity.

## 3. Capacity source
- [x] 3.1 `disk_usage` source reads the entity keyed by device and mount, labelled "device / mount"; worker test with per-mount rows proves one forecast per mount and device-scoped resource ids.

## 4. Verification
- [ ] 4.1 CI: migration applies on the fixture lane; SRQL tests; worker tests.
- [ ] 4.2 Post-deploy on demo: per-mount rows appear in `capacity_forecasts` with mount labels; the device page still lists the device's forecasts.
