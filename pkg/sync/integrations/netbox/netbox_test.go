package netbox

import (
	"encoding/json"
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/require"
)

func TestProcessDevices_UsesIDs(t *testing.T) {
	integ := &NetboxIntegration{
		Config: &models.SourceConfig{AgentID: "agent", PollerID: "poller", Partition: "test-partition"},
		Logger: logger.NewTestLogger(),
	}

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
	require.Equal(t, models.DiscoverySourceNetbox, events[0].Source)
	require.Equal(t, "test-partition", events[0].Partition)
}

func TestParseTCPPorts(t *testing.T) {
	tests := []struct {
		name          string
		credentials   map[string]string
		expectedPorts []int
		description   string
	}{
		{
			name:          "default ports when tcp_ports not set",
			credentials:   map[string]string{},
			expectedPorts: []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
			description:   "should return default NetBox ports when tcp_ports credential is not set",
		},
		{
			name:          "default ports when tcp_ports is empty",
			credentials:   map[string]string{"tcp_ports": ""},
			expectedPorts: []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
			description:   "should return default NetBox ports when tcp_ports credential is empty",
		},
		{
			name:          "custom single port",
			credentials:   map[string]string{"tcp_ports": "9090"},
			expectedPorts: []int{9090},
			description:   "should parse single custom port",
		},
		{
			name:          "custom multiple ports",
			credentials:   map[string]string{"tcp_ports": "22,80,443,9090"},
			expectedPorts: []int{22, 80, 443, 9090},
			description:   "should parse multiple custom ports",
		},
		{
			name:          "custom ports with spaces",
			credentials:   map[string]string{"tcp_ports": "22, 80, 443 , 9090"},
			expectedPorts: []int{22, 80, 443, 9090},
			description:   "should parse custom ports with spaces",
		},
		{
			name:          "invalid ports mixed with valid",
			credentials:   map[string]string{"tcp_ports": "22,invalid,443,99999"},
			expectedPorts: []int{22, 443},
			description:   "should parse only valid ports and skip invalid ones",
		},
		{
			name:          "all invalid ports",
			credentials:   map[string]string{"tcp_ports": "invalid,99999,-1"},
			expectedPorts: []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
			description:   "should return default NetBox ports when all provided ports are invalid",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := &models.SourceConfig{
				Credentials: tt.credentials,
			}

			result := parseTCPPorts(config)
			require.Equal(t, tt.expectedPorts, result, tt.description)
		})
	}
}
