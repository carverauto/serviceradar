## Context

`platform.ocsf_devices.is_available` is the single availability bit read by:

- the device list and the Available and Unavailable stats;
- the inventory rollups;
- SRQL, topology and dashboards;
- composite checks, Armis northbound and the correlation engine.

Many subsystems write it, and none of them arbitrates with the others. Each
writer encodes its own idea of "available", and the last write wins.

### What we saw on demo

On the demo deployment (2026-10-19) the device list showed roughly 320
devices as Available. About 125 of those had an Offline badge. The badge
disagrees because web-ng does not read the column for it; it recomputes the
badge from fresh `device_agent_availability` rows.

About 120 of the 125 are Wi-Fi access points. The Wi-Fi map ingestor imports
them and a sweep group also probes them. Their
`metadata.sweep_consecutive_failures` is in the thousands: every sweep clears
the bit and every Wi-Fi sync sets it again.

### Per-agent results are a product feature, not detail

Production operators deliberately probe the same host from several agents
and care about each agent's own result. A common setup is "reachable from
agent A, not reachable from agent B", where B sits on a segment that NAC/ACL
enforcement should block. B's failure is the *successful* outcome.

Two existing consumers are built on exactly that:

- **Composite checks.** A vantage input carries `expected: "available"` (a
  liveness witness) or `expected: "blocked"` (an isolation probe), and the
  rule generator derives `isolated_verified`, `not_isolated` and similar
  verdicts from them.
- **The Armis northbound updater.** It pushes one chosen agent's result
  (`northbound_availability_source_agent_id`) so that Armis can record which
  devices are isolated or NAC-enforced.

The merged value must therefore sit *on top of* the per-agent ledger. It must
never replace that ledger, and it must not count a blocked result from a
should-be-blocked agent as "down".

### Decision already made by the user

Compute one merged availability in core from all sources, with explicit
precedence. Persist it, and have every reader of "is this device up" use it.
Web-ng stops computing a divergent badge. The design must hold for any
integration: no branch in the merge may name an integration, and a new
integration plugs in by declaring an authority class.

### Constraints

- **CNPG stays the current-state store.** Availability is current state, not
  a metric, so the JetStream-first rule applies only to the transition
  *events*. Those already travel on the internal log publisher and the
  `signals.state.*` feed.
