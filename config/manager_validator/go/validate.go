// Package validator evaluates the committed rule set against an environment instance.
//
// This is an implementation of config/SEMANTICS.md, not a second definition of it. Where this
// file and that document disagree, the document is right and this is a bug -- which is what the
// shared conformance vectors exist to detect. See //config/rules/fixtures.
//
// Decision 12 requires every implementation to validate at LOAD, so this runs in production
// paths, not only in tests.
package validator

import (
	"fmt"
	"regexp"
	"sort"

	configpb "github.com/carverauto/serviceradar/config/proto_bindings/go"
)

// Verdict is one rule's outcome. NotApplicable is a first-class result, not an error: a
// predicate that cannot speak about an absent field must say so rather than guess.
type Verdict int

const (
	Satisfied Verdict = iota
	Violated
	NotApplicable
)

type Violation struct {
	FieldPath   string
	Code        string
	Description string
}

// UnknownField is returned when a rule names a field the schema lacks. A hard error rather than
// a skipped rule: a rule that silently never fires is the failure this system exists to remove.
type UnknownField struct{ Path string }

func (e UnknownField) Error() string { return "unknown field path: " + e.Path }

// value is a field flattened to the shapes the predicate vocabulary can talk about.
type value struct {
	absent bool
	str    *string
	num    *uint32
	// enum name as spelled in the .textproto, e.g. "TLS_MODE_VERIFY_FULL", so a rule compares
	// against the reviewable spelling rather than an integer nobody can check.
	enum *string
}

var absentValue = value{absent: true}

func strValue(s *string) value {
	if s == nil {
		return absentValue
	}
	return value{str: s}
}

func numValue(n *uint32) value {
	if n == nil {
		return absentValue
	}
	return value{num: n}
}

func enumValue(name string, present bool) value {
	if !present {
		return absentValue
	}
	return value{enum: &name}
}

func field(cfg *configpb.EnvironmentConfig, path string) (value, error) {
	db := cfg.GetDatabase()
	nats := cfg.GetNats()
	core := cfg.GetCore()
	dgraph := cfg.GetDgraph()

	switch path {
	case "kind":
		return enumValue(cfg.GetKind().String(), cfg.Kind != nil), nil
	case "instance":
		return strValue(cfg.Instance), nil

	case "database.host":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.Host), nil
	case "database.port":
		if db == nil {
			return absentValue, nil
		}
		return numValue(db.Port), nil
	case "database.database":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.Database), nil
	case "database.connecting_role":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.ConnectingRole), nil
	case "database.owning_role":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.OwningRole), nil
	case "database.tls_mode":
		if db == nil {
			return absentValue, nil
		}
		return enumValue(db.GetTlsMode().String(), db.TlsMode != nil), nil
	case "database.tls_server_name":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.TlsServerName), nil
	case "database.admin_role":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.AdminRole), nil
	case "database.ca_bundle_url":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.CaBundleUrl), nil
	case "database.search_path":
		if db == nil {
			return absentValue, nil
		}
		return strValue(db.SearchPath), nil
	case "database.pool_size":
		if db == nil {
			return absentValue, nil
		}
		return numValue(db.PoolSize), nil
	case "database.queue_target_ms":
		if db == nil {
			return absentValue, nil
		}
		return numValue(db.QueueTargetMs), nil
	case "database.queue_interval_ms":
		if db == nil {
			return absentValue, nil
		}
		return numValue(db.QueueIntervalMs), nil
	case "database.ownership_timeout_ms":
		if db == nil {
			return absentValue, nil
		}
		return numValue(db.OwnershipTimeoutMs), nil

	case "nats.url":
		if nats == nil {
			return absentValue, nil
		}
		return strValue(nats.Url), nil
	case "nats.server_name":
		if nats == nil {
			return absentValue, nil
		}
		return strValue(nats.ServerName), nil

	case "core.address":
		if core == nil {
			return absentValue, nil
		}
		return strValue(core.Address), nil
	case "core.api_url":
		if core == nil {
			return absentValue, nil
		}
		return strValue(core.ApiUrl), nil
	case "core.security_mode":
		if core == nil {
			return absentValue, nil
		}
		return enumValue(core.GetSecurityMode().String(), core.SecurityMode != nil), nil
	case "core.server_name":
		if core == nil {
			return absentValue, nil
		}
		return strValue(core.ServerName), nil
	case "core.trust_domain":
		if core == nil {
			return absentValue, nil
		}
		return strValue(core.TrustDomain), nil
	case "core.server_spiffe_id":
		if core == nil {
			return absentValue, nil
		}
		return strValue(core.ServerSpiffeId), nil
	case "core.workload_socket":
		if core == nil {
			return absentValue, nil
		}
		return strValue(core.WorkloadSocket), nil

	case "dgraph.host":
		if dgraph == nil {
			return absentValue, nil
		}
		return strValue(dgraph.Host), nil
	case "dgraph.port":
		if dgraph == nil {
			return absentValue, nil
		}
		return numValue(dgraph.Port), nil
	case "dgraph.tls_mode":
		if dgraph == nil {
			return absentValue, nil
		}
		return enumValue(dgraph.GetTlsMode().String(), dgraph.TlsMode != nil), nil
	case "dgraph.ca_bundle_url":
		if dgraph == nil {
			return absentValue, nil
		}
		return strValue(dgraph.CaBundleUrl), nil
	}
	return absentValue, UnknownField{Path: path}
}

