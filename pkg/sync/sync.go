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
	"log"
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

	s.initializeIntegrations(ctx)

	// Set the PollFunc to our Sync method
	s.poller.PollFunc = s.Sync

	return s, nil
}

// defaultIntegrationRegistry provides the default set of integration factories.
func defaultIntegrationRegistry() map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		integrationTypeArmis: func(ctx context.Context, config models.SourceConfig) Integration {
			return integrations.NewArmisIntegration(ctx, config, nil, nil, "")
		},
		integrationTypeNetbox: func(ctx context.Context, config models.SourceConfig) Integration {
			return integrations.NewNetboxIntegration(ctx, config, nil, nil, "")
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

	return New(ctx, config, kvClient, client, defaultIntegrationRegistry(), nil)
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

/*
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

*/

// createIntegration constructs an integration instance based on source type.
func (*SyncPoller) createIntegration(ctx context.Context, src models.SourceConfig, factory IntegrationFactory) Integration {
	return factory(ctx, src)
}

/*
func (s *SyncPoller) createIntegration(ctx context.Context, src models.SourceConfig, factory IntegrationFactory) Integration {
	if src.Type != integrationTypeArmis {
		return factory(ctx, src)
	}

	serverName := "default-agent"
	if s.config.Security != nil && s.config.Security.ServerName != "" {
		serverName = s.config.Security.ServerName
	}

	switch src.Type {
	case integrationTypeArmis:
		return integrations.NewArmisIntegration(ctx, src, s.kvClient, s.grpcClient.GetConnection(), serverName)
	case integrationTypeNetbox:
		return integrations.NewNetboxIntegration(ctx, src, s.kvClient, s.grpcClient.GetConnection(), serverName)
	default:
		return factory(ctx, src)
	}
}

*/

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
