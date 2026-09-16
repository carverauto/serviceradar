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

// The SHARED FRAME AND OUTPUT-SIZE corpus (task 1.5-f, slice 2).
//
// Go authors the bytes; both runtimes must reach the same verdict on each. An in-memory
// construction inside one runtime's test proves only that runtime's opinion, and the two
// implementations here are NOT the same shape: Go delegates the window and dictionary rules
// to its decoder while the Elixir peer enforces them in a project-owned preflight. Agreeing
// on hand-built bytes is the only thing that shows those two routes reach one answer.
//
// SCOPE, STATED SO IT IS NOT MISREAD AS MORE THAN IT IS. These vectors exercise
// `ValidateZstdPayload` -- frame structure, window, dictionary, and declared-versus-actual
// output size. They do NOT exercise RECORD-LEVEL admission, which additionally binds
// `encoded_size` to the payload length and applies the 100:1 ratio in
// `validatePayloadBinding` BEFORE any of this runs.
//
// So several vectors here are deliberately unreachable as whole records:
// `zstd_valid_5k.bin` declares 5000 bytes from a 15-byte frame (333:1) and
// `zstd_valid_above_output_buffer.bin` declares 131_073 from 18 (7281:1). Record admission
// refuses both. That is not a defect in the vectors -- it is the stage they belong to -- but
// this corpus MUST NOT be described as proving compression admission.
//
// SLICE 3 OWES THE RECORD-LEVEL SHARED VECTORS. The canonical checklist is task 1.5-f slice
// 3 in openspec/changes/freeze-edge-record-v1-abi/tasks.md -- restating it here produced a
// SECOND inventory that then fell out of date, missing the recursive-compression negative.
package edgerecord

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
)

const compressionManifest = "compression_corpus.txt"

// zframe compresses body into exactly one standard frame.
func zframe(t *testing.T, body []byte) []byte {
	t.Helper()

	var buf bytes.Buffer

	w, err := zstd.NewWriter(&buf, zstd.WithEncoderConcurrency(1))
	if err != nil {
		t.Fatalf("zstd writer: %v", err)
	}

	if _, err := w.Write(body); err != nil {
		t.Fatalf("zstd write: %v", err)
	}

	if err := w.Close(); err != nil {
		t.Fatalf("zstd close: %v", err)
	}

	return buf.Bytes()
}

// handFrame builds a frame header byte-by-byte so the WINDOW DESCRIPTOR and DICTIONARY ID
// can be varied independently of the payload. RFC 8878 orders the header as
// [Window_Descriptor] [Dictionary_ID] [Frame_Content_Size] -- writing the last two the other
// way round produces a frame that breaks two rules at once and proves neither.
func handFrame(fhd byte, extra, body []byte) []byte {
	out := binary.LittleEndian.AppendUint32(make([]byte, 0, 16+len(body)), 0xFD2FB528)
	out = append(out, fhd)
	out = append(out, extra...)
	// One RAW block, marked last.
	hdr := uint32(1) | uint32(len(body))<<3
	out = append(out, byte(hdr), byte(hdr>>8), byte(hdr>>16))

	return append(out, body...)
}

// windowed builds a frame advertising a Window_Descriptor VERBATIM. Descriptor 120 is
// exactly 33_554_432 and 121 is 37_748_736 -- the next MANTISSA step, and the smallest
// representable window above the ceiling. Computing the byte from a window LOG jumps a whole
// exponent to 64 MiB and skips the boundary entirely.
func windowed(descriptor byte, body []byte) []byte {
	return handFrame(0x00, []byte{descriptor}, body)
}

type compressionVector struct {
	file     string
	declared uint32
	// outcome is the portable verdict both runtimes must reach.
	outcome string // accept | invalid | output_size | trailing
	payload func(*testing.T) []byte
}

