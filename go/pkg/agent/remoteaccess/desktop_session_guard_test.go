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

func TestDesktopSessionGuardComposesRouteLifetimePolicyAndQuota(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Route.SelectedGateway = remoteAccessTestGatewayID
	target.Screen = DesktopScreenPolicy{
		MaxWidth:    1280,
		MaxHeight:   720,
		FrameRate:   1,
		BitrateBPS:  1024,
		IdleSeconds: 10,
		TTLSeconds:  30,
	}
	target.Redirection.ClipboardMode = DesktopClipboardModeTextBoth

	guard, err := NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	if guard.SessionID() != fakeRemoteSessionID || guard.LastActivityUnix() != 100 {
		t.Fatalf("guard identity/activity = %q/%d", guard.SessionID(), guard.LastActivityUnix())
	}
	if got := guard.Target(); got.Screen.FrameRate != 1 || got.Redirection.ClipboardMode != DesktopClipboardModeTextBoth {
		t.Fatalf("guard target = %#v", got)
	}

	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Width:     1280,
		Height:    720,
		Data:      []byte{0x01},
	}
	if err := guard.ValidateFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 101, 1); err != nil {
		t.Fatalf("ValidateFrame returned error: %v", err)
	}
	if guard.LastActivityUnix() != 101 {
		t.Fatalf("LastActivityUnix = %d, want 101", guard.LastActivityUnix())
	}

	if err := guard.ValidateFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 102, 2); !errors.Is(err, ErrDesktopQuotaExceeded) {
		t.Fatalf("quota error = %v, want %v", err, ErrDesktopQuotaExceeded)
	}

	clipboard := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Direction: DesktopClipboardDirectionToRemote,
		Data:      []byte("text"),
	}
	if err := guard.ValidateFrame(clipboard, desktopTestAgentID, remoteAccessTestGatewayID, 103, 3); err != nil {
		t.Fatalf("clipboard frame returned error: %v", err)
	}
}

func TestDesktopSessionGuardRejectsSessionRouteAndLifetimeViolations(t *testing.T) {
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

	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindFocus, Focused: true},
	}

	guard, err := NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	frame.SessionID = remoteAccessTestOtherSessionID
	if err := guard.ValidateFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 101, 1); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	guard, err = NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	frame.SessionID = fakeRemoteSessionID
	if err := guard.ValidateFrame(frame, "agent-2", remoteAccessTestGatewayID, 101, 1); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}

	guard, err = NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	if err := guard.ValidateFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 110, 1); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("idle-expired error = %v, want %v", err, ErrDesktopSessionExpired)
	}

	if _, err := NewDesktopSessionGuard("", target, 100); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("missing session error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	var nilGuard *DesktopSessionGuard
	if err := nilGuard.ValidateFrame(frame, desktopTestAgentID, remoteAccessTestGatewayID, 101, 1); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("nil guard error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopSessionGuardAppliesMediaAckAfterGuardValidation(t *testing.T) {
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
	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  7,
		CreditBytes:      16,
	}
	if err := guard.ApplyMediaAck(
		&window,
		ack,
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		101,
	); err != nil {
		t.Fatalf("ApplyMediaAck returned error: %v", err)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes = %d, want 17", window.RemainingBytes())
	}
	if guard.LastActivityUnix() != 101 {
		t.Fatalf("LastActivityUnix = %d, want 101", guard.LastActivityUnix())
	}

	ack.LastAcceptedSeq = 8
	if err := guard.ApplyMediaAck(
		&window,
		ack,
		desktopMediaTestMediaSessionID,
		"agent-2",
		remoteAccessTestGatewayID,
		102,
	); !errors.Is(err, ErrDesktopRouteLost) {
		t.Fatalf("route-loss error = %v, want %v", err, ErrDesktopRouteLost)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after route failure = %d, want 17", window.RemainingBytes())
	}
	if guard.LastActivityUnix() != 101 {
		t.Fatalf("LastActivityUnix after route failure = %d, want 101", guard.LastActivityUnix())
	}

	ack.LastAcceptedSeq = 7
	if err := guard.ApplyMediaAck(
		&window,
		ack,
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		102,
	); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("replay error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after replay = %d, want 17", window.RemainingBytes())
	}
	if guard.LastActivityUnix() != 101 {
		t.Fatalf("LastActivityUnix after replay = %d, want 101", guard.LastActivityUnix())
	}
}

