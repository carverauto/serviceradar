//! ServiceRadar configuration schema types.
//!
//! Generated from `config/proto/*.proto`. The schema is the cross-language contract: a field
//! that exists here exists identically in the Go and Elixir bindings, by construction. That
//! is the property the three naming schemes this replaces never had.
//!
//! This crate carries TYPES ONLY. `ConfigManager` and `SecretManager` are separate; keeping
//! the generated surface on its own means a schema change cannot silently alter manager
//! behaviour in the same diff.

#![forbid(unsafe_code)]

include!(concat!(env!("OUT_DIR"), "/serviceradar.config.v1.rs"));

#[cfg(test)]
mod tests {
    use super::*;

    // Explicit presence is the whole reason these fields are Option. A default-constructed
    // message must report ABSENCE, not a zero value -- if this ever compiles to `0` or `""`
    // the schema has lost the property that keeps a missing setting from silently becoming
    // a working-but-wrong one.
    #[test]
    fn unset_fields_are_absent_not_defaulted() {
        let db = DatabaseConfig::default();
        assert!(db.port.is_none(), "port must be absent, not 0");
        assert!(db.host.is_none(), "host must be absent, not empty string");
        assert!(db.tls_mode.is_none(), "tls_mode must be absent, not the zero enum");
    }

    // The zero value of every enum is a sentinel the rule set rejects.
    #[test]
    fn enum_zero_is_the_unspecified_sentinel() {
        assert_eq!(TlsMode::Unspecified as i32, 0);
        assert_eq!(EnvironmentKind::Unspecified as i32, 0);
        assert_eq!(SecurityMode::Unspecified as i32, 0);
    }

    // A predicate and its parameters cannot disagree: the oneof makes the pairing
    // unrepresentable rather than merely discouraged.
    #[test]
    fn rule_predicate_is_a_oneof() {
        let rule = Rule {
            field_path: Some("database.port".to_string()),
            code: Some("DATABASE_PORT_RANGE".to_string()),
            predicate: Some(rule::Predicate::IntRange(IntRange {
                min: Some(1),
                max: Some(65535),
            })),
            ..Default::default()
        };
        match rule.predicate {
            Some(rule::Predicate::IntRange(r)) => {
                assert_eq!(r.min, Some(1));
                assert_eq!(r.max, Some(65535));
            }
            other => panic!("expected IntRange, got {other:?}"),
        }
    }
}
