package db

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildCNPGPollerStatusArgs(t *testing.T) {
	now := time.Date(2025, time.June, 10, 12, 0, 0, 0, time.UTC)
	status := &models.PollerStatus{
		PollerID:  "poller-1",
		IsHealthy: true,
		FirstSeen: now.Add(-time.Hour),
		LastSeen:  now,
	}

	args, err := buildCNPGPollerStatusArgs(status)
	require.NoError(t, err)
	require.Len(t, args, 14)

	assert.Equal(t, "poller-1", args[0])
	assert.Equal(t, "implicit", args[2])
	assert.Equal(t, "active", args[3])
	assert.Equal(t, now.UTC(), args[7])
	assert.Equal(t, status.IsHealthy, args[10])
	updated, ok := args[13].(time.Time)
	require.True(t, ok)
	assert.WithinDuration(t, nowUTC(), updated, time.Second)
}

func TestBuildCNPGServiceStatusArgs(t *testing.T) {
	status := &models.ServiceStatus{
		PollerID:    "poller-1",
		AgentID:     "agent-1",
		ServiceName: "postgres",
		ServiceType: "database",
		Available:   true,
		Message:     "ok",
		Details:     json.RawMessage(`{"latency":10}`),
		Partition:   "default",
		Timestamp:   time.Date(2025, time.January, 2, 3, 4, 5, 0, time.UTC),
	}

	args, err := buildCNPGServiceStatusArgs(status)
	require.NoError(t, err)
	require.Len(t, args, 9)

	assert.Equal(t, status.Timestamp, args[0])
	assert.Equal(t, status.PollerID, args[1])
	assert.Equal(t, status.Message, args[6])
	assert.Equal(t, status.Partition, args[8])
	assert.Equal(t, status.Details, args[7])
}

func TestBuildCNPGServiceArgs(t *testing.T) {
	service := &models.Service{
		PollerID:    "poller-1",
		ServiceName: "svc",
		ServiceType: "process",
		AgentID:     "agent-1",
		Partition:   "default",
		Timestamp:   time.Date(2025, time.April, 1, 0, 0, 0, 0, time.UTC),
		Config: map[string]string{
			"interval": "30s",
		},
	}

	args, err := buildCNPGServiceArgs(service)
	require.NoError(t, err)
	require.Len(t, args, 7)

	assert.Equal(t, service.Timestamp, args[0])
	assert.Equal(t, service.PollerID, args[1])
	assert.Equal(t, service.ServiceType, args[4])
	assert.Equal(t, service.Partition, args[6])
	assertJSONRawEquals(t, map[string]string{"interval": "30s"}, args[5])
}
