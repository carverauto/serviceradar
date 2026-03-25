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
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errCameraRelayGatewayUnavailable = errors.New("camera relay gateway unavailable")
	errCameraRelaySessionExists      = errors.New("camera relay session already active")
	errCameraRelaySessionNotFound    = errors.New("camera relay session not found")
	errCameraRelayDrainRequested     = errors.New("camera relay drain requested")
	errCameraRelayPluginUnavailable  = errors.New("camera relay streaming plugin unavailable")
	errCameraRelaySessionIDRequired  = errors.New("relay_session_id is required")
	errCameraRelayAgentIDRequired    = errors.New("agent_id is required")
	errCameraRelaySourceIDRequired   = errors.New("camera_source_id is required")
	errCameraRelayProfileIDRequired  = errors.New("stream_profile_id is required")
	errCameraRelayLeaseTokenRequired = errors.New("lease_token is required")
)

const (
	defaultCameraRelayCloseTimeout = 10 * time.Second
	defaultCameraRelayUploadBatch  = 8
)

type cameraRelayStartPayload struct {
	RelaySessionID     string `json:"relay_session_id"`
	CameraSourceID     string `json:"camera_source_id"`
	StreamProfileID    string `json:"stream_profile_id"`
	LeaseToken         string `json:"lease_token"`
	PluginAssignmentID string `json:"plugin_assignment_id,omitempty"`
	SourceURL          string `json:"source_url,omitempty"`
	RTSPTransport      string `json:"rtsp_transport,omitempty"`
	CodecHint          string `json:"codec_hint,omitempty"`
	ContainerHint      string `json:"container_hint,omitempty"`
}

type cameraRelayStopPayload struct {
	RelaySessionID string `json:"relay_session_id"`
	Reason         string `json:"reason,omitempty"`
}

type cameraRelaySessionSpec struct {
	RelaySessionID     string
	MediaIngestID      string
	AgentID            string
	GatewayID          string
	CameraSourceID     string
	StreamProfileID    string
	LeaseToken         string
	PluginAssignmentID string
	SourceURL          string
	RTSPTransport      string
	CodecHint          string
	ContainerHint      string
}

type cameraRelaySessionState struct {
	RelaySessionID     string
	MediaIngestID      string
	LeaseExpiresAtUnix int64
}

type cameraRelayChunk struct {
	TrackID       string
	Payload       []byte
	Sequence      uint64
	PTS           int64
	DTS           int64
	Keyframe      bool
	IsFinal       bool
	Codec         string
	PayloadFormat string
}

type cameraRelayChunkStream interface {
	Recv(context.Context) (*cameraRelayChunk, error)
	Close() error
}

type cameraRelaySourceFactory func(cameraRelaySessionSpec) (cameraRelayChunkStream, error)

type cameraRelayGateway interface {
	GetGatewayID() string
	OpenRelaySession(context.Context, *proto.OpenRelaySessionRequest) (*proto.OpenRelaySessionResponse, error)
	UploadMedia(context.Context, []*proto.MediaChunk) (*proto.UploadMediaResponse, error)
	HeartbeatRelaySession(context.Context, *proto.RelayHeartbeat) (*proto.RelayHeartbeatAck, error)
	CloseRelaySession(context.Context, *proto.CloseRelaySessionRequest) (*proto.CloseRelaySessionResponse, error)
}

type cameraRelayHandle struct {
	cancel        context.CancelFunc
	done          chan struct{}
	agentID       string
	mediaIngestID string
	closeOnce     sync.Once
}

type cameraRelayManager struct {
	mu                  sync.Mutex
	sessions            map[string]*cameraRelayHandle
	gateway             cameraRelayGateway
	sourceFactory       cameraRelaySourceFactory
	pluginSourceFactory func(context.Context, cameraRelaySessionSpec) (cameraRelayChunkStream, error)
	logger              logger.Logger
	uploadBatchSize     int
}

func newCameraRelayManager(gateway cameraRelayGateway, log logger.Logger) *cameraRelayManager {
	return &cameraRelayManager{
		sessions:        make(map[string]*cameraRelayHandle),
		gateway:         gateway,
		sourceFactory:   defaultCameraRelaySource,
		logger:          log,
		uploadBatchSize: defaultCameraRelayUploadBatch,
	}
}

