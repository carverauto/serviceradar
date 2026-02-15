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

package agent

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	tftp "github.com/pin/tftp/v3"
	"github.com/rs/zerolog"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newTestTFTPService(t *testing.T) (*TFTPService, string) {
	t.Helper()

	tmpDir, err := os.MkdirTemp("", "tftp-test-*")
	require.NoError(t, err)

	t.Cleanup(func() { os.RemoveAll(tmpDir) })

	logger := zerolog.New(zerolog.NewTestWriter(t)).With().Timestamp().Logger()
	svc := NewTFTPService(logger, tmpDir)

	return svc, tmpDir
}

func TestTFTPService_Name(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	assert.Equal(t, "tftp", svc.Name())
}

func TestTFTPService_StartStop(t *testing.T) {
	svc, tmpDir := newTestTFTPService(t)

	ctx := context.Background()
	require.NoError(t, svc.Start(ctx))

	// Staging dir should exist
	_, err := os.Stat(tmpDir)
	require.NoError(t, err)

	require.NoError(t, svc.Stop(ctx))
}

func TestTFTPService_HasActiveSession(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	assert.False(t, svc.HasActiveSession())
}

func TestTFTPService_FilenameAllowlist(t *testing.T) {
	svc, _ := newTestTFTPService(t)

	tests := []struct {
		name     string
		req      string
		expected string
		allowed  bool
	}{
		{"exact match", "startup-config.bin", "startup-config.bin", true},
		{"mismatch", "other-file.bin", "startup-config.bin", false},
		{"path traversal dots", "../etc/passwd", "startup-config.bin", false},
		{"path traversal slash", "foo/bar.bin", "startup-config.bin", false},
		{"path traversal backslash", "foo\\bar.bin", "startup-config.bin", false},
		{"empty request", "", "startup-config.bin", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := svc.isFilenameAllowed(tt.req, tt.expected)
			assert.Equal(t, tt.allowed, result)
		})
	}
}

func TestTFTPService_LimitedWriter(t *testing.T) {
	var buf bytes.Buffer
	lw := &limitedWriter{
		w:     &buf,
		limit: 10,
	}

	// Write within limit
	n, err := lw.Write([]byte("hello"))
	require.NoError(t, err)
	assert.Equal(t, 5, n)
	assert.Equal(t, int64(5), lw.written)

	// Write that exceeds limit
	_, err = lw.Write([]byte("world!"))
	assert.ErrorIs(t, err, errFileSizeLimitExceeded)
}

func TestTFTPService_LimitedWriter_ExactLimit(t *testing.T) {
	var buf bytes.Buffer
	lw := &limitedWriter{
		w:     &buf,
		limit: 5,
	}

	n, err := lw.Write([]byte("hello"))
	require.NoError(t, err)
	assert.Equal(t, 5, n)

	// One more byte should fail
	_, err = lw.Write([]byte("x"))
	assert.ErrorIs(t, err, errFileSizeLimitExceeded)
}

func TestTFTPService_ConcurrencyLimit(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	ctx := context.Background()
	require.NoError(t, svc.Start(ctx))

	// Start a receive session
	err := svc.StartReceive(ctx, tftpReceivePayload{
		SessionID:        "session-1",
		ExpectedFilename: "test.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   5,
		Port:             0, // will use default
		BindAddress:      "127.0.0.1",
	})
	require.NoError(t, err)
	assert.True(t, svc.HasActiveSession())

	// Try to start another session — should fail
	err = svc.StartReceive(ctx, tftpReceivePayload{
		SessionID:        "session-2",
		ExpectedFilename: "test2.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   5,
		BindAddress:      "127.0.0.1",
	})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "active TFTP session")

	// Stop and cleanup
	require.NoError(t, svc.Stop(ctx))
}

