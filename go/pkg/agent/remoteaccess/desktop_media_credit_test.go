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
	"testing"
)

func TestDesktopMediaCreditWindowConsumesAndAdjustsCredit(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(8, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	frame := DesktopMediaFrame{Payload: []byte{1, 2, 3}, Metadata: []byte{4}}
	if !window.CanSend(frame) {
		t.Fatalf("CanSend returned false with available credit")
	}
	if err := window.Consume(frame); err != nil {
		t.Fatalf("Consume returned error: %v", err)
	}
	if window.RemainingBytes() != 4 {
		t.Fatalf("RemainingBytes = %d, want 4", window.RemainingBytes())
	}

	frame.Payload = []byte{1, 2, 3, 4, 5}
	if window.CanSend(frame) {
		t.Fatalf("CanSend returned true with exhausted credit")
	}
	if err := window.Consume(frame); !errors.Is(err, ErrDesktopMediaNoCredit) {
		t.Fatalf("Consume error = %v, want %v", err, ErrDesktopMediaNoCredit)
	}

	window.Adjust(10)
	if window.RemainingBytes() != 14 {
		t.Fatalf("RemainingBytes after adjust = %d, want 14", window.RemainingBytes())
	}
	if err := window.Consume(frame); err != nil {
		t.Fatalf("Consume after adjust returned error: %v", err)
	}
}

func TestDesktopMediaCreditWindowMaxChunkIncludesMetadata(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(16, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	frame := DesktopMediaFrame{
		Metadata: []byte{1, 2, 3, 4, 5},
		Payload:  []byte{6, 7, 8, 9},
	}
	if window.CanSend(frame) {
		t.Fatalf("CanSend returned true for metadata plus payload over max chunk")
	}
	if err := window.Consume(frame); !errors.Is(err, ErrInvalidDesktopMediaFrame) {
		t.Fatalf("Consume error = %v, want %v", err, ErrInvalidDesktopMediaFrame)
	}
	if window.RemainingBytes() != 16 {
		t.Fatalf("RemainingBytes after rejected chunk = %d, want 16", window.RemainingBytes())
	}
}

func TestDesktopMediaCreditWindowAppliesValidatedAck(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  42,
		CreditBytes:      16,
		QualityLevel:     "low",
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck returned error: %v", err)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after ack = %d, want 17", window.RemainingBytes())
	}
	if seq, ok := window.LastAcceptedSeq(); !ok || seq != 42 {
		t.Fatalf("LastAcceptedSeq = %d, %v; want 42, true", seq, ok)
	}

	ack.MediaSessionID = "other-media"
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ApplyAck mismatch error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
}

func TestDesktopMediaCreditWindowRejectsReplayAcks(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  7,
		CreditBytes:      16,
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck returned error: %v", err)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after first ack = %d, want 17", window.RemainingBytes())
	}

	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ApplyAck replay error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after replay ack = %d, want 17", window.RemainingBytes())
	}

	ack.LastAcceptedSeq = 6
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ApplyAck out-of-order error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after stale ack = %d, want 17", window.RemainingBytes())
	}

	ack.LastAcceptedSeq = 8
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck next sequence returned error: %v", err)
	}
	if window.RemainingBytes() != 33 {
		t.Fatalf("RemainingBytes after next ack = %d, want 33", window.RemainingBytes())
	}
}

func TestDesktopMediaCreditWindowCapsAckCredit(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}
	if window.MaxAckCreditBytes() != DesktopMediaDefaultMaxAckCreditBytes {
		t.Fatalf("MaxAckCreditBytes = %d, want %d", window.MaxAckCreditBytes(), DesktopMediaDefaultMaxAckCreditBytes)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  7,
		CreditBytes:      DesktopMediaDefaultMaxAckCreditBytes + 1024,
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck returned error: %v", err)
	}
	if window.RemainingBytes() != 1+DesktopMediaDefaultMaxAckCreditBytes {
		t.Fatalf(
			"RemainingBytes after oversized ack = %d, want %d",
			window.RemainingBytes(),
			1+DesktopMediaDefaultMaxAckCreditBytes,
		)
	}
}