func inScope(scope *configpb.Scope, cfg *configpb.EnvironmentConfig) bool {
	if scope == nil || cfg.Kind == nil {
		return true
	}
	kind := cfg.GetKind()
	for _, k := range scope.GetExceptKinds() {
		if k == kind {
			return false
		}
	}
	kinds := scope.GetKinds()
	if len(kinds) == 0 {
		return true
	}
	for _, k := range kinds {
		if k == kind {
			return true
		}
	}
	return false
}

// A file-phase validator sees configuration alone, so a rule needing resolved secrets is
// skipped rather than reported NotApplicable -- it was never in scope.
func phaseApplies(p configpb.Phase) bool {
	return p == configpb.Phase_PHASE_CONFIG || p == configpb.Phase_PHASE_BOTH
}

func evaluate(rule *configpb.Rule, cfg *configpb.EnvironmentConfig) (Verdict, error) {
	v, err := field(cfg, rule.GetFieldPath())
	if err != nil {
		return NotApplicable, err
	}

	switch p := rule.GetPredicate().(type) {
	case *configpb.Rule_Required:
		if v.absent {
			return Violated, nil
		}
		return Satisfied, nil

	case *configpb.Rule_NonEmpty:
		if v.absent {
			return NotApplicable, nil
		}
		if v.str != nil && *v.str == "" {
			return Violated, nil
		}
		return Satisfied, nil

	case *configpb.Rule_IntRange:
		if v.absent || v.num == nil {
			return NotApplicable, nil
		}
		n := int64(*v.num)
		lo, hi := int64(-1<<62), int64(1<<62)
		if p.IntRange.Min != nil {
			lo = p.IntRange.GetMin()
		}
		if p.IntRange.Max != nil {
			hi = p.IntRange.GetMax()
		}
		if n < lo || n > hi {
			return Violated, nil
		}
		return Satisfied, nil

	case *configpb.Rule_OneOf:
		if v.absent {
			return NotApplicable, nil
		}
		if v.enum != nil {
			return membership(p.OneOf.GetEnumValues(), *v.enum), nil
		}
		if v.str != nil {
			return membership(p.OneOf.GetStringValues(), *v.str), nil
		}
		return NotApplicable, nil

	case *configpb.Rule_Matches:
		if v.absent || v.str == nil {
			return NotApplicable, nil
		}
		re, err := regexp.Compile(p.Matches.GetPattern())
		if err != nil {
			return NotApplicable, fmt.Errorf("rule %s: bad pattern %q: %w",
				rule.GetFieldPath(), p.Matches.GetPattern(), err)
		}
		if re.MatchString(*v.str) {
			return Satisfied, nil
		}
		return Violated, nil

	case *configpb.Rule_RequiredIf:
		other, err := field(cfg, p.RequiredIf.GetOtherFieldPath())
		if err != nil {
			return NotApplicable, err
		}
		if !triggered(other, single(p.RequiredIf.OtherEnumValue), single(p.RequiredIf.OtherStringValue)) {
			return NotApplicable, nil
		}
		if v.absent {
			return Violated, nil
		}
		return Satisfied, nil

	case *configpb.Rule_ForbiddenValue:
		if v.absent {
			return NotApplicable, nil
		}
		if v.enum != nil && p.ForbiddenValue.EnumValue != nil && *v.enum == p.ForbiddenValue.GetEnumValue() {
			return Violated, nil
		}
		if v.str != nil && p.ForbiddenValue.StringValue != nil && *v.str == p.ForbiddenValue.GetStringValue() {
			return Violated, nil
		}
		return Satisfied, nil

	case *configpb.Rule_ForbiddenIf:
		other, err := field(cfg, p.ForbiddenIf.GetOtherFieldPath())
		if err != nil {
			return NotApplicable, err
		}
		// Absence is what the predicate wants; there is nothing to forbid.
		if v.absent {
			return NotApplicable, nil
		}
		if triggered(other, p.ForbiddenIf.GetOtherEnumValues(), p.ForbiddenIf.GetOtherStringValues()) {
			return Violated, nil
		}
		return Satisfied, nil

	// Ranges over instances rather than within one, so a single-instance pass cannot decide it.
	case *configpb.Rule_EqualAcrossEnvs:
		return NotApplicable, nil
	}
	return NotApplicable, nil
}

