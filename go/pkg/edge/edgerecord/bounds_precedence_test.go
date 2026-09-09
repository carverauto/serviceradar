package edgerecord

import (
	"errors"
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// Task 1.5-h: STRUCTURAL COUNT CEILINGS FIRE BEFORE THE RECURSIVE WALK THEY BOUND.
//
// Every test here asserts a PRECEDENCE, never a verdict. That is the whole point: both
// runtimes return the CORRECT verdict either way, so an N/N+1 pair passes in both directions
// while `hasUnknownFields` -- which recurses into a page's ranges, and a page's classification
// spans -- runs over an unbounded input. The only observable
// difference is WHICH refusal arrives, so that is what these tests pin.
//
// Each case is built so BOTH rules are violated at once. Reverting the ordering flips the
// error and fails the test; nothing else about the input changes.
//
// SCOPE: the DECODED validators, plus the tombstone's own ceiling. The raw entrypoints
// (`ValidatePlanFromRaw`, `ValidateManifestChainFromRaw`) bound their supplied lists before
// decoding anything and are deliberately untouched -- see design.md section 2h for which
// sites carry which defect.

// taintDeep puts the unknown field on the LAST nested child rather than on the page itself.
// A page-level taint is found by `hasUnknownFields` before it descends anywhere, so it would
// prove only that the top-level check runs first. Placing it on the final range or span means
// the walk must traverse EVERY child to reach it -- which is exactly the traversal the count
// ceiling is supposed to prevent, and exactly what these tests claim is no longer happening.
func taintDeep(m proto.Message) {
	m.ProtoReflect().SetUnknown(protoreflect.RawFields(
		append([]byte{}, 0xC0, 0xEA, 0x1D, 0x00),
	))
}

func taintLastRange(p *edgev1.ScheduledPlanPageV1) {
	taintDeep(p.GetRanges()[len(p.GetRanges())-1])
}

func taintLastSpan(p *edgev1.EdgeLossManifestPageV1) {
	taintDeep(p.GetClassificationSpans()[len(p.GetClassificationSpans())-1])
}

func TestPlanPageListCeilingPrecedesUnknownFieldWalk(t *testing.T) {
	_, h, pages := planBoundAssignment(t)

	// One page over the ceiling, with the taint on the LAST page's LAST range. If the walk ran
	// first this would report ErrUnknownFields -- a refusal, just not this one. Tainting every
	// page would let the walk stop on page one, which proves nothing about traversing an
	// oversize LIST: the ceiling this test names bounds the list, so the walk must be shown to
	// reach its end.
	over := make([]*edgev1.ScheduledPlanPageV1, 0, MaxManifestPages+1)
	for i := 0; i <= MaxManifestPages; i++ {
		p := proto.Clone(pages[0]).(*edgev1.ScheduledPlanPageV1)
		if i == MaxManifestPages {
			taintLastRange(p)
		}
		over = append(over, p)
	}
	if len(over) != MaxManifestPages+1 {
		t.Fatalf("control failed: built %d pages, want %d", len(over), MaxManifestPages+1)
	}

	err := ValidatePlanPages(h, over)
	if errors.Is(err, ErrUnknownFields) {
		t.Fatal("the unknown-field walk ran before the page-list ceiling: the ceiling bounds " +
			"that walk, so running it first does the work the ceiling exists to prevent")
	}
	if !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("oversize tainted page list = %v, want ErrPlanBounds", err)
	}
}

func TestPlanRangeCountCeilingPrecedesUnknownFieldWalk(t *testing.T) {
	_, h, pages := planBoundAssignment(t)

	// A LEGAL page count, so the list ceiling above cannot be what refuses this. One page
	// carries one range too many AND an unknown field.
	p := proto.Clone(pages[0]).(*edgev1.ScheduledPlanPageV1)
	base := p.GetRanges()[0]
	for len(p.Ranges) <= MaxRangesPerPage {
		p.Ranges = append(p.Ranges, proto.Clone(base).(*edgev1.TargetRangeV1))
	}
	taintLastRange(p)
	if len(p.GetRanges()) != MaxRangesPerPage+1 {
		t.Fatalf("control failed: built %d ranges, want %d", len(p.GetRanges()), MaxRangesPerPage+1)
	}

	err := ValidatePlanPages(h, []*edgev1.ScheduledPlanPageV1{p})
	if errors.Is(err, ErrUnknownFields) {
		t.Fatal("the unknown-field walk ran before the per-page range ceiling; that walk " +
			"descends into every range, which is exactly what the ceiling bounds")
	}
	if !errors.Is(err, ErrPlanBounds) {
		t.Fatalf("over-range tainted page = %v, want ErrPlanBounds", err)
	}
}

func TestManifestPageListCeilingPrecedesUnknownFieldWalk(t *testing.T) {
	pages := recoveryPages(t)

	// Only the LAST page's last span, for the reason above.
	over := make([]*edgev1.EdgeLossManifestPageV1, 0, MaxManifestPages+1)
	for i := 0; i <= MaxManifestPages; i++ {
		p := proto.Clone(pages[0]).(*edgev1.EdgeLossManifestPageV1)
		if i == MaxManifestPages {
			taintLastSpan(p)
		}
		over = append(over, p)
	}

	err := ValidateManifestChain(over, nil)
	if errors.Is(err, ErrUnknownFields) {
		t.Fatal("the unknown-field walk ran before the manifest page-list ceiling")
	}
	if !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("oversize tainted manifest = %v, want ErrManifestBounds", err)
	}
}

