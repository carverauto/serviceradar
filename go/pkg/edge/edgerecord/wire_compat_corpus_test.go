package edgerecord

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The SHARED UNKNOWN-FIELD / UNKNOWN-ENUM compatibility corpus (task 1.5-a).
//
// The rules themselves were already enforced on both sides before this corpus existed. What
// did NOT exist was SHARED EVIDENCE: every structural case was proven by bytes hand-built
// INSIDE the Elixir suite, so the two runtimes were asserted to agree on inputs neither had
// seen from the other. These vectors are Go-authored bytes, committed once, with Go's verdict
// asserted here and the Elixir verdict DERIVED FROM THE MANIFEST by the peer.
//
// ## The two runtimes reject at DIFFERENT LAYERS, and the manifest says so
//
// Recording one verdict per vector would hide the thing most worth knowing. For an
// out-of-range field number or a 10-byte overflow varint Go's WIRE PARSER refuses the bytes
// (ErrRecordDecode), while protobuf-elixir accepts them and it is the project-owned
// `WireValidate` preflight that refuses (`:poison`). For an unknown field or a group it is
// the reverse shape: Go PARSES and RETAINS, then ServiceRadar's own `hasUnknownFields` walk
// rejects. Same accept/reject verdict, different mechanism -- so the manifest carries a
// column per runtime and the claim being frozen is the VERDICT, not the layer.
//
// ## What is deliberately NOT frozen here
//
// The DISPOSITION a rejection resolves to (and which stream or DLQ it routes to) is
// stage- and slot-specific and belongs downstream; see task 1.16. This corpus freezes only
// what both runtimes must agree on for the ABI: accept vs reject, and -- for the enum
// vectors -- the RETAINED VALUE and its FORM.
const wireCompatManifest = "wire_compat_corpus.txt"

// wireCompatVector is one committed input plus the two runtimes' expected verdicts.
//
// retained/form are meaningful only for the enum vectors: `retained` is the effective
// traffic_class number both runtimes must decode, and `form` is how the Elixir decoder must
// surface it -- `integer` for a value with no declared member, `atom` for a declared one.
// That discriminator is load-bearing, not cosmetic: `SemanticValidate`'s recursive gate
// identifies "a retained non-member" as "an enum-typed field holding an integer", so if a
// future generator change made an undeclared value surface as an atom, the gate would stop
// seeing it and this corpus is what fails.
type wireCompatVector struct {
	file   string
	desc   string
	goWant string
	exWant string
	retain string
	form   string
	build  func(t *testing.T) []byte
}

// spliceIntoPath appends `extra` INSIDE the length-delimited payload reached by following
// `path` from the top level -- so `{12}` places a defect inside production_capability and
// `{12, 7}` places it inside that capability's production claims. Every length prefix on the
// way is rewritten. Depth is the point: an outer scanner cannot see either one, which is why
// both runtimes walk rather than peel.
func spliceIntoPath(t *testing.T, msg []byte, path []protowire.Number, extra []byte) []byte {
	t.Helper()

	if len(path) == 0 {
		return append(append([]byte{}, msg...), extra...)
	}

	rest := msg
	offset := 0

	for len(rest) > 0 {
		num, typ, n := protowire.ConsumeTag(rest)
		if n < 0 {
			t.Fatalf("splice: bad tag at %d", offset)
		}

		m := protowire.ConsumeFieldValue(num, typ, rest[n:])
		if m < 0 {
			t.Fatalf("splice: bad value for field %d", num)
		}

		if num == path[0] && typ == protowire.BytesType {
			payload, pn := protowire.ConsumeBytes(rest[n:])
			if pn < 0 {
				t.Fatalf("splice: bad length prefix for field %d", num)
			}

			body := spliceIntoPath(t, payload, path[1:], extra)

			out := append([]byte{}, msg[:offset]...)
			out = protowire.AppendTag(out, num, protowire.BytesType)
			out = protowire.AppendBytes(out, body)

			return append(out, msg[offset+n+pn:]...)
		}

		rest = rest[n+m:]
		offset += n + m
	}

	t.Fatalf("splice: field %d not found", path[0])

	return nil
}

