package edgerecord

import (
	"bufio"
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// Task 1.5-h: THE SHARED SCALAR / CARRIER CORPUS.
//
// FIVE BOUNDS, EIGHT SITES. A BOUND is the frozen ceiling; a SITE is an independently
// removable gate. `MaxPolicyIDBytes` and `MaxPrincipalBytes` are both 128 and stay SEPARATE
// NAMED bounds -- they bound different quantities and either may move alone, so collapsing
// them would hide one bound's drift behind the other's rows.
//
// A LOWER BOUND NEEDS TWO CONTROLS, NOT ONE. SEVEN sites are SEMANTICALLY two-sided -- they
// admit 1..Max, whatever spelling the gate uses -- which freezes a MINIMUM OF 1 as well as a
// ceiling. A zero-refusal alone does not pin it: a validator tightened to reject length 1
// refuses zero exactly as before. Each of those sites carries FOUR controls -- 0 refused,
// 1 ACCEPTED, at accepted, over refused.
//
// AND THEY ARE NEEDED AT EACH SITE, not once per helper: all three principal sites funnel into
// `ValidateAuthenticatedPrincipal`, so a helper-level test proves the HELPER's arithmetic, not
// that a carrier still routes through it -- exactly the regression a helper-level row cannot
// see.
//
// `plan_header_raw` is ONE-SIDED: at/over plus a STAGE WITNESS, no zero rule and no minimum.
// `abort_reason` carries SIX, because its second arm is a separate predicate with its own
// accepted and refused control.
//
// THE LITERALS COME FROM THE MANIFEST, NOT THE CONSTANTS. Building `over` as `Max...+1` moves
// every row with the bound, so a ceiling drifting to 64 keeps the corpus green.

type scalarRow struct {
	site, bound string
	// zero is the verdict for a zero-length value; min is the SMALLEST ADMISSIBLE one.
	// `hasMin` is false for a one-sided bound, whose zero/min columns both read `n/a`.
	zero                 string
	min                  int
	hasMin               bool
	at, over             int
	goVerdict, exVerdict string
	owner                string
}

func scalarCorpusPath(t *testing.T) string {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	return filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1", "testdata", "scalar_corpus.txt")
}

func scalarCorpus(t *testing.T) []scalarRow {
	t.Helper()

	f, err := os.Open(scalarCorpusPath(t))
	if err != nil {
		t.Fatalf("open scalar corpus: %v", err)
	}
	defer func() { _ = f.Close() }()

	var out []scalarRow

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 9 {
			t.Fatalf("scalar corpus row %q has %d fields, want 9", line, len(fields))
		}

		at, err := strconv.Atoi(fields[4])
		if err != nil {
			t.Fatalf("row %q: at: %v", line, err)
		}

		over, err := strconv.Atoi(fields[5])
		if err != nil {
			t.Fatalf("row %q: over: %v", line, err)
		}

		row := scalarRow{
			site: fields[0], bound: fields[1], zero: fields[2],
			at: at, over: over,
			goVerdict: fields[6], exVerdict: fields[7], owner: fields[8],
		}

		if fields[3] != verdictNA {
			row.min, err = strconv.Atoi(fields[3])
			if err != nil {
				t.Fatalf("row %q: min: %v", line, err)
			}

			row.hasMin = true
		}

		out = append(out, row)
	}

	if err := sc.Err(); err != nil {
		t.Fatalf("scan scalar corpus: %v", err)
	}

	return out
}

func scalarRowFor(t *testing.T, site string) scalarRow {
	t.Helper()

	for _, r := range scalarCorpus(t) {
		if r.site == site {
			return r
		}
	}

	t.Fatalf("no scalar corpus row for site %q", site)

	return scalarRow{}
}

