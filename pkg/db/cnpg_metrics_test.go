package db

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildTimeseriesMetricArgs(t *testing.T) {
	fixed := time.Date(2025, time.January, 10, 12, 0, 0, 0, time.UTC)
	original := nowUTC
	nowUTC = func() time.Time {
		return fixed
	}
	t.Cleanup(func() {
		nowUTC = original
	})

	metric := &models.TimeseriesMetric{
		Name:           "ifInOctets",
		Type:           "counter",
		Value:          "123.4",
		DeviceID:       "default:1.2.3.4",
		Partition:      "default",
		TargetDeviceIP: "1.2.3.4",
		IfIndex:        12,
		Metadata:       `{"foo":"bar"}`,
	}

	args, err := buildTimeseriesMetricArgs("gateway-a", metric)
	require.NoError(t, err)
	require.Len(t, args, 15)

	assert.Equal(t, fixed, args[0])
	assert.Equal(t, "gateway-a", args[1])
	assert.Empty(t, args[2])
	assert.Equal(t, "ifInOctets", args[3])
	assert.Equal(t, "counter", args[4])
	assert.Equal(t, "default:1.2.3.4", args[5])
	assert.InEpsilon(t, 123.4, args[6], 0.0001)
	assert.Empty(t, args[7])
	assert.Equal(t, map[string]string{}, args[8])
	assert.Equal(t, "default", args[9])
	assert.InEpsilon(t, 1.0, args[10], 0.0001)
	assert.Equal(t, false, args[11])
	assert.Equal(t, "1.2.3.4", args[12])
	assert.Equal(t, int32(12), args[13])
	_, ok := args[14].(json.RawMessage)
	assert.True(t, ok, "metadata should marshal to JSON raw message")

	metric.Metadata = ""
	args, err = buildTimeseriesMetricArgs("gateway-a", metric)
	require.NoError(t, err)
	assert.Nil(t, args[14])

	metric.Metadata = "{invalid"
	_, err = buildTimeseriesMetricArgs("gateway-a", metric)
	require.Error(t, err)
}

func TestBuildDiskMetricArgs(t *testing.T) {
	ts := time.Date(2025, time.February, 5, 9, 30, 0, 0, time.UTC)
	disk := models.DiskMetric{
		MountPoint: "/var",
		TotalBytes: 1000,
		UsedBytes:  400,
	}

	args := buildDiskMetricArgs("gateway", "agent", "host", "device", "partition", disk, ts)
	require.Len(t, args, 12)

	assert.Equal(t, ts, args[0])
	assert.Equal(t, "/var", args[4])
	assert.Equal(t, int64(1000), args[6])
	assert.Equal(t, int64(400), args[7])
	assert.Equal(t, int64(600), args[8])
	assert.InDelta(t, 40.0, args[9].(float64), 0.0001)
}

func TestBuildMemoryMetricArgs(t *testing.T) {
	ts := time.Date(2025, time.March, 1, 0, 0, 0, 0, time.UTC)
	memory := &models.MemoryMetric{
		TotalBytes: 2048,
		UsedBytes:  1024,
	}

	args := buildMemoryMetricArgs("gateway", "agent", "host", "device", "partition", memory, ts)
	require.Len(t, args, 10)

	assert.Equal(t, ts, args[0])
	assert.Equal(t, int64(2048), args[4])
	assert.Equal(t, int64(1024), args[5])
	assert.Equal(t, int64(1024), args[6])
	assert.InDelta(t, 50.0, args[7].(float64), 0.0001)
}
