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

	// Group interfaces by the device they were discovered on.
	// This is key to preventing cross-contamination between devices in the same report.
	deviceToInterfacesMap := make(map[string][]*discoverypb.DiscoveredInterface)
	for _, protoIface := range interfaces {
		if protoIface == nil || protoIface.DeviceIp == "" {
			continue
		}

		deviceToInterfacesMap[protoIface.DeviceIp] = append(deviceToInterfacesMap[protoIface.DeviceIp], protoIface)
	}

	// --- Process Interfaces for Storage (less critical path) ---
	// This part stores the detailed interface data.
	allModelInterfaces := make([]*models.DiscoveredInterface, 0, len(interfaces))
	for deviceIP, deviceInterfaces := range deviceToInterfacesMap {
		// Find canonical device ID specifically for THIS deviceIP.
		canonicalDeviceMap, err := s.DeviceRegistry.FindCanonicalDevicesByIPs(ctx, []string{deviceIP})
		if err != nil {
			log.Printf("Warning: Error finding canonical device for %s, will generate ID: %v", deviceIP, err)
			canonicalDeviceMap = make(map[string]*models.UnifiedDevice)
		}

		var canonicalDeviceID string

		if canonicalDevice, ok := canonicalDeviceMap[deviceIP]; ok {
			canonicalDeviceID = canonicalDevice.DeviceID
		} else {
			// Materialized view will handle reconciliation.
			canonicalDeviceID = fmt.Sprintf("%s:%s", partition, deviceIP)
		}

		// Prepare the detailed interface models for this device
		for _, protoIface := range deviceInterfaces {
			metadataJSON := s.prepareInterfaceMetadata(protoIface)
			modelIface := &models.DiscoveredInterface{
				Timestamp:     timestamp,
				AgentID:       discoveryAgentID,
				PollerID:      discoveryInitiatorPollerID,
				DeviceIP:      protoIface.DeviceIp,
				DeviceID:      canonicalDeviceID, // Use the determined canonical ID
				IfIndex:       protoIface.IfIndex,
				IfName:        protoIface.IfName,
				IfDescr:       protoIface.IfDescr,
				IfAlias:       protoIface.IfAlias,
				IfSpeed:       protoIface.IfSpeed.GetValue(),
				IfPhysAddress: protoIface.IfPhysAddress,
				IPAddresses:   protoIface.IpAddresses,
				IfAdminStatus: protoIface.IfAdminStatus,
				IfOperStatus:  protoIface.IfOperStatus,
				Metadata:      metadataJSON,
			}

			allModelInterfaces = append(allModelInterfaces, modelIface)
		}
	}

	if err := s.DB.PublishBatchDiscoveredInterfaces(ctx, allModelInterfaces); err != nil {
		log.Printf("Error publishing batch discovered interfaces for poller %s: %v", reportingPollerID, err)
	}

	// --- Process Devices for Correlation (CRITICAL PATH) ---
	// This path creates the SweepResults that drive the unified_devices view.
	correlationResults := make([]*models.SweepResult, 0, len(deviceToInterfacesMap))

	for deviceIP, deviceInterfaces := range deviceToInterfacesMap {
		// Step 1: Collect ALL IPs associated with THIS specific device from the report.
		ipSet := make(map[string]struct{})
		ipSet[deviceIP] = struct{}{}

		for _, iface := range deviceInterfaces {
			for _, ip := range iface.IpAddresses {
				if ip != "" && !isLoopbackIP(ip) {
					ipSet[ip] = struct{}{}
				}
			}
		}

		allIPsForThisDevice := make([]string, 0, len(ipSet))

		for ip := range ipSet {
			allIPsForThisDevice = append(allIPsForThisDevice, ip)
		}

		// Step 2: Find the canonical device by looking up ALL associated IPs for THIS device.
		canonicalDeviceMap, err := s.DeviceRegistry.FindCanonicalDevicesByIPs(ctx, allIPsForThisDevice)
		if err != nil {
			log.Printf("Error finding canonical devices for IP set %v: %v", allIPsForThisDevice, err)
			canonicalDeviceMap = make(map[string]*models.UnifiedDevice)
		}

		// Step 3: Determine the single canonical ID for this device.
		var canonicalDevice *models.UnifiedDevice

		foundCanonicalIDs := make(map[string]struct{})
		for _, dev := range canonicalDeviceMap {
			if _, exists := foundCanonicalIDs[dev.DeviceID]; !exists {
				if canonicalDevice == nil {
					canonicalDevice = dev // Pick the first one we find
				} else {
					log.Printf("Warning: Discovered device %s links to multiple canonical devices (%s and %s). Sticking with first: %s",
						deviceIP, canonicalDevice.DeviceID, dev.DeviceID, canonicalDevice.DeviceID)
				}

				foundCanonicalIDs[dev.DeviceID] = struct{}{}
			}
		}

		var canonicalDeviceID string

		if canonicalDevice != nil {
			canonicalDeviceID = canonicalDevice.DeviceID
			log.Printf("Found canonical device %s for discovered IP %s (linked via one of its IPs)", canonicalDeviceID, deviceIP)
		} else {
			canonicalDeviceID = fmt.Sprintf("%s:%s", partition, deviceIP)
			log.Printf("No canonical device for IP set of %s, generating new ID: %s", deviceIP, canonicalDeviceID)
		}

		// Marshal alternate IPs for metadata
		alternateIPsJSON, err := json.Marshal(allIPsForThisDevice)
		if err != nil {
			log.Printf("Error marshaling alternate IPs for device %s: %v", deviceIP, err)
			continue
		}

		// Create the sweep result with the correct canonical ID and all its discovered IPs.
		result := &models.SweepResult{
			AgentID:         discoveryAgentID,
			PollerID:        discoveryInitiatorPollerID,
			DeviceID:        canonicalDeviceID, // **CRITICAL FIX: Use the correctly scoped ID**
			Partition:       partition,
			IP:              deviceIP, // The primary IP from this discovery event.
			Available:       true,
			Timestamp:       timestamp,
			DiscoverySource: "mapper",
			Metadata: map[string]string{
				"alternate_ips": string(alternateIPsJSON),
			},
		}

		correlationResults = append(correlationResults, result)
	}

	// Step 4: Process the correlation results.
	if len(correlationResults) > 0 && s.DeviceRegistry != nil {
		if err := s.DeviceRegistry.ProcessBatchSweepResults(ctx, correlationResults); err != nil {
			log.Printf("Error processing alternate IP correlation results: %v", err)
		}
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
