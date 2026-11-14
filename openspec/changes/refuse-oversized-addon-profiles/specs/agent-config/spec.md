## ADDED Requirements
### Requirement: Add-On Profile Target Limit
Add-on profile reconciliation SHALL read a profile's whole target query and SHALL refuse, whole, a profile whose target query selects more distinct agents than its `max_targets`. The system SHALL NOT cut a profile's targets down to its `max_targets`, and SHALL NOT treat one page of the target query as the whole selection.

#### Scenario: Profile over max_targets is refused whole
- **GIVEN** an enabled add-on profile with `max_targets` 2
- **AND** its target query selects three agents
- **WHEN** add-on profile reconciliation runs
- **THEN** the system SHALL materialize no assignments for the profile
- **AND** the system SHALL disable the profile's existing assignments
- **AND** the reconcile summary SHALL record the profile as refused, with a message naming the limit
- **AND** the system SHALL emit a target-limit telemetry event for the profile.

#### Scenario: Other add-on config still delivers
- **GIVEN** an agent selected by a refused add-on profile
- **AND** the agent has an add-on assignment from another profile or a manual assignment
- **WHEN** add-on profile reconciliation refuses the profile
- **THEN** the other assignment SHALL remain enabled and SHALL still be delivered to the agent.

#### Scenario: Selection larger than one SRQL page
- **GIVEN** an add-on profile whose target query selects more agents than one SRQL page returns
- **AND** the selection is within the profile's `max_targets`
- **WHEN** add-on profile reconciliation runs
- **THEN** every selected agent SHALL be a target of the profile.

#### Scenario: Saving a profile over max_targets
- **GIVEN** an operator saves an enabled add-on profile
- **AND** its target query selects more agents than its `max_targets`
- **WHEN** the save is submitted
- **THEN** the save SHALL fail with a message naming the limit and how to narrow the profile.
