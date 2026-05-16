# Change: Sample Northbound Wasm Plugin

## Why

The provider-neutral northbound action flow needs an easy end-to-end test fixture that is not tied to Ansible or a real customer integration. A first-party sample Wasm plugin can exercise device-scoped and interface-scoped actions, document the Go SDK contract, and give operators a safe way to validate plugin import, assignment, launch, dispatch, and result handling.

## What Changes

- Add a first-party Go/TinyGo Wasm plugin that simulates an external NMS API.
- Define two sample northbound actions in the plugin manifest:
  - a device action that accepts device context, simulates a lookup, and returns normalized device/API facts.
  - an interface action that accepts device and interface context, simulates a port query/remediation request, and returns per-interface facts.
- Build and bundle the sample plugin through the existing Bazel Wasm plugin pipeline.
- Add the same sample under `serviceradar-sdk-go/examples/` so SDK users can copy the pattern.
- Add tests that validate action descriptors, action invocation decoding, device/interface target handling, and deterministic action results.

## Impact

- Affected specs: `plugin-sdk-go`, `wasm-plugin-builds`, `wasm-plugin-system`
- Affected ServiceRadar code:
  - `go/cmd/wasm-plugins/sample-northbound/**`
  - `build/wasm_plugins/plugin_inventory.bzl`
  - `go/pkg/agent` fixture tests, if needed for runtime coverage
- Affected SDK code:
  - `/home/mfreeman/src/serviceradar-sdk-go/examples/sample-northbound/**`
  - `/home/mfreeman/src/serviceradar-sdk-go/sdk` only if the sample exposes a missing SDK ergonomics gap
