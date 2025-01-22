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
	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	grpcConfigurationName    = "grpc"
	portConfigurationName    = "port"
	processConfigurationName = "process"
)

var (
	errInvalidDuration = errors.New("invalid duration")
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
	mu           sync.RWMutex
	checkers     map[string]checker.Checker
	checkerConfs map[string]CheckerConfig
	configDir    string
	services     []Service
}

func (s *Server) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	var stopErrs []error

	// Stop all services
	for _, svc := range s.services {
		if err := svc.Stop(); err != nil {
			stopErrs = append(stopErrs, err)
			log.Printf("Error stopping service: %v", err)
		}
	}

	// Check for errors
	if len(stopErrs) > 0 {
		return fmt.Errorf("errors occurred while stopping services: %v", stopErrs)
	}

	return nil
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

	// Load optional services
	if err := s.loadServices(); err != nil {
		log.Printf("Warning: some services failed to load: %v", err)
	}

	return s, nil
}

// Start starts all registered services.
func (s *Server) Start(ctx context.Context) error {
	var startupErrs []error

	// Start each service in its own goroutine
	for _, svc := range s.services {
		go func(svc Service) {
			if err := svc.Start(ctx); err != nil && !errors.Is(err, context.Canceled) {
				startupErrs = append(startupErrs, err)
				log.Printf("Service startup error: %v", err)
			}
		}(svc)
	}

	// If we want to wait for services to start, we could add a startup channel pattern here

	if len(startupErrs) > 0 {
		return fmt.Errorf("%w: %v", errServiceStartup, startupErrs)
	}

	return nil
}

