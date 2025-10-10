package deviceupdate

import (
	"sort"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

const (
	// maxMetadataValueBytes limits a single metadata entry to 64KiB to stay well under Proton row limits.
	maxMetadataValueBytes = 64 * 1024
	// maxMetadataTotalBytes caps total metadata payload to 512KiB per device sighting.
	maxMetadataTotalBytes = 512 * 1024
	minMetadataValueBytes = 32
)

type metadataEntry struct {
	key       string
	size      int
	priority  int
	protected bool
}

// SanitizeMetadata trims oversized metadata in-place to keep device update payloads bounded.
func SanitizeMetadata(update *models.DeviceUpdate) {
	if update == nil || len(update.Metadata) == 0 {
		return
	}

	meta := update.Metadata
	var modified bool

	totalSize := 0
	entries := make([]metadataEntry, 0, len(meta))

	for k, v := range meta {
		origLen := len(v)
		if origLen > maxMetadataValueBytes {
			meta[k] = truncateValue(v, maxMetadataValueBytes)
			modified = true
		}
		size := len(k) + len(meta[k]) + 4
		totalSize += size
		entries = append(entries, metadataEntry{
			key:       k,
			size:      size,
			priority:  dropPriority(k),
			protected: isProtectedKey(k),
		})
	}

	if totalSize > maxMetadataTotalBytes {
		modified = true
		totalSize = dropOversizedMetadata(meta, entries, totalSize)
	}

	if totalSize > maxMetadataTotalBytes {
		modified = true
		totalSize = aggressivelyTruncateMetadata(meta, totalSize)
	}

	if modified {
		meta["_metadata_truncated"] = strconv.Itoa(totalSize)
	}
}

func truncateValue(value string, limit int) string {
	if limit <= minMetadataValueBytes {
		limit = minMetadataValueBytes
	}
	if len(value) <= limit {
		return value
	}
	if limit <= 3 {
		return value[:limit]
	}
	return value[:limit-3] + "..."
}

func dropPriority(key string) int {
	if isProtectedKey(key) {
		return 0
	}

	prefixes := [...]string{
		"port_results",
		"open_ports",
		"port_scan_results",
		"port_scan_payload",
		"raw_payload",
		"raw_metrics",
		"metrics_payload",
		"event_raw",
		"kv_cache",
		"alt_ip:",
	}

	for idx, prefix := range prefixes {
		if strings.HasPrefix(key, prefix) {
			return len(prefixes) - idx + 1
		}
	}

	return 1
}

func isProtectedKey(key string) bool {
	switch key {
	case "armis_device_id",
		"integration_id",
		"integration_type",
		"netbox_device_id",
		"hostname",
		"mac",
		"ip",
		"device_id",
		"poller_id",
		"agent_id",
		"_merged_into",
		"_deleted",
		"confidence",
		"scan_availability_percent":
		return true
	default:
		return false
	}
}

func dropOversizedMetadata(meta map[string]string, entries []metadataEntry, total int) int {
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].priority == entries[j].priority {
			return entries[i].size > entries[j].size
		}
		return entries[i].priority > entries[j].priority
	})

	for _, ent := range entries {
		if total <= maxMetadataTotalBytes {
			break
		}
		if ent.protected || ent.priority == 0 {
			continue
		}
		delete(meta, ent.key)
		total -= ent.size
	}

	return total
}

func aggressivelyTruncateMetadata(meta map[string]string, total int) int {
	if total <= maxMetadataTotalBytes || len(meta) == 0 {
		return total
	}

	scale := float64(maxMetadataTotalBytes) / float64(total)
	if scale <= 0 {
		scale = 0.5
	}

	newTotal := 0
	for k, v := range meta {
		allowed := int(float64(len(v)) * scale)
		if allowed < minMetadataValueBytes {
			allowed = minMetadataValueBytes
		}
		meta[k] = truncateValue(v, allowed)
		newTotal += len(k) + len(meta[k]) + 4
	}

	return newTotal
}
