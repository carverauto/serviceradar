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
)

const (
	DesktopMediaMagic          = "SRDP"
	DesktopMediaVersion        = 1
	DesktopMediaHeaderSize     = 48
	DesktopMediaMaxMetadata    = 64 * 1024
	DesktopMediaMaxCloseReason = 256

	DesktopMediaFlagKeyframe      uint8 = 0x01
	DesktopMediaFlagFullFrame     uint8 = 0x02
	DesktopMediaFlagCursorUpdate  uint8 = 0x04
	DesktopMediaFlagEndOfStream   uint8 = 0x08
	DesktopMediaFlagDiscontinuity uint8 = 0x10
	DesktopMediaAllowedFlags            = DesktopMediaFlagKeyframe |
		DesktopMediaFlagFullFrame |
		DesktopMediaFlagCursorUpdate |
		DesktopMediaFlagEndOfStream |
		DesktopMediaFlagDiscontinuity

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
