## 1. Proposal

- [x] 1.1 Validate the OpenSpec proposal with `openspec validate add-sample-northbound-wasm-plugin --strict`.
- [ ] 1.2 Get approval before implementation.

## 2. ServiceRadar Plugin

- [ ] 2.1 Add `go/cmd/wasm-plugins/sample-northbound/` with Go/TinyGo source, manifest, config schema, and tests.
- [ ] 2.2 Declare device-scoped and interface-scoped action descriptors in the plugin manifest.
- [ ] 2.3 Return deterministic structured action results for simulated device and interface API calls.
- [ ] 2.4 Register the plugin in Bazel Wasm build and bundle inventory.
- [ ] 2.5 Add runtime fixture coverage that exercises the plugin through the Wasm action invocation path.

## 3. SDK Example

- [ ] 3.1 Add `/home/mfreeman/src/serviceradar-sdk-go/examples/sample-northbound/` using the public Go SDK.
- [ ] 3.2 Include README/config/manifest examples showing device and interface action descriptors.
- [ ] 3.3 Add SDK tests or example tests for decoding action invocations and building per-target results.

## 4. Validation

- [ ] 4.1 Run Go tests for the sample plugin and affected SDK package/example.
- [ ] 4.2 Run Bazel test/build targets for the sample Wasm plugin bundle.
- [ ] 4.3 Run focused agent runtime action tests.
- [ ] 4.4 Run `make lint-go` or focused `golangci-lint` for touched Go packages.
- [ ] 4.5 Run `openspec validate add-sample-northbound-wasm-plugin --strict`.