func (m *cameraRelayManager) Start(ctx context.Context, spec cameraRelaySessionSpec) (*cameraRelaySessionState, error) {
	if m == nil {
		return nil, errCameraRelayGatewayUnavailable
	}

	spec, err := normalizeCameraRelaySpec(spec)
	if err != nil {
		return nil, err
	}

	if m.gateway == nil {
		return nil, errCameraRelayGatewayUnavailable
	}

	if spec.GatewayID == "" {
		spec.GatewayID = strings.TrimSpace(m.gateway.GetGatewayID())
	}

	handle := &cameraRelayHandle{
		done:    make(chan struct{}),
		agentID: spec.AgentID,
	}

	if err := m.registerSession(spec.RelaySessionID, handle); err != nil {
		return nil, err
	}

	openResp, err := m.gateway.OpenRelaySession(ctx, &proto.OpenRelaySessionRequest{
		RelaySessionId:  spec.RelaySessionID,
		AgentId:         spec.AgentID,
		GatewayId:       spec.GatewayID,
		CameraSourceId:  spec.CameraSourceID,
		StreamProfileId: spec.StreamProfileID,
		LeaseToken:      spec.LeaseToken,
		CodecHint:       spec.CodecHint,
		ContainerHint:   spec.ContainerHint,
	})
	if err != nil {
		m.unregisterSession(spec.RelaySessionID, handle)
		return nil, fmt.Errorf("open relay session: %w", err)
	}

	spec.MediaIngestID = strings.TrimSpace(openResp.GetMediaIngestId())
	handle.mediaIngestID = spec.MediaIngestID

	m.logger.Info().
		Str("relay_session_id", spec.RelaySessionID).
		Str("media_ingest_id", spec.MediaIngestID).
		Str("agent_id", spec.AgentID).
		Str("gateway_id", spec.GatewayID).
		Str("camera_source_id", spec.CameraSourceID).
		Str("stream_profile_id", spec.StreamProfileID).
		Msg("Camera relay upstream session accepted")

	stream, err := m.openSource(ctx, spec)
	if err != nil {
		m.closeUpstream(spec, handle, "source_start_failed")
		m.unregisterSession(spec.RelaySessionID, handle)
		return nil, err
	}

	runCtx, cancel := context.WithCancel(ctx)
	handle.cancel = cancel
	go m.runSession(runCtx, spec, handle, stream)

	return &cameraRelaySessionState{
		RelaySessionID:     spec.RelaySessionID,
		MediaIngestID:      spec.MediaIngestID,
		LeaseExpiresAtUnix: openResp.GetLeaseExpiresAtUnix(),
	}, nil
}