// TestScalarCorpusInventory pins the FULL ROW, not just the site set. Checking site names
// alone leaves the bound and both verdicts free -- and MaxPolicyIDBytes and MaxPrincipalBytes
// are BOTH 128, so swapping them changes no arithmetic while the manifest says something false
// about which ceiling each site enforces.
func TestScalarCorpusInventory(t *testing.T) {
	want := map[string]scalarRow{
		"policy_plan_header":         {bound: "MaxPolicyIDBytes", zero: verdictRefuse, min: 1, hasMin: true, goVerdict: verdictRefuse, exVerdict: verdictRefuse, owner: "-"},
		"policy_assignment_record":   {bound: "MaxPolicyIDBytes", zero: verdictRefuse, min: 1, hasMin: true, goVerdict: verdictRefuse, exVerdict: verdictRefuse, owner: "-"},
		"principal_producer_context": {bound: "MaxPrincipalBytes", zero: verdictRefuse, min: 1, hasMin: true, goVerdict: verdictRefuse, exVerdict: verdictNA, owner: proofGroup15N},
		"principal_edge_slot":        {bound: "MaxPrincipalBytes", zero: verdictRefuse, min: 1, hasMin: true, goVerdict: verdictRefuse, exVerdict: verdictRefuse, owner: "-"},
		"principal_service_slot":     {bound: "MaxPrincipalBytes", zero: verdictRefuse, min: 1, hasMin: true, goVerdict: verdictRefuse, exVerdict: verdictRefuse, owner: "-"},
		"plan_header_raw":            {bound: "MaxPlanHeaderBytes", zero: verdictNA, goVerdict: verdictRefuse, exVerdict: verdictRefuse, owner: "-"},
		"abort_reason":               {bound: "MaxTraceStrBytes", zero: verdictRefuse, min: 1, hasMin: true, goVerdict: verdictRefuse, exVerdict: verdictNA, owner: "1.6-c"},
		"tombstone_reason_signed":    {bound: "MaxReasonBytes", zero: verdictRefuse, min: 1, hasMin: true, goVerdict: verdictRefuse, exVerdict: verdictNA, owner: proofGroup16D},
	}

	known := map[string]bool{verdictRefuse: true, verdictAccept: true, verdictNA: true}

	rows := scalarCorpus(t)

	// SET EQUALITY DOES NOT SEE A DUPLICATE: a row pasted twice collapses, and every per-row
	// check below then passes on it.
	if len(rows) != len(want) {
		t.Fatalf("scalar corpus has %d rows, inventory has %d -- a duplicate or missing row", len(rows), len(want))
	}

	seen := map[string]bool{}

	for _, r := range rows {
		w, ok := want[r.site]
		if !ok {
			t.Fatalf("scalar corpus row %q is not in the inventory", r.site)
		}

		seen[r.site] = true

		if r.bound != w.bound || r.zero != w.zero || r.min != w.min || r.hasMin != w.hasMin ||
			r.goVerdict != w.goVerdict || r.exVerdict != w.exVerdict || r.owner != w.owner {
			t.Fatalf("%s: manifest {%s %s %d %t %s %s %s} disagrees with the inventory {%s %s %d %t %s %s %s}",
				r.site, r.bound, r.zero, r.min, r.hasMin, r.goVerdict, r.exVerdict, r.owner,
				w.bound, w.zero, w.min, w.hasMin, w.goVerdict, w.exVerdict, w.owner)
		}

		if !known[r.zero] || !known[r.goVerdict] || !known[r.exVerdict] {
			t.Fatalf("%s: verdict tokens %s/%s/%s are not all recognised", r.site, r.zero, r.goVerdict, r.exVerdict)
		}

		// A TWO-SIDED SITE MUST NAME ITS MINIMUM, and a one-sided one must not. Without the
		// pairing, a `zero: refuse` row with no `min` would look complete while leaving the
		// frozen minimum free to move up.
		if r.hasMin != (r.zero != verdictNA) {
			t.Fatalf("%s: zero=%s but hasMin=%t -- a refused zero freezes a minimum, and a "+
				"one-sided bound has neither", r.site, r.zero, r.hasMin)
		}

		if r.hasMin && (r.min < 1 || r.min > r.at) {
			t.Fatalf("%s: min %d is not in [1, %d]", r.site, r.min, r.at)
		}

		if r.over != r.at+1 {
			t.Fatalf("%s: %d/%d is not an adjacent pair", r.site, r.at, r.over)
		}

		// An absent peer must NAME AN OWNER, so a gap cannot become a silent exemption.
		if (r.exVerdict == verdictNA) != (r.owner != "-") {
			t.Fatalf("%s: elixir=%s owner=%s -- an absent peer must name an owner and a present one must not",
				r.site, r.exVerdict, r.owner)
		}
	}

	for site := range want {
		if !seen[site] {
			t.Fatalf("inventory site %q is missing from the scalar corpus", site)
		}
	}
}

