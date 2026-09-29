package edgerecord

import (
	"bufio"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// Task 1.5-h: THE SHARED LOWER-BOUND CORPUS.
//
// ITS OWN INVENTORY, NOT AN EXTENSION OF THE COUNT CORPUS. The upper table proves each site's
// ceiling with an N/N+1 pair; extending it mechanically with one empty row per site would
// assert independent proofs the implementations do not provide, because several local
// emptiness predicates are SHADOWED by a later check that refuses the same input.
//
// So this file asks a different question and answers it per runtime: what does the BOUNDARY
// do with an empty collection, and what would removing the LOCAL arm actually change? The
// second answer is the `go_removal` column, and it is MEASURED -- see the manifest for what
// each token licenses a row to claim.
//
// TWO CONTROLS PER RULE. Zero refused alone does not pin a minimum of 1: an implementation
// demanding two elements refuses zero exactly as before. The ONE-element acceptance is what
// makes it a bound rather than a prohibition.

type lowerRow struct {
	site, kind           string
	zero, one            string
	at, over             int
	hasBounds            bool
	goRemoval, exRemoval string
	owner                string
}

func lowerCorpus(t *testing.T) []lowerRow {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	f, err := os.Open(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1", "testdata", "lower_bound_corpus.txt"))
	if err != nil {
		t.Fatalf("open lower-bound corpus: %v", err)
	}
	defer func() { _ = f.Close() }()

	var out []lowerRow

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 9 {
			t.Fatalf("lower-bound row %q has %d fields, want 9", line, len(fields))
		}

		row := lowerRow{
			site: fields[0], kind: fields[1], zero: fields[2], one: fields[3],
			goRemoval: fields[6], exRemoval: fields[7], owner: fields[8],
		}

		if fields[4] == verdictNA && fields[5] != verdictNA {
			t.Fatalf("row %q: at is n/a but over is %q -- one would be ignored", line, fields[5])
		}

		if fields[4] != verdictNA {
			at, err := strconv.Atoi(fields[4])
			if err != nil {
				t.Fatalf("row %q: at: %v", line, err)
			}

			over, err := strconv.Atoi(fields[5])
			if err != nil {
				t.Fatalf("row %q: over: %v", line, err)
			}

			row.at, row.over, row.hasBounds = at, over, true
		}

		out = append(out, row)
	}

	if err := sc.Err(); err != nil {
		t.Fatalf("scan lower-bound corpus: %v", err)
	}

	return out
}

func lowerRowFor(t *testing.T, site string) lowerRow {
	t.Helper()

	for _, r := range lowerCorpus(t) {
		if r.site == site {
			return r
		}
	}

	t.Fatalf("no lower-bound row for site %q", site)

	return lowerRow{}
}

// TestLowerCorpusInventory pins the full row. The `*_removal` tokens are the part most likely
// to drift optimistically -- an arm that becomes shadowed still passes every verdict row, so
// nothing but this comparison notices the claim is now too strong.
func TestLowerCorpusInventory(t *testing.T) {
	want := map[string]lowerRow{
		"plan_pages_decoded":       {kind: "collection", goRemoval: "retags", exRemoval: "retags", owner: "-"},
		"plan_pages_raw":           {kind: "collection", goRemoval: "silent", exRemoval: "combined", owner: "-"},
		"plan_ranges":              {kind: "collection", goRemoval: "admits", exRemoval: "admits", owner: "-"},
		"recovery_pages_decoded":   {kind: "collection", goRemoval: "crashes", exRemoval: "crashes", owner: "-"},
		"recovery_pages_raw":       {kind: "collection", goRemoval: "silent", exRemoval: "silent", owner: "-"},
		"recovery_spans_chain":     {kind: "collection", goRemoval: "retags", exRemoval: "retags", owner: "-"},
		"recovery_spans_single":    {kind: "collection", goRemoval: "retags", exRemoval: verdictNA, owner: proofGroup16D},
		"tombstone_declared_count": {kind: "scalar", goRemoval: "admits", exRemoval: verdictNA, owner: proofGroup16D, at: 1024, over: 1025, hasBounds: true},
	}

	removals := map[string]bool{
		"admits": true, "crashes": true, "retags": true,
		"silent": true, "combined": true, verdictNA: true,
	}

	rows := lowerCorpus(t)
	if len(rows) != len(want) {
		t.Fatalf("corpus has %d rows, inventory has %d -- a duplicate or missing row", len(rows), len(want))
	}

	// A LENGTH CHECK ALONE ADMITS SUBSTITUTION: duplicating one site while deleting another
	// keeps the count, and every per-row check below then passes twice on the survivor.
	seen := map[string]bool{}

	for _, r := range rows {
		if seen[r.site] {
			t.Fatalf("%s appears twice in the corpus", r.site)
		}

		seen[r.site] = true
	}

	for _, r := range rows {
		w, ok := want[r.site]
		if !ok {
			t.Fatalf("corpus row %q is not in the inventory", r.site)
		}

		if r.kind != w.kind || r.goRemoval != w.goRemoval || r.exRemoval != w.exRemoval ||
			r.owner != w.owner || r.at != w.at || r.over != w.over || r.hasBounds != w.hasBounds {
			t.Fatalf("%s: manifest and inventory disagree", r.site)
		}

		if r.zero != verdictRefuse || r.one != verdictAccept {
			t.Fatalf("%s: a lower bound of 1 is zero=refuse/one=accept, got %s/%s", r.site, r.zero, r.one)
		}

		if !removals[r.goRemoval] || !removals[r.exRemoval] {
			t.Fatalf("%s: removal tokens %s/%s are not both recognised", r.site, r.goRemoval, r.exRemoval)
		}

		// An absent peer must NAME AN OWNER. `n/a` is the only token that may.
		if (r.exRemoval == verdictNA) != (r.owner != "-") {
			t.Fatalf("%s: ex_removal=%s owner=%s -- an absent peer must name an owner and a present one must not",
				r.site, r.exRemoval, r.owner)
		}

		// Only the DECLARED-SCALAR rule freezes a ceiling here; a collection's ceiling belongs
		// to the count corpus and restating it would create a second inventory to keep in sync.
		if r.hasBounds != (r.kind == "scalar") {
			t.Fatalf("%s: kind=%s but hasBounds=%t", r.site, r.kind, r.hasBounds)
		}

		if r.hasBounds && r.over != r.at+1 {
			t.Fatalf("%s: %d/%d is not an adjacent pair", r.site, r.at, r.over)
		}

		// The reader only inspects `over` when `at` is numeric, so a row reading `n/a 1025`
		// would otherwise carry a silently ignored value.
		if !r.hasBounds && r.over != 0 {
			t.Fatalf("%s: at is n/a but over parsed as %d", r.site, r.over)
		}
	}
}

// ---------------------------------------------------------------------------
// collection sites -- zero refused, one accepted, at the BOUNDARY
// ---------------------------------------------------------------------------

func TestLowerSitePlanPages(t *testing.T) {
	decoded := lowerRowFor(t, "plan_pages_decoded")
	raw := lowerRowFor(t, "plan_pages_raw")

	h, pages := buildPlan(t, mustUUID(t), d32(0x81), [][]uint64{{1}})

	if err := ValidatePlanPages(h, nil); !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("an empty decoded page list = %v, want ErrPlanBounds", err)
	}

	// ONE PAGE IS ADMITTED. Without it the row would be satisfied by a validator demanding two.
	if err := ValidatePlanPages(h, pages); err != nil {
		t.Fatalf("a one-page plan must be accepted: %v", err)
	}

	if _, _, err := ValidatePlanFromRaw(headerBytes(t, h), [][]byte{}); !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("an empty raw page list = %v, want ErrPlanBounds", err)
	}

	if _, _, err := ValidatePlanFromRaw(headerBytes(t, h), rawPlanPagesOf(t, pages)); err != nil {
		t.Fatalf("a one-page raw plan must be accepted: %v", err)
	}

	// The raw row records BOUNDARY behaviour only: its local arm is `silent`, so removing it
	// changes no verdict here -- the decoded gate refuses the same input for the same reason.
	if raw.goRemoval != "silent" || decoded.goRemoval != "retags" {
		t.Fatalf("removal classes changed: raw=%s decoded=%s", raw.goRemoval, decoded.goRemoval)
	}
}

