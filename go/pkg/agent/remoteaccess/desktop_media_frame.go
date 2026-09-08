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
	"encoding/binary"
	"fmt"
	"math"
)

func NewDesktopMediaFrameStaticFields(
	sessionBindingID,
	mediaSessionID,
	encoding string,
) (DesktopMediaFrameStaticFields, error) {
	sessionID := []byte(sessionBindingID)
	mediaID := []byte(mediaSessionID)
	encodingBytes := []byte(encoding)

	if sessionBindingID == "" {
		return DesktopMediaFrameStaticFields{}, fmt.Errorf("%w: missing session binding id", ErrInvalidDesktopMediaFrame)
	}
	if mediaSessionID == "" {
		return DesktopMediaFrameStaticFields{}, fmt.Errorf("%w: missing media session id", ErrInvalidDesktopMediaFrame)
	}
	if len(sessionID) > math.MaxUint16 ||
		len(mediaID) > math.MaxUint16 ||
		len(encodingBytes) > math.MaxUint16 {
		return DesktopMediaFrameStaticFields{}, fmt.Errorf("%w: string field too large", ErrInvalidDesktopMediaFrame)
	}

	return DesktopMediaFrameStaticFields{
		SessionBindingID: sessionBindingID,
		MediaSessionID:   mediaSessionID,
		Encoding:         encoding,
		sessionBindingID: sessionID,
		mediaSessionID:   mediaID,
		encoding:         encodingBytes,
	}, nil
}

func EncodeDesktopMediaFrame(frame DesktopMediaFrame, policy DesktopScreenPolicy) ([]byte, error) {
	parts, err := BuildDesktopMediaFrameParts(frame, policy, nil)
	if err != nil {
		return nil, err
	}

	buf := make([]byte, 0, parts.Len())
	buf = parts.AppendTo(buf)

	return buf, nil
}

func BuildDesktopMediaFrameParts(
	frame DesktopMediaFrame,
	policy DesktopScreenPolicy,
	header []byte,
) (DesktopMediaFrameParts, error) {
	sessionID := []byte(frame.SessionBindingID)
	mediaSessionID := []byte(frame.MediaSessionID)
	encoding := []byte(frame.Encoding)

	return buildDesktopMediaFrameParts(frame, policy, header, sessionID, mediaSessionID, encoding)
}

func BuildDesktopMediaFramePartsWithStaticFields(
	frame DesktopMediaFrame,
	policy DesktopScreenPolicy,
	header []byte,
	staticFields DesktopMediaFrameStaticFields,
) (DesktopMediaFrameParts, error) {
	if staticFields.SessionBindingID == "" || staticFields.MediaSessionID == "" {
		return DesktopMediaFrameParts{}, fmt.Errorf("%w: missing static frame fields", ErrInvalidDesktopMediaFrame)
	}
	if frame.SessionBindingID != "" && frame.SessionBindingID != staticFields.SessionBindingID {
		return DesktopMediaFrameParts{}, fmt.Errorf("%w: session binding mismatch", ErrInvalidDesktopMediaFrame)
	}
	if frame.MediaSessionID != "" && frame.MediaSessionID != staticFields.MediaSessionID {
		return DesktopMediaFrameParts{}, fmt.Errorf("%w: media session mismatch", ErrInvalidDesktopMediaFrame)
	}
	if frame.Encoding != "" && frame.Encoding != staticFields.Encoding {
		return DesktopMediaFrameParts{}, fmt.Errorf("%w: encoding mismatch", ErrInvalidDesktopMediaFrame)
	}

	frame.SessionBindingID = staticFields.SessionBindingID
	frame.MediaSessionID = staticFields.MediaSessionID
	frame.Encoding = staticFields.Encoding

	return buildDesktopMediaFrameParts(
		frame,
		policy,
		header,
		staticFields.sessionBindingID,
		staticFields.mediaSessionID,
		staticFields.encoding,
	)
}

