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

import "testing"

func BenchmarkDesktopMediaFrameHotPath(b *testing.B) {
	policy := DesktopScreenPolicy{MaxWidth: 1920, MaxHeight: 1080}
	frame := DesktopMediaFrame{
		SessionBindingID:  desktopMediaTestSessionID,
		MediaSessionID:    desktopMediaTestMediaSessionID,
		Sequence:          42,
		TimestampUnixNano: 1_778_000_000,
		Width:             1920,
		Height:            1080,
		PayloadFamily:     DesktopMediaPayloadTile,
		Encoding:          "rgba",
		Metadata:          []byte(`{"tile_size":64,"dirty_tile_count":12}`),
		Payload:           make([]byte, 256*1024),
	}
	encoded, err := EncodeDesktopMediaFrame(frame, policy)
	if err != nil {
		b.Fatalf("EncodeDesktopMediaFrame returned error: %v", err)
	}
	staticFields, err := NewDesktopMediaFrameStaticFields(
		frame.SessionBindingID,
		frame.MediaSessionID,
		frame.Encoding,
	)
	if err != nil {
		b.Fatalf("NewDesktopMediaFrameStaticFields returned error: %v", err)
	}
	staticFrame := frame
	staticFrame.SessionBindingID = ""
	staticFrame.MediaSessionID = ""
	staticFrame.Encoding = ""

	b.Run("encode-contiguous", func(b *testing.B) {
		b.ReportAllocs()

		for i := 0; i < b.N; i++ {
			if _, err := EncodeDesktopMediaFrame(frame, policy); err != nil {
				b.Fatalf("EncodeDesktopMediaFrame returned error: %v", err)
			}
		}
	})

	b.Run("build-parts-reused-header", func(b *testing.B) {
		b.ReportAllocs()

		header := make([]byte, DesktopMediaHeaderSize)
		for i := 0; i < b.N; i++ {
			if _, err := BuildDesktopMediaFrameParts(frame, policy, header); err != nil {
				b.Fatalf("BuildDesktopMediaFrameParts returned error: %v", err)
			}
		}
	})

	b.Run("build-parts-static-fields", func(b *testing.B) {
		b.ReportAllocs()

		header := make([]byte, DesktopMediaHeaderSize)
		for i := 0; i < b.N; i++ {
			if _, err := BuildDesktopMediaFramePartsWithStaticFields(
				staticFrame,
				policy,
				header,
				staticFields,
			); err != nil {
				b.Fatalf("BuildDesktopMediaFramePartsWithStaticFields returned error: %v", err)
			}
		}
	})

	b.Run("decode-copy", func(b *testing.B) {
		b.ReportAllocs()

		for i := 0; i < b.N; i++ {
			if _, err := DecodeDesktopMediaFrame(encoded, policy); err != nil {
				b.Fatalf("DecodeDesktopMediaFrame returned error: %v", err)
			}
		}
	})

	b.Run("decode-view", func(b *testing.B) {
		b.ReportAllocs()

		for i := 0; i < b.N; i++ {
			if _, err := DecodeDesktopMediaFrameView(encoded, policy); err != nil {
				b.Fatalf("DecodeDesktopMediaFrameView returned error: %v", err)
			}
		}
	})
}

func BenchmarkDesktopSessionGuardHotPath(b *testing.B) {
	target := validDesktopTarget()
	target.Screen = DesktopScreenPolicy{
		MaxWidth:    1920,
		MaxHeight:   1080,
		FrameRate:   60,
		BitrateBPS:  16_000_000,
		IdleSeconds: DesktopDefaultIdleSec,
		TTLSeconds:  DesktopDefaultTTLSec,
	}
	guard, err := NewDesktopSessionGuard(fakeRemoteSessionID, target, 100)
	if err != nil {
		b.Fatalf("NewDesktopSessionGuard returned error: %v", err)
	}
	frame := DesktopFrame{
		SessionID: fakeRemoteSessionID,
		Protocol:  ProtocolRDP,
		FrameType: DesktopFrameTypeInput,
		Input:     &DesktopInputEvent{Kind: DesktopInputKindFocus, Focused: true},
	}

	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		if err := guard.ValidateFrame(frame, desktopTestAgentID, "", 101, 1); err != nil {
			b.Fatalf("ValidateFrame returned error: %v", err)
		}
	}
}
