# Change: Add shared add-on profile targeting

## Why
Native add-ons currently depend on per-add-on assignment/config paths, which makes each new add-on feel bespoke and pushes operators toward manual agent targeting. Add-ons need the same SRQL-driven profile model used elsewhere so customers can define intent once and let the control plane materialize safe agent assignments.

## What Changes
- Add reusable native add-on profiles with add-on id/package selection, config JSON, enablement, precedence, and SRQL target query.
- Add a reconciliation path that evaluates profile SRQL, resolves matching devices/agents, and materializes deterministic add-on assignments.
- Add preview/audit surfaces so operators can see matched agents, skipped agents, and the profile that produced each assignment.
- Keep artifact delivery through agent-gateway; agents and add-ons still never access web-ng or JetStream directly.

## Impact
- Affected specs: agent-config, plugin-configuration-ui
- Affected code: `elixir/serviceradar_core` add-on resources/reconciler, `elixir/web-ng` settings UI, agent config generator, SRQL preview helpers, tests/docs.
