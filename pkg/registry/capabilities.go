package registry

import (
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// CapabilityIndex maintains an in-memory index of collector capabilities keyed
// by device and capability type.
type CapabilityIndex struct {
	mu           sync.RWMutex
	byDevice     map[string]*models.CollectorCapability
	byCapability map[string]map[string]struct{}
	now          func() time.Time
}

// NewCapabilityIndex creates an empty capability index.
func NewCapabilityIndex() *CapabilityIndex {
	return &CapabilityIndex{
		byDevice:     make(map[string]*models.CollectorCapability),
		byCapability: make(map[string]map[string]struct{}),
		now:          time.Now,
	}
}

// Set injects or replaces the capability record for a device. Passing a record
// with an empty capability slice removes any existing entry for the device.
func (idx *CapabilityIndex) Set(record *models.CollectorCapability) {
	if record == nil {
		return
	}

	deviceID := strings.TrimSpace(record.DeviceID)
	if deviceID == "" {
		return
	}

	normalized := cloneCapability(record)
	normalized.DeviceID = deviceID
	normalized.Capabilities = dedupeCapabilities(normalized.Capabilities)
	if normalized.LastSeen.IsZero() {
		normalized.LastSeen = idx.now().UTC()
	} else {
		normalized.LastSeen = normalized.LastSeen.UTC()
	}

	idx.mu.Lock()
	defer idx.mu.Unlock()

	if len(normalized.Capabilities) == 0 {
		idx.removeLocked(deviceID)
		return
	}

	if existing, ok := idx.byDevice[deviceID]; ok {
		idx.pruneCapabilitiesLocked(deviceID, existing.Capabilities)
	}

	idx.byDevice[deviceID] = normalized
	for _, capability := range normalized.Capabilities {
		if capability == "" {
			continue
		}
		if _, ok := idx.byCapability[capability]; !ok {
			idx.byCapability[capability] = make(map[string]struct{})
		}
		idx.byCapability[capability][deviceID] = struct{}{}
	}
}

// Get returns a defensive copy of the capability record for the given device.
func (idx *CapabilityIndex) Get(deviceID string) (*models.CollectorCapability, bool) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return nil, false
	}

	idx.mu.RLock()
	defer idx.mu.RUnlock()

	record, ok := idx.byDevice[deviceID]
	if !ok || record == nil {
		return nil, false
	}

	return cloneCapability(record), true
}

// HasCapability reports whether the device currently has the provided capability.
func (idx *CapabilityIndex) HasCapability(deviceID, capability string) bool {
	deviceID = strings.TrimSpace(deviceID)
	capability = normalizeCapability(capability)
	if deviceID == "" || capability == "" {
		return false
	}

	idx.mu.RLock()
	defer idx.mu.RUnlock()

	if devices, ok := idx.byCapability[capability]; ok {
		_, present := devices[deviceID]
		return present
	}

	return false
}

// ListDevicesWithCapability returns the device IDs that expose the requested capability.
func (idx *CapabilityIndex) ListDevicesWithCapability(capability string) []string {
	capability = normalizeCapability(capability)
	if capability == "" {
		return nil
	}

	idx.mu.RLock()
	defer idx.mu.RUnlock()

	devices, ok := idx.byCapability[capability]
	if !ok || len(devices) == 0 {
		return nil
	}

	results := make([]string, 0, len(devices))
	for deviceID := range devices {
		results = append(results, deviceID)
	}
	sort.Strings(results)
	return results
}

// removeLocked deletes a device entry and cleans up reverse indexes. Lock must be held.
func (idx *CapabilityIndex) removeLocked(deviceID string) {
	if existing, ok := idx.byDevice[deviceID]; ok && existing != nil {
		idx.pruneCapabilitiesLocked(deviceID, existing.Capabilities)
	}
	delete(idx.byDevice, deviceID)
}

// pruneCapabilitiesLocked removes device references from capability sets. Lock must be held.
func (idx *CapabilityIndex) pruneCapabilitiesLocked(deviceID string, capabilities []string) {
	for _, capability := range capabilities {
		capability = normalizeCapability(capability)
		if capability == "" {
			continue
		}
		if set, ok := idx.byCapability[capability]; ok {
			delete(set, deviceID)
			if len(set) == 0 {
				delete(idx.byCapability, capability)
			}
		}
	}
}

func cloneCapability(src *models.CollectorCapability) *models.CollectorCapability {
	if src == nil {
		return nil
	}

	dst := &models.CollectorCapability{
		DeviceID:    src.DeviceID,
		AgentID:     src.AgentID,
		PollerID:    src.PollerID,
		LastSeen:    src.LastSeen,
		ServiceName: src.ServiceName,
	}

	if len(src.Capabilities) > 0 {
		dst.Capabilities = make([]string, len(src.Capabilities))
		copy(dst.Capabilities, src.Capabilities)
	}

	return dst
}

func dedupeCapabilities(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	normalized := make(map[string]struct{}, len(values))
	for _, value := range values {
		if cap := normalizeCapability(value); cap != "" {
			normalized[cap] = struct{}{}
		}
	}

	if len(normalized) == 0 {
		return nil
	}

	out := make([]string, 0, len(normalized))
	for capability := range normalized {
		out = append(out, capability)
	}
	sort.Strings(out)
	return out
}

func normalizeCapability(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
