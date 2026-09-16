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

package edgerecord

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"

	"github.com/klauspost/compress/zstd"
)

// zstdScratch bounds the streaming decode buffer so validation never reserves the
// full (up to 32 MiB) output at once.
const zstdScratch = 64 * 1024

var (
	// ErrZstdInvalid is returned when payload is not a decodable single Zstd frame.
	ErrZstdInvalid = errors.New("edgerecord: payload is not a valid zstd frame")
	// ErrZstdOutputSize is returned when the actual decoded size does not equal
	// the declared uncompressed_size.
	ErrZstdOutputSize = errors.New("edgerecord: zstd output size does not match declaration")
	// ErrZstdTrailing is returned when a Zstd payload has trailing bytes or a
	// second concatenated frame.
	ErrZstdTrailing = errors.New("edgerecord: zstd payload has trailing/second-frame data")
)

// ValidateZstdPayload performs a bounded streaming validation of a Zstd payload.
// It FIRST parses the encoded frame structure and requires the single standard
// Zstd frame to end at exactly len(payload): this rejects any trailing bytes, a
// second frame, an empty concatenated frame, and a skippable frame -- klauspost
// transparently consumes no-output trailing frames, so a decode-side "one extra
// output byte" check cannot see them. It THEN decodes without a dictionary,
// streaming through a fixed scratch buffer (never reserving the full output), and
// requires the actual output to equal declaredUncompressed exactly.
func ValidateZstdPayload(payload []byte, declaredUncompressed uint32) error {
	// THE ENCODED INPUT IS BOUNDED HERE, not only by the caller. In the composed path
	// validatePayloadBinding has already refused anything over MaxPayloadBytes, but this is
	// an EXPORTED api described as bounded, and a direct caller could otherwise hand it an
	// arbitrarily large buffer for zstdFrameLen to walk.
	//
	// Reported as ErrZstdInvalid rather than a new sentinel: the frame stage's reason
	// vocabulary is shared with the Elixir peer through the corpus manifest, and adding a
	// fourth reason would change a frozen taxonomy to describe a case the composed path
	// already refuses earlier, with ErrPayloadTooLarge.
	if len(payload) > MaxPayloadBytes {
		return ErrZstdInvalid
	}

	if declaredUncompressed == 0 || uint64(declaredUncompressed) > MaxUncompressedBytes {
		return ErrZstdOutputSize
	}
	frameLen, err := zstdFrameLen(payload)
	if err != nil {
		return err
	}
	if frameLen != len(payload) {
		// A valid frame ends before the payload does: trailing/second/skippable/
		// empty concatenated frame data follows.
		return ErrZstdTrailing
	}
	r, err := zstd.NewReader(bytes.NewReader(payload),
		zstd.WithDecoderMaxMemory(MaxZstdWindowBytes),
		zstd.WithDecoderConcurrency(1))
	if err != nil {
		return ErrZstdInvalid
	}
	defer r.Close()

	scratch := make([]byte, zstdScratch)
	var total uint64
	for {
		n, rerr := r.Read(scratch)
		total += uint64(n)
		if total > uint64(declaredUncompressed) {
			return ErrZstdOutputSize
		}
		if errors.Is(rerr, io.EOF) {
			break
		}
		if rerr != nil {
			return ErrZstdInvalid
		}
		if n == 0 {
			break
		}
	}
	if total != uint64(declaredUncompressed) {
		return ErrZstdOutputSize
	}
	return nil
}