func TestLowerSitePlanRanges(t *testing.T) {
	r := lowerRowFor(t, "plan_ranges")

	if r.goRemoval != "admits" {
		t.Fatalf("plan_ranges is the load-bearing plan arm; manifest says %s", r.goRemoval)
	}

	h, pages := buildPlan(t, mustUUID(t), d32(0x82), [][]uint64{{1}})

	if err := ValidatePlanPages(h, pages); err != nil {
		t.Fatalf("a one-range page must be accepted: %v", err)
	}

	empty, ok := proto.Clone(pages[0]).(*edgev1.ScheduledPlanPageV1)
	if !ok {
		t.Fatal("clone plan page")
	}

	empty.Ranges = nil
	empty.PageSha256 = PlanPageDigest(empty)

	one := []*edgev1.ScheduledPlanPageV1{empty}

	eh, ok := proto.Clone(h).(*edgev1.ScheduledPlanHeaderV1)
	if !ok {
		t.Fatal("clone plan header")
	}

	// RESEALED so the empty page is refused by its own rule and not by a stale digest,
	// declared total or commitment.
	eh.PlanRootSha256 = PlanRoot(one)
	eh.TotalTargetCount = 0
	eh.MtrOrdinalRangeCommitment = mustPlanCommitment(t, one)
	eh.ExecutionPlanSha256 = PlanHeaderDigest(eh)

	if err := ValidatePlanPages(eh, one); !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("a page with no ranges = %v, want ErrPlanBounds", err)
	}
}

