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

### Requirement: Kismet remains optional
The Sidekick product path SHALL NOT require Kismet to be installed or running.

#### Scenario: Daemon runs without Kismet
- **GIVEN** a Sidekick host with supported radios and no Kismet installation
- **WHEN** the Sidekick daemon starts
- **THEN** it can capture, parse, and stream RF observations through its own daemon path.
