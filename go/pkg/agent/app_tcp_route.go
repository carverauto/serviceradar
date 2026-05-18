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

	"github.com/carverauto/serviceradar/go/pkg/agent/remoteaccess"
	"github.com/carverauto/serviceradar/proto"
)

const appTCPAdapterUnavailableCode = "adapter_unavailable"

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
		payload := remoteaccess.ApplicationErrorPayload{
			SessionID: frame.GetSessionId(),
			Status:    remoteaccess.ApplicationStatusFailed,
			Code:      appTCPAdapterUnavailableCode,
			Message:   "application access adapter unavailable",
		}
		sendAppTCPErrorFrame(sender, frame.GetSessionId(), remoteaccess.FrameTypeApplicationError, payload)

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

func sendAppTCPErrorFrame(sender *controlStreamSender, sessionID string, frameType string, payload any) {
	data, err := json.Marshal(payload)
	if err != nil {
		data = nil
	}

	_ = sender.Send(consoleControlFrame(sessionID, frameType, data, "", 0, 0))
}
