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
	"strings"
	"sync"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	configkv "github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/pkg/models"
)

type NATSStore struct {
	nc             *nats.Conn
	ctx            context.Context
	natsURL        string
	security       *models.SecurityConfig
	bucket         string
	defaultDomain  string
	bucketHistory  uint32
	bucketTTL      time.Duration
	bucketMaxBytes int64
	jsByDomain     map[string]jetstream.JetStream
	kvByDomain     map[string]jetstream.KeyValue
	mu             sync.Mutex
	connectFn      func() (*nats.Conn, error)
}

func NewNATSStore(ctx context.Context, cfg *Config) (*NATSStore, error) {
	if cfg == nil {
		return nil, errNilConfig
	}

	store := &NATSStore{
		ctx:            ctx,
		natsURL:        cfg.NATSURL,
		security:       cloneSecurityConfig(cfg.Security),
		bucket:         cfg.Bucket,
		defaultDomain:  cfg.Domain,
		bucketHistory:  cfg.BucketHistory,
		bucketTTL:      time.Duration(cfg.BucketTTL),
		bucketMaxBytes: cfg.BucketMaxBytes,
		jsByDomain:     make(map[string]jetstream.JetStream),
		kvByDomain:     make(map[string]jetstream.KeyValue),
	}

	if store.bucketHistory == 0 {
		store.bucketHistory = 1
	}
	if store.bucketTTL < 0 {
		store.bucketTTL = 0
	}
	if store.bucketMaxBytes < 0 {
		store.bucketMaxBytes = 0
	}

	store.connectFn = store.connect

	// Warm the default domain so consumers fail fast on misconfiguration.
	if _, err := store.getKVForDomain(ctx, cfg.Domain); err != nil {
		if cerr := store.Close(); cerr != nil {
			log.Printf("failed to close NATS store after init error: %v", cerr)
		}
		return nil, err
	}

	return store, nil
}

func cloneSecurityConfig(sec *models.SecurityConfig) *models.SecurityConfig {
	if sec == nil {
		return nil
	}

	copy := *sec
	copy.TLS = sec.TLS

	return &copy
}

func (n *NATSStore) connect() (*nats.Conn, error) {
	if n.security == nil {
		return nil, errMTLSRequired
	}

	tlsConfig, err := getTLSConfig(n.security)
	if err != nil {
		return nil, fmt.Errorf("failed to configure TLS: %w", err)
	}

	opts := []nats.Option{
		nats.Secure(tlsConfig),
		nats.RootCAs(n.security.TLS.CAFile),
		nats.ClientCert(n.security.TLS.CertFile, n.security.TLS.KeyFile),
		nats.MaxReconnects(-1),
		nats.RetryOnFailedConnect(true),
		nats.ReconnectWait(2 * time.Second),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			if err != nil {
				log.Printf("Disconnected from NATS: %v", err)
			} else {
				log.Printf("Disconnected from NATS")
			}
		}),
		nats.ReconnectHandler(func(nc *nats.Conn) {
			log.Printf("Reconnected to NATS: %s", nc.ConnectedUrl())
		}),
		nats.ClosedHandler(func(nc *nats.Conn) {
			log.Printf("NATS connection closed (status=%s)", nc.Status())
		}),
		nats.ErrorHandler(func(_ *nats.Conn, _ *nats.Subscription, err error) {
			if err != nil {
				log.Printf("NATS error: %v", err)
			}
		}),
	}

	conn, err := nats.Connect(n.natsURL, opts...)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS: %w", err)
	}

	return conn, nil
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

func (n *NATSStore) Get(ctx context.Context, key string) ([]byte, bool, error) {
	entry, err := n.GetEntry(ctx, key)
	if err != nil {
		return nil, false, err
	}

	return entry.Value, entry.Found, nil
}

// GetEntry retrieves the value and revision metadata for a given key.
func (n *NATSStore) GetEntry(ctx context.Context, key string) (Entry, error) {
	domain, realKey := n.extractDomain(key)
	kv, err := n.getKVForDomain(ctx, domain)
	if err != nil {
		return Entry{}, err
	}

	entry, err := kv.Get(ctx, realKey)
	if errors.Is(err, jetstream.ErrKeyNotFound) {
		return Entry{Found: false}, nil
	}
	if err != nil {
		return Entry{}, fmt.Errorf("failed to get key %s: %w", realKey, err)
	}

	return Entry{
		Value:    entry.Value(),
		Revision: entry.Revision(),
		Found:    true,
	}, nil
}

