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
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/carverauto/serviceradar/pkg/core/api"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/gorilla/mux"
)

// HTTP status codes
const (
	statusBadRequest          = 400
	statusNotFound            = 404
	statusInternalServerError = 500
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
	mcpRouter.HandleFunc("/tools/call", m.handleToolCall).Methods("POST")
	mcpRouter.HandleFunc("/tools/list", m.handleToolList).Methods("GET")
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

// executeSRQLQuery executes an SRQL query directly via the query executor
func (m *MCPServer) executeSRQLQuery(ctx context.Context, query string, limit int) ([]map[string]interface{}, error) {
	return m.queryExecutor.ExecuteSRQLQuery(ctx, query, limit)
}
