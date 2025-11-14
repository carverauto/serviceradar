package core

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/registry"
)

func TestStatsAggregatorRefresh(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 1, 2, 15, 4, 5, 0, time.UTC)

	makeRecord := func(id string, available bool, lastSeen time.Time) *registry.DeviceRecord {
		partition := strings.SplitN(id, ":", 2)[0]
		metadata := map[string]string{
			"canonical_device_id": id,
			"canonical_partition": partition,
		}
		return &registry.DeviceRecord{
			DeviceID:    id,
			IsAvailable: available,
			LastSeen:    lastSeen.UTC(),
			FirstSeen:   lastSeen.Add(-24 * time.Hour).UTC(),
			Metadata:    metadata,
		}
	}

	reg.UpsertDeviceRecord(makeRecord("default:10.0.0.1", true, base.Add(-time.Hour)))
	reg.UpsertDeviceRecord(makeRecord("tenant-a:10.0.0.2", false, base.Add(-26*time.Hour)))
	reg.UpsertDeviceRecord(makeRecord("tenant-a:10.0.0.3", true, base.Add(-30*time.Minute)))

	reg.SetCollectorCapabilities(context.Background(), &models.CollectorCapability{
		DeviceID:     "default:10.0.0.1",
		Capabilities: []string{"icmp"},
		LastSeen:     base,
	})
	reg.SetCollectorCapabilities(context.Background(), &models.CollectorCapability{
		DeviceID:     "tenant-a:10.0.0.2",
		Capabilities: []string{"snmp"},
		LastSeen:     base,
	})
	reg.SetCollectorCapabilities(context.Background(), &models.CollectorCapability{
		DeviceID:     "tenant-a:10.0.0.3",
		Capabilities: []string{"icmp", "sysmon"},
		LastSeen:     base,
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)

	meta := agg.Meta()
	assert.Equal(t, 3, meta.RawRecords)
	assert.Equal(t, 3, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.SkippedNilRecords)
	assert.Equal(t, 0, meta.SkippedTombstonedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents)
	assert.Equal(t, 0, meta.SkippedNonCanonical)
	assert.Equal(t, 0, meta.InferredCanonicalFallback)

	assert.Equal(t, base.UTC(), snapshot.Timestamp)
	assert.Equal(t, 3, snapshot.TotalDevices)
	assert.Equal(t, 2, snapshot.AvailableDevices)
	assert.Equal(t, 1, snapshot.UnavailableDevices)
	assert.Equal(t, 2, snapshot.ActiveDevices)
	assert.Equal(t, 3, snapshot.DevicesWithCollectors)
	assert.Equal(t, 2, snapshot.DevicesWithICMP)
	assert.Equal(t, 1, snapshot.DevicesWithSNMP)
	assert.Equal(t, 1, snapshot.DevicesWithSysmon)

	require.Len(t, snapshot.Partitions, 2)
	assert.Equal(t, "default", snapshot.Partitions[0].PartitionID)
	assert.Equal(t, 1, snapshot.Partitions[0].DeviceCount)
	assert.Equal(t, 1, snapshot.Partitions[0].AvailableCount)
	assert.Equal(t, 1, snapshot.Partitions[0].ActiveCount)

	assert.Equal(t, "tenant-a", snapshot.Partitions[1].PartitionID)
	assert.Equal(t, 2, snapshot.Partitions[1].DeviceCount)
	assert.Equal(t, 1, snapshot.Partitions[1].AvailableCount)
	assert.Equal(t, 1, snapshot.Partitions[1].ActiveCount)

	// Ensure Snapshot returns a clone.
	snapshot.Partitions[0].DeviceCount = 0
	next := agg.Snapshot()
	require.NotNil(t, next)
	assert.Equal(t, 1, next.Partitions[0].DeviceCount)
}

