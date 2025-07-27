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
	"fmt"

	"github.com/carverauto/serviceradar/pkg/srql"
	"github.com/localrivet/gomcp/server"
)

// DeviceFilterArgs represents arguments for device filtering
type DeviceFilterArgs struct {
	Filter   string `json:"filter,omitempty"`   // SRQL WHERE clause
	Limit    int    `json:"limit,omitempty"`    // Max results
	OrderBy  string `json:"order_by,omitempty"` // Field to sort by
	SortDesc bool   `json:"sort_desc,omitempty"` // Sort descending
}

// DeviceIDArgs represents arguments for single device retrieval
type DeviceIDArgs struct {
	DeviceID string `json:"device_id"` // Device identifier
}

// registerDeviceTools registers all device-related MCP tools
func (m *MCPServer) registerDeviceTools() {
	// Tool: devices.getDevices - Retrieves device list with filtering, sorting, and pagination
	m.server.Tool("devices.getDevices", "Retrieves device list with filtering, sorting, and pagination",
		m.requireAuth(func(ctx *server.Context, args interface{}) (interface{}, error) {
			deviceArgs := args.(DeviceFilterArgs)
			// Build SRQL query for devices
			query := BuildSRQL("devices", deviceArgs.Filter, deviceArgs.OrderBy, deviceArgs.Limit, deviceArgs.SortDesc)
			
			m.logger.Debug().Str("query", query).Msg("Executing device query")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse device query: %w", err)
			}
			
			// Convert to SQL and execute
			// Note: This assumes there's a method to convert SRQL to SQL
			// You may need to adapt this based on your actual SRQL implementation
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert device query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute device query: %w", err)
			}
			
			return map[string]interface{}{
				"devices": results,
				"count":   len(results),
				"query":   query,
			}, nil
		}))

	// Tool: devices.getDevice - Retrieves single device by ID
	m.server.Tool("devices.getDevice", "Retrieves single device by ID",
		m.requireAuth(func(ctx *server.Context, args interface{}) (interface{}, error) {
			deviceIDArgs := args.(DeviceIDArgs)
			if deviceIDArgs.DeviceID == "" {
				return nil, fmt.Errorf("device_id is required")
			}
			
			// Build SRQL query for specific device
			filter := fmt.Sprintf("device_id = '%s'", deviceIDArgs.DeviceID)
			query := BuildSRQL("devices", filter, "", 1, false)
			
			m.logger.Debug().Str("device_id", deviceIDArgs.DeviceID).Str("query", query).Msg("Retrieving device")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse device query: %w", err)
			}
			
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert device query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
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
		}))
}

// convertSRQLToSQL converts a parsed SRQL query to SQL
func (m *MCPServer) convertSRQLToSQL(query interface{}) (string, error) {
	return ConvertSRQLToSQL(query)
}