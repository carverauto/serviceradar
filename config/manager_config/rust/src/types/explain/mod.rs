//! What a component resolved, and where each value came from.
//!
//! `explain` exists because the failure this whole system replaces was SILENT: a value came from
//! somewhere nobody could name, and the only way to find out was to read code. Provenance is
//! therefore reported for every value, including the ones that came from a built-in -- "it was
//! compiled in" is an answer, and omitting it would leave the same question open.

use crate::types::{ConfigManager, Identity, Source};
use serviceradar_config_schema::{EnvironmentKind, SecurityMode, TlsMode};

/// One reported setting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub field: String,
    pub value: String,
    pub origin: String,
}

/// A rendered explanation of everything a component resolved.
///
/// Secrets are NOT included -- not redacted, absent. A report that lists secret NAMES alongside
/// configuration is useful; one that lists their values with a mask beside them is one formatting
/// change away from listing them without.
#[derive(Debug, Clone)]
pub struct Explanation {
    pub identity: Identity,
    pub source: Source,
    pub entries: Vec<Entry>,
    pub declared_secrets: Vec<String>,
}

impl Explanation {
    /// Builds an explanation from a loaded manager and the secret names the component declared.
    ///
    /// The names are taken, never the values: this function has no way to reach a secret, which
    /// is a stronger guarantee than remembering to redact one.
    pub fn new(manager: &ConfigManager, declared_secrets: &[&str]) -> Self {
        let origin = manager.source().to_string();
        let mut entries = Vec::new();

        let mut push = |field: &str, value: Option<String>| {
            if let Some(value) = value {
                entries.push(Entry {
                    field: field.to_string(),
                    value,
                    origin: origin.clone(),
                });
            }
        };

        push("kind", Some(manager.identity().kind().to_string()));
        push("instance", manager.identity().instance().map(str::to_string));

        if let Some(db) = manager.database() {
            push("database.host", db.host.clone());
            push("database.port", db.port.map(|v| v.to_string()));
            push("database.database", db.database.clone());
            push("database.connecting_role", db.connecting_role.clone());
            push("database.owning_role", db.owning_role.clone());
            push("database.tls_mode", enum_name(db.tls_mode, TlsMode::try_from));
            push("database.tls_server_name", db.tls_server_name.clone());
            push("database.admin_role", db.admin_role.clone());
            push("database.ca_bundle_url", db.ca_bundle_url.clone());
            push("database.search_path", db.search_path.clone());
            push("database.pool_size", db.pool_size.map(|v| v.to_string()));
        }
        if let Some(nats) = manager.nats() {
            push("nats.url", nats.url.clone());
            push("nats.server_name", nats.server_name.clone());
        }
        if let Some(core) = manager.core() {
            push("core.address", core.address.clone());
            push("core.api_url", core.api_url.clone());
            push("core.security_mode", enum_name(core.security_mode, SecurityMode::try_from));
            push("core.server_name", core.server_name.clone());
            push("core.trust_domain", core.trust_domain.clone());
            push("core.server_spiffe_id", core.server_spiffe_id.clone());
        }
        if let Some(dgraph) = manager.dgraph() {
            push("dgraph.host", dgraph.host.clone());
            push("dgraph.port", dgraph.port.map(|v| v.to_string()));
            push("dgraph.ca_bundle_url", dgraph.ca_bundle_url.clone());
        }

        Self {
            identity: manager.identity().clone(),
            source: manager.source().clone(),
            entries,
            declared_secrets: declared_secrets.iter().map(|s| (*s).to_string()).collect(),
        }
    }

    /// The report a human reads.
    pub fn render(&self) -> String {
        let mut out = format!(
            "SERVICERADAR_ENV={}\nsource: {}\n\nconfiguration:\n",
            self.identity, self.source
        );
        for entry in &self.entries {
            out.push_str(&format!(
                "  {:<28} {:<48} <- {}\n",
                entry.field, entry.value, entry.origin
            ));
        }
        out.push_str("\nsecrets declared by this component:\n");
        if self.declared_secrets.is_empty() {
            out.push_str("  (none)\n");
        }
        for name in &self.declared_secrets {
            // The NAME and where it would be resolved from. Never the value, and never a masked
            // value beside it.
            out.push_str(&format!("  {name:<28} (value not shown)\n"));
        }
        out
    }
}

fn enum_name<T, E, F>(raw: Option<i32>, from: F) -> Option<String>
where
    F: Fn(i32) -> Result<T, E>,
    T: EnumName,
{
    raw.and_then(|v| from(v).ok()).map(|e| e.name().to_string())
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
impl EnumName for EnvironmentKind {
    fn name(&self) -> &'static str {
        self.as_str_name()
    }
}
