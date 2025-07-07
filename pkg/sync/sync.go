/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package sync

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/pkg/sync/integrations"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

const (
	integrationTypeArmis  = "armis"
	integrationTypeNetbox = "netbox"
)

// New creates a new PollerService with explicit dependencies.
func New(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	registry map[string]IntegrationFactory,
	grpcClient GRPCClient,
	clock poller.Clock,
) (*PollerService, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	// Create a minimal poller config; no core or agents needed for the internal polling loop.
	pollerConfig := &poller.Config{
		PollInterval: config.PollInterval,
		Security:     config.Security,
	}

	if clock == nil {
		clock = poller.Clock(realClock{})
	}

	p, err := poller.New(ctx, pollerConfig, clock)
	if err != nil {
		return nil, err
	}

	s := &PollerService{
		poller:       p,
		config:       *config,
		kvClient:     kvClient,
		sources:      make(map[string]Integration),
		registry:     registry,
		grpcClient:   grpcClient,
		resultsCache: make([]*models.SweepResult, 0),
	}

	s.initializeIntegrations(ctx)

	// Set the internal poller's PollFunc to our Sync method.
	s.poller.PollFunc = s.Sync

	return s, nil
}

// Start starts the integration polling loop and the gRPC server.
func (s *PollerService) Start(ctx context.Context) error {
	/*
		lis, err := net.Listen("tcp", s.config.ListenAddr)
		if err != nil {
			return fmt.Errorf("failed to listen on %s: %w", s.config.ListenAddr, err)
		}

		var opts []grpc.ServerOption

		if s.config.Security != nil {
			// Use the SecurityProvider to get the correct server credentials
			provider, err := ggrpc.NewSecurityProvider(ctx, s.config.Security)
			if err != nil {
				return fmt.Errorf("failed to create security provider for gRPC server: %w", err)
			}

			serverCreds, err := provider.GetServerCredentials(ctx)
			if err != nil {
				return fmt.Errorf("failed to get server credentials: %w", err)
			}

			opts = append(opts, serverCreds)
		}

		s.grpcServer = grpc.NewServer(opts...)

		// Register this PollerService instance, which implements the AgentServiceServer interface.
		proto.RegisterAgentServiceServer(s.grpcServer, s)

		// Register a standard health check service.
		healthServer := health.NewServer()
		grpc_health_v1.RegisterHealthServer(s.grpcServer, healthServer)
		healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)

		log.Printf("Sync service (as gRPC Agent) listening at %v", lis.Addr())

		go func() {
			if err := s.grpcServer.Serve(lis); err != nil {
				log.Printf("gRPC server failed to serve: %v", err)
			}
		}()
	*/

	// Start the background polling of Armis/Netbox etc.
	return s.poller.Start(ctx)
}

// Stop stops the internal poller, the gRPC server, and closes the gRPC client connection.
func (s *PollerService) Stop(ctx context.Context) error {
	if s.grpcServer != nil {
		s.grpcServer.GracefulStop()
		log.Println("gRPC server stopped.")
	}

	err := s.poller.Stop(ctx)

	if s.grpcClient != nil {
		if errClose := s.grpcClient.Close(); errClose != nil {
			log.Printf("Error closing gRPC client: %v", errClose)
		}
	}

	return err
}

// Sync performs the synchronization of data from sources to the KV store and caches the results.
func (s *PollerService) Sync(ctx context.Context) error {
	var wg sync.WaitGroup

	errChan := make(chan error, len(s.sources))
	resultsChan := make(chan []*models.SweepResult, len(s.sources))

	for name, integration := range s.sources {
		wg.Add(1)

		go func(name string, integ Integration) {
			defer wg.Done()

			data, events, err := integ.Fetch(ctx)

			if err != nil {
				errChan <- fmt.Errorf("error fetching from source '%s': %w", name, err)
				return
			}

			s.writeToKV(ctx, name, data)

			if len(events) > 0 {
				resultsChan <- events
			}
		}(name, integration)
	}

	wg.Wait()

	close(errChan)
	close(resultsChan)

	var allEvents []*models.SweepResult

	for events := range resultsChan {
		allEvents = append(allEvents, events...)
	}

	s.resultsMu.Lock()
	s.resultsCache = allEvents
	s.resultsMu.Unlock()

	log.Printf("Updated discovery cache with %d devices", len(allEvents))

	// Log any errors that occurred during the sync cycle
	for err := range errChan {
		if err != nil {
			log.Printf("Warning: error during sync cycle: %v", err)
		}
	}

	return nil // Return nil to allow the poller to continue running even if one source fails
}

// NewDefault provides a production-ready constructor with default settings.
func NewDefault(ctx context.Context, config *Config) (*PollerService, error) {
	return NewWithGRPC(ctx, config)
}

