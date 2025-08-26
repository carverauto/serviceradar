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
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "net"
    "strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/carverauto/serviceradar/proto"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"
)

// discoveryService implements the DiscoveryService interface.
type discoveryService struct {
	db     db.Service
	reg    registry.Manager
	logger logger.Logger
}

// NewDiscoveryService creates a new DiscoveryService instance.
func NewDiscoveryService(db db.Service, reg registry.Manager, log logger.Logger) DiscoveryService {
	return &discoveryService{db: db, reg: reg, logger: log}
}

// ProcessSyncResults processes the results of a sync discovery operation.
// It handles the discovery data, extracts relevant information, and stores it in the database.
func (s *discoveryService) ProcessSyncResults(
	ctx context.Context,
	reportingPollerID string,
	_ string, // partition is not used in sync results
	svc *proto.ServiceStatus,
	details json.RawMessage,
	_ time.Time,
) error {
	s.logger.Info().Msg("Processing sync discovery results")

	// First, check if this is a status payload that should be skipped
	if s.isStatusPayload(details) {
		s.logger.Debug().
			Str("poller_id", reportingPollerID).
			Msg("Skipping status payload for sync service")

		return nil
	}

	// Parse the device updates
	sightings, err := s.parseSyncDeviceUpdates(details, reportingPollerID, svc.ServiceName)
	if err != nil {
		return err
	}

	if len(sightings) == 0 {
		s.logger.Debug().
			Str("poller_id", reportingPollerID).
			Str("service_name", svc.ServiceName).
			Msg("No sightings found in sync discovery data")

		return nil // Nothing to process
	}

	// Process the sightings through the registry
	if s.reg != nil {
		source := "unknown"
		if len(sightings) > 0 {
			source = string(sightings[0].Source) // Use the source from the first sighting
		}

		s.logger.Info().
			Int("sighting_count", len(sightings)).
			Str("source", source).
			Msg("Processing device sightings from sync service")

		if err := s.reg.ProcessBatchDeviceUpdates(ctx, sightings); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", reportingPollerID).
				Msg("Error processing sync discovery sightings")

			return err
		}
	} else {
		s.logger.Warn().
			Int("sighting_count", len(sightings)).
			Msg("DeviceRegistry not available. Skipping Processing of sync discovery sightings")
	}

	return nil
}

// isStatusPayload checks if the payload is a status response that should be skipped
func (*discoveryService) isStatusPayload(details json.RawMessage) bool {
	var statusCheck map[string]interface{}

	if err := json.Unmarshal(details, &statusCheck); err == nil {
		if _, hasDevices := statusCheck["devices"]; hasDevices {
			if _, hasStatus := statusCheck["status"]; hasStatus {
				// This is a status payload from GetResults, skip it
				return true
			}
		}
	}

	return false
}

