# Sample Northbound NMS Plugin

This example shows how a Go/TinyGo Wasm plugin can expose ServiceRadar
northbound actions without depending on a real external system.

The plugin declares two actions in `plugin.yaml`:

- `sample.device.lookup`: device-scoped lookup requiring `device.uid` and
  `device.ip`.
- `sample.interface.audit`: interface-scoped audit/remediation preview requiring
  `device.ip` and `interface.name`.

Both actions use the SDK action helpers:

- `sdk.LoadActionConfig` reads the host-supplied action invocation envelope.
- `sdk.ActionInvocation.Targets` provides immutable selected device/interface
  context.
- `sdk.SubmitActionResult` returns `serviceradar.northbound_action_result.v1`
  with per-target results.

The default configuration uses a `mock://sample-nms` endpoint and deterministic
results so the example is safe to run in tests and demos.
