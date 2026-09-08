## ADDED Requirements

### Requirement: Flow Interface Resolution Cache
The system SHALL maintain a bounded cache table `platform.flow_interface_cache` that maps `(sampler_address, if_index)` tuples to interface metadata (if_name, if_description, if_speed, if_boundary, device_id, device_name). A background worker SHALL refresh this cache from the interface inventory on a configurable schedule (default 1h).

#### Scenario: Cache populated from interface inventory
- **GIVEN** a device with sampler_address 10.0.0.1 and interfaces with if_index 1 (GigabitEthernet0/0) and if_index 2 (GigabitEthernet0/1) in the interface inventory
- **WHEN** the FlowInterfaceCacheRefreshWorker runs
- **THEN** the cache contains entries for (10.0.0.1, 1) and (10.0.0.1, 2) with the respective interface metadata

#### Scenario: Cache invalidated on interface change
- **GIVEN** an interface name changes in the inventory
- **WHEN** the next cache refresh runs
- **THEN** the cache entry is updated with the new interface name

### Requirement: Application IP Range Database
The system SHALL maintain a table `platform.netflow_app_ip_ranges` that maps CIDR ranges to application labels with provider attribution. The system SHALL ship a default dataset covering major internet services (Netflix, YouTube, Microsoft, AWS, Cloudflare, gaming services, etc.) and support admin-managed additions.

#### Scenario: Default IP range dataset loaded
- **GIVEN** a fresh installation
- **WHEN** the system initializes
- **THEN** the `netflow_app_ip_ranges` table contains entries for well-known service providers with their published IP ranges

#### Scenario: Admin adds custom IP range
- **WHEN** an admin creates an IP range entry mapping 203.0.113.0/24 to app_label "partner-api"
- **THEN** flows to/from that CIDR are classified as "partner-api" in SRQL queries

#### Scenario: Scheduled refresh from external source
- **GIVEN** an import source URL is configured for AWS IP ranges
- **WHEN** the AppIpRangeRefreshWorker runs on schedule
- **THEN** the table is updated with the latest AWS IP ranges from `ip-ranges.json`

### Requirement: AlienVault OTX Threat Intelligence Feed
The system SHALL support AlienVault OTX as a threat intelligence feed provider. The system SHALL fetch indicators from the OTX API, parse IPv4/IPv6 CIDR indicators, map severity levels, and store them in the existing `platform.threat_intel_indicators` table.

#### Scenario: OTX indicators imported
- **GIVEN** an AlienVault OTX API key is configured in netflow settings
- **WHEN** the ThreatIntelFeedRefreshWorker runs with the OTX provider type
- **THEN** CIDR indicators from subscribed OTX pulses are stored in the threat_intel_indicators table with source="alienvault_otx"

#### Scenario: OTX API key missing
- **GIVEN** no OTX API key is configured
- **WHEN** the threat intel refresh runs
- **THEN** the OTX provider is skipped and a warning is logged

### Requirement: Network Dictionary System
The system SHALL provide an admin-managed network dictionary system that allows defining arbitrary metadata labels for IP ranges. Each dictionary consists of a named collection of CIDR-to-attributes mappings. Dictionaries are available as SRQL group-by dimensions.

#### Scenario: Admin creates a network zone dictionary
- **WHEN** an admin creates a dictionary named "zones" with entries:
  - 10.0.0.0/8 → {"zone_name": "corporate", "cost_center": "IT"}
  - 172.16.0.0/12 → {"zone_name": "lab", "cost_center": "R&D"}
- **THEN** SRQL queries can group flows by `net:zones:zone_name` or `net:zones:cost_center`

#### Scenario: Dictionary entry CIDR containment
- **GIVEN** a dictionary entry for 10.0.0.0/8 with zone_name "corporate"
- **WHEN** a flow has src_ip 10.1.2.3
- **THEN** the flow matches the dictionary entry and zone_name resolves to "corporate"

### Requirement: Multi-Resolution Continuous Aggregates
The system SHALL create TimescaleDB continuous aggregates on the `ocsf_network_activity` hypertable at 5-minute, 1-hour, and 1-day resolutions. Each aggregate SHALL store sum of bytes, sum of packets, and flow count grouped by key dimensions. Retention policies SHALL be configurable (defaults: raw=30d, 5min=90d, 1h=1y, 1d=3y).

#### Scenario: 5-minute aggregate created
- **GIVEN** the `ocsf_network_activity` hypertable contains flow data
- **WHEN** the 5min continuous aggregate refreshes
- **THEN** it contains time-bucketed aggregates with summed bytes, packets, and flow counts per key dimension combination

#### Scenario: Retention policy enforced
- **GIVEN** raw data retention is set to 30 days
- **WHEN** data older than 30 days exists in the raw hypertable
- **THEN** the retention policy drops chunks older than 30 days while aggregated data remains accessible

### Requirement: Materialized Exporter/Interface Inventory from Flows
The system SHALL maintain a materialized view or cache table that tracks active exporters and their interfaces as observed in flow data. This provides an inventory of "what exporters are sending flows and through which interfaces" independent of SNMP discovery.

#### Scenario: New exporter appears in flow data
- **GIVEN** a flow arrives from a previously unseen sampler_address
- **WHEN** the exporter inventory refresh runs
- **THEN** the exporter appears in the active exporters list with its observed interfaces and last-seen timestamp

### Requirement: Additional Flow Schema Fields
The system SHALL store the following additional fields in the `ocsf_network_activity` hypertable when provided by flow exporters: `etype` (integer), `tcp_flags` (integer bitmask), `ip_tos` (integer), `next_hop` (inet), `flow_direction` (enum: undefined/ingress/egress), `src_vlan` (integer), `dst_vlan` (integer), `sampling_rate` (integer).

#### Scenario: Flow with TCP flags stored
- **GIVEN** a NetFlow v9 template includes TCP flags field
- **WHEN** a flow record is ingested
- **THEN** the tcp_flags column contains the bitmask value (e.g., 0x12 for SYN+ACK)

#### Scenario: Flow with VLAN tags stored
- **GIVEN** a NetFlow v9 template includes VLAN fields
- **WHEN** a flow record is ingested
- **THEN** src_vlan and dst_vlan columns contain the respective VLAN IDs
