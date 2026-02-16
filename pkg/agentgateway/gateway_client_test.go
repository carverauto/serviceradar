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

package agentgateway

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
)

// mockGatewayServer implements the UploadFile and DownloadFile RPCs for testing.
type mockGatewayServer struct {
	proto.UnimplementedAgentGatewayServiceServer

	mu             sync.Mutex
	uploadedChunks []*proto.FileChunk
	uploadErr      error

	// downloadData is the file content the mock will stream back.
	downloadData []byte
	// downloadHash overrides the hash sent in the last chunk.
	// If empty, the real SHA-256 of downloadData is used.
	downloadHash string
	downloadErr  error
}

func (m *mockGatewayServer) UploadFile(stream grpc.ClientStreamingServer[proto.FileChunk, proto.FileUploadResponse]) error {
	if m.uploadErr != nil {
		return m.uploadErr
	}

	hasher := sha256.New()
	var total int64

	for {
		chunk, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		m.mu.Lock()
		m.uploadedChunks = append(m.uploadedChunks, chunk)
		m.mu.Unlock()

		if len(chunk.Data) > 0 {
			_, _ = hasher.Write(chunk.Data)
			total += int64(len(chunk.Data))
		}

		if chunk.IsLast {
			break
		}
	}

	computed := hex.EncodeToString(hasher.Sum(nil))

	return stream.SendAndClose(&proto.FileUploadResponse{
		Success:       true,
		Message:       "upload received",
		BytesReceived: total,
		ContentHash:   computed,
	})
}

func (m *mockGatewayServer) DownloadFile(req *proto.FileDownloadRequest, stream grpc.ServerStreamingServer[proto.FileChunk]) error {
	if m.downloadErr != nil {
		return m.downloadErr
	}

	data := m.downloadData
	hasher := sha256.New()
	_, _ = hasher.Write(data)

	hash := hex.EncodeToString(hasher.Sum(nil))
	if m.downloadHash != "" {
		hash = m.downloadHash
	}

	chunkSize := fileChunkSize
	for offset := 0; offset < len(data); offset += chunkSize {
		end := offset + chunkSize
		if end > len(data) {
			end = len(data)
		}

		isLast := end >= len(data)
		chunk := &proto.FileChunk{
			SessionId: req.SessionId,
			Data:      data[offset:end],
			Offset:    int64(offset),
			IsLast:    isLast,
		}

		if offset == 0 {
			chunk.TotalSize = int64(len(data))
		}

		if isLast {
			chunk.ContentHash = hash
		}

		if err := stream.Send(chunk); err != nil {
			return err
		}
	}

	return nil
}

func (m *mockGatewayServer) getUploadedChunks() []*proto.FileChunk {
	m.mu.Lock()
	defer m.mu.Unlock()
	cp := make([]*proto.FileChunk, len(m.uploadedChunks))
	copy(cp, m.uploadedChunks)
	return cp
}

// startMockServer starts a gRPC server with the mock on a random port.
// Returns the client, server address, and a cleanup function.
func startMockServer(t *testing.T, mock *mockGatewayServer) (*GatewayClient, func()) {
	t.Helper()

	lis, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)

	srv := grpc.NewServer()
	proto.RegisterAgentGatewayServiceServer(srv, mock)

	go func() { _ = srv.Serve(lis) }()

	t.Setenv("SR_ALLOW_INSECURE", "true")

	addr := lis.Addr().String()
	log := logger.NewTestLogger()
	gc := NewGatewayClient(addr, nil, log)

	ctx := context.Background()
	require.NoError(t, gc.Connect(ctx))

	cleanup := func() {
		_ = gc.Disconnect()
		srv.GracefulStop()
	}

	return gc, cleanup
}

// ── UploadFile tests ───────────────────────────────────────────────────────

func TestGatewayClient_UploadFile_MultiChunk(t *testing.T) {
	mock := &mockGatewayServer{}
	gc, cleanup := startMockServer(t, mock)
	defer cleanup()

	// Create a file larger than one chunk (64KB).
	tmpDir := t.TempDir()
	filePath := filepath.Join(tmpDir, "test-upload.bin")

	// 150KB — should produce 3 chunks (64K + 64K + 22K).
	data := make([]byte, 150*1024)
	for i := range data {
		data[i] = byte(i % 251) // deterministic non-zero pattern
	}
	require.NoError(t, os.WriteFile(filePath, data, 0o640))

	hasher := sha256.New()
	_, _ = hasher.Write(data)
	expectedHash := hex.EncodeToString(hasher.Sum(nil))

	resp, err := gc.UploadFile(context.Background(), "sess-multi", "test-upload.bin", filePath)
	require.NoError(t, err)
	assert.True(t, resp.Success)
	assert.Equal(t, int64(len(data)), resp.BytesReceived)
	assert.Equal(t, expectedHash, resp.ContentHash)

	// Verify chunks received by mock server.
	chunks := mock.getUploadedChunks()
	require.GreaterOrEqual(t, len(chunks), 2, "multi-chunk upload should produce >=2 chunks")

	// First chunk should have filename and total_size.
	assert.Equal(t, "test-upload.bin", chunks[0].Filename)
	assert.Equal(t, int64(len(data)), chunks[0].TotalSize)

	// Last chunk should have is_last and content_hash.
	last := chunks[len(chunks)-1]
	assert.True(t, last.IsLast)
	assert.Equal(t, expectedHash, last.ContentHash)

	// All chunks should have the session ID.
	for _, c := range chunks {
		assert.Equal(t, "sess-multi", c.SessionId)
	}
}

