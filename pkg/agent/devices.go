package agent

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

// GetDeviceStatus returns the current device status from the cache.
func (s *Server) GetDeviceStatus(ctx context.Context, req *proto.DeviceStatusRequest) (*proto.DeviceStatusResponse, error) {
	devices, isFullReport := s.collectDeviceUpdates()
	batches := s.buildDeviceBatches(devices)

	var protoDevices []*proto.DeviceInfo

	for _, batch := range batches {
		protoDevices = append(protoDevices, convertToProtoDevices(batch, s.config.AgentID)...)
	}

	s.markReported(devices)

	return &proto.DeviceStatusResponse{
		Devices:      protoDevices,
		IsFullReport: isFullReport,
		AgentId:      s.config.AgentID,
	}, nil
}

// collectDeviceUpdates collects devices for reporting.
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

// shouldSendFullReport determines if a full report is due.
func (s *Server) shouldSendFullReport() bool {
	return s.deviceCache.LastFullReport.IsZero() ||
		time.Since(s.deviceCache.LastFullReport) >= s.deviceCache.FullReportInterval
}

// buildDeviceBatches splits devices into batches.
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

func convertToProtoDevices(devices []*models.DeviceInfo, agentID string) []*proto.DeviceInfo {
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
			AgentId:         agentID,
			PollerId:        "", // Poller will set this
		}
	}

	return protos
}

// convertPorts converts []int to []int32.
func convertPorts(ports []int) []int32 {
	result := make([]int32, len(ports))

	for i, p := range ports {
		result[i] = int32(p)
	}

	return result
}
