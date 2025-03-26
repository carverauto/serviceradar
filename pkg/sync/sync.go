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
	"time"

	"github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/sync/integrations"
	"github.com/carverauto/serviceradar/proto"
)

// Syncer manages the synchronization of data from external sources to the KV store.
type Syncer struct {
	config     Config
	kvClient   KVClient
	grpcClient GRPCClient
	sources    map[string]Integration
	done       chan struct{}
	// mu                  sync.RWMutex
	clock               Clock
	integrationRegistry map[string]IntegrationFactory
}

// New creates a new Syncer with explicit dependencies.
func New(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	grpcClient GRPCClient,
	clock Clock,
	registry map[string]IntegrationFactory) (*Syncer, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	s := &Syncer{
		config:              *config,
		kvClient:            kvClient,
		grpcClient:          grpcClient,
		sources:             make(map[string]Integration),
		done:                make(chan struct{}),
		clock:               clock,
		integrationRegistry: registry,
	}

	s.initializeIntegrations(ctx)

	return s, nil
}

// defaultIntegrationRegistry provides the default set of integration factories.
func defaultIntegrationRegistry() map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		"armis": func(ctx context.Context, config models.SourceConfig) Integration {
			return integrations.NewArmisIntegration(ctx, config)
		},
		// Add more integrations here, e.g., "netbox": integrations.NewNetboxIntegration,
	}
}

// NewWithGRPC sets up the gRPC client for production use with default integrations.
func NewWithGRPC(ctx context.Context, config *Config, clock Clock) (*Syncer, error) {
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

	return New(ctx, config, kvClient, client, clock, defaultIntegrationRegistry())
}

func (s *Syncer) initializeIntegrations(ctx context.Context) {
	for name, src := range s.config.Sources {
		if factory, ok := s.integrationRegistry[src.Type]; ok {
			s.sources[name] = factory(ctx, src)
		} else {
			log.Printf("Unknown source type: %s", src.Type)
		}
	}
}

func (s *Syncer) Start(ctx context.Context) error {
	interval := time.Duration(s.config.PollInterval)

	ticker := s.clock.Ticker(interval)
	defer ticker.Stop()

	log.Printf("Starting syncer with interval %v", interval)

	// Initial sync
	if err := s.Sync(ctx); err != nil {
		log.Printf("Initial sync failed: %v", err)
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			return nil
		case <-ticker.Chan():
			if err := s.Sync(ctx); err != nil {
				log.Printf("Sync failed: %v", err)
			}
		}
	}
}

func (s *Syncer) Stop(_ context.Context) error {
	close(s.done)

	if s.grpcClient != nil {
		return s.grpcClient.Close()
	}

	return nil
}

func (s *Syncer) Sync(ctx context.Context) error {
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

func (s *Syncer) writeToKV(ctx context.Context, sourceName string, data map[string][]byte) {
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

// realClock implements Clock using the real time package.
type realClock struct{}

func (realClock) Now() time.Time {
	return time.Now()
}

func (realClock) Ticker(d time.Duration) Ticker {
	return &realTicker{t: time.NewTicker(d)}
}

type realTicker struct {
	t *time.Ticker
}

func (r *realTicker) Chan() <-chan time.Time {
	return r.t.C
}

func (r *realTicker) Stop() {
	r.t.Stop()
}

// NewDefault provides a production-ready constructor with default settings.
func NewDefault(ctx context.Context, config *Config) (*Syncer, error) {
	return NewWithGRPC(ctx, config, realClock{})
}
