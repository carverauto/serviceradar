package registry

import (
	"sort"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

// DeviceRecordFromUnified creates a DeviceRecord snapshot from a Proton unified device row.
func DeviceRecordFromUnified(device *models.UnifiedDevice) *DeviceRecord {
	if device == nil {
		return nil
	}

	record := &DeviceRecord{
		DeviceID:    strings.TrimSpace(device.DeviceID),
		IP:          strings.TrimSpace(device.IP),
		IsAvailable: device.IsAvailable,
		FirstSeen:   device.FirstSeen,
		LastSeen:    device.LastSeen,
		DeviceType:  device.DeviceType,
	}

	if record.DeviceID == "" {
		return nil
	}

	if device.Hostname != nil {
		if hostname := strings.TrimSpace(device.Hostname.Value); hostname != "" {
			record.Hostname = &hostname
		}
	}

	if device.MAC != nil {
		if mac := strings.TrimSpace(device.MAC.Value); mac != "" {
			upper := strings.ToUpper(mac)
			record.MAC = &upper
		}
	}

	if device.Metadata != nil && len(device.Metadata.Value) > 0 {
		record.Metadata = cloneMetadata(device.Metadata.Value)

		if integrationID := strings.TrimSpace(record.Metadata["integration_id"]); integrationID != "" {
			record.IntegrationID = &integrationID
		}
		if collectorAgent := strings.TrimSpace(record.Metadata["collector_agent_id"]); collectorAgent != "" {
			record.CollectorAgentID = &collectorAgent
		}
	}

	if len(device.DiscoverySources) > 0 {
		record.DiscoverySources = make([]string, 0, len(device.DiscoverySources))
		seenSources := make(map[string]struct{}, len(device.DiscoverySources))
		for _, source := range device.DiscoverySources {
			src := strings.TrimSpace(string(source.Source))
			if src == "" {
				continue
			}
			if _, ok := seenSources[src]; ok {
				continue
			}
			seenSources[src] = struct{}{}
			record.DiscoverySources = append(record.DiscoverySources, src)
		}
	}

	if primary, ok := selectPrimarySource(device.DiscoverySources); ok {
		record.PollerID = primary.PollerID
		record.AgentID = primary.AgentID
	} else {
		record.PollerID = fallbackPollerID(device)
		record.AgentID = fallbackAgentID(device)
	}

	return record
}

func selectPrimarySource(sources []models.DiscoverySourceInfo) (models.DiscoverySourceInfo, bool) {
	var (
		selected models.DiscoverySourceInfo
		found    bool
	)

	for _, source := range sources {
		if !found {
			selected = source
			found = true
			continue
		}

		if source.Confidence > selected.Confidence {
			selected = source
			continue
		}

		if source.Confidence == selected.Confidence && source.LastSeen.After(selected.LastSeen) {
			selected = source
			continue
		}
	}

	return selected, found
}

func fallbackPollerID(device *models.UnifiedDevice) string {
	if device == nil {
		return ""
	}

	if device.Hostname != nil && device.Hostname.PollerID != "" {
		return device.Hostname.PollerID
	}
	if device.MAC != nil && device.MAC.PollerID != "" {
		return device.MAC.PollerID
	}
	return ""
}

func fallbackAgentID(device *models.UnifiedDevice) string {
	if device == nil {
		return ""
	}

	if device.Hostname != nil && device.Hostname.AgentID != "" {
		return device.Hostname.AgentID
	}
	if device.MAC != nil && device.MAC.AgentID != "" {
		return device.MAC.AgentID
	}
	return ""
}

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

// UnifiedDeviceFromRecord converts a DeviceRecord into a UnifiedDevice view.
func UnifiedDeviceFromRecord(record *DeviceRecord) *models.UnifiedDevice {
	if record == nil {
		return nil
	}

	unified := &models.UnifiedDevice{
		DeviceID:    record.DeviceID,
		IP:          record.IP,
		IsAvailable: record.IsAvailable,
		FirstSeen:   record.FirstSeen,
		LastSeen:    record.LastSeen,
		DeviceType:  record.DeviceType,
	}

	if record.Hostname != nil {
		unified.Hostname = &models.DiscoveredField[string]{
			Value:       *record.Hostname,
			LastUpdated: record.LastSeen,
		}
	}
	if record.MAC != nil {
		unified.MAC = &models.DiscoveredField[string]{
			Value:       *record.MAC,
			LastUpdated: record.LastSeen,
		}
	}
	if len(record.Metadata) > 0 {
		unified.Metadata = &models.DiscoveredField[map[string]string]{
			Value:       cloneMetadata(record.Metadata),
			LastUpdated: record.LastSeen,
		}
	}

	if len(record.DiscoverySources) > 0 {
		unified.DiscoverySources = make([]models.DiscoverySourceInfo, 0, len(record.DiscoverySources))
		for _, src := range record.DiscoverySources {
			source := strings.TrimSpace(src)
			if source == "" {
				continue
			}
			ds := models.DiscoverySourceInfo{
				Source:     models.DiscoverySource(source),
				AgentID:    record.AgentID,
				PollerID:   record.PollerID,
				FirstSeen:  record.FirstSeen,
				LastSeen:   record.LastSeen,
				Confidence: models.GetSourceConfidence(models.DiscoverySource(source)),
			}
			unified.DiscoverySources = append(unified.DiscoverySources, ds)
		}
	}

	if record.AgentID != "" {
		unified.ServiceStatus = "active"
	}

	return unified
}

// LegacyDeviceFromRecord converts a DeviceRecord into the legacy Device representation.
func LegacyDeviceFromRecord(record *DeviceRecord) *models.Device {
	if record == nil {
		return nil
	}

	device := &models.Device{
		DeviceID:         record.DeviceID,
		AgentID:          record.AgentID,
		PollerID:         record.PollerID,
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

// UnifiedDeviceSlice converts records into UnifiedDevice representations.
func UnifiedDeviceSlice(records []*DeviceRecord) []*models.UnifiedDevice {
	if len(records) == 0 {
		return nil
	}
	out := make([]*models.UnifiedDevice, 0, len(records))
	for _, record := range records {
		if record == nil {
			continue
		}
		out = append(out, UnifiedDeviceFromRecord(record))
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
