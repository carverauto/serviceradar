package edgerecord

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The proof-group ids the corpora are keyed by. Each appears in several corpus tables AND in the
// inventory that cross-checks them, and they must agree, so the id is named once instead of
// repeated as a literal in every file that asserts on it.
const (
	proofGroup16D = "1.6-d"
)

// The verdict vocabulary the corpus manifests use. Six files write these columns and several
// more assert on them, so they are named once: a typo in a literal would read as a different
// verdict rather than as a compile error.
const (
	verdictAccept = "accept"
	verdictRefuse = "refuse"
	verdictNA     = "n/a"
)

// Task 1.5-h: THE EXACT PROOF-GROUP INVENTORY.
//
// Rebuild the remaining delegated bound sites from shared manifests. Principal and
// projected-cost rows now have both peers and must no longer appear as delegations.

// delegatedRow is one manifest row whose peer is absent and whose owner is named.
type delegatedRow struct{ corpus, site, owner string }

// scanDelegations reads a manifest and returns every row whose Elixir column is `n/a`, using
// the column positions given. Manifest shapes differ by corpus, which is why the positions are
// passed in rather than guessed.
func scanDelegations(t *testing.T, name string, siteCol, exCol, ownerCol, wantFields int) []delegatedRow {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	f, err := os.Open(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1", "testdata", name))
	if err != nil {
		t.Fatalf("open %s: %v", name, err)
	}
	defer func() { _ = f.Close() }()

	var out []delegatedRow

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != wantFields {
			t.Fatalf("%s row %q has %d fields, want %d", name, line, len(fields), wantFields)
		}

		if fields[exCol] != verdictNA {
			continue
		}

		if fields[ownerCol] == "-" {
			t.Fatalf("%s: %s has no peer and names no owner", name, fields[siteCol])
		}

		out = append(out, delegatedRow{corpus: name, site: fields[siteCol], owner: fields[ownerCol]})
	}

	if err := sc.Err(); err != nil {
		t.Fatalf("scan %s: %v", name, err)
	}

	return out
}

func TestProofGroupInventoryIsExact(t *testing.T) {
	// Column positions per manifest. A shape change breaks the field-count assertion above
	// rather than silently reading the wrong column.
	//
	//nolint:prealloc // length is the sum of the per-corpus scans below, unknown here
	var got []delegatedRow

	got = append(got, scanDelegations(t, "count_corpus.txt", 0, 6, 7, 8)...)
	got = append(got, scanDelegations(t, "scalar_corpus.txt", 0, 7, 8, 9)...)
	got = append(got, scanDelegations(t, "lower_bound_corpus.txt", 0, 7, 8, 9)...)

	// THE THREE REMAINING DELEGATED BOUND-SITE ROWS, exhaustively. Sites recur across corpora when the
	// same gap is bounded from both ends -- the single-page span site is delegated for its
	// ceiling AND its minimum -- so the inventory is keyed by (site, owner) and counted once.
	want := map[string]string{
		"recovery_spans_single":    proofGroup16D, // MaxSpansPerPage on the signed single-page path
		"tombstone_reason_signed":  proofGroup16D, // MaxReasonBytes on the signed body path
		"tombstone_declared_count": proofGroup16D, // the signed declared page count
	}

	seen := map[string]string{}

	for _, r := range got {
		if prior, ok := seen[r.site]; ok && prior != r.owner {
			t.Fatalf("%s is delegated to %s in one corpus and %s in another", r.site, prior, r.owner)
		}

		seen[r.site] = r.owner
	}

	if len(seen) != len(want) {
		sites := make([]string, 0, len(seen))
		for s := range seen {
			sites = append(sites, s)
		}

		sort.Strings(sites)
		t.Fatalf("the manifests delegate %d bound sites, the inventory names %d: %v",
			len(seen), len(want), sites)
	}

	for site, owner := range want {
		actual, ok := seen[site]
		if !ok {
			t.Fatalf("inventory names %q as delegated, but no manifest row delegates it", site)
		}

		if actual != owner {
			t.Fatalf("%s is delegated to %s, the inventory says %s", site, actual, owner)
		}
	}

	// Cost relations now have both structural validators.
	cost := projectedCostCorpus(t)
	if len(cost) != 3 {
		t.Fatal("the projected-cost relation must contain three conjuncts")
	}
	for _, r := range cost {
		if r.exVerdict != verdictRefuse || r.owner != "-" {
			t.Fatalf("projected cost %s requires both runtime verdicts, got %s/%s", r.conjunct, r.exVerdict, r.owner)
		}
	}
}
