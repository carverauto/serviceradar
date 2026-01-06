package mcp

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
)

type recordingParameterizedExecutor struct {
	lastQuery       string
	lastParams      []any
	lastLimit       int
	calledPlain     int
	calledWithParam int

	results []map[string]interface{}
}

func (r *recordingParameterizedExecutor) ExecuteSRQLQuery(_ context.Context, query string, limit int) ([]map[string]interface{}, error) {
	r.calledPlain++
	r.lastQuery = query
	r.lastLimit = limit
	r.lastParams = nil
	return r.results, nil
}

func (r *recordingParameterizedExecutor) ExecuteSRQLQueryWithParams(_ context.Context, query string, params []any, limit int) ([]map[string]interface{}, error) {
	r.calledWithParam++
	r.lastQuery = query
	r.lastParams = append([]any(nil), params...)
	r.lastLimit = limit
	return r.results, nil
}

var _ ParameterizedQueryExecutor = (*recordingParameterizedExecutor)(nil)

func TestDevicesGetDeviceBindsDeviceID(t *testing.T) {
	exec := &recordingParameterizedExecutor{
		results: []map[string]interface{}{
			{"device_id": "ok"},
		},
	}
	server := NewMCPServer(context.Background(), exec, logger.NewTestLogger(), &MCPConfig{Enabled: true}, nil)
	tool := server.tools["devices.getDevice"]

	payload := map[string]any{
		"device_id": "device' OR '1'='1",
	}
	raw, err := json.Marshal(payload)
	require.NoError(t, err)

	_, err = tool.Handler(context.Background(), raw)
	require.NoError(t, err)

	require.Equal(t, 0, exec.calledPlain)
	require.Equal(t, 1, exec.calledWithParam)
	require.Equal(t, "SHOW devices WHERE device_id = $1 LIMIT 1", exec.lastQuery)
	require.Equal(t, []any{payload["device_id"]}, exec.lastParams)
}

func TestLogsGetRecentLogsBindsGatewayID(t *testing.T) {
	exec := &recordingParameterizedExecutor{
		results: []map[string]interface{}{{"log": "ok"}},
	}
	server := NewMCPServer(context.Background(), exec, logger.NewTestLogger(), &MCPConfig{Enabled: true}, nil)
	tool := server.tools["logs.getRecentLogs"]

	raw, err := json.Marshal(map[string]any{
		"gateway_id": "gateway' OR '1'='1",
		"limit":     5,
	})
	require.NoError(t, err)

	_, err = tool.Handler(context.Background(), raw)
	require.NoError(t, err)

	require.Equal(t, 0, exec.calledPlain)
	require.Equal(t, 1, exec.calledWithParam)
	require.Equal(t, "SHOW logs WHERE gateway_id = $1 ORDER BY timestamp DESC LIMIT 5", exec.lastQuery)
	require.Equal(t, []any{"gateway' OR '1'='1"}, exec.lastParams)
}

func TestEventsGetEventsBindsMappedFilters(t *testing.T) {
	exec := &recordingParameterizedExecutor{
		results: []map[string]interface{}{{"event_type": "ok"}},
	}
	server := NewMCPServer(context.Background(), exec, logger.NewTestLogger(), &MCPConfig{Enabled: true}, nil)
	tool := server.tools["events.getEvents"]

	raw, err := json.Marshal(map[string]any{
		"event_type": "network_down' OR '1'='1",
		"severity":   "critical",
		"limit":      10,
	})
	require.NoError(t, err)

	_, err = tool.Handler(context.Background(), raw)
	require.NoError(t, err)

	require.Equal(t, 0, exec.calledPlain)
	require.Equal(t, 1, exec.calledWithParam)
	require.Equal(t, "SHOW events WHERE (event_type = $1) AND (severity = $2) ORDER BY _tp_time DESC LIMIT 10", exec.lastQuery)
	require.Equal(t, []any{"network_down' OR '1'='1", "critical"}, exec.lastParams)
}

func TestStructuredToolsRequireParameterizedExecutor(t *testing.T) {
	exec := &recordingExecutor{}
	server := NewMCPServer(context.Background(), exec, logger.NewTestLogger(), &MCPConfig{Enabled: true}, nil)
	tool := server.tools["devices.getDevice"]

	raw, err := json.Marshal(map[string]any{
		"device_id": "device-123",
	})
	require.NoError(t, err)

	_, err = tool.Handler(context.Background(), raw)
	require.Error(t, err)
	require.Contains(t, err.Error(), "parameterized SRQL")
}
