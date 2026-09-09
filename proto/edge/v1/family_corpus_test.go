package edgev1_test

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"

	"github.com/carverauto/serviceradar/go/pkg/edge/edgerecord"
	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// The verdict vocabulary the shared corpus manifests use. Two files write these columns and
// assert on them, so they are named once: a typo in a literal would read as a different verdict
// rather than as a compile error.
const (
	verdictAccept = "accept"
	verdictRefuse = "refuse"
)

// The FRAMING-FAMILY corpus (task 1.5-g): which payload family may enter which TYPED ingress.
//
// ## The decision this freezes
//
// There is NO global family-to-contract mapping, and deliberately no registry-wide
// contract-to-family table. The EXACT OUTPUT CONTRACT selects the semantic validator and the
// projector; `dispatchContract` compares the contract reference and nothing else.
//
// What IS frozen is a family-to-TYPED-ENTRYPOINT invariant:
//
//	sweep and MTR ingress -> EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1
//	lifecycle ingress     -> EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1
//	recovery ingress      -> EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1
//	future snapshot ingresses -> their named snapshot family
//
// `payload_family` is therefore an IMMUTABLE FRAMING AND LIFECYCLE DISCRIMINATOR. It is not
// decorative metadata, not authorization, and not an infrastructure routing key.
//
// ## Why the check has to live at each typed boundary
//
// Protobuf bytes are not intrinsically type-tagged: a body decodes under an unintended schema
// without complaint. A typed ingress that did not read the family would therefore ADMIT and
// AUTHENTICATE a record declaring SNAPSHOT_PAGE_V1 while carrying a sweep body, and every later
// reader that selects a decoder from the family would be choosing from a value nothing
// validated. The audit that found this is in design.md.
//
// The GENERIC validator stays permissive across the known non-recovery families on purpose: it
// has no entry-point context and cannot choose one of them. That permissiveness is a row here,
// not an omission.
const familyManifest = "family_corpus.txt"

type familyVector struct {
	entrypoint string
	family     edgev1.EdgeRecordPayloadFamily
	file       string
	// build returns the record for this row. The body is ALWAYS a valid sweep batch: the row
	// varies the declared family, so a body defect would confound it.
	build func(t *testing.T, family edgev1.EdgeRecordPayloadFamily) *edgev1.EdgeRecordV1
	// verify drives the PRODUCTION typed ingress.
	verify func(t *testing.T, r *edgev1.EdgeRecordV1) error
}

func familyShortName(f edgev1.EdgeRecordPayloadFamily) string {
	return strings.ToLower(strings.TrimPrefix(f.String(), "EDGE_RECORD_PAYLOAD_FAMILY_"))
}

// sweepRecordWithFamily is the canonical sweep record with its declared family replaced and
// every dependent value resealed, so the family is the ONLY thing that differs between rows.
func sweepRecordWithFamily(t *testing.T, family edgev1.EdgeRecordPayloadFamily) *edgev1.EdgeRecordV1 {
	t.Helper()

	r := canonicalRecord(t)
	r.PayloadFamily = family
	r.ProductionCapability = productionCap(r)

	if sa := r.GetSourceAuthorization(); sa != nil {
		sa.Capability = sourceCap(r, sa.GetContextId(), sa.GetScopeId())
	}

	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)

	return r
}

func familyVectors() []familyVector {
	// The four families a typed sweep/MTR ingress must judge. RECOVERY_CONTROL_V1 is excluded
	// here because the generic recovery-lane biconditional already refuses it against an
	// ordinary route -- a different rule, owned elsewhere, and folding it in would make this
	// corpus look like it proved something it did not.
	families := []edgev1.EdgeRecordPayloadFamily{
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_PAGE_V1,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_TERMINAL_V1,
	}

	out := make([]familyVector, 0, len(families))

	for _, f := range families {
		out = append(out, familyVector{
			entrypoint: "sweep", family: f,
			file:  "family_sweep_" + familyShortName(f) + ".bin",
			build: sweepRecordWithFamily,
			verify: func(t *testing.T, r *edgev1.EdgeRecordV1) error {
				t.Helper()
				return edgerecord.ValidateSweepRecord(r, r.GetOutputContract(), goldenPolicy())
			},
		})
	}

	return out
}

