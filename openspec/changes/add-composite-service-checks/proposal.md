# Change: Composite service checks — multi-vantage-point verdicts over existing signals

## Why

ServiceRadar can already tell you whether a device answered a probe. It cannot
tell you whether a device is *isolated*, and those are different questions.

The operational need is network segmentation assurance. An agent sits in the DMZ
and an agent sits in the core network. For a device that is supposed to be
fenced off, the correct observation is "reachable from the DMZ, not reachable
from core." Today each agent's result is stored independently — `add-per-agent-availability`
landed `platform.device_agent_availability` keyed by `{device_uid, agent_id}` —
but nothing composes those observations into a single answer, and nothing
distinguishes the three cases an operator actually cares about:

- reachable from the right place and blocked from the wrong place → isolated
- reachable from both → **not** isolated, a real finding
- reachable from neither → the device is probably powered off, and isolation
  cannot be proven either way, so it must not be counted as compliant

The third case is the one that makes single-vantage-point monitoring useless
here: without a liveness witness, a dead device looks exactly like a perfectly
segmented one.

Segmentation assurance also has a configuration half that ServiceRadar does not
observe. OpenText Network Automation (NCO) already knows how to validate whether
a device carries the expected access-control configuration. Observed isolation
plus confirmed configuration is a much stronger statement than either alone:
blocked-today-but-not-by-device-config is an upstream ACL that can change
without anyone noticing.

There is no way to express any of this today. This change adds a composite check
capability: an authored object that scopes a device population with SRQL, names
the signals it cares about, and maps combinations of those signals onto operator
defined verdicts.

## What Changes

### A derivation layer, not a second probe path

Composite checks **do not probe**. They read signals other subsystems already
produce and compute a verdict. Sweeps continue to be authored, scheduled, and
assigned in Settings > Networks exactly as they are today; the composite check
builder shows the governing sweep group/profile read-only and links out to it.
This keeps one probe path, one scheduler, and one metric path.

The cost of deriving rather than probing is that a check can silently report
`inconclusive` forever if nobody wired a sweep for one of its vantage points.
The builder therefore computes per-vantage-point coverage over the scope and
refuses to enable a check whose vantage point has zero coverage without an
explicit acknowledgement.

### Authored object model — four Ash resources in `serviceradar_core`, schema `platform`

- **ADD** `ServiceRadar.CompositeChecks.CompositeCheck`: `name`, `slug` (the SRQL
  handle), `description`, `scope_query` (SRQL, must resolve `in:devices`),
  `evaluation_interval` (default 5 minutes), `state`
  (`draft` / `enabled` / `disabled`), audit columns. Scope persists as the SRQL
  string only and is parsed back into visual builder state on load, the same
  round-trip `visibility_profiles_live/target_builder.ex` already performs.
- **ADD** `ServiceRadar.CompositeChecks.CompositeCheckInput`: a named, typed
  signal — `key`, `label`, `position`, `kind`, `config` (jsonb), `expected`.
  Two kinds ship:
  - `vantage_point` — `{agent_id, max_age}` → `available` / `blocked` / `unknown`
  - `device_metadata` — `{path, value_type, max_age}` → `true` / `false` / `unknown`
  New input kinds are a resolver module plus a config schema. Rules, storage,
  evaluation, and the UI shell do not change to accommodate one. This is the
  extension seam for future signals (SNMP OID, add-on result, BGP reachability).
- **ADD** `ServiceRadar.CompositeChecks.CompositeCheckRule`: one row of the
  decision table — `position`, `match` (jsonb, `input_key => literal | [literals] | "*"`),
  `verdict` (operator-defined slug), `verdict_label`, `verdict_description`,
  and `status`, a **fixed** enum of `healthy` / `degraded` / `down` / `unknown`.
  First match wins. A final all-`*` catch-all rule is mandatory and is created
  automatically as `inconclusive` / `unknown`; it can be renamed, not deleted.
  Operator-defined verdicts keep the vocabulary domain-specific; the fixed
  status enum keeps rollups, colors, and sorting working without knowing it.
