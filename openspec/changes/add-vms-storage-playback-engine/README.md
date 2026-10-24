# VMS implementation handoff

## Current pickup

Foundation PR #5950 is merged. Runtime PR #5952 merged at its existing published
head `b80465bfd6a7eca5c7a298e2d34530a93ba8ae8b` with all 20 checks passing,
including guarded suite
[23177e08](https://carverauto.buildbuddy.io/invocation/23177e08-ea4b-45c8-b90e-8f9a24b11d1a)
(12/12, observer, teardown, and release 0). Its CI repair skips a nested
ownership transaction and promotes a plain-map user when actor is nil.

Follow-up draft PR #5954 is this repair. It published that production code plus two keeper
regressions at `158aa45657`. Guarded workflow
[f1ecf78d](https://carverauto.buildbuddy.io/invocation/f1ecf78d-80ec-42ce-9c17-de022207c6c8),
suite `d607f3a0-48a9-4299-9c01-2fdd395a6bb8`, executed 12/12: 10 passed and the
two new keepers failed. Observer, teardown, and release each returned 0. Broad
child
[9470b885](https://carverauto.buildbuddy.io/invocation/9470b885-eab0-49d4-8a20-3c5c0f3c5791)
passed 440 tests, with 2 skipped and 45 executed. GitHub's broad BazelCI check
succeeded. Those two failures are the intended code regressions.

`camera_ingest_ownership_integration_test.exs:250` (serial_6) returned
`{:ok, :handled}` where the keeper requires `{:error, :publication_rejected}`.
The callback receipt assertion passed. The later persisted display-name
assertion was not reached. `relay_session_manager_test.exs:83` (serial_0) opened
`%{user: user, actor: nil}` and returned `{:ok, %RelaySession{}}` where the
keeper requires `{:error, :not_found}`.

This revision restores unconditional `Ash.transact` in
`IngestOwnership.transaction/1`, keeps the typed atom/tuple domain-error
envelope and genuine Ash or database errors, and calls
`IngestOwnership.require_idle/2` immediately before `begin_idle_close` on the
default branch of `RelaySessionManager.fenced_close/5` under the profile lock
already held. Forced close, the soft viewer retain branch, legacy close, and
`begin_idle_close`'s epoch, token, captured relay, database time, and deadline
checks stay as they were. The plain-map user-to-actor fallback in
`read_ash_opts/2` is removed. The successful plain-map fixture supplies
`actor: user` beside `user`. Explicit `actor: nil` and every earlier assertion
stay. Positive database proof is the next Core Integration run on this same
draft PR. Readiness waits on that run's test bodies, observer, teardown, and
release. Recording stays disabled; this pass makes no runtime rollout or
archive-availability claim.

On head `a8590062edff8c3cd31418562c740bf4f854bd22`, `bazel test --config=remote` of
`//elixir/serviceradar_core:quality_check`,
`//build:integration_selection_equivalence_test`,
`//build/contracts:ci_heavy_gate_contract_test`, and
`//build:integration_selection_formatter_test` is invocation
[958221fc](https://carverauto.buildbuddy.io/invocation/958221fc-4bfe-4cfa-a52a-cd2e659fd2e0).
Bazel exited 0, executed 0 of 4, and reported four cached passes: quality 40.5s,
selection equivalence 40.9s, CI registration 27.4s, and selection formatter 0.9s.
`openspec validate add-vms-storage-playback-engine --strict` exited 0. These
checks do not run the guarded database bodies. Those stay untested until draft
PR #5954 is republished and Core Integration runs them.

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
| Durable ownership | The published runtime passes all 12 guarded DB targets in [23177e08](https://carverauto.buildbuddy.io/invocation/23177e08-ea4b-45c8-b90e-8f9a24b11d1a), with successful teardown and lease release. Head `158aa45657` then failed the two added keepers in [f1ecf78d](https://carverauto.buildbuddy.io/invocation/f1ecf78d-80ec-42ce-9c17-de022207c6c8) as recorded above | Repeat the guarded suite after the rollback and explicit-actor repair on draft PR #5954 |
| Recorder exclusion | Retained claims carry a separate recorder epoch, authenticated ingress ID, provisioned storage UUID and durable sequence counter. The published runtime's guarded suite passes | This revision restores unconditional ownership transactions. Repeat guarded validation; full authenticated deployment recovery remains separate |
| Provider access | Authenticated bounded ranges pass synthetic TLS loopback and CONNECT, response-status, object-identity, byte/header/deadline tests in [eedb3bc5](https://carverauto.buildbuddy.io/invocation/eedb3bc5-2d1a-41ed-8c64-ab3cd22d74a0). Deliberately accepting HTTP 200 failed the control | Actual endpoint capability/security probes, gateway authorization and measured request cost |
| Provider diagnostic | Eight executable protocol cases, release startup and quality pass after the opaque-receipt correction in [4a5dd038](https://carverauto.buildbuddy.io/invocation/4a5dd038-3a46-4e1d-a944-7a00b9aed942). The corrected second live exercise verified private access, roles, conditional reads, checksums, multipart completion/hash/cross-part range and abort. All temporary resources from both exercises were removed and absence rechecked | Both object types lack confirmed default SSE-S3, so the overall live result remains failed. Explicit SSE-S3, atomic no-overwrite, policy/Object Lock are untested. Broad provider keys are not recorder credentials. [Operator runbook](../../../build/media/provider-probe.md) |
| A/V diagnostic | Stream Doctor measured 3 ms control drift and 503 ms with a 500 ms injected delay; removing the delay made the fault assertion fail. Integrated target passes in [90139de1](https://carverauto.buildbuddy.io/invocation/90139de1-7abd-4d0d-8489-6fb40a65f9ea), using the verified cached result | Product audio support and RTSP fault coverage; [scope, bounds and fresh-run evidence](stream-doctor.md) |
| Foundation validation | [PR #5950](https://github.com/carverauto/serviceradar/pull/5950) merged with all 20 checks passing. Core Integration executes all 12 targets in [681ba460](https://carverauto.buildbuddy.io/invocation/681ba460-25c3-4cdb-af7a-94a14e169724), with successful fixture teardown and lease release | Does not establish the later runtime or archive contracts |
| Regression checkpoint | [5042be95](https://carverauto.buildbuddy.io/invocation/5042be95-4711-4ae6-853e-d266fbdacdd8) ran core quality, integration selection, and CI registration while the regression assertions were already in the tree, uncommitted. That invocation executed no database bodies. The full sweep passes 436 targets, with two executed and two Swift skips, in [01f10928](https://carverauto.buildbuddy.io/invocation/01f10928-9ba6-406f-a942-de1a663b340f), and also executed no database bodies for these keepers. Independent review found no defects in the two test extensions or prepared repair. Published execution is [f1ecf78d](https://carverauto.buildbuddy.io/invocation/f1ecf78d-80ec-42ce-9c17-de022207c6c8) | Positive database proof of this repair is still outstanding |

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

On published head `158aa45657`, the nested keeper handled a rejected inner write
and returned `{:ok, :handled}` after the callback receipt. The source-name
assertion did not run. The authorization keeper supplied a user and an explicit
nil actor and received an opened relay. Both assertions remain. This revision
returns those paths to an unconditional ownership transaction and an explicit
actor. The successful plain-map open supplies that actor beside the user.
Sanctioned PR Core Integration on draft PR #5954 is what proves the repaired
database bodies.

## Next agent prompt

Read [design.md](design.md), [tasks.md](tasks.md), and the current diff. The
narrow repair is already in this tree: unconditional ownership transactions,
the idle precheck on the locked default close branch, and no plain-map actor
fallback. Revalidate from Review. Require the final Core Integration bodies,
observer, teardown, and release to pass before any readiness claim. Leave PR
#5954 draft. Do not merge, deploy, enable recording, provision storage, or run
a third provider probe.

Carry the corrected published runtime into the dependent archive block/binding
and media feasibility branches through their review workflows. Then implement
immutable upload, verification and index publication. Releasing a current claim
must not grant a stale recorder publication rights. Manifest encoding establishes
metadata validity only; provider capability and deployment recovery remain
separate gates.
Update this handoff with concise measured evidence and the next incomplete gate;
keep the authoritative checklist in `tasks.md`. Every implementation PR uses
Treehouse and no-mistakes. Do not close #4913 or #4915 until their acceptance passes.
