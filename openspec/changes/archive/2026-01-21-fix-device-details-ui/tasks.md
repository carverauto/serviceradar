## 1. Implementation
- [x] Locate the device detail view and sysmon metrics rendering in web-ng
- [x] Add gating so sysmon metrics panels render only when the device has sysmon metrics data or sysmon status
- [x] Update sysmon CPU, memory, and disk views to use graph visualizations instead of tables
- [x] Remove or disable the auto visualization for "Categories: type_id by modified"
- [ ] Add or update UI tests/fixtures for device detail sysmon panels (if coverage exists)

## 2. Validation
- [ ] Confirm a non-sysmon device detail page shows no sysmon metrics section
- [ ] Confirm CPU, memory, and disk sysmon metrics render as graphs for sysmon devices
- [ ] Confirm the "Categories: type_id by modified" visualization no longer appears by default
