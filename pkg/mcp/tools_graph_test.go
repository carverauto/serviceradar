/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package mcp

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/carverauto/serviceradar/pkg/logger"
)

type recordingExecutor struct {
	lastQuery string
	lastLimit int
	results   []map[string]interface{}
	err       error
}

func (r *recordingExecutor) ExecuteSRQLQuery(_ context.Context, query string, limit int) ([]map[string]interface{}, error) {
	r.lastQuery = query
	r.lastLimit = limit
	return r.results, r.err
}

func TestGraphToolBuildsQueryAndReturnsGraph(t *testing.T) {
	exec := &recordingExecutor{
		results: []map[string]interface{}{
			{
				"device": "device-alpha",
			},
		},
	}
	server := NewMCPServer(context.Background(), exec, logger.NewTestLogger(), &MCPConfig{Enabled: true}, nil)
	tool, ok := server.tools["graphs.getDeviceNeighborhood"]
	assert.True(t, ok, "graph tool should be registered")

	args := map[string]interface{}{
		"device_id":            "device-alpha",
		"collector_owned_only": true,
		"include_topology":     false,
	}
	raw, err := json.Marshal(args)
	assert.NoError(t, err)

	result, err := tool.Handler(context.Background(), raw)
	assert.NoError(t, err)

	assert.Equal(t, `in:device_graph device_id:"device-alpha" collector_owned:true include_topology:false`, exec.lastQuery)
	assert.Equal(t, 1, exec.lastLimit)

	payload, ok := result.(map[string]interface{})
	assert.True(t, ok, "result should be a map")
	assert.Equal(t, "device-alpha", payload["device_id"])
	assert.Equal(t, true, payload["collector_owned_only"])
	assert.Equal(t, false, payload["include_topology"])
	assert.Equal(t, 1, payload["count"])

	graph, ok := payload["graph"].(map[string]interface{})
	assert.True(t, ok, "graph payload should be a map")
	assert.Equal(t, "device-alpha", graph["device"])
}

func TestGraphToolRequiresDeviceID(t *testing.T) {
	exec := &recordingExecutor{}
	server := NewMCPServer(context.Background(), exec, logger.NewTestLogger(), &MCPConfig{Enabled: true}, nil)
	tool := server.tools["graphs.getDeviceNeighborhood"]

	raw, err := json.Marshal(map[string]interface{}{})
	assert.NoError(t, err)

	_, err = tool.Handler(context.Background(), raw)
	assert.ErrorIs(t, err, errDeviceIDRequired)
}

func TestGraphToolAliasAndDefaults(t *testing.T) {
	exec := &recordingExecutor{}
	server := NewMCPServer(context.Background(), exec, logger.NewTestLogger(), &MCPConfig{Enabled: true}, nil)
	tool := server.tools["graphs.getDeviceNeighborhood"]

	raw, err := json.Marshal(map[string]interface{}{
		"device_id":       "edge-1",
		"collector_owned": true, // Alias for collector_owned_only
	})
	assert.NoError(t, err)

	_, err = tool.Handler(context.Background(), raw)
	assert.NoError(t, err)

	assert.Equal(t, `in:device_graph device_id:"edge-1" collector_owned:true`, exec.lastQuery)
	assert.Equal(t, 1, exec.lastLimit)
}
