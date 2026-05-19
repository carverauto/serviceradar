# Change: Northbound Action Integrations

## Why

ServiceRadar is starting to grow one-off automation paths, with Ansible as the first visible example. If every external tool gets its own button, LiveView flow, payload shape, and event handling path, the UI and backend will become integration-specific quickly and operators will still lack a consistent way to audit, retry, secure, or trigger remediation.

This change creates a provider-neutral northbound action model: operators can select devices or interfaces, choose an eligible action exposed by an approved integration or Wasm plugin, provide action-specific inputs through a controlled schema-driven modal, and execute that action with full RBAC, audit, event, and result tracking.

## What Changes

- Add a `northbound-actions` capability that defines action providers, descriptors, targets, invocations, results, and event-handler execution.
- Generalize the current device "Run Task" entry point so it is disabled when no eligible action providers are configured and so Ansible is one provider rather than the model itself.
- Add interface-scoped actions so operators can select one or more interfaces and run external NMS/NCM tasks that need device and interface context.
- Extend approved Wasm plugin metadata with action descriptors, target scopes, input schemas, required context fields, safety metadata, and credential/capability requirements.
- Extend the dynamic configuration UI contract to render action launch forms from a documented schema subset without letting plugins inject arbitrary UI code.
- Add persisted action invocation state, target snapshots, submitted inputs, result summaries, external correlation IDs, and audit events.
- Add event-handler support so ServiceRadar events can invoke northbound actions after target resolution, cooldown, rate-limit, and optional approval checks.
- Update the Go and Rust SDK contracts so plugin authors can define action descriptors, decode invocation context, validate inputs, and return action results.

## Risks and Tradeoffs

### Risks of Doing This Work

- It increases the security surface because ServiceRadar will be able to initiate changes in external systems. The design must require RBAC, explicit provider approval, credential broker use, allowlists, auditing, rate limits, and safe defaults.
- The UI can become too generic if plugins are allowed to describe arbitrary forms. The proposal intentionally limits action forms to a documented schema subset and keeps rendering owned by ServiceRadar.
- Event-triggered remediation can create loops or destructive automation if handlers are not guarded. The first implementation must include cooldowns, dedupe keys, dry-run/confirmation metadata, and clear audit trails.
- SDK and manifest changes create compatibility work for plugin authors. Versioned descriptors and golden fixtures are required so old plugins continue to load.

### Risks of Not Doing This Work

- Ansible-specific concepts will harden into the product architecture and every later integration will copy them with slight differences.
- Operators will not have a consistent audit trail, RBAC model, or result view for actions that change external systems.
- Device and interface remediation will stay manual or be pushed into external automation tools that lack ServiceRadar inventory and event context.
- Event-driven workflows will become a separate later system instead of reusing the same action contract.

## Impact

- Affected specs:
  - `northbound-actions` (NEW)
  - `wasm-plugin-system`
  - `plugin-configuration-ui`
  - `plugin-sdk-go`
  - `plugin-sdk-rust` (NEW)
  - `observability-signals`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/automation/` for action resources, dispatcher, policies, and event handler execution.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/` and interface views for provider-neutral action launch UI.
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/ansible_live/` to adapt Ansible launch into the provider-neutral action registry.
  - `go/pkg/agent/` and Wasm plugin runtime command paths for on-demand action invocation.
  - `go/cmd/wasm-plugins/*` for plugin descriptor examples and fixtures.
  - `~/src/serviceradar-sdk/go` and `~/src/serviceradar-sdk-rust` for action descriptor/result APIs.
- Operator impact:
  - No action appears just because a device exists. Operators see only actions backed by configured, approved, reachable providers.
  - Device and interface action launches get a consistent modal, history, audit, and result model.
  - Event-driven action execution is opt-in and guarded; no automatic remediation runs without an explicit handler.
