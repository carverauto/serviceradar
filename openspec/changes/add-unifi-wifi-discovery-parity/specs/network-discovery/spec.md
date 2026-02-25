## ADDED Requirements

### Requirement: API-driven controller discovery mode
The system SHALL support an API discovery mode that fetches device, client, and network data directly from network controller platforms (UniFi, Aruba, Meraki) without requiring SNMP access to individual devices.

#### Scenario: UniFi API discovery returns devices and clients
- **GIVEN** a mapper discovery job configured with `discovery_mode: "api"` and a UniFi controller URL and credentials
- **WHEN** the discovery job executes
- **THEN** the mapper SHALL authenticate with the UniFi controller
- **AND** fetch all infrastructure devices (APs, switches, gateways) with model, firmware, IP, MAC, uptime, and state
- **AND** fetch all connected wireless and wired clients with MAC, IP, SSID, signal strength, and connection metadata
- **AND** stream results through the existing mapper result pipeline

#### Scenario: Hybrid discovery mode combines API and SNMP
- **GIVEN** a mapper discovery job configured with `discovery_mode: "hybrid"`
- **WHEN** the discovery job executes
- **THEN** the mapper SHALL run API discovery first for rich metadata
- **AND** then run SNMP discovery for additional interface counters and bridge table data
- **AND** merge results using MAC address as the primary correlation key

#### Scenario: Controller authentication handles both UniFi OS and standalone
- **GIVEN** a UniFi controller that may be either UniFi OS (UDM/UCG) or standalone Network Server
- **WHEN** the mapper connects to the controller
- **THEN** it SHALL attempt UniFi OS endpoints (`/proxy/network/api/`) first
- **AND** fall back to standalone endpoints (`/api/`) if the OS path returns 404
- **AND** handle cookie-based authentication with automatic re-auth on 401/403

### Requirement: Wireless client discovery
The system SHALL discover and track wireless clients as distinct entities, capturing their connection state, signal quality, and association metadata from controller APIs.

#### Scenario: Wireless client observation ingestion
- **GIVEN** a WiFi discovery result containing wireless client data
- **WHEN** the results are ingested by core-elx
- **THEN** a `WirelessClientObservation` record SHALL be persisted with timestamp, client MAC, AP MAC, SSID, signal strength (dBm), noise (dBm), TX/RX rates, WiFi generation, channel, band, and VLAN ID
- **AND** the observation SHALL be stored in a TimescaleDB hypertable for time-series analysis

#### Scenario: Wireless client promoted to device inventory
- **GIVEN** a wireless client discovered via controller API with fingerprint data
- **WHEN** the client is ingested
- **THEN** a DIRE device identity SHALL be created or updated for the client
- **AND** the device `type_id` SHALL be set based on available fingerprint data (Mobile=5, Laptop=3, IoT=7, etc.)
- **AND** `last_seen_at`, `last_ap_mac`, `last_ssid`, and `last_vlan_id` SHALL be updated

#### Scenario: Offline client tracking
- **GIVEN** a wireless client that was previously observed but is no longer connected
- **WHEN** a discovery poll completes without the client in the active client list
- **THEN** the device record SHALL retain its last-known state
- **AND** `last_seen_at` SHALL reflect the timestamp of the last observation
- **AND** the client SHALL remain queryable in device inventory

### Requirement: Controller-mediated topology enrichment
The system SHALL use controller API data to enrich network topology with device hierarchy information (which AP connects to which switch on which port).

#### Scenario: Uplink hierarchy from UniFi API
- **GIVEN** UniFi API discovery returns device data with uplink objects
- **WHEN** the topology is built
- **THEN** the system SHALL extract switch→AP and switch→switch connections from uplink data
- **AND** create topology links with the controller as the evidence source
- **AND** these links SHALL complement (not replace) LLDP/CDP-discovered links

### Requirement: Multi-source device fingerprinting
The system SHALL combine multiple fingerprint sources to achieve the best possible device classification accuracy.

#### Scenario: Fingerprint merge from SNMP and controller API
- **GIVEN** a device discovered via both SNMP (providing sysDescr) and controller API (providing UniFi fingerprint category)
- **WHEN** the device identity is reconciled by DIRE
- **THEN** the system SHALL merge fingerprint signals: controller fingerprint takes precedence for device type, SNMP sysDescr fills OS/firmware details, MAC OUI provides vendor name
- **AND** the resulting OCSF device SHALL have the most accurate classification possible

#### Scenario: MAC OUI vendor lookup
- **GIVEN** a device with a known MAC address
- **WHEN** the device is processed by the fingerprint enrichment pipeline
- **THEN** the system SHALL look up the MAC OUI against the IEEE registration database
- **AND** populate `vendor_name` if not already set by a higher-confidence source

## MODIFIED Requirements

### Requirement: Ubiquiti API discovery settings
The system SHALL support Ubiquiti discovery settings as part of mapper discovery jobs, including full controller authentication, site selection, and WiFi data collection.

#### Scenario: Configure Ubiquiti controller
- **GIVEN** an admin configures a discovery job in API mode
- **WHEN** they add a Ubiquiti controller with URL, site, and credentials
- **THEN** the settings SHALL be persisted with encrypted credentials
- **AND** the mapper job config SHALL include the Ubiquiti controller definition

#### Scenario: Configure Ubiquiti controller with WiFi data collection
- **GIVEN** an admin configures a discovery job in API mode with WiFi analytics enabled
- **WHEN** the discovery job executes
- **THEN** the mapper SHALL collect AP radio state (channel, TX power, utilization, noise floor) alongside device discovery
- **AND** collect wireless client data (signal, rate, WiFi generation) alongside client discovery
- **AND** results SHALL include a `WiFiDiscoveryResult` payload

#### Scenario: Controller connection test
- **GIVEN** an admin enters UniFi controller connection settings
- **WHEN** they click "Test Connection"
- **THEN** the system SHALL attempt authentication and report success or failure
- **AND** on success, display the controller version and available sites
