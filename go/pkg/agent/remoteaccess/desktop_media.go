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
	"fmt"
	"math"
)

const (
	DesktopMediaMagic       = "SRDP"
	DesktopMediaVersion     = 1
	DesktopMediaHeaderSize  = 48
	DesktopMediaMaxMetadata = 64 * 1024

	DesktopMediaFlagKeyframe      uint8 = 0x01
	DesktopMediaFlagFullFrame     uint8 = 0x02
	DesktopMediaFlagCursorUpdate  uint8 = 0x04
	DesktopMediaFlagEndOfStream   uint8 = 0x08
	DesktopMediaFlagDiscontinuity uint8 = 0x10

	DesktopMediaPayloadVideo     = "video"
	DesktopMediaPayloadDirtyRect = "dirty_rect"
	DesktopMediaPayloadTile      = "tile"
	DesktopMediaPayloadCursor    = "cursor"
	DesktopMediaPayloadMetadata  = "metadata"

	DesktopMediaDefaultInitialCreditBytes = 4 * 1024 * 1024
	DesktopMediaDefaultMaxChunkBytes      = 256 * 1024
)

var (
	ErrInvalidDesktopMediaFrame = errors.New("invalid desktop media frame")
	ErrInvalidDesktopMediaAck   = errors.New("invalid desktop media ack")
	ErrDesktopMediaNoCredit     = errors.New("desktop media credit exhausted")
)

// DesktopMediaFrame is the compact binary envelope shared by the Go agent,
// gateway/core, and browser worker. It matches web-ng's SRDP browser parser.
type DesktopMediaFrame struct {
	SessionBindingID  string
	MediaSessionID    string
	Sequence          uint64
	TimestampUnixNano int64
	Width             uint32
	Height            uint32
	PayloadFamily     string
	Encoding          string
	Metadata          []byte
	Payload           []byte
	Flags             uint8
}

type DesktopMediaAck struct {
	SessionBindingID string
	MediaSessionID   string
	LastAcceptedSeq  uint64
	CreditBytes      uint64
	QualityLevel     string
	Pause            bool
	Resume           bool
	CloseReason      string
}

type DesktopMediaCreditWindow struct {
	remainingBytes uint64
	maxChunkBytes  uint32
}

func NewDesktopMediaCreditWindow(initialCreditBytes uint64, maxChunkBytes uint32) (DesktopMediaCreditWindow, error) {
	if initialCreditBytes == 0 {
		initialCreditBytes = DesktopMediaDefaultInitialCreditBytes
	}
	if maxChunkBytes == 0 {
		maxChunkBytes = DesktopMediaDefaultMaxChunkBytes
	}
	if maxChunkBytes > DesktopMaxFrameData {
		return DesktopMediaCreditWindow{}, fmt.Errorf("%w: max chunk exceeds desktop policy", ErrInvalidDesktopMediaFrame)
	}

	return DesktopMediaCreditWindow{
		remainingBytes: initialCreditBytes,
		maxChunkBytes:  maxChunkBytes,
	}, nil
}

func (w DesktopMediaCreditWindow) RemainingBytes() uint64 {
	return w.remainingBytes
}

func (w DesktopMediaCreditWindow) MaxChunkBytes() uint32 {
	return w.maxChunkBytes
}

func (w DesktopMediaCreditWindow) CanSend(frame DesktopMediaFrame) bool {
	if frame.Flags&DesktopMediaFlagEndOfStream != 0 {
		return true
	}

	return mediaFrameCreditCost(frame) <= w.remainingBytes &&
		uint64(len(frame.Payload)) <= uint64(w.maxChunkBytes)
}

func (w *DesktopMediaCreditWindow) Consume(frame DesktopMediaFrame) error {
	if frame.Flags&DesktopMediaFlagEndOfStream != 0 {
		return nil
	}

	if uint64(len(frame.Payload)) > uint64(w.maxChunkBytes) {
		return fmt.Errorf("%w: payload exceeds max chunk", ErrInvalidDesktopMediaFrame)
	}

	cost := mediaFrameCreditCost(frame)
	if cost > w.remainingBytes {
		return ErrDesktopMediaNoCredit
	}

	w.remainingBytes -= cost

	return nil
}

func (w *DesktopMediaCreditWindow) Adjust(creditBytes uint64) {
	if math.MaxUint64-w.remainingBytes < creditBytes {
		w.remainingBytes = math.MaxUint64
		return
	}

	w.remainingBytes += creditBytes
}

func (w *DesktopMediaCreditWindow) ApplyAck(ack DesktopMediaAck, sessionBindingID, mediaSessionID string) error {
	if err := ValidateDesktopMediaAck(ack, sessionBindingID, mediaSessionID); err != nil {
		return err
	}

	w.Adjust(ack.CreditBytes)

	return nil
}