// NewWithGRPC sets up the gRPC client for production use with default integrations.
func NewWithGRPC(ctx context.Context, config *Config) (*PollerService, error) {
	// Setup gRPC client for KV Store, if configured
	kvClient, grpcClient, err := setupGRPCClient(ctx, config)
	if err != nil {
		return nil, err
	}

	// Create syncer instance
	syncer, err := createSyncer(ctx, config, kvClient, grpcClient)
	if err != nil {
		if grpcClient != nil {
			_ = grpcClient.Close()
		}

		return nil, err
	}

	return syncer, nil
}

// createSyncer creates a new PollerService instance with the provided dependencies.
func createSyncer(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	grpcClient GRPCClient,
) (*PollerService, error) {
	serverName := getServerName(config)

	return New(
		ctx,
		config,
		kvClient,
		defaultIntegrationRegistry(kvClient, grpcClient, serverName),
		grpcClient,
		nil,
	)
}

func (s *PollerService) initializeIntegrations(ctx context.Context) {
	for name, src := range s.config.Sources {
		factory, ok := s.registry[src.Type]
		if !ok {
			log.Printf("Unknown source type: %s", src.Type)
			continue
		}

		s.sources[name] = s.createIntegration(ctx, src, factory)
	}
}

func (s *PollerService) createIntegration(ctx context.Context, src *models.SourceConfig, factory IntegrationFactory) Integration {
	cfgCopy := *src
	if cfgCopy.AgentID == "" {
		cfgCopy.AgentID = s.config.AgentID
	}

	if cfgCopy.PollerID == "" {
		cfgCopy.PollerID = s.config.PollerID
	}

	if cfgCopy.Partition == "" {
		cfgCopy.Partition = "default"
	}

	return factory(ctx, &cfgCopy)
}

func (s *PollerService) writeToKV(ctx context.Context, sourceName string, data map[string][]byte) {
	if s.kvClient == nil || len(data) == 0 {
		return
	}

	prefix := strings.TrimSuffix(s.config.Sources[sourceName].Prefix, "/")
	source := s.config.Sources[sourceName]
	entries := make([]*proto.KeyValueEntry, 0, len(data))

	for key, value := range data {
		var fullKey string

		// Check if key is in partition:ip format and transform it
		if strings.Contains(key, ":") {
			parts := strings.SplitN(key, ":", 2)
			if len(parts) == 2 {
				partition := parts[0]
				ip := parts[1]
				// Build key as prefix/agentID/pollerID/partition/ip
				fullKey = fmt.Sprintf("%s/%s/%s/%s/%s", prefix, source.AgentID, source.PollerID, partition, ip)
			} else {
				fullKey = prefix + "/" + key
			}
		} else {
			fullKey = prefix + "/" + key
		}

		entries = append(entries, &proto.KeyValueEntry{Key: fullKey, Value: value})
	}

	if len(entries) > 0 {
		if _, err := s.kvClient.PutMany(ctx, &proto.PutManyRequest{Entries: entries}); err != nil {
			log.Printf("Failed to write batch to KV for source %s: %v", sourceName, err)
		}
	}
}

func defaultIntegrationRegistry(
	kvClient proto.KVServiceClient,
	grpcClient GRPCClient,
	serverName string,
) map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		integrationTypeArmis: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			return integrations.NewArmisIntegration(ctx, config, kvClient, conn, serverName)
		},
		integrationTypeNetbox: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpc.ClientConn

			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}

			integ := integrations.NewNetboxIntegration(ctx, config, kvClient, conn, serverName)
			if val, ok := config.Credentials["expand_subnets"]; ok && val == "true" {
				integ.ExpandSubnets = true
			}

			return integ
		},
	}
}

func setupGRPCClient(ctx context.Context, config *Config) (proto.KVServiceClient, GRPCClient, error) {
	if config.KVAddress == "" {
		return nil, nil, nil
	}

	clientCfg := ggrpc.ClientConfig{
		Address:    config.KVAddress,
		MaxRetries: 3,
	}

	if config.Security != nil {
		provider, errSec := ggrpc.NewSecurityProvider(ctx, config.Security)
		if errSec != nil {
			return nil, nil, fmt.Errorf("failed to create security provider: %w", errSec)
		}

		clientCfg.SecurityProvider = provider
	}

	c, errCli := ggrpc.NewClient(ctx, clientCfg)
	if errCli != nil {
		if clientCfg.SecurityProvider != nil {
			_ = clientCfg.SecurityProvider.Close()
		}

		return nil, nil, fmt.Errorf("failed to create KV gRPC client: %w", errCli)
	}

	grpcClient := GRPCClient(c)
	kvClient := proto.NewKVServiceClient(c.GetConnection())

	return kvClient, grpcClient, nil
}

func getServerName(config *Config) string {
	if config.Security != nil {
		return config.Security.ServerName
	}

	return ""
}
