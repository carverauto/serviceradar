# Design: hardware-signed camera relay attestations

## Context

- `go/pkg/agent/camera_relay_rtsp.go` decodes the H.264 access units coming from the RTSP reader
  and marshals each one as Annex B into `MediaChunk` payloads. Wasm streaming plugins write media
  through the `camera_media_open`, `camera_media_write`, `camera_media_heartbeat` and
  `camera_media_close` host functions.
- Both paths use one shared relay uploader. That is the `camera-streaming` requirement "Native and
  Wasm camera sources share one relay uploader".
- `github.com/google/go-tpm` is already in `go.mod` as an indirect dependency.

## Goals / Non-Goals

- **Goals:**
  - a capture-side commitment over relayed media, signed with a key the cluster operator can't use;
  - cheap enough to cover hundreds of cameras per agent;
  - never interferes with relaying;
  - verifiable by third parties from published vectors.
- **Non-Goals:**
  - verifying attestations inside ServiceRadar core;
  - proving the camera-to-agent hop;
  - deciding what a consumer does with the attestations.

## Decisions

### D1. Native agent capability, not a Wasm plugin
The capability is built into the agent host. Three reasons rule out a Wasm plugin:
1. **Coverage.** Only the shared uploader sees every relayed access unit, from both native readers
   and Wasm sources. A plugin sees only the media it produces itself.
2. **Key protection.** The TPM (`/dev/tpmrm0`) and PC/SC devices aren't reachable from the Wasm
   sandbox. A generic signing host function would turn any installed plugin into a signing
   oracle for the facility key. Here the host signs only attestations it constructs from its own
   hashes.
3. **Cost.** Copying every frame into Wasm memory to hash it would double the relay's memory
   traffic. Native SHA-256 over slices of the payload costs little.

Wasm streaming plugins need no changes, because their media is attested automatically by the
uploader.

### D2. Normalization and hashing
For each access unit that reaches the uploader:
1. Split the Annex B or length-prefixed payload into NAL units.
2. Keep only video-coding-layer (VCL) NAL units: H.264 types 1-5, and H.265 types 0-31. Parameter
   sets, SEI, AUD and filler data are excluded, because recorders may insert or rewrite them.
3. Hash each kept NAL unit's bytes exactly as received, including emulation-prevention bytes,
   but excluding start codes and length prefixes. Join them in order:
   `au_hash = SHA-256("sr-au-v1" || codec || pts_90k || n || len_1 || nal_1 || ... )`.
4. Chain per stream: `chain_i = SHA-256(chain_{i-1} || au_hash_i)`. The chain is seeded with the
   relay session ID and stream profile.

Golden vectors (inputs, NAL splits, `au_hash` and chain values) cover H.264 and H.265, Annex B and
AVCC, and B-frame ordering. They are published as fixtures for external verifiers. If a consumer
finds that a codec profile doesn't survive its recorder's remuxing unchanged, it can fall back to
the relay byte stream. That decision belongs to the consumer.

### D3. Interval attestation
Every 10 seconds (configurable, 5-60 s), the agent builds a `serviceradar.relay_attestation.v1`
record:
- `signer_key_id`, `agent_id`, `seq` (per signer and monotonic), `prev_attestation_sha256`;
- the interval's wall-clock start and end, and the clock source;
- for each active stream: `camera_source_id`, `stream_profile_id`, `relay_session_id`,
  `first_pts`, `last_pts`, `au_count` and `chain_head`;
- `merkle_root`, the RFC 6962 root over the interval's `au_hash` values, sorted by stream, then
  PTS.

The agent signs the record's JCS (RFC 8785) encoding as a DSSE envelope. That is one hardware
signature per agent per interval, well within TPM throughput at any camera count. Records are
capped at 64 KiB. Above that size, per-stream entries are split across numbered parts that share
one signature over a parts digest.

### D4. Signer backends and enrollment evidence
- **TPM 2.0 (default).**
  - The signing key is a P-256 key created under the owner hierarchy's storage root key, with
    `fixedTPM | fixedParent | sensitiveDataOrigin | sign`, so it is non-exportable.
  - The key's wrapped blob is kept in the agent state directory.
  - Signer announcement evidence: the EK certificate chain, the public part of an attestation
    key, and `TPM2_Certify` of the signing key by that attestation key. A verifier can then run
    credential activation, or check certify output against the EK chain.
- **YubiKey PIV or YubiHSM 2 (fallback).**
  - A P-256 key is generated on-device in a dedicated PIV slot, or object ID for YubiHSM.
  - The PIN is held in the agent's secret store.
  - The PIV attestation certificate chain goes into the announcement.
- **No software fallback.** Without a supported device, the status is `unavailable`, and no
  attestations are produced.
- **Rotation.** Signer rotation creates a new key and announcement, and the next attestation
  refers to the new key ID.

### D5. Transport
- **Uplink.** Attestations and announcements are new message types on the existing agent-to-
  gateway uplink, and are relayed to core unmodified.
- **Publication.** Core publishes them on `camera.recording.relay_attestations.v1` and
  `camera.recording.relay_signers.v1`, with `Nats-Msg-Id = <signer_key_id>:<seq>`.
- **Buffering.** The agent buffers unsent attestations on disk (bounded, default 24 h) while the
  uplink is down.
- **Core can't forge them.** Core can drop attestations but can't forge them. Gaps are visible to
  consumers through `seq` and `prev_attestation_sha256`.

### D6. Never block the relay
- **Hashing** runs inline in the uploader. SHA-256 over VCL payloads costs well under 1% of a core
  per Gbit/s.
- **Signing** runs on a separate goroutine. If the signer stalls or fails, intervals keep being
  built and are queued. The queue is bounded, and when it overflows, the oldest unsigned
  intervals are marked `unsigned` and still published, so the gap is visible.
- **Relay errors** are never caused by attestation failures.

### D7. Status
The agent reports `relay_attestation` status (`disabled`, `active`, `degraded` or `unavailable`)
with a reason, in its health and as `health.state_change`. It also records the last signed `seq`.

## Risks / Trade-offs

- **Normalization mismatch with downstream remuxing.** Golden vectors pin the agent behavior, and
  consumers must validate against their own recorders. A spike covers ServiceRadar's own CMAF
  path.
- **TPM availability and permissions vary.** There is a preflight check, packaging grants the
  `tss` group, and failures are reported clearly.
- **A root user on the agent host can feed doctored media to the relay.** That is out of scope,
  and camera-native signing addresses it.

## Migration Plan

The capability is opt-in per agent configuration (`camera_relay_attestation.enabled`), off by
default. Enabling it requires no core change beyond publishing the two subjects.

## Open Questions

- The default interval: 10 s, or shorter for lower-latency consumers?
- Windows hosts: should a TBS-based TPM backend be part of the first slice?
