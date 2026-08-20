//! Shared test fixtures.
//!
//! In `src/`, not `tests/`: Bazel cannot reach helper files inside `tests/` but can reach all of
//! `src/` during testing. The side effect is that these helpers are themselves compiled and
//! counted. They are `pub` because integration tests are a separate crate and reach them through
//! the public API like any other consumer.

use crate::types::endpoint::Endpoint;
use serviceradar_config_schema::DgraphTlsMode;

/// An endpoint with no cluster behind it, for testing this crate's own logic.
pub fn endpoint(host: &str, port: u16, tls_mode: DgraphTlsMode) -> Endpoint {
    Endpoint::new(host, port, tls_mode)
}

/// A `/health?all` body with one zero and one alpha, both healthy, as v25.4.0 renders it.
pub const HEALTHY_BODY: &str = r#"[
  {"instance":"zero","address":"z0:5080","status":"healthy","group":"0","version":"v25.4.0","uptime":973,"lastEcho":1787196174},
  {"instance":"alpha","address":"a0:7080","status":"healthy","group":"1","version":"v25.4.0","uptime":38,"lastEcho":1787196175,"ongoing":["opRollup"],"ee_features":["backup_restore","cdc"],"max_assigned":4}
]"#;

/// The same, with the alpha still coming up.
pub const UNHEALTHY_BODY: &str = r#"[
  {"instance":"zero","address":"z0:5080","status":"healthy","group":"0","version":"v25.4.0"},
  {"instance":"alpha","address":"a0:7080","status":"unhealthy","group":"1","version":"v25.4.0"}
]"#;
