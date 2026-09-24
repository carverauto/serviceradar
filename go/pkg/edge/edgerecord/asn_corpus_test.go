package edgerecord

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The SHARED ASN OBSERVATION corpus (task 1.5-e).
//
// The requirement "An MTR hop's ASN is diagnostic enrichment, not an allocation claim" freezes
// SEMANTICS, not a rejection path: implementations SHALL NOT apply allocation-status filtering,
// zero means unavailable, and every other uint32 is carried through unchanged. There is no
// value a conforming decoder can produce that the rule refuses, so there is nothing for a
// validator to reject -- and therefore nothing a rejection test could pin.
//
// What CAN drift is the number itself: a decode that substitutes, clamps, or truncates. These
// vectors pin that, and `ValidateMtrTraceBatch` cannot: it deliberately never reads `asn`, so a
// truncated value passes it unnoticed. Every case therefore ASSERTS THE DECODED VALUE and only
// then runs the validator.
const asnManifest = "asn_corpus.txt"

// asnHopFieldTag is field 6 (`asn`) of MtrTraceHopV1 at wire type 0 (varint): (6<<3)|0.
const asnHopFieldTag = 0x30

const asnOrgLabel = "AS-Example-Org"

type asnVector struct {
	file string
	// asn is the value the decoder must produce.
	asn uint32
	// org is the asn_org carried alongside it.
	org string
	// explicitZero writes field 6 as an EXPLICIT varint zero rather than omitting it.
	explicitZero bool
	why          string
}

func asnVectors() []asnVector {
	return []asnVector{
		{
			file: "asn_absent.bin", asn: 0, org: "",
			why: "field 6 omitted entirely -- the ordinary encoding of unavailable",
		},
		{
			file: "asn_explicit_zero.bin", asn: 0, org: "", explicitZero: true,
			why: "field 6 present exactly once as varint zero -- same meaning, different bytes",
		},
		{file: "asn_1.bin", asn: 1, org: "", why: "the smallest assigned value"},
		{
			file: "asn_23456.bin", asn: 23456, org: "",
			why: "AS_TRANS, the 2-byte transitional placeholder",
		},
		{file: "asn_64512.bin", asn: 64512, org: "", why: "16-bit private-use lower bound"},
		{file: "asn_65534.bin", asn: 65534, org: "", why: "16-bit private-use upper bound"},
		{file: "asn_65535.bin", asn: 65535, org: "", why: "16-bit reserved (Last ASN)"},
		{
			file: "asn_2147483647.bin", asn: 2147483647, org: "",
			why: "the largest value a SIGNED 32-bit column can hold",
		},
		{
			file: "asn_2147483648.bin", asn: 2147483648, org: "",
			why: "the first value a signed 32-bit column CANNOT hold",
		},
		{
			file: "asn_4200000000.bin", asn: 4200000000, org: "",
			why: "32-bit private-use lower bound",
		},
		{
			file: "asn_4294967294.bin", asn: 4294967294, org: "",
			why: "32-bit private-use upper bound",
		},
		{
			file: "asn_4294967295.bin", asn: 4294967295, org: "",
			why: "32-bit reserved (Last ASN), and the largest uint32",
		},
		{
			file: "asn_zero_with_org.bin", asn: 0, org: asnOrgLabel,
			why: "asn_org is admitted alongside an ABSENT number, independently",
		},
		{
			file: "asn_nonzero_with_org.bin", asn: 64512, org: asnOrgLabel,
			why: "asn_org is admitted alongside a private-use number, independently",
		},
	}
}

// asnHop builds the hop under test. Everything except `asn`/`asn_org` is held constant so a
// vector's only variable is the thing it pins.
func asnHop(v asnVector) *edgev1.MtrTraceHopV1 {
	hop := &edgev1.MtrTraceHopV1{
		HopNumber: 1,
		Sent:      3,
		Received:  3,
		AsnOrg:    v.org,
	}

	if v.explicitZero {
		// proto3 does not serialize a zero-valued non-optional scalar, so the explicit
		// encoding cannot be produced by setting the field. Writing the tag+varint as
		// unknown bytes appends exactly those two bytes after the known fields, which is
		// the encoding a conforming producer would emit, and the decoder resolves it to 0.
		hop.ProtoReflect().SetUnknown(protowire.AppendVarint(
			protowire.AppendTag(nil, 6, protowire.VarintType), 0))

		return hop
	}

	hop.Asn = v.asn

	return hop
}