// TestScalarCorpusBoundSet pins the DISTINCT BOUND SET, not a count. A count alone admits a
// row retitled under an existing bound, and the set alone admits a duplicate; both are checked.
func TestScalarCorpusBoundSet(t *testing.T) {
	want := map[string]bool{
		"MaxPolicyIDBytes": true, "MaxPrincipalBytes": true, "MaxPlanHeaderBytes": true,
		"MaxTraceStrBytes": true, "MaxReasonBytes": true,
	}

	got := map[string]bool{}
	for _, r := range scalarCorpus(t) {
		got[r.bound] = true
	}

	if len(got) != len(want) {
		t.Fatalf("the corpus names %d distinct bounds, want exactly %d", len(got), len(want))
	}

	for b := range want {
		if !got[b] {
			t.Fatalf("bound %q is named in the inventory but absent from the corpus", b)
		}
	}

	for b := range got {
		if !want[b] {
			t.Fatalf("the corpus names bound %q, which is not in the inventory", b)
		}
	}
}

// TestScalarCorpusConstants asserts THIS runtime's constants against the manifest.
func TestScalarCorpusConstants(t *testing.T) {
	live := map[string]int{
		"MaxPolicyIDBytes":   MaxPolicyIDBytes,
		"MaxPrincipalBytes":  MaxPrincipalBytes,
		"MaxPlanHeaderBytes": MaxPlanHeaderBytes,
		"MaxTraceStrBytes":   MaxTraceStrBytes,
		"MaxReasonBytes":     MaxReasonBytes,
	}

	for _, r := range scalarCorpus(t) {
		v, ok := live[r.bound]
		if !ok {
			t.Fatalf("%s names bound %s, which this runtime does not expose", r.site, r.bound)
		}

		if v != r.at {
			t.Fatalf("%s is %d in this runtime, the corpus freezes %d", r.bound, v, r.at)
		}
	}
}

// asciiOf builds a principal/policy of exactly n bytes from the frozen charset.
func asciiOf(n int) []byte { return bytes.Repeat([]byte("x"), n) }

// ---------------------------------------------------------------------------
// MaxPrincipalBytes -- three sites, four controls each
// ---------------------------------------------------------------------------

// Parallel to its sibling by design: the same bound proven at a DIFFERENT site, over a
// different slot type. Merging them hides which site each row belongs to.
//
//nolint:dupl // parallel by design; see above
func TestScalarSitePrincipalEdgeSlot(t *testing.T) {
	r := scalarRowFor(t, "principal_edge_slot")

	slot := func(id []byte) EdgeSlot {
		return EdgeSlot{
			NetworkScopeID:       mustUUID(t),
			AuthenticatedAgentID: id,
			SpoolID:              mustUUID(t),
			Sequence:             1,
		}
	}

	if _, err := DeliveryIDPreimage(slot(asciiOf(r.at))); err != nil {
		t.Fatalf("a %d-byte agent principal must be accepted: %v", r.at, err)
	}

	if _, err := DeliveryIDPreimage(slot(asciiOf(r.over))); !errors.Is(err, ErrPrincipal) {
		t.Fatalf("a %d-byte agent principal = %v, want ErrPrincipal", r.over, err)
	}

	// THE LOWER BOUND IS TWO CONTROLS, and both are asserted AT THIS SITE. Zero refused alone
	// leaves the frozen minimum free to move up -- a gate tightened to reject length 1 refuses
	// zero exactly as before -- so the smallest admissible value must be ACCEPTED too. And a
	// helper-level row proves the helper refuses zero, not that this slot still calls it.
	if _, err := DeliveryIDPreimage(slot(nil)); !errors.Is(err, ErrPrincipal) {
		t.Fatalf("an empty agent principal = %v, want ErrPrincipal", err)
	}

	if _, err := DeliveryIDPreimage(slot(asciiOf(r.min))); err != nil {
		t.Fatalf("a %d-byte agent principal is the frozen minimum and must be accepted: %v", r.min, err)
	}
}

