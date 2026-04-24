## 1. Implementation
- [x] 1.1 Confirm which device details queries are on the default tab critical path and which are edit-only or tab-specific.
- [x] 1.2 Stop loading profile-only and edit-only data during the initial device details render.
- [x] 1.3 Reduce discovery job lookup scope so device details do not scan the entire mapper job table.
- [x] 1.4 Parallelize independent sysmon presence and metric section probes where safe.
- [x] 1.5 Reduce the LiveView fallback wait so failed websocket upgrades do not add seconds to page mount.
- [x] 1.6 Run focused validation for the updated device details load path.
