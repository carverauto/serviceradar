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

// Task 1.5-h: THE SHARED STRUCTURAL-COUNT CORPUS.
//
// THREE BOUND-VECTOR PAIRS, FOUR TYPED ADAPTERS, EIGHT SITES. `MaxManifestPages` has two
// CARRIERS -- plan pages and recovery pages -- which share the literals in the manifest and
// cannot share serialized bytes, because a plan page and a manifest page are different
// messages. Several SITES reuse one carrier; each is an independently removable gate.
//
// THE LITERALS COME FROM THE MANIFEST, NOT THE CONSTANTS. Building `over` as `Max...+1` moves
// every row with the bound, so a ceiling drifting to 128 keeps the corpus green. The constants
// are asserted AGAINST the manifest instead.
//
// EVERY N+1 ARTIFACT IS FULLY RESEALED, WITH ITS DECLARATIONS SET TO N+1. A 1025-page list
// whose header still declares 1024 is refused by the COUNT RELATION, not the ceiling -- the
// row would pass while proving the wrong rule, exactly as the tombstone's declared-count
// comparison did before it was ordered behind the bound.
//
// A PLAIN N+1 VERDICT DOES NOT PROVE A RAW GATE -- measured, not argued. With both raw count
// gates deleted, EVERY verdict row here stays green and only the two STAGE WITNESSES fail,
// because the decoded gate behind each raw gate returns the same bounds error. Each witness is
// built from a competing fault whose result is distinguishable from the ceiling's.

type countRow struct {
	site, carrier, bound string
	at, over             int
	goVerdict, exVerdict string
	owner                string
}

func countCorpus(t *testing.T) []countRow {
	t.Helper()

	f, err := os.Open(filepath.Join("..", "..", "..", "..", "proto", "edge", "v1", "testdata", "count_corpus.txt"))
	if err != nil {
		t.Fatalf("open count corpus: %v", err)
	}
	defer func() { _ = f.Close() }()

	var rows []countRow

	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		c := strings.Fields(line)
		if len(c) != 8 {
			t.Fatalf("count corpus row has %d columns, want 8: %q", len(c), line)
		}

		at, err := strconv.Atoi(c[3])
		if err != nil {
			t.Fatalf("row %q: at: %v", c[0], err)
		}

		over, err := strconv.Atoi(c[4])
		if err != nil {
			t.Fatalf("row %q: over: %v", c[0], err)
		}
		if over != at+1 {
			t.Fatalf("row %q: over %d is not at+1 (%d); the pair must be adjacent or it "+
				"proves a gap rather than a boundary", c[0], over, at+1)
		}

		rows = append(rows, countRow{c[0], c[1], c[2], at, over, c[5], c[6], c[7]})
	}

	if err := s.Err(); err != nil {
		t.Fatalf("read count corpus: %v", err)
	}

	return rows
}

// TestCountCorpusPinsTheFrozenLiterals asserts the CONSTANTS against the manifest, which is
// the only direction that catches drift: the adapters read the manifest, so a bound moving
// under them changes nothing here unless this row objects.
func TestCountCorpusPinsTheFrozenLiterals(t *testing.T) {
	want := map[string]int{
		"MaxManifestPages": MaxManifestPages,
		"MaxRangesPerPage": MaxRangesPerPage,
		"MaxSpansPerPage":  MaxSpansPerPage,
	}

	seen := map[string]bool{}

	for _, r := range countCorpus(t) {
		got, ok := want[r.bound]
		if !ok {
			t.Fatalf("row %q names bound %q, which is not in this corpus's inventory", r.site, r.bound)
		}
		if got != r.at {
			t.Fatalf("%s = %d, but the corpus freezes %d", r.bound, got, r.at)
		}
		seen[r.bound] = true
	}

	for b := range want {
		if !seen[b] {
			t.Fatalf("bound %q is in the inventory and has no corpus row", b)
		}
	}
}

