package edgerecord

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The OPTIONAL-PRESENCE corpus (task 1.5-d): absent versus present-zero, for every explicitly
// optional scalar in the edge ABI.
//
// ## Why presence is a wire contract and not a detail
//
// An explicit proto3 `optional` scalar is distinguishable on the wire in both states: absent
// emits nothing, present-zero emits a tag and a zero. Preserving that distinction is the rule;
// what it MEANS is per field, and this ABI carries two kinds.
//
// FIFTEEN are MEASUREMENTS, where absent means "not measured" and present-zero means "measured,
// and the answer was zero". THREE are required AUTHORITY AND WINDOW statements --
// authority_epoch, plan_ordinal_offset, mtr_ordinal_count -- which are optional in the schema so
// that absent is distinguishable from zero, NOT so they may be omitted; their consumers refuse
// them absent. Calling all eighteen measurements would freeze the wrong rule for those three.
//
// A DECODE-SIDE COLLAPSE IS INVISIBLE TO EVERY DIGEST, and that is the risk this corpus exists
// for. Whether presence is COMMITTED is carrier-specific -- the semantic transcript frames
// authority_epoch's presence directly, and a payload-carried field's presence changes
// payload_sha256 -- so a PRODUCER that drops a zero emits a different, self-consistent artifact.
// What no digest can see is a READER that coerces after verifying: the bytes and every digest
// over them stay valid while the decoded meaning is gone.
//
// ## The inventory is DESCRIPTOR-PINNED, not hand-maintained
//
// An explicit `optional` scalar in proto3 is exactly a field whose containing oneof is
// SYNTHETIC, so the complete set is derivable from the generated descriptors. The hand-written
// tables below are compared against that walk in BOTH directions, which is what makes the
// coverage claim self-maintaining: a new optional field added to any edge message fails this
// test until it is placed in scope or explicitly excluded with a reason.
//
// A hand list alone cannot do that. This inventory was in fact drafted twice by hand, at 12
// fields and then at 17; the descriptor says 18 scalars across 8 carriers, and both hand counts
// were wrong in different directions.

// optionalScalarInventory is every explicitly optional SCALAR field, mapped to the carrier that
// holds it. Checked against the descriptor walk below.
//
//nolint:gochecknoglobals // frozen inventory, not state
var optionalScalarInventory = map[string]string{
	// The one envelope-carried optional: its presence is framed by the semantic transcript.
	"EdgeProducerContext.authority_epoch": "EdgeProducerContext",

	// The MTR per-hop measurements, whose proto comment states the rule outright.
	"MtrTraceHopV1.last_micro":                "MtrTraceHopV1",
	"MtrTraceHopV1.avg_micro":                 "MtrTraceHopV1",
	"MtrTraceHopV1.min_micro":                 "MtrTraceHopV1",
	"MtrTraceHopV1.max_micro":                 "MtrTraceHopV1",
	"MtrTraceHopV1.stddev_micro":              "MtrTraceHopV1",
	"MtrTraceHopV1.jitter_micro":              "MtrTraceHopV1",
	"MtrTraceHopV1.jitter_worst_micro":        "MtrTraceHopV1",
	"MtrTraceHopV1.jitter_interarrival_micro": "MtrTraceHopV1",

	// SINT64, so a present zero is ONE byte of payload. A width-specific coercion would show
	// up here and nowhere else.
	"SweepHostObservationV1.first_seen_delta_nano": "SweepHostObservationV1",
	"SweepHostObservationV1.last_seen_delta_nano":  "SweepHostObservationV1",

	// DOUBLE, so a present zero is eight bytes of zeros -- the encoding most likely to be
	// mistaken for absence by a hand-rolled reader.
	"SweepIcmpSummaryV1.packet_loss_pct": "SweepIcmpSummaryV1",
	"SweepMtrSummaryV1.packet_loss_pct":  "SweepMtrSummaryV1",

	"SweepIcmpSummaryV1.round_trip_micro":       "SweepIcmpSummaryV1",
	"SweepMtrSummaryV1.final_rtt_micro":         "SweepMtrSummaryV1",
	"SweepOpenPortV1.response_time_nano":        "SweepOpenPortV1",
	"SweepMtrExpectationV1.plan_ordinal_offset": "SweepMtrExpectationV1",
	"TargetRangeV1.mtr_ordinal_count":           "TargetRangeV1",
}

