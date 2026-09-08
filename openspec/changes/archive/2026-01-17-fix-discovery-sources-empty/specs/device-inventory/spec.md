## ADDED Requirements

### Requirement: Discovery Source Propagation

The system SHALL populate the `discovery_sources` field in `ocsf_devices` with the integration source type(s) that discovered each device.

#### Scenario: Device discovered by Armis integration
- **GIVEN** a device update received from the Armis sync integration with `source: "armis"`
- **WHEN** the device is processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["armis"]`

#### Scenario: Device discovered by NetBox integration
- **GIVEN** a device update received from the NetBox sync integration with `source: "netbox"`
- **WHEN** the device is processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["netbox"]`

#### Scenario: Device discovered by multiple sources
- **GIVEN** a device first discovered by Armis with `source: "armis"`
- **AND** the same device is later discovered by NetBox with `source: "netbox"`
- **WHEN** both updates are processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["armis", "netbox"]`
- **AND** the array SHALL contain no duplicate entries

#### Scenario: Device update with missing source field
- **GIVEN** a device update received without a `source` field
- **WHEN** the device is processed by the SyncIngestor
- **THEN** the `ocsf_devices` record SHALL have `discovery_sources` containing `["unknown"]`
