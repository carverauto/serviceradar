package sysmonvm

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/mem"

	"github.com/carverauto/serviceradar/pkg/cpufreq"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errCollectFrequency = errors.New("failed to collect cpu frequency data")
)

// Service implements the monitoring.AgentService gRPC interface for VM-oriented sysmon metrics.
type Service struct {
	proto.UnimplementedAgentServiceServer
	log             logger.Logger
	sampleInterval  time.Duration
	freqCollector   func(context.Context) (*cpufreq.Snapshot, error)
	usageCollector  func(context.Context, time.Duration, bool) ([]float64, error)
	hostIdentifier  func() string
	localIPResolver func(context.Context) string
	sequence        atomic.Uint64 // monotonically increasing sequence for GetResults
}

func NewService(log logger.Logger, sampleInterval time.Duration) *Service {
	return &Service{
		log:             log,
		sampleInterval:  sampleInterval,
		freqCollector:   cpufreq.NewCollector(sampleInterval),
		usageCollector:  cpu.PercentWithContext,
		hostIdentifier:  hostIdentifier,
		localIPResolver: localIP,
	}
}

func (s *Service) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	start := time.Now()

	s.log.Debug().
		Str("service_name", req.GetServiceName()).
		Str("service_type", req.GetServiceType()).
		Str("agent_id", req.GetAgentId()).
		Str("poller_id", req.GetPollerId()).
		Msg("Received sysmon-vm GetStatus request")

	freqSnapshot, err := s.freqCollector(ctx)
	if err != nil {
		s.log.Warn().Err(err).Msg("cpufreq collection failed")
		return s.failureResponse(req, start, errors.Join(errCollectFrequency, err)), nil
	}

	usagePercent := s.collectUsage(ctx, len(freqSnapshot.Cores))
	hostID := s.hostIdentifier()
	hostIP := s.localIPResolver(ctx)

	cpus := make([]models.CPUMetric, 0, len(freqSnapshot.Cores))
	now := time.Now().UTC()
	agentID := req.GetAgentId()

	for _, core := range freqSnapshot.Cores {
		usage := 0.0
		if core.CoreID >= 0 && core.CoreID < len(usagePercent) {
			usage = usagePercent[core.CoreID]
		}

		cpus = append(cpus, models.CPUMetric{
			CoreID:       int32(core.CoreID),
			Label:        core.Label,
			Cluster:      core.Cluster,
			UsagePercent: usage,
			FrequencyHz:  core.FrequencyHz,
			Timestamp:    now,
			HostID:       hostID,
			HostIP:       hostIP,
			AgentID:      agentID,
		})
	}

	clusterMetrics := make([]models.CPUClusterMetric, 0, len(freqSnapshot.Clusters))
	for _, cluster := range freqSnapshot.Clusters {
		clusterMetrics = append(clusterMetrics, models.CPUClusterMetric{
			Name:        cluster.Name,
			FrequencyHz: cluster.FrequencyHz,
			Timestamp:   now,
			HostID:      hostID,
			HostIP:      hostIP,
			AgentID:     agentID,
		})
	}

	memMetric := models.MemoryMetric{
		Timestamp: now,
		HostID:    hostID,
		HostIP:    hostIP,
		AgentID:   agentID,
	}

	if vmStats, err := mem.VirtualMemoryWithContext(ctx); err != nil {
		s.log.Warn().Err(err).Msg("memory collection failed; reporting zeroes")
	} else {
		memMetric.TotalBytes = vmStats.Total
		memMetric.UsedBytes = vmStats.Used
	}

	payload := struct {
		Available    bool  `json:"available"`
		ResponseTime int64 `json:"response_time"`
		Status       struct {
			Timestamp string                    `json:"timestamp"`
			HostID    string                    `json:"host_id"`
			HostIP    string                    `json:"host_ip"`
			CPUs      []models.CPUMetric        `json:"cpus"`
			Clusters  []models.CPUClusterMetric `json:"clusters,omitempty"`
			Disks     []models.DiskMetric       `json:"disks"`
			Memory    models.MemoryMetric       `json:"memory"`
			Processes []models.ProcessMetric    `json:"processes"`
		} `json:"status"`
	}{
		Available:    true,
		ResponseTime: time.Since(start).Nanoseconds(),
	}

	payload.Status.Timestamp = time.Now().UTC().Format(time.RFC3339Nano)
	payload.Status.HostID = hostID
	payload.Status.HostIP = hostIP
	payload.Status.CPUs = cpus
	payload.Status.Clusters = clusterMetrics
	payload.Status.Disks = []models.DiskMetric{}
	payload.Status.Memory = memMetric
	payload.Status.Processes = []models.ProcessMetric{}

	messageBytes, err := json.Marshal(payload)
	if err != nil {
		s.log.Error().Err(err).Msg("failed to marshal sysmon-vm payload")
		return s.failureResponse(req, start, fmt.Errorf("serialization error: %w", err)), nil
	}

	respTime := time.Since(start).Nanoseconds()
	s.log.Debug().
		Int("cpu_count", len(cpus)).
		Str("host_id", hostID).
		Str("host_ip", hostIP).
		Int64("response_time_ns", respTime).
		Msg("sysmon-vm GetStatus returning success")

	return &proto.StatusResponse{
		Available:    true,
		Message:      messageBytes,
		ServiceName:  req.GetServiceName(),
		ServiceType:  req.GetServiceType(),
		ResponseTime: respTime,
	}, nil
}

