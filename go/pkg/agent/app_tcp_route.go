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

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

var (
	errApplicationSessionNotOpen = errors.New("application access session is not open")
	errApplicationSessionExists  = errors.New("application access session already exists")
	errApplicationDataOutOfOrder = errors.New("application request data sequence is not greater than the previous chunk")
	errApplicationDataDirection  = errors.New("application data frame direction is not allowed")
	errTCPSessionNotOpen         = errors.New("tcp access session is not open")
	errTCPSessionExists          = errors.New("tcp access session already exists")
)

type applicationHTTPRequestState struct {
	request    remoteaccess.ApplicationRequestPayload
	hasRequest bool
	body       []byte
	lastSeq    uint64
	eof        bool
}

func isApplicationAccessFrameType(frameType string) bool {
	switch frameType {
	case remoteaccess.FrameTypeApplicationOpen,
		remoteaccess.FrameTypeApplicationRequest,
		remoteaccess.FrameTypeApplicationData,
		remoteaccess.FrameTypeApplicationClose:
		return true
	default:
		return false
	}
}

func isTCPAccessFrameType(frameType string) bool {
	switch frameType {
	case remoteaccess.FrameTypeTCPOpen,
		remoteaccess.FrameTypeTCPData,
		remoteaccess.FrameTypeTCPClose:
		return true
	default:
		return false
	}
}

func (p *PushLoop) handleAppTCPFrame(ctx context.Context, frame *proto.ConsoleFrame, sender *controlStreamSender) {
	if frame == nil || sender == nil {
		return
	}

	if p.remoteConsoleManager == nil {
		p.remoteConsoleManager = newRemoteConsoleManagerWithRoute(
			p.agentID(),
			gatewayIDFromClient(p.gateway),
			p.logger,
		)
	}

	if frame.GetFrameType() == remoteaccess.FrameTypeApplicationOpen ||
		frame.GetFrameType() == remoteaccess.FrameTypeTCPOpen {
		if err := p.remoteConsoleManager.registerFrameAuthenticator(frame); err != nil {
			signedSender := p.remoteConsoleManager.signingSender(sender)
			if isTCPAccessFrameType(frame.GetFrameType()) {
				sendTCPError(
					signedSender,
					frame.GetSessionId(),
					"invalid_open_payload",
					err.Error(),
					remoteaccess.TCPStatusFailed,
				)
			} else {
				sendApplicationError(signedSender, frame.GetSessionId(), "invalid_open_payload", err.Error())
			}

			return
		}
	}

	signedSender := p.remoteConsoleManager.signingSender(sender)

	switch {
	case isApplicationAccessFrameType(frame.GetFrameType()):
		p.handleApplicationAccessFrame(ctx, frame, signedSender)

	case isTCPAccessFrameType(frame.GetFrameType()):
		p.handleTCPAccessFrame(ctx, frame, signedSender)
	}
}

func (p *PushLoop) handleApplicationAccessFrame(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	switch frame.GetFrameType() {
	case remoteaccess.FrameTypeApplicationOpen:
		p.openApplicationAccess(frame, sender)
	case remoteaccess.FrameTypeApplicationRequest:
		p.executeApplicationRequest(ctx, frame, sender)
	case remoteaccess.FrameTypeApplicationData:
		p.handleApplicationRequestData(ctx, frame, sender)
	case remoteaccess.FrameTypeApplicationClose:
		p.closeApplicationAccess(frame, sender)
	default:
		sendApplicationError(sender, frame.GetSessionId(), "unsupported_frame", "unsupported application access frame")
	}
}