// optionalMessageOutOfScope is every explicitly optional MESSAGE field, with the reason it is
// not a member of this task.
//
// They are recorded rather than omitted: an unlisted obligation is how a gap ships inside a
// freeze. Their presence question is real but different -- an absent submessage versus a
// present-but-default one is not a MEASUREMENT that was or was not taken, and each already has
// its own normative statement (`absent = no source authorization`, the renewable delivery
// capability, and the three per-protocol summaries whose absence means the protocol was not
// run).
//
//nolint:gochecknoglobals // frozen inventory, not state
var optionalMessageOutOfScope = map[string]string{
	"EdgeRecordV1.source_authorization":       "absence is normative: no source authorization",
	"EdgeDeliveryFrameV1.delivery_capability": "renewable drain authority; absence is a lane state",
	"SweepHostObservationV1.icmp":             "absence means the protocol was not run",
	"SweepHostObservationV1.tcp":              "absence means the protocol was not run",
	"SweepHostObservationV1.mtr":              "absence means the protocol was not run",
}

// descriptorOptionalFields walks the edge descriptors and returns every explicitly optional
// field, split by whether it is a scalar. In proto3 the `optional` keyword is implemented as a
// SYNTHETIC one-member oneof, so that -- not a naming convention -- is the test.
func descriptorOptionalFields(t *testing.T) (scalars, messages map[string]string) {
	t.Helper()

	scalars, messages = map[string]string{}, map[string]string{}

	var walk func(msgs protoreflect.MessageDescriptors)

	walk = func(msgs protoreflect.MessageDescriptors) {
		for i := 0; i < msgs.Len(); i++ {
			m := msgs.Get(i)

			for j := 0; j < m.Fields().Len(); j++ {
				f := m.Fields().Get(j)

				oo := f.ContainingOneof()
				if oo == nil || !oo.IsSynthetic() {
					continue
				}

				name := string(m.Name()) + "." + string(f.Name())

				if k := f.Kind(); k == protoreflect.MessageKind || k == protoreflect.GroupKind {
					messages[name] = string(m.Name())
				} else {
					scalars[name] = string(m.Name())
				}
			}

			walk(m.Messages())
		}
	}

	for _, fd := range []protoreflect.FileDescriptor{
		edgev1.File_edge_v1_record_proto, edgev1.File_edge_v1_sweep_proto,
	} {
		walk(fd.Messages())
	}

	return scalars, messages
}

// TestOptionalInventoryMatchesDescriptor is what makes "every optional field" checkable.
//
// A new `optional` on any edge message lands in the descriptor walk immediately; if it is not
// placed in the in-scope inventory or the recorded out-of-scope list, this fails. That is the
// difference between an inventory that is complete today and one that STAYS complete.
func TestOptionalInventoryMatchesDescriptor(t *testing.T) {
	scalars, messages := descriptorOptionalFields(t)

	compare := func(kind string, got, want map[string]string, carrier bool) {
		for name, gotCarrier := range got {
			wantCarrier, ok := want[name]
			if !ok {
				t.Errorf("%s %s is optional in the descriptor but appears in NO inventory", kind, name)

				continue
			}

			if carrier && wantCarrier != gotCarrier {
				t.Errorf("%s: inventory says carrier %s, the descriptor says %s",
					name, wantCarrier, gotCarrier)
			}
		}

		for name := range want {
			if _, ok := got[name]; !ok {
				t.Errorf("%s: the inventory names it, but it is not optional in the descriptor", name)
			}
		}
	}

	compare("scalar", scalars, optionalScalarInventory, true)
	compare("message", messages, optionalMessageOutOfScope, false)

	if t.Failed() {
		return
	}

	carriers := map[string]bool{}
	for _, c := range optionalScalarInventory {
		carriers[c] = true
	}

	names := make([]string, 0, len(carriers))
	for c := range carriers {
		names = append(names, c)
	}

	sort.Strings(names)

	// Derived and informational, AFTER membership -- a count cannot detect an omission, which
	// is precisely how this inventory was drafted wrong twice by hand.
	t.Logf("optional scalars: %d across %d carriers %v (plus %d optional messages, out of scope)",
		len(optionalScalarInventory), len(carriers), names, len(optionalMessageOutOfScope))
}

// ---- generic carrier surgery, driven by the descriptor ------------------------------------
//
// The optional scalars are SET and CLEARED reflectively rather than by eighteen hand-written
// assignments. Hand-written setters are a second copy of the inventory: they drift from the
// descriptor exactly as the hand-written counts did, and the drift is invisible because the
// setters are what the test then measures.