func TestGatewayClient_UploadFile_SingleChunk(t *testing.T) {
	mock := &mockGatewayServer{}
	gc, cleanup := startMockServer(t, mock)
	defer cleanup()

	tmpDir := t.TempDir()
	filePath := filepath.Join(tmpDir, "small.bin")

	data := []byte("hello world")
	require.NoError(t, os.WriteFile(filePath, data, 0o640))

	resp, err := gc.UploadFile(context.Background(), "sess-small", "small.bin", filePath)
	require.NoError(t, err)
	assert.True(t, resp.Success)
	assert.Equal(t, int64(len(data)), resp.BytesReceived)

	chunks := mock.getUploadedChunks()
	require.Len(t, chunks, 1, "small file should be a single chunk")
	assert.True(t, chunks[0].IsLast)
	assert.Equal(t, "small.bin", chunks[0].Filename)
	assert.NotEmpty(t, chunks[0].ContentHash)
}

// ── DownloadFile tests ─────────────────────────────────────────────────────

func TestGatewayClient_DownloadFile_Success(t *testing.T) {
	// 100KB test data — multi-chunk download.
	data := make([]byte, 100*1024)
	for i := range data {
		data[i] = byte(i % 199)
	}

	mock := &mockGatewayServer{downloadData: data}
	gc, cleanup := startMockServer(t, mock)
	defer cleanup()

	tmpDir := t.TempDir()
	destPath := filepath.Join(tmpDir, "downloaded.bin")

	req := &proto.FileDownloadRequest{
		SessionId: "sess-dl",
		AgentId:   "agent-1",
		ImageId:   "img-1",
	}

	err := gc.DownloadFile(context.Background(), req, destPath)
	require.NoError(t, err)

	// Verify the file was written correctly.
	got, err := os.ReadFile(destPath)
	require.NoError(t, err)
	assert.Equal(t, data, got)
}

func TestGatewayClient_DownloadFile_BadServerHash(t *testing.T) {
	data := []byte("valid file content")
	mock := &mockGatewayServer{
		downloadData: data,
		downloadHash: "0000000000000000000000000000000000000000000000000000000000000bad",
	}
	gc, cleanup := startMockServer(t, mock)
	defer cleanup()

	tmpDir := t.TempDir()
	destPath := filepath.Join(tmpDir, "corrupt.bin")

	req := &proto.FileDownloadRequest{
		SessionId: "sess-bad-hash",
		AgentId:   "agent-1",
		ImageId:   "img-1",
	}

	err := gc.DownloadFile(context.Background(), req, destPath)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "download hash mismatch")

	// Corrupt file should be removed.
	_, statErr := os.Stat(destPath)
	assert.True(t, os.IsNotExist(statErr), "corrupt file should be removed")
}

func TestGatewayClient_DownloadFile_ExpectedHashMismatch(t *testing.T) {
	data := []byte("some firmware image data")

	mock := &mockGatewayServer{downloadData: data}
	gc, cleanup := startMockServer(t, mock)
	defer cleanup()

	tmpDir := t.TempDir()
	destPath := filepath.Join(tmpDir, "mismatch.bin")

	req := &proto.FileDownloadRequest{
		SessionId:    "sess-expected-mismatch",
		AgentId:      "agent-1",
		ImageId:      "img-1",
		ExpectedHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}

	err := gc.DownloadFile(context.Background(), req, destPath)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "download hash mismatch with expected")

	// File should be cleaned up.
	_, statErr := os.Stat(destPath)
	assert.True(t, os.IsNotExist(statErr), "mismatched file should be removed")
}

// ── Connection guard tests ─────────────────────────────────────────────────

func TestGatewayClient_UploadFile_NotConnected(t *testing.T) {
	log := logger.NewTestLogger()
	gc := NewGatewayClient("localhost:0", nil, log)

	_, err := gc.UploadFile(context.Background(), "s", "f", "/nonexistent")
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrGatewayNotConnected)
}

func TestGatewayClient_DownloadFile_NotConnected(t *testing.T) {
	log := logger.NewTestLogger()
	gc := NewGatewayClient("localhost:0", nil, log)

	err := gc.DownloadFile(context.Background(), &proto.FileDownloadRequest{}, "/tmp/x")
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrGatewayNotConnected)
}

// ── Insecure connection guard ──────────────────────────────────────────────

func TestGatewayClient_Connect_RequiresInsecureEnv(t *testing.T) {
	t.Setenv("SR_ALLOW_INSECURE", "")

	log := logger.NewTestLogger()
	gc := NewGatewayClient("localhost:12345", nil, log)

	err := gc.Connect(context.Background())
	require.Error(t, err)
	assert.ErrorIs(t, err, ErrSecurityRequired)
}
