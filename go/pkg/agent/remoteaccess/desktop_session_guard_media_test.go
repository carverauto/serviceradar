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

package remoteaccess

import (
	"errors"
	"testing"
)

func TestDesktopSessionGuardValidatesMediaFrames(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Route.SelectedGateway = remoteAccessTestGatewayID
	target.Screen = DesktopScreenPolicy{
		MaxWidth:    1280,
		MaxHeight:   720,
		FrameRate:   24,
		BitrateBPS:  4_000_000,
		IdleSeconds: 10,
		TTLSeconds:  30,
	}
	guard, err := NewDesktopSessionGuard(desktopMediaTestSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}

	frame := DesktopMediaFrame{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		Sequence:         1,
		Width:            1280,
		Height:           720,
		PayloadFamily:    DesktopMediaPayloadDirtyRect,
		Encoding:         "rgba",
		Payload:          []byte{1, 2, 3, 4},
	}
	if err := guard.ValidateMediaFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 101); err != nil {
		t.Fatalf("ValidateMediaFrame returned error: %v", err)
	}
	if guard.LastActivityUnix() != 101 {
		t.Fatalf("LastActivityUnix = %d, want 101", guard.LastActivityUnix())
	}

	frame.SessionBindingID = remoteAccessTestOtherSessionID
	if err := guard.ValidateMediaFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 102); !errors.Is(err, ErrInvalidDesktopMediaFrame) {
		t.Fatalf("session mismatch error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
	}

	frame.SessionBindingID = desktopMediaTestSessionID
	if err := guard.ValidateMediaFrame(frame, "agent-2", remoteAccessTestGatewayID, 102); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}

	if err := guard.ValidateMediaFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 111); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("idle-expired error = %v, want %v", err, ErrDesktopSessionExpired)
	}

	guard, err = NewDesktopSessionGuard(desktopMediaTestSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	frame.Width = 1281
	if err := guard.ValidateMediaFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 101); !errors.Is(err, ErrInvalidDesktopMediaFrame) {
		t.Fatalf("policy error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
	}

	var nilGuard *DesktopSessionGuard
	if err := nilGuard.ValidateMediaFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 101); !errors.Is(err, ErrInvalidDesktopMediaFrame) {
		t.Fatalf("nil guard error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
	}
}

func TestDesktopSessionGuardValidatesMediaAcks(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Route.SelectedGateway = remoteAccessTestGatewayID
	target.Screen = DesktopScreenPolicy{
		MaxWidth:    1280,
		MaxHeight:   720,
		FrameRate:   24,
		BitrateBPS:  4_000_000,
		IdleSeconds: 10,
		TTLSeconds:  30,
	}
	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  1,
		CreditBytes:      1024,
		QualityLevel:     DesktopMediaQualityLow,
	}

	guard, err := NewDesktopSessionGuard(desktopMediaTestSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	if err := guard.ValidateMediaAck(
		ack,
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		101,
	); err != nil {
		t.Fatalf("ValidateMediaAck returned error: %v", err)
	}
	if guard.LastActivityUnix() != 101 {
		t.Fatalf("LastActivityUnix = %d, want 101", guard.LastActivityUnix())
	}

	ack.MediaSessionID = "other-media"
	if err := guard.ValidateMediaAck(
		ack,
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		102,
	); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("media mismatch error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}

	ack.MediaSessionID = desktopMediaTestMediaSessionID
	if err := guard.ValidateMediaAck(
		ack,
		desktopMediaTestMediaSessionID,
		"agent-2",
		remoteAccessTestGatewayID,
		102,
	); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}

	if err := guard.ValidateMediaAck(
		ack,
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		111,
	); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("idle-expired error = %v, want %v", err, ErrDesktopSessionExpired)
	}

	guard, err = NewDesktopSessionGuard(desktopMediaTestSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	ack.QualityLevel = "ultra"
	if err := guard.ValidateMediaAck(
		ack,
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		101,
	); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("quality error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}

	ack.QualityLevel = DesktopMediaQualityLow
	if err := guard.ValidateMediaAck(
		ack,
		"",
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		101,
	); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("missing expected media id error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}

	var nilGuard *DesktopSessionGuard
	if err := nilGuard.ValidateMediaAck(
		ack,
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		101,
	); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("nil guard error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}