func TestDesktopMediaCreditWindowAppliesBackpressureControl(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(16, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	frame := DesktopMediaFrame{Payload: []byte{1}}
	if !window.CanSend(frame) {
		t.Fatalf("CanSend returned false before pause")
	}

	pauseAck := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  7,
		CreditBytes:      4,
		QualityLevel:     DesktopMediaQualityLow,
		Pause:            true,
	}
	if err := window.ApplyAck(pauseAck, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck pause returned error: %v", err)
	}
	if !window.Paused() {
		t.Fatalf("Paused returned false after pause ack")
	}
	if window.QualityLevel() != DesktopMediaQualityLow {
		t.Fatalf("QualityLevel = %q, want %q", window.QualityLevel(), DesktopMediaQualityLow)
	}
	if window.RemainingBytes() != 20 {
		t.Fatalf("RemainingBytes = %d, want 20", window.RemainingBytes())
	}
	if window.CanSend(frame) {
		t.Fatalf("CanSend returned true while paused")
	}
	if err := window.Consume(frame); !errors.Is(err, ErrDesktopMediaNoCredit) {
		t.Fatalf("Consume while paused error = %v, want %v", err, ErrDesktopMediaNoCredit)
	}

	resumeAck := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  7,
		QualityLevel:     DesktopMediaQualityAuto,
		Resume:           true,
	}
	if err := window.ApplyAck(resumeAck, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck resume returned error: %v", err)
	}
	if window.Paused() {
		t.Fatalf("Paused returned true after resume ack")
	}
	if window.QualityLevel() != DesktopMediaQualityAuto {
		t.Fatalf("QualityLevel = %q, want %q", window.QualityLevel(), DesktopMediaQualityAuto)
	}
	if window.RemainingBytes() != 20 {
		t.Fatalf("RemainingBytes after same-sequence resume = %d, want 20", window.RemainingBytes())
	}
	if !window.CanSend(frame) {
		t.Fatalf("CanSend returned false after resume")
	}
}

func TestDesktopMediaCreditWindowRejectsDuplicateCreditAtCurrentSequence(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  7,
		CreditBytes:      16,
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck returned error: %v", err)
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ApplyAck duplicate credit error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if window.RemainingBytes() != 17 {
		t.Fatalf("RemainingBytes after duplicate credit = %d, want 17", window.RemainingBytes())
	}
}

func TestDesktopMediaCreditWindowRejectsWhitespaceOnlyCloseReasonAtCurrentSequence(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  7,
		CreditBytes:      16,
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck returned error: %v", err)
	}

	ack.CreditBytes = 0
	ack.CloseReason = "\n\t"
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ApplyAck whitespace close reason error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if window.CloseReason() != "" {
		t.Fatalf("CloseReason = %q, want empty", window.CloseReason())
	}
}

