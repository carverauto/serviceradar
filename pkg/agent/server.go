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

	"github.com/mfreeman451/serviceradar/pkg/checker"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/proto"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

const (
	grpcConfigurationName    = "grpc"
	portConfigurationName    = "port"
	processConfigurationName = "process"
)

var (
	errInvalidDuration  = errors.New("invalid duration")
	errStoppingServices = errors.New("errors stopping services")
)

type Duration time.Duration

// SweepConfig represents sweep service configuration from JSON.
type SweepConfig struct {
	Networks    []string           `json:"networks"`
	Ports       []int              `json:"ports"`
	SweepModes  []models.SweepMode `json:"sweep_modes"`
	Interval    Duration           `json:"interval"`
	Concurrency int                `json:"concurrency"`
	Timeout     Duration           `json:"timeout"`
}

// CheckerConfig represents the configuration for a checker.
type CheckerConfig struct {
	Name       string          `json:"name"`
	Type       string          `json:"type"`
	Address    string          `json:"address,omitempty"`
	Port       int             `json:"port,omitempty"`
	Timeout    Duration        `json:"timeout,omitempty"`
	ListenAddr string          `json:"listen_addr,omitempty"`
	Additional json.RawMessage `json:"additional,omitempty"`
}

// Server implements the AgentService interface.
type Server struct {
	proto.UnimplementedAgentServiceServer
	mu            sync.RWMutex
	checkers      map[string]checker.Checker
	checkerConfs  map[string]CheckerConfig
	configDir     string
	services      []Service
	healthChecker *health.Server
	grpcServer    *grpc.Server
	listenAddr    string
	registry      checker.Registry
}

func (s *Server) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	var errs []error

	// Stop services
	for _, svc := range s.services {
		if err := svc.Stop(); err != nil {
			errs = append(errs, fmt.Errorf("failed to stop service %s: %w", svc.Name(), err))
		}
	}

	// Stop gRPC server
	if s.grpcServer != nil {
		s.grpcServer.Stop()
	}

	if len(errs) > 0 {
		return fmt.Errorf("%w: %v", errStoppingServices, errs)
	}

	return nil
}

func NewServer(configDir string) (*Server, error) {
	s := &Server{
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]CheckerConfig),
		configDir:    configDir,
		services:     make([]Service, 0),
		listenAddr:   ":50051",
		registry:     initRegistry(),
	}

	// Load configurations
	if err := s.loadConfigurations(); err != nil {
		return nil, fmt.Errorf("failed to load configurations: %w", err)
	}

	return s, nil
}

func (s *Server) loadConfigurations() error {
	// Load checker configs
	if err := s.loadCheckerConfigs(); err != nil {
		return fmt.Errorf("failed to load checker configs: %w", err)
	}

	// Load sweep service if configured
	sweepConfigPath := filepath.Join(s.configDir, "sweep", "sweep.json")

	service, err := s.loadSweepService(sweepConfigPath)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("failed to load sweep service: %w", err)
		}
		// If file doesn't exist, just log and continue
		log.Printf("No sweep service config found at %s", sweepConfigPath)

		return nil
	}

	if service != nil {
		s.services = append(s.services, service)
	}

	return nil
}

func (*Server) loadSweepService(configPath string) (Service, error) {
	// Load and parse config file
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read sweep config: %w", err)
	}

	var sweepConfig SweepConfig
	if err = json.Unmarshal(data, &sweepConfig); err != nil {
		return nil, fmt.Errorf("failed to parse sweep config: %w", err)
	}

	// Convert to models.Config
	config := &models.Config{
		Networks:    sweepConfig.Networks,
		Ports:       sweepConfig.Ports,
		SweepModes:  sweepConfig.SweepModes,
		Interval:    time.Duration(sweepConfig.Interval),
		Concurrency: sweepConfig.Concurrency,
		Timeout:     time.Duration(sweepConfig.Timeout),
	}

	// Create and return service
	service, err := NewSweepService(config)
	if err != nil {
		return nil, fmt.Errorf("failed to create sweep service: %w", err)
	}

	log.Printf("Successfully created sweep service with config: %+v", config)

	return service, nil
}

func (s *Server) Start(ctx context.Context) error {
	// Initialize gRPC server
	s.grpcServer = grpc.NewServer(s.listenAddr)

	// Register our agent service
	proto.RegisterAgentServiceServer(s.grpcServer.GetGRPCServer(), s)

	// Create and register health service
	s.healthChecker = health.NewServer()
	if err := s.grpcServer.RegisterHealthServer(s.healthChecker); err != nil {
		return fmt.Errorf("failed to register health server: %w", err)
	}

	// Start services
	for _, svc := range s.services {
		if err := svc.Start(ctx); err != nil {
			return fmt.Errorf("failed to start service %s: %w", svc.Name(), err)
		}

		s.healthChecker.SetServingStatus(svc.Name(), healthpb.HealthCheckResponse_SERVING)
	}

	return nil
}

func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("Received status request: %+v", req)

	// Special handling for sweep status requests
	if req.ServiceType == "sweep" {
		return s.getSweepStatus(ctx)
	}

	// Validate details field for port checks
	if req.ServiceType == "port" && req.Details == "" {
		return nil, fmt.Errorf("details field is required for port checks")
	}

	// Get the appropriate checker
	c, err := s.getChecker(ctx, req)
	if err != nil {
		return nil, err
	}

	// Execute the check
	available, message := c.Check(ctx)

	// Return the status response
	return &proto.StatusResponse{
		Available:   available,
		Message:     message,
		ServiceName: req.ServiceName,
		ServiceType: req.ServiceType,
	}, nil
}

// UnmarshalJSON implements json.Unmarshaler for Duration.
func (d *Duration) UnmarshalJSON(b []byte) error {
	var v interface{}
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}

	switch value := v.(type) {
	case float64:
		*d = Duration(time.Duration(value))
		return nil
	case string:
		tmp, err := time.ParseDuration(value)
		if err != nil {
			return err
		}

		*d = Duration(tmp)

		return nil
	default:
		return errInvalidDuration
	}
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

// getSweepStatus handles status requests specifically for the sweep service.
func (s *Server) getSweepStatus(ctx context.Context) (*proto.StatusResponse, error) {
	// Find sweep service among registered services
	for _, svc := range s.services {
		if provider, ok := svc.(SweepStatusProvider); ok {
			return provider.GetStatus(ctx)
		}
	}

	// Return a response indicating sweep service is not configured
	return &proto.StatusResponse{
		Available:   false,
		Message:     "Sweep service not configured",
		ServiceName: "network_sweep",
		ServiceType: "sweep",
	}, nil
}

func (s *Server) getChecker(ctx context.Context, req *proto.StatusRequest) (checker.Checker, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := fmt.Sprintf("%s:%s", req.GetServiceType(), req.GetServiceName())

	// Return existing checker if available
	if check, exists := s.checkers[key]; exists {
		return check, nil
	}

	// Create new checker using registry
	check, err := s.registry.Get(ctx, req.ServiceType, req.ServiceName, req.Details)
	if err != nil {
		return nil, err
	}

	// Cache the checker
	s.checkers[key] = check
	return check, nil
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

// Close stops all services and cleans up resources.
func (s *Server) Close() error {
	var closeErrs []error

	for _, svc := range s.services {
		if err := svc.Stop(); err != nil {
			closeErrs = append(closeErrs, err)

			log.Printf("Error stopping service: %v", err)
		}
	}

	if len(closeErrs) > 0 {
		return fmt.Errorf("%w: %v", errShutdown, closeErrs)
	}

	return nil
}
