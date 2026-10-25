# VMS validation evidence

[The handoff](README.md) owns the current pickup. These records retain the
measured scope of each checkpoint; earlier results do not execute later database
scenarios or establish hosted readiness.

## Evidence ledger

| Contract | Evidence | Remaining proof |
| --- | --- | --- |
| Scope and ownership | Planning PR #5945 merged; operator requested implementation | Runtime and Cloud acceptance remain unchecked |
| Existing live transport | Operator-confirmed agent/gateway/core live stream | Recorder lifetime, bounded fanout, archive and seek |
| Local spool and CMAF | Integrated RBE: eight media cases, provider protocol tests, core-elx quality and Chromium checks pass in [b4f35d58](https://carverauto.buildbuddy.io/invocation/b4f35d58-a326-4b32-98da-e80bfa728b3a). A recorder joining between keyframes waits for real in-band configuration and IDR; recovered fragments decode independently | Guarded recorder-claim execution, archive publication, rotation/reclamation and power-loss/deployment acceptance |
| Synthetic RTSP | The real Go receiver feeds Packaging and recovered Spool bytes; independent decoding matches the generated source. Three integrated cases and quality pass in [d9c4389a](https://carverauto.buildbuddy.io/invocation/d9c4389a-5306-494a-86c2-3ffb37c65e97). Forced TCP loss, fresh receiver clocks, RTP wrap, changed configuration and missing keyframes are exercised. A deliberate receiver timebase mutation fails | Authenticated agent/gateway/core recovery and automatic reconnect orchestration; the harness explicitly starts the fresh receiver |
| Browser fragment seek | Actual packaged and recovered bytes decode in Chromium MSE. Evicting the buffer between seeks forces ranges in order 0, 2, 1, 0 and produces the expected decoded colors. Three cases execute and pass with the shared descriptor in [4d2fc5f8](https://carverauto.buildbuddy.io/invocation/4d2fc5f8-1bbf-4c06-9bb7-b3e659052edf); the earlier wrong-color mutation fails | Product player/timeline integration and authorization; the fixture server does not establish the production gateway's access boundary |
| Recovery manifest | Version 1 metadata rejects open blocks, unbound object receipts, identity/path substitution, discontinuous fragment maps and excessive metadata allocations. Restored source passes 203 core-elx tests and quality in [6d3c95b2](https://carverauto.buildbuddy.io/invocation/6d3c95b2-1def-4657-a3b3-db4e25458a63). Permitting timing gaps fails in [79789014](https://carverauto.buildbuddy.io/invocation/79789014-5e3c-415e-96b8-63d8269ae90d); permitting excessive fragment counts fails in [ff07d967](https://carverauto.buildbuddy.io/invocation/ff07d967-e611-40a0-b4e5-0473f68c6875) | Remote byte/init/manifest verification and idempotent fenced publication; metadata alone establishes neither durability nor authorization |
| Durable ownership | Relay reservations, adoption, heartbeat, idle close and expiry cleanup use the persisted owner fence. Five remote targets pass in [d6e1ddea](https://carverauto.buildbuddy.io/invocation/d6e1ddea-ac90-485d-87c5-85b5dccc0979), including 191 core-elx tests, 1,014 core tests, quality checks and executable integration selection. Restoring the old close behavior fails the retained-consumer regression | Merged runtime suite [23177e08](https://carverauto.buildbuddy.io/invocation/23177e08-ea4b-45c8-b90e-8f9a24b11d1a) passed 12/12. Head `158aa45657` then failed the two added keepers in suite `d607f3a0`. Positive proof of repair `a8590062` is merged #5954 head `89d50a7f0d` (merge `9c3388359ad9a5ef079c2aa1b1ae7a0e7100f692`): workflow [a74b1f9f](https://carverauto.buildbuddy.io/invocation/a74b1f9f-ee0d-450f-88a0-7d26eeed15ed), child [7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a), 12 of 12 passed; suite, observer, teardown, and release 0; serial_6 256/0; serial_0 401/0 and 1 skip. GitHub rollup success, 18 checks. That run does not execute archive database cases |
| Recorder exclusion | Retained claims carry a separate recorder epoch, authenticated ingress ID, provisioned storage UUID and durable sequence counter. The first claim pass passes nine focused RBE checks in [c9dcd2fe](https://carverauto.buildbuddy.io/invocation/c9dcd2fe-fde4-43d6-a328-b8b344ec4be7). The relay-expiry correction passes core quality, core-elx units and integration selection in [bd3031f3](https://carverauto.buildbuddy.io/invocation/bd3031f3-d0a2-49f1-a9e6-c60156d8a4f9) | The exact-parent guarded result below passes these registered cases; deployment recovery remains separate |
| Provider access | Authenticated bounded ranges pass real TLS/CONNECT, response-status, object-identity, byte/header/deadline tests in [eedb3bc5](https://carverauto.buildbuddy.io/invocation/eedb3bc5-2d1a-41ed-8c64-ab3cd22d74a0). Deliberately accepting HTTP 200 failed the control | Actual endpoint capability/security probes, gateway authorization and measured request cost |
| Historical block authority | Nine focused targets pass in [27053d5a](https://carverauto.buildbuddy.io/invocation/27053d5a-0d1c-45ae-9fda-2e9a412a4b16), including 206 core-elx cases, eight media cases, quality, integration selection/topology and Helm migration checks. Weakening the shared descriptor bounds fails two manifest cases in [1c617b24](https://carverauto.buildbuddy.io/invocation/1c617b24-b950-4ef8-9bbf-58881832e059); restored source passes. The database file is `elixir/serviceradar_core/test/integration/camera_recording_blocks_integration_test.exs` on `//elixir/serviceradar_core:integration_tests` | Published `bf480fdcb1` executed this file in [7901e502](https://carverauto.buildbuddy.io/invocation/7901e502-43b8-4fbf-9a2e-3d3cbc29a690). `integration_tests_serial_2` failed only at line 204. The later exact-parent guarded result below re-executes and passes the corrected expectation. Immutable upload and publication remain unimplemented. [Authority boundary](block-authority.md) |
| Immutable archive destination | Six focused targets pass in [f6c00dae](https://carverauto.buildbuddy.io/invocation/f6c00dae-99ab-4c6c-907d-a30a0d00ab4e), including the owning unit shard (1,022 executed, one skipped, 555 excluded), quality, registration, selection and Helm migration checks. Allowing an unexpected input field fails the contract case in [4c35622e](https://carverauto.buildbuddy.io/invocation/4c35622e-1396-4beb-bded-45596214e4ae); the parser is restored byte-for-byte and generator replay is identical. Canonical identity without a database is `test/serviceradar/camera/archive_destination_test.exs` on `//elixir/serviceradar_core:unit_tests` | On `bf480fdcb1`, the referenced delete was rejected as `:restrict_violation`, pg_code `23001`, constraint `camera_recording_blocks_archive_binding_id_fkey`. The test expected `:foreign_key_violation`, so that test did not reach its later release and replacement assertions. The later exact-parent guarded result below passes the corrected expectation and subsequent assertions. Qualification and actual storage operations remain absent. [Binding contract](archive-binding.md) |
| Persisted-descriptor manifest | Four focused targets pass in [51ca7192](https://carverauto.buildbuddy.io/invocation/51ca7192-b501-4c2b-b3fe-85425239f51a): 207 unit cases, eight cached media cases, three freshly executed Chromium cases and quality. Fixed independently calculated hashes pin v1 bytes and object keys. Bypassing descriptor validation fails in [09d56db4](https://carverauto.buildbuddy.io/invocation/09d56db4-88d1-44bd-82f8-3f97f7cd66ea); accepting an unsupported profile fails in [b0368339](https://carverauto.buildbuddy.io/invocation/b0368339-fdfe-4fc6-8ec5-2b8ef3ecf7f7). Production mutations are restored byte-for-byte and all prior assertions remain | Remote receipts, byte verification and publication remain separate work |
| Provider diagnostic | Sixteen synthetic TLS protocol cases, release startup and quality pass in [373125cd](https://carverauto.buildbuddy.io/invocation/373125cd-3ffc-4b55-9618-359fb128eb2c). Separate negative controls reject missing conditional headers, missing explicit encryption headers and HTTP 200 completion errors. The earlier second live exercise verified private access, roles, conditional reads, checksums, multipart completion/hash/cross-part range and abort; all temporary resources from both exercises were removed and absence rechecked | The live result remains failed because default SSE-S3 was not confirmed. Explicit SSE-S3 and atomic no-overwrite now have synthetic diagnostic coverage but remain untested against the provider. Policy/Object Lock are untested; broad provider keys are not recorder credentials. [Operator runbook](../../../build/media/provider-probe.md) |
| A/V diagnostic | Stream Doctor measured 3 ms control drift and 503 ms with a 500 ms injected delay; removing the delay made the fault assertion fail. Integrated target passes in [90139de1](https://carverauto.buildbuddy.io/invocation/90139de1-7abd-4d0d-8489-6fb40a65f9ea), using the verified cached result | Product audio support and RTSP fault coverage; [scope, bounds and fresh-run evidence](stream-doctor.md) |
| Foundation validation | [PR #5950](https://github.com/carverauto/serviceradar/pull/5950) merged with all 20 checks passing. The final fix passes 199 core-elx and six media tests in [edd24097](https://carverauto.buildbuddy.io/invocation/edd24097-fb2c-4898-ad3e-daae1bf87952). Core Integration executes all 12 targets in [681ba460](https://carverauto.buildbuddy.io/invocation/681ba460-25c3-4cdb-af7a-94a14e169724), with successful fixture teardown and lease release | This PR does not contain the runtime claim/Worker or historical block cases |
| Combined runtime sweep | After replaying all 19 runtime commits onto the reviewed foundation with equivalent patches, `make test` passes 436 targets, with two Swift platform skips, in [bbf2e694](https://carverauto.buildbuddy.io/invocation/bbf2e694-c755-43bf-b2ee-d434aebeb471). Fifty targets execute; the remainder use verified cache results. Strict OpenSpec validation also passes | The unit sweep does not execute database integration bodies |
| Combined archive sweep | With runtime close/retry fixes, retained block authority, provider diagnostics, immutable archive bindings and descriptor encoding, an earlier `make test` passes 436 targets, with two Swift platform skips, in [5c992fa7](https://carverauto.buildbuddy.io/invocation/5c992fa7-55d0-448b-a0eb-a4f02b23aea5). Forty-nine targets execute; the remainder use verified cache results. Three Chromium cases execute in [d031da58](https://carverauto.buildbuddy.io/invocation/d031da58-b919-470f-8725-45a7f853e0ab), which also reuses the passing provider/media results. Historical non-database proof [87633a67](https://carverauto.buildbuddy.io/invocation/87633a67-0e9a-4b03-b886-614b01200cec) executed five targets and all passed: release startup, `provider_probe_test`, `unit_tests_serviceradar_core_elx`, `unit_tests_serviceradar_other`, and `migrations_expected_version_test`. Strict OpenSpec validation of this change passed on `8a5b83b0`. Non-database `make test` of `8a5b83b0` finished in [b0d27739](https://carverauto.buildbuddy.io/invocation/b0d27739-061d-4722-87e7-cd3a711b9958): 452 passed, 49 executed, and 2 skipped (`ios_compile_test`, `swift_regression_test`). It excludes integration and acceptance tests. The earlier replay of the seven archive commits onto runtime head `796882e59b` preserved their source | This draft merges staging `9c3388359ad9a5ef079c2aa1b1ae7a0e7100f692`, which contains merged #5952 and merged #5954, and imports repair `a8590062`. Published `bf480fdcb1` ran Core Integration [7901e502](https://carverauto.buildbuddy.io/invocation/7901e502-43b8-4fbf-9a2e-3d3cbc29a690): 12 targets executed once, uncached, 11 passed, and `integration_tests_serial_2` failed the stale `:foreign_key_violation` expectation. The later exact-parent guarded result below passes the corrected expectation |
| Media feasibility sweep | Before the logical byte-cost experiment, [9f994c74](https://carverauto.buildbuddy.io/invocation/9f994c74-4a00-406f-af4a-59d1b819d6b7) passed 438 targets, with three executed and two Swift skips. [Codec](codec-capabilities.md) and [RTCP clock](clock-capabilities.md) records retain their focused checks and failing controls | Later provisional-parent sweep is recorded below. Production audio/HEVC and trusted UTC remain unproved |
| Logical block bytes | [4a3336d1](https://carverauto.buildbuddy.io/invocation/4a3336d1-0c98-4b2d-ab91-168b55c83c50) executes nine media tests and quality. Omitting an append fails independent decoded-frame conservation. [Measurements and bounds](block-byte-costs.md) | Physical allocation, database/WAL, cache, provider requests and deployment capacity remain unmeasured |
| Reconciled focused media | At merge head `52adc0c3b3089b9ec9ed28d28f77b8d163be7252`, [d68c4a96](https://carverauto.buildbuddy.io/invocation/d68c4a96-71a6-420b-ad50-546645c7f8ee) executes all nine targets uncached: 210 core-elx units, nine media/byte-cost cases, three RTSP cases, one native codec case, the RTCP test with both source epochs, three seek and three codec Chromium cases, plus core and core-elx quality. All pass. Chromium records HEVC as unsupported | Provisional archive parent `8a5b83b0`; no database bodies execute. Final archive parent is now merged; this row retains its earlier source scope. Production audio/HEVC and trusted UTC remain unproved |
| Provisional media full sweep | At clean head `6e78ec0c6c708e58dfd23d24b809fda19da2fe43`, `make test` passes [4e854012](https://carverauto.buildbuddy.io/invocation/4e854012-b0ee-48fa-974c-393b960e4b36): 454 targets pass, 13 execute and 441 use cache; `ios_compile_test` and `swift_regression_test` are the two platform skips. Initial and final HEAD match; the worktree stays clean | Ordinary RBE does not execute guarded DB bodies. Final archive parent is now merged; combined-tree proof is recorded below |

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

The foundation ownership database lane has passed in PR #5950. The first runtime
Core Integration run, workflow
[84571f63](https://carverauto.buildbuddy.io/invocation/84571f63-a8ae-4357-9170-92286f5633d6)
child `c343a2e3`, executed 12 targets: 10 passed, and `serial_0` and `serial_1`
failed in the relay manager and lifecycle suites. The repair keeps a refusal
inside the parent transaction so an active consumer stays retained, and core
quality passes in
[37fc8ef4](https://carverauto.buildbuddy.io/invocation/37fc8ef4-4bb1-431d-a549-aa79e16cdd4c).
#5952 later merged at `b80465bfd6` after suite
[23177e08](https://carverauto.buildbuddy.io/invocation/23177e08-ea4b-45c8-b90e-8f9a24b11d1a)
executed 12 of 12. Follow-up head `158aa45657` failed the two added keepers in
suite `d607f3a0` on
[f1ecf78d](https://carverauto.buildbuddy.io/invocation/f1ecf78d-80ec-42ce-9c17-de022207c6c8):
12 executed, 10 passed, 2 intended failures; observer, teardown, and release
each returned 0. Repair `a8590062` restores unconditional ownership transactions,
prechecks idle under the existing close lock, and removes the plain-map actor
fallback. Focused proof
[3fa1b9f1](https://carverauto.buildbuddy.io/invocation/3fa1b9f1-8003-4245-b11c-e2c3ada4224c)
passed four targets, three executed, with the formatter cached. Positive
runtime database proof is merged #5954 head `89d50a7f0d` (merge
`9c3388359ad9a5ef079c2aa1b1ae7a0e7100f692`): workflow
[a74b1f9f](https://carverauto.buildbuddy.io/invocation/a74b1f9f-ee0d-450f-88a0-7d26eeed15ed),
child
[7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a),
executed 12 of 12 and all passed. Suite, observer, teardown, and release each
returned 0. `integration_tests_serial_6` finished 256 tests with 0 failures.
`integration_tests_serial_0` finished 401 tests with 0 failures and 1 skip.
GitHub's check rollup for that head is success across 18 checks. That result
covers the imported runtime correction. The merged runtime handoff also records
broad child
[9470b885](https://carverauto.buildbuddy.io/invocation/9470b885-eab0-49d4-8a20-3c5c0f3c5791)
(440 passed, 2 skipped, 45 executed) on the negative suite, cached non-database
recheck
[958221fc](https://carverauto.buildbuddy.io/invocation/958221fc-4bfe-4cfa-a52a-cd2e659fd2e0)
(4 cached passes, 0 executed) on repair `a8590062`, earlier browser proof
[468a68df](https://carverauto.buildbuddy.io/invocation/468a68df-accb-49c7-b508-f171dfc3b10a),
earlier provider diagnostic
[4a5dd038](https://carverauto.buildbuddy.io/invocation/4a5dd038-3a46-4e1d-a944-7a00b9aed942),
uncommitted regression checkpoint
[5042be95](https://carverauto.buildbuddy.io/invocation/5042be95-4711-4ae6-853e-d266fbdacdd8)
with no database bodies, and sweep
[01f10928](https://carverauto.buildbuddy.io/invocation/01f10928-9ba6-406f-a942-de1a663b340f)
(436 passed, two executed, two Swift skips, no keeper database bodies). Later
rows above supersede the browser and provider invocations. Published #5955 head
`bf480fdcb1`
ran workflow
[7901e502](https://carverauto.buildbuddy.io/invocation/7901e502-43b8-4fbf-9a2e-3d3cbc29a690),
suite `24917750-4926-455c-9a40-c07e00291d5d`. All 12 targets executed once,
uncached, and 11 passed. `integration_tests_serial_2` failed only at
`elixir/serviceradar_core/test/integration/camera_recording_blocks_integration_test.exs:204`.
The referenced delete was rejected with `:restrict_violation`, pg_code `23001`,
and constraint `camera_recording_blocks_archive_binding_id_fkey`. The test
expected `:foreign_key_violation`. Migration `20261023180000` keeps
`on_delete: :restrict`. This tree expects that exact code, pg_code, and
constraint. Release and replacement assertions after the old expectation did
not run on `bf480fdcb1`; the exact-parent rerun below passes them.
`integration_tests_serial_3` finished 329 tests, 0 failures, and 8 other cases excluded.
All 3 cases in `elixir/serviceradar_core/test/integration/camera_recording_worker_integration_test.exs` ran and passed.
Suite returned 3. Observer, teardown, and release each returned 0. Both files
are owned by `//elixir/serviceradar_core:integration_tests`. Earlier workflows
[b69c483d](https://carverauto.buildbuddy.io/invocation/b69c483d-c501-40f9-9c37-4576d286f037),
[2f02bddf](https://carverauto.buildbuddy.io/invocation/2f02bddf-6744-4eca-a7ff-5e89c9796d19),
and
[36f56b1b](https://carverauto.buildbuddy.io/invocation/36f56b1b-1d45-4eb2-8d17-2c4ee9807a6c)
stopped on the README merge conflict before any test body. Descriptor encoding is
`elixir/serviceradar_core_elx/test/serviceradar_core_elx/camera_recording/manifest_test.exs`
on `//elixir/serviceradar_core_elx:unit_tests`. The synthetic provider target is
`//elixir/serviceradar_core_elx:provider_probe_test`, and the chart floor target
is `//helm/serviceradar:migrations_expected_version_test`. Non-database `make test`
[b0d27739](https://carverauto.buildbuddy.io/invocation/b0d27739-061d-4722-87e7-cd3a711b9958)
finished on `8a5b83b0`: 452 passed, 49 executed, and 2 skipped
(`//build/arrow_swift:ios_compile_test` and
`//build/arrow_swift:swift_regression_test`). It excludes integration and
acceptance tests. Strict OpenSpec validation passed on `8a5b83b0`. Historical
non-database proof
[87633a67](https://carverauto.buildbuddy.io/invocation/87633a67-0e9a-4b03-b886-614b01200cec)
is an earlier five-target execution, separate from this sweep.
The owner and consumer tables are additive, but the runtime pass changes live
relay ownership and closure. It has not been deployed.


## Accepted archive parent

Archive PR #5955 at `72a81f96c4dfaa3d801b95dbab5150423f9a9cf5` passes all 19
GitHub checks. Workflow [223caaf4](https://carverauto.buildbuddy.io/invocation/223caaf4-2b5a-4111-aed6-e91f10d1cd81)
checks out that exact merged head; suite
[0df082fa](https://carverauto.buildbuddy.io/invocation/0df082fa-1895-4d75-be6a-8e90aaa60d0f)
executes 12/12 targets once, uncached, and passes. Serial_2 has 430 tests, zero
failures and no exclusions. Serial_3 has 329 tests, zero failures, with all three
worker cases included and eight other cases excluded. Case inclusion is based on
exact source, registration, tags and lane results; logs do not trace every case.
Suite, observer, teardown and release statuses are all zero; the matching lease
was released, with 335 observer samples. The earlier prepublication Test exception
is retained in the proxy record; final guarded CI was not waived. The workflow
finished at `2026-10-24T02:40:37Z`. The passing block lane includes all six block
cases. On published `bf480fdcb1d52dc6fe527f8b6fe6802af674510c`, the failing case
was `RecordingBlocksIntegrationTest`'s "binding requires exact authority and
cannot replace the retained destination": deletion was blocked with
`:restrict_violation`, SQLSTATE `23001`, and constraint
`camera_recording_blocks_archive_binding_id_fkey`, and the later assertions in
that case did not run. #5955 later merged at
`88c5a324793e4cff4155378c29fc29ec5949da6b`.

This is proof of the archive parent, not later upload-intent database cases.
The media reconciliation at `74788a15` merges this exact parent and retains the
three experiment commits. At that merge the 14 experiment files match the
pre-merge author byte-for-byte, and the media patch ID is
`ffa7689d1b13105878ce0badd7e7e08294ca96ee`. The deadline repair later changes two
build files; that correction is recorded below.

## Immutable upload intent checkpoint

The shared object-key owner preserves existing manifest bytes and key assertions.
Five focused targets execute and pass in
[d1b15dd3](https://carverauto.buildbuddy.io/invocation/d1b15dd3-e1e0-46fe-a456-578892a00b44):
core/core-elx quality, core-elx units, registration and the chart migration floor.
That command exits 1 because a sixth selection target was mistyped; it is not a
successful overall command. The correctly named
`//build:integration_selection_equivalence_test` executes and passes in
[8ebcf063](https://carverauto.buildbuddy.io/invocation/8ebcf063-6376-4580-98f5-9ef8d9584da8).
The required `make test` sweep
[6602a14e](https://carverauto.buildbuddy.io/invocation/6602a14e-ee01-4cab-b44f-763f118c2d81)
exits zero in 506.603 seconds: 452 targets pass, 55 execute, 397 are cached, and
2 Swift targets are skipped (`ios_compile_test`, `swift_regression_test`). The
sweep includes existing media/RTSP, synthetic provider diagnostics, core/web
units and release image contracts. It excludes integration and acceptance tests.
These commands test the intent working tree; subsequent edits only update its
evidence documents. The generated schema target and both app formatters also
complete successfully. Strict OpenSpec validation and diff checks pass.

Independent source/test review finds no remaining issue after replacing an
unreliable 50 ms lease acquisition with the established 2-second expiry pattern.
All existing assertions remain intact. New retry checks compare persisted fields,
and the conflicting-content case preserves the original row after refusal.
No new database body execution, browser acceptance, live provider check or runtime
rollout is claimed here. At this checkpoint, all five new guarded cases still
required that branch's sanctioned PR CI, including migration, lane inclusion and
fixture cleanup. Merging #5960 does not add a database result to this record, and
this media draft does not rerun those cases.

## Final media reconciliation

Merge `74788a15db84c478646afda4d3995f5edd784031` retains media parent
`2f8ba47a4d32b81d47e3a269b7295ebc0def75c7` and exact archive parent
`72a81f96c4dfaa3d801b95dbab5150423f9a9cf5`. Only README and validation conflicts
required manual resolution. At that merge, the 14-file media test/build delta
matches the pre-merge author. Production camera modules and receiver source
have no delta against the archive parent. The later deadline repair changes two
of those build files; that correction is recorded below. At this reconciliation
the staging comparison still included archive production ancestry because #5955
had not merged. Current publication status is in the [handoff](README.md).

Focused [230c21ab](https://carverauto.buildbuddy.io/invocation/230c21ab-2b6c-4419-b177-73a150ee633c)
ran on the resolved merge working tree before its commit, with the same source,
tests and build definitions as `74788a15`. All nine targets executed uncached and
passed: 210 core-elx units, nine media/byte-cost cases, three RTSP cases, one native
codec case, both RTCP source epochs, three Chromium seek cases, three Chromium
codec cases and core/core-elx quality. Native audio offsets and logical byte
measurements remain as documented; pinned Chromium reports HEVC unsupported.

Full `make test` [1a996f98](https://carverauto.buildbuddy.io/invocation/1a996f98-1d3e-482c-90c4-a432e45ef6f2)
began and ended clean at `74788a15`: 454 targets passed, 14 executed and 440 used
cache, with two platform skips (`ios_compile_test`, `swift_regression_test`).
Elapsed time was 223.947 seconds. The command excludes integration and acceptance
tests; the browser targets were explicitly executed in the focused run. The
following evidence checkpoint changes README and validation only, so executable
source, tests and build definitions remain those tested. Strict OpenSpec and
diff checks pass. No media-branch guarded DB rerun, deployment or provider probe
is claimed; the matching archive-parent guarded result is recorded above.

Review found no new architecture choice in this reconciliation: it preserves
the approved experiment scope and existing choices. Tasks 0.4 and 0.6 remain open.
Upload-intent #5960 later merged at `29b30748dfe212ba0672bd2cd53342303ecbbc26`.
Its non-database checkpoint stays in the section above and remains source-scoped:
it does not establish wire operations, provider qualification or availability
publication, and this media draft does not rerun its guarded database cases.

## Fixture action deadline correction

Review of `8e4fd1cc` found that Bazel 9.2.0 drops the plain `timeout` execution
requirement through its [execution-info key filter](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/packages/TargetUtils.java#L263-L289).
The earlier positive media runs did not prove the claimed 120-second action
deadline. Both existing fixture targets now use BuildBuddy's documented
[`default-timeout` and `termination-grace-period` properties](https://github.com/buildbuddy-io/buildbuddy/blob/v2.318.0/docs/rbe-platforms.md#execution-timeout-properties):
120 seconds with zero grace. The ignored requirement is removed. This changes
only two build files; all fixture source, test assertions and tolerances remain
byte-identical to `8e4fd1cc`.

A temporary 130-second sleep in the declared codec generator printed its entry
marker and caused `CameraBrowserFixture` to fail explicitly with a timeout after
120.01 seconds; Bazel returned 1. The actual target-level bound stayed at 120
seconds. The complete client log and temporary diff are retained privately;
the invocation UUID was unavailable because build INFO output was filtered. An
earlier 1 ms attempt only timed out dependency-copy actions and is not accepted
as generator proof. No transient delay or extra test seam is committed.

After restoring the generator byte-for-byte,
[aabf88b7](https://carverauto.buildbuddy.io/invocation/aabf88b7-c9af-4d0e-825a-ecc6b5ccfb39)
executes all nine focused targets uncached and passes in 52.139 seconds: core-elx
units, media, RTSP, native codec, RTCP, both Chromium suites and both quality
checks. Their assertions and case inventory are unchanged from `230c21ab`.
Both declared fixture targets build successfully under the
replacement deadline. The earlier `1a996f98` result retains its pre-repair scope.

Full `make test`
[1c64bc77](https://carverauto.buildbuddy.io/invocation/1c64bc77-528f-4b2e-97aa-3e75c8e6dbf0)
starts and ends clean at repair `43c32a8cca312b785664858b19352f43b0692aa6`.
It passes 454 targets in 40.836 seconds: one executes, 453 use cache, and the two
Swift platform targets are skipped. The fresh target is
`ci_heavy_gate_contract_test`; media/browser/quality were freshly executed in
`aabf88b7` above. No integration bodies execute in this command. This following
README/validation checkpoint changes no tested source, build definition or
assertion. Strict OpenSpec and diff checks pass; required media PR CI remains.

## Merged parent evidence before dispatch work

Upload-intent #5960 merged at `29b30748dfe212ba0672bd2cd53342303ecbbc26`.
Its guarded workflow
[aa0dd0ca](https://carverauto.buildbuddy.io/invocation/aa0dd0ca-22f9-425b-99f4-9a049ef9f469)
and suite
[853e4601](https://carverauto.buildbuddy.io/invocation/853e4601-ef2c-419e-b9c3-cfc8349da412)
pass all 12 targets uncached. The owning serial lane runs 260 tests, with no
failures or exclusions, including all five intent cases. Suite, observer,
teardown and lease release return zero. This final CI follows the explicitly
approved prepublication Test exception; it does not erase that exception.

Media #5959 merged at `ad424ac6b794f73abddd02e51c560a77d9af10fa` from
`10a70e71c39f91fcb30fa90389c6fc0130840213` after all 19 GitHub checks passed,
without a Test or CI exception. Final broad suite
[fcb92879](https://carverauto.buildbuddy.io/invocation/fcb92879-933e-43f6-b0bc-c30579f21371)
passes 442 targets (17 fresh, 425 cached) with two platform skips. Guarded core
[f78de788](https://carverauto.buildbuddy.io/invocation/f78de788-748e-4f40-afe1-9c10965c9069)
passes 12 fresh targets; guarded web
[95718b50](https://carverauto.buildbuddy.io/invocation/95718b50-7cd7-4caf-ae44-3671a8d4ad4d)
passes seven fresh targets. Both workflows have successful suite, observer,
teardown and release commands. The final supported timeout negative control
[d2dcf987](https://carverauto.buildbuddy.io/invocation/d2dcf987-efd2-44b4-a113-586266d51edd)
enters the injected delay and fails after 120.01 seconds; restored-source positive
[74da0d14](https://carverauto.buildbuddy.io/invocation/74da0d14-a881-4590-89f5-96d655e6406a)
passes. No temporary delay is retained.

These parent results establish their own code only. New dispatch tests require
fresh guarded CI on the dispatch candidate. Recording remains disabled and no
deployment or provider probe is implied.

## Bounded dispatch checkpoint

The schema is generated with pinned AshPostgres and migration
`20261024070623`; the Helm migration floor matches. Independent review confirmed
the restrictive/unique intent reference, atomic one-way observations and late
observation constraints. It found an inconsistent missing-ID error and a conflict
digest assertion that admitted nil. Both are corrected: all observation/marking
entry points return the same domain error, and tests require the exact fixed
conflict digest plus a non-null digest in the concurrent case. Every pre-existing
assertion remains.

Fresh focused run
[bb9e4ddf](https://carverauto.buildbuddy.io/invocation/bb9e4ddf-ab0f-430c-9cdf-c3e56589e1cc)
passes all six targets uncached in 124.013 seconds: core format/Credo, integration
selection equivalence, shard topology with its two refusal controls, and Helm
migration floor. This compiles/selects the new integration cases; it does not
execute their database bodies. Strict OpenSpec validation and changed handoff
link/ASCII checks pass. The repaired-head guarded result below supplies the
separate database execution evidence.

Full `make test`
[a79ef08e](https://carverauto.buildbuddy.io/invocation/a79ef08e-f310-4d4e-80a0-c49d19e171b0)
passes 459 targets: 59 execute, 400 use cache, and the two Swift platform targets
are skipped. That run predates the `:id` repair below, so it is not evidence for
the current head. Integration/acceptance bodies are excluded by that command.
Neither this result nor selection equivalence proves the 12 new guarded database
cases. No deployment, provider call, qualification or availability is claimed.

Draft publication was approved so BazelCI Core Integration could be the first
execution of these twelve database scenarios. The approval is prepublication
only. It does not waive final CI, and it does not count a failed run as a pass.

Core Integration then ran at the pre-repair head. Invocation
[ed8fbb26](https://carverauto.buildbuddy.io/invocation/ed8fbb26-da5c-4141-a0aa-4723e8934ec6)
failed only `//elixir/serviceradar_core:integration_tests_serial_6`: 297 tests,
10 failures and eight unrelated exclusions. Each failure is
`Ash.Error.Invalid.NoSuchInput` on `ArchiveUploadDispatch` action `:prepare`,
input `:id`. The other 11 targets
passed. The suite exit status was 3; observer, teardown and lease release each
returned 0. The complete dispatch contract had not passed validation. This does
not mean every new case failed: the missing-ID case and the original-cap rollback
case were outside those ten failures.

The repair stops accepting and supplying `:id`. `Ash.UUID.generate/0` on
`uuid_primary_key :id` is the only id source, and [the dispatch contract](upload-dispatch.md)
owns that rule. Remote `//elixir/serviceradar_core:quality_check` passed in
[dcebd82e](https://carverauto.buildbuddy.io/invocation/dcebd82e-593d-42df-b7bc-f177ff445d45).
The repair changes only those two production input lines. Every existing and new
test assertion is unchanged.

### Repaired-head guarded result

Head `fb920deb97ba3e026d952001ff00d31f43479561` passes all 20 PR checks.
Core Integration workflow
[158effba](https://carverauto.buildbuddy.io/invocation/158effba-7319-4d04-afe8-7dd8a1bcf341)
executes all 12 targets once, uncached, in child invocation
[6718f18c](https://carverauto.buildbuddy.io/invocation/6718f18c-7ae1-405b-8c55-86319ec01534).
All pass. The measured lifecycle reports `suite_status=0`, `observer_status=0`,
`teardown_status=0` and `release_status=0`.

The actual target test logs report:

- `integration_tests_serial_6`: 297 tests, zero failures, eight excluded.
  This lane owns `Camera.ArchiveUploadsIntegrationTest`, including all eleven
  new dispatch cases and its five existing upload-intent cases.
- `integration_tests_serial_3`: 471 tests, zero failures, no exclusions.
  This lane owns `Camera.RecordingBlocksIntegrationTest`, including the new
  original-cap rollback case and all six existing cases.

Bazel source ownership and the modules' `:integration` tags establish inclusion;
the logs report aggregate results, not individual case traces. The serial-6 log
includes `:integration` and `:requires_app`, excluding `:test`, `:external`,
`:cluster`, `:large_ingestion` and `:benchmark`; none of the changed cases has an
excluded tag. The twelve new database cases therefore execute with every
pre-existing assertion preserved. No failed CI result is waived.

The same head's [Web-NG DB workflow](https://carverauto.buildbuddy.io/invocation/526d92ad-b69e-4927-a3a2-6344bc69e5a7)
passes all seven targets uncached, with suite, observer, teardown and release
statuses all zero. [Main CI](https://carverauto.buildbuddy.io/invocation/3619d54e-cf9b-45e5-9789-3fcbbff634c2)
also passes: its initial sweep reports 442 passed and two platform skips, with
41 of 444 targets executed; its later suites report 17 passed (four executed)
and 71 passed (all cached). These are distinct reported suites, not a deduplicated
test count.

No-mistakes reaches `checks-passed` for that head. Its Test phase retains the
approved prepublication-only exception because it did not run the guarded
database itself; the fresh final CI above supplies that proof. This documentation
follow-up preserves the validated runtime and tests. It does not establish
provider qualification, storage availability or deployment acceptance.

### Merged dispatch and Cloud planning checkpoints

Dispatch PR #5966 merged at `df8a8fe2e20d5f3220483200e27fcc74b6872e14`.
Its final head `831e88938939a2f99364b13f711ed2aaccc10937` passed all 20 checks.
Final [Core Integration](https://carverauto.buildbuddy.io/invocation/d85a7307-4e47-42de-a019-9e95d1480221)
passed all 12 targets uncached in child
`a872ed95-53f7-4e8e-899b-deea8643599c`. Final
[Web-NG DB](https://carverauto.buildbuddy.io/invocation/6aafb922-cd02-48f5-a64c-eea09120cdd6)
passed all seven targets uncached. Both workflows reported suite, observer,
teardown and lease-release statuses of zero.
[Main CI](https://carverauto.buildbuddy.io/invocation/6779cda7-cf84-425c-ac87-c340921516dd)
reported 442 passed with two platform skips, then separate suites of 17 and 71
passed; these are not a deduplicated total. No-mistakes run
`01M5PM4P4G62FAZY1XF3VB5MW9` reached `checks-passed` before the merge.

Cloud planning PR #185 merged at `5a46b36e51e2428097f6202ce2f16678e9491780`
after all five checks passed on `2d25e97ac3fa3c6d114f95fa74dbeb67a76ee8f8`.
It adds a planning contract, not provider provisioning, credential installation
or an implemented readiness handshake. Its runtime tasks remain incomplete.

## Qualification report protocol

The [report parser](qualification-report.md) is metadata-only. Six new synthetic
cases own canonical report/destination hashes, exact JSON escaping, identity and
credential rotation, separate attestation/denial states, exact inventories and
bounded malformed input. The fixed digest was independently calculated from
invented input using sorted compact JSON and SHA-256. No existing test assertion
was changed. The source-disposition inventory includes the new file.

Focused remote run
[0384417a](https://carverauto.buildbuddy.io/invocation/0384417a-38fb-4254-903b-f55b692908fe)
passed `unit_tests_serviceradar_other`, reporting 1,038 tests, zero failures, one
skip and 565 exclusions. Bazel source ownership and the new module's lack of
excluded tags establish inclusion of all six new cases. Core quality failed
only because one new long test call needed formatting; Credo found no issues.
The repair wraps that call without changing values or assertions. Fresh
[b7e41fcf](https://carverauto.buildbuddy.io/invocation/b7e41fcf-2cca-48f4-8781-005bcfcc6f94)
then passed the remote format/Credo target uncached.

The local source-registration contract reports 65 tests, zero failures and one
skip. Strict OpenSpec validation, changed-document ASCII/relative-link checks and
`git diff --check` pass. Independent code and Cloud-contract reviews found no
blocking issues after exact JSON escaping and equal-sized wrong-inventory
coverage were added. These checks establish a report format, not the truth of
provider observations, an authenticated readiness handshake or deployment
acceptance. No provider call, live probe, database migration or rollout ran.

Full remote `make test`
[fc10c612](https://carverauto.buildbuddy.io/invocation/fc10c612-76b1-47e6-bd72-5153a34b6f46)
passes after the formatting correction: 459 targets pass, 49 execute and 410 use
cache; the two Swift platform targets are skipped. The owning core unit shard
executes again. Integration/acceptance bodies are excluded by this command; no
new database case or schema change is part of this checkpoint.


## Private qualification receipts

The private listener now receives a bounded qualification submission or withdrawal
and reloads its durable receipt. Three new database-free wire cases cover auth
before parsing, malformed/duplicate keys (including escaped equivalent keys),
media type and the exact 16 KiB boundary. Two new guarded HTTP cases own real
persistence and status; three additions to the existing archive-upload integration
suite own concurrency, input/transaction refusal and binding retention. Every
existing assertion is retained. Unboxed cases delete only their own rows and
re-query absence.

Focused remote run
[7ee73b1b](https://carverauto.buildbuddy.io/invocation/7ee73b1b-12ea-4339-a370-08832d49a80f)
passes all three targets: web unit owner and web quality execute; core quality
uses its passing cache. The web shard reports 819 tests, zero failures and 220
exclusions, including the new guarded cases reserved for their database lane.
The first run exposed a long guard and the existing formatter inventory's missing
classification for the new machine timestamp. The guard is equivalent after
formatting and the inventory gains one canonical-machine entry; no assertion is
removed or weakened. The corrected shard also passes that inventory.

Full remote `make test`
[3fe23e48](https://carverauto.buildbuddy.io/invocation/3fe23e48-5967-426f-b2ea-326dec32bc55)
passes 459 targets: 61 execute, 398 use cache, and two Swift platform targets are
skipped. This includes source routing, migration-version/Helm agreement and image
checks. The registration check reports 65 tests with one skip. Strict OpenSpec,
changed-document ASCII/relative links and `git diff --check` pass.

These prepublication checks exclude guarded database bodies. Their five new
cases must execute in the sanctioned Core Integration and Web-NG DB PR lanes;
publication may use the approved prepublication-only Test exception, but final
CI is not waived. No database migration against a live environment, provider
probe, rollout or recording enablement ran. Receipt acceptance still establishes
neither historical environment identity, evidence freshness, applied
configuration nor storage authority.

Final receipt PR #5979 merged at `37d7f26a61e8d5c3d2caf28eb2b6c5da3c5ee5d3`
after all 19 checks passed on head `53e3de1ecfa43fead3f712c52ba2f9e75cea3001`.
The prepublication database exception was satisfied by actual final-head CI:
[Core suite](https://carverauto.buildbuddy.io/invocation/42cf4965-a34a-4f4d-909f-59deef32203b)
executed all 12 targets uncached; receipt owner serial lane 6 reported 300 tests,
zero failures and eight unrelated exclusions, with integration bodies included.
[Web suite](https://carverauto.buildbuddy.io/invocation/8a15b4d4-8b75-4fa3-8b40-5282a700cf75)
executed all seven targets uncached. HTTP owner shard 0 reported two properties,
819 tests and zero failures; its trace includes both new receipt cases. Both
fixture parents reported zero suite, observer, teardown and release statuses.

## Deployment-scoped media authentication

The product changes protect existing receipt ingress with a separate installed
media credential and exact deployment/generation headers. The existing router
test owner adds purpose separation, installation acknowledgment, invalid
configuration, replacement/media-only operation and encoded-route cases. The
existing guarded HTTP owner extends denied authentication checks while retaining
all persistence, retry, conflict, withdrawal and unqualified-state assertions.

Independent review found that raw-path authentication and Plug.Router's decoded
path matching disagreed. The new regression failed at that exact boundary in
[2098b2d2](https://carverauto.buildbuddy.io/invocation/2098b2d2-7c0f-45c7-ab09-17b067b76a9c):
824 tests, one failure, 220 exclusions. An encoded media path selected account
authentication, then reached the media handler with no installed identity. The
repair applies the router's segment decoding before selecting authentication.
Compilation also exposed a new application-to-plug boundary dependency; shared
configuration validation now belongs to the context used by startup and the plug.

The complete Helm render suite passed in
[c3b2585f](https://carverauto.buildbuddy.io/invocation/c3b2585f-71ff-4fdb-9c49-8bd2f7a2cff2).
It exercises media-only and combined credentials, Secret references, rollout
annotations, exact bigint strings, invalid identity/generation and environment
override rejection. It preserves all previous assertions and test routing.

Repaired focused run
[ad739b15](https://carverauto.buildbuddy.io/invocation/ad739b15-70c1-458e-854f-fb9241fa87a2)
passes the router owner with 824 tests, zero failures and 220 exclusions, plus
web quality with no issues and the cached full Helm render suite. The encoded
route regression is included, and the new application-to-plug warning is gone.
Independent read-only review found no remaining authentication or boundary issue.

Full remote `make test`
[23ede7bb](https://carverauto.buildbuddy.io/invocation/23ede7bb-1e3e-45d0-a117-0c714ded1fd5)
passes 459 targets, with two Swift platform skips. Strict OpenSpec and the eight
changed documents' ASCII/relative links pass. The modified guarded HTTP bodies
remain explicitly unexecuted before publication; their final in-cluster PR lane
must execute on the published head. No provider or live deployment operation ran.


Final media authentication PR #5983 merged at
`07e895e9b104fb7345b67f873af99e6704253e64` from head
`66d2262431d9d08614177109dc52a763238975c8`. All final checks passed. The
prepublication database exception was satisfied by the actual final-head
[Core suite](https://carverauto.buildbuddy.io/invocation/59ceece3-2978-49f7-8142-5e1d23ffe855)
and [Web suite](https://carverauto.buildbuddy.io/invocation/f8b9178b-6750-4eef-ae3a-0f44b7807291):
all 12/seven targets executed and passed, with zero lifecycle failure statuses.
Web HTTP owner shard 0 reported 819 tests plus two properties and zero failures;
its normal test trace includes both qualification cases. The final full unit
invocation `7f88b797-695e-472d-bb74-77fb87083f7a` passed 442 targets with two
platform skips; benchmark and race invocations passed 17 and 71 targets.


## Durable recording stop

The stop-only checkpoint preserves existing local recording until explicitly
stopped, then fences recorder acquire, renewal, block reservation and dispatch
marking. Producer-owned drain preserves live viewing and the original deadline.
HTTP status deliberately reports no full applied revision or drain attestation.

Independent review corrected two test weaknesses: the three unboxed recorder
fixture owners now clean only their own control row and recheck the complete
prior state; the concurrency owner now uses independent database sessions and
actual blocking relationships to prove stop waits behind earlier admission.
All prior assertions remain. Final read-only review of HTTP, core and runtime
found no unresolved issues.

[Runtime checks](https://carverauto.buildbuddy.io/invocation/53a5ed1f-da51-4824-858e-4919bc87fe84)
passed 211 tests and strict quality. The
[core follow-up](https://carverauto.buildbuddy.io/invocation/6e6d9dec-b611-4e96-800e-dcb1601cdf62)
passed quality and integration compilation, while guarded database bodies remain
unexecuted. The inventory/workflow contract passed 65 tests with one intentional
skip after an unchanged rerun of a synthetic subprocess timeout.

The [combined HTTP checks](https://carverauto.buildbuddy.io/invocation/f3d8cdce-549c-4693-9a3a-57881ecc39e3)
passed 827 tests with zero failures and 221 exclusions, plus strict web quality
and Helm rendering. The new HTTP persistence body is one of the guarded
exclusions, not executed evidence. Both web database routing contracts passed
in `d66b959c-d144-4b82-8d53-e722436e854a`.

A temporary one-byte increase of the HTTP body limit failed the owning boundary
assertion in [81ea7320](https://carverauto.buildbuddy.io/invocation/81ea7320-a981-46dc-85d1-6b454b8ea85e):
the oversized document incorrectly returned 400 instead of 413. Both automatic
attempts reported 827 tests and exactly that one failure. The positive handler
was restored byte-for-byte before further checks.

Full remote `make test`
[cad55d76](https://carverauto.buildbuddy.io/invocation/cad55d76-96a7-4c64-8fa4-e5cf60bc1356)
then passed 459 targets: 59 executed, 400 used cache, and two Swift platform
targets were skipped. The run completed successfully without source changes or
a restart after a delayed remote Go compile response. This includes the restored
HTTP owner, migration/Helm agreement, test routing and image checks.

The required final-head database execution passed for published head `fb6c740f`
in [PR #5989](https://github.com/carverauto/serviceradar/pull/5989), subsequently
merged at `b06d0b6b12e42519aa0bda8157692feedbffd12d`. All 20 checks passed.
The [Core suite](https://carverauto.buildbuddy.io/invocation/e00f8d32-c39e-4d96-a91b-ec76e74c7d6f)
executed all 12 targets and the [Web suite](https://carverauto.buildbuddy.io/invocation/2602f4c1-2649-4981-80a6-7914dabbe78d)
executed all seven. Both parents reported zero suite, observer, teardown and
release statuses.

The tested prospective staging merge assigns the four new archive-upload cases
to Core serial lane 6 (243 tests, zero failures, eight unrelated exclusions) and
the worker drain case to lane 4 (392 tests, zero failures). Registration, explicit
integration inclusion and absence of case skips establish their coverage; the
Core console is aggregate output, not an individual case trace. Web shard 0
reported 820 tests and two properties with zero failures and explicitly traced
the new HTTP persistence case completing in 172.7 milliseconds. The approved
prepublication exception was therefore satisfied by actual guarded execution.
No provider or live rollout ran.

Cloud [PR #187](https://github.com/carverauto/serviceradar-control/pull/187)
merged at `a55f904cd9f929a58e133ca02c9b6dbe58323b73`. Its final CI used the
sanctioned Timescale fixture and reported 3230 tests, zero failures and 10 skips;
all 17 required owner cases were enabled. Earlier proxy-local PostgreSQL testing
was a workflow deviation, not a substitute for this CI. Exact local aliases were
not rerun and temporary-directory removal was not independently verified; the
PR retains those limits. This validates installation/chart persistence only.

## Isolated init-object authority

This checkpoint adds one nonrenewable installed authority window and one fresh
conditional init PUT per existing dispatch. It retains exact verification as
separate evidence; recording, archive publication and local reclamation remain
unavailable. No live provider, bucket, deployment or camera operation ran.

Focused validation before integration:

- [Core quality and integration-source compilation](https://carverauto.buildbuddy.io/invocation/1520ac21-e52e-4135-ad6a-eefefb426865)
  passed. The compile owner reported zero executed tests and 132 exclusions;
  its eight new database cases remain required in guarded Core CI. The
  [database-free owner](https://carverauto.buildbuddy.io/invocation/f03fc020-eb6e-4af1-b8b2-3edf4c882457)
  also passed.
- [Web TLS, quality and routing contracts](https://carverauto.buildbuddy.io/invocation/6f611c6b-7700-4e96-a418-103630b924b2)
  passed: 830 tests, zero failures and 222 exclusions. Three new database-free
  cases use real TLS sockets. The new boxed HTTP/database roundtrip is excluded
  here and must execute in guarded Web CI.
- [Storage runtime and quality](https://carverauto.buildbuddy.io/invocation/529180f7-7332-4c08-ba1b-557ea03eb7da)
  passed all 15 cases. The
  [packaged release smoke test](https://carverauto.buildbuddy.io/invocation/f6227e4c-1192-455e-b104-e2cd168ff0f3)
  passed the original probe startup assertions and isolated storage's real TLS
  authentication/startup behavior. The
  [existing provider probe](https://carverauto.buildbuddy.io/invocation/5717b5e6-74d9-4c9a-95fd-521e202c2a78)
  retained all 16 passing cases.
- [Helm rendering](https://carverauto.buildbuddy.io/invocation/9e82a6fa-8e80-411c-b1c8-061cb9b9cd1f)
  passed 410 cases. The new semantic render cases exercise default absence,
  credential projections, private ports, required configuration, process
  isolation and narrow network policy even with broad custom selectors.

The provider wire-identity assertion exposed a transport-added User-Agent after
signing. The runtime now supplies that header before signing and hashing; the
independent server-observed digest assertion remains. Release startup testing
also rejected an incorrectly generated synthetic client certificate; the fixture
now uses a proper CA-signed leaf without changing production TLS policy.
Independent review found that apply needed exact challenged-generation equality
in addition to digest equality. That guard and its crossed-generation regression
are included. A Helm case initially selected the wrong rendered resource name;
its selector was corrected without dropping the network-policy assertion.

Integrated remote `make test`
[8c77cc64](https://carverauto.buildbuddy.io/invocation/8c77cc64-cffa-4ca6-9e0e-0e6c526c5225)
passed 460 targets: 63 executed, 397 used cache and two Swift platform targets
were skipped. This includes generated schema agreement, migration/chart version
`20261025020000`, the complete Helm suite, test routing and integrated application
owners. Strict OpenSpec validation also passed. All existing assertions remain.

Publication through no-mistakes and actual guarded database execution on the
final published head remain outstanding at this authored checkpoint. Required
database coverage is eight cases in the existing archive-upload owner plus the
new actual private-TLS HTTP roundtrip. Compilation and excluded bodies are not
execution evidence. Both guarded lifecycles, their actual suites and cleanup
must pass before this change is ready for review. These synthetic checks do not
qualify a live provider or complete any broad runtime/Cloud acceptance task.