// GetResults implements the monitoring.AgentService GetResults RPC.
// It collects the same sysmon metrics as GetStatus but returns a ResultsResponse.
func (s *Service) GetResults(ctx context.Context, req *proto.ResultsRequest) (*proto.ResultsResponse, error) {
	start := time.Now()

	s.log.Debug().
		Str("service_name", req.GetServiceName()).
		Str("service_type", req.GetServiceType()).
		Str("agent_id", req.GetAgentId()).
		Str("poller_id", req.GetPollerId()).
		Str("last_sequence", req.GetLastSequence()).
		Msg("Received sysmon-vm GetResults request")

	freqSnapshot, err := s.freqCollector(ctx)
	if err != nil {
		s.log.Warn().Err(err).Msg("cpufreq collection failed")
		return s.failureResultsResponse(req, start, errors.Join(errCollectFrequency, err)), nil
	}

	usagePercent := s.collectUsage(ctx, len(freqSnapshot.Cores))
	hostID := s.hostIdentifier()
	hostIP := s.localIPResolver(ctx)

	cpus := make([]models.CPUMetric, 0, len(freqSnapshot.Cores))
	now := time.Now().UTC()
	agentID := req.GetAgentId()

	for _, core := range freqSnapshot.Cores {
		usage := 0.0
		if core.CoreID >= 0 && core.CoreID < len(usagePercent) {
			usage = usagePercent[core.CoreID]
		}

		cpus = append(cpus, models.CPUMetric{
			CoreID:       int32(core.CoreID),
			Label:        core.Label,
			Cluster:      core.Cluster,
			UsagePercent: usage,
			FrequencyHz:  core.FrequencyHz,
			Timestamp:    now,
			HostID:       hostID,
			HostIP:       hostIP,
			AgentID:      agentID,
		})
	}

	clusterMetrics := make([]models.CPUClusterMetric, 0, len(freqSnapshot.Clusters))
	for _, cluster := range freqSnapshot.Clusters {
		clusterMetrics = append(clusterMetrics, models.CPUClusterMetric{
			Name:        cluster.Name,
			FrequencyHz: cluster.FrequencyHz,
			Timestamp:   now,
			HostID:      hostID,
			HostIP:      hostIP,
			AgentID:     agentID,
		})
	}

	memMetric := models.MemoryMetric{
		Timestamp: now,
		HostID:    hostID,
		HostIP:    hostIP,
		AgentID:   agentID,
	}

	if vmStats, err := mem.VirtualMemoryWithContext(ctx); err != nil {
		s.log.Warn().Err(err).Msg("memory collection failed; reporting zeroes")
	} else {
		memMetric.TotalBytes = vmStats.Total
		memMetric.UsedBytes = vmStats.Used
	}

	payload := struct {
		Available    bool  `json:"available"`
		ResponseTime int64 `json:"response_time"`
		Status       struct {
			Timestamp string                    `json:"timestamp"`
			HostID    string                    `json:"host_id"`
			HostIP    string                    `json:"host_ip"`
			CPUs      []models.CPUMetric        `json:"cpus"`
			Clusters  []models.CPUClusterMetric `json:"clusters,omitempty"`
			Disks     []models.DiskMetric       `json:"disks"`
			Memory    models.MemoryMetric       `json:"memory"`
			Processes []models.ProcessMetric    `json:"processes"`
		} `json:"status"`
	}{
		Available:    true,
		ResponseTime: time.Since(start).Nanoseconds(),
	}

	payload.Status.Timestamp = now.Format(time.RFC3339Nano)
	payload.Status.HostID = hostID
	payload.Status.HostIP = hostIP
	payload.Status.CPUs = cpus
	payload.Status.Clusters = clusterMetrics
	payload.Status.Disks = []models.DiskMetric{}
	payload.Status.Memory = memMetric
	payload.Status.Processes = []models.ProcessMetric{}

	dataBytes, err := json.Marshal(payload)
	if err != nil {
		s.log.Error().Err(err).Msg("failed to marshal sysmon-vm payload")
		return s.failureResultsResponse(req, start, fmt.Errorf("serialization error: %w", err)), nil
	}

	respTime := time.Since(start).Nanoseconds()
	currentSeq := strconv.FormatUint(s.sequence.Add(1), 10)

	s.log.Debug().
		Int("cpu_count", len(cpus)).
		Str("host_id", hostID).
		Str("host_ip", hostIP).
		Str("sequence", currentSeq).
		Int64("response_time_ns", respTime).
		Msg("sysmon-vm GetResults returning success")

	return &proto.ResultsResponse{
		Available:       true,
		Data:            dataBytes,
		ServiceName:     req.GetServiceName(),
		ServiceType:     req.GetServiceType(),
		ResponseTime:    respTime,
		AgentId:         req.GetAgentId(),
		PollerId:        req.GetPollerId(),
		Timestamp:       now.UnixNano(),
		CurrentSequence: currentSeq,
		HasNewData:      true, // sysmon always has fresh metrics
	}, nil
}