// TestCountCorpusCoversEverySite compares a HAND-WRITTEN inventory against the manifest in
// both directions, pinning EVERY column and not just the site names.
//
// A PARTIAL GUARD IS A GREEN LIGHT FOR DRIFT. Checking only site->carrier leaves the BOUND
// and the VERDICTS free: `MaxRangesPerPage` and `MaxSpansPerPage` share the value 256, so
// swapping them changes no row's arithmetic and every consumer stays green while the manifest
// now says something false about which ceiling each site enforces. A verdict token can be
// edited the same way. The inventory therefore states the whole tuple.
func TestCountCorpusCoversEverySite(t *testing.T) {
	type spec struct{ carrier, bound, goV, exV, owner string }

	inventory := map[string]spec{
		"plan_raw":              {"plan_pages", "MaxManifestPages", verdictRefuse, verdictRefuse, "-"},
		"plan_decoded":          {"plan_pages", "MaxManifestPages", verdictRefuse, verdictRefuse, "-"},
		"recovery_raw":          {"recovery_pages", "MaxManifestPages", verdictRefuse, verdictRefuse, "-"},
		"recovery_decoded":      {"recovery_pages", "MaxManifestPages", verdictRefuse, verdictRefuse, "-"},
		"tombstone":             {"recovery_pages", "MaxManifestPages", verdictRefuse, verdictRefuse, "-"},
		"plan_ranges":           {"plan_ranges", "MaxRangesPerPage", verdictRefuse, verdictRefuse, "-"},
		"recovery_spans_chain":  {"recovery_spans", "MaxSpansPerPage", verdictRefuse, verdictRefuse, "-"},
		"recovery_spans_single": {"recovery_spans", "MaxSpansPerPage", verdictRefuse, verdictNA, proofGroup16D},
	}

	// A verdict column may only hold a token this corpus understands. An unrecognised one
	// would otherwise read as "not refuse" and quietly relax a row.
	known := map[string]bool{verdictRefuse: true, verdictAccept: true, verdictNA: true}

	rows := countCorpus(t)
	if len(rows) != len(inventory) {
		t.Fatalf("corpus has %d rows, inventory has %d", len(rows), len(inventory))
	}

	for _, r := range rows {
		want, ok := inventory[r.site]
		if !ok {
			t.Fatalf("corpus row %q is not in the inventory", r.site)
		}

		got := spec{r.carrier, r.bound, r.goVerdict, r.exVerdict, r.owner}
		if got != want {
			t.Fatalf("%s: corpus says %+v, inventory says %+v", r.site, got, want)
		}

		if !known[r.goVerdict] || !known[r.exVerdict] {
			t.Fatalf("%s: verdict tokens %q/%q are not both recognised", r.site, r.goVerdict, r.exVerdict)
		}

		delete(inventory, r.site)
	}

	for site := range inventory {
		t.Fatalf("inventory site %q has no corpus row", site)
	}
}

// TestCountCorpusRecordsTheAbsentPeer keeps `n/a` from becoming a silent exemption: every
// runtime column that is not a verdict must name an owner, and every owner must belong to a
// row that actually lacks a peer.
func TestCountCorpusRecordsTheAbsentPeer(t *testing.T) {
	for _, r := range countCorpus(t) {
		switch {
		case r.exVerdict == verdictNA && r.owner == "-":
			t.Fatalf("%s: the Elixir peer is absent and no owner is named", r.site)
		case r.exVerdict != verdictNA && r.owner != "-":
			t.Fatalf("%s: an owner is named for a site that has a peer", r.site)
		}
	}
}

// ---------------------------------------------------------------------------
// adapters -- one per typed carrier
// ---------------------------------------------------------------------------

// countPlanPages materialises a VALID n-page plan. Each page carries one range, so the fixture
// stays far below MaxPlanPageBytes and that ceiling can never shadow the count.
func countPlanPages(t *testing.T, n int) (*edgev1.ScheduledPlanHeaderV1, []*edgev1.ScheduledPlanPageV1) {
	t.Helper()

	pageRanges := make([][]uint64, n)
	for i := range pageRanges {
		pageRanges[i] = []uint64{1}
	}

	return buildPlan(t, mustUUID(t), d32(0x77), pageRanges)
}

// countManifestPages materialises a VALID n-page manifest whose pages carry a single UNATTRIBUTABLE
// span each. That shape is deliberate: an attributed span carries three UUIDs and three
// digests, and 1025 of those exceed MaxManifestBytes -- the BYTE ceiling would then refuse the
// list before the COUNT ceiling was reached, and the row would prove the wrong bound.
func countManifestPages(t *testing.T, n int) []*edgev1.EdgeLossManifestPageV1 {
	t.Helper()

	spans := make([][]*edgev1.EdgeClassificationSpanV1, n)
	for i := range spans {
		from := uint64(i*10 + 1)
		spans[i] = []*edgev1.EdgeClassificationSpanV1{
			unattributableSpan(from, from+1, edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING),
		}
	}

	return buildManifest(t, mustUUID(t), spans)
}

