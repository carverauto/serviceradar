# Change: Add Interface Metrics Discovery

## Why

Currently, the SNMP mapper discovers interfaces but does NOT record which metrics/OIDs are available per interface. Users enabling metrics collection must manually guess which OIDs work for a given interface, leading to polling failures and a poor user experience.

The mapper already performs SNMP walks to enumerate interfaces. By extending this to probe for common interface metrics (ifInOctets, ifOutOctets, etc.), we can:
1. Present users with a dropdown of available metrics when enabling collection
2. Prevent configuration of unsupported OIDs
3. Enable intelligent defaults based on device capabilities

## What Changes

### Go Mapper Enhancement
- Extend `handleInterfaceDiscoverySNMP()` to probe for standard interface counters after discovering each interface
- Add `available_metrics` field to `DiscoveredInterface` struct
- Probe for both 32-bit (ifInOctets) and 64-bit (ifHCInOctets) counter support

### Protocol Buffer Updates
- Add `available_metrics` repeated field to `DiscoveredInterface` message
- Define `InterfaceMetric` message with oid, name, data_type, supports_64bit fields

### Elixir Schema Changes
- Add `available_metrics` JSONB attribute to Interface resource
- Update `MapperResultsIngestor` to persist discovered metrics

### UI Enhancement
- Update interface details page metrics collection section
- Show dropdown of available metrics filtered by what the interface supports
- Allow selecting multiple metrics for collection

## Impact

- **Affected specs**: snmp-checker, device-inventory
- **Affected code**:
  - `pkg/mapper/snmp_polling.go` - Add OID probing
  - `pkg/mapper/types.go` - Extend DiscoveredInterface
  - `proto/discovery/discovery.proto` - Add metrics field
  - `elixir/serviceradar_core/lib/serviceradar/inventory/interface.ex` - Add attribute
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex` - Handle new field
  - `web-ng/lib/serviceradar_web_ng_web/live/interface_live/show.ex` - UI dropdown

## Standard Interface OIDs to Discover

| Metric Name | OID (32-bit) | OID (64-bit) | Data Type |
|-------------|--------------|--------------|-----------|
| In Octets | .1.3.6.1.2.1.2.2.1.10 | .1.3.6.1.2.1.31.1.1.1.6 | counter |
| Out Octets | .1.3.6.1.2.1.2.2.1.16 | .1.3.6.1.2.1.31.1.1.1.10 | counter |
| In Errors | .1.3.6.1.2.1.2.2.1.14 | - | counter |
| Out Errors | .1.3.6.1.2.1.2.2.1.20 | - | counter |
| In Discards | .1.3.6.1.2.1.2.2.1.13 | - | counter |
| Out Discards | .1.3.6.1.2.1.2.2.1.19 | - | counter |
| In Unicast Pkts | .1.3.6.1.2.1.2.2.1.11 | .1.3.6.1.2.1.31.1.1.1.7 | counter |
| Out Unicast Pkts | .1.3.6.1.2.1.2.2.1.17 | .1.3.6.1.2.1.31.1.1.1.11 | counter |
| Oper Status | .1.3.6.1.2.1.2.2.1.8 | - | gauge |
| Admin Status | .1.3.6.1.2.1.2.2.1.7 | - | gauge |

## Non-Goals

- This change does NOT implement automatic OID polling configuration
- This change does NOT modify the SNMP polling service
- Discovery of vendor-specific OIDs is out of scope (future enhancement)