// zeroOf is the PRESENT-ZERO value for a scalar kind. Presence is what the corpus varies, so
// every present field carries the same value -- zero -- and only its presence differs.
func zeroOf(t *testing.T, fd protoreflect.FieldDescriptor) protoreflect.Value {
	t.Helper()

	//nolint:exhaustive // fail-closed: the default arm rejects any unlisted kind
	switch fd.Kind() {
	case protoreflect.Uint64Kind:
		return protoreflect.ValueOfUint64(0)
	case protoreflect.Sint64Kind, protoreflect.Int64Kind:
		return protoreflect.ValueOfInt64(0)
	case protoreflect.DoubleKind:
		return protoreflect.ValueOfFloat64(0)
	default:
		t.Fatalf("no present-zero defined for kind %v (%s)", fd.Kind(), fd.FullName())

		return protoreflect.Value{}
	}
}

// eachCarrier visits every instance of the named message inside msg, at any depth.
func eachCarrier(msg protoreflect.Message, carrier string, fn func(protoreflect.Message)) {
	if string(msg.Descriptor().Name()) == carrier {
		fn(msg)
	}

	msg.Range(func(fd protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		switch {
		case fd.IsList() && fd.Kind() == protoreflect.MessageKind:
			l := v.List()
			for i := 0; i < l.Len(); i++ {
				eachCarrier(l.Get(i).Message(), carrier, fn)
			}
		case fd.IsMap() && fd.MapValue().Kind() == protoreflect.MessageKind:
			v.Map().Range(func(_ protoreflect.MapKey, mv protoreflect.Value) bool {
				eachCarrier(mv.Message(), carrier, fn)

				return true
			})
		case !fd.IsList() && !fd.IsMap() && fd.Kind() == protoreflect.MessageKind:
			eachCarrier(v.Message(), carrier, fn)
		}

		return true
	})
}

// applyOptionals sets EVERY optional scalar on each instance of `carrier` to present-zero,
// except `omit`, which is CLEARED. omit == "" builds the all-present control.
func applyOptionals(t *testing.T, msg proto.Message, carrier, omit string) {
	t.Helper()

	touched := 0

	eachCarrier(msg.ProtoReflect(), carrier, func(m protoreflect.Message) {
		fields := m.Descriptor().Fields()

		for i := 0; i < fields.Len(); i++ {
			fd := fields.Get(i)

			oo := fd.ContainingOneof()
			if oo == nil || !oo.IsSynthetic() {
				continue
			}

			if k := fd.Kind(); k == protoreflect.MessageKind || k == protoreflect.GroupKind {
				continue
			}

			if string(fd.Name()) == omit {
				m.Clear(fd)
			} else {
				m.Set(fd, zeroOf(t, fd))
			}

			touched++
		}
	})

	if touched == 0 {
		t.Fatalf("carrier %s not found in %T; the vector would prove nothing",
			carrier, msg)
	}
}

// optionalPresenceOf reports, for the FIRST instance of `carrier`, which optional scalars are
// present and what each present one holds. Reflective for the same reason as the setter.
func optionalPresenceOf(
	t *testing.T, msg proto.Message, carrier string,
) (present map[string]bool, values map[string]string) {
	t.Helper()

	present, values = map[string]bool{}, map[string]string{}
	found := false

	eachCarrier(msg.ProtoReflect(), carrier, func(m protoreflect.Message) {
		if found {
			return
		}

		found = true
		fields := m.Descriptor().Fields()

		for i := 0; i < fields.Len(); i++ {
			fd := fields.Get(i)

			oo := fd.ContainingOneof()
			if oo == nil || !oo.IsSynthetic() {
				continue
			}

			if k := fd.Kind(); k == protoreflect.MessageKind || k == protoreflect.GroupKind {
				continue
			}

			name := string(fd.Name())
			present[name] = m.Has(fd)

			if m.Has(fd) {
				values[name] = m.Get(fd).String()
			}
		}
	})

	if !found {
		t.Fatalf("carrier %s not found while reading presence", carrier)
	}

	return present, values
}

// ---- the eight carriers -------------------------------------------------------------------
//
// ONE CONTROL PER CARRIER, with every optional scalar PRESENT-ZERO, and ONE VARIANT PER FIELD
// omitting exactly that field. Each manifest row is therefore a SINGLE-AXIS comparison.
//
// A pair that toggled a carrier's optionals TOGETHER could not classify them: if one field
// became presence-required while its siblings stayed indifferent, the pair would only say "this
// carrier changed", and the row would record a policy it cannot see.

const presenceManifest = "presence_corpus.txt"

// presencePlanHeaderFile is the plan row's peer input. It is NAMED by every plan row rather
// than known by convention: an artifact on disk that no row references is staged by Bazel,
// read by nobody, and reported by nothing.
const presencePlanHeaderFile = "presence_TargetRangeV1_header.bin"