// asnBatch builds the batch for one vector.
//
// EVERY VECTOR CARRIES ITS OWN TRACE AND EVENT IDENTITY. Sharing them would make the fixtures
// conflicting encodings of ONE logical record rather than a set of records -- which is exactly
// what the requirement says the two zero encodings must NOT be, and would have been just as
// wrong for the value vectors. `seed` is the vector's position, so the identities stay
// deterministic across regeneration.
func asnBatch(t *testing.T, v asnVector, seed byte) *edgev1.MtrTraceBatchV1 {
	t.Helper()

	return &edgev1.MtrTraceBatchV1{
		NetworkScopeId: stableUUID(0x61),
		AgentId:        stableUUID(0x62),
		BatchSequence:  1,
		Source:         edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		Correlation: &edgev1.MtrTraceBatchV1_ScheduledCheck{
			ScheduledCheck: &edgev1.MtrScheduledCheckContextV1{CheckId: stableUUID(0x63)},
		},
		Traces: []*edgev1.MtrTraceEventV1{{
			TraceId:          stableUUID(0x80 + seed),
			EventId:          stableUUID(0xA0 + seed),
			SweepHostAddress: []byte{10, 0, 0, 9},
			Outcome:          edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
			Target:           "10.0.0.9",
			Attempted:        true,
			TargetReached:    true,
			TotalHops:        1,
			Protocol:         edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
			IpVersion:        4,
			Hops:             []*edgev1.MtrTraceHopV1{asnHop(v)},
		}},
	}
}

// countHopAsnFields reports how many times field 6 appears in ONE hop's encoding. The hop is
// marshalled on its own so the scan cannot mistake an unrelated 0x30 byte elsewhere in the
// batch for the tag.
func countHopAsnFields(t *testing.T, hop *edgev1.MtrTraceHopV1) int {
	t.Helper()

	raw, err := proto.Marshal(hop)
	if err != nil {
		t.Fatalf("marshal hop: %v", err)
	}

	count := 0

	for len(raw) > 0 {
		num, typ, n := protowire.ConsumeTag(raw)
		if n < 0 {
			t.Fatalf("malformed hop encoding: %v", protowire.ParseError(n))
		}

		raw = raw[n:]

		if num == 6 {
			count++
		}

		n = protowire.ConsumeFieldValue(num, typ, raw)
		if n < 0 {
			t.Fatalf("malformed hop field: %v", protowire.ParseError(n))
		}

		raw = raw[n:]
	}

	return count
}

// TestAsnSharedCorpus writes the vectors and asserts Go's DECODED values on each.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestAsnSharedCorpus(t *testing.T) {
	lines := make([]string, 0, len(asnVectors()))
	seen := map[string]bool{}

	identities := map[string]bool{}

	for i, v := range asnVectors() {
		if seen[v.file] {
			t.Fatalf("duplicate vector %s", v.file)
		}

		seen[v.file] = true

		encoded, err := proto.Marshal(asnBatch(t, v, byte(i)))
		if err != nil {
			t.Fatalf("%s: marshal: %v", v.file, err)
		}

		goldenBytesLocal(t, v.file, encoded)

		// DECODE AND COMPARE THE VALUE FIRST. The validator below never reads asn, so a
		// substituted or truncated number would survive it.
		var got edgev1.MtrTraceBatchV1
		if err := proto.Unmarshal(encoded, &got); err != nil {
			t.Fatalf("%s: decode: %v", v.file, err)
		}

		hop := got.GetTraces()[0].GetHops()[0]
		if hop.GetAsn() != v.asn {
			t.Fatalf("%s: decoded asn = %d, want %d (%s)", v.file, hop.GetAsn(), v.asn, v.why)
		}

		if hop.GetAsnOrg() != v.org {
			t.Fatalf("%s: decoded asn_org = %q, want %q", v.file, hop.GetAsnOrg(), v.org)
		}

		// POSITIVE VALIDATOR ASSERTION. Numeric drift is not the only prohibited regression:
		// an implementation that started filtering on allocation status would refuse one of
		// these values, and this is what catches that.
		if err := ValidateMtrTraceBatch(&got); err != nil {
			t.Fatalf("%s: every admitted value must validate: %v", v.file, err)
		}

		// Each fixture is its OWN record. Sharing (network_scope_id, event_id) would make
		// them conflicting encodings of one record instead.
		id := string(got.GetNetworkScopeId()) + "/" + string(got.GetTraces()[0].GetEventId())
		if identities[id] {
			t.Fatalf("%s: reuses an identity already used by another vector", v.file)
		}

		identities[id] = true

		lines = append(lines, fmt.Sprintf("%s %d %s", v.file, v.asn, orgField(v.org)))
	}

	goldenBytesLocal(t, asnManifest, []byte(strings.Join(lines, "\n")+"\n"))
}

// orgField keeps the manifest whitespace-delimited: an empty asn_org is written as "-".
func orgField(org string) string {
	if org == "" {
		return "-"
	}

	return org
}

