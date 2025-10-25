package hydrate

import "testing"

func TestFindComponents_All(t *testing.T) {
	b, err := Default()
	if err != nil {
		t.Fatalf("default bundle: %v", err)
	}

	comps, err := b.FindComponents(nil)
	if err != nil {
		t.Fatalf("find components (nil): %v", err)
	}

	if len(comps) == 0 {
		t.Fatalf("expected components, got none")
	}

	all, err := b.FindComponents([]string{"all"})
	if err != nil {
		t.Fatalf("find components (all): %v", err)
	}

	if len(all) != len(comps) {
		t.Fatalf("expected %d components for 'all', got %d", len(comps), len(all))
	}
}

func TestFindComponents_Unknown(t *testing.T) {
	b, err := Default()
	if err != nil {
		t.Fatalf("default bundle: %v", err)
	}

	if _, err := b.FindComponents([]string{"does-not-exist"}); err == nil {
		t.Fatalf("expected error for unknown component")
	}
}