func TestStatsAggregatorSkipsTombstonedRecords(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 2, 14, 10, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:canonical-1",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-1",
			"canonical_partition": "default",
		},
	})

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID: "default:alias-1",
		LastSeen: base.Add(-time.Hour),
		Metadata: map[string]string{
			"_merged_into":        "default:canonical-1",
			"canonical_device_id": "default:canonical-1",
		},
	})

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID: "default:deleted-1",
		LastSeen: base.Add(-2 * time.Hour),
		Metadata: map[string]string{
			"_deleted":            "true",
			"canonical_device_id": "default:deleted-1",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.SkippedNilRecords)
	assert.Equal(t, 2, meta.SkippedTombstonedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents)
	assert.Equal(t, 0, meta.SkippedNonCanonical)
	assert.Equal(t, 0, meta.InferredCanonicalFallback)
	assert.Equal(t, 1, snapshot.TotalDevices)
	assert.Equal(t, 1, snapshot.AvailableDevices)
	assert.Equal(t, 0, snapshot.UnavailableDevices)
}

func TestStatsAggregatorSkipsNonCanonicalRecords(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 6, 1, 8, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:canonical-3",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-3",
		},
	})

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:alias-noncanonical",
		IsAvailable: false,
		LastSeen:    base.Add(-time.Minute),
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-3",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)

	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.SkippedNilRecords)
	assert.Equal(t, 0, meta.SkippedTombstonedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents)
	assert.Equal(t, 1, meta.SkippedNonCanonical)
	assert.Equal(t, 0, meta.InferredCanonicalFallback)

	assert.Equal(t, 1, snapshot.TotalDevices)
	assert.Equal(t, 1, snapshot.AvailableDevices)
	assert.Equal(t, 0, snapshot.UnavailableDevices)
}

func TestStatsAggregatorCountsServiceComponents(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 7, 4, 12, 0, 0, 0, time.UTC)

	addServiceComponent := func(componentType, deviceID string) {
		reg.UpsertDeviceRecord(&registry.DeviceRecord{
			DeviceID:         deviceID,
			IsAvailable:      true,
			FirstSeen:        base.Add(-time.Hour),
			LastSeen:         base,
			DiscoverySources: []string{string(models.DiscoverySourceServiceRadar)},
			Metadata: map[string]string{
				"component_type":      componentType,
				"canonical_device_id": deviceID,
				"canonical_partition": models.ServiceDevicePartition,
			},
		})
	}

	addServiceComponent("poller", models.GenerateServiceDeviceID(models.ServiceTypePoller, "docker-poller"))
	addServiceComponent("agent", models.GenerateServiceDeviceID(models.ServiceTypeAgent, "docker-agent"))

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)

	meta := agg.Meta()
	assert.Equal(t, 2, meta.RawRecords)
	assert.Equal(t, 2, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents, "service components are counted as devices")

	assert.Equal(t, 2, snapshot.TotalDevices)
	assert.Equal(t, 2, snapshot.AvailableDevices)
	assert.Equal(t, 0, snapshot.UnavailableDevices)
}

func TestStatsAggregatorFallsBackToAliasWhenCanonicalMissing(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 11, 6, 3, 30, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:alias-1",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-1",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)

	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.SkippedNilRecords)
	assert.Equal(t, 0, meta.SkippedTombstonedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents)
	assert.Equal(t, 0, meta.SkippedNonCanonical)
	assert.Equal(t, 1, meta.InferredCanonicalFallback)
	assert.Equal(t, 1, snapshot.TotalDevices)
	assert.Equal(t, 1, snapshot.AvailableDevices)
}

func TestStatsAggregatorPrefersCanonicalOverAliasFallback(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 11, 6, 4, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:alias-2",
		IsAvailable: false,
		LastSeen:    base.Add(-time.Minute),
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-2",
		},
	})

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:canonical-2",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-2",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)

	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 1, meta.SkippedNonCanonical)
	assert.Equal(t, 0, meta.InferredCanonicalFallback)
	assert.Equal(t, 1, snapshot.TotalDevices)
	assert.Equal(t, 1, snapshot.AvailableDevices)
}