func buildDesktopMediaFrameParts(
	frame DesktopMediaFrame,
	policy DesktopScreenPolicy,
	header []byte,
	sessionID []byte,
	mediaSessionID []byte,
	encoding []byte,
) (DesktopMediaFrameParts, error) {
	if err := ValidateDesktopMediaFrame(frame, policy); err != nil {
		return DesktopMediaFrameParts{}, err
	}

	if len(sessionID) > math.MaxUint16 ||
		len(mediaSessionID) > math.MaxUint16 ||
		len(encoding) > math.MaxUint16 {
		return DesktopMediaFrameParts{}, fmt.Errorf("%w: string field too large", ErrInvalidDesktopMediaFrame)
	}

	totalLength := DesktopMediaHeaderSize +
		len(sessionID) +
		len(mediaSessionID) +
		len(encoding) +
		len(frame.Metadata) +
		len(frame.Payload)
	if totalLength < DesktopMediaHeaderSize {
		return DesktopMediaFrameParts{}, fmt.Errorf("%w: frame length overflow", ErrInvalidDesktopMediaFrame)
	}

	header = reusableDesktopMediaHeader(header)
	copy(header[0:4], DesktopMediaMagic)
	header[4] = DesktopMediaVersion
	header[5] = frame.Flags
	header[6] = desktopMediaPayloadFamilyID(frame.PayloadFamily)
	header[7] = 0
	binary.BigEndian.PutUint64(header[8:16], frame.Sequence)
	binary.BigEndian.PutUint64(header[16:24], uint64(frame.TimestampUnixNano))
	binary.BigEndian.PutUint32(header[24:28], frame.Width)
	binary.BigEndian.PutUint32(header[28:32], frame.Height)
	binary.BigEndian.PutUint32(header[32:36], uint32(len(frame.Metadata)))
	binary.BigEndian.PutUint32(header[36:40], uint32(len(frame.Payload)))
	binary.BigEndian.PutUint16(header[40:42], uint16(len(encoding)))
	binary.BigEndian.PutUint16(header[42:44], uint16(len(sessionID)))
	binary.BigEndian.PutUint16(header[44:46], uint16(len(mediaSessionID)))
	binary.BigEndian.PutUint16(header[46:48], 0)

	return DesktopMediaFrameParts{
		Header:           header,
		SessionBindingID: sessionID,
		MediaSessionID:   mediaSessionID,
		Encoding:         encoding,
		Metadata:         frame.Metadata,
		Payload:          frame.Payload,
	}, nil
}

func (p DesktopMediaFrameParts) Len() int {
	return len(p.Header) +
		len(p.SessionBindingID) +
		len(p.MediaSessionID) +
		len(p.Encoding) +
		len(p.Metadata) +
		len(p.Payload)
}

func (p DesktopMediaFrameParts) AppendTo(dst []byte) []byte {
	dst = append(dst, p.Header...)
	dst = append(dst, p.SessionBindingID...)
	dst = append(dst, p.MediaSessionID...)
	dst = append(dst, p.Encoding...)
	dst = append(dst, p.Metadata...)
	dst = append(dst, p.Payload...)

	return dst
}

func DecodeDesktopMediaFrame(data []byte, policy DesktopScreenPolicy) (DesktopMediaFrame, error) {
	return decodeDesktopMediaFrame(data, policy, true)
}

// DecodeDesktopMediaFrameView decodes a frame without copying metadata or
// payload. Callers must keep data alive and immutable for as long as the
// returned frame is used.
func DecodeDesktopMediaFrameView(data []byte, policy DesktopScreenPolicy) (DesktopMediaFrame, error) {
	return decodeDesktopMediaFrame(data, policy, false)
}

func decodeDesktopMediaFrame(data []byte, policy DesktopScreenPolicy, copyPayload bool) (DesktopMediaFrame, error) {
	var frame DesktopMediaFrame

	if len(data) < DesktopMediaHeaderSize {
		return frame, fmt.Errorf("%w: truncated header", ErrInvalidDesktopMediaFrame)
	}
	if !hasDesktopMediaMagic(data) {
		return frame, fmt.Errorf("%w: magic mismatch", ErrInvalidDesktopMediaFrame)
	}
	if data[4] != DesktopMediaVersion {
		return frame, fmt.Errorf("%w: unsupported version", ErrInvalidDesktopMediaFrame)
	}
	if data[7] != 0 || binary.BigEndian.Uint16(data[46:48]) != 0 {
		return frame, fmt.Errorf("%w: reserved header bytes set", ErrInvalidDesktopMediaFrame)
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
	if expectedLength != len(data) {
		return frame, fmt.Errorf("%w: trailing payload bytes", ErrInvalidDesktopMediaFrame)
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
	frame.Metadata = data[offset : offset+int(metadataLength)]
	offset += int(metadataLength)
	frame.Payload = data[offset : offset+int(payloadLength)]
	frame.Flags = data[5]
	frame.PayloadFamily = payloadFamily
	frame.Sequence = binary.BigEndian.Uint64(data[8:16])
	frame.TimestampUnixNano = int64(binary.BigEndian.Uint64(data[16:24]))
	frame.Width = binary.BigEndian.Uint32(data[24:28])
	frame.Height = binary.BigEndian.Uint32(data[28:32])

	if copyPayload {
		frame.Metadata = append([]byte(nil), frame.Metadata...)
		frame.Payload = append([]byte(nil), frame.Payload...)
	}

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
	if frame.Flags&^DesktopMediaAllowedFlags != 0 {
		return fmt.Errorf("%w: unsupported flags", ErrInvalidDesktopMediaFrame)
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

func reusableDesktopMediaHeader(header []byte) []byte {
	if cap(header) < DesktopMediaHeaderSize {
		header = make([]byte, DesktopMediaHeaderSize)
	} else {
		header = header[:DesktopMediaHeaderSize]
	}

	return header
}

func hasDesktopMediaMagic(data []byte) bool {
	return data[0] == DesktopMediaMagic[0] &&
		data[1] == DesktopMediaMagic[1] &&
		data[2] == DesktopMediaMagic[2] &&
		data[3] == DesktopMediaMagic[3]
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