- **ADD** `ServiceRadar.CompositeChecks.DeviceCompositeCheckResult`: primary key
  `(device_uid, check_id)`, plus `verdict`, `status`, `matched_rule_id`,
  `inputs` (jsonb snapshot of what each input resolved to and when),
  `evaluated_at`, `changed_at`. A dedicated table rather than a write into
  `ocsf_devices.metadata`, because a metadata merge per device per evaluation
  cycle would churn the device read model, DIRE notifiers, and device PubSub.

### Evaluation — one pure function, three callers

- **ADD** `CompositeChecks.Evaluator.verdict(inputs, rules)`, a pure function
  returning `{verdict, status, matched_rule_id}`. It is the only place decision
  table semantics live, and it is shared by the periodic worker, the
  event-driven refresh, and the builder's **Test** button, so a preview cannot
  disagree with production.
- **ADD** `CompositeChecks.EvaluationWorker`, one Oban job per enabled check on
  its `evaluation_interval`. It resolves the scope through the SRQL Ash adapter,
  pages device UIDs 1000 at a time, issues one availability query and one
  metadata query per page, evaluates, bulk-upserts results, and diffs against
  the prior verdict. Devices that have left the scope have their result rows
  for that check deleted, so rollups do not count ghosts.
- **ADD** a debounced (30s default) per-device refresh triggered by sweep-result
  ingestion and by device fact writes. The periodic pass is still required
  regardless of the event path: a fact going stale produces no event, so
  "`nac_applied` is now 25h old, therefore `inconclusive`" is only discoverable
  by looking.
- **ADD** verdict-transition OCSF events recorded through the same
  core-originated path other control-plane lifecycle events use — a system-actor
  `Ash.create(OcsfEvent, action: :record)`, following
  `credentials/credential_event_writer.ex:281`. Event recording failures are
  logged and swallowed; they never fail the evaluation. Verdicts are derived
  state, not metrics, so the JetStream-first metric rule does not apply.

### Phase-1 external fact ingress

NCO already performs the configuration validation; phase 1 is only about getting
its boolean into ServiceRadar.

- **ADD** `PATCH /api/devices/:uid/metadata` in web-ng, body
  `{"facts": {"nac_applied": true}}`, gated on a new `devices.facts.write`
  permission. It writes the plain value at `metadata.<key>` so every existing
  metadata consumer sees it, **and** writes
  `metadata.__fact_provenance.<key> = {source, updated_at}`. That provenance
  side-channel is what makes a composite input's `max_age` enforceable without
  requiring the caller to send timestamps.
- **ADD** bounds on that endpoint: key regex `^[a-z][a-z0-9_]{0,63}$`, a cap on
  fact count per device, scalar values only, and rejection of system-managed
  metadata keys (for example `passive_fingerprint`).
- Phase 2 is the OpenText Network Automation Wasm plugin under
  `add-external-inventory-wasm-plugin-contract`, landing the same signal as
  bounded `source_metadata` on `device_source_observations`. When it arrives the
  `device_metadata` input kind gains a `source:` option and authored checks are
  unchanged. Phase 2 is **not** in scope here.

### Builder UI — web-ng LiveView

- **ADD** `/settings/composite-checks` (index) and `/settings/composite-checks/:id`
  (builder), sited next to Settings > Networks because that is where the sweeps
  a composite consumes are authored.
- The index lists each check with state, scope size, and its verdict rollup bar.
- The builder has four sections: **Scope** (reusing `SRQL.Builder`,
  `QueryBuilderComponents`, and the existing `target_builder` round-trip, so raw
  SRQL and the visual filter rows edit the same state in either direction),
  **Vantage points**, **Verdicts** (the decision table), and a **Live preview**
  showing a sample device's per-input breakdown, its resulting verdict, and
  rollup counts across the scope.
- **Vantage point `expected` is authoring sugar, not evaluation input.** It
  seeds the initial rule table and drives the liveness-witness/isolation-probe
  labelling. After generation the rules are authoritative and freely editable;
  the evaluator never reads `expected`. Regenerating warns before overwriting
  hand edits.
