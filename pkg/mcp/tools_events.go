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

// EventFilterArgs represents arguments for event filtering
type EventFilterArgs struct {
	Filter    string     `json:"filter,omitempty"`     // SRQL WHERE clause
	StartTime *time.Time `json:"start_time,omitempty"` // Start time for event filtering
	EndTime   *time.Time `json:"end_time,omitempty"`   // End time for event filtering
	Limit     int        `json:"limit,omitempty"`      // Max results
	OrderBy   string     `json:"order_by,omitempty"`   // Field to sort by
	SortDesc  bool       `json:"sort_desc,omitempty"`  // Sort descending
	EventType string     `json:"event_type,omitempty"` // Filter by event type
	Severity  string     `json:"severity,omitempty"`   // Filter by severity level
}

// registerEventTools registers all event-related MCP tools
func (m *MCPServer) registerEventTools() {
	m.registerGetEventsTool()
	m.registerQueryEventsTool()
	m.registerGetAlertsTool()
	m.registerGetEventTypesTool()
}

// registerGetEventsTool registers the events.getEvents tool
func (m *MCPServer) registerGetEventsTool() {
	eventFilterBuilder := &GenericFilterBuilder{
		FieldMappings: map[string]string{
			"event_type": "event_type",
			"severity":   "severity",
		},
		ResponseFields: []string{"event_type", "severity", "start_time", "end_time"},
	}

	m.tools["events.getEvents"] = m.BuildGenericFilterToolWithBuilder(
		"events.getEvents",
		"Searches system/network events with comprehensive filtering",
		"events",
		"events",
		eventFilterBuilder,
	)
}

// registerQueryEventsTool registers the query_events tool for backward compatibility
func (m *MCPServer) registerQueryEventsTool() {
	m.tools["query_events"] = MCPTool{
		Name:        "query_events",
		Description: "Query system events with filters",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			return m.executeQueryEvents(ctx, args)
		},
	}
}

// registerGetAlertsTool registers the events.getAlerts tool
func (m *MCPServer) registerGetAlertsTool() {
	m.tools["events.getAlerts"] = MCPTool{
		Name:        "events.getAlerts",
		Description: "Get alert-level events (high severity events)",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var alertArgs struct {
				Limit     int        `json:"limit,omitempty"`      // Max results (default 50)
				StartTime *time.Time `json:"start_time,omitempty"` // Start time filter
				PollerID  string     `json:"poller_id,omitempty"`  // Optional poller filter
			}
			if err := json.Unmarshal(args, &alertArgs); err != nil {
				return nil, fmt.Errorf("invalid alert arguments: %w", err)
			}

			limit := alertArgs.Limit
			if limit <= 0 {
				limit = 50
			}

			// Build filters for high-severity events
			var filters []string
			filters = append(filters, "severity IN ('critical', 'high', 'alert')")

			if alertArgs.PollerID != "" {
				filters = append(filters, fmt.Sprintf("poller_id = '%s'", alertArgs.PollerID))
			}

			if alertArgs.StartTime != nil {
				timeFilter := BuildTimeRangeFilter(alertArgs.StartTime, nil, "timestamp")
				if timeFilter != "" {
					filters = append(filters, timeFilter)
				}
			}

			combinedFilter := CombineFilters(filters...)

			// Build SRQL query for alert events
			query := BuildSRQL("events", combinedFilter, "timestamp", limit, true)

			m.logger.Debug().Str("query", query).Msg("Executing alerts query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, query, limit)
			if err != nil {
				return nil, fmt.Errorf("failed to execute alerts query: %w", err)
			}

			return map[string]interface{}{
				"alerts": results,
				"count":  len(results),
				"query":  query,
				"filters": map[string]interface{}{
					"poller_id":  alertArgs.PollerID,
					"start_time": alertArgs.StartTime,
					"filter":     combinedFilter,
				},
			}, nil
		},
	}
}

// registerGetEventTypesTool registers the events.getEventTypes tool
func (m *MCPServer) registerGetEventTypesTool() {
	m.tools["events.getEventTypes"] = MCPTool{
		Name:        "events.getEventTypes",
		Description: "Get available event types in the system using SRQL",
		Handler: func(ctx context.Context, _ json.RawMessage) (interface{}, error) {
			// Use SRQL SHOW command to get distinct event types
			query := "SHOW events"

			m.logger.Debug().Str("query", query).Msg("Executing event types query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, query, 0)
			if err != nil {
				return nil, fmt.Errorf("failed to execute event types query: %w", err)
			}

			// Extract unique event types from results
			eventTypesMap := make(map[string]bool)
			for _, result := range results {
				if eventType, ok := result["event_type"].(string); ok && eventType != "" {
					eventTypesMap[eventType] = true
				}
			}

			// Convert to sorted slice
			var eventTypes []string
			for eventType := range eventTypesMap {
				eventTypes = append(eventTypes, eventType)
			}

			return map[string]interface{}{
				"event_types": eventTypes,
				"count":       len(eventTypes),
				"query":       query,
			}, nil
		},
	}
}
