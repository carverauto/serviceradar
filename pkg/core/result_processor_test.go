package core

import (
	"encoding/json"
	"strconv"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestAddPortMetadataTruncatesLargePortSets(t *testing.T) {
	meta := map[string]string{}
	ports := make([]*models.PortResult, maxPortResultsDetailed+100)
	openCount := 0
	for i := 0; i < len(ports); i++ {
		available := i%2 == 0
		if available {
			openCount++
		}
		ports[i] = &models.PortResult{
			Port:      1000 + i,
			Available: available,
		}
	}

	addPortMetadata(meta, ports)

	require.Equal(t, strconv.Itoa(len(ports)), meta["port_result_count"])
	require.Equal(t, "true", meta["port_results_truncated"])
	require.Equal(t, strconv.Itoa(maxPortResultsDetailed), meta["port_results_retained"])

	var decoded []*models.PortResult
	require.NoError(t, json.Unmarshal([]byte(meta["port_results"]), &decoded))
	require.Len(t, decoded, maxPortResultsDetailed)

	var openPorts []int
	require.NoError(t, json.Unmarshal([]byte(meta["open_ports"]), &openPorts))
	expectedOpen := maxOpenPortsDetailed
	if maxOpenPortsDetailed > openCount {
		expectedOpen = openCount
	}
	require.Len(t, openPorts, expectedOpen)
	require.Equal(t, strconv.Itoa(openCount), meta["open_port_count"])
	require.Equal(t, strconv.FormatBool(openCount > maxOpenPortsDetailed), meta["open_ports_truncated"])
}

func TestAddPortMetadataKeepsSmallSets(t *testing.T) {
	meta := map[string]string{}
	ports := []*models.PortResult{
		{Port: 443, Available: true},
		{Port: 22, Available: false},
	}

	addPortMetadata(meta, ports)

	require.Equal(t, strconv.Itoa(len(ports)), meta["port_result_count"])
	require.Equal(t, "false", meta["port_results_truncated"])
	require.Equal(t, strconv.Itoa(len(ports)), meta["port_results_retained"])

	var decoded []*models.PortResult
	require.NoError(t, json.Unmarshal([]byte(meta["port_results"]), &decoded))
	require.Len(t, decoded, len(ports))

	var openPorts []int
	require.NoError(t, json.Unmarshal([]byte(meta["open_ports"]), &openPorts))
	require.Equal(t, []int{443}, openPorts)
	require.Equal(t, "false", meta["open_ports_truncated"])
}
