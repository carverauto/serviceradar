# VMS implementation handoff

## Current pickup

Foundation #5950 and runtime #5952/#5954 are merged. Archive draft
[#5955](https://github.com/carverauto/serviceradar/pull/5955) at
`72a81f96c4dfaa3d801b95dbab5150423f9a9cf5` passes all 19 checks. Its guarded
suite [0df082fa](https://carverauto.buildbuddy.io/invocation/0df082fa-1895-4d75-be6a-8e90aaa60d0f)
executes all 12 targets once, uncached, and passes; suite, observer, teardown and
release return 0. The block lane has 430 tests, no failures or exclusions. The
worker lane has 329 tests, no failures, with all three worker cases included and
eight other cases excluded. The earlier prepublication Test exception did not
waive final CI. [Validation history](validation.md) preserves the negative run.

This branch adds [immutable upload intent](upload-intent.md) on that exact
archive parent. Object identity is derived under the existing upload fence and
retained independently of later upload leases. No storage request is sent.
Migration `20261024030000` adds one Ash table with restrictive block/destination
references; the chart migration floor follows it. New guarded database cases
still require this branch's sanctioned PR CI. Parent proof does not execute them.

A separate media branch measures codecs, RTCP mapping and logical block bytes.
Those experiments do not enable audio/HEVC recording or establish trusted UTC.
Production recording stays disabled. The operator-confirmed live RTSP transport
must remain working; no runtime rollout or new live provider exercise occurred.

## Priority order

1. Validate this intent checkpoint through no-mistakes and guarded PR CI.
2. Add bounded dispatch and late-response bookkeeping, then separately implement
   qualified provider operations, byte verification and index publication.
3. Complete playback, preservation, hosted lifecycle and optional-worker work in
   [tasks.md](tasks.md), respecting [Cloud ownership](cloud-control-plane.md).
4. Complete synthetic failure/security/capacity acceptance before the designated
   live environment. All committed fixtures and examples remain invented.

## Current evidence

| Contract | Evidence | Remaining gate |
| --- | --- | --- |
| Runtime repair | #5954 merged from `89d50a7f`; guarded [7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a) passes 12/12 with lifecycle statuses zero | Deployment acceptance |
| Archive parent | Exact `72a81f96`, guarded `0df082fa`, all 19 GitHub checks pass | No uploader, availability or provider readiness |
| Immutable intent | Derivation, exact retries and restrictive retention are implemented; focused and full results are recorded in [validation.md](validation.md) | Five new guarded database cases must execute on the published branch |
| Provider/Cloud | Synthetic conditional-write and explicit-SSE diagnostics; both prior live exercises cleaned and rechecked | Live readiness remains failed; explicit-SSE/conditional-write, policy and Object Lock require provider proof |

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), [upload-intent.md](upload-intent.md)
and the current diff. Preserve every existing ownership, manifest and archive
assertion. Focused/full non-database checks pass. Finish draft publication and guarded
database validation through no-mistakes against staging. Until #5955 merges, that comparison includes
its unmerged archive ancestry. Keep tracking issues and incomplete tasks open.

The next checkpoint persists one bounded dispatch and write-once response
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
remote bytes, archive availability or permission to reclaim local media. Do not
merge, deploy, enable recording, provision storage or run a third live probe as
part of this checkpoint. Every worktree uses Treehouse and every PR no-mistakes.
