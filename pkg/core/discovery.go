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
	"encoding/json"
	"fmt"

	"github.com/carverauto/serviceradar/proto"

	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

// processSNMPDiscoveryResults handles the data from SNMP discovery.
func (s *Server) processSNMPDiscoveryResults(
	ctx context.Context,
	reportingPollerID string,
	partition string,
	svc *proto.ServiceStatus,
	details json.RawMessage,
	timestamp time.Time,
) error {
	var payload models.SNMPDiscoveryDataPayload

	if err := json.Unmarshal(details, &payload); err != nil {
		log.Printf("Error unmarshaling SNMP discovery data for poller %s, service %s: %v. Payload: %s",
			reportingPollerID, svc.ServiceName, err, string(details))
		return fmt.Errorf("failed to parse SNMP discovery data: %w", err)
	}

	discoveryAgentID := payload.AgentID
	discoveryInitiatorPollerID := payload.PollerID

	// Fallback for discovery-specific IDs if not provided in payload
	if discoveryAgentID == "" {
		log.Printf("Warning: SNMPDiscoveryDataPayload.AgentID is empty for reportingPollerID %s. "+
			"Falling back to svc.AgentID %s.", reportingPollerID, svc.AgentId)

		discoveryAgentID = svc.AgentId
	}

	if discoveryInitiatorPollerID == "" {
		log.Printf("Warning: SNMPDiscoveryDataPayload.PollerID is empty for reportingPollerID %s. "+
			"Falling back to reportingPollerID %s.", reportingPollerID, reportingPollerID)

		discoveryInitiatorPollerID = reportingPollerID
	}

	// Process each type of discovery data
	if len(payload.Devices) > 0 {
		s.processDiscoveredDevices(ctx, payload.Devices, discoveryAgentID, discoveryInitiatorPollerID,
			partition, reportingPollerID, timestamp)
	}

	if len(payload.Interfaces) > 0 {
		s.processDiscoveredInterfaces(ctx, payload.Interfaces, discoveryAgentID, discoveryInitiatorPollerID,
			partition, reportingPollerID, timestamp)
	}

	if len(payload.Topology) > 0 {
		s.processDiscoveredTopology(ctx, payload.Topology, discoveryAgentID, discoveryInitiatorPollerID,
			partition, reportingPollerID, timestamp)
	}

	return nil
}

// processDiscoveredDevices handles processing and storing device information from SNMP discovery.
func (s *Server) processDiscoveredDevices(
	ctx context.Context,
	devices []*discoverypb.DiscoveredDevice,
	discoveryAgentID string,
	discoveryInitiatorPollerID string,
	partition string,
	reportingPollerID string,
	timestamp time.Time,
) {
	sweepResults := make([]*models.SweepResult, 0, len(devices))

	for _, protoDevice := range devices {
		if protoDevice == nil {
			continue
		}

		deviceMetadata := s.extractDeviceMetadata(protoDevice)
		hostname := protoDevice.Hostname
		mac := protoDevice.Mac

		sweepResult := &models.SweepResult{
			AgentID:         discoveryAgentID,
			PollerID:        discoveryInitiatorPollerID,
			Partition:       partition,
                        DiscoverySource: "mapper",
			IP:              protoDevice.Ip,
			MAC:             &mac,
			Hostname:        &hostname,
			Timestamp:       timestamp,
			Available:       true, // Assumed true if discovered via SNMP
			Metadata:        deviceMetadata,
		}
		sweepResults = append(sweepResults, sweepResult)
	}

	if err := s.DB.StoreSweepResults(ctx, sweepResults); err != nil {
		log.Printf("Error publishing batch discovered devices to sweep_results for poller %s: %v", reportingPollerID, err)
	}
}

// extractDeviceMetadata extracts and formats metadata from a discovered device.
func (*Server) extractDeviceMetadata(protoDevice *discoverypb.DiscoveredDevice) map[string]string {
	deviceMetadata := make(map[string]string)

	if protoDevice.Metadata != nil {
		for k, v := range protoDevice.Metadata {
			deviceMetadata[k] = v
		}
	}

	if protoDevice.SysDescr != "" {
		deviceMetadata["sys_descr"] = protoDevice.SysDescr
	}

	if protoDevice.SysObjectId != "" {
		deviceMetadata["sys_object_id"] = protoDevice.SysObjectId
	}

	if protoDevice.SysContact != "" {
		deviceMetadata["sys_contact"] = protoDevice.SysContact
	}

	if protoDevice.SysLocation != "" {
		deviceMetadata["sys_location"] = protoDevice.SysLocation
	}

	if protoDevice.Uptime != 0 {
		deviceMetadata["uptime"] = fmt.Sprintf("%d", protoDevice.Uptime)
	}

	return deviceMetadata
}

