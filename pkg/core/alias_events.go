package core

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/devicealias"
	"github.com/carverauto/serviceradar/pkg/models"
)

func (s *Server) buildAliasLifecycleEvents(ctx context.Context, updates []*models.DeviceUpdate) ([]*models.DeviceLifecycleEventData, error) {
	if len(updates) == 0 || s.DB == nil {
		return nil, nil
	}

	aliasUpdates := make(map[string]*models.DeviceUpdate)
	for _, update := range updates {
		if update == nil {
			continue
		}

		deviceID := strings.TrimSpace(update.DeviceID)
		if deviceID == "" || !hasAliasMetadata(update.Metadata) {
			continue
		}

		if existing, ok := aliasUpdates[deviceID]; ok {
			if existing.Timestamp.After(update.Timestamp) {
				continue
			}
		}
		aliasUpdates[deviceID] = update
	}

	if len(aliasUpdates) == 0 {
		return nil, nil
	}

	deviceIDs := make([]string, 0, len(aliasUpdates))
	for id := range aliasUpdates {
		deviceIDs = append(deviceIDs, id)
	}
	sort.Strings(deviceIDs)

	existingRecords := make(map[string]*devicealias.Record, len(deviceIDs))
	devices, err := s.DB.GetUnifiedDevicesByIPsOrIDs(ctx, nil, deviceIDs)
	if err != nil {
		return nil, err
	}

	for _, device := range devices {
		if device == nil || device.Metadata == nil || device.Metadata.Value == nil {
			continue
		}
		if record := devicealias.FromMetadata(device.Metadata.Value); record != nil {
			existingRecords[strings.TrimSpace(device.DeviceID)] = record
		}
	}

	events := make([]*models.DeviceLifecycleEventData, 0, len(aliasUpdates))

	for deviceID, update := range aliasUpdates {
		record := devicealias.FromMetadata(update.Metadata)
		if record == nil {
			continue
		}

		previous := existingRecords[deviceID]
		if !aliasChangeDetected(previous, record) {
			continue
		}

		event := &models.DeviceLifecycleEventData{
			DeviceID:  deviceID,
			Partition: pickPartition(update.Partition, deviceID),
			Action:    "alias_updated",
			Reason:    "alias_change",
			Timestamp: updateTimestamp(update.Timestamp),
			Severity:  "Low",
			Level:     6,
			Metadata:  buildAliasEventMetadata(record, previous),
		}

		events = append(events, event)
	}

	return events, nil
}

func hasAliasMetadata(metadata map[string]string) bool {
	if len(metadata) == 0 {
		return false
	}
	for key := range metadata {
		switch {
		case key == "_alias_last_seen_service_id",
			key == "_alias_last_seen_ip",
			key == "_alias_collector_ip",
			strings.HasPrefix(key, "service_alias:"),
			strings.HasPrefix(key, "ip_alias:"):
			return true
		}
	}
	return false
}

func aliasChangeDetected(previous, current *devicealias.Record) bool {
	if current == nil {
		return false
	}
	if previous == nil {
		return true
	}

	if strings.TrimSpace(previous.CurrentServiceID) != strings.TrimSpace(current.CurrentServiceID) {
		return true
	}
	if strings.TrimSpace(previous.CurrentIP) != strings.TrimSpace(current.CurrentIP) {
		return true
	}
	if strings.TrimSpace(previous.CollectorIP) != strings.TrimSpace(current.CollectorIP) {
		return true
	}

	if newKeysIntroduced(previous.Services, current.Services) {
		return true
	}
	if newKeysIntroduced(previous.IPs, current.IPs) {
		return true
	}

	return false
}

func newKeysIntroduced(previous, current map[string]string) bool {
	for key := range current {
		if _, ok := previous[key]; !ok {
			return true
		}
	}
	return false
}

func buildAliasEventMetadata(current, previous *devicealias.Record) map[string]string {
	metadata := make(map[string]string)

	if current.LastSeenAt != "" {
		metadata["alias_last_seen_at"] = current.LastSeenAt
	}
	if current.CurrentServiceID != "" {
		metadata["alias_current_service_id"] = current.CurrentServiceID
	}
	if current.CurrentIP != "" {
		metadata["alias_current_ip"] = current.CurrentIP
	}
	if current.CollectorIP != "" {
		metadata["alias_collector_ip"] = current.CollectorIP
	}

	if len(current.Services) > 0 {
		metadata["alias_services"] = devicealias.FormatMap(current.Services)
	}
	if len(current.IPs) > 0 {
		metadata["alias_ips"] = devicealias.FormatMap(current.IPs)
	}

	if previous != nil {
		if previous.CurrentServiceID != "" && previous.CurrentServiceID != current.CurrentServiceID {
			metadata["previous_service_id"] = previous.CurrentServiceID
		}
		if previous.CurrentIP != "" && previous.CurrentIP != current.CurrentIP {
			metadata["previous_ip"] = previous.CurrentIP
		}
		if previous.CollectorIP != "" && previous.CollectorIP != current.CollectorIP {
			metadata["previous_collector_ip"] = previous.CollectorIP
		}
	}

	return metadata
}

func pickPartition(partition, deviceID string) string {
	partition = strings.TrimSpace(partition)
	if partition != "" {
		return partition
	}
	if deviceID == "" {
		return ""
	}
	if idx := strings.Index(deviceID, ":"); idx > 0 {
		return strings.TrimSpace(deviceID[:idx])
	}
	return ""
}

func updateTimestamp(ts time.Time) time.Time {
	if ts.IsZero() {
		return time.Now().UTC()
	}
	return ts.UTC()
}
