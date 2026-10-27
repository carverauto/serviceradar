# Explicit sealed-media upload

This pass uploads one already frozen media block through the isolated storage
workload and retains exact remote-byte verification. It does not schedule
recording or uploads, publish an archive index, reclaim spool files, or enable
hosted recording. The separate [archive-publication command](archive-publication.md)
owns recovery-manifest verification and fenced index publication.

## Entry point and local ownership

`CameraRecording.MediaUpload.upload_once(block_id)` is an explicit core-elx
administration operation. Installed configuration supplies the verified spool
root, immutable archive binding and private storage-service credentials. The
caller supplies only a block UUID. The retained block supplies the storage
lifetime, relative block key, frozen descriptor, length and digest. The operation
uses the existing upload lease and binding fence. It never invokes destructive
spool recovery or accepts a caller-selected file, provider URL or object key.

The recorder and isolated storage service remain separate processes. Only the
isolated workload holds provider credentials; it has no CNPG credentials,
distributed Erlang membership, recorder filesystem mount or Kubernetes token.

The recorder loads `VMS_MEDIA_UPLOAD_CONFIG`, an absolute path to an installed
JSON document with exactly `schema_version: 1`, `spool_root`, `binding_id`, and
`storage`. The `storage` object contains the private `base_url`, `certfile`,
`keyfile`, `cacertfile`, and `token_file`. The configured recorder storage UUID
must match the retained block. This file contains no provider credentials.
Operators invoke `ServiceRadarCoreElx.CameraRecording.MediaUpload.upload_once/1`
on a running core-elx instance; this pass installs no automatic caller.

The separate storage instance uses the existing infrastructure configuration
file entry point with a `media_put_verified_v1` desired document. Its boot
challenge must be applied through the private media-authority route before
the explicit upload. An init-kind instance continues to accept only init
authority. No production init-upload caller exists yet; the next publication
pass must obtain or consume independently retained init verification.

## Distinct media authority

`media_put_verified_v1` uses its own persisted media authority and grant evidence.
The coordinator and configuration validation share the existing init machinery,
while init rows, digest domains, wire contracts and limits remain unchanged.
Old init readers cannot see media authority. Init grants never authorize media.

The media desired document uses the init document's required fields, with
`operation` `media_put_verified_v1` and `limits` containing `max_media_bytes`
(1 through 16777216), `max_operation_ms` (1 through 30000) and `max_in_flight`
of 1. Its canonical digest domain is `media-authority-v1`. Init keeps
`max_init_bytes`, a 5000 ms cap and `init-authority-v1`.

The installed desired document binds origin, binding, local storage lifetime,
complete qualification report, credential generation and storage boot identity.
All nineteen qualification observations must pass. The original nonrenewable
30-second challenge window, report expiry, upload lease and dispatch deadline
bound the operation. A greater revision does not rearm a marked dispatch.

Grant admission locks recording control, authority, block and dispatch in that
order. Only the first committed marker with current media authority grants one
conditional PUT. A bookkeeping marker, retained receipt, changed lease or lost
grant response grants no subsequent provider request.

The administrator and storage-control listeners use the same methods, schema
version, 16 KiB bound, lease fields, and grant, observe, and verify bodies as
the [init contract](init-authority.md), with `media-authorities` and
`media-uploads` in place of `init-authorities` and `init-uploads`. Media
`prepare` also returns `byte_length` and `object_sha256`. A malformed media
application or revoke body, including a binding that does not match the path,
is `invalid_media_authority`. Recorder ingress remains the raw
`POST /v1/media-uploads` below.

## Bounded byte transport

Recorder ingress is authenticated private HTTPS `POST /v1/media-uploads`, with
`application/octet-stream`, one canonical Content-Length, and one bounded
`X-ServiceRadar-Upload-Lease` JSON header containing the existing four-field
lease. Duplicate fields and headers fail before media is read. Media is never
base64 encoded or accumulated into a whole-object binary.
The listener serves one request per HTTP/1 connection and disables HTTP/2.
Rejected requests close without Bandit's keepalive unread-body drain.

The isolated service reserves its single admission slot before reading the body.
It stages at most 16 MiB in private scratch storage, using 64 KiB chunks and an
incremental SHA-256. Preparation supplies the immutable expected length/digest;
staged bytes must match before a fresh grant is requested. Oversize blocks are
refused, not split or silently truncated. The existing 32 MiB temporary volume
does not support the spool's 64 MiB default or its 512 MiB format ceiling.

One ingress-start monotonic deadline covers staging, preparation, grant, PUT,
HEAD and readback, with a ceiling of 30 seconds and all original authority and
lease caps. No phase renews the budget. Evidence callbacks have their own short
transport cap and cannot grant further provider work.

The PUT is streamed through the existing Mint CONNECT/proxy/TLS transport. There
is no direct fallback when the configured egress proxy fails. The existing Req
SigV4 utility signs the precomputed payload SHA, exact Content-Length,
If-None-Match, checksum and AES256 headers; enumerable-body UNSIGNED-PAYLOAD is
not used. The logical intent and exact signed-wire identity remain separate.

After PUT success, HEAD and sequential ranges target the same strong ETag and
non-null version when supplied. `EgressClient.fetch_range/3` owns external range
reads, each at most 4 MiB. Exact framing, length, identity and cumulative SHA
must match the frozen intent; redirects, whole-object fallbacks and encryption
mismatches fail. A 412 or unknown outcome never permits another PUT.

Media and manifest share staging, admission and cleanup ownership. The
[shared storage contract](archive-publication.md#installed-purposes-and-private-routes)
owns startup refusal, ingress/socket cleanup and restart behavior.

Original spool media and durable unknown/late-response evidence are preserved.
If cancellation prevents the outcome callback, the committed dispatch marker
still prevents another PUT; it is not evidence that the provider accepted or
rejected bytes. Two evidence callbacks have at most 2.1 seconds of cleanup
grace after the original deadline, with no additional provider work.
The bounded success receipt reports media verification with recording and
archive readiness unavailable.

The one-shot caller always releases its upload lease. A prepared dispatch keeps
its original lease and deadline, so a later call with a replacement lease cannot
rearm that attempt, even if it was never marked. This conservative limit requires
an explicit future recovery rule; it is not an automatic upload retry policy.

## Required proof

The existing init assertions remain. Guarded database tests cover current
authority, separate operation purposes, races, rollback and immutable late
evidence. Real private HTTPS and synthetic TLS/CONNECT traffic cover streaming,
signing, exact ranges, denial, deadlines, resource limits and scratch cleanup.
A joined test must drive actual database-backed coordination and the isolated
storage process from the one-shot production caller. Fake grants alone are not
that proof. Required remote tests and exact-head guarded database execution
remain publication gates.
