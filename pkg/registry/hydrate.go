package registry

import (
	"context"
	"errors"
	"fmt"
)

const hydrateBatchSize = 512

var errRegistryDatabaseUnavailable = errors.New("device registry database unavailable")

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
