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
	"io"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	consoleFrameTypeOpen   = "open"
	consoleFrameTypeReady  = "ready"
	consoleFrameTypeData   = "data"
	consoleFrameTypeResize = "resize"
	consoleFrameTypeClose  = "close"
	consoleFrameTypeError  = "error"
)

var (
	errProxmoxConsoleBridgeUnavailable = errors.New("proxmox console PTY bridge unavailable")
	errProxmoxConsoleSessionExists     = errors.New("console session is already active")
	errProxmoxConsoleSessionNotActive  = errors.New("console session is not active")
)

type proxmoxConsoleSender interface {
	Send(*proto.ControlStreamRequest) error
}

type proxmoxConsolePTY interface {
	Read(context.Context) ([]byte, error)
	Write([]byte) error
	Resize(cols, rows uint32) error
	Close() error
}

type proxmoxConsoleOpener func(context.Context, *proto.ConsoleFrame) (proxmoxConsolePTY, error)

type proxmoxConsoleSession struct {
	cancel context.CancelFunc
	pty    proxmoxConsolePTY
	once   sync.Once
}

func (s *proxmoxConsoleSession) close() {
	s.once.Do(func() {
		s.cancel()
		_ = s.pty.Close()
	})
}

type proxmoxConsoleManager struct {
	mu       sync.Mutex
	sessions map[string]*proxmoxConsoleSession
	opener   proxmoxConsoleOpener
	logger   logger.Logger
}

func newProxmoxConsoleManager(log logger.Logger) *proxmoxConsoleManager {
	return &proxmoxConsoleManager{
		sessions: make(map[string]*proxmoxConsoleSession),
		opener: func(context.Context, *proto.ConsoleFrame) (proxmoxConsolePTY, error) {
			return nil, errProxmoxConsoleBridgeUnavailable
		},
		logger: log,
	}
}

func (m *proxmoxConsoleManager) HandleFrame(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	if frame == nil || frame.GetSessionId() == "" {
		return
	}

	switch frame.GetFrameType() {
	case consoleFrameTypeOpen:
		m.open(ctx, frame, sender)
	case consoleFrameTypeData:
		m.write(frame, sender)
	case consoleFrameTypeResize:
		m.resize(frame, sender)
	case consoleFrameTypeClose:
		m.closeSession(frame.GetSessionId(), frame.GetReason(), sender)
	default:
		sendProxmoxConsoleFrame(sender, frame.GetSessionId(), consoleFrameTypeError, nil, "unsupported console frame type", 0, 0)
	}
}

func (m *proxmoxConsoleManager) open(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	sessionID := frame.GetSessionId()

	if m.get(sessionID) != nil {
		sendProxmoxConsoleError(sender, sessionID, errProxmoxConsoleSessionExists)
		return
	}

	ptySession, err := m.opener(ctx, frame)
	if err != nil {
		sendProxmoxConsoleError(sender, sessionID, err)
		return
	}

	sessionCtx, cancel := context.WithCancel(ctx)
	session := &proxmoxConsoleSession{cancel: cancel, pty: ptySession}

	m.mu.Lock()
	if _, exists := m.sessions[sessionID]; exists {
		m.mu.Unlock()
		session.close()
		sendProxmoxConsoleError(sender, sessionID, errProxmoxConsoleSessionExists)
		return
	}
	m.sessions[sessionID] = session
	m.mu.Unlock()

	sendProxmoxConsoleFrame(sender, sessionID, consoleFrameTypeReady, nil, "", frame.GetCols(), frame.GetRows())

	go m.readLoop(sessionCtx, sessionID, session, sender)
}

func (m *proxmoxConsoleManager) write(frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	session := m.get(frame.GetSessionId())
	if session == nil {
		sendProxmoxConsoleError(sender, frame.GetSessionId(), errProxmoxConsoleSessionNotActive)
		return
	}

	if err := session.pty.Write(frame.GetData()); err != nil {
		sendProxmoxConsoleError(sender, frame.GetSessionId(), err)
		m.closeSession(frame.GetSessionId(), "console write failed", sender)
	}
}