func TestStatsAggregatorDeduplicatesAliasRecords(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 11, 6, 5, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:alias-a",
		IsAvailable: true,
		LastSeen:    base.Add(-5 * time.Minute),
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-a",
		},
	})

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:alias-b",
		IsAvailable: false,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-a",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)

	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 1, meta.InferredCanonicalFallback)
	assert.Equal(t, 1, meta.SkippedNonCanonical)
	assert.Equal(t, 1, snapshot.TotalDevices)
}

func TestStatsAggregatorCountsCanonicalWithMergedMarker(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 3, 3, 12, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:canonical-2",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"_merged_into":        "default:canonical-2",
			"canonical_device_id": "default:canonical-2",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.SkippedNilRecords)
	assert.Equal(t, 0, meta.SkippedTombstonedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents)
	assert.Equal(t, 0, meta.SkippedNonCanonical)
	assert.Equal(t, 0, meta.InferredCanonicalFallback)
	assert.Equal(t, 1, snapshot.TotalDevices)
	assert.Equal(t, 1, snapshot.AvailableDevices)
	assert.Equal(t, 0, snapshot.UnavailableDevices)
}

func TestStatsAggregatorInfersCanonicalFallback(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 5, 5, 15, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:legacy-1",
		IsAvailable: true,
		LastSeen:    base,
		FirstSeen:   base.Add(-48 * time.Hour),
		Metadata:    nil,
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	meta := agg.Meta()

	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.SkippedNilRecords)
	assert.Equal(t, 0, meta.SkippedTombstonedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents)
	assert.Equal(t, 0, meta.SkippedNonCanonical)
	assert.Equal(t, 1, meta.InferredCanonicalFallback)

	assert.Equal(t, 1, snapshot.TotalDevices)
	assert.Equal(t, 1, snapshot.AvailableDevices)
	assert.Equal(t, 0, snapshot.UnavailableDevices)
}

func TestStatsAggregatorCountsServiceComponentsAsDevices(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 4, 12, 9, 30, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:10.0.0.10",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:10.0.0.10",
			"canonical_partition": "default",
		},
	})

	agentID := models.GenerateServiceDeviceID(models.ServiceTypeAgent, "agent-123")
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    agentID,
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"component_type":      "agent",
			"canonical_device_id": agentID,
			"canonical_partition": "default",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	meta := agg.Meta()
	assert.Equal(t, 2, meta.RawRecords, "Should count both normal device and service component")
	assert.Equal(t, 2, meta.ProcessedRecords, "Service components are now counted as devices")
	assert.Equal(t, 0, meta.SkippedNilRecords)
	assert.Equal(t, 0, meta.SkippedTombstonedRecords)
	assert.Equal(t, 0, meta.SkippedServiceComponents, "Service components are no longer skipped")
	assert.Equal(t, 0, meta.SkippedNonCanonical)
	assert.Equal(t, 0, meta.InferredCanonicalFallback)
	assert.Equal(t, 2, snapshot.TotalDevices, "Should count both normal device and agent")
	assert.Equal(t, 2, snapshot.AvailableDevices, "Both devices are available")
	assert.Equal(t, 0, snapshot.UnavailableDevices)
}

