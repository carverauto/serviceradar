package manager_test

import (
	"strings"
	"testing"

	manager "github.com/carverauto/serviceradar/config/manager_config/go"
)

func TestAnUnsetVariableIsAnErrorWithNoDefault(t *testing.T) {
	if _, err := manager.ParseIdentity("", false); err == nil {
		t.Fatal("an unset variable must be an error, not a default")
	}
}

// A shell exporting SERVICERADAR_ENV= has selected nothing, and this repository's build tooling
// pins several variables to "" deliberately. Empty must not become a kind.
func TestAnEmptyValueIsUnsetNotAChoice(t *testing.T) {
	for _, value := range []string{"", "   "} {
		_, err := manager.ParseIdentity(value, true)
		var se *manager.SelectorError
		if !asSelectorError(err, &se) || se.Kind != manager.Absent {
			t.Fatalf("%q: expected Absent, got %v", value, err)
		}
	}
}

func TestSingleInstanceKindsAcceptNoInstance(t *testing.T) {
	for _, kind := range []string{"localhost", "ci", "saas", "demo"} {
		id, err := manager.ParseIdentity(kind, true)
		if err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
		if id.Kind != kind || id.Instance != "" {
			t.Fatalf("%s: got %+v", kind, id)
		}

		_, err = manager.ParseIdentity(kind+":x", true)
		var se *manager.SelectorError
		if !asSelectorError(err, &se) || se.Kind != manager.InstanceNotAccepted {
			t.Fatalf("%s:x expected InstanceNotAccepted, got %v", kind, err)
		}
	}
}

func TestOnpremRequiresAnInstance(t *testing.T) {
	for _, value := range []string{"onprem", "onprem:"} {
		_, err := manager.ParseIdentity(value, true)
		var se *manager.SelectorError
		if !asSelectorError(err, &se) || se.Kind != manager.InstanceRequired {
			t.Fatalf("%q expected InstanceRequired, got %v", value, err)
		}
	}

	id, err := manager.ParseIdentity("onprem:untd", true)
	if err != nil {
		t.Fatal(err)
	}
	if id.Kind != "onprem" || id.Instance != "untd" {
		t.Fatalf("got %+v", id)
	}
}

func TestAnUnrecognisedKindIsRejected(t *testing.T) {
	_, err := manager.ParseIdentity("CI-staging", true)
	var se *manager.SelectorError
	if !asSelectorError(err, &se) || se.Kind != manager.UnknownKind {
		t.Fatalf("expected UnknownKind, got %v", err)
	}
	if !strings.Contains(err.Error(), "CI-staging") {
		t.Fatalf("the message must quote the value: %s", err)
	}
}

func TestSurroundingWhitespaceIsTolerated(t *testing.T) {
	id, err := manager.ParseIdentity("  saas  ", true)
	if err != nil || id.Kind != "saas" {
		t.Fatalf("got %+v, %v", id, err)
	}
}

// String is the spelling SERVICERADAR_ENV accepts, so an error can quote back something a reader
// can paste into a manifest.
func TestStringRoundTripsThroughParse(t *testing.T) {
	for _, value := range []string{"localhost", "ci", "saas", "demo", "onprem:untd"} {
		id, err := manager.ParseIdentity(value, true)
		if err != nil {
			t.Fatal(err)
		}
		if id.String() != value {
			t.Fatalf("String() = %q, want %q", id.String(), value)
		}
		again, err := manager.ParseIdentity(id.String(), true)
		if err != nil || again != id {
			t.Fatalf("round trip lost %q", value)
		}
	}
}

func asSelectorError(err error, out **manager.SelectorError) bool {
	se, ok := err.(*manager.SelectorError)
	if ok {
		*out = se
	}
	return ok
}
