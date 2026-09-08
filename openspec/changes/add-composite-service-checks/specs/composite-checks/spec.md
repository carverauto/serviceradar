## ADDED Requirements

### Requirement: Composite Check Definition

The system SHALL provide a composite check resource that scopes a device
population with SRQL and derives a verdict for each device in that scope from
named input signals.

A composite check SHALL carry a display name, an immutable slug used as its
query handle, an optional description, an SRQL `scope_query`, an
`evaluation_interval`, and a state of `draft`, `enabled`, or `disabled`.

The `scope_query` MUST resolve against the `devices` entity. A composite check
MUST NOT dispatch, create, schedule, or modify any probe, scan, or sweep.

#### Scenario: Author a composite check

- **WHEN** an operator creates a composite check named "PCI Isolation — Managed"
  with scope `in:devices source:armis tag:managed`
- **THEN** the check SHALL be persisted in `draft` state
- **AND** its slug SHALL be derived from the name and be unique across checks

#### Scenario: Reject a non-device scope

- **WHEN** an operator saves a composite check whose `scope_query` resolves
  against an entity other than `devices`
- **THEN** the save SHALL be rejected with a validation error naming the entity

#### Scenario: Slug is stable across renames

- **GIVEN** an enabled composite check with slug `pci-isolation`
- **WHEN** an operator changes its display name
- **THEN** the slug SHALL remain `pci-isolation`
- **AND** previously saved SRQL queries referencing that slug SHALL continue to
  resolve

#### Scenario: Composite checks never probe

- **GIVEN** an enabled composite check with two vantage points
- **WHEN** the check evaluates
- **THEN** no sweep, scan, or agent command SHALL be dispatched
- **AND** the evaluation SHALL read only already-persisted signals

### Requirement: Typed Check Inputs

The system SHALL represent each signal a composite check consumes as a named,
typed input with a `key`, `label`, `position`, `kind`, and kind-specific
`config`.

The system SHALL ship two input kinds, `vantage_point` and `device_metadata`.
Adding a further input kind SHALL require only a resolver and a config schema,
and SHALL NOT require changes to rule structure, result storage, or the
evaluator.

Every input SHALL be able to resolve to `unknown`, and `unknown` SHALL be a
value that rules can match explicitly.

#### Scenario: Declare a vantage point input

- **WHEN** an operator adds agent `agent-a` as a vantage point on a check
- **THEN** an input of kind `vantage_point` SHALL be created with `agent_id` and
  a `max_age`
- **AND** it SHALL resolve to one of `available`, `blocked`, or `unknown`

#### Scenario: Declare a device metadata input

- **WHEN** an operator adds a device metadata input with path `nac_applied`,
  value type `boolean`, and max age 24 hours
- **THEN** the input SHALL resolve to one of `true`, `false`, or `unknown`

#### Scenario: Input keys are unique within a check

- **WHEN** an operator adds a second input using an existing key
- **THEN** the save SHALL be rejected with a validation error

### Requirement: Vantage Point Resolution

The system SHALL resolve a `vantage_point` input for a device by reading the
latest per-agent availability row for `{device_uid, agent_id}`.

Resolution SHALL yield `unknown` when no row exists, or when the row's
`checked_at` is older than the input's `max_age`. Otherwise it SHALL yield
`available` when the row reports available and `blocked` when it does not.

`blocked` SHALL mean "no positive response from any enabled probe from that
vantage point". It SHALL NOT be represented, labelled, or documented as
"provably filtered", because per-target refused-versus-timeout outcomes are not
currently carried from the scanner into sweep results.

#### Scenario: Agent reports the device reachable

- **GIVEN** a fresh availability row for `{device-1, agent-a}` reporting available
- **WHEN** the vantage point input for `agent-a` resolves
- **THEN** it SHALL yield `available`

#### Scenario: No result from that agent

