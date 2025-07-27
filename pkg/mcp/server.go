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

// Package mcp provides Model Context Protocol integration for ServiceRadar
package mcp

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/gorilla/mux"
)

//go:embed srql-mcp-prompt.md
var srqlPrompt string

// HTTP status codes
const (
	statusBadRequest          = 400
	statusNotFound            = 404
	statusInternalServerError = 500
)

const (
	defaultSRQLGuide = "srql-guide"
)

// MCPServer represents the ServiceRadar MCP server
type MCPServer struct {
	queryExecutor api.SRQLQueryExecutor
	logger        logger.Logger
	config        *MCPConfig
	authService   auth.AuthService
	ctx           context.Context
	cancel        context.CancelFunc
	tools         map[string]MCPTool
}

// MCPConfig holds configuration for the MCP server
type MCPConfig struct {
	Enabled bool   `json:"enabled"`
	APIKey  string `json:"api_key"`
}

// MCPTool represents an MCP tool that can be called
type MCPTool struct {
	Name        string
	Description string
	Handler     func(ctx context.Context, args json.RawMessage) (interface{}, error)
}

// MCPRequest represents an MCP tool call request
type MCPRequest struct {
	Method string `json:"method"`
	Params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	} `json:"params"`
}

// MCPResponse represents an MCP tool call response
type MCPResponse struct {
	Result interface{} `json:"result,omitempty"`
	Error  *MCPError   `json:"error,omitempty"`
}

// MCPError represents an MCP error
type MCPError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// NewMCPServer creates a new MCP server instance
func NewMCPServer(
	parentCtx context.Context,
	queryExecutor api.SRQLQueryExecutor,
	log logger.Logger,
	config *MCPConfig,
	authService auth.AuthService,
) *MCPServer {
	ctx, cancel := context.WithCancel(parentCtx)

	mcpServer := &MCPServer{
		queryExecutor: queryExecutor,
		logger:        log,
		config:        config,
		authService:   authService,
		ctx:           ctx,
		cancel:        cancel,
		tools:         make(map[string]MCPTool),
	}

	// Register all MCP tools
	mcpServer.registerDeviceTools()
	mcpServer.registerLogTools()
	mcpServer.registerEventTools()
	mcpServer.registerSweepTools()
	mcpServer.registerSRQLTools()

	return mcpServer
}

// RegisterRoutes adds MCP endpoints to the provided router
func (m *MCPServer) RegisterRoutes(router *mux.Router) {
	if !m.config.Enabled {
		if m.logger != nil {
			m.logger.Info().Msg("MCP server disabled - skipping route registration")
		}

		return
	}

	if m.logger != nil {
		m.logger.Info().Msg("Registering MCP routes")
	}

	// Add MCP endpoints under /mcp (relative to the router's base path)
	mcpRouter := router.PathPrefix("/mcp").Subrouter()

	// REST endpoints
	mcpRouter.HandleFunc("/tools/call", m.handleToolCall).Methods("POST")
	mcpRouter.HandleFunc("/tools/list", m.handleToolList).Methods("GET")
	mcpRouter.HandleFunc("/prompts/list", m.handlePromptList).Methods("GET")
	mcpRouter.HandleFunc("/prompts/get", m.handlePromptGet).Methods("POST")

	// JSON-RPC endpoints for backward compatibility
	mcpRouter.HandleFunc("", m.handleJSONRPC).Methods("POST", "OPTIONS")
	mcpRouter.HandleFunc("/", m.handleJSONRPC).Methods("POST", "OPTIONS")
}

// Stop stops the MCP server
func (m *MCPServer) Stop() error {
	if m.logger != nil {
		m.logger.Info().Msg("Stopping MCP server")
	}

	if m.cancel != nil {
		m.cancel()
	}

	return nil
}

// GetDefaultConfig returns the default MCP configuration
func GetDefaultConfig() *MCPConfig {
	return &MCPConfig{
		Enabled: true, // Enable for testing
		APIKey:  "",   // Must be configured
	}
}

