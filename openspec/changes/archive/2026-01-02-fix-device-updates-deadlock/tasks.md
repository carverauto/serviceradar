## 1. Write Serialization
- [x] 1.1 Add `deviceUpdatesMu *sync.Mutex` field to `pkg/db/db.go` DB struct
- [x] 1.2 Wrap `cnpgInsertDeviceUpdates` batch execution with mutex in `pkg/db/cnpg_unified_devices.go`
- [x] 1.3 Wrap `UpsertDeviceIdentifiers` batch execution with mutex in `pkg/db/cnpg_identity_reconciliation_upserts.go`
- [x] 1.4 Wrap `StoreNetworkSightings` batch execution with mutex in `pkg/db/cnpg_identity_reconciliation.go`

## 2. Transient Error Handling
- [x] 2.1 Create `classifyCNPGError()` function in `pkg/db/cnpg_device_updates_retry.go` to detect transient errors (40P01, 40001, XX000, 57014)
- [x] 2.2 Implement `sendCNPGWithRetry()` wrapper function with configurable max attempts
- [x] 2.3 Add exponential backoff with jitter for deadlock errors (500ms base, configurable via env)
- [x] 2.4 Update `sendCNPG()` calls in device-related operations to use new retry wrapper

## 3. Metrics
- [x] 3.1 Add `cnpgDeadlockTotal` counter in `pkg/db/cnpg_device_updates_metrics.go`
- [x] 3.2 Add `cnpgRetryTotal` counter metric
- [x] 3.3 Add `cnpgRetrySuccessTotal` counter metric
- [x] 3.4 Instrument retry logic to record metrics on each deadlock/retry event

## 4. Configuration
- [x] 4.1 Add `CNPG_DEADLOCK_BACKOFF_MS` environment variable (default: 500)
- [x] 4.2 Add `CNPG_MAX_RETRY_ATTEMPTS` environment variable (default: 3)
- [ ] 4.3 Document new environment variables in deployment docs

## 5. Testing
- [x] 5.1 Add unit test for `classifyCNPGError()` with all transient SQLSTATE codes
- [x] 5.2 Add unit test for backoff calculation with jitter
- [ ] 5.3 Add integration test simulating concurrent device update batches

## 6. Verification
- [ ] 6.1 Deploy to demo environment
- [ ] 6.2 Monitor for deadlock errors in logs for 24 hours
- [ ] 6.3 Verify new metrics are being recorded
- [ ] 6.4 Confirm no performance regression in device update throughput
