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
	"google.golang.org/protobuf/encoding/protowire"
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

func zstdOf(tb testing.TB, b []byte) []byte {
	tb.Helper()

	enc, err := zstd.NewWriter(nil)
	if err != nil {
		tb.Fatalf("zstd writer: %v", err)
	}
	defer func() { _ = enc.Close() }()

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
func zstdRecord(tb testing.TB, body []byte) *edgev1.EdgeRecordV1 {
	tb.Helper()

	payload := zstdOf(tb, body)
	sum := sha256.Sum256(payload)

	return &edgev1.EdgeRecordV1{
		Compression:      edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD,
		Payload:          payload,
		PayloadSha256:    sum[:],
		EncodedSize:      uint32(len(payload)),
		UncompressedSize: uint32(len(body)),
	}
}

// stableUUID is a deterministic UUIDv7 whose 48-bit timestamp is a REAL one.
//
// fixedUUIDv7 fills all sixteen bytes with the seed, so its timestamp is ~89 billion
// seconds and `ms * 1_000_000` overflows int64 when the authority window is computed. That
// is invisible until a record is validated as a WHOLE, which is exactly what these vectors
// added -- the payload-binding stage never looks at the event id.
func stableUUID(seed byte) []byte {
	ms := uint64(benchObservedUnixNano / 1_000_000)

	b := make([]byte, 16)
	for i := 6; i < 16; i++ {
		b[i] = seed
	}

	b[0] = byte(ms >> 40)
	b[1] = byte(ms >> 32)
	b[2] = byte(ms >> 24)
	b[3] = byte(ms >> 16)
	b[4] = byte(ms >> 8)
	b[5] = byte(ms)
	b[6] = 0x70
	b[8] = 0x80

	return b
}

// validRecordFixed is the canonical valid record with DETERMINISTIC identities, so a
// committed vector does not change on every regeneration.
func validRecordFixed(t *testing.T) *edgev1.EdgeRecordV1 {
	t.Helper()

	r := validRecord(t)
	r.EventId = stableUUID(0x51)
	r.NetworkScopeId = stableUUID(0x52)
	r.ProducerContext.ProducerAssignmentId = stableUUID(0x53)
	r.ProducerContext.RunId = stableUUID(0x54)
	r.ProducerContext.ScopeId = stableUUID(0x55)

	// The capability and the envelope digest are BOUND to the identities above, and
	// validRecord computed both from the random ones it minted. Overwriting the ids without
	// rebinding leaves a record whose committed bytes still carry a random capability -- the
	// vector then drifts on every regeneration even though every id it names is fixed.
	r.ProductionCapability = productionCap(t, r)
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

	return r
}

// composedSweepRecord is a COMPLETE record -- one that passes ValidateRecord -- carrying a
// real, valid SweepObservationBatchV1 compressed with ZSTD.
//
// The earlier version of this corpus carried arbitrary filler in an otherwise incomplete
// record, which admission accepted because admission never looks at the envelope or decodes
// the body. That proved payload binding and nothing about the composed path.
func composedSweepRecord(t *testing.T, body []byte) *edgev1.EdgeRecordV1 {
	t.Helper()

	payload := zstdOf(t, body)
	sum := sha256.Sum256(payload)

	r := validRecordFixed(t)
	r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_ZSTD
	r.Payload = payload
	r.PayloadSha256 = sum[:]
	r.EncodedSize = uint32(len(payload))
	r.UncompressedSize = uint32(len(body))
	r.ProductionCapability = productionCap(t, r)
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

	return r
}

// sweepBody marshals a valid batch of the given size. Deterministic: benchBatch uses fixed
// identities throughout.
func sweepBody(t *testing.T, hosts int, mixed bool) []byte {
	t.Helper()

	b := benchBatch(hosts, mixed)
	if err := ValidateSweepObservationBatch(b); err != nil {
		t.Fatalf("the corpus body must be VALID, not merely well formed: %v", err)
	}

	raw, err := proto.Marshal(b)
	if err != nil {
		t.Fatalf("marshal batch: %v", err)
	}

	return raw
}

// noncanonicalBodyOfSize builds a body of EXACTLY total bytes that decodes to the canonical
// maximal sweep batch.
//
// This ABI ACCEPTS NONCANONICAL ENCODINGS -- unmarshalPayload deliberately does not impose a
// decode/re-encode equality, because payload identity is payload_sha256 over the EXACT
// received bytes. So a body may carry a DUPLICATE encoding of a singular field, and
// last-one-wins means the canonical value appended afterwards is the one the decoder keeps.
//
// That is what makes a body above the 512 KiB physical ceiling reachable while every family
// bounds its own CANONICAL size far below it. The padding rides in a duplicate of singular
// bytes field 13 (availability_policy_id); the real value follows and wins.
func noncanonicalBodyOfSize(t *testing.T, total, entropy int) []byte {
	t.Helper()

	canonical := sweepBody(t, MaxSweepHostsPerBatch, true)

	// total = tag(1) + varint(len(junk)) + len(junk) + len(canonical). The varint's own
	// width depends on the value it encodes, so solve for the fixed point.
	junkLen := total - len(canonical) - 1
	for range 8 {
		next := total - len(canonical) - 1 - protowire.SizeVarint(uint64(junkLen))
		if next == junkLen {
			break
		}

		junkLen = next
	}

	if junkLen <= 0 {
		t.Fatalf("total %d leaves no room for padding beside a %d-byte body", total, len(canonical))
	}

	var out []byte
	out = protowire.AppendTag(out, 13, protowire.BytesType)
	out = protowire.AppendBytes(out, tunedBody(junkLen, entropy))
	out = append(out, canonical...)

	if len(out) != total {
		t.Fatalf("built %d bytes, want exactly %d", len(out), total)
	}

	return out
}

// assertDecodesToCanonicalBatch is the whole point of the noncanonical vectors: the bytes are
// oversized, and what they MEAN is the ordinary bounded batch.
func assertDecodesToCanonicalBatch(t *testing.T, body []byte) {
	t.Helper()

	var got edgev1.SweepObservationBatchV1
	if err := unmarshalPayload(body, &got); err != nil {
		t.Fatalf("the noncanonical body must decode: %v", err)
	}

	if err := ValidateSweepObservationBatch(&got); err != nil {
		t.Fatalf("the decoded body must VALIDATE: %v", err)
	}

	if !proto.Equal(&got, benchBatch(MaxSweepHostsPerBatch, true)) {
		t.Fatalf("last-one-wins did not yield the canonical batch")
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
			// THE COMPOSED VECTOR: a COMPLETE record carrying a real, maximal, VALID sweep
			// body. Everything downstream of admission is exercised by
			// TestComposedRecordExtractionAndBodyValidation against these same bytes.
			file:    "record_admit_composed_sweep.bin",
			outcome: verdictAccept,
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
				return composedSweepRecord(t, sweepBody(t, MaxSweepHostsPerBatch, true))
			},
		},
		{
			// COMPOSED REACHABILITY: a body ABOVE the 512 KiB physical ceiling that is a
			// VALID contract body, carried by a record far below it. See
			// noncanonicalBodyOfSize -- the ABI accepts noncanonical encodings, so the
			// padding rides in a duplicate of a singular field and last-one-wins yields the
			// ordinary bounded batch.
			file:    "record_admit_oversize_body.bin",
			outcome: verdictAccept,
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
				return composedSweepRecord(t, noncanonicalBodyOfSize(t, 700*1024, 10_000))
			},
		},
		{
			// THE BINDING. Without it the ratio's denominator is whatever the sender
			// claims, so any body passes the ratio by declaring a large encoded_size.
			file:    "record_admit_encoded_size_unbound.bin",
			outcome: "encoded_size",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
				r := composedSweepRecord(t, sweepBody(t, 20, false))
				r.EncodedSize = uint32(len(r.GetPayload()) + 1)

				return r
			},
		},
		{
			file:    "record_admit_digest_mismatch.bin",
			outcome: "payload_digest",
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
				r := composedSweepRecord(t, sweepBody(t, 20, false))
				r.PayloadSha256 = make([]byte, sha256Len)

				return r
			},
		},
		{
			// EXACTLY 100:1 is ADMITTED -- the ratio ceiling is inclusive.
			//
			// FILLER, not a contract body, and deliberately so: hitting an EXACT ratio
			// requires tuning the body's compressibility byte by byte, which no real
			// message affords. The stage under test does not decode the payload.
			file:    "record_admit_ratio_at_ceiling.bin",
			outcome: verdictAccept,
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
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
				t.Helper()
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
				t.Helper()
				r := validRecordFixed(t)
				r.UncompressedSize = r.GetEncodedSize() + 1

				return r
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
				t.Helper()
				r := composedSweepRecord(t, sweepBody(t, 20, false))
				r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_UNSPECIFIED

				return r
			},
		},
		{
			// RECURSIVE COMPRESSION, at the admission stage: the outer frame is a perfectly
			// well-formed single frame, so admission ACCEPTS it. The one-compression-LAYER
			// rule is not an admission rule -- it is decided one stage later, and
			// TestRecursiveCompressionIsRefusedAsAContractPayload is where that is proven,
			// on a COMPLETE record so the refusal is reached the way a real one would be.
			file:    "record_admit_recursive_outer.bin",
			outcome: verdictAccept,
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
				return composedSweepRecord(t, recursiveInnerFrame(t))
			},
		},
		{
			// THE 32 MiB OUTPUT CEILING, COMMITTED rather than constructed.
			//
			// It costs ~340 KiB, which buys the one thing a shared recipe cannot: both
			// runtimes admit the SAME BYTES. Compressing the recipe independently in Go and
			// OTP produces two different frames, so "the ceiling is inclusive" would have
			// been asserted about two different inputs and neither runtime would have seen
			// the other's. There is no cheaper vector: admitting exactly 33_554_432 bytes
			// of output while staying within 100:1 REQUIRES at least 335_545 encoded bytes.
			//
			// The over-ceiling half is derived from these same bytes in both runtimes
			// rather than committed twice.
			file:    "record_admit_output_ceiling.bin",
			outcome: verdictAccept,
			build: func(t *testing.T) *edgev1.EdgeRecordV1 {
				t.Helper()
				return composedSweepRecord(t,
					noncanonicalBodyOfSize(t, MaxUncompressedBytes, 400_000))
			},
		},
	}
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
		return verdictAccept
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

