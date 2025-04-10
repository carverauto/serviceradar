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
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sync"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/pkg/sync/integrations"
	"github.com/carverauto/serviceradar/proto"
)

const (
	integrationTypeArmis  = "armis"
	integrationTypeNetbox = "netbox"
)

// SyncPoller manages synchronization using poller.Poller.
type SyncPoller struct {
	poller     *poller.Poller
	config     Config
	kvClient   KVClient
	grpcClient GRPCClient
	sources    map[string]Integration
	registry   map[string]IntegrationFactory
}

// New creates a new SyncPoller with explicit dependencies, leveraging poller.Poller.
func New(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	grpcClient GRPCClient,
	registry map[string]IntegrationFactory,
	clock poller.Clock,
) (*SyncPoller, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	// Create a minimal poller config; no core or agents needed for syncing
	pollerConfig := &poller.Config{
		PollInterval: config.PollInterval,
		Security:     config.Security,
		Agents:       make(map[string]poller.AgentConfig), // Empty agents map
	}

	if clock == nil {
		clock = poller.Clock(realClock{})
	}

	p, err := poller.New(ctx, pollerConfig, clock)
	if err != nil {
		return nil, err
	}

	s := &SyncPoller{
		poller:     p,
		config:     *config,
		kvClient:   kvClient,
		grpcClient: grpcClient,
		sources:    make(map[string]Integration),
		registry:   registry,
	}

	// Load initial config from filesystem if specified
	if config.ConfigFile != "" {
		if err := s.loadInitialConfig(ctx); err != nil {
			log.Printf("Failed to load initial config: %v", err)

			return nil, err
		}
	}

	s.initializeIntegrations(ctx)

	// Set the PollFunc to our Sync method
	s.poller.PollFunc = s.Sync

	return s, nil
}

// defaultIntegrationRegistry provides the default set of integration factories.
func defaultIntegrationRegistry(
	kvClient proto.KVServiceClient,
	grpcClient GRPCClient,
	serverName string) map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		integrationTypeArmis: func(ctx context.Context, config models.SourceConfig) Integration {
			return integrations.NewArmisIntegration(ctx, config, kvClient, grpcClient.GetConnection(), serverName)
		},
		integrationTypeNetbox: func(ctx context.Context, config models.SourceConfig) Integration {
			integ := integrations.NewNetboxIntegration(ctx, config, kvClient, grpcClient.GetConnection(), serverName)
			// Allow override via config
			if val, ok := config.Credentials["expand_subnets"]; ok && val == "true" {
				integ.ExpandSubnets = true
			}
			return integ
		},
	}
}

// NewWithGRPC sets up the gRPC client for production use with default integrations.
func NewWithGRPC(ctx context.Context, config *Config) (*SyncPoller, error) {
	clientCfg := grpc.ClientConfig{
		Address:    config.KVAddress,
		MaxRetries: 3,
	}

	if config.Security != nil {
		provider, err := grpc.NewSecurityProvider(ctx, config.Security)
		if err != nil {
			return nil, err
		}

		clientCfg.SecurityProvider = provider
	}

	client, err := grpc.NewClient(ctx, clientCfg)
	if err != nil {
		return nil, err
	}

	kvClient := proto.NewKVServiceClient(client.GetConnection())

	// Use config.Security.ServerName if available, otherwise default to empty string
	serverName := ""
	if config.Security != nil {
		serverName = config.Security.ServerName
	}

	return New(ctx, config, kvClient, client, defaultIntegrationRegistry(kvClient, client, serverName), nil)
}

func (s *SyncPoller) initializeIntegrations(ctx context.Context) {
	for name, src := range s.config.Sources {
		factory, ok := s.registry[src.Type]
		if !ok {
			log.Printf("Unknown source type: %s", src.Type)

			continue
		}

		s.sources[name] = s.createIntegration(ctx, src, factory)
	}
}

// createIntegration constructs an integration instance based on source type.
func (*SyncPoller) createIntegration(ctx context.Context, src models.SourceConfig, factory IntegrationFactory) Integration {
	return factory(ctx, src)
}

// Start delegates to poller.Poller.Start, using PollFunc for syncing.
func (s *SyncPoller) Start(ctx context.Context) error {
	return s.poller.Start(ctx)
}

// Stop delegates to poller.Poller.Stop and closes the gRPC client.
func (s *SyncPoller) Stop(ctx context.Context) error {
	err := s.poller.Stop(ctx)

	if s.grpcClient != nil {
		if closeErr := s.grpcClient.Close(); closeErr != nil {
			log.Printf("Failed to close gRPC client: %v", closeErr)

			if err == nil {
				err = closeErr
			}
		}
	}

	return err
}

// Sync performs the synchronization of data from sources to KV.
func (s *SyncPoller) Sync(ctx context.Context) error {
	var wg sync.WaitGroup

	errChan := make(chan error, len(s.sources))

	for name, integration := range s.sources {
		wg.Add(1)

		go func(name string, integ Integration) {
			defer wg.Done()

			data, err := integ.Fetch(ctx)

			if err != nil {
				errChan <- err

				return
			}

			s.writeToKV(ctx, name, data)
		}(name, integration)
	}

	wg.Wait()
	close(errChan)

	for err := range errChan {
		if err != nil {
			return err
		}
	}

	return nil
}

func (s *SyncPoller) writeToKV(ctx context.Context, sourceName string, data map[string][]byte) {
	prefix := s.config.Sources[sourceName].Prefix
	for key, value := range data {
		fullKey := prefix + key

		_, err := s.kvClient.Put(ctx, &proto.PutRequest{
			Key:   fullKey,
			Value: value,
		})

		if err != nil {
			log.Printf("Failed to write %s to KV: %v", fullKey, err)
		}
	}
}

// NewDefault provides a production-ready constructor with default settings.
func NewDefault(ctx context.Context, config *Config) (*SyncPoller, error) {
	return NewWithGRPC(ctx, config)
}

// loadInitialConfig reads the config file and populates the KV store.
func (s *SyncPoller) loadInitialConfig(ctx context.Context) error {
	data, err := os.ReadFile(s.config.ConfigFile)
	if err != nil {
		return fmt.Errorf("failed to read config file %s: %w", s.config.ConfigFile, err)
	}

	var initialData map[string]interface{}

	if err := json.Unmarshal(data, &initialData); err != nil {
		return fmt.Errorf("failed to unmarshal config file %s: %w", s.config.ConfigFile, err)
	}

	for key, value := range initialData {
		valueBytes, err := json.Marshal(value)
		if err != nil {
			log.Printf("Failed to marshal value for key %s: %v", key, err)

			continue
		}

		_, err = s.kvClient.Put(ctx, &proto.PutRequest{
			Key:   key,
			Value: valueBytes,
		})
		if err != nil {
			log.Printf("Failed to write initial key %s to KV: %v", key, err)
		}
	}

	return nil
}