func TestStatsAggregatorCountsServiceComponentsWithSharedIP(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 4, 12, 10, 0, 0, 0, time.UTC)
	sharedIP := "10.50.1.200"

	// Regular device on shared IP
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:" + sharedIP,
		IP:          sharedIP,
		IsAvailable: true,
		FirstSeen:   base.Add(-time.Hour),
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:" + sharedIP,
			"canonical_partition": "default",
		},
	})

	// Poller on same IP - should be counted as separate device
	pollerID := models.GenerateServiceDeviceID(models.ServiceTypePoller, "poller-on-shared-ip")
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    pollerID,
		IP:          sharedIP,
		IsAvailable: true,
		FirstSeen:   base.Add(-time.Hour),
		LastSeen:    base,
		Metadata: map[string]string{
			"component_type":      "poller",
			"canonical_device_id": pollerID,
			"canonical_partition": "default",
		},
	})

	// Agent on same IP - should also be counted as separate device
	agentID := models.GenerateServiceDeviceID(models.ServiceTypeAgent, "agent-on-shared-ip")
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    agentID,
		IP:          sharedIP,
		IsAvailable: true,
		FirstSeen:   base.Add(-time.Hour),
		LastSeen:    base,
		Metadata: map[string]string{
			"component_type":      "agent",
			"canonical_device_id": agentID,
			"canonical_partition": "default",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	meta := agg.Meta()

	assert.Equal(t, 3, meta.RawRecords, "Should have 3 records total")
	assert.Equal(t, 3, meta.ProcessedRecords, "All 3 should be processed")
	assert.Equal(t, 0, meta.SkippedServiceComponents, "Service components should not be skipped")
	assert.Equal(t, 3, snapshot.TotalDevices, "Should count all 3 as separate devices despite shared IP")
	assert.Equal(t, 3, snapshot.AvailableDevices)
	assert.Equal(t, 0, snapshot.UnavailableDevices)
}

func TestStatsAggregatorCountsMultipleServiceComponentsOfSameType(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 4, 12, 11, 0, 0, 0, time.UTC)

	// Multiple pollers
	for i := 1; i <= 3; i++ {
		pollerID := models.GenerateServiceDeviceID(models.ServiceTypePoller, fmt.Sprintf("poller-%d", i))
		reg.UpsertDeviceRecord(&registry.DeviceRecord{
			DeviceID:    pollerID,
			IsAvailable: true,
			LastSeen:    base,
			Metadata: map[string]string{
				"component_type":      "poller",
				"canonical_device_id": pollerID,
				"canonical_partition": "default",
			},
		})
	}

	// Multiple agents
	for i := 1; i <= 2; i++ {
		agentID := models.GenerateServiceDeviceID(models.ServiceTypeAgent, fmt.Sprintf("agent-%d", i))
		reg.UpsertDeviceRecord(&registry.DeviceRecord{
			DeviceID:    agentID,
			IsAvailable: true,
			LastSeen:    base,
			Metadata: map[string]string{
				"component_type":      "agent",
				"canonical_device_id": agentID,
				"canonical_partition": "default",
			},
		})
	}

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	meta := agg.Meta()

	assert.Equal(t, 5, meta.RawRecords, "Should have 5 service components")
	assert.Equal(t, 5, meta.ProcessedRecords, "All should be processed")
	assert.Equal(t, 0, meta.SkippedServiceComponents, "None should be skipped")
	assert.Equal(t, 5, snapshot.TotalDevices, "Should count all service components")
	assert.Equal(t, 5, snapshot.AvailableDevices)
}

func TestStatsAggregatorCountsServiceComponentsEvenWithFallbackRecords(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 4, 12, 12, 0, 0, 0, time.UTC)

	// Device with canonical metadata (will go to canonical map)
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:10.0.0.1",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:10.0.0.1",
			"canonical_partition": "default",
		},
	})

	// Device without canonical metadata (will go to fallback map)
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:10.0.0.2",
		IsAvailable: true,
		LastSeen:    base,
		Metadata:    map[string]string{},
	})

	// Service component - should still be counted
	agentID := models.GenerateServiceDeviceID(models.ServiceTypeAgent, "agent-123")
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    agentID,
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"component_type":      "agent",
			"canonical_device_id": agentID,
			"canonical_partition": "default",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	meta := agg.Meta()

	assert.Equal(t, 3, meta.RawRecords, "Should have 3 records")
	assert.Equal(t, 3, meta.ProcessedRecords, "All should be processed")
	assert.Equal(t, 0, meta.SkippedServiceComponents, "Service components counted regardless of fallback records")
	assert.Equal(t, 1, meta.InferredCanonicalFallback, "One record inferred from fallback")
	assert.Equal(t, 3, snapshot.TotalDevices, "Should count canonical + fallback + service component")
}