func (p *PushLoop) openApplicationAccess(frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	var payload remoteaccess.ApplicationOpenPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "invalid_open_payload", err.Error())
		return
	}
	if payload.SessionID == "" {
		payload.SessionID = frame.GetSessionId()
	}

	p.applicationHTTPMu.Lock()
	if p.applicationHTTPSessions != nil && p.applicationHTTPSessions[frame.GetSessionId()] != nil {
		p.applicationHTTPMu.Unlock()
		sendApplicationError(sender, frame.GetSessionId(), "session_exists", errApplicationSessionExists.Error())
		return
	}
	p.applicationHTTPMu.Unlock()

	adapter, err := remoteaccess.NewApplicationHTTPAdapter(payload, remoteaccess.ApplicationHTTPAdapterOptions{})
	if err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "open_failed", err.Error())
		return
	}

	p.applicationHTTPMu.Lock()
	if p.applicationHTTPSessions == nil {
		p.applicationHTTPSessions = make(map[string]*remoteaccess.ApplicationHTTPAdapter)
	}
	p.applicationHTTPSessions[frame.GetSessionId()] = adapter
	p.applicationHTTPMu.Unlock()

	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationProgress, remoteaccess.ApplicationProgressPayload{
		SessionID: frame.GetSessionId(),
		Status:    remoteaccess.ApplicationStatusStarted,
	})
}

func (p *PushLoop) executeApplicationRequest(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	adapter := p.applicationHTTPAdapter(frame.GetSessionId())
	if adapter == nil {
		sendApplicationError(sender, frame.GetSessionId(), "session_not_open", errApplicationSessionNotOpen.Error())
		return
	}

	var payload remoteaccess.ApplicationRequestPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "invalid_request_payload", err.Error())
		return
	}
	if payload.SessionID == "" {
		payload.SessionID = frame.GetSessionId()
	}

	if applicationRequestMayHaveBody(payload.Method) {
		state := p.storeApplicationRequest(frame.GetSessionId(), payload)
		if !state.eof {
			sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationProgress, remoteaccess.ApplicationProgressPayload{
				RequestID:    payload.RequestID,
				SessionID:    payload.SessionID,
				Status:       remoteaccess.ApplicationStatusInProgress,
				RequestBytes: int64(len(state.body)),
			})
			return
		}

		body := append([]byte(nil), state.body...)
		p.dropApplicationRequest(frame.GetSessionId(), payload.RequestID)
		p.executeApplicationHTTPRequest(ctx, frame.GetSessionId(), adapter, payload, body, sender)
		return
	}

	p.dropApplicationRequest(frame.GetSessionId(), payload.RequestID)
	p.executeApplicationHTTPRequest(ctx, frame.GetSessionId(), adapter, payload, nil, sender)
}

func (p *PushLoop) executeApplicationHTTPRequest(
	ctx context.Context,
	sessionID string,
	adapter *remoteaccess.ApplicationHTTPAdapter,
	payload remoteaccess.ApplicationRequestPayload,
	body []byte,
	sender proxmoxConsoleSender,
) {
	result, err := adapter.Execute(ctx, payload, body)
	if err != nil {
		sendApplicationError(sender, sessionID, "request_failed", err.Error())
		return
	}

	sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeApplicationResponseMetadata, result.Metadata)
	sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeApplicationData, result.Data)
	sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeApplicationProgress, result.Progress)
}

