//! Each predicate obeys its algebraic law, and every predicate is total.
//!
//! The vector fixtures pin what the RULE SET means; these pin what the PREDICATES mean.
//!
//! Two layers, and both are needed (Decision 5). The `proptest` properties state each law as a
//! universally quantified claim over generated inputs, which is what actually argues the engine
//! is sound rather than merely right on the cases someone thought of -- and on failure proptest
//! SHRINKS to a minimal counterexample, so a violated law arrives as the smallest input that
//! breaks it. The hand-written cases that follow pin the specific points most likely to diverge
//! between three implementations: the exact bound, one past it, and absence for every predicate
//! kind. Random generation reaches an inclusive edge only by luck.

use serviceradar_config_schema::{
    rule::Predicate, DatabaseConfig, EnvironmentConfig, EnvironmentKind, ForbiddenIf,
    ForbiddenValue, IntRange, Matches, NonEmpty, OneOf, Phase, Required, RequiredIf, Rule, RuleSet,
    Scope, TlsMode,
};
use serviceradar_config_validator::validate;

use proptest::prelude::*;

const CODE: &str = "UNDER_TEST";

fn one(field_path: &str, predicate: Predicate) -> RuleSet {
    RuleSet {
        rules: vec![Rule {
            field_path: Some(field_path.to_string()),
            code: Some(CODE.to_string()),
            phase: Some(Phase::Config as i32),
            scope: None::<Scope>,
            description: None,
            predicate: Some(predicate),
        }],
    }
}

/// True when the single rule under test fired.
fn fired(rules: &RuleSet, cfg: &EnvironmentConfig) -> bool {
    let v = validate(rules, cfg).expect("the rule names a field the schema has");
    v.iter().any(|v| v.code == CODE)
}

fn with_port(port: Option<u32>) -> EnvironmentConfig {
    EnvironmentConfig {
        database: Some(DatabaseConfig { port, ..Default::default() }),
        ..Default::default()
    }
}

fn with_host(host: Option<&str>) -> EnvironmentConfig {
    EnvironmentConfig {
        database: Some(DatabaseConfig {
            host: host.map(str::to_string),
            ..Default::default()
        }),
        ..Default::default()
    }
}

fn with_tls(mode: Option<TlsMode>) -> EnvironmentConfig {
    EnvironmentConfig {
        database: Some(DatabaseConfig {
            tls_mode: mode.map(|m| m as i32),
            ..Default::default()
        }),
        ..Default::default()
    }
}

fn with_kind_and_instance(kind: Option<EnvironmentKind>, instance: Option<&str>) -> EnvironmentConfig {
    EnvironmentConfig {
        kind: kind.map(|k| k as i32),
        instance: instance.map(str::to_string),
        ..Default::default()
    }
}

const ALL_KINDS: &[EnvironmentKind] = &[
    EnvironmentKind::Unspecified,
    EnvironmentKind::Localhost,
    EnvironmentKind::Ci,
    EnvironmentKind::Saas,
    EnvironmentKind::Onprem,
    EnvironmentKind::Demo,
];

const ALL_TLS: &[TlsMode] = &[
    TlsMode::Unspecified,
    TlsMode::Disable,
    TlsMode::Require,
    TlsMode::VerifyCa,
    TlsMode::VerifyFull,
];

/// Every predicate kind, for the cross-cutting laws below.
fn every_predicate() -> Vec<(&'static str, Predicate)> {
    vec![
        ("required", Predicate::Required(Required {})),
        ("non_empty", Predicate::NonEmpty(NonEmpty {})),
        ("int_range", Predicate::IntRange(IntRange { min: Some(1), max: Some(10) })),
        (
            "one_of",
            Predicate::OneOf(OneOf {
                enum_values: vec!["TLS_MODE_VERIFY_FULL".into()],
                string_values: vec!["x".into()],
            }),
        ),
        ("matches", Predicate::Matches(Matches { pattern: Some("^x".into()) })),
        (
            "required_if",
            Predicate::RequiredIf(RequiredIf {
                other_field_path: Some("kind".into()),
                other_enum_value: Some("ENVIRONMENT_KIND_ONPREM".into()),
                other_string_value: None,
            }),
        ),
        (
            "forbidden_value",
            Predicate::ForbiddenValue(ForbiddenValue {
                enum_value: Some("TLS_MODE_UNSPECIFIED".into()),
                string_value: Some("x".into()),
            }),
        ),
        (
            "forbidden_if",
            Predicate::ForbiddenIf(ForbiddenIf {
                other_field_path: Some("kind".into()),
                other_enum_values: vec!["ENVIRONMENT_KIND_CI".into()],
                other_string_values: vec![],
            }),
        ),
    ]
}

