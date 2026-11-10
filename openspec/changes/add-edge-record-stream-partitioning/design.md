# Design: Edge-record source streams keep only unwritten records

Supersedes the pending Gemini revert of #6471 (which was never opened as a PR):
instead of returning the source streams to `DiscardOld`/24h, this change moves
`TELEMETRY_EDGE_RECORD_V1_BULK` and `TELEMETRY_EDGE_RECORD_AUDIT_V1_BULK` to
`WorkQueue` retention with no `MaxAge`, keeping `DiscardNew`. That brings back
`DiscardNew` correctly: refusal then means EventWriter really is behind.

## 1. Retention policy: WorkQueue for both source streams

Each source stream has exactly one owning durable
(`serviceradar-event-writer-edge-record`, `-edge-record-audit`) with explicit
per-message ACK after the containing transaction commits. `WorkQueue` removes a
record when its owning consumer ACKs it, so the stream holds only records
EventWriter has not written yet, and `DiscardNew` refuses new publishes only
when the unwritten backlog fills `MaxBytes`. `Limits` is rejected: it keeps
ACKed records until they age out, so a caught-up consumer still fills the cap
(the demo flaw: 918 MiB held, refusal ~2.5h away with nothing able to age out
for 48h). `Interest` is rejected: it drops a published record when no consumer
exists at publish time, which loses records at install and on every consumer
restart gap before the durable is recreated.

At install, before the consumer exists, `WorkQueue` retains published records
(no consumer, no deletion); the durable is created by core's ensure path and
drains them. This is asserted by the real-JetStream retention test, not by
recollection of server semantics.

Overlapping consumers on one source stream are forbidden by construction: the
reconciler creates exactly one durable per stream entry and re-reconciling
never adds another (locked by the retention NATS test). The broker itself
permits overlapping durables on any retention (observed: three durables
coexisting on one stream), so the single-durable rule cannot rely on broker
refusal — like the recovery stream's single shared durable, it is a
configuration invariant the code maintains. The barrier below therefore never
places two consumers on one stream.

## 2. The 1.3 barrier under WorkQueue

The versioned stop/revoke/seal/new-authority barrier operates per physical
stream, never by overlapping two consumers on one stream. For the single-stream
upgrade the seal is literal: the old stream is sealed in place (publishes
refused into spool, no dual-write because there is only ever one stream), its
sole durable drains through final AckWait, redelivery, repair, and rollback
watermarks, the stream is deleted once drained (pending 0, ack-pending 0), and
the reconcile path recreates it with a fresh sole durable. For the future
sharded topology the same barrier flips the publisher map version instead:
gateways publish to exactly one authority per map version while each sealed
old shard drains the same way. The readiness scenario in `nats-tenant-isolation`
(old authority sealed before exactly one new authority is writable) is
unchanged; this design records how it is met without overlapping consumers.

## 3. Dead letters: source changes, DLQ and quarantine do not

Nothing reads source-stream records after they are ACKed. The reader inventory
(EventWriter pull durables, Broadway processors, Replay walk, web-ng DeadLetters
RPC, ConsumerLagReporter polls) shows: Replay republishes DLQ records to the
source subject as new messages (idempotent through the ledger, fenced by
`Nats-Expected-Stream`); inspection (`STREAM.MSG.GET`, runbooks) and the Dead
letters UI read the DLQ and quarantine streams, not the source streams.
Post-ACK source troubleshooting uses DLQ/quarantine/ledger instead; this is a
documented consequence, not a regression.

`TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` and
`TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK` stay `Limits` retention
with `DiscardNew` and `MaxAge` disabled. Both are held-for-inspection streams:
the operator UI groups held records from the stream itself and Replay walks it,
while their processors ACK without removing under `Limits`. Moving them to
`WorkQueue` would delete held records on processor ACK and break inspection,
replay, and the waive/purge audit trail. A refused DLQ copy keeps leaving the
source delivery unacknowledged (existing backpressure, unchanged).

The DLQ duplicate window was derived from the source stream's `MaxAge` (72h).
With source `MaxAge` removed it becomes an explicit 72h constant: a redelivered
source keeps its `Nats-Msg-Id`, and the window must cover the longest possible
redelivery span (20 deliveries under capped backoff, ~25 minutes, plus margin;
72h keeps the current dedup horizon unchanged).

