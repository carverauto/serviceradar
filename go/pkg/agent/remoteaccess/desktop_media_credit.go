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
	"fmt"
	"math"
)

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
	if w.closeReason != "" {
		return false
	}

	cost := mediaFrameCreditCost(frame)

	return cost <= w.remainingBytes && cost <= uint64(w.maxChunkBytes)
}

func (w *DesktopMediaCreditWindow) Consume(frame DesktopMediaFrame) error {
	if frame.Flags&DesktopMediaFlagEndOfStream != 0 {
		return nil
	}
	if w.paused {
		return ErrDesktopMediaNoCredit
	}
	if w.closeReason != "" {
		return ErrDesktopMediaNoCredit
	}

	cost := mediaFrameCreditCost(frame)
	if cost > uint64(w.maxChunkBytes) {
		return fmt.Errorf("%w: frame exceeds max chunk", ErrInvalidDesktopMediaFrame)
	}
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
	if w.closeReason != "" {
		return fmt.Errorf("%w: media stream already closed", ErrInvalidDesktopMediaAck)
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
	if closeReason := normalizeDesktopMediaAckCloseReason(ack.CloseReason); closeReason != "" {
		w.closeReason = closeReason
	}
}

func mediaFrameCreditCost(frame DesktopMediaFrame) uint64 {
	return uint64(len(frame.Metadata)) + uint64(len(frame.Payload))
}
