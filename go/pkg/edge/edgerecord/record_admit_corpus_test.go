package edgerecord

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The RECORD-STAGE compression-admission corpus (task 1.5-f, slice 3).
//
// Slice 2's corpus stops at the frame: it exercises ValidateZstdPayload, which sees a
// payload and a declared size and nothing else. Two of the frozen rules cannot be reached
// from there, because they live in RECORD validation:
//
//   - encoded_size is BOUND to the actual payload length, which is what stops the ratio's
//     DENOMINATOR from being chosen by the sender;
//   - the ratio and the 32 MiB output ceiling are applied to the DECLARED sizes, before any
//     decode.
//
// These vectors are therefore whole encoded EdgeRecordV1 messages, and the stage under test
// is validatePayloadBinding -- the record-level payload/compression admission -- not the
// full envelope. Go writes the bytes; the Elixir peer DERIVES its expectation from the
// manifest rather than restating it.
const recordAdmitManifest = "record_admit_corpus.txt"

// chainBytes is deterministic, effectively incompressible filler: sha256 over a counter.
// A shared RECIPE rather than crypto/rand, so the peer can build byte-identical input for
// the vectors that are constructed rather than committed.
func chainBytes(n int) []byte {
	out := make([]byte, 0, n+sha256.Size)

	var ctr [8]byte

	for i := 0; len(out) < n; i++ {
		binary.BigEndian.PutUint64(ctr[:], uint64(i))
		h := sha256.Sum256(ctr[:])
		out = append(out, h[:]...)
	}

	return out[:n]
}

func zstdOf(t testing.TB, b []byte) []byte {
	t.Helper()

	enc, err := zstd.NewWriter(nil)
	if err != nil {
		t.Fatalf("zstd writer: %v", err)
	}
	defer enc.Close()

	return enc.EncodeAll(b, nil)
}

// tunedBody returns a body of exactly total bytes whose first incompressible bytes make the
// compressed frame land in a controlled size range: the rest is zeros, which cost almost
// nothing, so the frame size tracks incompressible.
func tunedBody(total, incompressible int) []byte {
	b := make([]byte, total)
	copy(b, chainBytes(incompressible))

	return b
}

// zstdRecord builds a record whose payload-binding fields are internally consistent. Callers
// then break exactly ONE of them, so each vector's rejection has a single cause.
func zstdRecord(t testing.TB, body []byte) *edgev1.EdgeRecordV1 {
	t.Helper()

	payload := zstdOf(t, body)
	sum := sha256.Sum256(payload)

	return &edgev1.EdgeRecordV1{
		Compression:      edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD,
		Payload:          payload,
		PayloadSha256:    sum[:],
		EncodedSize:      uint32(len(payload)),
		UncompressedSize: uint32(len(body)),
	}
}

// exactRatioBody finds a body whose length is EXACTLY ratio times its compressed length.
//
// It cannot be computed directly: the compressed length depends on the body, and the body
// length is defined in terms of the compressed length. Setting total = frame * ratio and
// recompressing converges in a few rounds, because the added bytes are zeros and barely
// move the frame size. Failing to converge is a hard failure, never a near-miss -- a vector
// one byte off the boundary proves nothing about an inclusive bound.
func exactRatioBody(t *testing.T, ratio int) []byte {
	t.Helper()

	const incompressible = 2048

	total := incompressible * ratio

	for range 40 {
		body := tunedBody(total, incompressible)

		frame := zstdOf(t, body)
		if len(frame)*ratio == total {
			return body
		}

		total = len(frame) * ratio
	}

	t.Fatalf("no body converged to an exact %d:1 ratio", ratio)

	return nil
}

type recordVector struct {
	file    string
	outcome string
	build   func(t *testing.T) *edgev1.EdgeRecordV1
}

