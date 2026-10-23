# VMS implementation handoff

## Current pickup

Foundation PR #5950 is merged. Runtime PR #5952 has all 20 checks passing at
`b80465bfd6`, including 12 executed guarded database targets, but remains a draft:
its CI repair weakens nested rollback and promotes an explicit nil actor. This
follow-up preserves that published revision and adds two regressions to existing
guarded keepers. Production code and every earlier assertion are unchanged.

First publish this regression checkpoint through no-mistakes against staging and
observe the two intended failures in Core Integration. Then have the same proxy
restore nested transaction rollback, decide active-consumer retention before the
nested close mutation, and remove actor promotion while fixing the positive test
scope. Preserve all assertions and rerun guarded CI to green before readiness.
Recording stays disabled; no runtime rollout or archive-availability claim is made.
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
| Durable ownership | The published runtime passes all 12 guarded DB targets in [23177e08](https://carverauto.buildbuddy.io/invocation/23177e08-ea4b-45c8-b90e-8f9a24b11d1a), with successful teardown and lease release | Execute the added nested rejected-write and explicit nil-actor regressions, observe their intended failures, then repair and rerun |
| Recorder exclusion | Retained claims carry a separate recorder epoch, authenticated ingress ID, provisioned storage UUID and durable sequence counter. The published runtime's guarded suite passes | Restore the shared ownership transaction's rollback guarantee and repeat guarded validation; full authenticated deployment recovery remains separate |
| Provider access | Authenticated bounded ranges pass real TLS/CONNECT, response-status, object-identity, byte/header/deadline tests in [eedb3bc5](https://carverauto.buildbuddy.io/invocation/eedb3bc5-2d1a-41ed-8c64-ab3cd22d74a0). Deliberately accepting HTTP 200 failed the control | Actual endpoint capability/security probes, gateway authorization and measured request cost |
| Provider diagnostic | Eight executable protocol cases, release startup and quality pass after the opaque-receipt correction in [4a5dd038](https://carverauto.buildbuddy.io/invocation/4a5dd038-3a46-4e1d-a944-7a00b9aed942). The corrected second live exercise verified private access, roles, conditional reads, checksums, multipart completion/hash/cross-part range and abort. All temporary resources from both exercises were removed and absence rechecked | Both object types lack confirmed default SSE-S3, so the overall live result remains failed. Explicit SSE-S3, atomic no-overwrite, policy/Object Lock are untested. Broad provider keys are not recorder credentials. [Operator runbook](../../../build/media/provider-probe.md) |
| A/V diagnostic | Stream Doctor measured 3 ms control drift and 503 ms with a 500 ms injected delay; removing the delay made the fault assertion fail. Integrated target passes in [90139de1](https://carverauto.buildbuddy.io/invocation/90139de1-7abd-4d0d-8489-6fb40a65f9ea), using the verified cached result | Product audio support and RTSP fault coverage; [scope, bounds and fresh-run evidence](stream-doctor.md) |
| Foundation validation | [PR #5950](https://github.com/carverauto/serviceradar/pull/5950) merged with all 20 checks passing. Core Integration executes all 12 targets in [681ba460](https://carverauto.buildbuddy.io/invocation/681ba460-25c3-4cdb-af7a-94a14e169724), with successful fixture teardown and lease release | Does not establish the later runtime or archive contracts |
| Regression checkpoint | Core quality, integration selection and CI registration execute and pass in [5042be95](https://carverauto.buildbuddy.io/invocation/5042be95-4711-4ae6-853e-d266fbdacdd8). The full sweep passes 436 targets, with two executed and two Swift skips, in [01f10928](https://carverauto.buildbuddy.io/invocation/01f10928-9ba6-406f-a942-de1a663b340f). Independent review found no defects in the two test extensions or prepared repair | New DB assertions have not executed; the sweep does not prove their failure or the subsequent repair |

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

The nested regression deliberately handles a rejected inner write in its parent
transaction; the source must still remain unchanged. The authorization regression
supplies both a user and an explicit nil actor; that scope must remain anonymous.
These extend existing keepers and cleanup without adding a test lane or production
seam. Only sanctioned PR Core Integration may execute their database bodies.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md) and the current implementation
diff. Complete the regression-first proxy sequence above. Restore unconditional
ownership transactions while keeping the typed domain-error envelope, all original
deadlines and captured relay checks. Put the idle precheck inside the existing locked
profile flow, and supply an explicit actor in the successful plain-map fixture.

Carry the corrected published runtime into the dependent archive block/binding
and media feasibility branches through their review workflows. Then implement
immutable upload, verification and index publication. Releasing a current claim
must not grant a stale recorder publication rights. Manifest encoding establishes
metadata validity only; provider capability and deployment recovery remain
separate gates.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
