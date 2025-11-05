package api

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestToCollectorCapabilityResponseFlags(t *testing.T) {
	now := time.Now()
	record := &models.CollectorCapability{
		DeviceID:     "default:10.0.0.10",
		Capabilities: []string{"icmp", "SNMP", "sysmon"},
		AgentID:      "agent-1",
		PollerID:     "poller-1",
		ServiceName:  "serviceradar:agent:icmp",
		LastSeen:     now,
	}

	resp := toCollectorCapabilityResponse(record)
	require.NotNil(t, resp)
	require.True(t, resp.HasCollector)
	require.True(t, resp.SupportsICMP)
	require.True(t, resp.SupportsSNMP)
	require.True(t, resp.SupportsSysmon)
	require.ElementsMatch(t, []string{"icmp", "SNMP", "sysmon"}, resp.Capabilities)
	require.Equal(t, "agent-1", resp.AgentID)
	require.Equal(t, "poller-1", resp.PollerID)
	require.Equal(t, "serviceradar:agent:icmp", resp.ServiceName)
	require.NotNil(t, resp.LastSeen)
	require.WithinDuration(t, now, *resp.LastSeen, time.Second)
}

func TestToCollectorCapabilityResponseNilWhenEmpty(t *testing.T) {
	require.Nil(t, toCollectorCapabilityResponse(nil))
	require.Nil(t, toCollectorCapabilityResponse(&models.CollectorCapability{DeviceID: "default:empty"}))
}
