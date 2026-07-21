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

package sender

import (
	"errors"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgeframe"
	"github.com/carverauto/serviceradar/go/pkg/edge/spool"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// spoolFrame appends one EdgeResultFrame of the given payload size (its body is
// the marshaled frame) and returns the assigned sequence.
func spoolFrame(t *testing.T, sp *spool.Spool, payloadLen int) uint64 {
	t.Helper()
	eventID, err := edgeframe.NewUUIDv7()
	if err != nil {
		t.Fatalf("uuid: %v", err)
	}
	frame := &edgev1.EdgeResultFrame{
		EventId: eventID,
		Payload: make([]byte, payloadLen),
	}
	body, err := proto.Marshal(frame)
	if err != nil {
		t.Fatalf("marshal frame: %v", err)
	}
	seq, err := sp.Append(eventID, body)
	if err != nil {
		t.Fatalf("append: %v", err)
	}
	return seq
}

func openSpool(t *testing.T) *spool.Spool {
	t.Helper()
	sp, err := spool.Open(filepath.Join(t.TempDir(), "lane"))
	if err != nil {
		t.Fatalf("open spool: %v", err)
	}
	t.Cleanup(func() { _ = sp.Close() })
	return sp
}

// testSpoolID is a fixed, non-zero lane spool id so the tests actually exercise
// the spool_id binding (not an all-zero placeholder).
func testSpoolID() []byte { return []byte("lane-spool-id-16") }

func newTestLane(t *testing.T, sp *spool.Spool) *Lane {
	t.Helper()
	l, err := NewLane(sp, Config{SpoolID: testSpoolID(), LaneKind: edgev1.EdgeResultLaneKind_EDGE_RESULT_LANE_KIND_SWEEP_BULK})
	if err != nil {
		t.Fatalf("new lane: %v", err)
	}
	return l
}

func establish(t *testing.T, l *Lane, byteCredits uint64, frameCredits uint32) {
	t.Helper()
	open, err := l.Open()
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	err = l.OnLaneOpenAck(&edgev1.EdgeResultLaneOpenAck{
		SpoolId:             l.cfg.SpoolID,
		SessionNonce:        open.GetSessionNonce(),
		GrantedByteCredits:  byteCredits,
		GrantedFrameCredits: frameCredits,
	})
	if err != nil {
		t.Fatalf("open ack: %v", err)
	}
}

func TestLaneRejectsFramesBeforeEstablished(t *testing.T) {
	sp := openSpool(t)
	l := newTestLane(t, sp)
	if _, err := l.NextFrames(); err != ErrNotEstablished {
		t.Fatalf("want ErrNotEstablished, got %v", err)
	}
}

func TestLaneFrameCreditBound(t *testing.T) {
	sp := openSpool(t)
	for i := 0; i < 5; i++ {
		spoolFrame(t, sp, 8)
	}
	l := newTestLane(t, sp)
	establish(t, l, 1<<20, 3) // 3 frame credits

	frames, err := l.NextFrames()
	if err != nil {
		t.Fatalf("next: %v", err)
	}
	if len(frames) != 3 {
		t.Fatalf("want 3 frames (credit bound), got %d", len(frames))
	}
	if l.InflightFrames() != 3 {
		t.Fatalf("inflight = %d, want 3", l.InflightFrames())
	}
	// No further frames until credits free up.
	more, _ := l.NextFrames()
	if len(more) != 0 {
		t.Fatalf("want 0 additional frames while credits exhausted, got %d", len(more))
	}
}

func TestLaneByteCreditBound(t *testing.T) {
	sp := openSpool(t)
	// Each frame body is ~1000 bytes; a 2500-byte window admits exactly two.
	for i := 0; i < 5; i++ {
		spoolFrame(t, sp, 1000)
	}
	l := newTestLane(t, sp)
	establish(t, l, 2500, 100)

	frames, err := l.NextFrames()
	if err != nil {
		t.Fatalf("next: %v", err)
	}
	if len(frames) != 2 {
		t.Fatalf("want 2 frames (byte bound), got %d", len(frames))
	}
}

func TestLaneAckResolvesAndFreesCredits(t *testing.T) {
	sp := openSpool(t)
	seqs := make([]uint64, 5)
	for i := 0; i < 5; i++ {
		seqs[i] = spoolFrame(t, sp, 8)
	}
	l := newTestLane(t, sp)
	establish(t, l, 1<<20, 3)

	first, _ := l.NextFrames()
	if len(first) != 3 {
		t.Fatalf("want 3, got %d", len(first))
	}
	open, _ := l.Open()

	// Gateway durably accepted through the 2nd sequence.
	if err := l.OnAck(&edgev1.EdgeResultAck{
		SpoolId:                 l.cfg.SpoolID,
		SessionNonce:            open.GetSessionNonce(),
		ResolvedThroughSequence: seqs[1],
	}); err != nil {
		t.Fatalf("ack: %v", err)
	}
	if l.InflightFrames() != 1 {
		t.Fatalf("inflight after resolve = %d, want 1", l.InflightFrames())
	}

	// Spool must have dropped the resolved prefix.
	rem, err := sp.Unresolved()
	if err != nil {
		t.Fatalf("unresolved: %v", err)
	}
	if len(rem) != 3 || rem[0].Sequence != seqs[2] {
		t.Fatalf("unresolved head = %d (len %d), want %d (len 3)", rem[0].Sequence, len(rem), seqs[2])
	}

	// Freed credits let the next two frames go.
	next, _ := l.NextFrames()
	if len(next) != 2 {
		t.Fatalf("want 2 fresh frames after resolve, got %d", len(next))
	}
}

func TestLaneRejectsStaleSessionAck(t *testing.T) {
	sp := openSpool(t)
	spoolFrame(t, sp, 8)
	l := newTestLane(t, sp)
	establish(t, l, 1<<20, 10)

	wrongNonce := make([]byte, 16)
	wrongNonce[0] = 0xAB
	if err := l.OnAck(&edgev1.EdgeResultAck{SessionNonce: wrongNonce, ResolvedThroughSequence: 1}); err != ErrStaleSession {
		t.Fatalf("want ErrStaleSession, got %v", err)
	}
	// A stale-session open ack must not establish credits.
	l2, _ := NewLane(sp, Config{SpoolID: make([]byte, 16)})
	if err := l2.OnLaneOpenAck(&edgev1.EdgeResultLaneOpenAck{SessionNonce: wrongNonce}); err != ErrStaleSession {
		t.Fatalf("want ErrStaleSession on open ack, got %v", err)
	}
}

// Finding usp-09/P1: an ack echoing the live nonce but bound to another spool
// must not advance this lane's watermark.
func TestLaneRejectsSpoolMismatch(t *testing.T) {
	sp := openSpool(t)
	spoolFrame(t, sp, 8)
	l := newTestLane(t, sp)
	establish(t, l, 1<<20, 10)
	open, _ := l.Open()

	otherSpool := []byte("other-spool-id16")
	err := l.OnAck(&edgev1.EdgeResultAck{
		SpoolId:                 otherSpool,
		SessionNonce:            open.GetSessionNonce(),
		ResolvedThroughSequence: 1,
	})
	if err != ErrSpoolMismatch {
		t.Fatalf("cross-spool ack = %v, want ErrSpoolMismatch", err)
	}
	// The open-ack handler must bind the spool too.
	l2 := newTestLane(t, sp)
	o2, _ := l2.Open()
	if err := l2.OnLaneOpenAck(&edgev1.EdgeResultLaneOpenAck{SpoolId: otherSpool, SessionNonce: o2.GetSessionNonce()}); err != ErrSpoolMismatch {
		t.Fatalf("cross-spool open ack = %v, want ErrSpoolMismatch", err)
	}
}

// Finding usp-09/P1: a disposition resolving beyond the contiguous prefix this
// session has actually sent must be rejected (it would discard unsent frames).
func TestLaneRejectsAckBeyondSent(t *testing.T) {
	sp := openSpool(t)
	for i := 0; i < 5; i++ {
		spoolFrame(t, sp, 8)
	}
	l := newTestLane(t, sp)
	establish(t, l, 1<<20, 3) // only 3 frame credits => sends seqs 1..3
	if _, err := l.NextFrames(); err != nil {
		t.Fatalf("next: %v", err)
	}
	open, _ := l.Open()
	// Resolve 4: within the appended high-water (5) but beyond the sent prefix (3).
	err := l.OnAck(&edgev1.EdgeResultAck{
		SpoolId:                 l.cfg.SpoolID,
		SessionNonce:            open.GetSessionNonce(),
		ResolvedThroughSequence: 4,
	})
	if err == nil || !errors.Is(err, ErrAckBeyondSent) {
		t.Fatalf("over-range ack = %v, want ErrAckBeyondSent", err)
	}
}

// Finding usp-09/P1: NextFrames must stream only the credit window, not
// materialize a large backlog. With many frames and a tiny window, exactly the
// window is returned and the rest stay unsent.
func TestLaneStreamsOnlyCreditWindow(t *testing.T) {
	sp := openSpool(t)
	for i := 0; i < 1000; i++ {
		spoolFrame(t, sp, 16)
	}
	l := newTestLane(t, sp)
	establish(t, l, 1<<20, 4) // window of 4 frames
	frames, err := l.NextFrames()
	if err != nil {
		t.Fatalf("next: %v", err)
	}
	if len(frames) != 4 {
		t.Fatalf("streamed %d frames, want exactly the 4-frame window", len(frames))
	}
	if l.InflightFrames() != 4 {
		t.Fatalf("inflight = %d, want 4", l.InflightFrames())
	}
}