func rawPagesOf(t *testing.T, pages []*edgev1.EdgeLossManifestPageV1) [][]byte {
	t.Helper()

	out := make([][]byte, len(pages))
	total := 0

	for i, p := range pages {
		b, err := proto.Marshal(p)
		if err != nil {
			t.Fatalf("marshal manifest page %d: %v", i, err)
		}
		out[i] = b
		total += len(b)
	}

	// THE BYTE CEILING MUST NOT SHADOW THE COUNT CEILING. If the aggregate exceeded
	// MaxManifestBytes the raw gate would refuse for size, and every row below would pass
	// while proving a bound it does not name.
	if total > MaxManifestBytes {
		t.Fatalf("the %d-page fixture aggregates %d bytes, over MaxManifestBytes (%d); "+
			"the byte ceiling would shadow the count ceiling", len(pages), total, MaxManifestBytes)
	}

	return out
}

func rawPlanPagesOf(t *testing.T, pages []*edgev1.ScheduledPlanPageV1) [][]byte {
	t.Helper()

	out := make([][]byte, len(pages))

	for i, p := range pages {
		b, err := proto.Marshal(p)
		if err != nil {
			t.Fatalf("marshal plan page %d: %v", i, err)
		}
		// EACH page must stay under its own ceiling, or ErrPlanPageTooLarge shadows the count.
		if len(b) > MaxPlanPageBytes {
			t.Fatalf("plan page %d is %d bytes, over MaxPlanPageBytes (%d)", i, len(b), MaxPlanPageBytes)
		}
		out[i] = b
	}

	return out
}

func rowFor(t *testing.T, site string) countRow {
	t.Helper()

	for _, r := range countCorpus(t) {
		if r.site == site {
			return r
		}
	}

	t.Fatalf("no corpus row for site %q", site)

	return countRow{}
}

// ---------------------------------------------------------------------------
// per-site consumers
// ---------------------------------------------------------------------------

func TestCountSitePlanRaw(t *testing.T) {
	r := rowFor(t, "plan_raw")
	h, at := countPlanPages(t, r.at)

	if _, _, err := ValidatePlanFromRaw(headerBytes(t, h), rawPlanPagesOf(t, at)); err != nil {
		t.Fatalf("exactly %d pages must be accepted: %v", r.at, err)
	}

	overH, over := countPlanPages(t, r.over)
	if _, _, err := ValidatePlanFromRaw(headerBytes(t, overH), rawPlanPagesOf(t, over)); !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("%d pages = %v, want ErrPlanBounds", r.over, err)
	}
}

func TestCountSitePlanDecoded(t *testing.T) {
	r := rowFor(t, "plan_decoded")
	h, at := countPlanPages(t, r.at)

	if err := ValidatePlanPages(h, at); err != nil {
		t.Fatalf("exactly %d decoded pages must be accepted: %v", r.at, err)
	}

	overH, over := countPlanPages(t, r.over)
	if err := ValidatePlanPages(overH, over); !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("%d decoded pages = %v, want ErrPlanBounds", r.over, err)
	}
}

func TestCountSiteRecoveryRaw(t *testing.T) {
	r := rowFor(t, "recovery_raw")
	at := countManifestPages(t, r.at)

	if err := ValidateManifestChainFromRaw(rawPagesOf(t, at), ManifestRoot(at)); err != nil {
		t.Fatalf("exactly %d raw pages must be accepted: %v", r.at, err)
	}

	over := countManifestPages(t, r.over)
	if err := ValidateManifestChainFromRaw(rawPagesOf(t, over), ManifestRoot(over)); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("%d raw pages = %v, want ErrManifestBounds", r.over, err)
	}
}

func TestCountSiteRecoveryDecoded(t *testing.T) {
	r := rowFor(t, "recovery_decoded")
	at := countManifestPages(t, r.at)

	if err := ValidateManifestChain(at, ManifestRoot(at)); err != nil {
		t.Fatalf("exactly %d decoded pages must be accepted: %v", r.at, err)
	}

	over := countManifestPages(t, r.over)
	if err := ValidateManifestChain(over, ManifestRoot(over)); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("%d decoded pages = %v, want ErrManifestBounds", r.over, err)
	}
}

