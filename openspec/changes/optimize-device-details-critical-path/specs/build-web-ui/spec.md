## MODIFIED Requirements
### Requirement: Device details initial load remains focused on active content
The device details UI SHALL keep the initial load path focused on the currently active surface and SHALL avoid blocking the default details render on edit-only or inactive-tab data.

#### Scenario: Initial device details load skips edit-only data
- **GIVEN** an operator opens a device details page on the default `Details` tab
- **WHEN** the LiveView loads the initial page state
- **THEN** it SHALL NOT block on loading SNMP credential edit data
- **AND** it SHALL continue to render the existing details content

#### Scenario: Profiles data loads when the profiles surface is needed
- **GIVEN** a device details page with sysmon content available
- **WHEN** the operator opens the `Profiles` tab
- **THEN** the UI SHALL load the profile assignment and available profile list for that surface
- **AND** the default details load SHALL not require those reads

#### Scenario: Discovery job lookup stays scoped
- **GIVEN** a device details page needs discovery-job diagnostics for interface visibility or empty-state context
- **WHEN** the UI resolves discovery jobs that may target the device
- **THEN** it SHALL limit the lookup to jobs relevant to the device partition rather than scanning every mapper job in the deployment

#### Scenario: LiveView falls back quickly when websocket transport is unavailable
- **GIVEN** a device details page is served through an environment where the LiveView websocket upgrade does not succeed
- **WHEN** the browser falls back to longpoll transport
- **THEN** the UI SHALL avoid adding a multi-second fallback wait before the page mounts
