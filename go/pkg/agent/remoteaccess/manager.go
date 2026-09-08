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

// Package remoteaccess provides provider-neutral session plumbing for
// agent-routed interactive access. Protocol adapters such as SSH or Proxmox
// console own target-specific dialing; Manager owns session frame routing.
package remoteaccess

import (
	"context"
	"errors"
	"io"
	"sync"
	"time"
)

const (
	FrameTypeOpen      = "open"
	FrameTypeReady     = "ready"
	FrameTypeData      = "data"
	FrameTypeResize    = "resize"
	FrameTypeHeartbeat = "heartbeat"
	FrameTypeClose     = "close"
	FrameTypeError     = "error"
	FrameTypeOutcome   = "outcome"

	MaxTerminalCols      = 500
	MaxTerminalRows      = 200
	MaxTerminalFrameData = 65_536
	MaxOpenFrameData     = 262_144
)

var (
	ErrAdapterUnavailable = errors.New("remote access adapter unavailable")
	ErrSessionExists      = errors.New("remote access session is already active")
	ErrSessionNotActive   = errors.New("remote access session is not active")
	ErrUnsupportedFrame   = errors.New("unsupported remote access frame type")
	ErrInvalidFrameSize   = errors.New("invalid remote access frame size")
)

// Frame is the agent-local representation of a remote-access control frame.
// It intentionally mirrors the OpenSpec frame vocabulary before protobuf
// compatibility wrappers map it to existing ConsoleFrame traffic.
type Frame struct {
	SessionID     string
	Protocol      string
	FrameType     string
	Data          []byte
	Cols          uint32
	Rows          uint32
	Reason        string
	Timestamp     int64
	Seq           uint64
	PayloadSHA256 string
	Signature     string
	Metadata      map[string]string
}

// Sender emits frames back to the gateway/control-plane route.
type Sender interface {
	SendFrame(Frame) error
}

// PTY is the byte-oriented terminal interface exposed by terminal protocols.
type PTY interface {
	Read(context.Context) ([]byte, error)
	Write([]byte) error
	Resize(cols, rows uint32) error
	Close() error
}

// Opener opens a protocol-specific target adapter for an open frame.
type Opener func(context.Context, Frame) (PTY, error)

// ErrorReason maps internal errors to user-facing frame reasons.
type ErrorReason func(error) string

// ManagerConfig configures a remote-access session manager.
type ManagerConfig struct {
	Opener           Opener
	ErrorReason      ErrorReason
	EnhancedRecorder EnhancedRecorder
}

type session struct {
	cancel    context.CancelFunc
	pty       PTY
	enhanced  EnhancedRecording
	enhancedC context.CancelFunc
	once      sync.Once
}

func (s *session) close() {
	s.once.Do(func() {
		s.cancel()
		if s.enhancedC != nil {
			s.enhancedC()
		}
		if s.enhanced != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = s.enhanced.Stop(ctx)
		}
		_ = s.pty.Close()
	})
}

// Manager routes generic remote-access frames to active adapter sessions.
type Manager struct {
	mu       sync.Mutex
	sessions map[string]*session
	opener   Opener
	reason   ErrorReason
	enhanced EnhancedRecorder
}

// NewManager creates a remote-access session manager. A nil opener reports
// ErrAdapterUnavailable for open frames until the caller provides one.
func NewManager(opener Opener) *Manager {
	return NewManagerWithConfig(ManagerConfig{Opener: opener})
}

// NewManagerWithConfig creates a remote-access session manager with optional
// compatibility hooks for callers that are adapting an existing protocol.
func NewManagerWithConfig(cfg ManagerConfig) *Manager {
	opener := cfg.Opener
	if opener == nil {
		opener = func(context.Context, Frame) (PTY, error) {
			return nil, ErrAdapterUnavailable
		}
	}

	return &Manager{
		sessions: make(map[string]*session),
		opener:   opener,
		reason:   cfg.ErrorReason,
		enhanced: cfg.EnhancedRecorder,
	}
}

// HandleFrame applies one incoming control frame to the addressed session.
func (m *Manager) HandleFrame(ctx context.Context, frame Frame, sender Sender) {
	if frame.SessionID == "" {
		return
	}

	if err := validateInboundFrame(frame); err != nil {
		m.sendError(sender, frame.SessionID, err)
		if frame.FrameType == FrameTypeData || frame.FrameType == FrameTypeResize {
			m.closeSession(frame.SessionID, "remote access invalid frame size", sender)
		}
		return
	}

	switch frame.FrameType {
	case FrameTypeOpen:
		m.open(ctx, frame, sender)
	case FrameTypeData:
		m.write(frame, sender)
	case FrameTypeResize:
		m.resize(frame, sender)
	case FrameTypeHeartbeat:
		sendFrame(sender, heartbeatFrame(frame))
	case FrameTypeClose:
		m.closeSession(frame.SessionID, frame.Reason, sender)
	default:
		m.sendError(sender, frame.SessionID, ErrUnsupportedFrame)
	}
}

