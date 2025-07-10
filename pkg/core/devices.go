package core

import (
	"context"
	"fmt"
	"github.com/carverauto/serviceradar/pkg/models"
	"log"
	"time"
)

func (s *Server) createSysmonDeviceRecord(
	ctx context.Context,
	agentID, pollerID, partition, deviceID string, payload *sysmonPayload, pollerTimestamp time.Time) {
	if payload.Status.HostIP == "" || payload.Status.HostIP == "unknown" {
		return
	}

	sweepResult := &models.SweepResult{
		AgentID:         agentID,
		PollerID:        pollerID,
		Partition:       partition,
		DeviceID:        deviceID,
		DiscoverySource: "sysmon",
		IP:              payload.Status.HostIP,
		Hostname:        &payload.Status.HostID,
		Timestamp:       pollerTimestamp,
		Available:       true,
		Metadata: map[string]string{
			"source":      "sysmon",
			"last_update": pollerTimestamp.Format(time.RFC3339),
		},
	}

	log.Printf("Created/updated device record for sysmon device %s (hostname: %s, ip: %s)",
		deviceID, payload.Status.HostID, payload.Status.HostIP)

	// Also process through device registry for unified device management
	if s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessSweepResult(ctx, sweepResult); err != nil {
			log.Printf("Warning: Failed to process sysmon device through device registry for %s: %v", deviceID, err)
		}
	}
}

// createSNMPTargetDeviceRecord creates a device record for an SNMP target device.
// This ensures SNMP targets appear in the unified devices view and can be merged with other discovery sources.
func (s *Server) createSNMPTargetDeviceRecord(
	ctx context.Context,
	agentID, pollerID, partition, targetIP, hostname, sourceIP string, timestamp time.Time, available bool) {
	if targetIP == "" {
		log.Printf("Warning: Cannot create SNMP target device record; target IP is missing.")
		return
	}

	log.Printf("Creating SNMP target device record for IP %s (hostname: %s, source IP: %s)", targetIP, hostname, sourceIP)
	deviceID := fmt.Sprintf("%s:%s", partition, targetIP)
	log.Printf("Using device ID %s for SNMP target", deviceID)

	sweepResult := &models.SweepResult{
		AgentID:         agentID,
		PollerID:        pollerID,
		Partition:       partition,
		DiscoverySource: "snmp", // Will merge with other discovery sources in unified_devices
		IP:              targetIP,
		DeviceID:        deviceID,
		Hostname:        &hostname,
		Timestamp:       timestamp,
		Available:       available,
		Metadata: map[string]string{
			"source":          "snmp-target",
			"snmp_monitoring": "active",
			"last_poll":       timestamp.Format(time.RFC3339),
		},
	}
	{
		deviceID := fmt.Sprintf("%s:%s", partition, targetIP)
		log.Printf("Created/updated device record for SNMP target %s (hostname: %s, ip: %s)",
			deviceID, hostname, targetIP)
	}

	// Process through the new device registry
	if s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessSighting(ctx, sweepResult); err != nil {
			log.Printf("Warning: Failed to process SNMP target device sighting for %s: %v", targetIP, err)
		}
	}
}
