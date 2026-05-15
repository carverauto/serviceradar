## Context

The current Ansible work introduced useful concepts: cataloged actions, selected inventory targets, and external execution with observable results. Those concepts should not remain Ansible-shaped. ServiceRadar also needs to call external NMS/NCM systems, ticketing systems, CMDBs, and remediation APIs from device, interface, and event context.

The clean model is an action layer above integrations:

- A provider advertises actions.
- The platform determines whether each action is eligible for the current targets and actor.
- The UI renders the launch form from ServiceRadar-owned schema rendering.
- Core persists and dispatches an invocation.
- The provider returns a structured result.
- Observability and audit receive a normalized record independent of the provider.

## Goals

- Make "Run Task" provider-neutral and safe when no provider is configured.
- Support device-scoped and interface-scoped actions.
- Let approved Wasm plugins expose action descriptors without giving plugins arbitrary UI control.
- Persist action execution history with target snapshots and submitted inputs.
- Support future event handlers that invoke the same action contract used by the UI.
- Define SDK changes for Go and Rust plugin authors.

## Non-Goals

- Do not implement the HP Network Automation plugin in this change.
- Do not replace Ansible/AWX execution internals beyond adapting them to the shared action model.
- Do not let plugins render arbitrary HTML, LiveView, JavaScript, or React components.
- Do not build a general-purpose workflow/SOAR engine in the first implementation.
- Do not bypass existing credential broker, RBAC, package approval, or network allowlist controls.

## Terminology

- **Action provider**: A configured integration or approved Wasm plugin package that exposes one or more executable actions.
- **Action descriptor**: A versioned declaration of one action: ID, label, description, scopes, required context, input schema, safety metadata, credential requirements, timeout, and result schema version.
- **Action target**: A normalized target snapshot, usually a device and optionally one or more interfaces or an originating event.
- **Action invocation**: A persisted request to run an action, including actor, provider, descriptor version, targets, inputs, status, result, and external correlation ID.
- **Event handler**: A rule that reacts to an event and creates an action invocation after target resolution and guard checks.

## Data Model Sketch

The exact Ash resources can change during implementation, but the model should separate provider configuration from execution history.

- `ActionProvider`: source type (`ansible`, `wasm_plugin`, future `native`), enabled flag, package/config reference, health, and approved capabilities.
- `ActionDescriptor`: provider ID, stable action ID, version, label, scopes, required context, input schema, safety metadata, and descriptor hash.
- `ActionInvocation`: provider/action references, descriptor hash, source (`user`, `schedule`, `event_handler`), actor or service principal, status, target snapshots, submitted inputs, result summary, external correlation ID, started/completed timestamps, and error classification.
- `ActionInvocationTarget`: one row per device/interface target with per-target status and provider result.
- `ActionEventHandler`: matcher, target resolver, action reference, input template, dedupe/cooldown/rate limits, dry-run or approval mode, and enabled flag.

## Execution Path

1. Web-ng asks core for eligible actions for selected devices or interfaces.
2. Core filters by provider health, descriptor scope, required target fields, actor RBAC, package approval, and configured credentials.
3. Web-ng renders the ServiceRadar-owned launch modal from the descriptor's schema subset.
4. Core validates inputs and target snapshots again before persisting an invocation.
5. Core dispatches the action to the provider.
6. The provider runs through the existing safe execution path, such as an agent-routed Wasm command or an Ansible/AWX client.
7. Core stores the result, emits audit records, and publishes normalized observability events.

## Event Handler Path

Event handlers reuse the same invocation path but add guardrails:

- Match only normalized ServiceRadar events.
- Resolve device/interface targets from event attributes before invocation.
- Use a service principal with explicit action permissions.
- Require dedupe keys and cooldowns.
- Support dry-run and manual approval modes before fully automatic execution.
- Emit an event when the handler suppresses, queues, approves, executes, or fails an action.

## UI Rules

- The inventory "Run Task" button is disabled when no eligible actions exist for the selection.
- The button text can remain operator-friendly, but the modal must show provider-neutral language such as "Run Action" or "Run Task" and list configured actions.
- Provider names may appear as metadata where useful, but the normal device/interface details pages must not become integration-branded panels.
- Action forms must use ServiceRadar components generated from a constrained schema subset: text, number, boolean, enum, multi-select, secret reference, object groups, and read-only context preview.
- Plugins provide descriptors and schemas, not UI code.

## Security

- Action launch requires RBAC per action scope.
- Destructive actions require explicit descriptor metadata and stronger confirmation policy.
- Credentials are referenced through the credential broker and are never returned to the browser.
- Wasm providers still run under package approval, signature verification, resource limits, host-function allowlists, and agent sandboxing.
- All invocations produce audit records with actor, targets, input hashes or redacted inputs, provider, action ID, and result.

## Compatibility

- Existing Ansible launch resources can be adapted as the first provider.
- Existing plugin packages without action descriptors continue to behave as check/discovery plugins.
- Descriptor schema versions allow SDK and runtime evolution without breaking older plugins.