func recordAdmitVectors() []recordVector {
	return []recordVector{
		{
			// COMPOSED REACHABILITY: a body well above the 512 KiB PHYSICAL ceiling on
			// received bytes, carried by a record that itself fits under it. This is the
			// vector proving such a body is transport-reachable at all; 1.2-c's decoder
			// vectors assert nothing about whether a record carrying one survives
			// admission.
			file:    "record_admit_reachable_body.bin",
			outcome: "accept",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				return zstdRecord(t, tunedBody(600*1024, 9000))
			},
		},
		{
			// THE BINDING. Without it the ratio's denominator is whatever the sender
			// claims, so any body passes the ratio by declaring a large encoded_size.
			file:    "record_admit_encoded_size_unbound.bin",
			outcome: "encoded_size",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				r := zstdRecord(t, tunedBody(600*1024, 9000))
				r.EncodedSize = uint32(len(r.GetPayload()) + 1)

				return r
			},
		},
		{
			file:    "record_admit_digest_mismatch.bin",
			outcome: "payload_digest",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				r := zstdRecord(t, tunedBody(600*1024, 9000))
				r.PayloadSha256 = make([]byte, sha256Len)

				return r
			},
		},
		{
			// EXACTLY 100:1 is ADMITTED -- the ratio ceiling is inclusive.
			file:    "record_admit_ratio_at_ceiling.bin",
			outcome: "accept",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				return zstdRecord(t, exactRatioBody(t, MaxCompressionRatio))
			},
		},
		{
			// ONE MORE BYTE of declared output is refused. The frame is unchanged, so the
			// declaration no longer matches what it produces either -- and that is the
			// point of asserting the EXACT reason: the ratio must be what refuses this,
			// and if the ratio check were removed the frame stage would refuse it as
			// output_size instead.
			file:    "record_admit_ratio_over_ceiling.bin",
			outcome: "uncompressed_size",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				r := zstdRecord(t, exactRatioBody(t, MaxCompressionRatio))
				r.UncompressedSize++

				return r
			},
		},
		{
			// The NONE arm: uncompressed_size must equal encoded_size exactly.
			file:    "record_admit_none_size_mismatch.bin",
			outcome: "uncompressed_size",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				payload := []byte("an uncompressed contract payload")
				sum := sha256.Sum256(payload)

				return &edgev1.EdgeRecordV1{
					Compression:      edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE,
					Payload:          payload,
					PayloadSha256:    sum[:],
					EncodedSize:      uint32(len(payload)),
					UncompressedSize: uint32(len(payload) + 1),
				}
			},
		},
		{
			// UNSPECIFIED is not an admitted codec.
			//
			// WHAT THIS VECTOR DOES NOT PROVE: that the knownCompression GATE is what
			// refused it. The gate's accepted set is exactly the switch's cases, so
			// bypassing the gate leaves the switch's default arm returning the same error
			// -- deleting the gate keeps this vector green, and no representable value can
			// separate them. That is recorded rather than papered over. The gate earns its
			// place against DRIFT, not against any input: a codec added to the switch
			// without being added to the accepted set would be admitted by the switch and
			// refused by the gate, which is the single-authority property the comment on
			// validatePayloadBinding claims.
			file:    "record_admit_codec_unspecified.bin",
			outcome: "compression",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				r := zstdRecord(t, tunedBody(600*1024, 9000))
				r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_UNSPECIFIED

				return r
			},
		},
		{
			// RECURSIVE COMPRESSION, at the admission stage: the outer frame is a perfectly
			// well-formed single frame, so admission ACCEPTS it. The one-compression-LAYER
			// rule is not an admission rule -- it is decided one stage later, and
			// TestRecursiveCompressionIsRefusedAsAContractPayload is where that is proven.
			// Committing it here pins the half of the behaviour this stage owns.
			file:    "record_admit_recursive_outer.bin",
			outcome: "accept",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				return zstdRecord(t, recursiveInnerFrame(t))
			},
		},
	}
}

// deterministicSweepBatch is validSweepBatch with FIXED identifiers. The shared batch helper
// mints a fresh UUIDv7 per call, which is right for behavioural tests and fatal for a
// committed fixture: the bytes would differ on every run, so the vector would drift rather
// than pin anything.
func deterministicSweepBatch(t *testing.T) *edgev1.SweepObservationBatchV1 {
	t.Helper()

	b := validSweepBatch(t)
	b.ExecutionId = fixedUUIDv7(0x41)
	b.ExecutionPlanId = fixedUUIDv7(0x42)
	b.TargetRangeId = fixedUUIDv7(0x43)
	b.SourceRunId = fixedUUIDv7(0x44)
	b.Hosts[0].Mtr.TraceId = fixedUUIDv7(0x45)

	return b
}

