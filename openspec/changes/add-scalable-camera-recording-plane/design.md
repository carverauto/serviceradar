# Scalable recording plane

## 1. Placement and storage are separate choices

| Supported mode | Recorder placement | Durable recording destination | Local capacity role | Cloud dependency |
| --- | --- | --- | --- | --- |
| Cloud + S3 | Managed recording pool | Qualified private S3-compatible archive | Bounded outage buffer and optional read cache | Hosted control/runtime |
| On-prem + local | Customer hardware | Qualified retained filesystem volumes | Full configured retention, holds and recovery reserves | None for a complete self-hosted deployment |
| On-prem + S3 | Customer hardware | Qualified configured S3-compatible archive | Bounded outage buffer and optional read cache | S3 connectivity; SaaS management is optional |

An installation may assign different cameras to different compatible pools and
storage policies. Each camera/profile has one explicit current assignment;
placement is not inferred from whichever core pod or viewer is available.
Switching policy creates a controlled transition. Existing recordings retain
their original storage/authorization identity until explicitly migrated and
verified; a configuration edit never retargets historical media.

In on-prem + local mode, do not silently provision a bucket, attempt an upload,
require provider credentials or report local retention as S3-backed durability.
An on-prem S3-compatible service is also a possible configured destination after
qualification, but it is not required for the local-filesystem mode.

## 2. Service responsibilities and byte path

- The deployment's core remains the policy, inventory, assignment and index
  authority. CNPG/Ash stores current control state, recording indexes and holds.
  It does not receive a database transaction for every frame.
- A separately supervised recorder service reuses the existing Membrane/media,
  immutable block, spool identity, journal and publication boundaries. CPU,
  memory, file descriptors, network and disk I/O have independent limits from
  core. First package for qualified Linux AMD64/ARM64 hosts and Kubernetes;
  other platforms require capability qualification, not a silent fallback.
- Existing agents open camera sources with the unified credential model. For a
  cloud assignment, gateway media ingress routes to the assigned recorder pool
  instead of requiring all recording bytes to transit core. Gateway media
  capacity and placement must scale too; moving a bottleneck to one gateway is
  not success. For customer-local placement, use a local authenticated media
  bridge/uplink to the recorder without a mandatory WAN hairpin.
- An ingest owner fans out to recording and, on demand, authorized viewer egress
  and bounded analysis taps. Viewer egress may remain in core initially, but it
  subscribes to the assigned ingest rather than opening another RTSP connection.
  Different camera profiles may legitimately have separate source sessions.
  Membrane fan-out is mandatory, not an optional optimization: within a
  deployment, the same camera/profile has one active camera source session and
  one edge-to-cloud live media uplink, independent of viewer count. The latter
  is needed only when the cloud path has an admitted consumer; archive transfers
  are a separate workload, not another live viewer uplink.
- Local media goes to the recorder's retained volume. An S3 policy additionally
  transfers sealed blocks through the qualified storage boundary directly to
  that destination. Do not route archive payloads through core or JetStream.
- Analysis/transcription services fetch bounded authorized media from the local
  owner or archive reader. They cannot stall primary capture, sealing or upload.

Do not join customer hosts to a cloud Erlang distribution cluster. Enrollment
and authenticated, bounded RPC/media protocols carry control and data across
that boundary. Elixir RPC/PubSub may serve ephemeral notifications inside a
trusted local runtime; durable work uses JetStream metadata and idempotent
consumers. A standalone edge recorder needs a persistent local journal, not a
local JetStream Object Store or a remote quorum to append media.

### Outbound-only viewing of customer-hosted media

The browser contacts the public deployment runtime, never a customer-private
recorder address. After authorization, the runtime sends a start/attach request
over the agent-established bidirectional control connection. The agent attaches
to the assigned local ingest and initiates a separate authenticated media RPC
through the gateway. A public Membrane relay fans out the shared upload to each
authorized browser's own WebRTC transport. The browser-facing protocol does not
require the agent's uplink to be WebRTC.

The existing monitoring `ControlStream` and live client-streaming camera
`UploadMedia` establish this outbound transport pattern, but do not implement
the proposed remote recorder and historical range contracts. Bulk bytes do not
travel in control messages or JetStream. The default route uses the existing outbound gateway path, with
independently scalable gateway/media backends and explicit media/control budgets.
Separate RPCs alone do not prove congestion isolation on a shared connection;
qualification must prove control responsiveness under saturated media traffic.

Concurrent first viewers, requests arriving at different relay/core replicas,
and reconnects resolve the same assignment-scoped source and live uplink owner.
Additional relays subscribe downstream through bounded Membrane fan-out; they
never open their own source or edge upload. An unresolved owner fails admission
or waits within a deadline rather than bypassing ownership with a duplicate.
Slow viewers have bounded queues and can be disconnected without stalling other
viewers, capture or archival. Closing the last remote viewer releases remote
viewing resources only; an admitted local recording continues.

