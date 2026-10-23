# VMS implementation handoff

## Current pickup

Foundation PR #5950 merged with all 20 checks passing, including guarded database
CI. [Runtime PR #5952](https://github.com/carverauto/serviceradar/pull/5952) is
running guarded CI after publishing its rebased head `796882e59b`. This branch
now follows that head and preserves every runtime and foundation fix. It adds
retained block authority, immutable archive destinations, persisted-descriptor
manifest encoding and
conditional-write/encryption diagnostics. Submit this pass through no-mistakes
against staging, then inspect the runtime and archive guarded database results.
A recorder freezes exact block metadata before releasing its claim; a later
uploader receives a separate lease for that frozen block and binds its destination
once under that lease. Destination registration remains unqualified;
it grants no credentials or storage operations. No uploader or archive index is
implemented yet. Recording stays disabled and no runtime rollout has occurred.
The combined sweep passes 436 targets, with 49 executed and two Swift platform
skips. All three Chromium seeking cases also execute and pass on the integrated
tree. These results do not execute the guarded database scenarios.
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

## Current validation

| Contract | Current evidence | Remaining gate |
| --- | --- | --- |
| Foundation | [PR #5950](https://github.com/carverauto/serviceradar/pull/5950) merged with all 20 checks passing, including 12 guarded DB targets | Does not cover the later runtime, block or binding scenarios |
| Runtime integration | All seven archive commits replay unchanged onto published runtime head `796882e59b`; the rebase adds only two upstream documentation updates | Finish runtime PR #5952 guarded CI and preserve any subsequent proxy fixes |
| Combined archive pass | [5c992fa7](https://carverauto.buildbuddy.io/invocation/5c992fa7-55d0-448b-a0eb-a4f02b23aea5): 436 targets pass, 49 execute, two Swift platform skips; scoped strict OpenSpec validation passes | New block/binding and runtime DB bodies must execute in sanctioned Core Integration CI |
| Browser/media | [d031da58](https://carverauto.buildbuddy.io/invocation/d031da58-b919-470f-8725-45a7f853e0ab): three Chromium cases execute and pass; 16 provider and eight media cases reuse verified cache results | Product playback authorization and full authenticated deployment recovery |
| Provider/Cloud | Synthetic conditional-write and explicit-SSE diagnostics pass; both earlier live exercises were cleaned and absence/revocation rechecked | Live readiness remains failed: default SSE was not confirmed, new explicit-SSE/conditional-write checks are not live-tested, and policy/Object Lock remain untested |

[Detailed validation evidence](validation.md) retains the individual invocation
links, negative controls and the limits of each proof. The existing live RTSP
path is operator-confirmed; no recording runtime has been deployed. The runtime
pass changes live relay ownership and closure even while recording is disabled.
Implementation choices live in [choices.md](choices.md).

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md) and the current implementation
diff before editing. This branch follows the runtime proxy's published head; its
legacy-close fixes are integrated. Submit this retained-block and immutable-binding
pass through the proxy against staging so sanctioned guarded database CI executes.
Inspect the runtime and archive results and preserve any subsequent runtime fixes
before building on them: releasing a current claim must not turn a stale recorder into a valid publisher,
and a destination change must not retarget a retained block. Then implement
immutable upload, verification and index publication. The manifest currently
validates metadata only. Baseline-only admission does not establish other codec
support. Live provider probe completion and guarded database race
tests remain independent gates.

Persist exact bounded remote-operation intent before dispatch; a timeout leaves
reconciliation work, not proof of cancellation. Keep provider I/O outside CNPG
transactions and credentials behind the isolated storage boundary. Recovery
uses `Manifest.encode_descriptor/2` with the frozen descriptor, without rebuilding
a native packaging snapshot. Publication also needs its own terminal fence:
`with_current_upload/3` deliberately requires `:uploading` after its callback.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
