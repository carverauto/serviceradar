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
	"sync"

	ggrpc "github.com/carverauto/serviceradar/pkg/grpc"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/natsutil"
	"github.com/carverauto/serviceradar/pkg/poller"
	"github.com/carverauto/serviceradar/pkg/sync/integrations"
	"github.com/carverauto/serviceradar/proto"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	grpcstd "google.golang.org/grpc"
)

const (
	integrationTypeArmis  = "armis"
	integrationTypeNetbox = "netbox"
)

// SyncPoller manages synchronization using poller.Poller.
type SyncPoller struct {
	poller        *poller.Poller
	config        Config
	kvClient      KVClient
	js            jetstream.JetStream
	natsConn      *nats.Conn
	subjectPrefix string
	sources       map[string]Integration
	registry      map[string]IntegrationFactory
	grpcClient    GRPCClient
}

// New creates a new SyncPoller with explicit dependencies, leveraging poller.Poller.
func New(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	js jetstream.JetStream,
	nc *nats.Conn,
	registry map[string]IntegrationFactory,
	grpcClient GRPCClient,
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
		poller:        p,
		config:        *config,
		kvClient:      kvClient,
		js:            js,
		natsConn:      nc,
		subjectPrefix: config.Subject,
		sources:       make(map[string]Integration),
		registry:      registry,
		grpcClient:    grpcClient,
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
	serverName string,
) map[string]IntegrationFactory {
	return map[string]IntegrationFactory{
		integrationTypeArmis: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpcstd.ClientConn
			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}
			return integrations.NewArmisIntegration(ctx, config, kvClient, conn, serverName)
		},
		integrationTypeNetbox: func(ctx context.Context, config *models.SourceConfig) Integration {
			var conn *grpcstd.ClientConn
			if grpcClient != nil {
				conn = grpcClient.GetConnection()
			}
			integ := integrations.NewNetboxIntegration(ctx, config, kvClient, conn, serverName)
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
	var natsOpts []nats.Option
	natsSec := config.Security
	if config.NATSSecurity != nil {
		natsSec = config.NATSSecurity
	}

	if natsSec != nil {
		tlsConf, err := natsutil.TLSConfig(natsSec)
		if err != nil {
			return nil, fmt.Errorf("failed to build NATS TLS config: %w", err)
		}

		natsOpts = append(natsOpts,
			nats.Secure(tlsConf),
			nats.RootCAs(natsSec.TLS.CAFile),
			nats.ClientCert(natsSec.TLS.CertFile, natsSec.TLS.KeyFile),
		)
	}

	nc, err := nats.Connect(config.NATSURL, natsOpts...)
	if err != nil {
		return nil, err
	}

	var js jetstream.JetStream
	if config.Domain != "" {
		js, err = jetstream.NewWithDomain(nc, config.Domain)
	} else {
		js, err = jetstream.New(nc)
	}
	if err != nil {
		nc.Close()
		return nil, err
	}

	if config.StreamName != "" {
		stream, err := js.Stream(ctx, config.StreamName)
		if err != nil {
			nc.Close()
			return nil, fmt.Errorf("failed to get stream %s: %w", config.StreamName, err)
		}
		if _, err = stream.Info(ctx); err != nil {
			nc.Close()
			return nil, fmt.Errorf("failed to get stream info: %w", err)
		}
	}

	var (
		kvClient   proto.KVServiceClient
		grpcClient GRPCClient
	)

	if config.KVAddress != "" {
		clientCfg := ggrpc.ClientConfig{
			Address:    config.KVAddress,
			MaxRetries: 3,
		}
		if config.Security != nil {
			provider, errSec := ggrpc.NewSecurityProvider(ctx, config.Security)
			if errSec != nil {
				nc.Close()
				return nil, fmt.Errorf("failed to create security provider: %w", errSec)
			}

			clientCfg.SecurityProvider = provider
		}

		c, errCli := ggrpc.NewClient(ctx, clientCfg)
		if errCli != nil {
			nc.Close()
			if clientCfg.SecurityProvider != nil {
				_ = clientCfg.SecurityProvider.Close()
			}
			return nil, fmt.Errorf("failed to create KV gRPC client: %w", errCli)
		}

		grpcClient = c
		kvClient = proto.NewKVServiceClient(c.GetConnection())
	}

	// Use config.Security.ServerName if available, otherwise default to empty string
	serverName := ""
	if config.Security != nil {
		serverName = config.Security.ServerName
	}

	syncer, err := New(ctx, config, kvClient, js, nc, defaultIntegrationRegistry(kvClient, grpcClient, serverName), grpcClient, nil)
	if err != nil {
		if grpcClient != nil {
			_ = grpcClient.Close()
		}
		nc.Close()
		return nil, err
	}

	return syncer, nil
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
func (*SyncPoller) createIntegration(ctx context.Context, src *models.SourceConfig, factory IntegrationFactory) Integration {
	return factory(ctx, src)
}

// Start delegates to poller.Poller.Start, using PollFunc for syncing.
func (s *SyncPoller) Start(ctx context.Context) error {
	return s.poller.Start(ctx)
}

// Stop delegates to poller.Poller.Stop and closes the gRPC client.
func (s *SyncPoller) Stop(ctx context.Context) error {
	err := s.poller.Stop(ctx)

	if s.natsConn != nil {
		s.natsConn.Close()
	}

	if s.grpcClient != nil {
		if errClose := s.grpcClient.Close(); errClose != nil {
			log.Printf("Error closing gRPC client: %v", errClose)
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

			data, devices, err := integ.Fetch(ctx)

			if err != nil {
				errChan <- err

				return
			}

			s.writeToKV(ctx, name, data)
			srcType := s.config.Sources[name].Type
			s.publishDevices(ctx, srcType, devices)
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

func (s *SyncPoller) publishDevices(ctx context.Context, sourceType string, devices []models.Device) {
	log.Printf("Publishing %d devices", len(devices))

	if s.js == nil || len(devices) == 0 {
		log.Printf("No JetStream publishing devices found")

		return
	}

	subject := s.subjectPrefix + "." + sourceType
	if s.config.Domain != "" {
		subject = s.config.Domain + "." + subject
	}

	log.Printf("Publishing to subject: %s", subject)

	for _, dev := range devices {
		dev.AgentID = s.config.AgentID
		dev.PollerID = s.config.PollerID
		payload, err := json.Marshal(dev)
		if err != nil {
			log.Printf("Failed to marshal device %s: %v", dev.DeviceID, err)
			continue
		}

		if _, err = s.js.Publish(ctx, subject, payload); err != nil {
			log.Printf("Failed to publish device %s: %v", dev.DeviceID, err)
		}
	}
}

// NewDefault provides a production-ready constructor with default settings.
func NewDefault(ctx context.Context, config *Config) (*SyncPoller, error) {
	return NewWithGRPC(ctx, config)
}
