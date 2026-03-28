# Change: Add agent fleet release management and verified self-update

## Why
Issue #2406 identifies a broader problem than config polling alone. We already have `add-agent-command-bus` defining a long-lived control stream and push-config delivery, but large fleets still lack a central desired-version model, signed release catalog, staged rollout controls, and safe rollback behavior.

At a fleet size of thousands of edge nodes, manual RPM/DEB upgrades do not scale, and waiting for periodic config polls is too slow for urgent patching. ServiceRadar needs a release-management capability that lets operators publish signed agent releases, target cohorts, push updates immediately to connected agents, and reconcile disconnected agents when they return.

## What Changes
- Add a new `agent-release-management` capability covering:
  - signed release catalog metadata,
  - desired-version targeting,
  - staged/canary rollout policies,
  - per-agent rollout state tracking,
  - verified self-update and rollback semantics.
- Extend agent connectivity so reconnecting agents reconcile against stored desired version and receive pending update instructions over the existing control stream when eligible.
- Extend agent inventory surfaces to expose current version, desired version, rollout state, last update result, and rollout filters for operators.
- Extend operator workflows so inventory and agent-detail views can hand off explicit rollout cohorts into release management, while the releases page exposes supported platform coverage, preflight compatibility preview, disabled invalid submissions, creation-time cohort validation, and per-target diagnostics for rollout failures.
- Define a release verification contract using HTTPS artifact download, SHA256 digest validation, and Ed25519-signed manifests verified by the agent.
- Define a separate updater handoff that preserves RPM/DEB ownership of installed package assets while ServiceRadar manages versioned runtime payloads outside the package manager database.

## Impact
- Affected specs: `agent-release-management` (new), `agent-connectivity`, `agent-registry`
- Affected code:
  - agent/gateway protobufs and control protocol
  - `go/cmd/agent` and related agent packages
  - updater packaging/runtime layout
  - `elixir/serviceradar_agent_gateway`
  - `elixir/serviceradar_core`
  - `elixir/web-ng`
  - `docs/docs`
  - release publishing/signing pipeline
