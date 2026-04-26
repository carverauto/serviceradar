## ADDED Requirements

### Requirement: Capture-first iOS workflow
The FieldSurvey iOS app SHALL provide a capture-first workflow for walking a room, mapping LiDAR geometry, collecting Sidekick RF data, and saving or streaming the survey.

#### Scenario: Operator starts a survey
- **GIVEN** the operator has configured or paired a Sidekick
- **WHEN** the operator starts a survey
- **THEN** the app starts RoomPlan/ARKit capture
- **AND** starts Sidekick RF ingestion
- **AND** shows capture status without rendering 3D RF/AP objects over the camera.

#### Scenario: Operator stops a survey
- **GIVEN** a survey is actively capturing
- **WHEN** the operator stops the survey
- **THEN** the app stops Sidekick RF ingestion
- **AND** preserves captured room, pose, and RF data for save/upload
- **AND** releases live preview state that is not needed for persistence.

#### Scenario: Operator marks a physical access point
- **GIVEN** RoomPlan/ARKit tracking has a current device pose
- **WHEN** the operator stands near a physical access point and taps "mark AP here"
- **THEN** the app stores a manual AP landmark at the current LiDAR pose with the operator-provided label
- **AND** the capture view SHALL NOT draw a halo, orb, or 3D marker over the camera feed.

### Requirement: Sidekick-only RF survey source
The FieldSurvey iOS app SHALL use Sidekick radio streams as the only Wi-Fi/RF survey measurement source.

#### Scenario: Native iPhone Wi-Fi APIs are unavailable or misleading
- **GIVEN** FieldSurvey is running on iOS
- **WHEN** RF survey capture is active
- **THEN** the app SHALL NOT poll iPhone Wi-Fi APIs for RSSI, BSSID, channel, roam, or heatmap measurements
- **AND** RF measurements SHALL be derived from Sidekick observations.

#### Scenario: Subnet inventory remains available
- **GIVEN** mDNS/subnet discovery is enabled
- **WHEN** subnet devices are discovered
- **THEN** the app MAY show them as inventory context
- **AND** SHALL NOT treat them as Wi-Fi signal measurements.

### Requirement: Local 2D survey review
The FieldSurvey iOS app SHALL provide a 2D top-down review for locally saved surveys.

#### Scenario: Review saved survey
- **GIVEN** a survey has room geometry, pose samples, and Sidekick RF observations or derived heatmap points
- **WHEN** the operator opens the local survey review
- **THEN** the app renders a top-down room/floor-plane view
- **AND** overlays signal strength as a 2D heatmap with a bounded legend
- **AND** fills sparse walk paths with a derived coverage grid generated from measured heat points
- **AND** exposes a separate confidence overlay so extrapolated regions are distinguishable from well-supported measured regions
- **AND** avoids SceneKit/AR 3D RF billboards in the review.

#### Scenario: Room geometry is incomplete
- **GIVEN** a survey has RF and pose samples but incomplete RoomPlan geometry
- **WHEN** the operator opens the local survey review
- **THEN** the app renders a walked-path heatmap fallback
- **AND** indicates that room geometry is incomplete.

### Requirement: Spectrum analyzer review
The FieldSurvey iOS app SHALL expose HackRF spectrum analyzer data separately from Wi-Fi RSSI coverage.

#### Scenario: Operator previews spectrum while scanning
- **GIVEN** HackRF spectrum capture is enabled on the Sidekick
- **WHEN** the operator starts local Sidekick preview
- **THEN** the capture UI shows current RF energy, peak frequency, peak power, sweep rate, and per-channel interference bars
- **AND** the app saves local spectrum summaries in the active survey session.

#### Scenario: Operator reviews signal and interference
- **GIVEN** a saved survey has Wi-Fi heatmap points and local spectrum summaries
- **WHEN** the operator opens Live Signal Map or session review
- **THEN** the app can show Wi-Fi RSSI coverage as one overlay
- **AND** can show RF energy/interference as a separate overlay derived from spectrum summaries and survey timestamps.

### Requirement: RF-only update workflow
The FieldSurvey iOS app SHALL support updating Wi-Fi survey data without forcing a full RoomPlan remap when a usable room baseline already exists.

#### Scenario: Operator updates RF over an existing room
- **GIVEN** a saved survey has room geometry or a usable 2D review baseline
- **WHEN** the operator starts RF Update mode
- **THEN** the app captures Sidekick RF observations and phone pose samples
- **AND** avoids RoomPlan mesh reconstruction unless the operator chooses to remap geometry
- **AND** saves the update as a recoverable local survey revision.

#### Scenario: New RF path needs alignment
- **GIVEN** RF Update mode starts with a fresh ARKit coordinate origin
- **WHEN** the operator aligns the update to the saved room baseline
- **THEN** the app stores the transform used to compare new RF heatmap points with the saved room coordinate space.

### Requirement: Backend survey review
ServiceRadar SHALL provide a saved survey review using backend RF/pose fusion data.

#### Scenario: Review uploaded survey
- **GIVEN** raw RF observations and pose samples have been uploaded for a survey session
- **WHEN** an operator opens the survey in ServiceRadar
- **THEN** ServiceRadar renders a 2D signal heatmap over the survey floor-plane or walked path
- **AND** uses backend fused RF/pose data rather than iOS preview-only state.
