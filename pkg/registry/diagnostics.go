package registry

import (
	"context"
	"strings"
)

// SampleMissingDeviceIDs returns up to sampleLimit device IDs that exist in Proton but are absent
// from the provided knownIDs set (typically the current registry snapshot). This is intended for
// diagnostics and should only be called when discrepancies are detected.
func (r *DeviceRegistry) SampleMissingDeviceIDs(ctx context.Context, knownIDs map[string]struct{}, sampleLimit int) ([]string, error) {
	if sampleLimit <= 0 {
		return nil, nil
	}
	if r.db == nil {
		return nil, errRegistryDatabaseUnavailable
	}

	// Avoid panics if the caller passes nil.
	if knownIDs == nil {
		knownIDs = map[string]struct{}{}
	}

	missing := make([]string, 0, sampleLimit)
	offset := 0

	for len(missing) < sampleLimit {
		devices, err := r.db.ListUnifiedDevices(ctx, hydrateBatchSize, offset)
		if err != nil {
			return missing, err
		}
		if len(devices) == 0 {
			break
		}

		for _, device := range devices {
			if device == nil {
				continue
			}
			id := strings.TrimSpace(device.DeviceID)
			if id == "" {
				continue
			}
			if _, exists := knownIDs[id]; !exists {
				missing = append(missing, id)
				if len(missing) >= sampleLimit {
					break
				}
			}
		}

		offset += len(devices)
	}

	return missing, nil
}
