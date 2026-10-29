# Ingest ownership and provenance audit

## Pre-change camera path

The audit baseline is staging commit `f58d52400d`. The operator has validated
live camera transport, not recording or archive durability. The table records
that baseline. This pass now serializes source/profile opens through
`Camera.IngestOwnership` and consults consumer leases before idle close.

| Boundary | Baseline owner | Recording consequence |
| --- | --- | --- |
| RTSP to encoded access units | `go/pkg/agent/camera_relay_rtsp.go` | One AnnexB H.264 access unit per chunk; PTS uses the RTP clock and DTS currently copies PTS |
| Authenticated agent uplink | `serviceradar_agent_gateway/camera_media_server.ex` and `media_identity.ex` | Preserve certificate-bound agent identity and session/ingest checks |
| Gateway to media host | `camera_media_forwarder.ex` and core-elx `camera_media_ingress.ex` | Open allocates an ingress process; subsequent media uses that process, not a new broker video payload |
| Shared encoded stream | core-elx `camera_relay/pipeline.ex` | Record before the WebRTC NALU split; recorder failure must not stop other consumers |
| Viewer lifetime | core-elx `camera_relay/viewer_registry.ex` | Existing final-viewer timeout does not consult recorder/analysis leases |
| Relay open/reuse | core `camera/relay_session_manager.ex` | Lookup followed by create does not serialize competing source/profile opens |

The existing uplink lease token is required to be nonempty by the gateway but is
not carried through the core activation check. It is not proof of recorder
ownership. At the audit baseline, the Go deduplication key was a relay
session ID, and two independently created relay sessions could open two
upstream pulls for the same profile. The agent manager's later source/profile
reservation is recorded in
[add-scalable-camera-recording-plane tasks](../add-scalable-camera-recording-plane/tasks.md)
and is not the fence in this document. New admissions now fail while more than one unexpired legacy
session is live. Already authenticated active sessions may keep heartbeating
until one remains, and that exception does not grant a recorder an ownership
handle.

The current camera wire format carries no declared timebase, UTC mapping,
uncertainty, or clock epoch. The H.264 RTP timebase is established by the current
producer implementation. Equal PTS/DTS is not evidence that an arbitrary camera
profile has no B-frames. Initial packaging admits baseline/constrained-baseline
only, retains unknown UTC explicitly, and requires a new packaging instance after
a clock or codec transition. Wider support needs an actual timestamp contract.

## Durable ownership contract

`Camera.IngestOwnership` serializes camera/profile acquisition, renewal, consumer
changes and idle-close reservation through one CNPG row. Takeover increments the
epoch and clears the previous relay binding. Viewer, recorder and analysis leases
expire independently and cannot outlive that owner. Renewing ownership does not
implicitly renew its consumers.

Idle close captures one relay ID while holding the owner lock and marks the owner
closing. Late consumers cannot attach to that closing epoch. Close targets only
the captured session, even if a later epoch starts. Publication uses the same
transaction fence, including a database-time recheck before commit. Media I/O is
outside that transaction: immutable epoch-qualified object identities and a
second fenced publication check prevent stale uploads from replacing new media.

Relay open, heartbeat, viewer renewal and idle close now use that fence.
Ambiguous pre-existing relays stay refused except one exact close: a persisted
active session with a nonempty authenticated `media_ingest_id` can be reserved
without adoption and without retiring a different owner. Requested, opening, and
active sessions with an empty ingress id keep the original ambiguity refusal. A non-force close
still retains active viewers and unexpired consumers. Raised or exited idle
closes stay retryable while the session is locally tracked and viewer-empty.
Guarded execution of these ownership races is recorded in [the handoff](README.md).
Registry entries and process discovery do not replace the database fence.
Expired consumer cleanup must be bounded and must preserve owner epoch history.

## What #4905 actually supplies

[PR #4905](https://github.com/carverauto/serviceradar/pull/4905) merged into
`usp-01-proposal`, not staging. Its merge commit
`e6602368cd9807e91a5c9afe4c2288727dc8b0de` is not an ancestor of the implementation
baseline. Its `proto/edge/v1/record.proto` and edge-record implementation are
absent from that baseline. Do not claim those APIs are deployed, depend on them
implicitly, or copy the unrelated proposal branch into this feature.

The reviewed record contract separates authenticated producer identity and
immutable semantic bytes from mutable delivery coordinates. Production,
collection and delivery authority are distinct, and a transport receipt alone
does not establish durable acceptance. Preserve those principles here: bind
source/profile and recorder generation to authenticated control state, preserve
clock evidence and media hashes, and distinguish local completion from verified
archive publication. Future edge archive integration can adopt the canonical
record API when that implementation reaches the target branch. This feature
does not create a competing edge-record ABI or route video bytes through the
telemetry pipeline.
