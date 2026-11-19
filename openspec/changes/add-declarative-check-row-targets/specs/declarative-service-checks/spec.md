## MODIFIED Requirements

### Requirement: Unified Singleton and Dynamic Target Fan-Out
The system SHALL support `target_binding` modes `singleton`, `srql_devices` (`in:devices ...`), `service_targets`, and `srql_rows`, materializing per-target verdicts (`healthy` | `degraded` | `down` | `unknown`) in `platform.declarative_check_instances` and projecting current availability into `platform.service_state` (`ServiceRadar.Observability.ServiceState`).

#### Scenario: Dynamic SRQL device fan-out evaluates per target and prunes departed devices
- **GIVEN** an enabled declarative check with `target_binding: {"mode": "srql_devices", "scope_query": "in:devices tags.role:edge-gateway"}` matching two synthetic devices `dev-1` (`192.0.2.10`) and `dev-2` (`192.0.2.11`)
- **WHEN** the scheduled evaluation pass runs and later `dev-2` loses the `edge-gateway` tag
- **THEN** the first pass SHALL materialize per-device `DeclarativeCheckInstance` and `ServiceState` verdicts for `dev-1` and `dev-2` with safe `{{target.*}}` interpolation and per-device credential-rule matching
- **AND** the subsequent pass SHALL prune `dev-2` from `platform.declarative_check_instances` and mark its `ServiceState` projection `"inactive"`

#### Scenario: DIRE device merge reassigns declarative check instances
- **GIVEN** a `DeclarativeCheckInstance` recorded for `device_uid: "sr:loser-0001"`
- **WHEN** DIRE merges `"sr:loser-0001"` into `"sr:winner-0001"`
- **THEN** `DeclarativeCheckInstance.reassign_device/2` SHALL re-key or deduplicate the instance onto `"sr:winner-0001"` without leaving orphaned rows

#### Scenario: Row fan-out materializes one instance per scope query row
- **GIVEN** an enabled declarative check with `target_binding: {"mode": "srql_rows", "scope_query": "in:virtualization_datastores time:last_1h", "key_fields": ["host_name", "name"]}` whose scope query returns three synthetic rows for datastores `tank01`, `tank02` and `tank03`
- **WHEN** the scheduled evaluation pass runs
- **THEN** the pass SHALL execute the scope query once
- **AND** SHALL materialize three `DeclarativeCheckInstance` rows with `target_kind: "row"`, three distinct `target_key` values and null `device_uid` and `service_target_id`
- **AND** SHALL project one `ServiceState` per row target

## ADDED Requirements

### Requirement: Row Target Identity and Labels
The system SHALL derive each `srql_rows` target's identity from the binding's ordered, non-empty `key_fields`, as `row:` followed by the lowercase hexadecimal SHA-256 of the canonical JSON array of the row's key values, and SHALL give each row target a label of at most 200 characters, rendered from the binding's optional `label_template` or, without one, from the key values joined with ` / `.

#### Scenario: The same row keeps its identity across passes
- **GIVEN** a row target created for a row whose key fields are `host_name: "hv-a"` and `name: "tank01"`
- **WHEN** a later pass returns that row with the same key values and different values in every other field
- **THEN** the pass SHALL update the existing instance and SHALL NOT create a second one

#### Scenario: A label template names the target
- **GIVEN** a binding with `label_template: "{{target.row.name}} on {{target.row.host_name}}"`
- **WHEN** the row with `name: "tank01"` and `host_name: "hv-a"` is evaluated
- **THEN** the instance's `target_label` SHALL be `tank01 on hv-a`

#### Scenario: A row without a complete key is not evaluated
- **WHEN** the scope query returns a row in which a key field is missing or null
- **THEN** the pass SHALL NOT create or update an instance for that row
- **AND** SHALL evaluate the other rows
- **AND** SHALL record on the check that one row was skipped for an incomplete key

#### Scenario: Rows with the same key are not all evaluated
- **WHEN** the scope query returns two rows with identical key values
- **THEN** the pass SHALL evaluate the first in query order and SHALL NOT evaluate the second
- **AND** SHALL record on the check that one row was skipped for a duplicate key

#### Scenario: A binding without key fields is refused
- **WHEN** a check with `target_binding.mode: "srql_rows"` and no `key_fields`, an empty `key_fields`, or no `scope_query` is validated
- **THEN** validation SHALL fail with a diagnostic naming the missing field

### Requirement: Row Data Is the Check's Signal
The system SHALL provide a `target_row` core signal node that outputs the current row target's row as its payload without executing a query, SHALL expose that row to templates as `{{target.row.<field>}}` and the target's label as `{{target.label}}`, and SHALL present a row to `srql_rows` targets as one flat object regardless of how its SRQL entity shapes its result columns.

