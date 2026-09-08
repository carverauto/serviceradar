# Proposal: Device Discovery Workflow

## Summary

Add a device discovery workflow that allows users to add new devices to monitoring by:
1. Entering a target IP/hostname
2. Triggering automated discovery (device type detection, interface enumeration)
3. Reviewing discovered information (interfaces, services, capabilities)
4. Selecting what to monitor (SNMP interfaces, ports, services)
5. Creating appropriate monitoring configurations

## Motivation

Currently there is no way for users to:
- Add new devices to monitoring through the UI
- Discover device capabilities automatically
- Configure SNMP interface monitoring for network devices
- Set up ping/TCP checks from the web interface

Users need a guided workflow that:
- Dispatches discovery jobs to appropriate agents based on partition/tenant
- Uses gRPC services (mapper for SNMP, sweep for ICMP/TCP) for discovery
- Creates device records through DIRE (Device Identity Reconciliation Engine)
- Enables interface-level metric collection configuration

## Scope

### In Scope
- Device discovery page with "Add Device" form
- Oban job scheduling for discovery tasks (partition/tenant aware)
- Integration with mapper gRPC service for SNMP walks
- Integration with sweep gRPC service for port scanning
- LiveView real-time updates during discovery
- Interface selection UI for network devices
- ServiceCheck/MetricCollector creation for selected interfaces
- Device type detection and classification

### Out of Scope
- Custom discovery plugins (future)
- Bulk device import (future, separate proposal)
- Auto-discovery/network scanning without user initiation (future)
- SNMP trap handling (separate proposal)

## Design Overview

### Discovery Flow

```
User: Enters IP/hostname in "Add Device" form
         │
         ▼
System: Creates discovery job (Oban)
        - tenant_id, partition_id from user context
        - target IP/hostname
        - discovery type (auto, snmp, ping, etc.)
         │
         ▼
Oban: Picks up job, finds available agent in partition
         │
         ▼
Agent: Determines discovery strategy
        - ICMP ping first (is host reachable?)
        - SNMP probe (is SNMP available?)
        - TCP scan (what ports are open?)
         │
         ▼
Agent: Dispatches to gRPC services
        - mapper: SNMP walk for device info + interfaces
        - sweep: TCP port scan for services
         │
         ▼
Results: Stream back to Core via ERTS
         │
         ▼
Core: Process results
        - Create/update device via DIRE
        - Store discovered interfaces
        - Classify device type
         │
         ▼
LiveView: Real-time updates
        - Show discovery progress
        - Display discovered interfaces
        - Enable monitoring configuration
         │
         ▼
User: Selects interfaces to monitor
         │
         ▼
System: Creates ServiceChecks/MetricCollectors
        - SNMP OID collection for interfaces
        - Ping checks for availability
        - Custom poll intervals per interface
```

### Key Components

1. **DiscoveryLive.New** - LiveView for initiating discovery
2. **DiscoveryJob** - Oban worker for dispatching discovery tasks
3. **DiscoveredDevice** - Ash resource for storing discovery results
4. **DiscoveredInterface** - Ash resource for network interfaces
5. **InterfaceMonitor** - Ash resource for interface monitoring config

### gRPC Services Integration

- **mapper** (`serviceradar-mapper`): SNMP walk, device classification
- **sweep** (`serviceradar-sweep`): TCP/ICMP scanning

### Partition/Tenant Awareness

All discovery operations respect:
- User's tenant_id for data isolation
- Partition selection for network segmentation
- Agent availability in the target partition

## Success Criteria

1. User can add a device by entering IP/hostname
2. System automatically detects device type (router, switch, server, etc.)
3. For network devices, user sees list of discovered interfaces
4. User can select which interfaces to monitor
5. System creates appropriate ServiceChecks for selected interfaces
6. Discovery progress updates in real-time via LiveView
7. All operations are partition/tenant isolated

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| No agent available in partition | Discovery fails | Show clear error, suggest partition config |
| SNMP credentials incorrect | No interface data | Allow credential input, show SNMP status |
| Large device with many interfaces | Slow discovery | Paginate results, show progress |
| Device unreachable | Discovery times out | Show timeout error, suggest network check |

## Dependencies

- mapper gRPC service (existing)
- sweep gRPC service (existing, being renamed from serviceradar-agent)
- DIRE device identity system (existing)
- Oban job scheduling (existing)
- Horde agent registry (existing)

## Timeline

This is a multi-phase feature. Implementation order:
1. Discovery job infrastructure (Oban worker, agent dispatch)
2. Discovery LiveView (form, progress, results)
3. mapper integration (SNMP walks)
4. Interface selection UI
5. ServiceCheck creation from selection
6. sweep integration (port scanning)
