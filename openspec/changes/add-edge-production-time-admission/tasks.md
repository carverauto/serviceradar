# Tasks

All fixtures are synthetic. Bazel runs use `--config=remote`. Database tests
run only on srql-fixtures scratch databases. Every PR goes through the
no-mistakes gate. There are no bypass flags, and no Helm-only settings.

## 1. Edge (Go), phase 1

- [ ] 1.1 Add `EdgeDeliveryLateAdmissionV1`, `EdgeLatePublication`,
      `EdgeLateDecisionReason`, `EdgeRecordLaneOpen.admission` and the
      `LATE_ADMISSION` delivery mode to `proto/edge/v1/record.proto`.
      Regenerate the Go and Elixir bindings together
      (`make verify-proto-edge-elixir` stays green). Older peers fail closed on
      the unknown oneof member.
- [ ] 1.2 Add `edgerecord.ValidateRecordProduced` (Decision 3, agent checks 1
      to 5) and `RecordLateAttribution`. Classify the outcome as admissible,
      admissible-security, retryable or permanent. The live
      `ValidateRecordSigned` is unchanged.
- [ ] 1.3 Extend `ValidateFrameSigned`, the Go oracle of the gateway decision,
      with the late transition: late-session acceptance, the binding of
      `produced_at` and epoch, grant-decided publication, and the live-session
      restriction to stale or missing fences.
- [ ] 1.4 Add late generations to the spool (`<root>/late/<lane>/<generation>`).
      They use the shared allocator, frozen identity, event-id deduplication on
      append, and the existing reclaim path.
- [ ] 1.5 Add `RecordSpool.AdmitLate`, which validates with
      `ValidateRecordProduced` and appends to the late generation. It never
      falls back to live admission.
- [ ] 1.6 Hand off legacy layouts in `OpenRecordSpool`: a `flat_v1` reader,
      in-order handoff, durable append before the legacy resolve, rejection
      evidence for permanent failures, retirement through
      `RetireDrainedLegacyFlat`, and the readiness condition
      `legacy_storage_handoff_pending`.
- [ ] 1.7 Sender: open a late session per lane key with late admission and
      separate credits, gated on the gateway advertising `late_admission_v1`.
      Request late grants in place of renewals for late generations, and for
      live records refused for a stale or missing fence. Report
      `late_pending_gateway_support`.
- [ ] 1.8 Write fail-first tests:
  - a days-old flat-spool record, refused by live admission, handed off and
    delivered on the late session to a Go gateway oracle that applies the late
    grant;
  - a compromise-revoked key record that never publishes PRIMARY and is
    security-quarantined;
  - an `INVALID` key record written to rejection evidence;
  - a crash between the late append and the flat resolve that leaves one copy;
  - a retryable refusal that pauses the handoff in order;
  - a future `produced_at` that is refused.
- [ ] 1.9 Amend the `add-edge-spool-recovery-coordinator` delta and
      `legacy-recovery-decision.md` so the "SHALL NOT migrate, drain" sentence
      for flat storage points to this handoff, which is not a recovery
      operation, and update `docs/docs/durable-edge-records.md`.

## 2. Core and gateway (Elixir), phase 2. Roll out before agents send late sessions.

- [ ] 2.1 Migration: `platform.edge_authority_history`, its triggers on
      `sweep_producer_assignments` and `edge_output_grants` (insert, update and
      delete), an immutability guard, and seeding from current rows.
- [ ] 2.2 Make `OutputGrants.revoke_agent` record its cause:
      `identity_superseded` or `certificate_revoked`.
- [ ] 2.3 Add `late_admission_max_age_seconds` to `PipelineSettings` with a
      code default of 14 days. Raise `EdgeLedgerRetentionWorker`'s horizon to
      at least that age. Compute the effective late age as the smaller of the
      two. Add bounded pruning of history.
- [ ] 2.4 Keep issuer key history: retired keys stay `valid` in the trust
      document for at least the effective late age after their last window.
- [ ] 2.5 Add `ServiceRadar.Edge.LateAdmission.issue/…` with the history
      decision (Decision 3, checks 6 to 9), reasons and refusal for non-owners,
      plus a gateway RPC for late grants within the existing batch bounds.
- [ ] 2.6 Gateway: add late sessions (`admission = LATE`) and late-grant
      verification in `EdgeRecordAuthorization`, accept late grants on live
      sessions only for stale or missing fences, add the `LATE_ADMISSION`
      provenance mode, and advertise `late_admission_v1`.
- [ ] 2.7 EventWriter: accept `LATE_ADMISSION` on the primary and audit routes,
      add audit-trail columns to the ledger, let projectors authorize from the
      grant decision, and make current-state projectors apply by
      `produced_at` without regressing state.
- [ ] 2.8 Write database tests on srql-fixtures: a raw upsert records history,
      history rows are immutable, primary versus `fenced_at_production` versus
      `history_unknown` versus `compromise_ended` versus `beyond_late_window`,
      a deleted assignment still decides, and a replay is idempotent.

## 3. Other edge queues, phase 3

- [ ] 3.1 Make the local rejection quarantine a drained queue on the late
      session to reject-audit, with no eviction of undelivered entries.
- [ ] 3.2 OTel add-on: drain or adopt the old spool on a `spool_dir` or backend
      change, and report the remaining frames.

## 4. NVR/VMS media, phase 4. Coordinate with the open archive changes.

- [ ] 4.1 Add an automatic NVR archive drainer: start-up rescan, a production
      caller for block archive, writing the first publication intent, and
      persistent retries.
- [ ] 4.2 Add an automatic core-local camera spool uploader, and automatic
      reconciliation of `:prepared` dispatches by idempotent read-back.
- [ ] 4.3 Keep retained recovery-generation and archive-binding history, judge
      sealed blocks by the generation they were sealed under, and quarantine a
      seal with no history.
- [ ] 4.4 Add start-up reconciliation of unsealed and interrupted blocks, and
      owner reconciliation of leftover upload scratch.
- [ ] 4.5 Cross-reference or move these tasks into `add-edge-recording-archive`,
      `define-nvr-local-copy-registration` and `add-longshore-object-storage`
      so each drainer is built once.
