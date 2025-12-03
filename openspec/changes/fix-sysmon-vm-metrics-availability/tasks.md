## 1. Investigation
- [x] 1.1 Confirm current sysmon-vm enrollment/health (darwin/Compose mTLS path), capture sysmon-vm/poller/core logs, and note device IDs/endpoints in use. _Finding: sysmon-vm was connected and delivering CPU metrics for `sr:88239dc2-7208-4c24-a396-3f868c2c9419`, but memory/disk/process metrics were never emitted by the checker, so CNPG tables were empty and the UI/Next route returned null/500 for memory._
- [x] 1.2 Trace sysmon metrics flow (collector → poller → core → CNPG → `/api/sysmon`/UI) to isolate where data drops (e.g., target mapping, ingestion failure, query filtering).

## 2. Fix & instrumentation
- [x] 2.1 Implement the pipeline fix so connected sysmon-vm collectors persist CPU/memory/time-series metrics for their target device again (include any needed target identity mapping guards).
- [x] 2.2 Add detection/logging/metrics when sysmon collectors remain connected but metrics stop arriving or cannot be written/queryable; surface actionable signals (events/alerts/health markers) instead of empty panels.

## 3. Validation
- [x] 3.1 Add regression coverage for sysmon-vm → poller/core → CNPG write → `/api/sysmon` query (unit/integration as appropriate).
- [ ] 3.2 Manual E2E: run darwin/arm64 sysmon-vm against Compose poller with mTLS, verify metrics appear in CNPG and UI `/api/sysmon` panels within one polling interval.
