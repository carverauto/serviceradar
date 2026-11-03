# Tasks: Add producer run lifecycles and inventory completeness

## 1. Moved from `unify-sweep-results-proto`

Each task keeps its original text and number from `unify-sweep-results-proto`; its last line states what remained
when it moved.

- [ ] 1.1 (was `unify-sweep-results-proto` 1.8) Add `ProducerRunEventV1` and typed
  `DeviceInventoryObservationBatchV1` contracts with provider/source identity,
  bounded pages, stable item keys, page ordinal/content digest, cursor, start,
  checkpoint, complete/partial/aborted terminal manifest, and absence/deletion
  semantics that activate only after a valid complete terminal. Bind a bounded
  ordered Merkle/checkpoint root, assignment-authorized coverage scope, and
  provider snapshot token/revision or contract-specific consistency proof;
  without completeness proof, a run is upsert-only.
  Remaining as of the move (2026-11-02): per-family typed inventory batches replace a
  generic inventory batch (`move-agent-telemetry-to-edge-records` task 7.1:
  #6215, #6221). Run lifecycle events and absence-on-complete semantics are not
  built; follow-up.
- [ ] 1.2 (was `unify-sweep-results-proto` 2.3) Emit stable execution start, bounded progress/watermark, completion,
  and aborted evidence, with each data frame independently decodable and useful;
  integrate scheduler lease recovery so an agent crash produces authoritative
  lost/expired/superseded attempt state and a retriable WHOLE range window (v1 has no
  sparse-remainder representation -- see task 2.3c).
  Remaining as of the move (2026-11-02): core mints the execution (M2.0b2), completes
  it at the plan's target count (M2.3) and marks missed slots (M2.0h, #6196).
  Agent-emitted start/progress/aborted evidence is not built, and
  `go/pkg/edge/execstate` has no importers.
- [ ] 1.3 (was `unify-sweep-results-proto` 5.11) Implement the DIRE-aware inventory projector for bounded pages and
  terminal manifests. Stage each immutable page idempotently by source instance
  and scheduler-owned generation with no current/absence side effect; allow an
  early terminal to wait pending; validate every ordinal/hash/object key and
  ordered root; then atomically fence older generations and swap the current
  snapshot pointer. Preserve provider ownership and stable source keys, activate
  absence/deletion only for a valid consistency-proven complete terminal, keep
  prior current inventory on partial/aborted/missing/conflicting runs, poison
  late or conflicting terminals, and boundedly GC abandoned staging after its
  repair horizon.
  Remaining as of the move (2026-11-02): follow-up;
  `move-agent-telemetry-to-edge-records` task 7.2 projects inventory batches,
  but absence semantics need 1.8.

## 2. Validate

- [ ] 2.1 Run the Go, Elixir and Bazel suites for every touched target and
  `openspec validate add-edge-inventory-run-completeness --strict`.
