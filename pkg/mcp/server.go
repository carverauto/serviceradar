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
	"fmt"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/localrivet/gomcp/server"
)

// MCPServer represents the ServiceRadar MCP server
type MCPServer struct {
	server      server.Server
	db          db.Service
	logger      logger.Logger
	config      *MCPConfig
	authService auth.AuthService
	ctx         context.Context
	cancel      context.CancelFunc
}

// MCPConfig holds configuration for the MCP server
type MCPConfig struct {
	Enabled bool   `json:"enabled"`
	Port    string `json:"port"`
	Host    string `json:"host"`
}

// NewMCPServer creates a new MCP server instance
func NewMCPServer(database db.Service, log logger.Logger, config *MCPConfig, authService auth.AuthService) *MCPServer {
	ctx, cancel := context.WithCancel(context.Background())
	
	srv := server.NewServer("serviceradar-mcp")

	mcpServer := &MCPServer{
		server:      srv,
		db:          database,
		logger:      log,
		config:      config,
		authService: authService,
		ctx:         ctx,
		cancel:      cancel,
	}

	// Register all MCP tools
	mcpServer.registerDeviceTools()
	mcpServer.registerLogTools()
	mcpServer.registerEventTools()
	mcpServer.registerSweepTools()
	mcpServer.registerSRQLTools()

	return mcpServer
}

// Start starts the MCP server
func (m *MCPServer) Start() error {
	if !m.config.Enabled {
		if m.logger != nil {
			m.logger.Info().Msg("MCP server disabled")
		}
		return nil
	}

	address := fmt.Sprintf("%s:%s", m.config.Host, m.config.Port)
	if m.logger != nil {
		m.logger.Info().Str("address", address).Msg("Starting MCP server")

		if m.authService != nil {
			m.logger.Info().Msg("Authentication service available for MCP server")
			// Note: Authentication will be handled at the tool level within the MCP handlers
			// since GoMCP manages the HTTP server lifecycle
		} else {
			m.logger.Warn().Msg("No auth service provided - MCP server running without authentication")
		}
	}

	// Start as HTTP server - GoMCP handles the HTTP server setup
	return m.server.AsHTTP(address).Run()
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

// GetConfig returns the default MCP configuration
func GetDefaultConfig() *MCPConfig {
	return &MCPConfig{
		Enabled: false,
		Port:    "8081",
		Host:    "localhost",
	}
}