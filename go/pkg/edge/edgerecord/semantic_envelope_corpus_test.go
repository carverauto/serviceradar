package edgerecord

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
	"google.golang.org/protobuf/types/descriptorpb"
)

// Task 1.5-i: THE SEMANTIC-ENVELOPE TRANSCRIPT INVENTORY.
//
// SEVEN KEYED SETS, EACH GUARDED ON ITS OWN, AND NO GRAND TOTAL. They count different proof
// units -- a root slot is a closure view, a framer operation is a lexical write inside one
// framer, a state case is an alternative branch, an attachment edge is a composition-graph
// edge, a separation row is a quantity that must NOT reach the transcript -- so adding them
// would invent a number that means nothing.
//
// EVIDENCE OVERLAPS BY CONSTRUCTION. Deleting one call can fail rows in several sections at
// once: a caller that stops framing `output_contract` breaks its edge row, its slot row and
// every one of its seven operation rows. The mutation reports below therefore record the ACTUAL
// FAILURE SET rather than asserting that exactly one row fails, because "exactly one" would be
// false and enforcing it would push the suite toward weaker, non-overlapping rows.
//
// COMMITTED VECTORS ARE COMMITTED, NOT RECOMPUTED. Where a row's probe is `committed`, the
// expected value is read from a shared artifact. Recomputing it with the live framer would make
// the assertion a tautology: the grammar would be compared against itself and any drift would
// move both sides together.

type semRow struct {
	kind, key, detail, probe string
}

func semanticCorpus(t *testing.T) []semRow {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	f, err := os.Open(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1", "testdata", "semantic_envelope_corpus.txt"))
	if err != nil {
		t.Fatalf("open semantic corpus: %v", err)
	}
	defer func() { _ = f.Close() }()

	var out []semRow

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 4 {
			t.Fatalf("semantic corpus row %q has %d fields, want 4", line, len(fields))
		}

		out = append(out, semRow{kind: fields[0], key: fields[1], detail: fields[2], probe: fields[3]})
	}

	if err := sc.Err(); err != nil {
		t.Fatalf("scan semantic corpus: %v", err)
	}

	return out
}

func semRowsOfKind(t *testing.T, kind string) []semRow {
	t.Helper()

	var out []semRow

	for _, r := range semanticCorpus(t) {
		if r.kind == kind {
			out = append(out, r)
		}
	}

	return out
}

// TestSemanticCorpusCardinality guards each keyed set independently: its exact count AND that
// no key repeats. The counts are stated here rather than derived from the file, so a row
// silently deleted from the manifest fails instead of shrinking the inventory it defines.
func TestSemanticCorpusCardinality(t *testing.T) {
	want := map[string]int{"op": 125, "slot": 17, "state": 8, "edge": 13, "sep": 5, "excl": 2, "rel": 1}

	got := map[string]int{}
	seen := map[string]bool{}

	for _, r := range semanticCorpus(t) {
		got[r.kind]++

		if seen[r.key] {
			t.Fatalf("%s appears twice in the manifest", r.key)
		}

		seen[r.key] = true
	}

	if len(got) != len(want) {
		t.Fatalf("manifest has %d kinds, the inventory names %d", len(got), len(want))
	}

	for kind, n := range want {
		if got[kind] != n {
			t.Fatalf("%s: manifest has %d rows, the inventory names %d", kind, got[kind], n)
		}
	}
}

// ---------------------------------------------------------------------------
// closure: every EdgeRecordV1 field is classified, both directions
// ---------------------------------------------------------------------------

// TestSemanticClosureClassifiesEveryRecordField is bidirectional: no descriptor field is
// unclassified, and no classification names a field that does not exist. A one-way check lets a
// NEW record field arrive uncommitted and unnoticed, which is the drift this exists to catch.
func TestSemanticClosureClassifiesEveryRecordField(t *testing.T) {
	fields := (&edgev1.EdgeRecordV1{}).ProtoReflect().Descriptor().Fields()

	descriptor := map[int]string{}
	for i := range fields.Len() {
		f := fields.Get(i)
		descriptor[int(f.Number())] = string(f.Name())
	}

	// EXACT {number, name, classification} TUPLES. Parsing only the number and assigning into a
	// map lets a DUPLICATE number silently overwrite its predecessor -- the manifest would then
	// classify one field twice and another not at all, while the counts still balanced. The
	// NAME is compared too, so a row keyed `11.network_scope_id` cannot quietly describe
	// field 11 as something it is not.
	type classification struct{ name, class string }

	classified := map[int]classification{}

	record := func(kind, key, class string) {
		parts := strings.SplitN(key, ".", 2)

		n, err := strconv.Atoi(parts[0])
		if err != nil {
			t.Fatalf("%s key %q does not lead with a field number: %v", kind, key, err)
		}

		if prior, dup := classified[n]; dup {
			t.Fatalf("field %d is classified twice: %q then %q -- a duplicate number overwrites "+
				"and leaves some other field unclassified", n, prior.name, parts[1])
		}

		if len(parts) != 2 {
			t.Fatalf("%s key %q carries no field name", kind, key)
		}

		classified[n] = classification{name: parts[1], class: class}
	}

	for _, r := range semRowsOfKind(t, "slot") {
		if r.key == "version" {
			continue // the version prefix is not a record field
		}

		record("slot", r.key, "committed")
	}

	for _, r := range semRowsOfKind(t, "excl") {
		record("excl", r.key, "excluded")
	}

	for n, name := range descriptor {
		c, ok := classified[n]
		if !ok {
			t.Fatalf("record field %d (%s) is in the descriptor but classified nowhere -- a new "+
				"field is uncommitted until the manifest says which it is", n, name)
		}

		if c.name != name {
			t.Fatalf("field %d is %q in the descriptor but %q in the manifest", n, name, c.name)
		}

		switch {
		case n <= 16 && c.class != "committed":
			t.Fatalf("field %d (%s) is classified %s, want committed", n, name, c.class)
		case n >= 17 && c.class != "excluded":
			t.Fatalf("field %d (%s) is classified %s, want excluded", n, name, c.class)
		}
	}

	for n := range classified {
		if _, ok := descriptor[n]; !ok {
			t.Fatalf("the manifest classifies field %d, which the descriptor does not define", n)
		}
	}

	if len(descriptor) != 18 {
		t.Fatalf("EdgeRecordV1 has %d fields; the closure is written for 18 and must be revisited", len(descriptor))
	}
}

// ---------------------------------------------------------------------------
// exclusions and the payload relation
// ---------------------------------------------------------------------------

func TestSemanticExclusions(t *testing.T) {
	// THE TWO EXCLUSIONS ARE EXCLUDED FOR DIFFERENT REASONS and the tuples say which: field 17
	// is `self` because it is the digest's own output, field 18 is `raw` because its bytes are
	// carried transitively instead. Binding both columns is what stops the two reasons being
	// swapped -- the keys alone cannot tell them apart.
	semAssertKeyedTuples(t, "excl", map[string][2]string{
		"17.semantic_envelope_sha256": {"self", "exclude"},
		"18.payload":                  {"raw", "exclude"},
	})

	// FIELD 17 -- the digest itself. Recomputation must not depend on the value already stored,
	// or the transcript would commit to its own output and no stored value could ever be wrong.
	r := validRecord(t)
	base := SemanticEnvelopeDigest(r)

	priorSelf := append([]byte(nil), r.GetSemanticEnvelopeSha256()...)
	r.SemanticEnvelopeSha256 = bytes.Repeat([]byte{0xAB}, sha256Len)

	// THE MUTATION MUST HAVE HAPPENED. If the substituted value equalled the original, "the
	// digest did not move" would be true for the trivial reason and the exclusion unproven.
	if bytes.Equal(r.GetSemanticEnvelopeSha256(), priorSelf) {
		t.Fatal("the field-17 substitution did not change the stored value")
	}

	if got := SemanticEnvelopeDigest(r); !bytes.Equal(got, base) {
		t.Fatal("field 17 is the digest itself and MUST NOT feed its own recomputation")
	}

	// FIELD 18 -- the raw payload, excluded DIRECTLY. It reaches the transcript only through
	// payload_sha256, which the relation row below proves.
	r2 := validRecord(t)
	base2 := SemanticEnvelopeDigest(r2)

	priorPayload := append([]byte(nil), r2.GetPayload()...)
	r2.Payload = bytes.Repeat([]byte{0x5A}, len(r2.GetPayload()))

	if bytes.Equal(r2.GetPayload(), priorPayload) {
		t.Fatal("the field-18 substitution did not change the payload bytes")
	}

	if got := SemanticEnvelopeDigest(r2); !bytes.Equal(got, base2) {
		t.Fatal("field 18 is excluded DIRECTLY; an equal-length payload swap must not move the digest")
	}
}

// TestSemanticPayloadRelation proves field 18 is committed TRANSITIVELY through field 6.
//
// CONSTRUCTION IS NORMATIVE, and the manifest states it: the payloads are EQUAL LENGTH and the
// size fields are HELD FIXED. Unequal lengths would move encoded_size and uncompressed_size as
// well, and the row would then prove those slots rather than this relation.
func TestSemanticPayloadRelation(t *testing.T) {
	semAssertKeyedTuples(t, "rel", map[string][2]string{
		"18.payload->06.payload_sha256": {"transitive", "relation"},
	})

	r := validRecord(t)

	// THE BASELINE MUST BE HONEST FIRST. Without this the row proves only that field 6 is
	// sensitive -- not that the payload is carried THROUGH it -- because a fixture whose hash
	// never matched its payload would behave identically.
	baseSum := sha256.Sum256(r.GetPayload())
	if !bytes.Equal(r.GetPayloadSha256(), baseSum[:]) {
		t.Fatal("the baseline payload_sha256 must be SHA256 of the baseline payload")
	}

	if err := ValidateRecord(r); err != nil {
		t.Fatalf("the baseline record must be admissible: %v", err)
	}

	base := SemanticEnvelopeDigest(r)
	swapped := bytes.Repeat([]byte{0x5A}, len(r.GetPayload()))

	if len(swapped) != len(r.GetPayload()) {
		t.Fatal("the substituted payload must be equal length")
	}

	// HASH HELD FIXED: the digest must not move.
	held := proto.Clone(r).(*edgev1.EdgeRecordV1)
	held.Payload = swapped

	if got := SemanticEnvelopeDigest(held); !bytes.Equal(got, base) {
		t.Fatal("with payload_sha256 held fixed, changing the payload must not move the digest")
	}

	// HASH RECOMPUTED: the digest must move, and ONLY payload_sha256 differs from the case
	// above -- the two records are otherwise byte-identical.
	recomputed := proto.Clone(held).(*edgev1.EdgeRecordV1)
	sum := sha256.Sum256(swapped)
	recomputed.PayloadSha256 = sum[:]

	if bytes.Equal(recomputed.GetPayloadSha256(), held.GetPayloadSha256()) {
		t.Fatal("the recomputed hash must differ from the held one, or the row proves nothing")
	}

	if got := SemanticEnvelopeDigest(recomputed); bytes.Equal(got, base) {
		t.Fatal("recomputing payload_sha256 MUST move the digest -- that is the only path by " +
			"which the payload is committed at all")
	}
}

// semanticSortedKeys is a stable rendering for failure-set reporting.
func semanticSortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}

	sort.Strings(out)

	return out
}

// ---------------------------------------------------------------------------
// framer-local operations: 125 keys, driven from the manifest
// ---------------------------------------------------------------------------

// semFramerOutput runs one framer over a message and returns the framed bytes. The framers are
// same-package methods rather than exported API -- "seam" here means reachable by this suite,
// not part of the public surface. This runtime's peer reaches the same two seams through
// `ClaimsFraming`, which IS public there.
func semFramerOutput(t *testing.T, framer string, m proto.Message, present bool) []byte {
	t.Helper()

	d := newDigest()

	switch framer {
	case "output_contract":
		// PRESENCE IS PASSED EXPLICITLY. A typed nil pointer carried in a proto.Message
		// interface is NOT nil, so `m != nil` reports present for an absent contract and the
		// absent vector would silently be a present one.
		c, _ := m.(*edgev1.EdgeOutputContractRef)
		d.outputContract(c, present)
	case "claims_framed":
		d.claimsFramed(m.(*edgev1.EdgeSignedCapabilityV1))
	case "collection_claims":
		d.collectionClaims(m.(*edgev1.EdgeCollectionClaimsV1))
	case "production_claims":
		d.productionClaims(m.(*edgev1.EdgeProductionClaimsV1))
	case "source_claims":
		d.sourceClaims(m.(*edgev1.EdgeSourceClaimsV1))
	case "delivery_claims":
		d.deliveryClaims(m.(*edgev1.EdgeDeliveryClaimsV1))
	case "execution_grant_claims":
		d.executionGrantClaims(m.(*edgev1.EdgeAssignmentExecutionClaimsV1))
	default:
		t.Fatalf("no seam runner for framer %q", framer)
	}

	return append([]byte(nil), d.buf...)
}

// semPerturb changes exactly ONE field to a DIFFERENT value, by descriptor kind. It returns
// false when the field cannot be perturbed, which the caller reports rather than skipping --
// a silently skipped row is a row that proves nothing.
func semPerturb(m proto.Message, name string) bool {
	md := m.ProtoReflect()
	fd := md.Descriptor().Fields().ByName(protoreflect.Name(name))

	if fd == nil {
		return false
	}

	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted kind
	switch fd.Kind() {
	case protoreflect.BytesKind:
		cur := md.Get(fd).Bytes()
		next := append([]byte{0x7E}, cur...)
		md.Set(fd, protoreflect.ValueOfBytes(next))
	case protoreflect.StringKind:
		md.Set(fd, protoreflect.ValueOfString(md.Get(fd).String()+"-perturbed"))
	case protoreflect.Uint64Kind:
		md.Set(fd, protoreflect.ValueOfUint64(md.Get(fd).Uint()+1))
	case protoreflect.Uint32Kind:
		md.Set(fd, protoreflect.ValueOfUint32(uint32(md.Get(fd).Uint())+1))
	case protoreflect.Int64Kind:
		md.Set(fd, protoreflect.ValueOfInt64(md.Get(fd).Int()+1))
	case protoreflect.Int32Kind:
		md.Set(fd, protoreflect.ValueOfInt32(int32(md.Get(fd).Int())+1))
	case protoreflect.EnumKind:
		md.Set(fd, protoreflect.ValueOfEnum(md.Get(fd).Enum()+1))
	case protoreflect.BoolKind:
		md.Set(fd, protoreflect.ValueOfBool(!md.Get(fd).Bool()))
	case protoreflect.MessageKind:
		// A COMPOSITE SLOT is perturbed by changing a scalar INSIDE it. Replacing the whole
		// sub-message would also work but proves less: this way the slot is shown to carry its
		// contents, not merely its presence.
		sub := md.Mutable(fd).Message()
		sfds := sub.Descriptor().Fields()

		for i := range sfds.Len() {
			if sfds.Get(i).Kind() != protoreflect.MessageKind &&
				sfds.Get(i).ContainingOneof() == nil {
				return semPerturb(sub.Interface(), string(sfds.Get(i).Name()))
			}
		}

		return false
	default:
		return false
	}

	return true
}

// semPopulate fills every scalar field with a distinct non-zero value and recurses into message
// fields, so a later perturbation is always observable. A base left at proto defaults would let
// a perturbation collide with the zero value and pass for the wrong reason.
// semRecordVariants is how many record fixtures are committed.
//
// ONE FIXTURE CANNOT SEPARATE THE ROOT TRANSCRIPT, and that is arithmetic rather than an
// oversight. The preimage is a FLAT, UNTAGGED concatenation -- a Go method call writes into the
// same buffer and creates NO boundary, so every u64 write coexists with every other. The record
// carries thirteen enum writes, SEVEN of them with a range of only 0..2, plus constants at 3, 7
// and 8. Seven positions cannot take seven distinct values from three, so with one fixture some
// pair must collide and swapping that pair moves no byte.
//
// TWO FIXTURES SUFFICE because what must be unique is the SIGNATURE -- the tuple of a position's
// values ACROSS the committed fixtures -- and a range of 3 yields 9 signatures over two
// fixtures, which covers the seven. A swap is then undetectable only if the two positions agree
// in EVERY fixture, which the guard forbids.
const semRecordVariants = 3

// semEnumAlloc assigns each enum POSITION a signature no other position holds.
//
// Positions are numbered by the population walk, which is identical across variants because the
// fixture's SHAPE does not depend on its enum values. Allocation is greedy over the admissible
// tuples in lexicographic order, so it is deterministic and reproducible.
type semEnumAlloc struct {
	variants      int
	variant       int
	next          int
	constant      bool
	avoidConstant bool
	tuples        [][]uint64
	used          map[string]bool
}

// newSemEnumAllocShared builds an allocator over a SHARED tuple space.
//
// THE BASELINES AND THE RECORD MUST SHARE IT. A claim baseline is SPLICED into the record to
// build a composed shape, so its writes land in the record's flat transcript -- if the two were
// allocated independently, a record position and a claim position could hold the same value and
// swapping them across that seam would move no byte. Baselines take CONSTANT tuples because they
// are populated once and do not vary by variant; the record's tuples vary, so a constant tuple
// can never equal a varying one, and distinctness within each kind is the allocator's job.
func newSemEnumAllocShared(variants int, used map[string]bool, constant bool) *semEnumAlloc {
	return &semEnumAlloc{variants: variants, used: used, constant: constant}
}

// newSemEnumAlloc builds a standalone allocator for AD-HOC populations -- messages built inside a
// single assertion, never committed as fixtures and never read by the collision guard.
//
// IT RESERVES NOTHING. The committed path reserves the structural constants so no enum can take a
// discriminant's value; doing that here too would starve the space: at one variant every tuple IS
// a constant tuple, and removing 0 and 3 leaves a range-4 field just two choices against three
// range-3-or-4 positions in `production_claims`. These messages make no distinctness claim.
func newSemEnumAlloc(variants int) *semEnumAlloc {
	return &semEnumAlloc{variants: variants, used: map[string]bool{}}
}

func semTupleKey(t []uint64) string {
	parts := make([]string, len(t))
	for i, v := range t {
		parts[i] = strconv.FormatUint(v, 10)
	}

	return strings.Join(parts, ",")
}

func (a *semEnumAlloc) reset(variant int) {
	a.variant = variant
	a.next = 0
}

func (a *semEnumAlloc) pick(vals protoreflect.EnumValueDescriptors, owner string) protoreflect.EnumNumber {
	i := a.next
	a.next++

	if i >= len(a.tuples) {
		tup, ok := a.alloc(vals)
		if !ok {
			panic("semEnumAlloc: no unused signature remains for " + owner + " -- raise " +
				"semRecordVariants, which is what widens the signature space")
		}

		a.tuples = append(a.tuples, tup)
		a.used[semTupleKey(tup)] = true
	}

	return protoreflect.EnumNumber(a.tuples[i][a.variant])
}