func TestManifestSpanCountCeilingPrecedesUnknownFieldWalk(t *testing.T) {
	pages := recoveryPages(t)

	p := proto.Clone(pages[0]).(*edgev1.EdgeLossManifestPageV1)
	base := p.GetClassificationSpans()[0]
	for len(p.ClassificationSpans) <= MaxSpansPerPage {
		p.ClassificationSpans = append(p.ClassificationSpans,
			proto.Clone(base).(*edgev1.EdgeClassificationSpanV1))
	}
	taintLastSpan(p)
	if len(p.GetClassificationSpans()) != MaxSpansPerPage+1 {
		t.Fatalf("control failed: built %d spans, want %d",
			len(p.GetClassificationSpans()), MaxSpansPerPage+1)
	}

	err := ValidateManifestChain([]*edgev1.EdgeLossManifestPageV1{p}, nil)
	if errors.Is(err, ErrUnknownFields) {
		t.Fatal("the unknown-field walk ran before the per-page span ceiling; that walk " +
			"descends into every span, which is exactly what the ceiling bounds")
	}
	if !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("over-span tainted page = %v, want ErrManifestBounds", err)
	}
}

// THE CONTROLS THAT KEEP THE FOUR ABOVE HONEST. Without these, moving the count checks to the
// very top of each validator -- ahead of rules that SHOULD precede them -- would still pass:
// every test above only asserts that bounds beat unknown-fields.

func TestTombstoneBoundsPrecedeTheDeclaredCountRelation(t *testing.T) {
	// CROSS-RUNTIME PARITY, not a Go-local preference. An over-ceiling page list is a BOUNDS
	// fault whatever the tombstone declares; comparing the declared count first reported it
	// as a chain mismatch here while the Elixir peer said bounds -- the same inputs, two
	// verdicts.
	//
	// It is also the only order BOTH runtimes can implement. A peer whose list count is not
	// O(1) cannot compare a declared count before the ceiling without walking past that
	// ceiling to obtain the count, which is the traversal the ceiling exists to prevent.
	pages := recoveryPages(t)

	over := make([]*edgev1.EdgeLossManifestPageV1, 0, MaxManifestPages+1)
	for i := 0; i <= MaxManifestPages; i++ {
		over = append(over, proto.Clone(pages[0]).(*edgev1.EdgeLossManifestPageV1))
	}

	tomb := tombstoneFor(pages)
	tomb.ManifestPageCount = 1 // deliberately DISAGREES, so relation-first would win here

	if err := ValidateTombstone(tomb, over); !errors.Is(err, ErrManifestBounds) {
		t.Fatalf("over-ceiling manifest with a mismatched declared count = %v, want "+
			"ErrManifestBounds; a chain mismatch describes the wrong problem and diverges "+
			"from the Elixir peer", err)
	}
}

func TestUnknownFieldWalkStillPrecedesSemantics(t *testing.T) {
	_, h, pages := planBoundAssignment(t)

	// Counts are LEGAL, so neither ceiling fires. A tainted page whose chain fields are also
	// wrong must still report the unknown field: the count ceilings moved ahead of this walk,
	// not ahead of everything.
	p := proto.Clone(pages[0]).(*edgev1.ScheduledPlanPageV1)
	p.PageIndex = 99
	taintLastRange(p)

	if err := ValidatePlanPages(h, []*edgev1.ScheduledPlanPageV1{p}); !errors.Is(err, ErrUnknownFields) {
		t.Fatalf("tainted page with a broken chain = %v, want ErrUnknownFields", err)
	}
}

func TestCountCeilingsAcceptExactlyTheCeiling(t *testing.T) {
	// INCLUSIVITY for the PER-PAGE RANGE COUNT only. Without it, tightening that one check
	// from `>` to `>=` survives every test above, each of which proves only that one-over is
	// refused. It says NOTHING about the other three arms: the page-list ceilings and the
	// span count need their own at-ceiling controls, which the shared corpus owns -- building
	// a 1024-page plan here to assert one arm would trade a slow test for a narrow claim.
	_, h, pages := planBoundAssignment(t)

	p := proto.Clone(pages[0]).(*edgev1.ScheduledPlanPageV1)
	base := p.GetRanges()[0]
	for len(p.Ranges) < MaxRangesPerPage {
		clone := proto.Clone(base).(*edgev1.TargetRangeV1)
		p.Ranges = append(p.Ranges, clone)
	}
	if len(p.GetRanges()) != MaxRangesPerPage {
		t.Fatalf("control failed: built %d ranges, want exactly %d", len(p.GetRanges()), MaxRangesPerPage)
	}

	// The page is refused for its DUPLICATED ranges, not for its count -- which is the
	// assertion: ErrPlanBounds must not be the reason at exactly the ceiling.
	if err := ValidatePlanPages(h, []*edgev1.ScheduledPlanPageV1{p}); errors.Is(err, ErrPlanBounds) {
		t.Fatalf("exactly MaxRangesPerPage ranges was refused as a BOUNDS violation: %v", err)
	}
}