#### Scenario: A threshold is judged against the row the scope query returned
- **GIVEN** a check whose graph is `target_row` to `threshold_assert` (`field: "used_percent"`, `warn >= 80`, `crit >= 90`) to `alert_output`, bound to rows with `used_percent` of `72`, `85` and `95`
- **WHEN** the pass runs
- **THEN** the three instances SHALL have status `healthy`, `degraded` and `down` respectively
- **AND** the pass SHALL have executed exactly one SRQL query

#### Scenario: A single-object entity row is flattened
- **GIVEN** a scope query over an entity whose rows consist of one `payload` object
- **WHEN** a `target_row` node evaluates
- **THEN** `field: "used_percent"` SHALL resolve to the value inside that object

#### Scenario: target_row outside a row check is refused
- **WHEN** a check whose `target_binding.mode` is not `srql_rows` contains a `target_row` node
- **THEN** validation SHALL fail with a diagnostic on that node

### Requirement: Bounded Row Fan-Out
The system SHALL bound an `srql_rows` check to `max_targets` row targets per pass, defaulting to 200 and refusing a value above 1,000, SHALL run the scope query with a limit of at most `max_targets` and treat the scope as complete only when the returned page is short of the limit that actually ran, SHALL treat a page with at least as many rows as that limit as truncated whether or not a `next_cursor` was returned, SHALL validate the scope query as read-only SRQL without template placeholders, and MUST refuse edge signal nodes and credential slots in an `srql_rows` check.

#### Scenario: A scope larger than the bound is truncated and reported
- **GIVEN** a binding with `max_targets: 2` whose scope query matches three rows
- **WHEN** the pass runs
- **THEN** the pass SHALL evaluate two rows
- **AND** SHALL record on the check that the scope was truncated
- **AND** SHALL NOT assign any verdict to the row it did not evaluate

#### Scenario: A truncated pass does not treat unseen rows as departed
- **GIVEN** a row target with status `down` that the truncated pass did not evaluate
- **WHEN** the pass finishes
- **THEN** the pass SHALL NOT prune that instance and SHALL NOT publish a transition for it

#### Scenario: A full page under a clamped limit is truncated
- **GIVEN** a binding with `max_targets: 200` whose scope query is clamped by a configured SRQL maximum of 100 and matches 150 rows, one of them a row target at status `down` with an open alert that the returned page does not contain
- **WHEN** the pass runs and the page holds 100 rows
- **THEN** the pass SHALL record on the check that the scope was truncated
- **AND** SHALL NOT prune that row target and SHALL NOT publish a transition for it

#### Scenario: A full page without a cursor is truncated
- **GIVEN** a binding with `max_targets: 200` whose scope query matches 250 rows, one of them a row target at status `down` with an open alert that the returned page does not contain
- **WHEN** the pass runs, the page holds 200 rows and the runner returns no `next_cursor`
- **THEN** the pass SHALL record on the check that the scope was truncated
- **AND** SHALL NOT prune that row target and SHALL NOT publish a transition for it

#### Scenario: A failed scope query is not an empty scope
- **GIVEN** an `srql_rows` check with three existing row targets
- **WHEN** the scope query fails or times out
- **THEN** the pass SHALL record the failure on the check
- **AND** SHALL NOT prune any instance and SHALL NOT publish any transition

#### Scenario: Edge nodes and credential slots are refused
- **WHEN** a check with `target_binding.mode: "srql_rows"` containing an `http_request` node or a non-empty `credential_slots` list is validated
- **THEN** validation SHALL fail with a diagnostic naming the node or the slot

#### Scenario: An oversized bound is refused
- **WHEN** a binding declares `max_targets: 1001`
- **THEN** validation SHALL fail with an out-of-range diagnostic

### Requirement: Per-Target Alerts That Name and Close
The system SHALL carry a row target's label on its OCSF `health.state_change` transition event as `target_label` and in the event message, so that each row target opens, renotifies and recovers its own alert, and SHALL publish a transition to `healthy` with verdict `target_departed` for any fan-out target (device, service target or row) whose status was `degraded`, `down` or `unknown` when it leaves the scope, before pruning its instance. A target SHALL be treated as departed only when a complete, successful, non-truncated scope read no longer contains its key, where an SRQL scope read (`srql_rows` or the `srql_devices` stream) is complete only when its last page has fewer rows than the limit that actually ran, the absence of a `next_cursor` SHALL NOT be taken as completeness, and a successful `service_targets` resolution SHALL be treated as the whole scope whatever its size; a target still in scope whose graph evaluation failed SHALL keep its instance and last status unchanged, SHALL NOT be pruned or produce a transition, and SHALL be recorded as a pass diagnostic on the check. The `target_departed` transition SHALL be delivered even when operational-event suppression would drop events for the target's device, and every other transition SHALL keep the existing suppression. The closing transition SHALL carry the `target_departed` verdict and a boolean `target_departed: true` event field, and the alert engine MUST treat an event carrying that marker as a recovery for the matching rule and MUST NOT evaluate it against the rule's open clause, so that it never opens or renotifies an alert, including for a check whose `open_on_statuses` contains `healthy`.

