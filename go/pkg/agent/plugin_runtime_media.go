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
	"errors"
	"io"
	"strings"
	"sync"

	"github.com/tetratelabs/wazero/api"
)

type pluginCameraMediaOpenRequest struct {
	TrackID       string `json:"track_id,omitempty"`
	Codec         string `json:"codec,omitempty"`
	PayloadFormat string `json:"payload_format,omitempty"`
}

type pluginCameraMediaChunkMetadata struct {
	TrackID       string `json:"track_id,omitempty"`
	Sequence      uint64 `json:"sequence,omitempty"`
	PTS           int64  `json:"pts,omitempty"`
	DTS           int64  `json:"dts,omitempty"`
	Keyframe      bool   `json:"keyframe,omitempty"`
	IsFinal       bool   `json:"is_final,omitempty"`
	Codec         string `json:"codec,omitempty"`
	PayloadFormat string `json:"payload_format,omitempty"`
}

type pluginCameraMediaHeartbeat struct {
	Sequence      uint64 `json:"sequence,omitempty"`
	TimestampUnix int64  `json:"timestamp_unix,omitempty"`
}

type pluginCameraRelayStream struct {
	cancel context.CancelFunc
	chunks chan *cameraRelayChunk

	closeOnce sync.Once
	mu        sync.Mutex
	err       error
}

type pluginCameraMediaBridge struct {
	mu            sync.Mutex
	stream        *pluginCameraRelayStream
	handle        uint32
	opened        bool
	closed        bool
	lastHeartbeat pluginCameraMediaHeartbeat
	openRequest   pluginCameraMediaOpenRequest
}

func newPluginCameraRelayStream(cancel context.CancelFunc) *pluginCameraRelayStream {
	return &pluginCameraRelayStream{
		cancel: cancel,
		chunks: make(chan *cameraRelayChunk, defaultCameraRelayUploadBatch*2),
	}
}

func (s *pluginCameraRelayStream) Recv(ctx context.Context) (*cameraRelayChunk, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case chunk, ok := <-s.chunks:
		if !ok {
			return nil, s.terminalErr()
		}
		return chunk, nil
	}
}

func (s *pluginCameraRelayStream) Close() error {
	if s.cancel != nil {
		s.cancel()
	}
	s.finish(io.EOF)
	return nil
}

func (s *pluginCameraRelayStream) finish(err error) {
	s.closeOnce.Do(func() {
		s.mu.Lock()
		s.err = err
		s.mu.Unlock()
		close(s.chunks)
	})
}

func (s *pluginCameraRelayStream) terminalErr() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err == nil {
		return io.EOF
	}
	return s.err
}

func newPluginCameraMediaBridge(stream *pluginCameraRelayStream) *pluginCameraMediaBridge {
	return &pluginCameraMediaBridge{
		stream: stream,
		handle: 1,
	}
}

func (b *pluginCameraMediaBridge) Open(_ context.Context, req pluginCameraMediaOpenRequest) (uint32, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.closed {
		return 0, errCameraRelayPluginUnavailable
	}
	b.opened = true
	b.openRequest = req
	return b.handle, nil
}

func (b *pluginCameraMediaBridge) Write(
	ctx context.Context,
	handle uint32,
	payload []byte,
	meta pluginCameraMediaChunkMetadata,
) (int, error) {
	b.mu.Lock()
	if !b.isValidHandleLocked(handle) {
		b.mu.Unlock()
		return 0, errCameraRelaySessionNotFound
	}
	stream := b.stream
	b.mu.Unlock()

	chunk := &cameraRelayChunk{
		TrackID:       chooseNonEmpty(meta.TrackID, b.openRequest.TrackID),
		Payload:       append([]byte(nil), payload...),
		Sequence:      meta.Sequence,
		PTS:           meta.PTS,
		DTS:           meta.DTS,
		Keyframe:      meta.Keyframe,
		IsFinal:       meta.IsFinal,
		Codec:         chooseNonEmpty(meta.Codec, b.openRequest.Codec),
		PayloadFormat: chooseNonEmpty(meta.PayloadFormat, b.openRequest.PayloadFormat),
	}

	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case stream.chunks <- chunk:
		if meta.IsFinal {
			b.finish(io.EOF)
		}
		return len(payload), nil
	}
}

func (b *pluginCameraMediaBridge) Heartbeat(handle uint32, heartbeat pluginCameraMediaHeartbeat) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.isValidHandleLocked(handle) {
		return errCameraRelaySessionNotFound
	}
	b.lastHeartbeat = heartbeat
	return nil
}

func (b *pluginCameraMediaBridge) Close(handle uint32, _reason string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.isValidHandleLocked(handle) {
		return errCameraRelaySessionNotFound
	}
	b.finishLocked(io.EOF)
	return nil
}

func (b *pluginCameraMediaBridge) hasOpened() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.opened
}

func (b *pluginCameraMediaBridge) finish(err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.finishLocked(err)
}

func (b *pluginCameraMediaBridge) finishLocked(err error) {
	if b.closed {
		return
	}
	b.closed = true
	if b.stream != nil {
		b.stream.finish(err)
	}
}

func (b *pluginCameraMediaBridge) isValidHandleLocked(handle uint32) bool {
	return b.opened && !b.closed && handle == b.handle
}

func decodeCameraMediaOpenRequest(mod api.Module, ptr, size uint32) (pluginCameraMediaOpenRequest, int32) {
	if size == 0 {
		return pluginCameraMediaOpenRequest{}, pluginErrOK
	}
	raw, ok := readMemory(mod, ptr, size)
	if !ok {
		return pluginCameraMediaOpenRequest{}, pluginErrInvalid
	}
	var request pluginCameraMediaOpenRequest
	if err := json.Unmarshal(raw, &request); err != nil {
		return pluginCameraMediaOpenRequest{}, pluginErrInvalid
	}
	return request, pluginErrOK
}

func decodeCameraMediaChunkMetadata(mod api.Module, ptr, size uint32) (pluginCameraMediaChunkMetadata, int32) {
	if size == 0 {
		return pluginCameraMediaChunkMetadata{}, pluginErrOK
	}
	raw, ok := readMemory(mod, ptr, size)
	if !ok {
		return pluginCameraMediaChunkMetadata{}, pluginErrInvalid
	}
	var meta pluginCameraMediaChunkMetadata
	if err := json.Unmarshal(raw, &meta); err != nil {
		return pluginCameraMediaChunkMetadata{}, pluginErrInvalid
	}
	return meta, pluginErrOK
}

func decodeCameraMediaHeartbeat(mod api.Module, ptr, size uint32) (pluginCameraMediaHeartbeat, int32) {
	if size == 0 {
		return pluginCameraMediaHeartbeat{}, pluginErrOK
	}
	raw, ok := readMemory(mod, ptr, size)
	if !ok {
		return pluginCameraMediaHeartbeat{}, pluginErrInvalid
	}
	var heartbeat pluginCameraMediaHeartbeat
	if err := json.Unmarshal(raw, &heartbeat); err != nil {
		return pluginCameraMediaHeartbeat{}, pluginErrInvalid
	}
	return heartbeat, pluginErrOK
}

func pluginCameraMediaErrorCode(err error) int32 {
	switch {
	case err == nil:
		return pluginErrOK
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
		return pluginErrTimeout
	case errors.Is(err, errCameraRelaySessionNotFound):
		return pluginErrBadHandle
	default:
		return pluginErrInternal
	}
}

func chooseNonEmpty(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value != "" {
		return value
	}
	return strings.TrimSpace(fallback)
}
