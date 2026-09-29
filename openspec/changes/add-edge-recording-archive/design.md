## Context

Extend `add-camera-recording-storage` with optional local buffering and continuous
archival. This change owns offline admission and archive receipts, not the
central playback UI or retention holds.

## Decisions

### JetStream staging is optional, finite and admission-controlled

The direct media profile uploads finalized segments to durable object storage
using a bounded local spool. The disconnected-edge profile uses a local JetStream
Object Store as its finite transfer buffer, with the capture process, local NATS
server and archiver all able to run without the hub. Both profiles are part of
this proposal; disconnected capture is an explicit acceptance gate rather than
an inferred benefit of core-side staging. Operators choose the profile and budget.

When JetStream staging is enabled, require nonzero TTL, finite max bytes, maximum
object/segment size, bounded upload concurrency, replica count, placement and
per-deployment total media budget. Use dedicated buckets and reserve space/IOPS
for telemetry; separate buckets on the same disks alone do not provide isolation.
Reuse safe discard-new sizing rules rather than silently evict chunks belonging
to still-needed objects. A full bucket rejects admission; it is not proof of an
accepted complete segment. Interrupted chunk uploads and expiry are reconciled.

The upload deadline is earlier than the oldest segment chunk's expiry by a safety
margin that covers upload/retry duration. Immutable segment objects are never
rewritten to extend TTL indefinitely. Emit oldest-unarchived age, pending bytes,
remaining capacity, upload throughput/failures and lost capture intervals.
At high water, reduce/admit fewer recordings according to explicit policy; at
exhaustion, stop admitting affected recordings and expose gaps. Never expand the
bucket automatically, evict telemetry, or label unarchived footage as retained.
Disabling staging drains or explicitly disposes of pending segments before teardown.

### Disconnected capture and continuous archival

Deploy local JetStream with persistent disks and an explicit domain/account
binding. A leaf connection joins messaging domains; it does not turn a disconnected
edge server into a member of a remote Raft group, automatically replicate an Object
Store bucket, or upload anything to S3. Local recording clients and the archiver
must explicitly bind to the local JetStream domain and bucket. They must not need
remote quorum or a central CNPG connection to finalize a local segment.

The flow is:

```
local RTSP source -> edge recorder -> completed local JetStream objects
                                      -> edge archiver -> permanent S3 objects
                                                       + recoverable manifests
                                      -> durable metadata delivery -> core index
```

The plugin registers/normalizes the source through the existing host interfaces;
the native media worker or dedicated Wasm media bridge supplies media. A long-lived
host recorder and archiver own buffering/upload state, outside the stateless
per-check Wasm execution. Reuse the existing recorder identity/lease and durable
edge-record provenance contracts rather than adding a second plugin transport.

1. Before disconnect, provision an authorized recording assignment, local storage
   policy and a finite offline operating window. Recorder ownership is fenced
   locally; policy/credential expiry is an observable stop condition. Do not
   require a fresh central lease round-trip for every captured segment. Bind
   capture provenance to the policy/owner epoch so later upload can be validated.
2. Finalize a bounded keyframe-aligned segment locally; verify complete object
   storage and append its immutable identity to a durable pending-work journal.
   The complete-object catalogue plus journal reconciliation repairs a crash
   between these steps. Object-store watch events alone are not a durable queue.
3. The archiver starts work as soon as a segment is complete, not when a recording
   session closes or a staging high-water mark is reached. It tests S3 reachability
   independently of leaf status: if S3 is reachable while the hub is not, upload
   continues. Use bounded concurrency, bandwidth budgets and jittered retries.
   Oldest safe-deadline work gets priority; retry state survives process restart.
4. Upload under a stable object identity. Resume multipart state where supported,
   or retry a bounded segment; reconcile completed uploads before retransmission.
   Verify byte length and content checksum (an ETag is not generally a content
   checksum), then persist and verify an immutable archive manifest containing
   source/policy epoch, time mapping, codec/init references, digest and object key.
   An existing matching object/manifest is success; a conflicting one is an error,
   not an overwrite. Initialization objects must be archived before dependent
   media is eligible for local reclamation.