// Parallel to its sibling by design: the same bound proven at a DIFFERENT site, over a
// different slot type. Merging them hides which site each row belongs to.
//
//nolint:dupl // parallel by design; see above
func TestScalarSitePrincipalServiceSlot(t *testing.T) {
	r := scalarRowFor(t, "principal_service_slot")

	slot := func(id []byte) ServiceSlot {
		return ServiceSlot{
			NetworkScopeID:         mustUUID(t),
			AuthenticatedServiceID: id,
			PublicationLaneID:      mustUUID(t),
			PublicationSequence:    1,
		}
	}

	if _, err := ServiceDeliveryIDPreimage(slot(asciiOf(r.at))); err != nil {
		t.Fatalf("a %d-byte service principal must be accepted: %v", r.at, err)
	}

	if _, err := ServiceDeliveryIDPreimage(slot(asciiOf(r.over))); !errors.Is(err, ErrPrincipal) {
		t.Fatalf("a %d-byte service principal = %v, want ErrPrincipal", r.over, err)
	}

	if _, err := ServiceDeliveryIDPreimage(slot(nil)); !errors.Is(err, ErrPrincipal) {
		t.Fatalf("an empty service principal = %v, want ErrPrincipal", err)
	}

	if _, err := ServiceDeliveryIDPreimage(slot(asciiOf(r.min))); err != nil {
		t.Fatalf("a %d-byte service principal is the frozen minimum and must be accepted: %v", r.min, err)
	}
}

// ---------------------------------------------------------------------------
// MaxTraceStrBytes at abort_reason -- GO ONLY, owner 1.6-c
// ---------------------------------------------------------------------------

