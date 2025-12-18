# OCSF Device Inventory Schema

ServiceRadar uses the Open Cybersecurity Schema Framework (OCSF) v1.7.0 Device object as the foundation for its device inventory. This provides standardized, interoperable device data that can be exported to SIEM and security analytics platforms.

## Overview

The `ocsf_devices` table stores discovered devices using OCSF-aligned field names and structures. This enables:

- **Standardized Device Taxonomy**: OCSF-defined device types (Server, Router, Switch, Firewall, IoT, etc.)
- **Interoperability**: Export device data in a format understood by SIEM and security tools
- **Rich Metadata**: Nested JSONB objects for OS, hardware, network interfaces
- **Risk & Compliance**: Built-in fields for risk level, compliance status, and management state

## Schema Reference

### Core Identity Fields

| Field | Type | Description |
|-------|------|-------------|
| `uid` | text (PK) | Unique device identifier (canonical device ID) |
| `type_id` | integer | OCSF device type ID (see Device Types below) |
| `type` | text | Human-readable device type name |
| `name` | text | Device display name |
| `hostname` | text | Device hostname |
| `ip` | text | Primary IP address |
| `mac` | text | Primary MAC address |

### Extended Identity Fields

| Field | Type | Description |
|-------|------|-------------|
| `uid_alt` | text | Alternate identifier (e.g., Armis ID, NetBox ID) |
| `vendor_name` | text | Device vendor/manufacturer |
| `model` | text | Device model |
| `domain` | text | Network domain |
| `zone` | text | Security zone |
| `subnet_uid` | text | Subnet identifier |
| `vlan_uid` | text | VLAN identifier |
| `region` | text | Geographic region |

### Temporal Fields

| Field | Type | Description |
|-------|------|-------------|
| `first_seen_time` | timestamptz | When device was first discovered |
| `last_seen_time` | timestamptz | Most recent observation |
| `created_time` | timestamptz | Record creation timestamp |
| `modified_time` | timestamptz | Last modification timestamp |

### Risk & Compliance Fields

| Field | Type | Description |
|-------|------|-------------|
| `risk_level_id` | integer | OCSF risk level ID (0-5) |
| `risk_level` | text | Risk level name (Info, Low, Medium, High, Critical) |
| `risk_score` | integer | Numeric risk score (0-100) |
| `is_managed` | boolean | Is device managed by MDM/endpoint management |
| `is_compliant` | boolean | Meets compliance requirements |
| `is_trusted` | boolean | Device trust status |

### JSONB Objects

#### `os` - Operating System Information

```json
{
  "name": "Ubuntu",
  "type": "Linux",
  "version": "22.04",
  "build": "5.15.0-generic",
  "edition": "LTS",
  "kernel_release": "5.15.0-91-generic",
  "cpu_bits": 64,
  "lang": "en_US"
}
```

#### `hw_info` - Hardware Information

```json
{
  "cpu_type": "AMD EPYC 7763",
  "cpu_architecture": "x86_64",
  "cpu_cores": 16,
  "cpu_count": 2,
  "cpu_speed_mhz": 2450,
  "ram_size": 68719476736,
  "serial_number": "ABC123",
  "chassis": "Rack",
  "bios_manufacturer": "American Megatrends",
  "bios_ver": "2.4.1"
}
```

#### `network_interfaces` - Network Interface List

```json
[
  {
    "name": "eth0",
    "ip": "192.168.1.100",
    "mac": "00:11:22:33:44:55",
    "type": "Wired"
  }
]
```

### ServiceRadar-Specific Fields

| Field | Type | Description |
|-------|------|-------------|
| `poller_id` | text | ServiceRadar poller that discovered/monitors this device |
| `agent_id` | text | ServiceRadar agent ID |
| `discovery_sources` | text[] | List of discovery sources (snmp, icmp, grpc, armis, etc.) |
| `is_available` | boolean | Current availability status |
| `metadata` | jsonb | Additional key-value metadata |

## OCSF Device Types

ServiceRadar supports the following OCSF device type IDs:

| type_id | type | Description |
|---------|------|-------------|
| 0 | Unknown | Device type not determined |
| 1 | Server | Server/host |
| 2 | Desktop | Desktop computer |
| 3 | Laptop | Laptop computer |
| 4 | Tablet | Tablet device |
| 5 | Mobile | Mobile phone |
| 6 | Virtual | Virtual machine |
| 7 | IOT | IoT device (sensors, cameras, etc.) |
| 8 | Browser | Browser-based endpoint |
| 9 | Firewall | Network firewall |
| 10 | Switch | Network switch |
| 11 | Hub | Network hub |
| 12 | Router | Network router |
| 13 | IDS | Intrusion detection system |
| 14 | IPS | Intrusion prevention system |
| 15 | Load Balancer | Network load balancer |
| 99 | Other | Other device type |

## API Endpoints

### List Devices

```bash
GET /api/devices
```

Query parameters:
- `limit` - Max results (default 100, max 500)
- `offset` - Pagination offset
- `search` - Search hostname, IP, or device ID
- `status` - Filter by online/offline
- `device_type` - Filter by type name
- `poller_id` - Filter by poller

### Get Device

```bash
GET /api/devices/:device_id
```

### OCSF Export

```bash
GET /api/devices/ocsf/export
```

Export devices in pure OCSF format for integration with security tools.

Query parameters:
- `limit` - Max results (default 100, max 1000)
- `offset` - Pagination offset
- `type_id` - Filter by OCSF device type ID
- `first_seen_after` - Filter by first seen time (ISO8601)
- `last_seen_after` - Filter by last seen time (ISO8601)

Response:
```json
{
  "ocsf_version": "1.7.0",
  "class_uid": 5001,
  "class_name": "Device Inventory Info",
  "devices": [...],
  "count": 50,
  "pagination": {
    "limit": 100,
    "offset": 0,
    "next_offset": null
  }
}
```

## SRQL Queries

Query devices using SRQL (ServiceRadar Query Language):

```
# List all devices
in:devices

# Filter by device type
in:devices type:Router

# Filter by type_id
in:devices type_id:12

# Filter by IP range
in:devices ip:192.168.1.*

# Filter by vendor
in:devices vendor_name:Cisco

# Filter by risk level
in:devices risk_level:High
```

## Type Inference

ServiceRadar automatically infers device types from various sources:

1. **Armis Integration**: Uses `armis_category` metadata
2. **SNMP Discovery**: Parses `sysDescr` for device hints
3. **Explicit Metadata**: Uses `device_type` metadata field

The inference logic runs during device upserts and can be refined over time as more device signatures are identified.

## References

- [OCSF Schema Browser](https://schema.ocsf.io/1.7.0/objects/device)
- [OCSF Device Inventory Info Event](https://schema.ocsf.io/1.7.0/classes/device_inventory_info)
