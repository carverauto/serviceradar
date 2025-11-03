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

	"github.com/carverauto/serviceradar/pkg/registry"
	"github.com/gorilla/mux"
)

//go:generate mockgen -destination=mock_api_server.go -package=api github.com/carverauto/serviceradar/pkg/core/api Service

// Service represents the API server functionality.
type Service interface {
	Start(addr string) error
	UpdatePollerStatus(pollerID string, status *PollerStatus)
	SetPollerHistoryHandler(ctx context.Context, handler func(pollerID string) ([]PollerHistoryPoint, error))
	SetKnownPollers(knownPollers []string)
	SetDynamicPollers(pollerIDs []string)
}

// MCPRouteRegistrar interface for registering MCP routes
type MCPRouteRegistrar interface {
	RegisterRoutes(router *mux.Router)
	Stop() error
}

// ServiceRegistryService represents the service registry interface for managing pollers, agents, and checkers
type ServiceRegistryService interface {
	// GetPoller retrieves a registered poller by ID
	GetPoller(ctx context.Context, pollerID string) (*registry.RegisteredPoller, error)
	// GetAgent retrieves a registered agent by ID
	GetAgent(ctx context.Context, agentID string) (*registry.RegisteredAgent, error)
	// GetChecker retrieves a registered checker by ID
	GetChecker(ctx context.Context, checkerID string) (*registry.RegisteredChecker, error)
}
