## 1. Discovery and Schema

- [x] 1.1 Inventory existing Ansible launch resources, device action UI, plugin manifest fields, and Wasm host functions that can be reused.
- [x] 1.2 Define Ash resources for providers, descriptors, invocations, invocation targets, and event handlers.
- [x] 1.3 Add migrations under `elixir/serviceradar_core/priv/repo/migrations/` using the `platform` schema only.
- [x] 1.4 Define redaction and retention policy for action inputs and results.

## 2. Provider and Runtime Contract

- [x] 2.1 Extend plugin manifest validation to accept versioned action descriptors.
- [x] 2.2 Add action descriptor approval review alongside existing plugin capability approval.
- [ ] 2.3 Implement action invocation dispatch for approved Wasm providers through the agent-routed command path.
- [ ] 2.4 Adapt Ansible/AWX launch as a northbound action provider without removing the existing Ansible run history.

## 3. SDK Updates

- [ ] 3.1 Update `~/src/serviceradar-sdk/go` with action descriptor builders, invocation context decoding, input validation helpers, and result helpers.
- [ ] 3.2 Update `~/src/serviceradar-sdk-rust` with equivalent action descriptor, invocation, and result APIs.
- [ ] 3.3 Add shared fixture documents for descriptors, invocation payloads, and result payloads.
- [ ] 3.4 Add SDK compatibility tests that prove old check/discovery plugins still build and run.

## 4. UI

- [x] 4.1 Replace Ansible-specific "Run Task" launch gating with provider-neutral eligibility checks.
- [x] 4.2 Add a reusable device action modal rendered from the descriptor schema subset.
- [x] 4.3 Add interface selection action entry points.
- [ ] 4.4 Add action invocation history and per-target results in device and interface details without integration-specific panels.

## 5. Event Handlers

- [ ] 5.1 Add event handler resources with matcher, resolver, action reference, input template, dedupe, cooldown, and approval mode.
- [ ] 5.2 Implement event-to-target resolution for device and interface context.
- [ ] 5.3 Dispatch approved handler invocations through the same action invocation path as user launches.
- [ ] 5.4 Emit normalized events for handler suppression, approval, execution, success, and failure.

## 6. Validation

- [ ] 6.1 Add unit tests for descriptor validation, eligibility filtering, RBAC, redaction, and target resolution.
- [ ] 6.2 Add LiveView tests for disabled action buttons, device launches, interface launches, and schema-driven forms.
- [ ] 6.3 Add integration tests for a fixture Wasm action provider.
- [x] 6.4 Run `openspec validate add-northbound-action-integrations --strict`.
- [ ] 6.5 Run applicable Elixir, Go, and SDK quality checks before implementation PRs are merged.