#### Scenario: A second row going down opens a second alert
- **GIVEN** a row check with an alert open for target `tank01 on hv-a`
- **WHEN** a later pass finds the row for `tank02 on hv-a` at status `down`
- **THEN** a transition event SHALL be published for that target with its own `target_key` and `target_label: "tank02 on hv-a"`
- **AND** the rule grouped by `check_slug` and `target_key` SHALL open a second alert without changing the first

#### Scenario: One row recovering closes only its alert
- **GIVEN** alerts open for `tank01 on hv-a` and `tank02 on hv-a`
- **WHEN** a pass finds `tank01` at status `healthy` and `tank02` still `down`
- **THEN** a recovery transition SHALL be published for `tank01` only

#### Scenario: A departed row's alert is closed
- **GIVEN** a row target with status `down` and an open alert
- **WHEN** a complete, successful pass no longer returns that row
- **THEN** the pass SHALL publish a transition for that target to status `healthy` with verdict `target_departed`
- **AND** SHALL then prune the instance and mark its `ServiceState` projection `"inactive"`

#### Scenario: A departed healthy target publishes nothing
- **GIVEN** a fan-out target with status `healthy`
- **WHEN** it leaves the scope
- **THEN** the pass SHALL prune its instance without publishing a transition

#### Scenario: A departed device's alert is closed
- **GIVEN** an `srql_devices` check with a device target at status `down` and an open alert
- **WHEN** the device leaves the scope query
- **THEN** the pass SHALL publish a transition for that target to status `healthy` with verdict `target_departed` before pruning it

#### Scenario: A failed evaluation is not a departure
- **GIVEN** an `srql_devices` check with device target `dev-1` at status `down` and an open alert
- **WHEN** a pass's scope read succeeds and still contains `dev-1` but evaluating the graph for `dev-1` returns an error
- **THEN** the pass SHALL keep the instance for `dev-1` with status `down`
- **AND** SHALL NOT publish a transition for `dev-1` and SHALL NOT prune it
- **AND** SHALL record on the check that the evaluation of one target failed

#### Scenario: A departed out-of-service device's alert is closed
- **GIVEN** an `srql_devices` check scoped to in-service devices, with device target `dev-2` at status `down` and an open alert
- **WHEN** `dev-2` is marked out of service and a later pass no longer returns it from the scope query
- **THEN** the pass SHALL publish the `healthy` / `target_departed` transition for `dev-2` without operational-event suppression
- **AND** the alert for `dev-2` SHALL close
- **AND** SHALL then prune the instance

#### Scenario: A device stream whose last page is full is not complete
- **GIVEN** an `srql_devices` check with device target `dev-3` at status `down` and an open alert
- **WHEN** a pass reads the device scope and its last page holds as many devices as the limit that ran, with no `next_cursor`, and does not contain `dev-3`
- **THEN** the pass SHALL treat the scope as truncated
- **AND** SHALL NOT prune `dev-3` and SHALL NOT publish a transition for it

#### Scenario: A removed service target is departed in a resolution of exactly 1,000
- **GIVEN** a `service_targets` check bound to exactly 1,000 synthetic service targets, one of them `svc-0042` at status `down` with an open alert
- **WHEN** `svc-0042` is removed from the binding, another is added so the resolution still holds exactly 1,000 service targets, and the next pass resolves them successfully
- **THEN** the pass SHALL treat the resolution as complete
- **AND** SHALL publish the `healthy` / `target_departed` transition for `svc-0042`, close its alert and prune its instance

#### Scenario: Departure never opens an alert when healthy is an open status
- **GIVEN** a check whose alert rule has `open_on_statuses: ["down", "healthy"]`, with device target `dev-4` at status `down` and an open alert
- **WHEN** `dev-4` leaves the scope of a complete, successful scope read
- **THEN** the pass SHALL publish a transition for `dev-4` with verdict `target_departed` and event field `target_departed: true`
- **AND** the alert engine SHALL close the open alert for `dev-4`
- **AND** SHALL NOT open or renotify any alert for that event
