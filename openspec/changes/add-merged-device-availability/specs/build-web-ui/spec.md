## ADDED Requirements

### Requirement: Device Availability Badge Reads Canonical State
The device list and device detail pages SHALL render each device's availability badge from the device's canonical availability state, and web-ng MUST NOT compute an availability value of its own for the badge.
The badge SHALL show Online, Offline or Unknown. It SHALL show a conflict marker when lower-ranked evidence disagrees, and its tooltip SHALL name the deciding source and the time of the decision.

#### Scenario: Badge agrees with sort and count
- **GIVEN** a device counted in the Available stat card
- **WHEN** the device list renders
- **THEN** the device's badge SHALL show Online
- **AND** the device SHALL sort with the other available devices

#### Scenario: Controller-decided device with failing sweeps
- **GIVEN** a device resolved available by its managing controller while every sweep agent fails to reach it
- **WHEN** the device list renders
- **THEN** the badge SHALL show Online with a conflict marker
- **AND** the tooltip SHALL name the controller source as the deciding source

#### Scenario: Unknown device
- **GIVEN** a device with no fresh availability evidence
- **WHEN** the device list renders
- **THEN** the badge SHALL show Unknown
- **AND** the Unknown stat card SHALL include the device

### Requirement: Device Detail Explains Availability
The device detail page SHALL show the device's availability evidence, one row per evidence record, with source kind, authority class, state, observed time, expiry, confirmations, reporter eligibility and which record decided. It SHALL keep the existing per-agent sweep availability section.

#### Scenario: Operator reads the evidence table
- **GIVEN** a device with controller evidence and evidence from two sweep agents
- **WHEN** an operator opens the device detail page
- **THEN** the page SHALL list all three evidence records
- **AND** SHALL mark the record that decided the canonical state
- **AND** SHALL mark expired or ineligible records as not deciding
