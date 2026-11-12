## ADDED Requirements

### Requirement: No Configuration Provisions Or Consumes flow.attributed

The system SHALL NOT provision or consume the `flow.attributed.>` subject
in the default EventWriter stream configuration or any shipped release
runtime configuration: no entry may name `ATTRIBUTED_FLOW`, carry a
`flow.attributed.>` subject, or declare the `attributed_flow` stream.

#### Scenario: Release config stays free of the retired route

- **GIVEN** the shipped core release runtime configuration
- **WHEN** its EventWriter `streams` and `flow_streams` lists are enumerated
- **THEN** no entry is named `ATTRIBUTED_FLOW`
- **AND** no entry carries a subject under `flow.attributed.>`