- **ADD** three save-time validations: a mandatory catch-all rule; a liveness
  witness (a check with two or more vantage points MUST have at least one
  expected `available`, or a powered-off device is indistinguishable from a
  perfectly isolated one); and vantage-point coverage over the scope.
- **ADD** a verdict badge with per-input breakdown on device detail, plus an
  optional composite column and filter on the device list.

### SRQL

- **ADD** `composite.<slug>` as a device field, following the dynamic-key
  precedent `tags.<key>` already sets in the translator:
  `in:devices composite.pci-isolation:not_isolated` and
  `composite.pci-isolation.status:degraded`.
- **ADD** an `in:composite_results` entity for rollups
  (`check:pci-isolation verdict:isolated_verified`).
- **EXTEND** `srql_catalog_controller.ex` so the visual builder offers the new
  fields.

### Northbound

- **EXTEND** the Armis northbound path established by
  `add-armis-northbound-availability-updates` so an operator can export a
  selected check's verdict slug or status enum as a custom property or tag.

### RBAC

- **ADD** a `composite_checks` catalog section: `composite_checks.view` (all
  roles), `composite_checks.manage` (operator, admin),
  `composite_checks.evaluate` for on-demand Test (operator, admin).
- **ADD** `devices.facts.write` for the metadata fact endpoint (operator, admin,
  and API tokens holding the equivalent scope).

## Impact

- **Affected specs**: NEW capability `composite-checks`; `device-inventory`,
  `srql`, `build-web-ui`, `sync-service-integrations`.
- **Affected code**:
  - Elixir core: `ServiceRadar.CompositeChecks.*` (four resources, evaluator,
    worker, refresh trigger, event writer), migration for
    `composite_checks` / `composite_check_inputs` / `composite_check_rules` /
    `device_composite_check_results`, RBAC catalog, device metadata fact write
    action with provenance, `DeviceCompositeCheckResult.reassign_device` wired
    into the DIRE merge path.
  - Elixir web-ng: `CompositeCheckLive.Index` / `.Show`, device detail and list
    surfacing, `PATCH /api/devices/:uid/metadata`, router and RBAC wiring.
  - Rust: `rust/srql` translator support for `composite.<slug>` and
    `in:composite_results`, plus the Ash adapter side.
- **Depends on**: `add-per-agent-availability` (implemented, unarchived) for
  `platform.device_agent_availability`. This change reads that table and does
  not modify it.
- **Compatibility**: purely additive. No existing table, probe path, scheduler,
  or route changes behavior. Installations with no composite checks authored are
  unaffected.
- **BREAKING**: none.

## Explicit non-goals

- **No new probe path.** Composite checks never dispatch a scan. Anything that
  requires probing a device is a sweep concern.
- **No sweep profile changes.** "A device is available when" (any probe / every
  probe / ICMP with TCP fallback) and per-profile agent assignment stay as they
  are. The composite consumes per-agent availability as sweeps compute it today.
- **No refused-versus-timeout semantics.** `go/pkg/scan/tcp_scanner.go:296`
  detects `connection refused` only as an aggregate scanner statistic
  (`DialResets`); it is not carried per target into the result payload.
  Consequently `blocked` is specified throughout as *"no positive response from
  any enabled probe from that vantage point"*, **not** "provably filtered". The
  two-vantage-point design disambiguates dead-versus-firewalled without it —
  that is what the liveness witness is for. Propagating per-port outcome
  (open / refused / timeout) from the Go scanner through the gateway payload
  would make a single vantage point meaningful on its own, and is a worthwhile
  follow-up change against `sweeper` / `sweep-jobs`.
- **No notification delivery.** Verdict transitions produce event records.
  Notification delivery is non-functional platform-wide today
  (`WebhookNotifier` is not supervised, `Alert.send_notification` is a stub) and
  fixing that is out of scope.
- **No NCO Wasm plugin.** Phase 2 belongs to
  `add-external-inventory-wasm-plugin-contract`.
