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
			name: "unsupported flags",
			mutate: func(frame *DesktopMediaFrame) {
				frame.Flags = 0x20
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

func TestDesktopMediaFrameRejectsTrailingPayload(t *testing.T) {
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

	encoded = append(encoded, 0xff)
	_, err = DecodeDesktopMediaFrame(encoded, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
	if !errors.Is(err, ErrInvalidDesktopMediaFrame) {
		t.Fatalf("DecodeDesktopMediaFrame error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
	}
}

func TestDesktopMediaFrameRejectsReservedHeaderBytes(t *testing.T) {
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

	tests := []struct {
		name   string
		mutate func([]byte)
	}{
		{
			name: "reserved byte",
			mutate: func(data []byte) {
				data[7] = 1
			},
		},
		{
			name: "reserved uint16",
			mutate: func(data []byte) {
				binary.BigEndian.PutUint16(data[46:48], 1)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			data := append([]byte(nil), encoded...)
			tt.mutate(data)

			_, err := DecodeDesktopMediaFrame(data, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
			if !errors.Is(err, ErrInvalidDesktopMediaFrame) {
				t.Fatalf("DecodeDesktopMediaFrame error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
			}
		})
	}
}

func TestDesktopMediaFramePartsReuseHeaderAndPreservePayloadSlice(t *testing.T) {
	t.Parallel()

	header := make([]byte, DesktopMediaHeaderSize)
	for index := range header {
		header[index] = 0xff
	}

	payload := []byte{1, 2, 3, 4}
	metadata := []byte(`{"tile":1}`)
	frame := DesktopMediaFrame{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		Width:            640,
		Height:           480,
		PayloadFamily:    DesktopMediaPayloadTile,
		Encoding:         "rgba",
		Metadata:         metadata,
		Payload:          payload,
	}

	parts, err := BuildDesktopMediaFrameParts(frame, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480}, header)
	if err != nil {
		t.Fatalf("BuildDesktopMediaFrameParts returned error: %v", err)
	}

	if &parts.Header[0] != &header[0] {
		t.Fatalf("header was not reused")
	}
	if parts.Header[7] != 0 || binary.BigEndian.Uint16(parts.Header[46:48]) != 0 {
		t.Fatalf("reserved header bytes were not reset: %#v", parts.Header)
	}
	if &parts.Payload[0] != &payload[0] {
		t.Fatalf("payload was copied")
	}
	if &parts.Metadata[0] != &metadata[0] {
		t.Fatalf("metadata was copied")
	}

	encoded := parts.AppendTo(make([]byte, 0, parts.Len()))
	got, err := DecodeDesktopMediaFrame(encoded, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
	if err != nil {
		t.Fatalf("DecodeDesktopMediaFrame returned error: %v", err)
	}
	if !bytes.Equal(got.Payload, payload) || !bytes.Equal(got.Metadata, metadata) {
		t.Fatalf("decoded frame = %#v", got)
	}
}

func TestDesktopMediaFramePartsWithStaticFieldsAvoidsStableFieldCopies(t *testing.T) {
	t.Parallel()

	staticFields, err := NewDesktopMediaFrameStaticFields(
		desktopMediaTestSessionID,
		desktopMediaTestMediaSessionID,
		"rgba",
	)
	if err != nil {
		t.Fatalf("NewDesktopMediaFrameStaticFields returned error: %v", err)
	}

	frame := DesktopMediaFrame{
		Width:         640,
		Height:        480,
		PayloadFamily: DesktopMediaPayloadTile,
		Metadata:      []byte(`{"tile":1}`),
		Payload:       []byte{1, 2, 3, 4},
	}
	parts, err := BuildDesktopMediaFramePartsWithStaticFields(
		frame,
		DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480},
		make([]byte, DesktopMediaHeaderSize),
		staticFields,
	)
	if err != nil {
		t.Fatalf("BuildDesktopMediaFramePartsWithStaticFields returned error: %v", err)
	}

	if &parts.SessionBindingID[0] != &staticFields.sessionBindingID[0] {
		t.Fatalf("session binding bytes were copied")
	}
	if &parts.MediaSessionID[0] != &staticFields.mediaSessionID[0] {
		t.Fatalf("media session bytes were copied")
	}
	if &parts.Encoding[0] != &staticFields.encoding[0] {
		t.Fatalf("encoding bytes were copied")
	}

	got, err := DecodeDesktopMediaFrame(
		parts.AppendTo(make([]byte, 0, parts.Len())),
		DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480},
	)
	if err != nil {
		t.Fatalf("DecodeDesktopMediaFrame returned error: %v", err)
	}
	if got.SessionBindingID != desktopMediaTestSessionID ||
		got.MediaSessionID != desktopMediaTestMediaSessionID ||
		got.Encoding != "rgba" {
		t.Fatalf("decoded static fields = %#v", got)
	}
}

func TestDecodeDesktopMediaFrameViewAliasesPayload(t *testing.T) {
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

	view, err := DecodeDesktopMediaFrameView(encoded, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
	if err != nil {
		t.Fatalf("DecodeDesktopMediaFrameView returned error: %v", err)
	}
	view.Payload[0] = 9

	copied, err := DecodeDesktopMediaFrame(encoded, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
	if err != nil {
		t.Fatalf("DecodeDesktopMediaFrame returned error: %v", err)
	}
	if copied.Payload[0] != 9 {
		t.Fatalf("view payload did not alias encoded frame")
	}

	copied.Payload[0] = 7
	roundTrip, err := DecodeDesktopMediaFrame(encoded, DesktopScreenPolicy{MaxWidth: 640, MaxHeight: 480})
	if err != nil {
		t.Fatalf("DecodeDesktopMediaFrame returned error: %v", err)
	}
	if roundTrip.Payload[0] != 9 {
		t.Fatalf("copying decoder aliased encoded frame")
	}
}
