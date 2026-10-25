# Bounded init-object authority

This checkpoint installs one nonrenewable, short-lived authority window for an
isolated storage workload to upload and verify an initialization object. It is
not full media configuration, recording enablement, archive availability or
provider qualification. Historical qualification receipts remain diagnostic.
The [installation runbook](../../../docs/archive-init-storage.md) owns the Helm
and mounted-file contract.

## Desired identity

Version 1 uses an exact JSON object:

- `schema_version`: integer `1`.
- `revision`: canonical positive signed-bigint decimal string.
- `binding_id`: canonical lowercase UUID of the retained archive binding.
- `local_storage_id`: canonical lowercase UUID of the retained spool lifetime.
- `qualification_report`: the complete existing version 1 report.
- `operation`: `init_put_verified_v1`.
- `protection_mode`: `sse_s3_aes256`.
- `limits`: exact object containing integer `max_init_bytes` (1..1048576),
  integer `max_operation_ms` (1..5000), and integer `max_in_flight` (`1`).

All fields are required; unknown keys are rejected. The report owns the
destination, provider resource, endpoint class, policy, credential reference and
generation, storage-service identity, evidence reference and evidence expiry.
Do not repeat those fields in another independently editable identity. Match the
report destination to the retained binding and the local storage UUID to the
frozen block. All nineteen observations must be passed before applying authority;
the authenticated issuer remains accountable for their actual evidence.

The desired SHA-256 covers canonical JSON of the installed origin and the entire
desired document: `["init-authority-v1", deployment_ref, generation_string,
desired_document]`. Object keys are recursively ASCII-sorted, using the existing
qualification report's canonical JSON rules. The challenge is outside this
digest, avoiding a circular installation identity. The origin comes from trusted
installation authentication, never a request-selected deployment.

## Challenge and application

The storage service first loads its exact desired document and credential
reference/generation, then generates a boot UUID and a 256-bit nonce. Its
storage-purpose authenticated challenge request contains exactly
`schema_version`, `revision`, `binding_id`, `desired_sha256`, `storage_boot_id`
and `nonce`. The nonce is 64 lowercase hexadecimal characters. Authentication
binds deployment/generation, storage-service identity and credential reference/
generation. The Cloud administration token cannot call this service endpoint.

One retained authority row per binding consumes the revision high-water mark at
challenge issuance. The row pins origin, revision, desired digest, service
identity, boot and nonce, with a database-clock issue time and an expiry no more
than 30 seconds later. An exact retry returns the original challenge and time;
different content at the same revision is a conflict. A new boot, expired window
or replacement requires a greater revision. Issuing a greater revision immediately
invalidates previous applied authority. No same-revision renewal exists.

Cloud reads the private challenge and submits `{schema_version: 1,
desired: <document>, nonce: <challenge>}` under the separate installed media
administration credential. Application validates the complete identity, current
challenge, exact challenged deployment/generation, current report interval, every required observation and
the exact storage principal. It stores the full desired document and its digest.
The applied deadline is bounded by the original challenge expiry and report
expiry. Exact application retries preserve that deadline. This explicit fresh
attestation associates evidence with the challenged installation; an old receipt
or a set of passed strings alone never installs authority.

A higher-revision revoke retains the origin/revision high-water and permanently
denies new grants for that revision. Pending, applied and revoked are the only
stored states; expiry is computed. Storage also retains its challenge request's
monotonic start and the original bounded duration. Reading status, replaying a
receipt, restarting a process or moving wall time backwards cannot renew that
local deadline. A restarted storage service has a different boot UUID.

Status may acknowledge this narrow applied revision, but keeps recording and
archive readiness unavailable. It cannot attest fleet drain, policy truth,
credential retirement or hosted enablement. After expiry it retains the historical
`applied_revision` and returns `remaining_ms: 0`. Only a fresh committed dispatch
grant can authorize provider work.

## Private HTTP contract

The existing media-purpose administrator listener's init routes are:

| Method and path | Body |
| --- | --- |
| `GET /v1/media/init-authorities/:binding_id` | None; returns the current bounded status |
| `PUT /v1/media/init-authorities/:binding_id` | Exact application envelope above; body binding must equal path |
| `POST /v1/media/init-authorities/:binding_id/revoke` | `schema_version`, `binding_id`, decimal-string `revision` |

The separate HTTPS storage-control listener's init `POST` operations are below.
Its media routes are owned by [media-upload.md](media-upload.md). All
requests use integer `schema_version: 1`, reject unknown/duplicate keys and are
bounded to 16 KiB. Authentication supplies the installed principal, never the
JSON document. A lease contains exactly `id`, `upload_token`, decimal-string
`upload_epoch` and `descriptor_sha256`.

