# VMS implementation handoff

## Current pickup

Foundation PR #5950 and [runtime PR #5952](https://github.com/carverauto/serviceradar/pull/5952)
are merged. #5952 landed at `b80465bfd6`. Its guarded suite
[23177e08](https://carverauto.buildbuddy.io/invocation/23177e08-ea4b-45c8-b90e-8f9a24b11d1a)
executed 12 of 12, with observer, teardown, and release each returning 0. That
merged code skipped a nested ownership transaction and promoted a plain-map user
when actor was nil.

[PR #5954](https://github.com/carverauto/serviceradar/pull/5954) is the
regression repair. It published those two behaviors plus the keeper regressions
at `158aa45657`. Guarded workflow
[f1ecf78d](https://carverauto.buildbuddy.io/invocation/f1ecf78d-80ec-42ce-9c17-de022207c6c8),
suite `d607f3a0-48a9-4299-9c01-2fdd395a6bb8`, executed 12 of 12: 10 passed and
the two new keepers failed as intended. Observer, teardown, and release each
returned 0. `camera_ingest_ownership_integration_test.exs:250` (serial_6)
returned `{:ok, :handled}` where the keeper requires
`{:error, :publication_rejected}`. The callback receipt passed. The persisted
display-name assertion was not reached. `relay_session_manager_test.exs:83`
(serial_0) opened `%{user: user, actor: nil}` and returned
`{:ok, %RelaySession{}}` where the keeper requires `{:error, :not_found}`.

This draft is [PR #5955](https://github.com/carverauto/serviceradar/pull/5955).
It imports the reviewed repair `a8590062edff8c3cd31418562c740bf4f854bd22`.
`IngestOwnership.transaction/1` always uses `Ash.transact`, still wrapping atom
and tagged-tuple domain refusals and passing genuine Ash or database errors
through. `RelaySessionManager.fenced_close/5` calls
`IngestOwnership.require_idle/2` immediately before `begin_idle_close` on the
default branch, under the profile lock already held. Forced close, the soft
viewer retain branch, legacy close, and `begin_idle_close`'s epoch, token,
relay, database-time, and deadline checks stay as they were. The plain-map
user-to-actor fallback is gone from `read_ash_opts/2`. The successful plain-map
fixture passes `actor: user` beside `user`. The explicit `actor: nil` assertion
is unchanged. Focused repair proof
[3fa1b9f1](https://carverauto.buildbuddy.io/invocation/3fa1b9f1-8003-4245-b11c-e2c3ada4224c)
passed four targets, three executed, with the formatter cached. Positive
runtime and archive database proof is pending. #5954's own re-review and
positive CI continue on that draft. This import lets the archive tests validate
the same correction.

This pass keeps retained block authority, immutable archive destinations,
persisted-descriptor manifest encoding, and conditional-write/encryption
diagnostics. A recorder freezes one immutable descriptor while its original
recorder fence is still valid, before the claim is released. A later uploader
takes a separate lease and binds one destination once under that lease. The
final fresh database-time check uses the deadline captured at the start of
`with_current_upload/3`, so a nested renewal cannot extend an already expired
upload. Identical destination registration is idempotent, conflicting content
is rejected, and a referenced destination cannot be deleted. Registration
grants no credentials or storage operations. Block migration
`20261023160000` and binding migration `20261023180000` stay additive, and the
chart migration floor is `20261023180000`. Fixture cleanup deletes dependent
blocks before the other committed rows. Provider cleanup stays exact, under the
unchanged 80/30 request limits, and keeps unresolved receipts when absence is
not verified. No uploader, archive index, availability state, or recording
enablement is in this pass. Recording stays disabled and no runtime rollout has
occurred.

The combined sweep passes 436 targets, with 49 executed and two Swift platform
skips, in
[5c992fa7](https://carverauto.buildbuddy.io/invocation/5c992fa7-55d0-448b-a0eb-a4f02b23aea5).
All three Chromium seeking cases execute and pass in
[d031da58](https://carverauto.buildbuddy.io/invocation/d031da58-b919-470f-8725-45a7f853e0ab).
These results do not execute the guarded database scenarios.
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
| Foundation | [PR #5950](https://github.com/carverauto/serviceradar/pull/5950) merged with all 20 checks passing, including 12 guarded DB targets in [681ba460](https://carverauto.buildbuddy.io/invocation/681ba460-25c3-4cdb-af7a-94a14e169724) | Does not cover the later runtime, block, or binding scenarios |
| Runtime repair | #5952 is merged at `b80465bfd6`. Negative suite `d607f3a0` on [f1ecf78d](https://carverauto.buildbuddy.io/invocation/f1ecf78d-80ec-42ce-9c17-de022207c6c8): 12 executed, 10 passed, 2 intended failures; observer, teardown, and release 0. Repair `a8590062`. Focused proof [3fa1b9f1](https://carverauto.buildbuddy.io/invocation/3fa1b9f1-8003-4245-b11c-e2c3ada4224c): 4 passed, 3 executed, formatter cached | Positive runtime database proof is pending on draft PR #5954. Positive archive database proof is pending on this draft |
| Historical block authority | Nine focused targets pass in [27053d5a](https://carverauto.buildbuddy.io/invocation/27053d5a-0d1c-45ae-9fda-2e9a412a4b16). Weakening descriptor continuity and count fails two manifest cases in [1c617b24](https://carverauto.buildbuddy.io/invocation/1c617b24-b950-4ef8-9bbf-58881832e059); restored source passes. The original upload deadline and migration `20261023160000` stay | Guarded DB execution of reservation, freeze, upload takeover, and expiry rollback. [Authority boundary](block-authority.md) |
| Immutable archive destination | Six focused targets pass in [f6c00dae](https://carverauto.buildbuddy.io/invocation/f6c00dae-99ab-4c6c-907d-a30a0d00ab4e). Allowing an unexpected field fails in [4c35622e](https://carverauto.buildbuddy.io/invocation/4c35622e-1396-4beb-bded-45596214e4ae); the parser is restored byte-for-byte. Bind-once and migration floor `20261023180000` stay | Guarded DB execution of registration, bind-once, expiry rollback, and restrictive deletion. [Binding contract](archive-binding.md) |
| Persisted descriptor | Four focused targets pass in [51ca7192](https://carverauto.buildbuddy.io/invocation/51ca7192-b501-4c2b-b3fe-85425239f51a): 207 unit cases, eight cached media cases, three freshly executed Chromium cases, and quality. Validation bypass [09d56db4](https://carverauto.buildbuddy.io/invocation/09d56db4-88d1-44bd-82f8-3f97f7cd66ea) and unsupported profile [b0368339](https://carverauto.buildbuddy.io/invocation/b0368339-fdfe-4fc6-8ec5-2b8ef3ecf7f7) fail the intended assertions | Remote byte verification and publication remain separate |
| Combined archive pass | [5c992fa7](https://carverauto.buildbuddy.io/invocation/5c992fa7-55d0-448b-a0eb-a4f02b23aea5): 436 targets pass, 49 execute, two Swift platform skips; scoped strict OpenSpec validation passes | New block, binding, and repaired-runtime DB bodies must execute in sanctioned Core Integration CI |
| Browser/media | [d031da58](https://carverauto.buildbuddy.io/invocation/d031da58-b919-470f-8725-45a7f853e0ab): three Chromium cases execute and pass; 16 provider and eight media cases reuse verified cache results | Product playback authorization and full authenticated deployment recovery |
| Provider/Cloud | Synthetic conditional-write and explicit-SSE diagnostics pass in [373125cd](https://carverauto.buildbuddy.io/invocation/373125cd-3ffc-4b55-9618-359fb128eb2c). Separate controls reject missing conditional headers, missing explicit encryption headers, and HTTP 200 completion errors. Both earlier live exercises were cleaned and absence/revocation rechecked. Exact cleanup stays under the 80/30 limits | Live readiness remains failed: default SSE was not confirmed, the new explicit-SSE and conditional-write checks are not live-tested, and policy/Object Lock remain untested. No third live probe |

[Detailed validation evidence](validation.md) retains the individual invocation
links, negative controls, and the limits of each proof. The existing live RTSP
path is operator-confirmed; no recording runtime has been deployed. The runtime
pass changes live relay ownership and closure even while recording is disabled.
Implementation choices live in [choices.md](choices.md).

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), and the current diff. This
draft is PR #5955. The runtime repair is in this tree. Revalidate from Review.
Require guarded Core Integration bodies, observer, teardown, and release to
pass before any readiness claim. Leave this PR draft. #5954's positive CI
continues on its own draft. Do not merge, deploy, enable recording, provision
storage, start an uploader or index, or run a third provider probe.

Releasing a current claim must not turn a stale recorder into a valid publisher,
and a destination change must not retarget a retained block. Then implement
immutable upload, verification, and index publication. The manifest validates
metadata only. Baseline-only admission does not establish other codec support.
Recovery uses `Manifest.encode_descriptor/2` with the frozen descriptor.
`with_current_upload/3` deliberately requires `:uploading` after its callback
and checks the original deadline. Live provider probe completion and guarded
database race tests remain independent gates.

Persist exact bounded remote-operation intent before dispatch; a timeout leaves
reconciliation work, not proof of cancellation. Keep provider I/O outside CNPG
transactions and credentials behind the isolated storage boundary.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
