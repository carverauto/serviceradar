//! Shared test fixtures.
//!
//! In `src/`, not `tests/`: Bazel cannot reach helper files inside `tests/` but can reach all of
//! `src/` during testing, and the side effect is that these helpers are themselves compiled and
//! counted. They are `pub` because integration tests are a separate crate and reach them through
//! the public API like any other consumer.

use prost::Message;
use serviceradar_config_schema::{
    CoreConfig, DatabaseConfig, DgraphConfig, DgraphTlsMode, EnvironmentConfig, EnvironmentKind,
    NatsConfig, SecurityMode, TlsMode,
};

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
            connecting_role: Some("srql".into()),
            owning_role: Some("srql".into()),
            admin_role: Some("srql_hydra".into()),
            tls_mode: Some(TlsMode::VerifyFull as i32),
            tls_server_name: Some("db".into()),
            ca_bundle_url: Some("https://ca.example/ca.crt".into()),
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
            ca_bundle_url: None,
        }),
    }
}