// Put stores a key-value pair in the NATS key-value store. It accepts a context, key, value, and TTL.
// The TTL is not used in this implementation, as it is handled at the bucket level.
func (n *NATSStore) Put(ctx context.Context, key string, value []byte, _ time.Duration) error {
	domain, realKey := n.extractDomain(key)
	kv, err := n.getKVForDomain(ctx, domain)
	if err != nil {
		return err
	}
	_, err = kv.Put(ctx, realKey, value)
	if err != nil {
		return fmt.Errorf("failed to put key %s: %w", realKey, err)
	}

	return nil
}

// PutIfAbsent stores a key-value pair only if it doesn't already exist.
func (n *NATSStore) PutIfAbsent(ctx context.Context, key string, value []byte, _ time.Duration) error {
	domain, realKey := n.extractDomain(key)
	kv, err := n.getKVForDomain(ctx, domain)
	if err != nil {
		return err
	}
	_, err = kv.Create(ctx, realKey, value)
	if err != nil {
		if errors.Is(err, jetstream.ErrKeyExists) {
			return fmt.Errorf("key %s already exists: %w", realKey, ErrKeyExists)
		}
		return fmt.Errorf("failed to create key %s: %w", realKey, err)
	}

	return nil
}

// PutMany stores multiple key/value pairs. TTL is ignored in this implementation.
func (n *NATSStore) PutMany(ctx context.Context, entries []KeyValueEntry, _ time.Duration) error {
	for _, e := range entries {
		domain, realKey := n.extractDomain(e.Key)
		kv, err := n.getKVForDomain(ctx, domain)
		if err != nil {
			return err
		}
		if _, err := kv.Put(ctx, realKey, e.Value); err != nil {
			return fmt.Errorf("failed to put key %s: %w", realKey, err)
		}
	}

	return nil
}

// Update performs a compare-and-swap using JetStream revisions.
func (n *NATSStore) Update(ctx context.Context, key string, value []byte, revision uint64, _ time.Duration) (uint64, error) {
	domain, realKey := n.extractDomain(key)
	kv, err := n.getKVForDomain(ctx, domain)
	if err != nil {
		return 0, err
	}

	newRevision, err := kv.Update(ctx, realKey, value, revision)
	if err != nil {
		if errors.Is(err, jetstream.ErrKeyExists) {
			return 0, fmt.Errorf("cas conflict on key %s: %w", realKey, ErrCASMismatch)
		}
		return 0, fmt.Errorf("failed to update key %s: %w", realKey, err)
	}

	return newRevision, nil
}

