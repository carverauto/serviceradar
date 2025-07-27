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

// LogFilterArgs represents arguments for log filtering
type LogFilterArgs struct {
	Filter    string     `json:"filter,omitempty"`     // SRQL WHERE clause
	StartTime *time.Time `json:"start_time,omitempty"` // Start time for log filtering
	EndTime   *time.Time `json:"end_time,omitempty"`   // End time for log filtering
	Limit     int        `json:"limit,omitempty"`      // Max results
	OrderBy   string     `json:"order_by,omitempty"`   // Field to sort by
	SortDesc  bool       `json:"sort_desc,omitempty"`  // Sort descending
}

// registerLogTools registers all log-related MCP tools
func (m *MCPServer) registerLogTools() {
	// Tool: logs.getLogs - Searches log entries with optional time filtering
	m.tools["logs.getLogs"] = MCPTool{
		Name:        "logs.getLogs",
		Description: "Searches log entries with optional time filtering",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var logArgs LogFilterArgs
			if err := json.Unmarshal(args, &logArgs); err != nil {
				return nil, fmt.Errorf("invalid log filter arguments: %w", err)
			}

			// Build time range filter if start/end times are provided
			timeFilter := BuildTimeRangeFilter(logArgs.StartTime, logArgs.EndTime, "timestamp")

			// Combine user filter with time filter
			combinedFilter := CombineFilters(logArgs.Filter, timeFilter)

			// Default ordering by timestamp descending if not specified
			orderBy := logArgs.OrderBy
			sortDesc := logArgs.SortDesc
			if orderBy == "" {
				orderBy = "timestamp"
				sortDesc = true
			}

			// Build SRQL query for logs
			query := BuildSRQL("logs", combinedFilter, orderBy, logArgs.Limit, sortDesc)

			m.logger.Debug().Str("query", query).Msg("Executing logs query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, query, logArgs.Limit)
			if err != nil {
				return nil, fmt.Errorf("failed to execute logs query: %w", err)
			}

			return map[string]interface{}{
				"logs":  results,
				"count": len(results),
				"query": query,
				"filters": map[string]interface{}{
					"start_time": logArgs.StartTime,
					"end_time":   logArgs.EndTime,
				},
			}, nil
		},
	}

	// Tool: logs.getRecentLogs - Get recent logs with simple limit
	m.tools["logs.getRecentLogs"] = MCPTool{
		Name:        "logs.getRecentLogs",
		Description: "Get recent logs with simple limit",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var recentArgs struct {
				Limit    int    `json:"limit,omitempty"`     // Max results (default 100)
				PollerID string `json:"poller_id,omitempty"` // Optional poller filter
			}
			if err := json.Unmarshal(args, &recentArgs); err != nil {
				return nil, fmt.Errorf("invalid recent logs arguments: %w", err)
			}

			limit := recentArgs.Limit
			if limit <= 0 {
				limit = 100
			}

			var filter string
			if recentArgs.PollerID != "" {
				filter = fmt.Sprintf("poller_id = '%s'", recentArgs.PollerID)
			}

			// Build SRQL query for recent logs
			query := BuildSRQL("logs", filter, "timestamp", limit, true)

			m.logger.Debug().
				Str("query", query).
				Str("poller_id", recentArgs.PollerID).
				Int("limit", limit).
				Msg("Executing recent logs query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, query, limit)
			if err != nil {
				return nil, fmt.Errorf("failed to execute recent logs query: %w", err)
			}

			return map[string]interface{}{
				"logs":      results,
				"count":     len(results),
				"query":     query,
				"limit":     limit,
				"poller_id": recentArgs.PollerID,
			}, nil
		},
	}
}
