## 1. Dependency and Runtime Strategy
- [ ] 1.1 Update `rust/bmp-collector` to consume `arancini-lib` as an external dependency (crate release or pinned git revision).
- [ ] 1.2 Remove or gate NDJSON-only ingestion as non-production test mode; implement live BMP socket ingest as the primary path.
- [ ] 1.3 Document the external dependency policy so `arancini` remains standalone and not monorepo-owned.

## 2. Publish Contract Compatibility
- [ ] 2.1 Keep JetStream stream and subjects compatible with Broadway (`BMP_CAUSAL`, `bmp.events.>`).
- [ ] 2.2 Ensure published envelopes include fields required by `causal_signals` normalization and routing correlation.
- [ ] 2.3 Add/refresh tests verifying event-type to subject mapping (`peer_up`, `peer_down`, `route_update`, `route_withdraw`, `stats`).

## 3. Performance and Reliability
- [ ] 3.1 Add backpressure and publish-ack timeout handling for burst BMP input.
- [ ] 3.2 Add benchmark/fixture validation for sustained BMP bursts and publish latency telemetry.
- [ ] 3.3 Verify reconnect/retry behavior for transient NATS failures without message-contract corruption.

## 4. Deployment Wiring
- [ ] 4.1 Add Docker Compose service wiring/config for BMP collector consistent with other external collectors.
- [ ] 4.2 Add image/build target wiring for BMP collector in the existing packaging pipeline.
- [ ] 4.3 Document local/dev and demo runbook steps for enabling BMP ingest.

## 5. Validation
- [ ] 5.1 Run collector unit/integration tests for BMP decode + publish contract.
- [ ] 5.2 Run Broadway/EventWriter tests covering BMP causal ingestion compatibility.
- [ ] 5.3 Run `openspec validate refactor-bmp-collector-to-arancini --strict`.