func TestScalarSiteAbortReason(t *testing.T) {
	r := scalarRowFor(t, "abort_reason")

	if r.exVerdict != verdictNA || r.owner != "1.6-c" {
		t.Fatalf("abort_reason must stay Go-only with owner 1.6-c, manifest says %s/%s", r.exVerdict, r.owner)
	}

	// CONDITIONAL ON KIND, AND BOTH ARMS ARE RULES. An ABORTED event must carry a bounded
	// non-empty reason; every other kind must carry NONE. They are independently removable, so
	// six controls are needed -- an ABORTED-only set leaves the second arm unproven, and it is
	// the arm that stops a reason riding on an event that never aborted.
	ev := func(kind edgev1.SweepExecutionEventKind, reason string) *edgev1.SweepExecutionEventV1 {
		return &edgev1.SweepExecutionEventV1{
			ExecutionId: mustUUID(t), ExecutionPlanId: mustUUID(t), TargetRangeId: mustUUID(t),
			ExecutionPlanSha256: d32(0x10),
			Kind:                kind,
			EmittedAtUnixNano:   1,
			AbortReason:         reason,
		}
	}

	const aborted = edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_ABORTED

	// A kind that is NOT aborted and carries no extra obligations: COMPLETED would add the
	// completion-proof rules and refuse the fixture for those instead of for this one.
	const other = edgev1.SweepExecutionEventKind_SWEEP_EXECUTION_EVENT_KIND_START

	if other == aborted {
		t.Fatal("the non-aborted control must not be the aborted kind")
	}

	// Arm 1: ABORTED -- bounded and non-empty.
	if err := ValidateSweepExecutionEvent(ev(aborted, strings.Repeat("x", r.at))); err != nil {
		t.Fatalf("a %d-byte abort reason must be accepted: %v", r.at, err)
	}

	if err := ValidateSweepExecutionEvent(ev(aborted, strings.Repeat("x", r.over))); !errors.Is(err, ErrLifecycle) {
		t.Fatalf("a %d-byte abort reason = %v, want ErrLifecycle", r.over, err)
	}

	if err := ValidateSweepExecutionEvent(ev(aborted, "")); !errors.Is(err, ErrLifecycle) {
		t.Fatalf("an empty abort reason on an ABORTED event = %v, want ErrLifecycle", err)
	}

	if err := ValidateSweepExecutionEvent(ev(aborted, strings.Repeat("x", r.min))); err != nil {
		t.Fatalf("a %d-byte abort reason is the frozen minimum and must be accepted: %v", r.min, err)
	}

	// Arm 2: NOT ABORTED -- absent is the only admissible value. The accepted control is what
	// makes the refusal below mean something: without it, a predicate that refused every
	// non-aborted event would satisfy the negative row.
	if err := ValidateSweepExecutionEvent(ev(other, "")); err != nil {
		t.Fatalf("a non-ABORTED event with no reason must be accepted: %v", err)
	}

	if err := ValidateSweepExecutionEvent(ev(other, "x")); !errors.Is(err, ErrLifecycle) {
		t.Fatalf("a reason on a non-ABORTED event = %v, want ErrLifecycle", err)
	}
}

// ---------------------------------------------------------------------------
// MaxPolicyIDBytes -- two carriers, four controls each
// ---------------------------------------------------------------------------

// repointPlanPolicy re-points a plan's availability policy through EVERY range and reseals
// every commitment that covers it: range digest, page digest, plan root, MTR commitment and
// the header digest. Holding any of them fixed would make the artifact fail a RELATION rather
// than the ceiling, so the row would pass while proving the wrong rule.
func repointPlanPolicy(t *testing.T, h *edgev1.ScheduledPlanHeaderV1, pages []*edgev1.ScheduledPlanPageV1,
	policy []byte,
) (*edgev1.ScheduledPlanHeaderV1, []*edgev1.ScheduledPlanPageV1) {
	t.Helper()

	out := make([]*edgev1.ScheduledPlanPageV1, len(pages))

	var prev []byte

	for i, p := range pages {
		page, ok := proto.Clone(p).(*edgev1.ScheduledPlanPageV1)
		if !ok {
			t.Fatalf("clone plan page %d", i)
		}

		for _, rg := range page.GetRanges() {
			rg.AvailabilityPolicyId = policy
			rg.RangeSha256 = RangeDigest(rg)
		}

		page.PrevPageSha256 = prev
		page.PageSha256 = PlanPageDigest(page)
		prev = page.PageSha256
		out[i] = page
	}

	header, ok := proto.Clone(h).(*edgev1.ScheduledPlanHeaderV1)
	if !ok {
		t.Fatalf("clone plan header")
	}

	header.AvailabilityPolicyId = policy
	header.PlanRootSha256 = PlanRoot(out)
	header.MtrOrdinalRangeCommitment = mustPlanCommitment(t, out)
	header.ExecutionPlanSha256 = PlanHeaderDigest(header)

	return header, out
}

