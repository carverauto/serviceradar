//! Evaluates the committed rule set against a committed environment instance.
//!
//! The semantics are normative in `config/SEMANTICS.md`; this is an implementation of that
//! document, not a second definition of it. In particular:
//!
//!   * only `Required` treats ABSENCE as a violation. Every other predicate returns
//!     NotApplicable for an absent field, so one missing value yields one violation rather
//!     than a cascade (SEMANTICS.md section 4);
//!   * evaluation is exhaustive -- every rule runs, so a fix list is complete after one pass;
//!   * violations are totally ordered by `(field_path, code)`, which is what lets three
//!     implementations be compared rather than merely all rejecting (section 5).
//!
//! Field access is an explicit match rather than reflection. The schema is closed and small,
//! and the payoff is that a rule naming a field that does not exist is a hard error here
//! instead of a silently skipped rule.

#![forbid(unsafe_code)]

pub mod coverage;
pub mod credentials;
pub mod text;
pub mod utils_tests;

use regex_automata::meta::Regex;
use serviceradar_config_schema::{
    rule::Predicate, DgraphTlsMode, EnvironmentConfig, EnvironmentKind, Phase, Rule, RuleSet, Scope,
    SecurityMode, TlsMode,
};

/// One rule's verdict. `NotApplicable` is a first-class outcome, not an error: a predicate
/// that cannot speak about an absent field must say so rather than guess.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    Satisfied,
    Violated,
    NotApplicable,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Violation {
    pub field_path: String,
    pub code: String,
    pub description: String,
}

/// A field's value, flattened to the shapes the predicate vocabulary can talk about.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Value<'a> {
    Absent,
    Str(&'a str),
    U32(u32),
    /// The enum's proto name, e.g. "TLS_MODE_VERIFY_FULL", so a rule compares against the
    /// spelling used in the .textproto rather than an integer nobody can review.
    Enum(&'static str),
}

#[derive(Debug)]
pub struct UnknownField(pub String);

fn enum_name<T, F>(v: Option<i32>, from: F) -> Value<'static>
where
    F: Fn(i32) -> Option<T>,
    T: EnumName,
{
    match v.and_then(&from) {
        Some(e) => Value::Enum(e.name()),
        None => Value::Absent,
    }
}

trait EnumName {
    fn name(&self) -> &'static str;
}
impl EnumName for TlsMode {
    fn name(&self) -> &'static str {
        self.as_str_name()
    }
}
impl EnumName for SecurityMode {
    fn name(&self) -> &'static str {
        self.as_str_name()
    }
}
impl EnumName for DgraphTlsMode {
    fn name(&self) -> &'static str {
        self.as_str_name()
    }
}
impl EnumName for EnvironmentKind {
    fn name(&self) -> &'static str {
        self.as_str_name()
    }
}

fn opt_str(v: &Option<String>) -> Value<'_> {
    v.as_deref().map_or(Value::Absent, Value::Str)
}

fn opt_u32(v: Option<u32>) -> Value<'static> {
    v.map_or(Value::Absent, Value::U32)
}

