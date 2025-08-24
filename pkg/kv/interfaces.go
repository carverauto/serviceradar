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

//go:generate mockgen -destination=mock_kv.go -package=kv github.com/carverauto/serviceradar/pkg/kv KVStore

// Package kv pkg/kv/interfaces.go
package kv

import (
	"context"
	"time"
)

// KVStore defines the interface for a key-value store used in ServiceRadar configuration management.
type KVStore interface {
	// Get retrieves the value associated with the given key.
	// Returns the value as a byte slice, a boolean indicating if the key was found, and an error if the operation fails.
	Get(ctx context.Context, key string) ([]byte, bool, error)

	// Put stores a value under the given key with an optional TTL (time-to-live).
	// If ttl is zero, the value persists indefinitely (or until explicitly deleted, depending on the backend).
	Put(ctx context.Context, key string, value []byte, ttl time.Duration) error

	// PutMany stores multiple key/value pairs in a single operation.
	// The ttl parameter applies to all entries.
	PutMany(ctx context.Context, entries []KeyValueEntry, ttl time.Duration) error

	// Delete removes the key and its associated value from the store.
	Delete(ctx context.Context, key string) error

	// Watch monitors the specified key for changes and sends updates through a channel.
	// The channel receives the new value (or nil if deleted) whenever the key is modified.
	// The returned channel is closed when the context is canceled or the KV store is closed.
	Watch(ctx context.Context, key string) (<-chan []byte, error)

	// Close shuts down the KV store, releasing any resources (e.g., connections).
	Close() error
}

// KeyValueEntry represents a key-value update with metadata (used internally by NATSStore).
type KeyValueEntry struct {
	Key   string
	Value []byte
}
