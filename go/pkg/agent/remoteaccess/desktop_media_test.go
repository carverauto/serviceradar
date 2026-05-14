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
	"bytes"
	"encoding/binary"
	"errors"
	"testing"
)

const (
	desktopMediaTestSessionID      = "session-1"
	desktopMediaTestMediaSessionID = "media-1"
)

func TestDesktopMediaFrameBinaryEnvelopeRoundTrips(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{MaxWidth: 1280, MaxHeight: 720}
	frame := DesktopMediaFrame{
		SessionBindingID:  desktopMediaTestSessionID,
		MediaSessionID:    desktopMediaTestMediaSessionID,
		Sequence:          42,
		TimestampUnixNano: 1_700_000_000,
		Width:             1280,
		Height:            720,
		PayloadFamily:     DesktopMediaPayloadDirtyRect,
		Encoding:          "bgra",
		Metadata:          []byte(`{"x":10,"y":20,"width":100,"height":80}`),
		Payload:           []byte{1, 2, 3, 4},
		Flags:             DesktopMediaFlagKeyframe | DesktopMediaFlagFullFrame,
	}

	encoded, err := EncodeDesktopMediaFrame(frame, policy)
	if err != nil {
		t.Fatalf("EncodeDesktopMediaFrame returned error: %v", err)
	}

	if string(encoded[0:4]) != DesktopMediaMagic {
		t.Fatalf("magic = %q, want %q", string(encoded[0:4]), DesktopMediaMagic)
	}
	if encoded[4] != DesktopMediaVersion {
		t.Fatalf("version = %d, want %d", encoded[4], DesktopMediaVersion)
	}
	if binary.BigEndian.Uint64(encoded[8:16]) != frame.Sequence {
		t.Fatalf("sequence header mismatch")
	}

	got, err := DecodeDesktopMediaFrame(encoded, policy)
	if err != nil {
		t.Fatalf("DecodeDesktopMediaFrame returned error: %v", err)
	}

	if got.SessionBindingID != frame.SessionBindingID ||
		got.MediaSessionID != frame.MediaSessionID ||
		got.Sequence != frame.Sequence ||
		got.TimestampUnixNano != frame.TimestampUnixNano ||
		got.Width != frame.Width ||
		got.Height != frame.Height ||
		got.PayloadFamily != frame.PayloadFamily ||
		got.Encoding != frame.Encoding ||
		got.Flags != frame.Flags {
		t.Fatalf("decoded frame = %#v, want %#v", got, frame)
	}
	if !bytes.Equal(got.Metadata, frame.Metadata) || !bytes.Equal(got.Payload, frame.Payload) {
		t.Fatalf("decoded payload mismatch: %#v", got)
	}
}

func TestDesktopMediaFrameValidation(t *testing.T) {
	t.Parallel()

	policy := DesktopScreenPolicy{MaxWidth: 1280, MaxHeight: 720}
	valid := DesktopMediaFrame{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		Width:            1280,
		Height:           720,
		PayloadFamily:    DesktopMediaPayloadVideo,
		Payload:          []byte("frame"),
	}

	tests := []struct {
		name   string
		mutate func(*DesktopMediaFrame)
	}{
		{
			name: "missing session binding",
			mutate: func(frame *DesktopMediaFrame) {
				frame.SessionBindingID = ""
			},
		},
		{
			name: "missing media session",
			mutate: func(frame *DesktopMediaFrame) {
				frame.MediaSessionID = ""
			},
		},
		{
			name: "unsupported payload family",
			mutate: func(frame *DesktopMediaFrame) {
				frame.PayloadFamily = "bitmap"
			},
		},
		{
			name: "dimensions exceed policy",
			mutate: func(frame *DesktopMediaFrame) {
				frame.Width = 1281
			},
		},
		{
			name: "metadata too large",
			mutate: func(frame *DesktopMediaFrame) {
				frame.PayloadFamily = DesktopMediaPayloadMetadata
				frame.Width = 0
				frame.Height = 0
				frame.Metadata = make([]byte, DesktopMediaMaxMetadata+1)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			frame := valid
			tt.mutate(&frame)

			if err := ValidateDesktopMediaFrame(frame, policy); !errors.Is(err, ErrInvalidDesktopMediaFrame) {
				t.Fatalf("ValidateDesktopMediaFrame error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
			}
		})
	}
}

func TestDesktopMediaFrameRejectsTruncatedPayload(t *testing.T) {
	t.Parallel()

	frame := DesktopMediaFrame{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		Width:            640,
		Height:           480,
		PayloadFamily:    DesktopMediaPayloadTile,
		Payload:          []byte{1, 2, 3, 4},
	}
	encoded, err := EncodeDesktopMediaFrame(frame, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
	if err != nil {
		t.Fatalf("EncodeDesktopMediaFrame returned error: %v", err)
	}

	_, err = DecodeDesktopMediaFrame(encoded[:len(encoded)-1], DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
	if !errors.Is(err, ErrInvalidDesktopMediaFrame) {
		t.Fatalf("DecodeDesktopMediaFrame error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
	}
}

func TestDesktopMediaCreditWindowConsumesAndAdjustsCredit(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(8, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	frame := DesktopMediaFrame{Payload: []byte{1, 2, 3}, Metadata: []byte{4}}
	if !window.CanSend(frame) {
		t.Fatalf("CanSend returned false with available credit")
	}
	if err := window.Consume(frame); err != nil {
		t.Fatalf("Consume returned error: %v", err)
	}
	if window.RemainingBytes() != 4 {
		t.Fatalf("RemainingBytes = %d, want 4", window.RemainingBytes())
	}

	frame.Payload = []byte{1, 2, 3, 4, 5}
	if window.CanSend(frame) {
		t.Fatalf("CanSend returned true with exhausted credit")
	}
	if err := window.Consume(frame); !errors.Is(err, ErrDesktopMediaNoCredit) {
		t.Fatalf("Consume error = %v, want %v", err, ErrDesktopMediaNoCredit)
	}

	window.Adjust(10)
	if window.RemainingBytes() != 14 {
		t.Fatalf("RemainingBytes after adjust = %d, want 14", window.RemainingBytes())
	}
	if err := window.Consume(frame); err != nil {
		t.Fatalf("Consume after adjust returned error: %v", err)
	}
}

func TestDesktopMediaCreditWindowAppliesValidatedAck(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  42,
		CreditBytes:      16,
		QualityLevel:     "low",
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck returned error: %v", err)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after ack = %d, want 17", window.RemainingBytes())
	}

	ack.MediaSessionID = "other-media"
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ApplyAck mismatch error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}

func TestValidateDesktopMediaAckRejectsAmbiguousFlowControl(t *testing.T) {
	t.Parallel()

	err := ValidateDesktopMediaAck(
		DesktopMediaAck{
			SessionBindingID: desktopMediaTestSessionID,
			MediaSessionID:   desktopMediaTestMediaSessionID,
			Pause:            true,
			Resume:           true,
		},
		desktopMediaTestSessionID,
		desktopMediaTestMediaSessionID,
	)
	if !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ValidateDesktopMediaAck error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}

func TestDesktopMediaCreditWindowAllowsEOFWithoutCredit(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 1)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}
	if err := window.Consume(DesktopMediaFrame{Flags: DesktopMediaFlagEndOfStream}); err != nil {
		t.Fatalf("Consume EOF returned error: %v", err)
	}
}