func TestTFTPService_ReceiveMode(t *testing.T) {
	svc, tmpDir := newTestTFTPService(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	require.NoError(t, svc.Start(ctx))

	// Find a free port
	port := findFreePort(t)

	var (
		resultMu      sync.Mutex
		gotResult     bool
		resultSuccess bool
		resultHash    string
		resultSize    int64
	)

	svc.SetCallbacks(
		func(sessionID string, bytesTransferred int64, message string) {
			t.Logf("progress: session=%s bytes=%d msg=%s", sessionID, bytesTransferred, message)
		},
		func(sessionID string, success bool, message string, fileSize int64, contentHash string) {
			t.Logf("result: session=%s success=%v msg=%s size=%d hash=%s", sessionID, success, message, fileSize, contentHash)
			resultMu.Lock()
			gotResult = true
			resultSuccess = success
			resultHash = contentHash
			resultSize = fileSize
			resultMu.Unlock()
		},
	)

	err := svc.StartReceive(ctx, tftpReceivePayload{
		SessionID:        "test-recv",
		ExpectedFilename: "config.bin",
		MaxFileSize:      1024 * 1024,
		TimeoutSeconds:   10,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	require.NoError(t, err)

	// Wait for server to be ready
	time.Sleep(200 * time.Millisecond)

	// Send a file via TFTP client
	testData := []byte("hello from the TFTP test client")
	expectedHash := sha256Hex(testData)

	client, err := tftp.NewClient(fmt.Sprintf("127.0.0.1:%d", port))
	require.NoError(t, err)

	sender, err := client.Send("config.bin", "octet")
	require.NoError(t, err)

	n, err := sender.ReadFrom(bytes.NewReader(testData))
	require.NoError(t, err)
	assert.Equal(t, int64(len(testData)), n)

	// Wait for result callback
	require.Eventually(t, func() bool {
		resultMu.Lock()
		defer resultMu.Unlock()
		return gotResult
	}, 5*time.Second, 100*time.Millisecond)

	resultMu.Lock()
	assert.True(t, resultSuccess)
	assert.Equal(t, expectedHash, resultHash)
	assert.Equal(t, int64(len(testData)), resultSize)
	resultMu.Unlock()

	// Verify the file was written to staging
	receivedPath := filepath.Join(tmpDir, "test-recv", "config.bin")
	data, err := os.ReadFile(receivedPath)
	require.NoError(t, err)
	assert.Equal(t, testData, data)
}

func TestTFTPService_ReceiveMode_WrongFilename(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	require.NoError(t, svc.Start(ctx))

	port := findFreePort(t)

	err := svc.StartReceive(ctx, tftpReceivePayload{
		SessionID:        "test-wrong-name",
		ExpectedFilename: "expected.bin",
		MaxFileSize:      1024 * 1024,
		TimeoutSeconds:   10,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	require.NoError(t, err)

	time.Sleep(200 * time.Millisecond)

	client, err := tftp.NewClient(fmt.Sprintf("127.0.0.1:%d", port))
	require.NoError(t, err)

	// Try to send with wrong filename — should be rejected by server
	_, err = client.Send("wrong-name.bin", "octet")
	assert.Error(t, err)

	require.NoError(t, svc.Stop(ctx))
}

func TestTFTPService_ServeMode(t *testing.T) {
	svc, tmpDir := newTestTFTPService(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	require.NoError(t, svc.Start(ctx))

	// Stage a file to serve
	sessionID := "test-serve"
	filename := "firmware.bin"
	testData := []byte("firmware image data for serving")
	expectedHash := sha256Hex(testData)

	sessionDir := filepath.Join(tmpDir, sessionID)
	require.NoError(t, os.MkdirAll(sessionDir, 0o750))
	require.NoError(t, os.WriteFile(filepath.Join(sessionDir, filename), testData, 0o640))

	port := findFreePort(t)

	var (
		resultMu      sync.Mutex
		gotResult     bool
		resultSuccess bool
	)

	svc.SetCallbacks(
		func(sessionID string, bytesTransferred int64, message string) {},
		func(sessionID string, success bool, message string, fileSize int64, contentHash string) {
			resultMu.Lock()
			gotResult = true
			resultSuccess = success
			resultMu.Unlock()
		},
	)

	err := svc.StartServe(ctx, tftpServePayload{
		SessionID:      sessionID,
		ImageID:        "img-1",
		Filename:       filename,
		ContentHash:    expectedHash,
		FileSize:       int64(len(testData)),
		TimeoutSeconds: 10,
		BindAddress:    "127.0.0.1",
		Port:           port,
	})
	require.NoError(t, err)

	time.Sleep(200 * time.Millisecond)

	// Read file via TFTP client
	client, err := tftp.NewClient(fmt.Sprintf("127.0.0.1:%d", port))
	require.NoError(t, err)

	receiver, err := client.Receive(filename, "octet")
	require.NoError(t, err)

	var buf bytes.Buffer
	n, err := receiver.WriteTo(&buf)
	require.NoError(t, err)
	assert.Equal(t, int64(len(testData)), n)
	assert.Equal(t, testData, buf.Bytes())

	// Wait for result callback
	require.Eventually(t, func() bool {
		resultMu.Lock()
		defer resultMu.Unlock()
		return gotResult
	}, 5*time.Second, 100*time.Millisecond)

	resultMu.Lock()
	assert.True(t, resultSuccess)
	resultMu.Unlock()
}

func TestTFTPService_ServeMode_WrongFilename(t *testing.T) {
	svc, tmpDir := newTestTFTPService(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	require.NoError(t, svc.Start(ctx))

	sessionID := "test-serve-wrong"
	filename := "firmware.bin"
	testData := []byte("firmware data")

	sessionDir := filepath.Join(tmpDir, sessionID)
	require.NoError(t, os.MkdirAll(sessionDir, 0o750))
	require.NoError(t, os.WriteFile(filepath.Join(sessionDir, filename), testData, 0o640))

	port := findFreePort(t)

	err := svc.StartServe(ctx, tftpServePayload{
		SessionID:      sessionID,
		Filename:       filename,
		FileSize:       int64(len(testData)),
		TimeoutSeconds: 10,
		BindAddress:    "127.0.0.1",
		Port:           port,
	})
	require.NoError(t, err)

	time.Sleep(200 * time.Millisecond)

	client, err := tftp.NewClient(fmt.Sprintf("127.0.0.1:%d", port))
	require.NoError(t, err)

	// Try to receive with wrong filename
	_, err = client.Receive("wrong-file.bin", "octet")
	assert.Error(t, err)

	require.NoError(t, svc.Stop(ctx))
}

func TestTFTPService_ServeMode_StagedImageMissing(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	ctx := context.Background()
	require.NoError(t, svc.Start(ctx))

	err := svc.StartServe(ctx, tftpServePayload{
		SessionID:      "nonexistent",
		Filename:       "missing.bin",
		TimeoutSeconds: 5,
		BindAddress:    "127.0.0.1",
	})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "staged image not found")
}

func TestTFTPService_SessionTimeout(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	ctx := context.Background()
	require.NoError(t, svc.Start(ctx))

	port := findFreePort(t)

	err := svc.StartReceive(ctx, tftpReceivePayload{
		SessionID:        "test-timeout",
		ExpectedFilename: "config.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   1, // 1 second timeout
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	require.NoError(t, err)
	assert.True(t, svc.HasActiveSession())

	// Wait for timeout to expire
	time.Sleep(2 * time.Second)

	// Session should have cleaned up
	assert.Eventually(t, func() bool {
		return !svc.HasActiveSession()
	}, 5*time.Second, 200*time.Millisecond)
}

func TestTFTPService_StopSession(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	ctx := context.Background()
	require.NoError(t, svc.Start(ctx))

	port := findFreePort(t)

	err := svc.StartReceive(ctx, tftpReceivePayload{
		SessionID:        "test-stop",
		ExpectedFilename: "config.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   60,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	require.NoError(t, err)
	assert.True(t, svc.HasActiveSession())

	err = svc.stopSession(ctx, "test-stop")
	require.NoError(t, err)

	assert.Eventually(t, func() bool {
		return !svc.HasActiveSession()
	}, 5*time.Second, 100*time.Millisecond)
}

func TestTFTPService_StopSession_WrongID(t *testing.T) {
	svc, _ := newTestTFTPService(t)
	ctx := context.Background()
	require.NoError(t, svc.Start(ctx))

	port := findFreePort(t)

	err := svc.StartReceive(ctx, tftpReceivePayload{
		SessionID:        "test-active",
		ExpectedFilename: "config.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   60,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	require.NoError(t, err)

	// Stop with wrong session ID
	err = svc.stopSession(ctx, "wrong-id")
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "not found")

	require.NoError(t, svc.Stop(ctx))
}

func TestTFTPService_GetReceivedFilePath(t *testing.T) {
	svc, tmpDir := newTestTFTPService(t)

	path := svc.GetReceivedFilePath("session-1", "config.bin")
	assert.Equal(t, filepath.Join(tmpDir, "session-1", "config.bin"), path)
}

func TestTFTPService_Callbacks(t *testing.T) {
	svc, _ := newTestTFTPService(t)

	var progressCalled, resultCalled bool

	svc.SetCallbacks(
		func(sessionID string, bytesTransferred int64, message string) {
			progressCalled = true
		},
		func(sessionID string, success bool, message string, fileSize int64, contentHash string) {
			resultCalled = true
		},
	)

	svc.reportProgress("test", 100, "testing")
	svc.reportResult("test", true, "done", 100, "abc")

	assert.True(t, progressCalled)
	assert.True(t, resultCalled)
}

func TestTFTPService_Callbacks_Nil(t *testing.T) {
	svc, _ := newTestTFTPService(t)

	// Should not panic with nil callbacks
	svc.reportProgress("test", 100, "testing")
	svc.reportResult("test", true, "done", 100, "abc")
}

// findFreePort finds an available UDP port.
func findFreePort(t *testing.T) int {
	t.Helper()

	conn, err := net.ListenPacket("udp", "127.0.0.1:0")
	require.NoError(t, err)
	defer conn.Close()

	return conn.LocalAddr().(*net.UDPAddr).Port
}

func sha256Hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

// writerToAdapter adapts an io.Reader to io.WriterTo for testing.
type writerToAdapter struct {
	r io.Reader
}

func (w *writerToAdapter) WriteTo(dst io.Writer) (int64, error) {
	return io.Copy(dst, w.r)
}
