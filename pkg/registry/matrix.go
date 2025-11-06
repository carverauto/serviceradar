package registry

import (
	"strings"
	"sync"

	"github.com/carverauto/serviceradar/pkg/models"
)

type capabilityKey struct {
	capability string
	serviceID  string
}

// CapabilityMatrix maintains the latest capability snapshot for each
// Device ⇄ Capability ⇄ Service tuple.
type CapabilityMatrix struct {
	mu      sync.RWMutex
	devices map[string]map[capabilityKey]*models.DeviceCapabilitySnapshot
}

// NewCapabilityMatrix constructs an empty capability matrix.
func NewCapabilityMatrix() *CapabilityMatrix {
	return &CapabilityMatrix{
		devices: make(map[string]map[capabilityKey]*models.DeviceCapabilitySnapshot),
	}
}

// Set records or updates the snapshot for the provided capability tuple.
func (m *CapabilityMatrix) Set(snapshot *models.DeviceCapabilitySnapshot) {
	if m == nil || snapshot == nil {
		return
	}

	deviceID := strings.TrimSpace(snapshot.DeviceID)
	capability := strings.ToLower(strings.TrimSpace(snapshot.Capability))
	serviceID := strings.TrimSpace(snapshot.ServiceID)
	if deviceID == "" || capability == "" {
		return
	}

	key := capabilityKey{
		capability: capability,
		serviceID:  serviceID,
	}

	clone := cloneCapabilitySnapshot(snapshot)
	clone.DeviceID = deviceID
	clone.Capability = capability
	clone.ServiceID = serviceID

	m.mu.Lock()
	defer m.mu.Unlock()

	if _, ok := m.devices[deviceID]; !ok {
		m.devices[deviceID] = make(map[capabilityKey]*models.DeviceCapabilitySnapshot)
	}

	m.devices[deviceID][key] = clone
}

// Get returns the snapshot for the specified tuple if present.
func (m *CapabilityMatrix) Get(deviceID, capability, serviceID string) (*models.DeviceCapabilitySnapshot, bool) {
	if m == nil {
		return nil, false
	}

	deviceID = strings.TrimSpace(deviceID)
	capability = strings.ToLower(strings.TrimSpace(capability))
	serviceID = strings.TrimSpace(serviceID)
	if deviceID == "" || capability == "" {
		return nil, false
	}

	key := capabilityKey{
		capability: capability,
		serviceID:  serviceID,
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	perDevice, ok := m.devices[deviceID]
	if !ok {
		return nil, false
	}

	if snapshot, ok := perDevice[key]; ok && snapshot != nil {
		return cloneCapabilitySnapshot(snapshot), true
	}

	return nil, false
}

// ListForDevice returns all capability snapshots tracked for the device.
func (m *CapabilityMatrix) ListForDevice(deviceID string) []*models.DeviceCapabilitySnapshot {
	if m == nil {
		return nil
	}

	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return nil
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	perDevice, ok := m.devices[deviceID]
	if !ok || len(perDevice) == 0 {
		return nil
	}

	results := make([]*models.DeviceCapabilitySnapshot, 0, len(perDevice))
	for _, snapshot := range perDevice {
		if snapshot == nil {
			continue
		}
		results = append(results, cloneCapabilitySnapshot(snapshot))
	}
	return results
}

// ReplaceAll swaps the matrix contents with the provided snapshots.
func (m *CapabilityMatrix) ReplaceAll(snapshots []*models.DeviceCapabilitySnapshot) {
	if m == nil {
		return
	}

	next := make(map[string]map[capabilityKey]*models.DeviceCapabilitySnapshot)
	for _, snapshot := range snapshots {
		if snapshot == nil {
			continue
		}
		deviceID := strings.TrimSpace(snapshot.DeviceID)
		capability := strings.ToLower(strings.TrimSpace(snapshot.Capability))
		serviceID := strings.TrimSpace(snapshot.ServiceID)
		if deviceID == "" || capability == "" {
			continue
		}

		key := capabilityKey{
			capability: capability,
			serviceID:  serviceID,
		}

		clone := cloneCapabilitySnapshot(snapshot)
		clone.DeviceID = deviceID
		clone.Capability = capability
		clone.ServiceID = serviceID

		if _, ok := next[deviceID]; !ok {
			next[deviceID] = make(map[capabilityKey]*models.DeviceCapabilitySnapshot)
		}
		next[deviceID][key] = clone
	}

	m.mu.Lock()
	m.devices = next
	m.mu.Unlock()
}

func cloneCapabilitySnapshot(src *models.DeviceCapabilitySnapshot) *models.DeviceCapabilitySnapshot {
	if src == nil {
		return nil
	}

	dst := &models.DeviceCapabilitySnapshot{
		DeviceID:      src.DeviceID,
		ServiceID:     src.ServiceID,
		ServiceType:   src.ServiceType,
		Capability:    src.Capability,
		State:         src.State,
		Enabled:       src.Enabled,
		FailureReason: src.FailureReason,
		RecordedBy:    src.RecordedBy,
		LastChecked:   src.LastChecked,
	}

	if src.Metadata != nil {
		dst.Metadata = make(map[string]any, len(src.Metadata))
		for k, v := range src.Metadata {
			dst.Metadata[k] = v
		}
	}

	if src.LastSuccess != nil {
		clone := src.LastSuccess.UTC()
		dst.LastSuccess = &clone
	}

	if src.LastFailure != nil {
		clone := src.LastFailure.UTC()
		dst.LastFailure = &clone
	}

	if !dst.LastChecked.IsZero() {
		dst.LastChecked = dst.LastChecked.UTC()
	}

	return dst
}
