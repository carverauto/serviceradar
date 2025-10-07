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

package mapper

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
)

// ProtonPublisher implements the Publisher interface using the device registry for devices
// and direct database access for interfaces and topology (until registry supports them)
type ProtonPublisher struct {
	deviceRegistry registry.Manager
	dbService      db.Service // TODO: Remove when registry handles interfaces/topology
	config         *StreamConfig
}

// NewProtonPublisher creates a new Proton publisher
func NewProtonPublisher(deviceRegistry registry.Manager, dbService db.Service, config *StreamConfig) (Publisher, error) {
	if deviceRegistry == nil {
		return nil, ErrDeviceRegistryRequired
	}

	if dbService == nil {
		return nil, ErrDatabaseServiceRequired
	}

	return &ProtonPublisher{
		deviceRegistry: deviceRegistry,
		dbService:      dbService,
		config:         config,
	}, nil
}

// convertDiscoveredDeviceToUpdate converts a DiscoveredDevice to a DeviceUpdate
func (p *ProtonPublisher) convertDiscoveredDeviceToUpdate(device *DiscoveredDevice) *models.DeviceUpdate {
	// Build metadata from device fields
	metadata := make(map[string]string)
	metadata["sys_descr"] = device.SysDescr
	metadata["sys_object_id"] = device.SysObjectID
	metadata["sys_contact"] = device.SysContact
	metadata["sys_location"] = device.SysLocation
	metadata["uptime"] = fmt.Sprintf("%d", device.Uptime)
	metadata["device_id"] = device.DeviceID

	// Add custom metadata
	for k, v := range device.Metadata {
		metadata[k] = v
	}

	// Determine discovery source from device metadata, default to Mapper
	discoverySource := models.DiscoverySourceMapper

	if source, exists := device.Metadata["source"]; exists {
		switch source {
		case "snmp":
			discoverySource = models.DiscoverySourceSNMP
		case "mapper":
			discoverySource = models.DiscoverySourceMapper
		case "integration":
			discoverySource = models.DiscoverySourceIntegration
		case "netflow":
			discoverySource = models.DiscoverySourceNetFlow
		default:
			discoverySource = models.DiscoverySourceMapper
		}
	}

	// Ensure partition is set
	partition := p.config.Partition
	if partition == "" {
		partition = "default"
	}

	// Generate device ID with partition
	deviceID := fmt.Sprintf("%s:%s", partition, device.IP)

	// Create local copies for pointer fields to ensure consistency
	hostname := device.Hostname
	mac := device.MAC

	// Create and return device update
	return &models.DeviceUpdate{
		DeviceID:    deviceID,
		IP:          device.IP,
		Source:      discoverySource,
		AgentID:     p.config.AgentID,
		PollerID:    p.config.PollerID,
		Partition:   partition,
		Timestamp:   time.Now(),
		Hostname:    &hostname,
		MAC:         &mac,
		Metadata:    metadata,
		IsAvailable: true,
		Confidence:  models.GetSourceConfidence(discoverySource),
	}
}

// PublishDevice publishes a discovered device via the device registry
func (p *ProtonPublisher) PublishDevice(ctx context.Context, device *DiscoveredDevice) error {
	update := p.convertDiscoveredDeviceToUpdate(device)

	// Publish via the device registry
	if err := p.deviceRegistry.ProcessDeviceUpdate(ctx, update); err != nil {
		return fmt.Errorf("failed to publish device via registry: %w", err)
	}

	return nil
}

// In pkg/discovery/publisher.go