func single(s *string) []string {
	if s == nil {
		return nil
	}
	return []string{*s}
}

func membership(set []string, v string) Verdict {
	for _, s := range set {
		if s == v {
			return Satisfied
		}
	}
	return Violated
}

func triggered(other value, enums, strs []string) bool {
	if other.enum != nil {
		return membership(enums, *other.enum) == Satisfied
	}
	if other.str != nil {
		return membership(strs, *other.str) == Satisfied
	}
	return false
}

// Validate returns every file-phase violation in cfg, ordered by (field_path, code).
func Validate(rules *configpb.RuleSet, cfg *configpb.EnvironmentConfig) ([]Violation, error) {
	// Cascading: an absent field required by one rule reports once. Other predicates on the
	// same path return NotApplicable for absence anyway, but a path whose Required already
	// fired is skipped outright so the guarantee does not depend on each predicate's manners.
	failedRequired := map[string]bool{}
	out := []Violation{}

	for _, rule := range rules.GetRules() {
		if !phaseApplies(rule.GetPhase()) || !inScope(rule.GetScope(), cfg) {
			continue
		}
		path := rule.GetFieldPath()
		if failedRequired[path] {
			continue
		}
		verdict, err := evaluate(rule, cfg)
		if err != nil {
			return nil, err
		}
		if verdict != Violated {
			continue
		}
		if _, isRequired := rule.GetPredicate().(*configpb.Rule_Required); isRequired {
			failedRequired[path] = true
		}
		out = append(out, Violation{
			FieldPath:   path,
			Code:        rule.GetCode(),
			Description: rule.GetDescription(),
		})
	}

	sort.Slice(out, func(i, j int) bool {
		if out[i].FieldPath != out[j].FieldPath {
			return out[i].FieldPath < out[j].FieldPath
		}
		return out[i].Code < out[j].Code
	})
	return out, nil
}
