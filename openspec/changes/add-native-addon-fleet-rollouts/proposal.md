# Change: Add native add-on fleet rollout policies and truthful health semantics

## Why

Native add-on package approval, desired assignment, and artifact delivery are three
different lifecycle steps, but the product does not make that boundary operable.
Approving a newer package does not advance the concrete package pinned by an existing
direct assignment or add-on profile. Once desired state is changed, delivery and
activation are automatic, but the native add-on UI has no bulk upgrade action,
track-latest policy, canary controls, or rollout progress view. Operators therefore see
"newer approved" without a safe way to converge the fleet.

The fleet health summary is also not an actionable failure count. The live demo's
"Needs attention" total mixed real runtime failures with disconnected agents and stale
status, healthy built-in runtimes that intentionally have no assignment, incompatible
profile targets, and dormant `ephemeral-helper` packages such as the RDP helper. A
single red total cannot distinguish broken desired state from unavailable evidence or
expected inactivity.

## What Changes

- Make `track_latest_approved` the default for native add-on assignments and profiles
  backed by signed, verified first-party packages. Existing first-party sources migrate
  to managed tracking; explicit operator pins and non-first-party sources remain pinned.
- Keep approval separate from desired state: importing or approving a package SHALL NOT
  rewrite assignments in the approval transaction. A newer eligible approved version
  instead creates an asynchronous staged rollout with no operator action required.
- Add native add-on rollout records with a snapshotted target set, canary and batch
  controls, inter-batch soak, fresh model-specific health gates, pause/resume/cancel,
  per-target state, and automatic rollback to the previous desired package on failure.
- Add a bulk upgrade workflow that updates authoritative direct assignments and
  profiles through the rollout coordinator, with compatibility and availability
  preview before execution.
- Make the fleet read model classify rows as `healthy`, `updating`,
  `action_required`, `unavailable`, `expected_inactive`, or `observed_only`, with
  stable reason codes and evidence timestamps.
- Restrict "Needs attention" to actionable desired-state or fresh runtime failures.
  Show stale/unavailable agents, observed-only built-ins, dormant ephemeral helpers,
  and in-progress convergence in separate counters and filters.
- Audit policy changes, rollout transitions, source promotion, and rollback. Existing
  package verification, approval, capability narrowing, and target compatibility
  checks remain mandatory.

## Impact

- Affected specs: `agent-config`, `agent-registry`, `plugin-configuration-ui`
- Affected code:
  - `elixir/serviceradar_core`: native add-on assignment/profile resources, rollout
    resources and coordinator, profile reconciliation, config generation, add-on
    status classification, jobs, authorization, and audit history
  - `elixir/web-ng`: Add-on Fleet summaries/filters, package/profile assignment flows,
    bulk upgrade preview, rollout controls, and rollout detail/history
  - `go/pkg/agent`: model-specific readiness/status details only where the existing
    add-on status contract cannot distinguish ready, dormant, and failed states
  - migrations, API/SRQL exposure, tests, and operator documentation
- Depends on:
  - `add-native-addon-edge-ops` for package approval and observed add-on status
  - `add-addon-profile-targeting` for profile-owned materialized assignments
  - `refactor-addon-lifecycle-operability` for the one-row-per-agent/add-on fleet view
    and config-apply diagnostics
- Related but separate: base-agent rollout behavior remains in
  `agent-release-management`; Wasm plugin assignment upgrades are not changed here.
- Compatibility: existing signed and verified first-party sources become managed and
  may automatically roll to a newer already-approved stable package after migration.
  Existing upload/GitHub sources and explicit operator pins remain `manual_pin`.
