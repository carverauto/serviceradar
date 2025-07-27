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

// Package mcp provides a simple, direct MCP implementation without external dependencies
package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/gorilla/mux"
)

// SimpleMCPServer implements MCP protocol directly
type SimpleMCPServer struct {
	queryExecutor api.SRQLQueryExecutor
	logger        logger.Logger
	config        *MCPConfig
	ctx           context.Context
	cancel        context.CancelFunc
}

// JSON-RPC 2.0 structures

type JSONRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type JSONRPCResponse struct {
	JSONRPC string        `json:"jsonrpc"`
	ID      interface{}   `json:"id"`
	Result  interface{}   `json:"result,omitempty"`
	Error   *JSONRPCError `json:"error,omitempty"`
}

type JSONRPCError struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

// MCP-specific structures
type InitializeParams struct {
	ProtocolVersion string                 `json:"protocolVersion"`
	Capabilities    map[string]interface{} `json:"capabilities"`
	ClientInfo      ClientInfo             `json:"clientInfo"`
}

type ClientInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

type ToolCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments,omitempty"`
}

type Tool struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	InputSchema interface{} `json:"inputSchema"`
}

// NewSimpleMCPServer creates a new simple MCP server
func NewSimpleMCPServer(
	parentCtx context.Context,
	queryExecutor api.SRQLQueryExecutor,
	log logger.Logger,
	config *MCPConfig,
) *SimpleMCPServer {
	ctx, cancel := context.WithCancel(parentCtx)

	return &SimpleMCPServer{
		queryExecutor: queryExecutor,
		logger:        log,
		config:        config,
		ctx:           ctx,
		cancel:        cancel,
	}
}

// RegisterRoutes adds MCP endpoints to the router
func (s *SimpleMCPServer) RegisterRoutes(router *mux.Router) {
	if s.config == nil {
		if s.logger != nil {
			s.logger.Error().Msg("MCP config is nil - cannot register routes")
		}

		return
	}

	if !s.config.Enabled {
		if s.logger != nil {
			s.logger.Info().Msg("MCP server disabled - skipping route registration")
		}

		return
	}

	// Add the single MCP endpoint that handles all JSON-RPC requests
	mcpRouter := router.PathPrefix("/mcp").Subrouter()
	mcpRouter.HandleFunc("", s.handleMCPRequest).Methods("POST", "OPTIONS")
	mcpRouter.HandleFunc("/", s.handleMCPRequest).Methods("POST", "OPTIONS")
}

// handleMCPRequest handles all MCP JSON-RPC requests
func (s *SimpleMCPServer) handleMCPRequest(w http.ResponseWriter, r *http.Request) {
	// Set CORS headers for browser-based MCP clients
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key")
	w.Header().Set("Content-Type", "application/json")

	// Handle preflight requests
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)

		return
	}

	// Authentication is now handled by the API server middleware

	var req JSONRPCRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.writeError(w, req.ID, -32700, "Parse error", err.Error())

		return
	}

	// Handle different MCP methods
	switch req.Method {
	case "initialize":
		s.handleInitialize(w, req)
	case "tools/list":
		s.handleToolsList(w, req)
	case "tools/call":
		s.handleToolCall(w, req, r)
	default:
		s.writeError(w, req.ID, -32601, "Method not found", fmt.Sprintf("Unknown method: %s", req.Method))
	}
}

// handleInitialize handles the MCP initialize request
func (s *SimpleMCPServer) handleInitialize(w http.ResponseWriter, req JSONRPCRequest) {
	result := map[string]interface{}{
		"protocolVersion": "2025-03-26",
		"capabilities": map[string]interface{}{
			"tools": map[string]interface{}{},
		},
		"serverInfo": map[string]interface{}{
			"name":    "serviceradar-mcp",
			"version": "1.0.0",
		},
	}

	s.writeSuccess(w, req.ID, result)
}

func getSimpleDeviceTools() []Tool {
	return []Tool{
		{
			Name:        "list_devices",
			Description: "List all devices in the system",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"limit": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of devices to return",
					},
					"type": map[string]interface{}{
						"type":        "string",
						"description": "Filter by device type",
					},
					"status": map[string]interface{}{
						"type":        "string",
						"description": "Filter by device status",
					},
				},
			},
		},
		{
			Name:        "get_device",
			Description: "Get detailed information about a specific device",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"device_id": map[string]interface{}{
						"type":        "string",
						"description": "The ID of the device to retrieve",
					},
				},
				"required": []string{"device_id"},
			},
		},
	}
}

