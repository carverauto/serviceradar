# Change: Add policy-driven plugin targeting via SRQL + AshOban reconciliation

## Why
Operators need a safe way to run plugins against dynamic device sets (for example `in:devices type:camera brand:axis`) without giving WASM plugins API credentials or direct SRQL access.

Today plugin assignments are configured directly per agent/package. This does not scale for dynamic inventory-driven targeting and creates manual drift when device membership changes.

## What Changes
- Introduce a `PluginTargetPolicy` control-plane concept that stores:
  - plugin package/version
  - SRQL target query
  - schedule/interval/timeout
  - plugin parameter template
  - enable/disable state and safety limits
  - chunk sizing for high-cardinality targets
- Add an AshOban reconciler job that periodically:
  - executes policy SRQL query as system actor
  - resolves selected devices to agent ownership
  - groups devices per agent and chunks them into bounded batches
  - computes desired plugin assignments from `(policy_id, agent_id, chunk_index)`
  - upserts/deletes assignments deterministically.
- Ensure plugins receive concrete target batches in params; plugins SHALL NOT execute SRQL queries or use control-plane API keys.
- Add UI/API support for policy preview (matched devices count/sample), per-agent distribution visibility, and operational controls.
- Support optional command bus triggers for run-now/reconcile-now, while scheduled AshOban remains source of truth.

## Impact
- Affected specs:
  - `wasm-plugin-system`
  - `ash-jobs`
  - `plugin-configuration-ui`
  - `srql`
- Affected code:
  - Ash resources/actions for plugin target policies and assignment reconciliation
  - AshOban workers + schedules
  - plugin assignment API/UI flows
  - agent config payload generation for policy-derived batched assignments
