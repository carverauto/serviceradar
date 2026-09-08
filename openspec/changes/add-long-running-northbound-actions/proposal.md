# Change: Long-running Northbound Actions

## Why

Many network automation APIs do not return final results from the launch call. Systems such as OpenText Network Automation often accept a diagnostic or remediation request, return a vendor task ID, require polling until completion, and then require a separate result fetch. ServiceRadar's northbound action model needs to represent that lifecycle explicitly so operators see durable progress and plugins do not have to block an agent runtime until an external system finishes.

## What Changes

- Add a deferred northbound action lifecycle where a plugin can return an accepted state with an external task ID, poll schedule, and opaque continuation state.
- Persist continuation state and schedule follow-up polling through the control plane instead of requiring the initial request to stay open.
- Add a provider/plugin poll entrypoint that resumes the vendor task, records status transitions, and fetches final results when the external task completes.
- Expose queued/running/polling/result-fetch states in Action History so users understand where results will appear after launch.
- Extend the Go SDK sample contract so plugin authors can model launch, poll, and final-result phases for APIs such as OpenText Network Automation.

## Impact

- Affected specs:
  - `wasm-plugin-system`
  - `plugin-sdk-go`
  - `job-scheduling`
  - `build-web-ui`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/automation/northbound/` for invocation state, persisted continuation data, dispatch, and polling workers.
  - `go/pkg/agent/plugin_runtime.go` and Wasm host/plugin contracts for deferred action responses and poll invocations.
  - `~/src/serviceradar-sdk-go` for launch/poll/final-result helpers.
  - `elixir/web-ng` Action History components for clear progress and result visibility.
