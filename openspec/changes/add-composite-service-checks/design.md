# Design: Composite service checks

## Context

`add-per-agent-availability` (implemented, unarchived) landed
`platform.device_agent_availability`, a latest-state projection keyed by
`{device_uid, agent_id}` carrying `is_available`, `sweep_modes_results`,
`open_ports`, `response_time_ms`, and `checked_at`. Every raw signal this
feature needs from the network already exists and is already persisted.

What does not exist is composition. Three concrete gaps:

1. Nothing joins two agents' observations of the same device into one answer.
2. Nothing distinguishes "unreachable because segmented" from "unreachable
   because powered off". These are the same row today.
3. Nothing lets an operator state what the *expected* pattern is, so nothing can
   flag a deviation from it.

The domain driving this is segmentation assurance: proving a device is isolated,
and proving the configuration that enforces the isolation is actually applied.
OpenText Network Automation (NCO) owns the configuration half and already
performs the validation; ServiceRadar needs to accept its boolean and combine it
with observed reachability.

Constraints that shaped the design:

- ServiceRadar has one probe path (sweeps) and one metric path (JetStream →
  `event_writer` → CNPG). Neither may be duplicated. Verdicts are derived state
  rather than metrics, so they follow the core-originated OCSF event path
  (`credentials/credential_event_writer.ex:281`) rather than JetStream.
- All schema is Elixir migrations in `serviceradar_core`, `platform` schema, Ash
  resources for every table.
- The demo CNPG instance is CPU-sensitive; a design that rewrites device rows on
  every evaluation cycle is not acceptable.

## Goals / Non-Goals

**Goals**

- Express "agent A should reach it, agent B should not, and NCO should confirm
  the config" as an authored, reviewable object.
- Make the powered-off case explicitly *not* compliant rather than accidentally
  compliant.
- Store verdicts as durable per-device state that SRQL can query and that
  northbound integrations can export.
- Leave room for future signal types without reworking storage or evaluation.

**Non-Goals**

- Probing. See the proposal's non-goals section; composite checks derive only.
- Sweep profile changes, including the availability predicate and per-profile
  agent lists.
- Refused-versus-timeout probe semantics.
- Notification delivery.
- The NCO Wasm plugin (phase 2).

## Decisions

### D1 — Derivation, not orchestration

A composite check reads `device_agent_availability` and device metadata. It does
not create, assign, or trigger sweeps.

*Alternatives considered.* Having a composite reconcile sweep group assignments
(scope × profile × each vantage-point agent) would make it a single authoring
surface and would structurally prevent the "no coverage, silent inconclusive"
failure. It was rejected because it puts a second writer on sweep group
configuration and blurs which object owns scheduling.

*Consequence, and its mitigation.* The failure mode this admits is real: a check
whose vantage point has no sweep wired reports `inconclusive` forever and looks
like it is working. Mitigated by mandatory coverage computation at save time
(D8), not by documentation.

### D2 — Typed inputs plus an ordered decision table

Inputs are declared and named; rules are ordered rows of expected values mapped
to a verdict; first match wins; a catch-all is mandatory.

*Why over a boolean expression tree.* A rule table is total by construction once
the catch-all exists — every input combination lands somewhere, provably. A tree
falls through implicitly, so "we never thought about blocked/blocked" becomes a
silent wrong answer rather than a visible row. The table is also diffable in
review and renders as a table, which is what the operator is already drawing on
a whiteboard.

*Why over Zen JDM.* The existing `zen-rule-editor` has a decision-table node and
a working engine, and reusing it would be free evaluation. Rejected because the
editor is a generic graph canvas, Zen rules sync to KV for edge evaluation
(irrelevant here — this runs in core over the database), and the domain
vocabulary would have to be smuggled through untyped JSON, losing the agent
picker, the coverage check, and the liveness-witness validation.

*Extensibility.* Expressiveness grows through input `kind`s, not through
grammar. `two_of_three_blocked` is a future input kind that resolves to a
tri-state, not a new operator in the rule language. This keeps the table shape —
and therefore the UI, the storage, and the evaluator — fixed.

### D3 — Operator-defined verdicts, fixed status enum

`verdict` is a free slug (`isolated_verified`, `isolated_unenforced`,
`inverted_reachability`). `status` is `healthy | degraded | down | unknown`.

Verdicts carry the domain meaning and vary per deployment; status is what
rollups, colors, sort order, and northbound exports key on. Without the fixed
enum, every consumer would need to know each check's vocabulary.

### D4 — Dedicated result table, not `ocsf_devices.metadata`

`platform.device_composite_check_results`, PK `(device_uid, check_id)`.

*Why not the metadata map,* which is what "stored as metadata for that device"
literally suggests: a metadata merge per device per cycle is a device row UPDATE
per device per cycle. At demo scale that is thousands of writes every five
minutes flowing through DIRE notifiers, device PubSub, and the device read model
— for data no device consumer needs inline. The dedicated table also carries the
input snapshot and `changed_at`, which a map cannot.

SRQL exposure (D7) is what makes it feel like a device field to users.

### D5 — One pure evaluator, three callers

`Evaluator.verdict(inputs, rules) :: {verdict, status, matched_rule_id}`, called
by the periodic worker, the debounced refresh, and the builder's Test button.