fn field<'a>(cfg: &'a EnvironmentConfig, path: &str) -> Result<Value<'a>, UnknownField> {
    let db = cfg.database.as_ref();
    let nats = cfg.nats.as_ref();
    let core = cfg.core.as_ref();
    let dgraph = cfg.dgraph.as_ref();

    let v = match path {
        "kind" => enum_name(cfg.kind, |i| EnvironmentKind::try_from(i).ok()),
        "instance" => opt_str(&cfg.instance),

        "database.host" => db.map_or(Value::Absent, |d| opt_str(&d.host)),
        "database.port" => db.map_or(Value::Absent, |d| opt_u32(d.port)),
        "database.database" => db.map_or(Value::Absent, |d| opt_str(&d.database)),
        "database.connecting_role" => db.map_or(Value::Absent, |d| opt_str(&d.connecting_role)),
        "database.owning_role" => db.map_or(Value::Absent, |d| opt_str(&d.owning_role)),
        "database.tls_mode" => db.map_or(Value::Absent, |d| {
            enum_name(d.tls_mode, |i| TlsMode::try_from(i).ok())
        }),
        "database.tls_server_name" => db.map_or(Value::Absent, |d| opt_str(&d.tls_server_name)),
        "database.admin_role" => db.map_or(Value::Absent, |d| opt_str(&d.admin_role)),
        "database.ca_bundle_url" => db.map_or(Value::Absent, |d| opt_str(&d.ca_bundle_url)),
        "database.search_path" => db.map_or(Value::Absent, |d| opt_str(&d.search_path)),
        "database.pool_size" => db.map_or(Value::Absent, |d| opt_u32(d.pool_size)),
        "database.queue_target_ms" => db.map_or(Value::Absent, |d| opt_u32(d.queue_target_ms)),
        "database.queue_interval_ms" => db.map_or(Value::Absent, |d| opt_u32(d.queue_interval_ms)),
        "database.ownership_timeout_ms" => {
            db.map_or(Value::Absent, |d| opt_u32(d.ownership_timeout_ms))
        }

        "nats.url" => nats.map_or(Value::Absent, |n| opt_str(&n.url)),
        "nats.server_name" => nats.map_or(Value::Absent, |n| opt_str(&n.server_name)),

        "core.address" => core.map_or(Value::Absent, |c| opt_str(&c.address)),
        "core.api_url" => core.map_or(Value::Absent, |c| opt_str(&c.api_url)),
        "core.security_mode" => core.map_or(Value::Absent, |c| {
            enum_name(c.security_mode, |i| SecurityMode::try_from(i).ok())
        }),
        "core.server_name" => core.map_or(Value::Absent, |c| opt_str(&c.server_name)),
        "core.trust_domain" => core.map_or(Value::Absent, |c| opt_str(&c.trust_domain)),
        "core.server_spiffe_id" => core.map_or(Value::Absent, |c| opt_str(&c.server_spiffe_id)),
        "core.workload_socket" => core.map_or(Value::Absent, |c| opt_str(&c.workload_socket)),

        "dgraph.host" => dgraph.map_or(Value::Absent, |d| opt_str(&d.host)),
        "dgraph.port" => dgraph.map_or(Value::Absent, |d| opt_u32(d.port)),
        "dgraph.tls_mode" => dgraph.map_or(Value::Absent, |d| {
            enum_name(d.tls_mode, |i| DgraphTlsMode::try_from(i).ok())
        }),
        "dgraph.ca_bundle_url" => dgraph.map_or(Value::Absent, |d| opt_str(&d.ca_bundle_url)),

        other => return Err(UnknownField(other.to_string())),
    };
    Ok(v)
}

fn in_scope(scope: Option<&Scope>, kind: Option<i32>) -> bool {
    let Some(scope) = scope else { return true };
    let Some(kind) = kind else { return true };
    if !scope.except_kinds.is_empty() && scope.except_kinds.contains(&kind) {
        return false;
    }
    if !scope.kinds.is_empty() && !scope.kinds.contains(&kind) {
        return false;
    }
    true
}

fn phase_applies(phase: Option<i32>) -> bool {
    match phase.and_then(|p| Phase::try_from(p).ok()) {
        // A file-phase validator sees configuration alone, so a rule needing resolved
        // secrets is skipped rather than reported NotApplicable -- it was never in scope.
        Some(Phase::Config) | Some(Phase::Both) => true,
        _ => false,
    }
}

