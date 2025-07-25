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

	devicemodels "github.com/carverauto/serviceradar/pkg/models"
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

// getSecondaryOrderField returns the appropriate secondary order field for a given entity type
func (*APIServer) getSecondaryOrderField(entityType models.EntityType) (string, bool) {
	switch entityType {
	case models.Devices, models.DeviceUpdates, models.ICMPResults, models.SNMPResults:
		return "ip", true
	case models.Services:
		return "service_name", true
	case models.Interfaces:
		return "device_ip", true
	case models.Events:
		return "id", true
	case models.Pollers:
		return "poller_id", true
	case models.CPUMetrics:
		return "core_id", true
	case models.DiskMetrics:
		return "mount_point", true
	case models.ProcessMetrics:
		return "pid", true
	case models.SNMPMetrics:
		return "metric_name", true
	case models.Logs:
		return "trace_id", true
	// These entities don't need additional sort fields
	case models.Flows, models.Traps, models.Connections, models.MemoryMetrics:
		return "", false
	default:
		return "", false
	}
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
		secondaryField, hasSecondaryField := s.getSecondaryOrderField(query.Entity)
		if hasSecondaryField {
			query.OrderBy = append(query.OrderBy, models.OrderByItem{
				Field:     secondaryField,
				Direction: models.Descending, // Must be consistent
			})
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

		models.Events,
		models.Logs,
		models.Pollers,
		models.CPUMetrics,
		models.DiskMetrics,
		models.MemoryMetrics,
		models.ProcessMetrics,
		models.SNMPMetrics,
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
			"sweep_results, device_updates, events, logs, pollers, and metric types")
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
func (s *APIServer) executeQueryAndBuildResponse(
	ctx context.Context, query *models.Query, req *QueryRequest) (*QueryResponse, error) {
	// Store original limit for cursor generation
	originalLimit := query.Limit
	hasMore := false

	// For pagination queries, fetch one extra result to detect if there are more pages
	if query.HasLimit && len(query.OrderBy) > 0 && query.Type != models.Count {
		query.Limit = originalLimit + 1
	}

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

	// Post-process results for specific entity types
	results = s.postProcessResults(results, query.Entity)

	// Check if we got more results than requested (indicating more pages exist)
	if query.HasLimit && len(results) > originalLimit {
		hasMore = true
		// Trim results back to original limit
		results = results[:originalLimit]
	}

	// Restore original limit for cursor generation
	query.Limit = originalLimit

	// Generate cursors with hasMore information
	nextCursor, prevCursor := generateCursorsWithLookAhead(query, results, hasMore, s.dbType)

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
func (s *APIServer) executeQuery(
	ctx context.Context, query string, entity models.EntityType) ([]map[string]interface{}, error) {
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

// postProcessResults processes query results for specific entity types
func (s *APIServer) postProcessResults(
	results []map[string]interface{}, entity models.EntityType) []map[string]interface{} {
	if entity == models.Devices {
		return s.postProcessDeviceResults(results)
	}

	return results
}

// replaceIntegrationSource replaces generic "integration" discovery source with specific integration type
func replaceIntegrationSource(result map[string]interface{}) {
	sources, ok := result["discovery_sources"].([]string)
	if !ok {
		return
	}

	metadata, ok := result["metadata"].(map[string]interface{})
	if !ok {
		return
	}

	integrationType, ok := metadata["integration_type"].(string)
	if !ok || integrationType == "" {
		return
	}

	// Replace "integration" with specific type (e.g., "netbox", "armis")
	for i, source := range sources {
		if source == "integration" {
			sources[i] = integrationType
		}
	}

	result["discovery_sources"] = sources
}

// processMetadata handles the metadata field in different formats
func (*APIServer) processMetadata(result map[string]interface{}) {
	// Handle metadata from materialized view (new schema) or metadata_field (old schema)
	if metadataMap, ok := result["metadata"].(map[string]string); ok && len(metadataMap) > 0 {
		// New materialized view schema: metadata is directly a map[string]string
		metadata := make(map[string]interface{})

		for k, v := range metadataMap {
			metadata[k] = v
		}

		result["metadata"] = metadata

		return
	}

	if metadataFieldStr, ok := result["metadata_field"].(string); ok && metadataFieldStr != "" && metadataFieldStr != "{}" {
		// Old schema: metadata_field is a JSON string containing DiscoveredField
		var metadataField devicemodels.DiscoveredField[map[string]string]

		if err := json.Unmarshal([]byte(metadataFieldStr), &metadataField); err != nil {
			log.Printf("Warning: failed to unmarshal metadata_field for device: %v", err)

			result["metadata"] = map[string]interface{}{}
		} else {
			// Convert map[string]string to map[string]interface{} for JSON compatibility
			metadata := make(map[string]interface{})

			for k, v := range metadataField.Value {
				metadata[k] = v
			}

			result["metadata"] = metadata
		}

		return
	}

	// Default case
	result["metadata"] = map[string]interface{}{}
}

// processMAC handles the mac field in different formats
func (*APIServer) processMAC(result map[string]interface{}) {
	// Handle mac field - in new schema it's nullable(string), in old schema it might be JSON
	if macStr, ok := result["mac"].(string); ok && macStr != "" {
		// New schema: mac is direct string from unified_devices
		result["mac"] = macStr

		return
	}

	if macPtr, ok := result["mac"].(*string); ok && macPtr != nil && *macPtr != "" {
		// New schema: mac is nullable string (*string) from unified_devices
		result["mac"] = *macPtr

		return
	}

	if macFieldStr, ok := result["mac_field"].(string); ok && macFieldStr != "" && macFieldStr != "{}" {
		// Old schema: mac_field is JSON string - parse it
		var macField devicemodels.DiscoveredField[string]

		if err := json.Unmarshal([]byte(macFieldStr), &macField); err != nil {
			log.Printf("Warning: failed to unmarshal mac_field for device: %v", err)

			result["mac"] = nil
		} else {
			result["mac"] = macField.Value
		}

		return
	}

	// Default case
	result["mac"] = nil
}

// processHostname handles the hostname field in different formats
func (*APIServer) processHostname(result map[string]interface{}) {
	// Handle hostname field - in new schema it's nullable(string), in old schema it might be JSON
	if hostnameStr, ok := result["hostname"].(string); ok && hostnameStr != "" {
		// New schema: hostname is direct string from unified_devices
		log.Printf("DEBUG API: Device %v has hostname from direct string field: %s",
			result["device_id"], hostnameStr)

		result["hostname"] = hostnameStr

		return
	}

	if hostnamePtr, ok := result["hostname"].(*string); ok && hostnamePtr != nil && *hostnamePtr != "" {
		// New schema: hostname is nullable string (*string) from unified_devices
		log.Printf("DEBUG API: Device %v has hostname from pointer field: %s", result["device_id"], *hostnamePtr)
		result["hostname"] = *hostnamePtr

		return
	}

	if hostnameFieldStr, ok :=
		result["hostname_field"].(string); ok && hostnameFieldStr != "" && hostnameFieldStr != "{}" {
		// Old schema: hostname_field is JSON string - parse it
		var hostnameField devicemodels.DiscoveredField[string]

		if err := json.Unmarshal([]byte(hostnameFieldStr), &hostnameField); err != nil {
			log.Printf("Warning: failed to unmarshal hostname_field for device: %v", err)

			result["hostname"] = nil
		} else {
			log.Printf("DEBUG API: Device %v has hostname from JSON field: %s",
				result["device_id"], hostnameField.Value)

			result["hostname"] = hostnameField.Value
		}

		return
	}

	// Default case
	log.Printf("DEBUG API: Device %v has NO hostname (hostname: %v, hostname_field: %v)",
		result["device_id"], result["hostname"], result["hostname_field"])

	result["hostname"] = nil
}

// processStringDiscoverySources handles the case where discovery_sources is a string
func (*APIServer) processStringDiscoverySources(result map[string]interface{}, discoverySourcesStr string) {
	// Old schema: discovery_sources is JSON string - parse it
	var discoverySourcesInfo []devicemodels.DiscoverySourceInfo

	if err := json.Unmarshal([]byte(discoverySourcesStr), &discoverySourcesInfo); err != nil {
		log.Printf("Warning: failed to unmarshal discovery_sources for device: %v", err)

		result["discovery_sources"] = []string{}

		return
	}

	// Extract source names
	sources := make([]string, len(discoverySourcesInfo))

	for i, source := range discoverySourcesInfo {
		sources[i] = string(source.Source)
	}

	result["discovery_sources"] = sources

	// For old schema, extract agent_id and poller_id from first source if not already present
	if len(discoverySourcesInfo) > 0 {
		if _, hasAgentID := result["agent_id"]; !hasAgentID {
			result["agent_id"] = discoverySourcesInfo[0].AgentID
		}

		if _, hasPollerID := result["poller_id"]; !hasPollerID {
			result["poller_id"] = discoverySourcesInfo[0].PollerID
		}
	}
}

// processDiscoverySources handles the discovery_sources field in different formats
func (s *APIServer) processDiscoverySources(result map[string]interface{}) {
	// Handle discovery_sources field - in new schema it's array(string), in old schema it might be JSON
	if discoverySourcesArray, ok := result["discovery_sources"].([]string); ok && len(discoverySourcesArray) > 0 {
		// New schema: discovery_sources is already []string from unified_devices
		log.Printf("DEBUG API: Device %v has discovery_sources from string array: %v",
			result["device_id"], discoverySourcesArray)

		result["discovery_sources"] = discoverySourcesArray

		return
	}

	if discoverySourcesArray, ok := result["discovery_sources"].([]interface{}); ok {
		// Fallback: discovery_sources as []interface{}
		log.Printf("DEBUG API: Device %v has discovery_sources from interface array: %v", result["device_id"],
			discoverySourcesArray)

		sources := make([]string, len(discoverySourcesArray))

		for i, source := range discoverySourcesArray {
			if sourceStr, ok := source.(string); ok {
				sources[i] = sourceStr
			}
		}

		result["discovery_sources"] = sources

		return
	}

	if discoverySourcesStr, ok := result["discovery_sources"].(string); ok && discoverySourcesStr != "" {
		s.processStringDiscoverySources(result, discoverySourcesStr)
		return
	}

	// Default case
	log.Printf("DEBUG API: Device %v has NO discovery_sources (type: %T, value: %v)",
		result["device_id"], result["discovery_sources"], result["discovery_sources"])

	result["discovery_sources"] = []string{}
}

// postProcessDeviceResults processes device query results to parse JSON fields
func (s *APIServer) postProcessDeviceResults(results []map[string]interface{}) []map[string]interface{} {
	for _, result := range results {
		// Handle discovery_sources field
		s.processDiscoverySources(result)

		// Ensure agent_id and poller_id are set - in new schema they're direct columns
		if _, hasAgentID := result["agent_id"]; !hasAgentID {
			result["agent_id"] = ""
		}

		if _, hasPollerID := result["poller_id"]; !hasPollerID {
			result["poller_id"] = ""
		}

		// Handle hostname field
		s.processHostname(result)

		// Handle mac field
		s.processMAC(result)

		// Handle metadata field
		s.processMetadata(result)

		// Replace generic "integration" discovery source with specific integration type
		replaceIntegrationSource(result)

		// Remove the raw JSON fields that are no longer needed
		delete(result, "hostname_field")
		delete(result, "mac_field")
		delete(result, "metadata_field")
	}

	return results
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

			// Convert timestamp strings back to time.Time for proper comparison
			if strValue, isString := prevValue.(string); isString {
				if parsedTime, err := time.Parse(time.RFC3339, strValue); err == nil {
					prevValue = parsedTime
				}
			}

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

		// Convert timestamp strings back to time.Time for proper comparison
		if strValue, isString := cursorValue.(string); isString {
			if parsedTime, err := time.Parse(time.RFC3339, strValue); err == nil {
				cursorValue = parsedTime
			}
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
		models.Devices:        {"ip"},
		models.Interfaces:     {"device_ip", "ifIndex"},
		models.Services:       {"service_name"},
		models.Events:         {"id"},
		models.Pollers:        {"poller_id"},
		models.CPUMetrics:     {"core_id"},
		models.DiskMetrics:    {"mount_point"},
		models.ProcessMetrics: {"pid"},
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

// generateCursorsWithLookAhead creates next and previous cursors using look-ahead information.
func generateCursorsWithLookAhead(
	query *models.Query, results []map[string]interface{}, hasMore bool, _ parser.DatabaseType) (nextCursor, prevCursor string) {
	// COUNT queries and queries without an explicit order-by clause do not
	// support pagination. Additionally, skip when there are no results.
	if len(results) == 0 || query.Type == models.Count || len(query.OrderBy) == 0 {
		return "", "" // No cursors generated.
	}

	// Generate next cursor if we know there are more results
	if query.HasLimit && hasMore && len(results) > 0 {
		orderField := query.OrderBy[0].Field
		lastResult := results[len(results)-1]
		nextCursorData := createCursorData(lastResult, orderField)
		addEntityFields(nextCursorData, lastResult, query.Entity)

		nextCursor = encodeCursor(nextCursorData)
	}

	// Generate previous cursor (always when we have results)
	if len(results) > 0 {
		orderField := query.OrderBy[0].Field
		firstResult := results[0]
		prevCursorData := createCursorData(firstResult, orderField)
		addEntityFields(prevCursorData, firstResult, query.Entity)

		prevCursor = encodeCursor(prevCursorData)
	}

	return nextCursor, prevCursor
}

// generateCursors creates next and previous cursors from query results.
func generateCursors(
	query *models.Query, results []map[string]interface{}, _ parser.DatabaseType) (nextCursor, prevCursor string) {
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