// alloc walks the admissible tuples in lexicographic order and returns the first unused one.
func (a *semEnumAlloc) alloc(vals protoreflect.EnumValueDescriptors) ([]uint64, bool) {
	n := vals.Len()
	total := 1

	for range a.variants {
		total *= n
	}

	if a.constant {
		for k := range n {
			tup := make([]uint64, a.variants)
			for i := range tup {
				tup[i] = uint64(vals.Get(k).Number())
			}

			if !a.used[semTupleKey(tup)] {
				return tup, true
			}
		}

		return nil, false
	}

	for c := range total {
		tup := make([]uint64, a.variants)
		rem := c

		for i := a.variants - 1; i >= 0; i-- {
			tup[i] = uint64(vals.Get(rem % n).Number())
			rem /= n
		}

		// THE RECORD LEAVES THE ALL-EQUAL TUPLES ALONE. A baseline is populated ONCE and spliced
		// into every variant, so its effective signature is constant; a record position whose
		// tuple is also constant could equal it. Partitioning the space -- varying tuples for the
		// record, constant ones for the baselines -- makes record/baseline collisions impossible
		// by construction, with no shared bookkeeping between them.
		if a.avoidConstant && semTupleIsConstant(tup) {
			continue
		}

		if !a.used[semTupleKey(tup)] {
			return tup, true
		}
	}

	return nil, false
}

func semTupleIsConstant(t []uint64) bool {
	for _, v := range t {
		if v != t[0] {
			return false
		}
	}

	return true
}

func semPopulate(m proto.Message, seed *uint16) {
	semPopulateTracked(m, seed, map[uint64]bool{}, newSemEnumAlloc(1))
}

func semPopulateTracked(m proto.Message, seed *uint16, used map[uint64]bool, alloc *semEnumAlloc) {
	md := m.ProtoReflect()
	fds := md.Descriptor().Fields()

	nextU64 := func() uint64 {
		for {
			*seed++
			v := uint64(*seed) * 1000

			if !used[v] {
				used[v] = true

				return v
			}
		}
	}

	// ENUMS FIRST, MOST CONSTRAINED FIRST. Greedy field order exhausts the narrow enums: with
	// `kind` [0..7] taking 0, `traffic_class` [0..2] taking 1 and `route_profile` [0..3] taking
	// 2, `origin_kind` [0..2] has nothing left and must repeat a value. Assigning the
	// smallest ranges first finds an assignment that exists -- 3/0/1/2 here -- instead of
	// failing on ordering alone.
	var enums []protoreflect.FieldDescriptor

	for i := range fds.Len() {
		fd := fds.Get(i)
		if fd.Kind() == protoreflect.EnumKind && (fd.ContainingOneof() == nil || fd.ContainingOneof().IsSynthetic()) {
			enums = append(enums, fd)
		}
	}

	sort.SliceStable(enums, func(a, b int) bool {
		return enums[a].Enum().Values().Len() < enums[b].Enum().Values().Len()
	})

	// THE SCOPE IS THE WHOLE FLAT TRANSCRIPT -- there is no smaller one.
	//
	// TWO EARLIER SCOPES WERE WRONG AND EACH LEFT A LIVE SURVIVOR. Per MESSAGE let
	// `execution_grant_claims.traffic_class` and its inlined `source_identity.kind` both take 0.
	// Per FRAMER let the root's `traffic_class` and `producer_context.origin_kind` both take 0 --
	// because a Go method call is NOT a transcript boundary: `producerContext` appends to the
	// same buffer with no length prefix and no hash, so extracting it changed no byte and
	// separated nothing. Only length-framing or hashing child blocks would create a real
	// boundary, and either would change the ABI.
	//
	// So the allocator is GLOBAL over the walk and separates positions by SIGNATURE across the
	// committed fixtures rather than by value within one.

	for _, fd := range enums {
		md.Set(fd, protoreflect.ValueOfEnum(
			alloc.pick(fd.Enum().Values(), string(md.Descriptor().FullName())+"."+string(fd.Name()))))
	}

	for i := range fds.Len() {
		fd := fds.Get(i)
		if fd.ContainingOneof() != nil && !fd.ContainingOneof().IsSynthetic() {
			// A SET oneof member is still populated: the capability's claims MIRROR the record's
			// contract and producer fields, and leaving them equal makes each mirrored pair
			// interchangeable. The manifest already forbids synchronising duplicate occurrences
			// for exactly this reason.
			if fd.Kind() == protoreflect.MessageKind && md.Has(fd) {
				semPopulateTracked(md.Mutable(fd).Message().Interface(), seed, used, alloc)
			}

			continue
		}

		//nolint:exhaustive // fail-closed: the default arm rejects any unlisted kind
		switch fd.Kind() {
		case protoreflect.BytesKind:
			*seed++
			md.Set(fd, protoreflect.ValueOfBytes(semSeedBytes(*seed)))
		case protoreflect.StringKind:
			*seed++
			md.Set(fd, protoreflect.ValueOfString("v"+strconv.Itoa(int(*seed))))
		case protoreflect.Uint64Kind:
			md.Set(fd, protoreflect.ValueOfUint64(nextU64()))
		case protoreflect.Uint32Kind:
			md.Set(fd, protoreflect.ValueOfUint32(uint32(nextU64())))
		case protoreflect.Int64Kind:
			*seed++
			md.Set(fd, protoreflect.ValueOfInt64(int64(*seed)*7_000_000))
		case protoreflect.Int32Kind:
			*seed++
			md.Set(fd, protoreflect.ValueOfInt32(int32(*seed)*11))
		case protoreflect.EnumKind:
			// already assigned above, most-constrained-first
		case protoreflect.MessageKind:
			semPopulateTracked(md.Mutable(fd).Message().Interface(), seed, used, alloc)
		default:
			// Fail closed. A kind with no case here leaves the field at its zero value, and a
			// fixture whose field was never populated proves nothing about that field.
			panic(fmt.Sprintf("semPopulateTracked: no case for kind %v at %s", fd.Kind(), fd.FullName()))
		}
	}
}

// semNavigate walks a dotted path to the message OWNING the leaf, creating sub-messages and
// skipping oneof names (which are not fields). It returns the owner and the leaf name.
func semNavigate(t *testing.T, m proto.Message, path []string) (proto.Message, string) {
	t.Helper()

	cur := m.ProtoReflect()

	for i := 0; i < len(path)-1; i++ {
		seg := protoreflect.Name(path[i])
		if cur.Descriptor().Oneofs().ByName(seg) != nil {
			continue // a oneof name; the next segment names the member field
		}

		fd := cur.Descriptor().Fields().ByName(seg)
		if fd == nil || fd.Kind() != protoreflect.MessageKind {
			t.Fatalf("path segment %q is not a message field on %s", seg, cur.Descriptor().FullName())
		}

		cur = cur.Mutable(fd).Message()
	}

	return cur.Interface(), path[len(path)-1]
}

// TestSemanticFramerOperations discharges every framer-local operation row whose probe is
// `preimage`: perturb exactly one field and require the FRAMED BYTES at the seam to move.
//
// SEAM INEQUALITY IS THE RIGHT DISCRIMINATOR HERE, and only here. Deleting a field's write makes
// the base and the perturbed message frame IDENTICALLY, so inequality catches it exactly. That
// is NOT true of a presence marker -- absent and present differ for unrelated reasons -- which
// is why those rows carry committed vectors instead.
func TestSemanticFramerOperations(t *testing.T) {
	bases := map[string]func() proto.Message{
		"output_contract":        func() proto.Message { return &edgev1.EdgeOutputContractRef{} },
		"collection_claims":      func() proto.Message { return &edgev1.EdgeCollectionClaimsV1{} },
		"production_claims":      func() proto.Message { return &edgev1.EdgeProductionClaimsV1{} },
		"source_claims":          func() proto.Message { return &edgev1.EdgeSourceClaimsV1{} },
		"delivery_claims":        func() proto.Message { return &edgev1.EdgeDeliveryClaimsV1{} },
		"execution_grant_claims": func() proto.Message { return &edgev1.EdgeAssignmentExecutionClaimsV1{} },
	}

	covered, viaDigest, viaState := 0, 0, 0

	for _, r := range semRowsOfKind(t, "op") {
		segs := strings.Split(r.key, ".")
		framer := segs[0]

		// Presence and discriminant rows are alternatives, not field writes: they are
		// discharged by the state set with committed vectors. Counted, never skipped silently.
		// EXPLICIT ROUTING, and the manifest's own probe must agree with it. Either alone is
		// weaker: the map without the probe check lets the manifest relabel a row, and the
		// probe without the map lets a renamed key take a different route unnoticed.
		if want, ok := semStateKeys[r.key]; ok {
			if r.detail != want.detail || r.probe != want.probe {
				t.Fatalf("%s: manifest tuple {%s %s} disagrees with the inventory {%s %s}",
					r.key, r.detail, r.probe, want.detail, want.probe)
			}

			viaState++

			continue
		}

		if want, ok := semDigestKeys[r.key]; ok {
			if r.detail != want.detail || r.probe != want.probe {
				t.Fatalf("%s: manifest tuple {%s %s} disagrees with the inventory {%s %s}",
					r.key, r.detail, r.probe, want.detail, want.probe)
			}

			// THE SCHEMA IS CHECKED HERE TOO. These rows previously bypassed it, so a detail
			// column could drift from the field it names and nothing would notice.
			semAssertDigestRowKind(t, r)

			viaDigest++

			continue
		}

		if r.probe != "preimage" {
			t.Fatalf("%s is routed to the seam but its probe is %q", r.key, r.probe)
		}

		mk, ok := bases[framer]
		if !ok {
			t.Fatalf("%s: no base fixture for framer %q", r.key, framer)
		}

		seed := uint16(0)
		base := mk()
		semPopulate(base, &seed)

		// A oneof member on the path must be set before it can be navigated into.
		if strings.Contains(r.key, ".transition.renewal.") {
			base.(*edgev1.EdgeDeliveryClaimsV1).Transition = &edgev1.EdgeDeliveryClaimsV1_Renewal{
				Renewal: &edgev1.EdgeDeliveryRenewalV1{},
			}
		}

		if strings.Contains(r.key, ".transition.rollover.") {
			base.(*edgev1.EdgeDeliveryClaimsV1).Transition = &edgev1.EdgeDeliveryClaimsV1_Rollover{
				Rollover: &edgev1.EdgeDeliveryRolloverV1{},
			}
		}

		seed = 100
		semPopulate(base, &seed)

		perturbed := proto.Clone(base)
		owner, leaf := semNavigate(t, perturbed, segs[1:])

		semAssertKindMatches(t, r, owner, leaf)

		if !semPerturb(owner, leaf) {
			t.Fatalf("%s: could not perturb leaf %q on %s -- a row that cannot vary its own "+
				"quantity proves nothing", r.key, leaf, owner.ProtoReflect().Descriptor().FullName())
		}

		if bytes.Equal(semFramerOutput(t, framer, base, true), semFramerOutput(t, framer, perturbed, true)) {
			t.Fatalf("%s: perturbing this field did not move the framed bytes -- the write is "+
				"absent from the transcript", r.key)
		}

		covered++
	}

	// THREE BUCKETS, ACCOUNTED SEPARATELY. Collapsing them into "covered + deferred" hid that
	// most of the deferred rows go through the digest entry point rather than the state set,
	// which are different kinds of evidence with different strength.
	t.Logf("framer-local operations: %d at the seam, %d through the digest entry point, %d state cases",
		covered, viaDigest, viaState)

	if covered != 89 || viaDigest != 22 || viaState != 14 {
		t.Fatalf("bucket sizes drifted: seam=%d digest=%d state=%d (want 89/22/14)", covered, viaDigest, viaState)
	}

	if covered+viaDigest+viaState != 125 {
		t.Fatalf("accounted for %d operation rows, the inventory names 125", covered+viaDigest+viaState)
	}
}

type semRoute struct{ detail, probe string }

// semStateKeys pins the EXACT tuple, not just the key. Accepting either `preimage` or `committed` would let capability.presence be relabelled to
// the weaker probe and still pass, which is precisely the marker whose inequality is vacuous.
//
//nolint:gochecknoglobals // immutable declared axis
var semStateKeys = map[string]semRoute{
	"output_contract.presence":                         {detail: "present", probe: "preimage"},
	"claims_framed.discriminant_7":                     {detail: "u64", probe: "preimage"},
	"claims_framed.discriminant_8":                     {detail: "u64", probe: "preimage"},
	"claims_framed.discriminant_9":                     {detail: "u64", probe: "preimage"},
	"claims_framed.discriminant_11":                    {detail: "u64", probe: "preimage"},
	"claims_framed.discriminant_12":                    {detail: "u64", probe: "preimage"},
	"claims_framed.discriminant_unset":                 {detail: "u64", probe: "preimage"},
	"delivery_claims.transition.discriminant_renewal":  {detail: "u64", probe: "preimage"},
	"delivery_claims.transition.discriminant_rollover": {detail: "u64", probe: "preimage"},
	"delivery_claims.transition.discriminant_unset":    {detail: "u64", probe: "preimage"},
	"execution_grant_claims.source_identity.presence":  {detail: "present", probe: "preimage"},
	"capability.presence":                              {detail: "present", probe: "committed"},
	"source_auth.presence":                             {detail: "present", probe: "committed"},
	"producer_context.presence":                        {detail: "present", probe: "committed"},
}

// semDigestKeys pins the EXACT tuple, not just the key. These rows bypassed the descriptor kind check entirely, so capability.algorithm could be
// relabelled str -> bytes and survive; the tuple and the schema are both checked now.
//
//nolint:gochecknoglobals // immutable declared axis
var semDigestKeys = map[string]semRoute{
	"capability.capability_version":           {detail: "u64", probe: "digest"},
	"capability.issuer_id":                    {detail: "bytes", probe: "digest"},
	"capability.issuer_key_id":                {detail: "bytes", probe: "digest"},
	"capability.algorithm":                    {detail: "str", probe: "digest"},
	"capability.not_before_unix_nano":         {detail: "i64", probe: "digest"},
	"capability.expires_at_unix_nano":         {detail: "i64", probe: "digest"},
	"capability.signature":                    {detail: "bytes", probe: "digest"},
	"source_auth.kind":                        {detail: "u64", probe: "digest"},
	"source_auth.context_id":                  {detail: "bytes", probe: "digest"},
	"source_auth.scope_id":                    {detail: "bytes", probe: "digest"},
	"source_auth.scope_sha256":                {detail: "bytes", probe: "digest"},
	"producer_context.origin_kind":            {detail: "u64", probe: "digest"},
	"producer_context.origin_principal_id":    {detail: "bytes", probe: "digest"},
	"producer_context.producer_instance_id":   {detail: "bytes", probe: "digest"},
	"producer_context.producer_assignment_id": {detail: "bytes", probe: "digest"},
	"producer_context.run_id":                 {detail: "bytes", probe: "digest"},
	"producer_context.run_shard":              {detail: "u64", probe: "digest"},
	"producer_context.authority_epoch":        {detail: "optU64", probe: "digest"},
	"producer_context.scope_id":               {detail: "bytes", probe: "digest"},
	"producer_context.scope_sha256":           {detail: "bytes", probe: "digest"},
	"producer_context.package_id":             {detail: "str", probe: "digest"},
	"producer_context.package_sha256":         {detail: "bytes", probe: "digest"},
}

// semKindForField maps a descriptor kind to the transcript write the framer uses for it, so a
// manifest `detail` column that drifts from the schema fails instead of sitting unread.
func semKindForField(t *testing.T, fd protoreflect.FieldDescriptor) string {
	t.Helper()

	// PROTO3 OPTIONAL IS ITS OWN WRITE. `authority_epoch` frames a presence marker AND a value,
	// which is a different transcript shape from a bare u64 -- and it is the ONLY such site.
	// Collapsing it into u64 would let the marker be deleted with the manifest still agreeing.
	if fd.HasOptionalKeyword() {
		if fd.Kind() != protoreflect.Uint64Kind {
			t.Fatalf("%s is proto3-optional of kind %s; the transcript has no framing decision "+
				"for that yet", fd.FullName(), fd.Kind())
		}

		return "optU64"
	}

	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted kind
	switch fd.Kind() {
	case protoreflect.BytesKind:
		return "bytes"
	case protoreflect.StringKind:
		return "str"
	case protoreflect.Int64Kind, protoreflect.Int32Kind:
		return "i64"
	case protoreflect.Uint64Kind, protoreflect.Uint32Kind, protoreflect.EnumKind:
		// BOOL AND INT32 ARE DELIBERATELY ABSENT. Neither appears in any of the nine grammar
		// roots today, and Appendix A defines no encoding for them. Pre-authorising them here
		// would silently assign a shape to the first one that arrives -- the same defect as a
		// blanket u64 default, only narrower.
		return "u64"
	default:
		// NOT a default-to-u64. A kind this grammar has never framed is an OPEN QUESTION, and
		// answering it silently is how a new field type gets committed under the wrong shape.
		t.Fatalf("%s has kind %s, for which this transcript has no framing decision -- the "+
			"grammar must choose one before a row can claim to cover it", fd.FullName(), fd.Kind())

		return ""
	}
}

func semAssertKindMatches(t *testing.T, r semRow, owner proto.Message, leaf string) {
	t.Helper()

	fd := owner.ProtoReflect().Descriptor().Fields().ByName(protoreflect.Name(leaf))
	if fd == nil {
		t.Fatalf("%s: leaf %q is not a field on %s -- the manifest names a quantity the schema "+
			"does not have", r.key, leaf, owner.ProtoReflect().Descriptor().FullName())
	}

	if want := semKindForField(t, fd); r.detail != want {
		t.Fatalf("%s: manifest says the write kind is %q, the schema says %q", r.key, r.detail, want)
	}
}

// semAssertDigestRowKind resolves a digest-routed row against the schema of the message that
// owns it, so those rows are held to the same standard as the seam rows.
func semAssertDigestRowKind(t *testing.T, r semRow) {
	t.Helper()

	owners := map[string]proto.Message{
		"capability":       &edgev1.EdgeSignedCapabilityV1{},
		"source_auth":      &edgev1.EdgeSourceAuthorizationV1{},
		"producer_context": &edgev1.EdgeProducerContext{},
	}

	segs := strings.Split(r.key, ".")

	owner, ok := owners[segs[0]]
	if !ok {
		t.Fatalf("%s: no owning message registered for digest-routed framer %q", r.key, segs[0])
	}

	semAssertKindMatches(t, r, owner, segs[len(segs)-1])
}

// ---------------------------------------------------------------------------
// nested closure: the descriptor graph defines the paths, the manifest classifies them
// ---------------------------------------------------------------------------

// semGrammarRoots are the nine grammar messages, named INDEPENDENTLY of the manifest. The walk
// below discovers their scalar leaves from the DESCRIPTOR; the manifest then has to classify
// what was discovered. Deriving the expected paths from the manifest instead would make the
// closure agree with itself: a nested field added with no row would be absent from both sides.
//
//nolint:gochecknoglobals // immutable declared axis
var semGrammarRoots = map[string]func() proto.Message{
	"output_contract":        func() proto.Message { return &edgev1.EdgeOutputContractRef{} },
	"collection_claims":      func() proto.Message { return &edgev1.EdgeCollectionClaimsV1{} },
	"production_claims":      func() proto.Message { return &edgev1.EdgeProductionClaimsV1{} },
	"source_claims":          func() proto.Message { return &edgev1.EdgeSourceClaimsV1{} },
	"delivery_claims":        func() proto.Message { return &edgev1.EdgeDeliveryClaimsV1{} },
	"execution_grant_claims": func() proto.Message { return &edgev1.EdgeAssignmentExecutionClaimsV1{} },
	"capability":             func() proto.Message { return &edgev1.EdgeSignedCapabilityV1{} },
	"source_auth":            func() proto.Message { return &edgev1.EdgeSourceAuthorizationV1{} },
	"producer_context":       func() proto.Message { return &edgev1.EdgeProducerContext{} },
}

