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

package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/carverauto/serviceradar/pkg/srql"
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
)

// Direction constants
const (
	DirectionNext = "next"
	DirectionPrev = "prev"
)

// QueryRequest represents the request body for SRQL queries
type QueryRequest struct {
	Query     string `json:"query" example:"show devices where ip = '192.168.1.1'"`
	Limit     int    `json:"limit,omitempty" example:"10"`
	Cursor    string `json:"cursor,omitempty" example:"eyJpcCI6IjE5Mi4xNjguMS4xIiwibGFzdF9zZWVuIjoiMjAyNS0wNS0zMCAxMjowMDowMCJ9"`
	Direction string `json:"direction,omitempty" example:"next"` // DirectionNext or DirectionPrev
}

// QueryResponse represents the response for SRQL queries
type QueryResponse struct {
	Results    []map[string]interface{} `json:"results"`
	Pagination PaginationMetadata       `json:"pagination"`
	Error      string                   `json:"error,omitempty"`
}

// PaginationMetadata contains pagination information
type PaginationMetadata struct {
	NextCursor string `json:"next_cursor,omitempty"`
	PrevCursor string `json:"prev_cursor,omitempty"`
	Limit      int    `json:"limit"`
}

// @Summary Execute SRQL query with pagination
// @Description Executes a ServiceRadar Query Language (SRQL) query against the database with optional pagination
// @Tags SRQL
// @Accept json
// @Produce json
// @Param query body QueryRequest true "SRQL query with pagination parameters"
// @Success 200 {object} QueryResponse "Query results with pagination metadata"
// @Failure 400 {object} models.ErrorResponse "Invalid query or request"
// @Failure 401 {object} models.ErrorResponse "Unauthorized"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/query [post]
// @Security ApiKeyAuth
// validateQueryRequest validates the query request parameters
func validateQueryRequest(req *QueryRequest) (errMsg string, statusCode int, ok bool) {
	if req.Query == "" {
		errMsg = "Query string is required"
		statusCode = http.StatusBadRequest
		ok = false

		return errMsg, statusCode, ok
	}

	// Set default limit to 10 if not specified or invalid
	if req.Limit <= 0 {
		req.Limit = 10
	}

	// Validate direction
	if req.Direction != "" && req.Direction != DirectionNext && req.Direction != DirectionPrev {
		errMsg = fmt.Sprintf("Direction must be '%s' or '%s'", DirectionNext, DirectionPrev)
		statusCode = http.StatusBadRequest
		ok = false

		return errMsg, statusCode, ok
	}

	errMsg = ""
	statusCode = 0
	ok = true

	return errMsg, statusCode, ok
}

// setupOrderFields configures the order fields for a query
func (s *APIServer) setupOrderFields(query *models.Query) {
	var defaultOrderField string
	if len(query.OrderBy) == 0 {
		defaultOrderField = "_tp_time" // Default for Proton

		if s.dbType != parser.Proton {
			defaultOrderField = "last_seen" // Adjust for other DBs
		}

		query.OrderBy = []models.OrderByItem{
			{Field: defaultOrderField, Direction: models.Descending},
		}
	} else {
		// If an OrderBy exists, use its primary field as the "default" for the next check.
		defaultOrderField = query.OrderBy[0].Field
	}

	// Step 2: Ensure the sort order is stable by adding a tie-breaker field.
	// This runs after the default is set, ensuring stability for all paginated queries.
	if len(query.OrderBy) == 1 && query.OrderBy[0].Field == defaultOrderField {
		switch query.Entity {
		case models.SweepResults, models.Devices:
			// Add 'ip' as a default secondary sort key for stable pagination.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "ip",
				Direction: models.Descending, // Must be consistent
			})
		case models.Services:
			// Use service_name as the secondary sort key for services.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "service_name",
				Direction: models.Descending,
			})
		case models.Interfaces:
			// Use device_ip as the secondary sort key for interfaces.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "device_ip",
				Direction: models.Descending,
			})
		case models.Events:
			// Use id as the secondary sort key for events.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "id",
				Direction: models.Descending,
			})
		case models.Pollers:
			// Use poller_id as the secondary sort key for pollers.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "poller_id",
				Direction: models.Descending,
			})
		case models.ICMPResults:
			// Use ip as the secondary sort key for ICMP results.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "ip",
				Direction: models.Descending,
			})
		case models.SNMPResults:
			// Use ip as the secondary sort key for SNMP results.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "ip",
				Direction: models.Descending,
			})
		case models.CPUMetrics:
			// Use core_id as a secondary sort key for stability.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "core_id",
				Direction: models.Descending,
			})
		case models.DiskMetrics:
			// Use mount_point as a secondary sort key.
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     "mount_point",
				Direction: models.Descending,
			})
		// These entities don't need additional sort fields
		case models.Flows, models.Traps, models.Connections, models.Logs, models.MemoryMetrics:
		}
	}
}

