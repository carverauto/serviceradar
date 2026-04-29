## MODIFIED Requirements

### Requirement: FieldSurvey summary SRQL entities
SRQL SHALL support FieldSurvey summary entities for sessions, persisted coverage rasters, and room artifacts without requiring callers to use bespoke dashboard or review queries. These entities SHALL expose stable `session_id` fields so dashboard playlists and review selection controls can resolve a survey session from a candidate row.

#### Scenario: Query persisted Wi-Fi raster candidates by site and floor
- **GIVEN** FieldSurvey sessions have persisted metadata and `wifi_rssi` coverage rasters
- **WHEN** a client sends `in:field_survey_rasters site_id:ORD building_id:terminal-b floor_index:2 overlay_type:wifi_rssi has_floorplan:true sort:generated_at:desc limit:1`
- **THEN** SRQL SHALL return the latest matching persisted raster candidate
- **AND** each result SHALL include `raster_id`, `session_id`, `overlay_type`, `generated_at`, site/building/floor metadata, and whether cached floorplan geometry is available

#### Scenario: Query FieldSurvey sessions by tags
- **GIVEN** FieldSurvey session metadata includes tags
- **WHEN** a client sends `in:field_survey_sessions tags:[airport,ord] sort:updated_at:desc limit:20`
- **THEN** SRQL SHALL return only matching FieldSurvey sessions
- **AND** results SHALL include `session_id`, sample, raster, artifact, and AP summary counts when available

#### Scenario: Query FieldSurvey room artifacts
- **GIVEN** FieldSurvey room artifacts are indexed in Postgres and large blobs are stored in NATS Object Store
- **WHEN** a client sends `in:field_survey_artifacts artifact_type:floorplan_2d session_id:<session> limit:10`
- **THEN** SRQL SHALL return artifact metadata and cached render metadata
- **AND** SRQL SHALL NOT inline large artifact blobs in the result payload