func (s *Service) failureResultsResponse(req *proto.ResultsRequest, start time.Time, err error) *proto.ResultsResponse {
	respTime := time.Since(start).Nanoseconds()

	payload := map[string]interface{}{
		"available":     false,
		"response_time": respTime,
		"error":         err.Error(),
	}

	data, marshalErr := json.Marshal(payload)
	if marshalErr != nil {
		data = []byte(fmt.Sprintf(`{"available":false,"response_time":%d,"error":"%s"}`, respTime, err.Error()))
	}

	return &proto.ResultsResponse{
		Available:       false,
		Data:            data,
		ServiceName:     req.GetServiceName(),
		ServiceType:     req.GetServiceType(),
		ResponseTime:    respTime,
		AgentId:         req.GetAgentId(),
		PollerId:        req.GetPollerId(),
		Timestamp:       time.Now().UnixNano(),
		CurrentSequence: strconv.FormatUint(s.sequence.Add(1), 10),
		HasNewData:      false,
	}
}

func (s *Service) failureResponse(req *proto.StatusRequest, start time.Time, err error) *proto.StatusResponse {
	respTime := time.Since(start).Nanoseconds()

	payload := map[string]interface{}{
		"available":     false,
		"response_time": respTime,
		"error":         err.Error(),
	}

	message, marshalErr := json.Marshal(payload)
	if marshalErr != nil {
		message = []byte(fmt.Sprintf(`{"available":false,"response_time":%d,"error":"%s"}`, respTime, err.Error()))
	}

	return &proto.StatusResponse{
		Available:    false,
		Message:      message,
		ServiceName:  req.GetServiceName(),
		ServiceType:  req.GetServiceType(),
		ResponseTime: respTime,
	}
}

func (s *Service) collectUsage(ctx context.Context, cpuCount int) []float64 {
	if cpuCount <= 0 {
		return nil
	}

	percent, err := s.usageCollector(ctx, s.sampleInterval, true)
	if err != nil {
		s.log.Warn().Err(err).Msg("cpu.PercentWithContext failed; usage will be zero")
		return make([]float64, cpuCount)
	}

	// Ensure slice length matches cpuCount to align with freq snapshot.
	if len(percent) < cpuCount {
		out := make([]float64, cpuCount)
		copy(out, percent)
		return out
	}

	return percent
}

func hostIdentifier() string {
	if hostname, err := os.Hostname(); err == nil && hostname != "" {
		return hostname
	}

	return "unknown-host"
}

func localIP(ctx context.Context) string {
	// Prefer a stable, non-docker, non-loopback IPv4 before falling back to a dial trick.
	if ip := firstUsableIPv4(); ip != "" {
		return ip
	}

	dialer := &net.Dialer{
		Timeout: time.Second,
	}

	conn, err := dialer.DialContext(ctx, "udp", "8.8.8.8:80")
	if err != nil {
		return "unknown"
	}
	defer func() {
		_ = conn.Close()
	}()

	localAddr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return "unknown"
	}

	return localAddr.IP.String()
}

func firstUsableIPv4() string {
	dockerCIDRs := []net.IPNet{
		{IP: net.IPv4(172, 17, 0, 0), Mask: net.CIDRMask(16, 32)},
		{IP: net.IPv4(172, 18, 0, 0), Mask: net.CIDRMask(16, 32)},
		{IP: net.IPv4(172, 19, 0, 0), Mask: net.CIDRMask(16, 32)},
	}

	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		name := strings.ToLower(iface.Name)
		if strings.HasPrefix(name, "docker") || strings.HasPrefix(name, "br-") || strings.HasPrefix(name, "veth") {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet == nil {
				continue
			}
			ip := ipNet.IP.To4()
			if ip == nil || !ip.IsGlobalUnicast() {
				continue
			}
			skip := false
			for _, cidr := range dockerCIDRs {
				if cidr.Contains(ip) {
					skip = true
					break
				}
			}
			if skip {
				continue
			}
			return ip.String()
		}
	}

	return ""
}
