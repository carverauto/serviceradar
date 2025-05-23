package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/srql"
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
)

// QueryRequest represents the request body for SRQL queries
type QueryRequest struct {
	Query string `json:"query" example:"show devices where ip = '192.168.1.1'"`
}

// QueryResponse represents the response for SRQL queries
type QueryResponse struct {
	Results []map[string]interface{} `json:"results"`
	Error   string                   `json:"error,omitempty"`
}

// @Summary Execute SRQL query
// @Description Executes a ServiceRadar Query Language (SRQL) query against the database
// @Tags SRQL
// @Accept json
// @Produce json
// @Param query body QueryRequest true "SRQL query string"
// @Success 200 {object} QueryResponse "Query results"
// @Failure 400 {object} models.ErrorResponse "Invalid query or request"
// @Failure 401 {object} models.ErrorResponse "Unauthorized"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/query [post]
// @Security ApiKeyAuth
func (s *APIServer) handleSRQLQuery(w http.ResponseWriter, r *http.Request) {
	var req QueryRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if req.Query == "" {
		writeError(w, "Query string is required", http.StatusBadRequest)
		return
	}

	// Parse the SRQL query
	p := srql.NewParser()

	query, err := p.Parse(req.Query)
	if err != nil {
		writeError(w, fmt.Sprintf("Failed to parse query: %v", err), http.StatusBadRequest)
		return
	}

	// Translate to database query using the appropriate translator
	translator := parser.NewTranslator(s.dbType)

	dbQuery, err := translator.Translate(query)
	if err != nil {
		writeError(w, fmt.Sprintf("Failed to translate query: %v", err), http.StatusInternalServerError)
		return
	}

	// Execute the query against the database
	ctx, cancel := context.WithTimeout(r.Context(), defaultTimeout)
	defer cancel()

	results, err := s.executeQuery(ctx, dbQuery, query.Entity)
	if err != nil {
		writeError(w, fmt.Sprintf("Failed to execute query: %v", err), http.StatusInternalServerError)
		return
	}

	// Prepare response
	response := QueryResponse{
		Results: results,
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
