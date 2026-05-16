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
	"encoding/json"
	"errors"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
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

	protocolProxmoxConsole = "proxmox-console"
)

var (
	errProxmoxConsoleBridgeUnavailable = errors.New("proxmox console PTY bridge unavailable")
	errProxmoxConsoleSessionExists     = errors.New("console session is already active")
	errProxmoxConsoleSessionNotActive  = errors.New("console session is not active")
	errProxmoxConsoleFrameMismatch     = errors.New("desktop console frame type mismatch")
)

type proxmoxConsoleSender interface {
	Send(*proto.ControlStreamRequest) error
}

type proxmoxConsolePTY interface {
	remoteaccess.PTY
}

type proxmoxConsoleOpener func(context.Context, *proto.ConsoleFrame) (proxmoxConsolePTY, error)

type proxmoxConsoleManager struct {
	opener          proxmoxConsoleOpener
	manager         *remoteaccess.Manager
	sshOptions      remoteaccess.SSHOpenOptions
	sshMu           sync.Mutex
	sshConfig       map[string]remoteaccess.SSHConfig
	desktopMu       sync.Mutex
	desktopSessions map[string]desktopConsoleSession
	uploadMu        sync.Mutex
	uploads         map[string]*fileTransferUpload
	sftpDialer      remoteaccess.SFTPDialer
	agentID         string
	gatewayID       string
}

type desktopConsoleSession struct {
	target  remoteaccess.DesktopTarget
	session remoteaccess.DesktopAdapterSession
}

func newProxmoxConsoleManager(log logger.Logger) *proxmoxConsoleManager {
	return newProxmoxConsoleManagerWithAgentID("", log)
}

func newProxmoxConsoleManagerWithAgentID(agentID string, log logger.Logger) *proxmoxConsoleManager {
	return newProxmoxConsoleManagerWithRoute(agentID, "", log)
}

func newProxmoxConsoleManagerWithRoute(agentID string, gatewayID string, _ logger.Logger) *proxmoxConsoleManager {
	manager := &proxmoxConsoleManager{
		agentID:         agentID,
		gatewayID:       gatewayID,
		sshConfig:       make(map[string]remoteaccess.SSHConfig),
		desktopSessions: make(map[string]desktopConsoleSession),
		uploads:         make(map[string]*fileTransferUpload),
		sftpDialer:      nil,
		opener: func(context.Context, *proto.ConsoleFrame) (proxmoxConsolePTY, error) {
			return nil, errProxmoxConsoleBridgeUnavailable
		},
	}

	manager.manager = remoteaccess.NewManagerWithConfig(remoteaccess.ManagerConfig{
		Opener:           manager.openRemoteAccessPTY,
		ErrorReason:      proxmoxConsoleErrorReason,
		EnhancedRecorder: remoteaccess.NewPlatformEnhancedRecorder(),
	})

	return manager
}

func serverAgentID(server *Server) string {
	if server == nil || server.config == nil {
		return ""
	}

	server.mu.RLock()
	defer server.mu.RUnlock()

	return server.config.AgentID
}

func (m *proxmoxConsoleManager) HandleFrame(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	if frame == nil || frame.GetSessionId() == "" {
		return
	}

	var remoteSender remoteaccess.Sender
	if sender != nil {
		remoteSender = proxmoxConsoleRemoteSender{sender: sender}
	}

	if frame.GetFrameType() == consoleFrameTypeClose && m.hasDesktopSession(frame.GetSessionId()) {
		m.closeDesktopSession(ctx, frame.GetSessionId(), frame.GetReason(), remoteSender)

		return
	}

	if isDesktopConsoleFrameType(frame.GetFrameType()) {
		m.handleDesktopConsoleFrame(ctx, frame, remoteSender)

		return
	}

	m.manager.HandleFrame(ctx, m.proxmoxConsoleRemoteFrame(frame), remoteSender)
}

func (m *proxmoxConsoleManager) openRemoteAccessPTY(
	ctx context.Context,
	frame remoteaccess.Frame,
) (remoteaccess.PTY, error) {
	if frame.Protocol == remoteaccess.ProtocolSSH {
		cfg, err := remoteaccess.SSHConfigFromOpenFrame(frame)
		if err != nil {
			return nil, err
		}

		cfg.KnownHostsPath = m.sshOptions.KnownHostsPath

		pty, err := remoteaccess.OpenSSHPTY(ctx, cfg, m.sshOptions.Dial)
		if err != nil {
			return nil, err
		}

		m.setSSHConfig(frame.SessionID, cfg)

		return &remoteAccessTrackedPTY{
			PTY: pty,
			onClose: func() {
				m.deleteSSHConfig(frame.SessionID)
			},
		}, nil
	}

	return m.opener(ctx, remoteAccessConsoleFrame(frame))
}