const (
	// EdgeRecordV1.production_capability. The nested carrier for every "at depth" vector.
	fieldProductionCapability = protowire.Number(12)
	// EdgeSignedCapabilityV1.production, the claims oneof member -- one level deeper again.
	fieldProductionClaims = protowire.Number(7)
	// EdgeRecordV1.encoded_size, a SINGULAR uint32: the carrier for the wire-type mismatch.
	fieldEncodedSize = protowire.Number(4)
	// Undeclared in EdgeSignedCapabilityV1 and comfortably inside the valid range.
	unknownFieldNumber = protowire.Number(100)
	// Go's protowire.MaxValidNumber, the INCLUSIVE upper bound (2^29 - 1).
	maxValidFieldNumber = protowire.Number(1<<29 - 1)
)

// The two nesting paths the vectors use, named so the depth being exercised is legible at the
// call site rather than encoded in a bare number.
//
//nolint:gochecknoglobals // test data, not state
var (
	capabilityPath = []protowire.Number{fieldProductionCapability}
	claimsPath     = []protowire.Number{fieldProductionCapability, fieldProductionClaims}
)

// unknownVarintField is one ordinary unknown field: a valid tag, a valid wire type, and a
// value. Go parses and retains it; the frozen ABI then rejects it.
func unknownVarintField(num protowire.Number) []byte {
	b := protowire.AppendTag(nil, num, protowire.VarintType)

	return protowire.AppendVarint(b, 1)
}

// enumRecord is the control with exactly ONE difference: traffic_class. The semantic envelope
// digest is resealed so the digest is NOT a second defect; the production grant is left alone
// so the reject has one cause the validator can name.
func enumRecord(t *testing.T, v int32) []byte {
	t.Helper()

	r := validRecordFixed(t)
	r.TrafficClass = edgev1.EdgeRecordTrafficClass(v)
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

	return mustMarshalRecord(t, r)
}

func mustMarshalRecord(t *testing.T, r *edgev1.EdgeRecordV1) []byte {
	t.Helper()

	raw, err := proto.Marshal(r)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	return raw
}

