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
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/core/auth"
	"github.com/carverauto/serviceradar/pkg/db"
	srHttp "github.com/carverauto/serviceradar/pkg/http"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/metricstore"
	"github.com/carverauto/serviceradar/pkg/models"
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
		return srHttp.CommonMiddleware(next, corsConfig)
	}

	s.router.Use(middlewareChain)
}

// authenticationMiddleware provides flexible authentication, allowing either a Bearer token or an API key.
func (s *APIServer) authenticationMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Option 1: Authenticate with a Bearer token.
		authHeader := r.Header.Get("Authorization")
		if s.authService != nil && strings.HasPrefix(authHeader, "Bearer ") {
			// Use the existing auth.AuthMiddleware to validate the token and enrich the context.
			// We use a test recorder to "catch" the result of the middleware without it writing
			// a premature response. This allows us to fall back to the API key check.
			var isAuthenticated bool

			var enrichedRequest *http.Request

			recorder := httptest.NewRecorder()

			// This handler will only be called by the authMiddleware if the token is valid.
			dummyHandler := http.HandlerFunc(func(_ http.ResponseWriter, req *http.Request) {
				isAuthenticated = true
				enrichedRequest = req // Capture the request with the new context
			})

			authMiddleware := auth.AuthMiddleware(s.authService)
			authMiddleware(dummyHandler).ServeHTTP(recorder, r)

			if isAuthenticated {
				// Token was valid, proceed with the original flow using the enriched request.
				next.ServeHTTP(w, enrichedRequest)

				return
			}
		}

		// Option 2: Authenticate with an API Key.
		apiKey := os.Getenv("API_KEY")
		if apiKey != "" && r.Header.Get("X-API-Key") == apiKey {
			next.ServeHTTP(w, r)
			return
		}

		// If neither method is successful, and auth is configured, deny access.
		isAuthEnabled := os.Getenv("AUTH_ENABLED") == "true"

		apiKeyConfigured := apiKey != ""
		if isAuthEnabled || apiKeyConfigured {
			writeError(w, "Unauthorized", http.StatusUnauthorized)

			return
		}

		// Fallback for development: if no auth is configured, allow the request.
		next.ServeHTTP(w, r)
	})
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
func (*APIServer) serveSwaggerJSON(w http.ResponseWriter, _ *http.Request) {
	data, err := swagger.GetSwaggerJSON()
	if err != nil {
		http.Error(w, "Swagger JSON not found", http.StatusInternalServerError)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	_, err = w.Write(data)
	if err != nil {
		log.Printf("Error writing Swagger JSON response: %v", err)
		http.Error(w, "Failed to write Swagger JSON response", http.StatusInternalServerError)

		return
	}
}

// serveSwaggerYAML serves the embedded Swagger YAML file.
func (*APIServer) serveSwaggerYAML(w http.ResponseWriter, _ *http.Request) {
	data, err := swagger.GetSwaggerYAML()
	if err != nil {
		http.Error(w, "Swagger YAML not found", http.StatusInternalServerError)

		return
	}

	w.Header().Set("Content-Type", "application/yaml")

	_, err = w.Write(data)
	if err != nil {
		log.Printf("Error writing Swagger YAML response: %v", err)

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
		log.Printf("Error encoding Swagger spec: %v", err)

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
	protected.HandleFunc("/query", s.handleSRQLQuery).Methods("POST")
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
		log.Printf("Error fetching SNMP data for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(snmpMetrics); err != nil {
		log.Printf("Error encoding SNMP data response for poller %s: %v", pollerID, err)
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
		log.Printf("Metrics not configured for poller %s", pollerID)
		http.Error(w, "Metrics not configured", http.StatusInternalServerError)

		return
	}

	m := s.metricsManager.GetMetrics(pollerID)
	if m == nil {
		log.Printf("No metrics found for poller %s", pollerID)
		http.Error(w, "No metrics found", http.StatusNotFound)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(m); err != nil {
		log.Printf("Error encoding metrics response for poller %s: %v", pollerID, err)

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
		log.Printf("Error fetching poller history: %v", err)
		http.Error(w, "Failed to fetch history", http.StatusInternalServerError)

		return
	}

	if err := s.encodeJSONResponse(w, points); err != nil {
		log.Printf("Error encoding history response: %v", err)
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

	log.Printf("System status: total=%d healthy=%d last_update=%s",
		status.TotalPollers, status.HealthyPollers, status.LastUpdate.Format(time.RFC3339))

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
			log.Printf("Attached %d metrics points to poller %s response", len(m), pollerID)
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
func writeJSONResponse(w http.ResponseWriter, data interface{}, pollerID string) {
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding response for poller %s: %v", pollerID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	} else {
		// Log without trying to determine the length of a specific type
		log.Printf("Successfully wrote metrics response for poller %s", pollerID)
	}
}

// parseTimeRange parses start and end times from query parameters.
// @ignore This is an internal helper function, not directly exposed as an API endpoint
func parseTimeRange(query url.Values) (start, end time.Time, err error) {
	startStr := query.Get("start")
	endStr := query.Get("end")

	// Default to last 24 hours if not specified
	start = time.Now().Add(-24 * time.Hour)
	end = time.Now()

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