- **GIVEN** no availability row exists for `{device-1, agent-b}`
- **WHEN** the vantage point input for `agent-b` resolves
- **THEN** it SHALL yield `unknown`

#### Scenario: Stale result from that agent

- **GIVEN** an availability row for `{device-1, agent-b}` with `checked_at` older
  than the input's `max_age`
- **WHEN** the vantage point input resolves
- **THEN** it SHALL yield `unknown`
- **AND** the result's input snapshot SHALL record the observed `checked_at`

### Requirement: Device Metadata Fact Resolution

The system SHALL resolve a `device_metadata` input by reading the configured
path from the device's metadata, together with the provenance recorded for that
key.

Resolution SHALL yield `unknown` when the key is absent or when the stored value
does not match the declared value type.

When the input declares a `max_age`, resolution SHALL additionally yield
`unknown` if no provenance is recorded for the key or if the recorded
`updated_at` is older than that `max_age`.

`max_age` SHALL be optional. When it is absent the input SHALL resolve on the
stored value alone and SHALL NOT require provenance, so that a metadata key
written by a path that does not record provenance remains usable. The authoring
UI SHALL state that such an input cannot distinguish a fresh value from a stale
one.

#### Scenario: Fresh boolean fact

- **GIVEN** device metadata contains `nac_applied = true` with provenance
  `updated_at` two hours ago
- **AND** the input declares a 24 hour max age
- **WHEN** the input resolves
- **THEN** it SHALL yield `true`

#### Scenario: Stale fact

- **GIVEN** device metadata contains `nac_applied = true` with provenance
  `updated_at` 25 hours ago
- **AND** the input declares a 24 hour max age
- **WHEN** the input resolves
- **THEN** it SHALL yield `unknown`

#### Scenario: Value type mismatch

- **GIVEN** device metadata contains `nac_applied = "yes"`
- **AND** the input declares value type `boolean`
- **WHEN** the input resolves
- **THEN** it SHALL yield `unknown`

#### Scenario: Key without provenance and no max age

- **GIVEN** device metadata contains a boolean key written by a path that records
  no provenance
- **AND** the input declares no `max_age`
- **WHEN** the input resolves
- **THEN** it SHALL yield the stored value
- **AND** SHALL NOT yield `unknown` for the missing provenance

#### Scenario: Key without provenance but with max age

- **GIVEN** the same key with no recorded provenance
- **AND** the input declares a 24 hour `max_age`
- **WHEN** the input resolves
- **THEN** it SHALL yield `unknown`

### Requirement: Ordered Decision Table

The system SHALL evaluate a composite check as an ordered list of rules where
the first matching rule wins.

Each rule SHALL carry a `position`, a `match` map of input key to a literal
value, a list of literal values, or a wildcard, an operator-defined `verdict`
slug with a label and description, and a `status` drawn from the fixed set
`healthy`, `degraded`, `down`, `unknown`.

Every composite check SHALL have a final catch-all rule whose match is a
wildcard for every input. The catch-all SHALL be created automatically with
verdict `inconclusive` and status `unknown`, MAY be relabelled, and MUST NOT be
deleted or reordered away from last position.

#### Scenario: First match wins

- **GIVEN** rules ordered `(available, blocked, true) -> isolated_verified` then
  `(available, blocked, *) -> isolated_unenforced`
- **WHEN** a device resolves to `available`, `blocked`, `true`
- **THEN** the verdict SHALL be `isolated_verified`

#### Scenario: Wildcard matching

- **GIVEN** a rule `(available, available, *) -> not_isolated` with status `down`
- **WHEN** a device resolves to `available`, `available`, `unknown`
- **THEN** the verdict SHALL be `not_isolated` with status `down`

#### Scenario: Every input combination is covered

- **GIVEN** any composite check with a valid rule table
- **WHEN** any combination of input values is evaluated
- **THEN** exactly one rule SHALL match

#### Scenario: Catch-all cannot be removed

