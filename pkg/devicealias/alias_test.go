package devicealias

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestFromMetadata(t *testing.T) {
	metadata := map[string]string{
		"_alias_last_seen_at":                        "2025-11-03T15:00:00Z",
		"_alias_last_seen_service_id":                "serviceradar:agent:k8s-agent",
		"_alias_last_seen_ip":                        "10.0.0.5",
		"_alias_collector_ip":                        "10.1.1.1",
		"service_alias:serviceradar:agent:k8s-agent": "2025-11-03T15:00:00Z",
		"service_alias:serviceradar:agent:rperf":     "2025-11-03T14:00:00Z",
		"ip_alias:10.0.0.5":                          "2025-11-03T15:00:00Z",
		"ip_alias:10.0.0.6":                          "2025-11-03T14:30:00Z",
	}

	record := FromMetadata(metadata)
	assert.NotNil(t, record)
	assert.Equal(t, "2025-11-03T15:00:00Z", record.LastSeenAt)
	assert.Equal(t, "10.1.1.1", record.CollectorIP)
	assert.Equal(t, "serviceradar:agent:k8s-agent", record.CurrentServiceID)
	assert.Equal(t, "10.0.0.5", record.CurrentIP)
	assert.Len(t, record.Services, 2)
	assert.Equal(t, "2025-11-03T15:00:00Z", record.Services["serviceradar:agent:k8s-agent"])
	assert.Equal(t, "2025-11-03T14:00:00Z", record.Services["serviceradar:agent:rperf"])
	assert.Len(t, record.IPs, 2)
	assert.Equal(t, "2025-11-03T15:00:00Z", record.IPs["10.0.0.5"])
	assert.Equal(t, "2025-11-03T14:30:00Z", record.IPs["10.0.0.6"])
}

func TestEqual(t *testing.T) {
	a := &Record{
		LastSeenAt:       "2025-11-03T15:00:00Z",
		CollectorIP:      "10.1.1.1",
		CurrentServiceID: "serviceradar:agent:k8s-agent",
		CurrentIP:        "10.0.0.5",
		Services: map[string]string{
			"serviceradar:agent:k8s-agent": "2025-11-03T15:00:00Z",
		},
		IPs: map[string]string{
			"10.0.0.5": "2025-11-03T15:00:00Z",
		},
	}

	b := a.Clone()
	assert.True(t, Equal(a, b))

	b.Services["serviceradar:agent:rperf"] = "2025-11-03T14:00:00Z"
	assert.False(t, Equal(a, b))
}

func TestFormatMap(t *testing.T) {
	input := map[string]string{
		"beta":  "2025-11-03T14:00:00Z",
		"alpha": "2025-11-03T15:00:00Z",
	}

	result := FormatMap(input)
	assert.Equal(t, "alpha=2025-11-03T15:00:00Z,beta=2025-11-03T14:00:00Z", result)
}
