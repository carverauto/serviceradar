## ADDED Requirements

### Requirement: Interfaces entity reads time-series observations
SRQL SHALL query interface observations from the interface time-series table for `in:interfaces`.

#### Scenario: Query interfaces by device
- **GIVEN** a device UID with interface observations in the last 3 days
- **WHEN** a client sends `in:interfaces device_id:"sr:..." time:last_3d`
- **THEN** SRQL SHALL return interface rows for that device

### Requirement: Interface filters include rich fields
SRQL SHALL support filters for interface fields including:
- `if_type`, `if_type_name`, `interface_kind`
- `if_name`, `if_descr`, `if_alias`
- `speed_bps`, `mtu`, `admin_status`, `oper_status`, `duplex`
- `mac`, `ip_addresses`

#### Scenario: Filter by interface type
- **GIVEN** interface observations with `if_type_name = ethernetCsmacd`
- **WHEN** a client queries `in:interfaces if_type_name:ethernetCsmacd`
- **THEN** SRQL returns only matching interfaces

### Requirement: Latest snapshot per interface
SRQL SHALL provide a “latest snapshot per interface” result shape for UI queries, returning the most recent row per device/interface key.

#### Scenario: UI requests latest interface snapshot
- **GIVEN** multiple observations per interface in the last 3 days
- **WHEN** the UI queries `in:interfaces device_id:"sr:..."`
- **THEN** SRQL returns the latest observation per interface
