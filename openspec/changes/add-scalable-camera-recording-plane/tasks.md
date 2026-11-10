# Implementation plan

Implementation and deployment tasks remain open until their own evidence exists. The synthetic capacity ladder is a target,
not a shipped camera-count guarantee.

## 1. Contracts and qualification design

- [x] 1.1 Review/approve the three supported modes, independent recorder tier and no-JetStream-media decision.
- [x] 1.2 Specify source routing/consumer lifecycle and assignment/handoff transitions, including all crash and partition boundaries. [Source lifecycle](source-lifecycle.md) defines the three lifetimes, consumer ordering, transition evidence and failure matrix; implementation and offline-grant qualification remain open.
- [ ] 1.3 Specify finite offline grants, conservative expiry/reboot behavior and provenance-checked historical reconciliation without weakening stale-owner fences.
- [x] 1.4 Define local durable publication/restore/hold guarantees separately from provisional spool and S3 archive proofs. [Local publication](local-publication.md) defines durable ordering, authoritative recovery and preservation/deletion outcomes; implementation and storage qualification remain open.
- [ ] 1.5 Select measurable per-mode coverage, latency, outage, recovery, retention and cost SLOs; record supported codec/hardware profiles.
- [ ] 1.6 Reconcile the core-attached persistence rollout with recorder-pool packaging before a production controller conversion.
- [ ] 1.7 Specify outbound live attach and historical range/cancel/reconnect protocols over agent-established connectivity, with no inbound customer dependency.
- [ ] 1.8 Specify playable fragment indexes, bounded read-ahead, authorization-safe shared cache behavior and measurable startup/seek/rebuffer budgets.

## 2. Recorder and source lifecycle

- [ ] 2.1 Extract/package the existing recording primitives as an independent service with remote Bazel artifacts and resource limits.
- [ ] 2.2 Add deployment-scoped pools, enrollment/capabilities, capacity reservations and explicit source/profile ownership.
- [ ] 2.3 Route cloud and customer-local ingest to the assigned recorder; preserve agent ownership and bounded authenticated media transport.
- [ ] 2.4 Maintain recording without viewers and enforce Membrane fan-out from one source and one edge-to-cloud live uplink per camera/profile across concurrent viewers and relay replicas; preserve current viewer-only behavior.
- [ ] 2.5 Implement drained handoff, fencing, volume preservation, restart recovery and explicit unresolved/gap states.

Standalone NVR runtime checkpoint for 2.1: `serviceradar-nvr` packages temporary,
bounded local recording workers around the shared writer. Core retains its lease,
authorization and publication adapters. A disabled-by-default StatefulSet gives
each replica a retained PVC, a distinct configured storage UUID and CPU/memory
limits. Storage replication belongs to a qualified CSI provider; local-only
retention does not require S3. Remote release/media and Helm tests cover this
packaging boundary. Pool enrollment, authenticated transport, aggregate disk
admission, archive publication, automated journal recovery and physical node-loss
qualification remain pending; task 2.1 is not yet complete.

Shared-library extraction checkpoint for 2.1: `serviceradar_recording` owns the
existing bounded inbox, H264/CMAF packaging, storage identity and journaled spool.
Core consumes this library instead of owning duplicate implementations. Remote
Bazel production/test artifacts use media and data-type libraries; spool recovery
runs without core, CNPG or cluster startup. Existing media and playback fixtures
exercise the core-to-library integration. This does not package a runnable
recorder service, establish process resource limits, enroll a pool or enable
continuous recording. Task 2.1 remains open.

Agent-local shared-ingest checkpoint for 2.4/2.5: relay admission reserves the
normalized source/profile before opening upstream, and holds that reservation
through source teardown even when a Stop caller times out. Plugin Close waits
for executor cleanup and slot release. Distinct cameras/profiles remain
independent. This closes duplicate admission within one agent manager; it does
not implement cross-agent fencing, recorder pools or continuous recording, so
2.4 and 2.5 remain open.

