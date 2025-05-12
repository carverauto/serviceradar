# ServiceRadar Agent Device Caching & Reporting PRD

## 1. Overview
This PRD details the implementation strategy for enhancing the serviceradar-agent to support device caching and reporting. The agent will collect DeviceInfo from edge services (sweep, ICMP, port, SNMP), maintain a local cache, and report devices to the poller incrementally and periodically in full. The plan prioritizes efficiency, scalability, and minimal disruption to existing functionality, using a dedicated GetDeviceStatus gRPC method to ensure performance.

## 2. Goals
- Collect and cache DeviceInfo from all edge services reliably.
- Maintain an in-memory DeviceCache with state tracking (new, changed, reported).
- Support incremental reporting to the poller, minimizing network overhead.
- Enable periodic full synchronization for consistency.
- Implement cache cleanup for stale entries.
- Define a scalable gRPC protocol for device reporting.

## 3. Background
The ServiceRadar architecture involves:

- **Edge Services**: Discover and monitor devices (e.g., SweepService in sweep_service.go).
- **Agent**: Aggregates data, caches it, and reports to the poller (server.go, types.go).
- **Poller**: Collects data from agents and forwards to the core (poller.go).
- **Core**: Persists data in the Proton database.

The agent currently has a basic DeviceCache but lacks reporting logic and advanced cache management. This PRD addresses these gaps, ensuring efficient data flow to the poller.

## 4. Current State Analysis (pkg/agent)

- **Cache Structure**: The DeviceCache (types.go) stores devices by IP, with DeviceState tracking Info, Reported, Changed, and LastSeen. It's thread-safe but lacks configuration for reporting intervals or cleanup.
- **Cache Population**: The updateDeviceCache function (server.go) extracts DeviceInfo from sweep, ICMP, port, and SNMP checks, but merging logic is basic (overwrites Info).
- **Reporting**: No mechanism exists to report DeviceCache contents to the poller. GetStatus handles service status only.
- **Checkers**: Sweep, ICMP, port, and SNMP checkers generate device data, but extraction logic needs refinement for consistency.

## 5. Proposed Changes

### 5.1 Data Structures (types.go)
**DeviceCache**:

Enhance to include reporting and cleanup configuration:
```go
type DeviceCache struct {
    Devices             map[string]*DeviceState // IP -> device state
    LastReport          time.Time               // Last incremental report
    LastFullReport      time.Time               // Last full report
    IncrementalInterval time.Duration           // Interval for incremental reports (e.g., 5m)
    FullReportInterval  time.Duration           // Interval for full reports (e.g., 1h)
    CleanupInterval     time.Duration           // Interval for cleanup (e.g., 1h)
    MaxAge              time.Duration           // Max age for devices (e.g., 24h)
    BatchSize           int                     // Max devices per report (e.g., 1000)
    mu                  sync.RWMutex
}
```

**DeviceState**:

Add multi-source tracking and first-seen timestamp:
```go
type DeviceState struct {
    Info         models.DeviceInfo     // Device data
    Reported     bool                  // Reported to poller
    Changed      bool                  // Changed since last report
    LastSeen     time.Time             // Last observation
    FirstSeen    time.Time             // First observation
    Sources      map[string]bool       // Discovery sources (e.g., "network_sweep", "icmp")
    ReportCount  int                   // Number of reports
}
```

**ServerConfig**:

Add cache configuration:
```go
type ServerConfig struct {
    AgentID            string                 `json:"agent_id"`
    AgentName          string                 `json:"agent_name,omitempty"`
    ListenAddr         string                 `json:"listen_addr"`
    Security           *models.SecurityConfig `json:"security"`
    KVAddress          string                 `json:"kv_address,omitempty"`
    KVSecurity         *models.SecurityConfig `json:"kv_security,omitempty"`
    CheckersDir        string                 `json:"checkers_dir"`
    DeviceCacheConfig  *DeviceCacheConfig     `json:"device_cache_config,omitempty"`
}

type DeviceCacheConfig struct {
    IncrementalInterval Duration `json:"incremental_interval"` // e.g., "5m"
    FullReportInterval  Duration `json:"full_report_interval"` // e.g., "1h"
    CleanupInterval     Duration `json:"cleanup_interval"`     // e.g., "1h"
    MaxAge              Duration `json:"max_age"`              // e.g., "24h"
    BatchSize           int      `json:"batch_size"`           // e.g., 1000
}
```

### 5.2 Cache Population (server.go)
**updateDeviceCache**:

Enhance to support multi-source merging and state tracking:
```go
func (s *Server) updateDeviceCache(info *models.DeviceInfo) {
    if info == nil || info.IP == "" {
        return
    }
    s.deviceCache.mu.Lock()
    defer s.deviceCache.mu.Unlock()
    key := info.IP
    now := time.Now()
    if device, exists := s.deviceCache.Devices[key]; exists {
        oldInfo := device.Info
        updateDeviceFields(&device.Info, info)
        device.LastSeen = now
        device.Sources[info.DiscoverySource] = true
        if hasSignificantChanges(oldInfo, device.Info) {
            device.Changed = true
            device.Reported = false
            device.ReportCount++
        }
    } else {
        s.deviceCache.Devices[key] = &DeviceState{
            Info:        *info,
            Reported:    false,
            Changed:     true,
            LastSeen:    now,
            FirstSeen:   now,
            Sources:     map[string]bool{info.DiscoverySource: true},
            ReportCount: 0,
        }
    }
}

func updateDeviceFields(target, source *models.DeviceInfo) {
    if source.MAC != "" {
        target.MAC = source.MAC
    }
    if source.Hostname != "" {
        target.Hostname = source.Hostname
    }
    target.Available = source.Available
    target.LastSeen = source.LastSeen
    if len(source.OpenPorts) > 0 {
        target.OpenPorts = source.OpenPorts
    }
    if source.Metadata != nil {
        if target.Metadata == nil {
            target.Metadata = make(map[string]string)
        }
        for k, v := range source.Metadata {
            target.Metadata[k] = v
        }
    }
    // Update other fields similarly
}

func hasSignificantChanges(old, new models.DeviceInfo) bool {
    return old.Available != new.Available ||
        !reflect.DeepEqual(old.OpenPorts, new.OpenPorts) ||
        old.Hostname != new.Hostname ||
        old.MAC != new.MAC
}
```

**Extraction Functions**:

Refine extraction for consistency:
```go
func extractDeviceInfoFromICMP(message, host string) *models.DeviceInfo {
    var icmpData struct {
        Host         string  `json:"host"`
        ResponseTime int64   `json:"response_time"`
        PacketLoss   float64 `json:"packet_loss"`
        Available    bool    `json:"available"`
    }
    if err := json.Unmarshal([]byte(message), &icmpData); err != nil {
        return nil
    }
    return &models.DeviceInfo{
        IP:              icmpData.Host,
        Available:       icmpData.Available,
        DiscoverySource: "icmp",
        LastSeen:        time.Now().Unix(),
        DiscoveryTime:   time.Now().Unix(),
        ResponseTime:    icmpData.ResponseTime,
        PacketLoss:      icmpData.PacketLoss,
    }
}

func extractDevicesFromSweep(message string, s *Server) {
    var sweepData struct {
        Hosts []models.HostResult `json:"hosts"`
    }
    if err := json.Unmarshal([]byte(message), &sweepData); err != nil {
        return
    }
    for _, host := range sweepData.Hosts {
        deviceInfo := &models.DeviceInfo{
            IP:              host.Host,
            Available:       host.Available,
            DiscoverySource: "network_sweep",
            OpenPorts:       host.OpenPorts,
            LastSeen:        time.Now().Unix(),
            DiscoveryTime:   time.Now().Unix(),
            Hostname:        host.Hostname,
            ResponseTime:    host.ResponseTime,
        }
        s.updateDeviceCache(deviceInfo)
    }
}

func extractDeviceInfoFromChecker(req *proto.StatusRequest, resp *proto.StatusResponse) *models.DeviceInfo {
    switch req.ServiceType {
    case "port":
        parts := strings.Split(req.Details, ":")
        if len(parts) < 1 {
            return nil
        }
        host := parts[0]
        var port int
        if len(parts) == 2 {
            port, _ = strconv.Atoi(parts[1])
        }
        return &models.DeviceInfo{
            IP:              host,
            Available:       resp.Available,
            DiscoverySource: "port_check",
            LastSeen:        time.Now().Unix(),
            DiscoveryTime:   time.Now().Unix(),
            OpenPorts:       []int{port},
            ResponseTime:    resp.ResponseTime,
        }
    case "snmp":
        return &models.DeviceInfo{
            IP:              req.Details,
            Available:       resp.Available,
            DiscoverySource: "snmp_check",
            LastSeen:        time.Now().Unix(),
            DiscoveryTime:   time.Now().Unix(),
        }
    }
    return nil
}
```