## 4. Ledger retention re-derived

`EdgeLedgerRetentionWorker` drops the stream-`MaxAge` horizon component. The
new horizon is the maximum of the DLQ retention window, the output-grant
lifetime (8d+300s), and the spool retry horizon (~31d, the dominant term, so
removing the 72h component changes no kept row today). The worker test's 72h
stream-`MaxAge` assertion is updated to the re-derived components.

## 5. MaxAge removed on source streams; stuck consumers alert

`stream_max_age` becomes 0 on both source streams. A record that is never ACKed
comes from a stuck consumer; that raises the backlog alert (section 8), it does
not expire silently. (Under the old 72h `MaxAge` a stuck record vanished
unwritten with no signal — the silent-expiry half of the flaw.)

## 6. Upgrade through a drain-barrier cutover, lossless, no dual-write

The broker (verified 2.14.0, the deployed version) refuses `STREAM.UPDATE`
changes to or from `WorkQueue` retention (`stream configuration update can not
change retention policy to/from workqueue`, NATS err 10052); the stream keeps
its shape and records. The dead-letter precedent (in-place discard-policy
change) does not extend to retention. The upgrade therefore seals, drains,
deletes, and recreates each source stream under the same name and subject
(`EdgeRecordStreamCutover`, following the recovery stream's single-durable
model rather than inventing a second pattern):

1. Seal the limits stream in place (full-config `STREAM.UPDATE` with
   `sealed: true`). New publishes are refused with a retryable error and stay
   in agent spool; the owning durable keeps receiving, so no dual-write and no
   publisher coordination is needed.
2. Wait for the drain (pending 0 and ack-pending 0 on the sole durable). A
   missing durable with stored messages waits, never deletes; a deadline
   unseals and alerts, never deletes blind.
3. Delete the drained stream, then let the reconcile path recreate it with the
   production `WorkQueue` shape and durable, and verify `STREAM.INFO`.
4. The periodic edge-retention tick (`ConsumerReconciler`, same interval as
   ownership, own message so ownership stays consumer-free) drives this:
   absent streams are created, converted streams diff-reconciled, limits
   streams cut over. One core at a time cluster-wide (`:global` name
   registration per stream; crashes release it; losers retry next tick).

Pre-switch ACKed records cannot linger: they drain through the old durable
before the delete. In-flight redeliveries complete under the old durable
before the delete. The retention NATS test locks the broker refusal so a
future server version that permits the update fails visibly instead of
silently changing the upgrade path.

## 7. Sizing follows the backlog rule; budget math unchanged

Per-profile `MaxBytes` values are already backlog-sized (small bulk 960Mi ≈ 6h
EventWriter-outage window at burst rate) and already fit the file-store budget,
so no profile size changes. What changes is what the cap means: worst
outage-plus-catch-up backlog, not total traffic. Additionally, the
Compose/packaging installs carry no `TELEMETRY_EDGE_RECORD_*` sizing variables
and run the 1 GiB compiled bulk default outside the enforced budget; this
change adds the variables and the budget-test inventory rows so every install
type sizes and counts the edge streams.

## 8. Convergence and alerting

The 5-minute loop reconciles multi-owner stream ownership only; it does not
re-apply edge stream shapes today (edge shape is re-applied at core
(re)connect). This change adds a periodic edge-shape reconcile using the
existing diff-gated update, so the new policy converges on existing installs
without waiting for a reconnect.

`ConsumerLagReporter` already polls stream and consumer info; it gains a
backlog-ratio signal (stream bytes vs `MaxBytes`, oldest unacked age) and a
managed alert that fires before `DiscardNew` refuses, so a stuck consumer pages
instead of silently filling the backlog cap.

## Out of scope, noted

Alert-candidate streams (`scale-alert-evaluation-pipeline`) repeat
Limits/DiscardNew wording for a different consumer family; their owner analysis
is a separate change, not this one. Gemini's capacity-error classification
(10047/10071/10076/10077 to `{:error, :capacity}`) is kept as-is.
