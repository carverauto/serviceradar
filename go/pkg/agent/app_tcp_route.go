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

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

const appTCPAdapterUnavailableCode = "adapter_unavailable"

var errApplicationSessionNotOpen = errors.New("application access session is not open")

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

func (p *PushLoop) handleAppTCPFrame(_ context.Context, frame *proto.ConsoleFrame, sender *controlStreamSender) {
	if frame == nil || sender == nil {
		return
	}

	switch {
	case isApplicationAccessFrameType(frame.GetFrameType()):
		p.handleApplicationAccessFrame(frame, sender)

	case isTCPAccessFrameType(frame.GetFrameType()):
		payload := remoteaccess.TCPErrorPayload{
			SessionID: frame.GetSessionId(),
			Status:    remoteaccess.TCPStatusFailed,
			Code:      appTCPAdapterUnavailableCode,
			Message:   "tcp access adapter unavailable",
		}
		sendAppTCPErrorFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeTCPError, payload)
	}
}

func (p *PushLoop) handleApplicationAccessFrame(frame *proto.ConsoleFrame, sender *controlStreamSender) {
	switch frame.GetFrameType() {
	case remoteaccess.FrameTypeApplicationOpen:
		p.openApplicationAccess(frame, sender)
	case remoteaccess.FrameTypeApplicationRequest:
		p.executeApplicationRequest(frame, sender)
	case remoteaccess.FrameTypeApplicationClose:
		p.closeApplicationAccess(frame, sender)
	default:
		sendApplicationError(sender, frame.GetSessionId(), "unsupported_frame", "unsupported application access frame")
	}
}

func (p *PushLoop) openApplicationAccess(frame *proto.ConsoleFrame, sender *controlStreamSender) {
	var payload remoteaccess.ApplicationOpenPayload
	if err := json.Unmarshal(frame.GetData(), &payload); err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "invalid_open_payload", err.Error())
		return
	}
	if payload.SessionID == "" {
		payload.SessionID = frame.GetSessionId()
	}

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

func (p *PushLoop) executeApplicationRequest(frame *proto.ConsoleFrame, sender *controlStreamSender) {
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

	result, err := adapter.Execute(context.Background(), payload, nil)
	if err != nil {
		sendApplicationError(sender, frame.GetSessionId(), "request_failed", err.Error())
		return
	}

	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationResponseMetadata, result.Metadata)
	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationData, result.Data)
	sendJSONFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationProgress, result.Progress)
}

func (p *PushLoop) closeApplicationAccess(frame *proto.ConsoleFrame, sender *controlStreamSender) {
	p.applicationHTTPMu.Lock()
	delete(p.applicationHTTPSessions, frame.GetSessionId())
	p.applicationHTTPMu.Unlock()

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

func sendApplicationError(sender *controlStreamSender, sessionID string, code string, message string) {
	sendAppTCPErrorFrame(sender, sessionID, remoteaccess.FrameTypeApplicationError, remoteaccess.ApplicationErrorPayload{
		SessionID: sessionID,
		Status:    remoteaccess.ApplicationStatusFailed,
		Code:      code,
		Message:   message,
	})
}

func sendAppTCPErrorFrame(sender *controlStreamSender, sessionID string, frameType string, payload any) {
	sendJSONFrame(sender, sessionID, frameType, payload)
}

func sendJSONFrame(sender *controlStreamSender, sessionID string, frameType string, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		data = nil
	}

	_ = sender.Send(consoleControlFrame(sessionID, frameType, data, "", 0, 0))
}
