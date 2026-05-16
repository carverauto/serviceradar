## 1. Proposal

- [x] 1.1 Validate the OpenSpec proposal with `openspec validate add-sample-northbound-wasm-plugin --strict`.
- [x] 1.2 Get approval before implementation.

## 2. ServiceRadar Plugin

- [x] 2.1 Add `go/cmd/wasm-plugins/sample-northbound/` with Go/TinyGo source, manifest, config schema, and tests.
- [x] 2.2 Declare device-scoped and interface-scoped action descriptors in the plugin manifest.
- [x] 2.3 Return deterministic structured action results for simulated device and interface API calls.
- [x] 2.4 Register the plugin in Bazel Wasm build and bundle inventory.
- [x] 2.5 Add runtime fixture coverage that exercises the plugin through the Wasm action invocation path.

## 3. SDK Example

- [x] 3.1 Add `/home/mfreeman/src/serviceradar-sdk-go/examples/sample-northbound/` using the public Go SDK.
- [x] 3.2 Include README/config/manifest examples showing device and interface action descriptors.
- [x] 3.3 Add SDK tests or example tests for decoding action invocations and building per-target results.
- [x] 3.4 Update `/home/mfreeman/src/developer` developer docs for northbound action SDK usage and the sample plugin.

## 4. Validation

- [x] 4.1 Run Go tests for the sample plugin and affected SDK package/example.
- [x] 4.2 Run Bazel test/build targets for the sample Wasm plugin bundle.
- [x] 4.3 Run focused agent runtime action tests.
- [x] 4.4 Run `make lint-go` or focused `golangci-lint` for touched Go packages.
- [x] 4.5 Run `openspec validate add-sample-northbound-wasm-plugin --strict`.
