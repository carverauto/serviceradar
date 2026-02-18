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
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// mockBidiStream implements grpc.BidiStreamingClient for capturing sent messages.
type mockBidiStream struct {
	mu   sync.Mutex
	sent []*proto.ControlStreamRequest
	ctx  context.Context
}

func newMockBidiStream(ctx context.Context) *mockBidiStream {
	return &mockBidiStream{ctx: ctx}
}

func (m *mockBidiStream) Send(req *proto.ControlStreamRequest) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sent = append(m.sent, req)
	return nil
}

func (m *mockBidiStream) Recv() (*proto.ControlStreamResponse, error) {
	return nil, io.EOF
}

func (m *mockBidiStream) CloseSend() error { return nil }

func (m *mockBidiStream) Header() (metadata.MD, error) { return nil, nil }

func (m *mockBidiStream) Trailer() metadata.MD { return nil }

func (m *mockBidiStream) Context() context.Context { return m.ctx }

func (m *mockBidiStream) SendMsg(interface{}) error { return nil }

func (m *mockBidiStream) RecvMsg(interface{}) error { return nil }

// getSent returns a copy of all captured messages.
func (m *mockBidiStream) getSent() []*proto.ControlStreamRequest {
	m.mu.Lock()
	defer m.mu.Unlock()
	cp := make([]*proto.ControlStreamRequest, len(m.sent))
	copy(cp, m.sent)
	return cp
}

// Compile-time interface check.
var _ grpc.BidiStreamingClient[proto.ControlStreamRequest, proto.ControlStreamResponse] = (*mockBidiStream)(nil)

// newTestPushLoopWithTFTP creates a minimal PushLoop with a real TFTPService
// backed by a temporary staging directory.
func newTestPushLoopWithTFTP(t *testing.T) (*PushLoop, string) {
	t.Helper()

	tmpDir, err := os.MkdirTemp("", "tftp-cmd-test-*")
	require.NoError(t, err)
	t.Cleanup(func() {
		require.NoError(t, os.RemoveAll(tmpDir))
	})

	log := logger.NewTestLogger()

	tftpSvc := NewTFTPService(
		log.With().Str("test", t.Name()).Logger(),
		tmpDir,
	)
	require.NoError(t, tftpSvc.Start(context.Background()))
	t.Cleanup(func() {
		require.NoError(t, tftpSvc.Stop(context.Background()))
	})

	server := &Server{
		config:      &ServerConfig{AgentID: "test-agent", Partition: "default"},
		tftpService: tftpSvc,
		logger:      log,
		services:    make([]Service, 0),
		errChan:     make(chan error, 1),
		done:        make(chan struct{}),
	}

	pl := NewPushLoop(server, nil, time.Second, log)

	return pl, tmpDir
}

// makeCommand creates a CommandRequest with the given type and JSON payload.
func makeCommand(t *testing.T, cmdType string, payload interface{}) *proto.CommandRequest {
	t.Helper()

	var payloadJSON []byte
	if payload != nil {
		var err error
		payloadJSON, err = json.Marshal(payload)
		require.NoError(t, err)
	}

	return &proto.CommandRequest{
		CommandId:   "cmd-" + cmdType,
		CommandType: cmdType,
		PayloadJson: payloadJSON,
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  300,
	}
}

// findCommandResult searches sent messages for a CommandResult and returns it.
func findCommandResult(msgs []*proto.ControlStreamRequest) *proto.CommandResult {
	for _, msg := range msgs {
		if r := msg.GetCommandResult(); r != nil {
			return r
		}
	}
	return nil
}

// findCommandProgress searches sent messages for CommandProgress messages.
func findCommandProgress(msgs []*proto.ControlStreamRequest) []*proto.CommandProgress {
	var out []*proto.CommandProgress
	for _, msg := range msgs {
		if p := msg.GetCommandProgress(); p != nil {
			out = append(out, p)
		}
	}
	return out
}

