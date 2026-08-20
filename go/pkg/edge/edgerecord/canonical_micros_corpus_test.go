package edgerecord

import (
	"bufio"
	"crypto/sha256"
	"math"
	"math/big"
	"os"
	"strconv"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/projection"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The SHARED ns->us CANONICALIZATION corpus (task 1.5-c).
//
// The requirement "Nanosecond time is canonicalized to microseconds only at the projection
// boundary" freezes three things: the CONTAINING-BUCKET mathematics, the ORDER relative to the
// two contract hashes, and the consumer list. This file pins the first two.
//
// THE MANIFEST IS NOT GENERATED FROM THE IMPLEMENTATION. Every expected value in
// canonical_micros_corpus.txt is written out by hand, because a manifest produced by calling
// CanonicalMicros cannot detect CanonicalMicros being wrong -- which is exactly the failure
// this corpus exists to catch, and exactly the failure that was live until this slice.
const canonicalMicrosManifest = "canonical_micros_corpus.txt"

type microsVector struct {
	nanos  int64
	micros int64
}

func readMicrosVectors(t *testing.T) []microsVector {
	t.Helper()

	f, err := os.Open(goldenPath(canonicalMicrosManifest))
	if err != nil {
		t.Fatalf("open manifest: %v", err)
	}
	defer func() { _ = f.Close() }()

	var out []microsVector

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.Fields(line)
		if len(parts) != 2 {
			t.Fatalf("malformed manifest line %q", line)
		}

		ns, err := strconv.ParseInt(parts[0], 10, 64)
		if err != nil {
			t.Fatalf("nanoseconds %q: %v", parts[0], err)
		}

		us, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil {
			t.Fatalf("microseconds %q: %v", parts[1], err)
		}

		out = append(out, microsVector{nanos: ns, micros: us})
	}

	if err := sc.Err(); err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	return out
}

// TestCanonicalMicrosMatchesTheSharedManifest is the value comparison.
func TestCanonicalMicrosMatchesTheSharedManifest(t *testing.T) {
	vectors := readMicrosVectors(t)

	// EXACT MEMBERSHIP, not a count. A `len >= 14` gate would accept a required boundary row
	// being replaced by a duplicate of another row -- the count holds, the suite stays green,
	// and the case that was meant to be covered is gone.
	wantInputs := map[int64]bool{
		-1500: false, -1001: false, -1000: false, -999: false, -1: false,
		0: false, 999: false, 1000: false, 1500: false,
		math.MinInt64: false, math.MinInt64 + 807: false, math.MinInt64 + 808: false,
		math.MinInt64 + 999: false, math.MinInt64 + 1000: false,
	}

	seen := map[int64]bool{}

	for _, v := range vectors {
		if seen[v.nanos] {
			t.Fatalf("manifest lists %d more than once", v.nanos)
		}

		seen[v.nanos] = true

		if _, required := wantInputs[v.nanos]; !required {
			t.Fatalf("manifest carries an unexpected input %d", v.nanos)
		}

		wantInputs[v.nanos] = true
	}

	for ns, present := range wantInputs {
		if !present {
			t.Fatalf("manifest no longer covers the required input %d", ns)
		}
	}

	for _, v := range vectors {
		if got := projection.CanonicalMicros(v.nanos); got != v.micros {
			t.Fatalf("CanonicalMicros(%d) = %d, manifest says %d", v.nanos, got, v.micros)
		}
	}
}

// TestCanonicalMicrosNamesTheContainingBucket checks the INVARIANT rather than the table, so a
// manifest and an implementation that drifted together would still be caught.
//
// The bound is evaluated by reasoning about the division rather than by computing u*1000,
// which overflows int64 for the extreme rows -- the same reason the requirement states the
// inequality in widened arithmetic.
func TestCanonicalMicrosNamesTheContainingBucket(t *testing.T) {
	// THE CHECK RUNS IN WIDENED ARITHMETIC, and it has to. Evaluating u*1000 -- or the
	// equivalent ns-off -- in int64 overflows for the extreme rows, which is why the
	// requirement states the inequality mathematically rather than as int64 code. An earlier
	// version of this test did form that intermediate and reported the HELPER as wrong at
	// MinInt64 when the helper was right and the test had committed the very sin the rule
	// forbids.
	thousand := big.NewInt(1000)

	for _, v := range readMicrosVectors(t) {
		u := projection.CanonicalMicros(v.nanos)

		lo := new(big.Int).Mul(big.NewInt(u), thousand)
		hi := new(big.Int).Add(lo, thousand)
		ns := big.NewInt(v.nanos)

		if ns.Cmp(lo) < 0 || ns.Cmp(hi) >= 0 {
			t.Fatalf("ns=%d: bucket %d spans [%s, %s), which does not contain it",
				v.nanos, u, lo, hi)
		}
	}
}

