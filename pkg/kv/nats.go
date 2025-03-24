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
	"errors"
	"fmt"
	"log"
	"time"

	configkv "github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

type NatsStore struct {
	nc  *nats.Conn
	kv  jetstream.KeyValue
	ctx context.Context
}

func NewNatsStore(ctx context.Context, natsURL, bucket string, ttl time.Duration) (*NatsStore, error) {
	nc, err := nats.Connect(natsURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to NATS: %w", err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()

		return nil, fmt.Errorf("failed to create JetStream context: %w", err)
	}

	config := jetstream.KeyValueConfig{
		Bucket: bucket,
	}

	if ttl > 0 {
		config.TTL = ttl // Set TTL at bucket level
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

func (n *NatsStore) Get(ctx context.Context, key string) (value []byte, found bool, err error) {
	var entry jetstream.KeyValueEntry

	entry, err = n.kv.Get(ctx, key)
	if errors.Is(err, jetstream.ErrKeyNotFound) {
		return nil, false, nil
	}

	if err != nil {
		return nil, false, fmt.Errorf("failed to get key %s: %w", key, err)
	}

	return entry.Value(), true, nil
}

func (n *NatsStore) Put(ctx context.Context, key string, value []byte, _ time.Duration) error {
	_, err := n.kv.Put(ctx, key, value) // No opts, TTL is bucket-level
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

// handleWatchUpdates processes updates from the watcher and sends them to the channel.
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
			return // Context canceled or watcher closed
		}

		if !n.sendUpdate(ctx, ch, update.Value()) {
			return // Context canceled or channel closed
		}
	}
}

// waitForUpdate waits for the next update or context cancellation.
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

// sendUpdate attempts to send the value to the channel, respecting context cancellation.
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