func (n *NATSStore) Delete(ctx context.Context, key string) error {
	domain, realKey := n.extractDomain(key)
	kv, err := n.getKVForDomain(ctx, domain)
	if err != nil {
		return err
	}
	err = kv.Delete(ctx, realKey)
	if err != nil && !errors.Is(err, jetstream.ErrKeyNotFound) {
		return fmt.Errorf("failed to delete key %s: %w", realKey, err)
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
// Returns true if context was canceled, false if watcher closed unexpectedly and we should retry.
func (n *NATSStore) attemptWatch(ctx context.Context, key string, ch chan<- []byte, backoff *time.Duration) bool {
	const initialBackoff = 1 * time.Second

	domain, realKey := n.extractDomain(key)
	kv, err := n.getKVForDomain(ctx, domain)
	if err != nil {
		log.Printf("Failed to get KV for domain %s: %v", domain, err)
		return false
	}

	watcher, err := kv.Watch(ctx, realKey /* you can add options like jetstream.UpdatesOnly() here if desired */)
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

	*backoff = initialBackoff // reset backoff on success

	for {
		select {
		case <-ctx.Done():
			return true
		case <-n.ctx.Done():
			return true
		case upd, ok := <-watcher.Updates():
			if !ok {
				// Channel actually closed -> retry
				log.Printf("Watcher updates channel closed for key %s, will reconnect", key)

				return false
			}

			if upd == nil {
				// This is NORMAL: end-of-initial-snapshot sentinel. Keep watching.
				// See: "Watch will send a nil entry when it has received all initial values."
				// https://pkg.go.dev/github.com/nats-io/nats.go/jetstream
				log.Printf("Initial snapshot complete for key %s", key)

				continue
			}

			if !n.sendUpdate(ctx, ch, upd.Value()) {
				return true // context canceled during send
			}

			log.Printf("Successfully sent watch update for key %s (length: %d bytes)", key, len(upd.Value()))
		}
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
	n.mu.Lock()
	defer n.mu.Unlock()

	if n.nc != nil {
		n.nc.Close()
		n.nc = nil
	}

	n.jsByDomain = nil
	n.kvByDomain = nil

	return nil
}

// Ensure NATSStore implements both interfaces.
var _ configkv.KVStore = (*NATSStore)(nil)
var _ KVStore = (*NATSStore)(nil)

// Helpers for domain-aware keys.
// keys may be provided as: "domains/<domain>/<realKey>" to route to a JS domain.
func (n *NATSStore) extractDomain(key string) (string, string) {
	const p = "domains/"
	if strings.HasPrefix(key, p) {
		rest := key[len(p):]
		if idx := strings.IndexByte(rest, '/'); idx > 0 {
			return rest[:idx], rest[idx+1:]
		}
	}
	return n.defaultDomain, key
}

func (n *NATSStore) getKVForDomain(ctx context.Context, domain string) (jetstream.KeyValue, error) {
	n.mu.Lock()
	defer n.mu.Unlock()

	if kv, ok := n.kvByDomain[domain]; ok && kv != nil {
		if n.connectFn == nil {
			return kv, nil
		}

		if !n.connectionNeedsRefreshLocked() {
			return kv, nil
		}

		n.resetConnectionLocked()
	}

	if n.connectFn == nil {
		return nil, errNATSNotConfigured
	}

	if n.connectionNeedsRefreshLocked() {
		if err := n.reconnectLocked(); err != nil {
			return nil, err
		}
	}

	return n.ensureDomainLocked(ctx, domain)
}

func (n *NATSStore) connectionNeedsRefreshLocked() bool {
	if n.nc == nil {
		return true
	}

	status := n.nc.Status()
	switch status {
	case nats.CONNECTED:
		return false
	case nats.DISCONNECTED, nats.CLOSED, nats.RECONNECTING, nats.CONNECTING, nats.DRAINING_SUBS, nats.DRAINING_PUBS:
		return true
	default:
		return true
	}
}

func (n *NATSStore) reconnectLocked() error {
	if n.connectFn == nil {
		return errNATSReconnectDisabled
	}

	conn, err := n.connectFn()
	if err != nil {
		return fmt.Errorf("failed to connect to NATS: %w", err)
	}

	if n.nc != nil {
		n.nc.Close()
	}

	n.nc = conn
	n.jsByDomain = make(map[string]jetstream.JetStream)
	n.kvByDomain = make(map[string]jetstream.KeyValue)

	return nil
}

func (n *NATSStore) ensureDomainLocked(ctx context.Context, domain string) (jetstream.KeyValue, error) {
	if kv, ok := n.kvByDomain[domain]; ok && kv != nil {
		return kv, nil
	}

	js, ok := n.jsByDomain[domain]
	if !ok || js == nil {
		var err error
		if domain == "" {
			js, err = jetstream.New(n.nc)
		} else {
			js, err = jetstream.NewWithDomain(n.nc, domain)
		}
		if err != nil {
			return nil, fmt.Errorf("jetstream init failed for domain %q: %w", domain, err)
		}
		n.jsByDomain[domain] = js
	}

	kv, err := js.KeyValue(ctx, n.bucket)
	if err != nil {
		cfg := jetstream.KeyValueConfig{
			Bucket:  n.bucket,
			History: uint8(n.bucketHistory),
		}
		if n.bucketTTL > 0 {
			cfg.TTL = n.bucketTTL
		}
		if n.bucketMaxBytes > 0 {
			cfg.MaxBytes = n.bucketMaxBytes
		}

		kv, err = js.CreateKeyValue(ctx, cfg)
		if err != nil {
			return nil, fmt.Errorf("kv bucket init failed for domain %q: %w", domain, err)
		}
	}

	n.kvByDomain[domain] = kv

	return kv, nil
}

func (n *NATSStore) resetConnectionLocked() {
	if n.nc != nil {
		n.nc.Close()
	}

	n.nc = nil
	n.jsByDomain = make(map[string]jetstream.JetStream)
	n.kvByDomain = make(map[string]jetstream.KeyValue)
}