// semWalkLeaves discovers scalar leaf paths under one grammar root. Message-valued children are
// either INLINED (their leaves belong to this root's transcript) or handed to another root as a
// COMPOSITION EDGE -- never both, and never silently dropped.
func semWalkLeaves(t *testing.T, root string, md protoreflect.MessageDescriptor, prefix string, out map[string]string, edges map[string]bool) {
	t.Helper()

	fds := md.Fields()

	for i := range fds.Len() {
		fd := fds.Get(i)
		name := string(fd.Name())
		path := prefix + name

		// The capability's `claims` oneof is NOT recursed into from `capability`: its members
		// are framed by claims_framed, which is its own root. Recursing here would mint
		// capability.production.* paths that no framer ever writes.
		//
		// THE EXCEPTION NAMES THAT ONE ONEOF. Skipping every field with a containing oneof
		// swallowed anything that might later join the message: a SECOND oneof, or a
		// proto3-`optional` field -- whose synthetic oneof would have matched too -- would have
		// vanished into this existing edge without ever acquiring an operation row, classified
		// by nothing and framed by no one.
		//nolint:goconst // a corpus manifest token; the table is read against the committed file
		if root == "capability" && semIsClaimsOneofField(fd) {
			edges[root+"->claims_framed"] = true

			continue
		}

		// source_auth's nested capability is a COMPOSITION EDGE, not inlined leaves.
		if root == "source_auth" && fd.Kind() == protoreflect.MessageKind &&
			fd.Message().FullName() == (&edgev1.EdgeSignedCapabilityV1{}).ProtoReflect().Descriptor().FullName() {
			edges["source_authorization->capability"] = true

			continue
		}

		if fd.Kind() == protoreflect.MessageKind {
			// Delivery transition members and the execution grant's source identity ARE
			// inlined: the framer writes their leaves directly into this transcript.
			if oo := fd.ContainingOneof(); oo != nil && !oo.IsSynthetic() {
				// THE ONEOF NAME IS PART OF THE PATH. A member's field name alone
				// (`renewal.x`) hides which branch it belongs to, and two oneofs could name
				// the same member; the manifest keys carry the oneof, so the walk must too.
				edges[root+"->"+string(oo.Name())] = true
				semWalkLeaves(t, root, fd.Message(), prefix+string(oo.Name())+"."+name+".", out, edges)

				continue
			}

			edges[root+"->"+name] = true
			semWalkLeaves(t, root, fd.Message(), path+".", out, edges)

			continue
		}

		// A oneof member that is NOT a message is still a branch, and the grammar has made no
		// framing decision for one; fail rather than treat it as an ordinary scalar.
		if fd.ContainingOneof() != nil && !fd.ContainingOneof().IsSynthetic() && fd.Kind() != protoreflect.MessageKind {
			t.Fatalf("%s: %s is a scalar oneof member; the transcript has no framing decision for that", root, path)
		}

		out[root+"."+path] = semKindForField(t, fd)
	}
}

// semDescriptorEdges derives the composition edges the nested walk cannot see, and returns the
// claims oneof's {field number -> child root} map.
//
// THE WALK ALONE DISCOVERS FOUR OF THIRTEEN. The record's own composite slots and the five
// claims members were declared in the manifest and derived from nothing, so the comparison ran
// in one direction over a third of the graph: deleting a declaration was indistinguishable from
// deleting a carrier, and neither side could contradict the other.
func semDescriptorEdges(t *testing.T, edges map[string]bool) map[int]string {
	t.Helper()

	// A ROOT SLOT THAT CARRIES A MESSAGE IS AN EDGE, read off EdgeRecordV1 rather than listed.
	rf := (&edgev1.EdgeRecordV1{}).ProtoReflect().Descriptor().Fields()
	for i := range rf.Len() {
		if f := rf.Get(i); f.Kind() == protoreflect.MessageKind {
			edges["root->"+string(f.Name())] = true
		}
	}

	byName := map[protoreflect.FullName]string{}
	for root, mk := range semGrammarRoots {
		byName[mk().ProtoReflect().Descriptor().FullName()] = root
	}

	oo := (&edgev1.EdgeSignedCapabilityV1{}).ProtoReflect().Descriptor().Oneofs().ByName("claims")
	if oo == nil {
		t.Fatal("EdgeSignedCapabilityV1 declares no `claims` oneof; the claims edges are underivable")
	}

	nums := map[int]string{}

	for i := range oo.Fields().Len() {
		f := oo.Fields().Get(i)

		if f.Kind() != protoreflect.MessageKind {
			t.Fatalf("claims member %s carries no message, so it reaches no child framer", f.Name())
		}

		root, ok := byName[f.Message().FullName()]
		if !ok {
			t.Fatalf("claims member %s carries %s, which is not a declared grammar root -- a new "+
				"variant is unframed until one names it", f.Name(), f.Message().FullName())
		}

		edges["claims_framed->"+root] = true
		nums[int(f.Number())] = root
	}

	return nums
}

// TestSemanticNestedClosure is bidirectional over the DISCOVERED graph: every scalar leaf the
// descriptors define must be classified by the manifest, and every manifest operation must
// name a leaf that exists or be one of the fourteen synthetic ones.
func TestSemanticNestedClosure(t *testing.T) {
	discovered := map[string]string{}
	edges := map[string]bool{}

	for root, mk := range semGrammarRoots {
		semWalkLeaves(t, root, mk().ProtoReflect().Descriptor(), "", discovered, edges)
	}

	if len(discovered) != 111 {
		t.Fatalf("the descriptor graph yields %d scalar leaves, the inventory names 111: %v",
			len(discovered), semanticSortedKeys(func() map[string]bool {
				m := map[string]bool{}
				for k := range discovered {
					m[k] = true
				}

				return m
			}()))
	}

	manifest := map[string]string{}
	synthetic := 0

	for _, r := range semRowsOfKind(t, "op") {
		if strings.Contains(r.key, "presence") || strings.Contains(r.key, "discriminant") {
			synthetic++

			continue
		}

		manifest[r.key] = r.detail
	}

	if synthetic != 14 {
		t.Fatalf("the manifest carries %d synthetic operations, the inventory names 14", synthetic)
	}

	for path, kind := range discovered {
		got, ok := manifest[path]
		if !ok {
			t.Fatalf("the descriptor graph defines %s and the manifest classifies it nowhere -- "+
				"a nested field is uncommitted until a row names it", path)
		}

		if got != kind {
			t.Fatalf("%s: manifest says %q, the descriptor says %q", path, got, kind)
		}
	}

	for path := range manifest {
		if _, ok := discovered[path]; !ok {
			t.Fatalf("the manifest names %s, which the descriptor graph does not define", path)
		}
	}

	// THE DISCOVERED EDGE SET IS CONSUMED HERE TOO, not computed and dropped. Every composition
	// edge the descriptors imply must be declared, or a carrier could vanish from the schema
	// with the manifest and both consumers still agreeing with each other.
	declaredEdges := map[string]bool{}
	for _, r := range semRowsOfKind(t, "edge") {
		declaredEdges[r.key] = true

		if r.detail != "occurrence" || r.probe != "attach" {
			t.Fatalf("edge %s: manifest tuple {%s %s} disagrees with the bound {occurrence attach}",
				r.key, r.detail, r.probe)
		}
	}

	claimNums := semDescriptorEdges(t, edges)

	// THE ONEOF NUMBERS ARE THE TRANSCRIPT'S DISCRIMINANT VALUES, so pinning the member set is
	// not enough: renumbering two members swaps what every framed claim is labelled as while the
	// set, the count and the child framers all stay identical.
	wantNums := map[int]string{
		7:  "production_claims",
		8:  "source_claims",
		9:  "delivery_claims",
		11: "collection_claims",
		12: "execution_grant_claims",
	}

	if !reflect.DeepEqual(claimNums, wantNums) {
		t.Fatalf("claims discriminants moved.\n  descriptor %v\n  bound      %v", claimNums, wantNums)
	}

	for e := range edges {
		if !declaredEdges[e] {
			t.Fatalf("the descriptor graph implies composition edge %s, which the manifest omits", e)
		}
	}

	// AND THE OTHER DIRECTION, which is new: a manifest edge naming a carrier the schema does
	// not have is a row that can never fail.
	for e := range declaredEdges {
		if !edges[e] {
			t.Fatalf("the manifest declares composition edge %s, which the descriptor graph does "+
				"not imply", e)
		}
	}

	if len(edges) != 13 {
		t.Fatalf("the descriptor graph implies %d composition edges, the inventory names 13: %v",
			len(edges), semanticSortedKeys(edges))
	}

	// THE SEPARATION SET IS BOUND TOO. Its rows were counted but never tied to evidence, so
	// renaming them wholesale preserved cardinality and passed.
	semAssertKeyedTuples(t, "sep", map[string][2]string{
		"producer_receipt.submission_sha256":               {"schema-absent", "closure"},
		"physical_artifact.record_sha256.legal_reencoding": {"reencode", "invariant"},
		"delivery_frame.spool_id":                          {"outer-frame", "invariant"},
		"delivery_frame.sequence":                          {"outer-frame", "invariant"},
		"delivery_frame.delivery_capability":               {"outer-frame", "invariant"},
	})
}

// ---------------------------------------------------------------------------
// committed vectors: frozen expected outputs, never recomputed at assert time
// ---------------------------------------------------------------------------

// semVectors reads the committed vector file. The values are FROZEN ARTIFACTS: recomputing them
// with the live framer would compare the grammar against itself, so any drift would move both
// sides together and the assertion would hold while the ABI moved.
// semVectorReads records which committed keys were ACTUALLY read.
//
// A NAMED INVENTORY IS NOT AN OBSERVED ONE. The first version of the key-set guard listed the
// keys this runtime "consumes" and compared that list to the file -- which passes whether or not
// any test reads them. Measured: restricting the root witness to variant 0 changed nothing,
// because the list still named every variant. Reads are now recorded at the accessor and checked
// after the whole package has run, so a vector nothing asserts fails.
//
//nolint:gochecknoglobals // suite-scoped read ledger; the after-suite guard reads it once
var semVectorReads = map[string]bool{}

// semVectorFor reads one committed vector and records the read.
func semVectorFor(t *testing.T, key string) (string, bool) {
	t.Helper()

	v, ok := semVectors(t)[key]
	if ok {
		semVectorReads[key] = true
	}

	return v, ok
}

func semVectors(t *testing.T) map[string]string {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	b, err := os.ReadFile(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1", "testdata", "semantic_envelope_vectors.txt"))
	if err != nil {
		t.Fatalf("open semantic vectors: %v", err)
	}

	out := map[string]string{}

	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		f := strings.Fields(line)
		if len(f) != 2 {
			t.Fatalf("vector row %q must be `key hex`", line)
		}

		if _, dup := out[f[0]]; dup {
			t.Fatalf("vector %s appears twice", f[0])
		}

		out[f[0]] = f[1]
	}

	return out
}

// semBaseline loads the COMMITTED populated baseline for a grammar root.
//
// IT IS READ, NOT BUILT. A vector comparison is only cross-runtime evidence if both runtimes
// frame THE SAME INPUT; a baseline constructed independently on each side would compare two
// different messages and agree only by luck. The artifacts were generated once from the
// discriminating populator and committed alongside the vectors.
func semBaseline(t *testing.T, root string) proto.Message {
	t.Helper()

	return semBaselineFrom(t, root, "production", 0)
}

// semBaselineFrom reads one committed baseline for one CARRIER.
//
// TWO SETS EXIST because the cross product puts a claim body in BOTH carriers at once. Splicing
// the same artifact into both made every corresponding field pair hold the same value, and no
// fixture could then detect their exchange.
func semBaselineFrom(t *testing.T, root, carrier string, variant int) proto.Message {
	t.Helper()

	mk, ok := semGrammarRoots[root]
	if !ok {
		t.Fatalf("no grammar root %q", root)
	}

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	b, err := os.ReadFile(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1",
		"testdata", semBaselineArtifact(root, carrier, variant)))
	if err != nil {
		t.Fatalf("read committed %s baseline for %s: %v", carrier, root, err)
	}

	m := mk()
	if err := proto.Unmarshal(b, m); err != nil {
		t.Fatalf("decode committed %s baseline for %s: %v", carrier, root, err)
	}

	return m
}

func semBaselineArtifact(root, carrier string, variant int) string {
	name := "sem_" + root + "_populated"
	//nolint:goconst // a corpus manifest token; the table is read against the committed file
	if carrier != "production" {
		name += "_nested"
	}

	if variant > 0 {
		name += fmt.Sprintf("_v%d", variant)
	}

	return name + ".bin"
}

// TestSemanticCommittedVectors freezes the EXACT framed bytes for each seam-reachable framer in
// two states: fully populated, and empty/default.
//
// BOTH STATES ARE REQUIRED. A populated baseline pins field ORDER and WIDTH but says nothing
// about CONDITIONAL OMISSION -- a framer that skipped zero-valued fields would frame the
// populated case identically and only diverge on defaults, which is exactly where a
// cross-runtime disagreement would hide.
func TestSemanticCommittedVectors(t *testing.T) {
	for _, root := range []string{"output_contract", "collection_claims", "production_claims",
		"source_claims", "delivery_claims", "execution_grant_claims"} {
		for _, state := range []string{"populated", "default"} {
			key := "framer." + root + "." + state

			want, ok := semVectorFor(t, key)
			if !ok {
				t.Fatalf("no committed vector for %s", key)
			}

			var m proto.Message
			if state == "populated" {
				m = semBaseline(t, root)
			} else {
				m = semGrammarRoots[root]()
			}

			got := hex.EncodeToString(semFramerOutput(t, root, m, true))
			if got != want {
				t.Fatalf("%s: framed bytes moved.\n  committed %s\n  computed  %s", key, want, got)
			}
		}
	}
}

// TestSemanticRootDefaultVectors covers the PRIVATE and ROOT paths that the seam vectors above
// cannot reach: capability, source_auth, producer_context and the record's own writes.
//
// CONDITIONAL OMISSION HIDES HERE. A framer that skipped an empty field would frame the
// POPULATED record identically to a conforming one and diverge only when the field is at its
// default -- measured: omitting an empty capability field passed every other row in this file.
// These vectors are the present-but-default evidence that closes it.
func TestSemanticRootDefaultVectors(t *testing.T) {
	for _, c := range []struct {
		key   string
		build func(*edgev1.EdgeRecordV1)
	}{
		{"root.capability.defaulted", func(r *edgev1.EdgeRecordV1) {
			r.ProductionCapability = &edgev1.EdgeSignedCapabilityV1{}
		}},
		{"root.source_auth.defaulted", func(r *edgev1.EdgeRecordV1) {
			r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{}
		}},
		{"root.producer_context.defaulted", func(r *edgev1.EdgeRecordV1) {
			r.ProducerContext = &edgev1.EdgeProducerContext{}
		}},
		{"root.transition.defaulted", func(r *edgev1.EdgeRecordV1) {
			// A PRESENT-BUT-DEFAULT transition body. Without it a framer that omitted the
			// renewal's zero timestamps would frame the populated case identically.
			r.GetSourceAuthorization().GetCapability().Claims =
				&edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
					Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{
						Renewal: &edgev1.EdgeDeliveryRenewalV1{},
					},
				}}
		}},
		{"root.source_identity.defaulted", func(r *edgev1.EdgeRecordV1) {
			// PRESENT AND DEFAULT, not absent: the absent case is a state row, and only this
			// one exercises the marker followed by defaulted members.
			r.GetSourceAuthorization().GetCapability().Claims =
				&edgev1.EdgeSignedCapabilityV1_AssignmentExecution{
					AssignmentExecution: &edgev1.EdgeAssignmentExecutionClaimsV1{
						SourceIdentity: &edgev1.EdgeSourceSpanIdentityV1{},
					},
				}
		}},
		{"root.scalars.defaulted", func(r *edgev1.EdgeRecordV1) {
			// EVERY same-width root position, ENUMS INCLUDED. Leaving the four enums non-default
			// meant a framer that omitted a zero route-profile write was undetectable: the
			// defaulted vector never exercised the zero.
			r.EventId, r.NetworkScopeId, r.PayloadSha256 = nil, nil, nil
			r.EncodedSize, r.UncompressedSize = 0, 0
			r.ProjectedRowCount, r.ProjectedWriteBytes, r.CostModelVersion = 0, 0, 0
			r.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED
			r.Compression = edgev1.EdgeRecordCompression_EDGE_RECORD_COMPRESSION_UNSPECIFIED
			r.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_UNSPECIFIED
			r.TrafficClass = edgev1.EdgeRecordTrafficClass_EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED
		}},
	} {
		want, ok := semVectorFor(t, c.key)
		if !ok {
			t.Fatalf("no committed vector for %s", c.key)
		}

		r := semDeterministicRecord(t)
		c.build(r)

		if got := hex.EncodeToString(SemanticEnvelopeDigest(r)); got != want {
			t.Fatalf("%s: digest moved.\n  committed %s\n  computed  %s", c.key, want, got)
		}
	}
}

// TestSemanticRecordFixtureMatchesCommittedBytes binds the Go fixture to the SHARED artifact the
// Elixir peer decodes. Without it the two runtimes could drift onto different records while both
// suites stayed green -- the vectors would still agree with whatever each side happened to build.
func TestSemanticRecordFixtureMatchesCommittedBytes(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	// THE BASELINES ARE BOUND TOO, not just the records.
	//
	// `semGenerate` filled both baseline maps and NOTHING CONSUMED THEM: every semantic test read
	// the committed artifacts instead, so mutating the generator left the whole suite green and
	// the artifacts were "correct" only by the accident of having been generated by the code that
	// no longer had to agree with them.
	gen := semGenerate(t)

	for _, set := range []struct {
		carrier string
		msgs    map[string][]proto.Message
	}{{"production", gen.baselines}, {"nested", gen.nested}} {
		for root, msgs := range set.msgs {
			for v, want := range msgs {
				got := semBaselineFrom(t, root, set.carrier, v)
				if !proto.Equal(got, want) {
					t.Fatalf("committed %s baseline %s v%d has drifted from the generator; the "+
						"peer decodes the artifact, so the two must be the same message",
						set.carrier, root, v)
				}
			}
		}
	}

	// EVERY committed record variant, not just the first: the peer decodes each of them, and a
	// variant whose artifact drifted from this runtime's fixture would compare a different record
	// while still agreeing with itself.
	for v := range semRecordVariants {
		committed, err := os.ReadFile(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1",
			"testdata", semRecordArtifact(v)))
		if err != nil {
			t.Fatalf("read committed record variant %d: %v", v, err)
		}

		var decoded edgev1.EdgeRecordV1
		if err := proto.Unmarshal(committed, &decoded); err != nil {
			t.Fatalf("decode committed record variant %d: %v", v, err)
		}

		if !proto.Equal(&decoded, semDeterministicRecordVariant(t, v)) {
			t.Fatalf("committed record variant %d and this runtime's fixture have diverged; the "+
				"Elixir peer decodes the artifact, so they must be the same record", v)
		}
	}
}

// semRecordArtifact names a committed record variant. Variant 0 keeps the original filename so
// the peer's existing reference and the version corpus do not move.
func semRecordArtifact(variant int) string {
	if variant == 0 {
		return "sem_record_deterministic.bin"
	}

	return fmt.Sprintf("sem_record_deterministic_v%d.bin", variant)
}