func TestLowerSiteRecoveryPages(t *testing.T) {
	decoded := lowerRowFor(t, "recovery_pages_decoded")
	raw := lowerRowFor(t, "recovery_pages_raw")

	pages := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{spansOf(t, 1)})
	root := ManifestRoot(pages)

	if err := ValidateManifestChain(nil, root); !errors.Is(err, ErrManifestEmpty) {
		t.Fatalf("an empty decoded manifest = %v, want ErrManifestEmpty", err)
	}

	if err := ValidateManifestChain(pages, root); err != nil {
		t.Fatalf("a one-page manifest must be accepted: %v", err)
	}

	if err := ValidateManifestChainFromRaw([][]byte{}, root); !errors.Is(err, ErrManifestEmpty) {
		t.Fatalf("an empty raw manifest = %v, want ErrManifestEmpty", err)
	}

	if err := ValidateManifestChainFromRaw(rawPagesOf(t, pages), root); err != nil {
		t.Fatalf("a one-page raw manifest must be accepted: %v", err)
	}

	// THE DECODED ARM IS NOT MERELY A VERDICT. Removing it indexes page zero of an empty
	// slice, so it is what keeps a public validator from PANICKING on attacker-supplied
	// input -- which is why the manifest classes it `crashes` and not `retags`.
	if decoded.goRemoval != "crashes" || raw.goRemoval != "silent" {
		t.Fatalf("removal classes changed: decoded=%s raw=%s", decoded.goRemoval, raw.goRemoval)
	}
}

func TestLowerSiteRecoverySpans(t *testing.T) {
	chain := lowerRowFor(t, "recovery_spans_chain")
	single := lowerRowFor(t, "recovery_spans_single")

	if single.exRemoval != verdictNA || single.owner != proofGroup16D {
		t.Fatalf("the single-page span site is Go-only; manifest says %s/%s", single.exRemoval, single.owner)
	}

	pages := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{spansOf(t, 1)})

	if err := ValidateManifestChain(pages, ManifestRoot(pages)); err != nil {
		t.Fatalf("a one-span page must be accepted: %v", err)
	}

	// THE SINGLE-PAGE SITE IS DRIVEN THROUGH ITS PUBLIC BOUNDARY, as the upper pair is.
	// `validateSingleManifestPage` is private and reachable only via `ValidateRecoveryControl`,
	// so calling it directly would prove the predicate while leaving the ROUTE to it untested
	// -- and the route is half of what the site is.
	wrap := func(spans []*edgev1.EdgeClassificationSpanV1) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
		page := buildManifest(t, mustUUID(t),
			[][]*edgev1.EdgeClassificationSpanV1{spansOf(t, 1)})[0]

		// Finished FIRST -- spans, then count/index/terminal, then its own digest -- and only
		// then is the scope digest taken and the wrapper built around it.
		page.ClassificationSpans = spans
		page.PageIndex, page.PageCount, page.Terminal, page.PrevPageSha256 = 0, 1, true, nil
		page.PageSha256 = ManifestPageDigest(page)

		body := &edgev1.EdgeRecoveryControlPayloadV1{
			Body: &edgev1.EdgeRecoveryControlPayloadV1_ManifestPage{ManifestPage: page},
		}

		return scopeControlRecord(t, body, page.GetRecoveryId(), ManifestPageScopeDigest(page))
	}

	checkSingle := func(name string, spans []*edgev1.EdgeClassificationSpanV1, want error) {
		t.Helper()

		rec, policy := wrap(spans)

		// SIGNED-VALID BEFORE ANY PRODUCTION CLAIM, or a stale signature could masquerade as
		// bound evidence.
		if err := ValidateRecordSigned(rec, policy); err != nil {
			t.Fatalf("%s: the wrapper must pass the signed boundary first: %v", name, err)
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

	checkSingle("one span", spansOf(t, 1), nil)

	empty, ok := proto.Clone(pages[0]).(*edgev1.EdgeLossManifestPageV1)
	if !ok {
		t.Fatal("clone manifest page")
	}

	empty.ClassificationSpans = nil
	empty.PageSha256 = ManifestPageDigest(empty)

	one := []*edgev1.EdgeLossManifestPageV1{empty}

	// THE EXACT REFUSAL REASON, not merely "refused". Both arms are `retags`: with the local
	// check removed the boundary still refuses, under the span-body reason instead. Asserting
	// the reason is what makes these rows kill that removal.
	if err := ValidateManifestChain(one, ManifestRoot(one)); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("a page with no spans = %v, want ErrManifestBounds", err)
	}

	checkSingle("no spans", nil, ErrManifestBounds)

	if chain.goRemoval != "retags" {
		t.Fatalf("the chain span arm is classed %s", chain.goRemoval)
	}
}

