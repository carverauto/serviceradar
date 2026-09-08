## MODIFIED Requirements

### Requirement: OCSF Network Interfaces Array
The system SHALL treat `ocsf_devices.network_interfaces` as a non-canonical cache and SHALL NOT depend on it for interface presentation.

#### Scenario: Interface presentation uses SRQL
- **GIVEN** a device with interface observations stored in the time-series table
- **WHEN** the device details UI requests interfaces
- **THEN** the UI SHALL query SRQL `in:interfaces` and NOT rely on `ocsf_devices.network_interfaces`

## ADDED Requirements

### Requirement: Interface Observations Time-Series
The system SHALL store interface observations in a single time-series table covering routers and servers.

Interface observations SHALL include at minimum:
- `timestamp` (TIMESTAMPTZ) - observation time
- `device_id` (TEXT) - canonical device UID
- `device_ip` (TEXT) - device IP at observation time
- `if_index` (INTEGER, nullable) - interface index (SNMP ifIndex)
- `if_name` (TEXT, nullable)
- `if_descr` (TEXT, nullable)
- `if_alias` (TEXT, nullable)
- `if_type` (INTEGER, nullable) - numeric interface type identifier
- `if_type_name` (TEXT, nullable) - human-readable type (e.g., ethernetCsmacd)
- `interface_kind` (TEXT, nullable) - classification (physical, virtual, loopback, tunnel, bridge, etc.)
- `mac` (TEXT, nullable)
- `ip_addresses` (TEXT[] or JSON array)
- `speed_bps` (BIGINT, nullable)
- `mtu` (INTEGER, nullable)
- `admin_status` (INTEGER, nullable)
- `oper_status` (INTEGER, nullable)
- `duplex` (TEXT, nullable)
- `metadata` (JSONB, optional)

#### Scenario: Router interface observation
- **GIVEN** a router discovered by SNMP with `ifType`, speed, and MAC
- **WHEN** mapper publishes interface results
- **THEN** the time-series table SHALL store the observation with type fields, MAC, IPs, and speed

#### Scenario: Server interface observation
- **GIVEN** a Linux server with `eth0` and loopback interfaces
- **WHEN** mapper/sysmon publishes interface results
- **THEN** the time-series table SHALL store both interfaces with `interface_kind` set appropriately
