# Change: Add declarative agent config dependency catalog

## Why

Agent-delivered configuration currently depends on each UI-backed resource remembering to trigger the right gateway/core invalidation or push path. The Armis credential incident showed that a resource can save successfully in the UI while agents continue using stale or incomplete config because the relationship between that resource and agent config delivery is implicit.

## What Changes

- Add a declarative catalog for resources that affect agent-delivered config.
- Require each catalog entry to declare config type, affected agent selection, compiler/generator dependency, secret handling expectations, and invalidation/push behavior.
- Route resource lifecycle notifications through the catalog instead of one-off notifier calls.
- Add validation/tests that fail when an agent-facing config compiler depends on an Ash resource without a catalog entry.
- Add operational diagnostics so operators can see why a saved UI change should or should not trigger an agent config update.

## Impact

- Affected specs: `agent-config`
- Affected code:
  - `elixir/serviceradar_core` agent config generators and resource notifiers
  - `elixir/serviceradar_agent_gateway` config push/invalidation path
  - `elixir/web-ng` diagnostics for agent-affecting integration/config edits
  - Tests around config generation, invalidation, and resource dependency coverage
