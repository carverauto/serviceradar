//! What Dgraph's `/health?all` says about the cluster.

use crate::errors::fixture_error::FixtureError;

/// One server's entry in a health report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerHealth {
    instance: String,
    address: String,
    status: String,
    group: String,
    version: String,
}

impl ServerHealth {
    /// `zero` or `alpha`.
    pub fn instance(&self) -> &str {
        &self.instance
    }
    pub fn address(&self) -> &str {
        &self.address
    }
    pub fn status(&self) -> &str {
        &self.status
    }
    /// Raft group. Zeros report group 0; alphas report the group they serve.
    pub fn group(&self) -> &str {
        &self.group
    }
    pub fn version(&self) -> &str {
        &self.version
    }
    pub fn is_healthy(&self) -> bool {
        self.status == "healthy"
    }
}

/// Every server Dgraph knows about, as reported by one alpha.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthReport {
    servers: Vec<ServerHealth>,
}

impl HealthReport {
    /// Parse the JSON array `/health?all` returns.
    ///
    /// Tolerant about fields, strict about shape. Dgraph adds keys between versions
    /// (`ee_features`, `ongoing`, `max_assigned` appeared over time), so unknown keys are ignored
    /// and a missing one becomes an empty string rather than a parse failure -- a health check
    /// that breaks on a new optional field is worse than no health check. A response that is not
    /// a JSON array at all IS an error, because that means something other than Dgraph answered.
    pub fn parse(url: &str, body: &str) -> Result<Self, FixtureError> {
        let value: serde_json::Value = serde_json::from_str(body)
            .map_err(|err| FixtureError::health(url, format!("not JSON: {err}")))?;

        let array = value.as_array().ok_or_else(|| {
            FixtureError::health(url, "expected a JSON array of server entries")
        })?;

        let servers = array
            .iter()
            .map(|entry| {
                let text = |key: &str| {
                    entry
                        .get(key)
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default()
                        .to_string()
                };
                ServerHealth {
                    instance: text("instance"),
                    address: text("address"),
                    status: text("status"),
                    group: text("group"),
                    version: text("version"),
                }
            })
            .collect();

        Ok(Self { servers })
    }

    pub fn servers(&self) -> &[ServerHealth] {
        &self.servers
    }

    /// Every server reported healthy, and there is at least one.
    ///
    /// The emptiness check is load-bearing: `[]` parses fine and would otherwise satisfy "all
    /// healthy" vacuously, which is exactly the answer a half-started cluster gives.
    pub fn all_healthy(&self) -> bool {
        !self.servers.is_empty() && self.servers.iter().all(ServerHealth::is_healthy)
    }

    pub fn count(&self, instance: &str) -> usize {
        self.servers
            .iter()
            .filter(|s| s.instance() == instance)
            .count()
    }

    /// One line per server, for a failure message.
    pub fn describe(&self) -> String {
        if self.servers.is_empty() {
            return "no servers reported".to_string();
        }
        self.servers
            .iter()
            .map(|s| {
                format!(
                    "{} {} group={} status={} version={}",
                    s.instance(),
                    s.address(),
                    s.group(),
                    s.status(),
                    s.version()
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}
