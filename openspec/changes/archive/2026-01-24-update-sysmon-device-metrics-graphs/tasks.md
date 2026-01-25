## 1. Implementation
- [x] 1.1 Identify the current sysmon SRQL queries powering CPU, memory, and disk charts in the device detail view.
- [x] 1.2 Update CPU chart query/transform to return utilization percent (0-100) and expose the current value for a header gauge.
- [x] 1.3 Update memory chart query/transform to return used and available memory series.
- [x] 1.4 Update disk chart query/transform to group by disk/partition (mount/device) and return utilization (used vs total) instead of file entries.
- [x] 1.5 Update UI components to render the corrected labels/units and the CPU header gauge.
- [x] 1.6 Add/update tests or fixtures for sysmon device detail charts (CPU/memory/disk).
