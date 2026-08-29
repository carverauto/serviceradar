# Change: Let a plugin declare the SNMP data it needs

## Why

A WASM plugin cannot poll SNMP, and it never will be able to: the host ABI
exports `udp_sendto` and no receive call, so a guest can emit a datagram and
can never read the reply. Every plugin whose device exposes data only over
SNMP - ClearPass service status and per-node health among them - therefore has
a permanent hole in its coverage that no amount of plugin code closes.

The native SNMP checker can collect that data today. The problem is that
nothing connects the plugin that *knows* which OIDs it needs to the operator
who has to *configure* them. An operator importing a ClearPass plugin is handed
no OIDs, no cadence, no targeting hint - just an empty SNMP profile form and a
vendor MIB to read. The knowledge exists in the plugin author's head and in the
plugin's own dashboards; the configuration burden lands on someone who has
neither.

This is the same gap `alert_rules:` closed for alerting, and the same shape of
fix applies: the plugin declares what it needs, an operator approves it, and
what gets created is an ordinary, fully-editable object rather than hidden
generated state.

### What must not happen

An earlier generation of plugins asked operators to configure API keys at
import time, per plugin. That was rejected: credentials belong in Settings ->
Credential Rules, centrally, once. A plugin-declared SNMP profile must not
reintroduce that pattern through a side door - so a manifest SHALL NOT be able
to express a community string, a v3 username, an auth or priv password, or a
`credential_secret_id`. It declares OIDs; the operator binds the credential.

Equally, this must not become backend-only generated state. If approving a
package silently creates polling configuration that an operator cannot see,
inspect, or edit, the feature has failed even if it technically works.

### Where the collected data has to land

A large share of what a plugin needs from SNMP is **state about a device, not a
number to graph**: ClearPass node version, node role, publisher/subscriber
status, the list of services and whether each is running. `DataPoint.Value` is
an `interface{}` and `string` is a legal `data_type`
(`go/pkg/agent/snmp/types.go:75`), but `timeseries_metrics.value` is a
**non-nullable float** (`timeseries_metric.ex:98-102`). String-valued OIDs
therefore have nowhere to land in the metrics store at all.

So this change needs a device-linked home for SNMP-derived facts, following the
convention `ocsf_devices` already uses for exactly this - a side table keyed
`device_uid` against `ocsf_devices.uid`, exposed as a `has_many`, as
`DeviceRiskContribution`, `BumblebeeDevicePosture`, and
`EndpointInventoryPackage` all do (`inventory/device.ex:786-852`). Numeric OIDs
continue to `timeseries_metrics`; string and enum OIDs become current-state
facts attached to the device that reported them.

## What Changes

- `plugin.yaml` gains an optional top-level `snmp_requirements:` block.
- Each entry materializes, **on package approval**, into two ordinary rows:
  one `snmp_oid_templates` row holding the OID list, and one `snmp_profiles`
  row that is **created disabled, with no credentials and no agents bound**.
- Both appear in the existing `/settings/snmp` UI with a provenance badge.
  There is no new page, no new route, and no new RBAC permission.
- A new `device_snmp_facts` table stores each declared OID's latest value per
  device, keyed `device_uid` -> `ocsf_devices.uid`, so string-valued results
  have a home and every result is attributable to the device it came from.
- Declared OIDs may be `get` or `walk`. Walk mode is already wired end to end -
  `compile_oid/1` emits `mode`/`max_rows`/`walk_timeout_seconds` and
  `build_snmp_oid_config/1` maps them into `Monitoring.SNMPOIDConfig` - so a
  plugin can declare a walked MIB table without any new plumbing.
- Re-approving an upgraded package updates the **OID list only**. Every field
  an operator can tune - enabled, targeting, cadence, credentials, agents,
  priority - is written once at create and never again.

## Impact

- Affected specs: `wasm-plugin-system`, `snmp-profile-management`
- Affected code: `ServiceRadar.Plugins.Manifest`, a new
  `ServiceRadar.Plugins.SNMPRequirementCatalog`, `SNMPProfile` and
  `SNMPOIDTemplate` resources, `packages.ex` approve/deny/revoke hooks, and the
  `/settings/snmp` LiveViews.
- No proto change. No Go agent change. No SNMP compiler change: the
  `oid_template_ids` -> `SNMPCompiler.load_template_oids/2` path and the
  `:snmp_oid_template_config` dependency-catalog entry already deliver a new
  template's OIDs to agents, so writing the rows is the whole delivery
  mechanism.

## Preconditions

Two defects in the existing SNMP path must be fixed **before** the first
plugin-declared profile is enabled against real inventory. Both are pre-existing
and independent of this change, but this change is what makes them bite.

1. **Device names are not sanitized into valid target names.**
   `build_base_target/5` sets `"name" => device.name || device.hostname ||
   device.uid` (`snmp_compiler.ex:547-559`) with no sanitization, while the
   agent's `isValidNameChar` admits only `[A-Za-z0-9_-]`
   (`go/pkg/agent/snmp/config.go:266-270`). Any device whose name is an FQDN -
   which is exactly how ClearPass nodes are named - contains dots and is
   rejected.
2. **Target validation is all-or-nothing.** `ValidateForAgent` returns on the
   first bad target (`config.go:353-356`), and `ApplyProtoConfig` stops the
   running service before invoking the factory, so a rejected config leaves
   SNMP polling dead rather than degraded. One unusable device therefore takes
   out every other profile on that agent, including profiles the operator built
   by hand.

Together these mean a broad `target_query` can silently disable all SNMP
collection on an agent. That is a hard blocker for shipping a feature whose
purpose is to propose broad target queries.


## Open decision: what schedules the poll

Core cannot poll SNMP itself. UDP/161 reachability to device subnets exists only
from an agent, so in every option below the agent performs the request; the
question is only what decides when.

**Option A - the SNMP profile's own cadence (what the specs below assume).**
The materialized profile carries `poll_interval`, the agent's embedded SNMP
checker polls continuously on it, and config reaches the agent through the
existing `:snmp_oid_template_config` dependency-catalog path. Zero new delivery
code, and it is how every SNMP profile already works.

Its weakness is observability. The plugin's declared cadence is only a seed for
a profile field, and there is no per-requirement job an operator can see
running, failing, or retrying - only agent logs.

**Option B - an AshOban trigger per requirement, dispatching to an agent.**
`ProducerSchedule` already establishes this exact pattern: an `oban` block with
a `dispatch_due_producer_schedules` trigger on `scheduler_cron "* * * * *"`,
plus `next_due_at` and a `@schedule_shape_fields` list that forces a recompute
when cadence changes (`producer_schedule.ex:37-63`). Reusing it would give
per-requirement run history, retries, and failure surfacing for free, and would
make the plugin's declared cadence a real schedule rather than a seeded number.

Its cost is a second scheduler for the same work: the agent's SNMP checker is a
continuously-running poller driven by pushed config, so dispatching individual
polls means either bypassing it or replacing how it is driven.

**Recommendation: A for the first slice, with the requirement stored as a
first-class row so B remains reachable.** A ships collection using a path that
already works, and the device-linked facts table is where per-requirement
freshness and last-error become visible - which is most of what B was wanted
for. Moving to B later changes what fires the poll, not what a plugin declares
or where results land, so nothing in the manifest contract has to change.

This is called out rather than silently decided because it is an architectural
fork, not an implementation detail.
