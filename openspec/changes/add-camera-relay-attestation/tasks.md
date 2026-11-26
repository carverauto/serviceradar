# Tasks: hardware-signed camera relay attestations

## 1. Spike
- [ ] 1.1 Check that access-unit hashes survive ServiceRadar's own path from relay to CMAF fragments, for H.264 and H.265 with and without B-frames; record any profile that needs a fallback

## 2. Hashing and attestation (agent)
- [ ] 2.1 Normalization and `sr-au-v1` hashing over the shared uploader; per-stream chains
- [ ] 2.2 Golden vectors under `go/pkg/agent/testdata/relay_attestation/` (H.264/H.265, Annex B/AVCC, B-frames)
- [ ] 2.3 Interval builder: RFC 6962 Merkle root, JCS + DSSE, `seq` and previous digest, 64 KiB part splitting
- [ ] 2.4 Asynchronous signing queue, `unsigned` overflow marking, on-disk buffer for uplink outages

## 3. Signers
- [ ] 3.1 TPM 2.0 backend (`go-tpm`): non-exportable P-256 key, wrapped blob in agent state, EK chain and `TPM2_Certify` evidence
- [ ] 3.2 PIV (YubiKey) and YubiHSM 2 backends with device attestation chains; PIN from the agent secret store
- [ ] 3.3 Preflight and status reporting (`disabled`, `active`, `degraded`, `unavailable`) plus `health.state_change`
- [ ] 3.4 Packaging: `tss` group access to `/dev/tpmrm0`, optional PC/SC; docs for enabling a vTPM on VMware, Hyper-V and Proxmox

## 4. Transport and publication
- [ ] 4.1 Uplink message types for attestations and signer announcements, passed through the gateway unmodified
- [ ] 4.2 Core publisher for `camera.recording.relay_attestations.v1` and `camera.recording.relay_signers.v1` with `Nats-Msg-Id`
- [ ] 4.3 Agent config `camera_relay_attestation.*`, delivered through the control-plane config

## 5. Validation
- [ ] 5.1 Unit tests: normalization against the vectors, Merkle and chain, queue overflow, never blocking relay, no plugin signing path
- [ ] 5.2 Integration: a synthetic RTSP source with a software TPM simulator (test builds only) checked end to end through core publication
- [ ] 5.3 `openspec validate add-camera-relay-attestation --strict`
