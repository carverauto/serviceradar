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
	"encoding/json"
	"errors"
	"testing"
)

func TestValidateDesktopFrameEnforcesGraphicalPolicy(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}

	if err := ValidateDesktopFrame(DesktopFrame{
		SessionID: "session-1",
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeUpdate,
		Width:     1280,
		Height:    720,
		Data:      []byte("frame"),
	}, policy); err != nil {
		t.Fatalf("valid update returned error: %v", err)
	}

	tests := []DesktopFrame{
		{SessionID: "session-1", Protocol: ProtocolRDP, FrameType: DesktopFrameTypeUpdate, Width: 1281, Height: 720},
		{SessionID: "session-1", Protocol: ProtocolRDP, FrameType: DesktopFrameTypeInput},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{MaxFrameRate: 25},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{MaxBitrate: 4_000_001},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{Width: 1281},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeQuality,
			Quality:   &DesktopQuality{Height: 721},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeInput,
			Input:     &DesktopInputEvent{Kind: "unknown"},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeInput,
			Input: &DesktopInputEvent{
				Kind: DesktopInputKindPointer,
				X:    1281,
				Y:    360,
			},
		},
		{
			SessionID: "session-1",
			Protocol:  ProtocolRDP,
			FrameType: DesktopFrameTypeInput,
			Input: &DesktopInputEvent{
				Kind: DesktopInputKindKey,
				Key:  string(make([]byte, DesktopMaxInputTokenSize+1)),
			},
		},
	}

	for _, frame := range tests {
		_, err := json.Marshal(frame)
		if err != nil {
			t.Fatalf("Marshal returned error: %v", err)
		}
		if err := ValidateDesktopFrame(frame, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
			t.Fatalf("ValidateDesktopFrame(%#v) = %v, want %v", frame, err, ErrInvalidDesktopFrame)
		}
	}
}

func TestValidateDesktopFrameRequiresExplicitClipboardPolicy(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Direction: DesktopClipboardDirectionToBrowser,
		Data:      []byte("clipboard text"),
	}

	if err := ValidateDesktopFrame(frame, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("default clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeDisabled,
	}); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("disabled clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextBoth,
	}); err != nil {
		t.Fatalf("enabled clipboard validation returned error: %v", err)
	}
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextToRemote,
	}); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("wrong-direction clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	frame.Direction = ""
	if err := ValidateDesktopFrameWithPolicy(frame, policy, DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextBoth,
	}); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("missing-direction clipboard validation error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopFramePayloadPolicyAwareHelpersGateClipboard(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	redirection := DesktopRedirectionPolicy{
		ClipboardMode: DesktopClipboardModeTextBoth,
	}
	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeClipboard,
		Direction: DesktopClipboardDirectionToBrowser,
		Data:      []byte("clipboard text"),
	}

	if _, err := EncodeDesktopFramePayload(frame, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("default encode clipboard error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	data, err := EncodeDesktopFramePayloadWithPolicy(frame, policy, redirection)
	if err != nil {
		t.Fatalf("EncodeDesktopFramePayloadWithPolicy returned error: %v", err)
	}
	if _, err := DecodeDesktopFramePayload(data, policy); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("default decode clipboard error = %v, want %v", err, ErrInvalidDesktopFrame)
	}

	got, err := DecodeDesktopFramePayloadForSessionWithPolicy(
		data,
		policy,
		redirection,
		fakeRemoteSessionID,
	)
	if err != nil {
		t.Fatalf("DecodeDesktopFramePayloadForSessionWithPolicy returned error: %v", err)
	}
	if got.FrameType != DesktopFrameTypeClipboard || string(got.Data) != "clipboard text" {
		t.Fatalf("decoded clipboard frame = %#v", got)
	}

	_, err = DecodeDesktopFramePayloadForSessionWithPolicy(data, policy, redirection, remoteAccessTestOtherSessionID)
	if !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDesktopFramePayloadRoundTripsThroughConsoleFrameData(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	frame := DesktopFrame{
		SessionID: "session-1",
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input: &DesktopInputEvent{
			Kind: DesktopInputKindPointer,
			X:    640,
			Y:    360,
		},
	}

	data, err := EncodeDesktopFramePayload(frame, policy)
	if err != nil {
		t.Fatalf("EncodeDesktopFramePayload returned error: %v", err)
	}

	got, err := DecodeDesktopFramePayload(data, policy)
	if err != nil {
		t.Fatalf("DecodeDesktopFramePayload returned error: %v", err)
	}
	if got.SessionID != frame.SessionID || got.FrameType != frame.FrameType || got.Input == nil {
		t.Fatalf("decoded frame = %#v", got)
	}
	if got.Input.Kind != DesktopInputKindPointer || got.Input.X != 640 || got.Input.Y != 360 {
		t.Fatalf("decoded input = %#v", got.Input)
	}

	_, err = DecodeDesktopFramePayload([]byte(`{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.resize","width":9999,"height":720}`), policy)
	if !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("invalid decoded frame error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}

func TestDecodeDesktopFramePayloadForSessionRejectsMismatchedSession(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{
		MaxWidth:   1280,
		MaxHeight:  720,
		FrameRate:  24,
		BitrateBPS: 4_000_000,
	}
	data, err := EncodeDesktopFramePayload(DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeDisconnect,
	}, policy)
	if err != nil {
		t.Fatalf("EncodeDesktopFramePayload returned error: %v", err)
	}

	if _, err := DecodeDesktopFramePayloadForSession(data, policy, fakeRemoteSessionID); err != nil {
		t.Fatalf("DecodeDesktopFramePayloadForSession returned error: %v", err)
	}
	if _, err := DecodeDesktopFramePayloadForSession(data, policy, remoteAccessTestOtherSessionID); !errors.Is(err, ErrInvalidDesktopFrame) {
		t.Fatalf("session mismatch error = %v, want %v", err, ErrInvalidDesktopFrame)
	}
}
