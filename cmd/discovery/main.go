package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/carverauto/serviceradar/pkg/discovery"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
	discoverypb "github.com/carverauto/serviceradar/proto/discovery"

	googlegrpc "google.golang.org/grpc"
)

// Config holds the command-line configuration options.
type Config struct {
	configFile   string
	listenAddr   string
	securityMode string
	certDir      string
}

// parseFlags parses command-line flags and returns a Config.
func parseFlags() Config {
	config := Config{}

	flag.StringVar(&config.configFile, "config", "/etc/serviceradar/discovery-checker.json", "Path to this discovery checker's config file")
	flag.StringVar(&config.listenAddr, "listen", ":50056", "Address for this discovery checker to listen on")
	flag.StringVar(&config.securityMode, "security", "none", "Security mode for this checker (none, tls, mtls)")
	flag.StringVar(&config.certDir, "cert-dir", "/etc/serviceradar/certs/discovery-checker", "Directory for this checker's certificates")
	flag.Parse()

	return config
}

func main() {
	config := parseFlags()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan

		log.Printf("Received signal %v, initiating shutdown for discovery checker", sig)

		cancel()
	}()

	log.Printf("Starting ServiceRadar Discovery Checker Plugin...")

	// Load discovery configuration
	discoveryEngineConfig, err := loadDiscoveryConfig(config)
	if err != nil {
		log.Printf("Failed to load discovery checker configuration: %v", err)

		return // Deferred cancel() will run
	}

	// Initialize the discovery engine
	var publisher discovery.Publisher
	engine, err := discovery.NewSnmpDiscoveryEngine(discoveryEngineConfig, publisher)
	if err != nil {
		log.Printf("Failed to initialize discovery engine: %v", err)

		return // Deferred cancel() will run
	}

	// Create the gRPC service
	grpcDiscoveryService := discovery.NewGRPCDiscoveryService(engine)

	// Configure server options
	serverOptions := &lifecycle.ServerOptions{
		ListenAddr:  config.listenAddr,
		ServiceName: "discovery_checker",
		Service:     engine,
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{
			func(server *googlegrpc.Server) error {
				discoverypb.RegisterDiscoveryServiceServer(server, grpcDiscoveryService)
				log.Printf("Registered DiscoveryServiceServer for the discovery checker.")
				return nil
			},
		},
		EnableHealthCheck: true,
		Security:          createCheckerSecurityConfig(config),
	}

	// Run the server
	if err := lifecycle.RunServer(ctx, serverOptions); err != nil {
		log.Printf("Discovery checker server error: %v", err)

		return // Deferred cancel() will run
	}

	log.Println("ServiceRadar Discovery Checker Plugin stopped")
}

// loadDiscoveryConfig loads the configuration for the discovery engine.
func loadDiscoveryConfig(config Config) (*discovery.Config, error) {
	if config.configFile == "" {
		log.Println("No config file specified for discovery checker, using default in-memory config.")
		return &discovery.Config{
			Workers:         10,
			Timeout:         30 * time.Second,
			Retries:         3,
			MaxActiveJobs:   10,
			ResultRetention: 1 * time.Hour,
			DefaultCredentials: discovery.SNMPCredentials{
				Version:   discovery.SNMPVersion2c,
				Community: "public",
			},
			StreamConfig: discovery.StreamConfig{},
			OIDs: map[discovery.DiscoveryType][]string{
				discovery.DiscoveryTypeBasic: {
					".1.3.6.1.2.1.1.1.0", // sysDescr
					".1.3.6.1.2.1.1.5.0", // sysName
				},
			},
		}, nil
	}

	discoveryConfig, err := discovery.LoadConfigFromFile(config.configFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load discovery checker config from file '%s': %w", config.configFile, err)
	}

	log.Printf("Successfully loaded discovery checker config from %s", config.configFile)

	return discoveryConfig, nil
}

// createCheckerSecurityConfig creates a security configuration
func createCheckerSecurityConfig(config Config) *models.SecurityConfig {
	return &models.SecurityConfig{
		Mode:       models.SecurityMode(config.securityMode),
		CertDir:    config.certDir,
		Role:       models.RoleChecker,
		ServerName: "discovery.checker.local",
		TLS: models.TLSConfig{
			CertFile:     "server.crt",
			KeyFile:      "server.key",
			CAFile:       "ca.crt",
			ClientCAFile: "ca.crt",
		},
	}
}