// handleToolCall handles MCP tool execution requests
func (m *MCPServer) handleToolCall(w http.ResponseWriter, r *http.Request) {
	var req MCPRequest

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		m.writeError(w, statusBadRequest, "Invalid request body")
		return
	}

	// Look up the tool
	tool, exists := m.tools[req.Params.Name]
	if !exists {
		m.writeError(w, statusNotFound, fmt.Sprintf("Tool not found: %s", req.Params.Name))

		return
	}

	// Execute the tool
	result, err := tool.Handler(r.Context(), req.Params.Arguments)
	if err != nil {
		m.writeError(w, statusInternalServerError, err.Error())

		return
	}

	// Return success response
	response := MCPResponse{Result: result}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		m.logger.Error().Err(err).Msg("Failed to encode tool call response")
	}
}

// handleToolList returns the list of available MCP tools
func (m *MCPServer) handleToolList(w http.ResponseWriter, _ *http.Request) {
	tools := make([]map[string]string, 0, len(m.tools))

	for name, tool := range m.tools {
		tools = append(tools, map[string]string{
			"name":        name,
			"description": tool.Description,
		})
	}

	response := map[string]interface{}{
		"tools": tools,
		"count": len(tools),
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		m.logger.Error().Err(err).Msg("Failed to encode tool list response")
	}
}

// handlePromptList returns the list of available prompts
func (m *MCPServer) handlePromptList(w http.ResponseWriter, _ *http.Request) {
	prompts := []map[string]interface{}{
		{
			"name":        defaultSRQLGuide,
			"description": "ServiceRadar Query Language (SRQL) syntax guide and best practices for constructing network monitoring queries",
			"arguments":   []map[string]interface{}{}, // No arguments required for this prompt
		},
	}

	response := map[string]interface{}{
		"prompts": prompts,
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		m.logger.Error().Err(err).Msg("Failed to encode prompt list response")
	}
}

// handlePromptGet returns a specific prompt
func (m *MCPServer) handlePromptGet(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name      string                 `json:"name"`
		Arguments map[string]interface{} `json:"arguments,omitempty"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		m.writeError(w, statusBadRequest, "Invalid request body")
		return
	}

	if req.Name != defaultSRQLGuide {
		m.writeError(w, statusNotFound, fmt.Sprintf("Prompt not found: %s", req.Name))
		return
	}

	response := map[string]interface{}{
		"description": "ServiceRadar Query Language (SRQL) syntax guide for LLM assistants",
		"messages": []map[string]interface{}{
			{
				"role": "user",
				"content": map[string]interface{}{
					"type": "text",
					"text": srqlPrompt,
				},
			},
		},
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		m.logger.Error().Err(err).Msg("Failed to encode prompt response")
	}
}

// writeError writes an error response
func (m *MCPServer) writeError(w http.ResponseWriter, code int, message string) {
	w.Header().Set("Content-Type", "application/json")

	w.WriteHeader(code)

	response := MCPResponse{
		Error: &MCPError{
			Code:    code,
			Message: message,
		},
	}

	if err := json.NewEncoder(w).Encode(response); err != nil {
		m.logger.Error().Err(err).Msg("Failed to encode error response")
	}
}

// handleJSONRPC handles JSON-RPC requests for backward compatibility
func (m *MCPServer) handleJSONRPC(w http.ResponseWriter, r *http.Request) {
	// Set CORS headers
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key")
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	var req struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      interface{}     `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params,omitempty"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONRPCError(w, req.ID, -32700, "Parse error", err.Error())
		return
	}

	switch req.Method {
	case "initialize":
		handleJSONRPCInitialize(w, req.ID)
	case "tools/list":
		handleJSONRPCToolsList(w, req.ID)
	case "tools/call":
		m.handleJSONRPCToolCall(w, req.ID, req.Params, r)
	case "prompts/list":
		handleJSONRPCPromptsList(w, req.ID)
	case "prompts/get":
		handleJSONRPCPromptsGet(w, req.ID, req.Params)
	default:
		writeJSONRPCError(w, req.ID, -32601, "Method not found", fmt.Sprintf("Unknown method: %s", req.Method))
	}
}

