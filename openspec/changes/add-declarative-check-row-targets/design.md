## Context

A declarative check is a small graph of signal, transform and verdict nodes
evaluated once per target. `Evaluation.run_for_mode/5` resolves the targets,
`DAGEngine.evaluate_target/3` evaluates the graph for one, and
`persist_instances/5` upserts a `DeclarativeCheckInstance` per target and
returns the transitions that `VerdictEventWriter` publishes. Alerting keys on
`check_slug` and `target_key`.

The missing piece is a target that is neither a device nor a service target
but a row of some other inventory entity.

## Goals / Non-Goals

Goals:

- One verdict, one service state and one alert per row of a scope query.
- One scope query per pass, not one query per row.
- An alert that names the row and closes when the row recovers or disappears.
- Bounded cost and no new way to read data a check could not already read.

Non-goals:

- Edge execution against row targets.
- A general join or aggregation language. The scope query is ordinary SRQL.
- Changing how singleton, device or service-target checks evaluate.

## Decisions

### D1. A new target mode, not a new node

The alternative is a node that loops over rows inside a singleton check and
emits many verdicts. That would need a second instance model beside targets,
and alerting, service state, pruning and the results entity all key on
`target_key` already. A target mode reuses all of it.

```json
"target_binding": {
  "mode": "srql_rows",
  "scope_query": "in:virtualization_datastores time:last_1h",
  "key_fields": ["host_name", "name"],
  "label_template": "{{target.row.name}} on {{target.row.host_name}}",
  "max_targets": 200
}
```

### D2. The row is the signal

A `target_row` core signal node outputs the row as its payload. A typical
check is `target_row -> threshold_assert -> alert_output`, and evaluates
without touching the database again. A check may still add `srql_query` nodes
that interpolate `{{target.row.*}}`; those run per target and are subject to
D5.

SRQL entities do not return rows in one shape: some return columns, some a
single `payload` object. The runner hands `srql_rows` and `target_row` the
flattened row (the `payload` object when a row consists of exactly that
column), so `field: "used_percent"` means the same thing for every entity.
The existing `srql_query` node keeps its current payload shape; changing it
would break shipped checks.

### D3. Identity comes from declared key fields

`key_fields` is an ordered, non-empty list of row field paths. The target key
is `row:` followed by the lowercase hex SHA-256 of the canonical JSON array of
the key values, so it is bounded in length and safe to store and index
whatever the values contain. The readable form goes in the label (D4).

A row with a missing or null key field has no identity and is not evaluated.
Two rows with the same key are ambiguous: the first in query order is
evaluated and the rest are not. Both cases are counted on the pass and surface
on the check as a diagnostic. Choosing silently, or failing the whole pass for
one bad row, were the alternatives; the first hides an authoring error and the
second lets one malformed row blind every other target.

Row identity is whatever the author declares. A key built from a mutable
field (a display name) makes a renamed row look like a departure and an
arrival. That is the author's choice and the documentation says so.

### D4. A label, carried to the alert

`label_template` is optional and interpolates `{{target.row.*}}`. Without it
the label is the key values joined with ` / `. The label is truncated to 200
characters, stored on the instance, added to the transition event as
`target_label`, and used in the event message. Alert titles for row targets
use it.

### D5. Bounds

- `max_targets` defaults to 200 and may not exceed 1,000, the page size device
  fan-out already uses. The scope query is run with that limit plus one; if
  more rows come back, the first `max_targets` are evaluated and the pass
  records that the scope was truncated. Truncation is a diagnostic on the
  check and sets no verdict: inventing a verdict for rows that were not read
  would be a guess.
- The scope query is validated exactly as a `srql_query` node's query is
  (read-only SRQL, no raw SQL, 10 second timeout). It may not contain template
  placeholders, so it is syntax-checked at authoring time.
- Edge signal nodes and credential slots are refused in an `srql_rows` check.
- Instance snapshots keep their 16 KB bound. The row stored in a `target_row`
  snapshot goes through the existing redaction and is truncated to that bound.

### D6. Departure closes the alert

When a pass finishes, an instance it did not touch belongs to a target that
left the scope. Today that instance is deleted and nothing is published. If
its status was `degraded`, `down` or `unknown`, the pass now first publishes a
transition to `healthy` with verdict `target_departed`, which the rule's
existing recovery clause matches. Then it prunes.

This is done for all fan-out modes. The gap exists for devices today and a
row-only fix would leave two behaviours for the same event.

A truncated scope (D5) must not close alerts: a row may be missing only
because the limit cut it off. On a truncated pass nothing is treated as
departed.

A scope query that fails is not an empty scope. The pass records the failure
and neither evaluates nor prunes.

### D7. Storage

`declarative_check_instances.target_kind` gains the value `row`, and the table
gains a nullable `target_label` column. The check constraint is replaced in
one migration. `device_uid` and `service_target_id` stay null for row targets.
A row target is not linked to a device even when the row carries a device
identifier; a check about devices should use `srql_devices`.

## Risks / Trade-offs

- **A noisy scope query produces many alerts at once.** A threshold change can
  open one alert per row. `max_targets` bounds it, and the existing per-check
  alert policy (cooldown, renotify) applies per target. Grouped notification
  is out of scope.
- **Identity chosen badly churns alerts.** Covered by D3 and documentation.
- **An empty scope looks healthy.** Zero rows means zero instances, so a check
  cannot report "the inventory stopped arriving" by itself. Packs pair row
  checks with a singleton freshness check. This is stated in the docs rather
  than solved by inventing a synthetic target.
- **Two validators.** The pack CLI mirrors the core schema in TypeScript, as it
  does for the other modes.

## Migration Plan

Additive. Existing checks and packs are untouched. The departure transition
(D6) starts closing stale alerts for device and service-target checks on the
first pass after the upgrade.

## Open Questions

- Should `max_targets` be raised above 1,000 for row targets later, with
  paging? Nothing known needs it yet.
