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
	"encoding/json"
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
	DesktopMediaControlTypeAck   = "desktop_media_ack"
	DesktopMediaQualityAuto      = "auto"
	DesktopMediaQualityLow       = "low"

	DesktopMediaDefaultInitialCreditBytes = 4 * 1024 * 1024
	DesktopMediaDefaultMaxChunkBytes      = 256 * 1024
	DesktopMediaDefaultMaxAckCreditBytes  = 4 * 1024 * 1024
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

// DesktopMediaFrameParts exposes the SRDP frame as ordered byte slices for
// vectored writes. Header can be caller-owned and reused across frames;
// Metadata and Payload alias the frame input and must remain immutable until
// the write completes.
type DesktopMediaFrameParts struct {
	Header           []byte
	SessionBindingID []byte
	MediaSessionID   []byte
	Encoding         []byte
	Metadata         []byte
	Payload          []byte
}

// DesktopMediaFrameStaticFields stores per-session frame fields in both string
// and byte form so high-volume media loops can avoid re-encoding stable values
// for every screen update.
type DesktopMediaFrameStaticFields struct {
	SessionBindingID string
	MediaSessionID   string
	Encoding         string

	sessionBindingID []byte
	mediaSessionID   []byte
	encoding         []byte
}

type DesktopMediaAck struct {
	SessionBindingID string `json:"session_binding_id"`
	MediaSessionID   string `json:"media_session_id"`
	LastAcceptedSeq  uint64 `json:"last_accepted_seq"`
	CreditBytes      uint64 `json:"credit_bytes"`
	QualityLevel     string `json:"quality_level,omitempty"`
	Pause            bool   `json:"pause,omitempty"`
	Resume           bool   `json:"resume,omitempty"`
	CloseReason      string `json:"close_reason,omitempty"`
}

type desktopMediaAckMessage struct {
	Type string `json:"type"`
	DesktopMediaAck
}

type DesktopMediaCreditWindow struct {
	remainingBytes  uint64
	maxChunkBytes   uint32
	maxAckCredit    uint64
	lastAcceptedSeq uint64
	acceptedSeqSet  bool
	paused          bool
	qualityLevel    string
	closeReason     string
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
		maxAckCredit:   DesktopMediaDefaultMaxAckCreditBytes,
	}, nil
}

func (w DesktopMediaCreditWindow) RemainingBytes() uint64 {
	return w.remainingBytes
}

func (w DesktopMediaCreditWindow) MaxChunkBytes() uint32 {
	return w.maxChunkBytes
}

func (w DesktopMediaCreditWindow) MaxAckCreditBytes() uint64 {
	if w.maxAckCredit == 0 {
		return DesktopMediaDefaultMaxAckCreditBytes
	}

	return w.maxAckCredit
}

func (w DesktopMediaCreditWindow) LastAcceptedSeq() (uint64, bool) {
	return w.lastAcceptedSeq, w.acceptedSeqSet
}

func (w DesktopMediaCreditWindow) Paused() bool {
	return w.paused
}

func (w DesktopMediaCreditWindow) QualityLevel() string {
	return w.qualityLevel
}

func (w DesktopMediaCreditWindow) CloseReason() string {
	return w.closeReason
}

func (w DesktopMediaCreditWindow) CanSend(frame DesktopMediaFrame) bool {
	if frame.Flags&DesktopMediaFlagEndOfStream != 0 {
		return true
	}

	if w.paused {
		return false
	}

	return mediaFrameCreditCost(frame) <= w.remainingBytes &&
		uint64(len(frame.Payload)) <= uint64(w.maxChunkBytes)
}

func (w *DesktopMediaCreditWindow) Consume(frame DesktopMediaFrame) error {
	if frame.Flags&DesktopMediaFlagEndOfStream != 0 {
		return nil
	}
	if w.paused {
		return ErrDesktopMediaNoCredit
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
	if w.acceptedSeqSet && ack.LastAcceptedSeq < w.lastAcceptedSeq {
		return fmt.Errorf("%w: stale ack sequence", ErrInvalidDesktopMediaAck)
	}
	if w.acceptedSeqSet && ack.LastAcceptedSeq == w.lastAcceptedSeq {
		if ack.CreditBytes != 0 || !desktopMediaAckHasControlSignal(ack) {
			return fmt.Errorf("%w: stale ack sequence", ErrInvalidDesktopMediaAck)
		}

		w.applyAckControl(ack)

		return nil
	}

	if ack.CreditBytes != 0 {
		w.Adjust(min(ack.CreditBytes, w.MaxAckCreditBytes()))
	}
	w.lastAcceptedSeq = ack.LastAcceptedSeq
	w.acceptedSeqSet = true
	w.applyAckControl(ack)

	return nil
}

func (w *DesktopMediaCreditWindow) applyAckControl(ack DesktopMediaAck) {
	switch {
	case ack.Pause:
		w.paused = true
	case ack.Resume:
		w.paused = false
	}

	if ack.QualityLevel != "" {
		w.qualityLevel = ack.QualityLevel
	}
	if ack.CloseReason != "" {
		w.closeReason = ack.CloseReason
	}
}

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

func DecodeDesktopMediaAckMessage(data []byte, sessionBindingID, mediaSessionID string) (DesktopMediaAck, error) {
	var message desktopMediaAckMessage
	if err := json.Unmarshal(data, &message); err != nil {
		return DesktopMediaAck{}, fmt.Errorf("%w: decode ack message: %w", ErrInvalidDesktopMediaAck, err)
	}
	if message.Type != DesktopMediaControlTypeAck {
		return DesktopMediaAck{}, fmt.Errorf("%w: unsupported control message type", ErrInvalidDesktopMediaAck)
	}

	ack := message.DesktopMediaAck
	if err := ValidateDesktopMediaAck(ack, sessionBindingID, mediaSessionID); err != nil {
		return DesktopMediaAck{}, err
	}

	return ack, nil
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
	if !validDesktopMediaQualityLevel(ack.QualityLevel) {
		return fmt.Errorf("%w: unsupported quality level", ErrInvalidDesktopMediaAck)
	}

	return nil
}

func mediaFrameCreditCost(frame DesktopMediaFrame) uint64 {
	return uint64(len(frame.Metadata)) + uint64(len(frame.Payload))
}

func desktopMediaAckHasControlSignal(ack DesktopMediaAck) bool {
	return ack.Pause || ack.Resume || ack.QualityLevel != "" || ack.CloseReason != ""
}

func validDesktopMediaQualityLevel(level string) bool {
	switch level {
	case "", DesktopMediaQualityAuto, DesktopMediaQualityLow:
		return true
	default:
		return false
	}
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
