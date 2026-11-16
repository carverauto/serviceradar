# Change: Admit late edge data under the authority it was produced under

## Why

A record captured at the edge must never be left on disk without reaching a
central terminal disposition. On 2026-11-15 the product owner put it this way
for recorded video: "we really dont wanna leave any video sitting around where
it is not getting stored/saved off, that wouldnt be a very reliable NVR/VMS
system". The same rule applies to every durable edge record.

Today that rule fails, and not because of one bug. Every admission and
delivery decision judges a record against the authority that is current when
the decision is made: the production grant window at now, the fence epoch at
now, and the grant row's current state. A record that outlives its producing
authority has nowhere to go:

- The 1.5.1 to 1.5.2 agent upgrade left a short tail of committed records in the
  pre-lane flat spool. Lane admission (`RecordSpool.PrepareRecord` ->
  `RecordRecoveryAttribution` -> `ValidateRecordSigned`) refuses a days-old
  record with `ErrAuthorityExpired` or a stale fence. PR #6652 can only retire
  flat storage that is provably empty, and it keeps the rest "retained and
  flagged" as `unsupported_legacy_storage`.
- Any agent upgrading from 1.5.1 or earlier, such as SaaS tenants pinned at
  1.4.82, can strand the same tail.
- Core and the gateway also judge by current authority. A record whose
  assignment was deleted is withheld forever. A record whose assignment was
  revoked or superseded is rejected as `fence_stale` into the bounded local
  quarantine, which evicts and never redrives. A record whose grant moved on
  while it was in flight is dead-lettered as `output_grant_not_current`, and a
  replay re-runs the same current check.
- The NVR/VMS media path has a separate, wider gap: nothing drains sealed
  blocks automatically, and generation drift freezes every drain. See
  [survey.md](survey.md).

Re-delivery is impossible without a rule that judges a record against the
authority that was valid when it was produced, and verifies that authority
instead of trusting it.

## What Changes

- **No-strand invariant.** Every durable edge store has an automatic drainer
  and a central terminal disposition for every item. Local bytes are deleted
  only after a central receipt or a structural proof of emptiness, and pending
  work stays visible until it drains.
- **Production-time admission rule.** A committed record whose live admission
  is no longer possible is admitted LATE. Its proof is what it already carries:
  the signed production capability (issuer key, window, assignment, fence
  epoch, principal and scope), its producer context, and its UUIDv7 event time,
  which validation already binds inside the signed window. Signatures are
  verified against retained key history. Core decides the publication against
  an append-only authority history. Late records arrive on a separate late
  generation and session, never the live lane, and are stamped late end to end.
- **Security bounds.** These are a maximum late age, compromise handling that
  never backfills, event-id idempotency whose retention covers the late window,
  and an audit trail for every late decision. A record that fails the
  production-time rule is still delivered, to audit or security quarantine, and
  is never projected.
- **Upgrade-time handoff.** On first start a new agent drains whatever an older
  layout left behind, the flat spool included, through the late generation
  under the new rule. Only unrecognizable bytes stay retained and flagged.
- **Other stranding paths.** These are in-lane records whose fence is missing
  or stale (resolved as `late_admission_required` and moved to the late
  generation), records left by a revoked or superseded principal (security
  quarantine only), the evicting local rejection quarantine, the OTel add-on spool
  across a directory or backend change, and the NVR/VMS media path. Each gets
  a requirement and a task phase here.

## Impact

- Affected specs: `edge-producer-data-plane`, `agent-connectivity`,
  `camera-recording`.
- Affected code:
  - Go: `go/pkg/edge/edgerecord`, `go/pkg/edge/spool`, `go/pkg/edge/sender`,
    `go/pkg/agent`, `go/cmd/agent`, `proto/edge/v1/record.proto`.
  - Elixir: the agent gateway (`EdgeRecordAuthorization`, `EdgeRecordTrust`,
    delivery grants), core `ServiceRadar.Edge` (authority history, late
    grants, `OutputGrants`, projectors, `EdgeLedgerRetentionWorker`,
    `PipelineSettings`) and EventWriter.
  - Media: `serviceradar_nvr`, core-elx camera recording, `rust/otel`.
- Supersedes the "retained and flagged" state for real data in
  `add-edge-spool-recovery-coordinator/legacy-recovery-decision.md` (2026-11-15
  amendment). Only bytes the agent cannot parse as a known layout stay retained.
- Rollout: phase 1 edge Go (with the gateway refusing late lane opens), then
  phase 2 core and gateway. The agent moves late records into its late
  generation at once, but opens a late session only when the gateway
  advertises `late_admission_v1`, which phase 2 adds. Until then late records
  stay on disk, accounted and reported.
