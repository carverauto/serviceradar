// Package agent pkg/agent/server.go
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/mfreeman451/homemon/pkg/checker"
	"github.com/mfreeman451/homemon/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	defaultTimeout = 30 * time.Second
)

var (
	errGrpcAddressRequired = errors.New("address is required for gRPC checker")
	errUnknownCheckerType  = errors.New("unknown checker type")
)

// CheckerConfig represents the configuration for a checker.
type CheckerConfig struct {
	Name       string          `json:"name"`
	Type       string          `json:"type"`
	Address    string          `json:"address,omitempty"`
	Port       int             `json:"port,omitempty"`
	Timeout    time.Duration   `json:"timeout,omitempty"`
	ListenAddr string          `json:"listen_addr,omitempty"`
	Additional json.RawMessage `json:"additional,omitempty"`
}

// Server implements the AgentService interface.
type Server struct {
	proto.UnimplementedAgentServiceServer
	mu           sync.RWMutex
	checkers     map[string]checker.Checker
	checkerConfs map[string]CheckerConfig
	configDir    string
}

// NewServer creates a new agent server.
func NewServer(configDir string) (*Server, error) {
	s := &Server{
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]CheckerConfig),
		configDir:    configDir,
	}

	if err := s.loadCheckerConfigs(); err != nil {
		return nil, fmt.Errorf("failed to load checker configs: %w", err)
	}

	return s, nil
}

// loadCheckerConfigs loads all checker configurations from the config directory.
func (s *Server) loadCheckerConfigs() error {
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	for _, file := range files {
		if filepath.Ext(file.Name()) != ".json" {
			continue
		}

		path := filepath.Join(s.configDir, file.Name())

		data, err := os.ReadFile(path)
		if err != nil {
			log.Printf("Warning: Failed to read config file %s: %v", path, err)
			continue
		}

		var conf CheckerConfig
		if err := json.Unmarshal(data, &conf); err != nil {
			log.Printf("Warning: Failed to parse config file %s: %v", path, err)
			continue
		}

		s.checkerConfs[conf.Name] = conf
		log.Printf("Loaded checker config: %s (type: %s)", conf.Name, conf.Type)
	}

	return nil
}

// initializeChecker creates and initializes a checker based on its configuration.
func (*Server) initializeChecker(name string, conf *CheckerConfig) (checker.Checker, error) {
	switch conf.Type {
	case "process":
		return &ProcessChecker{
			ProcessName: name,
		}, nil

	case "port":
		return &PortChecker{
			Host: conf.Address,
			Port: conf.Port,
		}, nil

	case "grpc":
		if conf.Address == "" {
			return nil, fmt.Errorf("gRPC checker %q: %w", name, errGrpcAddressRequired)
		}

		return NewExternalChecker(name, conf.Address)

	default:
		return nil, fmt.Errorf("checker %q: %w", name, errUnknownCheckerType)
	}
}

// getChecker returns an initialized checker, creating it if necessary.
func (s *Server) getChecker(serviceName string) (checker.Checker, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check if we already have an initialized checker
	if check, exists := s.checkers[serviceName]; exists {
		return check, nil
	}

	// Look up the configuration
	conf, exists := s.checkerConfs[serviceName]
	if !exists {
		return nil, status.Errorf(codes.NotFound, "no configuration found for service: %s", serviceName)
	}

	// Initialize the checker
	check, err := s.initializeChecker(serviceName, &conf)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "failed to initialize checker: %v", err)
	}

	s.checkers[serviceName] = check

	return check, nil
}

// GetStatus implements the GetStatus RPC method.
func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("Checking status of service: %s", req.ServiceName)

	// Get or create the checker
	check, err := s.getChecker(req.ServiceName)
	if err != nil {
		return nil, err
	}

	// Create a context with timeout
	timeoutCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	// Perform the check
	available, msg := check.Check(timeoutCtx)

	// Get additional status data if available
	if provider, ok := check.(checker.StatusProvider); ok {
		if statusData := provider.GetStatusData(); statusData != nil {
			msg = string(statusData)
		}
	}

	return &proto.StatusResponse{
		Available: available,
		Message:   msg,
	}, nil
}

// ListServices returns a list of configured services.
func (s *Server) ListServices() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	services := make([]string, 0, len(s.checkerConfs))
	for name := range s.checkerConfs {
		services = append(services, name)
	}

	return services
}

// Close handles cleanup when the server shuts down
func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	var lastErr error

	for name, check := range s.checkers {
		if closer, ok := check.(interface{ Close() error }); ok {
			if err := closer.Close(); err != nil {
				log.Printf("Error closing checker %s: %v", name, err)
				lastErr = err
			}
		}
	}

	return lastErr
}
