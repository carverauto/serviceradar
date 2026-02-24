package models

import (
	"strings"
	"time"
)

const defaultServicePartition = "default"

// CreateCheckerDeviceUpdate creates a DeviceUpdate for a checker to register itself as a device
func CreateCheckerDeviceUpdate(checkerID, checkerKind, agentID, gatewayID, hostIP, partition string, metadata map[string]string) *DeviceUpdate {
	serviceType := ServiceTypeChecker

	if metadata == nil {
		metadata = make(map[string]string)
	}

	normalizedPartition := strings.TrimSpace(partition)
	if normalizedPartition == "" {
		normalizedPartition = defaultServicePartition
	}

	// Add checker-specific metadata
	metadata["component_type"] = "checker"
	metadata["checker_id"] = checkerID
	metadata["checker_kind"] = checkerKind
	metadata["agent_id"] = agentID
	metadata["gateway_id"] = gatewayID

	// Generate service-aware device ID
	deviceID := GenerateServiceDeviceID(serviceType, checkerID)

	return &DeviceUpdate{
		DeviceID:    deviceID,
		ServiceType: &serviceType,
		ServiceID:   checkerID,
		IP:          hostIP,
		Source:      DiscoverySourceServiceRadar,
		AgentID:     agentID,
		GatewayID:    gatewayID,
		Partition:   normalizedPartition,
		Timestamp:   time.Now(),
		Metadata:    metadata,
		IsAvailable: true,
		Confidence:  ConfidenceHighSelfReported,
	}
}

// CreateCoreServiceDeviceUpdate creates a DeviceUpdate for a core service (datasvc, sync, mapper, otel, zen, core)
// to register itself as a device with a stable service device ID that survives IP changes.
func CreateCoreServiceDeviceUpdate(serviceType ServiceType, serviceID, hostIP, partition string, metadata map[string]string) *DeviceUpdate {
	if metadata == nil {
		metadata = make(map[string]string)
	}

	normalizedPartition := strings.TrimSpace(partition)
	if normalizedPartition == "" {
		normalizedPartition = defaultServicePartition
	}

	// Add core service metadata
	metadata["component_type"] = string(serviceType)
	metadata["service_id"] = serviceID

	// Generate service-aware device ID (e.g., serviceradar:datasvc:instance-name)
	deviceID := GenerateServiceDeviceID(serviceType, serviceID)

	return &DeviceUpdate{
		DeviceID:    deviceID,
		ServiceType: &serviceType,
		ServiceID:   serviceID,
		IP:          hostIP,
		Source:      DiscoverySourceServiceRadar,
		Partition:   normalizedPartition,
		Timestamp:   time.Now(),
		Metadata:    metadata,
		IsAvailable: true,
		Confidence:  ConfidenceHighSelfReported,
	}
}