// ---------------------------------------------------------------------------
// digest-routed operations, root slots, states and composition edges
// ---------------------------------------------------------------------------

// semRecordOwner resolves a digest-routed key to the message inside a live record that owns it,
// so the mutation travels through the PUBLIC digest entry point rather than a framer call.
func semRecordOwner(t *testing.T, r *edgev1.EdgeRecordV1, framer string) proto.Message {
	t.Helper()

	switch framer {
	case "capability":
		return r.GetProductionCapability()
	case "source_auth":
		return r.GetSourceAuthorization()
	case "producer_context":
		return r.GetProducerContext()
	default:
		t.Fatalf("no record owner for digest-routed framer %q", framer)

		return nil
	}
}

// TestSemanticDigestRoutedOperations discharges the 22 rows whose framers are not seam-runnable
// from this suite. Each mutates ONE field and requires the envelope digest to move.
//
// NOTHING IS RESEALED OR REVALIDATED. Synchronising a duplicate occurrence -- network_scope_id
// lives in the record AND in production claims -- would let a DELETED write be masked by the
// other copy still moving. These records are intentionally admission-invalid.
func TestSemanticDigestRoutedOperations(t *testing.T) {
	covered := 0

	for _, r := range semRowsOfKind(t, "op") {
		want, ok := semDigestKeys[r.key]
		if !ok {
			continue
		}

		segs := strings.Split(r.key, ".")

		rec := validRecordForSemantics(t)
		base := SemanticEnvelopeDigest(rec)

		owner := semRecordOwner(t, rec, segs[0])
		leaf := segs[len(segs)-1]

		if want.detail == "optU64" {
			// The optional site is exercised by its own three-artifact row; here it only has
			// to be attached at all.
			p := owner.(*edgev1.EdgeProducerContext)
			p.AuthorityEpoch = proto.Uint64(p.GetAuthorityEpoch() + 1)
		} else if !semPerturb(owner, leaf) {
			t.Fatalf("%s: could not perturb %q on the live record", r.key, leaf)
		}

		if bytes.Equal(SemanticEnvelopeDigest(rec), base) {
			t.Fatalf("%s: perturbing this field did not move the envelope digest -- the write is "+
				"absent from the transcript", r.key)
		}

		covered++
	}

	if covered != 22 {
		t.Fatalf("discharged %d digest-routed rows, the inventory names 22", covered)
	}
}

// validRecordForSemantics is a record with every grammar slot occupied, so no row is discharged
// against an absent sub-message.
func validRecordForSemantics(t *testing.T) *edgev1.EdgeRecordV1 {
	t.Helper()

	r := validRecord(t)
	if r.GetSourceAuthorization() == nil {
		r.SourceAuthorization = &edgev1.EdgeSourceAuthorizationV1{
			Kind:        edgev1.EdgeSourceAuthorizationKind_EDGE_SOURCE_AUTHORIZATION_KIND_AD_HOC,
			ContextId:   mustUUID(t),
			ScopeId:     mustUUID(t),
			ScopeSha256: d32(0x31),
			// THE NESTED CAPABILITY IS POPULATED, or the source_authorization->capability edge
			// has nothing to remove and would pass by having never been exercised.
			Capability: &edgev1.EdgeSignedCapabilityV1{
				CapabilityVersion: 1,
				IssuerId:          bytes.Repeat([]byte{0x41}, 16),
				IssuerKeyId:       bytes.Repeat([]byte{0x42}, 16),
				Algorithm:         "ed25519",
				NotBeforeUnixNano: 1_700_000_000_000_000_000,
				ExpiresAtUnixNano: 1_800_000_000_000_000_000,
				Signature:         bytes.Repeat([]byte{0x43}, 64),
				Claims: &edgev1.EdgeSignedCapabilityV1_Source{
					Source: &edgev1.EdgeSourceClaimsV1{},
				},
			},
		}
	}

	return r
}

// TestSemanticRootSlots proves each of the 16 record slots is attached. `version` is REUSED
// EVIDENCE from the version corpus -- only Go can parameterise the grammar version, so no row
// here re-proves it.
func TestSemanticRootSlots(t *testing.T) {
	// THE detail COLUMN IS ANSWERABLE TO THE DESCRIPTOR, not to a hand-copied list. `direct` vs
	// `composite` is exactly "does this field carry a message", so deriving it is what makes a
	// relabelling fail: retyping `01.event_id` as composite passed unread before, because the
	// column was counted and never compared to anything.
	class := map[string]string{}

	rf := (&edgev1.EdgeRecordV1{}).ProtoReflect().Descriptor().Fields()
	for i := range rf.Len() {
		f := rf.Get(i)

		kind := "direct"
		if f.Kind() == protoreflect.MessageKind {
			kind = "composite"
		}

		class[fmt.Sprintf("%02d.%s", f.Number(), f.Name())] = kind
	}

	attached, reused := 0, 0

	for _, row := range semRowsOfKind(t, "slot") {
		if row.key == "version" {
			if row.probe != "reuse" || row.detail != "version_corpus.semantic_envelope" {
				t.Fatalf("the version slot must be recorded as reuse of the version corpus, got %s/%s",
					row.detail, row.probe)
			}

			reused++

			continue
		}

		want, ok := class[row.key]
		if !ok {
			t.Fatalf("slot %s names no record field {number, name} pair in the descriptor", row.key)
		}

		if row.detail != want || row.probe != "attach" {
			t.Fatalf("slot %s: manifest tuple {%s %s} disagrees with the descriptor-derived {%s attach}",
				row.key, row.detail, row.probe, want)
		}

		name := strings.SplitN(row.key, ".", 2)[1]

		rec := validRecordForSemantics(t)
		base := SemanticEnvelopeDigest(rec)

		if !semPerturb(rec, name) {
			t.Fatalf("%s: could not perturb record field %q", row.key, name)
		}

		if bytes.Equal(SemanticEnvelopeDigest(rec), base) {
			t.Fatalf("%s: perturbing this record field did not move the digest", row.key)
		}

		attached++
	}

	if attached != 16 || reused != 1 {
		t.Fatalf("slots: %d attached and %d reused, want 16 and 1", attached, reused)
	}
}

// TestSemanticStateCases discharges the eight alternatives against COMMITTED values.
//
// INEQUALITY IS VACUOUS HERE and that is the whole reason these rows exist separately. Absent
// and present already frame differently for unrelated reasons -- a missing sub-message writes
// no fields either way -- so "absent != present" survives DELETING the presence marker. Only a
// frozen expected value discriminates it.
func TestSemanticStateCases(t *testing.T) {
	seen := map[string]bool{}

	check := func(key string, got []byte) {
		want, ok := semVectorFor(t, key)
		if !ok {
			t.Fatalf("no committed vector for state %s", key)
		}

		if h := hex.EncodeToString(got); h != want {
			t.Fatalf("%s: framed bytes moved.\n  committed %s\n  computed  %s", key, want, h)
		}

		seen[key] = true
	}

	// PRESENCE, at a seam. output_contract carries presence explicitly, so absence is passed
	// rather than inferred from a typed nil.
	check("state.output_contract.absent", semFramerOutput(t, "output_contract", (*edgev1.EdgeOutputContractRef)(nil), false))
	check("state.output_contract.present", semFramerOutput(t, "output_contract", semBaseline(t, "output_contract"), true))

	// The execution grant's source identity is inlined, so its two states are framed through
	// its owning claims message.
	withID := semBaseline(t, "execution_grant_claims").(*edgev1.EdgeAssignmentExecutionClaimsV1)
	noID := proto.Clone(withID).(*edgev1.EdgeAssignmentExecutionClaimsV1)
	noID.SourceIdentity = nil

	check("state.execution_source_identity.absent", semFramerOutput(t, "execution_grant_claims", noID, true))
	check("state.execution_source_identity.present", semFramerOutput(t, "execution_grant_claims", withID, true))

	// DISCRIMINANTS: the exact frozen values, not merely "different". Changing a variant also
	// changes the branch BODY, so inequality would pass even if the discriminant were dropped.
	for _, v := range []string{"production", "source", "delivery", "collection", "assignment_execution", "unset"} {
		check("state.claims_discriminant."+v, semClaimsFramed(t, v))
	}

	for _, v := range []string{"renewal", "rollover", "unset"} {
		check("state.delivery_transition."+v, semDeliveryTransition(t, v))
	}

	// RENEWAL AND ROLLOVER GET POPULATED VECTORS OF THEIR OWN. The three above carry EMPTY
	// bodies, so within each branch the members are all default and mutually indistinguishable:
	// swapping a renewal's two timestamps, or two of a rollover's byte members, moves nothing.
	// A populated body per branch is what separates those positions.
	check("state.delivery_transition.renewal.populated", semTransitionPopulated(t, "renewal"))
	check("state.delivery_transition.rollover.populated", semTransitionPopulated(t, "rollover"))

	// The three record-level presence markers are committed as whole-envelope digests, since
	// their framers are not seam-runnable from this suite.
	for _, slot := range []string{"producer_context", "capability", "source_authorization"} {
		for _, state := range []string{"absent", "present"} {
			check("state."+slot+"."+state, semRecordDigestWith(t, slot, state == "present"))
		}
	}

	// THE CAPABILITY FRAMER HAS TWO CARRIERS and the manifest key names both. Covering only the
	// production slot leaves the NESTED one unproven: forcing its presence argument to `true`
	// unconditionally survives every other row here.
	// THE ROOT'S OWN PRESENCE INFERENCE for the fourth carrier. The seam rows above freeze what
	// the framer does when TOLD a carrier is absent; this freezes what the ROOT infers. Replacing
	// the root's `c != nil` with a literal `true` left the whole package green -- measured --
	// because no committed record omitted the contract. The other three carriers already have
	// record-level pairs below; the shape set covers all four at every variant.
	check("state.output_contract@root.absent", semRecordDigestWith(t, "output_contract", false))
	check("state.output_contract@root.present", semRecordDigestWith(t, "output_contract", true))

	check("state.capability@source_auth.absent", semNestedCapabilityDigest(t, false))
	check("state.capability@source_auth.present", semNestedCapabilityDigest(t, true))

	// THE ONLY optU64 SITE, three artifacts. Absent vs present-zero proves the MARKER; present-
	// zero vs present-one proves the VALUE. Without the first pair, changing `!= nil` to `!= 0`
	// is invisible -- an absent epoch and a zero epoch would frame identically.
	check("state.authority_epoch.absent", semAuthorityEpochDigest(t, nil))
	check("state.authority_epoch.zero", semAuthorityEpochDigest(t, proto.Uint64(0)))
	check("state.authority_epoch.one", semAuthorityEpochDigest(t, proto.Uint64(1)))

	// TWENTY-EIGHT ARTIFACTS from eight rows: two seam presence pairs (4), six claims
	// discriminants, three transition discriminants PLUS two populated transition bodies (5),
	// three record-level presence pairs (6), the ROOT-level output-contract pair (2), the SECOND
	// capability carrier (2) and the optU64 triple (3).
	//
	// The whole-record SHAPES are a separate evidence class with their own vectors and their own
	// signature guard; they are not counted here.
	if len(seen) != 28 {
		t.Fatalf("discharged %d state vectors; the eight state rows expand to 28 artifacts", len(seen))
	}

	// THE MANIFEST TUPLES ARE BOUND TO THIS EVIDENCE. Without it the state keys could be
	// renamed wholesale and, with cardinality preserved, nothing here would notice.
	semAssertKeyedTuples(t, "state", map[string][2]string{
		"presence.output_contract":                   {"absent+present", "preimage"},
		"presence.producer_context":                  {"absent+present", "committed"},
		"presence.capability@production+source_auth": {"absent+present", "committed"},
		"presence.source_authorization":              {"absent+present", "committed"},
		"presence.execution_source_identity":         {"absent+present", "preimage"},
		"discriminant.claims":                        {"0,7,8,9,11,12", "preimage"},
		"discriminant.delivery_transition":           {"0,5,6", "preimage"},
		"optional.producer_context.authority_epoch":  {"absent,0,1", "digest"},
	})
}

// semAssertKeyedTuples binds a manifest section's exact {key, detail, probe} tuples to the
// evidence that discharges it, so a rename cannot slip through on cardinality alone.
func semAssertKeyedTuples(t *testing.T, kind string, want map[string][2]string) {
	t.Helper()

	rows := semRowsOfKind(t, kind)
	if len(rows) != len(want) {
		t.Fatalf("%s: manifest has %d rows, this consumer binds %d", kind, len(rows), len(want))
	}

	for _, r := range rows {
		w, ok := want[r.key]
		if !ok {
			t.Fatalf("%s: manifest key %q is bound to no evidence here", kind, r.key)
		}

		if r.detail != w[0] || r.probe != w[1] {
			t.Fatalf("%s %s: manifest tuple {%s %s} disagrees with the bound {%s %s}",
				kind, r.key, r.detail, r.probe, w[0], w[1])
		}
	}
}

func semClaimsFramed(t *testing.T, variant string) []byte {
	t.Helper()

	c := &edgev1.EdgeSignedCapabilityV1{}

	switch variant {
	case "production":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Production{Production: &edgev1.EdgeProductionClaimsV1{}}
	//nolint:goconst // a corpus manifest token; the table is read against the committed file
	case "source":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Source{Source: &edgev1.EdgeSourceClaimsV1{}}
	//nolint:goconst // a corpus manifest token; the table is read against the committed file
	case "delivery":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{}}
	//nolint:goconst // a corpus manifest token; the table is read against the committed file
	case "collection":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Collection{Collection: &edgev1.EdgeCollectionClaimsV1{}}
	//nolint:goconst // a corpus manifest token; the table is read against the committed file
	case "assignment_execution":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_AssignmentExecution{
			AssignmentExecution: &edgev1.EdgeAssignmentExecutionClaimsV1{},
		}
	//nolint:goconst // a corpus manifest token; the table is read against the committed file
	case "unset":
	default:
		t.Fatalf("unknown claims variant %q", variant)
	}

	d := newDigest()
	d.claimsFramed(c)

	return append([]byte(nil), d.buf...)
}

func semDeliveryTransition(t *testing.T, variant string) []byte {
	t.Helper()

	c := &edgev1.EdgeDeliveryClaimsV1{}

	switch variant {
	case "renewal":
		c.Transition = &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{}}
	case "rollover":
		c.Transition = &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{}}
	case "unset":
	default:
		t.Fatalf("unknown transition variant %q", variant)
	}

	d := newDigest()
	d.deliveryClaims(c)

	return append([]byte(nil), d.buf...)
}

// semDeterministicRecord is a record with FIXED identifiers. `validRecord` mints fresh UUIDs on
// every call, so a whole-envelope digest taken from it is unrepeatable and could never be
// committed -- the vector would differ from the value it was generated against.
// semDeterministicRecord is the BASE shape at variant 0, the fixture the peer decodes.
func semDeterministicRecord(t *testing.T) *edgev1.EdgeRecordV1 {
	t.Helper()

	return semDeterministicRecordVariant(t, 0)
}

func semDeterministicRecordVariant(t *testing.T, variant int) *edgev1.EdgeRecordV1 {
	t.Helper()

	return semGenerate(t).records[variant]
}

// semGeneratedFixtures is everything ONE generation pass produces: the record at every variant,
// and the six claim baselines.
//
// THEY ARE GENERATED TOGETHER ON PURPOSE. A baseline is SPLICED into the record to build a
// composed shape, so its writes land in the record's own flat transcript. Generated
// independently -- as they were -- a record position and a claim position could hold the same
// value, and swapping them across that seam moved no byte in any committed fixture. One shared
// seed counter makes their scalar spaces disjoint by construction, and one shared tuple space
// does the same for enums.
type semGeneratedFixtures struct {
	records   []*edgev1.EdgeRecordV1
	baselines map[string][]proto.Message
	nested    map[string][]proto.Message
}

func semGenerate(t *testing.T) semGeneratedFixtures {
	t.Helper()

	tuples := map[string]bool{}

	for _, c := range []uint64{0, semanticDigestVersion, 5, 6, 7, 8, 9, 11, 12} {
		tup := make([]uint64, semRecordVariants)
		for i := range tup {
			tup[i] = c
		}

		tuples[semTupleKey(tup)] = true
	}

	alloc := newSemEnumAllocShared(semRecordVariants, tuples, false)

	// NO POSITION GETS A CONSTANT TUPLE. Every enum must differ across at least two variants, for
	// two reasons: a shape whose only payload content is root enums would otherwise frame
	// identically in all three variants -- measured, the shape with no producer context and
	// neither capability did -- and a constant tuple can equal a structural constant, which is
	// how `compression` came to sit on a discriminant's value.
	alloc.avoidConstant = true

	out := semGeneratedFixtures{
		baselines: map[string][]proto.Message{},
		nested:    map[string][]proto.Message{},
	}

	// ONE ALLOCATOR, ONE WALK ORDER, EVERY FIXTURE -- the record AND both baseline sets, at every
	// variant.
	//
	// THE BASELINES VARY BY VARIANT, and they have to. The cross product puts a claim body in
	// BOTH carriers at once, so two baselines coexist in one transcript and their enum positions
	// must be separable. Disjoint VALUES cannot do it: `production_claims` alone needs three
	// distinct values from fields of range 3, 4 and 3, so one set already consumes the whole
	// range-3 space and the other set has nothing left. Signatures across variants can: a range
	// of 3 yields 27 tuples over three variants against 19 range-3 positions in total. Measured
	// on the way here -- one shared set of baselines gave 202 collisions, two constant-valued
	// sets still gave 39.
	//
	// The seed restarts per variant so the variants differ ONLY in their enums, and it continues
	// across the record and both sets within a variant so no scalar value is ever reissued.
	for v := range semRecordVariants {
		alloc.reset(v)

		seed := uint16(semSeedStart)

		r := validRecordForSemantics(t)
		semPopulateTracked(r, &seed, map[uint64]bool{}, alloc)

		// THE PAYLOAD RELATION IS RESTORED: the populator assigns field 6 and field 18
		// independently, which breaks the one relation the transcript asserts about the payload.
		sum := sha256.Sum256(r.GetPayload())
		r.PayloadSha256 = sum[:]

		// FIELD 17 IS RESEALED LAST -- excluded from the transcript, so a stale value leaves the
		// digest stable while the record BYTES vary.
		r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

		out.records = append(out.records, r)

		for _, set := range []map[string][]proto.Message{out.baselines, out.nested} {
			for _, root := range semBaselineRoots {
				m := semGrammarRoots[root]()
				semPopulateTracked(m, &seed, map[uint64]bool{}, alloc)
				set[root] = append(set[root], m)
			}
		}
	}

	return out
}

// semSeedBytes fills a 32-byte field from a 16-bit seed. A BYTE SEED WRAPPED: the record and two
// baseline sets need more than 255 distinct scalar values, and a wrapped seed silently reissues
// one, which is exactly the collision this guard exists to forbid.
func semSeedBytes(seed uint16) []byte {
	return bytes.Repeat([]byte{byte(seed >> 8), byte(seed)}, sha256Len/2)
}

// semSeedStart is where the record's scalar seed begins. The baselines continue from where it
// ends, which is what keeps the two spaces disjoint.
const semSeedStart = 7

// semBaselineRoots is the generation ORDER of the claim baselines -- fixed, because the shared
// allocator numbers positions by walk order.
//
//nolint:gochecknoglobals // immutable baseline root list
var semBaselineRoots = []string{"output_contract", "collection_claims", "production_claims",
	"source_claims", "delivery_claims", "execution_grant_claims"}