// TestComposedRecordExtractionAndBodyValidation walks the REAL path a record takes:
// whole-record validation, extraction, contract decode, body validation. Admission alone
// looks at neither the envelope nor the decoded body, so a vector that stops there can be
// satisfied by an incomplete record carrying arbitrary filler -- which is what an earlier
// version of this corpus did.
func TestComposedRecordExtractionAndBodyValidation(t *testing.T) {
	body := sweepBody(t, MaxSweepHostsPerBatch, true)
	rec := composedSweepRecord(t, body)

	if err := ValidateRecord(rec); err != nil {
		t.Fatalf("the composed record must pass WHOLE-RECORD validation: %v", err)
	}

	inner, err := innerPayload(rec)
	if err != nil {
		t.Fatalf("extraction: %v", err)
	}

	if string(inner) != string(body) {
		t.Fatalf("extracted %d bytes, want the original %d", len(inner), len(body))
	}

	var got edgev1.SweepObservationBatchV1
	if err := unmarshalPayload(inner, &got); err != nil {
		t.Fatalf("the extracted bytes must decode as the contract: %v", err)
	}

	if err := ValidateSweepObservationBatch(&got); err != nil {
		t.Fatalf("the decoded body must VALIDATE: %v", err)
	}

	encoded, err := proto.Marshal(rec)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	if len(encoded) > MaxRecordBytes {
		t.Fatalf("record of %d exceeds MaxRecordBytes %d", len(encoded), MaxRecordBytes)
	}
}

