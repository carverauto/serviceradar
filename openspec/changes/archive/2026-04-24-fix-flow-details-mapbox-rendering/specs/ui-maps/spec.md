## MODIFIED Requirements

### Requirement: The system SHALL provide a reusable LiveView map component that can render point markers from provided coordinates.

The system SHALL provide a reusable LiveView map component that can render point markers from provided coordinates. The component SHALL handle error states gracefully — when the Mapbox access token is missing, invalid, or the style URL fails to load, the component SHALL display a user-visible fallback message instead of rendering a blank container.

#### Scenario: Flow details map renders basemap with valid configuration
- **GIVEN** a valid Mapbox access token and style URLs are configured
- **WHEN** the user opens the flow details panel for a flow with GeoIP coordinates
- **THEN** the map SHALL render the basemap tiles and display markers for available coordinates

#### Scenario: Map displays fallback when token is missing
- **GIVEN** the Mapbox access token is not configured or maps are disabled
- **WHEN** the user opens the flow details panel
- **THEN** the map container SHALL display a "Map not configured" message instead of a blank area

#### Scenario: Map displays error when style fails to load
- **GIVEN** a Mapbox access token is configured but the style URL is unreachable or the token is invalid
- **WHEN** the map attempts to initialise
- **THEN** the component SHALL catch the error, log a warning to the browser console, and display a fallback message to the user

#### Scenario: Map resizes correctly when container becomes visible
- **GIVEN** the map container is mounted by LiveView
- **WHEN** the container transitions from hidden to visible (e.g. tab switch, panel expand)
- **THEN** the map SHALL call `resize()` so tiles fill the container without blank regions
