package registry

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestCapabilityMatrixSetAndGet(t *testing.T) {
	t.Parallel()

	matrix := NewCapabilityMatrix()
	now := time.Date(2025, time.January, 2, 15, 4, 5, 0, time.UTC)

	input := &models.DeviceCapabilitySnapshot{
		DeviceID:    "default:10.0.0.1",
		Capability:  "ICMP",
		ServiceID:   "poller-1",
		ServiceType: "icmp",
		State:       "ok",
		Enabled:     true,
		LastChecked: now,
		Metadata: map[string]any{
			"latency_ms": 12,
		},
	}

	matrix.Set(input)

	got, ok := matrix.Get("default:10.0.0.1", "icmp", "poller-1")
	require.True(t, ok)
	require.NotNil(t, got)
	require.NotSame(t, input, got)
	require.Equal(t, "icmp", got.Capability)
	require.Equal(t, now, got.LastChecked)
	require.EqualValues(t, 12, got.Metadata["latency_ms"])

	// Mutating the returned snapshot must not affect the stored value.
	got.Metadata["latency_ms"] = 42
	got.LastChecked = got.LastChecked.Add(time.Hour)

	check, ok := matrix.Get("default:10.0.0.1", "icmp", "poller-1")
	require.True(t, ok)
	require.EqualValues(t, 12, check.Metadata["latency_ms"])
	require.Equal(t, now, check.LastChecked)
}

func TestCapabilityMatrixListForDevice(t *testing.T) {
	t.Parallel()

	matrix := NewCapabilityMatrix()

	matrix.Set(&models.DeviceCapabilitySnapshot{
		DeviceID:    "default:10.0.0.2",
		Capability:  "icmp",
		ServiceID:   "svc-a",
		ServiceType: "icmp",
		State:       "ok",
		Enabled:     true,
		LastChecked: time.Unix(1700000000, 0),
	})
	matrix.Set(&models.DeviceCapabilitySnapshot{
		DeviceID:    "default:10.0.0.2",
		Capability:  "snmp",
		ServiceID:   "svc-b",
		ServiceType: "snmp",
		State:       "failed",
		Enabled:     true,
		LastChecked: time.Unix(1700003600, 0),
	})

	list := matrix.ListForDevice("default:10.0.0.2")
	require.Len(t, list, 2)

	capabilities := make(map[string]string, len(list))
	for _, snapshot := range list {
		capabilities[snapshot.Capability] = snapshot.State
	}

	require.Equal(t, "ok", capabilities["icmp"])
	require.Equal(t, "failed", capabilities["snmp"])
}

func TestCapabilityMatrixReplaceAll(t *testing.T) {
	t.Parallel()

	matrix := NewCapabilityMatrix()
	matrix.Set(&models.DeviceCapabilitySnapshot{
		DeviceID:    "default:10.0.0.3",
		Capability:  "icmp",
		ServiceID:   "svc-old",
		ServiceType: "icmp",
		State:       "ok",
		Enabled:     true,
	})

	fresh := []*models.DeviceCapabilitySnapshot{
		{
			DeviceID:    "default:10.0.0.3",
			Capability:  "snmp",
			ServiceID:   "svc-new",
			ServiceType: "snmp",
			State:       "ok",
			Enabled:     true,
		},
	}

	matrix.ReplaceAll(fresh)

	_, ok := matrix.Get("default:10.0.0.3", "icmp", "svc-old")
	require.False(t, ok, "old capability should be replaced")

	got, ok := matrix.Get("default:10.0.0.3", "snmp", "svc-new")
	require.True(t, ok)
	require.Equal(t, "snmp", got.Capability)
}
