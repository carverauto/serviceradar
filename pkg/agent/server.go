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
	"strings"
	"sync"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/checker"
	"github.com/mfreeman451/serviceradar/pkg/grpc"
	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/proto"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

var (
	errInvalidDuration = errors.New("invalid duration")
)

const (
	defaultErrChanBufferSize = 10
	defaultTimeout           = 30 * time.Second
	jsonSuffix               = ".json"
	snmpPrefix               = "snmp"
	grpcType                 = "grpc"
)

type Duration time.Duration

// SweepConfig represents sweep service configuration from JSON.
type SweepConfig struct {
	MaxTargets    int
	MaxGoroutines int
	BatchSize     int
	MemoryLimit   int64
	Networks      []string           `json:"networks"`
	Ports         []int              `json:"ports"`
	SweepModes    []models.SweepMode `json:"sweep_modes"`
	Interval      Duration           `json:"interval"`
	Concurrency   int                `json:"concurrency"`
	Timeout       Duration           `json:"timeout"`
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
	Details    json.RawMessage `json:"details,omitempty"`
}

// ServerConfig holds the agent server configuration.
type ServerConfig struct {
	ListenAddr string                 `json:"listen_addr"`
	Security   *models.SecurityConfig `json:"security"`
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
	errChan       chan error
	done          chan struct{} // Signal for shutdown
	config        *ServerConfig
	connections   map[string]*CheckerConnection
}

// CheckerConnection represents a connection to a checker service.
type CheckerConnection struct {
	client      *grpc.ClientConn
	serviceName string
	serviceType string
	address     string
}

// ServiceError represents an error from a specific service.
type ServiceError struct {
	ServiceName string
	Err         error
}

func (e *ServiceError) Error() string {
	return fmt.Sprintf("service %s error: %v", e.ServiceName, e.Err)
}

