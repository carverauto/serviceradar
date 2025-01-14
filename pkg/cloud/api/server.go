package api

import (
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/mux"
)

type NodeStatus struct {
	NodeID        string    `json:"node_id"`
	IsHealthy     bool      `json:"is_healthy"`
	LastUpdate    time.Time `json:"last_update"`
	BlockHeight   uint64    `json:"block_height"`
	BlockHash     string    `json:"block_hash"`
	BlockTime     time.Time `json:"block_time"`
	ServiceStatus []struct {
		Name      string `json:"name"`
		Available bool   `json:"available"`
		Message   string `json:"message"`
	} `json:"services"`
}

type APIServer struct {
	mu     sync.RWMutex
	nodes  map[string]*NodeStatus
	router *mux.Router
}

func NewAPIServer() *APIServer {
	s := &APIServer{
		nodes:  make(map[string]*NodeStatus),
		router: mux.NewRouter(),
	}
	s.setupRoutes()
	return s
}

func (s *APIServer) setupRoutes() {
	s.router.HandleFunc("/api/nodes", s.getNodes).Methods("GET")
	s.router.HandleFunc("/api/nodes/{id}", s.getNode).Methods("GET")
	s.router.HandleFunc("/api/status", s.getSystemStatus).Methods("GET")
}

func (s *APIServer) getNodes(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	nodes := make([]*NodeStatus, 0, len(s.nodes))
	for _, node := range s.nodes {
		nodes = append(nodes, node)
	}
	s.mu.RUnlock()

	json.NewEncoder(w).Encode(nodes)
}

func (s *APIServer) getNode(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	nodeID := vars["id"]

	s.mu.RLock()
	node, exists := s.nodes[nodeID]
	s.mu.RUnlock()

	if !exists {
		http.Error(w, "Node not found", http.StatusNotFound)
		return
	}

	json.NewEncoder(w).Encode(node)
}

func (s *APIServer) getSystemStatus(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	status := struct {
		TotalNodes    int       `json:"total_nodes"`
		HealthyNodes  int       `json:"healthy_nodes"`
		LastUpdate    time.Time `json:"last_update"`
		AverageHeight uint64    `json:"average_height"`
	}{
		TotalNodes: len(s.nodes),
		LastUpdate: time.Now(),
	}

	var totalHeight uint64
	for _, node := range s.nodes {
		if node.IsHealthy {
			status.HealthyNodes++
			totalHeight += node.BlockHeight
		}
	}
	if status.HealthyNodes > 0 {
		status.AverageHeight = totalHeight / uint64(status.HealthyNodes)
	}
	s.mu.RUnlock()

	json.NewEncoder(w).Encode(status)
}

func (s *APIServer) UpdateNodeStatus(nodeID string, status *NodeStatus) {
	s.mu.Lock()
	s.nodes[nodeID] = status
	s.mu.Unlock()
}

// Start the API server
func (s *APIServer) Start(addr string) error {
	return http.ListenAndServe(addr, s.router)
}
