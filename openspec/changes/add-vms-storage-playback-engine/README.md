# VMS implementation handoff

## Current pickup

Foundation PR #5950 has all 20 checks passing, including guarded database CI.
Its reviewed fixes are reconciled into this runtime branch; submit this branch
through its own proxy run and execute the additional guarded runtime database
tests. The combined sweep and Chromium playback checks pass. A retained
claim serializes recorder generations and block allocation across nodes, and
publication rechecks persisted relay expiry. Recording stays disabled; no runtime
rollout or archive-availability claim is made.
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
| Local spool and CMAF | Integrated RBE: eight media cases, provider protocol tests, core-elx quality and Chromium checks pass in [b4f35d58](https://carverauto.buildbuddy.io/invocation/b4f35d58-a326-4b32-98da-e80bfa728b3a). A recorder joining between keyframes waits for real in-band configuration and IDR; recovered fragments decode independently | Guarded recorder-claim execution, archive publication, rotation/reclamation and power-loss/deployment acceptance |
| Synthetic RTSP | The real Go receiver feeds Packaging and recovered Spool bytes; independent decoding matches the generated source. Three integrated cases and quality pass in [d9c4389a](https://carverauto.buildbuddy.io/invocation/d9c4389a-5306-494a-86c2-3ffb37c65e97). Forced TCP loss, fresh receiver clocks, RTP wrap, changed configuration and missing keyframes are exercised. A deliberate receiver timebase mutation fails | Authenticated agent/gateway/core recovery and automatic reconnect orchestration; the harness explicitly starts the fresh receiver |
| Browser fragment seek | Actual packaged and recovered bytes decode in Chromium MSE. Evicting the buffer between seeks forces ranges in order 0, 2, 1, 0 and produces the expected decoded colors. Three cases pass after foundation reconciliation in [468a68df](https://carverauto.buildbuddy.io/invocation/468a68df-accb-49c7-b508-f171dfc3b10a); the wrong-color mutation fails | Product player/timeline integration and authorization; the fixture server does not establish the production gateway's access boundary |
| Recovery manifest | Version 1 metadata rejects open blocks, unbound object receipts, identity/path substitution, discontinuous fragment maps and excessive metadata allocations. Restored source passes 203 core-elx tests and quality in [6d3c95b2](https://carverauto.buildbuddy.io/invocation/6d3c95b2-1def-4657-a3b3-db4e25458a63). Permitting timing gaps fails in [79789014](https://carverauto.buildbuddy.io/invocation/79789014-5e3c-415e-96b8-63d8269ae90d); permitting excessive fragment counts fails in [ff07d967](https://carverauto.buildbuddy.io/invocation/ff07d967-e611-40a0-b4e5-0473f68c6875) | Remote byte/init/manifest verification and idempotent fenced publication; metadata alone establishes neither durability nor authorization |
| Durable ownership | Relay reservations, adoption, heartbeat, idle close and expiry cleanup use the persisted owner fence. Five remote targets pass in [d6e1ddea](https://carverauto.buildbuddy.io/invocation/d6e1ddea-ac90-485d-87c5-85b5dccc0979), including 191 core-elx tests, 1,014 core tests, quality checks and executable integration selection. Restoring the old close behavior fails the retained-consumer regression | Execute ownership, lifecycle, manager and reaper DB bodies in the guarded in-cluster workflow; prove independent recorder lifetime |
| Recorder exclusion | Retained claims carry a separate recorder epoch, authenticated ingress ID, provisioned storage UUID and durable sequence counter. The first claim pass passes nine focused RBE checks in [c9dcd2fe](https://carverauto.buildbuddy.io/invocation/c9dcd2fe-fde4-43d6-a328-b8b344ec4be7). The relay-expiry correction passes core quality, core-elx units and integration selection in [bd3031f3](https://carverauto.buildbuddy.io/invocation/bd3031f3-d0a2-49f1-a9e6-c60156d8a4f9) | Competing-claimant, expiry-rollback and Worker restart DB bodies remain unexecuted until guarded CI |
| Provider access | Authenticated bounded ranges pass real TLS/CONNECT, response-status, object-identity, byte/header/deadline tests in [eedb3bc5](https://carverauto.buildbuddy.io/invocation/eedb3bc5-2d1a-41ed-8c64-ab3cd22d74a0). Deliberately accepting HTTP 200 failed the control | Actual endpoint capability/security probes, gateway authorization and measured request cost |
| Provider diagnostic | Eight executable protocol cases, release startup and quality pass after the opaque-receipt correction in [4a5dd038](https://carverauto.buildbuddy.io/invocation/4a5dd038-3a46-4e1d-a944-7a00b9aed942). The corrected second live exercise verified private access, roles, conditional reads, checksums, multipart completion/hash/cross-part range and abort. All temporary resources from both exercises were removed and absence rechecked | Both object types lack confirmed default SSE-S3, so the overall live result remains failed. Explicit SSE-S3, atomic no-overwrite, policy/Object Lock are untested. Broad provider keys are not recorder credentials. [Operator runbook](../../../build/media/provider-probe.md) |
| A/V diagnostic | Stream Doctor measured 3 ms control drift and 503 ms with a 500 ms injected delay; removing the delay made the fault assertion fail. Integrated target passes in [90139de1](https://carverauto.buildbuddy.io/invocation/90139de1-7abd-4d0d-8489-6fb40a65f9ea), using the verified cached result | Product audio support and RTSP fault coverage; [scope, bounds and fresh-run evidence](stream-doctor.md) |
| Foundation validation | [PR #5950](https://github.com/carverauto/serviceradar/pull/5950) passes all 20 checks. The final fix passes 199 core-elx and six media tests in [edd24097](https://carverauto.buildbuddy.io/invocation/edd24097-fb2c-4898-ad3e-daae1bf87952). Core Integration executes all 12 targets in [681ba460](https://carverauto.buildbuddy.io/invocation/681ba460-25c3-4cdb-af7a-94a14e169724), with successful fixture teardown and lease release | Foundation merge; this PR does not contain the runtime claim/Worker cases |
| Combined runtime sweep | After replaying all 19 runtime commits onto the reviewed foundation with equivalent patches, `make test` passes 436 targets, with two Swift platform skips, in [bbf2e694](https://carverauto.buildbuddy.io/invocation/bbf2e694-c755-43bf-b2ee-d434aebeb471). Fifty targets execute; the remainder use verified cache results. Strict OpenSpec validation also passes | Runtime proxy and guarded database CI; the unit sweep does not execute database integration bodies |

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

The foundation ownership database lane has passed in PR #5950. Additional runtime
lifecycle, manager, reaper, recorder-claim and Worker scenarios have been compiled
and selected but still need their own sanctioned Core Integration run; the unit
sweep cannot establish those concurrency contracts. The owner and consumer tables
are additive, but the runtime pass changes live relay ownership and closure. It
has not been deployed.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md) and the current implementation
diff before editing. Reuse `CameraRecording.Packaging` and `CameraRecording.Spool`
for recorder-lifetime integration. The foundation review-proxy fixes are preserved
in the combined runtime branch. Complete runtime proxy/CI validation, then add the
historical block authority needed for recovery after a recorder stops; releasing
a current claim must not turn a stale recorder into a valid publisher. Then
implement immutable upload, verification and index publication. The manifest
currently validates metadata only. Baseline-only admission does not establish
other codec support. Live provider probe completion and guarded database race
tests remain independent gates.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
