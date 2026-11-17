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
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
	"github.com/google/uuid"
)

var (
	errCameraRelayGatewayUnavailable  = errors.New("camera relay gateway unavailable")
	errCameraRelaySessionExists       = errors.New("camera relay session already active")
	errCameraRelaySourceActive        = errors.New("camera source profile already active")
	errCameraRelaySessionNotFound     = errors.New("camera relay session not found")
	errCameraRelayIncarnationMismatch = errors.New("camera relay source incarnation mismatch")
	errCameraRelayDrainRequested      = errors.New("camera relay drain requested")
	errCameraRelayPluginUnavailable   = errors.New("camera relay streaming plugin unavailable")
	errCameraRelaySessionIDRequired   = errors.New("relay_session_id is required")
	errCameraRelayAgentIDRequired     = errors.New("agent_id is required")
	errCameraRelaySourceIDRequired    = errors.New("camera_source_id is required")
	errCameraRelayProfileIDRequired   = errors.New("stream_profile_id is required")
	errCameraRelayLeaseTokenRequired  = errors.New("lease_token is required")
)

const (
	defaultCameraRelayCloseTimeout = 10 * time.Second
	defaultCameraRelayUploadBatch  = 8

	cameraRelayReasonUploadFailed    = "camera relay upload failed"
	cameraRelayReasonSourceCompleted = "camera relay source completed"
	cameraRelayReasonSourceStartFail = "source_start_failed"
)

// relayStopCause is the context cancel cause for an operator stop. Its text is
// the upstream close reason, so it formats as that reason and is not a wrapped
// context.Canceled.
type relayStopCause struct {
	reason string
}

func (c relayStopCause) Error() string {
	return c.reason
}

func closeReasonFromContext(ctx context.Context, fallback string) string {
	cause := context.Cause(ctx)
	if cause == nil || errors.Is(cause, context.Canceled) || errors.Is(cause, context.DeadlineExceeded) {
		return fallback
	}
	return cause.Error()
}

type cameraRelayStartPayload struct {
	RelaySessionID     string `json:"relay_session_id"`
	CameraSourceID     string `json:"camera_source_id"`
	StreamProfileID    string `json:"stream_profile_id"`
	LeaseToken         string `json:"lease_token"`
	PluginAssignmentID string `json:"plugin_assignment_id,omitempty"`
	// SourceResolver replaces SourceURL: the agent derives the address itself.
	// SourceURL is still accepted from a Core that predates the resolver.
	SourceResolver     *cameraRelaySourceResolver `json:"source_resolver,omitempty"`
	SourceURL          string                     `json:"source_url,omitempty"`
	RTSPTransport      string                     `json:"rtsp_transport,omitempty"`
	CodecHint          string                     `json:"codec_hint,omitempty"`
	ContainerHint      string                     `json:"container_hint,omitempty"`
	InsecureSkipVerify bool                       `json:"insecure_skip_verify,omitempty"`
}