func TestStatsAggregatorSkipsSweepOnlyRecordsWithoutIdentity(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 5, 1, 12, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:         "default:10.0.0.10",
		LastSeen:         base,
		DiscoverySources: []string{string(models.DiscoverySourceSweep)},
		Metadata: map[string]string{
			"canonical_device_id": "default:10.0.0.10",
		},
	})

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:         "default:10.0.0.11",
		LastSeen:         base,
		DiscoverySources: []string{string(models.DiscoverySourceSweep)},
		Metadata: map[string]string{
			"canonical_device_id": "default:10.0.0.11",
			"armis_device_id":     "armis-42",
		},
	})

	agg := NewStatsAggregator(reg, log, WithStatsClock(func() time.Time { return base }))
	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	assert.Equal(t, 1, snapshot.TotalDevices)

	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 1, meta.SkippedSweepOnlyRecords)
}

func TestStatsAggregatorAlertsOnNonCanonicalIncrease(t *testing.T) {
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	base := time.Date(2025, 7, 1, 12, 0, 0, 0, time.UTC)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:canonical",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical",
		},
	})

	var (
		alertCalls int
		alertMeta  models.DeviceStatsMeta
	)

	agg := NewStatsAggregator(
		reg,
		log,
		WithStatsClock(func() time.Time { return base }),
		WithStatsAlertHandler(func(ctx context.Context, previousSnapshot *models.DeviceStatsSnapshot, previousMeta models.DeviceStatsMeta, currentSnapshot *models.DeviceStatsSnapshot, currentMeta models.DeviceStatsMeta) {
			if currentMeta.SkippedNonCanonical > previousMeta.SkippedNonCanonical {
				alertCalls++
				alertMeta = currentMeta
			}
		}),
	)

	agg.Refresh(context.Background())
	assert.Equal(t, 0, alertCalls)

	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:alias",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical",
		},
	})

	agg.Refresh(context.Background())
	assert.Equal(t, 1, alertCalls)
	assert.Equal(t, 1, alertMeta.SkippedNonCanonical)
	assert.Equal(t, 0, alertMeta.InferredCanonicalFallback)
}

func TestStatsAggregatorPrunesInferredRecordsToMatchProton(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	base := time.Date(2025, 11, 6, 4, 17, 0, 0, time.UTC)
	log := logger.NewTestLogger()
	reg := registry.NewDeviceRegistry(nil, log)

	// Canonical device with matching metadata.
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:canonical-1",
		IsAvailable: true,
		LastSeen:    base,
		Metadata: map[string]string{
			"canonical_device_id": "default:canonical-1",
		},
	})

	// Inferred record without canonical metadata (e.g. sweep echo).
	reg.UpsertDeviceRecord(&registry.DeviceRecord{
		DeviceID:    "default:sweep-ephemeral-1",
		IsAvailable: false,
		LastSeen:    base.Add(-2 * time.Hour),
		Metadata: map[string]string{
			"discovery_hint": "sweep",
		},
	})

	mockDB := db.NewMockService(ctrl)
	mockDB.EXPECT().
		CountUnifiedDevices(gomock.Any()).
		Return(int64(1), nil)
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), gomock.Nil(), gomock.AssignableToTypeOf([]string{})).
		Return([]*models.UnifiedDevice{
			{DeviceID: "default:canonical-1"},
		}, nil).
		AnyTimes()

	agg := NewStatsAggregator(
		reg,
		log,
		WithStatsDB(mockDB),
		WithStatsClock(func() time.Time { return base }),
	)

	agg.Refresh(context.Background())

	snapshot := agg.Snapshot()
	require.NotNil(t, snapshot)
	assert.Equal(t, 1, snapshot.TotalDevices)
	assert.Equal(t, 1, snapshot.AvailableDevices)
	assert.Equal(t, 0, snapshot.UnavailableDevices)

	meta := agg.Meta()
	assert.Equal(t, 1, meta.RawRecords)
	assert.Equal(t, 1, meta.ProcessedRecords)
	assert.Equal(t, 0, meta.InferredCanonicalFallback)
}