type presenceCarrier struct {
	name string
	// base builds the ENCLOSING artifact -- the record, batch, assignment or page run that the
	// carrier lives inside and that a production validator actually accepts.
	base func(t *testing.T) proto.Message
	// reseal recomputes whatever the enclosing artifact derives from the carrier's bytes.
	// Without it a variant is refused for a stale digest and the row says nothing about presence.
	reseal func(t *testing.T, msg proto.Message)
	// verify runs the production validator for the enclosing artifact.
	verify func(t *testing.T, msg proto.Message) error
	// decode parses a committed artifact back into the enclosing message.
	decode func(t *testing.T, raw []byte) proto.Message
	// clearDerived nils whatever the ENCLOSING artifact recomputes from the carrier's bytes --
	// a signature, a digest, a chained hash. Those legitimately move with the field under test,
	// so isolation normalises them; anything else that moves is a SECOND difference.
	clearDerived func(msg proto.Message)
	// peer records what the ELIXIR runtime can claim about this carrier. `validator` means it
	// has a production admission boundary for the enclosing artifact and must reach the same
	// accept/refuse verdict; `observation` means it has none, so the peer claims only what it
	// can see without one -- wire distinction, decoded presence, and exact zero preservation.
	//
	// Recorded per carrier because inventing an Elixir check to manufacture parity would prove
	// only that a test can refuse its own inputs.
	peer string
}

func decodeAs[T proto.Message](t *testing.T, raw []byte, msg T) proto.Message {
	t.Helper()

	if err := proto.Unmarshal(raw, msg); err != nil {
		t.Fatalf("unmarshal %T: %v", msg, err)
	}

	return msg
}

func presenceCarriers() []presenceCarrier {
	return []presenceCarrier{
		{
			name: "EdgeProducerContext", peer: "observation",
			base: func(t *testing.T) proto.Message { t.Helper(); return validRecordFixed(t) },
			reseal: func(t *testing.T, msg proto.Message) {
				t.Helper()
				r, _ := msg.(*edgev1.EdgeRecordV1)
				// The grant is bound to the producer context, and the envelope commits both.
				r.ProductionCapability = productionCap(t, r)
				r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)
			},
			clearDerived: func(msg proto.Message) {
				r, _ := msg.(*edgev1.EdgeRecordV1)
				r.ProductionCapability = nil
				r.SemanticEnvelopeSha256 = nil
			},
			verify: func(_ *testing.T, msg proto.Message) error {
				r, _ := msg.(*edgev1.EdgeRecordV1)

				return ValidateRecord(r)
			},
			decode: func(t *testing.T, raw []byte) proto.Message {
				t.Helper()
				return decodeAs(t, raw, &edgev1.EdgeRecordV1{})
			},
		},
		{
			name: "MtrTraceHopV1", peer: "observation",
			base:   func(t *testing.T) proto.Message { t.Helper(); return presenceMtrBatch(t) },
			reseal: func(_ *testing.T, _ proto.Message) {},
			verify: func(_ *testing.T, msg proto.Message) error {
				b, _ := msg.(*edgev1.MtrTraceBatchV1)

				return ValidateMtrTraceBatch(b)
			},
			decode: func(t *testing.T, raw []byte) proto.Message {
				t.Helper()
				return decodeAs(t, raw, &edgev1.MtrTraceBatchV1{})
			},
		},
		{
			name: "SweepHostObservationV1", peer: "validator",
			base:   func(t *testing.T) proto.Message { t.Helper(); return presenceSweepBatch(t) },
			reseal: func(_ *testing.T, _ proto.Message) {},
			verify: presenceSweepVerify,
			decode: presenceSweepDecode,
		},
		{
			name: "SweepIcmpSummaryV1", peer: "validator",
			base:   func(t *testing.T) proto.Message { t.Helper(); return presenceSweepBatch(t) },
			reseal: func(_ *testing.T, _ proto.Message) {},
			verify: presenceSweepVerify,
			decode: presenceSweepDecode,
		},
		{
			name: "SweepMtrSummaryV1", peer: "validator",
			base:   func(t *testing.T) proto.Message { t.Helper(); return presenceSweepBatch(t) },
			reseal: func(_ *testing.T, _ proto.Message) {},
			verify: presenceSweepVerify,
			decode: presenceSweepDecode,
		},
		{
			name: "SweepOpenPortV1", peer: "validator",
			base:   func(t *testing.T) proto.Message { t.Helper(); return presenceSweepBatch(t) },
			reseal: func(_ *testing.T, _ proto.Message) {},
			verify: presenceSweepVerify,
			decode: presenceSweepDecode,
		},
		{
			name: "SweepMtrExpectationV1", peer: "validator",
			base:   func(t *testing.T) proto.Message { t.Helper(); return presenceAssignment(t) },
			reseal: func(_ *testing.T, _ proto.Message) {},
			verify: func(_ *testing.T, msg proto.Message) error {
				a, _ := msg.(*edgev1.SweepAssignmentRecordV1)

				return ValidateSweepAssignmentRecord(a)
			},
			decode: func(t *testing.T, raw []byte) proto.Message {
				t.Helper()
				return decodeAs(t, raw, &edgev1.SweepAssignmentRecordV1{})
			},
		},
		{
			name: "TargetRangeV1", peer: "validator",
			base: func(t *testing.T) proto.Message { t.Helper(); return presencePlanPage(t) },
			reseal: func(t *testing.T, msg proto.Message) {
				t.Helper()
				p, _ := msg.(*edgev1.ScheduledPlanPageV1)
				// The range digest covers the optional field, and the page digest covers the
				// ranges. Without both, a variant is refused for a stale hash rather than for
				// the absence under test.
				for _, r := range p.GetRanges() {
					r.RangeSha256 = RangeDigest(r)
				}

				p.PageSha256 = PlanPageDigest(p)
			},
			clearDerived: func(msg proto.Message) {
				p, _ := msg.(*edgev1.ScheduledPlanPageV1)
				p.PageSha256 = nil

				for _, r := range p.GetRanges() {
					r.RangeSha256 = nil
				}
			},
			verify: func(t *testing.T, msg proto.Message) error {
				t.Helper()
				p, _ := msg.(*edgev1.ScheduledPlanPageV1)
				pages := []*edgev1.ScheduledPlanPageV1{p}

				// The header is ALWAYS well shaped, including for the absent variant: its
				// 32-byte MTR commitment is derived from the CONTROL pages. That is what lets
				// the refusal come from ValidatePlanPages reaching PlanMtrWindows, rather than
				// from this helper failing to build a header -- a construction error is not a
				// production verdict and cannot stand in for one.
				return ValidatePlanPages(presencePlanHeader(t, pages), pages)
			},
			decode: func(t *testing.T, raw []byte) proto.Message {
				t.Helper()
				return decodeAs(t, raw, &edgev1.ScheduledPlanPageV1{})
			},
		},
	}
}