func handleJSONRPCInitialize(w http.ResponseWriter, id interface{}) {
	result := map[string]interface{}{
		"protocolVersion": "2024-11-05",
		"capabilities": map[string]interface{}{
			"tools": map[string]interface{}{},
			"prompts": map[string]interface{}{
				"listChanged": true,
			},
		},
		"serverInfo": map[string]interface{}{
			"name":    "serviceradar-mcp",
			"version": "1.0.0",
		},
	}
	writeJSONRPCSuccess(w, id, result)
}

func getDeviceTools() []map[string]interface{} {
	return []map[string]interface{}{
		{
			"name":        "list_devices",
			"description": "List all devices in the system",
			"inputSchema": map[string]interface{}{
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
			"name":        "get_device",
			"description": "Get detailed information about a specific device",
			"inputSchema": map[string]interface{}{
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

func getQueryTools() []map[string]interface{} {
	return []map[string]interface{}{
		{
			"name":        "query_events",
			"description": "Query system events with filters",
			"inputSchema": map[string]interface{}{
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
			"name":        "execute_srql",
			"description": "Execute SRQL queries directly",
			"inputSchema": map[string]interface{}{
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

func getLogTools() []map[string]interface{} {
	return []map[string]interface{}{
		{
			"name":        "query_logs",
			"description": "Query system logs with filters",
			"inputSchema": map[string]interface{}{
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
			"name":        "get_recent_logs",
			"description": "Get recent logs with simple limit",
			"inputSchema": map[string]interface{}{
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

func getMCPToolsDefinition() []map[string]interface{} {
	var tools []map[string]interface{}
	tools = append(tools, getDeviceTools()...)
	tools = append(tools, getQueryTools()...)
	tools = append(tools, getLogTools()...)

	return tools
}

func handleJSONRPCToolsList(w http.ResponseWriter, id interface{}) {
	result := map[string]interface{}{
		"tools": getMCPToolsDefinition(),
	}
	writeJSONRPCSuccess(w, id, result)
}

func handleJSONRPCPromptsList(w http.ResponseWriter, id interface{}) {
	result := map[string]interface{}{
		"prompts": []map[string]interface{}{
			{
				"name":        defaultSRQLGuide,
				"description": "ServiceRadar Query Language (SRQL) syntax guide and best practices for constructing network monitoring queries",
				"arguments":   []map[string]interface{}{}, // No arguments required for this prompt
			},
		},
	}
	writeJSONRPCSuccess(w, id, result)
}

func handleJSONRPCPromptsGet(w http.ResponseWriter, id interface{}, params json.RawMessage) {
	var req struct {
		Name      string                 `json:"name"`
		Arguments map[string]interface{} `json:"arguments,omitempty"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		writeJSONRPCError(w, id, -32602, "Invalid params", err.Error())
		return
	}

	if req.Name != defaultSRQLGuide {
		writeJSONRPCError(w, id, -32602, "Unknown prompt", fmt.Sprintf("Prompt not found: %s", req.Name))
		return
	}

	result := map[string]interface{}{
		"description": "ServiceRadar Query Language (SRQL) syntax guide for LLM assistants",
		"messages": []map[string]interface{}{
			{
				"role": "user",
				"content": map[string]interface{}{
					"type": "text",
					"text": srqlPrompt,
				},
			},
		},
	}

	writeJSONRPCSuccess(w, id, result)
}

func (m *MCPServer) handleJSONRPCToolCall(w http.ResponseWriter, id interface{}, params json.RawMessage, r *http.Request) {
	var toolParams struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments,omitempty"`
	}

	if err := json.Unmarshal(params, &toolParams); err != nil {
		writeJSONRPCError(w, id, -32602, "Invalid params", err.Error())
		return
	}

	// Execute the tool based on its name with SimpleMCPServer-style handlers
	var result interface{}

	var err error

	switch toolParams.Name {
	case "list_devices":
		result, err = m.executeListDevices(r.Context(), toolParams.Arguments)
	case "get_device":
		result, err = m.executeGetDevice(r.Context(), toolParams.Arguments)
	case "query_events":
		result, err = m.executeQueryEvents(r.Context(), toolParams.Arguments)
	case "execute_srql":
		result, err = m.executeExecuteSRQL(r.Context(), toolParams.Arguments)
	case "query_logs":
		result, err = m.executeQueryLogs(r.Context(), toolParams.Arguments)
	case "get_recent_logs":
		result, err = m.executeGetRecentLogs(r.Context(), toolParams.Arguments)
	default:
		// Fallback to tool registry
		tool, exists := m.tools[toolParams.Name]
		if !exists {
			writeJSONRPCError(w, id, -32602, "Unknown tool", fmt.Sprintf("Tool not found: %s", toolParams.Name))
			return
		}

		result, err = tool.Handler(r.Context(), toolParams.Arguments)
	}

	if err != nil {
		writeJSONRPCError(w, id, -32603, "Internal error", err.Error())
		return
	}

	// Format result for MCP
	var content []map[string]interface{}

	resultJSON, err := json.Marshal(result)
	if err != nil {
		writeJSONRPCError(w, id, -32603, "Internal error", "Failed to marshal result")
		return
	}

	content = append(content, map[string]interface{}{
		"type": "text",
		"text": string(resultJSON),
	})

	writeJSONRPCSuccess(w, id, map[string]interface{}{
		"content": content,
	})
}

func writeJSONRPCSuccess(w http.ResponseWriter, id, result interface{}) {
	response := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  result,
	}

	if err := json.NewEncoder(w).Encode(response); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

func writeJSONRPCError(w http.ResponseWriter, id interface{}, code int, message string, data interface{}) {
	response := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"error": map[string]interface{}{
			"code":    code,
			"message": message,
			"data":    data,
		},
	}

	if err := json.NewEncoder(w).Encode(response); err != nil {
		http.Error(w, "Failed to encode error response", http.StatusInternalServerError)
	}
}

// Tool execution methods (SimpleMCPServer-style)
func (m *MCPServer) executeListDevices(ctx context.Context, args json.RawMessage) (interface{}, error) {
	return executeListDevices(ctx, args, m.queryExecutor)
}

func (m *MCPServer) executeGetDevice(ctx context.Context, args json.RawMessage) (interface{}, error) {
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

	return m.queryExecutor.ExecuteSRQLQuery(ctx, query, 1)
}

func (m *MCPServer) executeQueryEvents(ctx context.Context, args json.RawMessage) (interface{}, error) {
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
		query := showEventsQuery
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

	return m.queryExecutor.ExecuteSRQLQuery(ctx, params.Query, params.Limit)
}

func (m *MCPServer) executeExecuteSRQL(ctx context.Context, args json.RawMessage) (interface{}, error) {
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

	return m.queryExecutor.ExecuteSRQLQuery(ctx, params.Query, params.Limit)
}

func (m *MCPServer) executeQueryLogs(ctx context.Context, args json.RawMessage) (interface{}, error) {
	result, err := executeQueryLogs(ctx, args, m.queryExecutor)
	if err != nil {
		return nil, err
	}

	m.logger.Debug().Msg("Executing logs query")

	return result, nil
}

func (m *MCPServer) executeGetRecentLogs(ctx context.Context, args json.RawMessage) (interface{}, error) {
	result, err := executeGetRecentLogs(ctx, args, m.queryExecutor)
	if err != nil {
		return nil, err
	}

	m.logger.Debug().Msg("Executing recent logs query")

	return result, nil
}

// executeSRQLQuery executes an SRQL query directly via the query executor
func (m *MCPServer) executeSRQLQuery(ctx context.Context, query string, limit int) ([]map[string]interface{}, error) {
	return m.queryExecutor.ExecuteSRQLQuery(ctx, query, limit)
}
