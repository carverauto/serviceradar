package api

import (
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildAliasHistory(t *testing.T) {
	device := &models.UnifiedDevice{
		DeviceID: "default:10.0.0.5",
		Metadata: &models.DiscoveredField[map[string]string]{
			Value: map[string]string{
				"_alias_last_seen_at":                   "2025-11-03T15:00:00Z",
				"_alias_collector_ip":                   "10.42.111.114",
				"_alias_last_seen_service_id":           "serviceradar:agent:k8s-agent",
				"_alias_last_seen_ip":                   "10.0.0.5",
				"service_alias:serviceradar:poller:k8s": "2025-11-03T14:00:00Z",
				"ip_alias:10.0.0.8":                     "2025-11-03T14:30:00Z",
			},
		},
	}

	history := buildAliasHistory(device)
	assert.NotNil(t, history)
	assert.Equal(t, "2025-11-03T15:00:00Z", history.LastSeenAt)
	assert.Equal(t, "10.42.111.114", history.CollectorIP)
	assert.Equal(t, "serviceradar:agent:k8s-agent", history.CurrentServiceID)
	assert.Equal(t, "10.0.0.5", history.CurrentIP)

	assert.Len(t, history.Services, 2)
	assert.Contains(t, history.Services, DeviceAliasRecord{
		ID:         "serviceradar:agent:k8s-agent",
		LastSeenAt: "2025-11-03T15:00:00Z",
	})
	assert.Contains(t, history.Services, DeviceAliasRecord{
		ID:         "serviceradar:poller:k8s",
		LastSeenAt: "2025-11-03T14:00:00Z",
	})

	assert.Len(t, history.IPs, 2)
	assert.Contains(t, history.IPs, DeviceAliasRecord{
		IP:         "10.0.0.5",
		LastSeenAt: "2025-11-03T15:00:00Z",
	})
	assert.Contains(t, history.IPs, DeviceAliasRecord{
		IP:         "10.0.0.8",
		LastSeenAt: "2025-11-03T14:30:00Z",
	})
}

func TestBuildAliasHistoryNil(t *testing.T) {
	assert.Nil(t, buildAliasHistory(nil))
	assert.Nil(t, buildAliasHistory(&models.UnifiedDevice{}))
}