//nolint:funlen // a flat vector inventory; splitting it hides the shape of the corpus
func compressionVectors() []compressionVector {
	small := []byte("hello")
	body5k := bytes.Repeat([]byte("A"), 5000)
	// Just past OTP's 128 KiB output buffer, which is where a decoder that ignores the
	// streaming remainder starts returning short output or crashing.
	bodyBig := bytes.Repeat([]byte("B"), 131_073)

	return []compressionVector{
		{"zstd_valid_small.bin", 5, verdictAccept,
			func(t *testing.T) []byte { t.Helper(); return zframe(t, small) }},
		{"zstd_valid_5k.bin", 5000, verdictAccept,
			func(t *testing.T) []byte { t.Helper(); return zframe(t, body5k) }},
		// THE BUFFER-BOUNDARY VECTOR. A runtime whose streaming loop ignores the
		// unconsumed-input remainder either crashes or reports a short output here, and
		// every smaller vector passes for it.
		{"zstd_valid_above_output_buffer.bin", 131_073, verdictAccept,
			func(t *testing.T) []byte { t.Helper(); return zframe(t, bodyBig) }},
		// INCOMPRESSIBLE: the frame is LARGER than the body, so the remainder path is
		// driven by expansion rather than by a high compression ratio.
		{"zstd_valid_incompressible.bin", 200_000, verdictAccept, func(t *testing.T) []byte {
			t.Helper()
			return zframe(t, deterministicNoise(200_000))
		}},

		{"zstd_declared_low.bin", 4999, "output_size",
			func(t *testing.T) []byte { t.Helper(); return zframe(t, body5k) }},
		{"zstd_declared_high.bin", 5001, "output_size",
			func(t *testing.T) []byte { t.Helper(); return zframe(t, body5k) }},
		{"zstd_declared_zero.bin", 0, "output_size",
			func(t *testing.T) []byte { t.Helper(); return zframe(t, body5k) }},
		{"zstd_declared_above_ceiling.bin", MaxUncompressedBytes + 1, "output_size",
			func(t *testing.T) []byte { t.Helper(); return zframe(t, body5k) }},

		{"zstd_trailing_byte.bin", 5, "trailing", func(t *testing.T) []byte {
			t.Helper()
			return append(zframe(t, small), 0x00)
		}},
		{"zstd_two_frames.bin", 5, "trailing", func(t *testing.T) []byte {
			t.Helper()
			f := zframe(t, small)

			return append(append([]byte{}, f...), f...)
		}},
		// An EMPTY concatenated frame produces no output, so a decode-side size check sees
		// exactly the declared byte count and admits it. Only a frame-extent check refuses.
		{"zstd_empty_second_frame.bin", 5, "trailing", func(t *testing.T) []byte {
			t.Helper()
			return append(zframe(t, small), zframe(t, nil)...)
		}},
		// A SKIPPABLE frame is likewise consumed silently by a conforming decoder.
		{"zstd_skippable_appended.bin", 5, "trailing", func(t *testing.T) []byte {
			t.Helper()
			sk := binary.LittleEndian.AppendUint32(nil, 0x184D2A50)
			sk = binary.LittleEndian.AppendUint32(sk, 4)
			sk = append(sk, 0xDE, 0xAD, 0xBE, 0xEF)

			return append(zframe(t, small), sk...)
		}},

		{"zstd_truncated.bin", 5000, "invalid", func(t *testing.T) []byte {
			t.Helper()
			f := zframe(t, body5k)

			return f[:len(f)-1]
		}},
		{"zstd_not_a_frame.bin", 5, "invalid",
			func(_ *testing.T) []byte { return []byte{0, 1, 2, 3, 4, 5} }},
		{"zstd_skippable_only.bin", 5, "invalid", func(_ *testing.T) []byte {
			out := binary.LittleEndian.AppendUint32(nil, 0x184D2A50)

			return binary.LittleEndian.AppendUint32(out, 0)
		}},
		{"zstd_reserved_header_bit.bin", 2, "invalid",
			func(_ *testing.T) []byte { return handFrame(0x08, []byte{0}, []byte("hi")) }},
		{"zstd_reserved_block_type.bin", 2, "invalid", func(_ *testing.T) []byte {
			hdr := uint32(1) | uint32(3)<<1 | uint32(2)<<3
			out := binary.LittleEndian.AppendUint32(nil, 0xFD2FB528)
			out = append(out, 0x00, 0x00, byte(hdr), byte(hdr>>8), byte(hdr>>16))

			return append(out, []byte("hi")...)
		}},

		// THE WINDOW PAIR, adjacent by construction and isolated: five bytes of output out
		// of a twelve-byte frame, so neither the output ceiling nor the 100:1 ratio is
		// anywhere near its limit and only the window can be what decides.
		{"zstd_window_at_ceiling.bin", 5, verdictAccept,
			func(_ *testing.T) []byte { return windowed(120, []byte("hello")) }},
		{"zstd_window_above_ceiling.bin", 5, "invalid",
			func(_ *testing.T) []byte { return windowed(121, []byte("hello")) }},

		// DICTIONARY: single-segment (so no window descriptor) with didFlag=1, then the
		// 1-byte dictionary id BEFORE the 1-byte frame content size.
		{"zstd_dictionary_id.bin", 5, "invalid",
			func(_ *testing.T) []byte { return handFrame(0x21, []byte{0x07, 0x05}, []byte("hello")) }},
		// The control for it: the same shape with NO dictionary id is admitted, so the id is
		// what refused the vector above rather than the hand-built framing.
		{"zstd_no_dictionary_control.bin", 5, verdictAccept,
			func(_ *testing.T) []byte { return handFrame(0x20, []byte{0x05}, []byte("hello")) }},
	}
}

