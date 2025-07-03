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
	"log"
	"net"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

// isLoopbackIP checks if an IP address is a loopback address
func isLoopbackIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}
	return ip.IsLoopback()
}

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
	resultsToStore := make([]*models.SweepResult, 0, len(devices))

	for _, protoDevice := range devices {
		if protoDevice == nil || protoDevice.Ip == "" {
			continue
		}

		deviceMetadata := s.extractDeviceMetadata(protoDevice)
		hostname := protoDevice.Hostname
		mac := protoDevice.Mac

		result := &models.SweepResult{
			AgentID:         discoveryAgentID,
			PollerID:        discoveryInitiatorPollerID,
			DeviceID:        fmt.Sprintf("%s:%s", partition, protoDevice.Ip),
			Partition:       partition,
			DiscoverySource: "mapper", // Mapper discovery: devices found by the mapper component using SNMP
			IP:              protoDevice.Ip,
			MAC:             &mac,
			Hostname:        &hostname,
			Timestamp:       timestamp,
			Available:       true, // Assumed true if discovered via mapper
			Metadata:        deviceMetadata,
		}
		resultsToStore = append(resultsToStore, result)
	}


	// Process devices immediately to ensure they exist before interfaces reference them
	if s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessBatchSweepResults(ctx, resultsToStore); err != nil {
			log.Printf("Error processing batch sweep results from discovery for poller %s: %v", reportingPollerID, err)
		} else {
			log.Printf("Successfully processed %d discovered devices for poller %s", len(resultsToStore), reportingPollerID)
		}
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

	// Classify device type based on hostname, sys_descr, and sys_object_id
	deviceType := classifyDeviceType(protoDevice.Hostname, protoDevice.SysDescr, protoDevice.SysObjectId)
	if deviceType != "" {
		deviceMetadata["device_type"] = deviceType
	}

	return deviceMetadata
}

const (
	defaultWirelessAPType = "wireless_ap"
	defaultSwitchType     = "switch"
	defaultRouterType     = "router"
)

// checkHostnameForDeviceType determines device type based on hostname patterns
func checkHostnameForDeviceType(hostname string) string {
	hostnameLower := strings.ToLower(hostname)

	// Ubiquiti switches
	if strings.Contains(hostnameLower, "usw") || strings.Contains(hostnameLower, "unifi") {
		if strings.Contains(hostnameLower, "poe") {
			return "switch_poe"
		}

		return defaultSwitchType
	}

	// Ubiquiti Access Points
	if (strings.Contains(hostnameLower, "nano") && strings.Contains(hostnameLower, "hd")) ||
		strings.Contains(hostnameLower, "u6") || strings.Contains(hostnameLower, "u7") {
		return defaultWirelessAPType
	}

	return ""
}

// checkSysDescrForUbiquiti checks if the system description indicates a Ubiquiti device
func checkSysDescrForUbiquiti(sysDescr string) string {
	sysDescrLower := strings.ToLower(sysDescr)

	if !strings.Contains(sysDescrLower, "ubiquiti") && !strings.Contains(sysDescrLower, "unifi") {
		return ""
	}

	if strings.Contains(sysDescrLower, defaultSwitchType) {
		return defaultSwitchType
	}

	if strings.Contains(sysDescrLower, "access point") || strings.Contains(sysDescrLower, "wireless") {
		return defaultWirelessAPType
	}

	if strings.Contains(sysDescrLower, "gateway") || strings.Contains(sysDescrLower, defaultRouterType) {
		return defaultRouterType
	}

	return "network_device"
}

// checkSysDescrForGenericType checks for generic device types in system description
func checkSysDescrForGenericType(sysDescr string) string {
	sysDescrLower := strings.ToLower(sysDescr)

	if strings.Contains(sysDescrLower, defaultSwitchType) {
		return defaultSwitchType
	}

	if strings.Contains(sysDescrLower, defaultRouterType) {
		return defaultRouterType
	}

	if strings.Contains(sysDescrLower, "access point") || strings.Contains(sysDescrLower, "wireless") {
		return defaultWirelessAPType
	}

	if strings.Contains(sysDescrLower, "firewall") {
		return "firewall"
	}

	if strings.Contains(sysDescrLower, "server") {
		return "server"
	}

	if strings.Contains(sysDescrLower, "linux") || strings.Contains(sysDescrLower, "windows") ||
		strings.Contains(sysDescrLower, "host") {
		return "host"
	}

	return ""
}

// checkSysObjectIDForVendor identifies the vendor based on system object ID
func checkSysObjectIDForVendor(sysObjectID string) string {
	if sysObjectID == "" {
		return ""
	}

	// Cisco OIDs
	if strings.HasPrefix(sysObjectID, "1.3.6.1.4.1.9") {
		return "cisco_device"
	}

	// HP/HPE OIDs
	if strings.HasPrefix(sysObjectID, "1.3.6.1.4.1.11") {
		return "hp_device"
	}

	// Ubiquiti OIDs
	if strings.HasPrefix(sysObjectID, "1.3.6.1.4.1.41112") {
		return "ubiquiti_device"
	}

	return ""
}