// PublishInterface publishes a discovered interface to the discovered_interfaces stream
func (p *ProtonPublisher) PublishInterface(ctx context.Context, iface *DiscoveredInterface) error {
	// Convert metadata to a JSON representation
	metadata := make(map[string]string)

	if iface.Metadata != nil {
		for k, v := range iface.Metadata {
			metadata[k] = v
		}
	}

	// Add ifType to metadata if present
	if iface.IfType != 0 {
		metadata["if_type"] = fmt.Sprintf("%d", iface.IfType)
	}

	// Convert metadata to json.RawMessage
	metadataJSON, err := json.Marshal(metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	// Create discovered interface model
	discoveredInterface := &models.DiscoveredInterface{
		Timestamp:     time.Now(),
		AgentID:       p.config.AgentID,
		PollerID:      p.config.PollerID,
		DeviceIP:      iface.DeviceIP,
		DeviceID:      iface.DeviceID,
		IfIndex:       iface.IfIndex,
		IfName:        iface.IfName,
		IfDescr:       iface.IfDescr,
		IfAlias:       iface.IfAlias,
		IfSpeed:       iface.IfSpeed,
		IfPhysAddress: iface.IfPhysAddress,
		IPAddresses:   iface.IPAddresses,
		IfAdminStatus: iface.IfAdminStatus,
		IfOperStatus:  iface.IfOperStatus,
		Metadata:      metadataJSON,
	}

	// Call the DB service method directly
	if err := p.dbService.PublishDiscoveredInterface(ctx, discoveredInterface); err != nil {
		return fmt.Errorf("failed to publish interface to discovered_interfaces: %w", err)
	}

	return nil
}

// PublishTopologyLink publishes a discovered topology link to the topology_discovery_events stream
func (p *ProtonPublisher) PublishTopologyLink(ctx context.Context, link *TopologyLink) error {
	// Build metadata
	metadata := make(map[string]string)

	if link.Metadata != nil {
		for k, v := range link.Metadata {
			metadata[k] = v
		}
	}

	// Convert metadata to json.RawMessage
	metadataJSON, err := json.Marshal(metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal metadata: %w", err)
	}

	// Create topology discovery event
	topologyEvent := &models.TopologyDiscoveryEvent{
		Timestamp:              time.Now(),
		AgentID:                p.config.AgentID,
		PollerID:               p.config.PollerID,
		LocalDeviceIP:          link.LocalDeviceIP,
		LocalDeviceID:          link.LocalDeviceID,
		LocalIfIndex:           link.LocalIfIndex,
		LocalIfName:            link.LocalIfName,
		ProtocolType:           link.Protocol,
		NeighborChassisID:      link.NeighborChassisID,
		NeighborPortID:         link.NeighborPortID,
		NeighborPortDescr:      link.NeighborPortDescr,
		NeighborSystemName:     link.NeighborSystemName,
		NeighborManagementAddr: link.NeighborMgmtAddr,
		Metadata:               metadataJSON,
	}

	// Call the DB service method directly
	if err := p.dbService.PublishTopologyDiscoveryEvent(ctx, topologyEvent); err != nil {
		return fmt.Errorf("failed to publish topology link to topology_discovery_events: %w", err)
	}

	return nil
}

// PublishBatchDevices publishes multiple devices in a batch via the device registry
func (p *ProtonPublisher) PublishBatchDevices(ctx context.Context, devices []*DiscoveredDevice) error {
	if len(devices) == 0 {
		return nil
	}

	// Convert all devices to device updates using the shared helper
	updates := make([]*models.DeviceUpdate, len(devices))
	for i, device := range devices {
		updates[i] = p.convertDiscoveredDeviceToUpdate(device)
	}

	// Use the device registry batch method
	if err := p.deviceRegistry.ProcessBatchDeviceUpdates(ctx, updates); err != nil {
		return fmt.Errorf("failed to publish batch devices via registry: %w", err)
	}

	return nil
}

// PublishBatchInterfaces publishes multiple interfaces in a batch
func (p *ProtonPublisher) PublishBatchInterfaces(ctx context.Context, interfaces []*DiscoveredInterface) error {
	// Convert discovery types to models types
	modelInterfaces := make([]*models.DiscoveredInterface, len(interfaces))
	for i, iface := range interfaces {
		modelInterfaces[i] = &models.DiscoveredInterface{
			Timestamp:     time.Now(),
			AgentID:       p.config.AgentID,
			PollerID:      p.config.PollerID,
			DeviceIP:      iface.DeviceIP,
			DeviceID:      iface.DeviceID,
			IfIndex:       iface.IfIndex,
			IfName:        iface.IfName,
			IfDescr:       iface.IfDescr,
			IfAlias:       iface.IfAlias,
			IfSpeed:       iface.IfSpeed,
			IfPhysAddress: iface.IfPhysAddress,
			IPAddresses:   iface.IPAddresses,
			IfAdminStatus: iface.IfAdminStatus,
			IfOperStatus:  iface.IfOperStatus,
		}

		// Add metadata
		if iface.Metadata != nil {
			metadataJSON, err := json.Marshal(iface.Metadata)
			if err == nil {
				modelInterfaces[i].Metadata = metadataJSON
			}
		}
	}

	return p.dbService.PublishBatchDiscoveredInterfaces(ctx, modelInterfaces)
}

// PublishBatchTopologyLinks publishes multiple topology links in a batch
func (p *ProtonPublisher) PublishBatchTopologyLinks(ctx context.Context, links []*TopologyLink) error {
	// Convert discovery types to models types
	modelEvents := make([]*models.TopologyDiscoveryEvent, len(links))
	for i, link := range links {
		modelEvents[i] = &models.TopologyDiscoveryEvent{
			Timestamp:              time.Now(),
			AgentID:                p.config.AgentID,
			PollerID:               p.config.PollerID,
			LocalDeviceIP:          link.LocalDeviceIP,
			LocalDeviceID:          link.LocalDeviceID,
			LocalIfIndex:           link.LocalIfIndex,
			LocalIfName:            link.LocalIfName,
			ProtocolType:           link.Protocol,
			NeighborChassisID:      link.NeighborChassisID,
			NeighborPortID:         link.NeighborPortID,
			NeighborPortDescr:      link.NeighborPortDescr,
			NeighborSystemName:     link.NeighborSystemName,
			NeighborManagementAddr: link.NeighborMgmtAddr,
		}

		// Add metadata
		if link.Metadata != nil {
			metadataJSON, err := json.Marshal(link.Metadata)
			if err == nil {
				modelEvents[i].Metadata = metadataJSON
			}
		}
	}

	return p.dbService.PublishBatchTopologyDiscoveryEvents(ctx, modelEvents)
}