Open-command identity checkpoint for 2.5: a new relay reservation persists its
command UUID before dispatch, and the command ledger and control-stream request
use that UUID. Concurrent opens reuse the reservation; an interrupted opener
does not erase its command correlation. This does not replay an interrupted
dispatch, reconcile an agent incarnation, or prove physical retirement. Those
recovery and handoff tasks remain open, as does command-ledger retention beyond
its existing cleanup policy.

Close-command identity checkpoint for 2.5: the closing transition reserves a
separate stop-command UUID before dispatch. The command ledger and control-stream
request use that UUID; repeated close requests retain it without sending a second
stop. A mismatched dispatch reply cannot replace it or reopen the closing relay.
Existing closing and terminal rows retain an unknown stop identity. This provides
correlation after a caller dies; it does not replay an interrupted stop, interpret
an acknowledgement as physical retirement, extend ledger retention or implement
incarnation-aware reconciliation. Task 2.5 remains open.

Source-runtime identity checkpoint for 2.5: a camera relay manager generates one
UUID for its source registry lifetime and sends it on authenticated media open.
Core persists it at first activation. Repeat activation must retain that identity;
changing or omitting a known identity is rejected before lease renewal. Older
agents remain compatible with an explicitly unknown identity, and an already
active legacy relay cannot adopt a new identity. This does not reconcile a lost
command, fence an earlier runtime, or prove physical retirement. Control reconnect
does not replace the source registry. Pools and continuous recording remain open.

Stop-target incarnation checkpoint for 2.5: Core carries a relay's persisted
source incarnation through the command ledger and control-stream stop payload.
The agent rejects a different incarnation before looking up or cancelling the
session. A matching stop still targets the captured session ID. Missing identities
retain the existing compatibility behavior and remain unknown; older agents do
not enforce the new field. This is a prerequisite for interrupted-stop recovery,
not a replay/reconciliation implementation or proof of physical retirement.
Task 2.5 remains open.

Stop-observation checkpoint for 2.5: an incarnation-aware stop captures its
session handle before cancellation. Retries with the same command identity,
normalized content and original deadline observe that handle, including after a
lost reply or relay-ID reuse. Changed content is refused. A read-only command
reports pending, completed, unresolved source-close errors or unknown operations;
Core addresses it using the persisted stop UUID and source incarnation and stores
the response in the existing command ledger without changing relay ownership.

Observations are process-local, limited to 4,096 entries and retained only through
the original command deadline (at most five minutes). Capacity exhaustion refuses
new tracked stops before cancellation; expiry returns unknown and refuses the
expired mutation. Restarted registries reject the old incarnation. Stops without
an incarnation keep legacy behavior and have no recoverable observation. This
checkpoint does not automatically replay interrupted dispatches, persist an agent
journal, interpret local completion as qualified physical retirement, or change
the compatibility lease/reaper. Task 2.5 remains open.

Operator stop-recovery checkpoint for 2.5: authenticated camera API endpoints
submit the read-only query and read its retained command result by query UUID.
The reader authorizes the saved session, correlates the command agent/type and
stop/session/incarnation identities, and validates source/profile identities for
known observations. Delivery status is separate from the observed stop state;
missing, failed, expired or malformed replies do not imply completion. Only the
bounded observation projection is returned. Local completion remains explicitly
unqualified for retirement and cannot mutate relay ownership or leases. See the
[recovery API runbook](../../../docs/camera-relay-stop-recovery.md). Automatic
reconciliation, physical fencing and durable agent journaling remain open, as
does task 2.5.

Open-retry checkpoint for 2.5: the agent coalesces identical open commands and
retains the original startup outcome, including failures and successful receipts
after source teardown. Changed normalized content or command deadlines are
refused while retained. The cache admits at most 4,096 operations through their
original deadlines (at most five minutes); expired commands and new operations
at capacity cannot open a gateway session or camera. Synthetic native RTSP and
Wazero runtime coverage exercises lost replies, duplicate opens and teardown.
See [open retry limits](../../../docs/camera-relay-open-recovery.md). This is
registry-local deduplication, not restart fencing or automatic Core replay.
Task 2.5 remains open.