Historical reads use typed recording IDs, authorized intervals and bounded byte
ranges derived by the runtime from trusted metadata, sent over the existing
outbound control path. The agent reads from the
authenticated local recorder and pushes responses over a separate media RPC.
Specify request/session identity, range ordering, byte limits, cancellation,
deadlines and reconnect behavior before implementation. Do not build an arbitrary
URL, filesystem or general-purpose network tunnel. Fresh recording-read and
interval authorization apply to requests and returned bytes.

No inbound ports, VPN, public recorder endpoint or customer cloud-BEAM membership
is required. On WAN loss, local recording remains governed by its existing
finite offline authority; hosted remote viewing reports unavailable unless the
requested footage already has a verified cloud-reachable copy. A private S3
endpoint unreachable from Cloud uses the outbound read bridge too. Fully
self-hosted users may view through their local deployment without SaaS.

## 3. Recording independent of viewers

[Source lifecycle](source-lifecycle.md) specifies the source, recording-assignment
and cloud-uplink lifetimes, consumer ordering and handoff/reconciliation matrix.
Those contracts are requirements for the new recorder path, not a claim that
the current core-attached capture API implements continuous recording.

A recording policy admits a persistent consumer for the camera/profile. Closing
all browser sessions releases viewer resources only. The source remains active
while the recording assignment is authorized, including scheduled continuous
recording with no prior viewer. Viewer-only sources keep their existing idle
teardown behavior. Attach/detach operations are bounded and consumer-specific.

Keep encoded-stream passthrough/remux as the default; compatible recording does
not depend on GPU capacity or routine decode/re-encode. Codec changes, missing
keyframes, source reconnects and uncertain clocks close a block or produce an
explicit discontinuity within existing byte/time limits. Never invent UTC,
continuous coverage or a playable interval from a heartbeat or connection state.

## 4. Assignment, capacity and handoff

Retain an assignment containing source/profile, authorized ingress agent,
recorder/pool identity, storage lifetime, policy revision, owner epoch and budget.
The existing allocation/lease/provenance contracts are inputs, not proof that
moving their current core-local implementation to a remote host will work.
A protocol and state-machine implementation must explicitly extend them.

Admission considers aggregate admitted peak bitrate, camera count, encoding and
fragment bounds, CPU/memory, network path capacity, disk throughput/IOPS/free
reserve, upload concurrency, pending bytes/age and qualified failure headroom.
Reserve capacity before source activation. Autoscaling adds qualified capacity;
it cannot relocate an active recording merely by changing replica count or by
assuming another node can read the old volume.

Normal handoff proceeds through prepare/reserve, stop old admission, drain and
seal, persist pending-work ownership, confirm source/worker retirement, fence
the old epoch, then activate the new owner. Reads and recovery of old retained
blocks stay bound to their original lifetime. Test crashes at each transition.