func (p *PushLoop) handleApplicationRequestData(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	adapter := p.applicationHTTPAdapter(frame.GetSessionId())
	if adapter == nil {
		sendApplicationError(sender, frame.GetSessionId(), "session_not_open", errApplicationSessionNotOpen.Error())
		return
	}

	var payload remoteaccess.ApplicationDataPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "invalid_data_payload", err.Error())
		return
	}
	if payload.SessionID == "" {
		payload.SessionID = frame.GetSessionId()
	}
	if err := payload.Validate(); err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "invalid_data_payload", err.Error())
		return
	}
	if payload.SessionID != frame.GetSessionId() {
		sendApplicationError(sender, frame.GetSessionId(), "request_failed", remoteaccess.ErrApplicationSessionMismatch.Error())
		return
	}
	if payload.Direction != remoteaccess.ApplicationDataDirectionRequest {
		sendApplicationError(sender, frame.GetSessionId(), "request_failed", errApplicationDataDirection.Error())
		return
	}

	state, err := p.appendApplicationRequestData(frame.GetSessionId(), payload, adapter.MaxRequestBodyBytes())
	if err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "request_failed", err.Error())
		p.dropApplicationRequest(frame.GetSessionId(), payload.RequestID)
		return
	}
	if !state.eof || !state.hasRequest {
		sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationProgress, remoteaccess.ApplicationProgressPayload{
			RequestID:    payload.RequestID,
			SessionID:    payload.SessionID,
			Status:       remoteaccess.ApplicationStatusInProgress,
			RequestBytes: int64(len(state.body)),
		})
		return
	}

	request := state.request
	body := append([]byte(nil), state.body...)
	p.dropApplicationRequest(frame.GetSessionId(), payload.RequestID)
	p.executeApplicationHTTPRequest(ctx, frame.GetSessionId(), adapter, request, body, sender)
}

func (p *PushLoop) closeApplicationAccess(frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	if adapter := p.dropApplicationHTTPSession(frame.GetSessionId()); adapter != nil {
		adapter.Close()
	}

	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationClose, remoteaccess.ApplicationClosePayload{
		SessionID: frame.GetSessionId(),
		Reason:    frame.GetReason(),
	})
}

func (p *PushLoop) applicationHTTPAdapter(sessionID string) *remoteaccess.ApplicationHTTPAdapter {
	p.applicationHTTPMu.Lock()
	defer p.applicationHTTPMu.Unlock()

	return p.applicationHTTPSessions[sessionID]
}

func (p *PushLoop) dropApplicationHTTPSession(sessionID string) *remoteaccess.ApplicationHTTPAdapter {
	p.applicationHTTPMu.Lock()
	defer p.applicationHTTPMu.Unlock()

	adapter := p.applicationHTTPSessions[sessionID]
	delete(p.applicationHTTPSessions, sessionID)
	delete(p.applicationHTTPRequests, sessionID)
	return adapter
}

func (p *PushLoop) storeApplicationRequest(
	sessionID string,
	request remoteaccess.ApplicationRequestPayload,
) applicationHTTPRequestState {
	p.applicationHTTPMu.Lock()
	defer p.applicationHTTPMu.Unlock()

	state := p.applicationRequestStateLocked(sessionID, request.RequestID)
	state.request = request
	state.hasRequest = true
	return *state
}

func (p *PushLoop) appendApplicationRequestData(
	sessionID string,
	payload remoteaccess.ApplicationDataPayload,
	maxBodyBytes int64,
) (applicationHTTPRequestState, error) {
	p.applicationHTTPMu.Lock()
	defer p.applicationHTTPMu.Unlock()

	state := p.applicationRequestStateLocked(sessionID, payload.RequestID)
	if payload.Sequence <= state.lastSeq {
		return applicationHTTPRequestState{}, errApplicationDataOutOfOrder
	}
	if maxBodyBytes > 0 && int64(len(state.body)+len(payload.Data)) > maxBodyBytes {
		return applicationHTTPRequestState{}, remoteaccess.ErrApplicationRequestTooLarge
	}

	state.lastSeq = payload.Sequence
	state.body = append(state.body, payload.Data...)
	state.eof = payload.EOF
	return *state, nil
}

func (p *PushLoop) applicationRequestStateLocked(sessionID string, requestID string) *applicationHTTPRequestState {
	if p.applicationHTTPRequests == nil {
		p.applicationHTTPRequests = make(map[string]map[string]*applicationHTTPRequestState)
	}
	requests := p.applicationHTTPRequests[sessionID]
	if requests == nil {
		requests = make(map[string]*applicationHTTPRequestState)
		p.applicationHTTPRequests[sessionID] = requests
	}
	state := requests[requestID]
	if state == nil {
		state = &applicationHTTPRequestState{}
		requests[requestID] = state
	}
	return state
}

