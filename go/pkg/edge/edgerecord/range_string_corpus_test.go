package edgerecord

import (
	"errors"
	"net/netip"
	"strings"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

// Task 1.5-h: PLAN RANGE ADDRESS STRINGS -- the zone prohibition, and the guard bound that
// prohibition puts back out of reach.
//
// THREE PARTS, and only the first is a semantic rule:
//
//  1. ZONE-PRESENT REFUSAL, per field.
//  2. ACCEPTED CONTROLS -- at the frozen ceiling for the PREFLIGHT, and at the largest valid
//     syntax for the whole validator. Without these an always-refusing implementation
//     satisfies every refusal row.
//  3. ONE OVER-LIMIT, parser-not-entered control per field.
//
// THE CEILING IS PINNED AT THE SEAM, NOT THROUGH THE VALIDATOR. No canonical address reaches
// 64 bytes once zones are forbidden, so a whole-validator at-64 acceptance does not exist to
// construct -- and a 65-byte refusal driven through the validator survives the bound drifting
// anywhere from 43 to 65, since the parser refuses those lengths anyway. Only the preflight
// can distinguish them, so that is where 64 and 65 are asserted.

// THE SEAM IS TESTED DIRECTLY. `checkRangeStrings` parses nothing, so a row against it shows
// what the PREDICATES do and pins the frozen ceiling, without matching on DIAGNOSTIC WORDING
// that no requirement owns.
//
// IT DOES NOT PROVE ATTACHMENT. The checked value is an ordinary same-package struct, so a
// caller here can forge one and skip the preflight entirely. What catches that is the
// WHOLE-VALIDATOR zoned row below; in Elixir it is the traced stage test.
func TestRangeStringPreflightPinsTheFrozenLiteral(t *testing.T) {
	// LITERAL-PINNED. Building the vectors from the constant makes them move with it, so a
	// bound drifting to 43 or 128 would keep every row green. The frozen value is stated here
	// and the constant is checked against it.
	if MaxRangeStrBytes != 64 {
		t.Fatalf("MaxRangeStrBytes = %d, want the frozen 64", MaxRangeStrBytes)
	}

	for _, field := range []string{"cidr", "first", "last"} {
		t.Run(field, func(t *testing.T) {
			// AT the ceiling: accepted by the preflight. It is not a canonical address and the
			// parser will refuse it later -- which is the point: this row is about the PREFLIGHT,
			// and it is what stops a tightened `>` to `>=` from passing unnoticed.
			if _, err := checkRangeStrings(rangeWith(field, strings.Repeat("z", 64))); err != nil {
				t.Fatalf("exactly 64 bytes must pass the preflight: %v", err)
			}
			// ONE OVER: refused, before any parser is entered.
			if _, err := checkRangeStrings(rangeWith(field, strings.Repeat("z", 65))); !errors.Is(err, ErrPlanRange) {
				t.Fatalf("65 bytes = %v, want ErrPlanRange", err)
			}
		})
	}
}

func TestRangeStringPreflightRefusesZonesPerField(t *testing.T) {
	// Each field is an independently removable predicate: a prohibition applied to `cidr`
	// alone leaves a zoned span admitted. Tested at the seam, so the row does not depend on
	// what the whole validator would have done with the rest of the range.
	for _, field := range []string{"cidr", "first", "last"} {
		t.Run(field, func(t *testing.T) {
			if _, err := checkRangeStrings(rangeWith(field, "fe80::1%eth0")); !errors.Is(err, ErrPlanRange) {
				t.Fatalf("a zoned %s = %v, want ErrPlanRange", field, err)
			}
			// The SAME value without its zone passes the preflight, so the refusal is
			// attributable to the zone and not to anything else about the string.
			if _, err := checkRangeStrings(rangeWith(field, "fe80::1")); err != nil {
				t.Fatalf("the unzoned form must pass the preflight: %v", err)
			}
		})
	}
}

func TestZonedAddressIsAdmittedWithoutTheRule(t *testing.T) {
	// WHY THE RULE EXISTS, checked rather than argued. Without the preflight a zoned address
	// is canonical and parseable HERE, so this runtime would admit it -- and because a zone is
	// arbitrary-length text it reaches the ceiling exactly, which is what makes that bound
	// attainable at all.
	addr := "fe80::1%" + strings.Repeat("e", 64-len("fe80::1%"))
	if len(addr) != 64 {
		t.Fatalf("control failed: built %d bytes, want 64", len(addr))
	}

	a, err := netip.ParseAddr(addr)
	if err != nil {
		t.Fatalf("the address parser rejects the scoped form, so the rule guards nothing: %v", err)
	}
	if a.String() != addr {
		t.Fatal("the scoped form does not round-trip; the spelling rule would already catch it")
	}
}

func TestZonedRangeIsRefusedThroughTheWholeValidator(t *testing.T) {
	// THE SEAM ROWS ARE NOT ENOUGH ON THEIR OWN. `checkedRangeStrings` is an ordinary
	// same-package struct, so anything inside this package can FORGE one and reach the parser
	// without the preflight -- the handoff makes the order hard to get wrong, not impossible.
	// This row drives a zoned range through the real validator, resealed, so a bypass added
	// later fails here even though every seam row would still pass.
	//
	// EQUAL ENDPOINTS deliberately: a zoned span whose first and last are the same address is
	// the shape that would otherwise be ADMITTED, since it parses, round-trips canonically and
	// spans exactly one target.
	r := zoneCorpusRange(t)
	r.Cidr = ""
	r.FirstAddress, r.LastAddress = "fe80::1%eth0", "fe80::1%eth0"
	r.TargetCount = 1
	r.RangeSha256 = RangeDigest(r)

	if err := validateTargetRange(r, r.GetCheckSetSha256(), r.GetAvailabilityPolicyId()); !errors.Is(err, ErrPlanRange) {
		t.Fatalf("a zoned equal-endpoint span = %v, want ErrPlanRange", err)
	}

	// THE ACCEPTED CONTROL for the same shape. Without it an always-refusing validator
	// satisfies the row above, and the negative would prove only that something is wrong.
	ok := zoneCorpusRange(t)
	ok.Cidr = ""
	ok.FirstAddress, ok.LastAddress = "fe80::1", "fe80::1"
	ok.TargetCount = 1
	ok.RangeSha256 = RangeDigest(ok)

	if err := validateTargetRange(ok, ok.GetCheckSetSha256(), ok.GetAvailabilityPolicyId()); err != nil {
		t.Fatalf("the same span WITHOUT its zone must be accepted: %v", err)
	}
}

func TestPlanRangeAcceptsTheLargestValidSyntax(t *testing.T) {
	// The WHOLE-VALIDATOR acceptance controls. Without these an always-refusing validator
	// satisfies every refusal row above, and the preflight would look proven while the range
	// path admitted nothing.
	for _, tc := range []struct {
		name  string
		apply func(*edgev1.TargetRangeV1) uint64
	}{
		{"longest canonical CIDR", func(r *edgev1.TargetRangeV1) uint64 {
			p := netip.MustParsePrefix("ffff:ffff:ffff:ffff:ffff:ffff:ffff:8000/113")
			r.Cidr, r.FirstAddress, r.LastAddress = p.String(), "", ""
			return 1 << (p.Addr().BitLen() - p.Bits())
		}},
		{"longest canonical address span", func(r *edgev1.TargetRangeV1) uint64 {
			a := netip.MustParseAddr("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
			r.Cidr = ""
			r.FirstAddress, r.LastAddress = a.String(), a.String()
			return 1
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := zoneCorpusRange(t)
			r.TargetCount = tc.apply(r)
			r.RangeSha256 = RangeDigest(r)

			if err := validateTargetRange(r, r.GetCheckSetSha256(), r.GetAvailabilityPolicyId()); err != nil {
				t.Fatalf("the largest VALID %s must be accepted: %v", tc.name, err)
			}
		})
	}
}

// rangeWith puts one value in one address field and leaves the others empty, so each row
// exercises exactly the predicate it names.
func rangeWith(field, value string) *edgev1.TargetRangeV1 {
	r := &edgev1.TargetRangeV1{}

	switch field {
	case "cidr":
		r.Cidr = value
	case "first":
		r.FirstAddress = value
	case "last":
		r.LastAddress = value
	}

	return r
}

func zoneCorpusRange(t *testing.T) *edgev1.TargetRangeV1 {
	t.Helper()

	_, _, pages := planBoundAssignment(t)

	return proto.Clone(pages[0].GetRanges()[0]).(*edgev1.TargetRangeV1)
}
