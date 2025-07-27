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

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/localrivet/gomcp/server"
)

// authenticateRequest validates the authentication for an MCP request
func (m *MCPServer) authenticateRequest(ctx *server.Context) (*models.User, error) {
	if m.authService == nil {
		// No auth service configured - allow request
		return nil, nil
	}

	// Extract authorization from MCP session or context
	// GoMCP sessions can provide environment variables and headers
	session := ctx.Session
	env := session.Env()
	
	// Look for authorization token in environment
	var token string
	if authHeader, exists := env["AUTHORIZATION"]; exists {
		// Extract Bearer token
		parts := strings.Split(authHeader, " ")
		if len(parts) == 2 && parts[0] == "Bearer" {
			token = parts[1]
		}
	}
	
	// Also check for direct token
	if token == "" {
		if directToken, exists := env["AUTH_TOKEN"]; exists {
			token = directToken
		}
	}
	
	if token == "" {
		return nil, fmt.Errorf("authentication required: no token provided")
	}
	
	// Verify the token
	user, err := m.authService.VerifyToken(m.ctx, token)
	if err != nil {
		return nil, fmt.Errorf("authentication failed: %w", err)
	}
	
	return user, nil
}

// requireAuth is a wrapper that adds authentication to MCP tool handlers
func (m *MCPServer) requireAuth(handler func(*server.Context, interface{}) (interface{}, error)) func(*server.Context, interface{}) (interface{}, error) {
	return func(ctx *server.Context, args interface{}) (interface{}, error) {
		user, err := m.authenticateRequest(ctx)
		if err != nil {
			return nil, err
		}
		
		if user != nil {
			m.logger.Debug().Str("user_id", user.ID).Str("email", user.Email).Msg("Authenticated MCP request")
		}
		
		// Call the actual handler
		return handler(ctx, args)
	}
}