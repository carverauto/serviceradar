package registry

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestCapabilityIndexSetAndGet(t *testing.T) {
	idx := NewCapabilityIndex()
	now := time.Now().UTC()

	record := &models.CollectorCapability{
		DeviceID:     "default:10.0.0.1",
		Capabilities: []string{"ICMP", "icmp", "Sysmon"},
		AgentID:      "agent-1",
		PollerID:     "poller-1",
		LastSeen:     now,
		ServiceName:  "serviceradar:agent:icmp",
	}

	idx.Set(record)

	got, ok := idx.Get("default:10.0.0.1")
	assert.True(t, ok, "expected capability record to exist")
	assert.NotNil(t, got)
	assert.Equal(t, record.DeviceID, got.DeviceID)
	assert.ElementsMatch(t, []string{"icmp", "sysmon"}, got.Capabilities)
	assert.Equal(t, record.AgentID, got.AgentID)
	assert.Equal(t, record.PollerID, got.PollerID)
	assert.Equal(t, record.ServiceName, got.ServiceName)
	assert.WithinDuration(t, now, got.LastSeen, time.Second)

	assert.True(t, idx.HasCapability(record.DeviceID, "icmp"), "device should expose icmp capability")
	assert.False(t, idx.HasCapability(record.DeviceID, "snmp"), "device should not expose snmp capability")

	devices := idx.ListDevicesWithCapability("icmp")
	assert.Equal(t, []string{record.DeviceID}, devices)
}

func TestCapabilityIndexRemoveOnEmptyCapabilities(t *testing.T) {
	idx := NewCapabilityIndex()

	record := &models.CollectorCapability{
		DeviceID:     "default:10.0.0.2",
		Capabilities: []string{"snmp"},
		LastSeen:     time.Now(),
	}

	idx.Set(record)

	got, ok := idx.Get(record.DeviceID)
	assert.True(t, ok)
	assert.NotNil(t, got)

	// Setting empty capabilities should remove the record.
	idx.Set(&models.CollectorCapability{
		DeviceID:     record.DeviceID,
		Capabilities: nil,
	})

	got, ok = idx.Get(record.DeviceID)
	assert.False(t, ok, "capability record should be removed after empty update")
	assert.Nil(t, got)

	assert.False(t, idx.HasCapability(record.DeviceID, "snmp"))
	assert.Empty(t, idx.ListDevicesWithCapability("snmp"))
}