func TestCountSiteTombstone(t *testing.T) {
	r := rowFor(t, "tombstone")

	at := countManifestPages(t, r.at)
	tombAt := tombstoneFor(at)

	if err := ValidateTombstone(tombAt, at); err != nil {
		t.Fatalf("a tombstone over exactly %d pages must be accepted: %v", r.at, err)
	}

	// THE DECLARATION MOVES WITH THE LIST. `tombstoneFor` sets manifest_page_count from the
	// pages it is given, so the over-limit tombstone declares 1025 and the COUNT RELATION
	// agrees -- leaving the ceiling as the only rule that can refuse it. Declaring 1024 here
	// would prove the relation instead, and the row would pass with the ceiling deleted.
	over := countManifestPages(t, r.over)
	tombOver := tombstoneFor(over)

	if int(tombOver.GetManifestPageCount()) != r.over {
		t.Fatalf("control failed: the over-limit tombstone declares %d, want %d",
			tombOver.GetManifestPageCount(), r.over)
	}

	if err := ValidateTombstone(tombOver, over); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("a tombstone over %d pages = %v, want ErrManifestBounds", r.over, err)
	}
}

func TestCountSitePlanRanges(t *testing.T) {
	r := rowFor(t, "plan_ranges")

	counts := make([]uint64, r.at)
	for i := range counts {
		counts[i] = 1
	}

	h, pages := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{counts})
	if err := ValidatePlanPages(h, pages); err != nil {
		t.Fatalf("exactly %d ranges must be accepted: %v", r.at, err)
	}
	overCounts := make([]uint64, r.over)
	for i := range overCounts {
		overCounts[i] = 1
	}

	overH, overPages := buildPlan(t, mustUUID(t), d32(0x77), [][]uint64{overCounts})
	if err := ValidatePlanPages(overH, overPages); !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("%d ranges = %v, want ErrPlanBounds", r.over, err)
	}

	// THE REFUSED PAGE IS THE ONE THAT MUST BE UNDER THE SIZE CEILING. An oversize plan page
	// is also ErrPlanBounds, so if the N+1 page breached MaxPlanPageBytes the row above would
	// pass for the wrong rule. Checking only the ACCEPTED page proves nothing about the
	// refusal, which is the only verdict at issue -- so both go through, over first.
	_ = rawPlanPagesOf(t, overPages)
	_ = rawPlanPagesOf(t, pages)
}

func TestCountSiteRecoverySpansChain(t *testing.T) {
	r := rowFor(t, "recovery_spans_chain")

	atSpans := spansOf(t, r.at)
	at := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{atSpans})

	if err := ValidateManifestChain(at, ManifestRoot(at)); err != nil {
		t.Fatalf("exactly %d spans must be accepted: %v", r.at, err)
	}

	overSpans := spansOf(t, r.over)
	over := buildManifest(t, mustUUID(t), [][]*edgev1.EdgeClassificationSpanV1{overSpans})

	if err := ValidateManifestChain(over, ManifestRoot(over)); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("%d spans = %v, want ErrManifestBounds", r.over, err)
	}
}

func spansOf(t *testing.T, n int) []*edgev1.EdgeClassificationSpanV1 {
	t.Helper()

	out := make([]*edgev1.EdgeClassificationSpanV1, n)
	for i := range out {
		from := uint64(i*10 + 1)
		out[i] = unattributableSpan(from, from+1,
			edgev1.EdgeUnattributableReason_EDGE_UNATTRIBUTABLE_REASON_BINDING_MISSING)
	}

	return out
}

// ---------------------------------------------------------------------------
// stage witnesses -- one per RAW site
// ---------------------------------------------------------------------------
//
// A PLAIN N+1 VERDICT DOES NOT PROVE A RAW GATE. Delete `ValidatePlanFromRaw`'s count check
// and the decoded validator behind it returns the same ErrPlanBounds, so the row above stays
// green over a removed gate. Each witness therefore supplies a COMPETING FAULT whose result is
// DISTINGUISHABLE from the count's, placed on the LAST element so it is only reached by code
// that got past the count.

func TestCountStageWitnessPlanRaw(t *testing.T) {
	r := rowFor(t, "plan_raw")
	h, over := countPlanPages(t, r.over)
	raw := rawPlanPagesOf(t, over)

	// AN OVERSIZE FINAL PAGE. `ValidatePlanFromRaw` checks the count, then every page's size;
	// a decode failure also maps to ErrPlanBounds, so an undecodable page would NOT
	// distinguish the two stages. ErrPlanPageTooLarge wraps ErrPlanBounds and is testable on
	// its own, which is what makes the order observable.
	raw[len(raw)-1] = make([]byte, MaxPlanPageBytes+1)

	_, _, err := ValidatePlanFromRaw(headerBytes(t, h), raw)

	if !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("an over-count plan with an oversize final page = %v, want ErrPlanBounds", err)
	}
	if errors.Is(err, ErrPlanPageTooLarge) {
		t.Fatal("the PER-PAGE SIZE check ran before the page-list COUNT: the count ceiling is " +
			"either gone or behind it, and the plain N+1 row cannot see that because the " +
			"decoded validator returns the same ErrPlanBounds")
	}
}