// recursiveInnerFrame is a VALID zstd frame wrapping a VALID contract message -- the bytes a
// recursive implementation would happily unwrap a second time.
func recursiveInnerFrame(t *testing.T) []byte {
	t.Helper()

	return zstdOf(t, mustMarshal(t, deterministicSweepBatch(t)))
}

func recordVerdict(err error) string {
	switch {
	case err == nil:
		return "accept"
	case errors.Is(err, ErrPayloadTooLarge):
		return "payload_too_large"
	case errors.Is(err, ErrEncodedSize):
		return "encoded_size"
	case errors.Is(err, ErrPayloadDigest):
		return "payload_digest"
	case errors.Is(err, ErrCompression):
		return "compression"
	case errors.Is(err, ErrUncompressedSize):
		return "uncompressed_size"
	case errors.Is(err, ErrZstdInvalid):
		return "invalid"
	case errors.Is(err, ErrZstdOutputSize):
		return "output_size"
	case errors.Is(err, ErrZstdTrailing):
		return "trailing"
	default:
		return "unmapped:" + err.Error()
	}
}

// TestRecordAdmitSharedCorpus writes the vectors and asserts Go's verdict on each.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestRecordAdmitSharedCorpus(t *testing.T) {
	lines := make([]string, 0, len(recordAdmitVectors()))
	seen := map[string]bool{}

	for _, v := range recordAdmitVectors() {
		if seen[v.file] {
			t.Fatalf("duplicate vector %s", v.file)
		}

		seen[v.file] = true

		rec := v.build(t)

		encoded, err := proto.Marshal(rec)
		if err != nil {
			t.Fatalf("%s: marshal: %v", v.file, err)
		}

		goldenBytesLocal(t, v.file, encoded)

		if got := recordVerdict(validatePayloadBinding(rec)); got != v.outcome {
			t.Fatalf("%s: Go verdict %q, want %q", v.file, got, v.outcome)
		}

		lines = append(lines, fmt.Sprintf("%s %s", v.file, v.outcome))
	}

	goldenBytesLocal(t, recordAdmitManifest, []byte(strings.Join(lines, "\n")+"\n"))
}

