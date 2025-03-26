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

package kv

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	configkv "github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

type NatsStore struct {
	nc  *nats.Conn
	kv  jetstream.KeyValue
	ctx context.Context
}

func NewNatsStore(ctx context.Context, cfg *Config) (*NatsStore, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	tlsConfig, err := getTLSConfig(cfg.Security)
	if err != nil {
		return nil, fmt.Errorf("failed to configure TLS: %w", err)
	}

	nc, err := nats.Connect(cfg.NatsURL,
		nats.Secure(tlsConfig),
		nats.RootCAs(cfg.Security.TLS.CAFile),
		nats.ClientCert(cfg.Security.TLS.CertFile, cfg.Security.TLS.KeyFile),
		nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
			log.Printf("NATS error: %v", err)
		}),
		nats.ConnectHandler(func(nc *nats.Conn) {
			log.Printf("Connected to NATS: %s", nc.ConnectedUrl())
		}),
	)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()

		return nil, fmt.Errorf("failed to create JetStream context: %w", err)
	}

	config := jetstream.KeyValueConfig{
		Bucket: cfg.Bucket,
	}

	kv, err := js.CreateKeyValue(ctx, config)
	if err != nil {
		nc.Close()

		return nil, fmt.Errorf("failed to create KV bucket: %w", err)
	}

	return &NatsStore{
		nc:  nc,
		kv:  kv,
		ctx: ctx,
	}, nil
}

const (
	secModeMTLS = "mtls"
)

func getTLSConfig(sec *models.SecurityConfig) (*tls.Config, error) {
	if sec == nil || sec.Mode != secModeMTLS {
		return nil, errMTLSRequired
	}

	cert, err := tls.LoadX509KeyPair(sec.TLS.CertFile, sec.TLS.KeyFile)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToLoadClientCert, err)
	}

	caCert, err := os.ReadFile(sec.TLS.CAFile)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errFailedToReadCACert, err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, errFailedToParseCACert
	}

	return &tls.Config{
		Certificates:       []tls.Certificate{cert},
		RootCAs:            caCertPool,
		InsecureSkipVerify: false,
		ServerName:         sec.ServerName,
		MinVersion:         tls.VersionTLS13,
	}, nil
}

func (n *NatsStore) Get(ctx context.Context, key string) (value []byte, found bool, err error) {
	entry, err := n.kv.Get(ctx, key)
	if errors.Is(err, jetstream.ErrKeyNotFound) {
		return nil, false, nil
	}

	if err != nil {
		return nil, false, fmt.Errorf("failed to get key %s: %w", key, err)
	}

	return entry.Value(), true, nil
}

// Put stores a key-value pair in the NATS key-value store. It accepts a context, key, value, and TTL.
// The TTL is not used in this implementation, as it is handled at the bucket level.
func (n *NatsStore) Put(ctx context.Context, key string, value []byte, _ time.Duration) error {
	_, err := n.kv.Put(ctx, key, value) // TTL handled at bucket level in this implementation
	if err != nil {
		return fmt.Errorf("failed to put key %s: %w", key, err)
	}

	return nil
}

func (n *NatsStore) Delete(ctx context.Context, key string) error {
	err := n.kv.Delete(ctx, key)
	if err != nil && !errors.Is(err, jetstream.ErrKeyNotFound) {
		return fmt.Errorf("failed to delete key %s: %w", key, err)
	}

	return nil
}

func (n *NatsStore) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	watcher, err := n.kv.Watch(ctx, key)
	if err != nil {
		return nil, fmt.Errorf("failed to watch key %s: %w", key, err)
	}

	ch := make(chan []byte, 1)

	go n.handleWatchUpdates(ctx, key, watcher, ch)

	return ch, nil
}

func (n *NatsStore) handleWatchUpdates(ctx context.Context, key string, watcher jetstream.KeyWatcher, ch chan<- []byte) {
	defer func() {
		if err := watcher.Stop(); err != nil {
			log.Printf("failed to stop watcher for key %s: %v", key, err)
		}

		close(ch)
	}()

	for {
		update := n.waitForUpdate(ctx, watcher)
		if update == nil {
			return
		}

		if !n.sendUpdate(ctx, ch, update.Value()) {
			return
		}
	}
}

func (n *NatsStore) waitForUpdate(ctx context.Context, watcher jetstream.KeyWatcher) jetstream.KeyValueEntry {
	select {
	case <-ctx.Done():
		return nil
	case <-n.ctx.Done():
		return nil
	case update, ok := <-watcher.Updates():
		if !ok || update == nil {
			return nil
		}

		return update
	}
}

func (n *NatsStore) sendUpdate(ctx context.Context, ch chan<- []byte, value []byte) bool {
	select {
	case ch <- value:
		return true
	case <-ctx.Done():
		return false
	case <-n.ctx.Done():
		return false
	}
}

func (n *NatsStore) Close() error {
	n.nc.Close()

	return nil
}

// Ensure NatsStore implements both interfaces.
var _ configkv.KVStore = (*NatsStore)(nil)
var _ KVStore = (*NatsStore)(nil)
