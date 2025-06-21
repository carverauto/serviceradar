package netbox

import (
	"encoding/json"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/require"
)

func TestProcessDevices_UsesIDs(t *testing.T) {
	integ := &NetboxIntegration{Config: &models.SourceConfig{AgentID: "agent", PollerID: "poller", Partition: "test-partition"}}

	resp := DeviceResponse{Results: []Device{
		{
			ID:   1,
			Name: "host1",
			Role: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "role"},
			Site: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "site"},
			PrimaryIP4: struct {
				ID      int    "json:\"id\""
				Address string "json:\"address\""
			}{ID: 1, Address: "10.0.0.1/32"},
		},
	}}

	data, ips, events := integ.processDevices(resp)
	require.Len(t, ips, 1)
	require.Equal(t, "10.0.0.1/32", ips[0])
	require.Len(t, data, 1)

	b, ok := data["agent/10.0.0.1"]
	require.True(t, ok)

	var event models.SweepResult
	err := json.Unmarshal(b, &event)
	require.NoError(t, err)

	require.Equal(t, "poller", event.PollerID)
	require.Equal(t, "10.0.0.1", event.IP)
	require.Equal(t, "test-partition", event.Partition)

	require.Len(t, events, 1)
	require.Equal(t, "10.0.0.1", events[0].IP)
	require.Equal(t, "poller", events[0].PollerID)
	require.Equal(t, "netbox", events[0].DiscoverySource)
	require.Equal(t, "test-partition", events[0].Partition)
}
