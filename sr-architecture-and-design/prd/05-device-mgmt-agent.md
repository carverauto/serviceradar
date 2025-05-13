# ServiceRadar Agent Device Caching & Reporting PRD

## 1. Overview
This PRD details the implementation strategy for enhancing the `serviceradar-agent` to support device information collection and reporting without local caching. The agent will continue collecting raw `DeviceInfo` from edge services (sweep, ICMP, port, SNMP) unchanged, include `AgentID` in raw data via `context.Context`, and rely on the core service to derive the devices stream using a Proton materialized view. Pollers will add `PollerID` to raw data, ensuring traceability. The plan prioritizes minimal agent resource usage, scalability, and minimal disruption to existing functionality.

## 2. Goals
- Collect raw `DeviceInfo` from edge services without local caching.
- Include `AgentID` in raw data responses using `context.Context` for traceability.
- Maintain existing `GetStatus` gRPC method for raw data reporting.
- Support `PollerID` addition by pollers for complete traceability.
- Resolve the `OpenPorts` reference issue in the sweep service.
- Ensure scalability for large networks without increasing agent memory footprint.

## 3. Background
The ServiceRadar architecture involves:

- **Edge Services**: Discover and monitor devices (e.g., `SweepService` in `sweep_service.go`), producing raw data.
- **Agent**: Aggregates raw data and forwards to pollers (`server.go`, `types.go`).
- **Poller**: Collects data from agents and forwards to the core (`poller.go`).
- **Core**: Persists raw data in Proton streams and derives the devices stream.

The agent currently collects raw data but lacks `agent_id` and `poller_id` tracking. A previous plan proposed a local `DeviceCache`, but concerns about memory footprint led to a stream-based approach, where the core derives the devices stream using a materialized view, minimizing agent changes.

## 4. Current State Analysis (`pkg/agent`)
- **Raw Data Collection**: The agent collects raw data from edge services via `GetStatus`, storing it in JSON `Message` fields (e.g., `extractDevicesFromSweep`, `extractDeviceInfoFromICMP`).
- **No Cache**: The agent does not maintain a device cache, but extraction logic needs to include `agent_id`.
- **Reporting**: `GetStatus` returns raw data without `agent_id`, and no `GetDeviceStatus` exists.
- **Checkers**: Sweep, ICMP, port, and SNMP checkers generate device data, but extraction logic needs consistency and `agent_id` inclusion.
- **Traceability**: No mechanism exists to propagate `AgentID` or include `PollerID`.

## 5. Proposed Changes

### 5.1 Data Structures (`types.go`)

**ServerConfig**:
Ensure `AgentID` is available:
```go
type ServerConfig struct {
    AgentID            string                 `json:"agent_id"`
    AgentName          string                 `json:"agent_name,omitempty"`
    ListenAddr         string                 `json:"listen_addr"`
    Security           *models.SecurityConfig `json:"security"`
    KVAddress          string                 `json:"kv_address,omitempty"`
    KVSecurity         *models.SecurityConfig `json:"kv_security,omitempty"`
    CheckersDir        string                 `json:"checkers_dir"`
}
```

**Server**:
Add context for `AgentID`:
```go
type Server struct {
    // ... other fields ...
    ctx context.Context // Context with AgentID
}
```

**Remove DeviceCache**:
- Delete `DeviceCache`, `DeviceState`, and `DeviceCacheConfig`, as no caching is needed.

### 5.2 Raw Data Collection (`server.go`)

**GetStatus**:
Include `AgentID` from context:
```go
func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
    agentID, ok := common.GetAgentID(s.ctx)
    if !ok {
        log.Printf("AgentID not found in server context")
        return nil, fmt.Errorf("agent ID not found in context")
    }

    var response *proto.StatusResponse
    switch {
    case isRperfCheckerRequest(req):
        response, _ = s.handleRperfChecker(ctx, req)
    case isICMPRequest(req):
        response, _ = s.handleICMPCheck(ctx, req)
    case isSweepRequest(req):
        response, _ = s.getSweepStatus(ctx)
    default:
        response, _ = s.handleDefaultChecker(ctx, req)
    }

    if response != nil {
        response.AgentId = agentID
        // Update Message JSON to include agent_id
        response.Message = includeAgentIDInMessage(response.Message, agentID)
    }

    return response, nil
}

func includeAgentIDInMessage(message, agentID string) string {
    var data map[string]interface{}
    if err := json.Unmarshal([]byte(message), &data); err != nil {
        log.Printf("Failed to unmarshal message: %v", err)
        return message
    }
    data["agent_id"] = agentID
    updatedMessage, err := json.Marshal(data)
    if err != nil {
        log.Printf("Failed to marshal message: %v", err)
        return message
    }
    return string(updatedMessage)
}
```

