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
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// NatsStore implements KVStore using NATS JetStream.
type NatsStore struct {
	nc  *nats.Conn
	kv  jetstream.KeyValue
	ctx context.Context
}

// NewNatsStore creates a new NATS JetStream KV store.
func NewNatsStore(ctx context.Context, natsURL, bucket string) (*NatsStore, error) {
	nc, err := nats.Connect(natsURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("failed to create JetStream context: %w", err)
	}

	kv, err := js.CreateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket: bucket,
	})
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

// Get retrieves a value from the KV store.
func (n *NatsStore) Get(ctx context.Context, key string) ([]byte, bool, error) {
	entry, err := n.kv.Get(ctx, key)
	if err == jetstream.ErrKeyNotFound {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("failed to get key %s: %w", key, err)
	}
	return entry.Value(), true, nil
}

// Put stores a value in the KV store.
func (n *NatsStore) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	opts := []jetstream.KeyValuePutOpt{}
	if ttl > 0 {
		opts = append(opts, jetstream.WithTTL(ttl))
	}
	_, err := n.kv.Put(ctx, key, value, opts...)
	if err != nil {
		return fmt.Errorf("failed to put key %s: %w", key, err)
	}
	return nil
}

// Delete removes a key from the KV store.
func (n *NatsStore) Delete(ctx context.Context, key string) error {
	err := n.kv.Delete(ctx, key)
	if err != nil && err != jetstream.ErrKeyNotFound {
		return fmt.Errorf("failed to delete key %s: %w", key, err)
	}
	return nil
}

// Watch monitors a key for changes.
func (n *NatsStore) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	watcher, err := n.kv.Watch(ctx, key)
	if err != nil {
		return nil, fmt.Errorf("failed to watch key %s: %w", key, err)
	}

	ch := make(chan []byte, 1)
	go func() {
		defer watcher.Stop()
		defer close(ch)
		for {
			select {
			case <-ctx.Done():
				return
			case <-n.ctx.Done():
				return
			case update := <-watcher.Updates():
				if update == nil {
					continue // Initial load or no value
				}
				select {
				case ch <- update.Value():
				case <-ctx.Done():
					return
				case <-n.ctx.Done():
					return
				}
			}
		}
	}()

	return ch, nil
}

// Close shuts down the NATS connection.
func (n *NatsStore) Close() error {
	n.nc.Close()
	return nil
}
