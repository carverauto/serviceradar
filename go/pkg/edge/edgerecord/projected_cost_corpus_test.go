package edgerecord

import (
	"bufio"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
)

// Task 1.5-h: THE PROJECTED-COST RELATION.
//
// A RELATION, NOT A CEILING. The maxima are carried by the record's OWN production capability,
// so every comparison is between two values that travel together -- there is no frozen ABI
// constant to pin. What is frozen is the SHAPE of the comparison.
//
// THREE CONJUNCTS, EACH INDEPENDENTLY REMOVABLE: cost model versions must be EQUAL, and each
// projected quantity must be AT MOST its capability-carried maximum. Deleting any one leaves the other two
// refusing their own inputs, so one row cannot stand in for the group.
//
// INCLUSIVITY IS HALF OF EACH QUANTITY ROW. "Over is refused" alone permits tightening `>` into
// `>=`, which refuses a conforming producer's record projecting exactly its capability-carried maximum.
//
// PRE-SIGNATURE, AND THE ORDER IS PROVED AT THE SIGNED BOUNDARY. The relation runs inside
// `ValidateRecord`, which performs no cryptographic verification, so the maxima it reads are
// unverified: a SHAPE rule, not an authorization one. Showing that needs the boundary where
// verification DOES happen -- at `ValidateRecord` alone both orders look identical, because
// nothing there verifies anything. See TestProjectedCostIsEvaluatedBeforeSignatureVerification,
// which separates them by verdict through `ValidateRecordSigned`.

type costRow struct {
	conjunct, relation          string
	accepted, refused           string
	goVerdict, exVerdict, owner string
}

func projectedCostCorpus(t *testing.T) []costRow {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}

	f, err := os.Open(filepath.Join(wd, "..", "..", "..", "..", "proto", "edge", "v1", "testdata", "projected_cost_corpus.txt"))
	if err != nil {
		t.Fatalf("open projected-cost corpus: %v", err)
	}
	defer func() { _ = f.Close() }()

	var out []costRow

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 7 {
			t.Fatalf("projected-cost row %q has %d fields, want 7", line, len(fields))
		}

		out = append(out, costRow{
			conjunct: fields[0], relation: fields[1], accepted: fields[2], refused: fields[3],
			goVerdict: fields[4], exVerdict: fields[5], owner: fields[6],
		})
	}

	if err := sc.Err(); err != nil {
		t.Fatalf("scan projected-cost corpus: %v", err)
	}

	return out
}

// TestProjectedCostInventory pins the full row, both directions.
func TestProjectedCostInventory(t *testing.T) {
	want := map[string]costRow{
		"cost_model_version":    {relation: "equal", accepted: "equal_to_claim", refused: "differs_from_claim", goVerdict: verdictRefuse, exVerdict: verdictNA, owner: proofGroup15N},
		"projected_row_count":   {relation: "at_most", accepted: "equal_to_maximum", refused: "one_over_maximum", goVerdict: verdictRefuse, exVerdict: verdictNA, owner: proofGroup15N},
		"projected_write_bytes": {relation: "at_most", accepted: "equal_to_maximum", refused: "one_over_maximum", goVerdict: verdictRefuse, exVerdict: verdictNA, owner: proofGroup15N},
	}

	rows := projectedCostCorpus(t)
	if len(rows) != len(want) {
		t.Fatalf("corpus has %d rows, inventory has %d -- a duplicate or missing row", len(rows), len(want))
	}

	seen := map[string]bool{}

	for _, r := range rows {
		if seen[r.conjunct] {
			t.Fatalf("%s appears twice in the corpus", r.conjunct)
		}

		seen[r.conjunct] = true

		w, ok := want[r.conjunct]
		if !ok {
			t.Fatalf("corpus row %q is not in the inventory", r.conjunct)
		}

		if r.relation != w.relation || r.accepted != w.accepted || r.refused != w.refused ||
			r.goVerdict != w.goVerdict || r.exVerdict != w.exVerdict || r.owner != w.owner {
			t.Fatalf("%s: manifest and inventory disagree", r.conjunct)
		}

		// AN `at_most` RELATION OWES AN INCLUSIVITY CONTROL; an `equal` one owes a match.
		// Pairing them here stops a row being retitled into the weaker shape.
		switch r.relation {
		case "at_most":
			if r.accepted != "equal_to_maximum" || r.refused != "one_over_maximum" {
				t.Fatalf("%s: an at_most relation owes at-maximum accepted and one-over refused", r.conjunct)
			}
		case "equal":
			if r.accepted != "equal_to_claim" || r.refused != "differs_from_claim" {
				t.Fatalf("%s: an equal relation owes a match accepted and a mismatch refused", r.conjunct)
			}
		default:
			t.Fatalf("%s: relation %q is not recognised", r.conjunct, r.relation)
		}

		// GO-ONLY, and the gap must NAME AN OWNER rather than sit unexplained.
		if r.exVerdict != verdictNA || r.owner != proofGroup15N {
			t.Fatalf("%s: this runtime is the only one that COMPARES these fields; the peer is "+
				"1.5-n's, manifest says %s/%s", r.conjunct, r.exVerdict, r.owner)
		}
	}
}

// costRecord returns a valid record whose capability is mutated by fn, resealed afterwards.
func costRecord(t *testing.T, fn func(r *edgev1.EdgeRecordV1, claims *edgev1.EdgeProductionClaimsV1)) *edgev1.EdgeRecordV1 {
	t.Helper()

	r := validRecord(t)
	fn(r, r.GetProductionCapability().GetProduction())
	// The semantic envelope commits the record's own fields, so it is resealed LAST.
	r.SemanticEnvelopeSha256 = SemanticEnvelopeDigest(r)

	return r
}