// processCursorAndLimit handles cursor decoding and limit setting for a query
func (*APIServer) processCursorAndLimit(query *models.Query, req *QueryRequest) (map[string]interface{}, error) {
	var cursorData map[string]interface{}

	var err error

	// Handle cursor
	if req.Cursor != "" {
		cursorData, err = decodeCursor(req.Cursor)
		if err != nil {
			return nil, errors.New("invalid cursor")
		}

		query.Conditions = append(query.Conditions, buildCursorConditions(query, cursorData, req.Direction)...)
	}

	// Set LIMIT: prioritize SRQL query's LIMIT, then req.Limit, then default to 10
	if !query.HasLimit {
		if req.Limit > 0 {
			query.Limit = req.Limit
			query.HasLimit = true
		} else {
			query.Limit = 10
			query.HasLimit = true
		}
	}

	return cursorData, nil
}

// isValidPaginationEntity checks if the entity supports pagination
func isValidPaginationEntity(entity models.EntityType) bool {
	validEntities := []models.EntityType{
		models.Devices,
		models.Services,
		models.Interfaces,
		models.SweepResults,
		models.Events,
		models.Pollers,
		models.CPUMetrics,
		models.DiskMetrics,
		models.MemoryMetrics,
	}

	for _, validEntity := range validEntities {
		if entity == validEntity {
			return true
		}
	}

	return false
}

// prepareQuery prepares the SRQL query with pagination settings
func (s *APIServer) prepareQuery(req *QueryRequest) (*models.Query, map[string]interface{}, error) {
	// Parse the SRQL query
	p := srql.NewParser()

	query, err := p.Parse(req.Query)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to parse query: %w", err)
	}

	// Validate entity for pagination. COUNT queries don't need pagination support.
	if query.Type != models.Count && !isValidPaginationEntity(query.Entity) {
		return nil, nil, errors.New("pagination is only supported for devices, services, interfaces, " +
			"sweep_results, events, pollers, and metric types")
	}

	// For COUNT queries, pagination ordering is unnecessary and may generate
	// invalid SQL (e.g., ORDER BY without GROUP BY). Skip order/limit logic.
	var cursorData map[string]interface{}

	if query.Type != models.Count {
		// Setup order fields
		s.setupOrderFields(query)

		// Process cursor and limit
		cursorData, err = s.processCursorAndLimit(query, req)
		if err != nil {
			return nil, nil, err
		}
	}

	return query, cursorData, nil
}

// executeQueryAndBuildResponse executes the query and builds the response
func (s *APIServer) executeQueryAndBuildResponse(ctx context.Context, query *models.Query, req *QueryRequest) (*QueryResponse, error) {
	// Translate to database query
	translator := parser.NewTranslator(s.dbType)

	dbQuery, err := translator.Translate(query)
	if err != nil {
		return nil, fmt.Errorf("failed to translate query: %w", err)
	}

	// Execute the query
	results, err := s.executeQuery(ctx, dbQuery, query.Entity)
	if err != nil {
		return nil, fmt.Errorf("failed to execute query: %w", err)
	}

	// Generate cursors
	nextCursor, prevCursor := generateCursors(query, results, s.dbType)

	// Prepare response
	response := &QueryResponse{
		Results: results,
		Pagination: PaginationMetadata{
			NextCursor: nextCursor,
			PrevCursor: prevCursor,
			Limit:      req.Limit,
		},
	}

	return response, nil
}

