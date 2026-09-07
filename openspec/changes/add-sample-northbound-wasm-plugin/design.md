# Design: Sample Northbound Wasm Plugin

## Context

The northbound action system now supports provider-neutral action descriptors and on-demand Wasm action execution. The next practical gap is an integration that can be safely assigned in demo or development without requiring AWX, HP Network Automation, or any real external NMS.

The sample should behave like a small NMS connector: it receives selected device or interface context, makes a deterministic simulated "API query", and returns structured action results. It should use the public Go SDK instead of internal runtime helpers wherever possible.

## Goals

- Provide a safe test plugin for device and interface action launch flows.
- Demonstrate the Go SDK's action descriptor and invocation APIs with realistic code.
- Exercise the same build, bundle, import, approval, assignment, and runtime paths as production Wasm action plugins.
- Keep outputs deterministic so tests do not depend on external services.

## Non-Goals

- Build a real NMS or remediation integration.
- Add a new UI surface beyond existing provider-neutral action launch and history views.
- Add new host networking semantics beyond the existing Wasm HTTP host function wrappers.
- Store credentials or connect to a real third-party API.

## Proposed Shape

### Plugin

Add `go/cmd/wasm-plugins/sample-northbound/` with:

- `main.go` using the SDK pinned in the plugin's `go.mod`.
- `plugin.yaml` with stable ID `sample-northbound-nms`, standard Wasm metadata, and two action descriptors.
- `config.schema.json` for simulated endpoint/options.
- Unit tests for descriptor shape and invocation handling.
- Bazel metadata through `BUILD.bazel` and `build/wasm_plugins/plugin_inventory.bzl`.

### Actions

`sample.device.lookup`

- Scope: `device`.
- Required context: `device.uid`, `device.ip`.
- Inputs: `query_mode` enum, optional `include_neighbors` boolean, optional `reason`.
- Result: per-target success with simulated NMS facts such as inventory ID, reachability, platform, policy state, and external URL.

`sample.interface.audit`

- Scope: `interface`.
- Required context: `device.ip`, `interface.name`.
- Inputs: `operation` enum (`audit`, `validate`, `simulate_remediation`), optional `change_ticket`, optional `dry_run`.
- Result: per-target success with simulated port facts such as admin/oper status, vlan, policy state, and remediation preview.

### SDK Example

Add an equivalent example under `/home/mfreeman/src/serviceradar-sdk-go/examples/sample-northbound/`. The ServiceRadar in-repo plugin can either vendor the same shape or remain a standalone copy, but the example must compile against the SDK's public APIs and explain how device/interface target context maps into action requests.

### Test Strategy

- SDK unit tests for action invocation decoding and result building.
- Plugin unit tests for deterministic device and interface action results.
- Bazel build/test target for the first-party plugin bundle.
- Agent runtime fixture test, if needed, that runs the built Wasm against sample action invocation payloads.
- Manual demo validation after implementation: import/approve/assign plugin, select a device, launch device action, select an interface, launch interface action, verify invocation history and redacted results.

## Risks

- The SDK action APIs may still have rough edges. If the sample requires internal runtime details, fix the SDK ergonomics instead of coding around it in the sample.
- Action descriptor manifest support is new. Tests should validate descriptor parsing to catch drift between manifest, control plane, and SDK examples.
- Duplicating code between repo and SDK examples can drift. Prefer a clear README and shared test fixtures where direct code sharing is not practical.
