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

// Package api provides the HTTP API server for ServiceRadar
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	srHttp "github.com/carverauto/serviceradar/pkg/http"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
	srqlmodels "github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
	"github.com/carverauto/serviceradar/pkg/swagger"
	"github.com/gorilla/mux"
	httpSwagger "github.com/swaggo/http-swagger"
)

// NewAPIServer creates a new API server instance with the given configuration
func NewAPIServer(config models.CORSConfig, options ...func(server *APIServer)) *APIServer {
	s := &APIServer{
		pollers:    make(map[string]*PollerStatus),
		router:     mux.NewRouter(),
		corsConfig: config,
	}

	// Initialize with default entity table mapping to match SRQL translator
	defaultEntityTableMap := map[srqlmodels.EntityType]string{
		srqlmodels.Devices:       "unified_devices",
		srqlmodels.Flows:         "netflow_metrics",
		srqlmodels.Traps:         "traps",
		srqlmodels.Connections:   "connections",
		srqlmodels.Logs:          "logs",
		srqlmodels.Services:      "services",
		srqlmodels.Interfaces:    "discovered_interfaces",
		srqlmodels.SweepResults:  "unified_devices",
		srqlmodels.DeviceUpdates: "device_updates",
		srqlmodels.ICMPResults:   "icmp_results",
		srqlmodels.SNMPResults:   "timeseries_metrics",
		srqlmodels.Events:        "events",
		srqlmodels.Pollers:       "pollers",
		srqlmodels.CPUMetrics:    "cpu_metrics",
		srqlmodels.DiskMetrics:   "disk_metrics",
		srqlmodels.MemoryMetrics: "memory_metrics",
		srqlmodels.SNMPMetrics:   "timeseries_metrics",
		// OTEL entities
		srqlmodels.OtelTraces:         "otel_traces",
		srqlmodels.OtelMetrics:        "otel_metrics",
		srqlmodels.OtelTraceSummaries: "otel_trace_summaries_final",
	}
	s.entityTableMap = defaultEntityTableMap

	for _, o := range options {
		o(s)
	}

	s.setupRoutes()

	return s
}

// WithDatabaseType sets the database type for the API server
func WithDatabaseType(dbType parser.DatabaseType) func(*APIServer) {
	return func(server *APIServer) {
		server.dbType = dbType
	}
}

// WithQueryExecutor adds a query executor to the API server
func WithQueryExecutor(qe db.QueryExecutor) func(server *APIServer) {
	return func(server *APIServer) {
		server.queryExecutor = qe
	}
}

// WithAuthService adds an authentication service to the API server
func WithAuthService(a auth.AuthService) func(server *APIServer) {
	return func(server *APIServer) {
		server.authService = a
	}
}

// WithMetricsManager adds a metrics manager to the API server
func WithMetricsManager(m metrics.MetricCollector) func(server *APIServer) {
	return func(server *APIServer) {
		server.metricsManager = m
	}
}

// WithSNMPManager adds an SNMP manager to the API server
func WithSNMPManager(m metricstore.SNMPManager) func(server *APIServer) {
	return func(server *APIServer) {
		server.snmpManager = m
	}
}

// WithRperfManager adds an rperf manager to the API server
func WithRperfManager(m metricstore.RperfManager) func(server *APIServer) {
	return func(server *APIServer) {
		server.rperfManager = m
	}
}

// WithDBService adds a database service to the API server
func WithDBService(db db.Service) func(server *APIServer) {
	return func(server *APIServer) {
		server.dbService = db
	}
}

// WithDeviceRegistry adds a device registry service to the API server
func WithDeviceRegistry(dr DeviceRegistryService) func(server *APIServer) {
	return func(server *APIServer) {
		server.deviceRegistry = dr
	}
}

func WithLogger(log logger.Logger) func(server *APIServer) {
	return func(server *APIServer) {
		server.logger = log
	}
}

// setupRoutes configures the HTTP routes for the API server.
func (s *APIServer) setupRoutes() {
	s.setupMiddleware()
	s.setupSwaggerRoutes()
	s.setupAuthRoutes()
	s.setupProtectedRoutes()
}

// setupMiddleware configures CORS middleware.
func (s *APIServer) setupMiddleware() {
	corsConfig := models.CORSConfig{
		AllowedOrigins:   s.corsConfig.AllowedOrigins,
		AllowCredentials: s.corsConfig.AllowCredentials,
	}

	middlewareChain := func(next http.Handler) http.Handler {
		// The authentication middleware is now applied selectively in setupProtectedRoutes
		return srHttp.CommonMiddleware(next, corsConfig, s.logger)
	}

	s.router.Use(middlewareChain)
}

// authenticationMiddleware provides flexible authentication, allowing either a Bearer token or an API key.
func (s *APIServer) authenticationMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Try Bearer token authentication
		if handled := s.handleBearerTokenAuth(w, r, next); handled {
			return
		}

		// Try API key authentication
		if handled := s.handleAPIKeyAuth(w, r, next); handled {
			return
		}

		// Check if authentication is required
		if s.isAuthRequired() {
			s.logAuthFailure("Authentication required but not provided")
			writeError(w, "Authentication required", http.StatusUnauthorized)

			return
		}

		// Development mode - no auth configured
		s.logAuthFailure("No authentication configured - allowing request (development mode)")
		next.ServeHTTP(w, r)
	})
}

