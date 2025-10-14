package sysmonvm

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/shirou/gopsutil/v3/cpu"

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
			UsagePercent: usage,
			FrequencyHz:  core.FrequencyHz,
			Label:        core.Label,
			Cluster:      core.Cluster,
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
	payload.Status.Memory = models.MemoryMetric{}
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