// deterministicNoise is incompressible but REPRODUCIBLE -- a random source would make the
// fixture bytes differ on every regeneration and the manifest meaningless.
func deterministicNoise(n int) []byte {
	out := make([]byte, n)
	x := uint32(0x12345678)

	for i := range out {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		out[i] = byte(x)
	}

	return out
}

// goVerdict maps Go's sentinels onto the portable outcome names.
func goVerdict(err error) string {
	switch {
	case err == nil:
		return verdictAccept
	case errors.Is(err, ErrZstdTrailing):
		return "trailing"
	case errors.Is(err, ErrZstdOutputSize):
		return "output_size"
	case errors.Is(err, ErrZstdInvalid):
		return "invalid"
	default:
		return "UNMAPPED:" + err.Error()
	}
}

// TestCompressionSharedCorpus writes the vectors and asserts Go's verdict on each.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestCompressionSharedCorpus(t *testing.T) {
	lines := make([]string, 0, len(compressionVectors()))
	seen := map[string]bool{}

	for _, v := range compressionVectors() {
		if seen[v.file] {
			t.Fatalf("duplicate vector %s", v.file)
		}
		seen[v.file] = true

		payload := v.payload(t)
		goldenBytesLocal(t, v.file, payload)

		got := goVerdict(ValidateZstdPayload(payload, v.declared))
		if got != v.outcome {
			t.Fatalf("%s: Go verdict %q, want %q", v.file, got, v.outcome)
		}

		lines = append(lines, fmt.Sprintf("%s %d %s", v.file, v.declared, v.outcome))
	}

	sort.Strings(lines)
	goldenBytesLocal(t, compressionManifest, []byte(strings.Join(lines, "\n")+"\n"))
}

// TestFrozenCompressionCeilings pins the three frozen values against the spec requirement
// "Compression admission is frozen by value, stage, and frame shape", which is their
// normative source.
//
// THE WINDOW CEILING IS SPELLED SEPARATELY ON PURPOSE. Before this reconciliation the
// decoder was configured with MaxUncompressedBytes, so Go expressed "the window ceiling IS
// the output ceiling" -- which the freeze explicitly calls a coincidence of VALUE rather
// than a rule. Editing one would silently have moved the other, and the two would have
// stopped being independent limits.
func TestFrozenCompressionCeilings(t *testing.T) {
	if MaxUncompressedBytes != 33_554_432 {
		t.Fatalf("MaxUncompressedBytes = %d, frozen at 33_554_432", MaxUncompressedBytes)
	}

	if MaxCompressionRatio != 100 {
		t.Fatalf("MaxCompressionRatio = %d, frozen at 100", MaxCompressionRatio)
	}

	if MaxZstdWindowBytes != 33_554_432 {
		t.Fatalf("MaxZstdWindowBytes = %d, frozen at 33_554_432", MaxZstdWindowBytes)
	}

	// The ratio product must not overflow the width it is evaluated in. With encoded_size
	// bound to a payload already under the 512 KiB physical ceiling, the admitted
	// denominator is at most 524_288 and the product at most 52_428_800.
	const maxAdmittedEncoded = MaxRecordBytes
	if got := uint64(maxAdmittedEncoded) * MaxCompressionRatio; got > uint64(^uint32(0)) {
		t.Fatalf("admitted ratio product %d exceeds 32 bits; the freeze assumes it does not", got)
	}
}

