## ADDED Requirements

### Requirement: Edge onboarding events are mirrored into OCSF
The system SHALL write an OCSF Event Log Activity entry when an edge onboarding lifecycle event is recorded so the Events UI can display onboarding activity.

#### Scenario: Onboarding package event appears in OCSF
- **GIVEN** an onboarding package is created or delivered
- **WHEN** the onboarding event is recorded
- **THEN** an `ocsf_events` row SHALL be inserted for the tenant
- **AND** the OCSF event SHALL include the package ID and event type
