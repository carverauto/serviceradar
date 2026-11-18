/*
 * Copyright 2026 Carver Automation Corporation.
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

// Package netperf implements pure-Go agent-to-agent Hub & Spoke network
// performance testing over 5199/TCP mTLS and single-port 5199/UDP HMAC.
package netperf

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strings"
	"sync"
	"time"

	netperfpb "github.com/carverauto/serviceradar/proto/netperf/v1"
)

const (
	DefaultPort                  uint32 = 5199
	DefaultPacketLength          uint32 = 1200
	DefaultBandwidthBps          uint64 = 50_000_000
	DefaultDurationSec           uint32 = 5
	DefaultOmitSec               uint32 = 1
	DefaultParallel              uint32 = 1
	DefaultIntervalSeconds       uint32 = 900
	DefaultMaxConcurrentSessions uint32 = 4
	DefaultMaxTotalBandwidthBps  uint64 = 1_000_000_000

	MinDurationSec           uint32 = 1
	MaxDurationSec           uint32 = 30
	MaxOmitSec               uint32 = 5
	MinParallel              uint32 = 1
	MaxParallel              uint32 = 8
	MinBandwidthBps          uint64 = 100_000
	MaxBandwidthBps          uint64 = 10_000_000_000
	MaxResponderSessions     uint32 = 64
	MaxResponderBandwidthBps uint64 = 100_000_000_000
	MinPacketLength          uint32 = 64
	MaxPacketLength          uint32 = 65_507
	MinIntervalSeconds       uint32 = 60

	TCPChunkSize          = 64 * 1024
	MaxGRPCMessageBytes   = 1 << 20
	MaxClockToleranceNano = int64(300_000_000_000)

	MinRetryAfterMs uint32 = 2_000
	MaxRetryAfterMs uint32 = 15_000

	// UDPHeaderSize is the 54-byte authenticated UDP probe wire header:
	// [0:4]   magic ("SRNP")
	// [4]     version (1)
	// [5]     flags (HELLO=0x01, DATA=0x02, OMIT=0x04, END=0x08)
	// [6:22]  session_id[16]
	// [22:30] seq (big-endian uint64)
	// [30:38] sent_unix_nano (big-endian uint64)
	// [38:54] hmac_sha256_128[16] over pkt[0:38] || pkt[54:]
	UDPHeaderSize  = 54
	UDPSessionSize = 16
	UDPMACOffset   = 38
	UDPMACSize     = 16
	UDPKeySize     = 32
	UDPVersion     = uint8(1)

	UDPFlagHello uint8 = 0x01
	UDPFlagData  uint8 = 0x02
	UDPFlagOmit  uint8 = 0x04
	UDPFlagEnd   uint8 = 0x08
)

var (
	ErrInvalidConfig          = errors.New("netperf: invalid configuration")
	ErrSecurityRequired       = errors.New("netperf: mTLS security configuration is required")
	ErrPeerIdentityInvalid    = errors.New("netperf: peer certificate identity is missing or invalid")
	ErrPeerIdentityConflict   = errors.New("netperf: peer certificate identities conflict")
	ErrPeerIdentityMismatch   = errors.New("netperf: peer certificate identity does not match expected target")
	ErrPermitRequired         = errors.New("netperf: signed NetperfPermitV1 is required")
	ErrPermitInvalid          = errors.New("netperf: invalid NetperfPermitV1")
	ErrPermitExpired          = errors.New("netperf: NetperfPermitV1 is expired or not yet valid")
	ErrPermitEpochFenced      = errors.New("netperf: NetperfPermitV1 authority epoch is fenced")
	ErrPermitScopeMismatch    = errors.New("netperf: NetperfPermitV1 scope does not match session")
	ErrPermitCeilingExceeded  = errors.New("netperf: request exceeds NetperfPermitV1 ceilings")
	ErrPermitKeyUnavailable   = errors.New("netperf: NetperfPermitV1 signing key unavailable")
	ErrPermitKeyRevoked       = errors.New("netperf: NetperfPermitV1 signing key is historically revoked")
	ErrPermitKeyInvalid       = errors.New("netperf: NetperfPermitV1 signing key is invalid")
	ErrPermitSignatureInvalid = errors.New("netperf: NetperfPermitV1 signature verification failed")
	ErrInvalidRequest         = errors.New("netperf: invalid test request")
	ErrUDPDisabled            = errors.New("netperf: UDP responder mode is disabled")
	ErrResponderBusy          = errors.New("netperf: responder at capacity")
	ErrSessionRejected        = errors.New("netperf: session rejected by responder")
	ErrSessionNotFound        = errors.New("netperf: unknown or expired session")
	ErrInvalidStreamChunk     = errors.New("netperf: invalid stream test chunk")
	ErrInvalidUDPBuffer       = errors.New("netperf: UDP datagram buffer smaller than 54-byte header")
)

func udpMagic() [4]byte {
	return [4]byte{'S', 'R', 'N', 'P'}
}

func isRateDeadlineError(ctx context.Context, err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || (ctx != nil && errors.Is(ctx.Err(), context.DeadlineExceeded)) {
		return true
	}
	return strings.Contains(err.Error(), "would exceed context deadline")
}

// classifyRateWaitError distinguishes genuine phase testEnd completion from
// premature parent/abort context cancellation or deadline expiration.
func classifyRateWaitError(
	parentCtx context.Context,
	abortCtx context.Context,
	paceCtx context.Context,
	testEnd time.Time,
	now time.Time,
	err error,
) (phaseDone bool, fatalErr error) {
	if err == nil {
		return false, nil
	}
	if abortCtx != nil && abortCtx.Err() != nil {
		return false, abortCtx.Err()
	}
	if parentCtx != nil && parentCtx.Err() != nil {
		return false, parentCtx.Err()
	}
	if !now.Before(testEnd) {
		return true, nil
	}
	if isRateDeadlineError(paceCtx, err) {
		if parentCtx != nil {
			if parentDeadline, hasParent := parentCtx.Deadline(); hasParent && parentDeadline.Before(testEnd) {
				return false, context.DeadlineExceeded
			}
		}
		if abortCtx != nil {
			if abortDeadline, hasAbort := abortCtx.Deadline(); hasAbort && abortDeadline.Before(testEnd) {
				return false, context.DeadlineExceeded
			}
		}
		return true, nil
	}
	return false, err
}

func tcpChunkSizeForBandwidth(bandwidthBps uint64) int {
	// Target ~100ms per chunk at low rates, capped at TCPChunkSize (64 KiB).
	bytesPer100ms := int(bandwidthBps / 8 / 10)
	if bytesPer100ms < 4096 {
		return 4096
	}
	if bytesPer100ms > TCPChunkSize {
		return TCPChunkSize
	}
	return bytesPer100ms
}

// ClampRequestParams normalizes outbound request parameters to the safety bounds.
func ClampRequestParams(
	bandwidthBps uint64,
	durationSec uint32,
	omitSec uint32,
	parallel uint32,
	packetLength uint32,
) (uint64, uint32, uint32, uint32, uint32) {
	switch {
	case bandwidthBps == 0:
		bandwidthBps = DefaultBandwidthBps
	case bandwidthBps < MinBandwidthBps:
		bandwidthBps = MinBandwidthBps
	case bandwidthBps > MaxBandwidthBps:
		bandwidthBps = MaxBandwidthBps
	}

	switch {
	case durationSec == 0:
		durationSec = DefaultDurationSec
	case durationSec < MinDurationSec:
		durationSec = MinDurationSec
	case durationSec > MaxDurationSec:
		durationSec = MaxDurationSec
	}

	if omitSec > MaxOmitSec {
		omitSec = MaxOmitSec
	}
	if omitSec >= durationSec {
		omitSec = durationSec - 1
	}

	switch {
	case parallel == 0:
		parallel = DefaultParallel
	case parallel < MinParallel:
		parallel = MinParallel
	case parallel > MaxParallel:
		parallel = MaxParallel
	}

	switch {
	case packetLength == 0:
		packetLength = DefaultPacketLength
	case packetLength < MinPacketLength:
		packetLength = MinPacketLength
	case packetLength > MaxPacketLength:
		packetLength = MaxPacketLength
	}

	return bandwidthBps, durationSec, omitSec, parallel, packetLength
}

// ValidateRequestBounds checks strict Responder safety bounds on an OpenSessionRequest.
func ValidateRequestBounds(req *netperfpb.OpenSessionRequest) (uint32, error) {
	if req == nil {
		return 0, ErrInvalidRequest
	}
	if req.GetProtocol() != netperfpb.NetperfProtocol_NETPERF_PROTOCOL_TCP &&
		req.GetProtocol() != netperfpb.NetperfProtocol_NETPERF_PROTOCOL_UDP {
		return 0, ErrInvalidRequest
	}
	if req.GetDirection() != netperfpb.NetperfDirection_NETPERF_DIRECTION_UPLOAD &&
		req.GetDirection() != netperfpb.NetperfDirection_NETPERF_DIRECTION_DOWNLOAD &&
		req.GetDirection() != netperfpb.NetperfDirection_NETPERF_DIRECTION_BIDIRECTIONAL {
		return 0, ErrInvalidRequest
	}
	if req.GetBandwidthBps() < MinBandwidthBps || req.GetBandwidthBps() > MaxBandwidthBps {
		return 0, ErrInvalidRequest
	}
	if req.GetDurationSec() < MinDurationSec || req.GetDurationSec() > MaxDurationSec {
		return 0, ErrInvalidRequest
	}
	if req.GetOmitSec() > MaxOmitSec || req.GetOmitSec() >= req.GetDurationSec() {
		return 0, ErrInvalidRequest
	}
	if req.GetParallel() < MinParallel || req.GetParallel() > MaxParallel {
		return 0, ErrInvalidRequest
	}
	pktLen := req.GetPacketLength()
	if pktLen == 0 {
		pktLen = DefaultPacketLength
	}
	if pktLen < MinPacketLength || pktLen > MaxPacketLength {
		return 0, ErrInvalidRequest
	}
	return pktLen, nil
}

// EncodeUDPDatagram writes the 54-byte authenticated header into buf (len(buf) >= UDPHeaderSize)
// and computes the truncated HMAC-SHA256-128 tag over buf[0:38] || buf[54:].
func EncodeUDPDatagram(
	buf []byte,
	key []byte,
	flags uint8,
	sessionID [UDPSessionSize]byte,
	seq uint64,
	sentUnixNano uint64,
) error {
	if len(buf) < UDPHeaderSize {
		return ErrInvalidUDPBuffer
	}
	magic := udpMagic()
	copy(buf[0:4], magic[:])
	buf[4] = UDPVersion
	buf[5] = flags
	copy(buf[6:22], sessionID[:])
	binary.BigEndian.PutUint64(buf[22:30], seq)
	binary.BigEndian.PutUint64(buf[30:38], sentUnixNano)

	mac := computeUDPMAC(buf, key)
	copy(buf[UDPMACOffset:UDPHeaderSize], mac[:])
	return nil
}

// ParseUDPHeader parses the 54-byte header fields if magic and version match.
func ParseUDPHeader(pkt []byte) (flags uint8, sessionID [UDPSessionSize]byte, seq, sentUnixNano uint64, ok bool) {
	if len(pkt) < UDPHeaderSize {
		return 0, sessionID, 0, 0, false
	}
	magic := udpMagic()
	if pkt[0] != magic[0] || pkt[1] != magic[1] || pkt[2] != magic[2] || pkt[3] != magic[3] {
		return 0, sessionID, 0, 0, false
	}
	if pkt[4] != UDPVersion {
		return 0, sessionID, 0, 0, false
	}
	flags = pkt[5]
	copy(sessionID[:], pkt[6:22])
	seq = binary.BigEndian.Uint64(pkt[22:30])
	sentUnixNano = binary.BigEndian.Uint64(pkt[30:38])
	return flags, sessionID, seq, sentUnixNano, true
}

// VerifyUDPMAC verifies the 16-byte truncated HMAC-SHA256 tag in pkt[38:54].
func VerifyUDPMAC(pkt []byte, key []byte) bool {
	if len(pkt) < UDPHeaderSize || len(key) == 0 {
		return false
	}
	expected := computeUDPMAC(pkt, key)
	return hmac.Equal(expected[:], pkt[UDPMACOffset:UDPHeaderSize])
}

func computeUDPMAC(pkt []byte, key []byte) [UDPMACSize]byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(pkt[:UDPMACOffset])
	if len(pkt) > UDPHeaderSize {
		_, _ = mac.Write(pkt[UDPHeaderSize:])
	}
	var sum [sha256.Size]byte
	mac.Sum(sum[:0])
	var tag [UDPMACSize]byte
	copy(tag[:], sum[:UDPMACSize])
	return tag
}

// UDPStats captures RFC 3550 jitter, packet loss, and out-of-order counts.
type UDPStats struct {
	BytesReceived     uint64
	PacketsReceived   uint64
	PacketsLost       uint64
	OutOfOrderPackets uint64
	LossPercent       float64
	JitterMs          float64
}

const rfc3550WindowBits = 1024

// RFC3550Tracker computes RFC 3550 §6.4.1 inter-arrival jitter and tracks
// duplicate / out-of-order / lost UDP packets over a 1024-bit sliding window.
type RFC3550Tracker struct {
	mu            sync.Mutex
	hasFirst      bool
	prevTransit   int64
	jitterNs      float64
	maxSeq        uint64
	uniqueRecv    uint64
	ooo           uint64
	bytesReceived uint64
	window        [rfc3550WindowBits / 64]uint64
}

// Record processes one authenticated steady-state UDP DATA datagram (seq >= 1).
func (t *RFC3550Tracker) Record(seq uint64, sentUnixNano uint64, arrivalMonotonicNano int64, pktBytes uint64) {
	if seq == 0 {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	switch {
	case t.maxSeq == 0:
		t.maxSeq = seq
		t.window[0] = 1
		t.uniqueRecv = 1
	case seq > t.maxSeq:
		shift := seq - t.maxSeq
		t.shiftWindow(shift)
		t.window[0] |= 1
		t.maxSeq = seq
		t.uniqueRecv++
	default:
		diff := t.maxSeq - seq
		if diff >= rfc3550WindowBits {
			return
		}
		word := diff / 64
		bit := diff % 64
		mask := uint64(1) << bit
		if t.window[word]&mask != 0 {
			return
		}
		t.window[word] |= mask
		t.uniqueRecv++
		t.ooo++
	}

	t.bytesReceived += pktBytes

	transit := arrivalMonotonicNano - int64(sentUnixNano)
	if !t.hasFirst {
		t.hasFirst = true
		t.prevTransit = transit
		return
	}

	d := transit - t.prevTransit
	if d < 0 {
		d = -d
	}
	t.jitterNs += (float64(d) - t.jitterNs) / 16.0
	t.prevTransit = transit
}

func (t *RFC3550Tracker) shiftWindow(shift uint64) {
	if shift >= rfc3550WindowBits {
		clear(t.window[:])
		return
	}
	wordShift := int(shift / 64)
	bitShift := shift % 64
	n := len(t.window)
	if wordShift > 0 {
		for i := n - 1; i >= wordShift; i-- {
			t.window[i] = t.window[i-wordShift]
		}
		for i := range wordShift {
			t.window[i] = 0
		}
	}
	if bitShift > 0 {
		for i := n - 1; i > 0; i-- {
			t.window[i] = (t.window[i] << bitShift) | (t.window[i-1] >> (64 - bitShift))
		}
		t.window[0] <<= bitShift
	}
}

// Snapshot returns current loss, out-of-order, and jitter statistics.
// authoritativeSent may be passed from the peer's sender summary to catch tail losses.
func (t *RFC3550Tracker) Snapshot(authoritativeSent uint64) UDPStats {
	t.mu.Lock()
	defer t.mu.Unlock()

	expected := max(t.maxSeq, authoritativeSent)
	var lost uint64
	if expected > t.uniqueRecv {
		lost = expected - t.uniqueRecv
	}
	lossPercent := 0.0
	if expected > 0 {
		lossPercent = (float64(lost) * 100.0) / float64(expected)
	}
	return UDPStats{
		BytesReceived:     t.bytesReceived,
		PacketsReceived:   t.uniqueRecv,
		PacketsLost:       lost,
		OutOfOrderPackets: t.ooo,
		LossPercent:       lossPercent,
		JitterMs:          t.jitterNs / 1e6,
	}
}