Open-observation checkpoint for 2.5: authenticated camera recovery routes query
and read the original open outcome without replaying startup. Agent receipts
retain non-secret target identities and return pending, succeeded, failed or
unknown within their original deadline. Core correlates the command, agent,
session, operation, incarnation and source/profile; missing incarnation remains
explicitly unqueryable. Retained ledger replies survive a requesting caller.
Historical outcomes do not change ownership, prove liveness or retirement, or
authorize a replacement. Durable recovery, fencing and task 2.5 remain open.

## 3. Storage modes and recovery

Explicit interrupted-block recovery checkpoint for 3.2/3.3: the standalone NVR
can verify, repair uncommitted tails and seal one nonempty retained block using
its expected identity and original clock provenance. Recovery refuses active
local reservations and runs serialized against new admission, under inventory,
storage identity and physical free-space checks. Corrupt, empty and mismatched
blocks remain unresolved and untouched. Shipped-release tests abruptly halt a
recording VM, recover only the committed prefix after restart, verify refused
repairs preserve bytes and independently decode the recovered frames. The caller
must establish prior writer retirement and exclusive attachment; this operation
does not supply distributed fencing, automatic reconciliation, durable gap state
or publication authority. Tasks 3.2 and 3.3 remain open.

Aggregate local read checkpoint for 3.7: inventory, inspection, descriptor and
media reads share four independently supervised read slots with ten-second
admitted-task deadlines. Saturation refuses work without using recording slots;
worker expiry bounds orphan lifetime after caller loss. Shipped-release tests
exercise saturation, worker failure/expiry, caller loss and read-supervisor
restart while a recording reservation survives. This bounds active local read
work, not downstream buffers, kernel I/O latency, per-viewer fairness or remote
playback authorization/cancellation. Task 3.7 remains open.

Descriptor-bound local read checkpoint for 3.3/3.7: the trusted same-VM
`ServiceRadarNVR.read_block/3` API accepts a block ID, canonical descriptor SHA-256
and an initialization/fragment selector. It verifies the sealed retained block,
compares the descriptor digest and rechecks the selected bytes under existing
runtime bounds. The shipped-release restart/recovery tests reconstruct and decode
media through this API and refuse mismatched digests, invalid selectors and
unsealed/corrupt evidence without repair. The descriptor binding does not supply
authenticated remote playback or catalog publication; active read work is bounded
by the separate admission checkpoint above. Tasks 3.3 and 3.7 remain open.

Portable metadata checkpoint for 2.1/3.3: `serviceradar_recording_metadata`
owns the unchanged canonical v1 descriptor and archive-manifest contract shared
by Core and NVR, without Core, database or media-pipeline dependencies. The
trusted same-VM NVR `block_descriptor/1` API verifies a sealed retained block and
returns portable descriptor JSON after restart. Pure metadata tests preserve the
pinned v1 wire digest; the shipped-release test independently verifies descriptor
bytes and fragment digests alongside decoded synthetic frames. This adds no
publication, assignment protocol, catalog, receipt or playback authority. Tasks
2.1, 3.2 and 3.3 remain open.

Recovered initialization checkpoint for 3.2/3.3: standalone NVR inspection and
explicit recovery attach the initialization digest, timescale and baseline AVC
codec declaration derived from retained, verified init bytes. Live packaging uses
the same parser; no new persisted sidecar or Core dependency is needed. Synthetic
release restart tests assert format metadata and independently decoded frames;
malformed/unsupported initialization with valid journal hashes is refused without
inspection changing files. Format decoding follows explicit repair/seal, so a
format error does not imply that recovery made no progress. This is local media
evidence, not a publication receipt or playback authorization. Tasks 3.2 and 3.3
remain open.

