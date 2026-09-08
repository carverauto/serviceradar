## ADDED Requirements

### Requirement: Sample Northbound Action Plugin

The system SHALL provide a safe sample Wasm plugin that can act as a simulated northbound integration for provider-neutral device and interface action testing.

The sample plugin SHALL NOT require live third-party credentials or network access for its default mode. It MAY optionally demonstrate the HTTP host-function wrapper against a configured mock endpoint, but tests SHALL remain deterministic without external services.

#### Scenario: Sample plugin exposes device and interface actions

- **GIVEN** the sample northbound plugin package is imported and approved
- **WHEN** the northbound action catalog refreshes plugin descriptors
- **THEN** the catalog includes a device-scoped sample action
- **AND** includes an interface-scoped sample action

#### Scenario: Sample device action returns simulated API data

- **GIVEN** a user launches the sample device action for a selected device with a primary IP
- **WHEN** the assigned agent executes the Wasm action
- **THEN** the result includes a per-target success record
- **AND** includes simulated external API facts tied to the selected device

#### Scenario: Sample interface action returns simulated API data

- **GIVEN** a user launches the sample interface action for a selected interface
- **WHEN** the assigned agent executes the Wasm action
- **THEN** the result includes a per-target success record
- **AND** includes simulated external API facts tied to both the selected device and interface
