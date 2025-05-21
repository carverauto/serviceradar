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
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
)

// ProtonPublisher implements the Publisher interface using Proton streams
type ProtonPublisher struct {
	dbService db.Service
	config    *StreamConfig
}

// NewProtonPublisher creates a new Proton publisher
func NewProtonPublisher(dbService db.Service, config *StreamConfig) (Publisher, error) {
	if dbService == nil {
		return nil, ErrDatabaseServiceRequired
	}

	return &ProtonPublisher{
		dbService: dbService,
		config:    config,
	}, nil
}

// PublishDevice publishes a discovered device to the sweep_results stream
func (p *ProtonPublisher) PublishDevice(ctx context.Context, device *DiscoveredDevice) error {
	// Convert to SweepResult model
	metadata := make(map[string]string)

	// Add base device metadata
	metadata["sys_descr"] = device.SysDescr
	metadata["sys_object_id"] = device.SysObjectID
	metadata["sys_contact"] = device.SysContact
	metadata["sys_location"] = device.SysLocation
	metadata["uptime"] = fmt.Sprintf("%d", device.Uptime)

	// Add any additional metadata
	for k, v := range device.Metadata {
		metadata[k] = v
	}

	// Create sweep result
	result := &models.SweepResult{
		AgentID:         p.config.AgentID,
		PollerID:        p.config.PollerID,
		DiscoverySource: "snmp_discovery",
		IP:              device.IP,
		MAC:             &device.MAC,
		Hostname:        &device.Hostname,
		Timestamp:       time.Now(),
		Available:       true,
		Metadata:        metadata,
	}

	// Publish to Proton using the existing db.Service method
	results := []*models.SweepResult{result}
	if err := p.dbService.StoreSweepResults(ctx, results); err != nil {
		return fmt.Errorf("failed to publish device to sweep_results: %w", err)
	}

	log.Printf("Published device %s (%s) to sweep_results stream", device.IP, device.Hostname)

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

	log.Printf("Published interface %s (%d) for device %s to discovered_interfaces stream",
		iface.IfName, iface.IfIndex, iface.DeviceIP)

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

	log.Printf("Published topology link between %s:%s and %s:%s to topology_discovery_events stream",
		link.LocalDeviceIP, link.LocalIfName, link.NeighborSystemName, link.NeighborPortID)

	return nil
}

// PublishBatchDevices publishes multiple devices in a batch
func (p *ProtonPublisher) PublishBatchDevices(ctx context.Context, devices []*DiscoveredDevice) error {
	if len(devices) == 0 {
		return nil
	}

	// Convert all devices to sweep results
	results := make([]*models.SweepResult, len(devices))

	for i, device := range devices {
		// Create metadata
		metadata := make(map[string]string)
		metadata["sys_descr"] = device.SysDescr
		metadata["sys_object_id"] = device.SysObjectID
		metadata["sys_contact"] = device.SysContact
		metadata["sys_location"] = device.SysLocation
		metadata["uptime"] = fmt.Sprintf("%d", device.Uptime)

		// Add custom metadata
		for k, v := range device.Metadata {
			metadata[k] = v
		}

		// Create sweep result
		hostname := device.Hostname
		mac := device.MAC

		results[i] = &models.SweepResult{
			AgentID:         p.config.AgentID,
			PollerID:        p.config.PollerID,
			DiscoverySource: "snmp_discovery",
			IP:              device.IP,
			MAC:             &mac,
			Hostname:        &hostname,
			Timestamp:       time.Now(),
			Available:       true,
			Metadata:        metadata,
		}
	}

	// Use the existing DB service method to store the batch
	if err := p.dbService.StoreSweepResults(ctx, results); err != nil {
		return fmt.Errorf("failed to publish batch devices: %w", err)
	}

	log.Printf("Published batch of %d devices to sweep_results stream", len(devices))

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