// parseSyncDeviceUpdates parses device updates from sync service data
// It handles both single JSON arrays and multiple concatenated JSON arrays from chunked streaming
func (s *discoveryService) parseSyncDeviceUpdates(details json.RawMessage, pollerID, serviceName string) ([]*models.DeviceUpdate, error) {
	var sightings []*models.DeviceUpdate

	// Log data size for debugging
	s.logger.Debug().
		Str("poller_id", pollerID).
		Int("data_size", len(details)).
		Msg("CORE DEBUG: Parsing sync service data")

	// First try to parse as a single JSON array
	err := json.Unmarshal(details, &sightings)
	if err != nil {
		// If that fails, try to parse as multiple concatenated JSON arrays from chunked streaming
		s.logger.Debug().
			Err(err).
			Msg("Single array parse failed, trying multiple arrays")

        decoder := json.NewDecoder(bytes.NewReader(details))

		var allSightings []*models.DeviceUpdate

		for decoder.More() {
			var chunkSightings []*models.DeviceUpdate

			if chunkErr := decoder.Decode(&chunkSightings); chunkErr != nil {
				s.logger.Debug().
					Err(chunkErr).
					Msg("Failed to decode chunk in sync discovery data")
				s.logger.Debug().
					Str("payload", string(details)).
					Msg("Full raw JSON payload causing unmarshal failure")

				return nil, fmt.Errorf("failed to parse sync discovery data: %w", chunkErr)
			}

			allSightings = append(allSightings, chunkSightings...)
		}

		sightings = allSightings
		s.logger.Debug().
			Int("device_count", len(sightings)).
			Msg("Successfully parsed device updates from multiple JSON chunks")
	}

	// Debug logging for successful unmarshal
	s.logger.Debug().
		Int("device_count", len(sightings)).
		Str("poller_id", pollerID).
		Str("service_name", serviceName).
		Msg("CORE DEBUG: json.Unmarshal SUCCESS - parsed DeviceUpdate objects")

	// Log source breakdown if we have sightings
	if len(sightings) > 0 {
		sourceCounts := make(map[string]int)

		for _, update := range sightings {
			sourceCounts[string(update.Source)]++
		}

		s.logger.Debug().
			Interface("source_counts", sourceCounts).
			Msg("CORE DEBUG: Device breakdown by source")

		// Log samples from each source
		samplesLogged := make(map[string]int)
		for i, update := range sightings {
			if samplesLogged[string(update.Source)] < 2 {
				s.logger.Debug().
					Str("source", string(update.Source)).
					Int("index", i).
					Str("ip", update.IP).
					Str("device_id", update.DeviceID).
					Bool("is_available", update.IsAvailable).
					Interface("metadata", update.Metadata).
					Msgf("CORE DEBUG: %s DeviceUpdate[%d]", update.Source, i)

				samplesLogged[string(update.Source)]++
			}
		}
	}

	return sightings, nil
}

// isLoopbackIP checks if an IP address is a loopback address
func isLoopbackIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	return ip.IsLoopback()
}

// ProcessSNMPDiscoveryResults handles the data from SNMP discovery.
func (s *discoveryService) ProcessSNMPDiscoveryResults(
	ctx context.Context,
	reportingPollerID string,
	partition string,
	svc *proto.ServiceStatus,
	details json.RawMessage,
	timestamp time.Time,
) error {
	var payload models.SNMPDiscoveryDataPayload

	if err := json.Unmarshal(details, &payload); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", reportingPollerID).
			Str("service_name", svc.ServiceName).
			Str("payload", string(details)).
			Msg("Error unmarshaling SNMP discovery data")

		return fmt.Errorf("failed to parse SNMP discovery data: %w", err)
	}

	discoveryAgentID := payload.AgentID
	discoveryInitiatorPollerID := payload.PollerID

	// Fallback for discovery-specific IDs if not provided in payload
	if discoveryAgentID == "" {
		s.logger.Warn().
			Str("reporting_poller_id", reportingPollerID).
			Str("fallback_agent_id", svc.AgentId).
			Msg("SNMPDiscoveryDataPayload.AgentID is empty, falling back to svc.AgentID")

		discoveryAgentID = svc.AgentId
	}

	if discoveryInitiatorPollerID == "" {
		s.logger.Warn().
			Str("reporting_poller_id", reportingPollerID).
			Msg("SNMPDiscoveryDataPayload.PollerID is empty, falling back to reportingPollerID")

		discoveryInitiatorPollerID = reportingPollerID
	}

	// Create a map of discovered devices for easy lookup by IP.
	// This allows us to enrich interface data with device metadata.
	deviceMap := make(map[string]*discoverypb.DiscoveredDevice)

	for _, dev := range payload.Devices {
		if dev != nil && dev.Ip != "" {
			deviceMap[dev.Ip] = dev
		}
	}

	// Process each type of discovery data
	if len(payload.Devices) > 0 {
		s.processDiscoveredDevices(ctx, payload.Devices, discoveryAgentID, discoveryInitiatorPollerID,
			partition, reportingPollerID, timestamp)
	}

	if len(payload.Interfaces) > 0 {
		// Pass the deviceMap to the interface processor to enrich sightings.
		s.processDiscoveredInterfaces(ctx, payload.Interfaces, deviceMap, discoveryAgentID, discoveryInitiatorPollerID,
			partition, reportingPollerID, timestamp)
	}

	if len(payload.Topology) > 0 {
		s.processDiscoveredTopology(ctx, payload.Topology, discoveryAgentID, discoveryInitiatorPollerID,
			partition, reportingPollerID, timestamp)
	}

	return nil
}