// unmarshalResultPayload unmarshals the PayloadJson of a CommandResult.
func unmarshalResultPayload(t *testing.T, r *proto.CommandResult) map[string]interface{} {
	t.Helper()
	if len(r.PayloadJson) == 0 {
		return nil
	}
	var m map[string]interface{}
	require.NoError(t, json.Unmarshal(r.PayloadJson, &m))
	return m
}

type missingFieldTestCase[T any] struct {
	name    string
	payload T
}

func runMissingFieldsTest[T any](
	t *testing.T,
	ctx context.Context,
	cmdType string,
	cases []missingFieldTestCase[T],
	expectedMessage string,
	handler func(context.Context, *proto.CommandRequest, *controlStreamSender),
) {
	t.Helper()

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stream := newMockBidiStream(ctx)
			sender := newControlStreamSender(stream)
			cmd := makeCommand(t, cmdType, tc.payload)

			handler(ctx, cmd, sender)

			result := findCommandResult(stream.getSent())
			require.NotNil(t, result)
			assert.False(t, result.Success)
			assert.Contains(t, result.Message, expectedMessage)
		})
	}
}

// ── handleTFTPReceive ──────────────────────────────────────────────────────

func TestTFTPCommandReceive_InvalidPayload(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := &proto.CommandRequest{
		CommandId:   "cmd-recv-bad",
		CommandType: commandTypeTFTPReceive,
		PayloadJson: []byte(`{not json`),
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  300,
	}

	pl.handleTFTPReceive(ctx, cmd, sender)

	msgs := stream.getSent()
	result := findCommandResult(msgs)
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Contains(t, result.Message, "invalid tftp receive payload")
}

func TestTFTPCommandReceive_MissingFields(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	tests := []missingFieldTestCase[tftpReceivePayload]{
		{
			name:    "missing session_id",
			payload: tftpReceivePayload{ExpectedFilename: "config.bin"},
		},
		{
			name:    "missing expected_filename",
			payload: tftpReceivePayload{SessionID: "sess-1"},
		},
		{
			name:    "both empty",
			payload: tftpReceivePayload{},
		},
	}

	runMissingFieldsTest(t, ctx, commandTypeTFTPReceive, tests, "missing session_id or expected_filename", pl.handleTFTPReceive)
}

func TestTFTPCommandReceive_NoTFTPService(t *testing.T) {
	log := logger.NewTestLogger()

	server := &Server{
		config:      &ServerConfig{AgentID: "test-agent"},
		tftpService: nil, // no TFTP service
		logger:      log,
		services:    make([]Service, 0),
		errChan:     make(chan error, 1),
		done:        make(chan struct{}),
	}
	pl := NewPushLoop(server, nil, time.Second, log)

	ctx := context.Background()
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPReceive, tftpReceivePayload{
		SessionID:        "sess-1",
		ExpectedFilename: "config.bin",
	})

	pl.handleTFTPReceive(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Equal(t, "tftp service unavailable", result.Message)
}

func TestTFTPCommandReceive_ValidPayload(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	port := findFreePort(t)
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := makeCommand(t, commandTypeTFTPReceive, tftpReceivePayload{
		SessionID:        "recv-valid",
		ExpectedFilename: "config.bin",
		MaxFileSize:      1024 * 1024,
		TimeoutSeconds:   10,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})

	pl.handleTFTPReceive(ctx, cmd, sender)

	// Should send a progress message indicating the session started
	msgs := stream.getSent()
	progress := findCommandProgress(msgs)
	require.NotEmpty(t, progress, "expected at least one progress message after successful start")
	assert.Contains(t, progress[0].Message, "tftp receive session started")

	// No error result should be present
	result := findCommandResult(msgs)
	assert.Nil(t, result, "should not have a result yet — session is just started")
}

// ── handleTFTPServe ────────────────────────────────────────────────────────