func TestScalarSitePolicyPlanHeader(t *testing.T) {
	r := scalarRowFor(t, "policy_plan_header")

	base, basePages := buildPlan(t, mustUUID(t), d32(0x51), [][]uint64{{1, 1}})

	at, atPages := repointPlanPolicy(t, base, basePages, asciiOf(r.at))
	if err := ValidatePlanPages(at, atPages); err != nil {
		t.Fatalf("a %d-byte header policy must be accepted: %v", r.at, err)
	}

	// CONSISTENT over-limit: the same value in the header and in every range, so only the
	// header's LENGTH rule can refuse it. An inconsistent fixture would be refused by the
	// range's EQUALITY arm instead, proving a different rule under a verdict that looks right.
	over, overPages := repointPlanPolicy(t, base, basePages, asciiOf(r.over))
	if err := ValidatePlanPages(over, overPages); !errors.Is(err, ErrPlanPolicy) {
		t.Fatalf("a %d-byte header policy = %v, want ErrPlanPolicy", r.over, err)
	}

	empty, emptyPages := repointPlanPolicy(t, base, basePages, nil)
	if err := ValidatePlanPages(empty, emptyPages); !errors.Is(err, ErrPlanPolicy) {
		t.Fatalf("an empty header policy = %v, want ErrPlanPolicy", err)
	}

	// THE FROZEN MINIMUM IS ACCEPTED. Without this the gate could be tightened to reject
	// length 1 and every row above would still pass.
	minH, minPages := repointPlanPolicy(t, base, basePages, asciiOf(r.min))
	if err := ValidatePlanPages(minH, minPages); err != nil {
		t.Fatalf("a %d-byte header policy is the frozen minimum and must be accepted: %v", r.min, err)
	}
}

func TestScalarSitePolicyAssignmentRecord(t *testing.T) {
	r := scalarRowFor(t, "policy_assignment_record")

	rec := func(policy []byte) *edgev1.SweepAssignmentRecordV1 {
		a := validAssignment(t)
		a.AvailabilityPolicyId = policy

		return a
	}

	if err := ValidateSweepAssignmentRecord(rec(asciiOf(r.at))); err != nil {
		t.Fatalf("a %d-byte assignment policy must be accepted: %v", r.at, err)
	}

	if err := ValidateSweepAssignmentRecord(rec(asciiOf(r.over))); !errors.Is(err, ErrAssignmentScope) {
		t.Fatalf("a %d-byte assignment policy = %v, want ErrAssignmentScope", r.over, err)
	}

	// THE SECOND CARRIER'S LOWER BOUND IS ITS OWN RULE. The two carriers share one logical
	// vector but not one gate: deleting either leaves the other's rows green.
	if err := ValidateSweepAssignmentRecord(rec(nil)); !errors.Is(err, ErrAssignmentScope) {
		t.Fatalf("an empty assignment policy = %v, want ErrAssignmentScope", err)
	}

	if err := ValidateSweepAssignmentRecord(rec(asciiOf(r.min))); err != nil {
		t.Fatalf("a %d-byte assignment policy is the frozen minimum and must be accepted: %v", r.min, err)
	}
}

func TestScalarSitePrincipalProducerContext(t *testing.T) {
	r := scalarRowFor(t, "principal_producer_context")

	if r.exVerdict != verdictNA || r.owner != proofGroup15N {
		t.Fatalf("the producer-context principal has no peer here; manifest says %s/%s", r.exVerdict, r.owner)
	}

	rec := func(id []byte) *edgev1.EdgeRecordV1 {
		e := validRecord(t)
		e.GetProducerContext().OriginPrincipalId = id

		// THE MATCHING CAPABILITY CLAIM MOVES WITH IT. `validateProductionCapability` compares
		// claims.origin_principal_id byte-for-byte against producer_context, so a record
		// re-pointed on one side alone is refused for a CLAIM MISMATCH (ErrProductionGrant) --
		// another rule's outcome standing in for the ceiling's.
		e.GetProductionCapability().GetProduction().OriginPrincipalId = id
		// The semantic envelope commits producer_context, so it is resealed LAST.
		e.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(e)

		return e
	}

	if err := ValidateRecord(rec(asciiOf(r.at))); err != nil {
		t.Fatalf("a %d-byte origin principal must be accepted: %v", r.at, err)
	}

	if err := ValidateRecord(rec(asciiOf(r.over))); !errors.Is(err, ErrPrincipal) {
		t.Fatalf("a %d-byte origin principal = %v, want ErrPrincipal", r.over, err)
	}

	if err := ValidateRecord(rec(nil)); !errors.Is(err, ErrPrincipal) {
		t.Fatalf("an empty origin principal = %v, want ErrPrincipal", err)
	}

	if err := ValidateRecord(rec(asciiOf(r.min))); err != nil {
		t.Fatalf("a %d-byte origin principal is the frozen minimum and must be accepted: %v", r.min, err)
	}
}