func presenceSweepVerify(_ *testing.T, msg proto.Message) error {
	b, _ := msg.(*edgev1.SweepObservationBatchV1)

	return ValidateSweepObservationBatch(b)
}

func presenceSweepDecode(t *testing.T, raw []byte) proto.Message {
	t.Helper()
	return decodeAs(t, raw, &edgev1.SweepObservationBatchV1{})
}

// presenceSweepBatch is the deterministic sweep batch, extended with the one carrier the base
// fixture does not populate: an OPEN PORT. A carrier absent from the base cannot be exercised
// at all -- applyOptionals fails loudly rather than writing a vector that proves nothing.
func presenceSweepBatch(t *testing.T) *edgev1.SweepObservationBatchV1 {
	t.Helper()

	b := deterministicSweepBatch(t)

	tcpBit := uint32(edgev1.SweepModeBit_SWEEP_MODE_BIT_TCP_CONNECT)
	b.ConfiguredModeBits |= tcpBit
	b.TestedChecks = append(b.TestedChecks, &edgev1.SweepTestV1{
		Mode:     edgev1.SweepMode_SWEEP_MODE_TCP_CONNECT,
		Protocol: edgev1.TransportProtocol_TRANSPORT_PROTOCOL_TCP,
		Port:     443,
	})

	h := b.GetHosts()[0]
	h.ResultModeBits |= tcpBit
	h.Tcp = &edgev1.SweepTcpSummaryV1{
		Outcome: edgev1.SweepModeOutcome_SWEEP_MODE_OUTCOME_SUCCESS, TestedCount: 1, OpenCount: 1,
	}
	// The open port is the carrier for response_time_nano, and the base fixture has none: a
	// carrier absent from the base cannot be exercised, which applyOptionals reports rather
	// than silently writing a vector that proves nothing.
	h.OpenPorts = []*edgev1.SweepOpenPortV1{{
		TestedCheckIndex: uint32(len(b.GetTestedChecks()) - 1), Service: "https",
	}}

	return b
}

