# Change: Hardware-signed camera relay attestations from the edge agent

## Why

ServiceRadar records camera video in the cluster: the edge agent relays each stream, and core-elx
and the NVR seal it into blocks. Nothing proves that what was recorded matches what left the
facility. Whoever operates the cluster, whether the customer or a hosting provider, is trusted for
the bytes between relay and seal.

Evidence, compliance and VMS integrations need a capture-side commitment that the cluster operator
can't forge. The agent already runs at the facility and handles every relayed frame, so it can
hash what it relays and sign those hashes with a key held in the host's hardware. Neither the
cluster nor the hosting provider ever holds that key.

## What Changes

- **Relay attestation (new capability `camera-relay-attestation`, opt-in per agent).**
  - The shared camera relay uploader, which serves both native RTSP readers and Wasm streaming
    plugins, hashes the video-coding NAL unit payloads of every relayed access unit. It uses a
    fixed normalization: no start codes or length prefixes, and parameter sets and SEI excluded.
  - It chains the hashes per stream.
  - Every 10 seconds it signs one attestation for the agent: a Merkle root over that interval's
    access-unit hashes, plus per-stream PTS range, count and chain head.
- **Hardware signer.**
  - The default is a non-exportable ECDSA P-256 key in the host's TPM 2.0 (physical, firmware or
    virtual).
  - A YubiKey (PIV) or YubiHSM 2 is the fallback.
  - There is no software-key fallback. Without hardware, the attestation status is
    `unavailable` and relaying continues unchanged.
  - Plugins can't request signatures. There is no host function for it, and the agent signs only
    the attestation structures it builds itself.
- **Signer announcement.** The agent announces its signer: public key, key ID, device type, and
  for TPMs the endorsement-key certificate chain and key certification evidence. External
  verifiers can then confirm the key is hardware-resident.
- **Transport.** Attestations and signer announcements travel over the existing agent uplink.
  Core publishes them unmodified on `camera.recording.relay_attestations.v1` and
  `camera.recording.relay_signers.v1`, in the existing `CAMERA_RECORDING_EVENTS` stream
  (`add-recording-and-audit-event-streams`).
- **Status and fixtures.** Signer health is reported in agent health and as
  `health.state_change` events. Published golden test vectors let any verifier, in any language,
  reproduce the normalization and hashing.
- **Never blocks the relay.** Hashing is inline and cheap, and signing is asynchronous. Signer
  failure never drops, delays or alters media.

## Impact

- **Affected specs:**
  - new `camera-relay-attestation`;
  - it relies on the `camera-streaming` requirement "Native and Wasm camera sources share one
    relay uploader".
- **Affected code:**
  - `go/pkg/agent`: the relay uploader hook, normalization and hashing, attestation builder, and
    signer backends (`go-tpm`, PIV through PC/SC), plus config and health;
  - the agent-gateway and core uplink message types and the publisher;
  - Helm and agent packaging, for `/dev/tpmrm0` access (the `tss` group) and optional PC/SC;
  - golden fixtures under `go/pkg/agent/testdata/relay_attestation/`.
- **Related:** `add-recording-and-audit-event-streams` (the stream and subjects) and
  `camera-streaming`.
- **Non-goals:**
  - verifying attestations in core;
  - camera-native signing (Axis Signed Video, C2PA);
  - changing recording or relay behavior.