// ---------------------------------------------------------------------------
// MaxPlanHeaderBytes -- the one RAW, one-sided site
// ---------------------------------------------------------------------------

func TestScalarSitePlanHeaderRaw(t *testing.T) {
	r := scalarRowFor(t, "plan_header_raw")

	// ONE-SIDED, and the manifest says so. An empty header is refused, but for being an
	// unparseable/incomplete header -- not by this ceiling, which only bounds from above.
	if r.zero != verdictNA || r.hasMin {
		t.Fatalf("plan_header_raw is a one-sided bound; manifest says zero=%s hasMin=%t", r.zero, r.hasMin)
	}

	h, pages := buildPlan(t, mustUUID(t), d32(0x61), [][]uint64{{1}})
	base := headerBytes(t, h)
	num := fieldNumber(t, &edgev1.ScheduledPlanHeaderV1{}, "check_set_sha256")

	// PADDED TO AN EXACT BYTE COUNT AND STILL VALID: the filler is a duplicate field the true
	// value overwrites, so both encodings decode to the SAME header. A fixture that only
	// reached the ceiling by being malformed would be refused by the decoder instead.
	atRaw := padToExactBytes(t, base, num, h.GetCheckSetSha256(), r.at)
	overRaw := padToExactBytes(t, base, num, h.GetCheckSetSha256(), r.over)

	for name, raw := range map[string][]byte{"at": atRaw, "over": overRaw} {
		var round edgev1.ScheduledPlanHeaderV1
		if err := proto.Unmarshal(raw, &round); err != nil {
			t.Fatalf("%s-limit header must decode: %v", name, err)
		}

		if !proto.Equal(&round, h) {
			t.Fatalf("%s-limit header must decode to the same header", name)
		}
	}

	if _, _, err := ValidatePlanFromRaw(atRaw, rawPlanPagesOf(t, pages)); err != nil {
		t.Fatalf("exactly %d header bytes must be accepted: %v", r.at, err)
	}

	if _, _, err := ValidatePlanFromRaw(overRaw, rawPlanPagesOf(t, pages)); !errors.Is(err, ErrPlanHeaderTooLarge) {
		t.Fatalf("%d header bytes = %v, want ErrPlanHeaderTooLarge", r.over, err)
	}
}

// TestScalarStageWitnessPlanHeaderRaw proves the size gate runs BEFORE the decode, which the
// N/N+1 pair above cannot: a validator that decoded first and bounded afterwards returns the
// same verdict on the same inputs.
//
// The witness is an over-limit header that is ALSO undecodable. A decode failure maps to
// ErrPlanBounds and the size refusal to ErrPlanHeaderTooLarge, so the two stages are separable
// by verdict here -- no tracing needed on this side.
func TestScalarStageWitnessPlanHeaderRaw(t *testing.T) {
	r := scalarRowFor(t, "plan_header_raw")

	h, pages := buildPlan(t, mustUUID(t), d32(0x62), [][]uint64{{1}})
	base := headerBytes(t, h)
	num := fieldNumber(t, &edgev1.ScheduledPlanHeaderV1{}, "check_set_sha256")

	raw := padToExactBytes(t, base, num, h.GetCheckSetSha256(), r.over)
	// A TRUNCATED LENGTH-DELIMITED FIELD at the tail: it declares more bytes than remain, so any
	// parse must fail, and appending it only grows the input -- the header is still over the
	// ceiling, which is asserted below rather than assumed.
	raw = append(raw, byte(num<<3|2), 0xFF)

	var probe edgev1.ScheduledPlanHeaderV1
	if err := proto.Unmarshal(raw, &probe); err == nil {
		t.Fatal("the witness must be undecodable, or it cannot separate the two stages")
	}

	if len(raw) <= MaxPlanHeaderBytes {
		t.Fatalf("the witness is %d bytes, not over the ceiling", len(raw))
	}

	if _, _, err := ValidatePlanFromRaw(raw, rawPlanPagesOf(t, pages)); !errors.Is(err, ErrPlanHeaderTooLarge) {
		t.Fatalf("an over-limit UNDECODABLE header = %v, want ErrPlanHeaderTooLarge -- the "+
			"header was parsed before its size was bounded", err)
	}
}