Durable intent checkpoint for 3.2/3.3: trusted same-VM callers can explicitly
persist one bounded immutable `publication.json` for a verified sealed block.
The record binds the storage lifetime, descriptor and stable operation/Core block
references, survives restart, and is reverified before reading or exact retry.
Preparation is serialized while local writers are idle, charges new bytes before
writing and syncs the file/directory. Conflicting or partial records remain
untouched. Release tests exercise persistence, retry, corruption and admission.
This records authority correlation, not authority proof or catalog availability.
Authenticated Core acknowledgement, continuous-capture publication, separate
control reserves, scheduling and holds/disposition remain open; tasks 3.2 and 3.3
are not complete.

Core intent reconciliation checkpoint for 3.2/3.3: the shared v1 codec preserves
NVR intent bytes, and a trusted Core caller can durably acknowledge an intent
against the locked original frozen block. One immutable operation per block
binds storage UUID, block key and descriptor/content hashes. Exact retries return
the original acknowledgement; conflicting operations and authority substitutions
are refused, including after recorder replacement. The serial CNPG integration
owner exercises persistence, authorization, competing operations and retries.
This is intent acceptance only, not qualified local-copy registration or playback
availability. Authenticated delivery, storage
qualification and the remaining publication/disposition lifecycle are still open.

Local acknowledgement checkpoint for 3.2/3.3: Core returns canonical
`intent_accepted` bytes only after its immutable acceptance row commits. The
response binds the operation UUID and digest of the complete intent. Trusted
same-VM NVR callers can persist it as `publication-ack.json` after reverifying the
intent/media and syncing the original intent. Both files survive restart and
remain retained; exact retries sync the same bytes, while incomplete, conflicting
or aliased records remain unresolved. New bytes are capacity-accounted while
writers are idle. Bounded inspection reverifies the intent/media without writing.
The release test owns restart, corruption, preservation and capacity behavior;
Core integration owns committed acknowledgement emission and stable retries.
This is not authenticated remote delivery, qualified local-copy registration,
playback availability or permission to compact intent/preservation history.
Tasks 3.2 and 3.3 remain open.

Publication headroom checkpoint for 3.2/3.3: recording admission and rotation
reserve the bounded intent and acknowledgement sizes independently of media for
each new block and each missing retained record. Inventory reconstructs those
allowances after restart, and write guards keep publication headroom after a
worker exits. Idle publication spends only its own missing-record allowance;
other pending records remain reserved, exact retries allocate nothing and
partial records remain unresolved. Shipped-release coverage proves admission
refusal before metadata space is consumed and reuse of unused allowances after
publication. This is byte accounting, not filesystem preallocation or storage
qualification. Concurrent publication, broader hold/disposition reserves,
authenticated delivery and continuous capture remain open; tasks 3.2 and 3.3 are
not complete.

Concurrent local publication checkpoint for 3.2/3.3: one supervised task verifies
and persists intent/acknowledgement records outside the capacity owner while
recording admission, write checks and rotation continue. Capacity authorizes the
write from fresh inventory and keeps its full byte reservation until task exit,
including when the file already appears in inventory. Saturation refuses without
a waiting queue; a thirty-second task deadline survives caller loss. Recovery
remains exclusive. The shipped-release test stalls a real publication task,
records and rotates 510 synthetic frames, verifies decoded output, persists the
acknowledgement during capture, and checks deadline cleanup and retry after caller
loss. Publication-supervisor failure preserves capture; loss of capacity
accounting retires publication tasks. Authenticated remote delivery, scheduling,
catalog completion and storage
qualification remain open; tasks 3.2 and 3.3 are not complete.

Read-only discovery checkpoint for 3.2/3.3: a restarted standalone NVR can list
bounded retained block IDs and verify one sealed snapshot without an earlier
notification or expected-identity receipt. The shared journal reader validates
media, seal, directory identity and exact file lengths without repairing tails.
Incomplete and corrupt blocks remain untouched. Synthetic shipped-release tests
discard receipts before restart, independently decode discovered blocks and
verify byte preservation on refused inspection. This is local recovery evidence,
not a durable delivery acknowledgement, catalog, assignment reconciliation or
publication proof. Tasks 3.2 and 3.3 remain open.