*Why this matters more than it looks.* The alternative — compiling rules to a
SQL `CASE` for bulk passes — is faster and was rejected anyway, because it puts
decision semantics in SQL string generation. That is hard to unit test, and the
Test button would need a second implementation in Elixir that can drift from it.
A preview that disagrees with production is worse than a slow preview.

Scale is handled by batching around the pure function rather than by pushing the
function into SQL: page the scope 1000 UIDs at a time, one availability query and
one metadata query per page, evaluate in memory, bulk upsert.

### D6 — Periodic reconcile plus event-driven refresh

Both, not either.

The periodic pass is not an optimization fallback; it is load-bearing. Two state
transitions produce no event at all:

- an input aging past `max_age` (`nac_applied` was written 25 hours ago and the
  check requires 24h freshness → the verdict must become `inconclusive`, but
  nothing happened to trigger that)
- scope membership drift as Armis syncs (a device gains `tag:managed` and enters
  scope; the device did not change from this check's perspective)

The event path exists to keep verdicts fresh after a sweep cycle without waiting
a full interval, debounced 30s per device.

### D7 — `composite.<slug>` follows the `tags.<key>` precedent

The translator already supports dotted dynamic keys for `tags.env:prod`, so
`composite.pci-isolation:not_isolated` needs a resolution rule, not new grammar.
`in:composite_results` is added as a separate entity for rollups because
grouping by verdict across a check is a different shape than filtering devices.

### D8 — Coverage and liveness-witness validation are save-time gates

Two validations exist because the physics of the problem demands them, not as
polish:

- **Liveness witness.** A check with two or more vantage points MUST have at
  least one expected `available`. Without it, `blocked` everywhere is the
  expected pattern, and a powered-off device satisfies the check perfectly. The
  check would then certify dead devices as compliant.
- **Coverage.** For each vantage point, count devices in scope with a
  non-stale `device_agent_availability` row for that agent. Zero coverage blocks
  enabling; partial coverage warns with counts. This is the mitigation for D1.

### D9 — Fact provenance side-channel

`PATCH /api/devices/:uid/metadata` writes both `metadata.<key>` (plain value,
visible to every existing metadata consumer) and
`metadata.__fact_provenance.<key> = {source, updated_at}`.

*Why not require callers to send timestamps.* NCO's integration should be a
one-line PATCH. Server-stamped provenance also cannot be back-dated by a caller,
which matters when a verdict is a compliance statement.

*Why not a separate facts table with a write API.* It would be cleaner for
freshness, but it adds a second external write surface into device state that
DIRE and identity reconciliation would have to reason about. Phase 2 already has
a sanctioned external ingress (`device_source_observations.source_metadata` via
the signed Wasm plugin contract); this side-channel is deliberately the minimum
that makes phase 1 work and is superseded rather than extended.

## Risks / Trade-offs

- **Silent `inconclusive` from missing coverage** → D8 coverage gate; the check
  cannot be enabled at zero coverage without explicit acknowledgement, and
  partial coverage is stated with counts on the builder and index.
- **`blocked` conflates filtered with dead at a single vantage point** → this is
  inherent given the `DialResets` limitation, and is why the liveness witness is
  mandatory. Documented in the spec's resolution requirement so no reader
  mistakes `blocked` for "provably filtered". A follow-up change against
  `sweeper` can lift it.
- **Evaluation cost on large scopes** → paged batches, bounded queries per page,
  telemetry on pass duration and device count. A check whose scope resolves to
  an unbounded population is an authoring problem the preview surfaces before
  save.
- **Device merges stranding verdicts** → `DeviceCompositeCheckResult` gets a
  `reassign_device` action wired into the DIRE merge path, mirroring
  `DeviceAgentAvailability.reassign_device`. Without it, verdicts strand on the
  losing UID after a merge. Explicit regression test.
- **Rule tables drifting from vantage-point expectations** → `expected` seeds
  rules but never evaluates. Regeneration warns before overwriting hand edits.
  The rules are the single source of truth for evaluation, always.
- **Slug churn breaking saved SRQL** → slugs are immutable after first enable;
  renaming the display name does not change the slug.

## Migration Plan

Purely additive; no backfill and no data migration.

1. Migration creates `composite_checks`, `composite_check_inputs`,
   `composite_check_rules`, `device_composite_check_results` in `platform`.
2. Ash resources, evaluator, worker, refresh trigger ship inert — no check
   exists, so no worker runs.
3. `PATCH /api/devices/:uid/metadata` ships behind `devices.facts.write`, which
   no role holds by default beyond operator/admin.
4. SRQL fields resolve to null/empty for devices with no result rows.
5. UI ships; an operator authors the first check as a draft, tests it against
   live data with the Test button, then enables it.

Rollback is deleting the checks; the tables can remain empty with no effect on
any other subsystem.

## Open Questions

- Should `evaluation_interval` be per check (as designed) or a single global
  setting? Per check is more flexible but multiplies Oban cron entries. Starting
  per check with a sane default.
- Does the composite check index belong under Settings or as a top-level
  navigation item? The mock's breadcrumb suggests top-level. Settings is
  proposed because it sits beside Networks; alignment with
  `redesign-settings-catalog-nav` should decide it.
- Should a device be allowed in the scope of many checks (currently yes,
  unbounded)? A cap may be needed if evaluation cost becomes visible.
