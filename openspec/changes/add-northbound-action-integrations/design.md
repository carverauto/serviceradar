## Context

The current Ansible work demonstrated useful concepts: cataloged actions, selected inventory targets, and external execution with observable results. Hardened Ansible launch now also requires reviewed immutable bindings, exact AWX memberships, live preflight, and canonical `AutomationOperation` evidence, so it must remain separate from a generic action adapter. ServiceRadar still needs a provider-neutral way to call external NMS/NCM systems, ticketing systems, CMDBs, and remediation APIs from device, interface, and event context.

The clean model is an action layer above integrations:

- A provider advertises actions.
- The platform determines whether each action is eligible for the current targets and actor.
- The UI renders the launch form from ServiceRadar-owned schema rendering.
- Core persists and dispatches an invocation.
- The provider returns a structured result.
- Observability and audit receive a normalized record independent of the provider.

## Goals

- Make **Run Action** provider-neutral and safe when no provider is configured, separate from canonical Ansible **Launch Playbook**.
- Support device-scoped and interface-scoped actions.
- Let approved Wasm plugins expose action descriptors without giving plugins arbitrary UI control.
- Persist action execution history with target snapshots and submitted inputs.
- Support future event handlers that invoke the same action contract used by the UI.
- Define SDK changes for Go and Rust plugin authors.

## Non-Goals

- Do not implement the HP Network Automation plugin in this change.
- Do not adapt, replace, or dispatch Ansible/AWX execution through the shared action model.
- Do not delete retained Ansible northbound provider, descriptor, invocation, or target evidence in this change.
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

- `ActionProvider`: source type (`wasm_plugin`, future `native`), enabled flag, package/config reference, health, and approved capabilities. Historical `ansible` rows may remain stored but are not operator-eligible providers.
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
6. The provider runs through its approved execution path, such as an agent-routed Wasm command. Canonical Ansible/AWX launch does not enter this path.
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

- The inventory **Run Action** button is visible only with `northbound.actions.launch` and is disabled when no eligible non-Ansible actions exist for the selection.
- The separate inventory **Launch Playbook** button is visible only with `ansible.runs.launch` and navigates explicit selected device UIDs to `/ansible/launch`; neither permission grants the other action.
- The provider-neutral modal uses **Run Action** language and lists only configured, eligible non-Ansible actions.
- Provider names may appear as metadata where useful, but the normal device/interface details pages must not become integration-branded panels.
- Action forms must use ServiceRadar components generated from a constrained schema subset: text, number, boolean, enum, multi-select, secret reference, object groups, and read-only context preview.
- Plugins provide descriptors and schemas, not UI code.
- The generic Action History requires `northbound.actions.view` and excludes retained Ansible-provider invocations. Canonical Ansible operation history requires `ansible.runs.view` and remains the sole operator-facing Ansible history.

## Security

- Action launch requires `northbound.actions.launch` plus provider/action eligibility. `ansible.runs.launch` is not substitute northbound authority.
- Destructive actions require explicit descriptor metadata and stronger confirmation policy.
- Credentials are referenced through the credential broker and are never returned to the browser.
- Wasm providers still run under package approval, signature verification, resource limits, host-function allowlists, and agent sandboxing.
- All invocations produce audit records with actor, targets, input hashes or redacted inputs, provider, action ID, and result.
- Invocation inputs are split into private `input_values` for dispatch and public `redacted_input_values` for UI/audit. Redaction uses descriptor schema hints (`writeOnly`, `sensitive`, `x-sensitive`, `x-serviceradar-sensitive`, `x-serviceradar-redact`, and sensitive `format` values) plus conservative key-name matching for tokens, passwords, credentials, authorization headers, cookies, and private keys.
- Result summaries and per-target provider results are stored only after the same redaction pass. Invocation metadata stores deterministic input/result hashes and the redaction policy version so operators can correlate executions without exposing secrets.

## Compatibility

- Existing Ansible northbound provider, descriptor, invocation, and target rows may remain stored for internal evidence and migration, but operator catalog reads do not synchronize or return Ansible descriptors and operator Action History filters Ansible invocations.
- Canonical Ansible launch and history remain under `ansible.runs.launch` and `ansible.runs.view`; provider-neutral launch and history remain under `northbound.actions.launch` and `northbound.actions.view`.
- Existing plugin packages without action descriptors continue to behave as check/discovery plugins.
- Descriptor schema versions allow SDK and runtime evolution without breaking older plugins.
