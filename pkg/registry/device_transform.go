package registry

import (
	"sort"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

func cloneMetadata(src map[string]string) map[string]string {
	if len(src) == 0 {
		return nil
	}

	out := make(map[string]string, len(src))
	for key, value := range src {
		out[key] = value
	}
	return out
}

// LegacyDeviceFromRecord converts a DeviceRecord into the legacy Device representation.
func LegacyDeviceFromRecord(record *DeviceRecord) *models.Device {
	if record == nil {
		return nil
	}

	device := &models.Device{
		DeviceID:         record.DeviceID,
		AgentID:          record.AgentID,
		GatewayID:         record.GatewayID,
		DiscoverySources: append([]string(nil), record.DiscoverySources...),
		IP:               record.IP,
		FirstSeen:        record.FirstSeen,
		LastSeen:         record.LastSeen,
		IsAvailable:      record.IsAvailable,
	}

	if record.MAC != nil {
		device.MAC = *record.MAC
	}
	if record.Hostname != nil {
		device.Hostname = *record.Hostname
	}
	if len(record.Metadata) > 0 {
		device.Metadata = make(map[string]interface{}, len(record.Metadata))
		for k, v := range record.Metadata {
			device.Metadata[k] = v
		}
	}

	return device
}

// LegacyDeviceSlice converts multiple records with optional pagination.
func LegacyDeviceSlice(records []*DeviceRecord) []*models.Device {
	if len(records) == 0 {
		return nil
	}
	out := make([]*models.Device, 0, len(records))
	for _, record := range records {
		if record == nil {
			continue
		}
		out = append(out, LegacyDeviceFromRecord(record))
	}
	return out
}

func sortRecordsByLastSeenDesc(records []*DeviceRecord) {
	sort.Slice(records, func(i, j int) bool {
		// Newer last_seen should come first; fall back to device_id for stability.
		if records[i].LastSeen.Equal(records[j].LastSeen) {
			return records[i].DeviceID < records[j].DeviceID
		}
		return records[i].LastSeen.After(records[j].LastSeen)
	})
}

// DeviceRecordFromOCSF creates a DeviceRecord snapshot from an OCSF device row.
func DeviceRecordFromOCSF(device *models.OCSFDevice) *DeviceRecord {
	if device == nil {
		return nil
	}

	record := &DeviceRecord{
		DeviceID:   strings.TrimSpace(device.UID),
		IP:         strings.TrimSpace(device.IP),
		GatewayID:   device.GatewayID,
		AgentID:    device.AgentID,
		DeviceType: device.GetTypeName(),
	}

	if record.DeviceID == "" {
		return nil
	}

	if hostname := strings.TrimSpace(device.Hostname); hostname != "" {
		record.Hostname = &hostname
	}

	if mac := strings.TrimSpace(device.MAC); mac != "" {
		upper := strings.ToUpper(mac)
		record.MAC = &upper
	}

	if device.FirstSeenTime != nil {
		record.FirstSeen = *device.FirstSeenTime
	}

	if device.LastSeenTime != nil {
		record.LastSeen = *device.LastSeenTime
	}

	if device.IsAvailable != nil {
		record.IsAvailable = *device.IsAvailable
	}

	if len(device.DiscoverySources) > 0 {
		record.DiscoverySources = make([]string, len(device.DiscoverySources))
		copy(record.DiscoverySources, device.DiscoverySources)
	}

	if len(device.Metadata) > 0 {
		record.Metadata = cloneMetadata(device.Metadata)

		if integrationID := strings.TrimSpace(record.Metadata["integration_id"]); integrationID != "" {
			record.IntegrationID = &integrationID
		}
		if collectorAgent := strings.TrimSpace(record.Metadata["collector_agent_id"]); collectorAgent != "" {
			record.CollectorAgentID = &collectorAgent
		}
	}

	return record
}

// OCSFDeviceFromRecord converts a DeviceRecord into an OCSFDevice view.
func OCSFDeviceFromRecord(record *DeviceRecord) *models.OCSFDevice {
	if record == nil {
		return nil
	}

	device := &models.OCSFDevice{
		UID:              record.DeviceID,
		IP:               record.IP,
		GatewayID:         record.GatewayID,
		AgentID:          record.AgentID,
		DiscoverySources: append([]string(nil), record.DiscoverySources...),
	}

	// Set type from DeviceType string
	device.Type = record.DeviceType
	device.TypeID = inferTypeIDFromName(record.DeviceType)

	if record.Hostname != nil {
		device.Hostname = *record.Hostname
	}

	if record.MAC != nil {
		device.MAC = *record.MAC
	}

	if !record.FirstSeen.IsZero() {
		firstSeen := record.FirstSeen
		device.FirstSeenTime = &firstSeen
	}

	if !record.LastSeen.IsZero() {
		lastSeen := record.LastSeen
		device.LastSeenTime = &lastSeen
		device.ModifiedTime = lastSeen
	}

	isAvailable := record.IsAvailable
	device.IsAvailable = &isAvailable

	if len(record.Metadata) > 0 {
		device.Metadata = cloneMetadata(record.Metadata)
	}

	return device
}

// OCSFDeviceSlice converts records into OCSFDevice representations.
func OCSFDeviceSlice(records []*DeviceRecord) []*models.OCSFDevice {
	if len(records) == 0 {
		return nil
	}
	out := make([]*models.OCSFDevice, 0, len(records))
	for _, record := range records {
		if record == nil {
			continue
		}
		out = append(out, OCSFDeviceFromRecord(record))
	}
	return out
}

// inferTypeIDFromName converts a device type name to OCSF type ID.
func inferTypeIDFromName(typeName string) int {
	switch strings.ToLower(typeName) {
	case "server":
		return models.OCSFDeviceTypeServer
	case "desktop":
		return models.OCSFDeviceTypeDesktop
	case "laptop":
		return models.OCSFDeviceTypeLaptop
	case "tablet":
		return models.OCSFDeviceTypeTablet
	case "mobile":
		return models.OCSFDeviceTypeMobile
	case "virtual":
		return models.OCSFDeviceTypeVirtual
	case "iot":
		return models.OCSFDeviceTypeIOT
	case "browser":
		return models.OCSFDeviceTypeBrowser
	case "firewall":
		return models.OCSFDeviceTypeFirewall
	case "switch":
		return models.OCSFDeviceTypeSwitch
	case "hub":
		return models.OCSFDeviceTypeHub
	case "router":
		return models.OCSFDeviceTypeRouter
	case "ids":
		return models.OCSFDeviceTypeIDS
	case "ips":
		return models.OCSFDeviceTypeIPS
	case "load balancer":
		return models.OCSFDeviceTypeLoadBalancer
	case "other":
		return models.OCSFDeviceTypeOther
	default:
		return models.OCSFDeviceTypeUnknown
	}
}
