## ADDED Requirements

### Requirement: Mapbox Token Storage
The system SHALL store the Mapbox access token encrypted at rest in the CNPG database.

#### Scenario: Admin saves token
- **GIVEN** an authenticated admin with permission `settings.maps.manage`
- **WHEN** they save a Mapbox access token in the settings UI
- **THEN** the token SHALL be persisted encrypted at rest
- **AND** the UI SHALL indicate that a token is saved without revealing the token

### Requirement: Reusable Map Component
The system SHALL provide a reusable LiveView map component that can render point markers from provided coordinates.

#### Scenario: Render source and destination markers
- **GIVEN** a flow with GeoIP-enriched `src` and `dst` coordinates
- **WHEN** the user opens the flow details panel
- **THEN** the map SHALL render markers for available coordinates

### Requirement: Theme-Aware Styling
The system SHALL render Mapbox maps using a style appropriate for the current UI theme.

#### Scenario: Theme changes
- **GIVEN** a user viewing a map
- **WHEN** the UI theme changes between light and dark
- **THEN** the map style SHALL switch to match