// TestAsnZeroEncodingsAreByteDistinct is the byte-level half of the zero rule.
//
// Asserting only the decoded value would pass trivially -- both encodings decode to 0, which is
// the point -- and would prove nothing about what is on the wire. These assertions are what
// distinguish "field omitted" from "field present as varint zero", and they are the reason the
// two vectors are separate files rather than one.
func TestAsnZeroEncodingsAreByteDistinct(t *testing.T) {
	var absent, explicit asnVector

	for _, v := range asnVectors() {
		switch v.file {
		case "asn_absent.bin":
			absent = v
		case "asn_explicit_zero.bin":
			explicit = v
		}
	}

	if got := countHopAsnFields(t, asnHop(absent)); got != 0 {
		t.Fatalf("absent vector encodes field 6 %d times, want 0", got)
	}

	if got := countHopAsnFields(t, asnHop(explicit)); got != 1 {
		t.Fatalf("explicit-zero vector encodes field 6 %d times, want exactly 1", got)
	}

	// The explicit encoding is the two bytes the rule names, and they are really present in
	// the committed fixture rather than only in this in-memory hop.
	wantBytes := []byte{asnHopFieldTag, 0x00}

	explicitHop, err := proto.Marshal(asnHop(explicit))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	if !bytes.Contains(explicitHop, wantBytes) {
		t.Fatalf("explicit-zero hop does not carry % x", wantBytes)
	}

	if !bytes.Contains(readAsnVector(t, "asn_explicit_zero.bin"), explicitHop) {
		t.Fatalf("the committed fixture does not contain the explicit-zero hop encoding")
	}

	if bytes.Contains(readAsnVector(t, "asn_absent.bin"), wantBytes) {
		t.Fatalf("the absent fixture unexpectedly contains a field-6 varint zero")
	}

	// Both decode to the same observation, which is the semantic half of the same rule --
	// AND they are SEPARATELY IDENTIFIED records. Under one identity they would be
	// conflicting encodings of a single record rather than a pair, which is precisely what
	// the requirement says they must not be.
	decoded := map[string]*edgev1.MtrTraceBatchV1{}

	for _, name := range []string{"asn_absent.bin", "asn_explicit_zero.bin"} {
		var b edgev1.MtrTraceBatchV1
		if err := proto.Unmarshal(readAsnVector(t, name), &b); err != nil {
			t.Fatalf("%s: decode: %v", name, err)
		}

		if got := b.GetTraces()[0].GetHops()[0].GetAsn(); got != 0 {
			t.Fatalf("%s: decoded asn = %d, want 0", name, got)
		}

		decoded[name] = &b
	}

	a, e := decoded["asn_absent.bin"], decoded["asn_explicit_zero.bin"]
	if bytes.Equal(a.GetTraces()[0].GetEventId(), e.GetTraces()[0].GetEventId()) {
		t.Fatalf("the two zero encodings share an event_id, making them one record")
	}

	if bytes.Equal(a.GetTraces()[0].GetTraceId(), e.GetTraces()[0].GetTraceId()) {
		t.Fatalf("the two zero encodings share a trace_id")
	}
}

// TestAsnManifestMatchesDisk keeps the manifest and the vector files in step, so a fixture
// added without a manifest line is never silently unread by the peer.
func TestAsnManifestMatchesDisk(t *testing.T) {
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		t.Skip("regenerating")
	}

	raw, err := os.ReadFile(goldenPath(asnManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != len(asnVectors()) {
		t.Fatalf("manifest has %d entries, the corpus defines %d", len(lines), len(asnVectors()))
	}

	for _, line := range lines {
		parts := strings.Fields(line)
		if len(parts) != 3 {
			t.Fatalf("malformed manifest line %q", line)
		}

		if _, err := strconv.ParseUint(parts[1], 10, 32); err != nil {
			t.Fatalf("manifest asn %q is not a uint32: %v", parts[1], err)
		}

		if _, err := os.Stat(goldenPath(parts[0])); err != nil {
			t.Fatalf("manifest names %s, which is not on disk: %v", parts[0], err)
		}
	}
}

// TestAsnCorpusBracketsSignedStorage pins the two values that exist to catch a signed-32-bit
// projection column, so removing either is a test failure rather than a silent narrowing.
func TestAsnCorpusBracketsSignedStorage(t *testing.T) {
	want := map[uint32]bool{2147483647: false, 2147483648: false, 4294967295: false}

	for _, v := range asnVectors() {
		if _, ok := want[v.asn]; ok {
			want[v.asn] = true
		}
	}

	for value, present := range want {
		if !present {
			t.Fatalf("the corpus no longer covers %d", value)
		}
	}
}

func readAsnVector(t *testing.T, name string) []byte {
	t.Helper()

	raw, err := os.ReadFile(goldenPath(name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}

	return raw
}
