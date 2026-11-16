# Tasks

All fixtures are synthetic. Bazel runs use `--config=remote`. Database tests
run only on srql-fixtures scratch databases. Every PR goes through the
no-mistakes gate. There are no bypass flags, and no Helm-only settings.

## 1. Edge (Go), phase 1

- [ ] 1.1 Add `EdgeDeliveryLateAdmissionV1`, `EdgeLatePublication`,
      `EdgeLateDecisionReason` (including `LEDGER_PRUNED`),
      `EdgeRecordLaneOpen.admission` and the `LATE_ADMISSION_REQUIRED`
      rejection code (carried on a `REJECTED_PERMANENT` disposition) to
      `proto/edge/v1/record.proto`, and `uint32
      late_admission_protocol_version` to `EdgeRecordLaneOpen` (absent or 0
      means today's live dispositions); an agent that implements the late
      generation sends 1 on every lane open. Add `uint32
      edge_late_admission_protocol_version` to `AgentHelloResponse`, through
      which the gateway advertises `late_admission_v1` (value >= 1, set only
      in phase 2). Regenerate the Go and
      Elixir bindings together (`make verify-proto-edge-elixir` stays green).
      Older peers fail closed on the unknown oneof member. The provenance
      `LATE_ADMISSION` delivery mode (`DeliveryModeLateAdmission = 5`, the
      MODIFIED four-decisions requirement) is not added here: it is implemented
      in phase 2 with its Elixir peer (task 2.6), so phase 1 does not change
      the shared Go/Elixir provenance vectors.
- [ ] 1.2 Add `edgerecord.ValidateRecordProduced` (Decision 3, agent checks 1
      to 5) and `RecordLateAttribution`. Classify the outcome as admissible,
      admissible-security, foreign-principal, retryable or permanent. With a
      loaded trust snapshot, an absent fence entry or scope binding, an epoch
      ahead of the known fence and a `produced_at` ahead of the local clock are
      admissible; only an unloaded snapshot or an `UNAVAILABLE` key is
      retryable. The live
      `ValidateRecordSigned` is unchanged.
- [ ] 1.3 Extend `ValidateFrameSigned`, the Go oracle of the gateway decision,
      with the late transition: late-session acceptance only, the binding of
      `produced_at` and epoch, grant-decided publication, security quarantine
      for a foreign origin principal (before the identity rejection, replacing
      `identity_conflict`), a `HISTORICALLY_REVOKED` key, or an
      `(assignment, epoch)` in the trust snapshot's terminal-interval list
      (regardless of any grant), decided before the missing-grant withhold, a
      retryable withhold for any other frame without a grant (including one
      in core's future, unless a quarantine class applies first), and
      `LATE_ADMISSION_REQUIRED` (`REJECTED_PERMANENT`) for any live-lane record
      with a stale or missing fence, whatever its production window, or a
      foreign origin principal, only when the session's `EdgeRecordLaneOpen.late_admission_protocol_version >= 1`;
      otherwise today's live dispositions.
- [ ] 1.4 Add late generations to the spool (`<root>/late/<lane>/<generation>`)
      and per-principal holds keyed by `(lane key, origin principal)`
      (`<root>/late/<lane>/principal/<origin principal>/`).
      They use the shared allocator, frozen identity, event-id deduplication on
      append, and the existing reclaim path.
- [ ] 1.5 Add `RecordSpool.AdmitLate`, which validates with
      `ValidateRecordProduced` and appends to the late generation, or to the
      hold for `(lane key, origin principal)` for a foreign origin principal. It never falls back to
      live admission.
- [ ] 1.6 Hand off legacy layouts in `OpenRecordSpool`: a `flat_v1` reader,
      in-order handoff, durable append before the legacy resolve, foreign
      principals to their hold, rejection evidence for permanent failures with
      a paused or refused evidence write treated as retryable, retirement through
      `RetireDrainedLegacyFlat`, and the readiness condition
      `legacy_storage_handoff_pending`.
- [ ] 1.7 Sender: open at most one late session per lane key, which drains the
      lane key's late generation and its per-principal holds, with late
      admission and separate credits, gated on the gateway advertising
      `late_admission_v1`. Request late grants in place of renewals for the
      agent's own late records only; send hold frames, `HISTORICALLY_REVOKED`
      frames and frames core refused as `certificate_revoked_interval` without
      waiting for a grant. On
      `LATE_ADMISSION_REQUIRED`, append the exact record bytes durably to the
      lane key's late generation, or to the `(lane key, origin principal)` hold
      for a foreign origin, before persisting the live resolution, and never
      copy it into the evicting local quarantine. Report
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
  - a refused rejection-evidence write that leaves the legacy record unresolved;
  - a foreign-principal record routed to its hold while the agent's own records
    hand off past it, and never published PRIMARY even with a grant;
  - a `LATE_ADMISSION_REQUIRED` live record appended durably to the late
    generation before the live resolution is persisted;
  - a LATE lane open refused by a phase 1 gateway;
  - a flat record whose assignment was deleted (no fence entry or scope
    binding in a loaded snapshot) that is admissible late, not retried;
  - a hold frame without a grant that is quarantined and does not stall the
    agent's own late records behind it;
  - a live record with a stale fence and a still-open production window
    resolved as `LATE_ADMISSION_REQUIRED` on a lane open with
    `late_admission_protocol_version = 1`, and today's disposition for the
    same record on a lane open with version 0;
  - a `produced_at` ahead of the local clock, and an epoch ahead of the known
    fence, appended to the late generation without stopping the handoff.
- [ ] 1.9 Amend the `add-edge-spool-recovery-coordinator` delta and
      `legacy-recovery-decision.md` so the "SHALL NOT migrate, drain" sentence
      for flat storage points to this handoff, which is not a recovery
      operation, and update `docs/docs/durable-edge-records.md`.
- [ ] 1.10 Gateway: refuse an `EdgeRecordLaneOpen` with `admission = LATE`, and
      do not advertise `late_admission_v1`, until phase 2 implements the late
      path. The regenerated Elixir bindings decode the field, so the refusal
      must be explicit.
- [ ] 1.11 Parse the trust document's terminal-interval list
      (`certificate_revoked` and `revoked_cause_unknown` intervals by
      `(producer_assignment_id, network_scope_id, run_shard,
      authority_epoch)`) into the Go `TrustSnapshot`, separately from the
      current fences, for the oracle in task 1.3.

## 2. Core and gateway (Elixir), phase 2. Deploy before late sessions do anything; until then late records stay on disk, accounted and reported.

- [ ] 2.1 Migration: `platform.edge_authority_history`, its triggers on
      `sweep_producer_assignments` and `edge_output_grants` (insert opens;
      update closes and opens; delete only closes with `deleted`), an
      immutability guard, and seeding from current rows, with already-revoked
      output grants ended `revoked_cause_unknown` and already-revoked sweep
      assignments keeping their normal reason. Never prune
      `certificate_revoked` or `revoked_cause_unknown` intervals.
- [ ] 2.2 Make `OutputGrants.revoke_agent` record its cause:
      `identity_superseded` or `certificate_revoked`, on every revocation path
      including an operator-request certificate revocation that leaves the
      principal able to authenticate. A `certificate_revoked` interval routes
      its late records to security quarantine whoever presents them.
- [ ] 2.3 Add `late_admission_max_age_seconds` to `PipelineSettings` with a
      code default of 14 days. Raise `EdgeLedgerRetentionWorker`'s horizon to
      at least that age. Persist a monotonic `ledger_complete_since`, seeded
      at migration with the retention cutoff already in force (migration time
      minus the `EdgeLedgerRetentionWorker` horizon then), that advances
      only when pruning deletes rows, to that batch's `inserted_at` cutoff.
      PRIMARY requires `produced_at >= ledger_complete_since + clock
      tolerance`. Add bounded pruning of history.
- [ ] 2.4 Keep issuer key history: retired keys stay `valid` in the trust
      document for at least `late_admission_max_age_seconds` after their last
      window.
- [ ] 2.5 Add `ServiceRadar.Edge.LateAdmission.issue/…` with the history
      decision (Decision 3, checks 6 to 9, including `ledger_pruned`), reasons
      no grant for non-owners or a foreign origin principal (the gateway
      quarantines those), and no grant for a record naming a
      `certificate_revoked` or `revoked_cause_unknown` interval whoever
      presents it, returning `certificate_revoked_interval`, a "not yet"
      answer for a record whose `produced_at` is in core's future,
      plus a gateway RPC for late grants within the existing batch bounds.
- [ ] 2.6 Gateway: add late sessions (`admission = LATE`), replacing the
      phase 1 refusal, and late-grant verification in
      `EdgeRecordAuthorization`. Never accept a late grant on a live session;
      resolve any live record with a stale or missing fence, whatever its
      production window, or with a foreign origin principal (in place of
      `identity_conflict`), as `LATE_ADMISSION_REQUIRED` on a
      `REJECTED_PERMANENT` disposition, but only on live sessions whose
      `EdgeRecordLaneOpen.late_admission_protocol_version >= 1`; keep today's
      live dispositions for older agents (absent or 0). On a late session
      publish foreign-principal frames to security quarantine before the
      identity rejection, and `HISTORICALLY_REVOKED` and
      terminal-interval frames before the missing-grant withhold, recording the
      origin and presenting principals. Core emits the terminal-interval list
      in the trust document and `EdgeRecordTrust` parses it; frame
      authorization quarantines a listed interval regardless of an
      already-issued grant, and a higher fence alone never quarantines. Assign
      the provenance `LATE_ADMISSION` delivery mode (grammar-8 transport
      provenance, `DeliveryModeLateAdmission = 5`, with a delivery proof over
      the `EdgeDeliveryLateAdmissionV1` transition) in Go and Elixir together, and advertise
      `late_admission_v1` through
      `AgentHelloResponse.edge_late_admission_protocol_version = 1`.
- [ ] 2.7 EventWriter: accept `LATE_ADMISSION` on the primary and audit routes,
      add audit-trail columns to the ledger, let projectors authorize from the
      grant decision, and make current-state projectors apply by
      `produced_at` without regressing state.
- [ ] 2.8 Write database tests on srql-fixtures: a raw upsert records history,
      a delete closes the interval without opening a successor, history rows
      are immutable, a same-principal record naming a `certificate_revoked`
      interval gets no grant (`certificate_revoked_interval`), primary versus `fenced_at_production` versus
      `history_unknown` versus `compromise_ended` versus `beyond_late_window`
      versus `ledger_pruned`, the migration seed leaves the upgrade tail
      PRIMARY-eligible while a record older than the seed stays AUDIT after a
      late-age raise, a `produced_at` within the clock tolerance after the
      prune cutoff stays AUDIT, `ledger_complete_since` never moves backward and
      a raised late age after pruning stays AUDIT, a deleted assignment still
      decides, and a replay is idempotent.

## 3. Other edge queues, phase 3

- [ ] 3.1 Make the local rejection quarantine a drained queue on the late
      session to reject-audit, with no eviction of undelivered entries.
- [ ] 3.2 OTel add-on: drain or adopt the old spool on a `spool_dir` or backend
      change, and report the remaining frames.

## 4. NVR/VMS media, phase 4. Coordinate with the open archive changes.

- [ ] 4.1 Add an automatic NVR archive drainer: start-up rescan, a production
      caller for block archive, writing the first publication intent, and
      persistent retries. With an archive destination configured it stops only
      on a verified archive or quarantine-destination receipt, never on a
      local publication; in local-only mode it stops on a verified
      local-retention publication (published into the qualified durable local
      archive with its central index receipt persisted), after which local
      deletion follows the retention and hold policy.
- [ ] 4.2 Add an automatic core-local camera spool uploader, and automatic
      reconciliation of `:prepared` dispatches by idempotent read-back.
- [ ] 4.3 Keep retained recovery-generation and archive-binding history, judge
      sealed blocks by the generation they were sealed under, and quarantine a
      seal with no history. A verified quarantine-destination archive receipt
      is terminal: it ends the drainer for that block and permits local
      deletion.
- [ ] 4.4 Add start-up reconciliation of unsealed and interrupted blocks, and
      owner reconciliation of leftover upload scratch.
- [ ] 4.5 Cross-reference or move these tasks into `add-edge-recording-archive`,
      `define-nvr-local-copy-registration` and `add-longshore-object-storage`
      so each drainer is built once.
