# VMS implementation handoff

## Current pickup

Finish the distributed recorder claim and prove its independent lifetime in the
guarded database workflow. Local registry uniqueness is insufficient: different
core nodes can otherwise attach recorders under the same ingest epoch. Recording
stays disabled until a retained claim serializes recorder generations and block
allocation. Browser seek and real synthetic RTSP receipt tests now pass.
The operator has confirmed the agent-to-gateway-to-core live RTSP path works.
Preserve that path; live viewing does not establish archive durability or seeking.

## Priority order

1. Complete the P0 ownership, media-format and provider capability gates in
   [tasks.md](tasks.md). Keep unsupported codecs and unmeasured limits explicit.
2. Build a disabled-by-default recording path from shared ingest through durable
   local fragments, verified archive publication and authorized browser seeking.
3. Complete preservation, hosted lifecycle and optional-worker work in dependency
   order. Cloud ownership is scoped in [cloud-control-plane.md](cloud-control-plane.md).
4. Run synthetic failure/security/capacity acceptance before the operator-designated
   live environment. Never commit captured media, environment values or credentials.

## Evidence ledger

| Contract | Evidence | Remaining proof |
| --- | --- | --- |
| Scope and ownership | Planning PR #5945 merged; operator requested implementation | Runtime and Cloud acceptance remain unchecked |
| Existing live transport | Operator-confirmed agent/gateway/core live stream | Recorder lifetime, bounded fanout, archive and seek |
| Local spool and CMAF | Integrated RBE: eight media cases, provider protocol tests, core-elx quality and Chromium checks pass in [b4f35d58](https://carverauto.buildbuddy.io/invocation/b4f35d58-a326-4b32-98da-e80bfa728b3a). A recorder joining between keyframes waits for real in-band configuration and IDR; recovered fragments decode independently | Distributed recorder claims, archive publication, rotation/reclamation and power-loss/deployment acceptance |
| Synthetic RTSP | The real Go receiver feeds Packaging and recovered Spool bytes; independent decoding matches the generated source. Three integrated cases and quality pass in [d9c4389a](https://carverauto.buildbuddy.io/invocation/d9c4389a-5306-494a-86c2-3ffb37c65e97). Forced TCP loss, fresh receiver clocks, RTP wrap, changed configuration and missing keyframes are exercised. A deliberate receiver timebase mutation fails | Authenticated agent/gateway/core recovery and automatic reconnect orchestration; the harness explicitly starts the fresh receiver |
| Browser fragment seek | Actual packaged and recovered bytes decode in Chromium MSE. Evicting the buffer between seeks forces ranges in order 0, 2, 1, 0 and produces the expected decoded colors. Three cases pass in [83510fee](https://carverauto.buildbuddy.io/invocation/83510fee-06d5-4cc4-9862-fe62c20b1317); the wrong-color mutation fails | Product player/timeline integration and authorization; the fixture server does not establish the production gateway's access boundary |
| Recovery manifest | Version 1 metadata rejects open blocks, unbound object receipts, identity/path substitution and discontinuous fragment maps. Restored source passes 202 core-elx tests and quality in [10eed365](https://carverauto.buildbuddy.io/invocation/10eed365-20e5-40f3-b783-86184856aa44), reusing verified cached results. Permitting timing gaps fails in [79789014](https://carverauto.buildbuddy.io/invocation/79789014-5e3c-415e-96b8-63d8269ae90d) | Remote byte/init/manifest verification and idempotent fenced publication; metadata alone establishes neither durability nor authorization |
| Durable ownership | Relay reservations, adoption, heartbeat, idle close and expiry cleanup use the persisted owner fence. Five remote targets pass in [d6e1ddea](https://carverauto.buildbuddy.io/invocation/d6e1ddea-ac90-485d-87c5-85b5dccc0979), including 191 core-elx tests, 1,014 core tests, quality checks and executable integration selection. Restoring the old close behavior fails the retained-consumer regression | Execute ownership, lifecycle, manager and reaper DB bodies in the guarded in-cluster workflow; prove independent recorder lifetime |
| Provider access | Authenticated bounded ranges pass real TLS/CONNECT, response-status, object-identity, byte/header/deadline tests in [eedb3bc5](https://carverauto.buildbuddy.io/invocation/eedb3bc5-2d1a-41ed-8c64-ab3cd22d74a0). Deliberately accepting HTTP 200 failed the control | Actual endpoint capability/security probes, gateway authorization and measured request cost |
| Provider diagnostic | Eight executable S3 protocol cases, production-release startup and quality pass in [e6cfe063](https://carverauto.buildbuddy.io/invocation/e6cfe063-d73a-48be-8684-a0da973b3236). A signed-checksum mutation fails. The finite opt-in job persists recovery receipts before mutations | Live endpoint results and exact resource cleanup are pending. Broad provider keys are not recorder credentials; policy/Object Lock remain untested. [Operator runbook](../../../build/media/provider-probe.md) |
| A/V diagnostic | Stream Doctor measured 3 ms control drift and 503 ms with a 500 ms injected delay; removing the delay made the fault assertion fail. Integrated target passes in [90139de1](https://carverauto.buildbuddy.io/invocation/90139de1-7abd-4d0d-8489-6fb40a65f9ea), using the verified cached result | Product audio support and RTSP fault coverage; [scope, bounds and fresh-run evidence](stream-doctor.md) |
| Foundation unit sweep | `make test`: 431 passed, two platform-specific Swift targets skipped in [daa827a4](https://carverauto.buildbuddy.io/invocation/daa827a4-b75a-42ca-8626-0d9429f8c753) | Review-proxy and guarded database CI results; rerun affected checks for runtime integration |

Local spool tests cover committed reads after writer exit, interrupted-tail
recovery, corruption rejection, immutable sealing, stale snapshots, independent
bounds and epoch-qualified block identity. The separate media target generates
75 synthetic baseline H.264 frames with pinned FFmpeg, then independently probes
and decodes every recovered fragment and compares all decoded pixels with the
source. Final-sample duration inference survives recovery as explicit provenance.
The separate browser suite establishes fragment seeking, and the RTSP suite
establishes recording behavior after an explicitly restarted synthetic receiver.
Neither proves the full authenticated deployment recovery path. No live recording
path is enabled by this checkpoint. Implementation choices live in
[choices.md](choices.md).

The ownership, lifecycle, manager and reaper database scenarios have been compiled
and selected, but their test bodies have not yet run. They require the sanctioned
in-cluster Core Integration workflow; the unit sweep cannot establish those
concurrency contracts. The owner and consumer tables are additive, but the runtime
pass changes live relay ownership and closure. It has not been deployed.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md) and the current implementation
diff before editing. Reuse `CameraRecording.Packaging` and `CameraRecording.Spool`
for recorder-lifetime integration. Reconcile the foundation review-proxy fixes
before validating the combined runtime branch. After durable claims, add the
historical block authority needed for recovery after a recorder stops; releasing
a current claim must not turn a stale recorder into a valid publisher. Then
implement immutable upload, verification and index publication. The manifest
currently validates metadata only. Baseline-only admission does not establish
other codec support. Live provider probe completion and guarded database race
tests remain independent gates.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
