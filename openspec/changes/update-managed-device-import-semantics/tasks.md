## 1. Implementation
- [x] 1.1 Audit device create/import/update paths that set `is_managed` or `is_active`.
- [x] 1.2 Update new-device create/import defaults so authoritative imports create devices with `is_managed = true` and `is_active = true`.
- [x] 1.3 Update re-import/upsert paths to preserve existing `is_managed` and `is_active` values unless an operator action or explicit source-owned action changes them.
- [x] 1.4 Keep `mark_active` and `mark_inactive` scoped to `is_active` only.
- [x] 1.5 Confirm active managed usage counts remain `is_managed = true AND is_active = true`.
- [x] 1.6 Update SRQL `in:devices` defaults so inactive devices are excluded unless `is_active` is explicitly filtered or inventory callers use `include_inactive:true`.
- [x] 1.7 Exclude inactive devices from sweep/SNMP/baseline polling target compilation and camera relay source selection.
- [x] 1.8 Add regression tests covering new imports, re-import preservation, operator inactive/active actions, active managed usage counts, SRQL defaults, and operational target exclusion.
- [x] 1.9 Validate focused Elixir and SRQL checks touched by the changed paths.