func wireCompatVectors() []wireCompatVector {
	control := func(t *testing.T) []byte { t.Helper(); return mustMarshalRecord(t, validRecordFixed(t)) }

	return []wireCompatVector{
		{
			// The base every other vector is spliced from. Committed so "exactly one
			// difference" is checkable against bytes rather than asserted in a comment.
			file: "wire_compat_clean.bin", desc: "control: no defect",
			goWant: verdictAccept, exWant: verdictAccept, retain: "1", form: "atom",
			build: control,
		},
		{
			// Go PARSES and RETAINS this, then rejects it: the frozen ABI refuses a record a
			// later reader might reinterpret. protobuf-elixir also retains it (in
			// __unknown_fields__) and decodes cleanly, so the Elixir reject comes from the
			// WireValidate preflight instead.
			file: "wire_compat_unknown_field_top.bin", desc: "ordinary unknown field, record top level",
			goWant: "unknown_fields", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				return append(control(t), unknownVarintField(unknownFieldNumber)...)
			},
		},
		{
			// The SAME defect one level down. Go's hasUnknownFields walk is recursive; the
			// Elixir walker recurses only into schema-declared embedded messages. A top-level
			// scanner cannot see this, which is the entire reason both exist.
			file: "wire_compat_unknown_field_nested.bin", desc: "ordinary unknown field, inside production_capability",
			goWant: "unknown_fields", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				return spliceIntoPath(t, control(t), capabilityPath,
					unknownVarintField(unknownFieldNumber))
			},
		},
		{
			// TWO levels down, inside the capability's PRODUCTION CLAIMS. The depth-1 vector
			// alone cannot distinguish "the walker recurses" from "the walker looks one level
			// into a known carrier"; this one can only pass if the recursion is general.
			file: "wire_compat_unknown_field_depth2.bin", desc: "ordinary unknown field, inside production claims",
			goWant: "unknown_fields", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				return spliceIntoPath(t, control(t), claimsPath, unknownVarintField(unknownFieldNumber))
			},
		},
		{
			// A well-formed GROUP (wire types 3/4). Go retains it as an unknown field;
			// protobuf-elixir silently DISCARDS it, so no unknown-field check downstream could
			// ever see it -- the divergence WireValidate closes. The committed group vectors
			// that predate this corpus are all TOP-LEVEL; this one is nested.
			file: "wire_compat_unknown_group_nested.bin", desc: "group (wire 3/4) inside production_capability",
			goWant: "unknown_fields", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				group := protowire.AppendTag(nil, unknownFieldNumber, protowire.StartGroupType)
				group = protowire.AppendTag(group, unknownFieldNumber, protowire.EndGroupType)

				return spliceIntoPath(t, control(t), capabilityPath, group)
			},
		},
		{
			// The INCLUSIVE boundary: 2^29-1 is a VALID field number, so this is rejected as an
			// ordinary unknown field, NOT as an out-of-range one. Paired with the vector below
			// it proves the bound is inclusive rather than off by one.
			file: "wire_compat_field_number_max.bin", desc: "field number 2^29-1 (in range, undeclared)",
			goWant: "unknown_fields", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				return spliceIntoPath(t, control(t), capabilityPath,
					unknownVarintField(maxValidFieldNumber))
			},
		},
		{
			// One past the bound. Here Go's PARSER refuses the bytes outright, so the verdict
			// arrives as ErrRecordDecode rather than ErrUnknownFields -- a different mechanism
			// from the vector above, reaching the same reject.
			file: "wire_compat_field_number_over.bin", desc: "field number 2^29 (out of range)",
			goWant: "decode", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				over := protowire.AppendTag(nil, maxValidFieldNumber+1, protowire.VarintType)
				over = protowire.AppendVarint(over, 1)

				return spliceIntoPath(t, control(t), capabilityPath, over)
			},
		},
		{
			// 2^64+1 written as a 10-byte varint in a nested wire-0 position. The pinned
			// protobuf-elixir decoder MASKS this to its low 64 bits -- 2^64+1 aliases to 1 --
			// while Go rejects it as overflow. Committed because it is the one shape where
			// "both runtimes agree" and "both runtimes see the same number" are different
			// claims, and only the first is true of the generated decoders.
			file: "wire_compat_varint_overflow.bin", desc: "10-byte uint64-overflow varint, nested",
			goWant: "decode", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				// Field 5 of EdgeSignedCapabilityV1 (not_before_unix_nano), wire type 0.
				ovf := []byte{0x28, 0x81, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02}

				return spliceIntoPath(t, control(t), capabilityPath, ovf)
			},
		},
		{
			// A SINGULAR scalar arriving length-delimited. This one is worth committing
			// precisely because the two runtimes disagree about everything except the verdict:
			// Go retains the mismatched bytes as an unknown field and rejects; the Elixir
			// preflight deliberately passes it (the packed rules apply only to REPEATED fields)
			// and the generated decoder then raises Protobuf.DecodeError, which `classify/1`
			// maps to :poison. That mapping is one clause away from :systemic -- which at a
			// known delivery slot means RETRYABLE FOREVER against Go's permanent reject -- and
			// nothing else in the corpus pins it.
			file: "wire_compat_wire_type_mismatch.bin", desc: "singular scalar sent length-delimited",
			goWant: "unknown_fields", exWant: "poison", retain: "-", form: "-",
			build: func(t *testing.T) []byte {
				t.Helper()
				mism := protowire.AppendTag(nil, fieldEncodedSize, protowire.BytesType)
				mism = protowire.AppendBytes(mism, []byte{0x00})

				return append(control(t), mism...)
			},
		},
		{
			// THE FORWARD-COMPATIBILITY CASE: a value a NEWER producer might legitimately send.
			// 99 is undeclared and non-negative, so protobuf-elixir's own fallback clauses
			// already retain it -- unlike a negative, it never needed the transform. Both
			// runtimes must retain 99 and REJECT: the frozen sets are closed, so a member this
			// build does not know is not admitted merely because it decodes.
			file: "wire_compat_enum_positive.bin", desc: "traffic_class = 99 (undeclared, positive)",
			goWant: "enum", exWant: "unsupported_enum", retain: "99", form: "integer",
			build: func(t *testing.T) []byte { t.Helper(); return enumRecord(t, 99) },
		},
		{
			// The NEGATIVE case, which is the one protobuf-elixir could not represent before
			// `scripts/patch_edge_enum_negatives.exs`: both generated fallbacks are guarded
			// `when is_integer(tag) and tag >= 0`, so a negative RAISED at decode time and
			// Elixir classified as poison what Go accepted-then-semantically-rejected.
			file: "wire_compat_enum_negative.bin", desc: "traffic_class = -1 (undeclared, negative)",
			goWant: "enum", exWant: "unsupported_enum", retain: "-1", form: "integer",
			build: func(t *testing.T) []byte { t.Helper(); return enumRecord(t, -1) },
		},
		{
			// A DECLARED member that the closed sets still exclude. It separates "not a member
			// of the enum" from "not permitted here": UNSPECIFIED decodes to its ATOM in Elixir
			// and is still rejected, so the retained-value gate cannot be what rejects it and
			// the field-specific policy must be.
			file: "wire_compat_enum_unspecified.bin", desc: "traffic_class = 0 (declared UNSPECIFIED)",
			goWant: "enum", exWant: "unsupported_enum", retain: "0", form: "atom",
			build: func(t *testing.T) []byte { t.Helper(); return enumRecord(t, 0) },
		},
	}
}

