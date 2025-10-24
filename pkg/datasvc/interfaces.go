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

//go:generate mockgen -destination=mock_datasvc.go -package=datasvc github.com/carverauto/serviceradar/pkg/datasvc KVStore

// Package datasvc contains interfaces and helpers for interacting with the ServiceRadar data service.
package datasvc

import (
	"context"
	"io"
	"time"
)

// KVStore defines the interface for a key-value store used in ServiceRadar configuration management.
type KVStore interface {
	// Get retrieves the value associated with the given key.
	// Returns the value as a byte slice, a boolean indicating if the key was found, and an error if the operation fails.
	Get(ctx context.Context, key string) ([]byte, bool, error)

	// GetEntry retrieves the full metadata for the key, including revision numbers.
	GetEntry(ctx context.Context, key string) (Entry, error)

	// Put stores a value under the given key with an optional TTL (time-to-live).
	// If ttl is zero, the value persists indefinitely (or until explicitly deleted, depending on the backend).
	Put(ctx context.Context, key string, value []byte, ttl time.Duration) error

	// PutIfAbsent stores a value only if the key does not already exist.
	// Returns an error if the key exists. TTL semantics mirror Put.
	PutIfAbsent(ctx context.Context, key string, value []byte, ttl time.Duration) error

	// PutMany stores multiple key/value pairs in a single operation.
	// The ttl parameter applies to all entries.
	PutMany(ctx context.Context, entries []KeyValueEntry, ttl time.Duration) error

	// Update performs a compare-and-swap write using the provided revision.
	Update(ctx context.Context, key string, value []byte, revision uint64, ttl time.Duration) (uint64, error)

	// Delete removes the key and its associated value from the store.
	Delete(ctx context.Context, key string) error

	// Watch monitors the specified key for changes and sends updates through a channel.
	// The channel receives the new value (or nil if deleted) whenever the key is modified.
	// The returned channel is closed when the context is canceled or the KV store is closed.
	Watch(ctx context.Context, key string) (<-chan []byte, error)

	// PutObject streams an object payload into the JetStream object store.
	PutObject(ctx context.Context, key string, reader io.Reader, meta ObjectMetadata) (*ObjectInfo, error)

	// GetObject retrieves an object payload from the JetStream object store.
	GetObject(ctx context.Context, key string) (io.ReadCloser, *ObjectInfo, error)

	// DeleteObject removes an object from the JetStream object store.
	DeleteObject(ctx context.Context, key string) error

	// GetObjectInfo returns object metadata without downloading payload data.
	GetObjectInfo(ctx context.Context, key string) (*ObjectInfo, bool, error)

	// Close shuts down the KV store, releasing any resources (e.g., connections).
	Close() error
}

// KeyValueEntry represents a key-value update with metadata (used internally by NATSStore).
type KeyValueEntry struct {
	Key   string
	Value []byte
}

// Entry captures the value, revision, and presence metadata for a key lookup.
type Entry struct {
	Value    []byte
	Revision uint64
	Found    bool
}

// ObjectMetadata captures descriptive attributes for JetStream objects.
type ObjectMetadata struct {
	Domain      string
	ContentType string
	Compression string
	SHA256      string
	TotalSize   int64
	Attributes  map[string]string
}

// ObjectInfo reflects server-observed metadata for stored objects.
type ObjectInfo struct {
	Key            string
	Domain         string
	SHA256         string
	Size           int64
	CreatedAtUnix  int64
	ModifiedAtUnix int64
	Chunks         uint64
	Metadata       ObjectMetadata
}
