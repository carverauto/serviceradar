// pkg/cloud/api/server.go

package api

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/mux"
	"github.com/mfreeman451/serviceradar/pkg/metrics"
	"github.com/mfreeman451/serviceradar/pkg/models"
)

type ServiceStatus struct {
	Name      string          `json:"name"`
	Available bool            `json:"available"`
	Message   string          `json:"message"`
	Type      string          `json:"type"`    // e.g., "process", "port", "blockchain", etc.
	Details   json.RawMessage `json:"details"` // Flexible field for service-specific data
}

type NodeStatus struct {
	NodeID     string               `json:"node_id"`
	IsHealthy  bool                 `json:"is_healthy"`
	LastUpdate time.Time            `json:"last_update"`
	Services   []ServiceStatus      `json:"services"`
	UpTime     string               `json:"uptime"`
	FirstSeen  time.Time            `json:"first_seen"`
	Metrics    []models.MetricPoint `json:"metrics,omitempty"`
}

type SystemStatus struct {
	TotalNodes   int       `json:"total_nodes"`
	HealthyNodes int       `json:"healthy_nodes"`
	LastUpdate   time.Time `json:"last_update"`
}

type NodeHistory struct {
	NodeID    string
	Timestamp time.Time
	IsHealthy bool
	Services  []ServiceStatus
}

type NodeHistoryPoint struct {
	Timestamp time.Time `json:"timestamp"`
	IsHealthy bool      `json:"is_healthy"`
}

type APIServer struct {
	mu                 sync.RWMutex
	nodes              map[string]*NodeStatus
	router             *mux.Router
	nodeHistoryHandler func(nodeID string) ([]NodeHistoryPoint, error)
	metricsManager     *metrics.MetricsManager
}

func NewAPIServer(metricsManager *metrics.MetricsManager) *APIServer {
	s := &APIServer{
		nodes:          make(map[string]*NodeStatus),
		router:         mux.NewRouter(),
		metricsManager: metricsManager,
	}
	s.setupRoutes()

	return s
}

//go:embed web/dist/*
var webContent embed.FS

func (s *APIServer) setupRoutes() {
	// Add CORS middleware
	s.router.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusOK)
				return
			}

			next.ServeHTTP(w, r)
		})
	})

	// Basic endpoints
	s.router.HandleFunc("/api/nodes", s.getNodes).Methods("GET")
	s.router.HandleFunc("/api/nodes/{id}", s.getNode).Methods("GET")
	s.router.HandleFunc("/api/status", s.getSystemStatus).Methods("GET")

	// History endpoint
	s.router.HandleFunc("/api/nodes/{id}/history", s.getNodeHistory).Methods("GET")

	// Node history endpoint
	s.router.HandleFunc("/api/nodes/{id}/history", s.getNodeHistory).Methods("GET")

	// Service-specific endpoints
	s.router.HandleFunc("/api/nodes/{id}/services", s.getNodeServices).Methods("GET")
	s.router.HandleFunc("/api/nodes/{id}/services/{service}", s.getServiceDetails).Methods("GET")

	// Serve static files
	fsys, err := fs.Sub(webContent, "web/dist")
	if err != nil {
		log.Printf("Error setting up static file serving: %v", err)
		return
	}

	s.router.PathPrefix("/").Handler(http.FileServer(http.FS(fsys)))
}

func (s *APIServer) SetNodeHistoryHandler(handler func(nodeID string) ([]NodeHistoryPoint, error)) {
	s.nodeHistoryHandler = handler
}

func (s *APIServer) UpdateNodeStatus(nodeID string, status *NodeStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Update or add the node status in memory for API responses
	s.nodes[nodeID] = status

	log.Printf("Updated API state for node %s: healthy=%v, services=%d",
		nodeID, status.IsHealthy, len(status.Services))
}

func (s *APIServer) getNodeHistory(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

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

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(points); err != nil {
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

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(status); err != nil {
		log.Printf("Error encoding system status: %v", err)

		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
}

func (s *APIServer) getNodes(w http.ResponseWriter, _ *http.Request) {
	s.mu.RLock()
	nodes := make([]*NodeStatus, 0, len(s.nodes))

	for _, node := range s.nodes {
		log.Printf("Node %s services:", node.NodeID)
		nodes = append(nodes, node)
	}
	s.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(nodes); err != nil {
		log.Printf("Error encoding nodes response: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
	}
}

func (s *APIServer) getNode(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	log.Printf("Getting node status for: %s", nodeID)

	s.mu.RLock()

	node, exists := s.nodes[nodeID]
	if !exists {
		s.mu.RUnlock()
		log.Printf("Node %s not found in nodes map", nodeID)
		http.Error(w, "Node not found", http.StatusNotFound)

		return
	}

	// Get metrics if available
	if s.metricsManager != nil {
		m := s.metricsManager.GetMetrics(nodeID)
		if m != nil {
			node.Metrics = m
			log.Printf("Attached %d metrics points to node %s response",
				len(m), nodeID)
		}
	}
	s.mu.RUnlock()

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(node); err != nil {
		log.Printf("Error encoding node response: %v", err)
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

	err := json.NewEncoder(w).Encode(node.Services)
	if err != nil {
		http.Error(w, "Error encoding JSON", http.StatusInternalServerError)
		return
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
			if err := json.NewEncoder(w).Encode(service); err != nil {
				http.Error(w, "Error encoding JSON", http.StatusInternalServerError)
				return
			}

			return
		}
	}

	http.Error(w, "Service not found", http.StatusNotFound)
}

func (s *APIServer) Start(addr string) error {
	srv := &http.Server{
		Addr:         addr,
		Handler:      s.router,
		ReadTimeout:  10 * time.Second, // Timeout for reading the entire request, including the body.
		WriteTimeout: 10 * time.Second, // Timeout for writing the response.
		IdleTimeout:  60 * time.Second, // Timeout for idle connections waiting in the Keep-Alive state.
		// Optional: You can also set ReadHeaderTimeout to limit the time for reading request headers
		// ReadHeaderTimeout: 5 * time.Second,
	}

	return srv.ListenAndServe()
}
