## Context

`platform.ocsf_devices.is_available` is the single availability bit that the
device list, the Available and Unavailable stats, the inventory rollups,
SRQL, topology, dashboards, composite checks, Armis northbound and the
correlation engine all read. Many subsystems write it, and none of them
arbitrates with the others. Each writer encodes its own idea of
"available", and whichever writes last wins.

On the demo deployment (2026-10-19) the device list showed roughly 320
devices as Available. About 125 of those rendered an Offline badge, because
web-ng does not read the column for the badge. It recomputes the badge from
fresh `device_agent_availability` rows. About 120 of the 125 are Wi-Fi access
points that the Wi-Fi map ingestor imports and that a sweep group also
probes. Their `metadata.sweep_consecutive_failures` is in the thousands:
every sweep clears the bit and every Wi-Fi sync sets it again.

The user has decided the direction: compute one merged availability in core
from all sources with explicit precedence, persist it, and make every reader
use it. Web-ng stops computing a divergent badge.

The design must hold for any integration. No branch in the merge may name an
integration. A new integration must be able to plug in by declaring an
authority class.

Constraints:

- CNPG remains the current-state store. Availability is current state, not a
  metric, so the hard rule that metrics flow through JetStream applies only
  to the transition *events*. Those already flow through the internal log
  publisher and the `signals.state.*` feed, and keep doing so.