// TestCanonicalMicrosFormsNoUnrepresentableMagnitude pins the two distinct failure causes the
// previous negation-based implementation had, which returned POSITIVE microseconds for the
// most negative instants.
func TestCanonicalMicrosFormsNoUnrepresentableMagnitude(t *testing.T) {
	// At exactly MinInt64 the unary negation wraps; for MinInt64+1..+999 the negation is
	// representable and the +999 bias wraps. Both must yield negative results here.
	for _, ns := range []int64{
		math.MinInt64,
		math.MinInt64 + 1,
		math.MinInt64 + 807,
		math.MinInt64 + 808,
		math.MinInt64 + 999,
		math.MinInt64 + 1000,
	} {
		if got := projection.CanonicalMicros(ns); got >= 0 {
			t.Fatalf("CanonicalMicros(%d) = %d, which is not negative -- a sign flip", ns, got)
		}
	}
}

// The four committed records the hash controls use. Both runtimes read these same bytes.
//
//nolint:gochecknoglobals // immutable committed corpus
var canonicalHashVectors = []string{
	"canonical_hash_observed_128.bin",
	"canonical_hash_observed_999.bin",
	"canonical_hash_capability_128.bin",
	"canonical_hash_capability_999.bin",
}

// mtrBatchAt builds a VALID MtrTraceBatchV1 whose event carries observedNanos.
func mtrBatchAt(t *testing.T, observedNanos int64) *edgev1.MtrTraceBatchV1 {
	t.Helper()

	b := &edgev1.MtrTraceBatchV1{
		NetworkScopeId: stableUUID(0x71),
		AgentId:        stableUUID(0x72),
		BatchSequence:  1,
		Source:         edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		Correlation: &edgev1.MtrTraceBatchV1_ScheduledCheck{
			ScheduledCheck: &edgev1.MtrScheduledCheckContextV1{CheckId: stableUUID(0x73)},
		},
		Traces: []*edgev1.MtrTraceEventV1{{
			TraceId:            stableUUID(0x74),
			EventId:            stableUUID(0x75),
			SweepHostAddress:   []byte{10, 0, 0, 9},
			ObservedAtUnixNano: observedNanos,
			Outcome:            edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
			Target:             "10.0.0.9",
			Attempted:          true,
			TargetReached:      true,
			TotalHops:          1,
			Protocol:           edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
			IpVersion:          4,
			Hops:               []*edgev1.MtrTraceHopV1{{HopNumber: 1, Sent: 3, Received: 3}},
		}},
	}

	if err := ValidateMtrTraceBatch(b); err != nil {
		t.Fatalf("the control payload must be a VALID MTR body, not merely well formed: %v", err)
	}

	return b
}

// mtrRecordAt wraps that batch in a complete record, UNCOMPRESSED.
//
// Compression would defeat the control. The isolation argument is that 128 and 999 are
// equal-width varints, so the BODY length does not move -- but a compressor may still emit
// different frame lengths for two different bodies, which would move encoded_size and
// uncompressed_size and reintroduce exactly the confound the 128/999 choice removes. With
// EDGE_RECORD_COMPRESSION_NONE the payload IS the body, so the width argument applies directly
// to the bytes being hashed.
func mtrRecordAt(t *testing.T, observedNanos int64) *edgev1.EdgeRecordV1 {
	t.Helper()

	body := mustMarshal(t, mtrBatchAt(t, observedNanos))
	sum := sha256.Sum256(body)

	r := validRecordFixed(t)
	r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_NONE
	r.Payload = body
	r.PayloadSha256 = sum[:]
	r.EncodedSize = uint32(len(body))
	r.UncompressedSize = uint32(len(body))
	r.ProductionCapability = productionCap(t, r)
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

	return r
}

