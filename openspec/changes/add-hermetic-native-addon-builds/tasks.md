# Tasks: Hermetic native add-on build gates

## 1. Tool pinning
- [ ] 1.1 Add Bazel-owned, version-pinned tool targets for `go-size-analyzer`/`gsa`,
  `oras`, `cosign`, `jq`, and the native add-on artifact signature verifier.
- [ ] 1.2 Ensure tool targets work on the Linux exec platform used by CI and fail
  with a clear message when a required platform is unavailable.
- [ ] 1.3 Remove Forgejo workflow-time installation of build-gate tools after the
  Bazel targets provide them.

## 2. Bazel gate targets
- [x] 2.1 Convert native add-on manifest validation into a Bazel test or aggregate
  target with declared manifest/schema inputs.
  - `//build/native_addons:validate_addon_manifests_test` runs the Bazel-built
    `//go/tools/addon-manifest-validator` against declared first-party manifests.
- [ ] 2.2 Convert dependency-isolation and stdlib-`plugin` checks into Bazel tests
  that use Bazel-provided Go tooling rather than ambient `go` from `PATH`.
  - PARTIAL: `//build/native_addons:dependency_isolation_test` checks the Bazel
    dependency closure for `//go/cmd/agent:agent` via `genquery`, so the agent
    cannot gain add-on implementation labels without failing analysis/test.
    The stdlib-`plugin` gate still needs a Bazel-owned replacement.
- [ ] 2.3 Convert the dead-code-elimination guard into a Bazel test that builds
  native add-on binaries under the declared Go SDK and inspects linker `dumpdep`
  output as a declared test action.
- [ ] 2.4 Convert the binary-size gate into a Bazel test that consumes
  `//build/native_addons:all_binaries`, the committed size baseline, and the pinned
  `gsa` tool.
  - PARTIAL: `//build/native_addons:binary_size_test` consumes
    `//build/native_addons:all_binaries` and the committed baseline through Bazel
    runfiles. It is marked Linux-only because it validates Linux native add-on
    artifacts; macOS local runs skip it unless a Linux exec platform is selected.
    It fails closed when `gsa` is missing; CI currently installs pinned
    `gsa@v1.13.0`, but `gsa` is still not a Bazel-owned tool target, so this task
    remains open.
- [ ] 2.5 Add one canonical aggregate target, for example
  `//build/native_addons:build_gates_test`, covering all hermetic native add-on
  build gates.
  - PARTIAL: `//build/native_addons:build_gates_test` now aggregates the converted
    dependency-isolation, manifest, binary-size, and verifier-negative fixture
    tests. It does not yet cover stdlib-`plugin` or dead-code elimination.

## 3. Hermetic verifier fixtures
- [ ] 3.1 Replace fake-`PATH` verifier negative tests with Bazel fixture tests that
  use declared OCI layout, tarball, signature, and manifest inputs.
  - PARTIAL: `//scripts:verify_native_addon_publish_negative_test` runs the
    existing unsigned/tampered fixture harness as a Bazel test with declared script
    inputs. The fixture still creates fake CLIs dynamically and is not yet a pure
    declared OCI-layout fixture.
- [ ] 3.2 Assert unsigned, tampered, missing-layer, and wrong-signature cases fail
  before any publish step can run.
  - PARTIAL: unsigned and tampered cases are covered by the Bazel test.
- [ ] 3.3 Keep live registry/Cosign/Rekor verification as a separate publish-stage
  integration check with explicit network/secrets requirements.

## 4. CI and documentation
- [ ] 4.1 Update `.forgejo/workflows/native-addons.yml` to run the aggregate Bazel
  target instead of Make/script-composed gates.
  - PARTIAL: the workflow now runs `bazel test //build/native_addons:build_gates_test`
    before the existing Make gates. Make remains until the source-tree `go list` and
    `dumpdep` checks are converted.
- [ ] 4.2 Document the local and CI commands for hermetic native add-on gate
  validation, including any required Linux remote-execution config.
  - PARTIAL: local macOS runs can use `bazel test //build/native_addons:build_gates_test`
    for the platform-compatible fixture gates; CI/Linux runs the same aggregate and
    includes `//build/native_addons:binary_size_test`.
- [ ] 4.3 Verify the Agent D branch's pending Bazel-backed binary-size validation
  through the new hermetic target.

## 5. Validation
- [x] 5.1 `openspec validate add-hermetic-native-addon-builds --strict` passes.