// TestFamilySharedCorpus writes one record per (entrypoint, family) and asserts the typed
// ingress verdict, plus the GENERIC validator's verdict on the same bytes.
//
// Regenerate with EDGE_GOLDEN_UPDATE=1.
func TestFamilySharedCorpus(t *testing.T) {
	vectors := familyVectors()
	lines := make([]string, 0, len(vectors))

	for _, v := range vectors {
		r := v.build(t, v.family)
		raw := goldenBytes(t, v.file, mustMarshal(r))

		var decoded edgev1.EdgeRecordV1
		if err := proto.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("%s: unmarshal: %v", v.file, err)
		}

		typedErr := v.verify(t, &decoded)
		typed := verdictRefuse

		if typedErr == nil {
			typed = verdictAccept
		}

		// THE GENERIC VALIDATOR IS A ROW, not a footnote: its permissiveness is deliberate, and
		// recording it is what stops a future change from quietly making it strict and calling
		// that a fix.
		generic := verdictRefuse
		if edgerecord.ValidateRecord(&decoded) == nil {
			generic = verdictAccept
		}

		want := verdictRefuse
		if v.family == edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1 {
			want = verdictAccept
		}

		if typed != want {
			t.Fatalf("%s: typed ingress %s, want %s (err=%v)", v.file, typed, want, typedErr)
		}

		// THE EXACT SENTINEL on a refusal, not merely "some error". A stale signature, a body
		// defect or a failed authority join would otherwise masquerade as family evidence -- and
		// each of those is reachable from these fixtures, since every row reseals a real record.
		if want == verdictRefuse && !errors.Is(typedErr, edgerecord.ErrPayloadFraming) {
			t.Fatalf("%s: refused with %v, want ErrPayloadFraming", v.file, typedErr)
		}

		if generic != verdictAccept {
			t.Fatalf("%s: the generic validator must stay permissive, got %v",
				v.file, edgerecord.ValidateRecord(&decoded))
		}

		lines = append(lines, fmt.Sprintf("%s %s %s %s %s",
			v.entrypoint, familyShortName(v.family), v.file, typed, generic))
	}

	goldenBytes(t, familyManifest, []byte(strings.Join(lines, "\n")+"\n"))
}

// TestFamilyGatePrecedesDecode is the ONE precedence control this task owns.
//
// A record whose family is a wrong-but-KNOWN family AND whose payload is malformed must stop at
// the framing gate. If it stopped at the decoder instead, the gate would not be preventing the
// body from being parsed under a schema the declared family says not to use -- which is the
// entire reason the check sits before extraction.
//
// It is deliberately NOT a general reason-order matrix: ordering among other simultaneous
// precondition violations is outside this boundary.
func TestFamilyGatePrecedesDecode(t *testing.T) {
	r := sweepRecordWithFamily(t,
		edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_PAGE_V1)

	// A payload that CANNOT decode as a sweep batch, with its digest and sizes kept consistent
	// so the record is otherwise admissible and only the two faults are live.
	r.Payload = []byte{0xFF, 0xFF, 0xFF, 0xFF}
	r.EncodedSize = uint32(len(r.GetPayload()))
	r.UncompressedSize = uint32(len(r.GetPayload()))
	sum := sha256.Sum256(r.GetPayload())
	r.PayloadSha256 = sum[:]
	r.ProductionCapability = productionCap(r)

	if sa := r.GetSourceAuthorization(); sa != nil {
		sa.Capability = sourceCap(r, sa.GetContextId(), sa.GetScopeId())
	}

	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)

	err := edgerecord.ValidateSweepRecord(r, r.GetOutputContract(), goldenPolicy())
	if !errors.Is(err, edgerecord.ErrPayloadFraming) {
		t.Fatalf("wrong family + malformed payload = %v, want ErrPayloadFraming: the decoder was "+
			"entered before the framing gate", err)
	}
}

