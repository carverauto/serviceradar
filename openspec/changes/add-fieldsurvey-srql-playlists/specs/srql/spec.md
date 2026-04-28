## ADDED Requirements

### Requirement: FieldSurvey summary SRQL entities
SRQL SHALL support FieldSurvey summary entities for sessions, persisted coverage rasters, and room artifacts without requiring callers to use bespoke dashboard or review queries.

#### Scenario: Query persisted Wi-Fi raster candidates by site and floor
- **GIVEN** FieldSurvey sessions have persisted metadata and `wifi_rssi` coverage rasters
- **WHEN** a client sends `in:field_survey_rasters site_id:ORD building_id:terminal-b floor_index:2 overlay_type:wifi_rssi has_floorplan:true sort:generated_at:desc limit:1`
- **THEN** SRQL SHALL return the latest matching persisted raster candidate
- **AND** each result SHALL include `raster_id`, `session_id`, `overlay_type`, `generated_at`, site/building/floor metadata, and whether cached floorplan geometry is available

#### Scenario: Query FieldSurvey sessions by tags
- **GIVEN** FieldSurvey session metadata includes tags
- **WHEN** a client sends `in:field_survey_sessions tags:[airport,ord] sort:updated_at:desc limit:20`
- **THEN** SRQL SHALL return only matching FieldSurvey sessions
- **AND** results SHALL include sample, raster, artifact, and AP summary counts when available

#### Scenario: Query FieldSurvey room artifacts
- **GIVEN** FieldSurvey room artifacts are indexed in Postgres and large blobs are stored in NATS Object Store
- **WHEN** a client sends `in:field_survey_artifacts artifact_type:floorplan_2d session_id:<session> limit:10`
- **THEN** SRQL SHALL return artifact metadata and cached render metadata
- **AND** SRQL SHALL NOT inline large artifact blobs in the result payload

### Requirement: FieldSurvey raw observation SRQL entities
SRQL SHALL support investigation-oriented entities for FieldSurvey RF observations, pose samples, fused RF/pose matches, and spectrum observations.

#### Scenario: Query per-AP RF observations
- **GIVEN** raw Sidekick RF observations exist for a survey session
- **WHEN** a client sends `in:field_survey_rf_observations session_id:<session> bssid:aa:bb:cc:dd:ee:ff time:last_1h sort:captured_at:desc limit:100`
- **THEN** SRQL SHALL return matching RF observation rows with RSSI, channel, frequency, radio, and timestamp fields

#### Scenario: Query fused RF pose matches
- **GIVEN** backend fusion has matched RF observations to pose samples
- **WHEN** a client sends `in:field_survey_rf_pose_matches session_id:<session> bssid:aa:bb:cc:dd:ee:ff time:last_1h limit:100`
- **THEN** SRQL SHALL return matching rows with RF fields, pose coordinates, tracking quality, and pose offset metadata

#### Scenario: Raw observation queries are bounded
- **GIVEN** a client queries a raw FieldSurvey observation entity without an explicit time range or limit
- **WHEN** SRQL builds the query plan
- **THEN** SRQL SHALL apply safe default time and limit bounds
- **AND** it SHALL reject unsupported broad scans that would require unbounded raw-table reads

### Requirement: FieldSurvey SRQL dashboard candidates
SRQL SHALL expose enough stable fields for dashboard playlist entries to resolve persisted FieldSurvey heatmap candidates without reading raw observation tables.

#### Scenario: Dashboard playlist query resolves to renderable heatmap
- **GIVEN** a playlist entry contains an SRQL query against `in:field_survey_rasters`
- **WHEN** the dashboard evaluates the query
- **THEN** the first result SHALL be sufficient to load the persisted raster cells and cached floorplan metadata for rendering
- **AND** dashboard rendering SHALL NOT require a second SRQL query against raw RF, pose, or spectrum entities

#### Scenario: Non-raster FieldSurvey query is rejected for heatmap playlist use
- **GIVEN** a playlist entry targets `in:field_survey_rf_observations`
- **WHEN** the settings UI validates it as a dashboard heatmap entry
- **THEN** validation SHALL fail with a message explaining that dashboard heatmaps require `in:field_survey_rasters`
- **AND** the same raw query MAY still be valid in general SRQL search or investigation surfaces