func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	// Special handling for sweep status requests
	if req.ServiceType == "sweep" {
		return s.getSweepStatus(ctx)
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

func loadSweepService(configDir string) (Service, error) {
	sweepConfigPath := filepath.Join(configDir, "sweep.json")
	log.Printf("Looking for sweep config at: %s", sweepConfigPath)

	// Check if config exists
	if _, err := os.Stat(sweepConfigPath); os.IsNotExist(err) {
		log.Printf("Sweep config not found at %s", sweepConfigPath)
		return nil, err
	}

	// Load and parse config
	data, err := os.ReadFile(sweepConfigPath)
	if err != nil {
		log.Printf("Failed to read sweep config: %v", err)
		return nil, fmt.Errorf("failed to read sweep config: %w", err)
	}

	var sweepConfig SweepConfig
	if err = json.Unmarshal(data, &sweepConfig); err != nil {
		log.Printf("Failed to parse sweep config: %v", err)
		return nil, fmt.Errorf("failed to parse sweep config: %w", err)
	}

	log.Printf("Successfully loaded sweep config: %+v", sweepConfig)

	// Convert to sweeper.Config
	config := &models.Config{
		Networks:    sweepConfig.Networks,
		Ports:       sweepConfig.Ports,
		SweepModes:  sweepConfig.SweepModes,
		Interval:    time.Duration(sweepConfig.Interval),
		Concurrency: sweepConfig.Concurrency,
		Timeout:     time.Duration(sweepConfig.Timeout),
	}

	// Create service
	service, err := NewSweepService(config)
	if err != nil {
		log.Printf("Failed to create sweep service: %v", err)
		return nil, err
	}

	log.Printf("Successfully created sweep service with config: %+v", config)

	return service, nil
}

// loadServices initializes any optional services found in the config directory.
func (s *Server) loadServices() error {
	// Try to load sweep service if configured
	sweepService, err := loadSweepService(s.configDir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("failed to load sweep service: %w", err)
		}
	} else if sweepService != nil {
		s.services = append(s.services, sweepService)
	}

	// Additional services can be loaded here in the future
	// Each service should follow the Service interface

	return nil
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

// initializeChecker creates and initializes a checker based on its configuration.
func (*Server) initializeChecker(
	ctx context.Context,
	serviceName, serviceType string,
	conf *CheckerConfig) (checker.Checker, error) {
	switch serviceType {
	case processConfigurationName:
		return &ProcessChecker{
			ProcessName: serviceName,
		}, nil

	case portConfigurationName:
		return &PortChecker{
			Host: conf.Address,
			Port: conf.Port,
		}, nil

	case grpcConfigurationName:
		if conf.Address == "" {
			return nil, fmt.Errorf("gRPC checker %q: %w", serviceName, errGrpcAddressRequired)
		}

		return NewExternalChecker(ctx, serviceName, serviceType, conf.Address)

	default:
		return nil, fmt.Errorf("checker %q: %w", serviceName, errUnknownCheckerType)
	}
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

	s.logCheckerRequest(req)

	dynamicKey := s.getDynamicKey(req)

	// Try to get existing checker
	if check, exists := s.checkers[dynamicKey]; exists {
		return check, nil
	}

	// Try to create checker from local config
	if c, err := s.createFromLocalConfig(ctx, req, dynamicKey); err == nil {
		return c, nil
	}

	// Try to create built-in checker
	return s.createBuiltinChecker(ctx, req, dynamicKey)
}

func (s *Server) logCheckerRequest(req *proto.StatusRequest) {
	log.Printf("Got checker request: serviceName=%q serviceType=%q details=%q port=%d",
		req.GetServiceName(), req.GetServiceType(), req.GetDetails(), req.GetPort())

	log.Printf("Available configs: %v", s.checkerConfs)
}

func (*Server) getDynamicKey(req *proto.StatusRequest) string {
	return fmt.Sprintf("%s:%s", req.GetServiceType(), req.GetServiceName())
}

func (s *Server) createFromLocalConfig(ctx context.Context, req *proto.StatusRequest, dynamicKey string) (checker.Checker, error) {
	conf, ok := s.checkerConfs[req.ServiceName]
	if !ok {
		return nil, errNoLocalConfig
	}

	c, err := s.initializeChecker(ctx, req.ServiceName, req.ServiceType, &conf)
	if err != nil {
		return nil, err
	}

	s.checkers[dynamicKey] = c

	return c, nil
}

func (s *Server) createGRPCChecker(ctx context.Context, req *proto.StatusRequest, dynamicKey string) (checker.Checker, error) {
	log.Printf("Handling gRPC checker request: name=%q details=%q",
		req.GetServiceName(), req.GetDetails())

	if req.Details == "" {
		return nil, errGrpcMissingConfig
	}

	// Try to create from config first
	if conf, ok := s.checkerConfs[req.ServiceName]; ok {
		log.Printf("Found matching config: %+v", conf)

		return s.createCheckerFromConfig(ctx, req, dynamicKey, &conf)
	}

	// Try to create from details as address
	return s.createExternalChecker(ctx, req, dynamicKey)
}

func (s *Server) createCheckerFromConfig(
	ctx context.Context,
	req *proto.StatusRequest,
	dynamicKey string,
	conf *CheckerConfig) (checker.Checker, error) {
	c, err := s.initializeChecker(ctx, req.ServiceName, req.ServiceType, conf)
	if err != nil {
		return nil, err
	}

	s.checkers[dynamicKey] = c

	return c, nil
}

func (s *Server) createExternalChecker(ctx context.Context, req *proto.StatusRequest, dynamicKey string) (checker.Checker, error) {
	ec, err := NewExternalChecker(ctx, req.ServiceName, req.ServiceType, req.Details)
	if err != nil {
		return nil, err
	}

	s.checkers[dynamicKey] = ec

	return ec, nil
}

func (s *Server) createBuiltinChecker(ctx context.Context, req *proto.StatusRequest, dynamicKey string) (checker.Checker, error) {
	switch req.ServiceType {
	case processConfigurationName:
		return s.createProcessChecker(req, dynamicKey)

	case portConfigurationName:
		return s.createPortChecker(req, dynamicKey)

	case grpcConfigurationName:
		return s.createGRPCChecker(ctx, req, dynamicKey)

	default:
		return nil, status.Errorf(codes.NotFound, "no config or dynamic checker for: %s", req.ServiceType)
	}
}

func (s *Server) createProcessChecker(req *proto.StatusRequest, dynamicKey string) (checker.Checker, error) {
	pc := &ProcessChecker{
		ProcessName: req.Details,
	}

	s.checkers[dynamicKey] = pc

	return pc, nil
}

func (s *Server) createPortChecker(req *proto.StatusRequest, dynamicKey string) (checker.Checker, error) {
	portChecker := &PortChecker{
		Host: "127.0.0.1",
		Port: int(req.Port),
	}

	s.checkers[dynamicKey] = portChecker

	return portChecker, nil
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