func validateInboundFrame(frame Frame) error {
	switch frame.FrameType {
	case FrameTypeOpen:
		if len(frame.Data) > MaxOpenFrameData {
			return ErrInvalidFrameSize
		}
		if !validOptionalTerminalDimension(frame.Cols, MaxTerminalCols) ||
			!validOptionalTerminalDimension(frame.Rows, MaxTerminalRows) {
			return ErrInvalidFrameSize
		}
	case FrameTypeData:
		if len(frame.Data) > MaxTerminalFrameData {
			return ErrInvalidFrameSize
		}
	case FrameTypeResize:
		if !validTerminalDimension(frame.Cols, MaxTerminalCols) ||
			!validTerminalDimension(frame.Rows, MaxTerminalRows) {
			return ErrInvalidFrameSize
		}
	}

	return nil
}

func validOptionalTerminalDimension(value uint32, max uint32) bool {
	return value == 0 || validTerminalDimension(value, max)
}

func validTerminalDimension(value uint32, max uint32) bool {
	return value > 0 && value <= max
}

func (m *Manager) open(ctx context.Context, frame Frame, sender Sender) {
	if m.get(frame.SessionID) != nil {
		m.sendError(sender, frame.SessionID, ErrSessionExists)
		return
	}

	enhancedSession, enhanced, enhancedCancel, err := m.startEnhancedRecording(ctx, frame)
	if err != nil {
		m.sendError(sender, frame.SessionID, err)
		return
	}

	ptySession, err := m.opener(ctx, frame)
	if err != nil {
		stopEnhancedRecording(enhancedCancel, enhanced)
		m.sendError(sender, frame.SessionID, err)
		return
	}

	sessionCtx, cancel := context.WithCancel(ctx)
	next := &session{
		cancel:    cancel,
		pty:       ptySession,
		enhanced:  enhanced,
		enhancedC: enhancedCancel,
	}

	m.mu.Lock()
	if _, exists := m.sessions[frame.SessionID]; exists {
		m.mu.Unlock()
		next.close()
		m.sendError(sender, frame.SessionID, ErrSessionExists)
		return
	}
	m.sessions[frame.SessionID] = next
	m.mu.Unlock()

	sendFrame(sender, Frame{
		SessionID: frame.SessionID,
		Protocol:  frame.Protocol,
		FrameType: FrameTypeReady,
		Cols:      frame.Cols,
		Rows:      frame.Rows,
		Timestamp: nowUnix(),
	})

	go m.readLoop(sessionCtx, frame.SessionID, frame.Protocol, next, sender)
	go m.contextCloseLoop(sessionCtx, frame.SessionID, frame.Protocol, next, sender)
	if enhanced != nil {
		go m.enhancedLoop(sessionCtx, enhancedSession, enhanced, sender)
	}
}

func (m *Manager) write(frame Frame, sender Sender) {
	session := m.get(frame.SessionID)
	if session == nil {
		m.sendError(sender, frame.SessionID, ErrSessionNotActive)
		return
	}

	if err := session.pty.Write(frame.Data); err != nil {
		m.sendError(sender, frame.SessionID, err)
		m.closeSession(frame.SessionID, "remote access write failed", sender)
	}
}

func (m *Manager) resize(frame Frame, sender Sender) {
	session := m.get(frame.SessionID)
	if session == nil {
		m.sendError(sender, frame.SessionID, ErrSessionNotActive)
		return
	}

	if err := session.pty.Resize(frame.Cols, frame.Rows); err != nil {
		m.sendError(sender, frame.SessionID, err)
		m.closeSession(frame.SessionID, "remote access resize failed", sender)
	}
}

func (m *Manager) closeSession(sessionID string, reason string, sender Sender) {
	session := m.remove(sessionID)
	if session == nil {
		return
	}

	session.close()
	sendFrame(sender, Frame{
		SessionID: sessionID,
		FrameType: FrameTypeClose,
		Reason:    reason,
		Timestamp: nowUnix(),
	})
}