// ---------------------------------------------------------------------------
// the DECLARED SCALAR -- four controls on the signed path
// ---------------------------------------------------------------------------

// TestLowerSiteTombstoneDeclaredCount covers the rule this task freezes: a signed tombstone's
// `manifest_page_count` is bounded 1..MaxManifestPages, not merely non-zero.
//
// IT IS A DIFFERENT SITE FROM THE PAGE-LIST BOUND. `ValidateTombstone` reconciles a
// declaration against supplied pages; this path receives NO pages, so nothing questions the
// declaration and the scope digest commits it exactly as signed.
//
// EACH CONTROL IS FULLY RESCOPED AND RE-SIGNED. The tombstone is built first, its scope digest
// taken from the finished body, and the payload, source claim, envelope and both signatures
// built around it -- so a control never reuses a wrapper whose signature describes a different
// declaration. ValidateRecordSigned is asserted BEFORE the production claim, or a stale
// signature could masquerade as bound evidence.
func TestLowerSiteTombstoneDeclaredCount(t *testing.T) {
	r := lowerRowFor(t, "tombstone_declared_count")

	if r.kind != "scalar" || r.owner != proofGroup16D {
		t.Fatalf("the declared count is a Go-only scalar rule owned by 1.6-d; manifest says %s/%s", r.kind, r.owner)
	}

	wrap := func(count uint32) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
		id := mustUUID(t)

		tomb := &edgev1.SpoolLossTombstoneV1{
			RecoveryId:         id,
			PriorSpoolId:       mustUUID(t),
			NewSpoolId:         mustUUID(t),
			DetectedAtUnixNano: 1_700_000_000_000_000_000,
			DigestVersion:      RecoveryDigestVersion,
			ManifestPageCount:  count,
			ManifestRootSha256: d32(0x83),
			Reason:             "corpus",
		}

		body := &edgev1.EdgeRecoveryControlPayloadV1{
			Body: &edgev1.EdgeRecoveryControlPayloadV1_Tombstone{Tombstone: tomb},
		}

		return scopeControlRecord(t, body, id, TombstoneScopeDigest(tomb))
	}

	check := func(name string, count uint32, want error) {
		t.Helper()

		rec, policy := wrap(count)

		if err := ValidateRecordSigned(rec, policy); err != nil {
			t.Fatalf("%s: the wrapper must pass the signed boundary first: %v", name, err)
		}

		err := ValidateRecoveryControl(rec, rec.GetOutputContract(), policy)
		if want == nil {
			if err != nil {
				t.Fatalf("%s: count %d must be accepted: %v", name, count, err)
			}

			return
		}

		if !errors.Is(err, want) {
			t.Fatalf("%s: count %d = %v, want %v", name, count, err, want)
		}
	}

	check("zero", 0, ErrTombstoneMismatch)
	// The frozen minimum, ACCEPTED -- without it a gate demanding two pages passes "zero".
	check("minimum", 1, nil)
	check("at ceiling", uint32(r.at), nil)
	check("one over", uint32(r.over), ErrTombstoneMismatch)
}
