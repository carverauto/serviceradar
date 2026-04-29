## ADDED Requirements

### Requirement: FieldSurvey review survey selector
The web UI SHALL provide authenticated FieldSurvey review controls for selecting recent survey sessions without relying only on the left-side session list.

#### Scenario: Select recent survey from dropdown
- **GIVEN** an authenticated user is viewing `/spatial/field-surveys`
- **AND** multiple FieldSurvey sessions are visible
- **WHEN** the user selects a session from the recent survey dropdown
- **THEN** the review page SHALL load that session
- **AND** preserve the active floor filter when the selected session is visible under that filter

### Requirement: FieldSurvey review favorites and defaults
The web UI SHALL allow authenticated users to mark FieldSurvey sessions as favorites and choose one default FieldSurvey review/spatial session.

#### Scenario: Favorite a survey
- **GIVEN** an authenticated user is viewing a FieldSurvey session
- **WHEN** they toggle favorite
- **THEN** the session SHALL be marked favorite for that user
- **AND** favorite sessions SHALL be visually indicated in recent survey controls

#### Scenario: Set default survey
- **GIVEN** an authenticated user is viewing a FieldSurvey session
- **WHEN** they set it as the default view
- **THEN** subsequent visits to `/spatial/field-surveys` without an explicit session SHALL open that session when it is still visible
- **AND** previous default sessions for that user SHALL no longer be default

### Requirement: FieldSurvey review avoids incomplete default sessions
The FieldSurvey review page SHALL prefer complete, renderable sessions over incomplete newest uploads when no explicit session is requested.

#### Scenario: Incomplete newest upload is skipped
- **GIVEN** the newest FieldSurvey session has no RF rows or no floorplan/raster-backed review data
- **AND** an older visible session has RF observations and renderable Wi-Fi heat data
- **WHEN** the user opens `/spatial/field-surveys` without a session id
- **THEN** the review page SHALL select the complete renderable session
- **AND** the incomplete session SHALL remain available in the recent survey list

### Requirement: FieldSurvey review SRQL selector
The FieldSurvey review page SHALL provide an SRQL selection control that previews FieldSurvey raster or session queries and can load the resolved survey session.

#### Scenario: Preview and select SRQL candidate
- **GIVEN** an authenticated user enters an SRQL query targeting FieldSurvey sessions or rasters
- **WHEN** the query resolves to a FieldSurvey candidate with a `session_id`
- **THEN** the UI SHALL show the resolved session candidate
- **AND** offer a control to load that survey review

#### Scenario: Invalid SRQL selector query
- **GIVEN** an authenticated user enters an invalid or non-FieldSurvey SRQL query
- **WHEN** they preview the query
- **THEN** the UI SHALL show a useful validation error
- **AND** SHALL NOT navigate away from the current review

### Requirement: Spatial view respects FieldSurvey review defaults
The `/spatial` survey view SHALL use the same FieldSurvey default/favorite-aware session selection when choosing which room/floorplan scene to display by default.

#### Scenario: Spatial view opens default survey scene
- **GIVEN** an authenticated user has set a FieldSurvey default session
- **WHEN** they open `/spatial`
- **THEN** the spatial scene SHALL prefer artifacts and floorplan geometry for that default session when available
- **AND** fall back to the best complete visible session only when the default has no scene data