// TestBodyAboveThePhysicalCeilingIsTransportReachable is the composed-reachability
// obligation, met with a VALID contract body rather than filler.
//
// An earlier version of this file claimed the obligation was unsatisfiable, on the grounds
// that every family bounds its own body below 512 KiB -- a maximal sweep batch is ~116 KiB,
// MTR is capped at MaxMtrBatchBytes. That measured CANONICAL marshals and generalized to all
// bytes, which this ABI does not permit: unmarshalPayload deliberately imposes no
// decode/re-encode equality, so a body may carry a duplicate encoding of a singular field
// and still mean exactly the bounded batch. The canonical bound is a bound on MEANING, not
// on received bytes, and the physical ceiling bounds received bytes.
//
// The two ceilings are different KINDS, and this is where that stops being a taxonomy note:
// 512 KiB bounds RECEIVED BYTES, 32 MiB bounds EXTRACTED WORK. The body below exceeds the
// first, is a valid contract body, and rides in a record far under the first.
func TestBodyAboveThePhysicalCeilingIsTransportReachable(t *testing.T) {
	rec := decodeVector(t, "record_admit_oversize_body.bin")

	if err := ValidateRecord(rec); err != nil {
		t.Fatalf("the carrying record must pass WHOLE-RECORD validation: %v", err)
	}

	if rec.GetUncompressedSize() <= MaxPayloadBytes {
		t.Fatalf("body of %d does not exceed the physical ceiling %d",
			rec.GetUncompressedSize(), MaxPayloadBytes)
	}

	raw, err := proto.Marshal(rec)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	if len(raw) > MaxRecordBytes {
		t.Fatalf("record of %d exceeds MaxRecordBytes %d; the body is not reachable after all",
			len(raw), MaxRecordBytes)
	}

	inner, err := innerPayload(rec)
	if err != nil {
		t.Fatalf("extraction: %v", err)
	}

	if len(inner) != int(rec.GetUncompressedSize()) {
		t.Fatalf("extracted %d bytes, declared %d", len(inner), rec.GetUncompressedSize())
	}

	assertDecodesToCanonicalBatch(t, inner)
}

