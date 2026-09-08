# Sweep observation ABI closeout audit

Task 1.2-a, inspected against commit `af0a2151fd`.

The eight messages contain 52 fields. Their tags, names, types and cardinalities
match the generated Elixir descriptor inventory in
`elixir/serviceradar_core/test/serviceradar/edge/sweep_body_validate_test.exs`
(`@inventories`). The same test derives the integer-width coverage from those
inventories, including open enum int32 values. The authoritative declaration is
`proto/edge/v1/sweep.proto`, messages `SweepTestV1` through `SweepMtrSummaryV1`.
No missing field or body-validation rule was found within task 1.2's scope.

## Field coverage

Each row names every field it covers; numbers are protobuf tags. All fields also
receive generated wire typing, recursive unknown-field refusal at the raw
boundary, and the Elixir decoded shape checks. The table describes additional
semantic rules; it does not invent constraints on descriptive fields.

| Message | Fields | Implemented contract |
| --- | --- | --- |
| SweepTestV1 | mode (1), protocol (2), port (3) | Exact mode/protocol/port tuple, legal combination, no duplicate tuple; configured mode bits equal the union of the dictionary. |
| SweepObservationBatchV1 | execution_id (1), execution_plan_id (7), target_range_id (9) | Canonical UUIDs; execution or source-selected context and target range are joined to source authority at the record correlation boundary. |
| SweepObservationBatchV1 | sweep_group_id (2), source (14), source_run_id (15) | Source matrix selects the context operand and source-run-id disposition. The selected operand is execution_id or source_run_id. sweep_group_id remains descriptive grouping bytes and is not used as signed authority. |
| SweepObservationBatchV1 | execution_shard (3), assignment_epoch (4) | uint32/uint64 respectively; correlated against producer run shard and authority epoch. |
| SweepObservationBatchV1 | batch_sequence (5), observed_at_unix_nano (6) | Positive sequence and timestamp; batch time lies in the signed inclusive collection window. |
| SweepObservationBatchV1 | execution_plan_sha256 (8), target_range_sha256 (10) | Exactly 32 bytes; compared to source plan/range digests and scope digest at correlation. |
| SweepObservationBatchV1 | tested_checks (11), configured_mode_bits (12) | Nonempty exact check dictionary; mode-bit union equality. |
| SweepObservationBatchV1 | availability_policy_id (13) | Present nonempty bytes. Policy length is bounded at the authoritative plan/assignment boundary; the body does not add an independent policy ceiling. |
| SweepObservationBatchV1 | hosts (16) | Repeated terminal fragments, at most 2000; the count ceiling precedes host traversal. Empty host batches remain legal. |
| SweepHostObservationV1 | address (1), hostname (2) | 4/16-byte address and UTF-8 descriptive hostname. No separate hostname ceiling is introduced by this task. |
| SweepHostObservationV1 | observed_at_delta_nano (3) | sint64; checked addition to batch time and signed collection-window comparison at correlation. |
| SweepHostObservationV1 | first_seen_delta_nano (4), last_seen_delta_nano (5) | Optional sint64 values; absent and present zero remain distinct. They are observation attributes, not additional signed collection times. |
| SweepHostObservationV1 | result_mode_bits (6), mode_revision (7) | Nonzero result modes contained in the configured set; uint32 revision accompanies the fragment's named modes. The wire shape permits independent per-mode merge decisions downstream. |
| SweepHostObservationV1 | icmp (8), tcp (9), mtr (12) | Optional summaries must be present exactly when their modes are named. Both missing and surplus summaries are refused. |
| SweepHostObservationV1 | open_ports (10), port_errors (11) | Check indices must select a TCP check named by this host fragment; uniqueness spans both lists. Nonempty open ports require an equal TCP open_count. |
| SweepIcmpSummaryV1 | outcome (1), target_reached (2), sent (5), received (6) | Known outcome, received <= sent, reached requires received > 0. |
| SweepIcmpSummaryV1 | round_trip_micro (3), packet_loss_pct (4) | Optional uint64 RTT and optional finite loss percentage in [0,100]; measured zero retains presence. |
| SweepTcpSummaryV1 | outcome (1), tested_count (2), open_count (3) | Known outcome and open <= tested; listed ports are checked at the host boundary. |
| SweepOpenPortV1 | tested_check_index (1), response_time_nano (2), service (3) | Shared check-index gate; optional uint64 latency; UTF-8 service description. |
| SweepPortErrorV1 | tested_check_index (1), error_code (2) | Shared check-index gate; UTF-8 descriptive error code. No delivery-ACK token grammar is applied to this different field. |
| SweepMtrSummaryV1 | trace_id (1), outcome (2) | Terminal outcome; allocated outcomes require UUIDv7, unallocated outcomes require absence. Allocated trace time is checked against the signed collection window. |
| SweepMtrSummaryV1 | target_reached (3), total_hops (6) | Reached requires a nonzero hop count. Full trace hop limits belong to the MTR body contract. |
| SweepMtrSummaryV1 | final_rtt_micro (4), packet_loss_pct (5), error_code (7) | Optional uint64 RTT; optional finite loss percentage in [0,100]; UTF-8 descriptive error code. |

## Implementation and evidence

- Go body rules: `ValidateSweepObservationBatch`, `validateSweepSummaries`,
  `modeProtocolConsistent` in `go/pkg/edge/edgerecord/domain.go`.
- Elixir body rules: `SweepBodyValidate.validate_bytes/1` and `validate/1` in
  `elixir/serviceradar_core/lib/serviceradar/edge/sweep_body_validate.ex`.
  The raw boundary is `WireDecode.decode_sweep_batch/1`, with the distinct
  32 MiB extracted-body work ceiling. The physical record/payload ceiling and
  decompression rules remain at their existing outer boundaries.
- Correlation: Go's sweep record join and Elixir's
  `SweepCorrelate.ingest_own_payload/1`; `sweep_join_corpus.txt` records shared
  controls, predicate-specific mismatches, checked time arithmetic and inclusive
  window endpoints. Task 1.3 owns that relation.
- Schema and body evidence: `sweep_body_validate_test.exs` pins all eight
  descriptor inventories, uint32/uint64/int64/sint64/enum-int32 widths, optional
  presence, all nesting levels, counter relations, mode/check consistency and
  validation order. `sweep_batch_decode_test.exs` exercises the raw decoder.
- Cross-language artifacts: `proto/edge/v1/golden_test.go`,
  `TestPresenceZeroVersusAbsent`, the shared `sweep_batch.bin`, and
  `elixir/serviceradar_core/test/serviceradar/proto/edge_v1_golden_test.exs`.
  The generic optional-field corpora cover absent versus present-zero separately
  from semantic validity.
- Validation at this audit: the Go edge/golden targets and Elixir edge unit shard
  passed in BuildBuddy invocation `92d9ffbd-6a6d-4b4d-8401-e5da5619820d`.

This closes a contract-and-validator audit. It does not claim deployment of a
live edge ingress, implementation of every downstream merge writer, or an ABI
freeze approval. Those claims have their own owners; task 1.7 remains open.
