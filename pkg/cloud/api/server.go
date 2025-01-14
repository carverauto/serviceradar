// pkg/cloud/api/server.go

package api

import (
	"embed"
	"encoding/json"
	"io"
	"io/fs"
	"log"
	"net/http"
	"path"
	"strings"
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

			if r.Method == "OPTIONS" {
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

type spaHandler struct {
	staticFS   http.FileSystem
	indexPath  string
	staticPath string
}

func (h spaHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Get the absolute path to prevent directory traversal
	p := path.Clean(r.URL.Path)

	// Try to serve the requested file
	f, err := h.staticFS.Open(strings.TrimPrefix(p, "/"))
	if err != nil {
		// If file not found, serve index.html
		index, err := h.staticFS.Open(h.indexPath)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer index.Close()
		http.ServeContent(w, r, h.indexPath, time.Time{}, index.(io.ReadSeeker))
		return
	}
	defer f.Close()

	http.ServeContent(w, r, p, time.Time{}, f.(io.ReadSeeker))
}

func (s *APIServer) UpdateNodeStatus(nodeID string, status *NodeStatus) {
	s.mu.Lock()
	s.nodes[nodeID] = status
	s.mu.Unlock()

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
}

// Add new endpoint for history
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
	json.NewEncoder(w).Encode(history)
}

func (s *APIServer) getNodes(w http.ResponseWriter, r *http.Request) {
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
			json.NewEncoder(w).Encode(service)
			return
		}
	}

	http.Error(w, "Service not found", http.StatusNotFound)
}

func (s *APIServer) getSystemStatus(w http.ResponseWriter, r *http.Request) {
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

	log.Printf("System status: %+v", status)
	json.NewEncoder(w).Encode(status)
}

func (s *APIServer) Start(addr string) error {
	return http.ListenAndServe(addr, s.router)
}