func (s *APIServer) handleSRQLQuery(w http.ResponseWriter, r *http.Request) {
	var req QueryRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Validate request
	if errMsg, statusCode, ok := validateQueryRequest(&req); !ok {
		writeError(w, errMsg, statusCode)
		return
	}

	// Prepare query
	query, _, err := s.prepareQuery(&req)
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Execute query and build response
	ctx, cancel := context.WithTimeout(r.Context(), defaultTimeout)
	defer cancel()

	response, err := s.executeQueryAndBuildResponse(ctx, query, &req)
	if err != nil {
		writeError(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if err := s.encodeJSONResponse(w, response); err != nil {
		writeError(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

var (
	errUnsupportedEntity = errors.New("unsupported entity")
)

// executeProtonQuery executes a query specifically for Proton database type
func (s *APIServer) executeProtonQuery(ctx context.Context, query string) ([]map[string]interface{}, error) {
	log.Println("Executing Proton query:", query)

	results, err := s.queryExecutor.ExecuteQuery(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("query error: %w", err)
	}

	return results, nil
}

// getTableNameForEntity returns the table name for a given entity type
func (s *APIServer) getTableNameForEntity(entity models.EntityType) (string, error) {
	// Since the entity type is the same in both packages, we can use it directly
	tableName, exists := s.entityTableMap[entity]
	if !exists {
		return "", fmt.Errorf("%w: %s", errUnsupportedEntity, entity)
	}

	return tableName, nil
}

// executeQuery executes the translated query against the database.
func (s *APIServer) executeQuery(ctx context.Context, query string, entity models.EntityType) ([]map[string]interface{}, error) {
	// For Proton, we don't need to pass an additional parameter as the entity is already
	// properly formatted in the query with table() function
	if s.dbType == parser.Proton {
		return s.executeProtonQuery(ctx, query)
	}

	// For other database types, use the existing logic
	tableName, err := s.getTableNameForEntity(entity)
	if err != nil {
		return nil, err
	}

	results, err := s.queryExecutor.ExecuteQuery(ctx, query, tableName)
	if err != nil {
		return nil, fmt.Errorf("query error: %w", err)
	}

	return results, nil
}

// decodeCursor decodes a Base64-encoded cursor into a map
func decodeCursor(cursor string) (map[string]interface{}, error) {
	data, err := base64.StdEncoding.DecodeString(cursor)
	if err != nil {
		return nil, fmt.Errorf("failed to decode cursor: %w", err)
	}

	var cursorData map[string]interface{}

	if err := json.Unmarshal(data, &cursorData); err != nil {
		return nil, fmt.Errorf("failed to parse cursor data: %w", err)
	}

	return cursorData, nil
}

// determineOperator determines the comparison operator based on direction and sort order
func determineOperator(direction string, sortDirection models.SortDirection) models.OperatorType {
	op := models.LessThan

	if direction == DirectionPrev {
		op = models.GreaterThan
	}

	if sortDirection == models.Ascending {
		op = models.GreaterThan

		if direction == DirectionPrev {
			op = models.LessThan
		}
	}

	return op
}

// In query.go, replace the existing buildCursorConditions with this new version
func buildCursorConditions(query *models.Query, cursorData map[string]interface{}, direction string) []models.Condition {
	if len(query.OrderBy) == 0 {
		return nil
	}

	// This function now correctly handles multi-column keyset pagination.
	// It builds a clause like: (field1 < val1) OR (field1 = val1 AND field2 < val2) ...

	// The outer container for all the OR groups
	outerOrConditions := make([]models.Condition, 0, len(query.OrderBy))

	// Iterate through each OrderBy item to build the nested clauses
	for i, orderItem := range query.OrderBy {
		// Create the AND conditions for this level of nesting
		currentLevelAnds := make([]models.Condition, 0, i+1)

		// Add equality checks for all previous sort keys
		for j := 0; j < i; j++ {
			prevItem := query.OrderBy[j]

			prevValue, ok := cursorData[prevItem.Field]
			if !ok {
				continue
			} // Should not happen with a valid cursor

			currentLevelAnds = append(currentLevelAnds, models.Condition{
				Field:     prevItem.Field,
				Operator:  models.Equals,
				Value:     prevValue,
				LogicalOp: models.And,
			})
		}

		// Add the main inequality check for the current sort key
		op := determineOperator(direction, orderItem.Direction)

		cursorValue, ok := cursorData[orderItem.Field]
		if !ok {
			continue
		}

		currentLevelAnds = append(currentLevelAnds, models.Condition{
			Field:     orderItem.Field,
			Operator:  op,
			Value:     cursorValue,
			LogicalOp: models.And,
		})

		// Group the AND conditions into a complex condition
		outerOrConditions = append(outerOrConditions, models.Condition{
			IsComplex: true,
			Complex:   currentLevelAnds,
			LogicalOp: models.Or,
		})
	}

	// If there's only one OR condition, we don't need to wrap it again.
	if len(outerOrConditions) == 1 {
		return []models.Condition{{
			LogicalOp: models.And,
			IsComplex: true,
			Complex:   outerOrConditions[0].Complex,
		}}
	}

	// Wrap all the OR groups in a final complex AND condition
	return []models.Condition{{
		LogicalOp: models.And,
		IsComplex: true,
		Complex:   outerOrConditions,
	}}
}

// createCursorData creates cursor data from a result
func createCursorData(result map[string]interface{}, orderField string) map[string]interface{} {
	cursorData := make(map[string]interface{})

	if value, ok := result[orderField]; ok {
		if t, isTime := value.(time.Time); isTime {
			cursorData[orderField] = t.Format(time.RFC3339)
		} else {
			cursorData[orderField] = value
		}
	}

	return cursorData
}

// addEntityFields adds entity-specific fields to cursor data
func addEntityFields(cursorData, result map[string]interface{}, entity models.EntityType) {
	// Map entity types to the fields that should be copied from result to cursor data
	entityFieldMap := map[models.EntityType][]string{
		models.Devices:      {"ip"},
		models.Interfaces:   {"device_ip", "ifIndex"},
		models.SweepResults: {"ip"},
		models.Services:     {"service_name"},
		models.Events:       {"id"},
		models.Pollers:      {"poller_id"},
		models.CPUMetrics:   {"core_id"},
		models.DiskMetrics:  {"mount_point"},
		// The following entities don't need additional fields:
		// models.Flows, models.Traps, models.Connections, models.Logs,
		// models.ICMPResults, models.SNMPResults, models.MemoryMetrics
	}

	// Get the fields to copy for this entity type
	fields, exists := entityFieldMap[entity]
	if !exists {
		return // No fields to copy for this entity type
	}

	// Copy each field from result to cursorData if it exists
	for _, field := range fields {
		if value, ok := result[field]; ok {
			cursorData[field] = value
		}
	}
}

// encodeCursor encodes cursor data to a string
func encodeCursor(cursorData map[string]interface{}) string {
	if len(cursorData) == 0 {
		return ""
	}

	bytes, err := json.Marshal(cursorData)
	if err != nil {
		return ""
	}

	return base64.StdEncoding.EncodeToString(bytes)
}

// generateCursors creates next and previous cursors from query results.
func generateCursors(query *models.Query, results []map[string]interface{}, _ parser.DatabaseType) (nextCursor, prevCursor string) {
	// COUNT queries and queries without an explicit order-by clause do not
	// support pagination. Additionally, skip when there are no results.
	if len(results) == 0 || query.Type == models.Count || len(query.OrderBy) == 0 {
		return "", "" // No cursors generated.
	}

	if query.HasLimit && len(results) == query.Limit {
		orderField := query.OrderBy[0].Field
		lastResult := results[len(results)-1]
		nextCursorData := createCursorData(lastResult, orderField)
		addEntityFields(nextCursorData, lastResult, query.Entity)

		nextCursor = encodeCursor(nextCursorData)
	}

	orderField := query.OrderBy[0].Field
	firstResult := results[0]
	prevCursorData := createCursorData(firstResult, orderField)
	addEntityFields(prevCursorData, firstResult, query.Entity)
	prevCursor = encodeCursor(prevCursorData)

	return nextCursor, prevCursor
}
