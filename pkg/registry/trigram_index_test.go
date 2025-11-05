package registry

import (
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
)

func TestTrigramIndexAddSearch(t *testing.T) {
	idx := NewTrigramIndex(logger.NewTestLogger())

	idx.Add("dev-1", "edge gateway 10.0.0.1")
	idx.Add("dev-2", "core router 10.0.0.2")
	idx.Add("dev-3", "lab switch 10.0.0.3")

	matches := idx.Search("edge")
	if len(matches) != 1 || matches[0].ID != "dev-1" {
		t.Fatalf("expected dev-1 match, got %v", matches)
	}

	matches = idx.Search("10.0.0")
	if len(matches) != 3 {
		t.Fatalf("expected 3 matches, got %v", matches)
	}

	matches = idx.Search("gate")
	if len(matches) != 1 || matches[0].ID != "dev-1" {
		t.Fatalf("expected token query to match dev-1, got %v", matches)
	}

	idx.Remove("dev-1")
	matches = idx.Search("edge")
	if len(matches) != 0 {
		t.Fatalf("expected no matches after removal, got %v", matches)
	}
}