/// SEMANTICS.md section 3's load-bearing sentence: `Required` is the ONLY predicate that treats
/// absence as a violation. Everything downstream depends on it -- it is what makes one missing
/// value yield one violation instead of a cascade.
#[test]
fn only_required_violates_on_absence() {
    for (name, predicate) in every_predicate() {
        // `instance` is absent here, and `kind` is set so the conditional predicates' triggers
        // are live -- otherwise they would be vacuously NotApplicable and prove nothing.
        let cfg = with_kind_and_instance(Some(EnvironmentKind::Onprem), None);
        let rules = one("instance", predicate);
        let fired = fired(&rules, &cfg);
        assert_eq!(
            fired,
            name == "required" || name == "required_if",
            "{name} on an absent field: fired={fired}"
        );
    }
}

/// Bounds are inclusive at both ends. SEMANTICS.md calls this the most likely point of
/// divergence between three implementations, so both edges and both misses are walked.
#[test]
fn int_range_is_inclusive_at_both_edges() {
    for (min, max) in [(1u32, 10u32), (0, 0), (5, 5), (1, 65535)] {
        let rules = one(
            "database.port",
            Predicate::IntRange(IntRange { min: Some(min as i64), max: Some(max as i64) }),
        );
        for v in [min.saturating_sub(1), min, max, max.saturating_add(1)] {
            let inside = v >= min && v <= max;
            assert_eq!(
                !fired(&rules, &with_port(Some(v))),
                inside,
                "range [{min},{max}] at {v}: expected inside={inside}"
            );
        }
    }
}

/// Widening a range never turns an accepted value into a rejected one.
#[test]
fn int_range_is_monotone_in_its_bounds() {
    let values = [0u32, 1, 5, 10, 11, 65535];
    for v in values {
        let narrow = one(
            "database.port",
            Predicate::IntRange(IntRange { min: Some(5), max: Some(10) }),
        );
        let wide = one(
            "database.port",
            Predicate::IntRange(IntRange { min: Some(1), max: Some(100) }),
        );
        if !fired(&narrow, &with_port(Some(v))) {
            assert!(
                !fired(&wide, &with_port(Some(v))),
                "{v} accepted by [5,10] but rejected by the wider [1,100]"
            );
        }
    }
}

/// `one_of(v, S)` is exactly membership, walked over the whole enum against several sets.
#[test]
fn one_of_is_membership() {
    let sets: &[&[TlsMode]] = &[
        &[],
        &[TlsMode::VerifyFull],
        &[TlsMode::VerifyCa, TlsMode::VerifyFull],
        ALL_TLS,
    ];
    for set in sets {
        let rules = one(
            "database.tls_mode",
            Predicate::OneOf(OneOf {
                enum_values: set.iter().map(|m| m.as_str_name().to_string()).collect(),
                string_values: vec![],
            }),
        );
        for mode in ALL_TLS {
            let member = set.contains(mode);
            assert_eq!(
                !fired(&rules, &with_tls(Some(*mode))),
                member,
                "{} in {:?}: expected member={member}",
                mode.as_str_name(),
                set.iter().map(|m| m.as_str_name()).collect::<Vec<_>>()
            );
        }
    }
}

/// `forbidden_value(x)` is exactly disequality -- the dual of a one-element `one_of`.
#[test]
fn forbidden_value_is_disequality() {
    for forbidden in ALL_TLS {
        let rules = one(
            "database.tls_mode",
            Predicate::ForbiddenValue(ForbiddenValue {
                enum_value: Some(forbidden.as_str_name().to_string()),
                string_value: None,
            }),
        );
        for mode in ALL_TLS {
            assert_eq!(
                fired(&rules, &with_tls(Some(*mode))),
                mode == forbidden,
                "forbidding {} saw {}",
                forbidden.as_str_name(),
                mode.as_str_name()
            );
        }
    }
}

/// `non_empty` is a statement about length, not about presence.
#[test]
fn non_empty_is_length() {
    let rules = one("database.host", Predicate::NonEmpty(NonEmpty {}));
    for (value, violates) in [(Some(""), true), (Some("a"), false), (Some("  "), false), (None, false)] {
        assert_eq!(fired(&rules, &with_host(value)), violates, "value {value:?}");
    }
}

