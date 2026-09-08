package validator_test

import (
	"fmt"
	"testing"

	"pgregory.net/rapid"

	validator "github.com/carverauto/serviceradar/config/manager_validator/go"
	configpb "github.com/carverauto/serviceradar/config/proto_bindings/go"
)

// The Go half of the predicate laws. The vectors prove this engine agrees with Rust on the
// committed cases; these prove it obeys the same laws on inputs no case table contains.
//
// rapid shrinks failures to a minimal counterexample, which is why it is worth a dependency
// over testing/quick.

const code = "UNDER_TEST"

// The oneof wrapper interface generated for Rule.Predicate is unexported, so an external test
// package cannot name it as a parameter type. A type switch over the concrete wrappers can
// assign it, and enumerating them here means a predicate added to the vocabulary without a
// corresponding case fails loudly rather than silently producing a rule with no predicate.
func one(fieldPath string, predicate any) *configpb.RuleSet {
	phase := configpb.Phase_PHASE_CONFIG
	fp, c := fieldPath, code
	rule := &configpb.Rule{FieldPath: &fp, Code: &c, Phase: &phase}

	switch p := predicate.(type) {
	case *configpb.Rule_Required:
		rule.Predicate = p
	case *configpb.Rule_NonEmpty:
		rule.Predicate = p
	case *configpb.Rule_IntRange:
		rule.Predicate = p
	case *configpb.Rule_OneOf:
		rule.Predicate = p
	case *configpb.Rule_Matches:
		rule.Predicate = p
	case *configpb.Rule_RequiredIf:
		rule.Predicate = p
	case *configpb.Rule_ForbiddenValue:
		rule.Predicate = p
	case *configpb.Rule_ForbiddenIf:
		rule.Predicate = p
	case *configpb.Rule_EqualAcrossEnvs:
		rule.Predicate = p
	default:
		panic(fmt.Sprintf("no case for predicate %T", predicate))
	}
	return &configpb.RuleSet{Rules: []*configpb.Rule{rule}}
}

func fired(t *rapid.T, rules *configpb.RuleSet, cfg *configpb.EnvironmentConfig) bool {
	v, err := validator.Validate(rules, cfg)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	for _, x := range v {
		if x.Code == code {
			return true
		}
	}
	return false
}

func withPort(p *uint32) *configpb.EnvironmentConfig {
	return &configpb.EnvironmentConfig{Database: &configpb.DatabaseConfig{Port: p}}
}

func withHost(h *string) *configpb.EnvironmentConfig {
	return &configpb.EnvironmentConfig{Database: &configpb.DatabaseConfig{Host: h}}
}

func withTLS(m *configpb.TlsMode) *configpb.EnvironmentConfig {
	return &configpb.EnvironmentConfig{Database: &configpb.DatabaseConfig{TlsMode: m}}
}

func withKindInstance(k configpb.EnvironmentKind, instance *string) *configpb.EnvironmentConfig {
	return &configpb.EnvironmentConfig{Kind: &k, Instance: instance}
}

var allTLS = []configpb.TlsMode{
	configpb.TlsMode_TLS_MODE_UNSPECIFIED,
	configpb.TlsMode_TLS_MODE_DISABLE,
	configpb.TlsMode_TLS_MODE_REQUIRE,
	configpb.TlsMode_TLS_MODE_VERIFY_CA,
	configpb.TlsMode_TLS_MODE_VERIFY_FULL,
}

var allKinds = []configpb.EnvironmentKind{
	configpb.EnvironmentKind_ENVIRONMENT_KIND_UNSPECIFIED,
	configpb.EnvironmentKind_ENVIRONMENT_KIND_LOCALHOST,
	configpb.EnvironmentKind_ENVIRONMENT_KIND_CI,
	configpb.EnvironmentKind_ENVIRONMENT_KIND_SAAS,
	configpb.EnvironmentKind_ENVIRONMENT_KIND_ONPREM,
	configpb.EnvironmentKind_ENVIRONMENT_KIND_DEMO,
}

// drawBoundaryRelative picks a value RELATIVE to the bounds rather than independently of them.
// An independent draw over a large range reaches v == max only by luck, which is how the first
// Rust generator passed against a deliberately off-by-one engine. Sampling a boundary is not
// the same as testing it.
func drawBoundaryRelative(t *rapid.T, min, max uint32) uint32 {
	pick := rapid.IntRange(0, 5).Draw(t, "pick")
	switch pick {
	case 0:
		if min == 0 {
			return 0
		}
		return min - 1
	case 1:
		return min
	case 2:
		return max
	case 3:
		if max == ^uint32(0) {
			return max
		}
		return max + 1
	case 4:
		return min + (max-min)/2
	default:
		return rapid.Uint32Range(0, 400000).Draw(t, "free")
	}
}

