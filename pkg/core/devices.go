/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package core

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (s *Server) createSysmonDeviceRecord(
	ctx context.Context,
	agentID, pollerID, partition, deviceID string, payload *sysmonPayload, pollerTimestamp time.Time) {
	if payload.Status.HostIP == "" || payload.Status.HostIP == "unknown" {
		return
	}

	deviceUpdate := &models.DeviceUpdate{
		AgentID:     agentID,
		PollerID:    pollerID,
		Partition:   partition,
		DeviceID:    deviceID,
		Source:      models.DiscoverySourceSysmon,
		IP:          payload.Status.HostIP,
		Hostname:    &payload.Status.HostID,
		Timestamp:   pollerTimestamp,
		IsAvailable: true,
		Metadata: map[string]string{
			"source":      "sysmon",
			"last_update": pollerTimestamp.Format(time.RFC3339),
		},
	}

	log.Printf("Created/updated device record for sysmon device %s (hostname: %s, ip: %s)",
		deviceID, payload.Status.HostID, payload.Status.HostIP)

	// Also process through device registry for unified device management
	if s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessDeviceUpdate(ctx, deviceUpdate); err != nil {
			log.Printf("Warning: Failed to process sysmon device through device registry for %s: %v", deviceID, err)
		}
	}
}

// createSNMPTargetDeviceUpdate creates a DeviceUpdate for an SNMP target device.
// This ensures SNMP targets appear in the unified devices view and can be merged with other discovery sources.
func (s *Server) createSNMPTargetDeviceUpdate(
	agentID, pollerID, partition, targetIP, hostname string, timestamp time.Time, available bool) *models.DeviceUpdate {
	if targetIP == "" {
		log.Printf("Warning: Cannot create SNMP target device record; target IP is missing.")
		return nil
	}

	deviceID := fmt.Sprintf("%s:%s", partition, targetIP)
	log.Printf("Creating SNMP target device update for IP %s (hostname: %s, device_id: %s)", targetIP, hostname, deviceID)

	return &models.DeviceUpdate{
		AgentID:     agentID,
		PollerID:    pollerID,
		Partition:   partition,
		Source:      models.DiscoverySourceSNMP,
		IP:          targetIP,
		DeviceID:    deviceID,
		Hostname:    &hostname,
		Timestamp:   timestamp,
		IsAvailable: available,
		Metadata: map[string]string{
			"source":          "snmp-target",
			"snmp_monitoring": "active",
			"last_poll":       timestamp.Format(time.RFC3339),
		},
	}
}

// createSNMPTargetDeviceRecord creates a device record for an SNMP target device.
// This ensures SNMP targets appear in the unified devices view and can be merged with other discovery sources.
// Deprecated: Use createSNMPTargetDeviceUpdate and batch processing instead.
func (s *Server) createSNMPTargetDeviceRecord(
	ctx context.Context,
	agentID, pollerID, partition, targetIP, hostname, sourceIP string, timestamp time.Time, available bool) {
	deviceUpdate := s.createSNMPTargetDeviceUpdate(agentID, pollerID, partition, targetIP, hostname, timestamp, available)
	if deviceUpdate == nil {
		return
	}

	// Process through the new device registry
	if s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessDeviceUpdate(ctx, deviceUpdate); err != nil {
			log.Printf("Warning: Failed to process SNMP target device sighting for %s: %v", targetIP, err)
		}
	}
}