// TestCanonicalHashVectorsAreWritten commits the four records both runtimes consume.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestCanonicalHashVectorsAreWritten(t *testing.T) {
	obs128 := mtrRecordAt(t, 128)
	obs999 := mtrRecordAt(t, 999)

	cap128 := mtrRecordAt(t, 128)
	cap999 := mtrRecordAt(t, 128)
	cap128.ProductionCapability.NotBeforeUnixNano = 128
	cap999.ProductionCapability.NotBeforeUnixNano = 999

	// RESEAL AFTER THE MUTATION. mtrRecordAt computes semantic_envelope_sha256 from the record
	// as it stands, so moving not_before afterwards leaves both fixtures CARRYING the same
	// stale digest -- one that matches neither of them. The controls recompute the digest, so
	// they passed anyway, which is precisely how a fixture that lies about its own contents
	// survives: nothing that reads it ever consults the field it got wrong.
	cap128.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(cap128)
	cap999.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(cap999)

	for i, r := range []*edgev1.EdgeRecordV1{obs128, obs999, cap128, cap999} {
		goldenBytesLocal(t, canonicalHashVectors[i], mustMarshal(t, r))
	}
}

// TestCanonicalTimeNeverReachesEitherContractHash is the ORDER half of the requirement, proven
// behaviourally on COMMITTED records that the Elixir peer reads byte-for-byte.
//
// "The hashes do not change when the canonicalization changes" would be VACUOUS: it holds
// trivially and would keep holding if the rule were violated. These controls instead show the
// digests moving with the RAW value while the projection coordinate stays put.
func TestCanonicalTimeNeverReachesEitherContractHash(t *testing.T) {
	obs128 := decodeVector(t, "canonical_hash_observed_128.bin")
	obs999 := decodeVector(t, "canonical_hash_observed_999.bin")

	// THE PAYLOAD IS A REAL MTR BODY, and the field under test is the one the requirement
	// names. Asserting the decoded value is what makes the pair mean anything: without it the
	// records are just two blobs that happen to differ.
	for _, c := range []struct {
		rec  *edgev1.EdgeRecordV1
		want int64
	}{{obs128, 128}, {obs999, 999}} {
		var batch edgev1.MtrTraceBatchV1
		if err := unmarshalPayload(c.rec.GetPayload(), &batch); err != nil {
			t.Fatalf("control payload must decode as an MTR batch: %v", err)
		}

		if err := ValidateMtrTraceBatch(&batch); err != nil {
			t.Fatalf("control payload must be a VALID MTR body: %v", err)
		}

		if got := batch.GetTraces()[0].GetObservedAtUnixNano(); got != c.want {
			t.Fatalf("MtrTraceEventV1.observed_at_unix_nano = %d, want %d", got, c.want)
		}
	}

	// EQUAL VARINT WIDTHS. observed_at_unix_nano is an int64 varint: 1 ns occupies one byte and
	// 999 two, so a 1/999 pair would also move encoded_size and uncompressed_size -- which the
	// transcript frames directly -- and the digests would differ even with the transcript's
	// payload_sha256 dependency deleted. 128 and 999 are both two-byte varints, so
	// payload_sha256 is the only transcript member that moves. Asserted, not assumed.
	if len(obs128.GetPayload()) != len(obs999.GetPayload()) {
		t.Fatalf("payload lengths differ (%d vs %d): the varint widths are not equal, so this "+
			"pair does not isolate payload_sha256",
			len(obs128.GetPayload()), len(obs999.GetPayload()))
	}

	if obs128.GetEncodedSize() != obs999.GetEncodedSize() ||
		obs128.GetUncompressedSize() != obs999.GetUncompressedSize() {
		t.Fatalf("size fields moved; the pair is not isolated")
	}

	if projection.CanonicalMicros(128) != projection.CanonicalMicros(999) {
		t.Fatalf("128 ns and 999 ns must share one bucket for this control to mean anything")
	}

	if string(obs128.GetPayload()) == string(obs999.GetPayload()) {
		t.Fatalf("the payloads must differ -- the raw nanosecond is carried in them")
	}

	if string(obs128.GetPayloadSha256()) == string(obs999.GetPayloadSha256()) {
		t.Fatalf("payload_sha256 must differ: the digest is over the exact carried bytes")
	}

	if string(SemanticEnvelopeDigest(obs128)) == string(SemanticEnvelopeDigest(obs999)) {
		t.Fatalf("semantic_envelope_sha256 must differ; it commits payload_sha256")
	}

	// THE ISOLATION IS PROVEN MECHANICALLY, not by listing the fields that were held equal.
	// Normalizing the ONE permitted difference and everything derived from it must leave the
	// two records proto.Equal -- so a SECOND difference introduced by a future regeneration
	// fails here instead of quietly weakening every assertion above.
	assertOnlyDifferenceIsObservedNanos(t, obs128, obs999)

	// CONTROL 2, DIGEST-ONLY AND NOT AN ADMISSION CASE. Moving a signed timestamp while
	// retaining the signature makes the record cryptographically invalid, so neither member is
	// expected to be admitted. The field is NAMED rather than described because "a capability
	// timestamp" could otherwise be implemented against DELIVERY authority, which the semantic
	// envelope excludes -- and that implementation would show no movement at all.
	cap128 := decodeVector(t, "canonical_hash_capability_128.bin")
	cap999 := decodeVector(t, "canonical_hash_capability_999.bin")

	if cap128.GetProductionCapability().GetNotBeforeUnixNano() != 128 ||
		cap999.GetProductionCapability().GetNotBeforeUnixNano() != 999 {
		t.Fatalf("the capability control must carry not_before 128 and 999")
	}

	if string(cap128.GetPayload()) != string(cap999.GetPayload()) ||
		string(cap128.GetPayloadSha256()) != string(cap999.GetPayloadSha256()) {
		t.Fatalf("payload and its digest must be identical in the capability control")
	}

	if string(cap128.GetProductionCapability().GetSignature()) !=
		string(cap999.GetProductionCapability().GetSignature()) {
		t.Fatalf("the signature must be held fixed in the capability control")
	}

	if cap128.GetProductionCapability().GetExpiresAtUnixNano() !=
		cap999.GetProductionCapability().GetExpiresAtUnixNano() {
		t.Fatalf("expiry must be held fixed in the capability control")
	}

	if string(SemanticEnvelopeDigest(cap128)) == string(SemanticEnvelopeDigest(cap999)) {
		t.Fatalf("the transcript frames production_capability.not_before_unix_nano directly, " +
			"so moving it must move semantic_envelope_sha256")
	}

	// THE CARRIED DIGEST MUST MATCH ITS OWN RECORD. The generator computes it before the
	// mutation unless it reseals, which left both fixtures carrying one stale digest that
	// matched NEITHER of them -- invisible to every assertion above, because they all recompute.
	for _, r := range []*edgev1.EdgeRecordV1{obs128, obs999, cap128, cap999} {
		if string(r.GetSemanticEnvelopeSha256()) != string(SemanticEnvelopeDigest(r)) {
			t.Fatalf("a committed fixture carries a semantic_envelope_sha256 that does not " +
				"match its own contents")
		}
	}

	assertOnlyDifferenceIsCapabilityNotBefore(t, cap128, cap999)
}