**Extraction Functions**:
Update to include `agent_id` in JSON:
```go
func extractDeviceInfoFromICMP(message, host string, agentID string) string {
    var icmpData struct {
        Host         string  `json:"host"`
        ResponseTime int64   `json:"response_time"`
        PacketLoss   float64 `json:"packet_loss"`
        Available    bool    `json:"available"`
        AgentID      string  `json:"agent_id"`
    }
    if err := json.Unmarshal([]byte(message), &icmpData); err != nil {
        log.Printf("Failed to unmarshal ICMP data: %v", err)
        return message
    }
    icmpData.AgentID = agentID
    updatedMessage, err := json.Marshal(icmpData)
    if err != nil {
        log.Printf("Failed to marshal ICMP data: %v", err)
        return message
    }
    return string(updatedMessage)
}

func extractDevicesFromSweep(message string, agentID string) string {
    var sweepData struct {
        Hosts   []models.HostResult `json:"hosts"`
        AgentID string              `json:"agent_id"`
    }
    if err := json.Unmarshal([]byte(message), &sweepData); err != nil {
        log.Printf("Failed to unmarshal sweep data: %v", err)
        return message
    }
    sweepData.AgentID = agentID
    now := time.Now().Unix()
    for i, host := range sweepData.Hosts {
        sweepData.Hosts[i].Timestamp = now
    }
    updatedMessage, err := json.Marshal(sweepData)
    if err != nil {
        log.Printf("Failed to marshal sweep data: %v", err)
        return message
    }
    return string(updatedMessage)
}
```

### 5.3 Service Integration (`sweep_service.go`, etc.)

**SweepService**:
Include `AgentID` in JSON:
```go
func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
    agentID, ok := common.GetAgentID(ctx)
    if !ok {
        log.Printf("AgentID not found in context")
        return nil, fmt.Errorf("agent ID not found in context")
    }

    summary, err := s.sweeper.GetStatus(ctx)
    if err != nil {
        log.Printf("Failed to get sweep summary: %v", err)
        return nil, fmt.Errorf("failed to get sweep summary: %w", err)
    }

    s.mu.RLock()
    data := struct {
        Network        string              `json:"network"`
        TotalHosts     int                 `json:"total_hosts"`
        AvailableHosts int                 `json:"available_hosts"`
        LastSweep      int64               `json:"last_sweep"`
        Ports          []models.PortCount  `json:"ports"`
        Hosts          []models.HostResult `json:"hosts"`
        DefinedCIDRs   int                 `json:"defined_cidrs"`
        UniqueIPs      int                 `json:"unique_ips"`
        AgentID        string              `json:"agent_id"`
    }{
        Network:        strings.Join(s.config.Networks, ","),
        TotalHosts:     summary.TotalHosts,
        AvailableHosts: summary.AvailableHosts,
        LastSweep:      summary.LastSweep,
        Ports:          summary.Ports,
        Hosts:          summary.Hosts,
        DefinedCIDRs:   len(s.config.Networks),
        UniqueIPs:      s.stats.uniqueIPs,
        AgentID:        agentID,
    }
    s.mu.RUnlock()

    for _, host := range data.Hosts {
        if host.Available && len(host.OpenPorts) == 0 && !containsICMPMode(s.config.SweepModes) {
            log.Printf("Warning: Host %s is available but has no open ports", host.Host)
        }
    }

    statusJSON, err := json.Marshal(data)
    if err != nil {
        log.Printf("Failed to marshal status: %v", err)
        return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
    }

    return &proto.StatusResponse{
        Available:    true,
        Message:      string(statusJSON),
        ServiceName:  "network_sweep",
        ServiceType:  "sweep",
        ResponseTime: time.Since(time.Unix(summary.LastSweep, 0)).Nanoseconds(),
        AgentId:      agentID,
    }, nil
}
```

**Other Checkers**:
Ensure ICMP, port, and SNMP checkers include `agent_id` in their JSON responses, using context.

### 5.4 Poller Integration (`pkg/poller/poller.go`)