### 5.3 Cache Management (server.go)
**Cleanup Logic**:

Implement a background cleanup task:
```go
func (s *Server) SetupDeviceMaintenance(ctx context.Context) {
    ticker := time.NewTicker(s.deviceCache.CleanupInterval)
    go func() {
        defer ticker.Stop()
        for {
            select {
            case <-ctx.Done():
                return
            case <-ticker.C:
                removed := s.CleanupDeviceCache()
                if removed > 0 {
                    log.Printf("Removed %d stale devices from cache", removed)
                }
            }
        }
    }()
}

func (s *Server) CleanupDeviceCache() int {
    s.deviceCache.mu.Lock()
    defer s.deviceCache.mu.Unlock()
    now := time.Now()
    removed := 0
    for ip, device := range s.deviceCache.Devices {
        if now.Sub(device.LastSeen) > s.deviceCache.MaxAge {
            delete(s.deviceCache.Devices, ip)
            removed++
        }
    }
    return removed
}
```

**Initialization**:

Initialize DeviceCache with configuration in NewServer:
```go
func NewServer(ctx context.Context, configDir string, cfg *ServerConfig) (*Server, error) {
    s := initializeServer(configDir, cfg)
    incrementalInterval := 5 * time.Minute
    fullReportInterval := 1 * time.Hour
    cleanupInterval := 1 * time.Hour
    maxAge := 24 * time.Hour
    batchSize := 1000
    if cfg.DeviceCacheConfig != nil {
        incrementalInterval = time.Duration(cfg.DeviceCacheConfig.IncrementalInterval)
        fullReportInterval = time.Duration(cfg.DeviceCacheConfig.FullReportInterval)
        cleanupInterval = time.Duration(cfg.DeviceCacheConfig.CleanupInterval)
        maxAge = time.Duration(cfg.DeviceCacheConfig.MaxAge)
        batchSize = cfg.DeviceCacheConfig.BatchSize
    }
    s.deviceCache = DeviceCache{
        Devices:             make(map[string]*DeviceState),
        IncrementalInterval: incrementalInterval,
        FullReportInterval:  fullReportInterval,
        CleanupInterval:     cleanupInterval,
        MaxAge:              maxAge,
        BatchSize:           batchSize,
    }
    s.SetupDeviceMaintenance(ctx)
    return s, nil
}
```

### 5.4 Reporting Logic (server.go)
**New gRPC Method**:

Add GetDeviceStatus to report device data:
```go
func (s *Server) GetDeviceStatus(ctx context.Context, req *proto.DeviceStatusRequest) (*proto.DeviceStatusResponse, error) {
    devices, isFullReport := s.collectDeviceUpdates()
    batches := s.buildDeviceBatches(devices)
    var protoDevices []*proto.DeviceInfo
    for _, batch := range batches {
        protoDevices = append(protoDevices, convertToProtoDevices(batch)...)
    }
    s.markReported(devices)
    return &proto.DeviceStatusResponse{
        Devices:      protoDevices,
        IsFullReport: isFullReport,
    }, nil
}

func (s *Server) collectDeviceUpdates() ([]*models.DeviceInfo, bool) {
    s.deviceCache.mu.Lock()
    defer s.deviceCache.mu.Unlock()
    var devices []*models.DeviceInfo
    isFullReport := s.shouldSendFullReport()
    now := time.Now()
    for _, device := range s.deviceCache.Devices {
        if isFullReport || (device.Changed && !device.Reported) {
            devices = append(devices, &device.Info)
        }
    }
    if isFullReport {
        s.deviceCache.LastFullReport = now
    }
    s.deviceCache.LastReport = now
    return devices, isFullReport
}

func (s *Server) shouldSendFullReport() bool {
    return s.deviceCache.LastFullReport.IsZero() ||
        time.Since(s.deviceCache.LastFullReport) >= s.deviceCache.FullReportInterval
}

func (s *Server) buildDeviceBatches(devices []*models.DeviceInfo) [][]*models.DeviceInfo {
    if s.deviceCache.BatchSize <= 0 || len(devices) <= s.deviceCache.BatchSize {
        return [][]*models.DeviceInfo{devices}
    }
    var batches [][]*models.DeviceInfo
    for i := 0; i < len(devices); i += s.deviceCache.BatchSize {
        end := i + s.deviceCache.BatchSize
        if end > len(devices) {
            end = len(devices)
        }
        batches = append(batches, devices[i:end])
    }
    return batches
}

func (s *Server) markReported(devices []*models.DeviceInfo) {
    s.deviceCache.mu.Lock()
    defer s.deviceCache.mu.Unlock()
    for _, device := range devices {
        if d, exists := s.deviceCache.Devices[device.IP]; exists {
            d.Reported = true
            d.Changed = false
        }
    }
}

func convertToProtoDevices(devices []*models.DeviceInfo) []*proto.DeviceInfo {
    protos := make([]*proto.DeviceInfo, len(devices))
    for i, d := range devices {
        protos[i] = &proto.DeviceInfo{
            Ip:              d.IP,
            Mac:             d.MAC,
            Hostname:        d.Hostname,
            Available:       d.Available,
            LastSeen:        d.LastSeen,
            DiscoverySource: d.DiscoverySource,
            DiscoveryTime:   d.DiscoveryTime,
            OpenPorts:       convertPorts(d.OpenPorts),
            NetworkSegment:  d.NetworkSegment,
            ServiceType:     d.ServiceType,
            ServiceName:     d.ServiceName,
            ResponseTime:    d.ResponseTime,
            PacketLoss:      d.PacketLoss,
            DeviceType:      d.DeviceType,
            Vendor:          d.Vendor,
            Model:           d.Model,
            OsInfo:          d.OSInfo,
            Metadata:        d.Metadata,
        }
    }
    return protos
}

func convertPorts(ports []int) []int32 {
    result := make([]int32, len(ports))
    for i, p := range ports {
        result[i] = int32(p)
    }
    return result
}
```

