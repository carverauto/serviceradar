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
- Changing how singleton, device or service-target checks compute a verdict.
  What happens when a device or service target leaves the scope, or its
  evaluation fails, does change; see D6 and D8.

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
`target_label`, and used in the event message. The alert title for a row
target contains its `target_label`, so two rows of one check going down open
two alerts whose titles differ; today `AlertRuleSync` gives every target the
same title, the check name followed by `unhealthy`.

### D5. Bounds

- `max_targets` defaults to 200 and must be between 1 and 1,000 inclusive; 0 or
  a negative value is refused, because SRQL coerces a non-positive limit to 1.
  1,000 is the page size device
  fan-out already uses. The scope query is run once with limit `max_targets`,
  never more than 1,000. Completeness is decided by row count alone (D6): the
  scope is complete only when the page that came back has fewer rows than the
  limit that actually ran, which is the translated query's limit after any
  configured SRQL maximum has clamped it below `max_targets`. A page with at
  least as many rows as that limit is truncated, whether or not the runner
  returned a `next_cursor`: the translator omits the cursor past its
  configured offset cap without failing the query, so a missing cursor proves
  nothing. A truncated page's rows are evaluated, the pass records that the
  scope was truncated, and nothing is pruned or closed (D6). A scope with exactly
  `max_targets` rows therefore reports as truncated; authors size the bound
  above the expected scope. Truncation is a diagnostic on the check and sets
  no verdict: inventing a verdict for rows that were not read would be a
  guess.
- The 1,000 cap is per pass. Because a truncated pass prunes nothing, the
  stored instances of a check can exceed `max_targets` (for example after the
  bound is lowered or the scope grows) until a later complete pass prunes
  them.
- The scope query is validated exactly as a `srql_query` node's query is
  (read-only SRQL, no raw SQL, 10 second timeout). It may not contain template
  placeholders, so it is syntax-checked at authoring time.
- Edge signal nodes and credential slots are refused in an `srql_rows` check.
- Instance snapshots keep their 16 KB bound. The row stored in a `target_row`
  snapshot goes through the existing redaction and is truncated to that bound.

### D6. Departure closes the alert

A target is departed only when a complete, successful, non-truncated scope
read no longer contains its key. The departed set is the keys of the check's
existing instances minus the keys that scope read returned. "Not touched by
this pass" is not the test, because a pass also leaves untouched a target that
is still in scope but whose graph evaluation failed.

Today a departed instance is deleted and nothing is published. If its status
was `degraded`, `down` or `unknown`, the pass now first publishes a transition
to `healthy` with verdict `target_departed` and the departure marker (D9),
which the alert engine treats as recovery-only. Then it prunes.

The closing transition is published inside the pass, before the prune, by
calling the publisher directly. It is not appended to the transition list that
`Evaluation.run/1` writes after `run_for_mode` returns, because by then the
instance is already gone. A `degraded`, `down` or `unknown` departed instance
is pruned only after its closing event is accepted for delivery: the publisher
returns `{:ok, _}`, which covers both published and queued for retry. A
rejected publish (`{:error, _}`) leaves the instance in place; the next
scheduled pass finds it departed again and tries again. There is no retry
worker, and the writer's log-and-continue `:ok` is not acceptance.

Emission disabled is not rejection. When the check's
`alert_policy.emit_ocsf_transition` is false, the check has never published a
transition, so no alert can have been opened from it; its departed instances
are pruned with no event, exactly as today. A healthy departed instance is
likewise pruned with no event.

This is done for all fan-out modes. The gap exists for devices today and a
row-only fix would leave two behaviours for the same event.

A target that is in scope but whose graph evaluation failed is not departed.
Its instance and last status are kept unchanged, no transition is published
for it, it is not pruned, and the failure is recorded as a pass diagnostic on
the check. This changes today's behaviour for `srql_devices` and
`service_targets`: today such a target is dropped from the pass, its instance
is older than the pass start, and `prune_departed_targets` deletes it. Keeping
that deletion while adding the closing event would close a live alert on an
evaluation error and reopen it on the next good pass; keeping the deletion
without the event would leave the alert open with no instance behind it.