func semRecordDigestWith(t *testing.T, slot string, present bool) []byte {
	t.Helper()

	r := semDeterministicRecord(t)

	if !present {
		switch slot {
		case "output_contract":
			r.OutputContract = nil
		case "producer_context":
			r.ProducerContext = nil
		case "capability":
			r.ProductionCapability = nil
		case "source_authorization":
			r.SourceAuthorization = nil
		default:
			t.Fatalf("no absent case for record slot %q", slot)
		}
	}

	return SemanticEnvelopeDigest(r)
}

func semSetClaimsFrom(t *testing.T, c *edgev1.EdgeSignedCapabilityV1, kind, carrier string, variant int) {
	t.Helper()

	switch kind {
	case "production":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Production{
			Production: semBaselineFrom(t, "production_claims", carrier, variant).(*edgev1.EdgeProductionClaimsV1)}
	case "source":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Source{
			Source: semBaselineFrom(t, "source_claims", carrier, variant).(*edgev1.EdgeSourceClaimsV1)}
	case "delivery":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Delivery{
			Delivery: semBaselineFrom(t, "delivery_claims", carrier, variant).(*edgev1.EdgeDeliveryClaimsV1)}
	case "collection":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Collection{
			Collection: semBaselineFrom(t, "collection_claims", carrier, variant).(*edgev1.EdgeCollectionClaimsV1)}
	case "assignment_execution":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_AssignmentExecution{
			AssignmentExecution: semBaselineFrom(t, "execution_grant_claims", carrier, variant).(*edgev1.EdgeAssignmentExecutionClaimsV1)}
	case "unset":
		c.Claims = nil
	default:
		t.Fatalf("unknown claims variant %q", kind)
	}
}

// TestSemanticCompositionEdges discharges the 13 edges: for each, DELETING that call or inline
// block must move the transcript.
//
// EVIDENCE OVERLAPS AND THE ROWS SAY SO. Removing `root->output_contract` also breaks that
// slot's row and all seven of its operation rows. That is not double-counting to be engineered
// away -- it is what a composition graph looks like -- so each edge is proven by removing the
// SUB-MESSAGE IT CARRIES and requiring the digest to move, and the overlap is documented rather
// than avoided by weakening the rows.
func TestSemanticCompositionEdges(t *testing.T) {
	edges := map[string]func(*edgev1.EdgeRecordV1){
		"root->output_contract":       func(r *edgev1.EdgeRecordV1) { r.OutputContract = nil },
		"root->producer_context":      func(r *edgev1.EdgeRecordV1) { r.ProducerContext = nil },
		"root->production_capability": func(r *edgev1.EdgeRecordV1) { r.ProductionCapability = nil },
		"root->source_authorization":  func(r *edgev1.EdgeRecordV1) { r.SourceAuthorization = nil },
		"source_authorization->capability": func(r *edgev1.EdgeRecordV1) {
			r.GetSourceAuthorization().Capability = nil
		},
		"capability->claims_framed": func(r *edgev1.EdgeRecordV1) {
			r.GetProductionCapability().Claims = nil
		},
	}

	// The remaining six edges are carried by capabilities the record does not hold in its
	// production slot; they are exercised at the framer, which is where those calls live.
	// THE DISCRIMINANT IS HELD CONSTANT. Comparing a selected variant against `unset` proves
	// nothing about the CHILD FRAMER: the discriminant alone differs, so the two stay unequal
	// even with the child call deleted -- measured, and it left this test green. Comparing a
	// POPULATED body against a DEFAULT one under the SAME discriminant isolates the call.
	framerEdges := map[string]func() ([]byte, []byte){
		"claims_framed->production_claims": func() ([]byte, []byte) {
			return semClaimsBody(t, "production", true), semClaimsBody(t, "production", false)
		},
		"claims_framed->source_claims": func() ([]byte, []byte) {
			return semClaimsBody(t, "source", true), semClaimsBody(t, "source", false)
		},
		"claims_framed->delivery_claims": func() ([]byte, []byte) {
			return semClaimsBody(t, "delivery", true), semClaimsBody(t, "delivery", false)
		},
		"claims_framed->collection_claims": func() ([]byte, []byte) {
			return semClaimsBody(t, "collection", true), semClaimsBody(t, "collection", false)
		},
		"claims_framed->execution_grant_claims": func() ([]byte, []byte) {
			return semClaimsBody(t, "assignment_execution", true), semClaimsBody(t, "assignment_execution", false)
		},
		"delivery_claims->transition": func() ([]byte, []byte) {
			return semDeliveryTransition(t, "renewal"), semDeliveryTransition(t, "unset")
		},
		"execution_grant_claims->source_identity": func() ([]byte, []byte) {
			with := semBaseline(t, "execution_grant_claims").(*edgev1.EdgeAssignmentExecutionClaimsV1)
			without := proto.Clone(with).(*edgev1.EdgeAssignmentExecutionClaimsV1)
			without.SourceIdentity = nil

			return semFramerOutput(t, "execution_grant_claims", with, true),
				semFramerOutput(t, "execution_grant_claims", without, true)
		},
	}

	declared := map[string]bool{}
	for _, r := range semRowsOfKind(t, "edge") {
		declared[r.key] = true
	}

	if len(declared) != 13 {
		t.Fatalf("the manifest declares %d edges, the inventory names 13", len(declared))
	}

	for key, drop := range edges {
		if !declared[key] {
			t.Fatalf("%s is exercised here but not declared in the manifest", key)
		}

		r := semDeterministicRecord(t)
		base := SemanticEnvelopeDigest(r)

		drop(r)

		if bytes.Equal(SemanticEnvelopeDigest(r), base) {
			t.Fatalf("%s: removing what this edge carries did not move the transcript -- the "+
				"call is absent", key)
		}
	}

	for key, pair := range framerEdges {
		if !declared[key] {
			t.Fatalf("%s is exercised here but not declared in the manifest", key)
		}

		with, without := pair()
		if bytes.Equal(with, without) {
			t.Fatalf("%s: removing what this edge carries did not move the framed bytes", key)
		}
	}

	if len(edges)+len(framerEdges) != 13 {
		t.Fatalf("exercised %d edges, the inventory names 13", len(edges)+len(framerEdges))
	}
}

// ---------------------------------------------------------------------------
// separation: quantities that must NOT reach the transcript
// ---------------------------------------------------------------------------

// TestSemanticSeparationSchemaAbsence discharges the one row that is different in kind. There is
// nothing to mutate: `submission_sha256` -- the producer-receipt identity -- exists in NO edge
// proto, so the claim is SCHEMA CLOSURE rather than an invariance measurement.
func TestSemanticSeparationSchemaAbsence(t *testing.T) {
	// THE WHOLE EDGE PACKAGE, NESTED TYPES INCLUDED. Scanning top-level messages only proved
	// something much narrower than "absent from every edge proto", which is what the ledger says:
	// a `submission_sha256` declared inside a nested type would have satisfied it.
	scanned, fields, found := semScanEdgeSchema(t, "submission")

	// AN ABSENCE CLAIM NEEDS AN ACCEPTED CONTROL. "Found nothing" is equally true of a scan that
	// reached nothing at all, so the same walk must find a field that IS there -- and it must
	// find it in a NESTED type, or the recursion this test exists for goes unexercised.
	if _, _, control := semScanEdgeSchema(t, "record_sha256"); len(control) == 0 {
		t.Fatal("the control field record_sha256 was not found by this scan; an absence result " +
			"from it would mean nothing")
	}

	// THE EDGE PACKAGE DECLARES NO NESTED TYPES TODAY -- no nested messages, no map fields -- so
	// the recursive branch never executes against it and would stay unexecuted if it were
	// broken, leaving "absent from every edge proto" resting on code no test had run. The
	// control below runs the SAME walk over a package that DOES nest, so the branch the claim
	// depends on is measured here and inherited by the scan above.
	var cm, cf int

	var chits []string

	semWalkMessages(semNestedControlFile(t).Messages(), "needle_field", &cm, &cf, &chits)

	if want := "semantic.control.Outer.Inner.needle_field"; !slices.Contains(chits, want) {
		t.Fatalf("the nested-type control did not reach %s; the recursion is not descending and "+
			"the absence claim covers top-level types only (hits: %v)", want, chits)
	}

	// AND THE INVENTORY IS NONZERO AND ANCHORED. A registry that returned no files would leave
	// every counter at zero and every needle unfound.
	if scanned < 2 || fields == 0 {
		t.Fatalf("the scan reached %d messages and %d fields; it is vacuous", scanned, fields)
	}

	if len(found) != 0 {
		t.Fatalf("producer-receipt identity is supposed to be absent from the edge schema, found %v", found)
	}
}

// semScanEdgeSchema walks every message in the edge proto package, RECURSING INTO NESTED TYPES,
// and reports what it reached alongside the hits. The counters are returned so callers can prove
// the walk was not empty.
func semScanEdgeSchema(t *testing.T, needle string) (msgs, fields int, found []string) {
	t.Helper()

	pkg := (&edgev1.EdgeRecordV1{}).ProtoReflect().Descriptor().ParentFile().Package()
	if pkg == "" {
		t.Fatal("could not resolve the edge proto package; the scan would be vacuous")
	}

	protoregistry.GlobalFiles.RangeFilesByPackage(pkg, func(fd protoreflect.FileDescriptor) bool {
		semWalkMessages(fd.Messages(), needle, &msgs, &fields, &found)

		return true
	})

	return msgs, fields, found
}

// semWalkMessages is the recursion itself, separated so the nested branch can be exercised
// against a schema that actually nests.
func semWalkMessages(mds protoreflect.MessageDescriptors, needle string, msgs, fields *int, found *[]string) {
	for i := range mds.Len() {
		md := mds.Get(i)
		*msgs++

		fds := md.Fields()
		for j := range fds.Len() {
			*fields++

			if strings.Contains(string(fds.Get(j).Name()), needle) {
				*found = append(*found, string(md.FullName())+"."+string(fds.Get(j).Name()))
			}
		}

		semWalkMessages(md.Messages(), needle, msgs, fields, found)
	}
}

// semNestedControlFile builds a synthetic file descriptor whose ONLY occurrence of
// `needle_field` is one level down.
//
// NOTHING LINKED INTO THIS BINARY NESTS -- measured, not assumed: the edge protos declare no
// nested messages and no map fields, and neither do the well-known types the binary pulls in. A
// control drawn from the registry would therefore have had nothing to find, so the branch is
// exercised against a descriptor built for the purpose. The needle appears at the nested level
// ONLY, so deleting the recursive call fails this control.
func semNestedControlFile(t *testing.T) protoreflect.FileDescriptor {
	t.Helper()

	fdp := &descriptorpb.FileDescriptorProto{
		Name:    proto.String("semantic_control.proto"),
		Package: proto.String("semantic.control"),
		Syntax:  proto.String("proto3"),
		MessageType: []*descriptorpb.DescriptorProto{{
			Name: proto.String("Outer"),
			Field: []*descriptorpb.FieldDescriptorProto{{
				Name:   proto.String("top_field"),
				Number: proto.Int32(1),
				Label:  descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
				Type:   descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
			}},
			NestedType: []*descriptorpb.DescriptorProto{{
				Name: proto.String("Inner"),
				Field: []*descriptorpb.FieldDescriptorProto{{
					Name:   proto.String("needle_field"),
					Number: proto.Int32(1),
					Label:  descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
					Type:   descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
				}},
			}},
		}},
	}

	fd, err := protodesc.NewFile(fdp, nil)
	if err != nil {
		t.Fatalf("build the nested control descriptor: %v", err)
	}

	return fd
}

// TestSemanticSeparationDeliveryFrame proves the outer frame cannot influence the inner
// transcript. Each row varies ONE quantity around IDENTICAL record bytes and asserts the exact
// normalized differences: record bytes equal, record digest equal, semantic digest equal.
//
// A "digest unchanged" assertion alone would be weak -- it holds trivially if the frame never
// reached the record at all. Pinning record_bytes and record_sha256 as WELL shows the frame was
// genuinely built around the same artifact each time.
func TestSemanticSeparationDeliveryFrame(t *testing.T) {
	r, policy := signedRecord(t)

	rb, err := CanonicalRecordBytes(r)
	if err != nil {
		t.Fatalf("canonical record bytes: %v", err)
	}

	sum := sha256.Sum256(rb)
	inner := SemanticEnvelopeDigest(r)
	spool := mustUUID(t)

	frameFor := func(sp []byte, seq uint64, dc *edgev1.EdgeSignedCapabilityV1) *edgev1.EdgeDeliveryFrameV1 {
		return &edgev1.EdgeDeliveryFrameV1{
			SpoolId: sp, Sequence: seq, RecordSha256: sum[:], RecordBytes: rb, DeliveryCapability: dc,
		}
	}

	// The control: the frame must ADMIT, or every "unchanged" below would be unchanged for the
	// uninteresting reason that nothing was ever validated.
	base := frameFor(spool, 1, nil)

	baseDecision, err := ValidateFrameSigned(base, policy)
	if err != nil {
		t.Fatalf("the baseline frame must be admitted: %v", err)
	}

	if baseDecision.DeliveryMode != FrameDeliveryModeFresh {
		t.Fatalf("baseline delivery mode = %v, want Fresh", baseDecision.DeliveryMode)
	}

	assertInner := func(name string, f *edgev1.EdgeDeliveryFrameV1) {
		t.Helper()

		if !bytes.Equal(f.GetRecordBytes(), rb) {
			t.Fatalf("%s: record bytes moved; the row is no longer varying ONE quantity", name)
		}

		if !bytes.Equal(f.GetRecordSha256(), sum[:]) {
			t.Fatalf("%s: record digest moved", name)
		}

		var decoded edgev1.EdgeRecordV1
		if err := proto.Unmarshal(f.GetRecordBytes(), &decoded); err != nil {
			t.Fatalf("%s: enclosed record must decode: %v", name, err)
		}

		if got := SemanticEnvelopeDigest(&decoded); !bytes.Equal(got, inner) {
			t.Fatalf("%s: the outer frame moved the INNER semantic digest", name)
		}
	}

	// spool_id and sequence: varied one at a time, record artifact identical.
	other := mustUUID(t)
	if bytes.Equal(other, spool) {
		t.Fatal("the two spool ids must differ")
	}

	assertInner("delivery_frame.spool_id", frameFor(other, 1, nil))
	assertInner("delivery_frame.sequence", frameFor(spool, 2, nil))

	// delivery_capability: a VALID SIGNED add/remove pair. The capability must be demonstrably
	// LIVE -- attaching it moves the decision from Fresh to Renewal -- otherwise "the digest did
	// not move" would be equally true of bytes the validator ignored entirely.
	dpub, dpriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}

	dIssuer, dKey := mustUUID(t), mustUUID(t)
	policy.Trust.(mapTrust)[trustKey(dIssuer, dKey)] = dpub
	now := policy.NowUnixNano

	dc := &edgev1.EdgeSignedCapabilityV1{
		CapabilityVersion: 1, IssuerId: dIssuer, IssuerKeyId: dKey, Algorithm: "ed25519",
		NotBeforeUnixNano: now - 3_600_000_000_000, ExpiresAtUnixNano: now + 3_600_000_000_000,
		Claims: &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: &edgev1.EdgeDeliveryClaimsV1{
			EventId: r.GetEventId(), RecordSha256: sum[:], SpoolId: spool, Sequence: 1,
			Transition: &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
				RenewedNotBeforeUnixNano: now - 1_800_000_000_000,
				RenewedExpiresUnixNano:   now + 1_800_000_000_000,
			}},
		}},
	}
	SignCapability(dc, dpriv)

	withCap := frameFor(spool, 1, dc)

	capDecision, err := ValidateFrameSigned(withCap, policy)
	if err != nil {
		t.Fatalf("the frame carrying a delivery capability must be admitted: %v", err)
	}

	if capDecision.DeliveryMode != FrameDeliveryModeRenewal {
		t.Fatalf("attaching the delivery capability left the decision at %v; it must move to "+
			"Renewal, or the capability is inert and separation proves nothing about it",
			capDecision.DeliveryMode)
	}

	assertInner("delivery_frame.delivery_capability", withCap)
}

// TestSemanticSeparationLegalReencoding proves the PHYSICAL artifact identity is separate from
// the SEMANTIC one: two legal encodings of the same decoded record differ in record_sha256 while
// framing to the same semantic digest.
func TestSemanticSeparationLegalReencoding(t *testing.T) {
	r := semDeterministicRecord(t)

	canonical, err := CanonicalRecordBytes(r)
	if err != nil {
		t.Fatalf("canonical record bytes: %v", err)
	}

	// A SECOND LEGAL ENCODING, CONSTRUCTED rather than hoped for. Asking a marshaller to emit
	// different bytes is not reliable -- protobuf-go produced byte-identical output here, which
	// left the differing-digest half of this row undemonstrated. Re-emitting one scalar field
	// with its OWN value is unambiguously legal (proto3 scalars are last-wins) and decodes to
	// exactly the same message.
	num := protowire.Number(3) // compression: a varint field always present on a valid record
	alt := append(append([]byte(nil), canonical...),
		protowire.AppendVarint(protowire.AppendTag(nil, num, protowire.VarintType),
			uint64(r.GetCompression()))...)

	if bytes.Equal(canonical, alt) {
		t.Fatal("the constructed alternate encoding must differ in bytes")
	}

	var a, b edgev1.EdgeRecordV1
	if err := proto.Unmarshal(canonical, &a); err != nil {
		t.Fatalf("decode canonical: %v", err)
	}

	if err := proto.Unmarshal(alt, &b); err != nil {
		t.Fatalf("decode alternate: %v", err)
	}

	// EQUAL DECODED RECORDS is the premise: without it the two encodings are simply different
	// records and the row proves nothing about encoding at all.
	if !proto.Equal(&a, &b) {
		t.Fatal("the two encodings must decode to the same record")
	}

	if got, want := SemanticEnvelopeDigest(&a), SemanticEnvelopeDigest(&b); !bytes.Equal(got, want) {
		t.Fatal("the semantic digest must be invariant across legal re-encodings")
	}

	// THE PHYSICAL IDENTITY MUST MOVE while the semantic one did not. Both halves are required:
	// equal digests alone would also hold if the two encodings were identical.
	s1, s2 := sha256.Sum256(canonical), sha256.Sum256(alt)
	if bytes.Equal(s1[:], s2[:]) {
		t.Fatal("two differing legal encodings must yield differing record digests")
	}
}

// semNestedCapabilityDigest frames the record with the SOURCE AUTHORIZATION's nested capability
// present or absent -- the capability framer's second carrier.
func semNestedCapabilityDigest(t *testing.T, present bool) []byte {
	t.Helper()

	r := semDeterministicRecord(t)
	if !present {
		r.GetSourceAuthorization().Capability = nil
	}

	return SemanticEnvelopeDigest(r)
}

// semAuthorityEpochDigest frames the record with the ONLY proto3-optional field absent, present
// and zero, or present and one.
func semAuthorityEpochDigest(t *testing.T, v *uint64) []byte {
	t.Helper()

	r := semDeterministicRecord(t)
	r.GetProducerContext().AuthorityEpoch = v

	return SemanticEnvelopeDigest(r)
}

