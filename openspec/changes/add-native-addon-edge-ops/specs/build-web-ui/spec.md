## ADDED Requirements

### Requirement: Edge Ops add-on approval review
Edge Ops SHALL provide an approval-review surface for a staged `AddonPackage` that
shows its manifest, declared capabilities, delivery/supervision model, and provenance,
and lets an authorized operator approve or deny it. On approval the operator SHALL be
able to narrow the granted capability set; the narrowed set is what the control plane
sends to agents.

#### Scenario: Operator approves a staged package with narrowed capabilities
- **GIVEN** a staged `AddonPackage` with declared capabilities
- **WHEN** an authorized operator approves it and narrows the granted capabilities
- **THEN** the package SHALL transition to approved
- **AND** only the narrowed capability set SHALL be eligible for delivery to agents

#### Scenario: Denied package is not assignable
- **GIVEN** a staged `AddonPackage`
- **WHEN** an operator denies it
- **THEN** it SHALL NOT be assignable to any agent

### Requirement: Edge Ops add-on cohort targeting and drift
Edge Ops SHALL let an operator target an add-on to a cohort, reusing the agent-release
cohort selection and compatibility-preview pattern, in addition to per-agent
assignment. The per-agent detail SHALL show assigned vs. installed vs. active add-ons
and SHALL surface drift, including assigned-but-not-active, unhealthy, and
architecture-unsupported states.

#### Scenario: Cohort assignment fans out to members
- **GIVEN** a cohort and an approved add-on
- **WHEN** the operator assigns the add-on to the cohort
- **THEN** an assignment SHALL be recorded for each cohort member
- **AND** the compatibility preview SHALL flag members whose architecture is unsupported

#### Scenario: Drift is surfaced on the per-agent detail
- **GIVEN** an agent with an add-on assigned but reported not-active or unhealthy
- **WHEN** the operator views the agent detail
- **THEN** the UI SHALL show the add-on as drifted with its observed state

### Requirement: Onboarding feature-set selection
The onboarding package flow SHALL let an operator select an initial feature set
(one or more add-ons) so a newly onboarded agent comes up with those assignments
already in place.

#### Scenario: Initial feature set is selected at onboarding
- **GIVEN** an operator creating an onboarding package
- **WHEN** they select an initial feature set
- **THEN** the selected add-ons SHALL be assigned to the agent on onboarding
