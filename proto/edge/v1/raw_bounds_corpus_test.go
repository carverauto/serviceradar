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

package edgev1_test

import (
	"bytes"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

// These are wire-stage controls, not semantically admitted records/handshakes.
// Frame RecordBytes is opaque at this stage; its own decoder applies its ceiling.
func TestRawBoundsSharedCorpus(t *testing.T) {
	var manifest strings.Builder
	for _, tc := range []struct {
		name     string
		limit    int
		sentinel error
		build    func(int) []byte
		decode   func([]byte) error
	}{
		{"record", 524288, edgerecord.ErrRecordTooLarge,
			func(n int) []byte {
				return rawPaddedProto(t, n, func(pad int) proto.Message { return &edgev1.EdgeRecordV1{Payload: make([]byte, pad)} })
			},
			func(raw []byte) error { _, err := edgerecord.DecodeRecord(raw); return err }},
		{"frame", 540672, edgerecord.ErrFrameTooLarge,
			func(n int) []byte {
				return rawPaddedProto(t, n, func(pad int) proto.Message {
					return &edgev1.EdgeDeliveryFrameV1{RecordBytes: make([]byte, pad), SpoolId: make([]byte, 16377)}
				})
			},
			func(raw []byte) error { _, err := edgerecord.DecodeFrame(raw); return err }},
		{"envelope", 16384, edgerecord.ErrFrameTooLarge,
			func(n int) []byte {
				return rawPaddedProto(t, n+1, func(pad int) proto.Message {
					return &edgev1.EdgeDeliveryFrameV1{RecordBytes: []byte{0}, SpoolId: make([]byte, pad)}
				})
			},
			func(raw []byte) error { _, err := edgerecord.DecodeFrame(raw); return err }},
		{"client", 540680, edgerecord.ErrClientMessageTooLarge,
			func(n int) []byte {
				return rawPaddedProto(t, n, func(pad int) proto.Message {
					return &edgev1.EdgeRecordClientMessage{Payload: &edgev1.EdgeRecordClientMessage_LaneOpen{LaneOpen: &edgev1.EdgeRecordLaneOpen{SessionNonce: make([]byte, pad)}}}
				})
			},
			func(raw []byte) error { _, err := edgerecord.DecodeClientMessage(raw); return err }},
	} {
		for _, over := range []bool{false, true} {
			size := tc.limit
			if over {
				size++
			}
			raw := tc.build(size)
			err := tc.decode(raw)
			if over {
				if !errors.Is(err, tc.sentinel) {
					t.Fatalf("%s over: %v", tc.name, err)
				}
			} else if err != nil {
				t.Fatalf("%s at: %v", tc.name, err)
			}
			name := fmt.Sprintf("raw_bound_%s_%d.bin", tc.name, size)
			goldenBytes(t, name, raw)
			fmt.Fprintf(&manifest, "%s %s %d %t\n", name, tc.name, size, !over)
		}
		// A malformed input above each absolute bound must fail at the size gate,
		// not the parser. Envelope size needs the raw peel and is tested separately.
		if tc.name != "envelope" {
			raw := bytes.Repeat([]byte{0xff}, tc.limit+1)
			if err := tc.decode(raw); !errors.Is(err, tc.sentinel) {
				t.Fatalf("%s predecode: %v", tc.name, err)
			}
			name := "raw_bound_" + tc.name + "_predecode.bin"
			goldenBytes(t, name, raw)
			fmt.Fprintf(&manifest, "%s %s %d false\n", name, tc.name, len(raw))
		}
	}
	goldenText(t, "raw_bounds_corpus.txt", manifest.String())
}

// Find an exact byte length without deriving the frozen test limit from a
// production constant. All padding is synthetic, in a declared opaque bytes field.
func rawPaddedProto(t *testing.T, target int, build func(int) proto.Message) []byte {
	t.Helper()
	lo, hi := 0, target
	for lo <= hi {
		mid := (lo + hi) / 2
		msg := build(mid)
		size := proto.Size(msg)
		if size == target {
			raw, err := proto.Marshal(msg)
			if err != nil {
				t.Fatal(err)
			}
			return raw
		}
		if size < target {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	t.Fatalf("cannot construct exact %d-byte message", target)
	return nil
}

func TestRelationalRawEnvelopeCorpus(t *testing.T) {
	// Canonical size stays tiny while duplicate sequence occurrences consume the
	// received envelope budget. One record byte is subtracted, never a re-encoding.
	var manifest strings.Builder
	for _, overhead := range []int{16384, 16385} {
		raw := protowire.AppendTag(nil, 5, protowire.BytesType)
		raw = protowire.AppendBytes(raw, []byte{0})
		// One non-minimal zero uses an extra byte when parity requires it.
		if (overhead-2)%2 == 1 {
			raw = append(raw, 0x10, 0x80, 0)
		}
		for len(raw)-1 < overhead {
			raw = append(raw, 0x10, 0)
		}
		if len(raw)-1 != overhead {
			t.Fatal("wrong envelope size")
		}
		decoded := &edgev1.EdgeDeliveryFrameV1{}
		if err := proto.Unmarshal(raw, decoded); err != nil {
			t.Fatal(err)
		}
		if proto.Size(decoded) > 8 || len(raw) >= 540672 {
			t.Fatal("relational vector must isolate raw overhead")
		}
		for _, wrapper := range []bool{false, true} {
			artifact := raw
			boundary := "frame"
			if wrapper {
				artifact = protowire.AppendBytes(protowire.AppendTag(nil, 2, protowire.BytesType), raw)
				boundary = "client"
			}
			var err error
			if wrapper {
				_, err = edgerecord.DecodeClientMessage(artifact)
			} else {
				_, err = edgerecord.DecodeFrame(artifact)
			}
			accepted := overhead == 16384
			if accepted && err != nil || !accepted && !errors.Is(err, edgerecord.ErrFrameTooLarge) {
				t.Fatalf("%s envelope=%d: %v", boundary, overhead, err)
			}
			name := fmt.Sprintf("raw_relational_%s_%d.bin", boundary, overhead)
			goldenBytes(t, name, artifact)
			fmt.Fprintf(&manifest, "%s %s %d %t\n", name, boundary, overhead, accepted)
		}
	}
	goldenText(t, "raw_relational_corpus.txt", manifest.String())
}