// semClaimsBody frames one claims variant with a POPULATED or DEFAULT body under the SAME
// discriminant, so an edge row isolates the child framer call rather than the discriminant.
func semClaimsBody(t *testing.T, variant string, populated bool) []byte {
	t.Helper()

	if !populated {
		return semClaimsFramed(t, variant)
	}

	c := &edgev1.EdgeSignedCapabilityV1{}

	switch variant {
	case "production":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Production{
			Production: semBaseline(t, "production_claims").(*edgev1.EdgeProductionClaimsV1),
		}
	case "source":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Source{
			Source: semBaseline(t, "source_claims").(*edgev1.EdgeSourceClaimsV1),
		}
	case "delivery":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Delivery{
			Delivery: semBaseline(t, "delivery_claims").(*edgev1.EdgeDeliveryClaimsV1),
		}
	case "collection":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_Collection{
			Collection: semBaseline(t, "collection_claims").(*edgev1.EdgeCollectionClaimsV1),
		}
	case "assignment_execution":
		c.Claims = &edgev1.EdgeSignedCapabilityV1_AssignmentExecution{
			AssignmentExecution: semBaseline(t, "execution_grant_claims").(*edgev1.EdgeAssignmentExecutionClaimsV1),
		}
	default:
		t.Fatalf("unknown claims variant %q", variant)
	}

	d := newDigest()
	d.claimsFramed(c)

	return append([]byte(nil), d.buf...)
}

// ---------------------------------------------------------------------------
// systematic fixture-collision guard
// ---------------------------------------------------------------------------

// semCollectWrites walks a message and records every value the transcript will frame, keyed by
// the WIDTH CLASS it is written at. Two values in the same class that are EQUAL are
// indistinguishable once framed, so swapping their writes is undetectable.
// semWrite is one primitive the grammar emits.
//
// THE WIRE CLASS IS THE WIDTH, NOT THE GO TYPE. `i64` is `u64(uint64(v))` and `str` is
// `bytes([]byte(s))`, so those pairs are INDISTINGUISHABLE on the wire and separating them into
// four classes would declare two writes non-exchangeable when the transcript cannot tell them
// apart. Length-prefixed writes are classed by their payload length, which IS observable.
type semWrite struct {
	class string
	value string
	label string
	width int
	raw   []byte

	// konst marks a STRUCTURAL CONSTANT -- the version prefix and the oneof discriminants. Their
	// values are fixed by the shape, not by the payload.
	konst bool
}

// semFlatWrites collects a fixture's field writes in ONE FLAT SCOPE.
//
// There is no smaller scope to use: the preimage is an untagged concatenation, so every write
// coexists with every other. Helper boundaries in either implementation are invisible to it.
func semFlatWrites(t *testing.T, m protoreflect.Message, prefix string, out *[]semWrite) {
	t.Helper()

	fds := m.Descriptor().Fields()

	for i := range fds.Len() {
		fd := fds.Get(i)
		if fd.ContainingOneof() != nil && !fd.ContainingOneof().IsSynthetic() && !m.Has(fd) {
			continue
		}

		label := prefix + string(fd.Name())
		v := m.Get(fd)

		//nolint:exhaustive // fail-closed: the default arm rejects any unlisted kind
		switch fd.Kind() {
		case protoreflect.MessageKind:
			if m.Has(fd) {
				semFlatWrites(t, v.Message(), label+".", out)
			}
		case protoreflect.BytesKind:
			b := v.Bytes()
			*out = append(*out, semWrite{class: fmt.Sprintf("len:%d", len(b)), value: hex.EncodeToString(b), label: label, width: 8 + len(b)})
		case protoreflect.StringKind:
			b := []byte(v.String())
			*out = append(*out, semWrite{class: fmt.Sprintf("len:%d", len(b)), value: hex.EncodeToString(b), label: label, width: 8 + len(b)})
		case protoreflect.EnumKind:
			*out = append(*out, semWrite{class: "u64", value: strconv.FormatUint(uint64(v.Enum()), 10), label: label, width: 8})
		case protoreflect.Uint64Kind, protoreflect.Uint32Kind:
			*out = append(*out, semWrite{class: "u64", value: strconv.FormatUint(v.Uint(), 10), label: label, width: 8})
		case protoreflect.Int64Kind, protoreflect.Int32Kind:
			*out = append(*out, semWrite{class: "u64", value: strconv.FormatUint(uint64(v.Int()), 10), label: label, width: 8})
		default:
			// Fail closed. A kind this does not know is a write MISSING from the flat
			// transcript, and the collision proof reads that transcript as complete -- so a
			// silent skip would weaken the evidence without failing anything.
			t.Fatalf("semFlatWrites: no case for kind %v at %s", fd.Kind(), label)
		}
	}
}

// TestSemanticFixturesHaveNoValueCollisions is the systematic order guard.
//
// TWO WRITES OF THE SAME WIRE CLASS CARRYING THE SAME VALUE ARE EXCHANGEABLE WITHOUT MOVING A
// BYTE, so no assertion anywhere can detect their reordering. Chasing such pairs one mutation at
// a time cannot close the class -- by construction its members are the ones nobody thought of --
// so the fixtures are guarded systematically instead.
//
// FOR THE RECORD THE COMPARISON IS ACROSS FIXTURES. Its flat transcript cannot be separated by
// one fixture (see semRecordVariants), so a position's identity is its SIGNATURE: the tuple of
// values it takes across every committed record. Two positions collide only if they agree in
// ALL of them.
func TestSemanticFixturesHaveNoValueCollisions(t *testing.T) {
	// A POSITION'S EVIDENCE IS THE WHOLE COMMITTED FIXTURE SET, not one shape.
	//
	// Two positions are exchangeable only if they hold the SAME VALUE IN EVERY COMMITTED FIXTURE
	// WHERE BOTH OCCUR. Scoping the question per shape asked something stronger and wrong: the
	// two capability `claims` discriminants are both 8 in the shape where both capabilities carry
	// `source` claims, and no fixture could ever make them differ THERE -- but they are 7 and 8
	// in the base shape, so swapping the two writes does move bytes, and the pair is separated.
	// INDEXED BY FIXTURE, not a flat occurrence list. The cross product is 1983 fixtures, and
	// comparing every pair of labels by scanning both occurrence lists is quadratic in fixtures
	// on top of quadratic in labels -- hundreds of millions of comparisons. Keyed lookup makes it
	// linear in the fixtures one label appears in.
	seen := map[string]map[string]string{}
	classOf := map[string]string{}
	konstOf := map[string]bool{}

	var order []string

	record := func(fixture string, writes []semWrite) {
		for _, w := range writes {
			if w.class == "marker" || w.class == "len:0" {
				// A 1-byte presence marker carries no value and a zero-length write is a bare
				// length prefix; neither can be made distinct, and exchanging identical writes is
				// not observable. Presence is discharged by the state rows, which vary it.
				continue
			}

			if _, known := classOf[w.label]; !known {
				classOf[w.label] = w.class
				konstOf[w.label] = w.konst
				order = append(order, w.label)
			}

			if seen[w.label] == nil {
				seen[w.label] = map[string]string{}
			}

			seen[w.label][fixture] = w.value
		}
	}

	var collisions []string

	compare := func(scope string) {
		for i, a := range order {
			for _, b := range order[i+1:] {
				if classOf[a] != classOf[b] {
					continue
				}

				// TWO STRUCTURAL CONSTANTS may be forced equal BY THE SHAPE -- both carriers
				// holding the same claims kind write the same discriminant, and no fixture of
				// that shape can separate them because nothing varies. A swap confined to such a
				// shape changes no byte for ANY input, so there is nothing to detect. A pair with
				// a FIELD on either side is a different matter: its equality is the fixture's
				// choice, which is exactly how `compression` came to equal a discriminant.
				if konstOf[a] && konstOf[b] {
					continue
				}

				coexists, separated := false, false

				// NOT `a, b = b, a`: those are the loop variables, and reassigning them corrupts
				// every later iteration of the inner loop -- it reported one pair 306 times.
				left, right := seen[a], seen[b]
				if len(right) < len(left) {
					left, right = right, left
				}

				for fixture, va := range left {
					vb, both := right[fixture]
					if !both {
						continue
					}

					coexists = true

					if va != vb {
						separated = true

						break
					}
				}

				if coexists && !separated {
					collisions = append(collisions,
						fmt.Sprintf("%s: %s and %s hold the same %s value in EVERY variant",
							scope, a, b, classOf[a]))
				}
			}
		}
	}

	// SCOPED PER STRUCTURAL SHAPE, ACROSS ITS VARIANTS. Asking whether ANY of the fixtures
	// separates a pair is too weak: a mutation executes inside ONE shape, so the pair must be
	// separated in a fixture of THAT shape. Measured -- globally scoped, `compression` and the
	// production claims discriminant are both 0 in the shape where production claims are unset
	// and the nested carrier holds `source`, and swapping them there passed the whole package.
	for _, shape := range semShapes {
		clear(seen)
		clear(classOf)
		clear(konstOf)
		order = order[:0]

		for v := range semRecordVariants {
			record(fmt.Sprintf("v%d", v), semRecordOrderedWrites(semShapeRecord(t, shape, v)))
		}

		compare("shape " + shape)
	}

	// The claim baselines and the populated transition bodies are committed as their OWN frozen
	// byte strings, so each is a fixture in its own right.
	singles := map[string]proto.Message{}

	for _, carrier := range []string{"production", "nested"} {
		for _, root := range semBaselineRoots {
			for v := range semRecordVariants {
				singles[fmt.Sprintf("baseline.%s.%s.v%d", carrier, root, v)] = semBaselineFrom(t, root, carrier, v)
			}
		}
	}

	singles["transition.renewal.populated"] = semTransitionMessage(t, "renewal")
	singles["transition.rollover.populated"] = semTransitionMessage(t, "rollover")

	clear(seen)
	clear(classOf)
	clear(konstOf)
	order = order[:0]

	for name, m := range singles {
		var writes []semWrite

		semFlatWrites(t, m.ProtoReflect(), "", &writes)
		record(name, writes)
	}

	compare("committed baselines")

	if len(collisions) > 0 {
		sort.Strings(collisions)
		t.Fatalf("%d fixture signature collisions -- swapping either write in a pair produces an "+
			"IDENTICAL transcript in every committed fixture, so no row could detect the "+
			"reordering:\n  %s", len(collisions), strings.Join(collisions, "\n  "))
	}
}

// ---------------------------------------------------------------------------
// caller-level order: chunk signatures and the root-order witness
// ---------------------------------------------------------------------------

// semRootChunks renders the root transcript as the CALLER sees it: one chunk per direct write
// and one per composite child's framed output.
//
// A composition edge proves ATTACHMENT -- that a child is framed at all. It says nothing about
// WHERE. Two composite children whose framed output is byte-identical could be exchanged with
// every edge row, every child vector and every per-field row still green, because each of those
// looks inside one framer at a time. Order between callers is a property of the caller.
// semRootChunk is one caller-level unit of the root transcript: a direct write, or the complete
// framed output of one child framer.
type semRootChunk struct {
	name  string
	bytes []byte
}

// semRootChunks decomposes the root transcript into its SEVENTEEN ordered chunks, IN THE ORDER
// THE ROOT WRITES THEM.
//
// IT MUST BE ORDERED AND IT MUST BE RECONSTRUCTED. An unordered map cannot express the property
// being proved -- position -- and a decomposition that is never hashed back to the production
// digest is an independent copy of the grammar that can drift from it silently. That is exactly
// how `producer_context` went missing: the map held sixteen entries, the root writes seventeen
// chunks, and nothing compared the two.
func semRootChunks(t *testing.T, r *edgev1.EdgeRecordV1) []semRootChunk {
	t.Helper()

	u64 := func(v uint64) []byte {
		d := newDigest()
		d.u64(v)

		return append([]byte(nil), d.buf...)
	}

	byts := func(b []byte) []byte {
		d := newDigest()
		d.bytes(b)

		return append([]byte(nil), d.buf...)
	}

	framed := func(f func(*digestWriter)) []byte {
		d := newDigest()
		f(d)

		return append([]byte(nil), d.buf...)
	}

	return []semRootChunk{
		{"version", u64(semanticDigestVersion)},
		{"01.event_id", byts(r.GetEventId())},
		{"02.payload_family", u64(uint64(r.GetPayloadFamily()))},
		{"03.compression", u64(uint64(r.GetCompression()))},
		{"04.encoded_size", u64(uint64(r.GetEncodedSize()))},
		{"05.uncompressed_size", u64(uint64(r.GetUncompressedSize()))},
		{"06.payload_sha256", byts(r.GetPayloadSha256())},
		{"07.output_contract", framed(func(d *digestWriter) {
			d.outputContract(r.GetOutputContract(), r.GetOutputContract() != nil)
		})},
		{"08.producer_context", framed(func(d *digestWriter) {
			d.producerContext(r.GetProducerContext(), r.GetProducerContext() != nil)
		})},
		{"09.route_profile", u64(uint64(r.GetRouteProfile()))},
		{"10.traffic_class", u64(uint64(r.GetTrafficClass()))},
		{"11.network_scope_id", byts(r.GetNetworkScopeId())},
		{"12.production_capability", framed(func(d *digestWriter) {
			d.capability(r.GetProductionCapability(), r.GetProductionCapability() != nil)
		})},
		{"13.source_authorization", framed(func(d *digestWriter) {
			d.sourceAuth(r.GetSourceAuthorization(), r.GetSourceAuthorization() != nil)
		})},
		{"14.projected_row_count", u64(uint64(r.GetProjectedRowCount()))},
		{"15.projected_write_bytes", u64(r.GetProjectedWriteBytes())},
		{"16.cost_model_version", u64(uint64(r.GetCostModelVersion()))},
	}
}

// TestSemanticRootChunksReconstructTheProductionDigest binds the decomposition to production
// BEFORE anything is concluded from it.
//
// WITHOUT THIS THE CHUNK LIST PROVES NOTHING ABOUT THE REAL GRAMMAR. It would be a second,
// test-only implementation, free to omit a chunk (it did), reorder one, or frame one differently,
// while every assertion built on it stayed green.
func TestSemanticRootChunksReconstructTheProductionDigest(t *testing.T) {
	r := semDeterministicRecord(t)
	chunks := semRootChunks(t, r)

	if len(chunks) != 17 {
		t.Fatalf("the root writes %d chunks; the decomposition has %d -- version, 12 direct "+
			"writes and FOUR composite children", 17, len(chunks))
	}

	var preimage []byte
	for _, c := range chunks {
		preimage = append(preimage, c.bytes...)
	}

	sum := sha256.Sum256(preimage)
	if got := SemanticEnvelopeDigest(r); !bytes.Equal(sum[:], got) {
		t.Fatalf("the 17-chunk preimage does not hash to the production digest -- the "+
			"decomposition is not this grammar.\n  reconstructed %x\n  production    %x",
			sum[:], got)
	}
}

// TestSemanticRootChunksAreDistinct proves no two chunks are EXCHANGEABLE.
//
// THE COMPARISON IS BETWEEN COMPLETE PREIMAGES, not between the two chunks. Comparing A||B with
// B||A is wrong for non-adjacent chunks and unsound even for adjacent ones: with A="a", a middle
// M="b" and B="aba", A||B != B||A, yet the full arrangements A M B and B M A are both "ababa" --
// the swap is invisible in the transcript while the pairwise test calls it detected. So each
// pair is exchanged IN PLACE and the whole preimage is compared.
//
// AND ACROSS EVERY COMMITTED VARIANT. Two chunks may legitimately coincide in one fixture --
// `payload_family` and `compression` do -- and still be separated by another; the property is
// that SOME committed fixture moves, which is the same signature rule the primitive guard uses
// one level down.
func TestSemanticRootChunksAreDistinct(t *testing.T) {
	variants := make([][]semRootChunk, semRecordVariants)
	for v := range semRecordVariants {
		variants[v] = semRootChunks(t, semDeterministicRecordVariant(t, v))
	}

	join := func(chunks []semRootChunk, i, j int) []byte {
		var out []byte

		for k, c := range chunks {
			switch k {
			case i:
				out = append(out, chunks[j].bytes...)
			case j:
				out = append(out, chunks[i].bytes...)
			default:
				out = append(out, c.bytes...)
			}
		}

		return out
	}

	n := len(variants[0])

	for i := range n {
		for j := i + 1; j < n; j++ {
			detected := false

			for v := range semRecordVariants {
				base := join(variants[v], -1, -1)
				if !bytes.Equal(base, join(variants[v], i, j)) {
					detected = true

					break
				}
			}

			if !detected {
				t.Fatalf("exchanging root chunks %s and %s leaves the preimage identical in EVERY "+
					"committed variant, so no row could detect that reordering",
					variants[0][i].name, variants[0][j].name)
			}
		}
	}
}

// TestSemanticRootOrderWitness names the whole-envelope populated digest as the evidence for
// CALLER-LEVEL ORDER, which is the one thing the child vectors and edge tests cannot supply:
// they look inside a single framer, or assert a child is framed at all.
//
// A representative composite-block reorder must fail THIS vector while leaving those green.
func TestSemanticRootOrderWitness(t *testing.T) {
	// EVERY COMMITTED VARIANT, not just the first. Checking v0 alone left v1 consumed by the peer
	// and not by this runtime, so the shared-vector parity the ledger claims did not hold for it:
	// Go froze v1 only INDIRECTLY, through the committed record artifact.

	for v := range semRecordVariants {
		key := fmt.Sprintf("root.shape.base.v%d", v)

		want, ok := semVectorFor(t, key)
		if !ok {
			t.Fatalf("no committed vector for %s", key)
		}

		got := hex.EncodeToString(SemanticEnvelopeDigest(semDeterministicRecordVariant(t, v)))
		if got != want {
			t.Fatalf("%s: the whole-envelope digest moved.\n  committed %s\n  computed  %s",
				key, want, got)
		}
	}
}

// TestSemanticBaseShapeAliasSetIsExact rebuilds the set of committed keys that share the
// base-shape digest, instead of stating its size in prose.
//
// Those keys are the SAME whole-envelope measurement under other names: a `state.<slot>.present`
// row for a slot whose present value IS the fully populated record. That is why the base shape
// can be described as "naming" what the per-slot rows measure -- and why the set has to be
// pinned. A row entering or leaving it changes what the witness is evidence FOR.
//
// IT IS DERIVED BECAUSE THE HAND COUNT WENT STALE. The size was written out in three places;
// when the fifth row appeared, one of them still read "four" and stayed wrong through a review
// round, because nothing executed it. This fails instead, and names the drift.
func TestSemanticBaseShapeAliasSetIsExact(t *testing.T) {
	base, ok := semVectorFor(t, "root.shape.base.v0")
	if !ok {
		t.Fatal("no committed vector for root.shape.base.v0")
	}

	// semVectors, NOT semVectorFor: this walks every committed key, and recording a read for
	// each would mark the whole corpus observed and make the after-suite unread-vector guard
	// vacuous. The members are asserted by their own tests, which is what records them.
	var got []string

	for k, v := range semVectors(t) {
		if v == base {
			got = append(got, k)
		}
	}

	sort.Strings(got)

	want := []string{
		"root.shape.base.v0",
		"state.capability.present",
		"state.capability@source_auth.present",
		"state.output_contract@root.present",
		"state.producer_context.present",
		"state.source_authorization.present",
	}

	if !slices.Equal(got, want) {
		t.Fatalf("the base-shape alias set moved.\n  committed %v\n  expected  %v", got, want)
	}
}