/// The conditional pair fires on its trigger and nowhere else, walked over every kind.
#[test]
fn conditional_predicates_fire_only_on_their_trigger() {
    let required_if = one(
        "instance",
        Predicate::RequiredIf(RequiredIf {
            other_field_path: Some("kind".into()),
            other_enum_value: Some("ENVIRONMENT_KIND_ONPREM".into()),
            other_string_value: None,
        }),
    );
    let forbidden_if = one(
        "instance",
        Predicate::ForbiddenIf(ForbiddenIf {
            other_field_path: Some("kind".into()),
            other_enum_values: ALL_KINDS
                .iter()
                .filter(|k| **k != EnvironmentKind::Onprem)
                .map(|k| k.as_str_name().to_string())
                .collect(),
            other_string_values: vec![],
        }),
    );

    for kind in ALL_KINDS {
        let onprem = *kind == EnvironmentKind::Onprem;

        // required_if: violated exactly when the trigger holds and the value is absent.
        assert_eq!(
            fired(&required_if, &with_kind_and_instance(Some(*kind), None)),
            onprem,
            "required_if on absent instance, kind={}",
            kind.as_str_name()
        );
        assert!(
            !fired(&required_if, &with_kind_and_instance(Some(*kind), Some("x"))),
            "required_if must never fire when the value is present"
        );

        // forbidden_if: violated exactly when the trigger holds and the value is present.
        assert_eq!(
            fired(&forbidden_if, &with_kind_and_instance(Some(*kind), Some("x"))),
            !onprem,
            "forbidden_if on present instance, kind={}",
            kind.as_str_name()
        );
        assert!(
            !fired(&forbidden_if, &with_kind_and_instance(Some(*kind), None)),
            "forbidden_if must never fire when the value is absent"
        );
    }
}

