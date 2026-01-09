## 1. Implementation
- [x] 1.1 Add a supervised task pool for sync ingestion work
- [x] 1.2 Dispatch sync result ingestion per chunk to the task pool (non-blocking StatusHandler)
- [x] 1.3 Process sync batches concurrently with a configurable max concurrency
- [x] 1.4 Replace create/update split with conflict-safe bulk upsert for devices
- [x] 1.5 Ensure audit event inserts encode UUIDs correctly

## 2. Tests
- [ ] 2.1 Add/extend sync ingestion tests to cover parallel batch processing
- [ ] 2.2 Add regression test for device upsert under concurrent batches
- [ ] 2.3 Add audit writer UUID encoding test