- **WHEN** an operator attempts to delete the catch-all rule
- **THEN** the operation SHALL be rejected
- **AND** the check SHALL retain its catch-all at final position

#### Scenario: Verdict vocabulary is per check

- **WHEN** an operator defines verdict slug `inverted_reachability` with status
  `down`
- **THEN** the verdict SHALL be persisted as authored
- **AND** rollups and colors SHALL key on the `status` value, not the slug

### Requirement: Expectation-Seeded Rule Generation

The system SHALL let an operator record an expected value on each vantage point
input and SHALL use those expectations to generate an initial rule table.

Expectations SHALL be authoring aids only. The evaluator SHALL NOT read
expectations; the rule table SHALL be the sole source of evaluation semantics.

Regenerating the rule table SHALL warn before overwriting rules that were edited
after generation.

#### Scenario: Generate rules from expectations

- **GIVEN** vantage points `agent-a` expected `available` and `agent-b` expected
  `blocked`, plus a boolean metadata input
- **WHEN** the operator generates the rule table
- **THEN** rules covering the expected pattern, the inverted pattern, the
  both-reachable pattern, and the neither-reachable pattern SHALL be created
- **AND** a catch-all rule SHALL be appended

#### Scenario: Edited rules override expectations

- **GIVEN** a generated rule table that the operator has since edited
- **WHEN** the check evaluates
- **THEN** the edited rules SHALL be used
- **AND** the recorded expectations SHALL have no effect on the verdict

#### Scenario: Regeneration warns before discarding edits

- **GIVEN** a rule table with edits made after generation
- **WHEN** the operator requests regeneration
- **THEN** the system SHALL warn that edits will be discarded
- **AND** SHALL regenerate only on explicit confirmation

### Requirement: Liveness Witness Validation

A composite check with two or more vantage point inputs SHALL have at least one
vantage point whose expected value is `available` before it can be enabled.

This requirement exists because with no expected-reachable vantage point, a
powered-off device satisfies an all-blocked expectation perfectly, and the check
would certify dead devices as compliant.

#### Scenario: Enabling without a liveness witness is blocked

- **GIVEN** a check whose vantage points are all expected `blocked`
- **WHEN** the operator attempts to enable it
- **THEN** the system SHALL reject enabling
- **AND** SHALL explain that without a liveness witness a powered-off device is
  indistinguishable from an isolated one

#### Scenario: Single vantage point checks are exempt

- **GIVEN** a check with exactly one vantage point
- **WHEN** the operator enables it
- **THEN** the liveness witness validation SHALL NOT apply

### Requirement: Vantage Point Coverage Readiness

The system SHALL compute, for each vantage point of a composite check, how many
devices in the check's scope have a non-stale availability row for that agent,
and SHALL surface those counts during authoring.

A composite check SHALL NOT be enabled while any vantage point has zero coverage
over the scope, unless the operator explicitly acknowledges it. Partial coverage
SHALL be surfaced with counts and SHALL NOT block enabling.

#### Scenario: Zero coverage blocks enabling

- **GIVEN** a check scoped to 412 devices whose vantage point `agent-b` has no
  availability rows for any of them
- **WHEN** the operator attempts to enable the check
- **THEN** enabling SHALL be blocked
- **AND** the system SHALL state that no sweep from `agent-b` covers this scope

#### Scenario: Partial coverage warns with counts

- **GIVEN** `agent-b` has availability rows for 72 of 412 devices in scope
- **WHEN** the operator views or saves the check
- **THEN** the system SHALL report that 340 of 412 devices have no `agent-b`
  result and will evaluate as `inconclusive`
- **AND** SHALL allow the check to be enabled

### Requirement: Verdict Persistence

The system SHALL persist one result row per `{device_uid, check_id}` carrying
the verdict, the status, the matched rule, a snapshot of every input's resolved
value and observation time, the evaluation time, and the time the verdict last
changed.

Result rows SHALL NOT be written into the device record's metadata map.