func (m *proxmoxConsoleManager) setSSHConfig(sessionID string, cfg remoteaccess.SSHConfig) {
	if m == nil || sessionID == "" {
		return
	}

	m.sshMu.Lock()
	defer m.sshMu.Unlock()
	if m.sshConfig == nil {
		m.sshConfig = make(map[string]remoteaccess.SSHConfig)
	}
	m.sshConfig[sessionID] = cfg
}

func (m *proxmoxConsoleManager) getSSHConfig(sessionID string) (remoteaccess.SSHConfig, bool) {
	if m == nil || sessionID == "" {
		return remoteaccess.SSHConfig{}, false
	}

	m.sshMu.Lock()
	defer m.sshMu.Unlock()
	cfg, ok := m.sshConfig[sessionID]
	return cfg, ok
}

func (m *proxmoxConsoleManager) deleteSSHConfig(sessionID string) {
	if m == nil || sessionID == "" {
		return
	}

	m.sshMu.Lock()
	defer m.sshMu.Unlock()
	delete(m.sshConfig, sessionID)
}

func (m *proxmoxConsoleManager) registerDesktopSession(
	sessionID string,
	target remoteaccess.DesktopTarget,
	session remoteaccess.DesktopAdapterSession,
) {
	if m == nil || sessionID == "" || session == nil {
		return
	}

	m.desktopMu.Lock()
	defer m.desktopMu.Unlock()
	if m.desktopSessions == nil {
		m.desktopSessions = make(map[string]desktopConsoleSession)
	}
	m.desktopSessions[sessionID] = desktopConsoleSession{
		target:  target,
		session: session,
	}
}

func (m *proxmoxConsoleManager) getDesktopSession(sessionID string) (desktopConsoleSession, bool) {
	if m == nil || sessionID == "" {
		return desktopConsoleSession{}, false
	}

	m.desktopMu.Lock()
	defer m.desktopMu.Unlock()
	session, ok := m.desktopSessions[sessionID]

	return session, ok
}

func (m *proxmoxConsoleManager) hasDesktopSession(sessionID string) bool {
	_, ok := m.getDesktopSession(sessionID)

	return ok
}

func (m *proxmoxConsoleManager) deleteDesktopSession(sessionID string) {
	if m == nil || sessionID == "" {
		return
	}

	m.desktopMu.Lock()
	defer m.desktopMu.Unlock()
	delete(m.desktopSessions, sessionID)
}

func (m *proxmoxConsoleManager) handleDesktopConsoleFrame(
	ctx context.Context,
	frame *proto.ConsoleFrame,
	sender remoteaccess.Sender,
) {
	desktopSession, ok := m.getDesktopSession(frame.GetSessionId())
	if !ok {
		sendProxmoxConsoleRemoteError(sender, frame.GetSessionId(), errProxmoxConsoleSessionNotActive.Error())

		return
	}

	desktopFrame, err := remoteaccess.DecodeDesktopFramePayloadForSessionWithPolicy(
		frame.GetData(),
		desktopSession.target.Screen,
		desktopSession.target.Redirection,
		frame.GetSessionId(),
	)
	if err != nil {
		sendProxmoxConsoleRemoteError(sender, frame.GetSessionId(), err.Error())

		return
	}
	if desktopFrame.FrameType != frame.GetFrameType() {
		sendProxmoxConsoleRemoteError(sender, frame.GetSessionId(), errProxmoxConsoleFrameMismatch.Error())

		return
	}

	if err := desktopSession.session.SendDesktopFrame(ctx, desktopFrame); err != nil {
		sendProxmoxConsoleRemoteError(sender, frame.GetSessionId(), err.Error())
	}
}

func (m *proxmoxConsoleManager) closeDesktopSession(
	ctx context.Context,
	sessionID string,
	reason string,
	sender remoteaccess.Sender,
) {
	desktopSession, ok := m.getDesktopSession(sessionID)
	if !ok {
		sendProxmoxConsoleRemoteError(sender, sessionID, errProxmoxConsoleSessionNotActive.Error())

		return
	}

	m.deleteDesktopSession(sessionID)
	if err := desktopSession.session.Close(ctx, reason); err != nil {
		sendProxmoxConsoleRemoteError(sender, sessionID, err.Error())

		return
	}
	if sender != nil {
		_ = sender.SendFrame(remoteaccess.Frame{
			SessionID: sessionID,
			FrameType: consoleFrameTypeClose,
			Reason:    reason,
		})
	}
}