func (m *Manager) readLoop(ctx context.Context, sessionID string, protocol string, current *session, sender Sender) {
	for {
		data, err := current.pty.Read(ctx)
		if len(data) > 0 {
			sendDataFrames(sender, sessionID, protocol, data)
		}

		if err == nil {
			continue
		}

		if ctx.Err() != nil {
			return
		}

		if m.removeIfSame(sessionID, current) {
			current.close()
			if !errors.Is(err, io.EOF) {
				m.sendError(sender, sessionID, err)
			}
			sendFrame(sender, Frame{
				SessionID: sessionID,
				Protocol:  protocol,
				FrameType: FrameTypeClose,
				Timestamp: nowUnix(),
			})
		}

		return
	}
}

func sendDataFrames(sender Sender, sessionID string, protocol string, data []byte) {
	for len(data) > 0 {
		chunkSize := len(data)
		if chunkSize > MaxTerminalFrameData {
			chunkSize = MaxTerminalFrameData
		}

		sendFrame(sender, Frame{
			SessionID: sessionID,
			Protocol:  protocol,
			FrameType: FrameTypeData,
			Data:      data[:chunkSize],
			Timestamp: nowUnix(),
		})

		data = data[chunkSize:]
	}
}

func (m *Manager) contextCloseLoop(
	ctx context.Context,
	sessionID string,
	protocol string,
	current *session,
	sender Sender,
) {
	<-ctx.Done()
	if m.removeIfSame(sessionID, current) {
		current.close()
		sendFrame(sender, Frame{
			SessionID: sessionID,
			Protocol:  protocol,
			FrameType: FrameTypeClose,
			Reason:    ctx.Err().Error(),
			Timestamp: nowUnix(),
		})
	}
}

func (m *Manager) startEnhancedRecording(
	ctx context.Context,
	frame Frame,
) (EnhancedRecordingSession, EnhancedRecording, context.CancelFunc, error) {
	policy := enhancedPolicyFromFrame(frame)
	session := enhancedSessionFromFrame(frame, policy)

	if err := validateEnhancedRecordingBoundary(session); err != nil {
		return session, nil, nil, err
	}

	if !enhancedRecordingEnabled(policy) {
		return session, nil, nil, nil
	}

	if m.enhanced == nil {
		if policy.Required && !policy.AllowFallback {
			return session, nil, nil, ErrEnhancedRecordingUnavailable
		}
		return session, nil, nil, nil
	}

	collectorCtx, cancel := context.WithCancel(ctx)
	recording, err := m.enhanced.Start(collectorCtx, session)
	if err != nil {
		cancel()
		if policy.Required && !policy.AllowFallback {
			return session, nil, nil, err
		}
		return session, nil, nil, nil
	}

	return session, recording, cancel, nil
}

func (m *Manager) enhancedLoop(
	ctx context.Context,
	session EnhancedRecordingSession,
	recording EnhancedRecording,
	sender Sender,
) {
	for {
		select {
		case event, ok := <-recording.Events():
			if !ok {
				return
			}
			sendFrame(sender, enhancedEventFrame(session, event))
		case <-ctx.Done():
			return
		}
	}
}

func stopEnhancedRecording(cancel context.CancelFunc, recording EnhancedRecording) {
	if cancel != nil {
		cancel()
	}
	if recording == nil {
		return
	}

	ctx, cancelStop := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelStop()
	_ = recording.Stop(ctx)
}

func (m *Manager) get(sessionID string) *session {
	m.mu.Lock()
	defer m.mu.Unlock()

	return m.sessions[sessionID]
}

func (m *Manager) remove(sessionID string) *session {
	m.mu.Lock()
	defer m.mu.Unlock()

	session := m.sessions[sessionID]
	delete(m.sessions, sessionID)

	return session
}

func (m *Manager) removeIfSame(sessionID string, current *session) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.sessions[sessionID] != current {
		return false
	}

	delete(m.sessions, sessionID)

	return true
}

func heartbeatFrame(frame Frame) Frame {
	return Frame{
		SessionID: frame.SessionID,
		Protocol:  frame.Protocol,
		FrameType: FrameTypeHeartbeat,
		Timestamp: nowUnix(),
		Metadata:  frame.Metadata,
	}
}

func (m *Manager) sendError(sender Sender, sessionID string, err error) {
	reason := "remote access session failed"
	if m.reason != nil {
		reason = m.reason(err)
	} else if err != nil {
		reason = err.Error()
	}

	sendFrame(sender, Frame{
		SessionID: sessionID,
		FrameType: FrameTypeError,
		Reason:    reason,
		Timestamp: nowUnix(),
	})
}

func sendFrame(sender Sender, frame Frame) {
	if sender == nil {
		return
	}

	if frame.Timestamp == 0 {
		frame.Timestamp = nowUnix()
	}

	_ = sender.SendFrame(frame)
}

func nowUnix() int64 {
	return time.Now().Unix()
}