func TestPropIntRangeIsInclusiveContainment(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		min := rapid.Uint32Range(0, 200000).Draw(t, "min")
		span := rapid.Uint32Range(0, 200000).Draw(t, "span")
		max := min + span
		v := drawBoundaryRelative(t, min, max)

		lo, hi := int64(min), int64(max)
		rules := one("database.port", &configpb.Rule_IntRange{
			IntRange: &configpb.IntRange{Min: &lo, Max: &hi},
		})
		inside := v >= min && v <= max
		if fired(t, rules, withPort(&v)) == inside {
			t.Fatalf("range [%d,%d] at %d: expected inside=%v", min, max, v, inside)
		}
	})
}

func TestPropIntRangeIsMonotoneInItsBounds(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		min := rapid.Uint32Range(0, 100000).Draw(t, "min")
		span := rapid.Uint32Range(0, 100000).Draw(t, "span")
		growLo := rapid.Uint32Range(0, 100000).Draw(t, "growLo")
		growHi := rapid.Uint32Range(0, 100000).Draw(t, "growHi")
		max := min + span
		v := drawBoundaryRelative(t, min, max)

		nlo, nhi := int64(min), int64(max)
		narrow := one("database.port", &configpb.Rule_IntRange{
			IntRange: &configpb.IntRange{Min: &nlo, Max: &nhi},
		})
		wlo := int64(min) - int64(growLo)
		whi := int64(max) + int64(growHi)
		wide := one("database.port", &configpb.Rule_IntRange{
			IntRange: &configpb.IntRange{Min: &wlo, Max: &whi},
		})
		if !fired(t, narrow, withPort(&v)) && fired(t, wide, withPort(&v)) {
			t.Fatalf("%d accepted by [%d,%d] but rejected by the wider [%d,%d]", v, min, max, wlo, whi)
		}
	})
}

func TestPropOneOfIsMembership(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		set := rapid.SliceOfN(rapid.SampledFrom(allTLS), 0, 6).Draw(t, "set")
		v := rapid.SampledFrom(allTLS).Draw(t, "v")

		names := make([]string, 0, len(set))
		member := false
		for _, m := range set {
			names = append(names, m.String())
			if m == v {
				member = true
			}
		}
		rules := one("database.tls_mode", &configpb.Rule_OneOf{
			OneOf: &configpb.OneOf{EnumValues: names},
		})
		if fired(t, rules, withTLS(&v)) == member {
			t.Fatalf("%s in %v: expected member=%v", v, names, member)
		}
	})
}

func TestPropForbiddenValueIsDisequality(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		x := rapid.SampledFrom(allTLS).Draw(t, "x")
		v := rapid.SampledFrom(allTLS).Draw(t, "v")
		name := x.String()
		rules := one("database.tls_mode", &configpb.Rule_ForbiddenValue{
			ForbiddenValue: &configpb.ForbiddenValue{EnumValue: &name},
		})
		if fired(t, rules, withTLS(&v)) != (x == v) {
			t.Fatalf("forbidding %s saw %s", x, v)
		}
	})
}

func TestPropNonEmptyIsLength(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		v := rapid.String().Draw(t, "v")
		rules := one("database.host", &configpb.Rule_NonEmpty{NonEmpty: &configpb.NonEmpty{}})
		if fired(t, rules, withHost(&v)) != (v == "") {
			t.Fatalf("value %q", v)
		}
	})
}

func TestPropRequiredIsTheNegationOfAbsence(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		present := rapid.Bool().Draw(t, "present")
		var host *string
		if present {
			s := rapid.String().Draw(t, "s")
			host = &s
		}
		rules := one("database.host", &configpb.Rule_Required{Required: &configpb.Required{}})
		if fired(t, rules, withHost(host)) != !present {
			t.Fatalf("present=%v", present)
		}
	})
}

func TestPropConditionalPredicatesFireOnlyOnTriggerAndPresence(t *testing.T) {
	onpremName := configpb.EnvironmentKind_ENVIRONMENT_KIND_ONPREM.String()
	var others []string
	for _, k := range allKinds {
		if k != configpb.EnvironmentKind_ENVIRONMENT_KIND_ONPREM {
			others = append(others, k.String())
		}
	}

	rapid.Check(t, func(t *rapid.T) {
		kind := rapid.SampledFrom(allKinds).Draw(t, "kind")
		present := rapid.Bool().Draw(t, "present")
		var instance *string
		if present {
			s := "x"
			instance = &s
		}
		cfg := withKindInstance(kind, instance)
		onprem := kind == configpb.EnvironmentKind_ENVIRONMENT_KIND_ONPREM
		kindPath := "kind"

		req := one("instance", &configpb.Rule_RequiredIf{RequiredIf: &configpb.RequiredIf{
			OtherFieldPath: &kindPath, OtherEnumValue: &onpremName,
		}})
		if fired(t, req, cfg) != (onprem && !present) {
			t.Fatalf("required_if kind=%s present=%v", kind, present)
		}

		forb := one("instance", &configpb.Rule_ForbiddenIf{ForbiddenIf: &configpb.ForbiddenIf{
			OtherFieldPath: &kindPath, OtherEnumValues: others,
		}})
		if fired(t, forb, cfg) != (!onprem && present) {
			t.Fatalf("forbidden_if kind=%s present=%v", kind, present)
		}
	})
}
