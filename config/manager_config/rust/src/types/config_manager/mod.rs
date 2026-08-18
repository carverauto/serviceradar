//! Resolves a component's configuration and validates it before exposing a value.

use crate::errors::LoadError;
use crate::traits::ReadSource;
use crate::types::{Dsn, Identity, Source};
use prost::Message;
use serviceradar_config_schema::{
    CoreConfig, DatabaseConfig, DgraphConfig, EnvironmentConfig, EnvironmentKind, NatsConfig,
    TlsMode,
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
    ///
    /// Validation happens on every load
    pub fn load<R: ReadSource + ?Sized>(
        identity: &Identity,
        built_ins: BuiltIns<'_>,
        reader: &R,
    ) -> Result<Self, LoadError> {
        let rules = crate::rules::embedded();
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

    /// Assembles the database DSN from typed fields plus the resolved password.
    ///
    /// The password is taken already exposed, so the call site says `secret.expose()` and the
    /// read is visible there rather than hidden in here. `sslmode` comes from the typed TLS mode:
    /// a DSN built by string concatenation is how `sslmode` went missing and tokio-postgres fell
    /// back to Prefer, permitting a plaintext connection while every test still passed.
    pub fn database_url(&self, password: &str) -> Option<Dsn> {
        let database = self.config.database.as_ref()?.database.as_deref()?;
        self.database_url_named(database, password)
    }

    /// The same DSN, pointed at a different database on the same server.
    ///
    /// The integration fixture derives a per-run database name, which varies by RUN rather than
    /// by environment and so is not a schema field. Building the DSN from typed fields with the
    /// name substituted is what removes the need to parse a base URL and rewrite its path --
    /// a rewrite that had to preserve the query string by hand to avoid dropping `sslmode`.
    pub fn database_url_named(&self, database: &str, password: &str) -> Option<Dsn> {
        let db = self.config.database.as_ref()?;
        let sslmode = match TlsMode::try_from(db.tls_mode?).ok()? {
            TlsMode::Unspecified => return None,
            TlsMode::Disable => "disable",
            TlsMode::Require => "require",
            TlsMode::VerifyCa => "verify-ca",
            TlsMode::VerifyFull => "verify-full",
        };

        let url = format!(
            "postgres://{}:{}@{}:{}/{}?sslmode={sslmode}",
            encode_userinfo(db.connecting_role.as_deref()?),
            encode_userinfo(password),
            db.host.as_deref()?,
            db.port?,
            database,
        );

        // `tls_server_name` is deliberately NOT in the DSN. It is a typed field the caller hands
        // to its TLS connector, which is the only component that can act on it.
        //
        // This previously appended `&sslsni=1&host=<name>`, which is libpq syntax, and broke two
        // ways at once under tokio-postgres: `sslsni` has no arm in `Config::param`, so the whole
        // connection string is rejected with `unknown option`; and a query-string `host` is read
        // as an ADDITIONAL host to dial, so the SNI name would have become a silent fallback
        // endpoint rather than a verification name.
        Some(Dsn::new(url))
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

/// Percent-encodes the characters that would otherwise terminate a DSN's userinfo field.
///
/// A password containing `@` or `:` would silently truncate the host or the role, producing a DSN
/// that parses into something else entirely rather than failing.
fn encode_userinfo(raw: &str) -> String {
    raw.chars()
        .map(|c| match c {
            ':' => "%3A".to_string(),
            '@' => "%40".to_string(),
            '/' => "%2F".to_string(),
            '?' => "%3F".to_string(),
            '#' => "%23".to_string(),
            other => other.to_string(),
        })
        .collect()
}
