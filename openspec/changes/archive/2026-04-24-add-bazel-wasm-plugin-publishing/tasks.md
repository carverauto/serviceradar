## 1. Implementation
- [x] 1.1 Add Bazel targets/macros that compile first-party Wasm plugins and assemble canonical plugin bundle artifacts.
- [x] 1.2 Define Harbor publish targets for first-party Wasm plugin artifacts with deterministic repository/tag naming.
- [x] 1.3 Extend Cosign signing to cover published Wasm plugin artifacts with Rekor/tlog enabled by default.
- [x] 1.4 Extend local verification tooling to verify Wasm plugin artifact signatures and OCI publication metadata before deployment.
- [x] 1.5 Update existing first-party plugin examples and harnesses to use the Bazel-managed artifact path instead of standalone manual `dist/` workflows.
- [x] 1.6 Document the developer/operator workflow for building, publishing, verifying, and inspecting Wasm plugin artifacts, including `oras` usage where helpful.

## 2. Validation
- [x] 2.1 Add focused tests or smoke checks for plugin bundle assembly and digest generation.
- [x] 2.2 Add a publish/verify smoke path that proves a first-party Wasm plugin artifact can be signed and then verified with the same policy Kyverno enforces.
- [x] 2.3 Validate the OpenSpec change with `openspec validate add-bazel-wasm-plugin-publishing --strict`.
