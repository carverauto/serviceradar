## ADDED Requirements

### Requirement: Sidekick RF collection
The system SHALL provide a Raspberry Pi Sidekick daemon that collects Wi-Fi survey observations from Linux monitor-mode USB radios without depending on iOS Wi-Fi scan APIs.

#### Scenario: Monitor-mode observations are captured
- **GIVEN** a configured Sidekick with at least one supported USB Wi-Fi adapter
- **WHEN** capture is started
- **THEN** the daemon configures the adapter for monitor-mode capture
- **AND** captures frames through a Linux packet capture ring rather than iOS Wi-Fi scan APIs
- **AND** emits observations for detected beacon or probe-response frames with BSSID, SSID when present, RSSI, frequency, channel, radio ID, daemon wall-clock nanoseconds, and monotonic timestamp metadata.

#### Scenario: Unsupported adapter is reported
- **GIVEN** a configured Sidekick with an adapter that cannot enter monitor mode
- **WHEN** capture is started
- **THEN** the daemon reports the adapter as unavailable with a diagnostic reason
- **AND** continues operating any remaining supported adapters.

### Requirement: Sidekick local control API
The Sidekick daemon SHALL expose a paired local API for status, configuration, and observation streaming.

#### Scenario: iOS pairs with a Sidekick
- **GIVEN** an unpaired Sidekick daemon
- **WHEN** FieldSurvey presents a valid setup token to the pairing endpoint
- **THEN** the daemon stores the paired client identity
- **AND** subsequent configuration and stream requests require the paired credential.

#### Scenario: FieldSurvey configures Pi connectivity
- **GIVEN** FieldSurvey is paired with the Sidekick
- **WHEN** the user submits Pi Wi-Fi/uplink settings, country code, or channel-plan settings
- **THEN** the daemon validates and persists the settings
- **AND** reports whether a daemon or network restart is required.

### Requirement: iOS Sidekick ingestion
The FieldSurvey iOS app SHALL ingest per-radio Sidekick RF observation batches and correlate them with ARKit/LiDAR pose for live visualization and backend persistence.

#### Scenario: Observation batch is received
- **GIVEN** FieldSurvey is connected to a paired Sidekick and an AR session has a current pose
- **WHEN** the app receives a binary RF observation batch from a Sidekick radio WebSocket
- **THEN** the app preserves the Arrow IPC payload for upload/offline storage
- **AND** may decode a preview subset for live heatmaps using current or time-aligned ARKit pose.

#### Scenario: Sidekick disconnects during a survey
- **GIVEN** FieldSurvey is actively surveying with a Sidekick stream
- **WHEN** the Sidekick connection drops
- **THEN** the app shows the disconnected state
- **AND** preserves already captured samples
- **AND** continues LiDAR mapping and any enabled mDNS/subnet inventory collection without treating iPhone Wi-Fi APIs as RF survey sources.

#### Scenario: iPhone Wi-Fi radio is not used for RF survey measurements
- **GIVEN** FieldSurvey is running on iOS
- **WHEN** a survey is started
- **THEN** RF survey observations SHALL come from Sidekick radio streams only
- **AND** the app SHALL NOT poll `NEHotspotNetwork` or `NEHotspotHelper` for RSSI, BSSID, channel, roam, or heatmap measurements
- **AND** mDNS/subnet records MAY be retained as non-RF inventory context.

### Requirement: Survey source metadata
The survey data contract SHALL preserve raw Sidekick RF observations and iPhone pose samples with enough metadata for timestamp-keyed backend fusion.

#### Scenario: Raw Sidekick observations are uploaded
- **GIVEN** FieldSurvey streams a batch containing Sidekick-originated RF observations
- **WHEN** ServiceRadar decodes and stores the batch
- **THEN** stored records identify the Sidekick, radio ID, and interface name
- **AND** preserve BSSID, SSID when present, channel, noise floor when available, frame type, daemon wall-clock nanoseconds, and monotonic timestamp metadata.

#### Scenario: Pose samples are uploaded
- **GIVEN** FieldSurvey has ARKit/LiDAR pose samples for the same survey session
- **WHEN** ServiceRadar receives pose batches
- **THEN** stored pose records preserve session ID, scanner device ID, wall-clock timestamp, monotonic timestamp, transform/position, and tracking quality
- **AND** backend fusion can associate RF observations to poses by session and timestamp.

#### Scenario: Backend storage remains spatial/vector-queryable
- **GIVEN** ServiceRadar decodes Arrow IPC RF, pose, and spectrum batches
- **WHEN** records are persisted for a survey session
- **THEN** RF and spectrum rows SHALL include pgvector feature columns for similarity/search/indexing
- **AND** pose rows SHALL include PostGIS local 3D position geometry and GPS geography when GPS coordinates are present
- **AND** fused RF/pose review queries SHALL expose those vector and spatial fields rather than requiring clients to reparse Arrow IPC blobs.

#### Scenario: Raw Arrow IPC frames are archived for replay
- **GIVEN** FieldSurvey uploads RF, pose, or spectrum Arrow IPC frames
- **WHEN** the backend receives each binary frame
- **THEN** the backend SHALL archive the original Arrow IPC payload with session ID, stream type, frame index, byte size, row count when decode succeeds, decode status, and payload SHA-256
- **AND** failed decodes SHALL keep the WebSocket stream open while preserving the failed frame and error summary for debugging
- **AND** review and analytics queries SHALL use decoded typed tables instead of reparsing archived payloads on the hot path.

### Requirement: Kismet remains optional
The Sidekick product path SHALL NOT require Kismet to be installed or running.