/// Totality: every predicate returns a verdict for every input in the matrix, with no partiality
/// and no panic. A predicate that panicked on an unexpected shape would take a service down at
/// boot rather than reporting a violation.
#[test]
fn every_predicate_is_total_over_the_input_matrix() {
    for (name, predicate) in every_predicate() {
        for field in ["instance", "database.host", "database.port", "database.tls_mode"] {
            let rules = one(field, predicate.clone());
            for kind in ALL_KINDS {
                let cases = [
                    with_kind_and_instance(Some(*kind), None),
                    with_kind_and_instance(Some(*kind), Some("")),
                    with_port(None),
                    with_port(Some(0)),
                    with_port(Some(u32::MAX)),
                    with_host(Some("")),
                    with_tls(None),
                    with_tls(Some(TlsMode::Unspecified)),
                    EnvironmentConfig::default(),
                ];
                for cfg in cases {
                    validate(&rules, &cfg)
                        .unwrap_or_else(|e| panic!("{name} on {field}: unknown field {}", e.0));
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Properties: each law as a universally quantified claim over generated inputs.
// ---------------------------------------------------------------------------

fn any_tls_mode() -> impl Strategy<Value = TlsMode> {
    prop::sample::select(ALL_TLS.to_vec())
}

fn any_kind() -> impl Strategy<Value = EnvironmentKind> {
    prop::sample::select(ALL_KINDS.to_vec())
}

proptest! {
    /// `IntRange(min,max)` is satisfied exactly when `min <= v <= max`, for ANY bounds and ANY
    /// value -- not merely for the bounds the rule set happens to use today.
    ///
    /// The value is drawn RELATIVE TO THE BOUNDS, not independently of them. An independent
    /// draw over 400k values reaches `v == max` only by luck, so the property passed against a
    /// deliberately off-by-one engine -- it never generated the input that distinguishes
    /// inclusive from exclusive. Sampling a boundary is not the same as testing it.
    #[test]
    fn prop_int_range_is_inclusive_containment(
        min in 0u32..=200_000,
        span in 0u32..=200_000,
        pick in 0usize..6,
        free in 0u32..=400_000,
    ) {
        let max = min.saturating_add(span);
        let v = match pick {
            0 => min.saturating_sub(1),
            1 => min,
            2 => max,
            3 => max.saturating_add(1),
            4 => min.saturating_add(span / 2),
            _ => free,
        };
        let rules = one(
            "database.port",
            Predicate::IntRange(IntRange { min: Some(min as i64), max: Some(max as i64) }),
        );
        prop_assert_eq!(!fired(&rules, &with_port(Some(v))), v >= min && v <= max);
    }

    /// Widening a range never rejects a value it previously accepted. Monotonicity is the
    /// property a rule-set edit relies on when a bound is relaxed.
    #[test]
    fn prop_int_range_is_monotone_in_its_bounds(
        min in 0u32..=100_000,
        span in 0u32..=100_000,
        grow_lo in 0u32..=100_000,
        grow_hi in 0u32..=100_000,
        pick in 0usize..6,
        free in 0u32..=400_000,
    ) {
        let max = min.saturating_add(span);
        let v = match pick {
            0 => min.saturating_sub(1),
            1 => min,
            2 => max,
            3 => max.saturating_add(1),
            4 => min.saturating_add(span / 2),
            _ => free,
        };
        let narrow = one("database.port",
            Predicate::IntRange(IntRange { min: Some(min as i64), max: Some(max as i64) }));
        let wide = one("database.port", Predicate::IntRange(IntRange {
            min: Some(min.saturating_sub(grow_lo) as i64),
            max: Some(max.saturating_add(grow_hi) as i64),
        }));
        if !fired(&narrow, &with_port(Some(v))) {
            prop_assert!(!fired(&wide, &with_port(Some(v))));
        }
    }

    /// `one_of(v, S)` is exactly membership, for any subset S of the enum.
    #[test]
    fn prop_one_of_is_membership(
        set in prop::collection::vec(any_tls_mode(), 0..6),
        v in any_tls_mode(),
    ) {
        let rules = one("database.tls_mode", Predicate::OneOf(OneOf {
            enum_values: set.iter().map(|m| m.as_str_name().to_string()).collect(),
            string_values: vec![],
        }));
        prop_assert_eq!(!fired(&rules, &with_tls(Some(v))), set.contains(&v));
    }

    /// `forbidden_value(x)` is exactly disequality -- the dual of a one-element `one_of`.
    #[test]
    fn prop_forbidden_value_is_disequality(x in any_tls_mode(), v in any_tls_mode()) {
        let rules = one("database.tls_mode", Predicate::ForbiddenValue(ForbiddenValue {
            enum_value: Some(x.as_str_name().to_string()),
            string_value: None,
        }));
        prop_assert_eq!(fired(&rules, &with_tls(Some(v))), x == v);
    }

    /// `non_empty` speaks about LENGTH, and says nothing about presence. Generated over
    /// arbitrary strings, including the whitespace and unicode a case table omits.
    #[test]
    fn prop_non_empty_is_length(v in ".*") {
        let rules = one("database.host", Predicate::NonEmpty(NonEmpty {}));
        prop_assert_eq!(fired(&rules, &with_host(Some(&v))), v.is_empty());
    }

    /// `required` is violated exactly on absence, for any value.
    #[test]
    fn prop_required_is_the_negation_of_absence(v in prop::option::of(".*")) {
        let rules = one("database.host", Predicate::Required(Required {}));
        prop_assert_eq!(fired(&rules, &with_host(v.as_deref())), v.is_none());
    }

    /// The conditional pair: `required_if` fires exactly on (trigger AND absent),
    /// `forbidden_if` exactly on (trigger AND present). Quantified over every kind and both
    /// presence states, which is the claim the `instance` invariant rests on.
    #[test]
    fn prop_conditional_predicates_fire_only_on_trigger_and_presence(
        kind in any_kind(),
        present in any::<bool>(),
    ) {
        let instance = if present { Some("x") } else { None };
        let cfg = with_kind_and_instance(Some(kind), instance);

        let req = one("instance", Predicate::RequiredIf(RequiredIf {
            other_field_path: Some("kind".into()),
            other_enum_value: Some("ENVIRONMENT_KIND_ONPREM".into()),
            other_string_value: None,
        }));
        let onprem = kind == EnvironmentKind::Onprem;
        prop_assert_eq!(fired(&req, &cfg), onprem && !present);

        let forb = one("instance", Predicate::ForbiddenIf(ForbiddenIf {
            other_field_path: Some("kind".into()),
            other_enum_values: ALL_KINDS.iter().filter(|k| **k != EnvironmentKind::Onprem)
                .map(|k| k.as_str_name().to_string()).collect(),
            other_string_values: vec![],
        }));
        prop_assert_eq!(fired(&forb, &cfg), !onprem && present);
    }

    /// Totality, quantified: no predicate panics or returns an error on any generated input.
    /// A predicate that panicked on an unexpected shape would take a service down at boot
    /// rather than report a violation.
    #[test]
    fn prop_every_predicate_is_total(
        idx in 0usize..8,
        kind in any_kind(),
        host in prop::option::of(".*"),
        port in prop::option::of(any::<u32>()),
        tls in prop::option::of(any_tls_mode()),
        instance in prop::option::of(".*"),
    ) {
        let (_, predicate) = every_predicate().swap_remove(idx);
        let cfg = EnvironmentConfig {
            kind: Some(kind as i32),
            instance,
            database: Some(DatabaseConfig {
                host,
                port,
                tls_mode: tls.map(|m| m as i32),
                ..Default::default()
            }),
            ..Default::default()
        };
        for field in ["instance", "database.host", "database.port", "database.tls_mode"] {
            let rules = one(field, predicate.clone());
            prop_assert!(validate(&rules, &cfg).is_ok());
        }
    }
}