type cameraRelayStopPayload struct {
	RelaySessionID      string `json:"relay_session_id"`
	Reason              string `json:"reason,omitempty"`
	SourceIncarnationID string `json:"source_incarnation_id,omitempty"`
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
	SourceResolver     *cameraRelaySourceResolver
	SourceURL          string
	RTSPTransport      string
	CodecHint          string
	ContainerHint      string
	InsecureSkipVerify bool
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

type cameraRelaySourceKey struct {
	cameraSourceID  string
	streamProfileID string
}

type cameraRelayHandle struct {
	cancel context.CancelCauseFunc
	done   chan struct{}
	source cameraRelaySourceKey
	// Set by the stop path before cancel; a session that was asked to stop is
	// never reported as a source failure.
	stopped atomic.Bool
	// Written before done closes; readers must wait for done.
	closeErr error
}

type cameraRelayManager struct {
	// The source registry lifetime, not the gateway connection lifetime.
	incarnationID       string
	mu                  sync.Mutex
	startOperations     map[string]*cameraRelayStartOperation
	stopOperations      map[string]cameraRelayStopOperation
	sessions            map[string]*cameraRelayHandle
	sources             map[cameraRelaySourceKey]*cameraRelayHandle
	gateway             cameraRelayGateway
	sourceFactory       cameraRelaySourceFactory
	pluginSourceFactory func(context.Context, cameraRelaySessionSpec) (cameraRelayChunkStream, error)
	sourceResolver      func(context.Context, cameraRelaySourceResolver) (string, error)
	logger              logger.Logger
	uploadBatchSize     int
}

func newCameraRelayManager(gateway cameraRelayGateway, log logger.Logger) *cameraRelayManager {
	return &cameraRelayManager{
		incarnationID:   uuid.NewString(),
		startOperations: make(map[string]*cameraRelayStartOperation),
		stopOperations:  make(map[string]cameraRelayStopOperation),
		sessions:        make(map[string]*cameraRelayHandle),
		sources:         make(map[cameraRelaySourceKey]*cameraRelayHandle),
		gateway:         gateway,
		sourceFactory: func(spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
			return defaultCameraRelaySource(spec, log)
		},
		logger:          log,
		uploadBatchSize: defaultCameraRelayUploadBatch,
	}
}

func (m *cameraRelayManager) Start(ctx context.Context, spec cameraRelaySessionSpec) (state *cameraRelaySessionState, err error) {
	if m == nil {
		return nil, errCameraRelayGatewayUnavailable
	}

	spec, err = normalizeCameraRelaySpec(spec)
	if err != nil {
		return nil, err
	}

	if m.gateway == nil {
		return nil, errCameraRelayGatewayUnavailable
	}

	if spec.GatewayID == "" {
		spec.GatewayID = strings.TrimSpace(m.gateway.GetGatewayID())
	}

	runCtx, cancel := context.WithCancelCause(ctx)
	handle := &cameraRelayHandle{
		cancel: cancel, done: make(chan struct{}),
		source: cameraRelaySourceKey{cameraSourceID: spec.CameraSourceID, streamProfileID: spec.StreamProfileID},
	}

	if err := m.registerSession(spec.RelaySessionID, handle); err != nil {
		cancel(nil)
		return nil, err
	}
	defer func() {
		if err != nil {
			cancel(nil)
			m.unregisterSession(spec.RelaySessionID, handle)
			close(handle.done)
		}
	}()

	openResp, err := m.gateway.OpenRelaySession(ctx, &proto.OpenRelaySessionRequest{
		RelaySessionId:      spec.RelaySessionID,
		AgentId:             spec.AgentID,
		GatewayId:           spec.GatewayID,
		CameraSourceId:      spec.CameraSourceID,
		StreamProfileId:     spec.StreamProfileID,
		LeaseToken:          spec.LeaseToken,
		CodecHint:           spec.CodecHint,
		ContainerHint:       spec.ContainerHint,
		SourceIncarnationId: m.incarnationID,
	})
	if err != nil {
		return nil, fmt.Errorf("open relay session: %w", err)
	}

	spec.MediaIngestID = strings.TrimSpace(openResp.GetMediaIngestId())
	var (
		startFailure cameraRelayFailure
		lateSource   cameraRelayChunkStream
	)
	// Core is told before the camera socket is torn down, so a slow source
	// close never delays the upstream close.
	defer func() {
		if err == nil {
			return
		}
		m.closeUpstream(spec, handle, closeReasonFromContext(runCtx, cameraRelayReasonSourceStartFail), startFailure)
		if lateSource != nil {
			handle.closeErr = lateSource.Close()
		}
	}()

	m.logger.Info().
		Str("relay_session_id", spec.RelaySessionID).
		Str("media_ingest_id", spec.MediaIngestID).
		Str("agent_id", spec.AgentID).
		Str("gateway_id", spec.GatewayID).
		Str("camera_source_id", spec.CameraSourceID).
		Str("stream_profile_id", spec.StreamProfileID).
		Msg("Camera relay upstream session accepted")

	stream, err := m.openSource(runCtx, spec)
	if err == nil {
		if err = runCtx.Err(); err != nil {
			lateSource = stream
		}
	}
	if err != nil {
		startFailure = relaySourceFailure(runCtx, err)
		return nil, &cameraRelaySourceStartError{failure: startFailure, err: err}
	}

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

	// An omitted identity retains legacy stop behavior; a known identity may
	// only target the source registry that authenticated the media open.
	if payload.SourceIncarnationID != "" && payload.SourceIncarnationID != m.incarnationID {
		return errCameraRelayIncarnationMismatch
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

	return stopCameraRelayHandle(ctx, handle, reason)
}

func stopCameraRelayHandle(ctx context.Context, handle *cameraRelayHandle, reason string) error {
	handle.stopped.Store(true)
	handle.cancel(relayStopCause{reason: reason})

	if ctx == nil {
		return nil
	}

	select {
	case <-handle.done:
		if handle.closeErr != nil {
			return errCameraRelaySourceCloseFailed
		}
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
	defer handle.cancel(nil)
	defer close(handle.done)
	defer m.unregisterSession(spec.RelaySessionID, handle)
	defer func() {
		handle.closeErr = stream.Close()
		if err := handle.closeErr; err != nil {
			m.logger.Debug().Err(err).Str("relay_session_id", spec.RelaySessionID).Msg("Camera relay source close returned error")
		}
	}()

	closeReason := "camera relay completed"
	var sourceFailure cameraRelayFailure
	defer func() {
		closeReason = closeReasonFromContext(ctx, closeReason)
		m.logger.Info().
			Str("relay_session_id", spec.RelaySessionID).
			Str("media_ingest_id", spec.MediaIngestID).
			Str("close_reason", closeReason).
			Msg("Camera relay session stopping")
		m.closeUpstream(spec, handle, closeReason, sourceFailure)
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
		if err := ctx.Err(); err != nil {
			closeReason = "camera relay cancelled"
			sourceFailure = relaySourceFailure(ctx, err)
			return
		}
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
					closeReason = cameraRelayReasonUploadFailed
					m.logger.Warn().Err(err).Str("relay_session_id", spec.RelaySessionID).Msg("Camera relay upload failed")
					return
				}
			}
			if chunk.IsFinal {
				closeReason = cameraRelayReasonSourceCompleted
				return
			}

		case errors.Is(err, io.EOF):
			if err := flush(); err != nil {
				closeReason = cameraRelayReasonUploadFailed
				m.logger.Warn().Err(err).Str("relay_session_id", spec.RelaySessionID).Msg("Camera relay upload failed")
				return
			}
			closeReason = "camera relay source EOF"
			return

		case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
			closeReason = "camera relay cancelled"
			sourceFailure = relaySourceFailure(ctx, err)
			return

		default:
			closeReason = "camera relay source failed"
			sourceFailure = relaySourceFailure(ctx, err)
			return
		}
	}
}

