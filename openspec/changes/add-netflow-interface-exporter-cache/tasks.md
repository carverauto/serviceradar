## 1. Spec And Design
- [x] 1.1 Confirm the cache table names and key columns (`sampler_address`, `if_index`)
- [x] 1.2 Confirm inventory sources for interface speed/name and exporter naming

## 2. Database (Migrations)
- [x] 2.1 Add `platform.netflow_exporter_cache`
- [x] 2.2 Add `platform.netflow_interface_cache`
- [x] 2.3 Add indexes for lookup by `sampler_address` and `(sampler_address, if_index)`

## 3. Core (Ash + Jobs)
- [x] 3.1 Add Ash resources for the cache tables
- [x] 3.2 Add Oban worker to refresh exporter cache from inventory on schedule
- [x] 3.3 Add Oban worker to refresh interface cache from inventory on schedule

## 4. SRQL (Flows)
- [x] 4.1 Add flow dimensions/filters for exporter metadata (`exporter_name`)
- [x] 4.2 Add flow dimensions/filters for interface metadata (`in_if_name`, `out_if_name`, `in_if_speed_bps`, `out_if_speed_bps`)
- [x] 4.3 Ensure downsample `series:` supports new dimensions where applicable

## 5. Web-NG UI
- [x] 5.1 Add new dims to the `/netflow` dimension picker list in a stable order
- [x] 5.2 Add hover hints for interface dims (explain join keys and availability)

## 6. Validation
- [x] 6.1 Run `openspec validate add-netflow-interface-exporter-cache --strict`
- [x] 6.2 Run repo checks (`make lint`, `make test`)
