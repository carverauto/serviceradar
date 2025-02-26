// pkg/cloud/api/server.go

package api

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/db"
	srHttp "github.com/carverauto/serviceradar/pkg/http"
	"github.com/carverauto/serviceradar/pkg/metrics"
	"github.com/gorilla/mux"
)

func NewAPIServer(options ...func(server *APIServer)) *APIServer {
	s := &APIServer{
		nodes:  make(map[string]*NodeStatus),
		router: mux.NewRouter(),
		apiKey: "", // Default empty API key
	}

	for _, o := range options {
		o(s)
	}

	s.setupRoutes(s.apiKey)

	return s
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

func WithAPIKey(apiKey string) func(server *APIServer) {
	return func(server *APIServer) {
		server.apiKey = apiKey
	}
}

func WithDB(db db.Service) func(server *APIServer) {
	return func(server *APIServer) {
		server.db = db
	}
}

func (s *APIServer) setupRoutes(apiKey string) {
	// Create a middleware chain
	middlewareChain := func(next http.Handler) http.Handler {
		// Order matters: first API key check, then CORS headers
		return srHttp.CommonMiddleware(srHttp.APIKeyMiddleware(apiKey)(next))
	}

	// Add middleware to router
	s.router.Use(middlewareChain)

	// Basic endpoints
	s.router.HandleFunc("/api/nodes", s.getNodes).Methods("GET")
	s.router.HandleFunc("/api/nodes/{id}", s.getNode).Methods("GET")
	s.router.HandleFunc("/api/status", s.getSystemStatus).Methods("GET")

	// Node history endpoint
	s.router.HandleFunc("/api/nodes/{id}/history", s.getNodeHistory).Methods("GET")

	// Metrics endpoint
	s.router.HandleFunc("/api/nodes/{id}/metrics", s.getNodeMetrics).Methods("GET")

	// Service-specific endpoints
	s.router.HandleFunc("/api/nodes/{id}/services", s.getNodeServices).Methods("GET")
	s.router.HandleFunc("/api/nodes/{id}/services/{service}", s.getServiceDetails).Methods("GET")

	// SNMP endpoints
	s.router.HandleFunc("/api/nodes/{id}/snmp", s.getSNMPData).Methods("GET")
}

// getSNMPData retrieves SNMP data for a specific node.
func (s *APIServer) getSNMPData(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

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
	snmpMetrics, err := s.snmpManager.GetSNMPMetrics(nodeID, startTime, endTime)
	if err != nil {
		log.Printf("Error fetching SNMP data for node %s: %v", nodeID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(snmpMetrics); err != nil {
		log.Printf("Error encoding SNMP data response for node %s: %v", nodeID, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *APIServer) getNodeMetrics(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	if s.metricsManager == nil {
		log.Printf("Metrics not configured for node %s", nodeID)
		http.Error(w, "Metrics not configured", http.StatusInternalServerError)

		return
	}

	m := s.metricsManager.GetMetrics(nodeID)
	if m == nil {
		log.Printf("No metrics found for node %s", nodeID)
		http.Error(w, "No metrics found", http.StatusNotFound)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(m); err != nil {
		log.Printf("Error encoding metrics response for node %s: %v", nodeID, err)

		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *APIServer) SetNodeHistoryHandler(handler func(nodeID string) ([]NodeHistoryPoint, error)) {
	s.nodeHistoryHandler = handler
}

func (s *APIServer) UpdateNodeStatus(nodeID string, status *NodeStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.nodes[nodeID] = status
}

func (s *APIServer) getNodeHistory(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	log.Printf("Getting node history for: %s", nodeID)

	if s.nodeHistoryHandler == nil {
		http.Error(w, "History handler not configured", http.StatusInternalServerError)
		return
	}

	points, err := s.nodeHistoryHandler(nodeID)
	if err != nil {
		log.Printf("Error fetching node history: %v", err)
		http.Error(w, "Failed to fetch history", http.StatusInternalServerError)

		return
	}

	log.Printf("Fetched %d history points for node: %s", len(points), nodeID)

	if err := s.encodeJSONResponse(w, points); err != nil {
		log.Printf("Error encoding history response: %v", err)
		http.Error(w, "Error encoding response", http.StatusInternalServerError)
	}
}

func (s *APIServer) getSystemStatus(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	status := SystemStatus{
		TotalNodes:   len(s.nodes),
		HealthyNodes: 0,
		LastUpdate:   time.Now(),
	}

	for _, node := range s.nodes {
		if node.IsHealthy {
			status.HealthyNodes++
		}
	}
	s.mu.RUnlock()

	log.Printf("System status: total=%d healthy=%d last_update=%s",
		status.TotalNodes, status.HealthyNodes, status.LastUpdate.Format(time.RFC3339))

	if err := s.encodeJSONResponse(w, status); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *APIServer) getNodes(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Preallocate the slice with the correct length
	nodes := make([]*NodeStatus, 0, len(s.nodes))

	// Append all map values to the slice
	for id, node := range s.nodes {
		// Only include known pollers
		for _, known := range s.knownPollers {
			if id == known {
				nodes = append(nodes, node)

				break
			}
		}
	}

	// Encode and send the response
	if err := s.encodeJSONResponse(w, nodes); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *APIServer) SetKnownPollers(knownPollers []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.knownPollers = knownPollers
}

func (s *APIServer) getNodeByID(nodeID string) (*NodeStatus, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	node, exists := s.nodes[nodeID]

	return node, exists
}

func (*APIServer) encodeJSONResponse(w http.ResponseWriter, data interface{}) error {
	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding JSON response: %v", err)

		return err
	}

	return nil
}

func (s *APIServer) getNode(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	// Check if it's a known poller
	isKnown := false

	for _, known := range s.knownPollers {
		if nodeID == known {
			isKnown = true
			break
		}
	}

	if !isKnown {
		http.Error(w, "Node not found", http.StatusNotFound)
		return
	}

	node, exists := s.getNodeByID(nodeID)
	if !exists {
		log.Printf("Node %s not found", nodeID)
		http.Error(w, "Node not found", http.StatusNotFound)

		return
	}

	if s.metricsManager != nil {
		m := s.metricsManager.GetMetrics(nodeID)
		if m != nil {
			node.Metrics = m
			log.Printf("Attached %d metrics points to node %s response", len(m), nodeID)
		}
	}

	if err := s.encodeJSONResponse(w, node); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *APIServer) getNodeServices(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	s.mu.RLock()
	node, exists := s.nodes[nodeID]
	s.mu.RUnlock()

	if !exists {
		http.Error(w, "Node not found", http.StatusNotFound)
		return
	}

	if err := s.encodeJSONResponse(w, node.Services); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *APIServer) getServiceDetails(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]
	serviceName := vars["service"]

	s.mu.RLock()
	node, exists := s.nodes[nodeID]
	s.mu.RUnlock()

	if !exists {
		http.Error(w, "Node not found", http.StatusNotFound)
		return
	}

	for _, service := range node.Services {
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