// presenceAssignment is the deterministic assignment record carrying an MTR expectation.
func presenceAssignment(t *testing.T) *edgev1.SweepAssignmentRecordV1 {
	t.Helper()

	a := validAssignment(t)
	a.ProducerAssignmentId = stableUUID(0xF0)
	a.ExecutionId = stableUUID(0xF1)
	a.ExecutionPlanId = stableUUID(0xF2)
	a.TargetRangeId = stableUUID(0xF3)
	a.NetworkScopeId = stableUUID(0xF4)
	a.AuthenticatedAgentId = stableUUID(0xF5)
	a.ProductionScopeId = stableUUID(0xF6)
	a.RunId = stableUUID(0xF7)
	a.CompiledAssignmentId = stableUUID(0xF8)

	// The SIGNED SOURCE IDENTITY's two ids are minted randomly too. Missing them is what made
	// the first regeneration of this control drift: nine of eleven were fixed, and a committed
	// vector needs all eleven.
	if src := a.GetSourceIdentity(); src != nil {
		src.ContextId = stableUUID(0xF9)
		src.SourceScopeId = stableUUID(0xFA)
	}

	return a
}

// presencePlanPage is a deterministic single-page plan; presencePlanHeader roots whatever page
// it is given, so a variant is never refused for a root that no longer matches.
func presencePlanPage(t *testing.T) *edgev1.ScheduledPlanPageV1 {
	t.Helper()

	_, pages := stablePlan(t)
	p := pages[0]
	p.PageIndex, p.PageCount, p.PrevPageSha256 = 0, 1, nil
	p.PageSha256 = PlanPageDigest(p)

	return p
}

func presencePlanHeader(
	t *testing.T, pages []*edgev1.ScheduledPlanPageV1,
) *edgev1.ScheduledPlanHeaderV1 {
	t.Helper()

	h, _ := stablePlan(t)

	var total uint64

	for _, p := range pages {
		for _, r := range p.GetRanges() {
			total += r.GetTargetCount()
		}
	}

	// Derived from the CONTROL pages, which always carry mtr_ordinal_count, so the header is
	// constructible whatever the variant omits. The chain values below are recomputed over the
	// ACTUAL pages so the only thing left unreconciled is the absence under test.
	commitment, err := PlanMtrOrdinalRangeCommitment(presenceControlPlanPages(t))
	if err != nil {
		t.Fatalf("the CONTROL pages must yield a commitment: %v", err)
	}

	h.PageCount = uint32(len(pages))
	h.TotalTargetCount = total
	h.PlanRootSha256 = PlanRoot(pages)
	h.MtrOrdinalRangeCommitment = commitment
	h.ExecutionPlanSha256 = PlanHeaderDigest(h)

	return h
}

// presenceControlPlanPages is the all-present-zero single-page plan the header's MTR commitment
// is derived from.
func presenceControlPlanPages(t *testing.T) []*edgev1.ScheduledPlanPageV1 {
	t.Helper()

	p := presencePlanPage(t)
	applyOptionals(t, p, "TargetRangeV1", "")

	for _, r := range p.GetRanges() {
		r.RangeSha256 = RangeDigest(r)
	}

	p.PageSha256 = PlanPageDigest(p)

	return []*edgev1.ScheduledPlanPageV1{p}
}

// TestPresencePlanWindowIsTheProductionVerdict pins WHERE the refusal comes from.
//
// The row would look identical if the absence were reported by the corpus's own header builder,
// so this asserts the committed variant reaches ValidatePlanPages and returns ErrPlanMtrWindow --
// the error PlanMtrWindows raises on a nil mtr_ordinal_count.
func TestPresencePlanWindowIsTheProductionVerdict(t *testing.T) {
	raw, err := os.ReadFile(goldenPath("presence_TargetRangeV1_mtr_ordinal_count_absent.bin"))
	if err != nil {
		t.Fatalf("read variant: %v", err)
	}

	var p edgev1.ScheduledPlanPageV1
	if err := proto.Unmarshal(raw, &p); err != nil {
		t.Fatalf("unmarshal variant: %v", err)
	}

	pages := []*edgev1.ScheduledPlanPageV1{&p}

	if err := ValidatePlanPages(presencePlanHeader(t, pages), pages); !errors.Is(err, ErrPlanMtrWindow) {
		t.Fatalf("ValidatePlanPages(absent mtr_ordinal_count) = %v, want ErrPlanMtrWindow", err)
	}

	// The control must reach the same verifier and be ACCEPTED, so the row is a refusal about
	// presence and not a verifier that refuses this shape of plan generally.
	control := presenceControlPlanPages(t)
	if err := ValidatePlanPages(presencePlanHeader(t, control), control); err != nil {
		t.Fatalf("the all-present control plan must validate: %v", err)
	}
}