An SRQL scope read (`srql_rows` and the paged `srql_devices` stream) is
complete only when its last page has fewer rows than the limit that actually
ran for that page. A device stream whose last page is full is truncated even
when no `next_cursor` came back. A missing cursor is never evidence of
completeness.

A successful `service_targets` resolution is always the whole scope, whatever
its size, subject to D10. It loads every bound service target id, and the 1,000-id chunking
that follows is evaluation batching, not a limit, so the full-page rule does
not apply to it: a resolution of exactly 1,000 (or any multiple of 1,000)
service targets is complete, and a removed one is departed.

A truncated scope (D5) must not close alerts: a row may be missing only
because the limit cut it off. On a truncated pass nothing is treated as
departed, nothing is pruned and no `target_departed` transition is published.

A scope query that fails is not an empty scope. The pass records the failure
and neither evaluates nor prunes.

### D7. Storage

`declarative_check_instances.target_kind` gains the value `row`, and the table
gains a nullable `target_label` column. The check constraint is replaced in
one migration. `device_uid` and `service_target_id` stay null for row targets.
A row target is not linked to a device even when the row carries a device
identifier; a check about devices should use `srql_devices`.

### D8. The departure transition is never suppressed

The transition publisher drops operational events for a device that is
inactive or out of service. A device that leaves an `srql_devices` scope
because it was taken out of service is exactly that case: its instance still
carries `device_uid`, so the closing event would be suppressed, the instance
pruned, and the alert left open. The same holds for a service target whose
instance has a `device_uid`.

The `target_departed` transition is therefore delivered even for an
inactive or out-of-service device. The writer does this by passing the
publisher a suppression predicate that returns false, for this transition
only. Every other transition keeps the default predicate and the current
suppression rules. The bypass is unconditional because D9 guarantees the
transition can only close an alert, never open or renotify one, so
delivering it for an out-of-service device cannot page anyone.

### D9. Departure is recovery-only

A check's `open_on_statuses` may include `healthy`, and the alert engine's
event state machine evaluates a matched event against the rule's open clause
before its recovery clause. A plain `to_status: healthy` transition could
therefore open or renotify an alert instead of closing it.

The closing transition carries an explicit departure marker: the
`target_departed` verdict plus a dedicated boolean `target_departed: true`.
Both sit in the OCSF event's `unmapped` map next to `to_status` and
`to_verdict`, which is the stored shape the alert engine and `RuleMatcher`
read; `VerdictEventWriter` builds that map from an allowlist, so the marker is
added to it, and a marker set only on the published struct or at the event's
top level does not count. The alert engine treats an event carrying that marker as
a recovery for the matching rule and does not evaluate it against the rule's
open clause. It closes the open alert for that `check_slug` and `target_key`
if there is one and otherwise does nothing; it never opens or renotifies an
alert, including for a check whose `open_on_statuses` contains `healthy`.

### D10. An unread selector is not a resolution

A `service_targets` binding may name a `selector_query` and no `target_ids` (the key absent, null or an empty list),
and validation accepts it in all three forms. Evaluation does not read `selector_query` today:
it resolves `target_ids` and otherwise returns an empty list. That empty list
is not a successful resolution, because the selector was ignored, not run. A
non-empty `target_ids` list stays a successful resolution.

Such a pass evaluates nothing, prunes nothing and publishes no transition,
closing or otherwise. It records a pass diagnostic on the check saying the
selector is not evaluated. Validation keeps accepting the binding, so existing
saved checks stay valid. Resolving `selector_query` is a separate follow-up
change.

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
(D6, D8, D9) starts closing stale alerts for device and service-target checks on
the first pass after the upgrade, and a device or service target whose
evaluation fails keeps its instance instead of being deleted (D6).

## Open Questions

- Should `max_targets` be raised above 1,000 for row targets later, with
  paging? Nothing known needs it yet.
