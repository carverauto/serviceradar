package manager_test

import (
	"strings"
	"testing"

	manager "github.com/carverauto/serviceradar/config/manager_config/go"
)

// The message a reader meets in a crash loop with no other output.
//
// Asserted rather than merely written: the one thing worse than this failure is this failure
// explained badly, and a docstring cannot be checked.
func unsetMessage(t *testing.T) string {
	t.Helper()
	_, err := manager.ParseIdentity("", false)
	if err == nil {
		t.Fatal("expected an error")
	}
	return err.Error()
}

func TestTheUnsetMessageNamesTheVariableAndSaysNothingCanStart(t *testing.T) {
	text := unsetMessage(t)
	for _, want := range []string{"SERVICERADAR_ENV", "CANNOT START"} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %q in:\n%s", want, text)
		}
	}
}

func TestTheUnsetMessageSaysThereIsNoDefault(t *testing.T) {
	if text := unsetMessage(t); !strings.Contains(text, "NO DEFAULT") {
		t.Fatalf("missing NO DEFAULT in:\n%s", text)
	}
}

func TestTheUnsetMessageListsEveryAcceptedValue(t *testing.T) {
	text := unsetMessage(t)
	for _, kind := range []string{"localhost", "ci", "saas", "demo", "onprem"} {
		if !strings.Contains(text, kind) {
			t.Fatalf("missing %q in:\n%s", kind, text)
		}
	}
}

// The reader's next action is editing a manifest, not reading source.
func TestTheUnsetMessageShowsHowToSetItOnEveryPlatform(t *testing.T) {
	text := unsetMessage(t)
	for _, platform := range []string{"Kubernetes", "Docker", "Compose", "CI", "Local dev"} {
		if !strings.Contains(text, platform) {
			t.Fatalf("missing %q in:\n%s", platform, text)
		}
	}
}

func TestEveryOtherSelectorErrorQuotesTheOffendingValue(t *testing.T) {
	cases := []struct {
		err  *manager.SelectorError
		want string
	}{
		{&manager.SelectorError{Kind: manager.UnknownKind, Value: "CI-staging"}, "CI-staging"},
		{&manager.SelectorError{Kind: manager.InstanceRequired, Value: "onprem"}, "onprem"},
		{&manager.SelectorError{Kind: manager.InstanceNotAccepted, Value: "saas"}, "saas"},
	}
	for _, c := range cases {
		if !strings.Contains(c.err.Error(), c.want) {
			t.Fatalf("missing %q in: %s", c.want, c.err)
		}
	}
}
