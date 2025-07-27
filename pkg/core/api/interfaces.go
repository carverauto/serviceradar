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

// Package api pkg/core/api/interfaces.go
package api

import (
	"context"

	"github.com/gorilla/mux"
)

//go:generate mockgen -destination=mock_api_server.go -package=api github.com/carverauto/serviceradar/pkg/core/api Service

// Service represents the API server functionality.
type Service interface {
	Start(addr string) error
	UpdatePollerStatus(pollerID string, status *PollerStatus)
	SetPollerHistoryHandler(ctx context.Context, handler func(pollerID string) ([]PollerHistoryPoint, error))
	SetKnownPollers(knownPollers []string)
	RegisterMCPRoutes(mcpServer MCPRouteRegistrar)
	SRQLQueryExecutor
}

// MCPRouteRegistrar interface for registering MCP routes
type MCPRouteRegistrar interface {
	RegisterRoutes(router *mux.Router)
	Stop() error
}

// SRQLQueryExecutor interface for executing SRQL queries
type SRQLQueryExecutor interface {
	ExecuteSRQLQuery(ctx context.Context, query string, limit int) ([]map[string]interface{}, error)
}
