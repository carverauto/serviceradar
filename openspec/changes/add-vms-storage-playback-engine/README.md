# VMS implementation handoff

## Current pickup

Attach the bounded H.264 CMAF packager and local spool to the existing relay
consumer boundary with independently leased recorder lifetime. The standalone
packager now proves independent fragment decoding through the recovered byte map.
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
| Local spool and CMAF | RBE: 196 core-elx tests and six media tests, zero failures; format/Credo and Hex checks passed in [35b5d9ce](https://carverauto.buildbuddy.io/invocation/35b5d9ce-82d2-4ebf-8da0-b8e80f715c0c). Independently generated H.264 survives packaging, seal/recovery and independent decoding through committed byte ranges | Archive publication, power-loss/deployment acceptance, synthetic RTSP reconnect and browser seek |
| Durable ownership | Ash owner/consumer resources, generated migration and database-time fencing API compile; eight database scenarios are registered in serial integration lane 6 | Execute the actual DB races in the guarded in-cluster workflow; integrate relay lifecycle and independent recorder lifetime |
| Provider access | Authenticated bounded ranges pass real TLS/CONNECT, response-status, object-identity, byte/header/deadline tests in [eedb3bc5](https://carverauto.buildbuddy.io/invocation/eedb3bc5-2d1a-41ed-8c64-ab3cd22d74a0). Deliberately accepting HTTP 200 failed the control | Actual endpoint capability/security probes, gateway authorization and measured request cost |
| A/V diagnostic | Stream Doctor measured 3 ms control drift and 503 ms with a 500 ms injected delay; removing the delay made the fault assertion fail. Integrated target passes in [90139de1](https://carverauto.buildbuddy.io/invocation/90139de1-7abd-4d0d-8489-6fb40a65f9ea), using the verified cached result | Product audio support and RTSP fault coverage; [scope, bounds and fresh-run evidence](stream-doctor.md) |
| Foundation unit sweep | `make test`: 431 passed, two platform-specific Swift targets skipped in [daa827a4](https://carverauto.buildbuddy.io/invocation/daa827a4-b75a-42ca-8626-0d9429f8c753) | Review-proxy and guarded database CI results; rerun affected checks for runtime integration |

Local spool tests cover committed reads after writer exit, interrupted-tail
recovery, corruption rejection, immutable sealing, stale snapshots, independent
bounds and epoch-qualified block identity. The separate media target generates
75 synthetic baseline H.264 frames with pinned FFmpeg, then independently probes
and decodes every recovered fragment and compares all decoded pixels with the
source. Final-sample duration inference survives recovery as explicit provenance.
This establishes fragment random access for the independent decoder; browser
seeking and transport reconnect remain unproved. No live recording path is
enabled by this checkpoint. Implementation choices live in
[choices.md](choices.md).

The ownership database scenarios have been compiled and selected, but their test
bodies have not yet run. They require the sanctioned in-cluster Core Integration
workflow; the unit sweep cannot establish those concurrency contracts. The new
owner and consumer tables are additive and do not yet change live relay behavior.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md) and the current implementation
diff before editing. Reuse `CameraRecording.Packaging` and `CameraRecording.Spool`
for the next recorder-lifetime integration, and the existing relay and
object-storage owners. Keep task 0.3 open until synthetic RTSP/reconnect and
browser seek pass; baseline-only admission does not establish other codec support.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
