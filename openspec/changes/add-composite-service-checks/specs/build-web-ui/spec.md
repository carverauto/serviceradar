## ADDED Requirements

### Requirement: Composite Check Index

The web UI SHALL provide a composite check index listing each check with its
state, scope size, and verdict rollup across its scope.

#### Scenario: View configured checks

- **WHEN** an operator opens the composite check index
- **THEN** each check SHALL show its name, state, device count in scope, and a
  breakdown of devices per verdict

#### Scenario: Rollup reflects current results

- **GIVEN** a check whose scope contains 412 devices
- **WHEN** the index renders its rollup
- **THEN** the counts per verdict SHALL sum to the number of devices with result
  rows for that check

### Requirement: Composite Check Builder

The web UI SHALL provide a composite check builder with a scope section, a
vantage point section, a verdict rule table, and a live preview.

The scope section SHALL reuse the existing SRQL visual query builder so that the
raw SRQL string and the visual filter rows edit the same state in either
direction.

#### Scenario: Compose a scope visually

- **WHEN** an operator adds filters `source equals armis` and `tag equals managed`
  in the visual builder
- **THEN** the raw SRQL field SHALL show the equivalent query
- **AND** the matching device count SHALL be displayed

#### Scenario: Edit raw SRQL and see the builder update

- **WHEN** an operator edits the raw SRQL scope directly
- **THEN** the visual filter rows SHALL update to match
- **AND** an unparseable query SHALL leave the raw string authoritative and warn

#### Scenario: Add a vantage point with an expectation

- **WHEN** an operator adds agent `agent-a` and sets it to should-see `available`
- **THEN** the vantage point SHALL be recorded with that expectation
- **AND** SHALL be labelled as the liveness witness

#### Scenario: Edit the generated verdict table

- **GIVEN** a rule table generated from the vantage point expectations
- **WHEN** the operator edits a row's verdict, description, or status
- **THEN** the edited rule SHALL be persisted
- **AND** SHALL be used for evaluation in place of the generated value

### Requirement: Composite Check Live Preview

The builder SHALL provide a live preview showing, for a sampled device in scope,
what each vantage point observed, what each metadata fact resolved to with its
age, and the resulting verdict, alongside rollup counts across the scope.

#### Scenario: Preview a device

- **WHEN** the preview samples a device in scope
- **THEN** it SHALL show each vantage point's per-probe outcome and status
- **AND** each metadata fact's value and age
- **AND** the verdict and its explanation

#### Scenario: Preview explains an inconclusive population

- **GIVEN** devices unreachable from every vantage point
- **WHEN** the preview renders rollup counts
- **THEN** it SHALL state how many devices no vantage point can see
- **AND** SHALL state that they cannot be counted as compliant

#### Scenario: Draft rollup is labelled as sampled

- **GIVEN** a draft check whose preview evaluated a bounded sample of the scope
- **WHEN** the rollup renders
- **THEN** it SHALL show the sampled count against the total in scope
- **AND** SHALL NOT present the counts as covering the full scope

### Requirement: Composite Check Authoring Validation Feedback

The builder SHALL surface save-time and enable-time validation failures in place,
naming the specific problem.

#### Scenario: Missing liveness witness is explained

- **WHEN** an operator attempts to enable a check whose vantage points are all
  expected blocked
- **THEN** the UI SHALL block enabling
- **AND** SHALL explain that without a liveness witness a powered-off device is
  indistinguishable from an isolated one

#### Scenario: Coverage gap is reported with counts

- **GIVEN** a vantage point with results for only some devices in scope
- **WHEN** the operator saves the check
- **THEN** the UI SHALL state how many devices lack results from that vantage
  point and will evaluate as inconclusive

#### Scenario: Zero coverage requires acknowledgement

- **GIVEN** a vantage point with no results for any device in scope
- **WHEN** the operator attempts to enable the check
- **THEN** enabling SHALL require an explicit acknowledgement of the gap

### Requirement: Sweep Configuration Is Referenced, Not Edited

The composite check builder SHALL display the sweep configuration that produces
its vantage point signals as read-only context, and SHALL link to the sweep
administration UI for changes.

A vantage point names an agent, and an agent is covered by every sweep group
explicitly assigned to it plus every group assigned to no agent in its
partition. The builder SHALL therefore display all covering groups rather than a
single profile, and SHALL state when there are none.

#### Scenario: Sweep coverage shown read-only

- **WHEN** an operator views a check whose vantage point is covered by one or
  more sweep groups
- **THEN** each covering group's probes and ports SHALL be displayed as context
- **AND** editing them SHALL navigate to the sweep administration UI

#### Scenario: Every covering group is shown

- **GIVEN** a vantage point whose agent is covered by more than one sweep group
- **WHEN** the builder renders sweep context
- **THEN** every covering group SHALL be listed
- **AND** no single group SHALL be presented as the check's scan profile

#### Scenario: A vantage point with no sweep coverage is named

- **GIVEN** a vantage point whose agent is covered by no sweep group
- **WHEN** the builder renders sweep context
- **THEN** it SHALL state that no sweep group covers that agent

### Requirement: Device Composite Verdict Surfacing

The device detail page SHALL display each composite check verdict that applies
to the device, with the per-input breakdown that produced it, and SHALL link to
the check.

The device list SHALL support an optional composite verdict column and filter.

#### Scenario: Verdict on device detail

- **WHEN** a user opens a device in the scope of an enabled check
- **THEN** the verdict and status SHALL be shown
- **AND** each input's resolved value and observation age SHALL be shown

#### Scenario: Missing inputs are stated, not blank

- **GIVEN** a device with no result from one vantage point
- **WHEN** the verdict breakdown renders
- **THEN** that input SHALL be shown as unknown with the reason
- **AND** SHALL NOT render as an empty value or raw JSON

#### Scenario: Filter the device list by verdict

- **WHEN** a user filters the device list by a composite verdict
- **THEN** only devices holding that verdict SHALL be listed
