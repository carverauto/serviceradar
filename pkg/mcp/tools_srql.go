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
	"strings"

	"github.com/carverauto/serviceradar/pkg/srql"
	"github.com/localrivet/gomcp/server"
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
	// Tool: srql.query - Direct SRQL execution for advanced users
	m.server.Tool("srql.query", "Execute raw SRQL queries for advanced users",
		func(ctx *server.Context, args SRQLQueryArgs) (interface{}, error) {
			if strings.TrimSpace(args.Query) == "" {
				return nil, fmt.Errorf("query is required")
			}
			
			m.logger.Debug().Str("query", args.Query).Msg("Executing raw SRQL query")
			
			// Parse the SRQL query
			parsedQuery, err := srql.Parse(args.Query)
			if err != nil {
				return nil, fmt.Errorf("failed to parse SRQL query: %w", err)
			}
			
			// Convert to SQL and execute
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to convert SRQL to SQL: %w", err)
			}
			
			results, err := m.db.ExecuteQuery(m.ctx, sqlQuery)
			if err != nil {
				return nil, fmt.Errorf("failed to execute SRQL query: %w", err)
			}
			
			return map[string]interface{}{
				"results":     results,
				"count":       len(results),
				"srql_query":  args.Query,
				"sql_query":   sqlQuery,
				"parsed":      parsedQuery,
			}, nil
		})

	// Tool: srql.validate - Validate SRQL syntax without execution
	m.server.Tool("srql.validate", "Validate SRQL query syntax without execution",
		func(ctx *server.Context, args SRQLQueryArgs) (interface{}, error) {
			if strings.TrimSpace(args.Query) == "" {
				return nil, fmt.Errorf("query is required")
			}
			
			m.logger.Debug().Str("query", args.Query).Msg("Validating SRQL query")
			
			// Parse the SRQL query to validate syntax
			parsedQuery, err := srql.Parse(args.Query)
			if err != nil {
				return map[string]interface{}{
					"valid":        false,
					"error":        err.Error(),
					"srql_query":   args.Query,
				}, nil
			}
			
			// Try to convert to SQL to validate semantics
			sqlQuery, err := m.convertSRQLToSQL(parsedQuery)
			if err != nil {
				return map[string]interface{}{
					"valid":        false,
					"error":        err.Error(),
					"srql_query":   args.Query,
					"parsed":       parsedQuery,
				}, nil
			}
			
			return map[string]interface{}{
				"valid":       true,
				"srql_query":  args.Query,
				"sql_query":   sqlQuery,
				"parsed":      parsedQuery,
			}, nil
		})

	// Tool: srql.schema - Get available tables and schema information
	m.server.Tool("srql.schema", "Get available tables and schema information for SRQL queries",
		func(ctx *server.Context, args SRQLSchemaArgs) (interface{}, error) {
			if args.Entity != "" {
				// Get schema for specific entity
				return m.getEntitySchema(args.Entity)
			}
			
			// Get all available entities/tables
			return m.getAllEntitiesSchema()
		})

	// Tool: srql.examples - Get example SRQL queries for learning
	m.server.Tool("srql.examples", "Get example SRQL queries for learning and reference",
		func(ctx *server.Context, args struct{}) (interface{}, error) {
			examples := []map[string]interface{}{
				{
					"category":    "devices",
					"description": "Get all devices",
					"query":       "SELECT * FROM devices",
				},
				{
					"category":    "devices",
					"description": "Get devices from specific poller",
					"query":       "SELECT * FROM devices WHERE poller_id = 'poller-001'",
				},
				{
					"category":    "devices", 
					"description": "Get devices discovered in last 24 hours",
					"query":       "SELECT * FROM devices WHERE timestamp > NOW() - INTERVAL 1 DAY",
				},
				{
					"category":    "logs",
					"description": "Get recent error logs",
					"query":       "SELECT * FROM logs WHERE level = 'error' ORDER BY timestamp DESC LIMIT 50",
				},
				{
					"category":    "logs",
					"description": "Get logs from specific time range",
					"query":       "SELECT * FROM logs WHERE timestamp BETWEEN '2025-01-01' AND '2025-01-02'",
				},
				{
					"category":    "events",
					"description": "Get critical events",
					"query":       "SELECT * FROM events WHERE severity = 'critical' ORDER BY timestamp DESC",
				},
				{
					"category":    "events",
					"description": "Get events by type",
					"query":       "SELECT * FROM events WHERE event_type = 'network_down' LIMIT 100",
				},
				{
					"category":    "sweeps",
					"description": "Get recent sweep results",
					"query":       "SELECT * FROM sweep_results WHERE timestamp > NOW() - INTERVAL 1 HOUR",
				},
				{
					"category":    "sweeps",
					"description": "Get sweep results for specific network",
					"query":       "SELECT * FROM sweep_results WHERE network = '192.168.1.0/24'",
				},
				{
					"category":    "aggregation",
					"description": "Count devices by poller",
					"query":       "SELECT poller_id, COUNT(*) as device_count FROM devices GROUP BY poller_id",
				},
				{
					"category":    "aggregation",
					"description": "Count events by severity",
					"query":       "SELECT severity, COUNT(*) as event_count FROM events GROUP BY severity",
				},
			}
			
			return map[string]interface{}{
				"examples": examples,
				"count":    len(examples),
				"note":     "These examples show basic SRQL syntax. Modify them for your specific use cases.",
			}, nil
		})
}

// getEntitySchema returns schema information for a specific entity
func (m *MCPServer) getEntitySchema(entity string) (interface{}, error) {
	// This would query the database schema for the specific table
	// For now, return a placeholder
	m.logger.Debug().Str("entity", entity).Msg("Getting schema for entity")
	
	// TODO: Implement actual schema querying
	// This should query information_schema or equivalent to get table structure
	query := fmt.Sprintf("DESCRIBE %s", entity)
	
	results, err := m.db.ExecuteQuery(m.ctx, query)
	if err != nil {
		// If DESCRIBE fails, try a different approach
		return map[string]interface{}{
			"entity": entity,
			"error":  fmt.Sprintf("Failed to get schema: %v", err),
			"note":   "Schema introspection not yet fully implemented",
		}, nil
	}
	
	return map[string]interface{}{
		"entity": entity,
		"schema": results,
		"query":  query,
	}, nil
}

// getAllEntitiesSchema returns information about all available entities
func (m *MCPServer) getAllEntitiesSchema() (interface{}, error) {
	m.logger.Debug().Msg("Getting all available entities")
	
	// Common ServiceRadar entities based on the design document
	entities := []map[string]interface{}{
		{
			"name":        "devices",
			"description": "Network devices discovered by ServiceRadar",
			"fields":      []string{"device_id", "poller_id", "ip", "mac", "hostname", "timestamp", "available"},
		},
		{
			"name":        "logs",
			"description": "System and application logs",
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
			"fields":      []string{"timestamp", "poller_id", "network", "ip", "port", "status"},
		},
		{
			"name":        "metrics",
			"description": "Performance and monitoring metrics",
			"fields":      []string{"timestamp", "poller_id", "metric_name", "value", "tags"},
		},
	}
	
	return map[string]interface{}{
		"entities": entities,
		"count":    len(entities),
		"note":     "Use srql.schema with entity parameter for detailed field information",
	}, nil
}