- **Write volume matters.** The advisory-feed WAL storm (#3829) and the
  composite-check refresh cost both came from rewriting rows that had not
  changed. Every write this design adds is write-on-change or bounded by a
  lease.
- **Find every writer.** "Close the path that creates bad data before you
  delete it; find every writer, not the obvious one." The writer inventory
  below was built by searching for the attribute, not for action names.

## Goals / Non-Goals

Goals:

- One merged availability per device, derived in one place in core, so that
  sort order, counts and the badge always agree.
- **Per-agent results stay first-class and lossless.** The per-agent ledger
  keeps every agent's latest result per device, negative results included,
  each with its own timestamp. The merged value is a summary derived from it
  and never rewrites, prunes or ages out ledger rows.
- **Negative-control vantage points.** An agent that is expected to be
  blocked:
  - does not pull the merged value down when it cannot reach the device;
  - raises a policy-violation signal when it can.
- An integration-agnostic evidence contract. Precedence is a function of
  authority class, freshness, confirmation, vantage expectation and
  `availability_source_agent_id`.
- Existing protections stay:
  - hysteresis;
  - "available wins" across vantage agents;
  - the per-device source-agent pin and availability source profiles;
  - reporter-expectation gating for sweeps.
- **Nothing changes silently for Armis northbound.**
  - The agent-selected path behaves exactly as today.
  - The canonical path does not change without an operator choice.
- Every decision can be explained: which source decided, in which class,
  when, and whether other evidence disagreed.
- A staged rollout, whose shadow phase measures which devices would change
  before anything switches.

Non-Goals:

- Changing how any source collects data (probe types, sync cadence,
  controller APIs).
- Changing composite-check semantics, rules, verdicts, coverage or their
  inputs.
- Service-level availability (`service_health`, service state), which is a
  separate entity.
- Time-series availability history. Transitions are events.
- Multitenancy of any kind.

## Data model: two tiers

```
                 TIER 1: per-source ledgers (lossless, latest per key)
  +------------------------------------------+   +-----------------------------------------+
  | device_agent_availability (EXISTING)     |   | device_availability_evidence (NEW)      |
  | key (device_uid, agent_id)               |   | key (device_uid, source_kind,           |
  | every agent's latest probe result,       |   |      source_instance, reporter_agent_id)|
  | up AND down, own checked_at              |   | controllers, hypervisors, cameras,      |
  | read by: composite checks, coverage,     |   | agent liveness, mapper/census,          |
  |   Armis agent path, SRQL per-agent       |   | plugins, inventory, composite verdict   |
  |   filters, device page                   |   |                                         |
  | never pruned/aged/rewritten by the merge |   | write-on-change + lease                 |
  +------------------------------------------+   +-----------------------------------------+
                     |                                         |
                     |   device_vantage_expectations (NEW, materialized
                     |   from enabled composite checks: device, agent,
                     |   expectation reachable|blocked)
                     v                                         v
                 TIER 2: derived summary (resolver is the only writer)
  +-----------------------------------------------------------------------------+
  | ocsf_devices.availability_state  available | unavailable | unknown          |
  | ocsf_devices.availability_decided_by, _changed_at, _conflict                |
  | ocsf_devices.availability_agents  {up, down, stale, total,                  |
  |                                    blocked_verified, policy_violation}      |
  | ocsf_devices.is_available  (compatibility boolean: last decided value)       |
  +-----------------------------------------------------------------------------+
```

### Tier 1a: the per-agent ledger, `device_agent_availability`

This table already exists. It keeps:

- its key, `(device_uid, agent_id)`;
- every column and the existing upsert with
  `WHERE EXCLUDED.checked_at >= checked_at`;
- the `updated_at` statement-clock semantics that composite checks rely on
  for dirty tracking;
- its writers: the sweep ingestor (W4), validation scans (W18) and merge
  reassignment (W19).

This change does not prune, age out or rewrite these rows. The resolver
*reads* them. The ledger is the `active_probe` evidence for each agent.
Keeping it as the store, instead of copying it into the generic evidence
table, means there is one row per agent result and no duplicate writes.

There is exactly one additive column: `consecutive_down smallint NOT NULL
DEFAULT 0`. A `BEFORE INSERT OR UPDATE` trigger on the ledger maintains it
from `OLD` and `NEW` `is_available`, so every ledger writer (W4, W18, W19)
gets the same counter without any change to its code:

- on insert, it is 1 when `NEW.is_available` is false and 0 otherwise;
- on an update whose `NEW.checked_at` is later than `OLD.checked_at` (a new
  observation), it is 0 when `NEW.is_available` is true, 1 when the row goes
  from true to false, and `OLD.consecutive_down + 1` when it stays false,
  capped at the `active_probe` confirmation threshold;
- on any other update (merge reassignment, a replayed result with the same
  `checked_at`, the backfill), the value the statement wrote is kept, which
  is the old value unless the statement sets it.

A separate `AFTER INSERT OR UPDATE` trigger appends the device to the
invalidation log (Decision 1, "Invalidation"). Because it runs on the row that was
actually inserted or updated, an `INSERT ... ON CONFLICT DO UPDATE` that ends
in the update branch is judged as an update, and one whose `WHERE` rejects the
update fires nothing. It enqueues on an insert, on a change of `is_available`
or `consecutive_down`, or on an unchanged renewal whose previous
`OLD.checked_at` is older than half the row's freshness TTL. A steady renewal
of a comfortably fresh, unchanged result enqueues nothing, so each
device-agent pair appends at most once per half-TTL while steady. A renewal
that lands near expiry therefore always appends, and the worker re-resolves
the device even if the expiry job resolved it from the older committed row
before the renewal committed. Neither trigger
touches `is_available`, `checked_at` or `updated_at`, so the ledger's value
and timestamp semantics are unchanged. It carries the
hysteresis count that today lives in the device row's metadata. Existing
readers select named columns or Ash attributes, so the column is invisible to
them.

Ledger freshness is derived, not stored: a row is fresh while `checked_at +
ttl > now`. The TTL is `2 x sweep interval + 5 min` of the row's
`sweep_group_id`, or a 2 h default for rows without a group (validation scans
and legacy rows); 2 h is today's web-ng window. A stale row still exists, is
still shown, and is still read by the Armis agent path exactly as today.

### Tier 1b: the evidence table for every other source, `device_availability_evidence`

| Column | Meaning |
|---|---|
| `device_uid` | canonical device uid (FK, `ON DELETE CASCADE`) |
| `source_kind` | open string for display and grouping (`agent_liveness`, `wifi_map`, `hypervisor`, `camera`, `plugin:<id>`, `mapper`, `census`, `composite_check`, ...). **The resolver never branches on it.** |
| `source_instance` | integration instance, plugin assignment or composite check id; `''` if none |
| `reporter_agent_id` | the agent that relayed the observation, if any; `''` otherwise |
| `authority_class` | Decision 2 |
| `state` | `up` or `down`. A source that cannot tell submits nothing; it never submits "unknown". |
| `observed_at` | source observation time, clamped to `[ingest - max_ttl, ingest]` |
| `expires_at` | `observed_at + ttl` |
| `state_since` | when the current `state` started |
| `confirmations` | consecutive observations of `state`, capped at the class threshold |
| `reporter_eligible` | false when the source says this reporter is not authorized for the target |
| `detail` | bounded jsonb (at most 2 KB), e.g. the controller's raw status |
| `updated_at` | DB clock |

The primary key is `(device_uid, source_kind, source_instance,
reporter_agent_id)`, with indexes on `(expires_at)` and `(device_uid)`.

Agent-originated reachability probes go to the ledger (Tier 1a), not to this
table. The interface below routes them.

### Tier 1c: vantage expectations, `device_vantage_expectations`

This table has the columns `(device_uid, agent_id, expectation reachable |
blocked, check_id, updated_at)` and the key `(device_uid, agent_id,
check_id)`.

It is materialized write-on-change by the composite-check evaluation pass.
That pass already pages through each enabled check's scope and loads its
vantage inputs, so it adds no new scope query. For each device in scope and
each vantage input with an `expected` value, it writes one row. Disabling or
deleting a check, or a device leaving the scope, removes the rows. Every
insert, update or delete of an expectation row appends its device to the
invalidation log (Decision 1, "Invalidation").

This reuses the existing negative-control notion; it does not invent a
parallel one. The `expected` value on a vantage input means "this agent
should reach the device" (`available`) or "this agent should be blocked"
(`blocked`). That is exactly what the rule generator already uses to seed
`isolated_verified` and `not_isolated`.

The design does change one thing: `expected` becomes a read input to the
merged summary. Today it is documented as an authoring aid that the
*composite evaluator* never reads. The evaluator still does not read it, and
its verdicts stay rule-driven. The user confirmed this (Open Question 2).

`sweep_reporter_expectation` is a different concept and stays one.
`expected`, `unexpected`, `unknown` and `legacy` say whether an agent is an
*authorized reporter* for a sweep group's target. They say nothing about
whether the agent *should be able to reach* the device. Reporter
authorization becomes `reporter_eligible`. Reachability expectation comes
only from vantage expectations.

### Tier 2: the derived summary on `ocsf_devices`

New columns:

- `availability_state` (`available | unavailable | unknown`, not null,
  default `unknown`);
- `availability_decided_by` (jsonb: `source_kind`, `source_instance`,
  `reporter_agent_id`, `authority_class`, `rule`, and `previous` with the
  last decided state and its time);
- `availability_changed_at`;
- `availability_conflict` (boolean): fresh evidence that is lower-ranked, or
  excluded by the pin, disagrees with the decision;
- `availability_agents` (jsonb counters: `up`, `down`, `stale`, `total`,
  `blocked_verified`, `policy_violation`, `inconclusive_control`).

`availability_agents` is a summary of the per-agent ledger, so that the list
can show "up from 2 of 3 agents" and SRQL can filter on it without joining.
The ledger remains the source of the per-agent list.

`is_available` becomes a compatibility projection of the state:

| `availability_state` | `is_available` (from stage c) |
|---|---|
| available | true |
| unavailable | false |
| unknown | unchanged: the last decided boolean, or false for a device that has never had a decided state |

Unknown is exposed only through `availability_state` (Decision 6).

## Writer inventory (staging at 36a686236b)

This lists every code path that puts a value into
`ocsf_devices.is_available` or into the per-agent ledger. It was found by
searching for the attribute in Elixir, Go, Rust and SQL.

| # | Writer (file:line) | Path | Semantics today | After |
|---|---|---|---|---|
| W1 | `serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex:2123` `update_device_statuses_available/3` (SET at :2129) | raw SQL | Sets true on any successful probe from an authorized reporter (the pinned agent, or an expected reporter when there is no pin). Every success also writes `last_seen_time`, `modified_time` and the `metadata.sweep_*` keys. | From cutover it writes only the compatibility table (Decision 13) until stage d; the ledger row decides. `last_seen_time` behavior is unchanged. |
| W2 | same file `:2193` `update_device_statuses_with_hysteresis/4` (CASE at :2221) | raw SQL | Increments `metadata.sweep_consecutive_failures` without bound and clears the bit at 2 (`@unavailable_threshold`, :1694). Skips a device under "available wins". Rewrites the row on every failure. | From cutover it computes against the compatibility table (previous value plus `metadata.sweep_*`) until stage d. The resolver's hysteresis uses ledger `consecutive_down` (Decision 5). |
| W3 | same file `:1108` `insert_provisional_device/4` (`is_available: false`, :1122) | Ash create | A newly seeded sweep device starts fail-closed. | Starts `unknown`, and the same pass resolves it. |
| W4 | same file `:1845` `bulk_upsert_agent_availability/1` | `insert_all` into the ledger | Latest per-(device, agent) result. | **Unchanged**; the ledger trigger maintains `consecutive_down`. Becomes the `active_probe` input. |
| W5 | `serviceradar_core/lib/serviceradar/wifi_map/batch_ingestor.ex:949`, `wifi_device_available?/1` at `:1018` | SyncIngestor -> W6 | True for up/ok/online/available/true, **and true when the status is missing**. Re-asserted on every sync. | Evidence from its registration's class; a missing status is no evidence. |
| W6 | `serviceradar_core/lib/serviceradar/inventory/sync/device_writes.ex:1894` (also `normalize.ex:55`, `device_records.ex:74,135`) | `insert_all ... on_conflict` | `COALESCE(EXCLUDED.is_available, d.is_available)`: any non-nil value overwrites. Shared by W5, W7, W8, W12 and W13. | Stops setting the column; routes the value to evidence for the update's source. |
| W7 | `serviceradar_core/lib/serviceradar/inventory/device_discovery_ingestor.ex:271` | SyncIngestor | Plugin `device_discovery.v1` `is_available`. | Evidence with the class from the plugin manifest. |
| W8 | `serviceradar_core/lib/serviceradar/inventory/hypervisor_enrichment_ingestor.ex:1004`, `available_status?/1` at `:1287` | SyncIngestor | online/running/... means true; **missing means false** (the opposite default to W5). | `managing_controller` evidence; a missing status is no evidence. |
| W9 | `serviceradar_core/lib/serviceradar/camera/inventory_ingestor.ex:455`, `:607`, `descriptor_available?/2` at `:1075` | Ash create/update | unavailable -> false; degraded/available -> true; **missing -> `status.available`, default true**. | `managing_controller` evidence; a missing status is no evidence. |
| W10 | `serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex:689`, `:1161` (`:gateway_sync`/`:gateway_restore`) | Ash | An agent hello or control session sets true; **nothing ever sets it false**. | `self_report` evidence, up only, expiring after 3 heartbeats. |
| W11 | `serviceradar_core/lib/serviceradar/composite_checks/evaluation.ex:480` `persist_canonical_availability/2` | `Repo.update_all` | Runs only when `write_canonical_availability` is set: healthy -> true, down -> false. | `operator_policy` evidence. Verdicts and verdict events are unchanged. |
| W12 | `go/pkg/agent/mapper_service.go:282` | mapper -> SyncIngestor | **Always true**, including second-hand LLDP/CDP/ARP neighbours. | `passive_observation` evidence (up only). |
| W13 | Go plugins: `proxmox/discovery.go:20,106`, `starlink/discovery.go:140`, `opentext-nom/result.go:29`, `awx/main.go:3721` (**host `enabled` flag**) | plugin -> W7 | Each maps its own status field. 6 of the 10 in-repo plugins leave it nil. | Manifest-declared class, added in stage a. The awx `enabled` flag is `inventory_declared`, not reachability (Open Question 9). |
| W14 | `serviceradar_core/lib/serviceradar/inventory/device.ex:946` `default true`, plus the baseline column `DEFAULT true` | defaults | **Every create without a value starts available**, including CMDB-only imports. | New devices start `unknown` (with `is_available` false). Until stage d the legacy default still feeds the compatibility table. |
| W15 | `inventory/device.ex` accept lists for `:create` (:341), `:update` (:356), `:gateway_sync` (:363), `:gateway_restore` (:375) and `:set_availability` (:421) | Ash | Any Ash caller can set the column. `:set_availability` has no in-tree caller. | `is_available` removed from the accept lists at stage d. |
| W16 | `serviceradar_core/lib/serviceradar/core/result_processor.ex:162` | `DeviceUpdate` builder | **No live caller.** | Delete at stage d. |
| W17 | `go/pkg/sweeper/sweeper_results.go:121`, `sweeper_aggregators.go:153,213,232` | agent wire | The sweep `DeviceUpdate.IsAvailable` that feeds W1, W2 and W4. | Unchanged; it is the ledger input. |
| W18 | `serviceradar_core/lib/serviceradar/composite_checks/validation/orchestrator.ex:449` `upsert_availability` | Ash, ledger | Validation scans write ledger rows (`checked_at = now`, no group, no reporter metadata, so they read as `legacy`). | **Unchanged.** The ledger stays lossless, and the ledger trigger maintains `consecutive_down` for these rows too. They count as eligible probe results with the default TTL, exactly as web-ng counts them today. |
| W19 | `serviceradar_core/lib/serviceradar/inventory/identity/reassignments.ex:159` `reassign_availability` (merge transaction, `merge_engine.ex:439`) | Ash, ledger | Moves ledger rows to the merge survivor; on an agent collision the survivor's row is kept. | **Unchanged.** The survivor is re-resolved in the same transaction (Decision 11). |
| W20 | `go/pkg/models/service_registration.go:44,77` | `DeviceUpdate` constructors | `IsAvailable: true`; **no non-test caller**. | Delete with W16. |

Related paths that are not writers:

- `sweep_results_ingestor.ex:1957` `restore_deleted_devices/3` revives
  tombstones; it does not touch availability. The restored device is
  re-resolved in the same pass.
- The `trg_ocsf_devices_inventory_rollup` trigger recounts
  `COALESCE(is_available,false)` on every row update.
- `inventory/sync/state_events.ex:16-90` publishes `is_available`
  transitions for sync writes only. Sweep flips go out only through the
  opt-in `sweep_jobs/availability_events.ex`.

## Decisions

### Decision 1: One evidence interface; only the resolver writes the summary

`ServiceRadar.Inventory.Availability.record_evidence(records, opts)` is the
single entry point for non-ledger sources. The sweep ingestor keeps its
ledger upsert and calls `Availability.resolve_devices(uids, opts)` in the
same transaction. Both paths then run the same steps, in batches of at most
500 devices:

1. Validate each record against its source registration. The authority
   class comes from the registration, never from the caller (Decision 2).
2. Upsert evidence write-on-change (Decision 7). Ledger rows were already
   written by their own writer.
3. `SELECT ... FOR NO KEY UPDATE` the device rows in uid order. Then load the
   devices' ledger rows, evidence rows and vantage expectations, and run the
   pure `Availability.Resolver.resolve/3`. Resolution never reads, locks or
   waits on the invalidation log.
4. Run `UPDATE ocsf_devices ... WHERE` any of `availability_state`,
   `availability_decided_by`, `availability_conflict` or
   `availability_agents` `IS DISTINCT FROM` the new value. The returned old
   and new values determine whether this is a state transition (Decision 8)
   or a display-only change.
5. Insert state transitions into the existing outbox (the pattern from
   #4733) in the same transaction, so a rollback publishes nothing.
   Display-only changes broadcast a UI invalidation and emit no event.

**Invalidation.** Every mutation that can change a resolution appends one
row per affected device to an append-only log,
`availability_invalidations (id bigserial PK, device_uid, enqueued_at)`. The
append is a plain `INSERT`: no `ON CONFLICT`, no read and no lock on any
existing row. A plain insert of a new key never waits on another
transaction's row locks, so no writer (sweep, validation scans, merge
reassignment, pins, expectations) is coupled to the worker or to another
writer through the log, whatever device locks it already holds. The log
carries only mutations whose writer does not resolve inline; writers that
resolve inline (below) are not producers, apart from the ledger trigger,
which cannot tell its writers apart. Sources:

- ledger writes, through the ledger's `AFTER` trigger (Tier 1a). This is how
  validation scans (W18) and merge reassignment (W19) reach the resolver
  with no change to their code;
- a change of a device's `availability_source_agent_id`, through an `AFTER
  UPDATE` trigger on that column, and a change to an availability source
  profile, which appends a row for every device that uses the profile;
- a change to a vantage expectation (Tier 1c), through a trigger on that
  table.

**The worker.** A bounded resolver worker (Oban) drains the log. Each pass,
in one transaction:

1. Claims the oldest visible log rows: `DELETE FROM availability_invalidations
   WHERE id IN (SELECT id ... ORDER BY id LIMIT n FOR UPDATE SKIP LOCKED)
   RETURNING device_uid`. Rows inserted by transactions that have not
   committed are invisible to the claim and are not consumed, so gaps in the
   id sequence need no special handling; those rows are claimed by a later
   pass once they commit. `SKIP LOCKED` only lets concurrent passes share
   the log; writers never lock log rows.
2. Deduplicates the claimed uids, takes at most 500 devices, and resolves
   them through steps 3-5 of the resolution steps above, locking device rows in uid order. Any
   claimed uid beyond the batch limit is appended again before commit.
3. Commits. A rollback restores the claimed rows.

The worker follows the mode: it consumes rows without resolving in `legacy`
and writes the shadow table in `shadow`. It writes on change only and is the
same single emitter of transitions. Expiry stays a separate sweep
(Decision 4).

No invalidation is lost:

- A writer that committed before the claim is visible to the input reads (resolution step 3),
  which run after the claim in later statements (each takes a new snapshot).
- A writer that commits after the claim left its own log row unclaimed, so
  the next pass re-resolves the device from the newer inputs.
- A resolution that reads inputs which already include a not-yet-claimed
  invalidation is simply repeated by the next pass, as a write-on-change
  no-op.

**Inline resolution is part of the contract.** The sweep ingestor,
`record_evidence/2` and the merge transaction always resolve their devices
in their own transaction through `resolve_devices/2`, which follows steps
3-5 and never touches the log. Generic evidence writes go only through
`record_evidence/2`, so they are never left unresolved and append nothing to
the log. Ledger-trigger rows appended by an inline-resolving writer stay for
the worker, whose later pass is a write-on-change no-op. The only lock ordering that remains is the existing
one on device rows (uid order). Exact lock behavior, including merge
reassignment against the worker, is verified by implementation-phase
concurrency tests (tasks 5.6a and 5.6b).

Alternatives considered:

- *Read-time computation* (a view or SRQL join). Rejected: sorting and
  counting a large inventory would join three tables on every render, the
  rollups could not be maintained incrementally, and every external reader
  would need the join.
- *Copying ledger rows into the evidence table.* Rejected: it duplicates
  every sweep write and creates a second per-agent store that could drift
  from the one that composite checks and Armis read.
- *Keeping counters in `ocsf_devices.metadata`*, as today. Rejected: that
  rewrites the wide device row and fires the rollup trigger for every
  observation.

### Decision 2: Authority classes are declared by source registration

The resolver knows ranked classes, not integrations:

| Rank | Class | Meaning | Asserts | Confirmations for `down` |
|---|---|---|---|---|
| 1 | `operator_policy` | An operator rule decides availability for its scope: today, a composite check with `write_canonical_availability`. A per-device agent pin outranks it (Decision 3, step 3). | up, down | 1 |
| 2 | `self_report` | The device itself checks in (agent or gateway liveness, an on-device plugin). | up only | n/a |
| 3 | `managing_controller` | A system that manages the device and reports its operational state first-hand: a Wi-Fi controller for its APs, a hypervisor for its guests, an NVR/VMS for its cameras, an operator API for satellite terminals, an NMS for the devices it polls. | up, down | 1 |
| 4 | `active_probe` | Reachability from a vantage agent: the per-agent ledger. | up, down | 2 (today's threshold) |
| 5 | `passive_observation` | A second-hand sighting: ARP/NDP census, a mapper neighbour, flow presence. | up only | n/a |
| 6 | `inventory_declared` | An administrative or CMDB record: AWX `enabled`, a NetBox status, a static file import. | up, down | 1 |

How a class is assigned:

- A built-in source declares its class in a descriptor that its ingestor
  owns. A wasm plugin declares it in its manifest
  (`availability_authority`).
- An integration instance can *lower* its type's class. For example, a Wi-Fi
  map instance fed by a static file is `inventory_declared`, while one fed by
  a live controller API is `managing_controller`. An instance can never
  raise the class.
- An undeclared source is `inventory_declared`.
- An up-only class never writes a `down` row. Expiry retires it, which is
  how an agent that stops checking in, or a census sighting that ages out,
  stops holding a device up.
- A new integration plugs in by registering `{source_kind, authority_class,
  default_ttl, min_ttl, max_ttl}`. The resolver has no source-kind branch.

Why `managing_controller` outranks `active_probe`: a controller observes the
device's operational state, while a probe observes reachability from one
vantage point, and reachability is often blocked by design. A failed probe
against a device its controller reports as up is therefore a reachability
finding. It is kept in the ledger, counted in `availability_agents`, flagged
by `availability_conflict` and shown in the UI. It does not overturn the
controller.

### Decision 3: Precedence

`resolve(device, inputs, now)` works in these steps.

**Step 1. Fresh and eligible.**
- Evidence rows: drop those with `expires_at <= now` and those with
  `reporter_eligible = false`.
- Ledger rows: drop stale rows and rows whose
  `metadata.sweep_reporter_expectation` is `unexpected` or `unknown`. For the
  pinned agent, drop the row only when it is `unknown`. This is today's
  W1/W2 rule.

**Step 2. Vantage expectations.** Remove from the decision set every ledger
row from an agent that has an expectation of `blocked` for this device.
These rows are classified separately:
- `blocked_verified`: the row is fresh and down;
- `policy_violation`: the row is fresh and up (it also stays in the
  decision set as liveness);
- `inconclusive_control`: there is no fresh row.

Negative controls never pull the merged state down. A fresh `up` row from a
negative control returns to the decision set as an ordinary `active_probe`
`up` row: reaching the device proves it is alive. It is also counted as a
`policy_violation`; see Decision 12.

**Step 3. Pin.** When `availability_source_agent_id` is set (directly or
through an availability source profile), ledger rows from other agents leave
the decision set. They stay in `availability_agents` and in the UI.
`operator_policy` evidence also leaves the decision set: the per-device pin
outranks a composite check's policy (Open Question 5). A pinned-out policy
record that disagrees with the decision sets the conflict flag, exactly as a
pinned-out agent does. The other classes are unaffected. If the pinned agent
is itself a negative control for the device, the pin is ignored for the
decision and the configuration is reported as invalid on the device page and
in the divergence report.

**Step 4. Decisive rows.** An `up` row is decisive immediately. A `down`
row is decisive once its confirmations (ledger `consecutive_down`, or
evidence `confirmations`) reach the class threshold. Below the threshold it
is *pending*.

**Step 5. The governing class.** This is the highest-ranked class that has
any fresh, eligible row in the decision set, decisive or pending.
- If the governing class has a decisive row, it decides.
- If it has only pending rows, the device **keeps its previous state**
  (`rule = hysteresis_hold`).

A pending probe failure therefore cannot fall through to a lower class and
flip the device early. This fixes the mixed-evidence hysteresis hole
(review finding R1).

**Step 6. Available wins within the class.** Inside the deciding class, the
state is `available` if any decisive row is `up`, and `unavailable`
otherwise.

**Step 7. No rows.** With no fresh, eligible row in any class, the state is
`unknown` and `availability_decided_by.previous` keeps the last decision.

**Step 8. Stable provenance.**
- If the previously deciding row is still fresh, eligible, in the deciding
  class and agrees with the decision, it stays the decider.
- Otherwise the most recent agreeing row becomes the decider.

Lease renewals by agreeing sources therefore do not rewrite the device row.
This fixes review finding R5.

**Step 9. Conflict and agent summary.**
- `availability_conflict` is true when fresh decisive evidence outside the
  deciding set disagrees with the decision. That includes lower classes,
  pinned-out agents and pinned-out policy records; it excludes negative
  controls, which have their own counters.
- `availability_agents` counts the ledger rows (`up`, `down`, `stale` and
  `total` over non-control agents) plus the three control counters.

The resolver has no "if source is X" rule; the demo case follows from the
classes. There is no cross-class "available wins": a lower class's `up` never
overrides a higher class's decision, and sets the conflict flag instead (Open
Question 1).

### Decision 4: Freshness

Every evidence row is a lease, `expires_at = observed_at + ttl`. The TTL is
supplied by the source and bounded by its registration. Defaults:

| Class | Default TTL |
|---|---|
| `managing_controller`, `inventory_declared` | 3 x the source's sync interval (fallback 3 h) |
| `self_report` | 3 x the heartbeat interval |
| `passive_observation` | 24 h |
| `operator_policy` | 2 x the check's evaluation interval |
| Ledger rows | derived as in Tier 1a; nothing is stored |

An expiry job (Oban, once a minute, paged on `expires_at` and on ledger
`checked_at` thresholds) re-resolves devices whose evidence expired since the
last run. It runs through the same function and takes the same locks:
for each candidate it takes the device row lock first, then reads the
current committed ledger rows and evidence and re-checks freshness under
that lock, so a renewal that committed before the lock is honored. A renewal
that commits after the expiry pass appended an invalidation (Tier 1a), so the
worker corrects the result. It is
the only path that changes a decision by the passage of time alone, and it
is bounded by the number of expirations. Mutations that change a decision
without new evidence (pins, expectations) go through the invalidation log
(Decision 1).

### Decision 5: Hysteresis and "available wins" are preserved

| Today | After |
|---|---|
| 2 consecutive failures clear the bit (W2) | A ledger row needs `consecutive_down >= 2` to be decisive, and the governing-class hold covers mixed evidence (Decision 3, step 5) |
| Recovery is immediate (W1) | An `up` row is decisive at once |
| "Available wins" across agents, with a window of one sweep interval (W2) | Step 6, with the ledger freshness TTL as the window |
| Reporter expectation gates who may write | Step 1 (eligibility) |
| The unbounded `metadata.sweep_consecutive_failures` | Capped at the threshold on the ledger row by the ledger trigger; the metadata keys remain only for the legacy computation and are stripped at stage e |

### Decision 6: Unknown is a state; the boolean is a compatibility projection

A forced boolean is what produced the bug: "no information" had to be
written either as true (W5's missing status, W9, W14) or as false (W8).

- `unknown` is a value of `availability_state` only. It does **not** project
  to `NULL` (Open Question 3).
- `is_available` keeps its last decided boolean while the device is unknown,
  so existing boolean readers see no new value. A device that has never had
  a decided state carries false. From stage c the column is never NULL: the
  reconciliation writes false where it finds NULL.
- SRQL `is_available:true` and `is_available:false` keep reading the column.
  `availability:unknown` is the only way to find unknown devices.
- Every reader that must distinguish unknown (sort, counts, badge, rollups,
  Armis `merged` semantics) reads `availability_state`.

The stage-b report counts the devices that would become unknown, and how
many of them hold `is_available` true.

### Decision 7: Write amplification and WAL

These writes happen today and change nothing:

- W1 rewrites the device row on every successful probe.
- W2 rewrites it on every failed probe, forever.
- W5, W7 and W8 re-assert the bit on every sync.
- Every device-row UPDATE fires the rollup trigger.

Proposed:

- **Ledger.** Volume is unchanged: one upsert per result, as today. The
  ledger trigger sets one extra smallint column in the same row write.
- **Evidence.** An evidence row is written only when one of these holds:
  - its state or authority class changes;
  - reporter eligibility changes;
  - its TTL shrinks or `expires_at` moves earlier;
  - its confirmations are below the cap;
  - less than half of its lease remains.

  Unchanged observations coalesce, so a steady pair writes about twice per
  TTL. Decision-bearing changes are written immediately (review finding R3).
- **Device row.** It is written only when the state, provenance, conflict
  flag or agent counters change (Decision 1, step 5). Provenance is stable
  (Decision 3, step 8).
- **Sweep metadata.** The legacy writers keep the `metadata.sweep_*` keys
  until stage d, because the compatibility computation needs them
  (Decision 13); stage d stops writing them and stage e strips them. `last_seen_time` behavior is
  unchanged in this change, as the "Device re-sighting" scenario requires.
  Coalescing re-sighting writes is decided for a follow-up change (Open
  Question 10).
- **Rollup trigger.** It fires only when its inputs change: state, type,
  vendor, deletion or retirement.
- **Shadow and compatibility tables.** Both are written on change only.

Net effect: device-row writes driven by availability fall from
O(observations) to O(changes). A flapping pair like the demo's Wi-Fi APs
stops writing anything once it has resolved.

### Decision 8: Transitions come from the resolver, once

- **Events.** After cutover, `device.available` and `device.unavailable` are
  emitted only for state transitions. They use the same event types and the
  same internal log publisher, so the seeded StatefulAlertRule keeps working.
  New attributes: `source_kind`, `authority_class`, `reporter_agent_id`,
  `previous_state` and `conflict`.
- **Display-only changes.** Changes to conflict, agent counters or
  provenance emit no events.
- **Gating.** Emission stays opt-in. A deployment setting gates it, and each
  sweep group's `emit_availability_events` remains as a filter on
  transitions decided by that group's ledger rows (Open Question 6, decided).
  The `signals.state` feed is not gated, as today.
- **State feed.** `signals.state.ocsf_devices` `is_available` and
  `availability_state` transitions are published from the resolver.
  `state_events.ex` stops publishing `is_available` and keeps publishing
  `is_managed`.
- **Policy violations.** These signals already exist as composite-check
  verdicts (`not_isolated`, `inverted_reachability`) and their
  `VerdictEventWriter` events. The resolver does **not** emit a second event
  for them. It only exposes the `policy_violation` counter (Decision 12).

No metric is written to the database. Availability is current state, and its
events travel on JetStream through the existing publishers.

### Decision 9: web-ng and SRQL

- **The badge** reads `availability_state` and shows Online, Offline or
  Unknown. `effective_availability/2` is deleted at stage d.
- **Per-agent visibility is required, not decoration.**
  - The list shows "up from N of M agents" from `availability_agents`
    whenever M > 0. A partial-reachability marker appears whenever any fresh
    non-control agent is down, so the merged badge never hides that a device
    is unreachable from a specific agent.
  - A negative-control indicator shows "blocked as expected (n)" or
    "POLICY VIOLATION: reachable from k agent(s) that should be blocked".
  - The tooltip lists the agents and names the deciding source.
  - The device page keeps the per-agent ledger table, marking each agent's
    role (witness, negative control, pinned, ineligible), and adds an
    evidence table for the non-ledger sources.
- **SRQL.**
  - Keeps `available_from_agent`, `unavailable_from_agent` and
    `availability_source_fresh_within` unchanged; they read the ledger.
  - Adds:
    - `availability:` (available, unavailable, unknown);
    - `availability_class:` and `availability_source:`;
    - `agent_reachability:all|partial|none` and the returned fields
      `agents_up` and `agents_total`;
    - `availability_policy:violation|verified|inconclusive`.
  - The default sort becomes availability rank, then `ip`, then `uid`.
  - `rollup_stats:inventory_summary` adds `unknown`.
  - `is_available` filters and JSON output keep reading the column, which is
    never NULL (Decision 6).

### Decision 10: Staged rollout with a coordinated cutover

`inventory.availability_mode` takes the values `legacy`, `shadow`, `cutover`
and `authoritative`. It is stored in a settings row that writers and the
mirror trigger can read. Writers read the mode inside their transaction while
holding a shared transaction-level advisory lock. Changing the mode takes
that lock exclusively, so the switch waits for in-flight writers to finish
(drain) and no writer can straddle two modes.

**Phasing.** Phase 1 is stages a and b: evidence capture plus shadow mode with
the divergence report, with no behavior change. It ships first and is
reviewed on demo. Phase 2 (stage c cutover, then stage d writer removal)
begins only after that review. Destructive cleanup is a separate stage e,
after the stage-d rollback window.

Three mode-aware pieces exist from stage a until stage e, so that every stage
and every rollback keeps readers, rollups, publishers and Armis consistent:

- **The mirror.** A `BEFORE INSERT OR UPDATE` trigger on `ocsf_devices`
  that, while the mode is `legacy` or `shadow`, sets `availability_state`
  (and `availability_changed_at`, with `availability_decided_by.rule =
  legacy_mirror`) from the projection of `is_available`: true is
  `available`, false is `unavailable`, NULL is `unknown`. In `cutover` and
  `authoritative` it does nothing. Any reader or rollup that reads
  `availability_state` therefore sees exactly the legacy value whenever the
  legacy writers are authoritative.
- **The compatibility table**, `device_availability_legacy` (Decision 13).
  The legacy writers (W1-W3, W5-W11 and the W14 create default) maintain it,
  write-on-change, in every mode until stage d, with their full computation:
  the previous value plus `metadata.sweep_*`. In `legacy` and `shadow` they
  also write `is_available` exactly as today; from `cutover` they write only
  the table and compute against it.
- **The publishers switch with the mode.** In `legacy` and `shadow` the
  legacy publishers (`state_events.ex` for `is_available`,
  `sweep_jobs/availability_events.ex`) emit transitions. In `cutover` no
  per-device transition is emitted. In `authoritative` only the resolver
  emits.

**(a) Capture, mode `legacy`.**
- The ledger gains `consecutive_down` and its trigger. Every non-ledger
  writer also calls `record_evidence/2`, with resolution off. Plugin
  manifests declare their authority class now, so the evidence carries the
  class that will ship.
- The mirror, the compatibility table and the mode setting are created.
- Legacy column writes are unchanged.
- Proof: on the lab deployment, `is_available` and the badges match the
  previous release for a full day, and `availability_state` equals the
  projection of `is_available` for every device. WAL per hour is recorded as
  the baseline.
- Rollback: turn capture off. Evidence can be truncated; the ledger column,
  the mirror and the compatibility table only restate legacy values.

**(b) Shadow, mode `shadow`.**
- The resolver writes `device_availability_shadow` (state, decided_by,
  conflict, agents, computed_at) on change. The mirror still owns
  `availability_state`.
- The divergence report (an admin page and a periodic summary log line)
  counts devices by legacy `is_available`, legacy badge, shadow state,
  deciding `source_kind` and `authority_class`. It also counts:
  - devices that would become unknown, and how many of them hold
    `is_available` true;
  - devices with policy violations;
  - invalid pins.

  Each cell has up to 20 sample uids. A dedicated section covers each Armis
  northbound source in canonical mode: how many linked Armis ids would push
  a different value, in which direction (Decision 13).
- The report runs on demo and the lab deployment. A reviewed report is the
  gate for phase 2.
- Rollback: mode `legacy`; drop the shadow rows.

Stage b as built:

- The sweep ingestor's ledger upsert and status updates are separate autocommit
  statements, so its inline resolution runs in its own transaction right after them,
  for every device whose ledger row was accepted.
- Restores reach the resolver through the log: a trigger appends a restored tombstone,
  and a new device, outside `legacy`. One restore path is a raw upsert that no inline
  call can reach. Merge and unmerge resolve inline.
- `record_evidence/2` locks the device rows before the evidence rows when it will
  resolve, the order a merge holds them in (device rows, then their evidence).
- Before a device's first shadow decision its previous state is the legacy mirror.
- The expiry job keeps `availability_settings.expiry_watermark`, set on entering
  `shadow`, and reads ledger expiries through an index on `checked_at`.
- The report reads at `READ COMMITTED` inside one read-only transaction, so sections
  can differ by concurrent writes.

**(c) Cutover, mode `cutover` and then `authoritative`.** The mode switch to
`cutover` drains the legacy writers. Under that drained boundary, before any
reader is switched, `device_availability_legacy` is seeded from the current
`is_available` of every device, so a device that no legacy writer touches
after cutover still has its legacy value. From then on:
1. Legacy writers no longer write `ocsf_devices.is_available`. They keep
   their full computation against the compatibility table until stage d.
2. The resolver writes device rows with **all** transition side effects
   suppressed: no `device.*` events, no `signals.state` messages and no
   per-device PubSub. This applies to ordinary ingestion as well as to the
   reconciliation job.
3. The reconciliation job re-resolves every device from its current ledger
   rows, evidence and vantage expectations, in uid-ordered batches under the
   same device locks and through the same `resolve_devices/2` path as
   ingestion. It never copies the shadow table, so it cannot restore a
   decision that newer evidence has already superseded. It then refreshes
   the rollups once and reconciles stateful alerts that were opened from the
   flapping state (closing them with a reconciliation reason where the
   device is now available).
4. It emits one summary event: "availability reconciliation: N to
   available, M to unavailable, K to unknown".
5. Only after reconciliation completes does the mode move to
   `authoritative`, which enables normal transition emission.

No legacy write can land on the device column after the switch, and no
per-device transition fires while reconciliation is running.

Rollback from `cutover` or `authoritative`: switch to `legacy`, draining the
same way. Under that drained boundary, `is_available` is restored from
`device_availability_legacy` in uid-ordered pages. The mirror fires on each
restored row, so `availability_state`, the badge, the ordering and the
state-based rollups return to the legacy values together. The legacy
publishers resume with the mode, and Armis sources in `legacy` semantics keep
reading the same compatibility table, which the legacy writers never stopped
maintaining. The ledger and the evidence are untouched.

**(d) Removal.** Gated on Decision 13 having no Armis source left in
`legacy` semantics. Stage d removes code only:
- the legacy writers W1, W2 and W5-W11;
- `is_available` from the Device accept lists, and `:set_availability`;
- `effective_availability/2`, W16 and W20.

Its only migration is additive: the write-violation audit (Open Question 7),
whose down migration drops it. The audit never restores or rejects a write.
An `AFTER UPDATE OF is_available` trigger on `ocsf_devices` appends a row to
`availability_write_violations` (device uid, old and new value, the
statement's application name, time) when the column changes in `cutover` or
`authoritative` without a matching `availability_state` change, and does
nothing else. Writes are prevented in code, not in the database:
`is_available` leaves the Device accept lists, `:set_availability` is
deleted, and a static check fails the build when code outside the resolver
writes the column. An audit that can reject a write needs a bypass for the
writer it trusts, and that bypass becomes the default (CLAUDE.md); an
append-only audit needs none. Stage d keeps the compatibility table, the
mode setting, the mirror and the `metadata.sweep_*` keys intact through an
explicit rollback window of at least one release.

Rollback within the window: revert the stage-d release, including the down
migration. The stage-c writers resume against the retained table, mode
setting, mirror and metadata keys. Compatibility values for devices the
removed writers would have touched are refreshed on each writer's next cycle,
within one sweep and one sync interval, before an optional further rollback
to `legacy` (Decision 10, stage c rollback).

**(e) Cleanup.** Runs only after the stage-d rollback window closes. **This is
the point of no easy return:** once it runs, the legacy values and the
sweep counters are gone and no release can restore legacy behavior. Stage e:
- strips the `metadata.sweep_*` keys (a paged migration);
- drops `device_availability_legacy`, the mirror trigger and the mode
  setting.

Rollback: none beyond restoring a database backup; the window before it is
the rollback path.

### Decision 11: Identity operations

- **Merge.** The ledger reassignment (W19) is unchanged, so per-agent
  consumers see the same rows as today. Evidence rows move to the survivor
  (on a collision, the later `observed_at` wins), and the survivor is
  re-resolved inside the merge transaction, under the device locks the merge
  already holds. The ledger reassignment appends to the invalidation log
  without waiting on anything, so the merge never waits on the worker.

  Note a latent behavior that this change deliberately leaves alone: W19
  keeps the survivor's ledger row even when the merged-away device's row is
  fresher. Changing that would alter what composite checks and the Armis
  agent path read, so it is out of scope here and left for a separate change
  (Open Question 11, decided).
- **Unmerge or split.** Both devices are re-resolved.
- **Soft delete and restore.** Evidence is kept and nothing is re-resolved
  while the device is tombstoned. A restore re-resolves the device in the
  restoring transaction. Resolution never clears a tombstone.

### Decision 12: Negative-control vantage points

These are agents that a composite check expects to be blocked for a device
(Tier 1c).

- **Their down results are excluded from the merged decision** (Decision 3,
  step 2); a block is the expected outcome. **Their up results count as
  liveness** (an ordinary `active_probe` `up` row) and are also flagged as a
  policy violation (Open Question 4).
- **Counted separately**: `blocked_verified`, `policy_violation` and
  `inconclusive_control` in `availability_agents`. These feed the UI and the
  `availability_policy:` SRQL filter.
- **No new alerting.** The violation *event* is the composite check's
  existing verdict (`not_isolated` / `inverted_reachability`, status `down`)
  and its `VerdictEventWriter` output. The merged summary only mirrors it, so
  there is no second alert source and verdict semantics do not change.
- **Reuse.** The expectation comes from the vantage input's `expected`
  field, the same notion the rule generator and coverage already use.
- **Liveness witnesses** (`expected: "available"`) are ordinary probe rows
  in the decision. A witness that is down counts as down, as today.
- **A device whose only fresh probes are negative controls** is `available`
  when one of them reaches it (with the violation flag), and otherwise gets
  its state from the other classes, or `unknown`.

### Decision 13: Armis northbound compatibility

`armis_northbound_runner.ex` `candidates_query/1` has two paths.

- **Agent path**, `agent_candidates_query/2` (an agent is selected through
  `northbound_availability_source_agent_id`). It reads
  `COALESCE(daa.is_available,false)` for that agent from the ledger, with no
  freshness filter. The ledger is not changed by this design (Tier 1a), so
  this path returns identical rows before and after, at every stage. This
  includes isolation reporting from the agent that should be blocked.
- **Canonical path**, `canonical_candidates_query/1` (no agent selected). It
  reads `COALESCE(d.is_available,false)`. A merged value would change what is
  pushed. **No silent change is allowed.**
  - Every Armis source gains `northbound_availability_semantics` (`legacy |
    merged`). Existing sources are set to `legacy` by migration. A new source
    must either select an agent or use `merged`; `legacy` is not offered to
    new sources (Open Question 12).
  - The legacy writers maintain a narrow compatibility table,
    `device_availability_legacy (device_uid, is_available, updated_at)`,
    from stage a until stage d, with their full computation (Decision 10).
    It is seeded from `is_available` under the drained cutover boundary, so
    every device has its legacy value even if no legacy writer runs for it
    again. A canonical path in `legacy` semantics reads that table, so its
    pushes match the pre-change behavior exactly, in every mode.
  - The divergence report shows, per source, the pushes that would change.
    What the source settings show before an operator adopts merged
    semantics is the requirement in
    `specs/sync-service-integrations/spec.md` (this change).
  - Stage d is blocked while any source is still `legacy`. No source is
    switched automatically.
  - In `merged` semantics the path reads `availability_state`, and unknown
    devices are withheld (`missing_availability`) rather than pushed from the
    last decided boolean.
- **Other per-agent consumers, all unchanged** because the ledger is
  unchanged:
  - composite-check evaluation inputs and dirty tracking
    (`evaluation.ex:163-191,449-463`, which depends on ledger `updated_at`);
  - the vantage-point resolver (`resolvers/vantage_point.ex`);
  - coverage (`coverage.ex`);
  - the validation orchestrator's ledger writes (W18);
  - merge reassignment (W19);
  - the SRQL per-agent filters;
  - the Armis population builder's agent branch;
  - the device page's per-agent tab.

## Reader blast radius

About 106 non-test files mention `is_available`. Today the readers assume
four different NULL conventions (NULL counts as false, is excluded, means
unknown, or is never expected). This change does not add a NULL: from stage
c `is_available` is a non-null compatibility boolean holding the last decided
value (Decision 6), and `availability_state` is the only source of unknown.
Each reader below gets one of four dispositions:

- **switch**: read `availability_state` or the provenance;
- **keep**: the boolean semantics still fit;
- **fix**: a latent bug in the reader, fixed before stage c;
- **untouched**: a per-agent ledger reader.

**SE** marks readers that drive side effects.

### SRQL (`rust/srql`)

| Reader | Today | Change |
|---|---|---|
| `query/devices/order.rs:46,65-71,132-138` default sort | `coalesce(is_available,false) DESC, ip, uid` | switch: rank (available, unavailable, unknown), then ip, then uid |
| `query/devices/filters.rs:130`, `filters/params.rs` | `= v` / `<> v`; NULL excluded | keep; add the new filters (Decision 9) |
| `query/devices/filters/availability.rs`, `stats/clauses.rs` (`available_from_agent`, `unavailable_from_agent`, `availability_source_fresh_within`) | ledger `EXISTS` | **untouched** |
| `stats/fields.rs` group key | `COALESCE(is_available,false)` | keep; add the `availability` group key |
| `stats/filters.rs:26-45` grouped NotEq | `(IS NULL OR <> v)` | keep (the column is never NULL from stage c) |
| `stats/rollup.rs` `inventory_summary` | counters total/available/unavailable | switch: add `unknown` |
| `models/inventory.rs:236` JSON | `unwrap_or(false)` | keep; add the state and agent counters |
| `query/viz/inventory.rs:351` | column catalog | add the new fields |
| Rollup trigger and `refresh_device_inventory_rollups()` (baseline; migrations `20260305110000`, `20260306001000`, `20261005120000`) | `COALESCE(is_available,false)`; fires on every update | switch: count by state with an `unknown` key; narrow the `WHEN` clause |

### web-ng (`elixir/web-ng`)

| Reader | Today | Change |
|---|---|---|
| `device_live/index_data/availability.ex` `effective_availability/2` | kept, and no longer read by the badge. The badge reads `MergedAvailability` (`availability_state`, `availability_agents`) | delete the function at stage d |
| `index_data/stats.ex`, `index_view/stats.ex`, `index_view/filters.ex` | rollup counts; Available, Offline and Unknown link to `availability:available`, `availability:unavailable` and `availability:unknown`. A missing rollup `unknown` reads as 0. Quick filters add Unknown and `agent_reachability:partial` | switched with the web-ng cutover |
| `device_live/availability_components.ex`, `availability_data.ex` (per-agent tab, primary-source selector) | ledger rows unchanged. Role labels (decided, pinned, witness, negative control, ineligible) and a non-probe evidence section with the deciding record marked | switched with the web-ng cutover |
| `device_live/availability_data.ex` timeline fallback | canonical `availability_state`; an unknown device keeps an unknown timeline. `device_row_is_available/1` is gone | switched with the web-ng cutover |
| `topology/god_view_stream.ex:2422`, `bitmap_source.ex:233`, `world_health_source.ex:47` | true -> healthy, false -> unavailable, nil -> unknown | keep (already three-valued) |
| `dashboard_live/data/basic_summaries.ex` | active, non-retired rows; available, unavailable and unknown counted from `availability_state` | switched with the web-ng cutover. The inventory rollup's `unknown` key remains the stage-c rollup migration |
| `dashboard_live/data/service_sparklines.ex:65`, `vulnerable_assets.ex:22` | NULL counts as false | keep |
| Authored dashboards (`source_queries.ex`, `visuals.ex`, `DashboardPanelChart.jsx`, `DashboardBuilderCanvas.jsx`), `srql/builder.ex` | boolean pivot | keep `is_available` |
| `srql/catalog.ex` | `availability`, `availability_source`, `availability_class`, `agent_reachability` and `availability_policy` are filter fields, with known values; `availability` is a stats group key. `is_available` stays | switched with the web-ng cutover |
| `api/access.ex`, `controllers/api/device_controller.ex` | `is_available` kept; `availability_state`, `availability_decided_by`, `availability_changed_at`, `availability_conflict` and `availability_agents` added. `status=online`, `offline` and `unknown` filter on `availability_state` | switched with the web-ng cutover |
| `priv/static/openapi.json` (already `boolean \| null`) | generated from the core Device Ash resource | not hand-edited in web-ng. The core resource change adds the fields and documents `is_available` as the last decided value and `availability_state` as the source of unknown |
| `priv/mcp/srql-cookbook.md` | `availability:`, `agent_reachability:` and `availability_policy:` recipes, and the note that `is_available` is the last decided boolean | switched with the web-ng cutover |

### Composite checks, automation and integrations

| Reader | Today | Change |
|---|---|---|
| `composite_checks/evaluation.ex:163-191,449-463`, `resolvers/vantage_point.ex`, `coverage.ex`, `validation/orchestrator.ex` | ledger; **SE** verdict events via `VerdictEventWriter` | **untouched**. The evaluation pass additionally materializes vantage expectations (Tier 1c) |
| `composite_checks/evaluation.ex:480` (W11) | writes the column | becomes `operator_policy` evidence |
| `integrations/armis_northbound_runner.ex` agent path | ledger | **untouched** (Decision 13) |
| `integrations/armis_northbound_runner.ex` canonical path, **SE** push of `not is_available` | `COALESCE(d.is_available,false)` | per-source `legacy` (compatibility table, in every mode) or `merged` (state, with unknown withheld); never switched silently |
| `integrations/armis_northbound_population.ex:150-200` | column or the agent's ledger row; nil withheld | agent branch untouched; canonical branch follows the source's semantics |
| `automation/northbound/target_resolver.ex:173` | raw value in the target snapshot | keep; add the state |
| `automation/ansible/awx_membership_reconciler.ex:679,816` | plugin envelope `is_available`, not the column | untouched |

### Correlation engine (`rust/correlation-engine`)

| Reader | Today | Change |
|---|---|---|
| `delta.rs:3-90` | `signals.state` transitions, published only by the sync path | switch: in `authoritative` the resolver publishes every transition |
| `context_hydrator.rs:116,215` | never sees None because of the SRQL `unwrap_or(false)` | keep; the boolean stays non-null. **SE**: verdicts are published on JetStream |
| `reasoner.rs:108,253` | `Some(false)` means down | keep |

### Other core

| Reader | Today | Change |
|---|---|---|
| `sweep_jobs/sweep_results_ingestor.ex:2192-2273` "available wins" | column, metadata and ledger | removed; moved into the resolver |
| `sweep_jobs/availability_events.ex`, **SE** -> EventRules -> StatefulAlertRule | sweep flips, gated per group | emits only in `legacy` and `shadow`; resolver transitions in `authoritative` |
| `inventory/sync/state_events.ex`, **SE** `signals.state` | sync path only | publishes `is_available` only in `legacy` and `shadow` |
| `inventory/device_pubsub.ex`, **SE** UI invalidation | fired on every W1/W2 touch | fired on any summary change |
| `inventory/device.ex:331` `:available` read action, `:1094` `status_color` | no callers | delete or switch at stage d |
| `camera/inventory_ingestor.ex:860` | carries the value forward | removed with W9 |
| `observability/service_health.ex`, `identity/device_lookup.ex:760` | false positives | none |

### Go

| Reader or producer | Today | Change |
|---|---|---|
| `pkg/models/discovery.go:93` `DeviceUpdate.IsAvailable bool` | always sends false or true, so it cannot say "no opinion" | treated as evidence only where the source registration says the field is meaningful; making it `*bool` is a follow-up |
| `pkg/models/ocsf_device.go`, `pkg/models/device.go` | legacy conversions | keep |
| SDK `DiscoveredDevice.IsAvailable *bool`, `action.go:168` | optional | keep; the class comes from the manifest |

### Side-effect summary

These readers trigger side effects:

- sweep availability events -> StatefulAlertRule (alerts and notifications);
- composite verdict events;
- the `signals.state` feed and correlation verdicts on JetStream;
- the Armis northbound push (scheduled);
- AWX membership (from plugin envelopes);
- DevicePubSub.

Stage c (`cutover` mode) suppresses the first three for the whole
reconciliation window, and every publisher switches with the mode, including
on rollback. Composite verdict events are untouched because
composite inputs are untouched. Armis is covered by Decision 13.

## What could break, and mitigations

| Risk | Mitigation |
|---|---|
| **Alert or notification storm at cutover** | `cutover` mode suppresses every transition side effect until reconciliation finishes, then emits one summary event and reconciles stateful alerts. Stage b sizes the flip in advance. |
| **Available count changes on existing installs** (devices that were "available" only through `DEFAULT true` or stale writes become unknown) | Measured in stage b by source and class; an Unknown stat card and a release note. Boolean readers keep the last decided value (Decision 6). |
| **Hysteresis and "available wins" drift** | The one-to-one mapping in Decision 5, the governing-class hold, the ledger trigger that counts failures for every ledger writer, and table-driven resolver tests built from today's W1/W2 cases. |
| **Devices with no evidence at all** | They become `unknown`, which is visible, filterable and counted in stage b. |
| **Write amplification** | Decision 7. WAL per hour is measured in stages a to c, and stage c must not exceed the stage-a baseline. |
| **API consumers of `is_available`** | The field keeps its name, type and non-null values; unknown devices keep their last decided boolean. The MCP cookbook documents `availability_state` for unknown. OpenAPI is generated from the core Device resource and gains the same fields with that resource, not by a web-ng edit. A boolean `is_available:true` count can exceed the state-based Available count by the unknown devices that last decided true; the release note says so. |
| **Per-agent results lost or reinterpreted** | The ledger is unchanged except for one additive column (Tier 1a). Every per-agent consumer is listed as untouched (Decision 13). One DB-tier test asserts that the Armis agent path returns identical rows before and after resolution. |
| **Negative-control agents dragging devices down** | Their down results are excluded from the decision (Decision 12); a reach counts as liveness and the violation is surfaced through the existing composite verdicts. |
| **Silent change to Armis pushes** | Per-source `legacy` semantics with a compatibility table seeded at cutover and maintained in every mode, a preview, an explicit operator choice, and stage d gated on the choice. |
| **Readers disagree about unknown** | No new NULL is introduced; readers that need unknown switch to `availability_state` (sort, counts, badge, rollups, `basic_summaries`). |
| **The correlation engine sees transitions it never saw before** | Intended; measured on the lab deployment after stage c. |
| **Rollback leaves readers on stale merged values** | The mirror re-derives `availability_state` from `is_available` in `legacy` and `shadow`, the rollback restores `is_available` from the compatibility table under the drain, and publishers switch with the mode (Decision 10). |
| **Lock contention** | Uid-ordered `FOR NO KEY UPDATE`, as W1/W2 already do; batches of at most 500; the device row is updated only on change. |
| **A misdeclared class** | Assigned at registration and capped by the manifest; operators can lower it. Shown on the device page and grouped in the report. |
| **Clock skew** | `observed_at` is clamped. |
| **Expiry job lag** | Bounded and idempotent; a lag metric is published through JetStream. |

## Migration Plan

1. **Stage a:**
   - create `device_availability_evidence`, `device_vantage_expectations`,
     `device_availability_shadow`, `device_availability_legacy` and the
     mode setting (`legacy`);
   - add `device_agent_availability.consecutive_down` (default 0) with its
     trigger, and the `ocsf_devices.availability_*` columns (state defaults
     to `unknown`) with the mirror trigger;
   - set `availability_state` from the projection of `is_available` for
     every device, in pages;
   - add the Armis source attribute `northbound_availability_semantics`,
     with existing rows set to `legacy`.
2. **Backfill:**
   - Set `consecutive_down` from `metadata.sweep_consecutive_failures`,
     capped. Apart from the legacy computation, which keeps using that key
     until stage d, this is its only read.
   - Seed vantage expectations from the current composite checks.
   - Copy composite verdicts into `operator_policy` evidence for checks with
     `write_canonical_availability`.
   - Other sources fill within one cycle each.
3. **Stage c:**
   - seed `device_availability_legacy` from `is_available` under the drained
     cutover boundary;
   - add the rollup `unknown` key and narrow the trigger;
   - run the reconciliation job, which is the only bulk write to
     `ocsf_devices` (it also replaces any NULL `is_available` with false).
4. **Stage d:**
   - add the append-only write-violation trigger and its table (dropped by
     the down migration). The trigger never restores or rejects a write.
5. **Stage e** (after the stage-d rollback window of at least one release):
   - strip the `metadata.sweep_*` keys in pages;
   - drop `device_availability_legacy`, the mirror trigger and the mode
     setting.

### How the demo Wi-Fi case resolves

There are roughly 120 Wi-Fi APs that are counted Available but rendered
Offline. Every one of them has ledger rows from the sweep agents, all down,
with `consecutive_down` at the cap. None of those agents is a negative
control. How each AP resolves depends on its Wi-Fi map evidence:

- **The Wi-Fi map source is registered as a live controller and the row says
  up.** There is `managing_controller` evidence, so the state is
  `available`, decided by the controller, with `availability_conflict` set.
  The list shows Online, "up from 0 of N agents" and the partial-reachability
  marker, so the sweep result is not hidden. The column stops flipping, and
  the row and rollup stop being rewritten.
- **The row has no status.** There is no Wi-Fi evidence, so the probe class
  governs and the state is `unavailable`. Today these APs are counted
  Available.
- **The controller says down.** The state is `unavailable`, decided by the
  controller.
- **The Wi-Fi map source is a static import** (`inventory_declared`). The
  probes outrank it, so the state is `unavailable`, which matches today's
  badge.

The stage-b report on demo (2026-10-24) showed the first case: the APs'
controller reports them up while their sweeps fail, so they resolve
`available`, decided by the controller, with the conflict flag. The user
confirmed this split (the managing controller wins over a failing sweep;
Decision 2). In every case the order, the count and the badge agree. The
few other divergent devices resolve by the same rules.

## Relationship to pending changes

- **`add-per-agent-availability`** (complete, not yet archived) owns the
  per-agent ledger, the pin, the profiles and freshness. This change keeps
  all of those and builds the summary on top of them. Archive that change
  first. This change adds requirements without restating its requirements.
- **`add-armis-northbound-availability-updates`** and the composite-check
  changes: their contracts hold. Decision 13 states the Armis compatibility
  rules.

## Open Questions

Decided by the user (2026-10-19); the design body above reflects each
decision:

- **Q1. Cross-class "available wins". Decided: no.** A fresh `up` from a lower
  class never overrides a decisive `down` from a higher class; it sets the
  conflict flag.
- **Q2. Reading `expected`. Decided: yes.** The merged summary reads the
  composite vantage input's `expected` to identify negative controls. The
  composite evaluator still does not read it.
- **Q3. Unknown projection. Decided: unknown does not project to `NULL`.**
  `is_available` keeps its last decided boolean for reader compatibility,
  and unknown is exposed only through `availability_state`.
- **Q4. A negative-control reach as liveness. Decided: yes.** A negative-control
  agent that reaches the device counts as liveness, and the device carries
  the policy-violation flag.
- **Q8. Never-evidenced devices. Decided: `unknown`.** Inventory presence alone
  is not evidence.
- **Q9. Plugin class location. Decided:** the class lives in the plugin
  manifest. The awx host `enabled` flag is `inventory_declared`, not
  reachability evidence.
- **Q10. Re-sighting writes. Decided: yes, coalesce them** in a follow-up change
  that amends "Device re-sighting"; this change leaves `last_seen_time`
  unchanged. Open PR #5786 (batch device inventory rollups per statement)
  is complementary work on the write cost of availability flips.
- **Q12. Armis default for new sources. Decided:** a new source must select an
  agent or use `merged`. Existing sources keep `legacy` semantics until an
  operator chooses.

Decided by the user (2026-10-24), after the phase-1 review (task 2.6); the
design body above reflects each decision:

- **Q5. Composite precedence. Decided: a per-device agent pin
  (`availability_source_agent_id`) outranks `operator_policy`.** With a valid
  pin, policy evidence leaves the decision set like a pinned-out agent and
  sets the conflict flag when it disagrees (Decision 3, step 3).
- **Q6. Event gating. Decided: a deployment setting**, with each sweep
  group's `emit_availability_events` as a filter on transitions decided by
  that group's ledger rows (Decision 8).
- **Q7. The backstop. Decided: no restoring trigger.** `is_available` leaves
  the Device accept lists, a static check rejects new writers, and a trigger
  only appends a violation row. It never restores or rejects a write,
  because an audit that can reject a write grows a bypass flag (CLAUDE.md).
  Tasks 4.4 and 5.11 follow this.
- **Q11. W19 survivor-wins. Decided: out of scope.** Merge reassignment is
  unchanged; a fresher-row rule, if wanted, is a separate change.
- **Wi-Fi AP split. Decided: the managing controller wins over a failing
  sweep**, which is the resolver's behavior (Decision 2; "How the demo Wi-Fi
  case resolves").

Constraints the user restated with these decisions: per-agent rows are
first-class and are never pruned, collapsed or rewritten (Tier 1a), and the
Armis northbound source stays an explicit per-source choice that never
changes silently (Decision 13).

### Phase-1 review (task 2.6, 2026-10-24)

The divergence report from the demo deployment in `shadow` mode, reviewed
with the user before phase 2:

- Most devices would move from Offline to Unknown: no source holds any
  evidence for them. These are inventory-only records that the legacy
  default or a stale write had left with a boolean.
- A group of Wi-Fi access points would move from Offline to Available: the
  managing controller reports them up while their sweeps fail.
- A small group of automation-inventory hosts would move from Online to
  Unknown: their records are stale and nothing else observes them.
- There were conflicts, as designed, and no policy violations or invalid
  pins.
- The one canonical Armis northbound source is in `legacy` semantics, and
  no pushed value changes.
