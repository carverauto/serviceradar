## ADDED Requirements
### Requirement: Service Components Remain Devices
Self-reported ServiceRadar components (pollers, agents, checkers, host registrations) SHALL be treated as authoritative device updates and SHALL bypass network sighting demotion so they remain in inventory with stable ServiceRadar IDs.

#### Scenario: Poller status ingested under identity reconciliation
- **WHEN** a poller or agent reports status with its service identifiers while identity reconciliation is enabled
- **THEN** the registry records or refreshes the corresponding service device directly (skipping sighting ingest) so it stays visible as a device instead of reappearing as a sighting

### Requirement: Service Components Report Normalized Host Identity
ServiceRadar components SHALL send normalized source IPs and hostnames for their own hosts, and the system SHALL resolve missing values from runtime or service-registry metadata so service devices carry IP and hostname data in the default partition.

#### Scenario: Source IP is missing or a placeholder
- **WHEN** a poller status arrives with an empty or placeholder source_ip
- **THEN** the system resolves a concrete IP and hostname (for example the pod or node address), registers the host/device in the poller partition (default), and the resulting device entry shows the resolved IP/hostname rather than an empty or `Serviceradar` sighting