// processDiscoveredInterfaces handles processing and storing interface information from SNMP discovery.
func (s *Server) processDiscoveredInterfaces(
	ctx context.Context,
	interfaces []*discoverypb.DiscoveredInterface,
	discoveryAgentID string,
	discoveryInitiatorPollerID string,
	partition string,
	reportingPollerID string,
	timestamp time.Time,
) {
	modelInterfaces := make([]*models.DiscoveredInterface, 0, len(interfaces))

	for _, protoIface := range interfaces {
		if protoIface == nil {
			continue
		}

		deviceID := s.getOrGenerateDeviceID(protoIface, partition)
		metadataJSON := s.prepareInterfaceMetadata(protoIface)

		modelIface := &models.DiscoveredInterface{
			Timestamp:     timestamp,
			AgentID:       discoveryAgentID,
			PollerID:      discoveryInitiatorPollerID,
			DeviceIP:      protoIface.DeviceIp,
			DeviceID:      deviceID,
			IfIndex:       protoIface.IfIndex,
			IfName:        protoIface.IfName,
			IfDescr:       protoIface.IfDescr,
			IfAlias:       protoIface.IfAlias,
			IfSpeed:       protoIface.IfSpeed.GetValue(), // Unwrap the uint64 value
			IfPhysAddress: protoIface.IfPhysAddress,
			IPAddresses:   protoIface.IpAddresses,
			IfAdminStatus: protoIface.IfAdminStatus,
			IfOperStatus:  protoIface.IfOperStatus,
			Metadata:      metadataJSON,
		}

		modelInterfaces = append(modelInterfaces, modelIface)
	}

	if err := s.DB.PublishBatchDiscoveredInterfaces(ctx, modelInterfaces); err != nil {
		log.Printf("Error publishing batch discovered interfaces for poller %s: %v", reportingPollerID, err)
	}
}

// getOrGenerateDeviceID returns the device ID from the interface or generates one if not present.
func (*Server) getOrGenerateDeviceID(protoIface *discoverypb.DiscoveredInterface, partition string) string {
	deviceID := protoIface.DeviceId
	if deviceID == "" && protoIface.DeviceIp != "" {
		deviceID = fmt.Sprintf("%s:%s", partition, protoIface.DeviceIp)
	}

	return deviceID
}

// prepareInterfaceMetadata prepares the metadata JSON for an interface.
func (*Server) prepareInterfaceMetadata(protoIface *discoverypb.DiscoveredInterface) json.RawMessage {
	finalMetadataMap := make(map[string]string)

	if protoIface.Metadata != nil {
		for k, v := range protoIface.Metadata {
			finalMetadataMap[k] = v
		}
	}

	if protoIface.IfType != 0 { // Add IfType from proto if present
		finalMetadataMap["if_type"] = fmt.Sprintf("%d", protoIface.IfType)
	}

	metadataJSON, err := json.Marshal(finalMetadataMap)
	if err != nil {
		log.Printf("Error marshaling interface metadata for device %s, ifIndex %d: %v",
			protoIface.DeviceIp, protoIface.IfIndex, err)

		metadataJSON = []byte("{}")
	}

	return metadataJSON
}

// processDiscoveredTopology handles processing and storing topology information from SNMP discovery.
func (s *Server) processDiscoveredTopology(
	ctx context.Context,
	topology []*discoverypb.TopologyLink,
	discoveryAgentID string,
	discoveryInitiatorPollerID string,
	partition string,
	reportingPollerID string,
	timestamp time.Time,
) {
	modelTopologyEvents := make([]*models.TopologyDiscoveryEvent, 0, len(topology))

	for _, protoLink := range topology {
		if protoLink == nil {
			continue
		}

		localDeviceID := s.getOrGenerateLocalDeviceID(protoLink, partition)
		metadataJSON := s.prepareTopologyMetadata(protoLink)

		modelEvent := &models.TopologyDiscoveryEvent{
			Timestamp:              timestamp,
			AgentID:                discoveryAgentID,
			PollerID:               discoveryInitiatorPollerID,
			LocalDeviceIP:          protoLink.LocalDeviceIp,
			LocalDeviceID:          localDeviceID,
			LocalIfIndex:           protoLink.LocalIfIndex,
			LocalIfName:            protoLink.LocalIfName,
			ProtocolType:           protoLink.Protocol,
			NeighborChassisID:      protoLink.NeighborChassisId,
			NeighborPortID:         protoLink.NeighborPortId,
			NeighborPortDescr:      protoLink.NeighborPortDescr,
			NeighborSystemName:     protoLink.NeighborSystemName,
			NeighborManagementAddr: protoLink.NeighborMgmtAddr,
			// BGP fields are not in discoverypb.TopologyLink yet, so they will be empty/zero.
			// This is fine as the DB schema allows nulls.
			NeighborBGPRouterID: "", // Default to empty string
			NeighborIPAddress:   "", // Default to empty string
			NeighborAS:          0,  // Default to 0
			BGPSessionState:     "", // Default to empty string
			Metadata:            metadataJSON,
		}

		modelTopologyEvents = append(modelTopologyEvents, modelEvent)
	}

	if err := s.DB.PublishBatchTopologyDiscoveryEvents(ctx, modelTopologyEvents); err != nil {
		log.Printf("Error publishing batch topology discovery events for poller %s: %v", reportingPollerID, err)
	}
}

// getOrGenerateLocalDeviceID returns the local device ID from the topology link or generates one if not present.
func (*Server) getOrGenerateLocalDeviceID(protoLink *discoverypb.TopologyLink, partition string) string {
	localDeviceID := protoLink.LocalDeviceId
	if localDeviceID == "" && protoLink.LocalDeviceIp != "" {
		localDeviceID = fmt.Sprintf("%s:%s", partition, protoLink.LocalDeviceIp)
		log.Printf("Generated LocalDeviceID for link from %s: %s", protoLink.LocalDeviceIp, localDeviceID)
	}

	return localDeviceID
}

// prepareTopologyMetadata prepares the metadata JSON for a topology link.
func (*Server) prepareTopologyMetadata(protoLink *discoverypb.TopologyLink) json.RawMessage {
	metadataJSON, err := json.Marshal(protoLink.Metadata) // protoLink.Metadata is map[string]string
	if err != nil {
		log.Printf("Error marshaling topology metadata for local device %s, ifIndex %d: %v",
			protoLink.LocalDeviceIp, protoLink.LocalIfIndex, err)

		metadataJSON = []byte("{}")
	}

	return metadataJSON
}