type remoteAccessTrackedPTY struct {
	remoteaccess.PTY
	once    sync.Once
	onClose func()
}

func (p *remoteAccessTrackedPTY) Close() error {
	var err error
	p.once.Do(func() {
		if p.onClose != nil {
			p.onClose()
		}
		if p.PTY != nil {
			err = p.PTY.Close()
		}
	})
	return err
}

type proxmoxConsoleRemoteSender struct {
	sender proxmoxConsoleSender
}

func (s proxmoxConsoleRemoteSender) SendFrame(frame remoteaccess.Frame) error {
	return s.sender.Send(consoleControlFrame(
		frame.SessionID,
		frame.FrameType,
		frame.Data,
		frame.Reason,
		frame.Cols,
		frame.Rows,
	))
}

func (m *proxmoxConsoleManager) proxmoxConsoleRemoteFrame(frame *proto.ConsoleFrame) remoteaccess.Frame {
	metadata := map[string]string(nil)
	if m != nil {
		metadata = routeMetadata(m.agentID, m.gatewayID)
	}

	return remoteaccess.Frame{
		SessionID: frame.GetSessionId(),
		Protocol:  consoleFrameProtocol(frame),
		FrameType: frame.GetFrameType(),
		Data:      frame.GetData(),
		Cols:      frame.GetCols(),
		Rows:      frame.GetRows(),
		Reason:    frame.GetReason(),
		Timestamp: frame.GetTimestamp(),
		Metadata:  metadata,
	}
}

func routeMetadata(agentID string, gatewayID string) map[string]string {
	metadata := make(map[string]string, 2)
	if agentID != "" {
		metadata["agent_id"] = agentID
	}
	if gatewayID != "" {
		metadata["gateway_id"] = gatewayID
	}
	if len(metadata) == 0 {
		return nil
	}
	return metadata
}

func consoleFrameProtocol(frame *proto.ConsoleFrame) string {
	if frame.GetFrameType() != consoleFrameTypeOpen || len(bytes.TrimSpace(frame.GetData())) == 0 {
		return protocolProxmoxConsole
	}

	var payload struct {
		Protocol string `json:"protocol"`
	}
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		return protocolProxmoxConsole
	}
	if payload.Protocol == remoteaccess.ProtocolSSH {
		return remoteaccess.ProtocolSSH
	}

	return protocolProxmoxConsole
}

func remoteAccessConsoleFrame(frame remoteaccess.Frame) *proto.ConsoleFrame {
	return &proto.ConsoleFrame{
		SessionId: frame.SessionID,
		FrameType: frame.FrameType,
		Data:      frame.Data,
		Cols:      frame.Cols,
		Rows:      frame.Rows,
		Reason:    frame.Reason,
		Timestamp: frame.Timestamp,
	}
}

func proxmoxConsoleErrorReason(err error) string {
	switch {
	case errors.Is(err, remoteaccess.ErrSessionExists):
		return errProxmoxConsoleSessionExists.Error()
	case errors.Is(err, remoteaccess.ErrSessionNotActive):
		return errProxmoxConsoleSessionNotActive.Error()
	case errors.Is(err, remoteaccess.ErrUnsupportedFrame):
		return "unsupported console frame type"
	case err != nil:
		return err.Error()
	default:
		return "console session failed"
	}
}

func isDesktopConsoleFrameType(frameType string) bool {
	switch frameType {
	case remoteaccess.DesktopFrameTypeInput,
		remoteaccess.DesktopFrameTypeResize,
		remoteaccess.DesktopFrameTypeClipboard,
		remoteaccess.DesktopFrameTypeQuality,
		remoteaccess.DesktopFrameTypeDisconnect:
		return true
	default:
		return false
	}
}

func sendProxmoxConsoleRemoteError(sender remoteaccess.Sender, sessionID string, reason string) {
	if sender == nil {
		return
	}

	_ = sender.SendFrame(remoteaccess.Frame{
		SessionID: sessionID,
		FrameType: consoleFrameTypeError,
		Reason:    reason,
	})
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
