package secret_test

import (
	"fmt"
	"strings"
	"testing"

	secret "github.com/carverauto/serviceradar/config/manager_secret/go"
)

const value = "hunter2-correct-horse-battery-staple"

func newSecret(t *testing.T) secret.Secret {
	t.Helper()
	s, ok := secret.NewSecret(value)
	if !ok {
		t.Fatal("a non-empty value must produce a secret")
	}
	return s
}

// This is the single most important property in the package. Every other check guards a mistake;
// this one guards the mistake that ends up in a log aggregator, where it outlives the process
// that leaked it.
func TestNoFormatVerbPrintsTheValue(t *testing.T) {
	s := newSecret(t)

	// %v and %s reach String; %#v reaches GoString, which is what a struct-printing logger or a
	// debugger dump uses and which would otherwise print the literal including the value.
	for _, format := range []string{"%v", "%s", "%+v", "%#v", "%q"} {
		rendered := fmt.Sprintf(format, s)
		if strings.Contains(rendered, value) {
			t.Fatalf("%s leaked the value: %s", format, rendered)
		}
	}
}

// Nesting is where a struct or slice printing itself would defeat redaction on the value.
func TestASecretNestedInAContainerIsStillRedacted(t *testing.T) {
	s := newSecret(t)
	type holder struct {
		Name   string
		Secret secret.Secret
	}

	renders := []string{
		fmt.Sprintf("%v", []secret.Secret{s}),
		fmt.Sprintf("%+v", map[string]secret.Secret{"database.password": s}),
		fmt.Sprintf("%+v", holder{Name: "database.password", Secret: s}),
		fmt.Sprintf("%#v", holder{Name: "database.password", Secret: s}),
	}
	for _, rendered := range renders {
		if strings.Contains(rendered, value) {
			t.Fatalf("leaked through a container: %s", rendered)
		}
	}
}

// The value is reachable only through a method whose name says so, which makes every read visible
// in review and greppable in audit.
func TestTheValueIsReachableOnlyByExposingIt(t *testing.T) {
	if got := newSecret(t).Expose(); got != value {
		t.Fatalf("got %q", got)
	}
}

// Empty is not a secret. A provider returning an empty string has failed to resolve one, and
// treating it as a value is how a component connects with a blank password.
func TestAnEmptyValueIsNotASecret(t *testing.T) {
	if _, ok := secret.NewSecret(""); ok {
		t.Fatal("empty must not become a secret")
	}
}

// Whitespace is not empty: a secret may legitimately be or contain spaces, and trimming here
// would silently change a credential.
func TestWhitespaceIsAValueNotAnAbsence(t *testing.T) {
	s, ok := secret.NewSecret(" ")
	if !ok || s.Expose() != " " || s.Len() != 1 {
		t.Fatalf("got %q ok=%v", s.Expose(), ok)
	}
}
