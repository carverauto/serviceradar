package cloud

import (
	"context"
	"log"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/cloud/api"
	"github.com/mfreeman451/homemon/proto"
)

type AlertFunc func(pollerID string, duration time.Duration)

type Server struct {
	proto.UnimplementedPollerServiceServer
	mu             sync.RWMutex
	lastSeen       map[string]time.Time
	alertThreshold time.Duration
	alertFunc      AlertFunc
	apiServer      *api.APIServer
}

func (s *Server) SetAPIServer(api *api.APIServer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.apiServer = api
}

func NewServer(alertThreshold time.Duration, alertFunc AlertFunc) *Server {
	return &Server{
		lastSeen:       make(map[string]time.Time),
		alertThreshold: alertThreshold,
		alertFunc:      alertFunc,
	}
}

func (s *Server) ReportStatus(ctx context.Context, req *proto.PollerStatusRequest) (*proto.PollerStatusResponse, error) {
	s.mu.Lock()
	s.lastSeen[req.PollerId] = time.Unix(req.Timestamp, 0)
	s.mu.Unlock()

	for _, status := range req.Services {
		if !status.Available {
			log.Printf("Alert: Service %s is down: %s", status.ServiceName, status.Message)
		}
	}

	return &proto.PollerStatusResponse{Received: true}, nil
}

func (s *Server) MonitorPollers(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.checkPollers()
		}
	}
}

func (s *Server) checkPollers() {
	now := time.Now()
	s.mu.RLock()
	defer s.mu.RUnlock()

	for pollerID, lastSeen := range s.lastSeen {
		if duration := now.Sub(lastSeen); duration > s.alertThreshold {
			if s.alertFunc != nil {
				s.alertFunc(pollerID, duration)
			}
		}
	}
}
