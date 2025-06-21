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
	"errors"
	"fmt"
	"log"
	"strings"
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

// setupNATSConnection creates a NATS connection with the provided configuration.
func setupNATSConnection(config *Config) (*nats.Conn, error) {
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

	return nats.Connect(config.NATSURL, natsOpts...)
}

// setupJetStream creates a JetStream instance from a NATS connection.
func setupJetStream(ctx context.Context, nc *nats.Conn, config *Config) (jetstream.JetStream, error) {
	var (
		js  jetstream.JetStream
		err error
	)

	if config.Domain != "" {
		js, err = jetstream.NewWithDomain(nc, config.Domain)
	} else {
		js, err = jetstream.New(nc)
	}

	if err != nil {
		return nil, err
	}

	if config.StreamName != "" {
		stream, err := js.Stream(ctx, config.StreamName)

		if errors.Is(err, jetstream.ErrStreamNotFound) {
			subject := config.Subject + ".>"
			if config.Domain != "" {
				subject = config.Domain + "." + subject
			}

			sc := jetstream.StreamConfig{
				Name:     config.StreamName,
				Subjects: []string{subject},
			}

			stream, err = js.CreateOrUpdateStream(ctx, sc)
			if err != nil {
				return nil, fmt.Errorf("failed to create stream %s: %w", config.StreamName, err)
			}
		} else if err != nil {
			return nil, fmt.Errorf("failed to get stream %s: %w", config.StreamName, err)
		}

		if _, err = stream.Info(ctx); err != nil {
			return nil, fmt.Errorf("failed to get stream info: %w", err)
		}
	}

	return js, nil
}

// setupGRPCClient creates a gRPC client for KV service if an address is provided.
func setupGRPCClient(ctx context.Context, config *Config) (proto.KVServiceClient, GRPCClient, error) {
	var (
		kvClient   proto.KVServiceClient
		grpcClient GRPCClient
	)

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

	grpcClient = c
	kvClient = proto.NewKVServiceClient(c.GetConnection())

	return kvClient, grpcClient, nil
}

// getServerName extracts the server name from the security configuration.
func getServerName(config *Config) string {
	if config.Security != nil {
		return config.Security.ServerName
	}

	return ""
}

// cleanupResources closes the provided resources in case of an error.
func cleanupResources(nc *nats.Conn, grpcClient GRPCClient) {
	if grpcClient != nil {
		_ = grpcClient.Close()
	}

	if nc != nil {
		nc.Close()
	}
}

// createSyncer creates a new SyncPoller instance with the provided dependencies.
func createSyncer(
	ctx context.Context,
	config *Config,
	kvClient KVClient,
	js jetstream.JetStream,
	nc *nats.Conn,
	grpcClient GRPCClient,
) (*SyncPoller, error) {
	serverName := getServerName(config)

	return New(
		ctx,
		config,
		kvClient,
		js,
		nc,
		defaultIntegrationRegistry(kvClient, grpcClient, serverName),
		grpcClient,
		nil,
	)
}

// NewWithGRPC sets up the gRPC client for production use with default integrations.
func NewWithGRPC(ctx context.Context, config *Config) (*SyncPoller, error) {
	// Setup NATS connection
	nc, err := setupNATSConnection(config)
	if err != nil {
		return nil, err
	}

	// Setup JetStream
	js, err := setupJetStream(ctx, nc, config)
	if err != nil {
		cleanupResources(nc, nil)

		return nil, err
	}

	// Setup gRPC client
	kvClient, grpcClient, err := setupGRPCClient(ctx, config)
	if err != nil {
		cleanupResources(nc, nil)

		return nil, err
	}

	// Create syncer
	syncer, err := createSyncer(ctx, config, kvClient, js, nc, grpcClient)
	if err != nil {
		cleanupResources(nc, grpcClient)

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
func (s *SyncPoller) createIntegration(ctx context.Context, src *models.SourceConfig, factory IntegrationFactory) Integration {
	// Apply global defaults for AgentID and PollerID if not explicitly set
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

			data, events, err := integ.Fetch(ctx)
			if err != nil {
				errChan <- err
				return
			}

			s.writeToKV(ctx, name, data)
			s.publishEvents(ctx, name, events)
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
	prefix := strings.TrimSuffix(s.config.Sources[sourceName].Prefix, "/")

	for key, value := range data {
		fullKey := prefix + "/" + key

		if _, ip, ok := parseDeviceID(key); ok {
			srcCfg := s.config.Sources[sourceName]
			agentID := srcCfg.AgentID

			if agentID == "" {
				agentID = s.config.AgentID
			}

			pollerID := srcCfg.PollerID

			if pollerID == "" {
				pollerID = s.config.PollerID
			}

			fullKey = fmt.Sprintf("%s/%s/%s/%s", prefix, agentID, pollerID, ip)
		}

		_, err := s.kvClient.Put(ctx, &proto.PutRequest{
			Key:   fullKey,
			Value: value,
		})

		if err != nil {
			log.Printf("Failed to write %s to KV: %v", fullKey, err)
		}
	}
}

func (s *SyncPoller) publishEvents(ctx context.Context, sourceType string, events []*models.SweepResult) {
	log.Printf("Publishing %d discovery events", len(events))

	if s.js == nil || len(events) == 0 {
		log.Printf("No JetStream publishing events found")

		return
	}

	subject := s.subjectPrefix + "." + sourceType

	if s.config.Domain != "" {
		subject = s.config.Domain + "." + subject
	}

	log.Printf("Publishing to subject: %s", subject)

	for i := range events {
		payload, err := json.Marshal(events[i])
		if err != nil {
			log.Printf("Failed to marshal discovery event for %s: %v", events[i].IP, err)

			continue
		}

		if _, err = s.js.Publish(ctx, subject, payload); err != nil {
			log.Printf("Failed to publish discovery event for %s: %v", events[i].IP, err)
		}
	}
}

// parseDeviceID splits a device ID of the form "partition:ip" into its components.
// It returns partition, ip, and true on success. If the string does not contain a colon
// or the partition is empty, ok will be false.
func parseDeviceID(id string) (partition, ip string, ok bool) {
	idx := strings.Index(id, ":")
	if idx == -1 {
		return "", id, false
	}

	partition = id[:idx]
	ip = id[idx+1:]

	if partition == "" || ip == "" {
		return "", id, false
	}

	return partition, ip, true
}

// NewDefault provides a production-ready constructor with default settings.
func NewDefault(ctx context.Context, config *Config) (*SyncPoller, error) {
	return NewWithGRPC(ctx, config)
}
