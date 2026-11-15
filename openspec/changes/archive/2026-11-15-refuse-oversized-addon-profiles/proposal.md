# Change: Refuse add-on profiles that select more agents than max_targets

## Why

Add-on profile reconciliation cut the agents a profile's target query selected
down to its `max_targets` (default 10,000) with `Enum.take`, so an add-on was
delivered to an arbitrary subset of the selection and nothing said so. It also
read only the first page of the target query, which SRQL limits to 100 rows
when a request names no limit, so a profile selecting more than 100 agents was
cut down without reaching `max_targets` at all.

The SNMP side already refuses a profile over its limit whole
(`ServiceRadar.SNMPProfiles.TargetLimit`). Add-on profiles follow the same
contract.

## What Changes

- Reconciliation reads the whole target query, a page at a time, and counts
  distinct agents, stopping one past `max_targets`.
- A profile over its `max_targets` is refused whole. It desires no assignments,
  so its existing assignments are disabled as stale. Assignments that belong to
  other profiles or to manual overrides are untouched, so the rest of each
  agent's add-on config is still delivered.
- The refusal is reported on the profile's reconcile summary (`status:
  "refused"` and a message naming the limit and what to do), as a
  `[:serviceradar, :addon_profile, :target_limit_exceeded]` telemetry event on
  every refused reconcile, as a warning logged when the refusal starts or its
  limit changes, and in the add-on profile UI.
- Saving an enabled profile whose target query already selects more agents
  than its `max_targets` fails with the same message.

## Impact

- Affected specs: `agent-config`.
- Affected code: `ServiceRadar.Plugins.AddonProfileReconciler`,
  `ServiceRadar.Plugins.SRQLInputResolver` (`reduce_pages/4`),
  `ServiceRadar.Plugins.AddonProfileOps`, `ServiceRadar.Plugins.AddonProfile`
  (`Changes.CheckAddonProfileTargetLimit`), and the web-ng add-on package page.
- Relation to `distribute-snmp-targets-across-agents`: add-on profile targets
  are the agents' own hosts, so there is no placement choice to make; this is
  the "add-on profile target truncation" follow-up named in its design D13. The
  change does not use `TargetLimit`, which that change retires, so it does not
  need redoing when placement lands. The paged read is the shape that design's
  `TargetPlacement` "targets of a workload (paged)" callback needs.