func (m *cameraRelayManager) Stop(ctx context.Context, payload cameraRelayStopPayload) error {
	if m == nil {
		return errCameraRelaySessionNotFound
	}

	relaySessionID := strings.TrimSpace(payload.RelaySessionID)
	if relaySessionID == "" {
		return errCameraRelaySessionIDRequired
	}

	reason := strings.TrimSpace(payload.Reason)
	if reason == "" {
		reason = "camera relay stopped"
	}

	handle := m.lookupSession(relaySessionID)
	if handle == nil {
		return errCameraRelaySessionNotFound
	}

	m.closeUpstream(cameraRelaySessionSpec{
		RelaySessionID: relaySessionID,
		MediaIngestID:  handle.mediaIngestID,
		AgentID:        handle.agentID,
	}, handle, reason)

	if handle.cancel != nil {
		handle.cancel()
	}

	if ctx == nil {
		return nil
	}

	select {
	case <-handle.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *cameraRelayManager) runSession(
	ctx context.Context,
	spec cameraRelaySessionSpec,
	handle *cameraRelayHandle,
	stream cameraRelayChunkStream,
) {
	defer close(handle.done)
	defer m.unregisterSession(spec.RelaySessionID, handle)
	defer func() {
		if err := stream.Close(); err != nil {
			m.logger.Debug().Err(err).Str("relay_session_id", spec.RelaySessionID).Msg("Camera relay source close returned error")
		}
	}()

	closeReason := "camera relay completed"
	defer func() {
		m.logger.Info().
			Str("relay_session_id", spec.RelaySessionID).
			Str("media_ingest_id", spec.MediaIngestID).
			Str("close_reason", closeReason).
			Msg("Camera relay session stopping")
		m.closeUpstream(spec, handle, closeReason)
	}()

	batch := make([]*proto.MediaChunk, 0, m.batchSize())
	var (
		lastSequence uint64
		sentBytes    uint64
	)

	flush := func() error {
		if len(batch) == 0 {
			return nil
		}

		resp, err := m.gateway.UploadMedia(ctx, batch)
		if err != nil {
			return fmt.Errorf("upload media: %w", err)
		}
		if relayDrainRequested(resp.GetMessage()) {
			return errCameraRelayDrainRequested
		}

		if resp != nil && resp.GetLastSequence() > lastSequence {
			lastSequence = resp.GetLastSequence()
		}

		for _, chunk := range batch {
			sentBytes += uint64(len(chunk.GetPayload()))
			if chunk.GetSequence() > lastSequence {
				lastSequence = chunk.GetSequence()
			}
		}

		heartbeatResp, err := m.gateway.HeartbeatRelaySession(ctx, &proto.RelayHeartbeat{
			RelaySessionId: spec.RelaySessionID,
			MediaIngestId:  spec.MediaIngestID,
			AgentId:        spec.AgentID,
			LastSequence:   lastSequence,
			SentBytes:      sentBytes,
			TimestampUnix:  time.Now().Unix(),
		})
		if err != nil {
			return fmt.Errorf("heartbeat relay session: %w", err)
		}
		if relayDrainRequested(heartbeatResp.GetMessage()) {
			return errCameraRelayDrainRequested
		}

		batch = batch[:0]
		return nil
	}

	for {
		chunk, err := stream.Recv(ctx)
		switch {
		case err == nil:
			batch = append(batch, buildMediaChunk(spec, chunk))
			if chunk.IsFinal || len(batch) >= m.batchSize() {
				if err := flush(); err != nil {
					if errors.Is(err, errCameraRelayDrainRequested) {
						closeReason = "camera relay drain acknowledged"
						m.logger.Info().
							Str("relay_session_id", spec.RelaySessionID).
							Str("media_ingest_id", spec.MediaIngestID).
							Msg("Camera relay drain acknowledged by upstream")
						return
					}
					closeReason = "camera relay upload failed"
					m.logger.Warn().Err(err).Str("relay_session_id", spec.RelaySessionID).Msg("Camera relay upload failed")
					return
				}
			}
			if chunk.IsFinal {
				closeReason = "camera relay source completed"
				return
			}

		case errors.Is(err, io.EOF):
			if err := flush(); err != nil {
				closeReason = "camera relay upload failed"
				m.logger.Warn().Err(err).Str("relay_session_id", spec.RelaySessionID).Msg("Camera relay upload failed")
				return
			}
			closeReason = "camera relay source EOF"
			return

		case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
			closeReason = "camera relay cancelled"
			return

		default:
			closeReason = "camera relay source failed"
			m.logger.Warn().Err(err).Str("relay_session_id", spec.RelaySessionID).Msg("Camera relay source failed")
			return
		}
	}
}

func (m *cameraRelayManager) closeUpstream(spec cameraRelaySessionSpec, handle *cameraRelayHandle, reason string) {
	if m == nil || m.gateway == nil || handle == nil {
		return
	}

	handle.closeOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), defaultCameraRelayCloseTimeout)
		defer cancel()

		_, err := m.gateway.CloseRelaySession(ctx, &proto.CloseRelaySessionRequest{
			RelaySessionId: spec.RelaySessionID,
			MediaIngestId:  spec.MediaIngestID,
			AgentId:        spec.AgentID,
			Reason:         reason,
		})
		if err != nil {
			m.logger.Warn().
				Err(err).
				Str("relay_session_id", spec.RelaySessionID).
				Str("reason", reason).
				Msg("Failed to close upstream camera relay session")
			return
		}

		m.logger.Info().
			Str("relay_session_id", spec.RelaySessionID).
			Str("media_ingest_id", spec.MediaIngestID).
			Str("reason", reason).
			Msg("Closed upstream camera relay session")
	})
}

