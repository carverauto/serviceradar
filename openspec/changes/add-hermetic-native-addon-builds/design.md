## Context
The first native add-on release gates were intentionally pragmatic: Make targets and
shell scripts call `go`, `bazel`, `oras`, `cosign`, `jq`, and `gsa` from `PATH`.
That is enough to prove behavior, but it is not a hermetic contract. A macOS local
validation already exposed the weak point: Bazel selected a Linux Go SDK executable
for a host action and the gate failed with `cannot execute binary file`.

## Goals / Non-Goals
- Goals:
  - Give CI one canonical Bazel target for native add-on build gates.
  - Pin every non-system tool used by those gates.
  - Make binary-size and dead-code checks consume declared Bazel outputs.
  - Make negative verifier tests deterministic and offline.
  - Preserve existing publish/sign behavior and registry media types.
- Non-Goals:
  - Remove network access from publish/sign steps.
  - Replace Cosign, ORAS, or the existing upload-signature format.
  - Refactor unrelated container image or Wasm plugin build workflows.

## Decisions
- Decision: Keep the shell scripts as thin implementations, but make Bazel own the
  invocation.
  - Rationale: The scripts already encode useful diagnostics. Bazel can supply
    explicit tool paths and declared inputs without rewriting all checks at once.
- Decision: Use one aggregate Bazel test target for CI, for example
  `//build/native_addons:build_gates_test`.
  - Rationale: Forgejo should not install tools or compose target lists; it should
    run the same target developers run.
- Decision: Treat publish verification as two layers.
  - Rationale: Fixture-based verifier tests are hermetic. Real registry, Cosign,
    and Rekor verification remains an integration step because it depends on remote
    state and release secrets.

## Risks / Trade-offs
- Bazelizing external CLI tools can add repository-rule or toolchain maintenance.
  Mitigation: Pin exact versions and expose them through small wrapper targets.
- Cross-platform local development may still require remote Linux execution for
  Linux-only native add-on artifacts. Mitigation: document the expected local
  command and fail with a platform diagnostic when remote execution is unavailable.
- `go-size-analyzer` output may vary by Go version. Mitigation: pin the Go SDK used
  for native add-on gate builds and keep byte-budget baselines as source inputs.

## Migration Plan
1. Introduce pinned Bazel tool targets without changing CI behavior.
2. Convert individual gates to Bazel tests that accept explicit tool paths and
   declared artifacts.
3. Add the aggregate native add-on build-gates target and make Forgejo run it.
4. Remove workflow-time tool installation once the Bazel target is authoritative.
5. Re-run the Agent D branch's pending Bazel-backed size validation from this
   hermetic target.
