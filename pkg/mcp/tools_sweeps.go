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

// SweepFilterArgs represents arguments for network sweep filtering
type SweepFilterArgs struct {
	Filter    string     `json:"filter,omitempty"`     // SRQL WHERE clause
	StartTime *time.Time `json:"start_time,omitempty"` // Start time for sweep filtering
	EndTime   *time.Time `json:"end_time,omitempty"`   // End time for sweep filtering
	Limit     int        `json:"limit,omitempty"`      // Max results
	OrderBy   string     `json:"order_by,omitempty"`   // Field to sort by
	SortDesc  bool       `json:"sort_desc,omitempty"`  // Sort descending
	PollerID  string     `json:"poller_id,omitempty"`  // Filter by poller ID
	Network   string     `json:"network,omitempty"`    // Filter by network range
}

// registerSweepTools registers all network sweep-related MCP tools
func (m *MCPServer) registerSweepTools() {
	// Tool: sweeps.getResults - Retrieves network sweep results with comprehensive filtering
	m.server.Tool("sweeps.getResults", "Retrieves network sweep results with comprehensive filtering",
		func(ctx *server.Context, args SweepFilterArgs) (interface{}, error) {
			// Build time range filter if start/end times are provided
			timeFilter := BuildTimeRangeFilter(args.StartTime, args.EndTime, "timestamp")
			
			// Build additional filters
			var filters []string
			if args.Filter != "" {
				filters = append(filters, args.Filter)
			}
			if timeFilter != "" {
				filters = append(filters, timeFilter)
			}
			if args.PollerID != "" {
				filters = append(filters, fmt.Sprintf("poller_id = '%s'", args.PollerID))
			}
			if args.Network != "" {
				filters = append(filters, fmt.Sprintf("network = '%s'", args.Network))
			}
			
			// Combine all filters
			combinedFilter := CombineFilters(filters...)
			
			// Default ordering by timestamp descending if not specified
			orderBy := args.OrderBy
			sortDesc := args.SortDesc
			if orderBy == "" {
				orderBy = "timestamp"
				sortDesc = true
			}
			
			// Build SRQL query for sweep results
			query := BuildSRQL("sweep_results", combinedFilter, orderBy, args.Limit, sortDesc)
			
			m.logger.Debug().
				Str("query", query).
				Str("poller_id", args.PollerID).
				Str("network", args.Network).
				Msg("Executing sweep results query")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse sweep results query: %w", err)
			}
			
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert sweep results query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute sweep results query: %w", err)
			}
			
			return map[string]interface{}{
				"sweep_results": results,
				"count":         len(results),
				"query":         query,
				"filters": map[string]interface{}{
					"user_filter": args.Filter,
					"time_filter": timeFilter,
					"combined":    combinedFilter,
					"poller_id":   args.PollerID,
					"network":     args.Network,
					"start_time":  args.StartTime,
					"end_time":    args.EndTime,
				},
			}, nil
		})

	// Tool: sweeps.getRecentSweeps - Get recent network sweeps
	m.server.Tool("sweeps.getRecentSweeps", "Get recent network sweeps with simple filtering",
		func(ctx *server.Context, args struct {
			Limit    int    `json:"limit,omitempty"`     // Max results (default 20)
			PollerID string `json:"poller_id,omitempty"` // Optional poller filter
			Hours    int    `json:"hours,omitempty"`     // Last N hours (default 24)
		}) (interface{}, error) {
			limit := args.Limit
			if limit <= 0 {
				limit = 20
			}
			
			hours := args.Hours
			if hours <= 0 {
				hours = 24
			}
			
			// Build time filter for recent sweeps
			startTime := time.Now().Add(-time.Duration(hours) * time.Hour)
			timeFilter := BuildTimeRangeFilter(&startTime, nil, "timestamp")
			
			var filters []string
			if timeFilter != "" {
				filters = append(filters, timeFilter)
			}
			if args.PollerID != "" {
				filters = append(filters, fmt.Sprintf("poller_id = '%s'", args.PollerID))
			}
			
			combinedFilter := CombineFilters(filters...)
			
			// Build SRQL query for recent sweeps
			query := BuildSRQL("sweep_results", combinedFilter, "timestamp", limit, true)
			
			m.logger.Debug().
				Str("query", query).
				Int("limit", limit).
				Int("hours", hours).
				Str("poller_id", args.PollerID).
				Msg("Executing recent sweeps query")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse recent sweeps query: %w", err)
			}
			
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert recent sweeps query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute recent sweeps query: %w", err)
			}
			
			return map[string]interface{}{
				"sweep_results": results,
				"count":         len(results),
				"query":         query,
				"parameters": map[string]interface{}{
					"limit":      limit,
					"hours":      hours,
					"poller_id":  args.PollerID,
					"start_time": startTime,
				},
			}, nil
		})

	// Tool: sweeps.getSweepSummary - Get summary statistics for network sweeps
	m.server.Tool("sweeps.getSweepSummary", "Get summary statistics for network sweeps",
		func(ctx *server.Context, args struct {
			PollerID  string     `json:"poller_id,omitempty"`  // Optional poller filter
			StartTime *time.Time `json:"start_time,omitempty"` // Start time filter
			EndTime   *time.Time `json:"end_time,omitempty"`   // End time filter
		}) (interface{}, error) {
			// Build time range filter if start/end times are provided
			timeFilter := BuildTimeRangeFilter(args.StartTime, args.EndTime, "timestamp")
			
			var filters []string
			if timeFilter != "" {
				filters = append(filters, timeFilter)
			}
			if args.PollerID != "" {
				filters = append(filters, fmt.Sprintf("poller_id = '%s'", args.PollerID))
			}
			
			whereClause := ""
			if len(filters) > 0 {
				whereClause = "WHERE " + CombineFilters(filters...)
			}
			
			// Build summary query
			query := fmt.Sprintf(`
				SELECT 
					COUNT(*) as total_sweeps,
					COUNT(DISTINCT poller_id) as unique_pollers,
					COUNT(DISTINCT network) as unique_networks,
					MIN(timestamp) as earliest_sweep,
					MAX(timestamp) as latest_sweep
				FROM sweep_results
				%s`, whereClause)
			
			m.logger.Debug().
				Str("query", query).
				Str("poller_id", args.PollerID).
				Msg("Executing sweep summary query")
			
			results, err := m.db.ExecuteQuery(m.ctx, query)
			if err != nil {
				return nil, fmt.Errorf("failed to execute sweep summary query: %w", err)
			}
			
			var summary interface{}
			if len(results) > 0 {
				summary = results[0]
			}
			
			return map[string]interface{}{
				"summary": summary,
				"query":   query,
				"filters": map[string]interface{}{
					"poller_id":  args.PollerID,
					"start_time": args.StartTime,
					"end_time":   args.EndTime,
					"applied":    whereClause,
				},
			}, nil
		})
}