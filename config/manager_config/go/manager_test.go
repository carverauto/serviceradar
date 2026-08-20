package manager_test

import (
	"strings"
	"testing"

	manager "github.com/carverauto/serviceradar/config/manager_config/go"
	configpb "github.com/carverauto/serviceradar/config/proto_bindings/go"
)

func identity(t *testing.T, value string) manager.Identity {
	t.Helper()
	id, err := manager.ParseIdentity(value, true)
	if err != nil {
		t.Fatalf("%q: %v", value, err)
	}
	return id
}

// localhost and ci carry their instance because neither has a platform to mount anything: a
// developer running a binary directly and a Bazel test action both have a filesystem nobody
// provisioned.
func TestKindsWithoutAPlatformCarryTheirInstance(t *testing.T) {
	for _, value := range []string{"localhost", "ci"} {
		src := manager.SourceFor(identity(t, value))
		if src.Kind != manager.BuiltIn || src.Name != value {
			t.Fatalf("%s: got %+v", value, src)
		}
	}
}

func TestDeployedKindsReadTheMount(t *testing.T) {
	for _, value := range []string{"saas", "demo", "onprem:untd"} {
		src := manager.SourceFor(identity(t, value))
		if src.Kind != manager.Mounted || src.Name != manager.MountedInstancePath {
			t.Fatalf("%s: got %+v", value, src)
		}
	}
}

func TestSourceNamesABuiltInByIdentityAndAMountByPath(t *testing.T) {
	if got := manager.SourceFor(identity(t, "ci")).String(); got != "built-in:ci" {
		t.Fatalf("got %q", got)
	}
	if got := manager.SourceFor(identity(t, "saas")).String(); got != manager.MountedInstancePath {
		t.Fatalf("got %q", got)
	}
}

func TestABuiltInLoadsAndExposesItsSections(t *testing.T) {
	builtIns := manager.BuiltIns{"ci": encode(validCI())}

	loaded, err := manager.Load(identity(t, "ci"), builtIns, missingMount{})
	if err != nil {
		t.Fatalf("the fixture instance is valid: %v", err)
	}
	if loaded.Source.Kind != manager.BuiltIn || loaded.Source.Name != "ci" {
		t.Fatalf("got %+v", loaded.Source)
	}
	if loaded.Config.GetDatabase().GetPort() != 5432 {
		t.Fatalf("got port %d", loaded.Config.GetDatabase().GetPort())
	}
	if loaded.Config.GetNats() == nil || loaded.Config.GetCore() == nil || loaded.Config.GetDgraph() == nil {
		t.Fatal("every section must be exposed")
	}
}

// The check that catches a wrong ConfigMap. It is otherwise completely silent, and its blast
// radius is the database a component connects to.
func TestAnArtifactDescribingAnotherEnvironmentIsRejected(t *testing.T) {
	saas := validCI()
	kind := configpb.EnvironmentKind_ENVIRONMENT_KIND_SAAS
	saas.Kind = &kind

	_, err := manager.Load(identity(t, "demo"), nil, mounted{encode(saas)})
	if err == nil {
		t.Fatal("the artifact says saas; the selector says demo")
	}
	text := err.Error()
	for _, want := range []string{"demo", "saas", "wrong artifact is mounted", "database"} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %q in: %s", want, text)
		}
	}
}

// The same check, one on-prem customer's artifact in another's deployment.
func TestADifferentOnpremInstanceIsRejected(t *testing.T) {
	other := validCI()
	kind := configpb.EnvironmentKind_ENVIRONMENT_KIND_ONPREM
	name := "someone-else"
	other.Kind = &kind
	other.Instance = &name

	_, err := manager.Load(identity(t, "onprem:untd"), nil, mounted{encode(other)})
	if err == nil {
		t.Fatal("expected a mismatch")
	}
	for _, want := range []string{"onprem:untd", "onprem:someone-else"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("missing %q in: %s", want, err)
		}
	}
}

// Loading and validating are one operation. A committed instance is validated at build; a
// mounted one has never been seen by this repository's build at all.
func TestAnInvalidInstanceIsRejectedAtLoadAndYieldsNothing(t *testing.T) {
	cfg := validCI()
	disable := configpb.TlsMode_TLS_MODE_DISABLE
	cfg.Database.TlsMode = &disable

	loaded, err := manager.Load(identity(t, "ci"), manager.BuiltIns{"ci": encode(cfg)}, missingMount{})
	if err == nil {
		t.Fatal("plaintext TLS outside localhost must not load")
	}
	if loaded != nil {
		t.Fatal("a rejected instance must yield no configuration at all")
	}
	if !strings.Contains(err.Error(), "DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST") {
		t.Fatalf("the violation must be named: %s", err)
	}
}

func TestAnUnknownBuiltInListsWhatTheReleaseCarries(t *testing.T) {
	_, err := manager.Load(identity(t, "localhost"), manager.BuiltIns{"ci": encode(validCI())}, missingMount{})
	if err == nil {
		t.Fatal("expected an error")
	}
	for _, want := range []string{"localhost", "ci"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("missing %q in: %s", want, err)
		}
	}
}

// A missing mount is fatal. There is no cached fallback to fall back TO, by construction:
// nothing retains bytes across a call.
func TestAMissingMountIsFatalAndNamesTheSource(t *testing.T) {
	_, err := manager.Load(identity(t, "saas"), nil, missingMount{})
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), manager.MountedInstancePath) {
		t.Fatalf("the path must be named: %s", err)
	}
}

// A well-formed message of the WRONG type, because a wrong-but-valid artifact is the realistic
// mistake rather than random bytes.
func TestAWellFormedMessageOfAnotherTypeIsRejected(t *testing.T) {
	_, err := manager.Load(identity(t, "saas"), nil, mounted{encode(manager.EmbeddedRules())})
	if err == nil {
		t.Fatal("a RuleSet is not an EnvironmentConfig")
	}
}
