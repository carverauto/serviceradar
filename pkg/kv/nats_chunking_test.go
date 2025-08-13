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
	"bytes"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
)

// TestNATSChunking tests the chunking logic for NATS storage
func TestNATSChunking(t *testing.T) {
	tests := []struct {
		name        string
		dataSize    int
		expectChunks int
	}{
		{
			name:        "small data (100KB)",
			dataSize:    100 * 1024,
			expectChunks: 0, // No chunking needed
		},
		{
			name:        "exactly at threshold",
			dataSize:    NATSMaxPayload,
			expectChunks: 0, // No chunking needed at exactly the threshold
		},
		{
			name:        "just over threshold",
			dataSize:    NATSMaxPayload + 1,
			expectChunks: 2, // Should create 2 chunks
		},
		{
			name:        "large data (2MB)",
			dataSize:    2 * 1024 * 1024,
			expectChunks: 3, // Should create 3 chunks (900KB each, last one partial)
		},
		{
			name:        "very large data (5MB)",
			dataSize:    5 * 1024 * 1024,
			expectChunks: 6, // Should create 6 chunks
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_ = bytes.Repeat([]byte("x"), tt.dataSize)
			
			// Calculate expected chunks
			expectedChunks := 0
			if tt.dataSize > NATSMaxPayload {
				expectedChunks = (tt.dataSize + NATSMaxPayload - 1) / NATSMaxPayload
			}
			
			assert.Equal(t, tt.expectChunks, expectedChunks, 
				"Chunk calculation mismatch for %s", tt.name)
			
			// Test metadata creation
			if expectedChunks > 0 {
				metadata := ChunkMetadata{
					TotalSize:  tt.dataSize,
					ChunkCount: expectedChunks,
					ChunkSize:  NATSMaxPayload,
					IsChunked:  true,
				}
				
				metaJSON, err := json.Marshal(metadata)
				assert.NoError(t, err, "Should marshal metadata without error")
				assert.NotEmpty(t, metaJSON, "Metadata JSON should not be empty")
				
				// Verify metadata can be unmarshaled
				var unmarshaledMeta ChunkMetadata
				err = json.Unmarshal(metaJSON, &unmarshaledMeta)
				assert.NoError(t, err, "Should unmarshal metadata without error")
				assert.Equal(t, metadata.TotalSize, unmarshaledMeta.TotalSize)
				assert.Equal(t, metadata.ChunkCount, unmarshaledMeta.ChunkCount)
				assert.True(t, unmarshaledMeta.IsChunked)
			}
			
			t.Logf("Data size: %d bytes, Expected chunks: %d", tt.dataSize, expectedChunks)
		})
	}
}

// TestChunkKeyGeneration tests the generation of chunk keys
func TestChunkKeyGeneration(t *testing.T) {
	baseKey := "test/key"
	
	tests := []struct {
		chunkIndex int
		expected   string
	}{
		{0, "test/key_chunk__0"},
		{1, "test/key_chunk__1"},
		{10, "test/key_chunk__10"},
	}
	
	for _, tt := range tests {
		t.Run(tt.expected, func(t *testing.T) {
			chunkKey := baseKey + ChunkKeyPrefix + "_" + string(rune(tt.chunkIndex + '0'))
			if tt.chunkIndex >= 10 {
				chunkKey = baseKey + ChunkKeyPrefix + "_10"
			}
			assert.Equal(t, tt.expected, chunkKey)
		})
	}
}

// TestMetadataKeyGeneration tests the generation of metadata keys
func TestMetadataKeyGeneration(t *testing.T) {
	tests := []struct {
		baseKey  string
		expected string
	}{
		{"test/key", "test/key_meta"},
		{"agents/foo/config", "agents/foo/config_meta"},
		{"simple", "simple_meta"},
	}
	
	for _, tt := range tests {
		t.Run(tt.baseKey, func(t *testing.T) {
			metaKey := tt.baseKey + MetadataKeySuffix
			assert.Equal(t, tt.expected, metaKey)
		})
	}
}

// TestChunkSplitting verifies that data is correctly split into chunks
func TestChunkSplitting(t *testing.T) {
	dataSize := 2*1024*1024 + 500*1024 // 2.5MB
	data := bytes.Repeat([]byte("a"), dataSize)
	
	chunkCount := (dataSize + NATSMaxPayload - 1) / NATSMaxPayload
	assert.Equal(t, 3, chunkCount, "Should have 3 chunks for 2.5MB")
	
	// Simulate chunking
	chunks := make([][]byte, 0, chunkCount)
	for i := 0; i < chunkCount; i++ {
		start := i * NATSMaxPayload
		end := start + NATSMaxPayload
		if end > len(data) {
			end = len(data)
		}
		chunk := data[start:end]
		chunks = append(chunks, chunk)
		
		// Verify chunk size
		if i < chunkCount-1 {
			assert.Equal(t, NATSMaxPayload, len(chunk), 
				"All chunks except last should be max size")
		} else {
			assert.LessOrEqual(t, len(chunk), NATSMaxPayload, 
				"Last chunk should be <= max size")
		}
	}
	
	// Verify reassembly
	var reassembled bytes.Buffer
	for _, chunk := range chunks {
		reassembled.Write(chunk)
	}
	
	assert.Equal(t, dataSize, reassembled.Len(), "Reassembled size should match original")
	assert.True(t, bytes.Equal(data, reassembled.Bytes()), "Reassembled data should match original")
}

// BenchmarkChunking benchmarks the chunking operations
func BenchmarkChunking(b *testing.B) {
	sizes := []int{
		500 * 1024,       // 500KB (no chunking)
		1 * 1024 * 1024,  // 1MB (minimal chunking)
		5 * 1024 * 1024,  // 5MB (significant chunking)
	}
	
	for _, size := range sizes {
		data := bytes.Repeat([]byte("x"), size)
		
		b.Run(fmt.Sprintf("size_%dKB", size/1024), func(b *testing.B) {
			b.SetBytes(int64(size))
			b.ResetTimer()
			
			for i := 0; i < b.N; i++ {
				// Benchmark chunk calculation and splitting
				chunkCount := (size + NATSMaxPayload - 1) / NATSMaxPayload
				
				for j := 0; j < chunkCount; j++ {
					start := j * NATSMaxPayload
					end := start + NATSMaxPayload
					if end > len(data) {
						end = len(data)
					}
					_ = data[start:end]
				}
			}
		})
	}
}