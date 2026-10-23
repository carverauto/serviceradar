# VMS implementation handoff

## Current pickup

Connect the bounded local spool to H.264 CMAF packaging and prove decoding through
the persisted byte map with independently generated media. Then attach recording
to the existing relay consumer boundary with independently leased lifetime.
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
| Local spool | Core-elx RBE suite: 196 tests, zero failures; format/Credo passed in [aa845dcc](https://carverauto.buildbuddy.io/invocation/aa845dcc-daab-464a-988b-76dfe605d941) | Real CMAF integration, archive publication, power-loss/deployment acceptance |
| Ownership and media | Source audit identified viewer-only teardown, advisory reuse and unfenced relay token | Durable ownership races and independent recorder lifetime; synthetic media decode/seek |
| Provider access | Existing full-download egress API rejects partial responses | Explicit authenticated bounded-range contract and actual endpoint capability/security probes |

Local spool tests cover committed reads after writer exit, interrupted-tail
recovery, corruption rejection, immutable sealing, stale snapshots, independent
bounds and epoch-qualified block identity. They use invented storage bytes, not
video fixtures, and do not establish decoder or browser support. No runtime
recording path is enabled by this checkpoint. Implementation choices live in
[choices.md](choices.md).

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md) and the current implementation
diff before editing. Reuse the existing relay and object-storage owners. Complete
the current P0 proof before claiming a codec, browser or durability capability.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