// processDiscoveredDevices handles processing and storing device information from SNMP discovery.
func (s *discoveryService) processDiscoveredDevices(
	ctx context.Context,
	devices []*discoverypb.DiscoveredDevice,
	discoveryAgentID string,
	discoveryInitiatorPollerID string,
	partition string,
	reportingPollerID string,
	timestamp time.Time,
) {
	resultsToStore := make([]*models.DeviceUpdate, 0, len(devices))

	for _, protoDevice := range devices {
		if protoDevice == nil || protoDevice.Ip == "" {
			continue
		}

		deviceMetadata := s.extractDeviceMetadata(protoDevice)
		hostname := protoDevice.Hostname
		mac := protoDevice.Mac

		result := &models.DeviceUpdate{
			AgentID:     discoveryAgentID,
			PollerID:    discoveryInitiatorPollerID,
			DeviceID:    fmt.Sprintf("%s:%s", partition, protoDevice.Ip),
			Partition:   partition,
			Source:      models.DiscoverySourceMapper, // Mapper discovery: devices found by the mapper component using SNMP
			IP:          protoDevice.Ip,
			MAC:         &mac,
			Hostname:    &hostname,
			Timestamp:   timestamp,
			IsAvailable: true, // Assumed true if discovered via mapper
			Metadata:    deviceMetadata,
		}

		resultsToStore = append(resultsToStore, result)
	}

	if s.reg != nil {
		// Delegate to the new registry
		if err := s.reg.ProcessBatchDeviceUpdates(ctx, resultsToStore); err != nil {
			s.logger.Error().
				Err(err).
				Str("poller_id", reportingPollerID).
				Msg("Error processing discovered device sightings")
		}
	}
}