func (m *cameraRelayManager) registerSession(relaySessionID string, handle *cameraRelayHandle) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.sessions[relaySessionID]; exists {
		return errCameraRelaySessionExists
	}

	m.sessions[relaySessionID] = handle
	return nil
}

func (m *cameraRelayManager) unregisterSession(relaySessionID string, handle *cameraRelayHandle) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if current, exists := m.sessions[relaySessionID]; exists && current == handle {
		delete(m.sessions, relaySessionID)
	}
}

func (m *cameraRelayManager) lookupSession(relaySessionID string) *cameraRelayHandle {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.sessions[relaySessionID]
}

func (m *cameraRelayManager) batchSize() int {
	if m == nil || m.uploadBatchSize <= 0 {
		return defaultCameraRelayUploadBatch
	}
	return m.uploadBatchSize
}

func (m *cameraRelayManager) openSource(ctx context.Context, spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
	if strings.TrimSpace(spec.PluginAssignmentID) != "" {
		if m == nil || m.pluginSourceFactory == nil {
			return nil, errCameraRelayPluginUnavailable
		}
		return m.pluginSourceFactory(ctx, spec)
	}

	if m == nil || m.sourceFactory == nil {
		return nil, errCameraRelayPluginUnavailable
	}
	return m.sourceFactory(spec)
}

func normalizeCameraRelaySpec(spec cameraRelaySessionSpec) (cameraRelaySessionSpec, error) {
	spec.RelaySessionID = strings.TrimSpace(spec.RelaySessionID)
	spec.MediaIngestID = strings.TrimSpace(spec.MediaIngestID)
	spec.AgentID = strings.TrimSpace(spec.AgentID)
	spec.GatewayID = strings.TrimSpace(spec.GatewayID)
	spec.CameraSourceID = strings.TrimSpace(spec.CameraSourceID)
	spec.StreamProfileID = strings.TrimSpace(spec.StreamProfileID)
	spec.LeaseToken = strings.TrimSpace(spec.LeaseToken)
	spec.PluginAssignmentID = strings.TrimSpace(spec.PluginAssignmentID)
	spec.SourceURL = strings.TrimSpace(spec.SourceURL)
	spec.RTSPTransport = strings.TrimSpace(spec.RTSPTransport)
	spec.CodecHint = strings.TrimSpace(spec.CodecHint)
	spec.ContainerHint = strings.TrimSpace(spec.ContainerHint)

	switch {
	case spec.RelaySessionID == "":
		return spec, errCameraRelaySessionIDRequired
	case spec.AgentID == "":
		return spec, errCameraRelayAgentIDRequired
	case spec.CameraSourceID == "":
		return spec, errCameraRelaySourceIDRequired
	case spec.StreamProfileID == "":
		return spec, errCameraRelayProfileIDRequired
	case spec.LeaseToken == "":
		return spec, errCameraRelayLeaseTokenRequired
	default:
		return spec, nil
	}
}

func buildMediaChunk(spec cameraRelaySessionSpec, chunk *cameraRelayChunk) *proto.MediaChunk {
	codec := strings.TrimSpace(chunk.Codec)
	if codec == "" {
		codec = spec.CodecHint
	}

	return &proto.MediaChunk{
		RelaySessionId: spec.RelaySessionID,
		MediaIngestId:  spec.MediaIngestID,
		AgentId:        spec.AgentID,
		TrackId:        chunk.TrackID,
		Payload:        chunk.Payload,
		Sequence:       chunk.Sequence,
		Pts:            chunk.PTS,
		Dts:            chunk.DTS,
		Keyframe:       chunk.Keyframe,
		IsFinal:        chunk.IsFinal,
		Codec:          codec,
		PayloadFormat:  chunk.PayloadFormat,
	}
}

func relayDrainRequested(message string) bool {
	return strings.Contains(strings.ToLower(strings.TrimSpace(message)), "drain")
}
