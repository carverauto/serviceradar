# composite-checks

## ADDED Requirements

### Requirement: Generated Verdict Dashboard

The system SHALL generate an authored dashboard from a composite check on
operator request, with panels bound to that check's SRQL `composite.<slug>`
field: one count panel per authored verdict, a table of the devices holding
each terminal verdict, and the unreachable-population statement.

Generation SHALL be idempotent per check. Regenerating after the check's
verdicts change SHALL add panels for new verdicts, remove panels for verdicts
that no longer exist, and leave panels the operator added by hand untouched.

The generated dashboard SHALL be an ordinary authored dashboard. It SHALL be
editable, shareable, and schedulable by every mechanism that applies to a
hand-authored one, and SHALL NOT require the composite check to remain enabled
in order to be viewed.

#### Scenario: Operator publishes a dashboard from a check

- **GIVEN** a saved composite check with slug `lab-isolation` whose rule table
  authors `isolated_verified`, `isolated_unenforced`, and `not_isolated`
- **WHEN** the operator publishes a dashboard from the builder
- **THEN** the system SHALL create an authored dashboard containing a count
  panel for each of the three verdicts
- **AND** each panel's query SHALL filter on `composite.lab-isolation`
- **AND** the dashboard SHALL be reachable from the dashboard library

#### Scenario: Regeneration preserves hand-authored panels

- **GIVEN** a generated dashboard to which the operator has added a panel of
  their own
- **WHEN** the check's rule table gains a verdict and the operator regenerates
- **THEN** the system SHALL add a panel for the new verdict
- **AND** SHALL leave the operator's panel in place

#### Scenario: Removing a verdict removes its generated panel

- **GIVEN** a generated dashboard with a panel for verdict `quarantined`
- **WHEN** the operator deletes the `quarantined` rule and regenerates
- **THEN** the generated panel for `quarantined` SHALL be removed
- **AND** panels for the surviving verdicts SHALL remain

### Requirement: Scheduled Verdict Report

The system SHALL let an operator schedule a recurring emailed report of a
composite check's verdicts from the check's own surface, reusing the existing
dashboard report schedule, delivery, and outbound mail machinery rather than a
second delivery path.

Scheduling a report SHALL require the check to have a generated dashboard, so
that what is emailed and what is viewed are the same artifact and cannot drift.

#### Scenario: Operator schedules a report from a check

- **GIVEN** a composite check that has a generated dashboard
- **WHEN** the operator configures recipients and a cadence on the check
- **THEN** the system SHALL persist a dashboard report schedule bound to that
  dashboard
- **AND** delivery SHALL use the deployment's configured outbound mail settings

#### Scenario: Scheduling is refused without a dashboard

- **GIVEN** a composite check with no generated dashboard
- **WHEN** the operator attempts to schedule a report
- **THEN** the system SHALL refuse
- **AND** SHALL state that a dashboard must be generated first

### Requirement: Reported Evaluation Coverage

A generated dashboard and every report rendered from it SHALL state how many
devices in the check's scope produced a verdict and how many evaluated
`inconclusive`.

This is required because a compliance report whose non-compliant count is zero
is indistinguishable from one where nothing was ever evaluated. The count of
devices that could not be evaluated SHALL be presented alongside the verdict
rollup, not in place of it and not omitted when it is zero.

#### Scenario: Report distinguishes clean from unevaluated

- **GIVEN** a check scoped to 111 devices where 48 evaluate `inconclusive` and
  no device holds a non-compliant verdict
- **WHEN** a report is rendered
- **THEN** it SHALL state that 48 of 111 devices could not be evaluated
- **AND** SHALL NOT present the result as full compliance

#### Scenario: Full coverage is stated explicitly

- **GIVEN** a check where every device in scope produced a verdict
- **WHEN** a report is rendered
- **THEN** it SHALL state that 0 devices were unevaluated

### Requirement: Freshness Window Feasibility

The system SHALL compare each vantage point's `max_age_seconds` against the
interval of the sweep groups that cover that vantage point's agent, and SHALL
warn during authoring when the freshness window is shorter than the sweep
interval, naming both values.

A window shorter than the interval that feeds it means the input is stale for
most of every cycle, so the check reaches no verdict for most of its life. This
is a warning and not a blocker: the operator may be about to shorten the sweep
interval, and the check is still correct, merely dormant.

The comparison SHALL use the same agent-to-sweep-group resolution as the
coverage readiness report, including sweep groups assigned to no agent, which
cover every agent in their partition.

#### Scenario: Window shorter than the sweep interval warns

- **GIVEN** a vantage point on `agent-b` with `max_age_seconds` of 900
- **AND** the only sweep group covering `agent-b` runs hourly
- **WHEN** the operator views or saves the check
- **THEN** the system SHALL warn that the 900 second freshness window is
  shorter than the 3600 second sweep interval
- **AND** SHALL state that the input will be stale for most of each cycle
- **AND** SHALL NOT block enabling

#### Scenario: Window longer than the sweep interval does not warn

- **GIVEN** a vantage point on `agent-b` with `max_age_seconds` of 5400
- **AND** the only sweep group covering `agent-b` runs hourly
- **WHEN** the operator views or saves the check
- **THEN** the system SHALL NOT raise a freshness feasibility warning

#### Scenario: No covering sweep group raises no freshness warning

- **GIVEN** a vantage point whose agent no sweep group covers
- **WHEN** the operator views or saves the check
- **THEN** the system SHALL NOT raise a freshness feasibility warning
- **AND** the existing zero-coverage readiness behaviour SHALL apply instead