func getSimpleQueryTools() []Tool {
	return []Tool{
		{
			Name:        "query_events",
			Description: "Query system events with filters",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"query": map[string]interface{}{
						"type":        "string",
						"description": "SRQL query for events",
					},
					"start_time": map[string]interface{}{
						"type":        "string",
						"description": "Start time for event filter",
					},
					"end_time": map[string]interface{}{
						"type":        "string",
						"description": "End time for event filter",
					},
					"limit": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of events to return",
					},
				},
			},
		},
		{
			Name:        "execute_srql",
			Description: "Execute SRQL queries directly",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"query": map[string]interface{}{
						"type":        "string",
						"description": "The SRQL query to execute",
					},
					"limit": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of results to return",
					},
				},
				"required": []string{"query"},
			},
		},
	}
}

func getSimpleLogTools() []Tool {
	return []Tool{
		{
			Name:        "logs.getLogs",
			Description: "Searches log entries with optional time filtering",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"filter": map[string]interface{}{
						"type":        "string",
						"description": "SRQL WHERE clause for filtering logs",
					},
					"start_time": map[string]interface{}{
						"type":        "string",
						"description": "Start time for log filtering (ISO format)",
					},
					"end_time": map[string]interface{}{
						"type":        "string",
						"description": "End time for log filtering (ISO format)",
					},
					"limit": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of logs to return",
					},
				},
			},
		},
		{
			Name:        "logs.getRecentLogs",
			Description: "Get recent logs with simple limit",
			InputSchema: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"limit": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of logs to return (default: 100)",
					},
					"poller_id": map[string]interface{}{
						"type":        "string",
						"description": "Optional poller ID filter",
					},
				},
			},
		},
	}
}

func getSimpleMCPToolsDefinition() []Tool {
	var tools []Tool
	tools = append(tools, getSimpleDeviceTools()...)
	tools = append(tools, getSimpleQueryTools()...)
	tools = append(tools, getSimpleLogTools()...)

	return tools
}

// handleToolsList handles the tools/list request
func (s *SimpleMCPServer) handleToolsList(w http.ResponseWriter, req JSONRPCRequest) {
	result := map[string]interface{}{
		"tools": getSimpleMCPToolsDefinition(),
	}

	s.writeSuccess(w, req.ID, result)
}

// handleToolCall handles the tools/call request
func (s *SimpleMCPServer) handleToolCall(w http.ResponseWriter, req JSONRPCRequest, r *http.Request) {
	var params ToolCallParams

	if err := json.Unmarshal(req.Params, &params); err != nil {
		s.writeError(w, req.ID, -32602, "Invalid params", err.Error())
		return
	}

	// Execute the tool based on its name
	var result interface{}

	var err error

	switch params.Name {
	case "list_devices":
		result, err = s.executeListDevices(r.Context(), params.Arguments)
	case "get_device":
		result, err = s.executeGetDevice(r.Context(), params.Arguments)
	case "query_events":
		result, err = s.executeQueryEvents(r.Context(), params.Arguments)
	case "execute_srql":
		result, err = s.executeExecuteSRQL(r.Context(), params.Arguments)
	case "logs.getLogs":
		result, err = s.executeQueryLogs(r.Context(), params.Arguments)
	case "logs.getRecentLogs":
		result, err = s.executeGetRecentLogs(r.Context(), params.Arguments)
	default:
		s.writeError(w, req.ID, -32602, "Unknown tool", fmt.Sprintf("Tool not found: %s", params.Name))
		return
	}

	if err != nil {
		s.writeError(w, req.ID, -32603, "Internal error", err.Error())
		return
	}

	// Format result according to MCP specification
	var content []map[string]interface{}

	// Convert result to JSON for proper formatting
	resultJSON, err := json.Marshal(result)
	if err != nil {
		s.writeError(w, req.ID, -32603, "Internal error", "Failed to marshal result")
		return
	}

	content = append(content, map[string]interface{}{
		"type": "text",
		"text": string(resultJSON),
	})

	s.writeSuccess(w, req.ID, map[string]interface{}{
		"content": content,
	})
}

