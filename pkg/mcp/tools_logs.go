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
	"time"

	"github.com/carverauto/serviceradar/pkg/srql"
	"github.com/localrivet/gomcp/server"
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
	m.server.Tool("logs.getLogs", "Searches log entries with optional time filtering",
		func(ctx *server.Context, args LogFilterArgs) (interface{}, error) {
			// Build time range filter if start/end times are provided
			timeFilter := BuildTimeRangeFilter(args.StartTime, args.EndTime, "timestamp")
			
			// Combine user filter with time filter
			combinedFilter := CombineFilters(args.Filter, timeFilter)
			
			// Default ordering by timestamp descending if not specified
			orderBy := args.OrderBy
			sortDesc := args.SortDesc
			if orderBy == "" {
				orderBy = "timestamp"
				sortDesc = true
			}
			
			// Build SRQL query for logs
			query := BuildSRQL("logs", combinedFilter, orderBy, args.Limit, sortDesc)
			
			m.logger.Debug().
				Str("query", query).
				Str("time_filter", timeFilter).
				Msg("Executing log query")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse log query: %w", err)
			}
			
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert log query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute log query: %w", err)
			}
			
			return map[string]interface{}{
				"logs":    results,
				"count":   len(results),
				"query":   query,
				"filters": map[string]interface{}{
					"user_filter": args.Filter,
					"time_filter": timeFilter,
					"combined":    combinedFilter,
					"start_time":  args.StartTime,
					"end_time":    args.EndTime,
				},
			}, nil
		})

	// Tool: logs.getRecentLogs - Get recent logs with simple limit
	m.server.Tool("logs.getRecentLogs", "Get recent logs with simple limit",
		func(ctx *server.Context, args struct {
			Limit   int    `json:"limit,omitempty"`   // Max results (default 100)
			PollerID string `json:"poller_id,omitempty"` // Optional poller filter
		}) (interface{}, error) {
			limit := args.Limit
			if limit <= 0 {
				limit = 100
			}
			
			var filter string
			if args.PollerID != "" {
				filter = fmt.Sprintf("poller_id = '%s'", args.PollerID)
			}
			
			// Build SRQL query for recent logs
			query := BuildSRQL("logs", filter, "timestamp", limit, true)
			
			m.logger.Debug().
				Str("query", query).
				Int("limit", limit).
				Str("poller_id", args.PollerID).
				Msg("Executing recent logs query")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse recent logs query: %w", err)
			}
			
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert recent logs query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute recent logs query: %w", err)
			}
			
			return map[string]interface{}{
				"logs":  results,
				"count": len(results),
				"query": query,
				"parameters": map[string]interface{}{
					"limit":     limit,
					"poller_id": args.PollerID,
				},
			}, nil
		})
}