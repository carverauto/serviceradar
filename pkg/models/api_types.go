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

// Package models pkg/models/api_types.go
package models

import (
	"encoding/json"
	"time"
)

// ServiceStatus represents the status of a monitored service.
// @Description Status information about a service monitored by a gateway.
type ServiceStatus struct {
	// Name of the service
	Name string `json:"name" example:"postgres"`
	// Whether the service is currently available
	Available bool `json:"available" example:"true"`
	// Status message from the service
	Message string `json:"message" example:"Service is running normally"`
	// Type of service (e.g., "process", "port", "database", etc.)
	Type string `json:"type" example:"database"`
	// Detailed service-specific information as a JSON object
	Details     json.RawMessage `json:"details,omitempty"`
	GatewayID    string          `json:"gateway_id" example:"gateway-prod-east-01"`
	AgentID     string          `json:"agent_id" example:"agent-prod-east-01"`
	ServiceName string          `json:"service_name" example:"postgres"`
	ServiceType string          `json:"service_type" example:"database"`
	DeviceID    string          `json:"device_id,omitempty" example:"default:192.168.1.100"`
	Partition   string          `json:"partition,omitempty" example:"default"`
	Timestamp   time.Time       `json:"timestamp" example:"2020-11-10T23:00:00+09:00"`
}

// GatewayStatus represents the status of a gateway.
// @Description Status information about a service gateway.
type GatewayStatus struct {
	// Unique identifier for the gateway
	GatewayID string `json:"gateway_id" example:"gateway-prod-east-01"`
	// Whether the gateway is currently healthy
	IsHealthy bool `json:"is_healthy" example:"true"`
	// List of services monitored by this gateway
	Services []ServiceStatus `json:"services"`
	// How long the gateway has been running
	UpTime string `json:"uptime" example:"3d 2h 15m"`
	// When the gateway was first seen by the system
	FirstSeen time.Time `json:"first_seen" example:"2025-04-20T10:00:00Z"`
	// Last time the gateway reported its status
	LastSeen time.Time `json:"last_seen" example:"2025-04-24T14:15:22Z"`
	// IP address of the host where the gateway is running
	HostIP string `json:"host_ip,omitempty" example:"192.168.1.100"`
	// Optional metrics data points
	Metrics []MetricPoint `json:"metrics,omitempty"`
	// Metadata about the gateway
	LastEvaluated time.Time `json:"last_evaluated" example:"2025-04-24T14:15:22Z"`
	// AlertSent indicates if an alert has been sent for this gateway
	AlertSent bool `json:"alert_sent" example:"false"`
}

// SystemStatus represents the overall system status.
// @Description Overall system status information.
type SystemStatus struct {
	// Total number of gateways in the system
	TotalGateways int `json:"total_gateways" example:"15"`
	// Number of gateways that are currently healthy
	HealthyGateways int `json:"healthy_gateways" example:"12"`
	// Last time the system status was updated
	LastUpdate time.Time `json:"last_update" example:"2025-04-24T14:15:22Z"`
}

// GatewayHistory represents historical status of a gateway.
// @Description Historical status information for a gateway.
type GatewayHistory struct {
	// Unique identifier for the gateway
	GatewayID string `json:"gateway_id" example:"gateway-prod-east-01"`
	// When this status was recorded
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
	// Whether the gateway was healthy at this time
	IsHealthy bool `json:"is_healthy" example:"true"`
	// Services status at this time
	Services []ServiceStatus `json:"services"`
}

// GatewayHistoryPoint represents a simplified historical health state.
// @Description Simplified historical health state for a gateway.
type GatewayHistoryPoint struct {
	// When this status was recorded
	Timestamp time.Time `json:"timestamp" example:"2025-04-24T14:15:22Z"`
	// Whether the gateway was healthy at this time
	IsHealthy bool `json:"is_healthy" example:"true"`
}

// LoginRequest represents a login request.
// @Description Authentication request with username and password.
type LoginRequest struct {
	// Username for authentication
	Username string `json:"username" example:"admin"`
	// Password for authentication
	Password string `json:"password" example:"p@ssw0rd"`
}

// RefreshTokenRequest represents a token refresh request.
// @Description Request to refresh an expired access token.
type RefreshTokenRequest struct {
	// JWT refresh token
	RefreshToken string `json:"refresh_token" example:"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."`
}

// ErrorResponse represents an API error response.
// @Description Error information returned from the API.
type ErrorResponse struct {
	// Error message
	Message string `json:"message" example:"Invalid request parameters"`
	// HTTP status code
	Status int `json:"status" example:"400"`
}