// Tool execution methods
func (s *SimpleMCPServer) executeListDevices(ctx context.Context, args json.RawMessage) (interface{}, error) {
	return executeListDevices(ctx, args, s.queryExecutor)
}

func (s *SimpleMCPServer) executeGetDevice(ctx context.Context, args json.RawMessage) (interface{}, error) {
	var params struct {
		DeviceID string `json:"device_id"`
	}

	if err := json.Unmarshal(args, &params); err != nil {
		return nil, err
	}

	if params.DeviceID == "" {
		return nil, fmt.Errorf("device_id is required")
	}

	query := fmt.Sprintf("SHOW devices WHERE device_id = '%s' LIMIT 1", params.DeviceID)

	return s.queryExecutor.ExecuteSRQLQuery(ctx, query, 1)
}

func (s *SimpleMCPServer) executeQueryEvents(ctx context.Context, args json.RawMessage) (interface{}, error) {
	var params struct {
		Query     string `json:"query,omitempty"`
		StartTime string `json:"start_time,omitempty"`
		EndTime   string `json:"end_time,omitempty"`
		Limit     int    `json:"limit,omitempty"`
	}

	if len(args) > 0 {
		if err := json.Unmarshal(args, &params); err != nil {
			return nil, err
		}
	}

	// Build SRQL query if none provided
	if params.Query == "" {
		query := "SHOW events"
		conditions := []string{}

		if params.StartTime != "" {
			conditions = append(conditions, fmt.Sprintf("timestamp >= '%s'", params.StartTime))
		}

		if params.EndTime != "" {
			conditions = append(conditions, fmt.Sprintf("timestamp <= '%s'", params.EndTime))
		}

		if len(conditions) > 0 {
			query += " WHERE " + conditions[0]
			for _, condition := range conditions[1:] {
				query += " AND " + condition
			}
		}

		if params.Limit <= 0 {
			params.Limit = defaultLimit
		}

		query += fmt.Sprintf(" ORDER BY timestamp DESC LIMIT %d", params.Limit)
		params.Query = query
	}

	return s.queryExecutor.ExecuteSRQLQuery(ctx, params.Query, params.Limit)
}

func (s *SimpleMCPServer) executeExecuteSRQL(ctx context.Context, args json.RawMessage) (interface{}, error) {
	var params struct {
		Query string `json:"query"`
		Limit int    `json:"limit,omitempty"`
	}

	if err := json.Unmarshal(args, &params); err != nil {
		return nil, err
	}

	if params.Query == "" {
		return nil, fmt.Errorf("query is required")
	}

	if params.Limit <= 0 {
		params.Limit = defaultLimit
	}

	return s.queryExecutor.ExecuteSRQLQuery(ctx, params.Query, params.Limit)
}

func (s *SimpleMCPServer) executeQueryLogs(ctx context.Context, args json.RawMessage) (interface{}, error) {
	result, err := executeQueryLogs(ctx, args, s.queryExecutor)
	if err != nil {
		return nil, err
	}

	s.logger.Debug().Msg("Executing logs query")

	return result, nil
}

func (s *SimpleMCPServer) executeGetRecentLogs(ctx context.Context, args json.RawMessage) (interface{}, error) {
	result, err := executeGetRecentLogs(ctx, args, s.queryExecutor)
	if err != nil {
		return nil, err
	}

	s.logger.Debug().Msg("Executing recent logs query")

	return result, nil
}

// Utility methods
func (s *SimpleMCPServer) writeSuccess(w http.ResponseWriter, id, result interface{}) {
	response := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	}

	if err := json.NewEncoder(w).Encode(response); err != nil {
		if s.logger != nil {
			s.logger.Error().Err(err).Msg("Failed to encode MCP response")
		}
	}
}

func (s *SimpleMCPServer) writeError(w http.ResponseWriter, id interface{}, code int, message string, data interface{}) {
	response := JSONRPCResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error: &JSONRPCError{
			Code:    code,
			Message: message,
			Data:    data,
		},
	}

	if err := json.NewEncoder(w).Encode(response); err != nil {
		if s.logger != nil {
			s.logger.Error().Err(err).Msg("Failed to encode MCP error response")
		}
	}
}

// Stop stops the MCP server
func (s *SimpleMCPServer) Stop() error {
	if s.logger != nil {
		s.logger.Info().Msg("Stopping simple MCP server")
	}

	if s.cancel != nil {
		s.cancel()
	}

	return nil
}