// relaySourceFailure is the failure reported for the error that ended a relay's
// source, given the relay's run context. A source reporting the relay's own
// cancellation (agent shutdown, control-stream reconnect) is not a camera
// failure. Every other error is, a deadline included, and so is a real source
// error that merely coincides with a cancelled context. closeUpstream separately
// drops the failure when an operator stopped the session.
func relaySourceFailure(runCtx context.Context, err error) cameraRelayFailure {
	if errors.Is(err, context.Canceled) && errors.Is(runCtx.Err(), context.Canceled) {
		return cameraRelayFailure{}
	}
	return classifyCameraRelayFailure(err)
}

// logSourceFailure logs only the sanitized failure: the raw source error can
// quote the stream URL and its credentials.
func (m *cameraRelayManager) logSourceFailure(spec cameraRelaySessionSpec, failure cameraRelayFailure) {
	m.logger.Warn().
		Str("relay_session_id", spec.RelaySessionID).
		Str("camera_source_id", spec.CameraSourceID).
		Str("stream_profile_id", spec.StreamProfileID).
		Str("failure_class", failure.Class).
		Str("failure_detail", failure.Detail).
		Msg("Camera relay source failed")
}

// closeUpstream reports the close to Core. failure is relaySourceFailure for
// the error that ended the source, or empty when it ended normally; Core
// stores it as the session's failure_reason. The stop flag is read here, when
// the close is sent: a session an operator asked to stop is never reported as
// a failure.
func (m *cameraRelayManager) closeUpstream(spec cameraRelaySessionSpec, handle *cameraRelayHandle, reason string, failure cameraRelayFailure) {
	if m == nil || m.gateway == nil {
		return
	}

	if handle.stopped.Load() {
		failure = cameraRelayFailure{}
	} else if failure.Class != "" {
		m.logSourceFailure(spec, failure)
	}

	ctx, cancel := context.WithTimeout(context.Background(), defaultCameraRelayCloseTimeout)
	defer cancel()

	_, err := m.gateway.CloseRelaySession(ctx, &proto.CloseRelaySessionRequest{
		RelaySessionId: spec.RelaySessionID,
		MediaIngestId:  spec.MediaIngestID,
		AgentId:        spec.AgentID,
		Reason:         reason,
		FailureReason:  failure.String(),
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
}

func (m *cameraRelayManager) registerSession(relaySessionID string, handle *cameraRelayHandle) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.sessions[relaySessionID]; exists {
		return errCameraRelaySessionExists
	}

	if _, exists := m.sources[handle.source]; exists {
		return errCameraRelaySourceActive
	}

	// Reserve before upstream admission; retain ownership through source teardown,
	// even if Stop's caller times out or a replacement uses a new relay ID.
	m.sessions[relaySessionID] = handle
	m.sources[handle.source] = handle
	return nil
}

func (m *cameraRelayManager) unregisterSession(relaySessionID string, handle *cameraRelayHandle) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if current, exists := m.sessions[relaySessionID]; exists && current == handle {
		delete(m.sessions, relaySessionID)
		delete(m.sources, handle.source)
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
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	if spec.SourceResolver != nil {
		return m.openResolvedSource(ctx, spec)
	}

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

// openResolvedSource derives the stream address and hands it to the native
// reader. The address lives only in this call's copy of the spec: the session
// spec, which is logged and reported, never holds it.
func (m *cameraRelayManager) openResolvedSource(ctx context.Context, spec cameraRelaySessionSpec) (cameraRelayChunkStream, error) {
	if m == nil || m.sourceResolver == nil || m.sourceFactory == nil {
		return nil, errCameraRelaySourceResolverUnavailable
	}

	resolver, err := normalizeCameraRelaySourceResolver(*spec.SourceResolver)
	if err != nil {
		return nil, err
	}

	sourceURL, err := m.sourceResolver(ctx, resolver)
	if err != nil {
		return nil, err
	}

	spec.SourceURL = sourceURL
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
	if spec.SourceResolver != nil {
		// A command that names a resolver never opens a stored address.
		spec.SourceURL = ""
	}
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
