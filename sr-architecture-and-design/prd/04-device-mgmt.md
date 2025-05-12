# ServiceRadar Device Management System PRD

## Overview

ServiceRadar requires a unified device management system that consolidates device information from various sources and maintains a single source of truth in the core database. The system must efficiently track thousands of devices across the network, with data flowing from edge services through agents and pollers to the core service.

## Background

Currently, device information is scattered across different components:
- Network sweep services discover devices but don't consistently track them
- Service checks monitor specific devices but don't feed into a central inventory
- There's no unified view of all network devices for monitoring and analysis purposes
- The `OpenPorts` field reference is unresolved in the sweep data model

## Architecture Context

The ServiceRadar architecture follows a clear hierarchical flow:

1. **Edge Services** (Sweep, ICMP, SNMP, etc.) run monitoring and discovery functions
2. **Agent** coordinates with edge services to collect status and data
3. **Poller** collects information from agents at regular intervals
4. **Core Service** processes data and persists it in the database

Key constraint: Edge services and agents don't have direct database access. All data must flow through the agent → poller → core pipeline.

## Objectives

1. Create a unified device inventory in the core Proton database
2. Implement efficient device discovery through existing services
3. Establish a data pipeline from edge to core for device information
4. Support incremental updates to handle large numbers of devices
5. Enable deduplication and reconciliation of device information from multiple sources
6. Resolve the "OpenPorts" reference issue in the sweep data model

## Device Information Model

The system will use two primary models:

### 1. DeviceInfo Model (Edge/Agent level)

This model represents device information at the agent level:

```go
type DeviceInfo struct {
    // Basic identification
    IP              string   `json:"ip"`                        // Primary identifier
    MAC             string   `json:"mac,omitempty"`             // MAC address if available
    Hostname        string   `json:"hostname,omitempty"`        // DNS hostname if resolved

    // Status
    Available       bool     `json:"available"`                 // Current availability status
    LastSeen        int64    `json:"last_seen"`                 // Unix timestamp of last observation

    // Discovery metadata
    DiscoverySource string   `json:"discovery_source"`          // How device was discovered (network_sweep, icmp, snmp, etc.)
    DiscoveryTime   int64    `json:"discovery_time,omitempty"`  // When first discovered

    // Network information
    OpenPorts       []int    `json:"open_ports,omitempty"`      // List of open ports found
    NetworkSegment  string   `json:"network_segment,omitempty"` // Network segment/VLAN if known

    // Service information
    ServiceType     string   `json:"service_type,omitempty"`    // Type of service used for discovery (port, icmp, snmp)
    ServiceName     string   `json:"service_name,omitempty"`    // Name of service that discovered it

    // Response metrics
    ResponseTime    int64    `json:"response_time,omitempty"`   // Response time in nanoseconds
    PacketLoss      float64  `json:"packet_loss,omitempty"`     // Packet loss percentage (for ICMP)

    // Hardware/OS information if available
    DeviceType      string   `json:"device_type,omitempty"`     // Router, switch, server, etc.
    Vendor          string   `json:"vendor,omitempty"`          // Hardware vendor if known
    Model           string   `json:"model,omitempty"`           // Device model if known
    OSInfo          string   `json:"os_info,omitempty"`         // OS information if available

    // Additional metadata as string map for extensibility
    Metadata        map[string]string `json:"metadata,omitempty"` // Additional metadata
}
```

### 2. Device Model (Core/Database level)

This model is used for storing device information in the Proton database:

```go
type Device struct {
    DeviceID        string                 `json:"device_id"`        // Unique identifier
    PollerID        string                 `json:"poller_id"`        // Poller that reported the device
    DiscoverySource string                 `json:"discovery_source"` // How device was discovered
    IP              string                 `json:"ip"`               // IP address
    MAC             string                 `json:"mac,omitempty"`    // MAC address
    Hostname        string                 `json:"hostname,omitempty"` // DNS hostname
    FirstSeen       time.Time              `json:"first_seen"`       // First discovery timestamp
    LastSeen        time.Time              `json:"last_seen"`        // Last seen timestamp
    IsAvailable     bool                   `json:"is_available"`     // Current status
    Metadata        map[string]interface{} `json:"metadata,omitempty"` // Additional attributes
}
```

