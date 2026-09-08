## ADDED Requirements
### Requirement: Camera relay excludes inactive devices
Camera relay source selection SHALL exclude camera sources whose inventory device is inactive.

#### Scenario: Inactive camera has no live relay option
- **GIVEN** a camera source is linked to a device with `is_active = false`
- **WHEN** an operator requests a live camera preview or relay session
- **THEN** ServiceRadar SHALL reject or hide the live relay option
- **AND** it SHALL preserve the camera source record for archival/history views
