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

package config

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/config/kv"
	"github.com/carverauto/serviceradar/proto"
)

// KVConfigLoader loads configuration from a KV store.
type KVConfigLoader struct {
	store  kv.KVStore
	bucket string
}

// NewKVConfigLoader creates a new KVConfigLoader with the given KV store.
func NewKVConfigLoader(store kv.KVStore, bucket string) *KVConfigLoader {
	if bucket == "" {
		bucket = "serviceradar-kv" // Default bucket name
	}

	return &KVConfigLoader{store: store, bucket: bucket}
}

var (
	errKVKeyNotFound = errors.New("key not found in KV store")
)

// Load implements ConfigLoader by fetching and unmarshaling data from the KV store.
// pkg/config/kv_loader.go
func (k *KVConfigLoader) Load(ctx context.Context, path string, dst interface{}) error {
	key := path // Use the full path as the key

	log.Println("Loading key:", key)

	data, found, err := k.store.Get(ctx, key)
	if err != nil {
		return fmt.Errorf("failed to get key '%s' from KV store: %w", key, err)
	}

	if !found {
		return fmt.Errorf("%w: '%s'", errKVKeyNotFound, key)
	}

	err = json.Unmarshal(data, dst)
	if err != nil {
		return fmt.Errorf("failed to unmarshal JSON from key '%s': %w", key, err)
	}

	return nil
}

func (g *grpcKVStore) Get(ctx context.Context, key string) ([]byte, bool, error) {
	resp, err := g.client.Get(ctx, &proto.GetRequest{Key: key})
	if err != nil {
		return nil, false, err
	}
	return resp.Value, resp.Found, nil
}

func (g *grpcKVStore) Put(ctx context.Context, key string, value []byte, ttl time.Duration) error {
	_, err := g.client.Put(ctx, &proto.PutRequest{
		Key:        key,
		Value:      value,
		TtlSeconds: int64(ttl / time.Second),
	})
	return err
}

func (g *grpcKVStore) Delete(ctx context.Context, key string) error {
	_, err := g.client.Delete(ctx, &proto.DeleteRequest{Key: key})
	return err
}
func (g *grpcKVStore) Watch(ctx context.Context, key string) (<-chan []byte, error) {
	stream, err := g.client.Watch(ctx, &proto.WatchRequest{Key: key})
	if err != nil {
		return nil, err
	}

	ch := make(chan []byte)

	go func() {
		defer close(ch)
		for {
			resp, err := stream.Recv()
			if err != nil {
				return
			}

			select {
			case ch <- resp.Value:
			case <-ctx.Done():
				return
			}
		}
	}()

	return ch, nil
}

func (g *grpcKVStore) Close() error {
	return g.conn.Close()
}
