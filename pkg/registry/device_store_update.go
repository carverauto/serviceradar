package registry

import (
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func (r *DeviceRegistry) applyRegistryStore(updates []*models.DeviceUpdate, tombstones []*models.DeviceUpdate) {
	for _, update := range updates {
		r.applyDeviceUpdate(update)
	}
	for _, tombstone := range tombstones {
		r.applyTombstone(tombstone)
	}
}

func (r *DeviceRegistry) applyDeviceUpdate(update *models.DeviceUpdate) {
	if update == nil {
		return
	}

	deviceID := strings.TrimSpace(update.DeviceID)
	if deviceID == "" {
		return
	}

	if isDeletionMetadata(update.Metadata) {
		r.DeleteDeviceRecord(deviceID)
		return
	}

	existing, _ := r.GetDeviceRecord(deviceID)
	record := deviceRecordFromUpdate(update, existing)
	if record == nil {
		return
	}

	r.UpsertDeviceRecord(record)
}

func (r *DeviceRegistry) applyTombstone(update *models.DeviceUpdate) {
	if update == nil {
		return
	}
	deviceID := strings.TrimSpace(update.DeviceID)
	if deviceID == "" {
		return
	}
	r.DeleteDeviceRecord(deviceID)
}

func deviceRecordFromUpdate(update *models.DeviceUpdate, existing *DeviceRecord) *DeviceRecord {
	if update == nil {
		return nil
	}

	deviceID := strings.TrimSpace(update.DeviceID)
	if deviceID == "" {
		return nil
	}

	var record *DeviceRecord
	if existing != nil {
		record = existing
	} else {
		record = &DeviceRecord{
			DeviceID: deviceID,
		}
	}

	if ip := strings.TrimSpace(update.IP); ip != "" {
		record.IP = ip
	}
	if pollerID := strings.TrimSpace(update.PollerID); pollerID != "" {
		record.PollerID = pollerID
	}
	if agentID := strings.TrimSpace(update.AgentID); agentID != "" {
		record.AgentID = agentID
	}

	if update.Hostname != nil {
		if hostname := strings.TrimSpace(*update.Hostname); hostname != "" {
			record.Hostname = &hostname
		}
	}
	if update.MAC != nil {
		if mac := strings.TrimSpace(*update.MAC); mac != "" {
			upper := strings.ToUpper(mac)
			record.MAC = &upper
		}
	}

	record.Metadata = mergeMetadata(record.Metadata, update.Metadata)
	record.DiscoverySources = mergeDiscoverySources(record.DiscoverySources, string(update.Source))
	record.DeviceType = updateDeviceType(record.DeviceType, record.Metadata)
	record.IsAvailable = update.IsAvailable

	updateTimestamp := update.Timestamp.UTC()
	if updateTimestamp.IsZero() {
		updateTimestamp = time.Now().UTC()
	}

	if record.LastSeen.IsZero() || updateTimestamp.After(record.LastSeen) {
		record.LastSeen = updateTimestamp
	}

	if firstSeen, ok := firstSeenFromMetadata(update.Metadata); ok {
		if record.FirstSeen.IsZero() || firstSeen.Before(record.FirstSeen) {
			record.FirstSeen = firstSeen
		}
	} else if record.FirstSeen.IsZero() {
		record.FirstSeen = updateTimestamp
	}

	if integrationID := extractIntegrationID(record.Metadata); integrationID != "" {
		val := integrationID
		record.IntegrationID = &val
	}

	if collectorAgent := extractCollectorAgentID(record.Metadata); collectorAgent != "" {
		val := collectorAgent
		record.CollectorAgentID = &val
	}

	return record
}

func mergeDiscoverySources(existing []string, newSource string) []string {
	newSource = strings.TrimSpace(newSource)
	if newSource == "" {
		return existing
	}

	for _, src := range existing {
		if strings.EqualFold(src, newSource) {
			return existing
		}
	}

	return append(existing, newSource)
}

func mergeMetadata(dest map[string]string, src map[string]string) map[string]string {
	if len(src) == 0 {
		return dest
	}

	if dest == nil {
		dest = make(map[string]string, len(src))
	}

	for key, value := range src {
		trimmedKey := strings.TrimSpace(key)
		if trimmedKey == "" {
			continue
		}
		dest[trimmedKey] = value
	}

	return dest
}

func updateDeviceType(existing string, metadata map[string]string) string {
	if metadata == nil {
		return existing
	}
	if deviceType := strings.TrimSpace(metadata["device_type"]); deviceType != "" {
		return deviceType
	}
	return existing
}

func extractIntegrationID(metadata map[string]string) string {
	if metadata == nil {
		return ""
	}
	if val := strings.TrimSpace(metadata["integration_id"]); val != "" {
		return val
	}
	return ""
}

func extractCollectorAgentID(metadata map[string]string) string {
	if metadata == nil {
		return ""
	}
	if val := strings.TrimSpace(metadata["collector_agent_id"]); val != "" {
		return val
	}
	return ""
}

func firstSeenFromMetadata(metadata map[string]string) (time.Time, bool) {
	if metadata == nil {
		return time.Time{}, false
	}

	for _, key := range []string{"_first_seen", "first_seen"} {
		if val := strings.TrimSpace(metadata[key]); val != "" {
			if ts, ok := parseFirstSeenTimestamp(val); ok {
				return ts, true
			}
		}
	}

	return time.Time{}, false
}

func isDeletionMetadata(metadata map[string]string) bool {
	if metadata == nil {
		return false
	}
	for _, key := range []string{"_deleted", "deleted"} {
		if val, ok := metadata[key]; ok && strings.EqualFold(val, "true") {
			return true
		}
	}
	return false
}
