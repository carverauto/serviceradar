# Arrow source and checkout verification

Arrow is ordinary monorepo source replaced from the Apache revision recorded in
`swift/FieldSurvey/LocalPackages/arrow-swift/UPSTREAM.json`. This is not recovery
of the former orphan gitlink. The package retains upstream licenses, source
headers, original hashes, and the reviewed omitted-validity patch.

Refresh and compare the declared source import:

```text
bazel run --config=remote //swift/FieldSurvey/LocalPackages/arrow-swift:update_vendor
bazel test --config=remote //third_party/arrow_swift:vendor_drift_test
```

The updater owns 31 upstream source/license files. The package manifest,
provenance, and synthetic compatibility tests are project-owned adapters.

Run host Git validation before submitting an indexed source revision. The
expected commit must be a full SHA and the index must match that commit:

```text
bazel run //build/ci:verify_git_metadata -- --expected-commit <full-commit-sha>
bazel test //build/ci:git_metadata_test //build/arrow_swift:runner_test
bazel run //build/ci:git_checkout_regression
```

The Git runtime tools do not fetch submodule URLs. The synthetic regression uses
only temporary local repositories, including a worktree and sparse checkout.
It validates malformed metadata independently of whether the installed Git
version tolerates an orphan during recursive credential cleanup.

Run the Mac targets explicitly; Linux remote unit runs cannot cover them:

```text
bazel test --config=darwin_local --platforms=//build/platforms:darwin_aarch64 --nocache_test_results --test_env=DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer //build/arrow_swift:swift_regression_test //build/arrow_swift:ios_compile_test
```

The regression runs two synthetic compatibility tests and 43 self-contained
upstream core tests. Five upstream file tests requiring external generated data
are explicitly excluded. Dependencies come from declared, digest-pinned archives;
the action stages only their Swift package inputs and licenses in TEST_TMPDIR.
Unrelated FlatBuffers language trees are excluded. Selected links, special files,
archive traversal, and duplicate paths are rejected before extraction.

The iOS target compiles Arrow for the consumer's arm64 iOS 26.2 Simulator target.
Both targets fail when the requested Xcode installation or SDK is unavailable.
A full FieldSurvey app build and Xcode package resolution remain separate consumer
checks requiring compatible Xcode and CoreSimulator installations. Neither these
tests nor a source repair prove deployment or AWX/Proxmox runtime acceptance.
