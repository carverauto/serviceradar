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
	"fmt"
	"strconv"
	"strings"
)

// DeviceGraphArgs represents arguments for fetching a device neighborhood graph.
type DeviceGraphArgs struct {
	DeviceID           string `json:"device_id"`
	CollectorOwnedOnly *bool  `json:"collector_owned_only,omitempty"`
	CollectorOwned     *bool  `json:"collector_owned,omitempty"` // Alias
	IncludeTopology    *bool  `json:"include_topology,omitempty"`
}

// registerGraphTools registers MCP tools that expose the AGE device graph.
func (m *MCPServer) registerGraphTools() {
	m.tools["graphs.getDeviceNeighborhood"] = MCPTool{
		Name:        "graphs.getDeviceNeighborhood",
		Description: "Fetches the AGE-backed neighborhood for a device, including collectors, services/checkers, targets, interfaces, and capability badges",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var graphArgs DeviceGraphArgs
			if err := json.Unmarshal(args, &graphArgs); err != nil {
				return nil, fmt.Errorf("invalid device graph arguments: %w", err)
			}

			deviceID := strings.TrimSpace(graphArgs.DeviceID)
			if deviceID == "" {
				return nil, errDeviceIDRequired
			}

			collectorOwned := false
			switch {
			case graphArgs.CollectorOwnedOnly != nil:
				collectorOwned = *graphArgs.CollectorOwnedOnly
			case graphArgs.CollectorOwned != nil:
				collectorOwned = *graphArgs.CollectorOwned
			}

			includeTopology := true
			if graphArgs.IncludeTopology != nil {
				includeTopology = *graphArgs.IncludeTopology
			}

			queryParts := []string{
				fmt.Sprintf("in:device_graph device_id:%s", strconv.Quote(deviceID)),
			}
			if collectorOwned {
				queryParts = append(queryParts, "collector_owned:true")
			}
			if !includeTopology {
				queryParts = append(queryParts, "include_topology:false")
			}
			query := strings.Join(queryParts, " ")

			m.logger.Debug().
				Str("query", query).
				Str("device_id", deviceID).
				Bool("collector_owned_only", collectorOwned).
				Bool("include_topology", includeTopology).
				Msg("Executing device graph query via MCP")

			results, err := m.executeSRQLQuery(ctx, query, 1)
			if err != nil {
				return nil, fmt.Errorf("failed to execute device graph query: %w", err)
			}

			var graph interface{}
			if len(results) > 0 {
				graph = results[0]
			}

			return map[string]interface{}{
				"device_id":            deviceID,
				"collector_owned_only": collectorOwned,
				"include_topology":     includeTopology,
				"graph":                graph,
				"count":                len(results),
				"srql_query":           query,
			}, nil
		},
	}
}
