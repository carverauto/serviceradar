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

type NATSStore struct {
	nc  *nats.Conn
	kv  jetstream.KeyValue
	ctx context.Context
}

func NewNATSStore(ctx context.Context, cfg *Config) (*NATSStore, error) {
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid configuration: %w", err)
	}

	tlsConfig, err := getTLSConfig(cfg.Security)
	if err != nil {
		return nil, fmt.Errorf("failed to configure TLS: %w", err)
	}

	nc, err := nats.Connect(cfg.NATSURL,
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

	return &NATSStore{
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

func (n *NATSStore) Get(ctx context.Context, key string) (value []byte, found bool, err error) {
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
func (n *NATSStore) Put(ctx context.Context, key string, value []byte, _ time.Duration) error {
	_, err := n.kv.Put(ctx, key, value) // TTL handled at bucket level in this implementation
	if err != nil {
		return fmt.Errorf("failed to put key %s: %w", key, err)
	}

	return nil
}

// PutMany stores multiple key/value pairs. TTL is ignored in this implementation.
func (n *NATSStore) PutMany(ctx context.Context, entries []KeyValueEntry, _ time.Duration) error {
	for _, e := range entries {
		if _, err := n.kv.Put(ctx, e.Key, e.Value); err != nil {
			return fmt.Errorf("failed to put key %s: %w", e.Key, err)
		}
	}

	return nil
}

func (n *NATSStore) Delete(ctx context.Context, key string) error {
	err := n.kv.Delete(ctx, key)
	if err != nil && !errors.Is(err, jetstream.ErrKeyNotFound) {
		return fmt.Errorf("failed to delete key %s: %w", key, err)
	}

	return nil
}

func (n *NATSStore) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	ch := make(chan []byte, 1)

	go n.handleWatchWithReconnect(ctx, key, ch)

	return ch, nil
}

// handleWatchWithReconnect handles watch operations with automatic reconnection
func (n *NATSStore) handleWatchWithReconnect(ctx context.Context, key string, ch chan<- []byte) {
	defer close(ch)

	const (
		initialBackoff = 1 * time.Second
		maxBackoff     = 30 * time.Second
		backoffFactor  = 2.0
	)

	backoff := initialBackoff

	for {
		select {
		case <-ctx.Done():
			log.Printf("Context canceled, stopping watch for key %s", key)
			return
		case <-n.ctx.Done():
			log.Printf("NATSStore context canceled, stopping watch for key %s", key)
			return
		default:
			// Try to establish watch
			if n.attemptWatch(ctx, key, ch, &backoff) {
				return // Context was canceled
			}

			// If we reach here, the watcher closed unexpectedly, wait before retry
			log.Printf("Watch for key %s closed unexpectedly, retrying after %v", key, backoff)

			select {
			case <-ctx.Done():
				return
			case <-n.ctx.Done():
				return
			case <-time.After(backoff):
				// Increase backoff for next attempt
				if backoff < maxBackoff {
					backoff = time.Duration(float64(backoff) * backoffFactor)
					if backoff > maxBackoff {
						backoff = maxBackoff
					}
				}
			}
		}
	}
}

// attemptWatch attempts to establish a single watch session
// Returns true if context was canceled, false if watcher closed unexpectedly
func (n *NATSStore) attemptWatch(ctx context.Context, key string, ch chan<- []byte, backoff *time.Duration) bool {
	const initialBackoff = 1 * time.Second
	watcher, err := n.kv.Watch(ctx, key)
	if err != nil {
		log.Printf("Failed to create watch for key %s: %v", key, err)
		return false // Will retry
	}

	defer func() {
		if err := watcher.Stop(); err != nil {
			log.Printf("Failed to stop watcher for key %s: %v", key, err)
		}
	}()

	log.Printf("Established watch for key %s", key)
	*backoff = initialBackoff // Reset backoff on successful connection

	for {
		update := n.waitForUpdate(ctx, watcher)
		if update == nil {
			// Check if this was due to context cancellation
			select {
			case <-ctx.Done():
				return true // Context canceled
			case <-n.ctx.Done():
				return true // Store context canceled
			default:
				log.Printf("Watch update channel closed for key %s, will reconnect", key)
				return false // Will retry
			}
		}

		if !n.sendUpdate(ctx, ch, update.Value()) {
			return true // Context canceled during send
		}

		log.Printf("Successfully sent watch update for key %s (length: %d bytes)", key, len(update.Value()))
	}
}

func (n *NATSStore) handleWatchUpdates(ctx context.Context, key string, watcher jetstream.KeyWatcher, ch chan<- []byte) {
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

func (n *NATSStore) waitForUpdate(ctx context.Context, watcher jetstream.KeyWatcher) jetstream.KeyValueEntry {
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

func (n *NATSStore) sendUpdate(ctx context.Context, ch chan<- []byte, value []byte) bool {
	select {
	case ch <- value:
		return true
	case <-ctx.Done():
		return false
	case <-n.ctx.Done():
		return false
	}
}

func (n *NATSStore) Close() error {
	n.nc.Close()

	return nil
}

// Ensure NATSStore implements both interfaces.
var _ configkv.KVStore = (*NATSStore)(nil)
var _ KVStore = (*NATSStore)(nil)