// TestFamilyManifestMatchesDisk compares the manifest against the fixtures on disk, both ways.
func TestFamilyManifestMatchesDisk(t *testing.T) {
	if os.Getenv("EDGE_GOLDEN_UPDATE") == "1" {
		t.Skip("regenerating")
	}

	raw, err := os.ReadFile(filepath.Join("testdata", familyManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	listed := map[string]bool{}

	for i, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		f := strings.Fields(line)
		if len(f) != 5 {
			t.Fatalf("manifest line %d has %d columns, want 5: %q", i+1, len(f), line)
		}

		listed[f[2]] = true
	}

	matches, err := filepath.Glob(filepath.Join("testdata", "family_*.bin"))
	if err != nil {
		t.Fatalf("glob fixtures: %v", err)
	}

	if len(matches) == 0 {
		t.Fatal("no family_*.bin found on disk; the guard would pass vacuously")
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

func canonicalMtrRecord(t *testing.T, family edgev1.EdgeRecordPayloadFamily) *edgev1.EdgeRecordV1 {
	t.Helper()
	r := canonicalRecord(t)

	ctx := r.GetSourceAuthorization().GetContextId()
	batch := &edgev1.MtrTraceBatchV1{
		NetworkScopeId: r.GetNetworkScopeId(),
		AgentId:        r.GetProducerContext().GetProducerInstanceId(),
		BatchSequence:  1,
		Source:         edgev1.SweepExecutionSource_SWEEP_EXECUTION_SOURCE_SCHEDULED_CHECK,
		Correlation: &edgev1.MtrTraceBatchV1_ScheduledCheck{
			ScheduledCheck: &edgev1.MtrScheduledCheckContextV1{CheckId: ctx},
		},
		Traces: []*edgev1.MtrTraceEventV1{{
			TraceId: uuidv7(0x41), EventId: uuidv7(0x42),
			// INSIDE the signed collection window; a zero time is outside it and the join
			// would refuse the control for a reason that has nothing to do with framing.
			ObservedAtUnixNano: fixedNanos,
			SweepHostAddress:   []byte{10, 0, 0, 9},
			Outcome:            edgev1.MtrOutcome_MTR_OUTCOME_REACHED,
			Target:             "10.0.0.9", Attempted: true, TargetReached: true, TotalHops: 1,
			Protocol:  edgev1.TransportProtocol_TRANSPORT_PROTOCOL_ICMP,
			IpVersion: 4,
			Hops: []*edgev1.MtrTraceHopV1{{
				HopNumber: 1, Address: []byte{10, 0, 0, 1}, Sent: 3, Received: 3,
			}},
		}},
	}

	payload := mustMarshal(batch)
	sum := sha256.Sum256(payload)

	r.PayloadFamily = family
	r.Payload = payload
	r.EncodedSize = uint32(len(payload))
	r.UncompressedSize = uint32(len(payload))
	r.PayloadSha256 = sum[:]
	r.ProductionCapability = productionCap(r)

	if sa := r.GetSourceAuthorization(); sa != nil {
		sa.Capability = sourceCap(r, sa.GetContextId(), sa.GetScopeId())
	}

	r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)

	return r
}

func TestMtrIdentityTimeOverflow(t *testing.T) {
	control := canonicalMtrRecord(t, edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1)
	if err := edgerecord.ValidateMtrRecord(control, control.GetOutputContract(), goldenPolicy()); err != nil {
		t.Fatalf("control: %v", err)
	}
	var millis int64 = 20_230_744_073_710
	wrapped := millis * 1_000_000
	claims := control.GetSourceAuthorization().GetCapability().GetSource()
	if wrapped < claims.GetCollectionNotBeforeUnixNano() || wrapped > claims.GetCollectionExpiresUnixNano() {
		t.Fatal("unchecked product must land inside the signed collection window")
	}
	for _, field := range []string{"trace_id", "event_id"} {
		t.Run(field, func(t *testing.T) {
			r := proto.Clone(control).(*edgev1.EdgeRecordV1)
			var batch edgev1.MtrTraceBatchV1
			if err := proto.Unmarshal(r.GetPayload(), &batch); err != nil {
				t.Fatal(err)
			}
			if field == "trace_id" {
				batch.Traces[0].TraceId = uuidv7At(millis)
			} else {
				batch.Traces[0].EventId = uuidv7At(millis)
			}
			r.Payload = mustMarshal(&batch)
			r.EncodedSize = uint32(len(r.Payload))
			r.UncompressedSize = uint32(len(r.Payload))
			sum := sha256.Sum256(r.Payload)
			r.PayloadSha256 = sum[:]
			r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)
			raw := golden(t, "mtr_"+field+"_time_overflow.bin", r)
			var decoded edgev1.EdgeRecordV1
			if err := proto.Unmarshal(raw, &decoded); err != nil {
				t.Fatal(err)
			}
			if err := edgerecord.ValidateMtrRecord(&decoded, decoded.GetOutputContract(), goldenPolicy()); !errors.Is(err, edgerecord.ErrSweepJoin) {
				t.Fatalf("%s overflow: got %v, want ErrSweepJoin", field, err)
			}
		})
	}
}

// TestMtrEntrypointEnforcesFramingFamily proves the MTR ingress enforces the SAME equality at
// its OWN call site.
//
// Deliberately NOT four more corpus rows: the sweep corpus already exhausts the declared
// non-recovery alternatives at the cross-runtime boundary, and MTR rows would be Go-only —
// Elixir has no MTR record ingress to consume them. What is unproven without this is narrower:
// that the second call site exists and is independently removable.
//
// SNAPSHOT_PAGE_V1 rather than RECOVERY_CONTROL_V1, because the recovery-lane biconditional
// would refuse the latter earlier and the proof would be vacuous.
func TestMtrEntrypointEnforcesFramingFamily(t *testing.T) {
	ok := canonicalMtrRecord(t, edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RECORD_BATCH_V1)
	if err := edgerecord.ValidateMtrRecord(ok, ok.GetOutputContract(), goldenPolicy()); err != nil {
		t.Fatalf("the canonical MTR record must be admitted: %v", err)
	}

	wrong := canonicalMtrRecord(t, edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_PAGE_V1)

	err := edgerecord.ValidateMtrRecord(wrong, wrong.GetOutputContract(), goldenPolicy())
	if !errors.Is(err, edgerecord.ErrPayloadFraming) {
		t.Fatalf("MTR ingress with SNAPSHOT_PAGE_V1 = %v, want ErrPayloadFraming", err)
	}
}

// TestFamilyCorpusCoversEveryDeclaredFamily derives the expected family set from the GENERATED
// ENUM and holds the manifest to it in both directions.
//
// A hand-written count cannot do this: a family added to the proto would leave the corpus
// silently one short while every number in it still agreed with itself. Two exclusions, each
// stated rather than assumed:
//
//	UNSPECIFIED          -- not a declared family; knownPayloadFamily refuses it outright, so
//	                        there is no typed-ingress question to ask about it.
//	RECOVERY_CONTROL_V1  -- the recovery LANE biconditional (family <-> route_profile) preempts
//	                        generic admission, so a row here would be refused by a DIFFERENT
//	                        rule and would look like evidence for this one.
func TestFamilyCorpusCoversEveryDeclaredFamily(t *testing.T) {
	excluded := map[string]bool{
		"EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED":         true,
		"EDGE_RECORD_PAYLOAD_FAMILY_RECOVERY_CONTROL_V1": true,
	}

	values := edgev1.EdgeRecordPayloadFamily(0).Descriptor().Values()
	want := map[string]bool{}

	for i := 0; i < values.Len(); i++ {
		name := string(values.Get(i).Name())
		if !excluded[name] {
			want[strings.ToLower(strings.TrimPrefix(name, "EDGE_RECORD_PAYLOAD_FAMILY_"))] = true
		}
	}

	if len(want) == 0 {
		t.Fatal("the declared-family walk found nothing; the comparison below would be vacuous")
	}

	raw, err := os.ReadFile(filepath.Join("testdata", familyManifest))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	got := map[string]bool{}

	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		got[strings.Fields(line)[1]] = true
	}

	for name := range want {
		if !got[name] {
			t.Errorf("family %s is declared but has no manifest row", name)
		}
	}

	for name := range got {
		if !want[name] {
			t.Errorf("manifest carries %s, which is not a declared non-recovery family", name)
		}
	}
}