// THE NORMATIVE CLASS. The frozen claim is ACCEPT vs REFUSE on the same bytes; the reason
// token is which mechanism got there, which the spec deliberately leaves unfrozen ("a
// conforming implementation MAY refuse at either layer"). Normalising through this vocabulary
// is what makes the two independently authored columns a CROSS-RUNTIME assertion rather than
// two runtimes each grading their own homework.
//
// `systemic` and `not_ready` are deliberately ABSENT. Neither is a refusal -- one pauses and
// one leaves the delivery unresolved -- so a vector that started resolving to either is not a
// changed reason, it is a changed CONTRACT, and `wireCompatClass` fails rather than quietly
// normalising it to verdictRefuse.
//
//nolint:gochecknoglobals // frozen vocabulary, not state
var (
	acceptVerdicts = map[string]bool{verdictAccept: true}
	refuseVerdicts = map[string]bool{
		"unknown_fields":   true, // Go: retained unknown field (any depth)
		"decode":           true, // Go: the wire parser refused the bytes
		"too_large":        true, // either: a physical received-byte ceiling
		"enum":             true, // Go: a closed member set refused the value
		"poison":           true, // Elixir: structural preflight or typed decode error
		"unsupported_enum": true, // Elixir: a closed member set refused the value
	}
)

func wireCompatClass(verdict string) (string, error) {
	switch {
	case acceptVerdicts[verdict]:
		return verdictAccept, nil
	case refuseVerdicts[verdict]:
		return verdictRefuse, nil
	default:
		return "", fmt.Errorf("%w: %q is outside the frozen verdict vocabulary", errWireCompatVerdict, verdict)
	}
}

var errWireCompatVerdict = errors.New("wire-compat verdict")

// goWireCompatVerdict is the Go half of the frozen claim: decode the exact received bytes,
// then validate. Both stages are named because they refuse DIFFERENT vectors -- and the name
// is a DIAGNOSTIC. The normative comparison runs on wireCompatClass of it.
func goWireCompatVerdict(raw []byte) string {
	rec, err := DecodeRecord(raw)
	if err != nil {
		switch {
		case errors.Is(err, ErrUnknownFields):
			return "unknown_fields"
		case errors.Is(err, ErrRecordDecode):
			return "decode"
		case errors.Is(err, ErrRecordTooLarge):
			return "too_large"
		default:
			return "unmapped_decode:" + err.Error()
		}
	}

	err = ValidateRecord(rec)

	switch {
	case err == nil:
		return verdictAccept
	case errors.Is(err, ErrTrafficClass):
		return "enum"
	default:
		return "unmapped_validate:" + err.Error()
	}
}

// TestWireCompatSharedCorpus writes the vectors and asserts Go's verdict on each.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestWireCompatSharedCorpus(t *testing.T) {
	vectors := wireCompatVectors()
	lines := make([]string, 0, len(vectors))
	seen := map[string]bool{}

	for _, v := range vectors {
		if seen[v.file] {
			t.Fatalf("duplicate vector %s", v.file)
		}

		seen[v.file] = true

		raw := v.build(t)

		goldenBytesLocal(t, v.file, raw)

		got := goWireCompatVerdict(raw)

		// NORMATIVE: the accept/refuse class, and it must be the class BOTH columns carry.
		// Asserting the Go column alone would let someone move Elixir to verdictAccept, update only
		// the Elixir column, and leave both suites green while Go still refuses -- the two
		// halves each grading their own homework.
		gotClass, err := wireCompatClass(got)
		if err != nil {
			t.Fatalf("%s (%s): %v", v.file, v.desc, err)
		}

		goClass, err := wireCompatClass(v.goWant)
		if err != nil {
			t.Fatalf("%s: go column: %v", v.file, err)
		}

		exClass, err := wireCompatClass(v.exWant)
		if err != nil {
			t.Fatalf("%s: elixir column: %v", v.file, err)
		}

		if goClass != exClass {
			t.Fatalf("%s (%s): the two runtimes disagree -- Go %q is %s, Elixir %q is %s",
				v.file, v.desc, v.goWant, goClass, v.exWant, exClass)
		}

		if gotClass != goClass {
			t.Fatalf("%s (%s): Go %s these bytes, the corpus says %s", v.file, v.desc, gotClass, goClass)
		}

		// DIAGNOSTIC: which mechanism got there. The spec leaves the layer UNFROZEN, so a
		// decoder that legitimately starts refusing earlier changes this token and NOT the
		// class -- update the column, and only then read the class assertion above as the
		// contract question.
		if got != v.goWant {
			t.Errorf("%s (%s): Go reason %q, the corpus records %q (mechanism moved; the class is unchanged)",
				v.file, v.desc, got, v.goWant)
		}

		lines = append(lines, fmt.Sprintf("%s %s %s %s %s", v.file, v.goWant, v.exWant, v.retain, v.form))
	}

	goldenBytesLocal(t, wireCompatManifest, []byte(strings.Join(lines, "\n")+"\n"))
}