func TestDesktopSessionGuardApplyMediaAckRejectsMissingWindow(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	target.Route.SelectedGateway = remoteAccessTestGatewayID

	guard, err := NewDesktopSessionGuard(desktopMediaTestSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}

	err = guard.ApplyMediaAck(
		nil,
		DesktopMediaAck{
			SessionBindingID: desktopMediaTestSessionID,
			MediaSessionID:   desktopMediaTestMediaSessionID,
			LastAcceptedSeq:  1,
			CreditBytes:      16,
		},
		desktopMediaTestMediaSessionID,
		desktopTestAgentID,
		remoteAccessTestGatewayID,
		101,
	)
	if !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("missing-window error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if guard.LastActivityUnix() != 100 {
		t.Fatalf("LastActivityUnix = %d, want 100", guard.LastActivityUnix())
	}
}

func TestDesktopSessionGuardBindsContentRecordingToTargetPolicy(t *testing.T) {
	t.Parallel()

	target := validDesktopTarget()
	guard, err := NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}

	update := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Data:      []byte("screen"),
	}
	clipboard := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Data:      []byte("clipboard"),
	}
	input := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindFocus},
	}

	if err := guard.ValidateContentRecording(update); !errors.Is(err, ErrDesktopContentRecord) {
		t.Fatalf("default screen recording error = %v, want %v", err, ErrDesktopContentRecord)
	}
	if err := guard.ValidateContentRecording(clipboard); !errors.Is(err, ErrDesktopContentRecord) {
		t.Fatalf("default clipboard recording error = %v, want %v", err, ErrDesktopContentRecord)
	}
	if err := guard.ValidateContentRecording(input); err != nil {
		t.Fatalf("metadata-only frame recording returned error: %v", err)
	}

	target.Recording.ScreenEnabled = true
	target.Recording.ClipboardEnabled = true
	guard, err = NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		t.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	if err := guard.ValidateContentRecording(update); err != nil {
		t.Fatalf("screen recording with policy returned error: %v", err)
	}
	if err := guard.ValidateContentRecording(clipboard); err != nil {
		t.Fatalf("clipboard recording with policy returned error: %v", err)
	}

	update.SessionID = remoteAccessTestOtherSessionID
	if err := guard.ValidateContentRecording(update); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch recording error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	var nilGuard *DesktopSessionGuard
	if err := nilGuard.ValidateContentRecording(input); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("nil guard recording error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopFrameQuotaWindowEnforcesFrameRateAndBitrate(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  2,
		BitrateBPS: 16,
	}
	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Width:     1280,
		Height:    720,
		Data:      []byte{0x01},
	}
	quota := NewDesktopFrameQuotaWindow(policy)

	if err := quota.Consume(frame, 1); err != nil {
		t.Fatalf("first frame quota returned error: %v", err)
	}
	if err := quota.Consume(frame, 2); err != nil {
		t.Fatalf("second frame quota returned error: %v", err)
	}
	if err := quota.Consume(frame, 3); !errors.Is(err, ErrDesktopQuotaExceeded) {
		t.Fatalf("frame-rate quota error = %v, want %v", err, ErrDesktopQuotaExceeded)
	}

	quota = NewDesktopFrameQuotaWindow(policy)
	frame.Data = []byte{0x01, 0x02, 0x03}
	if err := quota.Consume(frame, 1); !errors.Is(err, ErrDesktopQuotaExceeded) {
		t.Fatalf("bitrate quota error = %v, want %v", err, ErrDesktopQuotaExceeded)
	}

	quota = NewDesktopFrameQuotaWindow(policy)
	frame.Data = []byte{0x01}
	if err := quota.Consume(frame, 1); err != nil {
		t.Fatalf("frame before reset returned error: %v", err)
	}
	if err := quota.Consume(frame, desktopQuotaWindowNanos+1); err != nil {
		t.Fatalf("frame after reset returned error: %v", err)
	}
	if err := quota.Consume(DesktopFrame{FrameType: DesktopFrameTypeInput}, 0); err != nil {
		t.Fatalf("non-update frame quota returned error: %v", err)
	}
	if err := quota.Consume(frame, 0); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("missing timestamp error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestValidateDesktopSessionLifetimeEnforcesIdleAndTTL(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:    1280,
		MaxHeight:   720,
		FrameRate:   24,
		BitrateBPS:  4_000_000,
		IdleSeconds: 10,
		TTLSeconds:  30,
	}

	if err := ValidateDesktopSessionLifetime(policy, 100, 105, 109); err != nil {
		t.Fatalf("active session returned error: %v", err)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 105, 115); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("idle timeout error = %v, want %v", err, ErrDesktopSessionExpired)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 125, 130); !errors.Is(err, ErrDesktopSessionExpired) {
		t.Fatalf("ttl timeout error = %v, want %v", err, ErrDesktopSessionExpired)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 0, 109); err != nil {
		t.Fatalf("missing last activity fallback returned error: %v", err)
	}
	if err := ValidateDesktopSessionLifetime(policy, 100, 105, 99); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("clock regression error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if err := ValidateDesktopSessionLifetime(policy, 0, 0, 109); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("invalid timestamp error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}
