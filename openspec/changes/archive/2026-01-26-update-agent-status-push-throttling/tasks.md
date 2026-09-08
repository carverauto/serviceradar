## 1. Implementation
- [x] 1.1 Define configuration fields for status push debounce/heartbeat (if not already present)
- [x] 1.2 Track last-pushed status signature and suppress unchanged pushes
- [x] 1.3 Ensure sweep status changes (sequence/execution ID) trigger pushes promptly
- [x] 1.4 Add tests/fixtures covering unchanged status suppression and heartbeat push
- [x] 1.5 Update logs to avoid info-level spam for unchanged status
