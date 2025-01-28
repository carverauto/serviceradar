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
	srHttp "github.com/mfreeman451/serviceradar/pkg/http"
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
	metricsManager     metrics.MetricCollector
}

func NewAPIServer(metricsManager metrics.MetricCollector) *APIServer {
	s := &APIServer{
		nodes:          make(map[string]*NodeStatus),
		router:         mux.NewRouter(),
		metricsManager: metricsManager,
	}
	s.setupRoutes()

	return s
}

func (s *APIServer) setupStaticFileServing() {
	fsys, err := fs.Sub(webContent, "web/dist")
	if err != nil {
		log.Printf("Error setting up static file serving: %v", err)
		return
	}

	s.router.PathPrefix("/").Handler(http.FileServer(http.FS(fsys)))
}

//go:embed web/dist/*
var webContent embed.FS

func (s *APIServer) setupRoutes() {
	// Add CORS middleware
	s.router.Use(srHttp.CommonMiddleware)

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

	// Serve static files
	s.setupStaticFileServing()
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

func (s *APIServer) handleSweepService(svc *ServiceStatus) {
	var sweepData map[string]interface{}
	if err := json.Unmarshal(svc.Details, &sweepData); err != nil {
		log.Printf("Error parsing sweep details: %v", err)
		return
	}

	if hosts, ok := sweepData["hosts"].([]interface{}); ok {
		for _, h := range hosts {
			if host, ok := h.(map[string]interface{}); ok {
				if icmpStatus, ok := host["icmp_status"].(map[string]interface{}); ok {
					// Convert round_trip to float64 if it exists
					if rt, exists := icmpStatus["round_trip"].(float64); exists {
						log.Printf("Host %v ICMP RTT: %.2fms",
							host["host"],
							float64(rt)/float64(time.Millisecond))
					}
					log.Printf("Host %v ICMP status: %+v", host["host"], icmpStatus)
				}
			}
		}
	}
}

func (s *APIServer) UpdateNodeStatus(nodeID string, status *NodeStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, svc := range status.Services {
		if svc.Type == "sweep" {
			s.handleSweepService(&svc)
		}
	}

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
	nodes := make([]*NodeStatus, 0, len(s.nodes))

	for _, node := range s.nodes {
		log.Printf("Node %s services:", node.NodeID)
		nodes = append(nodes, node)
	}
	s.mu.RUnlock()

	if err := s.encodeJSONResponse(w, nodes); err != nil {
		http.Error(w, "Internal server error", http.StatusInternalServerError)
	}
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
