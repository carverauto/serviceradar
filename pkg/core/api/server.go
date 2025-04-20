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

// pkg/core/api/server.go

package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/rperf"
	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/core/auth"
	srHttp "github.com/carverauto/serviceradar/pkg/http"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/gorilla/mux"
)

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

func WithAuthService(auth auth.AuthService) func(server *APIServer) {
	return func(server *APIServer) {
		server.authService = auth
	}
}

func WithMetricsManager(m metrics.MetricCollector) func(server *APIServer) {
	return func(server *APIServer) {
		server.metricsManager = m
	}
}

func WithSNMPManager(m snmp.SNMPManager) func(server *APIServer) {
	return func(server *APIServer) {
		server.snmpManager = m
	}
}

func WithRperfManager(m rperf.RperfManager) func(server *APIServer) {
	return func(server *APIServer) {
		server.rperfManager = m
	}
}

func (s *APIServer) setupRoutes() {
	corsConfig := models.CORSConfig{
		AllowedOrigins:   s.corsConfig.AllowedOrigins,
		AllowCredentials: s.corsConfig.AllowCredentials,
	}

	middlewareChain := func(next http.Handler) http.Handler {
		// Order matters: CORS first, then API key/auth checks
		return srHttp.CommonMiddleware(srHttp.APIKeyMiddleware(os.Getenv("API_KEY"))(next), corsConfig)
	}

	s.router.Use(middlewareChain)

	// Public routes
	s.router.HandleFunc("/auth/login", s.handleLocalLogin).Methods("POST")
	s.router.HandleFunc("/auth/refresh", s.handleRefreshToken).Methods("POST")
	s.router.HandleFunc("/auth/{provider}", s.handleOAuthBegin).Methods("GET")
	s.router.HandleFunc("/auth/{provider}/callback", s.handleOAuthCallback).Methods("GET")

	// Protected routes
	protected := s.router.PathPrefix("/api").Subrouter()
	if os.Getenv("AUTH_ENABLED") == "true" && s.authService != nil {
		protected.Use(auth.AuthMiddleware(s.authService))
	}

	protected.HandleFunc("/pollers", s.getPollers).Methods("GET")
	protected.HandleFunc("/pollers/{id}", s.getPoller).Methods("GET")
	protected.HandleFunc("/status", s.getSystemStatus).Methods("GET")
	protected.HandleFunc("/pollers/{id}/history", s.getPollerHistory).Methods("GET")
	protected.HandleFunc("/pollers/{id}/metrics", s.getPollerMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/rperf", s.getRperfMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/services", s.getPollerServices).Methods("GET")
	protected.HandleFunc("/pollers/{id}/services/{service}", s.getServiceDetails).Methods("GET")
	protected.HandleFunc("/pollers/{id}/snmp", s.getSNMPData).Methods("GET")

	// Sysmon metrics
	protected.HandleFunc("/pollers/{id}/sysmon/cpu", s.getSysmonCPUMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/sysmon/disk", s.getSysmonDiskMetrics).Methods("GET")
	protected.HandleFunc("/pollers/{id}/sysmon/memory", s.getSysmonMemoryMetrics).Methods("GET")
}

// getSNMPData retrieves SNMP data for a specific poller.
func (s *APIServer) getSNMPData(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	pollerID := vars["id"]

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
	snmpMetrics, err := s.snmpManager.GetSNMPMetrics(pollerID, startTime, endTime)
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

func (s *APIServer) SetPollerHistoryHandler(handler func(pollerID string) ([]PollerHistoryPoint, error)) {
	s.pollerHistoryHandler = handler
}

func (s *APIServer) UpdatePollerStatus(pollerID string, status *PollerStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.pollers[pollerID] = status
}

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

func (s *APIServer) SetKnownPollers(knownPollers []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.knownPollers = knownPollers
}

func (s *APIServer) getPollerByID(pollerID string) (*PollerStatus, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	poller, exists := s.pollers[pollerID]

	return poller, exists
}

func (*APIServer) encodeJSONResponse(w http.ResponseWriter, data interface{}) error {
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding JSON response: %v", err)

		return err
	}

	return nil
}

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
	defaultIdleTimeout  = 60 * time.Second
)

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

// writeError writes an HTTP error response with the given message and status.
func writeError(w http.ResponseWriter, message string, status int) {
	http.Error(w, message, status)
}
