## 1. Spec And Design
- [ ] 1.1 Confirm the cache table names and key columns (`sampler_address`, `if_index`)
- [ ] 1.2 Confirm inventory sources for interface speed/name and exporter naming

## 2. Database (Migrations)
- [ ] 2.1 Add `platform.netflow_exporter_cache`
- [ ] 2.2 Add `platform.netflow_interface_cache`
- [ ] 2.3 Add indexes for lookup by `sampler_address` and `(sampler_address, if_index)`

## 3. Core (Ash + Jobs)
- [ ] 3.1 Add Ash resources for the cache tables
- [ ] 3.2 Add Oban worker to refresh exporter cache from inventory on schedule
- [ ] 3.3 Add Oban worker to refresh interface cache from inventory on schedule

## 4. SRQL (Flows)
- [ ] 4.1 Add flow dimensions/filters for exporter metadata (`exporter_name`)
- [ ] 4.2 Add flow dimensions/filters for interface metadata (`in_if_name`, `out_if_name`, `in_if_speed_bps`, `out_if_speed_bps`)
- [ ] 4.3 Ensure downsample `series:` supports new dimensions where applicable

## 5. Web-NG UI
- [ ] 5.1 Add new dims to the `/netflow` dimension picker list in a stable order
- [ ] 5.2 Add hover hints for interface dims (explain join keys and availability)

## 6. Validation
- [ ] 6.1 Run `openspec validate add-netflow-interface-exporter-cache --strict`
- [ ] 6.2 Run repo checks (`make lint`, `make test`)

