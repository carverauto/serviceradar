package validator_test

import (
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/proto"

	validator "github.com/carverauto/serviceradar/config/manager_validator/go"
	configpb "github.com/carverauto/serviceradar/config/proto_bindings/go"
)

// dataPath resolves a declared input. `go test` runs with the package directory as the working
// directory; Bazel runs the binary out of the runfiles tree, where a bare relative path resolves
// to nothing.
func dataPath(t *testing.T, relative string) string {
	t.Helper()
	if dir := os.Getenv("TEST_SRCDIR"); dir != "" {
		for _, ws := range []string{"_main", "serviceradar"} {
			candidate := filepath.Join(dir, ws, relative)
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}
	candidate := filepath.Join("..", "..", "..", relative)
	if _, err := os.Stat(candidate); err == nil {
		return candidate
	}
	t.Fatalf("cannot locate %s", relative)
	return ""
}

func load(t *testing.T, relative string, m proto.Message) {
	t.Helper()
	bytes, err := os.ReadFile(dataPath(t, relative))
	if err != nil {
		t.Fatalf("read %s: %v", relative, err)
	}
	if err := proto.Unmarshal(bytes, m); err != nil {
		t.Fatalf("decode %s: %v", relative, err)
	}
}

func loadRules(t *testing.T) *configpb.RuleSet {
	t.Helper()
	rules := &configpb.RuleSet{}
	load(t, "config/rules/ruleset.binpb", rules)
	return rules
}

// The whole point of the vector file: this Go engine must reproduce the same violations, in the
// same order, as the Rust one -- compared by (code, field_path) rather than by accept/reject,
// because two implementations can reject the same input for two different reasons and a bare
// rejection assertion would stay green.
func TestEveryFixtureProducesExactlyItsExpectedViolations(t *testing.T) {
	rules := loadRules(t)
	fixtures := &configpb.FixtureSet{}
	load(t, "config/rules/fixtures/fixtures.binpb", fixtures)

	if len(fixtures.GetFixtures()) == 0 {
		t.Fatal("fixture set decoded empty")
	}

	for _, fixture := range fixtures.GetFixtures() {
		t.Run(fixture.GetName(), func(t *testing.T) {
			instance := fixture.GetInstance()
			if instance == nil {
				t.Fatal("fixture sets no instance")
			}
			actual, err := validator.Validate(rules, instance)
			if err != nil {
				t.Fatalf("validate: %v", err)
			}

			expected := fixture.GetExpectedViolations()
			if len(actual) != len(expected) {
				t.Fatalf("expected %d violation(s), got %d:\n  expected %s\n  actual   %s",
					len(expected), len(actual), formatExpected(expected), formatActual(actual))
			}
			for i := range expected {
				if actual[i].Code != expected[i].GetCode() ||
					actual[i].FieldPath != expected[i].GetFieldPath() {
					t.Fatalf("at %d: expected (%s, %s), got (%s, %s)", i,
						expected[i].GetCode(), expected[i].GetFieldPath(),
						actual[i].Code, actual[i].FieldPath)
				}
			}
		})
	}
}

// Every committed instance validates cleanly under the Go engine too. The Rust file-phase test
// asserts this already; repeating it here is what makes a disagreement between the two visible
// as a test failure rather than as a service that starts in one language and not another.
func TestEveryCommittedInstanceIsClean(t *testing.T) {
	rules := loadRules(t)
	for _, name := range []string{"ci", "demo", "localhost", "onprem/untd", "saas"} {
		t.Run(name, func(t *testing.T) {
			cfg := &configpb.EnvironmentConfig{}
			load(t, "config/environments/"+name+".binpb", cfg)
			violations, err := validator.Validate(rules, cfg)
			if err != nil {
				t.Fatalf("validate: %v", err)
			}
			if len(violations) != 0 {
				t.Fatalf("%s has violations: %s", name, formatActual(violations))
			}
		})
	}
}

func formatExpected(v []*configpb.ExpectedViolation) string {
	out := "["
	for i, e := range v {
		if i > 0 {
			out += ", "
		}
		out += "(" + e.GetCode() + ", " + e.GetFieldPath() + ")"
	}
	return out + "]"
}

func formatActual(v []validator.Violation) string {
	out := "["
	for i, a := range v {
		if i > 0 {
			out += ", "
		}
		out += "(" + a.Code + ", " + a.FieldPath + ")"
	}
	return out + "]"
}
