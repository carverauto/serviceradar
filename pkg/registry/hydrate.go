package registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
)

const hydrateBatchSize = 512

var (
	errRegistryDatabaseUnavailable = errors.New("device registry database unavailable")
	errCapabilityRowNil            = errors.New("capability snapshot row is nil")
	errMissingDeviceCapability     = errors.New("missing device_id or capability")
)

// HydrateFromStore loads the current device snapshot from Proton into the in-memory registry.
// It returns the number of records loaded.
func (r *DeviceRegistry) HydrateFromStore(ctx context.Context) (int, error) {
	if r.db == nil {
		return 0, errRegistryDatabaseUnavailable
	}

	records := make([]*DeviceRecord, 0, hydrateBatchSize)

	offset := 0
	for {
		if err := ctx.Err(); err != nil {
			return 0, fmt.Errorf("hydrate aborted: %w", err)
		}

		devices, err := r.db.ListUnifiedDevices(ctx, hydrateBatchSize, offset)
		if err != nil {
			return 0, fmt.Errorf("hydrate registry: %w", err)
		}
		if len(devices) == 0 {
			break
		}

		for _, device := range devices {
			record := DeviceRecordFromUnified(device)
			if record == nil {
				continue
			}
			records = append(records, record)
		}

		offset += len(devices)
		if len(devices) < hydrateBatchSize {
			break
		}
	}

	r.replaceAll(records)

	if err := r.hydrateCapabilitySnapshots(ctx); err != nil && r.logger != nil {
		r.logger.Warn().Err(err).Msg("Failed to hydrate capability matrix from Proton")
	}

	r.reportHydrationDiscrepancy(ctx, records)

	return len(records), nil
}

func (r *DeviceRegistry) replaceAll(records []*DeviceRecord) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.devices = make(map[string]*DeviceRecord, len(records))
	r.devicesByIP = make(map[string]map[string]*DeviceRecord)
	r.devicesByMAC = make(map[string]map[string]*DeviceRecord)
	if r.searchIndex != nil {
		r.searchIndex.Reset()
	}
	r.capabilities = NewCapabilityIndex()
	r.matrix = NewCapabilityMatrix()

	for _, record := range records {
		if record == nil || record.DeviceID == "" {
			continue
		}
		clone := cloneDeviceRecord(record)
		r.devices[clone.DeviceID] = clone
		r.indexRecordLocked(clone)
		r.addToSearchIndex(clone)
	}
}

func (r *DeviceRegistry) reportHydrationDiscrepancy(ctx context.Context, records []*DeviceRecord) {
	if r.db == nil || r.logger == nil {
		return
	}

	protonCount, err := r.db.CountUnifiedDevices(ctx)
	if err != nil {
		r.logger.Warn().Err(err).Msg("Failed to count Proton devices during registry hydration diagnostics")
		return
	}

	registryCount := len(records)
	if int64(registryCount) == protonCount {
		return
	}

	known := make(map[string]struct{}, registryCount)
	for _, record := range records {
		if record == nil {
			continue
		}
		if id := strings.TrimSpace(record.DeviceID); id != "" {
			known[id] = struct{}{}
		}
	}

	missingIDs, sampleErr := r.SampleMissingDeviceIDs(ctx, known, 20)

	event := r.logger.Warn().
		Int("registry_devices", registryCount).
		Int64("proton_devices", protonCount)

	if len(missingIDs) > 0 {
		event = event.Strs("missing_device_ids", missingIDs)
	}
	if sampleErr != nil {
		event = event.Err(sampleErr)
	}

	event.Msg("Device registry hydration mismatch detected")
}

