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
func (*Server) initializeChecker(ctx context.Context, name string, conf *CheckerConfig) (checker.Checker, error) {
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

		return NewExternalChecker(ctx, name, conf.Address)

	default:
		return nil, fmt.Errorf("checker %q: %w", name, errUnknownCheckerType)
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

	serviceName := req.ServiceName

	// Add debug logging
	log.Printf("Got checker request: serviceName=%q details=%q port=%d",
		req.GetServiceName(), req.GetDetails(), req.GetPort())
	log.Printf("Available configs: %v", s.checkerConfs)

	// 1) Already created a dynamic checker? Re-use it
	//    We'll create a key like "process:rusk" so we can handle multiple
	//    processes or ports
	dynamicKey := serviceName
	if req.Details != "" {
		dynamicKey += ":" + req.Details
	} else if req.Port > 0 {
		dynamicKey += fmt.Sprintf(":p%d", req.Port)
	}

	if check, exists := s.checkers[dynamicKey]; exists {
		return check, nil
	}

	// 2) If there's a local JSON config for "serviceName," use that
	if conf, ok := s.checkerConfs[serviceName]; ok {
		c, err := s.initializeChecker(ctx, serviceName, &conf)
		if err != nil {
			return nil, err
		}
		s.checkers[dynamicKey] = c
		return c, nil
	}

	// 3) No local config? Check the built-in dynamic types
	switch serviceName {
	case "process":
		pc := &ProcessChecker{
			ProcessName: req.Details, // e.g. "rusk"
		}
		s.checkers[dynamicKey] = pc
		return pc, nil

	case "port":
		host := "127.0.0.1"
		// If you wanted host in req.Details, you could parse it here
		// e.g. host = req.Details if not empty
		portChecker := &PortChecker{
			Host: host,
			Port: int(req.Port),
		}
		s.checkers[dynamicKey] = portChecker
		return portChecker, nil

	case "grpc":
		log.Printf("Handling gRPC checker request: details=%q", req.GetDetails())

		// If we have details, try them first
		if req.Details != "" {
			if conf, ok := s.checkerConfs[req.Details]; ok {
				log.Printf("Found matching config: %+v", conf)
				c, err := s.initializeChecker(ctx, req.Details, &conf)
				if err != nil {
					return nil, err
				}
				s.checkers[dynamicKey] = c
				return c, nil
			}

			// If details doesn't match a config name, try as address
			ec, err := NewExternalChecker(ctx, serviceName, req.Details)
			if err != nil {
				return nil, err
			}
			s.checkers[dynamicKey] = ec
			return ec, nil
		}

		// If no details provided, look for a single gRPC config
		for name, conf := range s.checkerConfs {
			if conf.Type == "grpc" {
				log.Printf("Found gRPC config: %s", name)
				c, err := s.initializeChecker(ctx, name, &conf)
				if err != nil {
					return nil, err
				}
				s.checkers[dynamicKey] = c
				return c, nil
			}
		}

		return nil, fmt.Errorf("no configuration or address provided for gRPC checker")

	default:
		return nil, status.Errorf(codes.NotFound, "no config or dynamic checker for: %s", serviceName)
	}
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
