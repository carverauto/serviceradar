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
