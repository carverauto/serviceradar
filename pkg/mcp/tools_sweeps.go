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
	"time"
)

// SweepFilterArgs represents arguments for network sweep filtering
type SweepFilterArgs struct {
	Filter    string     `json:"filter,omitempty"`     // SRQL WHERE clause
	StartTime *time.Time `json:"start_time,omitempty"` // Start time for sweep filtering
	EndTime   *time.Time `json:"end_time,omitempty"`   // End time for sweep filtering
	Limit     int        `json:"limit,omitempty"`      // Max results
	OrderBy   string     `json:"order_by,omitempty"`   // Field to sort by
	SortDesc  bool       `json:"sort_desc,omitempty"`  // Sort descending
	GatewayID  string     `json:"gateway_id,omitempty"`  // Filter by gateway ID
	Network   string     `json:"network,omitempty"`    // Filter by network range
}

// registerSweepTools registers all network sweep-related MCP tools
func (m *MCPServer) registerSweepTools() {
	m.registerGetSweepResultsTool()
	m.registerGetRecentSweepsTool()
	m.registerGetSweepSummaryTool()
}

// registerGetSweepResultsTool registers the sweeps.getResults tool
func (m *MCPServer) registerGetSweepResultsTool() {
	sweepFilterBuilder := &GenericFilterBuilder{
		FieldMappings: map[string]string{
			"gateway_id": "gateway_id",
			"network":   "network",
		},
		ResponseFields: []string{"gateway_id", "network", "start_time", "end_time"},
	}

	m.tools["sweeps.getResults"] = m.BuildGenericFilterToolWithBuilder(
		"sweeps.getResults",
		"Retrieves network sweep results with comprehensive filtering",
		"sweep_results",
		"sweep_results",
		sweepFilterBuilder,
	)
}

// registerGetRecentSweepsTool registers the sweeps.getRecentSweeps tool
func (m *MCPServer) registerGetRecentSweepsTool() {
	m.tools["sweeps.getRecentSweeps"] = MCPTool{
		Name:        "sweeps.getRecentSweeps",
		Description: "Get recent network sweeps with simple filtering",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var recentArgs struct {
				Limit    int    `json:"limit,omitempty"`     // Max results (default 20)
				GatewayID string `json:"gateway_id,omitempty"` // Optional gateway filter
				Hours    int    `json:"hours,omitempty"`     // Last N hours (default 24)
			}
			if err := json.Unmarshal(args, &recentArgs); err != nil {
				return nil, fmt.Errorf("invalid recent sweeps arguments: %w", err)
			}

			limit := recentArgs.Limit
			if limit <= 0 {
				limit = 20
			}

			hours := recentArgs.Hours
			if hours <= 0 {
				hours = 24
			}

			// Build time filter for recent sweeps
			startTime := time.Now().Add(-time.Duration(hours) * time.Hour)
			timeFilter := BuildTimeRangeFilter(&startTime, nil, "timestamp")

			var filters []string
			var queryParams []any
			if timeFilter != "" {
				filters = append(filters, timeFilter)
			}
			if recentArgs.GatewayID != "" {
				filters = append(filters, "gateway_id = $1")
				queryParams = append(queryParams, recentArgs.GatewayID)
			}

			combinedFilter := CombineFilters(filters...)

			// Build SRQL query for recent network sweeps
			query := BuildSRQL("sweep_results", combinedFilter, "timestamp", limit, true)

			m.logger.Debug().
				Str("query", query).
				Str("gateway_id", recentArgs.GatewayID).
				Int("hours", hours).
				Int("limit", limit).
				Msg("Executing recent sweeps query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQueryWithParams(ctx, query, queryParams, limit)
			if err != nil {
				return nil, fmt.Errorf("failed to execute recent sweeps query: %w", err)
			}

			return map[string]interface{}{
				"sweeps":     results,
				"count":      len(results),
				"query":      query,
				"limit":      limit,
				"hours":      hours,
				"gateway_id":  recentArgs.GatewayID,
				"start_time": startTime,
			}, nil
		},
	}
}

// registerGetSweepSummaryTool registers the sweeps.getSweepSummary tool
func (m *MCPServer) registerGetSweepSummaryTool() {
	m.tools["sweeps.getSweepSummary"] = MCPTool{
		Name:        "sweeps.getSweepSummary",
		Description: "Get summary statistics for network sweeps",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var summaryArgs struct {
				GatewayID  string     `json:"gateway_id,omitempty"`  // Optional gateway filter
				StartTime *time.Time `json:"start_time,omitempty"` // Start time filter
				EndTime   *time.Time `json:"end_time,omitempty"`   // End time filter
			}
			if err := json.Unmarshal(args, &summaryArgs); err != nil {
				return nil, fmt.Errorf("invalid sweep summary arguments: %w", err)
			}

			// Build time range filter if start/end times are provided
			timeFilter := BuildTimeRangeFilter(summaryArgs.StartTime, summaryArgs.EndTime, "timestamp")

			var filters []string
			var queryParams []any
			if timeFilter != "" {
				filters = append(filters, timeFilter)
			}
			if summaryArgs.GatewayID != "" {
				filters = append(filters, "gateway_id = $1")
				queryParams = append(queryParams, summaryArgs.GatewayID)
			}

			combinedFilter := CombineFilters(filters...)

			// Use a basic SRQL query to get all sweep results, then aggregate in memory
			// This is simpler than trying to construct complex aggregation SRQL
			query := BuildSRQL("sweep_results", combinedFilter, "timestamp", 0, true)

			m.logger.Debug().
				Str("query", query).
				Str("gateway_id", summaryArgs.GatewayID).
				Msg("Executing sweep summary query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQueryWithParams(ctx, query, queryParams, 0)
			if err != nil {
				return nil, fmt.Errorf("failed to execute sweep summary query: %w", err)
			}

			// Calculate summary statistics
			totalSweeps := len(results)
			gatewayCounts := make(map[string]int)
			networkCounts := make(map[string]int)

			for _, result := range results {
				if gatewayID, ok := result["gateway_id"].(string); ok {
					gatewayCounts[gatewayID]++
				}
				if network, ok := result["network"].(string); ok {
					networkCounts[network]++
				}
			}

			return map[string]interface{}{
				"total_sweeps":   totalSweeps,
				"gateway_counts":  gatewayCounts,
				"network_counts": networkCounts,
				"query":          query,
				"filters": map[string]interface{}{
					"gateway_id":  summaryArgs.GatewayID,
					"start_time": summaryArgs.StartTime,
					"end_time":   summaryArgs.EndTime,
				},
			}, nil
		},
	}
}