Block rotation checkpoint for 3.2: the finite standalone session seals a full
block before admitting its successor, keeps its original deadline and media
packager, and reuses verified initialization data with an incremented block
sequence. Capacity replacement is serialized and retains the old block's bytes
in inventory. A refused successor stops capture without deleting completed
blocks. Local notifications expose sealed snapshots but are not a durable
outbox or catalog. Synthetic release tests recover and independently decode
multiple blocks after restart and verify preserved coverage when the next
reservation is refused. Continuous authority, durable gap/outbox state, reserved
on-disk control allocation and automated recovery remain open; task 3.2 is not
complete.

Aggregate admission checkpoint for 2.1/3.2: the standalone finite-block runtime
serializes full-block reservations against a configurable per-replica logical
spool budget and available filesystem space. Read-only inventory counts retained
and incomplete files before admission, including after restart. Worker exit does
not reclaim those files. Capacity-owner loss retires dependent workers before
new admission. Unknown inventory and low space refuse work without deletion;
write guards refresh pressure observations at most once per second. Release tests
exercise competing admissions, worker/accounting restarts, retained media after
release restart, a physical free-space floor and refused aliased inventory.
This is not continuous sealing, durable gap/outbox publication, reserved on-disk
control allocation, journal reconciliation, retention or physical node-loss
qualification. Tasks 2.1 and 3.2 remain open.

- [ ] 3.1 Install qualified exclusive per-recorder filesystem volumes with explicit identities/initialization for Kubernetes and supported customer hosts.
- [ ] 3.2 Implement continuous bounded sealing, durable journal/outbox and capacity/pressure admission with reserved control space.
- [ ] 3.3 Implement local-only durable catalog/manifest publication, owner-aware authorized playback, retention/holds and restore without S3 or SaaS calls.
- [ ] 3.4 Complete qualified S3 upload/multipart reconciliation, recoverable manifests and receipt-based reclamation; preserve every existing provider/security check.
- [ ] 3.5 Enforce outage/catch-up budgets and independent archive/index availability; test `U <= R`, full disk, restart and lost responses.
- [ ] 3.6 Implement explicit mode/data-residency transitions without retargeting or deleting historical media.
- [ ] 3.7 Implement authorized outbound playback of customer-local recordings and bounded S3 fragment/range delivery with seek cancellation and isolated cache budgets.

## 4. Customer hardware, workers and Cloud

- [ ] 4.1 Implement customer-host enrollment, signed updates, supported architecture checks and bounded offline operation.
- [ ] 4.2 Implement metadata-only durable analysis queues and independent CPU/GPU admission, with slow-worker/expired-job isolation proof.
- [x] 4.3 Scope/file linked control-plane work for customer pools and mode-aware provisioning: [Cloud #191](https://github.com/carverauto/serviceradar-control/issues/191) records the extensions to #182/#183/#184/#190 in cloud-scope.md. This completes issue scoping only.
- [ ] 4.4 Implement mode-aware desired/applied reporting, quotas, metering, credential custody and preservation-aware lifecycle in Cloud.
- [ ] 4.5 Verify complete on-prem operation needs no SaaS entitlement/heartbeat or object storage when local-only mode is selected.

## 5. Acceptance and rollout

- [ ] 5.1 Preserve existing media, ownership, storage, publication, permission and browser assertions; add behavior tests through actual service/protocol boundaries.
- [ ] 5.2 Execute the synthetic 100/1,000/10,000-stream ladder, steady-state soak and independent generator qualification with explicit SLO failures.
- [ ] 5.3 Exercise all three deployment modes and the failure matrix in capacity-and-acceptance.md, including local-only recovery and concurrent live viewing.
- [ ] 5.4 Run remote builds/tests and full make test; deliver each implementation through Treehouse/no-mistakes with remote rc files in every checkout.
- [ ] 5.5 After synthetic qualification and explicit deployment approval, run bounded live acceptance and verify test-resource cleanup; keep operational identifiers/media private.
- [ ] 5.6 Publish measured supported profiles and unresolved limits; do not infer support from design, estimates, installed PVCs or visible GPUs.