func EncodeDesktopMediaFrame(frame DesktopMediaFrame, policy DesktopScreenPolicy) ([]byte, error) {
	if err := ValidateDesktopMediaFrame(frame, policy); err != nil {
		return nil, err
	}

	sessionID := []byte(frame.SessionBindingID)
	mediaSessionID := []byte(frame.MediaSessionID)
	encoding := []byte(frame.Encoding)

	if len(sessionID) > math.MaxUint16 ||
		len(mediaSessionID) > math.MaxUint16 ||
		len(encoding) > math.MaxUint16 {
		return nil, fmt.Errorf("%w: string field too large", ErrInvalidDesktopMediaFrame)
	}

	totalLength := DesktopMediaHeaderSize +
		len(sessionID) +
		len(mediaSessionID) +
		len(encoding) +
		len(frame.Metadata) +
		len(frame.Payload)
	if totalLength < DesktopMediaHeaderSize {
		return nil, fmt.Errorf("%w: frame length overflow", ErrInvalidDesktopMediaFrame)
	}

	buf := make([]byte, totalLength)
	copy(buf[0:4], DesktopMediaMagic)
	buf[4] = DesktopMediaVersion
	buf[5] = frame.Flags
	buf[6] = desktopMediaPayloadFamilyID(frame.PayloadFamily)
	binary.BigEndian.PutUint64(buf[8:16], frame.Sequence)
	binary.BigEndian.PutUint64(buf[16:24], uint64(frame.TimestampUnixNano))
	binary.BigEndian.PutUint32(buf[24:28], frame.Width)
	binary.BigEndian.PutUint32(buf[28:32], frame.Height)
	binary.BigEndian.PutUint32(buf[32:36], uint32(len(frame.Metadata)))
	binary.BigEndian.PutUint32(buf[36:40], uint32(len(frame.Payload)))
	binary.BigEndian.PutUint16(buf[40:42], uint16(len(encoding)))
	binary.BigEndian.PutUint16(buf[42:44], uint16(len(sessionID)))
	binary.BigEndian.PutUint16(buf[44:46], uint16(len(mediaSessionID)))

	offset := DesktopMediaHeaderSize
	offset += copy(buf[offset:], sessionID)
	offset += copy(buf[offset:], mediaSessionID)
	offset += copy(buf[offset:], encoding)
	offset += copy(buf[offset:], frame.Metadata)
	copy(buf[offset:], frame.Payload)

	return buf, nil
}

func DecodeDesktopMediaFrame(data []byte, policy DesktopScreenPolicy) (DesktopMediaFrame, error) {
	var frame DesktopMediaFrame

	if len(data) < DesktopMediaHeaderSize {
		return frame, fmt.Errorf("%w: truncated header", ErrInvalidDesktopMediaFrame)
	}
	if !bytes.Equal(data[0:4], []byte(DesktopMediaMagic)) {
		return frame, fmt.Errorf("%w: magic mismatch", ErrInvalidDesktopMediaFrame)
	}
	if data[4] != DesktopMediaVersion {
		return frame, fmt.Errorf("%w: unsupported version", ErrInvalidDesktopMediaFrame)
	}

	metadataLength := binary.BigEndian.Uint32(data[32:36])
	payloadLength := binary.BigEndian.Uint32(data[36:40])
	encodingLength := binary.BigEndian.Uint16(data[40:42])
	sessionLength := binary.BigEndian.Uint16(data[42:44])
	mediaSessionLength := binary.BigEndian.Uint16(data[44:46])
	expectedLength := DesktopMediaHeaderSize +
		int(sessionLength) +
		int(mediaSessionLength) +
		int(encodingLength) +
		int(metadataLength) +
		int(payloadLength)
	if expectedLength < DesktopMediaHeaderSize || expectedLength > len(data) {
		return frame, fmt.Errorf("%w: truncated payload", ErrInvalidDesktopMediaFrame)
	}

	payloadFamily, ok := desktopMediaPayloadFamily(data[6])
	if !ok {
		return frame, fmt.Errorf("%w: unsupported payload family", ErrInvalidDesktopMediaFrame)
	}

	offset := DesktopMediaHeaderSize
	frame.SessionBindingID = string(data[offset : offset+int(sessionLength)])
	offset += int(sessionLength)
	frame.MediaSessionID = string(data[offset : offset+int(mediaSessionLength)])
	offset += int(mediaSessionLength)
	frame.Encoding = string(data[offset : offset+int(encodingLength)])
	offset += int(encodingLength)
	frame.Metadata = append([]byte(nil), data[offset:offset+int(metadataLength)]...)
	offset += int(metadataLength)
	frame.Payload = append([]byte(nil), data[offset:offset+int(payloadLength)]...)
	frame.Flags = data[5]
	frame.PayloadFamily = payloadFamily
	frame.Sequence = binary.BigEndian.Uint64(data[8:16])
	frame.TimestampUnixNano = int64(binary.BigEndian.Uint64(data[16:24]))
	frame.Width = binary.BigEndian.Uint32(data[24:28])
	frame.Height = binary.BigEndian.Uint32(data[28:32])

	if err := ValidateDesktopMediaFrame(frame, policy); err != nil {
		return frame, err
	}

	return frame, nil
}