#### Scenario: Result recorded with input snapshot

- **WHEN** a device evaluates to `isolated_verified`
- **THEN** a result row SHALL record the verdict, status `healthy`, the matched
  rule, and each input's resolved value with its observation time

#### Scenario: Unchanged verdict preserves changed_at

- **GIVEN** a device whose prior verdict was `isolated_verified`
- **WHEN** it evaluates to `isolated_verified` again
- **THEN** `evaluated_at` SHALL advance
- **AND** `changed_at` SHALL be unchanged

#### Scenario: Device leaving scope drops its result

- **GIVEN** a device with a result row for a check
- **WHEN** the device no longer matches the check's scope query
- **THEN** its result row for that check SHALL be removed
- **AND** it SHALL no longer appear in that check's rollup counts

### Requirement: Shared Evaluator

The system SHALL implement decision table evaluation as a single pure function
taking resolved inputs and an ordered rule list and returning a verdict, a
status, and the matched rule.

The periodic evaluation pass, the event-driven refresh, and the authoring
preview SHALL all use that function, so that a preview cannot produce a
different verdict than a persisted evaluation for the same inputs.

#### Scenario: Preview matches production

- **GIVEN** a device whose inputs resolve to a given combination
- **WHEN** the verdict is computed by the authoring preview and by the periodic
  pass
- **THEN** both SHALL produce the same verdict, status, and matched rule

### Requirement: Periodic Evaluation

The system SHALL evaluate each enabled composite check on its configured
interval by resolving the scope query, processing devices in bounded pages,
resolving inputs per page with bounded queries, and bulk-writing results.

The periodic pass SHALL be required in addition to any event-driven refresh,
because input staleness and scope membership changes produce no event.

#### Scenario: Scheduled pass evaluates the scope

- **GIVEN** an enabled check with a five minute interval
- **WHEN** the interval elapses
- **THEN** every device in scope SHALL be evaluated
- **AND** results SHALL be written in bulk rather than per device

#### Scenario: Staleness transition is detected without an event

- **GIVEN** a device whose verdict is `isolated_verified` and whose metadata fact
  ages past its max age with no further writes
- **WHEN** the next periodic pass runs
- **THEN** the verdict SHALL become the catch-all verdict
- **AND** `changed_at` SHALL advance

#### Scenario: Scope membership change is picked up

- **GIVEN** a device that newly matches a check's scope query after an inventory
  sync
- **WHEN** the next periodic pass runs
- **THEN** the device SHALL be evaluated and SHALL gain a result row

### Requirement: Event-Driven Refresh

The system SHALL re-evaluate a device against the composite checks whose scope
contains it when one of that device's input signals changes, debounced per
device.

#### Scenario: Sweep result triggers refresh

- **GIVEN** an enabled check with a vantage point on `agent-a`
- **WHEN** a new sweep result for `agent-a` and a device in scope is ingested
- **THEN** that device SHALL be re-evaluated within the debounce window
- **AND** the result row SHALL reflect the new observation

#### Scenario: Repeated changes are debounced

- **WHEN** several input changes for the same device arrive inside the debounce
  window
- **THEN** the device SHALL be evaluated once for that window

### Requirement: Verdict Change Events

The system SHALL emit an OCSF event when a device's verdict for a check changes,
carrying the device, the check, the previous and new verdict and status, and the
resolved inputs that produced the change.

Verdict events SHALL be recorded through the same core-originated OCSF event
path used by other control-plane lifecycle events, under a system actor. A
failure to record an event SHALL NOT fail or roll back the evaluation that
produced it.

Verdicts are derived state, not metrics, and are therefore not subject to the
JetStream-first metric ingestion rule.

#### Scenario: Transition emits an event

- **GIVEN** a device whose verdict was `isolated_verified`
- **WHEN** it evaluates to `not_isolated`
- **THEN** an event SHALL be published carrying both verdicts and the inputs