// TestZstdInputCeilingIsEnforcedByTheExportedAPI pins the ENCODED-input bound on the
// exported frame API, which is separate from every work ceiling: it bounds RECEIVED BYTES.
//
// THE INPUT IS A VALID FRAME PLUS PADDING, so the two sides give DIFFERENT reasons and each
// mutation moves one of them:
//
//	exactly 524_288 bytes -> ErrZstdTrailing  (admitted, so the FRAME WALK decides)
//	524_289 bytes         -> ErrZstdInvalid   (the CEILING decides first)
//
// THE BOUND IS THE LITERAL, NOT THE CONSTANT: a frozen value is asserted against a number
// this test states itself, so raising MaxPayloadBytes fails HERE instead of moving the
// vectors with it and letting Go drift from the peer, which pins the same literal.
//
// The bytes are constructed rather than committed: 512 KiB of padding whose content is
// irrelevant would be a megabyte of fixtures to say what a recipe says exactly.
func TestZstdInputCeilingIsEnforcedByTheExportedAPI(t *testing.T) {
	// The frozen physical ceiling on RECEIVED payload bytes, stated here rather than read
	// from the production constant, so a change to the constant fails this test.
	const wantMaxPayload = 524_288

	if MaxPayloadBytes != wantMaxPayload {
		t.Fatalf("MaxPayloadBytes = %d, frozen at %d", MaxPayloadBytes, wantMaxPayload)
	}

	frame := zframe(t, []byte("hello"))

	pad := func(total int) []byte {
		out := make([]byte, total)
		copy(out, frame)

		return out
	}

	atLimit := pad(wantMaxPayload)
	overLimit := pad(wantMaxPayload + 1)

	if err := ValidateZstdPayload(atLimit, 5); !errors.Is(err, ErrZstdTrailing) {
		t.Fatalf("at the ceiling: %v, want ErrZstdTrailing -- the frame walk should decide", err)
	}

	if err := ValidateZstdPayload(overLimit, 5); !errors.Is(err, ErrZstdInvalid) {
		t.Fatalf("over the ceiling: %v, want ErrZstdInvalid -- the ceiling should decide", err)
	}

	// The same two verdicts through the materializing entry point.
	if _, err := DecompressZstdPayload(atLimit, 5); !errors.Is(err, ErrZstdTrailing) {
		t.Fatalf("decompress at the ceiling: %v, want ErrZstdTrailing", err)
	}

	if _, err := DecompressZstdPayload(overLimit, 5); !errors.Is(err, ErrZstdInvalid) {
		t.Fatalf("decompress over the ceiling: %v, want ErrZstdInvalid", err)
	}
}

// TestCompressionCorpusManifestMatchesDisk keeps the manifest and the vector files in step,
// so a fixture added without a manifest line is never silently unread by the peer.
func TestCompressionCorpusManifestMatchesDisk(t *testing.T) {
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		t.Skip("regenerating")
	}

	raw, err := os.ReadFile(goldenPath(compressionManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != len(compressionVectors()) {
		t.Fatalf("manifest has %d entries, the corpus defines %d",
			len(lines), len(compressionVectors()))
	}

	for _, line := range lines {
		name, _, ok := strings.Cut(line, " ")
		if !ok {
			t.Fatalf("malformed manifest line %q", line)
		}

		if _, err := os.Stat(goldenPath(name)); err != nil {
			t.Fatalf("manifest names %s, which is not on disk: %v", name, err)
		}
	}
}
