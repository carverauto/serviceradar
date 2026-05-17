## 1. Implementation
- [ ] 1.1 Audit device create/import/update paths that set `is_managed` or `is_active`.
- [ ] 1.2 Update new-device create/import defaults so authoritative imports create devices with `is_managed = true` and `is_active = true`.
- [ ] 1.3 Update re-import/upsert paths to preserve existing `is_managed` and `is_active` values unless an operator action or explicit source-owned action changes them.
- [ ] 1.4 Keep `mark_active` and `mark_inactive` scoped to `is_active` only.
- [ ] 1.5 Confirm active managed usage counts remain `is_managed = true AND is_active = true`.
- [ ] 1.6 Add regression tests covering new imports, re-import preservation, operator inactive/active actions, and active managed usage counts.
- [ ] 1.7 Validate focused Elixir and SRQL checks touched by the changed paths.