#### Scenario: Daemon runs without Kismet
- **GIVEN** a Sidekick host with supported radios and no Kismet installation
- **WHEN** the Sidekick daemon starts
- **THEN** it can capture, parse, and stream RF observations through its own daemon path.

### Requirement: Adaptive RF channel scheduling
The Sidekick daemon SHALL own RF channel scheduling and SHALL use both HackRF spectrum energy and decoded Wi-Fi observations to prioritize monitor-radio dwell time.

#### Scenario: Spectrum energy prioritizes channel dwell
- **GIVEN** FieldSurvey requests adaptive RF scanning from a paired Sidekick
- **AND** the HackRF spectrum stream reports elevated energy on a supported Wi-Fi channel
- **WHEN** the monitor radio is hopping channels
- **THEN** the Sidekick weights that channel higher in the local dwell plan
- **AND** still performs periodic passes over lower-priority supported channels.

#### Scenario: Wi-Fi observations confirm AP identity
- **GIVEN** the adaptive scheduler has prioritized a channel from spectrum energy
- **WHEN** the Wi-Fi monitor radio decodes beacons or probe responses on that channel
- **THEN** the Sidekick records BSSID, SSID when present, channel/frequency, and RSSI observations
- **AND** exposes enough status to show observed BSSID counts and stale/unseen channel state.

### Requirement: Survey review rasters and floorplan overlays
ServiceRadar SHALL persist backend-derived coverage artifacts for post-survey review instead of relying only on transient client-side drawing.

#### Scenario: Wi-Fi and RF rasters are persisted
- **GIVEN** a survey has fused RF/pose rows and optional floorplan geometry
- **WHEN** the survey review is generated
- **THEN** ServiceRadar persists a `wifi_rssi` raster derived from per-BSSID RSSI coverage
- **AND** persists an `rf_interference` raster derived from spectrum observations
- **AND** both rasters are masked to valid floorplan geometry when available.

#### Scenario: Malformed floorplan geometry does not crash review
- **GIVEN** a survey floorplan artifact contains horizontal, vertical, duplicate, or partial segments
- **WHEN** ServiceRadar generates review rasters
- **THEN** invalid polygon points are ignored
- **AND** horizontal or vertical edges do not raise arithmetic exceptions
- **AND** review falls back to unmasked bounds when the polygon cannot form a valid area.

#### Scenario: Dashboard shows persisted coverage over floorplan
- **GIVEN** ServiceRadar has a persisted `wifi_rssi` raster and a matching 2D floorplan artifact for a FieldSurvey session
- **WHEN** the operator opens the main dashboard
- **THEN** the FieldSurvey card renders the latest floorplan geometry with the Wi-Fi RSSI raster overlaid
- **AND** it uses the persisted raster and artifact data rather than synthetic placeholder heatmap shapes
- **AND** it renders coverage as a continuous heat surface derived from persisted raster cells rather than visible per-cell marker dots.

#### Scenario: Dashboard normalizes overview projection orientation
- **GIVEN** ServiceRadar has persisted FieldSurvey raster cells and 2D floorplan geometry with an arbitrary ARKit world heading
- **WHEN** the dashboard renders the FieldSurvey overview card
- **THEN** it applies one shared projection transform to the floorplan geometry and Wi-Fi raster cells
- **AND** it prefers floorplan-backed persisted rasters over raster-only rows
- **AND** it rotates the overview to a card-friendly landscape floorplan orientation rather than showing the raw capture heading
- **AND** it preserves the transformed floorplan aspect ratio so the heat surface is not stretched into an unrelated shape.

### Requirement: AP placement support
FieldSurvey SHALL support both manual and inferred AP placement without relying on HackRF as a BSSID identity source.

#### Scenario: Manual AP mark anchors placement
- **GIVEN** the operator is physically near an access point during capture
- **WHEN** the operator adds an AP mark
- **THEN** FieldSurvey records the mark as an authoritative AP landmark at the current pose
- **AND** keeps it available in live and review maps.

#### Scenario: Inferred AP candidates are confidence-scored
- **GIVEN** a survey contains per-BSSID RSSI observations across a path
- **WHEN** the app or backend estimates AP location candidates
- **THEN** the estimate uses per-BSSID RSSI gradients, strongest-observation clusters, and path diversity
- **AND** HackRF channel energy may affect confidence/noise explanation but SHALL NOT identify BSSID by itself.

### Requirement: Survey organization and floor grouping
ServiceRadar SHALL organize FieldSurvey captures by operator-defined site, building/area, floor, and metadata tags so dashboards can show the right survey context for large multi-site deployments.

#### Scenario: Survey is attributed to a site and floor
- **GIVEN** an operator starts or resumes a FieldSurvey capture
- **WHEN** they assign site/building/floor metadata such as `ORD`, `Terminal B`, and `Floor 2`
- **THEN** ServiceRadar persists that attribution with the survey session, RF rows, pose rows, rasters, and room artifacts
- **AND** upload retries preserve the same attribution instead of creating orphaned global sessions.

#### Scenario: Dashboard selects FieldSurvey groups by configured query
- **GIVEN** an administrator configures a dashboard FieldSurvey group using SRQL-backed filters or saved metadata tags
- **WHEN** the dashboard renders FieldSurvey coverage
- **THEN** it selects the latest matching persisted floorplan/raster set for that configured group
- **AND** it does not globally mix unrelated sites, buildings, floors, or sessions.

#### Scenario: Multi-floor review is separated
- **GIVEN** a site has FieldSurvey sessions for more than one floor
- **WHEN** an operator opens FieldSurvey Review
- **THEN** the UI exposes floor/group selection
- **AND** Wi-Fi RSSI, RF interference, AP candidates, and RoomPlan floor geometry are shown only for the selected floor/group.
