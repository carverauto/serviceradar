package netbox

import (
	"encoding/json"
	"testing"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/require"
)

func TestProcessDevices_UsesIDs(t *testing.T) {
	integ := &NetboxIntegration{Config: &models.SourceConfig{AgentID: "agent", PollerID: "poller"}}

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

	data, ips := integ.processDevices(resp)
	require.Len(t, ips, 1)
	require.Equal(t, "10.0.0.1/32", ips[0])
	require.Len(t, data, 1)

	b, ok := data["10.0.0.1:agent:poller"]
	require.True(t, ok)

	var dev models.Device
	err := json.Unmarshal(b, &dev)
	require.NoError(t, err)

	require.Equal(t, "poller", dev.PollerID)
	require.Equal(t, "10.0.0.1:agent:poller", dev.DeviceID)
}
