package armis

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestProcessDevices verifies that Armis devices are converted into KV entries and IP list
func TestProcessDevices(t *testing.T) {
	integ := &ArmisIntegration{
		Config: &models.SourceConfig{PollerID: "poller", Partition: "part"},
	}

	devices := []Device{
		{ID: 1, IPAddress: "192.168.1.1", MacAddress: "aa:bb", Name: "dev1", Tags: []string{"t1"}},
		{ID: 2, IPAddress: "192.168.1.2,10.0.0.1", MacAddress: "cc:dd", Name: "dev2"},
	}

	data, ips := integ.processDevices(devices)

	require.Len(t, data, 4) // two device keys and two sweep device entries
	assert.ElementsMatch(t, []string{"part:192.168.1.1", "part:192.168.1.2"}, keysWithPrefix(data, "part:"))
	assert.ElementsMatch(t, []string{"192.168.1.1/32", "192.168.1.2/32"}, ips)

	raw := data["1"]
	var withMeta DeviceWithMetadata
	require.NoError(t, json.Unmarshal(raw, &withMeta))
	assert.Equal(t, 1, withMeta.ID)
	assert.Equal(t, "t1", withMeta.Metadata["tag"])
}

// keysWithPrefix returns map keys that have the given prefix
func keysWithPrefix(m map[string][]byte, prefix string) []string {
	out := []string{}
	for k := range m {
		if len(k) >= len(prefix) && k[:len(prefix)] == prefix {
			out = append(out, k)
		}
	}
	return out
}

func TestPrepareArmisUpdateFromDeviceStates(t *testing.T) {
	integ := &ArmisIntegration{}
	states := []DeviceState{
		{IP: "1.1.1.1", IsAvailable: true, Metadata: map[string]interface{}{"armis_device_id": "10"}},
		{IP: "", IsAvailable: true, Metadata: map[string]interface{}{"armis_device_id": "11"}},
		{IP: "2.2.2.2", IsAvailable: false},
	}

	updates := integ.prepareArmisUpdateFromDeviceStates(states)
	require.Len(t, updates, 1)
	assert.Equal(t, 10, updates[0].DeviceID)
	assert.Equal(t, "1.1.1.1", updates[0].IP)
	assert.True(t, updates[0].Available)
}

func TestPrepareArmisUpdateFromDeviceQuery(t *testing.T) {
	integ := &ArmisIntegration{}
	results := []map[string]interface{}{
		{"ip": "1.1.1.1", "is_available": true, "metadata": map[string]interface{}{"armis_device_id": "5"}},
		{"ip": "", "is_available": true, "metadata": map[string]interface{}{"armis_device_id": "6"}},
		{"ip": "2.2.2.2", "is_available": false},
	}

	updates := integ.prepareArmisUpdateFromDeviceQuery(results)
	require.Len(t, updates, 1)
	assert.Equal(t, 5, updates[0].DeviceID)
	assert.Equal(t, "1.1.1.1", updates[0].IP)
	assert.True(t, updates[0].Available)
}

func TestConvertToDeviceStates(t *testing.T) {
	q := &SweepResultsQuery{}
	raw := []map[string]interface{}{
		{"ip": "1.1.1.1", "is_available": true, "metadata": map[string]interface{}{"x": "y"}},
	}
	states := q.convertToDeviceStates(raw)
	require.Len(t, states, 1)
	assert.Equal(t, "1.1.1.1", states[0].IP)
	assert.True(t, states[0].IsAvailable)
	assert.Equal(t, "y", states[0].Metadata["x"])
}

func TestConvertToSweepResults(t *testing.T) {
	q := &SweepResultsQuery{}
	ts := time.Now().UTC()
	raw := []map[string]interface{}{
		{"ip": "1.1.1.1", "available": true, "timestamp": ts.Format(time.RFC3339), "rtt": 1.5, "port": 80.0, "protocol": "icmp"},
	}
	res := q.convertToSweepResults(raw)
	require.Len(t, res, 1)
	assert.Equal(t, "1.1.1.1", res[0].IP)
	assert.True(t, res[0].Available)
	assert.WithinDuration(t, ts, res[0].Timestamp, time.Second)
	assert.Equal(t, 1.5, res[0].RTT)
	assert.Equal(t, 80, res[0].Port)
	assert.Equal(t, "icmp", res[0].Protocol)
}
