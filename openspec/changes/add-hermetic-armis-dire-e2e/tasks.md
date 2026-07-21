## 1. Faker test profile

- [x] 1.1 Add deterministic generation/churn configuration for standalone E2E
  runs without changing the 50,000-device production/demo default.
- [x] 1.2 Add readiness and deterministic fixture/churn controls, with tests for
  startup, reset, pagination, and IP cardinality.
- [x] 1.3 Update faker documentation to describe the fast and 50,000-device
  E2E profiles and correct the stale device-count references.

## 2. Real Armis fixture producer

- [x] 2.1 Add a test-only Go producer that invokes the real Armis sync driver
  against faker and emits normalized page/chunk fixtures with run metadata.
- [x] 2.2 Assert the producer sees every faker device across page boundaries,
  preserves typed `armis_device_id`, and never loses a page after a churn cycle.
- [x] 2.3 Add Bazel/Go test targets and keep the producer out of production
  images and runtime service registration.

## 3. Closed-loop core E2E

- [x] 3.1 Add a database-backed `armis_dire_e2e` ExUnit suite that consumes the
  producer output and ingests discovery through the core results/update path.
- [x] 3.2 Feed deterministic ICMP and TCP sweep payloads through the existing
  sweep/results ingestor and assert canonical availability for every fixture.
- [x] 3.3 Create the integration source against the local faker endpoint and
  run the real Armis northbound runner against the faker bulk endpoint.
- [x] 3.4 Assert clean-run equations: source devices = typed candidates =
  successful northbound operations, with one operation per Armis ID and no
  missing IDs.

## 4. Identity regression matrix

- [x] 4.1 Cover active-IP/DHCP churn and prove typed identity remains attached
  to the same canonical device.
- [x] 4.2 Cover stale generic Armis bridges and verify they cannot create or
  redirect a northbound candidate.
- [x] 4.3 Cover metadata/typed-ID disagreement, duplicate typed IDs, and a
  typed ID represented on multiple devices; assert the expected conflict
  category and deliberate skip only.
- [x] 4.4 Cover source scoping with the same numeric identifier in two sources
  and prove there is no cross-source merge or outbound leakage.
- [x] 4.5 Apply the safe repair path, rerun the worker, and assert repaired
  devices update while ambiguous devices remain withheld and visible.
- [x] 4.6 Rerun the same clean fixture to verify idempotent DIRE identifiers,
  stable cardinality, and one northbound operation per device per run.

## 5. Oban/manual execution and diagnostics

- [x] 5.1 Enqueue and perform `ArmisNorthboundRunWorker` through Oban test mode,
  covering the manual “run now” execution path and persisted run status.
- [x] 5.2 Assert `updated_count`, `skipped_count`, `error_count`, conflict
  categories, and faker-captured operations reconcile without row-count
  inflation.
- [x] 5.3 On failure, preserve faker logs, fixture JSONL, captured updates,
  identity summaries, and database run metadata in a temporary artifact path.

## 6. Hermetic orchestration and CI

- [x] 6.1 Add `scripts/test-armis-dire-e2e.sh` with isolated database
  provisioning/cleanup, faker lifecycle management, timeouts, and failure
  traps; support an explicit test DSN for ad-hoc runs.
- [x] 6.2 Add a fast CI invocation that requires no Kubernetes resources and
  reports a non-zero exit for any count, identity, or northbound mismatch.
- [x] 6.3 Add the 50,000-device scale invocation as a scheduled/release gate
  with resource/time limits and the same correctness assertions.
- [x] 6.4 Document local invocation, CI variables, profiles, expected count
  equations, and how to inspect artifacts.

## 7. Verification

- [x] 7.1 Run faker unit tests and the producer tests.
- [x] 7.2 Run the fast closed-loop E2E against a disposable local database.
- [ ] 7.3 Run the 50,000-device profile and record runtime/memory/cardinality
  baselines.
- [x] 7.4 Run `openspec validate add-hermetic-armis-dire-e2e --strict`.