func (p *PushLoop) dropApplicationRequest(sessionID string, requestID string) {
	p.applicationHTTPMu.Lock()
	defer p.applicationHTTPMu.Unlock()

	requests := p.applicationHTTPRequests[sessionID]
	delete(requests, requestID)
	if len(requests) == 0 {
		delete(p.applicationHTTPRequests, sessionID)
	}
}

func applicationRequestMayHaveBody(method string) bool {
	switch strings.ToUpper(strings.TrimSpace(method)) {
	case "GET", "HEAD", "OPTIONS":
		return false
	default:
		return true
	}
}

func (p *PushLoop) handleTCPAccessFrame(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	switch frame.GetFrameType() {
	case remoteaccess.FrameTypeTCPOpen:
		p.openTCPAccess(ctx, frame, sender)
	case remoteaccess.FrameTypeTCPData:
		p.writeTCPAccess(frame, sender)
	case remoteaccess.FrameTypeTCPClose:
		p.closeTCPAccess(frame, sender)
	default:
		sendTCPError(sender, frame.GetSessionId(), "unsupported_frame", "unsupported tcp access frame", remoteaccess.TCPStatusFailed)
	}
}

func (p *PushLoop) openTCPAccess(ctx context.Context, frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	var payload remoteaccess.TCPOpenPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		sendTCPError(sender, frame.GetSessionId(), "invalid_open_payload", err.Error(), remoteaccess.TCPStatusFailed)
		return
	}
	if payload.SessionID == "" {
		payload.SessionID = frame.GetSessionId()
	}

	p.tcpMu.Lock()
	if p.tcpSessions != nil && p.tcpSessions[frame.GetSessionId()] != nil {
		p.tcpMu.Unlock()
		sendTCPError(sender, frame.GetSessionId(), "session_exists", errTCPSessionExists.Error(), remoteaccess.TCPStatusFailed)
		return
	}
	p.tcpMu.Unlock()

	adapter, err := remoteaccess.NewTCPAdapter(ctx, payload, remoteaccess.TCPAdapterOptions{})
	if err != nil {
		sendTCPError(sender, frame.GetSessionId(), "open_failed", err.Error(), remoteaccess.TCPStatusFailed)
		return
	}

	p.tcpMu.Lock()
	if p.tcpSessions == nil {
		p.tcpSessions = make(map[string]*remoteaccess.TCPAdapter)
	}
	p.tcpSessions[frame.GetSessionId()] = adapter
	p.tcpMu.Unlock()

	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeTCPProgress, remoteaccess.TCPProgressPayload{
		SessionID:    payload.SessionID,
		ConnectionID: payload.ConnectionID,
		Status:       remoteaccess.TCPStatusStarted,
	})

	go p.readTCPAccess(ctx, frame.GetSessionId(), adapter, sender)
}

func (p *PushLoop) writeTCPAccess(frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	adapter := p.tcpAdapter(frame.GetSessionId())
	if adapter == nil {
		sendTCPError(sender, frame.GetSessionId(), "session_not_open", errTCPSessionNotOpen.Error(), remoteaccess.TCPStatusFailed)
		return
	}

	var payload remoteaccess.TCPDataPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		sendTCPError(sender, frame.GetSessionId(), "invalid_data_payload", err.Error(), remoteaccess.TCPStatusFailed)
		return
	}
	if payload.SessionID == "" {
		payload.SessionID = frame.GetSessionId()
	}

	progress, err := adapter.Write(payload)
	if err != nil {
		status := remoteaccess.TCPStatusFailed
		if errors.Is(err, remoteaccess.ErrTCPBytesInQuotaExceeded) {
			status = remoteaccess.TCPStatusQuotaExhausted
		}
		sendTCPError(sender, frame.GetSessionId(), "write_failed", err.Error(), status)
		if dropped := p.dropTCPAdapter(frame.GetSessionId()); dropped != nil {
			_ = dropped.Close()
		}
		return
	}

	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeTCPProgress, progress)
}