// semTransitionPopulated frames a delivery transition branch with a POPULATED body, so the
// members WITHIN that branch carry distinct values and their order is observable.
// semTransitionMessage builds a delivery-claims message with one transition branch POPULATED.
func semTransitionMessage(t *testing.T, variant string) *edgev1.EdgeDeliveryClaimsV1 {
	t.Helper()

	c := &edgev1.EdgeDeliveryClaimsV1{}

	switch variant {
	case "renewal":
		c.Transition = &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: &edgev1.EdgeDeliveryRenewalV1{
			RenewedNotBeforeUnixNano: 1_700_000_000_000_000_000,
			RenewedExpiresUnixNano:   1_900_000_000_000_000_000,
		}}
	case "rollover":
		c.Transition = &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: &edgev1.EdgeDeliveryRolloverV1{
			RecoveryId:    bytes.Repeat([]byte{0x61}, 16),
			PriorSpoolId:  bytes.Repeat([]byte{0x62}, 16),
			PriorSequence: 7,
		}}
	default:
		t.Fatalf("unknown transition variant %q", variant)
	}

	return c
}

func semTransitionPopulated(t *testing.T, variant string) []byte {
	t.Helper()

	d := newDigest()
	d.deliveryClaims(semTransitionMessage(t, variant))

	return append([]byte(nil), d.buf...)
}

// semIsClaimsOneofField reports whether a capability field belongs to the ONE oneof that
// claims_framed owns. Everything else -- a second oneof, or a proto3-`optional` field, whose
// SYNTHETIC oneof would otherwise match -- must fall through and be classified like any other
// field, so it cannot disappear into the existing edge without an operation row.
func semIsClaimsOneofField(fd protoreflect.FieldDescriptor) bool {
	oo := fd.ContainingOneof()

	return oo != nil && !oo.IsSynthetic() && oo.Name() == "claims"
}

// TestSemanticClaimsOneofExceptionIsNarrow controls that predicate against a descriptor carrying
// a SECOND oneof and a proto3-`optional` field.
//
// The `opt_field` member is a REAL proto3 optional -- declared with Proto3Optional and its own
// synthetic single-member oneof -- so it exercises the IsSynthetic half of the predicate. An
// ordinary field with no oneof index, which an earlier version of this control used, is not a
// proto3 optional at all and proved nothing about that half.
//
// THE CAPABILITY HAS NEITHER TODAY, so widening the exception back to "any containing oneof"
// changes no result and no mutation of the live schema can expose it -- measured. The control
// is what makes the restriction provable now rather than the next time the message grows.
func TestSemanticClaimsOneofExceptionIsNarrow(t *testing.T) {
	fdp := &descriptorpb.FileDescriptorProto{
		Name:    proto.String("semantic_oneof_control.proto"),
		Package: proto.String("semantic.control"),
		Syntax:  proto.String("proto3"),
		MessageType: []*descriptorpb.DescriptorProto{{
			Name: proto.String("Cap"),
			// THE THIRD ONEOF IS THE proto3-`optional` ONE. A proto3 optional field is encoded as
			// a SYNTHETIC single-member oneof, and it must be declared as such -- an ordinary
			// field with no oneof index is not one, and asserting over it would have proved
			// nothing about the synthetic case the exception has to exclude.
			OneofDecl: []*descriptorpb.OneofDescriptorProto{
				{Name: proto.String("claims")},
				{Name: proto.String("other")},
				{Name: proto.String("_opt_field")},
			},
			Field: []*descriptorpb.FieldDescriptorProto{
				{
					Name: proto.String("production"), Number: proto.Int32(1), OneofIndex: proto.Int32(0),
					Label: descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
					Type:  descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
				},
				{
					Name: proto.String("second_variant"), Number: proto.Int32(2), OneofIndex: proto.Int32(1),
					Label: descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
					Type:  descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
				},
				{
					Name: proto.String("opt_field"), Number: proto.Int32(3), OneofIndex: proto.Int32(2),
					Proto3Optional: proto.Bool(true),
					Label:          descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
					Type:           descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
				},
				{
					Name: proto.String("plain"), Number: proto.Int32(4),
					Label: descriptorpb.FieldDescriptorProto_LABEL_OPTIONAL.Enum(),
					Type:  descriptorpb.FieldDescriptorProto_TYPE_STRING.Enum(),
				},
			},
		}},
	}

	fd, err := protodesc.NewFile(fdp, nil)
	if err != nil {
		t.Fatalf("build the oneof control descriptor: %v", err)
	}

	fields := fd.Messages().Get(0).Fields()

	want := map[string]bool{"production": true, "second_variant": false, "opt_field": false, "plain": false}
	for i := range fields.Len() {
		f := fields.Get(i)

		if got := semIsClaimsOneofField(f); got != want[string(f.Name())] {
			t.Fatalf("%s: the claims exception returned %v, want %v -- a field outside the "+
				"`claims` oneof must be classified, not swallowed by the claims_framed edge",
				f.Name(), got, want[string(f.Name())])
		}
	}
}

// TestSemanticWireClassesMergeIndistinguishableWidths proves the classifier merges what the
// transcript cannot tell apart.
//
// THIS CANNOT BE PROVED BY MUTATING A FIXTURE, and that is a property of the guard rather than an
// omission. Splitting `i64` from `u64` is only observable if some fixture holds an i64 and a u64
// carrying the same value -- and the merged guard REJECTS exactly such a fixture, so the split
// stays invisible while the guard does its job. Measured: splitting the classes fails no row.
// The classifier is therefore asserted directly, on writes constructed to be indistinguishable.
func TestSemanticWireClassesMergeIndistinguishableWidths(t *testing.T) {
	// i64 is written as u64(uint64(v)) and str as bytes([]byte(s)); the transcript keeps no
	// record of which Go method produced the bytes.
	c := &edgev1.EdgeSourceClaimsV1{
		CollectionNotBeforeUnixNano: 42, // i64
		RunShard:                    42, // u64
		ContextId:                   []byte("abcd"),
	}

	var writes []semWrite

	semFlatWrites(t, c.ProtoReflect(), "", &writes)

	byLabel := map[string]semWrite{}
	for _, w := range writes {
		byLabel[w.label] = w
	}

	i64, u64 := byLabel["collection_not_before_unix_nano"], byLabel["run_shard"]

	if i64.class != u64.class || i64.value != u64.value {
		t.Fatalf("an i64 and a u64 holding the same value must be ONE class carrying one value, "+
			"got {%s %s} and {%s %s} -- split like that, swapping them would be reported as "+
			"detectable when the transcript cannot see it", i64.class, i64.value, u64.class, u64.value)
	}

	// And length-prefixed writes are classed by PAYLOAD LENGTH, which is what the transcript
	// actually shows, not by whether the field was declared string or bytes.
	s := &edgev1.EdgeOutputContractRef{ContractId: "abcd"}

	var swrites []semWrite

	semFlatWrites(t, s.ProtoReflect(), "", &swrites)

	var str semWrite

	for _, w := range swrites {
		if w.label == "contract_id" {
			str = w
		}
	}

	if str.class != byLabel["context_id"].class || str.value != byLabel["context_id"].value {
		t.Fatalf("a str and a bytes write of the same payload must be ONE class, got {%s %s} "+
			"and {%s %s}", str.class, str.value, byLabel["context_id"].class, byLabel["context_id"].value)
	}

	// AND THE MIRROR'S OWN CLASSIFIER, which is what the record's signature guard consumes.
	// Asserting only the reflective walker left the mirror free to split them: measured, that
	// split failed no row, because a fixture holding the colliding pair is exactly what the
	// guard forbids.
	m := &semMirror{}
	m.u64("u", 42)
	m.i64("i", 42)
	m.bytes("b", []byte("abcd"))
	m.str("s", "abcd")

	if m.writes[0].class != m.writes[1].class || m.writes[0].value != m.writes[1].value {
		t.Fatalf("the mirror must class an i64 and a u64 of the same value alike, got {%s %s} "+
			"and {%s %s}", m.writes[0].class, m.writes[0].value, m.writes[1].class, m.writes[1].value)
	}

	if m.writes[2].class != m.writes[3].class || m.writes[2].value != m.writes[3].value {
		t.Fatalf("the mirror must class a str and a bytes write of the same payload alike, got "+
			"{%s %s} and {%s %s}", m.writes[2].class, m.writes[2].value,
			m.writes[3].class, m.writes[3].value)
	}

	if !bytes.Equal(m.writes[0].raw, m.writes[1].raw) || !bytes.Equal(m.writes[2].raw, m.writes[3].raw) {
		t.Fatal("the mirror's raw bytes must match too; a class that agrees while the bytes " +
			"differ would mean the mirror is not framing what production frames")
	}
}

// ---------------------------------------------------------------------------
// the ordered primitive mirror: bound to the preimage BYTE FOR BYTE
// ---------------------------------------------------------------------------

// semMirror records the grammar's primitives IN TRANSCRIPT ORDER, each with the exact bytes it
// contributes.
//
// THE WIDTH SUM WAS NOT A COMPLETENESS PROOF. Summing widths and comparing to the preimage length
// is blind to an EQUAL-WIDTH omission paired with an equal-width addition, and to any
// substitution at all -- two u64s swapped for two other u64s balance perfectly. Only reproducing
// the preimage BYTE FOR BYTE proves the inventory is the transcript, and that is what binds this
// mirror: it is a second statement of the grammar, worth nothing on its own, made worth something
// by being required to equal production output exactly.
type semMirror struct {
	writes []semWrite
}

func (m *semMirror) emit(class, value, label string, raw []byte) {
	m.writes = append(m.writes, semWrite{class: class, value: value, label: label, width: len(raw), raw: raw})
}

func (m *semMirror) u64(label string, v uint64) {
	d := newDigest()
	d.u64(v)
	m.emit("u64", strconv.FormatUint(v, 10), label, append([]byte(nil), d.buf...))
}

// konst emits a STRUCTURAL CONSTANT: the version prefix, or a oneof discriminant. Its value is
// fixed by the shape rather than carried from the payload.
func (m *semMirror) konst(label string, v uint64) {
	m.u64(label, v)
	m.writes[len(m.writes)-1].konst = true
}

func (m *semMirror) i64(label string, v int64) { m.u64(label, uint64(v)) }

func (m *semMirror) bytes(label string, b []byte) {
	d := newDigest()
	d.bytes(b)
	m.emit(fmt.Sprintf("len:%d", len(b)), hex.EncodeToString(b), label, append([]byte(nil), d.buf...))
}

func (m *semMirror) str(label string, s string) { m.bytes(label, []byte(s)) }

func (m *semMirror) present(label string, p bool) {
	d := newDigest()
	d.present(p)
	m.emit("marker", "", label, append([]byte(nil), d.buf...))
}

func (m *semMirror) optU64(label string, v uint64, present bool) {
	m.present(label+".optU64", present)
	m.u64(label, v)

	// AN ABSENT optU64 WRITES A FORCED ZERO. The getter returns the zero value, so the write does
	// not carry a payload value at all in that state -- it is as structural as a discriminant,
	// and no fixture of a shape that omits the field can make it anything else.
	if !present {
		m.writes[len(m.writes)-1].konst = true
	}
}

func (m *semMirror) outputContract(p string, c *edgev1.EdgeOutputContractRef, present bool) {
	m.present(p+".present", present)

	if !present || c == nil {
		return
	}

	m.str(p+".contract_id", c.GetContractId())
	m.u64(p+".contract_version", uint64(c.GetContractVersion()))
	m.bytes(p+".contract_bundle_sha256", c.GetContractBundleSha256())
	m.u64(p+".registry_epoch", c.GetRegistryEpoch())
	m.bytes(p+".registry_snapshot_sha256", c.GetRegistrySnapshotSha256())
	m.bytes(p+".effective_grant_sha256", c.GetEffectiveGrantSha256())
}

func (m *semMirror) producerContext(p string, c *edgev1.EdgeProducerContext, present bool) {
	m.present(p+".present", present)

	if !present || c == nil {
		return
	}

	m.u64(p+".origin_kind", uint64(c.GetOriginKind()))
	m.bytes(p+".origin_principal_id", c.GetOriginPrincipalId())
	m.bytes(p+".producer_instance_id", c.GetProducerInstanceId())
	m.bytes(p+".producer_assignment_id", c.GetProducerAssignmentId())
	m.bytes(p+".run_id", c.GetRunId())
	m.u64(p+".run_shard", uint64(c.GetRunShard()))
	m.optU64(p+".authority_epoch", c.GetAuthorityEpoch(), c.AuthorityEpoch != nil)
	m.bytes(p+".scope_id", c.GetScopeId())
	m.bytes(p+".scope_sha256", c.GetScopeSha256())
	m.str(p+".package_id", c.GetPackageId())
	m.bytes(p+".package_sha256", c.GetPackageSha256())
}

func (m *semMirror) capability(p string, c *edgev1.EdgeSignedCapabilityV1, present bool) {
	m.present(p+".present", present)

	if !present || c == nil {
		return
	}

	m.u64(p+".capability_version", uint64(c.GetCapabilityVersion()))
	m.bytes(p+".issuer_id", c.GetIssuerId())
	m.bytes(p+".issuer_key_id", c.GetIssuerKeyId())
	m.str(p+".algorithm", c.GetAlgorithm())
	m.i64(p+".not_before_unix_nano", c.GetNotBeforeUnixNano())
	m.i64(p+".expires_at_unix_nano", c.GetExpiresAtUnixNano())
	m.claimsFramed(p+".claims", c)
	m.bytes(p+".signature", c.GetSignature())
}

func (m *semMirror) claimsFramed(p string, c *edgev1.EdgeSignedCapabilityV1) {
	switch cl := c.GetClaims().(type) {
	case *edgev1.EdgeSignedCapabilityV1_Production:
		m.konst(p+".discriminant", 7)
		m.productionClaims(p+".production", cl.Production)
	case *edgev1.EdgeSignedCapabilityV1_Source:
		m.konst(p+".discriminant", 8)
		m.sourceClaims(p+".source", cl.Source)
	case *edgev1.EdgeSignedCapabilityV1_Delivery:
		m.konst(p+".discriminant", 9)
		m.deliveryClaims(p+".delivery", cl.Delivery)
	case *edgev1.EdgeSignedCapabilityV1_Collection:
		m.konst(p+".discriminant", 11)
		m.collectionClaims(p+".collection", cl.Collection)
	case *edgev1.EdgeSignedCapabilityV1_AssignmentExecution:
		m.konst(p+".discriminant", 12)
		m.executionGrantClaims(p+".assignment_execution", cl.AssignmentExecution)
	default:
		m.konst(p+".discriminant", 0)
	}
}

func (m *semMirror) sourceAuth(p string, sa *edgev1.EdgeSourceAuthorizationV1, present bool) {
	m.present(p+".present", present)

	if !present || sa == nil {
		return
	}

	m.u64(p+".kind", uint64(sa.GetKind()))
	m.capability(p+".capability", sa.GetCapability(), sa.GetCapability() != nil)
	m.bytes(p+".context_id", sa.GetContextId())
	m.bytes(p+".scope_id", sa.GetScopeId())
	m.bytes(p+".scope_sha256", sa.GetScopeSha256())
}

func (m *semMirror) collectionClaims(p string, c *edgev1.EdgeCollectionClaimsV1) {
	m.u64(p+".purpose", uint64(c.GetPurpose()))
	m.bytes(p+".network_scope_id", c.GetNetworkScopeId())
	m.bytes(p+".authenticated_agent_id", c.GetAuthenticatedAgentId())
	m.bytes(p+".execution_plan_id", c.GetExecutionPlanId())
	m.bytes(p+".target_range_id", c.GetTargetRangeId())
	m.u64(p+".execution_shard", uint64(c.GetExecutionShard()))
	m.u64(p+".assignment_epoch", c.GetAssignmentEpoch())
	m.bytes(p+".compiled_assignment_body_sha256", c.GetCompiledAssignmentBodySha256())
	m.u64(p+".traffic_class", uint64(c.GetTrafficClass()))
	m.bytes(p+".producer_assignment_id", c.GetProducerAssignmentId())
	m.bytes(p+".execution_id", c.GetExecutionId())
}

func (m *semMirror) productionClaims(p string, c *edgev1.EdgeProductionClaimsV1) {
	m.str(p+".contract_id", c.GetContractId())
	m.u64(p+".contract_version", uint64(c.GetContractVersion()))
	m.bytes(p+".contract_bundle_sha256", c.GetContractBundleSha256())
	m.u64(p+".registry_epoch", c.GetRegistryEpoch())
	m.bytes(p+".network_scope_id", c.GetNetworkScopeId())
	m.bytes(p+".producer_assignment_id", c.GetProducerAssignmentId())
	m.u64(p+".traffic_class", uint64(c.GetTrafficClass()))
	m.u64(p+".route_profile", uint64(c.GetRouteProfile()))
	m.u64(p+".origin_kind", uint64(c.GetOriginKind()))
	m.bytes(p+".origin_principal_id", c.GetOriginPrincipalId())
	m.bytes(p+".producer_instance_id", c.GetProducerInstanceId())
	m.bytes(p+".run_id", c.GetRunId())
	m.u64(p+".run_shard", uint64(c.GetRunShard()))
	m.u64(p+".authority_epoch", c.GetAuthorityEpoch())
	m.bytes(p+".scope_id", c.GetScopeId())
	m.bytes(p+".scope_sha256", c.GetScopeSha256())
	m.bytes(p+".package_sha256", c.GetPackageSha256())
	m.bytes(p+".registry_snapshot_sha256", c.GetRegistrySnapshotSha256())
	m.bytes(p+".effective_grant_sha256", c.GetEffectiveGrantSha256())
	m.u64(p+".max_projected_row_count", uint64(c.GetMaxProjectedRowCount()))
	m.u64(p+".max_projected_write_bytes", c.GetMaxProjectedWriteBytes())
	m.u64(p+".cost_model_version", uint64(c.GetCostModelVersion()))
	m.str(p+".package_id", c.GetPackageId())
}

func (m *semMirror) sourceClaims(p string, c *edgev1.EdgeSourceClaimsV1) {
	m.u64(p+".kind", uint64(c.GetKind()))
	m.bytes(p+".context_id", c.GetContextId())
	m.bytes(p+".scope_id", c.GetScopeId())
	m.bytes(p+".scope_sha256", c.GetScopeSha256())
	m.bytes(p+".network_scope_id", c.GetNetworkScopeId())
	m.i64(p+".collection_not_before_unix_nano", c.GetCollectionNotBeforeUnixNano())
	m.i64(p+".collection_expires_unix_nano", c.GetCollectionExpiresUnixNano())
	m.bytes(p+".origin_principal_id", c.GetOriginPrincipalId())
	m.bytes(p+".producer_instance_id", c.GetProducerInstanceId())
	m.bytes(p+".producer_assignment_id", c.GetProducerAssignmentId())
	m.bytes(p+".run_id", c.GetRunId())
	m.u64(p+".run_shard", uint64(c.GetRunShard()))
	m.u64(p+".authority_epoch", c.GetAuthorityEpoch())
	m.u64(p+".traffic_class", uint64(c.GetTrafficClass()))
	m.u64(p+".route_profile", uint64(c.GetRouteProfile()))
	m.bytes(p+".execution_plan_sha256", c.GetExecutionPlanSha256())
	m.bytes(p+".target_range_sha256", c.GetTargetRangeSha256())
	m.u64(p+".origin_kind", uint64(c.GetOriginKind()))
}