// classifyDeviceType determines the device type based on available information
func classifyDeviceType(hostname, sysDescr, sysObjectID string) string {
	// Try to classify based on hostname
	if deviceType := checkHostnameForDeviceType(hostname); deviceType != "" {
		return deviceType
	}

	// Try to classify based on Ubiquiti-specific system description
	if deviceType := checkSysDescrForUbiquiti(sysDescr); deviceType != "" {
		return deviceType
	}

	// Try to classify based on generic system description
	if deviceType := checkSysDescrForGenericType(sysDescr); deviceType != "" {
		return deviceType
	}

	// Try to classify based on system object ID
	if deviceType := checkSysObjectIDForVendor(sysObjectID); deviceType != "" {
		return deviceType
	}

	// Default fallback
	return "network_device"
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
	if len(interfaces) == 0 {
		return
	}

	// Step 1: Collect all unique Device IPs from the interface batch
	deviceIPSet := make(map[string]struct{})
	// Map to group all IPs by the primary device IP to handle correlation
	deviceIPs := make(map[string]map[string]struct{})
	
	for _, protoIface := range interfaces {
		if protoIface != nil && protoIface.DeviceIp != "" {
			deviceIPSet[protoIface.DeviceIp] = struct{}{}
			
			// Initialize the set if it's the first time seeing this device IP
			if _, ok := deviceIPs[protoIface.DeviceIp]; !ok {
				deviceIPs[protoIface.DeviceIp] = make(map[string]struct{})
			}

			// Add all IPs from the interface to the device's IP set for correlation
			for _, ip := range protoIface.IpAddresses {
				if ip != "" && !isLoopbackIP(ip) {
					deviceIPs[protoIface.DeviceIp][ip] = struct{}{}
				}
			}
		}
	}
	
	ipsToLookup := make([]string, 0, len(deviceIPSet))
	for ip := range deviceIPSet {
		ipsToLookup = append(ipsToLookup, ip)
	}

	// Step 2: Use the Device Registry to find the canonical device for each IP in one batch
	canonicalDeviceMap, err := s.DeviceRegistry.FindCanonicalDevicesByIPs(ctx, ipsToLookup)
	if err != nil {
		log.Printf("Error finding canonical devices for interfaces: %v", err)
		// Continue processing even if lookup fails
	}

	modelInterfaces := make([]*models.DiscoveredInterface, 0, len(interfaces))
	for _, protoIface := range interfaces {
		if protoIface == nil {
			continue
		}

		// Step 3: Determine the canonical DeviceID
		var canonicalDeviceID string
		if canonicalDevice, ok := canonicalDeviceMap[protoIface.DeviceIp]; ok {
			canonicalDeviceID = canonicalDevice.DeviceID
		} else {
			// With materialized view approach, use the partition:ip format
			// The materialized view will handle device reconciliation automatically
			canonicalDeviceID = fmt.Sprintf("%s:%s", partition, protoIface.DeviceIp)
		}

		metadataJSON := s.prepareInterfaceMetadata(protoIface)

		modelIface := &models.DiscoveredInterface{
			Timestamp:     timestamp,
			AgentID:       discoveryAgentID,
			PollerID:      discoveryInitiatorPollerID,
			DeviceIP:      protoIface.DeviceIp, // This is the IP we discovered it on
			DeviceID:      canonicalDeviceID,   // THIS IS THE CRITICAL CHANGE - using canonical ID
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

	// --- Start of alternate IP correlation logic ---
	// Update device registry with alternate IPs using materialized view approach
	correlationResults := make([]*models.SweepResult, 0, len(deviceIPs))
	
	for deviceIP, ipSet := range deviceIPs {
		// Convert the set of IPs to a slice
		allIPs := make([]string, 0, len(ipSet))
		for ip := range ipSet {
			allIPs = append(allIPs, ip)
		}

		// Marshal the IPs into a JSON string for metadata
		alternateIPsJSON, err := json.Marshal(allIPs)
		if err != nil {
			log.Printf("Error marshaling alternate IPs for device %s: %v", deviceIP, err)
			continue
		}

		// Create a sweep result with alternate IP metadata
		result := &models.SweepResult{
			AgentID:         discoveryAgentID,
			PollerID:        discoveryInitiatorPollerID,
			DeviceID:        fmt.Sprintf("%s:%s", partition, deviceIP),
			IP:              deviceIP,
			Available:       true, // Assume available since we discovered interfaces
			Timestamp:       timestamp,
			DiscoverySource: "mapper", 
			Metadata: map[string]string{
				"alternate_ips": string(alternateIPsJSON),
			},
		}
		correlationResults = append(correlationResults, result)
	}

	// Process correlation results using materialized view pipeline
	if len(correlationResults) > 0 && s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessBatchSweepResults(ctx, correlationResults); err != nil {
			log.Printf("Error processing alternate IP correlation results: %v", err)
		}
	}
	// --- End of alternate IP correlation logic ---

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