// TestWireCompatRetainedEnumValue pins the DECODED NUMBER, not only the verdict.
//
// A decoder that clamped or substituted an unknown enum would still be rejected by the
// closed sets, so the verdict assertions above cannot see it. Go is the reference for the
// number the Elixir peer must reproduce.
func TestWireCompatRetainedEnumValue(t *testing.T) {
	for _, v := range wireCompatVectors() {
		if v.retain == "-" {
			continue
		}

		var want int32

		if _, err := fmt.Sscanf(v.retain, "%d", &want); err != nil {
			t.Fatalf("%s: unparsable retained value %q", v.file, v.retain)
		}

		var rec edgev1.EdgeRecordV1

		// proto.Unmarshal, NOT DecodeRecord: the retention claim is about what the PARSER
		// preserves, and DecodeRecord's unknown-field gate is a separate rule.
		if err := proto.Unmarshal(v.build(t), &rec); err != nil {
			t.Fatalf("%s: Go must RETAIN an unknown enum, not reject it: %v", v.file, err)
		}

		if got := int32(rec.GetTrafficClass()); got != want {
			t.Fatalf("%s: retained traffic_class = %d, want %d", v.file, got, want)
		}
	}
}

// TestWireCompatManifestMatchesDisk compares the manifest against the FIXTURES ON DISK, in
// both directions.
//
// The earlier version of this test compared the manifest to the Go table it was generated
// from, which is the same source twice: an orphan `wire_compat_*.bin` left behind by a renamed
// vector was staged by Bazel, read by nobody, and reported by nothing.
func TestWireCompatManifestMatchesDisk(t *testing.T) {
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		t.Skip("regenerating")
	}

	raw, err := os.ReadFile(goldenPath(wireCompatManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	listed := map[string]bool{}

	for i, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 5 {
			t.Fatalf("manifest line %d has %d columns, want 5: %q", i+1, len(fields), line)
		}

		listed[fields[0]] = true
	}

	onDisk := map[string]bool{}

	// Glob the directory the MANIFEST resolved to, not a wildcard passed through goldenPath.
	// goldenPath probes its argument with os.Stat, and a literal `wire_compat_*.bin` never
	// exists, so passing a pattern skips every fallback and returns the last candidate. It
	// happens to work because rules_go runs this test from its package-relative directory --
	// but it would fail silently under any runner that does not.
	matches, err := filepath.Glob(filepath.Join(filepath.Dir(goldenPath(wireCompatManifest)), "wire_compat_*.bin"))
	if err != nil {
		t.Fatalf("glob fixtures: %v", err)
	}

	for _, m := range matches {
		onDisk[filepath.Base(m)] = true
	}

	if len(onDisk) == 0 {
		t.Fatal("no wire_compat_*.bin found on disk; the guard would pass vacuously")
	}

	for name := range listed {
		if !onDisk[name] {
			t.Errorf("manifest names %s, which is not on disk", name)
		}
	}

	for name := range onDisk {
		if !listed[name] {
			t.Errorf("%s is on disk but absent from the manifest, so no runtime reads it", name)
		}
	}

	if len(listed) != len(wireCompatVectors()) {
		t.Fatalf("manifest has %d entries, the corpus defines %d", len(listed), len(wireCompatVectors()))
	}
}
