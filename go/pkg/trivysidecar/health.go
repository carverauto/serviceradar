package trivysidecar

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
	service    *Service
}

func NewHTTPServer(addr string, service *Service) *HTTPServer {
	handler := http.NewServeMux()
	srv := &HTTPServer{service: service}

	handler.HandleFunc("/healthz", srv.healthz)
	handler.HandleFunc("/readyz", srv.readyz)
	handler.HandleFunc("/metrics", srv.metrics)

	srv.httpServer = &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	return srv
}

func (s *HTTPServer) Start() {
	if s == nil || s.httpServer == nil {
		return
	}

	go func() {
		if err := s.httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("trivy-sidecar: metrics server failed: %v", err)
		}
	}()
}

func (s *HTTPServer) Close() {
	if s == nil || s.httpServer == nil {
		return
	}

	if err := s.httpServer.Close(); err != nil {
		log.Printf("trivy-sidecar: failed closing metrics server: %v", err)
	}
}

func (s *HTTPServer) healthz(w http.ResponseWriter, _ *http.Request) {
	payload := map[string]any{
		"status": "ok",
	}
	writeJSON(w, http.StatusOK, payload)
}

func (s *HTTPServer) readyz(w http.ResponseWriter, _ *http.Request) {
	ready := s.service != nil && s.service.Ready()
	status := http.StatusServiceUnavailable
	if ready {
		status = http.StatusOK
	}

	payload := map[string]any{
		"ready": ready,
	}
	writeJSON(w, status, payload)
}

func (s *HTTPServer) metrics(w http.ResponseWriter, _ *http.Request) {
	if s.service == nil || s.service.metrics == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	s.service.metrics.WritePrometheus(w, s.service.publisher != nil && s.service.publisher.IsConnected())
}

func writeJSON(w http.ResponseWriter, status int, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("trivy-sidecar: failed writing json response: %v", err)
	}
}