// DecompressZstdPayload validates the frame (via ValidateZstdPayload) and returns the exact
// declaredUncompressed decoded bytes.
//
// IT IS THE FRAME STAGE ONLY. It does NOT apply record-level admission -- the encoded_size
// binding and the 100:1 ratio live in validatePayloadBinding and run BEFORE this in the
// composed path. A caller reaching for this directly gets no ratio gate, so a bomb whose
// frame is well formed is refused only by the 32 MiB output ceiling.
//
// Nothing in the tree calls it today; the composed path uses decompressZstdValidated, which
// skips re-running validation that ValidateRecord already did.
func DecompressZstdPayload(payload []byte, declaredUncompressed uint32) ([]byte, error) {
	if err := ValidateZstdPayload(payload, declaredUncompressed); err != nil {
		return nil, err
	}
	r, err := zstd.NewReader(bytes.NewReader(payload),
		zstd.WithDecoderMaxMemory(MaxZstdWindowBytes),
		zstd.WithDecoderConcurrency(1))
	if err != nil {
		return nil, ErrZstdInvalid
	}
	defer r.Close()
	out := make([]byte, declaredUncompressed)
	if _, err := io.ReadFull(r, out); err != nil {
		return nil, ErrZstdOutputSize
	}
	return out, nil
}

// decompressZstdValidated materializes the inner body. It is the SECOND decode of an
// accepted payload -- ValidateZstdPayload already drained one to verify the output length --
// and it exists so the composed validators do not ALSO re-run that validation and take a
// THIRD pass. Callers MUST have run ValidateZstdPayload (via ValidateRecord) on this
// payload; the frozen rule is one compression LAYER, which two passes do not violate.
func decompressZstdValidated(payload []byte, declaredUncompressed uint32) ([]byte, error) {
	r, err := zstd.NewReader(bytes.NewReader(payload),
		zstd.WithDecoderMaxMemory(MaxZstdWindowBytes),
		zstd.WithDecoderConcurrency(1))
	if err != nil {
		return nil, ErrZstdInvalid
	}
	defer r.Close()
	out := make([]byte, declaredUncompressed)
	if _, err := io.ReadFull(r, out); err != nil {
		return nil, ErrZstdOutputSize
	}
	var extra [1]byte
	if n, _ := r.Read(extra[:]); n != 0 {
		return nil, ErrZstdOutputSize
	}
	return out, nil
}

// zstdFrameLen parses one standard Zstd frame (RFC 8878) at b[0:] and returns its
// exact encoded length in bytes. It rejects a non-Zstd magic, a skippable-frame
// magic, reserved bits/block types, and truncation. It does not decompress; it
// walks the frame header and block headers to find the frame's end offset.
func zstdFrameLen(b []byte) (int, error) {
	const zstdMagic = 0xFD2FB528
	if len(b) < 4 || binary.LittleEndian.Uint32(b[0:4]) != zstdMagic {
		return 0, ErrZstdInvalid
	}
	off := 4
	if off >= len(b) {
		return 0, ErrZstdInvalid
	}
	fhd := b[off]
	off++
	fcsFlag := fhd >> 6
	singleSeg := fhd&0x20 != 0
	if fhd&0x08 != 0 { // reserved bit MUST be zero
		return 0, ErrZstdInvalid
	}
	checksum := fhd&0x04 != 0
	didFlag := fhd & 0x03
	if !singleSeg { // window descriptor byte present
		off++
	}
	off += [...]int{0, 1, 2, 4}[didFlag] // dictionary id
	switch fcsFlag {                     // frame content size
	case 0:
		if singleSeg {
			off++
		}
	case 1:
		off += 2
	case 2:
		off += 4
	case 3:
		off += 8
	}
	if off > len(b) {
		return 0, ErrZstdInvalid
	}
	for { // data blocks until Last_Block
		if off+3 > len(b) {
			return 0, ErrZstdInvalid
		}
		hdr := uint32(b[off]) | uint32(b[off+1])<<8 | uint32(b[off+2])<<16
		off += 3
		last := hdr&1 != 0
		blockType := (hdr >> 1) & 0x3
		blockSize := int(hdr >> 3)
		switch blockType {
		case 0, 2: // raw / compressed: blockSize bytes on the wire
			off += blockSize
		case 1: // RLE: exactly one byte on the wire
			off++
		default: // 3 = reserved
			return 0, ErrZstdInvalid
		}
		if off > len(b) {
			return 0, ErrZstdInvalid
		}
		if last {
			break
		}
	}
	if checksum {
		off += 4
		if off > len(b) {
			return 0, ErrZstdInvalid
		}
	}
	return off, nil
}
