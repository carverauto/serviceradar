## ADDED Requirements

### Requirement: MTR fleet analytics separates a shared path fault from a failing endpoint

The MTR analytics dashboard SHALL let an operator determine, for a chosen set of devices, whether loss originates on a shared network path or at the endpoints themselves, and SHALL NOT present a single fleet-wide loss figure as the answer.

To that end it SHALL provide loss broken down by hop position, loss by hop address accompanied by the number of traces traversing that address, and reach rate per target. A hop address carrying high loss across many traces indicates a shared path; low reach rate spread across targets whose upstream hops are clean indicates the endpoints.

Every panel SHALL be scopeable to a device set by target address, since a fleet-wide aggregate cannot answer a question asked about particular devices.

#### Scenario: A shared upstream fault is identifiable
- **GIVEN** many devices whose traces traverse a common hop address that is losing probes
- **WHEN** an operator loads the dashboard scoped to those devices
- **THEN** that hop address appears with high loss and a high trace count
- **AND** the operator can distinguish it from a hop seen in only one or two traces

#### Scenario: Failing endpoints are identifiable
- **GIVEN** several devices that are not being reached while their upstream hops are clean
- **WHEN** an operator loads the dashboard scoped to those devices
- **THEN** reach rate per target identifies those devices
- **AND** no shared hop address carries the loss

#### Scenario: Panels are scopeable to a device set
- **WHEN** an operator narrows the dashboard to a chosen set of target addresses
- **THEN** every panel reflects only those devices

### Requirement: Loss attributable to ICMP deprioritization is not presented as a fault

The MTR analytics dashboard SHALL NOT rank hop addresses by loss without qualification, because routers deprioritize replies to probes addressed to themselves and report loss they are not causing.

Loss SHALL be presented in a form that lets a reader tell a real fault from that artifact: broken down by hop position, so loss beginning at a position and continuing is distinguishable from loss at a single position, and accompanied by trace counts. Panel titles and captions SHALL state what is being measured, so a rate-limiting mid-path router is not read as a network fault.

Determining whether loss at a hop persists to subsequent hops requires comparing hop positions within a trace, which the query language cannot express; the dashboard SHALL NOT imply it settles that question. The per-hop trace detail view remains where a finding is confirmed.

#### Scenario: A mid-path rate-limiting router is not ranked as the top fault
- **GIVEN** a mid-path router reporting loss on probes addressed to itself while traffic through it is unaffected
- **WHEN** an operator loads the dashboard
- **THEN** the presentation does not rank that router as the fleet's worst fault without qualification
- **AND** the operator can see that loss does not continue past it

#### Scenario: The dashboard points at the trace detail view for confirmation
- **WHEN** an operator identifies a candidate hop on the dashboard
- **THEN** the dashboard directs them to the per-hop trace view to confirm whether loss persists downstream

#### Scenario: An unqualified fleet-wide loss figure is not presented as the headline
- **WHEN** an operator loads the dashboard
- **THEN** no panel presents loss aggregated across all hop positions as the fleet's loss rate without stating what it includes