**Protocol Definition (proto/serviceradar.proto)**:

Add new messages and RPC:
```protobuf
message DeviceStatusRequest {
    string agent_id = 1;
}

message DeviceStatusResponse {
    repeated DeviceInfo devices = 1;
    bool is_full_report = 2;
}

message DeviceInfo {
    string ip = 1;
    string mac = 2;
    string hostname = 3;
    bool available = 4;
    int64 last_seen = 5;
    string discovery_source = 6;
    int64 discovery_time = 7;
    repeated int32 open_ports = 8;
    string network_segment = 9;
    string service_type = 10;
    string service_name = 11;
    int64 response_time = 12;
    double packet_loss = 13;
    string device_type = 14;
    string vendor = 15;
    string model = 16;
    string os_info = 17;
    map<string, string> metadata = 18;
}

service AgentService {
    rpc GetStatus(StatusRequest) returns (StatusResponse);
    rpc GetDeviceStatus(DeviceStatusRequest) returns (DeviceStatusResponse);
}
```

### 5.5 Service Integration (sweep_service.go, etc.)
**SweepService**:

Ensure OpenPorts is reliably populated:
```go
func (s *SweepService) GetStatus(ctx context.Context) (*proto.StatusResponse, error) {
    summary, err := s.sweeper.GetStatus(ctx)
    if err != nil {
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
    }{
        Network:        strings.Join(s.config.Networks, ","),
        TotalHosts:     summary.TotalHosts,
        AvailableHosts: summary.AvailableHosts,
        LastSweep:      summary.LastSweep,
        Ports:          summary.Ports,
        Hosts:          summary.Hosts,
        DefinedCIDRs:   len(s.config.Networks),
        UniqueIPs:      s.stats.uniqueIPs,
    }
    s.mu.RUnlock()
    for _, host := range data.Hosts {
        if host.Available && len(host.OpenPorts) == 0 {
            log.Printf("Warning: Host %s is available but has no open ports", host.Host)
        }
    }
    statusJSON, err := json.Marshal(data)
    if err != nil {
        return nil, fmt.Errorf("failed to marshal sweep status: %w", err)
    }
    return &proto.StatusResponse{
        Available:    true,
        Message:      string(statusJSON),
        ServiceName:  "network_sweep",
        ServiceType:  "sweep",
        ResponseTime: time.Since(time.Unix(summary.LastSweep, 0)).Nanoseconds(),
    }, nil
}
```

**Other Checkers**:

Ensure ICMP, port, and SNMP checkers produce consistent DeviceInfo fields, validated in their respective Check methods.

### 5.6 Poller Integration (pkg/poller/poller.go)