// handleBearerTokenAuth handles Bearer token authentication
func (s *APIServer) handleBearerTokenAuth(w http.ResponseWriter, r *http.Request, next http.Handler) bool {
	authHeader := r.Header.Get("Authorization")
	if !strings.HasPrefix(authHeader, "Bearer ") {
		return false
	}

	token := strings.TrimPrefix(authHeader, "Bearer ")

	if s.authService == nil {
		return false
	}

	user, err := s.authService.VerifyToken(r.Context(), token)
	if err != nil {
		writeError(w, "Invalid bearer token", http.StatusUnauthorized)
		return true // Handled (with rejection)
	}

	// Success - no logging to avoid exposing user info
	ctx := context.WithValue(r.Context(), auth.UserKey, user)
	next.ServeHTTP(w, r.WithContext(ctx))

	return true
}

// handleAPIKeyAuth handles API key authentication
func (s *APIServer) handleAPIKeyAuth(w http.ResponseWriter, r *http.Request, next http.Handler) bool {
	apiKey := os.Getenv("API_KEY")
	if apiKey == "" {
		return false
	}

	if r.Header.Get("X-API-Key") == apiKey {
		next.ServeHTTP(w, r)
		return true
	}

	// API key is configured but the provided key is invalid
	s.logger.Warn().Msg("API key authentication is enabled but no valid API key provided")
	writeError(w, "Invalid API key", http.StatusUnauthorized)

	return true // Handled (with rejection)
}

const (
	authEnabledTrue = "true"
)

// isAuthRequired checks if authentication is required
func (*APIServer) isAuthRequired() bool {
	return os.Getenv("AUTH_ENABLED") == authEnabledTrue || os.Getenv("API_KEY") != ""
}

// logAuthFailure logs authentication failures
func (s *APIServer) logAuthFailure(msg string) {
	// Log without sensitive details
	s.logger.Warn().Msg(msg)
}

// setupSwaggerRoutes configures routes for Swagger UI and documentation.
func (s *APIServer) setupSwaggerRoutes() {
	s.router.HandleFunc("/swagger/swagger.json", s.serveSwaggerJSON)
	s.router.HandleFunc("/swagger/swagger.yaml", s.serveSwaggerYAML)
	s.router.HandleFunc("/swagger/host.json", s.serveSwaggerHost)

	s.router.PathPrefix("/swagger/").Handler(httpSwagger.Handler(
		httpSwagger.URL("/swagger/host.json"),
		httpSwagger.DeepLinking(true),
		httpSwagger.DocExpansion("list"),
		httpSwagger.PersistAuthorization(true),
	))

	s.router.HandleFunc("/api-docs", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/swagger/", http.StatusMovedPermanently)
	})
}

// serveSwaggerJSON serves the embedded Swagger JSON file.
func (s *APIServer) serveSwaggerJSON(w http.ResponseWriter, _ *http.Request) {
	data, err := swagger.GetSwaggerJSON()
	if err != nil {
		http.Error(w, "Swagger JSON not found", http.StatusInternalServerError)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	_, err = w.Write(data)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error writing Swagger JSON response")
		http.Error(w, "Failed to write Swagger JSON response", http.StatusInternalServerError)

		return
	}
}

// serveSwaggerYAML serves the embedded Swagger YAML file.
func (s *APIServer) serveSwaggerYAML(w http.ResponseWriter, _ *http.Request) {
	data, err := swagger.GetSwaggerYAML()
	if err != nil {
		http.Error(w, "Swagger YAML not found", http.StatusInternalServerError)

		return
	}

	w.Header().Set("Content-Type", "application/yaml")

	_, err = w.Write(data)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error writing Swagger YAML response")

		return
	}
}

// serveSwaggerHost dynamically updates and serves the Swagger host configuration.
func (s *APIServer) serveSwaggerHost(w http.ResponseWriter, r *http.Request) {
	host := s.getRequestHost(r)

	data, err := swagger.GetSwaggerJSON()
	if err != nil {
		http.Error(w, "Swagger JSON not found", http.StatusInternalServerError)

		return
	}

	spec, err := s.parseSwaggerSpec(data)
	if err != nil {
		http.Error(w, "Could not parse Swagger spec", http.StatusInternalServerError)

		return
	}

	spec = s.updateSwaggerSpec(spec, r, host)

	w.Header().Set("Content-Type", "application/json")

	err = json.NewEncoder(w).Encode(spec)
	if err != nil {
		http.Error(w, "Failed to encode Swagger spec", http.StatusInternalServerError)
		s.logger.Error().Err(err).Msg("Error encoding Swagger spec")

		return
	}
}

// getRequestHost extracts the host from the request or returns a default.
func (*APIServer) getRequestHost(r *http.Request) string {
	host := r.Host

	if host == "" {
		return "localhost:8080"
	}

	return host
}

// parseSwaggerSpec unmarshals the Swagger JSON into a map.
func (*APIServer) parseSwaggerSpec(data []byte) (map[string]interface{}, error) {
	var spec map[string]interface{}

	if err := json.Unmarshal(data, &spec); err != nil {
		return nil, err
	}

	return spec, nil
}

// updateSwaggerSpec updates the Swagger/OpenAPI spec with a dynamic host.
func (s *APIServer) updateSwaggerSpec(spec map[string]interface{}, r *http.Request, host string) map[string]interface{} {
	// Update OpenAPI 3.0 servers
	if servers, ok := spec["servers"].([]interface{}); ok {
		spec = s.updateOpenAPI3Servers(servers, r, host, spec)
	}

	// Update Swagger 2.0 host
	if _, ok := spec["host"]; ok {
		spec["host"] = host
	}

	return spec
}