func TestCountStageWitnessRecoveryRaw(t *testing.T) {
	r := rowFor(t, "recovery_raw")
	over := countManifestPages(t, r.over)
	raw := rawPagesOf(t, over)

	// A MALFORMED FINAL PAGE: within every size budget, so only the DECODE can object to it.
	// With the count gate the list never reaches a decode; without it, the decode error
	// surfaces and is plainly not ErrManifestBounds.
	raw[len(raw)-1] = []byte{0xFF, 0xFF, 0xFF, 0xFF}

	err := ValidateManifestChainFromRaw(raw, ManifestRoot(over))

	if !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("an over-count manifest with a malformed final page = %v, want "+
			"ErrManifestBounds; a decode error here means the count ceiling did not run first", err)
	}
}

// TestCountSiteRecoverySpansSingle drives the SPAN ceiling through the signed
// recovery-control boundary, which is the only way `validateSingleManifestPage` is reached.
//
// THIS IS A SITE ADAPTER AROUND THE SHARED SPAN PAIR, not a fifth vector pair: the same
// at/over span counts from the manifest are wrapped, so the ceiling under test is the one the
// chain site already uses.
//
// SEAL ORDER IS THE WHOLE CARE HERE. The page is finished FIRST -- ordered spans, count,
// index, terminal, then its own digest -- and only then is its scope digest taken and the
// wrapper built around it. Nothing is mutated after signing, because a page edited afterwards
// leaves the signed claim describing a page that no longer exists, and the row would fail on
// the scope comparison rather than the ceiling.
//
// THE ISSUER IS THE VERSION CORPUS'S. Reusing `recoveryScopeKey` and its committed public key
// keeps this row comparable with the signed recovery evidence already in the tree, and avoids
// a second trust fixture whose drift nothing would notice.
//
// GO-ONLY. This runtime has no Elixir peer for the single-page path; the corpus records that
// as `n/a` with 1.6-d named, and the guard above refuses an unowned `n/a`.
func TestCountSiteRecoverySpansSingle(t *testing.T) {
	r := rowFor(t, "recovery_spans_single")

	wrap := func(n int) (*edgev1.EdgeRecordV1, AuthorizationPolicy) {
		page := buildManifest(t, mustUUID(t),
			[][]*edgev1.EdgeClassificationSpanV1{spansOf(t, n)})[0]

		// FINISHED FIRST: a single-page manifest, then its own digest over the final spans.
		page.PageIndex, page.PageCount, page.Terminal, page.PrevPageSha256 = 0, 1, true, nil
		page.PageSha256 = ManifestPageDigest(page)

		body := &edgev1.EdgeRecoveryControlPayloadV1{
			Body: &edgev1.EdgeRecoveryControlPayloadV1_ManifestPage{ManifestPage: page},
		}

		// The scope digest is taken from the FINISHED page, and the wrapper -- payload, source
		// claim, envelope, both signatures -- is built around it afterwards.
		return scopeControlRecord(t, body, page.GetRecoveryId(), ManifestPageScopeDigest(page))
	}

	atRec, atPolicy := wrap(r.at)
	overRec, overPolicy := wrap(r.over)

	// BOTH ARTIFACTS MUST BE SIGNED-VALID BEFORE ANY PRODUCTION CLAIM. Without this the
	// over-limit row could be refused by a stale signature or a failed join and still look
	// like span-ceiling evidence.
	if err := ValidateRecordSigned(atRec, atPolicy); err != nil {
		t.Fatalf("the at-ceiling wrapper must pass the signed boundary: %v", err)
	}

	if err := ValidateRecordSigned(overRec, overPolicy); err != nil {
		t.Fatalf("the over-ceiling wrapper must pass the signed boundary: %v", err)
	}

	expected := atRec.GetOutputContract()

	if err := ValidateRecoveryControl(atRec, expected, atPolicy); err != nil {
		t.Fatalf("exactly %d spans on a single page must be accepted: %v", r.at, err)
	}

	if err := ValidateRecoveryControl(overRec, overRec.GetOutputContract(), overPolicy); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("%d spans on a single page = %v, want ErrManifestBounds", r.over, err)
	}
}