Update pollAgent to call GetDeviceStatus:
```go
func (p *Poller) pollAgent(ctx context.Context, agentName string, agentConfig *AgentConfig) ([]*proto.ServiceStatus, []*proto.DeviceInfo, error) {
    agent, err := p.getAgentConnection(agentName)
    if err != nil {
        return nil, nil, err
    }
    if err := p.ensureAgentHealth(ctx, agentName, agentConfig, agent); err != nil {
        return nil, nil, err
    }
    client := proto.NewAgentServiceClient(agent.client.GetConnection())
    poller := newAgentPoller(agentName, agentConfig, client, defaultTimeout)
    statuses := poller.ExecuteChecks(ctx)
    deviceResp, err := client.GetDeviceStatus(ctx, &proto.DeviceStatusRequest{AgentId: agentName})
    if err != nil {
        log.Printf("Failed to get device status from agent %s: %v", agentName, err)
        return statuses, nil, nil
    }
    return statuses, deviceResp.Devices, nil
}
```

Update reportToCore to include devices:
```go
func (p *Poller) reportToCore(ctx context.Context, statuses []*proto.ServiceStatus, devices []*proto.DeviceInfo, isFullReport bool) error {
    _, err := p.coreClient.ReportStatus(ctx, &proto.PollerStatusRequest{
        Services:     statuses,
        PollerId:     p.config.PollerID,
        Timestamp:    time.Now().Unix(),
        Devices:      devices,
        IsFullReport: isFullReport,
    })
    if err != nil {
        return fmt.Errorf("failed to report status to core: %w", err)
    }
    return nil
}
```

Update PollerStatusRequest in proto/serviceradar.proto:
```protobuf
message PollerStatusRequest {
    repeated ServiceStatus services = 1;
    string poller_id = 2;
    int64 timestamp = 3;
    repeated DeviceInfo devices = 4;
    bool is_full_report = 5;
}
```

## 6. Implementation Phases

### Phase 1: Core Cache Infrastructure (1 week):
- Update types.go with enhanced DeviceCache, DeviceState, and ServerConfig.
- Initialize DeviceCache in server.go with configuration.
- Define GetDeviceStatus and DeviceInfo in proto/serviceradar.proto.

### Phase 2: Device Extraction and Cache Population (1 week):
- Enhance updateDeviceCache and extraction functions in server.go.
- Validate OpenPorts in sweep_service.go.

### Phase 3: Reporting and Poller Integration (1 week):
- Implement GetDeviceStatus and reporting logic in server.go.
- Update poller's pollAgent and reportToCore in poller.go.

### Phase 4: Testing and Optimization (1 week):
- Add unit tests for cache and reporting logic in server_test.go.
- Test with 10,000+ devices to validate scalability.
- Optimize batching and locking if needed.

## 7. Success Metrics
- Agent caches device data from all edge services accurately.
- Incremental reports send only changed devices, reducing network load.
- Full reports occur at configured intervals, ensuring consistency.
- Device data reaches the core within 5 minutes of discovery.
- System handles 10,000+ devices without performance degradation.
- OpenPorts field is consistently populated.

## 8. Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Large cache size impacts memory usage. | Implement cleanup with configurable MaxAge and monitor memory usage. |
| Frequent GetDeviceStatus calls overload the agent. | Use batching and configurable intervals; monitor call frequency. |
| Race conditions in cache access. | Ensure thread-safe operations with sync.RWMutex. |
| Protocol changes disrupt existing functionality. | Phase protocol updates and test thoroughly. |

## 9. Open Questions
- Should the poller control full syncs via a flag in DeviceStatusRequest?
- Is a maximum cache size limit necessary, or is MaxAge sufficient?
- How should errors in GetDeviceStatus be handled and reported?

## 10. Testing Plan

### Unit Tests:
- Test updateDeviceCache for merging and state tracking.
- Test collectDeviceUpdates for incremental and full reports.
- Test extraction functions for consistency.

### Integration Tests:
- Test agent-poller communication for device data transfer.
- Simulate large device counts and full syncs.

### System Tests:
- End-to-end test from edge to core.
- Performance test with 10,000+ devices.
- Failure recovery test for agent restarts.

## 11. Conclusion
This PRD provides a robust and scalable plan for implementing device caching and reporting in the serviceradar-agent. By using a dedicated GetDeviceStatus RPC, it avoids performance issues with GetStatus, ensuring efficient handling of large device networks. The phased approach and comprehensive testing plan ensure a reliable implementation, meeting the Device Management System's requirements.

### Next Steps:
- Validate protocol changes with poller and core teams.
- Develop detailed function signatures and test cases.
- Proceed with Phase 1 implementation after stakeholder approval.