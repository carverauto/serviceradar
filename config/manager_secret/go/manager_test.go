package secret_test

import (
	"strings"
	"testing"

	secret "github.com/carverauto/serviceradar/config/manager_secret/go"
)

// An in-memory provider, so the resolution paths are testable without a mount.
type mapProvider struct{ entries map[string]string }

func (mapProvider) Describe() string { return "test-map" }

func (p mapProvider) Resolve(name string) (secret.Secret, error) {
	value, ok := secret.NewSecret(p.entries[name])
	if !ok {
		return secret.Secret{}, &secret.Error{
			Kind: secret.Unresolvable, Name: name, Provider: "test-map",
		}
	}
	return value, nil
}

func manager(declared []string, stored map[string]string) secret.Manager {
	return secret.NewManager(mapProvider{entries: stored}, secret.NewManifest(declared...))
}

func TestADeclaredAndStoredSecretResolves(t *testing.T) {
	m := manager([]string{"database.password"}, map[string]string{"database.password": "hunter2"})
	s, err := m.Resolve("database.password")
	if err != nil || s.Expose() != "hunter2" {
		t.Fatalf("got %q, %v", s.Expose(), err)
	}
}

// Configuration gets least privilege from the build graph; a secret cannot be a build target, so
// the symmetric mechanism is the declaration, enforced here.
func TestAnUndeclaredNameIsRefusedEvenWhenTheStoreHasIt(t *testing.T) {
	m := manager([]string{"database.password"},
		map[string]string{"database.password": "hunter2", "nats.creds": "creds"})

	_, err := m.Resolve("nats.creds")
	var se *secret.Error
	if !asError(err, &se) || se.Kind != secret.Undeclared {
		t.Fatalf("expected Undeclared, got %v", err)
	}
	if !strings.Contains(err.Error(), "database.password") {
		t.Fatalf("the refusal must list what IS declared: %s", err)
	}
}

// Refusal precedes resolution. Answering an undeclared name -- even to say "not found" -- tells a
// component whether a secret it may not have exists.
func TestAnUndeclaredNameIsRefusedIdenticallyWhetherOrNotItExists(t *testing.T) {
	absent := manager([]string{"database.password"}, map[string]string{"database.password": "h"})
	present := manager([]string{"database.password"},
		map[string]string{"database.password": "h", "nats.creds": "x"})

	_, errAbsent := absent.Resolve("nats.creds")
	_, errPresent := present.Resolve("nats.creds")
	if errAbsent.Error() != errPresent.Error() {
		t.Fatalf("the refusal must not reveal existence:\n  %v\n  %v", errAbsent, errPresent)
	}
}

// There is no default and no empty fallback: a component that continued here would authenticate
// with a blank credential.
func TestADeclaredButMissingSecretNamesTheKeyAndTheProvider(t *testing.T) {
	m := manager([]string{"database.password"}, map[string]string{})

	_, err := m.Resolve("database.password")
	var se *secret.Error
	if !asError(err, &se) || se.Kind != secret.Unresolvable {
		t.Fatalf("expected Unresolvable, got %v", err)
	}
	for _, want := range []string{"database.password", "test-map", "no default", "blank credential"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("missing %q in: %s", want, err)
		}
	}
}

func TestAnEmptyStoredValueDoesNotResolve(t *testing.T) {
	m := manager([]string{"database.password"}, map[string]string{"database.password": ""})
	if _, err := m.Resolve("database.password"); err == nil {
		t.Fatal("an empty stored value is a failure to resolve, not a resolved empty secret")
	}
}

// Startup resolves everything declared. A component that resolves lazily discovers a missing
// secret when it first needs it -- under load, and far from the deploy that caused it.
func TestResolveAllReturnsEveryDeclaredSecret(t *testing.T) {
	m := manager([]string{"database.password", "nats.creds"},
		map[string]string{"database.password": "hunter2", "nats.creds": "creds"})

	resolved, err := m.ResolveAll()
	if err != nil {
		t.Fatal(err)
	}
	if len(resolved) != 2 || resolved[0].Name != "database.password" || resolved[1].Name != "nats.creds" {
		t.Fatalf("got %+v", resolved)
	}
}

func TestResolveAllFailsWhenAnyDeclaredSecretIsMissing(t *testing.T) {
	m := manager([]string{"database.password", "nats.creds"},
		map[string]string{"database.password": "hunter2"})

	if _, err := m.ResolveAll(); err == nil || !strings.Contains(err.Error(), "nats.creds") {
		t.Fatalf("got %v", err)
	}
}

// explain has to report which store was consulted, or a reader cannot tell where to put a
// missing value.
func TestTheProviderIsReportable(t *testing.T) {
	if got := manager(nil, nil).ProviderName(); got != "test-map" {
		t.Fatalf("got %q", got)
	}
}

// A secret error names a KEY, never a value -- these are the strings that reach logs.
func TestNoSecretErrorCanCarryAValue(t *testing.T) {
	errs := []*secret.Error{
		{Kind: secret.Undeclared, Name: "k", Declared: []string{"d"}},
		{Kind: secret.Unresolvable, Name: "k", Provider: "p"},
		{Kind: secret.ProviderFailed, Name: "k", Provider: "p", Detail: "d"},
	}
	for _, e := range errs {
		if strings.Contains(e.Error(), "hunter2") {
			t.Fatalf("leaked: %s", e)
		}
	}
}

func TestManifestDeclaredNamesAreSorted(t *testing.T) {
	m := secret.NewManifest("nats.creds", "database.password", "core.key")
	got := strings.Join(m.Declared(), ",")
	if got != "core.key,database.password,nats.creds" {
		t.Fatalf("got %q", got)
	}
}

// A component that declares nothing can request nothing -- the default is no access, not all.
func TestAnEmptyManifestDeclaresNothing(t *testing.T) {
	m := secret.NewManifest()
	if !m.IsEmpty() || m.Declares("database.password") {
		t.Fatal("an empty manifest must declare nothing")
	}
}

func asError(err error, out **secret.Error) bool {
	se, ok := err.(*secret.Error)
	if ok {
		*out = se
	}
	return ok
}