// assertOnlyDifferenceIsObservedNanos normalizes the permitted field and everything derived
// from it, then requires the clones to be proto.Equal.
func assertOnlyDifferenceIsObservedNanos(t *testing.T, a, b *edgev1.EdgeRecordV1) {
	t.Helper()

	na, nb := normalizeObserved(t, a), normalizeObserved(t, b)
	if !proto.Equal(na, nb) {
		t.Fatalf("the pair differs in more than observed_at_unix_nano; the control is not isolated")
	}
}

func normalizeObserved(t *testing.T, r *edgev1.EdgeRecordV1) *edgev1.EdgeRecordV1 {
	t.Helper()

	c, ok := proto.Clone(r).(*edgev1.EdgeRecordV1)
	if !ok {
		t.Fatalf("clone type")
	}

	var batch edgev1.MtrTraceBatchV1
	if err := proto.Unmarshal(c.GetPayload(), &batch); err != nil {
		t.Fatalf("decode payload: %v", err)
	}

	batch.Traces[0].ObservedAtUnixNano = 0

	c.Payload = mustMarshal(t, &batch)
	c.EncodedSize = uint32(len(c.GetPayload()))
	c.UncompressedSize = uint32(len(c.GetPayload()))
	// Derived from the payload, so they are normalized rather than compared.
	c.PayloadSha256 = nil
	c.SemanticEnvelopeSha256 = nil

	return c
}

// assertOnlyDifferenceIsCapabilityNotBefore does the same for the capability control.
func assertOnlyDifferenceIsCapabilityNotBefore(t *testing.T, a, b *edgev1.EdgeRecordV1) {
	t.Helper()

	na, nb := normalizeCapability(t, a), normalizeCapability(t, b)
	if !proto.Equal(na, nb) {
		t.Fatalf("the pair differs in more than production_capability.not_before_unix_nano; " +
			"the control is not isolated")
	}
}

func normalizeCapability(t *testing.T, r *edgev1.EdgeRecordV1) *edgev1.EdgeRecordV1 {
	t.Helper()

	c, ok := proto.Clone(r).(*edgev1.EdgeRecordV1)
	if !ok {
		t.Fatalf("clone type")
	}

	c.ProductionCapability.NotBeforeUnixNano = 0
	c.SemanticEnvelopeSha256 = nil

	return c
}
