package registry

import (
	"strings"

	"github.com/carverauto/serviceradar/pkg/models"
)

// isCanonicalUnifiedDevice reports whether the unified device represents a canonical row
// (no merge target and not marked deleted).
func isCanonicalUnifiedDevice(device *models.UnifiedDevice) bool {
	if device == nil {
		return false
	}

	meta := extractMetadata(device.Metadata)
	if meta == nil {
		return true
	}

	if strings.EqualFold(meta["_deleted"], "true") || strings.EqualFold(meta["deleted"], "true") {
		return false
	}

	merged := strings.TrimSpace(meta["_merged_into"])
	if merged != "" && merged != device.DeviceID {
		return false
	}

	return true
}

func extractMetadata(field *models.DiscoveredField[map[string]string]) map[string]string {
	if field == nil {
		return nil
	}
	return field.Value
}