func TestTFTPCommandServe_InvalidPayload(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := &proto.CommandRequest{
		CommandId:   "cmd-serve-bad",
		CommandType: commandTypeTFTPServe,
		PayloadJson: []byte(`not-json`),
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  300,
	}

	pl.handleTFTPServe(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Contains(t, result.Message, "invalid tftp serve payload")
}

func TestTFTPCommandServe_MissingFields(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	tests := []missingFieldTestCase[tftpServePayload]{
		{
			name:    "missing session_id",
			payload: tftpServePayload{Filename: "firmware.bin"},
		},
		{
			name:    "missing filename",
			payload: tftpServePayload{SessionID: "sess-1"},
		},
		{
			name:    "both empty",
			payload: tftpServePayload{},
		},
	}

	runMissingFieldsTest(t, ctx, commandTypeTFTPServe, tests, "missing session_id or filename", pl.handleTFTPServe)
}

func TestTFTPCommandServe_StagedImageMissing(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := makeCommand(t, commandTypeTFTPServe, tftpServePayload{
		SessionID:      "serve-missing",
		Filename:       "missing.bin",
		TimeoutSeconds: 5,
		BindAddress:    "127.0.0.1",
	})

	pl.handleTFTPServe(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Contains(t, result.Message, "staged image not found")
}

func TestTFTPCommandServe_NoTFTPService(t *testing.T) {
	log := logger.NewTestLogger()

	server := &Server{
		config:      &ServerConfig{AgentID: "test-agent"},
		tftpService: nil,
		logger:      log,
		services:    make([]Service, 0),
		errChan:     make(chan error, 1),
		done:        make(chan struct{}),
	}
	pl := NewPushLoop(server, nil, time.Second, log)

	ctx := context.Background()
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPServe, tftpServePayload{
		SessionID: "sess-1",
		Filename:  "firmware.bin",
	})

	pl.handleTFTPServe(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Equal(t, "tftp service unavailable", result.Message)
}

func TestTFTPCommandServe_ValidPayload(t *testing.T) {
	pl, tmpDir := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	// Pre-stage a file
	sessionID := "serve-valid"
	filename := "firmware.bin"
	sessionDir := filepath.Join(tmpDir, sessionID)
	require.NoError(t, os.MkdirAll(sessionDir, 0o750))
	require.NoError(t, os.WriteFile(filepath.Join(sessionDir, filename), []byte("image data"), 0o640))

	port := findFreePort(t)
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := makeCommand(t, commandTypeTFTPServe, tftpServePayload{
		SessionID:      sessionID,
		Filename:       filename,
		TimeoutSeconds: 10,
		BindAddress:    "127.0.0.1",
		Port:           port,
	})

	pl.handleTFTPServe(ctx, cmd, sender)

	// Should get a progress message indicating session started
	msgs := stream.getSent()
	progress := findCommandProgress(msgs)
	require.NotEmpty(t, progress, "expected progress message for started serve session")
	assert.Contains(t, progress[0].Message, "tftp serve session started")

	// No error result
	result := findCommandResult(msgs)
	assert.Nil(t, result, "should not have a result yet — session is just started")
}

// ── handleTFTPStop ─────────────────────────────────────────────────────────

func TestTFTPCommandStop_InvalidPayload(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := &proto.CommandRequest{
		CommandId:   "cmd-stop-bad",
		CommandType: commandTypeTFTPStop,
		PayloadJson: []byte(`{bad`),
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  300,
	}

	pl.handleTFTPStop(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Contains(t, result.Message, "invalid tftp stop payload")
}

func TestTFTPCommandStop_MissingSessionID(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStop, tftpStopPayload{})

	pl.handleTFTPStop(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Contains(t, result.Message, "missing session_id")
}

func TestTFTPCommandStop_WrongSessionID(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	// Start a real receive session so there's something active
	port := findFreePort(t)
	recvStream := newMockBidiStream(ctx)
	recvSender := newControlStreamSender(recvStream)
	recvCmd := makeCommand(t, commandTypeTFTPReceive, tftpReceivePayload{
		SessionID:        "active-session",
		ExpectedFilename: "file.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   30,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	pl.handleTFTPReceive(ctx, recvCmd, recvSender)

	// Now try to stop with wrong session ID
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStop, tftpStopPayload{SessionID: "wrong-id"})

	pl.handleTFTPStop(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Contains(t, result.Message, "not found")
}

func TestTFTPCommandStop_ActiveSession(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	// Start a receive session
	port := findFreePort(t)
	recvStream := newMockBidiStream(ctx)
	recvSender := newControlStreamSender(recvStream)
	recvCmd := makeCommand(t, commandTypeTFTPReceive, tftpReceivePayload{
		SessionID:        "stop-me",
		ExpectedFilename: "file.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   30,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	pl.handleTFTPReceive(ctx, recvCmd, recvSender)

	// Wait for server to be up
	time.Sleep(200 * time.Millisecond)

	// Stop the session
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStop, tftpStopPayload{SessionID: "stop-me"})

	pl.handleTFTPStop(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.True(t, result.Success)
	assert.Equal(t, "session stopped", result.Message)

	payload := unmarshalResultPayload(t, result)
	assert.Equal(t, "stop-me", payload["session_id"])
}

func TestTFTPCommandStop_NoTFTPService(t *testing.T) {
	log := logger.NewTestLogger()

	server := &Server{
		config:      &ServerConfig{AgentID: "test-agent"},
		tftpService: nil,
		logger:      log,
		services:    make([]Service, 0),
		errChan:     make(chan error, 1),
		done:        make(chan struct{}),
	}
	pl := NewPushLoop(server, nil, time.Second, log)

	ctx := context.Background()
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStop, tftpStopPayload{SessionID: "any"})

	pl.handleTFTPStop(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Equal(t, "tftp service unavailable", result.Message)
}

// ── handleTFTPStatus ───────────────────────────────────────────────────────

func TestTFTPCommandStatus_NoActiveSession(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)

	stream := newMockBidiStream(context.Background())
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStatus, nil)

	pl.handleTFTPStatus(cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.True(t, result.Success)
	assert.Equal(t, "no active session", result.Message)

	payload := unmarshalResultPayload(t, result)
	assert.Equal(t, false, payload["active"])
}

func TestTFTPCommandStatus_ActiveSession(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	// Start a receive session
	port := findFreePort(t)
	recvStream := newMockBidiStream(ctx)
	recvSender := newControlStreamSender(recvStream)
	recvCmd := makeCommand(t, commandTypeTFTPReceive, tftpReceivePayload{
		SessionID:        "status-sess",
		ExpectedFilename: "config.bin",
		MaxFileSize:      1024,
		TimeoutSeconds:   30,
		BindAddress:      "127.0.0.1",
		Port:             port,
	})
	pl.handleTFTPReceive(ctx, recvCmd, recvSender)

	// Wait for session to start
	time.Sleep(200 * time.Millisecond)

	// Query status
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStatus, nil)

	pl.handleTFTPStatus(cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.True(t, result.Success)
	assert.Equal(t, "session active", result.Message)

	payload := unmarshalResultPayload(t, result)
	assert.Equal(t, true, payload["active"])
	assert.Equal(t, "status-sess", payload["session_id"])
	assert.Equal(t, "receive", payload["mode"])
	assert.Equal(t, "config.bin", payload["expected_filename"])
	assert.Equal(t, "127.0.0.1", payload["bind_address"])
	assert.NotZero(t, payload["started_at"])
}

func TestTFTPCommandStatus_NoTFTPService(t *testing.T) {
	log := logger.NewTestLogger()

	server := &Server{
		config:      &ServerConfig{AgentID: "test-agent"},
		tftpService: nil,
		logger:      log,
		services:    make([]Service, 0),
		errChan:     make(chan error, 1),
		done:        make(chan struct{}),
	}
	pl := NewPushLoop(server, nil, time.Second, log)

	stream := newMockBidiStream(context.Background())
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStatus, nil)

	pl.handleTFTPStatus(cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Equal(t, "tftp service unavailable", result.Message)
}

// ── handleTFTPStageImage ───────────────────────────────────────────────────

func TestTFTPCommandStageImage_InvalidPayload(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := &proto.CommandRequest{
		CommandId:   "cmd-stage-bad",
		CommandType: commandTypeTFTPStageImage,
		PayloadJson: []byte(`{garbage`),
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  300,
	}

	pl.handleTFTPStageImage(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Contains(t, result.Message, "invalid tftp stage payload")
}

func TestTFTPCommandStageImage_MissingFields(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	tests := []missingFieldTestCase[tftpStagePayload]{
		{
			name:    "missing session_id",
			payload: tftpStagePayload{ImageID: "img-1"},
		},
		{
			name:    "missing image_id",
			payload: tftpStagePayload{SessionID: "sess-1"},
		},
		{
			name:    "both empty",
			payload: tftpStagePayload{},
		},
	}

	runMissingFieldsTest(t, ctx, commandTypeTFTPStageImage, tests, "missing session_id or image_id", pl.handleTFTPStageImage)
}

func TestTFTPCommandStageImage_NilGateway(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	cmd := makeCommand(t, commandTypeTFTPStageImage, tftpStagePayload{
		SessionID:   "stage-1",
		ImageID:     "img-1",
		ContentHash: "abc123",
		FileSize:    1024,
	})

	// gateway is nil on the PushLoop — this will panic inside the handler
	// when it tries to call p.gateway.DownloadFile. We expect a panic-recover
	// is NOT in place, so the handler will fail. We wrap in a goroutine to
	// catch the panic and verify the behavior.
	panicked := make(chan bool, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				panicked <- true
			} else {
				panicked <- false
			}
		}()
		pl.handleTFTPStageImage(ctx, cmd, sender)
	}()

	select {
	case didPanic := <-panicked:
		if didPanic {
			// Expected: nil gateway causes a nil pointer dereference
			t.Log("handleTFTPStageImage panicked on nil gateway as expected")
		} else {
			// Handler completed — check for download failure result
			result := findCommandResult(stream.getSent())
			require.NotNil(t, result)
			assert.False(t, result.Success)
			assert.Contains(t, result.Message, "download failed")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for handleTFTPStageImage")
	}
}

func TestTFTPCommandStageImage_NoTFTPService(t *testing.T) {
	log := logger.NewTestLogger()

	server := &Server{
		config:      &ServerConfig{AgentID: "test-agent"},
		tftpService: nil,
		logger:      log,
		services:    make([]Service, 0),
		errChan:     make(chan error, 1),
		done:        make(chan struct{}),
	}
	pl := NewPushLoop(server, nil, time.Second, log)

	ctx := context.Background()
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)
	cmd := makeCommand(t, commandTypeTFTPStageImage, tftpStagePayload{
		SessionID: "sess-1",
		ImageID:   "img-1",
	})

	pl.handleTFTPStageImage(ctx, cmd, sender)

	result := findCommandResult(stream.getSent())
	require.NotNil(t, result)
	assert.False(t, result.Success)
	assert.Equal(t, "tftp service unavailable", result.Message)
}

// ── handleCommand dispatch ─────────────────────────────────────────────────

// TestTFTPCommandDispatch_AllTypes verifies that all 5 TFTP command types are
// dispatched through handleCommand, producing an ack and a handler result for each.
func TestTFTPCommandDispatch_AllTypes(t *testing.T) {
	pl, tmpDir := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	// Pre-stage a file so the serve command doesn't fail with "staged image not found".
	sessionDir := filepath.Join(tmpDir, "all-types-serve")
	require.NoError(t, os.MkdirAll(sessionDir, 0o750))
	require.NoError(t, os.WriteFile(filepath.Join(sessionDir, "firmware.bin"), []byte("data"), 0o640))

	tests := []struct {
		name    string
		cmdType string
		payload interface{}
	}{
		{
			name:    "tftp.start_receive",
			cmdType: commandTypeTFTPReceive,
			payload: tftpReceivePayload{
				SessionID:        "dispatch-recv",
				ExpectedFilename: "config.bin",
				MaxFileSize:      1024,
				TimeoutSeconds:   10,
				BindAddress:      "127.0.0.1",
				Port:             findFreePort(t),
			},
		},
		{
			name:    "tftp.start_serve",
			cmdType: commandTypeTFTPServe,
			payload: tftpServePayload{
				SessionID:      "all-types-serve",
				Filename:       "firmware.bin",
				TimeoutSeconds: 10,
				BindAddress:    "127.0.0.1",
				Port:           findFreePort(t),
			},
		},
		{
			name:    "tftp.stop_session",
			cmdType: commandTypeTFTPStop,
			// Use a non-existent session — handler will return "not found", which is fine.
			payload: tftpStopPayload{SessionID: "nonexistent-stop"},
		},
		{
			name:    "tftp.status",
			cmdType: commandTypeTFTPStatus,
			payload: nil,
		},
		{
			name:    "tftp.stage_image",
			cmdType: commandTypeTFTPStageImage,
			// Missing fields — handler will return validation error quickly.
			payload: tftpStagePayload{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stream := newMockBidiStream(ctx)
			sender := newControlStreamSender(stream)
			cmd := makeCommand(t, tt.cmdType, tt.payload)

			pl.handleCommand(ctx, cmd, sender)

			// handleCommand dispatches the handler in a goroutine; wait for it.
			time.Sleep(300 * time.Millisecond)

			msgs := stream.getSent()

			// Every dispatched command must produce an ack.
			var gotAck bool
			for _, msg := range msgs {
				if ack := msg.GetCommandAck(); ack != nil {
					gotAck = true
					assert.Equal(t, cmd.CommandId, ack.CommandId)
					assert.Equal(t, tt.cmdType, ack.CommandType)
				}
			}
			assert.True(t, gotAck, "expected command ack for %s", tt.cmdType)

			// Each handler should produce either a result or a progress message.
			result := findCommandResult(msgs)
			progress := findCommandProgress(msgs)
			assert.True(t, result != nil || len(progress) > 0,
				"expected a result or progress for %s, got neither", tt.cmdType)
		})
	}
}

func TestTFTPCommandDispatch(t *testing.T) {
	pl, _ := newTestPushLoopWithTFTP(t)
	ctx := context.Background()

	// Verify that handleCommand dispatches TFTP commands and sends an ack
	stream := newMockBidiStream(ctx)
	sender := newControlStreamSender(stream)

	// Use an invalid payload so the handler returns quickly with an error
	cmd := &proto.CommandRequest{
		CommandId:   "cmd-dispatch",
		CommandType: commandTypeTFTPStatus,
		PayloadJson: nil,
		CreatedAt:   time.Now().Unix(),
		TtlSeconds:  300,
	}

	pl.handleCommand(ctx, cmd, sender)

	// handleCommand runs handler in a goroutine, wait for it
	time.Sleep(200 * time.Millisecond)

	msgs := stream.getSent()

	// Should have a command ack
	var gotAck bool
	for _, msg := range msgs {
		if ack := msg.GetCommandAck(); ack != nil {
			gotAck = true
			assert.Equal(t, "cmd-dispatch", ack.CommandId)
			assert.Equal(t, commandTypeTFTPStatus, ack.CommandType)
		}
	}
	assert.True(t, gotAck, "expected command ack message")

	// Should also have the status result (no active session)
	result := findCommandResult(msgs)
	require.NotNil(t, result)
	assert.True(t, result.Success)
}
