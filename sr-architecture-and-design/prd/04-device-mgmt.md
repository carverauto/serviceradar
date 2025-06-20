# ServiceRadar Device Management System PRD

## Overview

ServiceRadar requires a unified device management system that consolidates device information from various sources into a single source of truth in the core Proton database. The system leverages existing raw data streams from edge services, flowing through agents and pollers to the core service, where a materialized view derives the devices stream. It ensures traceability of `agent_id` and `poller_id` for each device, efficiently tracking thousands of devices across the network without increasing the agent's memory footprint.

## Background

Currently, device information is scattered across different components:

- Network sweep services discover devices but don't consistently track them.
- Service checks monitor specific devices but don't feed into a central inventory.
- There's no unified view of all network devices for monitoring and analysis.
- The `OpenPorts` field reference is unresolved in the sweep data model.
- No mechanism exists to track which agent discovered a device or which poller reported it.

## Architecture Context

The ServiceRadar architecture follows a hierarchical flow:

1. **Edge Services** (Sweep, ICMP, SNMP, etc.) run monitoring and discovery functions, producing raw data.
2. **Agent** coordinates with edge services to collect raw status and device data, forwarding it to pollers without local caching.
3. **Poller** collects raw data from multiple agents at regular intervals and forwards it to the core.
4. **Core Service** processes raw data, persists it to Proton streams, and derives the devices stream using a materialized view.

**Key Constraints**:
- Edge services and agents lack direct database access; all data flows through the agent → poller → core pipeline.
- Agents operate independently and are unaware of which poller queries them, supporting horizontal scaling of pollers.
- `AgentID` and `PollerID` are propagated via `context.Context` to ensure traceability without embedding in service configurations.
- Existing raw data collection (e.g., sweep, ICMP, SNMP results) must remain unchanged, with only `agent_id` and `poller_id` added.

## Objectives

1. Create a unified device inventory in the core Proton database with `agent_id` and `poller_id` tracking.
2. Leverage existing edge service data to derive device information without agent-side caching.
3. Maintain the existing data pipeline from edge to core, adding only `agent_id` and `poller_id` propagation.
4. Support deduplication using `IP`, `agent_id`, and `poller_id` as a composite key in the core.
5. Resolve the `OpenPorts` reference issue in the sweep data model.
6. Ensure scalability for multiple agents and pollers in a horizontally scaled environment with minimal agent resource usage.

## Device Information Model

The system uses two primary models:

### 1. DeviceInfo Model (Edge/Agent level)

This model represents raw device information collected by edge services and forwarded by agents:

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
    DiscoverySources []string `json:"discovery_sources"`        // Sources that reported the device
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

This model is used for storing device information in the Proton devices stream:

