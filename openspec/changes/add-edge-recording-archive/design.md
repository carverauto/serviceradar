## Context

This change owns disconnected admission and archive reconciliation, building on
`add-vms-storage-playback-engine` and the three modes in
[add-scalable-camera-recording-plane](../add-scalable-camera-recording-plane/design.md).
It does not own a second recorder implementation or central playback UI.

## Decisions

### One filesystem path, no JetStream media staging

Use a qualified exclusive filesystem lifetime for finalized media and a durable
pending-work journal. No recording payload is staged in JetStream Object Store,
replicated through a media stream, or forwarded through the central broker.
NATS remains the metadata, job and telemetry transport. This is an architecture
choice, not a claimed measured throughput ceiling for NATS.

The S3-backed mode uses a finite outage/recovery buffer; the local-only mode uses
a durable local archive sized for retention and holds. Neither mode requires a
local JetStream Object Store or remote quorum to seal a segment. Separate
filesystem paths on the same disk alone do not establish resource isolation:
reserve disk space, I/O and network capacity for telemetry/control explicitly.

Require finite byte, segment-size, in-flight work, concurrency and age/coverage
budgets plus qualified physical placement and failure headroom. An upload age
budget is an admission/alert boundary, not permission to delete unarchived data.
At high water, reduce/admit fewer recordings according to explicit policy; at
exhaustion, stop affected capture, preserve existing pending/held footage and
reserved journal space, and expose gaps. Never grow storage automatically or
label unarchived footage as retained. Disabling storage drains or explicitly
accounts for authorized disposition of pending segments before teardown.

### Disconnected capture and continuous archival

The flow is:

```
local source -> authenticated media bridge -> host recorder -> sealed filesystem media
                                                            -> optional S3 archive
                                                               + recovery manifests
                                                            -> durable metadata journal
                                                               -> core index
```

The plugin registers/normalizes the source through existing host interfaces;
the native reader or dedicated Wasm media bridge supplies media. A long-lived
host recorder/archiver owns state outside stateless per-check Wasm execution.
Reuse recorder identity, lease and provenance primitives with the explicit
assignment/offline extensions in the scalable recording proposal.

1. Before remote-control disconnect, provision a finite grant bound to assignment,
   policy/owner epoch, storage lifetime and resource/credential budgets. Local
   ownership is fenced. Policy expiry or uncertain remaining validity after reboot
   stops new capture; no per-segment central lease is needed. A self-hosted local
   control plane needs no SaaS grant. Outstanding grants constrain remote reassignment.
2. Seal a bounded keyframe-aligned segment and initialization dependencies, verify
   complete filesystem publication, then journal immutable pending work. A scan of
   sealed records plus journal reconciliation repairs crashes between these steps;
   filesystem notifications alone are not a durable work queue. Partial records
   remain unavailable and are reconciled within their reserved budget.
3. In S3-backed mode, upload as soon as a segment is complete, not at session close
   or high water. Test S3 reachability independently of hub status. Use bounded
   concurrency/bandwidth and jittered persistent retries, prioritizing the oldest
   pending work within policy. In local-only mode, verify durable local manifest
   and catalog publication instead; no S3 call or receipt is required.
4. S3 uploads use stable immutable identities. Persist/reconcile multipart state;
   verify length and the endpoint-qualified content checksum, not an ETag alone.
   Verify recovery manifests containing source/policy epoch, time mapping,
   codec/init references, digest and object key. Matching existing output is
   idempotent success; conflicting output is an error, not an overwrite.
   Archive initialization dependencies before dependent media is reclaimable.
5. Persist the archival receipt locally before reclaiming S3-backed media. Verified
   media plus recovery manifests allow reclamation without central CNPG; receipt
   delivery remains retryable. Manifests must reconstruct missing index entries
   if the edge is lost after reclamation. Local-only media is retained according
   to retention/hold policy and cannot use this S3 reclamation rule.
6. On hub reconnect, publish/reconcile idempotent metadata through the authorized
   path. A leaf connection or PubAck is not S3 proof. Global playback requires
   authorization/index publication even when bytes are already archived. Stale
   owner live writes remain rejected; historical reconciliation requires the
   retained grant/provenance contract rather than bypassing ownership checks.

Capture consumes finite local capacity while storage or control is unreachable.
Admission must cover the promised outage plus catch-up/safety margin, or state
an explicitly shorter coverage window. If recovered archive goodput is no greater
than capture, backlog cannot drain; report that fact and time-to-full and enforce
reduced admission or stop. Do not silently expire pending footage to hide pressure.

Expose captured, provisional local, durably retained local, uploading,
archived-but-not-indexed, available and gap intervals separately. Measure oldest
pending age, backlog bytes, effective goodput, drain ETA and remaining capacity.
Test offline credential refresh/revocation, policy expiry, restart/clock uncertainty
and reconnect. Infrastructure credentials remain purpose-scoped; camera secrets
stay in the unified credential inventory, never a plugin-local secret store.

### Capacity and catch-up

[Capacity and acceptance](../add-scalable-camera-recording-plane/capacity-and-acceptance.md)
is the shared sizing contract. S3 buffer sizing uses admitted peak bitrate times
outage duration plus measured overhead, in-flight work, cache and journal reserves.
Local-only retention sizing covers the retained history, holds and failure reserves.
Physical replication, if selected, increases physical reservation; per-node
placement, disk throughput and failure/rebuild headroom must also qualify.

For ongoing capture rate `R`, backlog `B` and effective upload rate `U`, backlog
drains only when `U > R`. Recovery in time `T` requires `U >= R + B/T`. Archive
retention is a separate duration/budget; do not assume additional compression
savings for already encoded media. Variable bitrates, object request rate,
concurrent reads and metadata overhead belong in measured admission sizing.

## Rollout

Disabled until multi-hour synthetic outage/restart/reclamation proof passes for
the selected mode. Stop admission and drain or explicitly account for authorized
loss/disposition before disabling storage. There is no universal disk-size default.
Local-only durability and S3 recovery are separate qualification results.

## Delivery and isolation

Use Treehouse and remote RBE with `--config=remote`; no local compilation or new
shell scripts. Automated database tests use the srql-fixtures scratch lifecycle.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and `make test`; deliver every PR through no-mistakes.
