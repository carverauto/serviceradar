# UniFi Protect Camera Plugin

## ADDED Requirements

### Requirement: The plugin reaches controllers addressed by private IP
The UniFi Protect manifests SHALL declare the private address space required to
reach a controller, because a UniFi OS controller is normally addressed by
private IP rather than by hostname.

#### Scenario: Controller at a private IP is reachable
- **GIVEN** a credential rule whose controller host is `192.168.1.1`
- **WHEN** the camera inventory check runs
- **THEN** the request SHALL NOT be denied by the egress policy

### Requirement: A failed collection is reported as a failure, not an empty inventory
The plugin SHALL name the cause in its reported summary when the controller
cannot be reached or authenticated, rather than reporting a bare camera count.

#### Scenario: Collection error is surfaced
- **GIVEN** a check whose bootstrap and integration endpoints both failed
- **WHEN** the plugin reports its result
- **THEN** the status SHALL be CRITICAL
- **AND** the summary SHALL include the collection error alongside the camera count
