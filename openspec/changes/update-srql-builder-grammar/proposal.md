# Change: Integrate SRQL builder for network sweep targeting rules

**Status: In Progress** (2026-01-11)

## Why
The network sweep UI needs a complete visual query builder for device targeting. The existing SRQL builder already supports stacking multiple filter conditions (implicit AND semantics), which covers production use cases like "devices with discovery_sources containing 'armis' in partition 'datacenter-1'". Rather than adding OR group syntax to the SRQL grammar, we can leverage the existing builder capabilities directly in the sweep targeting UI.

## What Changes
- Integrate the existing SRQL query builder component into the network sweep group targeting UI.
- Ensure the targeting rules UI supports the full set of device fields and operators already available in TargetCriteria (discovery_sources, partition, tags, IP CIDR/range, etc.).
- Update the criteria-to-SRQL conversion to handle all operators consistently.
- Add preview device counts using the generated SRQL query.

## Impact
- Affected specs: srql (documentation only - no grammar changes)
- Affected code:
  - `serviceradar_core/lib/serviceradar/sweep_jobs/criteria_query.ex` (new shared module)
  - `serviceradar_core/lib/serviceradar/sweep_jobs/target_criteria.ex` (enhanced Ash filtering)
  - `serviceradar_core/lib/serviceradar/sweep_jobs/sweep_config_refresh_worker.ex` (new Oban worker)
  - `serviceradar_core/lib/serviceradar/sweep_jobs/sweep_group.ex` (target_hash attributes)
  - `serviceradar_core/lib/serviceradar/agent_config/compilers/sweep_compiler.ex` (use Ash filters)
  - `web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index.ex` (use shared module)