- Write volume matters. The advisory-feed WAL storm (#3829) and the
  composite-check refresh cost both came from rewriting rows that had not
  changed. Every write in this design is write-on-change or bounded by a
  lease.
- "Close the path that creates bad data before you delete it; find every
  writer, not the obvious one." The writer inventory below was built by
  searching for the attribute rather than for action names.

## Goals / Non-Goals

Goals:

- One canonical availability per device, derived in one place in core from
  separately stored evidence, so that sort order, counts and badge always
  agree.
- An integration-agnostic evidence contract. Precedence is a function of
  authority class, freshness, confirmation and
  `availability_source_agent_id`.
- Existing protections stay: hysteresis (anti-flap), "available wins" across
  vantage agents, per-device pinning to a source agent, availability source
  profiles, and reporter-expectation gating for sweeps.
- Every decision can be explained: which source decided, in which class,
  when, and whether lower-ranked evidence disagreed.
- A staged rollout. The shadow phase measures exactly which devices would
  change before anything switches.

Non-Goals:

- Changing how any source collects data (probe types, sync cadence,
  controller APIs).
- Replacing `device_agent_availability` as the per-agent sweep detail store.
  It stays, and composite checks keep reading it.
- Service-level availability (`service_health`, service state). That is a
  separate entity. It is listed among readers only so the boundary is clear.
- Time-series availability history. Transitions are events, and the
  per-source detail tables keep the latest state only.
- Multitenancy of any kind.

## Writer inventory (staging at 36a686236b)

These are all the code paths that put a value into
`ocsf_devices.is_available` today. They were found by searching for the
attribute in Elixir, Go, Rust and SQL. The "Evidence class" column gives the
proposed authority class; see Decision 2.

| # | Writer (file:line) | Path | Semantics today | Evidence class |
|---|---|---|---|---|
| W1 | `serviceradar_core/lib/serviceradar/sweep_jobs/sweep_results_ingestor.ex:2123` `update_device_statuses_available/3` (SET at :2129) | raw SQL `UPDATE` | Sets true on any successful probe from an *authorized* reporter: the pinned agent, or an expected reporter when no pin is set. Also writes `last_seen_time`, `modified_time` and `metadata.sweep_consecutive_failures=0`/`sweep_last_available_at` on every success, whether or not anything changed. | active_probe |
| W2 | same file `:2193` `update_device_statuses_with_hysteresis/4` (CASE at :2221) | raw SQL `UPDATE` | Increments `metadata.sweep_consecutive_failures` on every failed probe, without bound. Clears the bit once the count reaches 2 (`@unavailable_threshold`, :1694). Skips a device that a sweep marked available within one sweep interval, or that has a fresh positive `device_agent_availability` row from an eligible agent ("available wins"). Rewrites the row on every failure, even when the bit is already false. | active_probe |
| W3 | same file `:1108` `insert_provisional_device/4` (`is_available: false`, :1122) | Ash `:create` | A newly seeded sweep device starts fail-closed until W1 or W2 runs. | (none: initial state) |
| W4 | same file `:1845` `bulk_upsert_agent_availability/1` | `insert_all` into `device_agent_availability` | The per-(device, agent) latest observation. It does not write the device column, but it is the input to W2's "available wins" check, to composite checks and to the web-ng badge. | active_probe (detail) |
| W5 | `serviceradar_core/lib/serviceradar/wifi_map/batch_ingestor.ex:949` with `wifi_device_available?/1` at `:1018` | SyncIngestor -> `device_writes` | True when the controller row's status is up/ok/online/available/true. **True when the status is missing.** Re-asserted on every Wi-Fi sync. | managing_controller, or inventory_declared for a static import; see Decision 2 |
| W6 | `serviceradar_core/lib/serviceradar/inventory/sync/device_writes.ex:1894` (with `normalize.ex:55`, `device_records.ex:74,135`) | `insert_all ... on_conflict` | `COALESCE(EXCLUDED.is_available, d.is_available)`: any sync update with a non-nil value overwrites the bit. A nil value keeps it. This is the shared path behind W5, W7, W8, W12 and W13. | per source |
| W7 | `serviceradar_core/lib/serviceradar/inventory/device_discovery_ingestor.ex:271` | SyncIngestor | Plugin `device_discovery.v1` records: the `is_available`/`isAvailable` field as the plugin set it. | declared by the plugin |
| W8 | `serviceradar_core/lib/serviceradar/inventory/hypervisor_enrichment_ingestor.ex:1004` with `available_status?/1` at `:1287` | SyncIngestor | True for online/running/connected/poweredon/ok/available. **False when the status is missing.** This is the opposite default from W5. | managing_controller |
| W9 | `serviceradar_core/lib/serviceradar/camera/inventory_ingestor.ex:455` (create), `:607` (update), `descriptor_available?/2` at `:1075` | Ash `:create`/`:update` | unavailable -> false; degraded/available -> true; **missing -> the plugin status's `available`, default true**. | managing_controller |
| W10 | `serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex:689` (create), `:1161` (update through `:gateway_sync`/`:gateway_restore`) | Ash | Every agent hello or control-session start sets true. **Nothing sets it false when the agent goes away.** | self_report |
| W11 | `serviceradar_core/lib/serviceradar/composite_checks/evaluation.ex:480` `persist_canonical_availability/2` | `Repo.update_all`, write-on-change | Only when a check has `write_canonical_availability: true`: a healthy verdict -> true, down -> false; degraded or unknown leaves the bit alone. | operator_policy |
| W12 | `go/pkg/agent/mapper_service.go:282` | mapper results -> SyncIngestor | **Always true** for every device the mapper publishes, including neighbours learned second-hand through LLDP/CDP or ARP tables. | passive_observation |
| W13 | Go plugins (non-vendored source): `proxmox/discovery.go:20,106` (node online, guest running), `starlink/discovery.go:140` (terminal active), `opentext-nom/result.go:29` (management status and exclude-from-poll), `awx/main.go:3721` (**host `enabled` flag**) | plugin results -> W7 | Each plugin maps its own status field. The awx plugin reports an administrative flag as reachability. The other 6 of the 10 in-repo plugins (alienvault-otx, axis, dusk-checker, netbox, sample-northbound, unifi-protect) leave it nil. | declared per plugin |
| W14 | `serviceradar_core/lib/serviceradar/inventory/device.ex:946` (`default true`) and the baseline column default `DEFAULT true` | Ash and DB default | **Every create that names no value starts available.** This covers devices imported by CMDB-style syncs that never report availability (NetBox, Armis inbound, k8s inventory, passive census). | (none: this is the "no evidence" case) |
| W15 | `inventory/device.ex` accept lists: `:create` (:341), `:update` (:356), `:gateway_sync` (:363), `:gateway_restore` (:375), `:set_availability` (:421) | Ash | Any Ash caller can set the bit directly. `:set_availability` has no in-tree caller apart from the composite bulk form (W11) noted in its docstring. | removed at stage d |
| W16 | `serviceradar_core/lib/serviceradar/core/result_processor.ex:162` | builds a `DeviceUpdate` | A port of the Go result processor. It has **no live caller** in `lib/`. Confirm it is dead and delete it at stage (d) rather than port it. | (dead) |
| W17 | `go/pkg/sweeper/sweeper_results.go:121`, `sweeper_aggregators.go:153,213,232` | agent-side `DeviceUpdate` | Sets the sweep `DeviceUpdate.IsAvailable` that W1, W2 and W4 consume. This is not a separate writer, but its wire field remains the input to the active_probe evidence. | active_probe (input) |

| W18 | `serviceradar_core/lib/serviceradar/composite_checks/validation/orchestrator.ex:449` `upsert_availability` | Ash create/update on `device_agent_availability` | Validation scans write per-agent rows with `checked_at = now`. They carry no `sweep_group_id` and no reporter metadata, so they read as `legacy` expectation. They can trigger W2's "available wins" skip and win web-ng's any-agent-up rule. | active_probe (detail); eligibility must be explicit |
| W19 | `serviceradar_core/lib/serviceradar/inventory/identity/reassignments.ex:159` `reassign_availability` (inside the merge transaction, `merge_engine.ex:439`) | Ash | On a device merge, moves the loser's per-agent rows to the survivor. Where the survivor already has a row for the same agent, the loser's row is destroyed **whichever is fresher**. A merge never recomputes `is_available`. | (identity; must move evidence and re-resolve) |
| W20 | `go/pkg/models/service_registration.go:44,77` | `DeviceUpdate` constructors | `IsAvailable: true` for service devices. **No non-test caller**, so this is dead and should be deleted with W16. | (dead) |

Related paths that are not writers but are affected:

- `sweep_jobs/sweep_results_ingestor.ex:1957` `restore_deleted_devices/3`
  revives tombstones on a sweep sighting. It clears the tombstone, not
  availability, and it stays. The evidence write for a restored device
  happens after the restore, in the same pass.
- The `trg_ocsf_devices_inventory_rollup` trigger (baseline) recounts
  `COALESCE(is_available, false)` on **every** row update. Every flip from
  W1/W2 against W5 therefore also rewrites the rollup counter rows.
- `inventory/sync/state_events.ex:16-90` publishes `is_available` transitions
  to `signals.state.ocsf_devices` for sync writes only. Sweep flips (W1/W2)
  and composite writes (W11) are not published there. Sweep flips are
  published instead, opt-in per sweep group, by
  `sweep_jobs/availability_events.ex`.

## Decisions

### Decision 1: Evidence is stored per source, and only the resolver writes the device

Introduce `platform.device_availability_evidence`, holding one current row
per (device, evidence source):

| Column | Meaning |
|---|---|
| `device_uid` | canonical device uid (FK, `ON DELETE CASCADE`) |
| `source_kind` | open string naming the producing source type (`sweep`, `agent_liveness`, `wifi_map`, `hypervisor`, `camera`, `plugin:<plugin_id>`, `mapper`, `composite_check`, ...). Used for display and grouping. **The resolver never branches on it.** |
| `source_instance` | integration instance, plugin assignment, sweep group or composite check id; `''` when none |
| `reporter_agent_id` | agent that produced the observation, when there is one; `''` otherwise |
| `authority_class` | enum, see Decision 2 |
| `state` | `up` or `down`. A source that cannot tell submits nothing; it does not submit "unknown". |
| `observed_at` | when the source observed the state (source clock, clamped to the ingest time) |
| `expires_at` | `observed_at + ttl`, see Decision 4 |
| `state_since` | when this source first reported the current `state` |
| `confirmations` | consecutive observations of the current `state`, **capped** at the class's confirmation threshold |
| `reporter_eligible` | whether the source considers this reporter authorized for the target (sweep reporter expectation generalized); ineligible rows are kept for display and never decide |
| `detail` | bounded jsonb (at most 2 KB), e.g. the controller's raw status string or the probe modes |
| `updated_at` | DB clock at the write |

The primary key is `(device_uid, source_kind, source_instance,
reporter_agent_id)`. Indexes: `(expires_at)` for the expiry job, and
`(device_uid)`.

Add to `ocsf_devices`:

- `availability_state` (`available | unavailable | unknown`, not null,
  default `unknown`);
- `availability_decided_by` (jsonb: `source_kind`, `source_instance`,
  `reporter_agent_id`, `authority_class`, `rule`);
- `availability_changed_at`;
- `availability_conflict` (boolean): a lower-ranked fresh source disagrees
  with the decision.

`is_available` remains as a projection:

| `availability_state` | `is_available` |
|---|---|
| available | true |
| unavailable | false |
| unknown | NULL (from stage c onward; see Decision 6) |

The single entry point is
`ServiceRadar.Inventory.Availability.record_evidence(evidence_list, opts)`.
It runs one transaction per batch of at most 500 devices:

1. Validate each record against the source registration. The authority class
   comes from the registration, not from the caller (Decision 2).
2. Upsert the evidence rows write-on-change (Decision 7).
3. For the touched devices, `SELECT ... FOR NO KEY UPDATE` the device rows in
   uid order. This is the same lock ordering the sweep ingestor already uses
   (`query_status_update/2`).
4. Load all evidence rows for those devices, run
   `Availability.Resolver.resolve/3` (a pure function), and
   `UPDATE ocsf_devices ... WHERE availability_state IS DISTINCT FROM $new OR
   availability_decided_by IS DISTINCT FROM $new_by`, returning the old and
   new state.
5. In the same transaction, insert transition rows into the existing outbox
   (internal telemetry is published from outbox rows written in
   transactions, #4733). Publishing happens after commit, so a rolled-back
   resolution never emits.

Alternatives considered:

- *Compute availability at read time* (an SRQL join or view over the
  evidence). Rejected: sort and count over a large inventory would join the
  evidence table on every list render. The rollups could not be maintained
  incrementally. Other readers (Armis northbound, topology bitmaps,
  correlation) would each need the join.
- *Keep `device_agent_availability` as the only evidence table* and add
  columns. Rejected: that table is keyed by agent and shaped around sweep
  detail (ports, modes, execution id), and composite checks depend on its
  `updated_at` semantics. A controller or hypervisor has no agent.
  `device_agent_availability` stays as the sweep source's detail store, and
  the sweep source additionally submits evidence.
- *Store evidence as keys in `ocsf_devices.metadata`*, as the sweep counters
  are today. Rejected: every evidence update rewrites the whole wide device
  row and fires the rollup trigger. This is the write amplification the
  design removes.

### Decision 2: Authority classes are declared by source registration and ranked

The resolver knows authority classes, not integrations. These classes are
ranked from highest to lowest:

| Rank | Class | Meaning | Asserts | Confirmations to assert `down` |
|---|---|---|---|---|
| 1 | `operator_policy` | An operator-authored rule decides availability for its scope. Today that is a composite check with `write_canonical_availability`. | up, down | 1 |
| 2 | `self_report` | The device itself reports in: agent or gateway liveness, or a plugin running on the device. | up only. Expiry, not a "down" record, is what retires it. | n/a |
| 3 | `managing_controller` | A system that manages the device's lifecycle and reports its operational state first-hand: a Wi-Fi controller for its APs, a hypervisor for its nodes and guests, an NVR/VMS for its cameras, a satellite operator API for its terminals, a network management system for the devices it polls. | up, down | 1 |
| 4 | `active_probe` | A reachability probe from a vantage agent: sweep ICMP/TCP, an SNMP poll response or timeout. | up, down | 2 (today's `@unavailable_threshold`) |
| 5 | `passive_observation` | A second-hand sighting: an ARP/NDP census entry, a mapper LLDP/CDP neighbour, flow presence. | up only | n/a |
| 6 | `inventory_declared` | An administrative or CMDB record: AWX `enabled`, a NetBox status, a static file import. | up, down | 1 |

Rules about the class:

- A source declares its class in its **registration**. Built-in sources
  declare it in a descriptor module that each ingestor owns. A wasm plugin
  declares it in its manifest (`availability_authority`), and each
  integration instance stores it in its configuration. An instance can
  *lower* the class its type declares. For example, a Wi-Fi map source fed by
  a static file import is `inventory_declared`, while one fed by a live
  controller API is `managing_controller`. An instance can never raise the
  class. A per-record value may also only lower it. An undeclared source
  defaults to `inventory_declared`, which ranks lowest and is the safe
  default.
- "Asserts up only" classes never produce a `down` row. When their evidence
  expires, they simply stop contributing. This is how an agent that stops
  checking in, or a census sighting that ages out, stops holding a device
  available, without the source having to say "down".
- The resolver contains no source-kind branch. A new integration plugs in by
  registering `{source_kind, authority_class, default_ttl}`.

Why `managing_controller` ranks above `active_probe`: a controller,
hypervisor or NVR observes the device's operational state directly. A probe
observes reachability *from one vantage point*, and reachability is often
blocked by design: management VLANs, guest firewalls, cameras on isolated
segments. A failed probe against a device its controller reports as up is a
reachability finding. The resolver keeps it as fresh lower-ranked evidence,
sets `availability_conflict`, and shows it on the device page. It does not
let it overturn the controller.

### Decision 3: Precedence

`resolve(device, evidence, now)`:

1. **Eligible, fresh set.** Discard rows with `expires_at <= now` and rows
   with `reporter_eligible = false`.
2. **Source-agent pin.** When `availability_source_agent_id` is set (directly
   or materialized by an availability source profile), `active_probe` rows
   from *other* agents are removed from the decision set. They remain visible
   as detail. Other classes are unaffected, because the pin selects a
   vantage point, not a source type. This matches today's behavior: only the
   pinned agent's sweep writes the bit (W1/W2), and the web-ng badge reads
   only the pinned agent's row.
3. **Decisive rows.** A `down` row is decisive only when `confirmations`
   reaches its class's threshold. This is the existing hysteresis, now
   applied per source rather than per device. An `up` row is decisive
   immediately, as recovery is today.
4. **Highest class wins.** Take the highest-ranked class that has at least
   one decisive row.
5. **Available wins within a class.** Inside that class, if any decisive row
   is `up` the state is `available`; otherwise `unavailable`. This
   generalizes the sweep "available wins" rule (W2) and today's web-ng
   any-agent-up rule, so one vantage point that can reach the device
   prevents a flap caused by another that cannot.
6. **No decisive row in any class:** the result is `unknown`, unless the
   only fresh rows are non-decisive `down` rows (hysteresis pending). In that
   case the previous state is kept, which matches today's behavior below the
   threshold.
7. **Provenance.** `availability_decided_by` records the deciding row of
   step 4/5 (for `available`, the most recent `up` row; for `unavailable`,
   the most recent `down` row) and the rule
   (`highest_class|pinned_agent|hysteresis_hold`). `availability_conflict`
   is true when a fresh decisive row in a lower class disagrees with the
   decision.

There are no "if source is X" rules. The behavior the demo needs follows
from the classes alone.

Open policy question, flagged for the user: should a fresh `up` from a lower
class override a decisive `down` from a higher class? An example is a
controller reporting an AP disconnected while a probe still reaches the AP.
This design says no: the higher class decides and the conflict flag is set.
The alternative is cross-class "available wins".

### Decision 4: Freshness is a per-row lease

Every evidence row carries `expires_at`. The source supplies a TTL, bounded
by its registration's `[min_ttl, max_ttl]`. Defaults:

- `active_probe`: `2 x sweep interval + 5 min`. The current web-ng badge
  uses a fixed 2 h; the current "available wins" window is 1 x interval.
- `managing_controller` and `inventory_declared`: `3 x the source's sync
  interval`, falling back to 3 h.
- `self_report`: `3 x the agent heartbeat interval`.
- `passive_observation`: 24 h.
- `operator_policy`: `2 x the check's evaluation_interval_seconds`.

An expiry job (Oban, every minute, paged by the `expires_at` index) selects
devices whose rows expired since the previous run and re-resolves them
through the same function, holding the same locks. This is the only path
that changes a decision without new evidence, and it is bounded by the
number of rows that expired.

### Decision 5: Hysteresis and "available wins" are preserved by construction

- *Threshold.* The `active_probe` class needs 2 confirmations before `down`
  is decisive. That is today's `@unavailable_threshold`. The counter lives
  on the evidence row and is capped at the threshold, so the unbounded
  `metadata.sweep_consecutive_failures` disappears.
- *Recovery.* An `up` row is decisive at once, as W1 is today.
- *Multi-agent anti-flap.* Step 5 covers it. The separate "recently marked
  available by another sweep" window in W2 becomes the evidence TTL.
- *Reporter expectation.* The `unexpected` and `unknown` reporter
  expectations become `reporter_eligible = false`. `legacy` and `expected`
  are eligible. The pinned agent is eligible unless its expectation is
  `unknown`, which matches W1/W2's SQL.

### Decision 6: The unknown state and the boolean projection

Forcing a boolean is what produced the bug: "no information" had to be
written as true (W5's missing status, W9, W14) or false (W8). The canonical
state therefore has three values.

`is_available` projection by stage:

- Stages a and b: unchanged. The legacy writers still own it.
- Stage c: `available -> true` and `unavailable -> false`. For `unknown`, the
  value depends on why the device is unknown:
  - **never had evidence** (every row is absent): `NULL`;
  - **evidence aged out** (rows exist but all expired): `NULL`, but the
    previous decision is kept in `availability_decided_by.previous` so the
    UI can show "last known available, 3 h ago".
- SRQL `is_available:true` and `is_available:false` keep their meaning.
  `NULL` matches neither, which is a behavior change: today NULL sorts and
  counts as false (see the readers). A new `availability:unknown` filter
  finds these devices.

The stage-b divergence report counts the devices that would become unknown,
so this impact is measured before cutover. The alternative of keeping the
last value for unknown devices is listed as an open question.

### Decision 7: Write amplification and WAL

Today, writes that change nothing:

- W1 rewrites the device row (with jsonb metadata) on every successful probe
  of every reachable device.
- W2 rewrites it on every failed probe of every unreachable device, forever.
- W5, W7 and W8 re-assert the value on every sync.

Every device row UPDATE also fires the rollup trigger.

Proposed:

- Evidence upsert is **write-on-change with lease renewal**. A row is
  written only when `state` changes, when `confirmations` is still below the
  cap, or when `expires_at - now < ttl / 2`. Each steady source/device pair
  therefore writes about twice per TTL, rather than once per observation. For
  a 5-minute sweep with a 15-minute TTL that is roughly one write per 7
  minutes, and the write is a narrow row on a narrow table.
- The device row is written only when the decision or its provenance
  changes. When several sources agree, the provenance moves to the most
  recent up row only when the previous deciding row expires, not on every
  refresh.
- W1's `last_seen_time`/`modified_time` refresh is a presence signal, not
  availability. The "Device re-sighting" scenario in `device-inventory`
  requires it on every sweep sighting, and this change leaves it alone. It
  stops carrying the `metadata.sweep_*` jsonb rewrite, which is the expensive
  part. Coalescing re-sighting writes is a separate follow-up, because it
  changes that requirement (Open Question 9).
- The rollup trigger changes to fire only `WHEN (OLD.availability_state IS
  DISTINCT FROM NEW.availability_state OR <existing type/vendor/deleted
  predicates>)`. This removes rollup churn from unrelated updates.
- Stage b's shadow table is written on change only, and its divergence
  report is computed by a periodic query. It is not maintained per write.

Expected net effect on a steady deployment: device-row writes caused by
availability drop from O(observations) to O(transitions). Evidence writes are
O(source/device pairs / (TTL/2)). A flapping pair like the demo's Wi-Fi APs
stops writing anything once resolved.

### Decision 8: Transition events and the state feed come from the resolver only

- After stage c, the resolver emits `device.available` and
  `device.unavailable` (the existing event types, still on the internal log
  publisher, so the existing `StatefulAlertRule` keeps working). The
  attributes add `availability_source_kind`, `authority_class`,
  `reporter_agent_id`, `previous_state` and `conflict`.
- **Emission gating** stays opt-in. Today it is per sweep group
  (`emit_availability_events`). The proposal moves it to a deployment
  setting, "Emit device availability transitions", with the per-sweep-group
  flag kept as a scope filter. A transition decided by evidence from a sweep
  group whose flag is off is not emitted, preserving today's behavior for
  those groups. A flag check on the deciding row's `source_instance`
  satisfies this without branching on source kind; see Open Questions.
- `signals.state.ocsf_devices` transitions for `is_available` (and the new
  `availability_state` field) are published from the resolver's returned
  rows. `state_events.ex` stops publishing `is_available`, though it keeps
  `is_managed`. One real transition yields exactly one feed message,
  whichever source caused it.
- `DevicePubSub.broadcast_invalidated/1` fires for devices whose decision
  changed. Today it fires for every row W1/W2 touched.

Availability is current state in CNPG, and the transition events travel on
JetStream through the existing publishers. No metric is written to the
database, so the JetStream hard rule is not engaged.

### Decision 9: web-ng and SRQL read the canonical value

- The device list badge, the stat cards and the sort all read
  `availability_state`. `DeviceLive.IndexData.Availability.effective_availability/2`
  is deleted at stage d. Until then it stays as the legacy path, behind the
  same mode switch.
- The badge has three variants: Online, Offline and Unknown. A conflict
  marker (for example "reachable from 0 of 2 sweep agents") appears when
  `availability_conflict` is set. A tooltip names the deciding source and
  time.
- The device detail page keeps the per-agent sweep table
  (`device_agent_availability`) and adds an "Availability evidence" table:
  one row per evidence record, showing class, state, observed, expires,
  confirmations, eligible and decided-by.
- SRQL:
  - `in:devices` adds the `availability` field
    (`available|unavailable|unknown`), and `availability_source` and
    `availability_class` filters on the provenance.
  - The default device sort becomes availability rank (available,
    unavailable, unknown), then `ip ASC`. Today it is
    `coalesce(is_available,false) DESC, ip ASC`.
  - `rollup_stats:inventory_summary` and `stats ... by is_available` read
    the canonical state, and the summary adds an `unknown` count. The
    rollup tables gain an `unknown` key.
  - `is_available:` filters keep working, with NULL excluded from both
    values.

### Decision 10: Staged rollout with rollback at every stage

A runtime setting `inventory.availability_mode` (`legacy | shadow |
authoritative`) plus code removal in stage d:

- **(a) Capture, `legacy`.** Every writer that produces a value (W1, W2, W4-W13, W18) also calls
  `record_evidence/2` with resolution disabled. The legacy column writes are
  unchanged, so behavior is unchanged. The proof is that the
  `is_available` and badge values match the previous release on the lab
  deployment for a full day.
  Rollback: switch capture off; the evidence table can be truncated freely.
- **(b) Shadow, `shadow`.** The resolver runs and writes
  `device_availability_shadow` (device_uid, state, decided_by, conflict,
  computed_at) on change only. A divergence report is a SRQL-backed admin
  page plus a periodic summary log line. It shows counts by `(legacy
  is_available, legacy badge, shadow state, deciding source_kind,
  authority_class)`, the number of devices that would become unknown, the
  number that would flip, and up to 20 sample device uids per cell. The
  report runs on demo and the lab deployment, and the cutover gate is a
  reviewed report.
  Rollback: switch back to `legacy` and drop the shadow rows.
- **(c) Cutover, `authoritative`.**
  1. A reconciliation job applies the shadow decisions to `ocsf_devices` in
     uid-ordered batches with **transition side effects suppressed**: no
     `device.*` events, no `signals.state` messages, no per-device PubSub.
     It emits one summary event ("availability reconciliation: N to
     available, M to unavailable, K to unknown").
  2. It refreshes the rollup counts once.
  3. Alerts that `StatefulAlertRule` opened from the old flapping state are
     reconciled against the new state, and incidents whose device is now
     available are closed with a reconciliation reason.
  4. Composite checks and Armis northbound read the new value on their next
     scheduled run. Armis northbound gets a one-run preview, because many
     external custom-property writes could follow; see Risks.

  After reconciliation, the legacy writers' column writes are skipped. Each
  writer checks the mode, and `device_writes` drops `is_available` from its
  `on_conflict` set.
  Rollback: switch back to `legacy`. The legacy writers resume on their next
  cycle and re-establish the old values within one sweep and one sync
  interval. The evidence stays and nothing is lost.
- **(d) Removal.** Delete the legacy column writes from W1, W2, W5-W11 and
  W15. Remove `is_available` from the Device accept lists and delete
  `:set_availability`. Delete `effective_availability/2`, the dead
  `ResultProcessor` (W16), and the `metadata.sweep_consecutive_failures` and
  `sweep_last_available_at` keys (in a migration). Remove the mode setting.
  Add the backstop trigger: a BEFORE UPDATE trigger on `ocsf_devices` that,
  when `is_available` or `availability_state` changes outside the resolver
  function, restores the old values and appends a row to
  `platform.device_availability_write_violations`. The trigger **never
  rejects** the statement, and the violations table is append-only. See Open
  Questions on the CLAUDE.md audit guidance.
  Rollback: revert the stage-d PR. The schema is unchanged, so the revert is
  data-compatible.

### Decision 11: Identity operations move evidence and re-resolve

- **Merge** (W19): inside the merge transaction, the loser's evidence rows
  move to the survivor. On a key collision the row with the later
  `observed_at` is kept; today the survivor's row always wins. The survivor
  is then re-resolved in the same transaction. The per-agent rows follow the
  same fresher-wins rule.
- **Unmerge or split**: evidence stays with the device it was keyed to, and
  both devices are re-resolved.
- **Soft delete**: evidence rows are kept, and the device's state is not
  recomputed while it is tombstoned. On a restore (`:restore`,
  `:gateway_restore`, or the sweep restore at `sweep_results_ingestor.ex:1957`)
  the device is re-resolved in the restoring transaction. Re-resolution only
  reads evidence; it never clears a tombstone, so this adds no revival path.
- **Validation scans** (W18) write per-agent rows that state their
  eligibility explicitly. They do not inherit `legacy`.

## Reader blast radius

About 106 non-test files mention `is_available`. Grouped by area, the readers
below assume one of four NULL conventions today: NULL counts as false, NULL
is excluded, NULL means unknown, or NULL is never expected. After cutover the
canonical rule is **NULL means unknown**, with `availability_state` as the
typed source. Every reader is assigned one of three dispositions:

- **switch**: read `availability_state` or decided provenance;
- **keep**: the boolean semantics are still right;
- **fix**: the reader carries a latent NULL bug that unknown would expose.

In the table, **SE** marks a reader that drives a side effect on a
transition or on a scheduled push.

### SRQL (`rust/srql`)

| Reader | Today | Change |
|---|---|---|
| `query/devices/order.rs:46,65-71,132-138` default sort | `coalesce(is_available,false) DESC, ip, uid` | switch: availability rank (available, unavailable, unknown), then ip, then uid |
| `query/devices/filters.rs:130` and `filters/params.rs` `is_available:` | `= v` / `<> v`, NULL excluded | keep; add `availability:` and `availability_class:`/`availability_source:` |
| `stats/fields.rs` group key | `COALESCE(is_available,false)` | switch: group by `availability_state`, keeping the `is_available` key for compatibility, with NULL reported as a separate `null` bucket |
| `stats/filters.rs:26-45` grouped NotEq | `(IS NULL OR <> v)`, so NULL is included. This is inconsistent with the list path | fix: same NULL exclusion as list filters |
| `filters/availability.rs`, `stats/clauses.rs` (`available_from_agent`, `availability_source_fresh_within`) | per-agent `device_agent_availability` | keep, as sweep detail. `availability_source_fresh_within` stays |
| `stats/rollup.rs` `rollup_stats:inventory_summary` | rollup counters (total/available/unavailable) | switch: add `unknown`; counters maintained from `availability_state` |
| `models/inventory.rs:236` JSON output | `unwrap_or(false)`: **NULL serialized as false** | fix: emit `null` and add `availability_state` |
| `query/viz/inventory.rs:351` | column catalog | add `availability_state` |
| Rollup trigger and `refresh_device_inventory_rollups()` (baseline; migrations `20260305110000`, `20260306001000`, `20261005120000`) | `COALESCE(is_available,false)`, so NULL counts as unavailable; fires on every row update | switch: count by state with an `unknown` key, and narrow the `WHEN` clause (Decision 7) |

### web-ng (`elixir/web-ng`)

| Reader | Today | Change |
|---|---|---|
| `device_live/index_data/availability.ex:40-125` `effective_availability/2`, consumed by `index_view/rows.ex:5-14`, then `badges.ex` | fresh (2 h) per-agent rows: pinned agent, else any agent up, else the column; ignores reporter expectation | **delete** at stage d. The badge reads `availability_state` and provenance |
| `index_data/stats.ex`, `index_view/stats.ex:69`, `index_view/filters.ex:15-24` | rollup counts; links `is_available:true/false` | switch to `availability:` links and add an Unknown card |
| `device_live/availability_components.ex`, `availability_data.ex:154-163` | per-agent detail | keep; add the evidence table |
| `device_live/availability_data.ex:104-125` | fills the 24 h timeline from the current bit when there is no ICMP history | switch to state, so unknown renders as unknown |
| `device_live/device_tab_runtime.ex:201` | `Map.get(row,"is_available") \|\| Map.get(row,:is_available)` **turns `false` into `nil`** | fix (a latent bug independent of this change) |
| `topology/god_view_stream.ex:2422`, `bitmap_source.ex:233`, `world_health_source.ex:47` | true -> healthy, false -> unavailable, nil -> unknown | keep: already three-valued. Switch to state when convenient |
| `dashboard_live/data/basic_summaries.ex:12-22` | raw SQL; unavailable = total - available, so NULL counts as unavailable; does not exclude source-retired rows | fix: read the rollup or count by state |
| `dashboard_live/data/service_sparklines.ex:65`, `vulnerable_assets.ex:22` | NULL counts as false | keep (the "available" count is unaffected); review the labels |
| authored dashboards (`source_queries.ex`, `visuals.ex`, `DashboardPanelChart.jsx`, `DashboardBuilderCanvas.jsx`), `srql/builder.ex`, `srql/catalog.ex` | detect `is_available` as a boolean pivot; field allowlists | add `availability` as an enum pivot; keep `is_available` |
| `api/access.ex:166,198`, `controllers/api/device_controller.ex:615,656` | raw value; `status=online` / `offline` | keep the raw value (now nullable), add `availability_state` and `availability_decided_by`, and add `status=unknown` |
| `priv/static/openapi.json` (already `boolean \| null`) | external contract | add `availability_state`, document NULL as unknown, and bump the API description |
| `priv/mcp/srql-cookbook.md:17,293` | examples | add `availability:unknown` and keep the existing examples |

### Composite checks, automation and integrations (`serviceradar_core`)

| Reader | Today | Change |
|---|---|---|
| `composite_checks/evaluation.ex:163-191,449-463`, `resolvers/vantage_point.ex:30-60`, `coverage.ex:55-75` | per-agent rows as inputs; **SE** verdict transitions through `VerdictEventWriter` | keep: inputs unchanged |
| `composite_checks/evaluation.ex:480` (W11) | writes the column | becomes `operator_policy` evidence; the verdict events are unchanged |
| `integrations/armis_northbound_population.ex:150-200` | canonical value or the source agent's row; **nil is withheld as `missing_availability`** | keep: unknown is withheld, which is correct |
| `integrations/armis_northbound_runner.ex:1000-1070,1201-1263` | `COALESCE(d.is_available,false)`; devices sharing an Armis id are combined with AND; **SE pushes `not is_available` to Armis** | **fix before stage c**: unknown must be withheld, not exported as "unavailable". Otherwise every unknown device would push `"true"` (unavailable) to Armis |
| `automation/northbound/target_resolver.ex:173` | raw value in the automation target snapshot | keep (nullable); add the state |
| `automation/ansible/awx_membership_reconciler.ex:679,816` | `is_available` from the **plugin envelope** (not the DB); nil fails the aggregate | unaffected by the device column; check the W13 awx decision (Open Question 8) against it |

### Correlation engine (`rust/correlation-engine`)

| Reader | Today | Change |
|---|---|---|
| `delta.rs:3-90` | `signals.state.ocsf_devices` `is_available` transitions. **Published only by the sync path**, so sweep, composite, agent and camera changes arrive only on refresh | switch: the resolver publishes every transition (Decision 8) and adds an `availability_state` field |
| `context_hydrator.rs:116,215` | SRQL refresh; never sees None because of `unwrap_or(false)` | fixed by the SRQL JSON change. The C13 "observation expected but availability unknown" verdict (`reasoner.rs:444`) becomes reachable for the first time. **SE**: verdicts are published on JetStream |
| `reasoner.rs:108,253` (C1, C3, C4, C7) | `Some(false)` counts as down | keep; `None` stays non-down |

### Other core

| Reader | Today | Change |
|---|---|---|
| `sweep_jobs/sweep_results_ingestor.ex:2192-2273` "available wins" | reads the column, `metadata.sweep_last_available_at` and per-agent rows | **removed**: the rule moves into the resolver (Decision 5) |
| `sweep_jobs/availability_events.ex` | **SE**: `device.available` / `device.unavailable`, then EventRules, then a seeded StatefulAlertRule (open and clear), gated per sweep group | generalized to resolver transitions (Decision 8) |
| `inventory/sync/state_events.ex:17-93` | **SE**: `signals.state.ocsf_devices` for the sync path | stops publishing `is_available`; the resolver does it |
| `inventory/device_pubsub.ex` | **SE** (UI invalidation) on every W1/W2 touch | fires on decision change only |
| `inventory/device.ex:331` read action `:available`, `:1094` `status_color` calc | no callers found | delete at stage d, or switch to state |
| `camera/inventory_ingestor.ex:860` | carries the current value into its update attrs | removed with W9 |
| `observability/service_health.ex`, `identity/device_lookup.ex:760` | false positives: service state and a comment | none |

### Go (`go/`)

| Reader or producer | Today | Change |
|---|---|---|
| `pkg/models/discovery.go:93` `DeviceUpdate.IsAvailable bool` (no omitempty) | **false is always sent**, so "no opinion" cannot be expressed | the evidence mapping treats this field as evidence only for sources whose registration says the field is meaningful (sweep). A follow-up makes it `*bool` |
| `pkg/models/ocsf_device.go:177,302,357`, `pkg/models/device.go:18` | legacy conversions; nil becomes false | keep; no core reader depends on them for availability |
| SDK `DiscoveredDevice.IsAvailable *bool` (`serviceradar-sdk-go`, vendored) and `action.go:168` | optional field | keep. The class comes from the manifest (Open Question 7) |

### Side-effect summary

These readers trigger side effects on availability transitions or pushes:

- the sweep availability events and the seeded StatefulAlertRule (alerts,
  and notifications through alert routing);
- composite-check verdict events;
- the `signals.state` feed and correlation verdicts on JetStream;
- the Armis northbound push (scheduled);
- AWX membership `enabled` (fed from the plugin, not the column);
- DevicePubSub UI invalidation.

Stage c's suppression (Decision 10) covers the first three. Armis gets a
preview run and the unknown-withholding fix. The others are idempotent
reads.

## What could break, and mitigations

| Risk | Mitigation |
|---|---|
| **Alert or event storm at cutover**: many devices flip at once, opening and closing `device.unavailable` alerts, sending notifications, triggering automation and pushing Armis northbound updates. | The stage-c reconciliation suppresses per-device side effects and emits one summary event. Stateful alerts are reconciled explicitly. The divergence report sizes the flip before cutover. Armis northbound runs a preview run first. |
| **Available count changes on existing installs.** Devices that were only ever "available" through the `DEFAULT true` (W14) or a stale write become `unknown`, so the Available stat drops. | Measured in stage b, by source and class. The release note explains the Unknown stat card. The open question on keeping the last value for evidence-less devices lets the user choose a softer projection. |
| **Hysteresis and "available wins" semantics drift.** | Decision 5 maps each rule one-to-one. The resolver's table-driven tests (see tasks) encode today's W1/W2 cases as fixtures before any writer moves. |
| **Devices with no evidence at all.** | They become `unknown` (Decision 6), not silently available. A device created by a CMDB sync stays unknown until some source reports on it. This is visible and filterable, and the shadow report counts these devices. |
| **Write amplification** from evidence rows in addition to device rows. | Write-on-change plus lease renewal (Decision 7). The device row is written only on transitions, and the rollup trigger is narrowed. Measure WAL bytes per hour on the lab deployment in stages a, b and c, and gate stage c on no increase over stage a. |
| **API consumers of `is_available`**: the REST device JSON, `openapi.json`, the MCP SRQL cookbook, Armis northbound, awx membership and northbound target resolution. | The field stays, with type `boolean` and nullable. The OpenAPI schema adds `availability_state` and documents NULL. The cookbook gains `availability:unknown`. External integrations that test `is_available == false` keep their semantics. Integrations that treat a missing value as false are listed in the reader table, and each one's behavior for unknown is decided explicitly. |
| **Armis northbound exports unknown as "unavailable".** The runner does `COALESCE(is_available,false)` and pushes `not is_available`. | Before stage c, make the runner withhold NULL the way the population builder already does (`missing_availability`). Cutover is gated on that fix and on a preview run. |
| **Readers disagree about NULL** (srql JSON `unwrap_or(false)`, grouped NotEq including NULL, `basic_summaries` counting NULL as unavailable, `device_tab_runtime` turning false into nil). | Each one is listed in the reader table as "fix" and lands before stage c, because unknown makes NULL common. One rule: NULL means unknown. |
| **The correlation engine starts seeing transitions it never saw**, from sweep, composite and agent sources, and the C13 unknown verdict becomes reachable. | Intended. Measure the verdict rate on the lab deployment in stage c, and the reconciliation's feed suppression prevents a burst. |
| **Lock contention**: the resolver locks device rows, and controller syncs and sweeps now contend on the same devices. | Uid-ordered `FOR NO KEY UPDATE` (as W1/W2 already do), batches of at most 500, and the device row is updated only on change. Contention is no worse than today's W1/W2 plus W6, which already lock the same rows. |
| **A misdeclared class** (for example a plugin claiming `managing_controller`). | The class is set by registration and capped by the plugin manifest, which operators can lower. The device page shows the deciding class, and the divergence report groups by class. |
| **Source clock skew** makes evidence look fresh or stale incorrectly. | `observed_at` is clamped to `[ingest_time - max_ttl, ingest_time]`. |
| **The expiry job lags** and expired evidence keeps a device available. | The job is bounded and idempotent, with a lag metric (published through JetStream like other internal telemetry). Every reader treats `expires_at` as advisory, and only the resolver decides. |

## Migration Plan

1. Migration A (stage a): create `device_availability_evidence`, add the
   `ocsf_devices.availability_*` columns (state defaults to `unknown`), and
   add the shadow table. Backfill nothing into the device columns.
2. The first evidence comes from the sources themselves within one cycle
   each. `device_agent_availability` rows younger than their TTL are copied
   into evidence as `active_probe` rows, so stage b does not start blind for
   sweeps. Composite-check verdicts are copied from
   `device_composite_check_results` for checks with
   `write_canonical_availability`.
3. Stage c's reconciliation is the only bulk write to `ocsf_devices`.
4. Migration B (stage c): add the `unknown` key to the rollup tables, and
   narrow the rollup trigger's `WHEN` clause.
5. Migration C (stage d): add the backstop trigger and the violations table,
   and strip the `sweep_*` metadata keys in pages.

### How the demo Wi-Fi case resolves

For the roughly 120 Wi-Fi APs counted Available but rendered Offline:

- Each has `active_probe` evidence from the sweep agents. All of it is
  `down`, confirmed, and fresh.
- Where the Wi-Fi map source is registered as a live controller feed, each
  AP also has `managing_controller` evidence: `up` when the controller
  reports up/ok/online.
  - **Controller row says up:** the result is `available`, decided by
    `managing_controller` with `availability_conflict = true`. The badge
    shows Online with "not reachable from sweep agents", and the sweep detail
    stays on the device page. The column stops flipping, and the device row
    and rollup stop being rewritten.
  - **Controller row has no status:** the Wi-Fi source submits no evidence,
    because a missing status is not evidence. The sweep decides
    `unavailable`. Today these devices are counted Available.
  - **Controller row says down:** the result is `unavailable`, decided by
    the controller.
  - **The Wi-Fi map source is a static import** rather than a live
    controller (it is registered as `inventory_declared`): the sweep's
    `active_probe` outranks it, and the result is `unavailable`, agreeing
    with today's badge.
- The split between these cases is not known from the investigation. It is
  the first thing the stage-b divergence report shows. If most of them are
  "controller says up", the Available count barely moves and the badges turn
  Online. If the static-import case dominates, the count drops by about 120
  and the badges stay Offline. Either way the list order, the count and the
  badge agree.
- The roughly 5 remaining divergent devices without Wi-Fi provenance resolve
  by the same rules. Their deciding class appears in the report.

## Relationship to pending changes

- `add-per-agent-availability` (complete, not archived) adds the
  requirements "Canonical availability source selection", "Availability
  source profiles" and "Availability source freshness". This change keeps
  their behavior: the pin and the profiles feed step 2 of the resolver, and
  freshness becomes `expires_at`. It refines what "derived" means. Archive
  `add-per-agent-availability` first so that its requirements land in
  `specs/device-inventory`. This change then adds its own requirements
  without restating theirs, so archiving the two in order cannot overwrite
  either.
- `add-armis-northbound-availability-updates` and the composite-check
  changes read canonical availability. Their contracts hold, and the value
  they read becomes consistent.

## Open Questions

1. **Cross-class conflict.** Should a fresh `up` from a lower class override
   a decisive `down` from a higher class (cross-class "available wins")? The
   proposal says no and sets a conflict flag.
2. **Unknown projection.** Should `unknown` project to `NULL` (proposed), or
   keep the last decided boolean? Keeping it holds the Available count
   stable, but then the count and the badge can diverge again for stale
   devices.
3. **Never-evidenced devices** (CMDB-only imports): `unknown` (proposed), or
   treat inventory presence as weak `inventory_declared up` evidence?
4. **Composite-check precedence.** Should `operator_policy` (a composite
   check with `write_canonical_availability`) outrank everything, including
   a device's agent pin? Or should an explicit per-device pin outrank a
   check?
5. **Event gating.** Should emission become a deployment setting with the
   per-sweep-group flag as a filter (proposed), or stay per source instance
   for every source type?
6. **Backstop trigger.** CLAUDE.md prefers append-only audit to rejecting
   writes. The proposed trigger silently restores the old value and appends
   to a violations table, using a transaction-local setting that only the
   resolver function sets. Is that acceptable, or should stage d rely on
   removing the accept lists and adding a static check instead?
7. **Plugin class declaration.** Should the class live in the plugin
   manifest only, or also in each `DiscoveredDevice` record? The record
   field would be a cross-repo `serviceradar-sdk-go` change, and the
   manifest allowlist is closed.
8. **awx `enabled`.** It is an administrative flag. Should the awx plugin
   stop reporting availability altogether rather than declare
   `inventory_declared`? Note that `awx_membership_reconciler.ex` consumes
   the plugin envelope's `is_available` as the AWX `enabled` input, so the
   envelope field must stay even if the plugin stops submitting evidence.
9. **Re-sighting write volume.** Should a follow-up change coalesce
   `last_seen_time` refreshes (for example, write at most every 5 minutes)?
   That would amend the "Device re-sighting" scenario in `device-inventory`.