**pollAgent**:
Add `PollerID` to `ServiceStatus`:
```go
func (p *Poller) pollAgent(ctx context.Context, agentID string, agentConn *AgentConnection) ([]*proto.ServiceStatus, error) {
    client := proto.NewAgentServiceClient(agentConn.client.GetConnection())
    pollerID, ok := common.GetPollerID(p.ctx)
    if !ok {
        return nil, fmt.Errorf("poller ID not found in context")
    }
    var statuses []*proto.ServiceStatus
    for _, check := range agentConn.config.Checks {
        resp, err := client.GetStatus(ctx, &proto.StatusRequest{
            ServiceName: check.ServiceName,
            ServiceType: check.ServiceType,
            Details:     check.Details,
            Port:        check.Port,
        })
        if err != nil {
            log.Printf("Failed to get status for %s: %v", check.ServiceName, err)
            continue
        }
        statuses = append(statuses, &proto.ServiceStatus{
            ServiceName:  resp.ServiceName,
            Available:    resp.Available,
            Message:      resp.Message,
            ServiceType:  resp.ServiceType,
            ResponseTime: resp.ResponseTime,
            PollerId:     pollerID,
        })
    }
    return statuses, nil
}
```

**reportToCore**:
Forward raw data with `PollerID`:
```go
func (p *Poller) reportToCore(ctx context.Context, statuses []*proto.ServiceStatus) error {
    pollerID, ok := common.GetPollerID(p.ctx)
    if !ok {
        return fmt.Errorf("poller ID not found in context")
    }
    _, err := p.coreClient.ReportStatus(ctx, &proto.PollerStatusRequest{
        Services:  statuses,
        PollerId:  pollerID,
        Timestamp: time.Now().Unix(),
    })
    if err != nil {
        return fmt.Errorf("failed to report status to core: %w", err)
    }
    return nil
}
```

## 6. Implementation Phases

### Phase 1: Core Infrastructure (3 days)
- Update `types.go` to remove `DeviceCache` and add context to `Server`.
- Initialize context in `server.go` with `AgentID`.
- Update `proto/serviceradar.proto` to include `agent_id` in `StatusResponse` and `poller_id` in `ServiceStatus`.
- Create `pkg/common/context.go` for context key management.

### Phase 2: Agent and Poller Updates (4 days)
- Modify `GetStatus` to include `AgentID` in `StatusResponse` and JSON `Message`.
- Update extraction functions to include `agent_id` in JSON.
- Validate `OpenPorts` in `sweep_service.go`.
- Update poller to include `PollerID` in `ServiceStatus`.

### Phase 3: Testing (4 days)
- Add unit tests for context-based `AgentID` propagation.
- Test raw data collection with `agent_id` and `poller_id`.
- Simulate large device counts (10,000+) to verify agent memory usage.

## 7. Success Metrics
- Agent includes `agent_id` in all `StatusResponse` messages and JSON data.
- Poller includes `poller_id` in `ServiceStatus` messages.
- Raw data collection remains unchanged, with no local caching.
- `OpenPorts` is consistently populated.
- Agent memory usage remains minimal (<1 MB for 10,000 devices).
- Raw data reaches the core within 5 minutes.

## 8. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Increased network traffic from raw data | Use gRPC compression and batching in core. |
| Missing context `AgentID` or `PollerID` | Log errors and return gRPC error if IDs are absent. |
| Materialized view latency | Optimize view with indexing and test for 5-minute updates. |

## 9. Open Questions
- How should context errors (e.g., missing `AgentID`) be reported to operators?
- Should the core implement a retry buffer for outages?

## 10. Testing Plan

### Unit Tests
- Test `GetStatus` for `AgentID` inclusion in `StatusResponse` and JSON.
- Test extraction functions for `agent_id` in JSON.
- Test context-based `AgentID` propagation.

### Integration Tests
- Test agent-poller communication with `agent_id` and `poller_id`.
- Verify raw data consistency with existing collection.

### System Tests
- End-to-end test from edge to core with `agent_id` and `poller_id`.
- Performance test with 10,000+ devices, monitoring agent memory.

## 11. Conclusion
This PRD provides a lightweight plan for enhancing the `serviceradar-agent` to support device information collection without caching, using context-based `AgentID` propagation and poller-added `PollerID`. The stream-based approach minimizes agent resource usage while enabling a unified device inventory in Proton.

### Next Steps
- Coordinate with core team for materialized view implementation.
- Develop detailed test cases.
- Proceed with Phase 1 after approval.