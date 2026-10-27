# Explicit archive publication

This checkpoint completes one frozen block after independently verified media.
Core derives a recovery manifest from the frozen descriptor and original init
and media proofs. The isolated storage service conditionally writes and verifies
that manifest. A final fenced database transaction records the block's archive
index. Production recording remains disabled.

## Entry point and recovery

`CameraRecording.ArchivePublication.complete_once(block_id)` is an explicit
administration operation beside `MediaUpload.upload_once/1`. The caller supplies
only a block UUID. It cannot choose credentials, files, destinations or keys.
Core returns a coherent status from the retained block and its object proofs:

| Status | Action |
| --- | --- |
| `media_required` | Refuse completion until independent media verification exists. |
| `init_required` | When recording is stopped, return `recording_stopped` before recorder configuration, the spool, manifest preparation or transfer. Otherwise read the bounded sealed init object from the verified spool, transfer it, then prepare and transfer the manifest. |
| `manifest_required` | When recording is stopped, return `recording_stopped` before those same steps. Otherwise use retained init/media proofs to prepare and transfer the manifest. |
| `archive_verified` | Publish the database index without loading recorder configuration, opening local storage or contacting the provider. |
| `available` | Return the original immutable publication receipt without acquiring another lease or performing provider/local-file I/O. |
| `reconciliation_required` | Refuse automatic completion; preserve the original attempted operation and its evidence. |

The command takes a new upload lease only when completion work remains. Its
30-second forward-work budget begins at entry and never renews between phases.
Each network operation is additionally bounded by its own original authority,
grant and dispatch deadlines. Lease release runs on every acquired-lease exit;
bounded evidence reporting and cleanup do not renew provider permission.

Missing means no dispatch exists. A prepared but unverified dispatch, even one
without a grant marker, is unresolved and cannot be replaced or resent by this
command. An exact frozen intent without a dispatch can be reused. A late clean
verification can resolve an originally unknown outcome; a response conflict or
verification conflict always excludes the object from availability.

An already verified archive can be indexed after recording stops. That path
consumes retained evidence and still requires current upload ownership. It does
not load recorder configuration, open the spool or contact the provider, and
index publication does not take the stop fence. Missing init or manifest is new
work: completion returns `recording_stopped` before configuration, local files,
manifest preparation or transfer. Init and manifest dispatch creation takes the
recording-control admission lock before the block lock, so a stopped control
cannot commit that dispatch. Media preparation stays outside that fence. A stop
does prevent new provider sends. Neither path resets recording control.

## Immutable proofs and the index

`ServiceRadar.Camera.RecordingManifest` owns the existing canonical version-one
wire format and golden bytes. Core constructs its inputs from the retained
descriptor and independent remote-byte verification. Request bodies cannot
provide an object URL, checksum, provider receipt or replacement descriptor.

The manifest intent retains the init and media dispatch UUIDs and their
verification digests. It does not copy their proof documents. The block index
retains the manifest dispatch UUID, verification digest and publication time.
These fields are all-or-none, restricted against deletion, and immutable after
publication. The existing block work state remains separate from archive
availability; there is no independently mutable `available` boolean.

Core checks the full proof chain at manifest preparation, manifest grant and
index publication. Every join must agree on the block, binding, frozen object
key, exact length and SHA-256. Original proofs can outlive the lease, boot and
authority that produced them; those identities remain evidence rather than
permission for another send. Database operations lock the block before its
init, media and manifest dependencies in a consistent order. Provider I/O never
runs inside those transactions.

Exact publication retries return the original receipt. A later conflicting
observation makes canonical status `reconciliation_required` even when a
historical publication receipt exists. The receipt remains an audit fact; it
does not override current availability. This checkpoint does not expose a
playback endpoint. All command and transport receipts continue to report
`recording_readiness` and `archive_readiness` as `unavailable`.

## Installed purposes and private routes

The [installation runbook](../../../docs/archive-init-storage.md#installed-files)
owns the version-one and version-two mounted configuration contract, shared
credential identity and independent purpose windows. One isolated workload
shares one global admission slot across its installed purposes.

Manifest authority has its own resource and retained grant/verification fields;
it shares the existing authority coordinator. The private storage listener adds
`manifest-authorities/challenge` and `manifest-uploads/{prepare,grant,observe,verify}`
under `/v1`. The existing control-plane media listener adds manifest authority
read/install/revoke routes under its authenticated scope. Pinned mutual TLS and
purpose-specific installed credentials still derive identity. No route is added
to the browser or a LiveView session.

The original generic `prepare/3` and `prepare_dispatch/5` continue to reject a
manifest role. Explicit `prepare_manifest/2` and `prepare_manifest_dispatch/3`
derive and freeze manifest dependencies before using the same dispatch owner.
The storage prepare response supplies only schema version, dispatch UUID,
length and SHA-256. The receiver independently compares those expectations
with the received bytes before requesting permission to send them.

Recorder ingress keeps init's existing JSON/base64 contract (1 MiB, 5 seconds)
and media's raw octet-stream contract (16 MiB, 30 seconds). Manifest ingress is
raw `POST /v1/manifest-uploads` with a 2 MiB, 30-second ceiling, exact
Content-Length and the existing bounded upload-lease header. Each role reserves
the same slot before reading a request body, including init. A slow partial
init request therefore cannot bypass admission while media or manifest work is
active. Oversize inputs are refused rather than split.

Media and manifest share one exclusive private `vms-media-staging` root under
the temporary directory, with one registered child directory per admitted raw
request. They create the root only when that path is absent. Every startup,
including preserved schema-v1 desired config and a version-two init-only map, refuses an existing path or an
unreadable inspection and does not delete it. Init-only does not create the
root when the path is absent. Restart cannot bypass abandoned raw staging by
installing a different purpose. Cancellation waits for actual ingress and
socket owners to exit before removing scratch files and reusing admission.
Failed scratch cleanup disables all purposes. Normal supervisor shutdown cleans
its owned root; a hard kill can leave it behind and requires operator
reconciliation, never automatic scanning, adoption or deletion.
One workload also means a process restart interrupts every purpose; independent
authorities do not imply independent failure domains. HTTP remains one request
per connection, with bounded ingress, task/socket ownership and no unread-body
keepalive drain.

## Validation ownership and remaining gates

The existing Core integration owner covers proof joins, old-epoch evidence,
prepared-operation refusal, current lease fencing, exact retries, concurrency
and late conflicts. The existing storage protocol owner covers synthetic
TLS/CONNECT, conditional writes, exact readback, per-purpose denial and expiry,
shared pre-body admission, restart and cleanup failures. Existing assertions
remain intact.

The joined Web database owner drives the real media command, completion command,
private service routes and persistence against a synthetic provider. The
provider observes committed grants through an independent database connection.
Recovery verifies objects through the real service, then stops recording and
removes recorder configuration and spool before database-only publication.
Tests clean and re-query every committed row they create, including the new
restricted proof references. No local product database substitutes for hosted
guarded execution.

Validation results belong in [validation.md](validation.md). Compilation does
not establish that a database case ran: the published head must pass its Core
and Web owners, connection observers, teardown and fixture-generation lease
release. Synthetic success does not qualify a live provider or provision Cloud
resources. Scheduling, multipart/unknown reconciliation, local reclamation,
playback, full recorder takeover and hosted lifecycle remain separate work in
[tasks.md](tasks.md) and [Cloud ownership](cloud-control-plane.md).
