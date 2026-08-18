//! Shared inputs for the loading tests.

use prost::Message;
use serviceradar_config_schema::{
    CoreConfig, DatabaseConfig, DgraphConfig, DgraphTlsMode, EnvironmentConfig, EnvironmentKind,
    NatsConfig, RuleSet, SecurityMode, TlsMode,
};
use std::path::{Path, PathBuf};

fn data_path(relative: &str) -> PathBuf {
    if let Ok(dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let candidate = Path::new(&dir).join("../../..").join(relative);
        if candidate.exists() {
            return candidate;
        }
    }
    if let Ok(srcdir) = std::env::var("TEST_SRCDIR") {
        let root = PathBuf::from(srcdir);
        for workspace in ["_main", "serviceradar"] {
            let candidate = root.join(workspace).join(relative);
            if candidate.exists() {
                return candidate;
            }
        }
    }
    PathBuf::from(relative)
}

/// The real committed rule set, not a stub. A manager tested against invented rules would prove
/// nothing about what it does at boot.
pub fn rules() -> RuleSet {
    let path = data_path("config/rules/ruleset.binpb");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    RuleSet::decode(&*bytes).unwrap_or_else(|e| panic!("decode {path:?}: {e}"))
}

pub fn encode(cfg: &EnvironmentConfig) -> Vec<u8> {
    let mut buf = Vec::new();
    cfg.encode(&mut buf).expect("encode");
    buf
}

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
