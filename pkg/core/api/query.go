package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
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

	// Default limit if not specified
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

// prepareQuery prepares the SRQL query with pagination settings
func (s *APIServer) prepareQuery(req *QueryRequest) (*models.Query, map[string]interface{}, error) {
	// Parse the SRQL query
	p := srql.NewParser()

	query, err := p.Parse(req.Query)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to parse query: %w", err)
	}

	// Validate entity
	if query.Entity != models.Devices && query.Entity != models.Interfaces {
		return nil, nil, errors.New("pagination is only supported for devices and interfaces")
	}

	// Ensure ORDER BY exists for stable pagination
	if len(query.OrderBy) == 0 {
		defaultOrderField := "_tp_time"

		if s.dbType != parser.Proton {
			defaultOrderField = "last_seen" // Adjust for ClickHouse/ArangoDB
		}

		query.OrderBy = []models.OrderByItem{
			{Field: defaultOrderField, Direction: models.Descending},
		}
	}

	// Handle cursor
	var cursorData map[string]interface{}

	if req.Cursor != "" {
		cursorData, err = decodeCursor(req.Cursor)
		if err != nil {
			return nil, nil, errors.New("invalid cursor")
		}

		query.Conditions = append(query.Conditions, buildCursorConditions(query, cursorData, req.Direction)...)
	}

	// Set or update LIMIT
	query.Limit = req.Limit
	query.HasLimit = true

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

// executeQuery executes the translated query against the database.
func (s *APIServer) executeQuery(ctx context.Context, query string, entity models.EntityType) ([]map[string]interface{}, error) {
	// For Proton, we don't need to pass an additional parameter as the entity is already
	// properly formatted in the query with table() function
	if s.dbType == parser.Proton {
		return s.queryExecutor.ExecuteQuery(ctx, query)
	}

	// For other database types, use the existing logic
	switch entity {
	case models.Devices:
		return s.queryExecutor.ExecuteQuery(ctx, query, "devices")
	case models.Flows:
		return s.queryExecutor.ExecuteQuery(ctx, query, "flows")
	case models.Traps:
		return s.queryExecutor.ExecuteQuery(ctx, query, "traps")
	case models.Connections:
		return s.queryExecutor.ExecuteQuery(ctx, query, "connections")
	case models.Logs:
		return s.queryExecutor.ExecuteQuery(ctx, query, "logs")
	case models.Interfaces:
		return s.queryExecutor.ExecuteQuery(ctx, query, "interfaces")
	case models.SweepResults:
		return s.queryExecutor.ExecuteQuery(ctx, query, "sweep_results")
	case models.ICMPResults:
		return s.queryExecutor.ExecuteQuery(ctx, query, "icmp_results")
	case models.SNMPResults:
		return s.queryExecutor.ExecuteQuery(ctx, query, "snmp_results")
	default:
		return nil, fmt.Errorf("%w: %s", errUnsupportedEntity, entity)
	}
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

// buildEntitySpecificConditions builds additional conditions specific to the entity type
func buildEntitySpecificConditions(entity models.EntityType, cursorData map[string]interface{}) []models.Condition {
	var conditions []models.Condition

	switch entity {
	case models.Devices:
		if ip, ok := cursorData["ip"]; ok {
			conditions = append(conditions, models.Condition{
				Field:     "ip",
				Operator:  models.NotEquals,
				Value:     ip,
				LogicalOp: models.Or,
			})
		}
	case models.Interfaces:
		if deviceIP, ok := cursorData["device_ip"]; ok {
			conditions = append(conditions, models.Condition{
				Field:     "device_ip",
				Operator:  models.NotEquals,
				Value:     deviceIP,
				LogicalOp: models.Or,
			})
		}

		if ifIndex, ok := cursorData["ifIndex"]; ok {
			conditions = append(conditions, models.Condition{
				Field:     "ifIndex",
				Operator:  models.NotEquals,
				Value:     ifIndex,
				LogicalOp: models.Or,
			})
		}
	case models.Flows, models.Traps, models.Connections, models.Logs,
		models.SweepResults, models.ICMPResults, models.SNMPResults:
	}

	return conditions
}

func buildCursorConditions(query *models.Query, cursorData map[string]interface{}, direction string) []models.Condition {
	// Guard: must have at least one order by field
	if len(query.OrderBy) == 0 {
		return nil
	}

	orderField := query.OrderBy[0].Field

	// Guard: cursor must contain the order field
	orderValue, ok := cursorData[orderField]
	if !ok {
		return nil
	}

	// Determine operator based on direction and sort order
	op := determineOperator(direction, query.OrderBy[0].Direction)

	conditions := []models.Condition{{
		Field:    orderField,
		Operator: op,
		Value:    orderValue,
	}}

	// Add entity-specific conditions
	entityConditions := buildEntitySpecificConditions(query.Entity, cursorData)

	if len(entityConditions) > 0 {
		conditions = append(conditions, entityConditions...)
	}

	return conditions
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
	switch entity {
	case models.Devices:
		if ip, ok := result["ip"]; ok {
			cursorData["ip"] = ip
		}
	case models.Interfaces:
		if deviceIP, ok := result["device_ip"]; ok {
			cursorData["device_ip"] = deviceIP
		}

		if ifIndex, ok := result["ifIndex"]; ok {
			cursorData["ifIndex"] = ifIndex
		}
	case models.Flows:
		// No additional fields needed for now
	case models.Traps:
		// No additional fields needed for now
	case models.Connections:
		// No additional fields needed for now
	case models.Logs:
		// No additional fields needed for now
	case models.SweepResults:
		// No additional fields needed for now
	case models.ICMPResults:
		// No additional fields needed for now
	case models.SNMPResults:
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

// generateCursors creates next and previous cursors from query results
func generateCursors(query *models.Query, results []map[string]interface{}, _ parser.DatabaseType) (nextCursor, prevCursor string) {
	if len(results) == 0 {
		return "", ""
	}

	orderField := query.OrderBy[0].Field

	// Generate next cursor from last result
	lastResult := results[len(results)-1]
	nextCursorData := createCursorData(lastResult, orderField)

	addEntityFields(nextCursorData, lastResult, query.Entity)

	// Generate prev cursor from first result
	firstResult := results[0]
	prevCursorData := createCursorData(firstResult, orderField)

	addEntityFields(prevCursorData, firstResult, query.Entity)

	return encodeCursor(nextCursorData), encodeCursor(prevCursorData)
}
