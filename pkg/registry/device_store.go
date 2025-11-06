package registry

import (
	"sort"
	"strings"
)

// UpsertDeviceRecord inserts or replaces the registry entry for a device and maintains lookup indexes.
func (r *DeviceRegistry) UpsertDeviceRecord(record *DeviceRecord) {
	if record == nil || strings.TrimSpace(record.DeviceID) == "" {
		return
	}

	input := cloneDeviceRecord(record)

	r.mu.Lock()
	defer r.mu.Unlock()

	if existing, ok := r.devices[input.DeviceID]; ok {
		r.removeIndexesLocked(existing)
		r.removeFromSearchIndex(existing)
	}

	r.devices[input.DeviceID] = input
	r.indexRecordLocked(input)
	r.addToSearchIndex(input)
}

func (r *DeviceRegistry) addToSearchIndex(record *DeviceRecord) {
	if record == nil || r.searchIndex == nil {
		return
	}
	r.searchIndex.Add(record.DeviceID, searchTextForRecord(record))
}

// DeleteDeviceRecord removes a device from the registry indexes.
func (r *DeviceRegistry) DeleteDeviceRecord(deviceID string) {
	if strings.TrimSpace(deviceID) == "" {
		return
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	existing, ok := r.devices[deviceID]
	if !ok {
		return
	}

	r.removeIndexesLocked(existing)
	r.removeFromSearchIndex(existing)
	delete(r.devices, deviceID)
}

func (r *DeviceRegistry) removeFromSearchIndex(record *DeviceRecord) {
	if record == nil || r.searchIndex == nil {
		return
	}
	r.searchIndex.Remove(record.DeviceID)
}

// GetDeviceRecord retrieves a device by ID.
func (r *DeviceRegistry) GetDeviceRecord(deviceID string) (*DeviceRecord, bool) {
	if strings.TrimSpace(deviceID) == "" {
		return nil, false
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	record, ok := r.devices[deviceID]
	if !ok {
		return nil, false
	}
	return cloneDeviceRecord(record), true
}

// FindDevicesByIP returns all devices currently indexed by the given IP.
func (r *DeviceRegistry) FindDevicesByIP(ip string) []*DeviceRecord {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return nil
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	return cloneRecordBucket(r.devicesByIP[ip])
}

// FindDevicesByMAC returns all devices matching the given MAC address.
func (r *DeviceRegistry) FindDevicesByMAC(mac string) []*DeviceRecord {
	mac = strings.TrimSpace(mac)
	if mac == "" {
		return nil
	}

	normalized := strings.ToUpper(mac)

	r.mu.RLock()
	defer r.mu.RUnlock()

	return cloneRecordBucket(r.devicesByMAC[normalized])
}

func (r *DeviceRegistry) indexRecordLocked(record *DeviceRecord) {
	if record == nil {
		return
	}

	if ip := strings.TrimSpace(record.IP); ip != "" {
		bucket := r.devicesByIP[ip]
		if bucket == nil {
			bucket = make(map[string]*DeviceRecord)
			r.devicesByIP[ip] = bucket
		}
		bucket[record.DeviceID] = record
	}

	for _, mac := range macKeysFromRecord(record) {
		bucket := r.devicesByMAC[mac]
		if bucket == nil {
			bucket = make(map[string]*DeviceRecord)
			r.devicesByMAC[mac] = bucket
		}
		bucket[record.DeviceID] = record
	}
}

func (r *DeviceRegistry) removeIndexesLocked(record *DeviceRecord) {
	if record == nil {
		return
	}

	if ip := strings.TrimSpace(record.IP); ip != "" {
		if bucket, ok := r.devicesByIP[ip]; ok {
			delete(bucket, record.DeviceID)
			if len(bucket) == 0 {
				delete(r.devicesByIP, ip)
			}
		}
	}

	for _, mac := range macKeysFromRecord(record) {
		if bucket, ok := r.devicesByMAC[mac]; ok {
			delete(bucket, record.DeviceID)
			if len(bucket) == 0 {
				delete(r.devicesByMAC, mac)
			}
		}
	}
}

func cloneRecordBucket(bucket map[string]*DeviceRecord) []*DeviceRecord {
	if len(bucket) == 0 {
		return nil
	}

	deviceIDs := make([]string, 0, len(bucket))
	for id := range bucket {
		deviceIDs = append(deviceIDs, id)
	}
	sort.Strings(deviceIDs)

	result := make([]*DeviceRecord, 0, len(deviceIDs))
	for _, id := range deviceIDs {
		if rec := bucket[id]; rec != nil {
			result = append(result, cloneDeviceRecord(rec))
		}
	}
	return result
}

func cloneDeviceRecord(src *DeviceRecord) *DeviceRecord {
	if src == nil {
		return nil
	}

	dst := *src

	if src.Hostname != nil {
		hostname := *src.Hostname
		dst.Hostname = &hostname
	}
	if src.MAC != nil {
		mac := *src.MAC
		dst.MAC = &mac
	}
	if src.IntegrationID != nil {
		integrationID := *src.IntegrationID
		dst.IntegrationID = &integrationID
	}
	if src.CollectorAgentID != nil {
		collectorAgentID := *src.CollectorAgentID
		dst.CollectorAgentID = &collectorAgentID
	}

	if len(src.DiscoverySources) > 0 {
		dst.DiscoverySources = append([]string(nil), src.DiscoverySources...)
	}
	if len(src.Capabilities) > 0 {
		dst.Capabilities = append([]string(nil), src.Capabilities...)
	}
	if len(src.Metadata) > 0 {
		meta := make(map[string]string, len(src.Metadata))
		for k, v := range src.Metadata {
			meta[k] = v
		}
		dst.Metadata = meta
	}

	return &dst
}

func macKeysFromRecord(record *DeviceRecord) []string {
	if record == nil || record.MAC == nil || strings.TrimSpace(*record.MAC) == "" {
		return nil
	}

	raw := parseMACList(*record.MAC)
	if len(raw) == 0 {
		return nil
	}

	keys := make([]string, 0, len(raw))
	for _, mac := range raw {
		keys = append(keys, strings.ToUpper(mac))
	}
	return keys
}

func (r *DeviceRegistry) snapshotRecords() []*DeviceRecord {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if len(r.devices) == 0 {
		return nil
	}

	out := make([]*DeviceRecord, 0, len(r.devices))
	for _, record := range r.devices {
		if record == nil {
			continue
		}
		out = append(out, cloneDeviceRecord(record))
	}
	return out
}

// SnapshotRecords returns a defensive copy of all device records currently held in memory.
func (r *DeviceRegistry) SnapshotRecords() []*DeviceRecord {
	return r.snapshotRecords()
}

func searchTextForRecord(record *DeviceRecord) string {
	if record == nil {
		return ""
	}

	parts := make([]string, 0, 16)
	parts = append(parts, record.DeviceID, record.IP, record.PollerID, record.AgentID)
	if record.Hostname != nil {
		parts = append(parts, *record.Hostname)
	}
	if record.MAC != nil {
		parts = append(parts, *record.MAC)
	}
	parts = append(parts, record.DiscoverySources...)
	parts = append(parts, record.Capabilities...)

	for key, value := range record.Metadata {
		if key == "" && value == "" {
			continue
		}
		parts = append(parts, key)
		parts = append(parts, value)
	}

	return strings.ToLower(strings.Join(parts, " "))
}
