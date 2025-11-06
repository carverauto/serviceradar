package core

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func normalizeCapabilities(capabilities []string) []string {
	if len(capabilities) == 0 {
		return nil
	}

	set := make(map[string]struct{}, len(capabilities))
	for _, raw := range capabilities {
		capability := strings.ToLower(strings.TrimSpace(raw))
		if capability == "" {
			continue
		}
		set[capability] = struct{}{}
	}

	if len(set) == 0 {
		return nil
	}

	out := make([]string, 0, len(set))
	for capability := range set {
		out = append(out, capability)
	}
	sort.Strings(out)
	return out
}

func mergeCollectorCapabilityRecord(
	existing *models.CollectorCapability,
	deviceID string,
	capabilities []string,
	agentID, pollerID, serviceName string,
	lastSeen time.Time,
) *models.CollectorCapability {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return nil
	}

	normalized := normalizeCapabilities(capabilities)
	if existing == nil && len(normalized) == 0 {
		return nil
	}

	record := &models.CollectorCapability{
		DeviceID:     deviceID,
		Capabilities: normalized,
		AgentID:      strings.TrimSpace(agentID),
		PollerID:     strings.TrimSpace(pollerID),
		ServiceName:  strings.TrimSpace(serviceName),
		LastSeen:     lastSeen.UTC(),
	}

	if existing != nil {
		set := make(map[string]struct{}, len(existing.Capabilities)+len(normalized))
		for _, value := range existing.Capabilities {
			capability := strings.ToLower(strings.TrimSpace(value))
			if capability == "" {
				continue
			}
			set[capability] = struct{}{}
		}
		for _, capability := range normalized {
			set[capability] = struct{}{}
		}

		merged := make([]string, 0, len(set))
		for capability := range set {
			merged = append(merged, capability)
		}
		sort.Strings(merged)
		record.Capabilities = merged

		if record.AgentID == "" {
			record.AgentID = existing.AgentID
		}
		if record.PollerID == "" {
			record.PollerID = existing.PollerID
		}
		if record.ServiceName == "" {
			record.ServiceName = existing.ServiceName
		}
		if record.LastSeen.IsZero() || (existing.LastSeen.After(record.LastSeen) && !existing.LastSeen.IsZero()) {
			record.LastSeen = existing.LastSeen
		}
	}

	if record.LastSeen.IsZero() {
		record.LastSeen = time.Now().UTC()
	}
	if len(record.Capabilities) == 0 {
		return nil
	}
	return record
}

func (s *Server) upsertCollectorCapabilities(
	ctx context.Context,
	deviceID string,
	capabilities []string,
	agentID, pollerID, serviceName string,
	lastSeen time.Time,
) {
	if s == nil || s.DeviceRegistry == nil {
		return
	}

	normalized := normalizeCapabilities(capabilities)
	if len(normalized) == 0 {
		return
	}

	existing, _ := s.DeviceRegistry.GetCollectorCapabilities(ctx, deviceID)
	record := mergeCollectorCapabilityRecord(existing, deviceID, normalized, agentID, pollerID, serviceName, lastSeen)
	if record == nil {
		return
	}
	s.DeviceRegistry.SetCollectorCapabilities(ctx, record)
}

type capabilityEventWriter interface {
	InsertDeviceCapabilityEvent(ctx context.Context, event *models.DeviceCapabilityEvent) error
}

type capabilitySnapshotSetter interface {
	SetDeviceCapabilitySnapshot(ctx context.Context, snapshot *models.DeviceCapabilitySnapshot)
}

type capabilityEventInput struct {
	DeviceID      string
	Capability    string
	ServiceID     string
	ServiceType   string
	RecordedBy    string
	Enabled       bool
	Success       bool
	CheckedAt     time.Time
	FailureReason string
	Metadata      map[string]any
}

func (s *Server) recordCapabilityEvent(ctx context.Context, input *capabilityEventInput) {
	if s == nil || input == nil {
		return
	}

	event := input.toEvent()
	if event == nil {
		return
	}

	var persisted bool
	if writer, ok := s.DB.(capabilityEventWriter); ok && writer != nil {
		if err := writer.InsertDeviceCapabilityEvent(ctx, event); err != nil && s.logger != nil {
			s.logger.Warn().
				Err(err).
				Str("device_id", event.DeviceID).
				Str("capability", event.Capability).
				Msg("Failed to persist device capability event")
		} else if err == nil {
			persisted = true
		}
	} else if s.logger != nil {
		s.logger.Debug().
			Str("device_id", event.DeviceID).
			Str("capability", event.Capability).
			Msg("Database does not implement capability event writer; skipping persistence")
	}

	snapshot := &models.DeviceCapabilitySnapshot{
		DeviceID:      event.DeviceID,
		Capability:    event.Capability,
		ServiceID:     event.ServiceID,
		ServiceType:   event.ServiceType,
		State:         event.State,
		Enabled:       event.Enabled,
		LastChecked:   event.LastChecked,
		FailureReason: event.FailureReason,
		Metadata:      cloneCapabilityMetadata(event.Metadata),
		RecordedBy:    event.RecordedBy,
	}

	if event.LastSuccess != nil {
		clone := event.LastSuccess.UTC()
		snapshot.LastSuccess = &clone
	}
	if event.LastFailure != nil {
		clone := event.LastFailure.UTC()
		snapshot.LastFailure = &clone
	}

	if setter, ok := s.DeviceRegistry.(capabilitySnapshotSetter); ok && setter != nil {
		setter.SetDeviceCapabilitySnapshot(ctx, snapshot)
	}

	if persisted {
		recordCapabilityEventMetric(ctx, event)
	}
}

func (input *capabilityEventInput) toEvent() *models.DeviceCapabilityEvent {
	if input == nil {
		return nil
	}

	deviceID := strings.TrimSpace(input.DeviceID)
	capability := strings.ToLower(strings.TrimSpace(input.Capability))
	if deviceID == "" || capability == "" {
		return nil
	}

	state := "failed"
	if input.Success {
		state = "ok"
	}

	timestamp := input.CheckedAt
	if timestamp.IsZero() {
		timestamp = time.Now().UTC()
	} else {
		timestamp = timestamp.UTC()
	}

	event := &models.DeviceCapabilityEvent{
		DeviceID:      deviceID,
		Capability:    capability,
		ServiceID:     strings.TrimSpace(input.ServiceID),
		ServiceType:   strings.TrimSpace(input.ServiceType),
		State:         state,
		Enabled:       input.Enabled,
		LastChecked:   timestamp,
		FailureReason: strings.TrimSpace(input.FailureReason),
		Metadata:      cloneCapabilityMetadata(input.Metadata),
		RecordedBy:    strings.TrimSpace(input.RecordedBy),
	}

	if input.Success {
		clone := timestamp
		event.LastSuccess = &clone
		if event.FailureReason == "" {
			event.FailureReason = ""
		}
	} else {
		clone := timestamp
		event.LastFailure = &clone
		if event.FailureReason == "" {
			event.FailureReason = "unavailable"
		}
	}

	return event
}

func cloneCapabilityMetadata(src map[string]any) map[string]any {
	if len(src) == 0 {
		return nil
	}
	dst := make(map[string]any, len(src))
	for k, v := range src {
		dst[k] = v
	}
	return dst
}
