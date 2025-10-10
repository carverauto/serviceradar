package deviceupdate

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestSanitizeMetadataTruncatesLargeValues(t *testing.T) {
	update := &models.DeviceUpdate{
		Metadata: map[string]string{
			"port_scan_payload": strings.Repeat("x", maxMetadataValueBytes+1024),
		},
	}

	SanitizeMetadata(update)

	got := update.Metadata["port_scan_payload"]
	require.LessOrEqual(t, len(got), maxMetadataValueBytes)
	require.NotEmpty(t, update.Metadata["_metadata_truncated"])
}

func TestSanitizeMetadataDropsPreferredKeysBeforeProtected(t *testing.T) {
	meta := map[string]string{
		"armis_device_id": strings.Repeat("a", maxMetadataValueBytes),
		"port_results":    strings.Repeat("p", maxMetadataValueBytes),
		"raw_payload":     strings.Repeat("r", maxMetadataValueBytes),
		"metrics_payload": strings.Repeat("m", maxMetadataValueBytes),
		"open_ports":      strings.Repeat("o", maxMetadataValueBytes),
		"kv_cache":        strings.Repeat("k", maxMetadataValueBytes),
		"misc_one":        strings.Repeat("z", maxMetadataValueBytes),
		"misc_two":        strings.Repeat("y", maxMetadataValueBytes),
		"misc_three":      strings.Repeat("q", maxMetadataValueBytes),
	}

	update := &models.DeviceUpdate{Metadata: meta}

	SanitizeMetadata(update)

	require.NotContains(t, update.Metadata, "port_results")
	require.NotEmpty(t, update.Metadata["armis_device_id"])

	total := 0
	for k, v := range update.Metadata {
		total += len(k) + len(v)
	}
	require.LessOrEqual(t, total, maxMetadataTotalBytes)
}

func TestSanitizeMetadataAggressivelyTruncatesProtectedWhenNeeded(t *testing.T) {
	update := &models.DeviceUpdate{
		Metadata: map[string]string{
			"armis_device_id": strings.Repeat("a", maxMetadataTotalBytes*2),
		},
	}

	SanitizeMetadata(update)

	require.LessOrEqual(t, len(update.Metadata["armis_device_id"]), maxMetadataTotalBytes)
	require.NotEmpty(t, update.Metadata["_metadata_truncated"])
}