## Data Flow

### 1. Edge Service to Agent

- Edge services (Sweep, ICMP, etc.) discover or monitor devices
- When reporting status to the agent, they include device information
- For the Sweep service, the output JSON includes an array of discovered hosts with IP, MAC, hostname, availability, and open ports

### 2. Agent to Poller

- Agent maintains a local device cache to track discovered devices
- Agent collects device information from all services
- When polled, agent provides both service status and device information
- Any new or changed devices are marked for reporting

### 3. Poller to Core

- Poller periodically collects status and device information from agents
- Device data is batched to handle large numbers efficiently
- Poller sends device information as part of its status report to the core
- Allows for incremental updates rather than sending all devices every time

### 4. Core to Database

- Core service processes incoming device information
- Converts device information into database records
- Performs deduplication based on IP address + poller ID
- Preserves first_seen timestamps when updating existing devices
- Consolidates information from multiple sources

## Implementation Requirements

### Device Cache (Agent)

- The agent should maintain a local cache of discovered devices
- The cache tracks which devices have been reported vs. changed
- It should support incremental reporting to handle thousands of devices
- Periodic full reports ensure consistency with the core

### Protocol Updates

- Extend the gRPC protocol to include device information:
- Add DeviceInfo data to ServiceStatus (for sweep and other services)
- Add device_data field to PollerStatusRequest

### Proton Database Stream

- Create a "devices" stream in Proton with appropriate fields
- Support efficient querying of devices by IP, MAC, and other attributes
- Implement batch insertion for device records

### Deduplication Strategy

- Use IP address + poller ID as a primary key for deduplication
- When the same device is reported by multiple services, consolidate information
- Preserve first_seen timestamp across updates
- Update last_seen timestamp and availability status on each report

## Key Features

### 1. Centralized Device Inventory

Maintain a single source of truth for all network devices with:
- Basic identification (IP, MAC, hostname)
- Current status (available, last seen)
- Discovery information (source, time)
- Network details (open ports, etc.)

### 2. Incremental Device Reporting

Efficiently handle large device networks by:
- Only reporting new or changed devices in routine updates
- Sending full device reports periodically for consistency
- Batching device updates to minimize network traffic

### 3. Multi-Source Device Discovery

Combine device information from multiple sources:
- Network sweeps (ICMP, TCP scans)
- Service checks (SNMP, port monitors)
- Manual configuration
- Integration with external systems

### 4. Device Metadata Management

Maintain rich device information:
- Track open ports, services, and protocols
- Store performance metrics (response time, packet loss)
- Capture hardware and OS information when available
- Support extensible metadata for future requirements

## Success Metrics

The device management system will be considered successful if it:

1. Accurately tracks all network devices across the infrastructure
2. Efficiently handles networks with 10,000+ devices
3. Updates device status within 5 minutes of changes
4. Maintains historical data about device discovery and availability
5. Correctly consolidates information from multiple discovery sources
6. Resolves the OpenPorts reference issue in the sweep data model

## Future Considerations

- Device filtering and search capabilities
- Device relationship mapping (topology)
- Integration with external inventory systems
- Device classification and tagging
- Alerting on device status changes
- Historical device metrics and trend analysis

## Phases of Implementation

### Phase 1: Core Infrastructure
- Update models and protocols
- Implement database schemas
- Create basic device extraction in core

### Phase 2: Agent-Side Caching
- Implement device cache in agent
- Add incremental reporting logic
- Handle device information from various services

### Phase 3: Advanced Features
- Add deduplication and reconciliation logic
- Implement periodic full reporting
- Support device metadata enrichment

### Phase 4: Optimization and Scaling
- Optimize for large device networks
- Add batch processing
- Implement query optimization