# Private NVR recording input

The first operator-test milestone is one existing inventory camera recorded by
`serviceradar-nvr`, retained on Longhorn-backed storage, listed and playable in
the UI, followed by restart and approved worker-loss verification. Two replicas
retain separate storage identities; the storage provider owns replication.
S3 remains optional.

| Milestone boundary | Current evidence | Remaining integration |
| --- | --- | --- |
| Camera to NVR | Bounded relay-to-NVR coordinator streams one shared relay session into a configured NVR replica over mTLS | Continuous recorder pool scheduling and automatic assignment |
| Footage catalog | Durable publication intents and Core acceptance | Current-history completion and qualified local-copy registration |
| Playback | Archive player and authorized S3 reads | Owner-routed authorized local reads and player discovery |
| Worker replacement | Synthetic release restart preserves decoded frames | Deployed Longhorn attachment and approved node-loss verification |

The listener below closes the network input boundary. It remains disabled by
default and does not implement the coordinator or change deployment readiness.

## Installation

Set both `SERVICERADAR_NVR_INGEST_CONFIG_FILE` and
`SERVICERADAR_NVR_INGEST_TOKEN_FILE` to installed workload credential files.
Omitting both leaves the listener absent; partial or invalid configuration
refuses application startup. The token is 32 through 512 printable ASCII bytes,
without a trailing newline. Use a separate token for this purpose.

The configuration is one JSON object with exactly these fields:

| Field | Meaning |
| --- | --- |
| `port` | Private HTTPS port, integer 1 through 65535 |
| `cert_file` | Absolute path to the NVR server certificate |
| `key_file` | Absolute path to its private key |
| `ca_file` | Absolute path to the trusted client CA bundle |
| `client_sha256` | Lowercase hexadecimal SHA-256 of the permitted coordinator's DER leaf certificate |

Configuration is loaded at boot. Rotate by replacing and retiring the listener;
changing a mounted file alone does not revoke an existing process. Workload
credentials belong to infrastructure custody. Camera credentials stay in the
unified CNPG credential inventory and never enter this request.

TLS requires a trusted client certificate; the leaf pin and exactly one
`Authorization: Bearer <token>` header are checked before reading the body.
The client must verify the NVR hostname and certificate against its installed CA.
The listener supports one request per HTTP/1 connection, disables HTTP/2 and uses
two acceptors with eight connections per acceptor. Recording capacity remains
bounded separately by the existing session and disk admission limits.

The listener is private to the trusted recording coordinator or a local media
bridge. It is not a browser endpoint or a new inbound requirement from Cloud
into a customer network. When `nvr.ingest.enabled` is set in Helm, only the
headless NVR Service and a `serviceradar-core` pod-selected NetworkPolicy rule
expose the listener inside the cluster; no public route is created.

## Bounded relay coordinator

`ServiceRadarCoreElx.CameraRecording.NVRCapture` (`once_source/4` and
`once_relay/3`) runs one finite capture from the shared camera relay into a
configured NVR replica without opening a second direct camera RTSP stream or
sending media over NATS/JetStream or ERTS distribution:

1. `once_source/4` reuses an active shared relay or opens one via
   `RelaySessionManager.request_open/3`, then routes execution to the `core-elx`
   node hosting `CameraRelay.Pipeline` (`ServiceRadar.Camera.RelayHosts`).
   It refuses with `:recording_disabled` before opening anything when the
   recording supervisor is off. If capture fails before streaming starts, it
   closes the relay only when this call opened it; a reused relay, including
   one a live viewer is still opening, is left untouched.
2. `NVRTargetConfig` resolves installed workload mTLS/token credentials and the
   target replica's provisioned `storage_id` from
   `SERVICERADAR_NVR_CLIENT_CONFIG_FILE` and
   `SERVICERADAR_NVR_CLIENT_TOKEN_FILE`.
3. `NVRWorker` verifies `IngestOwnership`, acquires `RecorderOwnership` bound to
   that `storage_id`, reserves `block_sequence: 0`, attaches a bounded
   `ServiceRadarRecording.Inbox` to the relay pipeline outside live-view and
   control processes, and streams contiguous 90000 Hz H264 AnnexB access units
   through `ServiceRadarNVRClient.send_recording/4`.
4. A verified `sealed_local` receipt returns the correlated `recording_block_id`
   and `block_key` while keeping the `RecordingBlock` in `:open_local` (never
   published or playable by local seal alone). Any `:outcome_unknown`, timeout,
   failed relay drain or caller loss aborts without sending the stream-end
   marker, never retries or fails over to another replica, and leaves the
   reserved block and epoch intact for inspection or recovery. The recorder
   lease keeps renewing until the NVR answers. A capture `timeout_ms` outside
   1 through 300000 is refused before any recorder claim is taken. A verified
   receipt is returned even if worker cleanup outlasts the drain window.

