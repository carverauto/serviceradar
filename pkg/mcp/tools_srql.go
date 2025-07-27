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
	"strings"
)

// SRQLQueryArgs represents arguments for direct SRQL execution
type SRQLQueryArgs struct {
	Query string `json:"query"` // Raw SRQL query string
}

// SRQLSchemaArgs represents arguments for schema queries
type SRQLSchemaArgs struct {
	Entity string `json:"entity,omitempty"` // Optional specific entity to describe
}

// registerSRQLTools registers the power-user SRQL tools
func (m *MCPServer) registerSRQLTools() {
	m.registerSRQLQueryTool()
	m.registerSRQLValidateTool()
	m.registerSRQLHelpTool()
	m.registerSRQLGetSchemaTool()
}

// registerSRQLQueryTool registers the srql.query tool
func (m *MCPServer) registerSRQLQueryTool() {
	m.tools["srql.query"] = MCPTool{
		Name:        "srql.query",
		Description: "Execute raw SRQL queries for advanced users",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var srqlArgs SRQLQueryArgs

			if err := json.Unmarshal(args, &srqlArgs); err != nil {
				return nil, fmt.Errorf("invalid SRQL query arguments: %w", err)
			}

			if strings.TrimSpace(srqlArgs.Query) == "" {
				return nil, fmt.Errorf("query is required")
			}

			m.logger.Debug().Str("query", srqlArgs.Query).Msg("Executing raw SRQL query")

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, srqlArgs.Query, 0)
			if err != nil {
				return nil, fmt.Errorf("failed to execute SRQL query: %w", err)
			}

			return map[string]interface{}{
				"results":    results,
				"count":      len(results),
				"srql_query": srqlArgs.Query,
			}, nil
		},
	}
}

// registerSRQLValidateTool registers the srql.validate tool
func (m *MCPServer) registerSRQLValidateTool() {
	m.tools["srql.validate"] = MCPTool{
		Name:        "srql.validate",
		Description: "Validate SRQL query syntax without execution",
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			var srqlArgs SRQLQueryArgs

			if err := json.Unmarshal(args, &srqlArgs); err != nil {
				return nil, fmt.Errorf("invalid SRQL validation arguments: %w", err)
			}

			if strings.TrimSpace(srqlArgs.Query) == "" {
				return nil, fmt.Errorf("query is required")
			}

			m.logger.Debug().Str("query", srqlArgs.Query).Msg("Validating SRQL query")

			// Try to execute the query with limit 0 to validate syntax
			_, err := m.executeSRQLQuery(ctx, srqlArgs.Query, 0)
			if err != nil {
				return map[string]interface{}{
					"valid":      false,
					"error":      err.Error(),
					"srql_query": srqlArgs.Query,
				}, nil
			}

			return map[string]interface{}{
				"valid":      true,
				"srql_query": srqlArgs.Query,
			}, nil
		},
	}
}

// registerSRQLGetSchemaTool registers the srql.schema tool
func (m *MCPServer) registerSRQLGetSchemaTool() {
	m.tools["srql.schema"] = MCPTool{
		Name:        "srql.schema",
		Description: "Get available tables and schema information for SRQL queries",
		Handler: func(_ context.Context, args json.RawMessage) (interface{}, error) {
			var schemaArgs SRQLSchemaArgs

			if err := json.Unmarshal(args, &schemaArgs); err != nil {
				return nil, fmt.Errorf("invalid schema arguments: %w", err)
			}

			if schemaArgs.Entity != "" {
				// Get schema for specific entity
				return m.getEntitySchema(schemaArgs.Entity), nil
			}

			// Get all available entities/tables
			return m.getAllEntitiesSchema(), nil
		},
	}
}