// presenceMtrBatch is a deterministic, VALID MTR batch carrying one hop -- the carrier for the
// eight per-hop measurements.
func presenceMtrBatch(t *testing.T) *edgev1.MtrTraceBatchV1 {
	t.Helper()

	return &edgev1.MtrTraceBatchV1{
		NetworkScopeId: stableUUID(0xE0),
		AgentId:        stableUUID(0xE1),
		BatchSequence:  1,
		Source:         edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		Correlation: &edgev1.MtrTraceBatchV1_ScheduledCheck{
			ScheduledCheck: &edgev1.MtrScheduledCheckContextV1{CheckId: stableUUID(0xE2)},
		},
		Traces: []*edgev1.MtrTraceEventV1{{
			TraceId:          stableUUID(0xE3),
			EventId:          stableUUID(0xE4),
			SweepHostAddress: []byte{10, 0, 0, 9},
			Outcome:          edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
			Target:           "10.0.0.9",
			Attempted:        true,
			TargetReached:    true,
			TotalHops:        1,
			Protocol:         edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
			IpVersion:        4,
			Hops: []*edgev1.MtrTraceHopV1{{
				HopNumber: 1, Address: []byte{10, 0, 0, 1}, Sent: 3, Received: 3,
			}},
		}},
	}
}

// carrierFields returns the carrier's optional scalar field names, from the DESCRIPTOR, sorted
// so the manifest is stable.
func carrierFields(t *testing.T, carrier string) []string {
	t.Helper()

	var out []string

	scalars, _ := descriptorOptionalFields(t)
	for full, c := range scalars {
		if c == carrier {
			out = append(out, full[len(carrier)+1:])
		}
	}

	sort.Strings(out)

	return out
}

// TestPresenceSharedCorpus writes one control per carrier and one variant per FIELD, and
// records what the production validator does with each.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestPresenceSharedCorpus(t *testing.T) {
	var lines []string

	for _, c := range presenceCarriers() {
		controlFile := "presence_" + c.name + "_control.bin"

		control := c.base(t)
		applyOptionals(t, control, c.name, "")
		c.reseal(t, control)

		controlBytes, err := proto.Marshal(control)
		if err != nil {
			t.Fatalf("%s: marshal control: %v", c.name, err)
		}

		goldenBytesLocal(t, controlFile, controlBytes)

		// The plan row needs its HEADER committed too: the peer runtime cannot construct one,
		// and a row the other runtime cannot execute is not a shared vector. It carries the
		// well-shaped MTR commitment derived from the control pages, so the peer re-roots it
		// over whatever page arrives and the absence is still refused by the validator.
		if c.name == "TargetRangeV1" {
			h := presencePlanHeader(t, presenceControlPlanPages(t))

			hb, err := proto.Marshal(h)
			if err != nil {
				t.Fatalf("marshal plan header: %v", err)
			}

			goldenBytesLocal(t, presencePlanHeaderFile, hb)
		}

		// NO OVER-REFUSAL: present-zero everywhere must be ADMITTED. A carrier whose control is
		// refused would make every variant below refuse too, and each row would look like a
		// presence rule while proving nothing.
		if err := c.verify(t, c.decode(t, controlBytes)); err != nil {
			t.Fatalf("%s: the all-present-zero CONTROL must be accepted: %v", c.name, err)
		}

		ctlPresent, ctlValues := optionalPresenceOf(t, c.decode(t, controlBytes), c.name)

		for _, field := range carrierFields(t, c.name) {
			if !ctlPresent[field] {
				t.Fatalf("%s.%s: the control must carry it PRESENT", c.name, field)
			}

			// PRESENT-ZERO, not present-anything: the corpus varies presence alone, so a value
			// that drifted off zero would make the pair differ on two axes.
			if v := ctlValues[field]; v != "0" {
				t.Errorf("%s.%s: control value %q, want \"0\"", c.name, field, v)
			}

			variantFile := "presence_" + c.name + "_" + field + "_absent.bin"

			variant := c.base(t)
			applyOptionals(t, variant, c.name, field)
			c.reseal(t, variant)

			variantBytes, err := proto.Marshal(variant)
			if err != nil {
				t.Fatalf("%s.%s: marshal variant: %v", c.name, field, err)
			}

			goldenBytesLocal(t, variantFile, variantBytes)

			// SINGLE AXIS, mechanically: the two artifacts may differ in this field's presence
			// and in nothing else the carrier declares optional.
			varPresent, _ := optionalPresenceOf(t, c.decode(t, variantBytes), c.name)

			for name, present := range ctlPresent {
				want := present
				if name == field {
					want = false
				}

				if varPresent[name] != want {
					t.Errorf("%s: variant omitting %s also changed %s (present=%v, want %v)",
						c.name, field, name, varPresent[name], want)
				}
			}

			// THE MEASURED POLICY. Some optional fields are refused when absent and some are
			// indifferent; which is which is read off the validator, never assumed.
			policy := "indifferent"
			if err := c.verify(t, c.decode(t, variantBytes)); err != nil {
				policy = "required"
			}

			peerFile := "-"
			if c.name == "TargetRangeV1" {
				peerFile = presencePlanHeaderFile
			}

			lines = append(lines, fmt.Sprintf("%s.%s %s %s %s %s %s %s",
				c.name, field, c.name, controlFile, variantFile, peerFile, policy, c.peer))
		}
	}

	sort.Strings(lines)

	goldenBytesLocal(t, presenceManifest, []byte(strings.Join(lines, "\n")+"\n"))
}