## Finite stream contract

Send `POST /v1/recordings/ingest` with exactly one
`Content-Type: application/vnd.serviceradar.nvr-ingest.v1` header. HTTP
Content-Length and chunked transfer are supported. HTTP chunk boundaries do not
need to align with application records. All integers below are unsigned network
byte order (big endian).

1. A four-byte header length, from 1 through 1024, followed by canonical JSON:
   sorted object keys, compact encoding, no duplicate or unknown keys. The
   header has `version: 1`, `storage_id`, `recovery_generation`, `clock_epoch`
   and `identity`. The identity has `source_id`, `profile`, `recorder_epoch`
   and `block_sequence`, using the existing recording identity limits.
2. Each access unit has a four-byte payload length from 1 through 1048576,
   then eight-byte `sequence`, `pts` and `dts` values, then that many payload
   bytes. Payloads are complete H264 AnnexB access units. The existing writer
   validates baseline/constrained-baseline H264, keyframe acquisition, timestamp
   and sequence continuity. Timestamps use a 90000 Hz timebase with no frame
   reordering. UTC mapping is explicitly unknown; receipt time is not capture time.
3. A zero four-byte payload length terminates the application stream. It must
   be followed immediately by HTTP body completion. Truncation, extra bytes or
   an HTTP EOF without this marker do not request a seal.

The header's storage UUID and recovery generation must match this NVR's installed
configuration. The coordinator supplies the original source/profile, recorder
epoch, block sequence and clock epoch from its authorized capture operation.
These fields are correlation, not proof of ownership: the installed coordinator
must establish exclusive source/writer assignment and valid authority covering
the finite operation before sending it. This transport does not enroll a pool,
issue leases, resolve an uncertain earlier writer or authorize takeover.

One request admits at most 64 MiB of application body and reports at most 256
sealed blocks. Reads have a one-second timeout. The existing configured session
duration also bounds the entire request handler, including body reads and
sealing; its default is 30 seconds and its ceiling is five minutes. The timer
survives a stalled or disconnected caller. There is no renewal or implicit retry.
The producer waits for each frame to pass through the writer before admitting
the next; this wait must stay outside shared live-view and control processes.

## Sending client

`ServiceRadarNVRClient.send_recording/4` in `elixir/serviceradar_nvr_client`
implements this finite stream contract without a Core, database, Membrane or NVR
application dependency. Its caller supplies an installed endpoint, workload
credentials, an authorized recording identity and a lazy access-unit enumerable.
The client pulls and sends one frame at a time, enforces unit/body/response
limits, verifies the server identity, and bounds the producer and socket lifetime
even after caller loss. Only normal enumeration completion sends the end marker.
It never retries, follows redirects or selects another replica.

A success receipt must match the requested storage lifetime and consecutive
block keys. Transport or malformed-response failures return an unknown outcome
requiring discovery at the original NVR. See the [client API and configuration](../elixir/serviceradar_nvr_client/README.md).
This is a library for the media bridge; installing it enables no consumer. The
[bounded relay coordinator](#bounded-relay-coordinator) is its only caller and
performs source ownership and recorder admission before sending.

## Outcomes and preservation

HTTP 200 returns `version: 1`, `status: sealed_local`, the `storage_id` and
ordered `block_ids`. IDs are opaque 64-character lowercase hexadecimal values,
not paths. This response confirms local seals only. It is not qualification,
Core publication, a playable catalog entry or permission to delete footage.
Existing block discovery is needed after an unknown response outcome.

Authentication failures return 401, malformed headers return 400, unavailable
admission returns 503 and incomplete media returns 422. A deadline, broken
transport or process failure can close the connection without a JSON response.
Any lost response is an unknown outcome. Do not automatically resend media,
change the recorder epoch or move to another replica to hide that uncertainty.

Incomplete work retains its journal and completed blocks. The request never
repairs, deletes or adopts retained storage. It cannot bypass current recovery
state, the bootstrap/history barrier, source/profile exclusion, capacity checks
or write-time disk guards. Closing recovery during work withholds success even
if some bytes have already been written. Inspection and explicit recovery remain
separate operations under their existing authority requirements.

## Verification

`//elixir/serviceradar_nvr:release_test` owns the real HTTP/TLS and release-lifecycle
contract. Its network input cases use independently generated H264, verify
rotated footage by decoding and comparing frames after restart, preserve files
on replay, and exercise authentication, storage/generation binding, incomplete
input, bootstrap refusal and finite producer lifetime. These tests establish
neither deployed-camera behavior nor physical Longhorn node-loss durability.
The same target runs the packaged client against the packaged NVR and an
independent TLS peer to check wire bytes, receipt binding, server identity,
byte limits, no retries and bounded cleanup after producer or caller failure.