func ValidateDesktopMediaFrame(frame DesktopMediaFrame, policy DesktopScreenPolicy) error {
	policy = normalizeDesktopScreenPolicy(policy)

	if frame.SessionBindingID == "" {
		return fmt.Errorf("%w: missing session binding id", ErrInvalidDesktopMediaFrame)
	}
	if frame.MediaSessionID == "" {
		return fmt.Errorf("%w: missing media session id", ErrInvalidDesktopMediaFrame)
	}
	if desktopMediaPayloadFamilyID(frame.PayloadFamily) == 0 {
		return fmt.Errorf("%w: unsupported payload family", ErrInvalidDesktopMediaFrame)
	}
	if len(frame.Metadata) > DesktopMediaMaxMetadata {
		return fmt.Errorf("%w: metadata exceeds maximum", ErrInvalidDesktopMediaFrame)
	}
	if len(frame.Payload) > DesktopMaxFrameData {
		return fmt.Errorf("%w: payload exceeds maximum", ErrInvalidDesktopMediaFrame)
	}
	if len(frame.Metadata) > math.MaxUint32 || len(frame.Payload) > math.MaxUint32 {
		return fmt.Errorf("%w: frame section too large", ErrInvalidDesktopMediaFrame)
	}

	switch frame.PayloadFamily {
	case DesktopMediaPayloadVideo, DesktopMediaPayloadDirtyRect, DesktopMediaPayloadTile:
		if frame.Width == 0 || frame.Height == 0 || frame.Width > policy.MaxWidth || frame.Height > policy.MaxHeight {
			return fmt.Errorf("%w: dimensions exceed policy", ErrInvalidDesktopMediaFrame)
		}
	case DesktopMediaPayloadCursor, DesktopMediaPayloadMetadata:
		if frame.Width > policy.MaxWidth || frame.Height > policy.MaxHeight {
			return fmt.Errorf("%w: dimensions exceed policy", ErrInvalidDesktopMediaFrame)
		}
	}

	return nil
}

func ValidateDesktopMediaAck(ack DesktopMediaAck, sessionBindingID, mediaSessionID string) error {
	if ack.SessionBindingID == "" {
		return fmt.Errorf("%w: missing session binding id", ErrInvalidDesktopMediaAck)
	}
	if ack.MediaSessionID == "" {
		return fmt.Errorf("%w: missing media session id", ErrInvalidDesktopMediaAck)
	}
	if sessionBindingID != "" && ack.SessionBindingID != sessionBindingID {
		return fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopMediaAck)
	}
	if mediaSessionID != "" && ack.MediaSessionID != mediaSessionID {
		return fmt.Errorf("%w: media session mismatch", ErrInvalidDesktopMediaAck)
	}
	if ack.Pause && ack.Resume {
		return fmt.Errorf("%w: pause and resume cannot both be set", ErrInvalidDesktopMediaAck)
	}

	return nil
}

func mediaFrameCreditCost(frame DesktopMediaFrame) uint64 {
	return uint64(len(frame.Metadata)) + uint64(len(frame.Payload))
}

func desktopMediaPayloadFamilyID(family string) uint8 {
	switch family {
	case DesktopMediaPayloadVideo:
		return 1
	case DesktopMediaPayloadDirtyRect:
		return 2
	case DesktopMediaPayloadTile:
		return 3
	case DesktopMediaPayloadCursor:
		return 4
	case DesktopMediaPayloadMetadata:
		return 5
	default:
		return 0
	}
}

func desktopMediaPayloadFamily(id uint8) (string, bool) {
	switch id {
	case 1:
		return DesktopMediaPayloadVideo, true
	case 2:
		return DesktopMediaPayloadDirtyRect, true
	case 3:
		return DesktopMediaPayloadTile, true
	case 4:
		return DesktopMediaPayloadCursor, true
	case 5:
		return DesktopMediaPayloadMetadata, true
	default:
		return "", false
	}
}
