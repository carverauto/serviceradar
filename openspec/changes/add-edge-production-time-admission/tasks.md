# Tasks

All fixtures are synthetic. Bazel runs use `--config=remote`. Database tests
run only on srql-fixtures scratch databases. Every PR goes through the
no-mistakes gate. There are no bypass flags, and no Helm-only settings.

## 1. Edge (Go), phase 1

Status: implemented in PR #6692 except where a task says otherwise.

- [x] 1.1 Add `EdgeDeliveryLateAdmissionV1`, `EdgeLatePublication` and
      `EdgeLateDecisionReason` (including `LEDGER_PRUNED`), the late-session
      flag and `uint32 late_admission_protocol_version` on
      `EdgeRecordLaneOpen` (absent or 0 means today's live dispositions), and
      `uint32 edge_late_admission_protocol_version` on `AgentHelloResponse`.
      Also add the `IssueEdgeLateAdmissionGrants` RPC and regenerate the Go
      and Elixir bindings together. The late-session flag is
      `bool late_admission` rather than an enum: the frozen enum-policy guards
      require every enum's zero member to be UNSPECIFIED and refused, which an
      older agent's lane open would hit, and an `optional` enum would need the
      generated presence corpus. When the gateway's Hello advertised late
      admission, every lane open (live and late) carries
      `late_admission_protocol_version = 1` and `late_admission = true` is set
      only on the late session; when Hello did not advertise it, neither field
      is set, because an older gateway rejects unknown lane-open fields. The provenance
      `LATE_ADMISSION` delivery mode (value 5) stays in phase 2 (task 2.6).
- [x] 1.2 Add `edgerecord.ValidateRecordProduced` and
      `RecordLateAttribution`. With a loaded trust snapshot, an absent fence
      entry or scope binding, an epoch ahead of the known fence and a
      `produced_at` ahead of the local clock are admissible; only an unloaded
      snapshot or an `UNAVAILABLE` key is retryable. The live
      `ValidateRecordSigned` is unchanged.
- [x] 1.3 Extend the Go oracle of the gateway decision. Done:
      `ValidateLateFrameSigned` accepts a late grant only on a late session,
      binds `produced_at` and epoch, takes the publication from the grant,
      and security-quarantines a foreign origin, a `HISTORICALLY_REVOKED` key
      or a terminal interval before any grant; and `ValidateLiveFrameSigned`
      resolves a live session's undeliverable records as
      `ErrLateAdmissionRequired` from lane-open version 1 (task 2.6c).
- [x] 1.4 Add late generations and per-principal holds, as built:
      `<root>/late/own/<lane>/<generation>` for the agent's own records, and
      `<root>/late/hold/<origin principal hex>/<lane>/<generation>`, keyed by
      `(lane key, origin principal)`, for foreign origins. They are charged to
      the shared allocator but not to the producer admission gate, and use
      frozen identity, event-id deduplication across every late set, and the
      existing reclaim path.
- [x] 1.5 Add `RecordSpool.AdmitLate`, which never falls back to live
      admission. Session switching and the append are serialized per admit.
- [x] 1.6 Hand off the pre-lane flat spool in order: durable late append
      before the legacy resolve, foreign principals to their hold, rejection
      evidence for permanent failures (a full evidence store is retryable and
      never evicts), retirement through `RetireDrainedLegacyFlat`, and the
      `legacy_handoff_pending_records` / `legacy_handoff_reason` status fields.
- [x] 1.6a Capacity: a handoff pass copies nothing when free ordinary capacity
      does not cover a conservative bound (one append charge plus one
      generation charge for every record still to be appended). It reports
      `insufficient_capacity` with `capacity_needed_bytes` and resumes on its
      own once the spool budget (`edge_spool_max_bytes`) covers that need. On
      live relocation, the extra charge is bounded by one session credit
      window. Releasing a resolved prefix while unresolved records remain
      (partial-prefix reclaim) is new spool durability and is deferred to its
      own change.
- [ ] 1.6b Raise the `legacy_storage_handoff_pending` readiness condition from
      the carried `legacy_handoff_pending_records` / `legacy_handoff_reason`
      fields; keep `unsupported_legacy_storage` only for unaccountable entries.
      Today a pending handoff is reported under `unsupported_legacy_storage`.
- [x] 1.7 Sender: one late session at a time, drained in order, with its own
      credits and gated on the gateway advertising late admission. Late
      grants are requested only for the agent's own late records; holds are
      sent without grants. `LATE_ADMISSION_REQUIRED` resolutions are
      relocated durably before the live resolution is persisted, and never
      copied into the evicting quarantine. `late_pending_gateway_support`,
      the handoff status and the readiness copy are reported.
- [ ] 1.8 Write fail-first tests. Done:
  - a days-old flat-spool record, refused by live admission, handed off and
    delivered PRIMARY on a late session to the Go gateway oracle;
  - a compromise-revoked key record that is security-quarantined and never
    PRIMARY;
  - a crash between the late append and the flat resolve, and a
    re-enrollment, each leaving one copy;
  - a missing trust snapshot pausing the handoff in order;
  - insufficient capacity with no partial copy and automatic resume;
  - concurrent admits of two scopes;
  - the relocation credit-window bound;
  - a LATE lane open refused by the phase 1 gateway;
  - the oracle's absent-fence, ahead-of-fence and terminal-interval cases.

  Remaining:
  - an `INVALID` key record written to rejection evidence;
  - a refused evidence write that leaves the legacy record unresolved;
  - a foreign-principal record routed to its hold;
  - a hold frame without a grant that does not stall the agent's own late
    records;
  - the live-session `LATE_ADMISSION_REQUIRED` version gating, together with
    task 1.3's remainder.
- [x] 1.9 Amend the `add-edge-spool-recovery-coordinator` delta,
      `legacy-recovery-decision.md` and `docs/docs/durable-edge-records.md`.
- [x] 1.10 Gateway: refuse a lane open with `late_admission = true`
      (`UNIMPLEMENTED`) and do not advertise late admission until phase 2.
- [x] 1.11 Parse the trust document's `terminal_intervals` into the Go
      `TrustSnapshot`, separately from the current fences.

## 2. Core and gateway (Elixir), phase 2. Deploy before late sessions do anything; until then late records stay on disk, accounted and reported.

- [x] 2.1 Migration: `platform.edge_authority_history`, its triggers on
      `sweep_producer_assignments` and `edge_output_grants` (insert opens;
      update closes and opens; delete only closes with `deleted`), an
      immutability guard, and seeding from current rows, with already-revoked
      output grants ended `revoked_cause_unknown` and already-revoked sweep
      assignments keeping their normal reason. Never prune
      `certificate_revoked` or `revoked_cause_unknown` intervals.
- [x] 2.2 Make `OutputGrants.revoke_agent` record its cause:
      `identity_superseded` or `certificate_revoked`, on every revocation path
      including an operator-request certificate revocation that leaves the
      principal able to authenticate. A `certificate_revoked` interval routes
      its late records to security quarantine whoever presents them.
- [x] 2.3 Add `late_admission_max_age_seconds` to `PipelineSettings` with a
      code default of 14 days. Raise `EdgeLedgerRetentionWorker`'s horizon to
      at least that age. Persist a monotonic `ledger_complete_since`, seeded
      at migration with the retention cutoff already in force (migration time
      minus the `EdgeLedgerRetentionWorker` horizon then), that advances
      only when pruning deletes rows, to that batch's `inserted_at` cutoff.
      PRIMARY requires `produced_at >= ledger_complete_since + clock
      tolerance`. Add bounded pruning of history.
- [x] 2.4 Keep issuer key history: retired keys stay `valid` in the trust
      document for at least `late_admission_max_age_seconds` after their last
      window. Satisfied by construction: core has one issuer key and no
      rotation or compromise operation, so no key ever retires. A core test
      pins that every key the trust document has carried stays present as
      `valid`. Issuer-key rotation and compromise marking are a separate future
      change, bound by this requirement (keep a retired key for the late
      window; mark a compromised key `historically_revoked`).
- [x] 2.5 Add `ServiceRadar.Edge.LateAdmission.issue/...` with the history
      decision (Decision 3, checks 6 to 9, including `ledger_pruned`), reasons
      no grant for non-owners or a foreign origin principal (the gateway
      quarantines those), and no grant for a record naming a
      `certificate_revoked` or `revoked_cause_unknown` interval whoever
      presents it, returning `certificate_revoked_interval`, a "not yet"
      answer for a record whose `produced_at` is in core's future,
      plus a gateway RPC for late grants within the existing batch bounds.
- [ ] 2.6 Gateway late sessions, delivered as three PRs, each safe to merge
      alone (owner decision, 2026-11-17). The gateway keeps advertising
      `edge_late_admission_protocol_version = 0` until 2.7 has merged. That
      advertisement is the one switch that makes agents open late lanes and
      makes live sessions answer `LATE_ADMISSION_REQUIRED`, and until
      EventWriter accepts the `LATE_ADMISSION` mode (2.7) a published late
      record would be refused there. So 2.6c ships dormant, and the flip to 1
      lands with 2.7, or in a one-line PR right after it, together with the
      2.8 end-to-end test.
  - [x] 2.6a Terminal intervals in the trust document: core emits them (global
        cap 100,000, per agent 10,000, failing closed like the assignment
        cap; see design Decision 4, "Bounding the terminal-interval list"),
        and the gateway's `EdgeRecordTrust` parses them (Go `TrustSnapshot`
        already did in phase 1).
  - [x] 2.6b The `LATE_ADMISSION` delivery mode in Go and Elixir together:
        `DeliveryModeLateAdmission = 5` in grammar-8 transport provenance, its
        delivery proof only over an `EdgeDeliveryLateAdmissionV1` grant (and
        no other mode over one), with shared Go-cut vectors
        (`delivery_late_admission_cap.bin`,
        `transport_provenance_late_admission.txt`) checked by both runtimes.
        No gateway emits it yet: the publisher still requires mode 4 on the
        audit route, which 2.6c and 2.7 change together.
  - [x] 2.6c Late sessions, late-grant verification, quarantine ordering,
        `LATE_ADMISSION_REQUIRED`, and the advertisement code held at 0. Also
        per the owner's 2026-11-17 decisions (design Decisions 2 and 7): an
        unbound scope on a live version-1 session relocates; a late session
        does not reject on registry epoch and routes quarantine and AUDIT
        `contract_retired` from the lane; late sessions are per generation, so
        each carries one scope; and a late session's recovery-coverage lookup
        is authorized by the record's signed scope.

      The full scope of 2.6 as specified: add late sessions (`late_admission = true`), replacing the
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
      deletion follows the retention and hold policy, or, for a block whose
      seal cannot be verified, on its placement in a quarantine partition or
      flag of that archive with its central index receipt persisted, which is
      never playback-indexed and excluded from retention deletion.
- [ ] 4.2 Add an automatic core-local camera spool uploader, and automatic
      reconciliation of `:prepared` dispatches by idempotent read-back.
- [ ] 4.3 Keep retained recovery-generation and archive-binding history, judge
      sealed blocks by the generation they were sealed under, and quarantine a
      seal with no history. With an archive destination configured, a
      verified quarantine-destination archive receipt is terminal: it ends the
      drainer for that block and permits local deletion, and no local-archive
      placement ends it. In local-only mode only, the bad seal goes to a
      quarantine partition or flag of the qualified durable local archive,
      and that placement is terminal, and permits removing the spool copy,
      only once its central index receipt is persisted; it is retained, counted and reported, never indexed for
      playback and excluded from retention-policy deletion. No new store.
- [ ] 4.4 Add start-up reconciliation of unsealed and interrupted blocks, and
      owner reconciliation of leftover upload scratch.
- [ ] 4.5 Cross-reference or move these tasks into `add-edge-recording-archive`,
      `define-nvr-local-copy-registration` and `add-longshore-object-storage`
      so each drainer is built once.
