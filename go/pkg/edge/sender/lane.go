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

// Package sender drives one durable delivery lane's send-side state machine. It
// is transport-agnostic: given a spool of unresolved frames, it produces the
// lane-open handshake, selects the next frames to transmit within the gateway's
// byte/frame credit window, and applies gateway EdgeResultAck dispositions to
// advance the spool's durable watermark and free credits. It rejects
// dispositions from a stale session (nonce mismatch), so a replaced sender's
// acks cannot corrupt state.
//
// The gRPC wiring (opening the stream, marshaling messages, reconnect) lives in
// a thin adapter; this package holds the correctness-critical logic and is unit
// tested against the real spool without a live connection.
package sender

import (
	"errors"
	"fmt"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgeframe"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// ErrStaleSession is returned when a message carries a session nonce that does
// not match the lane's active session.
var ErrStaleSession = errors.New("sender: message from a stale session")

// ErrNotEstablished is returned when frames are requested before the lane-open
// handshake completes.
var ErrNotEstablished = errors.New("sender: lane not established")

// ErrSpoolMismatch is returned when a gateway message carries a spool_id that is
// not this lane's spool. A live-nonce echo bound to another spool must never be
// allowed to advance this spool's watermark.
var ErrSpoolMismatch = errors.New("sender: message bound to a different spool")

// ErrAckBeyondSent is returned when a disposition resolves a sequence beyond the
// contiguous prefix this session has actually sent. A forged/over-range prefix
// could otherwise discard unsent frames.
var ErrAckBeyondSent = errors.New("sender: ack resolves beyond the sent prefix")

// Config sets the lane kind and the credits the agent requests at open.
type Config struct {
	SpoolID             []byte
	LaneKind            edgev1.EdgeResultLaneKind
	RequestByteCredits  uint64
	RequestFrameCredits uint32
}

// Lane is one lane's send-side state machine. Not safe for concurrent use.
type Lane struct {
	sp    *spool.Spool
	cfg   Config
	nonce []byte

	established  bool
	byteCredits  uint64
	frameCredits uint32

	cursor        uint64            // highest sequence handed out this session
	inflight      map[uint64]uint64 // sequence -> encoded frame bytes
	inflightBytes uint64
}

// NewLane creates a lane for the given spool with a fresh session nonce.
func NewLane(sp *spool.Spool, cfg Config) (*Lane, error) {
	nonce, err := edgeframe.NewUUIDv7()
	if err != nil {
		return nil, err
	}
	return &Lane{
		sp:       sp,
		cfg:      cfg,
		nonce:    nonce,
		inflight: make(map[uint64]uint64),
	}, nil
}

// Open returns the lane-open handshake to send first. first_unresolved_sequence
// is drawn from the spool so a replacement gateway can rebuild a resolved prefix.
func (l *Lane) Open() (*edgev1.EdgeResultLaneOpen, error) {
	first, err := l.firstUnresolvedBounded()
	if err != nil {
		return nil, err
	}
	return &edgev1.EdgeResultLaneOpen{
		SpoolId:                 l.cfg.SpoolID,
		LaneKind:                l.cfg.LaneKind,
		SequenceBase:            1,
		FirstUnresolvedSequence: first,
		SessionNonce:            l.nonce,
		RequestedByteCredits:    l.cfg.RequestByteCredits,
		RequestedFrameCredits:   l.cfg.RequestFrameCredits,
	}, nil
}

// OnLaneOpenAck validates the handshake ack's nonce AND spool binding, then
// records the granted credits.
func (l *Lane) OnLaneOpenAck(ack *edgev1.EdgeResultLaneOpenAck) error {
	if !equalBytes(ack.GetSessionNonce(), l.nonce) {
		return ErrStaleSession
	}
	if !equalBytes(ack.GetSpoolId(), l.cfg.SpoolID) {
		return ErrSpoolMismatch
	}
	l.byteCredits = ack.GetGrantedByteCredits()
	l.frameCredits = ack.GetGrantedFrameCredits()
	l.established = true
	return nil
}

// NextFrames returns the next unresolved, not-yet-sent frames that fit within
// the remaining byte/frame credit window, marking them in flight. It streams
// from the durable prefix through the spool cursor and stops as soon as the
// credit window is exhausted, so a multi-gigabyte backlog is never materialized
// to hand out a small window.
func (l *Lane) NextFrames() ([]*edgev1.EdgeResultFrame, error) {
	if !l.established {
		return nil, ErrNotEstablished
	}

	var out []*edgev1.EdgeResultFrame
	var decodeErr error
	err := l.sp.ScanFrom(l.cursor, func(rec spool.Record) bool {
		size := uint64(len(rec.Body))
		if uint32(len(l.inflight)) >= l.frameCredits {
			return false
		}
		if l.inflightBytes+size > l.byteCredits {
			return false
		}
		var frame edgev1.EdgeResultFrame
		if err := proto.Unmarshal(rec.Body, &frame); err != nil {
			decodeErr = fmt.Errorf("sender: decode spooled frame seq %d: %w", rec.Sequence, err)
			return false
		}
		out = append(out, &frame)
		l.inflight[rec.Sequence] = size
		l.inflightBytes += size
		if rec.Sequence > l.cursor {
			l.cursor = rec.Sequence
		}
		return true
	})
	if err != nil {
		return nil, err
	}
	if decodeErr != nil {
		return nil, decodeErr
	}
	return out, nil
}

// OnAck applies a gateway disposition report: it validates the session nonce and
// spool binding, rejects a prefix beyond what this session has sent, advances
// the spool's durable watermark to the resolved prefix, and frees the credits of
// every resolved (accepted or permanently rejected) sequence.
func (l *Lane) OnAck(ack *edgev1.EdgeResultAck) error {
	if !equalBytes(ack.GetSessionNonce(), l.nonce) {
		return ErrStaleSession
	}
	if !equalBytes(ack.GetSpoolId(), l.cfg.SpoolID) {
		return ErrSpoolMismatch
	}

	through := ack.GetResolvedThroughSequence()
	if through > l.cursor {
		return fmt.Errorf("%w: resolved=%d sent-through=%d", ErrAckBeyondSent, through, l.cursor)
	}
	if through > 0 {
		if err := l.sp.Resolve(through); err != nil {
			return err
		}
	}
	for seq, size := range l.inflight {
		if seq <= through {
			l.inflightBytes -= size
			delete(l.inflight, seq)
		}
	}
	return nil
}

// InflightFrames reports how many frames are currently in flight.
func (l *Lane) InflightFrames() int { return len(l.inflight) }

func (l *Lane) firstUnresolvedBounded() (uint64, error) {
	var first uint64
	if err := l.sp.ScanFrom(0, func(rec spool.Record) bool {
		first = rec.Sequence
		return false // only need the lowest unresolved sequence
	}); err != nil {
		return 0, err
	}
	if first == 0 {
		return l.sp.NextSequence(), nil
	}
	return first, nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) || len(a) == 0 {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
