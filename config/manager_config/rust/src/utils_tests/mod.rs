//! Shared test fixtures.
//!
//! In `src/`, not `tests/`: Bazel cannot reach helper files inside `tests/` but can reach all of
//! `src/` during testing, and the side effect is that these helpers are themselves compiled and
//! counted. They are `pub` because integration tests are a separate crate and reach them through
//! the public API like any other consumer.

use prost::Message;
use serviceradar_config_schema::{
    CoreConfig, DatabaseConfig, DgraphConfig, DgraphTlsMode, EnvironmentConfig, EnvironmentKind,
    NatsConfig, RuleSet, SecurityMode, TlsMode,
};

/// A rule set built here rather than read from `//config/rules:ruleset_binpb`.
///
/// The committed rule set is a BUILD OUTPUT -- protoc compiles it from `.textproto` -- and this
/// repository removes Bazel's convenience symlinks (`--experimental_convenience_symlinks=clean`),
/// so `cargo test` has no path to it. Reading it under Bazel and substituting something else
/// under cargo would leave the two runs testing different things, which is worse than either.
///
/// It is also the right fixture on the merits. These tests are about what the manager DOES with
/// a rule set -- delegate, and refuse to return a value when anything fires -- not about the
/// contents of the committed one. That the committed rules accept every committed instance is
/// asserted where it belongs, by `//config/validator/rust:file_phase_test`, against the real
/// artifacts.
pub fn rules() -> RuleSet {
    use serviceradar_config_schema::{rule::Predicate, OneOf, Phase, Required, Rule, Scope};

    let rule = |field_path: &str, code: &str, predicate, scope| Rule {
        field_path: Some(field_path.to_string()),
        code: Some(code.to_string()),
        phase: Some(Phase::Config as i32),
        scope,
        description: None,
        predicate: Some(predicate),
    };

    RuleSet {
        rules: vec![
            rule("database.host", "DATABASE_HOST_REQUIRED", Predicate::Required(Required {}), None),
            rule(
                "database.tls_mode",
                "DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST",
                Predicate::OneOf(OneOf {
                    enum_values: vec![
                        "TLS_MODE_VERIFY_CA".to_string(),
                        "TLS_MODE_VERIFY_FULL".to_string(),
                    ],
                    string_values: vec![],
                }),
                Some(Scope {
                    kinds: vec![],
                    except_kinds: vec![EnvironmentKind::Localhost as i32],
                }),
            ),
        ],
    }
}

pub fn encode(cfg: &EnvironmentConfig) -> Vec<u8> {
    let mut buf = Vec::new();
    cfg.encode(&mut buf).expect("encode");
    buf
}

/// A valid `ci` instance, as the baseline every mutation below starts from.
pub fn valid_ci() -> EnvironmentConfig {
    EnvironmentConfig {
        kind: Some(EnvironmentKind::Ci as i32),
        instance: None,
        database: Some(DatabaseConfig {
            host: Some("db".into()),
            port: Some(5432),
            database: Some("srql_fixture".into()),
            connecting_role: Some("srql_test".into()),
            owning_role: Some("srql_test".into()),
            tls_mode: Some(TlsMode::VerifyFull as i32),
            tls_server_name: Some("db".into()),
            search_path: Some("platform, ag_catalog".into()),
            pool_size: Some(10),
            queue_target_ms: Some(500),
            queue_interval_ms: Some(1000),
            ownership_timeout_ms: Some(60_000),
        }),
        nats: Some(NatsConfig {
            url: Some("nats://nats:4222".into()),
            server_name: Some("nats".into()),
        }),
        core: Some(CoreConfig {
            address: Some("core:50052".into()),
            api_url: Some("http://core:8090".into()),
            security_mode: Some(SecurityMode::Mtls as i32),
            server_name: Some("core".into()),
            trust_domain: None,
            server_spiffe_id: None,
            workload_socket: None,
        }),
        dgraph: Some(DgraphConfig {
            host: Some("dgraph".into()),
            port: Some(9080),
            tls_mode: Some(DgraphTlsMode::VerifyCa as i32),
        }),
    }
}