func TestProjectedCostRelation(t *testing.T) {
	for _, r := range projectedCostCorpus(t) {
		t.Run(r.conjunct, func(t *testing.T) {
			var accepted, refused *edgev1.EdgeRecordV1

			switch r.conjunct {
			case "cost_model_version":
				accepted = costRecord(t, func(rec *edgev1.EdgeRecordV1, c *edgev1.EdgeProductionClaimsV1) {
					rec.CostModelVersion = c.GetCostModelVersion()
				})
				refused = costRecord(t, func(rec *edgev1.EdgeRecordV1, c *edgev1.EdgeProductionClaimsV1) {
					rec.CostModelVersion = c.GetCostModelVersion() + 1
				})
			case "projected_row_count":
				accepted = costRecord(t, func(rec *edgev1.EdgeRecordV1, c *edgev1.EdgeProductionClaimsV1) {
					rec.ProjectedRowCount = c.GetMaxProjectedRowCount()
				})
				refused = costRecord(t, func(rec *edgev1.EdgeRecordV1, c *edgev1.EdgeProductionClaimsV1) {
					rec.ProjectedRowCount = c.GetMaxProjectedRowCount() + 1
				})
			case "projected_write_bytes":
				accepted = costRecord(t, func(rec *edgev1.EdgeRecordV1, c *edgev1.EdgeProductionClaimsV1) {
					rec.ProjectedWriteBytes = c.GetMaxProjectedWriteBytes()
				})
				refused = costRecord(t, func(rec *edgev1.EdgeRecordV1, c *edgev1.EdgeProductionClaimsV1) {
					rec.ProjectedWriteBytes = c.GetMaxProjectedWriteBytes() + 1
				})
			default:
				t.Fatalf("no consumer for conjunct %q", r.conjunct)
			}

			// THE ACCEPTANCE IS NOT DECORATION. Without it `>` may be tightened to `>=`, and a
			// record projecting EXACTLY its capability-carried maximum -- which a conforming producer emits
			// -- would be refused with every "over is refused" row still green.
			if err := ValidateRecord(accepted); err != nil {
				t.Fatalf("%s at %s must be accepted: %v", r.conjunct, r.accepted, err)
			}

			if err := ValidateRecord(refused); !errors.Is(err, ErrProductionGrant) {
				t.Fatalf("%s %s = %v, want ErrProductionGrant", r.conjunct, r.refused, err)
			}
		})
	}
}

// TestProjectedCostIsEvaluatedBeforeSignatureVerification pins the ORDER the ledger records:
// the cost relation is reached BEFORE the capability signature is verified, so the maxima it
// reads are unverified and this is a SHAPE rule rather than an authorization one.
//
// AN EARLIER VERSION OF THIS TEST PROVED NOTHING. It substituted a bogus signature and called
// `ValidateRecord`, which performs no cryptographic verification at all -- and the fixture's
// signature was already a placeholder, so both sides of the comparison were unverified before
// and after. It restated the structural boundary instead of discriminating a stage.
//
// This version runs at the SIGNED boundary, where signature verification genuinely happens,
// and separates the two orders by VERDICT:
//
//  1. a valid signed record is accepted -- the control, without which every rejection below
//     could be some unrelated defect in the fixture;
//  2. a record tampered so the signature no longer matches, but whose cost still conforms, is
//     rejected FOR THE SIGNATURE -- proving verification is reached and does its job;
//  3. the SAME tampering plus an over-cost declaration is rejected FOR THE COST. If the
//     relation ran after verification, this would report the signature fault instead.
func TestProjectedCostIsEvaluatedBeforeSignatureVerification(t *testing.T) {
	// 1. The control.
	ok, policy := signedRecord(t)
	if err := ValidateRecordSigned(ok, policy); err != nil {
		t.Fatalf("a valid signed record must verify: %v", err)
	}

	// 2. Tampered, cost still conforming. Changing a CLAIM the signature covers invalidates it
	// while leaving the record structurally sound.
	tampered, policy := signedRecord(t)
	tampered.GetProductionCapability().GetProduction().MaxProjectedRowCount++
	reseal(tampered)

	// THE EXACT SIGNATURE FAULT, not merely "some error that is not the cost one". Accepting
	// any non-cost error would let this control pass on an unrelated defect -- a malformed
	// fixture, a trust-policy fault, a clock-tolerance rejection -- and the row would then
	// claim the signature path is live when nothing had reached it.
	sigErr := ValidateRecordSigned(tampered, policy)
	if !errors.Is(sigErr, ErrCapabilitySignatureInvalid) {
		t.Fatalf("the conforming-cost tamper must fail with ErrCapabilitySignatureInvalid, "+
			"which is what proves the signature path is reached at all; got %v", sigErr)
	}

	// 3. The same tampering, now also over-cost. The cost fault must win.
	both, policy := signedRecord(t)
	claims := both.GetProductionCapability().GetProduction()
	claims.MaxProjectedRowCount++
	both.ProjectedRowCount = claims.GetMaxProjectedRowCount() + 1
	reseal(both)

	if err := ValidateRecordSigned(both, policy); !errors.Is(err, ErrProductionGrant) {
		t.Fatalf("the cost relation must be evaluated BEFORE signature verification -- an "+
			"over-cost record whose signature is ALSO invalid must fail for cost; got %v", err)
	}
}
