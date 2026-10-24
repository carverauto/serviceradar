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
later upload leases. No storage request is sent. Migration `20261024030000` adds
one Ash table with restrictive block and destination references; the chart
migration floor follows it. Focused and full non-database results are in
[validation.md](validation.md). That checkpoint still required its own sanctioned
PR CI for five guarded database cases. This media draft does not rerun them and
does not treat the merge as a new database result.

[Media PR #5959](https://github.com/carverauto/serviceradar/pull/5959) is this
published draft against staging. It adds test-only
[codec](codec-capabilities.md), [RTCP clock](clock-capabilities.md) and
[logical block-byte](block-byte-costs.md) experiments. Both existing fixture
targets use supported BuildBuddy deadlines of 120 seconds with zero termination
grace, and the already-pinned `pion/rtcp` v1.2.17 require is direct. Every media
assertion and tolerance is unchanged. The generator timeout control fails after
120.01 seconds, and the restored-source focused checks pass. The media delta
relative to `72a81f96` is test, build and docs only. Merged #5955 and #5960 mean
this comparison no longer carries unmerged archive or upload-intent ancestry.

Production recording admission and unknown UTC are unchanged. Recording stays
disabled. The operator-confirmed live RTSP transport must remain working. No
runtime rollout, uploader, archive index, availability transition or new live
provider exercise is in this draft. Destination registration remains unqualified
and grants no storage operations.

## Priority order

1. Keep tasks 0.4 and 0.6 open. The experiments measure pinned libraries and
   logical bytes. They do not select a codec matrix, synchronization tolerance
   or production block size.
2. Add bounded dispatch and late-response bookkeeping, then separately implement
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
| Immutable intent | #5960 merged at `29b30748`. Derivation, exact retries and restrictive retention are implemented; focused and full non-database results are in [validation.md](validation.md) | The five guarded database cases stay scoped to that checkpoint's required PR CI. This draft does not rerun them. No wire operation or availability is established |
| Media and fixture deadline | With the supported 120-second BuildBuddy action deadline, the deliberately stalled generator times out after 120.01 seconds. Restored-source [aabf88b7](https://carverauto.buildbuddy.io/invocation/aabf88b7-c9af-4d0e-825a-ecc6b5ccfb39) executes all nine focused targets uncached: native media, RTSP, RTCP, six Chromium cases and both quality checks pass | Product playback authorization and full authenticated deployment recovery remain open |
| Media full sweep | Clean repair `43c32a8c` passes 454 targets in [1c64bc77](https://carverauto.buildbuddy.io/invocation/1c64bc77-528f-4b2e-97aa-3e75c8e6dbf0): one executes, 453 use cache; two Swift platform skips | Production audio/HEVC, trusted clock mapping and deployment remain separate |
| Logical block bytes | [4a3336d1](https://carverauto.buildbuddy.io/invocation/4a3336d1-0c98-4b2d-ab91-168b55c83c50): nine media tests and quality execute and pass; the omitted-append control fails frame conservation | Database/WAL, cache, cloud requests and deployment sizing remain unmeasured |
| Provider/Cloud | Synthetic conditional-write and explicit-SSE diagnostics; both prior live exercises cleaned and rechecked | Live readiness remains failed; explicit-SSE/conditional-write, policy and Object Lock require provider proof |

[Detailed validation evidence](validation.md) retains the invocation links,
negative controls and the source scope of each proof. Implementation choices
live in [choices.md](choices.md).

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), [upload-intent.md](upload-intent.md)
and the current diff. Archive #5955 merged at
`88c5a324793e4cff4155378c29fc29ec5949da6b`. Upload-intent #5960 merged at
`29b30748dfe212ba0672bd2cd53342303ecbbc26`.
[Media PR #5959](https://github.com/carverauto/serviceradar/pull/5959) is this
published draft against staging. Preserve every ownership, manifest, archive and
upload-intent assertion, the three experiments, the 120-second fixture deadlines
and the direct `pion/rtcp` v1.2.17 require. Tasks 0.4 and 0.6 remain incomplete
after these bounded measurements.

The next product checkpoint persists one bounded dispatch and write-once response
observation per intent. A before-wire marker must commit before anything can be
sent. Reject ambient transactions at public mutation boundaries. Retain the
original dispatch deadline even when the upload lease is renewed; repeated
marking must never grant another send. Late responses survive lease replacement
without granting authority. Commit conflict evidence while preserving the first
receipt, then return the conflict error outside that transaction. A timeout is
unresolved work, not proof that a remote request was cancelled.

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