fn evaluate(rule: &Rule, cfg: &EnvironmentConfig) -> Result<Verdict, UnknownField> {
    let path = rule.field_path.as_deref().unwrap_or_default();
    let value = field(cfg, path)?;

    let verdict = match rule.predicate.as_ref() {
        Some(Predicate::Required(_)) => match value {
            Value::Absent => Verdict::Violated,
            _ => Verdict::Satisfied,
        },
        Some(Predicate::NonEmpty(_)) => match value {
            Value::Absent => Verdict::NotApplicable,
            Value::Str("") => Verdict::Violated,
            _ => Verdict::Satisfied,
        },
        Some(Predicate::IntRange(r)) => match value {
            Value::Absent => Verdict::NotApplicable,
            Value::U32(n) => {
                let n = i64::from(n);
                let lo = r.min.unwrap_or(i64::MIN);
                let hi = r.max.unwrap_or(i64::MAX);
                if n < lo || n > hi {
                    Verdict::Violated
                } else {
                    Verdict::Satisfied
                }
            }
            _ => Verdict::NotApplicable,
        },
        Some(Predicate::OneOf(o)) => match value {
            Value::Absent => Verdict::NotApplicable,
            Value::Enum(name) => {
                if o.enum_values.iter().any(|v| v == name) {
                    Verdict::Satisfied
                } else {
                    Verdict::Violated
                }
            }
            Value::Str(s) => {
                if o.string_values.iter().any(|v| v == s) {
                    Verdict::Satisfied
                } else {
                    Verdict::Violated
                }
            }
            _ => Verdict::NotApplicable,
        },
        Some(Predicate::Matches(m)) => match value {
            Value::Absent => Verdict::NotApplicable,
            Value::Str(s) => {
                let pattern = m.pattern.as_deref().unwrap_or("");
                let re = Regex::new(pattern)
                    .unwrap_or_else(|e| panic!("rule {path}: bad pattern {pattern:?}: {e}"));
                if re.is_match(s) {
                    Verdict::Satisfied
                } else {
                    Verdict::Violated
                }
            }
            _ => Verdict::NotApplicable,
        },
        Some(Predicate::RequiredIf(c)) => {
            let other_path = c.other_field_path.as_deref().unwrap_or_default();
            let other = field(cfg, other_path)?;
            let triggered = match other {
                Value::Enum(name) => c.other_enum_value.as_deref() == Some(name),
                Value::Str(s) => c.other_string_value.as_deref() == Some(s),
                _ => false,
            };
            if !triggered {
                Verdict::NotApplicable
            } else if matches!(value, Value::Absent) {
                Verdict::Violated
            } else {
                Verdict::Satisfied
            }
        }
        Some(Predicate::ForbiddenValue(f)) => match value {
            Value::Absent => Verdict::NotApplicable,
            Value::Enum(name) => {
                if f.enum_value.as_deref() == Some(name) {
                    Verdict::Violated
                } else {
                    Verdict::Satisfied
                }
            }
            Value::Str(s) => {
                if f.string_value.as_deref() == Some(s) {
                    Verdict::Violated
                } else {
                    Verdict::Satisfied
                }
            }
            _ => Verdict::Satisfied,
        },
        Some(Predicate::ForbiddenIf(c)) => {
            let other_path = c.other_field_path.as_deref().unwrap_or_default();
            let other = field(cfg, other_path)?;
            let triggered = match other {
                Value::Enum(name) => c.other_enum_values.iter().any(|v| v == name),
                Value::Str(s) => c.other_string_values.iter().any(|v| v == s),
                _ => false,
            };
            match value {
                // Absence is what the predicate wants; there is nothing to forbid.
                Value::Absent => Verdict::NotApplicable,
                _ if triggered => Verdict::Violated,
                _ => Verdict::Satisfied,
            }
        }
        // Ranges over instances rather than within one, so a single-instance pass cannot
        // decide it. The cross-instance check is a separate pass over the whole set.
        Some(Predicate::EqualAcrossEnvs(_)) => Verdict::NotApplicable,
        None => Verdict::NotApplicable,
    };
    Ok(verdict)
}

/// Every file-phase violation in `cfg`, ordered by `(field_path, code)`.
pub fn validate(rules: &RuleSet, cfg: &EnvironmentConfig) -> Result<Vec<Violation>, UnknownField> {
    // Cascading: an absent field required by one rule reports once. Other predicates on the
    // same path return NotApplicable for absence anyway, but a path whose Required already
    // fired is skipped outright so the guarantee does not depend on each predicate's manners.
    let mut failed_required: Vec<&str> = Vec::new();
    let mut out = Vec::new();

    for rule in &rules.rules {
        if !phase_applies(rule.phase) || !in_scope(rule.scope.as_ref(), cfg.kind) {
            continue;
        }
        let path = rule.field_path.as_deref().unwrap_or_default();
        if failed_required.contains(&path) {
            continue;
        }
        if evaluate(rule, cfg)? == Verdict::Violated {
            if matches!(rule.predicate.as_ref(), Some(Predicate::Required(_))) {
                failed_required.push(path);
            }
            out.push(Violation {
                field_path: path.to_string(),
                code: rule.code.clone().unwrap_or_default(),
                description: rule.description.clone().unwrap_or_default(),
            });
        }
    }

    out.sort();
    Ok(out)
}
