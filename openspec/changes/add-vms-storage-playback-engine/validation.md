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
| Durable ownership | Relay reservations, adoption, heartbeat, idle close and expiry cleanup use the persisted owner fence. Five remote targets pass in [d6e1ddea](https://carverauto.buildbuddy.io/invocation/d6e1ddea-ac90-485d-87c5-85b5dccc0979), including 191 core-elx tests, 1,014 core tests, quality checks and executable integration selection. Restoring the old close behavior fails the retained-consumer regression | Merged runtime suite [23177e08](https://carverauto.buildbuddy.io/invocation/23177e08-ea4b-45c8-b90e-8f9a24b11d1a) passed 12/12. Head `158aa45657` then failed the two added keepers in suite `d607f3a0`. Positive proof of repair `a8590062` is draft #5954 `89d50a7f0d`: workflow [a74b1f9f](https://carverauto.buildbuddy.io/invocation/a74b1f9f-ee0d-450f-88a0-7d26eeed15ed), child [7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a), 12 of 12 passed; suite, observer, teardown, and release 0; serial_6 256/0; serial_0 401/0 and 1 skip. GitHub rollup success, 18 checks. That run does not execute archive database cases |
| Recorder exclusion | Retained claims carry a separate recorder epoch, authenticated ingress ID, provisioned storage UUID and durable sequence counter. The first claim pass passes nine focused RBE checks in [c9dcd2fe](https://carverauto.buildbuddy.io/invocation/c9dcd2fe-fde4-43d6-a328-b8b344ec4be7). The relay-expiry correction passes core quality, core-elx units and integration selection in [bd3031f3](https://carverauto.buildbuddy.io/invocation/bd3031f3-d0a2-49f1-a9e6-c60156d8a4f9) | A passing guarded run after the repair is still required before competing-claimant, expiry-rollback, or Worker restart races count as proved |
| Provider access | Authenticated bounded ranges pass real TLS/CONNECT, response-status, object-identity, byte/header/deadline tests in [eedb3bc5](https://carverauto.buildbuddy.io/invocation/eedb3bc5-2d1a-41ed-8c64-ab3cd22d74a0). Deliberately accepting HTTP 200 failed the control | Actual endpoint capability/security probes, gateway authorization and measured request cost |
| Historical block authority | Nine focused targets pass in [27053d5a](https://carverauto.buildbuddy.io/invocation/27053d5a-0d1c-45ae-9fda-2e9a412a4b16), including 206 core-elx cases, eight media cases, quality, integration selection/topology and Helm migration checks. Weakening the shared descriptor bounds fails two manifest cases in [1c617b24](https://carverauto.buildbuddy.io/invocation/1c617b24-b950-4ef8-9bbf-58881832e059); restored source passes. The database file is `elixir/serviceradar_core/test/integration/camera_recording_blocks_integration_test.exs` on `//elixir/serviceradar_core:integration_tests` | Published `bf480fdcb1` executed this file in [7901e502](https://carverauto.buildbuddy.io/invocation/7901e502-43b8-4fbf-9a2e-3d3cbc29a690). `integration_tests_serial_2` failed only at line 204. The corrected RESTRICT expectation has not been re-executed. Immutable upload and publication remain unimplemented. [Authority boundary](block-authority.md) |
| Immutable archive destination | Six focused targets pass in [f6c00dae](https://carverauto.buildbuddy.io/invocation/f6c00dae-99ab-4c6c-907d-a30a0d00ab4e), including the owning unit shard (1,022 executed, one skipped, 555 excluded), quality, registration, selection and Helm migration checks. Allowing an unexpected input field fails the contract case in [4c35622e](https://carverauto.buildbuddy.io/invocation/4c35622e-1396-4beb-bded-45596214e4ae); the parser is restored byte-for-byte and generator replay is identical. Canonical identity without a database is `test/serviceradar/camera/archive_destination_test.exs` on `//elixir/serviceradar_core:unit_tests` | On `bf480fdcb1`, the referenced delete was rejected as `:restrict_violation`, pg_code `23001`, constraint `camera_recording_blocks_archive_binding_id_fkey`. The test expected `:foreign_key_violation`, so that test did not reach its later release and replacement assertions. The corrected expectation has no matching-head result. Qualification and actual storage operations remain absent. [Binding contract](archive-binding.md) |
| Persisted-descriptor manifest | Four focused targets pass in [51ca7192](https://carverauto.buildbuddy.io/invocation/51ca7192-b501-4c2b-b3fe-85425239f51a): 207 unit cases, eight cached media cases, three freshly executed Chromium cases and quality. Fixed independently calculated hashes pin v1 bytes and object keys. Bypassing descriptor validation fails in [09d56db4](https://carverauto.buildbuddy.io/invocation/09d56db4-88d1-44bd-82f8-3f97f7cd66ea); accepting an unsupported profile fails in [b0368339](https://carverauto.buildbuddy.io/invocation/b0368339-fdfe-4fc6-8ec5-2b8ef3ecf7f7). Production mutations are restored byte-for-byte and all prior assertions remain | Remote receipts, byte verification and publication remain separate work |
| Provider diagnostic | Sixteen synthetic TLS protocol cases, release startup and quality pass in [373125cd](https://carverauto.buildbuddy.io/invocation/373125cd-3ffc-4b55-9618-359fb128eb2c). Separate negative controls reject missing conditional headers, missing explicit encryption headers and HTTP 200 completion errors. The earlier second live exercise verified private access, roles, conditional reads, checksums, multipart completion/hash/cross-part range and abort; all temporary resources from both exercises were removed and absence rechecked | The live result remains failed because default SSE-S3 was not confirmed. Explicit SSE-S3 and atomic no-overwrite now have synthetic diagnostic coverage but remain untested against the provider. Policy/Object Lock are untested; broad provider keys are not recorder credentials. [Operator runbook](../../../build/media/provider-probe.md) |
| A/V diagnostic | Stream Doctor measured 3 ms control drift and 503 ms with a 500 ms injected delay; removing the delay made the fault assertion fail. Integrated target passes in [90139de1](https://carverauto.buildbuddy.io/invocation/90139de1-7abd-4d0d-8489-6fb40a65f9ea), using the verified cached result | Product audio support and RTSP fault coverage; [scope, bounds and fresh-run evidence](stream-doctor.md) |
| Foundation validation | [PR #5950](https://github.com/carverauto/serviceradar/pull/5950) merged with all 20 checks passing. The final fix passes 199 core-elx and six media tests in [edd24097](https://carverauto.buildbuddy.io/invocation/edd24097-fb2c-4898-ad3e-daae1bf87952). Core Integration executes all 12 targets in [681ba460](https://carverauto.buildbuddy.io/invocation/681ba460-25c3-4cdb-af7a-94a14e169724), with successful fixture teardown and lease release | This PR does not contain the runtime claim/Worker or historical block cases |
| Combined runtime sweep | After replaying all 19 runtime commits onto the reviewed foundation with equivalent patches, `make test` passes 436 targets, with two Swift platform skips, in [bbf2e694](https://carverauto.buildbuddy.io/invocation/bbf2e694-c755-43bf-b2ee-d434aebeb471). Fifty targets execute; the remainder use verified cache results. Strict OpenSpec validation also passes | The unit sweep does not execute database integration bodies |
| Combined archive sweep | With runtime close/retry fixes, retained block authority, provider diagnostics, immutable archive bindings and descriptor encoding, an earlier `make test` passes 436 targets, with two Swift platform skips, in [5c992fa7](https://carverauto.buildbuddy.io/invocation/5c992fa7-55d0-448b-a0eb-a4f02b23aea5). Forty-nine targets execute; the remainder use verified cache results. Three Chromium cases execute in [d031da58](https://carverauto.buildbuddy.io/invocation/d031da58-b919-470f-8725-45a7f853e0ab), which also reuses the passing provider/media results. Historical non-database proof [87633a67](https://carverauto.buildbuddy.io/invocation/87633a67-0e9a-4b03-b886-614b01200cec) executed five targets and all passed: release startup, `provider_probe_test`, `unit_tests_serviceradar_core_elx`, `unit_tests_serviceradar_other`, and `migrations_expected_version_test`. Strict OpenSpec validation of this change passed on `8a5b83b0`. Non-database `make test` of `8a5b83b0` finished in [b0d27739](https://carverauto.buildbuddy.io/invocation/b0d27739-061d-4722-87e7-cd3a711b9958): 452 passed, 49 executed, and 2 skipped (`ios_compile_test`, `swift_regression_test`). It excludes integration and acceptance tests. The earlier replay of the seven archive commits onto runtime head `796882e59b` preserved their source | This draft is rebased onto staging, which contains merged #5952, and imports repair `a8590062`. Published `bf480fdcb1` ran Core Integration [7901e502](https://carverauto.buildbuddy.io/invocation/7901e502-43b8-4fbf-9a2e-3d3cbc29a690): 12 targets executed once, uncached, 11 passed, and `integration_tests_serial_2` failed the stale `:foreign_key_violation` expectation. The corrected expectation has no guarded rerun |

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
runtime database proof is draft #5954 `89d50a7f0d`: workflow
[a74b1f9f](https://carverauto.buildbuddy.io/invocation/a74b1f9f-ee0d-450f-88a0-7d26eeed15ed),
child
[7cbd7c77](https://carverauto.buildbuddy.io/invocation/7cbd7c77-8615-4ab1-a68d-1774d52d966a),
executed 12 of 12 and all passed. Suite, observer, teardown, and release each
returned 0. `integration_tests_serial_6` finished 256 tests with 0 failures.
`integration_tests_serial_0` finished 401 tests with 0 failures and 1 skip.
GitHub's check rollup for that head is success across 18 checks. That result
covers the imported runtime correction. Published #5955 head `bf480fdcb1`
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
not run on `bf480fdcb1`, and the correction has no matching-head CI result.
`integration_tests_serial_3` finished 329 tests, 0 failures, and 8 excluded,
including the 3 cases in
`elixir/serviceradar_core/test/integration/camera_recording_worker_integration_test.exs`.
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
