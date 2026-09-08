## 1. Implementation
- [x] 1.1 Add or confirm `ocsf_devices.is_active` schema/resource field with default `true` and migration coverage.
- [x] 1.2 Add Ash actions and authorization for marking devices active/inactive.
- [x] 1.3 Update device list/details UI to display active state and provide in/out-of-service controls.
- [x] 1.4 Update inventory/license count helpers to exclude inactive devices from active inventory totals.
- [x] 1.5 Update event and alert promotion paths to suppress device-scoped operational events/alerts for inactive devices.
- [x] 1.6 Preserve raw telemetry/log ingestion and historical visibility for inactive devices.
- [x] 1.7 Add regression tests for authorization, UI state, inventory counts, and event/alert suppression.