// registerSRQLHelpTool registers the srql.examples tool
func (m *MCPServer) registerSRQLHelpTool() {
	m.tools["srql.examples"] = MCPTool{
		Name:        "srql.examples",
		Description: "Get example SRQL queries for learning and reference",
		Handler: func(_ context.Context, _ json.RawMessage) (interface{}, error) {
			examples := []map[string]interface{}{
				{
					"category":    "devices",
					"description": "Get all devices",
					"query":       "SHOW devices",
				},
				{
					"category":    "devices",
					"description": "Get devices from specific poller",
					"query":       "SHOW devices WHERE poller_id = 'poller-001'",
				},
				{
					"category":    "devices",
					"description": "Get devices discovered in last 24 hours",
					"query":       "SHOW devices WHERE timestamp > NOW() - INTERVAL 1 DAY",
				},
				{
					"category":    "logs",
					"description": "Get recent error logs",
					"query":       "SHOW logs WHERE level = 'error' ORDER BY timestamp DESC LIMIT 50",
				},
				{
					"category":    "logs",
					"description": "Get logs from specific time range",
					"query":       "SHOW logs WHERE timestamp BETWEEN '2025-01-01' AND '2025-01-02'",
				},
				{
					"category":    "events",
					"description": "Get critical events",
					"query":       "SHOW events WHERE severity = 'critical' ORDER BY timestamp DESC",
				},
				{
					"category":    "events",
					"description": "Get events by type",
					"query":       "SHOW events WHERE event_type = 'network_down' LIMIT 100",
				},
				{
					"category":    "sweeps",
					"description": "Get recent sweep results",
					"query":       "SHOW sweep_results WHERE timestamp > NOW() - INTERVAL 1 HOUR",
				},
				{
					"category":    "sweeps",
					"description": "Get sweep results for specific network",
					"query":       "SHOW sweep_results WHERE network = '192.168.1.0/24'",
				},
				{
					"category":    "aggregation",
					"description": "Count devices by poller",
					"query":       "COUNT devices GROUP BY poller_id",
				},
				{
					"category":    "aggregation",
					"description": "Count events by severity",
					"query":       "COUNT events GROUP BY severity",
				},
			}

			return map[string]interface{}{
				"examples": examples,
				"count":    len(examples),
				"note":     "These examples show basic SRQL syntax. Modify them for your specific use cases.",
			}, nil
		},
	}
}

// getEntitySchema returns schema information for a specific entity
func (m *MCPServer) getEntitySchema(entity string) map[string]interface{} {
	query := fmt.Sprintf("SHOW %s", entity)

	// Execute a limited query to get sample data and infer schema
	results, err := m.executeSRQLQuery(m.ctx, query, 1)
	if err != nil {
		return map[string]interface{}{
			"entity":             entity,
			"error":              fmt.Sprintf("Cannot query entity %s: %v", entity, err),
			"available_entities": []string{"devices", "logs", "events", "sweep_results"},
		}
	}

	// Extract field names from the first result
	var fields []string

	if len(results) > 0 {
		for field := range results[0] {
			fields = append(fields, field)
		}
	}

	return map[string]interface{}{
		"entity": entity,
		"fields": fields,
		"query":  query,
	}
}

// getAllEntitiesSchema returns information about all available entities
func (*MCPServer) getAllEntitiesSchema() map[string]interface{} {
	entities := []map[string]interface{}{
		{
			"name":        "devices",
			"description": "Device discovery and availability information",
			"fields":      []string{"device_id", "ip", "hostname", "poller_id", "timestamp", "available"},
		},
		{
			"name":        "logs",
			"description": "System and application log entries",
			"fields":      []string{"timestamp", "level", "message", "poller_id", "source"},
		},
		{
			"name":        "events",
			"description": "System and network events",
			"fields":      []string{"timestamp", "event_type", "severity", "message", "poller_id"},
		},
		{
			"name":        "sweep_results",
			"description": "Network sweep and discovery results",
			"fields":      []string{"timestamp", "network", "poller_id", "discovered_devices"},
		},
	}

	return map[string]interface{}{
		"entities": entities,
		"count":    len(entities),
		"note":     "Use SHOW <entity> to query data from these entities",
	}
}
