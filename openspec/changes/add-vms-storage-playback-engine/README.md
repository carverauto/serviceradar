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
passed four targets, three executed, with the formatter cached. Draft #5954
published `89d50a7f0d` afterward. Its GitHub check rollup is success across 18
checks, including BazelCI, Web-NG DB, and Core Integration. Workflow
[a74b1f9f](https://carverauto.buildbuddy.io/invocation/a74b1f9f-ee0d-450f-88a0-7d26eeed15ed),
child
[7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a),
executed 12 of 12 tests and all passed. Suite, observer, teardown, and release
each returned 0. `integration_tests_serial_6` finished 256 tests with 0
failures. `integration_tests_serial_0` finished 401 tests with 0 failures and
1 skip. That run validates the imported runtime correction only.

Archive block, binding, and worker database bodies have never executed.
Published #5955 is still `37da666884`. Its first workflows
[b69c483d](https://carverauto.buildbuddy.io/invocation/b69c483d-c501-40f9-9c37-4576d286f037),
[2f02bddf](https://carverauto.buildbuddy.io/invocation/2f02bddf-6744-4eca-a7ff-5e89c9796d19),
and
[36f56b1b](https://carverauto.buildbuddy.io/invocation/36f56b1b-1d45-4eb2-8d17-2c4ee9807a6c)
stopped on the README merge conflict before any test body. This head
`8a5b83b0` is not published. The database cases are
`elixir/serviceradar_core/test/integration/camera_recording_blocks_integration_test.exs`
and
`elixir/serviceradar_core/test/integration/camera_recording_worker_integration_test.exs`,
both owned by `//elixir/serviceradar_core:integration_tests`. They stay
untested until a republished Core Integration run executes those lanes.
Descriptor encoding is
`elixir/serviceradar_core_elx/test/serviceradar_core_elx/camera_recording/manifest_test.exs`
on `//elixir/serviceradar_core_elx:unit_tests`. Destination identity without a
database is
`elixir/serviceradar_core/test/serviceradar/camera/archive_destination_test.exs`
on `//elixir/serviceradar_core:unit_tests`. The chart floor target is
`//helm/serviceradar:migrations_expected_version_test`. The synthetic provider
target is `//elixir/serviceradar_core_elx:provider_probe_test`.

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

An earlier combined sweep passes 436 targets, with 49 executed and two Swift
platform skips, in
[5c992fa7](https://carverauto.buildbuddy.io/invocation/5c992fa7-55d0-448b-a0eb-a4f02b23aea5).
All three Chromium seeking cases execute and pass in
[d031da58](https://carverauto.buildbuddy.io/invocation/d031da58-b919-470f-8725-45a7f853e0ab).
Five focused non-database targets passed in
[87633a67](https://carverauto.buildbuddy.io/invocation/87633a67-0e9a-4b03-b886-614b01200cec):
`//build/media:provider_probe_release_startup_test`,
`//elixir/serviceradar_core_elx:provider_probe_test`,
`//elixir/serviceradar_core_elx:unit_tests_serviceradar_core_elx`,
`//elixir/serviceradar_core:unit_tests_serviceradar_other`, and
`//helm/serviceradar:migrations_expected_version_test`. Those invocations
predate `8a5b83b0` and leave the guarded database scenarios unexecuted. A
non-database `make test` of this head finished in
[b0d27739](https://carverauto.buildbuddy.io/invocation/b0d27739-061d-4722-87e7-cd3a711b9958):
452 tests passed, 49 executed, and 2 skipped
(`//build/arrow_swift:ios_compile_test` and
`//build/arrow_swift:swift_regression_test`). The command excludes
`integration_test` and `acceptance_test`. Strict OpenSpec validation of this
change passed on `8a5b83b0`.
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
| Runtime repair | #5952 is merged at `b80465bfd6`. Negative suite `d607f3a0` on [f1ecf78d](https://carverauto.buildbuddy.io/invocation/f1ecf78d-80ec-42ce-9c17-de022207c6c8): 12 executed, 10 passed, 2 intended failures; observer, teardown, and release 0. Repair `a8590062`. Focused proof [3fa1b9f1](https://carverauto.buildbuddy.io/invocation/3fa1b9f1-8003-4245-b11c-e2c3ada4224c): 4 passed, 3 executed, formatter cached. Positive proof is draft #5954 `89d50a7f0d`: workflow [a74b1f9f](https://carverauto.buildbuddy.io/invocation/a74b1f9f-ee0d-450f-88a0-7d26eeed15ed) / child [7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a), 12 of 12 passed; suite, observer, teardown, and release 0; serial_6 256/0; serial_0 401/0 and 1 skip. GitHub rollup success, 18 checks | That runtime result does not execute archive block, binding, or worker database cases. Those remain pending on unpublished `8a5b83b0` |
| Historical block authority | Nine focused targets pass in [27053d5a](https://carverauto.buildbuddy.io/invocation/27053d5a-0d1c-45ae-9fda-2e9a412a4b16). Weakening descriptor continuity and count fails two manifest cases in [1c617b24](https://carverauto.buildbuddy.io/invocation/1c617b24-b950-4ef8-9bbf-58881832e059); restored source passes. The original upload deadline and migration `20261023160000` stay. Source is `test/integration/camera_recording_blocks_integration_test.exs` on `//elixir/serviceradar_core:integration_tests` | Guarded DB execution has not run on published `37da666884` or on `8a5b83b0`. Reservation, freeze, upload takeover, and expiry rollback stay untested. [Authority boundary](block-authority.md) |
| Immutable archive destination | Six focused targets pass in [f6c00dae](https://carverauto.buildbuddy.io/invocation/f6c00dae-99ab-4c6c-907d-a30a0d00ab4e). Allowing an unexpected field fails in [4c35622e](https://carverauto.buildbuddy.io/invocation/4c35622e-1396-4beb-bded-45596214e4ae); the parser is restored byte-for-byte. Bind-once and migration floor `20261023180000` stay. Database cases share `camera_recording_blocks_integration_test.exs`; canonical identity without a database is `test/serviceradar/camera/archive_destination_test.exs` on `//elixir/serviceradar_core:unit_tests` | Guarded DB execution of registration, bind-once, expiry rollback, and restrictive deletion has not run. [Binding contract](archive-binding.md) |
| Persisted descriptor | Four focused targets pass in [51ca7192](https://carverauto.buildbuddy.io/invocation/51ca7192-b501-4c2b-b3fe-85425239f51a): 207 unit cases, eight cached media cases, three freshly executed Chromium cases, and quality. Validation bypass [09d56db4](https://carverauto.buildbuddy.io/invocation/09d56db4-88d1-44bd-82f8-3f97f7cd66ea) and unsupported profile [b0368339](https://carverauto.buildbuddy.io/invocation/b0368339-fdfe-4fc6-8ec5-2b8ef3ecf7f7) fail the intended assertions | Remote byte verification and publication remain separate |
| Combined archive pass | Earlier [5c992fa7](https://carverauto.buildbuddy.io/invocation/5c992fa7-55d0-448b-a0eb-a4f02b23aea5): 436 targets pass, 49 execute, two Swift platform skips. Historical non-database [87633a67](https://carverauto.buildbuddy.io/invocation/87633a67-0e9a-4b03-b886-614b01200cec) passed five focused targets. Strict OpenSpec validation passed on `8a5b83b0`. Non-database `make test` [b0d27739](https://carverauto.buildbuddy.io/invocation/b0d27739-061d-4722-87e7-cd3a711b9958) finished: 452 passed, 49 executed, 2 Swift skips | Runtime DB proof is the separate #5954 run above. Archive block, binding, and worker DB bodies still must execute in sanctioned Core Integration after this head is published |
| Browser/media | [d031da58](https://carverauto.buildbuddy.io/invocation/d031da58-b919-470f-8725-45a7f853e0ab): three Chromium cases execute and pass; 16 provider and eight media cases reuse verified cache results | Product playback authorization and full authenticated deployment recovery |
| Provider/Cloud | Synthetic conditional-write and explicit-SSE diagnostics pass in [373125cd](https://carverauto.buildbuddy.io/invocation/373125cd-3ffc-4b55-9618-359fb128eb2c). Separate controls reject missing conditional headers, missing explicit encryption headers, and HTTP 200 completion errors. Both earlier live exercises were cleaned and absence/revocation rechecked. Exact cleanup stays under the 80/30 limits | Live readiness remains failed: default SSE was not confirmed, the new explicit-SSE and conditional-write checks are not live-tested, and policy/Object Lock remain untested. No third live probe |

[Detailed validation evidence](validation.md) retains the individual invocation
links, negative controls, and the limits of each proof. The existing live RTSP
path is operator-confirmed; no recording runtime has been deployed. The runtime
pass changes live relay ownership and closure even while recording is disabled.
Implementation choices live in [choices.md](choices.md).

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), and the current diff. This
draft is PR #5955. Published head is still `37da666884`; local head
`8a5b83b0` is not published. The runtime repair in this tree has positive
guarded CI on #5954 `89d50a7f0d`. Archive database lanes have not run.
Revalidate from Review after publication. Require guarded Core Integration
bodies, observer, teardown, and release to pass before any archive readiness
claim. Leave this PR draft. Do not merge, deploy, enable recording, provision
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