func (p *PushLoop) readTCPAccess(ctx context.Context, sessionID string, adapter *remoteaccess.TCPAdapter, sender proxmoxConsoleSender) {
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			if dropped := p.dropTCPAdapter(sessionID); dropped != nil {
				_ = dropped.Close()
			}
		case <-done:
		}
	}()
	defer close(done)

	for {
		frame, progress, err := adapter.Read(ctx, 0)
		if err != nil {
			switch {
			case errors.Is(err, io.EOF):
				sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeTCPData, frame)
				sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeTCPProgress, progress)
				sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeTCPClose, remoteaccess.TCPClosePayload{
					SessionID:    frame.SessionID,
					ConnectionID: frame.ConnectionID,
					Reason:       "upstream_eof",
				})
			case errors.Is(err, remoteaccess.ErrTCPBytesOutQuotaExceeded):
				sendTCPError(sender, sessionID, "quota_exhausted", err.Error(), remoteaccess.TCPStatusQuotaExhausted)
			case !errors.Is(err, remoteaccess.ErrTCPAdapterClosed):
				sendTCPError(sender, sessionID, "read_failed", err.Error(), remoteaccess.TCPStatusFailed)
			}
			if dropped := p.dropTCPAdapter(sessionID); dropped != nil {
				_ = dropped.Close()
			}
			return
		}

		sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeTCPData, frame)
		sendJSONFrame(sender, sessionID, remoteaccess.FrameTypeTCPProgress, progress)
	}
}

func (p *PushLoop) closeTCPAccess(frame *proto.ConsoleFrame, sender proxmoxConsoleSender) {
	adapter := p.dropTCPAdapter(frame.GetSessionId())
	if adapter != nil {
		_ = adapter.Close()
	}

	var payload remoteaccess.TCPClosePayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		payload = remoteaccess.TCPClosePayload{SessionID: frame.GetSessionId()}
	}
	if payload.SessionID == "" {
		payload.SessionID = frame.GetSessionId()
	}

	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeTCPClose, payload)
}

func (p *PushLoop) tcpAdapter(sessionID string) *remoteaccess.TCPAdapter {
	p.tcpMu.Lock()
	defer p.tcpMu.Unlock()

	return p.tcpSessions[sessionID]
}

func (p *PushLoop) dropTCPAdapter(sessionID string) *remoteaccess.TCPAdapter {
	p.tcpMu.Lock()
	defer p.tcpMu.Unlock()

	adapter := p.tcpSessions[sessionID]
	delete(p.tcpSessions, sessionID)
	return adapter
}

func sendApplicationError(sender proxmoxConsoleSender, sessionID string, code string, message string) {
	sendAppTCPErrorFrame(sender, sessionID, remoteaccess.FrameTypeApplicationError, remoteaccess.ApplicationErrorPayload{
		SessionID: sessionID,
		Status:    remoteaccess.ApplicationStatusFailed,
		Code:      code,
		Message:   message,
	})
}

func sendTCPError(sender proxmoxConsoleSender, sessionID string, code string, message string, status remoteaccess.RemoteAccessStreamStatus) {
	sendAppTCPErrorFrame(sender, sessionID, remoteaccess.FrameTypeTCPError, remoteaccess.TCPErrorPayload{
		SessionID: sessionID,
		Status:    status,
		Code:      code,
		Message:   message,
	})
}

func sendAppTCPErrorFrame(sender proxmoxConsoleSender, sessionID string, frameType string, payload any) {
	sendJSONFrame(sender, sessionID, frameType, payload)
}

func sendJSONFrame(sender proxmoxConsoleSender, sessionID string, frameType string, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		data = nil
	}

	_ = sender.Send(consoleControlFrame(sessionID, frameType, data, "", 0, 0, 0, "", ""))
}