// extractDeviceMetadata extracts and formats metadata from a discovered device.
func (*discoveryService) extractDeviceMetadata(protoDevice *discoverypb.DiscoveredDevice) map[string]string {
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

// processDiscoveredInterfaces handles processing interface information from SNMP discovery.
// Its responsibilities are:
//  1. (Optional) Store the raw, detailed interface data for historical/diagnostic purposes.
//  2. Create one "sighting" (SweepResult) for each device discovered in the report. This sighting
//     is enriched with all IPs found on the device's interfaces, which is critical context for the registry.
//  3. Pass these sightings to the authoritative DeviceRegistry for correlation and processing.
//
// This function NO LONGER performs any lookups or correlation itself.
// groupInterfacesByDevice groups interfaces by the device they were discovered on.
func (*discoveryService) groupInterfacesByDevice(
	interfaces []*discoverypb.DiscoveredInterface) map[string][]*discoverypb.DiscoveredInterface {
	deviceToInterfacesMap := make(map[string][]*discoverypb.DiscoveredInterface)

	for _, protoIface := range interfaces {
		if protoIface == nil || protoIface.DeviceIp == "" {
			continue
		}

		deviceToInterfacesMap[protoIface.DeviceIp] = append(deviceToInterfacesMap[protoIface.DeviceIp], protoIface)
	}

	return deviceToInterfacesMap
}

// createModelInterfaces creates model interfaces for storage from proto interfaces.
func (s *discoveryService) createModelInterfaces(
	deviceToInterfacesMap map[string][]*discoverypb.DiscoveredInterface,
	partition string,
	discoveryAgentID string,
	discoveryInitiatorPollerID string,
	timestamp time.Time,
) []*models.DiscoveredInterface {
	allModelInterfaces := make([]*models.DiscoveredInterface, 0)

	for deviceIP, deviceInterfaces := range deviceToInterfacesMap {
		provisionalDeviceID := fmt.Sprintf("%s:%s", partition, deviceIP)

		for _, protoIface := range deviceInterfaces {
			metadataJSON := s.prepareInterfaceMetadata(protoIface)
			modelIface := &models.DiscoveredInterface{
				Timestamp:     timestamp,
				AgentID:       discoveryAgentID,
				PollerID:      discoveryInitiatorPollerID,
				DeviceIP:      protoIface.DeviceIp,
				DeviceID:      provisionalDeviceID, // Use the provisional ID for this raw data.
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

	return allModelInterfaces
}

// collectDeviceIPs collects all unique IPs associated with a device from its interfaces.
func (*discoveryService) collectDeviceIPs(deviceIP string, deviceInterfaces []*discoverypb.DiscoveredInterface) []string {
	ipSet := make(map[string]struct{})
	// Always include the primary IP the device was discovered with.
	ipSet[deviceIP] = struct{}{}

	for _, iface := range deviceInterfaces {
		for _, ip := range iface.IpAddresses {
			if ip != "" && !isLoopbackIP(ip) {
				ipSet[ip] = struct{}{}
			}
		}
	}

	// Extract alternate IPs (all IPs except the primary one)
	alternateIPs := make([]string, 0, len(ipSet)-1)

	for ip := range ipSet {
		if ip != deviceIP { // The primary IP is not an "alternate" of itself.
			alternateIPs = append(alternateIPs, ip)
		}
	}

	return alternateIPs
}

// createCorrelationSighting creates a correlation sighting for a device.
func (s *discoveryService) createCorrelationSighting(
	deviceIP string,
	alternateIPs []string,
	deviceMap map[string]*discoverypb.DiscoveredDevice,
	partition string,
	discoveryAgentID string,
	discoveryInitiatorPollerID string,
	timestamp time.Time,
) *models.DeviceUpdate {
	// Initialize metadata from the parent device, if it exists in the map.
	var metadata map[string]string

	if parentDevice, ok := deviceMap[deviceIP]; ok {
		metadata = s.extractDeviceMetadata(parentDevice)
	} else {
		// Fallback if no corresponding device entry was found.
		metadata = make(map[string]string)
	}

    // Add alternate IPs to metadata as exact-match keys for reliable lookup
    if len(alternateIPs) > 0 {
        if metadata == nil { // safety, though ensured above
            metadata = make(map[string]string)
        }
        for _, ip := range alternateIPs {
            if ip == "" || isLoopbackIP(ip) {
                continue
            }
            metadata["alt_ip:"+ip] = "1"
        }
    }

	// Create the single, enriched sighting for this device.
	return &models.DeviceUpdate{
		AgentID:     discoveryAgentID,
		PollerID:    discoveryInitiatorPollerID,
		DeviceID:    fmt.Sprintf("%s:%s", partition, deviceIP), // The registry will resolve the canonical ID.
		Partition:   partition,
		IP:          deviceIP, // The primary IP from this discovery event.
		IsAvailable: true,
		Timestamp:   timestamp,
		Source:      models.DiscoverySourceMapper,
		Metadata:    metadata,
	}
}

func (s *discoveryService) processDiscoveredInterfaces(
	ctx context.Context,
	interfaces []*discoverypb.DiscoveredInterface,
	deviceMap map[string]*discoverypb.DiscoveredDevice,
	discoveryAgentID string,
	discoveryInitiatorPollerID string,
	partition string,
	reportingPollerID string,
	timestamp time.Time,
) {
	if len(interfaces) == 0 {
		return
	}

	// Group interfaces by the device they were discovered on
	deviceToInterfacesMap := s.groupInterfacesByDevice(interfaces)

	// Path 1: Persist Raw Interface Data (for historical/detailed views)
	allModelInterfaces := s.createModelInterfaces(
		deviceToInterfacesMap,
		partition,
		discoveryAgentID,
		discoveryInitiatorPollerID,
		timestamp,
	)

	if err := s.db.PublishBatchDiscoveredInterfaces(ctx, allModelInterfaces); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", reportingPollerID).
			Msg("Error publishing batch discovered interfaces")
	}

	// Path 2: Create Correlation Sightings for the Device Registry (CRITICAL PATH)
	correlationSightings := make([]*models.DeviceUpdate, 0, len(deviceToInterfacesMap))

	for deviceIP, deviceInterfaces := range deviceToInterfacesMap {
		// Collect all unique IPs associated with this device
		alternateIPs := s.collectDeviceIPs(deviceIP, deviceInterfaces)

		// Create a correlation sighting for this device
		sighting := s.createCorrelationSighting(
			deviceIP,
			alternateIPs,
			deviceMap,
			partition,
			discoveryAgentID,
			discoveryInitiatorPollerID,
			timestamp,
		)

		correlationSightings = append(correlationSightings, sighting)
	}

	// Process the batch of sightings through the authoritative registry
	if len(correlationSightings) > 0 && s.reg != nil {
		if err := s.reg.ProcessBatchDeviceUpdates(ctx, correlationSightings); err != nil {
			s.logger.Error().
				Err(err).
				Msg("Error processing mapper correlation sightings")
		}
	}
}

// prepareInterfaceMetadata prepares the metadata JSON for an interface. (Helper function, remains unchanged)
func (s *discoveryService) prepareInterfaceMetadata(protoIface *discoverypb.DiscoveredInterface) json.RawMessage {
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
		s.logger.Error().
			Err(err).
			Str("device_ip", protoIface.DeviceIp).
			Int32("if_index", protoIface.IfIndex).
			Msg("Error marshaling interface metadata")

		metadataJSON = []byte("{}")
	}

	return metadataJSON
}

// processDiscoveredTopology handles processing and storing topology information from SNMP discovery.
func (s *discoveryService) processDiscoveredTopology(
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

	if err := s.db.PublishBatchTopologyDiscoveryEvents(ctx, modelTopologyEvents); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", reportingPollerID).
			Msg("Error publishing batch topology discovery events")
	}
}

// getOrGenerateLocalDeviceID returns the local device ID from the topology link or generates one if not present.
func (s *discoveryService) getOrGenerateLocalDeviceID(protoLink *discoverypb.TopologyLink, partition string) string {
	localDeviceID := protoLink.LocalDeviceId
	if localDeviceID == "" && protoLink.LocalDeviceIp != "" {
		localDeviceID = fmt.Sprintf("%s:%s", partition, protoLink.LocalDeviceIp)
		s.logger.Debug().
			Str("local_device_ip", protoLink.LocalDeviceIp).
			Str("local_device_id", localDeviceID).
			Msg("Generated LocalDeviceID for link")
	}

	return localDeviceID
}

// prepareTopologyMetadata prepares the metadata JSON for a topology link.
func (s *discoveryService) prepareTopologyMetadata(protoLink *discoverypb.TopologyLink) json.RawMessage {
	metadataJSON, err := json.Marshal(protoLink.Metadata) // protoLink.Metadata is map[string]string
	if err != nil {
		s.logger.Error().
			Err(err).
			Str("local_device_ip", protoLink.LocalDeviceIp).
			Int32("local_if_index", protoLink.LocalIfIndex).
			Msg("Error marshaling topology metadata")

		metadataJSON = []byte("{}")
	}

	return metadataJSON
}
