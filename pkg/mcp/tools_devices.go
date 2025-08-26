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
)

// DeviceFilterArgs represents arguments for device filtering
type DeviceFilterArgs struct {
	Filter   string `json:"filter,omitempty"`    // SRQL WHERE clause
	Limit    int    `json:"limit,omitempty"`     // Max results
	OrderBy  string `json:"order_by,omitempty"`  // Field to sort by
	SortDesc bool   `json:"sort_desc,omitempty"` // Sort descending
}

// DeviceIDArgs represents arguments for single device retrieval
type DeviceIDArgs struct {
	DeviceID string `json:"device_id"` // Device identifier
}

// registerDeviceTools registers all device-related MCP tools
func (m *MCPServer) registerDeviceTools() {
	// Tool: devices.getDevices - Retrieves device list with filtering, sorting, and pagination
	m.tools["devices.getDevices"] = MCPTool{
		Name:        "devices.getDevices",
		Description: "Retrieves device list with filtering, sorting, and pagination",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var deviceArgs DeviceFilterArgs
			if err := json.Unmarshal(args, &deviceArgs); err != nil {
				return nil, fmt.Errorf("invalid device filter arguments: %w", err)
			}

			// Build SRQL query for devices
			query := BuildSRQL("devices", deviceArgs.Filter, deviceArgs.OrderBy, deviceArgs.Limit, deviceArgs.SortDesc)

			m.logger.Debug().Str("query", query).Msg("Executing device query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, query, deviceArgs.Limit)
			if err != nil {
				return nil, fmt.Errorf("failed to execute device query: %w", err)
			}

			return map[string]interface{}{
				"devices": results,
				"count":   len(results),
				"query":   query,
			}, nil
		},
	}

	// Tool: devices.getDevice - Retrieves single device by ID
	m.tools["devices.getDevice"] = MCPTool{
		Name:        "devices.getDevice",
		Description: "Retrieves single device by ID",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var deviceIDArgs DeviceIDArgs
			if err := json.Unmarshal(args, &deviceIDArgs); err != nil {
				return nil, fmt.Errorf("invalid device ID arguments: %w", err)
			}

			if deviceIDArgs.DeviceID == "" {
				return nil, errDeviceIDRequired
			}

			// Build SRQL query for specific device
			filter := fmt.Sprintf("device_id = '%s'", deviceIDArgs.DeviceID)
			query := BuildSRQL("devices", filter, "", 1, false)

			m.logger.Debug().Str("device_id", deviceIDArgs.DeviceID).Str("query", query).Msg("Retrieving device")

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, query, 1)
			if err != nil {
				return nil, fmt.Errorf("failed to execute device query: %w", err)
			}

			if len(results) == 0 {
				return nil, fmt.Errorf("device not found: %s", deviceIDArgs.DeviceID)
			}

			return map[string]interface{}{
				"device": results[0],
				"query":  query,
			}, nil
		},
	}
}
