## 1. Implementation
- [ ] 1.1 Add or confirm `ocsf_devices.is_active` schema/resource field with default `true` and migration coverage.
- [ ] 1.2 Add Ash actions and authorization for marking devices active/inactive.
- [ ] 1.3 Update device list/details UI to display active state and provide in/out-of-service controls.
- [ ] 1.4 Update inventory/license count helpers to exclude inactive devices from active inventory totals.
- [ ] 1.5 Update event and alert promotion paths to suppress device-scoped operational events/alerts for inactive devices.
- [ ] 1.6 Preserve raw telemetry/log ingestion and historical visibility for inactive devices.
- [ ] 1.7 Add regression tests for authorization, UI state, inventory counts, and event/alert suppression.
