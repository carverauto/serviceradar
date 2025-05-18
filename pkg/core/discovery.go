package core

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	"log"
	"time"
)

// processSNMPDiscoveryResults handles the data from SNMP discovery.
func (s *Server) processSNMPDiscoveryResults(
	ctx context.Context,
	reportingPollerID string, // pollerID from the ReportStatus request, i.e., the one reporting this
	svc *proto.ServiceStatus, // The ServiceStatus message containing discovery results
	details json.RawMessage, // This is svc.Message, already parsed as json.RawMessage
	timestamp time.Time,
) error {
	var payload SNMPDiscoveryDataPayload
	if err := json.Unmarshal(details, &payload); err != nil {
		log.Printf("Error unmarshaling SNMP discovery data for poller %s, service %s: %v. Payload: %s",
			reportingPollerID, svc.ServiceName, err, string(details))
		return fmt.Errorf("failed to parse SNMP discovery data: %w", err)
	}

	discoveryAgentID := payload.AgentID
	discoveryInitiatorPollerID := payload.PollerID

	// Fallback for discovery-specific IDs if not provided in payload
	if discoveryAgentID == "" {
		log.Printf("Warning: SNMPDiscoveryDataPayload.AgentID is empty for reportingPollerID %s. Falling back to svc.AgentId %s.", reportingPollerID, svc.AgentId)
		discoveryAgentID = svc.AgentId
	}
	if discoveryInitiatorPollerID == "" {
		log.Printf("Warning: SNMPDiscoveryDataPayload.PollerID is empty for reportingPollerID %s. Falling back to reportingPollerID %s.", reportingPollerID, reportingPollerID)
		discoveryInitiatorPollerID = reportingPollerID
	}

	// Process Devices
	if len(payload.Devices) > 0 {
		sweepResults := make([]*db.SweepResult, 0, len(payload.Devices))
		for _, protoDevice := range payload.Devices {
			if protoDevice == nil {
				continue
			}

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

			hostname := protoDevice.Hostname
			mac := protoDevice.Mac

			sweepResult := &db.SweepResult{
				AgentID:         discoveryAgentID,
				PollerID:        discoveryInitiatorPollerID,
				DiscoverySource: "snmp_discovery",
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
		} else {
			log.Printf("Published %d discovered devices to sweep_results for poller %s (discovery by %s/%s)", len(sweepResults), reportingPollerID, discoveryAgentID, discoveryInitiatorPollerID)
		}
	}

	// Process Interfaces
	if len(payload.Interfaces) > 0 {
		modelInterfaces := make([]*models.DiscoveredInterface, 0, len(payload.Interfaces))
		for _, protoIface := range payload.Interfaces {
			if protoIface == nil {
				continue
			}

			deviceID := protoIface.DeviceId
			if deviceID == "" && protoIface.DeviceIp != "" {
				deviceID = fmt.Sprintf("%s:%s:%s", protoIface.DeviceIp, discoveryAgentID, discoveryInitiatorPollerID)
				log.Printf("Generated DeviceID for interface on %s: %s", protoIface.DeviceIp, deviceID)
			}

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
				log.Printf("Error marshaling interface metadata for device %s, ifIndex %d: %v", protoIface.DeviceIp, protoIface.IfIndex, err)
				metadataJSON = []byte("{}")
			}

			modelIface := &models.DiscoveredInterface{
				Timestamp:     timestamp,
				AgentID:       discoveryAgentID,
				PollerID:      discoveryInitiatorPollerID,
				DeviceIP:      protoIface.DeviceIp,
				DeviceID:      deviceID,
				IfIndex:       int(protoIface.IfIndex),
				IfName:        protoIface.IfName,
				IfDescr:       protoIface.IfDescr,
				IfAlias:       protoIface.IfAlias,
				IfSpeed:       protoIface.IfSpeed,
				IfPhysAddress: protoIface.IfPhysAddress,
				IPAddresses:   protoIface.IpAddresses,
				IfAdminStatus: int(protoIface.IfAdminStatus),
				IfOperStatus:  int(protoIface.IfOperStatus),
				Metadata:      metadataJSON,
			}
			modelInterfaces = append(modelInterfaces, modelIface)
		}
		if err := s.DB.PublishBatchDiscoveredInterfaces(ctx, modelInterfaces); err != nil {
			log.Printf("Error publishing batch discovered interfaces for poller %s: %v", reportingPollerID, err)
		} else {
			log.Printf("Published %d discovered interfaces for poller %s (discovery by %s/%s)", len(modelInterfaces), reportingPollerID, discoveryAgentID, discoveryInitiatorPollerID)
		}
	}

	// Process Topology Links
	if len(payload.Topology) > 0 {
		modelTopologyEvents := make([]*models.TopologyDiscoveryEvent, 0, len(payload.Topology))
		for _, protoLink := range payload.Topology {
			if protoLink == nil {
				continue
			}

			localDeviceID := protoLink.LocalDeviceId
			if localDeviceID == "" && protoLink.LocalDeviceIp != "" {
				localDeviceID = fmt.Sprintf("%s:%s:%s", protoLink.LocalDeviceIp, discoveryAgentID, discoveryInitiatorPollerID)
				log.Printf("Generated LocalDeviceID for link from %s: %s", protoLink.LocalDeviceIp, localDeviceID)
			}

			metadataJSON, err := json.Marshal(protoLink.Metadata) // protoLink.Metadata is map[string]string
			if err != nil {
				log.Printf("Error marshaling topology metadata for local device %s, ifIndex %d: %v", protoLink.LocalDeviceIp, protoLink.LocalIfIndex, err)
				metadataJSON = []byte("{}")
			}

			modelEvent := &models.TopologyDiscoveryEvent{
				Timestamp:              timestamp,
				AgentID:                discoveryAgentID,
				PollerID:               discoveryInitiatorPollerID,
				LocalDeviceIP:          protoLink.LocalDeviceIp,
				LocalDeviceID:          localDeviceID,
				LocalIfIndex:           int(protoLink.LocalIfIndex),
				LocalIfName:            protoLink.LocalIfName,
				ProtocolType:           protoLink.Protocol,
				NeighborChassisID:      protoLink.NeighborChassisId,
				NeighborPortID:         protoLink.NeighborPortId,
				NeighborPortDescr:      protoLink.NeighborPortDescr,
				NeighborSystemName:     protoLink.NeighborSystemName,
				NeighborManagementAddr: protoLink.NeighborMgmtAddr,
				Metadata:               metadataJSON,
			}
			modelTopologyEvents = append(modelTopologyEvents, modelEvent)
		}
		if err := s.DB.PublishBatchTopologyDiscoveryEvents(ctx, modelTopologyEvents); err != nil {
			log.Printf("Error publishing batch topology discovery events for poller %s: %v", reportingPollerID, err)
		} else {
			log.Printf("Published %d topology discovery events for poller %s (discovery by %s/%s)", len(modelTopologyEvents), reportingPollerID, discoveryAgentID, discoveryInitiatorPollerID)
		}
	}

	return nil
}
