# Change: Merge device availability evidence into one canonical value in core

## Why

The device inventory shows two availability values that disagree. `/devices`
sorts by `platform.ocsf_devices.is_available`, and the "Available" stat counts
the same column. The Online/Offline badge on each row is computed separately
in web-ng (`DeviceLive.IndexData.Availability.effective_availability/2`) from
fresh `device_agent_availability` rows. On the demo deployment about 40% of
the devices counted as available (roughly 125 of roughly 320) render Offline.
Nearly all of them are Wi-Fi access points imported through the Wi-Fi map
ingestor and also targeted by a sweep group. Their sweep failure counters run
into the thousands.

The root cause is that `is_available` is a shared mutable bit with about a
dozen writers and no arbitration. Each writer applies its own rule and the
last one to write wins:

- the sweep ingestor clears the bit after two consecutive failed probes;
- the Wi-Fi map ingestor sets it again on every sync whenever the controller
  status is "up", and also when the controller reports no status at all.

The column therefore flips on each sweep and each sync. The inventory rollups
follow every flip. The state-change feed publishes only the half of each flip
that comes from the sync path, so it is wrong in a different way. The
hysteresis path rewrites the device row's metadata on every failed sweep. Other writers
apply different defaults. Missing hypervisor status counts as down. A missing
camera status counts as up. An AWX host's `enabled` flag counts as
reachability. Agent check-in sets the bit true, and nothing ever clears it.

## What Changes

- **Availability evidence contract (new).** Each availability source submits
  *evidence* through a single core interface,
  `ServiceRadar.Inventory.Availability.record_evidence/2`. Sources do not
  write the device column. An evidence record carries the source kind, the
  source instance, an **authority class**, the observed state, `observed_at`,
  a freshness TTL, an optional reporter agent, a confirmation count and
  bounded detail. The authority class is declared by the source's
  registration (integration instance, plugin manifest or built-in source
  descriptor). It is never inferred from an integration's name.
- **One resolver, one place.** A pure function in core,
  `Availability.Resolver.resolve/3`, derives each device's availability from
  its fresh evidence. Its precedence depends only on authority class,
  freshness, confirmation (hysteresis) and the device's
  `availability_source_agent_id`. Resolution runs in the same transaction as
  the evidence write. It holds the device row lock and writes the device only
  when the decision changes.
- **Explicit unknown state.** A new `availability_state` column
  (`available | unavailable | unknown`) is the canonical value.
  `is_available` is kept as a compatibility projection: `true` when the state
  is available, `false` when it is unavailable, and `NULL` when it is unknown
  after cutover. The resolver also records the decision's provenance
  (deciding source kind, authority class, reporter agent, decided_at,
  changed_at, and a conflict flag).
- **Consistent readers.** SRQL sort, filters and stats, the inventory rollup
  counts and the device row badge all read the canonical state. The web-ng
  badge override is removed. The device detail page keeps the per-agent sweep
  table and gains an evidence table that explains the decision.
- **Transitions from one emitter.** `device.available` and
  `device.unavailable` events and the `signals.state.ocsf_devices` transition
  feed are emitted by the resolver alone, once per real transition, and name
  the source that decided. Opt-in event emission is preserved.
- **Staged, measurable rollout.** The rollout has four stages, each with its
  own rollback:
  - (a) capture evidence alongside today's writes, with no behavior change;
  - (b) resolve in shadow and publish a divergence report;
  - (c) cut over through a reconciliation pass that suppresses transition
    side effects;
  - (d) remove the direct writers and the web-ng override.
- **BREAKING (after stage d):** `is_available` can be `NULL` for devices with
  no fresh evidence. The Available and Unavailable counts change on existing
  installs where they were inflated by the `DEFAULT true` column and by stale
  writes. Direct writes to `is_available` through Ash actions, the
  `:set_availability` action, or raw SQL stop taking effect.

## Impact

- Affected specs: `device-inventory` (ADDED), `sweeper` (MODIFIED
  "Core Processes Sweep Results via DIRE"), `srql` (ADDED), `build-web-ui`
  (ADDED), `wasm-plugin-system` (ADDED).
- Interacts with the pending `add-per-agent-availability` change, which is
  complete but not archived. That change's "Canonical availability source
  selection" and "Availability source freshness" requirements are refined
  here, so archive it before this one. See design.md, "Relationship to
  pending changes".
- Affected code (implementation is out of scope for this proposal):
  - `elixir/serviceradar_core`: new `inventory/availability/*`.
  - Writers that move onto the evidence interface:
    - `sweep_jobs/sweep_results_ingestor.ex`
    - `wifi_map/batch_ingestor.ex`
    - `edge/agent_gateway_sync.ex`
    - `inventory/sync/{normalize,device_records,device_writes}.ex`
    - `inventory/device_discovery_ingestor.ex`
    - `inventory/hypervisor_enrichment_ingestor.ex`
    - `camera/inventory_ingestor.ex`
    - `composite_checks/evaluation.ex`
  - `inventory/device.ex`, whose accept lists change.
  - `sweep_jobs/availability_events.ex`, which is generalized.
  - `inventory/sync/state_events.ex`.
  - Migrations: an evidence table, device state columns, shadow and audit
    tables, the rollup trigger and a backstop trigger.
- `rust/srql`: devices filters, order and stats; `viz/inventory`.
- `elixir/web-ng`: device list and detail pages, topology availability
  sources, dashboards, the API device JSON, `priv/static/openapi.json` and
  `priv/mcp/srql-cookbook.md`.
- `go/`: mapper publisher, the sweeper `DeviceUpdate` path, the plugin SDK
  `DiscoveredDevice` (in `serviceradar-sdk-go`, vendored), and the
  in-repo plugins that set availability (proxmox, starlink, opentext-nom,
  awx).
- `rust/correlation-engine`: consumes the transition feed, which carries one
  transition per real change after cutover.