func TestDesktopMediaCreditWindowStopsMediaAfterCloseAck(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(16, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	frame := DesktopMediaFrame{Payload: []byte{1}}
	if !window.CanSend(frame) {
		t.Fatalf("CanSend returned false before close")
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  8,
		CloseReason:      " viewer\nclosed\t",
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck close returned error: %v", err)
	}
	if window.CloseReason() != "viewer closed" {
		t.Fatalf("CloseReason = %q, want viewer closed", window.CloseReason())
	}
	if window.CanSend(frame) {
		t.Fatalf("CanSend returned true after close ack")
	}
	if err := window.Consume(frame); !errors.Is(err, ErrDesktopMediaNoCredit) {
		t.Fatalf("Consume after close error = %v, want %v", err, ErrDesktopMediaNoCredit)
	}
	if !window.CanSend(DesktopMediaFrame{Flags: DesktopMediaFlagEndOfStream}) {
		t.Fatalf("CanSend returned false for EOF after close")
	}
}

func TestDesktopMediaCreditWindowRejectsAcksAfterClose(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 8)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	closeAck := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  8,
		CloseReason:      "viewer closed",
	}
	if err := window.ApplyAck(closeAck, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck close returned error: %v", err)
	}

	creditAck := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  9,
		CreditBytes:      16,
	}
	if err := window.ApplyAck(creditAck, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); !errors.Is(err, ErrInvalidDesktopMediaAck) {
		t.Fatalf("ApplyAck after close error = %v, want %v", err, ErrInvalidDesktopMediaAck)
	}
	if window.RemainingBytes() != 1 {
		t.Fatalf("RemainingBytes after post-close ack = %d, want 1", window.RemainingBytes())
	}
	if seq, ok := window.LastAcceptedSeq(); !ok || seq != 8 {
		t.Fatalf("LastAcceptedSeq = %d, %v; want 8, true", seq, ok)
	}
}

func TestDesktopMediaCreditWindowAllowsEOFWithoutCredit(t *testing.T) {
	t.Parallel()

	window, err := NewDesktopMediaCreditWindow(1, 1)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}
	if err := window.Consume(DesktopMediaFrame{Flags: DesktopMediaFlagEndOfStream}); err != nil {
		t.Fatalf("Consume EOF returned error: %v", err)
	}
}

func TestDesktopMediaCreditWindowExhaustsLongRunningBurstAndRecoversWithAcks(t *testing.T) {
	t.Parallel()

	const (
		initialCredit = 32
		maxChunk      = 8
	)
	const burstFrames = uint64(initialCredit / maxChunk)

	window, err := NewDesktopMediaCreditWindow(initialCredit, maxChunk)
	if err != nil {
		t.Fatalf("NewDesktopMediaCreditWindow returned error: %v", err)
	}

	frame := DesktopMediaFrame{Payload: make([]byte, maxChunk)}

	for seq := uint64(1); seq <= burstFrames; seq++ {
		frame.Sequence = seq
		if !window.CanSend(frame) {
			t.Fatalf("CanSend returned false for burst frame %d", seq)
		}
		if err := window.Consume(frame); err != nil {
			t.Fatalf("Consume burst frame %d returned error: %v", seq, err)
		}
	}
	if window.RemainingBytes() != 0 {
		t.Fatalf("RemainingBytes after burst = %d, want 0", window.RemainingBytes())
	}
	if window.CanSend(frame) {
		t.Fatalf("CanSend returned true after credit exhaustion")
	}
	if err := window.Consume(frame); !errors.Is(err, ErrDesktopMediaNoCredit) {
		t.Fatalf("Consume exhausted frame error = %v, want %v", err, ErrDesktopMediaNoCredit)
	}

	ack := DesktopMediaAck{
		SessionBindingID: desktopMediaTestSessionID,
		MediaSessionID:   desktopMediaTestMediaSessionID,
		LastAcceptedSeq:  burstFrames,
		CreditBytes:      maxChunk * 2,
	}
	if err := window.ApplyAck(ack, desktopMediaTestSessionID, desktopMediaTestMediaSessionID); err != nil {
		t.Fatalf("ApplyAck returned error: %v", err)
	}
	if window.RemainingBytes() != maxChunk*2 {
		t.Fatalf("RemainingBytes after ack = %d, want %d", window.RemainingBytes(), maxChunk*2)
	}

	for seq := burstFrames + 1; seq <= burstFrames+2; seq++ {
		frame.Sequence = seq
		if err := window.Consume(frame); err != nil {
			t.Fatalf("Consume recovered burst frame %d returned error: %v", seq, err)
		}
	}
	if window.RemainingBytes() != 0 {
		t.Fatalf("RemainingBytes after recovered burst = %d, want 0", window.RemainingBytes())
	}
}
