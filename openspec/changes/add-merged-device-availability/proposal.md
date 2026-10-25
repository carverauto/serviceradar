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

- **The per-agent ledger stays first-class and lossless.**
  `device_agent_availability` keeps every agent's latest result per device,
  including negative results, each with its own timestamp. The merged value
  is a summary derived from it. It never prunes or ages out per-agent rows,
  and writers do not change a row's stored result or timestamps. The only
  schema change to the ledger is one additive hysteresis counter (design,
  "Tier 1a: the per-agent ledger").
- **An evidence contract for every other source.** Non-probe sources submit
  *evidence* through one core interface,
  `ServiceRadar.Inventory.Availability.record_evidence/2`. These are
  controllers, hypervisors, camera managers, agent liveness, passive
  sightings, plugins, inventory records and composite-check policy. Each
  record carries an **authority class** that comes from the source's
  registration (built-in descriptor, plugin manifest or integration
  instance). The class is never inferred from an integration's name.
- **Negative-control vantage points.** An agent that a composite check
  expects to be blocked for a device reuses the existing vantage input
  `expected` notion. Its blocked result is a verified block, not "device
  down". If it can reach the device, that is a policy violation, surfaced
  through the composite check's existing verdict. A blocked result is
  excluded from the merged decision; a reach counts as liveness and carries
  the policy-violation flag.
- **One resolver, one place.** `Availability.Resolver.resolve/3` is a pure
  function. It derives the canonical `availability_state` (`available |
  unavailable | unknown`) from four inputs: authority class, freshness,
  confirmation (hysteresis, including a hold while the governing class has
  only unconfirmed failures) and `availability_source_agent_id`.
  - Resolution runs transactionally, holding the device row lock, and writes
    only on change.
  - `is_available` becomes a compatibility projection of the state: true or
    false, keeping its last decided value while the device is unknown.
    Unknown is exposed only through `availability_state`.
  - The device also records the decision's provenance, a conflict flag and a
    per-agent summary (up, down, stale and total agents; verified blocks;
    policy violations).
- **Consistent readers with per-agent visibility.** SRQL sort, filters,
  stats and the inventory rollups read the canonical state.
  - The device list badge reads the same state.
  - The list shows "up from N of M agents" with a partial-reachability
    marker, so the merged badge never hides a per-agent failure.
  - The existing per-agent SRQL filters and the device page's per-agent
    section are unchanged.
  - The web-ng badge override is removed.
- **Armis northbound compatibility.**
  - The agent-selected path reads the unchanged ledger and pushes exactly
    what it does today.
  - The canonical path (no agent selected) keeps `legacy` semantics through
    a compatibility table until an operator selects an agent or adopts
    merged availability, after seeing a per-source preview.
  - Nothing that is pushed to Armis changes silently.
- **Transitions from one emitter.** `device.available` and
  `device.unavailable` events and the `signals.state.ocsf_devices`
  transitions are emitted by the resolver alone, once per state change.
  Opt-in emission is preserved.
- **A staged, measurable rollout** with a rollback at each stage:
  - (a) capture evidence with no behavior change;
  - (b) run in shadow and publish a divergence report;
  - (c) cut over through a `cutover` mode that drains legacy writers and
    suppresses every transition side effect until reconciliation finishes;
  - (d) remove the direct writers and the web-ng override. Stage d is gated
    on no Armis source remaining in `legacy`, and keeps the compatibility
    objects through a rollback window of at least one release;
  - (e) after that window, drop the compatibility objects and the sweep
    metadata, the point of no easy return.
  - Phase 1 (stages a and b, no behavior change) ships and is reviewed on
    demo before phase 2 (stages c and d) begins.
  - Core moves through stages a to c by itself: it enters `shadow` once the
    running release supports it and cuts over when a set of readiness
    conditions holds, so no customer runs a command. A deployment mode
    control (`auto`, `hold_legacy`, `hold_shadow`), editable in Settings
    and pinnable by a Helm value, holds or rolls back (design.md,
    Decision 10, "Automatic progression").
- **BREAKING (after stage c):**
  - Unknown devices keep their last `is_available` value; readers that need
    unknown must read `availability_state`.
  - The Available and Unavailable counts change where they were inflated by
    `DEFAULT true` or by stale writes.
  - A direct write to `is_available` stays written until the next resolution.
    Stage d only appends a violation row (design.md, Open Question 7).

## Impact

- Affected specs:
  - `device-inventory` (ADDED);
  - `sweeper` (MODIFIED "Core Processes Sweep Results via DIRE");
  - `srql` (ADDED);
  - `build-web-ui` (ADDED);
  - `wasm-plugin-system` (ADDED);
  - `sync-service-integrations` (ADDED, Armis northbound compatibility).
- Builds on the pending `add-per-agent-availability` change (complete, not
  archived), which owns the ledger, the pin, the profiles and freshness.
  Archive that change first. See design.md, "Relationship to pending
  changes".
- Affected code (implementation is out of scope for this proposal):
  - `elixir/serviceradar_core`:
    - new: `inventory/availability/*`;
    - writers: `sweep_jobs/sweep_results_ingestor.ex`,
      `wifi_map/batch_ingestor.ex`, `edge/agent_gateway_sync.ex`,
      `inventory/sync/{normalize,device_records,device_writes}.ex`,
      `inventory/device_discovery_ingestor.ex`,
      `inventory/hypervisor_enrichment_ingestor.ex`,
      `camera/inventory_ingestor.ex`, and `composite_checks/evaluation.ex`
      (which also materializes vantage expectations);
    - other: `integrations/armis_northbound_runner.ex` (canonical path only),
      `inventory/device.ex`, `sweep_jobs/availability_events.ex`,
      `inventory/sync/state_events.ex`;
    - migrations.
  - `rust/srql`: devices filters, order and stats; `viz/inventory`.
  - `elixir/web-ng`:
    - device list and detail pages;
    - dashboards;
    - API device JSON, `priv/mcp/srql-cookbook.md`, and
      `priv/static/openapi.json` (design.md owns how that file was updated).
  - `go/`: plugin manifests for the in-repo plugins that set availability.
  - `rust/correlation-engine`: receives one transition per real change.
- Unchanged by design: every per-agent ledger consumer, namely
  - composite-check evaluation, the vantage resolver and coverage;
  - validation scans;
  - merge reassignment;
  - the Armis agent path;
  - the SRQL per-agent filters;
  - the per-agent device tab.
