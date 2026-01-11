package db

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestBuildSweepHostStateArgs(t *testing.T) {
	cidr := "10.0.0.0/24"
	host := "router.local"
	mac := "00:11:22:33:44:55"
	resp := int64(25000000)
	loss := 0.42
	now := time.Date(2025, time.June, 3, 12, 0, 0, 0, time.UTC)

	state := &models.SweepHostState{
		HostIP:           "192.168.1.10",
		GatewayID:         "gateway-1",
		AgentID:          "agent-1",
		Partition:        "demo",
		NetworkCIDR:      &cidr,
		Hostname:         &host,
		MAC:              &mac,
		ICMPAvailable:    true,
		ICMPResponseTime: &resp,
		ICMPPacketLoss:   &loss,
		TCPPortsScanned:  []int{22, 443},
		TCPPortsOpen:     []int{22},
		PortScanResults: []models.PortResult{
			{Port: 22, Available: true},
		},
		LastSweepTime: now,
		FirstSeen:     now.Add(-time.Hour),
		Metadata: map[string]string{
			"source": "tcp",
		},
	}

	args, err := buildSweepHostStateArgs(state)
	require.NoError(t, err)
	require.Len(t, args, 16)

	assert.Equal(t, "192.168.1.10", args[0])
	assert.Equal(t, "gateway-1", args[1])
	assert.Equal(t, "agent-1", args[2])
	assert.Equal(t, "demo", args[3])
	assert.Equal(t, "10.0.0.0/24", args[4])
	assert.Equal(t, "router.local", args[5])
	assert.Equal(t, "00:11:22:33:44:55", args[6])
	assert.Equal(t, true, args[7])
	assert.Equal(t, resp, args[8])
	assert.InEpsilon(t, loss, args[9], 0.0001)

	assertJSONEquals(t, []int{22, 443}, args[10])
	assertJSONEquals(t, []int{22}, args[11])
	assertJSONEquals(t, []models.PortResult{{Port: 22, Available: true}}, args[12])

	assert.Equal(t, now.UTC(), args[13])
	assert.Equal(t, now.Add(-time.Hour).UTC(), args[14])
	assertJSONEquals(t, map[string]string{"source": "tcp"}, args[15])
}

func TestBuildSweepHostStateArgsRequiresIdentifiers(t *testing.T) {
	state := &models.SweepHostState{}

	_, err := buildSweepHostStateArgs(state)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "host ip is required")

	state.HostIP = "1.2.3.4"
	_, err = buildSweepHostStateArgs(state)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "gateway id")

	state.GatewayID = "gateway"
	_, err = buildSweepHostStateArgs(state)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "agent id")
}

func TestBuildSweepHostStateArgsNilSlices(t *testing.T) {
	now := time.Now()
	state := &models.SweepHostState{
		HostIP:        "1.1.1.1",
		GatewayID:      "gateway",
		AgentID:       "agent",
		LastSweepTime: now,
		FirstSeen:     now,
	}

	args, err := buildSweepHostStateArgs(state)
	require.NoError(t, err)

	assert.Nil(t, args[10])
	assert.Nil(t, args[11])
	assert.Nil(t, args[12])
	assert.Nil(t, args[15])
	assert.Equal(t, "default", args[3])
}

func assertJSONEquals(t *testing.T, expected interface{}, actual interface{}) {
	t.Helper()

	raw, ok := actual.(json.RawMessage)
	if !ok {
		require.FailNow(t, "value is not json")
	}

	var decoded interface{}
	require.NoError(t, json.Unmarshal(raw, &decoded))

	expectedBytes, err := json.Marshal(expected)
	require.NoError(t, err)

	var expectedDecoded interface{}
	require.NoError(t, json.Unmarshal(expectedBytes, &expectedDecoded))

	assert.Equal(t, expectedDecoded, decoded)
}
