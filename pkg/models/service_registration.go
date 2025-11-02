package models

import (
	"time"
)

// CreatePollerDeviceUpdate creates a DeviceUpdate for a poller to register itself as a device
func CreatePollerDeviceUpdate(pollerID, hostIP string, metadata map[string]string) *DeviceUpdate {
	serviceType := ServiceTypePoller

	if metadata == nil {
		metadata = make(map[string]string)
	}

	// Add poller-specific metadata
	metadata["component_type"] = "poller"
	metadata["poller_id"] = pollerID

	return &DeviceUpdate{
		ServiceType: &serviceType,
		ServiceID:   pollerID,
		IP:          hostIP,
		Source:      DiscoverySourceServiceRadar,
		PollerID:    pollerID,
		Partition:   ServiceDevicePartition,
		Timestamp:   time.Now(),
		Metadata:    metadata,
		IsAvailable: true,
		Confidence:  ConfidenceHighSelfReported,
	}
}

// CreateAgentDeviceUpdate creates a DeviceUpdate for an agent to register itself as a device
func CreateAgentDeviceUpdate(agentID, pollerID, hostIP string, metadata map[string]string) *DeviceUpdate {
	serviceType := ServiceTypeAgent

	if metadata == nil {
		metadata = make(map[string]string)
	}

	// Add agent-specific metadata
	metadata["component_type"] = "agent"
	metadata["agent_id"] = agentID
	metadata["poller_id"] = pollerID

	return &DeviceUpdate{
		ServiceType: &serviceType,
		ServiceID:   agentID,
		IP:          hostIP,
		Source:      DiscoverySourceServiceRadar,
		AgentID:     agentID,
		PollerID:    pollerID,
		Partition:   ServiceDevicePartition,
		Timestamp:   time.Now(),
		Metadata:    metadata,
		IsAvailable: true,
		Confidence:  ConfidenceHighSelfReported,
	}
}

// CreateCheckerDeviceUpdate creates a DeviceUpdate for a checker to register itself as a device
func CreateCheckerDeviceUpdate(checkerID, checkerKind, agentID, pollerID, hostIP string, metadata map[string]string) *DeviceUpdate {
	serviceType := ServiceTypeChecker

	if metadata == nil {
		metadata = make(map[string]string)
	}

	// Add checker-specific metadata
	metadata["component_type"] = "checker"
	metadata["checker_id"] = checkerID
	metadata["checker_kind"] = checkerKind
	metadata["agent_id"] = agentID
	metadata["poller_id"] = pollerID

	return &DeviceUpdate{
		ServiceType: &serviceType,
		ServiceID:   checkerID,
		IP:          hostIP,
		Source:      DiscoverySourceServiceRadar,
		AgentID:     agentID,
		PollerID:    pollerID,
		Partition:   ServiceDevicePartition,
		Timestamp:   time.Now(),
		Metadata:    metadata,
		IsAvailable: true,
		Confidence:  ConfidenceHighSelfReported,
	}
}
