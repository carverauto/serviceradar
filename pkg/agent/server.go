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
	defaultTimeout           = 30 * time.Second
	grpcConfigurationName    = "grpc"
	portConfigurationName    = "port"
	processConfigurationName = "process"
)

var (
	errGrpcAddressRequired = errors.New("address is required for gRPC checker")
	errUnknownCheckerType  = errors.New("unknown checker type")
	errGrpcMissingConfig   = errors.New("no configuration or address provided for gRPC checker")
	errNoLocalConfig       = errors.New("no local config found")
)

type Duration time.Duration

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

func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string

	if err := json.Unmarshal(b, &s); err == nil {
		// user wrote e.g. "5m"
		parsed, err := time.ParseDuration(s)
		if err != nil {
			return err
		}

		*d = Duration(parsed)

		return nil
	}

	// fallback to number-of-nanoseconds if needed
	var n int64

	if err := json.Unmarshal(b, &n); err != nil {
		return err
	}

	*d = Duration(time.Duration(n))

	return nil
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

// GetStatus returns the status of a service.
func (s *Server) GetStatus(ctx context.Context, req *proto.StatusRequest) (*proto.StatusResponse, error) {
	// logs, etc.
	check, err := s.getChecker(ctx, req) // pass the entire request
	if err != nil {
		return nil, err
	}

	// Run the check
	timeoutCtx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	available, msg := check.Check(timeoutCtx)

	return &proto.StatusResponse{
		Available: available,
		Message:   msg,
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

// Close handles cleanup when the server shuts down.
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
