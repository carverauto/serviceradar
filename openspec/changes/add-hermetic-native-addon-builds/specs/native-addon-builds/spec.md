## ADDED Requirements

### Requirement: Hermetic native add-on build gates
Native add-on build gates SHALL run through canonical Bazel targets that declare
their source inputs, built artifacts, and tool dependencies, and SHALL NOT depend on
workflow-time tool installation or ambient host `PATH` selection.

#### Scenario: CI runs the canonical gate target
- **GIVEN** a native add-on release workflow needs to validate manifests,
  dependency isolation, stdlib-`plugin` exclusion, dead-code elimination, and binary
  size budgets
- **WHEN** the workflow runs the native add-on build gates
- **THEN** it SHALL invoke the canonical Bazel gate target
- **AND** every gate SHALL receive its tools from Bazel-declared tool targets
- **AND** the workflow SHALL NOT install or discover gate tools ad hoc before
  running the target

#### Scenario: Host tool drift cannot change gate behavior
- **GIVEN** a developer workstation has different versions of `go`, `oras`,
  `cosign`, `jq`, or `gsa` installed than CI
- **WHEN** the native add-on Bazel gate target runs
- **THEN** the gates SHALL use the Bazel-pinned tools
- **AND** host-installed versions SHALL NOT affect the validation result

### Requirement: Platform-stable native add-on gate execution
Native add-on binary builds and gate actions SHALL select explicit exec and target
platforms so local and CI validation either use the same Linux toolchains or fail
with an actionable platform diagnostic.

#### Scenario: macOS host validates Linux add-on gates
- **GIVEN** a maintainer runs the native add-on build-gate target from a macOS
  workstation
- **WHEN** the gate target needs Linux native add-on binaries or Linux-only tools
- **THEN** Bazel SHALL use the configured Linux execution platform or remote
  executor
- **AND** the build SHALL NOT attempt to execute a Linux Go SDK binary directly on
  macOS

#### Scenario: Missing Linux execution support fails clearly
- **GIVEN** no compatible Linux exec platform or remote executor is available
- **WHEN** the native add-on build-gate target runs
- **THEN** the target SHALL fail before running partial gates
- **AND** the error SHALL state that Linux execution support is required

### Requirement: Hermetic native add-on verifier fixtures
Pre-release native add-on verifier tests SHALL use deterministic, declared fixture
artifacts to prove unsigned, tampered, and malformed artifacts are rejected without
requiring a live registry or release secrets.

#### Scenario: Unsigned fixture is rejected offline
- **GIVEN** a declared OCI fixture for a native add-on artifact without a valid
  Cosign signature
- **WHEN** the verifier fixture test runs
- **THEN** verification SHALL fail
- **AND** the test SHALL complete without contacting Harbor, Cosign key services, or
  Rekor

#### Scenario: Tampered fixture is rejected offline
- **GIVEN** a declared native add-on tarball whose bytes do not match its
  upload-signature or digest metadata
- **WHEN** the verifier fixture test runs
- **THEN** verification SHALL fail
- **AND** the failure SHALL occur before any publish step can run
