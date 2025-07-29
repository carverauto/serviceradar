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
	"time"
)

// BuildSRQL constructs an SRQL query from tool arguments
func BuildSRQL(entity, filter, orderBy string, limit int, sortDesc bool) string {
	var query strings.Builder

	// Start with SHOW
	query.WriteString("SHOW ")
	query.WriteString(entity)

	// Add WHERE clause if filter is provided
	if filter != "" {
		query.WriteString(" WHERE ")
		query.WriteString(filter)
	}

	// Add ORDER BY clause if specified
	if orderBy != "" {
		query.WriteString(" ORDER BY ")
		query.WriteString(orderBy)

		if sortDesc {
			query.WriteString(" DESC")
		}
	}

	// Add LIMIT clause if specified
	if limit > 0 {
		query.WriteString(fmt.Sprintf(" LIMIT %d", limit))
	}

	return query.String()
}

// BuildTimeRangeFilter creates a time range filter for SRQL queries
func BuildTimeRangeFilter(startTime, endTime *time.Time, timestampField string) string {
	if startTime == nil && endTime == nil {
		return ""
	}

	var conditions []string

	if startTime != nil {
		conditions = append(conditions, fmt.Sprintf("%s >= '%s'", timestampField, startTime.Format(time.RFC3339)))
	}

	if endTime != nil {
		conditions = append(conditions, fmt.Sprintf("%s <= '%s'", timestampField, endTime.Format(time.RFC3339)))
	}

	return strings.Join(conditions, " AND ")
}

// CombineFilters combines multiple filter conditions with AND
func CombineFilters(filters ...string) string {
	var nonEmptyFilters []string

	for _, filter := range filters {
		if strings.TrimSpace(filter) != "" {
			nonEmptyFilters = append(nonEmptyFilters, fmt.Sprintf("(%s)", filter))
		}
	}

	return strings.Join(nonEmptyFilters, " AND ")
}

// FilterQueryParams represents common query parameters for filtering
type FilterQueryParams struct {
	Filter    string     `json:"filter,omitempty"`
	StartTime *time.Time `json:"start_time,omitempty"`
	EndTime   *time.Time `json:"end_time,omitempty"`
	OrderBy   string     `json:"order_by,omitempty"`
	SortDesc  bool       `json:"sort_desc,omitempty"`
	Limit     int        `json:"limit,omitempty"`
}

const (
	defaultOrderBy = "timestamp"
)

// BuildFilteredQuery builds a filtered SRQL query using common parameters and additional filters
func BuildFilteredQuery(entity string, params FilterQueryParams, additionalFilters ...string) string {
	// Build time range filter if start/end times are provided
	timeFilter := BuildTimeRangeFilter(params.StartTime, params.EndTime, defaultOrderBy)

	// Build all filters
	var filters []string

	if params.Filter != "" {
		filters = append(filters, params.Filter)
	}

	if timeFilter != "" {
		filters = append(filters, timeFilter)
	}

	// Add any additional filters
	filters = append(filters, additionalFilters...)

	// Combine all filters
	combinedFilter := CombineFilters(filters...)

	// Default ordering by timestamp descending if not specified
	orderBy := params.OrderBy
	sortDesc := params.SortDesc

	if orderBy == "" {
		orderBy = defaultOrderBy
		sortDesc = true
	}

	// Build SRQL query
	return BuildSRQL(entity, combinedFilter, orderBy, params.Limit, sortDesc)
}

// FilterHandlerFunc represents a function that builds additional filters for a specific entity type
type FilterHandlerFunc func(args json.RawMessage) ([]string, map[string]interface{}, error)

// FilterBuilder defines an interface for building entity-specific filters
type FilterBuilder interface {
	BuildFilters(args json.RawMessage) ([]string, map[string]interface{}, error)
}

// GenericFilterBuilder implements FilterBuilder with configurable field mappings
type GenericFilterBuilder struct {
	FieldMappings  map[string]string // JSON field -> SQL field mapping
	ResponseFields []string          // Fields to include in response filters
}

// BuildFilters builds filters for a generic entity using field mappings
func (g *GenericFilterBuilder) BuildFilters(args json.RawMessage) (
	additionalFilters []string, responseFilters map[string]interface{}, err error) {
	var rawArgs map[string]interface{}

	if err = json.Unmarshal(args, &rawArgs); err != nil {
		return nil, nil, fmt.Errorf("invalid filter arguments: %w", err)
	}

	responseFilters = make(map[string]interface{})

	// Process field mappings
	for jsonField, sqlField := range g.FieldMappings {
		if value, exists := rawArgs[jsonField]; exists && value != nil {
			if strValue, ok := value.(string); ok && strValue != "" {
				additionalFilters = append(additionalFilters, fmt.Sprintf("%s = '%s'", sqlField, strValue))
			}
		}
	}

	// Build response filters
	for _, field := range g.ResponseFields {
		if value, exists := rawArgs[field]; exists {
			responseFilters[field] = value
		}
	}

	return additionalFilters, responseFilters, nil
}

// BuildGenericFilterTool creates a generic MCP tool for filtered queries
func (m *MCPServer) BuildGenericFilterTool(name, description, entity, resultsKey string, filterHandler FilterHandlerFunc) MCPTool {
	return MCPTool{
		Name:        name,
		Description: description,
		Handler: func(ctx context.Context, args json.RawMessage) (interface{}, error) {
			// Extract common filter parameters
			var commonParams FilterQueryParams
			if err := json.Unmarshal(args, &commonParams); err != nil {
				return nil, fmt.Errorf("invalid filter arguments: %w", err)
			}

			// Get entity-specific filters and response filters
			additionalFilters, responseFilters, err := filterHandler(args)
			if err != nil {
				return nil, err
			}

			// Build query using common logic
			query := BuildFilteredQuery(entity, commonParams, additionalFilters...)

			m.logger.Debug().Str("query", query).Msgf("Executing %s query", entity)

			// Execute SRQL query via API
			results, err := m.executeSRQLQuery(ctx, query, commonParams.Limit)
			if err != nil {
				return nil, fmt.Errorf("failed to execute %s query: %w", entity, err)
			}

			// Build response with common structure
			response := map[string]interface{}{
				resultsKey: results,
				"count":    len(results),
				"query":    query,
				"filters":  responseFilters,
			}

			return response, nil
		},
	}
}

// BuildGenericFilterToolWithBuilder creates a generic MCP tool using a FilterBuilder
func (m *MCPServer) BuildGenericFilterToolWithBuilder(name, description, entity, resultsKey string, filterBuilder FilterBuilder) MCPTool {
	return m.BuildGenericFilterTool(name, description, entity, resultsKey, filterBuilder.BuildFilters)
}