// TestOutputCeilingBoundaryIsWholeRecord pins the 32 MiB ceiling as an INCLUSIVE bound at
// record scope, with the ratio deliberately slack so the CEILING is what decides.
//
// Both halves come from the COMMITTED vector, so the peer admits the same bytes rather than
// its own compressor's rendering of the same recipe.
func TestOutputCeilingBoundaryIsWholeRecord(t *testing.T) {
	rec := decodeVector(t, "record_admit_output_ceiling.bin")

	encoded := len(rec.GetPayload())
	if encoded > MaxPayloadBytes {
		t.Fatalf("frame of %d exceeds the physical ceiling; the vector cannot be admitted", encoded)
	}

	if rec.GetUncompressedSize() != MaxUncompressedBytes {
		t.Fatalf("the vector declares %d, not the ceiling %d",
			rec.GetUncompressedSize(), uint32(MaxUncompressedBytes))
	}

	// The ratio must be SLACK, or a rejection below would be the ratio's doing.
	if uint64(MaxUncompressedBytes) > uint64(encoded)*MaxCompressionRatio {
		t.Fatalf("frame of %d puts 32 MiB over the ratio; the ceiling would not be what decides",
			encoded)
	}

	raw, err := proto.Marshal(rec)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	if len(raw) > MaxRecordBytes {
		t.Fatalf("the COMPLETE record is %d, over MaxRecordBytes %d", len(raw), MaxRecordBytes)
	}

	if err := validatePayloadBinding(rec); err != nil {
		t.Fatalf("exactly MaxUncompressedBytes must be admitted: %v", err)
	}

	// And it is a REAL contract body at the ceiling, not filler: the same noncanonical
	// construction that makes the oversize vector reachable scales to exactly 32 MiB.
	if err := ValidateRecord(rec); err != nil {
		t.Fatalf("the ceiling vector must pass WHOLE-RECORD validation: %v", err)
	}

	inner, err := innerPayload(rec)
	if err != nil {
		t.Fatalf("extraction: %v", err)
	}

	assertDecodesToCanonicalBatch(t, inner)

	// One byte more, same payload bytes. The ratio still passes, so only the ceiling can
	// refuse it -- and the EXACT reason is what separates the two: without the ceiling the
	// frame stage would refuse it as output_size, because the frame produces one byte fewer.
	over := decodeVector(t, "record_admit_output_ceiling.bin")
	over.UncompressedSize = MaxUncompressedBytes + 1

	if uint64(over.GetUncompressedSize()) > uint64(encoded)*MaxCompressionRatio {
		t.Fatalf("the over-ceiling vector also breaks the ratio; it would prove neither")
	}

	if err := validatePayloadBinding(over); !errors.Is(err, ErrUncompressedSize) {
		t.Fatalf("MaxUncompressedBytes+1: %v, want ErrUncompressedSize", err)
	}
}

// decodeVector reads a committed vector back, so a test asserts against the bytes the peer
// will read rather than against an in-memory value that happened to produce them.
func decodeVector(t *testing.T, name string) *edgev1.EdgeRecordV1 {
	t.Helper()

	raw, err := os.ReadFile(goldenPath(name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}

	var rec edgev1.EdgeRecordV1
	if err := proto.Unmarshal(raw, &rec); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}

	return &rec
}

// TestRecursiveCompressionIsRefusedAsAContractPayload proves the ONE-COMPRESSION-LAYER rule,
// which was frozen with nothing exercising it.
//
// The record is COMPLETE, so the refusal is reached the way a real one would be: whole-record
// validation passes, extraction runs, and the contract stage is what says no. Its payload is a
// valid zstd frame whose extracted bytes are ANOTHER valid zstd frame wrapping a valid contract
// message. Correct behaviour decompresses exactly once and refuses those bytes AS THE CONTRACT
// PAYLOAD.
func TestRecursiveCompressionIsRefusedAsAContractPayload(t *testing.T) {
	inner := recursiveInnerFrame(t)
	rec := composedSweepRecord(t, inner)

	if err := ValidateRecord(rec); err != nil {
		t.Fatalf("the outer record is well formed and must validate: %v", err)
	}

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
	// the assertion above could be satisfied by an inner payload that was junk to begin with.
	body := mustMarshal(t, deterministicSweepBatch(t))

	unwrapped, err := DecompressZstdPayload(inner, uint32(len(body)))
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

// deterministicSweepBatch is validSweepBatch with FIXED identifiers. The shared batch helper
// mints a fresh UUIDv7 per call, which is right for behavioural tests and fatal for a
// committed fixture: the bytes would differ on every run.
func deterministicSweepBatch(t *testing.T) *edgev1.SweepObservationBatchV1 {
	t.Helper()

	b := validSweepBatch(t)
	b.ExecutionId = stableUUID(0x41)
	b.ExecutionPlanId = stableUUID(0x42)
	b.TargetRangeId = stableUUID(0x43)
	b.SourceRunId = stableUUID(0x44)
	b.Hosts[0].Mtr.TraceId = stableUUID(0x45)

	return b
}
