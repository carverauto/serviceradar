## 1. Diagnostics
- [ ] 1.1 Add registry vs CNPG parity metrics/logs (raw vs processed vs skipped_non_canonical) and alerts when drift exceeds tolerance on faker-scale loads.
- [ ] 1.2 Emit AGE graph queue/backpressure timing metrics with traceability to registry batches (queue depth, wait time, timeout counts).
- [ ] 1.3 Capture capability ingestion gaps for service devices (e.g., ICMP on `k8s-agent`) with targeted warnings and counters.

## 2. Ingestion resilience
- [ ] 2.1 Decouple AGE graph writes from the synchronous registry path (fire-and-forget worker or callback) with bounded retries and fast failure when the queue is saturated.
- [ ] 2.2 Add guardrails so registry ingestion and capability snapshots proceed even when AGE is unhealthy; persist replay/backfill artifacts for skipped graph batches.
- [ ] 2.3 Harden non-canonical selection to avoid miscounts (large skipped_non_canonical bursts) and reconcile registry snapshots against CNPG totals.

## 3. Validation
- [ ] 3.1 Load-test with faker 50k devices and confirm inventory returns ~50,002 devices without repeated AGE timeouts or registry/CNPG drift.
- [ ] 3.2 Verify ICMP capability for `k8s-agent` appears in registry/UI under AGE backpressure and after recovery/replay.
- [ ] 3.3 Document runbook updates for detecting and clearing AGE-induced ingest stalls.