```go
type Device struct {
    DeviceID        string                 `json:"device_id"`        // Unique identifier
    AgentID         string                 `json:"agent_id"`         // Agent that discovered the device
    PollerID        string                 `json:"poller_id"`        // Poller that reported the device
    DiscoverySources []string               `json:"discovery_sources"` // Sources that reported the device
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
- Edge services (Sweep, ICMP, SNMP, etc.) discover or monitor devices, producing raw data (e.g., JSON with IP, MAC, hostname, open ports).
- They report status to the agent via `GetStatus` responses, including raw data in the `Message` field.
- The agent retrieves `AgentID` from `context.Context` and includes it in the JSON data and `StatusResponse`.

### 2. Agent to Poller
- The agent forwards raw data to the poller using the existing `GetStatus` gRPC method, including `agent_id` in `StatusResponse`.
- No local caching or preprocessing of device data occurs, minimizing memory usage.
- The agent is unaware of `poller_id`, allowing multiple pollers to query it without conflicts.

### 3. Poller to Core
- The poller periodically collects raw data from agents via `GetStatus`, using `context.Context` to access its `PollerID`.
- The poller attaches `poller_id` to each `ServiceStatus` message, ensuring traceability.
- Raw data is forwarded to the core in `PollerStatusRequest` messages, preserving `agent_id` and `poller_id`.

### 4. Core to Database
- The core service parses raw data from `ServiceStatus` messages (e.g., JSON in `Message`) and writes it to Proton streams (`sweep_results`, `icmp_results`, `snmp_results`), including `agent_id` and `poller_id`.
- A materialized view aggregates and deduplicates data from these streams into the `devices` stream, using `IP`, `agent_id`, and `poller_id` as a composite key.
- The view preserves `first_seen` timestamps, updates `last_seen` and `is_available`, and merges metadata intelligently.

## Implementation Requirements

### Raw Data Collection (Agent)
- Continue existing raw data collection from edge services without modification.
- Include `agent_id` in `StatusResponse` and raw data JSON, retrieved from `context.Context` (in `pkg/common/context.go`).
- Avoid local caching to minimize memory footprint.

### Protocol Updates
- Update `proto/serviceradar.proto`:
    - Ensure `agent_id` is included in `StatusResponse`.
    - Add `poller_id` to `ServiceStatus` in `PollerStatusRequest`.
    - Remove `DeviceStatusRequest`, `DeviceStatusResponse`, and `devices` from `PollerStatusRequest`, as device reporting is handled via raw data streams.

### Proton Database Streams
- Maintain existing streams (`sweep_results`, `icmp_results`, `snmp_results`) with fields for `ip`, `mac`, `hostname`, `open_ports`, `available`, `timestamp`, `agent_id`, `poller_id`, and `metadata`.
- Create a `devices` stream with fields for `device_id`, `agent_id`, `poller_id`, `discovery_sources`, `ip`, `mac`, `hostname`, `first_seen`, `last_seen`, `is_available`, and `metadata`.
- Implement a materialized view to derive `devices` from raw streams, supporting efficient querying by `IP`, `agent_id`, and `poller_id`.
- Use batch insertion for raw stream writes to handle large volumes.

### Deduplication Strategy
- Use `IP`, `agent_id`, and `poller_id` as a composite key for deduplication in the materialized view.
- Consolidate multi-source data, preserving `first_seen` and updating `last_seen` and `is_available`.
- Merge metadata using Proton's `MAP_AGG` function, prioritizing newer data for conflicts.

### Context-Based ID Management
- Agents store `AgentID` in `context.Context` at startup, retrieved from `ServerConfig.AgentID`.
- Pollers store `PollerID` in `context.Context`, retrieved from `Config.PollerID`.
- Use a custom context key (`pkg/common/context.go`) to safely propagate `AgentID` and `PollerID`.

## Key Features

### 1. Centralized Device Inventory
Maintain a single source of truth in the `devices` stream with:
- Identification (`IP`, `MAC`, `hostname`, `agent_id`, `poller_id`).
- Status (`is_available`, `last_seen`).
- Discovery details (`discovery_sources`, `first_seen`).
- Extensible metadata.

### 2. Stream-Based Device Derivation
- Derive the `devices` stream from raw data streams (`sweep_results`, `icmp_results`, `snmp_results`) using a materialized view.
- Aggregate and deduplicate data in the core, minimizing agent resource usage.
- Support real-time updates with minimal latency.

### 3. Multi-Source Device Discovery
Combine information from:
- Network sweeps (ICMP, TCP scans).
- Service checks (SNMP, port monitors).
- Potential integration with external systems.

### 4. Agent-Poller Traceability
- Agents include `agent_id` in all gRPC responses, retrieved from context.
- Pollers attach `poller_id` to raw data records, ensuring clear tracking of the agent-poller relationship.
- Supports multiple pollers querying the same agent without requiring the agent to track `poller_id`.

## Success Metrics
The device management system is successful if it:
1. Accurately tracks all network devices with `agent_id` and `poller_id` in the `devices` stream.
2. Handles networks with 10,000+ devices efficiently.
3. Updates device status within 5 minutes of changes.
4. Maintains historical data (`first_seen`, `last_seen`).
5. Correctly consolidates multi-source information in the materialized view.
6. Resolves the `OpenPorts` reference issue.
7. Ensures `agent_id` and `poller_id` are consistently propagated in raw data streams.

## Future Considerations
- Device filtering and search by `agent_id` or `poller_id`.
- Device relationship mapping (topology).
- Integration with external inventory systems.
- Device classification and tagging.
- Alerting on device status changes.
- Historical device metrics and trend analysis.
- Auto-generation of `PollerID` during installation.

## Phases of Implementation

### Phase 1: Core Infrastructure
- Update gRPC protocol to include `agent_id` in `StatusResponse` and `poller_id` in `ServiceStatus`.
- Create context-based ID management in `pkg/common/context.go`.
- Ensure raw data streams include `agent_id` and `poller_id`.

### Phase 2: Agent and Poller Updates
- Modify agent to propagate `AgentID` via context and include it in raw data.
- Update poller to propagate `PollerID` and attach it to raw data records.
- Validate existing raw data collection for consistency.

### Phase 3: Proton Stream Processing
- Create `devices` stream and materialized view in Proton.
- Implement deduplication and multi-source merging in the view.
- Optimize stream writes for large volumes.

### Phase 4: Testing and Optimization
- Test end-to-end data flow with `agent_id` and `poller_id`.
- Optimize materialized view for performance with 10,000+ devices.
- Monitor agent memory usage and network traffic.