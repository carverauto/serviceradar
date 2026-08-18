//! Resolves a component's configuration and validates it before exposing a value.

use crate::errors::LoadError;
use crate::traits::ReadSource;
use crate::types::{Identity, Source};
use prost::Message;
use serviceradar_config_schema::{
    CoreConfig, DatabaseConfig, DgraphConfig, EnvironmentConfig, EnvironmentKind, NatsConfig,
    RuleSet,
};
use serviceradar_config_validator::validate;

/// The instances compiled into this release, as `(identity, encoded bytes)`.
pub type BuiltIns<'a> = &'a [(&'a str, &'a [u8])];

/// A loaded, validated environment.
///
/// There is no constructor that skips validation, and no way to build one from a message
/// directly: every instance of this type has been checked against the committed rule set and has
/// been confirmed to describe the environment that was selected.
#[derive(Debug, Clone)]
pub struct ConfigManager {
    identity: Identity,
    source: Source,
    config: EnvironmentConfig,
}

impl ConfigManager {
    /// Reads, decodes, confirms the artifact describes `identity`, and validates it.
    ///
    /// `reader` is taken by generic bound rather than `dyn`: the transport is a compile-time
    /// choice, and nothing here needs to store one.
    pub fn load<R: ReadSource + ?Sized>(
        identity: &Identity,
        built_ins: BuiltIns<'_>,
        rules: &RuleSet,
        reader: &R,
    ) -> Result<Self, LoadError> {
        let source = Source::for_identity(identity);

        let bytes = match &source {
            Source::BuiltIn { name } => match built_ins.iter().find(|(n, _)| n == name) {
                Some((_, bytes)) => bytes.to_vec(),
                None => {
                    return Err(LoadError::UnknownBuiltIn {
                        name: name.clone(),
                        available: built_ins.iter().map(|(n, _)| (*n).to_string()).collect(),
                    })
                }
            },
            // No cached fallback: a service that silently starts on last week's configuration
            // is worse than one that does not start.
            Source::Mounted { path } => reader
                .read(path)
                .map_err(|detail| LoadError::Read { source: source.clone(), detail })?,
        };

        let config = EnvironmentConfig::decode(&*bytes)
            .map_err(|e| LoadError::Decode { source: source.clone(), detail: e.to_string() })?;

        // The artifact is self-describing and the selector is declared, so they can be compared.
        // This catches the wrong ConfigMap being mounted -- otherwise completely silent, and its
        // blast radius is the database a component connects to.
        let found = Identity::from_parts(kind_name(config.kind), config.instance.clone());
        if found != *identity {
            return Err(LoadError::IdentityMismatch {
                selected: identity.to_string(),
                found: found.to_string(),
                source,
            });
        }

        let violations =
            validate(rules, &config).map_err(|e| LoadError::RuleSet { detail: e.0 })?;
        if !violations.is_empty() {
            return Err(LoadError::Invalid { source, violations });
        }

        Ok(Self { identity: identity.clone(), source, config })
    }

    pub fn identity(&self) -> &Identity {
        &self.identity
    }

    /// Where the instance came from. Reported by `explain`, and the place an endpoint or a fetch
    /// time would live if configuration ever arrived over a network.
    pub fn source(&self) -> &Source {
        &self.source
    }

    pub fn database(&self) -> Option<&DatabaseConfig> {
        self.config.database.as_ref()
    }

    pub fn nats(&self) -> Option<&NatsConfig> {
        self.config.nats.as_ref()
    }

    pub fn core(&self) -> Option<&CoreConfig> {
        self.config.core.as_ref()
    }

    pub fn dgraph(&self) -> Option<&DgraphConfig> {
        self.config.dgraph.as_ref()
    }
}

fn kind_name(kind: Option<i32>) -> String {
    match kind.and_then(|k| EnvironmentKind::try_from(k).ok()) {
        Some(k) => k
            .as_str_name()
            .strip_prefix("ENVIRONMENT_KIND_")
            .unwrap_or_default()
            .to_ascii_lowercase(),
        None => "<unset>".to_string(),
    }
}