func (r *DeviceRegistry) hydrateCapabilitySnapshots(ctx context.Context) error {
	if r.db == nil {
		return errRegistryDatabaseUnavailable
	}

	const query = `
SELECT
    device_id,
    capability,
    service_id,
    service_type,
    state,
    enabled,
    last_checked,
    last_success,
    last_failure,
    failure_reason,
    metadata,
    recorded_by
FROM table(device_capability_registry)`

	rows, err := r.db.ExecuteQuery(ctx, query)
	if err != nil {
		return fmt.Errorf("fetch capability snapshots: %w", err)
	}

	snapshots := make([]*models.DeviceCapabilitySnapshot, 0, len(rows))

	for _, row := range rows {
		snapshot, snapErr := buildCapabilitySnapshot(row, r.logger)
		if snapErr != nil {
			if r.logger != nil {
				r.logger.Debug().Err(snapErr).Msg("Skipping malformed capability snapshot during hydration")
			}
			continue
		}
		snapshots = append(snapshots, snapshot)
	}

	if r.matrix == nil {
		r.matrix = NewCapabilityMatrix()
	}
	r.matrix.ReplaceAll(snapshots)

	if r.capabilities == nil {
		r.capabilities = NewCapabilityIndex()
	}

	deviceCaps := make(map[string]map[string]struct{}, len(snapshots))
	deviceLastSeen := make(map[string]time.Time, len(snapshots))
	for _, snapshot := range snapshots {
		if snapshot == nil {
			continue
		}

		deviceID := strings.TrimSpace(snapshot.DeviceID)
		capability := strings.ToLower(strings.TrimSpace(snapshot.Capability))
		if deviceID == "" || capability == "" {
			continue
		}
		if !snapshot.Enabled {
			continue
		}

		if _, ok := deviceCaps[deviceID]; !ok {
			deviceCaps[deviceID] = make(map[string]struct{})
		}
		deviceCaps[deviceID][capability] = struct{}{}

		if !snapshot.LastChecked.IsZero() {
			if current, exists := deviceLastSeen[deviceID]; !exists || snapshot.LastChecked.After(current) {
				deviceLastSeen[deviceID] = snapshot.LastChecked
			}
		}
	}

	for deviceID, capabilities := range deviceCaps {
		values := make([]string, 0, len(capabilities))
		for capability := range capabilities {
			values = append(values, capability)
		}
		sort.Strings(values)
		r.capabilities.Set(&models.CollectorCapability{
			DeviceID:     deviceID,
			Capabilities: values,
			LastSeen:     deviceLastSeen[deviceID].UTC(),
		})
	}

	return nil
}

func buildCapabilitySnapshot(row map[string]any, log logger.Logger) (*models.DeviceCapabilitySnapshot, error) {
	if row == nil {
		return nil, errCapabilityRowNil
	}

	deviceID := strings.TrimSpace(toString(row["device_id"]))
	capability := strings.ToLower(strings.TrimSpace(toString(row["capability"])))
	if deviceID == "" || capability == "" {
		return nil, errMissingDeviceCapability
	}

	snapshot := &models.DeviceCapabilitySnapshot{
		DeviceID:      deviceID,
		Capability:    capability,
		ServiceID:     strings.TrimSpace(toString(row["service_id"])),
		ServiceType:   strings.TrimSpace(toString(row["service_type"])),
		State:         strings.TrimSpace(toString(row["state"])),
		Enabled:       toBool(row["enabled"]),
		FailureReason: strings.TrimSpace(toString(row["failure_reason"])),
		RecordedBy:    strings.TrimSpace(toString(row["recorded_by"])),
		Metadata:      parseCapabilityMetadata(toString(row["metadata"]), log),
	}

	if ts, ok := toTime(row["last_checked"]); ok {
		snapshot.LastChecked = ts.UTC()
	}
	if ts, ok := toTime(row["last_success"]); ok {
		clone := ts.UTC()
		snapshot.LastSuccess = &clone
	}
	if ts, ok := toTime(row["last_failure"]); ok {
		clone := ts.UTC()
		snapshot.LastFailure = &clone
	}

	return snapshot, nil
}

func toString(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case []byte:
		return string(v)
	case fmt.Stringer:
		return v.String()
	default:
		return ""
	}
}

func toBool(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case uint8:
		return v != 0
	case int:
		return v != 0
	default:
		return false
	}
}

func toTime(value any) (time.Time, bool) {
	switch v := value.(type) {
	case time.Time:
		return v, true
	case string:
		if v == "" {
			return time.Time{}, false
		}
		if ts, err := time.Parse(time.RFC3339Nano, v); err == nil {
			return ts, true
		}
		if ts, err := time.Parse(time.RFC3339, v); err == nil {
			return ts, true
		}
		return time.Time{}, false
	default:
		return time.Time{}, false
	}
}

func parseCapabilityMetadata(raw string, log logger.Logger) map[string]any {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "{}" {
		return nil
	}

	out := make(map[string]any)
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		if log != nil {
			log.Debug().Err(err).Msg("Failed to unmarshal capability metadata; returning empty map")
		}
		return nil
	}
	return out
}