// TestLifecycleEntrypointEnforcesFramingFamily is the lifecycle half of the same invariant.
//
// A family check that no test invokes is an unrun branch, and "already covered" on the strength
// of one is not coverage. This drives ValidateLifecycleRecord directly: the positive control is
// ADMITTED, and the wrong-family case is refused by the framing check specifically.
//
// Ownership note: task 1.6-c scopes the Elixir lifecycle peer to ValidateSweepExecutionEvent's
// structural boundary and EXPLICITLY EXCLUDES ValidateLifecycleRecord, so it does not own this;
// the Go-side proof lives here.
func TestLifecycleEntrypointEnforcesFramingFamily(t *testing.T) {
	// A REAL lifecycle record: a RUN_EVENT body bound to the record's signed authority. The
	// positive case must be ACCEPTED OUTRIGHT -- a control carrying a body this ingress does not
	// frame would fail deeper, and a control that is refused proves nothing about the gate above
	// it.
	build := func(family edgev1.EdgeRecordPayloadFamily) *edgev1.EdgeRecordV1 {
		r := canonicalRecord(t)

		claims := r.GetSourceAuthorization().GetCapability().GetSource()
		p := r.GetProducerContext()

		ev := &edgev1.SweepExecutionEventV1{
			ExecutionId:         claims.GetContextId(),
			ExecutionPlanId:     claims.GetScopeId(),
			TargetRangeId:       claims.GetScopeId(),
			ExecutionPlanSha256: claims.GetExecutionPlanSha256(),
			ExecutionShard:      p.GetRunShard(),
			AssignmentEpoch:     p.GetAuthorityEpoch(),
			Kind:                edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_START,
			EmittedAtUnixNano:   fixedNanos,
		}

		payload := mustMarshal(ev)
		sum := sha256.Sum256(payload)

		r.PayloadFamily = family
		r.RouteProfile = edgev1.EdgeRecordRouteProfile_EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1
		r.Payload = payload
		r.EncodedSize = uint32(len(payload))
		r.UncompressedSize = uint32(len(payload))
		r.PayloadSha256 = sum[:]
		r.ProductionCapability = productionCap(r)

		if sa := r.GetSourceAuthorization(); sa != nil {
			sa.Capability = sourceCap(r, sa.GetContextId(), sa.GetScopeId())
		}

		r.SemanticEnvelopeSha256 = edgerecord.SemanticEnvelopeDigest(r)

		return r
	}

	// POSITIVE CONTROL: accepted outright. Without this the refusal below could come from any
	// depth and still look like framing evidence.
	ok := build(edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_RUN_EVENT_V1)
	if err := edgerecord.ValidateLifecycleRecord(ok, ok.GetOutputContract(), goldenPolicy()); err != nil {
		t.Fatalf("the canonical lifecycle record must be ADMITTED: %v", err)
	}

	// Then ONLY the family changes, with the values derived from it resealed.
	wrong := build(edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_SNAPSHOT_PAGE_V1)

	err := edgerecord.ValidateLifecycleRecord(wrong, wrong.GetOutputContract(), goldenPolicy())
	if !errors.Is(err, edgerecord.ErrLifecycle) {
		t.Fatalf("lifecycle ingress with SNAPSHOT_PAGE_V1 = %v, want the lifecycle framing refusal", err)
	}

	// The pair differs in the family and in what the family derives, and in nothing else.
	okClone, _ := proto.Clone(ok).(*edgev1.EdgeRecordV1)
	wrongClone, _ := proto.Clone(wrong).(*edgev1.EdgeRecordV1)

	for _, c := range []*edgev1.EdgeRecordV1{okClone, wrongClone} {
		c.PayloadFamily = edgev1.EdgeRecordPayloadFamily_EDGE_RECORD_PAYLOAD_FAMILY_UNSPECIFIED
		c.ProductionCapability = nil
		c.SemanticEnvelopeSha256 = nil

		if sa := c.GetSourceAuthorization(); sa != nil {
			sa.Capability = nil
		}
	}

	if !proto.Equal(okClone, wrongClone) {
		t.Fatal("the lifecycle pair differs in more than the family; the refusal is not isolated")
	}
}