| Path | Remaining body fields |
| --- | --- |
| `/v1/init-authorities/challenge` | Exact challenge fields above |
| `/v1/init-uploads/prepare` | `lease`; returns `schema_version` and `dispatch_id` |
| `/v1/init-uploads/grant` | `lease`, `dispatch_id`, `storage_boot_id`, `desired_sha256`, fresh `nonce` |
| `/v1/init-uploads/observe` | `lease`, `dispatch_id`, `outcome`; `response` is also required for outcome `response`, omitted for `unknown` |
| `/v1/init-uploads/verify` | Grant request fields plus `verification` |

The fresh grant returns `schema_version`, `status: granted`, `dispatch_id`,
`binding_id`, decimal-string `revision`, `desired_sha256`, `storage_boot_id`,
the request `nonce`, bounded `remaining_ms`, logical `request_sha256`,
`object_key`, `byte_length`, `object_sha256`, `descriptor_sha256` and
`local_storage_id`. The storage service validates these against its loaded
configuration, input bytes and original request before sending anything.

Verification contains exactly `schema_version`, `put_request_sha256`, strong
quoted `etag`, nullable `version_id`, `byte_length`, `object_sha256` and
`encryption: AES256`. It records the actual signed-wire request identity separately
from the frozen logical intent. A successful verification response is only
`schema_version`, `status: recorded` and `dispatch_id`; it never serializes a raw
database resource. An HTTP observation acknowledges `schema_version` and
`status: recorded`. The existing bounded HTTP metadata contract remains unchanged.

Recorder ingress is separately authenticated `POST /v1/init-uploads` on the
isolated workload, with exactly `schema_version`, `lease` and `init_base64`.
Canonical base64 and its complete JSON envelope are bounded before any grant.

## One dispatch grant

The isolated service owns preparation, dispatch and late observations under the
fixed `camera_archive_storage` system actor. The installed principal supplies
the separately retained service/credential identity. Neither a recorder
nor an HTTP payload supplies that actor. Ingress carries the existing upload
handle and bounded init bytes; it cannot choose a destination URL or object key.
Read and hash the whole bounded init body before requesting a grant.

The grant owner locks recording control, authority, block and dispatch in that
order. It checks the current authority identity, local storage lifetime, boot,
report and credential generation, the exact frozen init intent, original upload
lease/deadline, and init-only PUT operation. The existing first marker commits
with immutable authority revision/digest, boot and per-request nonce identity.
Only the new postcommit grant result can authorize sending. Existing bookkeeping
markers, `already_marked`, reread rows, lost responses and lease replacement
never grant another send. Existing observation APIs retain late results.

Grant commit is the admission boundary shared with stop and revocation. Earlier
grants may finish within their original cap; later grants fail. This is not
remote cancellation. The returned remaining duration is clamped to the original
upload, dispatch, report and authority deadlines and at most five seconds.
Storage computes its deadline from ingress-start monotonic time and also clamps
it to its original installation window. One total deadline covers authorization,
body reads, PUT, HEAD and verification GET; no step refreshes it. Late observation
and verification callbacks have separate one-second transport caps and cannot
grant another provider operation.

## Isolated execution and exact verification

Use the existing core-elx release through a dedicated storage `eval` entry point
and its own supervisor. Start only the required HTTP/crypto dependencies. Force
distribution off and refuse startup if the node is distributed or the core/
recorder application is running. No core cookie, CNPG/NATS credentials or
Kubernetes API credentials are mounted. Provider keys exist only in this
workload. Use purpose-specific authenticated private HTTPS, with exact workload
authorization in addition to certificate-chain validation. Do not join ERTS or
introduce a media queue for this bounded request/response operation.

Promote the existing bounded provider transport to a shared owner and preserve
the diagnostic's assertions. Sign one PUT with `If-None-Match: *`, a checksum
and required AES256 encryption headers. Retain the exact logical and wire
identities separately. A 412 remains a conflict; this checkpoint never accepts
an incumbent object or sends a second PUT.

After success, require a strong quoted ETag and preserve a non-null version ID
when supplied. HEAD and GET target that exact identity. Require exact length,
AES256 evidence, an identity-bound complete byte range and the frozen SHA-256.
Reject redirects, weak/missing/duplicate/conflicting identity, 200 whole-body
fallback and deadline expiry. Store bounded verification evidence separately
from the dispatch's HTTP response. Init verification does not advance the block
to `archive_verified` or `available` and cannot authorize local reclamation.

## Acceptance

- Real authority persistence and private HTTP boundaries reject mismatched
  origins, stale/conflicting revisions, reused challenges, expired windows,
  different boots and unauthorized credential purposes.
- Grant/stop/revoke races serialize at the existing marker. Loss after marking
  never rearms the attempt; all prior lease and late-observation assertions stay.
- The actual isolated release entry point runs without core applications or
  distribution. Synthetic TLS/CONNECT provider traffic proves one conditional
  PUT and exact verification, with no provider request on denied authority.
- Wrong bytes, wrong identity, encryption mismatch, lost responses and elapsed
  deadlines withhold verification and retain the original media and evidence.
- Recording, multipart, recovery manifests, playback and live/provider readiness
  remain disabled or incomplete until their own acceptance passes.
