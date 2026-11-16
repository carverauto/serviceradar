# Tasks

All fixtures are synthetic. Bazel runs use `--config=remote`. Database tests
run only on srql-fixtures scratch databases. Every PR goes through the
no-mistakes gate. There are no bypass flags, and no Helm-only settings.

## 1. Edge (Go), phase 1

- [ ] 1.1 Add `EdgeDeliveryLateAdmissionV1`, `EdgeLatePublication`,
      `EdgeLateDecisionReason` (including `LEDGER_PRUNED`),
      `EdgeRecordLaneOpen.admission` and the `late_admission_required`
      rejection code to `proto/edge/v1/record.proto`. Regenerate the Go and
      Elixir bindings together (`make verify-proto-edge-elixir` stays green).
      Older peers fail closed on the unknown oneof member. The provenance
      `LATE_ADMISSION` delivery mode is not added here (task 2.6).
- [ ] 1.2 Add `edgerecord.ValidateRecordProduced` (Decision 3, agent checks 1
      to 5) and `RecordLateAttribution`. Classify the outcome as admissible,
      admissible-security, retryable or permanent. The live
      `ValidateRecordSigned` is unchanged.
- [ ] 1.3 Extend `ValidateFrameSigned`, the Go oracle of the gateway decision,
      with the late transition: late-session acceptance only, the binding of
      `produced_at` and epoch, grant-decided publication, security quarantine
      for a foreign origin principal, and `late_admission_required` for a
      live-lane record with expired authority and a stale or missing fence.
- [ ] 1.4 Add late generations to the spool (`<root>/late/<lane>/<generation>`)
      and per-principal holds (`<root>/late/principal/<origin principal>/`).
      They use the shared allocator, frozen identity, event-id deduplication on
      append, and the existing reclaim path.
- [ ] 1.5 Add `RecordSpool.AdmitLate`, which validates with
      `ValidateRecordProduced` and appends to the late generation, or to the
      per-principal hold for a foreign origin principal. It never falls back to
      live admission.
- [ ] 1.6 Hand off legacy layouts in `OpenRecordSpool`: a `flat_v1` reader,
      in-order handoff, durable append before the legacy resolve, foreign
      principals to their hold, rejection evidence for permanent failures with
      a paused or refused evidence write treated as retryable, retirement through
      `RetireDrainedLegacyFlat`, and the readiness condition
      `legacy_storage_handoff_pending`.
- [ ] 1.7 Sender: open a late session per lane key and per principal hold with
      late admission and separate credits, gated on the gateway advertising
      `late_admission_v1`. Request late grants in place of renewals for late
      generations only. On `late_admission_required`, append the exact record
      bytes durably to the lane key's late generation before persisting the
      live resolution. Report `late_pending_gateway_support`.
- [ ] 1.8 Write fail-first tests:
  - a days-old flat-spool record, refused by live admission, handed off and
    delivered on the late session to a Go gateway oracle that applies the late
    grant;
  - a compromise-revoked key record that never publishes PRIMARY and is
    security-quarantined;
  - an `INVALID` key record written to rejection evidence;
  - a crash between the late append and the flat resolve that leaves one copy;
  - a retryable refusal that pauses the handoff in order;
  - a refused rejection-evidence write that leaves the legacy record unresolved;
  - a foreign-principal record routed to its hold while the agent's own records
    hand off past it, and never published PRIMARY even with a grant;
  - a `late_admission_required` live record appended durably to the late
    generation before the live resolution is persisted;
  - a LATE lane open refused by a phase 1 gateway;
  - a future `produced_at` that is refused.
- [ ] 1.9 Amend the `add-edge-spool-recovery-coordinator` delta and
      `legacy-recovery-decision.md` so the "SHALL NOT migrate, drain" sentence
      for flat storage points to this handoff, which is not a recovery
      operation, and update `docs/docs/durable-edge-records.md`.
- [ ] 1.10 Gateway: refuse an `EdgeRecordLaneOpen` with `admission = LATE`, and
      do not advertise `late_admission_v1`, until phase 2 implements the late
      path. The regenerated Elixir bindings decode the field, so the refusal
      must be explicit.

## 2. Core and gateway (Elixir), phase 2. Deploy before late sessions do anything; until then late records stay on disk, accounted and reported.

- [ ] 2.1 Migration: `platform.edge_authority_history`, its triggers on
      `sweep_producer_assignments` and `edge_output_grants` (insert, update and
      delete), an immutability guard, and seeding from current rows.
- [ ] 2.2 Make `OutputGrants.revoke_agent` record its cause:
      `identity_superseded` or `certificate_revoked`.
- [ ] 2.3 Add `late_admission_max_age_seconds` to `PipelineSettings` with a
      code default of 14 days. Raise `EdgeLedgerRetentionWorker`'s horizon to
      at least that age. Persist a monotonic `ledger_complete_since` that only
      ledger pruning advances, to the cutoff it pruned. Add bounded pruning of
      history.
- [ ] 2.4 Keep issuer key history: retired keys stay `valid` in the trust
      document for at least `late_admission_max_age_seconds` after their last
      window.
- [ ] 2.5 Add `ServiceRadar.Edge.LateAdmission.issue/…` with the history
      decision (Decision 3, checks 6 to 9, including `ledger_pruned`), reasons
      and refusal for non-owners, no grant for a foreign origin principal,
      plus a gateway RPC for late grants within the existing batch bounds.
- [ ] 2.6 Gateway: add late sessions (`admission = LATE`), replacing the
      phase 1 refusal, and late-grant verification in
      `EdgeRecordAuthorization`. Never accept a late grant on a live session;
      resolve live records with expired authority and a stale or missing fence
      as `late_admission_required`. Publish foreign-principal frames to security
      quarantine only, recording the origin and presenting principals. Assign
      the provenance `LATE_ADMISSION` delivery mode (grammar-8 transport
      provenance, value 5) in Go and Elixir together, and advertise
      `late_admission_v1`.
- [ ] 2.7 EventWriter: accept `LATE_ADMISSION` on the primary and audit routes,
      add audit-trail columns to the ledger, let projectors authorize from the
      grant decision, and make current-state projectors apply by
      `produced_at` without regressing state.
- [ ] 2.8 Write database tests on srql-fixtures: a raw upsert records history,
      history rows are immutable, primary versus `fenced_at_production` versus
      `history_unknown` versus `compromise_ended` versus `beyond_late_window`
      versus `ledger_pruned`, `ledger_complete_since` never moves backward and a
      raised late age after pruning stays AUDIT, a deleted assignment still
      decides, and a replay is idempotent.

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