func (m *proxmoxConsoleManager) resize(frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	session := m.get(frame.GetSessionId())
	if session == nil {
		sendProxmoxConsoleError(sender, frame.GetSessionId(), errProxmoxConsoleSessionNotActive)
		return
	}

	if err := session.pty.Resize(frame.GetCols(), frame.GetRows()); err != nil {
		sendProxmoxConsoleError(sender, frame.GetSessionId(), err)
		m.closeSession(frame.GetSessionId(), "console resize failed", sender)
	}
}

func (m *proxmoxConsoleManager) closeSession(sessionID string, reason string, sender proxmoxConsoleSender) {
	session := m.remove(sessionID)
	if session == nil {
		return
	}

	session.close()
	sendProxmoxConsoleFrame(sender, sessionID, consoleFrameTypeClose, nil, reason, 0, 0)
}

func (m *proxmoxConsoleManager) readLoop(
	ctx context.Context,
	sessionID string,
	session *proxmoxConsoleSession,
	sender proxmoxConsoleSender,
) {
	for {
		data, err := session.pty.Read(ctx)
		if len(data) > 0 {
			sendProxmoxConsoleFrame(sender, sessionID, consoleFrameTypeData, data, "", 0, 0)
		}

		if err == nil {
			continue
		}

		if ctx.Err() != nil {
			return
		}

		if m.removeIfSame(sessionID, session) {
			session.close()
			if !errors.Is(err, io.EOF) {
				if m.logger != nil {
					m.logger.Warn().Err(err).Str("session_id", sessionID).Msg("Proxmox console PTY read failed")
				}
				sendProxmoxConsoleError(sender, sessionID, err)
			}
			sendProxmoxConsoleFrame(sender, sessionID, consoleFrameTypeClose, nil, "", 0, 0)
		}

		return
	}
}

func (m *proxmoxConsoleManager) get(sessionID string) *proxmoxConsoleSession {
	m.mu.Lock()
	defer m.mu.Unlock()

	return m.sessions[sessionID]
}

func (m *proxmoxConsoleManager) remove(sessionID string) *proxmoxConsoleSession {
	m.mu.Lock()
	defer m.mu.Unlock()

	session := m.sessions[sessionID]
	delete(m.sessions, sessionID)

	return session
}

func (m *proxmoxConsoleManager) removeIfSame(sessionID string, session *proxmoxConsoleSession) bool {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.sessions[sessionID] != session {
		return false
	}

	delete(m.sessions, sessionID)

	return true
}

func sendProxmoxConsoleError(sender proxmoxConsoleSender, sessionID string, err error) {
	reason := "console session failed"
	if err != nil {
		reason = err.Error()
	}
	sendProxmoxConsoleFrame(sender, sessionID, consoleFrameTypeError, nil, reason, 0, 0)
}

func sendProxmoxConsoleFrame(
	sender proxmoxConsoleSender,
	sessionID string,
	frameType string,
	data []byte,
	reason string,
	cols uint32,
	rows uint32,
) {
	if sender == nil {
		return
	}

	_ = sender.Send(consoleControlFrame(sessionID, frameType, data, reason, cols, rows))
}

func consoleControlFrame(
	sessionID string,
	frameType string,
	data []byte,
	reason string,
	cols uint32,
	rows uint32,
) *proto.ControlStreamRequest {
	return &proto.ControlStreamRequest{
		Payload: &proto.ControlStreamRequest_ConsoleFrame{
			ConsoleFrame: &proto.ConsoleFrame{
				SessionId: sessionID,
				FrameType: frameType,
				Data:      data,
				Cols:      cols,
				Rows:      rows,
				Reason:    reason,
				Timestamp: time.Now().Unix(),
			},
		},
	}
}