// NewServer creates a new agent server instance.
func NewServer(configDir string, cfg *ServerConfig) (*Server, error) {
	s := &Server{
		checkers:     make(map[string]checker.Checker),
		checkerConfs: make(map[string]CheckerConfig),
		configDir:    configDir,
		services:     make([]Service, 0),
		listenAddr:   ":50051",
		registry:     initRegistry(),
		errChan:      make(chan error, defaultErrChanBufferSize),
		done:         make(chan struct{}),
		config:       cfg,
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

// Start implements the lifecycle.Service interface.
func (s *Server) Start(ctx context.Context) error {
	log.Printf("Starting agent service...")

	// Initialize checkers first
	if err := s.initializeCheckers(ctx); err != nil {
		return fmt.Errorf("failed to initialize checkers: %w", err)
	}

	// Initialize gRPC server (but don't start it - lifecycle package will do that)
	s.grpcServer = grpc.NewServer(s.listenAddr)

	// Register our agent service
	proto.RegisterAgentServiceServer(s.grpcServer.GetGRPCServer(), s)

	// Create and register health service
	s.healthChecker = health.NewServer()
	healthpb.RegisterHealthServer(s.grpcServer.GetGRPCServer(), s.healthChecker)

	// Start services
	for _, svc := range s.services {
		if err := svc.Start(ctx); err != nil {
			return fmt.Errorf("failed to start service %s: %w", svc.Name(), err)
		}

		s.healthChecker.SetServingStatus(svc.Name(), healthpb.HealthCheckResponse_SERVING)
	}

	return nil
}

// Stop implements the lifecycle.Service interface.
func (s *Server) Stop(ctx context.Context) error {
	log.Printf("Stopping agent service...")

	// Close all checker connections
	for name, conn := range s.connections {
		if err := conn.client.Close(); err != nil {
			log.Printf("Error closing connection to checker %s: %v", name, err)
		}
	}

	// Close gRPC server and other resources
	if s.grpcServer != nil {
		s.grpcServer.Stop(ctx)
	}

	return nil
}

func (s *Server) ListenAddr() string {
	return s.config.ListenAddr
}

func (s *Server) SecurityConfig() *models.SecurityConfig {
	return s.config.Security
}

// loadCheckerConfig loads and parses a single checker configuration file.
func (*Server) loadCheckerConfig(path string) (CheckerConfig, error) {
	var conf CheckerConfig

	data, err := os.ReadFile(path)
	if err != nil {
		return conf, fmt.Errorf("failed to read config file %s: %w", path, err)
	}

	// Handle special case for SNMP config files
	if strings.HasPrefix(filepath.Base(path), snmpPrefix) {
		conf.Name = "snmp-" + strings.TrimSuffix(filepath.Base(path), jsonSuffix)
		conf.Type = snmpPrefix
		conf.Additional = data // Use the entire file as Additional

		return conf, nil
	}

	// Parse standard checker configs
	if err := json.Unmarshal(data, &conf); err != nil {
		return conf, fmt.Errorf("failed to parse config file %s: %w", path, err)
	}

	// Set default timeout if not specified
	if conf.Timeout == 0 {
		conf.Timeout = Duration(defaultTimeout)
	}

	// For gRPC checkers, ensure we have an address
	if conf.Type == grpcType && conf.Address == "" {
		conf.Address = conf.ListenAddr // Use listen address as fallback
	}

	log.Printf("Loaded checker config from %s: %+v", path, conf)

	return conf, nil
}

func (s *Server) initializeCheckers(ctx context.Context) error {
	// Load checker configurations
	files, err := os.ReadDir(s.configDir)
	if err != nil {
		return fmt.Errorf("failed to read config directory: %w", err)
	}

	s.connections = make(map[string]*CheckerConnection)

	for _, file := range files {
		if filepath.Ext(file.Name()) != jsonSuffix {
			continue
		}

		config, err := s.loadCheckerConfig(filepath.Join(s.configDir, file.Name()))
		if err != nil {
			log.Printf("Warning: Failed to load checker config %s: %v", file.Name(), err)

			continue
		}

		if config.Type == grpcType {
			// For gRPC checkers, establish connection
			conn, err := s.connectToChecker(ctx, &config)
			if err != nil {
				log.Printf("Warning: Failed to connect to checker %s: %v", config.Name, err)

				continue
			}

			s.connections[config.Name] = conn
		}

		s.checkerConfs[config.Name] = config
		log.Printf("Loaded checker config: %s (type: %s)", config.Name, config.Type)
	}

	return nil
}

func (s *Server) connectToChecker(ctx context.Context, checkerConfig *CheckerConfig) (*CheckerConnection, error) {
	// Create connection config for this checker
	connConfig := &grpc.ConnectionConfig{
		Address: checkerConfig.Address,
		Security: models.SecurityConfig{
			Mode:       s.config.Security.Mode,
			CertDir:    s.config.Security.CertDir,
			ServerName: strings.Split(checkerConfig.Address, ":")[0], // Use hostname part of address
			Role:       "agent",
		},
	}

	log.Printf("Connecting to checker service %s at %s (server name: %s)",
		checkerConfig.Name, checkerConfig.Address, connConfig.Security.ServerName)

	client, err := grpc.NewClient(
		ctx,
		connConfig,
		grpc.WithMaxRetries(defaultMaxRetries),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to checker %s: %w", checkerConfig.Name, err)
	}

	return &CheckerConnection{
		client:      client,
		serviceName: checkerConfig.Name,
		serviceType: checkerConfig.Type,
		address:     checkerConfig.Address,
	}, nil
}

func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	log.Printf("Received status request: %+v", req)

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

		// Special handling for SNMP config
		if strings.HasPrefix(file.Name(), "snmp") {
			var conf CheckerConfig
			conf.Name = "snmp-" + strings.TrimSuffix(file.Name(), ".json")
			conf.Type = "snmp"
			conf.Additional = data // Use the entire file as Additional

			s.checkerConfs[conf.Name] = conf
			log.Printf("Loaded SNMP checker config: %s", conf.Name)

			continue
		}

		// Handle other configs normally
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

	log.Printf("Getting checker for request - Type: %s, Name: %s, Details: %s",
		req.GetServiceType(),
		req.GetServiceName(),
		req.GetDetails())

	key := fmt.Sprintf("%s:%s:%s", req.GetServiceType(), req.GetServiceName(), req.GetDetails())

	// Return existing checker if available
	if check, exists := s.checkers[key]; exists {
		return check, nil
	}

	// Use the details from the request
	details := req.GetDetails()

	log.Printf("Creating new checker with details: %s", details)

	// Create new checker using registry
	check, err := s.registry.Get(ctx, req.ServiceType, req.ServiceName, details)
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

// Close performs final cleanup.
func (s *Server) Close(ctx context.Context) error {
	if err := s.Stop(ctx); err != nil {
		log.Printf("Error during stop: %v", err)
		return err
	}

	close(s.errChan)

	return nil
}
