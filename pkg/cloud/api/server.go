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
)

type ServiceStatus struct {
	Name      string          `json:"name"`
	Available bool            `json:"available"`
	Message   string          `json:"message"`
	Type      string          `json:"type"`    // e.g., "process", "port", "blockchain", etc.
	Details   json.RawMessage `json:"details"` // Flexible field for service-specific data
}

type NodeStatus struct {
	NodeID     string          `json:"node_id"`
	IsHealthy  bool            `json:"is_healthy"`
	LastUpdate time.Time       `json:"last_update"`
	Services   []ServiceStatus `json:"services"`
	UpTime     string          `json:"uptime"`
	FirstSeen  time.Time       `json:"first_seen"`
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

type APIServer struct {
	mu            sync.RWMutex
	nodes         map[string]*NodeStatus
	historyMu     sync.RWMutex
	nodeHistories map[string][]NodeHistory
	maxHistory    int
	router        *mux.Router
}

func NewAPIServer() *APIServer {
	s := &APIServer{
		nodes:         make(map[string]*NodeStatus),
		nodeHistories: make(map[string][]NodeHistory),
		maxHistory:    1000,
		router:        mux.NewRouter(),
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

func (s *APIServer) UpdateNodeStatus(nodeID string, status *NodeStatus) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Update or add the node status
	s.nodes[nodeID] = status

	// Add to history
	s.historyMu.Lock()
	defer s.historyMu.Unlock()

	history := s.nodeHistories[nodeID]
	if history == nil {
		history = make([]NodeHistory, 0)
	}

	// Add new entry
	history = append(history, NodeHistory{
		NodeID:    nodeID,
		Timestamp: status.LastUpdate,
		IsHealthy: status.IsHealthy,
		Services:  status.Services,
	})

	// Trim if too long
	if len(history) > s.maxHistory {
		history = history[len(history)-s.maxHistory:]
	}

	s.nodeHistories[nodeID] = history
	log.Printf("Updated history for node %s: healthy=%v, history_entries=%d",
		nodeID, status.IsHealthy, len(history))
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

// getNodeHistory retrieves the history of a node.
func (s *APIServer) getNodeHistory(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	s.historyMu.RLock()
	history, exists := s.nodeHistories[nodeID]
	s.historyMu.RUnlock()

	if !exists {
		http.Error(w, "Node not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(history); err != nil {
		log.Printf("Error encoding history response: %v", err)
		return
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
	s.mu.RUnlock()

	if !exists {
		log.Printf("Node %s not found in nodes map. Available nodes: %v",
			nodeID, s.getNodeIDs())
		http.Error(w, "Node not found", http.StatusNotFound)

		return
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(node); err != nil {
		log.Printf("Error encoding node response: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)

		return
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

func (s *APIServer) getNodeIDs() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ids := make([]string, 0, len(s.nodes))
	for id := range s.nodes {
		ids = append(ids, id)
	}

	return ids
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
