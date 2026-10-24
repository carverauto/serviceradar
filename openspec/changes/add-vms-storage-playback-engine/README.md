# VMS implementation handoff

## Current pickup

Foundation #5950 and runtime #5952/#5954 are merged.
[Runtime PR #5954](https://github.com/carverauto/serviceradar/pull/5954) merged
at `9c3388359ad9a5ef079c2aa1b1ae7a0e7100f692` from
`89d50a7f0d7930686d9dab662ec0cb5aa897387c` after all 18 GitHub checks passed.
Guarded suite
[7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a)
executed all 12 targets once, uncached; suite, observer, teardown and release
returned 0. The runtime pass changes live relay ownership and closure even while
recording is disabled. It has not been deployed.

[Archive PR #5955](https://github.com/carverauto/serviceradar/pull/5955) merged
at `88c5a324793e4cff4155378c29fc29ec5949da6b`. Its archive head
`72a81f96c4dfaa3d801b95dbab5150423f9a9cf5` passed all 19 GitHub checks. Guarded
suite
[0df082fa](https://carverauto.buildbuddy.io/invocation/0df082fa-1895-4d75-be6a-8e90aaa60d0f)
executes all 12 targets once, uncached, and passes; suite, observer, teardown and
release return 0. The block lane has 430 tests, no failures or exclusions. The
worker lane has 329 tests, no failures, with all three worker cases included and
eight other cases excluded. The earlier prepublication Test exception did not
waive final CI. [Validation history](validation.md) preserves the negative run
and the exact-parent pass.

[Upload-intent PR #5960](https://github.com/carverauto/serviceradar/pull/5960)
merged at `29b30748dfe212ba0672bd2cd53342303ecbbc26`. It retains
[immutable upload intent](upload-intent.md) on that archive parent. Object
identity is derived under the existing upload fence and retained independently of
later upload leases. No storage request is sent. Migration `20261024030000` added
that intent table with restrictive block and destination references. The chart
migration floor has since moved; [validation.md](validation.md) owns the current
version. Focused and full non-database results are in
[validation.md](validation.md). Its final guarded suite
[853e4601](https://carverauto.buildbuddy.io/invocation/853e4601-ef2c-419e-b9c3-cfc8349da412)
passes all 12 targets uncached; the owning serial lane runs 260 tests with no
failures or exclusions, including all five upload-intent cases. Its prepublication
Test exception did not waive that final CI.

[Media PR #5959](https://github.com/carverauto/serviceradar/pull/5959) merged at
`ad424ac6b794f73abddd02e51c560a77d9af10fa` after all 19 checks passed on
`10a70e71c39f91fcb30fa90389c6fc0130840213`. It adds test-only
[codec](codec-capabilities.md), [RTCP clock](clock-capabilities.md) and
[logical block-byte](block-byte-costs.md) experiments. Both existing fixture
targets use supported BuildBuddy deadlines of 120 seconds with zero termination
grace, and the already-pinned `pion/rtcp` v1.2.17 require is direct. Every media
assertion and tolerance is unchanged. The generator timeout control fails after
120.01 seconds, and the restored-source focused checks pass. The final guarded
core and web suites pass 12 and seven targets respectively, all uncached, with
successful observer, teardown and lease-release commands. These are bounded
experiments, not production audio/HEVC admission or trusted UTC mapping.

The current checkpoint adds [bounded dispatch observations](upload-dispatch.md)
on this merged parent. It retains one operation per intent, one committed marker,
the original deadline and bounded late-response/conflict evidence. The coordinator
does not perform provider I/O. Its database validation must come from the new
checkpoint's own guarded PR CI; earlier green suites cannot prove new code.
[validation.md](validation.md) records the approved prepublication exception.
That exception lets BazelCI Core Integration run these cases first. It passes
no scenario and does not waive final CI.

Production recording admission and unknown UTC are unchanged. Recording stays
disabled. The operator-confirmed live RTSP transport must remain working. No
runtime rollout, uploader, archive index, availability transition or new live
provider exercise is in this draft. Destination registration remains unqualified
and grants no storage operations.

## Priority order

1. Keep tasks 0.4 and 0.6 open. The experiments measure pinned libraries and
   logical bytes. They do not select a codec matrix, synchronization tolerance
   or production block size.
2. Validate bounded dispatch and late-response bookkeeping, then separately implement
   qualified provider operations, byte verification and index publication.
   Immutable intent is retained. It is not permission to send bytes.
3. Complete playback, preservation, hosted lifecycle and optional-worker work in
   [tasks.md](tasks.md), respecting [Cloud ownership](cloud-control-plane.md).
4. Complete synthetic failure, security and capacity acceptance before the
   designated live environment. All committed fixtures and examples remain invented.

## Current evidence

| Contract | Evidence | Remaining gate |
| --- | --- | --- |
| Runtime repair | #5954 merged from `89d50a7f`; guarded [7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a) passes 12/12 with lifecycle statuses zero | Deployment acceptance |
| Archive parent | #5955 merged at `88c5a324`. Exact `72a81f96`, guarded `0df082fa`, all 19 GitHub checks pass | No uploader, availability or provider readiness |
| Immutable intent | #5960 merged at `29b30748`; guarded `853e4601` passes all 12 targets, including its five new cases | No wire operation or availability is established |
| Dispatch observations | One retained operation, deadline, marker and bounded late-response facts; see [contract](upload-dispatch.md) | Current-checkpoint guarded database validation and no-mistakes review; provider I/O remains absent |
| Media and fixture deadline | With the supported 120-second BuildBuddy action deadline, the deliberately stalled generator times out after 120.01 seconds. Restored-source [aabf88b7](https://carverauto.buildbuddy.io/invocation/aabf88b7-c9af-4d0e-825a-ecc6b5ccfb39) executes all nine focused targets uncached: native media, RTSP, RTCP, six Chromium cases and both quality checks pass | Product playback authorization and full authenticated deployment recovery remain open |
| Media full sweep | Clean repair `43c32a8c` passes 454 targets in [1c64bc77](https://carverauto.buildbuddy.io/invocation/1c64bc77-528f-4b2e-97aa-3e75c8e6dbf0): one executes, 453 use cache; two Swift platform skips | Production audio/HEVC, trusted clock mapping and deployment remain separate |
| Logical block bytes | [4a3336d1](https://carverauto.buildbuddy.io/invocation/4a3336d1-0c98-4b2d-ab91-168b55c83c50): nine media tests and quality execute and pass; the omitted-append control fails frame conservation | Database/WAL, cache, cloud requests and deployment sizing remain unmeasured |
| Provider/Cloud | Synthetic conditional-write and explicit-SSE diagnostics; both prior live exercises cleaned and rechecked | Live readiness remains failed; explicit-SSE/conditional-write, policy and Object Lock require provider proof |

[Detailed validation evidence](validation.md) retains the invocation links,
negative controls and the source scope of each proof. Implementation choices
live in [choices.md](choices.md).

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), [upload-intent.md](upload-intent.md)
and [upload-dispatch.md](upload-dispatch.md) and the current diff. Archive #5955 merged at
`88c5a324793e4cff4155378c29fc29ec5949da6b`. Upload-intent #5960 merged at
`29b30748dfe212ba0672bd2cd53342303ecbbc26`.
[Media PR #5959](https://github.com/carverauto/serviceradar/pull/5959) merged at
`ad424ac6`. Preserve every ownership, manifest, archive and
upload-intent assertion, the three experiments, the 120-second fixture deadlines
and the direct `pion/rtcp` v1.2.17 require. Tasks 0.4 and 0.6 remain incomplete
after these bounded measurements.

Finish validating and publishing the bounded dispatch checkpoint through
no-mistakes. Keep its original-deadline fence, single marker, late observations
and permanent conflict evidence. The marker grants no provider qualification.
The next implementation boundary is qualified provider operations and byte
verification. A timeout is unresolved work, not proof that a remote request was
cancelled; a replacement lease must never rearm the retained operation.

Keep provider I/O outside CNPG transactions and credentials behind the isolated
storage boundary. Provider qualification, credential generation and policy must
be current before a future request. No intent or observed response establishes
remote bytes, archive availability or permission to reclaim local media.
Releasing a current claim must not grant a stale recorder publication rights,
and a destination change must not retarget a retained block. Manifest encoding
validates metadata only. Recovery uses `Manifest.encode_descriptor/2` with the
frozen descriptor. `with_current_upload/3` deliberately requires `:uploading`
after its callback and checks the original deadline.

Do not merge this draft, deploy, enable recording, provision storage or run a
third live probe as part of this checkpoint. Every worktree uses Treehouse and
every PR no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