// TestPresenceManifestMatchesDisk compares the manifest against the fixtures ON DISK, in both
// directions.
//
// Without it an artifact can be committed and staged while no row names it -- which was true of
// the plan row's header until it became a column here.
func TestPresenceManifestMatchesDisk(t *testing.T) {
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		t.Skip("regenerating")
	}

	raw, err := os.ReadFile(goldenPath(presenceManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	listed := map[string]bool{}

	for i, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		f := strings.Fields(line)
		if len(f) != 7 {
			t.Fatalf("manifest line %d has %d columns, want 7: %q", i+1, len(f), line)
		}

		for _, name := range f[2:5] {
			if name != "-" && strings.HasSuffix(name, ".bin") {
				listed[name] = true
			}
		}
	}

	matches, err := filepath.Glob(filepath.Join(filepath.Dir(goldenPath(presenceManifest)), "presence_*.bin"))
	if err != nil {
		t.Fatalf("glob fixtures: %v", err)
	}

	if len(matches) == 0 {
		t.Fatal("no presence_*.bin found on disk; the guard would pass vacuously")
	}

	onDisk := map[string]bool{}
	for _, m := range matches {
		onDisk[filepath.Base(m)] = true
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
}

// TestPresenceRowsIsolateTheField proves MECHANICALLY that a control and its variant differ in
// ONE logical value across the WHOLE message, not merely among the carrier's optional fields.
//
// The generator already checks that no OTHER optional scalar moved. That is not the same claim:
// a reseal, a chained hash, or an unrelated field touched during construction would leave the
// optional-field comparison green while the pair differed elsewhere, and the row would be
// recording a policy about something other than presence.
func TestPresenceRowsIsolateTheField(t *testing.T) {
	raw, err := os.ReadFile(goldenPath(presenceManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	byCarrier := map[string]presenceCarrier{}
	for _, c := range presenceCarriers() {
		byCarrier[c.name] = c
	}

	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		f := strings.Fields(line)
		carrier, controlFile, variantFile := f[1], f[2], f[3]

		c, ok := byCarrier[carrier]
		if !ok {
			t.Fatalf("%s: no carrier supplies a normaliser", carrier)
		}

		field := strings.TrimPrefix(f[0], carrier+".")

		control := presenceNormalized(t, c, controlFile, field)
		variant := presenceNormalized(t, c, variantFile, field)

		if !proto.Equal(control, variant) {
			t.Errorf("%s: the pair differs in more than %s; the row is not isolated", f[0], f[0])
		}
	}
}

// presenceNormalized loads an artifact and clears ONLY the row's own field, plus whatever the
// enclosing artifact derives from it. What remains must be identical.
//
// Clearing every optional scalar would be too generous: the siblings are present-zero in BOTH
// artifacts, so normalising them away would hide a sibling whose VALUE had drifted off zero --
// exactly the second difference this control exists to catch.
func presenceNormalized(t *testing.T, c presenceCarrier, file, field string) proto.Message {
	t.Helper()

	rawBytes, err := os.ReadFile(goldenPath(file))
	if err != nil {
		t.Fatalf("read %s: %v", file, err)
	}

	msg := c.decode(t, rawBytes)

	cleared := 0

	eachCarrier(msg.ProtoReflect(), c.name, func(m protoreflect.Message) {
		fields := m.Descriptor().Fields()

		for i := 0; i < fields.Len(); i++ {
			fd := fields.Get(i)

			oo := fd.ContainingOneof()
			if oo == nil || !oo.IsSynthetic() || string(fd.Name()) != field {
				continue
			}

			m.Clear(fd)

			cleared++
		}
	})

	if cleared == 0 {
		t.Fatalf("%s: %s is not an optional scalar on this carrier; nothing was normalised",
			file, field)
	}

	if c.clearDerived != nil {
		c.clearDerived(msg)
	}

	return msg
}
