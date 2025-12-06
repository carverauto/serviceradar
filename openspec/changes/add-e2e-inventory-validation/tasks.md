## 1. Test Harness Implementation

- [x] Create `tests/e2e/inventory` package.
- [x] Implement `InventoryValidator` struct with DB and API clients. (Implemented as direct test function for simplicity)
- [x] Add `ValidateCanonicalCount(minCount int)` method. (Implemented as assertion in test)
- [x] Add `DiagnoseInventoryCollapse()` method to log top merge targets and tombstone chains.

## 2. Faker Integration

- [ ] Ensure Faker agent exposes a "Sync Status" metric or API endpoint we can poll.
- [x] Alternatively, implement a "wait for quiet" logic based on ingestion metrics. (Implemented `Eventually` poll on DB count)

## 3. Local/Dev Verification

- [ ] Create a runbook/script to run the test against `kubectl port-forward` of the demo environment.
- [ ] Verify it passes against the current fixed deployment.

## 4. CI Automation

- [ ] Define the CI job (GitHub Actions or BuildBuddy) to deploy the stack (if not using persistent fixture) and run the test.
