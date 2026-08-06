package k8sinventory

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"
)

// HTTPServer exposes health and metrics endpoints.
type HTTPServer struct {
	httpServer *http.Server
	controller *Controller
}

func NewHTTPServer(addr string, controller *Controller) *HTTPServer {
	mux := http.NewServeMux()
	s := &HTTPServer{controller: controller}
	mux.HandleFunc("/healthz", s.healthz)
	mux.HandleFunc("/readyz", s.readyz)
	mux.HandleFunc("/metrics", s.metrics)
	mux.HandleFunc("/snapshot", s.snapshot)
	s.httpServer = &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	return s
}

func (s *HTTPServer) Start() {
	if s == nil || s.httpServer == nil {
		return
	}
	go func() {
		if err := s.httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("k8s-inventory: metrics server failed: %v", err)
		}
	}()
}

func (s *HTTPServer) Close() {
	if s == nil || s.httpServer == nil {
		return
	}
	if err := s.httpServer.Close(); err != nil {
		log.Printf("k8s-inventory: failed closing metrics server: %v", err)
	}
}

func (s *HTTPServer) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *HTTPServer) readyz(w http.ResponseWriter, _ *http.Request) {
	ready := s.controller != nil && s.controller.Ready()
	status := http.StatusServiceUnavailable
	if ready {
		status = http.StatusOK
	}
	writeJSON(w, status, map[string]any{"ready": ready})
}

func (s *HTTPServer) metrics(w http.ResponseWriter, _ *http.Request) {
	if s.controller == nil || s.controller.Metrics() == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	s.controller.Metrics().WritePrometheus(w)
}

func (s *HTTPServer) snapshot(w http.ResponseWriter, _ *http.Request) {
	if s.controller == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	snap := s.controller.LastSnapshot()
	writeJSON(w, http.StatusOK, snap)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
