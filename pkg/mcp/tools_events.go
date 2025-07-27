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

// EventFilterArgs represents arguments for event filtering
type EventFilterArgs struct {
	Filter     string     `json:"filter,omitempty"`      // SRQL WHERE clause
	StartTime  *time.Time `json:"start_time,omitempty"`  // Start time for event filtering
	EndTime    *time.Time `json:"end_time,omitempty"`    // End time for event filtering
	Limit      int        `json:"limit,omitempty"`       // Max results
	OrderBy    string     `json:"order_by,omitempty"`    // Field to sort by
	SortDesc   bool       `json:"sort_desc,omitempty"`   // Sort descending
	EventType  string     `json:"event_type,omitempty"`  // Filter by event type
	Severity   string     `json:"severity,omitempty"`    // Filter by severity level
}

// registerEventTools registers all event-related MCP tools
func (m *MCPServer) registerEventTools() {
	// Tool: events.getEvents - Searches system/network events with comprehensive filtering
	m.server.Tool("events.getEvents", "Searches system/network events with comprehensive filtering",
		func(ctx *server.Context, args EventFilterArgs) (interface{}, error) {
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
			if args.EventType != "" {
				filters = append(filters, fmt.Sprintf("event_type = '%s'", args.EventType))
			}
			if args.Severity != "" {
				filters = append(filters, fmt.Sprintf("severity = '%s'", args.Severity))
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
			
			// Build SRQL query for events
			query := BuildSRQL("events", combinedFilter, orderBy, args.Limit, sortDesc)
			
			m.logger.Debug().
				Str("query", query).
				Str("event_type", args.EventType).
				Str("severity", args.Severity).
				Msg("Executing events query")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse events query: %w", err)
			}
			
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert events query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute events query: %w", err)
			}
			
			return map[string]interface{}{
				"events": results,
				"count":  len(results),
				"query":  query,
				"filters": map[string]interface{}{
					"user_filter": args.Filter,
					"time_filter": timeFilter,
					"combined":    combinedFilter,
					"event_type":  args.EventType,
					"severity":    args.Severity,
					"start_time":  args.StartTime,
					"end_time":    args.EndTime,
				},
			}, nil
		})

	// Tool: events.getAlerts - Get alert-level events
	m.server.Tool("events.getAlerts", "Get alert-level events (high severity events)",
		func(ctx *server.Context, args struct {
			Limit     int        `json:"limit,omitempty"`      // Max results (default 50)
			StartTime *time.Time `json:"start_time,omitempty"` // Start time filter
			PollerID  string     `json:"poller_id,omitempty"`  // Optional poller filter
		}) (interface{}, error) {
			limit := args.Limit
			if limit <= 0 {
				limit = 50
			}
			
			// Build filters for alert-level events
			var filters []string
			filters = append(filters, "severity IN ('critical', 'error', 'warning')")
			
			if args.PollerID != "" {
				filters = append(filters, fmt.Sprintf("poller_id = '%s'", args.PollerID))
			}
			
			if args.StartTime != nil {
				timeFilter := BuildTimeRangeFilter(args.StartTime, nil, "timestamp")
				if timeFilter != "" {
					filters = append(filters, timeFilter)
				}
			}
			
			combinedFilter := CombineFilters(filters...)
			
			// Build SRQL query for alerts
			query := BuildSRQL("events", combinedFilter, "timestamp", limit, true)
			
			m.logger.Debug().
				Str("query", query).
				Int("limit", limit).
				Str("poller_id", args.PollerID).
				Msg("Executing alerts query")
			
			// Parse and execute SRQL
			parsedQuery, err := srql.Parse(query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse alerts query: %w", err)
			}
			
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert alerts query to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute alerts query: %w", err)
			}
			
			return map[string]interface{}{
				"alerts": results,
				"count":  len(results),
				"query":  query,
				"parameters": map[string]interface{}{
					"limit":      limit,
					"poller_id":  args.PollerID,
					"start_time": args.StartTime,
					"filter":     combinedFilter,
				},
			}, nil
		})

	// Tool: events.getEventTypes - Get available event types
	m.server.Tool("events.getEventTypes", "Get available event types in the system",
		func(ctx *server.Context, args struct{}) (interface{}, error) {
			// Query for distinct event types
			query := "SELECT DISTINCT event_type FROM events ORDER BY event_type"
			
			m.logger.Debug().Str("query", query).Msg("Executing event types query")
			
			results, err := m.db.ExecuteQuery(m.ctx, query)
			if err != nil {
				return nil, fmt.Errorf("failed to execute event types query: %w", err)
			}
			
			// Extract event types from results
			var eventTypes []string
			for _, result := range results {
				if eventType, ok := result["event_type"].(string); ok {
					eventTypes = append(eventTypes, eventType)
				}
			}
			
			return map[string]interface{}{
				"event_types": eventTypes,
				"count":       len(eventTypes),
				"query":       query,
			}, nil
		})
}