#### Scenario: Unchanged verdict emits nothing

- **WHEN** a device evaluates to the same verdict as its previous evaluation
- **THEN** no verdict change event SHALL be published

#### Scenario: Event failure does not fail the evaluation

- **GIVEN** a device whose verdict changed and whose result row was written
- **WHEN** recording the verdict event fails
- **THEN** the evaluation SHALL be reported as successful
- **AND** the persisted result SHALL be retained

### Requirement: On-Demand Preview

The system SHALL provide an on-demand evaluation of an unsaved or draft
composite check against live signals, returning per-device input resolution and
verdicts, without persisting results or emitting events.

Preview SHALL evaluate a bounded sample of the scope. Rollup counts shown
alongside a preview SHALL be computed over the evaluated sample and SHALL be
labelled with the sampled and total device counts. Rollup counts for a saved and
enabled check SHALL instead be read from persisted results and cover the full
scope.

#### Scenario: Test an unsaved check

- **GIVEN** an operator editing a composite check that has not been saved
- **WHEN** they run the preview
- **THEN** the system SHALL evaluate a bounded sample of the scope using the
  current unsaved definition
- **AND** SHALL NOT write result rows or emit events

#### Scenario: Preview rollup states its sample

- **GIVEN** a draft check whose scope resolves to 412 devices
- **WHEN** the preview evaluates a bounded sample of them
- **THEN** the rollup counts SHALL be labelled as covering the sampled devices
  out of the total in scope
- **AND** SHALL NOT be presented as covering the full scope

#### Scenario: Enabled check rollup covers the full scope

- **GIVEN** an enabled check with persisted results
- **WHEN** its rollup is displayed
- **THEN** the counts SHALL be read from persisted results
- **AND** SHALL cover every device in scope

#### Scenario: Preview shows per-input detail

- **WHEN** the preview evaluates a device
- **THEN** it SHALL show each input's resolved value and observation age
- **AND** the resulting verdict and status

### Requirement: Result Reassignment On Device Merge

When device identity reconciliation merges two devices, the system SHALL
reassign composite check results from the losing device UID to the surviving
device UID, retaining one row per `{device_uid, check_id}`.

#### Scenario: Merge preserves verdicts

- **GIVEN** two device records with composite check results for the same check
- **WHEN** identity reconciliation merges them
- **THEN** the surviving device SHALL retain exactly one result row for that
  check
- **AND** no result row SHALL remain against the losing UID

### Requirement: Evaluation Error Handling

The system SHALL degrade visibly rather than silently when a composite check
cannot be fully evaluated.

An input referencing an agent or path that can no longer be resolved SHALL yield
`unknown` and SHALL surface a configuration error on the check, rather than
failing the evaluation pass. A failed evaluation pass SHALL retain the previous
results and mark them stale rather than clearing them.

#### Scenario: Vantage point agent removed

- **GIVEN** an enabled check whose vantage point references a deleted agent
- **WHEN** the check evaluates
- **THEN** that input SHALL resolve to `unknown`
- **AND** the check SHALL display a configuration error identifying the missing
  agent

#### Scenario: Evaluation pass fails

- **GIVEN** an enabled check with existing results
- **WHEN** an evaluation pass fails
- **THEN** existing result rows SHALL be retained and marked stale
- **AND** the pass SHALL be retried

### Requirement: Composite Check Authorization

The system SHALL enforce role-based access control over composite checks:
viewing checks and verdicts, managing check definitions, and running on-demand
previews SHALL be separately controlled.

#### Scenario: Viewer sees but cannot edit

- **GIVEN** a user holding only view permission
- **WHEN** they open a composite check
- **THEN** the definition SHALL be read-only
- **AND** save, enable, and delete SHALL be unavailable

#### Scenario: Operator manages checks

- **GIVEN** a user holding manage permission
- **WHEN** they edit and enable a check
- **THEN** the change SHALL be persisted
