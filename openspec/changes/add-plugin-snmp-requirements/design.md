# Design

## D1. Reuse `snmp_oid_templates` + `snmp_profiles`; add no new domain

The seam this change needs already exists and is already wired to agents.

`SNMPProfile.oid_template_ids` (`snmp_profile.ex:272`, `{:array, :uuid}`) is
read by `SNMPCompiler.load_template_oids/2`, which loads `snmp_oid_templates`
rows and flattens their `oids`. `DependencyCatalog` already registers
`:snmp_oid_template_config -> SNMPCompiler`. **Writing a template row already
invalidates the config cache and pushes new SNMP config to affected agents.**

So delivery is free. There is no compiler change, no proto change, no Go
change, no new route, and no new RBAC permission in this proposal. The work is
manifest parsing, one migration, one catalog module, three lines in
`packages.ex`, and a provenance badge.

Rejected alternative: a dedicated `plugin_snmp_requirements` domain with its own
settings page. It would duplicate the SRQL target builder, the agent picker, the
credential picker, and test-connection - and it would produce exactly the
two-places-to-look problem this change is meant to prevent. An operator should
find plugin-proposed SNMP configuration in the same list as their own.

## D2. Three findings that shaped the design

Each was verified against source, and each changed a decision.

**Walk mode is already wired through core.** The fjb tracking note claiming
7.1.1 is "not wired through core, reachable only via local agent JSON" is
stale. `compile_oid/1` emits `mode`/`max_rows`/`walk_timeout_seconds` and
`build_snmp_oid_config/1` maps them into `Monitoring.SNMPOIDConfig`. A plugin
can declare a walked table today, so `mode: walk` is in scope for slice 1
rather than deferred.

**Built-in OID templates are not selectable and are not in the database.**
`BuiltinTemplates.seed!/1` has no caller anywhere in `elixir/` - the only
reference is inside its own moduledoc. And `load_all_templates/1` gives
builtins *synthetic string* ids that the profile form feeds into
`oid_template_ids`, a `{:array, :uuid}` column. Consequence for this design: a
plugin template must be a real row with a real UUID, which is the reliable path
anyway - and this proposal must not depend on builtin selection working.
Fixing that is a separate change.

**The "Custom" tab already renders any non-builtin row.** The custom branch of
the template browser applies no vendor filter, and loads via `list_custom`
(`is_builtin == false`). A plugin-contributed template is therefore visible in
the existing UI with no changes. Only the provenance badge is missing - which is
why the badge is in slice 1 and not deferred.

## D3. Why the alert-rule precedent is followed, and where it is not

`AlertRuleCatalog` (PR #4144) established the shape: materialize on approve,
create inert, split fields into a plugin-owned definition set and an
operator-owned set, and use `nilify_all` rather than cascade so that removing a
package orphans tuned configuration visibly instead of deleting it.

All of that carries over. One thing does not: nothing in `elixir/web-ng/` reads
`stateful_alert_rules.plugin_package_id`, so alert-rule provenance is recorded
and never rendered. For alert rules that is a cosmetic gap. Here it would defeat
the stated purpose - "whatever it creates should surface in the UI so it is
inspectable" - so the badge is a slice-1 requirement.

## D4. Inert twice over

A materialized profile cannot poll, for two independent reasons:

1. `enabled: false`, and `resolve_profile`'s read filter requires
   `enabled == true and is_default == false and not is_nil(target_query)`.
2. Even if enabled, `compile_device_target_with_host` skips every device when
   `valid_credentials?` fails, so an un-credentialed profile compiles to zero
   targets.

Two independent gates, because the failure mode being guarded against - a
package silently starting to probe production inventory on approval - is not
one a single boolean should stand alone against.

## D5. Why results need a device-linked table, not just the time series

`timeseries_metrics.value` is a **non-nullable float**
(`timeseries_metric.ex:98-102`). `DataPoint.Value` is an `interface{}` and
`string` is a legal `data_type` (`go/pkg/agent/snmp/types.go:75`). So an OID a
plugin is entitled to declare - and that the checker will happily collect - has
no representable form in the metrics store.

That is not a corner case for this workload. Of the nine ClearPass node-health
OIDs, four are strings (hostname, version, role) and the service table's useful
column is a name. These are *facts about a device*, not a series to graph: a
node's role changes rarely and matters as current state, and "which services
exist and are they up" is a set, not a scalar.

`ocsf_devices` already has the convention for this. `DeviceRiskContribution`,
`BumblebeeDevicePosture`, and `EndpointInventoryPackage` are all side tables
keyed `device_uid` against `ocsf_devices.uid` and exposed as `has_many`
(`inventory/device.ex:786-852`). `device_snmp_facts` is the same shape, so it
inherits the existing device lifecycle: facts are deleted with their device
rather than becoming orphans keyed to a uid nothing resolves.

The split is by data shape, not by source: numeric OIDs keep going to
`timeseries_metrics` exactly as today, and the facts table is the current-state
surface beside it. Nothing about existing SNMP collection changes.

## D6. Scheduling: the fork, and why the first slice takes the cheaper side

See proposal.md for the decision itself. The design constraint driving it is
that **core cannot poll SNMP**. UDP/161 reachability to device subnets exists
only from an agent, so the agent performs the request under either option and
the only question is what decides when.

Option A rides the agent's embedded checker, which is already a continuously
running poller driven by pushed config - so cadence is a profile field and
delivery is free. Option B reuses `ProducerSchedule`'s AshOban trigger
(`producer_schedule.ex:51-63`) to dispatch individual polls, which buys real
run history and retries but means two schedulers for one job.

The reason A is safe to start with is that the fork is **downstream of the
manifest contract**. What a plugin declares, and where results land, are
identical either way; only the thing that fires the poll differs. Slice 1 can
therefore ship collection on the path that already works without foreclosing B.

## D7. Deferred, with reasons

- **Table/index correlation.** Two walked columns of one MIB table are declared
  independently; nothing states they join on index suffix. That is fjb's open
  7.1.2 (`oid_index` currently rides through as `interface_uid`, semantically
  wrong for a non-interface table). A plugin can declare the walks now;
  downstream still re-derives the join, exactly as today.
- **Derivation rules** (`port > 0 => running`, `used/total => pct`, Timeticks
  / 100). Genuinely valuable, but needs a new evaluation surface in the
  compiler *and* a datapoint shape to hold the result.
- **Per-datapoint provenance.** `timeseries_metrics` does not record which
  template or profile produced a value, so plugin-sourced and operator-sourced
  points are indistinguishable. Pre-existing, unchanged by this.
- **Auto-binding a credential rule** from `credential_kind: snmp`. The operator
  picking it explicitly is the safer default for slice 1.
- **Fixing builtin-template selection** (D2). A real bug; a separate change;
  deliberately not a dependency of this one.
