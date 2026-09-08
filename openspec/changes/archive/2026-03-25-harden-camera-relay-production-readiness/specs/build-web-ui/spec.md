## ADDED Requirements
### Requirement: Camera viewers negotiate playback transport
The UI SHALL select a playback transport for each camera relay session based on browser capabilities and the transports advertised by the relay session.

#### Scenario: Browser supports the preferred direct playback path
- **GIVEN** a relay session advertises a direct low-latency playback transport
- **AND** the browser reports support for that transport
- **WHEN** the viewer initializes
- **THEN** the UI SHALL use the preferred direct playback transport

#### Scenario: Browser falls back to a portable playback path
- **GIVEN** a relay session advertises both a preferred direct playback transport and a portable fallback transport
- **AND** the browser does not support the preferred direct transport
- **WHEN** the viewer initializes
- **THEN** the UI SHALL select the fallback transport
- **AND** the viewer SHALL remain bound to the same relay session state

### Requirement: Unsupported browser state is explicit
The camera viewer UI SHALL show an explicit unsupported-browser state when no advertised playback transport is usable in the current browser.

#### Scenario: Browser supports no advertised transport
- **GIVEN** a relay session is active
- **AND** the browser does not support any transport advertised for that session
- **WHEN** the viewer initializes
- **THEN** the UI SHALL show that playback is unsupported in the current browser
- **AND** SHALL continue to display relay session status and termination details
- **AND** SHALL NOT render an ambiguous blank viewer surface
