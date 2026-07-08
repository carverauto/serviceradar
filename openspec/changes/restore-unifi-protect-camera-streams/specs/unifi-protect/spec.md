# UniFi Protect

## ADDED Requirements

### Requirement: A UniFi Protect camera renders a live stream
An operator SHALL be able to view a live stream from a UniFi Protect camera.

#### Scenario: Live stream from a controller camera
- **GIVEN** a UniFi Protect controller reachable at a configured static host with
  a valid api_key credential rule
- **AND** the assigned agent can reach the controller RTSPS port
- **WHEN** the operator opens the camera in ServiceRadar
- **THEN** inventory yields a Camera.Source with an rtsps source_url and agent +
  gateway assignment
- **AND** the relay session reaches active and frames render in the viewer