// ---------------------------------------------------------------------------
// MaxReasonBytes -- GO ONLY, on the SIGNED recovery-control path. Owner 1.6-d.
// ---------------------------------------------------------------------------

func TestScalarSiteTombstoneReasonSigned(t *testing.T) {
	r := scalarRowFor(t, "tombstone_reason_signed")

	if r.exVerdict != verdictNA || r.owner != proofGroup16D {
		t.Fatalf("the signed tombstone reason has no peer here; manifest says %s/%s", r.exVerdict, r.owner)
	}

	// SEAL ORDER: the tombstone is finished FIRST, its scope digest is taken from the finished
	// body, and the wrapper -- payload, source claim, envelope, both signatures -- is built
	// around it afterwards. Nothing is mutated after signing.
	wrap := func(reason string) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
		pages := buildManifest(t, mustUUID(t),
			[][]*edgev1.EdgeClassificationSpanV1{spansOf(t, 1)})

		tomb := &edgev1.SpoolLossTombstoneV1{
			RecoveryId:         pages[0].GetRecoveryId(),
			PriorSpoolId:       mustUUID(t),
			NewSpoolId:         mustUUID(t),
			DetectedAtUnixNano: 1_700_000_000_000_000_000,
			DigestVersion:      RecoveryDigestVersion,
			ManifestPageCount:  uint32(len(pages)),
			ManifestRootSha256: ManifestRoot(pages),
			Reason:             reason,
		}

		body := &edgev1.EdgeRecoveryControlPayloadV1{
			Body: &edgev1.EdgeRecoveryControlPayloadV1_Tombstone{Tombstone: tomb},
		}

		return scopeControlRecord(t, body, tomb.GetRecoveryId(), TombstoneScopeDigest(tomb))
	}

	check := func(name, reason string, want error) {
		t.Helper()

		rec, policy := wrap(reason)

		// SIGNED-VALID BEFORE ANY PRODUCTION CLAIM, or a stale signature could masquerade as
		// ceiling evidence.
		if err := ValidateRecordSigned(rec, policy); err != nil {
			t.Fatalf("%s: the wrapper must pass the signed boundary: %v", name, err)
		}

		err := ValidateRecoveryControl(rec, rec.GetOutputContract(), policy)
		if want == nil {
			if err != nil {
				t.Fatalf("%s: must be accepted: %v", name, err)
			}

			return
		}

		if !errors.Is(err, want) {
			t.Fatalf("%s: = %v, want %v", name, err, want)
		}
	}

	check("at ceiling", strings.Repeat("x", r.at), nil)
	check("one over", strings.Repeat("x", r.over), ErrTombstoneMismatch)
	// THE LOWER BOUND IS ITS OWN RULE, frozen normatively: an empty reason is refused. A pair
	// omitting it leaves that half of the gate unproven.
	check("empty", "", ErrTombstoneMismatch)
	// THE FROZEN MINIMUM, accepted. A zero refusal alone leaves the minimum free to move up.
	check("frozen minimum", strings.Repeat("x", r.min), nil)
}
