## Context

The reviewed Longshore baseline began at commit
`1b85610adb6702772acfd8b9af607acea6b0404c` and is now pinned to
`8759583fd1888f292f290a5adbe883c8c6eb6aee` (upstream PR #28), which adds the
verified single-object `Client::{put,head,get}` contract, `Budget::once`,
conditional `Expect`, response `Answer`/`Report` metadata, and non-secret
`Signed.canonical_request_sha256` request evidence. Depend on its public crates
by immutable git revision; do not publish them, vendor a fork of their
implementation or replace AWS-LC.

The current provider boundary is
`ServiceRadarCoreElx.CameraStorage.Upload` and `CameraStorage.Read`.
`ArchiveStorageHTTP` also transports private workload requests; replacing that
entire module with an S3 client would cross unrelated protocol boundaries.
Provider credentials for `s3_compatible` archive storage bind through the
canonical CNPG credential model (`ServiceRadar.Credentials.NativeDescriptors`
and `ServiceRadar.Camera.ArchiveCredentialResolver` reading encrypted secrets
through `SecretBroker` from `platform.network_credential_secrets`, never
Kubernetes, Helm or environment secrets). Live camera viewing remains WebRTC
and recorded browser playback remains HLS/fMP4.

## Decisions

### Rustler owns the bridge, not recording authority

Use a reusable library without Core, database or recorder-runtime dependencies.
Elixir owns supervision, configuration and request correlation. Rust owns the
bounded Longshore client, buffers and completion delivery. Provider credentials
remain inside the existing isolated storage workload; camera senders and browser
clients do not acquire them. Preserve the canonical credential/binding model.

A NIF call validates bounded arguments and admits work or returns busy. It must
not wait for buffers, sockets or thread joins on a normal scheduler. Bound both
queued operations and retained bytes, including requests whose callers exited.
Avoid an unbounded task/thread per request. Prefer sealed-file/limited-chunk
input over moving a whole recording through repeated BEAM binary copies; measure
actual copying before claiming zero-copy.

Return correlated completions through the supervised
`ServiceRadarObjectStorage.Session` owner so caller timeouts never strand late
multi-MiB `{:longshore_reply, ref, ...}` messages in caller mailboxes. Caller
timeout is not proof of provider cancellation. Keep admission charged until
physical completion or qualified termination. Decode all configuration and
per-operation option maps strictly (`{:error, :bad_config}` on missing, unknown
or wrongly-typed keys; never default `no_clobber` to `false` on malformed
input). Pool bounded `ScratchBuf` write buffers (`concurrency` slots capped at
`buffer_size`) so `PUT` avoids repeated multi-MiB OS `mmap`/page-fault/`munmap`
churn, and allocate `OwnedBinary` directly once from Longshore's registered
`Buffer` on HTTP `200`/`206` reads before zero-copy `release(env)` to BEAM.
Client destruction and last-reference thread joins belong to the worker
lifecycle, not a resource destructor on a scheduler (`Handle` holds zero
Longshore client references). Contain Rust panics at the FFI boundary and
verify release panic settings.

### Preserve archive semantics before activation

Upstream PR #28 (`8759583fd1888f292f290a5adbe883c8c6eb6aee`) closed the
single-object contract gaps identified against `1b85610adb67`:

| Existing requirement | Observed public client gap (`1b85610`) | Upstream / adapter disposition (`8759583`) |
| --- | --- | --- |
| One fresh grant permits one provider dispatch within its deadline | Internal retries; dropping Pending does not stop the operation | Closed for single-object ops via `Budget::once(deadline)` and `Report` `NotSent` vs `Unknown` outcomes |
| PUT receipt and subsequent reads bind ETag and optional version | Store returns success only; fetch returns length; no public stat method | Closed via `Client::{put,head,get}` returning `Answer` (`status`, `etag`, `version_id`, `request_id`, `content_length`, `content_range`) |
| Exact range and If-Match/version checks | High-level fetch_range takes offsets without these preconditions | Closed via `Expect { version_id, if_match, range }` with explicit `bytes.len() <= buffer.len()` validation |
| Requested AES256 encryption and SHA-256 evidence | High-level store does not expose the required request headers/evidence | Closed via `Put { no_clobber, sse_s3_aes256, sha256 }` and `Answer.server_side_encryption`; `Answer.sha256` stays optional because S3-compatible providers may omit checksum echo while enforcing `AES256`, so independent `HEAD` + 4 MiB ranged `GET` SHA-256 readback remains mandatory |
| Existing signed-wire digest correlates the authorized request | Signing happens inside Longshore with no equivalent public evidence | Closed via `Signed.canonical_request_sha256` recorded under new `*-put-canonical-v1` tags (`init-put-canonical-v1`, `media-put-canonical-v1`, `manifest-put-canonical-v1`) without altering `*-put-wire-v1` |
| Refused reads must not leak error XML as media | Longshore writes non-2xx XML error responses into the caller buffer | Enforced at the Rustler/adapter boundary: payload bytes are extracted only when `answer.status` is `200` or `206` |
| Conditional multipart completion and ambiguous outcomes | Client multipart exists, but the archive contract is not qualified | Kept out of initial adapter activation until no-clobber completion, durable upload identity and real-provider reconciliation are qualified |

Document these for the Longshore owner. Library changes belong in its own
repository and review workflow. Update this pin only after those changes merge.
Do not implement a second low-level S3 event loop in ServiceRadar to bypass gaps.

Select one object-checksum algorithm per upload. Preserve Longshore's existing
CRC64 default, but caller-provided SHA-256 replaces CRC64 for archive writes;
never send both algorithm-specific checksum headers. ServiceRadar supplies its
already-computed object digest, so Longshore does not add another payload SHA-256
pass. The SigV4 payload marker is a separate signing concern. Missing response
checksum evidence remains missing: a compatible provider may accept a checksum
header without validating it. Exact identity-bound readback and independent
SHA-256 comparison remain mandatory before an archive receipt is recorded.

If the upstream request evidence uses a canonical-request hash instead of the
existing signed-header-pair representation, assign it a new evidence format tag.
Do not change the meaning of the existing `*-put-wire-v1` tag in place.

The initial NIF round-trip/benchmark target can exercise existing public APIs
with synthetic objects in a dedicated test scope. It cannot publish an archive
receipt, make footage reclaimable, or claim production compatibility. Production
activation waits for the relevant gaps above to close; successful PUT alone is
insufficient.

### Deployment and memory qualification

Validate Linux kernel support (at least 6.1), permitted io_uring syscalls,
memlock/buffer allocation, architecture and container policy on the actual target.
Do not assume node kernel compatibility proves pod compatibility or disable
seccomp broadly. Return an actionable unsupported state when initialization fails.

The deployment prerequisite is an opt-in media-storage Localhost profile derived
from the runtime default with the three io_uring syscalls allowed, installed on
every eligible node. The chart configuration and installation runbook ship
separately from this integration. Profile selection alone does not qualify the
client: ring creation and buffer registration have independent failure modes.
Longshore retains registered buffers and zero-copy sends. The proposed upstream
`pin_buffers` option was withdrawn; the integration must reject it rather than
pretend to offer a fallback. The target deployment needs adequate soft and hard
memlock limits supplied by node/runtime configuration. Those infrastructure
changes require separate operator authorization and do not come from the seccomp
setting. Verify the inherited limit in newly created pods on every eligible node,
and include both the profile and the limit in node provisioning. Do not silently
accept options absent from the pinned API or raise container privileges to bypass
memlock. Node preparation does not by itself prove the NIF works.

Set connections, buffers, operations, buffer size and I/O threads explicitly.
Account for TLS buffers and outstanding BEAM binaries in the pod budget.
Start with bounded low concurrency; choose higher values from measurement.
Preserve public-root TLS verification. Private-CA/proxy requirements unsupported
by the high-level client must be reported, not silently ignored or downgraded.

Single-object writes are limited to buffer capacity. Multipart uses bounded
parts and explicit incomplete-upload cleanup/reconciliation. Initial tests cover
both paths; do not raise buffer sizes without accounting for total resident
memory. Multipart against the selected real provider is a separate correctness
gate because the handoff only qualifies high-level multipart against the test
server.

### Qualification order

1. Remote Linux build and actual container initialization.
2. Synthetic native and Rustler correctness, pressure, caller-exit and shutdown.
3. Upstream contract closure and isolated archive adapter qualification.
4. Bounded selected-camera recording, exact object readback, decode, catalog and
   authorized playback, followed by service restart.
5. Matched performance runs and a soak; fix measured bottlenecks and repeat.

[Benchmark protocol](benchmarks.md) defines evidence and explicit failure gates.
The real-camera check proves usability; synthetic sources establish capacity.
Do not convert the bounded Core compatibility recorder into the production
continuous recorder to shortcut missing source assignment.

## Rollout and recovery

Keep activation opt-in until correctness and resource limits pass. Preserve
spools on failures and unknown outcomes. Rollback stops new Longshore admissions,
drains or explicitly resolves outstanding operations, and preserves journals and
objects. Do not replay a one-shot dispatch through the old transport as fallback.

## Open evidence

- Upstream single-object contract closed at `8759583fd1888f292f290a5adbe883c8c6eb6aee`; multipart archive qualification against a live S3-compatible provider remains open.
- Real pod io_uring/memlock support across all eligible cluster nodes (node prerequisites: `docs/media-storage-node-prerequisites.md`) and live-cluster image rollout.
- Live selected-camera bounded recording dogfood, restart persistence and 30-minute real-provider TLS soak after cluster rollout prerequisites land.
- Synthetic same-host RBE native/NIF and `CameraStorage` pipeline baselines are recorded in [benchmarks.md](benchmarks.md); live S3-compatible HTTPS WAN ceiling and multi-camera capacity remain open.