// updateOpenAPI3Servers updates the servers array for OpenAPI 3.0 if a matching URL is found.
func (*APIServer) updateOpenAPI3Servers(
	servers []interface{}, r *http.Request, host string, spec map[string]interface{}) map[string]interface{} {
	if len(servers) == 0 {
		return spec
	}

	for i, server := range servers {
		serverMap, ok := server.(map[string]interface{})
		if !ok {
			continue
		}

		serverURL, ok := serverMap["url"].(string)
		if !ok || !strings.Contains(serverURL, "{hostname}") {
			continue
		}

		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}

		serverMap["url"] = fmt.Sprintf("%s://%s", scheme, host)
		servers[i] = serverMap

		spec["servers"] = servers

		break
	}

	return spec
}

// setupAuthRoutes configures public authentication routes.
func (s *APIServer) setupAuthRoutes() {
	s.router.HandleFunc("/auth/login", s.handleLocalLogin).Methods("POST")
	s.router.HandleFunc("/auth/refresh", s.handleRefreshToken).Methods("POST")
	s.router.HandleFunc("/auth/{provider}", s.handleOAuthBegin).Methods("GET")
	s.router.HandleFunc("/auth/{provider}/callback", s.handleOAuthCallback).Methods("GET")
}

// setupProtectedRoutes configures protected API routes.
func (s *APIServer) setupProtectedRoutes() {
	protected := s.router.PathPrefix("/api").Subrouter()

	// Use the new flexible authentication middleware for all protected API routes.
	protected.Use(s.authenticationMiddleware)

	protected.HandleFunc("/pollers", s.getPollers).Methods("GET")
	protected.HandleFunc("/pollers/{id}", s.getPoller).Methods("GET")
	protected.HandleFunc("/status", s.getSystemStatus).Methods("GET")
	protected.HandleFunc("/pollers/{id}/history", s.getPollerHistory).Methods("GET")
	protected.HandleFunc("/pollers/{id}/metrics", s.getPollerMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/rperf", s.getRperfMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/services", s.getPollerServices).Methods("GET")
	protected.HandleFunc("/pollers/{id}/services/{service}", s.getServiceDetails).Methods("GET")
	protected.HandleFunc("/pollers/{id}/snmp", s.getSNMPData).Methods("GET")
	protected.HandleFunc("/pollers/{id}/sysmon/cpu", s.getSysmonCPUMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/sysmon/disk", s.getSysmonDiskMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/sysmon/memory", s.getSysmonMemoryMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/sysmon/processes", s.getSysmonProcessMetrics).Methods("GET")

	// Device-centric sysmon endpoints
	protected.HandleFunc("/devices/{id}/sysmon/cpu", s.getDeviceSysmonCPUMetrics).Methods("GET")
	protected.HandleFunc("/devices/{id}/sysmon/disk", s.getDeviceSysmonDiskMetrics).Methods("GET")
	protected.HandleFunc("/devices/{id}/sysmon/memory", s.getDeviceSysmonMemoryMetrics).Methods("GET")
	protected.HandleFunc("/devices/{id}/sysmon/processes", s.getDeviceSysmonProcessMetrics).Methods("GET")

	protected.HandleFunc("/query", s.handleSRQLQuery).Methods("POST")
	
	// WebSocket streaming endpoint
	protected.HandleFunc("/stream", s.handleStreamQuery).Methods("GET")

	// Device-centric endpoints
	protected.HandleFunc("/devices", s.getDevices).Methods("GET")
	protected.HandleFunc("/devices/{id}", s.getDevice).Methods("GET")
	protected.HandleFunc("/devices/{id}/metrics", s.getDeviceMetrics).Methods("GET")
	protected.HandleFunc("/devices/metrics/status", s.getDeviceMetricsStatus).Methods("GET")
	protected.HandleFunc("/devices/snmp/status", s.getDeviceSNMPStatus).Methods("POST")

	// Store reference to protected router for MCP routes
	s.protectedRouter = protected
}

// @Summary Get SNMP data
// @Description Retrieves SNMP metrics data for a specific poller within the given time range
// @Tags SNMP
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Param start query string true "Start time in RFC3339 format"
// @Param end query string true "End time in RFC3339 format"
// @Success 200 {array} models.SNMPMetric "SNMP metrics data"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/pollers/{id}/snmp [get]
// @Security ApiKeyAuth
func (s *APIServer) getSNMPData(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]

	// set a timer of 10 seconds for the request
	ctx, cancel := context.WithTimeout(r.Context(), defaultTimeout)
	defer cancel()

	// Get start and end times from query parameters
	startStr := r.URL.Query().Get("start")
	endStr := r.URL.Query().Get("end")

	if startStr == "" || endStr == "" {
		http.Error(w, "start and end parameters are required", http.StatusBadRequest)

		return
	}

	startTime, err := time.Parse(time.RFC3339, startStr)
	if err != nil {
		http.Error(w, "Invalid start time format", http.StatusBadRequest)

		return
	}

	endTime, err := time.Parse(time.RFC3339, endStr)
	if err != nil {
		http.Error(w, "Invalid end time format", http.StatusBadRequest)

		return
	}

	// Use the injected snmpManager to fetch SNMP metrics
	snmpMetrics, err := s.snmpManager.GetSNMPMetrics(ctx, pollerID, startTime, endTime)
	if err != nil {
		s.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Error fetching SNMP data")
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(snmpMetrics); err != nil {
		s.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Error encoding SNMP data response")
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

// @Summary Get poller metrics
// @Description Retrieves performance metrics for a specific poller
// @Tags Metrics
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Success 200 {array} models.MetricPoint "Poller metrics data"
// @Failure 404 {object} models.ErrorResponse "No metrics found"
// @Failure 500 {object} models.ErrorResponse "Internal server error or metrics not configured"
// @Router /api/pollers/{id}/metrics [get]
// @Security ApiKeyAuth
func (s *APIServer) getPollerMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]

	if s.metricsManager == nil {
		s.logger.Warn().Str("poller_id", pollerID).Msg("Metrics not configured")
		http.Error(w, "Metrics not configured", http.StatusInternalServerError)

		return
	}

	m := s.metricsManager.GetMetrics(pollerID)
	if m == nil {
		s.logger.Debug().Str("poller_id", pollerID).Msg("No metrics found")
		http.Error(w, "No metrics found", http.StatusNotFound)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(m); err != nil {
		s.logger.Error().Err(err).Str("poller_id", pollerID).Msg("Error encoding metrics response")

		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

// SetPollerHistoryHandler sets the handler function for retrieving poller history
func (s *APIServer) SetPollerHistoryHandler(_ context.Context, handler func(pollerID string) ([]PollerHistoryPoint, error)) {
	s.pollerHistoryHandler = handler
}

// UpdatePollerStatus updates the status of a poller
func (s *APIServer) UpdatePollerStatus(pollerID string, status *PollerStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.pollers[pollerID] = status
}

// @Summary Get poller history
// @Description Retrieves historical status information for a specific poller
// @Tags Pollers
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Success 200 {array} PollerHistoryPoint "Historical status points"
// @Failure 500 {object} models.ErrorResponse "Internal server error or history handler not configured"
// @Router /api/pollers/{id}/history [get]
// @Security ApiKeyAuth
func (s *APIServer) getPollerHistory(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	pollerID := vars["id"]

	if s.pollerHistoryHandler == nil {
		http.Error(w, "History handler not configured", http.StatusInternalServerError)
		return
	}

	points, err := s.pollerHistoryHandler(pollerID)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error fetching poller history")
		http.Error(w, "Failed to fetch history", http.StatusInternalServerError)

		return
	}

	if err := s.encodeJSONResponse(w, points); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding history response")
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}

// @Summary Get system status
// @Description Retrieves overall system status including counts of total and healthy pollers
// @Tags System
// @Accept json
// @Produce json
// @Success 200 {object} SystemStatus "System status information"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/status [get]
// @Security ApiKeyAuth
func (s *APIServer) getSystemStatus(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	status := SystemStatus{
		TotalPollers:   len(s.pollers),
		HealthyPollers: 0,
		LastUpdate:     time.Now(),
	}

	for _, poller := range s.pollers {
		if poller.IsHealthy {
			status.HealthyPollers++
		}
	}

	s.mu.RUnlock()

	s.logger.Info().Int("total", status.TotalPollers).
		Int("healthy", status.HealthyPollers).
		Str("last_update", status.LastUpdate.Format(time.RFC3339)).
		Msg("System status")

	if err := s.encodeJSONResponse(w, status); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

// @Summary Get all pollers
// @Description Retrieves a list of all known pollers
// @Tags Pollers
// @Accept json
// @Produce json
// @Success 200 {array} PollerStatus "List of poller statuses"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/pollers [get]
// @Security ApiKeyAuth
func (s *APIServer) getPollers(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Preallocate the slice with the correct length
	pollers := make([]*PollerStatus, 0, len(s.pollers))

	// Append all map values to the slice
	for id, poller := range s.pollers {
		// Only include known pollers
		for _, known := range s.knownPollers {
			if id == known {
				pollers = append(pollers, poller)

				break
			}
		}
	}

	// Encode and send the response
	if err := s.encodeJSONResponse(w, pollers); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

// SetKnownPollers sets the list of known pollers
func (s *APIServer) SetKnownPollers(knownPollers []string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.knownPollers = knownPollers
}

// getPollerByID retrieves a poller by its ID
func (s *APIServer) getPollerByID(pollerID string) (*PollerStatus, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	poller, exists := s.pollers[pollerID]

	return poller, exists
}

// encodeJSONResponse encodes a response as JSON
func (*APIServer) encodeJSONResponse(w http.ResponseWriter, data interface{}) error {
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(data); err != nil {
		return err
	}

	return nil
}

// @Summary Get poller details
// @Description Retrieves detailed information about a specific poller
// @Tags Pollers
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Success 200 {object} PollerStatus "Poller status details"
// @Failure 404 {object} models.ErrorResponse "Poller not found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/pollers/{id} [get]
// @Security ApiKeyAuth
func (s *APIServer) getPoller(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]

	// Check if it's a known poller
	isKnown := false

	for _, known := range s.knownPollers {
		if pollerID == known {
			isKnown = true
			break
		}
	}

	if !isKnown {
		http.Error(w, "Poller not found", http.StatusNotFound)
		return
	}

	poller, exists := s.getPollerByID(pollerID)
	if !exists {
		http.Error(w, "Poller not found", http.StatusNotFound)

		return
	}

	if s.metricsManager != nil {
		m := s.metricsManager.GetMetrics(pollerID)
		if m != nil {
			poller.Metrics = m
			s.logger.Debug().Int("count", len(m)).Str("poller_id", pollerID).Msg("Attached metrics points to response")
		}
	}

	if err := s.encodeJSONResponse(w, poller); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

// @Summary Get poller services
// @Description Retrieves all services monitored by a specific poller
// @Tags Services
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Success 200 {array} ServiceStatus "List of service statuses"
// @Failure 404 {object} models.ErrorResponse "Poller not found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/pollers/{id}/services [get]
// @Security ApiKeyAuth
func (s *APIServer) getPollerServices(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]

	s.mu.RLock()
	poller, exists := s.pollers[pollerID]
	s.mu.RUnlock()

	if !exists {
		http.Error(w, "Poller not found", http.StatusNotFound)

		return
	}

	if err := s.encodeJSONResponse(w, poller.Services); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

// @Summary Get service details
// @Description Retrieves detailed information about a specific service monitored by a poller
// @Tags Services
// @Accept json
// @Produce json
// @Param id path string true "Poller ID"
// @Param service path string true "Service name"
// @Success 200 {object} ServiceStatus "Service status details"
// @Failure 404 {object} models.ErrorResponse "Poller or service not found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/pollers/{id}/services/{service} [get]
// @Security ApiKeyAuth
func (s *APIServer) getServiceDetails(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]
	serviceName := vars["service"]

	s.mu.RLock()
	poller, exists := s.pollers[pollerID]
	s.mu.RUnlock()

	if !exists {
		http.Error(w, "Poller not found", http.StatusNotFound)
		return
	}

	for _, service := range poller.Services {
		if service.Name == serviceName {
			if err := s.encodeJSONResponse(w, service); err != nil {
				http.Error(w, "Internal server error", http.StatusInternalServerError)
			}

			return
		}
	}

	http.Error(w, "Service not found", http.StatusNotFound)
}

const (
	defaultReadTimeout  = 10 * time.Second
	defaultWriteTimeout = 10 * time.Second
	defaultTimeout      = 10 * time.Second
	defaultIdleTimeout  = 60 * time.Second
)

// Start starts the API server on the specified address
func (s *APIServer) Start(addr string) error {
	srv := &http.Server{
		Addr:         addr,
		Handler:      s.router,
		ReadTimeout:  defaultReadTimeout,  // Timeout for reading the entire request, including the body.
		WriteTimeout: defaultWriteTimeout, // Timeout for writing the response.
		IdleTimeout:  defaultIdleTimeout,  // Timeout for idle connections waiting in the Keep-Alive state.
		// Optional: You can also set ReadHeaderTimeout to limit the time for reading request headers
		// ReadHeaderTimeout: 5 * time.Second,
	}

	return srv.ListenAndServe()
}

// writeJSONResponse writes a JSON response to the HTTP writer
func (s *APIServer) writeJSONResponse(w http.ResponseWriter, data interface{}, pollerID string) {
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(data); err != nil {
		s.logger.Error().
			Err(err).
			Str("poller_id", pollerID).
			Msg("Error encoding response")
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	} else {
		// Log without trying to determine the length of a specific type
		s.logger.Debug().
			Str("poller_id", pollerID).
			Msg("Successfully wrote metrics response")
	}
}

// parseTimeRange parses start and end times from query parameters.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func parseTimeRange(query url.Values) (start, end time.Time, err error) {
	startStr := query.Get("start")
	endStr := query.Get("end")
	hoursStr := query.Get("hours")

	// Default to last 24 hours if not specified
	start = time.Now().Add(-24 * time.Hour)
	end = time.Now()

	// If hours parameter is provided, use it instead of defaults
	if hoursStr != "" {
		hours, err := strconv.Atoi(hoursStr)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("invalid hours parameter: %w", err)
		}

		end = time.Now()
		start = end.Add(-time.Duration(hours) * time.Hour)
	}

	if startStr != "" {
		t, err := time.Parse(time.RFC3339, startStr)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("invalid start time format: %w", err)
		}

		start = t
	}

	if endStr != "" {
		t, err := time.Parse(time.RFC3339, endStr)
		if err != nil {
			return time.Time{}, time.Time{}, fmt.Errorf("invalid end time format: %w", err)
		}

		end = t
	}

	return start, end, nil
}

// httpError encapsulates an error message and HTTP status code.
type httpError struct {
	Message string
	Status  int
}

func (h httpError) Error() string {
	return fmt.Sprintf("HTTP %d: %s", h.Status, h.Message)
}

func writeError(w http.ResponseWriter, message string, statusCode int) {
	w.Header().Set("Content-Type", "application/json")

	w.WriteHeader(statusCode)

	errResponse := models.ErrorResponse{
		Message: message,
		Status:  statusCode,
	}

	if err := json.NewEncoder(w).Encode(errResponse); err != nil {
		// Fallback in case encoding fails
		http.Error(w, "Failed to encode error response", http.StatusInternalServerError)
	}
}

// @Summary Get all devices
// @Description Retrieves a list of all devices in the network
// @Tags Devices
// @Accept json
// @Produce json
// @Param limit query int false "Number of devices to return"
// @Param page query int false "Page number for pagination"
// @Param search query string false "Search term for device filtering"
// @Param status query string false "Filter by device status (online/offline)"
// @Success 200 {array} models.Device "List of devices"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/devices [get]
// @Security ApiKeyAuth
func (s *APIServer) getDevices(w http.ResponseWriter, r *http.Request) {
	// Set a timeout for the request
	ctx, cancel := context.WithTimeout(r.Context(), defaultTimeout)
	defer cancel()

	// Parse query parameters
	params := parseDeviceQueryParams(r)

	// Try device registry first (enhanced device data with discovery sources)
	if s.deviceRegistry != nil {
		if s.tryDeviceRegistryPath(ctx, w, params) {
			return
		}
	}

	// Fallback to SRQL query
	s.fallbackToSRQLQuery(ctx, w, params)
}

// parseDeviceQueryParams extracts and validates query parameters for device listing
func parseDeviceQueryParams(r *http.Request) map[string]interface{} {
	params := make(map[string]interface{})

	// Get query parameters
	params["searchTerm"] = r.URL.Query().Get("search")
	params["status"] = r.URL.Query().Get("status")
	params["mergedStr"] = r.URL.Query().Get("merged")

	// Parse pagination parameters
	limit := 100 // Default limit
	limitStr := r.URL.Query().Get("limit")

	if limitStr != "" {
		if parsedLimit, err := strconv.Atoi(limitStr); err == nil && parsedLimit > 0 {
			limit = parsedLimit
		}
	}

	params["limit"] = limit

	page := 1 // Default page
	pageStr := r.URL.Query().Get("page")

	if pageStr != "" {
		if parsedPage, err := strconv.Atoi(pageStr); err == nil && parsedPage > 0 {
			page = parsedPage
		}
	}

	params["page"] = page

	params["offset"] = (page - 1) * limit

	return params
}

// tryDeviceRegistryPath attempts to retrieve and process devices using the device registry
// Returns true if successful, false if it needs to fall back to SRQL
func (s *APIServer) tryDeviceRegistryPath(ctx context.Context, w http.ResponseWriter, params map[string]interface{}) bool {
	devices, err := s.deviceRegistry.ListDevices(ctx, params["limit"].(int), params["offset"].(int))
	if err != nil {
		s.logger.Warn().Err(err).Msg("Device registry listing failed, falling back to SRQL")
		return false
	}

	// Filter devices based on search and status parameters
	filteredDevices := filterDevices(devices, params["searchTerm"].(string), params["status"].(string), s.logger)

	// Apply device merging if requested
	if params["mergedStr"].(string) == "true" {
		filteredDevices = mergeRelatedDevices(ctx, s.deviceRegistry, filteredDevices, s.logger)
	}

	// Format and send the response
	s.sendDeviceRegistryResponse(w, filteredDevices)

	return true
}

// sendDeviceRegistryResponse formats and sends the response for device registry path
func (s *APIServer) sendDeviceRegistryResponse(w http.ResponseWriter, devices []*models.UnifiedDevice) {
	// Convert to response format with discovery information
	response := make([]map[string]interface{}, len(devices))

	for i, device := range devices {
		response[i] = map[string]interface{}{
			"device_id":         device.DeviceID,
			"ip":                device.IP,
			"hostname":          getFieldValue(device.Hostname),
			"mac":               getFieldValue(device.MAC),
			"first_seen":        device.FirstSeen,
			"last_seen":         device.LastSeen,
			"is_available":      device.IsAvailable,
			"device_type":       device.DeviceType,
			"discovery_sources": device.DiscoverySources,
			"metadata":          getFieldValue(device.Metadata),
		}
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding enhanced devices response")
		writeError(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// fallbackToSRQLQuery handles the SRQL query fallback path for device listing
func (s *APIServer) fallbackToSRQLQuery(ctx context.Context, w http.ResponseWriter, params map[string]interface{}) {
	query := buildDeviceSRQLQuery(params)

	// Execute the SRQL query
	result, err := s.queryExecutor.ExecuteQuery(ctx, query)
	if err != nil {
		s.logger.Error().Err(err).Msg("Error executing devices query")
		writeError(w, "Failed to retrieve devices", http.StatusInternalServerError)

		return
	}

	// Post-process device results (same as the /api/query endpoint)
	if len(result) > 0 {
		result = s.postProcessDeviceResults(result)
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(result); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding devices response")
		writeError(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// buildDeviceSRQLQuery constructs an SRQL query for device listing based on parameters
func buildDeviceSRQLQuery(params map[string]interface{}) string {
	query := "SHOW DEVICES"

	var whereClauses []string

	// Add search filter
	searchTerm := params["searchTerm"].(string)
	if searchTerm != "" {
		whereClauses = append(whereClauses, fmt.Sprintf("(ip LIKE '%%%s%%' OR hostname "+
			"LIKE '%%%s%%' OR device_id LIKE '%%%s%%')",
			searchTerm, searchTerm, searchTerm))
	}

	// Add status filter
	status := params["status"].(string)
	if status == "online" {
		whereClauses = append(whereClauses, "is_available = true")
	} else if status == "offline" {
		whereClauses = append(whereClauses, "is_available = false")
	}

	// Combine where clauses
	if len(whereClauses) > 0 {
		query += " WHERE " + strings.Join(whereClauses, " AND ")
	}

	// Add ordering
	query += " ORDER BY last_seen DESC"

	// Add limit
	query += fmt.Sprintf(" LIMIT %d", params["limit"].(int))

	return query
}

// @Summary Get specific device
// @Description Retrieves details for a specific device by device ID
// @Tags Devices
// @Accept json
// @Produce json
// @Param id path string true "Device ID (format: partition:ip)"
// @Success 200 {object} models.Device "Device details"
// @Failure 400 {object} models.ErrorResponse "Invalid device ID"
// @Failure 404 {object} models.ErrorResponse "Device not found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/devices/{id} [get]
// @Security ApiKeyAuth
func (s *APIServer) getDevice(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)

	deviceID := vars["id"]

	// Set a timeout for the request
	ctx, cancel := context.WithTimeout(r.Context(), defaultTimeout)
	defer cancel()

	// Try device registry first (enhanced device data with discovery sources)
	if s.deviceRegistry != nil {
		unifiedDevice, err := s.deviceRegistry.GetMergedDevice(ctx, deviceID)
		if err == nil {
			// Convert to legacy device format and add discovery source information
			response := struct {
				*models.Device
				DiscoveryInfo *models.UnifiedDevice `json:"discovery_info,omitempty"`
			}{
				Device:        unifiedDevice.ToLegacyDevice(),
				DiscoveryInfo: unifiedDevice, // Include enhanced discovery information
			}

			w.Header().Set("Content-Type", "application/json")

			if err = json.NewEncoder(w).Encode(response); err != nil {
				s.logger.Error().Err(err).Msg("Error encoding enhanced device response")

				writeError(w, "Failed to encode response", http.StatusInternalServerError)
			}

			return
		}

		s.logger.Warn().Err(err).Str("device_id", deviceID).Msg("Device registry lookup failed, falling back to legacy")
	}

	// Fallback to legacy database service
	if s.dbService == nil {
		writeError(w, "Database not configured", http.StatusInternalServerError)
		return
	}

	device, err := s.dbService.GetDeviceByID(ctx, deviceID)
	if err != nil {
		s.logger.Error().Err(err).Str("device_id", deviceID).Msg("Error fetching device")
		writeError(w, "Device not found", http.StatusNotFound)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(device); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding device response")
		writeError(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// @Summary Get device metrics
// @Description Retrieves all metrics for a specific device within a time range
// @Tags Devices
// @Accept json
// @Produce json
// @Param id path string true "Device ID (format: partition:ip)"
// @Param start query string false "Start time in RFC3339 format"
// @Param end query string false "End time in RFC3339 format"
// @Param type query string false "Filter by metric type (snmp, icmp, rperf, sysmon)"
// @Success 200 {array} models.TimeseriesMetric "Device metrics"
// @Failure 400 {object} models.ErrorResponse "Invalid request parameters"
// @Failure 404 {object} models.ErrorResponse "Device not found"
// @Failure 500 {object} models.ErrorResponse "Internal server error"
// @Router /api/devices/{id}/metrics [get]
// @Security ApiKeyAuth
func (s *APIServer) getDeviceMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	deviceID := vars["id"]

	// Set a timeout for the request
	ctx, cancel := context.WithTimeout(r.Context(), defaultTimeout)
	defer cancel()

	// Parse time range
	startTime, endTime, err := parseTimeRange(r.URL.Query())
	if err != nil {
		writeError(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Check if database is configured
	if s.dbService == nil {
		writeError(w, "Database not configured", http.StatusInternalServerError)
		return
	}

	// Get metric type filter
	metricType := r.URL.Query().Get("type")

	var timeseriesMetrics []models.TimeseriesMetric

	// For ICMP timeseriesMetrics, use the in-memory ring buffer instead of database
	if metricType == "icmp" && s.metricsManager != nil {
		s.logger.Debug().Str("device_id", deviceID).Msg("Fetching ICMP metrics from ring buffer")

		// Get timeseriesMetrics from ring buffer
		ringBufferMetrics := s.metricsManager.GetMetricsByDevice(deviceID)

		// Convert MetricPoint to TimeseriesMetric and filter by time range
		for _, mp := range ringBufferMetrics {
			// Filter by time range
			if mp.Timestamp.After(startTime) && mp.Timestamp.Before(endTime) {
				// Convert from MetricPoint to TimeseriesMetric
				timeseriesMetrics = append(timeseriesMetrics, models.TimeseriesMetric{
					PollerID:  mp.PollerID,
					DeviceID:  mp.DeviceID,
					Partition: mp.Partition,
					Name:      fmt.Sprintf("icmp_%s_response_time_ms", mp.ServiceName),
					Value:     fmt.Sprintf("%d", mp.ResponseTime),
					Type:      "icmp",
					Timestamp: mp.Timestamp,
					Metadata:  fmt.Sprintf(`{"host":"unknown","response_time":"%d","available":"true"}`, mp.ResponseTime),
				})
			}
		}

		s.logger.Debug().
			Int("metric_count", len(timeseriesMetrics)).
			Str("device_id", deviceID).
			Msg("Found ICMP metrics in ring buffer")
	} else {
		// Use database for non-ICMP timeseriesMetrics or when ring buffer not available
		if metricType != "" {
			// Get timeseriesMetrics filtered by type
			timeseriesMetrics, err = s.dbService.GetMetricsForDeviceByType(ctx, deviceID, metricType, startTime, endTime)
		} else {
			// Get all timeseriesMetrics for the device
			timeseriesMetrics, err = s.dbService.GetMetricsForDevice(ctx, deviceID, startTime, endTime)
		}

		if err != nil {
			s.logger.Error().Err(err).Str("device_id", deviceID).Msg("Error fetching timeseries metrics")
			writeError(w, "Failed to fetch device timeseriesMetrics", http.StatusInternalServerError)

			return
		}
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(timeseriesMetrics); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding device timeseries metrics response")
		writeError(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// @Summary Get status of which devices have metrics
// @Description Retrieves a list of device IDs that have recent metrics available in the ring buffer
// @Tags Devices
// @Accept json
// @Produce json
// @Success 200 {object} DeviceMetricsStatusResponse "List of device IDs with available metrics"
// @Failure 500 {object} models.ErrorResponse "Internal server error or metrics not configured"
// @Router /api/devices/metrics/status [get]
// @Security ApiKeyAuth
func (s *APIServer) getDeviceMetricsStatus(w http.ResponseWriter, _ *http.Request) {
	if s.metricsManager == nil {
		writeError(w, "Metrics not configured", http.StatusInternalServerError)

		return
	}

	deviceIDs := s.metricsManager.GetDevicesWithActiveMetrics()

	response := DeviceMetricsStatusResponse{
		DeviceIDs: deviceIDs,
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		s.logger.Error().Err(err).Msg("Error encoding device metrics status response")

		writeError(w, "Failed to encode response", http.StatusInternalServerError)
	}
}

// Helper functions for device registry integration

// getFieldValue extracts the value from a DiscoveredField, returning nil if the field is nil
func getFieldValue[T any](field *models.DiscoveredField[T]) interface{} {
	if field == nil {
		return nil
	}

	return field.Value
}

// filterDevices filters unified devices based on search term and status
func filterDevices(devices []*models.UnifiedDevice, searchTerm, status string, logger logger.Logger) []*models.UnifiedDevice {
	filtered := make([]*models.UnifiedDevice, 0, len(devices))

	for _, device := range devices {
		// Filter out merged devices (safety net) - ALWAYS apply this filter
		if device.Metadata != nil && device.Metadata.Value != nil {
			if mergedInto, hasMerged := device.Metadata.Value["_merged_into"]; hasMerged {
				logger.Debug().Str("device_id", device.DeviceID).Str("merged_into", mergedInto).Msg("Filtering out merged device")

				continue // Skip merged devices
			}
		}

		// Apply search filter
		if searchTerm != "" {
			searchLower := strings.ToLower(searchTerm)
			if !strings.Contains(strings.ToLower(device.IP), searchLower) &&
				!strings.Contains(strings.ToLower(device.DeviceID), searchLower) {
				// Check hostname if available
				if device.Hostname == nil || !strings.Contains(strings.ToLower(device.Hostname.Value), searchLower) {
					continue
				}
			}
		}

		// Apply status filter
		if status == "online" && !device.IsAvailable {
			continue
		}

		if status == "offline" && device.IsAvailable {
			continue
		}

		filtered = append(filtered, device)
	}

	return filtered
}

// mergeRelatedDevices merges devices that share IPs into unified views
// This provides application-level device unification for the device listing API
func mergeRelatedDevices(
	ctx context.Context,
	registry DeviceRegistryService,
	devices []*models.UnifiedDevice,
	logger logger.Logger) []*models.UnifiedDevice {
	if registry == nil || len(devices) == 0 {
		return devices
	}

	// Track which devices have been processed to avoid duplicates
	processed := make(map[string]bool)

	mergedDevices := make([]*models.UnifiedDevice, 0, len(devices))

	for _, device := range devices {
		if processed[device.DeviceID] {
			continue // Skip if already processed as part of a merge
		}

		// Try to get the merged view of this device
		mergedDevice, err := registry.GetMergedDevice(ctx, device.DeviceID)
		if err != nil {
			logger.Warn().Err(err).Str("device_id", device.DeviceID).Msg("Failed to get merged device")
			// Fallback to original device if merging fails
			mergedDevices = append(mergedDevices, device)
			processed[device.DeviceID] = true

			continue
		}

		// Find all related devices in the original list and mark them as processed
		relatedDevices, err := registry.FindRelatedDevices(ctx, device.DeviceID)
		if err != nil {
			logger.Warn().Err(err).Str("device_id", device.DeviceID).Msg("Failed to find related devices")
		} else {
			for _, related := range relatedDevices {
				processed[related.DeviceID] = true
			}
		}

		mergedDevices = append(mergedDevices, mergedDevice)
	}

	logger.Info().Int("original_count", len(devices)).Int("merged_count", len(mergedDevices)).Msg("Device merging complete")

	return mergedDevices
}

// RegisterMCPRoutes registers MCP routes with the API server
func (s *APIServer) RegisterMCPRoutes(mcpServer MCPRouteRegistrar) {
	// Use the protected router which already has authentication middleware
	if s.protectedRouter != nil {
		mcpServer.RegisterRoutes(s.protectedRouter)
	} else {
		// Fallback to creating a new protected subrouter if protectedRouter isn't set yet
		if s.logger != nil {
			s.logger.Warn().Msg("Protected router not initialized, creating new subrouter")
		}

		apiRouter := s.router.PathPrefix("/api").Subrouter()
		apiRouter.Use(s.authenticationMiddleware)
		mcpServer.RegisterRoutes(apiRouter)
	}
}

// ExecuteSRQLQuery executes an SRQL query and returns the results
func (s *APIServer) ExecuteSRQLQuery(ctx context.Context, query string, limit int) ([]map[string]interface{}, error) {
	// Create a QueryRequest similar to the HTTP API
	req := &QueryRequest{
		Query: query,
		Limit: limit,
	}

	// Validate the request
	if errMsg, _, ok := validateQueryRequest(req); !ok {
		return nil, fmt.Errorf("invalid query request: %s", errMsg)
	}

	// Prepare the query
	parsedQuery, _, err := s.prepareQuery(req)
	if err != nil {
		return nil, fmt.Errorf("failed to prepare query: %w", err)
	}

	// Execute the query and build response
	response, err := s.executeQueryAndBuildResponse(ctx, parsedQuery, req)
	if err != nil {
		return nil, fmt.Errorf("failed to execute query: %w", err)
	}

	return response.Results, nil
}