A missed heartbeat or elapsed coordinator lease alone is not proof of physical
retirement. If the previous owner or volume is unresolved, preserve it and do
not automatically start a conflicting source/writer. A safe source-side fence
or an independently proven retirement contract is required for takeover.
The current `IngestOwnership` expiry and closing-grace behavior fences database
state only. The new pool path must enforce the retirement evidence in
[source lifecycle](source-lifecycle.md#assignment-transitions-and-required-evidence)
before physical takeover; copying that expiry behavior into a remote recorder
would not satisfy this contract.
Publication rejects stale current-owner mutations; recovery of legitimately
sealed historical blocks must use an explicit provenance-checked reconciliation
path, not bypass that fence. Do not claim zero-gap or exactly-once capture during
an unqualified partition/failover; report the observed coverage.

## 5. Filesystem buffering and storage durability

There is no JetStream media staging option. The default byte path is the existing
private filesystem spool with bounded blocks and a durable pending-work journal.
Use one provisioned storage lifetime per exclusive recorder volume, explicit
initialization, no adoption on startup and no recursive repair. Kubernetes
placement requires qualified mount exclusivity/retention; customer hosts need
equivalent verified volume identity, filesystem durability and writer fencing.
A process lock or a marker alone does not attest a shared volume's exclusivity.

S3 mode sizes local storage for the declared upload-outage window plus bounded
in-flight data, recovery headroom and any separately budgeted read cache. It
uploads completed blocks promptly instead of waiting for a session to end or
a disk high-water mark. Object-store retention is a separate budget.

Local-only mode treats its qualified retained filesystem as the archive, not
as an upload backlog or an expendable cache. Seal, verify media/init/manifests
and durably register local availability before advertising retained coverage.
Expose the actual fault domain, replication and restore guarantees: fsync on one
host is not protection against losing that host's storage. A block still in the
open spool remains provisional in either mode. Retention and accepted holds
must be enforceable by the selected backend; unsupported guarantees are refused.

At high water stop new admission or apply an explicitly selected recording
policy, with gap accounting. At the hard reserve boundary stop affected capture
and preserve journaled/unarchived or protected bytes. Never silently overwrite
them, evict telemetry, enlarge disks or change destinations to conceal pressure.
Normal policy-authorized local retention remains possible after hold/export
checks; disk pressure itself is not deletion authority. Size metadata/outbox
reserves so a full media area can still record stop/gap and recovery state.

## 6. Upload and recovery

Keep immutable identities, checksums, initialization dependencies, recoverable
manifests, per-purpose authorities and publication proofs from the VMS foundation.
Use bounded upload concurrency, deadlines, jittered retry and durable multipart
state. A lost success response triggers reconciliation, not an overwrite or a
second logical block. Verify actual media and manifest identity before local
reclamation. A matching name, HTTP success, ETag or queue acknowledgement alone
is not an archive proof.

S3 reachability is independent of Cloud/core connectivity. With an authorized
unexpired storage operation and reachable S3, an edge uploader can continue
while central indexing is unavailable. Preserve a durable receipt/outbox and
recoverable archive manifests before reclaiming local bytes; reconcile indexes
idempotently later. Distinguish locally committed, uploaded-but-unverified,
archived-but-not-indexed, available and unavailable intervals.

A recovering pool reserves bandwidth for current recording/control while draining
backlog. If effective upload goodput does not exceed incoming bytes, report a
non-draining backlog rather than a fictional recovery ETA. Storage credentials
and operation grants must remain valid for bounded completion or stop safely;
never mint unbounded offline credentials to avoid that constraint.

Multipart completion, checksums and incomplete-upload cleanup require endpoint
qualification. [AWS's multipart contract](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)
distinguishes completion from uploaded parts and notes that an ETag need not be
an MD5 checksum. This is not evidence that another S3-compatible endpoint has
identical policy, locking or recovery behavior. Preserve all existing provider
qualification checks whenever S3 is selected.

## 7. Customer hardware and disconnected operation

A customer-operated recorder is enrolled into exactly one runtime deployment
with explicit allowed cameras, storage, capabilities and resource budgets.
Use deployment-managed mTLS, revocable scoped identity and supported signed
artifacts. Require outbound-only customer-to-hosted control/media connectivity;
do not require exposing cameras or joining unrelated BEAM clusters. GPU and CPU
architectures are reported and measured, not inferred from a host label.

A complete on-prem deployment owns its local control plane, database, messaging
and storage and operates without SaaS. A hosted deployment may manage edge
recorders; loss of that management link then uses the separately defined finite
offline operating grant. The grant binds assignment/owner epoch, local storage,
policy and capacity limits, conservative expiry and credential generation. It
must be persisted before disconnect, fence across restart and refuse uncertain
clock/identity state. Never require a remote CNPG round-trip for every segment.

The coordinator must account for outstanding offline grants when scheduling
replacement owners; do not revoke locally unreachable work merely by changing a
row and then assume it stopped. Test expiry, reboot, clock regression, WAN loss,
revocation and reconnection. On expiry, stop new capture, preserve existing bytes
and pending observations, and reconcile explicit gap/coverage state. No infinite
offline operation or immediate remote revocation is promised.

## 8. Analysis and transcription isolation

Reuse the existing CPU-first object/person detection direction and
[media-worker contract](../add-vms-storage-playback-engine/media-workers.md).
Sample deliberately; record model/config/source provenance and distinguish no
result from no detection. Audio/transcription remains opt-in. GPUs are optional
capacity classes for qualified inference/transcoding; never silently transcode
every camera or fall back to an unbudgeted expensive CPU path.

Use separate queues, concurrency, memory and I/O budgets for live analysis,
bulk transcription and interactive playback/export. Enqueue bounded job metadata
and source references, not video/audio payloads. Resolve short-lived read
capabilities at execution time. Bound queue bytes/age, outstanding acknowledgements,
attempts and per-job runtime; expired work is terminal/reconciled. Crash/redelivery
must not duplicate user-visible results. [JetStream pull consumers](https://docs.nats.io/learn/jetstream/pull-consumers)
provide bounded pull requests and acknowledgement flow control; application
idempotency and resource admission are still required.

Dropping optional live samples is allowed and visible. Losing required recording
bytes is not disguised as dropping analysis. Slow/full/dead CPU or GPU workers
must leave recording, upload and unrelated live viewing healthy. Workers cannot
delete originals, change holds, bypass source authorization or write telemetry
directly to databases. Telemetry goes through JetStream/EventWriter to the active
backend; control/index and explicitly owned derivative projections retain their
existing owners. No video-byte transport is added to telemetry.

## 9. Playback, security and lifecycle

Keep the separate recording-read permission and fresh camera/interval access
checks on every catalog, manifest and byte request. Local playback uses an
authenticated owner-aware bounded range service; a stale owner location is not
permission to expose a filesystem path. S3 playback keeps the verified archive
reader boundary and never hands out access to unauthorized portions of a packed
object. Local storage loss reports unavailable coverage; fallback exists only
when a verified second copy actually exists.

### Object storage playback and bounded buffering

Recorded playback uses an authorized playlist/index and independently playable
fragments, with required initialization data and explicit keyframe/discontinuity
boundaries. The recording index maps time to immutable object identity and
fragment byte ranges. The qualified archive reader fetches only the necessary
fragments/ranges, and the player buffers a bounded amount ahead of presentation.
A seek cancels obsolete prefetch and starts at a valid decode boundary; it does
not require downloading or transcoding the entire recording.

This is an established HTTP playback pattern:
[Apple HLS](https://developer.apple.com/documentation/http-live-streaming?language=objc)
describes playlist-driven segment delivery, and
[AWS documents S3-backed video delivery](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/on-demand-streaming-video.html).
[S3 GetObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html)
supports a byte range per request. These references justify the approach, not
an AWS dependency or qualification claim for another S3-compatible provider.
Retain encoded-stream remux where codecs permit; packaging is not a requirement
to decode/re-encode every recording.

Use explicit per-playback and aggregate byte, concurrency and read-ahead limits.
An optional shared immutable fragment cache coalesces identical in-flight reads
within its serving scope and reuses data across authorized viewers. Cache keys
bind deployment/storage lifetime, immutable object version and range; every hit
still requires current viewer authorization. Do not hand a browser a packed
object URL that exposes intervals outside its grant. Disk cache is optional,
bounded and evictable, with no access to the recorder's reserved spool capacity.
Independent historical seek positions retain independent playback state; shared
fragment reads do not force viewers onto one timeline.

Select read-ahead and any cache capacity from measured startup/seek/rebuffer SLOs,
origin latency, request/egress cost and active playback demand, not total camera
count or archive retention. Cancel abandoned reads and measure wasted prefetch.
No read-ahead can sustain playback if long-run available goodput is below the
selected media bitrate. Report stalls, unavailable media and restore-required
storage states honestly. A CDN is an optional delivery optimization subject to
the same private-origin and interval-authorization contract, not a prerequisite.

Camera/device credentials stay in the unified encrypted runtime credential
inventory and are delivered through existing scoped consumers. Recorder/cloud
infrastructure credentials use approved custody. Keep write/read/lifecycle
storage authorities separate; workers receive no broad bucket or delete key.
Remote hosts do not receive fleet-wide credentials. Private access, endpoint
allowlists, encryption policy and rotation are mode-specific readiness gates.

Drain/disable/uninstall/suspend/terminate retain media and unresolved assignments
until the existing hold/export/retention workflow authorizes disposition. A
customer-host disconnect is not a request to delete its storage. Changing modes
or moving between customer and managed hardware requires observed transfer and
permission to move data across that residency boundary.

## 10. Migration and deliberate limits

1. Approve the architecture and settle measurable storage/coverage SLOs.
2. Extract/repackage existing recorder primitives behind a separate service and
   prove it against synthetic media without changing the default live route.
3. Add one qualified recorder pool, source reuse and zero-viewer recording;
   enable a bounded policy only after runtime/source/storage acceptance.
4. Qualify local-only and S3 destinations separately, then customer-host
   enrollment/offline operation. Full on-prem operation must not depend on a
   SaaS entitlement call or remote heartbeat.
5. Ramp synthetic capacity and failure tests, then one explicitly approved live
   deployment. Keep rollback source ownership and pending media inventory intact.

Existing core-attached capture stays available during migration. Do not move its
retained volumes or reinterpret its UUIDs. The generic volume preflight and
filesystem initializer remain reusable safety components; their success is not
recording readiness. Production scale-out targets recorder pools, not a larger
core StatefulSet. No new runtime cross-customer routing or global bypass is added.

This proposal does not select a detector, promise lossless disaster recovery,
implement GPU sharing, remove provider qualification or enable recording. Buffer
windows, retention, failure-domain protection, maximum gap/recovery times and
supported codecs are configuration/qualification decisions, not universal defaults.
