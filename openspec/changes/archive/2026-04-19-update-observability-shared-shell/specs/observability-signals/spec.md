## MODIFIED Requirements

### Requirement: Observability panes in the UI
The web UI SHALL provide a shared observability shell for logs, traces, metrics, events, alerts, flows, BMP, BGP Routing, and Camera Relays. Navigating to any of those panes, including direct entry by URL, SHALL preserve the same top-level observability shell and active-pane treatment rather than replacing it with pane-specific top-level navigation chrome.

#### Scenario: Switching from logs to flows keeps the shared shell
- **GIVEN** a user is viewing `/observability` in the logs pane
- **WHEN** the user opens the flows pane
- **THEN** the observability shell SHALL remain visible
- **AND** the flows pane SHALL appear as the active top-level observability pane instead of suppressing the shared shell

#### Scenario: Direct entry into a route-backed observability pane keeps the shared shell
- **WHEN** a user navigates directly to a route-backed observability pane such as BMP, BGP Routing, or Camera Relays
- **THEN** the page SHALL render within the same observability shell used by the other observability panes
- **AND** the matching top-level observability pane SHALL appear active

## ADDED Requirements

### Requirement: Camera relay subsections stay under Camera Relays
Camera relay operational surfaces SHALL remain under the Camera Relays top-level observability pane. Camera Analysis Workers SHALL be presented as a subsection of Camera Relays rather than a separate top-level observability destination.

#### Scenario: Camera relay worker management loads as a subsection
- **GIVEN** a user is in the Camera Relays observability pane
- **WHEN** the user opens Camera Analysis Workers
- **THEN** the Camera Relays top-level pane SHALL remain active
- **AND** the worker management surface SHALL render as a Camera Relays subsection

#### Scenario: Direct worker link resolves under Camera Relays
- **WHEN** a user opens a direct link to the camera worker management surface
- **THEN** the UI SHALL resolve that request under the Camera Relays top-level observability pane
- **AND** the worker management subsection SHALL be selected on load
