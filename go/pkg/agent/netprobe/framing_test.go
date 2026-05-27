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

package netprobe

import (
	"bytes"
	"encoding/binary"
	"errors"
	"testing"

	netprobepb "github.com/carverauto/serviceradar/proto/agent/netprobe/v1"
)

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	want := &netprobepb.NetprobeFrame{
		Sequence: 7,
		Payload: &netprobepb.NetprobeFrame_Ping{
			Ping: &netprobepb.Ping{SentAtUnixNano: 42},
		},
	}

	if err := writeFrame(&buf, want); err != nil {
		t.Fatalf("writeFrame() error = %v", err)
	}
	got, err := readFrame(&buf)
	if err != nil {
		t.Fatalf("readFrame() error = %v", err)
	}
	if got.GetSequence() != want.GetSequence() {
		t.Fatalf("Sequence = %d, want %d", got.GetSequence(), want.GetSequence())
	}
	if got.GetPing().GetSentAtUnixNano() != 42 {
		t.Fatalf("Ping sent_at = %d, want 42", got.GetPing().GetSentAtUnixNano())
	}
}

func TestReadFrameRejectsOversizedFrame(t *testing.T) {
	var buf bytes.Buffer
	if err := binary.Write(&buf, binary.BigEndian, uint32(MaxFrameSize+1)); err != nil {
		t.Fatalf("write size prefix: %v", err)
	}

	_, err := readFrame(&buf)
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("readFrame() error = %v, want ErrFrameTooLarge", err)
	}
}