5. Durably record the archival receipt locally and enqueue index publication.
   Local media bytes may be deleted after verified media plus a recoverable
   archive manifest exist; do not wait for the core database to reconnect. Keep
   receipt delivery retryable, and make the S3 manifests sufficient to reconstruct
   missing index entries if the local node is lost after reclamation. Central
   playback remains unavailable until authorization/index publication catches up;
   local state distinguishes archived-but-not-indexed from globally available.
6. When the leaf reconnects, reconcile receipts and publish idempotent core index
   updates over the authorized metadata path. A leaf reconnect or a JetStream
   PubAck alone never proves S3 archival. Optional NATS stream sourcing/mirroring
   is a separately configured transport choice with tested subject permissions;
   it is not required to copy video through a central NATS disk before S3.

During an offline interval, capture consumes the configured local byte/time
budget. Several hours of recording requires several hours of measured capacity,
not a minutes-long TTL. TTL is a final bound, not the normal eviction schedule:
successful archiving reclaims objects promptly. Admission requires that the oldest
unarchived segment can survive the promised offline window plus catch-up/safety
margin, or the deployment must explicitly accept a shorter coverage window.
If the link returns slower than capture produces data, backlog cannot drain;
show estimated time-to-full and the policy-selected reduced admission or stop.
Telemetry and control retain reserved bandwidth/storage during catch-up.

Expose captured, locally staged, uploading, archived-but-not-indexed, globally
available and gap intervals separately. Measure effective archive goodput,
oldest-unarchived age, backlog bytes, drain ETA, storage headroom and expiry risk.
Capture never claims unlimited disconnected retention or unqualified losslessness.
Offline credential refresh/revocation and policy-expiry behavior must be tested;
credentials for S3 are infrastructure credentials scoped to the assigned media
prefix, never a new camera-secret store inside a plugin.

NATS [cross-domain leaf and stream-source documentation](https://docs.nats.io/reference/2.12/jetstream/cross-account-subjects)
describes explicit domain addressing and permissions. Freeze deployment configs
against the installed NATS/client versions; do not depend on undocumented automatic
Object Store mirroring or on features from a newer server release.

### Capacity and catch-up

All numbers below are invented planning examples, not measurements or defaults.

Let `R = sum(admitted peak bitrates) / 8` bytes/second, `W` be the maximum staging
window in seconds, `H` a measured overhead/headroom factor, and `N` replicas:

- logical staging cap must cover at least `R * W * H`, plus bounded in-flight
  partial uploads/metadata not already included in the measurement;
- aggregate physical reservation starts at `logical cap * N`, then adds node
  failure/rebuild headroom and separately reserved non-media storage;
- each placement node needs sufficient capacity for the replicas it hosts; an
  aggregate sum alone does not establish that placement or failover is possible;
- sustained archival throughput must exceed `R`; recovering backlog `B` within
  deadline `T` needs at least `R + B/T` archival throughput;
- retained bytes start at `R * retention_seconds`, adjusted for measured recording
  duty cycle, audio/metadata, object overhead and exports/holds. Do not assume
  compression savings for already compressed H.264.

Example: 24 sources at 3 Mbit/s total 9 MB/s. Thirty minutes is 16.2 GB logical
payload. With 30% headroom, plan 21.06 GB logical and 63.18 GB at three replicas,
before failure reserves and other streams. Seven continuous days are 5.4432 TB of
payload in archival storage. This is why short staging and recording retention
are separate controls. Variable-bitrate peaks, replica traffic, read concurrency,
object request rate and disk/network throughput must also pass admission sizing.

Upstream [NATS ObjectStoreConfig](https://github.com/nats-io/nats.go/blob/main/jetstream/object.go)
exposes TTL, MaxBytes and Replicas; defaults do not impose expiry or a byte cap.
Its object-store stream construction uses discard-new. Verify the installed
server/client behavior, including partial-object expiry, in the acceptance target.

## Rollout

Disabled until the multi-hour outage/restart/reclamation proof passes. Stop
admission and drain or explicitly account for loss before disabling staging.
No universal staging-size default is safe for every deployment.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
