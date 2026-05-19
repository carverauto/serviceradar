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
	"encoding/binary"
	"errors"
	"io"
	"testing"
)

func TestDesktopRDPHelperFrameRoundTrips(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	want := desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageMediaFrame,
		Payload: []byte("srdp-frame"),
	}
	if err := writeDesktopRDPHelperFrame(&buf, want); err != nil {
		t.Fatalf("writeDesktopRDPHelperFrame returned error: %v", err)
	}

	got, err := readDesktopRDPHelperFrame(&buf, desktopRDPHelperMaxFrameBytes)
	if err != nil {
		t.Fatalf("readDesktopRDPHelperFrame returned error: %v", err)
	}
	if got.Type != want.Type || !bytes.Equal(got.Payload, want.Payload) {
		t.Fatalf("frame = %#v, want %#v", got, want)
	}
}

func TestDesktopRDPHelperFrameRejectsInvalidInput(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	if err := writeDesktopRDPHelperFrame(&buf, desktopRDPHelperFrame{
		Type:    99,
		Payload: []byte("bad"),
	}); !errors.Is(err, errDesktopRDPHelperInvalidFrame) {
		t.Fatalf("invalid type write error = %v, want %v", err, errDesktopRDPHelperInvalidFrame)
	}

	var oversized bytes.Buffer
	var header [desktopRDPHelperFrameHeaderSize]byte
	binary.BigEndian.PutUint32(header[0:4], 9)
	header[4] = byte(desktopRDPHelperMessageMediaFrame)
	oversized.Write(header[:])
	oversized.WriteString("12345678")
	if _, err := readDesktopRDPHelperFrame(&oversized, 8); !errors.Is(err, errDesktopRDPHelperFrameTooLarge) {
		t.Fatalf("oversized read error = %v, want %v", err, errDesktopRDPHelperFrameTooLarge)
	}

	var zeroLength bytes.Buffer
	zeroLength.Write(make([]byte, desktopRDPHelperFrameHeaderSize))
	if _, err := readDesktopRDPHelperFrame(&zeroLength, desktopRDPHelperMaxFrameBytes); !errors.Is(err, errDesktopRDPHelperInvalidFrame) {
		t.Fatalf("zero-length read error = %v, want %v", err, errDesktopRDPHelperInvalidFrame)
	}
}

func TestDesktopRDPHelperFrameRejectsTruncatedPayload(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	var header [desktopRDPHelperFrameHeaderSize]byte
	binary.BigEndian.PutUint32(header[0:4], 4)
	header[4] = byte(desktopRDPHelperMessageInput)
	buf.Write(header[:])
	buf.Write([]byte{1})

	if _, err := readDesktopRDPHelperFrame(&buf, desktopRDPHelperMaxFrameBytes); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("truncated payload error = %v, want %v", err, io.ErrUnexpectedEOF)
	}
}

func TestDesktopRDPHelperFrameAllowsEmptyPayload(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	if err := writeDesktopRDPHelperFrame(&buf, desktopRDPHelperFrame{Type: desktopRDPHelperMessageClose}); err != nil {
		t.Fatalf("writeDesktopRDPHelperFrame returned error: %v", err)
	}

	got, err := readDesktopRDPHelperFrame(&buf, desktopRDPHelperMaxFrameBytes)
	if err != nil {
		t.Fatalf("readDesktopRDPHelperFrame returned error: %v", err)
	}
	if got.Type != desktopRDPHelperMessageClose || len(got.Payload) != 0 {
		t.Fatalf("frame = %#v", got)
	}
}

func TestDesktopRDPHelperFrameCapsNonMediaBeforePayloadRead(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	var header [desktopRDPHelperFrameHeaderSize]byte
	binary.BigEndian.PutUint32(header[0:4], desktopRDPHelperMaxControlBytes+1)
	header[4] = byte(desktopRDPHelperMessageError)
	buf.Write(header[:])

	if _, err := readDesktopRDPHelperFrame(&buf, desktopRDPHelperMaxFrameBytes); !errors.Is(err, errDesktopRDPHelperFrameTooLarge) {
		t.Fatalf("oversized control read error = %v, want %v", err, errDesktopRDPHelperFrameTooLarge)
	}
}

func TestDesktopRDPHelperFrameKeepsLargePayloadsMediaOnly(t *testing.T) {
	t.Parallel()

	payload := bytes.Repeat([]byte{0x42}, desktopRDPHelperMaxControlBytes)
	if err := writeDesktopRDPHelperFrame(io.Discard, desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageClose,
		Payload: payload,
	}); !errors.Is(err, errDesktopRDPHelperFrameTooLarge) {
		t.Fatalf("oversized close write error = %v, want %v", err, errDesktopRDPHelperFrameTooLarge)
	}

	var buf bytes.Buffer
	if err := writeDesktopRDPHelperFrame(&buf, desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageMediaFrame,
		Payload: payload,
	}); err != nil {
		t.Fatalf("large media write returned error: %v", err)
	}

	got, err := readDesktopRDPHelperFrame(&buf, desktopRDPHelperMaxFrameBytes)
	if err != nil {
		t.Fatalf("large media read returned error: %v", err)
	}
	if got.Type != desktopRDPHelperMessageMediaFrame || !bytes.Equal(got.Payload, payload) {
		t.Fatalf("large media frame = %#v", got)
	}
}

func TestDesktopRDPHelperFrameAllowsBoundedOpenPayloadsForCABundles(t *testing.T) {
	t.Parallel()

	payload := bytes.Repeat([]byte{0x43}, 256*1024)
	var buf bytes.Buffer
	if err := writeDesktopRDPHelperFrame(&buf, desktopRDPHelperFrame{
		Type:    desktopRDPHelperMessageOpen,
		Payload: payload,
	}); err != nil {
		t.Fatalf("bounded open write returned error: %v", err)
	}

	got, err := readDesktopRDPHelperFrame(&buf, desktopRDPHelperMaxFrameBytes)
	if err != nil {
		t.Fatalf("bounded open read returned error: %v", err)
	}
	if got.Type != desktopRDPHelperMessageOpen || !bytes.Equal(got.Payload, payload) {
		t.Fatalf("bounded open frame = %#v", got)
	}
}