func (m *semMirror) deliveryClaims(p string, c *edgev1.EdgeDeliveryClaimsV1) {
	m.bytes(p+".event_id", c.GetEventId())
	m.bytes(p+".record_sha256", c.GetRecordSha256())
	m.bytes(p+".spool_id", c.GetSpoolId())
	m.u64(p+".sequence", c.GetSequence())

	switch tr := c.GetTransition().(type) {
	case *edgev1.EdgeDeliveryClaimsV1_Renewal:
		m.konst(p+".transition.discriminant", 5)
		m.i64(p+".transition.renewal.renewed_not_before_unix_nano", tr.Renewal.GetRenewedNotBeforeUnixNano())
		m.i64(p+".transition.renewal.renewed_expires_unix_nano", tr.Renewal.GetRenewedExpiresUnixNano())
	case *edgev1.EdgeDeliveryClaimsV1_Rollover:
		m.konst(p+".transition.discriminant", 6)
		m.bytes(p+".transition.rollover.recovery_id", tr.Rollover.GetRecoveryId())
		m.bytes(p+".transition.rollover.prior_spool_id", tr.Rollover.GetPriorSpoolId())
		m.u64(p+".transition.rollover.prior_sequence", tr.Rollover.GetPriorSequence())
	default:
		m.konst(p+".transition.discriminant", 0)
	}
}

func (m *semMirror) executionGrantClaims(p string, c *edgev1.EdgeAssignmentExecutionClaimsV1) {
	m.u64(p+".purpose", uint64(c.GetPurpose()))
	m.bytes(p+".network_scope_id", c.GetNetworkScopeId())
	m.bytes(p+".authenticated_agent_id", c.GetAuthenticatedAgentId())
	m.bytes(p+".producer_assignment_id", c.GetProducerAssignmentId())
	m.bytes(p+".execution_id", c.GetExecutionId())
	m.bytes(p+".run_id", c.GetRunId())
	m.u64(p+".run_shard", uint64(c.GetRunShard()))
	m.u64(p+".authority_epoch", c.GetAuthorityEpoch())
	m.bytes(p+".production_scope_id", c.GetProductionScopeId())
	m.bytes(p+".scope_sha256", c.GetScopeSha256())
	m.bytes(p+".contract_bundle_sha256", c.GetContractBundleSha256())
	m.bytes(p+".execution_plan_sha256", c.GetExecutionPlanSha256())
	m.bytes(p+".target_range_sha256", c.GetTargetRangeSha256())
	m.u64(p+".traffic_class", uint64(c.GetTrafficClass()))
	m.i64(p+".collection_not_before_unix_nano", c.GetCollectionNotBeforeUnixNano())
	m.i64(p+".collection_expires_unix_nano", c.GetCollectionExpiresUnixNano())

	id := c.GetSourceIdentity()
	m.present(p+".source_identity.present", id != nil)

	if id != nil {
		m.u64(p+".source_identity.kind", uint64(id.GetKind()))
		m.bytes(p+".source_identity.context_id", id.GetContextId())
		m.bytes(p+".source_identity.source_scope_id", id.GetSourceScopeId())
		m.bytes(p+".source_identity.source_scope_sha256", id.GetSourceScopeSha256())
	}

	m.bytes(p+".compiled_assignment_id", c.GetCompiledAssignmentId())
	m.bytes(p+".compiled_assignment_sha256", c.GetCompiledAssignmentSha256())
}

// semRecordOrderedWrites mirrors the ROOT transcript in order.
func semRecordOrderedWrites(r *edgev1.EdgeRecordV1) []semWrite {
	m := &semMirror{}

	m.konst("version", semanticDigestVersion)
	m.bytes("01.event_id", r.GetEventId())
	m.u64("02.payload_family", uint64(r.GetPayloadFamily()))
	m.u64("03.compression", uint64(r.GetCompression()))
	m.u64("04.encoded_size", uint64(r.GetEncodedSize()))
	m.u64("05.uncompressed_size", uint64(r.GetUncompressedSize()))
	m.bytes("06.payload_sha256", r.GetPayloadSha256())
	m.outputContract("07.output_contract", r.GetOutputContract(), r.GetOutputContract() != nil)
	m.producerContext("08.producer_context", r.GetProducerContext(), r.GetProducerContext() != nil)
	m.u64("09.route_profile", uint64(r.GetRouteProfile()))
	m.u64("10.traffic_class", uint64(r.GetTrafficClass()))
	m.bytes("11.network_scope_id", r.GetNetworkScopeId())
	m.capability("12.production_capability", r.GetProductionCapability(), r.GetProductionCapability() != nil)
	m.sourceAuth("13.source_authorization", r.GetSourceAuthorization(), r.GetSourceAuthorization() != nil)
	m.u64("14.projected_row_count", uint64(r.GetProjectedRowCount()))
	m.u64("15.projected_write_bytes", r.GetProjectedWriteBytes())
	m.u64("16.cost_model_version", uint64(r.GetCostModelVersion()))

	return m.writes
}

// TestSemanticOrderedMirrorReproducesThePreimage BINDS the mirror byte for byte.
//
// Every collision and ordering conclusion below rests on "these are exactly the writes, in
// exactly this order". The width sum this replaces could not see an equal-width omission paired
// with an equal-width addition, nor any substitution at all. Byte equality can see all of them,
// and it is checked for EVERY committed variant AND for the record shapes the state rows use, so
// a branch the mirror gets wrong cannot hide in an unexercised shape.
func TestSemanticOrderedMirrorReproducesThePreimage(t *testing.T) {
	shapes := map[string]*edgev1.EdgeRecordV1{}

	for _, shape := range semShapes {
		for v := range semRecordVariants {
			shapes[fmt.Sprintf("%s.v%d", shape, v)] = semShapeRecord(t, shape, v)
		}
	}

	for name, r := range shapes {
		var mirrored []byte
		for _, w := range semRecordOrderedWrites(r) {
			mirrored = append(mirrored, w.raw...)
		}

		var preimage []byte
		for _, c := range semRootChunks(t, r) {
			preimage = append(preimage, c.bytes...)
		}

		if !bytes.Equal(mirrored, preimage) {
			t.Fatalf("%s: the ordered mirror does not reproduce the preimage byte for byte, so it "+
				"is not this grammar and nothing may be concluded from it\n  mirrored %d bytes\n"+
				"  preimage %d bytes", name, len(mirrored), len(preimage))
		}
	}
}

// ---------------------------------------------------------------------------
// record SHAPES: every structurally distinct whole-record transcript
// ---------------------------------------------------------------------------

// semShapes are the whole-record shapes the grammar can produce.
//
// A FROZEN DIGEST PER SHAPE IS NOT ORDER EVIDENCE. Reconstructing a shape byte for byte proves
// the mirror agrees with production for it; it says nothing about whether two writes INSIDE that
// shape are exchangeable. The base record was the only shape whose positions were separated, so
// a swap CONDITIONED on any other shape -- `payload_family` against `compression` only when the
// capability carries `collection`, where both values are zero -- moved no byte in any committed
// fixture and failed nothing. Measured before this list existed.
//
// So every shape is a first-class fixture: built at EVERY variant, signature-guarded like the
// base, mirrored, and committed.
// semCarrierStates are the states ONE capability carrier can be in: absent, or present carrying
// one claims discriminant -- refined by the delivery transition oneof and the execution grant's
// source-identity presence, which are themselves declared axes.
//
//nolint:gochecknoglobals // immutable declared axis
var semCarrierStates = []string{
	"absent", "production", "source", "collection", "unset",
	"delivery", "delivery.renewal", "delivery.rollover",
	"assignment", "assignment.no_identity",
}

// semShapes is the FULL CROSS PRODUCT OF THE DECLARED STRUCTURAL AXES, enumerated mechanically.
//
// THE HAND-PICKED MATRIX DID NOT CONVERGE. Five rounds each found a reordering conditioned on
// some state no fixture held -- a claims variant, a carrier, a PAIR of carriers -- and each round
// added the missing case. That regress has no end while the grammar may branch on anything: the
// space of predicates is unbounded, so no finite fixture set is complete against it.
//
// SO THE MATRIX IS ENUMERATED FROM THE DECLARED AXES rather than chosen, and it is exhaustive
// OVER THOSE AXES -- not over every program the host languages can express. The static guards
// that keep framing order on those axes are DEFENSE-IN-DEPTH REGRESSION CHECKS with known limits:
// Go's accessor identity is name-based, and Elixir's does not resolve function heads, guards,
// macros or remote calls. This matrix is exhaustive against the DECLARED grammar, not against an
// arbitrary rewrite of it:
//
//	output_contract presence            2
//	producer_context presence           2, and its optional authority_epoch when present -> 3
//	production capability              10 states
//	source_authorization               11: absent, or present with its capability in 10 states
//
// 2 x 3 x 10 x 11 = 660, plus the base record whose claims come from the generator rather than a
// spliced baseline. This says every combination of what the grammar DECLARES it branches on is
// committed. The static guard is a separate, weaker thing -- it checks that the framers keep that
// shape, and does NOT establish that nothing else can branch; its holes are named on it.
//
//nolint:gochecknoglobals // immutable enumerated axis product
var semShapes = semBuildShapes()

// errUnreadCommittedVectors reports vectors present in the committed manifest that no test in
// this runtime asserted. They are frozen values that cannot fail and so cannot catch a
// divergence -- evidence that looks committed and proves nothing.
var errUnreadCommittedVectors = errors.New("committed vectors are asserted by NO test in this runtime")

// The capacity is deliberately not preallocated: the epoch axis is one element or two
// depending on the production-capability bit, so a single capacity expression would be a second,
// wrong statement of the product.
//
//nolint:prealloc // state-dependent axis length; see above
func semBuildShapes() []string {
	out := []string{"base"}

	for _, oc := range []string{"1", "0"} {
		for _, pc := range []string{"1", "0"} {
			epochs := []string{"-"}
			if pc == "1" {
				epochs = []string{"1", "0"}
			}

			for _, ep := range epochs {
				for _, production := range semCarrierStates {
					for _, nested := range append([]string{"sa_absent"}, semCarrierStates...) {
						out = append(out, fmt.Sprintf("oc%s|pc%s|ep%s|p-%s|n-%s",
							oc, pc, ep, production, nested))
					}
				}
			}
		}
	}

	return out
}

// semShapeRecord builds one shape at one variant. Every shape is a STRUCTURAL edit of the
// generated record plus, where a claim is spliced, a COMMITTED baseline -- so the peer can
// reproduce each shape from artifacts it already decodes rather than needing one per shape.
func semShapeRecord(t *testing.T, shape string, variant int) *edgev1.EdgeRecordV1 {
	t.Helper()

	r := proto.Clone(semDeterministicRecordVariant(t, variant)).(*edgev1.EdgeRecordV1)

	if shape != "base" {
		semApplyAxes(t, r, shape, variant)

		r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

		return r
	}

	// FIELD 17 IS RESEALED for every shape. It is excluded from the transcript, so a stale value
	// leaves the digest stable while the record BYTES vary -- and the peer decodes those bytes.
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

	return r
}

// semRenewal and semRollover carry values chosen to sit OUTSIDE the generated scalar spaces: the
// record's u64 writes are seed*1000 with a byte seed, so nothing it holds can reach 10^15, and
// its i64 writes are seed*7e6. A `prior_sequence` of 7 would have collided with the `production`
// claims discriminant, which is a real position in the same transcript.
func semRenewal(carrier string) *edgev1.EdgeDeliveryRenewalV1 {
	// PER CARRIER, because both can hold a renewal at once in the cross product and equal values
	// across the two would be exchangeable.
	if carrier != "production" {
		return &edgev1.EdgeDeliveryRenewalV1{
			RenewedNotBeforeUnixNano: 2_100_000_000_000_000_000,
			RenewedExpiresUnixNano:   2_300_000_000_000_000_000,
		}
	}

	return &edgev1.EdgeDeliveryRenewalV1{
		RenewedNotBeforeUnixNano: 1_700_000_000_000_000_000,
		RenewedExpiresUnixNano:   1_900_000_000_000_000_000,
	}
}

func semRollover(carrier string) *edgev1.EdgeDeliveryRolloverV1 {
	if carrier != "production" {
		return &edgev1.EdgeDeliveryRolloverV1{
			RecoveryId:    bytes.Repeat([]byte{0x63}, 16),
			PriorSpoolId:  bytes.Repeat([]byte{0x64}, 16),
			PriorSequence: 800_000_000_000_009,
		}
	}

	return &edgev1.EdgeDeliveryRolloverV1{
		RecoveryId:    bytes.Repeat([]byte{0x61}, 16),
		PriorSpoolId:  bytes.Repeat([]byte{0x62}, 16),
		PriorSequence: 700_000_000_000_007,
	}
}

// TestSemanticShapeVectors freezes every shape at every variant.
func TestSemanticShapeVectors(t *testing.T) {
	for _, shape := range semShapes {
		for v := range semRecordVariants {
			key := fmt.Sprintf("root.shape.%s.v%d", shape, v)

			want, ok := semVectorFor(t, key)
			if !ok {
				t.Fatalf("no committed vector for shape %s", key)
			}

			if got := hex.EncodeToString(SemanticEnvelopeDigest(semShapeRecord(t, shape, v))); got != want {
				t.Fatalf("%s: digest moved.\n  committed %s\n  computed  %s", key, want, got)
			}
		}
	}
}

// TestSemanticShapesAreDistinct proves no two DISTINCT shapes are the same transcript.
//
// Without it a shape could silently degenerate into another -- a structural edit that did not
// take, or a claims variant that framed identically -- and its vectors would still pass while
// covering nothing new.
//
// THE COMPARISON IS BETWEEN SHAPES, NOT BETWEEN VARIANTS OF ONE SHAPE. Two variants of the same
// shape may legitimately coincide: the shape with no producer context and neither capability
// carries only four enum writes, and two variants assign them the same values. That is not
// redundant coverage, it is a shape with little to vary; whether its positions are separable is
// the collision guard's question, and it is asked per shape across variants.
func TestSemanticShapesAreDistinct(t *testing.T) {
	seen := map[string]string{}

	for _, shape := range semShapes {
		sig := make([]string, 0, semRecordVariants)

		for v := range semRecordVariants {
			sig = append(sig, hex.EncodeToString(SemanticEnvelopeDigest(semShapeRecord(t, shape, v))))
		}

		key := strings.Join(sig, ",")

		if prior, dup := seen[key]; dup {
			t.Fatalf("shapes %s and %s frame identically at every variant, so one of them covers "+
				"nothing", prior, shape)
		}

		seen[key] = shape
	}
}

// semVerifyEveryVectorWasRead is THIS runtime's exact key-set guard, run after the whole package.
//
// THE PEER HAD ONE AND THIS RUNTIME DID NOT, which is how a committed variant came to be asserted
// by Elixir and only INDIRECTLY frozen here, through the record artifact -- so the shared-vector
// parity the ledger claims did not hold for it. It checks READS, not a hand-written list: a list
// passes whether or not anything asserts the keys on it, measured.
func semVerifyEveryVectorWasRead() error {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "proto", "edge", "v1",
		"testdata", "semantic_envelope_vectors.txt"))
	if err != nil {
		return fmt.Errorf("read committed vectors: %w", err)
	}

	var unread []string

	sc := bufio.NewScanner(bytes.NewReader(raw))

	// A DEFAULT Scanner GIVES UP AT 64 KiB AND SAYS SO ONLY THROUGH Err(). Ignoring that made this
	// guard FAIL OPEN: one over-long row -- an unasserted vector among them -- stopped the scan
	// and every remaining key silently counted as read. The buffer is raised to the whole file and
	// the error is checked below.
	sc.Buffer(make([]byte, 0, 64*1024), len(raw)+1)

	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		key := strings.Fields(line)[0]
		if !semVectorReads[key] {
			unread = append(unread, key)
		}
	}

	if err := sc.Err(); err != nil {
		return fmt.Errorf("scan committed vectors: %w", err)
	}

	if len(unread) > 0 {
		sort.Strings(unread)

		return fmt.Errorf("%w: %d of them: %v", errUnreadCommittedVectors, len(unread), unread)
	}

	return nil
}

func TestMain(m *testing.M) {
	code := m.Run()

	// NO READS AT ALL means the vector tests were FILTERED OUT of this run -- `-run` selecting an
	// unrelated test, say -- not that the committed vectors go unasserted. Demanding all of them
	// there broke every filtered invocation of this package.
	if code == 0 && len(semVectorReads) > 0 {
		if err := semVerifyEveryVectorWasRead(); err != nil {
			fmt.Fprintln(os.Stderr, "FAIL: semantic-envelope vector consumption:", err)

			code = 1
		}
	}

	os.Exit(code)
}

// semApplyCarrierState puts ONE capability carrier into one state. Both carriers go through it,
// which is what makes the cross product mechanical rather than a second hand-written matrix.
func semApplyCarrierState(t *testing.T, r *edgev1.EdgeRecordV1, carrier, state string, variant int) {
	t.Helper()

	if state == "absent" {
		if carrier == "production" {
			r.ProductionCapability = nil
		} else {
			r.GetSourceAuthorization().Capability = nil
		}

		return
	}

	c := r.GetProductionCapability()
	if carrier != "production" {
		c = r.GetSourceAuthorization().GetCapability()
	}

	if c == nil {
		t.Fatalf("carrier %q has no capability to put into state %q", carrier, state)
	}

	switch state {
	case "delivery.renewal", "delivery.rollover":
		d := proto.Clone(semBaselineFrom(t, "delivery_claims", carrier, variant)).(*edgev1.EdgeDeliveryClaimsV1)
		if state == "delivery.renewal" {
			d.Transition = &edgev1.EdgeDeliveryClaimsV1_Renewal{Renewal: semRenewal(carrier)}
		} else {
			d.Transition = &edgev1.EdgeDeliveryClaimsV1_Rollover{Rollover: semRollover(carrier)}
		}

		c.Claims = &edgev1.EdgeSignedCapabilityV1_Delivery{Delivery: d}
	case "assignment.no_identity":
		e := proto.Clone(semBaselineFrom(t, "execution_grant_claims", carrier, variant)).(*edgev1.EdgeAssignmentExecutionClaimsV1)
		e.SourceIdentity = nil

		c.Claims = &edgev1.EdgeSignedCapabilityV1_AssignmentExecution{AssignmentExecution: e}
	case "assignment":
		semSetClaimsFrom(t, c, "assignment_execution", carrier, variant)
	default:
		semSetClaimsFrom(t, c, state, carrier, variant)
	}
}

// semApplyAxes puts a record into one enumerated structural state.
func semApplyAxes(t *testing.T, r *edgev1.EdgeRecordV1, shape string, variant int) {
	t.Helper()

	parts := strings.Split(shape, "|")
	if len(parts) != 5 {
		t.Fatalf("shape %q is not oc|pc|ep|p-|n-", shape)
	}

	if parts[0] == "oc0" {
		r.OutputContract = nil
	}

	if parts[1] == "pc0" {
		r.ProducerContext = nil
	} else if parts[2] == "ep0" {
		r.GetProducerContext().AuthorityEpoch = nil
	}

	production, ok := strings.CutPrefix(parts[3], "p-")
	if !ok {
		t.Fatalf("shape %q has no production axis", shape)
	}

	semApplyCarrierState(t, r, "production", production, variant)

	nested, ok := strings.CutPrefix(parts[4], "n-")
	if !ok {
		t.Fatalf("shape %q has no nested axis", shape)
	}

	if nested == "sa_absent" {
		r.SourceAuthorization = nil

		return
	}

	semApplyCarrierState(t, r, "nested", nested, variant)
}