// TestRecordAdmitManifestMatchesDisk keeps the manifest and the vector files in step, so a
// fixture added without a manifest line is never silently unread by the peer.
func TestRecordAdmitManifestMatchesDisk(t *testing.T) {
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		t.Skip("regenerating")
	}

	raw, err := os.ReadFile(goldenPath(recordAdmitManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != len(recordAdmitVectors()) {
		t.Fatalf("manifest has %d entries, the corpus defines %d",
			len(lines), len(recordAdmitVectors()))
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

// TestBodyAboveThePhysicalCeilingIsTransportReachable is the composed-reachability claim
// stated as an assertion rather than as prose.
//
// The two bounds are different KINDS, and this is where that stops being a taxonomy note:
// 512 KiB bounds RECEIVED BYTES, 32 MiB bounds EXTRACTED WORK. A 600 KiB body exceeds the
// first and is still admissible, because what crosses the wire is the 9 KiB frame. The
// record as a whole must still fit MaxRecordBytes, which is asserted here -- a "reachable"
// body carried by a record too large to accept would not be reachable at all.
func TestBodyAboveThePhysicalCeilingIsTransportReachable(t *testing.T) {
	const bodySize = 600 * 1024

	rec := zstdRecord(t, tunedBody(bodySize, 9000))

	if bodySize <= MaxPayloadBytes {
		t.Fatalf("body of %d does not exceed the physical ceiling %d", bodySize, MaxPayloadBytes)
	}

	if err := validatePayloadBinding(rec); err != nil {
		t.Fatalf("a %d-byte body must be admissible: %v", bodySize, err)
	}

	encoded, err := proto.Marshal(rec)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	if len(encoded) > MaxRecordBytes {
		t.Fatalf("record of %d exceeds MaxRecordBytes %d; the body is not reachable after all",
			len(encoded), MaxRecordBytes)
	}
}

// TestOutputCeilingBoundaryIsWholeRecord pins the 32 MiB ceiling as an INCLUSIVE bound at
// record scope, with the ratio deliberately slack so the CEILING is what decides.
//
// Constructed, not committed. The accepted side needs a frame that really does produce
// 33_554_432 bytes while staying above 1/100th of it, which is ~340 KiB of fixture -- larger
// than every existing vector in this corpus combined. The recipe is deterministic, and the
// size window it has to land in is ASSERTED rather than assumed, so a compressor change
// fails here instead of quietly making the vector prove something weaker.
func TestOutputCeilingBoundaryIsWholeRecord(t *testing.T) {
	body := tunedBody(MaxUncompressedBytes, 400_000)
	rec := zstdRecord(t, body)

	encoded := len(rec.GetPayload())
	if encoded > MaxPayloadBytes {
		t.Fatalf("frame of %d exceeds the physical ceiling; the vector cannot be admitted", encoded)
	}

	// The ratio must be SLACK, or a rejection below would be the ratio's doing.
	if uint64(MaxUncompressedBytes) > uint64(encoded)*MaxCompressionRatio {
		t.Fatalf("frame of %d puts 32 MiB over the ratio; the ceiling would not be what decides",
			encoded)
	}

	if err := validatePayloadBinding(rec); err != nil {
		t.Fatalf("exactly MaxUncompressedBytes must be admitted: %v", err)
	}

	// One byte more. The ratio still passes, so only the ceiling can refuse it -- and the
	// EXACT reason is what separates the two: without the ceiling the frame stage would
	// refuse the same record as output_size, because the frame produces one byte fewer.
	over := zstdRecord(t, body)
	over.UncompressedSize = MaxUncompressedBytes + 1

	if uint64(over.GetUncompressedSize()) > uint64(encoded)*MaxCompressionRatio {
		t.Fatalf("the over-ceiling vector also breaks the ratio; it would prove neither")
	}

	if err := validatePayloadBinding(over); !errors.Is(err, ErrUncompressedSize) {
		t.Fatalf("MaxUncompressedBytes+1: %v, want ErrUncompressedSize", err)
	}
}

// TestRecursiveCompressionIsRefusedAsAContractPayload proves the ONE-COMPRESSION-LAYER rule,
// which was frozen with nothing exercising it.
//
// The record carries a valid zstd frame whose extracted bytes are ANOTHER valid zstd frame
// wrapping a valid contract message. Correct behaviour decompresses exactly once and then
// refuses those bytes AS THE CONTRACT PAYLOAD. A runtime that treated the extracted bytes as
// another envelope would unwrap them and find a message that passes every body rule -- which
// is asserted here as the CONTROL, because a negative vector whose inner content was invalid
// anyway would prove nothing about recursion.
func TestRecursiveCompressionIsRefusedAsAContractPayload(t *testing.T) {
	inner := recursiveInnerFrame(t)
	rec := zstdRecord(t, inner)

	// Stage 1: admission accepts. The outer frame is well formed; recursion is not an
	// admission-stage property.
	if err := validatePayloadBinding(rec); err != nil {
		t.Fatalf("the outer frame is valid and must be admitted: %v", err)
	}

	// Stage 2: exactly one decompression, and the result is NOT a contract message.
	extracted, err := innerPayload(rec)
	if err != nil {
		t.Fatalf("innerPayload: %v", err)
	}

	if string(extracted) != string(inner) {
		t.Fatalf("innerPayload decompressed more than one layer")
	}

	var batch edgev1.SweepObservationBatchV1
	if err := unmarshalPayload(extracted, &batch); !errors.Is(err, ErrRecordDecode) {
		t.Fatalf("extracted bytes accepted as a contract payload: %v, want ErrRecordDecode", err)
	}

	// THE CONTROL: unwrapping a second time yields a message that would pass. Without this,
	// the test above could be satisfied by an inner payload that was junk to begin with.
	unwrapped, err := DecompressZstdPayload(inner, uint32(len(mustMarshal(t, deterministicSweepBatch(t)))))
	if err != nil {
		t.Fatalf("control: the inner frame is meant to be valid: %v", err)
	}

	var second edgev1.SweepObservationBatchV1
	if err := unmarshalPayload(unwrapped, &second); err != nil {
		t.Fatalf("control: the doubly-wrapped message is meant to decode: %v", err)
	}

	if err := ValidateSweepObservationBatch(&second); err != nil {
		t.Fatalf("control: the doubly-wrapped message is meant to be VALID, not merely "+
			"decodable -- otherwise a recursive runtime would have rejected it anyway: %v", err)
	}
}

func mustMarshal(t *testing.T, m proto.Message) []byte {
	t.Helper()

	b, err := proto.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	return b
}
