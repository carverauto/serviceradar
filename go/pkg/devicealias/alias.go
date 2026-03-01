package devicealias

import (
	"sort"
	"strings"
)

// Record captures alias metadata derived from device updates or unified device rows.
type Record struct {
	LastSeenAt       string
	CollectorIP      string
	CurrentServiceID string
	CurrentIP        string
	Services         map[string]string
	IPs              map[string]string
}

// FromMetadata constructs a Record from the provided metadata map. Returns nil when no alias fields exist.
func FromMetadata(metadata map[string]string) *Record {
	if len(metadata) == 0 {
		return nil
	}

	record := &Record{
		Services: make(map[string]string),
		IPs:      make(map[string]string),
	}

	trim := strings.TrimSpace

	record.LastSeenAt = trim(metadata["_alias_last_seen_at"])
	record.CollectorIP = trim(metadata["_alias_collector_ip"])
	record.CurrentServiceID = trim(metadata["_alias_last_seen_service_id"])
	record.CurrentIP = trim(metadata["_alias_last_seen_ip"])

	if record.CurrentServiceID != "" {
		timestamp := trim(metadata["service_alias:"+record.CurrentServiceID])
		if timestamp == "" {
			timestamp = record.LastSeenAt
		}
		record.Services[record.CurrentServiceID] = timestamp
	}

	if record.CurrentIP != "" {
		timestamp := trim(metadata["ip_alias:"+record.CurrentIP])
		if timestamp == "" {
			timestamp = record.LastSeenAt
		}
		record.IPs[record.CurrentIP] = timestamp
	}

	for key, raw := range metadata {
		switch {
		case strings.HasPrefix(key, "service_alias:"):
			id := trim(strings.TrimPrefix(key, "service_alias:"))
			if id == "" {
				continue
			}
			value := trim(raw)
			if value == "" {
				value = record.LastSeenAt
			}
			record.Services[id] = value
		case strings.HasPrefix(key, "ip_alias:"):
			ip := trim(strings.TrimPrefix(key, "ip_alias:"))
			if ip == "" {
				continue
			}
			value := trim(raw)
			if value == "" {
				value = record.LastSeenAt
			}
			record.IPs[ip] = value
		}
	}

	if record.empty() {
		return nil
	}

	return record
}

// Clone creates a defensive copy of the Record.
func (r *Record) Clone() *Record {
	if r == nil {
		return nil
	}
	clone := &Record{
		LastSeenAt:       r.LastSeenAt,
		CollectorIP:      r.CollectorIP,
		CurrentServiceID: r.CurrentServiceID,
		CurrentIP:        r.CurrentIP,
	}
	if len(r.Services) > 0 {
		clone.Services = make(map[string]string, len(r.Services))
		for k, v := range r.Services {
			clone.Services[k] = v
		}
	} else {
		clone.Services = make(map[string]string)
	}
	if len(r.IPs) > 0 {
		clone.IPs = make(map[string]string, len(r.IPs))
		for k, v := range r.IPs {
			clone.IPs[k] = v
		}
	} else {
		clone.IPs = make(map[string]string)
	}
	return clone
}

// Equal reports whether two Records contain the same alias metadata (order-insensitive).
func Equal(a, b *Record) bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	if strings.TrimSpace(a.LastSeenAt) != strings.TrimSpace(b.LastSeenAt) {
		return false
	}
	if strings.TrimSpace(a.CollectorIP) != strings.TrimSpace(b.CollectorIP) {
		return false
	}
	if strings.TrimSpace(a.CurrentServiceID) != strings.TrimSpace(b.CurrentServiceID) {
		return false
	}
	if strings.TrimSpace(a.CurrentIP) != strings.TrimSpace(b.CurrentIP) {
		return false
	}
	return mapsEqual(a.Services, b.Services) && mapsEqual(a.IPs, b.IPs)
}

// FormatMap renders a deterministic string representation of a map for logging or metadata.
func FormatMap(values map[string]string) string {
	if len(values) == 0 {
		return ""
	}
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		v := strings.TrimSpace(values[k])
		if v != "" {
			parts = append(parts, k+"="+v)
		} else {
			parts = append(parts, k)
		}
	}
	return strings.Join(parts, ",")
}

func (r *Record) empty() bool {
	return strings.TrimSpace(r.LastSeenAt) == "" &&
		strings.TrimSpace(r.CollectorIP) == "" &&
		strings.TrimSpace(r.CurrentServiceID) == "" &&
		strings.TrimSpace(r.CurrentIP) == "" &&
		len(r.Services) == 0 &&
		len(r.IPs) == 0
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for key, valA := range a {
		valB, ok := b[key]
		if !ok {
			return false
		}
		if strings.TrimSpace(valA) != strings.TrimSpace(valB) {
			return false
		}
	}
	return true
}
