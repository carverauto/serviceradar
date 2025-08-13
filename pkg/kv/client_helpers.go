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

// Package kv pkg/kv/client_helpers.go
package kv

import (
	"context"
	"fmt"
	"io"
	"time"

	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const (
	// DefaultChunkSize is the default size for streaming chunks (1MB)
	DefaultChunkSize = 1024 * 1024
	// LargeDataThreshold is the threshold above which we use streaming (2MB)
	LargeDataThreshold = 2 * 1024 * 1024
)

// PutLarge intelligently chooses between regular Put and streaming PutStream based on data size.
func PutLarge(ctx context.Context, client proto.KVServiceClient, key string, value []byte, ttl time.Duration) error {
	// If the data is small enough, use regular Put
	if len(value) < LargeDataThreshold {
		_, err := client.Put(ctx, &proto.PutRequest{
			Key:        key,
			Value:      value,
			TtlSeconds: int64(ttl.Seconds()),
		})
		return err
	}

	// For large data, use streaming
	return PutWithStream(ctx, client, key, value, ttl)
}

// PutWithStream sends data using the streaming PutStream RPC.
func PutWithStream(ctx context.Context, client proto.KVServiceClient, key string, value []byte, ttl time.Duration) error {
	stream, err := client.PutStream(ctx)
	if err != nil {
		return fmt.Errorf("failed to create stream: %w", err)
	}

	// Send metadata first
	metadata := &proto.PutStreamRequest{
		Data: &proto.PutStreamRequest_Metadata{
			Metadata: &proto.PutStreamMetadata{
				Key:        key,
				TtlSeconds: int64(ttl.Seconds()),
				TotalSize:  int64(len(value)),
			},
		},
	}

	if err := stream.Send(metadata); err != nil {
		return fmt.Errorf("failed to send metadata: %w", err)
	}

	// Send data in chunks
	for i := 0; i < len(value); i += DefaultChunkSize {
		end := i + DefaultChunkSize
		if end > len(value) {
			end = len(value)
		}

		chunk := &proto.PutStreamRequest{
			Data: &proto.PutStreamRequest_Chunk{
				Chunk: value[i:end],
			},
		}

		if err := stream.Send(chunk); err != nil {
			return fmt.Errorf("failed to send chunk: %w", err)
		}
	}

	// Close the stream and get response
	resp, err := stream.CloseAndRecv()
	if err != nil {
		return fmt.Errorf("failed to complete stream: %w", err)
	}

	if !resp.Success {
		return fmt.Errorf("stream operation failed")
	}

	return nil
}

// PutManyLarge handles PutMany operations with support for large values.
// It automatically splits large entries into streaming operations.
func PutManyLarge(ctx context.Context, client proto.KVServiceClient, entries []*proto.KeyValueEntry, ttl time.Duration) error {
	var smallEntries []*proto.KeyValueEntry
	var largeEntries []*proto.KeyValueEntry

	// Separate small and large entries
	for _, entry := range entries {
		if len(entry.Value) < LargeDataThreshold {
			smallEntries = append(smallEntries, entry)
		} else {
			largeEntries = append(largeEntries, entry)
		}
	}

	// Handle small entries with regular PutMany
	if len(smallEntries) > 0 {
		_, err := client.PutMany(ctx, &proto.PutManyRequest{
			Entries:    smallEntries,
			TtlSeconds: int64(ttl.Seconds()),
		})
		if err != nil {
			return fmt.Errorf("failed to put small entries: %w", err)
		}
	}

	// Handle large entries with streaming
	for _, entry := range largeEntries {
		if err := PutWithStream(ctx, client, entry.Key, entry.Value, ttl); err != nil {
			return fmt.Errorf("failed to stream large entry %s: %w", entry.Key, err)
		}
	}

	return nil
}

// StreamReader wraps a reader for streaming data to KV store.
type StreamReader struct {
	client proto.KVServiceClient
	key    string
	ttl    time.Duration
}

// NewStreamReader creates a new StreamReader for streaming data from an io.Reader.
func NewStreamReader(client proto.KVServiceClient, key string, ttl time.Duration) *StreamReader {
	return &StreamReader{
		client: client,
		key:    key,
		ttl:    ttl,
	}
}

// WriteFrom implements io.WriterTo for streaming from an io.Reader.
func (sr *StreamReader) WriteFrom(ctx context.Context, r io.Reader, totalSize int64) error {
	stream, err := sr.client.PutStream(ctx)
	if err != nil {
		return fmt.Errorf("failed to create stream: %w", err)
	}

	// Send metadata
	metadata := &proto.PutStreamRequest{
		Data: &proto.PutStreamRequest_Metadata{
			Metadata: &proto.PutStreamMetadata{
				Key:        sr.key,
				TtlSeconds: int64(sr.ttl.Seconds()),
				TotalSize:  totalSize,
			},
		},
	}

	if err := stream.Send(metadata); err != nil {
		return fmt.Errorf("failed to send metadata: %w", err)
	}

	// Stream data in chunks
	buf := make([]byte, DefaultChunkSize)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := &proto.PutStreamRequest{
				Data: &proto.PutStreamRequest_Chunk{
					Chunk: buf[:n],
				},
			}

			if err := stream.Send(chunk); err != nil {
				return fmt.Errorf("failed to send chunk: %w", err)
			}
		}

		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("failed to read data: %w", err)
		}
	}

	// Close and get response
	resp, err := stream.CloseAndRecv()
	if err != nil {
		return fmt.Errorf("failed to complete stream: %w", err)
	}

	if !resp.Success {
		return fmt.Errorf("stream operation failed")
	}

	return nil
}

// PutManyWithRetry wraps PutManyLarge with retry logic for handling temporary failures.
func PutManyWithRetry(ctx context.Context, client proto.KVServiceClient, entries []*proto.KeyValueEntry, ttl time.Duration, maxRetries int) error {
	var lastErr error
	
	for i := 0; i < maxRetries; i++ {
		if err := PutManyLarge(ctx, client, entries, ttl); err != nil {
			lastErr = err
			// Check if error is retryable
			if status.Code(err) == codes.ResourceExhausted {
				// Wait before retry with exponential backoff
				backoff := time.Duration(1<<uint(i)) * time.Second
				if backoff > 30*time.Second {
					backoff = 30 * time.Second
				}
				time.Sleep(backoff)
				continue
			}
			return err // Non-retryable error
		}
		return nil // Success
	}
	
	return fmt.Errorf("all %d retries failed: %w", maxRetries, lastErr)
}